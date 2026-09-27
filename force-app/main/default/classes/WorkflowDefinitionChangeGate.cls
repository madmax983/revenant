/**
 * @description Hot-path gate that stops a forward hop when the live definition
 * shape differs from the shape stored at start (issue #89).
 *
 * `WorkflowStepRunner` calls it after the compensation route and before the
 * pause gate and concurrency admission. On a match it adds no SOQL and no
 * DML: it reads the stored fingerprint from the loaded instance and computes
 * the live one in memory. On a HALT verdict it parks the instance in
 * `DefinitionChanged`, appends one marker step-execution row and writes one
 * Warn log row. It changes no prior step row and not the compensation stack.
 * A VersionedWorkflow mismatch (ADVISORY) and a blank stored fingerprint
 * (UNKNOWN) do not stop the hop. When the live definition cannot be read, the
 * hop continues. All DML and SOQL run in system mode.
 */
public inherited sharing class WorkflowDefinitionChangeGate {
  /** @description Instance status of a parked instance. */
  public static final String STATUS = 'DefinitionChanged';

  /** @description Step name of the appended halt marker row. */
  public static final String MARKER_STEP_NAME = 'Workflow_Definition_Changed';

  // Length of Workflow_Instance__c.Error_Message__c.
  private static final Integer ERROR_MESSAGE_MAX = 255;

  // Statuses a delivery can park from. Any other status is owned by another path.
  private static final Set<String> PARKABLE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended'
  };

  /**
   * @description Parks the instance when its definition shape changed. Returns
   * true when the caller must stop the delivery.
   * @param instance The instance being driven (loaded without a lock).
   * @return True when the instance is parked (now or before).
   */
  public static Boolean parkIfChanged(Workflow_Instance__c instance) {
    if (instance.Status__c == STATUS) {
      return true; // Stale delivery. Only release moves a parked instance.
    }
    if (String.isBlank(instance.Definition_Fingerprint__c)) {
      return false; // Unknown: started before issue #89.
    }
    WorkflowDefinition def = WorkflowDefinitionFingerprint.resolve(
      instance.Workflow_Name__c
    );
    List<String> liveSteps = WorkflowDefinitionFingerprint.liveSteps(def);
    if (liveSteps == null) {
      return false; // Fail open. The step path reports a broken definition.
    }
    String live = WorkflowDefinitionFingerprint.compute(liveSteps);
    WorkflowDefinitionFingerprint.Verdict verdict = WorkflowDefinitionFingerprint.compare(
      instance.Definition_Fingerprint__c,
      live,
      def instanceof VersionedWorkflow
    );
    if (verdict == WorkflowDefinitionFingerprint.Verdict.ADVISORY) {
      System.debug(
        LoggingLevel.WARN,
        'Definition shape changed for VersionedWorkflow instance ' +
          instance.Id +
          ' (advisory, not blocking).'
      );
      return false;
    }
    if (verdict != WorkflowDefinitionFingerprint.Verdict.HALT) {
      return false;
    }
    return park(instance, live, liveSteps);
  }

  // Re-read the instance FOR UPDATE (instance lock first, matching admission
  // lock order), then park it once. Concurrent parallel branches see the
  // parked status and stop without a second marker.
  private static Boolean park(
    Workflow_Instance__c instance,
    String live,
    List<String> liveSteps
  ) {
    Workflow_Instance__c locked = [
      SELECT Id, Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (!PARKABLE_STATUSES.contains(locked.Status__c)) {
      return true; // Parked, finished or compensating by another thread.
    }
    String detail =
      'Workflow definition step list changed while in flight. ' +
      'Stored fingerprint ' +
      instance.Definition_Fingerprint__c +
      ', live fingerprint ' +
      live +
      '. Current step: ' +
      locked.Current_Step__c +
      '. Reconcile the change, then release or cancel the instance.';
    // Error_Message__c holds 255 characters. The marker row keeps the detail.
    String reason = ('Definition step list changed in flight. Current step: ' +
      locked.Current_Step__c +
      '. Release or cancel.')
      .abbreviate(ERROR_MESSAGE_MAX);

    locked.Status__c = STATUS;
    locked.Error_Message__c = reason;
    locked.Sleep_Until__c = null;
    locked.Async_Job_Id__c = null;
    Database.update(locked, true, AccessLevel.SYSTEM_MODE);

    Database.insert(
      new Workflow_Step_Execution__c(
        Workflow_Instance__c = locked.Id,
        Step_Name__c = MARKER_STEP_NAME,
        Status__c = STATUS,
        Retry_Count__c = 0,
        Error_Details__c = detail,
        Output__c = JSON.serialize(
          new Map<String, Object>{
            'storedFingerprint' => instance.Definition_Fingerprint__c,
            'liveFingerprint' => live,
            'liveSteps' => liveSteps,
            'currentStep' => locked.Current_Step__c
          }
        )
      ),
      true,
      AccessLevel.SYSTEM_MODE
    );

    WorkflowLog.warn('DefinitionChanged', detail, locked.Id);
    instance.Status__c = STATUS;
    return true;
  }
}
