// Issue #141: seeds three runs of BranchingOrderWorkflowExample for the
// topology graph. Deploy the examples package first.
// Run: sf apex run --file scripts/apex/seed-branching-orders.apex
// Then open each instance in the dashboard and read the Workflow Graph.
// - review:    a large order. It parks at ManualReviewStep for a signal.
// - ship:      a small order in stock. It ends at ShipStep.
// - backorder: a small order out of stock. It ends at BackorderStep.
String suffix = String.valueOf(Datetime.now().getTime());
Map<String, Map<String, Object>> inputs = new Map<String, Map<String, Object>>{
    'review' => new Map<String, Object>{ 'amount' => 25000, 'inStock' => true },
    'ship' => new Map<String, Object>{ 'amount' => 100, 'inStock' => true },
    'backorder' => new Map<String, Object>{ 'amount' => 100, 'inStock' => false }
};
for (String name : inputs.keySet()) {
    Id instanceId = WorkflowEngine.start(
        'BranchingOrderWorkflowExample',
        'branching-' + name + '-' + suffix,
        inputs.get(name)
    );
    System.debug('BRANCHING_' + name.toUpperCase() + '=' + instanceId);
}
// To advance the review run, send the signal Approve:OrderReview with the
// payload {"decision":"approve"} or {"decision":"reject"}.
