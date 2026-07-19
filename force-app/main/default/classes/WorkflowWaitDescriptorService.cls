/**
 * @description Derives, at dashboard read time, the awaited-signal descriptor for a
 * Suspended instance parked on a signal / approval / child-completion wait. The engine
 * already persists what the instance is waiting for in the parked (Status__c = 'Pending')
 * Workflow_Step_Execution__c row's Output__c JSON (written by WorkflowStepSuspension);
 * this service reads that state, rehydrating any offloaded payload through
 * WorkflowPayloadOffload the same way the rest of the read path does, and classifies the
 * wait into an approval, child-completion, or generic signal descriptor.
 *
 * <p>The descriptor's signalName for approval / child waits is the exact operator-injectable
 * form ('Approve:<key>' / 'ChildCompleted:<key>') consumed by the dashboard Send Signal
 * action, so it is copy/paste-usable with no transformation.
 *
 * <p>Strictly read-only: it issues no DML and mutates no Workflow_Step_Execution__c record.
 * A sleep / retry timer wait also parks a Pending step but carries a resume job on the
 * instance; those are deliberately not classified as signal waits so their existing
 * mechanism descriptor (Scheduled Job / Delayed Queueable / Watchdog) is unchanged. All
 * SOQL runs WITH SYSTEM_MODE.
 */
public inherited sharing class WorkflowWaitDescriptorService {
  /** Descriptor type for an approval (WAIT_FOR_APPROVAL) wait. */
  public static final String TYPE_APPROVAL = 'approval';
  /** Descriptor type for a child-completion (START_CHILD / START_CHILDREN) wait. */
  public static final String TYPE_CHILD = 'child-completion';
  /** Descriptor type for a generic StepResult.suspend() wait with no derivable name. */
  public static final String TYPE_GENERIC = 'generic-signal';

  /**
   * @description Derives the signal-wait descriptor for a single instance from its
   * already-queried step executions (detail-view path). Returns null unless the instance
   * is Suspended on a signal / approval / child wait (a timer / sleep / retry wait yields
   * null so its existing mechanism descriptor is preserved).
   * @param instance The Suspended instance (Status__c and Async_Job_Id__c are read).
   * @param steps The instance's step executions, in CreatedDate-ascending order.
   * @return The wait descriptor map, or null when the instance is not on a signal wait.
   */
  public static Map<String, Object> describeSignalWait(
    Workflow_Instance__c instance,
    List<Workflow_Step_Execution__c> steps
  ) {
    if (instance == null || instance.Status__c != 'Suspended') {
      return null;
    }
    Workflow_Step_Execution__c pending = mostRecentPendingStep(steps);
    if (pending == null) {
      return null;
    }
    return buildDescriptor(
      pending.Step_Name__c,
      WorkflowPayloadOffload.resolvePayload(pending.Output__c),
      String.isBlank(instance.Async_Job_Id__c)
    );
  }

  /**
   * @description Bulk-derives signal-wait descriptors for a page of instances (list-view
   * path) in a single pending-step query, rehydrating offloaded outputs in one bulk pass
   * to avoid N+1 SOQL. Only Suspended instances on a signal wait get an entry. The caller
   * (the instance-list service) always supplies a non-null instance list.
   * @param instances The page of instances (Status__c and Async_Job_Id__c are read).
   * @return A map of instance id to its wait descriptor, for signal-waiting instances only.
   */
  public static Map<Id, Map<String, Object>> describeSignalWaits(
    List<Workflow_Instance__c> instances
  ) {
    Map<Id, Map<String, Object>> byInstance = new Map<Id, Map<String, Object>>();
    Set<Id> asyncBlankIds = new Set<Id>();
    Set<Id> suspendedIds = suspendedInstanceIds(instances, asyncBlankIds);
    if (suspendedIds.isEmpty()) {
      return byInstance;
    }
    Map<Id, Workflow_Step_Execution__c> pendingByInstance = mostRecentPendingSteps(
      suspendedIds
    );
    List<Id> orderedIds = new List<Id>(pendingByInstance.keySet());
    // Bulk-rehydrate any offloaded step outputs in one ContentVersion query (index-aligned).
    List<String> rawOutputs = new List<String>();
    for (Id instId : orderedIds) {
      rawOutputs.add(pendingByInstance.get(instId).Output__c);
    }
    List<String> resolvedOutputs = WorkflowPayloadOffload.resolvePayloads(
      rawOutputs
    );
    for (Integer i = 0; i < orderedIds.size(); i++) {
      Id instId = orderedIds[i];
      Map<String, Object> descriptor = buildDescriptor(
        pendingByInstance.get(instId).Step_Name__c,
        resolvedOutputs[i],
        asyncBlankIds.contains(instId)
      );
      if (descriptor != null) {
        byInstance.put(instId, descriptor);
      }
    }
    return byInstance;
  }

  // Collects the ids of the Suspended instances, recording (in asyncBlankIds) those with no
  // resume job attached so the generic-wait branch can tell a signal wait from a timer.
  private static Set<Id> suspendedInstanceIds(
    List<Workflow_Instance__c> instances,
    Set<Id> asyncBlankIds
  ) {
    Set<Id> suspendedIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      if (inst.Status__c != 'Suspended') {
        continue;
      }
      suspendedIds.add(inst.Id);
      if (String.isBlank(inst.Async_Job_Id__c)) {
        asyncBlankIds.add(inst.Id);
      }
    }
    return suspendedIds;
  }

  // The most-recent Pending step per instance is the representative wait. Rows are read
  // CreatedDate-ascending so a later Pending step overwrites an earlier one in the map.
  private static Map<Id, Workflow_Step_Execution__c> mostRecentPendingSteps(
    Set<Id> suspendedIds
  ) {
    Map<Id, Workflow_Step_Execution__c> pendingByInstance = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c, Step_Name__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :suspendedIds AND Status__c = 'Pending'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT 50000
    ]) {
      pendingByInstance.put(se.Workflow_Instance__c, se);
    }
    return pendingByInstance;
  }

  // The steps are supplied CreatedDate-ascending, so the last Pending step is the most
  // recent parked wait (mirroring the approval-role lookup's newest-gate selection).
  private static Workflow_Step_Execution__c mostRecentPendingStep(
    List<Workflow_Step_Execution__c> steps
  ) {
    Workflow_Step_Execution__c pending = null;
    if (steps == null) {
      return pending;
    }
    for (Workflow_Step_Execution__c se : steps) {
      if (se.Status__c == 'Pending') {
        pending = se;
      }
    }
    return pending;
  }

  // Classifies a parked Pending step's (rehydrated) Output JSON into a wait descriptor:
  // approval and child waits carry unambiguous markers; an opaque/absent state is a generic
  // signal wait only when no resume job is attached (a sleep/retry parks a Pending step too
  // but carries a resume job), otherwise it is a timer and yields null (unchanged).
  private static Map<String, Object> buildDescriptor(
    String stepName,
    String resolvedOutput,
    Boolean asyncJobBlank
  ) {
    Map<String, Object> state = parseState(resolvedOutput);
    if (state != null) {
      Map<String, Object> approval = approvalDescriptor(stepName, state);
      if (approval != null) {
        return approval;
      }
      Map<String, Object> child = childDescriptor(stepName, state);
      if (child != null) {
        return child;
      }
    }
    return asyncJobBlank ? genericDescriptor(stepName) : null;
  }

  // Parses the resolved Output into a JSON object, or null for blank/non-object/unparseable
  // input (JSON.deserializeUntyped throws on blank/null and on a non-object, all → null).
  private static Map<String, Object> parseState(String resolvedOutput) {
    try {
      return (Map<String, Object>) JSON.deserializeUntyped(resolvedOutput);
    } catch (Exception ignored) {
      // Opaque author state (or a non-object); treated as a generic wait by the caller.
      return null;
    }
  }

  // Builds an approval descriptor when the parked step state is a WAIT_FOR_APPROVAL gate.
  private static Map<String, Object> approvalDescriptor(
    String stepName,
    Map<String, Object> state
  ) {
    String approvalKey = readString(state, 'approvalKey');
    if (
      state.get('waitingForApproval') != true || String.isBlank(approvalKey)
    ) {
      return null;
    }
    String signalName = 'Approve:' + approvalKey;
    return descriptor(TYPE_APPROVAL, signalName, stepName);
  }

  // Builds a child-completion descriptor from a START_CHILD (single key) or START_CHILDREN
  // (key list) parked step state, surfacing every awaited ChildCompleted signal name.
  private static Map<String, Object> childDescriptor(
    String stepName,
    Map<String, Object> state
  ) {
    List<String> childSignalNames = childSignalNames(state);
    if (childSignalNames.isEmpty()) {
      return null;
    }
    // The first awaited ChildCompleted is directly injectable; the full list is surfaced so
    // the operator can see every child the step is blocked on.
    Map<String, Object> d = descriptor(
      TYPE_CHILD,
      childSignalNames[0],
      stepName
    );
    d.put('childSignalNames', childSignalNames);
    return d;
  }

  // Resolves the ordered awaited ChildCompleted: signal names from either the single-child
  // (childCorrelationKey) or bulk (childCorrelationKeys list) parked state. Keys originate
  // from validated non-blank correlation keys, so they are mapped directly.
  private static List<String> childSignalNames(Map<String, Object> state) {
    List<String> names = new List<String>();
    String singleKey = readString(state, 'childCorrelationKey');
    if (String.isNotBlank(singleKey)) {
      names.add('ChildCompleted:' + singleKey);
      return names;
    }
    Object raw = state.get('childCorrelationKeys');
    if (raw instanceof List<Object>) {
      for (Object k : (List<Object>) raw) {
        names.add('ChildCompleted:' + String.valueOf(k));
      }
    }
    return names;
  }

  // Builds the generic descriptor: the awaited name is unknowable, so it names the step the
  // instance is parked at and marks it as awaiting an inbound signal.
  private static Map<String, Object> genericDescriptor(String stepName) {
    Map<String, Object> d = descriptor(TYPE_GENERIC, null, stepName);
    d.put('label', 'Awaiting signal at step ' + stepName);
    return d;
  }

  // Assembles the descriptor map with label defaulting to the injectable signalName (so an
  // approval/child descriptor's shown string pastes straight into Send Signal).
  private static Map<String, Object> descriptor(
    String descriptorType,
    String signalName,
    String stepName
  ) {
    return new Map<String, Object>{
      'type' => descriptorType,
      'signalName' => signalName,
      'stepName' => stepName,
      'label' => signalName
    };
  }

  // Reads a string value from the parsed state, or null when absent.
  private static String readString(Map<String, Object> state, String key) {
    Object v = state.get(key);
    return v == null ? null : String.valueOf(v);
  }
}
