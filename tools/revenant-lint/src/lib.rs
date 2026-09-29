//! Deploy-time determinism lint for Revenant workflow steps (issue #135).
//!
//! Finds replay-unsafe API calls in the Apex source of step classes. A call in
//! the body of a `CaptureProducer` class is safe: `once()` replays its value.
//!
//! Scope (v1): the bodies of step classes only. The lint does not follow
//! calls into helper classes. It is a token heuristic, not a type checker.

pub mod lexer;
pub mod project;
pub mod report;
pub mod rules;
pub mod scope;
#[cfg(target_arch = "wasm32")]
mod wasm;

use std::collections::{BTreeSet, HashSet};

use serde::Deserialize;

use crate::lexer::{LexError, Token, lex};
use crate::project::{DeclId, ParsedFile, Project};
pub use crate::report::{Defect, DefectCode, Position, REPORT_VERSION, Report, Rule, Severity};
use crate::rules::{Hazard, hazard_at};
use crate::scope::TypeKind;

/// Suppresses findings on the line of the comment.
pub const DISABLE_LINE: &str = "revenant-lint-disable-line";
/// Suppresses findings on the line after the comment.
pub const DISABLE_NEXT_LINE: &str = "revenant-lint-disable-next-line";

/// One Apex source file.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct SourceFile {
    /// Path to show in the report.
    pub path: String,
    /// File text.
    pub source: String,
}

/// Lints the files as one project. Never fails: each problem is a defect.
#[must_use]
pub fn lint(files: &[SourceFile]) -> Report {
    let (parsed, mut defects) = parse_files(files);
    let project = Project::new(parsed);
    let (steps, mut findings) = find_steps(&project);
    findings.extend(scan_steps(&project, &steps));
    let suppressed = apply_suppressions(&project, findings, &mut defects);
    defects.sort_by(|a, b| {
        (&a.file, a.position, a.code, a.rule, &a.api)
            .cmp(&(&b.file, b.position, b.code, b.rule, &b.api))
    });
    Report {
        version: REPORT_VERSION,
        files_scanned: files.len(),
        step_classes_scanned: steps.len(),
        suppressed,
        defects,
    }
}

/// A finding and the index of its file in [`Project::files`].
type Finding = (usize, Defect);

/// Lexes each file. Drops test files. An unreadable file is a defect.
fn parse_files(files: &[SourceFile]) -> (Vec<ParsedFile<'_>>, Vec<Defect>) {
    let mut parsed = Vec::new();
    let mut defects = Vec::new();
    for file in files {
        match lex(&file.source) {
            Ok(tokens) => {
                let p = ParsedFile::new(&file.path, tokens);
                if !p.is_test_file() {
                    parsed.push(p);
                }
            }
            Err(e) => defects.push(unreadable(&file.path, e)),
        }
    }
    (parsed, defects)
}

/// Step classes: by supertype, and by name in `getSteps()`. A name that is
/// not in the source is a finding.
fn find_steps(project: &Project<'_>) -> (BTreeSet<DeclId>, Vec<Finding>) {
    let mut steps: BTreeSet<DeclId> = project
        .ids()
        .filter(|&id| project.is_step_type(id) && project.decl(id).kind == TypeKind::Class)
        .collect();
    let mut findings = Vec::new();
    for def in project.definition_classes() {
        let mut seen = HashSet::new();
        for lit in project.get_steps_literals(def) {
            let name = unquote(lit.text);
            if name.trim().is_empty() || !seen.insert(name.to_ascii_lowercase()) {
                continue;
            }
            let found = project.resolve_step_name(&name);
            if found.is_empty() {
                findings.push((def.file, not_found(project, def, &name, lit.pos)));
            }
            steps.extend(found);
        }
    }
    (steps, findings)
}

/// Runs the rules on each code token that a step class owns.
fn scan_steps(project: &Project<'_>, steps: &BTreeSet<DeclId>) -> Vec<Finding> {
    let mut findings = Vec::new();
    for (file, parsed) in project.files.iter().enumerate() {
        for (k, owner) in parsed.owner.iter().enumerate() {
            let step = owner.and_then(|d| attributed_step(project, steps, file, d));
            if let Some(step) = step
                && let Some(h) = hazard_at(&parsed.code, k)
            {
                findings.push((file, hazard(project, step, h)));
            }
        }
    }
    findings
}

/// Moves each finding that no comment suppresses into `defects`. Returns the
/// number of suppressed findings.
fn apply_suppressions(
    project: &Project<'_>,
    findings: Vec<Finding>,
    defects: &mut Vec<Defect>,
) -> usize {
    let lines: Vec<HashSet<u32>> = project
        .files
        .iter()
        .map(|f| suppressed_lines(&f.tokens))
        .collect();
    let mut suppressed = 0;
    for (file, defect) in findings {
        if lines[file].contains(&defect.position.line) {
            suppressed += 1;
        } else {
            defects.push(defect);
        }
    }
    suppressed
}

/// Lints a JSON request `{"files":[{"path","source"}]}`. Returns the report
/// JSON, or `{"error": "..."}`.
#[must_use]
pub fn lint_json(request: &str) -> String {
    #[derive(Deserialize)]
    struct Request {
        files: Vec<SourceFile>,
    }
    let result = serde_json::from_str::<Request>(request)
        .map_err(|e| e.to_string())
        .and_then(|r| serde_json::to_string(&lint(&r.files)).map_err(|e| e.to_string()));
    result.unwrap_or_else(|error| serde_json::json!({ "error": error }).to_string())
}

/// The step that owns a token in declaration `decl`: the innermost enclosing
/// step. None when a producer comes first, or no step encloses it.
fn attributed_step(
    project: &Project<'_>,
    steps: &BTreeSet<DeclId>,
    file: usize,
    decl: usize,
) -> Option<DeclId> {
    let mut cur = Some(decl);
    while let Some(d) = cur {
        let id = DeclId { file, decl: d };
        if project.is_producer(id) {
            return None;
        }
        if steps.contains(&id) {
            return Some(id);
        }
        cur = project.decl(id).parent;
    }
    None
}

fn hazard(project: &Project<'_>, step: DeclId, h: Hazard) -> Defect {
    let class_name = project.decl(step).qualified.clone();
    let effect = match h.rule {
        Rule::ClockRead => "gives a new time",
        Rule::RandomValue => "gives a new value",
        Rule::UserContext => "can give a different user",
        Rule::AsyncEnqueue => "starts the job again",
        Rule::SoqlRead => "can read changed rows",
    };
    Defect {
        code: DefectCode::NonDeterministicSource,
        rule: Some(h.rule),
        severity: h.rule.severity(),
        message: format!(
            "{} in step class {class_name} {effect} when the step runs again.",
            h.api
        ),
        remedy: h.rule.remedy().to_string(),
        class_name,
        file: project.files[step.file].path.to_string(),
        position: h.pos,
        api: h.api,
    }
}

fn not_found(project: &Project<'_>, def: DeclId, name: &str, pos: Position) -> Defect {
    let class_name = project.decl(def).qualified.clone();
    Defect {
        code: DefectCode::StepSourceNotFound,
        rule: None,
        severity: Severity::Low,
        message: format!(
            "getSteps() of {class_name} names \"{name}\". Its source is not in the scan, so the lint did not scan it."
        ),
        remedy: "Add the source directory of the step to the scan.".to_string(),
        class_name,
        file: project.files[def.file].path.to_string(),
        position: pos,
        api: name.to_string(),
    }
}

fn unreadable(path: &str, e: LexError) -> Defect {
    let position = match e {
        LexError::UnterminatedString(p) | LexError::UnterminatedComment(p) => p,
    };
    Defect {
        code: DefectCode::SourceUnreadable,
        rule: None,
        severity: Severity::High,
        class_name: String::new(),
        file: path.to_string(),
        position,
        api: String::new(),
        message: format!("The {e}. The lint did not scan this file."),
        remedy: "Correct the syntax error.".to_string(),
    }
}

/// Lines that a suppression comment covers.
fn suppressed_lines(tokens: &[Token<'_>]) -> HashSet<u32> {
    let mut lines = HashSet::new();
    for t in tokens.iter().filter(|t| t.is_comment()) {
        if t.text.contains(DISABLE_NEXT_LINE) {
            let newlines = u32::try_from(t.text.matches('\n').count()).unwrap_or(u32::MAX);
            lines.insert(t.pos.line.saturating_add(newlines).saturating_add(1));
        } else if t.text.contains(DISABLE_LINE) {
            lines.insert(t.pos.line);
        }
    }
    lines
}

/// The value of a string literal token.
fn unquote(text: &str) -> String {
    let inner = text
        .get(1..text.len().saturating_sub(1))
        .unwrap_or_default();
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(next) = chars.next() {
                out.push(next);
            }
        } else {
            out.push(c);
        }
    }
    out
}
