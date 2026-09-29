//! `revenant-lint`: native CLI for the determinism lint.
//!
//! Exit codes: 0 pass, 1 a defect at or above `--fail-on`, 2 usage error,
//! I/O error, or no `.cls` files.

use std::collections::HashSet;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use anyhow::{Context, Result, bail};
use revenant_lint::{Report, Severity, SourceFile, lint};

const USAGE: &str = "\
Usage: revenant-lint [OPTIONS] <PATH>...

Finds replay-unsafe calls in Revenant step classes (.cls files).

Options:
  --fail-on <LEVEL>  Exit 1 at this severity or higher: high (default), medium, low, never
  --json             Print the report as JSON
  -h, --help         Print this help
  -V, --version      Print the version

Exit codes: 0 pass, 1 gate failed, 2 usage error, I/O error, or no .cls files.";

struct Args {
    fail_on: Option<Severity>,
    json: bool,
    paths: Vec<PathBuf>,
}

enum Command {
    Run(Args),
    Help,
    Version,
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<ExitCode> {
    let args = match parse_args(std::env::args().skip(1))? {
        Command::Help => {
            println!("{USAGE}");
            return Ok(ExitCode::SUCCESS);
        }
        Command::Version => {
            println!("revenant-lint {}", env!("CARGO_PKG_VERSION"));
            return Ok(ExitCode::SUCCESS);
        }
        Command::Run(args) => args,
    };
    let mut walk = Walk::default();
    for path in &args.paths {
        walk.collect(path)?;
    }
    if walk.files.is_empty() {
        // A gate that scans nothing must not pass.
        bail!("No .cls files found in the given paths.");
    }
    let report = lint(&walk.files);
    let text = if args.json {
        serde_json::to_string_pretty(&report)? + "\n"
    } else {
        human(&report)
    };
    // A closed pipe (`| head`) is not an error. The exit code still applies.
    if let Err(e) = std::io::stdout().lock().write_all(text.as_bytes())
        && e.kind() != std::io::ErrorKind::BrokenPipe
    {
        return Err(e.into());
    }
    let failed = args.fail_on.is_some_and(|level| report.has_at_least(level));
    Ok(if failed {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    })
}

fn parse_args(mut input: impl Iterator<Item = String>) -> Result<Command> {
    let mut args = Args {
        fail_on: Some(Severity::High),
        json: false,
        paths: Vec::new(),
    };
    while let Some(arg) = input.next() {
        match arg.as_str() {
            "-h" | "--help" => return Ok(Command::Help),
            "-V" | "--version" => return Ok(Command::Version),
            "--json" => args.json = true,
            "--fail-on" => {
                let level = input.next().context("--fail-on needs a value")?;
                args.fail_on = parse_level(&level)?;
            }
            s if s.starts_with("--fail-on=") => {
                args.fail_on = parse_level(&s["--fail-on=".len()..])?;
            }
            s if s.starts_with('-') => bail!("unknown option {s}\n\n{USAGE}"),
            _ => args.paths.push(PathBuf::from(arg)),
        }
    }
    if args.paths.is_empty() {
        bail!("give one or more paths\n\n{USAGE}");
    }
    Ok(Command::Run(args))
}

fn parse_level(level: &str) -> Result<Option<Severity>> {
    Ok(match level.to_ascii_lowercase().as_str() {
        "high" => Some(Severity::High),
        "medium" => Some(Severity::Medium),
        "low" => Some(Severity::Low),
        "never" => None,
        other => bail!("--fail-on must be high, medium, low or never, not {other}"),
    })
}

/// The files to lint. Each file is read one time, also when two paths reach it.
#[derive(Default)]
struct Walk {
    files: Vec<SourceFile>,
    seen: HashSet<PathBuf>,
}

impl Walk {
    /// Adds `path` (a `.cls` file) or the `.cls` files below `path` (a directory).
    /// Skips hidden directories, `node_modules`, and symbolic links. Bytes
    /// that are not UTF-8 become U+FFFD, as in the `sf` plugin.
    fn collect(&mut self, path: &Path) -> Result<()> {
        let meta = fs::metadata(path).with_context(|| format!("cannot read {}", path.display()))?;
        if meta.is_file() {
            // A file that is not Apex must not count as a scanned file.
            if !path
                .extension()
                .is_some_and(|x| x.eq_ignore_ascii_case("cls"))
            {
                bail!("{} is not a .cls file", path.display());
            }
            let real = fs::canonicalize(path)
                .with_context(|| format!("cannot read {}", path.display()))?;
            if self.seen.insert(real) {
                let bytes =
                    fs::read(path).with_context(|| format!("cannot read {}", path.display()))?;
                self.files.push(SourceFile {
                    path: path.display().to_string(),
                    source: String::from_utf8_lossy(&bytes).into_owned(),
                });
            }
            return Ok(());
        }
        let mut entries: Vec<(PathBuf, fs::FileType)> = fs::read_dir(path)
            .with_context(|| format!("cannot read {}", path.display()))?
            .map(|e| e.and_then(|e| Ok((e.path(), e.file_type()?))))
            .collect::<Result<_, _>>()?;
        entries.sort_by(|a, b| a.0.cmp(&b.0));
        // file_type() does not follow links, so a link loop cannot recurse.
        for (entry, kind) in entries {
            let name = entry
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            if kind.is_dir() {
                if !name.starts_with('.') && name != "node_modules" {
                    self.collect(&entry)?;
                }
            } else if kind.is_file()
                && Path::new(&name)
                    .extension()
                    .is_some_and(|x| x.eq_ignore_ascii_case("cls"))
            {
                self.collect(&entry)?;
            }
        }
        Ok(())
    }
}

fn label(value: &impl serde::Serialize) -> String {
    serde_json::to_value(value)
        .ok()
        .and_then(|v| v.as_str().map(str::to_string))
        .unwrap_or_default()
}

fn human(report: &Report) -> String {
    use std::fmt::Write as _;
    let mut out = String::new();
    for d in &report.defects {
        let tag = d.rule.map_or_else(|| label(&d.code), |r| label(&r));
        let _ = writeln!(
            out,
            "{}:{}:{} {} {tag} {}\n    {}",
            d.file,
            d.position.line,
            d.position.column,
            label(&d.severity),
            d.message,
            d.remedy
        );
    }
    let count = |s: Severity| report.defects.iter().filter(|d| d.severity == s).count();
    let n = report.defects.len();
    let _ = writeln!(
        out,
        "{n} defect{} ({} high, {} medium, {} low). {} files, {} step classes, {} suppressed.",
        if n == 1 { "" } else { "s" },
        count(Severity::High),
        count(Severity::Medium),
        count(Severity::Low),
        report.files_scanned,
        report.step_classes_scanned,
        report.suppressed
    );
    out
}
