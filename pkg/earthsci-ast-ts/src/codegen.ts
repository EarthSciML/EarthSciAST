/**
 * Tree-walking scalar evaluator (`compileExpression` / `evaluateExpression`)
 * — the EarthSciAST TypeScript in-process runner. Despite the historical
 * "codegen" filename this performs NO code generation: a canonical-form `Expr`
 * is walked directly. `compileExpression` returns a closure over a
 * free-variable bindings map that returns the scalar numeric result;
 * `evaluateExpression` walks and applies in one step.
 *
 * Structural / array ops are dispatched to their consumers.
 *
 * Both entry points walk the whole expression BEFORE evaluating any of it
 * (esm-spec §9.6.6) and refuse an operator this evaluator cannot evaluate: an op
 * outside the §4.2 evaluable core — the open-tier sugar
 * `grad`/`div`/`laplacian`/`integral`, a user op, or a spatial / right-hand-side
 * `D` — with `unlowered_operator`, and a core op with no scalar rule — the
 * array/query and value-invention ops, `Pre`, an unlowered `enum` — with
 * `unevaluable_operator`. An op in an untaken `ifelse` branch is refused too.
 */

import type { Expr, ExpressionNode } from './types.js'
import { isNumericLiteral } from './numeric-literal.js'
import { getOpInfo, checkArity } from './op-registry.js'
import { forEachChild } from './expression.js'
import { ERROR_CODES, EsmDiagnosticError } from './errors.js'

/**
 * Compiled expression closure produced by {@link compileExpression}.
 * Accepts a `bindings` map of free-variable name → numeric value and
 * returns the scalar result.
 */
export type CompiledExpression = (bindings: Map<string, number>) => number

/**
 * Error carrying the stable, cross-binding `unlowered_operator` diagnostic
 * (esm-spec §4.2 / §9.6.3 constraint 6 / §9.6.8). Raised when a rewrite-target
 * op reaches evaluation/compilation without having been lowered — one uniform
 * gate, the same in every binding. Loading stays permissive (the op namespace
 * is open); the gate fires only at evaluation, as in the Julia reference.
 */
export class UnloweredOperatorError extends EsmDiagnosticError {
  declare readonly code: typeof ERROR_CODES.UNLOWERED_OPERATOR
  constructor(message: string) {
    super(ERROR_CODES.UNLOWERED_OPERATOR, `[unlowered_operator] ${message}`)
    this.name = 'UnloweredOperatorError'
  }
}

/**
 * Error carrying the stable, cross-binding `unevaluable_operator` diagnostic
 * (esm-spec §9.6.6): an op that IS in the §4.2 evaluable-core set but that this
 * scalar evaluator has no rule for. The complement of
 * {@link UnloweredOperatorError}, which is for an op OUTSIDE the core, so it
 * carries no rewrite-rule advice: the op needs an earlier pipeline stage (value
 * invention, or a load-time lowering pass), not a rewrite rule.
 */
export class UnevaluableOperatorError extends EsmDiagnosticError {
  declare readonly code: typeof ERROR_CODES.UNEVALUABLE_OPERATOR
  /** The offending operator name. */
  readonly op: string
  constructor(op: string, remedy?: string) {
    super(
      ERROR_CODES.UNEVALUABLE_OPERATOR,
      `[unevaluable_operator] operator '${op}' is an evaluable-core op with no evaluation rule ` +
        `in the scalar evaluator: ${
          remedy ??
          'an earlier pipeline stage (value invention, or a load-time lowering pass) must ' +
            'eliminate it, or the document belongs to a runtime that evaluates it'
        } (esm-spec §4.2 / §9.6.6).`,
    )
    this.name = 'UnevaluableOperatorError'
    this.op = op
  }
}

/**
 * Evaluable-core ops (esm-spec §4.2) with no row in the scalar op registry
 * (`op-registry.ts`), which lists only ops with an arity contract. Membership
 * here is what tells a closed-core op with no scalar rule
 * (`unevaluable_operator`) apart from an open-tier op no rewrite rule lowered
 * (`unlowered_operator`). `const`, `true` and `false` are evaluated; the rest
 * are refused.
 */
const CORE_OPS_WITHOUT_REGISTRY_ROW: ReadonlySet<string> = new Set([
  'const',
  'true',
  'false',
  'enum',
  'apply_expression_template',
  'ic',
  'faq',
  'makearray',
  'index',
  'broadcast',
  'reshape',
  'transpose',
  'concat',
  'distinct',
])

/** The diagnostic for an op the scalar evaluator has no rule for. */
function unevaluableOperator(node: ExpressionNode): Error {
  if (
    node.op === 'D' ||
    (getOpInfo(node.op) === undefined && !CORE_OPS_WITHOUT_REGISTRY_ROW.has(node.op))
  ) {
    const wrt = node.op === 'D' && typeof node.wrt === 'string' ? ` (wrt=${node.wrt})` : ''
    return new UnloweredOperatorError(
      `unlowered rewrite-target operator '${node.op}'${wrt} reached evaluation: ` +
        `it must be lowered to a stencil by a rewrite rule before evaluation ` +
        `(esm-spec §4.2 / §9.6.8). This format ships no discretization rules ` +
        `(they live in EarthSciDiscretizations).`,
    )
  }
  if (node.op === 'enum') {
    return new UnevaluableOperatorError(
      'enum',
      "enum nodes must be lowered to 'const' integer nodes via lowerEnums() at load time",
    )
  }
  return new UnevaluableOperatorError(node.op)
}

/**
 * Walk `expr` without evaluating it and throw the diagnostic for the first
 * operator (pre-order) the scalar evaluator cannot evaluate (esm-spec §9.6.6:
 * the check precedes evaluation).
 */
function assertEvaluable(expr: Expr): void {
  if (typeof expr !== 'object' || expr === null || isNumericLiteral(expr)) return
  const node = expr as ExpressionNode
  if (typeof node.op !== 'string') return
  switch (node.op) {
    case 'const':
    case 'true':
    case 'false':
      return
  }
  const info = getOpInfo(node.op)
  if (node.op === 'D' || info === undefined || !info.evaluate) throw unevaluableOperator(node)
  forEachChild(node, (child) => assertEvaluable(child))
}

/**
 * Error raised by the tree-walking evaluator for a node it cannot reduce to a
 * scalar: an unbound variable, an unsupported operator, an unlowered `enum`, a
 * non-scalar `const`, or a non-expression value. Carries a
 * stable `code` field so callers can branch programmatically instead of
 * regex-matching prose.
 *
 * Unlike {@link UnloweredOperatorError}, the `message` is passed through
 * VERBATIM (not `[code]`-prefixed): several of these strings are matched
 * byte-for-byte by the cross-binding runner tests, so the wording is pinned.
 * These `code` values are binding-local diagnostics for the in-process runner,
 * distinct from the cross-language conformance codes in `errors.ts`.
 */
export class EvaluatorError extends EsmDiagnosticError {
  constructor(code: string, message: string) {
    super(code, message)
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
 * container ops such as `index`, not by scalar evaluation).
 */
export function compileExpression(expr: Expr): CompiledExpression {
  assertEvaluable(expr)
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
  assertEvaluable(expr)
  return evalExprNode(expr, bindings)
}

function evalExprNode(expr: Expr, bindings: Map<string, number>): number {
  if (typeof expr === 'number') {
    return expr
  } else if (isNumericLiteral(expr)) {
    return expr.value
  } else if (typeof expr === 'string') {
    const bound = bindings.get(expr)
    if (bound !== undefined) return bound
    throw new EvaluatorError(ERROR_CODES.UNBOUND_VARIABLE, `Unbound variable: ${expr}`)
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
    // callers that consume them (e.g. `index`).
    if (node.op === 'const') {
      const value: unknown = node.value
      if (typeof value === 'number') return value
      if (Array.isArray(value)) {
        throw new EvaluatorError(
          ERROR_CODES.CONST_NOT_SCALAR,
          'const node with array value cannot be evaluated as a scalar; arrays are consumed by container ops (e.g. index)',
        )
      }
      throw new EvaluatorError(
        ERROR_CODES.CONST_NOT_SCALAR,
        `const node with non-numeric value: ${typeof value}`,
      )
    }

    // enum nodes should have been lowered to const at load time. If
    // we see one here, the file was evaluated before the lowering
    // pass ran.
    if (node.op === 'enum') throw unevaluableOperator(node)

    // `true` / `false`: the boolean literals (esm-spec §4.2), in the
    // evaluator's float encoding.
    if (node.op === 'true') return 1
    if (node.op === 'false') return 0

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
    // `_compile` gate). The const/enum structural ops are handled above; a
    // registered-but-non-scalar op (`Pre`, `=`) passes this gate and falls
    // through to the `unevaluable_operator` arm below. Both entry points have
    // already refused all of these in their up-front walk. Loading stays permissive
    // — the open namespace tolerates these ops until evaluation.
    if (node.op === 'D' || getOpInfo(node.op) === undefined) throw unevaluableOperator(node)

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
    // reports, as `unevaluable_operator`.
    const info = getOpInfo(node.op)
    if (!info || !info.evaluate) throw new UnevaluableOperatorError(node.op)

    const args: number[] = node.args.map((arg) => evalExprNode(arg, bindings))
    checkArity(node.op, args.length)
    return info.evaluate(args)
  }

  throw new EvaluatorError(ERROR_CODES.INVALID_EXPRESSION, 'Invalid expression type')
}
