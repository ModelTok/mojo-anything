//! `package`: gated Mojo ports laid out as the packages end users install. The packages are
//! built for this machine only (pip wheel, npm pack, ...) and installed into scratch folders;
//! nothing is published.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge::{self, Kind};
use mojo_anything::harness;
use mojo_anything::package::{self, Options};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn project(name: &str, files: &[(&str, &str)]) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-package-{name}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    for (path, text) in files {
        let path = root.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
    root
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name();
        if name == ".pixi" || name == ".mojo-anything" {
            continue;
        }
        let target = to.join(&name);
        if entry.file_type().unwrap().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

fn options(dir: &Path, out: &Path) -> Options<'static> {
    Options {
        crate_dir: Box::leak(dir.to_path_buf().into_boxed_path()),
        name: None,
        version: Some("1.0.0".into()),
        out: Some(out.to_path_buf()),
        dry_run: false,
    }
}

fn run(cmd: &mut Command) -> std::process::Output {
    let out = cmd.output().unwrap();
    assert!(
        out.status.success(),
        "{cmd:?} failed:\n{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    out
}

/// A `PATH` without pixi: the system's own folders only.
const PLAIN_PATH: &str = "/usr/local/bin:/usr/bin:/bin";

/// A written workflow parses as YAML and names every supported platform (checked with Ruby's
/// YAML, when Ruby is here).
fn check_workflow(path: &Path) {
    let text = std::fs::read_to_string(path).unwrap();
    assert!(!text.contains("windows"), "{text}");
    if Command::new("ruby").arg("--version").output().is_err() {
        return;
    }
    run(Command::new("ruby")
        .args(["-ryaml", "-e", "YAML.load_file(ARGV[0]).fetch('jobs')"])
        .arg(path));
}

// ---------------------------------------------------------------- Python

const FLIP_PORT: &str = "# Port of `invert` (`flip.py:5`).
def invert(data: List[UInt8], keep_ascii: Bool) raises -> List[UInt8]:
    var out = List[UInt8](capacity=len(data))
    for c in data:
        if keep_ascii and c < 128:
            out.append(c)
        else:
            out.append(255 - c)
    return out^
";

/// `tests/fixtures/python-mojo-bytes/flip.py` bridged, ported and built in a scratch folder.
fn built_flip(tag: &str) -> (PathBuf, PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-package-flip-{tag}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    copy_dir(
        &Path::new(ROOT).join("tests/fixtures/python-mojo-bytes"),
        &root,
    );
    let dir = root.join("port");
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "flip.py",
        kind: None,
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    std::fs::write(dir.join("port.mojo"), FLIP_PORT).unwrap();
    bridge::refresh(&dir).unwrap();
    harness::build(&dir).unwrap();
    (root, dir)
}

fn python_ready() -> bool {
    common::have_mojo() && common::have("python3")
}

#[test]
fn python_package_is_named_like_the_original() {
    if !python_ready() {
        return;
    }
    let (root, dir) = built_flip("named");
    let out = root.join("pkg");
    let outcome = package::package(&options(&dir, &out)).unwrap();
    assert_eq!(outcome.kind, Kind::MojoPy);
    assert_eq!(outcome.module.as_deref(), Some("flip"), "{outcome:?}");
    for file in [
        "python/pyproject.toml",
        "python/mojo_anything_backend.py",
        "python/flip/__init__.py",
        "python/flip/_native.so",
        ".github/workflows/wheels.yml",
    ] {
        assert!(
            outcome.files.iter().any(|f| f == file),
            "{file}: {outcome:?}"
        );
        assert!(out.join(file).is_file(), "{file} not written");
    }
    let names: Vec<&str> = package::PLATFORMS.iter().map(|p| p.name).collect();
    assert_eq!(names, ["linux-x64", "linux-arm64", "darwin-arm64"]);
    let pyproject = std::fs::read_to_string(out.join("python/pyproject.toml")).unwrap();
    assert!(pyproject.contains("name = \"flip-mojo\""), "{pyproject}");
    assert!(pyproject.contains("version = \"1.0.0\""), "{pyproject}");
    assert!(pyproject.contains("mojo-compiler==1.2.0"), "{pyproject}");
    assert!(pyproject.contains("requires-python"), "{pyproject}");
    let init = std::fs::read_to_string(out.join("python/flip/__init__.py")).unwrap();
    assert!(
        init.contains("linux-x64, linux-arm64, darwin-arm64"),
        "{init}"
    );
    assert!(init.contains("def invert("), "{init}");
    let workflow = std::fs::read_to_string(out.join(".github/workflows/wheels.yml")).unwrap();
    check_workflow(&out.join(".github/workflows/wheels.yml"));
    for platform in names {
        assert!(workflow.contains(platform), "{platform}: {workflow}");
    }
    for absent in ["windows", "macos-13", "darwin-x64"] {
        assert!(!workflow.contains(absent), "{absent}: {workflow}");
    }
    // The packaged extension no longer points into the machine that built it.
    let native = std::fs::read(out.join("python/flip/_native.so")).unwrap();
    let pixi = dir.join(".pixi").display().to_string();
    assert!(
        !native.windows(pixi.len()).any(|w| w == pixi.as_bytes()),
        "the packaged _native.so still names {pixi}"
    );
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn python_package_unsupported_platform_message() {
    if !python_ready() {
        return;
    }
    let (root, dir) = built_flip("unsupported");
    let out = root.join("pkg");
    package::package(&options(&dir, &out)).unwrap();
    std::fs::remove_file(out.join("python/flip/_native.so")).unwrap();
    let ran = Command::new("python3")
        .args(["-c", "import flip"])
        .env("PYTHONPATH", out.join("python"))
        .env("PYTHONDONTWRITEBYTECODE", "1")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&ran.stderr);
    assert!(!ran.status.success(), "{stderr}");
    assert!(stderr.contains("ImportError"), "{stderr}");
    assert!(
        stderr.contains("linux-x64, linux-arm64, darwin-arm64"),
        "{stderr}"
    );
    std::fs::remove_dir_all(&root).unwrap();
}

/// CPython's `quopri.py`, which `demo/real-world/python-quopri-mojo` ported (bytes parameters).
fn quopri_source() -> Option<PathBuf> {
    let out = Command::new("python3")
        .args(["-c", "import quopri; print(quopri.__file__)"])
        .output()
        .ok()?;
    let path = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
    path.is_file().then_some(path)
}

#[test]
fn wheel_imports_in_clean_venv() {
    if !python_ready() {
        return;
    }
    let Some(quopri) = quopri_source() else {
        eprintln!("skipped: python3 has no quopri.py");
        return;
    };
    let ensurepip = Command::new("python3")
        .args(["-c", "import venv, ensurepip"])
        .output()
        .unwrap();
    if !ensurepip.status.success() {
        eprintln!("skipped: python3 has no venv or ensurepip");
        return;
    }
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-package-quopri-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    let dir = root.join("quopri-mojo");
    copy_dir(
        &Path::new(ROOT).join("demo/real-world/python-quopri-mojo/mojo/quopri-mojo"),
        &dir,
    );
    std::fs::copy(&quopri, root.join("quopri.py")).unwrap();
    let manifest_path = dir.join("mojo-anything.json");
    let mut manifest: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&manifest_path).unwrap()).unwrap();
    manifest["root"] = serde_json::json!(root);
    std::fs::write(&manifest_path, manifest.to_string()).unwrap();
    bridge::refresh(&dir).unwrap();
    harness::build(&dir).unwrap();

    let out = root.join("pkg");
    let outcome = package::package(&options(&dir, &out)).unwrap();
    // `quopri` is a standard-library module, which a site-packages module of that name never
    // shadows: the wheel keeps the wrapper's name.
    assert_eq!(
        outcome.module.as_deref(),
        Some("quopri_mojo"),
        "{outcome:?}"
    );
    assert!(
        outcome.notes.iter().any(|n| n.contains("standard library")),
        "{outcome:?}"
    );

    // Build the wheel with pip, offline, in a venv of its own.
    let builder = root.join("venv-build");
    run(Command::new("python3").arg("-m").arg("venv").arg(&builder));
    let wheels = root.join("wheels");
    run(Command::new(builder.join("bin/pip"))
        .args([
            "wheel",
            "--no-deps",
            "--no-index",
            "--no-build-isolation",
            "-w",
        ])
        .arg(&wheels)
        .arg(out.join("python"))
        .env("PATH", PLAIN_PATH));
    let wheel = std::fs::read_dir(&wheels)
        .unwrap()
        .map(|e| e.unwrap().path())
        .find(|p| p.extension().is_some_and(|x| x == "whl"))
        .expect("a wheel");
    let wheel_name = wheel.file_name().unwrap().to_string_lossy().to_string();
    // The tag is that of the `python3` this test runs, which also builds and installs the wheel.
    let version = Command::new("python3")
        .args(["-c", "import sys; print('%d%d' % sys.version_info[:2])"])
        .output()
        .unwrap();
    let version = String::from_utf8_lossy(&version.stdout).trim().to_string();
    let tag = format!("quopri_mojo-1.0.0-cp{version}-cp{version}-linux_");
    assert!(
        wheel_name.starts_with(&tag),
        "{wheel_name} (expected {tag}...)"
    );

    // Install it into a fresh venv with no pixi on PATH.
    let venv = root.join("venv");
    run(Command::new("python3").arg("-m").arg("venv").arg(&venv));
    run(Command::new(venv.join("bin/pip"))
        .args(["install", "--no-deps", "--no-index"])
        .arg(&wheel)
        .env("PATH", PLAIN_PATH));
    let python = venv.join("bin/python");

    // Without the Mojo runtime, the import says which one it needs.
    let bare = Command::new(&python)
        .args(["-c", "import quopri_mojo"])
        .env("PATH", PLAIN_PATH)
        .env_remove("MOJO_ANYTHING_MOJO_LIB")
        .env_remove("CONDA_PREFIX")
        .env_remove("LD_LIBRARY_PATH")
        .current_dir(&root)
        .output()
        .unwrap();
    let said = String::from_utf8_lossy(&bare.stderr);
    assert!(!bare.status.success(), "{said}");
    assert!(said.contains("ImportError"), "{said}");
    assert!(said.contains("mojo-compiler==1.2.0"), "{said}");

    // With the runtime's folder named, the installed wheel replays every case.
    let runtime = dir.join(".pixi/envs/default/lib");
    let empty = root.join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    let replay = mojo_anything::harness_py::replay(
        &dir,
        Command::new(&python)
            .env("PATH", PLAIN_PATH)
            .env("MOJO_ANYTHING_MOJO_LIB", &runtime)
            .env_remove("CONDA_PREFIX")
            .env_remove("LD_LIBRARY_PATH"),
        &empty,
        "quopri_mojo",
    )
    .unwrap();
    let settled = mojo_anything::recording::apply_known(
        replay,
        &mojo_anything::recording::known_diffs(&dir).unwrap(),
    );
    assert_eq!(settled.total, 481, "{settled:?}");
    assert_eq!(
        (settled.failed, settled.passed),
        (0, settled.total),
        "{:?}",
        settled.mismatches
    );
    // The module came from the venv, not from the unit's own package.
    let file = run(Command::new(&python)
        .args(["-c", "import quopri_mojo; print(quopri_mojo.__file__)"])
        .env("PATH", PLAIN_PATH)
        .env("MOJO_ANYTHING_MOJO_LIB", &runtime)
        .current_dir(&empty));
    assert!(
        String::from_utf8_lossy(&file.stdout).starts_with(&venv.display().to_string()),
        "{}",
        String::from_utf8_lossy(&file.stdout)
    );
    std::fs::remove_dir_all(&root).unwrap();
}

// ---------------------------------------------------------------- shared by the native kinds

/// The Mojo runtime's folder in a built unit's pixi environment, for the library path.
fn runtime(dir: &Path) -> PathBuf {
    dir.join(".pixi/envs/default/lib")
}

fn record_with(dir: &Path, count: usize, inputs: Option<&Path>) -> harness::RecordOutcome {
    harness::record(&harness::RecordOptions {
        crate_dir: dir,
        count,
        inputs,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap()
}

fn bridge_unit(root: &Path, unit: &str, kind: Option<Kind>, name: Option<&str>, out: &Path) {
    bridge::bridge(&bridge::Options {
        root,
        unit,
        kind,
        out: Some(out.to_path_buf()),
        name: name.map(str::to_string),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
}

fn scratch(tag: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-package-{tag}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn npm(dir: &Path, args: &[&str]) -> std::process::Output {
    run(Command::new("npm")
        .args(args)
        .args(["--offline", "--no-audit", "--no-fund"])
        .current_dir(dir))
}

/// `npm pack` in `dir`; the tarball's path.
fn pack(dir: &Path) -> PathBuf {
    let out = npm(dir, &["pack", "--silent"]);
    let name = String::from_utf8_lossy(&out.stdout)
        .trim()
        .lines()
        .last()
        .unwrap()
        .to_string();
    dir.join(name)
}

// ---------------------------------------------------------------- npm (Node-API)

#[test]
fn npm_package_installs_from_tarballs_and_falls_back_to_the_original() {
    if !(common::have("node") && common::have("npm") && common::have("cc") && common::have_mojo()) {
        return;
    }
    let root = scratch("npm");
    let fixture = Path::new(ROOT).join("tests/fixtures/mini");
    copy_dir(&fixture, &root.join("mini"));
    let dir = root.join("util-mojo");
    bridge_unit(
        &root.join("mini"),
        "packages/a/src/util.ts",
        Some(Kind::MojoNode),
        None,
        &dir,
    );
    let recorded = record_with(&dir, 60, None);
    std::fs::copy(
        Path::new(ROOT).join("tests/fixtures/mini-mojo-port/port.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    harness::build(&dir).unwrap();
    let out = root.join("pkg");
    let outcome = package::package(&options(&dir, &out)).unwrap();
    let name = outcome.name.clone();
    let host = package::host_platform().unwrap();
    let main = out.join("npm").join(&name);
    let plat = out.join("npm").join(format!("{name}-{}", host.name));
    let manifest: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(main.join("package.json")).unwrap()).unwrap();
    let optional: Vec<&String> = manifest["optionalDependencies"]
        .as_object()
        .unwrap()
        .keys()
        .collect();
    assert_eq!(optional.len(), 3, "{manifest}");
    assert_eq!(manifest["peerDependencies"]["a"], "*", "{manifest}");
    assert!(
        outcome
            .files
            .iter()
            .any(|f| f == ".github/workflows/npm.yml")
    );
    check_workflow(&out.join(".github/workflows/npm.yml"));

    // A stand-in for the original package `a`, to fall back to.
    let original = root.join("original");
    std::fs::create_dir_all(&original).unwrap();
    std::fs::write(
        original.join("package.json"),
        r#"{"name":"a","version":"1.0.0","main":"index.js"}"#,
    )
    .unwrap();
    std::fs::write(original.join("index.js"), "exports.original = true\n").unwrap();

    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(
        project.join("package.json"),
        r#"{"name":"p","version":"1.0.0"}"#,
    )
    .unwrap();
    let tarballs = [pack(&main), pack(&plat), pack(&original)];
    let mut install = vec!["install".to_string()];
    install.extend(tarballs.iter().map(|t| t.display().to_string()));
    let args: Vec<&str> = install.iter().map(String::as_str).collect();
    npm(&project, &args);

    // Every recorded case through the installed package.
    let entry = project.join("node_modules").join(&name).join("index.cjs");
    let runtime_dir = runtime(&dir);
    let replay = harness::replay_module(
        &dir,
        &entry,
        &[("LD_LIBRARY_PATH", runtime_dir.as_os_str())],
    )
    .unwrap();
    assert_eq!(
        (replay.passed, replay.failed),
        (recorded.cases, 0),
        "{:?}",
        replay.mismatches
    );

    // Without the platform package (as when npm skipped it), the calls reach the original.
    // `npm uninstall` left it in place: it is an optional dependency of the main package.
    std::fs::remove_dir_all(
        project
            .join("node_modules")
            .join(format!("{name}-{}", host.name)),
    )
    .unwrap();
    let said = run(Command::new("node")
        .arg("-e")
        .arg(format!(
            "console.log(require({:?}) === require('a'), require({:?}).original === true)",
            name, name
        ))
        .current_dir(&project));
    assert_eq!(String::from_utf8_lossy(&said.stdout), "true true\n");
    std::fs::remove_dir_all(&root).unwrap();
}

/// A bridged `mojo-node` unit with stand-in binaries (`/bin/true`): enough for `package`, and
/// for a loader that never loads them.
fn fake_built_node_unit(tag: &str, package_json: &str) -> (PathBuf, PathBuf) {
    let root = project(
        tag,
        &[
            ("package.json", package_json),
            (
                "src/shout.ts",
                "export function shout(text: string): string {\n  return text + \"!\";\n}\n",
            ),
        ],
    );
    let dir = root.join("port");
    bridge_unit(&root, "src/shout.ts", Some(Kind::MojoNode), None, &dir);
    let m = bridge::Manifest::load(&dir).unwrap();
    let host = package::host_platform().unwrap();
    std::fs::copy(
        "/bin/true",
        mojo_anything::harness_mojo_node::addon_path(&dir, &m),
    )
    .unwrap();
    std::fs::copy(
        "/bin/true",
        dir.join(format!("lib{}.{}", m.lib_name(), host.lib_ext)),
    )
    .unwrap();
    (root, dir)
}

#[test]
fn npm_loader_falls_back_on_unsupported_platform() {
    if !common::have("node") || package::host_platform().is_none() {
        return;
    }
    let win32 = "Object.defineProperty(process, 'platform', { value: 'win32' });";
    // With the original's name: the loader falls back to it.
    let (root, dir) = fake_built_node_unit("npm-loader", r#"{"name":"shout","version":"1.2.3"}"#);
    let out = root.join("pkg");
    let outcome = package::package(&options(&dir, &out)).unwrap();
    let modules = root.join("node_modules");
    copy_dir(
        &out.join("npm").join(&outcome.name),
        &modules.join(&outcome.name),
    );
    std::fs::create_dir_all(modules.join("shout")).unwrap();
    std::fs::write(
        modules.join("shout/index.js"),
        "exports.original = 'shout'\n",
    )
    .unwrap();
    let said = run(Command::new("node")
        .arg("-e")
        .arg(format!(
            "{win32} console.log(require({:?}).original)",
            outcome.name
        ))
        .current_dir(&root));
    assert_eq!(String::from_utf8_lossy(&said.stdout), "shout\n");
    std::fs::remove_dir_all(&root).unwrap();

    // Without one: an error naming the supported platforms.
    let (root, dir) =
        fake_built_node_unit("npm-loader-bare", r#"{"private":true,"version":"1.2.3"}"#);
    let out = root.join("pkg");
    let outcome = package::package(&options(&dir, &out)).unwrap();
    assert!(
        outcome.notes.iter().any(|n| n.contains("no npm name")),
        "{outcome:?}"
    );
    let modules = root.join("node_modules");
    copy_dir(
        &out.join("npm").join(&outcome.name),
        &modules.join(&outcome.name),
    );
    let failed = Command::new("node")
        .arg("-e")
        .arg(format!("{win32} require({:?})", outcome.name))
        .current_dir(&root)
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&failed.stderr);
    assert!(!failed.status.success(), "{stderr}");
    assert!(
        stderr.contains("win32-x64") || stderr.contains("win32-"),
        "{stderr}"
    );
    assert!(
        stderr.contains("linux-x64, linux-arm64, darwin-arm64"),
        "{stderr}"
    );
    std::fs::remove_dir_all(&root).unwrap();
}

// ---------------------------------------------------------------- npm (wasm)

fn wasm_ready() -> bool {
    common::have("node") && common::have("npm") && common::have_mojo() && common::have_mojowasm()
}

/// `tests/fixtures/wasm-floats` bridged to `mojo-wasm`, recorded, ported and built, then packed
/// and installed into a scratch project; the installed entry point.
fn installed_wasm(root: &Path) -> (PathBuf, PathBuf, usize) {
    copy_dir(
        &Path::new(ROOT).join("tests/fixtures/wasm-floats"),
        &root.join("floats"),
    );
    let dir = root.join("floats-mojo");
    bridge_unit(
        &root.join("floats"),
        "src/floats.ts",
        Some(Kind::MojoWasm),
        None,
        &dir,
    );
    let recorded = record_with(&dir, 60, None);
    std::fs::copy(
        Path::new(ROOT).join("tests/fixtures/wasm-floats-port/port.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    harness::build(&dir).unwrap();
    let out = root.join("pkg");
    let outcome = package::package(&options(&dir, &out)).unwrap();
    let manifest: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(out.join("npm").join(&outcome.name).join("package.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["engines"]["node"], ">=24", "{manifest}");
    check_workflow(&out.join(".github/workflows/npm.yml"));
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(
        project.join("package.json"),
        r#"{"name":"p","version":"1.0.0"}"#,
    )
    .unwrap();
    let tarball = pack(&out.join("npm").join(&outcome.name));
    npm(&project, &["install", &tarball.display().to_string()]);
    let entry = project
        .join("node_modules")
        .join(&outcome.name)
        .join("index.cjs");
    (dir, entry, recorded.cases)
}

#[test]
fn wasm_package_replays() {
    if !wasm_ready() {
        return;
    }
    let root = scratch("wasm");
    let (dir, entry, cases) = installed_wasm(&root);
    let replay = harness::replay_module(&dir, &entry, &[]).unwrap();
    assert_eq!(
        (replay.passed, replay.failed),
        (cases, 0),
        "{:?}",
        replay.mismatches
    );
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn wasm_package_needs_node_24() {
    if !wasm_ready() {
        return;
    }
    let root = scratch("wasm-node22");
    let (_dir, entry, _) = installed_wasm(&root);
    let failed = Command::new("node")
        .arg("-e")
        .arg(format!(
            "Object.defineProperty(process.versions, 'node', {{ value: '22.0.0' }}); require({:?})",
            entry.display().to_string()
        ))
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&failed.stderr);
    assert!(!failed.status.success(), "{stderr}");
    assert!(stderr.contains("needs Node 24"), "{stderr}");
    assert!(stderr.contains("22.0.0"), "{stderr}");
    std::fs::remove_dir_all(&root).unwrap();
}

// ---------------------------------------------------------------- RubyGems

/// The recorded cases whose arguments are integers beyond 64 bits, which the dispatcher refuses.
fn bignum_cases(dir: &Path) -> usize {
    std::fs::read_to_string(dir.join("cases.jsonl"))
        .unwrap()
        .lines()
        .filter(|l| {
            let c: serde_json::Value = serde_json::from_str(l).unwrap();
            c["args"].as_array().unwrap().iter().any(|a| {
                a.is_number() && a.as_i64().is_none() && a.as_u64().is_none() && !a.is_f64()
            })
        })
        .count()
}

#[test]
fn gem_installs_and_replays() {
    if !(common::have("ruby") && common::have("gem") && common::have_mojo()) {
        return;
    }
    let root = scratch("gem");
    let fixture = Path::new(ROOT).join("tests/fixtures/ruby-mojo-ports");
    copy_dir(&fixture.join("textkit"), &root.join("textkit"));
    let dir = root.join("port");
    bridge::bridge(&bridge::Options {
        root: &root.join("textkit"),
        unit: "lib/textkit.rb",
        kind: None,
        out: Some(dir.clone()),
        name: Some("textkit-mojo".into()),
        force: false,
        keep: Vec::new(),
        lang: Some(mojo_anything::lang::Lang::Ruby),
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    let recorded = record_with(&dir, 5, Some(&fixture.join("inputs.jsonl")));
    std::fs::copy(fixture.join("textkit.mojo"), dir.join("port.mojo")).unwrap();
    harness::build(&dir).unwrap();
    let out = root.join("pkg");
    package::package(&options(&dir, &out)).unwrap();
    let host = package::host_platform().unwrap();
    let gems = root.join("gems");
    check_workflow(&out.join(".github/workflows/gem.yml"));
    for spec_dir in [out.join("gem"), out.join("gem/pure")] {
        run(Command::new("gem")
            .args(["build", "textkit-mojo.gemspec"])
            .current_dir(&spec_dir));
        let gem_file = std::fs::read_dir(&spec_dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .find(|p| p.extension().is_some_and(|x| x == "gem"))
            .unwrap();
        run(Command::new("gem")
            .args(["install", "--local", "--no-document", "--install-dir"])
            .arg(&gems)
            .arg(&gem_file));
    }
    let platform = match host.name {
        "linux-x64" => "x86_64-linux",
        "linux-arm64" => "aarch64-linux",
        _ => "arm64-darwin",
    };
    let installed = gems
        .join("gems")
        .join(format!("textkit-mojo-1.0.0-{platform}"))
        .join("lib/textkit_mojo.rb");
    assert!(installed.is_file(), "{}", installed.display());
    let runtime_dir = runtime(&dir);
    let replay = mojo_anything::harness_ruby::replay(
        &dir,
        &installed,
        &[("LD_LIBRARY_PATH", runtime_dir.as_os_str())],
    )
    .unwrap();
    // Every case matches but those with integers beyond 64 bits, which are refused.
    assert_eq!(replay.failed, bignum_cases(&dir), "{replay:?}");
    assert_eq!(replay.passed + replay.failed, recorded.cases, "{replay:?}");
    // The pure-Ruby gem runs the original.
    let pure = gems.join("gems/textkit-mojo-1.0.0/lib/textkit_mojo.rb");
    let said = run(Command::new("ruby").arg("-e").arg(format!(
        "require {:?}; puts Textkit.repeat(\"ab\", 2)",
        pure.display().to_string()
    )));
    assert_eq!(String::from_utf8_lossy(&said.stdout), "abab\n");
    std::fs::remove_dir_all(&root).unwrap();
}

// ---------------------------------------------------------------- Go

#[test]
fn go_module_replays() {
    if !(common::have("go") && common::have_mojo()) {
        return;
    }
    let root = scratch("go");
    let fixture = Path::new(ROOT).join("tests/fixtures/go-mojo-ports");
    let src = root.join("textkit");
    std::fs::create_dir_all(&src).unwrap();
    for f in ["go.mod", "textkit.go"] {
        std::fs::copy(fixture.join("textkit").join(f), src.join(f)).unwrap();
    }
    let dir = root.join("port");
    bridge_unit(&src, "textkit.go", None, Some("textkit-mojo"), &dir);
    let recorded = record_with(&dir, 5, Some(&fixture.join("inputs.jsonl")));
    std::fs::copy(fixture.join("textkit.mojo"), dir.join("port.mojo")).unwrap();
    bridge::refresh(&dir).unwrap();
    harness::build(&dir).unwrap();
    let out = root.join("pkg");
    let outcome = package::package(&options(&dir, &out)).unwrap();
    let host = package::host_platform().unwrap();
    for file in [
        "go/go.mod",
        "go/unsupported.go",
        "go/cgo_linux_amd64.go",
        "go/cgo_darwin_arm64.go",
    ] {
        assert!(
            outcome.files.iter().any(|f| f == file),
            "{file}: {outcome:?}"
        );
    }
    assert!(
        out.join(format!(
            "go/lib/{}/libtextkit_mojo.{}",
            host.name, host.lib_ext
        ))
        .is_file()
    );
    check_workflow(&out.join(".github/workflows/go.yml"));
    let runtime_dir = runtime(&dir);
    let replay = mojo_anything::harness_go::replay(
        &dir,
        &out.join("go"),
        &[("LD_LIBRARY_PATH", runtime_dir.as_os_str())],
    )
    .unwrap();
    assert_eq!(
        (replay.passed, replay.failed),
        (recorded.cases, 0),
        "{:?}",
        replay.mismatches
    );
    std::fs::remove_dir_all(&root).unwrap();
}

// ---------------------------------------------------------------- C

/// The Mojo port of `tests/fixtures/c/src/text.c`.
const C_TEXT_PORT: &str = "
def _space(b: UInt8) -> Bool:
    return b == 32 or (b >= 9 and b <= 13)


def count_words(s: Optional[Span[UInt8, ImmutAnyOrigin]]) -> UInt:
    if not s:
        return 0
    var b = s.value()
    var n: UInt = 0
    var inword = False
    for i in range(len(b)):
        if _space(b[i]):
            inword = False
        elif not inword:
            inword = True
            n += 1
    return n


def vowels(s: Optional[Span[UInt8, ImmutAnyOrigin]]) -> Int32:
    if not s:
        return -1
    var b = s.value()
    var n: Int32 = 0
    for i in range(len(b)):
        var c = b[i]
        if c == 97 or c == 101 or c == 105 or c == 111 or c == 117:
            n += 1
        elif c == 65 or c == 69 or c == 73 or c == 79 or c == 85:
            n += 1
    return n


def is_palindrome(s: Optional[Span[UInt8, ImmutAnyOrigin]]) -> Bool:
    if not s:
        return False
    var b = s.value()
    for i in range(len(b) // 2):
        if b[i] != b[len(b) - 1 - i]:
            return False
    return True
";

/// A C program calling the unit, built once against the original and once against the archive.
const C_PROGRAM: &str = r#"#include <stdio.h>
#include TEXT_HEADER

int main(void) {
    const char *texts[] = {"", "a", "abba", "Hello  World", " Ae iOu\tx ", "racecar", "ab", 0};
    for (int i = 0; texts[i]; i++)
        printf("%zu %d %d\n", count_words(texts[i]), vowels(texts[i]), is_palindrome(texts[i]));
    printf("%zu %d %d\n", count_words(0), vowels(0), is_palindrome(0));
    return 0;
}
"#;

#[test]
fn c_archive_links_and_replays() {
    if !(common::have("cc") && common::have("python3") && common::have_mojo()) {
        return;
    }
    let root = scratch("c");
    let fixture = Path::new(ROOT).join("tests/fixtures/c");
    copy_dir(&fixture, &root.join("c"));
    let dir = root.join("port");
    bridge_unit(&root.join("c"), "src/text.c", None, None, &dir);
    let recorded = record_with(&dir, 40, None);
    let stubs = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    let head = stubs.split("\n\n# Port of").next().unwrap();
    std::fs::write(dir.join("port.mojo"), format!("{head}\n{C_TEXT_PORT}")).unwrap();
    harness::build(&dir).unwrap();
    let out = root.join("pkg");
    package::package(&options(&dir, &out)).unwrap();
    let host = package::host_platform().unwrap();
    let archive = out.join("c");
    let library = archive.join(format!("lib/{}/libtext_mojo.{}", host.name, host.lib_ext));
    assert!(archive.join("include/text_mojo.h").is_file());
    let pc = std::fs::read_to_string(archive.join("lib/pkgconfig/text_mojo.pc")).unwrap();
    assert!(
        pc.contains("Libs: -L${prefix}/lib/${platform} -ltext_mojo"),
        "{pc}"
    );
    check_workflow(&out.join(".github/workflows/c.yml"));

    // The recorded cases, through the archive's library.
    let runtime_dir = runtime(&dir);
    let env = [("LD_LIBRARY_PATH", runtime_dir.as_os_str())];
    let replay = mojo_anything::harness_c::replay(&dir, &library, &env).unwrap();
    assert_eq!(
        (replay.passed, replay.failed),
        (recorded.cases, 0),
        "{:?}",
        replay.mismatches
    );

    // A program compiled against the archive's header and library prints what it prints
    // against the original.
    std::fs::write(root.join("program.c"), C_PROGRAM).unwrap();
    let original = root.join("program-original");
    run(Command::new("cc")
        .arg("-DTEXT_HEADER=\"text.h\"")
        .arg("-I")
        .arg(root.join("c/src"))
        .arg(root.join("program.c"))
        .arg(root.join("c/src/text.c"))
        .arg("-o")
        .arg(&original));
    let ported = root.join("program-mojo");
    let prefix = archive.display().to_string();
    let libs = format!(
        "-L{prefix}/lib/{0} -ltext_mojo -Wl,-rpath,{prefix}/lib/{0}",
        host.name
    );
    // The linker looks for the Mojo runtime the library needs on the library path too.
    run(Command::new("cc")
        .envs(env)
        .arg("-DTEXT_HEADER=\"text_mojo.h\"")
        .arg(format!("-I{prefix}/include"))
        .arg(root.join("program.c"))
        .args(libs.split(' '))
        .arg("-o")
        .arg(&ported));
    let expected = run(&mut Command::new(&original));
    let actual = run(Command::new(&ported).envs(env));
    assert_eq!(
        String::from_utf8_lossy(&actual.stdout),
        String::from_utf8_lossy(&expected.stdout)
    );
    std::fs::remove_dir_all(&root).unwrap();
}

// ---------------------------------------------------------------- Maven

/// The Java fixture bridged to `mojo-jvm`, recorded, ported and built, then packaged; the
/// unit, the package's `java` folder and the case count.
fn packaged_java(root: &Path) -> (PathBuf, PathBuf, usize) {
    let dir = root.join("port");
    bridge_unit(
        &Path::new(ROOT).join("tests/fixtures/java"),
        "src/main/java/com/example/text/",
        None,
        Some("text-mojo"),
        &dir,
    );
    let recorded = record_with(&dir, 30, None);
    std::fs::copy(
        Path::new(ROOT).join("tests/fixtures/java-mojo-port/port.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    bridge::refresh(&dir).unwrap();
    harness::build(&dir).unwrap();
    let out = root.join("pkg");
    package::package(&options(&dir, &out)).unwrap();
    let manifest = std::fs::read_to_string(out.join("java/MANIFEST.MF")).unwrap();
    assert!(
        manifest.contains("Automatic-Module-Name: com.example.text"),
        "{manifest}"
    );
    assert!(
        manifest.contains("Enable-Native-Access: ALL-UNNAMED"),
        "{manifest}"
    );
    check_workflow(&out.join(".github/workflows/jar.yml"));
    (dir, out.join("java"), recorded.cases)
}

/// The jar built from the Maven project with `javac` and `jar` (Maven is not needed).
fn build_jar(project: &Path, into: &Path) -> PathBuf {
    let classes = into.join("classes");
    std::fs::create_dir_all(&classes).unwrap();
    let mut sources = Vec::new();
    let mut stack = vec![project.join("src/main/java")];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                stack.push(p);
            } else {
                sources.push(p);
            }
        }
    }
    run(Command::new("javac")
        .args(["--release", "22", "-encoding", "UTF-8", "-nowarn", "-d"])
        .arg(&classes)
        .args(&sources));
    let resources = project.join("src/main/resources");
    if resources.is_dir() {
        copy_dir(&resources, &classes);
    }
    let jar = into.join("text-mojo.jar");
    run(Command::new("jar")
        .args(["--create", "--file"])
        .arg(&jar)
        .arg("--manifest")
        .arg(project.join("MANIFEST.MF"))
        .arg("-C")
        .arg(&classes)
        .arg("."));
    jar
}

#[test]
fn jar_replays() {
    if !(common::have_java() && common::have("jar") && common::have_mojo()) {
        return;
    }
    let root = scratch("jar");
    let (dir, project, cases) = packaged_java(&root);
    let jar = build_jar(&project, &root.join("build"));
    let runtime_dir = runtime(&dir);
    let cache = root.join("cache");
    let replay = mojo_anything::harness_java::replay_jar(
        &dir,
        &jar,
        &[
            ("LD_LIBRARY_PATH", runtime_dir.as_os_str()),
            ("XDG_CACHE_HOME", cache.as_os_str()),
        ],
    )
    .unwrap();
    assert_eq!(
        (replay.passed, replay.failed),
        (cases, 0),
        "{:?}",
        replay.mismatches
    );
    // The library came out of the jar into the cache folder.
    let host = package::host_platform().unwrap();
    assert!(
        cache
            .join(format!(
                "mojo-anything/text-mojo-1.0.0/{}/libtext_mojo.{}",
                host.name, host.lib_ext
            ))
            .is_file()
    );
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn jar_without_native_library_says_so() {
    if !(common::have_java() && common::have("jar") && common::have_mojo()) {
        return;
    }
    let root = scratch("jar-bare");
    let (_dir, project, _) = packaged_java(&root);
    std::fs::remove_dir_all(project.join("src/main/resources/native")).unwrap();
    let jar = build_jar(&project, &root.join("build"));
    let probe = root.join("probe");
    std::fs::create_dir_all(&probe).unwrap();
    std::fs::write(
        probe.join("Probe.java"),
        "public class Probe { public static void main(String[] a) throws Exception { \
         Class.forName(\"mojoanything.TextMojoNative\"); } }\n",
    )
    .unwrap();
    run(Command::new("javac")
        .arg("-cp")
        .arg(&jar)
        .arg("-d")
        .arg(&probe)
        .arg(probe.join("Probe.java")));
    let failed = Command::new("java")
        .arg("--enable-native-access=ALL-UNNAMED")
        .arg("-cp")
        .arg(format!("{}:{}", probe.display(), jar.display()))
        .arg("Probe")
        .env("XDG_CACHE_HOME", root.join("cache"))
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&failed.stderr);
    assert!(!failed.status.success(), "{stderr}");
    assert!(stderr.contains("this jar has no Mojo library"), "{stderr}");
    assert!(
        stderr.contains("linux-x64, linux-arm64, darwin-arm64"),
        "{stderr}"
    );
    std::fs::remove_dir_all(&root).unwrap();
}
