public class OnboardingWorkflowExample implements WorkflowDefinition {
    
    public String getInitialStep() {
        return 'OnboardingWorkflowExample.VerifyOrderStep';
    }

    public String getNextStep(String currentStepName, StepResult stepResult) {
        if (currentStepName == 'OnboardingWorkflowExample.VerifyOrderStep') {
            return 'OnboardingWorkflowExample.SplitOnboardingStep';
        }
        if (currentStepName == 'OnboardingWorkflowExample.SplitOnboardingStep') {
            return 'OnboardingWorkflowExample.JoinOnboardingStep';
        }
        if (currentStepName == 'OnboardingWorkflowExample.JoinOnboardingStep') {
            return 'OnboardingWorkflowExample.VIPApprovalStep';
        }
        if (currentStepName == 'OnboardingWorkflowExample.VIPApprovalStep') {
            return 'OnboardingWorkflowExample.WelcomeWorkflowLauncherStep';
        }
        if (currentStepName == 'OnboardingWorkflowExample.WelcomeWorkflowLauncherStep') {
            return 'OnboardingWorkflowExample.CompleteOnboardingStep';
        }
        return null;
    }

    // --- STEP DEFINITIONS ---

    public class VerifyOrderStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            if (String.isBlank(ctx.inputJson)) {
                throw new WorkflowEngine.WorkflowException('Input payload is required');
            }
            Map<String, Object> inputMap = (Map<String, Object>)JSON.deserializeUntyped(ctx.inputJson);
            Decimal amount = (Decimal)inputMap.get('amount');
            if (amount == null || amount <= 0) {
                throw new WorkflowEngine.WorkflowException('Order amount must be positive');
            }
            return StepResult.complete(null, inputMap);
        }
    }

    public class SplitOnboardingStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            return StepResult.split(new List<String>{
                'OnboardingWorkflowExample.ProvisionSandboxStep',
                'OnboardingWorkflowExample.CreateBillingAccountStep'
            }, ctx.previousStepOutput);
        }
    }

    public class ProvisionSandboxStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            Map<String, Object> order = (Map<String, Object>)JSON.deserializeUntyped(ctx.inputJson);
            
            String sandboxOrgId = '00D' + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(15);
            Map<String, Object> result = new Map<String, Object>{
                'sandboxOrgId' => sandboxOrgId,
                'status' => 'Provisioned'
            };
            return StepResult.complete(null, result);
        }
    }

    public class CreateBillingAccountStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            Map<String, Object> order = (Map<String, Object>)JSON.deserializeUntyped(ctx.inputJson);
            
            String billingAccountId = 'cust_billing_' + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(8);
            Map<String, Object> result = new Map<String, Object>{
                'billingAccountId' => billingAccountId,
                'status' => 'Created'
            };
            return StepResult.complete(null, result);
        }
    }

    public class JoinOnboardingStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            Map<String, Object> parallelOutputs = (Map<String, Object>)JSON.deserializeUntyped(ctx.inputJson);
            return StepResult.complete(null, parallelOutputs);
        }
    }

    public class VIPApprovalStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            Map<String, Object> instanceInput = (Map<String, Object>)JSON.deserializeUntyped(ctx.workflowInputJson);
            Decimal amount = (Decimal)instanceInput.get('amount');

            if (amount >= 10000.0) {
                List<Workflow_Signal__c> signals = [
                    SELECT Id, Payload__c FROM Workflow_Signal__c
                    WHERE Workflow_Instance__c = :ctx.workflowInstanceId
                    AND Signal_Name__c = 'Approve:VIPOrderApproval'
                    AND Status__c = 'Received'
                    LIMIT 1
                ];

                if (signals.isEmpty()) {
                    return StepResult.waitForApproval('VIPOrderApproval', 'Executive Manager');
                }

                Workflow_Signal__c sig = signals[0];
                sig.Status__c = 'Consumed';
                update sig;

                Map<String, Object> payloadMap = (Map<String, Object>)JSON.deserializeUntyped(sig.Payload__c);
                Boolean approved = (Boolean)payloadMap.get('approved');
                if (!approved) {
                    throw new WorkflowEngine.WorkflowException('VIP order was rejected by executive manager.');
                }
            }

            return StepResult.complete(null, 'VIP Approval Checked');
        }
    }

    public class WelcomeWorkflowLauncherStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            Map<String, Object> instanceInput = (Map<String, Object>)JSON.deserializeUntyped(ctx.workflowInputJson);
            String email = (String)instanceInput.get('email');
            
            String childKey = 'WelcomeEmail_' + ctx.workflowInstanceId;
            
            List<Workflow_Signal__c> signals = [
                SELECT Id, Payload__c FROM Workflow_Signal__c
                WHERE Workflow_Instance__c = :ctx.workflowInstanceId
                AND Signal_Name__c = :('ChildCompleted:' + childKey)
                AND Status__c = 'Received'
                LIMIT 1
            ];

            if (!signals.isEmpty()) {
                signals[0].Status__c = 'Consumed';
                update signals[0];
                return StepResult.complete(null, 'Welcome Email Sent Successfully');
            }

            return StepResult.startChild(
                'OnboardingWorkflowExample.WelcomeEmailWorkflow', 
                childKey, 
                email
            );
        }
    }

    public class CompleteOnboardingStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            Map<String, Object> onboardingResults = new Map<String, Object>{
                'status' => 'Completed',
                'completedDate' => Datetime.now()
            };
            return StepResult.complete(null, onboardingResults);
        }
    }

    // --- WELCOME EMAIL CHILD WORKFLOW ---

    public class WelcomeEmailWorkflow implements WorkflowDefinition {
        public String getInitialStep() {
            return 'OnboardingWorkflowExample.DelayEmailStep';
        }
        public String getNextStep(String currentStepName, StepResult stepResult) {
            if (currentStepName == 'OnboardingWorkflowExample.DelayEmailStep') {
                return 'OnboardingWorkflowExample.SendEmailStep';
            }
            return null;
        }
    }

    public class DelayEmailStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            if (ctx.stepStateJson != null) {
                return StepResult.complete(null, ctx.inputJson);
            }
            return StepResult.sleep(5, 'slept');
        }
    }

    public class SendEmailStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            String email = (String)JSON.deserialize(ctx.inputJson, String.class);
            System.debug('Welcome email sent to: ' + email);
            return StepResult.complete(null, 'Sent welcome email to ' + email);
        }
    }
}
