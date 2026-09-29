// Anti-pattern: generated ids. A replay makes a second id.
public class RandomReferenceStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    Integer n = Crypto.getRandomInteger(); // expect: RANDOM_VALUE
    Long l = Crypto.getRandomLong(); // expect: RANDOM_VALUE
    Double r = Math.random(); // expect: RANDOM_VALUE
    String u = UUID.randomUUID().toString(); // expect: RANDOM_VALUE
    String hex = EncodingUtil.convertToHex(
      Crypto.generateAesKey(128) // expect: RANDOM_VALUE
    );
    Boolean coin = System.Math.random() > 0.5; // expect: RANDOM_VALUE
    return StepResult.complete(null, hex + n + l + r + u + coin);
  }
}
