/**
 * @description Parent-notification surface for the Revenant engine. Publishes
 * child-completion signals (`ChildCompleted` / `ChildFailed` `Workflow_Event__e`
 * platform events) back to the parents of completed or failed child instances,
 * skipping parents already in a terminal state. Extracted from `WorkflowEngine`; the
 * resident `WorkflowEngine.WorkflowException` type is referenced fully qualified. All
 * SOQL/DML executes in system mode.
 */
public inherited sharing class WorkflowParentNotifier {
  /**
   * @description Publishes a child-completion signal to the parent of a single
   * completed/failed child instance.
   * @param childInstance the completed/failed child instance
   */
  public static void notifyParentCompletion(
    Workflow_Instance__c childInstance
  ) {
    notifyParentCompletion(new List<Workflow_Instance__c>{ childInstance });
  }

  /**
   * @description Publishes child-completion signals to the parents of the given
   * completed/failed child instances, skipping parents already in a terminal state.
   * @param childInstances the completed/failed child instances
   */
  public static void notifyParentCompletion(
    List<Workflow_Instance__c> childInstances
  ) {
    if (childInstances == null || childInstances.isEmpty()) {
      return;
    }

    // Query child instances to ensure all fields are loaded (avoids SObjectException)
    List<Workflow_Instance__c> freshChildren = [
      SELECT
        Parent_Instance__c,
        Correlation_Key__c,
        Status__c,
        Error_Message__c,
        Output__c
      FROM Workflow_Instance__c
      WHERE Id IN :childInstances
      WITH SYSTEM_MODE
    ];

    List<Workflow_Instance__c> childrenWithParents = new List<Workflow_Instance__c>();
    Set<Id> parentIds = new Set<Id>();
    for (Workflow_Instance__c child : freshChildren) {
      if (child.Parent_Instance__c != null) {
        childrenWithParents.add(child);
        parentIds.add(child.Parent_Instance__c);
      }
    }

    if (childrenWithParents.isEmpty()) {
      return;
    }

    Map<Id, Workflow_Instance__c> parents = new Map<Id, Workflow_Instance__c>(
      [
        SELECT Correlation_Key__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id IN :parentIds
        WITH SYSTEM_MODE
      ]
    );

    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (Workflow_Instance__c child : childrenWithParents) {
      Workflow_Instance__c parent = parents.get(child.Parent_Instance__c);
      if (parent == null) {
        continue;
      }

      // Skip if the parent is already terminal or inactive (avoids inserting stale Unrouted signals)
      if (isParentInTerminalState(parent)) {
        continue;
      }

      events.add(buildChildCompletionEvent(child, parent));
    }

    publishChildCompletionEvents(events);
  }

  /**
   * Determines whether a parent instance is in a terminal or inactive state and
   * should therefore not receive a child-completion signal.
   * @param parent the parent workflow instance
   * @return true when the parent status is terminal/inactive
   */
  private static Boolean isParentInTerminalState(Workflow_Instance__c parent) {
    return parent.Status__c == 'Completed' ||
      parent.Status__c == 'Failed' ||
      parent.Status__c == 'Compensated' ||
      parent.Status__c == 'Cancelled' ||
      parent.Status__c == 'ContinuedAsNew' ||
      parent.Status__c == 'CompensationFailed';
  }

  /**
   * Builds the child-completion platform event delivered to a parent instance.
   * @param child the completed/failed child instance
   * @param parent the parent instance to notify
   * @return the Workflow_Event__e carrying the child outcome signal
   */
  private static Workflow_Event__e buildChildCompletionEvent(
    Workflow_Instance__c child,
    Workflow_Instance__c parent
  ) {
    String targetKey = String.isNotBlank(parent.Correlation_Key__c)
      ? parent.Correlation_Key__c
      : parent.Id;

    String signalName;
    String payload;
    if (child.Status__c == 'Completed') {
      signalName = 'ChildCompleted';
      payload = child.Output__c;
    } else {
      signalName = 'ChildFailed';
      Map<String, Object> outcomeData = new Map<String, Object>{
        'status' => child.Status__c,
        'errorMessage' => child.Error_Message__c != null
          ? child.Error_Message__c.left(10000)
          : null,
        'output' => child.Output__c
      };
      payload = WorkflowPayloadOffload.savePayloadIfNeeded(
        parent.Id,
        JSON.serialize(outcomeData),
        'ChildFailedOutcome_' + child.Id
      );
    }

    signalName += String.isNotBlank(child.Correlation_Key__c)
      ? ':' + child.Correlation_Key__c
      : ':' + child.Id;

    return new Workflow_Event__e(
      Workflow_Instance_Id__c = targetKey,
      Event_Type__c = 'SIGNAL:' + signalName,
      Payload__c = payload
    );
  }

  /**
   * Publishes child-completion events and raises on any publish failure.
   * @param events platform events to publish (may be empty)
   */
  private static void publishChildCompletionEvents(
    List<Workflow_Event__e> events
  ) {
    if (events.isEmpty()) {
      return;
    }
    List<Database.SaveResult> srs = EventBus.publish(events);
    for (Database.SaveResult sr : srs) {
      if (sr.isSuccess()) {
        continue;
      }
      List<String> errMsgs = new List<String>();
      for (Database.Error err : sr.getErrors()) {
        errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
      }
      throw new WorkflowEngine.WorkflowException(
        'Failed to publish child completion event: ' +
        String.join(errMsgs, ', ')
      );
    }
  }
}
