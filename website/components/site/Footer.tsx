import Logo from '../Logo'
import Rich from '../Rich'
import { REPO_URL } from '../../lib/site'
import { messages, withLocale } from '../../lib/i18n'

export default function Footer({ locale = 'en' }: { locale?: string }) {
  const ui = messages(locale).ui
  const L = (p: string) => withLocale(p, locale)
  return (
    <footer className="border-t border-line bg-bg text-fg">
      <div
        className="mx-auto flex max-w-[1440px] flex-col gap-8 px-5 py-12 text-sm text-muted sm:px-8 md:flex-row md:items-start md:justify-between md:py-16"
      >
        <div className="max-w-md space-y-3">
          <span className="text-base"><Logo size={28} /></span>
          <p className="leading-relaxed">{ui.legal}</p>
          <p className="leading-relaxed">
            <Rich text={ui.credits} locale={locale} />
          </p>
        </div>
        <div className="grid grid-cols-2 gap-x-12 gap-y-2">
          <a className="hover:text-fg" href={L('/docs/introduction/quick-start')}>{ui.quickStart}</a>
          <a className="hover:text-fg" href={REPO_URL}>GitHub</a>
          <a className="hover:text-fg" href={L('/docs/reference/cli')}>{ui.cliReference}</a>
          <a className="hover:text-fg" href={`${REPO_URL}/issues`}>{ui.issues}</a>
          <a className="hover:text-fg" href={L('/docs/project/status')}>{ui.status}</a>
          <a className="hover:text-fg" href={L('/docs/project/privacy')}>{ui.privacy}</a>
        </div>
      </div>
    </footer>
  )
}
