import { messages, withLocale } from './i18n'

export interface NavItem {
  title: string
  path: string
}

export interface NavGroup {
  key: string
  title: string
  items: NavItem[]
}

export const docsNav: NavGroup[] = [
  {
    key: 'introduction',
    title: 'Introduction',
    items: [
      { title: 'What is mojo-anything', path: '/docs/introduction/what-is-mojo-anything' },
      { title: 'Quick start', path: '/docs/introduction/quick-start' },
      { title: 'Install', path: '/docs/introduction/install' },
    ],
  },
  {
    key: 'concepts',
    title: 'How it works',
    items: [
      { title: 'The loop', path: '/docs/concepts/the-loop' },
      { title: 'What analyze looks at', path: '/docs/concepts/analyze' },
      { title: 'What bridge decides', path: '/docs/concepts/bridge' },
      { title: 'Batches', path: '/docs/concepts/batches' },
      { title: "What it can't catch", path: '/docs/concepts/limits' },
      { title: 'What a real port takes', path: '/docs/concepts/real-port' },
      { title: 'Keep up with the original', path: '/docs/concepts/keep-up' },
    ],
  },
  {
    key: 'languages',
    title: 'Languages',
    items: [{ title: 'Languages and bridges', path: '/docs/languages/overview' }],
  },
  {
    key: 'wholeApps',
    title: 'Whole apps and packages',
    items: [
      { title: 'Port a whole app', path: '/docs/whole-apps/overview' },
      { title: 'Ship a package', path: '/docs/whole-apps/packaging' },
    ],
  },
  {
    key: 'realWorld',
    title: 'Real code, ported',
    items: [
      { title: 'Six languages', path: '/docs/real-world/overview' },
      { title: 'vercel/ms', path: '/docs/real-world/vercel-ms' },
      { title: 'Examples', path: '/docs/real-world/examples' },
    ],
  },
  {
    key: 'reference',
    title: 'Reference',
    items: [
      { title: 'CLI', path: '/docs/reference/cli' },
      { title: 'MCP tools', path: '/docs/reference/mcp-tools' },
    ],
  },
  {
    key: 'project',
    title: 'Project',
    items: [
      { title: 'Status', path: '/docs/project/status' },
      { title: 'FAQ', path: '/docs/project/faq' },
      { title: 'Contributing', path: '/docs/project/contributing' },
      { title: 'Privacy', path: '/docs/project/privacy' },
    ],
  },
]

export const allDocs: NavItem[] = docsNav.flatMap((g) => g.items)

export function groupOf(path: string): NavGroup | undefined {
  return docsNav.find((g) => g.items.some((i) => i.path === path))
}

export function pagerFor(path: string): { prev?: NavItem; next?: NavItem } {
  const i = allDocs.findIndex((d) => d.path === path)
  if (i === -1) return {}
  return { prev: allDocs[i - 1], next: allDocs[i + 1] }
}

export function publicPath(path: string): string {
  const p = path.replace(/\/+$/, '').replace(/^\/en(?=\/|$)/, '')
  return p === '' ? '/' : p
}

export function localizedNav(locale: string): NavGroup[] {
  const m = messages(locale).nav
  return docsNav.map((g) => ({
    key: g.key,
    title: (m.groups as Record<string, string>)[g.key] ?? g.title,
    items: g.items.map((i) => ({ title: m.items[i.path] ?? i.title, path: withLocale(i.path, locale) })),
  }))
}
