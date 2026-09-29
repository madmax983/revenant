// Quickstart step 5: check that the latest HelloWorkflow run is Completed.
// Run: sf apex run --file scripts/apex/verify-hello.apex
// It only reads. It throws if the run is not Completed.
System.debug('HELLO_VERIFY: ' + HelloWorkflowCheck.verifyLatest().summary());
