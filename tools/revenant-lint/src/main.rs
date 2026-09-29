//! `revenant-lint`: native CLI for the determinism lint.
//!
//! Exit codes: 0 pass, 1 a defect at or above `--fail-on`, 2 usage or I/O error.

use std::fs;
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

Exit codes: 0 pass, 1 gate failed, 2 usage or I/O error.";

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
    let mut files = Vec::new();
    for path in &args.paths {
        collect(path, &mut files)?;
    }
    let report = lint(&files);
    if args.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        print!("{}", human(&report));
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

/// Adds `path` (a `.cls` file) or the `.cls` files below `path` (a directory).
/// Skips hidden directories, `node_modules`, and symbolic links.
fn collect(path: &Path, out: &mut Vec<SourceFile>) -> Result<()> {
    let meta = fs::metadata(path).with_context(|| format!("cannot read {}", path.display()))?;
    if meta.is_file() {
        let source =
            fs::read_to_string(path).with_context(|| format!("cannot read {}", path.display()))?;
        out.push(SourceFile {
            path: path.display().to_string(),
            source,
        });
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
                collect(&entry, out)?;
            }
        } else if kind.is_file()
            && Path::new(&name)
                .extension()
                .is_some_and(|x| x.eq_ignore_ascii_case("cls"))
        {
            collect(&entry, out)?;
        }
    }
    Ok(())
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
