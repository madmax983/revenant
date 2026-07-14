/**
 * @description Buffered progress-snapshot state for a single step execution
 * (issue #52), split out of StepContext. A step calls reportProgress() from
 * within execute() or compensate(); the buffered snapshot is read by the engine
 * and persisted onto Workflow_Instance__c.Progress__c at the transition
 * checkpoint. Reached by step authors via StepContext.progress().
 */
public inherited sharing class StepProgress {
  /** The buffered progress snapshot as JSON, or null when none was reported. */
  private String progressJson = null;
  /** True once a step reported progress during this execution. */
  private Boolean progressReported = false;

  /**
   * @description Reports a progress snapshot as a percent-complete and message,
   * buffered for the engine to persist at the next transition checkpoint.
   * @param percentComplete The completion percentage to record.
   * @param message A human-readable progress description.
   */
  public void reportProgress(Decimal percentComplete, String message) {
    Map<String, Object> progressMap = new Map<String, Object>{
      'percentComplete' => percentComplete,
      'message' => message
    };
    reportProgress(progressMap);
  }

  /**
   * @description Reports an arbitrary progress payload, serialized to JSON and
   * buffered for the engine to persist at the next transition checkpoint. A null
   * payload clears the buffered progress.
   * @param progressData The progress object to serialize, or null to clear.
   */
  public void reportProgress(Object progressData) {
    if (progressData == null) {
      this.progressJson = null;
    } else {
      this.progressJson = JSON.serialize(progressData);
    }
    this.progressReported = true;
  }

  /**
   * @description The buffered progress snapshot as JSON, read by the engine at
   * the transition checkpoint. Null when no progress was reported.
   * @return The serialized progress JSON, or null.
   */
  public String getProgressJson() {
    return this.progressJson;
  }

  /**
   * @description True when the step called reportProgress() during this
   * execution, so the engine knows there is a snapshot to persist.
   * @return True if progress was reported.
   */
  public Boolean isProgressReported() {
    return this.progressReported;
  }
}
