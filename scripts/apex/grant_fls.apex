// Create or retrieve the Permission Set
List<PermissionSet> existingPs = [SELECT Id FROM PermissionSet WHERE Name = 'Revenant_FLS' LIMIT 1];
PermissionSet ps;
if (existingPs.isEmpty()) {
    ps = new PermissionSet(
        Name = 'Revenant_FLS',
        Label = 'Revenant FLS Access'
    );
    insert ps;
    System.debug('Created Permission Set: Revenant_FLS');
} else {
    ps = existingPs[0];
    System.debug('Using existing Permission Set: Revenant_FLS');
    // Clear old field permissions to avoid duplicates
    delete [SELECT Id FROM FieldPermissions WHERE ParentId = :ps.Id];
}

// List of custom fields to grant FLS to
List<String> fieldsToGrant = new List<String>{
    'Workflow_Instance__c.Compensation_Stack__c',
    'Workflow_Instance__c.Correlation_Key__c',
    'Workflow_Instance__c.Current_Step__c',
    'Workflow_Instance__c.Definition_Version__c',
    'Workflow_Instance__c.Error_Message__c',
    'Workflow_Instance__c.Input__c',
    'Workflow_Instance__c.Output__c',
    'Workflow_Instance__c.Parent_Instance__c',
    'Workflow_Instance__c.Previous_Instance__c',
    'Workflow_Instance__c.Status__c',
    'Workflow_Instance__c.Workflow_Name__c',
    
    'Workflow_Step_Execution__c.Error_Details__c',
    'Workflow_Step_Execution__c.Input__c',
    'Workflow_Step_Execution__c.Output__c',
    'Workflow_Step_Execution__c.Retry_Count__c',
    'Workflow_Step_Execution__c.Status__c',
    'Workflow_Step_Execution__c.Step_Name__c',
    'Workflow_Step_Execution__c.Workflow_Instance__c',
    
    'Workflow_Signal__c.Payload__c',
    'Workflow_Signal__c.Signal_Name__c',
    'Workflow_Signal__c.Status__c',
    'Workflow_Signal__c.Workflow_Instance__c'
};

Integer successCount = 0;
for (String fld : fieldsToGrant) {
    String objType = fld.substringBefore('.');
    FieldPermissions fp = new FieldPermissions(
        ParentId = ps.Id,
        SobjectType = objType,
        Field = fld,
        PermissionsRead = true,
        PermissionsEdit = true
    );
    try {
        insert fp;
        successCount++;
    } catch (Exception ex) {
        System.debug('Skipped FLS for ' + fld + ': ' + ex.getMessage());
    }
}
System.debug('Successfully inserted ' + successCount + ' FieldPermissions.');

// Assign the Permission Set to the current user if not already assigned
Id currentUserId = UserInfo.getUserId();
List<PermissionSetAssignment> existingPsa = [
    SELECT Id FROM PermissionSetAssignment 
    WHERE AssigneeId = :currentUserId 
    AND PermissionSetId = :ps.Id 
    LIMIT 1
];
if (existingPsa.isEmpty()) {
    PermissionSetAssignment psa = new PermissionSetAssignment(
        AssigneeId = currentUserId,
        PermissionSetId = ps.Id
    );
    insert psa;
    System.debug('Assigned Permission Set to current user: ' + UserInfo.getUserName());
} else {
    System.debug('Permission Set already assigned to current user.');
}
