//! Invariants from the plan (docs/plans/2026-09-29-determinism-lint.md).

use proptest::prelude::*;
use revenant_lint::lexer::lex;
use revenant_lint::{Severity, SourceFile, lint};

const HAZARDS: &[&str] = &[
    "Datetime.now()",
    "System.now()",
    "System.today()",
    "Date.today()",
    "Math.random()",
    "Crypto.getRandomInteger()",
    "UUID.randomUUID()",
    "UserInfo.getUserId()",
    "System.enqueueJob(q)",
    "Database.executeBatch(b)",
];

fn hazard() -> impl Strategy<Value = &'static str> {
    prop::sample::select(HAZARDS)
}

fn step(body: &str) -> SourceFile {
    SourceFile {
        path: "S.cls".into(),
        source: format!(
            "public class S implements WorkflowStep {{\n\
             public StepResult execute(StepContext ctx) {{\n{body}\nreturn null;\n}}\n}}"
        ),
    }
}

proptest! {
    // 1. The lexer is total. Spans are in order, in bounds, and slice the text.
    #[test]
    fn lexer_is_total(src in any::<String>()) {
        if let Ok(tokens) = lex(&src) {
            let mut last = 0;
            for t in tokens {
                prop_assert!(t.span.start >= last);
                prop_assert!(t.span.end <= src.len());
                prop_assert_eq!(&src[t.span.clone()], t.text);
                last = t.span.end;
            }
        }
    }

    // 1 and 5. The lint is total. Each defect line is in the file.
    #[test]
    fn lint_is_total_and_lines_are_in_the_file(body in any::<String>()) {
        let file = step(&body);
        let lines = u32::try_from(file.source.lines().count()).unwrap_or(u32::MAX);
        let report = lint(std::slice::from_ref(&file));
        for d in &report.defects {
            prop_assert!(d.position.line >= 1 && d.position.line <= lines.max(1));
        }
    }

    // 2. Hazard text in a comment or a string literal adds no defect.
    #[test]
    fn comments_and_strings_add_no_defect(
        h in hazard(),
        pad in "[a-zA-Z0-9 .(),;]{0,20}",
    ) {
        let text = format!("{pad}{h}{pad}");
        let quoted = text.replace('\\', "\\\\").replace('\'', "\\'");
        let body = format!("// {text}\n/* {text} */\nString s = '{quoted}';");
        let report = lint(&[step(&body)]);
        prop_assert!(report.defects.is_empty(), "{:?}", report.defects);
    }

    // 3. A hazard in a CaptureProducer adds no defect. The same call in the
    //    step body adds one HIGH defect.
    #[test]
    fn producer_body_is_safe(h in hazard()) {
        let wrapped = format!(
            "Object v = ctx.captures().once('k', new P());\n}}\n\
             class P implements CaptureProducer {{ public Object produce() {{ return {h}; }} }}\n\
             void unused() {{"
        );
        prop_assert!(lint(&[step(&wrapped)]).defects.is_empty());

        let bare = lint(&[step(&format!("Object v = {h};"))]);
        prop_assert_eq!(bare.defects.len(), 1);
        prop_assert_eq!(bare.defects[0].severity, Severity::High);
    }

    // 4. The file order does not change the report.
    #[test]
    fn file_order_does_not_change_the_report(
        picks in prop::collection::vec(hazard(), 1..6),
        seed in any::<u64>(),
    ) {
        let files: Vec<SourceFile> = picks
            .iter()
            .enumerate()
            .map(|(i, h)| SourceFile {
                path: format!("S{i}.cls"),
                source: format!("public class S{i} implements WorkflowStep {{ void x() {{ {h}; }} }}"),
            })
            .collect();
        let mut shuffled = files.clone();
        let len = shuffled.len();
        let rotate = usize::try_from(seed % len as u64).unwrap_or(0);
        shuffled.rotate_left(rotate);
        shuffled.reverse();
        prop_assert_eq!(lint(&files), lint(&shuffled));
    }
}
