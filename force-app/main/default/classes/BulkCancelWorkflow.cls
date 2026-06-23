/**
 * BulkCancelWorkflow
 *
 * Operator-initiated bulk cancel of workflow instances.
 */
public inherited sharing class BulkCancelWorkflow implements WorkflowDefinition {
  public static final String CANCELER_WORKFLOW_NAME = 'BulkCancelWorkflow';

  private static final Set<String> ELIGIBLE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Paused',
    'CompensationFailed'
  };

  @TestVisible
  public static Integer CHUNK_SIZE = 30;

  // ---- WorkflowDefinition ----

  public List<String> getSteps() {
    return new List<String>{ 'BulkCancelWorkflow.BulkCancelStep' };
  }

  public String getInitialStep() {
    return 'BulkCancelWorkflow.BulkCancelStep';
  }

  public String getNextStep(String currentStepName, StepResult result) {
    return null; // single-step workflow
  }

  // ---- Eligible-selection helpers ----

  private static List<String> effectiveStatuses(String status) {
    List<String> result = new List<String>();
    if (String.isNotBlank(status)) {
      if (ELIGIBLE_STATUSES.contains(status)) {
        result.add(status);
      }
    } else {
      result.addAll(ELIGIBLE_STATUSES);
    }
    return result;
  }

  public static Integer countEligible(
    String workflowName,
    String status,
    String searchTerm
  ) {
    List<String> effStatuses = effectiveStatuses(status);
    if (effStatuses.isEmpty()) {
      return 0;
    }
    String excludeName = CANCELER_WORKFLOW_NAME;
    String likeTerm = String.isNotBlank(searchTerm)
      ? '%' + String.escapeSingleQuotes(searchTerm) + '%'
      : null;

    if (String.isBlank(workflowName)) {
      if (likeTerm == null) {
        return [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Status__c IN :effStatuses AND Workflow_Name__c != :excludeName
          WITH SYSTEM_MODE
        ];
      } else {
        return [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE
            Status__c IN :effStatuses
            AND Workflow_Name__c != :excludeName
            AND (Name LIKE :likeTerm
            OR Correlation_Key__c LIKE :likeTerm
            OR Workflow_Name__c LIKE :likeTerm
            OR Error_Message__c LIKE :likeTerm)
          WITH SYSTEM_MODE
        ];
      }
    } else {
      if (likeTerm == null) {
        return [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE
            Status__c IN :effStatuses
            AND Workflow_Name__c != :excludeName
            AND Workflow_Name__c = :workflowName
          WITH SYSTEM_MODE
        ];
      } else {
        return [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE
            Status__c IN :effStatuses
            AND Workflow_Name__c != :excludeName
            AND Workflow_Name__c = :workflowName
            AND (Name LIKE :likeTerm
            OR Correlation_Key__c LIKE :likeTerm
            OR Workflow_Name__c LIKE :likeTerm
            OR Error_Message__c LIKE :likeTerm)
          WITH SYSTEM_MODE
        ];
      }
    }
  }

  public static List<Id> fetchEligibleChunk(
    String workflowName,
    String status,
    String searchTerm,
    Id afterId,
    Integer chunkSize
  ) {
    List<String> effStatuses = effectiveStatuses(status);
    if (effStatuses.isEmpty()) {
      return new List<Id>();
    }
    String excludeName = CANCELER_WORKFLOW_NAME;
    String likeTerm = String.isNotBlank(searchTerm)
      ? '%' + String.escapeSingleQuotes(searchTerm) + '%'
      : null;
    Integer lim = chunkSize;

    List<Workflow_Instance__c> rows;
    if (afterId == null) {
      if (String.isBlank(workflowName)) {
        if (likeTerm == null) {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE Status__c IN :effStatuses AND Workflow_Name__c != :excludeName
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        } else {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND (Name LIKE :likeTerm
              OR Correlation_Key__c LIKE :likeTerm
              OR Workflow_Name__c LIKE :likeTerm
              OR Error_Message__c LIKE :likeTerm)
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        }
      } else {
        if (likeTerm == null) {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Workflow_Name__c = :workflowName
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        } else {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Workflow_Name__c = :workflowName
              AND (Name LIKE :likeTerm
              OR Correlation_Key__c LIKE :likeTerm
              OR Workflow_Name__c LIKE :likeTerm
              OR Error_Message__c LIKE :likeTerm)
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        }
      }
    } else {
      if (String.isBlank(workflowName)) {
        if (likeTerm == null) {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Id > :afterId
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        } else {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Id > :afterId
              AND (Name LIKE :likeTerm
              OR Correlation_Key__c LIKE :likeTerm
              OR Workflow_Name__c LIKE :likeTerm
              OR Error_Message__c LIKE :likeTerm)
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        }
      } else {
        if (likeTerm == null) {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Id > :afterId
              AND Workflow_Name__c = :workflowName
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        } else {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Id > :afterId
              AND Workflow_Name__c = :workflowName
              AND (Name LIKE :likeTerm
              OR Correlation_Key__c LIKE :likeTerm
              OR Workflow_Name__c LIKE :likeTerm
              OR Error_Message__c LIKE :likeTerm)
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        }
      }
    }

    List<Id> ids = new List<Id>();
    for (Workflow_Instance__c inst : rows) {
      ids.add(inst.Id);
    }
    return ids;
  }

  // ---- The cancel step ----

  public class BulkCancelStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> state;
      if (String.isNotBlank(ctx.stepStateJson)) {
        state = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.stepStateJson
        );
      } else {
        state = new Map<String, Object>();
        if (String.isNotBlank(ctx.workflowInputJson)) {
          Map<String, Object> filter = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.workflowInputJson
          );
          state.put('workflowName', filter.get('workflowName'));
          state.put('status', filter.get('status'));
          state.put('searchTerm', filter.get('searchTerm'));
          state.put('runCompensations', filter.get('runCompensations'));
        }
      }

      String workflowName = (String) state.get('workflowName');
      String status = (String) state.get('status');
      String searchTerm = (String) state.get('searchTerm');
      Boolean runCompensations = state.get('runCompensations') == true;
      Id afterId = state.get('lastId') != null
        ? (Id) (String) state.get('lastId')
        : null;
      Integer cancelled = intOf(state.get('cancelled'));
      Integer skipped = intOf(state.get('skipped'));
      Integer errored = intOf(state.get('errored'));

      Integer chunkSize = CHUNK_SIZE;
      List<Id> chunk = fetchEligibleChunk(
        workflowName,
        status,
        searchTerm,
        afterId,
        chunkSize
      );

      Integer processed = 0;
      for (Id instId : chunk) {
        if (ctx.shouldYield()) {
          break;
        }
        try {
          List<Workflow_Instance__c> toCancel = [
            SELECT Status__c
            FROM Workflow_Instance__c
            WHERE Id = :instId
            WITH SYSTEM_MODE
            FOR UPDATE
          ];
          if (
            !toCancel.isEmpty() &&
            ELIGIBLE_STATUSES.contains(toCancel[0].Status__c)
          ) {
            WorkflowEngine.cancel(instId, runCompensations);
            cancelled++;
          } else {
            skipped++;
          }
        } catch (Exception ex) {
          errored++;
        }
        afterId = instId;
        processed++;

        if (ctx.shouldYield()) {
          break;
        }
      }

      state.put('workflowName', workflowName);
      state.put('status', status);
      state.put('searchTerm', searchTerm);
      state.put('runCompensations', runCompensations);
      state.put('lastId', afterId == null ? null : String.valueOf(afterId));
      state.put('cancelled', cancelled);
      state.put('skipped', skipped);
      state.put('errored', errored);

      Boolean moreRemain =
        (processed < chunk.size()) || (chunk.size() == chunkSize);
      if (moreRemain) {
        return StepResult.yield(JSON.serialize(state));
      }

      Map<String, Object> summary = new Map<String, Object>{
        'cancelled' => cancelled,
        'skipped' => skipped,
        'errored' => errored,
        'totalProcessed' => cancelled +
        skipped +
        errored
      };
      return StepResult.complete(null, summary);
    }

    private Integer intOf(Object o) {
      return o == null ? 0 : Integer.valueOf(String.valueOf(o));
    }
  }
}
