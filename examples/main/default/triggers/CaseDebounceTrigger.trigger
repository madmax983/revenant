trigger CaseDebounceTrigger on Case(after update) {
  CaseDebounceTriggerHandler.run();
}
