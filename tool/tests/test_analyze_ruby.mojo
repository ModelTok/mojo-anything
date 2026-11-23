# `analyze` of Ruby workspaces in Mojo (src/analyze.rs, src/report.rs,
# src/lang/ruby.rs read through tree-sitter's Python bindings, src/risks.rs,
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
    base = os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-ruby-%d" % os.getpid(), side)
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
    shutil.rmtree(os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-ruby-%d" % os.getpid()),
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


comptime _BAD = "cGFja2FnZSB1Ci8vIP8K"


comptime _WORDS = """require "json"
require 'set'
require "net/http"
require "nokogiri"
require "textkit/stack"
require_relative "util"
require_relative "../missing"
require name
load "x#{y}.rb"

module Textkit
  # Slug.
  # @param text [String]
  # @return [String]
  def self.slugify(text, sep = "-", max: nil)
    out = text.downcase.gsub(/[^a-z0-9]+/, sep)
    out[0, max] if max
    out
  end

  def self.each_word(text)
    yield text
  end

  def self.splat(*args) = args
  def self.opts(**o) = o
  def self.blk(&b) = b
  def self.value=(v) = v
  def self.bang!(x) = x
  def self.Upper(x) = x

  module Nums
    module_function

    def clamp(v, lo = 0, hi = 10)
      [[v, lo].max, hi].min
    end

    private

    def helper = 1
  end

  module Named
    def shellsplit(line)
      line.split
    end
    module_function :shellsplit

    def other(x) = x
  end

  class Stack < Object
    def push(x) = x

    class << self
      def build(n) = n
      private
      def secret(n) = n
    end

    def self.made(x) = x
    def self.gone(x) = x
    private_class_method :gone
  end
end

class String
  def shout = upcase
end

def risky(a, b)
  eval("1")
  a.send(:x)
  a.is_a?(Integer)
  define_method(:y) { 1 }
  [3, 1].sort_by { |x| x }.uniq
  a.each { |x| x }
  3.times do |i| i end
  Thread.new { 1 }
  Regexp.new(b)
  JSON.parse(b)
  raise "x" if a.nil?
  x = /(?<=a)b/ =~ b
  y = /\\h+/ =~ b
  z = %r{a(b)\\1}
  a[1]
  a / 2 % 3
  a ** 2 << 1
  h = { a: 1 }
  l = ->(q) { q }
  while a > 0
    a -= 1
  end
  until a > 3 do a += 1 end
  for i in 1..3 do end
  begin
    1
  rescue StandardError
    2
  ensure
    3
  end
  class << a
  end
  nil
end
"""


def test_ruby_plans_match_the_phase1_binary() raises:
    """Gems, units, waves, risks, module functions, tests and dependencies
    of Ruby workspaces, in Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "gem",
        [
            String(
                "textkit.gemspec=Gem::Specification.new do |spec|\n "
                ' spec.add_dependency "nokogiri", "~> 1.0"\n '
                " spec.add_runtime_dependency('rake')\n "
                " spec.add_development_dependency 'rspec'\nend\n"
            ),
            "Gemfile=source 'https://rubygems.org'\ngem \"rails\"\ngemspec\n",
            "lib/textkit.rb=" + _WORDS,
            "lib/util.rb=module Util\n  def self.f(x) = x * 2\nend\n",
            (
                "lib/textkit/stack.rb=require_relative"
                ' "../util"\nmodule Textkit\n  class Stack2\n    def'
                " self.depth(n) = n\n  end\nend\n"
            ),
            (
                "test/textkit_test.rb=require"
                ' "textkit"\nrequire_relative "../lib/util"\n'
            ),
            "spec/stack_spec.rb=require 'textkit/stack'\n",
            "lib/test_helper.rb=x = 1\n",
            "vendor/v.rb=x = 1\n",
            "tmp/t.rb=x = 1\n",
            "engines/sub/Gemfile=gem 'pg'\n",
            "engines/sub/lib/sub.rb=require 'textkit'\nmodule Sub; end\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "plain",
        [
            "a.rb=require_relative 'b'\nmodule A\n  def self.f(x) = x\nend\n",
            "b.rb=require_relative './a'\nmodule B\n  def self.g(x) = x\nend\n",
            "c/d.rb=require 'a'\n",
        ],
        ["analyze", ".", "--lang", "ruby"],
    )
    var many = List[String]()
    many.append("Gemfile=gem 'x'\n")
    for i in range(12):
        var body = String("module M", i, "\n  def self.f(s)\n")
        for _ in range(i * 3):
            body += "    s = s[1..] + s.downcase\n"
        body += "    s\n  end\nend\n"
        many.append(String("lib/m", i, "/m.rb=") + body)
    _both_ways(t, "many", many, dot)
    _both_ways(
        t,
        "unreadable",
        ["Gemfile=x\n", "bad.rb=b64:" + String(_BAD), "good.rb=x = 1\n"],
        dot,
    )


def test_out_writes_a_ruby_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            ["Gemfile=x\n", "a.rb=module A\n  def self.f(x) = x\nend\n"],
            ["analyze", ".", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary() raises:
    """A tree with an error, a method name outside ASCII, two gemspecs in
    one folder and ignore files with alternates."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(("syntax", "Gemfile=x\n|a.rb=def f(\n"))
    cases.append(
        (
            "unicode-name",
            "Gemfile=x\n|a.rb=module A\n  def self.été(x) = x\nend\n",
        )
    )
    cases.append(("two-gemspecs", "a.gemspec=x\n|b.gemspec=y\n|a.rb=x = 1\n"))
    cases.append(
        ("ignore-braces", "Gemfile=x\n|.gitignore={a,b}/\n|a.rb=x = 1\n")
    )
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", "."])
        # The log names the subcommand and its positional arguments.
        assert_equal(log, "analyze .\n", "fallback of " + c[0])


def main() raises:
    test_ruby_plans_match_the_phase1_binary()
    test_out_writes_a_ruby_plan()
    test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_ruby: 3 passed")
