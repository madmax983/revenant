@IsTest
private class StepResultValidationTest {
  @IsTest
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

  @IsTest
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

  @IsTest
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

  @IsTest
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

  @IsTest
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

  @IsTest
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

  @IsTest
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

    // 3. Named query matching default's actual name (hits cache)
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

  @IsTest
  static void testScalarJsonPreservation() {
    // 1. Pre-serialized boolean scalar
    StepResult r1 = StepResult.startChild('ChildWF', 'key', 'true');
    Assert.areEqual(
      'true',
      r1.childInputJson,
      'Should preserve boolean scalar JSON string'
    );

    // 2. Pre-serialized number scalar
    StepResult r2 = StepResult.startChild('ChildWF', 'key', '123.45');
    Assert.areEqual(
      '123.45',
      r2.childInputJson,
      'Should preserve number scalar JSON string'
    );

    // 3. Pre-serialized null scalar
    StepResult r3 = StepResult.startChild('ChildWF', 'key', 'null');
    Assert.areEqual(
      'null',
      r3.childInputJson,
      'Should preserve null scalar JSON string'
    );

    // 4. Pre-serialized string scalar
    StepResult r4 = StepResult.startChild('ChildWF', 'key', '"hello"');
    Assert.areEqual(
      '"hello"',
      r4.childInputJson,
      'Should preserve quoted string scalar JSON string'
    );

    // 5. Pre-serialized object
    StepResult r5 = StepResult.startChild('ChildWF', 'key', '{"foo":"bar"}');
    Assert.areEqual(
      '{"foo":"bar"}',
      r5.childInputJson,
      'Should preserve object JSON string'
    );

    // 6. Pre-serialized array
    StepResult r6 = StepResult.startChild('ChildWF', 'key', '[1, 2, 3]');
    Assert.areEqual(
      '[1, 2, 3]',
      r6.childInputJson,
      'Should preserve array JSON string'
    );

    // 7. Non-JSON plain string (should be serialized)
    StepResult r7 = StepResult.startChild('ChildWF', 'key', 'plain string');
    Assert.areEqual(
      '"plain string"',
      r7.childInputJson,
      'Plain string should be serialized'
    );
  }
}
