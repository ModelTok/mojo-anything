import { messages, withLocale, type Messages } from '../../lib/i18n'
import Rich from '../Rich'
import './landing.css'

function RecordViz() {
  const rows = [
    ['ms', '"1 ſ"'],
    ['ms', '"2 days"'],
    ['format', '-0'],
    ['round', '-2.5'],
    ['parse', '"ΣΊΣΥΦΟΣ"'],
  ]
  return (
    <div className="w-full font-mono text-[11px] leading-[22px] text-muted">
      {rows.map(([fn, args], i) => (
        <div key={i} className="truncate">
          {'{'}<span className="text-brand-ink">"fn"</span>:"{fn}",<span className="text-brand-ink">"args"</span>:[{args}]{'}'}
        </div>
      ))}
    </div>
  )
}

function PortViz({ m }: { m: Messages['home'] }) {
  return (
    <div className="flex w-full items-center justify-center gap-3 font-mono text-xs">
      <div className="grid grid-cols-2 gap-1.5">
        {['TS', 'Py', 'Go', 'Rb', 'Java', 'C'].map((l) => (
          <span key={l} className="rounded border border-line px-2 py-0.5 text-center text-muted">
            {l}
          </span>
        ))}
      </div>
      <svg width="48" height="20" viewBox="0 0 48 20" aria-hidden className="text-brand">
        <path d="M0 10 H42 M34 3 L43 10 L34 17" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <div className="rounded-md border border-brand/50 bg-brand-soft px-3 py-2 text-center text-brand-ink">
        port.mojo
        <div className="mt-0.5 text-[10px] text-muted">{m.vizSameApi}</div>
      </div>
    </div>
  )
}

function CheckViz({ m }: { m: Messages['home'] }) {
  return (
    <div className="text-center">
      <div className="text-xs text-muted">{m.vizCheck}</div>
      <div className="font-display text-3xl font-semibold tracking-tight">{m.vizMatch}</div>
      <div className="mt-3 inline-flex items-center gap-1.5 rounded-full bg-good-soft px-2.5 py-0.5 text-xs font-medium text-good">{m.vizGate}</div>
    </div>
  )
}

// The bars show the shape of a lift (everything falls back, then less, then nothing), not a
// measured run.
function LiftViz({ m }: { m: Messages['home'] }) {
  const widths = ['w-full', 'w-1/3', 'w-0']
  return (
    <div className="w-full space-y-2.5">
      <div className="text-[11px] text-muted">{m.vizLift}</div>
      {m.vizLiftSteps.map((label, i) => (
        <div key={label}>
          <div className="mb-1 text-[11px] text-muted">{label}</div>
          <div className="h-1.5 rounded-full bg-line">
            <div className={`h-1.5 rounded-full bg-brand ${widths[i]}`} />
          </div>
        </div>
      ))}
    </div>
  )
}

const STEP_CMDS = ['record', 'bridge', 'diff, gate', 'app lift']

const LANGS = [
  { key: 'typescript', name: 'TypeScript/JavaScript' },
  { key: 'python', name: 'Python' },
  { key: 'c', name: 'C' },
  { key: 'go', name: 'Go' },
  { key: 'ruby', name: 'Ruby' },
  { key: 'java', name: 'Java' },
  { key: 'kotlin', name: 'Kotlin' },
  { key: 'php', name: 'PHP', wholeApp: true },
  { key: 'csharp', name: 'C#', wholeApp: true },
] as const

export default function Home({ hero, install, locale = 'en' }: { hero: React.ReactNode; install: React.ReactNode; locale?: string }) {
  const m = messages(locale).home
  const L = (p: string) => withLocale(p, locale)
  const vizzes = [<RecordViz key="r" />, <PortViz key="p" m={m} />, <CheckViz key="c" m={m} />, <LiftViz key="l" m={m} />]
  return (
    <div className="home">
      {hero}

      <section className="section" aria-labelledby="install-title">
        <div className="wrap">
          <div className="section-head">
            <h2 id="install-title" className="section-title">
              {m.installTitle}
            </h2>
            <p className="section-desc">{m.installDesc}</p>
          </div>
          <div className="install">{install}</div>
          <p className="note">
            <Rich text={m.installNote} locale={locale} />
          </p>
        </div>
      </section>

      <section className="section" aria-labelledby="loop-title">
        <div className="wrap">
          <div className="section-head">
            <h2 id="loop-title" className="section-title">
              {m.loopTitle}
            </h2>
            <p className="section-desc">{m.loopDesc}</p>
          </div>
          <ol className="steps">
            {m.steps.map((s, i) => (
              <li key={i} className="step">
                <div className="step-viz" aria-hidden>
                  {vizzes[i]}
                </div>
                <span className="step-n" aria-hidden>
                  {i + 1}
                </span>
                <h3>{s.title}</h3>
                <code className="step-cmd">{STEP_CMDS[i]}</code>
                <p>
                  <Rich text={s.text} />
                </p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      <section className="section" aria-labelledby="demo-title">
        <div className="wrap">
          <div className="section-head">
            <h2 id="demo-title" className="section-title">
              {m.demoTitle}
            </h2>
            <p className="section-desc">
              <Rich text={m.demoDesc} locale={locale} />
            </p>
          </div>
          <div className="panel">
            <div className="titlebar">
              <span>~/ms</span>
            </div>
            <div className="split">
              <div>
                <pre>
                  <span className="c">{m.demoComments.bridge}</span>
                  {'\n'}
                  <span className="p">$</span> mojo-anything bridge . src/index.ts --kind node{'\n'}
                  <span className="p">$</span> mojo-anything record mojo/index-mojo{'\n'}
                  <span className="p">$</span> mojo-anything build mojo/index-mojo{'\n'}
                  <span className="c">{m.demoComments.check}</span>
                  {'\n'}
                  <span className="p">$</span> mojo-anything diff mojo/index-mojo{'\n'}
                  <span className="p">$</span> mojo-anything gate mojo/index-mojo
                </pre>
              </div>
              <div>
                <pre>
                  <span className="c">{m.demoComments.traps}</span>
                  {m.demoComments.trapLines.map((l) => (
                    <span key={l}>
                      {'\n'}
                      <span className="ok">✓</span> {l}
                    </span>
                  ))}
                </pre>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="section" aria-labelledby="ports-title">
        <div className="wrap">
          <div className="section-head">
            <h2 id="ports-title" className="section-title">
              {m.portsTitle}
            </h2>
            <p className="section-desc">
              <Rich text={m.portsDesc} />
            </p>
          </div>

          <div className="ports">
            {m.ports.map((p) => (
              <a key={p.href} href={L(p.href)} className="port-card">
                <div className="port-kind">{p.kind}</div>
                <div className="big">{p.title}</div>
                <p>
                  <Rich text={p.text} />
                </p>
              </a>
            ))}
          </div>
        </div>
      </section>

      <section className="section last" aria-labelledby="langs-title">
        <div className="wrap">
          <div className="section-head">
            <h2 id="langs-title" className="section-title">
              {m.langsTitle}
            </h2>
            <p className="section-desc">{m.langsDesc}</p>
          </div>
          <ul className="langs">
            {LANGS.map((l) => (
              <li key={l.key}>
                <a href={L('/docs/languages/overview')} className="lang">
                  <span className="name">{l.name}</span>
                  <span className={`badge${'wholeApp' in l ? ' preview' : ''}`}>{'wholeApp' in l ? m.wholeApps : m.verified}</span>
                  <span className="meta">
                    <Rich text={m.langMeta[l.key]} />
                  </span>
                </a>
              </li>
            ))}
          </ul>
        </div>
      </section>
    </div>
  )
}
