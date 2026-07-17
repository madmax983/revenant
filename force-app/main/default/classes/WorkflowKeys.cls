/**
 * @description Pure correlation-key utilities shared across the workflow engine's
 * start/dedup, signal-routing and status-read layers. Extracted from
 * `WorkflowEngine` so the canonical key-normalization helper lives on a thin,
 * dependency-free util rather than the engine facade. Holds no state and touches
 * no DML or SOQL.
 */
public inherited sharing class WorkflowKeys {
  /**
   * Canonical form of a correlation key for in-memory dedup maps/sets.
   * Correlation_Key__c is case-insensitive (and the unique
   * Active_Correlation_Key__c index is too), but Apex Map/Set keys are
   * case-sensitive, so keys are lower-cased to match the database semantics.
   * @param key the raw correlation key
   * @return the lower-cased key, or null when the input is null
   */
  public static String normalizeKey(String key) {
    return key == null ? null : key.toLowerCase();
  }
}
