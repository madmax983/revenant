// Builds the Rust lint core for wasm32 and copies it to lib/revenant_lint.wasm.
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const crate = fileURLToPath(new URL("../../revenant-lint/", import.meta.url));
const target = "wasm32-unknown-unknown";
const build = spawnSync(
  "cargo",
  ["build", "--release", "--lib", "--target", target],
  { cwd: crate, stdio: "inherit" },
);
if (build.error || build.status !== 0) {
  console.error(
    `cargo build failed. Install Rust and run: rustup target add ${target}`,
  );
  process.exit(1);
}
const out = fileURLToPath(new URL("../lib/", import.meta.url));
mkdirSync(out, { recursive: true });
copyFileSync(
  join(crate, "target", target, "release", "revenant_lint.wasm"),
  join(out, "revenant_lint.wasm"),
);
console.log("Wrote lib/revenant_lint.wasm");
