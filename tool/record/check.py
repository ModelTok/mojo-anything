#!/usr/bin/env python3
"""Check the recording in mojo/app-cases/ against tool/record/inputs.jsonl.

- every input line became a case (none timed out, none lost to a name clash);
- every subcommand has its `--help` case;
- the cases of commands that write files have non-empty `*.out` folders (docs/pitfalls.md);
- the chunk outcomes list no unstable or timed-out case.
Prints the counts; exits 1 on any problem.
"""

import glob
import json
import os
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CASES = os.path.join(REPO, "mojo", "app-cases")
WRITERS = ["bridge-", "map-write-", "setup-claude", "setup-codex", "setup-cursor", "setup-gemini",
           "setup-opencode", "app-record-cli", "app-replay-cli", "app-front-door-no-check",
           "shadow-", "refresh-"]
NOT_WRITERS = ("-dry-run", "-remove-nothing")


def main():
    inputs = [json.loads(l) for l in open(os.path.join(REPO, "tool", "record", "inputs.jsonl")) if l.strip()]
    names = {c["name"] for c in inputs}
    tomls = {os.path.basename(p)[:-5] for p in glob.glob(os.path.join(CASES, "*.toml"))}
    problems = []
    missing = sorted(names - tomls)
    extra = sorted(tomls - names)
    if missing:
        problems.append(f"{len(missing)} inputs have no case: {missing[:10]}")
    if extra:
        problems.append(f"{len(extra)} cases have no input: {extra[:10]}")
    for sub in ["analyze", "bridge", "refresh", "record", "build", "diff", "bench", "fuzz",
                "profile", "shadow", "gate", "package", "app", "mcp", "setup", "map", "doctor"]:
        if f"{sub}-help" not in tomls:
            problems.append(f"no --help case for {sub}")
    for sub in ["record", "replay", "front-door", "wire", "lift"]:
        if f"app-{sub}-help" not in tomls:
            problems.append(f"no --help case for app {sub}")
    writers = 0
    for name in sorted(tomls):
        if (any(name.startswith(w) for w in WRITERS) and not name.endswith(NOT_WRITERS)
                and "-help" not in name and "-error-" not in name):
            out = os.path.join(CASES, name + ".out")
            status = open(os.path.join(CASES, name + ".toml")).read()
            if "status.code = 0" not in status:
                continue
            writers += 1
            if not os.path.isdir(out) or not any(os.scandir(out)):
                problems.append(f"{name}: exits 0 but its .out folder is empty")
    unstable, timed_out, noisy = [], [], []
    for f in sorted(glob.glob(os.path.join(REPO, "tool", "record", "chunks", "inputs-*.json"))):
        o = json.load(open(f))
        unstable += o["unstable"]
        timed_out += o["timed_out"]
        noisy += o["noisy"]
    if unstable:
        problems.append(f"unstable: {unstable}")
    if timed_out:
        problems.append(f"timed out: {timed_out}")
    codes = {}
    for name in tomls:
        text = open(os.path.join(CASES, name + ".toml")).read()
        code = next((l.split("=")[1].strip() for l in text.splitlines() if l.startswith("status.code")), "interrupted")
        codes[code] = codes.get(code, 0) + 1
    print(f"inputs {len(inputs)}, cases {len(tomls)}, file-writing cases that exit 0: {writers}")
    print(f"exit codes: {dict(sorted(codes.items()))}")
    print(f"noisy: {len(noisy)} {noisy[:20]}")
    for p in problems:
        print("PROBLEM:", p)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
