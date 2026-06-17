/**
 * Rule engine unit tests (RFC §5.2).
 *
 * The cross-binding conformance assertions live in
 * `rule-engine-conformance.test.ts`; this file exercises each engine
 * component in isolation so regressions surface with a clear failure
 * mode.
 */

import { describe, expect, it } from 'vitest'
import { canonicalJson } from './canonicalize.js'
import { intLit } from './numeric-literal.js'
import {
  DEFAULT_MAX_PASSES,
  E_PATTERN_VAR_UNBOUND,
  E_RULES_NOT_CONVERGED,
  E_UNKNOWN_GUARD,
  E_UNREWRITTEN_PDE_OP,
  RuleEngineError,
  applyBindings,
  checkGuard,
  checkUnrewrittenPdeOps,
  emptyContext,
  matchPattern,
  parseExpr,
  parseRules,
  rewrite,
  type Guard,
  type Rule,
} from './rule-engine.js'

function op(name: string, args: unknown[], extra: Record<string, unknown> = {}) {
  return { op: name, args, ...extra } as never
}

describe('rule engine — matchPattern', () => {
  it('binds a bare pattern var to a subtree', () => {
    const m = matchPattern('$a' as never, 'x' as never)
    expect(m).not.toBeNull()
    expect(m!.get('$a')).toBe('x')
  })

  it('rejects mismatched operator names', () => {
    expect(
      matchPattern(op('+', ['$a', 0]) as never, op('-', ['x', 0]) as never),
    ).toBeNull()
  })

  it('enforces non-linear binding equality (§5.2.2)', () => {
    const pat = op('-', ['$a', '$a']) as never
    expect(matchPattern(pat, op('-', ['x', 'x']) as never)).not.toBeNull()
    expect(matchPattern(pat, op('-', ['x', 'y']) as never)).toBeNull()
  })

  it('binds a sibling-field pvar as a bare name', () => {
    const pat = op('D', ['$u'], { wrt: '$x' }) as never
    const m = matchPattern(pat, op('D', ['T'], { wrt: 't' }) as never)
    expect(m).not.toBeNull()
    expect(m!.get('$u')).toBe('T')
    expect(m!.get('$x')).toBe('t')
  })
})

describe('rule engine — applyBindings', () => {
  it('substitutes pattern vars into the template', () => {
    const b = new Map<string, unknown>([
      ['$a', 'x'],
      ['$b', intLit(3)],
    ]) as never
    const out = applyBindings(op('+', ['$a', '$b']) as never, b)
    // Canonicalize sorts + args: numeric leaf before string (§5.4.2).
    expect(canonicalJson(out)).toBe('{"args":[3,"x"],"op":"+"}')
  })

  it('throws E_PATTERN_VAR_UNBOUND when a pvar is missing', () => {
    try {
      applyBindings('$a' as never, new Map() as never)
      throw new Error('expected throw')
    } catch (e) {
      expect(e).toBeInstanceOf(RuleEngineError)
      expect((e as RuleEngineError).code).toBe(E_PATTERN_VAR_UNBOUND)
    }
  })
})

describe('rule engine — rewrite', () => {
  const addZero: Rule = {
    name: 'add_zero_int',
    pattern: op('+', ['$a', intLit(0)]) as never,
    where: [],
    replacement: '$a' as never,
  }

  it('fires once and converges (match_once)', () => {
    const out = rewrite(op('+', ['x', intLit(0)]) as never, [addZero])
    expect(canonicalJson(out)).toBe('"x"')
  })

  it('seals the rewritten subtree for the rest of the pass (§5.2.5)', () => {
    // ((x+x)+(x+x)) — rule $a+$a -> 2*$a fires at root first, then
    // the next pass fires on the new inner (x+x).
    const double: Rule = {
      name: 'double',
      pattern: op('+', ['$a', '$a']) as never,
      where: [],
      replacement: op('*', [intLit(2), '$a']) as never,
    }
    const inner = op('+', ['x', 'x'])
    const seed = op('+', [inner, inner])
    const out = rewrite(seed as never, [double])
    // canonicalize groups identical factors; the outer 2 is a numeric
    // leaf sorted before the * node.
    const want = op('*', [intLit(2), op('*', [intLit(2), 'x'])])
    expect(canonicalJson(out)).toBe(canonicalJson(want as never))
  })

  it('raises E_RULES_NOT_CONVERGED when the fixed point recedes', () => {
    const explode: Rule = {
      name: 'expand',
      pattern: '$a' as never,
      where: [],
      replacement: op('+', ['$a', intLit(0)]) as never,
    }
    try {
      rewrite('x' as never, [explode], emptyContext(), 3)
      throw new Error('expected throw')
    } catch (e) {
      expect(e).toBeInstanceOf(RuleEngineError)
      expect((e as RuleEngineError).code).toBe(E_RULES_NOT_CONVERGED)
    }
  })
})

describe('rule engine — guards', () => {
  it('var_has_grid binds a pvar grid field when unbound', () => {
    const g: Guard = {
      name: 'var_has_grid',
      params: { pvar: '$u', grid: '$g' },
    }
    const ctx = emptyContext()
    ctx.variables.T = { grid: 'atmos_rect' }
    const b = new Map<string, unknown>([['$u', 'T']]) as never
    const r = checkGuard(g, b, ctx)
    expect(r).not.toBeNull()
    expect(r!.get('$g')).toBe('atmos_rect')
  })

  it('dim_is_spatial_dim_of matches against grid metadata', () => {
    const g: Guard = {
      name: 'dim_is_spatial_dim_of',
      params: { pvar: 'x', grid: 'g1' },
    }
    const ctx = emptyContext()
    ctx.grids.g1 = { spatial_dims: ['x', 'y'] }
    expect(checkGuard(g, new Map() as never, ctx)).not.toBeNull()
    const g2: Guard = {
      name: 'dim_is_spatial_dim_of',
      params: { pvar: 'z', grid: 'g1' },
    }
    expect(checkGuard(g2, new Map() as never, ctx)).toBeNull()
  })

  it('throws E_UNKNOWN_GUARD for names outside the §5.2.4 closed set', () => {
    try {
      checkGuard({ name: 'made_up', params: {} }, new Map() as never, emptyContext())
      throw new Error('expected throw')
    } catch (e) {
      expect(e).toBeInstanceOf(RuleEngineError)
      expect((e as RuleEngineError).code).toBe(E_UNKNOWN_GUARD)
    }
  })
})

describe('rule engine — parseRules / parseExpr', () => {
  it('accepts both object and array rule forms (§5.2.5)', () => {
    const obj = {
      a: { pattern: { op: '+', args: ['$x', 0] }, replacement: '$x' },
    }
    const rs = parseRules(obj)
    expect(rs).toHaveLength(1)
    expect(rs[0]!.name).toBe('a')

    const arr = [
      { name: 'first', pattern: { op: '*', args: ['$a', 0] }, replacement: 0 },
      { name: 'second', pattern: { op: '+', args: ['$a', 0] }, replacement: '$a' },
    ]
    const rs2 = parseRules(arr)
    expect(rs2.map((r) => r.name)).toEqual(['first', 'second'])
  })

  it('preserves wrt/dim on operator nodes', () => {
    const e = parseExpr({ op: 'D', args: ['T'], wrt: 't' })
    expect(canonicalJson(e)).toBe('{"args":["T"],"op":"D","wrt":"t"}')
  })
})

describe('rule engine — checkUnrewrittenPdeOps', () => {
  it('flags leftover PDE ops with E_UNREWRITTEN_PDE_OP', () => {
    try {
      checkUnrewrittenPdeOps(op('grad', ['T'], { dim: 'x' }) as never)
      throw new Error('expected throw')
    } catch (e) {
      expect(e).toBeInstanceOf(RuleEngineError)
      expect((e as RuleEngineError).code).toBe(E_UNREWRITTEN_PDE_OP)
    }
  })

  it('accepts expressions with only non-PDE ops', () => {
    expect(() =>
      checkUnrewrittenPdeOps(op('index', ['T', 'x']) as never),
    ).not.toThrow()
  })
})

describe('rule engine — defaults', () => {
  it('DEFAULT_MAX_PASSES is 32 per RFC §5.2.5', () => {
    expect(DEFAULT_MAX_PASSES).toBe(32)
  })
})

// RFC §5.2.8 / §7 (esm-bet) — boundary_policy + ghost_width fields.
describe('rule engine — boundary_policy + ghost_width (esm-bet)', () => {
  function parseOne(rule: object) {
    const rs = parseRules([rule])
    expect(rs).toHaveLength(1)
    return rs[0]!
  }

  it('accepts every string-form boundary_policy kind', () => {
    for (const kind of [
      'periodic',
      'reflecting',
      'one_sided_extrapolation',
      'prescribed',
      'ghosted',
      'neumann_zero',
      'extrapolate',
    ]) {
      const r = parseOne({
        name: 'r',
        pattern: '$a',
        replacement: '$a',
        boundary_policy: kind,
      })
      expect(r.boundaryPolicy).toBe(kind)
    }
  })

  it('rejects unknown string-form boundary_policy', () => {
    try {
      parseRules([
        { name: 'r', pattern: '$a', replacement: '$a', boundary_policy: 'nope' },
      ])
      throw new Error('expected throw')
    } catch (e) {
      expect(e).toBeInstanceOf(RuleEngineError)
    }
  })

  it('parses per-axis one_sided_extrapolation with degree', () => {
    const r = parseOne({
      name: 'r',
      pattern: '$a',
      replacement: '$a',
      boundary_policy: {
        by_axis: { x: { kind: 'one_sided_extrapolation', degree: 2 } },
      },
    })
    const bp = r.boundaryPolicy as { by_axis: Record<string, { kind: string; degree?: number }> }
    expect(bp.by_axis.x!.kind).toBe('one_sided_extrapolation')
    expect(bp.by_axis.x!.degree).toBe(2)
  })

  it('rejects out-of-range degree', () => {
    try {
      parseRules([
        {
          name: 'r',
          pattern: '$a',
          replacement: '$a',
          boundary_policy: {
            by_axis: { x: { kind: 'one_sided_extrapolation', degree: 5 } },
          },
        },
      ])
      throw new Error('expected throw')
    } catch (e) {
      expect(e).toBeInstanceOf(RuleEngineError)
    }
  })

  it('parses ghost_width scalar form', () => {
    const r = parseOne({
      name: 'r',
      pattern: '$a',
      replacement: '$a',
      ghost_width: 3,
    })
    expect(r.ghostWidth).toBe(3)
  })

  it('parses ghost_width per-axis form', () => {
    const r = parseOne({
      name: 'r',
      pattern: '$a',
      replacement: '$a',
      ghost_width: { by_axis: { xi: 3, eta: 2 } },
    })
    const gw = r.ghostWidth as { by_axis: Record<string, number> }
    expect(gw.by_axis.xi).toBe(3)
    expect(gw.by_axis.eta).toBe(2)
  })

  it('rejects negative ghost_width', () => {
    try {
      parseRules([
        { name: 'r', pattern: '$a', replacement: '$a', ghost_width: -1 },
      ])
      throw new Error('expected throw')
    } catch (e) {
      expect(e).toBeInstanceOf(RuleEngineError)
    }
  })

  it('rejects string ghost_width', () => {
    try {
      parseRules([
        { name: 'r', pattern: '$a', replacement: '$a', ghost_width: '3' },
      ])
      throw new Error('expected throw')
    } catch (e) {
      expect(e).toBeInstanceOf(RuleEngineError)
    }
  })
})
