/**
 * @description Unit tests for opt-in workflow start-input validation (issue #51):
 * the {@link ValidatedWorkflow} contract, the scalar and bulk start hooks in
 * {@link WorkflowInputValidator}, and the branchable {@link
 * WorkflowStartInvocableAction} outputs. The `ContractWorkflow` fixture below
 * implements both {@link WorkflowDefinition} (so the engine authorizes it) and
 * {@link ValidatedWorkflow} (so its start input is validated).
 *
 * This class is declared `public` (not `private`) on purpose: the engine
 * authorizes a workflow by looking it up in `ApexTypeImplementor`
 * (WorkflowStartInstanceBuilder.validateWorkflowAuthorization), which only
 * surfaces public/global implementors. A `public` inner fixture of a `private`
 * outer test class is not enumerable there and would fail authorization, so the
 * outer class matches the proven shared-fixture pattern of the public
 * `WorkflowEngineTest`.
 */
@IsTest
public class WorkflowInputValidationTest {
  private static final String CONTRACT_WF = 'WorkflowInputValidationTest.ContractWorkflow';
  private static final String PLAIN_WF = 'WorkflowEngineTest.HappyWorkflow';

  // ── Fixtures ────────────────────────────────────────────────────────────────

  /**
   * @description Validated workflow fixture: requires a String `accountId` and a
   * numeric `amount`; type-checks optional `vipOnboarding` (Boolean) and
   * `startDate` (Date) when present.
   */
  public class ContractWorkflow implements WorkflowDefinition, ValidatedWorkflow {
    /**
     * @description Declares the fixture's input contract.
     * @return The required/optional field contract.
     */
    public WorkflowInputContract getInputContract() {
      return new WorkflowInputContract()
        .require('accountId', WorkflowInputType.STRING_TYPE)
        .require('amount', WorkflowInputType.DECIMAL_TYPE)
        .optional('vipOnboarding', WorkflowInputType.BOOLEAN_TYPE)
        .optional('startDate', WorkflowInputType.DATE_TYPE);
    }

    /**
     * @description Declares the fixture's single step.
     * @return The one-element step inventory.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowInputValidationTest.WelcomeStep' };
    }

    /**
     * @description Returns the fixture's initial step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowInputValidationTest.WelcomeStep';
    }

    /**
     * @description Ends the workflow after the single step.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /** @description Trivial terminal step for the ContractWorkflow fixture. */
  public class WelcomeStep implements WorkflowStep {
    /**
     * @description Completes immediately.
     * @param ctx The durable step context.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'ok');
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  private static Integer instanceCountForKey(String key) {
    return [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :key
    ];
  }

  private static Integer stepExecCountForKey(String key) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__r.Correlation_Key__c = :key
    ];
  }

  private static Map<String, Object> validInput() {
    return new Map<String, Object>{
      'accountId' => 'ACME-ACCOUNT-1',
      'amount' => 2500,
      'vipOnboarding' => true,
      'startDate' => '2026-07-19'
    };
  }

  // ── Scalar path ─────────────────────────────────────────────────────────────

  @IsTest
  static void testValidInputStartsScalar() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Test.startTest();
      WorkflowEngine.StartResult res = WorkflowEngine.startOrGet(
        new WorkflowEngine.StartRequest(CONTRACT_WF, 'VIV_valid', validInput())
      );
      Test.stopTest();
      System.assertEquals(
        true,
        res.isNew,
        'Valid input should start a new instance'
      );
      System.assertEquals(1, instanceCountForKey('VIV_valid'));
    }
  }

  @IsTest
  static void testMissingRequiredFieldThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Map<String, Object> input = new Map<String, Object>{ 'amount' => 10 };
      Boolean threw = false;
      try {
        WorkflowEngine.start(CONTRACT_WF, 'VIV_missing', input);
      } catch (WorkflowInputException ex) {
        threw = true;
        System.assertEquals(1, ex.getFieldErrors().size());
        WorkflowInputFieldError fe = ex.getFieldErrors()[0];
        System.assertEquals('accountId', fe.fieldName);
        System.assertEquals(WorkflowInputErrorReason.MISSING, fe.reason);
        System.assert(
          ex.getMessage().contains('accountId'),
          'Message should name the missing field: ' + ex.getMessage()
        );
      }
      System.assertEquals(true, threw, 'Missing required field must throw');
      System.assertEquals(
        0,
        instanceCountForKey('VIV_missing'),
        'No instance may be created on rejection'
      );
      System.assertEquals(
        0,
        stepExecCountForKey('VIV_missing'),
        'No step-execution audit row may be written on rejection'
      );
    }
  }

  @IsTest
  static void testWrongTypeThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, Object> input = new Map<String, Object>{
        'accountId' => 'ACME-ACCOUNT-1',
        'amount' => 'not-a-number'
      };
      Boolean threw = false;
      try {
        WorkflowEngine.start(CONTRACT_WF, 'VIV_wrongtype', input);
      } catch (WorkflowInputException ex) {
        threw = true;
        System.assertEquals(1, ex.getFieldErrors().size());
        WorkflowInputFieldError fe = ex.getFieldErrors()[0];
        System.assertEquals('amount', fe.fieldName);
        System.assertEquals(WorkflowInputErrorReason.WRONG_TYPE, fe.reason);
        System.assertEquals(WorkflowInputType.DECIMAL_TYPE, fe.expectedType);
        System.assertEquals('String', fe.actualType);
      }
      System.assertEquals(true, threw, 'Wrong-typed field must throw');
      System.assertEquals(0, instanceCountForKey('VIV_wrongtype'));
    }
  }

  @IsTest
  static void testMultipleBadFieldsAllEnumerated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Missing accountId AND wrong-typed amount AND wrong-typed vipOnboarding.
      Map<String, Object> input = new Map<String, Object>{
        'amount' => 'oops',
        'vipOnboarding' => 'yes'
      };
      Boolean threw = false;
      try {
        WorkflowEngine.start(CONTRACT_WF, 'VIV_multi', input);
      } catch (WorkflowInputException ex) {
        threw = true;
        System.assertEquals(
          3,
          ex.getFieldErrors().size(),
          'All three violations must be enumerated, not just the first'
        );
        System.assert(ex.getMessage().contains('accountId'));
        System.assert(ex.getMessage().contains('amount'));
        System.assert(ex.getMessage().contains('vipOnboarding'));
      }
      System.assertEquals(true, threw);
      System.assertEquals(0, instanceCountForKey('VIV_multi'));
    }
  }

  @IsTest
  static void testMalformedJsonThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean threw = false;
      try {
        // Malformed JSON string passed as the start input.
        WorkflowEngine.start(CONTRACT_WF, 'VIV_malformed', '{"accountId":');
      } catch (WorkflowInputException ex) {
        threw = true;
        System.assertEquals(1, ex.getFieldErrors().size());
        System.assertEquals(
          WorkflowInputErrorReason.MALFORMED_JSON,
          ex.getFieldErrors()[0].reason
        );
      }
      System.assertEquals(true, threw, 'Malformed JSON is an input error');
      System.assertEquals(0, instanceCountForKey('VIV_malformed'));
    }
  }

  @IsTest
  static void testDateFieldRejectsBadValue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, Object> input = new Map<String, Object>{
        'accountId' => 'ACME-ACCOUNT-1',
        'amount' => 10,
        'startDate' => 'not-a-date'
      };
      Boolean threw = false;
      try {
        WorkflowEngine.start(CONTRACT_WF, 'VIV_baddate', input);
      } catch (WorkflowInputException ex) {
        threw = true;
        System.assertEquals('startDate', ex.getFieldErrors()[0].fieldName);
        System.assertEquals(
          WorkflowInputErrorReason.WRONG_TYPE,
          ex.getFieldErrors()[0].reason
        );
      }
      System.assertEquals(true, threw);
    }
  }

  @IsTest
  static void testNonValidatedWorkflowSkipsValidation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // HappyWorkflow does not implement ValidatedWorkflow: any input is accepted.
      Test.startTest();
      Id instanceId = WorkflowEngine.start(PLAIN_WF, 'VIV_plain', 'anything');
      Test.stopTest();
      System.assertNotEquals(null, instanceId);
      System.assertEquals(1, instanceCountForKey('VIV_plain'));
    }
  }

  // ── Bulk path ───────────────────────────────────────────────────────────────

  @IsTest
  static void testBulkAllValidStarts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      List<WorkflowEngine.StartRequest> reqs = new List<WorkflowEngine.StartRequest>{
        new WorkflowEngine.StartRequest(
          CONTRACT_WF,
          'VIV_bulk_ok1',
          validInput()
        ),
        new WorkflowEngine.StartRequest(
          CONTRACT_WF,
          'VIV_bulk_ok2',
          validInput()
        )
      };
      Test.startTest();
      List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(
        reqs
      );
      Test.stopTest();
      System.assertEquals(2, results.size());
      System.assertEquals(1, instanceCountForKey('VIV_bulk_ok1'));
      System.assertEquals(1, instanceCountForKey('VIV_bulk_ok2'));
    }
  }

  @IsTest
  static void testBulkInvalidAggregatesAndWritesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      List<WorkflowEngine.StartRequest> reqs = new List<WorkflowEngine.StartRequest>{
        new WorkflowEngine.StartRequest(
          CONTRACT_WF,
          'VIV_bulk_good',
          validInput()
        ),
        new WorkflowEngine.StartRequest(
          CONTRACT_WF,
          'VIV_bulk_bad',
          new Map<String, Object>{ 'amount' => 5 }
        )
      };
      Boolean threw = false;
      try {
        WorkflowEngine.startOrGet(reqs);
      } catch (WorkflowInputException ex) {
        threw = true;
        System.assert(
          ex.getMessage().contains('request[1]'),
          'Bulk message should tag the offending request index: ' +
          ex.getMessage()
        );
        System.assert(ex.getMessage().contains('accountId'));
      }
      System.assertEquals(true, threw, 'Bulk invalid input must throw');
      // All-or-none: neither the valid sibling nor the invalid row is written.
      System.assertEquals(0, instanceCountForKey('VIV_bulk_good'));
      System.assertEquals(0, instanceCountForKey('VIV_bulk_bad'));
    }
  }

  // ── Zero SOQL / DML from validation ─────────────────────────────────────────

  @IsTest
  static void testValidationIssuesNoSoqlOrDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.StartRequest badReq = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_limits',
        new Map<String, Object>{ 'amount' => 'x' }
      );
      Test.startTest();
      Integer queriesBefore = Limits.getQueries();
      Integer dmlBefore = Limits.getDmlStatements();
      List<WorkflowInputFieldError> errors = WorkflowInputValidator.collectErrors(
        badReq
      );
      System.assertEquals(
        queriesBefore,
        Limits.getQueries(),
        'Validation must issue zero SOQL'
      );
      System.assertEquals(
        dmlBefore,
        Limits.getDmlStatements(),
        'Validation must issue zero DML'
      );
      Test.stopTest();
      System.assertEquals(false, errors.isEmpty());
    }
  }

  // ── Invocable (Flow-facing) ─────────────────────────────────────────────────

  @IsTest
  static void testInvocableInvalidIsBranchableNoFault() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      WorkflowStartInvocableAction.StartRequest bad = new WorkflowStartInvocableAction.StartRequest();
      bad.workflowName = CONTRACT_WF;
      bad.correlationKey = 'VIV_inv_bad';
      bad.inputJson = '{"amount":5}'; // missing accountId; amount is fine

      WorkflowStartInvocableAction.StartRequest good = new WorkflowStartInvocableAction.StartRequest();
      good.workflowName = CONTRACT_WF;
      good.correlationKey = 'VIV_inv_good';
      good.inputJson = JSON.serialize(validInput());

      Test.startTest();
      List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{ bad, good }
      );
      Test.stopTest();

      System.assertEquals(2, results.size());
      // Invalid row: branchable failure, no instance, siblings unaffected.
      System.assertEquals(false, results[0].isValid);
      System.assertNotEquals(null, results[0].validationError);
      System.assert(results[0].validationError.contains('accountId'));
      System.assertEquals(null, results[0].workflowInstanceId);
      System.assertEquals(0, instanceCountForKey('VIV_inv_bad'));
      // Valid sibling: started, isValid true.
      System.assertEquals(true, results[1].isValid);
      System.assertEquals(null, results[1].validationError);
      System.assertNotEquals(null, results[1].workflowInstanceId);
      System.assertEquals(1, instanceCountForKey('VIV_inv_good'));
    }
  }

  @IsTest
  static void testInvocableMalformedJsonIsBranchable() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStartInvocableAction.StartRequest bad = new WorkflowStartInvocableAction.StartRequest();
      bad.workflowName = CONTRACT_WF;
      bad.correlationKey = 'VIV_inv_malformed';
      bad.inputJson = '{"accountId":';

      Test.startTest();
      List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{ bad }
      );
      Test.stopTest();

      System.assertEquals(1, results.size());
      System.assertEquals(false, results[0].isValid);
      System.assertNotEquals(null, results[0].validationError);
      System.assertEquals(null, results[0].workflowInstanceId);
      System.assertEquals(0, instanceCountForKey('VIV_inv_malformed'));
    }
  }
}
