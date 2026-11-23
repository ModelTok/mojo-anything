# `analyze` of PHP workspaces in Mojo (src/analyze.rs, src/report.rs,
# src/lang/php.rs read through tree-sitter's Python bindings, src/risks.rs,
# the crate table and bridge::js_only_reason): the Mojo binary runs next to
# the Phase 1 binary on copies of the same project, and the two must agree
# byte for byte with no fallback logged; a file tree-sitter may read
# otherwise goes to the Phase 1 binary.

from std.python import Python, PythonObject
from std.testing import assert_equal


comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

def fixture(side, name, files):
    base = os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-tree-%d" % os.getpid(), side)
    d = os.path.join(base, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for rel, text in files:
        p = os.path.join(d, rel)
        if rel.endswith("/"):
            os.makedirs(p, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if text.startswith("b64:"):
            import base64
            with open(p, "wb") as f:
                f.write(base64.b64decode(text[4:]))
            continue
        with open(p, "w", newline="") as f:
            f.write(text)
    return d

def gone():
    shutil.rmtree(os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-tree-%d" % os.getpid()),
                  ignore_errors=True)

def tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        for f in files:
            p = os.path.join(base, f)
            if f.endswith(".fallback.log"):
                continue
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, d), fh.read()))
    out.sort()
    return repr(out)

def run(binary, args, cwd, log):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
    out = p.stdout.decode("utf-8", "replace").replace(cwd, "<D>")
    err = p.stderr.decode("utf-8", "replace").replace(cwd, "<D>")
    return (p.returncode, out, err)

def log_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""
""",
        scope,
    )
    return scope


def _files(spec: List[String]) raises -> PythonObject:
    """Pairs of (path, text) from `path=text` strings; `dir/` makes a folder."""
    var out = Python.list()
    for s in spec:
        var eq = s.find("=")
        if eq < 0:
            out.append(Python.tuple(PythonObject(s), PythonObject("")))
        else:
            out.append(
                Python.tuple(
                    PythonObject(String(s[byte=0:eq])),
                    PythonObject(String(s[byte = eq + 1 :])),
                )
            )
    return out


def _both(
    t: PythonObject, name: String, spec: List[String], args: List[String]
) raises -> String:
    """Runs both binaries on fresh copies of the project; returns the Mojo
    run's fallback log."""
    var files = _files(spec)
    var old = String(
        py=t["fixture"](PythonObject("old"), PythonObject(name), files)
    )
    var new = String(
        py=t["fixture"](PythonObject("new"), PythonObject(name), files)
    )
    var pargs = Python.list()
    var shown = String(" in " + name + ":")
    for a in args:
        pargs.append(PythonObject(a))
        shown += " " + a
    var o = t["run"](
        PythonObject(FALLBACK), pargs, PythonObject(old), PythonObject("")
    )
    var log = new + ".fallback.log"
    var n = t["run"](
        PythonObject(MOJO), pargs, PythonObject(new), PythonObject(log)
    )
    assert_equal(String(py=n[1]), String(py=o[1]), "stdout of" + shown)
    assert_equal(String(py=n[2]), String(py=o[2]), "stderr of" + shown)
    assert_equal(Int(py=n[0]), Int(py=o[0]), "exit code of" + shown)
    assert_equal(
        String(py=t["tree"](PythonObject(new))),
        String(py=t["tree"](PythonObject(old))),
        "files of" + shown,
    )
    return String(py=t["log_text"](PythonObject(log)))


def _both_ways(
    t: PythonObject, name: String, spec: List[String], args: List[String]
) raises:
    """Markdown and `--json`, both owned by Mojo."""
    assert_equal(_both(t, name, spec, args), "", "fell back in " + name)
    var j = args.copy()
    j.append("--json")
    assert_equal(_both(t, name, spec, j), "", "fell back in " + name)


comptime _SLUG = """<?php
declare(strict_types=1);
namespace App\\Text;

use App\\Util\\Str;
use GuzzleHttp\\Client;
use Symfony\\Component\\HttpFoundation\\Request;
use Symfony\\Component\\Yaml\\Yaml;
use Monolog\\{Logger, Handler\\StreamHandler};
use Psr\\Log\\LoggerInterface as Log;
use Unknown\\Vendor\\Thing;
use DateTime;
use function App\\Util\\helper;
require_once __DIR__ . '/helpers.php';
require 'lib/boot.php';
include $dynamic;
include_once "../outside.php";

/**
 * @param string $s
 * @param list<string> $stop
 * @return string
 */
function slugify($s, array $stop = [], ?int $max = null): string
{
    $out = strtolower($s);
    foreach ($stop as $w) {
        $out = str_replace($w, '', $out);
    }
    if ($max !== null && strlen($out) > $max) {
        $out = substr($out, 0, $max);
    }
    return preg_replace('/[^a-z0-9]+/', '-', $out);
}

function words(string $s, string ...$more): array { return explode(' ', $s); }
function swap(&$a, &$b): void { [$a, $b] = [$b, $a]; }
function apply(callable $f, $x) { return $f($x); }
function lazy(int $n): iterable { for ($i = 0; $i < $n; $i++) { yield $i; } }
function __magic() {}
function typed(int|string $x, float $y = 1.5, bool $z = true, $w = 'a'): ?float { return $y / 2; }

abstract class Shape { public static function area(): float { return 0.0; } }

final class Slug extends Base implements \\JsonSerializable
{
    use Helpers;

    public static function make(string $s): string { return slugify($s); }
    static function implicit(int $n): int { return $n * 2 ** 3 << 1; }
    private static function hidden(): void {}
    protected static function prot(): void {}
    public function instance(): void {}
    public static function __callStatic($n, $a) { return null; }
    public function __get($n) { return $this->$n; }

    public function jsonSerialize(): mixed
    {
        $r = new \\ReflectionClass($this);
        $f = new Fiber(function () {});
        $x = $$name;
        if ($a == $b || $a != $c || $a <> $d || ($a <=> $e)) {}
        $m = 7 % 3;
        try {
            throw new \\RuntimeException('x');
        } catch (\\Exception $e) {
        }
        $g = fn($v) => $v + 1;
        usort($list, fn($a, $b) => $a <=> $b);
        array_map(null, []);
        sort($list);
        json_encode($list);
        intdiv(7, 2);
        eval('1;');
        call_user_func('f');
        class_alias('A', 'B');
        proc_open('x', [], $p);
        preg_match('/(a)\\1/', $s);
        preg_match('#(?>a)#', $s);
        preg_match("/$pat/", $s);
        preg_match($pat, $s);
        preg_match('~\\Kx~', $s);
        mb_substr($s, 1);
        while (false) {}
        do {} while (false);
        return [1, 2];
    }
}
"""

comptime _HELPERS = """<?php
namespace App\\Util;

use App\\Text\\Slug;

function helper(string $s): string { return $s; }

class Str
{
    public static function upper(string $s): string { return strtoupper($s); }
}
"""

comptime _COMPOSER = """{
    "name": "acme/slug",
    "require": {
        "php": ">=8.1",
        "ext-json": "*",
        "guzzlehttp/guzzle": "^7.0",
        "symfony/yaml": "^6.0",
        "monolog/monolog": "^3.0",
        "acme/lib": "*"
    },
    "require-dev": {
        "phpunit/phpunit": "^10"
    },
    "autoload": {
        "psr-4": { "App\\\\": "src/" }
    },
    "autoload-dev": {
        "psr-4": { "App\\\\Tests\\\\": "tests/" }
    }
}
"""


def test_php_plans_match_the_phase1_binary() raises:
    """Composer packages, PSR-4 roots, units, waves, cycles, risks, exports,
    tests and dependencies of PHP workspaces, in Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "composer",
        [
            "composer.json=" + _COMPOSER,
            "src/Text/Slug.php=" + _SLUG,
            "src/Text/helpers.php=<?php\nfunction h(): int { return 1; }\n",
            "src/Util/Str.php=" + _HELPERS,
            "src/Util/lib/boot.php=<?php\n",
            "src/Text/lib/boot.php=<?php\n$x = 1;\n",
            (
                "tests/SlugTest.php=<?php\nnamespace App\\Tests;\nuse"
                " App\\Text\\Slug;\nclass SlugTest {}\n"
            ),
            "src/Util/StrTest.php=<?php\nclass StrTest {}\n",
            "src/spec/Spec.php=<?php\nclass Spec {}\n",
            "vendor/acme/x.php=<?php\nfunction v() {}\n",
            "var/cache.php=<?php\n",
            ".hidden/h.php=<?php\n",
            (
                'packages/lib/composer.json={"autoload": {"psr-4": {"Lib\\\\":'
                ' ["lib/", "other/"]}}, "require": {"acme/slug": "*"}}\n'
            ),
            (
                "packages/lib/lib/Tool.php=<?php\nnamespace Lib;\nuse"
                " App\\Text\\Slug;\nfunction tool(int $n): int { return $n; }\n"
            ),
        ],
        dot,
    )
    _both_ways(
        t,
        "plain",
        [
            "a.php=<?php\nrequire 'b.php';\nfunction a(): int { return 1; }\n",
            (
                "b.php=<?php\nrequire_once __DIR__ ."
                " '/a.php';\nfunction b(): int { return 2; }\n"
            ),
            "src/c.php=<?php\nuse Foo;\nfunction c() { return null; }\n",
        ],
        ["analyze", ".", "--lang", "php"],
    )
    var many = List[String]()
    many.append('composer.json={"name": "acme/many"}\n')
    for i in range(12):
        var body = String("<?php\nfunction f", i, "(string $s): string {\n")
        for _ in range(i * 3):
            body += "    $s = substr($s, 1) . strtolower($s);\n"
        body += "    return $s;\n}\n"
        many.append(String("p", i, "/M", i, ".php=") + body)
    _both_ways(t, "many", many, dot)
    _both_ways(
        t,
        "unreadable",
        [
            "composer.json={}\n",
            "Bad.php=b64:PD9waHAgLyog/yAqLwo=",
            "Good.php=<?php\nfunction f(int $x): int { return $x; }\n",
        ],
        dot,
    )


def test_out_writes_a_php_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            ["composer.json={}\n", "a.php=<?php\nfunction f() {}\n"],
            ["analyze", ".", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary() raises:
    """A tree with an error, a composer.json serde_json may read otherwise
    and ignore files with alternates."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(("syntax", "composer.json={}\n|a.php=<?php\nfunction f( {\n"))
    cases.append(("bad-json", "composer.json={\n|a.php=<?php\n"))
    cases.append(
        (
            "ignore-braces",
            ".gitignore={a,b}/\n|composer.json={}\n|a.php=<?php\n",
        )
    )
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", "."])
        assert_equal(log, "analyze .\n", "fallback of " + c[0])


def main() raises:
    test_php_plans_match_the_phase1_binary()
    test_out_writes_a_php_plan()
    test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_php: 3 passed")
