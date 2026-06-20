/**
 * Static, read-only structural validator for a WorkflowDefinition DAG.
 *
 * Where WorkflowEngine resolves step classes lazily at runtime (via
 * Type.forName, after prior forward steps and their side effects have already
 * committed), this validator lets a saga author assert "this DAG is wired
 * correctly" at authoring/deploy time, before any record is written or any
 * compensation can fire. A single validate() call returns *every* structural
 * defect found (not just the first), each naming the offending step.
 *
 * Validation is strictly read-only: it only calls Type.forName / newInstance
 * and the WorkflowDefinition contract methods. It creates no Workflow_Instance__c,
 * writes no Workflow_Step_Execution__c, touches no compensation state, publishes
 * no platform events, and enqueues no jobs.
 *
 * Constructor side effects: to check interface conformance, validation
 * instantiates each declared step (and the definition) via
 * Type.forName().newInstance() — exactly as WorkflowEngine does when it resolves
 * a step at runtime. Apex exposes no way to test `instanceof WorkflowStep`
 * without instantiating. Authors must therefore keep workflow/step zero-arg
 * constructors side-effect-free (no DML, no platform events, no enqueues) — the
 * same implicit requirement the engine already imposes, since it newInstance()s
 * the same classes. Put real work in execute()/compensate(), never the
 * constructor; otherwise that work would also run on every engine step
 * resolution, not just during validation.
 *
 * See issue #23.
 */
public with sharing class WorkflowValidator {
  // Defect codes. Stable identifiers so callers can branch on a defect class
  // without string-matching human-readable messages.
  public static final String DEFINITION_UNRESOLVABLE = 'DEFINITION_UNRESOLVABLE';
  public static final String INITIAL_STEP_BLANK = 'INITIAL_STEP_BLANK';
  public static final String INITIAL_STEP_NOT_DECLARED = 'INITIAL_STEP_NOT_DECLARED';
  public static final String DUPLICATE_STEP = 'DUPLICATE_STEP';
  public static final String STEP_UNRESOLVABLE = 'STEP_UNRESOLVABLE';
  public static final String STEP_NOT_WORKFLOWSTEP = 'STEP_NOT_WORKFLOWSTEP';
  public static final String DANGLING_SUCCESSOR = 'DANGLING_SUCCESSOR';
  public static final String CONTRACT_METHOD_THREW = 'CONTRACT_METHOD_THREW';

  /**
   * A single structural defect. stepName is the offending step (or the
   * workflow name itself for definition-level defects); message embeds it.
   */
  public class Defect {
    public String code;
    public String stepName;
    public String message;

    public Defect(String code, String stepName, String message) {
      this.code = code;
      this.stepName = stepName;
      this.message = message;
    }
  }

  /**
   * Structured outcome of a validation run. isValid() is true only when no
   * defects were found. defects lists every defect; getMessages() is a
   * convenience flattening of their human-readable text.
   */
  public class ValidationResult {
    public String workflowName;
    public List<Defect> defects = new List<Defect>();

    public ValidationResult(String workflowName) {
      this.workflowName = workflowName;
    }

    public Boolean isValid() {
      return defects.isEmpty();
    }

    public Boolean hasDefect(String code) {
      for (Defect d : defects) {
        if (d.code == code) {
          return true;
        }
      }
      return false;
    }

    public List<String> getMessages() {
      List<String> messages = new List<String>();
      for (Defect d : defects) {
        messages.add(d.message);
      }
      return messages;
    }

    private void add(String code, String stepName, String message) {
      defects.add(new Defect(code, stepName, message));
    }
  }

  /**
   * Statically validates the WorkflowDefinition named by workflowName and
   * returns all structural defects found. Never throws for author-side
   * problems — every defect is surfaced through the returned result.
   */
  public static ValidationResult validate(String workflowName) {
    ValidationResult result = new ValidationResult(workflowName);

    // (a) The definition class must resolve and implement WorkflowDefinition.
    WorkflowDefinition def = resolveDefinition(workflowName, result);
    if (def == null) {
      // Nothing further is checkable without a usable definition instance.
      return result;
    }

    // (b) The entry point must be present and declared. Author contract
    // methods may throw (e.g. reading malformed configuration); surface that as
    // a defect rather than letting it abort the whole validation run.
    Boolean initialStepThrew = false;
    String initialStep;
    try {
      initialStep = def.getInitialStep();
    } catch (Exception e) {
      initialStepThrew = true;
      result.add(
        CONTRACT_METHOD_THREW,
        workflowName,
        'Workflow "' +
        workflowName +
        '" getInitialStep() threw ' +
        e.getTypeName() +
        ': ' +
        e.getMessage()
      );
    }

    List<String> declaredSteps;
    try {
      declaredSteps = safeGetSteps(def);
    } catch (Exception e) {
      declaredSteps = new List<String>();
      result.add(
        CONTRACT_METHOD_THREW,
        workflowName,
        'Workflow "' +
        workflowName +
        '" getSteps() threw ' +
        e.getTypeName() +
        ': ' +
        e.getMessage()
      );
    }
    Set<String> declaredSet = new Set<String>(declaredSteps);

    if (initialStepThrew) {
      // Cannot evaluate the entry point further; already reported above.
    } else if (String.isBlank(initialStep)) {
      result.add(
        INITIAL_STEP_BLANK,
        workflowName,
        'Workflow "' +
        workflowName +
        '" getInitialStep() is blank; the DAG has no entry point.'
      );
    } else if (!declaredSet.contains(initialStep)) {
      result.add(
        INITIAL_STEP_NOT_DECLARED,
        initialStep,
        'Initial step "' +
        initialStep +
        '" is not contained in getSteps().'
      );
    }

    // (d) Duplicate declarations.
    Set<String> seen = new Set<String>();
    Set<String> alreadyFlaggedDup = new Set<String>();
    for (String stepName : declaredSteps) {
      if (seen.contains(stepName) && !alreadyFlaggedDup.contains(stepName)) {
        result.add(
          DUPLICATE_STEP,
          stepName,
          'Step "' +
          stepName +
          '" is declared more than once in getSteps().'
        );
        alreadyFlaggedDup.add(stepName);
      }
      seen.add(stepName);
    }

    // (c) Every declared step must resolve to an instantiable WorkflowStep.
    for (String stepName : declaredSet) {
      validateStepClass(stepName, result);
    }

    // Best-effort transition probe for dangling successors.
    probeTransitions(def, declaredSteps, declaredSet, result);

    return result;
  }

  /**
   * Resolves workflowName to a WorkflowDefinition instance, recording a
   * DEFINITION_UNRESOLVABLE defect and returning null when it cannot resolve
   * or does not implement the contract.
   */
  private static WorkflowDefinition resolveDefinition(
    String workflowName,
    ValidationResult result
  ) {
    if (String.isBlank(workflowName)) {
      result.add(
        DEFINITION_UNRESOLVABLE,
        workflowName,
        'Workflow name is blank; no definition class to resolve.'
      );
      return null;
    }

    Type defType = Type.forName(workflowName);
    if (defType == null) {
      result.add(
        DEFINITION_UNRESOLVABLE,
        workflowName,
        'Workflow "' +
        workflowName +
        '" does not resolve to an Apex class via Type.forName.'
      );
      return null;
    }

    Object instance;
    try {
      instance = defType.newInstance();
    } catch (Exception e) {
      result.add(
        DEFINITION_UNRESOLVABLE,
        workflowName,
        'Workflow "' +
        workflowName +
        '" could not be instantiated: ' +
        e.getMessage()
      );
      return null;
    }

    if (!(instance instanceof WorkflowDefinition)) {
      result.add(
        DEFINITION_UNRESOLVABLE,
        workflowName,
        'Workflow "' +
        workflowName +
        '" does not implement WorkflowDefinition.'
      );
      return null;
    }

    return (WorkflowDefinition) instance;
  }

  /**
   * Reads getSteps() defensively. A null return is normalized to an empty
   * list so downstream checks (initial-step containment, duplicates) behave
   * predictably rather than NPE-ing.
   */
  private static List<String> safeGetSteps(WorkflowDefinition def) {
    List<String> steps = def.getSteps();
    return (steps == null) ? new List<String>() : steps;
  }

  /**
   * Flags a declared step name that does not resolve via Type.forName, or
   * resolves to a class that does not implement WorkflowStep. CompensatableStep
   * extends WorkflowStep, so the instanceof check covers both.
   */
  private static void validateStepClass(
    String stepName,
    ValidationResult result
  ) {
    if (String.isBlank(stepName)) {
      result.add(
        STEP_UNRESOLVABLE,
        stepName,
        'A blank step name is declared in getSteps().'
      );
      return;
    }

    Type stepType = Type.forName(stepName);
    if (stepType == null) {
      result.add(
        STEP_UNRESOLVABLE,
        stepName,
        'Step "' +
        stepName +
        '" does not resolve to an Apex class via Type.forName.'
      );
      return;
    }

    Object stepInstance;
    try {
      stepInstance = stepType.newInstance();
    } catch (Exception e) {
      result.add(
        STEP_UNRESOLVABLE,
        stepName,
        'Step "' +
        stepName +
        '" could not be instantiated: ' +
        e.getMessage()
      );
      return;
    }

    if (!(stepInstance instanceof WorkflowStep)) {
      result.add(
        STEP_NOT_WORKFLOWSTEP,
        stepName,
        'Step "' +
        stepName +
        '" does not implement WorkflowStep (or CompensatableStep).'
      );
    }
  }

  /**
   * Best-effort, intentionally non-exhaustive transition probe. getNextStep is
   * data-dependent — its branches can hinge on step output the validator does
   * not have — so this cannot enumerate every reachable transition. It drives
   * getNextStep with a small set of representative StepResults for each declared
   * step and flags any returned successor name that is not itself declared in
   * getSteps(). Author exceptions thrown from getNextStep are swallowed because
   * the probe feeds it synthetic results it may not expect.
   *
   * The probe uses only COMPLETE-action results, because that is the sole
   * transition through which WorkflowEngine asks the definition for a successor.
   * Other actions (SUSPEND, YIELD, SLEEP, RETRY, WAIT_FOR_APPROVAL, START_CHILD,
   * CONTINUE_AS_NEW) re-run or park the same step without calling getNextStep, so
   * probing them could flag a dangling successor on a path the engine never
   * routes — a false positive against routers that branch on result.action.
   *
   * For a VersionedWorkflow the engine starts instances at getLatestVersion()
   * and routes via the three-argument getNextStep(current, result, version), so
   * the probe additionally drives that overload for every version in
   * 1..getLatestVersion(). This catches a successor used only by a newer version
   * that was omitted from getSteps() — which the two-argument fallback alone can
   * miss, letting it fail lazily at runtime after prior steps have committed.
   */
  private static void probeTransitions(
    WorkflowDefinition def,
    List<String> declaredSteps,
    Set<String> declaredSet,
    ValidationResult result
  ) {
    List<StepResult> probes = new List<StepResult>{
      StepResult.complete(null, null),
      StepResult.complete(null, new Map<String, Object>())
    };

    Set<String> flagged = new Set<String>();

    // Two-argument (default) routing for every declared step.
    for (String stepName : declaredSteps) {
      for (StepResult probe : probes) {
        String successor;
        try {
          successor = def.getNextStep(stepName, probe);
        } catch (Exception e) {
          // Data-dependent author logic; ignore for a best-effort probe.
          continue;
        }
        flagIfDangling(stepName, successor, declaredSet, flagged, result);
      }
    }

    // Version-aware routing for VersionedWorkflow definitions.
    if (def instanceof VersionedWorkflow) {
      VersionedWorkflow vdef = (VersionedWorkflow) def;
      Integer latest;
      try {
        latest = vdef.getLatestVersion();
      } catch (Exception e) {
        // The engine calls getLatestVersion() before starting an instance, so a
        // throw here means the workflow cannot start — report it rather than
        // silently skipping the versioned probe.
        latest = null;
        result.add(
          CONTRACT_METHOD_THREW,
          result.workflowName,
          'Workflow "' +
          result.workflowName +
          '" getLatestVersion() threw ' +
          e.getTypeName() +
          ': ' +
          e.getMessage()
        );
      }
      if (latest != null && latest >= 1) {
        for (Integer version = 1; version <= latest; version++) {
          for (String stepName : declaredSteps) {
            for (StepResult probe : probes) {
              String successor;
              try {
                successor = vdef.getNextStep(stepName, probe, version);
              } catch (Exception e) {
                continue;
              }
              flagIfDangling(stepName, successor, declaredSet, flagged, result);
            }
          }
        }
      }
    }
  }

  /**
   * Records a DANGLING_SUCCESSOR defect when a probed successor is non-blank and
   * not declared in getSteps(), de-duplicating by successor name.
   */
  private static void flagIfDangling(
    String stepName,
    String successor,
    Set<String> declaredSet,
    Set<String> flagged,
    ValidationResult result
  ) {
    if (String.isBlank(successor)) {
      return;
    }
    if (!declaredSet.contains(successor) && !flagged.contains(successor)) {
      result.add(
        DANGLING_SUCCESSOR,
        successor,
        'Step "' +
        stepName +
        '" can transition to "' +
        successor +
        '", which is not contained in getSteps() (best-effort probe).'
      );
      flagged.add(successor);
    }
  }
}
