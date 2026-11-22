//! The C side of record, build, diff and bench: the original is compiled into a shared
//! library, and Python's ctypes calls it and the Mojo library with the same signatures.

use crate::walk::Canonical;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

use crate::bridge::Manifest;
use crate::harness::{BenchRow, CASES, DiffOutcome};
use crate::lang::Lang;
use crate::lang::c::{defines_main, scalar};

const WORK_DIR: &str = ".mojo-anything";

fn run(cmd: &mut Command, what: &str) -> Result<()> {
    let _scratch = crate::harness::scratch_cwd(cmd)?;
    let output = cmd.output().with_context(|| format!("running {what}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let tail: Vec<&str> = stderr.lines().rev().take(25).collect();
        bail!(
            "{what} failed ({}):\n{}",
            output.status,
            tail.into_iter().rev().collect::<Vec<_>>().join("\n")
        );
    }
    Ok(())
}

fn compiler() -> &'static str {
    if Command::new("cc").arg("--version").output().is_ok() {
        "cc"
    } else {
        "gcc"
    }
}

/// ctypes signatures: `{ name: { "args": [...], "ret": ... } }`. Pointer parameters are tagged:
/// `bytes`, `buffer`, `len:<index>:<ctype>` (the length of the buffer at that index, which cases
/// leave out), `out:<ctype>`, `outptr:<index>` (a `char **` into the parameter at that index);
/// a returned pointer into parameter `i` is `ptr:<i>`. A struct by value, as an argument or the
/// return, is `struct:<field>=<ctype>,...`.
fn signatures(manifest: &Manifest) -> Value {
    use crate::codegen_c::{CKind, c_struct, kind, pointee, returns_into};
    if manifest.language == Lang::Cpp {
        return signatures_cpp(manifest);
    }
    let ctype = |c: &str| scalar(c).map_or("c_int", |(_, _, _, ct)| ct).to_string();
    let structure = |ts: &str| {
        c_struct(ts).map(|s| {
            let fields: Vec<String> = s
                .fields
                .iter()
                .map(|(ty, name)| format!("{name}={}", ctype(ty)))
                .collect();
            format!("struct:{}", fields.join(","))
        })
    };
    let map: serde_json::Map<String, Value> = manifest
        .exports
        .iter()
        .map(|f| {
            let args: Vec<String> = f
                .params
                .iter()
                .map(|p| {
                    let native = p.native_type.as_deref().unwrap_or("int");
                    match kind(p) {
                        CKind::Str => "c_char_p".into(),
                        CKind::Bytes => "bytes".into(),
                        CKind::Buffer => "buffer".into(),
                        CKind::Len(i) => format!("len:{i}:{}", ctype(native)),
                        CKind::Out => format!("out:{}", ctype(&pointee(native))),
                        CKind::OutPtr(i) => format!("outptr:{i}"),
                        CKind::Struct => structure(&p.ts_type).unwrap_or_else(|| "c_int".into()),
                        CKind::Scalar => ctype(native),
                    }
                })
                .collect();
            let ret = match returns_into(f) {
                Some(i) => format!("ptr:{i}"),
                None if structure(&f.returns).is_some() => {
                    structure(&f.returns).unwrap_or_default()
                }
                None if f.native_return.as_deref().unwrap_or("void") == "void" => "None".into(),
                None => ctype(f.native_return.as_deref().unwrap_or("int")),
            };
            (
                f.name.clone(),
                json!({
                    "args": args,
                    "ret": ret,
                    "names": f.params.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(),
                    "writes": crate::codegen_c::writes(f),
                }),
            )
        })
        .collect();
    Value::Object(map)
}

/// The ctypes signatures of a C++ unit's shim symbols, keyed by the C++ name, with the
/// `symbol` to load: a string is `utf8` and a vector `array:<ctype>`, each followed by its
/// length (`len:<index>:c_size_t`); a string or vector result is `owned:str` or
/// `owned:array:<ctype>`, with its length in a hidden `retlen` parameter; every symbol ends
/// with the hidden `error` slot.
fn signatures_cpp(manifest: &Manifest) -> Value {
    use crate::lang::cpp::{CppType, crossing, symbol};
    let ctype = |c: &str| scalar(c).map_or("c_int", |(_, _, _, ct)| ct).to_string();
    let map: serde_json::Map<String, Value> = manifest
        .exports
        .iter()
        .map(|f| {
            let mut args = Vec::new();
            for p in &f.params {
                match p.native_type.as_deref().and_then(crossing).map(|c| c.ty) {
                    Some(CppType::Str) => {
                        args.push("utf8".to_string());
                        args.push(format!("len:{}:c_size_t", args.len() - 1));
                    }
                    Some(CppType::Vec(e)) => {
                        args.push(format!("array:{}", ctype(&e)));
                        args.push(format!("len:{}:c_size_t", args.len() - 1));
                    }
                    Some(CppType::Scalar(s)) => args.push(ctype(&s)),
                    None => args.push("c_int".into()),
                }
            }
            let ret = match f.native_return.as_deref() {
                Some("void") | None => "None".to_string(),
                Some(r) => match crossing(r).map(|c| c.ty) {
                    Some(CppType::Str) => "owned:str".into(),
                    Some(CppType::Vec(e)) => format!("owned:array:{}", ctype(&e)),
                    Some(CppType::Scalar(s)) => ctype(&s),
                    None => "c_int".into(),
                },
            };
            if ret.starts_with("owned:") {
                args.push("retlen".into());
            }
            args.push("error".into());
            (
                f.name.clone(),
                json!({ "symbol": symbol(&f.name), "args": args, "ret": ret, "names": [], "writes": false }),
            )
        })
        .collect();
    Value::Object(map)
}

/// Compiles the project's C sources (without `main` and tests) into one shared library; for a
/// C++ unit, its C++ sources and the shim (regenerated from the manifest) with `c++`.
fn build_original(crate_dir: &Path, manifest: &Manifest) -> Result<PathBuf> {
    let out = crate_dir.join(WORK_DIR).join("original.so");
    std::fs::create_dir_all(crate_dir.join(WORK_DIR))?;
    if manifest.language == Lang::Cpp {
        let (sources, include_dirs) = original_sources_cpp(manifest)?;
        let shim = crate_dir.join(crate::codegen_cpp::SHIM);
        std::fs::create_dir_all(shim.parent().unwrap_or(crate_dir))?;
        std::fs::write(
            &shim,
            crate::codegen_cpp::shim_cpp(manifest).map_err(anyhow::Error::msg)?,
        )?;
        let mut cmd = Command::new(cxx_compiler()?);
        cmd.args(["-std=c++17", "-shared", "-fPIC", "-O1", "-w", "-o"])
            .arg(&out);
        cmd.args(include_args(&include_dirs, "CXXFLAGS"));
        cmd.args(&sources).arg(&shim).arg("-lm");
        run(&mut cmd, "c++ (original sources and cpp/shim.cpp)")?;
        return Ok(out);
    }
    let (sources, include_dirs) = original_sources(manifest)?;
    let mut cmd = Command::new(compiler());
    cmd.args(["-shared", "-fPIC", "-O1", "-w", "-o"]).arg(&out);
    cmd.args(include_args(&include_dirs, "CFLAGS"));
    cmd.args(&sources).arg("-lm");
    run(&mut cmd, "cc (original sources)")?;
    Ok(out)
}

/// The C++ compiler: `c++`, else `g++`, else `clang++`.
pub fn cxx_compiler() -> Result<&'static str> {
    ["c++", "g++", "clang++"]
        .into_iter()
        .find(|c| Command::new(c).arg("--version").output().is_ok())
        .context("no C++ compiler: install one that runs as `c++` (g++ or clang++)")
}

/// The project's C++ sources without `main` and tests, and the folders with headers.
fn original_sources_cpp(
    manifest: &Manifest,
) -> Result<(Vec<PathBuf>, std::collections::BTreeSet<PathBuf>)> {
    let ws = crate::lang::cpp::discover(&manifest.root)?;
    let mut sources = Vec::new();
    let mut include_dirs = std::collections::BTreeSet::new();
    include_dirs.insert(manifest.root.clone());
    for file in ws
        .files
        .iter()
        .filter(|f| f.kind == crate::ts::discover::FileKind::Source)
    {
        let path = manifest.root.join(&file.path);
        if let Some(dir) = path.parent() {
            include_dirs.insert(dir.to_path_buf());
        }
        if crate::lang::cpp::is_source(&file.path)
            && !crate::lang::cpp::defines_main(&std::fs::read_to_string(&path).unwrap_or_default())
        {
            sources.push(path);
        }
    }
    for entry in crate::walk::builder(&manifest.root)
        .require_git(false)
        .build()
        .flatten()
    {
        let name = entry.file_name().to_string_lossy().into_owned();
        if crate::lang::cpp::HEADERS
            .iter()
            .any(|e| name.ends_with(&format!(".{e}")))
            && let Some(dir) = entry.path().parent()
        {
            include_dirs.insert(dir.to_path_buf());
        }
    }
    Ok((sources, include_dirs))
}

/// Include flags: each header folder with `-I`, except a folder holding a header named like a
/// C standard one (ffmpeg's `libavutil/time.h`), which gets `-iquote` so `<time.h>` stays the
/// system's. Then the flags in `flags_var` (`CFLAGS` for C, `CXXFLAGS` for C++:
/// `-DHAVE_CONFIG_H`, `-include config.h`, `-std=c++20`).
fn include_args(dirs: &std::collections::BTreeSet<PathBuf>, flags_var: &str) -> Vec<String> {
    let mut out = Vec::new();
    for dir in dirs {
        let shadows = crate::lang::c::STANDARD_HEADERS.iter().any(|h| {
            dir.join(h.trim_start_matches('<').trim_end_matches('>'))
                .is_file()
        });
        if shadows {
            out.push("-iquote".into());
            out.push(dir.display().to_string());
        } else {
            out.push(format!("-I{}", dir.display()));
        }
    }
    out.extend(
        std::env::var(flags_var)
            .unwrap_or_default()
            .split_whitespace()
            .map(str::to_string),
    );
    out
}

fn driver(crate_dir: &Path, manifest: &Manifest) -> Result<(PathBuf, PathBuf)> {
    let work = crate_dir.join(WORK_DIR);
    std::fs::create_dir_all(&work)?;
    let path = work.join("driver_c.py");
    std::fs::write(&path, DRIVER_C_PY)?;
    let sigs = work.join("signatures.json");
    std::fs::write(&sigs, serde_json::to_string(&signatures(manifest))?)?;
    Ok((path, sigs))
}

fn python() -> Command {
    let mut cmd = Command::new("python3");
    cmd.env("PYTHONDONTWRITEBYTECODE", "1");
    cmd
}

pub fn record(crate_dir: &Path, manifest: &Manifest, cases: &[Value]) -> Result<PathBuf> {
    let original = build_original(crate_dir, manifest)?;
    let (driver, sigs) = driver(crate_dir, manifest)?;
    let out = crate_dir.join(CASES);
    crate::harness::record_cases(
        cases,
        &crate_dir.join(WORK_DIR),
        &out,
        "python (ctypes)",
        |inputs, part| {
            let mut cmd = python();
            cmd.arg(&driver)
                .arg("record")
                .arg(&original)
                .arg(&sigs)
                .arg(inputs)
                .arg(part);
            Ok(cmd)
        },
    )?;
    Ok(out)
}

pub fn diff(crate_dir: &Path, manifest: &Manifest) -> Result<DiffOutcome> {
    let cases = crate_dir.join(CASES);
    if !cases.exists() {
        bail!(
            "no {CASES} in {} (run `mojo-anything record` first)",
            crate_dir.display()
        );
    }
    let port = crate::harness_mojo_c::built_library(crate_dir, manifest, false)?;
    let (driver, sigs) = driver(crate_dir, manifest)?;
    let out = crate_dir.join(WORK_DIR).join("diff.json");
    run(
        python()
            .arg(&driver)
            .arg("diff")
            .arg(&port)
            .arg(&sigs)
            .arg(&cases)
            .arg(&out),
        "python (ctypes)",
    )?;
    Ok(serde_json::from_str(&std::fs::read_to_string(&out)?)?)
}

pub fn bench(crate_dir: &Path, manifest: &Manifest, min_ms: u64) -> Result<Vec<BenchRow>> {
    let cases_path = crate_dir.join(CASES);
    if !cases_path.exists() {
        bail!(
            "no {CASES} in {} (run `mojo-anything record` first)",
            crate_dir.display()
        );
    }
    if manifest.language == Lang::Cpp {
        return bench_cpp(crate_dir, manifest, min_ms);
    }
    let port = crate::harness_mojo_c::built_library(crate_dir, manifest, true)?.canonical()?;
    let work = crate_dir.canonical()?.join(WORK_DIR);
    std::fs::create_dir_all(&work)?;
    let cases: Vec<Value> = std::fs::read_to_string(&cases_path)?
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(serde_json::from_str)
        .collect::<Result<_, _>>()?;
    let source = work.join("bench.c");
    std::fs::write(&source, bench_c(manifest, &cases, min_ms))?;
    // The original, its functions renamed `<name>__original`, and the port's shadow library,
    // which exports it as `mojo_anything_<name>`: both called directly from one C program.
    let (sources, include_dirs) = original_sources(manifest)?;
    let bin = work.join("bench");
    let mut cmd = Command::new(compiler());
    cmd.args(["-O2", "-w", "-o"]).arg(&bin).arg(&source);
    for f in crate::codegen_c::shadow_flags(manifest).split_whitespace() {
        cmd.arg(f);
    }
    cmd.args(include_args(&include_dirs, "CFLAGS"));
    cmd.args(&sources)
        .arg(&port)
        .arg(format!(
            "-Wl,-rpath,{}",
            port.parent()
                .map_or_else(String::new, |p| p.display().to_string())
        ))
        .arg("-lm");
    run(&mut cmd, "cc (bench)")?;
    let out = work.join("bench.json");
    run(Command::new(&bin).arg(&out), "bench")?;
    let timings: serde_json::Map<String, Value> =
        serde_json::from_str(&std::fs::read_to_string(&out)?)?;
    Ok(manifest
        .exports
        .iter()
        .filter_map(|f| {
            let t = timings.get(&f.name)?;
            let (o, n) = (t["original_ns"].as_f64()?, t["rust_ns"].as_f64()?);
            Some(BenchRow {
                name: f.name.clone(),
                cases: usize::try_from(t["cases"].as_u64().unwrap_or(0)).unwrap_or(0),
                original_ns: o,
                rust_ns: n,
                speedup: o / n,
            })
        })
        .collect())
}

/// What `gate`'s `cpp api` check found: the original's mangled symbol for each export, and
/// whether `cpp/wrapper.cpp` defines the same one.
#[derive(Debug, Default)]
pub struct CppApi {
    /// Exports the wrapper defines with the original's symbol, demangled.
    pub same: Vec<String>,
    /// One line per export the wrapper does not define as the original does.
    pub different: Vec<String>,
    /// The original's other external definitions (demangled), which a program linking the
    /// wrapper in place of the unit no longer has.
    pub dropped: Vec<String>,
}

/// Compiles the unit and `cpp/wrapper.cpp` to objects and compares the mangled names they
/// define for each export: a C++ caller links against those names, so they must not change.
/// Every other external definition of the unit that the wrapper lacks is listed as dropped:
/// strong ones only (`T`, `D`, `B`, `R`), since an inline function, an implicit member or a
/// template instance (`W`, `V`) is emitted again by every file that uses it.
pub fn cpp_api(crate_dir: &Path, manifest: &Manifest) -> Result<CppApi> {
    let work = crate_dir.join(WORK_DIR).join("api");
    std::fs::create_dir_all(&work)?;
    let (_, include_dirs) = original_sources_cpp(manifest)?;
    let compiler = cxx_compiler()?;
    let compile = |src: &Path, obj: &Path, what: &str| -> Result<()> {
        let mut cmd = Command::new(compiler);
        cmd.args(["-std=c++17", "-c", "-w", "-o"]).arg(obj);
        cmd.args(include_args(&include_dirs, "CXXFLAGS"));
        cmd.arg(src);
        run(&mut cmd, what)
    };
    let (original, wrapper) = (work.join("original.o"), work.join("wrapper.o"));
    compile(
        &manifest.root.join(&manifest.unit),
        &original,
        "c++ (the original)",
    )?;
    compile(
        &crate_dir.join(crate::codegen_cpp::WRAPPER),
        &wrapper,
        "c++ (cpp/wrapper.cpp)",
    )?;
    let defined = |obj: &Path| -> Result<Vec<(bool, String, String)>> {
        let list = |demangle: bool| -> Result<Vec<String>> {
            let mut cmd = Command::new("nm");
            cmd.arg("--defined-only");
            if demangle {
                cmd.arg("-C");
            }
            let out = cmd.arg(obj).output().context("running nm")?;
            if !out.status.success() {
                bail!("nm {} failed", obj.display());
            }
            Ok(String::from_utf8_lossy(&out.stdout)
                .lines()
                .map(str::to_string)
                .collect())
        };
        let (raw, names) = (list(false)?, list(true)?);
        Ok(raw
            .iter()
            .zip(&names)
            .filter_map(|(r, d)| {
                let mut parts = r.splitn(3, ' ');
                let (_, kind, mangled) = (parts.next()?, parts.next()?, parts.next()?);
                let demangled = d.splitn(3, ' ').nth(2)?;
                let strong = matches!(kind, "T" | "D" | "B" | "R");
                (strong || matches!(kind, "W" | "V"))
                    .then(|| (strong, mangled.to_string(), demangled.to_string()))
            })
            .collect())
    };
    let (theirs, ours) = (defined(&original)?, defined(&wrapper)?);
    let mut api = CppApi::default();
    let prefixes: Vec<String> = manifest
        .exports
        .iter()
        .map(|f| format!("{}(", f.name))
        .collect();
    for (strong, mangled, demangled) in &theirs {
        if *strong
            && !ours.iter().any(|(_, m, _)| m == mangled)
            && !prefixes.iter().any(|p| demangled.starts_with(p))
        {
            api.dropped.push(demangled.clone());
        }
    }
    for f in &manifest.exports {
        let prefix = format!("{}(", f.name);
        let expected: Vec<(&String, &String)> = theirs
            .iter()
            .filter(|(_, _, d)| d.starts_with(&prefix))
            .map(|(_, m, d)| (m, d))
            .collect();
        if expected.is_empty() {
            api.different.push(format!(
                "`{}` is not defined by {} any more",
                f.name, manifest.unit
            ));
            continue;
        }
        for (mangled, demangled) in expected {
            if ours.iter().any(|(_, m, _)| m == mangled) {
                api.same.push(demangled.clone());
            } else {
                let wrote: Vec<&str> = ours
                    .iter()
                    .filter(|(_, _, d)| d.starts_with(&prefix))
                    .map(|(_, _, d)| d.as_str())
                    .collect();
                api.different.push(format!(
                    "{} defines `{demangled}` ({mangled}); {} defines {}",
                    manifest.unit,
                    crate::codegen_cpp::WRAPPER,
                    if wrote.is_empty() {
                        "no such function".to_string()
                    } else {
                        format!("`{}`", wrote.join("`, `"))
                    }
                ));
            }
        }
    }
    Ok(api)
}

/// The exceptions a C++ unit's recording shows that the wrapper cannot throw as they are: each
/// error recorded as `<type> (<base>): <what()>` (see `cpp/shim.cpp`), once per function and
/// type, as "`<function>` throws `<type>`, which C++ callers of the wrapper get as `<base>`".
pub fn cpp_rebuilt_exceptions(crate_dir: &Path) -> Vec<String> {
    let Ok(text) = std::fs::read_to_string(crate_dir.join(CASES)) else {
        return Vec::new();
    };
    let mut seen = std::collections::BTreeSet::new();
    for line in text.lines() {
        let Ok(case) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let (Some(name), Some(error)) = (case["fn"].as_str(), case["error"].as_str()) else {
            continue;
        };
        let Some((head, _)) = error.split_once(": ") else {
            continue;
        };
        if let Some(open) = head.rfind(" (")
            && head.ends_with(')')
        {
            let (ty, base) = (&head[..open], &head[open + 2..head.len() - 1]);
            seen.insert(format!(
                "`{name}` throws `{ty}`, which C++ callers of {} get as `{base}`",
                crate::codegen_cpp::WRAPPER
            ));
        }
    }
    seen.into_iter().collect()
}

/// A C++ unit's bench: the driver calls the original (through the shim) and the port's
/// library with the same recorded arguments, so both timings include one ctypes call.
fn bench_cpp(crate_dir: &Path, manifest: &Manifest, min_ms: u64) -> Result<Vec<BenchRow>> {
    let port = crate::harness_mojo_c::built_library(crate_dir, manifest, false)?;
    let original = build_original(crate_dir, manifest)?;
    let (driver, sigs) = driver(crate_dir, manifest)?;
    let out = crate_dir.join(WORK_DIR).join("bench.json");
    run(
        python()
            .arg(&driver)
            .arg("bench")
            .arg(&original)
            .arg(&port)
            .arg(&sigs)
            .arg(crate_dir.join(CASES))
            .arg(&out)
            .arg(min_ms.to_string()),
        "python (ctypes bench)",
    )?;
    let rows: Vec<Value> = serde_json::from_str(&std::fs::read_to_string(&out)?)?;
    Ok(rows
        .iter()
        .filter_map(|r| {
            let (o, n) = (r["original_ns"].as_f64()?, r["rust_ns"].as_f64()?);
            Some(BenchRow {
                name: r["fn"].as_str()?.to_string(),
                cases: usize::try_from(r["cases"].as_u64().unwrap_or(0)).unwrap_or(0),
                original_ns: o,
                rust_ns: n,
                speedup: o / n,
            })
        })
        .collect())
}

/// The project's C sources without `main`, and the folders with headers.
fn original_sources(
    manifest: &Manifest,
) -> Result<(Vec<PathBuf>, std::collections::BTreeSet<PathBuf>)> {
    let ws = crate::lang::c::discover(&manifest.root)?;
    let mut sources = Vec::new();
    let mut include_dirs = std::collections::BTreeSet::new();
    include_dirs.insert(manifest.root.clone());
    for file in ws
        .files
        .iter()
        .filter(|f| f.kind == crate::ts::discover::FileKind::Source)
    {
        let path = manifest.root.join(&file.path);
        if let Some(dir) = path.parent() {
            include_dirs.insert(dir.to_path_buf());
        }
        if file.path.ends_with(".c")
            && !defines_main(&std::fs::read_to_string(&path).unwrap_or_default())
        {
            sources.push(path);
        }
    }
    for entry in crate::walk::builder(&manifest.root)
        .require_git(false)
        .build()
        .flatten()
    {
        if entry.path().extension().is_some_and(|e| e == "h")
            && let Some(dir) = entry.path().parent()
        {
            include_dirs.insert(dir.to_path_buf());
        }
    }
    Ok((sources, include_dirs))
}

/// A C string literal for `s`, byte by byte.
fn c_literal(s: &str) -> String {
    let mut out = String::from("\"");
    for b in s.bytes() {
        match b {
            b'"' => out.push_str("\\\""),
            b'\\' => out.push_str("\\\\"),
            0x20..=0x7e if b != b'?' => out.push(b as char),
            _ => out.push_str(&format!("\\{b:03o}")),
        }
    }
    out.push('"');
    out
}

/// A C expression for a recorded argument of C type `c_type`; `None` when it has no C value.
fn c_arg(v: &Value, c_type: &str, is_string: bool) -> Option<String> {
    if is_string {
        return match v {
            Value::String(s) => Some(c_literal(s)),
            Value::Null => Some("NULL".into()),
            _ => None,
        };
    }
    let float = matches!(
        c_type.trim_start_matches("const ").trim(),
        "double" | "float" | "long double"
    );
    match v {
        Value::Number(n) if float => n
            .as_f64()
            .map(|x| format!("({c_type})mojo_anything_f({}ULL)", x.to_bits())),
        Value::Object(o) if float => {
            let x = match o.get("$num")?.as_str()? {
                "NaN" => f64::NAN,
                "Infinity" => f64::INFINITY,
                "-Infinity" => f64::NEG_INFINITY,
                _ => -0.0,
            };
            Some(format!("({c_type})mojo_anything_f({}ULL)", x.to_bits()))
        }
        Value::Number(n) => n
            .as_i64()
            .map(|i| format!("({c_type}){i}LL"))
            .or_else(|| n.as_u64().map(|u| format!("({c_type}){u}ULL"))),
        Value::Bool(b) => Some(format!("({c_type}){}", i32::from(*b))),
        _ => None,
    }
}

/// A C string literal for `bytes`.
fn c_bytes_literal(bytes: &[u8]) -> String {
    let mut out = String::from("\"");
    for &b in bytes {
        let _ = std::fmt::Write::write_fmt(&mut out, format_args!("\\{b:03o}"));
    }
    out.push('"');
    out
}

/// A buffer argument as recorded: hex text, or a size for that many zero bytes.
fn buffer_arg(v: &Value) -> Option<Option<Vec<u8>>> {
    match v {
        Value::Null => Some(None),
        Value::Number(n) => Some(Some(vec![0; usize::try_from(n.as_u64()?).ok()?])),
        Value::String(s) => {
            if s.len() % 2 != 0 {
                return None;
            }
            (0..s.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
                .collect::<Option<Vec<u8>>>()
                .map(Some)
        }
        _ => None,
    }
}

/// The statements that set up one recorded call, and its argument list; `None` when an
/// argument has no C value.
fn c_call(
    f: &crate::ts::exports::ExportedFn,
    args: &[Value],
    tag: &str,
) -> Option<(String, String, String)> {
    use crate::codegen_c::{CKind, kind, pointee};
    use std::fmt::Write as _;
    let mut given = args.iter();
    let values: Vec<Value> = f
        .params
        .iter()
        .map(|p| match kind(p) {
            CKind::Len(_) => Value::Null,
            _ => given.next().cloned().unwrap_or(Value::Null),
        })
        .collect();
    let (mut globals, mut setup) = (String::new(), String::new());
    let mut lens = std::collections::HashMap::new();
    let mut exprs = Vec::new();
    for (i, (p, v)) in f.params.iter().zip(&values).enumerate() {
        let native = p.native_type.as_deref().unwrap_or("int");
        let expr = match kind(p) {
            CKind::Str => c_arg(v, native, true)?,
            CKind::Bytes => match buffer_arg(v)? {
                None => "NULL".into(),
                Some(bytes) => {
                    lens.insert(i, bytes.len());
                    format!("({native}){}", c_bytes_literal(&bytes))
                }
            },
            CKind::Buffer => match buffer_arg(v)? {
                None => "NULL".into(),
                Some(bytes) => {
                    let n = bytes.len();
                    lens.insert(i, n);
                    let _ = writeln!(
                        globals,
                        "static const unsigned char init_{tag}_{i}[{}] = {};\nstatic unsigned char buf_{tag}_{i}[{}];",
                        n.max(1),
                        c_bytes_literal(&bytes),
                        n.max(1)
                    );
                    let _ = write!(setup, "memcpy(buf_{tag}_{i}, init_{tag}_{i}, {n}); ");
                    format!("({native})buf_{tag}_{i}")
                }
            },
            CKind::Out => {
                if v.is_null() {
                    "NULL".into()
                } else {
                    let ty = pointee(native);
                    let _ = writeln!(globals, "static {ty} out_{tag}_{i};");
                    let _ = write!(setup, "out_{tag}_{i} = {}; ", c_arg(v, &ty, false)?);
                    format!("&out_{tag}_{i}")
                }
            }
            CKind::Struct => {
                let s = crate::codegen_c::c_struct(&p.ts_type)?;
                let Value::Object(o) = v else {
                    return None;
                };
                let fields = s
                    .fields
                    .iter()
                    .map(|(ty, name)| {
                        let v = o.get(name).cloned().unwrap_or(Value::from(0));
                        Some(format!(".{name} = {}", c_arg(&v, ty, false)?))
                    })
                    .collect::<Option<Vec<_>>>()?;
                format!("({}){{{}}}", s.c_name, fields.join(", "))
            }
            CKind::OutPtr(_) => match v {
                Value::Null => "NULL".into(),
                _ => {
                    let _ = writeln!(
                        globals,
                        "static {};",
                        crate::codegen_c::c_decl(
                            native.trim_end().strip_suffix('*').unwrap_or(native),
                            &format!("slot_{tag}_{i}")
                        )
                    );
                    format!("&slot_{tag}_{i}")
                }
            },
            CKind::Len(_) => String::new(),
            CKind::Scalar => c_arg(v, native, false)?,
        };
        exprs.push(expr);
    }
    for (i, (p, v)) in f.params.iter().zip(&values).enumerate() {
        if let CKind::OutPtr(target) = kind(p)
            && !v.is_null()
        {
            let at = match v.as_u64() {
                Some(k) if !v.is_boolean() => format!("({}) + {k}", exprs[target]),
                _ => "NULL".into(),
            };
            let _ = write!(setup, "slot_{tag}_{i} = {at}; ");
        }
    }
    for (i, p) in f.params.iter().enumerate() {
        if let CKind::Len(target) = kind(p) {
            exprs[i] = format!(
                "({}){}",
                p.native_type.as_deref().unwrap_or("int"),
                lens.get(&target).copied().unwrap_or(0)
            );
        }
    }
    Some((globals, setup, exprs.join(", ")))
}

/// A C program that times each function's recorded calls on the original and on the port.
fn bench_c(m: &Manifest, cases: &[Value], min_ms: u64) -> String {
    use std::fmt::Write as _;
    let mut out = String::from(
        "#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n#include <stdio.h>\n#include <string.h>\n\
         #include <sys/types.h>\n#include <time.h>\n\n\
         static double mojo_anything_f(uint64_t bits) { double d; memcpy(&d, &bits, sizeof d); return d; }\n\
         static double now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }\n\
         static volatile uint64_t sink;\n\n",
    );
    out.push_str(&crate::codegen_c::c_struct_defs(m));
    let mut rows = Vec::new();
    for f in &m.exports {
        let _ = writeln!(
            out,
            "{};\n{};",
            crate::codegen_c::c_prototype(f, &format!("{}__original", f.name)),
            crate::codegen_c::c_prototype(f, &format!("mojo_anything_{}", f.name))
        );
        let mut calls = Vec::new();
        for (k, c) in cases
            .iter()
            .filter(|c| c["fn"] == f.name.as_str() && c.get("error").is_none())
            .enumerate()
        {
            let args = c["args"].as_array().cloned().unwrap_or_default();
            if let Some((globals, setup, exprs)) = c_call(f, &args, &format!("{}_{k}", f.name)) {
                out.push_str(&globals);
                calls.push((setup, exprs));
            }
        }
        if calls.is_empty() {
            continue;
        }
        let void = f.native_return.as_deref() == Some("void");
        let first_field = crate::codegen_c::c_struct(&f.returns)
            .and_then(|s| s.fields.first().map(|(_, n)| n.clone()));
        let body = |target: &str| -> String {
            calls
                .iter()
                .map(|(setup, a)| {
                    if void {
                        format!("    {setup}{target}({a});\n")
                    } else if let Some(field) = &first_field {
                        format!("    {setup}sink += (uint64_t){target}({a}).{field};\n")
                    } else {
                        format!("    {setup}sink += (uint64_t)(uintptr_t){target}({a});\n")
                    }
                })
                .collect()
        };
        let _ = writeln!(
            out,
            "static void pass_{n}_original(void) {{\n{}}}\nstatic void pass_{n}_rust(void) {{\n{}}}\n",
            body(&format!("{}__original", f.name)),
            body(&format!("mojo_anything_{}", f.name)),
            n = f.name
        );
        rows.push((f.name.clone(), calls.len()));
    }
    let _ = writeln!(
        out,
        "static double timed(void (*pass)(void), int calls) {{\n    pass();\n    double start = now_ns(), elapsed;\n    long passes = 0;\n\
         \x20   do {{ pass(); passes++; elapsed = now_ns() - start; }} while (elapsed < {min_ms} * 1e6);\n    return elapsed / ((double)passes * calls);\n}}\n\n\
         int main(int argc, char **argv) {{\n    FILE *out = fopen(argv[1], \"w\");\n    fputs(\"{{\", out);"
    );
    for (i, (name, n)) in rows.iter().enumerate() {
        let _ = writeln!(
            out,
            "    fprintf(out, \"{}\\\"{name}\\\": {{\\\"cases\\\": {n}, \\\"original_ns\\\": %f, \\\"rust_ns\\\": %f}}\", \
             timed(pass_{name}_original, {n}), timed(pass_{name}_rust, {n}));",
            if i == 0 { "" } else { "," }
        );
    }
    out.push_str("    fputs(\"}\", out);\n    fclose(out);\n    return 0;\n}\n");
    out
}

const DRIVER_C_PY: &str = r#"
import ctypes
import json
import locale
import math
import os
import signal
import sys
import time

# Python switches C's locale to the user's at startup; a C program stays in "C" unless it calls
# setlocale, so the library must see "C" here (isspace, toupper, strtod depend on it).
locale.setlocale(locale.LC_ALL, "C")

# Results the callee allocates (C++ strings, vectors and error texts) are freed with the C
# library's `free`, the one both the shim and Mojo's `malloc` use.
FREE = ctypes.CDLL(None).free
FREE.argtypes = [ctypes.c_void_p]
FREE.restype = None
HIDDEN = ("retlen", "error")


def enc(v):
    if isinstance(v, float):
        if math.isnan(v):
            return {"$num": "NaN"}
        if math.isinf(v):
            return {"$num": "Infinity" if v > 0 else "-Infinity"}
        if v == 0 and math.copysign(1, v) < 0:
            return {"$num": "-0"}
    if isinstance(v, bytes):
        return {"$bytes": list(v)}
    return v


def dec(v):
    if isinstance(v, dict) and len(v) == 1:
        (key, inner), = v.items()
        if key == "$undefined":
            return None
        if key == "$num":
            return {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf, "-0": -0.0}[inner]
    return v


STRUCTS = {}


def structure(kind):
    """The ctypes Structure for `struct:<field>=<ctype>,...`."""
    if kind not in STRUCTS:
        fields = [f.split("=", 1) for f in kind[len("struct:"):].split(",")]
        STRUCTS[kind] = type("Struct", (ctypes.Structure,), {"_fields_": [(n, getattr(ctypes, t)) for n, t in fields]})
    return STRUCTS[kind]


def scalar(ctype, value):
    if ctype in (ctypes.c_float, ctypes.c_double):
        return float(value) if isinstance(value, (int, float)) else 0.0
    if ctype is ctypes.c_bool:
        return bool(value)
    return int(value) if isinstance(value, (int, float)) and math.isfinite(value) else 0


def to_struct(kind, value):
    """A struct argument from an object of its fields; missing fields are zero."""
    if not isinstance(value, dict):
        raise TypeError("expects an object with fields %s" % ", ".join(n for n, _ in structure(kind)._fields_))
    cls = structure(kind)
    return cls(**{n: scalar(t, dec(value.get(n, 0))) for n, t in cls._fields_})


def from_struct(value):
    return {n: enc(getattr(value, n)) for n, _ in type(value)._fields_}


def argtype(kind):
    if kind.startswith("struct:"):
        return structure(kind)
    if kind in ("bytes", "buffer", "utf8") + HIDDEN or kind.startswith(("out:", "outptr:", "array:")):
        return ctypes.c_void_p
    if kind.startswith("len:"):
        return getattr(ctypes, kind.split(":")[2])
    return getattr(ctypes, kind)


def bind(path, signatures):
    lib = ctypes.CDLL(path)
    functions = {}
    for name, sig in signatures.items():
        try:
            fn = getattr(lib, sig.get("symbol", name))
        except AttributeError:
            continue
        fn.argtypes = [argtype(t) for t in sig["args"]]
        ret = sig["ret"]
        if ret == "None":
            fn.restype = None
        elif ret.startswith(("ptr:", "owned:")):
            fn.restype = ctypes.c_void_p
        elif ret.startswith("struct:"):
            fn.restype = structure(ret)
        else:
            fn.restype = getattr(ctypes, ret)
        functions[name] = (fn, sig)
    return functions


def as_bytes(value):
    """A buffer argument: hex text, or a size for that many zero bytes; None is NULL."""
    if value is None:
        return None
    if isinstance(value, bool):
        return bytes(int(value))
    if isinstance(value, (int, float)):
        return bytes(max(int(value), 0))
    return bytes.fromhex(str(value))


def call(functions, c):
    fn, sig = functions[c["fn"]]
    kinds = sig["args"]
    given = iter([dec(a) for a in c["args"]])
    values = [None if k.startswith("len:") or k in HIDDEN else next(given, None) for k in kinds]
    args = [None] * len(kinds)
    memory = {}
    outs = {}
    retlen = ctypes.c_size_t(0)
    error = ctypes.c_void_p(None)
    for i, (value, kind) in enumerate(zip(values, kinds)):
        if kind == "retlen":
            args[i] = ctypes.addressof(retlen)
        elif kind == "error":
            args[i] = ctypes.addressof(error)
        elif kind == "utf8":
            # A C++ string: its UTF-8 bytes and their count, NUL bytes included.
            data = str(value if value is not None else "").encode("utf-8")
            buf = ctypes.create_string_buffer(data, max(len(data), 1))
            memory[i] = (buf, len(data))
            args[i] = ctypes.cast(buf, ctypes.c_void_p)
        elif kind.startswith("array:"):
            # A C++ vector of numbers: the elements and their count.
            if not isinstance(value, list):
                raise TypeError("expects a list of numbers")
            ctype = getattr(ctypes, kind[len("array:"):])
            items = [scalar(ctype, dec(v)) for v in value]
            buf = (ctype * max(len(items), 1))(*items)
            memory[i] = (buf, len(items))
            args[i] = ctypes.cast(buf, ctypes.c_void_p)
        elif kind == "c_char_p":
            if value is not None:
                data = str(value).encode("utf-8")
                buf = ctypes.create_string_buffer(data)
                memory[i] = (buf, len(data) + 1)
                args[i] = ctypes.cast(buf, ctypes.c_char_p)
        elif kind in ("bytes", "buffer"):
            data = as_bytes(value)
            if data is not None:
                buf = ctypes.create_string_buffer(data, max(len(data), 1))
                memory[i] = (buf, len(data))
                args[i] = ctypes.cast(buf, ctypes.c_void_p)
        elif kind.startswith("out:"):
            if value is not None:
                ctype = getattr(ctypes, kind[4:])
                cell = ctype(value if ctype in (ctypes.c_float, ctypes.c_double) else int(value))
                outs[i] = cell
                args[i] = ctypes.cast(ctypes.pointer(cell), ctypes.c_void_p)
        elif kind.startswith("struct:"):
            args[i] = to_struct(kind, value)
        elif kind.startswith("outptr:"):
            pass
        elif kind in ("c_float", "c_double"):
            args[i] = float(value) if isinstance(value, (int, float)) else 0.0
        elif kind == "c_bool":
            args[i] = bool(value)
        elif not kind.startswith("len:"):
            args[i] = int(value) if isinstance(value, (int, float)) and math.isfinite(value) else 0
    for i, kind in enumerate(kinds):
        if kind.startswith("len:"):
            target = int(kind.split(":")[1])
            args[i] = memory[target][1] if target in memory else 0
    slots = {}
    for i, (value, kind) in enumerate(zip(values, kinds)):
        if kind.startswith("outptr:") and value is not None:
            # The starting pointer: an offset into its target argument, or NULL for `true`.
            target = int(kind.split(":")[1])
            start = None
            if isinstance(value, int) and not isinstance(value, bool):
                if target not in memory or not 0 <= value <= memory[target][1]:
                    return {"error": "starts a pointer outside its arguments"}
                start = ctypes.addressof(memory[target][0]) + value
            slots[i] = ctypes.c_void_p(start)
            args[i] = ctypes.addressof(slots[i])
    result = fn(*args)
    ret = sig["ret"]
    if error.value:
        # A C++ exception the shim caught, or an error a Mojo port raised.
        text = ctypes.string_at(error.value).decode("utf-8", "replace")
        FREE(error.value)
        if ret.startswith("owned:") and result:
            FREE(result)
        return {"error": text}
    if ret == "owned:str":
        data = ctypes.string_at(result, retlen.value) if result and retlen.value else b""
        if result:
            FREE(result)
        try:
            return {"ok": data.decode("utf-8")}
        except UnicodeDecodeError:
            return {"ok": enc(data)}
    if ret.startswith("owned:array:"):
        ctype = getattr(ctypes, ret[len("owned:array:"):])
        items = [enc(v) for v in (ctype * retlen.value).from_address(result)] if result and retlen.value else []
        if result:
            FREE(result)
        return {"ok": items}
    if sig["ret"].startswith("ptr:"):
        target = int(sig["ret"][4:])
        if result is not None:
            if target not in memory:
                return {"error": "returns a pointer outside its arguments"}
            offset = result - ctypes.addressof(memory[target][0])
            if not 0 <= offset <= memory[target][1]:
                return {"error": "returns a pointer outside its arguments"}
            result = offset
    elif sig["ret"].startswith("struct:"):
        result = from_struct(result)
    else:
        result = enc(result)
    if not sig.get("writes"):
        return {"ok": result}
    ok = {} if sig["ret"] == "None" else {"return": result}
    for i, kind in enumerate(kinds):
        name = sig["names"][i]
        if kind == "buffer":
            ok[name] = memory[i][0].raw[: memory[i][1]].hex() if i in memory else None
        elif kind.startswith("out:"):
            ok[name] = enc(outs[i].value) if i in outs else None
        elif kind.startswith("outptr:"):
            target = int(kind.split(":")[1])
            pointer = slots[i].value if i in slots else None
            if pointer is None:
                ok[name] = None
            else:
                offset = pointer - ctypes.addressof(memory[target][0]) if target in memory else -1
                if target not in memory or not 0 <= offset <= memory[target][1]:
                    return {"error": "writes a pointer outside its arguments"}
                ok[name] = offset
    return {"ok": ok}


def isolated(functions, c):
    """Runs one case in a forked child: undefined behavior in C can crash the process."""
    read_end, write_end = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_end)
        try:
            result = call(functions, c)
        except Exception as e:  # ctypes conversion errors
            result = {"error": "%s: %s" % (type(e).__name__, e)}
        os.write(write_end, json.dumps(result).encode())
        os._exit(0)
    os.close(write_end)
    data = b""
    while True:
        chunk = os.read(read_end, 65536)
        if not chunk:
            break
        data += chunk
    os.close(read_end)
    _, status = os.waitpid(pid, 0)
    if os.WIFSIGNALED(status):
        return {"error": "crash: " + signal.Signals(os.WTERMSIG(status)).name}
    return json.loads(data) if data else {"error": "crash: no result"}


def cases_of(path):
    return [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]


def record(lib, sigs, inputs, out_path):
    functions = bind(lib, json.load(open(sigs)))
    progress = os.environ.get("MOJO_ANYTHING_PROGRESS")
    with open(out_path, "w", encoding="utf-8") as out:
        for index, c in enumerate(json.load(open(inputs, encoding="utf-8"))):
            if progress:
                with open(progress, "a", encoding="utf-8") as p:
                    p.write("%d\n" % index)
            line = {"fn": c["fn"], "args": c["args"]}
            line.update(isolated(functions, c))
            out.write(json.dumps(line, ensure_ascii=False) + "\n")
            out.flush()


def diff(lib, sigs, cases_path, out_path):
    functions = bind(lib, json.load(open(sigs)))
    summary = {"total": 0, "passed": 0, "failed": 0, "missing": [], "mismatches": []}
    for c in cases_of(cases_path):
        summary["total"] += 1
        if c["fn"] not in functions:
            if c["fn"] not in summary["missing"]:
                summary["missing"].append(c["fn"])
            summary["failed"] += 1
            continue
        error = str(c.get("error", ""))
        if error.startswith("crash:") or error in (
            "returns a pointer outside its arguments",
            "writes a pointer outside its arguments",
        ):
            # The original's behavior is undefined there: any answer of the port passes.
            summary["passed"] += 1
            continue
        got = isolated(functions, c)
        expected = {"error": c["error"]} if "error" in c else {"ok": c.get("ok")}
        if json.dumps(got) == json.dumps(expected):
            summary["passed"] += 1
        else:
            summary["failed"] += 1
            summary["mismatches"].append({"fn": c["fn"], "args": c["args"], "expected": expected, "actual": got})
    json.dump(summary, open(out_path, "w", encoding="utf-8"), ensure_ascii=False)


def bench(original, rust, sigs, cases_path, out_path, min_ms):
    signatures = json.load(open(sigs))
    old, new = bind(original, signatures), bind(rust, signatures)
    groups = {}
    for c in cases_of(cases_path):
        if "error" not in c:
            groups.setdefault(c["fn"], []).append(c)
    rows = []
    for name, cases in groups.items():
        if name not in old or name not in new:
            continue

        def timed(functions):
            def once():
                for c in cases:
                    call(functions, c)
            once()
            passes, start = 0, time.perf_counter()
            while True:
                once()
                passes += 1
                elapsed = time.perf_counter() - start
                if elapsed * 1000 >= min_ms:
                    return elapsed * 1e9 / (passes * len(cases))
        original_ns, rust_ns = timed(old), timed(new)
        rows.append({"fn": name, "cases": len(cases), "original_ns": original_ns, "rust_ns": rust_ns, "speedup": original_ns / rust_ns})
    json.dump(rows, open(out_path, "w"))


if __name__ == "__main__":
    mode, *rest = sys.argv[1:]
    if mode == "record":
        record(*rest)
    elif mode == "diff":
        diff(*rest)
    elif mode == "bench":
        bench(rest[0], rest[1], rest[2], rest[3], rest[4], int(rest[5]))
"#;
