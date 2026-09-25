//! The per-cell oracle interpreter: recursive [`Value`] evaluation of every
//! expression node (arithmetic, transcendentals, array ops, `faq`
//! contractions with ragged/derived bounds, geometry leaf ops) plus the
//! standalone [`eval_expression`] entry point. This path is the correctness
//! reference the vectorized overlay is verified against.

use super::*;
use crate::compile_error::CompileError;
use crate::faq::effective_reduce_kind;
use crate::types::{ExpressionNode, JoinClause};

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
/// A geometry producer materialized by neither — an unevaluated clip, or an
/// empty (disjoint) one — yields `0`: an empty contraction reducing to the
/// additive identity 0̄, matching the evaluator's ghost-read convention. A
/// non-geometry producer with no extent never reaches here: the build and the
/// standalone entry both refuse it as `derived_index_set_unmaterialized`, since
/// its empty range would read as a plausible 0 (esm-spec §9.6.6). The leniency
/// is specific to a *contraction* bound, where an empty range is a well-defined
/// answer. A derived range that has to size an OUTPUT axis never reaches here:
/// it is resolved far earlier, and much more strictly, by
/// `crate::faq::resolve_index_set_ref`, which errors rather than invent a
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
        // Literals round on ingress (§ `crate::precision`): under Float32 a
        // literal that reaches an output through no operator at all must still
        // be the binary32 value, and `0.1` is not a binary32 number. Identity
        // under Float64.
        Expr::Number(n) => Value::Scalar(crate::precision::round(*n)),
        Expr::Integer(n) => Value::Scalar(crate::precision::round(*n as f64)),
        Expr::Variable(name) => lookup_variable(name, ctx),
        Expr::Operator(node) => eval_op(node, ctx),
    }
}

/// Resolve a bare variable name to a [`Value`].
///
/// **Precision.** The SCALAR arms round to the active precision
/// (`crate::precision`) — the ingress rule that keeps every live value
/// binary32 under `element_type: "Float32"`, so a variable copied straight to
/// an output is the binary32 value even though no operator ran. Identity under
/// Float64.
///
/// Two deliberate exceptions:
///
/// * **Loop index bindings are NOT rounded.** They are exact integers used as
///   array subscripts; narrowing them would be wrong, not more faithful.
///   (`precision::check_index_set_extent` rejects the extents where index
///   *arithmetic* through the f32 kernels would stop being exact.)
/// * **Array arms are not rounded here.** An array is either produced by this
///   evaluator (already binary32, every operation having rounded) or supplied
///   by the host, in which case it is rounded ONCE where it enters the problem
///   rather than on every one of the O(N) reads of it.
pub(super) fn lookup_variable(name: &str, ctx: &EvalCtx) -> Value {
    let prec = crate::precision::active();
    if name == "t" {
        return Value::Scalar(prec.round(ctx.t));
    }
    // A BARE read of the array a recurrence is sweeping (esm-spec §4.3.1.1
    // rejection 4). The structural validator refuses this, so reaching it means
    // the document bypassed validation; fail closed rather than let the name
    // fall through to a stale observed entry or a NaN that reads like a missing
    // variable.
    if let Some(scope) = ctx.recur
        && scope.name == name
    {
        latch_gather_fault(format!(
            "E_TREEWALK_RECUR_UNAVAILABLE: '{name}' is read BARE inside its own recurrence \
             definition — the whole array does not exist during the sweep. Read it through \
             `index` at a strictly earlier position instead (esm-spec §4.3.1.1)."
        ));
        return Value::Scalar(f64::NAN);
    }
    if let Some(v) = ctx.loop_binds.get(name) {
        return Value::Scalar(*v as f64);
    }
    if let Some(a) = ctx.state_arrays.get(name) {
        return if a.ndim() == 0 {
            Value::Scalar(prec.round(a[IxDyn(&[])]))
        } else {
            Value::Array(Box::new(a.clone()))
        };
    }
    if let Some(a) = ctx.observed_arrays.get(name) {
        return if a.ndim() == 0 {
            Value::Scalar(prec.round(a[IxDyn(&[])]))
        } else {
            Value::Array(Box::new(a.clone()))
        };
    }
    if let Some(i) = ctx.param_names.iter().position(|p| p == name) {
        return Value::Scalar(prec.round(ctx.params[i]));
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
            Value::Scalar(prec.round(a[IxDyn(&[])]))
        } else {
            Value::Array(Box::new(a.clone()))
        };
    }
    // Nothing produced a value for this name. Two very different defects reach
    // this point and they MUST NOT be reported as one (issue #181).
    //
    // (1) The name IS declared by this model — a state, a parameter, or an
    //     observed — but no value for it exists HERE. For an observed that
    //     means its rule has not run: the materialization order stalled, which
    //     is what a dependency cycle among observeds looks like from inside the
    //     evaluator (esm-spec §4.9.6). Reporting it as unbound is a claim about
    //     the DOCUMENT that this arm is not in a position to make, and it was
    //     routinely false — the reported name was typically an observed that is
    //     declared, defined and referenced perfectly well, and had nothing to
    //     do with the cycle. Bisecting from that message costs an afternoon.
    if ctx.declared.contains(name) {
        latch_gather_fault(format!(
            "E_TREEWALK_UNRESOLVED_ORDER: '{name}' IS declared in this model, but nothing had \
             produced a value for it at the point this expression was evaluated. For an observed \
             that means its defining rule had not run yet — the usual cause is a dependency \
             cycle among observed variables, which no evaluation order satisfies (esm-spec \
             §4.9.6). Run `esm validate`: it reports the cycle as `observed_cycle` and names the \
             observeds on it. This is NOT an undeclared name — see E_TREEWALK_UNBOUND_NAME for \
             that (CONFORMANCE_SPEC §5.23)."
        ));
        return Value::Scalar(f64::NAN);
    }
    // (2) NOTHING bound this name — not `t`, not a loop binder, not a state, not
    // an observed, not a parameter, not a forcing channel, and the model does
    // not declare it either. There is no further resolution scope to try, so the
    // read cannot produce a value.
    //
    // FAIL CLOSED (CONFORMANCE_SPEC §5.23). Returning a bare `NaN` here is the
    // sentinel that F24 and F25 both rode: IEEE-754 `max`/`min` return the
    // NON-NaN operand, so `max(known, typo)` silently evaluates as
    // `max(known)` — an operand disappears and the answer stays finite,
    // plausible and wrong. A comparison launders it just as quietly. The latch
    // is the tree walk's error channel (it returns a bare `Value`); every entry
    // point drains it, so the read surfaces as a named build/solve failure
    // instead of a number. The `NaN` returned alongside is only what the walk
    // carries until the drain.
    latch_gather_fault(format!(
        "E_TREEWALK_UNBOUND_NAME: '{name}' is referenced in an expression but bound by \
         NOTHING in scope — it is not the independent variable, a loop index, a state, an \
         observed, a parameter, or a forcing channel. A name declared nowhere in the \
         document is a structural error (`esm validate` reports it against the equation); \
         reaching evaluation means one route skipped that gate. Fail-closed per \
         CONFORMANCE_SPEC §5.23: never a NaN sentinel, which `max(x, floor)` or any \
         comparison would launder into a plausible number by dropping the operand."
    ));
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
/// * form / lowering ops (`ic`, `enum`, `table_lookup`,
///   `apply_expression_template`) — consumed by their lowering passes;
/// * the open rewrite-target tier (`grad`, `div`, `laplacian`, a typo'd
///   `"expp"`, a user op) — must be lowered to a stencil first.
#[must_use]
pub fn is_evaluable_op(op: &str) -> bool {
    matches!(
        op,
        // Arithmetic. `pow` is the word spelling of `^`.
        "+" | "-" | "*" | "/" | "^" | "pow" | "neg"
        // Elementary functions.
        | "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil"
        | "sin" | "cos" | "tan" | "asin" | "acos" | "atan"
        | "sinh" | "cosh" | "tanh" | "asinh" | "acosh" | "atanh"
        | "atan2" | "min" | "max"
        // Comparisons and booleans.
        | "==" | "!=" | "<" | "<=" | ">" | ">=" | "and" | "or" | "not"
        | "ifelse"
        // Form ops with a defined runtime meaning here. `true` is a nullary
        // boolean LITERAL (esm-spec §4.2: "an always-true join / `filter`
        // predicate"), not something a lowering pass consumes — the natural body
        // for a semi-join, and the one op in the §4.2 table this evaluator used
        // to have no answer for while `value_invention::vi_eval`, Python's
        // `numpy_interpreter` and Julia's `_geo_compile` all evaluated it.
        | "D" | "Pre" | "const" | "true" | "false"
        // Array / geometry ops.
        | "index" | "faq" | "makearray" | "reshape" | "transpose" | "concat"
        | "broadcast" | "intersect_polygon" | "polygon_intersection_area"
        // Closed function registry.
        | "fn"
        // The engine-internal precision-boundary marker
        // (`crate::precision_infer::MARKER_OP`): a transparent wrapper that
        // evaluates its one operand at a stated element type. Never authored.
        | crate::precision_infer::MARKER_OP
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
/// [`CompileError::MakearrayRegionInvalid`] (from the registry gate),
/// [`CompileError::UnevaluableOperatorError`], or — only when the active
/// precision is `Float32` — [`CompileError::Float32Unsupported`].
pub fn check_evaluable(expr: &Expr) -> Result<(), CompileError> {
    check_no_spatial_ops(expr)?;
    check_evaluable_ops(expr)?;
    // Layer 3: the constructs that have an evaluation rule here but only a
    // binary64 one (`intersect_polygon`, `polygon_intersection_area`, the
    // interpolating closed functions). Under `element_type: "Float32"` those
    // would quietly compute part of the answer in the wrong precision, so they
    // are rejected NAMING themselves (esm-spec §11.3). A no-op under Float64.
    crate::precision::check_f32_supported(expr)
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

/// Evaluate a standalone SCALAR expression to one number — the evaluator
/// behind [`crate::expression::evaluate`].
///
/// `params` / `param_names` are the scalar bindings, positionally; `t` is the
/// independent variable. The per-cell oracle does the work, gated first by
/// [`check_scalar_evaluable`], so an operator with no scalar value is refused
/// by name before any of the expression is evaluated.
///
/// # Errors
///
/// Everything [`check_scalar_evaluable`] reports, and the evaluator's own
/// fail-closed faults (an unbound name, an out-of-range const-array gather) as
/// [`CompileError::InterpreterBuildError`].
pub(crate) fn eval_scalar_expression(
    expr: &Expr,
    params: &[f64],
    param_names: &[String],
    t: f64,
) -> Result<f64, CompileError> {
    check_scalar_evaluable(expr)?;
    let value = eval_expression(expr, &HashMap::new(), params, param_names, t)?;
    value
        .as_scalar()
        .ok_or_else(|| CompileError::InterpreterBuildError {
            details: "the expression is array-valued; a scalar evaluation has one number \
                      to return"
                .to_string(),
        })
}

/// [`check_evaluable`] for an entry point whose answer is ONE NUMBER computed
/// from scalar bindings ([`eval_scalar_expression`]).
///
/// On top of the runtime gate it refuses, naming the operator, what has no
/// scalar value over scalar operands: the array / tensor ops, the geometry
/// ops, an array-valued `const` (except as a `fn` argument, where it is the
/// `interp.*` table or axis), and a structural `D`, which [`eval_op_named`]
/// answers with the `NaN` sentinel because a right-hand-side `D` never
/// legitimately reaches evaluation (esm-spec §4.2).
///
/// The layers run in [`check_evaluable`]'s order with this one before the
/// Float32 layer, so an op that trips both (`intersect_polygon`) is reported as
/// `unevaluable_operator`: declaring `Float64` would not make it evaluable here.
pub(crate) fn check_scalar_evaluable(expr: &Expr) -> Result<(), CompileError> {
    check_no_spatial_ops(expr)?;
    check_evaluable_ops(expr)?;
    check_scalar_ops(expr)?;
    crate::precision::check_f32_supported(expr)
}

/// The [`check_scalar_evaluable`] layer that refuses the ops with no scalar
/// value, applied over the whole tree.
fn check_scalar_ops(expr: &Expr) -> Result<(), CompileError> {
    let Expr::Operator(node) = expr else {
        return Ok(());
    };
    let no_scalar_value = match node.op.as_str() {
        "D"
        | "index"
        | "faq"
        | "makearray"
        | "reshape"
        | "transpose"
        | "concat"
        | "broadcast"
        | "intersect_polygon"
        | "polygon_intersection_area" => true,
        "const" => !node
            .value
            .as_ref()
            .is_some_and(serde_json::Value::is_number),
        _ => false,
    };
    if no_scalar_value {
        return Err(CompileError::UnevaluableOperatorError {
            op: node.op.clone(),
        });
    }
    let is_fn = node.op == "fn";
    let mut first_err: Option<CompileError> = None;
    node.for_each_child(&mut |child| {
        let table_arg = is_fn && matches!(child, Expr::Operator(c) if c.op == "const");
        if first_err.is_none()
            && !table_arg
            && let Err(e) = check_scalar_ops(child)
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
    eval_op_named(node.op.as_str(), node, ctx)
}

/// [`eval_op`] with the operator NAME supplied separately from the node.
///
/// Every arm below reads the operator from `op` and its operands from `node`,
/// which is what makes `broadcast` expressible without duplicating a single
/// kernel: a `broadcast` node re-enters this function with `op` replaced by its
/// `fn` and the SAME node, so `broadcast(fn = F, args)` is evaluated by
/// literally the code that evaluates `{"op": F, "args": args}` — bit-identity
/// by construction rather than by a parallel table that can drift.
///
/// (`display.rs` and `units.rs` already model `broadcast` this way, by building
/// a synthetic `{op: fn, args}` node. Passing the name alongside the real node
/// gets the same semantics without cloning `args` per cell — this is the
/// hottest node in the per-cell profile.)
fn eval_op_named(op: &str, node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    match op {
        // Elementwise / scalar arithmetic. If any operand is an array,
        // return an array (with ndarray broadcasting).
        "+" | "-" | "*" | "/" | "^" => eval_arith(op, &node.args, ctx),
        // The word spelling of `^`, folded through the `^` kernel itself.
        "pow" => eval_arith("^", &node.args, ctx),

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

        // The precision-boundary marker inserted by
        // `crate::precision_infer`: evaluate the one operand at the element
        // type it names, then hand the value back unchanged. Widening
        // binary32 → binary64 is exact, so the carrier stays invisible; the
        // marker only decides which kernel table the subtree resolves.
        crate::precision_infer::MARKER_OP => {
            if node.args.len() != 1 {
                return Value::Scalar(f64::NAN);
            }
            match crate::precision_infer::marker_precision(node) {
                Some(p) => {
                    let _guard = crate::precision::enter(p);
                    eval(&node.args[0], ctx)
                }
                None => eval(&node.args[0], ctx),
            }
        }

        // Unary / scalar transcendentals.
        "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil" | "sin"
        | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh" | "asinh"
        | "acosh" | "atanh" => eval_unary(op, &node.args, ctx),

        "atan2" => eval_binary(op, &node.args, ctx),

        // n-ary min/max (esm-spec §4.2 — arity ≥ 2). Reuse the n-ary
        // arithmetic combiner so array operands broadcast through the same
        // ndarray path as `+`/`*`.
        "min" | "max" => eval_arith(op, &node.args, ctx),

        // Comparison operators — return 1.0 (true) or 0.0 (false) via the same
        // [`scalar_compare`] kernel the vectorized overlay uses (bit-identity by
        // construction). BROADCAST when either operand is an array, so a per-cell
        // predicate like `code >= 1` over an [x,y] fuel grid yields an [x,y] mask
        // rather than collapsing to a scalar NaN.
        "==" | "!=" | "<" | "<=" | ">" | ">=" => {
            if node.args.len() != 2 {
                return Value::Scalar(f64::NAN);
            }
            eval_binary(op, &node.args, ctx)
        }

        // Logical connectives (esm-spec §4.2): nonzero is true, the result is a
        // strict 1.0/0.0 flag, broadcast over array operands like arithmetic —
        // e.g. `and(code >= 1, code <= 13)` over an [x,y] fuel grid.
        "and" | "or" => eval_arith(op, &node.args, ctx),
        "not" => eval_unary(op, &node.args, ctx),

        "ifelse" => eval_ifelse(node, ctx),

        // Derivative operator. Unreachable, and the sentinel says so.
        //
        // A right-hand-side `D` is resolved to a tendency by `flatten`'s phase
        // 5b′, or refused with `unlowered_operator` before any build (esm-spec
        // §4.2). §4.2 forbids inventing a value here, IN PARTICULAR `0`, which
        // passes an `expected: 0` assertion silently where `NaN` fails every
        // finite one.
        //
        // `D` must STAY in `is_evaluable_op` here (the single-expression
        // `check_scalar_evaluable` refuses it by name instead):
        // `check_evaluable_side` walks an equation's LHS and unwraps only
        // `ic`, so delisting `D` would reject every document that states a
        // differential equation. Teaching that gate to unwrap a structural `D`
        // LHS as it unwraps `ic` would let this arm go too.
        "D" => Value::Scalar(f64::NAN),

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
        "const" => eval_const_memo(node, ctx.const_lits),

        // Array ops.
        "index" => eval_index(node, ctx),
        "faq" => eval_faq(node, ctx),
        // Conservative-regridding geometry kernel (RFC §8.1): clip two lon/lat
        // polygon rings on the node's `manifold`, producing the overlap ring as
        // an `[N, 2]` array. `polygon_area` over it is an ordinary `faq`.
        "intersect_polygon" => eval_intersect_polygon(node, ctx),
        // Fused geometry leaf (esm-spec §4.2 / §8.6.1): the SCALAR overlap area of
        // the two polygon operands under the node's `manifold`, defined to equal
        // `polygon_area(intersect_polygon(a, b))` but with NO clip ring exposed.
        "polygon_intersection_area" => eval_polygon_intersection_area(node, ctx),
        "makearray" => eval_makearray(node, ctx),
        "reshape" => eval_reshape(node, ctx),
        "transpose" => eval_transpose(node, ctx),
        "concat" => eval_concat(node, ctx),

        // Element-wise application of the scalar operator named in `fn`
        // (esm-spec §4.3.4). Re-enter with that name against the SAME node —
        // see [`eval_op_named`]. Because the scalar-operator set excludes
        // `broadcast` itself, this recursion is one level deep.
        "broadcast" => eval_broadcast(node, ctx),

        // Closed-registry function call (esm-spec §9.2): `datetime.*` calendar
        // accessors and `interp.linear` / `interp.bilinear` tensor
        // interpolation. Routes to the shared `registered_functions` kernel —
        // the same one the Julia/Python bindings use — so a coupled model whose
        // observeds compute fuel/table lookups via `fn` evaluates identically
        // here (the fire stack's `FuelModelLookup` is the motivating case).
        "fn" => eval_fn(node, ctx),

        // The nullary boolean literal (esm-spec §4.2). This evaluator's boolean
        // convention is already 1.0 / 0.0 — every comparison and `and`/`or`/
        // `not` produces it — so the value is forced, not chosen, and it is
        // what Python (`numpy_interpreter`: `if op == "true": return 1.0`),
        // Julia (`geometry_compile.jl`: `_NK_LITERAL, literal=1.0`) and this
        // crate's own `value_invention::vi_eval` (`Val::Bool(true)`) already
        // produce. In a `sum_product` contraction it is the multiplicative
        // identity, so `faq{expr: true}` COUNTS the admitted tuples —
        // which is exactly what a semi-join wants to say.
        "true" => Value::Scalar(1.0),
        // Its counterpart, in the same encoding (a false comparison is 0.0).
        "false" => Value::Scalar(0.0),

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
    //
    // **Precision.** The fold BODY is `apply_binary`, which is already
    // precision-aware — but two things in this function are not, and both are
    // rounded here rather than left to the body:
    //
    // * the SEED. A one-element fold (`+` with a single operand, which
    //   `simulate::eval_op` does reach) returns `vs[0]` having applied no
    //   operator at all, so an unrounded seed would leave a binary64 value in a
    //   Float32 evaluation.
    // * the `and`/`or` truth test, which must ask whether the operand is zero
    //   *at the working precision* — `apply_binary`'s own `And`/`Or` arms
    //   narrow before comparing, and these two must agree with them.
    let prec = crate::precision::active();
    match op {
        "and" => return vs.iter().all(|&v| prec.round(v) != 0.0) as i32 as f64,
        "or" => return vs.iter().any(|&v| prec.round(v) != 0.0) as i32 as f64,
        _ => {}
    }
    rest.iter()
        .fold(prec.round(*first), |acc, &v| apply_binary(op, acc, v))
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
        // The array arms hoist the op-name lookup out of the element loop
        // (`binary_kernel_of` is pinned bit-for-bit to `apply_binary` by
        // `binary_kernels_match_apply_binary`).
        (Value::Scalar(x), Value::Array(ya)) => {
            let k = binary_kernel_of(BinCode::of(op));
            Value::Array(Box::new(ya.mapv(|y| k(x, y))))
        }
        (Value::Array(xa), Value::Scalar(y)) => {
            let k = binary_kernel_of(BinCode::of(op));
            Value::Array(Box::new(xa.mapv(|x| k(x, y))))
        }
        (Value::Array(xa), Value::Array(ya)) => {
            // Use ndarray broadcasting.
            Value::Array(Box::new(broadcast_binary(op, &xa, &ya)))
        }
    }
}

pub(crate) fn apply_binary(op: &str, x: f64, y: f64) -> f64 {
    // Under `element_type: "Float32"` the whole table is the binary32 one. The
    // Float64 arms below are untouched, so Float64 keeps the exact instruction
    // sequence it had — the branch is the only addition, and it is not taken.
    if crate::precision::is_f32() {
        return binary_kernel_f32_of(BinCode::of(op))(x, y);
    }
    match op {
        "+" => x + y,
        "-" => x - y,
        "*" => x * y,
        "/" => x / y,
        "^" | "pow" => x.powf(y),
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
#[cfg(test)] // only the `*_of` code-based form is on the hot path now;
// this `&str` wrapper survives solely for the bit-equality pinning test below.
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
            "^" | "pow" => BinCode::Pow,
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
///
/// Under [`crate::precision::Precision::Float32`] it returns the binary32
/// table ([`binary_kernel_f32_of`]) instead. Resolution happens ONCE per AST
/// node on the vectorized and taped paths (and once per cell on the oracle,
/// where the operator name is being matched anyway), so the mode read costs a
/// thread-local load where a string compare already lived — and the Float64
/// arms below are the identical closures they were before, so Float64 is
/// bit-unchanged by construction.
pub(crate) fn binary_kernel_of(op: BinCode) -> fn(f64, f64) -> f64 {
    if crate::precision::is_f32() {
        return binary_kernel_f32_of(op);
    }
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

/// [`binary_kernel_of`]'s table in **binary32**: each kernel narrows both
/// operands to `f32`, applies the `f32` operation, and widens the `f32` result.
///
/// The arms are [`binary_kernel_of`]'s arms with `f32` operands, in the same
/// order — `binary_kernels_f32_are_binary32` pins each one to the value the
/// same expression produces when it is written directly in `f32`.
///
/// Narrowing the operands is not redundant with the ingress rounding: it is
/// what makes the kernel *total*. Every value the evaluator produces in this
/// mode is already binary32-representable (so the narrowing is exact and the
/// widening is exact), and a value that somehow was not — a host-supplied array
/// this pass has not reached — is rounded here rather than computed in the
/// wrong precision.
///
/// Widening the result to `f64` is exact, so the `f64` carrier stores the
/// binary32 answer, bit for bit. For `+ - * /` this is also, by the
/// double-rounding-is-innocuous theorem (binary64 carries 53 bits ≥ 2·24 + 2),
/// identical to computing in `f64` and rounding once at the end; the elementary
/// functions are the reason the operands are narrowed explicitly rather than
/// relying on that — `expf` is not `exp` rounded.
pub(crate) fn binary_kernel_f32_of(op: BinCode) -> fn(f64, f64) -> f64 {
    match op {
        BinCode::Add => |x: f64, y: f64| ((x as f32) + (y as f32)) as f64,
        BinCode::Sub => |x: f64, y: f64| ((x as f32) - (y as f32)) as f64,
        BinCode::Mul => |x: f64, y: f64| ((x as f32) * (y as f32)) as f64,
        BinCode::Div => |x: f64, y: f64| ((x as f32) / (y as f32)) as f64,
        BinCode::Pow => |x: f64, y: f64| (x as f32).powf(y as f32) as f64,
        BinCode::Atan2 => |x: f64, y: f64| (x as f32).atan2(y as f32) as f64,
        BinCode::Min => |x: f64, y: f64| (x as f32).min(y as f32) as f64,
        BinCode::Max => |x: f64, y: f64| (x as f32).max(y as f32) as f64,
        // Comparisons and the logical flags are exact on binary32 operands and
        // return the same 1.0 / 0.0 flags, but they still narrow: comparing the
        // f64 carriers of two values that round to the SAME f32 must say equal.
        BinCode::Eq => |x: f64, y: f64| ((x as f32) == (y as f32)) as i32 as f64,
        BinCode::Ne => |x: f64, y: f64| ((x as f32) != (y as f32)) as i32 as f64,
        BinCode::Lt => |x: f64, y: f64| ((x as f32) < (y as f32)) as i32 as f64,
        BinCode::Le => |x: f64, y: f64| ((x as f32) <= (y as f32)) as i32 as f64,
        BinCode::Gt => |x: f64, y: f64| ((x as f32) > (y as f32)) as i32 as f64,
        BinCode::Ge => |x: f64, y: f64| ((x as f32) >= (y as f32)) as i32 as f64,
        BinCode::And => |x: f64, y: f64| ((x as f32) != 0.0 && (y as f32) != 0.0) as i32 as f64,
        BinCode::Or => |x: f64, y: f64| ((x as f32) != 0.0 || (y as f32) != 0.0) as i32 as f64,
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
    // Op-name lookup hoisted out of the element loop; the kernel table is
    // pinned bit-for-bit to `apply_binary`.
    let k = binary_kernel_of(BinCode::of(op));
    ndarray::Zip::from(&mut out)
        .and(&av)
        .and(&bv)
        .for_each(|o, &x, &y| {
            *o = k(x, y);
        });
    out
}

/// Julia-style broadcast shape alignment: pad the lower-rank shape with
/// *trailing* singleton dimensions so `(3,) + (1,3) → (3,3)`. This differs
/// from NumPy's right-alignment convention; the fixtures were authored in
/// Julia and expect this behavior (see
/// `fixtures/faq/14_broadcast_elementwise.esm`).
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
        Value::Array(a) => {
            // Op-name lookup hoisted out of the element loop; the kernel table
            // is pinned bit-for-bit to `apply_unary`.
            let k = unary_kernel_of(UnCode::of(op));
            Value::Array(Box::new(a.mapv(k)))
        }
    }
}

pub(crate) fn apply_unary(op: &str, x: f64) -> f64 {
    // See `apply_binary`: Float32 routes to the binary32 table, Float64 falls
    // through to the untouched arms below.
    if crate::precision::is_f32() {
        return unary_kernel_f32_of(UnCode::of(op))(x);
    }
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
#[cfg(test)] // see `binary_kernel` above: test-only pinning wrapper.
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
///
/// Under [`crate::precision::Precision::Float32`] it returns the binary32 table
/// ([`unary_kernel_f32_of`]) — see [`binary_kernel_of`] for why the mode read
/// sits here.
pub(crate) fn unary_kernel_of(op: UnCode) -> fn(f64) -> f64 {
    if crate::precision::is_f32() {
        return unary_kernel_f32_of(op);
    }
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

/// [`unary_kernel_of`]'s table in **binary32** — the unary counterpart of
/// [`binary_kernel_f32_of`], narrowing the operand and widening the result for
/// the same reasons.
///
/// The elementary functions call the `f32` libm entry points (`expf`, `logf`,
/// `sinf`, …), which is what an evaluator working in binary32 does; it is NOT
/// the binary64 function rounded afterwards, and the two differ in the last
/// ulp. That choice is the one a `real*4` reference implementation makes, and
/// it is the cross-binding contract this mode has to state explicitly — see
/// CONFORMANCE_SPEC §5.18.1.
pub(crate) fn unary_kernel_f32_of(op: UnCode) -> fn(f64) -> f64 {
    match op {
        UnCode::Exp => |x: f64| (x as f32).exp() as f64,
        UnCode::Ln => |x: f64| (x as f32).ln() as f64,
        UnCode::Log10 => |x: f64| (x as f32).log10() as f64,
        UnCode::Sqrt => |x: f64| (x as f32).sqrt() as f64,
        UnCode::Abs => |x: f64| (x as f32).abs() as f64,
        UnCode::Sign => |x: f64| {
            let x = x as f32;
            if x > 0.0 {
                1.0
            } else if x < 0.0 {
                -1.0
            } else {
                0.0
            }
        },
        UnCode::Floor => |x: f64| (x as f32).floor() as f64,
        UnCode::Ceil => |x: f64| (x as f32).ceil() as f64,
        UnCode::Sin => |x: f64| (x as f32).sin() as f64,
        UnCode::Cos => |x: f64| (x as f32).cos() as f64,
        UnCode::Tan => |x: f64| (x as f32).tan() as f64,
        UnCode::Asin => |x: f64| (x as f32).asin() as f64,
        UnCode::Acos => |x: f64| (x as f32).acos() as f64,
        UnCode::Atan => |x: f64| (x as f32).atan() as f64,
        UnCode::Sinh => |x: f64| (x as f32).sinh() as f64,
        UnCode::Cosh => |x: f64| (x as f32).cosh() as f64,
        UnCode::Tanh => |x: f64| (x as f32).tanh() as f64,
        UnCode::Asinh => |x: f64| (x as f32).asinh() as f64,
        UnCode::Acosh => |x: f64| (x as f32).acosh() as f64,
        UnCode::Atanh => |x: f64| (x as f32).atanh() as f64,
        UnCode::Not => |x: f64| ((x as f32) == 0.0) as i32 as f64,
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

    // -----------------------------------------------------------------------
    // `domain.element_type: "Float32"` (esm-spec §11.3).
    //
    // The pins above hold the two Float64 tables together. These hold the
    // binary32 tables to NATIVE `f32` arithmetic — the property the mode
    // claims — and hold the Float64 tables to plain `f64`, which is what makes
    // "Float64 is bit-unchanged" a checked statement rather than an assurance.
    // -----------------------------------------------------------------------

    /// Bit equality, with NaN counted equal to NaN (the tables produce NaN in
    /// several arms and `NaN != NaN` would make every such arm vacuous).
    fn same_bits(a: f64, b: f64) -> bool {
        (a.is_nan() && b.is_nan()) || a.to_bits() == b.to_bits()
    }

    /// A spread that exercises what binary32 does and binary64 does not:
    /// binary64 subnormals (flush to zero in f32), binary32 subnormals, a value
    /// that overflows f32's range, and the witness operands themselves.
    #[rustfmt::skip]
    const F32_XS: &[f64] = &[
        0.0, -0.0, 1.0, -1.0, 0.1, 0.5, -3.25, 2.0, 3.0, 26.5, 73.5, 100.0,
        1e-45, 5e-324, f64::MIN_POSITIVE, 1e38, 1e39, -1e39,
        f64::INFINITY, f64::NEG_INFINITY, f64::NAN,
    ];

    /// Under Float32 every binary kernel is the `f32` operation on `f32`
    /// operands — not the `f64` operation with a cast bolted on the end.
    #[test]
    fn binary_kernels_f32_are_binary32() {
        let _g = crate::precision::enter(crate::precision::Precision::Float32);
        for &x in F32_XS {
            for &y in F32_XS {
                let (xf, yf) = (x as f32, y as f32);
                #[rustfmt::skip]
                let cases: &[(&str, f64)] = &[
                    ("+", (xf + yf) as f64),
                    ("-", (xf - yf) as f64),
                    ("*", (xf * yf) as f64),
                    ("/", (xf / yf) as f64),
                    ("^", xf.powf(yf) as f64),
                    ("atan2", xf.atan2(yf) as f64),
                    ("min", xf.min(yf) as f64),
                    ("max", xf.max(yf) as f64),
                    ("==", (xf == yf) as i32 as f64),
                    ("!=", (xf != yf) as i32 as f64),
                    ("<", (xf < yf) as i32 as f64),
                    ("<=", (xf <= yf) as i32 as f64),
                    (">", (xf > yf) as i32 as f64),
                    (">=", (xf >= yf) as i32 as f64),
                    ("and", (xf != 0.0 && yf != 0.0) as i32 as f64),
                    ("or", (xf != 0.0 || yf != 0.0) as i32 as f64),
                ];
                for &(op, want) in cases {
                    let got = apply_binary(op, x, y);
                    assert!(
                        same_bits(got, want),
                        "apply_binary(\"{op}\", {x:?}, {y:?}) = {got:?}, want f32 {want:?}"
                    );
                    // The hoisted table the vectorized / taped paths resolve
                    // through must agree with the per-cell oracle.
                    let hoisted = binary_kernel_f32_of(BinCode::of(op))(x, y);
                    assert!(
                        same_bits(hoisted, want),
                        "binary_kernel_f32_of({op}) disagrees with apply_binary"
                    );
                }
            }
        }
    }

    /// The unary counterpart. `exp`/`log`/`sin`/… call the `f32` libm entry
    /// points, which is what an evaluator working in binary32 does — the
    /// binary64 function rounded afterwards is a DIFFERENT number in the last
    /// ulp, and this pins which of the two the mode means.
    #[test]
    fn unary_kernels_f32_are_binary32() {
        let _g = crate::precision::enter(crate::precision::Precision::Float32);
        for &x in F32_XS {
            let xf = x as f32;
            #[rustfmt::skip]
            let cases: &[(&str, f64)] = &[
                ("exp", xf.exp() as f64),
                ("log", xf.ln() as f64),
                ("ln", xf.ln() as f64),
                ("log10", xf.log10() as f64),
                ("sqrt", xf.sqrt() as f64),
                ("abs", xf.abs() as f64),
                ("floor", xf.floor() as f64),
                ("ceil", xf.ceil() as f64),
                ("sin", xf.sin() as f64),
                ("cos", xf.cos() as f64),
                ("tan", xf.tan() as f64),
                ("asin", xf.asin() as f64),
                ("acos", xf.acos() as f64),
                ("atan", xf.atan() as f64),
                ("sinh", xf.sinh() as f64),
                ("cosh", xf.cosh() as f64),
                ("tanh", xf.tanh() as f64),
                ("asinh", xf.asinh() as f64),
                ("acosh", xf.acosh() as f64),
                ("atanh", xf.atanh() as f64),
                ("not", (xf == 0.0) as i32 as f64),
            ];
            for &(op, want) in cases {
                let got = apply_unary(op, x);
                assert!(
                    same_bits(got, want),
                    "apply_unary(\"{op}\", {x:?}) = {got:?}, want f32 {want:?}"
                );
                let hoisted = unary_kernel_f32_of(UnCode::of(op))(x);
                assert!(
                    same_bits(hoisted, want),
                    "unary_kernel_f32_of({op}) disagrees with apply_unary"
                );
            }
        }
    }

    /// **Float64 is bit-unchanged.** With no guard armed, every kernel is the
    /// plain `f64` expression it always was — so the precision branch added to
    /// `apply_binary` / `apply_unary` / the two `*_kernel_of` tables cannot have
    /// perturbed the default path.
    #[test]
    fn float64_kernels_are_bit_identical_to_plain_f64() {
        assert_eq!(
            crate::precision::active(),
            crate::precision::Precision::Float64,
            "Float64 is the default and must need no guard"
        );
        for &x in F32_XS {
            for &y in F32_XS {
                #[rustfmt::skip]
                let cases: &[(&str, f64)] = &[
                    ("+", x + y), ("-", x - y), ("*", x * y), ("/", x / y),
                    ("^", x.powf(y)), ("atan2", x.atan2(y)),
                    ("min", x.min(y)), ("max", x.max(y)),
                    ("==", (x == y) as i32 as f64), ("!=", (x != y) as i32 as f64),
                    ("<", (x < y) as i32 as f64), ("<=", (x <= y) as i32 as f64),
                    (">", (x > y) as i32 as f64), (">=", (x >= y) as i32 as f64),
                    ("and", (x != 0.0 && y != 0.0) as i32 as f64),
                    ("or", (x != 0.0 || y != 0.0) as i32 as f64),
                ];
                for &(op, want) in cases {
                    assert!(
                        same_bits(apply_binary(op, x, y), want),
                        "apply_binary(\"{op}\", {x:?}, {y:?}) drifted from plain f64"
                    );
                }
            }
            #[rustfmt::skip]
            let un: &[(&str, f64)] = &[
                ("exp", x.exp()), ("log", x.ln()), ("log10", x.log10()),
                ("sqrt", x.sqrt()), ("abs", x.abs()), ("floor", x.floor()),
                ("ceil", x.ceil()), ("sin", x.sin()), ("cos", x.cos()),
                ("tan", x.tan()), ("tanh", x.tanh()),
            ];
            for &(op, want) in un {
                assert!(
                    same_bits(apply_unary(op, x), want),
                    "apply_unary(\"{op}\", {x:?}) drifted from plain f64"
                );
            }
        }
    }

    /// The witness expression, evaluated through the kernels the whole
    /// evaluator shares. `1.0` here would mean the mode is not reaching them.
    #[test]
    fn the_witness_expression_rounds_per_operation() {
        let expr = |h: f64, s: f64| {
            let num = apply_binary("*", h, apply_binary("/", apply_binary("-", h, s), h));
            apply_binary("/", num, apply_binary("-", h, s))
        };
        assert_eq!(expr(100.0, 73.5).to_bits(), 1.0_f64.to_bits());
        let _g = crate::precision::enter(crate::precision::Precision::Float32);
        assert_eq!(
            expr(100.0, 73.5).to_bits(),
            (0.99999994_f32 as f64).to_bits(),
            "the Float32 kernels must reproduce the binary32 answer"
        );
    }

    /// `fold_scalar`'s SEED rounds too: a one-operand fold applies no operator,
    /// so an unrounded seed would leave a binary64 value in a Float32 result.
    #[test]
    fn fold_scalar_rounds_its_seed() {
        let _g = crate::precision::enter(crate::precision::Precision::Float32);
        assert_eq!(
            fold_scalar("+", &[0.1]).to_bits(),
            (0.1_f32 as f64).to_bits()
        );
        // And the n-ary fold is the repeated binary32 apply.
        let want = ((0.1_f32 + 0.2_f32) + 0.3_f32) as f64;
        assert_eq!(fold_scalar("+", &[0.1, 0.2, 0.3]).to_bits(), want.to_bits());
    }

    /// A `const` literal is raw JSON, not an `Expr::Number`, so it is the one
    /// numeric ingress the literal rule does not reach — and a const ARRAY
    /// would then serve binary64 elements to every gather on it.
    #[test]
    fn const_literals_round_on_materialization() {
        let _g = crate::precision::enter(crate::precision::Precision::Float32);
        let scalar = json_to_value(&serde_json::json!(0.1)).expect("scalar const");
        match scalar {
            Value::Scalar(s) => assert_eq!(s.to_bits(), (0.1_f32 as f64).to_bits()),
            other => panic!("expected a scalar, got {other:?}"),
        }
        let arr = json_to_value(&serde_json::json!([0.1, 0.2])).expect("array const");
        match arr {
            Value::Array(a) => {
                assert_eq!(a[[0]].to_bits(), (0.1_f32 as f64).to_bits());
                assert_eq!(a[[1]].to_bits(), (0.2_f32 as f64).to_bits());
            }
            other => panic!("expected an array, got {other:?}"),
        }
    }

    /// The inline-`const` memo must answer with exactly what the walk produces,
    /// on the first read and on every later one — it is a pure
    /// evaluation-count change, never a value change.
    #[test]
    fn const_literal_memo_matches_the_direct_walk() {
        let node = ExpressionNode {
            op: "const".to_string(),
            value: Some(serde_json::json!([[1.5, -2.5], [3.25, 4.75]])),
            ..Default::default()
        };
        let want = match json_to_value(node.value.as_ref().unwrap()).expect("array const") {
            Value::Array(a) => *a,
            other => panic!("expected an array, got {other:?}"),
        };
        let memo = ConstLitMemo::default();
        let first = memo.get(&node).expect("memoized array");
        assert_eq!(*first, want);
        for _ in 0..3 {
            let got = memo.get(&node).expect("memoized array");
            assert_eq!(*got, want);
            // Same allocation, not an equal one: a later read is served from
            // the table rather than re-walking the payload.
            assert!(std::rc::Rc::ptr_eq(&first, &got));
        }
        // And the memo-aware `const` arm agrees with the un-memoized one.
        match (
            eval_const_memo(&node, Some(&memo)),
            eval_const_memo(&node, None),
        ) {
            (Value::Array(a), Value::Array(b)) => assert_eq!(*a, *b),
            other => panic!("expected two arrays, got {other:?}"),
        }
    }

    /// The memo is keyed by working precision as well as by node, because a
    /// `const` literal rounds on ingress (esm-spec §11.3.1): one node has two
    /// materializations and serving the wrong one would silently widen a
    /// binary32 document back to binary64.
    #[test]
    fn const_literal_memo_is_keyed_by_precision() {
        let node = ExpressionNode {
            op: "const".to_string(),
            value: Some(serde_json::json!([0.1, 0.2])),
            ..Default::default()
        };
        let memo = ConstLitMemo::default();
        let f64_first = memo.get(&node).expect("binary64 array")[[0]];
        let f32_seen = {
            let _g = crate::precision::enter(crate::precision::Precision::Float32);
            memo.get(&node).expect("binary32 array")[[0]]
        };
        let f64_again = memo.get(&node).expect("binary64 array again")[[0]];
        assert_eq!(f64_first.to_bits(), 0.1_f64.to_bits());
        assert_eq!(f32_seen.to_bits(), (0.1_f32 as f64).to_bits());
        assert_eq!(f64_again.to_bits(), f64_first.to_bits());
    }

    /// A ragged literal has no array materialization; the memo must report that
    /// as the NaN sentinel the plain walk reports, not cache a partial array.
    #[test]
    fn const_literal_memo_keeps_a_ragged_literal_unevaluable() {
        let node = ExpressionNode {
            op: "const".to_string(),
            value: Some(serde_json::json!([[1.0, 2.0], [3.0]])),
            ..Default::default()
        };
        let memo = ConstLitMemo::default();
        assert!(memo.get(&node).is_none());
        for m in [Some(&memo), None] {
            match eval_const_memo(&node, m) {
                Value::Scalar(s) => assert!(s.is_nan()),
                other => panic!("expected the NaN sentinel, got {other:?}"),
            }
        }
    }

    /// Entries are keyed by node ADDRESS, so a scratch handed a different rule
    /// set must drop them: a later node can land on an address the previous
    /// rule set used, and serving that node the old array would put a whole
    /// different lookup table under a gather. `retarget` to a new key must
    /// therefore leave nothing behind; re-binding the SAME key must not throw
    /// the table away on every call.
    #[test]
    fn const_literal_memo_is_dropped_when_the_rule_set_changes() {
        let node = ExpressionNode {
            op: "const".to_string(),
            value: Some(serde_json::json!([1.0, 2.0, 3.0])),
            ..Default::default()
        };
        let memo = ConstLitMemo::default();
        memo.retarget(0x1234);
        let first = memo.get(&node).expect("memoized array");
        assert!(std::rc::Rc::ptr_eq(
            &first,
            &memo.get(&node).expect("same rule set, same entry")
        ));
        // Re-binding the same key keeps the table.
        memo.retarget(0x1234);
        assert!(std::rc::Rc::ptr_eq(
            &first,
            &memo.get(&node).expect("same key, same entry")
        ));
        // A different key drops it: the next read is a fresh materialization.
        memo.retarget(0x5678);
        let after = memo.get(&node).expect("rebuilt array");
        assert!(!std::rc::Rc::ptr_eq(&first, &after));
        assert_eq!(*after, *first);
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

thread_local! {
    /// How many `faq` nodes this thread has evaluated by walking the body once
    /// per cell (or once per contracted term) rather than through the
    /// whole-array overlay. See [`per_cell_walks`].
    static PER_CELL_WALKS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// The running count of per-cell `faq` walks on this thread: the number of
/// times [`eval_faq`] took its per-cell branch (a prefix scan, the output-tuple
/// loop, or a rank-0 contraction folded term by term) because the whole-array
/// overlay did not take the node.
///
/// The routes that evaluate a document through this evaluator OUTSIDE the
/// compiled rule set — the build pipeline's observed graph, a field initial
/// condition — read the delta across one evaluation to learn whether it was
/// interpreted per cell, which is what a strict compiler refuses
/// (esm-libraries-spec §2.5.10). A counter rather than a flag, so a nested
/// evaluation cannot clear what an enclosing one recorded.
pub(crate) fn per_cell_walks() -> u64 {
    PER_CELL_WALKS.with(std::cell::Cell::get)
}

fn note_per_cell_walk() {
    PER_CELL_WALKS.with(|c| c.set(c.get().wrapping_add(1)));
}

#[cfg(test)]
thread_local! {
    static PER_CELL_CELLS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Test hook: how many cells the per-cell walks on this thread have
/// evaluated (a prefix-scan step, an output tuple, a recurrence cell).
#[cfg(test)]
pub(crate) fn per_cell_cells() -> u64 {
    PER_CELL_CELLS.with(std::cell::Cell::get)
}

#[inline]
pub(super) fn note_per_cell_cell() {
    #[cfg(test)]
    PER_CELL_CELLS.with(|c| c.set(c.get() + 1));
}

/// The state of a [`StopAtFirstCell`] on this thread.
#[derive(Clone, Copy, Default)]
struct FirstCellStop {
    /// A strict caller is listening: a per-cell walk stops after its first cell.
    armed: bool,
    /// A walk has stopped. Every value computed since is a placeholder.
    stopped: bool,
    /// A document error (a latched out-of-range gather) was already pending
    /// when the walk stopped, so the evaluation fails with it rather than being
    /// refused.
    with_error: bool,
}

thread_local! {
    static FIRST_CELL_STOP: std::cell::Cell<FirstCellStop> = const {
        std::cell::Cell::new(FirstCellStop { armed: false, stopped: false, with_error: false })
    };
}

/// Stop every per-cell walk at its first cell, for as long as this guard
/// lives.
///
/// A strict compiler refuses an evaluation the reference evaluator walks per
/// cell, so the rest of such a walk is work whose only product is a refusal —
/// on a gate-driven join over a million cells, minutes of it. Armed around the
/// evaluation, the first `faq` that goes per cell evaluates ONE cell, for its
/// diagnostic only (a body no route can evaluate is the document's error, and
/// an out-of-range gather in it must still say so), and stops; every walk
/// after it stops before its first cell. The evaluation's value is then a
/// placeholder, and [`per_cell_walk_refused`] tells the caller to discard it
/// and refuse.
///
/// The stop is taken exactly where [`per_cell_walks`] counts a walk, so
/// whether a refusal happens, and its reason, are what a full walk would have
/// given; only the work behind them is gone.
pub(crate) struct StopAtFirstCell(FirstCellStop);

impl StopAtFirstCell {
    pub(crate) fn arm() -> Self {
        StopAtFirstCell(FIRST_CELL_STOP.with(|c| {
            c.replace(FirstCellStop {
                armed: true,
                ..FirstCellStop::default()
            })
        }))
    }

    /// Whether any per-cell walk stopped under this guard, error or not: what
    /// was computed is not the whole answer.
    pub(crate) fn stopped(&self) -> bool {
        FIRST_CELL_STOP.with(|c| c.get().stopped)
    }
}

impl Drop for StopAtFirstCell {
    fn drop(&mut self) {
        FIRST_CELL_STOP.with(|c| c.set(self.0));
    }
}

/// What a refusal raised from a walk [`StopAtFirstCell`] stopped says after its
/// reason, in the words the Julia binding uses for its own: the cells the walk
/// did not evaluate may still hold a document error (an out-of-range gather at
/// the last cell of a prefix scan), and only the interpreter would find it.
pub(crate) const ONE_CELL_NOTE: &str = "only one cell of it was evaluated before this refusal, \
    so a document error in a cell that was not (an out-of-range gather at the last cell, say) \
    is not reported here; the interpreter evaluates every cell and reports it";

/// Whether a per-cell walk on this thread stopped under a [`StopAtFirstCell`]
/// with no document error pending, so that what was computed since — a value,
/// or an error raised by reading a placeholder — is not the document's, and
/// the evaluation is refused.
pub(crate) fn per_cell_walk_refused() -> bool {
    let s = FIRST_CELL_STOP.with(std::cell::Cell::get);
    s.stopped && !s.with_error
}

/// Whether a per-cell walk has already stopped on this thread, so the next
/// one need not evaluate even its first cell.
fn per_cell_walk_stopped() -> bool {
    FIRST_CELL_STOP.with(|c| c.get().stopped)
}

/// Whether a [`StopAtFirstCell`] is armed on this thread.
fn stop_at_first_cell() -> bool {
    FIRST_CELL_STOP.with(|c| c.get().armed)
}

/// Called after a per-cell walk's first cell. Under an armed
/// [`StopAtFirstCell`] it records the stop, and whether that cell latched a
/// document error, and answers `true`: the walk ends here.
pub(super) fn stop_after_first_cell() -> bool {
    FIRST_CELL_STOP.with(|c| {
        let mut s = c.get();
        if !s.armed {
            return false;
        }
        if !s.stopped {
            s.stopped = true;
            s.with_error = CONST_OOB.with(|l| l.borrow().is_some());
            c.set(s);
        }
        true
    })
}

thread_local! {
    /// First `E_TREEWALK_CONSTARRAY_OOB` raised during the current evaluation.
    ///
    /// The tree walk returns a bare [`Value`] with no error channel, so an
    /// out-of-range CONST-ARRAY gather latches its diagnostic here and yields
    /// `NaN`; the public entry points ([`eval_expression_with_extents_and_consts`])
    /// drain the latch and report it. This is the same "fail closed, do not
    /// silently substitute a number" contract the Julia reference gets from
    /// `throw` and Python from raising.
    static CONST_OOB: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// Take (and clear) the pending fail-closed gather diagnostic, if any.
///
/// Named for the first fault that used this channel
/// (`E_TREEWALK_CONSTARRAY_OOB`); it now also carries
/// `E_TREEWALK_RECUR_UNAVAILABLE` (CONFORMANCE_SPEC §5.19.4),
/// `E_TREEWALK_UNBOUND_NAME` / `E_TREEWALK_UNRESOLVED_ORDER` (§5.23) and
/// `E_TREEWALK_INDEX_ON_SCALAR` (§7.1). All of them are "fail closed, do not
/// silently substitute a number" faults with the same drain sites, so they
/// share one latch rather than adding a second one that a future drain site
/// could forget.
pub fn take_const_array_oob() -> Option<String> {
    CONST_OOB.with(|c| c.borrow_mut().take())
}

/// Latch the FIRST fail-closed gather diagnostic of this evaluation.
fn latch_gather_fault(msg: String) {
    CONST_OOB.with(|c| {
        let mut slot = c.borrow_mut();
        if slot.is_none() {
            *slot = Some(msg);
        }
    });
}

/// Latch an unavailable causal self-read (esm-spec §4.3.1.1): the position is
/// outside the recurrence axis, or names a cell the sweep has not published.
fn latch_recur_unavailable(name: &str, raw: &[i64]) {
    let at = raw
        .iter()
        .map(|i| i.to_string())
        .collect::<Vec<_>>()
        .join(",");
    latch_gather_fault(format!(
        "E_TREEWALK_RECUR_UNAVAILABLE: causal self-read of '{name}' at cell [{at}] is not \
         available — the position is outside the recurrence axis, or the sweep has not \
         published that cell yet (esm-spec §4.3.1.1; CONFORMANCE_SPEC.md §5.19.4: a causal \
         self-read is fail-closed, never the §5.5.5 zero ghost and never a NaN a `max(x, 0)` \
         could launder). Guard the base case inside the body, e.g. \
         `ifelse(k <= 1, <base>, <recurrence>)`."
    ));
}

/// Latch a subscript applied to a value that has NO axes (esm-spec §4.3.4: a
/// scalar declares no index sets).
///
/// `index(x)` with no subscript is the identity and never reaches here; this is
/// `index(x, i, …)` where `x` turned out to be 0-D, so the subscripts name
/// nothing there is to name. The alternative is the NaN this used to return,
/// and a NaN is laundered by any `max(x, 0)`, `ifelse` or comparison the body
/// goes on to apply — the document then reports a number that was never
/// computed.
fn latch_index_on_scalar(base: &Expr, subscripts: usize) {
    let what = match base {
        Expr::Variable(name) => format!("'{name}'"),
        Expr::Operator(node) => format!("the `{}` result", node.op),
        Expr::Integer(_) | Expr::Number(_) => "a numeric literal".to_string(),
    };
    latch_gather_fault(format!(
        "E_TREEWALK_INDEX_ON_SCALAR: {what} has no axes, so the {subscripts} subscript(s) \
         applied to it name nothing (esm-spec §4.3.4; CONFORMANCE_SPEC.md §7.1). Fail-closed: \
         never the §5.5.5 zero ghost, which is the boundary convention for a gather that HAS \
         an axis to fall outside of, and never a bare NaN. Read an unshaped quantity by its \
         bare name or as `index(<name>)` with no subscript, or give it a `shape` if it was \
         meant to have axes."
    ));
}

/// Latch the FIRST const-array out-of-range diagnostic of this evaluation.
fn latch_const_oob(name: &str, one_based: i64, n: i64, d: usize) {
    latch_gather_fault(format!(
        "E_TREEWALK_CONSTARRAY_OOB: const array '{name}' index {one_based} out of range \
         1..{n} in dim {d} (CONFORMANCE_SPEC.md §5.5.5: the zero-ghost convention is \
         never applied to a const-array gather; declare a per-dimension boundary policy \
         to resolve it as `periodic` or `clamp`)"
    ));
}

/// The out-of-range boundary policy of the gather being resolved
/// (CONFORMANCE_SPEC §5.5.5).
///
/// Splitting the OOB branch by PROVENANCE is the whole point: the
/// homogeneous-Dirichlet zero ghost is the STATE-variable gather's boundary
/// default (a stencil may read `u[i-1]` at `i = 1`), and §5.5.5 says it is
/// **never** applied to a const-array gather, where an out-of-range index into a
/// Fornberg weight table or a connectivity array is a bug, not a boundary.
#[derive(Clone, Copy)]
pub(super) enum GatherKind<'a> {
    /// State / observed gather: out-of-range ⇒ `0.0`.
    ZeroGhost,
    /// Const-array gather: out-of-range ⇒ the factor's declared per-dimension
    /// policy, defaulting to `E_TREEWALK_CONSTARRAY_OOB`.
    ConstArray {
        /// The factor's name, for the diagnostic.
        name: &'a str,
        /// The registry carrying its declared per-dimension policies.
        scope: &'a ConstArrayScope,
    },
}

/// Sample `arr` at the 1-based `raw` indices (fewer indices than the rank ⇒ a
/// fixed-leading-axes sub-array). `in_bounds` seeds the bound flag (`false` if
/// an index expression was non-scalar).
///
/// An out-of-range index resolves per `kind` (CONFORMANCE_SPEC §5.5.5):
/// [`GatherKind::ZeroGhost`] yields `0.0` (homogeneous Dirichlet ghost cells),
/// while [`GatherKind::ConstArray`] wraps (`periodic`), edge-extends (`clamp`),
/// or fails closed with `E_TREEWALK_CONSTARRAY_OOB`.
///
/// Shared by the borrowing fast path and the general path.
pub(super) fn index_into(
    arr: &ArrayD<f64>,
    raw: &[i64],
    mut in_bounds: bool,
    kind: GatherKind<'_>,
) -> Value {
    // Stack-inlined index buffer (array rank ≤ 4) — no per-node heap allocation.
    let mut indices: DimU = SmallVec::with_capacity(raw.len());
    for (d, &one_based) in raw.iter().enumerate() {
        let dim_size = arr.shape().get(d).copied().unwrap_or(0) as i64;
        let mut resolved = one_based;
        if one_based < 1 || one_based > dim_size {
            match kind {
                GatherKind::ZeroGhost => in_bounds = false,
                GatherKind::ConstArray { name, scope } => {
                    // An empty dimension can never be wrapped or clamped into a
                    // valid 1-based index — always the error, whatever the policy.
                    match (dim_size >= 1).then(|| scope.boundary(name, d)) {
                        // 1-based periodic wrap == Julia `mod1(i, n)`.
                        Some(BoundaryKind::Periodic) => {
                            resolved = (one_based - 1).rem_euclid(dim_size) + 1;
                        }
                        Some(BoundaryKind::Clamp) => {
                            resolved = one_based.clamp(1, dim_size);
                        }
                        Some(BoundaryKind::Error) | None => {
                            latch_const_oob(name, one_based, dim_size, d);
                            return Value::Scalar(f64::NAN);
                        }
                    }
                }
            }
        }
        indices.push((resolved - 1).max(0) as usize);
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
    // CAUSAL SELF-READ (esm-spec §4.3.1.1). Checked before every other channel:
    // during the sweep the array being defined exists nowhere else, and unlike
    // every other gather this one FAILS CLOSED out of range rather than
    // resolving to the §5.5.5 zero ghost. `ctx.recur` is `None` on every path
    // but a recurrence sweep, so this is one `Option` test for every other
    // document.
    if let Some(scope) = ctx.recur
        && matches!(&node.args[0], Expr::Variable(name) if name == scope.name)
    {
        let (raw, in_bounds) = eval_index_args(&node.args[1..], ctx);
        if !in_bounds {
            latch_recur_unavailable(scope.name, &raw);
            return Value::Scalar(f64::NAN);
        }
        return match scope.read(&raw) {
            Some(v) => Value::Scalar(crate::precision::active().round(v)),
            None => {
                latch_recur_unavailable(scope.name, &raw);
                Value::Scalar(f64::NAN)
            }
        };
    }
    if let Expr::Variable(name) = &node.args[0]
        && lookup_array_ref(name, ctx).is_some()
    {
        let (raw, in_bounds) = eval_index_args(&node.args[1..], ctx);
        let kind = gather_kind(name, ctx);
        if let Some(arr) = lookup_array_ref(name, ctx) {
            return index_into(arr, &raw, in_bounds, kind);
        }
    }
    // Inline `const` array literal as the gather target (esm-spec §4.3.3). Read
    // the one element straight out of the memoized array: the generic path below
    // re-walks the node's JSON payload and copies the whole table into a `Value`
    // for every single cell, which on a transcribed lookup table (an RRTM
    // k-distribution band is ~14k numbers, gathered once per level per g-point)
    // is the dominant cost of the whole right-hand side. The provenance
    // (`INLINE_CONST_NAME`), the out-of-range policy and `index_into` itself are
    // the ones the generic path would have used, so the result is bit-identical.
    //
    // Evaluating the subscripts after the literal rather than before is likewise
    // unobservable: a `const` node reads nothing and latches nothing.
    if let Expr::Operator(lit) = &node.args[0]
        && lit.op == "const"
        && is_inline_const_array(lit)
        && let Some(arr) = const_lit_array(lit, ctx.const_lits)
    {
        let (raw, in_bounds) = eval_index_args(&node.args[1..], ctx);
        return index_into(
            &arr,
            &raw,
            in_bounds,
            GatherKind::ConstArray {
                name: INLINE_CONST_NAME,
                scope: ctx.const_arrays,
            },
        );
    }

    // The gather's PROVENANCE is decided by the operand itself: a named const
    // factor, or a `const` literal written inline (esm-spec §4.3.3). A computed
    // array operand (`index(reshape(...), i)`) is never a const-array gather.
    let const_kind = match &node.args[0] {
        Expr::Variable(name) => gather_kind(name, ctx),
        base if ConstArrayScope::is_inline_const(base) => GatherKind::ConstArray {
            name: INLINE_CONST_NAME,
            scope: ctx.const_arrays,
        },
        _ => GatherKind::ZeroGhost,
    };
    let array_val = eval(&node.args[0], ctx);
    let arr = match array_val {
        Value::Array(a) => a,
        // `index(x)` with no subscript is the identity: the gather spelling for
        // reading a 0-D quantity.
        Value::Scalar(s) if node.args.len() == 1 => return Value::Scalar(s),
        // Subscripts on a 0-D value. This fails closed rather than answering a
        // number no cell holds; Python's interpreter refuses the same shape
        // ("index applied to scalar value").
        Value::Scalar(_) => {
            latch_index_on_scalar(&node.args[0], node.args.len() - 1);
            return Value::Scalar(f64::NAN);
        }
    };
    // Out-of-bounds accesses return 0.0 — homogeneous Dirichlet ghost-cell
    // semantics: a discretized PDE's stencil can reference u[i-1] when i=1
    // (ghost cell at i=0) and the boundary condition is u=0.
    let (raw, in_bounds) = eval_index_args(&node.args[1..], ctx);
    index_into(&arr, &raw, in_bounds, const_kind)
}

/// Which boundary convention a gather on `name` obeys: the const-array policy
/// when the evaluation's registry lists it, else the state gather's zero ghost.
///
/// The borrow is tied to `ctx`, not to the (later, mutable) array borrow, so
/// this is resolved before either `lookup_array_ref` or `eval` is called.
fn gather_kind<'a>(name: &'a str, ctx: &EvalCtx<'a>) -> GatherKind<'a> {
    if ctx.const_arrays.is_const(name) {
        GatherKind::ConstArray {
            name,
            scope: ctx.const_arrays,
        }
    } else {
        GatherKind::ZeroGhost
    }
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

/// [`eval_const`] served from the inline-literal memo when one is in scope.
///
/// Only the ARRAY case is memoized: a scalar literal is one `as_f64`, while an
/// array literal is a recursive JSON walk over (for a transcribed lookup table)
/// tens of thousands of numbers. The value is identical either way — the memo
/// stores exactly what [`json_to_value`] produced — so this is a pure
/// evaluation-count change. See [`EvalCtx::const_lits`].
pub(super) fn eval_const_memo(node: &ExpressionNode, memo: Option<&ConstLitMemo>) -> Value {
    // With no memo in scope there is nothing to serve from, and going through
    // one would only add a copy: fall straight through to the plain walk.
    if let Some(memo) = memo
        && is_inline_const_array(node)
        && let Some(arr) = memo.get(node)
    {
        return Value::Array(Box::new((*arr).clone()));
    }
    eval_const(node)
}

/// Whether this `const` node's payload is a (possibly nested) JSON array — the
/// literals the memo covers. A scalar payload takes the untouched path.
#[inline]
pub(super) fn is_inline_const_array(node: &ExpressionNode) -> bool {
    matches!(node.value.as_ref(), Some(serde_json::Value::Array(_)))
}

/// Convert an inline JSON literal to a runtime [`Value`]: a number → scalar; a
/// (possibly nested) numeric array → a row-major dynamic-rank array. `None` for
/// a non-numeric leaf or a ragged literal (a row whose length disagrees with its
/// siblings), so a malformed `const` surfaces as the NaN sentinel.
pub(super) fn json_to_value(v: &serde_json::Value) -> Option<Value> {
    use serde_json::Value as J;
    // A `const` literal is the one numeric ingress that does NOT arrive as an
    // `Expr::Number` — it is raw JSON hanging off the node — so it would keep
    // its binary64 value through a Float32 evaluation, and a const ARRAY would
    // then serve binary64 elements to every gather on it. Round here, once, at
    // the point of materialization. Identity under Float64.
    let prec = crate::precision::active();
    match v {
        J::Number(n) => Some(Value::Scalar(prec.round(n.as_f64()?))),
        J::Array(_) => {
            let mut shape: Vec<usize> = Vec::new();
            let mut flat: Vec<f64> = Vec::new();
            collect_json_array(v, 0, &mut shape, &mut flat)?;
            if prec.is_f32() {
                for x in &mut flat {
                    *x = prec.round(*x);
                }
            }
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
            // downstream `faq` over a `kind:"derived"` index set
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
/// the array evaluator — in particular the M1 `faq` machinery in
/// [`eval_faq`]. This is the entry point for computing a `polygon_area`
/// `sum_product` FAQ over an `intersect_polygon` ring (RFC §8.1): supply the
/// clipped ring (and any companion arrays the integrand references) in `inputs`
/// with the aggregate's `clip_ring` range already resolved to a concrete
/// `[1, N]` interval, and the body is reduced exactly as any other `faq`.
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
        crate::faq::empty_derived_extents(),
    )
}

/// [`eval_expression`] with the build-time **value-invention derived extents**
/// in hand — the standalone evaluator's counterpart of
/// [`crate::faq::resolve_aggregate_ranges_with_extents`].
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
    eval_expression_with_extents_and_consts(
        expr,
        inputs,
        params,
        param_names,
        t,
        derived_extents,
        ConstArrayScope::empty(),
    )
}

/// [`eval_expression_with_extents`] with an explicit CONST-ARRAY registry
/// (CONFORMANCE_SPEC §5.5.5).
///
/// A gather whose target is named in `const_arrays` is a const-array gather: an
/// out-of-range index resolves by that factor's declared per-dimension boundary
/// policy, and — with no declared policy — raises `E_TREEWALK_CONSTARRAY_OOB`
/// instead of silently reading the state gather's zero ghost. Every other
/// gather keeps the zero-ghost convention, so passing
/// [`ConstArrayScope::empty`] is byte-identical to the pre-§5.5.5 evaluator.
pub fn eval_expression_with_extents_and_consts(
    expr: &Expr,
    inputs: &HashMap<String, ArrayD<f64>>,
    params: &[f64],
    param_names: &[String],
    t: f64,
    derived_extents: &HashMap<String, i64>,
    const_arrays: &ConstArrayScope,
) -> Result<Value, CompileError> {
    // Cold public boundary: the standalone evaluator's `inputs` arrive as a std
    // `HashMap` (FAQ rings, coordinate fields). Rehash into the fast [`ArrMap`]
    // the interpreter uses so the per-node tree walk gets the fast lookups. The
    // input maps are small here (a clipped ring, a couple of coordinate arrays)
    // and this runs once per call (per-cell IC recompute was removed — see
    // `resolve_field_ics`), so the shallow re-map is negligible. Hot in-crate
    // callers whose maps carry provider slabs must NOT take this boundary —
    // prepare's observed-graph loop holds an [`ArrMap`] and calls the shared
    // variant below, because deep-cloning a map that holds fifteen
    // hundreds-of-MB SR slabs once per observed dominated the whole build
    // (measured: ~87% of a warm ISRM prepare was memmove).
    let inputs: ArrMap = inputs.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    eval_expression_with_extents_and_consts_shared(
        expr,
        &inputs,
        params,
        param_names,
        t,
        derived_extents,
        const_arrays,
    )
}

/// [`eval_expression_with_extents_and_consts`] minus the input-map rehash: the
/// caller already holds the interpreter's own [`ArrMap`] and the arrays are
/// borrowed for the duration of the call, byte-identically — no copy of any
/// input array is made.
/// Evaluate one observed that is a CAUSAL SELF-REFERENCE (esm-spec §4.3.1.1),
/// or report that it is not one.
///
/// `None` — `expr` contains no `index(name, …)` self-read, so the caller
/// evaluates it exactly as it did before this existed. `Some(Ok(_))` — the
/// sequential sweep ran and this is the finished array. `Some(Err(_))` — the
/// self-read is there but is not a well-founded causal read, or a read reached
/// a cell the sweep had not published.
///
/// **Why this exists on the build-pipeline path at all.** A recurrence has two
/// evaluation routes in this runtime: the per-step observed materialization,
/// and the build pipeline that materializes a relational document's whole
/// observed graph up front. The construct originally implemented only the
/// first, so it evaluated correctly under `esm test` and was DEAD wherever the
/// pipeline build was taken — which is any document that ingests, and every
/// document under `esm simulate`. Dead silently: the self-read fell through to
/// an unbound-name `NaN`, and a body containing `max(x, 0)` — which the
/// motivating fold's body is — turned that `NaN` into `0.0`, because IEEE-754
/// `max` returns the non-NaN operand. The result was finite, plausible,
/// monotone and wrong, with nothing logged at any level.
///
/// So this is not a second implementation. It resolves the frame with the same
/// [`lower_recurrence`] the compiled path uses and runs the same
/// [`sweep_recurrence`]; only the surrounding environment differs.
#[allow(clippy::too_many_arguments)]
pub(crate) fn eval_observed_recurrence(
    name: &str,
    expr: &Expr,
    inputs: &ArrMap,
    params: &[f64],
    param_names: &[String],
    t: f64,
    derived_extents: &HashMap<String, i64>,
    const_arrays: &ConstArrayScope,
) -> Option<Result<ArrayD<f64>, CompileError>> {
    // Cheap structural test first: no self-read, nothing to do, and every
    // document that does not use the construct pays one expression walk.
    if !expr_reads_self(expr, name) {
        return None;
    }
    let lhs = Expr::Variable(name.to_string());
    let lowered = match super::compile::lower_recurrence(name, &lhs, expr) {
        Ok(Some(l)) => l,
        // A self-read the lowering does not recognize as a recurrence. It must
        // NOT fall through to a wholesale evaluation, which is what laundered
        // it into a plausible number before.
        Ok(None) => {
            return Some(Err(CompileError::InterpreterBuildError {
                details: format!(
                    "recurrence_unsupported_form: '{name}' reads itself through `index` in its \
                     own definition, but the build pipeline could not resolve a cell frame to \
                     sweep. Evaluating it wholesale would resolve the self-read to an unbound \
                     name, and a body containing `max(x, 0)` would turn the resulting NaN into \
                     a plausible zero (esm-spec §4.3.1.1; CONFORMANCE_SPEC §5.19.4)."
                ),
            }));
        }
        Err(e) => return Some(Err(e)),
    };
    let empty: ArrMap = ArrMap::default();
    let derived_rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    let forcing: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    let env = EvalEnv {
        state_arrays: &empty,
        params,
        param_names,
        t,
        derived_rings: &derived_rings,
        derived_extents,
        forcing: &forcing,
        cse: None,
        const_lits: None,
        const_arrays,
        declared: empty_declared_names(),
    };
    let (shape, origin) = super::rhs::recur_frame(&lowered.ranges);
    let scope = RecurScope::new(name, shape, origin);
    take_const_array_oob(); // discard any latch left by an earlier failed call
    let arr = {
        let mut ctx = env.ctx(inputs);
        super::rhs::sweep_recurrence(
            &scope,
            &lowered.idx_names,
            &lowered.ranges,
            &lowered.body,
            lowered.axis,
            &mut ctx,
        )
    };
    // §5.19.4: an unavailable self-read is a FAULT, not a value. The latch is
    // the channel the tree walk has for one, and draining it here is what makes
    // this path fail closed rather than hand back an array built on a sentinel.
    match take_const_array_oob() {
        Some(details) => Some(Err(CompileError::InterpreterBuildError { details })),
        None => Some(Ok(arr)),
    }
}

/// Does `expr` read `name` through `index` — i.e. is it a self-read of the
/// variable this expression defines? Walks `args` and every expression sidecar,
/// so a read inside a `faq` body, a `filter` or a `makearray` region is
/// found.
fn expr_reads_self(expr: &Expr, name: &str) -> bool {
    let Expr::Operator(node) = expr else {
        return false;
    };
    if node.op == "index" && matches!(node.args.first(), Some(Expr::Variable(v)) if v == name) {
        return true;
    }
    node.args.iter().any(|a| expr_reads_self(a, name))
        || [
            node.expr.as_deref(),
            node.filter.as_deref(),
            node.key.as_deref(),
            node.lower.as_deref(),
            node.upper.as_deref(),
        ]
        .into_iter()
        .flatten()
        .any(|c| expr_reads_self(c, name))
        || node
            .values
            .as_ref()
            .is_some_and(|vs| vs.iter().any(|v| expr_reads_self(v, name)))
}

pub(crate) fn eval_expression_with_extents_and_consts_shared(
    expr: &Expr,
    inputs: &ArrMap,
    params: &[f64],
    param_names: &[String],
    t: f64,
    derived_extents: &HashMap<String, i64>,
    const_arrays: &ConstArrayScope,
) -> Result<Value, CompileError> {
    check_evaluable(expr)?;
    // A fresh evaluation can only register the geometry rings `expr` itself
    // produces, so a derived range over any other unsized producer is refused
    // rather than contracted as empty.
    let mut geometry_ids = std::collections::HashSet::new();
    super::compile::collect_geometry_producer_ids(expr, &mut geometry_ids);
    if let Some(from_faq) =
        super::compile::first_unmaterialized_derived_range(expr, derived_extents, &geometry_ids)
    {
        return Err(super::compile::unmaterialized_derived_error(
            &from_faq,
            &HashMap::new(),
            None,
        ));
    }
    let empty: ArrMap = ArrMap::default();
    let derived_rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    // Standalone expression evaluation (FAQ rings, area integrands) carries no
    // loader forcing — an empty buffer keeps the channel byte-identical here.
    let forcing: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    let env = EvalEnv {
        state_arrays: &empty,
        params,
        param_names,
        t,
        derived_rings: &derived_rings,
        derived_extents,
        forcing: &forcing,
        // Standalone one-shot evaluation: no CSE memo (nothing to amortize the
        // structural analysis over), so this path is unchanged.
        cse: None,
        const_lits: None,
        const_arrays,
        // No compiled model behind this entry point, so it vouches for no name
        // (see [`EvalCtx::declared`]).
        declared: empty_declared_names(),
    };
    let mut ctx = env.ctx(inputs);
    take_const_array_oob(); // discard any latch left by an earlier failed call
    let v = eval(expr, &mut ctx);
    match take_const_array_oob() {
        Some(details) => Err(CompileError::InterpreterBuildError { details }),
        None => Ok(v),
    }
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

/// The cell-invariant description of one ⊕-reduction: the contracted index
/// symbols, the body and optional `filter` expressions, the semiring, and the
/// output box an ARRAY-valued filter aligns against. Built once outside the
/// per-cell loop, so the contraction kernels take it as one argument instead
/// of threading five positionally.
pub(super) struct ReduceSpec<'a> {
    pub(super) contract_names: &'a [String],
    pub(super) body: &'a Expr,
    pub(super) reduce: ReduceKind,
    /// Optional `filter` predicate (§5.3): combinations for which it is false
    /// contribute the additive identity 0̄. `None` ⇒ no gating.
    pub(super) filter: Option<&'a Expr>,
    /// The output box (see [`CellBox`]), or `None` when there is none to align
    /// an array-valued filter against.
    pub(super) cell: Option<&'a CellBox<'a>>,
}

/// Evaluate a `faq` `filter` predicate under the current loop
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
/// kernel shared by the standalone-aggregate ([`eval_faq`]) and compiled
/// array-op-derivative ([`RhsRule::ArrayLoop`]) paths, mirroring the Julia
/// `_expand_int_range_dyn` einsum loop and the Python `_expand_ragged` gather.
pub(super) fn reduce_contraction(
    spec: &ReduceSpec,
    contract_dims: &[ContractDim],
    static_ranges: Option<&[(i64, i64)]>,
    ctx: &mut EvalCtx,
) -> f64 {
    let &ReduceSpec {
        contract_names,
        body,
        reduce,
        filter,
        cell,
    } = spec;
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

// =========================================================================== //
// GATE-DRIVEN contraction (CONFORMANCE_SPEC.md §5.5.6 / §5.5.8 / Wall #1)
// =========================================================================== //
//
// A join gate resolves its WHOLE admissible pair set once, so it can DRIVE
// enumeration rather than filter it. TWO gate kinds reach here and they differ
// only in how the pair set is COMPUTED — never in how it is used:
//
//   * a spatial OVERLAP gate (§5.5.6), whose pairs are the eps-inflated
//     envelope candidacies of [`crate::broad_phase::broad_phase_candidates`];
//   * a value-equality `on` gate (§5.5.8), whose pairs are the matches of
//     [`crate::relational::equijoin`] over the two key columns — the same
//     deterministic, canonical-key-ordered kernel the build-time relational
//     engine uses, not a second hashing path.
//
// The gate drives ANY aggregate — an ordinary dense reduction as much as an
// index-set-producing `distinct` producer; nothing in the contract
// distinguishes them. Three shapes reach here (the policy itself is
// [`crate::broad_phase::overlap_drive_plan`], shared with the value-invention
// producer, which differs only in loop shape because its ranges may be ragged
// and are therefore resolved lazily):
//
//   RESTRICT — one gated axis is an OUTPUT index (already bound) and the other
//     is contracted. This is the ISRM binning aggregate `E[c] = Σ_r […]` and
//     its record-output mirror `P[r] = Σ_c […]`: the contracted axis iterates
//     only this output cell's candidate partners, in the same ascending order
//     its own range would have visited them, so the aggregate costs
//     `O(|candidates|)` in total rather than `O(N_c·N_r)`.
//   PAIRS — both gated axes are contracted AND are the only two contracted axes
//     (the scalar-reduction form); the candidate pairs bind both at once.
//   PARTNER-RESTRICTED — both gated axes are contracted alongside OTHER
//     contracted axes, so the pair list cannot bind the whole tuple. The
//     product is walked lexicographically as usual except that the LATER gated
//     axis iterates only the partners of the earlier one's current value. Still
//     the exact order-preserving subsequence; drops the whole `N_later` factor.
//   REJECT — both gated axes are already bound and the pair is not a candidate:
//     no leaf is admitted at all.
//
// Anything else falls through to the full product. In EVERY shape the narrow
// `filter` still runs per leaf, and the driven sequence is the exact
// order-preserving SUBSEQUENCE of the product the gate would have admitted — so
// the emitted terms, and hence the ⊕-reduction, are BIT-IDENTICAL to the
// filtered full product. The driver removes work; it never changes an answer.
//
// That per-leaf `filter` is what makes falling through SAFE for an equality
// gate too. An overlap gate is a conservative superset and its narrow phase is
// the author's own `filter`; an `on` gate is EXACT, and there would be nothing
// to re-check it with — so `crate::join` lowers every resolved `on` pair into a
// value-equality predicate ANDed into that same `filter` (§5.5.8). Declining to
// drive therefore costs time, never correctness, on every shape and on every
// path that never consults a gate at all (the whole-array overlay, the tape).
//
// IDENTITY FILL (normative, §5.5.6). Driving means an output cell with no
// candidate pair emits NO term. That is the correct answer, not a hole: the
// accumulator starts at `reduce.identity()` and is returned untouched — e.g. an
// emission record outside the grid sums to `0` under `(+, 0)`.

/// A resolved join gate: the two range symbols it gates, the candidate pair
/// index built ONCE — from the const-array envelope factors for an overlap
/// gate, from the two key columns for a value-equality `on` gate — and the
/// three integers that make its SELECTIVITY comparable to a sibling gate's
/// (CONFORMANCE_SPEC.md §5.24).
///
/// Everything about the enumeration (placement, drive plan, driven unroll)
/// reads only `sym_src` / `sym_tgt` / `index`, which is why one struct serves
/// both gate kinds; `n_src` / `n_tgt` / `clause_ix` are consulted ONLY to order
/// the gates and can therefore never reach a result.
pub(super) struct JoinGate {
    sym_src: String,
    sym_tgt: String,
    index: Rc<crate::broad_phase::OverlapIndex>,
    /// Positions on the `src` side — the left key column's length for an `on`
    /// gate, the `src_env` factor's length for an overlap gate.
    n_src: usize,
    /// Positions on the `tgt` side.
    n_tgt: usize,
    /// This gate's index in the node's `join` list — the deterministic
    /// tiebreak when two gates estimate equally selective (§5.24).
    clause_ix: usize,
}

impl JoinGate {
    /// Compare two gates by ESTIMATED SELECTIVITY, most selective first
    /// (CONFORMANCE_SPEC.md §5.24).
    ///
    /// The estimate is the gate's **admitted fraction** `|matches| / (n_src ·
    /// n_tgt)`: what share of the two gated axes' cross product survives it.
    /// Every input is already in hand — `|matches|` is the match set the gate
    /// built anyway, and the two side lengths are the key columns' own — so the
    /// estimate costs nothing beyond the comparison.
    ///
    /// Compared as a RATIONAL in exact `i128` arithmetic (`a₁·s₂` vs `a₂·s₁`),
    /// never in floating point: two bindings must order a tie the same way, and
    /// a float division can round two distinct fractions together (or apart) in
    /// a language-dependent way. Both products fit: `|matches| ≤ n_src·n_tgt ≤
    /// (2⁶⁴)²` is out of range in principle but not in practice, and the inputs
    /// here are `usize` row counts of materialised arrays.
    ///
    /// Ties — including the degenerate `n_src·n_tgt = 0` — break on
    /// `clause_ix`, the gate's position in the document's `join` list. That is
    /// a property of the FILE, identical in every binding, so two bindings that
    /// agree on the match sets agree on the order.
    fn selectivity_cmp(&self, other: &JoinGate) -> std::cmp::Ordering {
        let (a1, s1) = (self.index.len() as i128, (self.n_src * self.n_tgt) as i128);
        let (a2, s2) = (
            other.index.len() as i128,
            (other.n_src * other.n_tgt) as i128,
        );
        (a1 * s2)
            .cmp(&(a2 * s1))
            .then_with(|| self.clause_ix.cmp(&other.clause_ix))
    }
}

/// Where one of a gate's two symbols sits in the aggregate being evaluated.
#[derive(Clone, Copy, PartialEq, Eq)]
enum GateAxis {
    /// A contracted index — free, at this position in `contract_names`.
    Contracted(usize),
    /// An output index — already bound in `ctx.loop_binds` for this cell.
    Output,
    /// Neither: the gate cannot be resolved against this node's loops.
    Absent,
}

/// The per-aggregate (cell-independent) placement of a gate's two symbols.
pub(super) struct GatePlacement {
    src: GateAxis,
    tgt: GateAxis,
}

fn gate_axis(sym: &str, idx_names: &[String], contract_names: &[String]) -> GateAxis {
    if let Some(d) = contract_names.iter().position(|n| n == sym) {
        return GateAxis::Contracted(d);
    }
    if idx_names.iter().any(|n| n == sym) {
        return GateAxis::Output;
    }
    GateAxis::Absent
}

pub(super) fn gate_placement(
    gate: &JoinGate,
    idx_names: &[String],
    contract_names: &[String],
) -> GatePlacement {
    GatePlacement {
        src: gate_axis(&gate.sym_src, idx_names, contract_names),
        tgt: gate_axis(&gate.sym_tgt, idx_names, contract_names),
    }
}

// --------------------------------------------------------------------------- //
// The gate-index caches and their resident-size budget (issue #418)
// --------------------------------------------------------------------------- //

/// What a cached gate entry COSTS, and whether evicting it would free anything.
///
/// Implemented for both caches' value types so one [`GateCache`] serves the
/// spatial overlap gate and the value-equality `on` gate alike.
trait Retained {
    /// Candidate pairs this entry holds — the unit the budget is denominated
    /// in. Entries differ by orders of magnitude (a 6-cell regrid geometry
    /// against a 50-million-pair star join), so a cap counted in ENTRIES would
    /// bound the wrong thing.
    ///
    /// PAIR-EQUIVALENTS, from [`crate::broad_phase::OverlapIndex::resident_pairs`]:
    /// the run table and the lazily built `tgt` adjacency are memory the cache
    /// holds, so they are memory the budget counts.
    fn retained_pairs(&self) -> usize;

    /// Is a live [`JoinGate`] still holding this index? Evicting it then frees
    /// nothing — the strong reference keeps the allocation alive — and only
    /// costs a rebuild the next time the node is evaluated.
    fn in_use(&self) -> bool;
}

impl Retained for Option<Rc<crate::broad_phase::OverlapIndex>> {
    fn retained_pairs(&self) -> usize {
        self.as_ref().map_or(0, |ix| ix.resident_pairs())
    }
    fn in_use(&self) -> bool {
        self.as_ref().is_some_and(|ix| Rc::strong_count(ix) > 1)
    }
}

impl Retained for Option<EqGateEntry> {
    fn retained_pairs(&self) -> usize {
        self.as_ref().map_or(0, |(ix, _, _)| ix.resident_pairs())
    }
    fn in_use(&self) -> bool {
        self.as_ref()
            .is_some_and(|(ix, _, _)| Rc::strong_count(ix) > 1)
    }
}

/// One cached gate index, with what the budget needs to know about it.
struct CacheEntry<V> {
    value: V,
    pairs: usize,
    /// The LRU clock reading at its last hit (or at its insertion).
    used: u64,
}

/// A gate-index cache bounded by the PAIRS it retains.
///
/// # Why there is a bound at all
///
/// A gate index is built once per node and consulted once per output cell, so
/// memoizing it across evaluations is what keeps a per-cell walk from
/// rebuilding an R*-tree or re-probing a million keys — see the note on
/// [`resolve_join_gates`]. Retaining it FOREVER is a different claim, and a
/// wrong one: an unbounded cache made peak memory track the sum of every match
/// set a build ever resolved. On issue #418's MOVES port that was three
/// successive 4.2 GB indices, each live for ~21 seconds of a multi-minute run
/// and resident for the rest of it, against 0.31 GiB of declared arrays.
///
/// # Why it can only change COST
///
/// A gate is a pure optimisation in both directions: [`resolve_join_gates`] is
/// free to decline one entirely (the lowered `filter` then computes the same
/// answer over the full product), and rebuilding one from the same inputs
/// yields the same match set, since it is a pure function of the key columns.
/// So an eviction — like a run with [`crate::broad_phase::set_join_gate_enabled`]
/// off — can make a document slower and can never make it answer differently.
///
/// # The policy
///
/// Least-recently-used, evicted BEFORE the replacement is built rather than
/// after, so the outgoing index's memory is already back when the incoming
/// one's is allocated: that is what turns "sum of every index" into "the
/// largest one". An entry a live [`JoinGate`] still holds is skipped, since
/// dropping the cache's reference to it would free nothing.
///
/// Because that eviction runs before the build, it cannot account for what the
/// build returns, and the insert that follows routinely leaves the cache over
/// budget. So the budget is enforced at the PROBE as well — see
/// [`GateCache::get_within_budget`] — which is what bounds a run whose gates
/// only ever hit.
///
/// The failure mode is thrash: a node that alternates between two indices which
/// do not BOTH fit will rebuild each in turn, as will a single index larger
/// than the whole budget. Two gates on ONE aggregate cannot trigger the former
/// (both are resolved, and so both `in_use`, before either is consulted), and a
/// steady-state repeated node whose index FITS never evicts at all.
/// [`gate_cache_pair_budget`] is the escape hatch if a document finds a shape
/// that does.
struct GateCache<K, V> {
    entries: HashMap<K, CacheEntry<V>>,
    clock: u64,
    pairs: usize,
}

/// Cap on the number of ENTRIES, independent of the pair budget: a build that
/// resolves thousands of tiny distinct gates would otherwise accumulate their
/// keys (an overlap key carries the envelope factor NAMES) without ever
/// approaching the budget.
const GATE_CACHE_MAX_ENTRIES: usize = 512;

impl<K: std::hash::Hash + Eq + Clone, V: Clone + Retained> GateCache<K, V> {
    fn new() -> Self {
        GateCache {
            entries: HashMap::new(),
            clock: 0,
            pairs: 0,
        }
    }

    /// Probe, marking a hit as most-recently-used.
    fn get(&mut self, key: &K) -> Option<V> {
        self.clock += 1;
        let clock = self.clock;
        let e = self.entries.get_mut(key)?;
        e.used = clock;
        Some(e.value.clone())
    }

    /// Probe, having FIRST dropped whatever the budget no longer covers.
    ///
    /// The trim comes before the probe, and that ordering is the guarantee.
    /// Eviction on a miss runs before the replacement is built, so it cannot
    /// account for what that build returns: the cache is routinely left over
    /// budget by its own last insert. A hit marks its entry most-recently-used
    /// and would then protect it indefinitely — which is the STEADY STATE of
    /// the very shape the budget exists for, one gate in an RHS evaluated every
    /// step of a time loop, where the index is inserted once and never probed
    /// as a miss again. Trimming only on a miss would leave that run resident
    /// at whatever its first build cost, whatever the budget said.
    ///
    /// So an index no live [`JoinGate`] holds is dropped here and rebuilt on
    /// the next miss, which is what makes `0` mean what
    /// [`crate::broad_phase::set_gate_cache_pair_budget`] says it means. Within
    /// budget the loop condition is false on entry and the probe is unchanged.
    fn get_within_budget(&mut self, key: &K, budget: usize) -> Option<V> {
        self.reprice();
        self.evict_to(budget, GATE_CACHE_MAX_ENTRIES);
        self.get(key)
    }

    /// Re-read what each entry costs.
    ///
    /// An index GROWS after it is inserted: its `tgt` adjacency is built on
    /// the first `Side::Tgt` walk, which is 8 B/pair the price at insert could
    /// not have known about. Repricing at the probe is what keeps that memory
    /// inside the budget rather than permanently invisible to it, and it is
    /// arithmetic over a handful of `Vec` lengths — the same scan
    /// [`GateCache::evict_to`] was about to make anyway.
    fn reprice(&mut self) {
        let mut total = 0;
        for e in self.entries.values_mut() {
            e.pairs = e.value.retained_pairs();
            total += e.pairs;
        }
        self.pairs = total;
    }

    /// Drop least-recently-used entries until the cache holds at most `budget`
    /// pairs in at most `max_entries` entries.
    ///
    /// `entries` is small (bounded by [`GATE_CACHE_MAX_ENTRIES`], and in
    /// practice a handful), so scanning it for the minimum beats carrying an
    /// intrusive order list.
    fn evict_to(&mut self, budget: usize, max_entries: usize) {
        while self.pairs > budget || self.entries.len() > max_entries {
            let victim = self
                .entries
                .iter()
                .filter(|(_, e)| !e.value.in_use())
                .min_by_key(|(_, e)| e.used)
                .map(|(k, _)| k.clone());
            let Some(victim) = victim else { return }; // every entry is live
            if let Some(e) = self.entries.remove(&victim) {
                self.pairs -= e.pairs;
            }
        }
    }

    /// Evict on a MISS, before the replacement is built: to the pair budget,
    /// and to one BELOW the entry cap so the incoming entry has a slot.
    fn evict_to_budget(&mut self, budget: usize) {
        self.evict_to(budget, GATE_CACHE_MAX_ENTRIES.saturating_sub(1));
    }

    fn insert(&mut self, key: K, value: V) {
        self.clock += 1;
        let pairs = value.retained_pairs();
        let prev = self.entries.insert(
            key,
            CacheEntry {
                value,
                pairs,
                used: self.clock,
            },
        );
        self.pairs = self.pairs - prev.map_or(0, |e| e.pairs) + pairs;
    }
}

/// The cache key of a resolved gate: the envelope factor NAMES, the `eps`, and
/// the two envelope side lengths.
///
/// §5.5.6 requires a gate's `src_env` / `tgt_env` factors to be build-time
/// const-array data by the time the broad phase runs, so for a given node the
/// candidate set is a pure function of this key — but a gate is resolved once
/// per node and consulted once per RHS evaluation, and rebuilding the R*-tree
/// each time would cost more than the enumeration it saves.
type GateKey = (Vec<String>, Vec<String>, u64, usize, usize);

thread_local! {
    /// The spatial-overlap gate cache, bounded by [`gate_cache_pair_budget`].
    static GATE_CACHE: RefCell<GateCache<GateKey, Option<Rc<crate::broad_phase::OverlapIndex>>>> =
        RefCell::new(GateCache::new());
}

/// The dense length of an envelope factor, WITHOUT cloning it (the cache is
/// consulted on every evaluation; the clone below happens only on a miss).
fn env_factor_len(name: &str, ctx: &EvalCtx) -> Option<usize> {
    if let Some(a) = ctx.state_arrays.get(name) {
        return Some(a.len());
    }
    if let Some(a) = ctx.observed_arrays.get(name) {
        return Some(a.len());
    }
    ctx.forcing.borrow().get(name).map(|a| a.len())
}

/// Resolve EVERY drivable clause of `join` into a gate, building (or reusing)
/// each candidate pair index — a broad-phase envelope set for an `overlap`
/// clause (§5.5.6), an [`crate::relational::equijoin`] match set for a resolved
/// `on` clause (§5.5.8) — and return them ordered MOST SELECTIVE FIRST
/// (§5.24).
///
/// This used to return the FIRST resolvable clause and stop, which made the
/// node's cost a function of the order the author happened to type the clauses
/// in: measured on the four-clause NONROAD roll-up `tech_fraction`, the best
/// and worst orderings of one unchanged document differ by 47× in wall clock
/// (moves.esm `docs/findings/README.md` F17). Resolving them all costs one
/// equijoin per clause — each `O(|L|+|R|+|matches|)`, memoised across
/// evaluations by [`EQ_GATE_CACHE`] — and buys two things: the driver picks by
/// SELECTIVITY rather than by position, and, because the gates compose by
/// conjunction, [`reduce_contraction_gated`] can INTERSECT their partner sets
/// instead of driving on one and testing the rest per leaf.
///
/// Returns an empty vector — and the caller then walks the untouched full
/// product — when no clause resolves: when an overlap clause's range symbols
/// were not resolved at build time ([`crate::join::resolve_overlap_join_syms`]),
/// when an envelope factor is not array data in this context, or when an `on`
/// gate's key columns cannot be read as exact-equality keys here.
///
/// Declining is always SAFE. For an overlap gate the candidate set is a
/// conservative superset behind the author's narrow `filter`, so the full
/// product yields the same terms. For an `on` gate — which is EXACT, and has no
/// author-supplied narrow phase — safety comes from `crate::join` having ALSO
/// lowered the equality into `filter` (§5.5.8); the full product then applies
/// the identical predicate.
///
/// **On Julia's "Hook 1b".** The Julia reference resolves its gates at BUILD
/// time out of a `const_arrays` registry, so an envelope factor living on a
/// value-invented derived axis — exactly the `pd_cell__*` gathers the pushdown
/// rewrite puts in `tgt_env` — had to be materialised into that registry by a
/// dedicated post-value-invention hook (`_derive_overlap_env_factors`) before
/// join-gate resolution could see it. Rust needs no equivalent: the gate is
/// resolved HERE, lazily, at the moment the aggregate is evaluated, by which
/// point a `pd_cell__*` gather is simply another materialised observed in
/// `ctx.observed_arrays` (the prepare front door and the compiled observed
/// pipeline both evaluate observeds in dependency order). The ordering
/// constraint the hook exists to satisfy is satisfied structurally.
pub(super) fn resolve_join_gates(join: &[JoinClause], ctx: &EvalCtx) -> Vec<JoinGate> {
    // The driver switch ([`crate::broad_phase::set_join_gate_enabled`], a
    // thread-local a test sets around one evaluation). Declining here is the
    // pre-driver path exactly: the full product, decided by `filter`. It is what
    // makes "the driver changes cost, never an answer" a directly testable
    // claim on the SAME document rather than an argument.
    if !crate::broad_phase::join_gate_enabled() {
        return Vec::new();
    }
    let mut gates: Vec<JoinGate> = Vec::new();
    // An upper bound on how many DISTINCT positions each gated symbol can still
    // take, given the gates resolved so far: a gate with `m` pairs leaves at
    // most `m` positions alive on either side. Seeded implicitly from the side
    // lengths, and read by the planner below to price what a further gate on
    // those symbols could possibly prune.
    let mut reach: HashMap<String, usize> = HashMap::new();

    // --- spatial overlap clauses ------------------------------------------
    // Resolved first and unconditionally. Their candidate set is a broad-phase
    // envelope superset whose size is bounded by the geometry, not by a key's
    // cardinality, so the pricing below has nothing to save on them -- and
    // resolving them first is what lets an overlap gate narrow `reach` for the
    // equality clauses that share a symbol with it.
    for (clause_ix, clause) in join.iter().enumerate() {
        let Some(ov) = &clause.overlap else {
            continue;
        };
        let (Some(sym_src), Some(sym_tgt)) = (&ov.sym_src, &ov.sym_tgt) else {
            continue;
        };
        let eps = ov.eps.unwrap_or(0.0);
        let (Some(first_src), Some(first_tgt)) = (ov.src_env.first(), ov.tgt_env.first()) else {
            continue;
        };
        let (Some(nsrc), Some(ntgt)) = (
            env_factor_len(first_src, ctx),
            env_factor_len(first_tgt, ctx),
        ) else {
            continue;
        };
        let key: GateKey = (
            ov.src_env.clone(),
            ov.tgt_env.clone(),
            eps.to_bits(),
            nsrc,
            ntgt,
        );
        let budget = crate::broad_phase::gate_cache_pair_budget();
        let cached = GATE_CACHE.with(|c| c.borrow_mut().get_within_budget(&key, budget));
        let index = match cached {
            Some(hit) => hit,
            None => {
                // Release the least-recently-used index BEFORE building this
                // one, so the two are never resident at once (issue #418).
                GATE_CACHE.with(|c| c.borrow_mut().evict_to_budget(budget));
                crate::broad_phase::bump_gate_index_builds();
                let built = build_overlap_index(&ov.src_env, &ov.tgt_env, eps, ctx).map(Rc::new);
                GATE_CACHE.with(|c| c.borrow_mut().insert(key, built.clone()));
                built
            }
        };
        if let Some(index) = index {
            narrow_reach(&mut reach, sym_src, index.len());
            narrow_reach(&mut reach, sym_tgt, index.len());
            gates.push(JoinGate {
                sym_src: sym_src.clone(),
                sym_tgt: sym_tgt.clone(),
                index,
                n_src: nsrc,
                n_tgt: ntgt,
                clause_ix,
            });
        }
    }

    // --- value-equality clauses, PRICED BEFORE THEY ARE BUILT --------------
    // An `on` gate's match count is a property of the DATA, not of the ranges:
    // a six-valued key against a 1.4-million-row table matches 167 million
    // pairs. `equijoin_match_count` reads that in O(|L| + |R|) without writing
    // a pair, so the planner can know what a gate would cost before paying.
    let mut priced: Vec<EqCandidate<'_>> = Vec::new();
    // The keyed sides of the CHEAPEST candidate priced so far, and its slot in
    // `priced`. Only one set is held.
    //
    // Pricing has to read both sides to count the matches, and the gate that
    // gets built needs the same keys again — so keeping them is worth a whole
    // `side_keys` pass over a multi-million-row column (issue #418's remaining
    // per-fact-row term). Keeping EVERY candidate's, though, makes a node's
    // peak the SUM of its clauses' key columns where it used to be the largest
    // single one, and a `Key` is 32 B per row before a composite adds a `Vec`
    // per row. So exactly one is retained, and it is the cheapest: `priced` is
    // resolved in ascending `matches`, so that candidate sorts first, is the
    // one a decline can never reach while `gates` is empty, and is therefore
    // the one most likely to be built. Every other candidate re-reads its
    // sides only if it survives the decline test — which is still no worse
    // than before the planner existed, when every built gate read them twice.
    let mut cheapest: Option<(usize, EqSides)> = None;
    let budget = crate::broad_phase::gate_cache_pair_budget();
    for (clause_ix, clause) in join.iter().enumerate() {
        if clause.overlap.is_some() {
            continue;
        }
        let Some(g) = &clause.on_gate else {
            continue;
        };
        if g.cols_l.len() != g.cols_r.len() || g.cols_l.is_empty() {
            continue;
        }
        let Some(key) = equality_cache_key(g, ctx) else {
            continue;
        };
        // Already resident: it costs nothing to take, so it is never declined.
        // Probed through the BUDGET (issue #418), so an entry the budget no
        // longer covers is dropped here rather than protected by the hit.
        if let Some(hit) = EQ_GATE_CACHE.with(|c| c.borrow_mut().get_within_budget(&key, budget)) {
            if let Some((index, n_l, n_r)) = hit {
                priced.push(EqCandidate {
                    g,
                    clause_ix,
                    matches: index.len(),
                    n_l,
                    n_r,
                    key,
                    ready: Some((index, n_l, n_r)),
                    sides: None,
                });
            }
            continue;
        }
        // A price already taken this run, for a gate the planner declined or
        // whose index has since been evicted.
        if let Some(&(n_l, n_r, matches)) = EQ_PRICE_CACHE
            .with(|c| c.borrow().get(&key).copied())
            .as_ref()
        {
            priced.push(EqCandidate {
                g,
                clause_ix,
                matches,
                n_l,
                n_r,
                key,
                ready: None,
                sides: None,
            });
            continue;
        }
        let Some(sides) = equality_sides(g, ctx) else {
            // The columns cannot be read as exact-equality keys here. Memoize
            // the decline, as the pre-planner path did, so it is not retried.
            EQ_GATE_CACHE.with(|c| c.borrow_mut().insert(key, None));
            continue;
        };
        let matches = crate::relational::equijoin_match_count(&sides.1, &sides.3);
        let (n_l, n_r) = (sides.0.len(), sides.2.len());
        remember_price(key.clone(), (n_l, n_r, matches));
        // Strictly cheaper only, so a tie keeps the lower `clause_ix` — the
        // same candidate `sort_by_key((matches, clause_ix))` will put first.
        if cheapest
            .as_ref()
            .is_none_or(|&(i, _)| matches < priced[i].matches)
        {
            cheapest = Some((priced.len(), sides));
        }
        priced.push(EqCandidate {
            g,
            clause_ix,
            matches,
            n_l,
            n_r,
            key,
            ready: None,
            sides: None,
        });
    }
    if let Some((slot, sides)) = cheapest {
        priced[slot].sides = Some(sides);
    }

    // CHEAPEST FIRST. A gate's value is the space it prunes, so the one that
    // prunes most must be resolved before the ones whose value depends on how
    // much is left to prune. `clause_ix` breaks ties, so the order is a pure
    // function of the document and the data.
    priced.sort_by_key(|c| (c.matches, c.clause_ix));

    let ratio = crate::broad_phase::gate_plan_ratio();
    let floor = crate::broad_phase::gate_plan_floor();
    for c in priced {
        let space = (reach_of(&reach, &c.g.sym_l, c.n_l) as u128)
            .saturating_mul(reach_of(&reach, &c.g.sym_r, c.n_r) as u128);
        let (index, n_src, n_tgt) = match c.ready {
            Some(entry) => entry,
            None => {
                // UNECONOMIC: it would materialise more pairs than the tuples
                // it could prune. The equality is still applied -- `crate::join`
                // lowered it into this node's `filter` -- so this costs a wider
                // walk and never an answer.
                // NEVER the only gate. Priced cheapest-first, so the first
                // one through here is the most selective the node has; leaving
                // it out would drop the walk to the full product, which is the
                // one way this planner could make a document dramatically
                // slower. A gate is declined only when another already drives.
                if !gates.is_empty()
                    && c.matches >= floor
                    && (c.matches as u128) > space.saturating_mul(ratio)
                {
                    crate::broad_phase::bump_gate_plan_declines();
                    continue;
                }
                let Some((pos_l, keys_l, pos_r, keys_r)) = c.sides else {
                    // Priced on an earlier evaluation and since evicted; the
                    // keys have to be read again to rebuild it.
                    let Some(sides) = equality_sides(c.g, ctx) else {
                        continue;
                    };
                    push_equality_gate(&mut gates, &mut reach, c.g, c.clause_ix, c.key, sides);
                    continue;
                };
                push_equality_gate(
                    &mut gates,
                    &mut reach,
                    c.g,
                    c.clause_ix,
                    c.key,
                    (pos_l, keys_l, pos_r, keys_r),
                );
                continue;
            }
        };
        narrow_reach(&mut reach, &c.g.sym_l, index.len());
        narrow_reach(&mut reach, &c.g.sym_r, index.len());
        gates.push(JoinGate {
            sym_src: c.g.sym_l.clone(),
            sym_tgt: c.g.sym_r.clone(),
            index,
            n_src,
            n_tgt,
            clause_ix: c.clause_ix,
        });
    }

    // MOST SELECTIVE FIRST (§5.24). `sort_by` is stable, and the comparator
    // already falls back to `clause_ix`, so the order is a pure function of the
    // document and the data -- never of `join`'s iteration order or of how many
    // gates happened to tie.
    gates.sort_by(JoinGate::selectivity_cmp);
    gates
}

/// Both sides of an `on` gate as the planner carries them: `(positions, keys)`
/// per side, left then right.
type EqSides = (
    Vec<i64>,
    Vec<crate::relational::Key>,
    Vec<i64>,
    Vec<crate::relational::Key>,
);

/// One `on` clause the planner is weighing: what it would cost, what it spans,
/// and either the index it already has or the keyed sides it would build from.
struct EqCandidate<'a> {
    g: &'a crate::join::OnGate,
    clause_ix: usize,
    /// How many pairs the gate would hold -- its cost, in the same unit as the
    /// cache budget.
    matches: usize,
    n_l: usize,
    n_r: usize,
    key: EqGateKey,
    /// Set when the index is already resident, which makes the gate free.
    ready: Option<EqGateEntry>,
    /// Set on the ONE cheapest candidate, whose sides pricing kept so that its
    /// build need not read them again.
    sides: Option<EqSides>,
}

/// Build one equality gate from its already-keyed sides, cache it, and record
/// what it narrows.
fn push_equality_gate(
    gates: &mut Vec<JoinGate>,
    reach: &mut HashMap<String, usize>,
    g: &crate::join::OnGate,
    clause_ix: usize,
    key: EqGateKey,
    sides: EqSides,
) {
    // Release the least-recently-used match set BEFORE building this one, so a
    // build that resolves several large gates in turn peaks at the LARGEST of
    // them rather than at their sum (issue #418).
    EQ_GATE_CACHE.with(|c| {
        c.borrow_mut()
            .evict_to_budget(crate::broad_phase::gate_cache_pair_budget())
    });
    crate::broad_phase::bump_gate_index_builds();
    let (ix, n_src, n_tgt) = index_from_sides(sides);
    let entry: EqGateEntry = (Rc::new(ix), n_src, n_tgt);
    EQ_GATE_CACHE.with(|c| c.borrow_mut().insert(key, Some(entry.clone())));
    narrow_reach(reach, &g.sym_l, entry.0.len());
    narrow_reach(reach, &g.sym_r, entry.0.len());
    gates.push(JoinGate {
        sym_src: g.sym_l.clone(),
        sym_tgt: g.sym_r.clone(),
        index: entry.0,
        n_src,
        n_tgt,
        clause_ix,
    });
}

/// How many distinct positions `sym` can still take, given the gates already
/// resolved. `full` is its side length, which is the answer when nothing has
/// narrowed it.
fn reach_of(reach: &HashMap<String, usize>, sym: &str, full: usize) -> usize {
    reach.get(sym).map_or(full, |r| (*r).min(full))
}

/// Record that a gate with `pairs` pairs leaves at most that many positions
/// alive on `sym`.
fn narrow_reach(reach: &mut HashMap<String, usize>, sym: &str, pairs: usize) {
    let slot = reach.entry(sym.to_string()).or_insert(usize::MAX);
    *slot = (*slot).min(pairs);
}

fn build_overlap_index(
    src_env: &[String],
    tgt_env: &[String],
    eps: f64,
    ctx: &EvalCtx,
) -> Option<crate::broad_phase::OverlapIndex> {
    let mut arrays: HashMap<String, ArrayD<f64>> = HashMap::new();
    for name in src_env.iter().chain(tgt_env.iter()) {
        if arrays.contains_key(name) {
            continue;
        }
        match lookup_variable(name, ctx) {
            Value::Array(a) => {
                arrays.insert(name.clone(), *a);
            }
            Value::Scalar(_) => return None,
        }
    }
    let src = crate::broad_phase::envelope_vectors(src_env, &arrays).ok()?;
    let tgt = crate::broad_phase::envelope_vectors(tgt_env, &arrays).ok()?;
    let pairs = crate::broad_phase::broad_phase_candidates(&src, &tgt, eps);
    Some(crate::broad_phase::OverlapIndex::from_zero_based(&pairs))
}

// --------------------------------------------------------------------------- //
// The value-equality (`join.on`) candidate set (CONFORMANCE_SPEC.md §5.5.8)
// --------------------------------------------------------------------------- //

/// The cache key of a resolved EQUALITY gate: the build-time gate id, the
/// observed length of each data column, and a content fingerprint of those
/// columns.
///
/// The id alone pins every [`crate::join::KeyColumn::Const`] side (its values
/// are baked in at build time), so only the data columns need watching. §5.5.8
/// requires an `on` key column to be build-time constant data by the time the
/// gate is built — the same requirement §5.5.6 puts on an overlap gate's
/// envelope factors — but a fingerprint is cheap next to the join itself (one
/// linear fold over `f64` bits, against a hash of every key plus the match
/// materialisation), so a column that does change is REBUILT rather than
/// silently served a stale match set.
type EqGateKey = (u64, SmallVec<[usize; 2]>, u64);

/// A cached equality gate: its match set, plus the two side lengths the
/// §5.24 selectivity estimate divides by. Cached together because both are
/// products of the same `side_keys` pass.
type EqGateEntry = (Rc<crate::broad_phase::OverlapIndex>, usize, usize);

thread_local! {
    /// The value-equality gate cache, bounded by [`gate_cache_pair_budget`].
    static EQ_GATE_CACHE: RefCell<GateCache<EqGateKey, Option<EqGateEntry>>> =
        RefCell::new(GateCache::new());
}

thread_local! {
    /// What each `on` gate WOULD cost, so a gate the planner declines is priced
    /// once per run rather than once per evaluation.
    ///
    /// Three `usize`s per entry — the price tag, not the thing priced — but it
    /// is CAPPED all the same, because the key it is filed under is the index
    /// cache's: `(id, lens, fingerprint)`. The fingerprint is there precisely
    /// because a key column's contents can change between evaluations, and
    /// when one does this map would otherwise gain an entry per gate per
    /// evaluation for the life of the thread, beside a cache that is bounded
    /// both by resident pairs and by [`GATE_CACHE_MAX_ENTRIES`].
    static EQ_PRICE_CACHE: RefCell<HashMap<EqGateKey, (usize, usize, usize)>> =
        RefCell::new(HashMap::new());
}

/// File one gate's price, dropping every earlier one when the map reaches the
/// index cache's entry cap.
///
/// Wholesale rather than least-recently-used: a price is a pure function of
/// the key it is filed under, so losing one costs a single `O(|L| + |R|)`
/// re-count and never a wrong decision — and the cap is only ever reached by a
/// document whose key columns keep changing, which is the case where the old
/// prices are stale anyway.
fn remember_price(key: EqGateKey, price: (usize, usize, usize)) {
    EQ_PRICE_CACHE.with(|c| {
        let mut m = c.borrow_mut();
        if m.len() >= GATE_CACHE_MAX_ENTRIES {
            m.clear();
        }
        m.insert(key, price);
    });
}

/// Run `f` on the named 1-D array WITHOUT cloning it. `lookup_variable` returns
/// an owned `Value`, which for a 10⁷-row key column is an 80 MB copy per
/// resolution; a gate reads each column twice (fingerprint, then keys).
fn with_named_array<R>(name: &str, ctx: &EvalCtx, f: impl FnOnce(&ArrayD<f64>) -> R) -> Option<R> {
    if let Some(a) = ctx.state_arrays.get(name) {
        return Some(f(a));
    }
    if let Some(a) = ctx.observed_arrays.get(name) {
        return Some(f(a));
    }
    let forcing = ctx.forcing.borrow();
    forcing.get(name).map(f)
}

/// FNV-1a over an array's raw `f64` bits — a cache-invalidation fingerprint
/// only. It never drives an emitted order, a key, or a result, so the §5.5
/// "no non-portable hash may drive output" rule does not reach it.
fn column_fingerprint(a: &ArrayD<f64>, acc: &mut u64) {
    for v in a.iter() {
        *acc ^= v.to_bits();
        *acc = acc.wrapping_mul(0x0000_0100_0000_01B3);
    }
}

/// The `(positions, keys)` of one resolved key column: the loop-symbol values
/// the column is defined at, and the [`crate::relational::Key`] at each.
///
/// A data column's values are `f64` in the dense evaluator, so they are
/// admitted only when EXACTLY integral — §5.3 forbids float join keys because
/// their equality is not portable across bindings, and a non-integral column is
/// exactly that. Returning `None` declines the gate; the lowered `filter`
/// predicate still computes the right answer, just without the driver.
fn key_column_values(
    col: &crate::join::KeyColumn,
    ctx: &EvalCtx,
) -> Option<(Vec<i64>, Vec<crate::relational::Key>)> {
    use crate::join::{JoinKey, KeyColumn};
    match col {
        KeyColumn::Const { positions, values } => {
            let keys = values
                .iter()
                .map(|v| match v {
                    JoinKey::Int(i) => crate::relational::Key::Int(*i),
                    JoinKey::Cat(c) => crate::relational::Key::Str(c.clone()),
                })
                .collect();
            Some((positions.clone(), keys))
        }
        KeyColumn::Column(name) => with_named_array(name, ctx, |a| {
            if a.ndim() != 1 {
                return None;
            }
            let mut keys = Vec::with_capacity(a.len());
            for &v in a.iter() {
                if !v.is_finite() || v.fract() != 0.0 {
                    return None;
                }
                keys.push(crate::relational::Key::Int(v as i64));
            }
            // A 1-D data column is addressed 1-based by `index(col, sym)`, and
            // its shape index set resolves the symbol's range to `[1, N]`.
            Some(((1..=a.len() as i64).collect(), keys))
        })?,
    }
}

/// One side's per-position key: the single column's key for a simple `on`, or
/// the canonical composite [`crate::relational::skolem`] tuple over every listed
/// pair's column for a multi-pair (COMPOSITE-KEY) clause. A composite key
/// matches iff EVERY pair agrees, which is exactly tuple equality; `skolem`
/// gives the directed (order-preserving) canonical tuple, so the left and right
/// sides build comparable keys as long as the pairs are listed in one order —
/// which the build-time grouping guarantees by construction.
fn side_keys(
    cols: &[crate::join::KeyColumn],
    ctx: &EvalCtx,
) -> Option<(Vec<i64>, Vec<crate::relational::Key>)> {
    let (positions, first) = key_column_values(cols.first()?, ctx)?;
    if cols.len() == 1 {
        return Some((positions, first));
    }
    let mut parts: Vec<Vec<crate::relational::Key>> = Vec::with_capacity(cols.len());
    parts.push(first);
    for c in &cols[1..] {
        let (p, k) = key_column_values(c, ctx)?;
        // Every column of one side runs over the SAME loop symbol, so a length
        // or position disagreement means the gate does not describe this node.
        if p != positions {
            return None;
        }
        parts.push(k);
    }
    let keys = (0..positions.len())
        .map(|t| crate::relational::skolem(parts.iter().map(|p| p[t].clone()).collect(), false))
        .collect();
    Some((positions, keys))
}

/// The cache key of one `on` gate in this context: its build-time id, plus the
/// length and a content fingerprint of each DATA key column.
///
/// Split out of the old `resolve_equality_index` so the planner can probe the
/// cache -- and so decide whether a gate is free -- without reading a single
/// key.
fn equality_cache_key(g: &crate::join::OnGate, ctx: &EvalCtx) -> Option<EqGateKey> {
    use crate::join::KeyColumn;
    let mut lens: SmallVec<[usize; 2]> = SmallVec::new();
    let mut fp: u64 = 0xcbf2_9ce4_8422_2325;
    for c in g.cols_l.iter().chain(g.cols_r.iter()) {
        if let KeyColumn::Column(name) = c {
            let n = with_named_array(name, ctx, |a| {
                column_fingerprint(a, &mut fp);
                a.len()
            })?;
            lens.push(n);
        }
    }
    Some((g.id, lens, fp))
}

/// Both sides of an `on` gate, as `(positions, keys)` per side.
///
/// `None` declines the gate, and the lowered `filter` predicate then produces
/// the same answer over the full product.
fn equality_sides(g: &crate::join::OnGate, ctx: &EvalCtx) -> Option<EqSides> {
    let (pos_l, keys_l) = side_keys(&g.cols_l, ctx)?;
    let (pos_r, keys_r) = side_keys(&g.cols_r, ctx)?;
    Some((pos_l, keys_l, pos_r, keys_r))
}

/// The match set plus the two SIDE LENGTHS -- `|L|` and `|R|`, the positions
/// each key column is defined at. The lengths are the denominator of the §5.24
/// selectivity estimate, and they fall out of the same `side_keys` pass that
/// built the keys, so they cost nothing to carry.
///
/// Takes the keyed sides rather than reading them, because the planner has
/// already read them to price this gate and reading a multi-million-row key
/// column twice is the term issue #418 left standing.
fn index_from_sides(sides: EqSides) -> (crate::broad_phase::OverlapIndex, usize, usize) {
    let (pos_l, keys_l, pos_r, keys_r) = sides;
    let (n_l, n_r) = (pos_l.len(), pos_r.len());
    // Canonical-key-ordered matches (§5.5 rule 5) mapped back onto the two
    // symbols' own values. `OverlapIndex` then re-sorts them position-ascending,
    // which is what makes the driven walk an order-preserving subsequence of the
    // full product; both orders are pure functions of the input.
    //
    // Handed over by VALUE (issue #418). This vector is the whole match set --
    // millions of pairs on a star join -- and nothing here reads it again, so
    // `from_owned_pairs` sorts it in place instead of copying it a third time.
    let pairs: Vec<(i64, i64)> = crate::relational::equijoin(&keys_l, &keys_r)
        .into_iter()
        .map(|(i, j)| (pos_l[i], pos_r[j]))
        .collect();
    (
        crate::broad_phase::OverlapIndex::from_owned_pairs(pairs),
        n_l,
        n_r,
    )
}

/// One contracted dimension's enumeration source: its own ascending interval,
/// or the explicit ascending value list the gate restricted it to.
enum DimSrc<'a> {
    Range(i64, i64),
    List(&'a [i64]),
}

impl DimSrc<'_> {
    #[inline]
    fn len(&self) -> usize {
        match self {
            DimSrc::Range(lo, hi) => (hi - lo + 1).max(0) as usize,
            DimSrc::List(v) => v.len(),
        }
    }
    #[inline]
    fn at(&self, i: usize) -> i64 {
        match self {
            DimSrc::Range(lo, _) => lo + i as i64,
            DimSrc::List(v) => v[i],
        }
    }
}

/// One contracted dimension's admitted value list, ACCUMULATED across gates.
///
/// The first gate that restricts a dim hands over its own partner slice — the
/// common case, and no allocation; a second gate intersects into an owned
/// vector. Both are ascending and duplicate-free (an [`crate::broad_phase::OverlapIndex`]
/// sorts and dedups its pairs), so the intersection is a linear merge and is
/// itself an ascending, duplicate-free SUBSEQUENCE of the dim's own range.
enum Restriction<'a> {
    /// One gate's partner list, borrowed from its index.
    Slice(&'a [i64]),
    /// Two or more gates' intersection.
    Owned(Vec<i64>),
}

impl Restriction<'_> {
    #[inline]
    fn as_slice(&self) -> &[i64] {
        match self {
            Restriction::Slice(s) => s,
            Restriction::Owned(v) => v,
        }
    }
}

/// Intersect `slot` with one more gate's ascending partner list.
///
/// Returns `false` when the result is EMPTY — no leaf is admitted for this
/// output cell at all, which is §5.5.6's identity fill and not a hole.
fn intersect_restriction<'a>(slot: &mut Option<Restriction<'a>>, parts: &'a [i64]) -> bool {
    match slot.take() {
        None => {
            let ok = !parts.is_empty();
            *slot = Some(Restriction::Slice(parts));
            ok
        }
        Some(cur) => {
            let a = cur.as_slice();
            let mut out: Vec<i64> = Vec::with_capacity(a.len().min(parts.len()));
            let (mut i, mut j) = (0usize, 0usize);
            while i < a.len() && j < parts.len() {
                match a[i].cmp(&parts[j]) {
                    std::cmp::Ordering::Less => i += 1,
                    std::cmp::Ordering::Greater => j += 1,
                    std::cmp::Ordering::Equal => {
                        out.push(a[i]);
                        i += 1;
                        j += 1;
                    }
                }
            }
            let ok = !out.is_empty();
            *slot = Some(Restriction::Owned(out));
            ok
        }
    }
}

/// [`reduce_contraction`] under the node's join gates, DRIVING the enumeration
/// CONJUNCTIVELY (CONFORMANCE_SPEC.md §5.24).
///
/// `ranges` is this cell's resolved contraction bounds (the same slice the
/// ungated path walks). The output-index tuple is already bound in
/// `ctx.loop_binds`. `gates` is every drivable clause, ordered most selective
/// first by [`resolve_join_gates`].
///
/// The gates compose by CONJUNCTION — that was always the semantics (§5.5.8:
/// "every gate still restricts the admitted set"); what changed is that the
/// conjunction now drives instead of only one member of it. Concretely, each
/// gate whose OTHER side is an already-bound output index contributes the
/// partner list of that bound position, and a contracted dim enumerates the
/// INTERSECTION of every such list rather than one of them. On moves.esm's
/// four-clause `tech_fraction` the difference is 2,320,704 leaves against
/// 2,601 — the relational answer, which is the count of tuples the four
/// clauses TOGETHER admit.
///
/// It stays bit-identical for the same reason the single-gate driver did: each
/// list is ascending and duplicate-free, so their intersection is an
/// order-preserving subsequence of the dim's own ascending range, and every
/// leaf it drops is one the lowered equality `filter` would have excluded.
pub(super) fn reduce_contraction_gated(
    spec: &ReduceSpec,
    ranges: &[(i64, i64)],
    gates: &[(JoinGate, GatePlacement)],
    ctx: &mut EvalCtx,
) -> f64 {
    use crate::broad_phase::Side;
    let &ReduceSpec {
        contract_names,
        reduce,
        ..
    } = spec;

    // ---- Phase 1: the conjunction of every gate with one side BOUND --------
    let mut restrict: SmallVec<[Option<Restriction<'_>>; 4]> =
        (0..ranges.len()).map(|_| None).collect();
    // The one both-contracted gate that will drive the partner-restricted walk
    // (§5.5.8's fourth shape). `gates` is selectivity-ordered, so this is the
    // most selective of them; the others stay per-leaf `filter` tests, which is
    // exactly what they were.
    let mut pair_gate: Option<(&JoinGate, usize, usize, bool)> = None;
    // Did ANY gate describe this node's loops? When none does we are in the
    // pre-driver position and walk the full product, exactly as before.
    let mut placed = false;

    for (g, place) in gates {
        match (place.src, place.tgt) {
            // Both bound: a single membership test (§5.5.8, third case).
            (GateAxis::Output, GateAxis::Output) => {
                let (Some(&l), Some(&r)) = (
                    ctx.loop_binds.get(&g.sym_src),
                    ctx.loop_binds.get(&g.sym_tgt),
                ) else {
                    continue;
                };
                placed = true;
                if !g.index.contains(l, r) {
                    return reduce.identity();
                }
            }
            // One bound, one contracted: the contracted dim enumerates the
            // bound position's partners (§5.5.8, second case) — intersected
            // with whatever the gates before it admitted.
            (GateAxis::Contracted(d), GateAxis::Output) => {
                let (Some(&r), Some(&(lo, hi))) = (ctx.loop_binds.get(&g.sym_tgt), ranges.get(d))
                else {
                    continue;
                };
                placed = true;
                let parts = g.index.partners_in(Side::Tgt, r, lo, hi);
                if !intersect_restriction(&mut restrict[d], parts) {
                    return reduce.identity();
                }
            }
            (GateAxis::Output, GateAxis::Contracted(d)) => {
                let (Some(&l), Some(&(lo, hi))) = (ctx.loop_binds.get(&g.sym_src), ranges.get(d))
                else {
                    continue;
                };
                placed = true;
                let parts = g.index.partners_in(Side::Src, l, lo, hi);
                if !intersect_restriction(&mut restrict[d], parts) {
                    return reduce.identity();
                }
            }
            // Both contracted, on DIFFERENT dims: the pair list binds two axes
            // at once. Only one such gate can drive the walk; the rest remain
            // per-leaf tests.
            (GateAxis::Contracted(a), GateAxis::Contracted(b)) if a != b => {
                placed = true;
                if pair_gate.is_none() {
                    let (p, q, bound_is_src) = if a < b { (a, b, true) } else { (b, a, false) };
                    pair_gate = Some((g, p, q, bound_is_src));
                }
            }
            // Both sides on ONE contracted dim (two columns of one table), or a
            // symbol this node does not bind: nothing a pair list can drive.
            // The lowered `filter` still applies it (§5.5.8).
            _ => {}
        }
    }

    // ---- Phase 2: enumerate ------------------------------------------------
    let mut srcs = full_sources(ranges);
    if placed {
        for (d, r) in restrict.iter().enumerate() {
            if let Some(r) = r {
                srcs[d] = DimSrc::List(r.as_slice());
            }
        }
    }

    let Some((gate, p, q, bound_is_src)) = pair_gate else {
        return reduce_over_sources(spec, &srcs, ctx);
    };

    // The PAIRS fast path: the two gated dims are the ONLY contracted dims and
    // nothing else restricted them, so the pair list binds the whole tuple and
    // the walk can skip straight to the matches instead of probing per value.
    if contract_names.len() == 2 && restrict[0].is_none() && restrict[1].is_none() {
        // The contraction odometer varies `contract_names[1]` FASTEST, so the
        // product order over the surviving tuples is the pair list sorted by
        // (contract_names[0] position, contract_names[1] position). With p < q
        // and exactly two dims, p is 0, so the src side is the slow one exactly
        // when the src is the earlier dim.
        let src_is_slow = bound_is_src;
        let (lo0, hi0) = ranges[0];
        let (lo1, hi1) = ranges[1];
        let mut tuples: Vec<(i64, i64)> = gate
            .index
            .pairs()
            .map(|(l, r)| if src_is_slow { (l, r) } else { (r, l) })
            .filter(|&(a, b)| a >= lo0 && a <= hi0 && b >= lo1 && b <= hi1)
            .collect();
        if !src_is_slow {
            tuples.sort_unstable();
        }
        return reduce_over_pairs(spec, &tuples, ctx);
    }

    // Otherwise walk the product in its usual order, except that the LATER
    // gated dim enumerates only the partners of the EARLIER one's current
    // binding — intersected with whatever Phase 1 already admitted there.
    let mut acc = reduce.identity();
    drive_partner_restricted(spec, &srcs, gate, p, q, bound_is_src, 0, &mut acc, ctx);
    acc
}

/// One level of the general both-contracted driven walk (see the tail of
/// [`reduce_contraction_gated`]): dim `q` — the LATER of the two gated dims —
/// enumerates only the gate partners of dim `p`'s current binding, restricted
/// to what `srcs[q]` already admits; every other dim walks its own source in
/// the same odometer order (last dim fastest, which is what recursing
/// depth-first on ascending `d` produces).
#[allow(clippy::too_many_arguments)]
fn drive_partner_restricted(
    spec: &ReduceSpec,
    srcs: &[DimSrc],
    gate: &JoinGate,
    p: usize,
    q: usize,
    bound_is_src: bool,
    d: usize,
    acc: &mut f64,
    ctx: &mut EvalCtx,
) {
    let &ReduceSpec {
        contract_names,
        body,
        reduce,
        filter,
        cell,
    } = spec;
    if d == srcs.len() {
        crate::broad_phase::bump_overlap_enum_visits(1);
        if !filter_excludes(filter, cell, ctx) {
            let term = eval(body, ctx).as_scalar().unwrap_or(f64::NAN);
            *acc = reduce.combine(*acc, term);
        }
        return;
    }
    if d == q {
        let Some(&bound) = ctx.loop_binds.get(&contract_names[p]) else {
            return;
        };
        let side = if bound_is_src {
            crate::broad_phase::Side::Src
        } else {
            crate::broad_phase::Side::Tgt
        };
        match &srcs[q] {
            // Borrowed from the gate, which is disjoint from `ctx` — no
            // per-level allocation on a walk that runs once per interior tuple.
            DimSrc::Range(lo, hi) => {
                let parts = gate.index.partners_in(side, bound, *lo, *hi);
                for i in 0..parts.len() {
                    let v = parts[i];
                    set_bind(&mut ctx.loop_binds, &contract_names[d], v);
                    drive_partner_restricted(spec, srcs, gate, p, q, bound_is_src, d + 1, acc, ctx);
                }
            }
            // Phase 1 already restricted this dim; walk the intersection of the
            // two ascending lists in place rather than materialising it.
            DimSrc::List(vals) => {
                let parts = gate.index.partners(side, bound);
                let (mut i, mut j) = (0usize, 0usize);
                while i < vals.len() && j < parts.len() {
                    match vals[i].cmp(&parts[j]) {
                        std::cmp::Ordering::Less => i += 1,
                        std::cmp::Ordering::Greater => j += 1,
                        std::cmp::Ordering::Equal => {
                            set_bind(&mut ctx.loop_binds, &contract_names[d], vals[i]);
                            drive_partner_restricted(
                                spec,
                                srcs,
                                gate,
                                p,
                                q,
                                bound_is_src,
                                d + 1,
                                acc,
                                ctx,
                            );
                            i += 1;
                            j += 1;
                        }
                    }
                }
            }
        }
        return;
    }
    let s = &srcs[d];
    for i in 0..s.len() {
        set_bind(&mut ctx.loop_binds, &contract_names[d], s.at(i));
        drive_partner_restricted(spec, srcs, gate, p, q, bound_is_src, d + 1, acc, ctx);
    }
}

fn full_sources(ranges: &[(i64, i64)]) -> SmallVec<[DimSrc<'_>; 4]> {
    ranges
        .iter()
        .map(|&(lo, hi)| DimSrc::Range(lo, hi))
        .collect()
}

/// The gated unroll: an odometer over per-dimension sources with the LAST
/// dimension varying fastest — bit-for-bit the order
/// [`crate::simulate_array::layout::CartesianTuples`] walks, so a restricted
/// dimension emits the exact subsequence of the terms the full product emitted.
fn reduce_over_sources(spec: &ReduceSpec, srcs: &[DimSrc], ctx: &mut EvalCtx) -> f64 {
    let &ReduceSpec {
        contract_names,
        body,
        reduce,
        filter,
        cell,
    } = spec;
    let mut acc = reduce.identity();
    let n = srcs.len();
    if n == 0 {
        // Pointwise (no contracted index) — the same arm `reduce_contraction`
        // takes, returning the body itself rather than `0̄ ⊕ body` so a `-0.0`
        // term stays `-0.0`.
        crate::broad_phase::bump_overlap_enum_visits(1);
        return if filter_excludes(filter, cell, ctx) {
            acc
        } else {
            eval(body, ctx).as_scalar().unwrap_or(f64::NAN)
        };
    }
    if srcs.iter().any(|s| s.len() == 0) {
        return acc;
    }
    let mut odom: SmallVec<[usize; 4]> = SmallVec::from_elem(0usize, n);
    loop {
        crate::broad_phase::bump_overlap_enum_visits(1);
        for (d, name) in contract_names.iter().enumerate() {
            set_bind(&mut ctx.loop_binds, name, srcs[d].at(odom[d]));
        }
        if !filter_excludes(filter, cell, ctx) {
            let term = eval(body, ctx).as_scalar().unwrap_or(f64::NAN);
            acc = reduce.combine(acc, term);
        }
        let mut d = n;
        loop {
            if d == 0 {
                return acc;
            }
            d -= 1;
            odom[d] += 1;
            if odom[d] < srcs[d].len() {
                break;
            }
            odom[d] = 0;
        }
    }
}

/// The PAIRS drive shape: the two contracted symbols are bound TOGETHER from
/// the gate's candidate pairs (already reordered to match the odometer's
/// slow/fast convention), so the emitted term sequence is the exact
/// subsequence the filtered full product emitted.
fn reduce_over_pairs(spec: &ReduceSpec, tuples: &[(i64, i64)], ctx: &mut EvalCtx) -> f64 {
    let &ReduceSpec {
        contract_names,
        body,
        reduce,
        filter,
        cell,
    } = spec;
    let mut acc = reduce.identity();
    for &(a, b) in tuples {
        crate::broad_phase::bump_overlap_enum_visits(1);
        set_bind(&mut ctx.loop_binds, &contract_names[0], a);
        set_bind(&mut ctx.loop_binds, &contract_names[1], b);
        if filter_excludes(filter, cell, ctx) {
            continue;
        }
        let term = eval(body, ctx).as_scalar().unwrap_or(f64::NAN);
        acc = reduce.combine(acc, term);
    }
    acc
}

/// A recognized **forward prefix scan**: a `faq` whose single contracted
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

/// The outer-tuple-invariant description of one forward prefix scan
/// (esm-spec §4.3.1): the detected [`PrefixScan`], the two symbols it binds,
/// the swept bounds, and the term body/semiring. Built once outside the
/// outer-cell loop; [`run_prefix_scan`] takes it as one argument.
pub(super) struct ScanSweep<'a> {
    pub(super) scan: PrefixScan,
    /// The scanned OUTPUT index symbol (the axis the accumulator sweeps).
    pub(super) i_name: &'a str,
    /// The contracted symbol the monotone filter admits (`j <= i` / `j < i`).
    pub(super) j_name: &'a str,
    /// Inclusive `(lo, hi)` bounds of the scanned axis.
    pub(super) bounds: (i64, i64),
    pub(super) body: &'a Expr,
    pub(super) reduce: ReduceKind,
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
    sweep: &ScanSweep,
    ctx: &mut EvalCtx,
    mut emit: impl FnMut(i64, f64, &EvalCtx),
) {
    let &ScanSweep {
        scan,
        i_name,
        j_name,
        bounds: (lo, hi),
        body,
        reduce,
    } = sweep;
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
    /// compiled-rule driver: a standalone `faq` materialized by
    /// [`eval_faq`], and an `AlgebraicRule::ArrayLoop` observed. Both used
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
pub(super) fn with_faq_pool<R>(f: impl FnOnce(&mut Pool) -> R) -> R {
    ARRAYOP_POOL.with(|p| match p.try_borrow_mut() {
        Ok(mut pool) => f(&mut pool),
        Err(_) => f(&mut Pool::default()),
    })
}

/// The evaluation parameters of a standalone `faq` node.
///
/// Extracted in ONE place so the per-cell oracle ([`eval_faq`]) and the
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
    /// Surviving `join` clauses. Either kind of gate — a spatial OVERLAP gate
    /// (CONFORMANCE_SPEC.md §5.5.6) or a resolved value-equality `on` gate
    /// (§5.5.8) — is resolved into a candidate pair index that DRIVES the
    /// enumeration instead of merely testing it (see [`resolve_join_gates`]). A
    /// value-equality clause is ADDITIONALLY lowered into `filter` at build
    /// time, so a path that ignores `join` still computes the same answer.
    pub(super) join: Option<&'n [JoinClause]>,
}

impl ArrayOpSpec<'_> {
    /// Does this aggregate carry a join GATE whose range symbols were resolved
    /// at build time — an OVERLAP gate (§5.5.6) or a value-equality `on` gate
    /// (§5.5.8) — i.e. one the driver can act on?
    ///
    /// The whole-array overlay and the tape lowering both consult this and
    /// decline: they evaluate the FULL product as shifted whole-array slices,
    /// which is bit-identical but reinstates exactly the `O(∏ranges)` cost the
    /// gate exists to remove.
    pub(super) fn has_drivable_overlap(&self) -> bool {
        self.join.is_some_and(|j| {
            j.iter().any(|c| {
                c.on_gate.is_some()
                    || c.overlap
                        .as_ref()
                        .is_some_and(|o| o.sym_src.is_some() && o.sym_tgt.is_some())
            })
        })
    }
}

/// Extract an aggregate node's evaluation parameters. `None` when the node
/// carries no body (`expr`), which the oracle reports as `NaN`.
pub(super) fn faq_spec(node: &ExpressionNode) -> Option<ArrayOpSpec<'_>> {
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
    // `None` here means "this node is not an evaluable aggregate", which every
    // caller already handles. An out-of-enum ⊕ spelling would land in that same
    // bucket, so it is NOT reported here — it is rejected up front by
    // `aggregate::validate_oplus_spellings`, which `ArrayCompiled::from_model`
    // runs over the whole model before any of this is reachable.
    let reduce = effective_reduce_kind(node.semiring.as_deref(), node.reduce.as_deref()).ok()?;
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
        join: node.join.as_deref(),
    })
}

pub(super) fn eval_faq(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // Standalone faq (embedded as an expression, not as the top-level
    // of an equation LHS/RHS). Build the output array by iterating
    // ranges, binding loop indices, evaluating the body.
    //
    // Supports generalized einsum: indices present in `ranges` but absent
    // from `output_idx` are contracted (summed/reduced) per `reduce`.
    let spec = match faq_spec(node) {
        Some(s) => s,
        None => return Value::Scalar(f64::NAN),
    };
    // Resolve a join GATE ONCE per node — a spatial OVERLAP broad phase
    // (§5.5.6) or a value-equality `on` match set (§5.5.8); either candidate
    // index is memoized across calls. When one resolves it DRIVES the
    // contraction below instead of the full product — the whole point of the
    // pushdown rewrite emitting a gate onto each rewritten binning aggregate,
    // and of `join.on` being a gate rather than a predicate.
    // §5.24: resolve EVERY drivable clause and drive on the most SELECTIVE one,
    // not on whichever the author typed first. `resolve_join_gates` returns them
    // already ordered, ties broken by document position, so the choice is a pure
    // function of the document and the data — and it can only change the node's
    // COST, because every clause is also lowered into `filter` (§5.5.8) and the
    // driven walk is an order-preserving subsequence of the filtered product.
    let gates: Vec<(JoinGate, GatePlacement)> = spec
        .join
        .map(|j| resolve_join_gates(j, &*ctx))
        .unwrap_or_default()
        .into_iter()
        .map(|g| {
            let place = gate_placement(&g, spec.idx_names, &spec.contract_names);
            (g, place)
        })
        .collect();
    let ArrayOpSpec {
        idx_names,
        ranges,
        body,
        contract_names,
        contract_dims,
        reduce,
        filter,
        join: _,
    } = spec;

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
    // `ctx.recur.is_none()`: CONFORMANCE_SPEC §5.19.2 forbids evaluating anything
    // inside a recurrence sweep through the whole-array overlay. The overlay
    // resolves names through the state/observed tables, which do not hold the
    // array being swept, and it batches cells the sweep must order — so it would
    // be both wrong and unordered. Declining is conservative: a nested aggregate
    // that does NOT read the swept array would also be correct vectorized, but
    // telling the two apart per node buys nothing on an inherently sequential
    // rule.
    if !shape.is_empty() && scan.is_none() && gates.is_empty() && ctx.recur.is_none() {
        // The pool is the THREAD's, not a fresh one per call: a stencil-heavy
        // model materializes dozens of standalone aggregates per RHS evaluation
        // and a per-call `Pool::default()` started empty every time, so every
        // kernel intermediate went to the allocator.
        let materialized = with_faq_pool(|pool| {
            try_eval_faq_vectorized(
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
                // `try_eval_faq_vectorized` already verified the value covers
                // the output box exactly (bailing to `None` otherwise) and lifted
                // a bare scalar into an owned box buffer, so a plain view→owned
                // suffices.
                let out = vv.view().expect("vectorized faq has a view").to_owned();
                vv.release(pool);
                out
            })
        });
        if let Some(out) = materialized {
            return Value::Array(Box::new(out));
        }
    }

    // ---- Rank-0 contraction as a whole-array map, then one fold -----------
    // A fully contracted node (`total = Σ_r x[r]`) has no output box for the
    // overlay above to evaluate over, so it used to be folded term by term,
    // one tree walk per term. Its body is a pure map over the CONTRACTION box
    // instead: evaluate that once through the overlay, with the contracted
    // symbols bound as the box's axes, and fold the resulting array. The fold
    // visits the terms in row-major order — the order `CartesianTuples` walks
    // the contraction odometer, last index fastest — starting from the
    // identity with the same `combine`, so the result is bit-identical to the
    // loop below. Declined (to that loop) for a filter, which the loop SKIPS
    // rather than folding the identity (not bit-identical for signed zeros),
    // for bounds that vary, and wherever the overlay above is declined.
    if shape.is_empty()
        && !contract_names.is_empty()
        && filter.is_none()
        && scan.is_none()
        && gates.is_empty()
        && ctx.recur.is_none()
        && let Some(box_ranges) = static_ranges.as_deref()
    {
        let terms = with_faq_pool(|pool| {
            try_eval_faq_vectorized(
                &contract_names,
                box_ranges,
                body,
                &[],
                &[],
                reduce,
                None,
                &*ctx,
                pool,
            )
            .map(|(vv, _ops)| {
                let out = vv.view().expect("vectorized faq has a view").to_owned();
                vv.release(pool);
                out
            })
        });
        if let Some(terms) = terms {
            let acc = terms
                .iter()
                .fold(reduce.identity(), |acc, &t| reduce.combine(acc, t));
            return Value::Scalar(acc);
        }
    }
    // An EMPTY output box (a size-0 index set) has no cell to evaluate: the
    // result is the empty array of that box. The buffer below is sized
    // `max(1)` for the rank-0 case, and reshaping its one element into a box
    // with a zero extent is not a value but a panic.
    if shape.contains(&0) {
        return Value::Array(Box::new(ArrayD::zeros(IxDyn(&shape))));
    }
    // From here on the node is walked per cell. A rank-0 node with nothing to
    // contract is a single scalar evaluation, not a walk.
    let is_walk = !shape.is_empty() || !contract_names.is_empty();
    if is_walk {
        note_per_cell_walk();
        // A strict caller has already been told to refuse (see
        // [`StopAtFirstCell`]): this walk's value is never read.
        if per_cell_walk_stopped() {
            return if shape.is_empty() {
                Value::Scalar(0.0)
            } else {
                Value::Array(Box::new(ArrayD::zeros(IxDyn(&shape))))
            };
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
        let sweep = ScanSweep {
            scan,
            i_name: &idx_names[scan.axis],
            j_name: &contract_names[0],
            // One step of one scan when the walk is to stop at its first cell.
            bounds: if stop_at_first_cell() {
                (scan_lo, scan_hi.min(scan_lo))
            } else {
                (scan_lo, scan_hi)
            },
            body,
            reduce,
        };
        let mut full = vec![0i64; ranges.len()];
        let mut outer = CartesianTuples::new(&outer_ranges);
        while let Some(otuple) = outer.next() {
            for ((d, name), val) in outer_axes.iter().zip(otuple.iter()) {
                set_bind(&mut ctx.loop_binds, name, *val);
                full[*d] = *val;
            }
            run_prefix_scan(&sweep, ctx, |i, acc, _| {
                note_per_cell_cell();
                full[scan.axis] = i;
                buf[multi_to_flat_col_major(&full, &shape, &origin)] = acc;
            });
            if stop_after_first_cell() {
                break;
            }
        }
    } else {
        let cellbox = CellBox {
            names: idx_names,
            origin: &origin,
        };
        let spec = ReduceSpec {
            contract_names: &contract_names,
            body,
            reduce,
            filter,
            cell: Some(&cellbox),
        };
        // Per-node cost accounting. The counter is thread-local and bumped
        // only on the gate-driven unroll, so the delta across this output loop
        // is exactly the leaves THIS aggregate enumerated.
        let stats_from = (!gates.is_empty()).then(crate::broad_phase::overlap_enum_visits);
        let mut tuples = CartesianTuples::new(&ranges);
        while let Some(tuple) = tuples.next() {
            for (name, val) in idx_names.iter().zip(tuple.iter()) {
                set_bind(&mut ctx.loop_binds, name, *val);
            }
            let v = if gates.is_empty() {
                reduce_contraction(&spec, &contract_dims, static_ranges.as_deref(), ctx)
            } else {
                // This cell's contraction bounds: the hoisted static ones when
                // every dim is cell-independent, else re-derived here exactly
                // as `reduce_contraction` does.
                let derived: SmallVec<[(i64, i64); 4]>;
                let cell_ranges: &[(i64, i64)] = match static_ranges.as_deref() {
                    Some(r) => r,
                    None => {
                        derived = contract_dims.iter().map(|d| d.concrete(ctx)).collect();
                        &derived
                    }
                };
                reduce_contraction_gated(&spec, cell_ranges, &gates, ctx)
            };
            let flat = multi_to_flat_col_major(tuple, &shape, &origin);
            buf[flat] = v;
            if is_walk {
                note_per_cell_cell();
                if stop_after_first_cell() {
                    break;
                }
            }
        }
        if let Some(before) = stats_from {
            let desc = gates
                .iter()
                .map(|(g, _)| format!("{}~{}:{}", g.sym_src, g.sym_tgt, g.index.len()))
                .collect::<Vec<_>>()
                .join(",");
            eprintln!(
                "[join-gate] gates={desc} cells={total} leaves={}",
                crate::broad_phase::overlap_enum_visits().wrapping_sub(before),
            );
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

/// Would the per-cell [`eval_faq`] path recognize this `makearray` region
/// value as a forward prefix scan (esm-spec §4.3.1)?
///
/// The whole-array overlay evaluates a region value through
/// `eval_vec_nested_aggregate` → `try_eval_faq_vectorized`, which does NOT
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
pub(super) fn region_value_is_prefix_scan(value: &Expr) -> bool {
    let Expr::Operator(n) = value else {
        return false;
    };
    if n.filter.is_none() {
        return false;
    }
    let Some(spec) = faq_spec(n) else {
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
    let regions: &[Vec<[crate::types::RegionBound; 2]>] = node.regions.as_deref().unwrap_or(&[]);
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
            // Every bound is folded to an integer at load (§9.7.6); an unfolded
            // one is refused the same way a malformed region is.
            let Some([r_lo, r_hi]) = crate::types::region_bounds(r) else {
                return Value::Scalar(f64::NAN);
            };
            lo[d] = lo[d].min(r_lo);
            hi[d] = hi[d].max(r_hi);
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
    // not through `eval_faq`, so it had no overlay entry at all: its region
    // values vectorized (they are `faq`s, which try the overlay
    // themselves) but the assembly around them stayed a per-cell
    // `CartesianTuples` walk writing through bounds-checked dynamic-stride
    // `ArrayD` indexing.
    //
    // `eval_vec_makearray` is the same region-sub-range-write assembly the
    // compiled-rule path already uses (pinned bit-identical by
    // `covered_makearray_region_dispatch`), so routing to it keeps the answer
    // identical while making the work N-independent and pool-backed.
    //
    // Gated on `loop_binds` being empty. That gate USED to be pure
    // cost-avoidance — "inside a per-cell loop the nested aggregates depend on
    // the enclosing bindings and the overlay would bail anyway, once per cell,
    // which is pure loss". Since `nested_aggregate_capture` learned to see
    // through shadowing, the bail is no longer certain, so the gate now earns
    // its keep on CORRECTNESS instead, and must stay:
    //
    // nothing below tests the region values against `ctx.loop_binds`. A nested
    // aggregate is still guarded (`eval_vec_nested_aggregate` scans those keys
    // itself), but a region value that names an enclosing per-cell index
    // DIRECTLY is not: the box carries no symbols, so `eval_vec_variable` walks
    // past `cbind` and `syms` straight into the state/observed/parameter
    // tables, and a loop index sharing a name with one of those would silently
    // resolve to the wrong value. Admitting non-empty `loop_binds` therefore
    // requires an `expr_mentions` scan of every region value against every
    // bound name — which is exactly the per-axis, per-region body walk costed
    // below, now paid once per cell — to buy a speed-up that only applies
    // inside a loop something else already fell back to.
    //
    // The box carries NO output-index symbols, because a `makearray` reached
    // here is not a cell of an enclosing `faq`: nothing is bound around it,
    // and each region value is evaluated exactly once (not once per cell), so
    // `eval_vec_nested_aggregate`'s hoisting precondition — "the nested body
    // must not depend on an enclosing bound index" — is vacuously satisfied and
    // its `expr_mentions` scan has nothing to test. That is not cosmetic:
    // placeholder names cost one full walk of the region body PER AXIS PER
    // REGION, and on a 7-region PPM template that scan alone was 43% of the run.
    if !overlay_off()
        && ctx.loop_binds.is_empty()
        && !shape.contains(&0)
        && !values.iter().any(region_value_is_prefix_scan)
        // See the same gate in `eval_faq`: CONFORMANCE_SPEC §5.19.2.
        && ctx.recur.is_none()
    {
        let bx = VecBox {
            syms: &[],
            lo: &lo,
            shape: &shape,
            cnames: &[],
            cvals: &[],
        };
        let materialized = with_faq_pool(|pool| {
            let mut ops = 0usize;
            eval_vec_makearray(node, &bx, &*ctx, pool, &mut ops).map(|vv| {
                let out = vv
                    .view()
                    .expect("vectorized makearray has a view")
                    .to_owned();
                vv.release(pool);
                out
            })
        });
        if let Some(out) = materialized {
            return Value::Array(Box::new(out));
        }
    }

    let mut arr = ArrayD::<f64>::zeros(IxDyn(&shape));
    for (region, value_expr) in regions.iter().zip(values.iter()) {
        let v = eval(value_expr, ctx);
        // Iterate the region's index tuples.
        let mut ranges: Vec<(i64, i64)> = Vec::with_capacity(region.len());
        for r in region {
            // Unreachable with a folded document (the bounding-box loop above
            // already refused a symbolic bound), but keeps this loop total.
            let Some([r_lo, r_hi]) = crate::types::region_bounds(r) else {
                return Value::Scalar(f64::NAN);
            };
            ranges.push((r_lo, r_hi));
        }
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

/// `broadcast` (esm-spec §4.3.4): apply the scalar operator named in `fn`
/// element-wise to the operands in `args`.
///
/// The whole implementation is one delegation, and that is the fix for issue
/// #101. It used to left-fold `args` through the BINARY kernel table, which
/// made a one-operand `broadcast` the IDENTITY: `broadcast(fn = "-", [x])`
/// returned `x`, unnegated, with no error — and so did `fn: "neg"`,
/// `fn: "log"`, and even `fn: "not_a_real_op"`, because a missing kernel simply
/// never got the chance to run. A missing `fn` silently became `"+"`.
///
/// Delegating to [`eval_op_named`] makes `broadcast(fn = F, args)` evaluate
/// through EXACTLY the arm that evaluates `{"op": F, "args": args}` — unary
/// maps, `neg`, `ifelse` and the n-ary folds alike — so the two spellings agree
/// bit for bit and cannot drift.
pub(super) fn eval_broadcast(node: &ExpressionNode, ctx: &mut EvalCtx) -> Value {
    // Both gates below are `unreachable!` for the same reason the operator-name
    // catch-all in `eval_op_named` is: every entry point into this evaluator
    // runs `op_registry::check_broadcast_fn` first (via `check_no_spatial_ops`
    // / `check_evaluable`), so reaching one means a gate was bypassed — a bug
    // in THIS crate. The alternative, a NaN sentinel, is indistinguishable from
    // a legitimate result, which is precisely how #101 stayed invisible.
    let Some(fn_name) = node.broadcast_fn.as_deref() else {
        unreachable!(
            "`broadcast` reached the evaluator with no `fn`; every entry point must gate \
             with op_registry::check_broadcast_fn() first"
        )
    };
    assert!(
        crate::op_registry::is_scalar_operator(fn_name),
        "`broadcast` fn '{fn_name}' is not a scalar operator and reached the evaluator; \
         every entry point must gate with op_registry::check_broadcast_fn() first"
    );
    eval_op_named(fn_name, node, ctx)
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
        Expr::operator(ExpressionNode {
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
            "faq",
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

    /// `true` is the one §4.2 core op that nothing downstream consumes — it is
    /// a boolean LITERAL — so it belongs on the evaluable side of the audit
    /// above, and its value is fixed by this evaluator's own 0/1 boolean
    /// convention. Pinned as a number, not merely as "is_evaluable_op", because
    /// the whole point of the fix is that `faq{expr: true}` COUNTS.
    #[test]
    fn the_true_literal_evaluates_to_one() {
        assert!(crate::op_registry::is_core_op("true"), "§4.2 lists `true`");
        assert!(is_evaluable_op("true"), "and this evaluator answers for it");
        match eval_it(&node("true", Vec::new())).expect("`true` evaluates") {
            Value::Scalar(v) => assert_eq!(v, 1.0),
            other => panic!("`true` must be the scalar 1.0, got {other:?}"),
        }
    }

    /// The §4.2 core set minus this evaluator's rules, pinned member by member.
    /// Nine ops, each eliminated by an earlier stage — and NOTHING else, which
    /// is what makes the build-time gate in `compile.rs` a complete answer to
    /// the `unreachable!` backstop rather than a patch for the op that was
    /// reported. A tenth entry appearing here means a new op reached the
    /// registry without an evaluation rule and can panic; it must be given a
    /// rule or added to this list deliberately.
    #[test]
    fn the_core_minus_evaluable_gap_is_exactly_nine_ops() {
        const CORE: &[&str] = &[
            "+",
            "-",
            "*",
            "/",
            "^",
            "neg",
            "exp",
            "log",
            "ln",
            "log10",
            "sqrt",
            "abs",
            "sign",
            "floor",
            "ceil",
            "sin",
            "cos",
            "tan",
            "asin",
            "acos",
            "atan",
            "sinh",
            "cosh",
            "tanh",
            "asinh",
            "acosh",
            "atanh",
            "atan2",
            "min",
            "max",
            "ifelse",
            "==",
            "!=",
            "<",
            "<=",
            ">",
            ">=",
            "and",
            "or",
            "not",
            "D",
            "ic",
            "Pre",
            "const",
            "true",
            "fn",
            "enum",
            "table_lookup",
            "apply_expression_template",
            "faq",
            "makearray",
            "index",
            "broadcast",
            "reshape",
            "transpose",
            "concat",
            "skolem",
            "rank",
            "distinct",
            "argmin",
            "argmax",
            "intersect_polygon",
            "polygon_intersection_area",
        ];
        for op in CORE {
            assert!(
                crate::op_registry::is_core_op(op),
                "{op} is listed here but the registry does not carry it"
            );
        }
        let mut gap: Vec<&str> = CORE
            .iter()
            .copied()
            .filter(|op| !is_evaluable_op(op))
            .collect();
        gap.sort_unstable();
        assert_eq!(
            gap,
            vec![
                "apply_expression_template",
                "argmax",
                "argmin",
                "distinct",
                "enum",
                "ic",
                "rank",
                "skolem",
                "table_lookup",
            ]
        );
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
    //! clipped ring, reduced by the M1 machinery in [`eval_faq`]. This is the
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
            "op": "faq",
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
            "op": "faq",
            "args": [],
            "semiring": "sum_product",
            "output_idx": ["i"],
            "expr": "k",
            "ranges": { "i": [1, 2], "k": [1, 1] }
        }))
        .unwrap();
        if let Some(node) = agg.node_mut() {
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

#[cfg(test)]
mod unbound_name_fault_tests {
    //! `lookup_variable`'s final arm reports TWO different defects, and it must
    //! not report them as one (issue #181).
    //!
    //! A name the model DECLARES — an observed whose rule has not run because
    //! the materialization order stalled — resolves through the same arm as a
    //! name declared nowhere at all. Reporting the first as
    //! `E_TREEWALK_UNBOUND_NAME`, "bound by NOTHING in scope", is a claim about
    //! the DOCUMENT that the evaluator is not in a position to make, and it was
    //! routinely false: the name it landed on was an observed that is declared,
    //! defined and referenced perfectly well, and the message said nothing about
    //! the dependency cycle that actually stalled the walk (esm-spec §4.9.6).

    use super::{lookup_variable, take_const_array_oob};
    use crate::faq::empty_derived_extents;
    use crate::simulate_array::{ArrMap, ConstArrayScope, EvalEnv};
    use ndarray::ArrayD;
    use std::cell::RefCell;
    use std::collections::{HashMap, HashSet};

    /// Resolve `name` against an evaluation whose maps are all empty and whose
    /// DECLARED set is `declared`, and return the latched fault.
    fn fault_for(name: &str, declared: &[&str]) -> String {
        let empty_arrays = ArrMap::default();
        let rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
        let forcing: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
        let declared: HashSet<String> = declared.iter().map(|s| (*s).to_string()).collect();
        let env = EvalEnv {
            state_arrays: &empty_arrays,
            params: &[],
            param_names: &[],
            t: 0.0,
            derived_rings: &rings,
            derived_extents: empty_derived_extents(),
            forcing: &forcing,
            cse: None,
            const_lits: None,
            const_arrays: ConstArrayScope::empty(),
            declared: &declared,
        };
        let ctx = env.ctx(&empty_arrays);
        take_const_array_oob(); // discard anything an earlier test left
        let _ = lookup_variable(name, &ctx);
        take_const_array_oob().expect("an unresolvable read must latch a fault")
    }

    /// A name the model declares — an observed whose rule has not run — is NOT
    /// unbound, and saying so was the defect: the message named a variable that
    /// is declared, defined and referenced correctly, and said nothing about
    /// the dependency cycle that actually stalled the walk.
    #[test]
    fn a_declared_name_with_no_value_is_not_reported_as_unbound() {
        let msg = fault_for("in_pbl", &["in_pbl", "hpbl"]);
        assert!(
            msg.contains("E_TREEWALK_UNRESOLVED_ORDER") && msg.contains("in_pbl"),
            "a declared name gets the order fault, naming itself: {msg}"
        );
        assert!(
            !msg.contains("E_TREEWALK_UNBOUND_NAME: "),
            "and MUST NOT be reported as bound by nothing: {msg}"
        );
        assert!(
            msg.contains("observed_cycle"),
            "and points at the check that names the real defect: {msg}"
        );
    }

    /// The other half, unchanged: a name declared NOWHERE keeps the §5.23
    /// diagnosis. Splitting the arm must not weaken the case it was written for.
    #[test]
    fn an_undeclared_name_still_reports_unbound() {
        let msg = fault_for("undeclaredFloor", &["in_pbl", "hpbl"]);
        assert!(
            msg.contains("E_TREEWALK_UNBOUND_NAME") && msg.contains("undeclaredFloor"),
            "a name nothing declares is still the §5.23 fault: {msg}"
        );
    }
}

#[cfg(test)]
mod gate_cache_budget_tests {
    use super::*;

    /// A gate index of `n` pairs.
    fn ix(n: i64) -> Option<Rc<crate::broad_phase::OverlapIndex>> {
        Some(Rc::new(crate::broad_phase::OverlapIndex::from_owned_pairs(
            (1..=n).map(|i| (i, i)).collect(),
        )))
    }

    /// What one [`ix`] of `n` pairs costs the budget. Read from the index
    /// rather than written down, because the price includes the run table and
    /// anything else the index owns — see
    /// [`crate::broad_phase::OverlapIndex::resident_pairs`] — and a literal
    /// here would silently stop matching the moment that changed.
    fn cost(n: i64) -> usize {
        ix(n).retained_pairs()
    }

    type Cache = GateCache<u32, Option<Rc<crate::broad_phase::OverlapIndex>>>;

    /// The price is the whole index, not its pair count: the two columns plus
    /// the dense run table a contiguous 1..=n span earns.
    #[test]
    fn an_entry_is_priced_by_what_it_holds_resident_not_by_its_pair_count() {
        assert!(
            cost(100) > 100,
            "pricing an index at len() ignores the run table it also owns"
        );
    }

    #[test]
    fn eviction_drops_the_least_recently_used_index_first() {
        let u = cost(100);
        let mut c: Cache = GateCache::new();
        c.insert(1, ix(100));
        c.insert(2, ix(100));
        assert_eq!(c.pairs, 2 * u);
        // Touch 1, making 2 the least recently used.
        assert!(c.get(&1).is_some());
        c.evict_to_budget(u);
        assert!(c.get(&2).is_none(), "the LRU entry survived");
        assert!(c.get(&1).is_some(), "the MRU entry was evicted");
        assert_eq!(c.pairs, u);
    }

    #[test]
    fn eviction_continues_until_the_cache_is_within_budget() {
        let u = cost(100);
        let mut c: Cache = GateCache::new();
        for k in 0..5 {
            c.insert(k, ix(100));
        }
        assert_eq!(c.pairs, 5 * u);
        c.evict_to_budget(2 * u);
        assert!(c.pairs <= 2 * u);
        // The two most recent survive; the three oldest are gone.
        assert!(c.get(&3).is_some() && c.get(&4).is_some());
        assert!(c.get(&0).is_none() && c.get(&1).is_none() && c.get(&2).is_none());
    }

    #[test]
    fn an_index_a_live_gate_still_holds_is_never_evicted() {
        let mut c: Cache = GateCache::new();
        let held = ix(100);
        c.insert(1, held.clone());
        c.evict_to_budget(0);
        assert!(
            c.get(&1).is_some(),
            "evicting an index a live gate holds frees nothing and costs a rebuild"
        );
        drop(held);
        c.evict_to_budget(0);
        assert!(c.get(&1).is_none(), "the last reference went and it stayed");
    }

    /// A gate that declined (`None`) retains nothing, so it never provokes an
    /// eviction — but it is still remembered, which is the point of caching it.
    #[test]
    fn a_declined_gate_costs_no_budget() {
        let u = cost(100);
        let mut c: Cache = GateCache::new();
        c.insert(1, ix(100));
        c.insert(2, None);
        assert_eq!(c.pairs, u);
        c.evict_to_budget(u);
        assert!(c.get(&1).is_some());
        assert!(matches!(c.get(&2), Some(None)));
    }

    /// A cache left over budget by its own last insert must not be kept there
    /// by hits alone: the entry is dropped at the next probe, and the caller
    /// rebuilds. This is the time-loop RHS, where the only probes are hits.
    #[test]
    fn a_probe_trims_an_entry_the_budget_no_longer_covers() {
        let u = cost(100);
        let mut c: Cache = GateCache::new();
        c.insert(1, ix(100));
        assert_eq!(c.pairs, u);
        assert!(
            c.get_within_budget(&1, u).is_some(),
            "an entry WITHIN budget must survive its own probe"
        );
        assert!(
            c.get_within_budget(&1, u - 1).is_none(),
            "the probe kept it"
        );
        assert_eq!(c.pairs, 0);
    }

    /// The trim skips what a live gate holds, exactly as an eviction on a miss
    /// does — dropping the cache's reference would free nothing.
    #[test]
    fn a_probe_keeps_an_index_a_live_gate_still_holds() {
        let mut c: Cache = GateCache::new();
        let held = ix(100);
        c.insert(1, held.clone());
        assert!(c.get_within_budget(&1, 0).is_some());
        drop(held);
        assert!(c.get_within_budget(&1, 0).is_none());
    }

    #[test]
    fn re_inserting_a_key_replaces_its_contribution_rather_than_adding_to_it() {
        let mut c: Cache = GateCache::new();
        c.insert(1, ix(100));
        c.insert(1, ix(10));
        assert_eq!(c.pairs, cost(10));
    }

    /// An index GROWS when a `Side::Tgt` walk builds its adjacency. The price
    /// at insert could not have known, so the probe re-reads it — otherwise
    /// that memory is outside the budget for as long as the entry lives.
    #[test]
    fn a_probe_reprices_an_index_that_grew_after_it_was_cached() {
        let held = ix(100);
        let mut c: Cache = GateCache::new();
        c.insert(1, held.clone());
        let at_insert = c.pairs;

        // Force the lazy `tgt` adjacency.
        let ix = held.as_ref().expect("an index");
        assert!(!ix.tgt_adjacency_built());
        ix.partners(crate::broad_phase::Side::Tgt, 1);
        assert!(ix.tgt_adjacency_built());

        assert_eq!(
            c.pairs, at_insert,
            "nothing has probed the cache, so the price is still the old one"
        );
        c.get_within_budget(&1, usize::MAX);
        assert!(
            c.pairs > at_insert,
            "the probe must re-read the price: {} did not grow",
            c.pairs
        );
    }
}

/// A join gate is PRICED before it is built, and one that cannot pay for
/// itself is declined (issue #418 follow-up).
///
/// [`resolve_join_gates`] used to build an index for every clause and only then
/// consult §5.24's selectivity estimate to pick a driver. A clause whose key is
/// low-cardinality matches enormously — six distinct fuel types against a
/// 1.4-million-row table is 167 million pairs — so a sibling clause that has
/// already cut that table to seven rows does not save the memory: the pairs are
/// materialised first and the selectivity is consulted second.
///
/// Now [`crate::relational::equijoin_match_count`] reads what a gate WOULD cost
/// in `O(|L| + |R|)` without writing a pair, gates are resolved cheapest-first,
/// and one that would materialise more pairs than the tuples it could prune is
/// declined.
///
/// These run INSIDE the crate rather than from `tests/`, so the planner's
/// knobs and counters stay `pub(crate)`: an integration test would have to be
/// handed `set_gate_plan` and `gate_plan_declines` across the API boundary,
/// and instrumentation is not an API. The documents still go through the
/// public `esm_problem` / `observed_field` pathway, which is the part that had
/// to be exercised end to end.
///
/// Three properties:
///
/// 1. **Declining cannot change an answer.** `crate::join` ALSO lowers every
///    `on` clause into the node's `filter`, so the equality is applied either
///    way. A run that declines must be bit-identical to one that declines
///    nothing, to the hand-written `filter` both lower to, and to a plain-Rust
///    oracle.
/// 2. **The decision rule is the documented one.** The fixture's redundant
///    gate costs exactly 125× the space it could prune, so a ratio of 124
///    declines it and 125 keeps it. That pins `reach` as well as the
///    comparison: were the sibling's narrowing not recorded, the reachable
///    space would be 500× larger and neither ratio would decline anything.
/// 3. **Never the only gate**, whatever the ratio — and the gate that survives
///    is really built, which the build counter says and a decline count of
///    zero does not.
#[cfg(all(test, not(target_arch = "wasm32")))]
mod gate_plan_tests {
    use crate::broad_phase::{
        gate_index_builds, gate_plan_declines, reset_gate_index_builds, reset_gate_plan_declines,
        set_gate_plan,
    };
    use crate::{ProblemOptions, esm_problem, observed_field};
    use ndarray::{ArrayD, IxDyn};
    use serde_json::{Value, json};
    use std::collections::HashMap;

    fn arr1(v: &[f64]) -> ArrayD<f64> {
        ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
    }

    fn ix(f: &str, i: &str) -> Value {
        json!({"op": "index", "args": [f, i]})
    }

    const FUELS: usize = 4;
    const BINS: usize = 40;
    const FACTS: usize = 4_000;
    const COUNTIES: usize = 500;

    /// The reachable space the fuel clause is weighed against once the county
    /// clause has resolved: `BINS` bins times the `FACTS / COUNTIES` fact rows
    /// the selected county leaves alive.
    const REACHABLE: usize = BINS * (FACTS / COUNTIES);
    /// What the fuel clause costs: every bin of a fuel against every fact of
    /// the same fuel.
    const FUEL_MATCHES: usize = FUELS * (BINS / FUELS) * (FACTS / FUELS);
    /// 125 — the overshoot ratio the planner computes for the fuel clause, so
    /// one below declines it and exactly this keeps it.
    const OVERSHOOT: u128 = (FUEL_MATCHES / REACHABLE) as u128;

    /// `bin` rows carry a fuel; `fact` rows carry a fuel AND a county, and the
    /// run selects ONE county. The aggregate sums a fact's weight into every
    /// bin of the same fuel, within the selected county.
    ///
    /// The two clauses are wildly different gates over the same data. The fuel
    /// one matches `BINS/FUELS · FACTS` = 40,000 pairs; the county one matches
    /// `FACTS/COUNTIES` = 8. Once the county clause has cut the fact table to
    /// 8 rows, the fuel clause can prune at most `BINS · 8` = 320 tuples, and
    /// it costs 40,000 pairs to say so — 125× over.
    struct Tables {
        bfuel: Vec<f64>,
        ffuel: Vec<f64>,
        fcounty: Vec<f64>,
        ncounty: Vec<f64>,
        weight: Vec<f64>,
    }

    impl Tables {
        fn fixture() -> Tables {
            Tables {
                bfuel: (0..BINS).map(|i| (i % FUELS) as f64).collect(),
                ffuel: (0..FACTS).map(|j| (j % FUELS) as f64).collect(),
                fcounty: (0..FACTS).map(|j| (j % COUNTIES) as f64).collect(),
                ncounty: vec![7.0],
                weight: (1..=FACTS).map(|j| j as f64).collect(),
            }
        }

        /// Folded in ascending `f`, the association the contraction odometer
        /// uses, so the oracle is bit-comparable and not merely close.
        fn oracle(&self) -> Vec<f64> {
            (0..BINS)
                .map(|b| {
                    let mut acc = 0.0f64;
                    for f in 0..FACTS {
                        if self.bfuel[b] == self.ffuel[f] && self.fcounty[f] == self.ncounty[0] {
                            acc += self.weight[f];
                        }
                    }
                    acc
                })
                .collect()
        }

        fn const_arrays(&self) -> HashMap<String, ArrayD<f64>> {
            [
                ("bfuel".to_string(), arr1(&self.bfuel)),
                ("ffuel".to_string(), arr1(&self.ffuel)),
                ("fcounty".to_string(), arr1(&self.fcounty)),
                ("ncounty".to_string(), arr1(&self.ncounty)),
                ("weight".to_string(), arr1(&self.weight)),
            ]
            .into_iter()
            .collect()
        }

        /// `gated` selects the arm: the two `join.on` clauses under test, or
        /// the hand-written conjunction they lower to — the differential
        /// baseline, which resolves no gate at all.
        fn doc(&self, gated: bool) -> Value {
            let mut vars = serde_json::Map::new();
            for (name, set) in [
                ("bfuel", "brows"),
                ("ffuel", "frows"),
                ("fcounty", "frows"),
                ("weight", "frows"),
                ("ncounty", "nrows"),
            ] {
                vars.insert(name.into(), json!({"type": "parameter", "shape": [set]}));
            }
            vars.insert("E".into(), json!({"type": "unknown", "shape": ["brows"]}));

            let mut node = json!({
                "op": "faq",
                "reduce": "+",
                "output_idx": ["b"],
                "ranges": {
                    "b": {"from": "brows"},
                    "f": {"from": "frows"},
                    "n": {"from": "nrows"}
                },
                "args": ["bfuel", "ffuel", "fcounty", "ncounty", "weight"],
                "expr": ix("weight", "f")
            });
            let obj = node.as_object_mut().unwrap();
            if gated {
                obj.insert(
                    "join".into(),
                    json!([
                        {"on": [["bfuel", "ffuel"]]},
                        {"on": [["fcounty", "ncounty"]]}
                    ]),
                );
            } else {
                obj.insert(
                    "filter".into(),
                    json!({"op": "and", "args": [
                        {"op": "==", "args": [ix("bfuel", "b"), ix("ffuel", "f")]},
                        {"op": "==", "args": [ix("fcounty", "f"), ix("ncounty", "n")]}
                    ]}),
                );
            }

            json!({
                "esm": "1.1.0",
                "metadata": {"name": "join_gate_plan"},
                "index_sets": {
                    "brows": {"kind": "interval", "size": BINS},
                    "frows": {"kind": "interval", "size": FACTS},
                    "nrows": {"kind": "interval", "size": 1}
                },
                "models": {"J": {
                    "variables": Value::Object(vars),
                    "equations": [{"lhs": "E", "rhs": node}]
                }}
            })
        }
    }

    fn prepare(doc: &Value, t: &Tables) -> crate::EsmProblem {
        esm_problem(
            doc,
            (0.0, 0.0),
            ProblemOptions {
                model_name: Some("J".into()),
                const_arrays: t.const_arrays(),
                build_providers: Vec::new(),
                // A gate-driven join is walked per cell by the pipeline, which
                // a strict native refuses (#484); the gate planner is what is
                // under test here, on the reference evaluator.
                compiler: Some(crate::Compiler::Interpreter),
                ..Default::default()
            },
        )
        .expect("prepare")
    }

    /// Materialize `E`, returning `(values, gates declined, indices built)`.
    fn run(t: &Tables, gated: bool) -> (Vec<f64>, u64, u64) {
        let doc = t.doc(gated);
        reset_gate_plan_declines();
        reset_gate_index_builds();
        let prep = prepare(&doc, t);
        let (declines, builds) = (gate_plan_declines(), gate_index_builds());
        let field = observed_field(&prep, "E").expect("E materialized");
        (field.iter().copied().collect(), declines, builds)
    }

    /// Run the gated document under one planner setting, restoring it after.
    fn run_planned(t: &Tables, ratio: u128, floor: usize) -> (Vec<f64>, u64, u64) {
        let (pr, pf) = set_gate_plan(ratio, floor);
        let out = run(t, true);
        set_gate_plan(pr, pf);
        out
    }

    #[test]
    fn a_declined_gate_changes_no_answer() {
        let t = Tables::fixture();
        let oracle = t.oracle();
        assert!(
            oracle.iter().any(|v| *v > 0.0),
            "the fixture must actually match something"
        );

        let (filtered, filter_declines, _) = run(&t, false);
        assert_eq!(
            filter_declines, 0,
            "the un-gated arm resolves no gate, so it can decline none"
        );

        // Floor 0 and ratio 0: decline any gate a sibling has already made
        // redundant. The fuel clause is 40,000 pairs against 320 reachable.
        let (planned, planned_declines, _) = run_planned(&t, 0, 0);
        // A floor above the fuel clause's match count puts it out of the
        // planner's reach, so every gate is built — the pre-planner behaviour.
        let (unplanned, unplanned_declines, _) = run_planned(&t, u128::MAX, usize::MAX);

        assert_eq!(
            planned_declines, 1,
            "the redundant fuel gate should be declined, and only it"
        );
        assert_eq!(
            unplanned_declines, 0,
            "a floor out of reach must decline nothing"
        );

        assert_eq!(
            planned, unplanned,
            "declining a gate changed an answer; it may only change cost"
        );
        assert_eq!(
            planned, filtered,
            "the planned arm and the hand-written filter must agree bit for bit"
        );
        assert_eq!(
            planned, oracle,
            "neither arm reproduces the plain-Rust oracle"
        );
    }

    #[test]
    fn the_ratio_is_weighed_against_what_a_sibling_gate_left_reachable() {
        // The arithmetic itself, not just its endpoints. The fuel clause costs
        // `OVERSHOOT` times the space the county clause left reachable, so the
        // comparison `matches > ratio · reachable` must flip between
        // `OVERSHOOT - 1` and `OVERSHOOT` and nowhere else.
        //
        // This is also the only assertion on `reach`: the fuel clause's own
        // sides are 40 × 4,000 = 160,000, so if the county gate's narrowing
        // were NOT recorded the overshoot would be well under 1 and no ratio
        // in this range could decline anything.
        assert_eq!(OVERSHOOT, 125, "the fixture's overshoot moved");
        let t = Tables::fixture();
        let oracle = t.oracle();

        let (just_under, declined, _) = run_planned(&t, OVERSHOOT - 1, 1);
        let (exactly, kept, _) = run_planned(&t, OVERSHOOT, 1);
        assert_eq!(
            declined, 1,
            "a ratio just under the overshoot must decline the redundant gate"
        );
        assert_eq!(
            kept, 0,
            "a ratio at the overshoot must keep it: the test is `>`, not `>=`"
        );

        // And the floor is the other term: the same uneconomic ratio declines
        // nothing once the gate is too small to be worth the risk.
        let (floored, floored_declines, _) = run_planned(&t, OVERSHOOT - 1, FUEL_MATCHES + 1);
        assert_eq!(
            floored_declines, 0,
            "a gate below the floor must be kept however uneconomic it looks"
        );

        assert_eq!(just_under, oracle, "the declining arm lost the answer");
        assert_eq!(exactly, oracle, "the keeping arm lost the answer");
        assert_eq!(floored, oracle, "the floored arm lost the answer");
    }

    #[test]
    fn a_gate_with_no_cheaper_sibling_is_kept() {
        // One clause alone: nothing has narrowed its symbols, so `space` is
        // the full side product and the gate is always worth building. This is
        // the guard that the planner cannot leave a walk ungated by accident.
        let t = Tables::fixture();
        let mut doc = t.doc(true);
        doc["models"]["J"]["equations"][0]["rhs"]["join"] = json!([{"on": [["bfuel", "ffuel"]]}]);
        doc["models"]["J"]["equations"][0]["rhs"]["ranges"]
            .as_object_mut()
            .unwrap()
            .remove("n");

        let (pr, pf) = set_gate_plan(0, 0);
        reset_gate_plan_declines();
        reset_gate_index_builds();
        let prep = prepare(&doc, &t);
        let (declines, builds) = (gate_plan_declines(), gate_index_builds());
        set_gate_plan(pr, pf);

        assert_eq!(
            declines, 0,
            "the only gate in a node must never be declined, whatever the ratio"
        );
        // A decline count of zero is also what a gate that was never resolved
        // at all reports, so the build counter is what actually says the walk
        // is gated.
        assert!(
            builds >= 1,
            "no index was built: the node is ungated, not kept"
        );
        let field = observed_field(&prep, "E").expect("E materialized");
        let got: Vec<f64> = field.iter().copied().collect();
        let want: Vec<f64> = (0..BINS)
            .map(|b| {
                (0..FACTS)
                    .filter(|&f| t.bfuel[b] == t.ffuel[f])
                    .map(|f| t.weight[f])
                    .sum()
            })
            .collect();
        assert_eq!(got, want);
    }
}
