trigger CaseApprovalBridgeTrigger on Case(after insert, after update) {
  if (Trigger.isAfter && Trigger.isInsert) {
    NativeApprovalTriggerBridgeExample.handleAfterInsert(Trigger.new);
  }
  if (Trigger.isAfter && Trigger.isUpdate) {
    NativeApprovalTriggerBridgeExample.handleAfterUpdate(Trigger.new, Trigger.oldMap);
  }
}
