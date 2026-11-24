import { existsSync, readFileSync, statSync } from 'node:fs'
import { join, posix, resolve } from 'node:path'

export const WEBSITE_ROOT = resolve(import.meta.dirname, '..')
export const REPO_ROOT = resolve(WEBSITE_ROOT, '..')
const REPO_URL = 'https://github.com/ModelTok/mojo-anything'
const INCLUDE_RE = /^<!--\s*include:\s*(\S+)\s*-->\s*$/gm

// A link in an included file to a section the website shows goes to that page; anything else
// (rust-anything's history in docs/real-world.md, logs, demos, source files) goes to GitHub.
// A page path ending in `#` takes the section's anchor as the website spells it.
const LINK_MAP = {
  'README.md': '/',
  'README.md#quick-start': '/docs/introduction/quick-start',
  'README.md#works-with': '/docs/introduction/quick-start#',
  'README.md#languages': '/docs/languages/overview',
  'README.md#real-code-ported-to-mojo': '/docs/introduction/what-is-mojo-anything#',
  'docs/install.md': '/docs/introduction/install',
  'docs/install.md#install': '/docs/introduction/install',
  'docs/install.md#from-a-clone': '/docs/introduction/install#',
  'docs/install.md#agents': '/docs/introduction/install#',
  'docs/how-it-works.md': '/docs/concepts/the-loop',
  'docs/how-it-works.md#how-it-works': '/docs/concepts/the-loop',
  'docs/how-it-works.md#the-loop': '/docs/concepts/the-loop',
  'docs/how-it-works.md#hot-paths-batches': '/docs/concepts/batches',
  'docs/how-it-works.md#what-bridge-decides': '/docs/concepts/bridge',
  'docs/how-it-works.md#what-analyze-looks-at': '/docs/concepts/analyze',
  'docs/how-it-works.md#what-it-cant-catch': '/docs/concepts/limits',
  'docs/how-it-works.md#what-a-real-port-takes': '/docs/concepts/real-port',
  'docs/how-it-works.md#keep-the-originals-shape': '/docs/concepts/real-port',
  'docs/how-it-works.md#keep-up-with-the-original': '/docs/concepts/keep-up',
  'docs/whole-apps.md': '/docs/whole-apps/overview',
  'docs/whole-apps.md#port-a-whole-app': '/docs/whole-apps/overview',
  'docs/whole-apps.md#side-effects-email-webhooks-and-databases': '/docs/whole-apps/overview#',
  'docs/whole-apps.md#servers': '/docs/whole-apps/overview#',
  'docs/whole-apps.md#libraries': '/docs/whole-apps/overview#',
  'docs/packaging.md': '/docs/whole-apps/packaging',
  'docs/real-world-languages.md': '/docs/real-world/overview',
  'docs/real-world-languages.md#a-whole-cli-lifted-to-mojo-cpythons-quopri': '/docs/real-world/overview#',
  'docs/real-world.md#vercelms-on-mojo': '/docs/real-world/vercel-ms',
  'docs/examples.md': '/docs/real-world/examples',
  'docs/tools.md': '/docs/reference/mcp-tools',
  'docs/STATUS.md': '/docs/project/status',
  'docs/STATUS.md#known-gaps': '/docs/project/status#',
  'docs/faq.md': '/docs/project/faq',
  'docs/faq.md#faq': '/docs/project/faq',
  'CONTRIBUTING.md': '/docs/project/contributing',
  'docs/privacy.md': '/docs/project/privacy',
}

export function githubSlug(text) {
  return text
    .trim()
    .toLowerCase()
    .replace(/<[^>]+>/g, '')
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    .replace(/\s/g, '-')
}

function headingOf(line) {
  const m = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line)
  return m ? { level: m[1].length, text: m[2] } : null
}

function scanLines(markdown) {
  const out = []
  let fence = null
  for (const line of markdown.split('\n')) {
    const f = /^\s{0,3}(`{3,}|~{3,})/.exec(line)
    if (f) {
      if (!fence) fence = f[1]
      else if (line.trim().startsWith(fence)) fence = null
      out.push({ line, heading: null })
      continue
    }
    out.push({ line, heading: fence ? null : headingOf(line) })
  }
  return out
}

function extract(markdown, anchor) {
  const lines = scanLines(markdown)
  if (!anchor) {
    const h1 = lines.findIndex((l) => l.heading?.level === 1)
    return h1 === -1 ? lines : lines.slice(h1 + 1)
  }
  const start = lines.findIndex((l) => l.heading && githubSlug(l.heading.text) === anchor)
  if (start === -1) throw new Error(`md-include: no heading #${anchor}`)
  const level = lines[start].heading.level
  let end = lines.findIndex((l, i) => i > start && l.heading && l.heading.level <= level)
  if (end === -1) end = lines.length
  return lines.slice(start + 1, end)
}

function shiftHeadings(lines) {
  const levels = lines.filter((l) => l.heading).map((l) => l.heading.level)
  if (!levels.length) return lines.map((l) => l.line)
  const delta = 2 - Math.min(...levels)
  return lines.map((l) =>
    l.heading && delta !== 0
      ? '#'.repeat(Math.min(6, l.heading.level + delta)) + ' ' + l.heading.text
      : l.line,
  )
}

// The id the website gives the heading of `repoPath` whose GitHub anchor is `hash`: the
// heading's text without markup, lower case, spaces as `-`, percent-encoded (as
// `anchorSlug(plainText(...))` in pages.mjs and @void/md's heading ids spell it).
function siteAnchor(repoPath, hash) {
  const source = readFileSync(join(REPO_ROOT, repoPath), 'utf8').replace(/\r\n/g, '\n')
  const heading = scanLines(source).find((l) => l.heading && githubSlug(l.heading.text) === hash)
  if (!heading) throw new Error(`md-include: ${repoPath} has no heading #${hash}`)
  const text = heading.heading.text
    .replace(/<[^>]+>/g, ' ')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/[|`*]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return encodeURIComponent(text.toLowerCase().replace(/\s+/g, '-'))
}

export function rewriteTarget(target, sourceFile, image = false) {
  if (/^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith('//') || target.startsWith('/')) {
    return target
  }
  const [p, hash] = target.split('#')
  let repoPath = p ? posix.normalize(posix.join(posix.dirname(sourceFile), p)) : sourceFile
  repoPath = repoPath.replace(/^\.\//, '').replace(/\/$/, '')
  if (repoPath.startsWith('..')) return target
  if (!image) {
    const key = hash ? `${repoPath}#${hash}` : repoPath
    const page = LINK_MAP[key]
    if (page) return page.endsWith('#') ? page + siteAnchor(repoPath, hash) : page
    if (!hash && LINK_MAP[repoPath]) return LINK_MAP[repoPath]
    if (hash && sourceFile === repoPath && !p) return `#${siteAnchor(repoPath, hash)}`
  }
  if (image) return `https://raw.githubusercontent.com/ModelTok/mojo-anything/main/${repoPath}`
  const abs = join(REPO_ROOT, repoPath)
  const kind = existsSync(abs) && statSync(abs).isDirectory() ? 'tree' : 'blob'
  return `${REPO_URL}/${kind}/main/${repoPath}${hash ? '#' + hash : ''}`
}

function rewriteLinks(markdown, sourceFile) {
  return markdown
    .replace(/(!?)\[([^\]]*)\]\(([^)\s]+)((?:\s+"[^"]*")?)\)/g, (_, bang, text, target, title) =>
      `${bang}[${text}](${rewriteTarget(target, sourceFile, bang === '!')}${title})`,
    )
    .replace(/\b(href|src)="([^"]+)"/g, (_, attr, target) =>
      `${attr}="${rewriteTarget(target, sourceFile, attr === 'src')}"`,
    )
}

function readCliHelp() {
  return JSON.parse(readFileSync(join(WEBSITE_ROOT, 'content', 'cli-help.json'), 'utf8'))
}

export function renderCliHelp() {
  const { version, commands } = readCliHelp()
  const parts = [
    `Generated from \`mojo-anything --help\` and each subcommand's \`--help\` (mojo-anything ${version}); \`tests/tools.rs\` checks it is current.`,
  ]
  for (const { command, help } of commands) {
    const title = command ? `mojo-anything ${command}` : 'mojo-anything'
    parts.push(`## \`${title}\``, '```text\n' + help.trimEnd() + '\n```')
  }
  return parts.join('\n\n')
}

export function includeFile(spec) {
  if (spec === 'cli-help') return renderCliHelp()
  const [file, anchor] = spec.split('#')
  const source = readFileSync(join(REPO_ROOT, file), 'utf8').replace(/\r\n/g, '\n')
  const body = shiftHeadings(extract(source, anchor)).join('\n').trim()
  return rewriteLinks(body, file)
}

export function includedFiles(markdown) {
  return [...markdown.matchAll(INCLUDE_RE)]
    .map((m) => m[1])
    .filter((s) => s !== 'cli-help')
    .map((s) => join(REPO_ROOT, s.split('#')[0]))
}

export function expandIncludes(markdown) {
  return markdown.replace(INCLUDE_RE, (_, spec) => includeFile(spec))
}

const escapeHtml = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

export function transformTabs(markdown) {
  let n = 0
  return markdown.replace(/^::: tabs\n([\s\S]*?)\n:::$/gm, (_, inner) => {
    const id = `tabs-${++n}`
    const panes = inner.split(/^== (.+)$/m).slice(1)
    const names = panes.filter((_, i) => i % 2 === 0).map((t) => t.trim())
    const bodies = panes.filter((_, i) => i % 2 === 1)
    const controls = names
      .map((name, i) => {
        const key = `${id}-${i}`
        return `<input type="radio" class="tabs-input" name="${id}" id="${key}"${i === 0 ? ' checked' : ''}><label for="${key}">${escapeHtml(name)}</label>`
      })
      .join('')
    const panels = bodies.map((b) => `<div class="tabs-panel">\n\n${b.trim()}\n\n</div>`).join('\n')
    return `<div class="tabs">${controls}\n${panels}\n</div>`
  })
}

export function markCodeFilenames(markdown) {
  return markdown.replace(
    /^\*\*([^*\n]+)\*\*\n(?=(`{3,}|~{3,}))/gm,
    (_, name) => `<div class="code-filename">${escapeHtml(name.trim())}</div>\n\n`,
  )
}

export function mdIncludePlugin() {
  return {
    name: 'mojo-anything-md-include',
    enforce: 'pre',
    transform(code, id) {
      if (!id.endsWith('.md')) return
      INCLUDE_RE.lastIndex = 0
      for (const f of includedFiles(code)) this.addWatchFile(f)
      const loc = /\/pages\/([a-z]{2}(?:-[a-z]{2})?)\//.exec(id.replace(/\\/g, '/'))?.[1]
      let out = markCodeFilenames(transformTabs(expandIncludes(code)))
      if (loc && loc !== 'en') {
        out = out
          .replace(/\]\(\/docs\//g, `](/${loc}/docs/`)
          .replace(/href="\/docs\//g, `href="/${loc}/docs/`)
      }
      return out === code ? undefined : { code: out, map: null }
    },
  }
}
