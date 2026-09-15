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
 *   - `unknown_enum` — reference to an enum name not present in the file's
 *     top-level `enums` block (esm-spec §4.5).
 *   - `unknown_enum_symbol` — reference to an unknown member of a declared
 *     enum (esm-spec §4.5).
 */

import type { EsmFile } from './types.js'
import { isNumericLiteral } from './numeric-literal.js'
import { EXPRESSION_CHILD_KEYS } from './expression.js'
import { ERROR_CODES, EsmDiagnosticError } from './errors.js'

/** Shared source of truth for "which op fields carry child expressions". */
const EXPRESSION_CHILD_KEY_SET: ReadonlySet<string> = new Set(EXPRESSION_CHILD_KEYS)

export class EnumLoweringError extends EsmDiagnosticError {
  declare code: string
  constructor(code: string, message: string) {
    super(code, `[${code}] ${message}`)
    this.name = 'EnumLoweringError'
  }
}

type EnumsMap = { [k: string]: { [k: string]: number } }

/** The `const` node `enums[enumName][memberName]` lowers to. */
function lowerEnumReference(
  enumName: string,
  memberName: string,
  enums: EnumsMap,
): Record<string, unknown> {
  const decl = Object.prototype.hasOwnProperty.call(enums, enumName) ? enums[enumName] : undefined
  if (!decl) {
    throw new EnumLoweringError(
      ERROR_CODES.UNKNOWN_ENUM,
      `enum '${enumName}' is referenced by an 'enum' op but not declared in the file's top-level 'enums' block`,
    )
  }
  if (!Object.prototype.hasOwnProperty.call(decl, memberName)) {
    throw new EnumLoweringError(
      ERROR_CODES.UNKNOWN_ENUM_SYMBOL,
      `enum '${enumName}' has no member '${memberName}'`,
    )
  }
  return { op: 'const', args: [], value: decl[memberName] }
}

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
          ERROR_CODES.ENUM_OP_MALFORMED,
          `enum op requires args = [enum_name, member_name] (two strings); got ${JSON.stringify(args)}`,
        )
      }
      return lowerEnumReference(args[0], args[1], enums)
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

/**
 * Return raw-JSON `target` with its `enum` ops lowered against the `enums`
 * block of `document`, the file that wrote `target`. `target` is not modified.
 *
 * An `enum` op is file-local (esm-spec §9.3): it resolves against the block of
 * the file it is written in. {@link lowerEnums} runs once over the root
 * document, so a tree that crosses a file boundary before that pass (a
 * template-library body reaching an importer, §9.7.5) is lowered here, at the
 * edge, while its own file's block is still at hand.
 *
 * An op with an argument spelled by a name in `openNames` is left in place: a
 * template parameter substitutes position-blind (§9.6.3 constraint 5), so the
 * call site decides what it spells and the op resolves there. An op whose
 * arguments are not two strings is left for {@link lowerEnums}, which owns the
 * malformed-op diagnostic.
 */
export function lowerEnumOpsForFile(
  document: unknown,
  target: unknown,
  openNames: ReadonlySet<string> = new Set(),
): unknown {
  const block =
    document !== null && typeof document === 'object'
      ? (document as { enums?: unknown }).enums
      : undefined
  const enums = (block !== null && typeof block === 'object' ? block : {}) as EnumsMap
  const walk = (node: unknown): unknown => {
    if (Array.isArray(node)) return node.map(walk)
    if (node === null || typeof node !== 'object' || isNumericLiteral(node)) return node
    const obj = node as Record<string, unknown>
    if (obj.op === 'enum') {
      const args = obj.args
      if (
        !Array.isArray(args) ||
        args.length !== 2 ||
        typeof args[0] !== 'string' ||
        typeof args[1] !== 'string' ||
        openNames.has(args[0]) ||
        openNames.has(args[1])
      ) {
        return node
      }
      return lowerEnumReference(args[0], args[1], enums)
    }
    const out: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(obj)) out[k] = walk(v)
    return out
  }
  return walk(target)
}
