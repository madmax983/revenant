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

  /** No current step, no definition, or a probe threw and gave no route. */
  public static final String NEXT_ROUTING_UNKNOWN = 'ROUTING_UNKNOWN';
  /** No step row gives the step that started the SPLIT. */
  public static final String NEXT_SPAWNING_STEP_UNKNOWN = 'SPAWNING_STEP_UNKNOWN';

  private static final String COMPENSATION_SUFFIX = '_Compensate';
  // Statuses where a rollback can be live or parked (see RowClassifier).
  private static final Set<String> LIVE_ROLLBACK_STATUSES = new Set<String>{
    'Compensating',
    'Cancelling',
    'Suspended',
    'Running',
    'CompensationFailed'
  };
  // Current_Step__c holds the branches of a SPLIT, joined with commas.
  private static final String BRANCH_SEPARATOR = ',';
  // The range of an Apex Integer, for Definition_Version__c (Number 18, 0).
  private static final Decimal MIN_VERSION = -2147483648L;
  private static final Decimal MAX_VERSION = 2147483647;
  // The statuses of the row of the step that starts a SPLIT
  // (WorkflowParallelJoin.proceedToJoin).
  private static final Set<String> SPAWNING_STATUSES = new Set<String>{
    'Completed',
    'OperatorSkipped'
  };

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
    // The validated definition, or null when it did not resolve.
    WorkflowDefinition definition;
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
    /**
     * Known successors of nextStepsFrom for the instance version. Empty for a
     * rollback or an end.
     */
    @AuraEnabled
    public List<String> nextSteps = new List<String>();
    /**
     * The step that the engine routes from: the current step, or for a SPLIT
     * the step that started it. It is null when it is not known, during a
     * rollback, or after the end.
     */
    @AuraEnabled
    public String nextStepsFrom;
    /** A probe of nextStepsFrom gave no successor: the run can end there. */
    @AuraEnabled
    public Boolean canEnd = false;
    /** Null, or a NEXT_ constant when the next step is not known. */
    @AuraEnabled
    public String nextStepsUnknownReason;
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

    private PathEntry(Workflow_Step_Execution__c row, Boolean compensation) {
      String name = row.Step_Name__c == null ? '' : row.Step_Name__c;
      this.compensation = compensation;
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
      workflowName,
      WorkflowTransitionProbe.MAX_PROBED_VERSIONS
    );
    for (WorkflowValidator.Defect d : result.defects) {
      b.graph.defects.add(d.message);
    }
    // Keep the definition before the return: the engine routes a run without
    // getSteps(), so the overlay can too.
    b.definition = result.definition;
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
        Definition_Version__c,
        Async_Job_Id__c,
        Sleep_Until__c,
        Awaited_Batch_Job_Id__c,
        Compensation_Stack__c
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

  // Breadth-first walk from the initial step over the known edges. It clears
  // the old marks first, so a second call after new edges is correct.
  private static void markReachable(GraphBuilder b) {
    for (Node n : b.graph.nodes) {
      n.reachable = false;
    }
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
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c != :WorkflowDefinitionChangeGate.MARKER_STEP_NAME
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT :rowLimit
    ];
    overlay.pathTruncated = newestFirst.size() > pathLimit;
    Integer kept = Math.min(newestFirst.size(), pathLimit);
    RowClassifier rows = new RowClassifier(b.declaredNames(), instance);
    List<PathEntry> entries = new List<PathEntry>();
    for (Integer i = 0; i < kept; i++) {
      entries.add(
        new PathEntry(newestFirst[i], rows.isCompensation(newestFirst[i]))
      );
    }
    for (Integer i = entries.size() - 1; i >= 0; i--) {
      overlay.path.add(entries[i]);
    }

    String lastForward = addPathNodes(overlay, b);
    String rollbackStep = rollbackStepOf(overlay);
    overlay.currentSteps = rollbackStep != null
      ? new List<String>{ rollbackStep }
      : currentStepsOf(instance, lastForward);
    Boolean moves =
      rollbackStep == null &&
      overlay.currentState != STATE_COMPENSATING &&
      overlay.currentState != STATE_ENDED;
    for (String stepName : overlay.currentSteps) {
      b.addNode(stepName, false);
    }
    if (moves) {
      addNextSteps(overlay, instance, newestFirst, b);
    }
    return overlay;
  }

  // Issue #290: this method routes as the engine does. A serial run routes from its
  // current step. A SPLIT (a comma in Current_Step__c) routes after the join
  // from its spawning step. The probe uses the stored instance version.
  private static void addNextSteps(
    Overlay overlay,
    Workflow_Instance__c instance,
    List<Workflow_Step_Execution__c> newestFirst,
    GraphBuilder b
  ) {
    Boolean split =
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(BRANCH_SEPARATOR);
    String fromStep = split
      ? spawningStepOf(newestFirst, overlay.currentSteps)
      : (overlay.currentSteps.isEmpty() ? null : overlay.currentSteps[0]);
    if (fromStep == null) {
      overlay.nextStepsUnknownReason = split
        ? NEXT_SPAWNING_STEP_UNKNOWN
        : NEXT_ROUTING_UNKNOWN;
      return;
    }
    overlay.nextStepsFrom = fromStep;
    b.addNode(fromStep, false);
    Decimal version = instance.Definition_Version__c;
    // The engine routes an undeclared step too, so the probe does not skip it.
    // A version out of the Integer range must not fail the graph read.
    if (b.definition == null || !isRoutableVersion(version)) {
      overlay.nextStepsUnknownReason = NEXT_ROUTING_UNKNOWN;
      return;
    }
    applyProbe(
      overlay,
      b,
      WorkflowTransitionProbe.probeStep(
        b.definition,
        fromStep,
        version == null ? null : version.intValue()
      )
    );
  }

  private static Boolean isRoutableVersion(Decimal version) {
    return version == null ||
      (version >= MIN_VERSION &&
      version <= MAX_VERSION);
  }

  // Copies the probe of nextStepsFrom to the overlay. A probe that threw or
  // varied marks the step "?". A throw also stops canEnd: it can hide a route.
  private static void applyProbe(
    Overlay overlay,
    GraphBuilder b,
    WorkflowTransitionProbe.Transitions t
  ) {
    String fromStep = overlay.nextStepsFrom;
    Boolean newEdge = false;
    for (String successor : t.successorsOf(fromStep)) {
      overlay.nextSteps.add(successor);
      // A version outside the graph probe can give a new step and route.
      b.addNode(successor, false);
      if (!b.hasEdge(fromStep, successor)) {
        b.addEdge(fromStep, successor);
        newEdge = true;
      }
    }
    if (newEdge) {
      refreshReachable(b);
    }
    Boolean threw = t.unresolvedSteps.contains(fromStep);
    if (threw) {
      b.nodeByName.get(fromStep).routingUnknown = true;
      b.addReason(REASON_ROUTING_THREW);
    }
    if (t.variedSteps.contains(fromStep)) {
      b.nodeByName.get(fromStep).routingUnknown = true;
      b.addReason(REASON_ROUTING_VARIES);
    }
    overlay.canEnd = t.endingSteps.contains(fromStep) && !threw;
    if (overlay.canEnd) {
      // The graph shows the End mark that the overlay found.
      b.nodeByName.get(fromStep).terminal = true;
    }
    if (overlay.nextSteps.isEmpty() && !overlay.canEnd) {
      overlay.nextStepsUnknownReason = NEXT_ROUTING_UNKNOWN;
    }
  }

  // Marks the reachable nodes again after the overlay adds an edge. A step
  // that the new edge reaches is no longer an unreached step.
  private static void refreshReachable(GraphBuilder b) {
    Integer i = b.graph.incompleteReasons.indexOf(REASON_UNREACHED_STEPS);
    if (i >= 0) {
      b.graph.incompleteReasons.remove(i);
    }
    b.graph.gapsFound = !b.graph.incompleteReasons.isEmpty();
    markReachable(b);
  }

  // The engine rule (WorkflowParallelJoin.proceedToJoin): the newest Completed
  // or OperatorSkipped row that is not a branch. Null when no row from the
  // query matches. Upper-case and lower-case letters are equal, as in SOQL
  // NOT IN.
  private static String spawningStepOf(
    List<Workflow_Step_Execution__c> newestFirst,
    List<String> branches
  ) {
    Set<String> branchKeys = new Set<String>();
    for (String branch : branches) {
      branchKeys.add(branch.toLowerCase());
    }
    for (Workflow_Step_Execution__c row : newestFirst) {
      if (
        SPAWNING_STATUSES.contains(row.Status__c) &&
        String.isNotBlank(row.Step_Name__c) &&
        !branchKeys.contains(row.Step_Name__c.toLowerCase())
      ) {
        return row.Step_Name__c;
      }
    }
    return null;
  }

  // The engine does not write Current_Step__c during a rollback. A rollback
  // runs or is parked (Suspended, CompensationFailed) when the state is
  // COMPENSATING or the newest row is a compensation row. The step of the
  // newest compensation row is then current. Returns null for no rollback.
  private static String rollbackStepOf(Overlay overlay) {
    if (overlay.path.isEmpty() || overlay.currentState == STATE_ENDED) {
      return null;
    }
    Boolean newestIsRollback = overlay.path[overlay.path.size() - 1]
      .compensation;
    if (!newestIsRollback && overlay.currentState != STATE_COMPENSATING) {
      return null;
    }
    for (Integer i = overlay.path.size() - 1; i >= 0; i--) {
      if (overlay.path[i].compensation) {
        return overlay.path[i].stepName;
      }
    }
    return null;
  }

  // Current_Step__c gives the current step (one for each SPLIT branch). Else
  // the last forward row.
  private static List<String> currentStepsOf(
    Workflow_Instance__c instance,
    String lastForward
  ) {
    List<String> current = new List<String>();
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

  // Adds a node for each path step. Returns the last forward step name. It
  // marks no edge as used: the rows have no branch data, and parallel
  // branches mix their rows, so two adjacent rows do not prove a transition.
  private static String addPathNodes(Overlay overlay, GraphBuilder b) {
    String previous = null;
    for (PathEntry entry : overlay.path) {
      if (String.isBlank(entry.stepName)) {
        continue;
      }
      b.addNode(entry.stepName, false);
      if (!entry.compensation) {
        previous = entry.stepName;
      }
    }
    return previous;
  }

  // Tells a compensation row from a forward row. Reads the rows newest first.
  // A row named <step>_Compensate is a compensation row when getSteps() does
  // not declare that name. When getSteps() declares it too, the engine rule
  // applies (WorkflowStepAdmission.isLiveCompensation): in a status where a
  // rollback can be live, the newest such row is a compensation row when
  // <step> is on Compensation_Stack__c. Other rows are forward rows.
  private class RowClassifier {
    final Set<String> declared;
    final Set<String> stack;
    final Set<String> seen = new Set<String>();

    RowClassifier(Set<String> declared, Workflow_Instance__c instance) {
      this.declared = declared;
      this.stack = LIVE_ROLLBACK_STATUSES.contains(instance.Status__c)
        ? compensationStackOf(instance)
        : new Set<String>();
    }

    Boolean isCompensation(Workflow_Step_Execution__c row) {
      String name = row.Step_Name__c == null ? '' : row.Step_Name__c;
      if (!name.endsWith(COMPENSATION_SUFFIX)) {
        return false;
      }
      if (!declared.contains(name)) {
        return true;
      }
      Boolean newest = seen.add(name);
      return newest && stack.contains(name.removeEnd(COMPENSATION_SUFFIX));
    }
  }

  private static Set<String> compensationStackOf(
    Workflow_Instance__c instance
  ) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return new Set<String>();
    }
    try {
      return new Set<String>(
        (List<String>) JSON.deserialize(
          instance.Compensation_Stack__c,
          List<String>.class
        )
      );
    } catch (Exception e) {
      return new Set<String>();
    }
  }

  private static AuraHandledException handled(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    return ex;
  }
}
