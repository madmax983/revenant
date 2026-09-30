/**
 * @description Read-only topology graph of a workflow definition, with an
 * optional path overlay of one instance (issue #141).
 *
 * Nodes are the getSteps() inventory. Edges are the transitions of the
 * best-effort probe that WorkflowValidator runs. A missing edge does not prove
 * that no route exists. The graph tells this: routingFullyKnown,
 * incompleteReasons, and routingUnknown on a node.
 *
 * Read-only: no DML, no event, no job. The graph makes an instance of a class
 * only after ApexTypeImplementor shows that it is a deployed workflow
 * definition. The overlay does one query for the instance and one bounded
 * query for its step rows. The caller does the authorization check.
 */
public inherited sharing class WorkflowTopology {
  /** The name is not a deployed definition, or getSteps() gave no step. */
  public static final String REASON_DEFINITION_UNRESOLVED = 'DEFINITION_UNRESOLVED';
  /** getNextStep threw for a probe of a step. */
  public static final String REASON_ROUTING_THREW = 'ROUTING_THREW';
  /** A declared step has no known route from the initial step. */
  public static final String REASON_UNREACHED_STEPS = 'UNREACHED_STEPS';
  /** A route or a run goes to a step that getSteps() does not declare. */
  public static final String REASON_UNDECLARED_STEPS = 'UNDECLARED_STEPS';
  /** getLatestVersion() threw, so no version was probed. */
  public static final String REASON_VERSIONS_UNRESOLVED = 'VERSIONS_UNRESOLVED';

  /** The instance is queued or runs. */
  public static final String STATE_RUNNING = 'RUNNING';
  /** The instance waits for a signal, an approval or a child. */
  public static final String STATE_AWAITING_SIGNAL = 'AWAITING_SIGNAL';
  /** The instance waits for a timer or a job. */
  public static final String STATE_SUSPENDED = 'SUSPENDED';
  /** The instance failed, or its rollback failed. */
  public static final String STATE_FAILED = 'FAILED';
  /** The instance does a rollback (compensation or cancel). */
  public static final String STATE_COMPENSATING = 'COMPENSATING';
  /** An operator or the engine parked the instance. */
  public static final String STATE_PARKED = 'PARKED';
  /** The instance is in a terminal status. */
  public static final String STATE_ENDED = 'ENDED';

  private static final String COMPENSATION_SUFFIX = '_Compensate';

  private static final Map<String, String> STATE_BY_STATUS = new Map<String, String>{
    'Pending' => STATE_RUNNING,
    'Running' => STATE_RUNNING,
    'Failed' => STATE_FAILED,
    'CompensationFailed' => STATE_FAILED,
    'Compensating' => STATE_COMPENSATING,
    'Cancelling' => STATE_COMPENSATING,
    'Paused' => STATE_PARKED,
    'Held' => STATE_PARKED,
    'DefinitionChanged' => STATE_PARKED
  };

  // Maximum step rows that the overlay reads. The newest rows are kept.
  @TestVisible
  private static Integer pathLimit = 200;

  /** @description The graph of one definition. The shape is pinned by a test. */
  public class Graph {
    @AuraEnabled
    public String workflowName;
    @AuraEnabled
    public String initialStep;
    @AuraEnabled
    public List<Node> nodes = new List<Node>();
    @AuraEnabled
    public List<Edge> edges = new List<Edge>();
    /** False when the graph is known to miss routes. Always best-effort. */
    @AuraEnabled
    public Boolean routingFullyKnown = true;
    @AuraEnabled
    public List<String> incompleteReasons = new List<String>();
    /** The validator defect messages. */
    @AuraEnabled
    public List<String> defects = new List<String>();
    /** The path of one instance, or null for a definition graph. */
    @AuraEnabled
    public Overlay overlay;
  }

  // Builds a Graph. Keeps the name index out of the serialized DTO.
  private class GraphBuilder {
    final Graph graph = new Graph();
    final Map<String, Node> nodeByName = new Map<String, Node>();

    Node addNode(String name, Boolean declared) {
      Node n = nodeByName.get(name);
      if (n == null) {
        n = new Node(name, declared);
        nodeByName.put(name, n);
        graph.nodes.add(n);
        if (!declared) {
          addReason(REASON_UNDECLARED_STEPS);
        }
      }
      return n;
    }

    void addReason(String reason) {
      if (!graph.incompleteReasons.contains(reason)) {
        graph.incompleteReasons.add(reason);
      }
      graph.routingFullyKnown = false;
    }

    void addEdge(String source, String target) {
      if (!hasEdge(graph.edges, source, target)) {
        graph.edges.add(new Edge(source, target));
      }
    }

    List<String> successorsOf(String stepName) {
      List<String> next = new List<String>();
      for (Edge e : graph.edges) {
        if (e.source == stepName) {
          next.add(e.target);
        }
      }
      return next;
    }
  }

  /** @description One step of the graph. */
  public class Node {
    /** The step class name. */
    @AuraEnabled
    public String name;
    /** The short name (the part after the last dot). */
    @AuraEnabled
    public String label;
    /** False when getSteps() does not declare the step. */
    @AuraEnabled
    public Boolean declared;
    @AuraEnabled
    public Boolean initial = false;
    /** getNextStep returned no successor for a probe: the run can end here. */
    @AuraEnabled
    public Boolean terminal = false;
    /** The step implements CompensatableStep. */
    @AuraEnabled
    public Boolean compensatable = false;
    /** The probe could not find the routing of this step. */
    @AuraEnabled
    public Boolean routingUnknown = false;
    /** A known route goes from the initial step to this step. */
    @AuraEnabled
    public Boolean reachable = false;

    private Node(String name, Boolean declared) {
      this.name = name;
      this.label = name.contains('.') ? name.substringAfterLast('.') : name;
      this.declared = declared;
      // No probe ran for an undeclared step.
      this.routingUnknown = !declared;
    }
  }

  /** @description One known transition. */
  public class Edge {
    @AuraEnabled
    public String source;
    @AuraEnabled
    public String target;

    private Edge(String source, String target) {
      this.source = source;
      this.target = target;
    }
  }

  /** @description The path and position of one instance. */
  public class Overlay {
    @AuraEnabled
    public Id instanceId;
    @AuraEnabled
    public String instanceStatus;
    @AuraEnabled
    public String currentStep;
    /** One of the STATE_ constants. */
    @AuraEnabled
    public String currentState;
    /** The step rows, oldest first. */
    @AuraEnabled
    public List<PathEntry> path = new List<PathEntry>();
    /** Known edges that the run used. */
    @AuraEnabled
    public List<Edge> traversedEdges = new List<Edge>();
    /** Known successors of the current step. */
    @AuraEnabled
    public List<String> nextSteps = new List<String>();
    /** True when the path shows only the newest rows. */
    @AuraEnabled
    public Boolean pathTruncated = false;
  }

  /** @description One step row of the path. */
  public class PathEntry {
    /** The step name. A compensation row gives its forward step. */
    @AuraEnabled
    public String stepName;
    @AuraEnabled
    public String status;
    /** True for a compensation row. */
    @AuraEnabled
    public Boolean compensation;

    private PathEntry(Workflow_Step_Execution__c row) {
      String name = row.Step_Name__c == null ? '' : row.Step_Name__c;
      this.compensation = name.endsWith(COMPENSATION_SUFFIX);
      this.stepName = compensation ? name.removeEnd(COMPENSATION_SUFFIX) : name;
      this.status = row.Status__c;
    }
  }

  /**
   * @description Builds the graph of a definition. It never throws for an
   * author defect. It gives an empty, incomplete graph for a name that is not
   * a deployed workflow definition.
   * @param workflowName The workflow definition name.
   * @return The graph.
   */
  public static Graph build(String workflowName) {
    return builderFor(workflowName).graph;
  }

  private static GraphBuilder builderFor(String workflowName) {
    GraphBuilder b = new GraphBuilder();
    b.graph.workflowName = workflowName;
    if (!WorkflowStartInstanceBuilder.isAuthorizedDefinition(workflowName)) {
      b.graph.defects.add(
        'Workflow "' + workflowName + '" is not a deployed WorkflowDefinition.'
      );
      b.addReason(REASON_DEFINITION_UNRESOLVED);
      return b;
    }

    WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
      workflowName
    );
    for (WorkflowValidator.Defect d : result.defects) {
      b.graph.defects.add(d.message);
    }
    if (result.transitions == null || result.declaredSteps.isEmpty()) {
      b.addReason(REASON_DEFINITION_UNRESOLVED);
      return b;
    }
    b.graph.initialStep = result.initialStep;
    addNodesAndEdges(b, result);
    markReachable(b);
    return b;
  }

  /**
   * @description Builds the graph of the definition of an instance, with the
   * path of the instance on it.
   * @param instanceId The workflow instance.
   * @return The graph with its overlay.
   */
  public static Graph forInstance(Id instanceId) {
    if (instanceId == null) {
      throw handled('instanceId is required.');
    }
    List<Workflow_Instance__c> rows = [
      SELECT
        Id,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Async_Job_Id__c,
        Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      throw handled('Workflow instance not found: ' + instanceId);
    }
    Workflow_Instance__c instance = rows[0];
    GraphBuilder b = builderFor(instance.Workflow_Name__c);
    b.graph.overlay = overlayFor(instance, b);
    return b.graph;
  }

  /**
   * @description Maps the instance status to a STATE_ constant. A Suspended
   * instance with no resume job and no timer waits for a signal (#84 rule).
   * @param instance The instance (Status__c, Async_Job_Id__c, Sleep_Until__c).
   * @return The state.
   */
  public static String stateFor(Workflow_Instance__c instance) {
    if (instance.Status__c == 'Suspended') {
      Boolean hasTimer =
        String.isNotBlank(instance.Async_Job_Id__c) ||
        instance.Sleep_Until__c != null;
      return hasTimer ? STATE_SUSPENDED : STATE_AWAITING_SIGNAL;
    }
    String state = STATE_BY_STATUS.get(instance.Status__c);
    return state == null ? STATE_ENDED : state;
  }

  private static void addNodesAndEdges(
    GraphBuilder b,
    WorkflowValidator.ValidationResult result
  ) {
    WorkflowTransitionProbe.Transitions t = result.transitions;
    for (String stepName : result.declaredSteps) {
      if (String.isBlank(stepName)) {
        continue;
      }
      Node n = b.addNode(stepName, true);
      n.initial = stepName == result.initialStep;
      n.compensatable = result.compensatableSteps.contains(stepName);
      n.terminal = t.endingSteps.contains(stepName);
      n.routingUnknown = t.unresolvedSteps.contains(stepName);
    }
    for (String stepName : result.declaredSteps) {
      if (String.isBlank(stepName)) {
        continue;
      }
      for (String successor : t.successorsOf(stepName)) {
        b.addEdge(stepName, successor);
        b.addNode(successor, false);
      }
    }
    if (!t.unresolvedSteps.isEmpty()) {
      b.addReason(REASON_ROUTING_THREW);
    }
    if (t.versionsUnresolved) {
      b.addReason(REASON_VERSIONS_UNRESOLVED);
    }
  }

  // Breadth-first walk from the initial step over the known edges.
  private static void markReachable(GraphBuilder b) {
    Node start = b.nodeByName.get(
      b.graph.initialStep == null ? '' : b.graph.initialStep
    );
    List<Node> queue = new List<Node>();
    if (start != null) {
      start.reachable = true;
      queue.add(start);
    }
    for (Integer i = 0; i < queue.size(); i++) {
      for (String successor : b.successorsOf(queue[i].name)) {
        Node next = b.nodeByName.get(successor);
        if (next != null && !next.reachable) {
          next.reachable = true;
          queue.add(next);
        }
      }
    }
    for (Node n : b.graph.nodes) {
      if (n.declared && !n.reachable) {
        b.addReason(REASON_UNREACHED_STEPS);
        return;
      }
    }
  }

  private static Overlay overlayFor(
    Workflow_Instance__c instance,
    GraphBuilder b
  ) {
    Overlay overlay = new Overlay();
    overlay.instanceId = instance.Id;
    overlay.instanceStatus = instance.Status__c;
    overlay.currentState = stateFor(instance);

    Integer rowLimit = pathLimit + 1;
    List<Workflow_Step_Execution__c> newestFirst = [
      SELECT Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instance.Id
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT :rowLimit
    ];
    overlay.pathTruncated = newestFirst.size() > pathLimit;
    Integer kept = Math.min(newestFirst.size(), pathLimit);
    for (Integer i = kept - 1; i >= 0; i--) {
      overlay.path.add(new PathEntry(newestFirst[i]));
    }

    String lastForward = addTraversedEdges(overlay, b);
    overlay.currentStep = String.isNotBlank(instance.Current_Step__c)
      ? instance.Current_Step__c
      : lastForward;
    if (String.isNotBlank(overlay.currentStep)) {
      b.addNode(overlay.currentStep, false);
      overlay.nextSteps = b.successorsOf(overlay.currentStep);
    }
    return overlay;
  }

  // Adds a node for each path step and the known edges between forward rows.
  // It never adds an edge that the probe did not find: parallel branches
  // interleave their rows. Gives the last forward step name.
  private static String addTraversedEdges(Overlay overlay, GraphBuilder b) {
    String previous = null;
    for (PathEntry entry : overlay.path) {
      if (String.isBlank(entry.stepName)) {
        continue;
      }
      b.addNode(entry.stepName, false);
      if (entry.compensation) {
        continue;
      }
      if (
        previous != null &&
        previous != entry.stepName &&
        hasEdge(b.graph.edges, previous, entry.stepName) &&
        !hasEdge(overlay.traversedEdges, previous, entry.stepName)
      ) {
        overlay.traversedEdges.add(new Edge(previous, entry.stepName));
      }
      previous = entry.stepName;
    }
    return previous;
  }

  private static Boolean hasEdge(
    List<Edge> edges,
    String source,
    String target
  ) {
    for (Edge e : edges) {
      if (e.source == source && e.target == target) {
        return true;
      }
    }
    return false;
  }

  private static AuraHandledException handled(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    return ex;
  }
}
