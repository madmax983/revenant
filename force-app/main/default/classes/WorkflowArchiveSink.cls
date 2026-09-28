/**
 * @description Cold storage for terminal workflow history. The archive sweep
 * calls `write` before it deletes the primary rows. Operators call the read
 * methods through {@link WorkflowArchive}.
 *
 * Select the sink in `Revenant_Config__mdt.Archive_Sink__c`. Blank selects
 * {@link BigObjectArchiveSink}. {@link CsvArchiveSink} is also shipped.
 *
 * Rules for an implementation:
 * - `write` must be idempotent for each instance Id. A second write of the
 *   same instance must not make a duplicate.
 * - `write` must throw when it cannot store all records. The sweep then
 *   deletes nothing.
 * - `write` must not change the records it gets.
 * - `write` can make callouts. Both sweep steps are `CalloutStep`s, and the
 *   sweep does no DML before `write`. Each batch calls `write` once.
 * - Read methods must not do DML. Return steps in `sequence` order.
 * - Use a public class with a public no-argument constructor.
 */
public interface WorkflowArchiveSink {
  /**
   * @description Stores the records. Throws when a record is not stored.
   * @param records the records to store. Never null.
   */
  void write(List<WorkflowArchiveRecord> records);

  /**
   * @description Reads archived records by instance Id.
   * @param instanceIds the instance Ids. Never null.
   * @return one record for each archived Id. Unknown Ids are absent.
   */
  List<WorkflowArchiveRecord> readByInstanceIds(Set<Id> instanceIds);

  /**
   * @description Reads archived records by correlation key. Case does not
   * matter, as in `Correlation_Key__c`.
   * @param correlationKey the correlation key. Never blank.
   * @return the matching records, at most
   *         {@link WorkflowArchive#MAX_READ_RECORDS}
   */
  List<WorkflowArchiveRecord> readByCorrelationKey(String correlationKey);
}
