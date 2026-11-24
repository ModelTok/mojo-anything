// The TypeScript and JavaScript reader of the Mojo tool: what src/ts/scan.rs,
// src/ts/exports.rs, src/ts/jsdoc.rs, src/ts/tsconfig.rs and bridge.rs's type
// rules (types_in_scope, substitute_constraints, js_only_reason) read from
// oxc's AST, read here from the AST of oxc's own parser at the same release
// (oxc-parser 0.158.0, DECISIONS.md F20). oxc-parser gives the ESTree form of
// the same tree; where that form loses what the Rust walk tells apart (a
// binding from a reference, a span ESTree moves), the file declines and the
// command goes to the Phase 1 binary.
//
// Request on stdin (JSON): {oxc, root, files: [{path, parse_as, exports}],
// packages: [[name, dir], ...]}. Answer on stdout: {decline: why} or {files:
// [{status, loc, parse_errors, imports: [[spec, type_only, platform,
// package, alias candidates]], risks: {name: [lines]}, platforms, loops,
// exports, bridgeable}]}, a file that does not read as UTF-8 being
// {status: "unreadable"}.

import fs from "node:fs";

class Decline extends Error {}
const decline = (why) => {
  throw new Decline(why);
};

const req = JSON.parse(fs.readFileSync(0, "utf8"));
const { parseSync } = await import(req.oxc);
const ROOT = req.root;

// ---- Rust's string rules ----------------------------------------------------

const WS = /^\p{White_Space}$/u;
const ALNUM = /^[\p{Alphabetic}\p{N}]$/u;
const isWs = (c) => WS.test(c);
const isAlnum = (c) => ALNUM.test(c);

// White_Space characters are all in the BMP, so UTF-16 units are enough.
function trimStart(s) {
  let i = 0;
  while (i < s.length && isWs(s[i])) i++;
  return s.slice(i);
}
function trimEnd(s) {
  let j = s.length;
  while (j > 0 && isWs(s[j - 1])) j--;
  return s.slice(0, j);
}
const trim = (s) => trimEnd(trimStart(s));

// str::lines: split after each `\n`, strip `\n` or `\r\n`, no empty last line.
function lines(s) {
  const out = [];
  let start = 0;
  while (start < s.length) {
    let nl = s.indexOf("\n", start);
    if (nl < 0) {
      out.push(s.slice(start));
      break;
    }
    let line = s.slice(start, nl);
    if (line.endsWith("\r")) line = line.slice(0, -1);
    out.push(line);
    start = nl + 1;
  }
  return out;
}

// `split(|c| !(c.is_alphanumeric() || extra.contains(c)))`, empty words kept.
function splitWords(s, extra) {
  const out = [];
  let cur = "";
  for (const c of s) {
    if (isAlnum(c) || extra.includes(c)) cur += c;
    else {
      out.push(cur);
      cur = "";
    }
  }
  out.push(cur);
  return out;
}

function hasLoneSurrogate(s) {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const d = s.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) {
        i++;
        continue;
      }
      return true;
    }
    if (c >= 0xdc00 && c <= 0xdfff) return true;
  }
  return false;
}

// A string value as oxc's `value.display()` / `as_str()` gives it: a lone
// surrogate (stored lossily in Rust) or a replacement character declines.
function strValue(lit) {
  const v = lit.value;
  if (hasLoneSurrogate(v) || v.includes("�")) decline("lossy string");
  return v;
}

const isStr = (n) => n && n.type === "Literal" && typeof n.value === "string" && !n.regex;

function readText(rel) {
  let buf;
  try {
    buf = fs.readFileSync(ROOT + "/" + rel);
  } catch {
    return null;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(buf);
  } catch {
    return null;
  }
}

function isFile(rel) {
  try {
    return fs.statSync(ROOT + "/" + rel).isFile();
  } catch {
    return false;
  }
}

function isDir(rel) {
  try {
    return fs.statSync(ROOT + "/" + rel).isDirectory();
  } catch {
    return false;
  }
}

// ---- parsing ----------------------------------------------------------------

const parsed = new Map();
function parse(fileName, source) {
  const key = fileName + "\0" + source;
  if (!parsed.has(key)) {
    const r = parseSync(fileName, source);
    parsed.set(key, r);
  }
  return parsed.get(key);
}

const SKIP_KEYS = new Set(["type", "start", "end", "range", "loc"]);

function children(node) {
  const out = [];
  for (const k of Object.keys(node)) {
    if (SKIP_KEYS.has(k)) continue;
    const v = node[k];
    if (Array.isArray(v)) {
      for (const x of v) if (x && typeof x === "object" && typeof x.type === "string") out.push([k, x]);
    } else if (v && typeof v === "object" && typeof v.type === "string") {
      out.push([k, v]);
    }
  }
  return out;
}

// ---- scan.rs ------------------------------------------------------------------

const STRING_OFFSET_METHODS = [
  "slice", "substring", "substr", "charAt", "charCodeAt", "codePointAt",
  "indexOf", "lastIndexOf", "padStart", "padEnd",
];
const BROWSER_GLOBALS = [
  "window", "document", "navigator", "localStorage", "sessionStorage", "location", "HTMLElement",
];
const NODE_GLOBALS = ["process", "Buffer", "__dirname", "__filename"];
const INTERESTING = new Set([...BROWSER_GLOBALS, ...NODE_GLOBALS, "Symbol"]);
const NODE_BUILTINS = [
  "assert", "async_hooks", "buffer", "child_process", "cluster", "console", "constants",
  "crypto", "dgram", "diagnostics_channel", "dns", "domain", "events", "fs", "http", "http2",
  "https", "inspector", "module", "net", "os", "path", "perf_hooks", "process", "punycode",
  "querystring", "readline", "repl", "stream", "string_decoder", "sys", "timers", "tls",
  "trace_events", "tty", "url", "util", "v8", "vm", "wasi", "worker_threads", "zlib",
];
const UI_PACKAGES = [
  "vue", "react", "react-dom", "preact", "solid-js", "svelte", "nuxt", "#app", "#imports",
  "vue-router",
];

function platformOf(spec) {
  const root = spec.split("/")[0];
  if (spec.startsWith("node:") || NODE_BUILTINS.includes(root)) return "node";
  if (spec === "vscode") return "editor";
  if (UI_PACKAGES.includes(spec)) return "ui";
  return null;
}

function regexFoldsDifferently(pattern, flags) {
  if (!flags.includes("i") || flags.includes("u") || flags.includes("v")) return false;
  let escaped = false;
  for (const c of pattern) {
    const letter = !escaped && (c === "s" || c === "S" || c === "k" || c === "K");
    escaped = !escaped && c === "\\";
    if (letter) return true;
  }
  return false;
}

function regexNeedsFancy(pattern, flags) {
  if (flags.includes("y")) return true;
  for (const n of ["(?=", "(?!", "(?<=", "(?<!", "\\k<"]) if (pattern.includes(n)) return true;
  let inClass = false;
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === "\\") {
      const d = pattern[i + 1];
      if (!inClass && d !== undefined && d >= "1" && d <= "9") return true;
      i++;
    } else if (c === "[") inClass = true;
    else if (c === "]") inClass = false;
  }
  return false;
}

const FUNCTION_TYPES = new Set([
  "FunctionDeclaration", "FunctionExpression", "TSDeclareFunction", "TSEmptyBodyFunctionExpression",
]);
const METHOD_TYPES = new Set(["MethodDefinition", "TSAbstractMethodDefinition"]);
const BITWISE = new Set(["|", "^", "&", "<<", ">>", ">>>"]);

// Where an Identifier is a binding or a name (not an IdentifierReference in
// oxc's Rust AST): "skip"; a reference: "ref"; a slot this reader has not
// sorted: null (the file declines when the name is one scan.rs looks for).
function identifierRole(parent, key, mode) {
  const t = parent.type;
  if (mode === "binding") return "skip";
  if (mode === "target") return "ref";
  switch (t) {
    case "MemberExpression":
      return key === "object" || parent.computed ? "ref" : "skip";
    case "Property":
      if (key === "key") return parent.computed ? "ref" : "skip";
      return "ref";
    case "MethodDefinition": case "TSAbstractMethodDefinition": case "PropertyDefinition":
    case "TSAbstractPropertyDefinition": case "AccessorProperty": case "TSAbstractAccessorProperty":
      if (key === "key") return parent.computed ? "ref" : "skip";
      return "ref";
    case "TSPropertySignature": case "TSMethodSignature":
      if (key === "key") return parent.computed ? "ref" : "skip";
      return null;
    case "ExportSpecifier":
      if (key === "exported") return "skip";
      return null; // decided by the caller (source or not)
    case "ImportSpecifier": case "ImportDefaultSpecifier": case "ImportNamespaceSpecifier":
    case "ExportAllDeclaration": case "MetaProperty": case "LabeledStatement":
    case "BreakStatement": case "ContinueStatement": case "TSTypeAliasDeclaration":
    case "TSInterfaceDeclaration": case "TSEnumDeclaration": case "TSModuleDeclaration":
    case "TSTypeParameter": case "TSEnumMember": case "TSTypePredicate": case "TSNamedTupleMember":
    case "TSImportEqualsDeclaration": case "TSNamespaceExportDeclaration": case "TSMappedType":
    case "TSIndexSignature":
      if (t === "TSEnumMember" && key === "initializer") return "ref";
      if (t === "TSImportEqualsDeclaration" && key === "moduleReference") return "ref";
      if (t === "TSMappedType" && key !== "key") return null;
      return "skip";
    case "TSQualifiedName":
      return key === "left" ? "ref" : "skip";
    case "TSTypeReference": case "TSTypeQuery": case "TSClassImplements": case "TSInterfaceHeritage":
    case "ExpressionStatement": case "CallExpression": case "NewExpression": case "BinaryExpression":
    case "LogicalExpression": case "UnaryExpression": case "UpdateExpression":
    case "ConditionalExpression": case "AssignmentExpression": case "SequenceExpression":
    case "ArrayExpression": case "SpreadElement": case "ReturnStatement": case "ThrowStatement":
    case "IfStatement": case "WhileStatement": case "DoWhileStatement": case "ForStatement":
    case "ForInStatement": case "ForOfStatement": case "SwitchStatement": case "SwitchCase":
    case "TemplateLiteral": case "TaggedTemplateExpression": case "AwaitExpression":
    case "YieldExpression": case "ArrowFunctionExpression": case "VariableDeclarator":
    case "AssignmentPattern": case "ChainExpression": case "ParenthesizedExpression":
    case "TSAsExpression": case "TSSatisfiesExpression": case "TSNonNullExpression":
    case "TSTypeAssertion": case "TSInstantiationExpression": case "Decorator":
    case "ExportDefaultDeclaration": case "ImportExpression": case "WithStatement":
    case "ClassDeclaration": case "ClassExpression": case "JSXExpressionContainer":
    case "JSXSpreadAttribute": case "TSExportAssignment":
      if ((t === "ClassDeclaration" || t === "ClassExpression") && key === "id") return "skip";
      if (t === "VariableDeclarator" && key === "id") return "skip";
      return "ref";
    default:
      return null;
  }
}

// The mode a child slot is read in: "expr" (identifiers are references),
// "binding" (declared names) or "target" (assigned names, references).
function childMode(node, key, mode) {
  const t = node.type;
  if (FUNCTION_TYPES.has(t) || t === "ArrowFunctionExpression") {
    if (key === "params") return "binding";
    if (key === "id") return "binding";
    return "expr";
  }
  switch (t) {
    case "VariableDeclarator":
      return key === "id" ? "binding" : "expr";
    case "CatchClause":
      return key === "param" ? "binding" : "expr";
    case "TSParameterProperty":
      return key === "parameter" ? "binding" : "expr";
    case "TSFunctionType": case "TSConstructorType": case "TSMethodSignature":
    case "TSCallSignatureDeclaration": case "TSConstructSignatureDeclaration":
      return key === "params" ? "binding" : "expr";
    case "AssignmentExpression":
      return key === "left" ? "target" : "expr";
    case "ForInStatement": case "ForOfStatement":
      if (key === "left") return node.left.type === "VariableDeclaration" ? "expr" : "target";
      return "expr";
    case "ObjectPattern": case "ArrayPattern": case "RestElement":
      if (key === "typeAnnotation" || key === "decorators") return "expr";
      return mode === "expr" ? "target" : mode;
    case "AssignmentPattern":
      if (key === "left") return mode === "expr" ? "target" : mode;
      return "expr";
    case "Property":
      if (mode === "binding" || mode === "target") {
        if (key === "value") return mode;
        return "expr";
      }
      return "expr";
    case "Identifier":
      return "expr";
    default:
      return "expr";
  }
}

function scanTree(program, source) {
  const starts = [0];
  for (let i = source.indexOf("\n"); i >= 0; i = source.indexOf("\n", i + 1)) starts.push(i + 1);
  const lineOf = (offset) => {
    let lo = 0, hi = starts.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (starts[mid] <= offset) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  };
  const facts = { imports: [], risks: {}, platforms: new Set(), loops: 0 };
  const add = (risk, node) => {
    (facts.risks[risk] ||= []).push(lineOf(node.start));
  };
  const imp = (spec, typeOnly, dynamic) => facts.imports.push([spec, typeOnly, dynamic]);
  const checkRegex = (pattern, flags, node) => {
    if (regexNeedsFancy(pattern, flags) || regexFoldsDifferently(pattern, flags)) add("regex-syntax", node);
    if (flags.includes("d")) add("string-offsets", node);
  };
  const ident = (e) => (e && e.type === "Identifier" ? e.name : null);
  const stringArg = (a) => (isStr(a) ? strValue(a) : null);
  const regexpCtor = (pattern, flags, node) => {
    const p = stringArg(pattern);
    if (p !== null) checkRegex(p, stringArg(flags) ?? "", node);
    else add("dynamic-regex", node);
  };

  const visit = (node, parent, key, mode) => {
    const t = node.type;
    switch (t) {
      case "ImportDeclaration":
        imp(strValue(node.source), node.importKind === "type", false);
        break;
      case "ExportNamedDeclaration":
        if (node.source) imp(strValue(node.source), node.exportKind === "type", false);
        break;
      case "ExportAllDeclaration":
        imp(strValue(node.source), node.exportKind === "type", false);
        break;
      case "ImportExpression":
        if (isStr(node.source)) imp(strValue(node.source), false, true);
        else add("dynamic-code", node);
        break;
      case "CallExpression": {
        const c = node.callee;
        if (c.type === "MemberExpression" && !c.computed && c.property.type === "Identifier") {
          const obj = ident(c.object);
          const p = c.property.name;
          if (obj === "JSON") add("json", node);
          else if (obj === "Object" && ["keys", "values", "entries", "fromEntries"].includes(p))
            add("ordered-collections", node);
          else if ((obj === "Object" && ["defineProperty", "getPrototypeOf", "setPrototypeOf", "freeze"].includes(p)) || obj === "Reflect")
            add("reflection", node);
          else if (obj === "Promise") add("async", node);
          else if ((obj === "Math" && p === "random") || ((obj === "Date" || obj === "performance") && p === "now") || (obj === "crypto" && (p === "randomUUID" || p === "getRandomValues")))
            add("clock-and-random", node);
          else if ((obj === "Math" && p === "round") || p === "toFixed") add("number-semantics", node);
          else if (p === "matchAll" || p === "exec") add("string-offsets", node);
          else if (STRING_OFFSET_METHODS.includes(p)) add("string-offsets", node);
        } else if (c.type === "Identifier") {
          const a = node.arguments;
          switch (c.name) {
            case "eval": add("dynamic-code", node); break;
            case "Date": add("clock-and-random", node); break;
            case "parseInt": case "parseFloat": add("number-semantics", node); break;
            case "require": {
              const s = stringArg(a[0]);
              if (s !== null) imp(s, false, true);
              else add("dynamic-code", node);
              break;
            }
            case "RegExp": regexpCtor(a[0], a[1], node); break;
          }
        }
        break;
      }
      case "NewExpression": {
        const name = ident(node.callee);
        const a = node.arguments;
        if (name === "RegExp") regexpCtor(a[0], a[1], node);
        else if (name === "Map" || name === "Set") add("ordered-collections", node);
        else if (name === "Date" && a.length === 0) add("clock-and-random", node);
        else if (name === "Function") add("dynamic-code", node);
        else if (name === "Proxy" || name === "WeakRef" || name === "FinalizationRegistry") add("reflection", node);
        else if (name === "Promise") add("async", node);
        break;
      }
      case "MemberExpression":
        if (parent && (parent.type === "TSClassImplements" || (parent.type === "MemberExpression" && parent._qualified))) {
          node._qualified = true; // a TSQualifiedName in Rust's AST, not a member expression
          break;
        }
        if (!node.computed && node.property.type === "Identifier" && (node.property.name === "indices" || node.property.name === "lastIndex"))
          add("string-offsets", node);
        break;
      case "Literal":
        if (node.regex) {
          checkRegex(node.regex.pattern, node.regex.flags, node);
          return;
        }
        break;
      case "ThrowStatement": case "TryStatement":
        add("exceptions", node);
        break;
      case "AwaitExpression":
        add("async", node);
        break;
      case "YieldExpression":
        add("generators", node);
        break;
      case "ArrowFunctionExpression":
        if (node.async) add("async", node);
        break;
      case "ClassDeclaration": case "ClassExpression":
        if (node.decorators && node.decorators.length) decline("decorated class");
        if (node.superClass) add("class-inheritance", node);
        break;
      case "ForInStatement":
        facts.loops++;
        add("ordered-collections", node);
        break;
      case "ForOfStatement": case "ForStatement": case "WhileStatement": case "DoWhileStatement":
        facts.loops++;
        break;
      case "BinaryExpression":
        if (BITWISE.has(node.operator)) add("number-semantics", node);
        else if (node.operator === "in" && node.left.type !== "PrivateIdentifier") add("dynamic-typing", node);
        break;
      case "TSAnyKeyword":
        add("dynamic-typing", node);
        break;
      case "TSFunctionType": case "TSMethodSignature":
        add("callbacks", node);
        break;
      case "Identifier":
        if (INTERESTING.has(node.name)) {
          let role = parent ? identifierRole(parent, key, mode) : null;
          if (parent && parent.type === "ExportSpecifier" && key === "local") role = parent._fromSource ? "skip" : "ref";
          if (role === null) decline("identifier `" + node.name + "` in " + (parent ? parent.type : "?"));
          if (role === "ref") {
            if (BROWSER_GLOBALS.includes(node.name)) facts.platforms.add("browser");
            else if (NODE_GLOBALS.includes(node.name)) facts.platforms.add("node");
            else add("reflection", node);
          }
        }
        break;
      case "JSXIdentifier":
        if (INTERESTING.has(node.name) && !(parent && parent.type === "JSXAttribute")) decline("JSX name");
        break;
    }
    if (FUNCTION_TYPES.has(t)) {
      // A method's function starts at its parameters in both trees (a `*` on
      // the line above `m()`, and a decorated `async m()`, give the line of
      // `m(` in the Phase 1 plan).
      if (node.generator) add("generators", node);
      if (node.async) add("async", node);
    }
    if (t === "ExportNamedDeclaration") {
      for (const s of node.specifiers || []) s._fromSource = !!node.source;
      if (node.declaration && node.declaration.decorators && node.declaration.decorators.length) decline("decorated export");
    }
    for (const [k, child] of children(node)) visit(child, node, k, childMode(node, k, mode));
  };
  visit(program, null, null, "expr");
  for (const [spec] of facts.imports) {
    const p = platformOf(spec);
    if (p) facts.platforms.add(p);
  }
  return facts;
}

function locOf(source) {
  return lines(source).filter((l) => trim(l).length > 0).length;
}

// ---- jsdoc.rs -------------------------------------------------------------------

function leadingDoc(source, offset) {
  const before = trimEnd(source.slice(0, offset));
  if (!before.endsWith("*/")) return null;
  const bodyEnd = before.length - 2;
  const start = before.slice(0, bodyEnd).lastIndexOf("/**");
  if (start < 0) return null;
  const body = before.slice(start + 3, bodyEnd);
  if (body.includes("*/")) return null;
  return parseDoc(body);
}

function splitWs(s) {
  // split_once(char::is_whitespace)
  let i = 0;
  for (const c of s) {
    if (isWs(c)) return [s.slice(0, i), s.slice(i + c.length)];
    i += c.length;
  }
  return [s, ""];
}

function braced(text) {
  if (!text.startsWith("{")) return null;
  const rest = text.slice(1);
  let depth = 1;
  for (let i = 0; i < rest.length; i++) {
    const c = rest[i];
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return [rest.slice(0, i), rest.slice(i + 1)];
    }
  }
  return null;
}

function validName(name) {
  if (!name.length) return false;
  for (const c of name) if (!(isAlnum(c) || c === "_" || c === "$" || c === ".")) return false;
  return true;
}

function paramName(text) {
  if (text.startsWith("[")) {
    const inner = text.slice(1);
    const end = inner.indexOf("]");
    if (end < 0) return null;
    const name = trim(inner.slice(0, end).split("=")[0]);
    return validName(name) ? [name, true] : null;
  }
  let name = "";
  for (const c of text) {
    if (isWs(c)) break;
    name += c;
  }
  name = name.replace(/[-,]+$/, "");
  return validName(name) ? [name, false] : null;
}

function normalizeDocType(t) {
  t = t.split("Object.<").join("Record<").split(".<").join("<");
  let out = "";
  let word = "";
  const map = { String: "string", Number: "number", Boolean: "boolean", Object: "object" };
  const flush = () => {
    out += map[word] ?? word;
    word = "";
  };
  for (const c of t) {
    if (isAlnum(c) || c === "_" || c === "$") word += c;
    else {
      flush();
      out += c;
    }
  }
  flush();
  return out;
}

function isType(ts) {
  const r = parseSync("t.ts", "type __T = " + ts + ";");
  return r.errors.length === 0 && r.program.body.length === 1;
}

function toTs(jsdoc) {
  let t = trim(jsdoc);
  const optional = t.endsWith("=");
  t = trim(t.replace(/=+$/, ""));
  const rest = t.startsWith("...");
  t = trim(t.replace(/^(\.\.\.)+/, ""));
  if (t.includes("function(") || t.includes("=>")) return null;
  let ts;
  if (t === "" || t === "*" || t === "?") ts = "unknown";
  else {
    let nullable = false;
    let inner = t;
    if (t.startsWith("?")) {
      nullable = true;
      inner = t.slice(1);
    } else if (t.startsWith("!")) inner = t.slice(1);
    inner = normalizeDocType(trim(inner));
    ts = nullable ? "(" + inner + ") | null" : inner;
  }
  if (rest) ts = "(" + ts + ")[]";
  return isType(ts) ? [ts, optional] : null;
}

function parseDoc(body) {
  const chunks = [];
  for (let line of lines(body)) {
    line = trimStart(line);
    if (line.startsWith("*")) line = line.slice(1);
    line = trim(line);
    if (line.startsWith("@")) chunks.push(line.slice(1));
    else if (chunks.length) chunks[chunks.length - 1] += "\n" + line;
  }
  const doc = { params: [], returns: null };
  const nested = [];
  for (const chunk of chunks) {
    let [tag, rest] = splitWs(chunk);
    rest = trimStart(rest);
    let rawType = null;
    const b = braced(rest);
    if (b) {
      rawType = b[0];
      rest = trimStart(b[1]);
    }
    if (tag === "param" || tag === "arg" || tag === "argument") {
      const pn = paramName(rest);
      if (!pn) continue;
      const [name, bracketed] = pn;
      let tsType = null, optionalType = false;
      if (rawType !== null) {
        const r = toTs(rawType);
        if (r) [tsType, optionalType] = r;
      }
      const optional = bracketed || optionalType;
      const dot = name.indexOf(".");
      if (dot >= 0) nested.push([name.slice(0, dot), name.slice(dot + 1), tsType, optional]);
      else doc.params.push({ name, tsType, optional });
    } else if (tag === "returns" || tag === "return") {
      const r = rawType === null ? null : toTs(rawType);
      doc.returns = r ? r[0] : null;
    }
  }
  for (const p of doc.params) {
    const fields = nested.filter((n) => n[0] === p.name);
    if (!fields.length || !(p.tsType === "object" || p.tsType === "Object")) continue;
    if (fields.some((f) => f[1].includes(".") || f[2] === null)) {
      p.tsType = null;
      continue;
    }
    p.tsType = "{ " + fields.map((f) => f[1] + (f[3] ? "?" : "") + ": " + (f[2] ?? "unknown")).join("; ") + " }";
  }
  return doc;
}

const docParam = (doc, name) => doc.params.find((p) => p.name === name) || null;
const EMPTY_DOC = { params: [], returns: null };

// ---- exports.rs -----------------------------------------------------------------

// FormalParameters: the items (a `this` parameter is not one) and the rest.
function formalParams(params) {
  const items = [];
  let rest = null;
  params.forEach((p, i) => {
    if (i === 0 && p.type === "Identifier" && p.name === "this") return;
    if (p.type === "RestElement") rest = p;
    else items.push(p);
  });
  return { items, rest };
}

// One FormalParameter: its pattern, annotation, initializer, optional flag and
// TS parameter-property modifiers.
function paramParts(p) {
  let accessibility = null, readonly = false, decorated = false;
  if (p.type === "TSParameterProperty") {
    accessibility = p.accessibility ?? null;
    readonly = !!p.readonly;
    if (p.decorators && p.decorators.length) decorated = true;
    p = p.parameter;
  }
  if (p.decorators && p.decorators.length) decorated = true;
  let pattern = p, init = null;
  if (p.type === "AssignmentPattern") {
    pattern = p.left;
    init = p.right;
  }
  const ann = pattern.typeAnnotation ?? (p !== pattern ? p.typeAnnotation : null) ?? null;
  return { pattern, ann, init, optional: !!pattern.optional, accessibility, readonly, decorated };
}

const bindingName = (pattern) => (pattern.type === "Identifier" ? pattern.name : null);

function exportsOf(path, source, program) {
  const text = (n) => source.slice(n.start, n.end);
  const lineAt = (off) => source.slice(0, off).split("\n").length;
  const annotation = (ann) => (ann ? text(ann.typeAnnotation) : "unknown");
  const typeParamsOf = (tp) =>
    tp ? tp.params.map((p) => (p.constraint ? p.name.name + " extends " + text(p.constraint) : p.name.name)) : [];
  const params = (ps, doc) => {
    const { items, rest } = formalParams(ps);
    const out = items.map((raw, i) => {
      const p = paramParts(raw);
      const name = bindingName(p.pattern) ?? "arg" + i;
      const tag = docParam(doc, name);
      const documented = tag ? tag.tsType : null;
      let tsType;
      if (p.ann) tsType = annotation(p.ann);
      else if (documented !== null) tsType = documented;
      else if (p.init && p.init.type === "Literal" && typeof p.init.value === "boolean") tsType = "boolean";
      else if (p.init && p.init.type === "Literal" && typeof p.init.value === "number" && !p.init.bigint) tsType = "number";
      else if (p.init && (isStr(p.init) || p.init.type === "TemplateLiteral")) tsType = "string";
      else tsType = "unknown";
      return {
        name, tsType, rest: false,
        optional: p.optional || p.init !== null || (!p.ann && tag !== null && tag.optional),
      };
    });
    if (rest) {
      const name = bindingName(rest.argument) ?? "rest";
      const ann = rest.typeAnnotation ?? rest.argument.typeAnnotation ?? null;
      const tag = docParam(doc, name);
      const tsType = !ann && tag && tag.tsType !== null ? tag.tsType : annotation(ann);
      out.push({ name, tsType, optional: true, rest: true });
    }
    return out;
  };
  const returnsOf = (ann, doc) => (!ann && doc.returns !== null ? doc.returns : annotation(ann));
  const usesInstanceof = (code) => splitWords(code, "_$").includes("instanceof");
  const functionEntry = (f, doc, exported) => {
    if (!f.id) return null;
    return {
      name: exported ?? f.id.name, line: lineAt(f.start), params: params(f.params, doc),
      returns: returnsOf(f.returnType, doc), isAsync: !!f.async, isGenerator: !!f.generator,
      typeParams: typeParamsOf(f.typeParameters), usesInstanceof: usesInstanceof(text(f))
    };
  };
  const declaratorEntry = (d, doc, exported) => {
    const name = bindingName(d.id);
    if (name === null) return null;
    const f = d.init;
    if (!f || (f.type !== "ArrowFunctionExpression" && f.type !== "FunctionExpression")) return null;
    return {
      name: exported ?? name, line: lineAt(f.start), params: params(f.params, doc),
      returns: returnsOf(f.returnType, doc), isAsync: !!f.async,
      isGenerator: f.type === "FunctionExpression" ? !!f.generator : false,
      typeParams: typeParamsOf(f.typeParameters), usesInstanceof: usesInstanceof(text(f))
    };
  };
  const fns = [];
  const local = new Map();
  const listed = [];
  for (const st of program.body) {
    const doc = leadingDoc(source, st.start) ?? EMPTY_DOC;
    if (st.type === "ExportNamedDeclaration" && st.declaration) {
      const d = st.declaration;
      if (d.type === "FunctionDeclaration" && d.body) {
        const e = functionEntry(d, doc, null);
        if (e) fns.push(e);
      } else if (d.type === "VariableDeclaration") {
        for (const v of d.declarations) {
          const e = declaratorEntry(v, doc, null);
          if (e) fns.push(e);
        }
      }
    } else if (st.type === "ExportNamedDeclaration" && !st.source) {
      if (st.exportKind !== "type") {
        for (const s of st.specifiers) {
          if (s.exportKind === "type") continue;
          const nm = (n) => (n.type === "Identifier" ? n.name : strValue(n));
          listed.push([nm(s.local), nm(s.exported)]);
        }
      }
    } else if (st.type === "ExpressionStatement") {
      listed.push(...commonjsExports(st.expression));
    } else if (st.type === "FunctionDeclaration" && st.body) {
      if (st.id) local.set(st.id.name, ["f", st, doc]);
    } else if (st.type === "VariableDeclaration") {
      for (const v of st.declarations) {
        const name = bindingName(v.id);
        if (name !== null) local.set(name, ["d", v, doc]);
      }
    }
  }
  for (const [name, exported] of listed) {
    const l = local.get(name);
    if (!l) continue;
    const e = l[0] === "f" ? functionEntry(l[1], l[2], exported) : declaratorEntry(l[1], l[2], exported);
    if (e) fns.push(e);
  }
  return fns;
}

function commonjsExports(e) {
  if (e.type !== "AssignmentExpression") return [];
  const isIdent = (x, n) => x.type === "Identifier" && x.name === n;
  const isStatic = (m) => m.type === "MemberExpression" && !m.computed && m.property.type === "Identifier";
  const isModuleExports = (x) => isStatic(x) && x.property.name === "exports" && isIdent(x.object, "module");
  const m = e.left;
  if (m.type === "ParenthesizedExpression") decline("parenthesized assignment target");
  if (!isStatic(m)) return [];
  let target;
  if (m.property.name === "exports" && isIdent(m.object, "module")) target = null;
  else if (isModuleExports(m.object) || isIdent(m.object, "exports")) target = m.property.name;
  else return [];
  const r = e.right;
  if (target !== null && r.type === "Identifier") return [[r.name, target]];
  if (target === null && r.type === "ObjectExpression") {
    const out = [];
    for (const p of r.properties) {
      if (p.type !== "Property" || p.computed) continue;
      let exported;
      if (p.key.type === "Identifier") exported = p.key.name;
      else if (isStr(p.key)) exported = strValue(p.key);
      else continue;
      if (p.value.type === "Identifier" && p.kind === "init" && !p.method) out.push([p.value.name, exported]);
    }
    return out;
  }
  return [];
}

// PropertyKey::static_name: an identifier or a string (a computed string too);
// a computed expression has none; other literal keys decline.
function staticName(key, computed) {
  if (key.type === "PrivateIdentifier") return null;
  if (!computed && key.type === "Identifier") return key.name;
  if (isStr(key)) return strValue(key);
  if (computed && key.type !== "Literal" && key.type !== "TemplateLiteral") return null;
  decline("class member key");
}

function classesOf(path, source, program) {
  const text = (n) => source.slice(n.start, n.end);
  const lineAt = (off) => source.slice(0, off).split("\n").length;
  const annotation = (ann) => (ann ? text(ann.typeAnnotation) : "unknown");
  const paramsOf = (ps) =>
    formalParams(ps).items.map((raw, i) => {
      const p = paramParts(raw);
      return { name: bindingName(p.pattern) ?? "arg" + i, tsType: annotation(p.ann), optional: p.optional || p.init !== null, rest: false };
    });
  const out = [];
  for (const st of program.body) {
    if (st.type !== "ExportNamedDeclaration" || !st.declaration || st.declaration.type !== "ClassDeclaration") continue;
    const cls = st.declaration;
    if (!cls.id) continue;
    if (cls.decorators && cls.decorators.length) decline("decorated class");
    const blockers = [];
    if (cls.superClass) blockers.push("extends another class");
    const methods = [];
    for (const el of cls.body.body) {
      if (METHOD_TYPES.has(el.type)) {
        const hidden = el.key.type === "PrivateIdentifier" || el.accessibility === "private" || el.accessibility === "protected";
        if (el.kind === "constructor") {
          const items = formalParams(el.value.params).items;
          if (items.some((r) => {
            const p = paramParts(r);
            return p.accessibility === "public" || (p.readonly && p.accessibility === null);
          })) blockers.push("public parameter properties");
          continue;
        }
        if (hidden) continue;
        const name = staticName(el.key, el.computed);
        if (el.kind === "get" || el.kind === "set") {
          blockers.push("accessor `" + (name ?? "") + "`");
        } else if (el.static) {
          blockers.push("static method `" + (name ?? "") + "`");
        } else {
          if (name === null) {
            blockers.push("computed method name");
            continue;
          }
          const f = el.value;
          methods.push({ name, line: lineAt(el.start), params: paramsOf(f.params), returns: annotation(f.returnType), isAsync: !!f.async, isGenerator: !!f.generator });
        }
      } else if (el.type === "PropertyDefinition" || el.type === "TSAbstractPropertyDefinition") {
        const hidden = el.key.type === "PrivateIdentifier" || el.accessibility === "private" || el.accessibility === "protected";
        if (!hidden) blockers.push("public field `" + (staticName(el.key, el.computed) ?? "") + "`");
      } else if (el.type === "AccessorProperty" || el.type === "TSAbstractAccessorProperty") {
        blockers.push("accessor property");
      } else if (el.type === "StaticBlock") {
        blockers.push("static block");
      } else if (el.type === "TSIndexSignature") {
        // no blocker
      } else {
        decline("class element " + el.type);
      }
    }
    const name = cls.id.name;
    for (const m of methods) {
      if (m.isAsync || m.isGenerator) blockers.push("async or generator method `" + m.name + "`");
      if (splitWords(m.returns, "_").some((w) => w === name || w === "this")) blockers.push("method `" + m.name + "` returns an instance");
    }
    out.push({ name, line: lineAt(cls.start), blocker: blockers.length ? blockers.join(", ") : null, methods });
  }
  return out;
}

function localTypes(source, program) {
  const text = (n) => source.slice(n.start, n.end);
  const out = [];
  for (const st of program.body) {
    let d = null;
    if (st.type === "ExportNamedDeclaration" && st.declaration) d = st.declaration;
    else if (st.type === "TSInterfaceDeclaration" || st.type === "TSTypeAliasDeclaration") d = st;
    if (!d) continue;
    if (d.type === "TSInterfaceDeclaration") out.push({ name: d.id.name, text: text(d), alias: false });
    else if (d.type === "TSTypeAliasDeclaration") out.push({ name: d.id.name, text: text(d.typeAnnotation), alias: !d.typeParameters });
  }
  return out;
}

// ---- bridge.rs's type rules ------------------------------------------------------

function packageName(spec) {
  const parts = spec.split("/");
  const first = parts[0];
  if (first.startsWith("@")) return parts.length > 1 ? first + "/" + parts[1] : spec;
  return first;
}

function normalizeRel(path) {
  const parts = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (!parts.length) return null;
      parts.pop();
    } else parts.push(part);
  }
  return parts.join("/");
}

const WORKSPACE = new Map(req.packages);

function typesInScope(file, text) {
  const types = [];
  const seen = new Set();
  collectTypes(file, text, 0, seen, types);
  return types;
}

function collectTypes(file, text, depth, seen, types) {
  if (depth > 4 || seen.has(file)) return;
  seen.add(file);
  const r = parse(file, text);
  types.push(...localTypes(text, r.program));
  const dir = file.includes("/") ? file.slice(0, file.lastIndexOf("/")) : "";
  for (const [spec] of scanTree(r.program, text).imports) {
    let base;
    if (spec.startsWith(".")) {
      base = normalizeRel(dir ? dir + "/" + spec : spec);
      if (base === null) continue;
    } else {
      const name = packageName(spec);
      if (!WORKSPACE.has(name)) continue;
      const pkgDir = WORKSPACE.get(name);
      const sub = spec.slice(name.length).replace(/^\/+/, "");
      let src = isDir(pkgDir ? pkgDir + "/src" : "src") ? pkgDir + "/src" : pkgDir;
      src = src.replace(/^\/+/, "");
      base = sub ? src + "/" + sub : src + "/index";
    }
    let stem = base;
    while (stem.endsWith(".js")) stem = stem.slice(0, -3);
    const cands = [stem + ".ts", stem + ".mts", stem + ".d.ts", stem + "/index.ts", base];
    const found = cands.find(isFile);
    if (found === undefined) continue;
    const imported = readText(found);
    if (imported === null) continue;
    collectTypes(found, imported, depth + 1, seen, types);
  }
}

function hasFunctions(name, types, seen) {
  if (seen.includes(name)) return false;
  seen.push(name);
  const t = types.find((x) => x.name === name);
  if (!t) return false;
  const method = lines(t.text).slice(1).some((l) => {
    l = trim(l).replace(/^(readonly )+/, "");
    if (!l.includes("(")) return false;
    const head = l.split("(")[0];
    if (!head.length) return false;
    for (const c of head) if (!(isAlnum(c) || c === "_" || c === "?")) return false;
    return true;
  });
  if (t.text.includes("=>") || method) return true;
  return splitWords(t.text, "_$").filter((w) => w.length && w !== name).some((w) => hasFunctions(w, types, seen));
}

function jsOnlyReason(f, types) {
  if (f.isGenerator) return "generator";
  if (f.usesInstanceof) return "instanceof";
  const ts = f.params.map((p) => p.tsType).concat([f.returns]);
  if (ts.some((t) => t.includes("=>"))) return "function";
  for (const t of ts) {
    for (const w of splitWords(t, "_$").filter((w) => w.length)) {
      if (["RegExp", "Generator", "Iterator", "IterableIterator", "AsyncGenerator", "AsyncIterable", "Function"].includes(w)) return w;
      if (f.typeParams.includes(w)) return "generic";
      if (hasFunctions(w, types, [])) return "members";
    }
  }
  return null;
}

function replaceWord(text, word, withText) {
  let out = "";
  let cur = "";
  for (const c of [...text, " "]) {
    if (isAlnum(c) || c === "_" || c === "$") cur += c;
    else {
      out += cur === word ? withText : cur;
      cur = "";
      out += c;
    }
  }
  return out.slice(0, -1);
}

function resolveAliases(ts, types) {
  let out = ts;
  for (let k = 0; k < 4; k++) {
    let changed = false;
    let next = "";
    let word = "";
    const flush = () => {
      const t = types.find((x) => x.alias && x.name === word);
      if (t) {
        const tt = trim(t.text);
        next += tt.includes("|") ? "(" + tt + ")" : tt;
        changed = true;
      } else next += word;
      word = "";
    };
    for (const c of out) {
      if (isAlnum(c) || c === "_" || c === "$") word += c;
      else {
        flush();
        next += c;
      }
    }
    flush();
    out = next;
    if (!changed) break;
  }
  return out;
}

function substituteConstraints(f, types) {
  const remaining = [];
  for (const tp of f.typeParams) {
    const at = tp.indexOf(" extends ");
    if (at < 0) {
      remaining.push(tp);
      continue;
    }
    const name = tp.slice(0, at);
    const constraint = resolveAliases(tp.slice(at + 9), types);
    const open = constraint.includes("=>") || splitWords(constraint, "_").some((w) =>
      ["Function", "object", "unknown", "any"].includes(w) || hasFunctions(w, types, []));
    if (open) {
      remaining.push(name);
      continue;
    }
    const rep = "(" + constraint + ")";
    for (const p of f.params) p.tsType = replaceWord(p.tsType, name, rep);
    f.returns = replaceWord(f.returns, name, rep);
  }
  f.typeParams = remaining;
}

// ---- tsconfig.rs -----------------------------------------------------------------

function tsJoin(dir, rel) {
  const parts = dir.split("/").filter((p) => p.length);
  for (const part of rel.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return parts.join("/");
}

const JSON5_NUMBER = /^(0|[1-9]\d*)(\.\d*)?([eE][+-]?\d+)?$|^\.\d+([eE][+-]?\d+)?$|^0[xX][0-9a-fA-F]+$/;

// json5::from_str into a serde_json Value: oxc reads the text as a JS
// expression (JSON5 is a subset), and only JSON5's forms are taken; any other
// form, a duplicate key, an escape or a number serde may not hold declines.
function json5Value(text) {
  if (text.startsWith("#!") || text.startsWith("﻿")) decline("tsconfig start");
  const r = parseSync("tsconfig.mjs", "(" + text + "\n)");
  if (r.errors.length) return undefined; // json5 refuses what JS refuses
  const body = r.program.body;
  if (body.length !== 1 || body[0].type !== "ExpressionStatement" || body[0].expression.type !== "ParenthesizedExpression") decline("tsconfig shape");
  const value = (n) => {
    switch (n.type) {
      case "ObjectExpression": {
        const o = new Map();
        for (const p of n.properties) {
          if (p.type !== "Property" || p.computed || p.method || p.shorthand || p.kind !== "init") decline("tsconfig member");
          let k;
          if (p.key.type === "Identifier") {
            if (source(p.key).includes("\\")) decline("tsconfig key escape");
            k = p.key.name;
          } else if (isStr(p.key)) {
            if (source(p.key).includes("\\")) decline("tsconfig string escape");
            k = p.key.value;
          } else decline("tsconfig key");
          if (o.has(k)) decline("tsconfig duplicate key");
          o.set(k, value(p.value));
        }
        return o;
      }
      case "ArrayExpression":
        return n.elements.map((e) => {
          if (e === null || e.type === "SpreadElement") decline("tsconfig array");
          return value(e);
        });
      case "Literal":
        if (n.regex || n.bigint !== undefined && n.bigint !== null) decline("tsconfig literal");
        if (typeof n.value === "string") {
          if (source(n).includes("\\")) decline("tsconfig string escape");
          return n.value;
        }
        if (typeof n.value === "number") {
          if (!JSON5_NUMBER.test(source(n)) || !Number.isFinite(n.value) || Math.abs(n.value) > 1e300) decline("tsconfig number");
          return n.value;
        }
        return n.value; // true, false, null
      case "UnaryExpression":
        if ((n.operator === "-" || n.operator === "+") && n.argument.type === "Literal" && typeof n.argument.value === "number") return value(n.argument);
        decline("tsconfig unary");
      default:
        decline("tsconfig value " + n.type);
    }
  };
  const src = "(" + text + "\n)";
  const source = (n) => src.slice(n.start, n.end);
  return value(body[0].expression.expression);
}

const get = (v, k) => (v instanceof Map && v.has(k) ? v.get(k) : null);

function loadConfig(rel, depth) {
  if (depth > 8) return null;
  const text = readText(rel);
  if (text === null) return null;
  for (const c of text) if (c.charCodeAt(0) > 127) decline("tsconfig outside ASCII");
  const json = json5Value(text);
  if (json === undefined) return null;
  const dir = rel.includes("/") ? rel.slice(0, rel.lastIndexOf("/")) : "";
  const ext = get(json, "extends");
  const extendsList = typeof ext === "string" ? [ext] : Array.isArray(ext) ? ext.filter((x) => typeof x === "string") : [];
  const config = { baseUrl: null, paths: null };
  const overlay = (later) => {
    config.baseUrl = later.baseUrl ?? config.baseUrl;
    config.paths = later.paths ?? config.paths;
  };
  for (const parent of extendsList.filter((p) => p.startsWith("."))) {
    let target = tsJoin(dir, parent);
    if (!target.endsWith(".json")) target += ".json";
    const p = loadConfig(target, depth + 1);
    if (p) overlay(p);
  }
  const options = get(json, "compilerOptions");
  const paths = get(options, "paths");
  let p = null;
  if (paths instanceof Map) {
    p = { dir, entries: [...paths].map(([pattern, targets]) => [pattern, Array.isArray(targets) ? targets.filter((t) => typeof t === "string") : []]) };
  }
  const base = get(options, "baseUrl");
  overlay({ baseUrl: typeof base === "string" ? tsJoin(dir, base) : null, paths: p });
  return config;
}

function nearestAliases(dir) {
  let current = dir.replace(/\/+$/, "");
  for (;;) {
    const candidate = current ? current + "/tsconfig.json" : "tsconfig.json";
    if (isFile(candidate)) {
      const c = loadConfig(candidate, 0);
      if (!c || !c.paths) return [];
      const base = c.baseUrl ?? c.paths.dir;
      return c.paths.entries.map(([pattern, targets]) => [pattern, targets.map((t) => tsJoin(base, t))]);
    }
    if (!current) return [];
    current = current.includes("/") ? current.slice(0, current.lastIndexOf("/")) : "";
  }
}

// ---- ts/mod.rs ---------------------------------------------------------------------

function scriptOf(path, text) {
  if (![".vue", ".svelte", ".astro"].some((e) => path.endsWith(e))) return text;
  let out = "";
  let rest = text;
  const newlines = (s) => s.replace(/[^\n]/g, "");
  for (;;) {
    const open = rest.indexOf("<script");
    if (open < 0) break;
    out += newlines(rest.slice(0, open));
    const afterOpen = rest.slice(open);
    const tagEnd = afterOpen.indexOf(">");
    if (tagEnd < 0) break;
    out += newlines(afterOpen.slice(0, tagEnd + 1));
    const body = afterOpen.slice(tagEnd + 1);
    let close = body.indexOf("</script>");
    if (close < 0) close = body.length;
    out += body.slice(0, close) + "\n";
    rest = body.slice(close);
    if (rest.startsWith("</script>")) rest = rest.slice(9);
  }
  return out;
}

// ---- the request ---------------------------------------------------------------------

// PathAliases::candidates: the targets of the longest matching pattern (an
// exact one wins), `*` replaced; weights are byte lengths (tsconfig text is
// ASCII here).
function candidates(entries, spec) {
  let best = null;
  for (const [pattern, targets] of entries) {
    let matched = null;
    const star = pattern.indexOf("*");
    if (star >= 0) {
      const prefix = pattern.slice(0, star), suffix = pattern.slice(star + 1);
      if (spec.startsWith(prefix)) {
        const rest = spec.slice(prefix.length);
        if (rest.endsWith(suffix)) matched = [prefix.length, rest.slice(0, rest.length - suffix.length)];
      }
    } else if (pattern === spec) matched = [Infinity, ""];
    if (matched && (best === null || matched[0] > best[0])) best = [matched[0], targets, matched[1]];
  }
  return best ? best[1].map((t) => t.replace("*", () => best[2])) : [];
}

const aliasCache = new Map();
function aliasesOf(dir) {
  if (!aliasCache.has(dir)) aliasCache.set(dir, nearestAliases(dir));
  return aliasCache.get(dir);
}

function main() {
  const files = [];
  for (const f of req.files) {
    const text = readText(f.path);
    if (text === null) {
      files.push({ status: "unreadable" });
      continue;
    }
    const code = scriptOf(f.path, text);
    const r = parse(f.parse_as, code);
    const facts = scanTree(r.program, code);
    const dir = f.path.includes("/") ? f.path.slice(0, f.path.lastIndexOf("/")) : "";
    // analyze.rs `classify`'s order: relative, a runtime, a tsconfig alias.
    const imports = facts.imports.map(([spec, typeOnly]) => {
      const relative = spec.startsWith("./") || spec.startsWith("../") || spec === "." || spec === "..";
      const platform = !relative && platformOf(spec) !== null;
      const cands = relative || platform ? [] : candidates(aliasesOf(dir), spec);
      if (hasLoneSurrogate(spec)) decline("import specifier");
      return [spec, typeOnly, platform, packageName(spec), cands];
    });
    const out = {
      status: "ok", loc: locOf(code), parse_errors: r.errors.length, imports,
      risks: facts.risks, platforms: [...facts.platforms], loops: facts.loops, exports: 0, bridgeable: 0,
    };
    if (f.exports) {
      const own = parse(f.path, text);
      const types = typesInScope(f.path, text);
      const fns = exportsOf(f.path, text, own.program);
      for (const fn of fns) {
        out.exports++;
        substituteConstraints(fn, types);
        if (jsOnlyReason(fn, types) === null) out.bridgeable++;
      }
      for (const c of classesOf(f.path, text, own.program)) {
        out.exports++;
        if (c.blocker === null) out.bridgeable++;
      }
    }
    files.push(out);
  }
  return { files };
}

let answer;
try {
  answer = main();
} catch (e) {
  if (!(e instanceof Decline)) throw e;
  answer = { decline: e.message };
}
process.stdout.write(JSON.stringify(answer));
