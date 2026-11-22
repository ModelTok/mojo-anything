// English only: translations stay removed until the English text settles. A locale added here
// later needs its `pages/<code>/` folder and `lib/messages/<code>.json`.
export const LOCALES: readonly { code: string; name: string; lang: string; rtl?: boolean }[] = [
  { code: 'en', name: 'English', lang: 'en' },
]

export type Locale = (typeof LOCALES)[number]['code']
export const DEFAULT_LOCALE: Locale = 'en'
const CODES = new Set<string>(LOCALES.map((l) => l.code))

export function localeOf(path: string): Locale {
  const first = path.split('/')[1] ?? ''
  return (CODES.has(first) && first !== DEFAULT_LOCALE ? first : DEFAULT_LOCALE) as Locale
}

export function stripLocale(path: string): string {
  const loc = localeOf(path)
  if (loc === DEFAULT_LOCALE) return path
  const rest = path.slice(loc.length + 1)
  return rest === '' ? '/' : rest
}

export function withLocale(path: string, locale: string): string {
  if (locale === DEFAULT_LOCALE || !path.startsWith('/')) return path
  return path === '/' ? `/${locale}` : `/${locale}${path}`
}

export function localeInfo(locale: string) {
  return LOCALES.find((l) => l.code === locale) ?? LOCALES[0]
}

export function fill(template: string, vars: Record<string, string>): string {
  return template.replace(/\{(\w+)\}/g, (m, k) => vars[k] ?? m)
}
