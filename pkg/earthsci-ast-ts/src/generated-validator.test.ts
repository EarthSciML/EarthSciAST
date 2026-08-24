/**
 * The precompiled validator must agree with the one Ajv would compile.
 *
 * `parse.ts` used to call `ajv.compile(schema)` at module loadString. Ajv is a code
 * generator, so that needs `'unsafe-eval'` — and because the compile happened at
 * import time, a consumer with a strict Content-Security-Policy did not lose
 * validation, it lost the whole application. `src/generated-validator.js` is the
 * same schema compiled ahead of time.
 *
 * That swap is only safe if the two are indistinguishable, and "indistinguishable"
 * has to mean the errors too, not just the verdict: this package's error objects
 * are public output that callers render. So this compiles the schema at test time
 * and compares both the boolean AND the full `errors` array, document by
 * document.
 *
 * It also compares on MALFORMED input. Agreement on valid documents is the easy
 * half — a validator that accepted everything would pass it. The mutations below
 * exercise a different schema mechanism each: type, required, format, additional
 * properties, and a pattern inside `$defs`.
 */
import { describe, expect, it } from 'vitest'
import { spawnSync } from 'node:child_process'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import Ajv from 'ajv'
import addFormats from 'ajv-formats'

import { schema } from './embedded-schema.js'
import precompiled from './generated-validator.js'
import { AJV_OPTIONS } from './ajv-options.mjs'
import { fixturesDir } from './test-helpers.js'

/** Compile the schema the way `parse.ts` used to, as the reference. */
function referenceValidator() {
  const ajv = new Ajv({ ...AJV_OPTIONS })
  addFormats(ajv)
  return ajv.compile(schema)
}

function esmFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry)
    if (statSync(p).isDirectory()) esmFiles(p, out)
    else if (p.endsWith('.esm')) out.push(p)
  }
  return out
}

/** Each mutation targets a different schema mechanism. */
const MUTATIONS: [string, (d: Record<string, unknown>) => unknown][] = [
  ['unmodified', (d) => d],
  ['wrong type', (d) => ({ ...d, esm: 12345 })],
  [
    'missing required',
    (d) => {
      const c = { ...d }
      delete c.metadata
      return c
    },
  ],
  [
    'bad format',
    (d) => ({
      ...d,
      metadata: { ...(d.metadata as object), created: 'not-a-date' },
    }),
  ],
  ['additional property', (d) => ({ ...d, nonsense_key: true })],
  [
    'pattern inside $defs',
    (d) => ({
      ...d,
      metadata: { ...(d.metadata as object), references: [{ doi: 'not-a-doi' }] },
    }),
  ],
]

describe('the precompiled validator', () => {
  const reference = referenceValidator()
  const files = esmFiles(fixturesDir())

  it('has a corpus to compare against', () => {
    expect(files.length).toBeGreaterThan(0)
  })

  it.each(MUTATIONS)('agrees with a freshly compiled Ajv (%s)', (_label, mutate) => {
    let compared = 0
    for (const file of files) {
      let doc: Record<string, unknown>
      try {
        doc = JSON.parse(readFileSync(file, 'utf8'))
      } catch {
        continue // not every fixture is JSON; those are other tests' problem
      }
      const data = mutate(doc)

      const expectedValid = reference(data)
      const expectedErrors = JSON.stringify(reference.errors ?? null)
      const actualValid = precompiled(data)
      const actualErrors = JSON.stringify(precompiled.errors ?? null)

      expect(actualValid, `verdict differs for ${file}`).toBe(expectedValid)
      expect(actualErrors, `errors differ for ${file}`).toBe(expectedErrors)
      compared++
    }
    expect(compared, 'nothing was actually compared').toBeGreaterThan(0)
  })

  it('is in sync with the canonical schema', () => {
    // The drift guard lives HERE rather than in `scripts/sync-schema.sh`, which
    // deliberately runs with no `npm install` (its comment says so) and could
    // not import Ajv to regenerate anything. A precompiled artifact that has
    // fallen behind the schema validates last week's rules while every other
    // copy validates this week's, so it has to be checked somewhere that has
    // the dependencies — which is this suite.
    const result = spawnSync(
      process.execPath,
      [
        fileURLToPath(new URL('../scripts/generate-standalone-validator.mjs', import.meta.url)),
        '--check',
      ],
      { encoding: 'utf8' },
    )
    expect(result.stdout + result.stderr).toContain('OK:')
    expect(result.status, 'run: npm run generate-validator').toBe(0)
  })

  it('needs no code generation, which is the entire point', () => {
    // The guard against someone "fixing" a future problem by reaching for
    // `ajv.compile` again. If this module ever evaluates a string, the CSP that
    // made it necessary starts blanking the page again — and that failure shows
    // up in the consuming app, never here.
    const source = readFileSync(new URL('./generated-validator.js', import.meta.url), 'utf8')
    expect(source).not.toMatch(/new Function\s*\(/)
    expect(source, 'a bare eval defeats the CSP this file exists to satisfy').not.toMatch(
      /\beval\s*\(/,
    )
    expect(source, 'require() is not defined in an ES module').not.toMatch(/\brequire\s*\(/)
  })
})
