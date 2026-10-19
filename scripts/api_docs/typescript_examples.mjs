#!/usr/bin/env node
// Checks and runs the TypeScript example programs in docs/api/examples/typescript.
//
//  1. Region markers: well formed, not nested, ids unique, and every `ops=`
//     name a canonical operation that api-surface.json binds in TypeScript.
//  2. Type-checks the examples with the package's own `tsc`.
//  3. Runs each example with Node's type stripping, resolving
//     `@earthsciml/ast` to the in-repo build. Any failure fails the run.
//
// Usage: node typescript_examples.mjs <repo-root>

import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(process.argv[2] ?? '.')
const exDir = path.join(repoRoot, 'docs', 'api', 'examples', 'typescript')
const pkgDir = path.join(repoRoot, 'pkg', 'earthsci-ast-ts')
const hook = path.join(repoRoot, 'scripts', 'api_docs', 'typescript_examples_resolve.mjs')
const rel = (p) => path.relative(repoRoot, p)

const manifest = JSON.parse(fs.readFileSync(path.join(repoRoot, 'api-surface.json'), 'utf8'))
const tsCanonical = new Set(manifest.symbols.filter((s) => s.bindings?.typescript !== undefined).map((s) => s.name))

const examples = fs
  .readdirSync(exDir)
  .filter((f) => f.endsWith('.ts') && !f.endsWith('.d.ts'))
  .sort()
  .map((f) => path.join(exDir, f))

let failed = false
const fail = (msg) => {
  console.error(msg)
  failed = true
}

// --- 1. regions ----------------------------------------------------------------
const seen = new Map()
for (const file of examples) {
  const lines = fs.readFileSync(file, 'utf8').split('\n')
  let open = null
  lines.forEach((line, i) => {
    const where = `${rel(file)}:${i + 1}`
    const start = line.match(/^\s*\/\/\s*region:\s*(\S+)(.*)$/)
    if (start) {
      if (open) fail(`${where}: region '${start[1]}' opens inside region '${open}'`)
      open = start[1]
      if (seen.has(open)) fail(`${where}: region id '${open}' already used at ${seen.get(open)}`)
      seen.set(open, where)
      const ops = start[2].match(/\bops=(\S+)/)
      if (!ops) fail(`${where}: region '${open}' has no ops=`)
      for (const op of ops ? ops[1].split(',') : []) {
        if (!tsCanonical.has(op)) fail(`${where}: '${op}' is not a canonical name bound in TypeScript`)
      }
    } else if (/^\s*\/\/\s*endregion\b/.test(line)) {
      if (!open) fail(`${where}: endregion without region`)
      open = null
    }
  })
  if (open) fail(`${rel(file)}: region '${open}' is never closed`)
}

// --- 2. type-check -------------------------------------------------------------
const tsc = path.join(pkgDir, 'node_modules', 'typescript', 'bin', 'tsc')
const tc = spawnSync(process.execPath, [tsc, '-p', path.join(exDir, 'tsconfig.json')], { stdio: 'inherit' })
if (tc.status !== 0) fail('type-check of the TypeScript examples failed')

// --- 3. run --------------------------------------------------------------------
const nodeFlags = ['--disable-warning=ExperimentalWarning']
if (!process.features?.typescript) nodeFlags.push('--experimental-strip-types')
for (const file of examples) {
  const t0 = Date.now()
  const r = spawnSync(process.execPath, [...nodeFlags, '--import', hook, file], {
    stdio: 'inherit',
    cwd: repoRoot,
  })
  const ms = Date.now() - t0
  if (r.status === 0) console.log(`ok    ${rel(file)} (${ms} ms)`)
  else fail(`FAIL  ${rel(file)} (exit ${r.status ?? r.signal})`)
}

if (failed) {
  console.error('typescript examples: FAILED')
  process.exit(1)
}
console.log(`typescript examples: ${examples.length} passed, ${seen.size} regions`)
