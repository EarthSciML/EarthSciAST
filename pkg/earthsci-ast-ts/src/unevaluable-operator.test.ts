import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { compileExpression, evaluateExpression } from './codegen.js'
import { ERROR_CODES } from './errors.js'
import type { Expr } from './types.js'

interface Cases {
  code: string
  bindings: Record<string, number>
  control: { expression: Expr; expected: number }
  cases: { id: string; op: string; expression: Expr }[]
}

const fixture = JSON.parse(
  readFileSync(
    new URL('../../../tests/conformance/unevaluable_operator/cases.json', import.meta.url),
    'utf8',
  ),
) as Cases

const bindings = new Map(Object.entries(fixture.bindings))

function refusal(fn: () => unknown): { code?: string; message: string } | undefined {
  try {
    fn()
  } catch (e) {
    return e as { code?: string; message: string }
  }
  return undefined
}

describe('unevaluable_operator (esm-spec §9.6.6, shared fixture)', () => {
  // Every case puts the op in the UNTAKEN branch of an `ifelse`: a walker that
  // raises only when evaluation reaches the node would answer 1.0.
  for (const c of fixture.cases) {
    it(`evaluateExpression refuses ${c.id} before evaluating`, () => {
      const err = refusal(() => evaluateExpression(c.expression, bindings))
      expect(err, `${c.op} must be refused, not evaluated`).toBeDefined()
      expect(err?.code).toBe(fixture.code)
      expect(err?.message).toContain(`'${c.op}'`)
    })

    it(`compileExpression refuses ${c.id} at compile time`, () => {
      const err = refusal(() => compileExpression(c.expression))
      expect(err, `${c.op} must be refused when the closure is built`).toBeDefined()
      expect(err?.code).toBe(fixture.code)
    })
  }

  it('still evaluates the control expression', () => {
    expect(evaluateExpression(fixture.control.expression, bindings)).toBe(fixture.control.expected)
  })
})

describe('unevaluable_operator versus unlowered_operator', () => {
  const x = new Map([['x', 1]])

  // Closed-core ops with no scalar rule: never the open-tier rewrite-rule advice.
  for (const op of [
    'skolem',
    'rank',
    'distinct',
    'argmin',
    'argmax',
    'apply_expression_template',
    'ic',
    'faq',
    'makearray',
    'index',
    'broadcast',
    'reshape',
    'transpose',
    'concat',
    'intersect_polygon',
    'polygon_intersection_area',
    'Pre',
  ]) {
    it(`${op} is unevaluable_operator`, () => {
      const err = refusal(() => evaluateExpression({ op, args: ['x'] } as Expr, x))
      expect(err?.code).toBe('unevaluable_operator')
      expect(err?.message).toContain(`'${op}'`)
      expect(err?.message).not.toContain('rewrite rule')
    })
  }

  it('enum is unevaluable_operator', () => {
    const err = refusal(() =>
      evaluateExpression({ op: 'enum', args: ['colors', 'red'] } as Expr, x),
    )
    expect(err?.code).toBe('unevaluable_operator')
  })

  for (const op of ['grad', 'godunov_hamiltonian']) {
    it(`${op} (open tier) stays unlowered_operator`, () => {
      const err = refusal(() => evaluateExpression({ op, args: ['x'] } as Expr, x))
      expect(err?.code).toBe('unlowered_operator')
    })
  }

  it('evaluates the `true` literal', () => {
    expect(evaluateExpression({ op: 'true', args: [] } as Expr, x)).toBe(1)
    expect(
      evaluateExpression({ op: 'ifelse', args: [{ op: 'true', args: [] }, 2, 3] } as Expr, x),
    ).toBe(2)
  })

  it('evaluates the `false` literal', () => {
    expect(evaluateExpression({ op: 'false', args: [] } as Expr, x)).toBe(0)
    expect(
      evaluateExpression({ op: 'ifelse', args: [{ op: 'false', args: [] }, 2, 3] } as Expr, x),
    ).toBe(3)
    expect(compileExpression({ op: 'not', args: [{ op: 'false', args: [] }] } as Expr)(x)).toBe(1)
  })

  it('evaluates `pow` as the word spelling of `^`', () => {
    const b = new Map([['x', 2]])
    expect(evaluateExpression({ op: 'pow', args: ['x', 3] } as Expr, b)).toBe(8)
    expect(evaluateExpression({ op: 'pow', args: ['x', 0.5] } as Expr, b)).toBe(
      evaluateExpression({ op: '^', args: ['x', 0.5] } as Expr, b),
    )
    expect(() => evaluateExpression({ op: 'pow', args: ['x'] } as Expr, b)).toThrow(
      'Exponentiation requires exactly 2 arguments',
    )
  })
})

describe('the up-front walk also carries the unlowered_operator gate (issue #277)', () => {
  // An op OUTSIDE the §4.2 core is refused even where lazy evaluation would
  // never reach it: an untaken `ifelse` branch, or an `and`/`or` operand past
  // the short-circuit (esm-spec §9.6.3 constraint 6).
  const grad = { op: 'grad', args: ['p'], dim: 'x' }
  const cases: Record<string, Expr> = {
    'ifelse untaken branch': {
      op: 'ifelse',
      args: [{ op: '>', args: ['u', 100] }, grad, 1],
    } as Expr,
    'and after a false operand': { op: 'and', args: [0, grad] } as Expr,
    'or after a true operand': { op: 'or', args: [1, grad] } as Expr,
  }
  for (const [label, expr] of Object.entries(cases)) {
    it(`evaluateExpression refuses grad in the ${label}`, () => {
      const err = refusal(() => evaluateExpression(expr, bindings))
      expect(err, 'grad must be refused, not evaluated').toBeDefined()
      expect(err?.code).toBe('unlowered_operator')
      expect(err?.message).toContain("'grad'")
    })
    it(`compileExpression refuses grad in the ${label}`, () => {
      expect(refusal(() => compileExpression(expr))?.code).toBe('unlowered_operator')
    })
  }
})

it('registers unevaluable_operator in ERROR_CODES', () => {
  expect(ERROR_CODES.UNEVALUABLE_OPERATOR).toBe('unevaluable_operator')
})
