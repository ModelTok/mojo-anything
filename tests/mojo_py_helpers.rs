//! `PyNum` keeps Python's numbers: ints stay ints, floats floats, big ints exact, `-0.0` kept,
//! and errors carry Python's exception type. Skips where Mojo cannot run.

use std::path::Path;
use std::process::Command;

use mojo_anything::{codegen_mojo_py::PY_NUM_MOJO, mojo};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

const CHECKS: &str = r#"
import _native as n, math
checks = [
    (n.add(1, 2), 3), (n.add(1.5, 2), 3.5), (n.mul(-0.0, 1), -0.0),
    (n.add(9007199254740992, 1), 9007199254740993), (n.mul(2**40, 2**40), 2**80),
    (n.div(1, 2), 0.5), (n.mod(-7, 3), 2), (n.mod(-7.5, 2.0), 0.5), (n.mod(7.5, -2.0), -0.5),
    (n.mod(-0.0, 1.0), 0.0), (n.neg(0.0), -0.0), (n.to_int(-2.7), -2),
    (n.biggest(1, 3.0, 3), 3.0), (n.add(True, 1), 2), (n.add(2**70, 1.0), float(2**70) + 1.0),
]
for got, want in checks:
    same = got == want and type(got) is type(want)
    if isinstance(want, float):
        same = same and math.copysign(1, got) == math.copysign(1, want)
    assert same, (got, want)
for f, args, kind in [
    (n.div, (1.0, 0.0), "ZeroDivisionError"), (n.div, (1, 0), "ZeroDivisionError"),
    (n.mod, (1, 0), "ZeroDivisionError"), (n.to_int, (math.nan,), "ValueError"),
    (n.to_int, (math.inf,), "OverflowError"),
]:
    try:
        f(*args)
    except Exception as e:
        assert str(e).startswith(kind + ": "), (args, str(e))
    else:
        raise AssertionError(("no error", args))
print("ok")
"#;

#[test]
fn py_num_keeps_int_and_float() {
    if !mojo::available() {
        eprintln!("skipping: {}", mojo::missing_message());
        return;
    }
    let dir = std::env::temp_dir().join(format!("mojo-py-num-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::copy(
        Path::new(ROOT).join("tests/fixtures/mojo-py-num/_native.mojo"),
        dir.join("_native.mojo"),
    )
    .unwrap();
    std::fs::write(dir.join("py_num.mojo"), PY_NUM_MOJO).unwrap();
    let out = mojo::command(Path::new(ROOT))
        .unwrap()
        .current_dir(&dir)
        .args([
            "build",
            "--Werror",
            "_native.mojo",
            "--emit",
            "shared-lib",
            "-o",
            "_native.so",
        ])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "mojo build failed:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let run = Command::new("python3")
        .arg("-c")
        .arg(CHECKS)
        .current_dir(&dir)
        .env("PYTHONDONTWRITEBYTECODE", "1")
        .output()
        .unwrap();
    assert!(
        run.status.success(),
        "{}",
        String::from_utf8_lossy(&run.stderr)
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn call_py_rebuilds_exceptions_with_several_arguments() {
    let script = format!(
        "{}\n\
         def f():\n    raise Exception('UnicodeDecodeError: bad byte')\n\
         try:\n    _call(f)\n\
         except UnicodeError as e:\n    print(type(e).__name__, e)\n",
        mojo_anything::codegen_mojo_py::CALL_PY
    );
    let out = std::process::Command::new("python3")
        .arg("-c")
        .arg(script)
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "UnicodeError bad byte\n",
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}
