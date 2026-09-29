//! Hazard rules. Each rule matches a short code-token pattern.

use crate::lexer::{Token, TokenKind};
use crate::report::{Position, Rule};

/// One match of a rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hazard {
    /// The rule.
    pub rule: Rule,
    /// The call, as written (`Datetime.now()`).
    pub api: String,
    /// Position of the first token.
    pub pos: Position,
}

enum Method {
    Exact(&'static str),
    Prefix(&'static str),
    Any,
}

/// `Qualifier.method(` calls. Names are lower case.
const CALLS: &[(&str, Method, Rule)] = &[
    ("datetime", Method::Exact("now"), Rule::ClockRead),
    ("system", Method::Exact("now"), Rule::ClockRead),
    ("system", Method::Exact("today"), Rule::ClockRead),
    ("date", Method::Exact("today"), Rule::ClockRead),
    (
        "system",
        Method::Exact("currenttimemillis"),
        Rule::ClockRead,
    ),
    ("math", Method::Exact("random"), Rule::RandomValue),
    ("crypto", Method::Prefix("getrandom"), Rule::RandomValue),
    ("crypto", Method::Exact("generateaeskey"), Rule::RandomValue),
    ("uuid", Method::Exact("randomuuid"), Rule::RandomValue),
    ("userinfo", Method::Any, Rule::UserContext),
    ("system", Method::Exact("enqueuejob"), Rule::AsyncEnqueue),
    ("system", Method::Exact("schedule"), Rule::AsyncEnqueue),
    ("system", Method::Exact("schedulebatch"), Rule::AsyncEnqueue),
    (
        "database",
        Method::Exact("executebatch"),
        Rule::AsyncEnqueue,
    ),
    ("database", Method::Prefix("query"), Rule::SoqlRead),
    ("database", Method::Prefix("countquery"), Rule::SoqlRead),
    (
        "database",
        Method::Prefix("getquerylocator"),
        Rule::SoqlRead,
    ),
    ("search", Method::Exact("query"), Rule::SoqlRead),
];

/// The hazard that starts at `code[i]`, if any.
#[must_use]
pub fn hazard_at(code: &[Token<'_>], i: usize) -> Option<Hazard> {
    inline_query(code, i).or_else(|| call(code, i))
}

/// `[SELECT` or `[FIND`.
fn inline_query(code: &[Token<'_>], i: usize) -> Option<Hazard> {
    if !code[i].is_punct('[') {
        return None;
    }
    let keyword = code.get(i + 1)?;
    (keyword.is_ident("select") || keyword.is_ident("find")).then(|| Hazard {
        rule: Rule::SoqlRead,
        api: format!("[{} ...]", keyword.text),
        pos: code[i].pos,
    })
}

/// `Qualifier.method(`. A `.` before the qualifier is allowed only in
/// `System.Qualifier`, so `this.userInfo.getName()` does not match.
fn call(code: &[Token<'_>], i: usize) -> Option<Hazard> {
    let [qualifier, dot, method, paren] = code.get(i..i + 4)? else {
        return None;
    };
    if qualifier.kind != TokenKind::Ident
        || !dot.is_punct('.')
        || method.kind != TokenKind::Ident
        || !paren.is_punct('(')
        || !qualifier_is_rooted(code, i)
    {
        return None;
    }
    let q = qualifier.text.to_ascii_lowercase();
    let m = method.text.to_ascii_lowercase();
    CALLS
        .iter()
        .find(|(cq, cm, _)| {
            *cq == q
                && match cm {
                    Method::Exact(name) => m == *name,
                    Method::Prefix(prefix) => m.starts_with(prefix),
                    Method::Any => true,
                }
        })
        .map(|&(_, _, rule)| Hazard {
            rule,
            api: format!("{}.{}()", qualifier.text, method.text),
            pos: qualifier.pos,
        })
}

/// True when no `.` comes before `code[i]`, or the prefix is a lone `System.`.
fn qualifier_is_rooted(code: &[Token<'_>], i: usize) -> bool {
    if i == 0 || !code[i - 1].is_punct('.') {
        return true;
    }
    i >= 2 && code[i - 2].is_ident("system") && (i < 3 || !code[i - 3].is_punct('.'))
}
