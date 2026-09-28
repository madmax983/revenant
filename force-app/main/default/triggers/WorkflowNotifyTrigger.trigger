/**
 * Sends approver notifications (issue #123). A separate subscriber from
 * WorkflowEventTrigger: it runs in its own transaction with its own limits,
 * so engine work cannot use its budget and it cannot fail engine work.
 */
trigger WorkflowNotifyTrigger on Workflow_Event__e(after insert) {
  WorkflowNotifier.handleEvents(Trigger.new);
}
