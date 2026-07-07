@isTest
public class PatchExampleWorkflowTest {
  @isTest
  static void testBrandNewInstanceAdoptsPatch() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'PatchExampleWorkflow.PatchSagaWorkflow',
      'BrandNewSagaKey',
      null
    );

    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

    // 1. Run BookHotel. It should decide insert-flight = true.
    harness.step();

    Workflow_Instance__c inst = [
      SELECT Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'PatchExampleWorkflow.BookFlight',
      inst.Current_Step__c,
      'New instance should adopt the patch and route to BookFlight'
    );

    // 2. Drive to completion
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assert(result.output.contains('"carBooked":true'));
    System.assert(
      result.output.contains('"carType":"Luxury SUV"'),
      'Should have book Luxury SUV because flight was booked'
    );

    // 3. Verify no adoption count since it adopted the patch (insert-flight = true)
    System.assertEquals(
      0,
      WorkflowEngine.getPatchAdoptionCount('insert-flight')
    );
  }

  @isTest
  static void testInFlightInstanceUsesLegacyPathAndCountsAdoption() {
    // 1. Setup an in-flight instance that has already completed BookHotel under the old code.
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'PatchExampleWorkflow.PatchSagaWorkflow',
      'InFlightSagaKey',
      null
    );

    // Lock and update the instance to pretend it already ran BookHotel and is now on BookCar
    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    inst.Current_Step__c = 'PatchExampleWorkflow.BookCar';
    update inst;

    // Create a completed step execution for BookHotel with insert-flight decision as false.
    // Note: Manual seeding of this patch decision is specifically used here to verify that the
    // getPatchAdoptionCount query correctly picks up and counts active instances that have recorded
    // a 'false' decision. In a normal execution flow, the engine automatically resolves and records
    // 'false' for in-flight instances when they first reach a patch decision point, as verified by
    // testInFlightInstanceWithoutPreRecordedPatchDefaultsToFalse.
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = 'PatchExampleWorkflow.BookHotel',
      Status__c = 'Completed',
      Captured_Values__c = '{"hotelBooked":true,"__patch:insert-flight":false}'
    );

    // 2. Since BookHotel recorded false, getPatchAdoptionCount should be 1
    System.assertEquals(
      1,
      WorkflowEngine.getPatchAdoptionCount('insert-flight'),
      'Active instance should count as 1 adoption'
    );

    // 3. Drive BookCar to completion
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assert(result.output.contains('"carBooked":true'));
    System.assert(
      result.output.contains('"carType":"Economy Sedan"'),
      'Should fall back to Economy Sedan because flight was not booked'
    );

    // 4. Once completed (terminal status), the adoption count should drop to 0
    System.assertEquals(
      0,
      WorkflowEngine.getPatchAdoptionCount('insert-flight'),
      'Adoption count should drop to 0 once completed'
    );
  }

  @isTest
  static void testInFlightInstanceWithoutPreRecordedPatchDefaultsToFalse() {
    // 1. Setup an in-flight instance that completed BookHotel under the old code (no patch recorded).
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'PatchExampleWorkflow.PatchSagaWorkflow',
      'InFlightSagaKeyNoDecision',
      null
    );

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    inst.Current_Step__c = 'PatchExampleWorkflow.BookCar';
    update inst;

    // Create a completed step execution for BookHotel without any patch captured value
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = 'PatchExampleWorkflow.BookHotel',
      Status__c = 'Completed',
      Captured_Values__c = '{"hotelBooked":true}'
    );

    // 2. Drive BookCar to completion. Because BookHotel is completed (instance is in-flight),
    // the patch insert-flight must evaluate to false automatically, even without pre-recording.
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assert(result.output.contains('"carBooked":true'));
    System.assert(
      result.output.contains('"carType":"Economy Sedan"'),
      'Should naturally fall back to Economy Sedan because instance was in-flight and did not book flight'
    );
  }

  @isTest
  static void testDeprecatedRetiredPatchThrowsError() {
    Test.startTest();
    // Start with input to trigger retired path exception
    Id instanceId = WorkflowEngine.start(
      'PatchExampleWorkflow.PatchSagaWorkflow',
      'RetiredKey',
      'triggerRetiredError'
    );

    // Insert a running step execution for BookHotel with retired-patch as false to simulate old instance expectation
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = 'PatchExampleWorkflow.BookHotel',
      Status__c = 'Running',
      Input__c = '"triggerRetiredError"',
      Captured_Values__c = '{"__patch:retired-patch":false}'
    );

    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.step();
    Test.stopTest();

    Workflow_Instance__c inst = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Failed',
      inst.Status__c,
      'Instance should have failed due to retired patch'
    );
    System.assert(
      inst.Error_Message__c.contains(
        'retired code path for patch: retired-patch'
      ),
      'Expected retired patch message, got: ' + inst.Error_Message__c
    );
  }
}
