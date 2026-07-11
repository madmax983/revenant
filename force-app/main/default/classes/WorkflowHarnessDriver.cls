/**
 * Test-only hop-loop driver for the WorkflowTestHarness. Repeatedly advances every
 * advanceable instance in the tree (root + spawned children) within a caller-supplied
 * hop budget, delivering pending platform events between hops, until the workflow
 * stabilizes (terminal or genuine signal-suspend), the target step is reached, or the
 * budget is exhausted.
 */
@IsTest
public inherited sharing class WorkflowHarnessDriver {
  public static WorkflowTestHarness.Result stepOnce(
    WorkflowHarnessContext ctx
  ) {
    WorkflowHarnessCore.deliverEvents();
    WorkflowHarnessStepRunner runner = new WorkflowHarnessStepRunner(ctx);
    for (Workflow_Instance__c inst : WorkflowHarnessCore.collectTree(ctx)) {
      if (WorkflowHarnessAdvancer.isAdvanceable(ctx, inst)) {
        runner.advanceOneStep(inst, 1);
        WorkflowHarnessCore.deliverEvents();
        return WorkflowHarnessCore.buildResult(ctx);
      }
    }
    return WorkflowHarnessCore.buildResult(ctx);
  }

  public static WorkflowTestHarness.Result driveUntilStep(
    WorkflowHarnessContext ctx,
    String stepName,
    Integer maxHops
  ) {
    WorkflowHarnessContext.requireStep(stepName);
    WorkflowHarnessContext.requirePositiveHops(maxHops);

    Integer hopsThisCall = 0;
    while (hopsThisCall < maxHops) {
      WorkflowHarnessCore.deliverEvents();
      WorkflowTestHarness.Result current = WorkflowHarnessCore.buildResult(ctx);
      if (current.reachedStep(stepName) || current.isTerminal) {
        return current;
      }
      TreeAdvance adv = driveUntilTreeOnce(ctx, maxHops - hopsThisCall);
      if (!adv.advancedAny) {
        return WorkflowHarnessCore.buildResult(ctx);
      }
      hopsThisCall += adv.used;
    }

    // One final check: the target step may have completed on the last hop.
    return driveUntilTimeout(ctx, stepName, maxHops);
  }

  private static TreeAdvance driveUntilTreeOnce(
    WorkflowHarnessContext ctx,
    Integer remaining
  ) {
    TreeAdvance adv = new TreeAdvance();
    WorkflowHarnessStepRunner runner = new WorkflowHarnessStepRunner(ctx);
    for (Workflow_Instance__c inst : WorkflowHarnessCore.collectTree(ctx)) {
      if (adv.used >= remaining) {
        break;
      }
      if (!WorkflowHarnessAdvancer.isAdvanceable(ctx, inst)) {
        continue;
      }
      adv.used += runner.advanceOneStep(inst, remaining - adv.used);
      adv.advancedAny = true;
    }
    return adv;
  }

  private static WorkflowTestHarness.Result driveUntilTimeout(
    WorkflowHarnessContext ctx,
    String stepName,
    Integer maxHops
  ) {
    WorkflowTestHarness.Result finalCheck = WorkflowHarnessCore.buildResult(
      ctx
    );
    if (finalCheck.reachedStep(stepName) || finalCheck.isTerminal) {
      return finalCheck;
    }
    throw new WorkflowTestHarness.HarnessException(
      'Step ' +
        stepName +
        ' was not reached within ' +
        maxHops +
        ' hop(s). Root status: ' +
        finalCheck.status
    );
  }

  public static WorkflowTestHarness.Result drive(
    WorkflowHarnessContext ctx,
    Integer maxHops
  ) {
    WorkflowHarnessContext.requirePositiveHops(maxHops);

    Integer hopsThisCall = 0;
    while (hopsThisCall < maxHops) {
      // Deliver any pending platform events (e.g. child-completion signals) so a
      // parent that was waiting on a child becomes advanceable again.
      WorkflowHarnessCore.deliverEvents();

      Integer used = driveTreeOnce(ctx, maxHops - hopsThisCall);
      if (used == 0) {
        // Nothing in the tree can move on its own: the workflow has stabilized.
        return WorkflowHarnessCore.buildResult(ctx);
      }
      hopsThisCall += used;
    }

    // Budget spent. If the tree still has work to do, fail loudly.
    return assertStabilized(ctx, maxHops);
  }

  private static Integer driveTreeOnce(
    WorkflowHarnessContext ctx,
    Integer remaining
  ) {
    Integer used = 0;
    WorkflowHarnessStepRunner runner = new WorkflowHarnessStepRunner(ctx);
    for (Workflow_Instance__c inst : WorkflowHarnessCore.collectTree(ctx)) {
      if (used >= remaining) {
        break;
      }
      if (!WorkflowHarnessAdvancer.isAdvanceable(ctx, inst)) {
        continue;
      }
      Integer step = runner.advanceOneStep(inst, remaining - used);
      if (step > 0) {
        used += step;
      }
    }
    return used;
  }

  private static WorkflowTestHarness.Result assertStabilized(
    WorkflowHarnessContext ctx,
    Integer maxHops
  ) {
    WorkflowHarnessCore.deliverEvents();
    for (Workflow_Instance__c inst : WorkflowHarnessCore.collectTree(ctx)) {
      if (WorkflowHarnessAdvancer.isAdvanceable(ctx, inst)) {
        Workflow_Instance__c root = WorkflowHarnessCore.queryInstance(
          ctx.rootInstanceId
        );
        throw new WorkflowTestHarness.HarnessException(
          'Workflow ' +
            ctx.rootInstanceId +
            ' did not stabilize within ' +
            maxHops +
            ' hop(s). Root status: ' +
            root.Status__c +
            ', current step: ' +
            root.Current_Step__c +
            '. Increase the hop budget passed to drive(), or check for a ' +
            'non-terminating workflow.'
        );
      }
    }
    // Stabilized exactly at the budget boundary.
    return WorkflowHarnessCore.buildResult(ctx);
  }

  private class TreeAdvance {
    Integer used = 0;
    Boolean advancedAny = false;
  }
}
