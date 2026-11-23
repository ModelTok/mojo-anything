// The website's English text. It shows no number with a unit or a ratio
// (`scripts/check-doc-numbers.py` checks): counts and sizes live in the Markdown pages, next to
// the log of the run that measured them, and no timing is shown until the Mojo timings are
// measured on a quiet machine.
export const en = {
  meta: {
    title: 'Rewrite your app in Mojo, and prove it still behaves the same',
    description:
      'Rewrite your app in Mojo one piece at a time, checked against a recording of the original at every step. CLIs, servers and libraries in TypeScript/JavaScript, Python, C, Go, Ruby, Java and Kotlin.',
  },
  ui: {
    docs: 'Docs',
    languages: 'Languages',
    realWorld: 'Real code, ported',
    searchButton: 'Search documentation…',
    searchDocs: 'Search the docs',
    searchPlaceholder: 'Search: record, gate, front door…',
    searchQuery: 'Search query',
    searchEmpty: 'Type to search every docs page.',
    searchNone: 'No pages match.',
    openMenu: 'Open menu',
    closeMenu: 'Close menu',
    menu: 'Menu',
    language: 'Language',
    home: 'mojo-anything home',
    github: 'mojo-anything on GitHub',
    onThisPage: 'On this page',
    editPage: 'Edit this page on GitHub',
    previous: 'Previous',
    next: 'Next',
    pager: 'Previous and next page',
    breadcrumb: 'Breadcrumb',
    themeDark: 'Dark',
    themeLight: 'Light',
    themeSystem: 'System',
    theme: 'Theme',
    themeSwitch: 'Switch to',
    copy: 'Copy',
    copied: 'Copied',
    copyInstall: 'Copy the install commands',
    installWith: 'Install with',
    fromClone: 'from a clone',
    npmOnceReleased: 'npm, once released',
    skip: 'Skip to content',
    legal:
      'MIT licensed. Ports and generated code in your repository are yours. An independent project, not affiliated with or endorsed by Modular or the rust-anything project.',
    credits:
      'A fork of [rust-anything](https://github.com/erkamyaman/rust-anything) by Erkam Yaman: the recording, replay, front-door and agent machinery come from it; the bridges, ports and gates were rewritten for Mojo.',
    quickStart: 'Quick start',
    cliReference: 'CLI reference',
    issues: 'Issues',
    status: 'Status',
    privacy: 'Privacy',
  },
  nav: {
    groups: {
      introduction: 'Introduction',
      concepts: 'How it works',
      languages: 'Languages',
      wholeApps: 'Whole apps and packages',
      realWorld: 'Real code, ported',
      reference: 'Reference',
      project: 'Project',
    },
    items: {} as Record<string, string>,
  },
  hero: {
    title1: 'Rewrite your app in Mojo.',
    title2: 'Prove it behaves the same.',
    sub: 'mojo-anything records what your code does, then replays every recorded case against the Mojo port. Your agent writes the Mojo. Nothing ships until the outputs match.',
    cta: 'Read the quick start',
    source: 'Source on GitHub',
    sourceLanguage: 'Source language',
    bridge: 'bridge',
    verified: '{what}, ported to Mojo: every recorded case matches and gate passes',
    wholeApp: '{lang} apps record and replay against the original today, through a Mojo front door.',
    fixtureOnly: '{lang} units bridge through {bridge}; checked on the test fixtures so far.',
  },
  home: {
    installTitle: 'Install',
    installDesc:
      'No release exists yet: build it from a clone, then register the MCP server and the workflow skill with Claude Code, Codex, Cursor, Gemini CLI and OpenCode.',
    installNote:
      'Linux (x64, arm64) and macOS (Apple silicon); on Windows, inside WSL. Every run so far was on x86-64 Linux; macOS has not been run yet ([Status](/docs/project/status)). Mojo comes from pixi, pinned per unit. More in [Install](/docs/introduction/install).',
    agentPrompt: 'Install mojo-anything: run `npm install -g mojo-anything`, then `mojo-anything setup`.',
    agentRestart: 'Tell me when to restart you.',
    loopTitle: 'How a port gets done',
    loopDesc:
      'The original stays the source of truth. mojo-anything does not translate code: it supplies what an agent cannot guess, and a gate that says when a port is done.',
    steps: [
      {
        title: 'Record',
        text: '`record` runs the original on generated edge cases, semantic traps and your own inputs, and saves what it returns or throws.',
      },
      {
        title: 'Port',
        text: '`bridge` generates the Mojo unit and the bindings, so callers keep the original API. You or your agent write `port.mojo`.',
      },
      {
        title: 'Check',
        text: '`diff` replays every recorded case against the Mojo, and nothing ships until they all match and `gate` passes.',
      },
      {
        title: 'Lift',
        text: 'When replay passes with no fallback and every unit passes gate, `app lift` makes it a pure Mojo app. The original is never touched.',
      },
    ],
    vizSameApi: 'same API',
    vizCheck: 'every recorded case',
    vizMatch: 'matches',
    vizGate: 'gate passes',
    vizLift: 'cases answered by the original',
    vizLiftSteps: ['front door: all of them', 'units wired: fewer', 'lifted: none'],
    demoTitle: 'What the recording catches',
    demoDesc:
      'vercel/ms turns `"2 days"` into milliseconds and back. Its Mojo port matched every recorded case, and these are the traps it had to get right. [The run](/docs/real-world/vercel-ms)',
    demoComments: {
      bridge: '# bridge, record, then write port.mojo (or let your agent):',
      check: '# every recorded case must match:',
      traps: '# what the port had to match, caught by recorded cases:',
      trapLines: [
        '/.../i without u folds ASCII only: "1 ſ" is not seconds',
        'Math.round(-2.5) is -2: halves round up',
        '`${n}` prints 1e+21, and 0 for -0',
        'str.length counts UTF-16 units: an emoji is two',
        'errors quote the argument with JSON.stringify',
      ],
    },
    portsTitle: 'Real code, ported to Mojo',
    portsDesc:
      'Each of these was ported to Mojo and checked again by `build`, `diff` and `gate` on a copy of its demo. The case counts and the log of each run are on the linked pages. How fast the ports are is not published yet: the timings wait for a quiet machine.',
    ports: [
      {
        href: '/docs/real-world/vercel-ms',
        kind: 'vercel/ms · TypeScript',
        title: 'Node-API addon and wasm module',
        text: 'Every recorded case matches on both bridges, including the cases captured from its own Jest tests, and `gate` passes.',
      },
      {
        href: "/docs/real-world/overview#a-whole-cli-lifted-to-mojo%3A-cpython's-quopri",
        kind: 'quopri · a whole Python CLI',
        title: 'Lifted to a pure Mojo binary',
        text: '`python3 -m quopri` went through the whole-app loop to one Mojo binary, which passes every recorded CLI case with the original moved away.',
      },
      {
        href: '/docs/real-world/overview',
        kind: 'Go, Ruby, Python, Java, C',
        title: 'Standard libraries and ffmpeg',
        text: "Go's `path`, Ruby's `shellwords`, CPython's `colorsys`, ffmpeg's `rational.c`, and JDK and glibc behaviour behind facades.",
      },
    ],
    langsTitle: 'Languages',
    langsDesc:
      'The language is detected from the repository, and each gets a bridge so the rest of the code calls the Mojo with its API unchanged.',
    verified: 'Bridged',
    wholeApps: 'Whole apps',
    langMeta: {
      typescript: '`mojo-node` (Node-API addon) or `mojo-wasm` (Node 24+)',
      python: '`mojo-py`: a Python extension module built by Mojo',
      c: '`c-abi`: the original names and signatures, and a header',
      cpp: '`c-abi` behind an `extern "C"` shim, and a C++ wrapper with the original signatures',
      go: '`ffi`: cgo calls into a JSON dispatcher',
      ruby: '`ffi`: Fiddle calls into a JSON dispatcher',
      java: '`mojo-jvm`: Foreign Function & Memory API, Java 22+',
      kotlin: '`mojo-jvm`, with wrapper classes named for the JVM owners',
      php: 'whole-app record, replay and the Mojo front door',
      csharp: 'whole-app record, replay and the Mojo front door',
    } as Record<string, string>,
  },
}

export type Messages = typeof en
