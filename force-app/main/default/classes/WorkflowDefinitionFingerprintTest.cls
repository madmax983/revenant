/**
 * Unit tests for WorkflowDefinitionFingerprint (issue #89). They cover the
 * fingerprint compute, the stamp at start, and each row of the compare
 * decision table. No DML. No SOQL.
 */
@IsTest
private class WorkflowDefinitionFingerprintTest {
  /**
   * @description Plain definition with a fixed step list.
   */
  public class PlainDef implements WorkflowDefinition {
    /**
     * @description Returns the step list.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'StepA', 'StepB' };
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'StepA';
    }
    /**
     * @description Routes StepA to StepB.
     * @param current The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == 'StepA' ? 'StepB' : null;
    }
  }

  /**
   * @description Definition whose getSteps() throws.
   */
  public class ThrowingDef implements WorkflowDefinition {
    /**
     * @description Throws to simulate a broken definition.
     * @return Never returns.
     */
    public List<String> getSteps() {
      throw new WorkflowEngine.WorkflowException('boom');
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'StepA';
    }
    /**
     * @description Ends the workflow.
     * @param current The completed step.
     * @param result The step result.
     * @return Always null.
     */
    public String getNextStep(String current, StepResult result) {
      return null;
    }
  }

  @IsTest
  static void testComputeIsStableAndVersioned() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> steps = new List<String>{ 'StepA', 'StepB' };
      String fp1 = WorkflowDefinitionFingerprint.compute(steps);
      String fp2 = WorkflowDefinitionFingerprint.compute(
        new List<String>{ 'StepA', 'StepB' }
      );
      System.assertEquals(
        fp1,
        fp2,
        'Same steps must give the same fingerprint'
      );
      System.assert(
        fp1.startsWith(WorkflowDefinitionFingerprint.VERSION_PREFIX),
        'Fingerprint must carry the algorithm version prefix'
      );
      System.assertEquals(
        WorkflowDefinitionFingerprint.VERSION_PREFIX.length() + 64,
        fp1.length(),
        'Fingerprint is the prefix plus a SHA-256 hex digest'
      );
    }
  }

  @IsTest
  static void testComputeDetectsInsertRemoveRenameReorder() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String base = WorkflowDefinitionFingerprint.compute(
        new List<String>{ 'A', 'B', 'C' }
      );
      List<List<String>> changed = new List<List<String>>{
        new List<String>{ 'A', 'X', 'B', 'C' }, // insert
        new List<String>{ 'A', 'C' }, // remove
        new List<String>{ 'A', 'B2', 'C' }, // rename
        new List<String>{ 'A', 'C', 'B' } // reorder
      };
      for (List<String> steps : changed) {
        System.assertNotEquals(
          base,
          WorkflowDefinitionFingerprint.compute(steps),
          'Shape change must change the fingerprint: ' + steps
        );
      }
    }
  }

  @IsTest
  static void testComputeIgnoresCaseAndWhitespace() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        WorkflowDefinitionFingerprint.compute(
          new List<String>{ 'StepA', 'StepB' }
        ),
        WorkflowDefinitionFingerprint.compute(
          new List<String>{ ' stepa ', 'STEPB' }
        ),
        'Case and outer spaces must not change the fingerprint'
      );
    }
  }

  @IsTest
  static void testComputeBoundaryInputs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String empty = WorkflowDefinitionFingerprint.compute(new List<String>());
      System.assertEquals(
        empty,
        WorkflowDefinitionFingerprint.compute(null),
        'A null step list must equal an empty step list'
      );
      // Joined-name collision guard: ['ab','c'] and ['a','bc'] differ.
      System.assertNotEquals(
        WorkflowDefinitionFingerprint.compute(new List<String>{ 'ab', 'c' }),
        WorkflowDefinitionFingerprint.compute(new List<String>{ 'a', 'bc' }),
        'Step boundaries must be part of the fingerprint'
      );
      // A null element must not throw.
      String withNull = WorkflowDefinitionFingerprint.compute(
        new List<String>{ 'A', null }
      );
      System.assertNotEquals(null, withNull, 'Null element must not throw');
    }
  }

  @IsTest
  static void testStampWritesFingerprintAndShape() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c();
      WorkflowDefinitionFingerprint.stamp(inst, new PlainDef());
      System.assertEquals(
        WorkflowDefinitionFingerprint.compute(new PlainDef().getSteps()),
        inst.Definition_Fingerprint__c,
        'Stamp must write the fingerprint of getSteps()'
      );
      System.assertEquals(
        new List<String>{ 'StepA', 'StepB' },
        WorkflowDefinitionFingerprint.parseShape(inst.Definition_Shape__c),
        'Stamp must write the step list with its original case'
      );
    }
  }

  @IsTest
  static void testStampFailsOpen() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c();
      WorkflowDefinitionFingerprint.stamp(inst, new ThrowingDef());
      WorkflowDefinitionFingerprint.stamp(inst, null);
      WorkflowDefinitionFingerprint.stamp(inst, 'not a definition');
      System.assertEquals(
        null,
        inst.Definition_Fingerprint__c,
        'A broken definition must leave the fingerprint blank (unknown)'
      );
      WorkflowDefinitionFingerprint.stamp(null, new PlainDef());
    }
  }

  @IsTest
  static void testShapeTooLongIsDropped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> steps = new List<String>();
      for (Integer i = 0; i < 200; i++) {
        steps.add('Step'.repeat(50) + i);
      }
      System.assertEquals(
        null,
        WorkflowDefinitionFingerprint.shapeJson(steps),
        'A shape over the field size must be dropped, not truncated'
      );
      System.assertEquals(
        null,
        WorkflowDefinitionFingerprint.parseShape('not json'),
        'Bad shape JSON must parse to null'
      );
      System.assertEquals(
        null,
        WorkflowDefinitionFingerprint.parseShape(null),
        'Blank shape must parse to null'
      );
    }
  }

  // Each row of the decision table in docs/plans/2026-09-27-definition-change-detection.md.
  @IsTest
  static void testCompareDecisionTable() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String a = WorkflowDefinitionFingerprint.compute(new List<String>{ 'A' });
      String b = WorkflowDefinitionFingerprint.compute(new List<String>{ 'B' });
      String foreign = 'v0:' + a.substringAfter(':');
      assertVerdict('UNKNOWN', null, a, false);
      assertVerdict('UNKNOWN', '', a, true);
      assertVerdict('UNKNOWN', a, null, false);
      assertVerdict('UNKNOWN', foreign, b, false);
      assertVerdict('MATCH', a, a, false);
      assertVerdict('MATCH', a, a, true);
      assertVerdict('ADVISORY', a, b, true);
      assertVerdict('HALT', a, b, false);
    }
  }

  private static void assertVerdict(
    String expected,
    String stored,
    String live,
    Boolean isVersioned
  ) {
    System.assertEquals(
      expected,
      WorkflowDefinitionFingerprint.compare(stored, live, isVersioned).name(),
      'compare(' + stored + ', ' + live + ', ' + isVersioned + ')'
    );
  }

  @IsTest
  static void testLiveFingerprintForWorkflowName() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String live = WorkflowDefinitionFingerprint.liveFingerprint(
        'WorkflowDefinitionFingerprintTest.PlainDef'
      );
      System.assertEquals(
        WorkflowDefinitionFingerprint.compute(new PlainDef().getSteps()),
        live,
        'Live fingerprint must match the resolved definition'
      );
      System.assertEquals(
        null,
        WorkflowDefinitionFingerprint.liveFingerprint('No_Such_Class_89'),
        'An unresolvable class must give null, not throw'
      );
      System.assertEquals(
        null,
        WorkflowDefinitionFingerprint.liveFingerprint(
          'WorkflowDefinitionFingerprintTest.ThrowingDef'
        ),
        'A throwing getSteps() must give null, not throw'
      );
    }
  }
}
