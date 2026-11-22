//! Libraries: the front door is a Mojo package with the public API, units are wired as they pass
//! gate (the original package reaches them through their shadows, which honor the kill switch),
//! replay runs every wired unit's recorded cases, and the lift leaves one pure Mojo package.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge::{self, Manifest};
use mojo_anything::front_door::{self, AppKind, FrontDoorOptions, State, WireOptions};
use mojo_anything::harness::{self, RecordOptions};
use mojo_anything::lift::{self, LiftOptions};

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap().flatten() {
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), &target).unwrap();
        }
    }
}

fn fixture(name: &str) -> PathBuf {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let repo = std::env::temp_dir().join(format!(
        "mojo-anything-library-{}-{}-{}",
        name.replace('/', "-"),
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&repo);
    copy_dir(
        &Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(name),
        &repo,
    );
    repo
}

fn bridged(repo: &Path, unit: &str) -> PathBuf {
    bridge::bridge(&bridge::Options {
        root: repo,
        unit,
        kind: None,
        out: None,
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap()
    .crate_dir
}

fn door(repo: &Path, library: bool) -> front_door::FrontDoorOutcome {
    front_door::front_door(&FrontDoorOptions {
        repo,
        library,
        check: true,
    })
    .unwrap()
}

fn wire(repo: &Path, unit: &str, check: bool) -> front_door::WireOutcome {
    front_door::wire(&WireOptions {
        repo,
        unit,
        commands: &[],
        routes: &[],
        skip_gate: true,
        check,
    })
    .unwrap()
}

/// Mojo and Python, for the tests that build a Mojo package and run a Python unit's cases.
fn ready() -> bool {
    if !common::have_mojo() {
        eprintln!("skipping: {}", mojo_anything::mojo::missing_message());
        return false;
    }
    common::have("python3")
}

/// A second public unit for the `python-mojo` fixture, with the Mojo port the tests give it.
const GREET_PY: &str = "def greet(name: str) -> str:\n    return \"hello, \" + name\n";
const GREET_PORT: &str = "# The Mojo port of `src/greet.py`.


# Port of `greet`.
def greet(name: String) raises -> String:
    return \"hello, \" + name
";

/// The `python-mojo` fixture as a library (with `src/greet.py` as a second unit when `greet`),
/// its front door made, and `src/mathkit/` bridged to Mojo, ported (the loop tests' port, edited
/// by `edit`), recorded and built.
fn mathkit_library(greet: bool, edit: impl Fn(String) -> String) -> (PathBuf, PathBuf) {
    let repo = fixture("python-mojo");
    if greet {
        std::fs::write(repo.join("src/greet.py"), GREET_PY).unwrap();
    }
    door(&repo, true);
    let dir = bridged(&repo, "src/mathkit/");
    let port = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/python-mojo-port/port.mojo"),
    )
    .unwrap();
    std::fs::write(dir.join("port.mojo"), edit(port)).unwrap();
    record_and_build(&dir);
    (repo, dir)
}

fn record_and_build(dir: &Path) {
    let recorded = harness::record(&RecordOptions {
        crate_dir: dir,
        count: 20,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert!(recorded.cases > 0);
    harness::build(dir).unwrap();
}

fn app_dir(repo: &Path) -> PathBuf {
    repo.join(front_door::APP_DIR)
}

#[test]
fn the_public_api_is_found_in_every_language() {
    let cases = [
        ("lib/ts", "shout"),
        ("python", "slugify"),
        ("c", "count_words"),
        ("go", "Slugify"),
        ("ruby", "slugify"),
        ("java", "slugify"),
    ];
    if !common::have_mojo() {
        return;
    }
    for (name, export) in cases {
        let repo = fixture(name);
        let out = door(&repo, true);
        assert!(
            out.api
                .iter()
                .any(|a| a.exports.iter().any(|e| e == export)),
            "{name}: {:?}",
            out.api
        );
        let replay = out.replay.unwrap();
        assert_eq!((replay.passed, replay.total), (0, 0));
        let fallback = replay.fallback.unwrap();
        assert_eq!(fallback.cases, fallback.total, "{name}");
        let state = State::load(&repo).unwrap();
        assert_eq!(state.kind, AppKind::Library);
        let blocked = lift::lift(&LiftOptions { repo: &repo }).unwrap();
        assert!(!blocked.lifted);
        assert!(
            blocked
                .blockers
                .iter()
                .any(|b| b.contains("no unit is wired")),
            "{name}: {:?}",
            blocked.blockers
        );
        std::fs::remove_dir_all(&repo).unwrap();
    }
}

#[test]
fn shadows_honor_the_unit_kill_switch() {
    let units = [
        ("mini", "packages/a/src/util.ts"),
        ("python", "src/textkit/"),
        ("go", "strkit/"),
        ("ruby", "lib/textkit/"),
        ("java", "src/main/java/com/example/text/"),
    ];
    for (name, unit) in units {
        // Bridging a Java unit needs Java 22 or newer.
        if name == "java" && !common::have_java() {
            continue;
        }
        let repo = fixture(name);
        let dir = bridged(&repo, unit);
        let manifest = Manifest::load(&dir).unwrap();
        let shadow = mojo_anything::shadow::shadow(&dir, None).unwrap();
        let text = std::fs::read_to_string(&shadow.path).unwrap();
        let switch = front_door::kill_switch(&manifest.crate_name);
        assert!(text.contains(&switch), "{name}: {switch} in\n{text}");
        assert!(
            text.contains("\"original\"") || text.contains("'original'"),
            "{name}"
        );
        std::fs::remove_dir_all(&repo).unwrap();
    }
}

#[test]
fn library_front_door_is_mojo_package() {
    if !ready() {
        return;
    }
    let repo = fixture("python-mojo");
    let out = door(&repo, true);
    let app = app_dir(&repo);
    assert_eq!(out.binary, "mathkit");
    for file in ["__init__.mojo", "pixi.toml", "mojo-anything.json"] {
        assert!(app.join(file).is_file(), "{file}");
    }
    for rust in ["Cargo.toml", "src/lib.rs"] {
        assert!(!app.join(rust).exists(), "{rust}");
    }
    assert!(app.join(".mojo-anything/build/mathkit.mojoc").is_file());
    let init = std::fs::read_to_string(app.join("__init__.mojo")).unwrap();
    assert!(
        init.contains("Still only in the original: `src/mathkit/`"),
        "{init}"
    );
    let replay = out.replay.unwrap();
    assert_eq!((replay.passed, replay.total), (0, 0));
    let fallback = replay.fallback.unwrap();
    assert!(fallback.total > 0);
    assert_eq!(fallback.cases, fallback.total);
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn library_wire_reexports_port() {
    if !ready() {
        return;
    }
    let (repo, _) = mathkit_library(false, |p| p);
    let wired = wire(&repo, "mathkit-mojo", true);
    assert!(wired.shadow.is_some());
    let replay = wired.replay.unwrap();
    assert!(replay.total > 0);
    assert_eq!(
        replay.passed,
        replay.total,
        "{}",
        std::fs::read_to_string(&replay.report).unwrap()
    );
    assert_eq!(replay.fallback.unwrap().cases, 0);
    let app = app_dir(&repo);
    let init = std::fs::read_to_string(app.join("__init__.mojo")).unwrap();
    assert!(
        init.contains("from mathkit.units.mathkit import port as mathkit"),
        "{init}"
    );

    // A Mojo program reaches the port through the package, under the unit's name.
    let user = repo.join("user");
    std::fs::create_dir_all(&user).unwrap();
    std::fs::write(
        user.join("main.mojo"),
        "from mathkit import mathkit\n\n\ndef main() raises:\n    print(mathkit.exclaim(\"hi\"))\n",
    )
    .unwrap();
    let mut build = mojo_anything::mojo::command(&app).unwrap();
    build
        .current_dir(&user)
        .args(["build", "--Werror", "-I"])
        .arg(app.join(".mojo-anything/build"))
        .args(["main.mojo", "-o"])
        .arg(user.join("user"));
    let built = build.output().unwrap();
    assert!(
        built.status.success(),
        "{}{}",
        String::from_utf8_lossy(&built.stdout),
        String::from_utf8_lossy(&built.stderr)
    );
    let out = Command::new(user.join("user")).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout), "hi!\n");
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn library_lift_needs_zero_fallback() {
    if !ready() {
        return;
    }
    let (repo, mathkit) = mathkit_library(true, |p| p);
    let state = State::load(&repo).unwrap();
    assert_eq!(state.api.len(), 2, "{:?}", state.api);
    let blocked = lift::lift(&LiftOptions { repo: &repo }).unwrap();
    assert!(
        blocked
            .blockers
            .iter()
            .any(|b| b.contains("no unit is wired")),
        "{:?}",
        blocked.blockers
    );

    wire(&repo, "mathkit-mojo", true);
    let blocked = lift::lift(&LiftOptions { repo: &repo }).unwrap();
    assert!(!blocked.lifted);
    assert!(
        blocked
            .blockers
            .iter()
            .any(|b| b.contains("still only in the original") && b.contains("greet")),
        "{:?}",
        blocked.blockers
    );

    let greet = bridged(&repo, "src/greet.py");
    std::fs::write(greet.join("port.mojo"), GREET_PORT).unwrap();
    record_and_build(&greet);
    let wired = wire(&repo, "greet-mojo", true);
    assert_eq!(wired.replay.unwrap().fallback.unwrap().cases, 0);

    let lifted = lift::lift(&LiftOptions { repo: &repo }).unwrap();
    assert!(
        lifted.lifted,
        "{:?}\n{:?}",
        lifted.blockers, lifted.checklist
    );
    for item in [
        "mojo/app: mojo precompile",
        "mojo/app: mojo format",
        "mathkit-mojo: ported",
        "greet-mojo: mojo format",
        "replay",
    ] {
        assert!(
            lifted
                .checklist
                .iter()
                .any(|i| i.name == item && i.mark == lift::Mark::Pass),
            "{item}: {:?}",
            lifted.checklist
        );
    }
    let app = app_dir(&repo);
    let package = lifted.binary.unwrap();
    assert_eq!(package, app.join(".mojo-anything/build/mathkit.mojoc"));
    assert!(package.is_file());
    let init = std::fs::read_to_string(app.join("__init__.mojo")).unwrap();
    assert!(init.contains("mojo-anything app lift"), "{init}");
    assert!(init.contains("import port as greet"), "{init}");
    assert!(State::load(&repo).unwrap().lifted);
    for unit in [&mathkit, &greet] {
        assert!(unit.join("port.mojo").is_file());
        assert!(!unit.join("_native.mojo").exists(), "{}", unit.display());
        assert!(!unit.join("python").exists(), "{}", unit.display());
    }
    assert!(mathkit.join("py_num.mojo").is_file(), "the port imports it");
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn library_kill_switch_uses_original() {
    if !ready() {
        return;
    }
    // A port that answers differently from the original shows which one a call reached.
    let (repo, _) = mathkit_library(false, |p| {
        p.replace("return text + \"!\"", "return text + \"?\"")
    });
    let wired = wire(&repo, "mathkit-mojo", false);
    assert_eq!(wired.switch, "MOJO_ANYTHING_UNIT_MATHKIT");
    let shadow = wired.shadow.unwrap();
    let module = shadow.file_stem().unwrap().to_string_lossy().into_owned();
    let call = |switch: Option<&str>| {
        let mut cmd = Command::new("python3");
        cmd.arg("-c")
            .arg(format!(
                "import sys; sys.path.insert(0, {:?}); import {module}; print({module}.exclaim('hi'))",
                shadow.parent().unwrap().to_string_lossy()
            ))
            .env("MOJO_ANYTHING_MODE", "new")
            .env_remove(&wired.switch);
        if let Some(value) = switch {
            cmd.env(&wired.switch, value);
        }
        let out = cmd.output().unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    };
    assert_eq!(call(None), "hi?", "the port answers");
    assert_eq!(call(Some("original")), "hi!", "the original answers");
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn library_takes_mojo_units_and_refuses_rust_crates() {
    if !common::have_mojo() {
        return;
    }
    let repo = fixture("lib/ts");
    let front = door(&repo, false);
    assert_eq!(front.api.len(), 2, "{:?}", front.api);
    let dir = bridged(&repo, "src/text.ts");
    assert!(dir.ends_with("mojo/text-mojo"), "{}", dir.display());
    wire(&repo, "text-mojo", false);
    let init = std::fs::read_to_string(app_dir(&repo).join("__init__.mojo")).unwrap();
    assert!(init.contains("import port as text"), "{init}");
    std::fs::remove_dir_all(&repo).unwrap();

    // Bridging a Java unit needs Java 22 or newer.
    if !common::have_java() {
        return;
    }
    let repo = fixture("java");
    door(&repo, true);
    let wire_unit = |unit: &Path| {
        front_door::wire(&WireOptions {
            repo: &repo,
            unit: &unit.to_string_lossy(),
            commands: &[],
            routes: &[],
            skip_gate: true,
            check: false,
        })
        .unwrap_err()
    };
    // A Rust-era JNI crate is refused.
    let rust = bridge::bridge(&bridge::Options {
        root: &repo,
        unit: "src/main/java/com/example/text/",
        kind: Some(bridge::Kind::Ffi),
        out: None,
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap()
    .crate_dir;
    assert!(rust.join("Cargo.toml").is_file(), "{}", rust.display());
    let refused = wire_unit(&rust);
    assert!(
        format!("{refused:#}").contains("is a Rust crate"),
        "{refused:#}"
    );
    // So is a Java unit ported to Mojo: front doors do not wire `mojo-jvm` units yet.
    let unit = bridged(&repo, "src/main/java/com/example/text/");
    assert!(unit.join("port.mojo").is_file(), "{}", unit.display());
    let refused = wire_unit(&unit);
    assert!(format!("{refused:#}").contains("mojo-jvm"), "{refused:#}");
    std::fs::remove_dir_all(&repo).unwrap();
}
