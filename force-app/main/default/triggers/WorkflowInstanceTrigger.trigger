trigger WorkflowInstanceTrigger on Workflow_Instance__c(
  before insert,
  before update
) {
  new WorkflowInstanceTriggerHandler(
      Trigger.new,
      Trigger.oldMap,
      Trigger.operationType
    )
    .handleBeforeSave();
}
