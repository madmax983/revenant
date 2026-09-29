//! Invariants from the plan (docs/plans/2026-09-29-determinism-lint.md).

use proptest::prelude::*;
use revenant_lint::lexer::lex;
use revenant_lint::{DefectCode, Severity, SourceFile, lint};

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
    "EventBus.publish(e)",
];

/// Apex-like fragments, so the generator makes real tokens, not only noise.
const FRAGMENTS: &[&str] = &[
    "class ",
    "implements ",
    "WorkflowStep ",
    "{",
    "}",
    "(",
    ")",
    ";",
    ".",
    "x",
    "Datetime",
    "now",
    "'s'",
    "'it\\'s'",
    "// c\n",
    "/* c */",
    "\n",
    "\r\n",
    "\r",
    "\t",
    "é",
    "\u{feff}",
    "[SELECT Id FROM A]",
    "@IsTest ",
    "1.5",
    " ",
];

fn hazard() -> impl Strategy<Value = &'static str> {
    prop::sample::select(HAZARDS)
}

fn apex_like() -> impl Strategy<Value = String> {
    prop::collection::vec(prop::sample::select(FRAGMENTS), 0..60).prop_map(|v| v.concat())
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

/// Line and column of a byte offset, as the lexer counts them.
fn position_of(src: &str, offset: usize) -> (u32, u32) {
    let before = src[..offset]
        .strip_prefix('\u{feff}')
        .unwrap_or(&src[..offset]);
    let (mut line, mut column) = (1u32, 1u32);
    let mut chars = before.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\n' || (c == '\r' && chars.peek() != Some(&'\n')) {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    (line, column)
}

proptest! {
    // 1. The lexer is total. Spans are in order, in bounds, slice the text,
    //    and each position agrees with its span.
    #[test]
    fn lexer_is_total(src in prop_oneof![any::<String>(), apex_like()]) {
        if let Ok(tokens) = lex(&src) {
            let mut last = 0;
            for t in tokens {
                prop_assert!(t.span.start >= last);
                prop_assert!(t.span.end <= src.len());
                prop_assert_eq!(&src[t.span.clone()], t.text);
                let (line, column) = position_of(&src, t.span.start);
                prop_assert_eq!((t.pos.line, t.pos.column), (line, column));
                last = t.span.end;
            }
        }
    }

    // 1 and 5. The lint is total. Each hazard defect points at a line that
    //    holds its api (the api can continue on the next lines).
    #[test]
    fn lint_is_total_and_defects_point_at_the_api(
        body in apex_like(),
        h in hazard(),
        crlf in any::<bool>(),
    ) {
        let text = format!("{body}\nObject v = {h};");
        let file = step(&text);
        let file = SourceFile {
            source: if crlf { file.source.replace('\n', "\r\n") } else { file.source },
            ..file
        };
        let report = lint(std::slice::from_ref(&file));
        // Split as the lexer does: `\r\n`, `\n` and a lone `\r` end a line.
        let lines: Vec<&str> = file.source.split("\r\n").flat_map(|l| l.split(['\n', '\r'])).collect();
        for d in report.defects.iter().filter(|d| d.code == DefectCode::NonDeterministicSource) {
            let line = lines.get(d.position.line as usize - 1).copied().unwrap_or_default();
            let qualifier = d.api.split('.').next().unwrap_or_default();
            prop_assert!(line.contains(qualifier.trim_start_matches('[')), "{d:?} on {line:?}");
        }
    }

    // 2. Hazard text in a comment or a string literal adds no defect.
    #[test]
    fn comments_and_strings_add_no_defect(
        h in hazard(),
        pad in "[a-zA-Z0-9 .(),;'\\\\*/]{0,20}",
    ) {
        let text = format!("{pad}{h}{pad}");
        let quoted = text.replace('\\', "\\\\").replace('\'', "\\'");
        let commented = text.replace("*/", "* /");
        let line = text.replace('\n', " ");
        let body = format!("// {line}\n/* {commented} */\nString s = '{quoted}';");
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

    // 4. The file order does not change the report, also with base classes,
    //    producers and getSteps() across files.
    #[test]
    fn file_order_does_not_change_the_report(
        files in Just(project_files()).prop_shuffle(),
    ) {
        prop_assert_eq!(lint(&files), lint(&project_files()));
    }
}

fn project_files() -> Vec<SourceFile> {
    let f = |path: &str, source: &str| SourceFile {
        path: path.into(),
        source: source.into(),
    };
    vec![
        f(
            "Base.cls",
            "public abstract class Base implements WorkflowStep {}",
        ),
        f(
            "A.cls",
            "public class A extends Base { void x() { Datetime.now(); } }",
        ),
        f(
            "B.cls",
            "public class B extends A { void x() { Math.random(); } }",
        ),
        f(
            "P.cls",
            "public abstract class P implements CaptureProducer {}",
        ),
        f(
            "C.cls",
            "public class C extends Base { class Q extends P { Object produce() { return UserInfo.getUserId(); } } }",
        ),
        f(
            "Wf.cls",
            "public class Wf implements WorkflowDefinition { List<String> getSteps() { return new List<String>{ 'D', 'Gone' }; } }",
        ),
        f(
            "D.cls",
            "public class D extends vendor.Step { void x() { System.enqueueJob(q); } }",
        ),
    ]
}
