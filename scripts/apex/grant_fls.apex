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

// Grant FLS on every custom data field of the core engine objects. The list comes
// from describe, so it matches the fields the Readiness panel (#114) checks. Formula,
// auto-number and required fields take no FLS, so they are skipped. Fields of other
// packages are skipped too. This script is for a source deploy (no namespace).
List<Schema.SObjectType> engineObjects = new List<Schema.SObjectType>{
    Workflow_Instance__c.SObjectType,
    Workflow_Step_Execution__c.SObjectType,
    Workflow_Signal__c.SObjectType
};
List<FieldPermissions> grants = new List<FieldPermissions>();
for (Schema.SObjectType objectType : engineObjects) {
    String objType = objectType.getDescribe().getName();
    for (Schema.SObjectField field : objectType.getDescribe().fields.getMap().values()) {
        Schema.DescribeFieldResult d = field.getDescribe();
        // Skip fields of other packages (name has a namespace prefix).
        if (!d.isCustom() || d.isCalculated() || d.isAutoNumber() || !d.isPermissionable()
            || d.getName() != d.getLocalName()) {
            continue;
        }
        grants.add(new FieldPermissions(
            ParentId = ps.Id,
            SobjectType = objType,
            Field = objType + '.' + d.getName(),
            PermissionsRead = true,
            PermissionsEdit = true
        ));
    }
}

Integer successCount = 0;
for (Database.SaveResult result : Database.insert(grants, false)) {
    if (result.isSuccess()) {
        successCount++;
    } else {
        System.debug('Skipped FLS: ' + result.getErrors()[0].getMessage());
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
