@IsTest
public class ParallelSagaFanoutWorkflowExampleTest {
  @IsTest
  static void testParallelSagaSuccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      ParallelSagaFanoutWorkflowExample.failBranch3 = false;
      ParallelSagaFanoutWorkflowExample.executionAudit.clear();
      ParallelSagaFanoutWorkflowExample.compensationAudit.clear();

      Id instanceId = WorkflowEngine.start(
        'ParallelSagaFanoutWorkflowExample.ParallelSagaWorkflow',
        'SuccessKey',
        '{}'
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

      // Initial drive to run SpawnStep and suspend on the branch steps
      WorkflowTestHarness.Result result = harness.drive();
      System.assertEquals('Suspended', result.status);

      Test.startTest();
      // Signal all 4 branches to complete using bulkified API
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest(
            instanceId,
            'Branch1_Complete',
            '{}'
          ),
          new WorkflowEngine.SignalRequest(
            instanceId,
            'Branch2_Complete',
            '{}'
          ),
          new WorkflowEngine.SignalRequest(
            instanceId,
            'Branch3_Complete',
            '{}'
          ),
          new WorkflowEngine.SignalRequest(instanceId, 'Branch4_Complete', '{}')
        }
      );

      // Drive the workflow to completion
      result = harness.drive();
      Test.stopTest();

      System.assertEquals(
        'Completed',
        result.status,
        'Workflow should complete successfully'
      );
      System.assertEquals(
        5,
        ParallelSagaFanoutWorkflowExample.executionAudit.size()
      );
      System.assert(
        ParallelSagaFanoutWorkflowExample.executionAudit.contains(
          'Branch1_Execute'
        )
      );
      System.assert(
        ParallelSagaFanoutWorkflowExample.executionAudit.contains(
          'Branch2_Execute'
        )
      );
      System.assert(
        ParallelSagaFanoutWorkflowExample.executionAudit.contains(
          'Branch3_Execute'
        )
      );
      System.assert(
        ParallelSagaFanoutWorkflowExample.executionAudit.contains(
          'Branch4_Execute'
        )
      );
      System.assert(
        ParallelSagaFanoutWorkflowExample.executionAudit.contains(
          'Join_Execute'
        )
      );
      System.assertEquals(
        0,
        ParallelSagaFanoutWorkflowExample.compensationAudit.size()
      );

      // Verify joined outputs in the workflow instance output
      Workflow_Instance__c completedInst = [
        SELECT Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
        WITH SYSTEM_MODE
      ];
      Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(
        WorkflowPayloadOffload.resolvePayload(completedInst.Output__c)
      );
      System.assertNotEquals(null, outputMap, 'Output should be present');
      System.assert(
        outputMap.containsKey('ParallelSagaFanoutWorkflowExample.Branch1Step'),
        'Output should contain Branch 1 payload'
      );
      System.assertEquals(
        1,
        ((Map<String, Object>) outputMap.get(
            'ParallelSagaFanoutWorkflowExample.Branch1Step'
          ))
          .get('branch')
      );
      System.assertEquals(
        'Completed',
        ((Map<String, Object>) outputMap.get(
            'ParallelSagaFanoutWorkflowExample.Branch1Step'
          ))
          .get('status')
      );
    }
  }

  @IsTest
  static void testParallelSagaFailureRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      ParallelSagaFanoutWorkflowExample.failBranch3 = true;
      ParallelSagaFanoutWorkflowExample.executionAudit.clear();
      ParallelSagaFanoutWorkflowExample.compensationAudit.clear();

      Id instanceId = WorkflowEngine.start(
        'ParallelSagaFanoutWorkflowExample.ParallelSagaWorkflow',
        'FailureKey',
        '{}'
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

      // Initial drive to run SpawnStep and suspend on the branch steps
      WorkflowTestHarness.Result result = harness.drive();
      System.assertEquals('Suspended', result.status);

      // Signal Branch1 and Branch2 to complete, and Branch3 to fail using bulkified API
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest(
            instanceId,
            'Branch1_Complete',
            '{}'
          ),
          new WorkflowEngine.SignalRequest(
            instanceId,
            'Branch2_Complete',
            '{}'
          ),
          new WorkflowEngine.SignalRequest(instanceId, 'Branch3_Complete', '{}')
        }
      );

      Test.startTest();
      // Drive the workflow to completion (this will run Branch1 and 2 to completion,
      // then Branch3 will run and fail, cancel Branch4, and roll back 2 and 1)
      result = harness.drive();
      Test.stopTest();

      System.assertEquals(
        'Compensated',
        result.status,
        'Workflow should be fully compensated'
      );

      // Verify executions: Branch 1, 2, and 3 ran. Branch 4 never ran.
      System.assertEquals(
        3,
        ParallelSagaFanoutWorkflowExample.executionAudit.size()
      );
      System.assertEquals(
        'Branch1_Execute',
        ParallelSagaFanoutWorkflowExample.executionAudit[0]
      );
      System.assertEquals(
        'Branch2_Execute',
        ParallelSagaFanoutWorkflowExample.executionAudit[1]
      );
      System.assertEquals(
        'Branch3_Execute',
        ParallelSagaFanoutWorkflowExample.executionAudit[2]
      );

      // Verify compensations: only completed branches (Branch 2 and Branch 1) are compensated in LIFO order
      System.assertEquals(
        2,
        ParallelSagaFanoutWorkflowExample.compensationAudit.size()
      );
      System.assertEquals(
        'Branch2_Compensate',
        ParallelSagaFanoutWorkflowExample.compensationAudit[0]
      );
      System.assertEquals(
        'Branch1_Compensate',
        ParallelSagaFanoutWorkflowExample.compensationAudit[1]
      );

      // Verify compensated steps from result object
      System.assertEquals(
        new List<String>{
          'ParallelSagaFanoutWorkflowExample.Branch2Step_Compensate',
          'ParallelSagaFanoutWorkflowExample.Branch1Step_Compensate'
        },
        result.compensatedSteps,
        'Compensations must run in LIFO order for the completed branches'
      );
    }
  }

  @IsTest
  static void testParallelSagaRedeliveredSignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      ParallelSagaFanoutWorkflowExample.failBranch3 = true;
      ParallelSagaFanoutWorkflowExample.executionAudit.clear();
      ParallelSagaFanoutWorkflowExample.compensationAudit.clear();

      Id instanceId = WorkflowEngine.start(
        'ParallelSagaFanoutWorkflowExample.ParallelSagaWorkflow',
        'SignalRedeliveryKey',
        '{}'
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

      // Initial drive to run SpawnStep and suspend on the branch steps
      harness.drive();

      // Signal Branch1 and Branch2 to complete, and Branch3 to fail using bulkified API
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest(
            instanceId,
            'Branch1_Complete',
            '{}'
          ),
          new WorkflowEngine.SignalRequest(
            instanceId,
            'Branch2_Complete',
            '{}'
          ),
          new WorkflowEngine.SignalRequest(instanceId, 'Branch3_Complete', '{}')
        }
      );

      Test.startTest();
      // Run Branch1, Branch2, and Branch3 steps.
      // Branch 3 will fail and transition the instance to Compensating.
      try {
        harness.drive(3);
      } catch (WorkflowTestHarness.HarnessException ignored) {
        // Expected: budget exhausted during rollback before stabilization
      }
      Workflow_Instance__c freshInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
        WITH SYSTEM_MODE
      ];
      System.assertEquals(
        'Compensating',
        freshInst.Status__c,
        'Should transition to Compensating status'
      );

      // While in Compensating status, deliver duplicate signals in bulk:
      // 1. Redelivered signal for completed Branch2
      // 2. Late-arriving signal for cancelled Branch4
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest(
            instanceId,
            'Branch2_Complete',
            '{}'
          ),
          new WorkflowEngine.SignalRequest(instanceId, 'Branch4_Complete', '{}')
        }
      );

      // Drive the workflow to stabilization/completion
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals('Compensated', result.status);

      // Verify compensations ran exactly once for completed branches, and none for Branch4/Branch3
      System.assertEquals(
        2,
        ParallelSagaFanoutWorkflowExample.compensationAudit.size()
      );
      System.assertEquals(
        'Branch2_Compensate',
        ParallelSagaFanoutWorkflowExample.compensationAudit[0]
      );
      System.assertEquals(
        'Branch1_Compensate',
        ParallelSagaFanoutWorkflowExample.compensationAudit[1]
      );
    }
  }
}
