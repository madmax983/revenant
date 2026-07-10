/**
 * Test-only helper that mints valid, unique fake Salesforce Ids without any
 * hardcoded Id literals. The generated Id preserves the key prefix of the
 * supplied SObjectType, so behavior that depends on the prefix is retained,
 * while equality/distinctness are guaranteed by a monotonically increasing
 * counter (deterministic per call order within a transaction).
 */
@IsTest
public class TestIdFactory {
  private static Integer counter = 0;
  private static Map<Schema.SObjectType, String> prefixCache = new Map<Schema.SObjectType, String>();

  /**
   * Returns a fresh, valid 18-char Id carrying the key prefix of `sot`.
   * Successive calls return distinct Ids in a deterministic sequence.
   *
   * @param sot the SObjectType whose key prefix the generated Id should carry
   * @return a unique, valid fake Id for the given SObjectType
   */
  public static Id generate(Schema.SObjectType sot) {
    String prefix = prefixCache.get(sot);
    if (prefix == null) {
      prefix = sot.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix();
      prefixCache.put(sot, prefix);
    }
    counter++;
    String suffix = String.valueOf(counter).leftPad(15 - prefix.length(), '0');
    return Id.valueOf(prefix + suffix);
  }
}
