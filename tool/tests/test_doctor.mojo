# `doctor` in Mojo: the tests of src/doctor.rs, ported by name.

from std.python import Python
from std.testing import assert_equal, assert_false, assert_true

from mojo_anything.doctor import (
    Check,
    Entry,
    FOREIGN,
    INSTALL_CURRENT,
    INSTALL_FOREIGN,
    INSTALL_MISSING,
    INSTALL_OUTDATED,
    MACOS,
    MISSING,
    OK,
    OTHER,
    OUTDATED,
    Report,
    Runtime,
    Version,
    WINDOWS,
    WSL,
    assess,
    entry_state,
    grade,
    install_status,
    mcp_self_test,
    mojo_toolchain,
    parse_java_version,
    parse_version,
    pinned_mojo_args,
    read_entry,
    runtime_fix,
    runtimes,
    skill_state,
    text,
)
from mojo_anything.skill_files import skill_file_names, skill_file_text


def _same(v: Optional[Version], want: Version) -> Bool:
    return Bool(v) and v.value() == want


def test_versions_are_read_from_every_banner() raises:
    assert_true(_same(parse_version("v24.1.0"), Version(24, 1, 0)))
    assert_true(_same(parse_version("Python 3.12.1"), Version(3, 12, 1)))
    assert_true(
        _same(
            parse_version("go version go1.22.3 darwin/arm64"), Version(1, 22, 3)
        )
    )
    assert_true(
        _same(
            parse_version(
                "ruby 2.6.10p210 (2022-04-12 revision 67958)"
                " [universal.arm64e-darwin26]"
            ),
            Version(2, 6, 10),
        )
    )
    assert_true(
        _same(
            parse_version('openjdk version "21.0.8" 2025-07-15'),
            Version(21, 0, 8),
        )
    )
    assert_true(_same(parse_version("javac 17"), Version(17, 0, 0)))
    assert_true(
        _same(
            parse_version("PHP 8.3.4 (cli) (built: Mar 12 2024)"),
            Version(8, 3, 4),
        )
    )
    assert_true(
        _same(
            parse_version("cargo 1.97.0 (abcdef 2026-01-01)"), Version(1, 97, 0)
        )
    )
    assert_true(_same(parse_version("8.0.100"), Version(8, 0, 100)))
    assert_false(Bool(parse_version("no digits")))
    assert_true(
        _same(parse_java_version('java version "1.8.0_281"'), Version(8, 0, 0))
    )
    assert_true(
        _same(parse_java_version('openjdk version "17.0.2"'), Version(17, 0, 2))
    )


def _runtime(name: String) raises -> Runtime:
    for r in runtimes():
        if r.name == name:
            return r.copy()
    raise Error("no runtime " + name)


def test_java_and_javac_need_java_22() raises:
    for name in ["java", "javac"]:
        var r = _runtime(String(name))
        assert_true(_same(r.minimum, Version(22, 0, 0)), name)
        assert_equal(grade(True, Version(21, 0, 2), r.minimum), OUTDATED)


def test_doctor_on_windows_points_at_wsl() raises:
    var checks = mojo_toolchain(WINDOWS)
    assert_equal(len(checks), 2)
    assert_equal(checks[0].name, "pixi")
    assert_equal(checks[1].name, "mojo")
    for c in checks:
        assert_true(c.status != OK)
        assert_true(c.required)
        assert_true("wsl -d Ubuntu-24.04" in c.fix.value())


def test_java_21_is_too_old() raises:
    assert_equal(grade(True, Version(21, 0, 4), Version(22, 0, 0)), OUTDATED)
    var c = assess(
        _runtime("java"), String('openjdk version "21.0.4" 2024-07-16'), OTHER
    )
    assert_equal(c.status, OUTDATED)
    assert_false(c.required)
    assert_true("Java 22" in c.fix.value())


def test_node_22_warns_about_wasm() raises:
    var node = _runtime("node")
    var c = assess(node, String("v22.12.0"), OTHER)
    assert_equal(c.status, OUTDATED)
    assert_false(c.required)
    assert_true("mojo-wasm" in c.detail)
    assert_true(Bool(c.fix))
    var ok = assess(node, String("v24.1.0"), OTHER)
    assert_equal(ok.status, OK)
    assert_false(Bool(ok.fix))


def test_rows_are_the_mojo_toolchain_and_the_runtimes() raises:
    var names = List[String]()
    for r in runtimes():
        names.append(r.name)
    for name in [
        "python",
        "node",
        "go",
        "ruby",
        "java",
        "kotlinc",
        "php",
        "dotnet",
    ]:
        assert_true(String(name) in names, name)
    assert_false(String("cargo") in names)
    for r in runtimes():
        assert_false(assess(r, None, OTHER).required, r.name)
        for status in [MISSING, OUTDATED]:
            for platform in [MACOS, WINDOWS, OTHER]:
                var fix = runtime_fix(r, String(status), platform).value()
                assert_false("winget" in fix, fix)
                assert_false("rustup" in fix, fix)


def test_runtimes_are_graded_against_their_minimum() raises:
    var min = Version(3, 0, 0)
    assert_equal(grade(False, None, min), MISSING)
    assert_equal(grade(True, Version(2, 6, 10), min), OUTDATED)
    assert_equal(grade(True, Version(3, 0, 0), min), OK)
    assert_equal(grade(True, Version(3, 4, 1), min), OK)
    assert_equal(grade(True, None, min), OK)
    assert_equal(grade(True, Version(1, 0, 0), None), OK)
    assert_true(Version(22, 5, 9) < Version(22, 6, 0))


def test_install_states_map_to_statuses() raises:
    assert_equal(install_status(INSTALL_MISSING), MISSING)
    assert_equal(install_status(INSTALL_CURRENT), OK)
    assert_equal(install_status(INSTALL_OUTDATED), OUTDATED)
    assert_equal(install_status(INSTALL_FOREIGN), FOREIGN)
    assert_equal(String(OUTDATED), "outdated")


def _entry(command: String, arg: String, url: Bool) -> Entry:
    var args = List[String]()
    args.append(arg)
    return Entry(command, args^, url, False)


def test_mcp_entries_are_ours_only_when_they_run_this_binary() raises:
    var exe = "/opt/bin/mojo-anything"
    assert_equal(entry_state(None, exe), INSTALL_MISSING)
    assert_equal(
        entry_state(_entry("/opt/bin/mojo-anything", "mcp", False), exe),
        INSTALL_CURRENT,
    )
    assert_equal(
        entry_state(_entry("/old/mojo-anything", "mcp", False), exe),
        INSTALL_OUTDATED,
    )
    assert_equal(
        entry_state(_entry("/opt/bin/mojo-anything", "serve", False), exe),
        INSTALL_FOREIGN,
    )
    assert_equal(
        entry_state(_entry("/opt/bin/mojo-anything", "mcp", True), exe),
        INSTALL_FOREIGN,
    )
    assert_equal(
        entry_state(Entry(None, List[String](), False, False), exe),
        INSTALL_FOREIGN,
    )
    var disabled = _entry("/opt/bin/mojo-anything", "mcp", False)
    disabled.disabled = True
    assert_equal(entry_state(disabled^, exe), INSTALL_OUTDATED)
    # The Phase 1 binary this one hands over to is current too.
    var phase1 = "/opt/fallback/mojo-anything"
    assert_equal(
        entry_state(_entry(phase1, "mcp", False), exe, phase1),
        INSTALL_CURRENT,
    )
    assert_equal(
        entry_state(_entry("/old/mojo-anything", "mcp", False), exe, phase1),
        INSTALL_OUTDATED,
    )


def _put(path: String, body: String) raises:
    with open(path, "w") as f:
        f.write(body)


def test_opencode_entries_come_from_mcp_servers() raises:
    var os = Python.import_module("os")
    var tempfile = Python.import_module("tempfile")
    var shutil = Python.import_module("shutil")
    var home = (
        String(py=tempfile.gettempdir())
        + "/mojo-anything-doctor-opencode-"
        + String(py=os.getpid())
    )
    _ = shutil.rmtree(home, ignore_errors=True)
    _ = os.makedirs(home + "/.config/opencode")
    var config = home + "/.config/opencode/opencode.json"
    var exe = "/opt/bin/mojo-anything"

    _put(
        config,
        '{"mcp":{"servers":{"mojo-anything":{"type":"local","command":["/opt/bin/mojo-anything","mcp"]}}}}',
    )
    var entry = read_entry("opencode", config)
    assert_equal(entry_state(entry, exe), INSTALL_CURRENT)
    assert_equal(
        entry_state(entry, "/elsewhere/mojo-anything"), INSTALL_OUTDATED
    )
    _put(
        config,
        '{"mcp":{"servers":{"mojo-anything":{"type":"local","command":["/opt/bin/mojo-anything","mcp"],"disabled":true}}}}',
    )
    assert_equal(
        entry_state(read_entry("opencode", config), exe), INSTALL_OUTDATED
    )
    _put(
        config,
        '{"mcp":{"mojo-anything":{"type":"local","command":["/opt/bin/mojo-anything","mcp"]}}}',
    )
    assert_equal(
        entry_state(read_entry("opencode", config), exe), INSTALL_CURRENT
    )
    _ = shutil.rmtree(home)


def test_skills_are_current_outdated_or_foreign() raises:
    var ours = List[Optional[String]]()
    for name in skill_file_names():
        ours.append(skill_file_text(name))
    assert_equal(skill_state(ours), INSTALL_CURRENT)
    var none = List[Optional[String]]()
    for _ in skill_file_names():
        none.append(None)
    assert_equal(skill_state(none), INSTALL_MISSING)
    var old = ours.copy()
    old[0] = String(
        "---\nname: mojo-anything\ndescription: old\n---\n\n# Old\n"
    )
    assert_equal(skill_state(old), INSTALL_OUTDATED)
    var partial = ours.copy()
    partial[1] = None
    assert_equal(skill_state(partial), INSTALL_OUTDATED)
    var foreign = ours.copy()
    foreign[0] = String("---\nname: something-else\n---\n")
    assert_equal(skill_state(foreign), INSTALL_FOREIGN)


def _check(status: String, required: Bool) -> Check:
    return Check("x", status, required, "", None)


def test_only_required_problems_fail_the_report() raises:
    var optional = Report()
    optional.checks.append(_check(OK, True))
    optional.checks.append(_check(MISSING, False))
    assert_true(optional.ok())
    var required = Report()
    required.checks.append(_check(OUTDATED, True))
    assert_false(required.ok())


def test_fixes_follow_the_platform() raises:
    var cc = _runtime("cc")
    assert_equal(
        runtime_fix(cc, MISSING, MACOS).value(), "xcode-select --install"
    )
    assert_equal(
        runtime_fix(cc, MISSING, WINDOWS).value(),
        "in WSL (" + WSL + "): sudo apt install build-essential",
    )
    assert_equal(
        runtime_fix(cc, MISSING, OTHER).value(),
        "sudo apt install build-essential",
    )
    assert_false(Bool(runtime_fix(cc, OK, WINDOWS)))


def test_the_pinned_mojo_comes_from_the_units_channels() raises:
    var line = String("")
    var args = pinned_mojo_args()
    for i in range(len(args)):
        if i > 0:
            line += " "
        line += args[i]
    assert_equal(
        line,
        (
            "exec -c https://conda.modular.com/max -c conda-forge --spec"
            " mojo==1.2.0 mojo --version"
        ),
    )


def test_fixes_of_several_lines_line_up() raises:
    var report = Report()
    report.checks.append(
        Check("mojo", MISSING, True, "not found", String("first\nsecond"))
    )
    var out = text(report)
    var lines = out.split("\n")
    assert_true(String(lines[1].strip()).startswith("fix: first"), out)
    assert_equal(lines[1].find("first"), lines[2].find("second"), out)


def test_mcp_fix_points_at_the_npm_wrapper_and_the_release() raises:
    var check = mcp_self_test("/nonexistent/mojo-anything")
    assert_equal(check.status, MISSING)
    var fix = check.fix.value()
    assert_true("npm install -g mojo-anything" in fix, fix)
    assert_true(
        "https://github.com/ModelTok/mojo-anything/releases" in fix, fix
    )
    assert_false("cargo" in fix, fix)


def main() raises:
    test_versions_are_read_from_every_banner()
    test_java_and_javac_need_java_22()
    test_doctor_on_windows_points_at_wsl()
    test_java_21_is_too_old()
    test_node_22_warns_about_wasm()
    test_rows_are_the_mojo_toolchain_and_the_runtimes()
    test_runtimes_are_graded_against_their_minimum()
    test_install_states_map_to_statuses()
    test_mcp_entries_are_ours_only_when_they_run_this_binary()
    test_opencode_entries_come_from_mcp_servers()
    test_skills_are_current_outdated_or_foreign()
    test_only_required_problems_fail_the_report()
    test_fixes_follow_the_platform()
    test_the_pinned_mojo_comes_from_the_units_channels()
    test_fixes_of_several_lines_line_up()
    test_mcp_fix_points_at_the_npm_wrapper_and_the_release()
    print("test_doctor: 16 passed")
