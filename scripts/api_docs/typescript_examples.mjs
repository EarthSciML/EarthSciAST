#!/usr/bin/env node
// Checks and runs the TypeScript example programs in docs/api/examples/typescript.
//
//  1. Type-checks the examples with the package's own `tsc`.
//  2. Runs each example with Node's type stripping, resolving
//     `@earthsciml/ast` to the in-repo build. Any failure fails the run.
//
// The region markers are checked by regions.py, which typescript.sh runs first.
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

// --- 1. type-check -------------------------------------------------------------
const tsc = path.join(pkgDir, 'node_modules', 'typescript', 'bin', 'tsc')
const tc = spawnSync(process.execPath, [tsc, '-p', path.join(exDir, 'tsconfig.json')], { stdio: 'inherit' })
if (tc.status !== 0) fail('type-check of the TypeScript examples failed')

// --- 2. run --------------------------------------------------------------------
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
console.log(`typescript examples: ${examples.length} passed`)
