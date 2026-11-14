/**
 * The deprecated op spellings `neg` and `pow` (esm-spec §4.2 "Deprecated ops";
 * CONFORMANCE_SPEC `deprecated_op`): the wire boundary rewrites `neg(x)` to
 * unary `-(x)`, `pow(x, n)` to `^(x, n)` and a `broadcast` `fn: "neg"` to
 * `fn: "-"`, keeps every other field, leaves a wrong-arity use alone, and warns
 * `deprecated_op` once per document naming every rewritten node.
 */

import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { loadPath, loadString, validate } from './index'
import { emitDocument } from './template-imports'
import { prepareDocumentOps, rewriteDeprecatedOps } from './parse'
import { resolveSubsystemRefsSync } from './ref-loading'
import type { Model } from './types'

const here = dirname(fileURLToPath(import.meta.url))
const TESTS = join(here, '..', '..', '..', 'tests')

function deprecatedWarnings(spy: ReturnType<typeof vi.spyOn>): string[] {
  return spy.mock.calls
    .map((c: unknown[]) => String(c[0]))
    .filter((m: string) => m.startsWith('deprecated_op'))
}

function doc(rhs: unknown): string {
  return JSON.stringify({
    esm: '2.0.0',
    metadata: { name: 'Dep' },
    models: {
      M: {
        variables: {
          x: { type: 'unknown', units: '1', default: 1.0 },
          y: { type: 'unknown', units: '1' },
        },
        equations: [
          { lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: { op: '-', args: ['x'] } },
          { lhs: 'y', rhs },
        ],
      },
    },
  })
}

describe('deprecated ops neg and pow', () => {
  afterEach(() => vi.restoreAllMocks())

  it('rewrites pow to ^ in pow_alias.esm, with one warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const file = loadPath(
      join(TESTS, 'conformance/scalar_operator_semantics/fixtures/pow_alias.esm'),
    )
    expect((file.models!.PowAlias as Model).equations[0]!.rhs).toEqual({
      op: '^',
      args: ['two', 3],
    })
    const w = deprecatedWarnings(warn)
    expect(w).toHaveLength(1)
    expect(w[0]).toContain('/models/PowAlias/equations/0/rhs')
  })

  it('rewrites the negated observed of scalar_operator_semantics.esm to unary -', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const file = loadPath(
      join(TESTS, 'conformance/scalar_operator_semantics/fixtures/scalar_operator_semantics.esm'),
    )
    const eq = (file.models!.Ops as Model).equations.find((e) => e.lhs === 'negated')!
    expect(eq.rhs).toEqual({ op: '-', args: ['four'] })
    expect(deprecatedWarnings(warn)).toHaveLength(1)
  })

  it("rewrites a broadcast fn 'neg' to '-' in 27_broadcast_unary.esm, keeping the node", () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const file = loadPath(join(TESTS, 'fixtures/faq/27_broadcast_unary.esm'))
    const text = JSON.stringify(file)
    expect(text).not.toContain('"neg"')
    expect(text).toContain('"op":"broadcast","args":["a"],"fn":"-"')
    expect(deprecatedWarnings(warn)).toHaveLength(1)
  })

  it('names every rewritten node in one warning per document', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const file = loadString(
      doc({
        op: '+',
        args: [
          { op: 'neg', args: ['x'] },
          { op: 'pow', args: ['x', 2] },
        ],
      }),
    )
    expect((file.models!.M as Model).equations[1]!.rhs).toEqual({
      op: '+',
      args: [
        { op: '-', args: ['x'] },
        { op: '^', args: ['x', 2] },
      ],
    })
    const w = deprecatedWarnings(warn)
    expect(w).toHaveLength(1)
    expect(w[0]).toContain('/models/M/equations/1/rhs/args/0 (neg)')
    expect(w[0]).toContain('/models/M/equations/1/rhs/args/1 (pow)')
  })

  it('leaves a wrong-arity use as written, so its arity error is unchanged', () => {
    const raw = {
      a: { op: 'neg', args: ['x', 'y'] },
      b: { op: 'pow', args: ['x'] },
      c: { op: 'broadcast', fn: 'pow', args: ['x', 'y'] },
      d: { op: 'broadcast', fn: 'neg', args: ['x', 'y'] },
    }
    expect(rewriteDeprecatedOps(raw)).toEqual([])
    expect(raw.a.op).toBe('neg')
    expect(raw.b.op).toBe('pow')
    expect(raw.c.fn).toBe('pow')
    expect(raw.d.fn).toBe('neg')
  })

  it('refuses a two-operand broadcast of neg for its arity, as before', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const refusal = (): string => {
      try {
        const file = loadString(doc({ op: 'broadcast', fn: 'neg', args: ['x', 'x'] }))
        return JSON.stringify(validate(file).structural_errors)
      } catch (e) {
        return String(e)
      }
    }
    const refused = refusal()
    expect(refused).toContain("'neg'")
    expect(deprecatedWarnings(warn)).toHaveLength(0)
  })

  it('names each site by its escaped pointer and old spelling', () => {
    const raw = {
      'a/b~c': { op: 'neg', args: ['x'] },
      d: { op: 'broadcast', fn: 'neg', args: ['x'] },
    }
    expect(rewriteDeprecatedOps(raw)).toEqual(['/a~1b~0c (neg)', '/d (broadcast fn neg)'])
  })

  it('the reference-preserving emit path rewrites them too', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const dir = join(TESTS, 'conformance', 'scalar_operator_semantics', 'fixtures')
    const raw = JSON.parse(readFileSync(join(dir, 'pow_alias.esm'), 'utf8'))
    const before = JSON.stringify(raw)
    const out = JSON.stringify(emitDocument(raw, dir))
    expect(JSON.stringify(raw)).toBe(before)
    expect(out).not.toContain('"pow"')
    expect(deprecatedWarnings(warn)).toHaveLength(1)
  })

  it('keeps every other field of a rewritten node', () => {
    const raw = { op: 'neg', args: ['x'], id: 'n1' }
    expect(rewriteDeprecatedOps(raw)).toEqual([' (neg)'])
    expect(raw).toEqual({ op: '-', args: ['x'], id: 'n1' })
  })

  it('warn: false silences the warning but still rewrites', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const file = loadString(doc({ op: 'neg', args: ['x'] }), { warn: false })
    expect((file.models!.M as Model).equations[1]!.rhs).toEqual({ op: '-', args: ['x'] })
    expect(deprecatedWarnings(warn)).toHaveLength(0)
    const raw = { op: 'pow', args: ['x', 2] }
    prepareDocumentOps(raw, { warn: false })
    expect(raw.op).toBe('^')
    expect(deprecatedWarnings(warn)).toHaveLength(0)
  })

  it('rewrites a mounted {ref} child, with its own one warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const child = doc({ op: 'pow', args: ['x', 2] })
    const root = loadString(
      JSON.stringify({
        esm: '2.0.0',
        metadata: { name: 'Root' },
        models: {
          R: {
            variables: { z: { type: 'unknown', units: '1', default: 0.0 } },
            equations: [{ lhs: { op: 'D', args: ['z'], wrt: 't' }, rhs: 0 }],
            subsystems: { C: { ref: './child.esm' } },
          },
        },
      }),
    )
    resolveSubsystemRefsSync(root, '/virtual', () => child)
    const mounted = JSON.stringify(root)
    expect(mounted).not.toContain('"pow"')
    expect(mounted).toContain('{"op":"^","args":["x",2]}')
    expect(deprecatedWarnings(warn)).toHaveLength(1)
  })
})
