//! Seed corpus (issue #135 success metric). Each `// expect: <RULE or CODE>`
//! comment marks one finding on its line. The lint must report each marked
//! finding and no other finding: zero false negatives, zero false positives.

use std::fs;
use std::path::Path;

use revenant_lint::{SourceFile, lint};

fn load_corpus() -> Vec<SourceFile> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/corpus");
    let mut files: Vec<SourceFile> = fs::read_dir(dir)
        .expect("corpus dir")
        .map(|e| e.expect("dir entry").path())
        .filter(|p| p.extension().is_some_and(|x| x == "cls"))
        .map(|p| SourceFile {
            path: p.file_name().expect("name").to_string_lossy().into_owned(),
            source: fs::read_to_string(&p).expect("read"),
        })
        .collect();
    files.sort_by(|a, b| a.path.cmp(&b.path));
    files
}

fn label(value: &impl serde::Serialize) -> String {
    serde_json::to_value(value)
        .expect("serializes")
        .as_str()
        .expect("string enum")
        .to_string()
}

#[test]
fn corpus_findings_match_the_expect_markers() {
    let files = load_corpus();
    assert!(files.len() >= 10, "corpus is too small");

    // Sorted lists, not sets: a duplicate finding must show as a difference.
    let mut expected = Vec::new();
    for f in &files {
        for (i, line) in f.source.lines().enumerate() {
            if let Some((_, tag)) = line.split_once("// expect: ") {
                expected.push((f.path.clone(), i + 1, tag.trim().to_string()));
            }
        }
    }
    expected.sort();

    let report = lint(&files);
    let mut actual: Vec<_> = report
        .defects
        .iter()
        .map(|d| {
            let tag = d.rule.map_or_else(|| label(&d.code), |r| label(&r));
            (d.file.clone(), d.position.line as usize, tag)
        })
        .collect();
    actual.sort();
    assert_eq!(
        actual, expected,
        "left: actual findings, right: expect markers"
    );
    assert_eq!(report.suppressed, 2);
}

#[test]
fn a_50_step_definition_lints_in_under_2_seconds() {
    // Issue #135 success metric. Each step has 200 lines and one hazard.
    let steps: Vec<String> = (0..50).map(|i| format!("'Step{i}'")).collect();
    let mut files = vec![SourceFile {
        path: "Wf.cls".into(),
        source: format!(
            "public class Wf implements WorkflowDefinition {{\n\
             public List<String> getSteps() {{ return new List<String>{{ {} }}; }}\n}}",
            steps.join(", ")
        ),
    }];
    for i in 0..50 {
        files.push(SourceFile {
            path: format!("Step{i}.cls"),
            source: format!(
                "public class Step{i} extends PackagedBase {{\n\
                 public StepResult execute(StepContext ctx) {{\n{}Datetime.now();\nreturn null;\n}}\n}}",
                "Integer x = 1; // filler\n".repeat(200)
            ),
        });
    }
    let start = std::time::Instant::now();
    let report = lint(&files);
    assert!(start.elapsed().as_secs_f64() < 2.0);
    assert_eq!(report.step_classes_scanned, 50);
    assert_eq!(report.defects.len(), 50);
}
