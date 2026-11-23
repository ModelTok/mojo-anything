# The catalog of behaviours that do not carry over as-is (port of src/risks.rs's
# Risk and Severity: names, order, severity, weight, title and guidance). A
# risk is its index in `RISKS`, the declaration order Rust's derived `Ord`
# sorts by. The checks that find risks in Python (`compiled_by`,
# `regex_needs_fancy`) run inside the `ast` walk, analyze_py.py.

comptime RISK_COUNT = 25
comptime LOW = 0
comptime MEDIUM = 1
comptime HIGH = 2


def risk_names() -> List[String]:
    """serde's kebab-case names, in declaration order."""
    return [
        "string-offsets",
        "regex-syntax",
        "dynamic-regex",
        "dynamic-code",
        "dynamic-typing",
        "ordered-collections",
        "exceptions",
        "async",
        "generators",
        "class-inheritance",
        "reflection",
        "callbacks",
        "number-semantics",
        "json",
        "integer-semantics",
        "division-semantics",
        "unordered-iteration",
        "pointers",
        "concurrency",
        "null-references",
        "monkeypatching",
        "already-compiled",
        "array-parameters",
        "platform-specific",
        "clock-and-random",
    ]


def risk_index(name: String) -> Int:
    var names = risk_names()
    for i in range(len(names)):
        if names[i] == name:
            return i
    return -1


def severity(risk: Int) -> Int:
    var name = risk_names()[risk]
    if (
        name == "string-offsets"
        or name == "regex-syntax"
        or name == "dynamic-regex"
        or name == "dynamic-code"
        or name == "pointers"
        or name == "monkeypatching"
        or name == "unordered-iteration"
        or name == "platform-specific"
        or name == "array-parameters"
    ):
        return HIGH
    if (
        name == "exceptions"
        or name == "number-semantics"
        or name == "json"
        or name == "clock-and-random"
    ):
        return LOW
    return MEDIUM


def severity_weight(s: Int) -> Float64:
    if s == LOW:
        return 1.0
    if s == MEDIUM:
        return 3.0
    return 6.0


def severity_name(s: Int) -> String:
    """serde's lowercase name."""
    if s == LOW:
        return "low"
    if s == MEDIUM:
        return "medium"
    return "high"


def severity_debug(s: Int) -> String:
    """`{:?}` of Severity."""
    if s == LOW:
        return "Low"
    if s == MEDIUM:
        return "Medium"
    return "High"


def risk_title(risk: Int) -> String:
    var titles: List[String] = [
        "String offsets and slicing",
        "Regexes (Mojo has no engine; lookaround, backreferences, `y`)",
        "Regexes built at runtime (Mojo has no engine)",
        "Dynamic code (eval, new Function, computed import)",
        "Dynamic typing",
        "Insertion-ordered maps and object keys",
        "Exceptions",
        "Async and promises",
        "Generators",
        "Class inheritance",
        "Reflection and prototypes",
        "Callback-shaped APIs",
        "Number semantics",
        "JSON round-trips",
        "Integer width and overflow",
        "Division and modulo",
        "Hash iteration order",
        "Pointers and manual memory",
        "Concurrency",
        "Null references",
        "Runtime changes to code",
        "Already compiled (numba, Cython, JAX)",
        "numpy array parameters",
        "Platform-specific C (asm, volatile, bitfields, packing)",
        "Clock and random numbers",
    ]
    return titles[risk]


def risk_guidance(risk: Int) -> String:
    var g: List[String] = [
        (
            "JS indexes strings in UTF-16 code units, Rust in UTF-8 bytes."
            " Offsets that cross the boundary must be converted, or non-ASCII"
            " text gets wrong ranges silently."
        ),
        (
            "Mojo's standard library has no regex engine: rewrite the pattern"
            " by hand, or run it through Python's `re` over CPython interop,"
            " which a lifted binary then still needs. Lookaround and"
            " backreferences make a hand rewrite harder, and `re` has no `y`"
            " flag. Test either on non-ASCII text: `\\w`, `\\b` and"
            " case-insensitive matching differ between engines even where a"
            " pattern compiles. JS `/i` without `u` never matches a non-ASCII"
            " letter to an ASCII one, `re.IGNORECASE` on a `str` does (`ſ`"
            " matches `s`, the Kelvin sign `K` matches `k`): add `re.ASCII`,"
            " or compare ASCII letters by hand."
        ),
        (
            "Patterns come from data or config in the original's syntax at"
            " runtime. Mojo has no regex engine, and Python's `re` reads some"
            " of that syntax differently, so user-visible behavior can change."
            " Pin it with tests on real patterns."
        ),
        (
            "eval, new Function and computed imports have no Rust equivalent."
            " Keep this part in JS or replace it with an explicit registry."
        ),
        (
            "Values whose shape is checked at runtime need an explicit Rust"
            " enum or `serde_json::Value`."
        ),
        (
            "JS Map, Set and object keys keep insertion order. `HashMap` does"
            " not: use `indexmap` wherever order reaches output. With"
            " serde_json's `preserve_order`, `Map::remove` swaps the last key"
            " into the hole: use `shift_remove` for JS `delete`. Sort with"
            " `js::sort` when a comparator can return NaN: the order then"
            " depends on V8's algorithm."
        ),
        (
            "Thrown errors become `Result`. Errors crossing the bridge must map"
            " back to the same JS error shape."
        ),
        (
            "Promises have no Mojo counterpart across the bridge: keep the"
            " async shell in JS and port the sync core."
        ),
        (
            "Lazy generators become iterators, or return a collected Vec"
            " across the bridge."
        ),
        (
            "Class hierarchies become traits plus composition; `instanceof`"
            " checks become enums."
        ),
        (
            "Proxy, Reflect, Symbol and prototype tricks need a redesign, not a"
            " translation."
        ),
        (
            "Function-typed parameters and methods cross the bridge on every"
            " call. Keep boundaries coarse: pass data in, get data out."
        ),
        (
            "JS numbers are f64; bitwise ops truncate to i32; parseInt is"
            " lenient. Pick Rust integer types deliberately. Printing differs:"
            " `${n}` gives `1e+21`, `1e-7` and `0` for -0 where Rust's `{}`"
            " does not, so use `js::number_to_string`. `Math.round` rounds"
            " halves up (-2.5 gives -2), Rust's `round` away from zero: use"
            " `js::math_round`. `toFixed` rounds exact halves up"
            ' ((2.5).toFixed(0) is "3"), Rust\'s `{:.0}` to even.'
        ),
        (
            "JSON.stringify key order and number formatting must match"
            " `serde_json` output if the result is user-visible."
        ),
        (
            "Python ints never overflow; C, Go and Java ints wrap or are"
            " undefined on overflow. Pick i64, i128 or a bignum crate"
            " deliberately, and use wrapping_* where the source wraps."
        ),
        (
            "Python `//` and `%` floor toward negative infinity; Rust `/` and"
            " `%` truncate: use `div_euclid`/`rem_euclid` or explicit floor"
            " math. C division by zero is undefined."
        ),
        (
            "Set and map iteration order comes from the source language's hash"
            " function. A port cannot reproduce it: sort before output, or make"
            " the order part of the contract."
        ),
        (
            "Pointer arithmetic and manual memory become slices, indices and"
            " owned types. Code that exposes pointers across the boundary needs"
            " `unsafe`, isolated and explained."
        ),
        (
            "Threads, goroutines and locks need a design in Rust (channels,"
            " Send/Sync), not a line-by-line translation; keep concurrency in"
            " the caller where possible."
        ),
        (
            "Any reference may be null in the source: decide per parameter"
            " whether it is `Option` and what null means, instead of mapping"
            " every value to `Option`."
        ),
        (
            "Code that rewrites classes or modules at runtime has no Rust"
            " equivalent: keep it in the source language and port the stable"
            " parts."
        ),
        (
            "numba, Cython and JAX already compile this code to machine code"
            " (numba through LLVM, like Rust): a Rust port is unlikely to run"
            " much faster. Port it for a pure Rust app, not for speed, and"
            " profile first. Its floats may not match Rust's bit for bit"
            " (fastmath, operation order): record with `--float-tolerance`."
        ),
        (
            "`record` passes JSON values, never numpy arrays, so a function"
            " that takes `np.ndarray` gets no valid cases on the unit path."
            " Record the app instead (`app record`, `app replay`), or port the"
            " function together with a caller that takes and returns plain"
            " lists."
        ),
        (
            "This C depends on its target: register access, memory layout, the"
            " compiler's type sizes or its assembly. A recording on this"
            " machine says nothing about the target, and battle-tested driver"
            " or firmware code gains little from a rewrite: keep it in C and"
            " port the portable logic around it."
        ),
        (
            "Results that depend on the time or on random numbers differ on"
            " every run, so a plain recording cannot pin them down. Record with"
            " `record --pin-clock` (TS/JS with the node bridge, Python):"
            " `Date.now()`, `new Date()` and `Math.random` (`time.time`,"
            " `datetime.now` and `random`) then return fixed values during"
            " record, diff and gate, and the port reads the same ones from"
            " `pinned.mojo` (`now_ms()`, `random()`, a documented mulberry32;"
            " `src/port/pinned.rs` for a Rust port). Or pass the time and the"
            " seed in as parameters."
        ),
    ]
    return g[risk]
