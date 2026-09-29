// sf revenant lint determinism (issue #135).
import { existsSync } from "node:fs";
import { relative, resolve } from "node:path";
import { Flags, SfCommand } from "@salesforce/sf-plugins-core";
import { loadEngine } from "../../../engine.js";
import { formatReport, hasAtLeast } from "../../../format.js";
import { collectSources, projectSourceDirs } from "../../../sources.js";

export default class LintDeterminism extends SfCommand {
  static summary = "Find replay-unsafe calls in Revenant step classes before deploy.";

  static description =
    "Scans the Apex source of each WorkflowStep and CompensatableStep class. " +
    "Reports calls that give a different result when the engine runs the step again: " +
    "clock reads, random values, UserInfo, async job starts, EventBus.publish (HIGH), and SOQL or SOSL (MEDIUM). " +
    "A call in produce() of a CaptureProducer is safe, because ctx.captures().once() replays its value. " +
    "The command does not scan comments, string literals, or test classes (@IsTest, or a name that ends with Test). " +
    "Exit code 1: a defect at or above --fail-on. Exit code 2: no .cls files, or another error.";

  static examples = [
    "<%= config.bin %> <%= command.id %>",
    "<%= config.bin %> <%= command.id %> --source-dir force-app --source-dir examples",
    "<%= config.bin %> <%= command.id %> --fail-on medium --json",
  ];

  static flags = {
    "source-dir": Flags.string({
      char: "d",
      multiple: true,
      summary: ".cls file or directory to scan. Default: the package directories in sfdx-project.json.",
    }),
    "fail-on": Flags.string({
      options: ["high", "medium", "low", "never"],
      default: "high",
      summary: "Set exit code 1 when a defect has this severity or a higher one.",
    }),
  };

  async run() {
    const { flags } = await this.parse(LintDeterminism);
    let report;
    try {
      report = await this.scan(flags["source-dir"]);
    } catch (e) {
      // Exit code 1 is only for defects. Each other error is exit code 2.
      throw Object.assign(e instanceof Error ? e : new Error(String(e)), { exitCode: 2 });
    }
    this.log(formatReport(report));
    const level = flags["fail-on"].toUpperCase();
    if (level !== "NEVER" && hasAtLeast(report, level)) {
      process.exitCode = 1;
    }
    return report;
  }

  /** Finds the sources and lints them. Throws when there is nothing to scan. */
  async scan(sourceDirs) {
    const cwd = process.cwd();
    let paths = sourceDirs;
    if (paths) {
      for (const p of paths) {
        if (!existsSync(resolve(cwd, p))) throw new Error(`Source path not found: ${p}`);
      }
    } else {
      const project = projectSourceDirs(cwd);
      if (!project) {
        throw new Error("No sfdx-project.json found. Run in a Salesforce DX project or use --source-dir.");
      }
      for (const m of project.missing) {
        this.warn(`Package directory not found, not scanned: ${relative(cwd, m)}`);
      }
      paths = project.dirs;
    }
    const files = collectSources(paths, cwd);
    if (files.length === 0) {
      // A gate that scans nothing must not pass.
      throw new Error("No .cls files found. Check --source-dir or the packageDirectories in sfdx-project.json.");
    }
    const engine = await loadEngine();
    return engine.lint(files);
  }
}
