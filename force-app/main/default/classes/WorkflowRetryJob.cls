/**
 * @description Schedulable that fires a delayed retry of a failed step by enqueuing the
 * orchestrator, scheduling its timeout watchdog, and clearing itself from the schedule.
 */
public inherited sharing class WorkflowRetryJob implements Schedulable {
  private Id instanceId;
  private String stepName;

  /**
   * @description Constructs a retry job for a specific instance and step.
   * @param instanceId The Id of the workflow instance to retry; required.
   * @param stepName The name of the step to re-execute.
   */
  public WorkflowRetryJob(Id instanceId, String stepName) {
    if (instanceId == null) {
      throw new WorkflowEngine.WorkflowException('instanceId is required.');
    }
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  /**
   * @description Enqueues the orchestrator for the retried step, schedules its timeout
   * watchdog, and aborts this scheduled job to remove it from the schedule queue.
   * @param ctx The schedulable execution context.
   */
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
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(
        this.instanceId,
        this.stepName
      );
    }

    // Schedule watchdog for the step we just enqueued
    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(this.instanceId);

    // Clean up this scheduled execution from the schedule queue
    if (ctx != null && ctx.getTriggerId() != null) {
      System.abortJob(ctx.getTriggerId());
    }
  }

  /**
   * @description Queueable variant of the retry job used when a delayed retry must be
   * chained through the async queue rather than the scheduler.
   */
  public inherited sharing class QueueableRetryJob implements Queueable {
    private Id instanceId;
    private String stepName;

    /**
     * @description Constructs a queueable retry job for a specific instance and step.
     * @param instanceId The Id of the workflow instance to retry.
     * @param stepName The name of the step to re-execute.
     */
    public QueueableRetryJob(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    /**
     * @description Attaches a failure-sink finalizer, enqueues the orchestrator for the
     * retried step, and schedules the step's timeout watchdog.
     * @param ctx The queueable execution context.
     */
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
        WorkflowOrchestratorEnqueue.enqueueOrchestrator(
          this.instanceId,
          this.stepName
        );
      }

      // Schedule watchdog for the step we just enqueued
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(this.instanceId);
    }
  }

  // Best-effort failure sink for the retry queueable. On an unhandled exception the
  // retry re-enqueue would otherwise fail silently and strand the instance; this logs it.
  // The success path is untouched (it only acts on UNHANDLED_EXCEPTION).
  /**
   * @description Best-effort finalizer that logs an error when the retry queueable ends
   * in an unhandled exception, so a failed re-enqueue does not silently strand the instance.
   */
  public inherited sharing class RetryJobFinalizer implements Finalizer {
    private final Id instanceId;
    private final String stepName;

    /**
     * @description Constructs the finalizer capturing the instance and step being retried.
     * @param instanceId The Id of the workflow instance the retry targeted.
     * @param stepName The name of the step the retry targeted.
     */
    public RetryJobFinalizer(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    /**
     * @description Logs the retry enqueue failure when the parent job ended in an
     * unhandled exception; otherwise does nothing.
     * @param ctx The finalizer context carrying the parent job result and exception.
     */
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
