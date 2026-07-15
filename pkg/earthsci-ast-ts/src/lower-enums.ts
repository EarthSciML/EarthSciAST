/**
 * Load-time enum lowering pass — esm-spec §9.3.
 *
 * Walks the AST of a parsed EsmFile and rewrites every
 * `{op: "enum", args: [enum_name, member_name]}` node into the
 * equivalent `{op: "const", args: [], value: <integer>}` node, using the
 * file-local `enums` block to resolve the symbol.
 *
 * The pass is a no-op when no `enums` block is present. After lowering,
 * the file's expression trees contain no `enum` ops; the codegen
 * runner (`compileExpression` / `evaluateExpression`) sees only
 * `const`. Mirrors the Julia `lower_enums!` pass.
 *
 * Errors are `EnumLoweringError`s carrying stable, registry-backed diagnostic
 * codes (see `errors.ts` `ERROR_CODES`, mirrored by the Python `ErrorCode`
 * enum):
 *   - `enum_op_malformed` — an `enum` op whose args are not
 *     `[enum_name, member_name]` (two strings).
 *   - `enum_not_declared` — reference to an enum name not present in the file's
 *     top-level `enums` block.
 *   - `enum_member_not_found` — reference to an unknown member of a declared
 *     enum.
 */

import type { EsmFile } from './types.js'
import { isNumericLiteral } from './numeric-literal.js'
import { EXPRESSION_CHILD_KEYS } from './expression.js'

/** Shared source of truth for "which op fields carry child expressions". */
const EXPRESSION_CHILD_KEY_SET: ReadonlySet<string> = new Set(EXPRESSION_CHILD_KEYS)

export class EnumLoweringError extends Error {
  constructor(
    public code: string,
    message: string,
  ) {
    super(`[${code}] ${message}`)
    this.name = 'EnumLoweringError'
  }
}

type EnumsMap = { [k: string]: { [k: string]: number } }

/**
 * `memo` is an identity-keyed cache (one per `lowerEnums` run): template
 * expansion produces shared DAGs (`lower-expression-templates.ts`
 * `substitute`), so a subtree reachable through many parents is lowered once
 * and the single (possibly identical) result is spliced everywhere. The pass
 * was already identity-preserving; memoization keeps it linear in UNIQUE
 * nodes and preserves the sharing. Safe because the rewrite is a pure
 * function of the node and the fixed `enums` block.
 */
function lowerExpr(expr: unknown, enums: EnumsMap, memo: Map<object, unknown>): unknown {
  if (expr === null || expr === undefined) return expr
  if (typeof expr !== 'object') return expr
  if (isNumericLiteral(expr)) return expr
  const hit = memo.get(expr)
  if (hit !== undefined) return hit
  const res = lowerExprUncached(expr, enums, memo)
  memo.set(expr, res)
  return res
}

function lowerExprUncached(expr: object, enums: EnumsMap, memo: Map<object, unknown>): unknown {
  if (Array.isArray(expr)) {
    let changed = false
    const out: unknown[] = new Array(expr.length)
    for (let i = 0; i < expr.length; i++) {
      const child = lowerExpr(expr[i], enums, memo)
      if (child !== expr[i]) changed = true
      out[i] = child
    }
    return changed ? out : expr
  }

  const node = expr as Record<string, unknown>
  if (typeof node.op === 'string') {
    if (node.op === 'enum') {
      const args = node.args as unknown[] | undefined
      if (
        !Array.isArray(args) ||
        args.length !== 2 ||
        typeof args[0] !== 'string' ||
        typeof args[1] !== 'string'
      ) {
        throw new EnumLoweringError(
          'enum_op_malformed',
          `enum op requires args = [enum_name, member_name] (two strings); got ${JSON.stringify(args)}`,
        )
      }
      const [enumName, memberName] = args as [string, string]
      const decl = enums[enumName]
      if (!decl) {
        throw new EnumLoweringError(
          'enum_not_declared',
          `enum '${enumName}' is referenced by an 'enum' op but not declared in the file's top-level 'enums' block`,
        )
      }
      if (!Object.prototype.hasOwnProperty.call(decl, memberName)) {
        throw new EnumLoweringError(
          'enum_member_not_found',
          `enum '${enumName}' has no member '${memberName}'`,
        )
      }
      return { op: 'const', args: [], value: decl[memberName] }
    }
    // Generic op: recurse into every expression-bearing child field. Descent
    // uses `EXPRESSION_CHILD_KEYS` — the SAME single source of truth the shared
    // walker (`mapChildren`/`forEachChild`) and the rest of the package trust —
    // rather than a local `/expr/i` heuristic that both diverged from that set
    // and skipped aggregate `filter`/`key`, `table_lookup` `axes`, and template
    // `bindings`. Non-child fields (`op`, `wrt`, `dim`, `reduce`, `value`, …)
    // are copied verbatim, preserving key order and structural sharing (map
    // fields `axes`/`bindings` recurse through the plain-object branch below,
    // which keeps their key order).
    const out: Record<string, unknown> = {}
    let changed = false
    for (const key of Object.keys(node)) {
      const v = node[key]
      const lv = EXPRESSION_CHILD_KEY_SET.has(key) ? lowerExpr(v, enums, memo) : v
      if (lv !== v) changed = true
      out[key] = lv
    }
    return changed ? out : node
  }

  // Plain object (no op): recurse into every value (catches nested
  // models/equations/etc).
  let changed = false
  const out: Record<string, unknown> = {}
  for (const key of Object.keys(node)) {
    const v = node[key]
    const lv = lowerExpr(v, enums, memo)
    if (lv !== v) changed = true
    out[key] = lv
  }
  return changed ? out : node
}

/**
 * Resolve every `enum` op in `file` against `file.enums`. Returns the
 * (possibly identical) input — the rewrite is structural, immutable:
 * unchanged subtrees are shared with the input.
 */
export function lowerEnums(file: EsmFile): EsmFile {
  const enums = (file as unknown as { enums?: EnumsMap }).enums
  if (!enums || Object.keys(enums).length === 0) {
    // Still scan: an enum op without a declaration is an error and we
    // want it surfaced even if the user forgot the block.
    return lowerExpr(file, {} as EnumsMap, new Map()) as EsmFile
  }
  return lowerExpr(file, enums, new Map()) as EsmFile
}
