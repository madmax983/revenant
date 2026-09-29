//! Type declarations and their body ranges, from code tokens.

use std::ops::Range;

use crate::lexer::{Token, TokenKind};
use crate::report::Position;

/// Declaration keyword.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TypeKind {
    /// `class`.
    Class,
    /// `interface`.
    Interface,
    /// `enum`.
    Enum,
}

/// One type declaration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TypeDecl {
    /// Declaration keyword.
    pub kind: TypeKind,
    /// Simple name.
    pub name: String,
    /// `Outer.Inner` name.
    pub qualified: String,
    /// `extends` and `implements` names, as written.
    pub supertypes: Vec<String>,
    /// Annotation names before the declaration, without `@` (`IsTest`).
    pub annotations: Vec<String>,
    /// Position of the name.
    pub pos: Position,
    /// Code-token indices between the braces of the body.
    pub body: Range<usize>,
    /// Index of the enclosing declaration.
    pub parent: Option<usize>,
}

/// Finds all type declarations in code tokens (no comments), outer first.
///
/// A body with no closing brace ends at the last token.
#[must_use]
pub fn declarations(code: &[Token<'_>]) -> Vec<TypeDecl> {
    let mut decls: Vec<TypeDecl> = Vec::new();
    // (declaration index, brace depth inside its body)
    let mut open: Vec<(usize, usize)> = Vec::new();
    let mut depth = 0usize;
    // Annotations since the last `;`, `{` or `}`. A declaration takes them.
    let mut pending: Vec<String> = Vec::new();
    let mut i = 0;
    while i < code.len() {
        let tok = &code[i];
        if tok.is_punct('@')
            && let Some(name) = code.get(i + 1).filter(|t| t.kind == TokenKind::Ident)
        {
            pending.push(name.text.to_string());
            i = skip_parens(code, i + 2);
            continue;
        }
        if let Some(kind) = declaration_kind(code, i)
            && let Some((header, brace)) = parse_header(code, i + 1)
        {
            let name = code[i + 1].text.to_string();
            let parent = open.last().map(|&(idx, _)| idx);
            let qualified = parent.map_or_else(
                || name.clone(),
                |p| format!("{}.{name}", decls[p].qualified),
            );
            decls.push(TypeDecl {
                kind,
                name,
                qualified,
                supertypes: header,
                annotations: std::mem::take(&mut pending),
                pos: code[i + 1].pos,
                body: brace + 1..code.len(),
                parent,
            });
            depth += 1;
            open.push((decls.len() - 1, depth));
            i = brace + 1;
            continue;
        }
        if tok.is_punct('{') || tok.is_punct('}') || tok.is_punct(';') {
            pending.clear();
        }
        if tok.is_punct('{') {
            depth += 1;
        } else if tok.is_punct('}') {
            if let Some(&(idx, d)) = open.last()
                && d == depth
            {
                decls[idx].body.end = i;
                open.pop();
            }
            depth = depth.saturating_sub(1);
        }
        i += 1;
    }
    decls
}

/// The index after a `( ... )` group at `code[i]`, or `i` when no group starts there.
fn skip_parens(code: &[Token<'_>], i: usize) -> usize {
    if !code.get(i).is_some_and(|t| t.is_punct('(')) {
        return i;
    }
    let mut depth = 0usize;
    for (j, t) in code.iter().enumerate().skip(i) {
        if t.is_punct('(') {
            depth += 1;
        } else if t.is_punct(')') {
            depth -= 1;
            if depth == 0 {
                return j + 1;
            }
        }
    }
    code.len()
}

/// The kind when `code[i]` starts a declaration: a keyword that no `.`
/// comes before, and a name after it.
fn declaration_kind(code: &[Token<'_>], i: usize) -> Option<TypeKind> {
    let tok = &code[i];
    if tok.kind != TokenKind::Ident {
        return None;
    }
    let kind = if tok.is_ident("class") {
        TypeKind::Class
    } else if tok.is_ident("interface") {
        TypeKind::Interface
    } else if tok.is_ident("enum") {
        TypeKind::Enum
    } else {
        return None;
    };
    let after_dot = i > 0 && code[i - 1].is_punct('.');
    let named = code.get(i + 1).is_some_and(|t| t.kind == TokenKind::Ident);
    (!after_dot && named).then_some(kind)
}

/// Reads the header after the name, up to `{`. Returns the supertype names
/// and the index of `{`. None when a `;` or the end comes first.
fn parse_header(code: &[Token<'_>], name: usize) -> Option<(Vec<String>, usize)> {
    let mut supertypes = Vec::new();
    let mut in_list = false;
    let mut angle = 0usize;
    let mut j = name + 1;
    while j < code.len() {
        let t = &code[j];
        if t.is_punct('{') && angle == 0 {
            return Some((supertypes, j));
        }
        if t.is_punct(';') {
            return None;
        }
        if t.is_punct('<') {
            angle += 1;
        } else if t.is_punct('>') {
            angle = angle.saturating_sub(1);
        } else if angle == 0 && (t.is_ident("extends") || t.is_ident("implements")) {
            in_list = true;
        } else if angle == 0 && in_list && t.kind == TokenKind::Ident {
            let start_of_name = !code[j - 1].is_punct('.');
            if start_of_name {
                supertypes.push(t.text.to_string());
            } else if let Some(last) = supertypes.last_mut() {
                last.push('.');
                last.push_str(t.text);
            }
        }
        j += 1;
    }
    None
}
