/**
 * Minimal recursive-descent parser for +, -, *, /, and parentheses — just
 * enough to back the Calculator[expr] tool in ReActLoopWorkflowExample without
 * an external dependency. Extracted into its own class so the ReAct loop
 * example stays focused on the Reason/Act/Observe orchestration.
 */
public with sharing class ReActArithmeticParser {
  private final String src;
  private Integer pos = 0;

  /**
   * @description Creates a parser over the given arithmetic expression.
   * @param expression The expression to evaluate; whitespace is ignored.
   */
  public ReActArithmeticParser(String expression) {
    this.src = (expression == null) ? '' : expression.replaceAll('\\s+', '');
  }

  /**
   * @description Parses and evaluates a full additive expression.
   * @return The evaluated decimal value.
   */
  public Decimal parseExpression() {
    Decimal value = parseTerm();
    while (pos < src.length() && (peek() == '+' || peek() == '-')) {
      String op = peek();
      pos++;
      Decimal rhs = parseTerm();
      value = (op == '+') ? value + rhs : value - rhs;
    }
    return value;
  }

  /**
   * @description Verifies the entire input was consumed.
   */
  public void expectEnd() {
    if (pos != src.length()) {
      throw new IllegalArgumentException(
        'unexpected trailing characters at position ' + pos
      );
    }
  }

  private Decimal parseTerm() {
    Decimal value = parseFactor();
    while (pos < src.length() && (peek() == '*' || peek() == '/')) {
      String op = peek();
      pos++;
      Decimal rhs = parseFactor();
      if (op == '*') {
        value = value * rhs;
      } else {
        if (rhs == 0) {
          throw new IllegalArgumentException('division by zero');
        }
        value = value / rhs;
      }
    }
    return value;
  }

  private Decimal parseFactor() {
    if (pos < src.length() && peek() == '-') {
      pos++;
      return -parseFactor();
    }
    if (pos < src.length() && peek() == '(') {
      pos++;
      Decimal value = parseExpression();
      expect(')');
      return value;
    }
    return parseNumber();
  }

  private Decimal parseNumber() {
    Integer start = pos;
    while (pos < src.length() && (peek().isNumeric() || peek() == '.')) {
      pos++;
    }
    if (start == pos) {
      throw new IllegalArgumentException(
        'expected a number at position ' + pos
      );
    }
    return Decimal.valueOf(src.substring(start, pos));
  }

  private String peek() {
    return src.substring(pos, pos + 1);
  }

  private void expect(String ch) {
    if (pos >= src.length() || peek() != ch) {
      throw new IllegalArgumentException(
        'expected "' + ch + '" at position ' + pos
      );
    }
    pos++;
  }
}
