// Issue #132: run once after deploy, as a user with Modify All Data.
// Puts waiting instances from before admission priority into the indexed
// admission queue, so that the gate sees them at once. The watchdog heartbeat
// does the same, 200 rows per page. Run again until it prints 0.
// A call that fixes 0 rows can still move the saved cursor past failing
// rows (issue #277). Run until the cursor prints null and the count is 0.
// Page size 1000: max 5 pages = 5000 DML rows, below the 10,000-row limit.
Integer fixed = ConcurrencyAdmissionOrder.backfillQueue(1000);
System.debug('Admission queue rows fixed: ' + fixed);
System.debug('Cursor: ' + Admission_Backfill_Cursor__c.getOrgDefaults().After_Id__c);
