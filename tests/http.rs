//! HTTP servers end to end, on the same small server written in each of the eight languages:
//! record and replay (a changed error message is caught), then the Mojo front door proxying
//! every route, wiring every route to a Mojo unit, the lift, and a replay of the pure binary with
//! the original gone. A language is skipped when its runtime (or Mojo) is missing.

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

fn fixture(lang: &str, phase: &str) -> PathBuf {
    let repo = std::env::temp_dir().join(format!(
        "mojo-anything-http-{lang}-{phase}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&repo);
    copy_dir(
        &Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/http")
            .join(lang),
        &repo,
    );
    repo
}

fn sh(dir: &Path, program: &str, args: &[&str]) {
    let out = Command::new(program)
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{program} {args:?}: {}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_string).collect()
}

fn record(repo: &Path, run: &str, traps: bool) -> app::RecordOutcome {
    app::record(&RecordOptions {
        repo,
        run: &words(run),
        inputs: None,
        normalize: &[],
        name: None,
        traps,
        timeout_secs: None,
        http: true,
        server_args: &[],
        fresh: &[],
        pace_ms: None,
        port: None,
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap()
}

fn replay(repo: &Path, build: Option<&str>) -> app::ReplayOutcome {
    app::replay(&ReplayOptions {
        case: None,
        repo,
        build,
        timeout_secs: None,
        port: None,
    })
    .unwrap()
}

#[test]
fn http_record_keeps_distinct_requests_with_the_same_name() {
    if !common::have("node") {
        return;
    }
    let repo = fixture("ts", "duplicate-inputs");
    let inputs = repo.join("inputs.jsonl");
    std::fs::write(
        &inputs,
        concat!(
            "{\"name\":\"request\",\"path\":\"/hello\"}\n",
            "{\"name\":\"request-003\",\"path\":\"/div/1/1\"}\n",
            "{\"name\":\"request\",\"path\":\"/div/2/1\"}\n",
        ),
    )
    .unwrap();
    std::fs::remove_file(repo.join("README.md")).unwrap();
    let out = app::record(&RecordOptions {
        repo: &repo,
        run: &words("node server.js"),
        inputs: Some(&inputs),
        normalize: &[],
        name: None,
        traps: false,
        timeout_secs: None,
        http: true,
        server_args: &[],
        fresh: &[],
        pace_ms: None,
        port: None,
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap();
    let repeated = replay(&repo, None);
    let mut recorded = std::fs::read_dir(&out.dir)
        .unwrap()
        .map(|r| r.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".toml"))
        .collect::<Vec<_>>();
    recorded.sort();
    std::fs::remove_dir_all(repo).unwrap();
    assert_eq!(out.cases, 3);
    assert_eq!(repeated.passed, 3, "{:?}", repeated.failures);
    assert_eq!(
        recorded,
        ["request-003.toml", "request-3.toml", "request.toml"]
    );
}

#[test]
fn http_fresh_files_and_arguments_reach_every_start() {
    if !common::have("node") {
        return;
    }
    let repo = fixture("ts", "fresh-state");
    std::fs::create_dir_all(repo.join("data")).unwrap();
    std::fs::write(repo.join("data/count.txt"), "0").unwrap();
    std::fs::write(
        repo.join("counter.js"),
        concat!(
            "const http = require('http');\nconst fs = require('fs');\n",
            "const file = process.argv[2];\n",
            "http.createServer((req, res) => {\n",
            "  let n = Number(fs.readFileSync(file, 'utf8'));\n",
            "  if (req.method === 'POST') { n += 1; fs.writeFileSync(file, String(n)); }\n",
            "  setTimeout(() => res.end(String(n)), 1);\n",
            "}).listen(Number(process.env.PORT), '127.0.0.1');\n",
        ),
    )
    .unwrap();
    std::fs::remove_file(repo.join("README.md")).unwrap();
    let inputs = repo.join("inputs.jsonl");
    std::fs::write(
        &inputs,
        "{\"name\":\"a1\",\"method\":\"POST\",\"path\":\"/\"}\n{\"name\":\"a2\",\"path\":\"/\"}\n",
    )
    .unwrap();
    let out = app::record(&RecordOptions {
        repo: &repo,
        run: &words("node counter.js"),
        inputs: Some(&inputs),
        normalize: &[],
        name: None,
        traps: false,
        timeout_secs: None,
        http: false,
        port: None,
        server_args: &["data/count.txt".to_string()],
        fresh: &["data".to_string()],
        pace_ms: Some(5),
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap();
    let body = std::fs::read_to_string(out.dir.join("a2.body")).unwrap();
    let config = app::Config::load(&repo).unwrap().unwrap();
    let replayed = replay(&repo, None);
    // The Mojo front door gets the same arguments and fresh files on every start, and its
    // original runs where the front door runs, not in the repository.
    let door = common::have_mojo().then(|| {
        front_door::front_door(&FrontDoorOptions {
            repo: &repo,
            library: false,
            check: true,
        })
        .unwrap()
        .replay
        .unwrap()
    });
    let untouched = std::fs::read_to_string(repo.join("data/count.txt")).unwrap();
    std::fs::remove_dir_all(&repo).unwrap();
    if let Some(door) = door {
        assert_eq!(door.passed, 2, "{:?}", door.failures);
        assert_eq!(door.fallback.unwrap().cases, 2);
    }
    assert!(out.noisy.is_empty(), "{:?}", out.noise);
    assert_eq!(body, "1");
    assert_eq!(untouched, "0");
    let http = config.http.unwrap();
    assert_eq!(
        (http.args, http.fresh, http.pace_ms),
        (
            vec!["data/count.txt".to_string()],
            vec!["data".to_string()],
            Some(5)
        )
    );
    assert_eq!(replayed.passed, 2, "{:?}", replayed.failures);
}

/// How to build and run one language's server, and a copy with a changed error message.
struct Lang {
    name: &'static str,
    runtime: (&'static str, &'static str),
    source: &'static str,
    compiled: bool,
    build: fn(&Path, &str, &str),
    run: fn(&str) -> String,
    original: &'static str,
}

fn no_build(_: &Path, _: &str, _: &str) {}

#[test]
fn http_rerecord_uses_the_existing_fixed_port() {
    if !common::have("node") {
        return;
    }
    let repo = fixture("ts", "saved-port");
    let port = mojo_anything::http::free_port().unwrap();
    let server = repo.join("server.js");
    let text = std::fs::read_to_string(&server).unwrap();
    let condition = format!("if (Number(process.env.PORT) !== {port}) process.exit(2);");
    std::fs::write(&server, format!("{condition}\n{text}")).unwrap();
    let run = &words("node server.js");
    let record = |port| {
        app::record(&RecordOptions {
            repo: &repo,
            run,
            inputs: None,
            normalize: &[],
            name: None,
            traps: false,
            timeout_secs: None,
            http: true,
            server_args: &[],
            fresh: &[],
            pace_ms: None,
            port,
            float_tolerance: None,
            float_files: &[],
            effects: None,
        })
    };
    let first = record(Some(port));
    let second = record(None);
    // The Mojo front door starts the original on a port of its own, so it refuses a server
    // recorded on a fixed one, and says what to change.
    let door = front_door::front_door(&FrontDoorOptions {
        repo: &repo,
        library: false,
        check: false,
    });
    std::fs::remove_dir_all(repo).unwrap();
    assert!(first.unwrap().cases > 0);
    assert!(second.unwrap().cases > 0);
    let err = format!("{:#}", door.unwrap_err());
    assert!(err.contains("a port of its own"), "{err}");
}

/// The command that runs the server; `buggy` builds a copy whose division-by-zero message changed.
fn prepare(lang: &Lang, repo: &Path, buggy: bool) -> String {
    let mut source = lang.source.to_string();
    if buggy {
        let text = std::fs::read_to_string(repo.join(lang.source)).unwrap();
        assert!(text.contains("division by zero"));
        let text = text.replace("division by zero", "divide by zero");
        source = match lang.name {
            "go" => {
                let dir = repo.join("bug");
                std::fs::create_dir_all(&dir).unwrap();
                std::fs::copy(repo.join("go.mod"), dir.join("go.mod")).unwrap();
                std::fs::write(dir.join("main.go"), text).unwrap();
                "bug".to_string()
            }
            "java" => {
                std::fs::create_dir_all(repo.join("bug")).unwrap();
                std::fs::write(repo.join("bug/Server.java"), text).unwrap();
                "bug/Server.java".to_string()
            }
            "csharp" => {
                let dir = repo.join("bug");
                std::fs::create_dir_all(&dir).unwrap();
                std::fs::copy(repo.join("server.csproj"), dir.join("server.csproj")).unwrap();
                std::fs::write(dir.join("Program.cs"), text).unwrap();
                "bug".to_string()
            }
            _ => {
                let (stem, ext) = lang.source.rsplit_once('.').unwrap();
                let bug = format!("{stem}_bug.{ext}");
                std::fs::write(repo.join(&bug), text).unwrap();
                bug
            }
        };
    }
    if lang.compiled {
        let artifact = if buggy { "server-bug" } else { "server" };
        (lang.build)(repo, &source, artifact);
        (lang.run)(artifact)
    } else {
        (lang.run)(&source)
    }
}

const API_PORT_MOJO: &str = "# The Mojo port of the server's text and arithmetic.


def upper(text: String) -> String:
    return text.upper()


def div(a: Int, b: Int) -> Tuple[Int, Int]:
    return (a // b, a % b)
";

/// Glue for every route of the server fixture, in Mojo.
const API_GLUE_MOJO: &str = "from std.time import perf_counter_ns

import http
from api import port


def get_hello(
    req: http.Request, params: Dict[String, String]
) raises -> http.Response:
    return http.Response(200, \"application/json\", '{\"message\":\"hello\"}')


def post_upper(
    req: http.Request, params: Dict[String, String]
) raises -> http.Response:
    return http.text(200, port.upper(req.text()))


def get_div_a_b(
    req: http.Request, params: Dict[String, String]
) raises -> http.Response:
    var a: Int
    var b: Int
    try:
        a = Int(params.get(\"a\", String()))
        b = Int(params.get(\"b\", String()))
    except:
        return http.text(400, \"error: not a number\\n\")
    if b == 0:
        return http.text(400, \"error: division by zero\\n\")
    var qr = port.div(a, b)
    return http.text(
        200, String(a, \" / \", b, \" = \", qr[0], \" remainder \", qr[1], \"\\n\")
    )


def get_now(
    req: http.Request, params: Dict[String, String]
) raises -> http.Response:
    return http.text(200, String(\"now: \", perf_counter_ns(), \"\\n\"))


def fallback(
    req: http.Request, params: Dict[String, String]
) raises -> http.Response:
    return http.text(404, \"not found\\n\")
";

/// Glue that answers `GET /hello` only.
const HELLO_GLUE_MOJO: &str = "import http


def get_hello(
    req: http.Request, params: Dict[String, String]
) raises -> http.Response:
    return http.Response(200, \"application/json\", '{\"message\":\"hello\"}')
";

fn write_api_unit(repo: &Path) {
    let unit = repo.join("mojo/api-mojo");
    std::fs::create_dir_all(&unit).unwrap();
    std::fs::write(unit.join("port.mojo"), API_PORT_MOJO).unwrap();
    std::fs::write(
        unit.join("pixi.toml"),
        front_door_mojo::pixi_toml_app("api-mojo", false),
    )
    .unwrap();
}

fn wire(repo: &Path, routes: &[&str], check: bool) -> front_door::WireOutcome {
    front_door::wire(&WireOptions {
        repo,
        unit: "api-mojo",
        commands: &[],
        routes: &routes.iter().map(|r| r.to_string()).collect::<Vec<_>>(),
        skip_gate: true,
        check,
    })
    .unwrap()
}

fn front_door_proxies_everything(repo: &Path) -> front_door::FrontDoorOutcome {
    let door = front_door::front_door(&FrontDoorOptions {
        repo,
        library: false,
        check: true,
    })
    .unwrap();
    let app = repo.join(front_door::APP_DIR);
    for file in [
        "main.mojo",
        "original.mojo",
        "units.mojo",
        "http.mojo",
        "pixi.toml",
    ] {
        assert!(app.join(file).is_file(), "{file}");
    }
    assert!(!app.join("Cargo.toml").exists());
    let replayed = door.replay.as_ref().unwrap();
    assert_eq!(replayed.passed, replayed.total, "{:?}", replayed.failures);
    assert_eq!(
        replayed.fallback.as_ref().unwrap().cases,
        replayed.total,
        "every route is proxied"
    );
    door
}

fn check_language(lang: &Lang) {
    let (program, arg) = lang.runtime;
    if !common::have_with(program, &[arg], "was not found") {
        return;
    }

    let repo = fixture(lang.name, "replay");
    let run = prepare(lang, &repo, false);
    let buggy = prepare(lang, &repo, true);
    let recorded = record(&repo, &run, true);
    assert_eq!(recorded.examples, 6, "{recorded:?}");
    assert!(recorded.traps > 20, "{recorded:?}");
    assert_eq!(recorded.noisy, ["example-005-get-now"], "{recorded:?}");
    assert!(
        recorded.unstable.is_empty() && recorded.timed_out.is_empty(),
        "{recorded:?}"
    );
    let dir = app::cases_dir(&repo).join("http");
    assert_eq!(
        std::fs::read_to_string(dir.join("example-005-get-now.body")).unwrap(),
        "now: [..]\n"
    );
    let upper = std::fs::read_to_string(dir.join("example-002-post-upper.toml")).unwrap();
    assert!(upper.contains("body = \"hello world\""), "{upper}");
    assert!(upper.contains("status = 200"), "{upper}");
    assert!(
        upper.contains("content-type = \"text/plain; charset=utf-8\""),
        "{upper}"
    );
    assert!(
        std::fs::read_to_string(dir.join("example-006-get-missing.toml"))
            .unwrap()
            .contains("status = 404")
    );
    let original = replay(&repo, None);
    assert_eq!(original.passed, original.total, "{:?}", original.failures);
    let bug = replay(&repo, Some(&buggy));
    assert!(!bug.failures.is_empty());
    for f in &bug.failures {
        assert!(f.args[1].starts_with("/div/"), "{f:?}");
        assert!(f.problems.iter().all(|p| p.field == "body"), "{f:?}");
    }
    std::fs::remove_dir_all(&repo).unwrap();

    if !common::have_mojo() {
        return;
    }
    let repo = fixture(lang.name, "lift");
    let run = prepare(lang, &repo, false);
    record(&repo, &run, false);
    let door = front_door_proxies_everything(&repo);
    assert!(
        door.routes.contains(&"GET /div/7/2".to_string()),
        "{door:?}"
    );

    write_api_unit(&repo);
    let routes = ["GET /hello", "POST /upper", "GET /div/{a}/{b}", "GET /now"];
    let stub = wire(&repo, &routes, false);
    assert!(stub.glue_pending);
    assert_eq!(
        stub.glue,
        repo.join(front_door::APP_DIR).join("glue/api.mojo")
    );
    std::fs::write(&stub.glue, API_GLUE_MOJO).unwrap();
    let partial = wire(&repo, &[], true).replay.unwrap();
    assert_eq!(partial.passed, partial.total, "{:?}", partial.failures);
    let fallback = partial.fallback.unwrap();
    assert_eq!(fallback.names, ["example-006-get-missing"], "{fallback:?}");
    let blocked = lift::lift(&LiftOptions { repo: &repo }).unwrap();
    assert!(
        blocked
            .blockers
            .iter()
            .any(|b| b.contains("still fall back") && b.contains("example-006-get-missing")),
        "{:?}",
        blocked.blockers
    );

    let mut all = routes.to_vec();
    all.push("*");
    let full = wire(&repo, &all, true).replay.unwrap();
    assert_eq!(full.passed, full.total, "{:?}", full.failures);
    assert_eq!(full.fallback.unwrap().cases, 0);

    let lifted = lift::lift(&LiftOptions { repo: &repo }).unwrap();
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
    assert!(
        lifted
            .checklist
            .iter()
            .any(|i| i.name == "replay in CI" && i.mark == lift::Mark::Warn)
    );
    assert_lifted_without_proxy(&repo);

    let hidden = repo.join(format!("{}.hidden", lang.original));
    std::fs::rename(repo.join(lang.original), &hidden).unwrap();
    let pure = replay(
        &repo,
        Some(&lifted.binary.as_ref().unwrap().to_string_lossy()),
    );
    assert_eq!(pure.passed, pure.total, "{:?}", pure.failures);
    assert!(pure.fallback.is_none());
    std::fs::rename(&hidden, repo.join(lang.original)).unwrap();
    std::fs::remove_dir_all(&repo).unwrap();
}

/// The lifted server has no original to start and no proxy to it.
fn assert_lifted_without_proxy(repo: &Path) {
    let app_dir = repo.join(front_door::APP_DIR);
    assert!(!app_dir.join("original.mojo").exists());
    assert!(!app_dir.join("Cargo.toml").exists());
    for file in ["main.mojo", "units.mojo", "glue/api.mojo"] {
        let text = std::fs::read_to_string(app_dir.join(file)).unwrap();
        assert!(!text.contains("original"), "{file}: {text}");
        assert!(!text.contains("forward("), "{file}: {text}");
    }
}

#[test]
fn http_wire_route_in_mojo() {
    if !common::have("python3") || !common::have_mojo() {
        return;
    }
    let repo = fixture("python", "wire-one");
    record(&repo, "python3 server.py", false);
    let door = front_door_proxies_everything(&repo);
    let total = door.replay.unwrap().total;
    write_api_unit(&repo);
    let stub = wire(&repo, &["GET /hello"], true);
    // The stub hands the route back to the original: nothing changes yet.
    assert!(stub.glue_pending);
    let before = stub.replay.unwrap();
    assert_eq!(before.passed, total, "{:?}", before.failures);
    assert_eq!(before.fallback.unwrap().cases, total);
    std::fs::write(&stub.glue, HELLO_GLUE_MOJO).unwrap();
    let after = wire(&repo, &[], true).replay.unwrap();
    // The kill switch sends the wired route back to the original, end to end.
    let log = repo.join("switch.log");
    let log_text = log.to_string_lossy().into_owned();
    let mut switched = Vec::new();
    for value in ["original", ""] {
        let _ = std::fs::remove_file(&log);
        let port = mojo_anything::http::free_port().unwrap();
        let port_text = port.to_string();
        let mut child = start_listening(
            &after.build[0],
            &[],
            &[
                ("PORT", &port_text),
                ("MOJO_ANYTHING_UNIT_API", value),
                (app::FALLBACK_ENV, &log_text),
            ],
            port,
        );
        let answer = get(port, "/hello");
        let _ = child.kill();
        let _ = child.wait();
        switched.push((answer, std::fs::read_to_string(&log).unwrap_or_default()));
    }
    std::fs::remove_dir_all(&repo).unwrap();
    for (answer, _) in &switched {
        let (status, body) = answer.as_ref().unwrap();
        assert!(status.contains(" 200 "), "{status}");
        assert!(body.contains("hello"), "{body}");
    }
    assert_eq!(
        switched[0].1, "GET /hello\n",
        "the switch proxied the route"
    );
    assert_eq!(switched[1].1, "", "without the switch the glue answered");
    assert_eq!(after.passed, total, "{:?}", after.failures);
    let fallback = after.fallback.unwrap();
    assert_eq!(fallback.cases, total - 1, "{fallback:?}");
    assert!(
        !fallback.names.iter().any(|n| n.contains("hello")),
        "{fallback:?}"
    );
}

#[test]
fn http_lift_has_no_proxy() {
    if !common::have("python3") || !common::have_mojo() {
        return;
    }
    let repo = fixture("python", "lift-no-proxy");
    record(&repo, "python3 server.py", false);
    front_door_proxies_everything(&repo);
    write_api_unit(&repo);
    let stub = wire(
        &repo,
        &[
            "GET /hello",
            "POST /upper",
            "GET /div/{a}/{b}",
            "GET /now",
            "*",
        ],
        false,
    );
    std::fs::write(&stub.glue, API_GLUE_MOJO).unwrap();
    let lifted = lift::lift(&LiftOptions { repo: &repo }).unwrap();
    assert!(
        lifted.lifted,
        "{:?}\n{:?}",
        lifted.blockers, lifted.checklist
    );
    assert_lifted_without_proxy(&repo);
    let state =
        std::fs::read_to_string(repo.join(front_door::APP_DIR).join(front_door::STATE_FILE))
            .unwrap();
    std::fs::rename(repo.join("server.py"), repo.join("server.py.hidden")).unwrap();
    let pure = replay(
        &repo,
        Some(&lifted.binary.as_ref().unwrap().to_string_lossy()),
    );
    std::fs::remove_dir_all(&repo).unwrap();
    assert!(state.contains("\"lifted\": true"), "{state}");
    assert_eq!(pure.passed, pure.total, "{:?}", pure.failures);
    assert!(
        pure.fallback.is_none(),
        "the lifted server logs no fallback"
    );
}

#[test]
fn ts_server() {
    check_language(&Lang {
        name: "ts",
        compiled: false,
        runtime: ("node", "--version"),
        source: "server.js",
        build: no_build,
        run: |s| format!("node {s}"),
        original: "server.js",
    });
}

#[test]
fn python_server() {
    check_language(&Lang {
        name: "python",
        compiled: false,
        runtime: ("python3", "--version"),
        source: "server.py",
        build: no_build,
        run: |s| format!("python3 {s}"),
        original: "server.py",
    });
}

#[test]
fn php_server() {
    check_language(&Lang {
        name: "php",
        compiled: false,
        runtime: ("php", "--version"),
        source: "server.php",
        build: no_build,
        run: |s| format!("php -S 127.0.0.1:{{port}} {s}"),
        original: "server.php",
    });
}

#[test]
fn ruby_server() {
    check_language(&Lang {
        name: "ruby",
        compiled: false,
        runtime: ("ruby", "--version"),
        source: "server.rb",
        build: no_build,
        run: |s| format!("ruby {s}"),
        original: "server.rb",
    });
}

#[test]
fn c_server() {
    check_language(&Lang {
        name: "c",
        compiled: true,
        runtime: ("cc", "--version"),
        source: "server.c",
        build: |repo, source, out| sh(repo, "cc", &["-O1", "-o", out, source]),
        run: |s| format!("./{s}"),
        original: "server",
    });
}

#[test]
fn go_server() {
    check_language(&Lang {
        name: "go",
        compiled: true,
        runtime: ("go", "version"),
        source: "main.go",
        build: |repo, source, out| {
            let dir = if source == "bug" {
                repo.join("bug")
            } else {
                repo.to_path_buf()
            };
            let out = repo.join(out);
            sh(&dir, "go", &["build", "-o", &out.to_string_lossy(), "."]);
        },
        run: |s| format!("./{s}"),
        original: "server",
    });
}

#[test]
fn java_server() {
    check_language(&Lang {
        name: "java",
        compiled: true,
        runtime: ("javac", "--version"),
        source: "Server.java",
        build: |repo, source, out| sh(repo, "javac", &["-d", out, source]),
        run: |s| format!("java -cp ./{s} Server"),
        original: "server",
    });
}

#[test]
fn csharp_server() {
    check_language(&Lang {
        name: "csharp",
        compiled: true,
        runtime: ("dotnet", "--version"),
        source: "Program.cs",
        build: |repo, source, out| {
            let dir = if source == "bug" {
                repo.join("bug")
            } else {
                repo.to_path_buf()
            };
            let out = repo.join(out);
            sh(
                &dir,
                "dotnet",
                &[
                    "build",
                    "-c",
                    "Release",
                    "--nologo",
                    "-v",
                    "q",
                    "-o",
                    &out.to_string_lossy(),
                ],
            );
        },
        run: |s| format!("dotnet {s}/server.dll --urls http://127.0.0.1:{{port}}"),
        original: "server",
    });
}

/// A server that takes its port only from `--port N` (the last one given, as argparse does).
const PORT_ARG_SERVER: &str = r#"import argparse
import http.server

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, required=True)
args = parser.parse_args()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"hello\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
"#;

/// Starts `program args` with `envs` and waits until something listens on `port`.
fn start_listening(
    program: &str,
    args: &[&str],
    envs: &[(&str, &str)],
    port: u16,
) -> std::process::Child {
    let mut child = Command::new(program)
        .args(args)
        .env_remove("PORT")
        .envs(envs.iter().copied())
        .stdin(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    while std::net::TcpStream::connect(("127.0.0.1", port)).is_err() {
        if let Some(status) = child.try_wait().unwrap() {
            panic!("`{program}` exited ({status}) before listening on {port}");
        }
        assert!(
            std::time::Instant::now() < deadline,
            "nothing listened on {port}"
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    child
}

/// `GET path` on a connection of its own: the status line and the body.
fn get(port: u16, path: &str) -> std::io::Result<(String, String)> {
    use std::io::{Read, Write};
    let mut stream = std::net::TcpStream::connect(("127.0.0.1", port))?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(20)))?;
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    )?;
    let mut text = String::new();
    stream.read_to_string(&mut text)?;
    let (head, body) = text.split_once("\r\n\r\n").unwrap_or((&text, ""));
    Ok((
        head.lines().next().unwrap_or_default().to_string(),
        body.to_string(),
    ))
}

/// The lines `ss` prints for the sockets listening on TCP `port`, with their processes.
fn listeners(port: u16) -> String {
    let out = Command::new("ss")
        .args(["-Hltnp", &format!("sport = :{port}")])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).into_owned()
}

#[cfg(target_os = "linux")]
#[test]
fn http_port_argument_reaches_the_front_door_not_the_original() {
    if !common::have("python3") || !common::have_mojo() || !common::have("ss") {
        return;
    }
    let repo = fixture("python", "port-arg");
    std::fs::remove_file(repo.join("README.md")).unwrap();
    std::fs::write(repo.join("port_server.py"), PORT_ARG_SERVER).unwrap();
    let inputs = repo.join("inputs.jsonl");
    std::fs::write(
        &inputs,
        "{\"name\":\"hello\",\"path\":\"/hello\"}\n{\"name\":\"again\",\"path\":\"/again\"}\n",
    )
    .unwrap();
    app::record(&RecordOptions {
        repo: &repo,
        run: &words("python3 port_server.py"),
        inputs: Some(&inputs),
        normalize: &[],
        name: None,
        traps: false,
        timeout_secs: None,
        http: true,
        server_args: &["--port".to_string(), "{port}".to_string()],
        fresh: &[],
        pace_ms: None,
        port: None,
        float_tolerance: None,
        float_files: &[],
        effects: None,
    })
    .unwrap();
    let door = front_door::front_door(&FrontDoorOptions {
        repo: &repo,
        library: false,
        check: true,
    })
    .unwrap();
    let replayed = door.replay.unwrap();
    let binary = replayed.build[0].clone();

    // Started by hand with the recorded arguments, the front door owns the public port, on
    // loopback only, and answers a client while another connection sends nothing.
    let port = mojo_anything::http::free_port().unwrap();
    let mut child = start_listening(&binary, &["--port", &port.to_string()], &[], port);
    let listening = listeners(port);
    let idle = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    let started = std::time::Instant::now();
    let answer = get(port, "/hello");
    let waited = started.elapsed();
    drop(idle);
    let _ = child.kill();
    let _ = child.wait();
    std::fs::remove_dir_all(&repo).unwrap();

    eprintln!("replay: {replayed:?}\nss: {listening}\nanswer: {answer:?} after {waited:?}");
    assert_eq!(replayed.passed, 2, "{:?}", replayed.failures);
    assert_eq!(
        replayed.fallback.as_ref().map(|f| f.cases),
        Some(2),
        "every request went through the front door to the original"
    );
    assert!(
        listening.contains(&format!("pid={},", child.id())),
        "the front door listens on the public port: {listening}"
    );
    assert_eq!(listening.lines().count(), 1, "{listening}");
    assert!(
        listening.contains(&format!("127.0.0.1:{port} ")),
        "loopback only: {listening}"
    );
    let (status, body) = answer.unwrap();
    assert!(status.contains(" 200 "), "{status}");
    assert_eq!(body, "hello\n");
    assert!(
        waited < std::time::Duration::from_secs(8),
        "a silent connection held the next client up for {waited:?}"
    );
}

#[test]
fn http_replay_fails_when_the_front_door_answers_nothing() {
    if !common::have("python3") {
        return;
    }
    // A build that says it counts fallbacks but leaves every request to another process: the
    // replay must not report it as a front door that fell back on nothing.
    let repo = fixture("python", "door-absent");
    record(&repo, "python3 server.py", false);
    std::fs::write(
        repo.join("absent.sh"),
        ": >> \"$MOJO_ANYTHING_FALLBACK_LOG\"\nunset MOJO_ANYTHING_FALLBACK_LOG\nexec python3 server.py \"$@\"\n",
    )
    .unwrap();
    let absent = replay(&repo, Some("sh absent.sh"));
    std::fs::remove_dir_all(&repo).unwrap();
    assert!(absent.total > 0);
    assert_eq!(absent.passed, 0, "{absent:?}");
    assert!(
        absent.failures.iter().all(|f| f
            .problems
            .iter()
            .any(|p| p.detail.contains("the front door did not answer"))),
        "{:?}",
        absent.failures
    );
}
