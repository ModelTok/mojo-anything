export default function Logo({ size = 28, text = true }: { size?: number; text?: boolean }) {
  return (
    <span className="inline-flex items-center gap-2.5">
      <img src="/favicon.svg" width={size} height={size} alt={text ? '' : 'mojo-anything'} className="shrink-0" />
      {text && <span className="font-display font-semibold tracking-tight text-fg">mojo-anything</span>}
    </span>
  )
}
