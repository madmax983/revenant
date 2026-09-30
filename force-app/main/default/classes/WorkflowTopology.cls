/**
 * @description Read-only topology graph of a workflow definition, with an
 * optional path overlay of one instance (issue #141).
 *
 * Nodes are the getSteps() inventory. Edges are the transitions of the
 * best-effort probe that WorkflowValidator runs. A missing edge does not prove
 * that no route exists. The fields gapsFound, incompleteReasons and
 * Node.routingUnknown show the gaps that the graph finds.
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
  /** getNextStep gave different successors for the probes of a step. */
  public static final String REASON_ROUTING_VARIES = 'ROUTING_VARIES';
  /** A declared step has no known route from the initial step. */
  public static final String REASON_UNREACHED_STEPS = 'UNREACHED_STEPS';
  /** A route or a run goes to a step that getSteps() does not declare. */
  public static final String REASON_UNDECLARED_STEPS = 'UNDECLARED_STEPS';
  /** getLatestVersion() threw, so no version was probed. */
  public static final String REASON_VERSIONS_UNRESOLVED = 'VERSIONS_UNRESOLVED';
  /** The probe did not read the oldest versions. */
  public static final String REASON_VERSIONS_CAPPED = 'VERSIONS_CAPPED';

  /** The instance is queued or runs. */
  public static final String STATE_RUNNING = 'RUNNING';
  /** The instance waits for a signal, an approval or a child. */
  public static final String STATE_AWAITING_SIGNAL = 'AWAITING_SIGNAL';
  /** The instance waits for a timer, a resume job or a batch job. */
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
  // Current_Step__c holds the branches of a SPLIT, joined with commas.
  private static final String BRANCH_SEPARATOR = ',';

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
    /**
     * True when the graph finds a gap. False does not prove that the graph is
     * complete: the probe is best-effort.
     */
    @AuraEnabled
    public Boolean gapsFound = false;
    @AuraEnabled
    public List<String> incompleteReasons = new List<String>();
    /** The validator defect messages. */
    @AuraEnabled
    public List<String> defects = new List<String>();
    /** The path of one instance, or null for a definition graph. */
    @AuraEnabled
    public Overlay overlay;
  }

  // Builds a Graph. Keeps the indexes out of the serialized DTO. Names match
  // exactly (case-sensitive), as the validator's declared-step Set does.
  private class GraphBuilder {
    final Graph graph = new Graph();
    final Map<String, Node> nodeByName = new Map<String, Node>();
    final Map<String, List<String>> successorsByName = new Map<String, List<String>>();

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
      graph.gapsFound = true;
    }

    void addEdge(String source, String target) {
      if (!hasEdge(source, target)) {
        graph.edges.add(new Edge(source, target));
        if (!successorsByName.containsKey(source)) {
          successorsByName.put(source, new List<String>());
        }
        successorsByName.get(source).add(target);
      }
    }

    Set<String> declaredNames() {
      Set<String> names = new Set<String>();
      for (Node n : graph.nodes) {
        if (n.declared) {
          names.add(n.name);
        }
      }
      return names;
    }

    Boolean hasEdge(String source, String target) {
      return successorsOf(source).contains(target);
    }

    List<String> successorsOf(String stepName) {
      List<String> next = successorsByName.get(stepName);
      return next == null ? new List<String>() : new List<String>(next);
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
    /** getNextStep threw, or gave different successors for the probes. */
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
    /** The current step. A SPLIT gives one entry for each branch. */
    @AuraEnabled
    public List<String> currentSteps = new List<String>();
    /** One of the STATE_ constants. */
    @AuraEnabled
    public String currentState;
    /** The step rows, oldest first. */
    @AuraEnabled
    public List<PathEntry> path = new List<PathEntry>();
    /** Known edges that the run used. */
    @AuraEnabled
    public List<Edge> traversedEdges = new List<Edge>();
    /** Known successors of the current steps. Empty for a rollback or an end. */
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

    // A declared step can have a name that ends in _Compensate. Its row is a
    // forward row, not a compensation row.
    private PathEntry(Workflow_Step_Execution__c row, Set<String> declared) {
      String name = row.Step_Name__c == null ? '' : row.Step_Name__c;
      this.compensation =
        name.endsWith(COMPENSATION_SUFFIX) && !declared.contains(name);
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
        Sleep_Until__c,
        Awaited_Batch_Job_Id__c
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
   * instance with no resume job, no timer and no batch job waits for a signal.
   * This is the list rule of issue #84.
   * @param instance The instance (Status__c, Async_Job_Id__c, Sleep_Until__c,
   * Awaited_Batch_Job_Id__c).
   * @return The state.
   */
  public static String stateFor(Workflow_Instance__c instance) {
    if (instance.Status__c == 'Suspended') {
      Boolean hasTimer =
        String.isNotBlank(instance.Async_Job_Id__c) ||
        instance.Sleep_Until__c != null ||
        String.isNotBlank(instance.Awaited_Batch_Job_Id__c);
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
      n.initial = stepName.equals(result.initialStep);
      n.compensatable = result.compensatableSteps.contains(stepName);
      n.terminal = t.endingSteps.contains(stepName);
      n.routingUnknown =
        t.unresolvedSteps.contains(stepName) ||
        t.variedSteps.contains(stepName);
    }
    if (String.isNotBlank(result.initialStep)) {
      // An undeclared initial step still gets a node.
      b.addNode(result.initialStep, false).initial = true;
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
    if (!t.variedSteps.isEmpty()) {
      b.addReason(REASON_ROUTING_VARIES);
    }
    if (t.versionsUnresolved) {
      b.addReason(REASON_VERSIONS_UNRESOLVED);
    }
    if (t.versionsCapped) {
      b.addReason(REASON_VERSIONS_CAPPED);
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
    Set<String> declared = b.declaredNames();
    for (Integer i = kept - 1; i >= 0; i--) {
      overlay.path.add(new PathEntry(newestFirst[i], declared));
    }

    String lastForward = addTraversedEdges(overlay, b);
    overlay.currentSteps = currentStepsOf(instance, overlay, lastForward);
    Boolean moves =
      overlay.currentState != STATE_COMPENSATING &&
      overlay.currentState != STATE_ENDED;
    for (String stepName : overlay.currentSteps) {
      b.addNode(stepName, false);
      if (!moves) {
        continue;
      }
      for (String successor : b.successorsOf(stepName)) {
        if (!overlay.nextSteps.contains(successor)) {
          overlay.nextSteps.add(successor);
        }
      }
    }
    return overlay;
  }

  // During a rollback, the engine does not write Current_Step__c. The newest
  // compensation row gives the step in rollback. Else Current_Step__c gives the
  // current step (one for each SPLIT branch). Else the last forward row.
  private static List<String> currentStepsOf(
    Workflow_Instance__c instance,
    Overlay overlay,
    String lastForward
  ) {
    List<String> current = new List<String>();
    if (overlay.currentState == STATE_COMPENSATING) {
      for (Integer i = overlay.path.size() - 1; i >= 0; i--) {
        if (overlay.path[i].compensation) {
          current.add(overlay.path[i].stepName);
          return current;
        }
      }
    }
    if (String.isNotBlank(instance.Current_Step__c)) {
      for (String stepName : instance.Current_Step__c.split(BRANCH_SEPARATOR)) {
        if (String.isNotBlank(stepName) && !current.contains(stepName.trim())) {
          current.add(stepName.trim());
        }
      }
    } else if (String.isNotBlank(lastForward)) {
      current.add(lastForward);
    }
    return current;
  }

  // Adds a node for each path step and the known edges between forward rows.
  // It adds no edge that the probe did not find, because parallel branches mix
  // their rows. Returns the last forward step name.
  private static String addTraversedEdges(Overlay overlay, GraphBuilder b) {
    Set<String> used = new Set<String>();
    String previous = null;
    for (PathEntry entry : overlay.path) {
      if (String.isBlank(entry.stepName)) {
        continue;
      }
      b.addNode(entry.stepName, false);
      if (entry.compensation) {
        continue;
      }
      String key = previous + '->' + entry.stepName;
      if (
        previous != null &&
        !previous.equals(entry.stepName) &&
        b.hasEdge(previous, entry.stepName) &&
        !used.contains(key)
      ) {
        overlay.traversedEdges.add(new Edge(previous, entry.stepName));
        used.add(key);
      }
      previous = entry.stepName;
    }
    return previous;
  }

  private static AuraHandledException handled(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    return ex;
  }
}
