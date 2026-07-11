public inherited sharing class WorkflowRetryJob implements Schedulable {
  private Id instanceId;
  private String stepName;

  public WorkflowRetryJob(Id instanceId, String stepName) {
    if (instanceId == null) {
      throw new WorkflowEngine.WorkflowException('instanceId is required.');
    }
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  public void execute(SchedulableContext ctx) {
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(
          String.isNotBlank(this.stepName)
            ? new WorkflowOrchestrator(this.instanceId, this.stepName)
            : new WorkflowOrchestrator(this.instanceId)
        );
      }
    } else {
      WorkflowEngine.enqueueOrchestrator(this.instanceId, this.stepName);
    }

    // Schedule watchdog for the step we just enqueued
    WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);

    // Clean up this scheduled execution from the schedule queue
    if (ctx != null && ctx.getTriggerId() != null) {
      System.abortJob(ctx.getTriggerId());
    }
  }

  public inherited sharing class QueueableRetryJob implements Queueable {
    private Id instanceId;
    private String stepName;

    public QueueableRetryJob(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    public void execute(QueueableContext ctx) {
      // Surface an unhandled failure of the retry enqueue to the log sink rather than
      // letting it vanish. The finalizer runs even if execute() throws.
      System.attachFinalizer(
        new RetryJobFinalizer(this.instanceId, this.stepName)
      );

      if (Test.isRunningTest()) {
        if (!WorkflowEngine.disableQueueableInTest) {
          System.enqueueJob(
            String.isNotBlank(this.stepName)
              ? new WorkflowOrchestrator(this.instanceId, this.stepName)
              : new WorkflowOrchestrator(this.instanceId)
          );
        }
      } else {
        WorkflowEngine.enqueueOrchestrator(this.instanceId, this.stepName);
      }

      // Schedule watchdog for the step we just enqueued
      WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);
    }
  }

  // Best-effort failure sink for the retry queueable. On an unhandled exception the
  // retry re-enqueue would otherwise fail silently and strand the instance; this logs it.
  // The success path is untouched (it only acts on UNHANDLED_EXCEPTION).
  public inherited sharing class RetryJobFinalizer implements Finalizer {
    private final Id instanceId;
    private final String stepName;

    public RetryJobFinalizer(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    public void execute(FinalizerContext ctx) {
      if (
        ctx == null ||
        ctx.getResult() != ParentJobResult.UNHANDLED_EXCEPTION
      ) {
        return;
      }
      Exception ex = ctx.getException();
      String detail = (ex == null) ? 'unknown error' : ex.getMessage();
      // WorkflowLog.error swallows its own DML failures, so this stays best-effort.
      WorkflowLog.error(
        'WorkflowRetryJob.QueueableRetryJob',
        'Retry enqueue failed for step "' + stepName + '": ' + detail,
        instanceId
      );
    }
  }
}
