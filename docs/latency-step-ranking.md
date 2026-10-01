# Latency step ranking

The Latency panel ranks steps by median wall-clock time. The time includes durable waits.

## How the engine times a step

| Step | Time measured |
| --- | --- |
| Not last | Its `CreatedDate` to the next step's `CreatedDate`. |
| Last | Its `CreatedDate` to `Terminal_At__c` of the instance. |
| Fan-out sibling | No sample. |

- A negative time gives no sample.
- A capped step scan can cut the last instance short. That instance gets no last-step sample.
- The end-to-end percentiles do not change.

## Fan-out siblings

A parallel step inserts all branch rows together. Their `CreatedDate` values are equal. The engine cannot time each branch, so it skips them.

The result has `stepsApproximate = true`. The panel shows an **Approximate** badge.

`CreatedDate` has one-second precision. Two fast serial steps in the same second look like siblings. The engine skips them and shows the badge.
