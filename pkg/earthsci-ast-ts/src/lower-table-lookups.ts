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
  const tableId = node.table
  if (typeof tableId !== 'string') {
    fail(
      ERROR_CODES.TABLE_LOOKUP_UNKNOWN_TABLE,
      'a `table_lookup` node carries no `table` id (esm-spec §9.5.2)',
    )
  }
  const table = tables?.[tableId]
  if (table === undefined) {
    fail(
      ERROR_CODES.TABLE_LOOKUP_UNKNOWN_TABLE,
      `\`table_lookup\` references table \`${tableId}\`, which the document's ` +
        '`function_tables` block does not declare',
    )
  }
  // esm-spec §9.5.3a. `clamp` (the default) is exactly what `interp.linear` /
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

  const inputs = axisInputs(node, table, tableId)
  const data = outputSlice(table, outputIndex(node, table, tableId), tableId)

  // `interpolation` defaults to `linear` (esm-spec §9.5.1).
  const kind = table.interpolation ?? 'linear'
  const axes = table.axes
  if (kind === 'linear' && axes.length === 1) {
    return closedFn('interp.linear', [constExpr(data), axisConst(axes[0], tableId), inputs[0]])
  }
  if (kind === 'bilinear' && axes.length === 2) {
    return closedFn('interp.bilinear', [
      constExpr(data),
      axisConst(axes[0], tableId),
      axisConst(axes[1], tableId),
      inputs[0],
      inputs[1],
    ])
  }
  if (kind === 'nearest' && axes.length === 1) {
    // `nearest` is an `index` of the table slice at the searchsorted position,
    // not an `interp` blend. The lowered form is the §9.5.3 one, but note that
    // `index` is an ARRAY op with no entry in the scalar op-registry, so
    // `codegen.ts` cannot evaluate the result — a `nearest` table lowers
    // correctly here and is then refused as `unlowered_operator` by the scalar
    // runner, the same as any other array op.
    return {
      op: 'index',
      args: [
        constExpr(data),
        closedFn('interp.searchsorted', [inputs[0], axisConst(axes[0], tableId)]),
      ],
    }
  }
  return fail(
    ERROR_CODES.TABLE_INTERPOLATION_AXES_MISMATCH,
    `table \`${tableId}\` declares \`interpolation: "${kind}"\` over ${axes.length} axes; ` +
      '`linear` and `nearest` require 1, `bilinear` requires 2 (esm-spec §9.5.1)',
  )
}

/**
 * The node's per-axis input expressions, in the table's DECLARED axis order
 * (which is the order of `data`'s inner dimensions, and therefore the argument
 * order of `interp.bilinear`).
 */
function axisInputs(node: ExpressionNode, table: FunctionTable, tableId: string): Expr[] {
  if (node.args !== undefined && node.args.length > 0) {
    fail(
      ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH,
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
 * one (which has no leading output dimension, §9.5.1).
 */
function outputSlice(table: FunctionTable, output: number, tableId: string): unknown {
  // The generated type for `data` is the json2ts rendering of an untyped nested
  // array; the wire value is an array.
  const data = table.data as unknown
  if (table.outputs === undefined) return data
  if (!Array.isArray(data) || output >= data.length) {
    fail(
      ERROR_CODES.TABLE_DATA_SHAPE_MISMATCH,
      `table \`${tableId}\`: \`data\` has no row ${output} for the selected output — its ` +
        'leading dimension must equal `len(outputs)` (esm-spec §9.5.1)',
    )
  }
  return data[output]
}

/** `{op: "const", args: [], value: <axis values>}` for one declared axis. */
function axisConst(axis: FunctionTableAxis, tableId: string): Expr {
  for (const value of axis.values) {
    const n = numericValue(value)
    if (n === undefined || Number.isNaN(n)) {
      fail(
        ERROR_CODES.TABLE_AXIS_NAN,
        `table \`${tableId}\`: axis \`${axis.name}\` carries a non-finite value; axis \`values\` ` +
          'must be strictly-increasing FINITE floats (esm-spec §9.5.1)',
      )
    }
  }
  return constExpr(axis.values)
}

function constExpr(value: unknown): Expr {
  return { op: 'const', args: [], value: plainNumbers(value) } as Expr
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
