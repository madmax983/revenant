/**
 * Subscriber for the reference Order_Shipped__e domain event (issue #64).
 * Starts the downstream refund workflow (Workflow B) when a shipment workflow
 * (Workflow A) step emits Order_Shipped__e on its COMPLETE transition.
 *
 * Delivery is at-least-once, so this handler stays idempotent (WorkflowEngine.start
 * is get-or-start by correlation key). The producer-side effectively-once
 * publish is what keeps a forced retry/re-drive of the emitting step from
 * asking it to start B more than once per shipment.
 */
trigger OrderShippedTrigger on Order_Shipped__e(after insert) {
  OrderChoreographyWorkflowExample.onOrderShipped(Trigger.new);
}
