# Security policy

## Supported versions

Security fixes go into the latest release. No release has been published yet; once 0.1.0 is out,
upgrade with `npm install -g mojo-anything@latest` (or the latest release archive) before
reporting, in case it is already fixed.

| Version | Supported |
| --- | --- |
| Latest minor (0.x) | Yes |
| Older | No |

## Reporting a vulnerability

Please report it privately, not in a public issue: use
[Report a vulnerability](https://github.com/ModelTok/mojo-anything/security/advisories/new) on
the repository's Security tab.

Include what you found, how to reproduce it, which version and platform you used, and what an
attacker could do with it. You'll get a reply within a few days, and you'll hear when a fix is out.
If you'd like credit in the release notes, say how you want to be named.

## What counts

mojo-anything runs your code on purpose. `record`, `diff`, `app record` and `app replay` execute
the original app and the Mojo port to compare them, so running them on an untrusted repository is
like running that repository yourself. That alone is not a vulnerability.

These are in scope:

- Code that mojo-anything generates (bindings, dispatchers, drivers, front doors) with
  memory-unsafe or undefined behaviour that the port didn't ask for.
- Reading or writing files outside the project, the unit and the system temp folder.
- A crafted recording (`cases.jsonl`, `mojo/app-cases/`) that makes mojo-anything run commands it
  wasn't told to run.
- The release pipeline: the published binaries or the npm launcher not matching the tagged
  source, or the launcher running a download whose checksum does not match `SHA256SUMS`.
- The MCP server doing more than the tool call asked for.

## Disclosure

Once a fix is released, the advisory is published with credit to the reporter, unless they prefer
otherwise.
