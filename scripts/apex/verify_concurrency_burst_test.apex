// Concurrency-limit burst test (issue #28) — VERIFY.
//
// Reports, per governed workflow definition: the configured ceiling, the durable
// in-flight slot counter, the LIVE count of instances actually in Running/Compensating
// (the AC3 invariant — must stay <= ceiling), and the number of parked/throttled
// instances awaiting admission. Run this repeatedly during a burst drain.
//
// To prove leaked-slot reclamation (AC5): force-kill an admitted instance (e.g. hard-
// delete it or roll back its transaction so its slot is never released), wait one
// watchdog sweep, then re-run — the counter should reconcile down to reality.

for (Concurrency_State__c state : [
  SELECT Workflow_Definition__c, In_Flight_Count__c
  FROM Concurrency_State__c
  ORDER BY Workflow_Definition__c
]) {
  String wf = state.Workflow_Definition__c;
  Integer ceiling = ConcurrencyGate.getCeiling(wf);

  Integer liveRunning = [
    SELECT COUNT()
    FROM Workflow_Instance__c
    WHERE Workflow_Name__c = :wf AND Status__c IN ('Running', 'Compensating')
  ];
  Integer parked = [
    SELECT COUNT()
    FROM Workflow_Instance__c
    WHERE
      Workflow_Name__c = :wf
      AND Status__c = 'Suspended'
      AND Concurrency_Parked__c = true
  ];

  String verdict = (ceiling != null && liveRunning > ceiling)
    ? '  *** VIOLATION: live Running/Compensating exceeds ceiling ***'
    : '';
  System.debug('====================================================');
  System.debug('Workflow: ' + wf);
  System.debug('  Ceiling (config):        ' + ceiling);
  System.debug('  In-flight (counter):     ' + state.In_Flight_Count__c);
  System.debug('  Live Running/Compensating: ' + liveRunning + verdict);
  System.debug('  Parked / throttled:      ' + parked);
}
System.debug('====================================================');
