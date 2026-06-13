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
    public static List<Workflow_Instance__c> getFilteredInstances(String workflowName, String status, String searchTerm, Integer limitSize, Integer offsetSize) {
        String query = 'SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate, Error_Message__c ' +
                       'FROM Workflow_Instance__c';
        
        List<String> conditions = new List<String>();
        if (String.isNotBlank(workflowName)) {
            conditions.add('Workflow_Name__c = :workflowName');
        }
        if (String.isNotBlank(status)) {
            conditions.add('Status__c = :status');
        }
        if (String.isNotBlank(searchTerm)) {
            String likeTerm = '%' + String.escapeSingleQuotes(searchTerm) + '%';
            conditions.add('(Name LIKE :likeTerm OR Correlation_Key__c LIKE :likeTerm OR Error_Message__c LIKE :likeTerm OR Workflow_Name__c LIKE :likeTerm)');
        }
        
        if (!conditions.isEmpty()) {
            query += ' WHERE ' + String.join(conditions, ' AND ');
        }
        
        query += ' ORDER BY CreatedDate DESC LIMIT :limitSize OFFSET :offsetSize';
        
        return Database.query(query);
    }
    
    @AuraEnabled
    public static Map<String, Object> getInstanceDetails(Id instanceId) {
        Workflow_Instance__c instance = [
            SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, Input__c, Output__c, Current_Step__c, Error_Message__c, CreatedDate, Parent_Instance__c, Parent_Instance__r.Name, Previous_Instance__c, Previous_Instance__r.Name
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];
        instance.Input__c = WorkflowEngine.resolvePayload(instance.Input__c);
        instance.Output__c = WorkflowEngine.resolvePayload(instance.Output__c);
        
        List<Workflow_Step_Execution__c> steps = [
            SELECT Id, Step_Name__c, Status__c, Input__c, Output__c, Retry_Count__c, Error_Details__c, CreatedDate
            FROM Workflow_Step_Execution__c
            WHERE Workflow_Instance__c = :instanceId
            ORDER BY CreatedDate ASC
        ];
        for (Workflow_Step_Execution__c step : steps) {
            step.Input__c = WorkflowEngine.resolvePayload(step.Input__c);
            step.Output__c = WorkflowEngine.resolvePayload(step.Output__c);
        }
        
        List<Workflow_Instance__c> children = [
            SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c, CreatedDate
            FROM Workflow_Instance__c
            WHERE Parent_Instance__c = :instanceId
            ORDER BY CreatedDate ASC
        ];
        
        List<Workflow_Instance__c> successors = [
            SELECT Id, Name FROM Workflow_Instance__c
            WHERE Previous_Instance__c = :instanceId
            LIMIT 1
        ];
        Workflow_Instance__c successor = successors.isEmpty() ? null : successors[0];
        
        return new Map<String, Object>{
            'instance' => instance,
            'steps' => steps,
            'children' => children,
            'successor' => successor
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
        
        Pattern classPattern = Pattern.compile('(?i)\\bclass\\s+([a-zA-Z0-9_]+)\\s+[^\\{]*?\\bimplements\\s+[^\\{]*?\\b(WorkflowDefinition|VersionedWorkflow)\\b');
        
        for (ApexClass ac : classes) {
            if (ac.Body != null) {
                Matcher pm = classPattern.matcher(ac.Body);
                while (pm.find()) {
                    String className = pm.group(1);
                    // Check if it's the outer class or an inner class
                    if (className.equalsIgnoreCase(ac.Name)) {
                        // Exclude test classes
                        if (!ac.Name.contains('WorkflowEngineTest') && !ac.Name.contains('WorkflowDashboardControllerTest')) {
                            definitions.add(ac.Name);
                        }
                    } else {
                        // Inner class: prefix with outer class name
                        // Exclude test classes
                        if (!ac.Name.contains('WorkflowEngineTest') && !ac.Name.contains('WorkflowDashboardControllerTest')) {
                            definitions.add(ac.Name + '.' + className);
                        }
                    }
                }
            }
        }
        definitions.sort();
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
    
    @AuraEnabled
    public static void retryWorkflowInstance(Id instanceId) {
        try {
            WorkflowEngine.retryWorkflow(instanceId);
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static void cancelWorkflow(Id instanceId, Boolean runCompensations) {
        try {
            WorkflowEngine.cancel(instanceId, runCompensations);
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static void submitApproval(Id instanceId, String approvalKey, Boolean approved, String comments) {
        try {
            Map<String, Object> payload = new Map<String, Object>{
                'approved' => approved,
                'comments' => comments,
                'approver' => UserInfo.getName()
            };
            String payloadJson = JSON.serialize(payload);
            String signalName = 'Approve:' + approvalKey;
            
            Workflow_Instance__c inst = [
                SELECT Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :instanceId
            ];
            String targetKey = String.isNotBlank(inst.Correlation_Key__c) ? inst.Correlation_Key__c : inst.Id;
            WorkflowEngine.signal(targetKey, signalName, payloadJson);
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }
}
