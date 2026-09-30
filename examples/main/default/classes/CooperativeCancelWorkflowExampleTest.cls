/**
 * @description Tests for `CooperativeCancelWorkflowExample` (issue #143). A
 * test tagger cancels the instance in the same transaction, during a batch. A
 * real cancel from another transaction waits for the step row lock (ADR 0017).
 * The loop must stop at its next check.
 */
@IsTest
private class CooperativeCancelWorkflowExampleTest {
  private static final String WORKFLOW = 'CooperativeCancelWorkflowExample.CooperativeCancelWorkflow';
  private static final String TAG_STEP = 'CooperativeCancelWorkflowExample.TagAccountsStep';
  private static final String RESERVE_STEP = 'CooperativeCancelWorkflowExample.ReserveQuotaStep';

  /**
   * @description Cancels the instance on its first batch, before the DML. Then
   * it tags the batch with the real tagger.
   */
  private class CancellingTagger implements CooperativeCancelWorkflowExample.AccountTagger {
    private Id instanceId;
    private Boolean withCompensation;
    private Integer calls = 0;

    /**
     * @description Makes the tagger.
     * @param instanceId The instance to cancel.
     * @param withCompensation True to roll back completed steps.
     */
    public CancellingTagger(Id instanceId, Boolean withCompensation) {
      this.instanceId = instanceId;
      this.withCompensation = withCompensation;
    }

    /**
     * @description Cancels on the first call, then tags the batch.
     * @param batch The records to tag.
     */
    public void tag(List<Account> batch) {
      if (this.calls == 0) {
        WorkflowEngine.cancel(this.instanceId, this.withCompensation);
      }
      this.calls++;
      new CooperativeCancelWorkflowExample.DescriptionTagger().tag(batch);
    }
  }

  private static void insertAccounts(Integer count) {
    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < count; i++) {
      accounts.add(
        new Account(Name = 'Coop ' + String.valueOf(i).leftPad(3, '0'))
      );
    }
    insert accounts;
  }

  private static Integer taggedCount() {
    Integer tagged = 0;
    for (Account acc : [SELECT Description FROM Account]) {
      if (acc.Description == CooperativeCancelWorkflowExample.TAG) {
        tagged++;
      }
    }
    return tagged;
  }

  private static String statusOf(Id instanceId) {
    return [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
    .Status__c;
  }

  private static List<Workflow_Step_Execution__c> rowsOf(
    Id instanceId,
    String stepName
  ) {
    return [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :stepName
      ORDER BY CreatedDate ASC, Id ASC
    ];
  }

  private static void driveToTerminal(Id instanceId) {
    for (Integer hop = 0; hop < 5; hop++) {
      if (WorkflowCancellation.isTerminalForCancel(statusOf(instanceId))) {
        return;
      }
      WorkflowEngine.runStep(instanceId, null);
    }
  }

  private static void assertNoCompletedTagRow(Id instanceId) {
    for (Workflow_Step_Execution__c row : rowsOf(instanceId, TAG_STEP)) {
      Assert.areNotEqual('Completed', row.Status__c);
    }
  }

  @IsTest
  static void cancelDuringFirstRunStopsAtNextCheck() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insertAccounts(20);
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(WORKFLOW, 'CoopCancel_1', null);
      WorkflowEngine.runStep(instanceId, null); // ReserveQuotaStep
      CooperativeCancelWorkflowExample.tagger = new CancellingTagger(
        instanceId,
        true
      );

      WorkflowEngine.runStep(instanceId, null); // TagAccountsStep

      Assert.areEqual(
        CooperativeCancelWorkflowExample.CHECK_EVERY,
        taggedCount(),
        'Only the batch in flight at the cancel commits'
      );
      Assert.areEqual('Cancelling', statusOf(instanceId));
      assertNoCompletedTagRow(instanceId);

      driveToTerminal(instanceId);

      Assert.areEqual('Cancelled', statusOf(instanceId));
      List<Workflow_Step_Execution__c> comp = rowsOf(
        instanceId,
        RESERVE_STEP + '_Compensate'
      );
      Assert.isFalse(comp.isEmpty(), 'The reserve step was rolled back');
      Assert.areEqual('Compensated', comp[comp.size() - 1].Status__c);
      Assert.areEqual(
        CooperativeCancelWorkflowExample.CHECK_EVERY,
        taggedCount(),
        'No work commits after the stop'
      );
      assertNoCompletedTagRow(instanceId);
    }
  }

  @IsTest
  static void cancelDuringLaterRunStopsAtNextCheck() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insertAccounts(20);
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(WORKFLOW, 'CoopCancel_2', null);
      WorkflowEngine.runStep(instanceId, null); // ReserveQuotaStep
      WorkflowEngine.runStep(instanceId, null); // first run: yields
      Assert.areEqual(
        CooperativeCancelWorkflowExample.RUN_LIMIT,
        taggedCount()
      );
      CooperativeCancelWorkflowExample.tagger = new CancellingTagger(
        instanceId,
        false
      );

      WorkflowEngine.runStep(instanceId, null); // second run: sees the cancel

      Assert.areEqual(
        CooperativeCancelWorkflowExample.RUN_LIMIT +
        CooperativeCancelWorkflowExample.CHECK_EVERY,
        taggedCount()
      );
      Assert.areEqual('Cancelled', statusOf(instanceId));
      List<Workflow_Step_Execution__c> rows = rowsOf(instanceId, TAG_STEP);
      Assert.areEqual('Cancelled', rows[rows.size() - 1].Status__c);
      assertNoCompletedTagRow(instanceId);
    }
  }

  @IsTest
  static void runsToCompletionWithoutCancel() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insertAccounts(12);
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(WORKFLOW, 'CoopCancel_3', null);

      for (Integer hop = 0; hop < 4; hop++) {
        WorkflowEngine.runStep(instanceId, null);
      }

      Assert.areEqual('Completed', statusOf(instanceId));
      Assert.areEqual(12, taggedCount());
    }
  }

  @IsTest
  static void stepStopsWhenTestBuilderRequestsCancel() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insertAccounts(20);
      StepContext ctx = new StepContextTestBuilder()
        .requestCancellation()
        .build();

      StepResult result = new CooperativeCancelWorkflowExample.TagAccountsStep()
        .execute(ctx);

      Assert.areEqual(StepResult.ActionType.YIELD, result.directive().action);
      Assert.areEqual(
        CooperativeCancelWorkflowExample.CHECK_EVERY,
        taggedCount(),
        'Check 1 is true: the loop stops after batch 1, not at RUN_LIMIT'
      );
    }
  }

  @IsTest
  static void stepRunsFullBatchesWithoutCancel() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insertAccounts(20);
      StepContext ctx = new StepContextTestBuilder().build();

      StepResult result = new CooperativeCancelWorkflowExample.TagAccountsStep()
        .execute(ctx);

      Assert.areEqual(StepResult.ActionType.YIELD, result.directive().action);
      Assert.areEqual(
        CooperativeCancelWorkflowExample.RUN_LIMIT,
        taggedCount(),
        'With no cancel, the run tags RUN_LIMIT records'
      );
    }
  }
}
