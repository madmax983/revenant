public class StepResult {
    public enum ActionType { COMPLETE, SUSPEND, YIELD, RETRY, SLEEP }
    
    public ActionType action { get; set; }
    public String nextStepName { get; set; }
    public String outputJson { get; set; }
    public String stepStateJson { get; set; }
    public Integer retryAfterSeconds { get; set; }
    public RetryPolicy retryPolicy { get; set; }
    public Integer sleepDurationSeconds { get; set; }

    public static StepResult complete(String nextStepName, Object output) {
        StepResult r = new StepResult();
        r.action = ActionType.COMPLETE;
        r.nextStepName = nextStepName;
        r.outputJson = (output != null) ? JSON.serialize(output) : null;
        return r;
    }

    public static StepResult yield(String stepStateJson) {
        StepResult r = new StepResult();
        r.action = ActionType.YIELD;
        r.stepStateJson = stepStateJson;
        return r;
    }

    public static StepResult suspend() {
        StepResult r = new StepResult();
        r.action = ActionType.SUSPEND;
        return r;
    }

    public static StepResult retry(RetryPolicy policy) {
        StepResult r = new StepResult();
        r.action = ActionType.RETRY;
        r.retryPolicy = policy;
        return r;
    }

    public static StepResult retry(Integer retryAfterSeconds) {
        StepResult r = new StepResult();
        r.action = ActionType.RETRY;
        r.retryAfterSeconds = retryAfterSeconds;
        r.retryPolicy = new RetryPolicy(retryAfterSeconds, (Double)1.0, 5); // Backwards compatible fixed interval retry
        return r;
    }

    public static StepResult sleep(Integer seconds) {
        StepResult r = new StepResult();
        r.action = ActionType.SLEEP;
        r.sleepDurationSeconds = seconds;
        return r;
    }

    public static StepResult sleep(Integer seconds, String stepStateJson) {
        StepResult r = new StepResult();
        r.action = ActionType.SLEEP;
        r.sleepDurationSeconds = seconds;
        r.stepStateJson = stepStateJson;
        return r;
    }
}
