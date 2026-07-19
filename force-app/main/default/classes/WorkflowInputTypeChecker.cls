/**
 * @description Primitive type-matching for start-input validation. Given a value
 * parsed from a JSON start payload (by `JSON.deserializeUntyped`), decides whether
 * it satisfies a declared {@link WorkflowInputType} under the strict, non-mutating
 * coercion rules documented on that enum, and produces a short human label for a
 * value's actual runtime kind. Pure in-memory logic — no SOQL, DML, or callouts.
 * Extracted from {@link WorkflowInputValidator} so each class stays within the
 * repo's per-class complexity budget.
 */
public inherited sharing class WorkflowInputTypeChecker {
  /**
   * @description True when the parsed value satisfies the declared primitive type.
   * @param rawValue the value parsed from the JSON payload (non-null)
   * @param expectedType the declared primitive type to check against
   * @return true when the value satisfies the type under the documented rules
   */
  public static Boolean matches(
    Object rawValue,
    WorkflowInputType expectedType
  ) {
    switch on expectedType {
      when STRING {
        return rawValue instanceof String;
      }
      when BOOLEAN {
        return rawValue instanceof Boolean;
      }
      when INTEGER, LONG {
        return rawValue instanceof Integer || rawValue instanceof Long;
      }
      when DECIMAL {
        return isNumeric(rawValue);
      }
      when DATE {
        return isDate(rawValue);
      }
      when DATETIME {
        return isDatetime(rawValue);
      }
      when else {
        return false;
      }
    }
    return false;
  }

  /**
   * @description A short human label for a parsed value's runtime kind, used in a
   * WRONG_TYPE violation's `actualType`.
   * @param rawValue the parsed value to label
   * @return a stable label such as "String", "Integer", "Object", or "Array"
   */
  public static String describeActual(Object rawValue) {
    if (rawValue instanceof String) {
      return 'String';
    }
    if (rawValue instanceof Boolean) {
      return 'Boolean';
    }
    if (rawValue instanceof Integer) {
      return 'Integer';
    }
    if (rawValue instanceof Long) {
      return 'Long';
    }
    if (rawValue instanceof Decimal) {
      return 'Decimal';
    }
    if (rawValue instanceof Double) {
      return 'Double';
    }
    if (rawValue instanceof Map<String, Object>) {
      return 'Object';
    }
    if (rawValue instanceof List<Object>) {
      return 'Array';
    }
    return 'unknown';
  }

  // Any JSON numeric kind counts as a Decimal/Number.
  private static Boolean isNumeric(Object rawValue) {
    return rawValue instanceof Integer ||
      rawValue instanceof Long ||
      rawValue instanceof Decimal ||
      rawValue instanceof Double;
  }

  // A DATE field must be a JSON string parseable as an ISO-8601 date.
  private static Boolean isDate(Object rawValue) {
    if (!(rawValue instanceof String)) {
      return false;
    }
    try {
      Object parsed = JSON.deserialize(
        JSON.serialize((String) rawValue),
        Date.class
      );
      return parsed != null;
    } catch (Exception parseFailure) {
      return false;
    }
  }

  // A DATETIME field must be a JSON string parseable as an ISO-8601 datetime.
  private static Boolean isDatetime(Object rawValue) {
    if (!(rawValue instanceof String)) {
      return false;
    }
    try {
      Object parsed = JSON.deserialize(
        JSON.serialize((String) rawValue),
        Datetime.class
      );
      return parsed != null;
    } catch (Exception parseFailure) {
      return false;
    }
  }
}
