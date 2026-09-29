//! Declaration scopes.

use revenant_lint::lexer::{Token, lex};
use revenant_lint::scope::{TypeKind, declarations};

fn code(src: &str) -> Vec<Token<'_>> {
    lex(src)
        .expect("lexes")
        .into_iter()
        .filter(|t| {
            !matches!(
                t.kind,
                revenant_lint::lexer::TokenKind::LineComment
                    | revenant_lint::lexer::TokenKind::BlockComment
            )
        })
        .collect()
}

#[test]
fn finds_nested_classes_with_supertypes() {
    let src = "public class Outer implements WorkflowDefinition {\n\
               public class Step extends Base implements rvn.WorkflowStep, Database.Batchable<SObject> { void x() {} }\n\
               interface Marker extends A, B {}\n\
               enum Color { RED, GREEN }\n\
               }";
    let toks = code(src);
    let decls = declarations(&toks);
    let names: Vec<_> = decls.iter().map(|d| d.qualified.as_str()).collect();
    assert_eq!(
        names,
        vec!["Outer", "Outer.Step", "Outer.Marker", "Outer.Color"]
    );
    assert_eq!(decls[0].supertypes, vec!["WorkflowDefinition"]);
    assert_eq!(
        decls[1].supertypes,
        vec!["Base", "rvn.WorkflowStep", "Database.Batchable"]
    );
    assert_eq!(decls[1].parent, Some(0));
    assert_eq!(decls[1].pos.line, 2);
    assert_eq!(decls[2].kind, TypeKind::Interface);
    assert_eq!(decls[2].supertypes, vec!["A", "B"]);
    assert_eq!(decls[3].kind, TypeKind::Enum);
}

#[test]
fn body_range_is_between_the_braces() {
    let src = "class A { x(); }";
    let toks = code(src);
    let decls = declarations(&toks);
    let body: Vec<_> = toks[decls[0].body.clone()].iter().map(|t| t.text).collect();
    assert_eq!(body, vec!["x", "(", ")", ";"]);
}

#[test]
fn class_literal_is_not_a_declaration() {
    let src = "class A { Type t = Account.class; String n = B.class.getName(); }";
    let toks = code(src);
    let decls = declarations(&toks);
    assert_eq!(decls.len(), 1);
    assert_eq!(decls[0].body.end, toks.len() - 1);
}

#[test]
fn keywords_match_without_case() {
    let src = "PUBLIC CLASS A IMPLEMENTS WorkflowStep { }";
    let decls = declarations(&code(src));
    assert_eq!(decls[0].name, "A");
    assert_eq!(decls[0].supertypes, vec!["WorkflowStep"]);
}

#[test]
fn open_body_ends_at_the_last_token() {
    let src = "class A { class B { x";
    let toks = code(src);
    let decls = declarations(&toks);
    assert_eq!(decls.len(), 2);
    assert_eq!(decls[0].body.end, toks.len());
    assert_eq!(decls[1].body.end, toks.len());
}
