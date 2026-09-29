//! Native CLI: arguments, directory walk, output, and exit codes.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const HIGH: &str = "public class A implements WorkflowStep { void x() { Datetime.now(); } }";
const MEDIUM: &str =
    "public class B implements WorkflowStep { void x() { Object o = [SELECT Id FROM Account]; } }";

fn project(name: &str, files: &[(&str, &str)]) -> PathBuf {
    let root = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&root);
    for (rel, text) in files {
        let path = root.join(rel);
        fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
        fs::write(path, text).expect("write");
    }
    root
}

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_revenant-lint"))
        .args(args)
        .output()
        .expect("runs")
}

fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

#[test]
fn high_defect_fails_with_exit_1_and_a_location() {
    let root = project("high", &[("classes/A.cls", HIGH)]);
    let out = run(&[root.to_str().expect("utf8")]);
    assert_eq!(out.status.code(), Some(1));
    let text = stdout(&out);
    assert!(text.contains("A.cls:1:"), "{text}");
    assert!(text.contains("HIGH"), "{text}");
    assert!(text.contains("CLOCK_READ"), "{text}");
    assert!(text.contains("once("), "{text}");
}

#[test]
fn fail_on_sets_the_gate_level() {
    let root = project("medium", &[("B.cls", MEDIUM)]);
    let dir = root.to_str().expect("utf8");
    assert_eq!(run(&[dir]).status.code(), Some(0));
    assert_eq!(run(&["--fail-on", "medium", dir]).status.code(), Some(1));
    assert_eq!(run(&["--fail-on", "low", dir]).status.code(), Some(1));
    let high = project("never", &[("A.cls", HIGH)]);
    let high = high.to_str().expect("utf8");
    assert_eq!(run(&["--fail-on", "never", high]).status.code(), Some(0));
}

#[test]
fn json_output_is_the_report() {
    let root = project("json", &[("A.cls", HIGH)]);
    let out = run(&["--json", root.to_str().expect("utf8")]);
    assert_eq!(out.status.code(), Some(1));
    let report: serde_json::Value = serde_json::from_slice(&out.stdout).expect("json");
    assert_eq!(report["defects"][0]["rule"], "CLOCK_READ");
    assert_eq!(report["filesScanned"], 1);
}

#[test]
fn walk_reads_cls_files_and_skips_hidden_and_node_modules() {
    let root = project(
        "walk",
        &[
            ("a/b/A.cls", HIGH),
            ("a/B.CLS", MEDIUM),
            ("a/B.cls-meta.xml", HIGH),
            ("a/C.trigger", HIGH),
            (".sf/X.cls", HIGH),
            ("node_modules/pkg/Y.cls", HIGH),
        ],
    );
    #[cfg(unix)]
    std::os::unix::fs::symlink(root.join("a"), root.join("link")).expect("symlink");
    let out = run(&["--json", root.to_str().expect("utf8")]);
    let report: serde_json::Value = serde_json::from_slice(&out.stdout).expect("json");
    assert_eq!(report["filesScanned"], 2);
    let files: Vec<_> = report["defects"]
        .as_array()
        .expect("defects")
        .iter()
        .map(|d| {
            d["file"]
                .as_str()
                .expect("file")
                .rsplit('/')
                .next()
                .expect("name")
                .to_string()
        })
        .collect();
    assert_eq!(files, vec!["B.CLS", "A.cls"]);
}

#[test]
fn a_file_argument_is_read() {
    let root = project("file", &[("A.cls", HIGH)]);
    let file = root.join("A.cls");
    let out = run(&["--json", file.to_str().expect("utf8")]);
    let report: serde_json::Value = serde_json::from_slice(&out.stdout).expect("json");
    assert_eq!(report["filesScanned"], 1);
}

#[test]
fn clean_source_passes_with_a_summary() {
    let root = project("clean", &[("C.cls", "public class C { }")]);
    let out = run(&[root.to_str().expect("utf8")]);
    assert_eq!(out.status.code(), Some(0));
    assert!(stdout(&out).contains("0 defects"), "{}", stdout(&out));
}

#[test]
fn usage_errors_exit_2() {
    assert_eq!(run(&[]).status.code(), Some(2));
    assert_eq!(run(&["--bogus", "."]).status.code(), Some(2));
    assert_eq!(run(&["--fail-on", "sometimes", "."]).status.code(), Some(2));
    assert_eq!(run(&["--fail-on"]).status.code(), Some(2));
    assert_eq!(run(&["/no/such/dir"]).status.code(), Some(2));
}

#[test]
fn help_exits_0() {
    let out = run(&["--help"]);
    assert_eq!(out.status.code(), Some(0));
    assert!(stdout(&out).contains("--fail-on"));
}

#[test]
fn a_file_that_is_not_utf8_is_still_linted() {
    let root = project("latin1", &[("B.cls", MEDIUM)]);
    let mut bytes = b"public class A implements WorkflowStep { String s = '\xe9'; void x() { Datetime.now(); } }".to_vec();
    bytes.push(b'\n');
    fs::write(root.join("A.cls"), bytes).expect("write");
    let out = run(&["--json", root.to_str().expect("utf8")]);
    assert_eq!(out.status.code(), Some(1));
    let report: serde_json::Value = serde_json::from_slice(&out.stdout).expect("json");
    assert_eq!(report["filesScanned"], 2);
    assert_eq!(report["defects"][0]["rule"], "CLOCK_READ");
}

#[test]
fn a_scan_with_no_cls_files_exits_2() {
    let root = project("empty", &[("readme.txt", "x")]);
    let out = run(&[root.to_str().expect("utf8")]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("No .cls files"));
}

#[test]
fn overlapping_paths_read_each_file_one_time() {
    let root = project("overlap", &[("a/A.cls", HIGH)]);
    let dir = root.to_str().expect("utf8");
    let sub = root.join("a");
    let out = run(&["--json", dir, sub.to_str().expect("utf8"), dir]);
    let report: serde_json::Value = serde_json::from_slice(&out.stdout).expect("json");
    assert_eq!(report["filesScanned"], 1);
    assert_eq!(report["defects"].as_array().expect("defects").len(), 1);
}

#[test]
fn fail_on_accepts_the_equals_form() {
    let root = project("equals", &[("B.cls", MEDIUM)]);
    let dir = root.to_str().expect("utf8");
    assert_eq!(run(&["--fail-on=medium", dir]).status.code(), Some(1));
}

#[test]
fn a_closed_stdout_is_not_a_crash() {
    use std::io::Read as _;
    use std::process::Stdio;
    let files: Vec<(String, &str)> = (0..300).map(|i| (format!("S{i}.cls"), HIGH)).collect();
    let refs: Vec<(&str, &str)> = files.iter().map(|(p, s)| (p.as_str(), *s)).collect();
    let root = project("pipe", &refs);
    let mut child = Command::new(env!("CARGO_BIN_EXE_revenant-lint"))
        .arg(root.to_str().expect("utf8"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawns");
    drop(child.stdout.take());
    let status = child.wait().expect("waits");
    let mut err = String::new();
    child
        .stderr
        .take()
        .expect("stderr")
        .read_to_string(&mut err)
        .expect("reads");
    assert!(!err.contains("panicked"), "{err}");
    assert_ne!(status.code(), Some(101));
}
