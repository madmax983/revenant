@isTest
private class StepResultValidationTest {
  @isTest
  static void testSleepValidation() {
    try {
      StepResult.sleep((Integer) null);
      Assert.fail(
        'Should have thrown IllegalArgumentException for null seconds'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('seconds must be a non-negative integer'),
        'Error message should match'
      );
    }

    try {
      StepResult.sleep(-5);
      Assert.fail(
        'Should have thrown IllegalArgumentException for negative seconds'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('seconds must be a non-negative integer'),
        'Error message should match'
      );
    }

    try {
      StepResult.sleep((Integer) null, 'state');
      Assert.fail(
        'Should have thrown IllegalArgumentException for null seconds in overload'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('seconds must be a non-negative integer'),
        'Error message should match'
      );
    }
  }

  @isTest
  static void testRetryValidation() {
    try {
      StepResult.retry((RetryPolicy) null);
      Assert.fail(
        'Should have thrown IllegalArgumentException for null policy'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('policy must not be null'),
        'Error message should match'
      );
    }
  }

  @isTest
  static void testStartChildValidation() {
    try {
      StepResult.startChild(' ', 'key', null);
      Assert.fail(
        'Should have thrown IllegalArgumentException for blank childWorkflowName'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('childWorkflowName must not be blank'),
        'Error message should match'
      );
    }

    try {
      StepResult.startChild(null, 'key', null);
      Assert.fail(
        'Should have thrown IllegalArgumentException for null childWorkflowName'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('childWorkflowName must not be blank'),
        'Error message should match'
      );
    }
  }

  @isTest
  static void testChildRequestValidation() {
    try {
      new StepResult.ChildRequest(null, 'key', null);
      Assert.fail(
        'Should have thrown IllegalArgumentException for null workflowName'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('workflowName must not be blank'),
        'Error message should match'
      );
    }
  }

  @isTest
  static void testStartChildrenValidation() {
    try {
      StepResult.startChildren((List<StepResult.ChildRequest>) null);
      Assert.fail(
        'Should have thrown IllegalArgumentException for null children'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('children list must not be null or empty'),
        'Error message should match'
      );
    }

    try {
      StepResult.startChildren(new List<StepResult.ChildRequest>());
      Assert.fail(
        'Should have thrown IllegalArgumentException for empty children'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('children list must not be null or empty'),
        'Error message should match'
      );
    }

    try {
      StepResult.startChildren(new List<StepResult.ChildRequest>{ null });
      Assert.fail(
        'Should have thrown IllegalArgumentException for null child element'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('children list must not contain null values'),
        'Error message should match'
      );
    }
  }

  @isTest
  static void testWaitForApprovalValidation() {
    try {
      StepResult.waitForApproval(null, 'Manager');
      Assert.fail('Should have thrown IllegalArgumentException for null key');
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('key must not be blank'),
        'Error message should match'
      );
    }

    try {
      StepResult.waitForApproval(null, 'Manager', 10, 'StepB');
      Assert.fail(
        'Should have thrown IllegalArgumentException for null key in timeout overload'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('key must not be blank'),
        'Error message should match'
      );
    }

    try {
      StepResult.waitForApproval('key', 'Manager', 10, ' ');
      Assert.fail(
        'Should have thrown IllegalArgumentException for blank timeoutStep'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('timeoutStep must not be blank'),
        'Error message should match'
      );
    }

    try {
      StepResult.waitForApproval('key', 'Manager', -5, 'StepB');
      Assert.fail(
        'Should have thrown IllegalArgumentException for negative timeoutSeconds'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('timeoutSeconds must be a positive integer'),
        'Error message should match'
      );
    }
  }

  @isTest
  static void testSplitValidation() {
    try {
      StepResult.split((List<String>) null);
      Assert.fail(
        'Should have thrown IllegalArgumentException for null stepNames'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('stepNames list must not be null or empty'),
        'Error message should match'
      );
    }

    try {
      StepResult.split(new List<String>());
      Assert.fail(
        'Should have thrown IllegalArgumentException for empty stepNames'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage().contains('stepNames list must not be null or empty'),
        'Error message should match'
      );
    }

    try {
      StepResult.split(new List<String>{ 'StepA', ' ' });
      Assert.fail(
        'Should have thrown IllegalArgumentException for blank stepName'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage()
          .contains('stepNames list must not contain null or blank values'),
        'Error message should match'
      );
    }

    try {
      StepResult.split(new List<String>{ 'StepA', ' ' }, 'input');
      Assert.fail(
        'Should have thrown IllegalArgumentException for blank stepName in overload'
      );
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage()
          .contains('stepNames list must not contain null or blank values'),
        'Error message should match'
      );
    }
  }
}
