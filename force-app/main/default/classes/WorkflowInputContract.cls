/**
 * @description Forever-public description of a workflow's start-input shape: an
 * ordered list of field specifications, each naming a top-level JSON key, its
 * expected {@link WorkflowInputType}, and whether the key must be present. A
 * workflow author builds one fluently inside {@link ValidatedWorkflow#getInputContract}:
 *
 * ```
 * public WorkflowInputContract getInputContract() {
 *   return new WorkflowInputContract()
 *     .require('accountId', WorkflowInputType.STRING_TYPE)
 *     .require('amount', WorkflowInputType.DECIMAL_TYPE)
 *     .optional('vipOnboarding', WorkflowInputType.BOOLEAN_TYPE);
 * }
 * ```
 *
 * The contract is validated in memory only (no SOQL/DML). It is intentionally
 * minimal for v1 — required keys plus primitive types, per issue #51's scope —
 * and is designed to evolve additively (new field kinds, nested shapes) without
 * breaking existing contracts. The builder methods return the same contract for
 * chaining; {@link #getFields} exposes the accumulated specs (defensively copied)
 * for the validator and for tooling.
 */
public inherited sharing class WorkflowInputContract {
  private final List<Field> fields = new List<Field>();

  /**
   * @description One field specification within a {@link WorkflowInputContract}:
   * the top-level JSON key, its expected primitive type, and whether it must be
   * present in the start payload. Immutable once built.
   */
  public class Field {
    /** @description The top-level JSON key this spec constrains. */
    public String name { get; private set; }
    /** @description The primitive type the key's value must satisfy. */
    public WorkflowInputType expectedType { get; private set; }
    /** @description True when the key must be present and non-null. */
    public Boolean required { get; private set; }

    /**
     * @description Builds a spec whose key is optional by default; the enclosing
     * contract flips {@link #required} on for {@link WorkflowInputContract#require}.
     * @param name the top-level JSON key
     * @param expectedType the primitive type the value must satisfy
     */
    private Field(String name, WorkflowInputType expectedType) {
      this.name = name;
      this.expectedType = expectedType;
      this.required = false;
    }
  }

  /**
   * @description Declares a required field: the key must be present and non-null,
   * and its value must satisfy the declared type.
   * @param name the top-level JSON key that must be present
   * @param expectedType the primitive type the value must satisfy
   * @return this contract, for fluent chaining
   */
  public WorkflowInputContract require(
    String name,
    WorkflowInputType expectedType
  ) {
    Field spec = new Field(name, expectedType);
    spec.required = true;
    this.fields.add(spec);
    return this;
  }

  /**
   * @description Declares an optional, type-checked field: the key may be absent,
   * but when present and non-null its value must satisfy the declared type.
   * @param name the top-level JSON key to type-check when present
   * @param expectedType the primitive type the value must satisfy when present
   * @return this contract, for fluent chaining
   */
  public WorkflowInputContract optional(
    String name,
    WorkflowInputType expectedType
  ) {
    this.fields.add(new Field(name, expectedType));
    return this;
  }

  /**
   * @description Returns the declared field specs in declaration order. The list
   * is a defensive copy, so mutating it does not alter the contract.
   * @return the field specifications making up this contract
   */
  public List<Field> getFields() {
    return this.fields.clone();
  }

  /**
   * @description True when the contract declares no fields, in which case
   * validation is a no-op (equivalent to not declaring a contract at all).
   * @return true when the contract carries no field specifications
   */
  public Boolean isEmpty() {
    return this.fields.isEmpty();
  }
}
