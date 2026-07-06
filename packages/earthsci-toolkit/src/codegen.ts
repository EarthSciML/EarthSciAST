/**
 * In-language AST → JavaScript lowering (`compileExpression` /
 * `evaluateExpression`) — the official ESS TypeScript runner per
 * `AGENTS.md` "Official per-binding runners". A canonical-form
 * `Expr` is lowered to a closure that takes a free-variable bindings
 * map and returns the scalar numeric result.
 */

import type { Expr, ExpressionNode } from './types.js'
import { isNumericLiteral } from './numeric-literal.js'
import { dispatchClosedFunction } from './registered_functions.js'
import { getOpInfo, checkArity } from './op-registry.js'

/**
 * Compiled expression closure produced by {@link compileExpression}.
 * Accepts a `bindings` map of free-variable name → numeric value and
 * returns the scalar result.
 */
export type CompiledExpression = (bindings: Map<string, number>) => number

/**
 * Rewrite-target ops (esm-spec §4.2, docs/rfcs/open-op-namespace-fixpoint-rewrite.md):
 * a spatial / right-hand-side `D`, and the `grad`/`div`/`laplacian` sugar ops.
 * They carry NO evaluator implementation — each MUST be lowered to an
 * `aggregate`/`makearray` stencil by a rewrite rule (§9.6) before evaluation.
 * This format ships no discretization rules (the std-lib lives in
 * EarthSciDiscretizations). One reaching the evaluator means no rule lowered it.
 */
const REWRITE_TARGET_OPS = new Set<string>(['D', 'grad', 'div', 'laplacian'])

/**
 * Error carrying the stable, cross-binding `unlowered_operator` diagnostic
 * (esm-spec §4.2 / §9.6.3 constraint 6 / §9.6.8). Raised when a rewrite-target
 * op reaches evaluation/compilation without having been lowered — the uniform
 * gate that supersedes the old per-binding UnreachableSpatialOperator /
 * UnsupportedDimensionality codes. Loading stays permissive (the op namespace
 * is open); the gate fires only at evaluation, mirroring the Julia `_compile`
 * gate in tree_walk.jl.
 */
export class UnloweredOperatorError extends Error {
  readonly code = 'unlowered_operator'
  constructor(message: string) {
    super(`[unlowered_operator] ${message}`)
    this.name = 'UnloweredOperatorError'
  }
}

/**
 * Lower a canonical-AST {@link Expr} into a JavaScript function for
 * in-process scalar evaluation. This is the official ESS TypeScript
 * runner entry point for evaluating an expression against a bindings
 * map (per AGENTS.md "Official per-binding runners" and audit
 * esm-rv3 §1.3 / bead esm-3r4).
 *
 * The walker rejects unlowered `enum` ops (lower via `lowerEnums()` at
 * load time) and array-valued `const` nodes (those are consumed by
 * container ops such as `interp.searchsorted` and `index`, not by
 * scalar evaluation).
 */
export function compileExpression(expr: Expr): CompiledExpression {
  return (bindings: Map<string, number>) => evalExprNode(expr, bindings)
}

/**
 * Compile and apply in one step. Equivalent to
 * `compileExpression(expr)(bindings)` but avoids allocating a closure
 * for one-shot callers (`simplify`'s constant-folding path,
 * fixed-point observed-variable resolution, unit-conversion
 * folding).
 */
export function evaluateExpression(expr: Expr, bindings: Map<string, number>): number {
  return evalExprNode(expr, bindings)
}

function evalExprNode(expr: Expr, bindings: Map<string, number>): number {
  if (typeof expr === 'number') {
    return expr
  } else if (isNumericLiteral(expr)) {
    return expr.value
  } else if (typeof expr === 'string') {
    if (bindings.has(expr)) {
      return bindings.get(expr)!
    }
    throw new Error(`Unbound variable: ${expr}`)
  } else if (typeof expr === 'object' && (expr as ExpressionNode).op) {
    const node = expr as any

    // const: inline literal — only meaningful as a scalar when its
    // value is a number; array-valued const nodes are extracted by
    // callers that consume them (e.g. interp.searchsorted's xs arg).
    if (node.op === 'const') {
      const v = node.value
      if (typeof v === 'number') return v
      if (Array.isArray(v)) {
        throw new Error('const node with array value cannot be evaluated as a scalar; arrays are consumed by container ops (e.g. interp.searchsorted, index)')
      }
      throw new Error(`const node with non-numeric value: ${typeof v}`)
    }

    // enum nodes should have been lowered to const at load time. If
    // we see one here, the file was evaluated before the lowering
    // pass ran.
    if (node.op === 'enum') {
      throw new Error("enum op encountered during evaluateExpression(); enum nodes must be lowered to 'const' integer nodes via lowerEnums() at load time")
    }

    // fn: closed function registry dispatch (esm-spec §9.2). Most
    // args evaluate to scalars; interp.searchsorted's second arg is
    // a const array that we extract WITHOUT evaluating it through
    // the scalar path.
    if (node.op === 'fn') {
      const fnName = node.name
      if (typeof fnName !== 'string') {
        throw new Error('fn op missing required string `name` field')
      }
      const fnArgs = node.args.map((arg: any) => {
        if (arg && typeof arg === 'object' && (arg as ExpressionNode).op === 'const' && Array.isArray((arg as any).value)) {
          return (arg as any).value
        }
        return evalExprNode(arg, bindings)
      })
      return dispatchClosedFunction(fnName, fnArgs)
    }

    // Rewrite-target op gate (esm-spec §4.2 / §9.6.8): a spatial/RHS `D` or a
    // grad/div/laplacian sugar op that reaches evaluation was never lowered to
    // a stencil. Fire the uniform `unlowered_operator` diagnostic BEFORE
    // evaluating args (mirrors the Julia `_compile` gate). Loading stays
    // permissive — the open namespace tolerates these ops until evaluation.
    if (typeof node.op === 'string' && REWRITE_TARGET_OPS.has(node.op)) {
      const wrt = node.op === 'D' && typeof node.wrt === 'string' ? ` (wrt=${node.wrt})` : ''
      throw new UnloweredOperatorError(
        `unlowered rewrite-target operator '${node.op}'${wrt} reached evaluation: ` +
          `it must be lowered to a stencil by a rewrite rule before evaluation ` +
          `(esm-spec §4.2 / §9.6.8). This format ships no discretization rules ` +
          `(they live in EarthSciDiscretizations).`,
      )
    }

    // Scalar operators dispatch through the central op registry: arity
    // bounds and the evaluator body live in ONE table (op-registry.ts), so
    // adding an operator is a single registry entry.
    const info = getOpInfo(node.op)
    if (!info || !info.evaluate) {
      throw new Error(`Unsupported operator: ${node.op}`)
    }

    const args: number[] = node.args.map((arg: any) => evalExprNode(arg, bindings))
    checkArity(node.op, args.length)
    return info.evaluate(args)
  }

  throw new Error('Invalid expression type')
}
