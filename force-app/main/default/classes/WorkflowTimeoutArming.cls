/**
 * @description Instance-level step-timeout arming for the Revenant engine.
 * Decides which of an instance's steps need a watchdog-enforced deadline job —
 * the current compensation step for a compensating/cancelling saga, otherwise the
 * active step(s), fanning out over comma-separated parallel branches — and skips a
 * concurrency-parked instance that has not yet won a slot. Delegates the actual
 * per-step scheduling to {@link WorkflowTimeoutScheduler}. Extracted from
 * `WorkflowEngine`.
 */
public inherited sharing class WorkflowTimeoutArming {
  /**
   * @description Schedules the dynamic timeout jobs for a batch of instances,
   * arming the deadline of each instance's active step (or, for a compensating
   * saga, its current compensation step) so the watchdog can enforce timeouts.
   * @param instances the instances whose active steps' timeout jobs are scheduled
   */
  public static void scheduleTimeoutJobsForInstances(
    List<Workflow_Instance__c> instances
  ) {
    for (Workflow_Instance__c instance : instances) {
      armTimeoutJobsForInstance(instance);
    }
  }

  /**
   * Arms the timeout job(s) for a single instance's active work — the current
   * compensation step for a compensating saga, otherwise the active step(s).
   * @param instance the instance whose timeout jobs are armed
   */
  private static void armTimeoutJobsForInstance(Workflow_Instance__c instance) {
    if (
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      armCompensationTimeoutJob(instance);
      return;
    }
    if (String.isBlank(instance.Current_Step__c)) {
      return;
    }
    armActiveStepTimeoutJobs(instance);
  }

  /**
   * Arms the timeout job for the top of a compensating saga's compensation stack.
   * @param instance the compensating/cancelling instance
   */
  private static void armCompensationTimeoutJob(Workflow_Instance__c instance) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return;
    }
    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      return;
    }
    WorkflowTimeoutScheduler.scheduleTimeoutJobIfNeeded(
      instance.Id,
      stack[stack.size() - 1] + '_Compensate',
      instance.Workflow_Name__c
    );
  }

  /**
   * Arms timeout jobs for an instance's active step(s), fanning out over the
   * comma-separated parallel steps when present.
   * @param instance the running instance whose active step(s) are armed
   */
  private static void armActiveStepTimeoutJobs(Workflow_Instance__c instance) {
    if (!instance.Current_Step__c.contains(',')) {
      WorkflowTimeoutScheduler.scheduleTimeoutJobIfNeeded(
        instance.Id,
        instance.Current_Step__c,
        instance.Workflow_Name__c
      );
      return;
    }
    for (String pStep : instance.Current_Step__c.split(',')) {
      WorkflowTimeoutScheduler.scheduleTimeoutJobIfNeeded(
        instance.Id,
        pStep.trim(),
        instance.Workflow_Name__c
      );
    }
  }

  /**
   * @description Schedules the timeout job for a single instance by Id, querying
   * the fields needed to arm the deadline before delegating to the record overload.
   * @param instanceId Id of the instance whose timeout job is scheduled
   */
  public static void scheduleTimeoutJobForInstance(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      return;
    }
    scheduleTimeoutJobForInstance(instances[0]);
  }

  // Overload for callers that already hold the instance with the fields this needs
  // (Status__c, Current_Step__c, Compensation_Stack__c, and the two concurrency
  // flags). Skipping the re-query matters on the per-step drive: handleStepResult
  // schedules the next step's watchdog on every advance, so re-reading the instance
  // each time can exhaust the 100-SOQL limit on a long synchronous drive (e.g. the
  // test harness driving many steps in one transaction).
  /**
   * @description Schedules the timeout job for an already-loaded instance record,
   * avoiding a re-query on the hot per-step drive. Skips a concurrency-parked
   * instance that has not yet won a slot (its step has no deadline yet).
   * @param instance the instance record carrying the fields needed to arm the timeout
   */
  public static void scheduleTimeoutJobForInstance(
    Workflow_Instance__c instance
  ) {
    if (instance == null) {
      return;
    }
    // A concurrency-parked instance that has not won a slot has a null step deadline;
    // scheduling a timeout job now would only wake and return, while occupying one of
    // the org's scarce scheduled-job slots — a large parked backlog could crowd out
    // real sleep/admission/timeout jobs. Admission re-arms the timeout once a slot is
    // won (the generic WorkflowSleepJob admission-retry path routes through here).
    if (instance.Concurrency_Parked__c && !instance.Concurrency_Slot_Held__c) {
      return;
    }
    scheduleTimeoutJobsForInstances(new List<Workflow_Instance__c>{ instance });
  }
}
