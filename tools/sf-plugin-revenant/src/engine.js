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
  const module = await WebAssembly.compile(bytes);
  let exports = (await WebAssembly.instantiate(module, {})).exports;

  /** Sends request JSON to the core. Returns the parsed response. */
  function lintRaw(json) {
    try {
      return call(exports, json);
    } catch (e) {
      // A trap (a Rust panic) can leave the heap broken. Use a new instance next time.
      if (e instanceof WebAssembly.RuntimeError) {
        exports = new WebAssembly.Instance(module, {}).exports;
      }
      throw e;
    }
  }

  return {
    lint: (files) => lintRaw(JSON.stringify({ files })),
    lintRaw,
    memoryBytes: () => exports.memory.buffer.byteLength,
  };
}

function call({ memory, rl_alloc, rl_lint, rl_free }, json) {
  const input = encoder.encode(json);
  const ptr = rl_alloc(input.length) >>> 0;
  new Uint8Array(memory.buffer, ptr, input.length).set(input);
  // rl_lint frees the request. It returns (ptr << 32) | len as an i64. JS gets
  // a signed BigInt, so read it as unsigned.
  const packed = BigInt.asUintN(64, rl_lint(ptr, input.length));
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
