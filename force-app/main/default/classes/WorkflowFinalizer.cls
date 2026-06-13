public inherited sharing class WorkflowFinalizer implements System.Finalizer {
    private Id instanceId;
    private String stepName;

    public WorkflowFinalizer(Id instanceId) {
        this.instanceId = instanceId;
    }

    public WorkflowFinalizer(Id instanceId, String stepName) {
        this.instanceId = instanceId;
        this.stepName = stepName;
    }

    public void execute(System.FinalizerContext ctx) {
        if (ctx.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
            Exception ex = ctx.getException();
            WorkflowEngine.handleCrash(this.instanceId, this.stepName, ex);
        }
    }
}
