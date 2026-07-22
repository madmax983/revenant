/**
 * @description Implemented by a WorkflowStep that calls a shared external
 * dependency (an integration, a partner API, a legacy endpoint) which the engine
 * should protect with a circuit breaker. The step declares the dependency it
 * depends on via a stable key; the breaker for that key is shared across every
 * workflow whose guarded steps name it.
 *
 * When the breaker for the declared key is Open the engine fast-fails the step by
 * parking it (durable suspend) instead of executing it, so a fleet of instances
 * stops hammering a dependency that is already down and auto-recovers once it
 * heals — the same admission-gate discipline as ConcurrencyGuarded parking, but
 * keyed on dependency health rather than an in-flight ceiling.
 *
 * Sibling to RetryConfigurable / TimeoutConfigurable / CalloutStep: a plain
 * WorkflowStep that does not implement this interface is never breaker-gated, and
 * the admission hot path short-circuits on the `instanceof` check with zero SOQL
 * and zero DML.
 */
public interface CircuitBreakerGuarded {
  /**
   * @description Returns the stable dependency key whose circuit breaker guards
   * this step. Blank/null opts the step out of breaker gating (treated as no
   * dependency). The key resolves to a Circuit_Breaker_Config__mdt record by the
   * same DeveloperName convention as Concurrency_Config__mdt; a key with no
   * matching config (and no Default) has no breaker and always admits.
   * @return The dependency key naming the breaker that guards this step.
   */
  String dependencyKey();
}
