/**
 * @description Backs the dashboard's read-only Workflow Catalog: a definition-level front
 * door that lists every concrete, startable WorkflowDefinition the engine already discovers
 * and, per definition, surfaces a human-readable label, a description, the current declared
 * version (for VersionedWorkflow implementations), and a live active/failed/suspended health
 * rollup computed from existing Workflow_Instance__c data.
 *
 * Discovery is delegated to WorkflowDefinitionDiscoveryService.discover() (called, never
 * modified) so the Catalog inherits its ApexTypeImplementor index scan, inner-class
 * ("Outer.Inner") support, and system-workflow/test-class exclusions. Label and description
 * come from the optional WorkflowCatalogDescribable interface: a definition MAY implement it
 * to supply friendly text; definitions that do not still appear, falling back to a humanized
 * class name and an "undocumented" marker. Resolving the label/version instantiates each
 * definition AT MOST ONCE via WorkflowTypeResolver (the same resolver the engine uses),
 * inside a per-definition try/catch so one uninstantiable definition never fails the Catalog.
 *
 * The health counts are produced by a SINGLE grouped aggregate over Workflow_Instance__c
 * (GROUP BY Workflow_Name__c, Status__c), bounded to the non-terminal/failed statuses the
 * Catalog reports, then pivoted per definition in memory. The view is strictly read-only: it
 * performs no DML, enqueues no jobs, and emits no signals or events. All SOQL runs
 * WITH SYSTEM_MODE, matching the sibling read services.
 */
public inherited sharing class WorkflowCatalogService {
  // Non-terminal in-flight statuses rolled up as "active".
  private static final Set<String> ACTIVE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Compensating',
    'Cancelling',
    'Paused'
  };

  // Broken/recoverable statuses rolled up as "failed".
  private static final Set<String> FAILED_STATUSES = new Set<String>{
    'Failed',
    'CompensationFailed'
  };

  // The single status parked as "suspended" (awaiting a signal / manual action).
  private static final String SUSPENDED_STATUS = 'Suspended';

  // Union of the statuses the health rollup cares about. Restricting the aggregate to these
  // both bounds the number of GROUP BY rows (<= ~200 definitions * 8 statuses) and skips the
  // clean-terminal (Completed/Cancelled/Compensated/ContinuedAsNew) rows the Catalog never
  // shows, so the scan stays governor-safe for large orgs.
  private static final Set<String> HEALTH_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Compensating',
    'Cancelling',
    'Paused',
    'Failed',
    'CompensationFailed',
    'Suspended'
  };

  /**
   * @description Builds the read-only Workflow Catalog AFTER enforcing the dashboard
   * authorization gate: one row per concrete, startable definition the engine discovers,
   * each carrying its class name (engine identifier), a human-readable label, a description
   * (or an "undocumented" marker), the current declared version for VersionedWorkflow
   * implementations, and an active/failed/suspended health rollup.
   * @return One catalog row map per discovered definition, sorted by class name.
   */
  public static List<Map<String, Object>> buildCatalog() {
    WorkflowDashboardSupport.checkAuthorization();
    return buildCatalogFor(WorkflowDefinitionDiscoveryService.discover());
  }

  /**
   * @description Assembles catalog rows for an explicit list of definition class names.
   * Separated from buildCatalog() (which supplies the discovered names) so tests can drive
   * the pivot, label resolution, and version surfacing deterministically without depending
   * on which definitions happen to be deployed. Runs the single grouped health aggregate
   * once, then resolves each definition's label/description/version.
   * @param definitionNames The concrete definition class names to build rows for.
   * @return One catalog row map per supplied definition, in the supplied order.
   */
  @TestVisible
  private static List<Map<String, Object>> buildCatalogFor(
    List<String> definitionNames
  ) {
    Map<String, Map<String, Integer>> countsByDefinition = queryHealthCounts();

    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    for (String definitionName : definitionNames) {
      if (String.isBlank(definitionName)) {
        continue;
      }
      rows.add(
        buildRow(definitionName, countsByDefinition.get(definitionName))
      );
    }
    return rows;
  }

  /**
   * @description Runs the single grouped aggregate that powers every definition's health
   * rollup and pivots it into per-definition active/failed/suspended counts. Bounded to the
   * non-terminal/failed statuses the Catalog reports so the aggregate stays governor-safe on
   * large orgs; definitions with no matching instances are simply absent from the map (the
   * caller defaults them to zero, so a definition with no runs still appears in the Catalog).
   * @return A map of Workflow_Name__c to its {active, failed, suspended} counts.
   */
  private static Map<String, Map<String, Integer>> queryHealthCounts() {
    Map<String, Map<String, Integer>> countsByDefinition = new Map<String, Map<String, Integer>>();

    for (AggregateResult ar : [
      SELECT Workflow_Name__c wf, Status__c st, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE Status__c IN :HEALTH_STATUSES
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c, Status__c
      LIMIT 50000
    ]) {
      String workflowName = (String) ar.get('wf');
      if (String.isBlank(workflowName)) {
        continue;
      }
      String status = (String) ar.get('st');
      Integer count = (Integer) ar.get('cnt');

      Map<String, Integer> buckets = countsByDefinition.get(workflowName);
      if (buckets == null) {
        buckets = newZeroBuckets();
        countsByDefinition.put(workflowName, buckets);
      }
      if (ACTIVE_STATUSES.contains(status)) {
        buckets.put('active', buckets.get('active') + count);
      } else if (FAILED_STATUSES.contains(status)) {
        buckets.put('failed', buckets.get('failed') + count);
      } else if (status == SUSPENDED_STATUS) {
        buckets.put('suspended', buckets.get('suspended') + count);
      }
    }
    return countsByDefinition;
  }

  // A fresh zeroed active/failed/suspended bucket map for one definition.
  private static Map<String, Integer> newZeroBuckets() {
    return new Map<String, Integer>{
      'active' => 0,
      'failed' => 0,
      'suspended' => 0
    };
  }

  // Builds one catalog row: the class name plus its resolved label/description/version and
  // the health counts (defaulted to zero when the definition has no instances).
  private static Map<String, Object> buildRow(
    String definitionName,
    Map<String, Integer> counts
  ) {
    Map<String, Integer> buckets = counts == null ? newZeroBuckets() : counts;

    DefinitionDescription described = describe(definitionName);
    Integer active = buckets.get('active');
    Integer failed = buckets.get('failed');
    Integer suspended = buckets.get('suspended');

    return new Map<String, Object>{
      'className' => definitionName,
      'label' => described.label,
      'description' => described.description,
      'documented' => described.documented,
      'versioned' => described.version != null,
      'version' => described.version,
      'active' => active,
      'failed' => failed,
      'suspended' => suspended,
      'total' => active +
      failed +
      suspended
    };
  }

  // Resolved label/description/version for one definition. Bundled so buildRow reads a single
  // value object instead of juggling three out-parameters.
  private class DefinitionDescription {
    String label;
    String description;
    Boolean documented = false;
    Integer version = null;
  }

  // Resolves a definition's label, description, and current version. Instantiates the
  // definition AT MOST ONCE (via WorkflowTypeResolver, the resolver the engine itself uses)
  // to read the optional WorkflowCatalogDescribable text and the VersionedWorkflow version.
  // Instantiation is guarded: if the type cannot be resolved or its constructor throws
  // (argument constructor, abstract, heavy init), the row degrades gracefully to a humanized
  // class-name label with no description ("undocumented") and no version. Issues no SOQL/DML.
  private static DefinitionDescription describe(String definitionName) {
    DefinitionDescription result = new DefinitionDescription();
    result.label = humanize(definitionName);

    try {
      Type definitionType = WorkflowTypeResolver.resolve(definitionName);
      if (definitionType == null) {
        return result;
      }
      Object instance = definitionType.newInstance();

      if (instance instanceof WorkflowCatalogDescribable) {
        WorkflowCatalogDescribable describable = (WorkflowCatalogDescribable) instance;
        String suppliedLabel = describable.catalogLabel();
        String suppliedDescription = describable.catalogDescription();
        if (String.isNotBlank(suppliedLabel)) {
          result.label = suppliedLabel;
          result.documented = true;
        }
        if (String.isNotBlank(suppliedDescription)) {
          result.description = suppliedDescription;
          result.documented = true;
        }
      }

      if (instance instanceof VersionedWorkflow) {
        result.version = ((VersionedWorkflow) instance).getLatestVersion();
      }
    } catch (Exception ignored) {
      // Uninstantiable definition (argument constructor / abstract / heavy init) or a
      // throwing self-describe method: keep the humanized-class-name fallback so the
      // definition still appears, undocumented and version-less, instead of failing the
      // whole Catalog.
    }
    return result;
  }

  // Derives a human-readable label from a definition's Apex class name when the definition
  // does not supply one via WorkflowCatalogDescribable. Splits camel-case and acronym
  // boundaries and treats the inner-class separator as a space, so "PurchaseApprovalWorkflow"
  // becomes "Purchase Approval Workflow" and "Order.HTTPRetryWorkflow" becomes
  // "Order HTTP Retry Workflow".
  @TestVisible
  private static String humanize(String className) {
    if (String.isBlank(className)) {
      return className;
    }
    String spaced = className.replace('.', ' ');
    // Insert a space between an acronym run and a following CapitalizedWord (HTTPRetry -> HTTP Retry).
    spaced = spaced.replaceAll('([A-Z]+)([A-Z][a-z])', '$1 $2');
    // Insert a space at each lower-to-upper boundary (PurchaseApproval -> Purchase Approval).
    spaced = spaced.replaceAll('([a-z0-9])([A-Z])', '$1 $2');
    // Collapse any runs of whitespace and trim.
    spaced = spaced.replaceAll('\\s+', ' ').trim();
    return spaced;
  }
}
