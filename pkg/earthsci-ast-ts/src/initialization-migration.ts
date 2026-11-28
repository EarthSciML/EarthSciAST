/**
 * esm 2.5.0: the deprecated `initialization_equations` block, read at the
 * load's wire boundary (esm-spec §11.4.4), and the load-time check of an `ic`
 * argument (esm-spec §4.2, the `ic` row).
 *
 * For every model (top-level, and inline subsystems at any depth) that carries
 * `initialization_equations`, the field is removed and:
 *
 * - a model with a time derivative (an equation whose left-hand side contains
 *   a `D`) gets each equation appended to `equations`, with every reference to
 *   an unknown `w` replaced by `ic(w)` and every `D(w)` by `ic(D(w))`;
 * - a model with none gets each `v ~ e`, `v` a bare unknown, as
 *   `guesses[v] = e` (an existing entry is kept); any other equation is
 *   refused with `deprecated_field`;
 * - before either, an initial condition of a declared parameter `k` (an entry
 *   whose left-hand side is `k` or `ic(k)`, or, below esm 2.5.0, an `equations`
 *   entry whose left-hand side is `ic(k)`) becomes `k`'s `default`.
 *
 * The loader and the canonical form (so every printer) apply this one
 * migration.
 *
 * Mirrors the Julia, Rust and Python loaders. Imports nothing that reaches
 * the loader.
 */

import { ERROR_CODES, EsmDiagnosticError } from './errors.js'
import { mapChildren } from './expression.js'
import { icTarget, isOpNode } from './initialization.js'
import { numericValue } from './numeric-literal.js'
import { pointerToken } from './json-pointer.js'
import { deepClone, setOwn } from './object-utils.js'
import type { Expression } from './types.js'

type Obj = Record<string, unknown>

const isObj = (v: unknown): v is Obj => v !== null && typeof v === 'object' && !Array.isArray(v)

/** A load-time refusal of the migration or of an `ic` argument. */
export class InitializationMigrationError extends EsmDiagnosticError {
  constructor(code: string, message: string) {
    super(code, message)
    this.name = 'InitializationMigrationError'
  }
}

/** Whether `e` holds a `D` node anywhere. */
function mentionsD(e: unknown): boolean {
  if (Array.isArray(e)) return e.some(mentionsD)
  if (!isObj(e)) return false
  return e.op === 'D' || Object.values(e).some(mentionsD)
}

/** A model's own `equations` include one whose left-hand side has a `D`. */
function hasTimeDerivative(model: Obj): boolean {
  const eqs = model.equations
  return Array.isArray(eqs) && eqs.some((eq) => isObj(eq) && mentionsD(eq.lhs))
}

/** What a name declares: an unknown, a parameter, a species, or nothing found. */
type Declared = 'unknown' | 'parameter' | 'species' | null

/** Resolve a dotted name, segment by segment, from a model or reaction system. */
function resolveIn(container: unknown, parts: readonly string[]): Declared {
  if (!isObj(container) || parts.length === 0) return null
  const [head, ...rest] = parts as [string, ...string[]]
  if (rest.length === 0) {
    const vars = container.variables
    const v =
      isObj(vars) && Object.prototype.hasOwnProperty.call(vars, head) ? vars[head] : undefined
    if (isObj(v) && (v.type === 'unknown' || v.type === 'parameter')) return v.type
    const species = container.species
    if (isObj(species) && Object.prototype.hasOwnProperty.call(species, head)) return 'species'
    const params = container.parameters
    if (isObj(params) && Object.prototype.hasOwnProperty.call(params, head)) return 'parameter'
    return null
  }
  const subs = container.subsystems
  return isObj(subs) && Object.prototype.hasOwnProperty.call(subs, head)
    ? resolveIn(subs[head], rest)
    : null
}

/**
 * What `name`, read in `model`, declares: a local variable, else a scoped name
 * resolved from the model's subsystems, then from the document's models and
 * reaction systems.
 */
function declaredAs(doc: Obj, model: Obj, name: string): Declared {
  const parts = name.split('.')
  const local = resolveIn(model, parts)
  if (local !== null || parts.length < 2) return local
  for (const key of ['models', 'reaction_systems']) {
    const top = doc[key]
    if (!isObj(top) || !Object.prototype.hasOwnProperty.call(top, parts[0]!)) continue
    const found = resolveIn(top[parts[0]!], parts.slice(1))
    if (found !== null) return found
  }
  return null
}

/** Whether `name`, read in `model`, names an unknown (a variable or a species). */
function namesUnknown(doc: Obj, model: Obj, name: string): boolean {
  const d = declaredAs(doc, model, name)
  return d === 'unknown' || d === 'species'
}

const icOf = (arg: unknown): Obj => ({ op: 'ic', args: [arg] })

/** A time derivative: `D` whose `wrt` is absent or `t`. */
const isTimeD = (e: Obj): boolean =>
  e.op === 'D' && (e.wrt === undefined || e.wrt === null || e.wrt === 't')

/**
 * `e` with every unknown `w` replaced by `ic(w)` and every time derivative
 * `D(w)` of an unknown by `ic(D(w))`, through every expression-valued field
 * (`args`, `expr`, `filter`, `values`, `bindings`, `lower`, `upper`, `key`).
 * An `ic` node is left as it is.
 */
function rewriteUnknowns(e: unknown, isUnknown: (n: string) => boolean): unknown {
  if (typeof e === 'string') return isUnknown(e) ? icOf(e) : e
  if (!isOpNode(e)) return e
  if (e.op === 'ic') return e
  const args = e.args
  if (isTimeD(e) && Array.isArray(args) && typeof args[0] === 'string' && isUnknown(args[0])) {
    return icOf(e)
  }
  return mapChildren(e, (child) => rewriteUnknowns(child, isUnknown) as Expression)
}

/** Whether the document declares an esm version below 2.5.0. */
function declaresBelow250(doc: Obj): boolean {
  const m = typeof doc.esm === 'string' ? /^(\d+)\.(\d+)/.exec(doc.esm) : null
  if (m === null) return false
  const major = Number(m[1])
  return major < 2 || (major === 2 && Number(m[2]) < 5)
}

/** `k` when `lhs` is `k` or `ic(k)`, `k` a declared parameter of `model`; else null. */
function parameterTarget(model: Obj, lhs: unknown, bareToo: boolean): string | null {
  const k = bareToo && typeof lhs === 'string' ? lhs : icTarget(lhs)
  return k !== null && resolveIn(model, [k]) === 'parameter' ? k : null
}

/**
 * esm-spec §11.4.4 "An initial condition of a parameter": move each pre-2.5.0
 * initial condition of a declared parameter `k` of `model` into `k`'s
 * `default` (replacing one it declares) and remove the equation. Those are the
 * `initialization_equations` entries whose left-hand side is `k` or `ic(k)`
 * and, in a document declaring esm below 2.5.0, the `equations` entries whose
 * left-hand side is exactly `ic(k)`. A right-hand side that is not a number is
 * `ic_invalid_argument`. Returns the remaining initialization equations.
 */
function moveParameterInitialConditions(
  model: Obj,
  init: unknown[],
  at: string,
  below250: boolean,
  sites: string[],
): unknown[] {
  const vars = isObj(model.variables) ? model.variables : {}
  const take = (eq: unknown, where: string, bareToo: boolean): boolean => {
    if (!isObj(eq)) return false
    const k = parameterTarget(model, eq.lhs, bareToo)
    if (k === null) return false
    if (numericValue(eq.rhs) === undefined) {
      throw new InitializationMigrationError(
        ERROR_CODES.IC_INVALID_ARGUMENT,
        `${ERROR_CODES.IC_INVALID_ARGUMENT}: ${where}: an initial condition of the parameter ` +
          `\`${k}\` is read as its \`default\` (esm-spec §11.4.4), which must be a number.`,
      )
    }
    setOwn(vars[k] as Obj, 'default', eq.rhs)
    return true
  }
  if (below250 && Array.isArray(model.equations)) {
    const eqs = model.equations as unknown[]
    const kept = eqs.filter((eq, i) => {
      const where = `${at}/equations/${i}`
      if (!take(eq, where, false)) return true
      sites.push(`${where} (ic of a parameter)`)
      return false
    })
    if (kept.length !== eqs.length) model.equations = kept
  }
  return init.filter((eq, i) => !take(eq, `${at}/initialization_equations/${i}`, true))
}

function migrateModel(doc: Obj, model: Obj, at: string, below250: boolean, sites: string[]): void {
  const hasField = Object.prototype.hasOwnProperty.call(model, 'initialization_equations')
  const init = hasField ? model.initialization_equations : undefined
  if (hasField) delete model.initialization_equations
  const all = Array.isArray(init) ? init : []
  if (all.length > 0) sites.push(`${at}/initialization_equations (initialization_equations)`)
  const eqs = moveParameterInitialConditions(model, all, at, below250, sites)
  if (eqs.length > 0) {
    if (hasTimeDerivative(model)) {
      const isUnknown = (n: string): boolean => namesUnknown(doc, model, n)
      const out = Array.isArray(model.equations) ? model.equations : []
      for (const eq of eqs) {
        if (!isObj(eq)) continue
        const moved: Obj = {}
        for (const [k, v] of Object.entries(eq)) {
          setOwn(moved, k, k === 'lhs' || k === 'rhs' ? rewriteUnknowns(v, isUnknown) : v)
        }
        out.push(moved)
      }
      model.equations = out
    } else {
      const guesses: Obj = isObj(model.guesses) ? model.guesses : {}
      all.forEach((eq, i) => {
        if (!eqs.includes(eq)) return
        const lhs = isObj(eq) ? eq.lhs : undefined
        if (typeof lhs !== 'string' || resolveIn(model, [lhs]) !== 'unknown') {
          throw new InitializationMigrationError(
            ERROR_CODES.DEPRECATED_FIELD,
            `${ERROR_CODES.DEPRECATED_FIELD}: ${at}/initialization_equations/${i}: the model has ` +
              'no time derivative, so its initialization equations are read as `guesses` ' +
              '(esm 2.5.0, esm-spec §11.4.4), and this one has no left-hand side that is a ' +
              'bare unknown. Write a `guesses` entry instead.',
          )
        }
        if (!Object.prototype.hasOwnProperty.call(guesses, lhs))
          setOwn(guesses, lhs, (eq as Obj).rhs)
      })
      model.guesses = guesses
    }
  }
  const subs = model.subsystems
  if (isObj(subs)) {
    for (const [k, sub] of Object.entries(subs)) {
      if (isObj(sub)) migrateModel(doc, sub, `${at}/subsystems/${pointerToken(k)}`, below250, sites)
    }
  }
}

/**
 * Rewrite every model's `initialization_equations`, and every pre-2.5.0
 * initial condition of a parameter, IN PLACE (esm-spec §11.4.4). Returns the
 * sites, as the `deprecated_field` warning names them. Idempotent: a second
 * pass finds nothing.
 */
export function migrateInitializationEquations(doc: unknown): string[] {
  const sites: string[] = []
  if (!isObj(doc) || !isObj(doc.models)) return sites
  const below250 = declaresBelow250(doc)
  for (const [k, model] of Object.entries(doc.models)) {
    if (isObj(model)) migrateModel(doc, model, `/models/${pointerToken(k)}`, below250, sites)
  }
  return sites
}

/**
 * Whether the migration has anything to do on `doc`: a model, at any depth,
 * carries `initialization_equations` or, in a document declaring esm below
 * 2.5.0, an equation whose left-hand side is `ic(k)` of a declared parameter.
 */
export function needsInitializationMigration(doc: unknown): boolean {
  if (!isObj(doc) || !isObj(doc.models)) return false
  const below250 = declaresBelow250(doc)
  const modelNeeds = (m: unknown): boolean =>
    isObj(m) &&
    (Object.prototype.hasOwnProperty.call(m, 'initialization_equations') ||
      (below250 &&
        Array.isArray(m.equations) &&
        m.equations.some((eq) => isObj(eq) && parameterTarget(m, eq.lhs, false) !== null)) ||
      (isObj(m.subsystems) && Object.values(m.subsystems).some(modelNeeds)))
  return Object.values(doc.models).some(modelNeeds)
}

/**
 * `doc` as a load reads its `initialization_equations` (esm-spec §11.4.4), on
 * a copy, for the canonical form and the printers (esm-spec §9.6.6
 * `deprecated_field`: the field never survives into an emitted document).
 * `doc` itself when no model carries the field, or when the migration refuses
 * it (the load reports that refusal; a printer prints the document as given).
 */
export function initializationEquationsMigrated<T>(doc: T): T {
  if (!needsInitializationMigration(doc)) return doc
  const copy = deepClone(doc)
  try {
    migrateInitializationEquations(copy)
  } catch (e) {
    if (e instanceof InitializationMigrationError) return doc
    throw e
  }
  return copy
}

/** The load-time `deprecated_field` warning naming the migrated blocks `sites`. */
export function deprecatedInitializationEquationsWarning(sites: readonly string[]): string {
  return (
    `${ERROR_CODES.DEPRECATED_FIELD}: \`initialization_equations\` is deprecated (esm 2.5.0, ` +
    'esm-spec §11.4.4); each equation was rewritten into an `ic` equation in `equations` ' +
    '(or into `guesses` for a model with no time derivative), and an initial condition ' +
    'of a parameter became its `default`. ' +
    `Read at: ${sites.join(', ')}.`
  )
}

/** The name an `ic` node reads (`u` of `ic(u)` or `ic(D(u))`), or null when malformed. */
function icArgumentName(node: Obj): string | null {
  const args = node.args
  const a = Array.isArray(args) && args.length === 1 ? args[0] : undefined
  if (typeof a === 'string') return a
  if (isObj(a) && a.op === 'D' && Array.isArray(a.args) && a.args.length === 1) {
    return typeof a.args[0] === 'string' ? a.args[0] : null
  }
  return null
}

/**
 * The load-time check of every `ic` node (esm-spec §4.2, the `ic` row),
 * refused with `ic_invalid_argument` naming the node's location:
 *
 * - its argument must be a variable reference or `D` of one: an element is
 *   `index(ic(u), i)`, never `ic(index(u, i))`;
 * - inside a model, that reference must not name a declared parameter (bare,
 *   or scoped to another component): a parameter has no starting value.
 */
export function checkIcArguments(doc: unknown): void {
  const root = isObj(doc) ? doc : {}
  const seen = new Set<object>()
  // `model` is the model whose scope the node sits in; null outside a model,
  // and under `operators`, whose bodies name template parameters.
  const walk = (n: unknown, at: string, model: Obj | null): void => {
    if (n === null || typeof n !== 'object' || seen.has(n)) return
    seen.add(n)
    if (Array.isArray(n)) {
      n.forEach((x, i) => walk(x, `${at}/${i}`, model))
      return
    }
    const o = n as Obj
    if (o.op === 'ic') {
      const name = icArgumentName(o)
      if (name === null) {
        throw new InitializationMigrationError(
          ERROR_CODES.IC_INVALID_ARGUMENT,
          `${ERROR_CODES.IC_INVALID_ARGUMENT}: ${at}: the argument of \`ic\` must be a variable reference or \`D\` of one ` +
            '(esm-spec §4.2); an element of an array unknown is written `index(ic(u), i)`, ' +
            'not `ic(index(u, i))`.',
        )
      }
      if (model !== null && declaredAs(root, model, name) === 'parameter') {
        throw new InitializationMigrationError(
          ERROR_CODES.IC_INVALID_ARGUMENT,
          `${ERROR_CODES.IC_INVALID_ARGUMENT}: ${at}: \`ic(${name})\` names a parameter, which has ` +
            'no starting value; `ic` reads the starting value of an unknown (esm-spec §4.2). ' +
            `Write \`${name}\` for the parameter's value.`,
        )
      }
    }
    for (const [k, v] of Object.entries(o)) {
      if (k === 'operators') walk(v, `${at}/operators`, null)
      else if ((k === 'models' && o === root) || (k === 'subsystems' && model !== null)) {
        if (!isObj(v)) continue
        for (const [name, m] of Object.entries(v)) {
          walk(m, `${at}/${k}/${pointerToken(name)}`, isObj(m) ? m : null)
        }
      } else walk(v, `${at}/${pointerToken(k)}`, model)
    }
  }
  walk(doc, '', null)
}
