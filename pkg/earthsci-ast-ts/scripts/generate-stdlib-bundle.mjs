#!/usr/bin/env node
/**
 * generate-stdlib-bundle.mjs — derive `src/stdlib-bundle.ts` from the
 * repo-root standard library `lib/*.esm`.
 *
 * A `esm:std/<file>.esm` ref (esm-spec §4.7) resolves to the copy of the
 * standard library each binding bundles in its own published package. The
 * TypeScript binding also runs in the browser, where there is no filesystem,
 * so the library is embedded as a module of file texts that Rollup bundles
 * into `dist/`. The module is GENERATED so it cannot hand-drift from `lib/`:
 *
 *   npm run generate-stdlib                            # rewrite the module
 *   node scripts/generate-stdlib-bundle.mjs --check    # drift guard (CI)
 *
 * `scripts/sync-lib.sh` runs this generator, and `scripts/sync-lib.sh --check`
 * runs its `--check` mode as part of the repo-wide library-sync gate.
 */
import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
// scripts/ -> package root -> pkg/ -> repo root
const LIB_DIR = resolve(here, '..', '..', '..', 'lib')
const OUTPUT = resolve(here, '..', 'src', 'stdlib-bundle.ts')

function render() {
  const names = readdirSync(LIB_DIR)
    .filter((n) => n.endsWith('.esm'))
    .sort()
  const entries = names
    .map((n) => `  ${JSON.stringify(n)}: ${JSON.stringify(readFileSync(join(LIB_DIR, n), 'utf8'))},`)
    .join('\n')
  return `/* eslint-disable */
/**
 * stdlib-bundle.ts — GENERATED FILE. DO NOT EDIT BY HAND.
 *
 * The text of every file of the repo-root standard library \`lib/\`, keyed by
 * file name, written by \`scripts/generate-stdlib-bundle.mjs\`. An
 * \`esm:std/<file>.esm\` ref (esm-spec §4.7) resolves against this table.
 *
 * To change the library, edit \`lib/\` and run \`scripts/sync-lib.sh\`. The drift
 * guard \`scripts/sync-lib.sh --check\` fails CI if this file falls out of sync.
 */

// prettier-ignore
export const STDLIB_FILES: Readonly<Record<string, string>> = {
${entries}
}
`
}

const expected = render()

if (process.argv.includes('--check')) {
  let actual = ''
  try {
    actual = readFileSync(OUTPUT, 'utf8')
  } catch {
    console.error(`DRIFT: ${OUTPUT} is missing. Run: scripts/sync-lib.sh`)
    process.exit(1)
  }
  if (actual !== expected) {
    console.error('DRIFT: src/stdlib-bundle.ts is out of sync with lib/. Run: scripts/sync-lib.sh')
    process.exit(1)
  }
  console.log('OK: src/stdlib-bundle.ts matches lib/')
} else {
  writeFileSync(OUTPUT, expected)
  console.log(`Wrote ${OUTPUT}`)
}
