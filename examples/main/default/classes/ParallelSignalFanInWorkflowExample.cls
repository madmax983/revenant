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
  /**
   * The distinct ack names the collector branch gathers (one per upstream
   * worker/region) -- the point is there can be many. Stored lower-cased so the
   * in-memory membership test matches the engine's case-insensitive signal-name
   * matching (StepContext.matchesFor), so an 'ack:US'-cased delivery is not
   * silently dropped. Declared on the outer class because Apex does not allow
   * static members on inner classes.
   */
  static final Set<String> EXPECTED_ACK_NAMES = new Set<String>{
    'ack:us',
    'ack:eu',
    'ack:apac'
  };

  /**
   * @description Lists the ordered step names in this workflow.
   * @return The step names in execution order.
   */
  public List<String> getSteps() {
    return new List<String>{
      'ParallelSignalFanInWorkflowExample.GatherSpawnStep',
      'ParallelSignalFanInWorkflowExample.CollectorBranch',
      'ParallelSignalFanInWorkflowExample.SiblingBranch',
      'ParallelSignalFanInWorkflowExample.JoinStep'
    };
  }

  /**
   * @description Names the first step to run when an instance starts.
   * @return The initial step name.
   */
  public String getInitialStep() {
    return 'ParallelSignalFanInWorkflowExample.GatherSpawnStep';
  }

  /**
   * @description Determines the step to run after the current one completes; the
   * gather step routes to the join step and branches otherwise end their path.
   * @param currentStepName The name of the step that just completed.
   * @param stepResult The result of the completed step.
   * @return The join step after the gather step, or null otherwise.
   */
  public String getNextStep(String currentStepName, StepResult stepResult) {
    // Branches join back at the gather step's successor; the join step ends it.
    if (
      currentStepName == 'ParallelSignalFanInWorkflowExample.GatherSpawnStep'
    ) {
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
    /**
     * @description Waits for the Kick signal, then splits into the collector and
     * sibling branches, forwarding the kick payload.
     * @param ctx The durable step context for this execution.
     * @return A suspend result until kicked, or a split into the two branches.
     */
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
   *
   * It also waits for the WHOLE expected set: if only a subset of acks has been
   * buffered it suspends (without consuming the partial set) rather than joining
   * with an incomplete result, and resumes when a later ack re-drives it. If the
   * single getSignals() page was truncated by the governor cap (a pathological
   * same-name backlog hiding the still-missing names beyond the page), it falls
   * back to a name-scoped getSignal() per missing name before suspending, so the
   * branch cannot livelock re-reading the same capped page.
   */
  public class CollectorBranch implements WorkflowStep {
    /**
     * @description Claims the whole pending signal page with a single getSignals()
     * call, filters to the expected acks, and completes only once every expected ack
     * is present; suspends (with a capped-page name-scoped fallback) otherwise.
     * @param ctx The durable step context for this execution.
     * @return A suspend result until all acks arrive, or completion with the acks.
     */
    public StepResult execute(StepContext ctx) {
      // RECOMMENDED PRIMITIVE: one getSignals() call claims the whole pending
      // page in a single statement and stays exactly-once.
      //
      // CAVEAT: an unscoped getSignals() marks EVERY pending signal observed, so
      // the COMPLETE transition consumes all of them -- including any not in
      // EXPECTED_ACK_NAMES. Use this full-list-and-filter pattern only when this
      // branch owns the instance's signal namespace (here the sibling branch
      // consumes no signals); otherwise a row meant for a sibling would be
      // consumed here and never delivered. When branches share a namespace,
      // scope the read per name instead.
      Map<String, String> received = new Map<String, String>();
      for (StepContext.Signal s : ctx.getSignals()) {
        String name = (s.name == null) ? null : s.name.toLowerCase();
        if (EXPECTED_ACK_NAMES.contains(name)) {
          // Key by the CANONICAL (lower-cased) name -- the same form used for the
          // membership test -- so a case-variant redelivery ('Ack:US' then
          // 'ack:us') collapses to one entry instead of two. Keying by the raw
          // s.name would let those count as two distinct acks and push
          // received.size() to the gate while a real expected name is still
          // missing. The original-case name is kept as the value for display.
          received.put(name, s.name);
        }
      }

      // FAN-IN GATING: only COMPLETE once every expected ack is present. If just
      // a subset has arrived (the branch was re-driven before the rest were
      // buffered), suspend instead of completing on a partial set. The engine
      // rolls this branch's claims back from Processing to Received on any
      // non-COMPLETE outcome (WorkflowEngine.rollbackClaimedSignals), so the
      // partial acks are neither consumed nor lost; when a later ack re-drives
      // this branch, getSignals() re-reads the full set and consumes it exactly
      // once at COMPLETE.
      if (received.size() < EXPECTED_ACK_NAMES.size()) {
        // CAPPED-PAGE FALLBACK: the unscoped getSignals() page is bounded by the
        // engine's governor-safety cap (PARALLEL_CLAIM_ROW_CAP). At pathological
        // scale -- thousands of unconsumed same-name rows (e.g. redelivered
        // 'Ack:US') older than the still-missing names -- those rows fill the
        // whole oldest-first page, so an unscoped read never reaches 'Ack:EU' /
        // 'Ack:APAC'. Plain suspend would roll the claims back and re-read the
        // SAME oldest page on every re-drive, stranding the branch forever.
        // ctx.signalReadWasCapped() detects exactly this truncation. When it
        // fires, fall back to a NAME-SCOPED read per missing name: a per-name
        // query filters on Signal_Name__c, so it is not starved by a different
        // name's backlog and reaches the buried acks directly. This stays
        // exactly-once while the per-branch claim budget lasts and degrades to
        // the engine's documented at-least-once once it is spent.
        if (ctx.signalReadWasCapped()) {
          for (String expected : EXPECTED_ACK_NAMES) {
            if (received.containsKey(expected)) {
              continue;
            }
            StepContext.Signal scoped = ctx.getSignal(expected);
            if (scoped.isPresent()) {
              received.put(expected, scoped.name);
            }
          }
        }
        if (received.size() < EXPECTED_ACK_NAMES.size()) {
          return StepResult.suspend();
        }
      }

      List<String> presentNames = new List<String>(received.values());
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
    /**
     * @description Trivial branch that completes immediately so the SPLIT fans out
     * into more than one branch.
     * @param ctx The durable step context for this execution.
     * @return A completion result carrying a placeholder ack.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'ack');
    }
  }

  /** Join step: surfaces the merged branch input as its output. */
  public class JoinStep implements WorkflowStep {
    /**
     * @description Join step that surfaces the merged branch input as its output.
     * @param ctx The durable step context for this execution.
     * @return A completion result echoing the merged branch input JSON.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, ctx.inputJson);
    }
  }
}
