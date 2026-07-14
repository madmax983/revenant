/**
 * @description Discovers the concrete WorkflowDefinition class names for the dashboard via
 * the platform's compiled-type index (ApexTypeImplementor). Extracted from
 * WorkflowDashboardController so the discovery logic can be reused by sibling controllers
 * gated on a different permission. All SOQL runs WITH SYSTEM_MODE.
 */
public inherited sharing class WorkflowDefinitionDiscoveryService {
  /**
   * Raised internally when the precise source-scan strategy approaches a governor limit.
   * It is thrown *before* the (uncatchable) platform LimitException would fire, so the
   * caller can degrade gracefully to the lightweight ApexTypeImplementor index.
   */
  @TestVisible
  private class DefinitionScanLimitException extends Exception {
  }

  /**
   * @description Returns the discoverable WorkflowDefinition class names for the dashboard
   * AFTER enforcing the Workflow_Admin authorization gate.
   * @return The sorted list of concrete WorkflowDefinition class names.
   */
  public static List<String> discoverChecked() {
    WorkflowDashboardSupport.checkAuthorization();
    return discover();
  }

  /**
   * @description WorkflowDefinition discovery WITHOUT an authorization check. Callers MUST
   * perform their own authorization first. Exists so sibling controllers (gated on a
   * different permission) can reuse the exact discovery logic without tripping the
   * dashboard's Workflow_Admin gate.
   * @return The sorted list of concrete WorkflowDefinition class names.
   */
  public static List<String> discover() {
    return getDefinitionsFromTypeIndex();
  }

  /**
   * @description Degraded-mode discovery via the platform's compiled-type index.
   * Heap/CPU cheap. Includes inner classes (qualified "Outer.Inner") and transitive
   * interface inheritance, but lists only concrete (IsConcrete = true) implementing
   * classes.
   * @return The sorted list of concrete WorkflowDefinition class names, test classes and
   * system-only workflows excluded.
   */
  private static List<String> getDefinitionsFromTypeIndex() {
    Set<String> definitions = new Set<String>();
    for (ApexTypeImplementor impl : [
      SELECT ClassName
      FROM ApexTypeImplementor
      WHERE
        InterfaceName IN ('WorkflowDefinition', 'VersionedWorkflow')
        AND ClassNamespacePrefix = NULL
        AND IsConcrete = TRUE
      WITH SYSTEM_MODE
    ]) {
      String className = impl.ClassName;
      if (String.isBlank(className)) {
        continue;
      }
      // By convention all test classes end with 'Test'. Extract the outer class name
      // (before '.' for inner classes) to catch inners of test classes too. Also exclude
      // system-only workflows not meant to be launched from the UI.
      String outerClass = className.contains('.')
        ? className.substringBefore('.')
        : className;
      if (
        outerClass.toLowerCase().endsWith('test') ||
        className.equalsIgnoreCase('BulkRedriveWorkflow') ||
        className.equalsIgnoreCase('BulkCancelWorkflow')
      ) {
        continue;
      }
      definitions.add(className);
    }
    List<String> sorted = new List<String>(definitions);
    sorted.sort();
    return sorted;
  }
}
