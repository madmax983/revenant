/**
 * Reference-example test for the durable circuit breaker (issue #128).
 *
 * Demonstrates the acceptance-criteria scenario end-to-end through the shipped
 * engine paths (WorkflowEngine.runStep): a fleet of instances calling one shared
 * dependency fast-fails (parks) once the breaker trips Open — without hammering the
 * down dependency — then auto-recovers via a half-open probe once the dependency
 * heals.
 *
 * Declared `public` per the workflow-authorization convention: it drives a started
 * WorkflowDefinition (the public CircuitBreakerWorkflowExample fixtures).
 */
@IsTest
public class CircuitBreakerWorkflowExampleTest {
  private static final String WF = 'CircuitBreakerWorkflowExample.CircuitBreakerWorkflow';
  private static final String STEP = 'CircuitBreakerWorkflowExample.CallDependencyStep';

  private static Circuit_Breaker_Config__mdt cfg() {
    return (Circuit_Breaker_Config__mdt) JSON.deserialize(
      '{"DeveloperName":"ExternalPaymentsApi","Failure_Threshold__c":3,' +
        '"Rolling_Window_Seconds__c":300,"Open_Duration_Seconds__c":60,' +
        '"Half_Open_Probe_Count__c":1}',
      Circuit_Breaker_Config__mdt.class
    );
  }

  // Fresh, not-yet-driven instance (Pending instance + Pending initial step), so
  // runStep drives it through the breaker admission hook (mirrors WorkflowConcurrencyTest).
  // A fast-tripping breaker (opens on the second failure) with a short open window,
  // so a tiny started fleet trips it and the parked instance can then be woken for a
  // half-open probe.
  private static Circuit_Breaker_Config__mdt fastTripCfg() {
    return (Circuit_Breaker_Config__mdt) JSON.deserialize(
      '{"DeveloperName":"ExternalPaymentsApi","Failure_Threshold__c":2,' +
        '"Rolling_Window_Seconds__c":300,"Open_Duration_Seconds__c":30,' +
        '"Half_Open_Probe_Count__c":1}',
      Circuit_Breaker_Config__mdt.class
    );
  }

  private static Id newPendingInstance(String key) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Pending',
      Current_Step__c = STEP,
      Correlation_Key__c = key
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = STEP,
      Status__c = 'Pending',
      Retry_Count__c = 0
    );
    return inst.Id;
  }

  private static String status(Id id) {
    return [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :id]
    .Status__c;
  }

  private static Circuit_Breaker_State__c breaker() {
    return [
      SELECT Status__c, Failure_Count__c
      FROM Circuit_Breaker_State__c
      WHERE Dependency_Key__c = 'ExternalPaymentsApi'
    ];
  }

  @IsTest
  static void testFleetFastFailsWhenDependencyDown() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean priorDynamic = WorkflowEngine.useDynamicScheduling;
      WorkflowEngine.useDynamicScheduling = false;
      try {
        WorkflowEngine.disableQueueableInTest = true;
        CircuitBreakerWorkflowExample.reset(); // dependency down
        CircuitBreakerGate.mockConfigs.put('ExternalPaymentsApi', cfg());

        Id i1 = newPendingInstance('cb-1');
        Id i2 = newPendingInstance('cb-2');
        Id i3 = newPendingInstance('cb-3');
        Id i4 = newPendingInstance('cb-4');
        Id i5 = newPendingInstance('cb-5');

        Test.startTest();
        // Dependency is down: the first three attempts fail and fill the window.
        WorkflowEngine.runStep(i1, null);
        WorkflowEngine.runStep(i2, null);
        WorkflowEngine.runStep(i3, null); // third failure trips the breaker Open
        // Breaker Open now: the rest fast-fail (park) WITHOUT calling the dependency.
        WorkflowEngine.runStep(i4, null);
        WorkflowEngine.runStep(i5, null);
        Test.stopTest();

        System.assertEquals(
          'Open',
          breaker().Status__c,
          'The breaker trips Open once the failure threshold is reached'
        );
        System.assertEquals(
          3,
          CircuitBreakerWorkflowExample.callAttempts,
          'Only the pre-open attempts reached the dependency; parked instances never called it'
        );
        System.assertEquals('Failed', status(i1), 'A pre-open attempt fails');
        System.assertEquals('Failed', status(i3), 'The tripping attempt fails');
        System.assertEquals(
          'Suspended',
          status(i4),
          'An instance arriving at the Open breaker fast-fails (parks)'
        );
        System.assertEquals('Suspended', status(i5), 'and so does the next');
        // Message__c is a LongTextArea and is non-filterable in a WHERE clause, so
        // key the query on the filterable Log_Type__c column and verify the
        // dependency-named message text in Apex on the retrieved rows.
        List<Workflow_Log__c> breakerLogs = [
          SELECT Message__c
          FROM Workflow_Log__c
          WHERE Log_Type__c = 'CircuitBreaker'
        ];
        Integer parkSignals = 0;
        for (Workflow_Log__c logRow : breakerLogs) {
          if (
            logRow.Message__c != null &&
            logRow.Message__c.contains('parked by circuit breaker')
          ) {
            parkSignals++;
          }
        }
        System.assert(
          parkSignals >= 2,
          'Each breaker park emits the distinct, dependency-named observability signal'
        );
      } finally {
        WorkflowEngine.useDynamicScheduling = priorDynamic;
      }
    }
  }

  @IsTest
  static void testHalfOpenProbeRecoversWhenDependencyHeals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean priorDynamic = WorkflowEngine.useDynamicScheduling;
      WorkflowEngine.useDynamicScheduling = false;
      try {
        WorkflowEngine.disableQueueableInTest = true;
        CircuitBreakerWorkflowExample.reset();
        CircuitBreakerGate.mockConfigs.put('ExternalPaymentsApi', cfg());
        // The breaker opened while the dependency was down; its open duration (60s)
        // has since elapsed, so it is eligible for a half-open trial probe.
        insert new Circuit_Breaker_State__c(
          Dependency_Key__c = 'ExternalPaymentsApi',
          Status__c = 'Open',
          Failure_Count__c = 3,
          Half_Open_Probes_Admitted__c = 0,
          Opened_At__c = Datetime.now().addSeconds(-120)
        );
        // The dependency has healed.
        CircuitBreakerWorkflowExample.dependencyHealthy = true;

        Id probe = newPendingInstance('cb-probe');
        Test.startTest();
        WorkflowEngine.runStep(probe, null);
        Test.stopTest();

        System.assertEquals(
          'Completed',
          status(probe),
          'The half-open probe against the healed dependency completes'
        );
        System.assertEquals(
          'Closed',
          breaker().Status__c,
          'A successful probe closes the breaker, restoring normal admission'
        );
        System.assertEquals(
          1,
          CircuitBreakerWorkflowExample.callAttempts,
          'The probe actually invoked the (now healthy) dependency'
        );
      } finally {
        WorkflowEngine.useDynamicScheduling = priorDynamic;
      }
    }
  }

  // Same AC scenario as the two runStep tests above, but driven through the engine's
  // public entry point WorkflowEngine.start(...) so it also proves the example
  // workflow is discoverable/authorized via ApexTypeImplementor (a private starter or
  // a non-public workflow/step would make start() throw "Unauthorized or invalid
  // workflow definition"), and that the shipped start -> park -> sleep-resume ->
  // half-open probe path recovers a real fleet end-to-end. Mirrors the start()-based
  // ThrottledCalloutWorkflowExampleTest precedent (start, drive via WorkflowTestHarness,
  // rewind the durable clock to make the wait eligible, then resume).
  @IsTest
  static void testStartedFleetParksThenAutoRecoversWhenDependencyHeals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerWorkflowExample.reset(); // dependency down
      CircuitBreakerGate.mockConfigs.put('ExternalPaymentsApi', fastTripCfg());

      Test.startTest();
      // Start the fleet through the engine's public entry point. This resolves the
      // definition via the ApexTypeImplementor authorization path — if the example
      // workflow (or this starter) were not public/discoverable, start() would throw
      // "Unauthorized or invalid workflow definition".
      Id trip1 = WorkflowEngine.start(WF, 'wf-cb-trip-1', null);
      Id trip2 = WorkflowEngine.start(WF, 'wf-cb-trip-2', null);
      Id parked = WorkflowEngine.start(WF, 'wf-cb-parked', null);

      // The two failing attempts against the down dependency fill the window and trip
      // the breaker Open.
      System.assertEquals(
        'Failed',
        new WorkflowTestHarness(trip1).drive().status,
        'A pre-open attempt against the down dependency fails'
      );
      System.assertEquals(
        'Failed',
        new WorkflowTestHarness(trip2).drive().status,
        'The threshold-reaching attempt fails and trips the breaker Open'
      );
      System.assertEquals(
        'Open',
        breaker().Status__c,
        'The breaker trips Open once the failure threshold is reached'
      );
      Integer callsWhileDown = CircuitBreakerWorkflowExample.callAttempts;

      // The next instance arrives at the Open breaker and fast-fails (parks): the
      // guarded step suspends on a durable sleep and the down dependency is not called.
      WorkflowTestHarness parkedHarness = new WorkflowTestHarness(parked);
      parkedHarness.disableAutoTimeSkip = true;
      WorkflowTestHarness.Result parkedRes = parkedHarness.drive();
      System.assertEquals(
        'Suspended',
        parkedRes.status,
        'An instance arriving at the Open breaker parks instead of executing'
      );
      System.assert(
        parkedRes.isSleeping,
        'The breaker park is a durable sleep that re-checks the breaker on wake'
      );
      System.assertEquals(
        callsWhileDown,
        CircuitBreakerWorkflowExample.callAttempts,
        'The parked instance never called the down dependency'
      );

      // The dependency heals and the breaker's open duration elapses, making it
      // eligible for a half-open trial probe (mirrors ThrottledCallout rewinding its
      // refill clock — Test.now() does not advance on its own).
      CircuitBreakerWorkflowExample.dependencyHealthy = true;
      Circuit_Breaker_State__c st = [
        SELECT Id, Opened_At__c
        FROM Circuit_Breaker_State__c
        WHERE Dependency_Key__c = 'ExternalPaymentsApi'
      ];
      st.Opened_At__c = Datetime.now().addSeconds(-120);
      update as system st;

      // Wake the parked step through the engine's own sleep-resume path: it re-hits
      // the breaker gate, is admitted as a half-open probe, calls the now-healthy
      // dependency, completes, and closes the breaker — the fleet auto-recovers.
      parkedHarness.disableAutoTimeSkip = false;
      WorkflowTestHarness.Result recovered = parkedHarness.fireSleep(STEP);
      Test.stopTest();

      System.assertEquals(
        'Completed',
        recovered.status,
        'The parked instance auto-recovers to completion once the dependency heals'
      );
      System.assertEquals(
        'Closed',
        breaker().Status__c,
        'A successful half-open probe closes the breaker, restoring the fleet'
      );
      System.assertEquals(
        callsWhileDown + 1,
        CircuitBreakerWorkflowExample.callAttempts,
        'Only the half-open probe re-invoked the (now healthy) dependency'
      );
    }
  }
}
