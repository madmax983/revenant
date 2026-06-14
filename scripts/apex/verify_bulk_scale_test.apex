Integer totalInstances = [SELECT Count() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'Opp_Onboarding_%'];
Integer runningInstances = [SELECT Count() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'Opp_Onboarding_%' AND Status__c = 'Running'];
Integer completedInstances = [SELECT Count() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'Opp_Onboarding_%' AND Status__c = 'Completed'];
Integer failedInstances = [SELECT Count() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'Opp_Onboarding_%' AND Status__c = 'Failed'];

System.debug('===========================================');
System.debug('Total Scale Instances: ' + totalInstances);
System.debug('Running Scale Instances: ' + runningInstances);
System.debug('Completed Scale Instances: ' + completedInstances);
System.debug('Failed Scale Instances: ' + failedInstances);

Integer totalSteps = [SELECT Count() FROM Workflow_Step_Execution__c WHERE Workflow_Instance__r.Correlation_Key__c LIKE 'Opp_Onboarding_%'];
System.debug('Total Step Executions: ' + totalSteps);
System.debug('===========================================');
