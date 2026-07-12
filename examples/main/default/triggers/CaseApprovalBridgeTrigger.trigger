trigger CaseApprovalBridgeTrigger on Case(after insert, after update) {
  NativeApprovalTriggerBridgeExample.run();
}
