trigger WorkflowEventTrigger on Workflow_Event__e(after insert) {
  new WorkflowEventTriggerHandler(Trigger.new).handleAfterInsert();
}
