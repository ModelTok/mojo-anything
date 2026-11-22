//! Go: the cgo wrapper package (the original API over the Mojo library), and the driver that
//! calls a package's functions by name for record, diff and bench.

use std::fmt::Write as _;
use std::path::Path;

use crate::bridge::Manifest;
use crate::ts::exports::ExportedFn;

/// The result types of a Go function, without the trailing `error`, and whether it has one.
pub fn results(f: &ExportedFn) -> (Vec<String>, bool) {
    let text = f.native_return.as_deref().unwrap_or("()");
    let inner = text.trim().trim_start_matches('(').trim_end_matches(')');
    let mut parts = split_top(inner);
    let fallible = parts.last().is_some_and(|p| p == "error");
    if fallible {
        parts.pop();
    }
    (parts, fallible)
}

fn split_top(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut current = String::new();
    for c in text.chars() {
        match c {
            '[' | '(' | '{' => depth += 1,
            ']' | ')' | '}' => depth -= 1,
            ',' if depth == 0 => {
                out.push(current.trim().to_string());
                current.clear();
                continue;
            }
            _ => {}
        }
        current.push(c);
    }
    if !current.trim().is_empty() {
        out.push(current.trim().to_string());
    }
    out
}

/// Exported identifiers in a Go type: the package's own named types.
fn local_types(t: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut word = String::new();
    let mut prev = ' ';
    for c in t.chars().chain(std::iter::once(' ')) {
        if c.is_alphanumeric() || c == '_' {
            word.push(c);
            continue;
        }
        if !word.is_empty() {
            if word.starts_with(char::is_uppercase) && prev != '.' {
                out.push(std::mem::take(&mut word));
            }
            word.clear();
        }
        prev = c;
    }
    out
}

/// `t` with the package's named types qualified as `pkg.Name`.
fn qualify(t: &str) -> String {
    let mut out = String::new();
    let mut word = String::new();
    let mut prev = ' ';
    for c in t.chars().chain(std::iter::once('\0')) {
        if c.is_alphanumeric() || c == '_' {
            word.push(c);
            continue;
        }
        if !word.is_empty() {
            if word.starts_with(char::is_uppercase) && prev != '.' {
                out.push_str("pkg.");
            }
            out.push_str(&word);
            word.clear();
        }
        if c != '\0' {
            out.push(c);
        }
        prev = c;
    }
    out
}

/// Every named type the exported signatures use.
pub fn used_types(m: &Manifest) -> Vec<String> {
    let mut names: Vec<String> = m
        .exports
        .iter()
        .flat_map(|f| {
            f.params
                .iter()
                .filter_map(|p| p.native_type.clone())
                .chain(results(f).0)
                .collect::<Vec<_>>()
        })
        .flat_map(|t| local_types(&t))
        .collect();
    names.sort();
    names.dedup();
    names
}

/// The Go sources of the unit (not tests).
pub fn unit_sources(m: &Manifest) -> Vec<String> {
    let dir = m.root.join(m.unit.trim_end_matches('/'));
    let dir = if dir.is_file() {
        dir.parent().map(Path::to_path_buf).unwrap_or(dir)
    } else {
        dir
    };
    let mut files: Vec<_> = std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.extension().is_some_and(|e| e == "go") && !p.to_string_lossy().ends_with("_test.go")
        })
        .collect();
    files.sort();
    files
        .iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .collect()
}

pub fn package_name(m: &Manifest) -> String {
    unit_sources(m)
        .iter()
        .find_map(|s| crate::lang::go::package_name(s))
        .unwrap_or_else(|| "port".into())
}

/// JSON helpers shared by the wrapper and the driver.
const HELPERS_GO: &str = r#"
// mojoAnythingDecode decodes JSON into target; floats may be {"$num": "NaN" | "Infinity" | ...}.
func mojoAnythingDecode(raw json.RawMessage, target any) error {
	if f, ok := target.(*float64); ok && len(raw) > 0 && raw[0] == '{' {
		var marker map[string]string
		if err := json.Unmarshal(raw, &marker); err != nil {
			return err
		}
		switch marker["$num"] {
		case "NaN":
			*f = math.NaN()
		case "Infinity":
			*f = math.Inf(1)
		case "-Infinity":
			*f = math.Inf(-1)
		case "-0":
			*f = math.Copysign(0, -1)
		default:
			return errors.New("not a number")
		}
		return nil
	}
	if len(raw) == 0 {
		raw = json.RawMessage("null")
	}
	return json.Unmarshal(raw, target)
}

// mojoAnythingEncode marks the floats JSON cannot carry.
func mojoAnythingEncode(v any) any {
	var f float64
	switch x := v.(type) {
	case float64:
		f = x
	case float32:
		f = float64(x)
	default:
		return v
	}
	switch {
	case math.IsNaN(f):
		return map[string]string{"$num": "NaN"}
	case math.IsInf(f, 1):
		return map[string]string{"$num": "Infinity"}
	case math.IsInf(f, -1):
		return map[string]string{"$num": "-Infinity"}
	case f == 0 && math.Signbit(f):
		return map[string]string{"$num": "-0"}
	}
	return v
}
"#;

/// The Mojo source a Go unit's library is built from.
pub const EXPORTS: &str = "exports.mojo";

/// Whether some function of the unit goes through the JSON dispatcher.
pub fn uses_dispatcher(m: &Manifest, api: &crate::codegen::PortApi) -> bool {
    api.functions.iter().any(|f| typed(m, f).is_none())
}

/// The wrapper package: the original package's API, each function calling the Mojo library.
pub fn wrapper(m: &Manifest, api: &crate::codegen::PortApi) -> String {
    let lib = m.lib_name();
    let sources = unit_sources(m);
    let types = crate::lang::go::type_decls(&sources, &used_types(m));
    let dispatcher = uses_dispatcher(m, api);
    let call_c = if dispatcher {
        "char *mojo_anything_call(const char *name, const char *args);\n"
    } else {
        ""
    };
    let mut out = format!(
        "// Package {pkg} is the Mojo port of `{unit}`, generated by mojo-anything: the same API, each\n\
         // function calling the Mojo library. Regenerate with `mojo-anything refresh`.\n\
         package {pkg}\n\n\
         /*\n#cgo LDFLAGS: -L${{SRCDIR}}/../{build} -l{lib} -Wl,-rpath,${{SRCDIR}}/../{build}\n\
         #include <stdint.h>\n#include <stdlib.h>\n\
         {call_c}void mojo_anything_free(char *ptr);\n{typed_c}*/\nimport \"C\"\n\n\
         import (\n\t\"encoding/json\"\n\t\"errors\"\n\t\"fmt\"\n\t\"math\"\n\t\"reflect\"\n\t\"unicode/utf8\"\n\t\"unsafe\"\n)\n\n\
         var _ = json.Marshal\nvar _ = errors.New\nvar _ = fmt.Sprint\nvar _ = math.NaN\nvar _ = reflect.ValueOf\n\
         var _ = utf8.ValidString\nvar _ = unsafe.Pointer(nil)\n",
        pkg = package_name(m),
        unit = m.unit,
        build = crate::harness_mojo_c::BUILD_DIR,
        typed_c = typed_prototypes(m, api),
    );
    for t in types {
        let _ = write!(out, "\n{t}\n");
    }
    out.push_str(HELPERS_GO);
    if dispatcher {
        out.push_str(CALL_GO);
    }
    let typed_fns: Vec<&str> = api
        .functions
        .iter()
        .filter(|f| typed(m, f).is_some())
        .map(|f| f.js_name.as_str())
        .collect();
    if !typed_fns.is_empty() {
        out.push_str(TYPED_HELPERS_GO);
    }
    for f in &m.exports {
        if typed_fns.contains(&f.name.as_str()) {
            out.push_str(&typed_go(f));
            continue;
        }
        let (results, fallible) = results(f);
        let params = wrapper_params(f);
        let mut all_results = results.clone();
        if fallible {
            all_results.push("error".into());
        }
        let ret = match all_results.len() {
            0 => String::new(),
            1 => format!(" {}", all_results[0]),
            _ => format!(" ({})", all_results.join(", ")),
        };
        let args: Vec<String> = (0..f.params.len()).map(wrapper_arg).collect();
        let call_args = if args.is_empty() {
            String::new()
        } else {
            format!(", {}", args.join(", "))
        };
        let _ = writeln!(
            out,
            "\n// {} is the Mojo port of `{}` (`{}:{}`).\nfunc {}({}){ret} {{",
            f.name,
            f.prototype.as_deref().unwrap_or(&f.name),
            f.file,
            f.line,
            f.name,
            params
        );
        let names: Vec<String> = (0..results.len()).map(|i| format!("r{i}")).collect();
        let decls: String = results
            .iter()
            .enumerate()
            .map(|(i, t)| format!("\tvar r{i} {t}\n"))
            .collect();
        let raw = if results.is_empty() { "_" } else { "raw" };
        let _ = writeln!(
            out,
            "\t{raw}, err := mojoAnythingCall(\"{}\"{call_args})",
            f.name
        );
        if fallible {
            let _ = writeln!(out, "\tif err != nil {{\n{decls}\t\treturn {}\n\t}}", {
                let mut r = names.clone();
                r.push("err".into());
                r.join(", ")
            });
        } else {
            out.push_str("\tmojoAnythingMust(err)\n");
        }
        out.push_str(&decls);
        match results.len() {
            0 => {}
            1 => out.push_str("\tmojoAnythingMust(mojoAnythingDecode(raw, &r0))\n"),
            n => {
                let _ = writeln!(
                    out,
                    "\tvar parts []json.RawMessage\n\tmojoAnythingMust(json.Unmarshal(raw, &parts))\n\
                     \tif len(parts) != {n} {{\n\t\tpanic(\"mojo-anything: expected {n} results\")\n\t}}"
                );
                for i in 0..n {
                    let _ = writeln!(
                        out,
                        "\tmojoAnythingMust(mojoAnythingDecode(parts[{i}], &r{i}))"
                    );
                }
            }
        }
        let mut r = names;
        if fallible {
            r.push("nil".into());
        }
        if r.is_empty() {
            out.push_str("}\n");
        } else {
            let _ = writeln!(out, "\treturn {}\n}}", r.join(", "));
        }
    }
    out
}

/// The Go side of the JSON dispatcher.
const CALL_GO: &str = r#"
type mojoAnythingAnswer struct {
	Ok    json.RawMessage `json:"ok"`
	Error *string         `json:"error"`
	Panic *string         `json:"panic"`
}

// mojoAnythingValidUTF8 says whether every string in v is UTF-8: json.Marshal would replace
// invalid bytes with U+FFFD and the port would see other text.
func mojoAnythingValidUTF8(v reflect.Value) bool {
	switch v.Kind() {
	case reflect.String:
		return utf8.ValidString(v.String())
	case reflect.Pointer, reflect.Interface:
		return v.IsNil() || mojoAnythingValidUTF8(v.Elem())
	case reflect.Slice, reflect.Array:
		if v.Kind() == reflect.Slice && v.Type().Elem().Kind() == reflect.Uint8 {
			return true // []byte crosses as base64
		}
		for i := 0; i < v.Len(); i++ {
			if !mojoAnythingValidUTF8(v.Index(i)) {
				return false
			}
		}
	case reflect.Map:
		for it := v.MapRange(); it.Next(); {
			if !mojoAnythingValidUTF8(it.Key()) || !mojoAnythingValidUTF8(it.Value()) {
				return false
			}
		}
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			if v.Type().Field(i).IsExported() && !mojoAnythingValidUTF8(v.Field(i)) {
				return false
			}
		}
	}
	return true
}

func mojoAnythingCall(name string, args ...any) (json.RawMessage, error) {
	for i, a := range args {
		if !mojoAnythingValidUTF8(reflect.ValueOf(a)) {
			panic(fmt.Sprintf("mojo-anything: argument %d of %s holds invalid UTF-8, which the JSON dispatcher cannot carry", i+1, name))
		}
		args[i] = mojoAnythingEncode(a)
	}
	encoded, err := json.Marshal(args)
	if err != nil {
		panic(err)
	}
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))
	cArgs := C.CString(string(encoded))
	defer C.free(unsafe.Pointer(cArgs))
	answer := C.mojo_anything_call(cName, cArgs)
	if answer == nil {
		panic("mojo-anything: the dispatcher could not allocate its answer")
	}
	defer C.mojo_anything_free(answer)
	var a mojoAnythingAnswer
	if err := json.Unmarshal([]byte(C.GoString(answer)), &a); err != nil {
		panic(err)
	}
	if a.Panic != nil {
		panic(*a.Panic)
	}
	if a.Error != nil {
		return nil, errors.New(*a.Error)
	}
	return a.Ok, nil
}

func mojoAnythingMust(err error) {
	if err != nil {
		panic(err)
	}
}
"#;

// ---- typed calls: numbers, booleans and strings cross cgo without JSON ----------------------

/// A Go type that crosses cgo directly: its C type and the Mojo type the port must keep.
pub(crate) struct Typed {
    pub c: &'static str,
    pub port: String,
}

pub(crate) fn typed_type(go: &str) -> Option<Typed> {
    let c = match go.trim() {
        "int" | "int8" | "int16" | "int32" | "int64" | "uint8" | "uint16" | "uint32" | "byte"
        | "rune" => "int64_t",
        "uint" | "uint64" | "uintptr" => "uint64_t",
        "float64" | "float32" => "double",
        "bool" => "uint8_t",
        "string" => "string",
        _ => return None,
    };
    Some(Typed {
        c,
        port: crate::codegen_mojo::go_mojo_type(go),
    })
}

/// Whether a function crosses as a typed cgo call: typed parameters, and no result, one typed
/// result, or one with a trailing `error`; the port kept the matching Mojo types.
fn typed<'m>(m: &'m Manifest, f: &crate::codegen::PortFn) -> Option<&'m ExportedFn> {
    let e = m.exports.iter().find(|e| e.name == f.js_name)?;
    if e.params.len() != f.params.len() {
        return None;
    }
    for (p, (_, port)) in e.params.iter().zip(&f.params) {
        if typed_type(p.native_type.as_deref()?)?.port != *port {
            return None;
        }
    }
    let (results, _) = results(e);
    match results.as_slice() {
        [] => (f.ret == "None").then_some(e),
        [r] => (typed_type(r)?.port == f.ret).then_some(e),
        _ => None,
    }
}

/// The C parameters of a typed export, as the cgo preamble declares them.
fn typed_c_params(e: &ExportedFn) -> Vec<String> {
    let mut params: Vec<String> = Vec::new();
    for (index, p) in e.params.iter().enumerate() {
        let name = format!("ra_arg{index}");
        let t = typed_type(p.native_type.as_deref().unwrap_or_default()).expect("typed");
        if t.c == "string" {
            params.push(format!("const uint8_t *{name}_ptr, size_t {name}_len"));
        } else {
            params.push(format!("{} {name}", t.c));
        }
    }
    match results(e).0.first().and_then(|r| typed_type(r)) {
        Some(t) if t.c == "string" => {
            params.push("uint8_t *out, size_t out_cap, size_t *out_len".into())
        }
        Some(t) => params.push(format!("{} *out", t.c)),
        None => {}
    }
    params.push("char **err".into());
    params
}

/// C prototypes of the typed functions, for the cgo preamble.
fn typed_prototypes(m: &Manifest, api: &crate::codegen::PortApi) -> String {
    let mut out = String::new();
    for f in &api.functions {
        let Some(e) = typed(m, f) else { continue };
        let _ = writeln!(
            out,
            "int mojo_anything_t_{}({});",
            f.js_name,
            typed_c_params(e).join(", ")
        );
    }
    out
}

const TYPED_HELPERS_GO: &str = r#"
// mojoAnythingStr is a string's bytes for C, without copying; nil for "".
func mojoAnythingStr(s string) *C.uint8_t {
	if len(s) == 0 {
		return nil
	}
	return (*C.uint8_t)(unsafe.Pointer(unsafe.StringData(s)))
}

// mojoAnythingBool is a bool for C.
func mojoAnythingBool(b bool) C.uint8_t {
	if b {
		return 1
	}
	return 0
}

// mojoAnythingErr takes the error message the Mojo side allocated.
func mojoAnythingErr(p *C.char) string {
	msg := C.GoString(p)
	C.mojo_anything_free(p)
	return msg
}
"#;

fn wrapper_arg(index: usize) -> String {
    format!("raArg{index}")
}

fn wrapper_params(export: &ExportedFn) -> String {
    export
        .params
        .iter()
        .enumerate()
        .map(|(index, param)| {
            format!(
                "{} {}",
                wrapper_arg(index),
                param.native_type.as_deref().unwrap_or("any")
            )
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// The Go wrapper function of a typed export: one cgo call, retried once with a bigger buffer
/// when a string result does not fit.
fn typed_go(e: &ExportedFn) -> String {
    let (results, fallible) = results(e);
    let result = results.first().cloned();
    let params = wrapper_params(e);
    let mut sig_results: Vec<String> = result.iter().cloned().collect();
    if fallible {
        sig_results.push("error".into());
    }
    let ret = match sig_results.len() {
        0 => String::new(),
        1 => format!(" {}", sig_results[0]),
        _ => format!(" ({})", sig_results.join(", ")),
    };
    let mut args: Vec<String> = Vec::new();
    for (index, p) in e.params.iter().enumerate() {
        let name = wrapper_arg(index);
        let t = typed_type(p.native_type.as_deref().unwrap_or_default()).expect("typed");
        match t.c {
            "string" => {
                args.push(format!("mojoAnythingStr({name})"));
                args.push(format!("C.size_t(len({name}))"));
            }
            "uint8_t" => args.push(format!("mojoAnythingBool({name})")),
            c => args.push(format!("C.{c}({name})")),
        }
    }
    let rt = result.as_deref().and_then(typed_type);
    let mut body = String::new();
    let zero = match (&result, rt.as_ref().map(|t| t.c)) {
        (_, Some("string")) => "\"\"".to_string(),
        (_, Some("uint8_t")) => "false".to_string(),
        (Some(_), _) => "0".to_string(),
        _ => String::new(),
    };
    let fail = |body: &mut String| {
        if fallible {
            let ret = if zero.is_empty() {
                "errors.New(mojoAnythingErr(errp))".to_string()
            } else {
                format!("{zero}, errors.New(mojoAnythingErr(errp))")
            };
            let _ = writeln!(body, "\tif status == 1 {{\n\t\treturn {ret}\n\t}}");
        } else {
            let _ = writeln!(
                body,
                "\tif status == 1 {{\n\t\tpanic(mojoAnythingErr(errp))\n\t}}"
            );
        }
    };
    body.push_str("\tvar errp *C.char\n");
    let ok_tail = if fallible { ", nil" } else { "" };
    match rt.as_ref().map(|t| t.c) {
        Some("string") => {
            let call = |buf: &str| {
                let mut a = args.clone();
                a.push(format!("(*C.uint8_t)(unsafe.Pointer(&{buf}[0]))"));
                a.push(format!("C.size_t(len({buf}))"));
                a.push("&n".into());
                a.push("&errp".into());
                format!("C.mojo_anything_t_{}({})", e.name, a.join(", "))
            };
            let _ = writeln!(
                body,
                "\tvar stack [256]byte\n\tbuf := stack[:]\n\tvar n C.size_t\n\tstatus := {}",
                call("buf")
            );
            let _ = writeln!(
                body,
                "\tfor status == 2 {{\n\t\tbuf = make([]byte, int(n))\n\t\tstatus = {}\n\t}}",
                call("buf")
            );
            fail(&mut body);
            let _ = writeln!(body, "\treturn string(buf[:n]){ok_tail}");
        }
        Some(c) => {
            let mut a = args.clone();
            a.push("&out".into());
            a.push("&errp".into());
            let _ = writeln!(
                body,
                "\tvar out C.{c}\n\tstatus := C.mojo_anything_t_{}({})",
                e.name,
                a.join(", ")
            );
            fail(&mut body);
            if c == "uint8_t" {
                let _ = writeln!(body, "\treturn out != 0{ok_tail}");
            } else {
                let _ = writeln!(
                    body,
                    "\treturn {}(out){ok_tail}",
                    result.as_deref().unwrap_or_default()
                );
            }
        }
        None => {
            let mut a = args.clone();
            a.push("&errp".into());
            let _ = writeln!(
                body,
                "\tstatus := C.mojo_anything_t_{}({})",
                e.name,
                a.join(", ")
            );
            fail(&mut body);
            if fallible {
                body.push_str("\treturn nil\n");
            }
        }
    }
    format!(
        "\n// {} is the Mojo port of `{}` (`{}:{}`): a typed call, no JSON.\nfunc {}({}){ret} {{\n{body}}}\n",
        e.name,
        e.prototype.as_deref().unwrap_or(&e.name),
        e.file,
        e.line,
        e.name,
        params
    )
}

/// Helpers of the typed exports in `exports.mojo`.
const TYPED_HELPERS_MOJO: &str = r#"

def _go_str(p: Optional[Pointer[UInt8, ImmutAnyOrigin]], n: UInt) -> String:
    # SAFETY: Go passes a string's bytes and length, or NULL for "". The bytes are copied as they
    # are: a Go string need not be UTF-8.
    if not p or n == 0:
        return String()
    return String(
        unsafe_from_utf8=Span[UInt8, ImmutAnyOrigin](unsafe_ptr=p.value(), length=Int(n))
    )


def _fail(err: Optional[Pointer[Int, MutAnyOrigin]], message: String) -> Int32:
    # The message for Go, allocated with malloc and freed by `mojo_anything_free`.
    var b = message.as_bytes()
    var n = len(b)
    var p = external_call["malloc", Optional[Pointer[UInt8, MutAnyOrigin]]](n + 1)
    if p and err:
        var q = p.value()
        for i in range(n):
            q[unsafe_offset=i] = b[i] if b[i] != 0 else 32
        q[unsafe_offset=n] = 0
        err.value()[] = Int(q)
    return 1
"#;

/// The Mojo type of a typed export's C argument.
fn c_mojo(c: &str) -> &'static str {
    match c {
        "int64_t" => "Int64",
        "uint64_t" => "UInt64",
        "double" => "Float64",
        _ => "UInt8",
    }
}

/// `exports.mojo` of a Go unit: one `mojo_anything_t_<name>` per typed function (status 0 ok,
/// 1 error with the message in `err`, 2 the string result needs `*out_len` bytes), the JSON
/// dispatcher when some function needs it, and `mojo_anything_free`.
pub fn typed_mojo(m: &Manifest, api: &crate::codegen::PortApi) -> Result<String, String> {
    let mut out = if uses_dispatcher(m, api) {
        crate::codegen_ffi::dispatcher_mojo(m, api)?
    } else {
        format!(
            "# Typed C exports for the Mojo port of `{}`, generated by mojo-anything. Regenerate\n\
             # with `mojo-anything refresh`.\n\n\
             from std.ffi import external_call\nfrom std.memory import Pointer\n\n\
             import port\n\n\n\
             @export\n\
             def mojo_anything_free(p: Optional[Pointer[Int8, MutAnyOrigin]]) abi(\"C\"):\n    \
             if p:\n        external_call[\"free\", NoneType](p.value())\n",
            m.unit
        )
    };
    let typed_fns: Vec<(&crate::codegen::PortFn, &ExportedFn)> = api
        .functions
        .iter()
        .filter_map(|f| typed(m, f).map(|e| (f, e)))
        .collect();
    if typed_fns.is_empty() {
        return Ok(out);
    }
    out.push_str(TYPED_HELPERS_MOJO);
    for (f, e) in typed_fns {
        let mut params = Vec::new();
        let mut args = Vec::new();
        for (i, (p, (_, port))) in e.params.iter().zip(&f.params).enumerate() {
            let t = typed_type(p.native_type.as_deref().unwrap_or_default()).expect("typed");
            if t.c == "string" {
                params.push(format!(
                    "a{i}_ptr: Optional[Pointer[UInt8, ImmutAnyOrigin]], a{i}_len: UInt"
                ));
                args.push(format!("_go_str(a{i}_ptr, a{i}_len)"));
            } else {
                params.push(format!("a{i}: {}", c_mojo(t.c)));
                args.push(if port == "Bool" {
                    format!("a{i} != 0")
                } else {
                    format!("{port}(a{i})")
                });
            }
        }
        let rt = results(e).0.first().and_then(|r| typed_type(r));
        let call = format!("port.{}({})", f.rust_name, args.join(", "));
        let ok = match rt.as_ref().map(|t| t.c) {
            Some("string") => {
                params.push(
                    "res: Optional[Pointer[UInt8, MutAnyOrigin]], res_cap: UInt, \
                     res_len: Optional[Pointer[UInt, MutAnyOrigin]]"
                        .into(),
                );
                format!(
                    "var value = {call}\n        var b = value.as_bytes()\n        \
                     res_len.value()[] = UInt(len(b))\n        if len(b) > Int(res_cap):\n            \
                     return 2\n        if len(b) > 0:\n            var o = res.value()\n            \
                     for i in range(len(b)):\n                o[unsafe_offset=i] = b[i]\n        return 0"
                )
            }
            Some(c) => {
                let mojo = c_mojo(c);
                params.push(format!("res: Optional[Pointer[{mojo}, MutAnyOrigin]]"));
                let value = if mojo == "UInt8" {
                    "UInt8(1) if value else UInt8(0)".to_string()
                } else {
                    format!("{mojo}(value)")
                };
                format!("var value = {call}\n        res.value()[] = {value}\n        return 0")
            }
            None => format!("{call}\n        return 0"),
        };
        params.push("err: Optional[Pointer[Int, MutAnyOrigin]]".into());
        let _ = writeln!(
            out,
            "\n\n# `{proto}`: a typed call.\n@export\ndef mojo_anything_t_{name}(\n    {params},\n) abi(\"C\") -> Int32:\n    \
             try:\n        {ok}\n    except e:\n        return _fail(err, String(e))",
            proto = e.prototype.as_deref().unwrap_or(&e.name),
            name = f.js_name,
            params = params.join(",\n    "),
        );
    }
    Ok(out)
}

/// A `main` package that calls `import_path`'s functions by name: record, diff and bench.
pub fn driver(m: &Manifest, import_path: &str) -> String {
    let mut cases = String::new();
    let mut prepares = String::new();
    for f in &m.exports {
        let (results, fallible) = results(f);
        let _ = writeln!(cases, "\tcase \"{}\":", f.name);
        let mut args = Vec::new();
        for (i, p) in f.params.iter().enumerate() {
            let t = qualify(p.native_type.as_deref().unwrap_or("any"));
            let _ = writeln!(
                cases,
                "\t\tvar a{i} {t}\n\t\tif mojoAnythingDecode(argAt(args, {i}), &a{i}) != nil {{\n\t\t\treturn invalid\n\t\t}}"
            );
            args.push(format!("a{i}"));
        }
        let _ = writeln!(prepares, "\tcase \"{}\":", f.name);
        for (i, p) in f.params.iter().enumerate() {
            let t = qualify(p.native_type.as_deref().unwrap_or("any"));
            let _ = writeln!(
                prepares,
                "\t\tvar a{i} {t}\n\t\tif mojoAnythingDecode(argAt(args, {i}), &a{i}) != nil {{\n\t\t\treturn nil\n\t\t}}"
            );
        }
        let _ = writeln!(
            prepares,
            "\t\treturn func() {{ pkg.{}({}) }}",
            f.name,
            args.join(", ")
        );
        let mut lhs: Vec<String> = (0..results.len()).map(|i| format!("r{i}")).collect();
        if fallible {
            lhs.push("err".into());
        }
        let call = format!("pkg.{}({})", f.name, args.join(", "));
        if lhs.is_empty() {
            let _ = writeln!(cases, "\t\t{call}");
        } else {
            let _ = writeln!(cases, "\t\t{} := {call}", lhs.join(", "));
        }
        if fallible {
            cases.push_str(
                "\t\tif err != nil {\n\t\t\treturn map[string]any{\"error\": err.Error()}\n\t\t}\n",
            );
        }
        let ok = match results.len() {
            0 => "nil".to_string(),
            1 => "mojoAnythingEncode(r0)".to_string(),
            n => format!(
                "[]any{{{}}}",
                (0..n)
                    .map(|i| format!("mojoAnythingEncode(r{i})"))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        };
        let _ = writeln!(cases, "\t\treturn map[string]any{{\"ok\": {ok}}}");
    }
    DRIVER_GO
        .replace("IMPORT_PATH", import_path)
        .replace("// CASES\n", &cases)
        .replace("// PREPARES\n", &prepares)
        .replace("// HELPERS\n", HELPERS_GO)
}

const DRIVER_GO: &str = r#"// Generated by mojo-anything: calls the package's functions by name.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"strings"
	"time"

	pkg "IMPORT_PATH"
)

var _ = errors.New
var _ = strings.Contains

// HELPERS

var invalid = map[string]any{"invalid": true}

func argAt(args []json.RawMessage, i int) json.RawMessage {
	if i < len(args) {
		return args[i]
	}
	return nil
}

func call(name string, args []json.RawMessage) (out map[string]any) {
	defer func() {
		if r := recover(); r != nil {
			out = map[string]any{"panic": fmt.Sprint(r)}
		}
	}()
	switch name {
	// CASES
	}
	return map[string]any{"missing": name}
}

// prepare decodes a case's arguments once and returns the bare call; nil if they do not fit.
func prepare(name string, args []json.RawMessage) func() {
	switch name {
	// PREPARES
	}
	return nil
}

type input struct {
	Fn   string            `json:"fn"`
	Args []json.RawMessage `json:"args"`
}

// canon re-encodes a JSON value with exact numbers, so equal values compare equal as text.
func canon(v any) string {
	text, err := json.Marshal(v)
	if err != nil {
		return "unencodable: " + err.Error()
	}
	d := json.NewDecoder(bytes.NewReader(text))
	d.UseNumber()
	var x any
	if err := d.Decode(&x); err != nil {
		return string(text)
	}
	out, _ := json.Marshal(x)
	return string(out)
}

func record(inputs, out string) {
	data, err := os.ReadFile(inputs)
	if err != nil {
		panic(err)
	}
	var cases []input
	if err := json.Unmarshal(data, &cases); err != nil {
		panic(err)
	}
	f, err := os.Create(out)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	defer w.Flush()
	progress := os.Getenv("MOJO_ANYTHING_PROGRESS")
	for index, c := range cases {
		if progress != "" {
			if p, err := os.OpenFile(progress, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
				fmt.Fprintln(p, index)
				p.Close()
			}
		}
		result := call(c.Fn, c.Args)
		if result["invalid"] != nil {
			continue
		}
		line := map[string]any{"fn": c.Fn, "args": c.Args}
		for k, v := range result {
			line[k] = v
		}
		text, err := json.Marshal(line)
		if err != nil {
			continue
		}
		w.Write(text)
		w.WriteByte('\n')
		w.Flush()
	}
}

func readCases(path string) []map[string]json.RawMessage {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	var out []map[string]json.RawMessage
	for _, line := range bytes.Split(data, []byte("\n")) {
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var c map[string]json.RawMessage
		if err := json.Unmarshal(line, &c); err != nil {
			panic(err)
		}
		out = append(out, c)
	}
	return out
}

func argsOf(c map[string]json.RawMessage) (string, []json.RawMessage) {
	var name string
	var args []json.RawMessage
	json.Unmarshal(c["fn"], &name)
	json.Unmarshal(c["args"], &args)
	return name, args
}

func diff(cases, out string) {
	summary := map[string]any{"total": 0, "passed": 0, "failed": 0}
	missing := []string{}
	mismatches := []any{}
	total, passed, failed := 0, 0, 0
	for _, c := range readCases(cases) {
		total++
		name, args := argsOf(c)
		got := call(name, args)
		if got["missing"] != nil {
			failed++
			missing = append(missing, name)
			continue
		}
		expected := map[string]any{}
		for _, k := range []string{"ok", "error", "panic"} {
			if raw, ok := c[k]; ok {
				expected[k] = raw
			}
		}
		same := false
		if p, ok := got["panic"]; ok && strings.HasPrefix(fmt.Sprint(p), "not ported: ") {
			// A stub never matches, not even a recorded panic.
			same = false
		} else if _, ok := expected["panic"]; ok {
			// Panic messages differ between Go and Mojo; that it panicked is the behavior.
			_, same = got["panic"]
		} else {
			same = canon(expected) == canon(got)
		}
		if same {
			passed++
		} else {
			failed++
			mismatches = append(mismatches, map[string]any{"fn": name, "args": args, "expected": expected, "actual": got})
		}
	}
	summary["total"], summary["passed"], summary["failed"] = total, passed, failed
	summary["missing"], summary["mismatches"] = missing, mismatches
	text, _ := json.Marshal(summary)
	os.WriteFile(out, text, 0o644)
}

func bench(cases, out string, minMs int) {
	groups := map[string][][]json.RawMessage{}
	order := []string{}
	for _, c := range readCases(cases) {
		name, args := argsOf(c)
		if _, ok := groups[name]; !ok {
			order = append(order, name)
		}
		groups[name] = append(groups[name], args)
	}
	result := map[string]any{}
	for _, name := range order {
		// Arguments are decoded once: only the calls are timed.
		var calls []func()
		for _, args := range groups[name] {
			if f := prepare(name, args); f != nil {
				calls = append(calls, f)
			}
		}
		if len(calls) == 0 {
			continue
		}
		once := func() {
			for _, f := range calls {
				func() {
					defer func() { recover() }()
					f()
				}()
			}
		}
		once()
		passes, start := 0, time.Now()
		for {
			once()
			passes++
			if elapsed := time.Since(start); elapsed.Milliseconds() >= int64(minMs) {
				result[name] = map[string]any{"cases": len(calls), "ns": float64(elapsed.Nanoseconds()) / float64(passes*len(calls))}
				break
			}
		}
	}
	text, _ := json.Marshal(result)
	os.WriteFile(out, text, 0o644)
}

func main() {
	switch os.Args[1] {
	case "record":
		record(os.Args[2], os.Args[3])
	case "diff":
		diff(os.Args[2], os.Args[3])
	case "bench":
		var ms int
		fmt.Sscan(os.Args[4], &ms)
		bench(os.Args[2], os.Args[3], ms)
	}
}
"#;

/// A shadow package with the original's API: each call runs the original and the Mojo port
/// (through the wrapper), returns the original's results and logs mismatches.
/// `MOJO_ANYTHING_MODE=old` runs the original only, `new` the port only.
pub fn shadow(m: &Manifest, original: &str) -> String {
    let wrapper = crate::harness_go::wrapper_module(m);
    let mut out = format!(
        "// Package {pkg} runs the Go original and the Mojo port of `{unit}` side by side. Generated\n\
         // by mojo-anything: import it in place of {original}. MOJO_ANYTHING_MODE=old|shadow|new.\n\
         package {pkg}\n\n\
         import (\n\t\"encoding/json\"\n\t\"log\"\n\t\"os\"\n\t\"reflect\"\n\t\"sync/atomic\"\n\n\
         \torig \"{original}\"\n\tport \"{wrapper}\"\n)\n\n\
         var mode = func() string {{\n\tif m := os.Getenv(\"MOJO_ANYTHING_MODE\"); m != \"\" {{\n\t\treturn m\n\t}}\n\treturn \"shadow\"\n}}()\n\n\
         // Calls and Mismatches count shadowed calls.\nvar Calls, Mismatches atomic.Int64\n\n\
         // convert moves a value between the original's and the wrapper's identical types.\n\
         func convert[T any](v any) T {{\n\tvar out T\n\tif text, err := json.Marshal(v); err == nil {{\n\t\t_ = json.Unmarshal(text, &out)\n\t}}\n\treturn out\n}}\n\n\
         func compare(name string, expected, actual []any) {{\n\tCalls.Add(1)\n\tif !reflect.DeepEqual(expected, actual) {{\n\
         \t\tif Mismatches.Add(1) <= 10 {{\n\t\t\tlog.Printf(\"[mojo-anything] mismatch in %s: expected %v, got %v\", name, expected, actual)\n\t\t}}\n\t}}\n}}\n",
        pkg = package_name(m),
        unit = m.unit,
    );
    for t in used_types(m) {
        let _ = write!(
            out,
            "\n// {t} is the original's type.\ntype {t} = orig.{t}\n"
        );
    }
    for f in &m.exports {
        let (results, fallible) = results(f);
        let params: Vec<String> = f
            .params
            .iter()
            .map(|p| format!("{} {}", p.name, p.native_type.as_deref().unwrap_or("any")))
            .collect();
        let mut all: Vec<String> = results.clone();
        if fallible {
            all.push("error".into());
        }
        let ret = match all.len() {
            0 => String::new(),
            1 => format!(" {}", all[0]),
            _ => format!(" ({})", all.join(", ")),
        };
        let names: Vec<String> = (0..all.len()).map(|i| format!("o{i}")).collect();
        let rust_names: Vec<String> = (0..all.len()).map(|i| format!("n{i}")).collect();
        let args: Vec<&str> = f.params.iter().map(|p| p.name.as_str()).collect();
        let port_args: Vec<String> = f
            .params
            .iter()
            .map(|p| {
                let t = p.native_type.as_deref().unwrap_or("any");
                if local_types(t).is_empty() {
                    p.name.clone()
                } else {
                    format!(
                        "convert[{}]({})",
                        qualify(t).replace("pkg.", "port."),
                        p.name
                    )
                }
            })
            .collect();
        let lhs = |v: &[String]| {
            if v.is_empty() {
                String::new()
            } else {
                format!("{} := ", v.join(", "))
            }
        };
        let back: Vec<String> = all
            .iter()
            .zip(&rust_names)
            .map(|(t, n)| {
                if local_types(t).is_empty() {
                    n.clone()
                } else {
                    format!("convert[{t}]({n})")
                }
            })
            .collect();
        let errors_text = |v: &[String]| -> Vec<String> {
            v.iter()
                .zip(&all)
                .map(|(n, t)| {
                    if t == "error" {
                        format!("errText({n})")
                    } else {
                        n.clone()
                    }
                })
                .collect()
        };
        let _ = writeln!(
            out,
            "\n// {} shadows the original `{}`.\nfunc {}({}){ret} {{",
            f.name,
            f.name,
            f.name,
            params.join(", ")
        );
        let ret_new = if all.is_empty() {
            String::new()
        } else {
            format!("return {}", back.join(", "))
        };
        let _ = writeln!(
            out,
            "\tif mode == \"new\" {{\n\t\t{}port.{}({})\n\t\t{ret_new}\n\t}}",
            lhs(&rust_names),
            f.name,
            port_args.join(", ")
        );
        let _ = writeln!(out, "\t{}orig.{}({})", lhs(&names), f.name, args.join(", "));
        let ret_old = if all.is_empty() {
            "return".to_string()
        } else {
            format!("return {}", names.join(", "))
        };
        let _ = writeln!(
            out,
            "\tif mode != \"old\" {{\n\t\tfunc() {{\n\t\t\tdefer func() {{\n\t\t\t\tif r := recover(); r != nil {{\n\
             \t\t\t\t\tcompare(\"{name}\", []any{{\"no panic\"}}, []any{{r}})\n\t\t\t\t}}\n\t\t\t}}()\n\
             \t\t\t{}port.{name}({})\n\t\t\tcompare(\"{name}\", []any{{{}}}, []any{{{}}})\n\t\t}}()\n\t}}\n\t{ret_old}\n}}",
            lhs(&rust_names),
            port_args.join(", "),
            errors_text(&names).join(", "),
            errors_text(&back).join(", "),
            name = f.name,
        );
    }
    out.push_str("\nfunc errText(err error) any {\n\tif err == nil {\n\t\treturn nil\n\t}\n\treturn err.Error()\n}\n");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn go_codegen_reserves_its_own_bindings() {
        let exports = crate::lang::go::exports(
            "names.go",
            r#"package names
func Typed(out int, C string) int { return out + len(C) }
func Wire(cwb []int, r []int) []int { return append(cwb, r...) }
func Json(raw uint64) uint64 { return raw }"#,
        );
        let manifest = Manifest {
            schema: String::new(),
            root: std::path::PathBuf::new(),
            root_written: None,
            unit: "names.go".into(),
            language: crate::lang::Lang::Go,
            kind: crate::bridge::Kind::Ffi,
            crate_name: "names-rs".into(),
            exports,
            classes: vec![],
            js_only: vec![],
            batches: vec![],
            allocator: Default::default(),
            float_tolerance: None,
        };
        let mut api =
            crate::codegen_mojo::parse_port_mojo(&crate::codegen_mojo::port_mojo(&manifest));
        crate::bridge::match_export_names(&manifest, &mut api);
        let go = wrapper(&manifest, &api);
        assert!(
            go.contains("func Typed(raArg0 int, raArg1 string) int {"),
            "{go}"
        );
        assert!(
            go.contains("C.mojo_anything_t_Typed(C.int64_t(raArg0),"),
            "{go}"
        );
        assert!(
            go.contains("int64_t ra_arg0, const uint8_t *ra_arg1_ptr"),
            "{go}"
        );
        assert!(
            go.contains("func Wire(raArg0 []int, raArg1 []int) []int {"),
            "{go}"
        );
        assert!(
            go.contains(r#"raw, err := mojoAnythingCall("Wire", raArg0, raArg1)"#),
            "{go}"
        );
        assert!(go.contains("func Json(raArg0 uint64) uint64 {"), "{go}");
        assert!(
            go.contains("C.mojo_anything_t_Json(C.uint64_t(raArg0),"),
            "{go}"
        );
        assert!(go.contains(".mojo-anything/build -lnames_rs"), "{go}");
        let mojo = typed_mojo(&manifest, &api).unwrap();
        assert!(
            mojo.contains("var value = port.typed(Int(a0), _go_str(a1_ptr, a1_len))"),
            "{mojo}"
        );
        assert!(mojo.contains("def mojo_anything_t_Json("), "{mojo}");
        assert!(mojo.contains("def mojo_anything_call("), "{mojo}");
        assert!(mojo.contains("def _call_wire(args: Array)"), "{mojo}");
    }

    #[test]
    fn scalar_go_unit_needs_no_dispatcher() {
        let exports = crate::lang::go::exports(
            "p.go",
            "package p\nfunc Clean(path string) string { return path }\nfunc Ok(b bool) (bool, error) { return b, nil }",
        );
        let manifest = Manifest {
            schema: String::new(),
            root: std::path::PathBuf::new(),
            root_written: None,
            unit: "p.go".into(),
            language: crate::lang::Lang::Go,
            kind: crate::bridge::Kind::Ffi,
            crate_name: "p-mojo".into(),
            exports,
            classes: vec![],
            js_only: vec![],
            batches: vec![],
            allocator: Default::default(),
            float_tolerance: None,
        };
        let mut api =
            crate::codegen_mojo::parse_port_mojo(&crate::codegen_mojo::port_mojo(&manifest));
        crate::bridge::match_export_names(&manifest, &mut api);
        assert!(!uses_dispatcher(&manifest, &api));
        let go = wrapper(&manifest, &api);
        assert!(!go.contains("mojo_anything_call"), "{go}");
        assert!(go.contains("return out != 0, nil"), "{go}");
        // A string result that outgrows the buffer again is retried until it fits, never
        // sliced past the buffer.
        assert!(go.contains("\tfor status == 2 {"), "{go}");
        let mojo = typed_mojo(&manifest, &api).unwrap();
        assert!(
            !mojo.contains("json") && !mojo.contains("emberjson"),
            "{mojo}"
        );
        assert!(mojo.contains("def mojo_anything_free("), "{mojo}");
        assert!(
            mojo.contains("res.value()[] = UInt8(1) if value else UInt8(0)"),
            "{mojo}"
        );
    }

    #[test]
    fn qualifies_local_types() {
        assert_eq!(qualify("[]Point"), "[]pkg.Point");
        assert_eq!(qualify("map[string]Point"), "map[string]pkg.Point");
        assert_eq!(qualify("time.Duration"), "time.Duration");
        assert_eq!(local_types("map[string][]Point"), ["Point"]);
    }
}
