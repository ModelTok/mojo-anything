//! Building a TS/JS unit ported to Mojo as a WebAssembly module (`--kind wasm`).
//!
//! Mojo has no wasm backend. The unit's own Mojo (pixi, with EmberJson) writes the dispatcher's
//! LLVM IR for a baseline x86-64 CPU; the IR is retargeted to `wasm64-unknown-unknown`, whose
//! data layout matches x86-64's for every type Mojo emits (64-bit pointers and `Int`), and
//! compiled and linked with the clang and wasm-ld of mojo-wasm (github.com/lee101/mojo-wasm),
//! with `src/mojo/wasm_runtime.c` for the symbols the standard library leaves undefined. The
//! result is `<lib>.wasm` beside `index.cjs`, which loads it.
//!
//! Why not mojo-wasm's own `mojowasm build` (wasm32): its pinned Mojo nightly cannot compile
//! EmberJson 0.5.0, and on 32-bit targets Mojo 1.2 lays a `Variant` out one way and sizes it
//! another (a `List` of JSON values loses its tags when it grows), while 64-bit IR read as
//! wasm32 loops for ever. See DECISIONS.md.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};

use crate::bridge::Manifest;

/// The runtime linked into every module.
pub const WASM_RUNTIME_C: &str = include_str!("mojo/wasm_runtime.c");

/// What `index.cjs` and the runtime need from the module.
const EXPORTS: &[&str] = &[
    "mojo_anything_call",
    "mojo_anything_free",
    "mw_alloc",
    "mw_heap_reset",
    "memory",
];

/// wasm64's data layout (clang 22), which the x86-64 IR is given.
const WASM64_DATALAYOUT: &str =
    "e-m:e-p:64:64-p10:8:8-p20:8:8-i64:64-i128:128-n32:64-S128-ni:1:10:20";
const WASM64_TRIPLE: &str = "wasm64-unknown-unknown";

/// The stack the module gets (EmberJson recurses once per nesting level).
const STACK_BYTES: u64 = 8 << 20;

/// The mojo-wasm checkout: `MOJOWASM_HOME`, else `~/github/mojo-wasm`.
pub fn home() -> Option<PathBuf> {
    std::env::var_os("MOJOWASM_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join("github/mojo-wasm")))
}

/// mojo-wasm's pixi environment, which holds its clang and wasm-ld.
fn tool(name: &str) -> Option<PathBuf> {
    let path = home()?
        .join(".pixi")
        .join("envs")
        .join("default")
        .join("bin")
        .join(name);
    path.is_file().then_some(path)
}

/// Whether the wasm toolchain is installed (mojo-wasm with `pixi install` run).
pub fn available() -> bool {
    !cfg!(windows) && tool("clang").is_some() && tool("wasm-ld").is_some()
}

/// One line saying what is missing and how to get it.
pub fn missing_message() -> String {
    let at = home().map_or_else(
        || "~/github/mojo-wasm".to_string(),
        |h| h.display().to_string(),
    );
    format!(
        "the wasm kind needs mojo-wasm's clang and wasm-ld: clone github.com/lee101/mojo-wasm \
         to {at} (or set MOJOWASM_HOME) and run `pixi install` there"
    )
}

/// The module `index.cjs` loads: `<lib>.wasm` beside it.
pub fn wasm_path(unit_dir: &Path, m: &Manifest) -> PathBuf {
    unit_dir.join(format!("{}.wasm", m.lib_name()))
}

/// Removes `"name"="value"` from an attribute group line.
fn strip_attribute(line: &str, name: &str) -> String {
    let key = format!("\"{name}\"=\"");
    let mut out = line.to_string();
    while let Some(at) = out.find(&key) {
        let value = at + key.len();
        let Some(len) = out[value..].find('"') else {
            break;
        };
        let mut end = value + len + 1;
        while out[end..].starts_with(' ') {
            end += 1;
        }
        out.replace_range(at..end, "");
    }
    out
}

/// x86-64 IR from `mojo build --emit llvm --target-cpu x86-64`, retargeted to wasm64.
/// Refuses IR that holds x86 intrinsics or inline assembly, which wasm cannot run (a host CPU
/// target emits SSE intrinsics, which compile to a function that never returns).
fn retarget(ir: &str) -> Result<String> {
    if let Some(at) = ir.find("@llvm.x86.") {
        let name: String = ir[at + 1..]
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '.' || *c == '_')
            .collect();
        bail!("the dispatcher's IR uses the x86 intrinsic `{name}`, which wasm cannot run");
    }
    if ir.contains(" asm \"") || ir.contains(" asm sideeffect ") {
        bail!("the dispatcher's IR holds inline assembly, which wasm cannot run");
    }
    let mut out = String::with_capacity(ir.len());
    let mut triple = false;
    for line in ir.lines() {
        if line.starts_with("target datalayout") {
            out.push_str(&format!("target datalayout = \"{WASM64_DATALAYOUT}\""));
        } else if let Some(rest) = line.strip_prefix("target triple = ") {
            if !rest.starts_with("\"x86_64") {
                bail!("expected x86-64 IR from mojo build, got the triple {rest}");
            }
            triple = true;
            out.push_str(&format!("target triple = \"{WASM64_TRIPLE}\""));
        } else if line.starts_with("attributes #") {
            let line = strip_attribute(&strip_attribute(line, "target-cpu"), "target-features");
            let empty = line
                .split_once('{')
                .is_some_and(|(_, body)| body.trim().trim_end_matches('}').trim().is_empty());
            if empty {
                let head = line.split_once('{').map_or(line.as_str(), |(h, _)| h);
                out.push_str(&format!("{head}{{ nounwind }}"));
            } else {
                out.push_str(&line);
            }
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }
    if !triple {
        bail!("the IR from mojo build names no target triple");
    }
    special_floats(&out)
}

/// The old spelling of an infinity or NaN of type `ty` whose sign is `negative` and whose
/// significand (the bits below the exponent, quiet bit included) is `significand`: a `double`
/// or `float` as the `double` hex of the same value (a `float`'s significand moves up 29 bits,
/// which keeps its quiet bit and payload), a `half` or `bfloat` as its own bits.
fn special_old(ty: &str, negative: bool, significand: u64) -> Option<String> {
    let sign = u64::from(negative);
    match ty {
        "double" => Some(format!("0x{:016X}", sign << 63 | 0x7FF << 52 | significand)),
        "float" => Some(format!(
            "0x{:016X}",
            sign << 63 | 0x7FF << 52 | significand << 29
        )),
        "half" => Some(format!("0xH{:04X}", sign << 15 | 0x1F << 10 | significand)),
        "bfloat" => Some(format!("0xR{:04X}", sign << 15 | 0xFF << 7 | significand)),
        _ => None,
    }
}

/// The significand of the newer spelling of an infinity or NaN without its sign: `inf`,
/// `qnan`, `nan(0x<payload>)` (quiet) or `snan(0x<payload>)` (signalling, payload not zero).
/// The payload is the significand without the quiet bit, as Mojo 1.2's LLVM writes it (a probe
/// gave `double +nan(0x7FFFFFFFFFFFF)` for the bits 0x7FFFFFFFFFFFFFFF and `double +snan(0x1)`
/// for 0x7FF0000000000001). `None` when the spelling or payload is not one of these.
fn special_significand(ty: &str, body: &str) -> Option<u64> {
    let width = match ty {
        "double" => 52,
        "float" => 23,
        "half" => 10,
        "bfloat" => 7,
        _ => return None,
    };
    let quiet = 1u64 << (width - 1);
    let payload = |inner: &str| {
        let digits = inner.strip_prefix("(0x")?.strip_suffix(')')?;
        u64::from_str_radix(digits, 16).ok().filter(|&p| p < quiet)
    };
    match body {
        "inf" => Some(0),
        "qnan" => Some(quiet),
        _ => {
            if let Some(inner) = body.strip_prefix("snan") {
                payload(inner).filter(|&p| p != 0)
            } else {
                body.strip_prefix("nan")
                    .and_then(payload)
                    .map(|p| quiet | p)
            }
        }
    }
}

/// The old spelling of one float constant in the newer syntax Mojo's LLVM writes, or `None`
/// when `token` is already old syntax. `ty` is the constant's type.
fn old_float(ty: &str, token: &str) -> Result<Option<String>> {
    let double = |bits: u64| Some(format!("0x{bits:016X}"));
    let hex = |digits: &str| u64::from_str_radix(digits, 16).ok();
    let cannot =
        || format!("the dispatcher's IR has a float constant clang cannot read: `{ty} {token}`");
    if let Some(body) = token.strip_prefix(['+', '-'])
        && body.starts_with(|c: char| c.is_ascii_alphabetic())
    {
        let old =
            special_significand(ty, body).and_then(|s| special_old(ty, token.starts_with('-'), s));
        return old.map(Some).with_context(cannot);
    }
    Ok(match token.strip_prefix("f0x").map(|d| (d, hex(d))) {
        // The bits of the constant's own type: a `double` keeps them; a `float` is written as
        // the `double` of the same value; `half` and `bfloat` take their own prefixes.
        Some((_, Some(bits))) if ty == "double" => double(bits),
        Some((_, Some(bits))) if ty == "float" => {
            let x = f32::from_bits(u32::try_from(bits).context("a float constant over 32 bits")?);
            double(f64::from(x).to_bits())
        }
        Some((digits, Some(_))) if ty == "half" => Some(format!("0xH{digits}")),
        Some((digits, Some(_))) if ty == "bfloat" => Some(format!("0xR{digits}")),
        Some(_) => bail!(cannot()),
        None => None,
    })
}

/// Mojo's LLVM writes float constants in a syntax the LLVM behind clang 22 cannot read
/// (`double +qnan`, `double -inf`, `double +nan(0x1)`, `double -snan(0x1)`,
/// `double f0x7FEFFFFFFFFFFFFF`): they become the hex forms both read.
fn special_floats(ir: &str) -> Result<String> {
    let mut out = String::with_capacity(ir.len());
    for line in ir.split_inclusive('\n') {
        special_floats_in_line(line, &mut out)?;
    }
    Ok(out)
}

/// Rewrites the float constants of one line. A constant takes the float type named last before
/// it on the line: its own (`double +inf`), or the instruction's for an operand written without
/// one (`fmul double %a, +inf`, `phi double [ %a, %b ], [ +inf, %c ]`). Quoted text (`c"..."`,
/// names, metadata strings) is copied as it is.
fn special_floats_in_line(line: &str, out: &mut String) -> Result<()> {
    let word = |c: char| c.is_ascii_alphanumeric() || "_.$%@+-".contains(c);
    let mut ty: Option<&str> = None;
    let mut rest = line;
    while let Some(c) = rest.chars().next() {
        if c == '"' {
            let end = rest[1..].find('"').map_or(rest.len(), |n| n + 2);
            out.push_str(&rest[..end]);
            rest = &rest[end..];
            continue;
        }
        if !word(c) {
            out.push(c);
            rest = &rest[c.len_utf8()..];
            continue;
        }
        let mut end = rest.find(|c: char| !word(c)).unwrap_or(rest.len());
        let token = &rest[..end];
        let special = token.starts_with(['+', '-'])
            && token[1..].starts_with(|c: char| c.is_ascii_alphabetic());
        if special && rest[end..].starts_with('(') {
            // A NaN's payload follows in parentheses: `+nan(0x1)`, `-snan(0x1)`.
            end += rest[end..].find(')').map_or(rest.len() - end, |n| n + 1);
        }
        let token = &rest[..end];
        if special || token.starts_with("f0x") {
            let Some(t) = ty else {
                bail!(
                    "the dispatcher's IR has a float constant with no type on its line: `{token}`"
                )
            };
            out.push_str(old_float(t, token)?.as_deref().unwrap_or(token));
        } else {
            if let Some(t) = ["double", "float", "half", "bfloat"]
                .into_iter()
                .find(|t| *t == token)
            {
                ty = Some(t);
            }
            out.push_str(token);
        }
        rest = &rest[end..];
    }
    Ok(())
}

/// Reads a LEB128 unsigned integer at `*at`.
fn leb(bytes: &[u8], at: &mut usize) -> Result<u64> {
    let mut value = 0u64;
    let mut shift = 0;
    loop {
        let b = *bytes.get(*at).context("truncated wasm module")?;
        *at += 1;
        value |= u64::from(b & 0x7f) << shift;
        if b & 0x80 == 0 {
            return Ok(value);
        }
        shift += 7;
        if shift > 63 {
            bail!("bad LEB128 in wasm module");
        }
    }
}

/// The names a wasm module exports, and the `module.name` pairs it imports.
pub fn wasm_interface(bytes: &[u8]) -> Result<(Vec<String>, Vec<String>)> {
    if bytes.len() < 8 || &bytes[..4] != b"\0asm" {
        bail!("not a wasm module");
    }
    let mut at = 8;
    let (mut exports, mut imports) = (Vec::new(), Vec::new());
    let name = |at: &mut usize| -> Result<String> {
        let n = usize::try_from(leb(bytes, at)?)?;
        let text = bytes.get(*at..*at + n).context("truncated wasm module")?;
        *at += n;
        Ok(String::from_utf8_lossy(text).into_owned())
    };
    while at < bytes.len() {
        let id = bytes[at];
        at += 1;
        let size = usize::try_from(leb(bytes, &mut at)?)?;
        let end = at + size;
        let mut p = at;
        match id {
            7 => {
                for _ in 0..leb(bytes, &mut p)? {
                    exports.push(name(&mut p)?);
                    p += 1;
                    leb(bytes, &mut p)?;
                }
            }
            2 => {
                for _ in 0..leb(bytes, &mut p)? {
                    let module = name(&mut p)?;
                    let field = name(&mut p)?;
                    imports.push(format!("{module}.{field}"));
                    // Only function imports are expected; stop at anything else.
                    if bytes.get(p) != Some(&0) {
                        break;
                    }
                    p += 1;
                    leb(bytes, &mut p)?;
                }
            }
            _ => {}
        }
        at = end;
    }
    Ok((exports, imports))
}

fn run(cmd: &mut Command, what: &str) -> Result<()> {
    let out = crate::process::output(cmd, crate::process::BUILD)
        .with_context(|| format!("running {what}"))?;
    if !out.success() {
        bail!("{what} failed:\n{}{}", out.stdout_text(), out.stderr_text());
    }
    Ok(())
}

/// Builds `<lib>.wasm` from the dispatcher (Mojo warnings are errors), checks that it exports
/// the dispatcher and imports nothing but `env.mw_write`, and installs it beside `index.cjs`.
/// Returns its path.
pub fn build(unit_dir: &Path, m: &Manifest) -> Result<PathBuf> {
    let (Some(clang), Some(wasm_ld)) = (tool("clang"), tool("wasm-ld")) else {
        bail!("{}", missing_message());
    };
    let unit_dir = std::path::absolute(unit_dir)?;
    let build = unit_dir.join(crate::harness_mojo_c::BUILD_DIR);
    std::fs::create_dir_all(&build)?;
    let lib = m.lib_name();
    let ll = build.join(format!("{lib}.x86_64.ll"));
    let mut mojo = crate::mojo::command(&unit_dir)?;
    mojo.current_dir(&unit_dir)
        .args(["build", "--Werror", crate::codegen_ffi::DISPATCHER])
        .args(["--emit", "llvm", "-O3", "--target-cpu", "x86-64", "-o"])
        .arg(&ll);
    run(&mut mojo, "mojo build --emit llvm")?;
    let ir = std::fs::read_to_string(&ll).with_context(|| format!("reading {}", ll.display()))?;
    let wasm_ll = build.join(format!("{lib}.wasm64.ll"));
    std::fs::write(&wasm_ll, retarget(&ir)?)?;
    let target = format!("--target={WASM64_TRIPLE}");
    let object = build.join(format!("{lib}.wasm64.o"));
    run(
        Command::new(&clang)
            .arg(&target)
            .args([
                "-O3",
                "-mbulk-memory",
                "-nostdlib",
                "-Wno-override-module",
                "-c",
            ])
            .arg(&wasm_ll)
            .arg("-o")
            .arg(&object),
        "clang (the dispatcher)",
    )?;
    let runtime_c = build.join("wasm_runtime.c");
    std::fs::write(&runtime_c, WASM_RUNTIME_C)?;
    let runtime_o = build.join("wasm_runtime.o");
    run(
        Command::new(&clang)
            .arg(&target)
            .args([
                "-O3",
                "-mbulk-memory",
                "-nostdlib",
                "-ffreestanding",
                "-Wall",
                "-Werror",
                "-c",
            ])
            .arg(&runtime_c)
            .arg("-o")
            .arg(&runtime_o),
        "clang (wasm_runtime.c)",
    )?;
    let built = build.join(format!("{lib}.wasm"));
    let mut link = Command::new(&wasm_ld);
    link.args([
        "-mwasm64",
        "--no-entry",
        "--export-dynamic",
        "--stack-first",
    ])
    .arg(format!("-zstack-size={STACK_BYTES}"))
    .args([
        "--export=mw_alloc",
        "--export=mw_heap_used",
        "--export=mw_heap_reset",
    ])
    .arg("-o")
    .arg(&built)
    .arg(&object)
    .arg(&runtime_o);
    run(&mut link, "wasm-ld")?;
    let bytes = std::fs::read(&built)?;
    let (exports, imports) = wasm_interface(&bytes)?;
    let missing: Vec<&str> = EXPORTS
        .iter()
        .copied()
        .filter(|e| !exports.iter().any(|x| x == e))
        .collect();
    if !missing.is_empty() {
        bail!(
            "{} does not export {}; it exports {}",
            built.display(),
            missing.join(", "),
            exports.join(", ")
        );
    }
    if let Some(other) = imports.iter().find(|i| *i != "env.mw_write") {
        bail!(
            "{} imports `{other}`, which index.cjs does not provide",
            built.display()
        );
    }
    let dest = wasm_path(&unit_dir, m);
    crate::harness::install(&built, &dest)
        .with_context(|| format!("copying {} next to index.cjs", built.display()))?;
    Ok(dest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retargets_x86_ir_to_wasm64() {
        let ir = "target datalayout = \"e-m:e-p270:32:32-i64:64-i128:128-f80:128-n8:16:32:64-S128\"\n\
                  target triple = \"x86_64-unknown-linux-gnu\"\n\
                  define i64 @f(i64 %0) #0 {\n  ret i64 %0\n}\n\
                  attributes #0 = { \"target-cpu\"=\"x86-64\" \"target-features\"=\"+sse2\" }\n\
                  attributes #1 = { nounwind \"target-cpu\"=\"x86-64\" }\n";
        let out = retarget(ir).unwrap();
        assert!(
            out.contains(&format!("target datalayout = \"{WASM64_DATALAYOUT}\"")),
            "{out}"
        );
        assert!(
            out.contains("target triple = \"wasm64-unknown-unknown\""),
            "{out}"
        );
        assert!(out.contains("attributes #0 = { nounwind }"), "{out}");
        assert!(out.contains("attributes #1 = { nounwind }"), "{out}");
        assert!(!out.contains("target-cpu"), "{out}");
    }

    #[test]
    fn writes_nan_and_infinities_in_hex() {
        let ir = "%a = insertvalue { i1, double } { i1 false, double +qnan }, i1 true, 0\n\
                  store double -inf, ptr %p\nstore float +inf, ptr %q\nstore double -1.5, ptr %r\n\
                  call void @f(double f0x7FEFFFFFFFFFFFFF, float f0x3F800000, half f0x3C00)\n\
                  %mydouble = fadd double 0x7FF0000000000000, 1.0\n";
        let out = special_floats(ir).unwrap();
        assert!(out.contains("double 0x7FF8000000000000 }"), "{out}");
        assert!(out.contains("double 0xFFF0000000000000, ptr %p"), "{out}");
        assert!(out.contains("float 0x7FF0000000000000, ptr %q"), "{out}");
        assert!(out.contains("double -1.5"), "{out}");
        assert!(
            out.contains("(double 0x7FEFFFFFFFFFFFFF, float 0x3FF0000000000000, half 0xH3C00)"),
            "{out}"
        );
        assert!(
            out.contains("%mydouble = fadd double 0x7FF0000000000000, 1.0"),
            "{out}"
        );
        let err = special_floats("store double +snan, ptr %p\n")
            .unwrap_err()
            .to_string();
        assert!(err.contains("double +snan"), "{err}");
    }

    /// Each spelling Mojo 1.2's LLVM wrote for a constant of known bits (a probe that returned
    /// `bitcast` constants from `@export` functions), with the bits it stands for.
    #[test]
    fn writes_nans_with_payloads_in_hex() {
        let cases = [
            ("double +nan(0x7FFFFFFFFFFFF)", "double 0x7FFFFFFFFFFFFFFF"),
            ("double -nan(0x7FFFFFFFFFFFF)", "double 0xFFFFFFFFFFFFFFFF"),
            ("double +nan(0x1)", "double 0x7FF8000000000001"),
            ("double +nan(0x4000000000000)", "double 0x7FFC000000000000"),
            ("double +snan(0x1)", "double 0x7FF0000000000001"),
            ("double -snan(0x4000000000000)", "double 0xFFF4000000000000"),
            ("float +nan(0x3FFFFF)", "float 0x7FFFFFFFE0000000"),
            ("float +nan(0x1)", "float 0x7FF8000020000000"),
            ("float -snan(0x1)", "float 0xFFF0000020000000"),
            ("float +qnan", "float 0x7FF8000000000000"),
            ("half +nan(0x1FF)", "half 0xH7FFF"),
            ("half -snan(0x1)", "half 0xHFC01"),
            ("half +qnan", "half 0xH7E00"),
            ("bfloat +nan(0x3F)", "bfloat 0xR7FFF"),
            ("bfloat -inf", "bfloat 0xRFF80"),
        ];
        for (new, old) in cases {
            let out = special_floats(&format!("ret {new}\n")).unwrap();
            assert_eq!(out, format!("ret {old}\n"), "{new}");
        }
        let out = special_floats("store double +nan(0x1), ptr %p\n").unwrap();
        assert_eq!(out, "store double 0x7FF8000000000001, ptr %p\n");
        // A phi names the type once; its incoming values follow without one (vercel/ms).
        let phi = "  %1366 = phi double [ %1364, %1363 ], [ +inf, %1247 ]\n\
                   %2 = phi nnan float [ -nan(0x1), %a ], [ 1.0, %b ]\n\
                   %3 = phi ptr [ %p, %a ]\n";
        let out = special_floats(phi).unwrap();
        assert_eq!(
            out,
            "  %1366 = phi double [ %1364, %1363 ], [ 0x7FF0000000000000, %1247 ]\n\
             %2 = phi nnan float [ 0xFFF8000020000000, %a ], [ 1.0, %b ]\n\
             %3 = phi ptr [ %p, %a ]\n"
        );
        // So does a binary operation or a comparison for its second operand; a string that
        // spells a constant is left alone.
        let ops = "  %145 = fmul contract double %144, +inf\n\
                   %c = fcmp olt float %x, -qnan\n\
                   @s = constant [9 x i8] c\"double -inf\"\n";
        let out = special_floats(ops).unwrap();
        assert_eq!(
            out,
            "  %145 = fmul contract double %144, 0x7FF0000000000000\n\
             %c = fcmp olt float %x, 0xFFF8000000000000\n\
             @s = constant [9 x i8] c\"double -inf\"\n"
        );
        for bad in [
            "double +nan(0x8000000000000)",
            "double +snan(0x0)",
            "float +nan(0x400000)",
            "double +nan(0x1",
            "double +nan(12)",
        ] {
            let err = special_floats(&format!("ret {bad}\n"))
                .unwrap_err()
                .to_string();
            assert!(err.contains("clang cannot read"), "{bad}: {err}");
        }
    }

    #[test]
    fn refuses_x86_intrinsics_and_other_triples() {
        let sse = "target triple = \"x86_64-unknown-linux-gnu\"\n\
                   declare <16 x i8> @llvm.x86.ssse3.pshuf.b.128(<16 x i8>, <16 x i8>)\n";
        let err = retarget(sse).unwrap_err().to_string();
        assert!(err.contains("llvm.x86.ssse3.pshuf.b.128"), "{err}");
        let arm = "target triple = \"aarch64-unknown-linux-gnu\"\n";
        assert!(retarget(arm).unwrap_err().to_string().contains("aarch64"));
    }

    #[test]
    fn reads_a_modules_exports_and_imports() {
        // (module (import "env" "mw_write" (func)) (memory 1) (export "memory" (memory 0)))
        let module: &[u8] = &[
            0, b'a', b's', b'm', 1, 0, 0, 0, // header
            1, 4, 1, 0x60, 0, 0, // type section: one () -> ()
            2, 16, 1, 3, b'e', b'n', b'v', 8, b'm', b'w', b'_', b'w', b'r', b'i', b't', b'e', 0,
            0, // import env.mw_write, func type 0
            5, 3, 1, 0, 1, // memory section
            7, 10, 1, 6, b'm', b'e', b'm', b'o', b'r', b'y', 2, 0, // export "memory"
        ];
        let (exports, imports) = wasm_interface(module).unwrap();
        assert_eq!(exports, ["memory"]);
        assert_eq!(imports, ["env.mw_write"]);
        assert!(wasm_interface(b"\x7fELF....").is_err());
    }

    fn have(program: &str) -> bool {
        Command::new(program)
            .arg("--version")
            .output()
            .is_ok_and(|o| o.status.success())
    }

    /// xorshift64*: the same 100,000 patterns on every run.
    fn patterns(n: usize) -> Vec<u64> {
        let mut state = 0x9e37_79b9_7f4a_7c15u64;
        (0..n)
            .map(|_| {
                state ^= state >> 12;
                state ^= state << 25;
                state ^= state >> 27;
                state.wrapping_mul(0x2545_f491_4f6c_dd1d)
            })
            .collect()
    }

    /// Whether another number with as many significant digits as V8's shortest also reads back
    /// as `x`: the cases where the writer must pick the closest digits, not just any.
    fn has_close_rival(x: f64) -> bool {
        let text = crate::js_number::number_to_string(x);
        let (mantissa, exponent) = text.split_once('e').unwrap_or((&text, ""));
        let Some(last) = mantissa.chars().last().and_then(|c| c.to_digit(10)) else {
            return false;
        };
        let stem = &mantissa[..mantissa.len() - 1];
        [last.wrapping_sub(1), last + 1].into_iter().any(|d| {
            d <= 9 && {
                let other = format!(
                    "{stem}{d}{}",
                    if exponent.is_empty() {
                        String::new()
                    } else {
                        format!("e{exponent}")
                    }
                );
                other.parse::<f64>().ok() == Some(x)
            }
        })
    }

    /// Floats returned by a wasm port come back to JS bit for bit, and print as V8 prints the
    /// original: 100,000 random bit patterns (subnormals, -0 and close rivals included), the
    /// dispatcher's float writer checked against `js_number::number_to_string`.
    #[test]
    fn wasm_floats_match_number_to_string() {
        if !(available() && crate::mojo::available() && have("node")) {
            eprintln!("skipped: needs mojo, node and {}", missing_message());
            return;
        }
        let dir =
            std::env::temp_dir().join(format!("mojo-anything-wasm-f64-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let manifest = r#"{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "src/f.ts",
            "language": "ts", "kind": "mojo-wasm", "crate_name": "f64-mojo",
            "exports": [{"name": "echoAll", "file": "src/f.ts", "line": 1,
              "params": [{"name": "xs", "ts_type": "number[]", "optional": false, "rest": false}],
              "returns": "number[]", "is_async": false, "is_generator": false,
              "type_params": [], "uses_instanceof": false}]}"#;
        std::fs::write(dir.join(crate::bridge::MANIFEST), manifest).unwrap();
        let m = Manifest::load(&dir).unwrap();
        let port =
            "def echo_all(xs: List[Float64]) raises -> List[Float64]:\n    return xs.copy()\n";
        std::fs::write(dir.join("port.mojo"), port).unwrap();
        let mut api = crate::codegen_mojo::parse_port_mojo(port);
        crate::bridge::match_export_names(&m, &mut api);
        for (name, text) in [
            (
                crate::codegen_ffi::DISPATCHER,
                crate::codegen_ffi::dispatcher_mojo(&m, &api).unwrap(),
            ),
            ("json.mojo", crate::codegen_mojo::JSON_MOJO.to_string()),
            (
                "pixi.toml",
                crate::codegen_mojo_py::unit_pixi_toml(&m, true),
            ),
            (
                "index.cjs",
                crate::codegen_mojo_node::index_cjs_mojo(&m, &api),
            ),
        ] {
            std::fs::write(dir.join(name), text).unwrap();
        }
        build(&dir, &m).unwrap();

        let mut xs: Vec<f64> = patterns(100_000)
            .into_iter()
            .map(f64::from_bits)
            .filter(|x| x.is_finite())
            .collect();
        xs.extend([
            0.1 + 0.2,
            -0.0,
            5e-324,
            1.7976931348623157e308,
            2.2250738585072014e-308,
        ]);
        let rivals = xs.iter().filter(|x| has_close_rival(**x)).count();
        assert!(rivals > 1000, "only {rivals} close rivals");
        let input = dir.join("bits.txt");
        let hex: Vec<String> = xs.iter().map(|x| format!("{:016x}", x.to_bits())).collect();
        std::fs::write(&input, hex.join("\n")).unwrap();
        let script = format!(
            "const m = require({:?})\n\
             const bits = require('fs').readFileSync({:?}, 'utf8').split('\\n')\n\
             const f = new Float64Array(1), u = new BigUint64Array(f.buffer)\n\
             const xs = bits.map(b => {{ u[0] = BigInt('0x' + b); return f[0] }})\n\
             const out = m.echoAll(xs).map(y => {{ f[0] = y; return u[0].toString(16).padStart(16, '0') + ' ' + String(y) }})\n\
             process.stdout.write(out.join('\\n'))\n",
            dir.join("index.cjs"),
            input
        );
        let out = Command::new("timeout")
            .args(["120", "node", "-e", &script])
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let stdout = String::from_utf8(out.stdout).unwrap();
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(lines.len(), xs.len());
        for (x, line) in xs.iter().zip(&lines) {
            let (bits, text) = line.split_once(' ').unwrap();
            assert_eq!(bits, format!("{:016x}", x.to_bits()), "{x:e}: {line}");
            assert_eq!(text, crate::js_number::number_to_string(*x), "{x:e}");
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
