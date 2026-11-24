# The shape of a type as `record` generates values for it (port of
# src/ts/shape.rs `parse`, `convert` and `resolve`). Rust parses the type with
# oxc as `type __T = <text>;`; here a small reader takes the forms the Python
# type dialect writes (python.rs `to_ts_type`: keywords, `int`, string and
# number literals, unions, intersections, `T[]`, parentheses, `readonly`,
# object types with properties and index signatures, named types with type
# arguments, dotted names) and raises `DECLINE` on anything else, where oxc's
# reading would have to be reproduced (function types, tuples, template
# literals, a leading `|`, escapes in a literal, negative numbers).
#
# Shapes live in an arena: a node is an index into `Shapes`.

comptime DECLINE = "decline: a type the shape reader does not read"

comptime S_STR = 0
comptime S_NUM = 1
comptime S_INT = 2
comptime S_BOOL = 3
comptime S_NULL = 4
comptime S_UNDEF = 5
comptime S_LITSTR = 6
comptime S_LITNUM = 7
comptime S_LITBOOL = 8
comptime S_UNION = 9
comptime S_ARRAY = 10
comptime S_TUPLE = 11
comptime S_OBJECT = 12
comptime S_REF = 13
comptime S_ANY = 14


def _is_ident_start(b: UInt8) -> Bool:
    return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b == 36


def _is_ident(b: UInt8) -> Bool:
    return _is_ident_start(b) or (b >= 48 and b <= 57)


def _is_space(b: UInt8) -> Bool:
    return b == 32 or b == 9 or b == 10 or b == 13


struct Shapes(Movable):
    """The arena: per node its kind, text (a literal's value, a name), child
    nodes (union and tuple items, an array's item, a reference's type
    arguments, an object's property shapes), property names and optional
    flags, and an object's index-signature shape (-1 for none)."""

    var kinds: List[Int]
    var texts: List[String]
    var kids: List[List[Int]]
    var names: List[List[String]]
    var optional: List[List[Bool]]
    var index: List[Int]
    # The reader's position in the text being parsed.
    var src: String
    var at: Int

    def __init__(out self):
        self.kinds = List[Int]()
        self.texts = List[String]()
        self.kids = List[List[Int]]()
        self.names = List[List[String]]()
        self.optional = List[List[Bool]]()
        self.index = List[Int]()
        self.src = ""
        self.at = 0

    def node(mut self, kind: Int, text: String = "") -> Int:
        self.kinds.append(kind)
        self.texts.append(text)
        self.kids.append(List[Int]())
        self.names.append(List[String]())
        self.optional.append(List[Bool]())
        self.index.append(-1)
        return len(self.kinds) - 1

    def copy_object(mut self, s: Int, all_optional: Bool) -> Int:
        var n = self.node(S_OBJECT)
        self.kids[n] = self.kids[s].copy()
        self.names[n] = self.names[s].copy()
        var opts = List[Bool]()
        for o in self.optional[s]:
            opts.append(True if all_optional else o)
        self.optional[n] = opts^
        self.index[n] = self.index[s]
        return n

    # ---- the reader ----------------------------------------------------------

    def parse(mut self, text: String) raises -> Int:
        """shape.rs `parse`: the shape of `text`, or raises DECLINE."""
        var saved_src = self.src
        var saved_at = self.at
        self.src = text
        self.at = 0
        var s = self._union()
        self._skip()
        if self.at != self.src.byte_length():
            raise Error(DECLINE)
        self.src = saved_src
        self.at = saved_at
        return s

    def _skip(mut self):
        var b = self.src.as_bytes()
        while self.at < len(b) and _is_space(b[self.at]):
            self.at += 1

    def _peek(mut self) -> Int:
        self._skip()
        var b = self.src.as_bytes()
        if self.at >= len(b):
            return -1
        return Int(b[self.at])

    def _eat(mut self, c: Int) -> Bool:
        if self._peek() == c:
            self.at += 1
            return True
        return False

    def _word(mut self) -> String:
        """An identifier at the position, or ""."""
        self._skip()
        var b = self.src.as_bytes()
        if self.at >= len(b) or not _is_ident_start(b[self.at]):
            return ""
        var start = self.at
        while self.at < len(b) and _is_ident(b[self.at]):
            self.at += 1
        return String(self.src[byte = start : self.at])

    def _peek_word(mut self) -> String:
        var at = self.at
        var w = self._word()
        self.at = at
        return w

    def _union(mut self) raises -> Int:
        if self._peek() == 124:  # a leading `|`
            raise Error(DECLINE)
        var first = self._intersection()
        if self._peek() != 124:
            return first
        var u = self.node(S_UNION)
        var items: List[Int] = [first]
        while self._eat(124):
            items.append(self._intersection())
        self.kids[u] = items^
        return u

    def _intersection(mut self) raises -> Int:
        if self._peek() == 38:
            raise Error(DECLINE)
        var first = self._operator()
        if self._peek() != 38:
            return first
        var parts: List[Int] = [first]
        while self._eat(38):
            parts.append(self._operator())
        # `A & { b: string }`: the object parts merged; the first part that
        # is not an object is the shape.
        var merged = self.node(S_OBJECT)
        for p in parts:
            if self.kinds[p] != S_OBJECT:
                return p
            for k in range(len(self.kids[p])):
                self.kids[merged].append(self.kids[p][k])
                self.names[merged].append(self.names[p][k])
                self.optional[merged].append(self.optional[p][k])
            if self.index[merged] < 0:
                self.index[merged] = self.index[p]
        return merged

    def _operator(mut self) raises -> Int:
        var w = self._peek_word()
        if w == "readonly" or w == "keyof" or w == "unique":
            _ = self._word()
            return self._operator()
        return self._postfix()

    def _postfix(mut self) raises -> Int:
        var s = self._primary()
        while self._peek() == 91:  # `[`
            self.at += 1
            if not self._eat(93):
                raise Error(DECLINE)
            var a = self.node(S_ARRAY)
            self.kids[a].append(s)
            s = a
        return s

    def _string(mut self) raises -> String:
        var b = self.src.as_bytes()
        var quote = b[self.at]
        var start = self.at + 1
        var i = start
        while i < len(b) and b[i] != quote:
            if b[i] == 92 or b[i] == 10 or b[i] == 13:
                raise Error(DECLINE)
            i += 1
        if i >= len(b):
            raise Error(DECLINE)
        self.at = i + 1
        return String(self.src[byte=start:i])

    def _number(mut self) raises -> String:
        var b = self.src.as_bytes()
        var start = self.at
        while self.at < len(b) and b[self.at] >= 48 and b[self.at] <= 57:
            self.at += 1
        if self.at < len(b) and b[self.at] == 46:
            self.at += 1
            var digits = self.at
            while self.at < len(b) and b[self.at] >= 48 and b[self.at] <= 57:
                self.at += 1
            if self.at == digits:
                raise Error(DECLINE)
        if self.at < len(b) and (_is_ident(b[self.at]) or b[self.at] == 46):
            raise Error(DECLINE)
        var text = String(self.src[byte = start : self.at])
        # A leading zero is octal or an error to oxc.
        if (
            text.byte_length() > 1
            and text.startswith("0")
            and not text.startswith("0.")
        ):
            raise Error(DECLINE)
        return text

    def _primary(mut self) raises -> Int:
        var c = self._peek()
        if c == 40:  # `(`: a parenthesized type is its inner type
            self.at += 1
            var inner = self._union()
            if not self._eat(41):
                raise Error(DECLINE)
            return inner
        if c == 39 or c == 34:
            return self.node(S_LITSTR, self._string())
        if c >= 48 and c <= 57:
            return self.node(S_LITNUM, self._number())
        if c == 123:
            return self._object()
        var w = self._word()
        if w == "":
            raise Error(DECLINE)
        if w == "string":
            return self.node(S_STR)
        if w == "number":
            return self.node(S_NUM)
        if w == "boolean":
            return self.node(S_BOOL)
        if w == "null":
            return self.node(S_NULL)
        if w == "undefined" or w == "void":
            return self.node(S_UNDEF)
        if w == "true" or w == "false":
            return self.node(S_LITBOOL, w)
        if (
            w == "any"
            or w == "unknown"
            or w == "object"
            or w == "never"
            or w == "bigint"
            or w == "symbol"
        ):
            return self.node(S_ANY)
        if (
            w == "typeof"
            or w == "infer"
            or w == "this"
            or w == "new"
            or w == "asserts"
            or w == "abstract"
        ):
            raise Error(DECLINE)
        var qualified = False
        while self._peek() == 46:
            self.at += 1
            if self._word() == "":
                raise Error(DECLINE)
            qualified = True
        var args = List[Int]()
        if self._eat(60):  # `<`
            args.append(self._union())
            while self._eat(44):
                args.append(self._union())
            if not self._eat(62):
                raise Error(DECLINE)
        if qualified:
            return self.node(S_ANY)
        var r = self.node(S_REF, w)
        self.kids[r] = args^
        return r

    def _object(mut self) raises -> Int:
        self.at += 1  # `{`
        var o = self.node(S_OBJECT)
        while True:
            var c = self._peek()
            if c == 125:
                self.at += 1
                return o
            if c == 59 or c == 44:
                self.at += 1
                continue
            if c == 91:  # an index signature `[k: string]: T`
                self.at += 1
                if self._word() == "" or not self._eat(58):
                    raise Error(DECLINE)
                _ = self._union()
                if not self._eat(93) or not self._eat(58):
                    raise Error(DECLINE)
                var value = self._union()
                self.index[o] = value
                continue
            var name = String("")
            var named = True
            if c == 39 or c == 34:
                name = self._string()
            elif c >= 48 and c <= 57:
                _ = self._number()
                named = False
            else:
                name = self._word()
                if name == "":
                    raise Error(DECLINE)
                if name == "readonly":
                    var n = self._peek()
                    if n != 58 and n != 63 and n != 40 and n != 59 and n != 125:
                        var c2 = self._peek()
                        if c2 == 39 or c2 == 34:
                            name = self._string()
                        else:
                            name = self._word()
                            if name == "":
                                raise Error(DECLINE)
            var opt = self._eat(63)
            var n = self._peek()
            if n == 40 or n == 60:  # a method signature
                raise Error(DECLINE)
            var s: Int
            if self._eat(58):
                s = self._union()
            elif n == 59 or n == 44 or n == 125:
                s = self.node(S_ANY)
            else:
                raise Error(DECLINE)
            if named:
                self.kids[o].append(s)
                self.names[o].append(name)
                self.optional[o].append(opt)
