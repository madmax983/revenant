public with sharing class WorkflowDashboardController {
    
    @AuraEnabled(cacheable=true)
    public static List<Workflow_Instance__c> getInstances() {
        return [
            SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, Error_Message__c 
            FROM Workflow_Instance__c 
            ORDER BY CreatedDate DESC 
            LIMIT 100
        ];
    }
    
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getInstanceDetails(Id instanceId) {
        Workflow_Instance__c instance = [
            SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, Input__c, Output__c, Current_Step__c, Error_Message__c, CreatedDate
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];
        
        List<Workflow_Step_Execution__c> steps = [
            SELECT Id, Step_Name__c, Status__c, Input__c, Output__c, Retry_Count__c, Error_Details__c, CreatedDate
            FROM Workflow_Step_Execution__c
            WHERE Workflow_Instance__c = :instanceId
            ORDER BY CreatedDate ASC
        ];
        
        return new Map<String, Object>{
            'instance' => instance,
            'steps' => steps
        };
    }
    
    @AuraEnabled(cacheable=true)
    public static List<String> getDefinitions() {
        List<String> definitions = new List<String>();
        // Query Apex classes and check body in memory to bypass SOQL Body restriction
        List<ApexClass> classes = [
            SELECT Name, Body FROM ApexClass 
            WHERE NamespacePrefix = null 
            ORDER BY Name ASC
        ];
        for (ApexClass ac : classes) {
            if (ac.Body != null && (ac.Body.contains('implements WorkflowDefinition') || ac.Body.contains('implements  WorkflowDefinition'))) {
                // Exclude test class definitions
                if (!ac.Name.contains('WorkflowEngineTest') && !ac.Name.contains('WorkflowDashboardControllerTest')) {
                    definitions.add(ac.Name);
                }
            }
        }
        return definitions;
    }
    
    @AuraEnabled
    public static Id startWorkflow(String workflowName, String correlationKey, String inputJson) {
        try {
            Object input = null;
            if (String.isNotBlank(inputJson)) {
                input = JSON.deserializeUntyped(inputJson);
            }
            return WorkflowEngine.start(workflowName, correlationKey, input);
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }
}
