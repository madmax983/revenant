// Reads the `global` API surface of Apex source (issue #122).
// Gives: the surface lines for docs/global-api.md, the rule violations, and a
// stub project that holds only the global members (the "packaged view").
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { ApexParserFactory } from "@apexdevtools/apex-parser";

const hasMod = (mods, name) => mods.some((m) => m[name]() != null);
const annotationsOf = (mods) =>
  mods.filter((m) => m.annotation() != null).map((m) => m.annotation());
const annotationName = (a) => a.id().getText();

/** Parses one class file. Throws on a syntax error. */
function parse(source, file) {
  const parser = ApexParserFactory.createParser(source, true);
  try {
    return parser.compilationUnit();
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
  for (const { file, unit } of classes) {
    const td = unit.typeDeclaration();
    collectType(td, td.modifier_list(), null, file, types);
  }
  return types;
}

function collectType(decl, mods, outer, file, types) {
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
    isTest: annotationsOf(mods).some((a) =>
      /^istest$/i.test(annotationName(a)),
    ),
    node,
    extendsRefs: [],
    members: [],
    enumValues: enm
      ? (enm.enumConstants()?.id_list() ?? []).map((i) => i.getText())
      : [],
    hasExplicitCtor: false,
  };
  types.set(qname.toLowerCase(), type);
  if (cls) {
    if (cls.typeRef()) type.extendsRefs.push(cls.typeRef());
    for (const bd of cls.classBody().classBodyDeclaration_list()) {
      const md = bd.memberDeclaration();
      if (!md) continue;
      const bmods = bd.modifier_list();
      if (
        md.classDeclaration() ||
        md.interfaceDeclaration() ||
        md.enumDeclaration()
      ) {
        collectType(md, bmods, type, file, types);
        continue;
      }
      const member = memberOf(md, bmods, type);
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
        interfaceMethod: true,
      });
    }
  }
}

function formalParams(fp) {
  const list = fp.formalParameterList();
  return list ? list.formalParameter_list().map((p) => p.typeRef()) : [];
}

function memberOf(md, mods, owner) {
  const base = {
    global: hasMod(mods, "GLOBAL"),
    isStatic: hasMod(mods, "STATIC"),
    isFinal: hasMod(mods, "FINAL"),
    annotations: annotationsOf(mods),
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
    for (const pb of p.propertyBlock_list()) {
      if (pb.setter()) {
        hasSetter = true;
        setterOpen = pb.modifier_list().length === 0; // no narrower modifier
      }
    }
    return {
      ...base,
      kind: "property",
      name: p.id().getText(),
      typeRef: p.typeRef(),
      hasSetter,
      setterOpen,
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
  let line = `global ${t.kind} ${t.name}`;
  if (t.extendsRefs.length) {
    line += ` extends ${t.extendsRefs.map((r) => renderType(r, t.outer ?? t, types)).join(", ")}`;
  }
  if (t.kind === "enum") line += ` { ${t.enumValues.join(", ")} }`;
  return line;
}

function memberLines(m, t, types) {
  const inv = m.annotations.find((a) =>
    /^invocable(method|variable)$/i.test(annotationName(a)),
  );
  const prefix = `${inv ? `@${annotationName(inv)} ` : ""}${m.isStatic ? "static " : ""}${m.isFinal ? "final " : ""}`;
  switch (m.kind) {
    case "method":
      return [
        `${prefix}${t.name}.${m.name}${signature(m, t, types)}: ${renderType(m.returnRef, t, types)}`,
      ];
    case "constructor":
      return [`${prefix}new ${t.name}${signature(m, t, types)}`];
    case "property":
      return [
        `${prefix}${t.name}.${m.name}: ${renderType(m.typeRef, t, types)} { get${m.hasSetter && m.setterOpen ? "; set" : ""} }`,
      ];
    default:
      return m.names.map(
        (n) => `${prefix}${t.name}.${n}: ${renderType(m.typeRef, t, types)}`,
      );
  }
}

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

/** Engine internals that must stay namespace-private (AC 6). */
export const INTERNAL_PATTERN =
  /^(WorkflowOrchestrator\w*|WorkflowWatchdog\w*|\w*Finalizer|\w*Job|\w*Controller|\w*Sweep|\w*Sweeper|\w*SweepRunner|Watchdog\w*)$/;

/** Returns internal top-level types that have any global declaration. */
export function exposedInternals(types) {
  const bad = new Set();
  for (const t of types.values()) {
    let top = t;
    while (top.outer) top = top.outer;
    if (!INTERNAL_PATTERN.test(top.name)) continue;
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

function stubType(t, types, indent) {
  const pad = "  ".repeat(indent);
  const inner = [...types.values()].filter((x) => x.outer === t && x.global);
  const ext = t.extendsRefs.length
    ? ` extends ${t.extendsRefs.map(srcType).join(", ")}`
    : "";
  if (t.kind === "enum")
    return `${pad}global enum ${t.node.id().getText()} { ${t.enumValues.join(", ")} }\n`;
  const name = t.node.id().getText();
  let out = `${pad}global ${t.kind} ${name}${ext} {\n`;
  const p2 = pad + "  ";
  if (t.kind === "interface") {
    for (const m of t.members)
      out += `${p2}${srcType(m.returnRef)} ${m.name}(${stubParams(m)});\n`;
  } else {
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
        out += `${p2}${stubAnn(m)}global ${st}${srcType(m.returnRef)} ${m.name}(${stubParams(m)}) ${body}\n`;
      }
      if (m.kind === "property") {
        const set = m.hasSetter && m.setterOpen ? "set;" : "private set;";
        out += `${p2}${stubAnn(m)}global ${st}${srcType(m.typeRef)} ${m.name} { get; ${set} }\n`;
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

/**
 * Adds a namespace prefix to each reference to a top-level repo type in a
 * subscriber source. Skips member names (after a dot) and the file's own type.
 */
export function prefixRepoTypes(source, types, namespace, ownType) {
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
    if (hit && !afterDot && hit.toLowerCase() !== ownType.toLowerCase()) {
      out += `${source.slice(at, tok.start)}${namespace}.${hit}`;
      at = tok.stop + 1;
    }
  });
  return out + source.slice(at);
}
