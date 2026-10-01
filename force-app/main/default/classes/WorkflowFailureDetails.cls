/**
 * @description Writes and reads `Error_Details__c` for an explicit failure:
 * the reason, then `failureData` after a separator. With a payload codec, the
 * failure data is a stored form (an envelope, or an offload marker for large
 * data). The identity codec keeps the legacy plaintext value.
 *
 * With a codec, the reason cannot contain the separator. Then only the engine
 * can write a stored form after the last separator, and {@link #resolve} does
 * not decode ciphertext that was copied into error text.
 */
public inherited sharing class WorkflowFailureDetails {
  private static final String SEPARATOR = '\nfailureData: ';
  private static final String SAFE_REASON_SEPARATOR = '\n failureData: ';
  private static final Integer ERROR_DETAILS_LIMIT = 131072;

  /**
   * @description Builds `Error_Details__c` for an explicit failure. With a
   * codec, the failure data is encoded and offloaded when it is too large. If
   * the value is still longer than the field, the reason is shortened. The
   * failure data never changes. The identity codec keeps the legacy value.
   * @param stepExec the failed step execution (owner and file title)
   * @param reason the failure reason
   * @param failureDataJson the author failure data, or null
   * @return the Error_Details__c value
   */
  public static String build(
    Workflow_Step_Execution__c stepExec,
    String reason,
    String failureDataJson
  ) {
    if (WorkflowPayloadCodecs.isIdentity()) {
      return failureDataJson == null
        ? reason
        : reason + SEPARATOR + failureDataJson;
    }
    String safeReason = reason == null
      ? null
      : reason.replace(SEPARATOR, SAFE_REASON_SEPARATOR);
    if (failureDataJson == null) {
      return safeReason;
    }
    String stored = WorkflowPayloadOffload.savePayloadIfNeeded(
      stepExec.Workflow_Instance__c,
      WorkflowPayloadCodecs.encode(
        failureDataJson,
        CodecContext.PayloadKind.STEP_OUTPUT
      ),
      'Output_Failure_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    Integer room = ERROR_DETAILS_LIMIT - SEPARATOR.length() - stored.length();
    return String.valueOf(safeReason).left(room) + SEPARATOR + stored;
  }

  /**
   * @description Replaces failure data that is in an offload file. The archive
   * uses it, because the purge deletes the file. The reason is shortened when
   * the result is longer than the field.
   * @param details the stored Error_Details__c value
   * @param replacement the text to put in place of the offload marker
   * @return the new value, or null when no failure data is offloaded
   */
  public static String replaceOffloadedData(
    String details,
    String replacement
  ) {
    Integer at = details == null ? -1 : details.lastIndexOf(SEPARATOR);
    if (
      at < 0 ||
      !details.substring(at + SEPARATOR.length())
        .startsWith(WorkflowPayloadCodecs.OFFLOAD_PREFIX)
    ) {
      return null;
    }
    Integer room =
      ERROR_DETAILS_LIMIT -
      SEPARATOR.length() -
      replacement.length();
    return details.left(Math.min(at, room)) + SEPARATOR + replacement;
  }

  /**
   * @description Decodes the failure data that {@link #build} wrote. The value
   * after the last separator is decoded only when it is a stored form. Other
   * text does not change. With the identity codec, the value does not change.
   * @param details the stored Error_Details__c value
   * @param instanceId the instance that owns the step execution
   * @return the value with plaintext failure data
   */
  public static String resolve(String details) {
    return resolveWith(details, null);
  }

  /**
   * @description Like {@link #resolve}, but checks record access first. The
   * failure data is decoded only when the user can read the instance. Else it
   * is the redaction placeholder (issue #243).
   * @param details the stored Error_Details__c value
   * @param instanceId the owner instance of the step execution
   * @return the value with plaintext failure data, or the placeholder
   */
  public static String resolveForUser(String details, Id instanceId) {
    return resolveWith(details, instanceId);
  }

  // A non-null instanceId turns on the record-access check.
  private static String resolveWith(String details, Id instanceId) {
    Integer at = details == null ? -1 : details.lastIndexOf(SEPARATOR);
    if (at < 0) {
      return details;
    }
    String stored = details.substring(at + SEPARATOR.length());
    Boolean storedForm =
      WorkflowPayloadCodecs.isEncoded(stored) ||
      stored.startsWith(WorkflowPayloadCodecs.OFFLOAD_PREFIX);
    if (!storedForm || WorkflowPayloadCodecs.isIdentity()) {
      return details;
    }
    if (
      instanceId != null &&
      !WorkflowPayloadAccess.readableIds(new Set<Id>{ instanceId })
        .contains(instanceId)
    ) {
      return details.left(at) +
        SEPARATOR +
        WorkflowPayloadAccess.DENIED_PAYLOAD;
    }
    return details.left(at) +
      SEPARATOR +
      WorkflowPayloadOffload.resolvePayload(stored, instanceId);
  }
}
