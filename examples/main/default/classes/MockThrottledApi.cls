/**
 * @description Test fake for the API in ThrottledCalloutWorkflowExample (#106).
 * It is the example's Transport and an HttpCalloutMock. It applies one effect
 * for each Idempotency-Key, as a Stripe-style API does. A request with no key
 * always applies an effect.
 */
@IsTest
public class MockThrottledApi implements ThrottledCalloutWorkflowExample.Transport, HttpCalloutMock {
  /** @description Number of requests, including repeats. */
  public static Integer calls = 0;
  /** @description Number of effects applied. */
  public static Integer effects = 0;
  /** @description Idempotency keys of the applied effects. */
  public static Set<String> keys = new Set<String>();
  /** @description Idempotency keys of all requests. */
  public static Set<String> sentKeys = new Set<String>();
  /** @description The last request. */
  public static HttpRequest lastRequest;
  private static List<HttpResponse> queued = new List<HttpResponse>();

  /**
   * @description Clears the state and sets this fake as the example transport.
   */
  public static void reset() {
    calls = 0;
    effects = 0;
    keys.clear();
    sentKeys.clear();
    lastRequest = null;
    queued.clear();
    ThrottledCalloutWorkflowExample.transport = new MockThrottledApi();
  }

  /**
   * @description Queues one response. When the queue is empty, the fake
   * returns HTTP 200.
   * @param statusCode The HTTP status code.
   * @param retryAfter The Retry-After header value, or null for no header.
   */
  public static void queue(Integer statusCode, String retryAfter) {
    queued.add(response(statusCode, retryAfter));
  }

  /**
   * @description Handles the request as the example transport.
   * @param req The request.
   * @return The next response.
   */
  public HttpResponse send(HttpRequest req) {
    return respond(req);
  }

  /**
   * @description Handles the request. A 2xx response applies an effect only
   * for a new key.
   * @param req The request.
   * @return The next response.
   */
  public HttpResponse respond(HttpRequest req) {
    calls++;
    lastRequest = req;
    HttpResponse res = queued.isEmpty()
      ? response(200, null)
      : queued.remove(0);
    Integer code = res.getStatusCode();
    String key = req.getHeader('Idempotency-Key');
    sentKeys.add(key);
    Boolean isSuccess = code >= 200 && code < 300;
    if (isSuccess && (String.isBlank(key) || !keys.contains(key))) {
      effects++;
      if (String.isNotBlank(key)) {
        keys.add(key);
      }
    }
    return res;
  }

  private static HttpResponse response(Integer statusCode, String retryAfter) {
    HttpResponse res = new HttpResponse();
    res.setStatusCode(statusCode);
    res.setBody('{"ok":' + (statusCode == 200) + '}');
    if (retryAfter != null) {
      res.setHeader('Retry-After', retryAfter);
    }
    return res;
  }
}
