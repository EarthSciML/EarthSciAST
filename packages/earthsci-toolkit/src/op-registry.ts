/**
 * Central registry of built-in AST operators (esm-spec §4).
 *
 * One table carries, per operator:
 *   - arity bounds (+ the human name used in arity error messages),
 *   - the scalar evaluator used by the official TS runner (codegen.ts),
 *   - infix precedence for the pretty-printers (absent = renders as a
 *     function call),
 *   - a relative computational-cost weight for complexity analysis.
 *
 * Adding a new scalar operator is ONE entry here plus any per-format render
 * strings in pretty-print.ts. Rewrite-target ops (D, grad, div, laplacian,
 * integral) and structural ops (const, enum, fn, aggregate, ...) are handled
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
  '+': {
    arity: { min: 0, max: null },
    precedence: 4,
    cost: 1,
    evaluate: (args) => args.reduce((sum, val) => sum + val, 0),
  },
  '-': {
    arity: { min: 1, max: null },
    precedence: 4,
    cost: 1,
    evaluate: (args) =>
      args.length === 1 ? -args[0] : args.reduce((diff, val, idx) => (idx === 0 ? val : diff - val)),
  },
  '*': {
    arity: { min: 0, max: null },
    precedence: 5,
    cost: 2,
    evaluate: (args) => args.reduce((prod, val) => prod * val, 1),
  },
  '/': {
    arity: { min: 2, max: 2 },
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
    arityName: 'Exponentiation',
    precedence: 7,
    cost: 8,
    evaluate: (args) => Math.pow(args[0], args[1]),
  },

  // ---- exponential / logarithmic ---------------------------------------
  exp: { arity: { min: 1, max: 1 }, cost: 20, evaluate: (args) => Math.exp(args[0]) },
  log: {
    arity: { min: 1, max: 1 },
    cost: 15,
    evaluate: (args) => {
      if (args[0] <= 0) throw new Error('log argument must be positive')
      return Math.log(args[0])
    },
  },
  log10: {
    arity: { min: 1, max: 1 },
    cost: 15,
    evaluate: (args) => {
      if (args[0] <= 0) throw new Error('log10 argument must be positive')
      return Math.log10(args[0])
    },
  },
  sqrt: {
    arity: { min: 1, max: 1 },
    cost: 6,
    evaluate: (args) => {
      if (args[0] < 0) throw new Error('sqrt argument must be non-negative')
      return Math.sqrt(args[0])
    },
  },
  abs: { arity: { min: 1, max: 1 }, cost: 1, evaluate: (args) => Math.abs(args[0]) },

  // ---- trigonometric ----------------------------------------------------
  sin: { arity: { min: 1, max: 1 }, cost: 12, evaluate: (args) => Math.sin(args[0]) },
  cos: { arity: { min: 1, max: 1 }, cost: 12, evaluate: (args) => Math.cos(args[0]) },
  tan: { arity: { min: 1, max: 1 }, cost: 15, evaluate: (args) => Math.tan(args[0]) },
  asin: {
    arity: { min: 1, max: 1 },
    cost: 18,
    evaluate: (args) => {
      if (args[0] < -1 || args[0] > 1) throw new Error('asin argument must be in [-1, 1]')
      return Math.asin(args[0])
    },
  },
  acos: {
    arity: { min: 1, max: 1 },
    cost: 18,
    evaluate: (args) => {
      if (args[0] < -1 || args[0] > 1) throw new Error('acos argument must be in [-1, 1]')
      return Math.acos(args[0])
    },
  },
  atan: { arity: { min: 1, max: 1 }, cost: 18, evaluate: (args) => Math.atan(args[0]) },
  atan2: { arity: { min: 2, max: 2 }, cost: 20, evaluate: (args) => Math.atan2(args[0], args[1]) },

  // ---- hyperbolic ---------------------------------------------------------
  sinh: { arity: { min: 1, max: 1 }, cost: 15, evaluate: (args) => Math.sinh(args[0]) },
  cosh: { arity: { min: 1, max: 1 }, cost: 15, evaluate: (args) => Math.cosh(args[0]) },
  tanh: { arity: { min: 1, max: 1 }, cost: 15, evaluate: (args) => Math.tanh(args[0]) },
  asinh: { arity: { min: 1, max: 1 }, cost: 18, evaluate: (args) => Math.asinh(args[0]) },
  acosh: {
    arity: { min: 1, max: 1 },
    cost: 18,
    evaluate: (args) => {
      if (args[0] < 1) throw new Error('acosh argument must be >= 1')
      return Math.acosh(args[0])
    },
  },
  atanh: {
    arity: { min: 1, max: 1 },
    cost: 18,
    evaluate: (args) => {
      if (args[0] <= -1 || args[0] >= 1) throw new Error('atanh argument must be in (-1, 1)')
      return Math.atanh(args[0])
    },
  },

  // ---- rounding / selection ----------------------------------------------
  min: { arity: { min: 2, max: null }, cost: 3, evaluate: (args) => Math.min(...args) },
  max: { arity: { min: 2, max: null }, cost: 3, evaluate: (args) => Math.max(...args) },
  floor: { arity: { min: 1, max: 1 }, cost: 2, evaluate: (args) => Math.floor(args[0]) },
  ceil: { arity: { min: 1, max: 1 }, cost: 2, evaluate: (args) => Math.ceil(args[0]) },
  sign: { arity: { min: 1, max: 1 }, cost: 1, evaluate: (args) => Math.sign(args[0]) },

  // ---- comparison / logical ----------------------------------------------
  '>': { arity: { min: 2, max: 2 }, precedence: 3, cost: 2, evaluate: (args) => (args[0] > args[1] ? 1 : 0) },
  '<': { arity: { min: 2, max: 2 }, precedence: 3, cost: 2, evaluate: (args) => (args[0] < args[1] ? 1 : 0) },
  '>=': { arity: { min: 2, max: 2 }, precedence: 3, cost: 2, evaluate: (args) => (args[0] >= args[1] ? 1 : 0) },
  '<=': { arity: { min: 2, max: 2 }, precedence: 3, cost: 2, evaluate: (args) => (args[0] <= args[1] ? 1 : 0) },
  '==': { arity: { min: 2, max: 2 }, precedence: 3, cost: 2, evaluate: (args) => (args[0] === args[1] ? 1 : 0) },
  '!=': { arity: { min: 2, max: 2 }, precedence: 3, cost: 2, evaluate: (args) => (args[0] !== args[1] ? 1 : 0) },
  '=': { arity: { min: 2, max: 2 }, precedence: 3 },
  and: { arity: { min: 0, max: null }, precedence: 2, cost: 2, evaluate: (args) => (args.every((x) => x !== 0) ? 1 : 0) },
  or: { arity: { min: 0, max: null }, precedence: 1, cost: 2, evaluate: (args) => (args.some((x) => x !== 0) ? 1 : 0) },
  not: { arity: { min: 1, max: 1 }, precedence: 6, cost: 1, evaluate: (args) => (args[0] === 0 ? 1 : 0) },
  ifelse: {
    arity: { min: 3, max: 3 },
    cost: 3,
    evaluate: (args) => (args[0] !== 0 ? args[1] : args[2]),
  },

  // ---- event / rewrite-target ops (no scalar evaluator) -------------------
  Pre: { arity: { min: 1, max: 1 }, cost: 5 },
  D: { arity: { min: 1, max: 1 }, cost: 30 },
  grad: { arity: { min: 1, max: 1 }, cost: 50 },
  div: { arity: { min: 1, max: 1 }, cost: 40 },
  laplacian: { arity: { min: 1, max: 1 }, cost: 80 },
  integral: { arity: { min: 1, max: null }, cost: 50 },
}

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
