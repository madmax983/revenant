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
    /// Line of the closing `)` or `]`. A call or a query can span lines.
    pub end_line: u32,
}

enum Method {
    Exact(&'static str),
    Prefix(&'static str),
    OneOf(&'static [&'static str]),
}

/// `UserInfo` methods (lower case). A list, so `userInfo.get('k')` on a local
/// map does not match.
const USER_INFO: &[&str] = &[
    "getdefaultcurrency",
    "getfirstname",
    "getlanguage",
    "getlastname",
    "getlocale",
    "getname",
    "getorganizationid",
    "getorganizationname",
    "getprofileid",
    "getsessionid",
    "gettimezone",
    "getuitheme",
    "getuithemedisplayed",
    "getuseremail",
    "getuserid",
    "getusername",
    "getuserroleid",
    "getusertype",
    "haspackagelicense",
    "iscurrentuserlicensed",
    "iscurrentuserlicensedforpermissionset",
    "ismulticurrencyorganization",
];

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
    ("userinfo", Method::OneOf(USER_INFO), Rule::UserContext),
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
    ("database", Method::Prefix("getcursor"), Rule::SoqlRead),
    ("search", Method::Exact("query"), Rule::SoqlRead),
    ("search", Method::Exact("find"), Rule::SoqlRead),
    ("eventbus", Method::Exact("publish"), Rule::EventPublish),
];

/// The hazard that starts at `code[i]`, if any.
#[must_use]
pub fn hazard_at(code: &[Token<'_>], i: usize) -> Option<Hazard> {
    inline_query(code, i).or_else(|| call(code, i))
}

/// `[SELECT` or `[FIND 'text'` / `[FIND :term`. A `FIND` with no search text
/// after it is an index variable (`vals[find]`).
fn inline_query(code: &[Token<'_>], i: usize) -> Option<Hazard> {
    if !code[i].is_punct('[') {
        return None;
    }
    let keyword = code.get(i + 1)?;
    let search_text = || {
        code.get(i + 2)
            .is_some_and(|t| t.kind == TokenKind::Str || t.is_punct(':'))
    };
    (keyword.is_ident("select") || (keyword.is_ident("find") && search_text())).then(|| Hazard {
        rule: Rule::SoqlRead,
        api: format!("[{} ...]", keyword.text),
        pos: code[i].pos,
        end_line: closing_line(code, i, '[', ']'),
    })
}

/// `Qualifier.method(`. A `.` before the qualifier is allowed only in
/// `System.Qualifier`, so `this.userInfo.getName()` does not match. The
/// `System.` prefix is part of the api text and the position.
fn call(code: &[Token<'_>], i: usize) -> Option<Hazard> {
    let [qualifier, dot, method, paren] = code.get(i..i + 4)? else {
        return None;
    };
    if qualifier.kind != TokenKind::Ident
        || !dot.is_punct('.')
        || method.kind != TokenKind::Ident
        || !paren.is_punct('(')
    {
        return None;
    }
    let start = rooted_start(code, i)?;
    let q = qualifier.text.to_ascii_lowercase();
    let m = method.text.to_ascii_lowercase();
    let (_, _, rule) = CALLS.iter().find(|(cq, cm, _)| {
        *cq == q
            && match cm {
                Method::Exact(name) => m == *name,
                Method::Prefix(prefix) => m.starts_with(prefix),
                Method::OneOf(names) => names.contains(&m.as_str()),
            }
    })?;
    let prefix = if start < i { "System." } else { "" };
    Some(Hazard {
        rule: *rule,
        api: format!("{prefix}{}.{}()", qualifier.text, method.text),
        pos: code[start].pos,
        end_line: closing_line(code, i + 3, '(', ')'),
    })
}

/// The index where the qualified name starts: `i`, or `i - 2` for a lone
/// `System.` prefix. None when another `.` comes before the qualifier.
fn rooted_start(code: &[Token<'_>], i: usize) -> Option<usize> {
    if i == 0 || !code[i - 1].is_punct('.') {
        return Some(i);
    }
    (i >= 2 && code[i - 2].is_ident("system") && (i < 3 || !code[i - 3].is_punct('.')))
        .then(|| i - 2)
}

/// Line of the bracket that closes the `open` at `code[start]`. The last
/// token when no bracket closes it.
fn closing_line(code: &[Token<'_>], start: usize, open: char, close: char) -> u32 {
    let mut depth = 0usize;
    for tok in &code[start..] {
        if tok.is_punct(open) {
            depth += 1;
        } else if tok.is_punct(close) {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                return tok.pos.line;
            }
        }
    }
    code.last().map_or(code[start].pos.line, |t| t.pos.line)
}
