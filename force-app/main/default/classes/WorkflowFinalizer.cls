public class WorkflowFinalizer implements System.Finalizer {
    private Id instanceId;

    public WorkflowFinalizer(Id instanceId) {
        this.instanceId = instanceId;
    }

    public void execute(System.FinalizerContext ctx) {
        if (ctx.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
            Exception ex = ctx.getException();
            WorkflowEngine.handleCrash(this.instanceId, ex);
        }
    }
}
