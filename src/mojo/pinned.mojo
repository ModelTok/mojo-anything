# The clock and random numbers the original saw while mojo-anything recorded it.
#
# Written by `mojo-anything record --pin-clock`. Import it in `port.mojo` (`from pinned import
# now_ms, random`), then call `now_ms()` where the original reads the clock and `random()` where
# it draws a random number. While `record`, `diff`, `fuzz` and `gate` run, the clock is fixed at
# `MOJO_ANYTHING_NOW_MS` (time zone UTC) and the numbers come from mulberry32 seeded with
# `MOJO_ANYTHING_SEED`, restarted at every case (the drivers change `MOJO_ANYTHING_CASE` between
# cases). Without those variables (in production) the real clock and a clock seed are used.
#
# Mojo has no global variables, so the generator keeps its state in the environment variable
# `MOJO_ANYTHING_PIN_STATE` (`<case>:<state>`).

from std.ffi import external_call
from std.os import getenv, setenv

comptime _STATE = "MOJO_ANYTHING_PIN_STATE"


def _var(name: String) -> Optional[Int]:
    var text = getenv(name)
    if text.byte_length() == 0:
        return None
    try:
        return Int(text)
    except:
        return None


def _real_secs() -> Int:
    # SAFETY: `time(NULL)` reads the clock and writes through no pointer.
    return Int(external_call["time", Int64](Int64(0)))


def now_ms() -> Float64:
    """Milliseconds since the Unix epoch, like JS `Date.now()`."""
    var pinned = _var("MOJO_ANYTHING_NOW_MS")
    if pinned:
        return Float64(pinned.value())
    return Float64(_real_secs()) * 1000.0


def now_secs() -> Float64:
    """Seconds since the Unix epoch, like Python `time.time()`."""
    return now_ms() / 1000.0


def next_u32() -> UInt32:
    """The next 32 random bits: mulberry32, as the drivers run it."""
    var seed = _var("MOJO_ANYTHING_SEED")
    var this_case = getenv("MOJO_ANYTHING_CASE")
    var saved = getenv(_STATE)
    var state: UInt32
    var split = -1
    var b = saved.as_bytes()
    for i in range(len(b)):
        if b[i] == 58:
            split = i
    # The same case goes on from its saved state; a new one restarts from the seed.
    if split >= 0 and String(saved[byte=0:split]) == this_case:
        try:
            state = UInt32(Int(String(saved[byte = split + 1 : len(b)])))
        except:
            state = UInt32(seed.value()) if seed else UInt32(_real_secs())
    elif seed:
        state = UInt32(seed.value())
    else:
        state = UInt32(_real_secs() & 0xFFFFFFFF)
    state = state + 0x6D2B79F5
    var t = (state ^ (state >> 15)) * (state | 1)
    t = t ^ (t + (t ^ (t >> 7)) * (t | 61))
    _ = setenv(_STATE, this_case + ":" + String(state))
    return t ^ (t >> 14)


def random() -> Float64:
    """JS `Math.random()` and Python `random.random()`: `next_u32() / 2^32`."""
    return Float64(next_u32()) / 4294967296.0


def getrandbits(k: Int) raises -> UInt64:
    """Python's `random.getrandbits(k)`, for `k` up to 64."""
    if k < 0 or k > 64:
        var e = Error("getrandbits takes at most 64 bits here")
        raise e^
    if k == 0:
        return 0
    if k <= 32:
        return UInt64(next_u32() >> UInt32(32 - k))
    var low = UInt64(next_u32())
    return low | (UInt64(next_u32() >> UInt32(64 - k)) << 32)


def randbelow(n: UInt64) raises -> UInt64:
    """CPython's `Random._randbelow(n)`: an integer in `[0, n)`."""
    if n == 0:
        return 0
    var k = 0
    var m = n
    while m > 0:
        k += 1
        m >>= 1
    while True:
        var r = getrandbits(k)
        if r < n:
            return r
