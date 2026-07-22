/**
 * @description Unit tests for WorkflowLatencyService. Seeds terminal Workflow_Instance__c
 * records with controlled CreatedDate (via Test.setCreatedDate) and Terminal_At__c spreads
 * and append-only Workflow_Step_Execution__c rows with controlled CreatedDate deltas, then
 * asserts the end-to-end p50/p95/p99/max percentiles, the median-wall-clock step ranking
 * (including a definition whose middle step is deliberately the slowest), and the
 * sampled/truncated flag tripping when the scan cap is exceeded.
 */
@IsTest
public class WorkflowLatencyServiceTest {
  // Fixed base timestamps so durations are exact and independent of test execution time.
  private static final Datetime INSTANCE_BASE = Datetime.newInstance(
    2026,
    1,
    1,
    0,
    0,
    0
  );
  private static final Datetime STEP_BASE = Datetime.newInstance(
    2026,
    2,
    1,
    0,
    0,
    0
  );

  // Seeds terminal instances for one definition with CreatedDate = INSTANCE_BASE and
  // Terminal_At__c = INSTANCE_BASE + durationSeconds[i]. Insert stamps a terminal timestamp;
  // the follow-up update sets the intended value (the trigger does not restamp an
  // already-terminal record). Returns the inserted instances.
  private static List<Workflow_Instance__c> seedTerminalInstances(
    String workflowName,
    List<Integer> durationSeconds
  ) {
    List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < durationSeconds.size(); i++) {
      insts.add(
        new Workflow_Instance__c(
          Workflow_Name__c = workflowName,
          Status__c = 'Completed'
        )
      );
    }
    insert insts;
    for (Integer i = 0; i < insts.size(); i++) {
      Test.setCreatedDate(insts[i].Id, INSTANCE_BASE);
      insts[i].Terminal_At__c = INSTANCE_BASE.addSeconds(durationSeconds[i]);
    }
    update insts;
    return insts;
  }

  // Seeds an ordered set of step executions for one instance at the given CreatedDate offsets
  // (seconds after STEP_BASE), aligned positionally with stepNames.
  private static void seedSteps(
    Id instanceId,
    List<String> stepNames,
    List<Integer> offsetSeconds
  ) {
    List<Workflow_Step_Execution__c> steps = new List<Workflow_Step_Execution__c>();
    for (Integer i = 0; i < stepNames.size(); i++) {
      steps.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = instanceId,
          Step_Name__c = stepNames[i],
          Status__c = 'Completed'
        )
      );
    }
    insert steps;
    for (Integer i = 0; i < steps.size(); i++) {
      Test.setCreatedDate(steps[i].Id, STEP_BASE.addSeconds(offsetSeconds[i]));
    }
  }

  @IsTest
  static void computesEndToEndPercentilesByNearestRank() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 100 terminal instances with durations 1s..100s.
      List<Integer> durations = new List<Integer>();
      for (Integer i = 1; i <= 100; i++) {
        durations.add(i);
      }
      seedTerminalInstances('LatencyTest.DurationFlow', durations);

      Test.startTest();
      Map<String, Object> result = WorkflowLatencyService.definitionLatency(
        'LatencyTest.DurationFlow',
        'all'
      );
      Test.stopTest();

      System.assertEquals(
        100,
        (Integer) result.get('sampleSize'),
        'All 100 durations should be in the sample'
      );
      // Nearest-rank over 1000ms..100000ms: p50=rank50=50000, p95=rank95=95000,
      // p99=rank99=99000, max=100000.
      System.assertEquals(50000L, (Long) result.get('p50Ms'), 'p50');
      System.assertEquals(95000L, (Long) result.get('p95Ms'), 'p95');
      System.assertEquals(99000L, (Long) result.get('p99Ms'), 'p99');
      System.assertEquals(100000L, (Long) result.get('maxMs'), 'max');
      System.assertEquals(
        false,
        (Boolean) result.get('isCapped'),
        'Sample under the cap should not be flagged truncated'
      );
    }
  }

  @IsTest
  static void ranksStepsByMedianWallClockWithSlowestMiddleStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Four terminal instances, each with StepA -> StepB (middle) -> StepC. StepA's
      // consecutive delta is a constant 1s; StepB's delta grows per instance (10/12/14/16s)
      // so its four-sample median averages the two distinct middles (12s, 14s) = 13s. StepC
      // is the final step and contributes no delta.
      List<Workflow_Instance__c> insts = seedTerminalInstances(
        'LatencyTest.StepFlow',
        new List<Integer>{ 30, 30, 30, 30 }
      );
      List<String> names = new List<String>{ 'StepA', 'StepB', 'StepC' };
      for (Integer k = 0; k < insts.size(); k++) {
        Integer stepBSpan = 10 + (2 * k); // 10, 12, 14, 16 seconds
        // StepA @ base, StepB @ base+1s, StepC @ base+1s+stepBSpan.
        seedSteps(insts[k].Id, names, new List<Integer>{ 0, 1, 1 + stepBSpan });
      }

      Test.startTest();
      Map<String, Object> result = WorkflowLatencyService.definitionLatency(
        'LatencyTest.StepFlow',
        'all'
      );
      Test.stopTest();

      List<Map<String, Object>> steps = (List<Map<String, Object>>) result.get(
        'steps'
      );
      // Only StepA and StepB have consecutive deltas; StepC (final) is excluded.
      System.assertEquals(2, steps.size(), 'Two ranked steps expected');

      Map<String, Object> slowest = steps[0];
      System.assertEquals(
        'StepB',
        (String) slowest.get('stepName'),
        'Middle step StepB should rank slowest'
      );
      System.assertEquals(
        13000L,
        (Long) slowest.get('medianMs'),
        'StepB even-count median averages the two middles (12s,14s)'
      );
      System.assertEquals(
        4,
        (Integer) slowest.get('sampleCount'),
        'StepB has four deltas'
      );

      Map<String, Object> fastest = steps[1];
      System.assertEquals('StepA', (String) fastest.get('stepName'), 'StepA');
      System.assertEquals(
        1000L,
        (Long) fastest.get('medianMs'),
        'StepA median is a constant 1s'
      );
    }
  }

  @IsTest
  static void truncationFlagTripsWhenInstanceCapExceeded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Cap the sample at 3 and seed 4 terminal instances so the scan hits the cap.
      WorkflowLatencyService.instanceSampleCapOverride = 3;
      seedTerminalInstances(
        'LatencyTest.CapFlow',
        new List<Integer>{ 1, 2, 3, 4 }
      );

      Test.startTest();
      Map<String, Object> result = WorkflowLatencyService.definitionLatency(
        'LatencyTest.CapFlow',
        'all'
      );
      Test.stopTest();

      System.assertEquals(
        3,
        (Integer) result.get('sampleSize'),
        'Sample is bounded to the cap'
      );
      System.assertEquals(
        3,
        (Integer) result.get('capLimit'),
        'capLimit reflects the effective cap'
      );
      System.assertEquals(
        true,
        (Boolean) result.get('isCapped'),
        'Hitting the instance cap should flag the result truncated'
      );
    }
  }

  @IsTest
  static void truncationFlagTripsWhenStepCapExceeded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // One terminal instance with three step rows, step scan capped at 2.
      WorkflowLatencyService.stepScanCapOverride = 2;
      List<Workflow_Instance__c> insts = seedTerminalInstances(
        'LatencyTest.StepCapFlow',
        new List<Integer>{ 30 }
      );
      seedSteps(
        insts[0].Id,
        new List<String>{ 'StepA', 'StepB', 'StepC' },
        new List<Integer>{ 0, 1, 2 }
      );

      Test.startTest();
      Map<String, Object> result = WorkflowLatencyService.definitionLatency(
        'LatencyTest.StepCapFlow',
        'all'
      );
      Test.stopTest();

      System.assertEquals(
        true,
        (Boolean) result.get('isCapped'),
        'Hitting the step scan cap should flag the result truncated'
      );
    }
  }

  @IsTest
  static void effectiveStepCapIsHeapSafeAndStaysWithinGovernor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // The step-scan cap is sized for the 6MB synchronous Apex heap governor, not the row
      // governor: it must be well below the 50,000 row limit so the per-instance buckets and
      // per-step delta lists built over the scanned rows cannot blow heap before isCapped is
      // returned. Assert the constant itself is heap-safe.
      System.assert(
        WorkflowLatencyService.STEP_SCAN_CAP <= 15000,
        'Step-scan cap must be heap-safe (an order of magnitude below the 50k row governor)'
      );

      // With the heap-safe analytical cap the effective LIMIT is the analytical cap itself, not
      // the row-governor reservation: even with zero instance rows the reservation (49500) far
      // exceeds STEP_SCAN_CAP, so the smaller heap-safe cap binds.
      System.assertEquals(
        WorkflowLatencyService.STEP_SCAN_CAP,
        WorkflowLatencyService.effectiveStepScanCap(0),
        'Heap-safe analytical cap binds below the row-governor reservation'
      );

      // The row-governor reservation is still honored as defense-in-depth: at the production
      // instance-sample cap (2000 rows) instance_rows + step_rows stays within the 50k governor.
      Integer instanceRows = 2000;
      Integer effectiveCap = WorkflowLatencyService.effectiveStepScanCap(
        instanceRows
      );
      System.assertEquals(
        WorkflowLatencyService.STEP_SCAN_CAP,
        effectiveCap,
        'At 2000 instance rows the heap-safe cap still binds below the reservation'
      );
      System.assert(
        instanceRows + effectiveCap <= 50000,
        'instance rows + effective step cap must stay within the 50k sync row governor'
      );
    }
  }

  @IsTest
  static void windowFilterExcludesInstancesTerminalBeforeTheWindow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Recent terminal instance (inside a 24h window) and an old one (outside it).
      Workflow_Instance__c recent = new Workflow_Instance__c(
        Workflow_Name__c = 'LatencyTest.WindowFlow',
        Status__c = 'Completed'
      );
      Workflow_Instance__c old = new Workflow_Instance__c(
        Workflow_Name__c = 'LatencyTest.WindowFlow',
        Status__c = 'Completed'
      );
      insert new List<Workflow_Instance__c>{ recent, old };
      recent.Terminal_At__c = Datetime.now().addMinutes(-30);
      old.Terminal_At__c = Datetime.now().addDays(-10);
      update new List<Workflow_Instance__c>{ recent, old };

      Test.startTest();
      Map<String, Object> result = WorkflowLatencyService.definitionLatency(
        'LatencyTest.WindowFlow',
        '24h'
      );
      Test.stopTest();

      System.assertEquals(
        1,
        (Integer) result.get('sampleSize'),
        'Only the instance that terminated inside the 24h window is sampled'
      );
      System.assertEquals(
        '24h',
        (String) result.get('windowKey'),
        'Resolved window echoed back'
      );
    }
  }

  @IsTest
  static void blankWorkflowNameReturnsEmptyResult() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Map<String, Object> result = WorkflowLatencyService.definitionLatency(
        '',
        '24h'
      );
      Test.stopTest();

      System.assertEquals(0, (Integer) result.get('sampleSize'), 'No sample');
      System.assertEquals(null, result.get('p50Ms'), 'No p50 without data');
      System.assertEquals(null, result.get('maxMs'), 'No max without data');
      System.assertEquals(
        false,
        (Boolean) result.get('isCapped'),
        'Empty result is not truncated'
      );
      System.assertEquals(
        0,
        ((List<Map<String, Object>>) result.get('steps')).size(),
        'No steps'
      );
    }
  }

  @IsTest
  static void controllerEndpointDelegatesToService() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seedTerminalInstances(
        'LatencyTest.ControllerFlow',
        new List<Integer>{ 5, 10, 15 }
      );

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getDefinitionLatency(
        'LatencyTest.ControllerFlow',
        'all'
      );
      Test.stopTest();

      System.assertEquals(
        3,
        (Integer) result.get('sampleSize'),
        'Controller endpoint returns the service result'
      );
      // Durations 5s,10s,15s sorted -> nearest-rank p50 = rank2 = 10000ms.
      System.assertEquals(
        10000L,
        (Long) result.get('p50Ms'),
        'p50 via controller'
      );
    }
  }
}
