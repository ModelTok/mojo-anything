//! `package` for a Python unit ported to Mojo (`mojo-py`): a project `pip wheel` builds offline
//! (an in-tree build backend, no setuptools), holding the wrapper package under the original's
//! module name and this machine's `_native.so`, and a workflow that builds the wheel on every
//! supported platform.
//!
//! The Mojo runtime is not vendored: the wheel depends on `mojo-compiler` (Modular's wheel that
//! holds it) and the package loads the runtime from there, from `MOJO_ANYTHING_MOJO_LIB`, or from
//! the active conda or pixi environment before it imports `_native`.

use std::process::Command;

use anyhow::{Context, Result, bail};

use crate::package::{Content, Generated, PLATFORMS, Unit, platform_list, repo_relative};

/// The in-tree build backend's module (`backend-path = ["."]`).
const BACKEND: &str = "mojo_anything_backend";

/// The interpreter the unit was recorded with: `python3`, as the Python driver runs it.
struct Python {
    major: u32,
    minor: u32,
    stdlib: Vec<String>,
}

fn recording_python() -> Result<Python> {
    let mut cmd = Command::new("python3");
    cmd.args([
        "-c",
        "import sys\nprint('%d %d' % sys.version_info[:2])\n\
         print(' '.join(sorted(getattr(sys, 'stdlib_module_names', ()))))",
    ]);
    let out = crate::process::output(&mut cmd, crate::process::BUILD)
        .context("running python3 to read its version")?;
    if !out.success() {
        bail!("python3 failed: {}", out.stderr_text());
    }
    let text = out.stdout_text();
    let mut lines = text.lines();
    let version = lines.next().unwrap_or_default();
    let mut parts = version.split(' ').map(str::parse::<u32>);
    let (Some(Ok(major)), Some(Ok(minor))) = (parts.next(), parts.next()) else {
        bail!("python3 printed no version: {text}");
    };
    let stdlib = lines
        .next()
        .unwrap_or_default()
        .split(' ')
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();
    Ok(Python {
        major,
        minor,
        stdlib,
    })
}

/// The module the wheel installs: the original's, unless that is a standard-library module,
/// which an installed module of the same name never shadows; then the wrapper's own name.
fn module_name(unit: &Unit, python: &Python, notes: &mut Vec<String>) -> String {
    let original = crate::package::python_module(unit.manifest);
    let top = original.split('.').next().unwrap_or_default();
    if python.stdlib.iter().any(|s| s == top) {
        let own = unit.manifest.lib_name();
        notes.push(format!(
            "`{original}` is a standard library module, which a module installed from a wheel \
             never shadows (the standard library comes first on sys.path); the wheel installs \
             `{own}` instead: import it as `import {own} as {top}`."
        ));
        own
    } else {
        original
    }
}

pub(crate) fn generate(unit: &Unit) -> Result<Generated> {
    let m = unit.manifest;
    let native = crate::harness_mojo_py::native_file(unit.dir, m);
    if !native.is_file() {
        bail!(
            "no built extension at {} (run `mojo-anything build {}` first)",
            native.display(),
            unit.dir.display()
        );
    }
    if crate::harness_mojo_py::sources_newer_than(unit.dir, &native) {
        bail!(
            "{} is older than the unit's Mojo sources; run `mojo-anything build {}` first",
            native.display(),
            unit.dir.display()
        );
    }
    let python = recording_python()?;
    let mut notes = Vec::new();
    let module = module_name(unit, &python, &mut notes);
    let module_dir = module.replace('.', "/");
    if module.contains('.') {
        notes.push(format!(
            "`{module}` is a submodule: the wheel installs `{module_dir}/` without an \
             `__init__.py` above it, so the folders above are a namespace package."
        ));
    }
    let (wrapper_dir, lib) = crate::harness_mojo_py::package(unit.dir, m);
    let wrapper = wrapper_dir.join(&lib);
    let mut files = Vec::new();
    let mut entries: Vec<_> = std::fs::read_dir(&wrapper)
        .with_context(|| format!("reading {}", wrapper.display()))?
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let file = entry.file_name().to_string_lossy().into_owned();
        let path = format!("python/{module_dir}/{file}");
        if file == "__init__.py" {
            let text = std::fs::read_to_string(entry.path())?;
            files.push((path, Content::Text(init_py(&text)?)));
        } else if file == format!("{}.so", crate::codegen_mojo_py::NATIVE) {
            files.push((
                path,
                Content::Binary(crate::package::relocatable(&entry.path())?),
            ));
        } else if !file.ends_with(".pyc") {
            files.push((path, Content::Binary(std::fs::read(entry.path())?)));
        }
    }
    let requires_python = format!(
        ">={}.{},<{}.{}",
        python.major,
        python.minor,
        python.major,
        python.minor + 1
    );
    let tag = format!("cp{}{}", python.major, python.minor);
    files.push((
        "python/pyproject.toml".into(),
        Content::Text(pyproject(unit, &requires_python)),
    ));
    files.push((
        format!("python/{BACKEND}.py"),
        Content::Text(backend_py(unit, &module_dir, &tag, &requires_python)),
    ));
    files.push((
        ".github/workflows/wheels.yml".into(),
        Content::Text(wheels_workflow(unit, &module_dir, &python)),
    ));
    notes.push(format!(
        "Build this machine's wheel with `pip wheel --no-deps --no-build-isolation {}`; \
         .github/workflows/wheels.yml builds {} (move it into your repository's .github). \
         Nothing was published.",
        unit.out.join("python").display(),
        platform_list()
    ));
    notes.push(format!(
        "The wheel needs the Mojo {} runtime: it depends on mojo-compiler=={}, or finds the \
         runtime in MOJO_ANYTHING_MOJO_LIB or the active conda or pixi environment.",
        crate::mojo::MOJO_VERSION,
        crate::mojo::MOJO_VERSION
    ));
    Ok(Generated {
        files,
        module: Some(module),
        notes,
    })
}

/// A string as a Python (and TOML) literal: JSON's escapes are valid in both.
fn literal(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

fn pyproject(unit: &Unit, requires_python: &str) -> String {
    format!(
        "# Written by mojo-anything `package`: the Mojo port of `{unit_path}`.\n\
         # `pip wheel .` builds this machine's wheel with the backend beside this file.\n\
         [build-system]\n\
         requires = []\n\
         build-backend = \"{BACKEND}\"\n\
         backend-path = [\".\"]\n\n\
         [project]\n\
         name = {name}\n\
         version = {version}\n\
         description = {description}\n\
         requires-python = \"{requires_python}\"\n\
         dependencies = [\"mojo-compiler=={mojo}\"]\n",
        unit_path = unit.manifest.unit,
        name = literal(unit.name),
        version = literal(unit.version),
        description = literal(&format!(
            "Mojo port of {}, made by mojo-anything",
            unit.manifest.unit
        )),
        mojo = crate::mojo::MOJO_VERSION,
    )
}

/// The loader that replaces the wrapper's `from . import _native`: says plainly which platform
/// or runtime is missing, loads the Mojo runtime, then the extension.
const LOADER_PY: &str = r#"import ctypes as _ctypes
import os as _os
import platform as _platform
import sys as _sys

_PLATFORMS = "@PLATFORMS@"
_MOJO = "@MOJO@"
_RUNTIME = (@RUNTIME@)


def _platform_name():
    machine = _platform.machine().lower()
    if _sys.platform.startswith("linux"):
        return {"x86_64": "linux-x64", "amd64": "linux-x64", "aarch64": "linux-arm64", "arm64": "linux-arm64"}.get(machine)
    if _sys.platform == "darwin":
        return {"arm64": "darwin-arm64"}.get(machine)
    return None


def _runtime_dir(ext):
    want = _RUNTIME[-1] + ext
    places = []
    if _os.environ.get("MOJO_ANYTHING_MOJO_LIB"):
        places.append(_os.environ["MOJO_ANYTHING_MOJO_LIB"])
    try:
        from importlib import metadata as _metadata

        for f in _metadata.files("mojo-compiler") or ():
            if f.name == want:
                places.append(str(f.locate().parent))
    except Exception:
        pass
    for prefix in (_os.environ.get("CONDA_PREFIX"), _sys.prefix):
        if prefix:
            places.append(_os.path.join(prefix, "lib"))
    for place in places:
        if _os.path.isfile(_os.path.join(place, want)):
            return place
    return None


def _load_native():
    here = _os.path.dirname(_os.path.abspath(__file__))
    name = _platform_name()
    if name is None or not _os.path.isfile(_os.path.join(here, "_native.so")):
        raise ImportError(
            f"{__name__} has no Mojo build for this machine ({_sys.platform}, {_platform.machine()}): "
            f"its wheels are built for {_PLATFORMS} only"
        )
    ext = ".dylib" if _sys.platform == "darwin" else ".so"
    lib = _runtime_dir(ext)
    if lib is None:
        raise ImportError(
            f"{__name__} needs the Mojo {_MOJO} runtime ({_RUNTIME[-1]}{ext}), which was not found: "
            f"pip install mojo-compiler=={_MOJO}, or set MOJO_ANYTHING_MOJO_LIB to the lib folder "
            "of an environment that has it"
        )
    for runtime in _RUNTIME:
        try:
            _ctypes.CDLL(_os.path.join(lib, runtime + ext), mode=_ctypes.RTLD_GLOBAL)
        except OSError as e:
            raise ImportError(f"{__name__}: loading the Mojo runtime from {lib} failed: {e}") from None
    from . import _native

    return _native


_native = _load_native()
"#;

fn init_py(wrapper: &str) -> Result<String> {
    let import = format!("from . import {}\n", crate::codegen_mojo_py::NATIVE);
    if !wrapper.contains(&import) {
        bail!(
            "the wrapper package's __init__.py has no `{}`",
            import.trim()
        );
    }
    let runtime = crate::package::MOJO_RUNTIME
        .iter()
        .map(|r| format!("\"{r}\", "))
        .collect::<String>();
    let loader = LOADER_PY
        .replace("@PLATFORMS@", &platform_list())
        .replace("@MOJO@", crate::mojo::MOJO_VERSION)
        .replace("@RUNTIME@", runtime.trim_end());
    Ok(wrapper.replacen(&import, &loader, 1))
}

/// A PEP 517 backend that packs the project folder as it is into one wheel for this machine.
const BACKEND_PY: &str = r#""""PEP 517 build backend written by mojo-anything: packs the package folder as it is (the Mojo
extension is built beforehand, by `mojo build` or the wheels workflow) into one wheel for the
machine it runs on. It needs nothing but the standard library, so `pip wheel` works offline."""

import base64
import hashlib
import io
import os
import sysconfig
import tarfile
import zipfile

NAME = @NAME@
VERSION = @VERSION@
PACKAGE = @PACKAGE@
PYTHON = @PYTHON@
REQUIRES_PYTHON = @REQUIRES_PYTHON@
REQUIRES = [@REQUIRES@]
SUMMARY = @SUMMARY@
PLATFORMS = @PLATFORMS@
DATE = (2020, 1, 1, 0, 0, 0)


def _platform_tag():
    plat = sysconfig.get_platform()
    if plat in ("linux-x86_64", "linux-aarch64"):
        return plat.replace("-", "_")
    if plat.startswith("macosx-") and plat.endswith("-arm64"):
        return plat.replace("-", "_").replace(".", "_")
    raise RuntimeError(f"{NAME}: Mojo builds only for {PLATFORMS}, not {plat}")


def _dist():
    return NAME.replace("-", "_").replace(".", "_") + "-" + VERSION


def _metadata():
    lines = ["Metadata-Version: 2.1", f"Name: {NAME}", f"Version: {VERSION}", f"Summary: {SUMMARY}"]
    lines.append(f"Requires-Python: {REQUIRES_PYTHON}")
    lines += [f"Requires-Dist: {r}" for r in REQUIRES]
    return "\n".join(lines) + "\n"


def get_requires_for_build_wheel(config_settings=None):
    return []


def get_requires_for_build_sdist(config_settings=None):
    return []


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    native = os.path.join(PACKAGE, "_native.so")
    if not os.path.isfile(native):
        raise RuntimeError(f"{native} is missing: build the Mojo extension first")
    tag = f"{PYTHON}-{PYTHON}-{_platform_tag()}"
    dist = _dist()
    info = f"{dist}.dist-info"
    filename = f"{dist}-{tag}.whl"
    record = []

    def add(z, path, data):
        entry = zipfile.ZipInfo(path, DATE)
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.external_attr = (0o755 if path.endswith(".so") else 0o644) << 16
        z.writestr(entry, data)
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        record.append(f"{path},sha256={digest},{len(data)}")

    with zipfile.ZipFile(os.path.join(wheel_directory, filename), "w") as z:
        for root, dirs, files in os.walk(PACKAGE):
            dirs[:] = sorted(d for d in dirs if d != "__pycache__")
            for file in sorted(files):
                if file.endswith(".pyc"):
                    continue
                path = os.path.join(root, file)
                with open(path, "rb") as f:
                    add(z, path.replace(os.sep, "/"), f.read())
        add(z, f"{info}/METADATA", _metadata().encode())
        wheel = f"Wheel-Version: 1.0\nGenerator: mojo-anything\nRoot-Is-Purelib: false\nTag: {tag}\n"
        add(z, f"{info}/WHEEL", wheel.encode())
        record.append(f"{info}/RECORD,,")
        entry = zipfile.ZipInfo(f"{info}/RECORD", DATE)
        z.writestr(entry, "\n".join(record) + "\n")
    return filename


def build_sdist(sdist_directory, config_settings=None):
    base = _dist()
    filename = f"{base}.tar.gz"
    with tarfile.open(os.path.join(sdist_directory, filename), "w:gz") as tar:
        for path in ["pyproject.toml", "mojo_anything_backend.py", PACKAGE]:
            tar.add(path, arcname=f"{base}/{path}", filter=lambda t: None if "__pycache__" in t.name else t)
        data = _metadata().encode()
        entry = tarfile.TarInfo(f"{base}/PKG-INFO")
        entry.size = len(data)
        tar.addfile(entry, io.BytesIO(data))
    return filename
"#;

fn backend_py(unit: &Unit, module_dir: &str, tag: &str, requires_python: &str) -> String {
    BACKEND_PY
        .replace("@NAME@", &literal(unit.name))
        .replace("@VERSION@", &literal(unit.version))
        .replace("@PACKAGE@", &literal(module_dir))
        .replace("@PYTHON@", &literal(tag))
        .replace("@REQUIRES_PYTHON@", &literal(requires_python))
        .replace(
            "@REQUIRES@",
            &literal(&format!("mojo-compiler=={}", crate::mojo::MOJO_VERSION)),
        )
        .replace(
            "@SUMMARY@",
            &literal(&format!(
                "Mojo port of {}, made by mojo-anything",
                unit.manifest.unit
            )),
        )
        .replace("@PLATFORMS@", &literal(&platform_list()))
}

/// The GitHub workflow building the wheel on every supported platform: the extension with the
/// unit's pinned Mojo, the wheel with `pip wheel`, then `auditwheel repair` (Linux) or
/// `delocate-wheel` (macOS), both told to leave the Mojo runtime out. It builds and uploads the
/// wheels as artifacts; it publishes nothing.
fn wheels_workflow(unit: &Unit, module_dir: &str, python: &Python) -> String {
    let m = unit.manifest;
    let unit_dir = repo_relative(&m.root, unit.dir);
    let out = repo_relative(&m.root, unit.out);
    let matrix: String = PLATFORMS
        .iter()
        .map(|p| {
            format!(
                "          - platform: {}\n            runner: {}\n",
                p.name, p.runner
            )
        })
        .collect();
    let exclude = |ext: &str| {
        crate::package::MOJO_RUNTIME
            .iter()
            .map(|r| format!("--exclude {r}.{ext}"))
            .collect::<Vec<_>>()
            .join(" ")
    };
    format!(
        "# Builds the wheels of {name} on {platforms}, written by mojo-anything `package`.\n\
         # Move it into the repository's .github/workflows. It builds and uploads the wheels as\n\
         # artifacts; it publishes nothing. Paths are relative to the repository root: the unit\n\
         # is {unit_dir}, the package {out}.\n\
         name: {name} wheels\n\
         on:\n  workflow_dispatch:\n  push:\n    tags: [\"v*\"]\n\
         jobs:\n  wheel:\n    strategy:\n      fail-fast: false\n      matrix:\n        include:\n\
         {matrix}\
         \x20   runs-on: ${{{{ matrix.runner }}}}\n\
         \x20   steps:\n\
         \x20     - uses: actions/checkout@v4\n\
         \x20     - uses: prefix-dev/setup-pixi@v0.8.1\n\
         \x20       with:\n          manifest-path: {unit_dir}/pixi.toml\n\
         \x20     - name: Build the Mojo extension\n\
         \x20       working-directory: {unit_dir}\n\
         \x20       run: pixi run mojo build --Werror _native.mojo --emit shared-lib -o \"$GITHUB_WORKSPACE/{out}/python/{module_dir}/_native.so\"\n\
         \x20     - uses: actions/setup-python@v5\n\
         \x20       with:\n          python-version: \"{major}.{minor}\"\n\
         \x20     - name: Build the wheel\n\
         \x20       run: python -m pip wheel --no-deps --no-build-isolation -w dist {out}/python\n\
         \x20     - name: Repair the wheel (Linux)\n\
         \x20       if: runner.os == 'Linux'\n\
         \x20       run: |\n\
         \x20         python -m pip install auditwheel patchelf\n\
         \x20         auditwheel repair {linux} -w wheelhouse dist/*.whl\n\
         \x20     - name: Repair the wheel (macOS)\n\
         \x20       if: runner.os == 'macOS'\n\
         \x20       run: |\n\
         \x20         python -m pip install delocate\n\
         \x20         delocate-wheel {mac} -w wheelhouse dist/*.whl\n\
         \x20     - uses: actions/upload-artifact@v4\n\
         \x20       with:\n          name: wheel-${{{{ matrix.platform }}}}\n          path: wheelhouse/*.whl\n",
        name = unit.name,
        platforms = platform_list(),
        major = python.major,
        minor = python.minor,
        linux = exclude("so"),
        mac = exclude("dylib"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loader_replaces_the_native_import() {
        let wrapper =
            "\"\"\"doc\"\"\"\n\nfrom . import _native\n\ndef f(x):\n    return _native.f(x)\n";
        let init = init_py(wrapper).unwrap();
        assert!(!init.contains("\nfrom . import _native\n\ndef"), "{init}");
        assert!(init.contains("_native = _load_native()"), "{init}");
        assert!(
            init.contains("linux-x64, linux-arm64, darwin-arm64"),
            "{init}"
        );
        assert!(init.contains("\"libKGENCompilerRTShared\""), "{init}");
        assert!(init.contains("def f(x):"), "{init}");
        assert!(init_py("def f(): pass\n").is_err());
    }
}
