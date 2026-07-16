/**
 * @description Shared signal dedup-key derivation for the durable-execution
 * engine. Hashes an idempotency key into a per-instance or per-correlation-key
 * scoped `Workflow_Signal__c.Signal_Key__c` value so an at-least-once
 * redelivered signal collapses onto its first delivery through the global unique
 * index. Kept off the `WorkflowEngine` facade so signal routing, unrouted
 * capture and pre-arrival dedup can all share one derivation without publicizing
 * three methods on the engine's public surface. All hashing is deterministic and
 * side-effect free (no DML/SOQL).
 */
public inherited sharing class WorkflowSignalDedup {
  /**
   * @description Derives a per-instance-scoped dedup key for a routed signal with
   * a caller-supplied idempotency key. Hashing scopes uniqueness to the instance
   * so the same logical key on different instances never collides on the global
   * `Workflow_Signal__c.Signal_Key__c` unique index. The 'I:' namespace prefix
   * keeps routed (instance-scoped) keys distinct from the 'C:'
   * correlation-scoped keys used for pre-arrival/unrouted captures.
   * @param instanceId Id of the target instance the key is scoped to
   * @param idempotencyKey caller-supplied idempotency key
   * @return a hex SHA-256 dedup key for the routed signal
   */
  public static String deriveSignalDedupKey(
    Id instanceId,
    String idempotencyKey
  ) {
    return hashDedupBasis('I:' + instanceId + '::' + idempotencyKey);
  }

  /**
   * @description Derives a correlation-key-scoped dedup key for a pre-arrival
   * (unrouted) signal whose target instance does not exist yet. Scoping by
   * correlation key collapses duplicate keyed captures of the same logical event
   * into one Unrouted row while keeping distinct correlation keys (different
   * targets) separate. The 'C:' prefix avoids collision with routed 'I:' keys.
   *
   * The correlation key is lower-cased before hashing because Salesforce SOQL
   * matches Correlation_Key__c case-insensitively, so 'Order-1' and 'order-1'
   * resolve to the same instance and must therefore dedup to the same key.
   *
   * Components are length-prefixed before hashing so the variable-length
   * correlation and idempotency keys can never form an ambiguous basis: without
   * it, correlation 'a::b' + key 'c' and correlation 'a' + key 'b::c' would hash
   * identically and silently swallow the second capture as a duplicate.
   * @param correlationKey correlation key of the not-yet-existing target instance
   * @param idempotencyKey caller-supplied idempotency key
   * @return a hex SHA-256 dedup key for the unrouted capture
   */
  public static String deriveUnroutedDedupKey(
    String correlationKey,
    String idempotencyKey
  ) {
    String normalizedKey = correlationKey == null
      ? ''
      : correlationKey.toLowerCase();
    String key = idempotencyKey == null ? '' : idempotencyKey;
    return hashDedupBasis(
      'C:' +
        normalizedKey.length() +
        ':' +
        normalizedKey +
        ':' +
        key.length() +
        ':' +
        key
    );
  }

  /**
   * @description Hashes a dedup basis string to a hex SHA-256 digest, the common
   * final step shared by the routed and unrouted dedup-key derivations.
   * @param basis the fully-qualified, namespace-prefixed dedup basis to hash
   * @return the hex-encoded SHA-256 digest of the basis
   */
  public static String hashDedupBasis(String basis) {
    Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(basis));
    return EncodingUtil.convertToHex(digest);
  }
}
