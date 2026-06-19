/**
 * Reference example for issue #38: reading MANY DISTINCT signal names inside a
 * parallel (scatter-gather) branch with the recommended primitive.
 *
 * A step running as one branch of a parallel SPLIT atomically CLAIMS each signal
 * it reads (Received -> Processing, promoted to Consumed at COMPLETE) so two
 * sibling branches can never both process the same payload. For governor safety
 * the claim is bounded: each per-name ctx.getSignal(name) / ctx.hasSignal(name)
 * spends one claim DML statement (and one FOR UPDATE lock query), so a fan-in
 * branch that probes many distinct names one-by-one approaches the DML-statement
 * / SOQL limits and, past the engine's internal per-branch budget, degrades to
 * at-least-once (it reads the overflow names without claiming).
 *
 * The recommended primitive for multi-name inspection is therefore a SINGLE
 * ctx.getSignals() call: it claims the whole pending page in one statement and
 * filters in memory, keeping the read exactly-once and within limits no matter
 * how many distinct names the branch cares about. CollectorBranch below shows
 * the pattern.
 */
public inherited sharing class ParallelSignalFanInWorkflowExample implements WorkflowDefinition {
  public String getInitialStep() {
    return 'ParallelSignalFanInWorkflowExample.GatherSpawnStep';
  }

  public String getNextStep(String currentStepName, StepResult stepResult) {
    // Branches join back at the gather step's successor; the join step ends it.
    if (currentStepName == 'ParallelSignalFanInWorkflowExample.GatherSpawnStep') {
      return 'ParallelSignalFanInWorkflowExample.JoinStep';
    }
    return null;
  }

  // --- STEP DEFINITIONS ---

  /**
   * Waits for the Kick signal, then fans out into the collector branch (which
   * gathers the distinct named acks) and a trivial sibling branch.
   */
  public class GatherSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal kick = ctx.getSignal('Kick');
      if (!kick.isPresent()) {
        // Nothing to gather yet -- suspend until the fan-out is kicked off.
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{
          'ParallelSignalFanInWorkflowExample.CollectorBranch',
          'ParallelSignalFanInWorkflowExample.SiblingBranch'
        },
        kick.payload
      );
    }
  }

  /**
   * The fan-in branch. It needs to inspect several DISTINCT signal names (here,
   * one acknowledgement per upstream worker/region). Instead of issuing a
   * separate ctx.getSignal('Ack:US'), ctx.getSignal('Ack:EU'), ... per name --
   * each its own claim statement that can spill past the per-branch budget into
   * at-least-once -- it calls ctx.getSignals() ONCE (a single exactly-once claim
   * page) and filters the result in memory.
   */
  public class CollectorBranch implements WorkflowStep {
    // The distinct names this branch gathers. In a real workflow these might be
    // generated, one per upstream worker; the point is there can be many.
    static final Set<String> EXPECTED = new Set<String>{
      'Ack:US',
      'Ack:EU',
      'Ack:APAC'
    };

    public StepResult execute(StepContext ctx) {
      // RECOMMENDED PRIMITIVE: one getSignals() call claims the whole pending
      // page in a single statement and stays exactly-once.
      Map<String, Object> received = new Map<String, Object>();
      for (StepContext.Signal s : ctx.getSignals()) {
        if (EXPECTED.contains(s.name)) {
          received.put(s.name, s.payload);
        }
      }

      List<String> presentNames = new List<String>(received.keySet());
      presentNames.sort();

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'collectedVia' => 'getSignals',
          'present' => presentNames,
          'count' => presentNames.size()
        }
      );
    }
  }

  /** Trivial sibling so the SPLIT fans out into more than one branch. */
  public class SiblingBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'ack');
    }
  }

  /** Join step: surfaces the merged branch input as its output. */
  public class JoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, ctx.inputJson);
    }
  }
}
