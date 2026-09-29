// Text output of a report. Same format as the native revenant-lint CLI.

export const LEVELS = { LOW: 1, MEDIUM: 2, HIGH: 3 };

/** True when a defect has this severity or a higher one. */
export function hasAtLeast(report, severity) {
  return report.defects.some((d) => LEVELS[d.severity] >= LEVELS[severity]);
}

/** One entry for each defect, then a summary line. */
export function formatReport(report) {
  const lines = [];
  for (const d of report.defects) {
    lines.push(
      `${d.file}:${d.line}:${d.column} ${d.severity} ${d.rule ?? d.code} ${d.message}`,
      `    ${d.remedy}`,
    );
  }
  const count = (s) => report.defects.filter((d) => d.severity === s).length;
  const n = report.defects.length;
  lines.push(
    `${n} defect${n === 1 ? "" : "s"} (${count("HIGH")} high, ${count("MEDIUM")} medium, ` +
      `${count("LOW")} low). ${report.filesScanned} files, ${report.stepClassesScanned} step classes, ` +
      `${report.suppressed} suppressed.`,
  );
  return lines.join("\n");
}
