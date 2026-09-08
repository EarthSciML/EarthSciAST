/**
 * Bit-equivalent table_lookup → interp.* lowering harness (esm-lhm).
 *
 * For each conformance fixture under `tests/conformance/function_tables/`,
 * loadString the file, walk the model equations, evaluate every `table_lookup`
 * node THROUGH THE PRODUCTION EVALUATOR (which lowers it to the
 * inline-`const` `interp.linear` / `interp.bilinear` invocation prescribed by
 * esm-spec §9.5.3), and assert IEEE-754 binary64 agreement with the equivalent
 * hand-written inline-`const` lookup at the §9.2 tolerance contract
 * (`abs: 0, rel: 0`, non-FMA reference path).
 *
 * Both arms bottom out in the same `dispatchClosedFunction` implementations;
 * the harness catches lowering-side mistakes (wrong output slice, swapped axis
 * order, dropped input expression) by computing the reference value from the
 * raw `function_tables` block independently of the parsed `table_lookup` node.
 *
 * The lowering itself lives in `lower-table-lookups.ts` — see
 * `lower-table-lookups.test.ts` for the tree-level and diagnostic pins.
 */
import { describe, it, expect } from 'vitest'
import { dispatchClosedFunction } from './closed-functions.js'
import { evaluateExpression } from './codegen.js'
import { loadFixture as loadEsmFixture } from './test-helpers.js'

function bitEq(a: number, b: number): boolean {
  const buf = new ArrayBuffer(16)
  const f = new Float64Array(buf)
  f[0] = a
  f[1] = b
  const u = new BigUint64Array(buf)
  return u[0] === u[1]
}

function loadFixture(scenario: string): any {
  return loadEsmFixture('conformance', 'function_tables', scenario, 'fixture.esm')
}

interface Var {
  type?: string
  default?: number
}

function resolveAxisValue(expr: unknown, vars: Record<string, Var>): number {
  if (typeof expr === 'number') return expr
  if (typeof expr === 'string') {
    const v = vars[expr]
    if (v?.default === undefined) {
      throw new Error(`variable ${expr} has no default`)
    }
    return v.default
  }
  throw new Error(`complex axis input not exercised: ${JSON.stringify(expr)}`)
}

function slice1d(data: any, idx: number, hasOutputs: boolean): number[] {
  return (hasOutputs ? data[idx] : data).map((v: any) => Number(v))
}
function slice2d(data: any, idx: number, hasOutputs: boolean): number[][] {
  const rows = hasOutputs ? data[idx] : data
  return rows.map((r: any) => r.map((v: any) => Number(v)))
}

/**
 * Evaluate a `table_lookup` node through the PRODUCTION path: `codegen.ts`
 * lowers it per §9.5.3 (`lower-table-lookups.ts`) and evaluates the result.
 *
 * This used to re-implement the lowering locally — which is exactly how issue
 * #188 stayed hidden: the harness agreed with the reference while NOTHING on
 * the path a caller actually takes could lower a table at all.
 */
function lowerAndEvaluate(node: any, file: any, vars: Record<string, Var>): number {
  expect(node.op).toBe('table_lookup')
  expect(node.args).toEqual([])
  const bindings = new Map<string, number>()
  for (const [name, v] of Object.entries(vars)) {
    if (typeof v.default === 'number') bindings.set(name, v.default)
  }
  return evaluateExpression(node, bindings, { functionTables: file.function_tables })
}

function referenceInlineConst(
  tableId: string,
  output: string | null,
  outputIdxInt: number | null,
  axisInputs: Array<[string, string]>,
  file: any,
  vars: Record<string, Var>,
): number {
  const table = file.function_tables[tableId]
  const hasOutputs = Array.isArray(table.outputs)
  let idx: number
  if (output !== null) {
    idx = (table.outputs as string[]).indexOf(output)
  } else if (outputIdxInt !== null) {
    idx = outputIdxInt
  } else {
    idx = 0
  }
  const kind = (table.interpolation ?? 'linear') as string

  if (kind === 'linear') {
    const axis = table.axes[0]
    const [axName, varName] = axisInputs[0]
    expect(axName).toBe(axis.name)
    const slice = slice1d(table.data, idx, hasOutputs)
    const x = vars[varName].default!
    return dispatchClosedFunction('interp.linear', [slice, axis.values.map(Number), x])
  }
  if (kind === 'bilinear') {
    const [ax, ay] = table.axes
    const [[axn0, vn0], [axn1, vn1]] = axisInputs
    expect(axn0).toBe(ax.name)
    expect(axn1).toBe(ay.name)
    const slice = slice2d(table.data, idx, hasOutputs)
    return dispatchClosedFunction('interp.bilinear', [
      slice,
      ax.values.map(Number),
      ay.values.map(Number),
      vars[vn0].default!,
      vars[vn1].default!,
    ])
  }
  throw new Error(`unsupported reference kind: ${kind}`)
}

describe('table_lookup → interp.* lowering bit-equivalence (esm-spec §9.5.3)', () => {
  it('linear fixture lowering matches the inline-const reference bit-for-bit', () => {
    const file = loadFixture('linear')
    const model = file.models!.M
    const vars = model.variables as Record<string, Var>
    const node = model.equations[0].rhs

    const lowered = lowerAndEvaluate(node, file, vars)
    const reference = referenceInlineConst(
      'sigma_O3_298',
      null,
      null,
      [['lambda_idx', 'lambda']],
      file,
      vars,
    )
    expect(bitEq(lowered, reference)).toBe(true)

    // Sanity: lambda=4.5 → i=3, w=0.5 → t3 + 0.5*(t4-t3)
    const expected = 8.7e-18 + 0.5 * (7.9e-18 - 8.7e-18)
    expect(bitEq(lowered, expected)).toBe(true)
  })

  it('bilinear fixture lowering matches the inline-const reference for both outputs', () => {
    const file = loadFixture('bilinear')
    const model = file.models!.M
    const vars = model.variables as Record<string, Var>

    const node0 = model.equations[0].rhs
    const lowered0 = lowerAndEvaluate(node0, file, vars)
    const reference0 = referenceInlineConst(
      'F_actinic',
      'NO2',
      null,
      [
        ['P', 'P_atm'],
        ['cos_sza', 'cos_sza'],
      ],
      file,
      vars,
    )
    expect(bitEq(lowered0, reference0)).toBe(true)

    const node1 = model.equations[1].rhs
    const lowered1 = lowerAndEvaluate(node1, file, vars)
    const reference1 = referenceInlineConst(
      'F_actinic',
      null,
      1,
      [
        ['P', 'P_atm'],
        ['cos_sza', 'cos_sza'],
      ],
      file,
      vars,
    )
    expect(bitEq(lowered1, reference1)).toBe(true)

    // Sanity: P=100, cos_sza=0.5 sits on the (1,1) interior knot.
    expect(lowered0).toBe(1.6) // NO2: data[0][1][1]
    expect(lowered1).toBe(2.6) // O3:  data[1][1][1]
  })

  it('roundtrip fixture lowering matches its inline-const companion bit-for-bit', () => {
    const file = loadFixture('roundtrip')
    const model = file.models!.M
    const vars = model.variables as Record<string, Var>
    const node = model.equations[0].rhs
    const lowered = lowerAndEvaluate(node, file, vars)

    // Eq 1 carries the equivalent inline-const interp.linear call by hand.
    const inline: any = model.equations[1].rhs
    expect(inline.op).toBe('fn')
    expect(inline.name).toBe('interp.linear')
    const tableArg: any = inline.args[0]
    const axisArg: any = inline.args[1]
    expect(tableArg.op).toBe('const')
    expect(axisArg.op).toBe('const')
    const inlineVal = dispatchClosedFunction('interp.linear', [
      (tableArg.value as number[]).map(Number),
      (axisArg.value as number[]).map(Number),
      resolveAxisValue(inline.args[2], vars),
    ])
    expect(bitEq(lowered, inlineVal)).toBe(true)
  })
})
