# The command line the Mojo tool owns: `--version`, `-h` and the `--help`
# that matches it, rendered byte for byte as the Phase 1 binary (clap 4)
# prints them in the recording.

from std.testing import assert_equal, assert_true, assert_false

from mojo_anything.cli import decide, render_help
from mojo_anything.cli_spec import spec


def _case_name(path: String) -> String:
    if path == "":
        return "top"
    return path.replace(" ", "-")


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def test_every_short_help_matches_the_recording() raises:
    var all = spec()
    assert_true(len(all) == 18)
    for i in range(len(all)):
        var want = _read(
            "mojo/app-cases/" + _case_name(all[i].path) + "-help-short.stdout"
        )
        assert_equal(render_help(all[i]), want)


def test_version_is_owned() raises:
    for flag in ["--version", "-V"]:
        var args = List[String]()
        args.append(flag)
        var r = decide(args)
        assert_true(r.owned)
        assert_equal(r.stdout, "mojo-anything 0.1.0\n")
        assert_equal(r.code, 0)


def test_help_is_owned_where_long_equals_short() raises:
    var args = List[String]()
    args.append("analyze")
    args.append("--help")
    var r = decide(args)
    assert_true(r.owned)
    assert_equal(r.stdout, _read("mojo/app-cases/analyze-help.stdout"))
    var sub = List[String]()
    sub.append("help")
    sub.append("analyze")
    var h = decide(sub)
    assert_true(h.owned)
    assert_equal(h.stdout, r.stdout)


def test_long_help_is_clap_long_layout() raises:
    var args = List[String]()
    args.append("bridge")
    args.append("--help")
    var l = decide(args)
    assert_true(l.owned)
    assert_equal(l.stdout, _read("mojo/app-cases/bridge-help.stdout"))
    var app = List[String]()
    app.append("app")
    app.append("record")
    app.append("--help")
    var a = decide(app)
    assert_true(a.owned)
    assert_equal(a.stdout, _read("mojo/app-cases/app-record-help.stdout"))
    var sub = List[String]()
    sub.append("help")
    sub.append("app")
    sub.append("record")
    var h = decide(sub)
    assert_true(h.owned)
    assert_equal(h.stdout, a.stdout)
    var short = List[String]()
    short.append("bridge")
    short.append("-h")
    var r = decide(short)
    assert_true(r.owned)
    assert_equal(r.stdout, _read("mojo/app-cases/bridge-help-short.stdout"))


def test_app_subcommand_help() raises:
    var top = List[String]()
    top.append("app")
    top.append("-h")
    var r = decide(top)
    assert_true(r.owned)
    assert_equal(r.stdout, _read("mojo/app-cases/app-help-short.stdout"))
    var args = List[String]()
    args.append("app")
    args.append("record")
    args.append("-h")
    assert_false(decide(args).owned)


def test_real_work_falls_back() raises:
    var args = List[String]()
    args.append("analyze")
    args.append(".")
    assert_false(decide(args).owned)
    assert_false(decide(List[String]()).owned)
    var odd = List[String]()
    odd.append("analyze")
    odd.append(".")
    odd.append("--help")
    assert_false(decide(odd).owned)


def main() raises:
    test_every_short_help_matches_the_recording()
    test_version_is_owned()
    test_help_is_owned_where_long_equals_short()
    test_long_help_is_clap_long_layout()
    test_app_subcommand_help()
    test_real_work_falls_back()
    print("test_cli: 6 passed")
