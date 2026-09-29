//! Seed corpus (issue #135 success metric). Each `// expect: <RULE or CODE>`
//! comment marks one finding on its line. The lint must report each marked
//! finding and no other finding: zero false negatives, zero false positives.

use std::collections::BTreeSet;
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

    let mut expected = BTreeSet::new();
    for f in &files {
        for (i, line) in f.source.lines().enumerate() {
            if let Some((_, tag)) = line.split_once("// expect: ") {
                expected.insert((f.path.clone(), i + 1, tag.trim().to_string()));
            }
        }
    }

    let report = lint(&files);
    let actual: BTreeSet<_> = report
        .defects
        .iter()
        .map(|d| {
            let tag = d.rule.map_or_else(|| label(&d.code), |r| label(&r));
            (d.file.clone(), d.position.line as usize, tag)
        })
        .collect();

    let missed: Vec<_> = expected.difference(&actual).collect();
    let extra: Vec<_> = actual.difference(&expected).collect();
    assert!(missed.is_empty(), "false negatives: {missed:#?}");
    assert!(extra.is_empty(), "false positives: {extra:#?}");
    assert_eq!(report.suppressed, 2);
}

#[test]
fn corpus_lints_fast() {
    // Issue #135: under 2 s for a 50-step definition. Lint the corpus 10 times.
    let files = load_corpus();
    let start = std::time::Instant::now();
    for _ in 0..10 {
        let _ = lint(&files);
    }
    assert!(start.elapsed().as_secs_f64() < 2.0);
}
