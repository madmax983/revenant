// Query the parent instance
List<Workflow_Instance__c> parentInsts = [
    SELECT Id, Status__c, Current_Step__c, Output__c, Error_Message__c 
    FROM Workflow_Instance__c 
    WHERE Correlation_Key__c = 'ParentFanout_LoadTest'
];

if (parentInsts.isEmpty()) {
    System.debug('Error: Parent workflow "ParentFanout_LoadTest" not found.');
} else {
    Workflow_Instance__c parent = parentInsts[0];
    System.debug('====================================================');
    System.debug('Parent Instance Status: ' + parent.Status__c);
    System.debug('Parent Current Step: ' + parent.Current_Step__c);
    System.debug('Parent Error Message: ' + parent.Error_Message__c);
    
    // Query children
    List<AggregateResult> children = [
        SELECT Status__c, Count(Id) cnt 
        FROM Workflow_Instance__c 
        WHERE Parent_Instance__c = :parent.Id 
        GROUP BY Status__c
    ];
    System.debug('----------------------------------------------------');
    System.debug('Child Workflow Instances by Status:');
    for (AggregateResult ar : children) {
        System.debug('  - ' + ar.get('Status__c') + ': ' + ar.get('cnt'));
    }

    // Query updated Accounts in memory to check Description
    List<Account> testAccs = [
        SELECT Description 
        FROM Account 
        WHERE Name LIKE 'FanoutTest_Account_%'
    ];
    Integer updatedAccountsCount = 0;
    for (Account acc : testAccs) {
        if (acc.Description != null && acc.Description.contains('Audited by Revenant Workflow')) {
            updatedAccountsCount++;
        }
    }
    System.debug('----------------------------------------------------');
    System.debug('Accounts successfully updated (with DML audit notes): ' + updatedAccountsCount + '/60');
    System.debug('====================================================');
}
