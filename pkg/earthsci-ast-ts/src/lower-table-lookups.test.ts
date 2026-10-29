/**
 * `table_lookup` lowering ON THE EVALUATION PATH — esm-spec §9.5.3 / §9.5.3a /
 * §9.5.4.
 *
 * The bug these tests pin (issue #188): the §9.5.3 lowering existed only inside
 * `function-tables-lowering.test.ts`'s own harness, so a document whose observed
 * is defined by a `table_lookup` loaded, validated and round-tripped fine and
 * then failed EVERY evaluation that depended on it — while the identical lookup
 * written out by hand in the lowered form evaluated. The
 * `conformance/function_tables/inline_test` fixture is exactly that document
 * (`y` authored, `z` hand-lowered, `w` clamping), and these tests drive it
 * through the PRODUCTION evaluator (`evaluateExpression`), not a local
 * re-implementation.
 *
 * The other half of the contract is that the lowering must NOT happen at load:
 * §9.5.4 makes the authored forms round-trip, which the last `describe` pins.
 */
import { describe, it, expect } from 'vitest'
import { evaluateExpression } from './codegen.js'
import { dispatchClosedFunction } from './closed-functions.js'
import { getOpInfo } from './op-registry.js'
import { deepEqualExpr } from './expression.js'
import { ERROR_CODES } from './errors.js'
import {
  lowerTableLookups,
  TableLookupLoweringError,
  type FunctionTables,
} from './lower-table-lookups.js'
import { toJson } from './serialize.js'
import { loadFixture } from './test-helpers.js'
import type { EsmFile, Expr, ExprNodeOf, FunctionTable, Model } from './types.js'

function fixture(scenario: string): EsmFile {
  return loadFixture('conformance', 'function_tables', scenario, 'fixture.esm')
}

function modelOf(file: EsmFile, name: string): Model {
  return file.models![name] as Model
}

function tablesOf(file: EsmFile): FunctionTables | undefined {
  return file.function_tables
}

/** The RHS of the equation whose LHS is the bare variable `name`. */
function definitionOf(model: Model, name: string): Expr {
  const eq = model.equations.find((e) => e.lhs === name)
  if (eq === undefined) throw new Error(`no bare-LHS equation defines ${name}`)
  return eq.rhs
}

/** Declared variable defaults, overridden by a test case's `parameter_overrides`. */
function bindingsFor(model: Model, overrides: Record<string, unknown> = {}): Map<string, number> {
  const bindings = new Map<string, number>()
  for (const [name, variable] of Object.entries(model.variables)) {
    if (typeof variable.default === 'number') bindings.set(name, variable.default)
  }
  for (const [name, value] of Object.entries(overrides)) {
    if (typeof value === 'number') bindings.set(name, value)
  }
  return bindings
}

/** The §9.5.5 diagnostic code `fn` raises, or `'NO_ERROR'`. Rethrows anything else. */
function loweringErrorCode(fn: () => unknown): string {
  try {
    fn()
    return 'NO_ERROR'
  } catch (e) {
    if (e instanceof TableLookupLoweringError) return e.code
    throw e
  }
}

/** A `function_tables` block written inline; `data` is an untyped nested array. */
function tables(block: unknown): FunctionTables {
  return block as FunctionTables
}

/** Operator-node view of a lowered expression. */
function nodeOf(expr: Expr): ExprNodeOf {
  return expr as ExprNodeOf
}

/** The `value` an `{op: "const"}` node carries. */
function constValue(expr: Expr): unknown {
  return nodeOf(expr).value
}

/** A table's `data` literal — the generated type is json2ts's untyped object map. */
function dataOf(table: FunctionTable): unknown[] {
  return table.data as unknown as unknown[]
}

describe('inline_test fixture: an authored table_lookup evaluates (esm-spec §9.5.3, issue #188)', () => {
  const file = fixture('inline_test')
  const model = modelOf(file, 'TableLookupObserved')
  const testCase = model.tests![0]
  const bindings = bindingsFor(model, testCase.parameter_overrides ?? {})

  // The fixture's own inline-`tests` assertions are the pin, read from the
  // fixture rather than restated here so the two cannot drift. The TypeScript
  // binding has no ODE solver, so this evaluates the three OBSERVED definitions
  // directly — which is the whole of what these assertions exercise (`x`, the
  // only integrated state, has a constant zero tendency and is not asserted).
  for (const assertion of testCase.assertions as Array<{ variable: string; expected: number }>) {
    it(`evaluates observed \`${assertion.variable}\` to ${assertion.expected}`, () => {
      const actual = evaluateExpression(definitionOf(model, assertion.variable), bindings, {
        functionTables: tablesOf(file),
      })
      expect(actual).toBe(assertion.expected)
    })
  }

  it('lowers the authored `y` to exactly the hand-written tree of `z` (§9.5.3)', () => {
    // Structural identity, not just numeric agreement: the lowered form IS the
    // inline-const spelling, which is what makes the two bit-equivalent for
    // every input rather than for the one this fixture happens to test.
    const lowered = lowerTableLookups(definitionOf(model, 'y'), tablesOf(file))
    expect(deepEqualExpr(lowered, definitionOf(model, 'z'))).toBe(true)
  })

  it('lowers the clamping `w` against the same table and axis consts as `y`', () => {
    const y = nodeOf(lowerTableLookups(definitionOf(model, 'y'), tablesOf(file)))
    const w = nodeOf(lowerTableLookups(definitionOf(model, 'w'), tablesOf(file)))
    expect(w.name).toBe('interp.linear')
    expect(w.name).toBe(y.name)
    expect(deepEqualExpr(w.args[0], y.args[0])).toBe(true) // data slice
    expect(deepEqualExpr(w.args[1], y.args[1])).toBe(true) // axis knots
    // Only the input expression differs — `p_hi` sits above the last knot, so
    // the §9.5.1 default `clamp` holds the last table value (asserted above).
    expect(w.args[2]).toBe('p_hi')
    expect(y.args[2]).toBe('p')
  })

  it('is idempotent: a lowered tree lowers to itself', () => {
    const once = lowerTableLookups(definitionOf(model, 'y'), tablesOf(file))
    expect(lowerTableLookups(once, tablesOf(file))).toBe(once)
  })
})

describe('out_of_bounds_error fixture: `error` mode is refused, not clamped (esm-spec §9.5.3a)', () => {
  it('loads cleanly — the document is valid and §9.5.5 names no load-time diagnostic', () => {
    const file = fixture('out_of_bounds_error')
    expect(tablesOf(file)!.strict_tab.out_of_bounds).toBe('error')
    expect(modelOf(file, 'M').equations[0].rhs).toMatchObject({ op: 'table_lookup' })
  })

  it('refuses the lookup with `table_out_of_bounds_unsupported` at lowering', () => {
    const file = fixture('out_of_bounds_error')
    const rhs = definitionOf(modelOf(file, 'M'), 'y')
    expect(loweringErrorCode(() => lowerTableLookups(rhs, tablesOf(file)))).toBe(
      ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED,
    )
  })

  it('refuses it on the evaluation path too, rather than answering under clamp', () => {
    const file = fixture('out_of_bounds_error')
    const model = modelOf(file, 'M')
    const rhs = definitionOf(model, 'y')
    expect(
      loweringErrorCode(() =>
        evaluateExpression(rhs, bindingsFor(model), { functionTables: tablesOf(file) }),
      ),
    ).toBe(ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED)
  })

  it("checks the lookup's own fields before refusing `error` mode (esm-spec §9.5.5, ruling Q-107)", () => {
    const block = tables({
      T: { axes: [{ name: 'x', values: [0, 1] }], data: [1, 2], out_of_bounds: 'error' },
    })
    const lookup = (fields: object) => ({ op: 'table_lookup', table: 'T', ...fields }) as Expr
    expect(loweringErrorCode(() => lowerTableLookups(lookup({ axes: { y: 0.5 } }), block))).toBe(
      ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
    )
    expect(
      loweringErrorCode(() => lowerTableLookups(lookup({ axes: { x: 0.5 }, output: 3 }), block)),
    ).toBe(ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE)
    expect(loweringErrorCode(() => lowerTableLookups(lookup({ axes: { x: 0.5 } }), block))).toBe(
      ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED,
    )
  })

  it('still round-trips the refused document verbatim (§9.5.4)', () => {
    const file = fixture('out_of_bounds_error')
    const reloaded = JSON.parse(toJson(file)) as {
      function_tables: { strict_tab: { out_of_bounds: string } }
      models: { M: { equations: Array<{ rhs: { op: string } }> } }
    }
    expect(reloaded.function_tables.strict_tab.out_of_bounds).toBe('error')
    expect(reloaded.models.M.equations[0].rhs.op).toBe('table_lookup')
  })
})

describe('the §9.5.3 lowered form', () => {
  it("puts the bilinear axis consts in the table's DECLARED axis order", () => {
    const file = fixture('bilinear')
    const model = modelOf(file, 'M')
    const byName = nodeOf(lowerTableLookups(model.equations[0].rhs, tablesOf(file)))
    expect(byName.op).toBe('fn')
    expect(byName.name).toBe('interp.bilinear')
    const table = tablesOf(file)!.F_actinic
    expect(constValue(byName.args[0])).toEqual(dataOf(table)[0])
    expect(constValue(byName.args[1])).toEqual(table.axes[0].values)
    expect(constValue(byName.args[2])).toEqual(table.axes[1]!.values)
    expect(byName.args[3]).toBe('P_atm')
    expect(byName.args[4]).toBe('cos_sza')
  })

  it('resolves `output` by NAME and by INDEX to the same row of `data`', () => {
    const file = fixture('bilinear')
    const model = modelOf(file, 'M')
    // eq 0 selects output "NO2" by name; eq 1 selects index 1.
    const byName = nodeOf(lowerTableLookups(model.equations[0].rhs, tablesOf(file)))
    const byIndex = nodeOf(lowerTableLookups(model.equations[1].rhs, tablesOf(file)))
    const data = dataOf(tablesOf(file)!.F_actinic)
    expect(constValue(byName.args[0])).toEqual(data[0])
    expect(constValue(byIndex.args[0])).toEqual(data[1])
  })

  it('lowers BOTTOM-UP, so a table_lookup nested in an axis input is lowered too', () => {
    const block = tables({
      outer: { axes: [{ name: 'q', values: [1, 2] }], data: [5, 6] },
      inner: { axes: [{ name: 'p', values: [1, 2] }], data: [1, 2] },
    })
    const lowered = lowerTableLookups(
      {
        op: 'table_lookup',
        table: 'outer',
        args: [],
        axes: {
          q: { op: 'table_lookup', table: 'inner', axes: { p: 'p_in' }, args: [] },
        },
      },
      block,
    )
    expect(nodeOf(lowered).name).toBe('interp.linear')
    expect(nodeOf(nodeOf(lowered).args[2]).name).toBe('interp.linear')
  })

  it('leaves an expression carrying no table_lookup untouched, by identity', () => {
    const expr: Expr = { op: '+', args: ['x', 1] }
    expect(lowerTableLookups(expr, undefined)).toBe(expr)
  })
})

describe('§9.5.5 diagnostics', () => {
  const block = tables({
    t: {
      axes: [{ name: 'p', values: [1, 2, 3, 4] }],
      interpolation: 'linear',
      outputs: ['a', 'b'],
      data: [
        [10, 20, 30, 40],
        [11, 21, 31, 41],
      ],
    },
  })
  const lookup = (extra: Record<string, unknown> = {}): Expr =>
    ({ op: 'table_lookup', table: 't', axes: { p: 'p_in' }, args: [], ...extra }) as Expr

  it('names an undeclared table `table_lookup_unknown_table`', () => {
    expect(loweringErrorCode(() => lowerTableLookups(lookup({ table: 'nope' }), block))).toBe(
      ERROR_CODES.TABLE_LOOKUP_UNKNOWN_TABLE,
    )
  })

  it('reports the same code when the document declares no function_tables at all', () => {
    // The evaluator's fallback: without the document's block in hand, no table
    // the node could name is in scope.
    expect(loweringErrorCode(() => lowerTableLookups(lookup(), undefined))).toBe(
      ERROR_CODES.TABLE_LOOKUP_UNKNOWN_TABLE,
    )
  })

  it('names a misspelled axis key `table_lookup_axis_name_mismatch`', () => {
    expect(loweringErrorCode(() => lowerTableLookups(lookup({ axes: { q: 'p_in' } }), block))).toBe(
      ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
    )
  })

  it('names an EXTRA axis key `table_lookup_axis_name_mismatch` (key sets match exactly)', () => {
    expect(
      loweringErrorCode(() => lowerTableLookups(lookup({ axes: { p: 'p_in', q: 1 } }), block)),
    ).toBe(ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH)
  })

  it('names positional `args` on a table_lookup `table_lookup_args_nonempty`', () => {
    expect(loweringErrorCode(() => lowerTableLookups(lookup({ args: ['p_in'] }), block))).toBe(
      ERROR_CODES.TABLE_LOOKUP_ARGS_NONEMPTY,
    )
  })

  it('reads an absent `args` as `[]` (esm-spec §9.5.2)', () => {
    const node = { op: 'table_lookup', table: 't', axes: { p: 'p_in' } } as unknown as Expr
    const withArgs = lowerTableLookups(lookup(), block)
    expect(lowerTableLookups(node, block)).toEqual(withArgs)
  })

  it('names an out-of-range output index `table_lookup_output_out_of_range`', () => {
    expect(loweringErrorCode(() => lowerTableLookups(lookup({ output: 7 }), block))).toBe(
      ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
    )
  })

  it('names an unknown output NAME `table_lookup_output_out_of_range`', () => {
    expect(loweringErrorCode(() => lowerTableLookups(lookup({ output: 'z' }), block))).toBe(
      ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
    )
  })

  it('rejects a non-zero output on a single-output table (no leading `data` dimension)', () => {
    const single = tables({ t: { axes: [{ name: 'p', values: [1, 2] }], data: [10, 20] } })
    expect(loweringErrorCode(() => lowerTableLookups(lookup({ output: 1 }), single))).toBe(
      ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
    )
  })

  it.each(['a', '0'])('rejects any string output (%s) on a single-output table', (name) => {
    const single = tables({ t: { axes: [{ name: 'p', values: [1, 2] }], data: [10, 20] } })
    expect(loweringErrorCode(() => lowerTableLookups(lookup({ output: name }), single))).toBe(
      ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
    )
  })

  it.each([undefined, 0])(
    'lowers a single-output table with the WHOLE `data` for output %s (esm-spec §9.5.3)',
    (output) => {
      const single = tables({ t: { axes: [{ name: 'p', values: [1, 2] }], data: [10, 20] } })
      const node = nodeOf(lowerTableLookups(lookup(output === undefined ? {} : { output }), single))
      expect(constValue(node.args[0])).toEqual([10, 20])
    },
  )

  it('reads an omitted output on a multi-output table as output 0', () => {
    const omitted = nodeOf(lowerTableLookups(lookup(), block))
    const zero = nodeOf(lowerTableLookups(lookup({ output: 0 }), block))
    expect(constValue(omitted.args[0])).toEqual([10, 20, 30, 40])
    expect(omitted).toEqual(zero)
  })

  it('names an interpolation/axis-count disagreement `table_interpolation_axes_mismatch`', () => {
    const oneAxisBilinear = tables({
      t: { axes: [{ name: 'p', values: [1, 2] }], interpolation: 'bilinear', data: [10, 20] },
    })
    expect(loweringErrorCode(() => lowerTableLookups(lookup(), oneAxisBilinear))).toBe(
      ERROR_CODES.TABLE_INTERPOLATION_AXES_MISMATCH,
    )
  })

  // esm-spec §9.5.5: the table is checked before the lookup, so even output
  // `a` (whose row exists) is refused, and `outputs` vs the leading dimension
  // of `data` is its own code.
  it.each(['a', 'b'])(
    'names a `data` block shorter than `outputs` `table_outputs_length_mismatch` (output %s)',
    (output) => {
      const short = tables({
        t: { axes: [{ name: 'p', values: [1, 2] }], outputs: ['a', 'b'], data: [[10, 20]] },
      })
      expect(loweringErrorCode(() => lowerTableLookups(lookup({ output }), short))).toBe(
        ERROR_CODES.TABLE_OUTPUTS_LENGTH_MISMATCH,
      )
    },
  )

  it('checks the table before the lookup: a broken table beats a misspelled axis key', () => {
    const bad = tables({ t: { axes: [{ name: 'p', values: [2, 1] }], data: [10, 20] } })
    expect(loweringErrorCode(() => lowerTableLookups(lookup({ axes: { q: 1 } }), bad))).toBe(
      ERROR_CODES.TABLE_AXIS_NON_MONOTONIC,
    )
  })

  it('checks the table before refusing `out_of_bounds: "error"`', () => {
    const bad = tables({
      t: { axes: [{ name: 'p', values: [1, 2] }], out_of_bounds: 'error', data: [10, 20, 30] },
    })
    expect(loweringErrorCode(() => lowerTableLookups(lookup(), bad))).toBe(
      ERROR_CODES.TABLE_DATA_SHAPE_MISMATCH,
    )
  })

  it.each([Infinity, -Infinity, NaN])(
    'names a non-finite `data` leaf (%s) `table_data_nan`',
    (v) => {
      const bad = tables({ t: { axes: [{ name: 'p', values: [1, 2] }], data: [10, v] } })
      expect(loweringErrorCode(() => lowerTableLookups(lookup(), bad))).toBe(
        ERROR_CODES.TABLE_DATA_NAN,
      )
    },
  )

  it('names a non-numeric `data` leaf `table_data_shape_mismatch`', () => {
    const bad = tables({ t: { axes: [{ name: 'p', values: [1, 2] }], data: [10, 'x'] } })
    expect(loweringErrorCode(() => lowerTableLookups(lookup(), bad))).toBe(
      ERROR_CODES.TABLE_DATA_SHAPE_MISMATCH,
    )
  })

  it('names a non-increasing axis `table_axis_non_monotonic`', () => {
    for (const values of [
      [1, 1, 2],
      [3, 1, 2],
    ]) {
      const bad = tables({ t: { axes: [{ name: 'p', values }], data: [10, 20, 30] } })
      expect(loweringErrorCode(() => lowerTableLookups(lookup(), bad))).toBe(
        ERROR_CODES.TABLE_AXIS_NON_MONOTONIC,
      )
    }
  })

  // §9.5.5: NaN takes precedence over non-monotonic, wherever the NaN sits.
  it.each([[[3, 1, NaN]], [[NaN, 1, 2]]])(
    'names an axis %j `table_axis_nan`, not `table_axis_non_monotonic`',
    (values) => {
      const bad = tables({ t: { axes: [{ name: 'p', values }], data: [10, 20, 30] } })
      expect(loweringErrorCode(() => lowerTableLookups(lookup(), bad))).toBe(
        ERROR_CODES.TABLE_AXIS_NAN,
      )
    },
  )

  it('names a NaN axis knot `table_axis_nan`', () => {
    const nan = tables({ t: { axes: [{ name: 'p', values: [1, NaN] }], data: [10, 20] } })
    expect(loweringErrorCode(() => lowerTableLookups(lookup(), nan))).toBe(
      ERROR_CODES.TABLE_AXIS_NAN,
    )
  })

  // §9.5.1 says FINITE, and the other four bindings refuse ±Infinity here.
  // An infinite knot is worse than a NaN one: it yields a 0-or-NaN §9.2 blend
  // weight with no diagnostic, and the lowered `const` serializes as `null`.
  it.each([Infinity, -Infinity])('names an infinite axis knot (%s) `table_axis_nan`', (v) => {
    const inf = tables({ t: { axes: [{ name: 'p', values: [1, v] }], data: [10, 20] } })
    expect(loweringErrorCode(() => lowerTableLookups(lookup(), inf))).toBe(
      ERROR_CODES.TABLE_AXIS_NAN,
    )
  })
})

describe('lookup_defaults fixture: omitted `output` is 0, single-output lowers the whole `data`', () => {
  const file = fixture('lookup_defaults')
  const model = modelOf(file, 'LookupDefaults')
  const testCase = model.tests![0]
  const bindings = bindingsFor(model, testCase.parameter_overrides ?? {})
  for (const assertion of testCase.assertions as Array<{ variable: string; expected: number }>) {
    it(`evaluates observed \`${assertion.variable}\` to ${assertion.expected}`, () => {
      const actual = evaluateExpression(definitionOf(model, assertion.variable), bindings, {
        functionTables: tablesOf(file),
      })
      expect(actual).toBe(assertion.expected)
    })
  }
})

/**
 * Evaluate a lowered `nearest` tree. The production scalar evaluator refuses
 * `index` (an array op), so this adds the one rule it lacks — `index` of a
 * `const` array at a 1-based scalar position — and takes every other op from
 * the same op registry and closed-function dispatch `evaluateExpression` uses.
 */
function evalLowered(expr: Expr, bindings: Map<string, number>): number {
  if (typeof expr === 'number') return expr
  if (typeof expr === 'string') {
    const v = bindings.get(expr)
    if (v === undefined) throw new Error(`unbound ${expr}`)
    return v
  }
  const node = nodeOf(expr)
  const constArray = (e: Expr): number[] | null => {
    const n = nodeOf(e)
    return n.op === 'const' && Array.isArray(n.value) ? (n.value as number[]) : null
  }
  if (node.op === 'index') {
    const array = constArray(node.args[0])!
    const k = evalLowered(node.args[1], bindings)
    if (!Number.isInteger(k) || k < 1 || k > array.length) {
      throw new Error(`index ${k} out of 1..${array.length}`)
    }
    return array[k - 1]!
  }
  if (node.op === 'ifelse') {
    return evalLowered(node.args[0], bindings) !== 0
      ? evalLowered(node.args[1], bindings)
      : evalLowered(node.args[2], bindings)
  }
  if (node.op === 'fn') {
    const args = node.args.map((a): unknown => constArray(a) ?? evalLowered(a, bindings))
    return dispatchClosedFunction(node.name as string, args)
  }
  return getOpInfo(node.op)!.evaluate!(node.args.map((a) => evalLowered(a, bindings)))
}

describe('nearest fixture: the §9.5.3 nearest-knot composition (Q-13)', () => {
  const file = fixture('nearest')
  const model = modelOf(file, 'NearestLookup')
  const testCase = model.tests![0]
  const bindings = bindingsFor(model, testCase.parameter_overrides ?? {})

  it('lowers `n_tie_2_4` to exactly the hand-spelled tree of `n_tie_2_4_hand`', () => {
    const lowered = lowerTableLookups(definitionOf(model, 'n_tie_2_4'), tablesOf(file))
    expect(lowered).toEqual(definitionOf(model, 'n_tie_2_4_hand'))
  })

  for (const assertion of testCase.assertions as Array<{ variable: string; expected: number }>) {
    it(`evaluates the lowered \`${assertion.variable}\` to ${assertion.expected}`, () => {
      const lowered = lowerTableLookups(definitionOf(model, assertion.variable), tablesOf(file))
      expect(evalLowered(lowered, bindings)).toBe(assertion.expected)
    })
  }

  it('returns NaN for a NaN query', () => {
    const lowered = lowerTableLookups(definitionOf(model, 'n_knot'), tablesOf(file))
    expect(evalLowered(lowered, new Map([['q_knot', NaN]]))).toBeNaN()
  })

  it('is refused by the scalar evaluator as `unevaluable_operator` (it has no `index` rule)', () => {
    let code = 'NO_ERROR'
    try {
      evaluateExpression(definitionOf(model, 'n_knot'), bindings, {
        functionTables: tablesOf(file),
      })
    } catch (e) {
      code = (e as { code?: string }).code ?? 'NO_CODE'
    }
    expect(code).toBe(ERROR_CODES.UNEVALUABLE_OPERATOR)
  })

  it('still refuses `out_of_bounds: "error"` with `table_out_of_bounds_unsupported`', () => {
    const strict = tables({
      t: {
        axes: [{ name: 'p', values: [1, 2] }],
        interpolation: 'nearest',
        out_of_bounds: 'error',
        data: [10, 20],
      },
    })
    expect(
      loweringErrorCode(() =>
        lowerTableLookups({ op: 'table_lookup', table: 't', axes: { p: 'x' }, args: [] }, strict),
      ),
    ).toBe(ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED)
  })
})

describe('§9.5.4 round-trip: lowering never touches the loaded image', () => {
  it('serializes the authored `table_lookup` and its `function_tables` block back out', () => {
    const file = fixture('inline_test')
    const model = modelOf(file, 'TableLookupObserved')
    // Evaluate FIRST: were the lowering happening in place, the emit below
    // would carry the `interp.linear` form instead of what was authored.
    evaluateExpression(definitionOf(model, 'y'), bindingsFor(model), {
      functionTables: tablesOf(file),
    })

    const reloaded = JSON.parse(toJson(file)) as {
      function_tables: { t_prof: { data: number[] } }
      models: {
        TableLookupObserved: { equations: Array<{ lhs: unknown; rhs: { op: string } }> }
      }
    }
    expect(reloaded.function_tables.t_prof.data).toEqual([10, 20, 30, 40])
    const authored = reloaded.models.TableLookupObserved.equations.find((e) => e.lhs === 'y')!
    expect(authored.rhs).toEqual({
      op: 'table_lookup',
      table: 't_prof',
      axes: { p: 'p' },
      args: [],
    })
  })
})
