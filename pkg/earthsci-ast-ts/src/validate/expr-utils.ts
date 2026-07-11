/**
 * Expression-tree walkers and reference-resolution utilities shared by the
 * structural-validation check modules.
 *
 * Leaf module (no dependency on other `validate/` files): the model-, reaction-,
 * and coupling-check modules import these helpers, and the orchestrator imports
 * {@link isInlineModel}.
 */

import { isExprNode, forEachChild } from '../expression.js'
import type { Expr } from '../expression.js'
import type {
  EsmFile,
  Model,
  DataLoader,
  ReactionSystem,
  Expression,
  SubsystemRef,
} from '../types.js'

/** Narrow a `models` / `subsystems` map value to an inline Model. */
export function isInlineModel(v: Model | DataLoader | SubsystemRef): v is Model {
  return !('ref' in v) && !('kind' in v)
}

// ---------------------------------------------------------------------------
// Expression-tree walkers.
//
// These four walkers (extractVariableReferences, collectIndexSymbols,
// countDerivatives, expressionReferencesName) share a common leaf-discrimination
// rule via `isExprNode` (number/string/NumericLiteral leaves vs operator nodes)
// AND a common DESCENT: every one now recurses through `forEachChild` (the
// shared full-child walker in expression.ts), so each visits the COMPLETE set of
// expression-bearing fields (`args`, the aggregate/integral scalar bodies
// `expr`/`filter`/`key`/`lower`/`upper`, `makearray` `values`, `table_lookup`
// `axes`, and template `bindings`) instead of the historical `args`-only subset.
//
// Descending the aggregate bodies is only sound because the bound-symbol
// collector (collectIndexSymbols) now models EVERY binder those bodies can
// introduce — not just aggregate `output_idx`/`ranges` and `index` element
// positions, but also the `argmin`/`argmax` `arg` witness and its own `ranges`,
// the `skolem` invented-key name (the first positional arg, e.g. the
// `skolem('edge', …)` term in tests/valid/aggregate/skolem_distinct_rank.esm or
// the `skolem('bin', …)` term in nearest_generator_argmin.esm), and
// `apply_expression_template` `bindings` parameter names. Every such name is a
// scoped iteration/invention symbol, NOT a declared variable, so
// validateReferenceIntegrity treats it as bound and does not flag it — keeping
// emitted diagnostics byte-identical to the old `args`-only walkers on valid
// fixtures while gaining the deeper descent. (`join` is deliberately NOT an
// expression-child field, so `forEachChild` never descends into it and its
// `on` operands are never surfaced as references.)
// ---------------------------------------------------------------------------

/**
 * Extract all variable references from an expression, descending the full child
 * set via {@link forEachChild}. `args` are visited first (preserving the
 * historical DFS order of the previous `args`-only walker), then the remaining
 * expression-bearing fields, so any name the old walker surfaced keeps its
 * relative position; binder-introduced names newly reachable under the deeper
 * bodies are filtered out by {@link collectIndexSymbols} at the call site.
 */
export function extractVariableReferences(expr: Expression): string[] {
  const variables: string[] = []

  function visit(node: Expr): void {
    if (typeof node === 'string') {
      // String references are variable names
      variables.push(node)
    } else if (isExprNode(node)) {
      // Operator node — recurse over every expression-bearing child.
      forEachChild(node, (child) => visit(child))
    }
    // number / NumericLiteral leaves carry no variables
  }

  visit(expr)
  return Array.from(new Set(variables)) // Remove duplicates
}

/**
 * Collect the binder-introduced symbols an expression scopes — the names that
 * are iteration positions or invented values rather than declared variables, so
 * reference integrity must not flag them as undefined. Descent is the same
 * full-child walk (`forEachChild`) as {@link extractVariableReferences}, so
 * every symbol that function can surface from any nested body is captured here.
 *
 * Binders modelled:
 *   - `aggregate` `output_idx` entries and `ranges` keys (loop variables);
 *   - `argmin` / `argmax` `arg` witness and their own `ranges` keys;
 *   - `skolem` invented-key name (the first positional `args` entry);
 *   - `index(array, i, j, …)` element positions after the array head;
 *   - `apply_expression_template` `bindings` parameter names.
 */
export function collectIndexSymbols(expr: Expression): Set<string> {
  const symbols = new Set<string>()

  function visit(node: Expr): void {
    if (!isExprNode(node)) return

    // Aggregate output indices are bound loop variables.
    if (node.op === 'aggregate') {
      for (const idx of node.output_idx || []) {
        if (typeof idx === 'string') symbols.add(idx)
      }
    }

    // `ranges` keys are bound loop variables on aggregate AND on the
    // argmin/argmax reducers, which carry their own inner contraction range.
    if (node.ranges && typeof node.ranges === 'object') {
      for (const key of Object.keys(node.ranges)) symbols.add(key)
    }

    // argmin/argmax bind an arg-witness symbol naming the winning index.
    if ((node.op === 'argmin' || node.op === 'argmax') && typeof node.arg === 'string') {
      symbols.add(node.arg)
    }

    // skolem(name, ...): the first positional arg is the invented-key binder,
    // not a declared variable reference.
    if (node.op === 'skolem' && node.args.length > 0 && typeof node.args[0] === 'string') {
      symbols.add(node.args[0])
    }

    if (node.op === 'index') {
      // index(array, pos1, pos2, ...): positions after the array head are
      // index expressions; bare-name positions are bound index symbols.
      for (let i = 1; i < node.args.length; i++) {
        const pos = node.args[i]
        if (typeof pos === 'string') symbols.add(pos)
      }
    }

    // apply_expression_template bindings map its formal parameter names, which
    // are template-local and not references in the enclosing scope.
    if (node.bindings && typeof node.bindings === 'object') {
      for (const key of Object.keys(node.bindings)) symbols.add(key)
    }

    forEachChild(node, (child) => visit(child))
  }

  visit(expr)
  return symbols
}

/**
 * The variable a derivative differentiates. Either a bare name (`D(v)`) or the
 * array head of an `index` node (`D(index(v, i...))`) — the aggregate-IR form
 * that differentiates a single element of an arrayed state variable.
 */
function derivativeTargetVariable(arg: Expression): string | undefined {
  if (typeof arg === 'string') return arg
  if (isExprNode(arg)) {
    if (arg.op === 'index' && arg.args && arg.args.length > 0) {
      const head = arg.args[0]
      if (typeof head === 'string') return head
    }
  }
  return undefined
}

/**
 * The variable an equation LHS assigns to, peeling derivative, element-index,
 * and aggregate-output wrappers down to the underlying name. Used to credit a
 * relational / algebraic equation (e.g. the aggregate-IR `index(v, i) =
 * aggregate(...)` produced by skolem / distinct / rank) that defines a state
 * variable without a time derivative.
 */
export function lhsAssignmentTarget(lhs: Expression): string | undefined {
  if (typeof lhs === 'string') return lhs
  if (isExprNode(lhs)) {
    switch (lhs.op) {
      case 'D':
      case 'index':
        return lhs.args && lhs.args.length > 0 ? lhsAssignmentTarget(lhs.args[0]) : undefined
      case 'aggregate':
        return lhs.expr !== undefined ? lhsAssignmentTarget(lhs.expr) : undefined
      default:
        return undefined
    }
  }
  return undefined
}

/**
 * Count D(var, t) derivatives in an expression.
 *
 * Recognises the aggregate-IR derivative forms in addition to the bare
 * `D(v)`: an `index`-wrapped derivative `D(index(v, i))`, and a derivative
 * carried in an aggregate's contracted body (`aggregate(output_idx:[i],
 * expr: D(index(v, i)))`), whose `D` lives under `expr` rather than `args`.
 */
export function countDerivatives(expr: Expression): { [variable: string]: number } {
  const derivatives: { [variable: string]: number } = {}

  function visit(node: Expr): void {
    if (!isExprNode(node)) return
    if (node.op === 'D' && node.args.length >= 1) {
      const target = derivativeTargetVariable(node.args[0])
      if (target !== undefined) {
        derivatives[target] = (derivatives[target] || 0) + 1
      }
    }
    // Recurse over every expression-bearing child. An aggregate carries its
    // contracted body (and any LHS derivative) in `expr`, not `args`, which
    // `forEachChild` descends alongside `args`.
    forEachChild(node, (child) => visit(child))
  }

  visit(expr)
  return derivatives
}

/**
 * Resolve scoped variable reference like "Model.Subsystem.var"
 */
export function resolveScopedReference(reference: string, esmFile: EsmFile): boolean {
  const parts = reference.split('.')
  if (parts.length < 2) {
    return false // Not a scoped reference
  }

  const [systemName, ...pathParts] = parts
  const variableName = pathParts.pop()!

  // Try to find in models
  if (esmFile.models && esmFile.models[systemName]) {
    let current: Model | DataLoader | SubsystemRef = esmFile.models[systemName]

    // Navigate through subsystems (unresolved refs and data loaders
    // carry none, so navigation simply fails for them)
    for (const pathPart of pathParts) {
      const subsystems: Model['subsystems'] =
        'subsystems' in current ? current.subsystems : undefined
      if (!subsystems || !subsystems[pathPart]) {
        return false
      }
      current = subsystems[pathPart]
    }

    // Check if variable exists
    return 'variables' in current && !!current.variables && variableName in current.variables
  }

  // Try to find in reaction systems
  if (esmFile.reaction_systems && esmFile.reaction_systems[systemName]) {
    let current: ReactionSystem | SubsystemRef = esmFile.reaction_systems[systemName]

    // Navigate through subsystems (unresolved refs carry none, so
    // navigation simply fails for them)
    for (const pathPart of pathParts) {
      const subsystems: ReactionSystem['subsystems'] =
        'subsystems' in current ? current.subsystems : undefined
      if (!subsystems || !subsystems[pathPart]) {
        return false
      }
      current = subsystems[pathPart]
    }

    // Check if species or parameter exists
    return (
      ('species' in current && !!current.species && variableName in current.species) ||
      ('parameters' in current && !!current.parameters && variableName in current.parameters)
    )
  }

  // Try to find in data loaders (RFC pure-io-data-loaders): a loader-scoped
  // reference like "InitialConditions.O3_init" names a variable the loader
  // exposes. Loaders have no subsystems, so only a single-segment path
  // resolves.
  const loader = esmFile.data_loaders?.[systemName]
  if (loader && pathParts.length === 0) {
    return !!loader.variables && variableName in loader.variables
  }

  return false
}

/**
 * Split a scoped reference like `"System.var"` or `"System.Sub.var"` into its
 * head system segment and the ENTIRE remaining dotted path.
 *
 * Unlike a 2-limit split (`ref.split('.', 2)`), the remainder keeps every
 * trailing segment, so `"A.b.c"` → `["A", "b.c"]` rather than truncating to
 * `"b"`. This matches Go's `strings.SplitN(ref, ".", 2)` remainder semantics,
 * so the (system, variable-path) decomposition is identical across bindings.
 * Callers that need a scoped ref's system head and variable path share this
 * one helper (both `validateCouplingIntegrity` and `validateDataLoaderReferences`
 * previously parsed the same field two incompatible ways).
 */
export function splitScopedRef(ref: string): [string, string] {
  const dot = ref.indexOf('.')
  if (dot < 0) return [ref, '']
  return [ref.slice(0, dot), ref.slice(dot + 1)]
}

/**
 * Return true if the expression tree references a variable by exact name
 * (string leaf match).
 */
export function expressionReferencesName(expr: Expr | undefined | null, name: string): boolean {
  if (expr === undefined || expr === null) return false
  if (typeof expr === 'string') return expr === name
  if (isExprNode(expr)) {
    let found = false
    forEachChild(expr, (child) => {
      if (!found && expressionReferencesName(child, name)) found = true
    })
    return found
  }
  return false
}
