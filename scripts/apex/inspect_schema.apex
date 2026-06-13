Map<String, Schema.SObjectField> fields = Schema.SObjectType.Workflow_Instance__c.fields.getMap();
for (String fName : fields.keySet()) {
    System.debug('Field: ' + fName);
}
