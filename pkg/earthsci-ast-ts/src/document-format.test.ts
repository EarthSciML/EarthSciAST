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
import {
  expressionNames,
  parseDocument,
  parseMath,
  printDocument,
  printMath,
  type DocumentFormat,
} from './document/index.js'
import { EsmDiagnosticError } from './errors.js'
import { intLit } from './numeric-literal.js'
import { fixturesDir, numberKinds, readFixture } from './test-helpers.js'

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

/** Every number as its kind and value (see {@link numberKinds}). */
const typed = numberKinds

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
        model?.operators !== undefined ||
        esm.operators !== undefined ||
        model?.expression_templates !== undefined ||
        esm.expression_templates !== undefined
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
        // ... and `parseMath` reads that math back to the equation.
        const eq = typed(canonicalizeDocument(eqs[0]))
        expect(typed(parseMath(c.math!.latex, names, 'markdown', { canonical: true }))).toEqual(eq)
        expect(typed(parseMath(c.math!.typst, names, 'typst', { canonical: true }))).toEqual(eq)
      })
    }
  }
})

/** The diagnostic code `parseMath` raises, or `undefined` when it reads. */
function mathRefusalCode(
  text: string,
  names: string[],
  format: DocumentFormat,
): string | undefined {
  try {
    parseMath(text, names, format)
    return undefined
  } catch (e) {
    if (e instanceof EsmDiagnosticError) return e.code
    throw e
  }
}

describe('parseMath', () => {
  it('reads an expression or an equation', () => {
    const names = ['RT', 'k', 'y']
    expect(parseMath('RT + k', names, 'markdown')).toEqual({ op: '+', args: ['RT', 'k'] })
    // With its letters declared instead, a run of letters in LaTeX is their
    // product; with neither, it is not read.
    expect(parseMath('RT', ['R', 'T'], 'markdown')).toEqual({ op: '*', args: ['R', 'T'] })
    expect(mathRefusalCode('RT', [], 'markdown')).toBe('parse_error')
    expect(parseMath('y = 2 k', names, 'typst')).toEqual({
      lhs: 'y',
      rhs: { op: '*', args: [2, 'k'] },
    })
    for (const [text, format] of [
      ['y = k', 'markdown'],
      ['(dif y)/(dif t) = -k y', 'typst'],
    ] as const) {
      expect(printMath(parseMath(text, names, format), names, format)).toBe(text)
    }
  })

  it('refuses as a document read does', () => {
    const names = ['k']
    expect(mathRefusalCode('k +', names, 'markdown')).toBe('parse_error')
    expect(mathRefusalCode('1.0e400 k', names, 'typst')).toBe('parse_error')
    expect(mathRefusalCode('\\operatorname{arrayop}(k)', names, 'markdown')).toBe('removed_op')
    const deep = `${'('.repeat(50_000)}k${')'.repeat(50_000)}`
    expect(mathRefusalCode(deep, names, 'typst')).toBe('parse_error')
  })

  it('gives numbers as the document readers do', () => {
    const z = 2n ** 63n - 1n
    const read = parseMath(`${z} k`, ['k'], 'typst', { canonical: true }) as { args: unknown[] }
    expect(read.args[0]).toBe(z)
    expect(typed(parseMath('2.0 k', ['k'], 'typst', { canonical: true }))).toEqual(
      typed({ op: '*', args: [intLit(2), 'k'] }),
    )
  })
})

describe('expressionNames', () => {
  it('lists the names under lhs, rhs and args in order of first use', () => {
    const eq = {
      lhs: { op: 'D', args: ['x'], wrt: 't' },
      rhs: { op: '+', args: [{ op: '*', args: ['k', 'x'] }, 3, 'k', 'Emis.flux'] },
    }
    expect(expressionNames(eq)).toEqual(['x', 'k', 'Emis.flux'])
    expect(expressionNames('y')).toEqual(['y'])
    expect(expressionNames(2)).toEqual([])
    expect(printMath(eq, expressionNames(eq), 'typst')).toBe(
      printMath(eq, ['x', 'k', 'Emis.flux'], 'typst'),
    )
  })
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

describe('document format integers past 2^53', () => {
  const doc = (k: unknown, rhs: unknown): Record<string, unknown> => ({
    esm: '2.3.0',
    metadata: { name: 'm' },
    models: {
      M: {
        variables: { k: { type: 'parameter', default: k }, x: { type: 'state' } },
        equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs }],
      },
    },
  })
  type Read = {
    models: { M: { variables: { k: { default: unknown } }; equations: [{ rhs: unknown }] } }
  }
  const parts = (d: Record<string, unknown>): [unknown, unknown] => {
    const m = (d as Read).models.M
    return [m.variables.k.default, m.equations[0].rhs]
  }
  const INTS = [2n ** 53n + 1n, -(2n ** 53n) - 1n, 2n ** 63n - 1n, -(2n ** 63n)]

  for (const format of FORMATS) {
    for (const z of INTS) {
      it(`${format}: ${z} reads as its exact bigint and prints back exactly`, () => {
        const text = printDocument(doc(z, { op: '*', args: [z, 'k'] }), format)
        const lit = format === 'typst' && z === -(2n ** 63n) ? '(-9223372036854775807 - 1)' : `${z}`
        expect(text).toContain(lit)
        expect(text).toContain(`${z}`)
        const back = parseDocument(text, format, { canonical: true })
        const [k, rhs] = parts(back)
        expect(k).toBe(z)
        expect((rhs as { args: unknown[] }).args).toContain(z)
        expect(printDocument(back, format)).toBe(text)
        // Without `canonical`, a plain number, as `JSON.parse` gives it.
        const [plain] = parts(parseDocument(text, format))
        expect(plain).toBe(Number(z))
      })
    }
  }

  it('reads the integer written in Markdown, not its nearest binary64', () => {
    const text = printDocument(doc(1, 'k'), 'markdown').replace(
      'default=1',
      'default=9007199254740993',
    )
    expect(parts(parseDocument(text, 'markdown', { canonical: true }))[0]).toBe(9007199254740993n)
  })

  // As in Rust: a mantissa times `10^{Int64 max}` is a decimal far beyond the
  // binary64 range (refused) when its exponent fits in Int64, and otherwise the
  // product of the mantissa and a power whose exponent is the exact integer.
  it('a power of ten with exponent Int64 max reads as in Rust', () => {
    const max = 2n ** 63n - 1n
    for (const format of FORMATS) {
      const sci = (m: string, e: string): string =>
        format === 'markdown' ? `${m} \\times 10^{${e}}` : `${m} times 10^(${e})`
      const base = printDocument(doc(1, { op: '*', args: [2.5, 'k'] }), format)
      const read = (m: string, e: string): Record<string, unknown> =>
        parseDocument(base.replace('2.5', sci(m, e)), format, { canonical: true })
      expect(refusalCode(base.replace('2.5', sci('1.5', `${max}`)), format)).toBe('parse_error')
      expect(typed(parts(read('15', `${max}`))[1])).toEqual(
        typed({ op: '*', args: [intLit(15), { op: '^', args: [intLit(10), max] }, 'k'] }),
      )
      expect(typed(parts(read('1.5', `${-max - 1n}`))[1])).toEqual(
        typed({ op: '*', args: [intLit(0), 'k'] }),
      )
    }
  })

  it('a plain number past 2^53 in Int64 prints as an integer', () => {
    for (const format of FORMATS) {
      const text = printDocument(doc(-(2 ** 63), 'k'), format)
      expect(text).not.toMatch(/9\.22/)
      expect(parts(parseDocument(text, format))[0]).toBe(-(2 ** 63))
      expect(printDocument(doc(2 ** 60, 'k'), format)).toContain(`${2n ** 60n}`)
    }
  })
})

interface LimitsCase {
  id: string
  surface: DocumentFormat
  input: {
    prefix?: string
    open?: string
    n?: number
    middle?: string
    close?: string
    suffix?: string
    yaml_levels?: number
  }
  esm_json?: string
  error?: string
}

/** A `limits.json` input, built from its recipe (README, section Limits). */
function limitsText(head: string, input: LimitsCase['input']): string {
  if (input.yaml_levels !== undefined) {
    let body = '```esm:metaparameters\nx:\n'
    for (let i = 1; i < input.yaml_levels; i++) body += ' '.repeat(2 * i) + '-\n'
    return head + body + '```\n'
  }
  const n = input.n ?? 0
  return (
    head +
    (input.prefix ?? '') +
    (input.open ?? '').repeat(n) +
    (input.middle ?? '') +
    (input.close ?? '').repeat(n) +
    (input.suffix ?? '')
  )
}

/**
 * `limits.json`: the readers' bounds on nesting and numbers, and `removed_op`
 * only for an operator the math meets. Each case reads as `esm_json` or is
 * refused with `error`, without exhausting the stack.
 */
describe('document format limits', () => {
  const fixture = JSON.parse(readFixture('conformance', 'document_format', 'limits.json')) as {
    heads: Record<DocumentFormat, string>
    cases: LimitsCase[]
  }
  for (const c of fixture.cases) {
    it(c.id, () => {
      const text = limitsText(fixture.heads[c.surface], c.input)
      if (c.error !== undefined) {
        expect(refusalCode(text, c.surface)).toBe(c.error)
      } else {
        expect(parseTyped(text, c.surface)).toEqual(typed(JSON.parse(c.esm_json!)))
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
