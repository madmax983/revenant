@IsTest
private class VerifyWorkflowHelperTest {
  /**
   * Issue #283: the successor key comes from once(), so a replay gives the same key.
   */
  @IsTest
  static void successorKeyUsesCapturedTime() {
    StepContext ctx = new StepContextTestBuilder().once('nowMs', '42').build();

    StepResult result = new VerifyWorkflowHelper.TimeoutContinueStep()
      .execute(ctx);

    Assert.areEqual(
      'SuccessorKey_42',
      result.directive().continuation.newCorrelationKey
    );
  }
}
