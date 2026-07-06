public inherited sharing class ParallelSagaFanoutWorkflowExample {
  public static Boolean failBranch3 = true;
  public static List<String> executionAudit = new List<String>();
  public static List<String> compensationAudit = new List<String>();

  public inherited sharing class ParallelSagaWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'ParallelSagaFanoutWorkflowExample.SpawnStep',
        'ParallelSagaFanoutWorkflowExample.Branch1Step',
        'ParallelSagaFanoutWorkflowExample.Branch2Step',
        'ParallelSagaFanoutWorkflowExample.Branch3Step',
        'ParallelSagaFanoutWorkflowExample.Branch4Step',
        'ParallelSagaFanoutWorkflowExample.JoinStep'
      };
    }

    public String getInitialStep() {
      return 'ParallelSagaFanoutWorkflowExample.SpawnStep';
    }

    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'ParallelSagaFanoutWorkflowExample.SpawnStep') {
        return 'ParallelSagaFanoutWorkflowExample.JoinStep';
      }
      return null;
    }
  }

  public inherited sharing class SpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'ParallelSagaFanoutWorkflowExample.Branch1Step',
          'ParallelSagaFanoutWorkflowExample.Branch2Step',
          'ParallelSagaFanoutWorkflowExample.Branch3Step',
          'ParallelSagaFanoutWorkflowExample.Branch4Step'
        },
        ctx.inputJson
      );
    }
  }

  public inherited sharing class Branch1Step implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal sig = ctx.getSignal('Branch1_Complete');
      if (!sig.isPresent()) {
        return StepResult.suspend();
      }
      executionAudit.add('Branch1_Execute');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 1, 'status' => 'Completed' }
      );
    }

    public StepResult compensate(StepContext ctx) {
      if (String.isNotBlank(ctx.stepStateJson)) {
        Map<String, Object> state = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.stepStateJson
        );
        System.debug(
          LoggingLevel.INFO,
          'Compensating branch 1 with state: ' + state
        );
      }
      compensationAudit.add('Branch1_Compensate');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 1, 'status' => 'Compensated' }
      );
    }
  }

  public inherited sharing class Branch2Step implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal sig = ctx.getSignal('Branch2_Complete');
      if (!sig.isPresent()) {
        return StepResult.suspend();
      }
      executionAudit.add('Branch2_Execute');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 2, 'status' => 'Completed' }
      );
    }

    public StepResult compensate(StepContext ctx) {
      if (String.isNotBlank(ctx.stepStateJson)) {
        Map<String, Object> state = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.stepStateJson
        );
        System.debug(
          LoggingLevel.INFO,
          'Compensating branch 2 with state: ' + state
        );
      }
      compensationAudit.add('Branch2_Compensate');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 2, 'status' => 'Compensated' }
      );
    }
  }

  public inherited sharing class Branch3Step implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal sig = ctx.getSignal('Branch3_Complete');
      if (!sig.isPresent()) {
        return StepResult.suspend();
      }
      executionAudit.add('Branch3_Execute');
      if (failBranch3) {
        throw new WorkflowEngine.WorkflowException('Branch 3 induced failure');
      }
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 3, 'status' => 'Completed' }
      );
    }

    public StepResult compensate(StepContext ctx) {
      if (String.isNotBlank(ctx.stepStateJson)) {
        Map<String, Object> state = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.stepStateJson
        );
        System.debug(
          LoggingLevel.INFO,
          'Compensating branch 3 with state: ' + state
        );
      }
      compensationAudit.add('Branch3_Compensate');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 3, 'status' => 'Compensated' }
      );
    }
  }

  public inherited sharing class Branch4Step implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal sig = ctx.getSignal('Branch4_Complete');
      if (!sig.isPresent()) {
        return StepResult.suspend();
      }
      executionAudit.add('Branch4_Execute');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 4, 'status' => 'Completed' }
      );
    }

    public StepResult compensate(StepContext ctx) {
      if (String.isNotBlank(ctx.stepStateJson)) {
        Map<String, Object> state = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.stepStateJson
        );
        System.debug(
          LoggingLevel.INFO,
          'Compensating branch 4 with state: ' + state
        );
      }
      compensationAudit.add('Branch4_Compensate');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'branch' => 4, 'status' => 'Compensated' }
      );
    }
  }

  public inherited sharing class JoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      executionAudit.add('Join_Execute');
      Object parsedInput = String.isNotBlank(ctx.inputJson)
        ? JSON.deserializeUntyped(ctx.inputJson)
        : null;
      return StepResult.complete(null, parsedInput);
    }
  }
}
