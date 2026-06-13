public inherited sharing class WorkflowAlertManager {

    @TestVisible
    private static Map<String, Workflow_Alert_Config__mdt> mockConfigs = new Map<String, Workflow_Alert_Config__mdt>();
    
    @TestVisible
    public static Integer sentEmailsCount = 0;

    /**
     * Inspects configuration and thresholds, and sends an email alert if needed.
     */
    public static void sendAlert(Workflow_Instance__c instance, String errorMsg) {
        String workflowName = instance.Workflow_Name__c;
        if (String.isBlank(workflowName)) {
            return;
        }

        // 1. Resolve Config
        Workflow_Alert_Config__mdt config = getAlertConfig(workflowName);
        if (config == null || !config.Enable_Alerts__c || String.isBlank(config.Email_Recipients__c)) {
            return;
        }

        // 2. Evaluate Thresholds
        Boolean isThresholdMet = evaluateThresholds(workflowName, config);
        if (!isThresholdMet) {
            return;
        }

        // 3. Dispatch Alert
        dispatchEmail(instance, config.Email_Recipients__c, errorMsg);
    }

    private static Workflow_Alert_Config__mdt getAlertConfig(String workflowName) {
        String devName = workflowName.replaceAll('[^a-zA-Z0-9_]', '_');
        String truncatedDevName = devName.length() > 40 ? devName.substring(0, 40) : devName;
        
        // Check mock configs first
        if (mockConfigs.containsKey(devName)) {
            return mockConfigs.get(devName);
        }
        if (mockConfigs.containsKey(truncatedDevName)) {
            return mockConfigs.get(truncatedDevName);
        }
        if (mockConfigs.containsKey('Default')) {
            return mockConfigs.get('Default');
        }

        // Query specific config
        List<Workflow_Alert_Config__mdt> configs = [
            SELECT Email_Recipients__c, Enable_Alerts__c, 
                   Consecutive_Failures_Limit__c, Failure_Count_Limit__c, 
                   Time_Window_Minutes__c, Stall_Threshold_Hours__c
            FROM Workflow_Alert_Config__mdt
            WHERE DeveloperName = :devName OR DeveloperName = :truncatedDevName
        ];
        if (!configs.isEmpty()) {
            return configs[0];
        }

        // Fallback to Default
        configs = [
            SELECT Email_Recipients__c, Enable_Alerts__c, 
                   Consecutive_Failures_Limit__c, Failure_Count_Limit__c, 
                   Time_Window_Minutes__c, Stall_Threshold_Hours__c
            FROM Workflow_Alert_Config__mdt
            WHERE DeveloperName = 'Default'
        ];
        if (!configs.isEmpty()) {
            return configs[0];
        }

        return null;
    }

    private static Boolean evaluateThresholds(String workflowName, Workflow_Alert_Config__mdt config) {
        Boolean hasConsecutiveLimit = config.Consecutive_Failures_Limit__c != null && config.Consecutive_Failures_Limit__c > 0;
        Boolean hasSlidingWindow = config.Failure_Count_Limit__c != null && config.Failure_Count_Limit__c > 0 
                                && config.Time_Window_Minutes__c != null && config.Time_Window_Minutes__c > 0;

        // If no thresholds are configured, default to sending the alert
        if (!hasConsecutiveLimit && !hasSlidingWindow) {
            return true;
        }

        // Check Consecutive Failures
        if (hasConsecutiveLimit) {
            Integer limitVal = config.Consecutive_Failures_Limit__c.intValue();
            List<Workflow_Instance__c> recent = [
                SELECT Status__c FROM Workflow_Instance__c
                WHERE Workflow_Name__c = :workflowName
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT :limitVal
            ];
            if (recent.size() >= limitVal) {
                Boolean allFailed = true;
                for (Workflow_Instance__c inst : recent) {
                    if (inst.Status__c != 'Failed' && inst.Status__c != 'Compensated' && inst.Status__c != 'Cancelled') {
                        allFailed = false;
                        break;
                    }
                }
                if (allFailed) {
                    return true;
                }
            }
        }

        // Check Sliding Window Count
        if (hasSlidingWindow) {
            Integer limitVal = config.Failure_Count_Limit__c.intValue();
            Integer timeWindow = config.Time_Window_Minutes__c.intValue();
            Datetime windowStart = Datetime.now().addMinutes(-timeWindow);
            
            Integer failCount = [
                SELECT COUNT() FROM Workflow_Instance__c
                WHERE Workflow_Name__c = :workflowName
                AND (Status__c = 'Failed' OR Status__c = 'Compensated' OR Status__c = 'Cancelled')
                AND CreatedDate >= :windowStart
            ];
            
            if (failCount >= limitVal) {
                return true;
            }
        }

        return false;
    }

    private static void dispatchEmail(Workflow_Instance__c instance, String recipients, String errorMsg) {
        List<String> toAddresses = new List<String>();
        for (String email : recipients.split('[,;]')) {
            if (String.isNotBlank(email)) {
                toAddresses.add(email.trim());
            }
        }
        if (toAddresses.isEmpty()) {
            return;
        }

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(toAddresses);
        
        String subject = '[Revenant Alert] Workflow Failure: ' + instance.Workflow_Name__c;
        mail.setSubject(subject);
        
        String htmlBody = '<div style="font-family: sans-serif; padding: 20px; border: 1px solid #e2e8f0; border-radius: 8px; max-width: 600px;">' +
            '<h2 style="color: #e53e3e; margin-top: 0;">Workflow Execution Failed</h2>' +
            '<hr style="border: 0; border-top: 1px solid #e2e8f0; margin-bottom: 20px;"/>' +
            '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' +
            '<tr><td style="padding: 6px 0; font-weight: bold; width: 150px;">Workflow Name:</td><td>' + instance.Workflow_Name__c + '</td></tr>' +
            '<tr><td style="padding: 6px 0; font-weight: bold;">Instance ID:</td><td>' + instance.Name + ' (' + instance.Id + ')</td></tr>' +
            '<tr><td style="padding: 6px 0; font-weight: bold;">Correlation Key:</td><td>' + (String.isNotBlank(instance.Correlation_Key__c) ? instance.Correlation_Key__c : 'N/A') + '</td></tr>' +
            '<tr><td style="padding: 6px 0; font-weight: bold;">Failed Time:</td><td>' + Datetime.now().format() + '</td></tr>' +
            '</table>' +
            '<div style="background-color: #fff5f5; border: 1px solid #fed7d7; border-radius: 4px; padding: 15px; margin-bottom: 20px; color: #c53030;">' +
            '<strong>Error Details:</strong><br/><pre style="white-space: pre-wrap; font-family: monospace; margin: 5px 0 0 0;">' + errorMsg + '</pre>' +
            '</div>' +
            '<p style="font-size: 14px; color: #718096; margin-bottom: 0;">To view and retry this workflow, open the Workflow Dashboard in Salesforce.</p>' +
            '</div>';
            
        mail.setHtmlBody(htmlBody);
        
        if (!Test.isRunningTest()) {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        }
        sentEmailsCount += 1;
    }
}
