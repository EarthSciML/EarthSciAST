/**
 * Well-foundedness of a causal self-reference (recurrence) along one index axis
 * — esm-spec §4.3.1.1, CONFORMANCE_SPEC §5.19.
 *
 * The construct: an equation defining an array-shaped unknown `V` whose RHS
 * `aggregate` body reads `index(V, k - c)` — the array being defined, strictly
 * earlier along ONE of the aggregate's own output axes. There is no new op and
 * no new schema field; the recurrence, its axis and its lag are all read off the
 * document, which is why recognition is STRUCTURAL and lives here.
 *
 * This module is the STATIC half of the construct, and the half every binding
 * implements whether or not it evaluates anything (CONFORMANCE_SPEC §5.19.5,
 * rejection parity). This binding evaluates no array numerics at all, so the
 * static half is the whole of its duty — and it cuts both ways: rejecting a
 * LEGAL recurrence is the same defect as admitting an illegal one, which is why
 * `tests/valid/recurrence_causal_self_reference.esm` is a required positive
 * control and why `CadenceSeeder.leaf` hands the self-edge `V -> V` to these
 * rules instead of calling it a cycle.
 *
 * It decides two things about such an equation:
 *
 *   - whether the read is WELL FOUNDED — affine in its frame symbol with
 *     coefficient 1, offset on exactly one axis, and not provably
 *     same-cell-or-later (`recurrence_not_wellfounded`);
 *   - whether the construct CARRYING the read can be sequenced cell by cell
 *     (`recurrence_unsupported_form`).
 *
 * **The proof obligation splits in two, and only one half is mandatory**
 * (esm-spec §4.3.1.1 *Admitted lag*, normative). The COEFFICIENT of the frame
 * symbol must be provably 1: without it the read names no position relative to
 * the cell being written, and which axis the recurrence folds along — and in
 * which direction — is undecidable. The SIGN of the lag need not be provable at
 * all, and a checker MUST NOT reject a lag merely because it could not bound it:
 * a self-read resolves only against cells the sweep has already published, so an
 * ill-founded read cannot return a number — it faults (§4.3.1.1 point 5 is
 * fail-closed, never the §4.3.3 zero ghost).
 *
 * That asymmetry is what keeps this validator and an evaluator from disagreeing,
 * and it runs in a specific direction. A validator sees `ranges` BEFORE they are
 * resolved against the `index_sets` registry, so it necessarily proves strictly
 * less than an evaluator does; a validator that treated "unproven" as "illegal"
 * would reject documents its own evaluator accepts, which is the one divergence
 * between the two that is never defensible. So an unprovable lag is admitted on
 * the same footing as a straddling one — see
 * `tests/fixtures/recurrence/08_recurrence_parameter_valued_lag.esm`, whose lag
 * is a PARAMETER that nothing static can bound, and
 * `04_recurrence_banded_lag_fold.esm`, whose `lag = a` straddles zero and whose
 * `a = 0` cell is excluded by a guard in the body rather than by arithmetic.
 *
 * **Why this module sits at core level rather than under `validate/`.** Its
 * analysis has a second consumer: `CadenceSeeder.leaf` needs
 * {@link isRecurrenceCandidate} to decide whether a self-edge `V -> V` is an
 * ordering these rules govern or a genuine self-dependency to be reported as a
 * cycle. `validate/` already imports `cadence.js`, so leaving the analysis there
 * would put a cycle between the two directories. The validator entry point
 * {@link validateRecurrenceEquations} still belongs to `validate()` and is
 * called from its orchestrator.
 *
 * Mirrors the reference validator `check_recurrence_equation` in
 * `pkg/earthsci-ast-rs/src/structural.rs` decision for decision: the two must
 * agree on which documents are legal, or "exact agreement" in the §5.2
 * Validation row is not true.
 */

import { isExprNode } from './expression.js'
import { numericValue } from './numeric-literal.js'
import { ERROR_CODES } from './errors.js'
import type { Model, ExpressionNode, EsmFile, IndexSet } from './types.js'
import type { Expr } from './expression.js'
import type { StructuralError } from './validate/types.js'

/** Inclusive integer bounds `[lo, hi]` of an index symbol or an affine term. */
type Bounds = [number, number]

/**
 * Bounds of an index symbol, resolved from the ranges available to the
 * VALIDATOR — unlike an evaluator, which sees ranges already resolved against
 * the index-set registry.
 *
 * A dense literal interval, an `interval` set's `1..size`, or a `categorical`
 * set's `1..len(members)`. Any other form is UNKNOWN, and an unknown symbol
 * makes a lag unprovable rather than illegal (see the module note on the split
 * proof obligation): a `ragged` or `derived` set has no static extent, and a
 * `{ from, of }` inner set's extent depends on its parent index.
 */
function symbolBounds(range: unknown, esmFile: EsmFile | undefined): Bounds | undefined {
  if (Array.isArray(range)) {
    // `[start, stop]` (unit step) or `[start, step, stop]`. Metaparameter
    // expressions in these slots are folded to integers at load (§9.7.6), so
    // anything still non-integral here is not statically resolvable.
    const lo = numericValue(range[0])
    const hi = numericValue(range[range.length - 1])
    if (lo === undefined || hi === undefined) return undefined
    if (!Number.isInteger(lo) || !Number.isInteger(hi)) return undefined
    return [lo, hi]
  }
  if (range && typeof range === 'object' && 'from' in range) {
    const ref = range as { from?: unknown; of?: unknown }
    // A ragged / dependent inner set enumerates per parent, so it has no single
    // static extent to bound a lag with.
    if (ref.of !== undefined) return undefined
    if (typeof ref.from !== 'string') return undefined
    const set: IndexSet | undefined = esmFile?.index_sets?.[ref.from]
    if (set === undefined) return undefined
    // `interval` by declared size, `categorical` by member count. Both are
    // 1-origin dense ranges at evaluation, and an evaluator resolves BOTH before
    // it builds a rule — so omitting `categorical` here would make the validator
    // prove less than the evaluator and reject a document the evaluator accepts.
    if (set.kind === 'interval') {
      const size = numericValue(set.size)
      return size !== undefined && Number.isInteger(size) ? [1, size] : undefined
    }
    if (set.kind === 'categorical') {
      return Array.isArray(set.members) ? [1, set.members.length] : undefined
    }
    // `derived` / `ragged`: no static extent.
    return undefined
  }
  return undefined
}

/** Every statically resolvable symbol bound an `aggregate`'s `ranges` declares. */
function rangeBounds(node: ExpressionNode, esmFile: EsmFile | undefined): Array<[string, Bounds]> {
  const out: Array<[string, Bounds]> = []
  for (const [sym, range] of Object.entries(node.ranges ?? {})) {
    const bounds = symbolBounds(range, esmFile)
    if (bounds !== undefined) out.push([sym, bounds])
  }
  return out
}

/**
 * The affine form of an index expression with respect to the frame symbol
 * `sym`: the coefficient of `sym`, plus the bounds of the symbol-free part.
 *
 * `konst` is OPTIONAL, and that is the whole point of the type. The two halves
 * carry different proof obligations (see the module note): `coef` must be
 * provable, so a shape whose coefficient cannot be determined makes the whole
 * result `undefined`; `konst` need not be, so an unbounded constant part is
 * represented as a known coefficient with `konst: undefined` — a lag of unknown
 * SIGN — rather than as a failure.
 */
interface Affine {
  coef: number
  /** Bounds of the symbol-free part; `undefined` when they cannot be proved. */
  konst?: Bounds
}

/**
 * The affine form of `e` in `sym`, or `undefined` when `e` is not affine in
 * `sym` at all (an unsupported operator, a non-integral literal, a product of
 * two non-constants).
 *
 * Must agree exactly with an evaluator's `affine_in_sym` on which COEFFICIENTS
 * are decidable. It deliberately does NOT have to match on which constant parts
 * are bounded — an evaluator resolves ranges this function cannot see, and the
 * asymmetry is safe in exactly one direction: proving less here admits more, and
 * an admitted-but-ill-founded read faults at evaluation instead of returning a
 * number.
 */
function affineInSym(e: Expr, sym: string, env: ReadonlyMap<string, Bounds>): Affine | undefined {
  if (typeof e === 'string') {
    if (e === sym) return { coef: 1, konst: [0, 0] }
    // Any other NAME contributes no coefficient. If it is an index symbol in
    // scope it also contributes its range — `y - a` is affine in `y` with the
    // symbol-free part `-a` bounded by `a`'s range, which is what admits the
    // banded-fold spelling. If it is a parameter, or a symbol whose range this
    // pass cannot resolve, the constant part is simply UNKNOWN: still affine,
    // still coefficient 0, and the lag's sign is left unproven rather than
    // treated as illegal (fixture 08).
    return { coef: 0, konst: env.get(e) }
  }
  const literal = numericValue(e)
  if (literal !== undefined) {
    // A non-integral or infinite literal cannot name an index position.
    if (!Number.isFinite(literal) || !Number.isInteger(literal)) return undefined
    return { coef: 0, konst: [literal, literal] }
  }
  if (!isExprNode(e) || (e.args ?? []).length !== 2) return undefined
  const a = affineInSym(e.args[0], sym, env)
  const b = affineInSym(e.args[1], sym, env)
  if (a === undefined || b === undefined) return undefined
  // An interval arithmetic result is known only when BOTH operands' are.
  const both = a.konst !== undefined && b.konst !== undefined
  switch (e.op) {
    case '+':
      return {
        coef: a.coef + b.coef,
        konst: both ? [a.konst![0] + b.konst![0], a.konst![1] + b.konst![1]] : undefined,
      }
    case '-':
      return {
        coef: a.coef - b.coef,
        konst: both ? [a.konst![0] - b.konst![1], a.konst![1] - b.konst![0]] : undefined,
      }
    case '*': {
      // One side must be a single KNOWN constant; the other carries the symbol.
      // Scaling by an interval, or by an unknown, is not affine — and here the
      // coefficient itself would be unprovable, which is the half that may not
      // be guessed at.
      const scalar = (x: Affine): number | undefined =>
        x.coef === 0 && x.konst !== undefined && x.konst[0] === x.konst[1] ? x.konst[0] : undefined
      const ka = scalar(a)
      const kb = scalar(b)
      const [k, other] = ka !== undefined ? [ka, b] : kb !== undefined ? [kb, a] : [undefined, a]
      if (k === undefined) return undefined
      return {
        coef: other.coef * k,
        konst:
          other.konst === undefined
            ? undefined
            : [
                Math.min(other.konst[0] * k, other.konst[1] * k),
                Math.max(other.konst[0] * k, other.konst[1] * k),
              ],
      }
    }
    default:
      return undefined
  }
}

/**
 * Ops whose operands are consumed WHOLE. A self-read underneath one of these
 * names a cell of an array that must exist in full before the op can run, so no
 * cell-by-cell sweep can supply it — `recurrence_unsupported_form` rather than
 * `recurrence_not_wellfounded`, because the read itself may be perfectly causal
 * and it is the CARRIER that cannot be sequenced.
 *
 * `apply_expression_template` is deliberately NOT here. Its operands ride the
 * `bindings` field, which this walk does not visit (and must not start visiting
 * unilaterally — five bindings mirror this field set and §5.19.5 is exact
 * agreement), so listing it was a rule that barely reached what it named. It is
 * also unreachable in practice: a template application surviving into an
 * evaluation position is already an `unlowered_operator` error (esm-spec
 * §9.6.4). So this list names only the ops that legitimately reach evaluation
 * and consume an operand whole.
 */
const OPS_BLOCKING_CELL_RESTRICTION: ReadonlySet<string> = new Set([
  'reshape',
  'transpose',
  'concat',
  'broadcast',
])

/**
 * One self-read the structural walk found: its index arguments, the symbol
 * bounds in scope where it was found, and whether it was reached only through a
 * construct that cannot be restricted to one cell.
 */
interface SelfRead {
  args: Expr[]
  env: Map<string, Bounds>
  unsequenceable: boolean
}

/**
 * Collect every `index(var, ...)` read in an expression, tracking the index
 * symbols in scope and whether the read sits under an unsequenceable carrier.
 * Also latches `bare`: a read of `var` as a plain leaf, NOT through `index`.
 *
 * The child fields are enumerated HERE rather than delegated to the package's
 * shared `forEachChild`, for two reasons that both matter.
 *
 * First, the two child slots this walk must treat differently are not
 * distinguishable through that walker: `args[0]` of a self-read is the variable
 * NAME rather than an operand (counting it would latch `bare` on every legal
 * recurrence), and a `makearray` `values` entry is a REGION VALUE that must
 * block sequencing — but `forEachChild` reports `axes` / `bindings` entries
 * under the map's OWN key, so a field-name test cannot tell a region value from
 * a template binding.
 *
 * Second, and decisively: this walk visits exactly what the reference validator
 * visits — `args`, `expr`, `filter`, `key`, `lower`, `upper`, `values` — and NOT
 * `axes` / `bindings`, even though those are expression positions in the
 * canonical `EXPRESSION_CHILD_KEYS` set. Rejection parity is EXACT agreement
 * (§5.19.5): seeing a self-read the reference validator does not see would make
 * this binding reject a document the others accept, which §5.19.5 forbids in the
 * same breath as the converse. That gap is real — `apply_expression_template`
 * is on the blocking list above, yet its operands ride `bindings` rather than
 * `args`, so the blocking rule barely reaches it — and it should be closed in
 * every binding at once rather than unilaterally here.
 */
function collectSelfReads(
  e: Expr,
  varName: string,
  esmFile: EsmFile | undefined,
  env: Array<[string, Bounds]>,
  blocked: boolean,
  out: SelfRead[],
  state: { bare: boolean },
): void {
  if (!isExprNode(e)) {
    if (e === varName) state.bare = true
    return
  }

  // An `aggregate` binds its `ranges` symbols over its own body; an inner
  // binding shadows an outer one of the same name, which the ordered array plus
  // insertion-ordered snapshot below reproduces.
  const pushed = e.op === 'aggregate' ? rangeBounds(e, esmFile) : []
  env.push(...pushed)

  const isSelfIndex = e.op === 'index' && (e.args ?? [])[0] === varName
  if (isSelfIndex) {
    out.push({
      args: (e.args ?? []).slice(1),
      env: new Map(env),
      unsequenceable: blocked,
    })
  }

  const blockedChildren = blocked || OPS_BLOCKING_CELL_RESTRICTION.has(e.op)
  const recurse = (child: Expr | undefined, childBlocked: boolean): void => {
    if (child === undefined) return
    collectSelfReads(child, varName, esmFile, env, childBlocked, out, state)
  }

  // `args[0]` of a self-read names the variable; every other arg is an operand.
  const args = e.args ?? []
  for (let i = isSelfIndex ? 1 : 0; i < args.length; i++) recurse(args[i], blockedChildren)
  for (const side of [e.expr, e.filter, e.key, e.lower, e.upper]) {
    recurse(side as Expr | undefined, blockedChildren)
  }
  // A `makearray` REGION VALUE is evaluated once for the whole region, so a
  // self-read inside one cannot be sequenced however the regions are ordered:
  // §4.3.2's region order fixes which write WINS, not which cell is evaluated
  // when (esm-spec §4.3.1.1).
  for (const value of e.values ?? []) recurse(value as Expr, true)

  env.length -= pushed.length
}

/**
 * The variable an equation DEFINES, with the cell frame its LHS declares (if
 * any): a bare variable, or the §4.3 indexed-aggregate LHS form
 * `aggregate{expr: index(V, k...)}`.
 *
 * A DERIVATIVE LHS (`D(u)`) deliberately yields `undefined`: it defines no array
 * algebraically, so a stencil read of `u` at `i-1` there is a gather on the
 * solver's state, not a self-reference, and must not be dragged through the
 * well-foundedness table.
 */
function recurrenceLhsTarget(lhs: Expr): { varName: string; frame?: (string | 1)[] } | undefined {
  if (typeof lhs === 'string') return { varName: lhs }
  if (!isExprNode(lhs) || lhs.op !== 'aggregate') return undefined
  const inner = lhs.expr
  if (!isExprNode(inner) || inner.op !== 'index') return undefined
  const target = (inner.args ?? [])[0]
  if (typeof target !== 'string') return undefined
  return { varName: target, frame: lhs.output_idx }
}

/**
 * Report every ill-founded or unsequenceable causal self-reference in a
 * component's equations (esm-spec §4.3.1.1). Emits nothing for an equation
 * whose RHS contains no self-read, which is every equation in every document
 * that does not use the construct.
 *
 * Findings are pointed at the containing expression field,
 * `/models/<M>/equations/<i>/rhs` — the pointer convention §5.19.5 pins and the
 * one the reference checks already share.
 */
export function validateRecurrenceEquations(
  model: Model,
  componentPath: string,
  esmFile?: EsmFile,
): StructuralError[] {
  const errors: StructuralError[] = []
  const equations = model.equations ?? []
  if (equations.length === 0) return errors

  // Array-shaped unknowns are the only variables a causal self-reference can
  // define: a recurrence folds along an output AXIS, and a scalar has none.
  const arrayShaped = new Set(
    Object.entries(model.variables ?? {})
      .filter(([, v]) => Array.isArray(v.shape) && v.shape.length > 0)
      .map(([name]) => name),
  )
  if (arrayShaped.size === 0) return errors

  equations.forEach((equation, eqIdx) => {
    const target = recurrenceLhsTarget(equation.lhs as Expr)
    if (target === undefined || !arrayShaped.has(target.varName)) return
    errors.push(
      ...checkRecurrenceEquation(
        equation.rhs as Expr,
        target,
        `${componentPath}/equations/${eqIdx}/rhs`,
        esmFile,
      ),
    )
  })
  return errors
}

/** Whether `varName` is declared with a non-empty `shape` in this component. */
function isArrayShaped(model: Model, varName: string): boolean {
  const shape = model.variables?.[varName]?.shape
  return Array.isArray(shape) && shape.length > 0
}

/**
 * Whether the equation defining `varName` is a RECOGNIZED, well-founded causal
 * recurrence: the variable is array-shaped, its RHS contains at least one
 * self-read, and every self-read passes the §4.3.1.1 checks.
 *
 * This is the predicate that licenses dropping the self-edge `V -> V` from the
 * observed dependency graph, and it is deliberately the SAME code path as the
 * validator — `checkRecurrenceEquation` decides both. If the two could disagree,
 * a malformed self-reference could be exempted from cycle detection by one and
 * reported by the other, and which of the two ran first would decide whether the
 * document loaded.
 *
 * The exemption belongs to the construct that earns it. A self-reference the
 * analysis does NOT recognize is not an ordering within one variable — it is an
 * equation reading a name nothing binds — so it keeps its cycle rejection
 * (esm-spec §4.3.1.1, CONFORMANCE_SPEC §5.19.5: admitting a recurrence must not
 * weaken any cycle rejection). A scalar `x ~ x + 1` has no axis to fold along
 * and so can never qualify.
 */
export function isWellFoundedRecurrence(model: Model, varName: string, esmFile?: EsmFile): boolean {
  const candidate = recurrenceCandidate(model, varName, esmFile)
  if (candidate === undefined) return false
  // The path is unused: only the COUNT of findings matters here.
  return checkRecurrenceEquation(candidate.rhs, candidate.target, '', esmFile).length === 0
}

/**
 * Whether `varName`'s defining equation is in the RECURRENCE CHECKER'S
 * JURISDICTION: array-shaped, with at least one `index` self-read in its own
 * RHS — well founded or not.
 *
 * This, and not {@link isWellFoundedRecurrence}, is what the cadence seeder
 * needs, and the difference is load-bearing. Candidacy answers "does
 * {@link validateRecurrenceEquations} own the diagnosis for this equation?" A
 * MALFORMED array self-read (`index(V, k+1)`, `index(V, 2k)`, a self-read in a
 * `makearray` region) must be reported as `recurrence_not_wellfounded` /
 * `recurrence_unsupported_form` at the offending expression, because those codes
 * are the cross-binding contract (CONFORMANCE_SPEC §5.19.5). Gating the
 * seeder's self-edge on WELL-FOUNDEDNESS instead would make the cadence cycle
 * error fire first for exactly those documents and collapse the whole file to a
 * single `load_error`, losing the code — the same masking defect this feature
 * started as, merely moved from the legal case to the illegal one.
 *
 * Candidacy is still narrow where it matters, which is what keeps §5.19.5's
 * converse duty. A self-reference with NO `index` read at all (a bare `V ~ V + 1`,
 * scalar or array-shaped) is not a recurrence in any sense and nothing else will
 * report it, so it keeps its `CadenceCycleError`; and a cycle through two
 * DISTINCT variables never reaches this predicate.
 */
export function isRecurrenceCandidate(model: Model, varName: string, esmFile?: EsmFile): boolean {
  return recurrenceCandidate(model, varName, esmFile) !== undefined
}

/**
 * The defining equation of `varName` when it is a recurrence candidate: the
 * variable is array-shaped and its RHS carries at least one `index` self-read.
 * The single place the two predicates above agree on what a candidate IS.
 */
function recurrenceCandidate(
  model: Model,
  varName: string,
  esmFile: EsmFile | undefined,
): { rhs: Expr; target: { varName: string; frame?: (string | 1)[] } } | undefined {
  if (!isArrayShaped(model, varName)) return undefined
  for (const equation of model.equations ?? []) {
    const target = recurrenceLhsTarget(equation.lhs as Expr)
    if (target === undefined || target.varName !== varName) continue
    const rhs = equation.rhs as Expr
    // A definition with no `index` self-read is not a recurrence however clean
    // the rest of it is, and `checkRecurrenceEquation` reports nothing for it —
    // so the read count has to be asked separately rather than inferred from an
    // empty finding list.
    if (collectReads(rhs, varName, esmFile).reads.length === 0) return undefined
    return { rhs, target }
  }
  return undefined
}

/** Every `index(varName, ...)` read in `rhs`, plus whether a BARE read occurs. */
function collectReads(
  rhs: Expr,
  varName: string,
  esmFile: EsmFile | undefined,
): { reads: SelfRead[]; bare: boolean } {
  const reads: SelfRead[] = []
  const state = { bare: false }
  collectSelfReads(rhs, varName, esmFile, [], false, reads, state)
  return { reads, bare: state.bare }
}

/**
 * The per-equation rule. Returns at most ONE finding: the shapes below are not
 * independent defects to enumerate but competing explanations of the same
 * malformed read, and the first one that applies is the one an author can act
 * on. Ordered from the most structural (no array exists to sweep) to the most
 * arithmetic (this lag points the wrong way).
 */
function checkRecurrenceEquation(
  rhs: Expr,
  target: { varName: string; frame?: (string | 1)[] },
  path: string,
  esmFile: EsmFile | undefined,
): StructuralError[] {
  const varName = target.varName
  const { reads, bare } = collectReads(rhs, varName, esmFile)
  if (reads.length === 0) return []

  const finding = (code: string, message: string, axis?: string | null): StructuralError[] => [
    { path, code, message, details: { variable: varName, recurrence_axis: axis ?? null } },
  ]

  if (bare) {
    return finding(
      ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
      `'${varName}' is read bare inside its own defining equation as well as through \`index\`. ` +
        'A bare read names the whole array, which does not exist while the recurrence sweeps it ' +
        '(esm-spec §4.3.1.1).',
    )
  }

  if (reads.some((r) => r.unsequenceable)) {
    return finding(
      ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
      `a causal self-read of '${varName}' is reached only through a construct that evaluates its ` +
        'operand whole — a `makearray` region value, or a ' +
        '`reshape`/`transpose`/`concat`/`broadcast` operand — so no cell-by-cell sweep can ' +
        "supply it. A `makearray`'s region order fixes which write WINS, not the order cells are " +
        'EVALUATED in (esm-spec §4.3.1.1, §4.3.2); write the recurrence as one `aggregate` with ' +
        'the base case as an `ifelse` guard in the body.',
    )
  }

  // The cell frame: the indexed-aggregate LHS's own indices, else the RHS
  // aggregate's.
  const rhsFrame = isExprNode(rhs) && rhs.op === 'aggregate' ? rhs.output_idx : undefined
  const frame = target.frame ?? rhsFrame
  if (frame === undefined) {
    return finding(
      ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
      `the definition of '${varName}' reads '${varName}' at another position, but the equation ` +
        'declares no cell frame to sweep: its RHS is not an `aggregate` over the ' +
        "variable's axes and its LHS is not the indexed-aggregate form " +
        `\`aggregate{expr: index(${varName}, k…)}\` (esm-spec §4.3.1.1).`,
    )
  }
  // `output_idx` admits the integer 1 as a literal singleton dimension. A
  // literal has no symbol to fold along, so it cannot be a recurrence axis.
  if (frame.length === 0 || frame.some((n) => typeof n !== 'string' || /^-?\d+$/.test(n))) {
    return finding(
      ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
      `the recurrence definition of '${varName}' has no symbolic output index to fold along ` +
        `(${JSON.stringify(frame)}); a literal singleton dimension cannot be a recurrence axis ` +
        '(esm-spec §4.3.1.1).',
    )
  }
  const frameNames = frame as string[]

  // The frame symbols' own bounds come from the DEFINING aggregate's `ranges`;
  // a read's captured scope refines them with whatever inner symbols it saw.
  const frameEnv = new Map<string, Bounds>(
    isExprNode(rhs) && rhs.op === 'aggregate' ? rangeBounds(rhs, esmFile) : [],
  )

  let axis: number | undefined
  for (const read of reads) {
    if (read.args.length !== frameNames.length) {
      return finding(
        ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
        `a causal self-read of '${varName}' supplies ${read.args.length} indices but its frame ` +
          `has ${frameNames.length} axes; every self-read indexes every axis ` +
          '(esm-spec §4.3.1.1).',
      )
    }
    const env = new Map(frameEnv)
    for (const [k, v] of read.env) env.set(k, v)

    let lagged: number | undefined
    for (let d = 0; d < read.args.length; d++) {
      const sym = frameNames[d]
      const affine = affineInSym(read.args[d], sym, env)
      if (affine === undefined) {
        return finding(
          ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
          `index ${d} of a causal self-read of '${varName}' is not affine in its frame symbol ` +
            `'${sym}'. A self-read names a position RELATIVE to the cell being written ` +
            `(\`${sym} - 1\`, \`${sym} - a\`, \`${sym} - a - 2\`), which is what makes the ` +
            'recurrence axis and its direction decidable (esm-spec §4.3.1.1).',
        )
      }
      // The COEFFICIENT is the half that must be provable: without it the read
      // names no position relative to the cell being written, and which axis the
      // recurrence folds along is undecidable (esm-spec §4.3.1.1).
      if (affine.coef !== 1) {
        return finding(
          ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
          `index ${d} of a causal self-read of '${varName}' carries its frame symbol '${sym}' ` +
            `with coefficient ${affine.coef}, not 1, so it does not name a position relative to ` +
            'the cell being written (esm-spec §4.3.1.1).',
        )
      }
      // The lag's SIGN, by contrast, need not be provable. An unbounded constant
      // part means this axis IS the recurrence axis, unproven — not the identity
      // and not a rejection. The cells where the lag would turn out non-causal
      // cannot be read at all, because the sweep has not published them, so the
      // fail-closed read is what stands in for the missing proof.
      if (affine.konst === undefined) {
        if (lagged !== undefined) {
          return finding(
            ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
            `a causal self-read of '${varName}' is offset on more than one axis. A recurrence ` +
              'folds along exactly ONE axis; every other index must be the bare frame symbol ' +
              '(esm-spec §4.3.1.1).',
            sym,
          )
        }
        lagged = d
        continue
      }
      // lag = sym - arg, so the symbol-free part's bounds invert.
      const [lagLo, lagHi] = [-affine.konst[1], -affine.konst[0]]
      // Exactly [0, 0]: the read stays on this axis's own cell, so this axis is
      // simply not the recurrence axis. Not an error on its own — a
      // multi-dimensional recurrence reads `index(V, i, j-1)`.
      if (lagLo === 0 && lagHi === 0) continue
      if (lagHi <= 0) {
        return finding(
          ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
          `index ${d} of a causal self-read of '${varName}' names the cell being written, or a ` +
            `later one, on axis '${sym}'. A causal self-reference reads strictly EARLIER ` +
            'positions; no sweep order can satisfy a same-cell or forward read ' +
            '(esm-spec §4.3.1.1).',
          sym,
        )
      }
      // Everything left either provably leads (`lagLo >= 1`) or STRADDLES zero.
      // Straddling is admitted: the cells where the lag is not strictly earlier
      // are excluded by a guard in the body, and fault if they are not.
      if (lagged !== undefined) {
        return finding(
          ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
          `a causal self-read of '${varName}' is offset on more than one axis. A recurrence ` +
            'folds along exactly ONE axis; every other index must be the bare frame symbol ' +
            '(esm-spec §4.3.1.1).',
          sym,
        )
      }
      lagged = d
    }

    if (lagged === undefined) {
      return finding(
        ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
        `a causal self-read of '${varName}' is at the same cell on every axis, so it defines ` +
          `'${varName}' in terms of itself rather than of an earlier position ` +
          '(esm-spec §4.3.1.1).',
      )
    }
    if (axis === undefined) {
      axis = lagged
    } else if (axis !== lagged) {
      return finding(
        ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
        `the causal self-reads of '${varName}' disagree on the recurrence axis: one folds along ` +
          `'${frameNames[axis]}' and another along '${frameNames[lagged]}'. A definition folds ` +
          'along exactly one axis (esm-spec §4.3.1.1).',
        frameNames[lagged],
      )
    }
  }
  return []
}
