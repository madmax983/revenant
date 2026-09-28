/**
 * @description Reference example for durable back-off under rate limiting (#106).
 *
 * Contract:
 *   1. AcquireTokenStep calls RateLimiter.acquire(). An empty bucket returns
 *      StepResult.sleep(sleepDurationSeconds). It does not throw, fail, or loop.
 *   2. ThrottledCalloutStep sends the request with the header
 *      Idempotency-Key = ctx.idempotencyKey. An HTTP 429 returns
 *      StepResult.sleep(Retry-After). The step runs again on resume with the
 *      same key, so the API applies one effect.
 *
 * Why two steps: acquire() does DML. Apex blocks a callout after DML in the
 * same transaction. The engine runs each step in a new transaction.
 *
 * A sleep is not a failure. It does not unwind the compensation stack.
 *
 * A RetryPolicy retry, an HTTP 429 resume, or an operator re-drive runs
 * ThrottledCalloutStep again without a new token. To take a token for each
 * call, return StepResult.complete(ACQUIRE_STEP, null) from the callout step.
 *
 * See docs/rate-limiting.md.
 */
public inherited sharing class ThrottledCalloutWorkflowExample {
  /** @description Rate_Limit_Config__mdt DeveloperName for the bucket. */
  public static final String INTEGRATION_KEY = 'ThrottledService';
  /** @description API endpoint. Use a Named Credential in production. */
  public static final String ENDPOINT = 'https://httpbin.org/post';
  /** @description Sleep for an HTTP 429 with no valid Retry-After value. */
  public static final Integer DEFAULT_RETRY_AFTER_SECONDS = 60;
  /** @description Longest sleep for one HTTP 429. */
  public static final Integer MAX_RETRY_AFTER_SECONDS = 3600;

  private static final String ACQUIRE_STEP = 'ThrottledCalloutWorkflowExample.AcquireTokenStep';
  private static final String CALLOUT_STEP = 'ThrottledCalloutWorkflowExample.ThrottledCalloutStep';

  /** @description Sends the HTTP request. Tests replace it with a fake. */
  public interface Transport {
    /**
     * @description Sends one request.
     * @param req The request to send.
     * @return The response.
     */
    HttpResponse send(HttpRequest req);
  }

  /** @description Production transport. It makes a real callout. */
  public class HttpTransport implements Transport {
    /**
     * @description Sends the request with Http.send.
     * @param req The request to send.
     * @return The response.
     */
    public HttpResponse send(HttpRequest req) {
      return new Http().send(req);
    }
  }

  @TestVisible
  private static Transport transport = new HttpTransport();

  /**
   * @description Two steps: take a token, then call the API.
   */
  public class ThrottledCalloutWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps in order.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ ACQUIRE_STEP, CALLOUT_STEP };
    }

    /**
     * @description Names the first step.
     * @return The acquire step.
     */
    public String getInitialStep() {
      return ACQUIRE_STEP;
    }

    /**
     * @description Names the next step.
     * @param currentStepName The step that completed.
     * @param result The result of that step.
     * @return The callout step after the acquire step, else null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return currentStepName == ACQUIRE_STEP ? CALLOUT_STEP : null;
    }
  }

  /**
   * @description Takes a token. An empty bucket makes a durable sleep.
   */
  public class AcquireTokenStep implements WorkflowStep {
    /**
     * @description Takes a token, or sleeps until the bucket refills.
     * @param ctx The step context.
     * @return SLEEP when the bucket is empty, else COMPLETE to the callout step.
     */
    public StepResult execute(StepContext ctx) {
      RateLimiter.AcquireResult token = RateLimiter.acquire(INTEGRATION_KEY);
      if (!token.isAllowed) {
        // Not a failure. The engine runs this step again after the sleep.
        return StepResult.sleep(token.sleepDurationSeconds);
      }
      return StepResult.complete(CALLOUT_STEP, null);
    }
  }

  /**
   * @description Calls the API with the step's idempotency key. An HTTP 429
   * makes a durable sleep.
   */
  public class ThrottledCalloutStep implements WorkflowStep, CalloutStep {
    /**
     * @description Sends the request and maps the status code.
     * @param ctx The step context.
     * @return COMPLETE for 2xx, SLEEP for 429, else FAIL.
     */
    public StepResult execute(StepContext ctx) {
      HttpRequest req = new HttpRequest();
      req.setEndpoint(ENDPOINT);
      req.setMethod('POST');
      req.setHeader('Content-Type', 'application/json');
      // The key is the same on each run of this step visit. The API applies
      // one effect.
      req.setHeader('Idempotency-Key', ctx.idempotencyKey);
      req.setBody(
        String.isBlank(ctx.workflowInputJson) ? '{}' : ctx.workflowInputJson
      );

      HttpResponse res = transport.send(req);
      Integer code = res.getStatusCode();
      if (code == 429) {
        // The API is full. Sleep. Do not fail.
        return StepResult.sleep(retryAfterSeconds(res));
      }
      if (code >= 200 && code < 300) {
        return StepResult.complete(
          null,
          new Map<String, Object>{ 'statusCode' => code }
        );
      }
      return StepResult.fail('Throttled API returned HTTP ' + code);
    }
  }

  // Reads Retry-After in seconds. Uses the default for a missing, non-integer,
  // or zero value. Caps the value at MAX_RETRY_AFTER_SECONDS.
  private static Integer retryAfterSeconds(HttpResponse res) {
    String raw = res.getHeader('Retry-After');
    raw = (raw == null) ? '' : raw.trim();
    if (!raw.isNumeric()) {
      return DEFAULT_RETRY_AFTER_SECONDS;
    }
    if (raw.length() > 9) {
      return MAX_RETRY_AFTER_SECONDS;
    }
    Integer seconds = Integer.valueOf(raw);
    if (seconds < 1) {
      return DEFAULT_RETRY_AFTER_SECONDS;
    }
    return Math.min(seconds, MAX_RETRY_AFTER_SECONDS);
  }
}
