public class WorkflowOrchestrator implements Queueable, Database.AllowsCallouts {
    private Id instanceId;

    public WorkflowOrchestrator(Id instanceId) {
        this.instanceId = instanceId;
    }

    public void execute(QueueableContext ctx) {
        // Attach transaction finalizer to rescue workflow on crash/limits
        if (ctx != null) {
            System.attachFinalizer(new WorkflowFinalizer(this.instanceId));
        }
        
        // Execute step
        WorkflowEngine.runStep(this.instanceId);
    }
}
