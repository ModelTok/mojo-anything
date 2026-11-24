//! `app record` and `app replay` on the same small CLI written in each of the six languages.
//!
//! Each test copies its fixture to a temp folder, records the original, replays the original
//! (everything matches), then replays a build whose division-by-zero message changed (only those
//! cases fail, with a diff in the report). A test is skipped when its runtime is missing.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::app::{self, RecordOptions, ReplayOptions};
use mojo_anything::front_door::{self, FrontDoorOptions, WireOptions};
use mojo_anything::front_door_mojo;
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

fn fixture(lang: &str) -> PathBuf {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let repo = std::env::temp_dir().join(format!(
        "mojo-anything-app-test-{lang}-{}-{n}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&repo);
    copy_dir(
        &Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/cli")
            .join(lang),
        &repo,
    );
    repo
}

fn sh(repo: &Path, program: &str, args: &[&str]) {
    let out = Command::new(program)
        .args(args)
        .current_dir(repo)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{program} {args:?}: {}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

fn add_bug(repo: &Path, source: &str, copy_to: Option<&str>) {
    let text = std::fs::read_to_string(repo.join(source)).unwrap();
    assert!(text.contains("division by zero"));
    std::fs::write(
        repo.join(copy_to.unwrap_or(source)),
        text.replace("division by zero", "divide by zero"),
    )
    .unwrap();
}

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_string).collect()
}

fn record_then_replay(repo: &Path, run: &str, buggy: &str) {
    let outcome = app::record(&RecordOptions {
        repo,
        run: &words(run),
        inputs: None,
        normalize: &[],
        name: None,
        traps: true,
        timeout_secs: None,
        http: false,
        server_args: &[],
        fresh: &[],
        pace_ms: None,
        port: None,
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap();
    assert_eq!(outcome.examples, 7, "{outcome:?}");
    assert!(outcome.traps > 30, "{outcome:?}");
    assert!(outcome.unstable.is_empty(), "{outcome:?}");
    assert!(outcome.timed_out.is_empty(), "{outcome:?}");
    assert_eq!(outcome.noisy, ["example-006-now"], "{outcome:?}");

    let dir = app::cases_dir(repo);
    let read = |name: &str| std::fs::read_to_string(dir.join(name)).unwrap();
    assert_eq!(
        read("example-006-now.stdout").lines().collect::<Vec<_>>(),
        ["now: [..]"]
    );
    let div = read("example-003-div.toml");
    assert!(div.contains("args = [\"div\", \"7\", \"2\"]"), "{div}");
    assert!(div.contains("status.code = 0"), "{div}");
    assert_eq!(
        read("example-003-div.stdout").lines().collect::<Vec<_>>(),
        ["7 / 2 = 3 remainder 1"]
    );
    assert_eq!(read("example-004-words.stdin"), "one two three\n");
    assert_eq!(
        read("example-004-words.stdout").lines().collect::<Vec<_>>(),
        ["3"]
    );
    assert!(dir.join("example-005-copy.in/input.txt").is_file());
    assert!(
        read("example-005-copy.out/out.txt").starts_with("GR"),
        "the copy wrote its output file"
    );
    assert!(read("example-007-nope.toml").contains("status.code = 1"));
    assert!(read("example-007-nope.stderr").starts_with("usage: tcli"));

    let original = app::replay(&ReplayOptions {
        case: None,
        repo,
        build: None,
        timeout_secs: None,
        port: None,
    })
    .unwrap();
    assert_eq!(original.total, outcome.cases);
    assert_eq!(
        original.passed,
        original.total,
        "{}",
        std::fs::read_to_string(&original.report).unwrap()
    );
    assert!(original.fallback.is_none());

    let bug = app::replay(&ReplayOptions {
        case: None,
        repo,
        build: Some(buggy),
        timeout_secs: None,
        port: None,
    })
    .unwrap();
    assert!(!bug.failures.is_empty());
    assert_eq!(bug.passed + bug.failures.len(), bug.total);
    for f in &bug.failures {
        assert_eq!(f.args[0], "div", "{f:?}");
        assert!(f.problems.iter().all(|p| p.field == "stderr"), "{f:?}");
    }
    let report = std::fs::read_to_string(&bug.report).unwrap();
    assert!(report.contains("- error: division by zero"), "{report}");
    assert!(report.contains("+ error: divide by zero"), "{report}");

    let one = app::replay(&ReplayOptions {
        case: Some(&bug.failures[0].case),
        repo,
        build: Some(buggy),
        timeout_secs: None,
        port: None,
    })
    .unwrap();
    assert_eq!((one.total, one.failures.len()), (1, 1));
    let missing = app::replay(&ReplayOptions {
        case: Some("no-such-case"),
        repo,
        build: None,
        timeout_secs: None,
        port: None,
    });
    assert!(missing.unwrap_err().to_string().contains("no case named"));
    std::fs::remove_dir_all(repo).unwrap();
}

/// The front door is a Mojo binary in `mojo/app` that answers every recorded case through the
/// original, each one a fallback.
fn front_door_falls_back(repo: &Path) -> app::ReplayOutcome {
    let door = front_door::front_door(&FrontDoorOptions {
        repo,
        library: false,
        check: true,
    })
    .unwrap();
    let replay = door.replay.unwrap();
    assert_eq!(
        replay.passed,
        replay.total,
        "{}",
        std::fs::read_to_string(&replay.report).unwrap()
    );
    let fallback = replay.fallback.as_ref().unwrap();
    assert_eq!(fallback.cases, replay.total, "{fallback:?}");
    let app_dir = repo.join(front_door::APP_DIR);
    assert_eq!(app_dir, repo.join("mojo/app"));
    for file in ["pixi.toml", "main.mojo", "original.mojo", "units.mojo"] {
        assert!(app_dir.join(file).is_file(), "{file}");
    }
    assert!(!app_dir.join("Cargo.toml").exists());
    let exe = Path::new(&replay.build[0]);
    assert!(
        exe.starts_with(app_dir.join(".mojo-anything/build")),
        "{}",
        exe.display()
    );
    // `mojo format` has no check mode: formatting again must change nothing.
    let sources: Vec<String> = front_door_mojo::SOURCES
        .iter()
        .map(|f| std::fs::read_to_string(app_dir.join(f)).unwrap())
        .collect();
    let out = mojo_anything::mojo::command(&app_dir)
        .unwrap()
        .current_dir(&app_dir)
        .arg("format")
        .args(front_door_mojo::SOURCES)
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    for (file, before) in front_door_mojo::SOURCES.iter().zip(&sources) {
        let after = std::fs::read_to_string(app_dir.join(file)).unwrap();
        assert_eq!(&after, before, "{file} is not as `mojo format` writes it");
    }
    replay
}

/// Records the CLI fixture without traps and checks its Mojo front door.
fn cli_front_door_falls_back(repo: &Path, run: &str) {
    app::record(&RecordOptions {
        repo,
        run: &words(run),
        inputs: None,
        normalize: &[],
        name: None,
        traps: false,
        timeout_secs: None,
        http: false,
        server_args: &[],
        fresh: &[],
        pace_ms: None,
        port: None,
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap();
    let door = front_door_falls_back(repo);
    assert_eq!(door.total, 7, "{door:?}");
    let state = front_door::State::load(repo).unwrap();
    assert_eq!(
        state.commands,
        ["copy", "div", "len", "now", "upper", "words"]
    );
    // Then a Mojo unit takes over `words`, whatever language the original is in.
    write_mojo_unit(repo, "wordcount-mojo", WORDCOUNT_PORT_MOJO);
    let stub = wire_mojo(repo, "wordcount-mojo", &["words"], true);
    assert!(stub.glue_pending);
    assert_eq!(stub.switch, "MOJO_ANYTHING_UNIT_WORDCOUNT");
    std::fs::write(&stub.glue, WORDCOUNT_GLUE_MOJO).unwrap();
    let wired = wire_mojo(repo, "wordcount-mojo", &[], true);
    assert!(!wired.glue_pending);
    assert_eq!(wired.commands, ["words"]);
    let replay = wired.replay.unwrap();
    assert_eq!(
        replay.passed,
        replay.total,
        "{}",
        std::fs::read_to_string(&replay.report).unwrap()
    );
    let fallback = replay.fallback.as_ref().unwrap();
    assert_eq!(fallback.cases, fallback.total - 1, "{fallback:?}");
    assert!(
        !fallback.names.iter().any(|n| n.contains("words")),
        "{fallback:?}"
    );
    std::fs::remove_dir_all(repo).unwrap();
}

/// Writes a hand-made Mojo unit: `mojo/<folder>/port.mojo` and the pixi project it builds in.
fn write_mojo_unit(repo: &Path, folder: &str, port: &str) {
    let unit = repo.join("mojo").join(folder);
    std::fs::create_dir_all(&unit).unwrap();
    std::fs::write(unit.join("port.mojo"), port).unwrap();
    std::fs::write(
        unit.join("pixi.toml"),
        front_door_mojo::pixi_toml_app(folder, false),
    )
    .unwrap();
}

fn wire_mojo(repo: &Path, unit: &str, commands: &[&str], check: bool) -> front_door::WireOutcome {
    front_door::wire(&WireOptions {
        repo,
        unit,
        commands: &commands.iter().map(|c| c.to_string()).collect::<Vec<_>>(),
        routes: &[],
        skip_gate: true,
        check,
    })
    .unwrap()
}

const WORDCOUNT_PORT_MOJO: &str =
    "# The Mojo port of the original's `words`: words between ASCII whitespace.


def count_words(data: List[UInt8]) -> Int:
    var count = 0
    var in_word = False
    for i in range(len(data)):
        var b = data[i]
        if b == 32 or (b >= 9 and b <= 13):
            in_word = False
        elif not in_word:
            in_word = True
            count += 1
    return count
";

const WORDCOUNT_GLUE_MOJO: &str = "from wordcount import port


def words(args: List[String]) raises -> Int:
    var data = open(\"/dev/stdin\", \"r\").read_bytes()
    print(port.count_words(data))
    return 0
";

/// Glue that hands a case back to the original after reading stdin.
const WORDCOUNT_DECLINING_GLUE_MOJO: &str = "import original
from wordcount import port


def _starts_with(data: List[UInt8], prefix: String) -> Bool:
    var p = prefix.as_bytes()
    if len(data) < len(p):
        return False
    for i in range(len(p)):
        if data[i] != p[i]:
            return False
    return True


def words(args: List[String]) raises -> Int:
    var data = open(\"/dev/stdin\", \"r\").read_bytes()
    if _starts_with(data, \"#original\"):
        return original.run_with_stdin(args, data)
    print(port.count_words(data))
    return 0
";

/// Records the Python CLI fixture from `inputs` (JSON lines) and builds its front door.
fn python_repo_from_inputs(inputs: &str) -> PathBuf {
    let repo = fixture("python");
    std::fs::write(repo.join("inputs.jsonl"), inputs).unwrap();
    let path = repo.join("inputs.jsonl");
    app::record(&RecordOptions {
        repo: &repo,
        run: &words("python3 tcli.py"),
        inputs: Some(&path),
        normalize: &[],
        name: Some("tcli"),
        traps: false,
        timeout_secs: None,
        http: false,
        server_args: &[],
        fresh: &[],
        pace_ms: None,
        port: None,
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap();
    repo
}

fn record_python_examples() -> PathBuf {
    let repo = fixture("python");
    app::record(&RecordOptions {
        repo: &repo,
        run: &words("python3 tcli.py"),
        inputs: None,
        normalize: &[],
        name: None,
        traps: false,
        timeout_secs: None,
        http: false,
        server_args: &[],
        fresh: &[],
        pace_ms: None,
        port: None,
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap();
    repo
}

fn replay_build(repo: &Path, build: &str) -> app::ReplayOutcome {
    app::replay(&ReplayOptions {
        case: None,
        repo,
        build: Some(build),
        timeout_secs: None,
        port: None,
    })
    .unwrap()
}

#[test]
fn wire_writes_mojo_glue() {
    if !common::have("python3") || !mojo() {
        return;
    }
    let repo = record_python_examples();
    let door = front_door_falls_back(&repo);
    write_mojo_unit(&repo, "textops-mojo", &textops_port_mojo(&CHARS));
    let wired = wire_mojo(&repo, "textops-mojo", &["upper"], true);
    let glue = repo.join("mojo/app/glue/textops.mojo");
    assert_eq!(wired.glue, glue);
    let text = std::fs::read_to_string(&glue).unwrap();
    assert!(front_door::is_stub(&text), "{text}");
    assert!(wired.glue_pending);
    assert!(
        text.contains("def upper(args: List[String]) raises -> Int:"),
        "{text}"
    );
    assert!(text.contains("return original.run(args)"), "{text}");
    // The stub names what the port offers.
    assert!(text.contains("port.upper(text: String)"), "{text}");
    assert!(repo.join("mojo/app/glue/__init__.mojo").is_file());
    let units = std::fs::read_to_string(repo.join("mojo/app/units.mojo")).unwrap();
    assert!(units.contains("from glue import textops"), "{units}");
    let replay = wired.replay.unwrap();
    assert_eq!(replay.passed, replay.total, "{:?}", replay.failures);
    assert_eq!(
        replay.fallback.unwrap().cases,
        door.fallback.unwrap().cases,
        "the stub still hands every case to the original"
    );
    let state = front_door::State::load(&repo).unwrap();
    assert_eq!(state.units[0].path, "../../mojo/textops-mojo");
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn wired_command_runs_in_mojo() {
    if !common::have("python3") || !mojo() {
        return;
    }
    let repo = record_python_examples();
    let door = front_door_falls_back(&repo);
    let before = door.fallback.unwrap();
    write_mojo_unit(&repo, "textops-mojo", &textops_port_mojo(&CHARS));
    let stub = wire_mojo(&repo, "textops-mojo", &["upper"], false);
    std::fs::copy(fixture_glue("textops.mojo"), &stub.glue).unwrap();
    let wired = wire_mojo(&repo, "textops-mojo", &[], true);
    assert!(!wired.glue_pending);
    let replay = wired.replay.unwrap();
    assert_eq!(
        replay.passed,
        replay.total,
        "{}",
        std::fs::read_to_string(&replay.report).unwrap()
    );
    let upper = cases_of(&repo, "upper");
    assert!(upper > 0);
    let after = replay.fallback.unwrap();
    assert_eq!(after.cases, before.cases - upper, "{after:?}");
    assert!(
        !after.names.iter().any(|n| n.contains("upper")),
        "{after:?}"
    );
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn kill_switch_sends_command_back() {
    if !common::have("python3") || !mojo() {
        return;
    }
    let repo = record_python_examples();
    let door = front_door_falls_back(&repo);
    write_mojo_unit(&repo, "textops-mojo", &textops_port_mojo(&CHARS));
    let stub = wire_mojo(&repo, "textops-mojo", &["upper"], false);
    std::fs::copy(fixture_glue("textops.mojo"), &stub.glue).unwrap();
    let wired = wire_mojo(&repo, "textops-mojo", &[], true);
    let exe = wired.replay.unwrap().build[0].clone();
    assert!(wired.switch == "MOJO_ANYTHING_UNIT_TEXTOPS");
    let switched = replay_build(&repo, &format!("env {}=original {exe}", wired.switch));
    assert_eq!(switched.passed, switched.total, "{:?}", switched.failures);
    assert_eq!(
        switched.fallback.unwrap().cases,
        door.fallback.unwrap().cases,
        "every case falls back again"
    );
    // Any other value leaves the unit on.
    let on = replay_build(&repo, &format!("env {}=mojo {exe}", wired.switch));
    assert!(on.fallback.unwrap().cases < switched.total);
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn glue_declines_with_stdin() {
    if !common::have("python3") || !mojo() {
        return;
    }
    let repo = python_repo_from_inputs(concat!(
        r#"{"name": "plain", "args": ["words"], "stdin": "alpha  beta\tgamma delta\n"}"#,
        "\n",
        r##"{"name": "declined", "args": ["words"], "stdin": "#original four five six\n"}"##,
        "\n",
        r#"{"name": "empty", "args": ["words"], "stdin": ""}"#,
        "\n",
    ));
    front_door_falls_back(&repo);
    write_mojo_unit(&repo, "wordcount-mojo", WORDCOUNT_PORT_MOJO);
    let stub = wire_mojo(&repo, "wordcount-mojo", &["words"], false);
    std::fs::write(&stub.glue, WORDCOUNT_DECLINING_GLUE_MOJO).unwrap();
    let wired = wire_mojo(&repo, "wordcount-mojo", &[], true);
    let replay = wired.replay.unwrap();
    assert_eq!(
        replay.passed,
        replay.total,
        "{}",
        std::fs::read_to_string(&replay.report).unwrap()
    );
    // The README's examples are recorded too; every `words` case but one is answered in Mojo.
    let words = cases_of(&repo, "words");
    assert_eq!(words, 4);
    let fallback = replay.fallback.unwrap();
    assert_eq!(fallback.cases, replay.total - (words - 1), "{fallback:?}");
    assert!(
        fallback.names.iter().any(|n| n == "declined"),
        "{fallback:?}"
    );
    for answered in ["plain", "empty", "example-004-words"] {
        assert!(
            !fallback.names.iter().any(|n| n == answered),
            "{fallback:?}"
        );
    }
    std::fs::remove_dir_all(&repo).unwrap();
}

/// How many recorded cases start with `command`.
fn cases_of(repo: &Path, command: &str) -> usize {
    let wanted = format!("args = [\"{command}\"");
    std::fs::read_dir(app::cases_dir(repo))
        .unwrap()
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "toml"))
        .filter(|e| {
            std::fs::read_to_string(e.path())
                .unwrap_or_default()
                .contains(&wanted)
        })
        .count()
}

fn fixture_glue(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/app-glue")
        .join(name)
}

fn mojo() -> bool {
    mojo_anything::mojo::available()
}

#[test]
fn ts_cli_front_door_falls_back() {
    if !common::have("node") || !mojo() {
        return;
    }
    cli_front_door_falls_back(&fixture("ts"), "node tcli.js");
}

#[test]
fn python_cli_front_door_falls_back() {
    if !common::have("python3") || !mojo() {
        return;
    }
    cli_front_door_falls_back(&fixture("python"), "python3 tcli.py");
}

#[test]
fn c_cli_front_door_falls_back() {
    if !common::have("cc") || !mojo() {
        return;
    }
    let repo = fixture("c");
    sh(&repo, "cc", &["-O1", "-o", "tcli", "tcli.c"]);
    cli_front_door_falls_back(&repo, "./tcli");
}

#[test]
fn go_cli_front_door_falls_back() {
    if !common::have("go") || !mojo() {
        return;
    }
    let repo = fixture("go");
    sh(&repo, "go", &["build", "-o", "tcli", "."]);
    cli_front_door_falls_back(&repo, "./tcli");
}

#[test]
fn ruby_cli_front_door_falls_back() {
    if !common::have("ruby") || !mojo() {
        return;
    }
    cli_front_door_falls_back(&fixture("ruby"), "ruby tcli.rb");
}

#[test]
fn java_cli_front_door_falls_back() {
    if !common::have("javac") || !common::have("java") || !mojo() {
        return;
    }
    let repo = fixture("java");
    sh(&repo, "javac", &["-d", "classes", "Tcli.java"]);
    cli_front_door_falls_back(&repo, "java -XX:-UsePerfData -cp ./classes Tcli");
}

#[test]
fn php_cli_front_door_falls_back() {
    if !common::have("php") || !mojo() {
        return;
    }
    cli_front_door_falls_back(&fixture("php"), "php tcli.php");
}

#[test]
fn csharp_cli_front_door_falls_back() {
    if !common::have("dotnet") || !mojo() {
        return;
    }
    let repo = fixture("csharp");
    dotnet_build(&repo, "out");
    cli_front_door_falls_back(&repo, "dotnet out/tcli.dll");
}

/// A CLI that copies stdin to stdout, exits with a given code, or kills itself.
const BYTES_TOOL: &str = r#"#!/bin/sh
case "$1" in
  echo) cat ;;
  exit) echo "leaving with $2"; echo "to stderr" >&2; exit "$2" ;;
  term) echo "about to stop"; kill -TERM $$ ;;
  sleep) echo $$ > "$2"; exec sleep 30 ;;
esac
"#;

fn bytes_tool_repo() -> PathBuf {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let repo = std::env::temp_dir().join(format!(
        "mojo-anything-app-bytes-{}-{n}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&repo);
    std::fs::create_dir_all(&repo).unwrap();
    std::fs::write(repo.join("tool.sh"), BYTES_TOOL).unwrap();
    std::fs::write(
        repo.join("inputs.jsonl"),
        concat!(
            r#"{"name": "bytes", "args": ["echo"], "stdin": "placeholder\n"}"#,
            "\n",
            r#"{"name": "exit-3", "args": ["exit", "3"]}"#,
            "\n",
            r#"{"name": "term", "args": ["term"]}"#,
            "\n",
        ),
    )
    .unwrap();
    let inputs = repo.join("inputs.jsonl");
    let outcome = app::record(&RecordOptions {
        repo: &repo,
        run: &["sh".to_string(), "tool.sh".to_string()],
        inputs: Some(&inputs),
        normalize: &[],
        name: Some("tool"),
        traps: false,
        timeout_secs: None,
        http: false,
        server_args: &[],
        fresh: &[],
        pace_ms: None,
        port: None,
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap();
    assert_eq!(outcome.cases, 3, "{outcome:?}");
    repo
}

fn replay_original(repo: &Path) -> app::ReplayOutcome {
    app::replay(&ReplayOptions {
        case: None,
        repo,
        build: None,
        timeout_secs: None,
        port: None,
    })
    .unwrap()
}

#[test]
fn fallback_passes_bytes_through() {
    if !mojo() {
        return;
    }
    let repo = bytes_tool_repo();
    // Recorded inputs are text; the case is made binary by hand: not UTF-8, and a NUL.
    let dir = app::cases_dir(&repo);
    let bytes = [0xff_u8, 0x00, 0xfe];
    std::fs::write(dir.join("bytes.stdin"), bytes).unwrap();
    std::fs::write(dir.join("bytes.stdout"), bytes).unwrap();
    let toml = dir.join("bytes.toml");
    let text = std::fs::read_to_string(&toml).unwrap();
    std::fs::write(
        &toml,
        format!(
            "binary = true
{text}"
        ),
    )
    .unwrap();
    let original = replay_original(&repo);
    assert_eq!(original.passed, original.total, "{:?}", original.failures);

    let replay = front_door_falls_back(&repo);
    assert_eq!(replay.total, 3);

    // A byte changed in the expected output fails, so the case compares bytes.
    std::fs::write(dir.join("bytes.stdout"), [0xff_u8, 0x00, 0xfd]).unwrap();
    let changed = app::replay(&ReplayOptions {
        case: Some("bytes"),
        repo: &repo,
        build: Some(&replay.build[0]),
        timeout_secs: None,
        port: None,
    })
    .unwrap();
    assert_eq!(changed.passed, 0, "{changed:?}");
    std::fs::remove_dir_all(&repo).unwrap();
}

#[cfg(unix)]
#[test]
fn fallback_keeps_exit_status() {
    if !mojo() {
        return;
    }
    let repo = bytes_tool_repo();
    let dir = app::cases_dir(&repo);
    let read = |name: &str| std::fs::read_to_string(dir.join(name)).unwrap();
    assert!(
        read("exit-3.toml").contains("status.code = 3"),
        "{}",
        read("exit-3.toml")
    );
    assert!(
        read("term.toml").contains("interrupted"),
        "{}",
        read("term.toml")
    );
    let replay = front_door_falls_back(&repo);
    assert_eq!(replay.total, 3);

    // Outside the replay: the same code, and the same signal, from the front door itself.
    let exe = &replay.build[0];
    let three = Command::new(exe).args(["exit", "3"]).output().unwrap();
    assert_eq!(three.status.code(), Some(3));
    assert_eq!(String::from_utf8_lossy(&three.stdout), "leaving with 3\n");
    assert_eq!(String::from_utf8_lossy(&three.stderr), "to stderr\n");
    let term = Command::new(exe).arg("term").output().unwrap();
    {
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(term.status.signal(), Some(15), "{:?}", term.status);
    }

    // A parent that ignores SIGCHLD makes waitpid fail: the front door says so and exits
    // non-zero instead of reporting success.
    let ignored = Command::new("python3")
        .args([
            "-c",
            "import os, signal, sys\nsignal.signal(signal.SIGCHLD, signal.SIG_IGN)\nos.execv(sys.argv[1], sys.argv[1:])",
            exe,
            "exit",
            "3",
        ])
        .output()
        .unwrap();
    std::fs::remove_dir_all(&repo).unwrap();
    let stderr = String::from_utf8_lossy(&ignored.stderr);
    assert_ne!(ignored.status.code(), Some(0), "{ignored:?}");
    assert!(stderr.contains("cannot wait for the original"), "{stderr}");
}

/// Whether process `pid` is gone (or a zombie nobody has reaped yet).
#[cfg(target_os = "linux")]
fn gone(pid: u32) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/stat")).map_or(true, |stat| {
        stat.rsplit(')')
            .next()
            .is_some_and(|s| s.trim_start().starts_with('Z'))
    })
}

#[cfg(target_os = "linux")]
#[test]
fn killing_the_front_door_stops_the_original() {
    if !mojo() {
        return;
    }
    let repo = bytes_tool_repo();
    let replay = front_door_falls_back(&repo);
    let exe = &replay.build[0];
    let mut seen = Vec::new();
    for signal in ["-TERM", "-KILL"] {
        let pid_file = repo.join(format!("original{signal}.pid"));
        let mut door = Command::new(exe)
            .args(["sleep", &pid_file.to_string_lossy()])
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        let original: u32 = loop {
            if let Some(pid) = std::fs::read_to_string(&pid_file)
                .ok()
                .and_then(|t| t.trim().parse().ok())
            {
                break pid;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the original never started"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        };
        sh(&repo, "kill", &[signal, &door.id().to_string()]);
        let status = door.wait().unwrap();
        let stopped = std::time::Instant::now();
        while !gone(original) && stopped.elapsed() < std::time::Duration::from_secs(3) {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let left = !gone(original);
        if left {
            let _ = Command::new("kill")
                .args(["-KILL", &original.to_string()])
                .status();
        }
        seen.push((signal, status, left, stopped.elapsed()));
    }
    std::fs::remove_dir_all(&repo).unwrap();
    use std::os::unix::process::ExitStatusExt;
    for (signal, status, left, after) in &seen {
        assert!(
            !left,
            "{signal}: the original outlived the front door: {seen:?}"
        );
        assert!(
            *after < std::time::Duration::from_secs(1),
            "{signal}: the original took {after:?} to stop"
        );
        let expected = if *signal == "-TERM" { 15 } else { 9 };
        assert_eq!(status.signal(), Some(expected), "{signal}: {status:?}");
    }
}

#[test]
fn ts_cli_records_and_replays() {
    if !common::have("node") {
        return;
    }
    let repo = fixture("ts");
    add_bug(&repo, "tcli.js", Some("tcli-bug.js"));
    record_then_replay(&repo, "node tcli.js", "node tcli-bug.js");
}

#[test]
fn python_cli_records_and_replays() {
    if !common::have("python3") {
        return;
    }
    let repo = fixture("python");
    add_bug(&repo, "tcli.py", Some("tcli_bug.py"));
    record_then_replay(&repo, "python3 tcli.py", "python3 tcli_bug.py");
}

#[test]
fn c_cli_records_and_replays() {
    if !common::have("cc") {
        return;
    }
    let repo = fixture("c");
    sh(&repo, "cc", &["-O1", "-o", "tcli", "tcli.c"]);
    add_bug(&repo, "tcli.c", Some("tcli-bug.c"));
    sh(&repo, "cc", &["-O1", "-o", "tcli-bug", "tcli-bug.c"]);
    record_then_replay(&repo, "./tcli", "./tcli-bug");
}

#[test]
fn go_cli_records_and_replays() {
    if !common::have("go") {
        return;
    }
    let repo = fixture("go");
    sh(&repo, "go", &["build", "-o", "tcli", "."]);
    add_bug(&repo, "main.go", None);
    sh(&repo, "go", &["build", "-o", "tcli-bug", "."]);
    record_then_replay(&repo, "./tcli", "./tcli-bug");
}

#[test]
fn ruby_cli_records_and_replays() {
    if !common::have("ruby") {
        return;
    }
    let repo = fixture("ruby");
    add_bug(&repo, "tcli.rb", Some("tcli_bug.rb"));
    record_then_replay(&repo, "ruby tcli.rb", "ruby tcli_bug.rb");
}

#[test]
fn php_cli_records_and_replays() {
    if !common::have("php") {
        return;
    }
    let repo = fixture("php");
    add_bug(&repo, "tcli.php", Some("tcli_bug.php"));
    record_then_replay(&repo, "php tcli.php", "php tcli_bug.php");
}

#[test]
fn java_cli_records_and_replays() {
    if !common::have("javac") || !common::have("java") {
        return;
    }
    let repo = fixture("java");
    sh(&repo, "javac", &["-d", "classes", "Tcli.java"]);
    add_bug(&repo, "Tcli.java", None);
    sh(&repo, "javac", &["-d", "classes-bug", "Tcli.java"]);
    record_then_replay(
        &repo,
        "java -XX:-UsePerfData -cp ./classes Tcli",
        "java -XX:-UsePerfData -cp ./classes-bug Tcli",
    );
}

fn dotnet_build(repo: &Path, out: &str) {
    sh(
        repo,
        "dotnet",
        &["build", "-c", "Release", "--nologo", "-v", "q", "-o", out],
    );
}

#[test]
fn csharp_cli_records_and_replays() {
    if !common::have("dotnet") {
        return;
    }
    let repo = fixture("csharp");
    dotnet_build(&repo, "out");
    add_bug(&repo, "Program.cs", None);
    dotnet_build(&repo, "out-bug");
    record_then_replay(&repo, "dotnet out/tcli.dll", "dotnet out-bug/tcli.dll");
}

#[test]
fn the_command_exits_non_zero_on_a_mismatch() {
    if !common::have("python3") {
        return;
    }
    let repo = fixture("python");
    add_bug(&repo, "tcli.py", Some("tcli_bug.py"));
    std::fs::write(
        repo.join("inputs.jsonl"),
        "{\"name\": \"stamped\", \"args\": [\"upper\", \"at 2026-11-16T10:00:00Z\"]}\n\
         {\"args\": [\"copy\", \"a.txt\", \"b.txt\"], \"files\": {\"a.txt\": \"x\"}}\n\
         {\"args\": [\"div\", \"1\", \"0\"]}\n",
    )
    .unwrap();
    let bin = env!("CARGO_BIN_EXE_mojo-anything");
    let record = Command::new(bin)
        .args(["app", "record"])
        .arg(&repo)
        .args([
            "--no-traps",
            "--inputs",
            "inputs.jsonl",
            "--normalize",
            "timestamps",
            "--",
            "python3",
            "tcli.py",
        ])
        .current_dir(&repo)
        .output()
        .unwrap();
    assert!(
        record.status.success(),
        "{}",
        String::from_utf8_lossy(&record.stderr)
    );
    let dir = app::cases_dir(&repo);
    assert_eq!(
        std::fs::read_to_string(dir.join("stamped.stdout"))
            .unwrap()
            .lines()
            .collect::<Vec<_>>(),
        ["AT [..]"]
    );
    assert_eq!(
        std::fs::read_to_string(dir.join("input-002-copy.out/b.txt")).unwrap(),
        "X"
    );
    let config = std::fs::read_to_string(dir.join(app::CONFIG_FILE)).unwrap();
    assert!(config.contains("\"timestamps\""), "{config}");

    let replay = |build: Option<&str>| {
        let mut cmd = Command::new(bin);
        cmd.args(["app", "replay"]).arg(&repo);
        if let Some(b) = build {
            cmd.args(["--build", b]);
        }
        cmd.output().unwrap()
    };
    let good = replay(None);
    assert!(good.status.success());
    assert!(String::from_utf8_lossy(&good.stdout).starts_with("10/10 cases passed"));
    let bad = replay(Some("python3 tcli_bug.py"));
    assert_eq!(bad.status.code(), Some(1));
    let text = String::from_utf8_lossy(&bad.stdout);
    assert!(text.starts_with("9/10 cases passed"), "{text}");
    assert!(text.contains("- input-003-div: stderr"), "{text}");
    std::fs::remove_dir_all(&repo).unwrap();
}

/// How the original counts and uppercases: a faithful port matches its own language.
struct Semantics {
    count: &'static str,
    upper: &'static str,
    unit: &'static str,
}

const CHARS: Semantics = Semantics {
    count: "Count::Chars",
    upper: "Upper::Full",
    unit: "characters",
};

/// The same port in Mojo, as `mojo format` writes it.
fn textops_port_mojo(s: &Semantics) -> String {
    let upper = match s.upper {
        "Upper::Full" => "FULL",
        "Upper::Simple" => "SIMPLE",
        _ => "ASCII",
    };
    let bytes = if s.count == "Count::Bytes" {
        "True"
    } else {
        "False"
    };
    format!(
        "# The Mojo port of the original's text operations.

comptime FULL = 0
comptime SIMPLE = 1
comptime ASCII = 2
comptime UPPER = {upper}
comptime COUNT_BYTES = {bytes}
comptime UNIT = \"{}\"


def upper(text: String) -> String:
    comptime if UPPER == FULL:
        return text.upper()
    else:
        var out = String()
        for c in text.codepoint_slices():
            var one = String(c)
            comptime if UPPER == ASCII:
                if one.byte_length() > 1:
                    out += one
                    continue
            var up = one.upper()
            if up.count_codepoints() == 1:
                out += up
            else:
                out += one
        return out


def count(text: String) -> Int:
    comptime if COUNT_BYTES:
        return text.byte_length()
    else:
        return text.count_codepoints()


def div(a: Int, b: Int) raises -> Tuple[Int, Int]:
    if b == 0:
        raise Error(\"division by zero\")
    return (a // b, a % b)
",
        s.unit
    )
}

/// Glue for every command of the CLI fixture, in Mojo.
const TEXTOPS_GLUE_MOJO: &str = "from std.sys import stderr
from std.time import perf_counter_ns

from textops import port


def _usage() -> Int:
    print(\"usage: tcli upper|len|div|words|copy|now\", file=stderr)
    return 1


def upper(args: List[String]) raises -> Int:
    var words = String()
    for i in range(1, len(args)):
        if i > 1:
            words += \" \"
        words += args[i]
    print(port.upper(words))
    return 0


def len_(args: List[String]) raises -> Int:
    if len(args) != 2:
        return _usage()
    print(port.count(args[1]))
    return 0


def div(args: List[String]) raises -> Int:
    if len(args) != 3:
        return _usage()
    try:
        var a = Int(args[1])
        var b = Int(args[2])
        if b == 0:
            print(\"error: division by zero\", file=stderr)
            return 2
        var qr = port.div(a, b)
        print(a, \"/\", b, \"=\", qr[0], \"remainder\", qr[1])
        return 0
    except:
        print(\"error: not a number\", file=stderr)
        return 2


def copy(args: List[String]) raises -> Int:
    if len(args) != 3:
        return _usage()
    var text: String
    try:
        text = open(args[1], \"r\").read()
    except:
        print(\"error: cannot read\", args[1], file=stderr)
        return 1
    try:
        var out = open(args[2], \"w\")
        out.write(port.upper(text))
        out.close()
    except:
        print(\"error: cannot write\", args[2], file=stderr)
        return 1
    print(\"copied\", port.count(text), port.UNIT)
    return 0


def now(args: List[String]) raises -> Int:
    print(\"now:\", perf_counter_ns())
    return 0


def tcli(args: List[String]) raises -> Int:
    return _usage()
";

/// The lift's checklist item called `name` passed.
fn passed(outcome: &lift::LiftOutcome, name: &str) -> bool {
    outcome
        .checklist
        .iter()
        .any(|i| i.name == name && i.mark == lift::Mark::Pass)
}

/// Record, front door, wire every command to Mojo units, lift, then replay the pure binary with
/// the original moved away: nothing may still need it.
fn lift_end_to_end(repo: &Path, run: &str, semantics: &Semantics, original: &str) {
    app::record(&RecordOptions {
        repo,
        run: &words(run),
        inputs: None,
        normalize: &[],
        name: None,
        traps: false,
        timeout_secs: None,
        http: false,
        server_args: &[],
        fresh: &[],
        pace_ms: None,
        port: None,
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap();
    front_door_falls_back(repo);

    let blocked = lift::lift(&LiftOptions { repo }).unwrap();
    assert!(!blocked.lifted);
    assert!(
        blocked
            .blockers
            .iter()
            .any(|b| b.contains("no unit is wired")),
        "{:?}",
        blocked.blockers
    );

    write_mojo_unit(repo, "wordcount-mojo", WORDCOUNT_PORT_MOJO);
    write_mojo_unit(repo, "textops-mojo", &textops_port_mojo(semantics));
    let words_glue = wire_mojo(repo, "wordcount-mojo", &["words"], false).glue;
    std::fs::write(&words_glue, WORDCOUNT_DECLINING_GLUE_MOJO).unwrap();
    let partial = wire_mojo(repo, "textops-mojo", &["upper", "len"], true);
    let fallback = partial.replay.unwrap().fallback.unwrap();
    assert!(fallback.cases > 0);
    let blocked = lift::lift(&LiftOptions { repo }).unwrap();
    assert!(!blocked.lifted);
    assert!(
        blocked
            .blockers
            .iter()
            .any(|b| b.contains("the glue in") && b.contains("textops")),
        "{:?}",
        blocked.blockers
    );
    assert!(
        blocked
            .blockers
            .iter()
            .any(|b| b.contains("wordcount") && b.contains("hands cases to the original")),
        "{:?}",
        blocked.blockers
    );
    std::fs::write(&words_glue, WORDCOUNT_GLUE_MOJO).unwrap();
    std::fs::write(&partial.glue, TEXTOPS_GLUE_MOJO).unwrap();
    let blocked = lift::lift(&LiftOptions { repo }).unwrap();
    assert!(
        blocked
            .blockers
            .iter()
            .any(|b| b.contains("still fall back") && b.contains("example-003-div")),
        "{:?}",
        blocked.blockers
    );

    let all = wire_mojo(
        repo,
        "textops-mojo",
        &["upper", "len", "div", "copy", "now", "tcli"],
        true,
    );
    assert!(!all.glue_pending);
    let replay = all.replay.unwrap();
    assert_eq!(
        replay.passed,
        replay.total,
        "{}",
        std::fs::read_to_string(&replay.report).unwrap()
    );
    assert_eq!(replay.fallback.unwrap().cases, 0);

    let lifted = lift::lift(&LiftOptions { repo }).unwrap();
    assert!(
        lifted.lifted,
        "{:?}\n{:?}",
        lifted.blockers, lifted.checklist
    );
    assert!(
        lifted.checklist.iter().all(|i| i.mark != lift::Mark::Fail),
        "{:?}",
        lifted.checklist
    );
    for item in [
        "mojo/app: mojo build",
        "mojo/app: mojo format",
        "no original.",
        "no fallback",
        "replay",
        "textops-mojo: mojo format",
        "wordcount-mojo: ported",
    ] {
        assert!(passed(&lifted, item), "{item}: {:?}", lifted.checklist);
    }
    let replay = lifted.replay.as_ref().unwrap();
    assert_eq!(replay.passed, replay.total);

    let app_dir = repo.join(front_door::APP_DIR);
    assert!(!app_dir.join("original.mojo").exists());
    let main = std::fs::read_to_string(app_dir.join("main.mojo")).unwrap();
    assert!(!main.contains("original"), "{main}");
    let units = std::fs::read_to_string(app_dir.join("units.mojo")).unwrap();
    assert!(!units.contains("MOJO_ANYTHING_UNIT"), "{units}");
    for glue in ["glue/textops.mojo", "glue/wordcount.mojo"] {
        let text = std::fs::read_to_string(app_dir.join(glue)).unwrap();
        assert!(!text.contains("original"), "{glue}: {text}");
    }
    assert!(front_door::State::load(repo).unwrap().lifted);
    let binary = lifted.binary.as_ref().unwrap();
    assert!(binary.starts_with(app_dir.join(".mojo-anything/build")));

    let hidden = repo.join(format!("{original}.hidden"));
    std::fs::rename(repo.join(original), &hidden).unwrap();
    let pure = replay_build(repo, &binary.to_string_lossy());
    assert_eq!(
        pure.passed,
        pure.total,
        "{}",
        std::fs::read_to_string(&pure.report).unwrap()
    );
    assert!(
        pure.fallback.is_none(),
        "the pure binary has no fallback hook"
    );
    std::fs::rename(&hidden, repo.join(original)).unwrap();

    let again = lift::lift(&LiftOptions { repo });
    assert!(again.is_err());
    let rewire = front_door::wire(&WireOptions {
        repo,
        unit: "wordcount-mojo",
        commands: &[],
        routes: &[],
        skip_gate: true,
        check: false,
    });
    assert!(rewire.is_err());
    std::fs::remove_dir_all(repo).unwrap();
}

#[test]
fn ts_cli_lifts_to_pure_mojo() {
    if !common::have("node") || !mojo() {
        return;
    }
    lift_end_to_end(&fixture("ts"), "node tcli.js", &CHARS, "tcli.js");
}

#[test]
fn python_cli_lifts_to_pure_mojo() {
    if !common::have("python3") || !mojo() {
        return;
    }
    lift_end_to_end(&fixture("python"), "python3 tcli.py", &CHARS, "tcli.py");
}

#[test]
fn c_cli_lifts_to_pure_mojo() {
    if !common::have("cc") || !mojo() {
        return;
    }
    let repo = fixture("c");
    sh(&repo, "cc", &["-O1", "-o", "tcli", "tcli.c"]);
    let bytes = Semantics {
        count: "Count::Bytes",
        upper: "Upper::Ascii",
        unit: "bytes",
    };
    lift_end_to_end(&repo, "./tcli", &bytes, "tcli");
}

#[test]
fn go_cli_lifts_to_pure_mojo() {
    if !common::have("go") || !mojo() {
        return;
    }
    let repo = fixture("go");
    sh(&repo, "go", &["build", "-o", "tcli", "."]);
    let go = Semantics {
        count: "Count::Bytes",
        upper: "Upper::Simple",
        unit: "bytes",
    };
    lift_end_to_end(&repo, "./tcli", &go, "tcli");
}

#[test]
fn php_cli_lifts_to_pure_mojo() {
    if !common::have("php") || !mojo() {
        return;
    }
    lift_end_to_end(&fixture("php"), "php tcli.php", &CHARS, "tcli.php");
}

#[test]
fn ruby_cli_lifts_to_pure_mojo() {
    if !common::have("ruby") || !mojo() {
        return;
    }
    lift_end_to_end(&fixture("ruby"), "ruby tcli.rb", &CHARS, "tcli.rb");
}

#[test]
fn java_cli_lifts_to_pure_mojo() {
    if !common::have("javac") || !common::have("java") || !mojo() {
        return;
    }
    let repo = fixture("java");
    sh(&repo, "javac", &["-d", "classes", "Tcli.java"]);
    lift_end_to_end(
        &repo,
        "java -XX:-UsePerfData -cp ./classes Tcli",
        &CHARS,
        "classes",
    );
}

#[test]
fn csharp_cli_lifts_to_pure_mojo() {
    if !common::have("dotnet") || !mojo() {
        return;
    }
    let repo = fixture("csharp");
    dotnet_build(&repo, "out");
    let invariant = Semantics {
        count: "Count::Chars",
        upper: "Upper::Simple",
        unit: "characters",
    };
    lift_end_to_end(&repo, "dotnet out/tcli.dll", &invariant, "out");
}

/// A hash of every file under `dir` (paths and bytes), leaving out the build and pixi folders,
/// which a build rewrites.
fn tree_hash(dir: &Path) -> u64 {
    use std::hash::{Hash, Hasher};
    fn walk(dir: &Path, root: &Path, out: &mut Vec<(String, Vec<u8>)>) {
        for entry in std::fs::read_dir(dir).unwrap().flatten() {
            let name = entry.file_name();
            // The replay report is rewritten by every replay, the lift's first one included.
            if name == ".pixi" || name == ".mojo-anything" || name == "replay-report.md" {
                continue;
            }
            let path = entry.path();
            if entry.file_type().unwrap().is_dir() {
                walk(&path, root, out);
            } else {
                let rel = path
                    .strip_prefix(root)
                    .unwrap()
                    .to_string_lossy()
                    .into_owned();
                out.push((rel, std::fs::read(&path).unwrap()));
            }
        }
    }
    let mut files = Vec::new();
    walk(dir, dir, &mut files);
    files.sort();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    files.hash(&mut hasher);
    hasher.finish()
}

#[test]
fn failed_lift_leaves_repo_unchanged() {
    if !common::have("python3") || !mojo() {
        return;
    }
    let repo = record_python_examples();
    front_door_falls_back(&repo);
    write_mojo_unit(&repo, "wordcount-mojo", WORDCOUNT_PORT_MOJO);
    // A port that builds and answers every case, but not as `mojo format` writes it: the
    // unit's gate fails only on the lifted copy.
    write_mojo_unit(
        &repo,
        "textops-mojo",
        &(textops_port_mojo(&CHARS) + "\n\n\n"),
    );
    let glue = wire_mojo(&repo, "wordcount-mojo", &["words"], false).glue;
    std::fs::write(&glue, WORDCOUNT_GLUE_MOJO).unwrap();
    let glue = wire_mojo(
        &repo,
        "textops-mojo",
        &["upper", "len", "div", "copy", "now", "tcli"],
        false,
    )
    .glue;
    std::fs::write(&glue, TEXTOPS_GLUE_MOJO).unwrap();
    let mojo_dir = repo.join("mojo");
    let before = tree_hash(&mojo_dir);
    let outcome = lift::lift(&LiftOptions { repo: &repo }).unwrap();
    assert!(!outcome.lifted);
    assert!(
        outcome
            .blockers
            .iter()
            .any(|b| b.starts_with("textops-mojo: mojo format")),
        "{:?}",
        outcome.blockers
    );
    // Everything else passed on the copy, which is kept to look at.
    assert!(passed(&outcome, "replay"), "{:?}", outcome.checklist);
    let stage = outcome.stage.as_ref().unwrap();
    assert!(!stage.join("mojo/app/original.mojo").exists());
    assert_eq!(
        tree_hash(&mojo_dir),
        before,
        "the failed lift changed mojo/"
    );
    assert!(repo.join("mojo/app/original.mojo").is_file());
    assert!(!front_door::State::load(&repo).unwrap().lifted);
    std::fs::remove_dir_all(stage).unwrap();
    std::fs::remove_dir_all(&repo).unwrap();
}

/// A CLI that upper-cases a file and reads a `.textopsrc` beside it, like a formatter reading
/// its config.
const CONFIG_TOOL: &str = "import os
import sys

prefix = \"\"
if os.path.exists(\".textopsrc\"):
    with open(\".textopsrc\") as f:
        for line in f:
            if line.startswith(\"prefix=\"):
                prefix = line[len(\"prefix=\"):].rstrip(\"\\n\")
with open(sys.argv[2]) as f:
    print(prefix + f.read().strip().upper())
";

const CONFIG_NAIVE_GLUE: &str = "from textops import port


def upper(args: List[String]) raises -> Int:
    var text = open(args[1], \"r\").read()
    print(port.upper(String(text.strip())))
    return 0
";

const CONFIG_DECLINING_GLUE: &str = "from std.os.path import exists

import original
from textops import port


def upper(args: List[String]) raises -> Int:
    if exists(\".textopsrc\"):
        return original.run(args)
    var text = open(args[1], \"r\").read()
    print(port.upper(String(text.strip())))
    return 0
";

const CONFIG_GLUE: &str = "from std.os.path import exists

from textops import port


def upper(args: List[String]) raises -> Int:
    var prefix = String()
    if exists(\".textopsrc\"):
        var config = open(\".textopsrc\", \"r\").read()
        for line in config.splitlines():
            if line.startswith(\"prefix=\"):
                prefix = String(line[byte=7:])
    var text = open(args[1], \"r\").read()
    print(prefix + port.upper(String(text.strip())))
    return 0
";

#[test]
fn cli_with_config_file_falls_back() {
    if !common::have("python3") || !mojo() {
        return;
    }
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let repo = std::env::temp_dir().join(format!(
        "mojo-anything-app-config-{}-{n}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&repo);
    std::fs::create_dir_all(&repo).unwrap();
    std::fs::write(repo.join("textops.py"), CONFIG_TOOL).unwrap();
    let inputs = repo.join("inputs.jsonl");
    std::fs::write(
        &inputs,
        concat!(
            r#"{"name": "plain", "args": ["upper", "in.txt"], "files": {"in.txt": "hello"}}"#,
            "\n",
            r#"{"name": "configured", "args": ["upper", "in.txt"], "files": {"in.txt": "hello", ".textopsrc": "prefix=>> "}}"#,
            "\n",
        ),
    )
    .unwrap();
    app::record(&RecordOptions {
        repo: &repo,
        run: &words("python3 textops.py"),
        inputs: Some(&inputs),
        normalize: &[],
        name: Some("textops"),
        traps: false,
        timeout_secs: None,
        http: false,
        server_args: &[],
        fresh: &[],
        pace_ms: None,
        port: None,
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap();
    let dir = app::cases_dir(&repo);
    assert_eq!(
        std::fs::read_to_string(dir.join("configured.stdout")).unwrap(),
        ">> HELLO\n"
    );
    front_door_falls_back(&repo);
    write_mojo_unit(&repo, "textops-mojo", &textops_port_mojo(&CHARS));
    let glue = wire_mojo(&repo, "textops-mojo", &["upper"], false).glue;

    // Glue that never looks at the config fails the configured case: it cannot pass because it
    // was recorded in an empty folder.
    std::fs::write(&glue, CONFIG_NAIVE_GLUE).unwrap();
    let naive = wire_mojo(&repo, "textops-mojo", &[], true).replay.unwrap();
    let failed: Vec<&str> = naive.failures.iter().map(|f| f.case.as_str()).collect();
    assert_eq!(failed, ["configured"], "{:?}", naive.failures);

    // Glue that hands the configured case back: it falls back and matches, and blocks the lift.
    std::fs::write(&glue, CONFIG_DECLINING_GLUE).unwrap();
    let declining = wire_mojo(&repo, "textops-mojo", &[], true).replay.unwrap();
    assert_eq!(
        declining.passed, declining.total,
        "{:?}",
        declining.failures
    );
    assert_eq!(declining.fallback.unwrap().names, ["configured"]);
    let blocked = lift::lift(&LiftOptions { repo: &repo }).unwrap();
    assert!(!blocked.lifted);
    assert!(
        blocked
            .blockers
            .iter()
            .any(|b| b.contains("still fall back") && b.contains("configured")),
        "{:?}",
        blocked.blockers
    );

    // Glue that reads the config itself answers both, and the lift goes through.
    std::fs::write(&glue, CONFIG_GLUE).unwrap();
    let handled = wire_mojo(&repo, "textops-mojo", &[], true).replay.unwrap();
    assert_eq!(handled.passed, handled.total, "{:?}", handled.failures);
    assert_eq!(handled.fallback.unwrap().cases, 0);
    let lifted = lift::lift(&LiftOptions { repo: &repo }).unwrap();
    assert!(lifted.lifted, "{:?}", lifted.blockers);
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn lift_strips_bridge_bindings_in_every_language() {
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let base = std::env::temp_dir().join(format!("mojo-anything-strip-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let units = [
        ("mini", "packages/a/src/util.ts", "ts"),
        ("go", "strkit/", "go"),
        ("ruby", "lib/textkit/", "ruby"),
        ("python-mojo", "src/mathkit/", "python"),
        ("c", "src/text.c", "c"),
        ("java", "src/main/java/com/example/text/", "java"),
    ];
    for (fixture, unit, lang) in units {
        let dir = base.join(lang);
        mojo_anything::bridge::bridge(&mojo_anything::bridge::Options {
            root: &fixtures.join(fixture),
            unit,
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
        if lang != "java" {
            let imported = front_door_mojo::port_modules(&dir);
            let removed = lift::strip_unit(&dir).unwrap();
            assert!(!removed.is_empty(), "{lang}");
            for generated in [
                "_native.mojo",
                "python",
                "dispatcher.mojo",
                "exports.mojo",
                "exports_shadow.mojo",
                "include",
                "node_shim.c",
                "binding.gyp",
                "index.cjs",
                "go",
                "ruby",
            ] {
                assert!(!dir.join(generated).exists(), "{lang}: {generated}");
            }
            assert!(dir.join("port.mojo").is_file(), "{lang}");
            assert!(
                dir.join(mojo_anything::bridge::MANIFEST).is_file(),
                "{lang}"
            );
            // The helpers the port imports stay; the others go.
            for module in &imported {
                assert!(
                    dir.join(format!("{module}.mojo")).is_file(),
                    "{lang}: {module}"
                );
            }
            for helper in ["json", "py_num", "c_structs"] {
                if !imported.iter().any(|m| m == helper) {
                    assert!(
                        !dir.join(format!("{helper}.mojo")).exists(),
                        "{lang}: {helper}"
                    );
                }
            }
            continue;
        }
        // Java bridges to `mojo-jvm`, which no front door wires yet, so the lift refuses to strip
        // it and leaves it as it was.
        let err = format!("{:#}", lift::strip_unit(&dir).unwrap_err());
        assert!(err.contains("mojo-jvm"), "{lang}: {err}");
        assert!(dir.join("port.mojo").is_file());
        assert!(dir.join("dispatcher.mojo").is_file());
    }
    std::fs::remove_dir_all(&base).unwrap();
}
