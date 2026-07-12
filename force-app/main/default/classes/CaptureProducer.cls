/**
 * Functional interface for the capture-once API (StepContext.once()).
 *
 * Implement this to wrap any non-deterministic expression — Datetime.now(),
 * a generated UUID, a Crypto-random token, a sequence number — that must be
 * stable across re-executions of the same logical step.  The engine calls
 * produce() at most once per (instance, step, key); on every subsequent
 * re-execution it returns the durably recorded result without calling produce().
 */
public interface CaptureProducer {
  /**
   * @description Produces the non-deterministic value to capture durably. The
   * engine invokes this at most once per (instance, step, key); thereafter the
   * recorded result is replayed without calling this method again.
   * @return The value to record and replay for this capture key.
   */
  Object produce();
}
