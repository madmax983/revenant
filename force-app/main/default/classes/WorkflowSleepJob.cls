/**
 * @description Schedulable that resumes a sleeping (Suspended) workflow instance once its
 * sleep timer elapses, clearing the sleep markers, enqueuing the next step, and no-opping
 * if the sleep was already resumed by another path.
 */
public inherited sharing class WorkflowSleepJob implements Schedulable {
  private Id instanceId;
  private String stepName;

  /**
   * @description Constructs a sleep job that resumes the instance's current step.
   * @param instanceId The Id of the suspended workflow instance to resume; required.
   */
  public WorkflowSleepJob(Id instanceId) {
    this(instanceId, null);
  }

  /**
   * @description Constructs a sleep job that resumes a specific named step.
   * @param instanceId The Id of the suspended workflow instance to resume; required.
   * @param stepName The name of the step to resume.
   */
  public WorkflowSleepJob(Id instanceId, String stepName) {
    if (instanceId == null) {
      throw new WorkflowEngine.WorkflowException('instanceId is required.');
    }
    this.instanceId = instanceId;
    this.stepName = stepName;
  }

  /**
   * @description Clears the sleep markers and, if the sleep is still pending, enqueues the
   * orchestrator and schedules its timeout watchdog; aborts this stale scheduled job.
   * @param ctx The schedulable execution context.
   */
  public void execute(SchedulableContext ctx) {
    // If the sleep has already been resumed by fireSleep or the watchdog, this scheduled job is stale and must no-op.
    if (!checkAndClearSleepMarkers(this.instanceId, this.stepName)) {
      if (ctx != null && ctx.getTriggerId() != null) {
        System.abortJob(ctx.getTriggerId());
      }
      return;
    }

    // Enqueue the next step execution
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(
          new WorkflowOrchestrator(this.instanceId, this.stepName)
        );
      }
    } else {
      WorkflowEngine.enqueueOrchestrator(this.instanceId, this.stepName);
    }

    // Schedule watchdog for the step we just resumed
    WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);

    // Clean up this scheduled execution from the schedule queue
    if (ctx != null && ctx.getTriggerId() != null) {
      System.abortJob(ctx.getTriggerId());
    }
  }

  private static Boolean checkAndClearSleepMarkers(
    Id instanceId,
    String stepName
  ) {
    List<Workflow_Instance__c> insts = [
      SELECT Status__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (insts.isEmpty()) {
      return false;
    }
    if (Test.isRunningTest() && WorkflowEngine.disableQueueableInTest) {
      return false;
    }
    Workflow_Instance__c inst = insts[0];
    if (inst.Status__c != 'Suspended' || inst.Sleep_Until__c == null) {
      return false;
    }
    if (String.isNotBlank(stepName)) {
      List<Workflow_Step_Execution__c> steps = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = :stepName
          AND Status__c = 'Pending'
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (steps.isEmpty()) {
        return false;
      }
    }

    Workflow_Instance__c toUpdate = new Workflow_Instance__c(
      Id = instanceId,
      Sleep_Until__c = null,
      Async_Job_Id__c = null
    );
    update as system toUpdate;
    return true;
  }

  /**
   * @description Queueable variant of the sleep job used when a sleep resume must be
   * chained through the async queue rather than the scheduler.
   */
  public inherited sharing class QueueableSleepJob implements Queueable {
    private Id instanceId;
    private String stepName;

    /**
     * @description Constructs a queueable sleep job that resumes the instance's current step.
     * @param instanceId The Id of the suspended workflow instance to resume.
     */
    public QueueableSleepJob(Id instanceId) {
      this(instanceId, null);
    }

    /**
     * @description Constructs a queueable sleep job that resumes a specific named step.
     * @param instanceId The Id of the suspended workflow instance to resume.
     * @param stepName The name of the step to resume.
     */
    public QueueableSleepJob(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    /**
     * @description Attaches a failure-sink finalizer, clears the sleep markers, and if the
     * sleep is still pending enqueues the orchestrator and schedules its timeout watchdog.
     * @param ctx The queueable execution context.
     */
    public void execute(QueueableContext ctx) {
      // Surface an unhandled failure of the sleep resume to the log sink rather than
      // letting it vanish. The finalizer runs even if execute() throws.
      System.attachFinalizer(
        new SleepJobFinalizer(this.instanceId, this.stepName)
      );

      // If the sleep has already been resumed by fireSleep or the watchdog, this queueable job is stale and must no-op.
      if (!checkAndClearSleepMarkers(this.instanceId, this.stepName)) {
        return;
      }

      if (Test.isRunningTest()) {
        if (!WorkflowEngine.disableQueueableInTest) {
          System.enqueueJob(
            new WorkflowOrchestrator(this.instanceId, this.stepName)
          );
        }
      } else {
        WorkflowEngine.enqueueOrchestrator(this.instanceId, this.stepName);
      }

      // Schedule watchdog for the step we just resumed
      WorkflowEngine.scheduleTimeoutJobForInstance(this.instanceId);
    }
  }

  // Best-effort failure sink for the sleep queueable. On an unhandled exception the sleep
  // resume would otherwise fail silently and strand the suspended instance; this logs it.
  // The success path is untouched (it only acts on UNHANDLED_EXCEPTION).
  /**
   * @description Best-effort finalizer that logs an error when the sleep queueable ends in
   * an unhandled exception, so a failed resume does not silently strand the suspended instance.
   */
  public inherited sharing class SleepJobFinalizer implements Finalizer {
    private final Id instanceId;
    private final String stepName;

    /**
     * @description Constructs the finalizer capturing the instance and step being resumed.
     * @param instanceId The Id of the workflow instance the resume targeted.
     * @param stepName The name of the step the resume targeted.
     */
    public SleepJobFinalizer(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }

    /**
     * @description Logs the sleep resume failure when the parent job ended in an unhandled
     * exception; otherwise does nothing.
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
        'WorkflowSleepJob.QueueableSleepJob',
        'Sleep resume failed for step "' + stepName + '": ' + detail,
        instanceId
      );
    }
  }
}
