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
 * Errors:
 *   - Reference to an undeclared enum name → EnumLoweringError with a
 *     descriptive message (no spec-pinned diagnostic code at this time;
 *     follow-up if a stable code is added).
 *   - Reference to an unknown member of a declared enum → EnumLoweringError.
 */

import type { Expression, ExpressionNode } from './generated.js'
import type { EsmFile } from './types.js'
import { isNumericLiteral } from './numeric-literal.js'

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

function lowerExpr(expr: unknown, enums: EnumsMap): unknown {
  if (expr === null || expr === undefined) return expr
  if (typeof expr !== 'object') return expr
  if (isNumericLiteral(expr)) return expr
  if (Array.isArray(expr)) {
    let changed = false
    const out: unknown[] = new Array(expr.length)
    for (let i = 0; i < expr.length; i++) {
      const child = lowerExpr(expr[i], enums)
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
    // Generic op: recurse into args + every Expression-valued field.
    const out: Record<string, unknown> = {}
    let changed = false
    for (const key of Object.keys(node)) {
      const v = node[key]
      const lv = key === 'args' || /expr/i.test(key) || key === 'values' ? lowerExpr(v, enums) : v
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
    const lv = lowerExpr(v, enums)
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
    return lowerExpr(file, {} as EnumsMap) as EsmFile
  }
  return lowerExpr(file, enums) as EsmFile
}

// Re-export for tests.
export type { Expression, ExpressionNode }
