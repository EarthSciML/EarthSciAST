/**
 * `table_lookup` → `interp.linear` / `interp.bilinear` / `index` lowering —
 * esm-spec §9.5.3.
 *
 * A `table_lookup` node is SUGAR. It names a `function_tables` entry plus one
 * input expression per declared axis, and §9.5.3 gives the exact §9.2
 * closed-function tree it stands for. Nothing in this binding evaluated
 * `table_lookup` itself: the op is absent from the evaluable-core op registry,
 * so `evaluateExpression` refused it as an `unlowered_operator` — and the only
 * lowering that existed lived INSIDE a test harness
 * (`function-tables-lowering.test.ts`). A document whose observed is defined by
 * a `table_lookup` therefore validated, round-tripped, and then failed every
 * evaluation that depended on it, while the same lookup written out by hand in
 * the lowered form worked (issue #188).
 *
 * **This runs at EVALUATION, not at load, and that is the point.** §9.5.4 makes
 * `function_tables` / `table_lookup` first-class AUTHORED constructs that must
 * survive a round trip, and `toJson` serializes the typed `EsmFile` that
 * `loadString` produced — so lowering in `parse.ts` (where `lowerEnums` sits)
 * would emit the lowered `fn` form and break §9.5.4. §9.5.3 admits either an
 * in-memory transformation or a direct evaluator dispatch; `codegen.ts`
 * dispatches on the node and lowers it here, one node at a time, leaving the
 * loaded image authored-as-written.
 *
 * Bit-equivalence with the hand-written inline-`const` lookup (§9.5's central
 * promise) comes for free: the lowered tree drives the very same
 * `closed-functions.ts` `interp.linear` / `interp.bilinear` implementations an
 * author would have invoked by hand.
 *
 * **`out_of_bounds: "error"` is REFUSED, not silently clamped.** `"clamp"` is
 * required of every binding and `"error"` is "conformant when implemented"
 * (§9.5.1); this binding does not implement it, so §9.5.3a makes the lookup a
 * `table_out_of_bounds_unsupported` error here rather than an `interp.*` tree
 * that answers in a mode the author did not ask for. That would be the same
 * defect as the one this module exists to fix: a wrong number with nothing in
 * the result to say so. The document still LOADS and still round-trips — it
 * simply does not evaluate.
 */

import type { Expr, ExpressionNode, FunctionTable, FunctionTableAxis } from './types.js'
import { mapChildren, forEachChild } from './expression.js'
import { numericValue } from './numeric-literal.js'
import { ERROR_CODES, EsmDiagnosticError } from './errors.js'

/** The op this pass consumes. */
const TABLE_LOOKUP = 'table_lookup'

/** A document's `function_tables` block (esm-spec §9.5.1), keyed by table id. */
export type FunctionTables = { [k: string]: FunctionTable }

/**
 * Error carrying one of the esm-spec §9.5.5 diagnostic codes (registered in
 * `errors.ts` `ERROR_CODES`, and coordinated across all five bindings). Message
 * is `[code]`-prefixed, matching {@link EnumLoweringError}, the other lowering
 * pass.
 */
export class TableLookupLoweringError extends EsmDiagnosticError {
  declare readonly code: string
  constructor(code: string, message: string) {
    super(code, `[${code}] ${message}`)
    this.name = 'TableLookupLoweringError'
  }
}

function fail(code: string, message: string): never {
  throw new TableLookupLoweringError(code, message)
}

/**
 * Narrow an {@link Expr} to its operator-node view, or `null` for a leaf.
 * Deliberately looser than `isExprNode`, which additionally requires `args`: a
 * `const` node legitimately carries only `value`, and this walker must descend
 * through whatever it is handed.
 */
function asOperatorNode(expr: Expr): ExpressionNode | null {
  if (typeof expr !== 'object' || expr === null) return null
  const node = expr as ExpressionNode
  return typeof node.op === 'string' ? node : null
}

/**
 * Whether `expr` carries a `table_lookup` anywhere. The guard that keeps a
 * document whose tables are used in one equation from having its entire AST
 * rebuilt equation by equation.
 */
function containsTableLookup(expr: Expr): boolean {
  const node = asOperatorNode(expr)
  if (node === null) return false
  if (node.op === TABLE_LOOKUP) return true
  let found = false
  forEachChild(node, (child) => {
    // No early exit: `forEachChild` is a plain visitor. The subtrees are
    // expression-sized, so a full visit is cheaper than a bespoke walker.
    if (!found && containsTableLookup(child)) found = true
  })
  return found
}

/**
 * Rewrite every `table_lookup` node in `expr` to its §9.5.3 form.
 *
 * BOTTOM-UP: children are lowered first, so a `table_lookup` nested inside
 * another node's axis input (or body, or filter, …) is already an `interp.*`
 * tree by the time its parent is rewritten. The result is a NEW tree; `expr` is
 * not mutated, and a subtree carrying no `table_lookup` is returned unchanged
 * (identity-preserving). Idempotent: after one pass no `table_lookup` survives,
 * so a second finds nothing to do.
 *
 * `tables` is the document's `function_tables` block; pass `undefined` for a
 * document that declares none, which makes any `table_lookup` in `expr` an
 * unknown-table error rather than a silent pass-through.
 */
export function lowerTableLookups(expr: Expr, tables: FunctionTables | undefined): Expr {
  if (!containsTableLookup(expr)) return expr
  // `containsTableLookup` already established this is an operator node.
  const node = asOperatorNode(expr) as ExpressionNode
  const lowered = mapChildren(node, (child) => lowerTableLookups(child, tables))
  return lowered.op === TABLE_LOOKUP ? lowerTableLookupNode(lowered, tables) : lowered
}

/**
 * The §9.5.3 lowering of ONE `table_lookup` node, whose axis inputs are taken
 * as-is (they are lowered by {@link lowerTableLookups}, or evaluated in place by
 * the `codegen.ts` walker, which recurses into the result).
 */
export function lowerTableLookupNode(
  node: ExpressionNode,
  tables: FunctionTables | undefined,
): Expr {
  const { tableId, table, inputs, output } = checkLookup(node, tables, true)
  const data = outputSlice(table, output)

  // esm-spec §9.5.3a, outside the order above: raised only on a lookup that
  // passed every check. `clamp` (the default) is exactly what `interp.linear` /
  // `interp.bilinear` do at the ends, so the lowering IS the semantics there;
  // `error` has no lowered form at all, and answering it with the clamping one
  // would hand back a number the author did not ask for with nothing in the
  // result to say so.
  if (table.out_of_bounds === 'error') {
    fail(
      ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED,
      `table \`${tableId}\` declares \`out_of_bounds: "error"\`, which this binding does not ` +
        'implement; only `"clamp"` (the default) is available, and answering an `"error"` table ' +
        'under clamp semantics would be a silently different result (esm-spec §9.5.3a)',
    )
  }

  // `interpolation` defaults to `linear` (esm-spec §9.5.1).
  const kind = table.interpolation ?? 'linear'
  const axes = table.axes
  if (kind === 'linear' && axes.length === 1) {
    return closedFn('interp.linear', [constExpr(data), axisConst(axes[0]), inputs[0]])
  }
  if (kind === 'bilinear' && axes.length === 2) {
    return closedFn('interp.bilinear', [
      constExpr(data),
      axisConst(axes[0]),
      axisConst(axes[1]),
      inputs[0],
      inputs[1],
    ])
  }
  // `validateFunctionTable` has already rejected every other kind/axis-count pair.
  return nearestTree(data, axes[0], inputs[0])
}

/**
 * The esm-spec §9.5.5 checks of ONE `table_lookup` node, in the pinned order
 * ("Order of the lookup checks", rulings Q-107 and Q-112): unknown table, then
 * (when `checkTable`) the named table's ten checks, then the lookup's own
 * `args`, axis keys and output. Throws a {@link TableLookupLoweringError}
 * naming the first failure.
 *
 * Load runs this on every `table_lookup` node with `checkTable` false, because
 * it has already checked every table before any expression node; the lowering
 * runs it with `checkTable` true, because it is also handed tables that never
 * went through a load.
 */
export function checkTableLookupNode(
  node: ExpressionNode,
  tables: FunctionTables | undefined,
  checkTable: boolean,
): void {
  checkLookup(node, tables, checkTable)
}

function checkLookup(
  node: ExpressionNode,
  tables: FunctionTables | undefined,
  checkTable: boolean,
): { tableId: string; table: FunctionTable; inputs: Expr[]; output: number } {
  const tableId = node.table
  if (typeof tableId !== 'string') {
    fail(
      ERROR_CODES.TABLE_LOOKUP_UNKNOWN_TABLE,
      'a `table_lookup` node carries no `table` id (esm-spec §9.5.2)',
    )
  }
  const table = tables !== undefined && Object.hasOwn(tables, tableId) ? tables[tableId] : undefined
  if (table === undefined) {
    fail(
      ERROR_CODES.TABLE_LOOKUP_UNKNOWN_TABLE,
      `\`table_lookup\` references table \`${tableId}\`, which the document's ` +
        '`function_tables` block does not declare',
    )
  }
  if (checkTable) validateFunctionTable(table, tableId)
  const inputs = axisInputs(node, table, tableId)
  const output = outputIndex(node, table, tableId)
  return { tableId, table, inputs, output }
}

/** The arity `interpolation` requires (esm-spec §9.5.1), or `undefined` for an unknown kind. */
const AXES_FOR_INTERPOLATION: { [kind: string]: number | undefined } = {
  linear: 1,
  bilinear: 2,
  nearest: 1,
}

/**
 * The esm-spec §9.5.5 load-time checks on ONE function table, in the order the
 * spec pins ("Order of the table checks"; the formal model is
 * `Esm.Closed.Tables.validateTable`). Throws a {@link TableLookupLoweringError}
 * naming the FIRST rule the table breaks; returns when it breaks none. Each
 * step covers every axis before the next begins:
 *
 *  1. `table_axis_duplicate_name`
 *  2. `table_outputs_duplicate_name`
 *  3. `table_interpolation_axes_mismatch`
 *  4. `table_axis_nan` — any axis
 *  5. `table_axis_non_monotonic` — any axis
 *  6. `table_axis_too_short` — any axis
 *  7. `table_outputs_length_mismatch` — `outputs` declared, `data` an array of another length
 *  8. `table_data_shape_mismatch` — the nesting of `data` is not exactly the implied shape
 *  9. `table_data_nan`
 * 10. `table_data_shape_mismatch` — the `shape` assertion is not the implied shape
 *
 * The implied shape is `[len(outputs), len(axes[0].values), …]` with `outputs`,
 * the axis lengths alone without (§9.5.1).
 *
 * A knot that is not finite (NaN, +Inf or -Inf) is `table_axis_nan`, and a
 * `data` leaf that is not finite is `table_data_nan` (esm-spec §9.5.5, ruling
 * Q-109). Choices this binding makes where the rules leave room: a non-numeric
 * knot is `table_axis_nan` too; a non-numeric `data` leaf (a string, an
 * object, `null`) does not count as a leaf at all, so it is a nesting mismatch
 * (`table_data_shape_mismatch`, step 8).
 *
 * The binding's one validator for a function table: load runs it on every
 * `function_tables` entry, referenced or not (`load-function-checks.ts`,
 * ruling Q-106), and the §9.5.3 lowering runs it again on the table a lookup
 * names.
 */
export function validateFunctionTable(table: FunctionTable, tableId: string): void {
  const axes: readonly FunctionTableAxis[] = table.axes
  const where = `table \`${tableId}\``

  // 1. Axis names unique within the table.
  const axisNames = axes.map((a) => a.name)
  const dupAxis = firstDuplicate(axisNames)
  if (dupAxis !== undefined) {
    fail(
      ERROR_CODES.TABLE_AXIS_DUPLICATE_NAME,
      `${where} declares two axes named \`${dupAxis}\` (esm-spec §9.5.1)`,
    )
  }

  // 2. Output names unique.
  const outputs: readonly string[] | undefined = table.outputs
  if (outputs !== undefined) {
    const dupOutput = firstDuplicate(outputs)
    if (dupOutput !== undefined) {
      fail(
        ERROR_CODES.TABLE_OUTPUTS_DUPLICATE_NAME,
        `${where} declares the output \`${dupOutput}\` twice (esm-spec §9.5.1)`,
      )
    }
  }

  // 3. `interpolation` (default `linear`) agrees with the axis count.
  const kind = table.interpolation ?? 'linear'
  if (AXES_FOR_INTERPOLATION[kind] !== axes.length) {
    fail(
      ERROR_CODES.TABLE_INTERPOLATION_AXES_MISMATCH,
      `${where} declares \`interpolation: "${kind}"\` over ${axes.length} axes; ` +
        '`linear` and `nearest` require 1, `bilinear` requires 2 (esm-spec §9.5.1)',
    )
  }

  // 4. No non-finite knot on ANY axis. Every knot is a finite number after this.
  const knots: number[][] = axes.map((axis) => axis.values.map((v) => numericValue(v) ?? NaN))
  for (let a = 0; a < axes.length; a++) {
    const i = knots[a].findIndex((v) => !Number.isFinite(v))
    if (i >= 0) {
      fail(
        ERROR_CODES.TABLE_AXIS_NAN,
        `${where}: axis \`${axes[a].name}\` entry ${i + 1} is not a finite number; axis ` +
          '`values` must be strictly-increasing FINITE floats (esm-spec §9.5.1)',
      )
    }
  }

  // 5. Every axis strictly increasing.
  for (let a = 0; a < axes.length; a++) {
    const vs = knots[a]
    for (let i = 1; i < vs.length; i++) {
      if (!(vs[i] > vs[i - 1])) {
        fail(
          ERROR_CODES.TABLE_AXIS_NON_MONOTONIC,
          `${where}: axis \`${axes[a].name}\` is not strictly increasing at entry ${i + 1} ` +
            `(${vs[i]} after ${vs[i - 1]}) (esm-spec §9.5.1)`,
        )
      }
    }
  }

  // 6. Every axis carries at least two knots.
  for (let a = 0; a < axes.length; a++) {
    if (knots[a].length < 2) {
      fail(
        ERROR_CODES.TABLE_AXIS_TOO_SHORT,
        `${where}: axis \`${axes[a].name}\` has ${knots[a].length} values; an axis needs at ` +
          'least 2 (esm-spec §9.5.1)',
      )
    }
  }

  // 7. The leading dimension of `data` is `len(outputs)`. A non-array `data`
  // skips this step and fails the nesting check below.
  const data = table.data as unknown
  if (outputs !== undefined && Array.isArray(data) && data.length !== outputs.length) {
    fail(
      ERROR_CODES.TABLE_OUTPUTS_LENGTH_MISMATCH,
      `${where}: \`data\` has leading dimension ${data.length} but the table declares ` +
        `${outputs.length} outputs (esm-spec §9.5.1)`,
    )
  }

  // 8. The nesting of `data` is exactly the implied shape.
  const axisShape = knots.map((vs) => vs.length)
  const implied = outputs !== undefined ? [outputs.length, ...axisShape] : axisShape
  if (!hasShape(data, implied)) {
    fail(
      ERROR_CODES.TABLE_DATA_SHAPE_MISMATCH,
      `${where}: the nesting of \`data\` is not the shape [${implied.join(', ')}] its ` +
        `${outputs !== undefined ? '`outputs` and ' : ''}axes imply (esm-spec §9.5.1)`,
    )
  }

  // 9. Every `data` leaf finite.
  if (anyNonFiniteLeaf(data)) {
    fail(
      ERROR_CODES.TABLE_DATA_NAN,
      `${where}: \`data\` holds a non-finite leaf; leaves must be finite numbers (esm-spec §9.5.1)`,
    )
  }

  // 10. The redundant `shape` assertion, when present, is the implied shape.
  const shape: readonly unknown[] | undefined = table.shape
  if (shape !== undefined) {
    const asserted = shape.map((d) => numericValue(d))
    if (asserted.length !== implied.length || asserted.some((d, i) => d !== implied[i])) {
      fail(
        ERROR_CODES.TABLE_DATA_SHAPE_MISMATCH,
        `${where}: the \`shape\` assertion [${asserted.join(', ')}] is not the shape ` +
          `[${implied.join(', ')}] of \`data\` (esm-spec §9.5.1)`,
      )
    }
  }
}

/** The first entry of `names` that occurs earlier in it, or `undefined`. */
function firstDuplicate(names: readonly string[]): string | undefined {
  const seen = new Set<string>()
  for (const name of names) {
    if (seen.has(name)) return name
    seen.add(name)
  }
  return undefined
}

/**
 * Whether `value`'s nesting is EXACTLY `shape`: a numeric leaf (NaN included —
 * that is step 9's business) has shape `[]`, and an array of length `n` has
 * shape `n :: rest` when every element has shape `rest`. A non-numeric leaf
 * matches no shape.
 */
function hasShape(value: unknown, shape: readonly number[]): boolean {
  if (shape.length === 0) return numericValue(value) !== undefined
  if (!Array.isArray(value) || value.length !== shape[0]) return false
  const rest = shape.slice(1)
  return value.every((v) => hasShape(v, rest))
}

/** Whether any numeric leaf of `value` is NaN or ±Infinity. */
function anyNonFiniteLeaf(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(anyNonFiniteLeaf)
  const n = numericValue(value)
  return n !== undefined && !Number.isFinite(n)
}

/**
 * The esm-spec §9.5.3 `nearest` composition, built node for node as the spec
 * spells it (same ops, same operand order) so that every binding decides a tie
 * on the same two `binary64` differences `A[hi] - x` and `x - A[lo]`:
 *
 *     ifelse(x == x, index(D, ifelse(A[hi] - x < x - A[lo], hi, lo)), x)
 *
 * with `j = searchsorted(x, A)`, `lo = max(j - 1, 1)`, `hi = min(j, N)`. A tie
 * goes to the lower knot, a query outside the axis clamps to the end knot, and
 * a NaN query returns NaN. `index` is an array op the scalar evaluator in
 * `codegen.ts` does not evaluate, so the result lowers here and is then refused
 * there as `unevaluable_operator`.
 */
function nearestTree(data: unknown, axis: FunctionTableAxis, x: Expr): Expr {
  const n = axis.values.length
  const knots = (): Expr => axisConst(axis)
  const j = (): Expr => closedFn('interp.searchsorted', [x, knots()])
  const lo = (): Expr => op('max', [op('-', [j(), 1]), 1])
  const hi = (): Expr => op('min', [j(), n])
  const knotAt = (k: Expr): Expr => op('index', [knots(), k])
  return op('ifelse', [
    op('==', [x, x]),
    op('index', [
      constExpr(data),
      op('ifelse', [op('<', [op('-', [knotAt(hi()), x]), op('-', [x, knotAt(lo())])]), hi(), lo()]),
    ]),
    x,
  ])
}

/**
 * The node's per-axis input expressions, in the table's DECLARED axis order
 * (which is the order of `data`'s inner dimensions, and therefore the argument
 * order of `interp.bilinear`).
 */
function axisInputs(node: ExpressionNode, table: FunctionTable, tableId: string): Expr[] {
  // An absent `args` means `[]` (esm-spec §9.5.2).
  if (node.args !== undefined && node.args.length > 0) {
    fail(
      ERROR_CODES.TABLE_LOOKUP_ARGS_NONEMPTY,
      `\`table_lookup\` on table \`${tableId}\` carries ${node.args.length} positional \`args\`; ` +
        'the per-axis inputs live under `axes` and `args` MUST be empty (esm-spec §9.5.2)',
    )
  }
  // Typed with an explicit `| undefined` value: `noUncheckedIndexedAccess` is
  // off, so the declared `{[k: string]: Expression}` would make the
  // missing-axis check below a comparison TypeScript reads as impossible.
  const supplied: { [k: string]: Expr | undefined } = node.axes ?? {}
  const inputs: Expr[] = []
  for (const axis of table.axes) {
    const input = supplied[axis.name]
    if (input === undefined) {
      fail(
        ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
        `\`table_lookup\` on table \`${tableId}\` supplies no input for its declared axis ` +
          `\`${axis.name}\``,
      )
    }
    inputs.push(input)
  }
  // Every declared axis is bound by here, so a count mismatch means EXTRA keys.
  const suppliedCount = Object.keys(supplied).length
  if (suppliedCount !== table.axes.length) {
    const declared = table.axes.map((a) => a.name).join(', ')
    fail(
      ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
      `\`table_lookup\` on table \`${tableId}\` supplies ${suppliedCount} axis inputs but the ` +
        `table declares ${table.axes.length} (${declared}); the key sets must match exactly ` +
        '(esm-spec §9.5.2)',
    )
  }
  return inputs
}

/**
 * Resolve `output` (absent, integer index, or name) to a 0-based row index into
 * `data`'s leading dimension.
 */
function outputIndex(node: ExpressionNode, table: FunctionTable, tableId: string): number {
  const output = node.output
  const outputs = table.outputs
  if (output === undefined || output === null) return 0

  const index = numericValue(output)
  if (index !== undefined) {
    if (!Number.isInteger(index) || index < 0) {
      fail(
        ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
        `\`table_lookup.output\` on table \`${tableId}\` is ${index}; an integer output index ` +
          'must be a non-negative integer',
      )
    }
    if (outputs === undefined) {
      // No `outputs` list means the table is single-output and `data` has no
      // leading output dimension at all (§9.5.1), so 0 is the only index that
      // names anything.
      if (index !== 0) {
        fail(
          ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
          `\`table_lookup.output\` ${index} on table \`${tableId}\`, which declares no ` +
            '`outputs` and is therefore single-output',
        )
      }
      return 0
    }
    if (index >= outputs.length) {
      fail(
        ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
        `\`table_lookup.output\` ${index} on table \`${tableId}\` is out of range: the table ` +
          `declares ${outputs.length} outputs`,
      )
    }
    return index
  }

  if (typeof output === 'string') {
    if (outputs === undefined) {
      fail(
        ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
        `\`table_lookup.output\` "${output}" names an output, but table \`${tableId}\` declares ` +
          'no `outputs` list',
      )
    }
    const position = outputs.indexOf(output)
    if (position < 0) {
      fail(
        ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
        `\`table_lookup.output\` "${output}" is not one of table \`${tableId}\`'s outputs ` +
          `(${outputs.join(', ')})`,
      )
    }
    return position
  }

  return fail(
    ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
    `\`table_lookup.output\` on table \`${tableId}\` must be a non-negative integer or an ` +
      `output name, not ${JSON.stringify(output)}`,
  )
}

/**
 * The `data` sub-array the lowered `const` carries: row `output` of the leading
 * dimension for a multi-output table, and the whole literal for a single-output
 * one (which has no leading output dimension, §9.5.1). `data`'s nesting was
 * checked by {@link validateFunctionTable} and `output` is in range, so the row
 * exists.
 */
function outputSlice(table: FunctionTable, output: number): unknown {
  // The generated type for `data` is the json2ts rendering of an untyped nested
  // array; the wire value is an array.
  const data = table.data as unknown
  if (table.outputs === undefined) return data
  return (data as unknown[])[output]
}

/**
 * `{op: "const", args: [], value: <axis values>}` for one declared axis, whose
 * knots {@link validateFunctionTable} has already checked.
 */
function axisConst(axis: FunctionTableAxis): Expr {
  return constExpr(axis.values)
}

function constExpr(value: unknown): Expr {
  return { op: 'const', args: [], value: plainNumbers(value) } as Expr
}

function op(name: string, args: Expr[]): Expr {
  return { op: name, args } as Expr
}

function closedFn(name: string, args: Expr[]): Expr {
  return { op: 'fn', name, args } as Expr
}

/**
 * Strip tagged `NumericLiteral` leaves back to plain JS numbers.
 *
 * `loadString(text, {canonical: true})` decodes EVERY number in the document —
 * `function_tables` data and axis values included — to a tagged
 * `NumericLiteral`. The `interp.*` closed functions take plain `number[]`, so a
 * canonically-loaded table would otherwise lower to a `const` the registry
 * rejects as `interp_table_not_const`: a lowering-shaped failure under a
 * misleading name. Under a default load the values are already plain and this
 * is a structural copy.
 */
function plainNumbers(value: unknown): unknown {
  const n = numericValue(value)
  if (n !== undefined) return n
  if (Array.isArray(value)) return value.map(plainNumbers)
  return value
}
