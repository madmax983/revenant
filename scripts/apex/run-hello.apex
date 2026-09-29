// Quickstart step 3: start HelloWorkflow with the public start API.
// Run: sf apex run --file scripts/apex/run-hello.apex
// A new correlation key each run gives a new instance.
Id instanceId = WorkflowEngine.start(
    HelloWorkflow.NAME,
    'hello-' + Datetime.now().getTime(),
    new Map<String, Object>{ 'name' => 'Revenant' }
);
System.debug('HELLO_INSTANCE_ID=' + instanceId);
