// Reads the `global` API surface of Apex source (issue #122).
// Gives: the surface lines for docs/global-api.md, the rule violations, and a
// stub project that holds only the global members (the "packaged view").
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import {
  ApexParserFactory,
  CatchClauseContext,
  EnhancedForControlContext,
  FieldDeclarationContext,
  FormalParameterContext,
  LocalVariableDeclarationContext,
  VariableDeclaratorContext,
} from "@apexdevtools/apex-parser";

const hasMod = (mods, name) => mods.some((m) => m[name]() != null);
const annotationsOf = (mods) =>
  mods.filter((m) => m.annotation() != null).map((m) => m.annotation());
const annotationName = (a) => a.id().getText();
// Annotations that are part of the frozen contract, with their arguments.
const CONTRACT_ANNOTATION = /^(invocablemethod|invocablevariable|deprecated)$/i;

/** Parses one class file. Throws on a syntax error. */
function parse(source, file) {
  return parseAs(source, file, (p) => p.compilationUnit());
}

/** Parses a class file or, if that fails, a block of statements. */
function parseAny(source, file) {
  try {
    return parse(source, file);
  } catch {
    return parseAs(source, file, (p) => p.anonymousUnit());
  }
}

function parseAs(source, file, rule) {
  const parser = ApexParserFactory.createParser(source, true);
  try {
    return rule(parser);
  } catch (e) {
    throw new Error(`${file}: parse error: ${e.message ?? e}`);
  }
}

/** Reads all top-level `.cls` files of a directory. */
export function loadClasses(dir) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".cls"))
    .sort()
    .map((f) => {
      const source = readFileSync(join(dir, f), "utf8");
      return { file: f, source, unit: parse(source, f) };
    });
}

/** Parses in-memory sources: { "Name.cls": source }. */
export function parseSources(sources) {
  return Object.entries(sources).map(([file, source]) => ({
    file,
    source,
    unit: parse(source, file),
  }));
}

// ─── Type model ────────────────────────────────────────────────────────────

/**
 * Builds the type model. Each type has: qualified name, kind, global flag,
 * members (with global flag and signature data), and super types.
 */
export function buildModel(classes) {
  const types = new Map(); // lower-case qualified name -> type
  for (const { file, source, unit } of classes) {
    const td = unit.typeDeclaration();
    collectType(td, td.modifier_list(), null, { file, source }, types);
  }
  return types;
}

// Annotation arguments that change compatibility. Labels and descriptions
// are text only, so the manifest leaves them out.
const CONTRACT_ARGUMENTS = /^(required|callout)$/i;

/** An annotation with only its contract arguments, for example `@X(required=true)`. */
const annotationText = (a, source) => {
  const pairs = (a.elementValuePairs()?.elementValuePair_list() ?? [])
    .filter((p) => CONTRACT_ARGUMENTS.test(p.id().getText()))
    .map((p) => {
      const v = p.elementValue();
      return `${p.id().getText()}=${source.slice(v.start.start, v.stop.stop + 1)}`;
    });
  return `@${annotationName(a)}${pairs.length ? `(${pairs.join(" ")})` : ""}`;
};

function modifierWords(mods) {
  return ["WEBSERVICE", "ABSTRACT", "VIRTUAL", "OVERRIDE"]
    .filter((w) => hasMod(mods, w))
    .map((w) => w.toLowerCase());
}

function collectType(decl, mods, outer, src, types) {
  const { file } = src;
  const cls = decl.classDeclaration?.() ?? null;
  const itf = decl.interfaceDeclaration?.() ?? null;
  const enm = decl.enumDeclaration?.() ?? null;
  const node = cls ?? itf ?? enm;
  const name = node.id().getText();
  const qname = outer ? `${outer.name}.${name}` : name;
  const type = {
    name: qname,
    file,
    outer,
    kind: cls ? "class" : itf ? "interface" : "enum",
    global: hasMod(mods, "GLOBAL"),
    words: modifierWords(mods).filter((w) => w !== "override"),
    auraEnabled: false,
    isTest: annotationsOf(mods).some((a) =>
      /^istest$/i.test(annotationName(a)),
    ),
    node,
    extendsRefs: [],
    implementsRefs: [],
    members: [],
    enumValues: enm
      ? (enm.enumConstants()?.id_list() ?? []).map((i) => i.getText())
      : [],
    hasExplicitCtor: false,
  };
  types.set(qname.toLowerCase(), type);
  if (cls) {
    if (cls.typeRef()) type.extendsRefs.push(cls.typeRef());
    if (cls.typeList())
      type.implementsRefs.push(...cls.typeList().typeRef_list());
    for (const bd of cls.classBody().classBodyDeclaration_list()) {
      const md = bd.memberDeclaration();
      if (!md) continue;
      const bmods = bd.modifier_list();
      if (
        md.classDeclaration() ||
        md.interfaceDeclaration() ||
        md.enumDeclaration()
      ) {
        collectType(md, bmods, type, src, types);
        continue;
      }
      const member = memberOf(md, bmods, type, src.source);
      if (
        member.annotations.some((a) => /^auraenabled$/i.test(annotationName(a)))
      )
        type.auraEnabled = true;
      if (member.kind === "constructor") type.hasExplicitCtor = true;
      type.members.push(member);
    }
  } else if (itf) {
    if (itf.typeList()) type.extendsRefs.push(...itf.typeList().typeRef_list());
    for (const im of itf.interfaceBody().interfaceMethodDeclaration_list()) {
      type.members.push({
        kind: "method",
        name: im.id().getText(),
        global: type.global, // interface methods share the interface access
        isStatic: false,
        returnRef: im.typeRef(),
        params: formalParams(im.formalParameters()),
        annotations: [],
        contractAnnotations: [],
        words: [],
        interfaceMethod: true,
      });
    }
  }
}

function formalParams(fp) {
  const list = fp.formalParameterList();
  return list ? list.formalParameter_list().map((p) => p.typeRef()) : [];
}

function memberOf(md, mods, owner, source) {
  const words = modifierWords(mods);
  const annotations = annotationsOf(mods);
  const base = {
    // webservice members are visible outside the package, as global members.
    global: hasMod(mods, "GLOBAL") || words.includes("webservice"),
    words,
    contractAnnotations: annotations
      .filter((a) => CONTRACT_ANNOTATION.test(annotationName(a)))
      .map((a) => annotationText(a, source)),
    isStatic: hasMod(mods, "STATIC"),
    isFinal: hasMod(mods, "FINAL"),
    annotations,
    owner,
  };
  if (md.methodDeclaration()) {
    const m = md.methodDeclaration();
    return {
      ...base,
      kind: "method",
      name: m.id().getText(),
      returnRef: m.typeRef(),
      params: formalParams(m.formalParameters()),
    };
  }
  if (md.constructorDeclaration()) {
    const c = md.constructorDeclaration();
    return {
      ...base,
      kind: "constructor",
      name: owner.name,
      params: formalParams(c.formalParameters()),
    };
  }
  if (md.propertyDeclaration()) {
    const p = md.propertyDeclaration();
    let setterOpen = false;
    let hasSetter = false;
    let getterOpen = false;
    for (const pb of p.propertyBlock_list()) {
      const open = pb.modifier_list().length === 0; // no narrower modifier
      if (pb.setter()) {
        hasSetter = true;
        setterOpen = open;
      }
      if (pb.getter()) getterOpen = open;
    }
    return {
      ...base,
      kind: "property",
      name: p.id().getText(),
      typeRef: p.typeRef(),
      hasSetter,
      setterOpen,
      getterOpen,
    };
  }
  const f = md.fieldDeclaration();
  return {
    ...base,
    kind: "field",
    names: f
      .variableDeclarators()
      .variableDeclarator_list()
      .map((v) => v.id().getText()),
    typeRef: f.typeRef(),
  };
}

// ─── Type rendering and resolution ─────────────────────────────────────────

/** Finds the repo type that a dotted name means inside `scope`. */
function resolveRepoType(segments, scope, types) {
  for (let s = scope; s; s = s.outer) {
    const hit = types.get(`${s.name}.${segments.join(".")}`.toLowerCase());
    if (hit) return hit;
  }
  return types.get(segments.join(".").toLowerCase()) ?? null;
}

/**
 * Renders a type reference with repo types fully qualified. Calls `onRepo`
 * for each repo type it finds (also in generic arguments).
 */
function renderType(ref, scope, types, onRepo = () => {}) {
  if (!ref) return "void";
  const names = ref.typeName_list();
  const args = (tn) => {
    const ta = tn.typeArguments();
    if (!ta) return "";
    return `<${ta
      .typeList()
      .typeRef_list()
      .map((r) => renderType(r, scope, types, onRepo))
      .join(", ")}>`;
  };
  const head = names.map((tn) => {
    if (tn.LIST()) return "List";
    if (tn.SET()) return "Set";
    if (tn.MAP()) return "Map";
    return tn.id().getText();
  });
  const repo = resolveRepoType(head, scope, types);
  const tail = names.map(args);
  let text;
  if (repo && tail.every((t) => t === "")) {
    onRepo(repo);
    text = repo.name;
  } else {
    text = head.map((h, i) => h + tail[i]).join(".");
  }
  return text + (ref.arraySubscripts()?.getText() ?? "");
}

// ─── Surface lines ─────────────────────────────────────────────────────────

/**
 * A global class with no explicit constructor gets a global default
 * constructor. Exceptions are skipped: the platform gives their constructors.
 */
const implicitGlobalCtor = (t) =>
  t.global &&
  t.kind === "class" &&
  !t.hasExplicitCtor &&
  !t.extendsRefs.some((r) => /^exception$/i.test(r.getText()));

const signature = (m, scope, types) =>
  `(${m.params.map((p) => renderType(p, scope, types)).join(", ")})`;

function typeLine(t, types) {
  const words = t.words.map((w) => `${w} `).join("");
  let line = `global ${words}${t.kind} ${t.name}`;
  if (t.extendsRefs.length) {
    line += ` extends ${t.extendsRefs.map((r) => renderType(r, t.outer ?? t, types)).join(", ")}`;
  }
  if (t.implementsRefs.length) {
    line += ` implements ${t.implementsRefs.map((r) => renderType(r, t.outer ?? t, types)).join(", ")}`;
  }
  if (t.kind === "enum") line += ` { ${t.enumValues.join(", ")} }`;
  return line;
}

function memberLines(m, t, types) {
  const prefix = [
    ...m.contractAnnotations,
    ...m.words,
    m.isStatic ? "static" : "",
    m.isFinal ? "final" : "",
  ]
    .filter(Boolean)
    .map((w) => `${w} `)
    .join("");
  switch (m.kind) {
    case "method":
      return [
        `${prefix}${t.name}.${m.name}${signature(m, t, types)}: ${renderType(m.returnRef, t, types)}`,
      ];
    case "constructor":
      return [`${prefix}new ${t.name}${signature(m, t, types)}`];
    case "property":
      return [
        `${prefix}${t.name}.${m.name}: ${renderType(m.typeRef, t, types)} { ${accessors(m)} }`,
      ];
    default:
      return m.names.map(
        (n) => `${prefix}${t.name}.${n}: ${renderType(m.typeRef, t, types)}`,
      );
  }
}

/** Accessors a subscriber can use: "get", "set", or "get; set". */
const accessors = (m) =>
  [m.getterOpen ? "get" : "", m.hasSetter && m.setterOpen ? "set" : ""]
    .filter(Boolean)
    .join("; ");

/** Returns the sorted global surface lines of the model. */
export function surfaceLines(types) {
  const lines = [];
  for (const t of types.values()) {
    if (t.global) lines.push(typeLine(t, types));
    if (implicitGlobalCtor(t)) lines.push(`new ${t.name}()`);
    for (const m of t.members) {
      if (m.global && !m.interfaceMethod)
        lines.push(...memberLines(m, t, types));
      if (m.interfaceMethod && t.global)
        lines.push(...memberLines(m, t, types));
    }
  }
  return lines.sort();
}

// ─── Rules ─────────────────────────────────────────────────────────────────

/** Returns platform-rule violations of the global surface. */
export function ruleViolations(types) {
  const out = [];
  for (const t of types.values()) {
    for (let o = t.outer; t.global && o; o = o.outer) {
      if (!o.global)
        out.push(`${t.name}: global type in non-global type ${o.name}`);
    }
    if (t.global) {
      for (const r of t.extendsRefs) {
        renderType(r, t.outer ?? t, types, (rt) => {
          if (!rt.global) out.push(`${t.name}: extends non-global ${rt.name}`);
        });
      }
      for (const r of t.implementsRefs) {
        renderType(r, t.outer ?? t, types, (rt) => {
          if (!rt.global)
            out.push(`${t.name}: implements non-global ${rt.name}`);
        });
      }
    }
    for (const m of t.members) {
      if (!m.global) continue;
      if (!t.global)
        out.push(
          `${t.name}.${m.name ?? m.names}: global member in non-global type`,
        );
      const refs = [m.returnRef, m.typeRef, ...(m.params ?? [])].filter(
        Boolean,
      );
      for (const r of refs) {
        renderType(r, t, types, (rt) => {
          if (!rt.global)
            out.push(
              `${t.name}.${m.name ?? m.names}: uses non-global ${rt.name}`,
            );
        });
      }
    }
    if (t.global) {
      for (const m of t.members) {
        const inv = m.annotations.some((a) =>
          /^invocablevariable$/i.test(annotationName(a)),
        );
        if (inv && !m.global)
          out.push(
            `${t.name}.${m.names ?? m.name}: @InvocableVariable is not global`,
          );
        const im = m.annotations.some((a) =>
          /^invocablemethod$/i.test(annotationName(a)),
        );
        if (im && !m.global)
          out.push(`${t.name}.${m.name}: @InvocableMethod is not global`);
      }
    }
  }
  return out;
}

/** Engine internals by name (issue #122, acceptance criterion 6). */
export const INTERNAL_PATTERN =
  /^(WorkflowOrchestrator\w*|WorkflowWatchdog\w*|\w*Finalizer|\w*Job|\w*Controller|\w*Sweep|\w*Sweeper|\w*SweepRunner|Watchdog\w*)$/i;

/** Engine internals by structure: async jobs and finalizers. */
const INTERNAL_INTERFACE =
  /^(system\.)?(queueable|schedulable|database\.batchable|finalizer)(<.*>)?$/i;

const topOf = (t) => (t.outer ? topOf(t.outer) : t);

/**
 * Returns internal top-level types that have any global declaration. A type is
 * internal by name, when it is an async job or finalizer, or when it has
 * @AuraEnabled members (dashboard services).
 */
export function exposedInternals(types) {
  const internalTops = new Set();
  for (const t of types.values()) {
    const top = topOf(t);
    const byStructure = t.implementsRefs.some((r) =>
      INTERNAL_INTERFACE.test(r.getText()),
    );
    if (INTERNAL_PATTERN.test(top.name) || byStructure || t.auraEnabled)
      internalTops.add(top);
  }
  const bad = new Set();
  for (const t of types.values()) {
    const top = topOf(t);
    if (!internalTops.has(top)) continue;
    if (t.global || t.members.some((m) => m.global)) bad.add(top.name);
  }
  return [...bad].sort();
}

// ─── Packaged view (stub) ──────────────────────────────────────────────────

const srcType = (ref) => {
  if (!ref) return "void";
  // Keep source text; add the spaces that getText() drops.
  return ref.getText().replace(/,/g, ", ");
};
const stubParams = (m) =>
  m.params.map((p, i) => `${srcType(p)} a${i}`).join(", ");
const stubAnn = (m) =>
  m.annotations
    .filter((a) => /^invocable(method|variable)$/i.test(annotationName(a)))
    .map((a) => `@${annotationName(a)} `)
    .join("");
const stubWords = (w) =>
  w
    .filter((x) => x !== "webservice")
    .map((x) => `${x} `)
    .join("");

// Methods of the system interfaces that a global class implements.
const SYSTEM_INTERFACE_METHODS = { comparable: ["compareto"] };

/** Returns the lower-case method names that the class's interfaces require. */
function requiredMethodNames(t, types) {
  const names = new Set();
  const add = (refs, scope) => {
    for (const r of refs) {
      let repo = null;
      renderType(r, scope, types, (rt) => (repo = rt));
      if (repo) {
        repo.members.forEach((m) => names.add(m.name.toLowerCase()));
        add(repo.extendsRefs, repo.outer ?? repo); // super-interfaces
      } else {
        const sys = SYSTEM_INTERFACE_METHODS[r.getText().toLowerCase()] ?? [];
        sys.forEach((n) => names.add(n));
      }
    }
  };
  add(t.implementsRefs, t.outer ?? t);
  return names;
}

/** Returns the non-global methods that the stub keeps (lower-case names). */
function stubOnlyMethodNames(types) {
  const names = new Set();
  for (const t of types.values()) {
    if (!t.global || t.kind !== "class") continue;
    const required = requiredMethodNames(t, types);
    for (const m of t.members) {
      if (
        m.kind === "method" &&
        !m.global &&
        required.has(m.name.toLowerCase())
      )
        names.add(m.name.toLowerCase());
    }
  }
  return names;
}

function usesNonGlobalType(m, t, types) {
  let bad = false;
  for (const r of [m.returnRef, ...m.params].filter(Boolean)) {
    renderType(r, t, types, (rt) => {
      if (!rt.global) bad = true;
    });
  }
  return bad;
}

function stubType(t, types, indent) {
  const pad = "  ".repeat(indent);
  const inner = [...types.values()].filter((x) => x.outer === t && x.global);
  let ext = t.extendsRefs.length
    ? ` extends ${t.extendsRefs.map(srcType).join(", ")}`
    : "";
  if (t.implementsRefs.length) {
    ext += ` implements ${t.implementsRefs.map(srcType).join(", ")}`;
  }
  if (t.kind === "enum")
    return `${pad}global enum ${t.node.id().getText()} { ${t.enumValues.join(", ")} }\n`;
  const name = t.node.id().getText();
  let out = `${pad}global ${stubWords(t.words)}${t.kind} ${name}${ext} {\n`;
  const p2 = pad + "  ";
  if (t.kind === "interface") {
    for (const m of t.members)
      out += `${p2}${srcType(m.returnRef)} ${m.name}(${stubParams(m)});\n`;
  } else {
    // A class that implements an interface needs its implementing methods.
    // Keep them public. apex-ls does not check public access, so
    // stubOnlyCalls() finds a subscriber call to one.
    const required = requiredMethodNames(t, types);
    for (const m of t.members) {
      if (m.kind !== "method" || m.global || m.isStatic) continue;
      if (!required.has(m.name.toLowerCase())) continue;
      if (usesNonGlobalType(m, t, types)) continue;
      const body = m.returnRef ? "{ return null; }" : "{}";
      out += `${p2}public ${srcType(m.returnRef)} ${m.name}(${stubParams(m)}) ${body}\n`;
    }
    const globalCtors = t.members.filter(
      (m) => m.kind === "constructor" && m.global,
    );
    if (t.hasExplicitCtor && globalCtors.length === 0)
      out += `${p2}private ${name}() {}\n`;
    for (const m of t.members) {
      if (!m.global) continue;
      const st = m.isStatic ? "static " : "";
      if (m.kind === "constructor")
        out += `${p2}${stubAnn(m)}global ${name}(${stubParams(m)}) {}\n`;
      if (m.kind === "method") {
        const body = m.returnRef ? "{ return null; }" : "{}";
        const abstract = m.words.includes("abstract");
        out += `${p2}${stubAnn(m)}global ${stubWords(m.words)}${st}${srcType(m.returnRef)} ${m.name}(${stubParams(m)})${abstract ? ";" : ` ${body}`}\n`;
      }
      if (m.kind === "property") {
        const get = m.getterOpen ? "get;" : "private get;";
        const set = m.hasSetter && m.setterOpen ? "set;" : "private set;";
        out += `${p2}${stubAnn(m)}global ${st}${srcType(m.typeRef)} ${m.name} { ${get} ${set} }\n`;
      }
      if (m.kind === "field")
        out += `${p2}${stubAnn(m)}global ${st}${srcType(m.typeRef)} ${m.names.join(", ")};\n`;
    }
  }
  for (const it of inner) out += stubType(it, types, indent + 1);
  return `${out}${pad}}\n`;
}

/** Returns { fileName: source } for each global top-level type. */
export function stubSources(types) {
  const files = {};
  for (const t of types.values()) {
    if (t.outer || !t.global) continue;
    files[`${t.name}.cls`] = stubType(t, types, 0);
  }
  return files;
}

/** Returns the variable and parameter names that a unit declares. */
function declaredNames(unit) {
  const names = new Set();
  const visit = (node) => {
    if (
      node instanceof VariableDeclaratorContext ||
      node instanceof FormalParameterContext ||
      node instanceof EnhancedForControlContext ||
      node instanceof CatchClauseContext
    ) {
      names.add(node.id().getText());
    }
    for (const child of node.children ?? []) visit(child);
  };
  visit(unit);
  return names;
}

/**
 * Adds a namespace prefix to each reference to a top-level repo type in a
 * subscriber source. Skips member names (after a dot) and the file's own type.
 */
export function prefixRepoTypes(source, types, namespace, ownType) {
  const declared = declaredNames(parse(source, ownType));
  const tokens = ApexParserFactory.createLexer(source)
    .getAllTokens()
    .filter((tok) => tok.channel === 0);
  const top = new Map(
    [...types.values()]
      .filter((t) => !t.outer)
      .map((t) => [t.name.toLowerCase(), t.name]),
  );
  let out = "";
  let at = 0;
  tokens.forEach((tok, i) => {
    const text = source.slice(tok.start, tok.stop + 1);
    const hit = /^[A-Za-z_]\w*$/.test(text) && top.get(text.toLowerCase());
    const afterDot = i > 0 && tokens[i - 1].text === ".";
    const isVariable = declared.has(text);
    if (
      hit &&
      !afterDot &&
      !isVariable &&
      hit.toLowerCase() !== ownType.toLowerCase()
    ) {
      out += `${source.slice(at, tok.start)}${namespace}.${hit}`;
      at = tok.stop + 1;
    }
  });
  return out + source.slice(at);
}

/** Maps each declared variable (lower-case) to the repo type it names. */
function variableTypes(unit, types) {
  const map = new Map();
  const add = (ref, id) => {
    const names = ref.typeName_list();
    if (names.some((tn) => tn.typeArguments() || !tn.id())) return;
    const repo = resolveRepoType(
      names.map((tn) => tn.id().getText()),
      null,
      types,
    );
    if (repo) map.set(id.getText().toLowerCase(), repo);
  };
  const visit = (node) => {
    if (
      node instanceof LocalVariableDeclarationContext ||
      node instanceof FieldDeclarationContext
    ) {
      for (const v of node.variableDeclarators().variableDeclarator_list())
        add(node.typeRef(), v.id());
    }
    if (
      node instanceof FormalParameterContext ||
      node instanceof EnhancedForControlContext
    )
      add(node.typeRef(), node.id());
    for (const child of node.children ?? []) visit(child);
  };
  visit(unit);
  return map;
}

const ASSIGN_OPS = new Set([
  "=",
  "+=",
  "-=",
  "*=",
  "/=",
  "|=",
  "&=",
  "^=",
  "++",
  "--",
]);
const SHIFT_OPS = ["<<=", ">>=", ">>>="];

/** True when the tokens at `i` start an assignment operator. */
function isAssignAt(tokens, i) {
  const text = tokens[i]?.text ?? "";
  if (ASSIGN_OPS.has(text)) return true;
  const joined = tokens
    .slice(i, i + 4)
    .map((t) => t.text)
    .join("");
  return SHIFT_OPS.some((op) => joined.startsWith(op) && /^[<>]/.test(text));
}

/**
 * Returns the writes in a subscriber source to a global property that is
 * read-only outside the package. apex-ls does not check setter access. A
 * receiver with a known type is checked on that type. Any other receiver is
 * checked on all global types (strict).
 */
export function readOnlyWrites(source, types) {
  const readOnlyAnywhere = new Set();
  for (const t of types.values()) {
    for (const m of t.members) {
      if (m.global && m.kind === "property" && !(m.hasSetter && m.setterOpen))
        readOnlyAnywhere.add(m.name.toLowerCase());
    }
  }
  const isReadOnlyOn = (type, name) => {
    const m = type.members.find(
      (x) => x.kind === "property" && x.name.toLowerCase() === name,
    );
    return !!m && m.global && !(m.hasSetter && m.setterOpen);
  };
  const vars = variableTypes(parseAny(source, "subscriber"), types);
  const tokens = ApexParserFactory.createLexer(source)
    .getAllTokens()
    .filter((tok) => tok.channel === 0);
  const out = [];
  tokens.forEach((tok, i) => {
    if (i < 2 || tokens[i - 1].text !== ".") return;
    const name = tok.text.toLowerCase();
    const recv = tokens[i - 2];
    const prefixOp = ["++", "--"].includes(tokens[i - 3]?.text);
    if (!isAssignAt(tokens, i + 1) && !prefixOp) return;
    const simple = /^\w+$/.test(recv.text) && tokens[i - 3]?.text !== ".";
    const type = simple ? vars.get(recv.text.toLowerCase()) : null;
    const bad = type ? isReadOnlyOn(type, name) : readOnlyAnywhere.has(name);
    if (bad)
      out.push(`line ${tok.line}: ${simple ? recv.text : "?"}.${tok.text}`);
  });
  return out;
}

/**
 * Returns calls to methods that the stub keeps as public so a class can
 * implement an interface. apex-ls does not check public access across
 * namespaces, so a call to one would pass against the stub only.
 */
export function stubOnlyCalls(source, types) {
  const names = stubOnlyMethodNames(types);
  const tokens = ApexParserFactory.createLexer(source)
    .getAllTokens()
    .filter((tok) => tok.channel === 0);
  const out = [];
  tokens.forEach((tok, i) => {
    if (i === 0 || tokens[i - 1].text !== ".") return;
    if (tokens[i + 1]?.text !== "(") return;
    if (names.has(tok.text.toLowerCase()))
      out.push(`line ${tok.line}: .${tok.text}(`);
  });
  return out;
}
