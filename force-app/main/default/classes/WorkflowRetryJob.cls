public inherited sharing class WorkflowRetryJob implements Schedulable {
    private Id instanceId;
    
    public WorkflowRetryJob(Id instanceId) {
        this.instanceId = instanceId;
    }
    
    public void execute(SchedulableContext ctx) {
        // Enqueue the next step execution
        System.enqueueJob(new WorkflowOrchestrator(this.instanceId));
        
        // Clean up this scheduled execution from the schedule queue
        System.abortJob(ctx.getTriggerId());
    }
}
