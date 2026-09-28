// Issue #132: run once after deploy, as a user with Modify All Data.
// Puts waiting instances from before admission priority into the indexed
// admission queue, so that the gate sees them at once. The watchdog heartbeat
// does the same, 200 rows per sweep. Run again until it prints 0.
Integer fixed = ConcurrencyAdmissionOrder.backfillQueue(5000);
System.debug('Admission queue rows fixed: ' + fixed);
