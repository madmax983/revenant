// 1. Clean up any existing test data
System.debug('Cleaning up existing data...');
delete [SELECT Id FROM Opportunity WHERE Name LIKE 'BulkScaleOpp_%'];
delete [SELECT Id FROM Account WHERE Name = 'BulkScaleTestAccount'];
delete [SELECT Id FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'Opp_Onboarding_%'];

// 2. Setup bulk test account
Account testAcc = new Account(Name = 'BulkScaleTestAccount');
insert testAcc;

// 3. Create 1000 Opportunities in Prospecting stage
System.debug('Inserting 1000 Opportunities...');
List<Opportunity> opps = new List<Opportunity>();
for (Integer i = 0; i < 1000; i++) {
    opps.add(new Opportunity(
        Name = 'BulkScaleOpp_' + i,
        AccountId = testAcc.Id,
        CloseDate = Date.today().addDays(30),
        StageName = 'Prospecting',
        Amount = 5000.00
    ));
}
insert opps;

// 4. Update the 1000 Opportunities to Closed Won stage to trigger the bulkified handler
System.debug('Updating 1000 Opportunities to Closed Won to trigger bulk start...');
for (Opportunity opp : opps) {
    opp.StageName = 'Closed Won';
}

update opps;

System.debug('Bulk start transaction finished.');
System.debug('SOQL Queries consumed: ' + Limits.getQueries() + ' / ' + Limits.getLimitQueries());
System.debug('DML Statements consumed: ' + Limits.getDmlStatements() + ' / ' + Limits.getLimitDmlStatements());
System.debug('DML Rows consumed: ' + Limits.getDmlRows() + ' / ' + Limits.getLimitDmlRows());
System.debug('Queueable Jobs consumed: ' + Limits.getQueueableJobs() + ' / ' + Limits.getLimitQueueableJobs());

// Verify created workflow instances
Integer count = [SELECT Count() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'Opp_Onboarding_%'];
System.debug('Workflow Instances created: ' + count + ' / 1000');
