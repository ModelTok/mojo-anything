//! Libraries: the front door is a Rust crate with the public API, units are wired as they pass
//! gate (the original package reaches them through their shadows, which honor the kill switch),
//! replay runs every wired unit's recorded cases, and the lift leaves one pure Rust library.

mod common;

use std::path::{Path, PathBuf};

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
        allocator: Default::default(),
    })
    .unwrap()
    .crate_dir
}

fn record(dir: &Path, count: usize) {
    harness::record(&RecordOptions {
        crate_dir: dir,
        count,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
}

fn door(repo: &Path, library: bool) -> front_door::FrontDoorOutcome {
    front_door::front_door(&FrontDoorOptions {
        repo,
        library,
        check: true,
    })
    .unwrap()
}

fn wire(repo: &Path, unit: &str, skip_gate: bool) -> front_door::WireOutcome {
    front_door::wire(&WireOptions {
        repo,
        unit,
        commands: &[],
        routes: &[],
        skip_gate,
        check: true,
    })
    .unwrap()
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
    if !common::have("cargo") {
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
        let repo = fixture(name);
        let dir = bridged(&repo, unit);
        let manifest = Manifest::load(&dir).unwrap();
        let shadow = mojo_anything::shadow::shadow(&dir, None).unwrap();
        let text = std::fs::read_to_string(&shadow.path).unwrap();
        let switch = front_door::kill_switch(&manifest.crate_name);
        assert!(text.contains(&switch), "{name}: no {switch} in\n{text}");
        assert!(
            text.contains("\"original\"") || text.contains("'original'"),
            "{name}"
        );
        std::fs::remove_dir_all(&repo).unwrap();
    }
}

const STAND_IN: &str = "exports.shout = text => text.toUpperCase() + '!'\n\
    exports.initials = name => name.split(/\\s+/).filter(Boolean).map(w => w[0]).join('').toUpperCase()\n";

#[test]
fn a_ts_library_moves_unit_by_unit() {
    if !common::have("node") || !common::have("cargo") {
        return;
    }
    let repo = fixture("lib/ts");
    let front = door(&repo, false);
    assert_eq!(front.api.len(), 2, "{:?}", front.api);
    let dir = bridged(&repo, "src/text.ts");
    record(&dir, 40);
    std::fs::write(dir.join("index.cjs"), STAND_IN).unwrap();

    let wired = wire(&repo, "text-rs", true);
    let shadow = wired.shadow.clone().unwrap();
    let shadow_text = std::fs::read_to_string(&shadow).unwrap();
    assert!(
        shadow_text.contains("MOJO_ANYTHING_UNIT_TEXT"),
        "{shadow_text}"
    );
    let replay = wired.replay.unwrap();
    assert!(replay.total > 40);
    assert_eq!(replay.passed, replay.total, "{:?}", replay.failures);
    let fallback = replay.fallback.unwrap();
    assert_eq!(fallback.names, ["src/nums.ts: clamp"]);
    let lib = std::fs::read_to_string(repo.join("rust/app/src/lib.rs")).unwrap();
    assert!(lib.contains("pub use text_rs::port as text;"), "{lib}");
    assert!(
        lib.contains("Still only in the original: `src/nums.ts`"),
        "{lib}"
    );

    std::fs::write(dir.join("index.cjs"), STAND_IN.replace("+ '!'", "+ '?'")).unwrap();
    let broken = mojo_anything::app::replay(&mojo_anything::app::ReplayOptions {
        case: None,
        repo: &repo,
        build: None,
        timeout_secs: None,
        port: None,
    })
    .unwrap();
    assert!(!broken.failures.is_empty());
    assert!(broken.failures.iter().all(|f| f.case == "text: shout"));
    std::fs::remove_dir_all(&repo).unwrap();
}
