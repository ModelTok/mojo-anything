// Renders the flame logo (docs/assets/logo-mojo.svg) to the website's icons in public/:
// icon-192.png, icon-512.png, apple-touch-icon.png and favicon.ico (PNGs inside an ICO).
// Run with `npm run icons` after changing the logo.
import { readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { Resvg, initWasm } from '@resvg/resvg-wasm'
import { REPO_ROOT, WEBSITE_ROOT } from './md-include.mjs'

const require = createRequire(import.meta.url)
await initWasm(readFileSync(require.resolve('@resvg/resvg-wasm/index_bg.wasm')))
const svg = readFileSync(join(REPO_ROOT, 'docs', 'assets', 'logo-mojo.svg'), 'utf8')

function png(size, background) {
  const r = new Resvg(svg, { fitTo: { mode: 'width', value: size }, background })
  return Buffer.from(r.render().asPng())
}

function ico(images) {
  const header = Buffer.alloc(6)
  header.writeUInt16LE(0, 0)
  header.writeUInt16LE(1, 2)
  header.writeUInt16LE(images.length, 4)
  const entries = []
  let offset = 6 + 16 * images.length
  for (const { size, data } of images) {
    const e = Buffer.alloc(16)
    e.writeUInt8(size >= 256 ? 0 : size, 0)
    e.writeUInt8(size >= 256 ? 0 : size, 1)
    e.writeUInt16LE(1, 4)
    e.writeUInt16LE(32, 6)
    e.writeUInt32LE(data.length, 8)
    e.writeUInt32LE(offset, 12)
    offset += data.length
    entries.push(e)
  }
  return Buffer.concat([header, ...entries, ...images.map((i) => i.data)])
}

const out = join(WEBSITE_ROOT, 'public')
writeFileSync(join(out, 'icon-192.png'), png(192))
writeFileSync(join(out, 'icon-512.png'), png(512))
// iOS draws a transparent touch icon on black, so this one gets a light background.
writeFileSync(join(out, 'apple-touch-icon.png'), png(180, '#f2f3ef'))
writeFileSync(join(out, 'favicon.ico'), ico([16, 32, 48].map((size) => ({ size, data: png(size) }))))
console.log('icons: icon-192.png, icon-512.png, apple-touch-icon.png, favicon.ico')
