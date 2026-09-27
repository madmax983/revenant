/**
 * @description Tells a {@link PayloadCodec} which payload it encodes or
 * decodes. `decode` gets the same kind that `encode` got.
 */
public inherited sharing class CodecContext {
  /**
   * @description The author payload classes that the engine encodes.
   * - WORKFLOW_INPUT: the input of a workflow instance.
   * - STEP_OUTPUT: a step output and the workflow output.
   * - STEP_STATE: step state: suspend state, captures and progress.
   * - SIGNAL_PAYLOAD: an inbound or outbound signal payload.
   */
  public enum PayloadKind {
    WORKFLOW_INPUT,
    STEP_OUTPUT,
    STEP_STATE,
    SIGNAL_PAYLOAD
  }

  /** @description The payload class. */
  public final PayloadKind kind;

  /**
   * @description Makes a context for one payload class.
   * @param kind the payload class
   */
  public CodecContext(PayloadKind kind) {
    this.kind = kind;
  }
}
