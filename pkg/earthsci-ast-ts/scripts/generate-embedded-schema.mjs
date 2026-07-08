#!/usr/bin/env node
/**
 * generate-embedded-schema.mjs — derive `src/embedded-schema.ts` from the
 * canonical repo-root `esm-schema.json`.
 *
 * Why this exists: the TypeScript binding validates ESM files in the browser,
 * where there is no filesystem to read `esm-schema.json` from at runtime. The
 * schema therefore has to be embedded in a TS module that Rollup bundles into
 * the published artifact. A hand-maintained inline copy was the de-facto "6th
 * schema copy" and silently drifted from the canonical schema. This script
 * makes the embedded copy a GENERATED artifact so it can never hand-drift:
 *
 *   npm run generate-schema                              # rewrite the embedded file
 *   node scripts/generate-embedded-schema.mjs --check    # drift guard (CI)
 *
 * `scripts/sync-schema.sh --check` invokes the `--check` mode as part of the
 * repo-wide schema-sync gate. The check is byte-exact against the output this
 * generator would produce, which is in turn a verbatim re-serialization of the
 * canonical schema — so it is a strict, full-document semantic comparison.
 *
 * Deterministic by construction: `JSON.parse` preserves key order from the
 * canonical file and `JSON.stringify(…, null, 2)` re-emits it stably, so the
 * same canonical schema always yields byte-identical output.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
// scripts/ -> package root -> pkg/ -> repo root
const CANONICAL = resolve(here, '..', '..', '..', 'esm-schema.json')
const OUTPUT = resolve(here, '..', 'src', 'embedded-schema.ts')

/**
 * Render the full text of `src/embedded-schema.ts` for the current canonical
 * schema. Pure function of the canonical file's bytes.
 */
function render() {
  const schema = JSON.parse(readFileSync(CANONICAL, 'utf8'))
  const body = JSON.stringify(schema, null, 2)
  return `/* eslint-disable */
/**
 * embedded-schema.ts — GENERATED FILE. DO NOT EDIT BY HAND.
 *
 * Derived verbatim from the canonical repo-root \`esm-schema.json\` by
 * \`scripts/generate-embedded-schema.mjs\`. The TypeScript binding cannot read a
 * file at runtime (it must run in the browser), so the canonical schema is
 * embedded here and bundled by Rollup. \`parse.ts\` imports this object and
 * hands it to Ajv.
 *
 * To change the schema, edit \`esm-schema.json\` and run \`npm run generate-schema\`.
 * The drift guard \`scripts/sync-schema.sh --check\` fails CI if this file falls
 * out of sync with the canonical schema.
 */
import type { AnySchemaObject } from 'ajv'

// prettier-ignore
export const schema: AnySchemaObject = ${body}
`
}

const expected = render()

if (process.argv.includes('--check')) {
  let actual = ''
  try {
    actual = readFileSync(OUTPUT, 'utf8')
  } catch {
    console.error(`DRIFT: ${OUTPUT} is missing. Run: npm run generate-schema`)
    process.exit(1)
  }
  if (actual !== expected) {
    console.error(
      `DRIFT: src/embedded-schema.ts is out of sync with esm-schema.json.\n` +
        `       Run: npm run generate-schema`,
    )
    process.exit(1)
  }
  console.log('OK: src/embedded-schema.ts matches esm-schema.json')
} else {
  writeFileSync(OUTPUT, expected)
  console.log(`Wrote ${OUTPUT}`)
}
