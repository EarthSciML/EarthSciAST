/**
 * The load-time closed-function argument checks and function-table checks
 * (esm-spec §9.2 "When the argument checks run", §9.5.5 "When the table checks
 * run"; ruling Q-106).
 *
 * Both sets of checks used to run only where a lookup was lowered or a call was
 * evaluated, so a broken table nothing referenced, or a broken `interp.*` call
 * in a reaction rate nothing evaluated, loaded cleanly. They now run in load —
 * and therefore in `validate()`, which loads — on the document AS LOADED: after
 * template expansion and enum lowering, so a `fn` node in an
 * expression-template body is checked where the template is applied, on the
 * arguments the expansion gave it.
 *
 * - Every entry of `function_tables`, referenced or not, gets the ten §9.5.5
 *   table checks ({@link validateFunctionTable}, the same function the
 *   `table_lookup` lowering calls).
 * - Every `fn` node naming `interp.searchsorted` / `interp.linear` /
 *   `interp.bilinear`, wherever it sits, gets the §9.2 argument checks
 *   ({@link checkClosedFunctionArguments}, which shares its value checks with
 *   evaluation).
 *
 * "Wherever it sits" is a walk over the WHOLE loaded document rather than a
 * list of expression-bearing fields: every expression position (equations,
 * initialization equations, reaction rates, events, guesses, coupling
 * transforms, data-source conversions, inline-test references, …) is somewhere
 * in it, and a list would be one more place to forget a field. The walk skips
 * `function_tables` (checked as tables, and possibly large) and the `value` of
 * a `const` node (data, not expressions). A non-expression object that happened
 * to carry `op: "fn"` and an `interp.*` name does not occur in the schema.
 *
 * The evaluation-time checks stay: `evaluateExpression` and the lowering are
 * public and are handed expressions that never went through a load.
 */

import { checkClosedFunctionArguments } from './closed-functions.js'
import { validateFunctionTable, type FunctionTables } from './lower-table-lookups.js'

/** The closed functions that have load-time argument checks (esm-spec §9.2). */
const CHECKED_FUNCTIONS: ReadonlySet<string> = new Set([
  'interp.searchsorted',
  'interp.linear',
  'interp.bilinear',
])

/** JSON Pointer escaping of one reference token (RFC 6901). */
function escapePointer(token: string): string {
  return token.replace(/~/g, '~0').replace(/\//g, '~1')
}

/**
 * Run the §9.5.5 table checks on every `function_tables` entry, then the §9.2
 * argument checks on every checked `fn` node, of a loaded document. Throws the
 * first failure: a `TableLookupLoweringError` carrying a `table_*` code, or a
 * `ClosedFunctionError` carrying an `interp_*` / `searchsorted_*` code.
 */
export function checkFunctionTablesAndClosedFunctionCalls(doc: unknown): void {
  if (doc === null || typeof doc !== 'object') return
  const tables = (doc as { function_tables?: FunctionTables }).function_tables
  if (tables !== null && typeof tables === 'object') {
    for (const [id, table] of Object.entries(tables)) {
      validateFunctionTable(table, id)
    }
  }
  for (const [key, child] of Object.entries(doc)) {
    if (key === 'function_tables') continue
    walk(child, `/${escapePointer(key)}`)
  }
}

function walk(value: unknown, path: string): void {
  if (value === null || typeof value !== 'object') return
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) walk(value[i], `${path}/${i}`)
    return
  }
  const node = value as { op?: unknown; name?: unknown; args?: unknown }
  if (node.op === 'fn' && typeof node.name === 'string' && CHECKED_FUNCTIONS.has(node.name)) {
    checkClosedFunctionArguments(node.name, Array.isArray(node.args) ? node.args : [], path)
  }
  for (const [key, child] of Object.entries(value)) {
    // A `const` node's `value` is data: there is no expression inside it.
    if (node.op === 'const' && key === 'value') continue
    walk(child, `${path}/${escapePointer(key)}`)
  }
}
