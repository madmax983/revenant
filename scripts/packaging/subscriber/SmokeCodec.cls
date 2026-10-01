/** Codec that adds a kind prefix. */
public class SmokeCodec implements __NS__.PayloadCodec {
  public String encode(String plaintext, __NS__.CodecContext ctx) {
    return ctx.kind.name() + ':' + plaintext;
  }
  public String decode(String stored, __NS__.CodecContext ctx) {
    return stored.removeStart(ctx.kind.name() + ':');
  }
}
