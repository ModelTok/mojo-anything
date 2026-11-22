#!/usr/bin/env node
'use strict'
// Runs the mojo-anything binary for this machine, downloading it from the GitHub release of
// this package's version on first use and checking it against the release's SHA256SUMS.
//
// The binaries are the assets `.github/workflows/release.yml` uploads when a `v*` tag is
// pushed. No release exists yet (2026-11-22): until `v0.1.0` is tagged and published, the
// download answers 404 and this launcher says so.
//
// Everything the launcher prints goes to stderr: an MCP client reads `mojo-anything mcp`'s
// stdout as JSON-RPC, so only the binary itself writes there.
//
// MOJO_ANYTHING_CACHE: where binaries are kept (default: $XDG_CACHE_HOME/mojo-anything,
// ~/Library/Caches/mojo-anything on macOS, ~/.cache/mojo-anything elsewhere).
// MOJO_ANYTHING_DOWNLOAD_BASE: another place laid out like the releases (a mirror).

const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const RELEASES = 'https://github.com/ModelTok/mojo-anything/releases'

// The platforms a release builds: Mojo ships for these (pixi.toml `platforms`).
const TARGETS = {
  'linux-x64': 'x86_64-unknown-linux-gnu',
  'linux-arm64': 'aarch64-unknown-linux-gnu',
  'darwin-arm64': 'aarch64-apple-darwin',
}

class Refusal extends Error {}

function cacheDir() {
  if (process.env.MOJO_ANYTHING_CACHE) return process.env.MOJO_ANYTHING_CACHE
  if (process.env.XDG_CACHE_HOME) return path.join(process.env.XDG_CACHE_HOME, 'mojo-anything')
  const home = os.homedir()
  return process.platform === 'darwin'
    ? path.join(home, 'Library', 'Caches', 'mojo-anything')
    : path.join(home, '.cache', 'mojo-anything')
}

async function get(url, tag) {
  let res
  try {
    res = await fetch(url)
  } catch (e) {
    throw new Refusal(`could not download ${url}: ${(e.cause && e.cause.message) || e.message}`)
  }
  if (!res.ok) {
    throw new Refusal(
      `${url} answered ${res.status} ${res.statusText}: is release ${tag} published? ` +
        `See ${RELEASES}`,
    )
  }
  return Buffer.from(await res.arrayBuffer())
}

async function download(version, target, exe) {
  const tag = `v${version}`
  const name = `mojo-anything-${tag}-${target}`
  const archiveName = `${name}.tar.gz`
  const base = (process.env.MOJO_ANYTHING_DOWNLOAD_BASE || `${RELEASES}/download`).replace(/\/+$/, '')
  const url = `${base}/${tag}/${archiveName}`
  console.error(`mojo-anything: downloading ${url}`)
  const archive = await get(url, tag)
  const sums = (await get(`${base}/${tag}/SHA256SUMS`, tag)).toString('utf8')
  const line = sums
    .split('\n')
    .map((l) => l.trim().split(/\s+/))
    .find(([, file]) => file === archiveName || file === `*${archiveName}`)
  if (!line) throw new Refusal(`SHA256SUMS of ${tag} has no line for ${archiveName}`)
  const have = crypto.createHash('sha256').update(archive).digest('hex')
  if (have !== line[0].toLowerCase()) {
    throw new Refusal(
      `${archiveName} does not match its SHA-256 in SHA256SUMS (${have}, expected ${line[0]}); ` +
        'nothing was installed',
    )
  }
  const dir = path.dirname(exe)
  fs.mkdirSync(dir, { recursive: true })
  const tmp = fs.mkdtempSync(path.join(dir, '.download-'))
  try {
    fs.writeFileSync(path.join(tmp, archiveName), archive)
    const tar = spawnSync('tar', ['xzf', archiveName], {
      cwd: tmp,
      stdio: ['ignore', 'ignore', 'inherit'],
    })
    if (tar.error || tar.status !== 0) {
      throw new Refusal(`could not unpack ${archiveName} with tar: ${tar.error ? tar.error.message : `exit ${tar.status}`}`)
    }
    const unpacked = path.join(tmp, name, 'mojo-anything')
    if (!fs.existsSync(unpacked)) throw new Refusal(`${archiveName} holds no ${name}/mojo-anything`)
    fs.chmodSync(unpacked, 0o755)
    // A rename within one folder is atomic: a second launcher never runs half a file.
    fs.renameSync(unpacked, exe)
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true })
  }
}

async function main() {
  const key = `${process.platform}-${process.arch}`
  if (process.platform === 'win32') {
    throw new Refusal(
      'Mojo does not run on Windows, so mojo-anything does not either. Use it inside WSL:\n' +
        '  wsl --install -d Ubuntu-24.04\n' +
        'then, in the Ubuntu shell: npm install -g mojo-anything',
    )
  }
  const target = TARGETS[key]
  if (!target) {
    throw new Refusal(
      `no mojo-anything binary for ${key}; releases build ${Object.keys(TARGETS).join(', ')}`,
    )
  }
  const { version } = require('../package.json')
  const exe = path.join(cacheDir(), version, key, 'mojo-anything')
  if (!fs.existsSync(exe)) await download(version, target, exe)

  const result = spawnSync(exe, process.argv.slice(2), { stdio: 'inherit' })
  if (result.error) throw new Refusal(`could not run ${exe}: ${result.error.message}`)
  if (result.signal) process.kill(process.pid, result.signal)
  process.exit(result.status ?? 1)
}

main().catch((e) => {
  console.error(`mojo-anything: ${e instanceof Refusal ? e.message : e.stack}`)
  process.exit(1)
})
