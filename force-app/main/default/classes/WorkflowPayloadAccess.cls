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
  // One access query covers at most 200 instance Ids.
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
   * @description Finds the instances that the running user can read. It runs a
   * user-mode query that selects only the Id, so object permission, field
   * permission and sharing all apply. A user without object access gets an
   * empty result.
   * @param recordIds the instance Ids to check
   * @return the subset the user can read
   */
  public static Set<Id> readableIds(Set<Id> recordIds) {
    Set<Id> allowed = new Set<Id>();
    List<Id> pending = new List<Id>(recordIds);
    for (Integer i = 0; i < pending.size(); i += CHUNK) {
      List<Id> batchIds = new List<Id>();
      for (Integer j = i; j < Math.min(i + CHUNK, pending.size()); j++) {
        batchIds.add(pending[j]);
      }
      try {
        for (Workflow_Instance__c inst : [
          SELECT Id
          FROM Workflow_Instance__c
          WHERE Id IN :batchIds
          WITH USER_MODE
        ]) {
          allowed.add(inst.Id);
        }
      } catch (QueryException ex) {
        // No object access: the user can read none of these instances.
        continue;
      }
    }
    return allowed;
  }
}
