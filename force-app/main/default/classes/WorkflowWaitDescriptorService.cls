/**
 * @description Derives, at dashboard read time, the awaited-signal descriptor for a
 * Suspended instance parked on a signal / approval / child-completion wait. The engine
 * already persists what the instance is waiting for in the parked (Status__c = 'Pending')
 * Workflow_Step_Execution__c row's Output__c JSON (written by WorkflowStepSuspension);
 * this service reads that state and classifies the wait into an approval, child-completion,
 * or generic signal descriptor.
 *
 * <p><b>List vs. detail (issue #84):</b> the single-row detail path
 * ({@link #describeSignalWait}) reads the parked step's {@code Output__c} (rehydrating an
 * offloaded body through WorkflowPayloadOffload) and classifies the wait in full. The bulk
 * list path ({@link #describeSignalWaits}) deliberately does NOT select {@code Output__c} at
 * all: it is a LongTextArea (up to ~100,000 chars) and a full page of inline parked states
 * would materialize ~6-10MB into one synchronous transaction and exceed the 6MB Apex heap
 * before any classification runs. The wait TYPE (approval / child / generic) lives ONLY inside
 * that Output JSON — no small step/instance field encodes it — so the list cannot name the type
 * without paying that heap cost. It therefore emits one lightweight indicator per signal wait
 * ("Awaiting signal at step &lt;name&gt;"), while still distinguishing a signal wait from a
 * timer/job wait via two small instance fields that need no Output read: a signal wait has no
 * resume job ({@code Async_Job_Id__c} blank) AND no armed timer ({@code Sleep_Until__c} null);
 * a resume job OR an armed {@code Sleep_Until__c} marks a sleep/retry/timer wait. The exact
 * approval/child classification and awaited signalName are deferred to the detail view (which
 * can safely rehydrate one Output body).
 *
 * <p>The descriptor's signalName for an approval / single-child wait is the exact
 * operator-injectable form ('Approve:<key>' / 'ChildCompleted:<key>') consumed by the dashboard
 * Send Signal action, so it is copy/paste-usable with no transformation. A START_CHILDREN join
 * with more than one awaited key leaves signalName blank (the read side cannot tell which child
 * is still outstanding) and surfaces the full key list for the operator to choose from.
 *
 * <p>Strictly read-only: it issues no DML and mutates no Workflow_Step_Execution__c record.
 * A sleep / retry / admission timer wait also parks a Pending step but carries a timer on the
 * instance — a resume job ({@code Async_Job_Id__c}) or, when scheduling is off / limit-capped
 * and the async id ends up blank, an armed {@code Sleep_Until__c} deadline; those are
 * deliberately not classified as signal waits so their existing mechanism descriptor
 * (Scheduled Job / Delayed Queueable / Watchdog) is unchanged. An explicitly-marked timed
 * approval / suspend ({@code $timeoutStep}) is the exception on the detail path: its marker
 * keeps its signal descriptor even with {@code Sleep_Until__c} armed. All SOQL runs WITH
 * SYSTEM_MODE.
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
   * @param instance The Suspended instance (Status__c, Async_Job_Id__c and Sleep_Until__c are read).
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
    // A timer is armed when the instance carries a resume job (Async_Job_Id__c) OR an armed
    // Sleep_Until__c deadline (the async id can be blank while Sleep_Until__c is set when
    // scheduling is off / limit-capped — see buildDescriptor). Combined here so buildDescriptor
    // takes a single timer flag.
    Boolean timerArmed =
      String.isNotBlank(instance.Async_Job_Id__c) ||
      instance.Sleep_Until__c != null;
    return buildDescriptor(
      pending.Step_Name__c,
      WorkflowPayloadOffload.resolvePayload(pending.Output__c),
      timerArmed
    );
  }

  /**
   * @description Bulk-derives signal-wait descriptors for a page of instances (list-view
   * path) in a single pending-step query. Only Suspended instances on a signal wait get an
   * entry. The caller (the instance-list service) always supplies a non-null instance list.
   *
   * <p><b>List-vs-detail split (issue #84):</b> unlike the single-row detail path, this bulk
   * path deliberately does NOT select the parked step's {@code Output__c} (a LongTextArea up to
   * ~100,000 chars). A page of Suspended rows (limitSize up to ~100) whose inline parked states
   * are each 60-100KB would materialize ~6-10MB into one synchronous transaction and exceed the
   * 6MB Apex heap before any classification runs — even without the (already-removed) offloaded
   * ContentVersion rehydration. The wait TYPE (approval / child / generic) is encoded ONLY inside
   * that Output JSON; no small step/instance field carries it. So the list cannot label the type
   * without paying the heap cost and instead emits a single lightweight generic "Awaiting signal"
   * indicator for every signal wait. A signal wait is still distinguished from a timer/job wait
   * without reading Output: a parked step whose instance has no resume job ({@code Async_Job_Id__c}
   * blank) AND no armed timer ({@code Sleep_Until__c} null) is a signal wait; one carrying a resume
   * job OR an armed {@code Sleep_Until__c} is a timer and yields no descriptor. Accepted Option-A
   * limitation: a timed approval/suspend (signal marker + {@code Sleep_Until__c}) shows as a timer
   * on this list but still gets its full descriptor on the detail view. The exact approval/child
   * classification and awaited signalName are deferred to the single-row {@link #describeSignalWait}
   * detail view, which can safely rehydrate one body.
   * @param instances The page of instances (Status__c is read to select the Suspended rows; the
   * Async_Job_Id__c and Sleep_Until__c used for the signal/timer split are filtered in the parked
   * step's parent (WHERE) clause, so the caller need not select them here).
   * @return A map of instance id to its lightweight wait descriptor, for signal-waiting instances only.
   */
  public static Map<Id, Map<String, Object>> describeSignalWaits(
    List<Workflow_Instance__c> instances
  ) {
    Map<Id, Map<String, Object>> byInstance = new Map<Id, Map<String, Object>>();
    Set<Id> suspendedIds = suspendedInstanceIds(instances);
    if (suspendedIds.isEmpty()) {
      return byInstance;
    }
    // The bulk query never selected Output__c, so no approval/child classification is possible
    // here without a heap-blowing re-read. It returns ONLY signal-wait steps — the signal/timer
    // split is pushed into the pending-step query (see mostRecentPendingSignalSteps), which keeps
    // only parked steps whose instance has no resume job AND no armed timer — so every returned
    // step is a signal wait and simply gets the lightweight generic indicator.
    // Accepted Option-A limitation (issue #84): the list cannot read Output__c, so it cannot tell an
    // explicitly-marked TIMED APPROVAL/SUSPEND (approval/child/$timeoutStep marker + Sleep_Until__c)
    // from a bare sleep — such a timed approval shows as a timer on the LIST, yet still gets its full
    // approval descriptor on the DETAIL view (which can safely rehydrate one Output body).
    for (
      Workflow_Step_Execution__c pending : mostRecentPendingSignalSteps(
          suspendedIds
        )
        .values()
    ) {
      byInstance.put(
        pending.Workflow_Instance__c,
        genericDescriptor(pending.Step_Name__c)
      );
    }
    return byInstance;
  }

  // Collects the ids of the Suspended instances on the page (the signal/timer distinction is
  // then made in the pending-step query's WHERE clause — see mostRecentPendingSignalSteps).
  private static Set<Id> suspendedInstanceIds(
    List<Workflow_Instance__c> instances
  ) {
    Set<Id> suspendedIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      if (inst.Status__c == 'Suspended') {
        suspendedIds.add(inst.Id);
      }
    }
    return suspendedIds;
  }

  // The most-recent Pending SIGNAL-wait step per instance is the representative wait. Rows are read
  // CreatedDate-ascending so a later Pending step overwrites an earlier one in the map.
  // Output__c (a LongTextArea) is deliberately NOT selected: a page of Suspended rows would
  // materialize megabytes of inline parked state and blow the sync heap (issue #84); only the small
  // Step_Name__c label is read. The signal/timer split is done in the WHERE clause (no Output read,
  // no extra SOQL): a sleep/retry/admission/timed wait parks a Pending step too but carries a timer
  // on its instance — a resume job (Async_Job_Id__c set) or, when scheduling is off / limit-capped
  // and the async id is blank, an armed Sleep_Until__c deadline. Requiring BOTH parent fields null
  // keeps only signal waits, so a pure timer is never mislabeled "Awaiting signal". (Async_Job_Id__c
  // is only ever null or a real job id — never blank-string — so `= null` matches String.isBlank.)
  // The exact wait type + awaited name are derived on the detail view.
  private static Map<Id, Workflow_Step_Execution__c> mostRecentPendingSignalSteps(
    Set<Id> suspendedIds
  ) {
    Map<Id, Workflow_Step_Execution__c> pendingByInstance = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :suspendedIds
        AND Status__c = 'Pending'
        AND Workflow_Instance__r.Async_Job_Id__c = NULL
        AND Workflow_Instance__r.Sleep_Until__c = NULL
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

  // Classifies a parked Pending step's (rehydrated) Output JSON into a wait descriptor.
  //
  // An EXPLICIT signal marker wins even when a fallback timer is armed (issue #84/#35): an
  // approval ({"waitingForApproval":true,...}), a child (START_CHILD/START_CHILDREN), or a
  // timed suspend ({"$timeoutStep":...}, written by handleSuspendOutcome) is a genuine signal
  // wait, so a timed approval/suspend keeps its descriptor even though Sleep_Until__c is set.
  //
  // Only when NO explicit signal marker is present is the deadline consulted: a bare sleep /
  // transient-retry / concurrency-admission park (WorkflowStepSuspension.handleSleepOutcome,
  // WorkflowTransientLockRetry, WorkflowStepAdmission) also leaves a Pending step, but carries
  // a timer — either Sleep_Until__c armed OR a resume job (folded into the caller's timerArmed
  // flag). Those scheduling paths call scheduleSleepResume/scheduleRetry, which return null when
  // WorkflowEngine.useDynamicScheduling is off or a scheduling limit is hit, so the resume job
  // can be blank while Sleep_Until__c is still set: keying off the async id alone would mislabel
  // such a pure TIMER wait as a signal wait. So a parked step with no explicit marker AND a timer
  // armed is a timer/watchdog wait and yields null (its mechanism descriptor is preserved).
  private static Map<String, Object> buildDescriptor(
    String stepName,
    String resolvedOutput,
    Boolean timerArmed
  ) {
    Map<String, Object> state = parseState(resolvedOutput);
    Map<String, Object> approval = approvalDescriptor(stepName, state);
    if (approval != null) {
      return approval;
    }
    Map<String, Object> child = childDescriptor(stepName, state);
    if (child != null) {
      return child;
    }
    // A timed suspend persists the engine-reserved $timeoutStep marker: it is an EXPLICIT
    // signal wait with a deadline fallback (unlike a bare sleep, whose state carries no
    // engine marker), so it stays a generic signal wait even with Sleep_Until__c armed.
    if (state.containsKey('$timeoutStep')) {
      return genericDescriptor(stepName);
    }
    return timerArmed ? null : genericDescriptor(stepName);
  }

  // Parses the resolved Output into a JSON object, or an EMPTY map for blank/non-object/unparseable
  // input (JSON.deserializeUntyped throws on blank/null and the cast throws on a non-object, both
  // → empty map). Returning an empty map (never null) lets buildDescriptor's marker checks run
  // uniformly: no marker key is present, so an opaque state falls through to a generic/timer wait.
  private static Map<String, Object> parseState(String resolvedOutput) {
    try {
      return (Map<String, Object>) JSON.deserializeUntyped(resolvedOutput);
    } catch (Exception ignored) {
      // Opaque author state (or a non-object); carries no engine marker, so the caller
      // classifies it as a generic signal (or timer) wait.
      return new Map<String, Object>();
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
  // (START_CHILD) or bulk (START_CHILDREN) parked state. Keys originate from validated
  // non-blank correlation keys, so they are mapped directly.
  //
  // Disambiguation (issue #84): a generic StepResult.suspend() persists OPAQUE author state
  // that can legitimately carry a `childCorrelationKey` (or a `childCorrelationKeys` array)
  // without being a child-completion wait — a stray ChildCompleted:<key> suggestion would not
  // unblock that generic wait. WorkflowStepSuspension.handleStartChildOutcome writes the REAL
  // single-child state as {"childWorkflowName": ..., "childCorrelationKey": ...}, so the
  // START_CHILD-specific `childWorkflowName` marker MUST be present before a single key is
  // classified as a child-completion wait; absent it, the caller falls back to a generic wait.
  private static List<String> childSignalNames(Map<String, Object> state) {
    List<String> names = new List<String>();
    String singleKey = readString(state, 'childCorrelationKey');
    if (
      String.isNotBlank(singleKey) &&
      String.isNotBlank(readString(state, 'childWorkflowName'))
    ) {
      names.add('ChildCompleted:' + singleKey);
      return names;
    }
    // START_CHILDREN (handleStartChildrenOutcome) persists {"childCorrelationKeys": [...]} — a
    // non-empty list is its only marker (no companion key is written), so require an actual
    // list of >=1 element before classifying a bulk child join. An opaque author state whose
    // `childCorrelationKeys` is absent, empty, or not a list stays a generic wait.
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
