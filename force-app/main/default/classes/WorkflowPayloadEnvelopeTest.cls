/**
 * @description Unit tests for the stored-form envelope shape.
 */
@IsTest
private class WorkflowPayloadEnvelopeTest {
  @IsTest
  static void exactShapeIsAnEnvelope() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String plain = WorkflowPayloadEnvelope.wrap(
        CodecContext.PayloadKind.STEP_OUTPUT,
        'QUJD+/='
      );
      String escaped = WorkflowPayloadEnvelope.wrap(
        CodecContext.PayloadKind.STEP_STATE,
        'a"b\\c'
      );

      System.assertEquals(
        CodecContext.PayloadKind.STEP_OUTPUT,
        WorkflowPayloadEnvelope.kindOf(plain)
      );
      System.assertEquals(
        CodecContext.PayloadKind.STEP_STATE,
        WorkflowPayloadEnvelope.kindOf(escaped)
      );
      System.assertEquals(
        'a"b\\c',
        WorkflowPayloadEnvelope.dataOf(
          escaped,
          CodecContext.PayloadKind.STEP_STATE
        )
      );
    }
  }

  @IsTest
  static void extraPropertiesAreNotAnEnvelope() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        null,
        WorkflowPayloadEnvelope.kindOf(
          '{"$codec":"STEP_OUTPUT","data":"abc","extra":"x"}'
        ),
        'Legacy plaintext with more keys stays plaintext'
      );
      System.assertEquals(
        null,
        WorkflowPayloadEnvelope.kindOf(
          '{"$codec":"STEP_OUTPUT","data":"a\\"b","extra":"x"}'
        ),
        'Escaped data with more keys stays plaintext'
      );
      System.assertEquals(
        null,
        WorkflowPayloadEnvelope.kindOf('{"$codec":"NOPE","data":"abc"}'),
        'Unknown kind stays plaintext'
      );
      System.assertEquals(
        null,
        WorkflowPayloadEnvelope.kindOf(
          '{"$codec":"STEP_OUTPUT","data":"line1\nline2"}'
        ),
        'Raw control characters are not valid JSON, so this is plaintext'
      );
      System.assertEquals(null, WorkflowPayloadEnvelope.kindOf(null));
    }
  }
}
