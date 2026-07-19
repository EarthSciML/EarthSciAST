/**
 * Tree-walking scalar evaluator (`compileExpression` / `evaluateExpression`)
 * — the EarthSciAST TypeScript in-process runner. Despite the historical
 * "codegen" filename this performs NO code generation or lowering: a
 * canonical-form `Expr` is walked directly. `compileExpression` returns a
 * closure over a free-variable bindings map that returns the scalar numeric
 * result; `evaluateExpression` walks and applies in one step.
 *
 * Structural / array ops and the closed-function registry are dispatched to
 * their consumers; ANY op the evaluable-core op-registry does not know — the
 * open-tier rewrite-target sugar `grad`/`div`/`laplacian`/`integral`, a user op,
 * or a spatial / right-hand-side `D` — is rejected here as an unlowered
 * rewrite-target: it must be lowered to a stencil by a rewrite rule before
 * evaluation.
 */

import type { Expr, Expression, ExpressionNode } from './types.js'
import { isNumericLiteral } from './numeric-literal.js'
import { dispatchClosedFunction } from './closed-functions.js'
import { getOpInfo, checkArity } from './op-registry.js'

/**
 * Compiled expression closure produced by {@link compileExpression}.
 * Accepts a `bindings` map of free-variable name → numeric value and
 * returns the scalar result.
 */
export type CompiledExpression = (bindings: Map<string, number>) => number

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
 * Error raised by the tree-walking evaluator for a node it cannot reduce to a
 * scalar: an unbound variable, an unsupported operator, an unlowered `enum`, a
 * non-scalar `const`, a malformed `fn`, or a non-expression value. Carries a
 * stable `code` field so callers can branch programmatically instead of
 * regex-matching prose.
 *
 * Unlike {@link UnloweredOperatorError}, the `message` is passed through
 * VERBATIM (not `[code]`-prefixed): several of these strings are matched
 * byte-for-byte by the cross-binding runner tests, so the wording is pinned.
 * These `code` values are binding-local diagnostics for the in-process runner,
 * distinct from the cross-language conformance codes in `errors.ts`.
 */
export class EvaluatorError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message)
    this.name = 'EvaluatorError'
  }
}

/**
 * Build a reusable closure that walks the canonical-AST {@link Expr} and
 * evaluates it against a bindings map. This is the EarthSciAST TypeScript
 * runner's entry point for scalar evaluation.
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

/**
 * Extract an array-valued `const` node's inline literal, or `null` when `arg`
 * is not one. Container closed-functions (`interp.*`) receive their table /
 * axis operands this way — as the raw array, NOT scalar-evaluated. The check is
 * arity-agnostic (it does not require an `args` field) so hand-built and
 * canonical `const` nodes are both recognized.
 */
function constArrayValue(arg: Expression): unknown[] | null {
  if (typeof arg === 'object' && arg !== null && (arg as { op?: unknown }).op === 'const') {
    const value = (arg as { value?: unknown }).value
    if (Array.isArray(value)) return value
  }
  return null
}

function evalExprNode(expr: Expr, bindings: Map<string, number>): number {
  if (typeof expr === 'number') {
    return expr
  } else if (isNumericLiteral(expr)) {
    return expr.value
  } else if (typeof expr === 'string') {
    const bound = bindings.get(expr)
    if (bound !== undefined) return bound
    throw new EvaluatorError('unbound_variable', `Unbound variable: ${expr}`)
  } else if (typeof expr === 'object' && expr !== null && (expr as ExpressionNode).op) {
    // Narrow the schema-level `{ [k]: unknown }` expression object to the rich
    // `ExpressionNode` view once, at this boundary, so the branches below read
    // its fields typed rather than via scattered `as any`. `const`/`enum` nodes
    // may legitimately omit `args`, so this cast (not the stricter `isExprNode`
    // guard, which requires `args`) is the correct gate here — the args-bearing
    // fields are only accessed on the ops that carry them.
    const node = expr as ExpressionNode

    // const: inline literal — only meaningful as a scalar when its
    // value is a number; array-valued const nodes are extracted by
    // callers that consume them (e.g. interp.searchsorted's xs arg).
    if (node.op === 'const') {
      const value: unknown = node.value
      if (typeof value === 'number') return value
      if (Array.isArray(value)) {
        throw new EvaluatorError(
          'const_not_scalar',
          'const node with array value cannot be evaluated as a scalar; arrays are consumed by container ops (e.g. interp.searchsorted, index)',
        )
      }
      throw new EvaluatorError(
        'const_not_scalar',
        `const node with non-numeric value: ${typeof value}`,
      )
    }

    // enum nodes should have been lowered to const at load time. If
    // we see one here, the file was evaluated before the lowering
    // pass ran.
    if (node.op === 'enum') {
      throw new EvaluatorError(
        'enum_not_lowered',
        "enum op encountered during evaluateExpression(); enum nodes must be lowered to 'const' integer nodes via lowerEnums() at load time",
      )
    }

    // fn: closed function registry dispatch (esm-spec §9.2). Most
    // args evaluate to scalars; interp.searchsorted's second arg is
    // a const array that we extract WITHOUT evaluating it through
    // the scalar path.
    if (node.op === 'fn') {
      const fnName = node.name
      if (typeof fnName !== 'string') {
        throw new EvaluatorError('fn_missing_name', 'fn op missing required string `name` field')
      }
      const fnArgs: unknown[] = node.args.map((arg): unknown => {
        const arr = constArrayValue(arg)
        return arr !== null ? arr : evalExprNode(arg, bindings)
      })
      return dispatchClosedFunction(fnName, fnArgs)
    }

    // Rewrite-target op gate (esm-spec §4.2 / §9.6.8). The evaluable-core op
    // vocabulary is the op-registry (op-registry.ts) — the SINGLE SOURCE OF
    // TRUTH, no bespoke {grad,div,laplacian} name list. ANY op reaching
    // evaluation that the registry does not know is an OPEN-TIER rewrite-target:
    // the optional spatial sugar `grad`/`div`/`laplacian`/`integral`, or a user
    // op such as `godunov_hamiltonian`. It carries no evaluator and must have
    // been lowered to a stencil by a rewrite rule (§9.6) first. `D` is the one
    // registered op that is evaluable-core ONLY in its structural equation-LHS
    // role (§4.2) — reaching THIS scalar evaluator (a spatial `D`, or any `D` in
    // an RHS / observed / rate position) it is likewise an unlowered
    // rewrite-target, so it is named explicitly. Both fire the uniform
    // `unlowered_operator` diagnostic BEFORE evaluating args (mirrors the Julia
    // `_compile` gate). The const/enum/fn structural ops are handled above; a
    // registered-but-non-scalar op (`Pre`, `=`) passes this gate and falls
    // through to the `unsupported_operator` arm below. Loading stays permissive
    // — the open namespace tolerates these ops until evaluation.
    if (node.op === 'D' || getOpInfo(node.op) === undefined) {
      const wrt = node.op === 'D' && typeof node.wrt === 'string' ? ` (wrt=${node.wrt})` : ''
      throw new UnloweredOperatorError(
        `unlowered rewrite-target operator '${node.op}'${wrt} reached evaluation: ` +
          `it must be lowered to a stencil by a rewrite rule before evaluation ` +
          `(esm-spec §4.2 / §9.6.8). This format ships no discretization rules ` +
          `(they live in EarthSciDiscretizations).`,
      )
    }

    // LAZY OPS — evaluated BEFORE the eager `args.map` below.
    //
    // `ifelse`, `and` and `or` short-circuit: an operand that the semantics say
    // is not reached must not be evaluated. Running them eagerly breaks the
    // canonical guard idiom, because the *untaken* branch's domain error still
    // propagates:
    //
    //     ifelse(x > 0, log(x), 0)   at x = -1   ->  threw "log argument must be positive"
    //     ifelse(x != 0, 1/x, 0)     at x = 0    ->  threw "Division by zero"
    //     or(1, <unbound>)                       ->  threw "Unbound variable"
    //
    // all of which must instead yield the guarded value. (Julia's `_eval_node_op`
    // is lazy for exactly these three.)
    const truthy = (v: number): boolean => v !== 0
    if (node.op === 'ifelse') {
      checkArity(node.op, node.args.length)
      return truthy(evalExprNode(node.args[0], bindings))
        ? evalExprNode(node.args[1], bindings)
        : evalExprNode(node.args[2], bindings)
    }
    if (node.op === 'and') {
      checkArity(node.op, node.args.length)
      // Short-circuit on the first falsy operand.
      for (const arg of node.args) {
        if (!truthy(evalExprNode(arg, bindings))) return 0
      }
      return 1
    }
    if (node.op === 'or') {
      checkArity(node.op, node.args.length)
      // Short-circuit on the first truthy operand.
      for (const arg of node.args) {
        if (truthy(evalExprNode(arg, bindings))) return 1
      }
      return 0
    }

    // Scalar operators dispatch through the central op registry: arity
    // bounds and the evaluator body live in ONE table (op-registry.ts), so
    // adding an operator is a single registry entry. The gate above already
    // rejected every UNREGISTERED op as `unlowered_operator`, so `info` is
    // defined here; a registered op that carries no scalar evaluator (`Pre`,
    // `=` — structural, not scalar-evaluable) is the only thing this arm
    // reports as `unsupported_operator`.
    const info = getOpInfo(node.op)
    if (!info || !info.evaluate) {
      throw new EvaluatorError('unsupported_operator', `Unsupported operator: ${node.op}`)
    }

    const args: number[] = node.args.map((arg) => evalExprNode(arg, bindings))
    checkArity(node.op, args.length)
    return info.evaluate(args)
  }

  throw new EvaluatorError('invalid_expression', 'Invalid expression type')
}
