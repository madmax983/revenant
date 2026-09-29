// sf revenant lint determinism (issue #135).
import { existsSync } from "node:fs";
import { relative, resolve } from "node:path";
import { Flags, SfCommand } from "@salesforce/sf-plugins-core";
import { loadEngine } from "../../../engine.js";
import { formatReport, hasAtLeast } from "../../../format.js";
import { collectSources, projectSourceDirs } from "../../../sources.js";

/** A usage error. Exit code 2, as in the native CLI. */
function usageError(message) {
  return Object.assign(new Error(message), { exitCode: 2 });
}

export default class LintDeterminism extends SfCommand {
  static summary = "Find replay-unsafe calls in Revenant step classes before deploy.";

  static description =
    "Scans the Apex source of each WorkflowStep and CompensatableStep class. " +
    "Reports calls that give a different result when the engine runs the step again: " +
    "clock reads, random values, UserInfo, async job starts (HIGH), and SOQL or SOSL (MEDIUM). " +
    "A call in a CaptureProducer class is safe, because ctx.captures().once() replays its value. " +
    "Comments and string literals are not scanned. Files of classes whose name ends with Test are excluded. " +
    "The command sets exit code 1 when a defect is at or above --fail-on.";

  static examples = [
    "<%= config.bin %> <%= command.id %>",
    "<%= config.bin %> <%= command.id %> --source-dir force-app --source-dir examples",
    "<%= config.bin %> <%= command.id %> --fail-on medium --json",
  ];

  static flags = {
    "source-dir": Flags.string({
      char: "d",
      multiple: true,
      summary: "File or directory to scan. Default: the package directories in sfdx-project.json.",
    }),
    "fail-on": Flags.string({
      options: ["high", "medium", "low", "never"],
      default: "high",
      summary: "Set exit code 1 when a defect has this severity or a higher one.",
    }),
  };

  async run() {
    const { flags } = await this.parse(LintDeterminism);
    const cwd = process.cwd();
    let paths = flags["source-dir"];
    if (paths) {
      for (const p of paths) {
        if (!existsSync(resolve(cwd, p))) throw usageError(`Source path not found: ${p}`);
      }
    } else {
      const project = projectSourceDirs(cwd);
      if (!project) {
        throw usageError("No sfdx-project.json found. Run in a Salesforce DX project or use --source-dir.");
      }
      for (const m of project.missing) {
        this.warn(`Package directory not found, not scanned: ${relative(cwd, m)}`);
      }
      paths = project.dirs;
    }

    const engine = await loadEngine();
    const report = engine.lint(collectSources(paths, cwd));
    this.log(formatReport(report));
    const level = flags["fail-on"].toUpperCase();
    if (level !== "NEVER" && hasAtLeast(report, level)) {
      process.exitCode = 1;
    }
    return report;
  }
}
