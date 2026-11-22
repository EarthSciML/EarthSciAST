/**
 * The definition layer of esm 2.4.0's "one operator type" (esm-spec §9.6.1,
 * §9.6.3, §9.6.12): what an `operators` entry is a definition of
 * (`defines`), structural pattern matching of a definition against a node,
 * parameter substitution, and the `unlowered_operator` explanation of an
 * unresolved call. Shared by the rewrite engine
 * (`lower-expression-templates.ts`), the unit checker (`units.ts`) and the
 * evaluator gate (`codegen.ts`); it imports nothing that reaches the loader,
 * so each of them can depend on it without an import cycle.
 *
 * Terminology: a **core operator** is one of the closed esm-spec §4.2 set
 * ({@link isCoreOp}); every other op names a **defined operator**, given by
 * definitions.
 */

import { isNumericLiteral, numericValue } from './numeric-literal.js'
import { isObject } from './object-utils.js'
import { isCoreOp } from './op-registry.js'
import { compareUtf8 } from './json-rewrite.js'

type Json = unknown

/** The root `op` of a definition's `match`, or `undefined`. */
export function matchRootOp(decl: unknown): string | undefined {
  if (!isObject(decl)) return undefined
  const m = decl.match
  if (!isObject(m)) return undefined
  return typeof m.op === 'string' ? m.op : undefined
}

/**
 * The defined operator an `operators` entry is a definition of (esm-spec
 * §9.6.1 `defines`): its written `defines`; else the root `op` of its `match`
 * when that is not a core op; else its key.
 */
export function definitionDefines(name: string, decl: unknown): string {
  if (isObject(decl) && typeof decl.defines === 'string') return decl.defines
  const r = matchRootOp(decl)
  if (r !== undefined && !isCoreOp(r)) return r
  return name
}

/**
 * `decl` carrying its `defines` (inferred under `name` when absent): the entry
 * itself when it already has one, else a copy.
 */
export function withDefines(name: string, decl: unknown): unknown {
  if (!isObject(decl) || decl.defines !== undefined) return decl
  return { ...decl, defines: definitionDefines(name, decl) }
}

/**
 * Whether `n` is a call shape a match-less definition can bind: an `op` and
 * `args`, no other field (esm-spec §9.6.3 constraint 2).
 */
export function onlyOpArgs(n: Record<string, unknown>): boolean {
  for (const k of Object.keys(n)) if (k !== 'op' && k !== 'args') return false
  return true
}

/**
 * Structural deep equality over the JSON AST, treating plain `number`
 * and tagged `NumericLiteral` leaves as equal when their numeric values
 * agree. Used for match-binding consistency, pattern literal checks, and
 * the §9.7.4 / §9.7.5 deep-equal dedup of diamond imports.
 */
export function deepEqual(a: Json, b: Json): boolean {
  if (a === b) return true
  const av = numericValue(a)
  const bv = numericValue(b)
  if (av !== undefined || bv !== undefined) return av !== undefined && av === bv
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) if (!deepEqual(a[i], b[i])) return false
    return true
  }
  if (isObject(a) && isObject(b)) {
    const ak = Object.keys(a)
    const bk = Object.keys(b)
    if (ak.length !== bk.length) return false
    for (const k of ak) {
      if (!Object.prototype.hasOwnProperty.call(b, k)) return false
      if (!deepEqual(a[k], b[k])) return false
    }
    return true
  }
  return false
}

/**
 * Attempt to structurally match `pattern` against `node`, treating any
 * bare string in `params` as a wildcard metavariable. On success the
 * `bindings` map is populated (param → bound sub-AST for operand/`args`
 * positions, param → matched literal for scalar fields — including a custom
 * `attrs.<key>` slot) and `true` is returned. Repeated occurrences of a
 * metavariable must bind consistently.
 *
 * Pattern object fields are matched by key; node keys absent from the
 * pattern are ignored (so a partial operator pattern listing only
 * `op`/`args`/`dim` still matches a node that carries extra fields).
 */
export function matchPattern(
  pattern: Json,
  node: Json,
  params: Set<string>,
  bindings: Record<string, Json>,
  bv?: BodyView,
): boolean {
  // Inside a template body (esm-spec §9.6.4 rules 3 and 4) a parameter is a
  // leaf: a metavariable captures it whole, and any other pattern node sees it
  // only as the literal its instance binds in a structural position (and never
  // matches an operand-position parameter).
  if (
    bv !== undefined &&
    typeof node === 'string' &&
    bv.params.has(node) &&
    !(typeof pattern === 'string' && params.has(pattern))
  ) {
    if (!bv.lit.has(node)) return false
    return matchPattern(pattern, bv.lit.get(node), params, bindings)
  }
  // Metavariable: binds to whatever node occupies this position (sub-AST
  // in an operand/`args` slot, literal in a scalar field / `attrs.<key>`).
  if (typeof pattern === 'string' && params.has(pattern)) {
    if (Object.prototype.hasOwnProperty.call(bindings, pattern)) {
      return deepEqual(bindings[pattern], node)
    }
    bindings[pattern] = node
    return true
  }
  // Literal string (a concrete op name / variable reference): exact match.
  if (typeof pattern === 'string') return pattern === node
  // Numeric literal (plain or tagged): match by value.
  if (typeof pattern === 'number' || isNumericLiteral(pattern)) {
    const pv = numericValue(pattern)
    const nv = numericValue(node)
    return pv !== undefined && pv === nv
  }
  // Array (an `args`/operand list): element-wise, equal length.
  if (Array.isArray(pattern)) {
    if (!Array.isArray(node) || node.length !== pattern.length) return false
    for (let i = 0; i < pattern.length; i++) {
      if (!matchPattern(pattern[i], node[i], params, bindings, bv)) return false
    }
    return true
  }
  // Object (an operator node, or a nested `attrs` object): node must be an
  // object that carries every key the pattern specifies (extra node keys are
  // allowed). Generic recursion is what makes `attrs.<key>` metavariables work.
  if (isObject(pattern)) {
    if (!isObject(node)) return false
    for (const k of Object.keys(pattern)) {
      if (!Object.prototype.hasOwnProperty.call(node, k)) return false
      if (!matchPattern(pattern[k], node[k], params, bindings, bv)) return false
    }
    return true
  }
  // null / boolean.
  return deepEqual(pattern, node)
}

/**
 * Substitute parameter occurrences in a template body.
 *
 * STRUCTURAL SHARING (mirrors the Julia reference fix "store expanded
 * expression templates as shared DAGs, not exponential trees"): binding values
 * and untouched body subtrees are spliced in BY REFERENCE, never copied, and
 * the walk is identity-preserving (a subtree containing no parameter
 * occurrence is returned as the SAME object) and identity-memoized (a subtree
 * shared under many parents is processed once). A template chain in which each
 * body references its predecessor twice therefore expands to a DAG with O(n)
 * unique nodes instead of a 2^n-node tree. This changes representation only:
 * expansion is otherwise pure, every subsequent pass over the expanded form is
 * non-mutating, and the canonical serialized bytes are unchanged (JSON
 * serialization of the DAG re-expands it textually).
 */
export function substituteBindings(body: Json, bindings: Record<string, Json>): Json {
  const memo = new Map<object, Json>()
  const go = (node: Json): Json => {
    if (typeof node === 'string') {
      if (Object.prototype.hasOwnProperty.call(bindings, node)) {
        // Splice the binding by reference: expanded forms are never mutated in
        // place downstream, so sharing is safe and keeps expansion linear.
        return bindings[node]
      }
      return node
    }
    if (Array.isArray(node)) {
      const hit = memo.get(node)
      if (hit !== undefined) return hit
      let changed = false
      const out = node.map((c) => {
        const r = go(c)
        if (r !== c) changed = true
        return r
      })
      const res = changed ? out : node
      memo.set(node, res)
      return res
    }
    if (isObject(node)) {
      const hit = memo.get(node)
      if (hit !== undefined) return hit
      let changed = false
      const out: Record<string, unknown> = {}
      for (const k of Object.keys(node)) {
        const r = go(node[k])
        if (r !== node[k]) changed = true
        out[k] = r
      }
      const res = changed ? out : node
      memo.set(node, res)
      return res
    }
    return node
  }
  return go(body)
}

/**
 * How the rewrite engine sees a template body it rewrites for one template
 * instance (esm-spec §9.6.4 rule 3): `params` — the template's parameters, each
 * a leaf; `lit` — the literal the instance binds to each parameter in a
 * structural position; `entries` — each parameter's instance entry
 * ({@link instanceEntry}), which a `where` `shape` constraint reads. Mirrors the
 * Julia reference `_BodyView`.
 */
export interface BodyView {
  params: Set<string>
  lit: Map<string, Json>
  entries: Map<string, string>
}

/**
 * The `unlowered_operator` explanation of esm-spec §9.6.6 for an unresolved
 * call `call` (raw JSON) of a defined operator: every definition of it in
 * `registry` (name → raw entry), sorted by name, with the reason it was not
 * eligible there — its `match` did not match, its `where` failed (naming the
 * constraint), or its arity or call shape differed. No definition of the
 * operator in the registry: a placeholder.
 */
export function explainUnresolvedCall(
  call: unknown,
  registry: Record<string, unknown> | null | undefined,
  shapeEnv: Record<string, string[]> = {},
): string {
  if (!isObject(call) || typeof call.op !== 'string') return ''
  const op = call.op
  const args = Array.isArray(call.args) ? call.args : []
  const k = args.length
  const placeholder = `no definition of '${op}' is in scope (a placeholder)`
  if (registry === null || registry === undefined) return placeholder
  const lines: string[] = []
  for (const name of Object.keys(registry).sort(compareUtf8)) {
    const decl = registry[name]
    if (!isObject(decl)) continue
    const params = Array.isArray(decl.params) ? decl.params.map((x) => String(x)) : []
    const m = decl.match
    if (m !== undefined && m !== null) {
      if (matchRootOp(decl) !== op) continue
      const b: Record<string, Json> = {}
      if (!matchPattern(m, call, new Set(params), b)) {
        lines.push(`'${name}': its match does not match the call`)
        continue
      }
      lines.push(`'${name}': its where constraint ` + whereReason(decl.where, b, shapeEnv))
    } else {
      if (definitionDefines(name, decl) !== op) continue
      if (params.length !== k) {
        lines.push(`'${name}': takes ${params.length} operand(s), the call carries ${k}`)
      } else if (!onlyOpArgs(call)) {
        const extra = Object.keys(call)
          .filter((x) => x !== 'op' && x !== 'args')
          .sort(compareUtf8)
        lines.push(
          `'${name}': has no match, so it binds operands only, and the call carries ${extra.join(', ')}`,
        )
      } else {
        const b: Record<string, Json> = {}
        params.forEach((p, i) => {
          b[p] = args[i]
        })
        lines.push(`'${name}': its where constraint ` + whereReason(decl.where, b, shapeEnv))
      }
    }
  }
  if (lines.length === 0) return placeholder
  return `definitions of '${op}' in scope: ` + lines.join('; ')
}

/** Julia `repr`-style rendering of a string list (`["a", "b"]`). */
function showList(xs: readonly unknown[]): string {
  return '[' + xs.map((x) => JSON.stringify(x)).join(', ') + ']'
}

function whereReason(
  whr: unknown,
  b: Record<string, Json>,
  shapeEnv: Record<string, string[]>,
): string {
  if (whr === undefined || whr === null) return 'holds (the definition was not selected)'
  if (isObject(whr)) {
    for (const [p, c] of Object.entries(whr)) {
      const want = isObject(c) ? c.shape : undefined
      const got = Object.prototype.hasOwnProperty.call(b, p) ? b[p] : undefined
      const wantS = Array.isArray(want) ? showList(want) : String(want)
      if (typeof got === 'string') {
        const shp = Object.prototype.hasOwnProperty.call(shapeEnv, got) ? shapeEnv[got] : undefined
        return (
          `${p}.shape = ${wantS} fails: the operand bound to ${p} ('${got}') has declared ` +
          `shape ${shp === undefined ? 'none' : showList(shp)}`
        )
      }
      return `${p}.shape = ${wantS} fails: the operand bound to ${p} is not a bare variable`
    }
  }
  return 'fails'
}
