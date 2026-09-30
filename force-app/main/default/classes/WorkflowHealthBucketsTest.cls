/**
 * @description Tests for WorkflowHealthBuckets and for the legacy dashboard stat buckets.
 * Both surfaces must use the active/failed/suspended mapping of the Workflow Catalog (#54).
 */
@IsTest
private class WorkflowHealthBucketsTest {
  private static Map<String, Integer> zeroStats() {
    return new Map<String, Integer>{
      'total' => 0,
      'active' => 0,
      'suspended' => 0,
      'completed' => 0,
      'failed' => 0
    };
  }

  @IsTest
  static void bucketOfMapsEveryStatus() {
    Map<String, String> expected = new Map<String, String>{
      'Pending' => 'active',
      'Running' => 'active',
      'Compensating' => 'active',
      'Cancelling' => 'active',
      'Paused' => 'active',
      'DefinitionChanged' => 'active',
      'Held' => 'active',
      'Failed' => 'failed',
      'CompensationFailed' => 'failed',
      'Suspended' => 'suspended',
      'Completed' => null,
      'ContinuedAsNew' => null,
      'Compensated' => null,
      'Cancelled' => null
    };
    for (String status : expected.keySet()) {
      System.assertEquals(
        expected.get(status),
        WorkflowHealthBuckets.bucketOf(status),
        'Bucket for ' + status
      );
    }
  }

  @IsTest
  static void bucketOfHandlesNullAndUnknown() {
    System.assertEquals(null, WorkflowHealthBuckets.bucketOf(null));
    System.assertEquals(null, WorkflowHealthBuckets.bucketOf('Bogus'));
  }

  @IsTest
  static void healthStatusesHoldExactlyTheBucketedStatuses() {
    System.assertEquals(10, WorkflowHealthBuckets.HEALTH_STATUSES.size());
    System.assert(WorkflowHealthBuckets.HEALTH_STATUSES.contains('Suspended'));
    System.assert(!WorkflowHealthBuckets.HEALTH_STATUSES.contains('Cancelled'));
  }

  @IsTest
  static void legacyTilesSplitSuspendedFromActive() {
    Map<String, Integer> r = zeroStats();
    WorkflowStallDetectionService.bucketWorkflowStat(r, 'Running', 2);
    WorkflowStallDetectionService.bucketWorkflowStat(r, 'Suspended', 3);
    System.assertEquals(2, r.get('active'));
    System.assertEquals(3, r.get('suspended'));
    System.assertEquals(5, r.get('total'));
  }

  @IsTest
  static void legacyTilesDoNotCountCompensatedOrCancelledAsFailed() {
    Map<String, Integer> r = zeroStats();
    WorkflowStallDetectionService.bucketWorkflowStat(r, 'Compensated', 4);
    WorkflowStallDetectionService.bucketWorkflowStat(r, 'Cancelled', 5);
    WorkflowStallDetectionService.bucketWorkflowStat(
      r,
      'CompensationFailed',
      1
    );
    System.assertEquals(1, r.get('failed'));
    System.assertEquals(0, r.get('active'));
    System.assertEquals(0, r.get('completed'));
    System.assertEquals(10, r.get('total'));
  }

  @IsTest
  static void legacyTilesKeepCompleted() {
    Map<String, Integer> r = zeroStats();
    WorkflowStallDetectionService.bucketWorkflowStat(r, 'Completed', 2);
    WorkflowStallDetectionService.bucketWorkflowStat(r, 'ContinuedAsNew', 1);
    System.assertEquals(3, r.get('completed'));
  }

  @IsTest
  static void legacyTilesAgreeWithClassifierForEveryStatus() {
    for (
      String status : new List<String>{
        'Pending',
        'Running',
        'Compensating',
        'Cancelling',
        'Paused',
        'DefinitionChanged',
        'Held',
        'Failed',
        'CompensationFailed',
        'Suspended',
        'Completed',
        'ContinuedAsNew',
        'Compensated',
        'Cancelled'
      }
    ) {
      Map<String, Integer> r = zeroStats();
      WorkflowStallDetectionService.bucketWorkflowStat(r, status, 1);
      String bucket = WorkflowHealthBuckets.bucketOf(status);
      for (String key : new List<String>{ 'active', 'failed', 'suspended' }) {
        System.assertEquals(
          key == bucket ? 1 : 0,
          r.get(key),
          status + ' in ' + key
        );
      }
    }
  }
}
