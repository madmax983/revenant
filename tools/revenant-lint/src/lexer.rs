//! Apex lexer. Comments and string literals are their own tokens, so the rules
//! never match text in them.

use std::ops::Range;

use crate::report::Position;

/// Token class.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenKind {
    /// Identifier or keyword.
    Ident,
    /// Numeric literal.
    Number,
    /// String literal, quotes included.
    Str,
    /// `// ...` comment.
    LineComment,
    /// `/* ... */` comment.
    BlockComment,
    /// One other `char`.
    Punct,
}

/// One token. `text` is a slice of the source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token<'a> {
    /// Token class.
    pub kind: TokenKind,
    /// Source text of the token.
    pub text: &'a str,
    /// Start position.
    pub pos: Position,
    /// Byte span in the source.
    pub span: Range<usize>,
}

impl Token<'_> {
    /// True for the punctuation `c`.
    #[must_use]
    pub fn is_punct(&self, c: char) -> bool {
        self.kind == TokenKind::Punct && self.text.starts_with(c)
    }

    /// True for the identifier `name`, without case (Apex is case-insensitive).
    #[must_use]
    pub fn is_ident(&self, name: &str) -> bool {
        self.kind == TokenKind::Ident && self.text.eq_ignore_ascii_case(name)
    }

    /// True for a comment.
    #[must_use]
    pub const fn is_comment(&self) -> bool {
        matches!(self.kind, TokenKind::LineComment | TokenKind::BlockComment)
    }
}

/// The source is not valid Apex at the token level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum LexError {
    /// A string literal has no closing quote on its line.
    #[error("string literal at line {}, column {} has no closing quote", .0.line, .0.column)]
    UnterminatedString(Position),
    /// A block comment has no `*/`.
    #[error("block comment at line {}, column {} has no closing */", .0.line, .0.column)]
    UnterminatedComment(Position),
}

/// Splits Apex source into tokens. Skips white space.
///
/// # Errors
/// Returns [`LexError`] for an open string literal or block comment.
pub fn lex(src: &str) -> Result<Vec<Token<'_>>, LexError> {
    let mut cur = Cursor::new(src);
    let mut tokens = Vec::new();
    while let Some(c) = cur.peek() {
        if c.is_whitespace() {
            cur.bump();
            continue;
        }
        let start = cur.offset;
        let pos = cur.pos();
        let kind = match c {
            '/' if cur.peek_second() == Some('/') => {
                cur.bump_while(|c| c != '\n');
                TokenKind::LineComment
            }
            '/' if cur.peek_second() == Some('*') => {
                cur.bump();
                cur.bump();
                if !cur.bump_past("*/") {
                    return Err(LexError::UnterminatedComment(pos));
                }
                TokenKind::BlockComment
            }
            '\'' => {
                cur.bump();
                if !cur.bump_string_rest() {
                    return Err(LexError::UnterminatedString(pos));
                }
                TokenKind::Str
            }
            c if is_ident_start(c) => {
                cur.bump_while(is_ident_char);
                TokenKind::Ident
            }
            c if c.is_ascii_digit() => {
                cur.bump_number();
                TokenKind::Number
            }
            _ => {
                cur.bump();
                TokenKind::Punct
            }
        };
        tokens.push(Token {
            kind,
            text: &src[start..cur.offset],
            pos,
            span: start..cur.offset,
        });
    }
    Ok(tokens)
}

const fn is_ident_start(c: char) -> bool {
    c.is_ascii_alphabetic() || c == '_'
}

const fn is_ident_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// Reads `char`s and tracks the byte offset, line and column.
struct Cursor<'a> {
    src: &'a str,
    offset: usize,
    line: u32,
    column: u32,
}

impl<'a> Cursor<'a> {
    const fn new(src: &'a str) -> Self {
        Self {
            src,
            offset: 0,
            line: 1,
            column: 1,
        }
    }

    const fn pos(&self) -> Position {
        Position {
            line: self.line,
            column: self.column,
        }
    }

    fn peek(&self) -> Option<char> {
        self.src[self.offset..].chars().next()
    }

    fn peek_second(&self) -> Option<char> {
        self.src[self.offset..].chars().nth(1)
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.offset += c.len_utf8();
        if c == '\n' {
            self.line = self.line.saturating_add(1);
            self.column = 1;
        } else {
            self.column = self.column.saturating_add(1);
        }
        Some(c)
    }

    fn bump_while(&mut self, keep: impl Fn(char) -> bool) {
        while self.peek().is_some_and(&keep) {
            self.bump();
        }
    }

    /// Reads up to and including `end`. False at the end of the source.
    fn bump_past(&mut self, end: &str) -> bool {
        while !self.src[self.offset..].starts_with(end) {
            if self.bump().is_none() {
                return false;
            }
        }
        for _ in end.chars() {
            self.bump();
        }
        true
    }

    /// Reads the rest of a string literal, after the open quote. False when
    /// the line or the source ends first.
    fn bump_string_rest(&mut self) -> bool {
        loop {
            match self.peek() {
                None | Some('\n' | '\r') => return false,
                Some('\\') => {
                    self.bump();
                    if matches!(self.peek(), None | Some('\n' | '\r')) {
                        return false;
                    }
                    self.bump();
                }
                Some('\'') => {
                    self.bump();
                    return true;
                }
                Some(_) => {
                    self.bump();
                }
            }
        }
    }

    /// Reads digits, letter suffixes, and a `.` that a digit follows.
    fn bump_number(&mut self) {
        loop {
            match self.peek() {
                Some(c) if is_ident_char(c) => {
                    self.bump();
                }
                Some('.') if self.peek_second().is_some_and(|c| c.is_ascii_digit()) => {
                    self.bump();
                }
                _ => return,
            }
        }
    }
}
