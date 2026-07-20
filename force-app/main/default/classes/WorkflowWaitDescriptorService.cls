/**
 * @description Derives, at dashboard read time, the awaited-signal descriptor for a
 * Suspended instance parked on a signal / approval / child-completion wait. The engine
 * already persists what the instance is waiting for in the parked (Status__c = 'Pending')
 * Workflow_Step_Execution__c row's Output__c JSON (written by WorkflowStepSuspension);
 * this service reads that state and classifies the wait into an approval, child-completion,
 * or generic signal descriptor.
 *
 * <p><b>List vs. detail (issue #84):</b> the single-row detail path
 * ({@link #describeSignalWait}) rehydrates an offloaded payload through WorkflowPayloadOffload
 * the same way the rest of the read path does. The bulk list path
 * ({@link #describeSignalWaits}) does NOT — bulk-pulling every offloaded body on a page would
 * blow the Apex heap — so it classifies the raw parked state as-is: inline (non-offloaded)
 * states classify in full, while an offloaded {@code {"$attachmentId":...}} marker is a small
 * object with no approval/child key and so falls through to a generic descriptor, deferring the
 * exact awaited name to the detail view.
 *
 * <p>The descriptor's signalName for an approval / single-child wait is the exact
 * operator-injectable form ('Approve:<key>' / 'ChildCompleted:<key>') consumed by the dashboard
 * Send Signal action, so it is copy/paste-usable with no transformation. A START_CHILDREN join
 * with more than one awaited key leaves signalName blank (the read side cannot tell which child
 * is still outstanding) and surfaces the full key list for the operator to choose from.
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
   * path) in a single pending-step query. Only Suspended instances on a signal wait get an
   * entry. The caller (the instance-list service) always supplies a non-null instance list.
   *
   * <p><b>List-vs-detail split (issue #84):</b> unlike the single-row detail path, this bulk
   * path deliberately does NOT rehydrate offloaded ContentVersion bodies. A page of Suspended
   * rows (limitSize up to ~100) can hold many steps whose parked state was offloaded (each
   * &gt;100,000 chars); bulk-pulling every VersionData into one synchronous transaction blows
   * the Apex heap before any classification runs. Instead this path passes the RAW parked state
   * to buildDescriptor: an inline (small, non-offloaded) state is classified in full exactly as
   * before, while an offloaded {@code {"$attachmentId":...}} marker is itself a small object
   * with no approval/child key, so it falls through to a generic descriptor and the full
   * approval/child derivation is deferred to the single-row {@link #describeSignalWait} detail
   * view (which can safely rehydrate one body). In practice the engine writes approval/child
   * markers as small inline JSON, so only an author's large plain-suspend state is ever
   * offloaded — a generic wait either way.
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
    for (Id instId : pendingByInstance.keySet()) {
      Workflow_Step_Execution__c pending = pendingByInstance.get(instId);
      // Pass the RAW (unresolved) parked state — never WorkflowPayloadOffload.resolvePayload(s)
      // — so the bulk path issues no ContentVersion body fetch. An inline state classifies in
      // full; an offloaded {"$attachmentId":...} marker is itself a small JSON object carrying
      // no approval/child key, so it falls through buildDescriptor to the generic branch and the
      // exact awaited name is derived by the single-row detail view instead.
      Map<String, Object> descriptor = buildDescriptor(
        pending.Step_Name__c,
        pending.Output__c,
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
    // A single awaited child is unambiguous, so its ChildCompleted:<key> is directly injectable.
    //
    // For a START_CHILDREN join with >1 key the parked state holds the ORIGINAL full key list
    // and carries NO read-side record of which children have already completed: that lives on
    // the child instances' statuses (WorkflowSignalChildGate.collectFinishedChildKeys), which
    // this read path deliberately does not query — doing so on the bulk list path would re-add
    // the SOQL/heap cost this service avoids. Pre-filling the FIRST key would suggest a possibly
    // already-satisfied ChildCompleted:<k1> that no longer unblocks the join (issue #84). So the
    // suggestion stays honest: leave the single pre-fill blank and surface the full list for the
    // operator to pick the still-outstanding child from.
    Map<String, Object> d;
    if (childSignalNames.size() == 1) {
      d = descriptor(TYPE_CHILD, childSignalNames[0], stepName);
    } else {
      d = descriptor(TYPE_CHILD, null, stepName);
      d.put(
        'label',
        'Awaiting child completion — choose the outstanding child key'
      );
    }
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
