use super::*;

// ============================================================================
// Interpreter
// ============================================================================

/// Walk a [`ResolvedExpr`] tree given current state, parameter, observed
/// vectors and time. Returns a finite f64 on success, or NaN / ±inf on
/// runtime math errors (the solver detects these as a step failure).
pub fn interpret(
    expr: &ResolvedExpr,
    state: &[f64],
    params: &[f64],
    observed: &[f64],
    t: f64,
) -> f64 {
    // Leaf ingress rounds to the active precision, mirroring the array oracle's
    // `Expr::Number` / `lookup_variable` arms (`crate::precision`): under
    // `element_type: "Float32"` a literal or a bound value that reaches the
    // result through no operator must still be the binary32 value. Identity
    // under Float64, where `round` is `|v| v`.
    let prec = crate::precision::active();
    match expr {
        ResolvedExpr::Number(n) => prec.round(*n),
        ResolvedExpr::State(i) => prec.round(state[*i]),
        ResolvedExpr::Param(i) => prec.round(params[*i]),
        ResolvedExpr::Observed(i) => prec.round(observed[*i]),
        ResolvedExpr::Time => prec.round(t),
        ResolvedExpr::Precision { prec, arg } => {
            let _guard = crate::precision::enter(*prec);
            interpret(arg, state, params, observed, t)
        }
        ResolvedExpr::Op { op, args } => eval_op(op, args, state, params, observed, t),
        ResolvedExpr::Fn { name, args } => eval_fn(name, args, state, params, observed, t),
    }
}

/// Evaluate a resolved `fn` call (esm-spec §9.2). Scalar arguments are folded
/// per call through [`interpret`]; array arguments were materialized at resolve
/// time. Dispatches to the shared [`crate::registered_functions`] kernel and
/// lifts the result to `f64`. A registry error (unknown function, arity /
/// shape mismatch, non-monotonic axis) surfaces as the NaN sentinel — the same
/// runtime-error convention [`eval_op`] uses; the solver reads NaN as a step
/// failure.
fn eval_fn(
    name: &str,
    args: &[ResolvedFnArg],
    state: &[f64],
    params: &[f64],
    observed: &[f64],
    t: f64,
) -> f64 {
    use crate::registered_functions::{ClosedArg, evaluate_closed_function};

    let closed_args: Vec<ClosedArg> = args
        .iter()
        .map(|a| match a {
            ResolvedFnArg::Scalar(e) => ClosedArg::Scalar(interpret(e, state, params, observed, t)),
            ResolvedFnArg::Array(v) => ClosedArg::Array(v.clone()),
            ResolvedFnArg::Array2D(v) => ClosedArg::Array2D(v.clone()),
        })
        .collect();
    match evaluate_closed_function(name, &closed_args) {
        Ok(v) => v.as_f64(),
        Err(_) => f64::NAN,
    }
}

/// Fold a scalar [`Expr`] to a numeric value with the given variable bindings.
///
/// Canonical single-expression entry point on the scalar runner: builds a
/// parameter table from `bindings`, runs [`resolve_expr`], then walks the
/// result through [`interpret`] / [`eval_op`] — the same primitives the
/// scalar ODE solver uses. Adding an op to `eval_op` transparently
/// extends single-expression evaluation; there is no parallel dispatch table.
///
/// State and observed buffers are empty. The independent-variable `t` reads
/// from `bindings.get("t")` if present (caller-supplied "current time"),
/// otherwise defaults to `0.0`.
///
/// On success returns `Ok(value)`. If `expr` references variable names that
/// are not in `bindings` (and that aren't `t`), returns `Err(names)` listing
/// each missing reference in encounter order. An operator this interpreter has
/// no rule for is likewise an `Err` (a rendered
/// [`CompileError::UnevaluableOperatorError`]) — it used to fold to `NaN` in
/// the `Ok` branch, which is the defect issue #220 closed. Genuine MATH errors
/// (division by zero, log of a non-positive number) still propagate as
/// `f64::NAN` or `±inf` in the `Ok` branch: that is the canonical runner's
/// convention, and the one case where a NaN really is the answer.
pub fn fold_constant_expr(
    expr: &Expr,
    bindings: &HashMap<String, f64>,
) -> Result<f64, Vec<String>> {
    let mut unbound: Vec<String> = Vec::new();
    collect_unbound(expr, bindings, &mut unbound);
    if !unbound.is_empty() {
        return Err(unbound);
    }
    let mut names: Vec<String> = bindings.keys().cloned().collect();
    names.sort();
    let mut param_index: HashMap<String, usize> = HashMap::with_capacity(names.len());
    let mut params: Vec<f64> = Vec::with_capacity(names.len());
    for (i, n) in names.iter().enumerate() {
        param_index.insert(n.clone(), i);
        params.push(bindings[n]);
    }
    let resolved = resolve_expr(expr, &HashMap::new(), &param_index, &HashMap::new(), None)
        .map_err(|e| vec![format!("{e:?}")])?;
    let t_value = bindings.get("t").copied().unwrap_or(0.0);
    Ok(interpret(&resolved, &[], &params, &[], t_value))
}

fn collect_unbound(expr: &Expr, bindings: &HashMap<String, f64>, out: &mut Vec<String>) {
    match expr {
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Variable(name) => {
            // `t` is supplied by the caller (or defaults to 0.0); never report
            // it as unbound even if the user did not put it in `bindings`.
            if name != "t" && !bindings.contains_key(name) {
                out.push(name.clone());
            }
        }
        Expr::Operator(node) => {
            for arg in &node.args {
                collect_unbound(arg, bindings, out);
            }
        }
    }
}

/// Does this interpreter have an evaluation rule for `op`?
///
/// The scalar analogue of [`crate::simulate_array::is_evaluable_op`], and the
/// single source of truth for THIS evaluator's operator coverage. It is kept
/// adjacent to [`eval_op`] so the two cannot drift: every name listed here has
/// a `match` arm below (or, for `fn` and the precision marker, a dedicated
/// [`ResolvedExpr`] variant that [`interpret`] dispatches before `eval_op` is
/// reached), and every arm below is listed here.
///
/// It is NOT the same set as [`crate::op_registry::is_core_op`]: the registry
/// answers "may this op appear in a legal AST", this answers "can the scalar
/// interpreter produce a number for it". Nor is it the same set as the ARRAY
/// runtime's oracle — this evaluator's values are `f64`, so on top of the nine
/// core ops neither evaluator has a rule for (`skolem`, `rank`, `distinct`,
/// `argmin`, `argmax`, `ic`, `enum`, `table_lookup`,
/// `apply_expression_template`) it also has none for the array / tensor ops
/// (`aggregate`, `makearray`, `index`, `reshape`, `transpose`, `concat`,
/// `broadcast`) or the geometry ops (`intersect_polygon`,
/// `polygon_intersection_area`) — a document carrying one belongs to
/// [`crate::simulate_array`], which [`crate::simulate::is_array_file`] routes
/// it to.
///
/// `const` is absent for a different reason: its value hangs off the NODE, not
/// off `args`, so a plain [`ResolvedExpr::Op`] cannot carry it.
/// [`crate::simulate::resolve_expr`] folds a SCALAR `const` straight to a
/// [`ResolvedExpr::Number`] before this oracle is consulted; only an ARRAY
/// `const`, which this evaluator has no value type for, reaches the gate.
///
/// Every one of the gated ops used to reach [`eval_op`]'s `_ => f64::NAN`
/// backstop and come back as a NUMBER (issue #220). They are refused by name
/// now, and that backstop is an `unreachable!`.
#[must_use]
pub fn is_evaluable_op(op: &str) -> bool {
    matches!(
        op,
        // n-ary arithmetic and the n-ary reductions (left fold).
        "+" | "*" | "min" | "max"
        // Unary negate OR binary subtract.
        | "-"
        // Strictly-binary arithmetic, comparisons and logicals.
        | "/" | "^" | "atan2" | "<" | ">" | "<=" | ">=" | "==" | "!=" | "and" | "or"
        // Unary elementary functions / trig / rounding / sign / abs / not.
        | "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil"
        | "sin" | "cos" | "tan" | "asin" | "acos" | "atan"
        | "sinh" | "cosh" | "tanh" | "asinh" | "acosh" | "atanh" | "not"
        // Canonical unary negate and the nullary boolean literal.
        | "neg" | "true"
        // Conditional.
        | "ifelse"
        // Form ops with a defined runtime meaning here: a `D` on the RHS is the
        // legacy-parity zero, `Pre` passes its operand through.
        | "D" | "Pre"
        // Resolved to their own `ResolvedExpr` variants by `resolve_expr` and
        // dispatched by `interpret` before `eval_op` sees them — the closed
        // function registry (esm-spec §9.2) and the engine-internal
        // precision-boundary marker (`crate::precision_infer::MARKER_OP`).
        | "fn"
        | crate::precision_infer::MARKER_OP
    )
}

fn eval_op(
    op: &str,
    args: &[ResolvedExpr],
    state: &[f64],
    params: &[f64],
    observed: &[f64],
    t: f64,
) -> f64 {
    let v = |i: usize| interpret(&args[i], state, params, observed, t);
    match op {
        // ------------------------------------------------------------------
        // Leaf scalar algebra — routed through the ONE shared kernel that also
        // backs the array runtime's per-cell oracle and vectorized overlay
        // (`apply_binary` / `apply_unary` / `fold_scalar`, in `simulate_array`).
        // Defining each operator's numeric meaning once makes the scalar and
        // array paths impossible to diverge (knot #3a) — the past oracle/overlay
        // and interpreter divergences (e.g. the `==` EPSILON bug) lived exactly
        // in this hand-duplicated block.
        // ------------------------------------------------------------------

        // n-ary arithmetic + min/max: left-fold via `fold_scalar` (the same fold
        // the array oracle uses). `fold_scalar` returns NaN for an empty fold;
        // the `op_registry` gate makes that arity unreachable here, but preserve
        // simulate.rs's historical fold identity for it regardless.
        "+" | "*" | "min" | "max" => {
            let vs: Vec<f64> = args
                .iter()
                .map(|a| interpret(a, state, params, observed, t))
                .collect();
            if vs.is_empty() {
                match op {
                    "+" => 0.0,
                    "*" => 1.0,
                    "min" => f64::INFINITY,
                    "max" => f64::NEG_INFINITY,
                    _ => f64::NAN,
                }
            } else {
                fold_scalar(op, &vs)
            }
        }

        // `-` is unary negate (arity 1) or binary subtract (arity 2). Only the
        // binary case has a leaf-kernel entry; unary negation is trivial and has
        // no shared `f64` kernel (the array path negates at the `Value` level).
        // Unary negation is a sign flip: exact in every binary format, so it
        // needs no rounding under Float32 (its operand already is binary32).
        "-" => match args.len() {
            1 => -v(0),
            2 => apply_binary("-", v(0), v(1)),
            _ => f64::NAN,
        },

        // The canonical unary negation `canonicalize.rs` emits — the same sign
        // flip as the unary `-` above, and the same primitive the array
        // evaluator routes `neg` through, so the two agree by construction.
        "neg" => -v(0),

        // The nullary boolean literal (esm-spec §4.2). This interpreter's
        // boolean convention is 1.0 / 0.0 — every comparison and `and`/`or`/
        // `not` above produces it — so the value is forced, not chosen, and it
        // is what the array evaluator, Python (`numpy_interpreter`), Julia and
        // Go all already produce for the same node.
        "true" => 1.0,

        // Strictly-binary arithmetic + comparisons + logicals, all via the shared
        // `apply_binary`. Comparisons route through `scalar_compare` internally,
        // so `==`/`!=` stay EXACT equality (`a == b`) — the pinned cross-binding
        // semantic — and never the old absolute-EPSILON tolerance. Orderings and
        // `and`/`or` return a strict 1.0/0.0 flag.
        "/" | "^" | "atan2" | "<" | ">" | "<=" | ">=" | "==" | "!=" | "and" | "or" => {
            apply_binary(op, v(0), v(1))
        }

        // Unary transcendentals / trig / rounding / `sign` / `abs` / `not`, via the
        // shared `apply_unary` (mathematical `sign(0) = 0`, `not` on the 0/≠0
        // flag, etc. — one definition shared with the array path).
        "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil" | "sin"
        | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh" | "asinh"
        | "acosh" | "atanh" | "not" => apply_unary(op, v(0)),

        // conditional (not a leaf-kernel op): evaluate the predicate, then only
        // the taken branch.
        "ifelse" => {
            if v(0) != 0.0 {
                v(1)
            } else {
                v(2)
            }
        }

        // Differential operator on a RIGHT-hand side. Unreachable, and the
        // sentinel says so.
        //
        // esm-spec §4.2: a right-hand-side structural `D` is resolved to the
        // named quantity's tendency by `flatten`'s phase 5b′
        // (`flatten::resolve_rhs_time_derivatives`), and one that resolves to
        // nothing is refused with `unlowered_operator` by
        // `flatten::first_unresolved_rhs_time_derivative`, which both compile
        // paths call before building. So no `D` reaches this arm.
        //
        // It used to return `0.0` "for legacy parity" with the two array
        // evaluators, which was a WRONG NUMBER graded green: three shipped
        // documents computed silent zeros through it, and §4.2 now says an
        // implementation MUST NOT invent a value here, in particular not `0`.
        // `NaN` is the crate's existing "undeterminable" sentinel and is the
        // one answer that cannot be mistaken for a result — an assertion over
        // it fails every finite expectation (the `assertion_nonfinite`
        // conformance category), where `0` silently PASSES `expected: 0`.
        "D" => f64::NAN,

        // Pre is the previous-value operator (used by event handling). With
        // events disallowed in v1 it should never appear, but if it does we
        // pass through the argument unchanged.
        "Pre" => v(0),

        // The spatial-calculus sugar ops (`grad`/`div`/`laplacian`/`curl`/`∇`/
        // `integral`), every other unregistered op, and the evaluable-core ops
        // this interpreter has no rule for (the array/tensor and geometry ops
        // and the build-time relational ops) are ALL refused before a
        // `ResolvedExpr::Op` carrying one can exist — from a DOCUMENT by
        // `resolve_expr` (the open tier via `op_registry::check_node`, the
        // evaluable-core remainder via `is_evaluable_op`), and from a CALLER by
        // `ResolvedExpr::op`, the sealed variant's only constructor outside
        // this crate. Reaching here therefore means the oracle and this `match`
        // have drifted, which is a bug in this crate and not in the document.
        //
        // This used to be `_ => f64::NAN`, which meant an ungated op came back
        // as a NUMBER: indistinguishable from a legitimate result, propagating
        // into the solution, and reported to the author as an assertion that
        // "expected 25, got NaN" rather than as the pipeline defect it is
        // (issue #220). The array evaluator's backstop is `unreachable!` for
        // exactly this reason; this one now matches it.
        _ => unreachable!(
            "scalar interpreter reached operator '{op}' with no evaluation rule — \
             `resolve_expr` and `ResolvedExpr::op` both gate on `is_evaluable_op()` \
             before building a `ResolvedExpr::Op`, so the two have drifted"
        ),
    }
}
