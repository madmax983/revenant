/**
 * Marker interface for a step that performs an HTTP callout whose endpoint or
 * body is derived from an inbound signal payload it reads in the SAME execution.
 *
 * In a parallel branch the engine normally claims signals at read time (writing
 * Workflow_Signal__c.Status__c = 'Processing') so two concurrent branches cannot
 * both process the same payload. That claim is uncommitted DML, and Salesforce
 * forbids a callout once a transaction has pending DML -- so a branch that reads
 * a signal and then calls out based on its payload would hit the uncommitted-work
 * exception, fail, retry, re-claim, and never make progress.
 *
 * Implementing this interface opts the step's signal reads out of claiming: in a
 * parallel branch it reads pending signals WITHOUT writing Processing, so the
 * subsequent callout is legal. The trade-off is at-least-once delivery rather
 * than exactly-once: if two parallel branches read the same signal name
 * concurrently, both may observe the payload. Use distinct signal names per
 * branch (or perform idempotent callouts) when relying on this mode. Serial
 * steps never claim, so the marker is a no-op there.
 */
public interface CalloutStep {
}
