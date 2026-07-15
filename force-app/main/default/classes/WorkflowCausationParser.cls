/**
 * @description Causation-id parsing and normalization for the Revenant engine.
 * Pure, DML-free string/JSON helpers that recover a bare correlation key plus an
 * optional inline timestamp from a `key:`-scoped `Causation_Id__c` (current JSON
 * form, interim `::ts::<millis>` suffix, or legacy `#<millis>` suffix) and clean
 * a stored causation id for display. Split out from {@link WorkflowCausationLineage}
 * so each cohesive phase stays within its own complexity budget; the multi-hop
 * ancestor walk consumes {@link WorkflowCausationParser#parseCausationTimestamp}
 * and {@link WorkflowCausationParser#isValidId} to resolve each hop.
 */
public inherited sharing class WorkflowCausationParser {
  /**
   * @description Bare key + optional parsed timestamp recovered from a
   * `key:`-scoped causation id. `correlationKey` is the key stripped of any
   * encoded timestamp suffix; `earliestCreatedDate` is populated when the id
   * carried an inline timestamp (JSON `t`, `::ts::<millis>`, or legacy
   * `#<millis>`), otherwise null so the caller falls back to the predecessor
   * walk.
   */
  public class CausationKeyParse {
    /** @description The bare correlation key, stripped of any timestamp suffix. */
    public String correlationKey;
    /** @description The parsed inline timestamp, or null when none was present. */
    public DateTime earliestCreatedDate;

    /**
     * @description Constructs a parse holder.
     * @param correlationKey the recovered bare correlation key
     * @param earliestCreatedDate the parsed inline timestamp, or null
     */
    private CausationKeyParse(
      String correlationKey,
      DateTime earliestCreatedDate
    ) {
      this.correlationKey = correlationKey;
      this.earliestCreatedDate = earliestCreatedDate;
    }
  }

  /**
   * @description Parses a `key:`-prefixed causation id into a bare correlation
   * key plus an optional inline timestamp. Recognizes three encodings in this
   * priority order: current JSON form `key:{"k":..,"t":..}` -> interim
   * `<k>::ts::<millis>` suffix (when not JSON) -> legacy `<k>#<millis>`
   * suffix (fallback when neither of the above produced a timestamp). Any
   * partial-parse exception is swallowed so callers fall through to the
   * predecessor walk; on JSON partial success (the parse setting `k` before
   * failing on `t`), the correlation key remains overwritten, matching the
   * pre-refactor behavior.
   * @param cause a non-blank `key:`-prefixed causation id
   * @return the recovered bare key and, when the id carried one, the parsed
   *   inline timestamp; the timestamp is null when no encoded value is
   *   present or recoverable
   */
  public static CausationKeyParse parseCausationTimestamp(String cause) {
    CausationKeyParse first = cause.startsWith('key:{"')
      ? parseJsonCausation(cause)
      : parseTsSuffix(cause.substring(4));
    if (first.earliestCreatedDate != null) {
      return first;
    }
    // Backwards compatibility fallback for older '#' format. Applied against
    // whatever the first pass produced for correlationKey (matches pre-refactor
    // behavior, where the '#' pass ran on the possibly-JSON-mutated key).
    return parseHashSuffix(first.correlationKey);
  }

  /**
   * @description Parses the JSON `key:{"k":..,"t":..}` causation form. Returns
   * the recovered bare key and inline timestamp on success; on any
   * partial-parse failure, returns whatever fields the try block had already
   * assigned (bare key from `data.get('k')` may be populated even when the
   * timestamp is not), preserving the pre-refactor partial-success behavior.
   * @param cause the causation id, guaranteed to start with `key:{"`
   * @return a parse holder with the bare key (or the raw substring on total
   *   failure) and the parsed timestamp when available
   */
  private static CausationKeyParse parseJsonCausation(String cause) {
    String correlationKey = cause.substring(4);
    DateTime earliestCreatedDate = null;
    try {
      String jsonStr = cause.substring(4);
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
        jsonStr
      );
      correlationKey = (String) data.get('k');
      Long ms = (Long) data.get('t');
      earliestCreatedDate = DateTime.newInstance(ms);
    } catch (Exception ignored) {
      // fallback: leave earliestCreatedDate unresolved and continue
    }
    return new CausationKeyParse(correlationKey, earliestCreatedDate);
  }

  /**
   * @description Parses the interim `<k>::ts::<millis>` suffix. Trims the
   * suffix from the correlation key when the numeric tail is 12-15 digits and
   * parses as a Long; on any failure (no suffix, wrong length, non-numeric)
   * returns the input key with a null timestamp so callers fall through.
   * @param correlationKey the bare key (already stripped of the `key:` prefix)
   * @return a parse holder with the possibly-trimmed key and, on success, the
   *   parsed inline timestamp
   */
  private static CausationKeyParse parseTsSuffix(String correlationKey) {
    Integer tsIndex = correlationKey.lastIndexOf('::ts::');
    if (tsIndex == -1) {
      return new CausationKeyParse(correlationKey, null);
    }
    String tsStr = correlationKey.substring(tsIndex + 6);
    if (tsStr.length() < 12 || tsStr.length() > 15) {
      return new CausationKeyParse(correlationKey, null);
    }
    try {
      Long ms = Long.valueOf(tsStr);
      return new CausationKeyParse(
        correlationKey.substring(0, tsIndex),
        DateTime.newInstance(ms)
      );
    } catch (Exception ignored) {
      // fallback: leave earliestCreatedDate unresolved and continue
    }
    return new CausationKeyParse(correlationKey, null);
  }

  /**
   * @description Parses the legacy `<k>#<millis>` suffix as the final
   * fallback. Trims the suffix from the correlation key when the numeric tail
   * is 12-15 digits and parses as a Long; on any failure (no suffix, wrong
   * length, non-numeric) returns the input key with a null timestamp.
   * @param correlationKey the possibly-JSON-normalized key from the first pass
   * @return a parse holder with the possibly-trimmed key and, on success, the
   *   parsed legacy inline timestamp
   */
  private static CausationKeyParse parseHashSuffix(String correlationKey) {
    Integer hashIndex = correlationKey.lastIndexOf('#');
    if (hashIndex == -1) {
      return new CausationKeyParse(correlationKey, null);
    }
    String tsStr = correlationKey.substring(hashIndex + 1);
    if (tsStr.length() < 12 || tsStr.length() > 15) {
      return new CausationKeyParse(correlationKey, null);
    }
    try {
      Long ms = Long.valueOf(tsStr);
      return new CausationKeyParse(
        correlationKey.substring(0, hashIndex),
        DateTime.newInstance(ms)
      );
    } catch (Exception ignored) {
      // fallback: leave earliestCreatedDate unresolved and continue
    }
    return new CausationKeyParse(correlationKey, null);
  }

  /**
   * @description Whether the given value is a valid `Workflow_Instance__c` id.
   * @param val the candidate id string
   * @return true when val parses as an id of the Workflow_Instance__c type
   */
  public static Boolean isValidId(String val) {
    if (String.isBlank(val)) {
      return false;
    }
    try {
      Id parsed = (Id) val;
      return parsed.getSObjectType() == Workflow_Instance__c.SObjectType;
    } catch (Exception ex) {
      return false;
    }
  }

  /**
   * @description Recovers the bare key from the current JSON causation form
   * (`key:{...}`).
   * @param val a `key:`-scoped causation id
   * @return the `key:<k>` display value, or null when val is not JSON-shaped or
   *   cannot be parsed (so callers fall through to legacy trimming)
   */
  private static String parseKeyScopedJson(String val) {
    if (!val.startsWith('key:{"')) {
      return null;
    }
    try {
      String jsonStr = val.substring(4);
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
        jsonStr
      );
      return 'key:' + (String) data.get('k');
    } catch (Exception ignored) {
      return null;
    }
  }

  /**
   * @description Trims a legacy numeric uniqueness suffix delimited by the given
   * separator.
   * @param val the raw value
   * @param separator the delimiter preceding the numeric suffix
   * @return the value with the suffix removed, or null when there is no valid
   *   12-15 digit numeric suffix to strip
   */
  private static String stripNumericSuffix(String val, String separator) {
    Integer idx = val.lastIndexOf(separator);
    if (idx == -1) {
      return null;
    }
    String suffix = val.substring(idx + separator.length());
    if (suffix.length() < 12 || suffix.length() > 15) {
      return null;
    }
    try {
      Long.valueOf(suffix);
      return val.substring(0, idx);
    } catch (Exception ignored) {
      return null;
    }
  }

  /**
   * @description Normalizes a stored causation id for display by stripping the
   * uniqueness suffix from a `key:`-scoped value. Parses the current JSON form
   * (`key:{...}`) to recover the bare key, and falls back to trimming legacy
   * `::ts::<millis>` or `#<millis>` suffixes. Non-key values are returned unchanged.
   * @param val the raw causation id to clean
   * @return the display causation id, or the original value when nothing to strip
   */
  public static String cleanCausationId(String val) {
    if (String.isBlank(val) || !val.startsWith('key:')) {
      return val;
    }
    String fromJson = parseKeyScopedJson(val);
    if (fromJson != null) {
      return fromJson;
    }
    // Backwards compatibility fallback for older formats
    String tsTrimmed = stripNumericSuffix(val, '::ts::');
    if (tsTrimmed != null) {
      return tsTrimmed;
    }
    String hashTrimmed = stripNumericSuffix(val, '#');
    if (hashTrimmed != null) {
      return hashTrimmed;
    }
    return val;
  }

  /**
   * @description Whether the value carries an unambiguous `::ts::<millis>`
   * timestamp suffix (a 12-15 digit numeric tail that parses as a Long).
   * @param val the value to inspect
   * @return true when a valid timestamp suffix is present
   */
  private static Boolean hasUnambiguousTimestampSuffix(String val) {
    if (String.isBlank(val)) {
      return false;
    }
    Integer tsIndex = val.lastIndexOf('::ts::');
    if (tsIndex == -1 || tsIndex == val.length() - 6) {
      return false;
    }
    String suffix = val.substring(tsIndex + 6);
    if (suffix.length() < 12 || suffix.length() > 15) {
      return false;
    }
    try {
      Long.valueOf(suffix);
      return true;
    } catch (Exception ex) {
      return false;
    }
  }
}
