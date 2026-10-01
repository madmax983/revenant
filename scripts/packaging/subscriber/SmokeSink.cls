/** Archive sink that keeps records in memory. */
public class SmokeSink implements __NS__.WorkflowArchiveSink {
  private final Map<Id, __NS__.WorkflowArchiveRecord> store = new Map<Id, __NS__.WorkflowArchiveRecord>();

  public void write(List<__NS__.WorkflowArchiveRecord> records) {
    for (__NS__.WorkflowArchiveRecord r : records) {
      store.put(r.instanceId, r);
    }
  }
  public List<__NS__.WorkflowArchiveRecord> readByInstanceIds(Set<Id> ids) {
    List<__NS__.WorkflowArchiveRecord> out = new List<__NS__.WorkflowArchiveRecord>();
    for (Id i : ids) {
      if (store.containsKey(i)) {
        out.add(store.get(i));
      }
    }
    return out;
  }
  public List<__NS__.WorkflowArchiveRecord> readByCorrelationKey(String key) {
    List<__NS__.WorkflowArchiveRecord> out = new List<__NS__.WorkflowArchiveRecord>();
    String hash = __NS__.WorkflowArchive.hashCorrelationKey(key);
    for (__NS__.WorkflowArchiveRecord r : store.values()) {
      if (__NS__.WorkflowArchive.hashCorrelationKey(r.correlationKey) == hash) {
        out.add(r);
      }
    }
    return out;
  }
}
