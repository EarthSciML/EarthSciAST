import { forEachChild, isExprNode } from './expression.js'
import type { Equation, EsmFile, Model, ModelVariable, ReactionSystem } from './types.js'

/**
 * The first esm version (major, minor) at which a root that declares no
 * `domain.element_type` leaves its precision unspecified (esm-spec §11.3.3).
 * An older root that omits it declares binary64.
 */
export const UNSPECIFIED_PRECISION_SINCE: readonly [number, number] = [2, 4]

/** Precision of a root's omitted domain.element_type (esm-spec §11.3.3). */
export function omittedPrecision(version: unknown): 'Float64' | 'unspecified' {
  const parts = typeof version === 'string' && /^(\d+)\.(\d+)\.\d+$/.exec(version)
  if (!parts) return 'Float64'
  const [major, minor] = [Number(parts[1]), Number(parts[2])]
  const [sinceMajor, sinceMinor] = UNSPECIFIED_PRECISION_SINCE
  return major > sinceMajor || (major === sinceMajor && minor >= sinceMinor)
    ? 'unspecified'
    : 'Float64'
}

/** Return the declared element type or `unspecified`. With no variable, query the document default. */
export function precisionSource(
  document: EsmFile,
  variable?: Pick<ModelVariable, 'element_type'>,
): 'Float32' | 'Float64' | 'unspecified' {
  return variable?.element_type ?? document.domain?.element_type ?? omittedPrecision(document.esm)
}

/** One unspecified variable used directly as a key (esm-spec §11.3.3 P8). */
export interface KeySite {
  /** JSON pointer to the equation side or reaction rate. */
  path: string
  message: string
}

const pointerToken = (name: string): string => name.replace(/~/g, '~0').replace(/\//g, '~1')

/**
 * Every unspecified variable used directly as an operand of `==` / `!=` or as
 * a `join.on` key (esm-spec §11.3.3 P8). Empty unless the document's own
 * precision is unspecified. An indexed read is its array; a loop or binder
 * symbol is not a variable.
 */
export function unspecifiedKeys(file: EsmFile): KeySite[] {
  if (precisionSource(file) !== 'unspecified') return []
  const unspecified = new Map<string, boolean>()
  const expressions: [string, string, unknown][] = []
  const equations = (scope: string, pointer: string, block: string, eqs?: Equation[]): void => {
    ;(eqs ?? []).forEach((eq, i) => {
      expressions.push([scope, `${pointer}/${block}/${i}/lhs`, eq.lhs])
      expressions.push([scope, `${pointer}/${block}/${i}/rhs`, eq.rhs])
    })
  }
  const isInline = (c: unknown): boolean => typeof c === 'object' && c !== null && !('ref' in c)
  const model = (scope: string, pointer: string, m: Model): void => {
    for (const [name, v] of Object.entries(m.variables ?? {})) {
      unspecified.set(`${scope}.${name}`, v.element_type === undefined)
    }
    equations(scope, pointer, 'equations', m.equations)
    equations(scope, pointer, 'initialization_equations', m.initialization_equations)
    for (const [key, sub] of Object.entries(m.subsystems ?? {})) {
      if (isInline(sub)) model(`${scope}.${key}`, `${pointer}/subsystems/${key}`, sub as Model)
    }
  }
  const reactionSystem = (scope: string, pointer: string, rs: ReactionSystem): void => {
    for (const name of [...Object.keys(rs.species ?? {}), ...Object.keys(rs.parameters ?? {})]) {
      unspecified.set(`${scope}.${name}`, true)
    }
    ;(rs.reactions ?? []).forEach((r, i) => {
      expressions.push([scope, `${pointer}/reactions/${i}/rate`, r.rate])
    })
    equations(scope, pointer, 'constraint_equations', rs.constraint_equations)
    for (const [key, sub] of Object.entries(rs.subsystems ?? {})) {
      if (isInline(sub)) {
        reactionSystem(`${scope}.${key}`, `${pointer}/subsystems/${key}`, sub as ReactionSystem)
      }
    }
  }
  for (const [name, m] of Object.entries(file.models ?? {})) {
    if (isInline(m)) model(name, `/models/${pointerToken(name)}`, m as Model)
  }
  for (const [name, rs] of Object.entries(file.reaction_systems ?? {})) {
    if (isInline(rs)) {
      reactionSystem(name, `/reaction_systems/${pointerToken(name)}`, rs as ReactionSystem)
    }
  }
  const sites: KeySite[] = []
  for (const [scope, pointer, expr] of expressions) {
    visitKeys(expr, [], (key, op) => {
      for (const variable of [`${scope}.${key}`, key]) {
        const isUnspecified = unspecified.get(variable)
        if (isUnspecified === undefined) continue
        if (isUnspecified) {
          sites.push({
            path: pointer,
            message: `${variable} has unspecified precision in ${op} at ${pointer}`,
          })
        }
        return
      }
    })
  }
  return sites
}

function visitKeys(expr: unknown, bound: string[], found: (key: string, op: string) => void): void {
  if (!isExprNode(expr)) return
  const outer = bound.length
  bound.push(...Object.keys(expr.ranges ?? {}))
  for (const i of expr.output_idx ?? []) if (typeof i === 'string') bound.push(i)
  if (typeof expr.var === 'string') bound.push(expr.var)
  if (expr.op === '==' || expr.op === '!=') {
    for (let arg of expr.args ?? []) {
      while (isExprNode(arg) && arg.op === 'index' && arg.args.length > 0) arg = arg.args[0]!
      if (typeof arg === 'string' && !bound.includes(arg)) found(arg, expr.op)
    }
  }
  for (const clause of expr.join ?? []) {
    const on = (clause as { on?: unknown }).on
    if (!Array.isArray(on)) continue
    for (const pair of on) {
      if (!Array.isArray(pair)) continue
      for (const name of pair) if (typeof name === 'string') found(name, 'join.on')
    }
  }
  forEachChild(expr, (child) => visitKeys(child, bound, found))
  bound.length = outer
}
