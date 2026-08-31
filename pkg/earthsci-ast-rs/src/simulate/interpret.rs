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
    match expr {
        ResolvedExpr::Number(n) => *n,
        ResolvedExpr::State(i) => state[*i],
        ResolvedExpr::Param(i) => params[*i],
        ResolvedExpr::Observed(i) => observed[*i],
        ResolvedExpr::Time => t,
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
/// each missing reference in encounter order. Math errors (division by zero,
/// log of a non-positive number, unknown ops) propagate as `f64::NAN` or
/// `±inf` in the `Ok` branch — that is the canonical runner's convention.
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
        "-" => match args.len() {
            1 => -v(0),
            2 => apply_binary("-", v(0), v(1)),
            _ => f64::NAN,
        },

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

        // Differential operator on RHS. `D` is a programming-form-only
        // marker on the LHS of state equations and is rewritten elsewhere;
        // if it shows up on the RHS we treat it as 0 (legacy parity).
        "D" => 0.0,

        // The spatial-calculus sugar ops (`grad`/`div`/`laplacian`/`curl`/`∇`/
        // `integral`) and every other unregistered op carry NO privileged
        // semantics: they are open-tier rewrite targets that a discretization
        // rule must lower to a stencil before evaluation, and their value is
        // UNDETERMINABLE until then (esm-spec §4.2). The normal pipeline rejects
        // them at compile time (`resolve_expr`); reaching this direct-evaluation
        // fallback with one still present yields `NaN` (undeterminable) via the
        // catch-all below — never a silent `0.0`, which would quietly poison a
        // trajectory.

        // Pre is the previous-value operator (used by event handling). With
        // events disallowed in v1 it should never appear, but if it does we
        // pass through the argument unchanged.
        "Pre" => v(0),

        _ => f64::NAN,
    }
}
