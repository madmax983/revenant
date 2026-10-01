//! Lint behavior. One test group for each acceptance criterion of issue #135.

use revenant_lint::{DefectCode, Position, Report, Rule, Severity, SourceFile, lint, lint_json};

fn run(files: &[(&str, &str)]) -> Report {
    let files: Vec<SourceFile> = files
        .iter()
        .map(|(path, source)| SourceFile {
            path: (*path).to_string(),
            source: (*source).to_string(),
        })
        .collect();
    lint(&files)
}

/// (line, rule) of each `NON_DETERMINISTIC_SOURCE` defect.
fn hazards(report: &Report) -> Vec<(u32, Rule)> {
    report
        .defects
        .iter()
        .filter(|d| d.code == DefectCode::NonDeterministicSource)
        .map(|d| (d.position.line, d.rule.expect("hazard has a rule")))
        .collect()
}

fn step(body: &str) -> String {
    format!(
        "public class S implements WorkflowStep {{\n\
         public StepResult execute(StepContext ctx) {{\n{body}\nreturn null;\n}}\n}}"
    )
}

// AC1: the minimum API list, with class and line.

#[test]
fn flags_each_minimum_api_with_class_and_line() {
    let src = step(
        "Datetime a = Datetime.now();\n\
         Datetime b = System.now();\n\
         Date c = System.today();\n\
         Double d = Math.random();\n\
         Integer e = Crypto.getRandomInteger();\n\
         Long f = Crypto.getRandomLong();\n\
         Id g = UserInfo.getUserId();\n\
         String h = UserInfo.getUserName();\n\
         System.enqueueJob(new Q());\n\
         Database.executeBatch(new B(), 200);",
    );
    let report = run(&[("classes/S.cls", &src)]);
    assert_eq!(
        hazards(&report),
        vec![
            (3, Rule::ClockRead),
            (4, Rule::ClockRead),
            (5, Rule::ClockRead),
            (6, Rule::RandomValue),
            (7, Rule::RandomValue),
            (8, Rule::RandomValue),
            (9, Rule::UserContext),
            (10, Rule::UserContext),
            (11, Rule::AsyncEnqueue),
            (12, Rule::AsyncEnqueue),
        ]
    );
    let first = &report.defects[0];
    assert_eq!(first.class_name, "S");
    assert_eq!(first.file, "classes/S.cls");
    assert_eq!(
        first.position,
        Position {
            line: 3,
            column: 14
        }
    );
    assert_eq!(first.api, "Datetime.now()");
    assert_eq!(first.severity, Severity::High);
    assert!(first.message.contains("Datetime.now()"));
    assert!(first.message.contains('S'));
    assert!(first.remedy.contains("once("));
    assert_eq!(report.step_classes_scanned, 1);
}

#[test]
fn flags_the_extra_clock_random_and_async_apis() {
    let src = step(
        "Date a = Date.today();\n\
         Long b = System.currentTimeMillis();\n\
         UUID c = UUID.randomUUID();\n\
         Blob d = Crypto.generateAesKey(128);\n\
         System.schedule('j', '0 0 * * * ?', new J());\n\
         System.scheduleBatch(new B(), 'j', 5);",
    );
    assert_eq!(
        hazards(&run(&[("S.cls", &src)])),
        vec![
            (3, Rule::ClockRead),
            (4, Rule::ClockRead),
            (5, Rule::RandomValue),
            (6, Rule::RandomValue),
            (7, Rule::AsyncEnqueue),
            (8, Rule::AsyncEnqueue),
        ]
    );
}

#[test]
fn matches_names_without_case() {
    let src = step("Datetime a = DATETIME.NOW();\nId u = userinfo.getuserid();");
    assert_eq!(
        hazards(&run(&[("S.cls", &src)])),
        vec![(3, Rule::ClockRead), (4, Rule::UserContext)]
    );
}

#[test]
fn allows_a_system_prefix_but_not_a_member_path() {
    let src = step(
        "Double a = System.Math.random();\n\
         String b = this.userInfo.getName();\n\
         Datetime c = holder.Datetime.now();\n\
         Datetime d = x.System.now();",
    );
    assert_eq!(
        hazards(&run(&[("S.cls", &src)])),
        vec![(3, Rule::RandomValue)]
    );
}

#[test]
fn a_reference_without_a_call_is_not_flagged() {
    let src = step("Object a = Datetime.now;\nString b = 'x'.now();");
    let found = hazards(&run(&[("S.cls", &src)]));
    assert!(found.is_empty(), "{found:?}");
}

#[test]
fn flags_soql_and_sosl_as_medium() {
    let src = step(
        "List<Account> a = [SELECT Id FROM Account];\n\
         List<SObject> b = Database.query(q);\n\
         Integer c = Database.countQuery(q);\n\
         List<List<SObject>> d = [FIND 'x' IN ALL FIELDS];\n\
         Object e = list[0];",
    );
    let report = run(&[("S.cls", &src)]);
    assert_eq!(
        hazards(&report),
        vec![
            (3, Rule::SoqlRead),
            (4, Rule::SoqlRead),
            (5, Rule::SoqlRead),
            (6, Rule::SoqlRead),
        ]
    );
    assert!(
        report
            .defects
            .iter()
            .all(|d| d.severity == Severity::Medium)
    );
    assert!(!report.has_at_least(Severity::High));
    assert!(report.has_at_least(Severity::Medium));
}

#[test]
fn flags_field_initializers_and_compensate() {
    let src = "public class S implements CompensatableStep {\n\
               static final Datetime T = Datetime.now();\n\
               public StepResult execute(StepContext c) { return null; }\n\
               public StepResult compensate(StepContext c) { Id u = UserInfo.getUserId(); return null; }\n\
               }";
    assert_eq!(
        hazards(&run(&[("S.cls", src)])),
        vec![(2, Rule::ClockRead), (4, Rule::UserContext)]
    );
}

// AC2: a call in a CaptureProducer is safe.

#[test]
fn a_call_in_a_nested_producer_is_not_flagged() {
    let src = "public class S implements WorkflowStep {\n\
               public StepResult execute(StepContext ctx) {\n\
               Object t = ctx.captures().once('t', new NowProducer());\n\
               return null;\n\
               }\n\
               class NowProducer implements CaptureProducer {\n\
               public Object produce() { return Datetime.now(); }\n\
               }\n\
               }";
    let report = run(&[("S.cls", src)]);
    assert!(report.defects.is_empty(), "{:?}", report.defects);
}

#[test]
fn a_call_in_a_sibling_or_inherited_producer_is_not_flagged() {
    let wf = "public class Wf implements WorkflowDefinition {\n\
              public List<String> getSteps() { return new List<String>{ 'Wf.S' }; }\n\
              public class S implements WorkflowStep {\n\
              public StepResult execute(StepContext ctx) { return null; }\n\
              class P extends BaseProducer { public Object produce() { return Math.random(); } }\n\
              }\n\
              class Sibling implements rvn.CaptureProducer { public Object produce() { return Datetime.now(); } }\n\
              }";
    let base = "public abstract class BaseProducer implements CaptureProducer {}";
    let report = run(&[("Wf.cls", wf), ("BaseProducer.cls", base)]);
    assert!(report.defects.is_empty(), "{:?}", report.defects);
}

// AC3: comments and string literals.

#[test]
fn text_in_comments_and_strings_is_not_flagged() {
    let src = step(
        "// Datetime.now()\n\
         /* Math.random(); UserInfo.getUserId(); */\n\
         String s = 'System.enqueueJob(x) Datetime.now()';\n\
         String t = 'it\\'s Math.random()';",
    );
    let report = run(&[("S.cls", &src)]);
    assert!(report.defects.is_empty(), "{:?}", report.defects);
}

// AC4: test classes are excluded by name.

#[test]
fn files_of_test_classes_are_excluded() {
    let a = "@IsTest public class OrderStepTest { class S implements WorkflowStep { \
             StepResult execute(StepContext c) { Datetime.now(); return null; } } }";
    let b = "public class Helper_test implements WorkflowStep { \
             StepResult execute(StepContext c) { Datetime.now(); return null; } }";
    let c = "public class TestingStep implements WorkflowStep { \
             StepResult execute(StepContext c) { Datetime.now(); return null; } }";
    let report = run(&[("A.cls", a), ("B.cls", b), ("C.cls", c)]);
    assert_eq!(hazards(&report), vec![(1, Rule::ClockRead)]);
    assert_eq!(report.defects[0].class_name, "TestingStep");
    assert_eq!(report.files_scanned, 3);
}

// Step discovery.

#[test]
fn a_class_that_is_not_a_step_is_not_scanned() {
    let src = "public class Service { Datetime now() { return Datetime.now(); } }";
    let report = run(&[("Service.cls", src)]);
    assert!(report.defects.is_empty(), "{:?}", report.defects);
    assert_eq!(report.step_classes_scanned, 0);
}

#[test]
fn finds_steps_through_base_classes_and_sub_interfaces() {
    let base = "public abstract class BaseStep implements rvn.CompensatableStep {}";
    let iface = "public interface AuditedStep extends WorkflowStep {}";
    let a = "public class A extends BaseStep { \
             public StepResult execute(StepContext c) { Datetime.now(); return null; } }";
    let b = "public class B implements AuditedStep { \
             public StepResult execute(StepContext c) { Math.random(); return null; } }";
    let report = run(&[
        ("BaseStep.cls", base),
        ("AuditedStep.cls", iface),
        ("A.cls", a),
        ("B.cls", b),
    ]);
    let classes: Vec<_> = report
        .defects
        .iter()
        .map(|d| d.class_name.as_str())
        .collect();
    assert_eq!(classes, vec!["A", "B"]);
    assert_eq!(report.step_classes_scanned, 3);
}

#[test]
fn a_supertype_cycle_does_not_hang() {
    let a = "public class A extends B { void x() { Datetime.now(); } }";
    let b = "public class B extends A { }";
    let report = run(&[("A.cls", a), ("B.cls", b)]);
    assert!(report.defects.is_empty(), "{:?}", report.defects);
}

#[test]
fn finds_steps_named_in_get_steps() {
    let wf = "public class OrderWorkflow implements VersionedWorkflow {\n\
              public List<String> getSteps() {\n\
              return new List<String>{ 'acme.Reserve', 'OrderWorkflow.Ship', 'Missing' };\n\
              }\n\
              public class Ship extends PackagedBase { void x() { Math.random(); } }\n\
              }";
    let reserve = "public class Reserve extends PackagedBase { void x() { Datetime.now(); } }";
    let report = run(&[("OrderWorkflow.cls", wf), ("Reserve.cls", reserve)]);
    let found: Vec<_> = report
        .defects
        .iter()
        .map(|d| (d.code, d.class_name.as_str(), d.api.as_str(), d.severity))
        .collect();
    assert_eq!(
        found,
        vec![
            (
                DefectCode::StepSourceNotFound,
                "OrderWorkflow",
                "Missing",
                Severity::Low
            ),
            (
                DefectCode::NonDeterministicSource,
                "OrderWorkflow.Ship",
                "Math.random()",
                Severity::High
            ),
            (
                DefectCode::NonDeterministicSource,
                "Reserve",
                "Datetime.now()",
                Severity::High
            ),
        ]
    );
    assert_eq!(report.defects[0].position.line, 3);
    assert_eq!(report.step_classes_scanned, 2);
}

#[test]
fn a_nested_step_is_reported_once_for_the_inner_class() {
    let src = "public class Outer implements WorkflowStep {\n\
               public StepResult execute(StepContext c) { return null; }\n\
               public class Inner implements WorkflowStep {\n\
               public StepResult execute(StepContext c) { Datetime.now(); return null; }\n\
               }\n\
               }";
    let report = run(&[("Outer.cls", src)]);
    assert_eq!(report.defects.len(), 1);
    assert_eq!(report.defects[0].class_name, "Outer.Inner");
    assert_eq!(report.step_classes_scanned, 2);
}

// AC6: every hazard in one call, in a stable order.

#[test]
fn returns_every_hazard_across_files_in_a_stable_order() {
    let a = step("Math.random();");
    let b = step("Datetime.now(); UserInfo.getUserId();");
    let report = run(&[("b/B.cls", &b), ("a/A.cls", &a)]);
    let found: Vec<_> = report
        .defects
        .iter()
        .map(|d| (d.file.as_str(), d.position.line, d.rule))
        .collect();
    assert_eq!(
        found,
        vec![
            ("a/A.cls", 3, Some(Rule::RandomValue)),
            ("b/B.cls", 3, Some(Rule::ClockRead)),
            ("b/B.cls", 3, Some(Rule::UserContext)),
        ]
    );
}

// Suppression.

#[test]
fn a_suppression_comment_removes_one_finding() {
    let src = step(
        "Datetime a = Datetime.now(); // revenant-lint-disable-line: log time only\n\
         /* revenant-lint-disable-next-line */\n\
         Double b = Math.random();\n\
         Id c = UserInfo.getUserId();",
    );
    let report = run(&[("S.cls", &src)]);
    assert_eq!(hazards(&report), vec![(6, Rule::UserContext)]);
    assert_eq!(report.suppressed, 2);
}

// Fail closed.

#[test]
fn an_unreadable_file_is_a_high_defect() {
    let report = run(&[("Bad.cls", "public class Bad { String s = 'open; }")]);
    assert_eq!(report.defects.len(), 1);
    let d = &report.defects[0];
    assert_eq!(d.code, DefectCode::SourceUnreadable);
    assert_eq!(d.severity, Severity::High);
    assert_eq!(d.file, "Bad.cls");
    assert_eq!(
        d.position,
        Position {
            line: 1,
            column: 31
        }
    );
    assert!(report.has_at_least(Severity::High));
}

// JSON contract.

#[test]
fn json_request_gives_the_stable_report_shape() {
    let request = serde_json::json!({
        "files": [{ "path": "S.cls", "source": step("Datetime.now();") }]
    });
    let out: serde_json::Value =
        serde_json::from_str(&lint_json(&request.to_string())).expect("valid JSON");
    assert_eq!(out["version"], 1);
    assert_eq!(out["filesScanned"], 1);
    assert_eq!(out["stepClassesScanned"], 1);
    assert_eq!(out["suppressed"], 0);
    let d = &out["defects"][0];
    assert_eq!(d["code"], "NON_DETERMINISTIC_SOURCE");
    assert_eq!(d["rule"], "CLOCK_READ");
    assert_eq!(d["severity"], "HIGH");
    assert_eq!(d["className"], "S");
    assert_eq!(d["file"], "S.cls");
    assert_eq!(d["line"], 3);
    assert_eq!(d["column"], 1);
    assert_eq!(d["api"], "Datetime.now()");
}

#[test]
fn json_request_error_is_an_error_object() {
    let out: serde_json::Value = serde_json::from_str(&lint_json("{")).expect("valid JSON");
    assert!(out["error"].as_str().is_some_and(|e| !e.is_empty()));
}

// Review round 1 regressions.

#[test]
fn a_step_that_is_also_a_producer_exempts_only_produce() {
    let src = "public class SelfStep implements WorkflowStep, CaptureProducer {\n\
               public StepResult execute(StepContext ctx) { Datetime t = Datetime.now(); return null; }\n\
               public Object produce() { return Math.random(); }\n\
               }";
    assert_eq!(
        hazards(&run(&[("SelfStep.cls", src)])),
        vec![(2, Rule::ClockRead)]
    );
}

#[test]
fn a_nested_supertype_resolves_in_its_own_outer_class_first() {
    // Only OrderFlow.Base is a step. InvoiceFlow.Impl extends InvoiceFlow.Base.
    let order = "public class OrderFlow { public abstract class Base implements WorkflowStep {} }";
    let invoice = "public class InvoiceFlow {\n\
                   abstract class Base {}\n\
                   class Impl extends Base { void x() { Datetime.now(); } }\n\
                   }";
    let report = run(&[("OrderFlow.cls", order), ("InvoiceFlow.cls", invoice)]);
    assert!(report.defects.is_empty(), "{:?}", report.defects);

    // Flow.Impl extends Flow.Base (a step), not the top-level Base.
    let top = "public virtual class Base {}";
    let flow = "public class Flow {\n\
                abstract class Base implements WorkflowStep {}\n\
                class Impl extends Base { void x() { Datetime.now(); } }\n\
                }";
    assert_eq!(
        hazards(&run(&[("Base.cls", top), ("Flow.cls", flow)])),
        vec![(3, Rule::ClockRead)]
    );
}

#[test]
fn test_files_are_found_by_annotation_or_a_test_suffix_only() {
    let step = |name: &str, annotation: &str| {
        format!(
            "{annotation} public class {name} implements WorkflowStep {{ void x() {{ Datetime.now(); }} }}"
        )
    };
    let latest = step("FetchLatest", "");
    let contest = step("Contest", "");
    let harness = step("StepHarness", "@IsTest(SeeAllData=false)");
    let lower = step("order_test", "");
    let report = run(&[
        ("FetchLatest.cls", &latest),
        ("Contest.cls", &contest),
        ("StepHarness.cls", &harness),
        ("order_test.cls", &lower),
    ]);
    let classes: Vec<_> = report
        .defects
        .iter()
        .map(|d| d.class_name.as_str())
        .collect();
    assert_eq!(classes, vec!["Contest", "FetchLatest"]);
}

#[test]
fn flags_cursors_dynamic_sosl_and_event_publish() {
    let src = step(
        "Database.Cursor c = Database.getCursor(q);\n\
         Object f = Search.find(q);\n\
         EventBus.publish(new Order_Event__e());",
    );
    let report = run(&[("S.cls", &src)]);
    assert_eq!(
        hazards(&report),
        vec![
            (3, Rule::SoqlRead),
            (4, Rule::SoqlRead),
            (5, Rule::EventPublish)
        ]
    );
    assert_eq!(report.defects[2].severity, Severity::High);
    assert!(report.defects[2].remedy.contains("ctx.events().emit("));
}

#[test]
fn a_variable_named_like_a_keyword_or_class_is_not_flagged() {
    let src = step(
        "Integer find = 0;\nObject v = vals[find];\n\
         Map<String, Object> userInfo = new Map<String, Object>();\n\
         Object n = userInfo.get('name');\n\
         Boolean e = userInfo.isEmpty();",
    );
    let found = hazards(&run(&[("S.cls", &src)]));
    assert!(found.is_empty(), "{found:?}");
}

#[test]
fn a_system_prefix_is_part_of_the_api_and_the_position() {
    let src = step("Double a = System.Math.random();");
    let d = &run(&[("S.cls", &src)]).defects[0];
    assert_eq!(d.api, "System.Math.random()");
    assert_eq!(
        d.position,
        Position {
            line: 3,
            column: 12
        }
    );
}

#[test]
fn disable_line_in_a_block_comment_covers_each_of_its_lines() {
    let src = step("/* reviewed:\n revenant-lint-disable-line */ Object d = Datetime.now();");
    let report = run(&[("S.cls", &src)]);
    assert!(report.defects.is_empty(), "{:?}", report.defects);
    assert_eq!(report.suppressed, 1);
}

#[test]
fn a_suppression_on_any_line_of_a_multi_line_call_covers_it() {
    let src = step("Datetime t = Datetime\n  .now(); // revenant-lint-disable-line: log only");
    let report = run(&[("S.cls", &src)]);
    assert!(report.defects.is_empty(), "{:?}", report.defects);
    assert_eq!(report.suppressed, 1);
}

#[test]
fn a_suppression_marker_must_end_at_a_word_boundary() {
    let src = step(
        "Datetime a = Datetime.now(); // revenant-lint-disable-line-please-no\n\
         Datetime b = Datetime.now(); // revenant-lint-disable-lines",
    );
    assert_eq!(
        hazards(&run(&[("S.cls", &src)])),
        vec![(3, Rule::ClockRead), (4, Rule::ClockRead)]
    );
}

#[test]
fn only_produce_is_safe_in_a_producer() {
    // `new P()` runs on each replay. Only produce() runs behind once().
    let src = "public class S implements WorkflowStep {\n\
               public StepResult execute(StepContext ctx) { return null; }\n\
               class P implements CaptureProducer {\n\
               Id jobId = System.enqueueJob(new Q());\n\
               P() { Datetime.now(); }\n\
               public Object produce() { return Math.random(); }\n\
               }\n\
               }";
    let report = run(&[("S.cls", src)]);
    assert_eq!(
        hazards(&report),
        vec![(4, Rule::AsyncEnqueue), (5, Rule::ClockRead)]
    );
    assert!(report.defects.iter().all(|d| d.class_name == "S"));
}

#[test]
fn a_suppression_after_a_multi_line_query_or_call_covers_it() {
    let src = step(
        "List<Account> a = [\n  SELECT Id\n  FROM Account\n]; // revenant-lint-disable-line: config rows\n\
         Id j = System.enqueueJob(\n  new Q()\n); // revenant-lint-disable-line: guarded by step state",
    );
    let report = run(&[("S.cls", &src)]);
    assert!(report.defects.is_empty(), "{:?}", report.defects);
    assert_eq!(report.suppressed, 2);
}
