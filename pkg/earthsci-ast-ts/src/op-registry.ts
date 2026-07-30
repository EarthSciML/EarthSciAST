/**
 * Central registry of built-in AST operators (esm-spec §4).
 *
 * One table carries, per operator:
 *   - arity bounds (+ the human name used in arity error messages),
 *   - whether the operator is SCALAR (pointwise) — see {@link OpInfo.scalar},
 *   - the scalar evaluator used by the official TS runner (codegen.ts),
 *   - infix precedence for the pretty-printers (absent = renders as a
 *     function call),
 *   - a relative computational-cost weight for complexity analysis.
 *
 * Adding a new scalar operator is ONE entry here plus any per-format render
 * strings in pretty-print.ts. Open-tier rewrite-target sugar (grad, div,
 * laplacian, integral) is NOT registered here — it carries no evaluator and,
 * per esm-spec §4.2, gets no special treatment: it renders through the
 * generic pretty-print fallback and is lowered by rewrite rules before
 * evaluation. Structural ops (const, enum, fn, aggregate, ...) are handled
 * specially by their consumers and carry no `evaluate`.
 */

/** Inclusive arity bounds; `max: null` means unbounded. */
export interface OpArity {
  min: number
  max: number | null
}

export interface OpInfo {
  arity: OpArity
  /**
   * Is this a SCALAR operator — one whose meaning is a POINTWISE map from
   * scalar operands to a scalar result (esm-spec §4.2 arithmetic, elementary
   * functions, comparisons, logical connectives and `ifelse`)?
   *
   * ONE flag answers two questions the format asks in two places, because they
   * are the same question:
   *
   *   - **What may a `broadcast` node's `fn` name?** §4.3.4: "the `fn` value
   *     must name a scalar operator". That is what makes the `broadcast`
   *     contract stateable in one line — `{op:'broadcast', fn:F, args:A}` means
   *     what `{op:F, args:A}` means, applied element-wise — and it is what
   *     {@link checkBroadcastFn} enforces, deriving the legal operand count
   *     from the SAME row's {@link OpInfo.arity} rather than from a second,
   *     hand-maintained "broadcast arity" table.
   *   - **Does element alignment descend into a node's operands?** An
   *     ARRAY-LEVEL `a * b` means "combine corresponding elements", so its
   *     operands must first be brought onto a common index frame (§4.3.4).
   *     Every other op consumes its operands WHOLE under its own contract — an
   *     `aggregate`/`makearray` names its axes, an `index` gathers, the shape
   *     ops restructure, a geometry kernel returns an unrelated shape — so
   *     alignment must not reach inside them. {@link isElementwiseNode} lifts
   *     this flag from op NAMES to NODES.
   *
   * Every exclusion is load-bearing. Not scalar: the array/tensor ops
   * (`aggregate`, `makearray`, `index`, `reshape`, `transpose`, `concat`, and
   * `broadcast` ITSELF — a self-referential `fn: 'broadcast'` would recurse
   * forever); the closed-registry invocation `fn`; the form/lowering ops (`D`,
   * `ic`, `Pre`, `const`, `true`, `enum`, `table_lookup`,
   * `apply_expression_template`); and the relational/geometry kernels. `=` is
   * likewise NOT scalar: the registry has no alias mechanism, and `=` is not a
   * spelling of `==` (nor `pow`/`**` of `^`) — it carries no evaluator and is
   * not an operator this format applies element-wise.
   *
   * Because the flag lives ON the arity row, a scalar operator is by
   * construction a registered one: there is no way to classify a name the
   * registry does not know, and no way for the two facts to drift apart.
   */
  scalar?: true
  /**
   * Human name used in arity error messages (e.g. 'Division requires
   * exactly 2 arguments'). Defaults to the operator symbol itself.
   */
  arityName?: string
  /**
   * Infix precedence for parenthesization (higher binds tighter). Absent
   * for operators that render as function calls.
   */
  precedence?: number
  /**
   * Scalar evaluator per the official ESS TypeScript runner semantics.
   * Domain checks (positive log argument, ...) live inside. Absent for
   * ops that cannot be scalar-evaluated.
   */
  evaluate?: (args: number[]) => number
  /** Relative computational cost (units of one addition). */
  cost?: number
}

/** Cost assumed for operators without a registry entry / cost. */
export const DEFAULT_OP_COST = 10

/** Precedence assigned to function-call rendering (binds tightest). */
export const FUNCTION_PRECEDENCE = 8

export const OPS: Record<string, OpInfo> = {
  // ---- arithmetic -------------------------------------------------------
  // n-ary FROM ONE OPERAND, not from zero: `{op:'+', args:[x]}` is `x` (the
  // identity §4.3.4 relies on to settle the one-operand `broadcast` case), but
  // an EMPTY `+` denotes nothing the spec defines. Rust, Julia and Python all
  // floor these at 1; TS alone accepted `args: []` and folded it to the
  // semiring identity, so the same document loaded here and failed elsewhere.
  '+': {
    arity: { min: 1, max: null },
    scalar: true,
    precedence: 4,
    cost: 1,
    evaluate: (args) => args.reduce((sum, val) => sum + val, 0),
  },
  '-': {
    arity: { min: 1, max: null },
    scalar: true,
    precedence: 4,
    cost: 1,
    evaluate: (args) =>
      args.length === 1
        ? -args[0]
        : args.reduce((diff, val, idx) => (idx === 0 ? val : diff - val)),
  },
  // Floored at 1 for the same reason as `+` — see the note there.
  '*': {
    arity: { min: 1, max: null },
    scalar: true,
    precedence: 5,
    cost: 2,
    evaluate: (args) => args.reduce((prod, val) => prod * val, 1),
  },
  '/': {
    arity: { min: 2, max: 2 },
    scalar: true,
    arityName: 'Division',
    precedence: 5,
    cost: 4,
    evaluate: (args) => {
      if (args[1] === 0) throw new Error('Division by zero')
      return args[0] / args[1]
    },
  },
  '^': {
    arity: { min: 2, max: 2 },
    scalar: true,
    arityName: 'Exponentiation',
    precedence: 7,
    cost: 8,
    evaluate: (args) => Math.pow(args[0], args[1]),
  },
  // The CANONICAL unary negation `canonicalize.ts` emits (`-(0, x)` folds to
  // `neg(x)`, and `neg(neg(x))` to `x`). It is an ordinary scalar operator —
  // §4.2 arithmetic, listed in the schema's `broadcast.fn` scalar subset and
  // spelled by `tests/fixtures/arrayop/27_broadcast_unary.esm` — so it belongs
  // in the registry rather than falling through to the unlowered-op gate.
  neg: { arity: { min: 1, max: 1 }, scalar: true, cost: 1, evaluate: (args) => -args[0] },

  // ---- exponential / logarithmic ---------------------------------------
  exp: { arity: { min: 1, max: 1 }, scalar: true, cost: 20, evaluate: (args) => Math.exp(args[0]) },
  log: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 15,
    evaluate: (args) => {
      if (args[0] <= 0) throw new Error('log argument must be positive')
      return Math.log(args[0])
    },
  },
  // `ln` is the natural logarithm under its alternate spelling — a DISTINCT
  // registered name, not an alias (the registry has no alias mechanism). It is
  // carried in the schema's `broadcast.fn` scalar subset and is already
  // dimension-analysed by `units.ts`, so registering it here is what lets one
  // name be both checked and evaluated instead of half-known.
  ln: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 15,
    evaluate: (args) => {
      if (args[0] <= 0) throw new Error('ln argument must be positive')
      return Math.log(args[0])
    },
  },
  log10: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 15,
    evaluate: (args) => {
      if (args[0] <= 0) throw new Error('log10 argument must be positive')
      return Math.log10(args[0])
    },
  },
  sqrt: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 6,
    evaluate: (args) => {
      if (args[0] < 0) throw new Error('sqrt argument must be non-negative')
      return Math.sqrt(args[0])
    },
  },
  abs: { arity: { min: 1, max: 1 }, scalar: true, cost: 1, evaluate: (args) => Math.abs(args[0]) },

  // ---- trigonometric ----------------------------------------------------
  sin: { arity: { min: 1, max: 1 }, scalar: true, cost: 12, evaluate: (args) => Math.sin(args[0]) },
  cos: { arity: { min: 1, max: 1 }, scalar: true, cost: 12, evaluate: (args) => Math.cos(args[0]) },
  tan: { arity: { min: 1, max: 1 }, scalar: true, cost: 15, evaluate: (args) => Math.tan(args[0]) },
  asin: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 18,
    evaluate: (args) => {
      if (args[0] < -1 || args[0] > 1) throw new Error('asin argument must be in [-1, 1]')
      return Math.asin(args[0])
    },
  },
  acos: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 18,
    evaluate: (args) => {
      if (args[0] < -1 || args[0] > 1) throw new Error('acos argument must be in [-1, 1]')
      return Math.acos(args[0])
    },
  },
  atan: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 18,
    evaluate: (args) => Math.atan(args[0]),
  },
  atan2: {
    arity: { min: 2, max: 2 },
    scalar: true,
    cost: 20,
    evaluate: (args) => Math.atan2(args[0], args[1]),
  },

  // ---- hyperbolic ---------------------------------------------------------
  sinh: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 15,
    evaluate: (args) => Math.sinh(args[0]),
  },
  cosh: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 15,
    evaluate: (args) => Math.cosh(args[0]),
  },
  tanh: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 15,
    evaluate: (args) => Math.tanh(args[0]),
  },
  asinh: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 18,
    evaluate: (args) => Math.asinh(args[0]),
  },
  acosh: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 18,
    evaluate: (args) => {
      if (args[0] < 1) throw new Error('acosh argument must be >= 1')
      return Math.acosh(args[0])
    },
  },
  atanh: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 18,
    evaluate: (args) => {
      if (args[0] <= -1 || args[0] >= 1) throw new Error('atanh argument must be in (-1, 1)')
      return Math.atanh(args[0])
    },
  },

  // ---- rounding / selection ----------------------------------------------
  min: {
    arity: { min: 2, max: null },
    scalar: true,
    cost: 3,
    evaluate: (args) => Math.min(...args),
  },
  max: {
    arity: { min: 2, max: null },
    scalar: true,
    cost: 3,
    evaluate: (args) => Math.max(...args),
  },
  floor: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 2,
    evaluate: (args) => Math.floor(args[0]),
  },
  ceil: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 2,
    evaluate: (args) => Math.ceil(args[0]),
  },
  sign: {
    arity: { min: 1, max: 1 },
    scalar: true,
    cost: 1,
    evaluate: (args) => Math.sign(args[0]),
  },

  // ---- comparison / logical ----------------------------------------------
  '>': {
    arity: { min: 2, max: 2 },
    scalar: true,
    precedence: 3,
    cost: 2,
    evaluate: (args) => (args[0] > args[1] ? 1 : 0),
  },
  '<': {
    arity: { min: 2, max: 2 },
    scalar: true,
    precedence: 3,
    cost: 2,
    evaluate: (args) => (args[0] < args[1] ? 1 : 0),
  },
  '>=': {
    arity: { min: 2, max: 2 },
    scalar: true,
    precedence: 3,
    cost: 2,
    evaluate: (args) => (args[0] >= args[1] ? 1 : 0),
  },
  '<=': {
    arity: { min: 2, max: 2 },
    scalar: true,
    precedence: 3,
    cost: 2,
    evaluate: (args) => (args[0] <= args[1] ? 1 : 0),
  },
  '==': {
    arity: { min: 2, max: 2 },
    scalar: true,
    precedence: 3,
    cost: 2,
    evaluate: (args) => (args[0] === args[1] ? 1 : 0),
  },
  '!=': {
    arity: { min: 2, max: 2 },
    scalar: true,
    precedence: 3,
    cost: 2,
    evaluate: (args) => (args[0] !== args[1] ? 1 : 0),
  },
  '=': { arity: { min: 2, max: 2 }, precedence: 3 },
  // A CONNECTIVE needs two things to connect. The §4.2 conditionals table reads
  // "| `and`, `or`, `not` | `[a, b]` or `[a]` |" — one Args cell shared by three
  // ops, where `[a]` is `not`'s unary form and `[a, b]` is `and`/`or`'s binary
  // one. It is not a licence for a one-operand `and`: Rust, Julia and Python all
  // floor these at 2, and a `broadcast(fn:'and', [x])` that loads here and is
  // rejected by the other three is exactly the silent registry divergence
  // §4.3.4's `fn` rule exists to close.
  and: {
    arity: { min: 2, max: null },
    scalar: true,
    precedence: 2,
    cost: 2,
    evaluate: (args) => (args.every((x) => x !== 0) ? 1 : 0),
  },
  or: {
    arity: { min: 2, max: null },
    scalar: true,
    precedence: 1,
    cost: 2,
    evaluate: (args) => (args.some((x) => x !== 0) ? 1 : 0),
  },
  not: {
    arity: { min: 1, max: 1 },
    scalar: true,
    precedence: 6,
    cost: 1,
    evaluate: (args) => (args[0] === 0 ? 1 : 0),
  },
  ifelse: {
    arity: { min: 3, max: 3 },
    scalar: true,
    cost: 3,
    evaluate: (args) => (args[0] !== 0 ? args[1] : args[2]),
  },

  // ---- event / structural ops (no scalar evaluator) -----------------------
  Pre: { arity: { min: 1, max: 1 }, cost: 5 },
  // The registry is keyed by op STRING, so this row states the STRUCTURAL time
  // derivative's contract (`wrt: 't'`, or an absent `wrt`): evaluable-core,
  // consumed by system assembly, STRICTLY UNARY. A spatial `D` is a
  // rewrite-target whose arity relaxes — see `isRewriteTargetDerivative`.
  D: { arity: { min: 1, max: 1 }, cost: 30 },
}

/**
 * Is this node a REWRITE-TARGET `D` — a derivative whose `wrt` names a SPATIAL
 * axis rather than the time variable (esm-spec §4.2 "Arity of `D`" / §9.6.8)?
 *
 * `D` is the one op whose tier — and therefore whose operand contract — depends
 * on a FIELD of the node rather than on its name. A spatial `D` has no evaluator
 * (it MUST be lowered to a stencil by a discretization rule), which is exactly
 * why it MAY carry TRAILING AUXILIARY OPERANDS after `args[0]`: the per-face
 * boundary/halo values the rule binds as ordinary §9.6.1 wildcards and consumes.
 * Their count is unbounded and they carry no evaluator semantics. The structural
 * time derivative (`wrt: 't'`, or absent — an absent `wrt` means `t`) is not a
 * rewrite target and stays strictly unary.
 */
export function isRewriteTargetDerivative(node: { op: string; wrt?: string }): boolean {
  return node.op === 'D' && node.wrt !== undefined && node.wrt !== 't'
}

/** Arity bounds a REWRITE-TARGET `D` relaxes to (esm-spec §4.2 "Arity of `D`"). */
export const REWRITE_TARGET_DERIVATIVE_ARITY: OpArity = { min: 1, max: null }

/** Registry entry for an operator, or undefined for unknown ops. */
export function getOpInfo(op: string): OpInfo | undefined {
  return Object.prototype.hasOwnProperty.call(OPS, op) ? OPS[op] : undefined
}

/**
 * Infix precedence for parenthesization. Function-call ops and unknown ops
 * bind tightest ({@link FUNCTION_PRECEDENCE}).
 */
export function opPrecedence(op: string): number {
  return getOpInfo(op)?.precedence ?? FUNCTION_PRECEDENCE
}

/** True when the operator renders as a function call (no infix precedence). */
export function isFunctionCallOp(op: string): boolean {
  const info = getOpInfo(op)
  return info !== undefined && info.precedence === undefined
}

/** Relative computational cost for complexity analysis. */
export function opCost(op: string): number {
  return getOpInfo(op)?.cost ?? DEFAULT_OP_COST
}

/**
 * Enforce the operator's arity bounds, throwing the runner's stable arity
 * error message on violation.
 */
export function checkArity(op: string, count: number): void {
  const info = getOpInfo(op)
  if (!info) return
  const { min, max } = info.arity
  const name = info.arityName ?? op
  if (max !== null && min === max && count !== min) {
    throw new Error(`${name} requires exactly ${min} argument${min === 1 ? '' : 's'}`)
  }
  if (count < min) {
    throw new Error(
      max === null
        ? `${name} requires at least ${min} argument${min === 1 ? '' : 's'}`
        : `${name} requires exactly ${min} argument${min === 1 ? '' : 's'}`,
    )
  }
  if (max !== null && count > max) {
    throw new Error(`${name} requires exactly ${max} argument${max === 1 ? '' : 's'}`)
  }
}

/**
 * Is `op` a SCALAR (pointwise) operator — see {@link OpInfo.scalar}?
 *
 * A name the registry does not know is not scalar, so this only ever
 * CLASSIFIES registered operators; it can never invent one.
 */
export function isScalarOperator(op: string): boolean {
  return getOpInfo(op)?.scalar === true
}

/**
 * Does element alignment see THROUGH this node to its operands — i.e. are the
 * node's children in ELEMENTWISE position (esm-spec §4.3.4)?
 *
 * This is {@link isScalarOperator} lifted from op NAMES to NODES, plus the one
 * node whose elementwise-ness lives in a FIELD rather than in its name:
 * `broadcast` applies the scalar operator named in `fn` element by element, so
 * `{op:'broadcast', fn:'*', args:[w2, z1]}` MEANS `{op:'*', args:[w2, z1]}` and
 * its operands must align exactly as the bare spelling's do. Treating
 * `broadcast` as opaque made the two spellings disagree — the bare form aligned
 * by index-set name while the `broadcast` form silently kept the positional
 * flatten, which is precisely the divergence §4.3.4 exists to close.
 *
 * That node/name split is why {@link OpInfo.scalar} must keep EXCLUDING
 * `broadcast`: a `broadcast` NODE is elementwise in its `args`, but the STRING
 * `'broadcast'` is not a kernel name, and any caller handed it as one — as an
 * `fn`, or as a re-dispatch target — recurses forever. Ask the node question of
 * a node and the name question of a name.
 *
 * The `fn` guard is deliberately conservative: alignment descends only when
 * `fn` names a scalar operator. A `broadcast` carrying any other `fn` has no
 * elementwise meaning to preserve — it is a hard {@link checkBroadcastFn}
 * error — so this arm only decides how an UNVALIDATED document is treated, and
 * an ABSENT `fn` keeps the historical `+` classification there.
 */
export function isElementwiseNode(node: { op: string; fn?: string }): boolean {
  if (node.op === 'broadcast') return isScalarOperator(node.fn ?? '+')
  return isScalarOperator(node.op)
}

/** A `broadcast` node's `fn`/`args` defect, ready to become a structural error. */
export interface BroadcastFnViolation {
  /** Diagnostic text (esm-spec §4.3.4 wording, shared with the other bindings). */
  message: string
  /** Structured detail fields for the emitted `invalid_broadcast_fn` error. */
  details: Record<string, unknown>
}

/**
 * Validate a `broadcast` node's `fn` field (esm-spec §4.3.4). Returns `null`
 * when the node is well-formed.
 *
 * `broadcast` is the one op whose OPERATOR is data: the node says `broadcast`
 * but the arithmetic it performs is named by a sibling string field, so no
 * `op`-keyed check ever reaches it. Three distinct defects were therefore
 * accepted silently, each producing a plausible wrong value rather than a
 * diagnostic:
 *
 *  1. **A missing `fn`.** There is no default in the spec, and inventing `+`
 *     turns a truncated node into a silent sum.
 *  2. **An `fn` naming no scalar operator** — a typo (`'not_a_real_op'`) or a
 *     non-pointwise op (`'aggregate'`, `'index'`, `'broadcast'` itself). This
 *     is the exact analogue of the §4.4 `unknown_closed_function` rule for
 *     `fn`-NODE names: a name no binding can resolve must never reach an
 *     evaluator, because the failure is otherwise silent.
 *  3. **An `fn`/`args` arity mismatch.** `broadcast(fn:'sin', [a, b])` and
 *     `broadcast(fn:'min', [x])` are wrong for precisely the reason the bare
 *     `sin(a, b)` and `min(x)` nodes are wrong.
 *
 * Note what (3) does NOT reject. A one-operand `broadcast` whose `fn` is
 * genuinely unary or n-ary stays legal: `broadcast(fn:'+', [x])` is `x` and
 * `broadcast(fn:'-', [x])` is `-x`, exactly as the bare `+(x)` / `-(x)` nodes
 * are. That is the whole point of deriving the bound from the registry row's
 * {@link OpInfo.arity} instead of hard-coding "at least 2".
 */
export function checkBroadcastFn(node: {
  op: string
  fn?: string
  args?: unknown[]
}): BroadcastFnViolation | null {
  const fnName = node.fn
  if (typeof fnName !== 'string') {
    return {
      message:
        "'broadcast' is missing its 'fn': the field names the scalar operator to apply " +
        'element-wise and has no default (esm-spec §4.3.4)',
      details: { broadcast_fn: null },
    }
  }
  // One arm covers both "not in the registry at all" and "registered but not
  // pointwise" — from the file's point of view they are one defect: `fn` does
  // not name a scalar operator.
  const info = isScalarOperator(fnName) ? getOpInfo(fnName) : undefined
  if (!info) {
    return {
      message: `'broadcast' fn '${fnName}' does not name a scalar operator (esm-spec §4.3.4)`,
      details: { broadcast_fn: fnName },
    }
  }
  const got = node.args?.length ?? 0
  const { min, max } = info.arity
  if (got >= min && (max === null || got <= max)) return null
  const expected =
    max === null ? `at least ${min}` : min === max ? `exactly ${min}` : `${min} or ${max}`
  return {
    message: `'broadcast' fn '${fnName}' takes ${expected} argument(s), got ${got} (esm-spec §4.3.4)`,
    details: { broadcast_fn: fnName, got, expected },
  }
}
