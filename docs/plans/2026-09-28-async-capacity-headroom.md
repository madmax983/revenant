# Async Apex Capacity Headroom (Issue #129)

## Goal

Show the operator how much async Apex capacity the org has left. Show the
state before the Queueable chain stops. Read only. No alerts.

## Facts About The Platform And The Engine

- `WorkflowOrchestrator` enqueues the next hop. When the org has no async
  capacity, `System.enqueueJob()` throws and the chain stops.
- `Limits.getAsyncCalls()` and `Limits.getLimitAsyncCalls()` are "reserved
  for future use". They do not give the daily org count.
- `System.OrgLimits.getMap().get('DailyAsyncApexExecutions')` gives the
  daily org count and limit. It costs 0 SOQL. The REST `/limits` resource
  shows the same values. No Setup page shows it.
- The Apex flex queue holds a maximum of 100 batch jobs in `Holding`.
- Queueable jobs in `Queued` have no queue limit. A maximum of 5 batch jobs
  can be `Queued` or `Processing`.
- A `COUNT(Id)` with `GROUP BY` costs one query row for each group. Three
  statuses give max three query rows.
- `WorkflowDashboardController` is at the PMD public-member limit. New
  panels use a new controller (see `WorkflowRateLimitController`).
- `Revenant_Config__mdt.getInstance('Default')` costs 0 SOQL.

## Brainstorming (options)

| #   | Idea                                                            | Keep?                                                           |
| --- | --------------------------------------------------------------- | --------------------------------------------------------------- |
| B1  | Use `Limits.getAsyncCalls()` for the daily count.               | No. Reserved. Returns no org data.                              |
| B2  | Use `OrgLimits` `DailyAsyncApexExecutions`.                     | Yes. Free. Same value as the REST `/limits` resource.           |
| B3  | One `AsyncApexJob` query, `GROUP BY Status`, three statuses.    | Yes. 1 SOQL, max 3 query rows.                                  |
| B4  | Flex queue metric = `Holding` / 100.                            | Yes. 100 is the platform ceiling.                               |
| B5  | Metric for `Queued` + `Processing` against an invented ceiling. | No. Queueables have no queue limit. See B13.                    |
| B6  | Two number fields for warn and critical.                        | No. The issue permits one field.                                |
| B7  | One text field `Async_Capacity_Thresholds__c` = `80,95`.        | Yes. One field. Both thresholds change without code.            |
| B8  | Pure evaluator class with no SOQL.                              | Yes. Unit tests with no data. Easy to prove.                    |
| B9  | New LWC child `asyncCapacityPanel` in System Doctor.            | Yes. Own tests. Small change to the large dashboard.            |
| B10 | Add the metrics to `getWatchdogStatus`.                         | No. That read already runs many queries and the stall detector. |
| B11 | Publish an alert event on Critical.                             | No. Out of scope (#127).                                        |
| B12 | Cache the result in a custom setting.                           | No. Adds a write. The read is cheap.                            |
| B13 | Pending jobs / daily executions left.                           | Yes (review round 1). A real limit. No extra SOQL.              |

## Reverse Brainstorming (how to make it fail)

| How to fail                                              | Counter                                                           |
| -------------------------------------------------------- | ----------------------------------------------------------------- |
| Call the read from the orchestrator.                     | The read lives only in the controller path. Test checks the body. |
| Query all `AsyncApexJob` rows.                           | Aggregate query, `GROUP BY Status`, three statuses only.          |
| Divide by a zero or missing limit.                       | Missing or zero limit gives `UNKNOWN`, not an error.              |
| Bad config (`95,80`, `abc`) silently changes the status. | Bad config uses the defaults and the panel shows "invalid".       |
| Status shows Healthy at a displayed 80.00%.              | Classify the rounded percent that the panel shows.                |
| A query error hides the whole panel.                     | The flex metric becomes `UNKNOWN`. The daily metric still shows.  |
| Unknown data shows as Healthy.                           | Overall status: `UNKNOWN` ranks above `HEALTHY`.                  |
| Write a log row on each read.                            | No DML. Test checks DML count 0 and no new log rows.              |
| Lightning cache shows old values.                        | Endpoint is not cacheable.                                        |
| User with no view access reads org limits.               | Same view gate as the other panels.                               |

## Six Thinking Hats

- **White (facts):** Default daily limit is 250,000 or 200 × licenses. The
  flex queue holds 100. The read costs 1 SOQL and max 3 query rows.
- **Red (feel):** Operators want one word and one color. "Chain handoff at
  risk" must be clear and loud.
- **Black (risk):** The daily count is a rolling 24 hour value. A burst can
  go from Degraded to Critical in minutes. The panel is a snapshot. It is
  not an alert. A text field can hold bad data.
- **Yellow (value):** Operators see saturation before instances become orphans. No
  new object. No hot-path change.
- **Green (ideas):** Later: feed the same evaluator to #127 alerts and to a
  start throttle (#91/#28).
- **Blue (process):** Spec, RED, GREEN, REFACTOR. Then agent review. Then
  map each acceptance criterion to evidence.

## Spec

Percent = round(used / limit × 100, 2), `HALF_UP`. Classify this percent.

| Condition                        | Status     |
| -------------------------------- | ---------- |
| Limit missing or ≤ 0, or no data | `UNKNOWN`  |
| percent < warn                   | `HEALTHY`  |
| warn ≤ percent < crit            | `DEGRADED` |
| percent ≥ crit                   | `CRITICAL` |

- Thresholds: text `warn,crit`. Valid when 0 < warn < crit ≤ 100. Blank
  gives the defaults 80 and 95 (source `DEFAULT`). Bad text gives the
  defaults (source `INVALID`). Good text gives source `CONFIG`.
- Overall status = worst metric. Rank: `CRITICAL` > `DEGRADED` >
  `UNKNOWN` > `HEALTHY`.
- `chainAtRisk` = true only when one or more metrics are `CRITICAL`.
- Invariant: the read does 0 DML and max 1 SOQL.
- Invariant: `WorkflowOrchestrator` and the enqueue classes do not call the
  read.
- Pending jobs metric: (Holding + Queued + Processing) / (daily limit −
  daily used). Unknown when a value is missing or no executions are left.

## Design

- `AsyncCapacityEvaluator` (pure): `parseThresholds(raw)`,
  `classify(percent, thresholds)`, `percentOf(used, limit)`,
  `metric(...)`, `evaluate(...)`.
- `WorkflowAsyncCapacityService.asyncCapacity()`: view gate, reads
  `OrgLimits`, one `AsyncApexJob` aggregate, the config field. Returns a map.
- `WorkflowAsyncCapacityController.getAsyncCapacity()`: not cacheable.
  Granted in `Revenant_Operator` and `Revenant_Admin`.
- `Revenant_Config__mdt.Async_Capacity_Thresholds__c`: Text(20), optional.
- LWC `asyncCapacityPanel`: loads on connect. Shows overall badge, "Chain
  handoff at risk" alert, one row per metric, job counts, thresholds.
- `workflowDashboard`: puts the panel in System Doctor.

## Test Plan

- `AsyncCapacityEvaluatorTest`: parse (blank, valid, spaces, reversed,
  equal, out of range, text, one value); classify at each boundary; percent
  rounding; zero and missing limit; over 100%; worst-status rank;
  `chainAtRisk`.
- `WorkflowAsyncCapacityServiceTest`: envelope keys; config override;
  1 SOQL and max 3 query rows with 5 jobs; 0 DML; enqueued job shows in
  counts; query error gives `UNKNOWN`; enqueue classes do not name the
  service.
- `WorkflowAsyncCapacityControllerTest`: denial matches other panels;
  authorized read; permission sets grant the class.
- Jest `asyncCapacityPanel`: badge per status, risk alert only on Critical,
  metric rows, invalid config note, error state, unknown state.
- Jest `workflowDashboard`: System Doctor holds the panel.

## Review Round 1

Four review agents (Apex, LWC, security and acceptance criteria, docs):

- Acceptance criterion 2: `Queued` and `Processing` had no percent. Added
  the pending jobs metric (B13).
- Row cost: the test now enqueues 5 jobs before it measures query rows.
- Hot path: the test examines all classes that call `System.enqueueJob()`.
- `worst()` ignores a status that is not ranked.
- LWC: null guards, "Percent used" header, alert and busy roles, one marker
  (`—`) for missing values, own-key status lookup.
- Docs: the batch limit of 5, no Setup page for the daily count, the elastic
  limit, the cause of Unknown.
