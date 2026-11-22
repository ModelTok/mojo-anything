---
title: "What is mojo-anything"
description: "A tool that records what your code does and checks a Mojo rewrite against that recording, one piece at a time."
source: README.md
---

# What is mojo-anything

mojo-anything rewrites an app in Mojo one piece at a time and proves each piece still behaves
like the original. It records what your Node.js (TypeScript/JavaScript), Python, C, Go, Ruby, Java
or Kotlin code does today; your coding agent (or you) writes the Mojo; and every piece is
replayed against the recording before it moves on. It doesn't translate code: it proves the
rewrite.

Each port is called from the original language through a bridge mojo-anything generates (a
Node-API addon or a wasm module, a Python extension, a C ABI library, a JSON dispatcher for Go and
Ruby, Java's Foreign Function & Memory API), so the rest of the code keeps calling it with its
API unchanged. mojo-anything decides what to move, in which order, and when a port is done. It
can only catch what the recording covers: see [What it can't catch](/docs/concepts/limits).

It runs on Linux and macOS (on Windows, inside WSL). Every test and every run so far was on
x86-64 Linux; macOS has not been run yet ([Status](/docs/project/status#known-gaps)). No release
exists yet: [build it from a clone](/docs/introduction/install#from-a-clone).

## Real code, ported to Mojo

<!-- include: README.md#real-code-ported-to-mojo -->

## Credits

<!-- include: README.md#credits -->
