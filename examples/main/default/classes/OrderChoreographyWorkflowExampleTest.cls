/**
 * Reference choreography test (issue #64): workflow A's step emits a domain
 * event (Order_Shipped__e) that starts workflow B (the refund/billing workflow).
 *
 * Proves the producer-side effectively-once guarantee end-to-end: the shipping
 * step is forced through >=3 re-executions (yield -> retry -> complete) before
 * its COMPLETE commits, calling ctx.emit() on every one of them. A hand-rolled
 * EventBus.publish() in execute() would start workflow B three times. With the
 * engine coupling the publish to the COMPLETE commit, B is started exactly once.
 */
@isTest
private class OrderChoreographyWorkflowExampleTest {
  @isTest
  static void forcedRetryBeforeCommitDoesNotDoubleStartWorkflowB() {
    WorkflowOutboundEventPublisher.publishedEvents.clear();
    OrderChoreographyWorkflowExample.resetCounters();

    Test.startTest();
    Id shipmentId = WorkflowEngine.start(
      'OrderChoreographyWorkflowExample.ShipmentWorkflow',
      'order-shipped-choreo-1',
      new Map<String, Object>{ 'orderId' => 'ORD-001' }
    );
    // drive() auto-resumes the yield and retry and auto-delivers the published
    // Order_Shipped__e through OrderShippedTrigger, which starts workflow B.
    WorkflowTestHarness.Result result = new WorkflowTestHarness(shipmentId)
      .drive();
    Test.stopTest();

    System.assertEquals(
      'Completed',
      result.status,
      'Shipment workflow (A) must complete'
    );

    // Producer-side effectively-once: the Order_Shipped__e was published once
    // despite the step re-executing (and calling emit()) three times.
    System.assertEquals(
      1,
      WorkflowOutboundEventPublisher.publishedEvents.size(),
      'Exactly one Order_Shipped__e published despite >=3 re-executions'
    );

    // The downstream trigger ran exactly once...
    System.assertEquals(
      1,
      OrderChoreographyWorkflowExample.refundStartCount,
      'Order_Shipped__e subscriber must fire exactly once'
    );

    // ...and started exactly one workflow B instance (not three).
    List<Workflow_Instance__c> refundInstances = [
      SELECT Id, Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = 'OrderChoreographyWorkflowExample.RefundWorkflow'
    ];
    System.assertEquals(
      1,
      refundInstances.size(),
      'Workflow B must be started exactly once (no double-start from retries)'
    );
    System.assertEquals(
      shipmentId,
      refundInstances[0].Causation_Id__c,
      'Downstream B must be causally linked to upstream A via stable trace/causation ID'
    );
  }
}
