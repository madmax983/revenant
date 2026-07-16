/**
 * @description Small pure helpers shared across the durable-execution engine's
 * signal-routing and signal-or-start services: cancel-signal name detection,
 * cancel-payload runCompensations parsing, signal-wakeable status testing, and
 * refreshing a cached instance SObject's status. Centralized here so the several
 * cohesive signal phase classes call one copy rather than each duplicating these
 * tiny helpers. Stateless; no DML or SOQL.
 */
public inherited sharing class WorkflowSignalHelpers {
  /**
   * @description Tests whether a signal name is a cancellation (Cancel /
   * CancelWorkflow), case-insensitively.
   * @param signalName the signal name to test
   * @return true when the signal name is a cancellation
   */
  public static Boolean isCancelSignalName(String signalName) {
    return String.isNotBlank(signalName) &&
      (signalName.equalsIgnoreCase('Cancel') ||
      signalName.equalsIgnoreCase('CancelWorkflow'));
  }

  /**
   * @description Parses the optional {"runCompensations": <bool>} flag from a
   * cancel signal payload, defaulting to true when absent or unparseable.
   * @param payload the raw cancel signal payload JSON
   * @return the runCompensations flag, or true when absent/unparseable
   */
  public static Boolean parseRunCompensations(String payload) {
    if (String.isBlank(payload)) {
      return true;
    }
    try {
      Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(
        payload
      );
      if (params.containsKey('runCompensations')) {
        return (Boolean) params.get('runCompensations');
      }
    } catch (Exception ignored) {
      // Malformed cancel payload; fall through to the default runCompensations.
    }
    return true;
  }

  /**
   * @description The set of statuses for which an inbound signal can still wake
   * an instance: a forward signal resumes Suspended/Running, and a compensation
   * step may await a signal while Compensating/Cancelling. Terminal statuses are
   * not signalable.
   * @param status the instance status to test
   * @return true when a signal can still wake an instance in this status
   */
  public static Boolean isWakeableStatus(String status) {
    return status == 'Suspended' ||
      status == 'Running' ||
      status == 'Compensating' ||
      status == 'Cancelling';
  }

  /**
   * @description Refreshes the cached SObject's status from a freshly-queried
   * copy. The bulk signal path holds the same instance under several map keys
   * (18-/15-char Id and correlation key), but they all reference one SObject, so
   * a single field assignment updates every view of it.
   * @param instById map of instances keyed by Id (and other aliases)
   * @param refreshed the freshly-queried instance whose status is copied over
   */
  public static void refreshCachedStatus(
    Map<String, Workflow_Instance__c> instById,
    Workflow_Instance__c refreshed
  ) {
    Workflow_Instance__c cached = instById.get(refreshed.Id);
    if (cached != null) {
      cached.Status__c = refreshed.Status__c;
    }
  }
}
