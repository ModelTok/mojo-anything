# Java over the Mojo JSON dispatcher: the generated classes of a `mojo-jvm`
# unit (port of src/codegen_mojo_jvm.rs, with codegen_ffi.rs
# `java_native_class`, codegen_java.rs `boxed` and `imports_of`, java.rs
# `receiver` and bridge.rs `mojo_jvm_bindings`). The fixed Java texts
# (NATIVE_FFM, JSON_JAVA, ERROR_JAVA) are embedded from the Rust sources by
# tool/embedded.py.

from mojo_anything.analyze import lang_name
from mojo_anything.codegen_ffi import DISPATCHER, dispatcher_mojo
from mojo_anything.codegen_mojo import (
    ExportedFn,
    Manifest,
    PortApi,
    is_alnum,
    join,
    trim,
)
from mojo_anything.codegen_mojo_py import unit_pixi_toml
from mojo_anything.embedded import (
    java_error,
    java_json,
    java_native_ffm,
    json_mojo,
)


def java_native_class(m: Manifest) -> String:
    """`<Lib>Native`: each `_`-separated part of the library name with its
    first letter upper-cased."""
    var out = String("")
    for part in m.lib_name().split("_"):
        var p = String(part)
        if p.byte_length() == 0:
            continue
        out += String(p[byte=0:1]).upper() + String(p[byte=1:])
    return out + "Native"


def native_class_ffm(m: Manifest) -> String:
    return (
        java_native_ffm()
        .replace("@CLASS@", java_native_class(m))
        .replace("@LIB@", m.lib_name())
        .replace("@UNIT@", m.unit)
    )


def boxed(t: String) -> String:
    """A primitive boxed for generics: `int` to `Integer`."""
    var s = trim(t)
    if s == "int":
        return "Integer"
    if s == "long":
        return "Long"
    if s == "short":
        return "Short"
    if s == "byte":
        return "Byte"
    if s == "double":
        return "Double"
    if s == "float":
        return "Float"
    if s == "boolean":
        return "Boolean"
    if s == "char":
        return "Character"
    return s


def _words(t: String) -> List[String]:
    """`t.split(|c| !c.is_alphanumeric())` (the text is ASCII here)."""
    var out = List[String]()
    var cur = String("")
    for b in t.as_bytes():
        if is_alnum(b):
            cur += chr(Int(b))
        else:
            out.append(cur)
            cur = ""
    out.append(cur)
    return out^


def imports_of(m: Manifest) -> String:
    """The `java.util` imports the original signatures need."""
    var names = List[String]()
    for f in m.exports:
        var types = List[String]()
        for p in f.params:
            if p.native_type:
                types.append(p.native_type.value())
        if f.native_return:
            types.append(f.native_return.value())
        for t in types:
            var words = _words(t)
            for name in ["List", "Map", "Optional", "Collection", "Set"]:
                var n = String(name)
                if n in words and n not in names:
                    names.append(n)
    for i in range(1, len(names)):
        var k = i
        while k > 0 and names[k] < names[k - 1]:
            names.swap_elements(k, k - 1)
            k -= 1
    var out = String("")
    for n in names:
        out += String("import java.util.", n, ";\n")
    if out.byte_length() > 0:
        out += "\n"
    return out


def receiver(f: ExportedFn) -> Tuple[String, String]:
    """The declaring class and the method name: `("com.x.Strings", "slugify")`.
    """
    var proto = f.prototype.or_else(f.name)
    var paren = proto.find("(")
    var head = proto if paren < 0 else String(proto[byte=0:paren])
    var dot = head.rfind(".")
    if dot < 0:
        return (String(""), f.name)
    return (String(head[byte=0:dot]), String(head[byte = dot + 1 :]))


def _simple(class_name: String) -> String:
    var dot = class_name.rfind(".")
    if dot < 0:
        return class_name
    return String(class_name[byte = dot + 1 :])


@fieldwise_init
struct _Wrapper(Copyable, Movable):
    var class_name: String
    var methods: List[String]
    var holder: Optional[String]
    var members: List[String]
    var constructor: Bool


def wrappers_ffm(m: Manifest) -> Tuple[List[String], List[String]]:
    """`(paths, sources)` of the wrapper classes, one per class of the unit
    in the order its exports first name it."""
    var native = java_native_class(m)
    var classes = List[_Wrapper]()
    for f in m.exports:
        var rc = receiver(f)
        var class_name = rc[0]
        var name = rc[1]
        var simple = _simple(class_name)
        var ret = f.native_return.or_else("void")
        var params = List[String]()
        var names = List[String]()
        for p in f.params:
            params.append(String(p.native_type.or_else("Object"), " ", p.name))
            names.append(p.name)
        var args = String("new Object[] {", join(names, ", "), "}")
        var ty = String("T_", f.name)
        var field = String("")
        var body: String
        if ret == "void":
            body = String(
                "mojoanything.",
                native,
                '.invoke("',
                f.name,
                '", void.class, ',
                args,
                ");",
            )
        else:
            field = String(
                "    private static final java.lang.reflect.Type ",
                ty,
                " =\n        new mojoanything.MojoAnythingJson.TypeRef<",
                boxed(ret),
                ">() {}.type();\n\n",
            )
            body = String(
                "return (",
                boxed(ret),
                ") mojoanything.",
                native,
                '.invoke("',
                f.name,
                '", ',
                ty,
                ", ",
                args,
                ");",
            )
        var method = String(
            field,
            "    /** The Mojo port of `",
            f.prototype.or_else(f.name),
            "` (`",
            f.file,
            ":",
            f.line,
            "`). */\n    public static ",
            ret,
            " ",
            name,
            "(",
            join(params, ", "),
            ") {\n        ",
            body,
            "\n    }\n",
        )
        var member = String(
            "        public ",
            ret,
            " ",
            name,
            "(",
            join(params, ", "),
            ") {\n            ",
            "" if ret == "void" else "return ",
            simple,
            ".",
            name,
            "(",
            join(names, ", "),
            ");\n        }\n",
        )
        var at = -1
        for i in range(len(classes)):
            if classes[i].class_name == class_name:
                at = i
                break
        if at < 0:
            classes.append(
                _Wrapper(
                    class_name,
                    List[String](),
                    f.jvm_holder,
                    List[String](),
                    False,
                )
            )
            at = len(classes) - 1
        classes[at].constructor = classes[at].constructor or f.jvm_constructor
        classes[at].methods.append(method)
        classes[at].members.append(member)
    var imports = imports_of(m)
    var paths = List[String]()
    var texts = List[String]()
    for w in classes:
        var dot = w.class_name.rfind(".")
        var package = String("")
        var simple = w.class_name
        if dot >= 0:
            package = String(w.class_name[byte=0:dot])
            simple = String(w.class_name[byte = dot + 1 :])
        var methods = w.methods.copy()
        if w.holder:
            var h = w.holder.value()
            if h.startswith("companion:"):
                var cname = String(h[byte=10:])
                methods.insert(
                    0,
                    String(
                        "    /** Kotlin callers read the companion object `",
                        cname,
                        "` from this field. */\n    public static final ",
                        cname,
                        " ",
                        cname,
                        " = new ",
                        cname,
                        (
                            "();\n\n    /** The companion object: each member"
                            " calls the"
                        ),
                        (
                            " static method of the same name. */\n    public"
                            " static"
                        ),
                        " final class ",
                        cname,
                        " {\n        private ",
                        cname,
                        "() {}\n\n",
                        join(w.members, "\n"),
                        "    }\n",
                    ),
                )
            else:
                methods.insert(
                    0,
                    String(
                        (
                            "    /** The `object` instance, as Kotlin declares"
                            " it. */\n    public static final "
                        ),
                        simple,
                        " INSTANCE = new ",
                        simple,
                        "();\n",
                    ),
                )
        var path: String
        if package.byte_length() == 0:
            path = String("java/", simple, ".java")
        else:
            path = String(
                "java/", package.replace(".", "/"), "/", simple, ".java"
            )
        var out = String("")
        if package.byte_length() > 0:
            out += String("package ", package, ";\n\n")
        out += imports
        var constructor: String
        if w.constructor:
            constructor = String(
                (
                    "    /** The original's public no-arg constructor. */\n   "
                    " public "
                ),
                simple,
                "() {}\n",
            )
        else:
            constructor = String("    private ", simple, "() {}\n")
        out += String(
            "/**\n * The Mojo port of `",
            simple,
            "`, generated by mojo-anything: the same static methods, each\n",
            " * calling the Mojo library through the JSON dispatcher.",
            " Regenerate with `mojo-anything refresh`.\n */\n",
            '@SuppressWarnings("unchecked")\npublic final class ',
            simple,
            " {\n",
            constructor,
            "\n",
            join(methods, "\n"),
            "}\n",
        )
        paths.append(path)
        texts.append(out)
    return (paths^, texts^)


def mojo_jvm_bindings(
    m: Manifest,
    api: PortApi,
    mut paths: List[String],
    mut texts: List[String],
) raises:
    """bridge.rs `mojo_jvm_bindings`: `pixi.toml`, `json.mojo`, the
    dispatcher over the unit's exports, the FFM class, the codec, the error
    mapping and the wrappers."""
    if len(m.batches) > 0:
        raise Error(
            "not yet: batches for Java units ported to Mojo come after"
            " correctness"
        )
    if m.language != "java" and m.language != "kotlin":
        raise Error(
            String(lang_name(m.language), " units do not bridge through Java")
        )
    var exported = PortApi()
    for f in api.functions:
        for e in m.exports:
            if e.name == f.js_name:
                exported.functions.append(f.copy())
                break
    for s in api.structs:
        exported.structs.append(s)
    paths.append("pixi.toml")
    texts.append(unit_pixi_toml(m, True))
    paths.append("json.mojo")
    texts.append(json_mojo())
    paths.append(DISPATCHER)
    texts.append(dispatcher_mojo(m, exported))
    paths.append(String("java/mojoanything/", java_native_class(m), ".java"))
    texts.append(native_class_ffm(m))
    paths.append("java/mojoanything/MojoAnythingJson.java")
    texts.append(java_json())
    paths.append("java/mojoanything/MojoAnythingError.java")
    texts.append(java_error())
    var w = wrappers_ffm(m)
    for i in range(len(w[0])):
        paths.append(w[0][i])
        texts.append(w[1][i])
