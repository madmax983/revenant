/**
 * @description Tells a {@link PayloadCodec} which payload it encodes or
 * decodes. `decode` gets the same kind that `encode` got. A copied value keeps
 * the kind of its first encode. For example, a child output that becomes a
 * signal payload keeps STEP_OUTPUT.
 */
global inherited sharing class CodecContext {
  /**
   * @description The author payload classes that the engine encodes.
   * - WORKFLOW_INPUT: the input of a workflow instance.
   * - STEP_OUTPUT: a step output and the workflow output.
   * - STEP_STATE: step state: suspend state, captures and progress.
   * - SIGNAL_PAYLOAD: a signal payload or a resume payload.
   *
   * This list is fixed. A new value breaks a subscriber `switch`.
   */
  global enum PayloadKind {
    WORKFLOW_INPUT,
    STEP_OUTPUT,
    STEP_STATE,
    SIGNAL_PAYLOAD
  }

  /** @description The payload class. */
  global PayloadKind kind { get; private set; }

  /**
   * @description Makes a context for one payload class. A subscriber can use
   * it to unit-test a codec.
   * @param kind the payload class
   */
  global CodecContext(PayloadKind kind) {
    this.kind = kind;
  }
}
