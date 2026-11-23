# C ABI probe: exported functions with the C names and signatures `probe.c` declares.

from std.memory import Pointer


@fieldwise_init
struct Pair(Copyable, Movable, TrivialRegisterPassable):
    var a: Int32
    var b: Float64


@export
def probe_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b


@export
def probe_len(s: Optional[Pointer[Int8, ImmutAnyOrigin]]) abi("C") -> UInt:
    if not s:
        return UInt.MAX
    var p = s.value()
    var n = 0
    while p[unsafe_offset=n] != 0:
        n += 1
    return UInt(n)


@export
def probe_fill(buf: Pointer[UInt8, MutAnyOrigin], n: UInt) abi("C"):
    for i in range(Int(n)):
        buf[unsafe_offset=i] = UInt8(i)


@export
def probe_swap(p: Pair) abi("C") -> Pair:
    return Pair(p.a * 2, p.b * 2)


@export
def probe_end(
    s: Pointer[Int8, ImmutAnyOrigin],
    end: Pointer[Pointer[Int8, ImmutAnyOrigin], MutAnyOrigin],
) abi("C"):
    end[] = s.unsafe_offset(2)
