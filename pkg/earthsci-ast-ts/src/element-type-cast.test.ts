/**
 * esm-spec §4.2 "Precision conversion" / §11.3.1 (CONFORMANCE_SPEC §5.18.2a):
 * `{"op": "cast", "element_type": "Float32" | "Float64", "args": [x]}`.
 *
 * The fixtures are shared with the other four bindings
 * (`tests/conformance/element_type_cast/`). This binding asserts the loader
 * contract (`casts`: every fixture loads with exactly those cast element types
 * in document order and keeps them through load → emit → load). Its scalar
 * evaluator computes in binary64 only, so it evaluates a cast to Float64 as the
 * identity and refuses one to Float32 with `float32_unsupported`, never
 * evaluating it as the identity.
 */

import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { canonicalJson } from './canonicalize.js'
import { compileExpression, EvaluatorError, evaluateExpression } from './codegen.js'
import { ERROR_CODES } from './errors.js'
import { parseExpression } from './parse-expression.js'
import { loadPath, loadString } from './parse.js'
import { toAscii, toLatex, toUnicode } from './pretty-print.js'
import { toJson } from './serialize.js'
import type { Expression } from './types.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const dir = path.resolve(here, '../../../tests/conformance/element_type_cast')
const expected = JSON.parse(readFileSync(path.join(dir, 'expected.json'), 'utf8')) as {
  casts: Record<string, string[]>
  binary64_values: Record<string, Record<string, number>>
}

type Doc = {
  models?: Record<string, { equations?: Array<{ lhs: unknown; rhs: unknown }> }>
}

/**
 * The `element_type` of every `cast` node of an emitted document: models in
 * order, equations in order (lhs then rhs), a node before its operands.
 */
function casts(doc: Doc): string[] {
  const out: string[] = []
  const walk = (v: unknown): void => {
    if (Array.isArray(v)) {
      for (const a of v) walk(a)
    } else if (v !== null && typeof v === 'object') {
      const n = v as Record<string, unknown>
      if (n.op === 'cast') out.push(String(n.element_type))
      walk(n.args)
      for (const [k, child] of Object.entries(n)) if (k !== 'args') walk(child)
    }
  }
  for (const model of Object.values(doc.models ?? {})) {
    for (const eq of model.equations ?? []) {
      walk(eq.lhs)
      walk(eq.rhs)
    }
  }
  return out
}

function f32Cast(): Expression {
  return { op: 'cast', element_type: 'Float32', args: ['x'] } as unknown as Expression
}

describe('element_type_cast (esm-spec §4.2 "Precision conversion")', () => {
  it('expected.json lists casts for every fixture', () => {
    expect(Object.keys(expected.casts).length).toBeGreaterThan(0)
  })

  for (const [fixture, want] of Object.entries(expected.casts)) {
    it(`${fixture}: loads with exactly its casts and keeps them through load → emit → load`, () => {
      const file = loadPath(path.join(dir, fixture))
      const text = toJson(file)
      expect(casts(JSON.parse(text) as Doc)).toEqual(want)
      const again = toJson(loadString(text))
      expect(casts(JSON.parse(again) as Doc)).toEqual(want)
    })
  }

  it('evaluates identity_f64.esm: cast(x, Float64) * 3 at x = 0.1 is 0.30000000000000004', () => {
    const file = loadPath(path.join(dir, 'identity_f64.esm'))
    const model = file.models!.Same as { equations: Array<{ rhs: unknown }> }
    const rhs = model.equations[0]!.rhs as Expression
    const y = evaluateExpression(rhs, new Map([['x', 0.1]]))
    expect(Object.is(y, 0.30000000000000004)).toBe(true)
    expect(y).toBe(expected.binary64_values['identity_f64.esm']!['Same.y'])
  })

  it('refuses a cast to Float32 with float32_unsupported, never the identity', () => {
    for (const run of [
      () => evaluateExpression(f32Cast(), new Map([['x', 0.1]])),
      () => compileExpression(f32Cast()),
      () =>
        evaluateExpression(
          { op: '*', args: [f32Cast(), 3] } as unknown as Expression,
          new Map([['x', 0.1]]),
        ),
    ]) {
      let err: unknown
      try {
        run()
      } catch (e) {
        err = e
      }
      expect(err).toBeInstanceOf(EvaluatorError)
      expect((err as EvaluatorError).code).toBe(ERROR_CODES.FLOAT32_UNSUPPORTED)
      expect((err as Error).message).toContain('cast to Float32')
    }
  })

  it('renders cast(A, element_type=P) and parses it back', () => {
    expect(toAscii(f32Cast())).toBe('cast(x, element_type=Float32)')
    expect(toUnicode(f32Cast())).toBe('cast(x, element_type=Float32)')
    expect(toLatex(f32Cast())).toBe('\\mathrm{cast}(x, element\\_type=Float32)')
    expect(parseExpression('cast(x, element_type=Float32)')).toEqual(f32Cast())
    for (const bad of [
      'cast(x)',
      'cast(x, y, element_type=Float32)',
      'cast(x, element_type=Float16)',
      'cast(x, element_type=Float32, id=z)',
    ]) {
      expect(() => parseExpression(bad), bad).toThrow()
    }
  })

  it('canonicalizes the two precisions apart', () => {
    const c32 = canonicalJson(f32Cast())
    expect(c32).toBe('{"args":["x"],"element_type":"Float32","op":"cast"}')
    expect(
      canonicalJson({ op: 'cast', element_type: 'Float64', args: ['x'] } as unknown as Expression),
    ).not.toBe(c32)
  })
})
