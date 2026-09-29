//! The scanned project: parsed files, a type index, and the step, producer
//! and definition sets.

use std::collections::{HashMap, HashSet};
use std::ops::Range;

use crate::lexer::{Token, TokenKind};
use crate::scope::{TypeDecl, TypeKind, declarations};

/// Supertype names (last segment, lower case) that make a step.
const STEP_ROOTS: &[&str] = &["workflowstep", "compensatablestep"];
/// Supertype names that make a capture producer.
const PRODUCER_ROOTS: &[&str] = &["captureproducer"];
/// Supertype names that make a workflow definition.
const DEFINITION_ROOTS: &[&str] = &[
    "workflowdefinition",
    "versionedworkflow",
    "errorroutingworkflow",
];

/// A declaration: file index and declaration index in that file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DeclId {
    /// Index in [`Project::files`].
    pub file: usize,
    /// Index in [`ParsedFile::decls`].
    pub decl: usize,
}

/// One lexed file that is not a test file.
pub struct ParsedFile<'a> {
    /// Path, as given.
    pub path: &'a str,
    /// All tokens, comments included.
    pub tokens: Vec<Token<'a>>,
    /// Tokens without comments.
    pub code: Vec<Token<'a>>,
    /// Type declarations, outer first.
    pub decls: Vec<TypeDecl>,
    /// Innermost declaration that holds each code token in its body.
    pub owner: Vec<Option<usize>>,
}

impl<'a> ParsedFile<'a> {
    /// Splits the tokens and finds the declarations.
    #[must_use]
    pub fn new(path: &'a str, tokens: Vec<Token<'a>>) -> Self {
        let code: Vec<Token<'a>> = tokens.iter().filter(|t| !t.is_comment()).cloned().collect();
        let decls = declarations(&code);
        let mut owner = vec![None; code.len()];
        for (idx, d) in decls.iter().enumerate() {
            for slot in &mut owner[d.body.clone()] {
                *slot = Some(idx);
            }
        }
        Self {
            path,
            tokens,
            code,
            decls,
            owner,
        }
    }

    /// True for a test file: a top-level class with `@IsTest`, or a name that
    /// ends with `Test`, `_test` (any case), or is `test`. Thus `FetchLatest`
    /// and `Contest` are not test classes.
    #[must_use]
    pub fn is_test_file(&self) -> bool {
        self.decls.iter().filter(|d| d.parent.is_none()).any(|d| {
            let lower = d.name.to_ascii_lowercase();
            d.annotations
                .iter()
                .any(|a| a.eq_ignore_ascii_case("istest"))
                || d.name.ends_with("Test")
                || lower.ends_with("_test")
                || lower == "test"
        })
    }
}

/// The type index and the trait sets.
pub struct Project<'a> {
    /// Files that are not test files.
    pub files: Vec<ParsedFile<'a>>,
    by_qualified: HashMap<String, Vec<DeclId>>,
    /// Classes and interfaces that are steps, through any supertype path.
    steps: HashSet<DeclId>,
    /// Types that are capture producers.
    producers: HashSet<DeclId>,
    /// Types that are workflow definitions.
    definitions: HashSet<DeclId>,
}

impl<'a> Project<'a> {
    /// Builds the index and the trait sets.
    #[must_use]
    pub fn new(files: Vec<ParsedFile<'a>>) -> Self {
        let mut by_qualified: HashMap<String, Vec<DeclId>> = HashMap::new();
        for (file, parsed) in files.iter().enumerate() {
            for (decl, d) in parsed.decls.iter().enumerate() {
                let id = DeclId { file, decl };
                by_qualified
                    .entry(d.qualified.to_ascii_lowercase())
                    .or_default()
                    .push(id);
            }
        }
        let mut project = Self {
            files,
            by_qualified,
            steps: HashSet::new(),
            producers: HashSet::new(),
            definitions: HashSet::new(),
        };
        project.steps = project.closure(STEP_ROOTS);
        project.producers = project.closure(PRODUCER_ROOTS);
        project.definitions = project.closure(DEFINITION_ROOTS);
        project
    }

    /// The declaration of `id`.
    #[must_use]
    pub fn decl(&self, id: DeclId) -> &TypeDecl {
        &self.files[id.file].decls[id.decl]
    }

    /// All declaration ids, in file and declaration order.
    pub fn ids(&self) -> impl Iterator<Item = DeclId> + '_ {
        self.files
            .iter()
            .enumerate()
            .flat_map(|(file, f)| (0..f.decls.len()).map(move |decl| DeclId { file, decl }))
    }

    /// True for a type that is a step through any supertype path.
    #[must_use]
    pub fn is_step_type(&self, id: DeclId) -> bool {
        self.steps.contains(&id)
    }

    /// True for a type that is a capture producer.
    #[must_use]
    pub fn is_producer(&self, id: DeclId) -> bool {
        self.producers.contains(&id)
    }

    /// Classes that are workflow definitions, in order.
    #[must_use]
    pub fn definition_classes(&self) -> Vec<DeclId> {
        let mut ids: Vec<DeclId> = self
            .definitions
            .iter()
            .copied()
            .filter(|&id| self.decl(id).kind == TypeKind::Class)
            .collect();
        ids.sort_unstable();
        ids
    }

    /// Resolves a step name from `getSteps()`, as `Type.forName` does: the
    /// qualified name, then the name without its namespace. Classes only.
    #[must_use]
    pub fn resolve_step_name(&self, name: &str) -> Vec<DeclId> {
        let lower = name.trim().to_ascii_lowercase();
        let mut found = self.by_qualified.get(&lower).cloned().unwrap_or_default();
        if found.is_empty()
            && let Some((_, rest)) = lower.split_once('.')
        {
            found = self.by_qualified.get(rest).cloned().unwrap_or_default();
        }
        found.retain(|&id| self.decl(id).kind == TypeKind::Class);
        found
    }

    /// String literals in the `getSteps()` method of a definition class.
    #[must_use]
    pub fn get_steps_literals(&self, id: DeclId) -> Vec<&Token<'a>> {
        let code = &self.files[id.file].code;
        self.method_body(id, "getsteps")
            .map_or_else(Vec::new, |body| {
                code[body]
                    .iter()
                    .filter(|t| t.kind == TokenKind::Str)
                    .collect()
            })
    }

    /// Code-token indices in the body of the no-argument method `name` that
    /// declaration `id` itself declares. Names match without case.
    #[must_use]
    pub fn method_body(&self, id: DeclId, name: &str) -> Option<Range<usize>> {
        let file = &self.files[id.file];
        let code = &file.code;
        let body = self.decl(id).body.clone();
        let open = body.clone().find(|&k| {
            file.owner[k] == Some(id.decl)
                && code[k].is_ident(name)
                && code.get(k + 1).is_some_and(|t| t.is_punct('('))
                && code.get(k + 2).is_some_and(|t| t.is_punct(')'))
                && code.get(k + 3).is_some_and(|t| t.is_punct('{'))
        })? + 3;
        let mut depth = 0usize;
        for (k, tok) in code.iter().enumerate().take(body.end).skip(open) {
            if tok.is_punct('{') {
                depth += 1;
            } else if tok.is_punct('}') {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return Some(open + 1..k);
                }
            }
        }
        Some(open + 1..body.end)
    }

    /// Types that reach a root name through `extends` or `implements`, in the
    /// scanned source. A fixpoint, so a supertype cycle stops.
    fn closure(&self, roots: &[&str]) -> HashSet<DeclId> {
        let mut set: HashSet<DeclId> = HashSet::new();
        loop {
            let mut changed = false;
            for id in self.ids() {
                if set.contains(&id) {
                    continue;
                }
                let reaches = self.decl(id).supertypes.iter().any(|s| {
                    roots.contains(&last_segment(s).as_str())
                        || self.resolve_type(id, s).iter().any(|t| set.contains(t))
                });
                if reaches {
                    set.insert(id);
                    changed = true;
                }
            }
            if !changed {
                return set;
            }
        }
    }

    /// Resolves a supertype name of `from` as Apex does: a nested type of each
    /// enclosing class (innermost first), then a top-level type, then the name
    /// without its namespace.
    fn resolve_type(&self, from: DeclId, name: &str) -> Vec<DeclId> {
        let lower = name.to_ascii_lowercase();
        let mut scope = self.decl(from).parent;
        while let Some(outer) = scope {
            let outer_id = DeclId {
                file: from.file,
                decl: outer,
            };
            let nested = format!(
                "{}.{lower}",
                self.decl(outer_id).qualified.to_ascii_lowercase()
            );
            if let Some(ids) = self.by_qualified.get(&nested) {
                return ids.clone();
            }
            scope = self.decl(outer_id).parent;
        }
        if let Some(ids) = self.by_qualified.get(&lower) {
            return ids.clone();
        }
        lower
            .split_once('.')
            .and_then(|(_, rest)| self.by_qualified.get(rest).cloned())
            .unwrap_or_default()
    }
}

fn last_segment(name: &str) -> String {
    name.rsplit('.').next().unwrap_or(name).to_ascii_lowercase()
}
