from std.os import makedirs
from std.os.path import exists
from std.python import Python
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from mojo_anything.walk import canonical, ignored_files, walk


def _keep_all(path: String) -> Bool:
    return True


def _scratch(tag: String) raises -> String:
    var dir = String("/tmp/mojo-anything-test-walk-") + tag + "-"
    dir += String(Int(perf_counter_ns() % 1_000_000_000))
    makedirs(dir)
    return dir


def _write(path: String, text: String) raises:
    var slash = path.rfind("/")
    var parent = String(path[byte=0:slash])
    if not exists(parent):
        makedirs(parent)
    var f = open(path, "w")
    f.write(text)
    f.close()


def _remove_tree(path: String) raises:
    _ = Python.import_module("shutil").rmtree(path)


def _build_tree(dest: String) raises:
    var spec = open("tool/tests/data/walk_tree.txt", "r").read()
    for line in spec.split("\n"):
        var text = String(line)
        if text.byte_length() == 0 or text.startswith("# "):
            continue
        var tab = text.find("\t")
        var path = text
        var content = String("")
        if tab >= 0:
            path = String(text[byte=0:tab])
            content = String(text[byte = tab + 1 :]).replace("\\n", "\n")
        if path.endswith("/"):
            makedirs(dest + "/" + path, exist_ok=True)
            continue
        _write(dest + "/" + path, content)


def _section(expected: String, label: String) raises -> String:
    var start = expected.find("## " + label + "\n")
    assert_true(start >= 0, "no section " + label)
    var body = start + label.byte_length() + 4
    var end = expected.find("\n## ", body - 1)
    if end < 0:
        return String(expected[byte=body:])
    return String(expected[byte = body : end + 1])


def _listing(root: String, require_git: Bool) raises -> String:
    var out = String("")
    for path in walk(root, _keep_all, require_git):
        out += String(path[byte = root.byte_length() + 1 :]) + "\n"
    return out


def test_nested_gitignore_and_negation() raises:
    var expected = open("tool/tests/data/walk_expected.txt", "r").read()
    var tree = _scratch("tree")
    _build_tree(tree)
    assert_equal(_listing(tree, True), _section(expected, "root"))
    assert_equal(
        _listing(tree, False), _section(expected, "root without require_git")
    )
    assert_equal(_listing(tree + "/lib", True), _section(expected, "lib"))
    assert_equal(
        _listing(tree + "/lib", False),
        _section(expected, "lib without require_git"),
    )
    assert_equal(_listing(tree + "/doc", True), _section(expected, "doc"))
    _remove_tree(tree + "/.git")
    assert_equal(_listing(tree, True), _section(expected, "no git"))
    assert_equal(
        _listing(tree, False), _section(expected, "no git without require_git")
    )
    _remove_tree(tree)


def test_ignored_count_matches_rust() raises:
    var expected = open("tool/tests/data/walk_expected.txt", "r").read()
    var tree = _scratch("ignored")
    _build_tree(tree)
    var exts = List[String]()
    for e in ["py", "log", "tmp", "txt", "md", "mojo"]:
        exts.append(e)
    assert_equal(
        String(ignored_files(tree, exts)) + "\n",
        _section(expected, "ignored py log tmp txt md mojo"),
    )
    _remove_tree(tree + "/.git")
    assert_equal(
        String(ignored_files(tree, exts)) + "\n",
        _section(expected, "no git ignored py log tmp txt md mojo"),
    )
    _remove_tree(tree)


def test_canonical_through_symlink_and_dotdot() raises:
    var dir = _scratch("canonical")
    var real = canonical(dir)
    makedirs(dir + "/a dir/b")
    _ = Python.import_module("os").symlink(dir + "/a dir", dir + "/link")
    assert_equal(canonical(dir + "/link/b/../b"), real + "/a dir/b")
    assert_equal(canonical(dir + "/a dir/./b/"), real + "/a dir/b")
    assert_equal(
        canonical(dir + "/link/b") + "x", canonical(dir + "/a dir/b") + "x"
    )
    # A path that does not exist is cleaned by its words.
    assert_equal(canonical(dir + "/nope/../x/./y//z"), dir + "/x/y/z")
    _remove_tree(dir)


def test_ignore_files_above_the_repository_are_not_read() raises:
    var tmp = _scratch("above")
    var repo = tmp + "/home/proj"
    _write(tmp + "/home/.gitignore", "*\n")
    _write(repo + "/src/a.ts", "")
    _write(repo + "/src/gen/b.ts", "")
    assert_equal(_listing(repo, False), "src/a.ts\nsrc/gen/b.ts\n")
    makedirs(repo + "/.git")
    _write(repo + "/.gitignore", "/src/gen/\n")
    assert_equal(_listing(repo, False), "src/a.ts\n")
    assert_equal(_listing(repo + "/src", False), "a.ts\n")
    _remove_tree(tmp)


def test_bridge_crates_inside_the_project_are_not_source() raises:
    var tmp = _scratch("bridge")
    _write(tmp + "/src/A.java", "")
    _write(tmp + "/rust/x-rs/mojo-anything.json", "{}")
    _write(tmp + "/rust/x-rs/java/A.java", "")
    assert_equal(_listing(tmp, False), "src/A.java\n")
    assert_true("java/A.java\n" in _listing(tmp + "/rust/x-rs", False))
    _remove_tree(tmp)


def main() raises:
    test_nested_gitignore_and_negation()
    test_ignored_count_matches_rust()
    test_canonical_through_symlink_and_dotdot()
    test_ignore_files_above_the_repository_are_not_read()
    test_bridge_crates_inside_the_project_are_not_source()
    print("test_walk: 5 passed")
