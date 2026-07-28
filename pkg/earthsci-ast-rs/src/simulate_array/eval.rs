//! The per-cell oracle interpreter: recursive [`Value`] evaluation of every
//! expression node (arithmetic, transcendentals, array ops, `aggregate`
//! contractions with ragged/derived bounds, geometry leaf ops) plus the
//! standalone [`eval_expression`] entry point. This path is the correctness
//! reference the vectorized overlay is verified against.

use super::*;
use crate::aggregate::effective_reduce_kind;
use crate::compile_error::CompileError;
use crate::types::ExpressionNode;

/// Stack-inlined per-axis `(lo, hi)` range list, the same rank≤4 argument
/// [`DimI`]/[`DimU`] rest on. Used where a range list is rebuilt on every RHS
/// evaluation ([`ArrayOpSpec`]), so it does not reach the allocator.
pub(super) type RangeVec = SmallVec<[(i64, i64); 4]>;

/// The extent of the derived index set produced by the FAQ node `from_faq`.
///
/// Two producers can size a `kind:"derived"` set, and they are consulted in the
/// order the Python reference (`numpy_interpreter._resolve_range_spec`) fixes:
///
/// 1. **Value invention** (RFC §6.1 / §5.5) — the build-time relational engine
///    enumerated a distinct member set and recorded its cardinality under the
///    producing aggregate's `id`. It runs once at setup, off the per-step hot
///    path, so the extent is constant for the whole run; this is what sizes an
///    ISRM emission axis (`emis_src_cells`, invented by the point-in-cell
///    overlap producer).
/// 2. **Geometry** (RFC §8.1) — the producing `intersect_polygon` clip stores
///    the **closed** ring (`n+1` rows, first vertex repeated so the
///    `polygon_area` shoelace can read the wrap edge as an ordinary
///    `index(ring, v+1, …)`), so the number of distinct vertices is `rows − 1`.
///
/// A producer materialized by NEITHER — an unevaluated clip, or an empty
/// (disjoint) one — yields `0`: an empty contraction reducing to the additive
/// identity 0̄, matching the evaluator's ghost-read convention. That leniency is
/// specific to a *contraction* bound, where an empty range is a well-defined
/// answer. A derived range that has to size an OUTPUT axis never reaches here:
/// it is resolved far earlier, and much more strictly, by
/// `crate::aggregate::resolve_index_set_ref`, which errors rather than invent a
/// zero-length axis.
pub(super) fn derived_extent(from_faq: &str, ctx: &EvalCtx) -> i64 {
    if let Some(&n) = ctx.derived_extents.get(from_faq) {
        return n;
    }
    match ctx.derived_rings.borrow().get(from_faq) {
        Some(ring) if ring.ndim() >= 1 => (ring.shape()[0] as i64 - 1).max(0),
        _ => 0,
    }
}

pub(super) fn eval(expr: &Expr, ctx: &mut EvalCtx) -> Value {
    match expr {
        Expr::Number(n) => Value::Scalar(*n),
        Expr::Integer(n) => Value::Scalar(*n as f64),
        Expr::Variable(name) => lookup_variable(name, ctx),
        Expr::Operator(node) => eval_op(node, ctx),
    }
}

pub(super) fn lookup_variable(name: &str, ctx: &EvalCtx) -> Value {
    if name == "t" {
        return Value::Scalar(ctx.t);
    }
    if let Some(v) = ctx.loop_binds.get(name) {
        return Value::Scalar(*v as f64);
    }
    if let Some(a) = ctx.state_arrays.get(name) {
        return if a.ndim() == 0 {
            Value::Scalar(a[IxDyn(&[])])
        } else {
            Value::Array(Box::new(a.clone()))
        };
    }
    if let Some(a) = ctx.observed_arrays.get(name) {
        return if a.ndim() == 0 {
            Value::Scalar(a[IxDyn(&[])])
        } else {
            Value::Array(Box::new(a.clone()))
        };
    }
    if let Some(i) = ctx.param_names.iter().position(|p| p == name) {
        return Value::Scalar(ctx.params[i]);
    }
    // External forcing channel (PR-1, ess-14f.7): a loader-fed field a driver
    // refreshed into the buffer. Checked *last* — after t, loop binds, state,
    // observed, and params — so it can only resolve a name that is otherwise
    // unbound (it would read NaN today). That makes the scalar-`p` path and
    // every existing model byte-identical: forcing only ever fills a gap, never
    // shadows a live binding. (When R-1 wires `cadence.rs` it can carry the set
    // of declared-loader-fed names and, if a name ever legitimately collides
    // with a state, promote this lookup for those names — the seam is here.)
    if let Some(a) = ctx.forcing.borrow().get(name) {
        return if a.ndim() == 0 {
            Value::Scalar(a[IxDyn(&[])])
        } else {
            Value::Array(Box::new(a.clone()))
        };
    }
    Value::Scalar(f64::NAN)
}

/// Bind (or rebind) a loop index in `binds` without reallocating the key on the
/// hot path. The output/contraction index names are fixed for a given
/// aggregate, so after the first cell every key already exists — `get_mut`
/// rebinds in place, avoiding the per-cell `String` clone that
/// `insert(name.clone(), …)` paid on every cell of every reduction.
#[inline]
pub(super) fn set_bind(binds: &mut IdxMap, name: &str, val: i64) {
    if let Some(slot) = binds.get_mut(name) {
        *slot = val;
    } else {
        binds.insert(name.to_string(), val);
    }
}

/// Does [`eval_op`] have an evaluation rule for `op`?
///
/// This is the single source of truth for the array interpreter's operator
/// coverage, and it is deliberately kept adjacent to [`eval_op`] so the two
/// cannot drift: every name listed here has a `match` arm below, and every arm
/// below is listed here.
///
/// It is NOT the same set as [`crate::op_registry::is_core_op`]. The registry
/// answers "may this op appear in a legal AST"; this answers "can the per-cell
/// evaluator produce a number for it". The gap between them is real and is
/// exactly what [`check_evaluable`] rejects:
///
/// * build-time query ops (`skolem`, `rank`, `distinct`, `argmin`, `argmax`) —
///   resolved by [`crate::value_invention`] before evaluation;
/// * form / lowering ops (`ic`, `true`, `enum`, `table_lookup`,
///   `apply_expression_template`) — consumed by their lowering passes;
/// * the open rewrite-target tier (`grad`, `div`, `laplacian`, a typo'd
///   `"expp"`, a user op) — must be lowered to a stencil first.
#[must_use]
pub fn is_evaluable_op(op: &str) -> bool {
    matches!(
        op,
        // Arithmetic.
        "+" | "-" | "*" | "/" | "^" | "neg"
        // Elementary functions.
        | "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil"
        | "sin" | "cos" | "tan" | "asin" | "acos" | "atan"
        | "sinh" | "cosh" | "tanh" | "asinh" | "acosh" | "atanh"
        | "atan2" | "min" | "max"
        // Comparisons and booleans.
        | "==" | "!=" | "<" | "<=" | ">" | ">=" | "and" | "or" | "not"
        | "ifelse"
        // Form ops with a defined runtime meaning here.
        | "D" | "Pre" | "const"
        // Array / geometry ops.
        | "index" | "aggregate" | "makearray" | "reshape" | "transpose" | "concat"
        | "broadcast" | "intersect_polygon" | "polygon_intersection_area"
        // Closed function registry.
        | "fn"
    )
}

/// Reject every operator in `expr` that the array interpreter cannot evaluate.
///
/// This is the RUNTIME operator gate, and it closes the last silent-NaN hole in
/// the evaluator. It layers two checks:
///
/// 1. [`check_no_spatial_ops`] (the shared [`crate::op_registry`] gate) — the
///    open rewrite-target tier (sugar ops, a spatial `D`, a user op, a typo) and
///    illegal arities.
/// 2. [`is_evaluable_op`] — evaluable-core ops that are legal in an AST but have
///    no rule in THIS evaluator because an earlier pipeline stage was supposed to
///    eliminate them.
///
/// Without this, a typo'd or unevaluable op reaching [`eval_op`] fell through to
/// a `NaN` sentinel, which is indistinguishable from a legitimate numerical
/// result and silently poisons the solution.
///
/// # Errors
///
/// [`CompileError::UnloweredOperatorError`], [`CompileError::InvalidOperatorArity`],
/// [`CompileError::MakearrayRegionInvalid`] (from the registry gate), or
/// [`CompileError::UnevaluableOperatorError`].
pub fn check_evaluable(expr: &Expr) -> Result<(), CompileError> {
    check_no_spatial_ops(expr)?;
    check_evaluable_ops(expr)
}

/// The [`is_evaluable_op`] half of [`check_evaluable`], applied over the whole
/// tree (including sidecar expression fields via `for_each_child`).
fn check_evaluable_ops(expr: &Expr) -> Result<(), CompileError> {
    let Expr::Operator(node) = expr else {
        return Ok(());
    };
    if !is_evaluable_op(&node.op) {
        return Err(CompileError::UnevaluableOperatorError {
            op: node.op.clone(),
        });
    }
    let mut first_err: Option<CompileError> = None;
    node.for_each_child(&mut |child| {
        if first_err.is_none()
            && let Err(e) = check_evaluable_ops(child)
        {
            first_err = Some(e);
        }
    });
    match first_err {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

pub(super) fn eval_op(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    match node.op.as_str() {
        // Elementwise / scalar arithmetic. If any operand is an array,
        // return an array (with ndarray broadcasting).
        "+" | "-" | "*" | "/" | "^" => eval_arith(&node.op, &node.args, ctx),

        // Canonical unary negation: `canonicalize.rs` emits `neg`, so a
        // canonicalized expression can reach this oracle, and the vectorized
        // overlay already handles it (`vec_negate` / `affine_terms`). Route it
        // through `negate` — the same primitive the unary-minus arm of
        // `eval_arith` uses — so oracle and overlay agree. Unary only; a
        // non-unary `neg` is malformed ⇒ the NaN sentinel.
        "neg" => {
            if node.args.len() != 1 {
                return Value::Scalar(f64::NAN);
            }
            negate(eval(&node.args[0], ctx))
        }

        // Unary / scalar transcendentals.
        "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil" | "sin"
        | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh" | "asinh"
        | "acosh" | "atanh" => eval_unary(&node.op, &node.args, ctx),

        "atan2" => eval_binary(&node.op, &node.args, ctx),

        // n-ary min/max (esm-spec §4.2 — arity ≥ 2). Reuse the n-ary
        // arithmetic combiner so array operands broadcast through the same
        // ndarray path as `+`/`*`.
        "min" | "max" => eval_arith(&node.op, &node.args, ctx),

        // Comparison operators — return 1.0 (true) or 0.0 (false) via the same
        // [`scalar_compare`] kernel the vectorized overlay uses (bit-identity by
        // construction). BROADCAST when either operand is an array, so a per-cell
        // predicate like `code >= 1` over an [x,y] fuel grid yields an [x,y] mask
        // rather than collapsing to a scalar NaN.
        "==" | "!=" | "<" | "<=" | ">" | ">=" => {
            if node.args.len() != 2 {
                return Value::Scalar(f64::NAN);
            }
            eval_binary(&node.op, &node.args, ctx)
        }

        // Logical connectives (esm-spec §4.2): nonzero is true, the result is a
        // strict 1.0/0.0 flag, broadcast over array operands like arithmetic —
        // e.g. `and(code >= 1, code <= 13)` over an [x,y] fuel grid.
        "and" | "or" => eval_arith(&node.op, &node.args, ctx),
        "not" => eval_unary(&node.op, &node.args, ctx),

        "ifelse" => eval_ifelse(node, ctx),

        // Derivative operator: only meaningful on LHS. On RHS we treat
        // D(anything) = 0 for parity with the scalar interpreter.
        "D" => Value::Scalar(0.0),

        // `Pre` (previous-value marker) is only meaningful under event handling;
        // on the RHS it passes its argument through. Guard the arity so a
        // malformed `Pre` node from `eval_expression` yields the NaN sentinel
        // rather than panicking on `args[0]`.
        "Pre" => {
            if node.args.is_empty() {
                Value::Scalar(f64::NAN)
            } else {
                eval(&node.args[0], ctx)
            }
        }

        // Inline literal (esm-spec §4): a number → scalar; a nested numeric
        // array → a row-major array (e.g. a polygon's `[verts, 2]` lon/lat ring
        // held as a constant observed input feeding an `intersect_polygon` clip).
        "const" => eval_const(node),

        // Array ops.
        "index" => eval_index(node, ctx),
        "aggregate" => eval_arrayop(node, ctx),
        // Conservative-regridding geometry kernel (RFC §8.1): clip two lon/lat
        // polygon rings on the node's `manifold`, producing the overlap ring as
        // an `[N, 2]` array. `polygon_area` over it is an ordinary `aggregate`.
        "intersect_polygon" => eval_intersect_polygon(node, ctx),
        // Fused geometry leaf (esm-spec §4.2 / §8.6.1): the SCALAR overlap area of
        // the two polygon operands under the node's `manifold`, defined to equal
        // `polygon_area(intersect_polygon(a, b))` but with NO clip ring exposed.
        "polygon_intersection_area" => eval_polygon_intersection_area(node, ctx),
        "makearray" => eval_makearray(node, ctx),
        "reshape" => eval_reshape(node, ctx),
        "transpose" => eval_transpose(node, ctx),
        "concat" => eval_concat(node, ctx),
        "broadcast" => eval_broadcast(node, ctx),

        // Closed-registry function call (esm-spec §9.2): `datetime.*` calendar
        // accessors and `interp.linear` / `interp.bilinear` tensor
        // interpolation. Routes to the shared `registered_functions` kernel —
        // the same one the Julia/Python bindings use — so a coupled model whose
        // observeds compute fuel/table lookups via `fn` evaluates identically
        // here (the fire stack's `FuelModelLookup` is the motivating case).
        "fn" => eval_fn(node, ctx),

        // Unreachable by construction: EVERY path into this evaluator is gated.
        // The compiled-model path gates in `from_model` (`check_no_spatial_ops`),
        // and the public `eval_expression` gates with `check_evaluable`, which
        // additionally rejects evaluable-core ops with no arm here (`skolem`,
        // `rank`, `ic`, `table_lookup`, …).
        //
        // This used to be `_ => Value::Scalar(f64::NAN)`. A NaN sentinel is
        // indistinguishable from a legitimate numerical result, so a typo'd op
        // ("expp") or an op an earlier stage failed to eliminate produced a
        // silently poisoned solution instead of a diagnosable failure. Reaching
        // this arm now means a gate was bypassed — a bug in THIS crate — so it
        // fails loudly rather than corrupting the answer.
        other => unreachable!(
            "operator '{other}' reached eval_op without an evaluation rule; \
             every entry point must gate with check_evaluable() first"
        ),
    }
}

/// Evaluate a `fn` op: a call into the closed function registry
/// (esm-spec §9.2 / [`crate::registered_functions`]). Each argument is
/// evaluated to a runtime [`Value`] and coerced to a [`ClosedArg`] — a scalar
/// (or 0-D array) to `Scalar`, a 1-D array to `Array`, a 2-D array to
/// `Array2D`. The result is lifted back to `f64`. A missing `name`, an
/// unsupported argument rank (≥ 3), or a registry error (unknown function,
/// arity/shape mismatch, non-monotonic axis) surfaces as the NaN sentinel —
/// the same runtime-error convention every other op in this interpreter uses
/// (the solver detects NaN as a step failure).
pub(super) fn eval_fn(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    use crate::registered_functions::{ClosedArg, evaluate_closed_function};

    let Some(name) = node.name.as_deref() else {
        return Value::Scalar(f64::NAN);
    };
    let vals: ValVec = node.args.iter().map(|a| eval(a, ctx)).collect();

    // Broadcast the 1-D interpolation kernel over an ARRAY query: the table +
    // axis (args 0,1) stay fixed as the lookup table, only the query point
    // (arg 2) varies per cell, so `interp.linear(y, x, code)` over an [x,y] fuel
    // grid returns that same [x,y] shape. (`interp.bilinear`'s queries are 2-D
    // corner blends — they are not array-broadcast here.)
    if name == "interp.linear"
        && vals.len() == 3
        && let Value::Array(q) = &vals[2]
    {
        let table: Vec<f64> = value_flat(&vals[0]);
        let axis: Vec<f64> = value_flat(&vals[1]);
        let out = q.mapv(|x| {
            let call = [
                ClosedArg::Array(table.clone()),
                ClosedArg::Array(axis.clone()),
                ClosedArg::Scalar(x),
            ];
            evaluate_closed_function("interp.linear", &call)
                .map(|v| v.as_f64())
                .unwrap_or(f64::NAN)
        });
        return Value::Array(Box::new(out));
    }

    let mut args: Vec<ClosedArg> = Vec::with_capacity(vals.len());
    for v in vals {
        let arg = match v {
            Value::Scalar(s) => ClosedArg::Scalar(s),
            Value::Array(arr) => match arr.ndim() {
                0 => ClosedArg::Scalar(arr[IxDyn(&[])]),
                1 => ClosedArg::Array(arr.iter().copied().collect()),
                2 => {
                    let (rows, cols) = (arr.shape()[0], arr.shape()[1]);
                    let mut out = Vec::with_capacity(rows);
                    for i in 0..rows {
                        let mut row = Vec::with_capacity(cols);
                        for j in 0..cols {
                            row.push(arr[IxDyn(&[i, j])]);
                        }
                        out.push(row);
                    }
                    ClosedArg::Array2D(out)
                }
                _ => return Value::Scalar(f64::NAN),
            },
        };
        args.push(arg);
    }
    match evaluate_closed_function(name, &args) {
        Ok(v) => Value::Scalar(v.as_f64()),
        Err(_) => Value::Scalar(f64::NAN),
    }
}

pub(super) fn eval_arith(op: &str, args: &[Expr], ctx: &mut EvalCtx) -> Value {
    // Stack-inlined operand buffer (arity ≤ 4 in practice) — no per-node heap
    // allocation in the hot per-cell loop.
    let mut values: ValVec = args.iter().map(|a| eval(a, ctx)).collect();

    // Unary minus: 1 arg.
    if op == "-" && values.len() == 1 {
        return negate(values.remove(0));
    }

    // Scalar fast path — if all operands are scalars, compute scalar.
    if values.iter().all(|v| matches!(v, Value::Scalar(_))) {
        let scalars: SmallVec<[f64; 4]> = values
            .iter()
            .map(|v| match v {
                Value::Scalar(s) => *s,
                // The `values.iter().all(matches Scalar)` guard just above proves
                // every operand here is a `Scalar`; a non-scalar is impossible.
                _ => unreachable!(
                    "eval_arith scalar fast path: operand proven Scalar by the all-scalar guard"
                ),
            })
            .collect();
        return Value::Scalar(fold_scalar(op, &scalars));
    }

    // Array path: reduce left-to-right with broadcasting.
    let mut acc = values.remove(0);
    for v in values {
        acc = combine(op, acc, v);
    }
    acc
}

/// The all-scalar fast path of [`eval_arith`].
///
/// **This function and [`apply_binary`] must compute the same value for every
/// LEGAL node** — that is the whole contract between the per-cell oracle and the
/// vectorized overlay, and it is pinned by the
/// `vectorized_matches_per_cell_oracle` equivalence test.
///
/// It did not used to hold. This function special-cased arity — returning `NaN`
/// for `-`/`/`/`^` unless `len == 2`, and for `min`/`max` unless `len >= 2` —
/// while the vectorized path left-folded *any* arity through `apply_binary`. So
/// `-(3,1,1)` was `NaN` here and `1.0` there; `min(5)` was `NaN` here and `5.0`
/// there. Worse, the oracle contradicted *itself*: the all-scalar guard in
/// `eval_arith` routed to this function, but a single *array* operand routed to
/// the left-folding `combine`, so `-(u,1,1)` meant `u-2` for an array `u` and
/// `NaN` for a scalar one.
///
/// Those arities are now rejected before evaluation by [`crate::op_registry`],
/// so the `NaN` special-cases are not merely unnecessary — they are unreachable,
/// and keeping them would only re-open the divergence if the gate were ever
/// bypassed. This is now a plain left-fold of [`apply_binary`], identical in
/// kernel and in order to the vectorized path.
pub(crate) fn fold_scalar(op: &str, vs: &[f64]) -> f64 {
    // A zero-arity arithmetic node is not legal (the registry rejects it); the
    // NaN sentinel is the module's convention for an unevaluable node.
    let Some((first, rest)) = vs.split_first() else {
        return f64::NAN;
    };
    // `and`/`or` are the one family whose n-ary fold is not a repeated binary
    // apply: they return a strict 1.0/0.0 flag over ALL operands, whereas
    // left-folding `apply_binary` would compare a raw operand against a flag.
    // `apply_binary` agrees with this for the legal arity (>= 2), which is what
    // the equivalence test checks.
    match op {
        "and" => return vs.iter().all(|&v| v != 0.0) as i32 as f64,
        "or" => return vs.iter().any(|&v| v != 0.0) as i32 as f64,
        _ => {}
    }
    rest.iter().fold(*first, |acc, &v| apply_binary(op, acc, v))
}

pub(super) fn negate(v: Value) -> Value {
    match v {
        Value::Scalar(s) => Value::Scalar(-s),
        Value::Array(a) => Value::Array(Box::new(a.mapv(|x| -x))),
    }
}

/// `ifelse(cond, a, b)`. A scalar `cond` picks a branch and returns it verbatim
/// (scalar OR array). An ARRAY `cond` SELECTS elementwise — `a`/`b` (scalar or
/// array) are broadcast to the common shape and chosen per cell — so a per-cell
/// fuel-model lookup `ifelse(and(code>=1, code<=13), interp.linear(...), default)`
/// materializes at `code`'s [x,y] shape instead of collapsing to a scalar. A
/// true select (not a `cond*a + (1-cond)*b` blend) keeps a `NaN` in the
/// *unchosen* branch — e.g. an out-of-table `interp.linear` — from contaminating
/// the result.
pub(super) fn eval_ifelse(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    if node.args.len() != 3 {
        return Value::Scalar(f64::NAN);
    }
    let cond = match eval(&node.args[0], ctx) {
        Value::Scalar(c) => {
            return if c != 0.0 {
                eval(&node.args[1], ctx)
            } else {
                eval(&node.args[2], ctx)
            };
        }
        Value::Array(c) => c,
    };
    let a = eval(&node.args[1], ctx);
    let b = eval(&node.args[2], ctx);
    let mut target = cond.shape().to_vec();
    if let Value::Array(aa) = &a {
        target = broadcast_shape(&target, aa.shape());
    }
    if let Value::Array(bb) = &b {
        target = broadcast_shape(&target, bb.shape());
    }
    let cond_b = broadcast_value(&Value::Array(cond), &target);
    let a_b = broadcast_value(&a, &target);
    let b_b = broadcast_value(&b, &target);
    let mut out = ArrayD::<f64>::zeros(IxDyn(&target));
    ndarray::Zip::from(&mut out)
        .and(&cond_b)
        .and(&a_b)
        .and(&b_b)
        .for_each(|o, &c, &av, &bv| *o = if c != 0.0 { av } else { bv });
    Value::Array(Box::new(out))
}

/// Row-major flatten of a [`Value`] to a `Vec<f64>` (a scalar → one element) —
/// used to snapshot a fixed interpolation table/axis.
pub(super) fn value_flat(v: &Value) -> Vec<f64> {
    match v {
        Value::Scalar(s) => vec![*s],
        Value::Array(a) => a.iter().copied().collect(),
    }
}

/// Broadcast a [`Value`] to `target` shape: a scalar fills; an array is
/// trailing-padded (Julia alignment) then broadcast. An incompatible array
/// yields a `NaN` fill — the module's runtime-error convention.
pub(super) fn broadcast_value(v: &Value, target: &[usize]) -> ArrayD<f64> {
    match v {
        Value::Scalar(s) => ArrayD::<f64>::from_elem(IxDyn(target), *s),
        Value::Array(a) => match pad_trailing(a, target.len()).broadcast(IxDyn(target)) {
            Some(b) => b.to_owned(),
            None => ArrayD::<f64>::from_elem(IxDyn(target), f64::NAN),
        },
    }
}

pub(super) fn combine(op: &str, a: Value, b: Value) -> Value {
    match (a, b) {
        (Value::Scalar(x), Value::Scalar(y)) => Value::Scalar(apply_binary(op, x, y)),
        (Value::Scalar(x), Value::Array(ya)) => {
            Value::Array(Box::new(ya.mapv(|y| apply_binary(op, x, y))))
        }
        (Value::Array(xa), Value::Scalar(y)) => {
            Value::Array(Box::new(xa.mapv(|x| apply_binary(op, x, y))))
        }
        (Value::Array(xa), Value::Array(ya)) => {
            // Use ndarray broadcasting.
            Value::Array(Box::new(broadcast_binary(op, &xa, &ya)))
        }
    }
}

pub(crate) fn apply_binary(op: &str, x: f64, y: f64) -> f64 {
    match op {
        "+" => x + y,
        "-" => x - y,
        "*" => x * y,
        "/" => x / y,
        "^" => x.powf(y),
        "atan2" => x.atan2(y),
        "min" => x.min(y),
        "max" => x.max(y),
        // Comparison + logical kernels, so the broadcast paths (`combine` /
        // `broadcast_binary`) carry array operands elementwise.
        "==" | "!=" | "<" | "<=" | ">" | ">=" => scalar_compare(op, x, y),
        "and" => (x != 0.0 && y != 0.0) as i32 as f64,
        "or" => (x != 0.0 || y != 0.0) as i32 as f64,
        _ => f64::NAN,
    }
}

/// [`apply_binary`]'s per-element arithmetic with the **op-name lookup lifted
/// out**: resolve the name once, then call the returned kernel per element.
///
/// The per-cell oracle calls `apply_binary(op, x, y)` once per cell, so the
/// `match op` costs one string dispatch per element either way. The whole-array
/// overlay ran the *same* call inside an N-element `ndarray::Zip`, so every
/// element of every kernel node re-matched the operator name — `apply_binary`
/// plus `__memcmp_evex` were 14% of a vectorized RHS profile, and the string
/// compare also blocked the loop from vectorizing. Hoisting the lookup to once
/// per AST node leaves an inlinable `f64`-only body in the loop.
///
/// The arms are the arms of [`apply_binary`], in the same order, evaluating the
/// same expressions — `binary_kernels_match_apply_binary` pins the two to raw
/// IEEE bit equality over every op name and a spread of operands (±0, ±inf,
/// NaN, subnormals), so a divergence is a test failure, not a silent one.
pub(crate) fn binary_kernel(op: &str) -> fn(f64, f64) -> f64 {
    binary_kernel_of(BinCode::of(op))
}

/// A binary/elementwise operator resolved to a compact code.
///
/// The overlay used to carry the operator around as a `&str` and re-match the
/// NAME at every dispatch point: once in `eval_vec_op`, again in `vec_combine`,
/// and a third time inside [`binary_kernel`] — and the comparison arms matched a
/// FOURTH time, per element, inside `scalar_compare`. A perf profile of the
/// solve attributed ~2.5% to that (`__memcmp_evex_movbe` plus the inlined
/// `str PartialEq::eq` chain under `eval_vec_op`). Resolving the name ONCE per
/// AST node into this code and dispatching on the code afterwards removes every
/// downstream string compare.
///
/// [`BinCode::Unknown`] is the "not a binary kernel" code; its kernel is the NaN
/// sentinel, matching `apply_binary`'s catch-all arm.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum BinCode {
    Add,
    Sub,
    Mul,
    Div,
    Pow,
    Atan2,
    Min,
    Max,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    And,
    Or,
    Unknown,
}

impl BinCode {
    /// Resolve an operator name. The arms are exactly [`apply_binary`]'s.
    pub(crate) fn of(op: &str) -> BinCode {
        match op {
            "+" => BinCode::Add,
            "-" => BinCode::Sub,
            "*" => BinCode::Mul,
            "/" => BinCode::Div,
            "^" => BinCode::Pow,
            "atan2" => BinCode::Atan2,
            "min" => BinCode::Min,
            "max" => BinCode::Max,
            "==" => BinCode::Eq,
            "!=" => BinCode::Ne,
            "<" => BinCode::Lt,
            "<=" => BinCode::Le,
            ">" => BinCode::Gt,
            ">=" => BinCode::Ge,
            "and" => BinCode::And,
            "or" => BinCode::Or,
            _ => BinCode::Unknown,
        }
    }
}

/// [`binary_kernel`] with the name already resolved to a [`BinCode`].
///
/// The comparison arms inline the relop rather than calling `scalar_compare(op,
/// …)` — which would re-match the operator NAME once per element — but compute
/// the identical value: `scalar_compare` is itself `if a <relop> b { 1.0 } else
/// { 0.0 }`. `binary_kernel` delegates here, so
/// `binary_kernels_match_apply_binary` pins this table to `apply_binary` bit for
/// bit over every op name and a spread of operands.
pub(crate) fn binary_kernel_of(op: BinCode) -> fn(f64, f64) -> f64 {
    match op {
        BinCode::Add => |x, y| x + y,
        BinCode::Sub => |x, y| x - y,
        BinCode::Mul => |x, y| x * y,
        BinCode::Div => |x, y| x / y,
        BinCode::Pow => |x: f64, y: f64| x.powf(y),
        BinCode::Atan2 => |x: f64, y: f64| x.atan2(y),
        BinCode::Min => |x: f64, y: f64| x.min(y),
        BinCode::Max => |x: f64, y: f64| x.max(y),
        BinCode::Eq => |x: f64, y: f64| (x == y) as i32 as f64,
        BinCode::Ne => |x: f64, y: f64| (x != y) as i32 as f64,
        BinCode::Lt => |x: f64, y: f64| (x < y) as i32 as f64,
        BinCode::Le => |x: f64, y: f64| (x <= y) as i32 as f64,
        BinCode::Gt => |x: f64, y: f64| (x > y) as i32 as f64,
        BinCode::Ge => |x: f64, y: f64| (x >= y) as i32 as f64,
        BinCode::And => |x: f64, y: f64| (x != 0.0 && y != 0.0) as i32 as f64,
        BinCode::Or => |x: f64, y: f64| (x != 0.0 || y != 0.0) as i32 as f64,
        BinCode::Unknown => |_, _| f64::NAN,
    }
}

pub(super) fn broadcast_binary(op: &str, a: &ArrayD<f64>, b: &ArrayD<f64>) -> ArrayD<f64> {
    // Julia-style left-align: pad the lower-rank operand with trailing
    // singletons before broadcasting.
    let max_rank = a.ndim().max(b.ndim());
    let a_padded = pad_trailing(a, max_rank);
    let b_padded = pad_trailing(b, max_rank);
    let target_shape = broadcast_shape(a_padded.shape(), b_padded.shape());
    // Incompatible operand shapes come from user model data
    // (`broadcast_shape` marks the clashing dimension with extent 0). Follow
    // the module's runtime convention for unevaluable nodes — a NaN sentinel
    // the solver treats as step failure — rather than panicking.
    let (Some(av), Some(bv)) = (
        a_padded.broadcast(IxDyn(&target_shape)),
        b_padded.broadcast(IxDyn(&target_shape)),
    ) else {
        let nan_shape: Vec<usize> = target_shape.iter().map(|&d| d.max(1)).collect();
        return ArrayD::<f64>::from_elem(IxDyn(&nan_shape), f64::NAN);
    };
    let mut out = ArrayD::<f64>::zeros(IxDyn(&target_shape));
    ndarray::Zip::from(&mut out)
        .and(&av)
        .and(&bv)
        .for_each(|o, &x, &y| {
            *o = apply_binary(op, x, y);
        });
    out
}

/// Julia-style broadcast shape alignment: pad the lower-rank shape with
/// *trailing* singleton dimensions so `(3,) + (1,3) → (3,3)`. This differs
/// from NumPy's right-alignment convention; the fixtures were authored in
/// Julia and expect this behavior (see
/// `fixtures/arrayop/14_broadcast_elementwise.esm`).
pub(super) fn broadcast_shape(a: &[usize], b: &[usize]) -> Vec<usize> {
    let n = a.len().max(b.len());
    let mut out = vec![1usize; n];
    for i in 0..n {
        let ai = if i < a.len() { a[i] } else { 1 };
        let bi = if i < b.len() { b[i] } else { 1 };
        let dim = if ai == bi {
            ai
        } else if ai == 1 {
            bi
        } else if bi == 1 {
            ai
        } else {
            0
        };
        out[i] = dim;
    }
    out
}

/// Pad an ndarray with trailing singleton dimensions to reach `target_rank`.
pub(super) fn pad_trailing(arr: &ArrayD<f64>, target_rank: usize) -> ArrayD<f64> {
    if arr.ndim() >= target_rank {
        return arr.clone();
    }
    let mut shape = arr.shape().to_vec();
    while shape.len() < target_rank {
        shape.push(1);
    }
    arr.clone()
        .into_shape_with_order(IxDyn(&shape))
        .expect("pad_trailing reshape")
}

pub(super) fn eval_unary(op: &str, args: &[Expr], ctx: &mut EvalCtx) -> Value {
    // A malformed unary node (no operand) from the public `eval_expression`
    // surfaces the NaN sentinel rather than panicking on `args[0]`.
    let Some(arg0) = args.first() else {
        return Value::Scalar(f64::NAN);
    };
    let v = eval(arg0, ctx);
    match v {
        Value::Scalar(s) => Value::Scalar(apply_unary(op, s)),
        Value::Array(a) => Value::Array(Box::new(a.mapv(|x| apply_unary(op, x)))),
    }
}

pub(crate) fn apply_unary(op: &str, x: f64) -> f64 {
    match op {
        "exp" => x.exp(),
        "log" | "ln" => x.ln(),
        "log10" => x.log10(),
        "sqrt" => x.sqrt(),
        "abs" => x.abs(),
        "sign" => {
            if x > 0.0 {
                1.0
            } else if x < 0.0 {
                -1.0
            } else {
                0.0
            }
        }
        "floor" => x.floor(),
        "ceil" => x.ceil(),
        "sin" => x.sin(),
        "cos" => x.cos(),
        "tan" => x.tan(),
        "asin" => x.asin(),
        "acos" => x.acos(),
        "atan" => x.atan(),
        "sinh" => x.sinh(),
        "cosh" => x.cosh(),
        "tanh" => x.tanh(),
        "asinh" => x.asinh(),
        "acosh" => x.acosh(),
        "atanh" => x.atanh(),
        "not" => (x == 0.0) as i32 as f64,
        _ => f64::NAN,
    }
}

/// [`apply_unary`]'s per-element map with the op-name lookup lifted out — the
/// unary counterpart of [`binary_kernel`], for the same reason (the whole-array
/// overlay applied it inside an N-element loop). Arms mirror [`apply_unary`]
/// exactly; `unary_kernels_match_apply_unary` pins them to bit equality.
pub(crate) fn unary_kernel(op: &str) -> fn(f64) -> f64 {
    unary_kernel_of(UnCode::of(op))
}

/// A unary operator resolved to a compact code — the counterpart of
/// [`BinCode`], for the same reason (see its docs).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum UnCode {
    Exp,
    Ln,
    Log10,
    Sqrt,
    Abs,
    Sign,
    Floor,
    Ceil,
    Sin,
    Cos,
    Tan,
    Asin,
    Acos,
    Atan,
    Sinh,
    Cosh,
    Tanh,
    Asinh,
    Acosh,
    Atanh,
    Not,
    Unknown,
}

impl UnCode {
    /// Resolve an operator name. The arms are exactly [`apply_unary`]'s
    /// (including the `log`/`ln` alias).
    pub(crate) fn of(op: &str) -> UnCode {
        match op {
            "exp" => UnCode::Exp,
            "log" | "ln" => UnCode::Ln,
            "log10" => UnCode::Log10,
            "sqrt" => UnCode::Sqrt,
            "abs" => UnCode::Abs,
            "sign" => UnCode::Sign,
            "floor" => UnCode::Floor,
            "ceil" => UnCode::Ceil,
            "sin" => UnCode::Sin,
            "cos" => UnCode::Cos,
            "tan" => UnCode::Tan,
            "asin" => UnCode::Asin,
            "acos" => UnCode::Acos,
            "atan" => UnCode::Atan,
            "sinh" => UnCode::Sinh,
            "cosh" => UnCode::Cosh,
            "tanh" => UnCode::Tanh,
            "asinh" => UnCode::Asinh,
            "acosh" => UnCode::Acosh,
            "atanh" => UnCode::Atanh,
            "not" => UnCode::Not,
            _ => UnCode::Unknown,
        }
    }
}

/// [`unary_kernel`] with the name already resolved to a [`UnCode`]. Arms mirror
/// [`apply_unary`] exactly; `unary_kernels_match_apply_unary` pins them to bit
/// equality through [`unary_kernel`], which delegates here.
pub(crate) fn unary_kernel_of(op: UnCode) -> fn(f64) -> f64 {
    match op {
        UnCode::Exp => |x: f64| x.exp(),
        UnCode::Ln => |x: f64| x.ln(),
        UnCode::Log10 => |x: f64| x.log10(),
        UnCode::Sqrt => |x: f64| x.sqrt(),
        UnCode::Abs => |x: f64| x.abs(),
        UnCode::Sign => |x: f64| {
            if x > 0.0 {
                1.0
            } else if x < 0.0 {
                -1.0
            } else {
                0.0
            }
        },
        UnCode::Floor => |x: f64| x.floor(),
        UnCode::Ceil => |x: f64| x.ceil(),
        UnCode::Sin => |x: f64| x.sin(),
        UnCode::Cos => |x: f64| x.cos(),
        UnCode::Tan => |x: f64| x.tan(),
        UnCode::Asin => |x: f64| x.asin(),
        UnCode::Acos => |x: f64| x.acos(),
        UnCode::Atan => |x: f64| x.atan(),
        UnCode::Sinh => |x: f64| x.sinh(),
        UnCode::Cosh => |x: f64| x.cosh(),
        UnCode::Tanh => |x: f64| x.tanh(),
        UnCode::Asinh => |x: f64| x.asinh(),
        UnCode::Acosh => |x: f64| x.acosh(),
        UnCode::Atanh => |x: f64| x.atanh(),
        UnCode::Not => |x: f64| (x == 0.0) as i32 as f64,
        UnCode::Unknown => |_| f64::NAN,
    }
}

#[cfg(test)]
mod kernel_equivalence_tests {
    //! The whole-array overlay resolves an operator name to a kernel ONCE per
    //! AST node ([`binary_kernel`]/[`unary_kernel`]) where the per-cell oracle
    //! re-matches it per element ([`apply_binary`]/[`apply_unary`]). The two
    //! paths must stay bit-identical, so pin them here rather than trusting two
    //! hand-kept copies of the same match to drift together.
    use super::*;

    /// Operand spread: signed zeros, subnormals, ±inf and NaN, so a divergence
    /// in a branchy arm (`min`/`max`/`sign`/the comparisons) cannot hide.
    const XS: &[f64] = &[
        0.0,
        -0.0,
        1.0,
        -1.0,
        0.5,
        -3.25,
        2.0,
        f64::MIN_POSITIVE,
        5e-324,
        1e300,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NAN,
    ];

    #[rustfmt::skip]
    const BIN_OPS: &[&str] = &[
        "+", "-", "*", "/", "^", "atan2", "min", "max",
        "==", "!=", "<", "<=", ">", ">=", "and", "or", "no_such_op",
    ];

    #[rustfmt::skip]
    const UN_OPS: &[&str] = &[
        "exp", "log", "ln", "log10", "sqrt", "abs", "sign", "floor", "ceil", "sin", "cos",
        "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
        "not", "no_such_op",
    ];

    #[test]
    fn binary_kernels_match_apply_binary() {
        for op in BIN_OPS {
            let k = binary_kernel(op);
            for &x in XS {
                for &y in XS {
                    let a = apply_binary(op, x, y);
                    let b = k(x, y);
                    assert_eq!(
                        a.to_bits(),
                        b.to_bits(),
                        "binary_kernel(\"{op}\")({x}, {y}) = {b} != apply_binary = {a}"
                    );
                }
            }
        }
    }

    #[test]
    fn unary_kernels_match_apply_unary() {
        for op in UN_OPS {
            let k = unary_kernel(op);
            for &x in XS {
                let a = apply_unary(op, x);
                let b = k(x);
                assert_eq!(
                    a.to_bits(),
                    b.to_bits(),
                    "unary_kernel(\"{op}\")({x}) = {b} != apply_unary = {a}"
                );
            }
        }
    }
}

/// Evaluate a strictly-binary op (`atan2`, the comparisons).
///
/// The arity guard is not decoration: this function used to index `args[0]` and
/// `args[1]` unconditionally, so `{"op":"atan2","args":[1.0]}` — a
/// *schema-valid* document, since the schema puts no lower bound on `args` —
/// **panicked** with an index-out-of-bounds. [`crate::op_registry`] now rejects
/// that node at the compile gate, but `eval_expression` is a public entry point
/// that bypasses the gate, so the guard stays as the backstop that makes a panic
/// unreachable rather than merely unlikely.
pub(super) fn eval_binary(op: &str, args: &[Expr], ctx: &mut EvalCtx) -> Value {
    let ([a_expr, b_expr] | [a_expr, b_expr, ..]) = args else {
        return Value::Scalar(f64::NAN);
    };
    let a = eval(a_expr, ctx);
    let b = eval(b_expr, ctx);
    combine(op, a, b)
}

// --- Array ops ---

/// Borrow a state/observed variable's whole ARRAY by reference, mirroring
/// [`lookup_variable`]'s precedence (`t` → loop binds → state → observed) but
/// without cloning. Returns `None` when the name would resolve to a scalar
/// (0-D array, loop index, `t`), a param, or a forcing entry — those keep the
/// original clone/scalar path. Lets [`eval_index`] sample one element of a big
/// stencil/geometry-table array without cloning the entire array per cell.
pub(super) fn lookup_array_ref<'a>(name: &str, ctx: &'a EvalCtx) -> Option<&'a ArrayD<f64>> {
    if name == "t" || ctx.loop_binds.contains_key(name) {
        return None;
    }
    if let Some(a) = ctx.state_arrays.get(name) {
        return if a.ndim() == 0 { None } else { Some(a) };
    }
    if let Some(a) = ctx.observed_arrays.get(name) {
        return if a.ndim() == 0 { None } else { Some(a) };
    }
    // Params (scalars) and forcing (a `RefCell` — no plain `&` to hand back)
    // fall through to the normal evaluate-then-index path.
    None
}

/// Sample `arr` at the 1-based `raw` indices (out-of-bounds ⇒ 0.0, homogeneous
/// Dirichlet ghost cells; fewer indices than the rank ⇒ a fixed-leading-axes
/// sub-array). `in_bounds` seeds the bound flag (`false` if an index expression
/// was non-scalar). Shared by the borrowing fast path and the general path.
pub(super) fn index_into(arr: &ArrayD<f64>, raw: &[i64], mut in_bounds: bool) -> Value {
    // Stack-inlined index buffer (array rank ≤ 4) — no per-node heap allocation.
    let mut indices: DimU = SmallVec::with_capacity(raw.len());
    for (d, &one_based) in raw.iter().enumerate() {
        let dim_size = arr.shape().get(d).copied().unwrap_or(0) as i64;
        if one_based < 1 || one_based > dim_size {
            in_bounds = false;
        }
        indices.push((one_based - 1).max(0) as usize);
    }
    if !in_bounds {
        return Value::Scalar(0.0);
    }
    if indices.len() > arr.ndim() {
        return Value::Scalar(f64::NAN);
    }
    // Partial indexing (fewer indices than the array rank) selects a sub-array:
    // fix the leading `indices.len()` axes and keep the trailing axes free. This
    // is how a per-cell polygon ring is drawn from a `[cells, verts, coord]`
    // geometry table — `index(poly, a)` yields the `a`-th `[verts, coord]` ring
    // that `polygon_intersection_area` / `intersect_polygon` clip. A full index
    // set (`indices.len() == ndim`) yields the scalar element, as before.
    if indices.len() < arr.ndim() {
        let mut view = arr.view();
        for &ix in &indices {
            view = view.index_axis_move(ndarray::Axis(0), ix);
        }
        return Value::Array(Box::new(view.to_owned()));
    }
    match arr.get(IxDyn(&indices)) {
        Some(v) => Value::Scalar(*v),
        None => Value::Scalar(0.0),
    }
}

/// Evaluate the index expressions (args[1..]) into 1-based `i64` indices,
/// flagging `in_bounds = false` for any non-scalar operand (contributes a 0
/// ghost). Kept separate so both `eval_index` paths share identical semantics.
#[inline]
fn eval_index_args(args: &[Expr], ctx: &mut EvalCtx) -> (DimI, bool) {
    let mut raw: DimI = SmallVec::with_capacity(args.len());
    let mut in_bounds = true;
    for a in args {
        match eval(a, ctx).as_scalar() {
            Some(f) => raw.push(f.round() as i64),
            None => {
                in_bounds = false;
                raw.push(0);
            }
        }
    }
    (raw, in_bounds)
}

pub(super) fn eval_index(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // First arg is the array-valued expression; remaining args are indices.
    if node.args.is_empty() {
        return Value::Scalar(f64::NAN);
    }
    // Fast path: `index(<var>, i, j, …)` where `<var>` names a state/observed
    // ARRAY. Borrow it and read the one element directly, rather than cloning
    // the whole array (via `lookup_variable`) just to sample a single cell —
    // the dominant per-cell stencil / geometry-table access. Index expressions
    // are evaluated first (they never depend on the indexed array), so the
    // borrow is taken only after `&mut ctx` is no longer needed.
    // `index` needs at least the array operand (`args[0]`); the registry rejects
    // a nullary `index`, and this guard keeps the public `eval_expression`
    // bypass from panicking on one.
    if node.args.is_empty() {
        return Value::Scalar(f64::NAN);
    }
    if let Expr::Variable(name) = &node.args[0]
        && lookup_array_ref(name, ctx).is_some()
    {
        let (raw, in_bounds) = eval_index_args(&node.args[1..], ctx);
        if let Some(arr) = lookup_array_ref(name, ctx) {
            return index_into(arr, &raw, in_bounds);
        }
    }
    let array_val = eval(&node.args[0], ctx);
    let arr = match array_val {
        Value::Array(a) => a,
        Value::Scalar(s) if node.args.len() == 1 => return Value::Scalar(s),
        Value::Scalar(_) => return Value::Scalar(f64::NAN),
    };
    // Out-of-bounds accesses return 0.0 — homogeneous Dirichlet ghost-cell
    // semantics: a discretized PDE's stencil can reference u[i-1] when i=1
    // (ghost cell at i=0) and the boundary condition is u=0.
    let (raw, in_bounds) = eval_index_args(&node.args[1..], ctx);
    index_into(&arr, &raw, in_bounds)
}

/// Evaluate a `const` op: the inline literal in the node's `value` field. A JSON
/// number yields a [`Value::Scalar`]; a nested numeric array yields a row-major
/// [`Value::Array`]. A missing, ragged, or non-numeric literal is unevaluable
/// (NaN sentinel), matching the evaluator's convention for malformed nodes.
pub(super) fn eval_const(node: &ExpressionNode) -> Value {
    node.value
        .as_ref()
        .and_then(json_to_value)
        .unwrap_or(Value::Scalar(f64::NAN))
}

/// Convert an inline JSON literal to a runtime [`Value`]: a number → scalar; a
/// (possibly nested) numeric array → a row-major dynamic-rank array. `None` for
/// a non-numeric leaf or a ragged literal (a row whose length disagrees with its
/// siblings), so a malformed `const` surfaces as the NaN sentinel.
pub(super) fn json_to_value(v: &serde_json::Value) -> Option<Value> {
    use serde_json::Value as J;
    match v {
        J::Number(n) => Some(Value::Scalar(n.as_f64()?)),
        J::Array(_) => {
            let mut shape: Vec<usize> = Vec::new();
            let mut flat: Vec<f64> = Vec::new();
            collect_json_array(v, 0, &mut shape, &mut flat)?;
            ArrayD::from_shape_vec(IxDyn(&shape), flat)
                .ok()
                .map(|a| Value::Array(Box::new(a)))
        }
        _ => None,
    }
}

/// Walk a nested JSON numeric array, recording its shape (from the first branch
/// at each depth) and pushing every leaf number in row-major order. `None` on a
/// non-numeric leaf or a sub-array whose length disagrees with the recorded
/// shape at that depth (a ragged literal).
pub(super) fn collect_json_array(
    v: &serde_json::Value,
    depth: usize,
    shape: &mut Vec<usize>,
    flat: &mut Vec<f64>,
) -> Option<()> {
    use serde_json::Value as J;
    match v {
        J::Array(items) => {
            if depth == shape.len() {
                shape.push(items.len());
            } else if shape[depth] != items.len() {
                return None; // ragged: this row's length disagrees with its siblings
            }
            for item in items {
                collect_json_array(item, depth + 1, shape, flat)?;
            }
            Some(())
        }
        J::Number(n) => {
            flat.push(n.as_f64()?);
            Some(())
        }
        _ => None,
    }
}

/// Evaluate the `intersect_polygon` leaf op (RFC `semiring-faq-unified-ir` §8.1):
/// clip the two polygon operands on the node's declared `manifold` and return
/// the overlap ring as an `[N, 2]` array of `(lon, lat)` rows. `N` is
/// data-dependent; a disjoint / edge-touching clip yields a `[0, 2]` array.
/// Spherical/geodesic clips dispatch to `s2geometry` via [`crate::geometry`];
/// planar clips use a pure-Rust Sutherland–Hodgman intersection.
/// Validate and evaluate the shared operand contract of the two polygon-clip
/// leaf ops (§5.8.4): exactly two array operands that read as `[V, 2]`
/// lon/lat rings, plus a required in-enum `manifold` flag. `None` means "not
/// evaluable" — the caller returns the NaN sentinel.
pub(super) fn eval_clip_operands(
    node: &ExpressionNode,
    ctx: &mut EvalCtx,
) -> Option<(crate::geometry::Manifold, Vec<(f64, f64)>, Vec<(f64, f64)>)> {
    // Strict binary clip (schema-enforced; defense-in-depth here).
    if node.args.len() != 2 {
        return None;
    }
    // The `manifold` flag is required and part of the op's contract (§5.8.4);
    // a missing or out-of-enum value is not evaluable.
    let manifold = node
        .manifold
        .as_deref()
        .and_then(crate::geometry::Manifold::from_flag)?;
    // Both geometry leaves are binary (§4.3). Destructure rather than index, so
    // an under-applied node from the public `eval_expression` bypass is
    // un-evaluable (`None`) rather than a panic.
    let ([a_expr, b_expr] | [a_expr, b_expr, ..]) = node.args.as_slice() else {
        return None;
    };
    let poly_a = match eval(a_expr, ctx) {
        Value::Array(a) => a,
        _ => return None,
    };
    let poly_b = match eval(b_expr, ctx) {
        Value::Array(a) => a,
        _ => return None,
    };
    let va = arrayd_to_lonlat(&poly_a)?;
    let vb = arrayd_to_lonlat(&poly_b)?;
    Some((manifold, va, vb))
}

pub(super) fn eval_intersect_polygon(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let Some((manifold, va, vb)) = eval_clip_operands(node, ctx) else {
        return Value::Scalar(f64::NAN);
    };
    match crate::geometry::intersect_polygon(&va, &vb, manifold) {
        Ok(ring) => {
            // Return the ring **closed** (first vertex repeated) so the
            // `polygon_area` shoelace FAQ reads the wrap edge n→1 as an ordinary
            // `index(ring, v+1, …)` with no modular arithmetic in the AST —
            // matching the Python reference (`numpy_interpreter._eval_intersect_polygon`
            // → `geometry.close_ring`). The pure kernel `crate::geometry::intersect_polygon`
            // still returns the n distinct vertices; closure is the op's contract.
            let closed = close_ring(&ring);
            let arr = lonlat_to_arrayd(&closed);
            // Self-register the closed ring under the node `id` (RFC §8.1) so a
            // downstream `aggregate` over a `kind:"derived"` index set
            // (`from_faq: <id>`) sizes its contraction from this ring's
            // distinct-vertex count (`rows − 1`); see [`derived_extent`].
            if let Some(id) = &node.id {
                ctx.derived_rings
                    .borrow_mut()
                    .insert(id.clone(), arr.clone());
            }
            Value::Array(Box::new(arr))
        }
        // A degenerate input ring or unavailable backend surfaces as NaN, the
        // same not-a-value sentinel the evaluator uses for unevaluable nodes.
        Err(_) => Value::Scalar(f64::NAN),
    }
}

/// Evaluate the fused `polygon_intersection_area` leaf op (esm-spec §4.2 /
/// §8.6.1): the **scalar** overlap area of the two polygon operands under the
/// node's declared `manifold`. It is defined to equal
/// `polygon_area(intersect_polygon(a, b))` at the same `manifold` — the FUSED
/// form of the existing clip + shoelace — but exposes **no** clip ring
/// (unlike [`eval_intersect_polygon`], which surfaces the ring as an `[N, 2]`
/// array and self-registers a derived index set). This reuses the same kernels:
/// [`crate::geometry::intersect_polygon`] to clip, then
/// [`crate::geometry::polygon_area`] (planar shoelace / spherical-geodesic S2)
/// to measure, so its value matches the composed form exactly. A disjoint /
/// edge-touching clip yields a `< 3`-vertex ring, whose area is `0.0`.
pub(super) fn eval_polygon_intersection_area(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let Some((manifold, va, vb)) = eval_clip_operands(node, ctx) else {
        return Value::Scalar(f64::NAN);
    };
    // Clip, then measure — the fused composition. The clip kernel returns the
    // `n` distinct overlap vertices; `polygon_area`'s shoelace / spherical body
    // reads the wrap edge `n→1` itself, so no explicit ring closure is needed
    // here (and no derived ring is registered — the fused leaf exposes none).
    match crate::geometry::intersect_polygon(&va, &vb, manifold)
        .and_then(|ring| crate::geometry::polygon_area(&ring, manifold))
    {
        Ok(area) => Value::Scalar(area),
        // A degenerate input ring or unavailable backend surfaces as NaN, the
        // same not-a-value sentinel the evaluator uses for unevaluable nodes.
        Err(_) => Value::Scalar(f64::NAN),
    }
}

/// Close a ring by repeating its first vertex (RFC §8.1; mirrors Python
/// `geometry.close_ring`) so a `polygon_area` shoelace FAQ reads the wrap edge
/// `n→1` as an ordinary `index(ring, v+1, …)`. An empty (disjoint-clip) ring
/// stays empty, so its derived index set has extent 0 and the FAQ reduces to 0̄.
pub(super) fn close_ring(ring: &[(f64, f64)]) -> Vec<(f64, f64)> {
    if ring.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(ring.len() + 1);
    out.extend_from_slice(ring);
    out.push(ring[0]);
    out
}

/// Read a `[V, 2]` lon/lat coordinate array into a `Vec<(lon, lat)>`. Returns
/// `None` unless the array is 2-D with a trailing coordinate axis of length 2.
pub(super) fn arrayd_to_lonlat(arr: &ArrayD<f64>) -> Option<Vec<(f64, f64)>> {
    if arr.ndim() != 2 || arr.shape()[1] != 2 {
        return None;
    }
    let nv = arr.shape()[0];
    let mut out = Vec::with_capacity(nv);
    for v in 0..nv {
        out.push((arr[IxDyn(&[v, 0])], arr[IxDyn(&[v, 1])]));
    }
    Some(out)
}

/// Build a row-major `[N, 2]` lon/lat array from a ring of `(lon, lat)` pairs.
/// An empty ring yields a `[0, 2]` array so downstream `index(clip, v, c)` reads
/// return the 0 ghost value and a `sum_product` FAQ over the empty `clip_ring`
/// range reduces to the additive identity `0̄`.
pub(super) fn lonlat_to_arrayd(ring: &[(f64, f64)]) -> ArrayD<f64> {
    let n = ring.len();
    let mut flat = Vec::with_capacity(n * 2);
    for &(lon, lat) in ring {
        flat.push(lon);
        flat.push(lat);
    }
    ArrayD::from_shape_vec(IxDyn(&[n, 2]), flat).expect("ring [N,2] shape is consistent")
}

/// Evaluate a standalone expression against a set of named array inputs, reusing
/// the array evaluator — in particular the M1 `aggregate` machinery in
/// [`eval_arrayop`]. This is the entry point for computing a `polygon_area`
/// `sum_product` FAQ over an `intersect_polygon` ring (RFC §8.1): supply the
/// clipped ring (and any companion arrays the integrand references) in `inputs`
/// with the aggregate's `clip_ring` range already resolved to a concrete
/// `[1, N]` interval, and the body is reduced exactly as any other `aggregate`.
///
/// Returns [`Value::Scalar`] for a scalar FAQ output (`output_idx: []`),
/// [`Value::Array`] otherwise.
///
/// # Errors
///
/// This is the crate's one UNGATED evaluation entry point — it takes a raw
/// [`Expr`] that never passed through `from_model`'s compile-time gate — so it
/// applies [`check_evaluable`] itself. An operator the interpreter cannot
/// evaluate (a typo, an unlowered `grad`, or a `skolem`/`ic`/`table_lookup` that
/// an earlier pipeline stage should have eliminated) is reported here rather
/// than silently evaluating to `NaN`.
pub fn eval_expression(
    expr: &Expr,
    inputs: &HashMap<String, ArrayD<f64>>,
    params: &[f64],
    param_names: &[String],
    t: f64,
) -> Result<Value, CompileError> {
    eval_expression_with_extents(
        expr,
        inputs,
        params,
        param_names,
        t,
        crate::aggregate::empty_derived_extents(),
    )
}

/// [`eval_expression`] with the build-time **value-invention derived extents**
/// in hand — the standalone evaluator's counterpart of
/// [`crate::aggregate::resolve_aggregate_ranges_with_extents`].
///
/// `derived_extents` maps a producing aggregate's `id` (what a `kind:"derived"`
/// index set names in its `from_faq`) to the cardinality of the distinct member
/// set that producer materialized — i.e.
/// [`crate::value_invention::ValueInventionResult::extents`], verbatim.
///
/// Use this when `expr` still carries a [`RangeSpec::DerivedDyn`] bound, which
/// is what a range over a value-invented set looks like once it has been
/// resolved *without* the engine's results. Only the relational engine knows
/// how many members it invented, and `expr` alone cannot say; supplying the map
/// is the only way that contraction gets a non-empty range instead of silently
/// folding to the additive identity.
///
/// A runner wanting the reference wiring end to end:
///
/// ```ignore
/// // 1. invent the members from the loader-fed factor arrays
/// let vi = run_value_invention(&model, &index_sets, Some(&loaded))?;
/// // 2. size every `{ "from": <derived set> }` axis from the invented members
/// resolve_expr_ranges_with_extents(&mut expr, &index_sets, &vi.extents)?;
/// // 3. evaluate, with the extents still available to any `DerivedDyn` bound
/// eval_expression_with_extents(&expr, &inputs, &[], &[], 0.0, &vi.extents)?;
/// ```
///
/// Pass an empty map (or call [`eval_expression`]) for the geometry-only case:
/// a derived range then resolves from the runtime clip-ring registry exactly as
/// before.
///
/// # Errors
///
/// As [`eval_expression`] — an operator the interpreter cannot evaluate is
/// reported rather than silently producing `NaN`.
pub fn eval_expression_with_extents(
    expr: &Expr,
    inputs: &HashMap<String, ArrayD<f64>>,
    params: &[f64],
    param_names: &[String],
    t: f64,
    derived_extents: &HashMap<String, i64>,
) -> Result<Value, CompileError> {
    check_evaluable(expr)?;
    let empty: ArrMap = ArrMap::default();
    // Cold public boundary: the standalone evaluator's `inputs` arrive as a std
    // `HashMap` (FAQ rings, coordinate fields). Rehash into the fast [`ArrMap`]
    // the interpreter uses so the per-node tree walk gets the fast lookups. The
    // input maps are small (a clipped ring, a couple of coordinate arrays) and
    // this runs once per call (per-cell IC recompute was removed — see
    // `resolve_field_ics`), so the shallow re-map is negligible.
    let inputs: ArrMap = inputs.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    let derived_rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    // Standalone expression evaluation (FAQ rings, area integrands) carries no
    // loader forcing — an empty buffer keeps the channel byte-identical here.
    let forcing: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    let mut ctx = EvalCtx {
        state_arrays: &empty,
        observed_arrays: &inputs,
        params,
        param_names,
        loop_binds: IdxMap::default(),
        t,
        derived_rings: &derived_rings,
        derived_extents,
        forcing: &forcing,
        // Standalone one-shot evaluation: no CSE memo (nothing to amortize the
        // structural analysis over), so this path is unchanged.
        cse: None,
    };
    Ok(eval(expr, &mut ctx))
}

/// The output-index box of the aggregate currently being evaluated: the index
/// symbol names, and the origin (lower bound) of each output axis.
///
/// This is what lets an ARRAY-valued `filter` be resolved to *this* cell's
/// element — the same positional alignment the vectorized overlay's `VecBox`
/// uses (`element = array[idx - lo]`).
pub(super) struct CellBox<'a> {
    /// The output index symbol names, in axis order.
    pub names: &'a [String],
    /// The lower bound of each output axis, in the same order.
    pub origin: &'a [i64],
}

/// Evaluate an `aggregate`/`arrayop` `filter` predicate under the current loop
/// binds and report whether the combination is **excluded** (§5.3): excluded
/// iff a filter is present and evaluates to false. With no filter this is always
/// `false`, so the reduction is byte-identical to the no-filter form.
///
/// # An array filter is a per-cell MASK, not "exclude everything"
///
/// This function used to read `eval(f, ctx).as_scalar().unwrap_or(0.0) == 0.0`.
/// A filter that evaluates to an ARRAY — the natural spelling of a regrid
/// `overlap > 0` sparsity gate or a fuel gate `code >= 1`, where the predicate
/// names a whole field rather than an indexed element — has no scalar form, so
/// `as_scalar()` returned `None`, `unwrap_or(0.0)` turned that into `0.0`, and
/// **every cell was excluded**: the aggregate collapsed to the reduction
/// identity everywhere.
///
/// The vectorized overlay, meanwhile, fed exactly that array into `vec_select`
/// as a genuine per-cell mask — which is what its doc-comments advertise, and
/// what the fixtures using it intend. So the same document produced `[10, 0, 10]`
/// if its body happened to vectorize and `[0, 0, 0]` if a `reshape` in the body
/// forced it onto this oracle. **Which answer you got depended solely on
/// incidental vectorizability.**
///
/// The per-cell-mask reading is the intended one, so the oracle now implements
/// it: an array filter is indexed at the current output cell, aligned to the
/// output box exactly as `VecBox` aligns it. An array that cannot be aligned
/// (its rank does not match the output box) is treated as *including* the cell —
/// the conservative direction, since silently dropping every term is the failure
/// mode this fix exists to remove.
pub(super) fn filter_excludes(
    filter: Option<&Expr>,
    cell: Option<&CellBox>,
    ctx: &mut EvalCtx,
) -> bool {
    let Some(f) = filter else {
        return false;
    };
    match eval(f, ctx) {
        Value::Scalar(s) => s == 0.0,
        Value::Array(a) => {
            // 0-D array — a scalar in array clothing.
            if a.ndim() == 0 {
                return a.first().copied().unwrap_or(0.0) == 0.0;
            }
            let Some(cell) = cell else {
                return false;
            };
            if a.ndim() != cell.names.len() || cell.origin.len() != cell.names.len() {
                return false;
            }
            let ix: Vec<usize> = cell
                .names
                .iter()
                .zip(cell.origin.iter())
                .map(|(n, &lo)| {
                    let bound = ctx.loop_binds.get(n).copied().unwrap_or(lo);
                    (bound - lo).max(0) as usize
                })
                .collect();
            match a.get(IxDyn(&ix)) {
                Some(&m) => m == 0.0,
                // Out of the mask's bounds: include, rather than silently
                // dropping the term.
                None => false,
            }
        }
    }
}

/// Evaluate one output cell's value: the pointwise body when there are no
/// contracted indices, otherwise the semiring ⊕-reduction of the body over the
/// Cartesian product of the contracted dims. Each dim is resolved to its
/// concrete bound *under the current output tuple*, so a [`ContractDim::Ragged`]
/// dim uses this cell's dynamic per-parent extent (an empty extent reduces to
/// the additive identity 0̄). `ctx.loop_binds` must already hold the output-index
/// tuple; the contracted indices are bound here. This is the single contraction
/// kernel shared by the standalone-aggregate ([`eval_arrayop`]) and compiled
/// array-op-derivative ([`RhsRule::ArrayLoop`]) paths, mirroring the Julia
/// `_expand_int_range_dyn` einsum loop and the Python `_expand_ragged` gather.
pub(super) fn reduce_contraction(
    contract_names: &[String],
    contract_dims: &[ContractDim],
    static_ranges: Option<&[(i64, i64)]>,
    body: &Expr,
    reduce: ReduceKind,
    filter: Option<&Expr>,
    cell: Option<&CellBox>,
    ctx: &mut EvalCtx,
) -> f64 {
    if contract_names.is_empty() {
        // Pointwise: a filtered-out cell contributes the additive identity 0̄.
        return if filter_excludes(filter, cell, ctx) {
            reduce.identity()
        } else {
            eval(body, ctx).as_scalar().unwrap_or(f64::NAN)
        };
    }
    // Resolve each contracted dim to a concrete (lo, hi). When every dim is
    // static (the common case) the caller passes the bounds it computed ONCE
    // outside the output loop — they are cell-independent — so we skip the
    // per-cell re-derivation. Ragged/derived dims read their per-parent length
    // under *this* output tuple, so they are (re)derived here on the stack.
    let derived: SmallVec<[(i64, i64); 4]>;
    let ranges: &[(i64, i64)] = match static_ranges {
        Some(r) => r,
        None => {
            derived = contract_dims.iter().map(|d| d.concrete(ctx)).collect();
            &derived
        }
    };
    let mut acc: f64 = reduce.identity();
    // Stream the contraction product from a reused buffer — no per-tuple heap
    // allocation (this loop is the array-simulate hot path).
    let mut tuples = CartesianTuples::new(ranges);
    while let Some(k_tuple) = tuples.next() {
        for (kn, kv) in contract_names.iter().zip(k_tuple.iter()) {
            set_bind(&mut ctx.loop_binds, kn, *kv);
        }
        // A filtered-out combination contributes 0̄ (acc ⊕ 0̄ = acc) (§5.3).
        if filter_excludes(filter, cell, ctx) {
            continue;
        }
        let term = eval(body, ctx).as_scalar().unwrap_or(f64::NAN);
        acc = reduce.combine(acc, term);
    }
    acc
}

/// A recognized **forward prefix scan**: an `aggregate` whose single contracted
/// index is admitted by a monotone `filter` against one output index symbol
/// (esm-spec §4.3.1 "Cumulative (prefix) reductions").
///
/// Recognizing it turns the `O(N²)` triangular double loop into one `O(N)` sweep
/// with a running accumulator. The rewrite is **bit-identical, not approximate**:
/// the oracle folds the admitted window ascending, lowest `j` first, so
/// `accᵢ = accᵢ₋₁ ⊕ bodyᵢ` reproduces the same left fold with the same
/// association. That is the whole justification, and it is why only the FORWARD
/// rows (`<=`, `<`) are recognized here — a reverse scan's cells each fold their
/// own suffix from that suffix's low end, share no partial result, and cannot be
/// accumulated right-to-left without re-associating (esm-spec §4.3.1).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct PrefixScan {
    /// Position of the scanned symbol within the output-index tuple: the axis
    /// the accumulator sweeps along.
    pub axis: usize,
    /// `true` for `<=` (the newly admitted term joins BEFORE the cell is
    /// written), `false` for `<` (the cell is written first, so its window is
    /// the strictly-earlier terms and cell one is the empty reduction).
    pub inclusive: bool,
}

/// Match `filter` against the forward-prefix-scan shape and return the output
/// axis it scans along, or `None` if this aggregate is not one.
///
/// Every precondition below is a correctness requirement, not a heuristic:
///
/// * **Exactly one contracted index**, and the filter names it. With two, the
///   admitted set is not a prefix of a single axis.
/// * **Static contraction bounds** matching the output axis's own bounds — the
///   scan visits `j = i` at step `i`, which is only the newly admitted term when
///   the two axes are the same interval. A ragged/derived bound varies per cell.
/// * **The body must not reference the scanned output symbol.** If it did, every
///   output cell would have a *different* summand for the same `j` and no
///   partial result could be reused. (It may reference the contracted symbol and
///   any OTHER output symbol — those axes are just independent scans.)
/// * **The filter is exactly the comparison** — no conjunction, no extra
///   predicate — so "admitted" and "j ≤ i" coincide.
pub(super) fn detect_prefix_scan(
    output_idx_names: &[String],
    output_ranges: &[(i64, i64)],
    contract_names: &[String],
    static_ranges: Option<&[(i64, i64)]>,
    body: &Expr,
    filter: Option<&Expr>,
) -> Option<PrefixScan> {
    let filter = filter?;
    let [j_name] = contract_names else {
        return None;
    };
    let [(c_lo, c_hi)] = *static_ranges? else {
        return None;
    };

    let Expr::Operator(node) = filter else {
        return None;
    };
    if node.args.len() != 2 {
        return None;
    }
    // Accept both spellings of the same predicate: `j <= i` and `i >= j`.
    let (lhs, rhs) = (&node.args[0], &node.args[1]);
    let (i_name, inclusive) = match node.op.as_str() {
        "<=" | "<" => (var_name(rhs)?, node.op == "<="),
        ">=" | ">" => (var_name(lhs)?, node.op == ">="),
        _ => return None,
    };
    let j_side = match node.op.as_str() {
        "<=" | "<" => var_name(lhs)?,
        _ => var_name(rhs)?,
    };
    if j_side != j_name {
        return None;
    }

    let axis = output_idx_names.iter().position(|s| s == i_name)?;
    // Same interval, or `j = i` is not the term entering the window at step `i`.
    if output_ranges.get(axis)? != &(c_lo, c_hi) {
        return None;
    }
    // A body that reads the scanned symbol makes each cell's summand distinct.
    if expr_references(body, i_name) {
        return None;
    }
    Some(PrefixScan { axis, inclusive })
}

/// The variable name of a bare-string expression, else `None`. Index symbols
/// reach the evaluator as ordinary variable references.
fn var_name(e: &Expr) -> Option<&str> {
    match e {
        Expr::Variable(name) => Some(name.as_str()),
        _ => None,
    }
}

/// Whether `name` occurs anywhere in `e` as a bare variable reference —
/// including inside every sidecar Expression field, not just `args` (esm-spec
/// §4.9.5). Used to reject a scan whose body reads the scanned output symbol.
fn expr_references(e: &Expr, name: &str) -> bool {
    match e {
        Expr::Variable(v) => v == name,
        Expr::Integer(_) | Expr::Number(_) => false,
        Expr::Operator(node) => {
            node.args.iter().any(|a| expr_references(a, name))
                || [
                    node.expr.as_deref(),
                    node.filter.as_deref(),
                    node.key.as_deref(),
                    node.lower.as_deref(),
                    node.upper.as_deref(),
                ]
                .into_iter()
                .flatten()
                .any(|c| expr_references(c, name))
                || node
                    .values
                    .as_ref()
                    .is_some_and(|vs| vs.iter().any(|v| expr_references(v, name)))
        }
    }
}

/// Run one forward prefix scan along `scan.axis`, writing each output cell
/// through `emit`.
///
/// The caller has already bound every output symbol EXCEPT the scanned one; this
/// sweeps that axis ascending, carrying a single accumulator. At step `i` the
/// contracted symbol is bound to `i` — the term entering the window — so the
/// body is evaluated exactly once per cell rather than once per (cell, j) pair.
///
/// Inclusive (`<=`) folds the new term in *before* writing; exclusive (`<`)
/// writes first, so the first cell emits the untouched identity — the empty
/// reduction the spec requires, not an error.
pub(super) fn run_prefix_scan(
    scan: PrefixScan,
    i_name: &str,
    j_name: &str,
    (lo, hi): (i64, i64),
    body: &Expr,
    reduce: ReduceKind,
    ctx: &mut EvalCtx,
    mut emit: impl FnMut(i64, f64, &EvalCtx),
) {
    // Evaluate the one term admitted at step `i` (the body at `j = i`). The
    // scanned output symbol is bound too: it is out of scope for the body by
    // construction (`detect_prefix_scan` rejected a body that reads it), but
    // keeping it bound means an ARRAY-valued sub-read aligns to the same cell
    // the oracle would have aligned it to.
    let term_at = |i: i64, ctx: &mut EvalCtx| {
        set_bind(&mut ctx.loop_binds, i_name, i);
        set_bind(&mut ctx.loop_binds, j_name, i);
        eval(body, ctx).as_scalar().unwrap_or(f64::NAN)
    };

    let mut acc = reduce.identity();
    for i in lo..=hi {
        if scan.inclusive {
            // `<=`: the new term joins the window BEFORE this cell is written.
            let term = term_at(i, ctx);
            acc = reduce.combine(acc, term);
            set_bind(&mut ctx.loop_binds, i_name, i);
            emit(i, acc, ctx);
        } else {
            // `<`: this cell sees only strictly-earlier terms, so cell `lo`
            // emits the untouched identity — the empty reduction, not an error.
            set_bind(&mut ctx.loop_binds, i_name, i);
            emit(i, acc, ctx);
            let term = term_at(i, ctx);
            acc = reduce.combine(acc, term);
        }
    }
}

/// Precompute the contraction bounds when every dim is static (cell-independent),
/// so [`reduce_contraction`] can skip the per-cell re-derivation. Returns `None`
/// if any dim is ragged/derived (those must be resolved per output tuple).
pub(super) fn static_contract_ranges(
    contract_dims: &[ContractDim],
) -> Option<SmallVec<[(i64, i64); 4]>> {
    contract_dims
        .iter()
        .map(|d| d.static_bound())
        .collect::<Option<SmallVec<[(i64, i64); 4]>>>()
}

/// Gather the ragged per-parent length `offsets[of…]` for the current output
/// tuple: read each parent index variable from `ctx.loop_binds`, address the
/// `offsets` factor array (1-based → 0-based), and round to an integer count.
/// A scalar/0-D `offsets` factor is a constant valence for every parent. A
/// missing/unbound parent, a rank mismatch, or an out-of-bounds gather yields
/// `0` — an empty reduction (the additive identity 0̄), matching the evaluator's
/// homogeneous-ghost convention for out-of-bounds reads.
pub(super) fn ragged_upper_bound(offsets: &str, of: &[String], ctx: &EvalCtx) -> i64 {
    let arr = match lookup_variable(offsets, ctx) {
        Value::Scalar(s) => return s.round() as i64,
        Value::Array(a) => a,
    };
    if of.len() != arr.ndim() {
        return 0;
    }
    let mut idx = Vec::with_capacity(of.len());
    for p in of {
        match ctx.loop_binds.get(p) {
            Some(pv) if *pv >= 1 => idx.push((*pv - 1) as usize),
            _ => return 0,
        }
    }
    arr.get(IxDyn(&idx)).map(|v| v.round() as i64).unwrap_or(0)
}

thread_local! {
    /// Kernel-buffer pool for the vectorized overlay reached OUTSIDE the
    /// compiled-rule driver: a standalone `aggregate` materialized by
    /// [`eval_arrayop`], and an `AlgebraicRule::ArrayLoop` observed. Both used
    /// to build a `Pool::default()` per call, so their pool was empty every
    /// time and every kernel intermediate hit the allocator — the RHS-rule path
    /// has recycled through [`RhsScratch`]'s pool since ess-mro, but the
    /// observed path (where a stencil-heavy model does most of its work) never
    /// did.
    ///
    /// Thread-local rather than a field on `EvalCtx`: the overlay takes the
    /// pool by `&mut` while `EvalCtx` is borrowed shared, and the observed and
    /// aggregate call sites construct their contexts independently.
    static ARRAYOP_POOL: RefCell<Pool> = RefCell::new(Pool::default());
}

/// Run `f` with this thread's persistent kernel-buffer pool.
///
/// Re-entrancy is possible in principle — an outer aggregate whose vectorized
/// attempt FAILED falls back to the per-cell oracle, which may evaluate an
/// inner aggregate — but only after the outer borrow has been released, since
/// the borrow spans just the overlay attempt. The `try_borrow_mut` fallback to
/// a private pool makes that structural claim unnecessary: a nested use loses
/// the recycling, never correctness, and never panics.
pub(super) fn with_arrayop_pool<R>(f: impl FnOnce(&mut Pool) -> R) -> R {
    ARRAYOP_POOL.with(|p| match p.try_borrow_mut() {
        Ok(mut pool) => f(&mut pool),
        Err(_) => f(&mut Pool::default()),
    })
}

/// The evaluation parameters of a standalone `aggregate`/`arrayop` node.
///
/// Extracted in ONE place so the per-cell oracle ([`eval_arrayop`]) and the
/// vectorized overlay's nested-aggregate arm ([`eval_vec_nested_aggregate`])
/// derive them from the same code. A divergence here (a different contracted-
/// index order, a different `reduce` default) would silently make the fast path
/// compute a *different* array while both look correct in isolation.
pub(super) struct ArrayOpSpec<'n> {
    pub(super) idx_names: &'n [String],
    /// Stack-inlined (grid rank ≤ 4 in practice): a standalone aggregate is
    /// re-specified on every observed materialization of every RHS call, and a
    /// `Vec` here was one heap allocation per aggregate per call.
    pub(super) ranges: RangeVec,
    pub(super) body: &'n Expr,
    pub(super) contract_names: Vec<String>,
    pub(super) contract_dims: Vec<ContractDim>,
    pub(super) reduce: ReduceKind,
    pub(super) filter: Option<&'n Expr>,
}

/// Extract an aggregate node's evaluation parameters. `None` when the node
/// carries no body (`expr`), which the oracle reports as `NaN`.
pub(super) fn arrayop_spec(node: &ExpressionNode) -> Option<ArrayOpSpec<'_>> {
    // Borrow the node's index names / ranges / body rather than cloning them:
    // a standalone aggregate is re-evaluated on every observed materialization
    // (every RHS call), and the body can be a large stencil subtree — cloning it
    // per call was a leading source of allocation in the per-cell profile.
    let idx_names: &[String] = node.output_idx.as_deref().unwrap_or(&[]);
    static EMPTY_RANGES: std::sync::OnceLock<HashMap<String, crate::types::RangeSpec>> =
        std::sync::OnceLock::new();
    let ranges_map = node
        .ranges
        .as_ref()
        .unwrap_or_else(|| EMPTY_RANGES.get_or_init(HashMap::new));
    let body: &Expr = node.expr.as_deref()?;
    let ranges: RangeVec = idx_names
        .iter()
        .map(|n| {
            let r = ranges_map.get(n).and_then(|s| s.bounds()).unwrap_or([0, 0]);
            (r[0], r[1])
        })
        .collect();

    // Contracted indices: in ranges_map but not in output_idx. A linear scan of
    // `idx_names` (rank ≤ 4) rather than a `HashSet` built per call — the set
    // was a heap allocation on every aggregate of every RHS evaluation, and it
    // was probed at most `ranges_map.len()` times.
    let mut sorted_contract_keys: Vec<&String> = ranges_map
        .keys()
        .filter(|k| !idx_names.iter().any(|n| n == *k))
        .collect();
    sorted_contract_keys.sort();
    let contract_names: Vec<String> = sorted_contract_keys.iter().map(|k| (*k).clone()).collect();
    let contract_dims: Vec<ContractDim> = sorted_contract_keys
        .iter()
        .map(|k| ContractDim::from_range(&ranges_map[*k]))
        .collect();
    let reduce = effective_reduce_kind(node.semiring.as_deref(), node.reduce.as_deref());
    // §5.3 filter: a boolean predicate gating which index combinations
    // contribute a ⊗-term. Absent ⇒ every combination contributes (byte-
    // identical to the no-filter form).
    let filter = node.filter.as_deref();
    Some(ArrayOpSpec {
        idx_names,
        ranges,
        body,
        contract_names,
        contract_dims,
        reduce,
        filter,
    })
}

pub(super) fn eval_arrayop(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // Standalone arrayop (embedded as an expression, not as the top-level
    // of an equation LHS/RHS). Build the output array by iterating
    // ranges, binding loop indices, evaluating the body.
    //
    // Supports generalized einsum: indices present in `ranges` but absent
    // from `output_idx` are contracted (summed/reduced) per `reduce`.
    let ArrayOpSpec {
        idx_names,
        ranges,
        body,
        contract_names,
        contract_dims,
        reduce,
        filter,
    } = match arrayop_spec(node) {
        Some(s) => s,
        None => return Value::Scalar(f64::NAN),
    };

    // Stack-inlined (rank ≤ 4): rebuilt for every aggregate of every RHS call.
    let shape: DimU = ranges
        .iter()
        .map(|(lo, hi)| (hi - lo + 1) as usize)
        .collect();
    let origin: DimI = ranges.iter().map(|(lo, _)| *lo).collect();
    let total = shape.iter().copied().product::<usize>().max(1);

    // Hoist cell-independent (all-static) contraction bounds out of the per-cell
    // loop; ragged/derived dims are re-derived per output tuple inside.
    let static_ranges = static_contract_ranges(&contract_dims);

    // ---- Forward prefix scan (O(N) instead of the O(N²) triangle) -----------
    // A cumulative reduction (esm-spec §4.3.1) reaches here as a full triangular
    // double loop: N output cells × N contracted terms, each re-summing a window
    // the previous cell already summed. Recognized, it becomes one sweep with a
    // running accumulator — bit-identical, because both fold the window ascending
    // in the same association (see [`PrefixScan`]).
    //
    // Detected BEFORE the whole-array overlay is tried, because the two race and
    // the scan must win: the overlay would evaluate a cumulative aggregate as an
    // N-tuple fold of N-element arrays — correct, and bit-identical, but O(N²)
    // where the scan is O(N). (A widening of the overlay's index coverage made it
    // start accepting these, which regressed
    // `forward_scan_work_grows_linearly_not_quadratically`.) A non-cumulative
    // aggregate returns `None` here and goes to the overlay as before.
    let scan = detect_prefix_scan(
        idx_names,
        &ranges,
        &contract_names,
        static_ranges.as_deref(),
        body,
        filter,
    );

    // ---- Vectorized fast path (whole-array) --------------------------------
    // Evaluate the aggregate with the same verified `eval_vec` overlay the
    // compiled-RHS stencil path uses, instead of walking the body once per cell:
    //   * a pure MAP (out == ranges — e.g. a level-set Godunov `|∇φ|` stencil, a
    //     pointwise behaviour-stack field),
    //   * a static einsum CONTRACTION (`eval_vec_contracted` folds the window as
    //     shifted whole-array slices — e.g. a conservative-regrid `sum_product`
    //     over the source cells),
    //   * a §5.3 `filter` (a per-cell fuel gate, a `overlap > 0` regrid sparsity),
    //     carried by masking each term with the reduction identity.
    // The kernels reuse the identical `apply_binary`/`apply_unary`/`scalar_compare`
    // functions and ghost-0 convention, so the result is bit-identical to the
    // per-cell oracle below; any op / ragged-bound the overlay does not handle
    // returns `None` and we fall through. A local `Pool` recycles intermediates.
    if !shape.is_empty() && scan.is_none() {
        // The pool is the THREAD's, not a fresh one per call: a stencil-heavy
        // model materializes dozens of standalone aggregates per RHS evaluation
        // and a per-call `Pool::default()` started empty every time, so every
        // kernel intermediate went to the allocator.
        let materialized = with_arrayop_pool(|pool| {
            try_eval_arrayop_vectorized(
                idx_names,
                &ranges,
                body,
                &contract_names,
                &contract_dims,
                reduce,
                filter,
                &*ctx,
                pool,
            )
            .map(|(vv, _ops)| {
                // `try_eval_arrayop_vectorized` already verified the value covers
                // the output box exactly (bailing to `None` otherwise) and lifted
                // a bare scalar into an owned box buffer, so a plain view→owned
                // suffices.
                let out = vv.view().expect("vectorized arrayop has a view").to_owned();
                vv.release(pool);
                out
            })
        });
        if let Some(out) = materialized {
            return Value::Array(Box::new(out));
        }
    }

    let mut buf = vec![0.0f64; total];
    let saved_binds: Vec<(String, Option<i64>)> = idx_names
        .iter()
        .chain(contract_names.iter())
        .map(|n| (n.clone(), ctx.loop_binds.get(n).copied()))
        .collect();
    if let Some(scan) = scan {
        let (scan_lo, scan_hi) = ranges[scan.axis];
        // Sweep the scanned axis inside; every OTHER output axis is an
        // independent scan and forms the outer loop.
        let outer_ranges: Vec<(i64, i64)> = ranges
            .iter()
            .enumerate()
            .filter(|(d, _)| *d != scan.axis)
            .map(|(_, r)| *r)
            .collect();
        // Axis position and symbol name of each outer axis, paired once so the
        // per-tuple loop binds the symbol and records the coordinate together.
        let outer_axes: Vec<(usize, &String)> = idx_names
            .iter()
            .enumerate()
            .filter(|(d, _)| *d != scan.axis)
            .collect();
        let mut full = vec![0i64; ranges.len()];
        let mut outer = CartesianTuples::new(&outer_ranges);
        while let Some(otuple) = outer.next() {
            for ((d, name), val) in outer_axes.iter().zip(otuple.iter()) {
                set_bind(&mut ctx.loop_binds, name, *val);
                full[*d] = *val;
            }
            run_prefix_scan(
                scan,
                &idx_names[scan.axis],
                &contract_names[0],
                (scan_lo, scan_hi),
                body,
                reduce,
                ctx,
                |i, acc, _| {
                    full[scan.axis] = i;
                    buf[multi_to_flat_col_major(&full, &shape, &origin)] = acc;
                },
            );
        }
    } else {
        let mut tuples = CartesianTuples::new(&ranges);
        while let Some(tuple) = tuples.next() {
            for (name, val) in idx_names.iter().zip(tuple.iter()) {
                set_bind(&mut ctx.loop_binds, name, *val);
            }
            let v = reduce_contraction(
                &contract_names,
                &contract_dims,
                static_ranges.as_deref(),
                body,
                reduce,
                filter,
                Some(&CellBox {
                    names: idx_names,
                    origin: &origin,
                }),
                ctx,
            );
            let flat = multi_to_flat_col_major(tuple, &shape, &origin);
            buf[flat] = v;
        }
    }
    for (name, saved) in saved_binds {
        match saved {
            Some(v) => {
                ctx.loop_binds.insert(name, v);
            }
            None => {
                ctx.loop_binds.remove(&name);
            }
        }
    }
    if shape.is_empty() {
        Value::Scalar(buf[0])
    } else {
        Value::Array(Box::new(col_major_to_arrayd(&buf, &shape)))
    }
}

/// Would the per-cell [`eval_arrayop`] path recognize this `makearray` region
/// value as a forward prefix scan (esm-spec §4.3.1)?
///
/// The whole-array overlay evaluates a region value through
/// `eval_vec_nested_aggregate` → `try_eval_arrayop_vectorized`, which does NOT
/// consult [`detect_prefix_scan`]: a cumulative aggregate would come out
/// bit-identical but as an O(N²) triangular fold where the scan is O(N) — the
/// exact regression `forward_scan_work_grows_linearly_not_quadratically` pins.
/// So the overlay is declined for a `makearray` whose region value the scan
/// would have claimed. Only the region values themselves need this test: an
/// aggregate nested DEEPER already reaches the overlay's nested arm on the
/// existing paths, scan-detection included or not, and this change does not
/// alter that.
///
/// The check is one field test (`detect_prefix_scan` needs a `filter`) for the
/// unfiltered region values that make up every stencil template, so the
/// expensive spec build never runs on the hot path.
fn region_value_is_prefix_scan(value: &Expr) -> bool {
    let Expr::Operator(n) = value else {
        return false;
    };
    if n.filter.is_none() {
        return false;
    }
    let Some(spec) = arrayop_spec(n) else {
        return false;
    };
    let static_ranges = static_contract_ranges(&spec.contract_dims);
    detect_prefix_scan(
        spec.idx_names,
        &spec.ranges,
        &spec.contract_names,
        static_ranges.as_deref(),
        spec.body,
        spec.filter,
    )
    .is_some()
}

pub(super) fn eval_makearray(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // Borrow (don't clone) the region boxes and their value exprs — a boundary
    // `makearray` is rebuilt on every observed materialization, and its `values`
    // are full stencil subtrees; cloning them per call was pure allocation.
    let regions: &[Vec<[i64; 2]>] = node.regions.as_deref().unwrap_or(&[]);
    let values: &[Expr] = node.values.as_deref().unwrap_or(&[]);
    if regions.is_empty() || values.len() != regions.len() {
        return Value::Scalar(f64::NAN);
    }
    // Two region shapes used to PANIC here rather than being rejected: a ragged
    // `regions` list (rank taken from `regions[0]`, then `lo[d]`/`hi[d]` indexed
    // for every `d` of every region) and an inverted pair like `[5, 2]` (extent
    // `-2`, cast `as usize`, capacity-overflow in `ArrayD::zeros`). The registry
    // rejects both at the compile gate; re-checking here keeps the ungated
    // `eval_expression` entry point panic-free. Note the legal EMPTY spelling
    // `stop == start - 1` (§4.3.2) survives this check and must still assemble.
    if crate::op_registry::check_makearray_regions(node).is_err() {
        return Value::Scalar(f64::NAN);
    }
    // Compute the bounding box.
    let ndim = regions[0].len();
    let mut lo = vec![i64::MAX; ndim];
    let mut hi = vec![i64::MIN; ndim];
    for region in regions {
        for (d, r) in region.iter().enumerate() {
            lo[d] = lo[d].min(r[0]);
            hi[d] = hi[d].max(r[1]);
        }
    }
    // `max(0)` before the cast: an all-empty `regions` list legitimately yields a
    // zero-extent axis, and a negative extent must never wrap into a colossal
    // `usize`.
    let shape: Vec<usize> = (0..ndim)
        .map(|d| (hi[d] - lo[d] + 1).max(0) as usize)
        .collect();
    let origin = lo.clone();

    // ---- Vectorized fast path (whole-array region writes) ------------------
    // A `makearray` used as an observed's whole body — every boundary-dispatch
    // stencil a discretization template expands to — reaches the evaluator HERE,
    // not through `eval_arrayop`, so it had no overlay entry at all: its region
    // values vectorized (they are `aggregate`s, which try the overlay
    // themselves) but the assembly around them stayed a per-cell
    // `CartesianTuples` walk writing through bounds-checked dynamic-stride
    // `ArrayD` indexing. `ESS_VEC_DEBUG` reported these observeds as
    // "vectorized" precisely because nothing bailed — there was no bail site.
    //
    // `eval_vec_makearray` is the same region-sub-range-write assembly the
    // compiled-rule path already uses (pinned bit-identical by
    // `covered_makearray_region_dispatch`), so routing to it keeps the answer
    // identical while making the work N-independent and pool-backed.
    //
    // Gated on `loop_binds` being empty: inside a per-cell loop the nested
    // aggregates depend on the enclosing bindings and the overlay would bail
    // anyway — once per cell, which is pure loss.
    //
    // The box carries NO output-index symbols, because a `makearray` reached
    // here is not a cell of an enclosing `arrayop`: nothing is bound around it,
    // and each region value is evaluated exactly once (not once per cell), so
    // `eval_vec_nested_aggregate`'s hoisting precondition — "the nested body
    // must not depend on an enclosing bound index" — is vacuously satisfied and
    // its `expr_mentions` scan has nothing to test. That is not cosmetic:
    // placeholder names cost one full walk of the region body PER AXIS PER
    // REGION, and on a 7-region PPM template that scan alone was 43% of the run.
    if !vec_disabled()
        && ctx.loop_binds.is_empty()
        && !shape.contains(&0)
        && !values.iter().any(region_value_is_prefix_scan)
    {
        let bx = VecBox {
            syms: &[],
            lo: &lo,
            shape: &shape,
            cnames: &[],
            cvals: &[],
        };
        let materialized = with_arrayop_pool(|pool| {
            let mut ops = 0usize;
            eval_vec_makearray(node, &bx, &*ctx, pool, &mut ops).map(|vv| {
                let out = vv.view().expect("vectorized makearray has a view").to_owned();
                vv.release(pool);
                out
            })
        });
        if let Some(out) = materialized {
            return Value::Array(Box::new(out));
        }
        // `eval_vec_makearray` records its own bail site, so the log already
        // names the offending region value.
    } else if !vec_disabled() {
        // Declined before the overlay ran, so nothing else recorded a reason.
        // Without this, a `makearray` observed that took the per-cell path
        // reported as "vectorized" under `ESS_VEC_DEBUG` — an empty bail log —
        // and was invisible to exactly the tracing built to find it.
        note_bail(|| {
            format!(
                "makearray: overlay not attempted (loop_binds={}, empty axis={}, prefix-scan region={})",
                ctx.loop_binds.len(),
                shape.contains(&0),
                values.iter().any(region_value_is_prefix_scan),
            )
        });
    }

    let mut arr = ArrayD::<f64>::zeros(IxDyn(&shape));
    for (region, value_expr) in regions.iter().zip(values.iter()) {
        let v = eval(value_expr, ctx);
        // Iterate the region's index tuples.
        let ranges: Vec<(i64, i64)> = region.iter().map(|r| (r[0], r[1])).collect();
        // A region-aligned ARRAY value (e.g. a lowered stencil's interior
        // aggregate) must span the region box exactly; each region cell then
        // reads its aligned element (mirrors the vectorized
        // `eval_vec_makearray` region-assign and the Julia/Python region
        // semantics).
        //
        // A shape MISMATCH used to `continue` — silently leaving the region as
        // the `zeros` fill, so a region `[1, 3]` given a 2-element `const` value
        // assembled to `[0.0, 0.0, 0.0]` and the caller had no way to tell that
        // its value expression had been discarded. The vectorized twin refuses
        // to assemble such a node at all (it bails to this oracle). Poison the
        // result with the NaN sentinel instead: this interpreter has no error
        // channel (`eval` returns a `Value`, and the solver reads `NaN` as a step
        // failure), so a loud `NaN` is the strongest signal available — and it is
        // strictly better than a plausible-looking zero.
        if let Value::Array(a) = &v
            && a.ndim() > 0
        {
            let region_shape: Vec<usize> = ranges
                .iter()
                .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                .collect();
            if a.shape() != region_shape.as_slice() {
                return Value::Scalar(f64::NAN);
            }
            // The legal EMPTY region spelling (`stop == start - 1`, §4.3.2)
            // writes nothing — and its `start` may sit one past the bounding
            // box, which is not a slicable offset. The per-cell walk produced no
            // tuples here; skip explicitly.
            if region_shape.contains(&0) {
                continue;
            }
            // Whole-region slice assign. This used to be a `CartesianTuples`
            // walk that built TWO `Vec<usize>` index tuples per cell and wrote
            // through `ArrayD`'s bounds-checked, dynamic-stride `Index`/
            // `IndexMut` — two heap allocations and two `stride_offset_checked`
            // computations per element, for what is a straight sub-block copy.
            // `assign` moves the same values to the same places (both arrays are
            // in the evaluator's row-major layout and the shapes were just
            // checked equal), so the result is bit-identical.
            arr.slice_each_axis_mut(|ax| {
                let d = ax.axis.index();
                let s0 = (ranges[d].0 - origin[d]) as usize;
                ndarray::Slice::from(s0..s0 + region_shape[d])
            })
            .assign(a);
            continue;
        }
        let scalar = match &v {
            Value::Scalar(s) => *s,
            Value::Array(a) if a.ndim() == 0 => a[IxDyn(&[])],
            // Unreachable: the `ndim() > 0` array case returned/continued above.
            _ => continue,
        };
        // Whole-region fill (was the same per-cell `Vec`-building walk).
        let region_shape: Vec<usize> = ranges
            .iter()
            .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
            .collect();
        if region_shape.contains(&0) {
            continue;
        }
        arr.slice_each_axis_mut(|ax| {
            let d = ax.axis.index();
            let s0 = (ranges[d].0 - origin[d]) as usize;
            ndarray::Slice::from(s0..s0 + region_shape[d])
        })
        .fill(scalar);
    }
    Value::Array(Box::new(arr))
}

pub(super) fn eval_reshape(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let Some(arg0) = node.args.first() else {
        return Value::Scalar(f64::NAN);
    };
    let v = eval(arg0, ctx);
    let arr = match v {
        Value::Array(a) => *a,
        Value::Scalar(s) => ArrayD::from_elem(IxDyn(&[]), s),
    };
    let target: Vec<usize> = node
        .shape
        .clone()
        .unwrap_or_default()
        .iter()
        .map(|&d| d as usize)
        .collect();
    // Column-major reshape: flatten in column-major order, reinterpret
    // under the new shape in column-major order.
    let flat = arrayd_to_col_major(&arr);
    // `col_major_to_arrayd` `.expect`s a matching element count; a user `shape`
    // whose product disagrees with the data length is a malformed node ⇒ the NaN
    // sentinel (module convention) rather than a panic.
    if target.iter().product::<usize>() != flat.len() {
        return Value::Scalar(f64::NAN);
    }
    Value::Array(Box::new(col_major_to_arrayd(&flat, &target)))
}

/// True iff `perm` is a permutation of `0..ndim` (correct length, every axis in
/// range, no duplicates) — the precondition `ndarray::permuted_axes` panics on if
/// violated. A user-supplied `transpose` `perm` is untrusted, so it is validated
/// before use.
fn is_valid_permutation(perm: &[usize], ndim: usize) -> bool {
    if perm.len() != ndim {
        return false;
    }
    let mut seen = vec![false; ndim];
    for &ax in perm {
        if ax >= ndim || seen[ax] {
            return false;
        }
        seen[ax] = true;
    }
    true
}

pub(super) fn eval_transpose(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let Some(arg0) = node.args.first() else {
        return Value::Scalar(f64::NAN);
    };
    let v = eval(arg0, ctx);
    let arr = match v {
        Value::Array(a) => a,
        Value::Scalar(s) => return Value::Scalar(s),
    };
    let perm: Vec<usize> = if let Some(p) = &node.perm {
        p.iter().map(|&x| x as usize).collect()
    } else {
        // Default: reverse axes.
        (0..arr.ndim()).rev().collect()
    };
    // `permuted_axes` panics unless `perm` is a permutation of the array's axes
    // (right length, in-range, no duplicates). Validate the untrusted `perm`
    // first and surface the NaN sentinel for a malformed permutation.
    if !is_valid_permutation(&perm, arr.ndim()) {
        return Value::Scalar(f64::NAN);
    }
    Value::Array(Box::new(
        arr.permuted_axes(perm).as_standard_layout().into_owned(),
    ))
}

pub(super) fn eval_concat(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let axis = node.axis.unwrap_or(0) as usize;
    let parts: Vec<ArrayD<f64>> = node
        .args
        .iter()
        .map(|a| match eval(a, ctx) {
            Value::Array(arr) => *arr,
            Value::Scalar(s) => ArrayD::from_elem(IxDyn(&[1]), s),
        })
        .collect();
    let views: Vec<_> = parts.iter().map(|a| a.view()).collect();
    // A shape mismatch (unequal extents off the concat axis) or an out-of-range
    // `axis` makes the join impossible. Mirror the module's NaN-sentinel
    // convention used by the sibling assembly ops (`eval_reshape`,
    // `eval_makearray`), which return `Value::Scalar(f64::NAN)` for a malformed
    // node: the solver reads NaN as a step failure. The former silent
    // `[0]`-shaped empty array looked like a valid (if degenerate) result and
    // hid the mismatch.
    match ndarray::concatenate(ndarray::Axis(axis), &views) {
        Ok(joined) => Value::Array(Box::new(joined)),
        Err(_) => Value::Scalar(f64::NAN),
    }
}

pub(super) fn eval_broadcast(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // Fold the operands left-to-right without materializing a `Vec<Value>`:
    // evaluate the first arg, then combine each subsequent one in place. This is
    // the hottest node in the per-cell profile; the old `.collect()` allocated a
    // temporary vector per node per cell.
    let fn_name = node.broadcast_fn.as_deref().unwrap_or("+");
    let mut args = node.args.iter();
    let Some(first) = args.next() else {
        return Value::Scalar(f64::NAN);
    };
    let mut out = eval(first, ctx);
    for next in args {
        let v = eval(next, ctx);
        out = combine(fn_name, out, v);
    }
    out
}

/// Evaluate a simple index expression given concrete loop variable bindings.
/// Supports integer literals, bare variable lookups, and `a + b` / `a - b`.
/// Generic over the map hasher so it accepts both the build-time std-`HashMap`
/// binds and the hot-path [`IdxMap`] (`ctx.loop_binds`).
pub(super) fn eval_simple_index<S: std::hash::BuildHasher>(
    expr: &Expr,
    binds: &HashMap<String, i64, S>,
) -> i64 {
    match expr {
        Expr::Integer(n) => *n,
        Expr::Number(n) => *n as i64,
        Expr::Variable(name) => binds.get(name).copied().unwrap_or(0),
        Expr::Operator(node) if (node.op == "+" || node.op == "-") && node.args.len() == 2 => {
            let a = eval_simple_index(&node.args[0], binds);
            let b = eval_simple_index(&node.args[1], binds);
            if node.op == "+" { a + b } else { a - b }
        }
        _ => 0,
    }
}

/// Evaluate the integer range of an index expression given the currently
/// active loop variable ranges. Supports: integer literals, a bare symbol
/// bound to a loop, and `(i + k)` / `(i - k)` / `(k + i)` arithmetic.
pub(super) fn evaluate_index_range(
    expr: &Expr,
    loop_ranges: &HashMap<String, (i64, i64)>,
) -> (i64, i64) {
    match expr {
        Expr::Integer(n) => (*n, *n),
        Expr::Number(n) => {
            let v = *n as i64;
            (v, v)
        }
        Expr::Variable(name) => {
            if let Some((lo, hi)) = loop_ranges.get(name) {
                (*lo, *hi)
            } else {
                (0, 0)
            }
        }
        Expr::Operator(node) => match node.op.as_str() {
            "+" | "-" => {
                if node.args.len() != 2 {
                    return (0, 0);
                }
                let a = evaluate_index_range(&node.args[0], loop_ranges);
                let b = evaluate_index_range(&node.args[1], loop_ranges);
                if node.op == "+" {
                    (a.0 + b.0, a.1 + b.1)
                } else {
                    (a.0 - b.1, a.1 - b.0)
                }
            }
            _ => (0, 0),
        },
    }
}

#[cfg(test)]
mod evaluability_gate_tests {
    //! The public `eval_expression` entry point must never answer a question it
    //! cannot evaluate with a silent `NaN` — a NaN is indistinguishable from a
    //! legitimate numerical result and poisons the solution downstream. Every
    //! unevaluable operator class must surface a diagnosable error instead.

    use super::*;
    use crate::types::Expr;

    fn node(op: &str, args: Vec<Expr>) -> Expr {
        Expr::Operator(ExpressionNode {
            op: op.to_string(),
            args,
            ..ExpressionNode::default()
        })
    }

    fn eval_it(expr: &Expr) -> Result<Value, CompileError> {
        eval_expression(expr, &HashMap::new(), &[], &[], 0.0)
    }

    /// A misspelled operator ("expp") is an open-tier op: `unlowered_operator`.
    #[test]
    fn typo_op_is_rejected_not_nan() {
        let err = eval_it(&node("expp", vec![Expr::Number(1.0)]))
            .expect_err("a typo'd operator must not evaluate");
        assert!(
            matches!(err, CompileError::UnloweredOperatorError { ref op } if op == "expp"),
            "{err:?}"
        );
    }

    /// An unlowered rewrite-target sugar op reaching evaluation is reported,
    /// where it used to yield the NaN sentinel.
    #[test]
    fn unlowered_spatial_op_is_rejected_not_nan() {
        let err = eval_it(&node("grad", vec![Expr::Variable("c".into())]))
            .expect_err("an unlowered spatial operator must not evaluate");
        assert!(
            matches!(err, CompileError::UnloweredOperatorError { ref op } if op == "grad"),
            "{err:?}"
        );
    }

    /// Build `op` with an argument count its registry arity actually admits, so
    /// the arity gate passes and the EVALUABILITY gate is what fires.
    fn node_with_legal_arity(op: &str) -> Expr {
        let arity = crate::op_registry::arity_of(op).expect("registry-legal op");
        let n = (0..=3)
            .find(|n| arity.admits(*n))
            .expect("some arity in 0..=3 is admitted");
        node(op, (0..n).map(|_| Expr::Variable("x".into())).collect())
    }

    /// The gap this closes: ops the REGISTRY calls legal (`is_core_op`) but this
    /// evaluator has no arm for, because an earlier pipeline stage was supposed
    /// to eliminate them. They used to fall through to `_ => NaN`.
    #[test]
    fn registry_legal_but_unevaluable_ops_are_rejected_not_nan() {
        for op in [
            "skolem",
            "rank",
            "distinct",
            "argmin",
            "argmax",
            "ic",
            "table_lookup",
        ] {
            assert!(
                crate::op_registry::is_core_op(op),
                "{op} should be registry-legal, else this test proves nothing"
            );
            assert!(
                !is_evaluable_op(op),
                "{op} should have no eval arm, else this test proves nothing"
            );
            let err = eval_it(&node_with_legal_arity(op)).unwrap_err_or_else_msg(op);
            assert!(
                matches!(err, CompileError::UnevaluableOperatorError { op: ref got } if got == op),
                "{op}: {err:?}"
            );
        }
    }

    /// The gate is not merely top-level: an unevaluable op NESTED inside an
    /// otherwise-fine expression is still caught.
    #[test]
    fn unevaluable_op_nested_in_expression_is_rejected() {
        let expr = node(
            "+",
            vec![Expr::Number(1.0), node("skolem", vec![Expr::Number(2.0)])],
        );
        assert!(
            eval_it(&expr).is_err(),
            "nested unevaluable op must be caught"
        );
    }

    /// And an evaluable expression still evaluates — the gate is not a blanket
    /// rejection.
    #[test]
    fn evaluable_expression_still_evaluates() {
        let expr = node("+", vec![Expr::Number(2.0), Expr::Number(3.0)]);
        match eval_it(&expr).expect("a legal expression must evaluate") {
            Value::Scalar(s) => assert_eq!(s, 5.0),
            Value::Array(_) => panic!("expected a scalar"),
        }
    }

    /// `is_evaluable_op` must agree with `eval_op`'s arms for every op the
    /// registry admits: any registry op NOT listed as evaluable must be rejected
    /// by the gate rather than reaching the `unreachable!` backstop.
    #[test]
    fn every_registry_op_is_either_evaluable_or_gated() {
        for op in [
            "+",
            "-",
            "*",
            "/",
            "^",
            "exp",
            "log",
            "sqrt",
            "min",
            "max",
            "ifelse",
            "index",
            "aggregate",
            "makearray",
            "broadcast",
            "reshape",
            "transpose",
            "concat",
            "fn",
            "skolem",
            "rank",
            "distinct",
            "argmin",
            "argmax",
            "ic",
            "enum",
            "table_lookup",
            "apply_expression_template",
            "true",
        ] {
            if !crate::op_registry::is_core_op(op) {
                continue;
            }
            if is_evaluable_op(op) {
                continue;
            }
            // Not evaluable ⇒ the gate MUST reject it, so `eval_op` never sees it.
            let err = eval_it(&node_with_legal_arity(op)).unwrap_err_or_else_msg(op);
            assert!(
                matches!(err, CompileError::UnevaluableOperatorError { .. }),
                "{op} is registry-legal and not evaluable, so it must be gated: {err:?}"
            );
        }
    }

    /// Small helper: `Result::unwrap_err` with the op name in the panic message.
    trait UnwrapErrMsg {
        fn unwrap_err_or_else_msg(self, op: &str) -> CompileError;
    }
    impl UnwrapErrMsg for Result<Value, CompileError> {
        fn unwrap_err_or_else_msg(self, op: &str) -> CompileError {
            match self {
                Ok(v) => panic!("op '{op}' must not evaluate, got {v:?}"),
                Err(e) => e,
            }
        }
    }
}

#[cfg(test)]
mod geometry_eval_tests {
    //! End-to-end evaluation of the M4 geometry kernel through the *real* array
    //! evaluator (bead ess-my4.4.11; RFC `semiring-faq-unified-ir` §8.1): the
    //! `intersect_polygon` leaf is dispatched by [`eval_op`] (spherical →
    //! s2geometry via the `s2bindings` crate, planar → Sutherland–Hodgman), and
    //! `polygon_area` is computed as an ordinary `sum_product` aggregate over the
    //! clipped ring, reduced by the M1 machinery in [`eval_arrayop`]. This is the
    //! Rust binding actually clipping and integrating, not just schema-validating.
    use super::*;
    use serde_json::json;

    /// Build an `[N, 2]` lon/lat array from a ring of `(lon, lat)` pairs.
    fn ring_array(ring: &[(f64, f64)]) -> ArrayD<f64> {
        let mut flat = Vec::with_capacity(ring.len() * 2);
        for &(lon, lat) in ring {
            flat.push(lon);
            flat.push(lat);
        }
        ArrayD::from_shape_vec(IxDyn(&[ring.len(), 2]), flat).unwrap()
    }

    /// Drop a trailing vertex equal to the first — the closed-ring form the
    /// `intersect_polygon` AST op now returns — so an oracle that expects the `n`
    /// distinct vertices (e.g. s2 `spherical_area`, which rejects a degenerate
    /// duplicate-vertex edge) sees the open ring.
    fn distinct_vertices(ring: &[(f64, f64)]) -> Vec<(f64, f64)> {
        match ring.last() {
            Some(last) if ring.len() >= 2 && *last == ring[0] => ring[..ring.len() - 1].to_vec(),
            _ => ring.to_vec(),
        }
    }

    /// Clip two polygons through the public evaluator path — `eval_expression`
    /// → [`eval_op`] → `intersect_polygon` arm — exactly as a model's observed
    /// `clip` variable would be evaluated. Returns the overlap ring vertices.
    fn clip_via_evaluator(
        src: &[(f64, f64)],
        tgt: &[(f64, f64)],
        manifold: &str,
    ) -> Vec<(f64, f64)> {
        let mut inputs = HashMap::new();
        inputs.insert("src_poly".to_string(), ring_array(src));
        inputs.insert("tgt_poly".to_string(), ring_array(tgt));
        let node: Expr = serde_json::from_value(json!({
            "op": "intersect_polygon",
            "id": "overlap_clip",
            "manifold": manifold,
            "args": ["src_poly", "tgt_poly"],
        }))
        .unwrap();
        match eval_expression(&node, &inputs, &[], &[], 0.0)
            .expect("test node is built from evaluable ops")
        {
            Value::Array(a) => arrayd_to_lonlat(&a).expect("[N,2] ring"),
            Value::Scalar(s) => panic!("intersect_polygon evaluated to scalar {s}"),
        }
    }

    /// `polygon_area` as an ordinary `sum_product` FAQ over a ring (planar
    /// shoelace), evaluated by the M1 aggregate machinery. The integrand is the
    /// signed cross term `½·(xᵥ·yᵥ₊₁ − xᵥ₊₁·yᵥ)` summed over ring edges; the ring
    /// and its one-vertex rotation are supplied as arrays so the contracted `v`
    /// loop needs no wrap-around indexing. Returns the unsigned area.
    fn shoelace_area_faq(ring: &[(f64, f64)]) -> f64 {
        let n = ring.len();
        if n < 3 {
            return 0.0;
        }
        let next: Vec<(f64, f64)> = (0..n).map(|i| ring[(i + 1) % n]).collect();
        let mut inputs = HashMap::new();
        inputs.insert("clip".to_string(), ring_array(ring));
        inputs.insert("clip_next".to_string(), ring_array(&next));
        let agg: Expr = serde_json::from_value(json!({
            "op": "aggregate",
            "args": [],
            "semiring": "sum_product",
            "output_idx": [],
            "ranges": { "v": [1, n] },
            "expr": {
                "op": "*",
                "args": [
                    0.5,
                    { "op": "-", "args": [
                        { "op": "*", "args": [
                            { "op": "index", "args": ["clip", "v", 1] },
                            { "op": "index", "args": ["clip_next", "v", 2] }
                        ]},
                        { "op": "*", "args": [
                            { "op": "index", "args": ["clip_next", "v", 1] },
                            { "op": "index", "args": ["clip", "v", 2] }
                        ]}
                    ]}
                ]
            }
        }))
        .unwrap();
        match eval_expression(&agg, &inputs, &[], &[], 0.0)
            .expect("test node is built from evaluable ops")
        {
            Value::Scalar(s) => s.abs(),
            Value::Array(_) => panic!("scalar polygon_area FAQ expected"),
        }
    }

    #[test]
    fn planar_clip_then_polygon_area_faq_is_exact() {
        // [0,2]² ∩ [1,3]² = [1,2]², area 1. Clip through the evaluator, then take
        // `polygon_area` as a sum_product FAQ over the clipped ring.
        let src = [(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)];
        let tgt = [(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)];
        let ring = clip_via_evaluator(&src, &tgt, "planar");
        assert!(ring.len() >= 3, "expected a non-degenerate overlap ring");
        let area = shoelace_area_faq(&ring);
        assert!(
            (area - 1.0).abs() < 1e-9,
            "polygon_area FAQ = {area}, expected 1"
        );
        // The FAQ agrees with the closed-form shoelace oracle.
        assert!((area - crate::geometry::shoelace_area(&ring)).abs() < 1e-12);
    }

    #[test]
    fn planar_clip_of_offset_triangles_area_faq() {
        // A non-rectangular case so the FAQ is exercised on a general ring.
        let src = [(0.0, 0.0), (4.0, 0.0), (0.0, 4.0)];
        let tgt = [(0.0, 0.0), (4.0, 0.0), (4.0, 4.0)];
        let ring = clip_via_evaluator(&src, &tgt, "planar");
        let area = shoelace_area_faq(&ring);
        // Overlap is the triangle (0,0),(4,0),(2,2): area = ½·base·height = 4.
        assert!(
            (area - 4.0).abs() < 1e-9,
            "polygon_area FAQ = {area}, expected 4"
        );
    }

    #[test]
    fn spherical_clip_via_s2_is_nonempty_with_analytic_area() {
        // Two quarter-hemisphere sectors; the s2 clip overlap is π/4 steradians.
        let src = [(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)];
        let tgt = [(45.0, 0.0), (135.0, 0.0), (45.0, 90.0)];
        let ring = clip_via_evaluator(&src, &tgt, "spherical");
        assert!(ring.len() >= 3, "the s2 spherical clip should be non-empty");
        // The AST op returns the ring CLOSED (first vertex repeated) for the
        // shoelace FAQ's `v+1` wrap; the `spherical_area` oracle wants the `n`
        // distinct vertices (s2 rejects a duplicate-vertex edge), so drop the
        // closing copy before the analytic comparison.
        let area =
            crate::geometry::spherical_area(&distinct_vertices(&ring)).expect("spherical area");
        assert!(
            (area - std::f64::consts::FRAC_PI_4).abs() < 1e-9,
            "spherical overlap area = {area}, expected π/4"
        );
    }

    #[test]
    fn disjoint_clip_is_empty_ring_with_zero_area_faq() {
        let src = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)];
        let tgt = [(5.0, 5.0), (6.0, 5.0), (6.0, 6.0), (5.0, 6.0)];
        let ring = clip_via_evaluator(&src, &tgt, "planar");
        assert!(ring.is_empty(), "disjoint cells clip to an empty ring");
        // A sum_product FAQ over the empty clip_ring reduces to the additive 0̄.
        assert_eq!(shoelace_area_faq(&ring), 0.0);
    }

    /// Evaluate the fused `polygon_intersection_area` leaf through the public
    /// evaluator path (`eval_expression` → [`eval_op`] → `polygon_intersection_area`
    /// arm), returning the scalar overlap area directly (no clip ring exposed).
    fn fused_area_via_evaluator(src: &[(f64, f64)], tgt: &[(f64, f64)], manifold: &str) -> Value {
        let mut inputs = HashMap::new();
        inputs.insert("src_poly".to_string(), ring_array(src));
        inputs.insert("tgt_poly".to_string(), ring_array(tgt));
        let node: Expr = serde_json::from_value(json!({
            "op": "polygon_intersection_area",
            "manifold": manifold,
            "args": ["src_poly", "tgt_poly"],
        }))
        .unwrap();
        eval_expression(&node, &inputs, &[], &[], 0.0)
            .expect("test node is built from evaluable ops")
    }

    #[test]
    fn polygon_intersection_area_planar_is_fused_clip_area() {
        // [0,2]² ∩ [1,3]² = [1,2]², area 1. The fused leaf returns the SCALAR
        // area directly and equals `polygon_area(intersect_polygon(a, b))`.
        let src = [(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)];
        let tgt = [(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)];
        let area = match fused_area_via_evaluator(&src, &tgt, "planar") {
            Value::Scalar(s) => s,
            Value::Array(_) => panic!("fused leaf must return a scalar, not a ring"),
        };
        assert!(
            (area - 1.0).abs() < 1e-9,
            "polygon_intersection_area = {area}, expected 1"
        );
        // Fused value matches the composed clip + shoelace-FAQ form exactly.
        let ring = clip_via_evaluator(&src, &tgt, "planar");
        assert!((area - shoelace_area_faq(&ring)).abs() < 1e-12);
    }

    #[test]
    fn polygon_intersection_area_disjoint_is_zero() {
        // Disjoint cells clip to a < 3-vertex ring, whose area is 0.
        let src = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)];
        let tgt = [(5.0, 5.0), (6.0, 5.0), (6.0, 6.0), (5.0, 6.0)];
        match fused_area_via_evaluator(&src, &tgt, "planar") {
            Value::Scalar(s) => assert_eq!(s, 0.0, "disjoint overlap area should be 0, got {s}"),
            Value::Array(_) => panic!("fused leaf must return a scalar"),
        }
    }

    #[test]
    fn polygon_intersection_area_without_manifold_is_unevaluable() {
        // `manifold` is required on the fused leaf too; absent, it is NaN.
        let mut inputs = HashMap::new();
        inputs.insert(
            "src_poly".to_string(),
            ring_array(&[(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)]),
        );
        inputs.insert(
            "tgt_poly".to_string(),
            ring_array(&[(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)]),
        );
        let node: Expr = serde_json::from_value(json!({
            "op": "polygon_intersection_area",
            "args": ["src_poly", "tgt_poly"],
        }))
        .unwrap();
        match eval_expression(&node, &inputs, &[], &[], 0.0)
            .expect("test node is built from evaluable ops")
        {
            Value::Scalar(s) => assert!(s.is_nan(), "missing manifold should be NaN, got {s}"),
            Value::Array(_) => panic!("missing manifold must not produce a scalar area"),
        }
    }

    #[test]
    fn intersect_polygon_without_manifold_is_unevaluable() {
        // `manifold` is required; absent, the node is not evaluable (NaN sentinel).
        let mut inputs = HashMap::new();
        inputs.insert(
            "src_poly".to_string(),
            ring_array(&[(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)]),
        );
        inputs.insert(
            "tgt_poly".to_string(),
            ring_array(&[(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)]),
        );
        let node: Expr = serde_json::from_value(json!({
            "op": "intersect_polygon",
            "args": ["src_poly", "tgt_poly"],
        }))
        .unwrap();
        match eval_expression(&node, &inputs, &[], &[], 0.0)
            .expect("test node is built from evaluable ops")
        {
            Value::Scalar(s) => assert!(s.is_nan(), "missing manifold should be NaN, got {s}"),
            Value::Array(_) => panic!("missing manifold must not produce a ring"),
        }
    }
}

#[cfg(test)]
mod ragged_eval_tests {
    //! Dynamic per-parent (ragged) contraction bounds in the array evaluator
    //! (bead ess-787; RFC `semiring-faq-unified-ir` §5.2). A `RangeSpec::RaggedDyn`
    //! contracted index reads its per-parent length `offsets[of…]` from a factor
    //! array at eval time, so each output cell reduces over its own dynamic
    //! extent — mirroring the Julia `_expand_int_range_dyn` einsum loop and the
    //! Python `_expand_ragged` reference (`test_ragged_index_set_dynamic_per_parent_bound`).
    use super::*;
    use serde_json::json;

    /// Build the standalone aggregate `out[i] = ⊕_{k∈edges(i)} k` with `k`'s
    /// range resolved to a ragged bound over the `nedges` factor. A file never
    /// authors a `RaggedDyn` range (the resolver produces it), so we parse the
    /// node and inject the resolved range directly.
    fn ragged_sum_node() -> Expr {
        let mut agg: Expr = serde_json::from_value(json!({
            "op": "aggregate",
            "args": [],
            "semiring": "sum_product",
            "output_idx": ["i"],
            "expr": "k",
            "ranges": { "i": [1, 2], "k": [1, 1] }
        }))
        .unwrap();
        if let Expr::Operator(node) = &mut agg {
            node.ranges.as_mut().unwrap().insert(
                "k".to_string(),
                RangeSpec::RaggedDyn {
                    offsets: "nedges".into(),
                    of: vec!["i".into()],
                },
            );
        }
        agg
    }

    fn nedges(values: &[f64]) -> HashMap<String, ArrayD<f64>> {
        HashMap::from([(
            "nedges".to_string(),
            ArrayD::from_shape_vec(IxDyn(&[values.len()]), values.to_vec()).unwrap(),
        )])
    }

    /// `nedges = [2, 3]` ⇒ `out = [1+2, 1+2+3] = [3, 6]` — the per-parent bound
    /// is read fresh for each output cell.
    #[test]
    fn ragged_contraction_uses_per_parent_dynamic_bound() {
        match eval_expression(&ragged_sum_node(), &nedges(&[2.0, 3.0]), &[], &[], 0.0)
            .expect("test node is built from evaluable ops")
        {
            Value::Array(a) => {
                assert_eq!(a.shape(), [2]);
                assert_eq!(a[IxDyn(&[0])], 3.0);
                assert_eq!(a[IxDyn(&[1])], 6.0);
            }
            Value::Scalar(s) => panic!("expected a [3, 6] array, got scalar {s}"),
        }
    }

    /// An isolated parent (zero-length ragged segment) reduces to the semiring's
    /// additive identity 0̄: `nedges = [0, 2]` ⇒ `out = [0, 1+2] = [0, 3]`.
    #[test]
    fn ragged_empty_segment_yields_additive_identity() {
        match eval_expression(&ragged_sum_node(), &nedges(&[0.0, 2.0]), &[], &[], 0.0)
            .expect("test node is built from evaluable ops")
        {
            Value::Array(a) => {
                assert_eq!(a[IxDyn(&[0])], 0.0);
                assert_eq!(a[IxDyn(&[1])], 3.0);
            }
            Value::Scalar(s) => panic!("expected a [0, 3] array, got scalar {s}"),
        }
    }
}
