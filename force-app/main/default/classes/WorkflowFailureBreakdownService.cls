/**
 * @description Builds the per-step failure breakdown for a workflow over a selectable time
 * window: queries the failed step executions (capped at a governor-safe scan bound) and
 * delegates the grouping/signature rendering to WorkflowFailureSignatureService. Extracted
 * from WorkflowDashboardController; all SOQL runs WITH SYSTEM_MODE.
 */
public inherited sharing class WorkflowFailureBreakdownService {
  // Selectable windows, mapped to a span in hours. Blank/unrecognized keys mean "all
  // time" (resolveWindowStart returns null).
  private static final Map<String, Integer> TREND_WINDOW_HOURS = new Map<String, Integer>{
    '1h' => 1,
    '24h' => 24,
    '7d' => 168
  };

  private static final Integer FAILURE_BREAKDOWN_CAP = 2000;

  /**
   * @description Returns a per-step failure breakdown for a workflow over the given time
   * window: failure counts grouped by step, capped at a governor-safe scan bound with an
   * isCapped flag when the cap is reached.
   * @param workflowName The workflow definition name to analyze.
   * @param timeWindow The window key selecting how far back to scan.
   * @return A map with the window, cap metadata, total failures, and per-step groups.
   */
  public static Map<String, Object> breakdown(
    String workflowName,
    String timeWindow
  ) {
    WorkflowDashboardSupport.checkAuthorization();

    if (String.isBlank(workflowName)) {
      return new Map<String, Object>{
        'workflowName' => '',
        'timeWindow' => timeWindow,
        'isCapped' => false,
        'capLimit' => FAILURE_BREAKDOWN_CAP,
        'totalFailures' => 0,
        'steps' => new List<Map<String, Object>>()
      };
    }

    Datetime since = resolveWindowStart(timeWindow);
    List<Workflow_Step_Execution__c> steps = queryFailedSteps(
      workflowName,
      since
    );

    List<Map<String, Object>> stepList = WorkflowFailureSignatureService.groupToMaps(
      steps
    );

    return new Map<String, Object>{
      'workflowName' => workflowName,
      'timeWindow' => String.isNotBlank(timeWindow) ? timeWindow : 'all',
      'isCapped' => (steps.size() >= FAILURE_BREAKDOWN_CAP),
      'capLimit' => FAILURE_BREAKDOWN_CAP,
      'totalFailures' => steps.size(),
      'steps' => stepList
    };
  }

  // Resolves the start of a recognized trend window (blank/unknown → null = "all time").
  private static Datetime resolveWindowStart(String timeWindow) {
    if (
      String.isBlank(timeWindow) || !TREND_WINDOW_HOURS.containsKey(timeWindow)
    ) {
      return null;
    }
    return Datetime.now().addHours(-TREND_WINDOW_HOURS.get(timeWindow));
  }

  private static List<Workflow_Step_Execution__c> queryFailedSteps(
    String workflowName,
    Datetime since
  ) {
    if (since != null) {
      return [
        SELECT
          Step_Name__c,
          Error_Details__c,
          Workflow_Instance__c,
          Workflow_Instance__r.Name,
          CreatedDate
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__r.Workflow_Name__c = :workflowName
          AND Status__c = 'Failed'
          AND CreatedDate >= :since
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC
        LIMIT :FAILURE_BREAKDOWN_CAP
      ];
    }
    return [
      SELECT
        Step_Name__c,
        Error_Details__c,
        Workflow_Instance__c,
        Workflow_Instance__r.Name,
        CreatedDate
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__r.Workflow_Name__c = :workflowName
        AND Status__c = 'Failed'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
      LIMIT :FAILURE_BREAKDOWN_CAP
    ];
  }
}
