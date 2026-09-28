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
 *   3. A timeout or HTTP 408, 409, or 5xx has an unknown result. The step
 *      retries with the same key. Other codes fail the step. The saga then
 *      rolls back, but a rollback does not undo a remote effect.
 *
 * Why two steps: acquire() does DML. Apex blocks a callout after DML in the
 * same transaction. The engine runs each step in a new transaction.
 * ThrottledCalloutStep implements CalloutStep, so the engine does no DML
 * before execute().
 *
 * A sleep is not a failure. It does not unwind the compensation stack.
 *
 * A RetryPolicy retry, an HTTP 429 resume, or an operator re-drive runs
 * ThrottledCalloutStep again without a new token. To take a token for each
 * call, make getNextStep() return ACQUIRE_STEP after the callout step. A loop
 * starts a new step visit, so the callout gets a new idempotency key. Use a
 * loop only when the API applied no effect.
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
  /** @description Time after the first HTTP 429 when the step fails. */
  public static final Integer MAX_REMOTE_THROTTLE_SECONDS = 86400;
  /** @description Capture key for the time of the first HTTP 429. */
  public static final String FIRST_THROTTLE_KEY = 'firstRemoteThrottleMs';

  private static final String ACQUIRE_STEP = 'ThrottledCalloutWorkflowExample.AcquireTokenStep';
  private static final String CALLOUT_STEP = 'ThrottledCalloutWorkflowExample.ThrottledCalloutStep';
  private static final List<String> MONTHS = new List<String>{
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  };

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
      // getNextStep() routes to the callout step.
      return StepResult.complete(null, null);
    }
  }

  /**
   * @description Calls the API with the step's idempotency key. An HTTP 429
   * makes a durable sleep. CalloutStep: the engine does no DML before
   * execute().
   */
  public class ThrottledCalloutStep implements WorkflowStep, CalloutStep, AutoRetryConfigurable {
    /**
     * @description Sends the request and maps the status code.
     * @param ctx The step context.
     * @return COMPLETE for 2xx, SLEEP for 429, RETRY for 408, 409, or 5xx,
     * else FAIL.
     */
    public StepResult execute(StepContext ctx) {
      HttpRequest req = new HttpRequest();
      req.setEndpoint(ENDPOINT);
      req.setMethod('POST');
      req.setHeader('Content-Type', 'application/json');
      // The key is the same on each run of this step visit. The API applies
      // one effect. Send the same body on each run.
      req.setHeader('Idempotency-Key', ctx.idempotencyKey);
      req.setBody(
        String.isBlank(ctx.workflowInputJson) ? '{}' : ctx.workflowInputJson
      );

      HttpResponse res = transport.send(req);
      Integer code = res.getStatusCode();
      if (code >= 200 && code < 300) {
        return StepResult.complete(
          null,
          new Map<String, Object>{ 'statusCode' => code }
        );
      }
      if (code == 429) {
        return remoteThrottle(ctx, res);
      }
      if (code == 408 || code == 409 || code >= 500) {
        // Unknown result. Retry with the same key.
        return StepResult.retry(getAutoRetryPolicy());
      }
      return StepResult.fail('Throttled API returned HTTP ' + code);
    }

    /**
     * @description Retry policy for a thrown CalloutException (for example, a
     * timeout) and for HTTP 408, 409, or 5xx. A retry keeps the same key.
     * @return Four attempts: 30 s, then 60 s, then 120 s.
     */
    public RetryPolicy getAutoRetryPolicy() {
      return new RetryPolicy(30, (Double) 2.0, 4);
    }
  }

  // HTTP 429: the API refuses more requests now. Sleep for Retry-After. Do not
  // fail. once() keeps the time of the first 429 across sleeps and retries.
  // If the API still returns 429 after MAX_REMOTE_THROTTLE_SECONDS, fail.
  private static StepResult remoteThrottle(StepContext ctx, HttpResponse res) {
    Long firstMs = Long.valueOf(
      (String) ctx.captures().once(FIRST_THROTTLE_KEY, new NowProducer())
    );
    Long waitedSeconds = (System.currentTimeMillis() - firstMs) / 1000;
    if (waitedSeconds >= MAX_REMOTE_THROTTLE_SECONDS) {
      return StepResult.fail(
        'Throttled API returned HTTP 429 for ' + waitedSeconds + ' s'
      );
    }
    return StepResult.sleep(retryAfterSeconds(res));
  }

  /**
   * @description Produces the current time in epoch milliseconds, as a String.
   */
  private class NowProducer implements CaptureProducer {
    /**
     * @description Returns the current time.
     * @return The epoch milliseconds, as a String.
     */
    public Object produce() {
      return String.valueOf(System.currentTimeMillis());
    }
  }

  // Reads Retry-After as seconds or as an HTTP-date. Uses the default for a
  // missing, unknown, zero, or past value. Caps the value at
  // MAX_RETRY_AFTER_SECONDS.
  private static Integer retryAfterSeconds(HttpResponse res) {
    String raw = res.getHeader('Retry-After');
    raw = (raw == null) ? '' : raw.trim();
    Long seconds = null;
    String digits = raw.replaceFirst('^0+(?=\\d)', '');
    if (raw.isNumeric() && digits.length() <= 9) {
      seconds = Long.valueOf(digits);
    } else if (raw.isNumeric()) {
      seconds = MAX_RETRY_AFTER_SECONDS;
    } else {
      Datetime wakeAt = parseHttpDate(raw);
      if (wakeAt != null) {
        Decimal waitMs = wakeAt.getTime() - System.currentTimeMillis();
        seconds = waitMs.divide(1000, 3).round(System.RoundingMode.CEILING);
      }
    }
    if (seconds == null || seconds < 1) {
      return DEFAULT_RETRY_AFTER_SECONDS;
    }
    return Math.min(seconds, (Long) MAX_RETRY_AFTER_SECONDS).intValue();
  }

  // Parses an HTTP-date, for example "Wed, 21 Oct 2026 07:28:00 GMT".
  // Returns null for a different form.
  private static Datetime parseHttpDate(String raw) {
    List<String> parts = raw.split(' ');
    if (parts.size() != 6 || parts[5] != 'GMT') {
      return null;
    }
    Integer month = MONTHS.indexOf(parts[2]) + 1;
    List<String> clock = parts[4].split(':');
    if (month == 0 || clock.size() != 3) {
      return null;
    }
    try {
      return Datetime.newInstanceGmt(
        Integer.valueOf(parts[3]),
        month,
        Integer.valueOf(parts[1]),
        Integer.valueOf(clock[0]),
        Integer.valueOf(clock[1]),
        Integer.valueOf(clock[2])
      );
    } catch (TypeException e) {
      return null;
    }
  }
}
