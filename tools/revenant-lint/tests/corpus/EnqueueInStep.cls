// Anti-pattern: start async work in a step. Each replay starts it again.
public class EnqueueInStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    Id jobId = System.enqueueJob(new SyncQueueable()); // expect: ASYNC_ENQUEUE
    Database.executeBatch(new CleanupBatch(), 200); // expect: ASYNC_ENQUEUE
    System.schedule('nightly', '0 0 1 * * ?', new Nightly()); // expect: ASYNC_ENQUEUE
    System.scheduleBatch(new CleanupBatch(), 'later', 10); // expect: ASYNC_ENQUEUE
    return StepResult.complete(null, jobId);
  }
}
