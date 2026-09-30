/**
 * @description Tests for input-contract checks on internal start paths (issue
 * #227): single child start, bulk child start and continue-as-new. The class is
 * `public` so the engine can find the fixtures in `ApexTypeImplementor`.
 */
@IsTest
public class WorkflowInternalStartValidationTest {
  private static final String CONTRACT_WF = 'WorkflowInputValidationTest.ContractWorkflow';
  private static final String PLAIN_WF = 'WorkflowEngineTest.HappyWorkflow';
  private static final String CAN_WF = 'WorkflowInternalStartValidationTest.CanWorkflow';

  // Input for the continue-as-new step. Tests set it before the run.
  public static Object nextInput;

  /** @description Validated workflow that continues as new. */
  public class CanWorkflow implements WorkflowDefinition, ValidatedWorkflow {
    /**
     * @description Declares the input contract.
     * @return The required fields.
     */
    public WorkflowInputContract getInputContract() {
      return new WorkflowInputContract()
        .require('accountId', WorkflowInputType.STRING_TYPE)
        .require('amount', WorkflowInputType.DECIMAL_TYPE);
    }

    /**
     * @description Declares the step list.
     * @return The one step.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowInternalStartValidationTest.CanStep' };
    }

    /**
     * @description Returns the first step.
     * @return The step name.
     */
    public String getInitialStep() {
      return 'WorkflowInternalStartValidationTest.CanStep';
    }

    /**
     * @description Ends the workflow after the step.
     * @param currentStepName The finished step.
     * @param stepResult The step result.
     * @return Always null.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /** @description Continues as new once, then completes. */
  public class CanStep implements WorkflowStep {
    /**
     * @description Continues as new on the first run.
     * @param ctx The step context.
     * @return A continue-as-new or complete result.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.previousRunAt != null) {
        return StepResult.complete(null, 'done');
      }
      return StepResult.continueAsNew(nextInput);
    }
  }

  private static Map<String, Object> validInput() {
    return new Map<String, Object>{ 'accountId' => 'A-1', 'amount' => 10 };
  }

  private static Id startParent() {
    WorkflowEngine.disableQueueableInTest = true;
    return WorkflowEngine.start(
      PLAIN_WF,
      'P_' + Crypto.getRandomInteger(),
      null
    );
  }

  private static WorkflowChildService.ChildWorkflowStartRequest childReq(
    Id parentId,
    String wf,
    String key,
    String inputJson
  ) {
    WorkflowChildService.ChildWorkflowStartRequest req = new WorkflowChildService.ChildWorkflowStartRequest();
    req.parentId = parentId;
    req.workflowName = wf;
    req.correlationKey = key;
    req.inputJson = inputJson;
    return req;
  }

  private static Integer childCount(String key) {
    return [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :key
    ];
  }

  // ── Single child ────────────────────────────────────────────────────────────

  @IsTest
  static void testChildMissingFieldRejectedBeforeInsert() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      WorkflowInputException caught;
      try {
        WorkflowChildService.startChildWorkflow(
          childReq(parentId, CONTRACT_WF, 'C_missing', '{"amount":5}')
        );
      } catch (WorkflowInputException ex) {
        caught = ex;
      }
      System.assertNotEquals(null, caught, 'Missing field must be rejected');
      System.assertEquals('accountId', caught.getFieldErrors()[0].fieldName);
      System.assertEquals(
        WorkflowInputErrorReason.MISSING,
        caught.getFieldErrors()[0].reason
      );
      System.assertEquals(0, childCount('C_missing'), 'No child row');
    }
  }

  @IsTest
  static void testChildWrongTypeRejected() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      WorkflowInputException caught;
      try {
        WorkflowChildService.startChildWorkflow(
          childReq(
            parentId,
            CONTRACT_WF,
            'C_wrong',
            '{"accountId":"A","amount":"lots"}'
          )
        );
      } catch (WorkflowInputException ex) {
        caught = ex;
      }
      System.assertNotEquals(null, caught, 'Wrong type must be rejected');
      System.assertEquals('amount', caught.getFieldErrors()[0].fieldName);
      System.assertEquals(
        WorkflowInputErrorReason.WRONG_TYPE,
        caught.getFieldErrors()[0].reason
      );
      System.assertEquals(0, childCount('C_wrong'));
    }
  }

  @IsTest
  static void testChildNullInputRejected() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      Boolean threw = false;
      try {
        WorkflowChildService.startChildWorkflow(
          childReq(parentId, CONTRACT_WF, 'C_null', null)
        );
      } catch (WorkflowInputException ex) {
        threw = true;
      }
      System.assert(threw, 'Null input must fail required fields');
      System.assertEquals(0, childCount('C_null'));
    }
  }

  @IsTest
  static void testChildValidInputStarts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      WorkflowChildService.startChildWorkflow(
        childReq(parentId, CONTRACT_WF, 'C_ok', JSON.serialize(validInput()))
      );
      System.assertEquals(1, childCount('C_ok'));
    }
  }

  @IsTest
  static void testChildWithoutContractUnaffected() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      WorkflowChildService.startChildWorkflow(
        childReq(parentId, PLAIN_WF, 'C_plain', null)
      );
      System.assertEquals(1, childCount('C_plain'));
    }
  }

  @IsTest
  static void testChildDedupHitNotValidated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      WorkflowChildService.startChildWorkflow(
        childReq(parentId, CONTRACT_WF, 'C_dup', JSON.serialize(validInput()))
      );
      // Same key under the same parent: idempotent, bad input never persisted.
      WorkflowChildService.startChildWorkflow(
        childReq(parentId, CONTRACT_WF, 'C_dup', '{}')
      );
      System.assertEquals(1, childCount('C_dup'));
    }
  }

  @IsTest
  static void testChildMalformedJsonRejected() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      WorkflowInputException caught;
      try {
        WorkflowChildService.startChildWorkflow(
          childReq(parentId, CONTRACT_WF, 'C_json', '{bad')
        );
      } catch (WorkflowInputException ex) {
        caught = ex;
      }
      System.assertNotEquals(null, caught, 'Malformed JSON must be rejected');
      System.assertEquals(
        WorkflowInputErrorReason.MALFORMED_JSON,
        caught.getFieldErrors()[0].reason
      );
      System.assertEquals(0, childCount('C_json'));
    }
  }

  @IsTest
  static void testBulkChildrenMessageListsEveryBadChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      WorkflowInputException caught;
      try {
        WorkflowChildBulkService.startChildWorkflows(
          parentId,
          new List<StepResult.ChildRequest>{
            new StepResult.ChildRequest(
              CONTRACT_WF,
              'B_bad1',
              new Map<String, Object>()
            ),
            new StepResult.ChildRequest(
              CONTRACT_WF,
              'B_bad2',
              new Map<String, Object>()
            )
          }
        );
      } catch (WorkflowInputException ex) {
        caught = ex;
      }
      System.assertNotEquals(null, caught, 'Bad children must be rejected');
      System.assert(
        caught.getMessage().contains('B_bad1'),
        caught.getMessage()
      );
      System.assert(
        caught.getMessage().contains('B_bad2'),
        caught.getMessage()
      );
    }
  }

  // ── Bulk children ───────────────────────────────────────────────────────────

  @IsTest
  static void testBulkChildrenInvalidRejectsWholeBatch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      List<StepResult.ChildRequest> reqs = new List<StepResult.ChildRequest>{
        new StepResult.ChildRequest(CONTRACT_WF, 'B_good', validInput()),
        new StepResult.ChildRequest(
          CONTRACT_WF,
          'B_bad',
          new Map<String, Object>{ 'amount' => 1 }
        )
      };
      WorkflowInputException caught;
      try {
        WorkflowChildBulkService.startChildWorkflows(parentId, reqs);
      } catch (WorkflowInputException ex) {
        caught = ex;
      }
      System.assertNotEquals(null, caught, 'Bad child must reject the batch');
      System.assert(caught.getMessage().contains('B_bad'), caught.getMessage());
      System.assertEquals(0, childCount('B_good'), 'All or none');
      System.assertEquals(0, childCount('B_bad'));
    }
  }

  @IsTest
  static void testBulkChildrenValidStart() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      WorkflowChildBulkService.startChildWorkflows(
        parentId,
        new List<StepResult.ChildRequest>{
          new StepResult.ChildRequest(CONTRACT_WF, 'B_1', validInput()),
          new StepResult.ChildRequest(CONTRACT_WF, 'B_2', validInput())
        }
      );
      System.assertEquals(1, childCount('B_1'));
      System.assertEquals(1, childCount('B_2'));
    }
  }

  @IsTest
  static void testBulkChildDedupHitNotValidated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = startParent();
      WorkflowChildBulkService.startChildWorkflows(
        parentId,
        new List<StepResult.ChildRequest>{
          new StepResult.ChildRequest(CONTRACT_WF, 'B_dup', validInput())
        }
      );
      WorkflowChildBulkService.startChildWorkflows(
        parentId,
        new List<StepResult.ChildRequest>{
          new StepResult.ChildRequest(
            CONTRACT_WF,
            'B_dup',
            new Map<String, Object>()
          ),
          new StepResult.ChildRequest(PLAIN_WF, 'B_plain', null)
        }
      );
      System.assertEquals(1, childCount('B_dup'));
      System.assertEquals(1, childCount('B_plain'));
    }
  }

  // ── Continue-as-new ─────────────────────────────────────────────────────────

  private static Integer successorCount(Id predecessorId) {
    return [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :predecessorId
    ];
  }

  @IsTest
  static void testContinueAsNewInvalidInputCreatesNoSuccessor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      nextInput = new Map<String, Object>{ 'amount' => 'lots' };
      Id id = WorkflowEngine.start(CAN_WF, 'CAN_bad', validInput());
      // The harness hands a thrown step to the crash handler.
      new WorkflowTestHarness(id).drive();
      System.assertEquals(0, successorCount(id), 'No successor row');
      System.assertEquals(
        'Failed',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :id].Status__c,
        'Predecessor must fail, not continue'
      );
    }
  }

  @IsTest
  static void testContinueAsNewWithoutContractUnaffected() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowInputValidator.validateContinuation(PLAIN_WF, '{"x":1}');
      WorkflowInputValidator.validateContinuation(PLAIN_WF, null);
      System.assert(true, 'A workflow without a contract never throws');
    }
  }

  @IsTest
  static void testContinueAsNewValidInputCreatesSuccessor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      nextInput = validInput();
      Id id = WorkflowEngine.start(CAN_WF, 'CAN_ok', validInput());
      new WorkflowTestHarness(id).drive();
      System.assertEquals(1, successorCount(id), 'Successor created');
    }
  }
}
