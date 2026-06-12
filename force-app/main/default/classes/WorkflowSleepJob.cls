public class WorkflowSleepJob implements Schedulable {
    private Id instanceId;
    
    public WorkflowSleepJob(Id instanceId) {
        this.instanceId = instanceId;
    }
    
    public void execute(SchedulableContext ctx) {
        // Enqueue the next step execution
        if (Test.isRunningTest()) {
            System.enqueueJob(new WorkflowOrchestrator(this.instanceId));
        } else {
            WorkflowEngine.enqueueOrchestrator(this.instanceId, null);
        }
        
        // Clean up this scheduled execution from the schedule queue
        System.abortJob(ctx.getTriggerId());
    }
}
