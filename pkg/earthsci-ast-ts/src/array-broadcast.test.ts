/**
 * The two array-level structural rules of esm-spec §4.3.4:
 * `invalid_broadcast_fn` and `array_shape_mismatch`.
 *
 * Both are pinned by the SHARED corpus (`tests/invalid/expected_errors.json`),
 * so the fixture-driven cases below assert the exact `(path, code)` pairs the
 * cross-binding comparator diffs. The inline cases cover the boundaries the
 * corpus does not spell out — which `fn` names are admissible, which operand
 * positions alignment descends into — because those are where a binding drifts
 * from the others without any fixture noticing.
 */

import { describe, it, expect } from 'vitest'
import { validate } from './validate.js'
import { checkArity, checkBroadcastFn, getOpInfo } from './op-registry.js'
import { readFixture } from './test-helpers.js'
import type { EsmFile, Expression } from './types.js'

/** A one-state model whose single equation is `D(x) ~ rhs`. */
function scalarModel(rhs: Expression): EsmFile {
  return {
    esm: '0.1.0',
    metadata: { name: 'BroadcastFnTest' },
    models: {
      TestModel: {
        variables: { x: { type: 'state', units: 'm', default: 1.0 } },
        equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs }],
      },
    },
  } as unknown as EsmFile
}

/**
 * A `[lon,lat,lev]` state `dp` driven by `rhs`, plus one observed operand per
 * entry of `operandShapes`. Each operand's defining expression is an
 * `aggregate` over its own axes — the spelling that DECLARES a frame without
 * itself being an array-level expression.
 */
function arrayModel(rhs: Expression, operandShapes: Record<string, string[]>): EsmFile {
  const variables: Record<string, unknown> = {
    dp: { type: 'state', units: '1', shape: ['lon', 'lat', 'lev'], default: 0.0 },
  }
  for (const [name, shape] of Object.entries(operandShapes)) {
    const idx = shape.map((_, i) => `i${i}`)
    variables[name] = {
      type: 'observed',
      units: '1',
      shape,
      expression: {
        op: 'aggregate',
        args: [],
        output_idx: idx,
        ranges: Object.fromEntries(idx.map((s, i) => [s, { from: shape[i] }])),
        expr: { op: '*', args: [1, idx[0]] },
      },
    }
  }
  return {
    esm: '0.9.0',
    metadata: { name: 'ArrayShapeTest' },
    index_sets: {
      lon: { kind: 'interval', size: 3 },
      lat: { kind: 'interval', size: 2 },
      lev: { kind: 'interval', size: 2 },
      spc: { kind: 'interval', size: 4 },
    },
    models: {
      M: {
        variables,
        equations: [{ lhs: { op: 'D', args: ['dp'], wrt: 't' }, rhs }],
      },
    },
  } as unknown as EsmFile
}

/** `(code, path)` pairs — the pair the cross-binding comparator diffs. */
function findings(file: EsmFile): string[] {
  const result = validate(file)
  return result.structural_errors.map((e) => `${e.code} @ ${e.path}`)
}

describe('invalid_broadcast_fn (esm-spec §4.3.4)', () => {
  it('rejects the shared fixture at the pinned path, code and message', () => {
    const result = validate(readFixture('invalid', 'broadcast_fn_unregistered.esm'))

    expect(result.is_valid).toBe(false)
    const found = result.structural_errors.filter((e) => e.code === 'invalid_broadcast_fn')
    expect(found).toHaveLength(1)
    expect(found[0].path).toBe('/models/TestModel/equations/0/rhs')
    expect(found[0].message).toBe(
      "'broadcast' fn 'not_a_real_op' does not name a scalar operator (esm-spec §4.3.4)",
    )
    expect(found[0].details).toEqual({ broadcast_fn: 'not_a_real_op', equation_index: 0 })
  })

  it('rejects an ABSENT fn — there is no default, so `+` must not be assumed', () => {
    // Rejected at BOTH layers, like Rust. The schema's `if op == broadcast then
    // required: [fn]` rule fires first and short-circuits the structural pass,
    // so the document-level assertion is a schema error; the structural rule is
    // asserted directly below, because it is what protects a caller that
    // reaches the checker with an already-parsed tree.
    const result = validate(scalarModel({ op: 'broadcast', args: ['x'] } as Expression))
    expect(result.is_valid).toBe(false)
    expect(result.schema_errors.map((e) => e.message)).toContain("must have required property 'fn'")

    const violation = checkBroadcastFn({ op: 'broadcast', args: ['x'] })
    expect(violation?.details).toEqual({ broadcast_fn: null })
    expect(violation?.message).toContain("missing its 'fn'")
  })

  it.each([
    'aggregate',
    'makearray',
    'index',
    'broadcast',
    'reshape',
    'transpose',
    'concat',
    'fn',
    'D',
    'ic',
    'Pre',
    'const',
    'enum',
    'table_lookup',
    'apply_expression_template',
    'skolem',
    'rank',
    'argmin',
    'intersect_polygon',
    'polygon_intersection_area',
    '=',
    'pow',
    'grad',
  ])('rejects the NON-scalar fn %s', (fn) => {
    expect(findings(scalarModel({ op: 'broadcast', fn, args: ['x'] } as Expression))).toContain(
      'invalid_broadcast_fn @ /models/TestModel/equations/0/rhs',
    )
  })

  it.each([
    ['min', 1],
    ['max', 1],
    ['sin', 2],
    ['atan2', 1],
    ['ifelse', 2],
    ['^', 1],
    ['and', 1],
    ['or', 1],
  ])('rejects fn %s at arity %i', (fn, argc) => {
    const args = Array.from({ length: argc as number }, () => 'x')
    const result = validate(scalarModel({ op: 'broadcast', fn, args } as Expression))
    const found = result.structural_errors.filter((e) => e.code === 'invalid_broadcast_fn')
    expect(found).toHaveLength(1)
    expect(found[0].message).toContain(`'broadcast' fn '${fn}' takes`)
    expect(found[0].details.got).toBe(argc)
  })

  it.each(['+', '*', '-', 'neg', 'log', 'ln', 'sqrt', 'exp', 'not', 'abs'])(
    'accepts the UNARY application broadcast(fn: %s, [x])',
    (fn) => {
      // `broadcast(fn:'+', [x])` is `x` and `broadcast(fn:'-', [x])` is `-x`,
      // for exactly the reason the bare `+(x)` / `-(x)` nodes are legal. The
      // bound comes from the registry row, never from a hardcoded "at least 2".
      expect(findings(scalarModel({ op: 'broadcast', fn, args: ['x'] } as Expression))).toEqual([])
    },
  )

  it.each(['expr_039', 'expr_040'])(
    'accepts the property-corpus 1-operand broadcast(fn:"+") in %s',
    (name) => {
      const expr = JSON.parse(readFixture('property_corpus', 'expressions', `${name}.json`))
      expect(findings(scalarModel(expr as Expression))).toEqual([])
    },
  )

  it('checks broadcast nodes OUTSIDE equations too (an observed expression)', () => {
    const file = {
      esm: '0.1.0',
      metadata: { name: 'Sidecar' },
      models: {
        M: {
          variables: {
            x: { type: 'state', units: 'm', default: 1.0 },
            y: {
              type: 'observed',
              units: 'm',
              expression: { op: 'broadcast', fn: 'nope', args: ['x'] },
            },
          },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 0 }],
        },
      },
    } as unknown as EsmFile
    expect(findings(file)).toContain('invalid_broadcast_fn @ /models/M/variables/y/expression')
  })
})

describe('registry arity floors are the cross-binding ones (esm-spec §4.2)', () => {
  // These four bounds are what `checkBroadcastFn` derives the legal operand
  // count from, so a drift here silently changes which documents this binding
  // accepts relative to Rust / Julia / Python. Pinned as VALUES, with the
  // agreeing bindings named, so a future edit has to argue with the other three.
  it.each([
    // op, min, max — Rust op_registry.rs, Julia op_registry.jl, Python op_registry.py
    ['+', 1, null], // n-ary FROM ONE operand; an empty sum denotes nothing
    ['*', 1, null],
    ['and', 2, null], // a connective needs two things to connect
    ['or', 2, null],
  ])('%s is %i..%s', (op, min, max) => {
    expect(getOpInfo(op as string)?.arity).toEqual({ min, max })
  })

  it.each(['+', '*', 'and', 'or'])('checkArity rejects a degenerate %s node', (op) => {
    const below = op === 'and' || op === 'or' ? 1 : 0
    expect(() => checkArity(op, below)).toThrow(/requires at least/)
  })
})

describe('array_shape_mismatch (esm-spec §4.3.4 "Broadcast compatibility")', () => {
  it('rejects the shared fixture at the pinned path, code, message and details', () => {
    const result = validate(
      readFixture('invalid', 'array_broadcast', 'operand_index_set_not_in_result.esm'),
    )

    expect(result.is_valid).toBe(false)
    const found = result.structural_errors.filter((e) => e.code === 'array_shape_mismatch')
    expect(found).toHaveLength(1)
    expect(found[0].path).toBe('/models/OperandIndexSetNotInResult/equations/0/rhs')
    expect(found[0].message).toBe(
      "Operand 'z1' of the array-level expression for 'dp' is declared over index set " +
        "'lev', which 'dp' is not shaped over",
    )
    expect(found[0].details).toEqual({
      variable: 'dp',
      operand: 'z1',
      operand_shape: ['lev'],
      result_shape: ['lon', 'lat'],
      missing_index_set: 'lev',
    })
  })

  it.each([
    'bare_rank_lift.esm',
    'bare_mixed_rank_product.esm',
    'bare_axis_permuted_operand.esm',
    'broadcast_node_mixed_rank.esm',
  ])('accepts the alignable fixture %s', (name) => {
    const result = validate(readFixture('valid', 'array_broadcast', name))
    expect(result.structural_errors).toEqual([])
    expect(result.is_valid).toBe(true)
  })

  it('accepts a SUBSET operand and one whose axis ORDER differs (it transposes)', () => {
    expect(
      findings(
        arrayModel({ op: '*', args: ['w', 'wT'] } as Expression, {
          w: ['lat'],
          wT: ['lat', 'lon'],
        }),
      ),
    ).toEqual([])
  })

  it('rejects an operand carrying an index set the result does not have', () => {
    expect(
      findings(
        arrayModel({ op: '*', args: ['w', 'bad'] } as Expression, { w: ['lat'], bad: ['spc'] }),
      ),
    ).toEqual(['array_shape_mismatch @ /models/M/equations/0/rhs'])
  })

  it('sees THROUGH a broadcast node to its args (the two spellings must agree)', () => {
    // The bare spelling and the `broadcast` spelling denote the same thing, so
    // aligning one and not the other is the very divergence the rule closes.
    expect(
      findings(
        arrayModel({ op: 'broadcast', fn: '*', args: ['bad'] } as Expression, { bad: ['spc'] }),
      ),
    ).toEqual(['array_shape_mismatch @ /models/M/equations/0/rhs'])
  })

  it.each(['aggregate', 'index', 'reshape', 'transpose', 'concat', 'makearray'])(
    'does NOT descend into %s — those consume their operands whole',
    (op) => {
      expect(findings(arrayModel({ op, args: ['bad'] } as Expression, { bad: ['spc'] }))).toEqual(
        [],
      )
    },
  )

  it('leaves an INDEXED equation LHS alone (a per-cell equation spells its own axes)', () => {
    const file = arrayModel('bad' as Expression, { bad: ['spc'] })
    const model = (file.models as Record<string, { equations: { lhs: unknown }[] }>).M
    model.equations[0].lhs = { op: 'D', args: [{ op: 'index', args: ['dp', 'i', 'j', 'k'] }] }
    expect(findings(file)).toEqual([])
  })

  it('leaves an ANONYMOUS operand alone — no declared shape names no axes', () => {
    const file = arrayModel({ op: '*', args: ['dp', 'anon'] } as Expression, {})
    const model = (file.models as Record<string, { variables: Record<string, unknown> }>).M
    // Declared, but with no `shape`: it names no axes, so §4.3.4 regime 2
    // (positional) governs it and there is nothing to align by name.
    model.variables.anon = { type: 'parameter', units: '1', default: 1.0 }
    expect(findings(file)).toEqual([])
  })
})
