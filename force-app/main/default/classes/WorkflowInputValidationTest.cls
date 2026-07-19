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
   * numeric `amount`; type-checks optional `vipOnboarding` (Boolean), `startDate`
   * (Date) and `startTime` (Datetime) when present.
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
        .optional('startDate', WorkflowInputType.DATE_TYPE)
        .optional('startTime', WorkflowInputType.DATETIME_TYPE)
        .optional('count', WorkflowInputType.INTEGER_TYPE)
        .optional('bigCount', WorkflowInputType.LONG_TYPE);
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
      // Malformed JSON supplied via inputJson (the raw-object channel the engine
      // stores verbatim): a parse failure is a MALFORMED_JSON input error. (A
      // malformed string passed as `input` instead is serialized to a scalar and
      // validated as such — see testJsonObjectStringAsInputValidatesAsScalarAndFails.)
      WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_malformed',
        null
      );
      req.inputJson = '{"accountId":';
      Boolean threw = false;
      try {
        WorkflowEngine.startOrGet(req);
      } catch (WorkflowInputException ex) {
        threw = true;
        System.assertEquals(1, ex.getFieldErrors().size());
        System.assertEquals(
          WorkflowInputErrorReason.MALFORMED_JSON,
          ex.getFieldErrors()[0].reason
        );
      }
      System.assertEquals(true, threw, 'Malformed inputJson is an input error');
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

  // ── FIX 1: debounce start path validates before persistence ──────────────────

  private static Integer debounceStateCountForKey(String key) {
    return [
      SELECT COUNT()
      FROM Debounce_State__c
      WHERE Correlation_Key__c = :key
    ];
  }

  @IsTest
  static void testInvocableDebounceInvalidInputStillArms() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Debounce wraps a dedup verb (sweep-time startOrGet), so the invocable does
      // NOT pre-validate it — that would block a row that might dedup-resolve at
      // sweep. The row is armed (isValid=true) and its contract is checked only if
      // the sweep-time start actually creates a new instance.
      WorkflowStartInvocableAction.StartRequest bad = new WorkflowStartInvocableAction.StartRequest();
      bad.workflowName = CONTRACT_WF;
      bad.correlationKey = 'VIV_deb_defer';
      bad.inputJson = '{"amount":5}'; // missing accountId (parseable)
      bad.debounceSeconds = 10;

      Test.startTest();
      List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{ bad }
      );
      Test.stopTest();

      System.assertEquals(1, results.size());
      System.assertEquals(
        true,
        results[0].isValid,
        'Debounce is armed without pre-validation; validation is deferred to sweep'
      );
      System.assertEquals(null, results[0].workflowInstanceId);
      System.assertEquals(1, debounceStateCountForKey('VIV_deb_defer'));
    }
  }

  @IsTest
  static void testInvocableDebounceValidPersists() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStartInvocableAction.StartRequest good = new WorkflowStartInvocableAction.StartRequest();
      good.workflowName = CONTRACT_WF;
      good.correlationKey = 'VIV_deb_good';
      good.inputJson = JSON.serialize(validInput());
      good.debounceSeconds = 10;

      Test.startTest();
      List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{ good }
      );
      Test.stopTest();

      System.assertEquals(1, results.size());
      System.assertEquals(true, results[0].isValid);
      System.assertEquals(null, results[0].validationError);
      // Debounced: no instance started immediately, but the state IS armed.
      System.assertEquals(null, results[0].workflowInstanceId);
      System.assertEquals(1, debounceStateCountForKey('VIV_deb_good'));
    }
  }

  // ── FIX 2: DATE_TYPE / DATETIME_TYPE validate identically for Map & JSON ──────

  @IsTest
  static void testDatePassesAsNativeMapAndJsonString() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Map form carrying a native Apex Date.
      WorkflowEngine.StartRequest mapReq = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_date_map',
        new Map<String, Object>{
          'accountId' => 'ACME-ACCOUNT-1',
          'amount' => 10,
          'startDate' => Date.newInstance(2026, 7, 19)
        }
      );
      // JSON string form carrying the equivalent ISO date.
      WorkflowEngine.StartRequest jsonReq = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_date_json',
        null
      );
      jsonReq.inputJson = '{"accountId":"ACME-ACCOUNT-1","amount":10,"startDate":"2026-07-19"}';

      System.assertEquals(
        true,
        WorkflowInputValidator.collectErrors(mapReq).isEmpty(),
        'Native Apex Date in a Map must satisfy DATE_TYPE'
      );
      System.assertEquals(
        true,
        WorkflowInputValidator.collectErrors(jsonReq).isEmpty(),
        'ISO date string must satisfy DATE_TYPE'
      );
    }
  }

  @IsTest
  static void testDatetimePassesAsNativeMapAndJsonString() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.StartRequest mapReq = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_dt_map',
        new Map<String, Object>{
          'accountId' => 'ACME-ACCOUNT-1',
          'amount' => 10,
          'startTime' => Datetime.newInstanceGmt(2026, 7, 19, 8, 30, 0)
        }
      );
      WorkflowEngine.StartRequest jsonReq = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_dt_json',
        null
      );
      jsonReq.inputJson = '{"accountId":"ACME-ACCOUNT-1","amount":10,"startTime":"2026-07-19T08:30:00.000Z"}';

      System.assertEquals(
        true,
        WorkflowInputValidator.collectErrors(mapReq).isEmpty(),
        'Native Apex Datetime in a Map must satisfy DATETIME_TYPE'
      );
      System.assertEquals(
        true,
        WorkflowInputValidator.collectErrors(jsonReq).isEmpty(),
        'ISO datetime string must satisfy DATETIME_TYPE'
      );
    }
  }

  @IsTest
  static void testBadDateFailsWrongTypeBothForms() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.StartRequest mapReq = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_baddate_map',
        new Map<String, Object>{
          'accountId' => 'ACME-ACCOUNT-1',
          'amount' => 10,
          'startDate' => 'not-a-date'
        }
      );
      WorkflowEngine.StartRequest jsonReq = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_baddate_json',
        null
      );
      jsonReq.inputJson = '{"accountId":"ACME-ACCOUNT-1","amount":10,"startDate":"not-a-date"}';

      List<WorkflowInputFieldError> mapErrors = WorkflowInputValidator.collectErrors(
        mapReq
      );
      List<WorkflowInputFieldError> jsonErrors = WorkflowInputValidator.collectErrors(
        jsonReq
      );
      System.assertEquals(1, mapErrors.size(), 'Map form: one violation');
      System.assertEquals('startDate', mapErrors[0].fieldName);
      System.assertEquals(
        WorkflowInputErrorReason.WRONG_TYPE,
        mapErrors[0].reason
      );
      System.assertEquals(1, jsonErrors.size(), 'JSON form: one violation');
      System.assertEquals('startDate', jsonErrors[0].fieldName);
      System.assertEquals(
        WorkflowInputErrorReason.WRONG_TYPE,
        jsonErrors[0].reason
      );
    }
  }

  @IsTest
  static void testBadDatetimeFailsWrongTypeBothForms() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.StartRequest mapReq = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_baddt_map',
        new Map<String, Object>{
          'accountId' => 'ACME-ACCOUNT-1',
          'amount' => 10,
          'startTime' => 'not-a-datetime'
        }
      );
      WorkflowEngine.StartRequest jsonReq = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_baddt_json',
        null
      );
      jsonReq.inputJson = '{"accountId":"ACME-ACCOUNT-1","amount":10,"startTime":"not-a-datetime"}';

      List<WorkflowInputFieldError> mapErrors = WorkflowInputValidator.collectErrors(
        mapReq
      );
      List<WorkflowInputFieldError> jsonErrors = WorkflowInputValidator.collectErrors(
        jsonReq
      );
      System.assertEquals(1, mapErrors.size(), 'Map form: one violation');
      System.assertEquals('startTime', mapErrors[0].fieldName);
      System.assertEquals(
        WorkflowInputErrorReason.WRONG_TYPE,
        mapErrors[0].reason
      );
      System.assertEquals(1, jsonErrors.size(), 'JSON form: one violation');
      System.assertEquals('startTime', jsonErrors[0].fieldName);
      System.assertEquals(
        WorkflowInputErrorReason.WRONG_TYPE,
        jsonErrors[0].reason
      );
    }
  }

  // ── FIX 3: validation graph == persistence graph (String input vs inputJson) ──

  @IsTest
  static void testJsonObjectStringAsInputValidatesAsScalarAndFails() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // A JSON-object STRING passed as `input` (NOT inputJson). The engine will
      // persist JSON.serialize(String) — a quoted scalar string — so the first
      // step would receive a String, not an object. Validation must agree: the
      // scalar carries none of the required object fields, so start fails and
      // nothing is inserted (matching what the step would actually see).
      String objectString = '{"accountId":"ACME-ACCOUNT-1","amount":10}';
      Boolean threw = false;
      try {
        WorkflowEngine.start(CONTRACT_WF, 'VIV_strinput', objectString);
      } catch (WorkflowInputException ex) {
        threw = true;
        System.assert(
          ex.getMessage().contains('accountId'),
          'Required accountId is missing from a scalar payload: ' +
          ex.getMessage()
        );
        System.assert(
          ex.getMessage().contains('amount'),
          'Required amount is missing from a scalar payload: ' + ex.getMessage()
        );
      }
      System.assertEquals(
        true,
        threw,
        'A JSON-object string as `input` must fail (it is validated as the scalar the step receives)'
      );
      System.assertEquals(0, instanceCountForKey('VIV_strinput'));
    }
  }

  @IsTest
  static void testSameObjectViaInputJsonPassesAndPersistsRaw() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // The SAME object supplied via inputJson (preserved raw) validates as an
      // object and starts; the persisted graph is exactly what was validated.
      String rawObjectJson = '{"accountId":"ACME-ACCOUNT-1","amount":10}';
      WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_jsoninput',
        null
      );
      req.inputJson = rawObjectJson;

      WorkflowEngine.StartResult res = WorkflowEngine.startOrGet(req);

      System.assertEquals(true, res.isNew);
      System.assertEquals(1, instanceCountForKey('VIV_jsoninput'));
      Workflow_Instance__c inst = [
        SELECT Input__c
        FROM Workflow_Instance__c
        WHERE Id = :res.instanceId
      ];
      // Validation graph == persistence graph: inputJson is stored verbatim.
      System.assertEquals(
        rawObjectJson,
        inst.Input__c,
        'inputJson must be persisted raw, matching the validated object graph'
      );
    }
  }

  @IsTest
  static void testStringInputPersistsAsScalarConfirmingMirror() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // Non-validated workflow, so no contract blocks the start: prove the engine
      // persists JSON.serialize(String) for a String `input`, i.e. a quoted scalar
      // that deserializes back to a String (not an object). This is exactly the
      // graph the parser now validates, so validation and persistence agree.
      String objectString = '{"accountId":"A"}';
      Id instanceId = WorkflowEngine.start(
        PLAIN_WF,
        'VIV_strpersist',
        objectString
      );

      Workflow_Instance__c inst = [
        SELECT Input__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        JSON.serialize(objectString),
        inst.Input__c,
        'A String input is persisted as JSON.serialize(input) — a quoted scalar'
      );
      Object persistedGraph = JSON.deserializeUntyped(inst.Input__c);
      System.assertEquals(
        true,
        persistedGraph instanceof String,
        'A String input round-trips to a scalar String, not an object — matching validation'
      );
    }
  }

  // ── INTEGER_TYPE is the signed 32-bit range; wide whole numbers use LONG_TYPE ─

  private static WorkflowEngine.StartRequest numberReq(
    String key,
    String field,
    Object value
  ) {
    return new WorkflowEngine.StartRequest(
      CONTRACT_WF,
      key,
      new Map<String, Object>{
        'accountId' => 'ACME-ACCOUNT-1',
        'amount' => 10,
        field => value
      }
    );
  }

  @IsTest
  static void testIntegerTypeInRangePasses() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Integer.MAX_VALUE is in range.
      System.assertEquals(
        true,
        WorkflowInputValidator.collectErrors(
            numberReq('VIV_int_ok', 'count', 2147483647)
          )
          .isEmpty(),
        'A 32-bit whole number satisfies INTEGER_TYPE'
      );
    }
  }

  @IsTest
  static void testIntegerTypeOutOfRangeFailsWrongType() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // 3000000000 and -3000000000 exceed the signed 32-bit range -> Long.
      for (Long outOfRange : new List<Long>{ 3000000000L, -3000000000L }) {
        WorkflowEngine.StartRequest req = numberReq(
          'VIV_int_bad',
          'count',
          outOfRange
        );
        List<WorkflowInputFieldError> errors = WorkflowInputValidator.collectErrors(
          req
        );
        System.assertEquals(1, errors.size(), 'Out-of-range: one violation');
        System.assertEquals('count', errors[0].fieldName);
        System.assertEquals(
          WorkflowInputErrorReason.WRONG_TYPE,
          errors[0].reason,
          'A whole number outside 32-bit is WRONG_TYPE for INTEGER_TYPE: ' +
          outOfRange
        );
      }
      // And no instance is created for the rejected start.
      Boolean threw = false;
      try {
        WorkflowEngine.start(
          CONTRACT_WF,
          'VIV_int_bad',
          new Map<String, Object>{
            'accountId' => 'ACME-ACCOUNT-1',
            'amount' => 10,
            'count' => 3000000000L
          }
        );
      } catch (WorkflowInputException ex) {
        threw = true;
      }
      System.assertEquals(true, threw);
      System.assertEquals(0, instanceCountForKey('VIV_int_bad'));
    }
  }

  @IsTest
  static void testLongTypeAcceptsOutOfRange() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // The same wide whole number satisfies LONG_TYPE.
      System.assertEquals(
        true,
        WorkflowInputValidator.collectErrors(
            numberReq('VIV_long_ok', 'bigCount', 3000000000L)
          )
          .isEmpty(),
        'A wide whole number satisfies LONG_TYPE'
      );
    }
  }
}
