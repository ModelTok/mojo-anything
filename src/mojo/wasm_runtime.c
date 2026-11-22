/* The runtime of a Mojo port compiled to WebAssembly by mojo-anything (`--kind wasm`): the
   symbols Mojo's standard library leaves undefined, for a freestanding wasm64 module.

   The Mojo code is compiled for x86-64 and its LLVM IR retargeted to wasm64, so `Int`,
   pointers and `size_t` are all 64 bits, as in a native build.

   One heap serves Mojo (`KGEN_CompilerRT_AlignedAlloc`), C's `malloc` and the host
   (`mw_alloc`): a bump allocator that only grows, so nothing it hands out can overlap. The
   generated `index.cjs` calls `mw_heap_reset` after every call, once it has read the answer:
   Mojo has no global variables, so no Mojo value outlives a call. */

typedef unsigned long long u64;
typedef __SIZE_TYPE__ usize;
typedef unsigned __int128 u128;

extern unsigned char __heap_base;

static usize heap_start = 0;
static usize heap_top = 0;

__attribute__((import_module("env"), import_name("mw_write")))
extern void mw_host_write(u64 fd, u64 ptr, u64 len);

static void heap_init(void) {
  if (!heap_start) {
    heap_start = (usize)&__heap_base;
    heap_top = heap_start;
  }
}

void *KGEN_CompilerRT_AlignedAlloc(usize align, usize size) {
  heap_init();
  usize a = align < 16 ? 16 : align;
  usize p = (heap_top + (a - 1)) & ~(a - 1);
  if (p < heap_top || p + size < p) return 0;
  usize end = p + size;
  usize have = (usize)__builtin_wasm_memory_size(0) * 65536u;
  if (end > have) {
    usize pages = (end - have + 65535u) / 65536u;
    if (__builtin_wasm_memory_grow(0, pages) == (usize)-1) return 0;
  }
  heap_top = end;
  return (void *)p;
}

void KGEN_CompilerRT_AlignedFree(void *p) { (void)p; }

void *malloc(usize n) { return KGEN_CompilerRT_AlignedAlloc(16, n); }
void free(void *p) { KGEN_CompilerRT_AlignedFree(p); }

/* The host's side of the heap: buffers for the arguments, and the reset after each call. */
__attribute__((visibility("default"))) usize mw_alloc(usize size, usize align) {
  return (usize)KGEN_CompilerRT_AlignedAlloc(align ? align : 16, size);
}
__attribute__((visibility("default"))) usize mw_heap_used(void) {
  heap_init();
  return heap_top - heap_start;
}
__attribute__((visibility("default"))) void mw_heap_reset(void) {
  heap_init();
  heap_top = heap_start;
}

/* A raised Mojo `Error` asks for a stack trace; a wasm module has none to give. */
long KGEN_CompilerRT_GetStackTrace(void *frames, long max) {
  (void)frames;
  (void)max;
  return 0;
}

/* `print` and the stdio veneer behind it: bytes go to the host's `env.mw_write`. */
long write(int fd, const void *buf, long n) {
  mw_host_write((u64)fd, (u64)(usize)buf, (u64)n);
  return n;
}
int dup(int fd) { return fd; }
long fdopen(int fd, const char *mode) {
  (void)mode;
  return fd;
}
int fflush(long f) {
  (void)f;
  return 0;
}
int fclose(long f) {
  (void)f;
  return 0;
}
int KGEN_CompilerRT_fprintf(long f, const char *fmt, ...) {
  (void)f;
  (void)fmt;
  return 0;
}

/* The C library calls the compiled Mojo code makes. The memory ones lower to the bulk-memory
   instructions (memory.copy, memory.fill), so they never call themselves. */
usize strlen(const char *s) {
  usize n = 0;
  while (s[n]) n++;
  return n;
}
void *memcpy(void *d, const void *s, usize n) {
  __builtin_memmove(d, s, n);
  return d;
}
void *memmove(void *d, const void *s, usize n) {
  __builtin_memmove(d, s, n);
  return d;
}
void *memset(void *d, int c, usize n) {
  __builtin_memset(d, c, n);
  return d;
}
int memcmp(const void *a, const void *b, usize n) {
  const unsigned char *x = a, *y = b;
  for (usize i = 0; i < n; i++)
    if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
  return 0;
}

/* 128-bit arithmetic (EmberJson's number reader and writer), written with 64-bit halves so
   that none of them compiles to a call to itself. */
u128 __multi3(u128 a, u128 b) {
  u64 al = (u64)a, ah = (u64)(a >> 64), bl = (u64)b, bh = (u64)(b >> 64);
  u64 a0 = al & 0xffffffffu, a1 = al >> 32, b0 = bl & 0xffffffffu, b1 = bl >> 32;
  u64 p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  u64 mid = (p00 >> 32) + (p01 & 0xffffffffu) + (p10 & 0xffffffffu);
  u64 lo = (p00 & 0xffffffffu) | (mid << 32);
  u64 hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32) + al * bh + ah * bl;
  return ((u128)hi << 64) | lo;
}
u128 __ashlti3(u128 a, int b) {
  u64 lo = (u64)a, hi = (u64)(a >> 64);
  if (b == 0) return a;
  if (b >= 64) {
    hi = lo << (b - 64);
    lo = 0;
  } else {
    hi = (hi << b) | (lo >> (64 - b));
    lo <<= b;
  }
  return ((u128)hi << 64) | lo;
}
u128 __lshrti3(u128 a, int b) {
  u64 lo = (u64)a, hi = (u64)(a >> 64);
  if (b == 0) return a;
  if (b >= 64) {
    lo = hi >> (b - 64);
    hi = 0;
  } else {
    lo = (lo >> b) | (hi << (64 - b));
    hi >>= b;
  }
  return ((u128)hi << 64) | lo;
}
