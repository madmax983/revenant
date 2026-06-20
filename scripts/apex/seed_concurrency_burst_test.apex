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

// Use the bulk startOrGet(List<StartRequest>) API, not the scalar start() in a loop.
// The scalar path costs several DML statements per call (instance insert/update, step
// insert, orchestrator publish), so 200 iterations would blow the 150-DML governor
// before the burst is seeded. startOrGet bulkifies its DML, so a chunk of starts costs
// a fixed handful of statements regardless of chunk size. Chunk the burst so this scales
// toward larger sizes (each chunk is its own bounded set of DML statements).
Integer CHUNK_SIZE = 200;
Long batchStamp = System.now().getTime();
Integer started = 0;
for (Integer offset = 0; offset < BURST_SIZE; offset += CHUNK_SIZE) {
  List<WorkflowEngine.StartRequest> reqs = new List<WorkflowEngine.StartRequest>();
  Integer chunkEnd = Math.min(offset + CHUNK_SIZE, BURST_SIZE);
  for (Integer i = offset; i < chunkEnd; i++) {
    reqs.add(
      new WorkflowEngine.StartRequest(
        WORKFLOW_NAME,
        'ConcBurst_' + batchStamp + '_' + i,
        null
      )
    );
  }
  try {
    WorkflowEngine.startOrGet(reqs);
    started += reqs.size();
  } catch (Exception e) {
    System.debug(LoggingLevel.WARN, 'chunk at offset ' + offset + ' failed: ' + e.getMessage());
  }
}
System.debug('Requested ' + started + ' starts against ceiling=' + ceiling +
  '. Run verify_concurrency_burst_test.apex during the drain.');
