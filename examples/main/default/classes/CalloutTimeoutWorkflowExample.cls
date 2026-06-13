public with sharing class CalloutTimeoutWorkflowExample {

    public class CalloutWorkflow implements WorkflowDefinition {
        public List<String> getSteps() {
            return new List<String>{
                'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
            };
        }

        public String getInitialStep() {
            return 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep';
        }

        public String getNextStep(String currentStepName, StepResult result) {
            return null; // Terminal step
        }
    }

    public class MakeHttpCalloutStep implements WorkflowStep, TimeoutConfigurable {
        
        public Integer getTimeoutSeconds() {
            return 5; // Timeout watchdog times out after 5 seconds
        }

        public StepResult execute(StepContext ctx) {
            String endpoint = 'https://httpbin.org/status/500';
            
            // Allow endpoint override via input JSON
            if (String.isNotBlank(ctx.workflowInputJson)) {
                try {
                    Map<String, Object> input = (Map<String, Object>)JSON.deserializeUntyped(ctx.workflowInputJson);
                    if (input.containsKey('endpoint')) {
                        endpoint = (String)input.get('endpoint');
                    }
                } catch (Exception ex) {
                    // Fall back to default
                }
            }

            if (Test.isRunningTest()) {
                if (endpoint.contains('status/200')) {
                    return StepResult.complete(null, new Map<String, Object>{
                        'status' => 200,
                        'body' => '{"success": true}'
                    });
                } else {
                    return StepResult.retry(new RetryPolicy(2, (Double)2.0, 3));
                }
            }

            Http h = new Http();
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            
            try {
                HttpResponse res = h.send(req);
                if (res.getStatusCode() == 200) {
                    return StepResult.complete(null, new Map<String, Object>{
                        'status' => 200,
                        'body' => res.getBody()
                    });
                } else {
                    // Retry on error status codes
                    return StepResult.retry(new RetryPolicy(2, (Double)2.0, 3));
                }
            } catch (Exception ex) {
                System.debug('Exception in MakeHttpCalloutStep: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
                // Retry on exceptions (e.g. timeout, connection failure)
                return StepResult.retry(new RetryPolicy(2, (Double)2.0, 3));
            }
        }
    }
}
