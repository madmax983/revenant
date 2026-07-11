/**
 * Best-effort, intentionally non-exhaustive transition probe for a
 * WorkflowDefinition DAG, extracted from WorkflowValidator so each class keeps a
 * small aggregate complexity. getNextStep is data-dependent — its branches can
 * hinge on step output the validator does not have — so this cannot enumerate
 * every reachable transition. It drives getNextStep with a small set of
 * representative StepResults for each declared step and flags any returned
 * successor name that is not itself declared in getSteps(). Author exceptions
 * thrown from getNextStep are swallowed because the probe feeds it synthetic
 * results it may not expect.
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
 */
public inherited sharing class WorkflowTransitionProbe {
  /**
   * @description Runs the default and (where applicable) version-aware transition
   * probes, appending any DANGLING_SUCCESSOR / CONTRACT_METHOD_THREW defects to
   * result. The declared-name set is derived from declaredSteps exactly as the
   * validator derives it (new Set&lt;String&gt;(declaredSteps)).
   * @param def The workflow definition whose routing is being probed.
   * @param declaredSteps The step names declared by the definition's getSteps().
   * @param result The validation result to which discovered defects are appended.
   */
  public static void probe(
    WorkflowDefinition def,
    List<String> declaredSteps,
    WorkflowValidator.ValidationResult result
  ) {
    ProbeContext ctx = new ProbeContext(declaredSteps, result);

    // Two-argument (default) routing for every declared step.
    probeDefaultRouting(def, ctx);

    // Version-aware routing for VersionedWorkflow definitions.
    if (def instanceof VersionedWorkflow) {
      probeVersionedRouting((VersionedWorkflow) def, ctx);
    }
  }

  /**
   * @description Drives the two-argument getNextStep for every declared step and
   * COMPLETE-action probe result, flagging any returned successor not declared in
   * getSteps() and swallowing author exceptions from getNextStep.
   * @param def The workflow definition whose default routing is being probed.
   * @param ctx The probe context holding declared steps, probes, and the result.
   */
  private static void probeDefaultRouting(
    WorkflowDefinition def,
    ProbeContext ctx
  ) {
    for (String stepName : ctx.declaredSteps) {
      for (StepResult probe : ctx.probes) {
        String successor;
        try {
          successor = def.getNextStep(stepName, probe);
        } catch (Exception e) {
          // Data-dependent author logic; ignore for a best-effort probe.
          continue;
        }
        flagIfDangling(stepName, successor, ctx);
      }
    }
  }

  /**
   * @description Drives the three-argument getNextStep(current, result, version)
   * for every version in 1..getLatestVersion(). A throw from getLatestVersion()
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
    for (Integer version = 1; version <= latest; version++) {
      for (String stepName : ctx.declaredSteps) {
        for (StepResult probe : ctx.probes) {
          String successor;
          try {
            successor = vdef.getNextStep(stepName, probe, version);
          } catch (Exception e) {
            continue;
          }
          flagIfDangling(stepName, successor, ctx);
        }
      }
    }
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
    final List<StepResult> probes = new List<StepResult>{
      StepResult.complete(null, null),
      StepResult.complete(null, new Map<String, Object>())
    };

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
