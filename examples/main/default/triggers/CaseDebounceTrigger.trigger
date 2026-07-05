trigger CaseDebounceTrigger on Case (after update) {
  if (Trigger.isAfter && Trigger.isUpdate) {
    CaseDebounceTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
  }
}
