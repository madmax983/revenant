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
  Object produce();
}
