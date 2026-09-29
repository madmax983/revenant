//! Lexer contract.

use revenant_lint::Position;
use revenant_lint::lexer::{LexError, TokenKind, lex};

fn kinds(src: &str) -> Vec<(TokenKind, String)> {
    lex(src)
        .expect("lexes")
        .into_iter()
        .map(|t| (t.kind, t.text.to_string()))
        .collect()
}

#[test]
fn splits_a_call_into_tokens() {
    assert_eq!(
        kinds("Datetime.now();"),
        vec![
            (TokenKind::Ident, "Datetime".into()),
            (TokenKind::Punct, ".".into()),
            (TokenKind::Ident, "now".into()),
            (TokenKind::Punct, "(".into()),
            (TokenKind::Punct, ")".into()),
            (TokenKind::Punct, ";".into()),
        ]
    );
}

#[test]
fn comments_and_strings_are_single_tokens() {
    let src = "a // Datetime.now()\n/* Math.random() */ 'UserInfo.getName()'";
    assert_eq!(
        kinds(src),
        vec![
            (TokenKind::Ident, "a".into()),
            (TokenKind::LineComment, "// Datetime.now()".into()),
            (TokenKind::BlockComment, "/* Math.random() */".into()),
            (TokenKind::Str, "'UserInfo.getName()'".into()),
        ]
    );
}

#[test]
fn escaped_quote_does_not_end_the_string() {
    let toks = kinds(r"x = 'it\'s \\' + y;");
    assert!(toks.contains(&(TokenKind::Str, r"'it\'s \\'".into())));
    assert!(toks.contains(&(TokenKind::Ident, "y".into())));
}

#[test]
fn numbers_are_one_token() {
    assert_eq!(
        kinds("1.5 42L"),
        vec![
            (TokenKind::Number, "1.5".into()),
            (TokenKind::Number, "42L".into()),
        ]
    );
}

#[test]
fn positions_count_lines_and_chars() {
    let toks = lex("/* é */\n  foo").expect("lexes");
    assert_eq!(toks[1].pos, Position { line: 2, column: 3 });
    let toks = lex("'é' bar").expect("lexes");
    assert_eq!(toks[1].pos, Position { line: 1, column: 5 });
}

#[test]
fn block_comment_lines_advance_the_line_count() {
    let toks = lex("/*\n\n*/ x").expect("lexes");
    assert_eq!(toks[1].pos, Position { line: 3, column: 4 });
}

#[test]
fn open_string_is_an_error() {
    assert_eq!(
        lex("x = 'abc\n';"),
        Err(LexError::UnterminatedString(Position {
            line: 1,
            column: 5
        }))
    );
    assert!(matches!(lex("'abc"), Err(LexError::UnterminatedString(_))));
}

#[test]
fn open_block_comment_is_an_error() {
    assert_eq!(
        lex("x /* abc"),
        Err(LexError::UnterminatedComment(Position {
            line: 1,
            column: 3
        }))
    );
}

#[test]
fn spans_slice_the_source() {
    let src = "public class A { }";
    for t in lex(src).expect("lexes") {
        assert_eq!(&src[t.span.clone()], t.text);
    }
}

#[test]
fn a_lone_carriage_return_ends_a_line() {
    let toks = lex("a\rb\r\nc").expect("lexes");
    let lines: Vec<_> = toks.iter().map(|t| t.pos.line).collect();
    assert_eq!(lines, vec![1, 2, 3]);
}

#[test]
fn a_byte_order_mark_does_not_move_columns() {
    let toks = lex("\u{feff}class A").expect("lexes");
    assert_eq!(toks[0].text, "class");
    assert_eq!(toks[0].pos, Position { line: 1, column: 1 });
}
