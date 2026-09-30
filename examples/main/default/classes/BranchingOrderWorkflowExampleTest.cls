/**
 * Tests for BranchingOrderWorkflowExample (issue #141). The graph shows the
 * routes that the probe finds and names the gaps. The overlay shows where a
 * parked run is and what advances it.
 */
@IsTest
private class BranchingOrderWorkflowExampleTest {
  static final String WF = 'BranchingOrderWorkflowExample';
  static final String VALIDATE = WF + '.ValidateOrderStep';
  static final String REVIEW = WF + '.ManualReviewStep';
  static final String RESERVE = WF + '.ReserveStockStep';
  static final String CHARGE = WF + '.ChargePaymentStep';
  static final String SHIP = WF + '.ShipStep';
  static final String BACKORDER = WF + '.BackorderStep';
  static final String CANCEL = WF + '.CancelOrderStep';

  private static Boolean hasEdge(
    List<WorkflowTopology.Edge> edges,
    String source,
    String target
  ) {
    for (WorkflowTopology.Edge e : edges) {
      if (e.source == source && e.target == target) {
        return true;
      }
    }
    return false;
  }

  private static Map<String, WorkflowTopology.Node> byName(
    WorkflowTopology.Graph graph
  ) {
    Map<String, WorkflowTopology.Node> nodes = new Map<String, WorkflowTopology.Node>();
    for (WorkflowTopology.Node n : graph.nodes) {
      nodes.put(n.name, n);
    }
    return nodes;
  }

  @IsTest
  static void graphShowsKnownRoutesAndGapsWithoutARun() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build(WF);
      Map<String, WorkflowTopology.Node> nodes = byName(graph);

      Assert.areEqual(7, graph.nodes.size());
      Assert.areEqual(VALIDATE, graph.initialStep);
      Assert.isTrue(hasEdge(graph.edges, VALIDATE, RESERVE));
      Assert.isTrue(hasEdge(graph.edges, RESERVE, CHARGE));
      Assert.isTrue(hasEdge(graph.edges, CHARGE, SHIP));
      Assert.isTrue(nodes.get(SHIP).terminal);
      Assert.isTrue(nodes.get(RESERVE).compensatable);
      Assert.isTrue(nodes.get(CHARGE).compensatable);
      Assert.isTrue(
        nodes.get(REVIEW).routingUnknown,
        'The review router fails closed on an unknown decision'
      );
      Assert.isFalse(nodes.get(REVIEW).reachable, 'Only data reaches it');
      Assert.isFalse(nodes.get(BACKORDER).reachable);
      Assert.isFalse(nodes.get(CANCEL).reachable);
      Assert.isTrue(graph.gapsFound, 'The graph is not complete');
      Assert.isTrue(graph.defects.isEmpty(), String.valueOf(graph.defects));
    }
  }

  @IsTest
  static void parkedReviewShowsPositionAndWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        WF,
        'branching-order-review',
        new Map<String, Object>{ 'amount' => 25000, 'inStock' => true }
      );
      WorkflowTestHarness.Result parked = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      Assert.areEqual('Suspended', parked.status);
      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(
          instanceId
        )
        .overlay;
      Assert.areEqual(new List<String>{ REVIEW }, overlay.currentSteps);
      Assert.areEqual(
        WorkflowTopology.STATE_AWAITING_SIGNAL,
        overlay.currentState
      );
      Assert.areEqual(VALIDATE, overlay.path[0].stepName);
      Assert.areEqual(REVIEW, overlay.path[overlay.path.size() - 1].stepName);
    }
  }

  @IsTest
  static void approvedReviewRunsToShip() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      String key = 'branching-order-approved';
      Id instanceId = WorkflowEngine.start(
        WF,
        key,
        new Map<String, Object>{ 'amount' => 25000, 'inStock' => true }
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.drive();
      WorkflowTestHarness.Result done = harness.injectSignal(
        key,
        BranchingOrderWorkflowExample.REVIEW_SIGNAL,
        '{"decision":"approve"}'
      );
      Test.stopTest();

      Assert.areEqual('Completed', done.status);
      Assert.isTrue(done.reachedStep(SHIP));
      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(
          instanceId
        )
        .overlay;
      Assert.areEqual(WorkflowTopology.STATE_ENDED, overlay.currentState);
      Assert.areEqual(new List<String>{ SHIP }, overlay.currentSteps);
      Assert.isTrue(overlay.nextSteps.isEmpty(), 'An ended run has no next');
    }
  }

  @IsTest
  static void lowRiskOutOfStockGoesToBackorder() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        WF,
        'branching-order-backorder',
        new Map<String, Object>{ 'amount' => 100, 'inStock' => false }
      );
      WorkflowTestHarness.Result done = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      Assert.areEqual('Completed', done.status);
      Assert.isTrue(done.reachedStep(BACKORDER));
      Assert.isFalse(done.reachedStep(REVIEW));
    }
  }

  @IsTest
  static void rejectedReviewCancels() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      String key = 'branching-order-rejected';
      Id instanceId = WorkflowEngine.start(
        WF,
        key,
        new Map<String, Object>{ 'amount' => 25000, 'inStock' => true }
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.drive();
      WorkflowTestHarness.Result done = harness.injectSignal(
        key,
        BranchingOrderWorkflowExample.REVIEW_SIGNAL,
        '{"decision":"reject"}'
      );
      Test.stopTest();

      Assert.areEqual('Completed', done.status);
      Assert.isTrue(done.reachedStep(CANCEL));
    }
  }
}
