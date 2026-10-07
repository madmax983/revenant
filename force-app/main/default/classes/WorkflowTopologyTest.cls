/**
 * Tests for WorkflowTopology (issue #141): the graph of a definition and the
 * path overlay of an instance.
 */
@IsTest
public class WorkflowTopologyTest {
  private static final String PREFIX = 'WorkflowTopologyTest.';
  private static final String START = PREFIX + 'StartStep';
  private static final String MIDDLE = PREFIX + 'MiddleStep';
  private static final String FINISH = PREFIX + 'FinishStep';
  private static final String GATE = PREFIX + 'GateStep';
  private static final String APPROVE = PREFIX + 'ApproveStep';
  private static final String REJECT = PREFIX + 'RejectStep';
  private static final String MISSING = PREFIX + 'MissingStep';
  private static final String V2_ONLY = PREFIX + 'VersionTwoStep';
  private static final String STAGE = PREFIX + 'Stage_Compensate';
  private static final String START_COMP = PREFIX + 'StartStep_Compensate';

  // ==========================================
  // FIXTURE STEPS
  // ==========================================

  /** @description Fixture step with rollback. */
  public class StartStep implements CompensatableStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /** @description Plain fixture step. */
  public virtual class MiddleStep implements WorkflowStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /** @description Plain fixture step. */
  public class FinishStep extends MiddleStep {
  }
  /** @description Plain fixture step. */
  public class GateStep extends MiddleStep {
  }
  /** @description Plain fixture step. */
  public class ApproveStep extends MiddleStep {
  }
  /** @description Plain fixture step. */
  public class RejectStep extends MiddleStep {
  }
  /** @description Plain fixture step. */
  public class VersionTwoStep extends MiddleStep {
  }
  /** @description A forward step whose name ends in _Compensate. */
  public class Stage_Compensate extends MiddleStep {
  }
  /** @description A forward step with the rollback-row name of StartStep. */
  public class StartStep_Compensate extends MiddleStep {
  }

  // ==========================================
  // FIXTURE WORKFLOWS
  // ==========================================

  /** @description Start -> Middle -> Finish. The probe finds all edges. */
  public class LinearWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, MIDDLE, FINISH };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Routes the steps.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      if (current == START) {
        return MIDDLE;
      }
      if (current == MIDDLE) {
        return FINISH;
      }
      return null;
    }
  }

  /**
   * @description Start -> Gate -> Approve or Reject. The gate reads the
   * output. It throws on null output and goes to Reject on empty output.
   * Thus the probe does not find Gate -> Approve.
   */
  public class BranchyWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, GATE, APPROVE, REJECT };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Routes the steps. The gate depends on the output.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      if (current == START) {
        return GATE;
      }
      if (current == GATE) {
        Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(
          result.directive().outputJson
        );
        return out.get('approved') == true ? APPROVE : REJECT;
      }
      return null;
    }
  }

  /** @description Start -> Missing. Missing is not in getSteps(). */
  public class DanglingWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Routes to a step that is not declared.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == START ? MISSING : null;
    }
  }

  /** @description Version 2 adds Middle -> VersionTwo. */
  public class VersionedTopologyWorkflow implements VersionedWorkflow {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, MIDDLE, V2_ONLY };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Gives the latest version.
     * @return 2.
     */
    public Integer getLatestVersion() {
      return 2;
    }
    /**
     * @description Routes as version 1.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return getNextStep(current, result, 1);
    }
    /**
     * @description Routes for a version.
     * @param current The step that completed.
     * @param result The step result.
     * @param version The version.
     * @return The next step, or null.
     */
    public String getNextStep(
      String current,
      StepResult result,
      Integer version
    ) {
      if (current == START) {
        return MIDDLE;
      }
      if (current == MIDDLE && version >= 2) {
        return V2_ONLY;
      }
      return null;
    }
  }

  /** @description getLatestVersion() throws. */
  public class BadVersionWorkflow implements VersionedWorkflow {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Throws.
     * @return Never.
     */
    public Integer getLatestVersion() {
      throw new IllegalArgumentException('no version');
    }
    /**
     * @description Ends.
     * @param current The step that completed.
     * @param result The step result.
     * @return Null.
     */
    public String getNextStep(String current, StepResult result) {
      return null;
    }
    /**
     * @description Ends.
     * @param current The step that completed.
     * @param result The step result.
     * @param version The version.
     * @return Null.
     */
    public String getNextStep(
      String current,
      StepResult result,
      Integer version
    ) {
      return null;
    }
  }

  /**
   * @description Start goes to Middle on null output and to Finish on empty
   * output. The probes disagree, so the routing depends on data.
   */
  public class VaryingWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, MIDDLE, FINISH };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Routes on the output.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      if (current == START) {
        return result.directive().outputJson == null ? MIDDLE : FINISH;
      }
      return null;
    }
  }

  /**
   * @description A very large latest version. Only versions 1 to 10 route
   * Middle to VersionTwo.
   */
  public class ManyVersionsWorkflow implements VersionedWorkflow {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, MIDDLE, V2_ONLY };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Gives a date-style version.
     * @return 20260930.
     */
    public Integer getLatestVersion() {
      return 20260930;
    }
    /**
     * @description Routes Start to Middle.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == START ? MIDDLE : null;
    }
    /**
     * @description Routes for a version.
     * @param current The step that completed.
     * @param result The step result.
     * @param version The version.
     * @return The next step, or null.
     */
    public String getNextStep(
      String current,
      StepResult result,
      Integer version
    ) {
      if (current == START) {
        return MIDDLE;
      }
      return current == MIDDLE && version <= 10 ? V2_ONLY : null;
    }
  }

  /** @description The initial step is not in getSteps(). */
  public class UndeclaredInitialWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ MIDDLE };
    }
    /**
     * @description Names an undeclared first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Routes Start to Middle.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == START ? MIDDLE : null;
    }
  }

  /** @description Start -> Stage_Compensate, a forward step. */
  public class SuffixWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, STAGE };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Routes Start to Stage_Compensate.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == START ? STAGE : null;
    }
  }

  /**
   * @description Start (rollback) -> StartStep_Compensate, a forward step
   * with the name of the rollback row of Start.
   */
  public class CollisionWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, START_COMP };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Routes Start to StartStep_Compensate.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == START ? START_COMP : null;
    }
  }

  /** @description Only version 1 of 60 routes Middle to an undeclared step. */
  public class SixtyVersionsWorkflow implements VersionedWorkflow {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, MIDDLE };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Gives the latest version.
     * @return 60.
     */
    public Integer getLatestVersion() {
      return 60;
    }
    /**
     * @description Routes Start to Middle.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == START ? MIDDLE : null;
    }
    /**
     * @description Routes for a version.
     * @param current The step that completed.
     * @param result The step result.
     * @param version The version.
     * @return The next step, or null.
     */
    public String getNextStep(
      String current,
      StepResult result,
      Integer version
    ) {
      if (current == START) {
        return MIDDLE;
      }
      return current == MIDDLE && version == 1 ? MISSING : null;
    }
  }

  /**
   * @description Version 1 routing of Middle throws. Version 2 ends at Middle.
   */
  public class VersionThrowsWorkflow implements VersionedWorkflow {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, MIDDLE };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Gives the latest version.
     * @return 2.
     */
    public Integer getLatestVersion() {
      return 2;
    }
    /**
     * @description Routes as version 2.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return getNextStep(current, result, 2);
    }
    /**
     * @description Routes for a version. Version 1 throws for Middle.
     * @param current The step that completed.
     * @param result The step result.
     * @param version The version.
     * @return The next step, or null.
     */
    public String getNextStep(
      String current,
      StepResult result,
      Integer version
    ) {
      if (current == START) {
        return MIDDLE;
      }
      if (current == MIDDLE && version == 1) {
        throw new IllegalArgumentException('Version 1 needs step output.');
      }
      return null;
    }
  }

  /**
   * @description 60 versions. Versions 1 and 2 of Middle read step output:
   * the null-output probe throws. Version 1 then goes to Start. Version 2
   * ends. Version 3 goes to Start or ends. Later versions go to Start, so
   * the graph probe finds no end at Middle.
   */
  public class OldVersionThrowsWorkflow implements VersionedWorkflow {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, MIDDLE };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Gives the latest version.
     * @return 60.
     */
    public Integer getLatestVersion() {
      return 60;
    }
    /**
     * @description Routes as version 60.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return getNextStep(current, result, 60);
    }
    /**
     * @description Routes for a version. Versions 1 and 2 read the output.
     * @param current The step that completed.
     * @param result The step result.
     * @param version The version.
     * @return The next step, or null.
     */
    public String getNextStep(
      String current,
      StepResult result,
      Integer version
    ) {
      if (current == START) {
        return MIDDLE;
      }
      if (current == MIDDLE && version == 3) {
        // The two probes differ: Start, then an end.
        return result.directive().outputJson == null ? START : null;
      }
      if (current == MIDDLE && version <= 2) {
        // A null output throws here. The output "{}" has length 2.
        Integer size = result.directive().outputJson.length();
        return version == 1 && size > 0 ? START : null;
      }
      return current == MIDDLE ? START : null;
    }
  }

  /** @description getSteps() is empty. Start still routes to Middle. */
  public class NoStepsWorkflow implements WorkflowDefinition {
    /**
     * @description Declares no step.
     * @return An empty list.
     */
    public List<String> getSteps() {
      return new List<String>();
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Routes Start to Middle.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == START ? MIDDLE : null;
    }
  }

  /**
   * @description Start splits into Approve and Reject, then goes to Finish.
   * Approve -> Reject is a branch route that the join does not use.
   */
  public class SplitWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ START, APPROVE, REJECT, FINISH };
    }
    /**
     * @description Names the first step.
     * @return The first step.
     */
    public String getInitialStep() {
      return START;
    }
    /**
     * @description Routes the steps.
     * @param current The step that completed.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      if (current == START) {
        return FINISH;
      }
      if (current == APPROVE) {
        return REJECT;
      }
      return null;
    }
  }

  /**
   * @description Not a workflow. The graph must not make an instance of it.
   */
  public class NotAWorkflow {
    /** @description Counts the constructor calls. */
    public NotAWorkflow() {
      constructed++;
    }
  }

  private static Integer constructed = 0;

  // ==========================================
  // HELPERS
  // ==========================================

  private static WorkflowTopology.Node node(
    WorkflowTopology.Graph graph,
    String name
  ) {
    for (WorkflowTopology.Node n : graph.nodes) {
      if (n.name == name) {
        return n;
      }
    }
    return null;
  }

  private static Boolean hasEdge(
    List<WorkflowTopology.Edge> edges,
    String source,
    String target
  ) {
    for (WorkflowTopology.Edge e : edges) {
      if (e.source == source && e.target == target) {
        return true;
      }
    }
    return false;
  }

  private static Workflow_Instance__c seedInstance(
    String workflowName,
    String status,
    String currentStep
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = workflowName,
      Status__c = status,
      Current_Step__c = currentStep,
      Correlation_Key__c = 'topology-' + Crypto.getRandomInteger(),
      Compensation_Stack__c = '["' + START + '"]'
    );
    insert inst;
    return inst;
  }

  // A null version clears the field default (1) after the insert.
  private static Workflow_Instance__c seedVersioned(
    String workflowName,
    String currentStep,
    Integer version
  ) {
    Workflow_Instance__c inst = seedInstance(
      workflowName,
      'Running',
      currentStep
    );
    inst.Definition_Version__c = version;
    update inst;
    return inst;
  }

  private static void seedSteps(Id instanceId, List<String> namesAndStatuses) {
    List<Workflow_Step_Execution__c> rows = new List<Workflow_Step_Execution__c>();
    for (String pair : namesAndStatuses) {
      rows.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = instanceId,
          Step_Name__c = pair.substringBefore('|'),
          Status__c = pair.substringAfter('|'),
          Retry_Count__c = 0
        )
      );
    }
    insert rows;
  }

  // ==========================================
  // DEFINITION GRAPH
  // ==========================================

  @IsTest
  static void linearGraphHasNodesEdgesAndMarkers() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build(
        PREFIX + 'LinearWorkflow'
      );

      System.assertEquals(PREFIX + 'LinearWorkflow', graph.workflowName);
      System.assertEquals(START, graph.initialStep);
      System.assertEquals(3, graph.nodes.size(), 'One node for each step');
      System.assertEquals(START, graph.nodes[0].name, 'Declared order');
      System.assertEquals('StartStep', graph.nodes[0].label);
      System.assertEquals(2, graph.edges.size());
      System.assert(hasEdge(graph.edges, START, MIDDLE));
      System.assert(hasEdge(graph.edges, MIDDLE, FINISH));

      System.assertEquals(true, node(graph, START).initial);
      System.assertEquals(false, node(graph, MIDDLE).initial);
      System.assertEquals(true, node(graph, START).compensatable);
      System.assertEquals(false, node(graph, MIDDLE).compensatable);
      System.assertEquals(true, node(graph, FINISH).terminal);
      System.assertEquals(false, node(graph, MIDDLE).terminal);
      System.assertEquals(true, node(graph, FINISH).reachable);
      System.assertEquals(true, node(graph, FINISH).declared);
      System.assertEquals(false, node(graph, MIDDLE).routingUnknown);

      System.assertEquals(false, graph.gapsFound);
      System.assert(graph.incompleteReasons.isEmpty());
      System.assert(graph.defects.isEmpty());
      System.assertEquals(null, graph.overlay);
    }
  }

  @IsTest
  static void dataDependentRoutingIsMarkedNotHidden() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build(
        PREFIX + 'BranchyWorkflow'
      );

      WorkflowTopology.Node gateNode = node(graph, GATE);
      System.assertEquals(
        true,
        gateNode.routingUnknown,
        'A throw from getNextStep marks the routing as not known'
      );
      System.assertEquals(
        false,
        gateNode.terminal,
        'A throw must not show as the end of the run'
      );
      System.assert(hasEdge(graph.edges, GATE, REJECT), 'Probe edge');
      System.assert(!hasEdge(graph.edges, GATE, APPROVE), 'Not found');
      System.assertEquals(false, node(graph, APPROVE).reachable);
      System.assertEquals(true, node(graph, REJECT).reachable);

      System.assertEquals(true, graph.gapsFound);
      System.assert(
        graph.incompleteReasons.contains(WorkflowTopology.REASON_ROUTING_THREW)
      );
      System.assert(
        graph.incompleteReasons.contains(
          WorkflowTopology.REASON_UNREACHED_STEPS
        )
      );
    }
  }

  @IsTest
  static void danglingSuccessorIsAnUndeclaredNode() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build(
        PREFIX + 'DanglingWorkflow'
      );

      WorkflowTopology.Node missingNode = node(graph, MISSING);
      System.assertNotEquals(null, missingNode, 'The routing bug is visible');
      System.assertEquals(false, missingNode.declared);
      System.assert(hasEdge(graph.edges, START, MISSING));
      System.assertEquals(1, graph.defects.size(), graph.defects);
      System.assert(graph.defects[0].contains(MISSING), graph.defects);
    }
  }

  @IsTest
  static void versionEdgesAreIncluded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build(
        PREFIX + 'VersionedTopologyWorkflow'
      );

      System.assert(hasEdge(graph.edges, START, MIDDLE));
      System.assert(
        hasEdge(graph.edges, MIDDLE, V2_ONLY),
        'An edge of version 2 is in the graph'
      );
      System.assertEquals(true, node(graph, MIDDLE).terminal, 'v1 ends');
      System.assertEquals(false, graph.gapsFound);
    }
  }

  @IsTest
  static void versionErrorMarksGraphIncomplete() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build(
        PREFIX + 'BadVersionWorkflow'
      );

      System.assertEquals(true, graph.gapsFound);
      System.assert(
        graph.incompleteReasons.contains(
          WorkflowTopology.REASON_VERSIONS_UNRESOLVED
        )
      );
    }
  }

  @IsTest
  static void differentProbeResultsMarkDataDependentRouting() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build(
        PREFIX + 'VaryingWorkflow'
      );

      System.assert(hasEdge(graph.edges, START, MIDDLE));
      System.assert(hasEdge(graph.edges, START, FINISH));
      System.assertEquals(true, node(graph, START).routingUnknown);
      System.assertEquals(true, graph.gapsFound);
      System.assert(
        graph.incompleteReasons.contains(
          WorkflowTopology.REASON_ROUTING_VARIES
        ),
        graph.incompleteReasons
      );
    }
  }

  @IsTest
  static void versionProbeIsCapped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build(
        PREFIX + 'ManyVersionsWorkflow'
      );

      System.assert(hasEdge(graph.edges, START, MIDDLE));
      System.assert(
        !hasEdge(graph.edges, MIDDLE, V2_ONLY),
        'Old versions are not probed'
      );
      System.assert(
        graph.incompleteReasons.contains(
          WorkflowTopology.REASON_VERSIONS_CAPPED
        ),
        graph.incompleteReasons
      );
    }
  }

  @IsTest
  static void validatorStillProbesEveryVersion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String name = PREFIX + 'SixtyVersionsWorkflow';
      WorkflowValidator.ValidationResult result = WorkflowValidator.validate(
        name
      );
      System.assert(
        result.hasDefect(WorkflowValidator.DANGLING_SUCCESSOR),
        'The validator checks version 1: ' + result.getMessages()
      );
      System.assertEquals(false, result.transitions.versionsCapped);

      WorkflowTopology.Graph graph = WorkflowTopology.build(name);
      System.assert(
        graph.incompleteReasons.contains(
          WorkflowTopology.REASON_VERSIONS_CAPPED
        )
      );
      System.assertEquals(null, node(graph, MISSING), 'Graph is capped');
    }
  }

  @IsTest
  static void undeclaredInitialStepIsANode() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build(
        PREFIX + 'UndeclaredInitialWorkflow'
      );

      WorkflowTopology.Node startNode = node(graph, START);
      System.assertNotEquals(null, startNode);
      System.assertEquals(false, startNode.declared);
      System.assertEquals(true, startNode.initial);
      System.assertEquals(
        false,
        node(graph, MIDDLE).reachable,
        'The probe reads only declared steps'
      );
      System.assert(
        graph.incompleteReasons.contains(
          WorkflowTopology.REASON_UNDECLARED_STEPS
        )
      );
    }
  }

  @IsTest
  static void unknownDefinitionGivesEmptyIncompleteGraph() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build(
        'NoSuchWorkflow_141'
      );

      System.assert(graph.nodes.isEmpty());
      System.assert(graph.edges.isEmpty());
      System.assertEquals(true, graph.gapsFound);
      System.assert(
        graph.incompleteReasons.contains(
          WorkflowTopology.REASON_DEFINITION_UNRESOLVED
        )
      );
      System.assertEquals(1, graph.defects.size(), graph.defects);
    }
  }

  @IsTest
  static void nonWorkflowClassIsNeverInstantiated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      constructed = 0;
      WorkflowTopology.Graph graph = WorkflowTopology.build(
        PREFIX + 'NotAWorkflow'
      );

      System.assertEquals(0, constructed, 'No instance of a non-workflow');
      System.assert(
        graph.incompleteReasons.contains(
          WorkflowTopology.REASON_DEFINITION_UNRESOLVED
        )
      );
    }
  }

  @IsTest
  static void blankNameGivesEmptyGraph() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.Graph graph = WorkflowTopology.build('  ');
      System.assert(graph.nodes.isEmpty());
      System.assertEquals(true, graph.gapsFound);
    }
  }

  // ==========================================
  // READ-ONLY AND BOUNDS
  // ==========================================

  @IsTest
  static void graphAndOverlayWriteNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'BranchyWorkflow',
        'Suspended',
        GATE
      );
      seedSteps(
        inst.Id,
        new List<String>{ START + '|Completed', GATE + '|Pending' }
      );
      Datetime instanceStamp = [
        SELECT SystemModstamp
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ]
      .SystemModstamp;
      Integer instances = [SELECT COUNT() FROM Workflow_Instance__c];
      Integer steps = [SELECT COUNT() FROM Workflow_Step_Execution__c];
      Integer dml = Limits.getDmlStatements();
      Integer queueables = Limits.getQueueableJobs();
      Integer events = Limits.getPublishImmediateDML();
      Integer futures = Limits.getFutureCalls();

      WorkflowTopology.build(PREFIX + 'BranchyWorkflow');
      WorkflowTopology.forInstance(inst.Id);

      System.assertEquals(dml, Limits.getDmlStatements(), 'No DML');
      System.assertEquals(queueables, Limits.getQueueableJobs(), 'No job');
      System.assertEquals(events, Limits.getPublishImmediateDML(), 'No event');
      System.assertEquals(futures, Limits.getFutureCalls(), 'No future');
      System.assertEquals(
        instances,
        [SELECT COUNT() FROM Workflow_Instance__c]
      );
      System.assertEquals(
        steps,
        [SELECT COUNT() FROM Workflow_Step_Execution__c]
      );
      Workflow_Instance__c after = [
        SELECT SystemModstamp, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(instanceStamp, after.SystemModstamp);
      System.assertEquals('["' + START + '"]', after.Compensation_Stack__c);
    }
  }

  @IsTest
  static void overlayQueryCountDoesNotGrowWithHistory() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c small = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Running',
        MIDDLE
      );
      seedSteps(small.Id, new List<String>{ START + '|Completed' });
      Workflow_Instance__c big = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Running',
        MIDDLE
      );
      List<String> many = new List<String>();
      for (Integer i = 0; i < 40; i++) {
        many.add(START + '|Completed');
      }
      seedSteps(big.Id, many);

      Integer before = Limits.getQueries();
      WorkflowTopology.forInstance(small.Id);
      Integer smallCost = Limits.getQueries() - before;
      before = Limits.getQueries();
      WorkflowTopology.forInstance(big.Id);
      Integer bigCost = Limits.getQueries() - before;

      System.assert(smallCost <= 3, 'Few queries: ' + smallCost);
      System.assert(bigCost <= smallCost, 'Constant: ' + bigCost);
    }
  }

  @IsTest
  static void longHistoryKeepsNewestRowsAndFlagsTruncation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.pathLimit = 3;
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Running',
        FINISH
      );
      seedSteps(
        inst.Id,
        new List<String>{
          START + '|Completed',
          MIDDLE + '|Completed',
          START + '|Completed',
          MIDDLE + '|Completed',
          FINISH + '|Running'
        }
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assertEquals(true, overlay.pathTruncated);
      System.assertEquals(3, overlay.path.size());
      System.assertEquals(FINISH, overlay.path[2].stepName, 'Newest last');
      System.assertEquals(START, overlay.path[0].stepName);
    }
  }

  // ==========================================
  // INSTANCE OVERLAY
  // ==========================================

  @IsTest
  static void suspendedInstanceShowsPathCurrentStepAndNextSteps() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'BranchyWorkflow',
        'Suspended',
        GATE
      );
      seedSteps(
        inst.Id,
        new List<String>{ START + '|Completed', GATE + '|Pending' }
      );

      WorkflowTopology.Graph graph = WorkflowTopology.forInstance(inst.Id);
      WorkflowTopology.Overlay overlay = graph.overlay;

      System.assertEquals(PREFIX + 'BranchyWorkflow', graph.workflowName);
      System.assertEquals(inst.Id, overlay.instanceId);
      System.assertEquals('Suspended', overlay.instanceStatus);
      System.assertEquals(new List<String>{ GATE }, overlay.currentSteps);
      System.assertEquals(
        WorkflowTopology.STATE_AWAITING_SIGNAL,
        overlay.currentState
      );
      System.assertEquals(2, overlay.path.size());
      System.assertEquals(START, overlay.path[0].stepName);
      System.assertEquals('Completed', overlay.path[0].status);
      System.assertEquals(false, overlay.path[0].compensation);
      System.assertEquals(GATE, overlay.path[1].stepName);
      System.assertEquals(new List<String>{ REJECT }, overlay.nextSteps);
      System.assertEquals(false, overlay.pathTruncated);
    }
  }

  @IsTest
  static void timerWaitIsNotASignalWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Suspended',
        MIDDLE
      );
      inst.Sleep_Until__c = System.now().addMinutes(5);
      update inst;

      System.assertEquals(
        WorkflowTopology.STATE_SUSPENDED,
        WorkflowTopology.forInstance(inst.Id).overlay.currentState
      );
    }
  }

  @IsTest
  static void statusMapsToCurrentState() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, String> expected = new Map<String, String>{
        'Pending' => WorkflowTopology.STATE_RUNNING,
        'Running' => WorkflowTopology.STATE_RUNNING,
        'Failed' => WorkflowTopology.STATE_FAILED,
        'CompensationFailed' => WorkflowTopology.STATE_FAILED,
        'Compensating' => WorkflowTopology.STATE_COMPENSATING,
        'Cancelling' => WorkflowTopology.STATE_COMPENSATING,
        'Paused' => WorkflowTopology.STATE_PARKED,
        'Held' => WorkflowTopology.STATE_PARKED,
        'DefinitionChanged' => WorkflowTopology.STATE_PARKED,
        'Completed' => WorkflowTopology.STATE_ENDED,
        'Compensated' => WorkflowTopology.STATE_ENDED,
        'Cancelled' => WorkflowTopology.STATE_ENDED,
        'ContinuedAsNew' => WorkflowTopology.STATE_ENDED
      };
      System.assertEquals(
        WorkflowTopology.STATE_SUSPENDED,
        WorkflowTopology.stateFor(
          new Workflow_Instance__c(
            Status__c = 'Suspended',
            Awaited_Batch_Job_Id__c = '707000000000001AAA'
          )
        ),
        'A batch wait is a job wait'
      );
      for (String status : expected.keySet()) {
        System.assertEquals(
          expected.get(status),
          WorkflowTopology.stateFor(
            new Workflow_Instance__c(Status__c = status)
          ),
          status
        );
      }
    }
  }

  @IsTest
  static void compensationRowsMapToTheirStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Compensating',
        MIDDLE
      );
      seedSteps(
        inst.Id,
        new List<String>{
          START + '|Completed',
          MIDDLE + '|Failed',
          START + '_Compensate|Running'
        }
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assertEquals(
        WorkflowTopology.STATE_COMPENSATING,
        overlay.currentState
      );
      System.assertEquals(3, overlay.path.size());
      System.assertEquals(START, overlay.path[2].stepName);
      System.assertEquals(true, overlay.path[2].compensation);
      System.assertEquals(
        new List<String>{ START },
        overlay.currentSteps,
        'The step in rollback is current'
      );
      System.assert(overlay.nextSteps.isEmpty(), 'No forward step');
    }
  }

  @IsTest
  static void parkedRollbackShowsTheStepInRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (
        String status : new List<String>{ 'Suspended', 'CompensationFailed' }
      ) {
        Workflow_Instance__c inst = seedInstance(
          PREFIX + 'LinearWorkflow',
          status,
          MIDDLE
        );
        seedSteps(
          inst.Id,
          new List<String>{
            START + '|Completed',
            MIDDLE + '|Failed',
            START + '_Compensate|Pending'
          }
        );

        WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
          .overlay;

        System.assertEquals(
          new List<String>{ START },
          overlay.currentSteps,
          status + ': the step in rollback is current'
        );
        System.assert(
          overlay.nextSteps.isEmpty(),
          status + ': a rollback has no forward step'
        );
      }
    }
  }

  @IsTest
  static void rollbackRowThatMatchesADeclaredStepUsesTheStack() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // seedInstance puts Start on Compensation_Stack__c.
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'CollisionWorkflow',
        'Suspended',
        START_COMP
      );
      seedSteps(
        inst.Id,
        new List<String>{
          START + '|Completed',
          START_COMP + '|Failed',
          START_COMP + '|Pending'
        }
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assertEquals(START_COMP, overlay.path[1].stepName);
      System.assertEquals(false, overlay.path[1].compensation, 'Forward row');
      System.assertEquals(START, overlay.path[2].stepName);
      System.assertEquals(true, overlay.path[2].compensation, 'Rollback row');
      System.assertEquals(new List<String>{ START }, overlay.currentSteps);
      System.assert(overlay.nextSteps.isEmpty());
    }
  }

  @IsTest
  static void completedRunKeepsACollidingForwardRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'CollisionWorkflow',
        'Completed',
        START_COMP
      );
      seedSteps(
        inst.Id,
        new List<String>{ START + '|Completed', START_COMP + '|Completed' }
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assertEquals(START_COMP, overlay.path[1].stepName);
      System.assertEquals(false, overlay.path[1].compensation);
    }
  }

  @IsTest
  static void definitionChangeMarkerRowIsNotAStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'LinearWorkflow',
        'DefinitionChanged',
        MIDDLE
      );
      seedSteps(
        inst.Id,
        new List<String>{
          START + '|Completed',
          WorkflowDefinitionChangeGate.MARKER_STEP_NAME + '|DefinitionChanged'
        }
      );

      WorkflowTopology.Graph graph = WorkflowTopology.forInstance(inst.Id);

      System.assertEquals(1, graph.overlay.path.size());
      System.assertEquals(3, graph.nodes.size(), 'No marker node');
      System.assertEquals(false, graph.gapsFound);
    }
  }

  @IsTest
  static void declaredStepWithCompensateSuffixIsAForwardStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'SuffixWorkflow',
        'Compensating',
        STAGE
      );
      seedSteps(
        inst.Id,
        new List<String>{
          START + '|Completed',
          STAGE + '|Failed',
          START + '_Compensate|Running'
        }
      );

      WorkflowTopology.Graph graph = WorkflowTopology.forInstance(inst.Id);
      WorkflowTopology.Overlay overlay = graph.overlay;

      System.assertEquals(STAGE, overlay.path[1].stepName);
      System.assertEquals(false, overlay.path[1].compensation);
      System.assertEquals(START, overlay.path[2].stepName);
      System.assertEquals(true, overlay.path[2].compensation);
      System.assertEquals(2, graph.nodes.size(), 'No invented node');
    }
  }

  @IsTest
  static void undeclaredPathStepBecomesANode() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String retired = PREFIX + 'RetiredStep';
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Failed',
        retired
      );
      seedSteps(inst.Id, new List<String>{ retired + '|Failed' });

      WorkflowTopology.Graph graph = WorkflowTopology.forInstance(inst.Id);

      WorkflowTopology.Node n = node(graph, retired);
      System.assertNotEquals(null, n, 'The run used this step');
      System.assertEquals(false, n.declared);
      System.assertEquals(
        WorkflowTopology.STATE_FAILED,
        graph.overlay.currentState
      );
    }
  }

  @IsTest
  static void parallelBranchesAreEachCurrent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Running',
        MIDDLE + ',' + FINISH
      );

      WorkflowTopology.Graph graph = WorkflowTopology.forInstance(inst.Id);

      System.assertEquals(
        new List<String>{ MIDDLE, FINISH },
        graph.overlay.currentSteps
      );
      System.assertEquals(3, graph.nodes.size(), 'No joined node');
      System.assertEquals(false, graph.gapsFound);
      // No row gives the spawning step, so the step after the join is not known.
      System.assert(graph.overlay.nextSteps.isEmpty(), 'No branch successors');
      System.assertEquals(null, graph.overlay.nextStepsFrom);
      System.assertEquals(false, graph.overlay.canEnd);
      System.assertEquals(
        WorkflowTopology.NEXT_SPAWNING_STEP_UNKNOWN,
        graph.overlay.nextStepsUnknownReason
      );
    }
  }

  // ==========================================
  // NEXT STEPS (issue #290)
  // ==========================================

  @IsTest
  static void versionedInstanceShowsOnlyTheSuccessorsOfItsVersion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wf = PREFIX + 'VersionedTopologyWorkflow';
      Workflow_Instance__c v1 = seedVersioned(wf, MIDDLE, 1);
      Workflow_Instance__c v2 = seedVersioned(wf, MIDDLE, 2);

      WorkflowTopology.Graph g1 = WorkflowTopology.forInstance(v1.Id);
      WorkflowTopology.Overlay o2 = WorkflowTopology.forInstance(v2.Id).overlay;

      System.assert(hasEdge(g1.edges, MIDDLE, V2_ONLY), 'Graph keeps union');
      System.assert(g1.overlay.nextSteps.isEmpty(), 'Version 1 ends here');
      System.assertEquals(true, g1.overlay.canEnd);
      System.assertEquals(MIDDLE, g1.overlay.nextStepsFrom);
      System.assertEquals(null, g1.overlay.nextStepsUnknownReason);
      System.assertEquals(new List<String>{ V2_ONLY }, o2.nextSteps);
      System.assertEquals(false, o2.canEnd);
    }
  }

  @IsTest
  static void nullVersionRoutesAsVersionOne() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedVersioned(
        PREFIX + 'VersionedTopologyWorkflow',
        MIDDLE,
        null
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assert(overlay.nextSteps.isEmpty(), 'The engine uses version 1');
      System.assertEquals(true, overlay.canEnd);
    }
  }

  @IsTest
  static void versionOutsideTheProbeWindowStillRoutes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedVersioned(
        PREFIX + 'SixtyVersionsWorkflow',
        MIDDLE,
        1
      );

      WorkflowTopology.Graph graph = WorkflowTopology.forInstance(inst.Id);

      System.assert(
        graph.incompleteReasons.contains(
          WorkflowTopology.REASON_VERSIONS_CAPPED
        )
      );
      System.assertEquals(new List<String>{ MISSING }, graph.overlay.nextSteps);
      System.assertEquals(false, node(graph, MISSING).declared);
      // The graph draws the route that the overlay found.
      System.assert(hasEdge(graph.edges, MIDDLE, MISSING), 'Edge added');
      System.assertEquals(true, node(graph, MISSING).reachable);
    }
  }

  @IsTest
  static void versionProbeThatThrowsGivesNotKnown() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wf = PREFIX + 'VersionThrowsWorkflow';
      Workflow_Instance__c v1 = seedVersioned(wf, MIDDLE, 1);
      Workflow_Instance__c v2 = seedVersioned(wf, MIDDLE, 2);

      WorkflowTopology.Graph g1 = WorkflowTopology.forInstance(v1.Id);
      WorkflowTopology.Overlay o2 = WorkflowTopology.forInstance(v2.Id).overlay;

      System.assertEquals(true, node(g1, MIDDLE).terminal, 'Union: v2 ends');
      System.assert(g1.overlay.nextSteps.isEmpty());
      System.assertEquals(false, g1.overlay.canEnd, 'Version 1 threw');
      System.assertEquals(
        WorkflowTopology.NEXT_ROUTING_UNKNOWN,
        g1.overlay.nextStepsUnknownReason
      );
      System.assertEquals(true, o2.canEnd);
      System.assertEquals(null, o2.nextStepsUnknownReason);
    }
  }

  @IsTest
  static void partialProbeThrowMarksTheStepUnknown() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wf = PREFIX + 'OldVersionThrowsWorkflow';
      Workflow_Instance__c inst = seedVersioned(wf, MIDDLE, 1);
      System.assertEquals(
        false,
        node(WorkflowTopology.build(wf), MIDDLE).routingUnknown,
        'The graph does not probe version 1'
      );

      WorkflowTopology.Graph graph = WorkflowTopology.forInstance(inst.Id);

      System.assertEquals(new List<String>{ START }, graph.overlay.nextSteps);
      System.assertEquals(true, node(graph, MIDDLE).routingUnknown);
      System.assert(
        graph.incompleteReasons.contains(WorkflowTopology.REASON_ROUTING_THREW)
      );
    }
  }

  @IsTest
  static void varyingProbeOfAnOldVersionMarksTheStepUnknown() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedVersioned(
        PREFIX + 'OldVersionThrowsWorkflow',
        MIDDLE,
        3
      );

      WorkflowTopology.Graph graph = WorkflowTopology.forInstance(inst.Id);

      System.assertEquals(new List<String>{ START }, graph.overlay.nextSteps);
      System.assertEquals(true, graph.overlay.canEnd);
      System.assertEquals(true, node(graph, MIDDLE).terminal, 'End mark');
      System.assertEquals(true, node(graph, MIDDLE).routingUnknown);
      System.assert(
        graph.incompleteReasons.contains(WorkflowTopology.REASON_ROUTING_VARIES)
      );
    }
  }

  @IsTest
  static void versionOutsideTheIntegerRangeGivesNotKnown() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedVersioned(
        PREFIX + 'VersionedTopologyWorkflow',
        MIDDLE,
        1
      );
      inst.Definition_Version__c = 3000000000L;
      update inst;

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assert(overlay.nextSteps.isEmpty());
      System.assertEquals(MIDDLE, overlay.nextStepsFrom);
      System.assertEquals(
        WorkflowTopology.NEXT_ROUTING_UNKNOWN,
        overlay.nextStepsUnknownReason
      );
    }
  }

  @IsTest
  static void splitShowsTheSuccessorsOfTheSpawningStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'SplitWorkflow',
        'Running',
        APPROVE + ',' + REJECT
      );
      // Oldest first. A Completed branch row and a Pending row do not count.
      seedSteps(
        inst.Id,
        new List<String>{
          FINISH + '|Completed',
          START + '|OperatorSkipped',
          APPROVE + '|Running',
          REJECT + '|Completed',
          FINISH + '|Pending'
        }
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assertEquals(
        new List<String>{ APPROVE, REJECT },
        overlay.currentSteps
      );
      System.assertEquals(START, overlay.nextStepsFrom, 'Spawning step');
      System.assertEquals(new List<String>{ FINISH }, overlay.nextSteps);
      System.assertEquals(false, overlay.canEnd);
      System.assertEquals(null, overlay.nextStepsUnknownReason);
    }
  }

  @IsTest
  static void splitWhoseSpawningStepEndsCanEnd() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'SplitWorkflow',
        'Running',
        APPROVE + ',' + START
      );
      seedSteps(
        inst.Id,
        new List<String>{
          FINISH + '|Completed',
          APPROVE + '|Running',
          START + '|Running'
        }
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assertEquals(FINISH, overlay.nextStepsFrom);
      System.assert(overlay.nextSteps.isEmpty(), 'Not the branch routes');
      System.assertEquals(true, overlay.canEnd);
    }
  }

  @IsTest
  static void splitUsesTheInstanceVersion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wf = PREFIX + 'VersionedTopologyWorkflow';
      String branches = START + ',' + FINISH;
      Workflow_Instance__c v1 = seedVersioned(wf, branches, 1);
      Workflow_Instance__c v2 = seedVersioned(wf, branches, 2);
      seedSteps(v1.Id, new List<String>{ MIDDLE + '|Completed' });
      seedSteps(v2.Id, new List<String>{ MIDDLE + '|Completed' });

      WorkflowTopology.Overlay o1 = WorkflowTopology.forInstance(v1.Id).overlay;
      WorkflowTopology.Overlay o2 = WorkflowTopology.forInstance(v2.Id).overlay;

      System.assertEquals(MIDDLE, o1.nextStepsFrom);
      System.assert(o1.nextSteps.isEmpty());
      System.assertEquals(true, o1.canEnd);
      System.assertEquals(new List<String>{ V2_ONLY }, o2.nextSteps);
    }
  }

  @IsTest
  static void singleBranchIsRoutedAsASerialStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // No comma: the engine routes from the step itself.
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'SplitWorkflow',
        'Running',
        APPROVE
      );
      seedSteps(
        inst.Id,
        new List<String>{ START + '|Completed', APPROVE + '|Running' }
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assertEquals(APPROVE, overlay.nextStepsFrom);
      System.assertEquals(new List<String>{ REJECT }, overlay.nextSteps);
    }
  }

  @IsTest
  static void undeclaredCurrentStepIsProbedAsTheEngineDoes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String retired = PREFIX + 'RetiredStep';
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Running',
        retired
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assertEquals(retired, overlay.nextStepsFrom);
      System.assert(overlay.nextSteps.isEmpty());
      System.assertEquals(true, overlay.canEnd, 'getNextStep gives null');
      System.assertEquals(null, overlay.nextStepsUnknownReason);
    }
  }

  @IsTest
  static void emptyStepListStillRoutesTheRun() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'NoStepsWorkflow',
        'Running',
        START
      );

      WorkflowTopology.Graph graph = WorkflowTopology.forInstance(inst.Id);

      System.assert(
        graph.incompleteReasons.contains(
          WorkflowTopology.REASON_DEFINITION_UNRESOLVED
        )
      );
      System.assertEquals(new List<String>{ MIDDLE }, graph.overlay.nextSteps);
      System.assertEquals(null, graph.overlay.nextStepsUnknownReason);
    }
  }

  @IsTest
  static void undeclaredSpawningStepIsProbed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String retired = PREFIX + 'RetiredStep';
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'SplitWorkflow',
        'Running',
        APPROVE + ',' + REJECT
      );
      // The branch names differ in case only. They are still branches.
      seedSteps(
        inst.Id,
        new List<String>{
          retired + '|Completed',
          APPROVE.toUpperCase() + '|Completed',
          REJECT.toLowerCase() + '|Completed'
        }
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assertEquals(retired, overlay.nextStepsFrom);
      System.assertEquals(true, overlay.canEnd);
    }
  }

  @IsTest
  static void spawningRowOutsideTheReadRowsGivesNotKnown() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowTopology.pathLimit = 1;
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'SplitWorkflow',
        'Running',
        APPROVE + ',' + REJECT
      );
      // The query reads the newest 2 rows. Start is the third newest.
      seedSteps(
        inst.Id,
        new List<String>{
          START + '|Completed',
          APPROVE + '|Completed',
          REJECT + '|Running'
        }
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assert(overlay.nextSteps.isEmpty());
      System.assertEquals(null, overlay.nextStepsFrom);
      System.assertEquals(
        WorkflowTopology.NEXT_SPAWNING_STEP_UNKNOWN,
        overlay.nextStepsUnknownReason
      );
    }
  }

  @IsTest
  static void probeThatThrowsAndEndsIsNotAnEnd() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Version 2 of Middle: the null-output probe throws, the other ends.
      Workflow_Instance__c inst = seedVersioned(
        PREFIX + 'OldVersionThrowsWorkflow',
        MIDDLE,
        2
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assert(overlay.nextSteps.isEmpty());
      System.assertEquals(false, overlay.canEnd, 'A probe threw');
      System.assertEquals(
        WorkflowTopology.NEXT_ROUTING_UNKNOWN,
        overlay.nextStepsUnknownReason
      );
    }
  }

  @IsTest
  static void stoppedRunHasNoNextStepState() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'SplitWorkflow',
        'Completed',
        null
      );
      seedSteps(inst.Id, new List<String>{ START + '|Completed' });

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assert(overlay.nextSteps.isEmpty());
      System.assertEquals(null, overlay.nextStepsFrom);
      System.assertEquals(false, overlay.canEnd);
      System.assertEquals(null, overlay.nextStepsUnknownReason);
    }
  }

  @IsTest
  static void blankCurrentStepFallsBackToLastForwardRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Completed',
        null
      );
      seedSteps(
        inst.Id,
        new List<String>{
          START + '|Completed',
          MIDDLE + '|Completed',
          FINISH + '|Completed'
        }
      );

      WorkflowTopology.Overlay overlay = WorkflowTopology.forInstance(inst.Id)
        .overlay;

      System.assertEquals(new List<String>{ FINISH }, overlay.currentSteps);
      System.assert(
        overlay.nextSteps.isEmpty(),
        'An ended run has no next step'
      );
    }
  }

  @IsTest
  static void missingInstanceThrowsHandledException() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Running',
        START
      );
      Id goneId = inst.Id;
      delete inst;
      try {
        WorkflowTopology.forInstance(goneId);
        System.assert(false, 'Expected AuraHandledException');
      } catch (AuraHandledException e) {
        System.assert(e.getMessage().contains('not found'), e.getMessage());
      }
      try {
        WorkflowTopology.forInstance(null);
        System.assert(false, 'Expected AuraHandledException');
      } catch (AuraHandledException e) {
        System.assert(e.getMessage().contains('required'), e.getMessage());
      }
    }
  }

  // ==========================================
  // PINNED DTO SHAPE
  // ==========================================

  private static Set<String> keysOf(Object value) {
    return ((Map<String, Object>) JSON.deserializeUntyped(
        JSON.serialize(value)
      ))
      .keySet();
  }

  @IsTest
  static void dtoShapeIsPinned() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = seedInstance(
        PREFIX + 'LinearWorkflow',
        'Running',
        MIDDLE
      );
      seedSteps(inst.Id, new List<String>{ START + '|Completed' });
      WorkflowTopology.Graph graph = WorkflowTopology.forInstance(inst.Id);

      System.assertEquals(
        new Set<String>{
          'workflowName',
          'initialStep',
          'nodes',
          'edges',
          'gapsFound',
          'incompleteReasons',
          'defects',
          'overlay'
        },
        keysOf(graph)
      );
      System.assertEquals(
        new Set<String>{
          'name',
          'label',
          'declared',
          'initial',
          'terminal',
          'compensatable',
          'routingUnknown',
          'reachable'
        },
        keysOf(graph.nodes[0])
      );
      System.assertEquals(
        new Set<String>{ 'source', 'target' },
        keysOf(graph.edges[0])
      );
      System.assertEquals(
        new Set<String>{
          'instanceId',
          'instanceStatus',
          'currentSteps',
          'currentState',
          'path',
          'nextSteps',
          'nextStepsFrom',
          'canEnd',
          'nextStepsUnknownReason',
          'pathTruncated'
        },
        keysOf(graph.overlay)
      );
      System.assertEquals(
        new Set<String>{ 'stepName', 'status', 'compensation' },
        keysOf(graph.overlay.path[0])
      );
    }
  }
}
