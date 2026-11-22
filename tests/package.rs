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
    assert!(
        wheel_name.starts_with("quopri_mojo-1.0.0-cp312-cp312-linux_"),
        "{wheel_name}"
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

// ---------------------------------------------------------------- npm

#[test]
fn mojo_node_package_is_not_yet() {
    let root = project(
        "mojo-node",
        &[
            ("package.json", r#"{"name":"shout","version":"1.2.3"}"#),
            (
                "src/shout.ts",
                "export function shout(text: string): string {\n  return text + \"!\";\n}\n",
            ),
        ],
    );
    let dir = root.join("port");
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/shout.ts",
        kind: Some(Kind::MojoNode),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    let err = package::package(&Options {
        crate_dir: &dir,
        name: None,
        version: None,
        out: None,
        dry_run: false,
    })
    .unwrap_err();
    let shown = format!("{err:#}");
    assert!(shown.starts_with("not yet:"), "{shown}");
    assert!(shown.contains("packaging plan"), "{shown}");
    assert!(
        !dir.join("package").exists(),
        "a refused package writes nothing"
    );
    std::fs::remove_dir_all(&root).unwrap();
}
