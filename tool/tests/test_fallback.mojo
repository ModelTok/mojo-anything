from std.os import setenv, unsetenv
from std.testing import assert_equal, assert_true

from mojo_anything.fallback import dirname, fallback_path, own_binary


def test_dirname() raises:
    assert_equal(dirname("/a/b/c"), "/a/b")
    assert_equal(dirname("/a/b/c/"), "/a/b")
    assert_equal(dirname("c"), ".")
    assert_equal(dirname("/c"), "/")
    assert_equal(dirname("a//b"), "a")


def test_fallback_path_from_env() raises:
    _ = setenv("MOJO_ANYTHING_FALLBACK", "/somewhere/else")
    assert_equal(fallback_path(), "/somewhere/else")
    _ = unsetenv("MOJO_ANYTHING_FALLBACK")


def test_fallback_path_beside_binary() raises:
    _ = unsetenv("MOJO_ANYTHING_FALLBACK")
    var own = own_binary()
    assert_true(own.startswith("/"), own)
    assert_equal(
        fallback_path(), dirname(dirname(own)) + "/fallback/mojo-anything"
    )


def main() raises:
    test_dirname()
    test_fallback_path_from_env()
    test_fallback_path_beside_binary()
    print("test_fallback: 3 passed")
