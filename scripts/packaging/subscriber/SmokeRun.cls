/** Calls each subscriber-facing API. Throws when a call fails. */
public class SmokeRun {
  public static String run() {
    String key = 'pkg-smoke-' + String.valueOf(Datetime.now().getTime());
    Id instanceId = __NS__.WorkflowEngine.start('SmokeWorkflow', key, null);
    __NS__.WorkflowEngine.signal(key, 'Ping', null);
    __NS__.WorkflowEngine.WorkflowStatus status = __NS__.WorkflowStatusRead.getStatus(
      instanceId
    );
    check(status != null && status.instanceId == instanceId, 'status read');

    __NS__.CodecContext ctx = new __NS__.CodecContext(
      __NS__.CodecContext.PayloadKind.STEP_OUTPUT
    );
    __NS__.PayloadCodec codec = new SmokeCodec();
    check(codec.decode(codec.encode('x', ctx), ctx) == 'x', 'codec round trip');

    __NS__.WorkflowArchiveRecord rec = new __NS__.WorkflowArchiveRecord();
    rec.instanceId = instanceId;
    rec.correlationKey = key;
    __NS__.WorkflowArchiveSink sink = new SmokeSink();
    sink.write(new List<__NS__.WorkflowArchiveRecord>{ rec });
    check(
      sink.readByInstanceIds(new Set<Id>{ instanceId }).size() == 1,
      'sink read by Id'
    );
    check(
      sink.readByCorrelationKey(key.toUpperCase()).size() == 1,
      'sink read by key'
    );
    check(
      __NS__.WorkflowArchive.getArchivedHistory(null) == null,
      'archive read'
    );
    return 'PASS ' + key;
  }

  private static void check(Boolean ok, String what) {
    if (!ok) {
      throw new IllegalArgumentException('Smoke failed: ' + what);
    }
  }
}
