trigger WorkflowInstanceTrigger on Workflow_Instance__c(
  before insert,
  before update,
  after update
) {
  WorkflowInstanceTriggerHandler handler = new WorkflowInstanceTriggerHandler(
    Trigger.new,
    Trigger.oldMap,
    Trigger.operationType
  );
  if (Trigger.isAfter) {
    handler.handleAfterUpdate();
  } else {
    handler.handleBeforeSave();
  }
}
