//! The per-cell oracle interpreter: recursive [`Value`] evaluation of every
//! expression node (arithmetic, transcendentals, array ops, `aggregate`
//! contractions with ragged/derived bounds, geometry leaf ops) plus the
//! standalone [`eval_expression`] entry point. This path is the correctness
//! reference the vectorized overlay is verified against.

use super::*;
use crate::aggregate::effective_reduce_kind;
use crate::types::ExpressionNode;

/// The distinct-vertex extent of the FAQ-materialized ring registered under
/// `from_faq` (RFC §8.1): the producing `intersect_polygon` clip stores the
/// **closed** ring (`n+1` rows, first vertex repeated so the `polygon_area`
/// shoelace can read the wrap edge as an ordinary `index(ring, v+1, …)`), so the
/// number of distinct vertices is `rows − 1`. An unmaterialized producer or an
/// empty (disjoint) clip yields `0` — an empty contraction reducing to the
/// additive identity 0̄, matching the evaluator's ghost-read convention and the
/// Python reference (`numpy_interpreter._resolve_range_spec`).
pub(super) fn derived_ring_extent(from_faq: &str, ctx: &EvalCtx) -> i64 {
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
            Value::Array(a.clone())
        };
    }
    if let Some(a) = ctx.observed_arrays.get(name) {
        return if a.ndim() == 0 {
            Value::Scalar(a[IxDyn(&[])])
        } else {
            Value::Array(a.clone())
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
            Value::Array(a.clone())
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

        // Rewrite-target sugar ops must be lowered to a stencil by a `match`
        // rewrite rule before reaching the simulator (esm-spec §4.2 / §9.6.8).
        // The compile-time `check_no_spatial_ops` walk in `from_model` catches
        // these with the uniform `unlowered_operator` code. But the public
        // `eval_expression` entry point bypasses that gate, so this arm IS
        // reachable — surface the NaN sentinel (the module's convention for an
        // unevaluable node; the solver reads it as a step failure) rather than
        // panicking.
        op if UNLOWERED_SPATIAL_OPS.contains(&op) => Value::Scalar(f64::NAN),

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

        _ => Value::Scalar(f64::NAN),
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
        return Value::Array(out);
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

pub(super) fn fold_scalar(op: &str, vs: &[f64]) -> f64 {
    match op {
        "+" => vs.iter().sum(),
        "*" => vs.iter().product(),
        "-" => {
            if vs.len() == 2 {
                vs[0] - vs[1]
            } else {
                f64::NAN
            }
        }
        "/" => {
            if vs.len() == 2 {
                vs[0] / vs[1]
            } else {
                f64::NAN
            }
        }
        "^" => {
            if vs.len() == 2 {
                vs[0].powf(vs[1])
            } else {
                f64::NAN
            }
        }
        "min" => {
            if vs.len() < 2 {
                f64::NAN
            } else {
                vs.iter().copied().fold(f64::INFINITY, f64::min)
            }
        }
        "max" => {
            if vs.len() < 2 {
                f64::NAN
            } else {
                vs.iter().copied().fold(f64::NEG_INFINITY, f64::max)
            }
        }
        // n-ary logical connectives (the all-scalar fast path of `eval_arith`).
        "and" => vs.iter().all(|&v| v != 0.0) as i32 as f64,
        "or" => vs.iter().any(|&v| v != 0.0) as i32 as f64,
        _ => f64::NAN,
    }
}

pub(super) fn negate(v: Value) -> Value {
    match v {
        Value::Scalar(s) => Value::Scalar(-s),
        Value::Array(a) => Value::Array(a.mapv(|x| -x)),
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
    Value::Array(out)
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
        (Value::Scalar(x), Value::Array(ya)) => Value::Array(ya.mapv(|y| apply_binary(op, x, y))),
        (Value::Array(xa), Value::Scalar(y)) => Value::Array(xa.mapv(|x| apply_binary(op, x, y))),
        (Value::Array(xa), Value::Array(ya)) => {
            // Use ndarray broadcasting.
            Value::Array(broadcast_binary(op, &xa, &ya))
        }
    }
}

pub(super) fn apply_binary(op: &str, x: f64, y: f64) -> f64 {
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
        Value::Array(a) => Value::Array(a.mapv(|x| apply_unary(op, x))),
    }
}

pub(super) fn apply_unary(op: &str, x: f64) -> f64 {
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

pub(super) fn eval_binary(op: &str, args: &[Expr], ctx: &mut EvalCtx) -> Value {
    let a = eval(&args[0], ctx);
    let b = eval(&args[1], ctx);
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
        return Value::Array(view.to_owned());
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
                .map(Value::Array)
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
    let poly_a = match eval(&node.args[0], ctx) {
        Value::Array(a) => a,
        _ => return None,
    };
    let poly_b = match eval(&node.args[1], ctx) {
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
            // distinct-vertex count (`rows − 1`); see [`derived_ring_extent`].
            if let Some(id) = &node.id {
                ctx.derived_rings
                    .borrow_mut()
                    .insert(id.clone(), arr.clone());
            }
            Value::Array(arr)
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
pub fn eval_expression(
    expr: &Expr,
    inputs: &HashMap<String, ArrayD<f64>>,
    params: &[f64],
    param_names: &[String],
    t: f64,
) -> Value {
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
        forcing: &forcing,
    };
    eval(expr, &mut ctx)
}

/// Evaluate an `aggregate`/`arrayop` `filter` predicate under the current loop
/// binds and report whether the combination is **excluded** (§5.3): excluded
/// iff a filter is present and evaluates to false (a zero scalar). With no
/// filter this is always `false`, so the reduction is byte-identical to the
/// no-filter form.
pub(super) fn filter_excludes(filter: Option<&Expr>, ctx: &mut EvalCtx) -> bool {
    match filter {
        Some(f) => eval(f, ctx).as_scalar().unwrap_or(0.0) == 0.0,
        None => false,
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
    ctx: &mut EvalCtx,
) -> f64 {
    if contract_names.is_empty() {
        // Pointwise: a filtered-out cell contributes the additive identity 0̄.
        return if filter_excludes(filter, ctx) {
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
        if filter_excludes(filter, ctx) {
            continue;
        }
        let term = eval(body, ctx).as_scalar().unwrap_or(f64::NAN);
        acc = reduce.combine(acc, term);
    }
    acc
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

pub(super) fn eval_arrayop(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // Standalone arrayop (embedded as an expression, not as the top-level
    // of an equation LHS/RHS). Build the output array by iterating
    // ranges, binding loop indices, evaluating the body.
    //
    // Supports generalized einsum: indices present in `ranges` but absent
    // from `output_idx` are contracted (summed/reduced) per `reduce`.
    // Borrow the node's index names / ranges / body rather than cloning them:
    // a standalone aggregate is re-evaluated on every observed materialization
    // (every RHS call), and the body can be a large stencil subtree — cloning it
    // per call was a leading source of allocation in the per-cell profile.
    let idx_names: &[String] = node.output_idx.as_deref().unwrap_or(&[]);
    let empty_ranges: HashMap<String, crate::types::RangeSpec> = HashMap::new();
    let ranges_map = node.ranges.as_ref().unwrap_or(&empty_ranges);
    let body: &Expr = match node.expr.as_deref() {
        Some(b) => b,
        None => return Value::Scalar(f64::NAN),
    };
    let ranges: Vec<(i64, i64)> = idx_names
        .iter()
        .map(|n| {
            let r = ranges_map.get(n).and_then(|s| s.bounds()).unwrap_or([0, 0]);
            (r[0], r[1])
        })
        .collect();

    // Contracted indices: in ranges_map but not in output_idx.
    let output_idx_set: std::collections::HashSet<&String> = idx_names.iter().collect();
    let mut sorted_contract_keys: Vec<&String> = ranges_map
        .keys()
        .filter(|k| !output_idx_set.contains(k))
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

    let shape: Vec<usize> = ranges
        .iter()
        .map(|(lo, hi)| (hi - lo + 1) as usize)
        .collect();
    let origin: Vec<i64> = ranges.iter().map(|(lo, _)| *lo).collect();
    let total = shape.iter().copied().product::<usize>().max(1);

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
    if !shape.is_empty() {
        let mut pool = Pool::default();
        if let Some((vv, _ops)) = try_eval_arrayop_vectorized(
            idx_names,
            &ranges,
            body,
            &contract_names,
            &contract_dims,
            reduce,
            filter,
            &*ctx,
            &mut pool,
        ) {
            // `try_eval_arrayop_vectorized` already verified the value covers the
            // output box exactly (bailing to `None` otherwise) and lifted a bare
            // scalar into an owned box buffer, so a plain view→owned suffices.
            let out = vv.view().expect("vectorized arrayop has a view").to_owned();
            vv.release(&mut pool);
            return Value::Array(out);
        }
    }

    let mut buf = vec![0.0f64; total];
    let saved_binds: Vec<(String, Option<i64>)> = idx_names
        .iter()
        .chain(contract_names.iter())
        .map(|n| (n.clone(), ctx.loop_binds.get(n).copied()))
        .collect();
    // Hoist cell-independent (all-static) contraction bounds out of the per-cell
    // loop; ragged/derived dims are re-derived per output tuple inside.
    let static_ranges = static_contract_ranges(&contract_dims);
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
            ctx,
        );
        let flat = multi_to_flat_col_major(tuple, &shape, &origin);
        buf[flat] = v;
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
        Value::Array(col_major_to_arrayd(&buf, &shape))
    }
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
    let shape: Vec<usize> = (0..ndim).map(|d| (hi[d] - lo[d] + 1) as usize).collect();
    let origin = lo.clone();
    let mut arr = ArrayD::<f64>::zeros(IxDyn(&shape));
    for (region, value_expr) in regions.iter().zip(values.iter()) {
        let v = eval(value_expr, ctx);
        // Iterate the region's index tuples.
        let ranges: Vec<(i64, i64)> = region.iter().map(|r| (r[0], r[1])).collect();
        // A region-aligned ARRAY value (e.g. a lowered stencil's interior
        // aggregate) must span the region box exactly; each region cell then
        // reads its aligned element (mirrors the vectorized
        // `eval_vec_makearray` region-assign and the Julia/Python region
        // semantics). A shape mismatch keeps the previous skip behaviour.
        if let Value::Array(a) = &v
            && a.ndim() > 0
        {
            let region_shape: Vec<usize> = ranges
                .iter()
                .map(|(lo, hi)| (hi - lo + 1) as usize)
                .collect();
            if a.shape() == region_shape.as_slice() {
                let mut tuples = CartesianTuples::new(&ranges);
                while let Some(tuple) = tuples.next() {
                    let out_ix: Vec<usize> = tuple
                        .iter()
                        .enumerate()
                        .map(|(d, x)| (x - origin[d]) as usize)
                        .collect();
                    let src_ix: Vec<usize> = tuple
                        .iter()
                        .enumerate()
                        .map(|(d, x)| (x - ranges[d].0) as usize)
                        .collect();
                    arr[IxDyn(&out_ix)] = a[IxDyn(&src_ix)];
                }
            }
            continue;
        }
        let mut tuples = CartesianTuples::new(&ranges);
        while let Some(tuple) = tuples.next() {
            let indices: Vec<usize> = tuple
                .iter()
                .enumerate()
                .map(|(d, x)| (x - origin[d]) as usize)
                .collect();
            let ix = IxDyn(&indices);
            let scalar = match &v {
                Value::Scalar(s) => *s,
                Value::Array(a) if a.ndim() == 0 => a[IxDyn(&[])],
                _ => continue,
            };
            arr[ix] = scalar;
        }
    }
    Value::Array(arr)
}

pub(super) fn eval_reshape(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let Some(arg0) = node.args.first() else {
        return Value::Scalar(f64::NAN);
    };
    let v = eval(arg0, ctx);
    let arr = match v {
        Value::Array(a) => a,
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
    Value::Array(col_major_to_arrayd(&flat, &target))
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
    Value::Array(arr.permuted_axes(perm).as_standard_layout().into_owned())
}

pub(super) fn eval_concat(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    let axis = node.axis.unwrap_or(0) as usize;
    let parts: Vec<ArrayD<f64>> = node
        .args
        .iter()
        .map(|a| match eval(a, ctx) {
            Value::Array(arr) => arr,
            Value::Scalar(s) => ArrayD::from_elem(IxDyn(&[1]), s),
        })
        .collect();
    let views: Vec<_> = parts.iter().map(|a| a.view()).collect();
    let joined = ndarray::concatenate(ndarray::Axis(axis), &views)
        .unwrap_or_else(|_| ArrayD::zeros(IxDyn(&[0])));
    Value::Array(joined)
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
        match eval_expression(&node, &inputs, &[], &[], 0.0) {
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
        match eval_expression(&agg, &inputs, &[], &[], 0.0) {
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
        match eval_expression(&node, &inputs, &[], &[], 0.0) {
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
        match eval_expression(&node, &inputs, &[], &[], 0.0) {
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
        match eval_expression(&ragged_sum_node(), &nedges(&[2.0, 3.0]), &[], &[], 0.0) {
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
        match eval_expression(&ragged_sum_node(), &nedges(&[0.0, 2.0]), &[], &[], 0.0) {
            Value::Array(a) => {
                assert_eq!(a[IxDyn(&[0])], 0.0);
                assert_eq!(a[IxDyn(&[1])], 3.0);
            }
            Value::Scalar(s) => panic!("expected a [0, 3] array, got scalar {s}"),
        }
    }
}
