/**
 * Reference example for event-keyed aggregation.
 *
 * This workflow aggregates multiple inbound events for the same correlation key.
 * It accumulates event payloads in the step state, suspending itself until it
 * has received at least 3 events. Once 3 events are accumulated, it moves to
 * the processing step and completes.
 */
public inherited sharing class EventAggregationWorkflowExample implements WorkflowDefinition {
  public static final String EVENT_SIGNAL = 'Approve:Event';

  /**
   * @description Returns the ordered step names composing this aggregation workflow.
   * @return The accumulate and process-batch step names.
   */
  public List<String> getSteps() {
    return new List<String>{
      'EventAggregationWorkflowExample.AccumulateStep',
      'EventAggregationWorkflowExample.ProcessBatchStep'
    };
  }

  /**
   * @description Returns the step the workflow begins with.
   * @return The accumulate step name.
   */
  public String getInitialStep() {
    return 'EventAggregationWorkflowExample.AccumulateStep';
  }

  /**
   * @description Advances from accumulation to batch processing once the threshold
   * of events has been reached.
   * @param currentStepName The name of the step that just completed.
   * @param stepResult The result of the completed step.
   * @return The process-batch step after accumulation, or null to end the workflow.
   */
  public String getNextStep(String currentStepName, StepResult stepResult) {
    if (currentStepName == 'EventAggregationWorkflowExample.AccumulateStep') {
      return 'EventAggregationWorkflowExample.ProcessBatchStep';
    }
    return null;
  }

  // --- STEP DEFINITIONS ---

  /**
   * @description Accumulates inbound event payloads in the durable step state,
   * suspending until at least three distinct events for the correlation key arrive.
   */
  public class AccumulateStep implements WorkflowStep {
    /**
     * @description Merges the pending event signals into the accumulated state,
     * completing once three are collected or otherwise suspending for more.
     * @param ctx The durable step context exposing the accumulated state and pending signals.
     * @return COMPLETE with the collected payloads at the threshold, or SUSPEND to await more.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, String> accumulatedMap = new Map<String, String>();
      if (String.isNotBlank(ctx.stepStateJson)) {
        accumulatedMap = (Map<String, String>) JSON.deserialize(
          ctx.stepStateJson,
          Map<String, String>.class
        );
      }

      // Read all pending events that woke us
      List<StepContext.Signal> signals = ctx.getSignals(EVENT_SIGNAL);
      for (StepContext.Signal sig : signals) {
        if (sig.isPresent()) {
          accumulatedMap.put(
            String.valueOf(sig.signalId),
            normalizePayload(sig)
          );
        }
      }

      if (accumulatedMap.size() >= 3) {
        // We have reached our aggregation threshold, complete the step
        // Decoupled routing: nextStepName is null, resolved by getNextStep
        return StepResult.complete(null, accumulatedMap.values());
      }

      // Otherwise, save state and suspend waiting for more events
      return StepResult.suspend(JSON.serialize(accumulatedMap));
    }

    /**
     * Unwraps a JSON-encoded string payload (e.g. `"Item-A"`) to its raw value,
     * falling back to the original payload when it is not a quoted JSON string or
     * cannot be deserialized.
     */
    private String normalizePayload(StepContext.Signal sig) {
      String parsedPayload = sig.payload;
      Boolean looksJsonQuoted =
        String.isNotBlank(parsedPayload) &&
        parsedPayload.startsWith('"') &&
        parsedPayload.endsWith('"') &&
        parsedPayload.length() >= 2;
      if (looksJsonQuoted) {
        try {
          return (String) JSON.deserialize(sig.payload, String.class);
        } catch (Exception ignored) {
          // Use raw payload if it fails to deserialize
        }
      }
      return parsedPayload;
    }
  }

  /**
   * @description Terminal step that processes the accumulated batch of events once
   * the aggregation threshold has been met.
   */
  public class ProcessBatchStep implements WorkflowStep {
    /**
     * @description Reads the accumulated payloads from the previous step, sorts them,
     * and completes with a processing summary.
     * @param ctx The durable step context supplying the previous step's accumulated output.
     * @return A COMPLETE result summarizing the processed events.
     */
    public StepResult execute(StepContext ctx) {
      List<String> processed = new List<String>();
      if (String.isNotBlank(ctx.previousStepOutput)) {
        try {
          processed = (List<String>) JSON.deserialize(
            ctx.previousStepOutput,
            List<String>.class
          );
        } catch (Exception ignored) {
          // Handle/ignore malformed input
        }
      }
      if (processed == null) {
        processed = new List<String>();
      }
      processed.sort();
      // Simulate batch processing
      return StepResult.complete(
        null,
        'Processed ' +
          processed.size() +
          ' events: ' +
          String.join(processed, ', ')
      );
    }
  }
}
