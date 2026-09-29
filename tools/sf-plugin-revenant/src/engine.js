// Loads the Rust lint core (wasm) and calls it through its C ABI.
// See tools/revenant-lint/src/wasm.rs.
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

export const DEFAULT_WASM = new URL("../lib/revenant_lint.wasm", import.meta.url);

/** The wasm file is not built. */
export class EngineMissingError extends Error {}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/**
 * Loads the core.
 * @param {URL} [wasmUrl] The wasm file.
 * @returns {Promise<{lint: (files: {path: string, source: string}[]) => object,
 *   lintRaw: (json: string) => object, memoryBytes: () => number}>}
 */
export async function loadEngine(wasmUrl = DEFAULT_WASM) {
  let bytes;
  try {
    bytes = await readFile(wasmUrl);
  } catch (e) {
    if (e.code === "ENOENT") {
      throw new EngineMissingError(
        `The lint core is not built (${fileURLToPath(wasmUrl)}). ` +
          'Run "npm run build" in tools/sf-plugin-revenant.',
      );
    }
    throw e;
  }
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const { memory, rl_alloc, rl_lint, rl_free } = instance.exports;

  /** Sends request JSON to the core. Returns the parsed response. */
  function lintRaw(json) {
    const input = encoder.encode(json);
    const ptr = rl_alloc(input.length) >>> 0;
    new Uint8Array(memory.buffer, ptr, input.length).set(input);
    // rl_lint frees the request. It returns (ptr << 32) | len as an i64.
    const packed = rl_lint(ptr, input.length);
    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);
    const text = decoder.decode(new Uint8Array(memory.buffer, outPtr, outLen));
    rl_free(outPtr, outLen);
    const value = JSON.parse(text);
    if (typeof value.error === "string") {
      throw new Error(`revenant-lint core: ${value.error}`);
    }
    return value;
  }

  return {
    lint: (files) => lintRaw(JSON.stringify({ files })),
    lintRaw,
    memoryBytes: () => memory.buffer.byteLength,
  };
}
