// Concurrency-limit burst test (issue #28) — SEED.
//
// Prereq (no-code): deploy a Concurrency_Config__mdt record whose DeveloperName is
// the normalized class name of WORKFLOW_NAME below (non-alphanumeric chars -> '_'),
// with Max_Concurrent_Instances__c = the ceiling you want to prove (e.g. 10). A
// 'Default' record also works and applies to every workflow without a specific one.
//
// This kicks off a burst of starts. As each instance is admitted it holds a slot
// until it reaches a terminal state; the rest park (Suspended + Concurrency_Parked__c)
// and re-attempt admission automatically through the sleep/watchdog plumbing. Run the
// verify script repeatedly during the drain to watch peak Running/Compensating stay
// at or below the ceiling.

// The workflow definition to burst. Replace with any deployed WorkflowDefinition.
String WORKFLOW_NAME = 'OnboardingWorkflow';
Integer BURST_SIZE = 200; // raise toward 10000 across multiple runs for the full metric

System.debug('Concurrency burst: starting ' + BURST_SIZE + ' instances of ' + WORKFLOW_NAME);
Integer ceiling = ConcurrencyGate.getCeiling(WORKFLOW_NAME);
if (ceiling == null) {
  System.debug(LoggingLevel.ERROR,
    'No Concurrency_Config__mdt ceiling resolved for ' + WORKFLOW_NAME +
    ' — deploy a config record (or Default) first, or the burst will be unbounded.');
}

Integer started = 0;
for (Integer i = 0; i < BURST_SIZE; i++) {
  try {
    WorkflowEngine.start(
      WORKFLOW_NAME,
      'ConcBurst_' + System.now().getTime() + '_' + i,
      null
    );
    started++;
  } catch (Exception e) {
    System.debug(LoggingLevel.WARN, 'start ' + i + ' failed: ' + e.getMessage());
  }
}
System.debug('Requested ' + started + ' starts against ceiling=' + ceiling +
  '. Run verify_concurrency_burst_test.apex during the drain.');
