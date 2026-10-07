/**
 * Best-effort, intentionally non-exhaustive transition probe for a
 * WorkflowDefinition DAG, extracted from WorkflowValidator so each class keeps a
 * small aggregate complexity. getNextStep is data-dependent — its branches can
 * hinge on step output the validator does not have — so this cannot enumerate
 * every reachable transition. It drives getNextStep with a small set of
 * representative StepResults for each declared step and flags any returned
 * successor name that is not itself declared in getSteps(). An author exception
 * from getNextStep gives no defect, because the probe feeds it synthetic
 * results. The probe records the step as unresolved.
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
 *
 * Defects are appended straight to the caller's ValidationResult, exactly as the
 * former in-validator probe did.
 *
 * Issue #141: the probe also records each transition it finds in a Transitions
 * value. WorkflowTopology uses it to draw the graph. The validator probes every
 * version. The graph probes only the newest MAX_PROBED_VERSIONS versions, so a
 * large version number (for example a date) cannot use all the CPU time of a
 * dashboard request.
 *
 * Issue #290: probeStep probes one step for the version of one instance.
 */
public inherited sharing class WorkflowTransitionProbe {
  /** The maximum number of versions that the graph probes. */
  public static final Integer MAX_PROBED_VERSIONS = 50;

  /**
   * The transitions that the probe found (issue #141). It is best-effort:
   * a missing edge does not prove that no edge exists.
   */
  public class Transitions {
    /** Known successors of each probed step, in the order found. */
    public Map<String, List<String>> successors = new Map<String, List<String>>();
    /** Steps where getNextStep returned a blank successor (the run can end). */
    public Set<String> endingSteps = new Set<String>();
    /** Steps where getNextStep threw for a probe (routing not known). */
    public Set<String> unresolvedSteps = new Set<String>();
    /** Steps where the probes of one pass gave different successors. */
    public Set<String> variedSteps = new Set<String>();
    /** True when getLatestVersion() threw, so no version was probed. */
    public Boolean versionsUnresolved = false;
    /** True when the probe did not read the oldest versions. */
    public Boolean versionsCapped = false;

    /**
     * @description Records one probe outcome. A blank successor marks an end.
     * @param stepName The probed step.
     * @param successor The successor that getNextStep returned.
     */
    public void record(String stepName, String successor) {
      if (String.isBlank(successor)) {
        endingSteps.add(stepName);
        return;
      }
      List<String> known = successors.get(stepName);
      if (known == null) {
        known = new List<String>();
        successors.put(stepName, known);
      }
      if (!known.contains(successor)) {
        known.add(successor);
      }
    }

    /**
     * @description Gives the known successors of a step.
     * @param stepName The step.
     * @return The known successors, or an empty list.
     */
    public List<String> successorsOf(String stepName) {
      List<String> known = successors.get(stepName);
      return known == null ? new List<String>() : known;
    }
  }

  /**
   * @description Runs the default and (where applicable) version-aware transition
   * probes, appending any DANGLING_SUCCESSOR / CONTRACT_METHOD_THREW defects to
   * result. The declared-name set is derived from declaredSteps exactly as the
   * validator derives it (new Set&lt;String&gt;(declaredSteps)).
   * @param def The workflow definition whose routing is being probed.
   * @param declaredSteps The step names declared by the definition's getSteps().
   * @param result The validation result to which discovered defects are appended.
   * @return The transitions that the probe found (issue #141).
   */
  public static Transitions probe(
    WorkflowDefinition def,
    List<String> declaredSteps,
    WorkflowValidator.ValidationResult result
  ) {
    return probe(def, declaredSteps, result, null);
  }

  /**
   * @description Runs the probes as probe(def, declaredSteps, result) does, but
   * reads only the newest maxVersions versions of a VersionedWorkflow.
   * @param def The workflow definition whose routing is being probed.
   * @param declaredSteps The step names declared by the definition's getSteps().
   * @param result The validation result to which discovered defects are appended.
   * @param maxVersions The maximum number of versions to probe, or null for all.
   * @return The transitions that the probe found.
   */
  public static Transitions probe(
    WorkflowDefinition def,
    List<String> declaredSteps,
    WorkflowValidator.ValidationResult result,
    Integer maxVersions
  ) {
    ProbeContext ctx = new ProbeContext(declaredSteps, result);
    ctx.maxVersions = maxVersions;

    // Two-argument (default) routing for every declared step.
    probeDefaultRouting(def, ctx);

    // Version-aware routing for VersionedWorkflow definitions.
    if (def instanceof VersionedWorkflow) {
      probeVersionedRouting((VersionedWorkflow) def, ctx);
    }
    return ctx.transitions;
  }

  /**
   * @description Drives the two-argument getNextStep for every declared step and
   * COMPLETE-action probe result, flagging any returned successor not declared in
   * getSteps(). An author exception marks the step as unresolved.
   * @param def The workflow definition whose default routing is being probed.
   * @param ctx The probe context holding declared steps, probes, and the result.
   */
  private static void probeDefaultRouting(
    WorkflowDefinition def,
    ProbeContext ctx
  ) {
    for (String stepName : ctx.declaredSteps) {
      Set<String> outcomes = new Set<String>();
      for (StepResult probe : ctx.probes) {
        String successor;
        try {
          successor = def.getNextStep(stepName, probe);
        } catch (Exception e) {
          // Data-dependent author logic: no defect, but the routing is not known.
          ctx.transitions.unresolvedSteps.add(stepName);
          continue;
        }
        recordOutcome(stepName, successor, outcomes, ctx);
      }
    }
  }

  /**
   * @description Drives the three-argument getNextStep(current, result, version)
   * for each version up to getLatestVersion(), or for the newest
   * ctx.maxVersions versions when the caller sets a limit. A throw from getLatestVersion()
   * means the workflow cannot start, so it is reported (the engine calls it before
   * starting an instance) rather than silently skipping the versioned probe.
   * @param vdef The versioned workflow definition whose per-version routing is
   * probed.
   * @param ctx The probe context holding declared steps, probes, and the result.
   */
  private static void probeVersionedRouting(
    VersionedWorkflow vdef,
    ProbeContext ctx
  ) {
    Integer latest;
    try {
      latest = vdef.getLatestVersion();
    } catch (Exception e) {
      ctx.transitions.versionsUnresolved = true;
      ctx.addDefect(
        WorkflowValidator.CONTRACT_METHOD_THREW,
        ctx.result.workflowName,
        'Workflow "' +
          ctx.result.workflowName +
          '" getLatestVersion() threw ' +
          e.getTypeName() +
          ': ' +
          e.getMessage()
      );
      return;
    }
    if (latest == null || latest < 1) {
      return;
    }
    Integer oldest = ctx.maxVersions == null
      ? 1
      : Math.max(1, latest - ctx.maxVersions + 1);
    ctx.transitions.versionsCapped = oldest > 1;
    for (Integer version = oldest; version <= latest; version++) {
      for (String stepName : ctx.declaredSteps) {
        Set<String> outcomes = new Set<String>();
        for (StepResult probe : ctx.probes) {
          String successor;
          try {
            successor = vdef.getNextStep(stepName, probe, version);
          } catch (Exception e) {
            ctx.transitions.unresolvedSteps.add(stepName);
            continue;
          }
          recordOutcome(stepName, successor, outcomes, ctx);
        }
      }
    }
  }

  /**
   * @description Probes one step as the engine routes an instance (issue
   * #290). A VersionedWorkflow uses getNextStep(current, result, version), as
   * WorkflowStepAdvance.resolveNextStepName does. Another definition uses
   * getNextStep(current, result). It records no defect.
   * @param def The workflow definition.
   * @param stepName The step to probe.
   * @param version The instance version. Null gives version 1, as in the engine.
   * @return The transitions of the step.
   */
  public static Transitions probeStep(
    WorkflowDefinition def,
    String stepName,
    Integer version
  ) {
    Transitions t = new Transitions();
    Boolean versioned = def instanceof VersionedWorkflow;
    Integer routed = version == null ? 1 : version;
    for (StepResult probe : probeResults()) {
      try {
        t.record(
          stepName,
          versioned
            ? ((VersionedWorkflow) def).getNextStep(stepName, probe, routed)
            : def.getNextStep(stepName, probe)
        );
      } catch (Exception e) {
        t.unresolvedSteps.add(stepName);
      }
    }
    return t;
  }

  // The COMPLETE-action results that each probe gives to getNextStep.
  private static List<StepResult> probeResults() {
    return new List<StepResult>{
      StepResult.complete(null, null),
      StepResult.complete(null, new Map<String, Object>())
    };
  }

  // Records one probe outcome. Two different outcomes in one pass show that
  // the routing of the step depends on step output.
  private static void recordOutcome(
    String stepName,
    String successor,
    Set<String> outcomes,
    ProbeContext ctx
  ) {
    outcomes.add(String.isBlank(successor) ? '' : successor);
    if (outcomes.size() > 1) {
      ctx.transitions.variedSteps.add(stepName);
    }
    ctx.transitions.record(stepName, successor);
    flagIfDangling(stepName, successor, ctx);
  }

  /**
   * @description Records a DANGLING_SUCCESSOR defect when a probed successor is
   * non-blank and not declared in getSteps(), de-duplicating by successor name.
   * @param stepName The declared step whose routing produced the successor.
   * @param successor The successor step name returned by getNextStep.
   * @param ctx The probe context holding the declared set, flagged set, and result.
   */
  private static void flagIfDangling(
    String stepName,
    String successor,
    ProbeContext ctx
  ) {
    if (String.isBlank(successor)) {
      return;
    }
    if (
      !ctx.declaredSet.contains(successor) && !ctx.flagged.contains(successor)
    ) {
      ctx.addDefect(
        WorkflowValidator.DANGLING_SUCCESSOR,
        successor,
        'Step "' +
          stepName +
          '" can transition to "' +
          successor +
          '", which is not contained in getSteps() (best-effort probe).'
      );
      ctx.flagged.add(successor);
    }
  }

  /**
   * Bundles the mutable and read-only state threaded through the transition
   * probe: the declared step list/set, the running set of already-flagged
   * dangling successors, the result to append defects to, and the fixed set of
   * COMPLETE-action probe StepResults driven into getNextStep.
   */
  private class ProbeContext {
    final List<String> declaredSteps;
    final Set<String> declaredSet;
    final Set<String> flagged = new Set<String>();
    final WorkflowValidator.ValidationResult result;
    final Transitions transitions = new Transitions();
    Integer maxVersions;
    final List<StepResult> probes = probeResults();

    ProbeContext(
      List<String> declaredSteps,
      WorkflowValidator.ValidationResult result
    ) {
      this.declaredSteps = declaredSteps;
      this.declaredSet = new Set<String>(declaredSteps);
      this.result = result;
    }

    void addDefect(String code, String stepName, String message) {
      this.result.defects.add(
        new WorkflowValidator.Defect(code, stepName, message)
      );
    }
  }
}
