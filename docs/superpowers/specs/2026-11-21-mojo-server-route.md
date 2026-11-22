# The Mojo server route (M6 Task 7)

Decision: the HTTP front door is a Mojo server on the C library's sockets, reached through
`external_call` (route A). Python's `http.server` and `http.client` through interop (route B)
passed the same cases but is slower, cannot call Mojo glue, and leaves the original running when
it is stopped.

## What was compared

Both spikes are throwaway proxies in `/tmp/m6server`, outside the repository. Each starts the
original on a free port of its own (`PORT`), forwards every request to it, and passes its answer
through, logging one fallback line per request to `$MOJO_ANYTHING_FALLBACK_LOG`.

- **A**: `http.mojo` (sockets, request and response parsing, keep-alive, chunked bodies) and
  `original.mojo` (fork and execvp as in the CLI front door, `PR_SET_PDEATHSIG`) with a
  `main.mojo` accept loop; `socket`, `setsockopt` (`SO_REUSEADDR`, `TCP_NODELAY` on every
  accepted and outgoing socket), `bind`, `listen`, `accept`, `connect`, `getsockname`, `recv`,
  `send` with `MSG_NOSIGNAL`, `poll`, `close`. Built with `mojo build --Werror`.
- **B**: a Mojo binary whose `main` runs a Python proxy with `builtins.exec`:
  `http.server.HTTPServer` with `protocol_version = "HTTP/1.1"`, `TCP_NODELAY` set, a handler
  that decodes chunked request bodies and forwards with `http.client`, and `subprocess.Popen`
  for the original.

The original is the Python server of `tests/http.rs` (`tests/fixtures/http/python`), recorded with
`app record --http -- python3 server.py`: 42 cases (6 examples, 36 traps).

## Results

Measured 2026-11-22 on an AMD Ryzen 9 3900X (12 cores, 24 threads), WSL 2 Ubuntu 24.04, Mojo
1.2.0, Python 3.12.3; load average 0.16 to 0.45 during the runs (a quiet machine). Each timing is
the better of two passes of 2000 `GET /hello`, the whole script run twice; the client is Python
(`socket` for one connection per request, `http.client` for one keep-alive connection), so the
client's own cost is in every number.

| | replay (`--build`) | keep-alive, chunked POST, HEAD | new connection each | one keep-alive connection | SIGTERM ends the original |
| --- | --- | --- | --- | --- | --- |
| original alone | 42/42 | (no chunked bodies) | 3435, 3488 req/s (291, 287 us) | 3430, 3514 req/s | - |
| A: Mojo on libc sockets | 42/42, fallback 42/42 | pass | 2573, 2729 req/s (389, 366 us) | 2609, 2663 req/s (383, 375 us) | yes |
| B: Python through interop | 42/42, fallback 42/42 | pass | 1612, 1571 req/s (620, 637 us) | 1805, 1815 req/s (554, 551 us) | no |

Time in process for A: the proxy call (read the request, forward it, read the original's answer)
took 230, 226 and 223 us on average over each run of 4000 requests, measured with
`perf_counter_ns` around the call. Nearly all of it is the original answering over its own
connection (290 us a request from the outside), so A adds about 80 us a request, the hop to the
original included. B's handler was not timed in process; it is Python code, and its HTTP numbers
are about 250 us a request slower than A's.

## What each could not do

- **A**: one request at a time. An idle keep-alive connection is closed as soon as another client
  is waiting (`poll` on the connection and the listener), or after 5 s, so it never holds the
  next client up; a slow request still does. `open` cannot be declared through `external_call`
  (the stdlib declares it with another signature), so the original's stdin is `/dev/null` through
  glibc's `open64`. `PR_SET_PDEATHSIG` is Linux only: on macOS a front door killed with SIGKILL
  would leave the original running.
- **B**: Mojo glue cannot answer a route: `http.server` calls Python methods, and a Mojo binary
  cannot hand Python a Mojo function without building a Python extension module, so every unit
  would have to be reached through one. The front door would depend on CPython, and a lifted
  server would still need it. SIGTERM ended the proxy without its `finally`, and the original kept
  running (seen in both runs).

## Consequences

- `src/mojo/http.mojo` (template) holds the HTTP code of spike A; `src/mojo/original_http.mojo`
  starts the original and proxies; the generated `main.mojo` runs the accept loop and hands each
  request to `units.handle`.
- The original's port reaches `original.proxy` through `$MOJO_ANYTHING_ORIGINAL_PORT`, set by the
  front door after the original listens (Mojo 1.2 has no globals), so glue that declines a request
  calls `original.proxy(req)` with nothing else.
- The numbers above are for the decision only; any number published from here is measured again.
