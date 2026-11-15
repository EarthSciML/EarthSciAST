/**
 * The document source formats (CONFORMANCE_SPEC §5.58): the golden set in
 * `tests/conformance/document_format/`, and the whole-corpus round trip.
 *
 * The fixture contract is the README of that directory:
 *
 * - `print`: `print(esm) == text` byte for byte and `parse(text) == esm` as a
 *   JSON value, in both formats (and `canonicalize(written) == esm` when the
 *   case is about the canonical form);
 * - `variant`: `parse(surface, input) == esm` and `print(surface, esm) == canonical`;
 * - `refusal`: `parse(surface, input)` fails with the diagnostic code `error`.
 *
 * The corpus round trip is computed here from the corpus itself, never stored:
 * every `.esm` under `tests/` that is a JSON object (the corpus of
 * `formal/scripts/doc-corpus.py`), canonicalized, printed in each format and
 * read back, must give its canonical form again.
 *
 * Numbers compare by kind as well as value: a parsed document is read with
 * `canonical: true` (int and float literals), and an expected number is an int
 * when it is integral and in Int64 (the canonical form, CONFORMANCE §5.5.3.1).
 */

import { execFile } from 'node:child_process'
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { promisify } from 'node:util'
import { describe, expect, it } from 'vitest'
import { canonicalizeDocument } from './canonicalize.js'
import { parseDocument, printDocument, printMath, type DocumentFormat } from './document/index.js'
import { EsmDiagnosticError } from './errors.js'
import { isIntLit, isNumericLiteral } from './numeric-literal.js'
import { fixturesDir, readFixture } from './test-helpers.js'

const FILES = [
  'operators.json',
  'names.json',
  'variants.json',
  'documents.json',
  'units.json',
  'refusals.json',
]
const FORMATS: readonly DocumentFormat[] = ['markdown', 'typst']

interface Case {
  id: string
  kind: 'print' | 'variant' | 'refusal'
  esm?: Record<string, unknown>
  written?: Record<string, unknown>
  markdown?: string
  typst?: string
  surface?: DocumentFormat
  input?: string
  canonical?: string
  error?: string
  math?: { latex: string; typst: string }
}

const INT64_BOUND = 2 ** 63

/**
 * A JSON value with every number as its kind and value. A `NumericLiteral` keeps
 * its kind; a plain number (an expected value) is an int when it is integral and
 * in Int64.
 */
function typed(value: unknown): unknown {
  if (isNumericLiteral(value)) return { [isIntLit(value) ? 'int' : 'float']: value.value }
  if (typeof value === 'number') {
    const int = Number.isInteger(value) && value >= -INT64_BOUND && value < INT64_BOUND
    return { [int ? 'int' : 'float']: Object.is(value, -0) ? 0 : value }
  }
  if (Array.isArray(value)) return value.map(typed)
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, typed(v)]))
  }
  return value
}

const parseTyped = (text: string, format: DocumentFormat): unknown =>
  typed(parseDocument(text, format, { canonical: true }))

/** The diagnostic code a parse raises, or `undefined` when it reads. */
function refusalCode(text: string, format: DocumentFormat): string | undefined {
  try {
    parseDocument(text, format)
    return undefined
  } catch (e) {
    if (e instanceof EsmDiagnosticError) return e.code
    throw e
  }
}

/**
 * The `math` field of a case is the math of the case's one equation display, so
 * `printMath` of that equation under the names its model declares (the keys of
 * its variables, species and parameters, and the document's index sets) gives
 * it in both formats. A case whose model or document declares expression
 * templates is skipped: no template is in scope for `printMath`.
 */
describe('printMath reproduces the math of a display', () => {
  type Obj = Record<string, unknown>
  for (const file of FILES) {
    const fixture = JSON.parse(readFixture('conformance', 'document_format', file)) as {
      cases: Case[]
    }
    for (const c of fixture.cases) {
      if (c.math === undefined) continue
      const esm = c.esm!
      const model = Object.values((esm.models ?? {}) as Obj)[0] as Obj | undefined
      const template =
        model?.expression_templates !== undefined || esm.expression_templates !== undefined
      it.skipIf(template)(c.id, () => {
        expect(Object.keys((esm.models ?? {}) as Obj)).toHaveLength(1)
        const eqs = model!.equations as unknown[]
        expect(eqs).toHaveLength(1)
        const names = [
          ...['variables', 'species', 'parameters'].flatMap((f) =>
            Object.keys((model![f] ?? {}) as Obj),
          ),
          ...Object.keys((esm.index_sets ?? {}) as Obj),
        ]
        expect(printMath(eqs[0], names, 'markdown')).toBe(c.math!.latex)
        expect(printMath(eqs[0], names, 'typst')).toBe(c.math!.typst)
      })
    }
  }
})

describe('document format fixtures', () => {
  for (const file of FILES) {
    const fixture = JSON.parse(readFixture('conformance', 'document_format', file)) as {
      cases: Case[]
    }
    describe(file, () => {
      for (const c of fixture.cases) {
        it(c.id, () => {
          if (c.kind === 'print') {
            const esm = c.esm!
            if (c.written !== undefined)
              expect(typed(canonicalizeDocument(c.written))).toEqual(typed(esm))
            for (const format of FORMATS) {
              const text = c[format]!
              expect(printDocument(esm, format)).toBe(text)
              expect(parseTyped(text, format)).toEqual(typed(esm))
            }
          } else if (c.kind === 'variant') {
            expect(parseTyped(c.input!, c.surface!)).toEqual(typed(c.esm))
            expect(printDocument(c.esm!, c.surface!)).toBe(c.canonical)
          } else {
            expect(refusalCode(c.input!, c.surface!)).toBe(c.error)
          }
        })
      }
    })
  }
})

/** The `.esm` files under `tests/` that are JSON objects, sorted. */
function corpus(): Array<{ file: string; text: string }> {
  const out: Array<{ file: string; text: string }> = []
  const walk = (dir: string): void => {
    for (const name of fs.readdirSync(dir).sort()) {
      const p = path.join(dir, name)
      if (fs.statSync(p).isDirectory()) walk(p)
      else if (name.endsWith('.esm')) {
        let text: string
        let doc: unknown
        try {
          text = fs.readFileSync(p, 'utf-8')
          doc = JSON.parse(text)
        } catch {
          continue
        }
        if (doc !== null && typeof doc === 'object' && !Array.isArray(doc))
          out.push({ file: p, text })
      }
    }
  }
  walk(fixturesDir())
  return out
}

/**
 * A corpus document in canonical form. It is read with `JSON.parse`, which keeps
 * a key named `__proto__` as an own property; in canonical form a number's kind
 * follows from its value, which `typed` recovers.
 */
const canonOf = (text: string): Record<string, unknown> =>
  canonicalizeDocument(JSON.parse(text)) as Record<string, unknown>

describe('document format corpus round trip', () => {
  it('every corpus document reads back as its canonical form in both formats', () => {
    const docs = corpus()
    expect(docs.length).toBeGreaterThan(100)
    const failures: string[] = []
    for (const { file, text } of docs) {
      const canon = canonOf(text)
      const want = typed(canon)
      for (const format of FORMATS) {
        let what: string | undefined
        try {
          const back = parseTyped(printDocument(canon, format), format)
          if (!isDeepStrictEqual(back, want)) what = 'reads back differently'
        } catch (e) {
          what =
            e instanceof EsmDiagnosticError
              ? `does not read back (${e.code})`
              : `throws ${String(e)}`
        }
        if (what !== undefined)
          failures.push(`${path.relative(fixturesDir(), file)} (${format}): ${what}`)
      }
    }
    expect(failures, `${failures.length} of ${2 * docs.length} round trips failed`).toEqual([])
  }, 600_000)
})

/** Deep equality of two plain JSON-like values. */
function isDeepStrictEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false
  if (Array.isArray(a) !== Array.isArray(b)) return false
  const ka = Object.keys(a)
  const kb = Object.keys(b)
  if (ka.length !== kb.length) return false
  const bo = b as Record<string, unknown>
  return ka.every(
    (k) =>
      Object.prototype.hasOwnProperty.call(bo, k) &&
      isDeepStrictEqual((a as Record<string, unknown>)[k], bo[k]),
  )
}

/**
 * The cross-check against the Lean model, run where `esm-lean` is built
 * (`ESM_LEAN=/path/to/esm-lean npx vitest run src/document-format.test.ts`):
 * over the whole corpus, the canonical form is `esm-lean canon`'s, the printers
 * write exactly what `esm-lean print-md` / `print-typ` write for it, and the
 * readers read the Lean-printed texts exactly as `esm-lean parse-md` /
 * `parse-typ` do. A self round trip alone cannot see a printer and a reader that
 * drift together. Scratch files go to `ESM_LEAN_SCRATCH` (default: a directory
 * under the system temporary directory).
 */
const ESM_LEAN = process.env.ESM_LEAN
describe.skipIf(ESM_LEAN === undefined || ESM_LEAN === '')(
  'document format against esm-lean',
  () => {
    it('matches the Lean printers and readers over the corpus', async () => {
      const run = promisify(execFile)
      const lean = async (mode: string, file: string): Promise<string | undefined> => {
        try {
          return (await run(ESM_LEAN!, [mode, file], { maxBuffer: 1 << 28 })).stdout
        } catch {
          return undefined
        }
      }
      const scratch = process.env.ESM_LEAN_SCRATCH ?? path.join(os.tmpdir(), 'esm-lean-check')
      fs.mkdirSync(scratch, { recursive: true })
      const docs = corpus()
      const failures: string[] = []
      const check = async ({ file, text }: { file: string; text: string }): Promise<void> => {
        const name = path.relative(fixturesDir(), file)
        const stem = path.join(scratch, name.replace(/[/\\]/g, '__'))
        const leanCanon = await lean('canon', file)
        if (leanCanon === undefined) {
          failures.push(`${name}: esm-lean canon refused`)
          return
        }
        const canonPath = `${stem}.canon.json`
        fs.writeFileSync(canonPath, leanCanon)
        const canon = canonOf(text)
        // esm-lean writes canonical numbers, so `JSON.parse` and `typed` recover
        // their kinds (and `JSON.parse` keeps a `__proto__` key as a key).
        if (!isDeepStrictEqual(typed(canon), typed(JSON.parse(leanCanon)))) {
          failures.push(`${name}: canonical forms differ`)
        }
        for (const [format, ext, pr, pa] of [
          ['markdown', 'md', 'print-md', 'parse-md'],
          ['typst', 'typ', 'print-typ', 'parse-typ'],
        ] as const) {
          const leanText = await lean(pr, canonPath)
          if (leanText === undefined) {
            failures.push(`${name}: esm-lean ${pr} refused`)
            continue
          }
          let ours: string | undefined
          try {
            ours = printDocument(JSON.parse(leanCanon) as object, format)
          } catch {
            ours = undefined
          }
          if (ours !== leanText) {
            if (ours !== undefined) fs.writeFileSync(`${stem}.ts.${ext}`, ours)
            failures.push(`${name}: ${pr} differs`)
          }
          const textPath = `${stem}.${ext}`
          fs.writeFileSync(textPath, leanText)
          const leanBack = await lean(pa, textPath)
          let back: unknown
          try {
            back = parseTyped(leanText, format)
          } catch {
            back = undefined
          }
          const want = leanBack === undefined ? undefined : typed(JSON.parse(leanBack))
          if (!isDeepStrictEqual(back, want)) failures.push(`${name}: ${pa} differs`)
        }
      }
      const queue = [...docs]
      const workers = Array.from(
        { length: Math.max(1, Math.min(16, os.cpus().length)) },
        async () => {
          for (let d = queue.shift(); d !== undefined; d = queue.shift()) await check(d)
        },
      )
      await Promise.all(workers)
      failures.sort()
      expect(failures, `${failures.length} differences over ${docs.length} documents`).toEqual([])
    }, 3_600_000)
  },
)
