/**
 * @description Record-access gate for read APIs that decode payloads (issue
 * #243). The read APIs query in system mode. Before the gate decodes an encoded
 * payload, it checks that the running user can read the instance. If not, it
 * returns {@link #DENIED_PAYLOAD}. Plaintext values pass unchanged.
 */
public inherited sharing class WorkflowPayloadAccess {
  /**
   * @description Returned instead of a payload when the user cannot read the
   * instance. It is valid JSON.
   */
  public static final String DENIED_PAYLOAD = '{"$redacted":"Access denied. The user cannot read this workflow instance."}';
  // UserRecordAccess accepts at most 200 record Ids in one query.
  private static final Integer CHUNK = 200;

  /**
   * @description Decodes payloads for one API call. It loads read access one
   * time, on the first encoded value. With the identity codec it runs no SOQL.
   */
  public class Gate {
    private final Set<Id> instanceIds;
    private Set<Id> readable;

    /**
     * @description Makes a gate for the instances in one call.
     * @param instanceIds the instances whose payloads the call can decode
     */
    public Gate(Set<Id> instanceIds) {
      this.instanceIds = instanceIds == null ? new Set<Id>() : instanceIds;
    }

    /**
     * @description Decodes a stored value, or redacts it.
     * @param stored the stored value, after file rehydration
     * @param instanceId the instance that owns the value
     * @return the stored value when it is not encoded, the decoded payload
     *         when the user can read the instance, else the placeholder
     */
    public String decode(String stored, Id instanceId) {
      if (!WorkflowPayloadCodecs.isEncoded(stored)) {
        return stored;
      }
      if (readable == null) {
        readable = readableIds(instanceIds);
      }
      return readable.contains(instanceId)
        ? WorkflowPayloadCodecs.decode(stored)
        : DENIED_PAYLOAD;
    }
  }

  /**
   * @description Finds the records that the running user can read. Uses
   * `UserRecordAccess`, so sharing and object permission both apply.
   * @param recordIds the records to check
   * @return the subset the user can read
   */
  public static Set<Id> readableIds(Set<Id> recordIds) {
    Set<Id> allowed = new Set<Id>();
    List<Id> pending = new List<Id>(recordIds);
    Id userId = UserInfo.getUserId();
    for (Integer i = 0; i < pending.size(); i += CHUNK) {
      List<Id> chunk = new List<Id>();
      for (Integer j = i; j < Math.min(i + CHUNK, pending.size()); j++) {
        chunk.add(pending[j]);
      }
      for (UserRecordAccess a : [
        SELECT RecordId
        FROM UserRecordAccess
        WHERE UserId = :userId AND RecordId IN :chunk AND HasReadAccess = TRUE
      ]) {
        allowed.add(a.RecordId);
      }
    }
    return allowed;
  }
}
