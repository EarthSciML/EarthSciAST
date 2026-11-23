//! The per-cell oracle interpreter: recursive [`Value`] evaluation of every
//! expression node (arithmetic, transcendentals, array ops, `faq`
//! contractions with ragged/derived bounds) plus the
//! standalone [`eval_expression`] entry point. This path is the correctness
//! reference the tape is verified against.

use super::gate_walk::{CellBufs, GatePlan, TupleSink};
use super::scalar_ops::{with_bin_kernel, with_un_kernel};
use super::*;
use crate::compile_error::CompileError;
use crate::faq::effective_reduce_kind;
use crate::types::{ExpressionNode, JoinClause};

/// Stack-inlined per-axis `(lo, hi)` range list, the same rank≤4 argument
/// [`DimI`]/[`DimU`] rest on. Used where a range list is rebuilt on every RHS
/// evaluation ([`ArrayOpSpec`]), so it does not reach the allocator.
pub(super) type RangeVec = SmallVec<[(i64, i64); 4]>;

/// The extent of the derived index set produced by the FAQ node `from_faq`:
/// the cardinality the build-time value-invention engine (RFC §6.1 / §5.5)
/// recorded under the producing aggregate's `id`. It runs once at setup, off
/// the per-step hot path, so the extent is constant for the whole run; this is
/// what sizes an ISRM emission axis (`emis_src_cells`, invented by the
/// point-in-cell overlap producer).
///
/// A producer with no extent never reaches here: the build and the standalone
/// entry both refuse it as `derived_index_set_unmaterialized`, since its empty
/// range would read as a plausible 0 (esm-spec §9.6.6). A derived range that
/// has to size an OUTPUT axis never reaches here either: it is resolved far
/// earlier, and much more strictly, by `crate::faq::resolve_index_set_ref`,
/// which errors rather than invent a zero-length axis.
pub(super) fn derived_extent(from_faq: &str, ctx: &EvalCtx) -> i64 {
    ctx.derived_extents.get(from_faq).copied().unwrap_or(0)
}

pub(super) fn eval(expr: &Expr, ctx: &mut EvalCtx) -> Value {
    match expr {
        // Literals round on ingress (§ `crate::precision`): under Float32 a
        // literal that reaches an output through no operator at all must still
        // be the binary32 value, and `0.1` is not a binary32 number. Identity
        // under Float64.
        Expr::Number(n) => Value::Scalar(crate::precision::round(*n)),
        Expr::Integer(n) => Value::Scalar(crate::precision::round(*n as f64)),
        Expr::Variable(name) => match ctx.param_binding(name) {
            Some(b) => ctx.in_caller(|ctx| eval(&b, ctx)),
            None => lookup_variable(name, ctx),
        },
        Expr::Operator(node) if node.op == crate::operator_refs::APPLY_OP => eval_call(node, ctx),
        Expr::Operator(node) => eval_op(node, ctx),
    }
}

/// Evaluate an operator reference (esm-spec §9.6.4) as a call: the body of
/// the instance it names, with each parameter the body reads standing for the
/// reference's binding, evaluated in the caller's frame where the body reads
/// it (call by name), with the loop symbols bound there. That is the value,
/// and the operations in the order, the reference's expansion denotes.
pub(super) fn eval_call(node: &std::sync::Arc<ExpressionNode>, ctx: &mut EvalCtx) -> Value {
    let instance = match ctx.ops.instance_of_node(node) {
        Ok(i) => i,
        Err(e) => {
            latch_fault(fault_code::UNCODED, e.to_string());
            return Value::Scalar(f64::NAN);
        }
    };
    ctx.frames.push(CallFrame {
        node: std::sync::Arc::clone(node),
        instance: std::sync::Arc::clone(&instance),
    });
    let v = eval(&instance.body, ctx);
    ctx.frames.pop();
    v
}

impl EvalCtx<'_> {
    /// The binding of `name` when it is a parameter of the innermost call in
    /// progress ([`eval_call`]).
    fn param_binding(&self, name: &str) -> Option<Expr> {
        let f = self.frames.last()?;
        if !f.instance.is_param(name) {
            return None;
        }
        f.node.bindings.as_ref()?.get(name).cloned()
    }

    /// Run `f` in the frame of the innermost call's caller.
    fn in_caller<R>(&mut self, f: impl FnOnce(&mut Self) -> R) -> R {
        let top = self.frames.pop();
        let r = f(self);
        if let Some(t) = top {
            self.frames.push(t);
        }
        r
    }

    /// `e` read through the calls in progress: when it is a parameter of the
    /// innermost call, its binding (followed while that is itself a parameter
    /// of the caller), with how many innermost frames to leave to read it.
    /// `None` when `e` is not a parameter.
    fn through_params(&self, e: &Expr) -> Option<(Expr, usize)> {
        let mut cur = match e {
            Expr::Variable(_) => e.clone(),
            _ => return None,
        };
        let mut depth = self.frames.len();
        let mut up = 0;
        while let Expr::Variable(name) = &cur
            && depth > 0
        {
            let f = &self.frames[depth - 1];
            if !f.instance.is_param(name) {
                break;
            }
            let Some(b) = f.node.bindings.as_ref().and_then(|b| b.get(name)) else {
                break;
            };
            cur = b.clone();
            depth -= 1;
            up += 1;
        }
        (up > 0).then_some((cur, up))
    }

    /// Run `f` with the `up` innermost call frames left.
    fn up_frames<R>(&mut self, up: usize, f: impl FnOnce(&mut Self) -> R) -> R {
        let keep = self.frames.len() - up;
        let saved = self.frames.split_off(keep);
        let r = f(self);
        self.frames.extend(saved);
        r
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
        latch_fault(
            fault_code::RECUR_UNAVAILABLE,
            format!(
                "E_TREEWALK_RECUR_UNAVAILABLE: '{name}' is read BARE inside its own recurrence \
             definition — the whole array does not exist during the sweep. Read it through \
             `index` at a strictly earlier position instead (esm-spec §4.3.1.1)."
            ),
        );
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
    latch_unbound_read(name, ctx.declared);
    Value::Scalar(f64::NAN)
}

/// Latch the fault for a read that NOTHING in scope produced a value for:
/// [`lookup_variable`]'s last resort, shared with the tape's forcing load
/// (`Instr::LoadForcing`), which reads the same forcing channel and has to fail
/// the same way when the channel holds no entry for the name.
pub(super) fn latch_unbound_read(name: &str, declared: &HashSet<String>) {
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
    if declared.contains(name) {
        latch_fault(
            fault_code::UNRESOLVED_ORDER,
            format!(
                "E_TREEWALK_UNRESOLVED_ORDER: '{name}' IS declared in this model, but nothing had \
             produced a value for it at the point this expression was evaluated. For an observed \
             that means its defining rule had not run yet — the usual cause is a dependency \
             cycle among observed variables, which no evaluation order satisfies (esm-spec \
             §4.9.6). Run `esm validate`: it reports the cycle as `observed_cycle` and names the \
             observeds on it. This is NOT an undeclared name — see E_TREEWALK_UNBOUND_NAME for \
             that (CONFORMANCE_SPEC §5.23)."
            ),
        );
        return;
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
    latch_fault(
        fault_code::UNBOUND_NAME,
        format!(
            "E_TREEWALK_UNBOUND_NAME: '{name}' is referenced in an expression but bound by \
         NOTHING in scope — it is not the independent variable, a loop index, a state, an \
         observed, a parameter, or a forcing channel. A name declared nowhere in the \
         document is a structural error (`esm validate` reports it against the equation); \
         reaching evaluation means one route skipped that gate. Fail-closed per \
         CONFORMANCE_SPEC §5.23: never a NaN sentinel, which `max(x, floor)` or any \
         comparison would launder into a plausible number by dropping the operand."
        ),
    );
}

/// Latch the fault for a forcing-buffer entry whose shape is not the box a
/// compiled program was built against (`Instr::LoadForcing`). The interpreter
/// reads whatever array the buffer holds; a compiled program fixed each box at
/// build, so it cannot, and says so rather than reading the entry through the
/// wrong box.
pub(super) fn latch_forcing_shape_mismatch(name: &str, built: &[usize], held: &[usize]) {
    latch_fault(
        fault_code::UNCODED,
        format!(
            "the forcing buffer holds '{name}' with shape {held:?}, but the compiled program \
         reads it as {built:?} (the shape the buffer held, or else the variable declared, \
         when the program was built). A compiled program's boxes are fixed at build: a \
         forcing field that changes shape between refreshes cannot be read by it."
        ),
    );
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
/// It is NOT the same set as `crate::op_registry::is_core_op`. The registry
/// answers "may this op appear in a legal AST"; this answers "can the per-cell
/// evaluator produce a number for it". The gap between them is real and is
/// exactly what [`check_evaluable_all`] rejects:
///
/// * the build-time query op `distinct` — resolved by
///   [`crate::value_invention`] before evaluation;
/// * form / lowering ops (`ic`, `enum`, `apply_expression_template`) —
///   consumed by their lowering passes;
/// * the open rewrite-target tier (`integral`, a typo'd `"expp"`, a user op)
///   — must be lowered to a stencil first.
#[must_use]
pub fn is_evaluable_op(op: &str) -> bool {
    use crate::op_registry::{CoreOp, OtherOp as O};
    let Some(core) = CoreOp::from_name(op) else {
        return false;
    };
    match core {
        CoreOp::Unary(_) | CoreOp::Compare(_) => true,
        CoreOp::Other(o) => match o {
            // Arithmetic, including the deprecated word spellings.
            O::Add | O::Sub | O::Mul | O::Div | O::Pow | O::PowWord | O::Neg => true,
            O::Atan2 | O::Min | O::Max => true,
            O::And | O::Or | O::Not | O::Ifelse => true,
            // Form ops with a defined runtime meaning here. `true` is a
            // nullary boolean LITERAL (esm-spec §4.2: "an always-true join /
            // `filter` predicate"), not something a lowering pass consumes.
            O::D | O::Pre | O::Const | O::True | O::False => true,
            // Array ops.
            O::Index
            | O::Faq
            | O::Makearray
            | O::Reshape
            | O::Transpose
            | O::Concat
            | O::Broadcast => true,
            // A transparent wrapper that evaluates its one operand at a stated
            // element type. Never authored.
            O::Precision => true,
            // An operator reference is evaluated as a call of its instance
            // ([`eval_call`]); the gates check that it names one.
            O::ApplyExpressionTemplate => true,
            // Consumed before evaluation: the load-time ops and the build-time
            // query op.
            O::Ic | O::Enum | O::Distinct => false,
        },
    }
}

/// Reject every operator in `expr` that the array interpreter cannot evaluate.
///
/// This is the RUNTIME operator gate, and it closes the last silent-NaN hole in
/// the evaluator. It layers two checks:
///
/// 1. [`check_no_spatial_ops`] (the shared [`crate::op_registry`] gate) — the
///    open rewrite-target tier (a spatial `D`, `integral`, a user op, a typo) and
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
///
/// It checks every expression of `roots` and, once each, the body of every
/// operator instance they reach through `ops` (esm-spec §9.6.3 constraint 6:
/// an operator a reference's body holds reaches evaluation as surely as one
/// written in place). A reference that names no instance is refused as an
/// unevaluable `apply_operator`.
pub(crate) fn check_evaluable_all<'a>(
    roots: impl IntoIterator<Item = &'a Expr>,
    ops: &Instances,
) -> Result<(), CompileError> {
    let roots: Vec<&Expr> = roots.into_iter().collect();
    for e in &roots {
        check_no_spatial_ops(e)?;
        check_evaluable_ops(e)?;
    }
    for i in reachable_instances(roots, ops)? {
        check_no_spatial_ops(&i.body)?;
        check_evaluable_ops(&i.body)?;
    }
    Ok(())
}

/// Every operator instance `roots` reach through `ops`, each once; a reference
/// that names none is refused as an unevaluable `apply_operator`.
pub(crate) fn reachable_instances<'a>(
    roots: impl IntoIterator<Item = &'a Expr>,
    ops: &Instances,
) -> Result<Vec<std::sync::Arc<crate::operator_refs::Instance>>, CompileError> {
    ops.reachable(roots).map_err(|e| match e {
        crate::operator_refs::InstanceError::Unknown(_) => CompileError::UnevaluableOperatorError {
            op: crate::operator_refs::APPLY_OP.to_string(),
        },
        other => CompileError::build_err(other.to_string()),
    })
}

/// The [`is_evaluable_op`] half of [`check_evaluable_all`], applied over the whole
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

/// [`check_evaluable_all`] for an entry point whose answer is ONE NUMBER computed
/// from scalar bindings ([`eval_scalar_expression`]).
///
/// On top of the runtime gate it refuses, naming the operator, what has no
/// scalar value over scalar operands: the array / tensor ops, an array-valued
/// `const`, and a structural `D`, which [`eval_op_named`] answers with the
/// `NaN` sentinel because a right-hand-side `D` never legitimately reaches
/// evaluation (esm-spec §4.2).
pub(crate) fn check_scalar_evaluable(expr: &Expr) -> Result<(), CompileError> {
    check_scalar_evaluable_in(expr, Instances::empty())
}

/// [`check_scalar_evaluable`] with the operator instances a reference in
/// `expr` names: each body it reaches is checked once, as `expr` is.
pub(crate) fn check_scalar_evaluable_in(expr: &Expr, ops: &Instances) -> Result<(), CompileError> {
    check_evaluable_all([expr], ops)?;
    check_scalar_ops(expr)?;
    for i in reachable_instances([expr], ops)? {
        check_scalar_ops(&i.body)?;
    }
    Ok(())
}

/// The [`check_scalar_evaluable`] layer that refuses the ops with no scalar
/// value, applied over the whole tree.
fn check_scalar_ops(expr: &Expr) -> Result<(), CompileError> {
    let Expr::Operator(node) = expr else {
        return Ok(());
    };
    use crate::op_registry::{CoreOp, OtherOp as O};
    let no_scalar_value = match node.core_op() {
        Some(CoreOp::Other(
            O::D
            | O::Index
            | O::Faq
            | O::Makearray
            | O::Reshape
            | O::Transpose
            | O::Concat
            | O::Broadcast,
        )) => true,
        Some(CoreOp::Other(O::Const)) => !node
            .value
            .as_ref()
            .is_some_and(crate::ConstValue::is_number),
        // Everything else has a scalar value over scalar operands, or was
        // refused by the gates above.
        Some(CoreOp::Unary(_) | CoreOp::Compare(_)) | None => false,
        Some(CoreOp::Other(
            O::Add
            | O::Sub
            | O::Mul
            | O::Div
            | O::Pow
            | O::PowWord
            | O::Neg
            | O::Precision
            | O::Atan2
            | O::Min
            | O::Max
            | O::Ifelse
            | O::And
            | O::Or
            | O::Not
            | O::Ic
            | O::Pre
            | O::True
            | O::False
            | O::Enum
            | O::ApplyExpressionTemplate
            | O::Distinct,
        )) => false,
    };
    if no_scalar_value {
        return Err(CompileError::UnevaluableOperatorError {
            op: node.op.clone(),
        });
    }
    node.try_for_each_child(&mut check_scalar_ops)
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
    use crate::op_registry::{CoreOp, OtherOp as O};
    // Unreachable by construction: EVERY path into this evaluator is gated.
    // The compiled-model path gates in `from_model` (`check_no_spatial_ops`),
    // and the public `eval_expression` gates with `check_evaluable`, which
    // additionally rejects the evaluable-core ops with no rule here. A NaN
    // sentinel would be indistinguishable from a legitimate numerical result,
    // so reaching an unknown name means a gate was bypassed — a bug in THIS
    // crate — and it fails loudly rather than corrupting the answer.
    let unreachable_op = || -> ! {
        unreachable!(
            "operator '{op}' reached eval_op without an evaluation rule; \
             every entry point must gate with check_evaluable_all() first"
        )
    };
    let Some(core) = CoreOp::from_name(op) else {
        unreachable_op()
    };
    match core {
        // Elementwise / scalar arithmetic. If any operand is an array,
        // return an array (with ndarray broadcasting).
        CoreOp::Other(O::Add | O::Sub | O::Mul | O::Div | O::Pow) => {
            eval_arith(op, &node.args, ctx)
        }
        // The word spelling of `^`, folded through the `^` kernel itself.
        CoreOp::Other(O::PowWord) => eval_arith("^", &node.args, ctx),

        // The deprecated word spelling of unary `-` (esm-spec §4.2): the loader
        // rewrites it away, but an expression built in code can still reach
        // this oracle. Route it through `negate` — the same primitive the
        // unary-minus arm of `eval_arith` uses — so the two spellings agree.
        // Unary only; a non-unary `neg` is malformed ⇒ the NaN sentinel.
        CoreOp::Other(O::Neg) => {
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
        CoreOp::Other(O::Precision) => {
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
        CoreOp::Unary(_) => eval_unary(op, &node.args, ctx),

        CoreOp::Other(O::Atan2) => eval_binary(op, &node.args, ctx),

        // n-ary min/max (esm-spec §4.2 — arity ≥ 2). Reuse the n-ary
        // arithmetic combiner so array operands broadcast through the same
        // ndarray path as `+`/`*`.
        CoreOp::Other(O::Min | O::Max) => eval_arith(op, &node.args, ctx),

        // Comparison operators — return 1.0 (true) or 0.0 (false) via the
        // [`BinCode`] kernels the tape also runs. BROADCAST when either operand is an array, so a per-cell
        // predicate like `code >= 1` over an [x,y] fuel grid yields an [x,y] mask
        // rather than collapsing to a scalar NaN.
        CoreOp::Compare(_) => {
            if node.args.len() != 2 {
                return Value::Scalar(f64::NAN);
            }
            eval_binary(op, &node.args, ctx)
        }

        // Logical connectives (esm-spec §4.2): nonzero is true, the result is a
        // strict 1.0/0.0 flag, broadcast over array operands like arithmetic —
        // e.g. `and(code >= 1, code <= 13)` over an [x,y] fuel grid.
        CoreOp::Other(O::And | O::Or) => eval_arith(op, &node.args, ctx),
        CoreOp::Other(O::Not) => eval_unary(op, &node.args, ctx),

        CoreOp::Other(O::Ifelse) => eval_ifelse(node, ctx),

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
        CoreOp::Other(O::D) => Value::Scalar(f64::NAN),

        // `Pre` (previous-value marker) is only meaningful under event handling;
        // on the RHS it passes its argument through. Guard the arity so a
        // malformed `Pre` node from `eval_expression` yields the NaN sentinel
        // rather than panicking on `args[0]`.
        CoreOp::Other(O::Pre) => {
            if node.args.is_empty() {
                Value::Scalar(f64::NAN)
            } else {
                eval(&node.args[0], ctx)
            }
        }

        // Inline literal (esm-spec §4): a number → scalar; a nested numeric
        // array → a row-major array.
        CoreOp::Other(O::Const) => eval_const(node),

        // Array ops.
        CoreOp::Other(O::Index) => eval_index(node, ctx),
        CoreOp::Other(O::Faq) => eval_faq(node, ctx),
        CoreOp::Other(O::Makearray) => eval_makearray(node, ctx),
        CoreOp::Other(O::Reshape) => eval_reshape(node, ctx),
        CoreOp::Other(O::Transpose) => eval_transpose(node, ctx),
        CoreOp::Other(O::Concat) => eval_concat(node, ctx),

        // Element-wise application of the scalar operator named in `fn`
        // (esm-spec §4.3.4). Re-enter with that name against the SAME node —
        // see [`eval_op_named`]. Because the scalar-operator set excludes
        // `broadcast` itself, this recursion is one level deep.
        CoreOp::Other(O::Broadcast) => eval_broadcast(node, ctx),

        // The nullary boolean literal (esm-spec §4.2). This evaluator's boolean
        // convention is already 1.0 / 0.0 — every comparison and `and`/`or`/
        // `not` produces it — so the value is forced, not chosen, and it is
        // what Python (`numpy_interpreter`: `if op == "true": return 1.0`),
        // Julia (`geometry_compile.jl`: `_NK_LITERAL, literal=1.0`) and this
        // crate's own `value_invention::vi_eval` (`Val::Bool(true)`) already
        // produce. In a `sum_product` contraction it is the multiplicative
        // identity, so `faq{expr: true}` COUNTS the admitted tuples —
        // which is exactly what a semi-join wants to say.
        CoreOp::Other(O::True) => Value::Scalar(1.0),
        // Its counterpart, in the same encoding (a false comparison is 0.0).
        CoreOp::Other(O::False) => Value::Scalar(0.0),

        // Consumed before evaluation; `check_evaluable` refuses them.
        // A reference is evaluated by [`eval`] as a call; one reaching here
        // came through `broadcast`'s `fn`, which names no reference.
        CoreOp::Other(O::Ic | O::Enum | O::ApplyExpressionTemplate | O::Distinct) => {
            unreachable_op()
        }
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
/// **This function and the array path of [`eval_arith`] (a left fold of
/// [`combine`]) must compute the same value for every LEGAL node**, so a
/// scalar operand and an array operand of the same node mean the same thing.
/// It is a plain left fold of [`apply_binary`], identical in kernel and in
/// order to the array path. Arities that would need special-casing (`-`/`/`/`^`
/// with other than two operands, `min`/`max` with fewer than two) are rejected
/// before evaluation by [`crate::op_registry`], so none is handled here.
pub(crate) fn fold_scalar(op: &str, vs: &[f64]) -> f64 {
    // A zero-arity arithmetic node is not legal (the registry rejects it); the
    // NaN sentinel is the module's convention for an unevaluable node.
    let Some((first, rest)) = vs.split_first() else {
        return f64::NAN;
    };
    // `and`/`or` are the one family whose n-ary fold is not a repeated binary
    // apply: they return a strict 1.0/0.0 flag over ALL operands, whereas
    // left-folding `apply_binary` would compare a raw operand against a flag.
    // `apply_binary` agrees with this for the legal arity (>= 2).
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
/// fuel-model lookup `ifelse(and(code>=1, code<=13), lookup, default)`
/// materializes at `code`'s `[x,y]` shape instead of collapsing to a scalar. A
/// true select (not a `cond*a + (1-cond)*b` blend) keeps a `NaN` in the
/// *unchosen* branch — e.g. an out-of-table lookup — from contaminating the
/// result.
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

/// A kernel closure from [`with_bin_kernel`] as a function pointer.
macro_rules! fn_ptr2 {
    ($k:expr) => {{
        let k: fn(f64, f64) -> f64 = $k;
        k
    }};
}

/// A kernel closure from [`with_un_kernel`] as a function pointer.
macro_rules! fn_ptr1 {
    ($k:expr) => {{
        let k: fn(f64) -> f64 = $k;
        k
    }};
}

pub(crate) fn apply_binary(op: &str, x: f64, y: f64) -> f64 {
    // Under `element_type: "Float32"` the whole table is the binary32 one;
    // Float64 calls the binary64 kernels inline.
    if crate::precision::is_f32() {
        return binary_kernel_f32_of(BinCode::of(op))(x, y);
    }
    macro_rules! call {
        ($k:expr) => {
            ($k)(x, y)
        };
    }
    with_bin_kernel!(f64, BinCode::of(op), call)
}

/// [`apply_binary`]'s per-element arithmetic with the **op-name lookup lifted
/// out**: resolve the name once, then call the returned kernel per element.
///
/// It and [`apply_binary`] both expand the one kernel list, [`with_bin_kernel`];
/// `binary_kernels_match_apply_binary` pins the two to raw IEEE bit equality
/// over every op name and a spread of operands (±0, ±inf, NaN, subnormals).
#[cfg(test)] // the code-based `binary_kernel_of` is the runtime form; this
// `&str` wrapper exists for the bit-equality pinning test below.
pub(crate) fn binary_kernel(op: &str) -> fn(f64, f64) -> f64 {
    binary_kernel_of(BinCode::of(op))
}

/// A binary/elementwise operator resolved to a compact code.
///
/// Resolving the operator name ONCE per AST node into this code, and
/// dispatching on the code afterwards, keeps string compares out of every
/// per-element kernel loop (the tape's executors, the oracle's broadcasts).
///
/// [`BinCode::Unknown`] is the "not a binary kernel" code; its kernel is the NaN
/// sentinel, matching `apply_binary`'s catch-all arm.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
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
    /// Resolve an operator name.
    pub(crate) fn of(op: &str) -> BinCode {
        crate::op_registry::CoreOp::from_name(op).map_or(BinCode::Unknown, BinCode::from_core)
    }

    /// The binary kernel a core operator folds with, or [`BinCode::Unknown`]
    /// for one that has none. `pow` shares `^`'s kernel; `-` is subtraction.
    pub(crate) const fn from_core(op: crate::op_registry::CoreOp) -> BinCode {
        use crate::op_registry::{Comparison as C, CoreOp, OtherOp as O};
        match op {
            CoreOp::Compare(c) => match c {
                C::Eq => BinCode::Eq,
                C::Ne => BinCode::Ne,
                C::Lt => BinCode::Lt,
                C::Le => BinCode::Le,
                C::Gt => BinCode::Gt,
                C::Ge => BinCode::Ge,
            },
            CoreOp::Unary(_) => BinCode::Unknown,
            CoreOp::Other(o) => match o {
                O::Add => BinCode::Add,
                O::Sub => BinCode::Sub,
                O::Mul => BinCode::Mul,
                O::Div => BinCode::Div,
                O::Pow | O::PowWord => BinCode::Pow,
                O::Atan2 => BinCode::Atan2,
                O::Min => BinCode::Min,
                O::Max => BinCode::Max,
                O::And => BinCode::And,
                O::Or => BinCode::Or,
                O::Neg
                | O::Precision
                | O::Ifelse
                | O::Not
                | O::D
                | O::Ic
                | O::Pre
                | O::Const
                | O::True
                | O::False
                | O::Enum
                | O::ApplyExpressionTemplate
                | O::Faq
                | O::Makearray
                | O::Index
                | O::Broadcast
                | O::Reshape
                | O::Transpose
                | O::Concat
                | O::Distinct => BinCode::Unknown,
            },
        }
    }
}

/// `binary_kernel` with the name already resolved to a [`BinCode`].
///
/// `binary_kernel` delegates here, so
/// `binary_kernels_match_apply_binary` pins this table to `apply_binary` bit for
/// bit over every op name and a spread of operands.
///
/// Under [`crate::precision::Precision::Float32`] it returns the binary32
/// table ([`binary_kernel_f32_of`]) instead. Resolution happens ONCE per AST
/// node on the taped path (and once per cell on the oracle's per-cell walk,
/// where the operator name is being matched anyway), so the mode read costs a
/// thread-local load where a string compare already lived. The kernels are
/// [`with_bin_kernel`]'s, the list every binary evaluator path expands.
pub(crate) fn binary_kernel_of(op: BinCode) -> fn(f64, f64) -> f64 {
    if crate::precision::is_f32() {
        return binary_kernel_f32_of(op);
    }
    with_bin_kernel!(f64, op, fn_ptr2)
}

/// [`binary_kernel_of`]'s table in **binary32**: each kernel narrows both
/// operands to `f32`, applies the `f32` operation, and widens the `f32` result.
///
/// It is [`with_bin_kernel`] instantiated at `f32` —
/// `binary_kernels_f32_are_binary32` pins each kernel to the value the same
/// expression produces when it is written directly in `f32`.
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
    with_bin_kernel!(f32, op, fn_ptr2)
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
    // See `apply_binary`: Float32 routes to the binary32 table, Float64 calls
    // the binary64 kernels inline.
    if crate::precision::is_f32() {
        return unary_kernel_f32_of(UnCode::of(op))(x);
    }
    macro_rules! call {
        ($k:expr) => {
            ($k)(x)
        };
    }
    with_un_kernel!(f64, UnCode::of(op), call)
}

/// [`apply_unary`]'s per-element map with the op-name lookup lifted out — the
/// unary counterpart of `binary_kernel`. It and [`apply_unary`] both expand
/// [`with_un_kernel`]; `unary_kernels_match_apply_unary` pins them to bit
/// equality.
#[cfg(test)] // see `binary_kernel` above: test-only pinning wrapper.
pub(crate) fn unary_kernel(op: &str) -> fn(f64) -> f64 {
    unary_kernel_of(UnCode::of(op))
}

/// A unary operator resolved to a compact code — the counterpart of
/// [`BinCode`], for the same reason (see its docs).
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
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
    /// Resolve an operator name: a unary function, `not`, or
    /// [`UnCode::Unknown`].
    pub(crate) fn of(op: &str) -> UnCode {
        use crate::op_registry::{CoreOp, OtherOp};
        match CoreOp::from_name(op) {
            Some(CoreOp::Unary(f)) => UnCode::from_unary(f),
            Some(CoreOp::Other(OtherOp::Not)) => UnCode::Not,
            Some(CoreOp::Compare(_) | CoreOp::Other(_)) | None => UnCode::Unknown,
        }
    }

    /// The kernel code of a unary function.
    pub(crate) const fn from_unary(f: crate::op_registry::UnaryFn) -> UnCode {
        use crate::op_registry::UnaryFn as F;
        match f {
            F::Exp => UnCode::Exp,
            F::Log => UnCode::Ln,
            F::Log10 => UnCode::Log10,
            F::Sqrt => UnCode::Sqrt,
            F::Abs => UnCode::Abs,
            F::Sign => UnCode::Sign,
            F::Floor => UnCode::Floor,
            F::Ceil => UnCode::Ceil,
            F::Sin => UnCode::Sin,
            F::Cos => UnCode::Cos,
            F::Tan => UnCode::Tan,
            F::Asin => UnCode::Asin,
            F::Acos => UnCode::Acos,
            F::Atan => UnCode::Atan,
            F::Sinh => UnCode::Sinh,
            F::Cosh => UnCode::Cosh,
            F::Tanh => UnCode::Tanh,
            F::Asinh => UnCode::Asinh,
            F::Acosh => UnCode::Acosh,
            F::Atanh => UnCode::Atanh,
        }
    }
}

/// `unary_kernel` with the name already resolved to a [`UnCode`]. It and
/// [`apply_unary`] both expand [`with_un_kernel`];
/// `unary_kernels_match_apply_unary` pins them to bit equality through
/// `unary_kernel`, which delegates here.
///
/// Under [`crate::precision::Precision::Float32`] it returns the binary32 table
/// ([`unary_kernel_f32_of`]) — see [`binary_kernel_of`] for why the mode read
/// sits here.
pub(crate) fn unary_kernel_of(op: UnCode) -> fn(f64) -> f64 {
    if crate::precision::is_f32() {
        return unary_kernel_f32_of(op);
    }
    with_un_kernel!(f64, op, fn_ptr1)
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
    with_un_kernel!(f32, op, fn_ptr1)
}

#[cfg(test)]
mod kernel_equivalence_tests {
    //! The tape resolves an operator name to a kernel ONCE per
    //! AST node ([`binary_kernel`]/[`unary_kernel`]) where the per-cell oracle
    //! re-matches it per element ([`apply_binary`]/[`apply_unary`]). The two
    //! paths must stay bit-identical; both expand the kernel lists in
    //! `scalar_ops`, and these tests pin the result.
    use super::*;
    use std::hint::black_box;

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
        "exp", "log", "log10", "sqrt", "abs", "sign", "floor", "ceil", "sin", "cos",
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
                // Opaque operands per `want`: see `unary_kernels_f32_are_binary32`.
                let (xf, yf) = (|| black_box(x as f32), || black_box(y as f32));
                #[rustfmt::skip]
                let cases: &[(&str, f64)] = &[
                    ("+", (xf() + yf()) as f64),
                    ("-", (xf() - yf()) as f64),
                    ("*", (xf() * yf()) as f64),
                    ("/", (xf() / yf()) as f64),
                    ("^", xf().powf(yf()) as f64),
                    ("atan2", xf().atan2(yf()) as f64),
                    ("min", crate::faq::nan_min_f32(xf(), yf()) as f64),
                    ("max", crate::faq::nan_max_f32(xf(), yf()) as f64),
                    ("==", (xf() == yf()) as i32 as f64),
                    ("!=", (xf() != yf()) as i32 as f64),
                    ("<", (xf() < yf()) as i32 as f64),
                    ("<=", (xf() <= yf()) as i32 as f64),
                    (">", (xf() > yf()) as i32 as f64),
                    (">=", (xf() >= yf()) as i32 as f64),
                    ("and", (xf() != 0.0 && yf() != 0.0) as i32 as f64),
                    ("or", (xf() != 0.0 || yf() != 0.0) as i32 as f64),
                ];
                for &(op, want) in cases {
                    let got = apply_binary(op, x, y);
                    assert!(
                        same_bits(got, want),
                        "apply_binary(\"{op}\", {x:?}, {y:?}) = {got:?}, want f32 {want:?}"
                    );
                    // The hoisted table the taped path resolves
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
            // Each `want` gets its OWN opaque operand. Handed one shared `xf`,
            // LLVM fuses `xf.sin()` and `xf.cos()` into a single `sincosf`
            // (Apple: `__sincosf_stret`), and on a constant operand it folds
            // the call outright — by evaluating in binary64 and rounding.
            // Neither is the lone `cosf` the kernel calls, so wherever the
            // platform `cosf` is not correctly rounded (Apple aarch64:
            // `cosf(1e38)` is one ulp off) the test failed while the kernel
            // was right. glibc's x86-64 `cosf` is correctly rounded, which is
            // why it only ever failed on arm.
            let xf = || black_box(x as f32);
            #[rustfmt::skip]
            let cases: &[(&str, f64)] = &[
                ("exp", xf().exp() as f64),
                ("log", xf().ln() as f64),
                ("log10", xf().log10() as f64),
                ("sqrt", xf().sqrt() as f64),
                ("abs", xf().abs() as f64),
                ("floor", xf().floor() as f64),
                ("ceil", xf().ceil() as f64),
                ("sin", xf().sin() as f64),
                ("cos", xf().cos() as f64),
                ("tan", xf().tan() as f64),
                ("asin", xf().asin() as f64),
                ("acos", xf().acos() as f64),
                ("atan", xf().atan() as f64),
                ("sinh", xf().sinh() as f64),
                ("cosh", xf().cosh() as f64),
                ("tanh", xf().tanh() as f64),
                ("asinh", xf().asinh() as f64),
                ("acosh", xf().acosh() as f64),
                ("atanh", xf().atanh() as f64),
                ("not", (xf() == 0.0) as i32 as f64),
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
                    ("min", crate::faq::nan_min(x, y)), ("max", crate::faq::nan_max(x, y)),
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

    fn const_node(value: serde_json::Value) -> ExpressionNode {
        ExpressionNode {
            op: "const".to_string(),
            value: Some(value.into()),
            ..Default::default()
        }
    }

    /// A `const` literal is not an `Expr::Number`, so it is the one numeric
    /// ingress the literal rule does not reach — and a const ARRAY would then
    /// serve binary64 elements to every gather on it.
    #[test]
    fn const_literals_round_on_materialization() {
        let _g = crate::precision::enter(crate::precision::Precision::Float32);
        match eval_const(&const_node(serde_json::json!(0.1))) {
            Value::Scalar(s) => assert_eq!(s.to_bits(), (0.1_f32 as f64).to_bits()),
            other => panic!("expected a scalar, got {other:?}"),
        }
        // A dense payload, and one held as JSON (mixed spelling).
        for lit in [
            serde_json::json!([0.1, 0.2]),
            serde_json::json!([0.1, 0.2, 3]),
        ] {
            match eval_const(&const_node(lit)) {
                Value::Array(a) => {
                    assert_eq!(a[[0]].to_bits(), (0.1_f32 as f64).to_bits());
                    assert_eq!(a[[1]].to_bits(), (0.2_f32 as f64).to_bits());
                }
                other => panic!("expected an array, got {other:?}"),
            }
        }
    }

    /// A literal's array is materialized once per precision and shared by
    /// every later read, including a read through a clone of the node; the
    /// binary32 reading is a different array from the binary64 one.
    #[test]
    fn const_literal_array_is_materialized_once_per_precision() {
        for lit in [serde_json::json!([0.1, 0.2]), serde_json::json!([0.1, 2])] {
            let node = const_node(lit);
            let clone = node.clone();
            let v = node.value.as_ref().unwrap();
            let first = v.array().expect("array const");
            let again = clone.value.as_ref().unwrap().array().expect("array const");
            assert!(std::sync::Arc::ptr_eq(&first, &again));
            let f32_seen = {
                let _g = crate::precision::enter(crate::precision::Precision::Float32);
                v.array().expect("binary32 array")
            };
            assert_eq!(f32_seen[[0]].to_bits(), (0.1_f32 as f64).to_bits());
            assert_eq!(first[[0]].to_bits(), 0.1_f64.to_bits());
            match eval_const(&node) {
                Value::Array(a) => assert_eq!(*a, *first),
                other => panic!("expected an array, got {other:?}"),
            }
        }
    }

    /// A ragged literal has no array reading: it evaluates to the NaN
    /// sentinel, never a partial array.
    #[test]
    fn const_literal_ragged_is_unevaluable() {
        let node = const_node(serde_json::json!([[1.0, 2.0], [3.0]]));
        assert!(node.value.as_ref().unwrap().array().is_none());
        match eval_const(&node) {
            Value::Scalar(s) => assert!(s.is_nan()),
            other => panic!("expected the NaN sentinel, got {other:?}"),
        }
    }
}

/// Evaluate a strictly-binary op (`atan2`, the comparisons).
///
/// The arity guard is not decoration: `{"op":"atan2","args":[1.0]}` is
/// *schema-valid* (the schema puts no lower bound on `args`), and indexing
/// `args[1]` on it would panic. [`crate::op_registry`] rejects that node at
/// the compile gate, but `eval_expression` is a public entry point that
/// bypasses the gate, so the guard is the backstop that makes a panic
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

/// What one evaluation is told about walking a `faq` cell by cell, and what
/// it reports back ([`EvalCtx::walks`]).
///
/// A strict compiler refuses an evaluation the reference evaluator walks per
/// cell, so the rest of such a walk is work whose only product is a refusal —
/// on a gate-driven join over a million cells, minutes of it. With
/// `stop_at_first` set, the first `faq` that goes per cell evaluates ONE cell,
/// for its diagnostic only (a body no route can evaluate is the document's
/// error, and an out-of-range gather in it must still say so), and stops;
/// every walk after it stops before its first cell. The evaluation's value is
/// then a placeholder, and [`Self::refused`] tells the caller to discard it.
///
/// The stop is taken exactly where a walk is counted, so whether a refusal
/// happens, and its reason, are what a full walk would have given; only the
/// work behind them is gone.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct CellWalks {
    /// Stop every per-cell walk after its first cell.
    stop_at_first: bool,
    /// How many `faq` nodes were evaluated by walking the body once per cell
    /// (or once per contracted term): a prefix scan, the output-tuple loop,
    /// or a rank-0 contraction folded term by term.
    count: u64,
    /// A walk has stopped. Every value computed since is a placeholder.
    stopped: bool,
    /// A document error (a latched out-of-range gather) was already pending
    /// when the walk stopped, so the evaluation fails with it rather than
    /// being refused.
    with_error: bool,
}

impl CellWalks {
    /// Walks that stop after their first cell.
    pub(crate) fn stopping() -> Self {
        CellWalks {
            stop_at_first: true,
            ..CellWalks::default()
        }
    }

    /// Whether any `faq` was walked per cell.
    pub(crate) fn walked(&self) -> bool {
        self.count > 0
    }

    /// Whether a walk stopped, error or not: what was computed is not the
    /// whole answer.
    pub(crate) fn stopped(&self) -> bool {
        self.stopped
    }

    /// Whether a walk stopped with no document error pending, so that what
    /// was computed since — a value, or an error raised by reading a
    /// placeholder — is not the document's, and the evaluation is refused.
    pub(crate) fn refused(&self) -> bool {
        self.stopped && !self.with_error
    }

    fn note_walk(&mut self) {
        self.count = self.count.wrapping_add(1);
    }

    /// Called after a per-cell walk's first cell. Under `stop_at_first` it
    /// records the stop, and whether that cell latched a document error, and
    /// answers `true`: the walk ends here.
    pub(super) fn after_first_cell(&mut self) -> bool {
        if !self.stop_at_first {
            return false;
        }
        if !self.stopped {
            self.stopped = true;
            self.with_error = CONST_OOB.with(|l| l.borrow().is_some());
        }
        true
    }
}

/// What a refusal raised from a walk [`CellWalks`] stopped says after its
/// reason, in the words the Julia binding uses for its own: the cells the walk
/// did not evaluate may still hold a document error (an out-of-range gather at
/// the last cell of a prefix scan), and only the interpreter would find it.
pub(crate) const ONE_CELL_NOTE: &str = "only one cell of it was evaluated before this refusal, \
    so a document error in a cell that was not (an out-of-range gather at the last cell, say) \
    is not reported here; the interpreter evaluates every cell and reports it";

thread_local! {
    /// First `E_TREEWALK_CONSTARRAY_OOB` raised during the current evaluation.
    ///
    /// The tree walk returns a bare [`Value`] with no error channel, so an
    /// out-of-range CONST-ARRAY gather latches its diagnostic here and yields
    /// `NaN`; the public entry points ([`eval_expression_with_extents_and_consts`])
    /// drain the latch and report it. This is the same "fail closed, do not
    /// silently substitute a number" contract the Julia reference gets from
    /// `throw` and Python from raising.
    static CONST_OOB: RefCell<Option<LatchedFault>> = const { RefCell::new(None) };
}

/// The codes of the fail-closed faults the evaluators latch, each the
/// prefix of its message (`"<code>: …"`).
pub(crate) mod fault_code {
    macro_rules! codes {
        ($($name:ident),* $(,)?) => {
            $(pub(crate) const $name: &str = concat!("E_TREEWALK_", stringify!($name));)*
            /// Every code above.
            pub(crate) const ALL: &[&str] = &[$($name),*];
        };
    }
    codes!(
        CONSTARRAY_OOB,
        FILTER_UNALIGNED,
        INDEX_ON_SCALAR,
        NESTED_BOX_MISMATCH,
        RECUR_UNAVAILABLE,
        UNBOUND_NAME,
        UNRESOLVED_ORDER,
    );
    /// The code of a fault whose message leads with none of [`ALL`].
    pub(crate) const UNCODED: &str = "rhs_fault";

    /// The code `message` leads with, for a message latched without one
    /// (the tape latches the texts the evaluator's message builders made).
    pub(crate) fn of(message: &str) -> &'static str {
        ALL.iter()
            .copied()
            .find(|c| {
                message
                    .strip_prefix(c)
                    .is_some_and(|rest| rest.starts_with(':'))
            })
            .unwrap_or(UNCODED)
    }
}

/// A fail-closed fault an evaluation latched: its code
/// ([`fault_code`]) and its message.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Fault {
    pub(crate) code: &'static str,
    pub(crate) message: String,
}

/// The latched fault and, for one the tape latched through
/// [`latch_ordered_fault`], where it sits in its rule's evaluation order.
struct LatchedFault {
    fault: Fault,
    order: Option<(u32, SmallVec<[i64; 12]>)>,
}

/// Take (and clear) the pending fail-closed fault's message, if any.
///
/// Named for the first fault that used this channel
/// (`E_TREEWALK_CONSTARRAY_OOB`); it carries every code in [`fault_code`].
/// All of them are "fail closed, do not silently substitute a number" faults
/// with the same drain sites, so they share one latch.
pub fn take_const_array_oob() -> Option<String> {
    take_fault().map(|f| f.message)
}

/// Take (and clear) the pending fail-closed fault, if any.
pub(crate) fn take_fault() -> Option<Fault> {
    CONST_OOB.with(|c| c.borrow_mut().take().map(|l| l.fault))
}

/// The fault latch of one evaluation: made on entry, it holds whatever the
/// caller had latched and leaves the latch empty for the evaluation;
/// [`Self::take`] and [`Self::finish`] read the evaluation's own fault, and
/// the caller's is put back when the scope ends. An evaluation runs on one
/// thread and starts no other, so nothing it latches is visible outside it,
/// and nothing latched outside it is reported as its own.
pub(crate) struct FaultScope {
    prev: Option<LatchedFault>,
}

impl FaultScope {
    pub(crate) fn enter() -> FaultScope {
        FaultScope {
            prev: CONST_OOB.with(|c| c.borrow_mut().take()),
        }
    }

    /// Take the fault latched so far in this scope, if any, leaving the latch
    /// empty for the rest of it.
    pub(crate) fn take(&self) -> Option<Fault> {
        take_fault()
    }

    /// The fault the evaluation latched, if any; the caller's latch is
    /// restored.
    pub(crate) fn finish(mut self) -> Option<Fault> {
        let prev = self.prev.take();
        CONST_OOB.with(|c| std::mem::replace(&mut *c.borrow_mut(), prev).map(|l| l.fault))
    }
}

impl Drop for FaultScope {
    fn drop(&mut self) {
        let prev = self.prev.take();
        CONST_OOB.with(|c| *c.borrow_mut() = prev);
    }
}

/// Latch the FIRST fail-closed fault of this evaluation, with its code.
pub(crate) fn latch_fault(code: &'static str, message: String) {
    debug_assert!(code == fault_code::UNCODED || message.starts_with(code));
    CONST_OOB.with(|c| {
        let mut slot = c.borrow_mut();
        if slot.is_none() {
            *slot = Some(LatchedFault {
                fault: Fault { code, message },
                order: None,
            });
        }
    });
}

/// Latch the FIRST fail-closed fault of this evaluation, coded by the code
/// its message leads with. The tape's `Instr::Fault` latches through here
/// too, so both evaluators keep the same first-wins record.
pub(crate) fn latch_gather_fault(msg: String) {
    latch_fault(fault_code::of(&msg), msg);
}

/// Latch a fault the tape raises in rule `rule` at `key`, the position the
/// per-cell oracle reaches it in that rule (the tape's `FaultKey`: nested box
/// cells in visiting order, then expression order). The tape evaluates a rule
/// instruction by instruction over whole boxes rather than cell by cell, so
/// two faults of ONE rule can reach the latch in the opposite order to the
/// oracle's: within a rule the smaller key replaces the latched one, which is
/// the fault the oracle latches first. Across rules, and against a fault
/// latched without a position, the first one latched stays.
pub(crate) fn latch_ordered_fault(rule: u32, key: &[i64], msg: impl FnOnce() -> String) {
    CONST_OOB.with(|c| {
        let mut slot = c.borrow_mut();
        let replace = match &*slot {
            None => true,
            Some(LatchedFault {
                order: Some((r, k)),
                ..
            }) => *r == rule && key < &k[..],
            Some(_) => false,
        };
        if replace {
            let message = msg();
            *slot = Some(LatchedFault {
                fault: Fault {
                    code: fault_code::of(&message),
                    message,
                },
                order: Some((rule, key.iter().copied().collect())),
            });
        }
    });
}

/// Latch an unavailable causal self-read (esm-spec §4.3.1.1): the position is
/// outside the recurrence axis, or names a cell the sweep has not published.
fn latch_recur_unavailable(name: &str, raw: &[i64]) {
    latch_fault(
        fault_code::RECUR_UNAVAILABLE,
        recur_unavailable_message(name, raw),
    );
}

/// The text [`latch_recur_unavailable`] latches, shared with the tape's
/// causal self-read (`Instr::ScalarRead`).
pub(crate) fn recur_unavailable_message(name: &str, raw: &[i64]) -> String {
    let at = raw
        .iter()
        .map(|i| i.to_string())
        .collect::<Vec<_>>()
        .join(",");
    format!(
        "E_TREEWALK_RECUR_UNAVAILABLE: causal self-read of '{name}' at cell [{at}] is not \
         available — the position is outside the recurrence axis, or the sweep has not \
         published that cell yet (esm-spec §4.3.1.1; CONFORMANCE_SPEC.md §5.19.4: a causal \
         self-read is fail-closed, never the §5.5.5 zero ghost and never a NaN a `max(x, 0)` \
         could launder). Guard the base case inside the body, e.g. \
         `ifelse(k <= 1, <base>, <recurrence>)`."
    )
}

/// Latch a subscript applied to a value that has NO axes (esm-spec §4.3.4: a
/// scalar declares no index sets).
///
/// `index(x)` with no subscript is the identity and never reaches here; this is
/// `index(x, i, …)` where `x` turned out to be 0-D, so the subscripts name
/// nothing there is to name. It latches a fault rather than returning NaN,
/// because a NaN is laundered by any `max(x, 0)`, `ifelse` or comparison the
/// body goes on to apply — the document would then report a number that was
/// never computed.
fn latch_index_on_scalar(base: &Expr, subscripts: usize) {
    latch_fault(
        fault_code::INDEX_ON_SCALAR,
        index_on_scalar_message(base, subscripts),
    );
}

/// The text [`latch_index_on_scalar`] latches, shared with the tape lowering,
/// which emits it as an `Instr::Fault`.
pub(crate) fn index_on_scalar_message(base: &Expr, subscripts: usize) -> String {
    let what = match base {
        Expr::Variable(name) => format!("'{name}'"),
        Expr::Operator(node) => format!("the `{}` result", node.op),
        Expr::Integer(_) | Expr::Number(_) => "a numeric literal".to_string(),
    };
    format!(
        "E_TREEWALK_INDEX_ON_SCALAR: {what} has no axes, so the {subscripts} subscript(s) \
         applied to it name nothing (esm-spec §4.3.4; CONFORMANCE_SPEC.md §7.1). Fail-closed: \
         never the §5.5.5 zero ghost, which is the boundary convention for a gather that HAS \
         an axis to fall outside of, and never a bare NaN. Read an unshaped quantity by its \
         bare name or as `index(<name>)` with no subscript, or give it a `shape` if it was \
         meant to have axes."
    )
}

/// Latch the FIRST const-array out-of-range diagnostic of this evaluation.
fn latch_const_oob(name: &str, one_based: i64, n: i64, d: usize) {
    latch_fault(
        fault_code::CONSTARRAY_OOB,
        const_oob_message(name, one_based, n, d),
    );
}

/// The text [`latch_const_oob`] latches, shared with the tape lowering.
pub(crate) fn const_oob_message(name: &str, one_based: i64, n: i64, d: usize) -> String {
    format!(
        "E_TREEWALK_CONSTARRAY_OOB: const array '{name}' index {one_based} out of range \
         1..{n} in dim {d} (CONFORMANCE_SPEC.md §5.5.5: the zero-ghost convention is \
         never applied to a const-array gather; declare a per-dimension boundary policy \
         to resolve it as `periodic` or `clamp`)"
    )
}

/// The 0-based position the §5.5.5 periodic fold `mod1(one_based, n)` reads
/// along an axis of extent `n >= 1`: `(one_based − 1) mod n`, exact for every
/// `i64` (a saturated `i64::MIN` subscript must not overflow the `− 1`).
#[inline]
pub(crate) fn periodic_offset(one_based: i64, n: i64) -> usize {
    (i128::from(one_based) - 1).rem_euclid(i128::from(n)) as usize
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
                            resolved = periodic_offset(one_based, dim_size) as i64 + 1;
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
        // A zero-ghost index left out of range may be a saturated `i64::MIN`.
        indices.push(resolved.saturating_sub(1).max(0) as usize);
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
    // geometry table — `index(poly, a)` yields the `a`-th `[verts, coord]`
    // ring. A full index
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
    // A base that is a parameter of the call in progress is the reference's
    // binding, read in the caller's frame: the subscripts are evaluated here,
    // then the gather runs there on their values, as the expansion gathers
    // the binding at them.
    if let Some((base, up)) = ctx.through_params(&node.args[0]) {
        let (raw, _) = eval_index_args(&node.args[1..], ctx);
        let mut args = Vec::with_capacity(node.args.len());
        args.push(base);
        args.extend(raw.iter().map(|&i| Expr::Integer(i)));
        let gather = ExpressionNode {
            op: "index".to_string(),
            args,
            ..Default::default()
        };
        return ctx.up_frames(up, |ctx| eval_index(&gather, ctx));
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
    // the one element straight out of the payload's materialized array: the
    // generic path below copies the whole table into a `Value` for every
    // single cell, which on a transcribed lookup table (an RRTM
    // k-distribution band is ~14k numbers, gathered once per level per g-point)
    // is the dominant cost of the whole right-hand side. The provenance
    // (`INLINE_CONST_NAME`), the out-of-range policy and `index_into` itself are
    // the ones the generic path would have used, so the result is bit-identical.
    //
    // Evaluating the subscripts after the literal rather than before is likewise
    // unobservable: a `const` node reads nothing and latches nothing.
    if let Expr::Operator(lit) = &node.args[0]
        && lit.op == "const"
        && let Some(arr) = lit.value.as_ref().and_then(crate::ConstValue::array)
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
/// number yields a [`Value::Scalar`]; a rectangular numeric array yields a
/// row-major [`Value::Array`]. A missing, ragged, or non-numeric literal is
/// unevaluable (NaN sentinel), matching the evaluator's convention for
/// malformed nodes.
///
/// A literal rounds to the working precision on ingress (esm-spec §11.3.1),
/// once: the scalar here, the array when the payload materializes it
/// ([`crate::ConstValue`]).
pub(super) fn eval_const(node: &ExpressionNode) -> Value {
    let Some(v) = node.value.as_ref() else {
        return Value::Scalar(f64::NAN);
    };
    if let Some(a) = v.array() {
        return Value::Array(Box::new((*a).clone()));
    }
    let scalar = v.as_f64().map(|x| crate::precision::active().round(x));
    Value::Scalar(scalar.unwrap_or(f64::NAN))
}

/// Evaluate a standalone expression against a set of named array inputs, reusing
/// the array evaluator — in particular the M1 `faq` machinery in
/// [`eval_faq`]: supply the arrays the expression reads in `inputs`, with
/// every aggregate range already resolved to a concrete interval, and the body
/// is reduced exactly as any other `faq`.
///
/// Returns [`Value::Scalar`] for a scalar FAQ output (`output_idx: []`),
/// [`Value::Array`] otherwise.
///
/// # Errors
///
/// This is the crate's one UNGATED evaluation entry point — it takes a raw
/// [`Expr`] that never passed through `from_model`'s compile-time gate — so it
/// applies [`check_evaluable_all`] itself. An operator the interpreter cannot
/// evaluate (a typo, an unlowered spatial `D`, or an `ic`/`enum` that an earlier
/// pipeline stage should have eliminated) is reported here rather
/// than silently evaluating to `NaN`.
pub fn eval_expression(
    expr: &Expr,
    inputs: &HashMap<String, ArrayD<f64>>,
    params: &[f64],
    param_names: &[String],
    t: f64,
) -> Result<Value, CompileError> {
    let inputs: ArrMap = inputs.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    StandaloneScope {
        inputs: &inputs,
        params,
        param_names,
        t,
        derived_extents: crate::faq::empty_derived_extents(),
        const_arrays: ConstArrayScope::empty(),
        ops: Instances::empty(),
    }
    .eval_fast(expr)
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
/// Pass an empty map (or call [`eval_expression`]) when nothing ranges over a
/// derived set: a derived range with no extent is refused.
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
    let inputs: ArrMap = inputs.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    StandaloneScope {
        inputs: &inputs,
        params,
        param_names,
        t,
        derived_extents,
        const_arrays: ConstArrayScope::empty(),
        ops: Instances::empty(),
    }
    .eval_fast(expr)
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
    // hundreds-of-MB SR slabs once per observed dominated the whole build.
    let inputs: ArrMap = inputs.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    StandaloneScope {
        inputs: &inputs,
        params,
        param_names,
        t,
        derived_extents,
        const_arrays,
        ops: Instances::empty(),
    }
    .eval_fast(expr)
}

/// A state-free build-time expression (a field `ic`'s right-hand side, a
/// definition of its scope, an initialization equation) evaluated by the
/// route `mode` names, over the build-time ARRAY scope `scope` bound by name
/// (where state arrays would bind) and the parameters `params` (name →
/// value). Ranges are resolved against `index_sets` first. `name` is the
/// variable the expression defines, if any.
///
/// The independent variable is `params["t"]` where the scope binds it — the
/// start of the run for an `ic` right-hand side (esm-spec §11.4.2) — and `0`
/// otherwise.
pub(crate) fn eval_buildtime_field_routed(
    name: Option<&str>,
    expr: &Expr,
    index_sets: &HashMap<String, crate::types::IndexSet>,
    params: &HashMap<String, f64>,
    scope: &HashMap<String, ArrayD<f64>>,
    mode: BuildEval,
    ops: &Instances,
) -> Result<Routed, CompileError> {
    let mut resolved = expr.clone();
    crate::faq::resolve_expr_ranges(&mut resolved, index_sets)?;
    let param_names: Vec<String> = params.keys().cloned().collect();
    let param_vec: Vec<f64> = param_names.iter().map(|n| params[n]).collect();
    let t = params.get("t").copied().unwrap_or(0.0);
    let inputs: ArrMap = scope.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    StandaloneScope {
        inputs: &inputs,
        params: &param_vec,
        param_names: &param_names,
        t,
        derived_extents: crate::faq::empty_derived_extents(),
        const_arrays: ConstArrayScope::empty(),
        ops,
    }
    .eval_routed(name.unwrap_or(STANDALONE_EXPRESSION), &resolved, None, mode)
}

/// The scope a standalone expression is evaluated in, outside any compiled
/// model: named input arrays (borrowed, never copied), positional parameters,
/// the time, the build-time value-invention extents and the const-array
/// registry. With no model behind it, it vouches for no declared name (see
/// [`EvalCtx::declared`]) and carries no loader forcing.
#[derive(Clone, Copy)]
pub(crate) struct StandaloneScope<'a> {
    pub(crate) inputs: &'a ArrMap,
    pub(crate) params: &'a [f64],
    pub(crate) param_names: &'a [String],
    pub(crate) t: f64,
    pub(crate) derived_extents: &'a HashMap<String, i64>,
    pub(crate) const_arrays: &'a ConstArrayScope,
    /// The operator instances a reference in the expression names.
    pub(crate) ops: &'a Instances,
}

impl StandaloneScope<'_> {
    /// Run `f` with an evaluation environment over this scope.
    fn with_env<R>(&self, f: impl FnOnce(&EvalEnv) -> R) -> R {
        let empty: ArrMap = ArrMap::default();
        let forcing: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
        f(&EvalEnv {
            state_arrays: &empty,
            params: self.params,
            param_names: self.param_names,
            t: self.t,
            derived_extents: self.derived_extents,
            forcing: &forcing,
            const_arrays: self.const_arrays,
            declared: empty_declared_names(),
            ops: self.ops,
        })
    }

    /// Evaluate `expr` (ranges already resolved) in this scope, reporting a
    /// fault the evaluation latched as the error; its per-cell walks are told
    /// and reported through `walks`.
    pub(crate) fn eval_walking(
        &self,
        expr: &Expr,
        walks: &mut CellWalks,
    ) -> Result<Value, CompileError> {
        check_evaluable_all([expr], self.ops)?;
        // A derived range over an unsized producer is refused rather than
        // contracted as empty.
        if let Some(from_faq) =
            super::compile::first_unmaterialized_derived_range(expr, self.derived_extents)
        {
            return Err(super::compile::unmaterialized_derived_error(
                &from_faq,
                &HashMap::new(),
                None,
            ));
        }
        self.with_env(|env| {
            let mut ctx = env.ctx(self.inputs);
            ctx.walks = *walks;
            let faults = FaultScope::enter();
            let v = eval(expr, &mut ctx);
            *walks = ctx.walks;
            match faults.finish() {
                Some(fault) => Err(CompileError::InterpreterBuildError {
                    details: fault.message,
                }),
                None => Ok(v),
            }
        })
    }

    /// Evaluate `expr` (ranges resolved) over whole arrays where it can be:
    /// [`Self::eval_routed`]'s non-strict [`BuildEval::Fast`] route, for an
    /// expression that defines no variable.
    pub(crate) fn eval_fast(&self, expr: &Expr) -> Result<Value, CompileError> {
        self.eval_routed(
            STANDALONE_EXPRESSION,
            expr,
            None,
            BuildEval::Fast { strict: false },
        )
        .map(Routed::into_value)
    }

    /// Evaluate the build-time value `name := expr` (ranges resolved) by the
    /// route `mode` names, and say which evaluator served it.
    ///
    /// Under [`BuildEval::Fast`] the reference evaluator is tried first with
    /// its walks stopping at their first cell ([`CellWalks::stopping`]): what it evaluates over whole arrays, with
    /// no `faq` walked cell by cell, is its value. Once a walk would go cell
    /// by cell the whole expression is lowered on a standalone tape instead
    /// ([`eval_observed_taped`]), from the same inputs. A tape decline is a
    /// refusal when `strict`, and otherwise the reference evaluator's full
    /// per-cell walk. [`BuildEval::PerCell`] is the reference evaluator alone.
    pub(crate) fn eval_routed(
        &self,
        name: &str,
        expr: &Expr,
        fill_shape: Option<&[usize]>,
        mode: BuildEval,
    ) -> Result<Routed, CompileError> {
        let walked = |scope: &Self| {
            let mut walks = CellWalks::default();
            let v = scope.eval_walking(expr, &mut walks)?;
            let route = if walks.walked() {
                BuildRoute::PerCell
            } else {
                BuildRoute::Whole
            };
            Ok(Routed::Value(v, route))
        };
        let BuildEval::Fast { strict } = mode else {
            return walked(self);
        };
        let mut walks = CellWalks::stopping();
        let v = self.eval_walking(expr, &mut walks);
        let stopped = walks.stopped();
        if !walks.refused() {
            // A stopped walk here latched a document error in its first
            // cell, which `v` reports.
            return v.map(|v| {
                let route = if stopped {
                    BuildRoute::PerCell
                } else {
                    BuildRoute::Whole
                };
                Routed::Value(v, route)
            });
        }
        use super::tape::StandaloneError;
        match eval_observed_taped(name, expr, self, fill_shape, false)
            .expect("a non-recurrence always reaches the tape")
        {
            Ok(a) => Ok(Routed::Value(value_of_taped(a), BuildRoute::Tape)),
            Err(StandaloneError::Fault(details)) => {
                Err(CompileError::InterpreterBuildError { details })
            }
            Err(StandaloneError::Declined(why)) if strict => Ok(Routed::Refused(why)),
            Err(StandaloneError::Declined(_)) => walked(self),
        }
    }

    /// Evaluate the observed `name := expr` in this scope if it is a CAUSAL
    /// SELF-REFERENCE (esm-spec §4.3.1.1).
    ///
    /// `None` — `expr` contains no `index(name, …)` self-read, so the caller
    /// evaluates it as any other expression. `Some(Ok(_))` — the sequential
    /// sweep ran and this is the finished array. `Some(Err(_))` — the
    /// self-read is there but is not a well-founded causal read, or a read
    /// reached a cell the sweep had not published.
    ///
    /// The build pipeline materializes a document's observed graph through
    /// this scope, so a recurrence needs this path as well as the per-step
    /// one. It resolves the frame with the same [`lower_recurrence`] the
    /// compiled path uses and runs the same [`sweep_recurrence`]; only the
    /// surrounding environment differs. The sweep's cells are told and
    /// reported through `walks`.
    pub(crate) fn eval_recurrence(
        &self,
        name: &str,
        expr: &Expr,
        walks: &mut CellWalks,
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
                return Some(Err(CompileError::coded_build_err(
                    crate::diagnostic::codes::RECURRENCE_UNSUPPORTED_FORM,
                    format!(
                        "recurrence_unsupported_form: '{name}' reads itself through `index` in its \
                     own definition, but the build pipeline could not resolve a cell frame to \
                     sweep. Evaluating it wholesale would resolve the self-read to an unbound \
                     name, and a body containing `max(x, 0)` would turn the resulting NaN into \
                     a plausible zero (esm-spec §4.3.1.1; CONFORMANCE_SPEC §5.19.4)."
                    ),
                )));
            }
            Err(e) => return Some(Err(e)),
        };
        let (shape, origin) = super::rhs::recur_frame(&lowered.ranges);
        let scope = RecurScope::new(name, shape, origin);
        let faults = FaultScope::enter();
        let arr = self.with_env(|env| {
            let mut ctx = env.ctx(self.inputs);
            ctx.walks = *walks;
            let arr = super::rhs::sweep_recurrence(
                &scope,
                &lowered.idx_names,
                &lowered.ranges,
                &lowered.body,
                lowered.axis,
                &mut ctx,
            );
            *walks = ctx.walks;
            arr
        });
        // §5.19.4: an unavailable self-read is a FAULT, not a value. The latch is
        // the channel the tree walk has for one, and draining it here is what makes
        // this path fail closed rather than hand back an array built on a sentinel.
        match faults.finish() {
            Some(fault) => Some(Err(CompileError::InterpreterBuildError {
                details: fault.message,
            })),
            None => Some(Ok(arr)),
        }
    }
}

/// The name a standalone expression is lowered under on the tape: no
/// document variable can spell it, so no input is mistaken for a self-read.
const STANDALONE_EXPRESSION: &str = "\u{0}expression";

/// How [`StandaloneScope::eval_routed`] evaluates a build-time value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BuildEval {
    /// The reference evaluator, walking every `faq` cell by cell: what the
    /// `interpreter` does, and an inline test's reference.
    PerCell,
    /// Whole arrays: the reference evaluator where it walks no cell, the tape
    /// where it would. `strict` refuses what the tape declines rather than
    /// walking it per cell.
    Fast { strict: bool },
}

impl BuildEval {
    /// The route a compiler takes: per cell under the `interpreter`, and
    /// strict everywhere else.
    pub(crate) fn of_compiler(interpreter: bool) -> BuildEval {
        if interpreter {
            BuildEval::PerCell
        } else {
            BuildEval::Fast { strict: true }
        }
    }
}

/// Which evaluator served a build-time value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BuildRoute {
    /// The reference evaluator over whole arrays, no `faq` walked per cell.
    Whole,
    /// A standalone tape program.
    Tape,
    /// The reference evaluator, with a `faq` walked cell by cell.
    PerCell,
}

/// What [`StandaloneScope::eval_routed`] produced.
#[derive(Debug)]
pub(crate) enum Routed {
    /// The value, and the evaluator that served it.
    Value(Value, BuildRoute),
    /// Strict, and the tape declined what would have been walked per cell:
    /// the tape's reason.
    Refused(String),
}

impl Routed {
    /// The value of a non-strict route, which refuses nothing.
    pub(crate) fn into_value(self) -> Value {
        match self {
            Routed::Value(v, _) => v,
            Routed::Refused(_) => unreachable!("a non-strict route refuses nothing"),
        }
    }
}

/// A standalone tape's value as the reference evaluator gives it: a 0-d array
/// is a scalar.
fn value_of_taped(a: ArrayD<f64>) -> Value {
    if a.ndim() == 0 {
        Value::Scalar(a[IxDyn(&[])])
    } else {
        Value::Array(Box::new(a))
    }
}

/// Evaluate the build-time observed `name := expr` on a standalone tape
/// (`tape::eval_standalone_rule`) rather than through the reference
/// evaluator: what [`StandaloneScope::eval_routed`] does with a value the
/// reference evaluator would walk per cell.
///
/// `expr` has its ranges resolved, as for
/// [`StandaloneScope::eval_walking`]. Every name in `scope.inputs`
/// that `expr` mentions is seeded as a known value, and `params` bind
/// `param_names`. A causal self-reference (esm-spec §4.3.1.1) lowers as the
/// model's own recurrence rule does, to one ordered sweep; one the lowering
/// does not recognize is left to the caller's own diagnostic. `None` when
/// `recurrence_only` and the observed is not such a recurrence. `fill_shape`
/// is the shape the build decided the variable has (its declared one, or
/// esm-spec §4.3.4's for an unshaped mixed-rank `ifelse`): a scalar value
/// fills it, as the reference evaluator's does. With none, a scalar value
/// comes back as a 0-d array.
pub(crate) fn eval_observed_taped(
    name: &str,
    expr: &Expr,
    scope: &StandaloneScope,
    fill_shape: Option<&[usize]>,
    recurrence_only: bool,
) -> Option<Result<ArrayD<f64>, super::tape::StandaloneError>> {
    use super::tape::StandaloneError;
    let recurrence = expr_reads_self(expr, name);
    if recurrence_only && !recurrence {
        return None;
    }
    let rule = if recurrence {
        let lhs = Expr::Variable(name.to_string());
        match super::compile::lower_recurrence(name, &lhs, expr) {
            Ok(Some(r)) => AlgebraicRule::Recurrence {
                var: name.to_string(),
                output_idx_names: r.idx_names,
                output_ranges: r.ranges,
                body: std::sync::Arc::new(r.body),
                axis: r.axis,
                max_lag: r.max_lag,
                lag_proven: r.lag_proven,
            },
            // Not a recurrence the lowering recognizes: the caller's own path
            // reports it ([`StandaloneScope::eval_recurrence`]'s diagnostics).
            Ok(None) | Err(_) if recurrence_only => return None,
            Ok(None) | Err(_) => {
                return Some(Err(StandaloneError::Declined(
                    "recurrence: a self-read the recurrence lowering does not recognize".into(),
                )));
            }
        }
    } else {
        AlgebraicRule::Scalar {
            var: name.to_string(),
            body: std::sync::Arc::new(expr.clone()),
            declared_shape: fill_shape.map(<[usize]>::to_vec),
            data_shaped: None,
        }
    };
    let mut mentioned = HashSet::new();
    super::tape::collect_variable_names(expr, &mut mentioned);
    let mut seeded: Vec<(&str, &ArrayD<f64>)> = scope
        .inputs
        .iter()
        .filter(|(k, _)| k.as_str() != name && mentioned.contains(k.as_str()))
        .map(|(k, a)| (k.as_str(), a))
        .collect();
    seeded.sort_by(|a, b| a.0.cmp(b.0));
    Some(super::tape::eval_standalone_rule(
        &rule,
        &seeded,
        scope.param_names,
        scope.params,
        scope.t,
        scope.const_arrays,
        true,
    ))
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

/// The output-index box of the aggregate currently being evaluated: the index
/// symbol names, and the origin (lower bound) of each output axis.
///
/// This is what lets an ARRAY-valued `filter` be resolved to *this* cell's
/// element by positional alignment (`element = array[idx - lo]`), the same
/// alignment the axis analyses' `VecBox` describes.
pub(super) struct CellBox<'a> {
    /// The output index symbol names, in axis order.
    pub names: &'a [String],
    /// The lower bound of each output axis, in the same order.
    pub origin: &'a [i64],
    /// The `(lo, hi)` range of each output axis, in the same order.
    pub ranges: &'a [(i64, i64)],
    /// The variable the rule being evaluated defines, when there is one, for
    /// a diagnostic to name.
    pub rule: Option<&'a str>,
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
/// # An array filter is a per-cell MASK
///
/// A filter that evaluates to an ARRAY — a regrid `overlap > 0` sparsity gate
/// or a fuel gate `code >= 1` that names a whole field rather than an indexed
/// element — is indexed at the current output cell, aligned to the output box
/// exactly as `VecBox` aligns it, so this oracle and the tape (which applies
/// the array as an elementwise mask) give one answer.
///
/// An array that cannot be aligned — its rank is not the output box's, or the
/// cell lies outside it — is a FAULT, not a verdict: including the cell would
/// silently ignore the filter, so a filter `a_val > 1.5` over a node with two
/// output indices (`a_val` rank 1) would sum rows it excludes. A shaped
/// variable read by bare name in a filter is refused at build
/// (`faq_bare_array_operand`, esm-spec §4.3.1); this fault is what is left for
/// an array whose shape the build cannot name.
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
            let unaligned = |why: String| {
                latch_fault(
                    fault_code::FILTER_UNALIGNED,
                    format!(
                        "E_TREEWALK_FILTER_UNALIGNED: a `faq` filter evaluated to an array of shape \
                     {:?}, {why}, so it does not say which index tuple each element gates. \
                     Read the filter's operands through `index` at the node's symbols \
                     (esm-spec §4.3.1).",
                        a.shape()
                    ),
                );
                true
            };
            let Some(cell) = cell else {
                return unaligned("and the node has no output box to align it to".to_string());
            };
            if a.ndim() != cell.names.len() || cell.origin.len() != cell.names.len() {
                return unaligned(format!(
                    "while the node has {} output indices ({})",
                    cell.names.len(),
                    cell.names.join(", ")
                ));
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
                None => unaligned(format!("and the output cell {ix:?} lies outside it")),
            }
        }
    }
}

/// The element of an output-box-shaped `a` at the current output cell, aligned
/// as `VecBox` aligns an array operand to its box
/// (`element = a[idx - lo]` per output axis). `None` when the rank differs from
/// the box's or the cell lies outside `a`.
fn cell_element(a: &ArrayD<f64>, cell: &CellBox, ctx: &EvalCtx) -> Option<f64> {
    if a.ndim() != cell.names.len() || cell.origin.len() != cell.names.len() {
        return None;
    }
    let ix: DimU = cell
        .names
        .iter()
        .zip(cell.origin.iter())
        .map(|(n, &lo)| {
            let bound = ctx.loop_binds.get(n).copied().unwrap_or(lo);
            (bound - lo).max(0) as usize
        })
        .collect();
    a.get(IxDyn(&ix)).copied()
}

/// What the array-producing nested `faq`s a cell body combines elementwise
/// say about the box its array value is over.
enum NestedBox {
    /// The body reaches no array-producing nested `faq` through elementwise
    /// operators.
    None,
    /// Every one it reaches is over the output box: the same output index
    /// symbols, in order, over the same ranges.
    Same,
    /// One it reaches is over another box (described).
    Other(String),
}

/// [`NestedBox`] of `e`, walking only the elementwise operators, which
/// combine their operands position by position.
fn nested_faq_box(e: &Expr, cell: &CellBox) -> NestedBox {
    let Expr::Operator(node) = e else {
        return NestedBox::None;
    };
    match vec_op_code(&node.op) {
        VecOp::Arith(_)
        | VecOp::Cmp(_)
        | VecOp::Unary(_)
        | VecOp::Neg
        | VecOp::Ifelse
        | VecOp::Precision => {
            let mut verdict = NestedBox::None;
            for a in &node.args {
                match nested_faq_box(a, cell) {
                    other @ NestedBox::Other(_) => return other,
                    NestedBox::Same => verdict = NestedBox::Same,
                    NestedBox::None => {}
                }
            }
            verdict
        }
        VecOp::Aggregate => match faq_spec(node) {
            Some(spec) if !spec.ranges.is_empty() => {
                if spec.idx_names == cell.names && spec.ranges[..] == cell.ranges[..] {
                    NestedBox::Same
                } else {
                    NestedBox::Other(format!(
                        "a nested `faq` over {:?} with ranges {:?}",
                        spec.idx_names,
                        &spec.ranges[..]
                    ))
                }
            }
            _ => NestedBox::None,
        },
        _ => NestedBox::None,
    }
}

/// The fault a cell body latches when it combines an array-producing nested
/// `faq` over a box other than its own output box.
fn nested_box_message(cell: &CellBox, what: &str) -> String {
    let rule = cell
        .rule
        .map(|r| format!("the equation for '{r}'"))
        .unwrap_or_else(|| "a `faq`".to_string());
    format!(
        "E_TREEWALK_NESTED_BOX_MISMATCH: {rule} over {:?} with ranges {:?} combines {what} \
         elementwise, and an array is read at a cell only over the box the cell belongs to. \
         Index the nested `faq` explicitly (`index(faq, ...)`) to say which element each \
         cell reads.",
        cell.names, cell.ranges
    )
}

/// One cell's term: the body's value at the current output cell.
///
/// A body that is array-valued over the output box — an array-producing
/// nested `faq` under an elementwise operator, `faq_f(Σ_k w[e(f, k)]) - q[f]`
/// inside the node over `f` — denotes, per cell, its element at that cell: the
/// nested node rebinds `f` and so is a whole array (esm-spec §4.3.1 shadowing),
/// and a whole-array evaluation (the tape) combines it with the box's other
/// operands position by position. This reads the same element
/// ([`cell_element`]), so the oracle and the tape agree. The read is taken
/// only when the body's nested `faq`s are provably over the output box
/// ([`nested_faq_box`]); one over any other box latches a fault rather than
/// reading an element of a different cell. Anything else that is not a
/// scalar is NaN.
pub(super) fn cell_term(v: Value, body: &Expr, cell: Option<&CellBox>, ctx: &EvalCtx) -> f64 {
    match v {
        Value::Scalar(s) => s,
        Value::Array(a) if a.ndim() == 0 => a[IxDyn(&[])],
        Value::Array(a) => {
            let Some(cell) = cell else {
                return f64::NAN;
            };
            match nested_faq_box(body, cell) {
                NestedBox::Same => cell_element(&a, cell, ctx).unwrap_or(f64::NAN),
                NestedBox::Other(what) => {
                    latch_fault(
                        fault_code::NESTED_BOX_MISMATCH,
                        nested_box_message(cell, &what),
                    );
                    f64::NAN
                }
                NestedBox::None => f64::NAN,
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
            let v = eval(body, ctx);
            cell_term(v, body, cell, ctx)
        };
    }
    // A ragged dim whose parent is itself CONTRACTED (esm-spec §4.3.1 "Ragged
    // ranges"): its bound is not known until the parent is bound, so the box is
    // not a Cartesian product. Walk it as a nest, parent outer to child.
    if static_ranges.is_none() && has_contracted_ragged_parent(contract_names, contract_dims) {
        let order = parent_first_order(contract_names, contract_dims);
        let mut acc = reduce.identity();
        fold_dependent_nest(spec, contract_dims, &order, 0, &mut acc, ctx);
        return acc;
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
    // A reverse window folds its suffix from the high end (esm-spec §4.3.1);
    // a scan that `detect_prefix_scan` did not claim (its body reads the
    // output index, or its range differs from the output axis) lands here.
    if let (Some(cell), [j_name], [(lo, hi)]) = (cell, contract_names, ranges)
        && folds_from_the_top(cell.names, contract_names, filter)
    {
        for j in (*lo..=*hi).rev() {
            set_bind(&mut ctx.loop_binds, j_name, j);
            if filter_excludes(filter, Some(cell), ctx) {
                continue;
            }
            let v = eval(body, ctx);
            let term = cell_term(v, body, Some(cell), ctx);
            acc = reduce.combine(acc, term);
        }
        return acc;
    }
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
        let v = eval(body, ctx);
        let term = cell_term(v, body, cell, ctx);
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
// path that never consults a gate at all (the tape).
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
pub(super) enum GateAxis {
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

pub(super) fn gate_axis(sym: &str, idx_names: &[String], contract_names: &[String]) -> GateAxis {
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
/// [`gate_cache_pair_budget`](crate::broad_phase::gate_cache_pair_budget) is
/// the escape hatch if a document finds a shape that does.
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

/// The cache key of a resolved overlap gate: the envelope factor NAMES, the
/// `eps`, the two envelope side lengths, and a content fingerprint of every
/// factor.
///
/// §5.5.6 requires a gate's `src_env` / `tgt_env` factors to be build-time
/// const-array data, so within one build the candidate set never changes —
/// but a gate is resolved once per node and consulted once per RHS
/// evaluation, and rebuilding the R*-tree each time would cost more than the
/// enumeration it saves. The cache is per THREAD, though, not per build: two
/// builds on one thread can name the same factors with the same sizes and
/// different geometry (a second document using the same regrid template, or a
/// rebuild with a different grid origin). The names alone would then serve
/// the first build's candidate pairs to the second, so the key carries the
/// factors' contents too. The fingerprint is the equality gate's
/// ([`EqGateKey`]): one linear fold over the factors' `f64` bits, against a
/// broad phase that is `O(n log n)` in the same data and a narrow phase over
/// every candidate pair it admits.
type GateKey = (Vec<String>, Vec<String>, u64, usize, usize, u64);

thread_local! {
    /// The spatial-overlap gate cache, bounded by [`gate_cache_pair_budget`].
    static GATE_CACHE: RefCell<GateCache<GateKey, Option<Rc<crate::broad_phase::OverlapIndex>>>> =
        RefCell::new(GateCache::new());
}

/// The cache key of one overlap clause in this context, WITHOUT cloning a
/// factor (the clone happens only on a miss): its names and `eps`, each
/// side's POSITION count — the first factor's first axis, which is the
/// envelope count for a 1-D column and for a `[pos, verts, coord]` ring stack
/// alike, and is what the selectivity estimate divides by — and a fingerprint
/// of every factor's shape and values. `None` when a factor is not array data
/// here, which declines the gate.
fn overlap_cache_key(ov: &crate::types::OverlapClause, eps: f64, ctx: &EvalCtx) -> Option<GateKey> {
    let mut fp: u64 = 0xcbf2_9ce4_8422_2325;
    let mut positions = |names: &[String]| -> Option<usize> {
        let mut n = None;
        for name in names {
            let len = with_named_array(name, ctx, |a| {
                for &d in a.shape() {
                    fp ^= d as u64;
                    fp = fp.wrapping_mul(0x0000_0100_0000_01B3);
                }
                column_fingerprint(a, &mut fp);
                a.shape().first().copied().unwrap_or(1)
            })?;
            n.get_or_insert(len);
        }
        n
    };
    let nsrc = positions(&ov.src_env)?;
    let ntgt = positions(&ov.tgt_env)?;
    Some((
        ov.src_env.clone(),
        ov.tgt_env.clone(),
        eps.to_bits(),
        nsrc,
        ntgt,
        fp,
    ))
}

/// Resolve EVERY drivable clause of `join` into a gate, building (or reusing)
/// each candidate pair index — a broad-phase envelope set for an `overlap`
/// clause (§5.5.6), an [`crate::relational::equijoin`] match set for a resolved
/// `on` clause (§5.5.8) — and return them ordered MOST SELECTIVE FIRST
/// (§5.24).
///
/// Resolving every clause, rather than stopping at the first resolvable one,
/// keeps the node's cost independent of the order the author typed the
/// clauses in. Resolving them all costs one equijoin per clause — each `O(|L|+|R|+|matches|)`, memoised across
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
        let Some(key) = overlap_cache_key(ov, eps, ctx) else {
            continue;
        };
        let (nsrc, ntgt) = (key.3, key.4);
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
    // peak the SUM of its clauses' key columns rather than the largest single
    // one, and a `Key` is 32 B per row before a composite adds a `Vec`
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
pub(super) type EqSides = (
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
pub(super) fn reach_of(reach: &HashMap<String, usize>, sym: &str, full: usize) -> usize {
    reach.get(sym).map_or(full, |r| (*r).min(full))
}

/// Record that a gate with `pairs` pairs leaves at most that many positions
/// alive on `sym`.
pub(super) fn narrow_reach(reach: &mut HashMap<String, usize>, sym: &str, pairs: usize) {
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
    use crate::join::KeyColumn;
    match col {
        KeyColumn::Const { positions, values } => Some(const_key_column(positions, values)),
        KeyColumn::Column(name) => with_named_array(name, ctx, data_key_column)?,
    }
}

/// The `(positions, keys)` of a build-time constant key column.
pub(super) fn const_key_column(
    positions: &[i64],
    values: &[crate::join::JoinKey],
) -> (Vec<i64>, Vec<crate::relational::Key>) {
    use crate::join::JoinKey;
    let keys = values
        .iter()
        .map(|v| match v {
            JoinKey::Int(i) => crate::relational::Key::Int(*i),
            JoinKey::Cat(c) => crate::relational::Key::Str(c.clone()),
        })
        .collect();
    (positions.to_vec(), keys)
}

/// The `(positions, keys)` of a 1-D data column, or `None` when it is not one
/// or holds a value that is not EXACTLY integral (see [`key_column_values`]).
pub(super) fn data_key_column(a: &ArrayD<f64>) -> Option<(Vec<i64>, Vec<crate::relational::Key>)> {
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
}

/// One side's per-position key: the single column's key for a simple `on`, or
/// the tuple ([`crate::relational::Key::Tuple`]) of every listed pair's column
/// value, in pair order, for a multi-pair (COMPOSITE-KEY) clause. A composite
/// key matches iff EVERY pair agrees, which is exactly tuple equality; the
/// left and right sides build comparable keys as long as the pairs are listed
/// in one order —
/// which the build-time grouping guarantees by construction.
fn side_key_parts(cols: &[crate::join::KeyColumn], ctx: &EvalCtx) -> Option<Vec<KeyPart>> {
    cols.iter()
        .map(|c| key_column_values(c, ctx))
        .collect::<Option<Vec<_>>>()
}

/// One key column of one side: the positions it is defined at, and its key
/// at each.
pub(super) type KeyPart = (Vec<i64>, Vec<crate::relational::Key>);

/// Both sides' per-position keys for one `on` clause (see [`side_key_parts`]).
///
/// A composite clause whose every column holds integers is PACKED: each row's
/// tuple becomes one [`crate::relational::Key::Int`] in a mixed radix whose
/// digit ranges are the two sides' JOINT per-column ranges, first column most
/// significant. The packing is a bijection on the values present, so equality
/// is exactly tuple equality, and it is monotone in the lexicographic tuple
/// order, so [`crate::relational::equijoin`]'s canonical key order is the order
/// the tuples would have had. What it removes is a heap-allocated
/// [`crate::relational::Key::Tuple`] per row and its hashing, O(rows x columns)
/// allocations on each side. A clause whose ranges do not fit in an `i64`, or
/// that holds any non-integer key, keeps the tuples.
pub(super) fn composite_pair_keys(
    parts_l: Vec<KeyPart>,
    parts_r: Vec<KeyPart>,
) -> Option<(KeyPart, KeyPart)> {
    if parts_l.len() > 1 && parts_l.len() == parts_r.len() {
        if let Some(packed) = pack_int_pair(&parts_l, &parts_r) {
            return Some(packed);
        }
    }
    Some((composite_side_keys(parts_l)?, composite_side_keys(parts_r)?))
}

fn pack_int_pair(parts_l: &[KeyPart], parts_r: &[KeyPart]) -> Option<(KeyPart, KeyPart)> {
    use crate::relational::Key;
    let k = parts_l.len();
    // The same agreement `composite_side_keys` checks: every column of one
    // side runs over the same positions. A disagreement is left to it.
    let pos_l = &parts_l.first()?.0;
    let pos_r = &parts_r.first()?.0;
    if parts_l.iter().any(|(p, _)| p != pos_l) || parts_r.iter().any(|(p, _)| p != pos_r) {
        return None;
    }
    let mut lo = vec![i64::MAX; k];
    let mut hi = vec![i64::MIN; k];
    for c in 0..k {
        for key in parts_l[c].1.iter().chain(parts_r[c].1.iter()) {
            let Key::Int(v) = key else { return None };
            lo[c] = lo[c].min(*v);
            hi[c] = hi[c].max(*v);
        }
    }
    let mut span = vec![1u128; k];
    let mut total: u128 = 1;
    for c in 0..k {
        if lo[c] > hi[c] {
            // No value on either side: a one-value digit.
            lo[c] = 0;
            continue;
        }
        span[c] = (i128::from(hi[c]) - i128::from(lo[c]) + 1) as u128;
        total = total.checked_mul(span[c])?;
        if total > i64::MAX as u128 {
            return None;
        }
    }
    let pack = |parts: &[KeyPart]| -> Vec<Key> {
        let n = parts[0].1.len();
        (0..n)
            .map(|row| {
                let mut acc: u128 = 0;
                for c in 0..k {
                    let Key::Int(v) = parts[c].1[row] else {
                        unreachable!("checked above")
                    };
                    acc = acc * span[c] + (i128::from(v) - i128::from(lo[c])) as u128;
                }
                Key::Int(acc as i64)
            })
            .collect()
    };
    Some((
        (pos_l.clone(), pack(parts_l)),
        (pos_r.clone(), pack(parts_r)),
    ))
}

/// Combine one side's per-column `(positions, keys)` into its per-position
/// key (see [`side_key_parts`]). `None` for no columns, or for columns that do
/// not run over the same positions.
pub(super) fn composite_side_keys(
    mut parts: Vec<(Vec<i64>, Vec<crate::relational::Key>)>,
) -> Option<(Vec<i64>, Vec<crate::relational::Key>)> {
    if parts.len() == 1 {
        return parts.pop();
    }
    let (positions, _) = parts.first()?;
    let positions = positions.clone();
    // Every column of one side runs over the SAME loop symbol, so a length
    // or position disagreement means the gate does not describe this node.
    if parts.iter().any(|(p, _)| *p != positions) {
        return None;
    }
    let keys = (0..positions.len())
        .map(|t| crate::relational::Key::Tuple(parts.iter().map(|p| p.1[t].clone()).collect()))
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
    let ((pos_l, keys_l), (pos_r, keys_r)) = composite_pair_keys(
        side_key_parts(&g.cols_l, ctx)?,
        side_key_parts(&g.cols_r, ctx)?,
    )?;
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
pub(super) fn index_from_sides(sides: EqSides) -> (crate::broad_phase::OverlapIndex, usize, usize) {
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
/// Gates between two CONTRACTED dims ([`super::gate_walk`]) take part the same
/// way: a restriction Phase 1 put on one end is propagated across them to a
/// fixpoint before the walk, and during the walk a dim enumerates the
/// intersection of the partner lists of EVERY such gate to an earlier dim.
///
/// It stays bit-identical for the same reason the single-gate driver did: each
/// list is ascending and duplicate-free, so their intersection is an
/// order-preserving subsequence of the dim's own ascending range, and every
/// leaf it drops is one the lowered equality `filter` would have excluded.
pub(super) fn reduce_contraction_gated<'g>(
    spec: &ReduceSpec,
    ranges: &[(i64, i64)],
    gates: &[(JoinGate, GatePlacement)],
    plan: &GatePlan<'g>,
    bufs: &mut CellBufs<'g>,
    ctx: &mut EvalCtx,
) -> f64 {
    let reduce = spec.reduce;
    // Phase 1, the empty-range guard and the propagation, shared with the
    // tape builder ([`super::gate_walk`]).
    let admitted = {
        let binds = &ctx.loop_binds;
        plan.restrict_cell(
            ranges,
            |g, src| {
                let (gate, _) = &gates[g];
                binds
                    .get(if src { &gate.sym_src } else { &gate.sym_tgt })
                    .copied()
            },
            bufs,
        )
    };
    if !admitted {
        return reduce.identity();
    }
    let mut sink = EvalSink {
        spec,
        ctx,
        acc: reduce.identity(),
    };
    plan.walk_cell(ranges, bufs, &mut sink);
    sink.acc
}

/// The interpreter's [`TupleSink`]: bind each contracted symbol as the walk
/// reaches its depth, and fold each leaf's term the way
/// [`reduce_contraction`] does.
struct EvalSink<'s, 'r, 'c, 'e> {
    spec: &'s ReduceSpec<'r>,
    ctx: &'c mut EvalCtx<'e>,
    acc: f64,
}

impl TupleSink for EvalSink<'_, '_, '_, '_> {
    #[inline]
    fn bind(&mut self, d: usize, v: i64) {
        set_bind(&mut self.ctx.loop_binds, &self.spec.contract_names[d], v);
    }

    #[inline]
    fn leaf(&mut self, _cur: &[i64]) -> bool {
        let &ReduceSpec {
            body,
            reduce,
            filter,
            cell,
            contract_names,
        } = self.spec;
        crate::broad_phase::bump_overlap_enum_visits(1);
        if !filter_excludes(filter, cell, self.ctx) {
            let v = eval(body, self.ctx);
            let term = cell_term(v, body, cell, self.ctx);
            // Pointwise (no contracted index): the body itself, as
            // `reduce_contraction` returns it, not `0̄ ⊕ body`, so a `-0.0`
            // term stays `-0.0`.
            self.acc = if contract_names.is_empty() {
                term
            } else {
                reduce.combine(self.acc, term)
            };
        }
        true
    }
}

/// A recognized **prefix scan**: a `faq` whose single contracted index is
/// admitted by a monotone `filter` against one output index symbol (esm-spec
/// §4.3.1 "Cumulative (prefix) reductions").
///
/// Recognizing it turns the `O(N²)` triangular double loop into one `O(N)` sweep
/// with a running accumulator. The rewrite is **bit-identical, not approximate**,
/// because §4.3.1 fixes each window's fold order to be the sweep's: a FORWARD
/// scan (`j <= i`, `j < i`) folds its window ascending, lowest `j` first, and a
/// REVERSE scan (`j >= i`, `j > i`) folds its suffix descending, highest `j`
/// first, so in both `accᵢ = acc_prev ⊕ bodyᵢ` reproduces the left fold with
/// the same association.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct PrefixScan {
    /// Position of the scanned symbol within the output-index tuple: the axis
    /// the accumulator sweeps along.
    pub axis: usize,
    /// `true` for `<=` / `>=` (the newly admitted term joins BEFORE the cell
    /// is written), `false` for `<` / `>` (the cell is written first, so its
    /// window is the strictly-earlier terms and the first cell swept is the
    /// empty reduction).
    pub inclusive: bool,
    /// `true` for a reverse scan (`j >= i`, `j > i`): the sweep runs from the
    /// axis's high end down.
    pub reverse: bool,
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
    let ScanWindow {
        axis,
        inclusive,
        reverse,
    } = scan_window(output_idx_names, j_name, filter)?;
    let i_name = &output_idx_names[axis];
    // Same interval, or `j = i` is not the term entering the window at step `i`.
    if output_ranges.get(axis)? != &(c_lo, c_hi) {
        return None;
    }
    // A body that reads the scanned symbol makes each cell's summand distinct.
    if expr_references(body, i_name) {
        return None;
    }
    Some(PrefixScan {
        axis,
        inclusive,
        reverse,
    })
}

/// The window a `filter` admits when it is exactly one comparison between
/// the contracted index `j_name` and an output index (esm-spec §4.3.1): a
/// prefix (`j <= i`, `j < i`, and the mirrored `i >= j`, `i > j`) or a
/// suffix, a reverse window (`j >= i`, `j > i`, `i <= j`, `i < j`).
pub(super) struct ScanWindow {
    /// Position of the output index within the output-index tuple.
    pub axis: usize,
    /// The comparison admits `j = i`.
    pub inclusive: bool,
    /// A suffix window, folded from its high end.
    pub reverse: bool,
}

pub(super) fn scan_window(
    output_idx_names: &[String],
    j_name: &str,
    filter: &Expr,
) -> Option<ScanWindow> {
    let Expr::Operator(node) = filter else {
        return None;
    };
    if node.args.len() != 2 {
        return None;
    }
    // Normalize to `low <op> high`: `j <= i` and `i >= j` are the same
    // forward predicate, `j >= i` and `i <= j` the same reverse one.
    let (lhs, rhs) = (var_name(&node.args[0])?, var_name(&node.args[1])?);
    let (low, high, inclusive) = match node.op.as_str() {
        "<=" | "<" => (lhs, rhs, node.op == "<="),
        ">=" | ">" => (rhs, lhs, node.op == ">="),
        _ => return None,
    };
    let (i_name, reverse) = if low == j_name {
        (high, false)
    } else if high == j_name {
        (low, true)
    } else {
        return None;
    };
    let axis = output_idx_names.iter().position(|s| s == i_name)?;
    Some(ScanWindow {
        axis,
        inclusive,
        reverse,
    })
}

/// Does this contraction fold its one contracted index from the top: is
/// its filter a reverse window (esm-spec §4.3.1)? Every other contraction
/// folds ascending.
pub(super) fn folds_from_the_top(
    output_idx_names: &[String],
    contract_names: &[String],
    filter: Option<&Expr>,
) -> bool {
    let (Some(filter), [j_name]) = (filter, contract_names) else {
        return false;
    };
    scan_window(output_idx_names, j_name, filter).is_some_and(|w| w.reverse)
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
    let steps: &mut dyn Iterator<Item = i64> = if scan.reverse {
        &mut (lo..=hi).rev()
    } else {
        &mut (lo..=hi)
    };
    for i in steps {
        if scan.inclusive {
            // `<=`: the new term joins the window BEFORE this cell is written.
            let term = term_at(i, ctx);
            acc = reduce.combine(acc, term);
            set_bind(&mut ctx.loop_binds, i_name, i);
            emit(i, acc, ctx);
        } else {
            // `<`: this cell sees only strictly-earlier terms, so the first
            // cell swept emits the untouched identity — the empty reduction, not an error.
            set_bind(&mut ctx.loop_binds, i_name, i);
            emit(i, acc, ctx);
            let term = term_at(i, ctx);
            acc = reduce.combine(acc, term);
        }
    }
}

/// Does any ragged contracted dim name another CONTRACTED index among its
/// parents? Its bound then depends on that index's current value, which only a
/// nested walk binds in time.
pub(super) fn has_contracted_ragged_parent(
    contract_names: &[String],
    contract_dims: &[ContractDim],
) -> bool {
    contract_dims.iter().any(|d| match d {
        ContractDim::Ragged { of, .. } => of.iter().any(|p| contract_names.contains(p)),
        _ => false,
    })
}

/// The contracted dims' visit order for a nest: the node's usual order (first
/// listed outermost, as [`CartesianTuples`] walks it), except that a ragged dim
/// is moved after every contracted parent it reads, stably. Its bound depends
/// on the parent, so the parent must be outer (esm-spec §4.3.1).
pub(super) fn parent_first_order(
    contract_names: &[String],
    contract_dims: &[ContractDim],
) -> SmallVec<[usize; 4]> {
    let n = contract_names.len();
    let parents = |i: usize| -> SmallVec<[usize; 2]> {
        match &contract_dims[i] {
            ContractDim::Ragged { of, .. } => of
                .iter()
                .filter_map(|p| contract_names.iter().position(|c| c == p))
                .filter(|&j| j != i)
                .collect(),
            _ => SmallVec::new(),
        }
    };
    let mut order: SmallVec<[usize; 4]> = SmallVec::new();
    let mut placed = vec![false; n];
    while order.len() < n {
        // The first unplaced dim whose contracted parents are all placed; a
        // cycle (never valid) falls back to the first unplaced dim.
        let next = (0..n)
            .find(|&i| !placed[i] && parents(i).iter().all(|&j| placed[j]))
            .or_else(|| (0..n).find(|&i| !placed[i]))
            .expect("an unplaced dim remains");
        placed[next] = true;
        order.push(next);
    }
    order
}

/// Fold the contraction as a nest over `order[depth..]`, resolving each dim's
/// bound only once every outer dim is bound, ascending at every level (the left
/// fold of the terms in visit order). A filtered-out point is skipped, exactly
/// as the Cartesian walk in [`reduce_contraction`] skips it.
fn fold_dependent_nest(
    spec: &ReduceSpec,
    contract_dims: &[ContractDim],
    order: &[usize],
    depth: usize,
    acc: &mut f64,
    ctx: &mut EvalCtx,
) {
    if depth == order.len() {
        if filter_excludes(spec.filter, spec.cell, ctx) {
            return;
        }
        let v = eval(spec.body, ctx);
        let term = cell_term(v, spec.body, spec.cell, ctx);
        *acc = spec.reduce.combine(*acc, term);
        return;
    }
    let d = order[depth];
    let (lo, hi) = contract_dims[d].concrete(ctx);
    for v in lo..=hi {
        set_bind(&mut ctx.loop_binds, &spec.contract_names[d], v);
        fold_dependent_nest(spec, contract_dims, order, depth + 1, acc, ctx);
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

/// The evaluation parameters of a standalone `faq` node.
///
/// Extracted in ONE place so the per-cell oracle ([`eval_faq`]) and the tape
/// lowering derive them from the same code. A divergence here (a different contracted-
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
    /// The tape lowering consults this and declines: they evaluate the FULL product as shifted whole-array slices,
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

    // ---- Forward prefix scan (O(N) instead of the O(N²) triangle) -----------
    // A cumulative reduction (esm-spec §4.3.1) reaches here as a full triangular
    // double loop: N output cells × N contracted terms, each re-summing a window
    // the previous cell already summed. Recognized, it becomes one sweep with a
    // running accumulator — bit-identical, because both fold the window ascending
    // in the same association (see [`PrefixScan`]).
    let cells = FaqCells::new(
        idx_names,
        &ranges,
        body,
        &contract_names,
        &contract_dims,
        reduce,
        filter,
        None,
        &gates,
    );

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
        ctx.walks.note_walk();
        // A strict caller has already been told to refuse (see
        // [`CellWalks`]): this walk's value is never read.
        if ctx.walks.stopped() {
            return if shape.is_empty() {
                Value::Scalar(0.0)
            } else {
                Value::Array(Box::new(ArrayD::zeros(IxDyn(&shape))))
            };
        }
    }
    let mut buf = vec![0.0f64; total];
    cells.walk(ctx, |cell, v, _| {
        buf[multi_to_flat_col_major(cell, &shape, &origin)] = v;
    });
    if shape.is_empty() {
        Value::Scalar(buf[0])
    } else {
        Value::Array(Box::new(col_major_to_arrayd(&buf, &shape)))
    }
}

/// One `faq`'s per-cell walk: every output cell's ⊕-reduced value, handed to
/// a sink with the cell's output tuple, in the oracle's visiting order.
///
/// The one evaluation order of the construct, shared by a standalone `faq`
/// ([`eval_faq`]) and the per-cell oracle's state-derivative and observed
/// rules (`rhs.rs`). It recognizes a forward prefix scan
/// ([`detect_prefix_scan`]) and sweeps it in O(N); drives the contraction
/// from resolved join gates when there are any; and honours a
/// stop at the first cell ([`CellWalks`]), counting each cell it evaluates.
pub(super) struct FaqCells<'s> {
    idx_names: &'s [String],
    ranges: &'s [(i64, i64)],
    body: &'s Expr,
    contract_names: &'s [String],
    contract_dims: &'s [ContractDim],
    reduce: ReduceKind,
    filter: Option<&'s Expr>,
    /// The variable the rule being walked defines, for a diagnostic to name.
    rule: Option<&'s str>,
    gates: &'s [(JoinGate, GatePlacement)],
    /// The contraction bounds when every contracted dim is cell-independent,
    /// hoisted out of the cell loop.
    pub(super) static_ranges: Option<RangeVec>,
    /// The prefix scan the walk sweeps instead of the triangular product.
    pub(super) scan: Option<PrefixScan>,
}

impl<'s> FaqCells<'s> {
    #[allow(clippy::too_many_arguments)]
    pub(super) fn new(
        idx_names: &'s [String],
        ranges: &'s [(i64, i64)],
        body: &'s Expr,
        contract_names: &'s [String],
        contract_dims: &'s [ContractDim],
        reduce: ReduceKind,
        filter: Option<&'s Expr>,
        rule: Option<&'s str>,
        gates: &'s [(JoinGate, GatePlacement)],
    ) -> Self {
        let static_ranges = static_contract_ranges(contract_dims);
        let scan = detect_prefix_scan(
            idx_names,
            ranges,
            contract_names,
            static_ranges.as_deref(),
            body,
            filter,
        );
        FaqCells {
            idx_names,
            ranges,
            body,
            contract_names,
            contract_dims,
            reduce,
            filter,
            rule,
            gates,
            static_ranges,
            scan,
        }
    }

    /// Walk every cell, calling `sink(cell, value, ctx)` with the cell's
    /// output tuple and its reduced value; `ctx` has the cell's output (and,
    /// in a scan, contracted) symbols bound. The binds `ctx` held for these
    /// symbols are restored afterwards.
    pub(super) fn walk(&self, ctx: &mut EvalCtx, mut sink: impl FnMut(&[i64], f64, &EvalCtx)) {
        let &FaqCells {
            idx_names,
            ranges,
            body,
            contract_names,
            contract_dims,
            reduce,
            filter,
            rule,
            gates,
            ref static_ranges,
            scan,
        } = self;
        // A rank-0 node with nothing to contract is a single evaluation, not
        // a walk: it neither counts a cell nor stops.
        let is_walk = !idx_names.is_empty() || !contract_names.is_empty();
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
                bounds: if !ctx.walks.stop_at_first {
                    (scan_lo, scan_hi)
                } else if scan.reverse {
                    (scan_lo.max(scan_hi), scan_hi)
                } else {
                    (scan_lo, scan_hi.min(scan_lo))
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
                run_prefix_scan(&sweep, ctx, |i, acc, ctx| {
                    note_per_cell_cell();
                    full[scan.axis] = i;
                    sink(&full, acc, ctx);
                });
                if ctx.walks.after_first_cell() {
                    break;
                }
            }
        } else {
            let origin: DimI = ranges.iter().map(|(lo, _)| *lo).collect();
            let cellbox = CellBox {
                names: idx_names,
                origin: &origin,
                ranges,
                rule,
            };
            let spec = ReduceSpec {
                contract_names,
                body,
                reduce,
                filter,
                cell: Some(&cellbox),
            };
            // Per-node cost accounting. The counter is thread-local and bumped
            // only on the gate-driven unroll, so the delta across this output
            // loop is exactly the leaves THIS aggregate enumerated.
            let stats_from = (!gates.is_empty() && crate::broad_phase::join_gate_log_enabled())
                .then(crate::broad_phase::overlap_enum_visits);
            // The gated walk's cell-independent plan and its per-cell buffers,
            // built once for the whole output loop.
            let gate_plan = GatePlan::new(
                contract_names.len(),
                gates.iter().map(|(g, p)| (&*g.index, p.src, p.tgt)),
            );
            let mut gate_bufs = gate_plan.bufs();
            let mut tuples = CartesianTuples::new(ranges);
            while let Some(tuple) = tuples.next() {
                for (name, val) in idx_names.iter().zip(tuple.iter()) {
                    set_bind(&mut ctx.loop_binds, name, *val);
                }
                let v = if gates.is_empty() {
                    reduce_contraction(&spec, contract_dims, static_ranges.as_deref(), ctx)
                } else {
                    // This cell's contraction bounds: the hoisted static ones
                    // when every dim is cell-independent, else re-derived here
                    // exactly as `reduce_contraction` does.
                    let derived: SmallVec<[(i64, i64); 4]>;
                    let cell_ranges: &[(i64, i64)] = match static_ranges.as_deref() {
                        Some(r) => r,
                        None => {
                            derived = contract_dims.iter().map(|d| d.concrete(ctx)).collect();
                            &derived
                        }
                    };
                    reduce_contraction_gated(
                        &spec,
                        cell_ranges,
                        gates,
                        &gate_plan,
                        &mut gate_bufs,
                        ctx,
                    )
                };
                sink(tuple, v, ctx);
                if is_walk {
                    note_per_cell_cell();
                    if ctx.walks.after_first_cell() {
                        break;
                    }
                }
            }
            if let Some(before) = stats_from {
                let total: usize = ranges
                    .iter()
                    .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                    .product();
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
    }
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
    // Two region shapes would PANIC below if they reached it: a ragged
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
        // reads its aligned element (the tape's `Instr::Region` and the
        // Julia/Python region semantics).
        //
        // A shape MISMATCH poisons the result with the NaN sentinel rather
        // than leaving the region as the `zeros` fill, where a region `[1, 3]`
        // given a 2-element `const` value would assemble to `[0.0, 0.0, 0.0]`
        // with no sign that its value expression was discarded. This
        // interpreter has no error channel (`eval` returns a `Value`, and the solver reads `NaN` as a step
        // failure), so a loud `NaN` is the strongest signal available — and it is
        // strictly better than a plausible-looking zero.
        if let Value::Array(a) = &v
            && a.ndim() > 0
        {
            let region_shape: Vec<usize> = ranges
                .iter()
                .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                .collect();
            // The value must fit the region, excluding its singleton axes
            // (esm-spec §4.3.2): the face region `[[1,1],[1,n]]` takes an
            // `[n]` value.
            let Some(covered) = region_value_axes(a.shape(), &region_shape) else {
                return Value::Scalar(f64::NAN);
            };
            // The legal EMPTY region spelling (`stop == start - 1`, §4.3.2)
            // writes nothing — and its `start` may sit one past the bounding
            // box, which is not a slicable offset. The per-cell walk produced no
            // tuples here; skip explicitly.
            if region_shape.contains(&0) {
                continue;
            }
            // Whole-region slice assign: a straight sub-block copy, with no
            // per-cell index tuples. Both arrays are in the evaluator's
            // row-major layout and the shapes were just checked equal, so
            // every value lands at its region cell.
            arr.slice_each_axis_mut(|ax| {
                let d = ax.axis.index();
                let s0 = (ranges[d].0 - origin[d]) as usize;
                ndarray::Slice::from(s0..s0 + region_shape[d])
            })
            .assign(&region_value_view(a.view(), &covered));
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
/// The whole implementation is one delegation. Delegating to [`eval_op_named`] makes `broadcast(fn = F, args)` evaluate
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
            matches!(err, CompileError::UnloweredOperatorError { ref op, .. } if op == "expp"),
            "{err:?}"
        );
    }

    /// An unlowered spatial `D` reaching evaluation is reported, not answered
    /// with the NaN sentinel.
    #[test]
    fn unlowered_spatial_op_is_rejected_not_nan() {
        let spatial_d = Expr::operator(ExpressionNode {
            op: "D".to_string(),
            args: vec![Expr::Variable("c".into())],
            wrt: Some("x".to_string()),
            ..ExpressionNode::default()
        });
        let err = eval_it(&spatial_d).expect_err("an unlowered spatial operator must not evaluate");
        assert!(
            matches!(err, CompileError::UnloweredOperatorError { ref op, .. } if op == "D"),
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

    /// Ops the REGISTRY calls legal (`is_core_op`) but this evaluator has no
    /// arm for, because an earlier pipeline stage eliminates them, are
    /// reported rather than answered with `NaN`.
    #[test]
    fn registry_legal_but_unevaluable_ops_are_rejected_not_nan() {
        for op in ["distinct", "ic", "enum"] {
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
            vec![Expr::Number(1.0), node("distinct", vec![Expr::Number(2.0)])],
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
            "distinct",
            "ic",
            "enum",
            "apply_operator",
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
    /// Four ops, each eliminated by an earlier stage — and NOTHING else, which
    /// is what makes the build-time gate in `compile.rs` a complete answer to
    /// the `unreachable!` backstop rather than a patch for the op that was
    /// reported. A fifth entry appearing here means a new op reached the
    /// registry without an evaluation rule and can panic; it must be given a
    /// rule or added to this list deliberately.
    #[test]
    fn the_core_minus_evaluable_gap_is_exactly_four_ops() {
        const CORE: &[&str] = &[
            "+",
            "-",
            "*",
            "/",
            "^",
            "neg",
            "exp",
            "log",
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
            "enum",
            "apply_operator",
            "faq",
            "makearray",
            "index",
            "broadcast",
            "reshape",
            "transpose",
            "concat",
            "distinct",
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
        assert_eq!(gap, vec!["apply_operator", "distinct", "enum", "ic"]);
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
        let declared: HashSet<String> = declared.iter().map(|s| (*s).to_string()).collect();
        let forcing: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
        let env = EvalEnv {
            state_arrays: &empty_arrays,
            params: &[],
            param_names: &[],
            t: 0.0,
            derived_extents: empty_derived_extents(),
            forcing: &forcing,
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
/// A clause whose key is low-cardinality matches enormously — six distinct
/// fuel types against a 1.4-million-row table is 167 million pairs — so
/// building every clause's index before consulting §5.24's selectivity
/// estimate would materialise those pairs even when a sibling clause has
/// already cut the table to seven rows. [`resolve_join_gates`] therefore reads
/// what a gate WOULD cost with [`crate::relational::equijoin_match_count`]
/// (`O(|L| + |R|)`, no pair written), resolves gates cheapest-first, and
/// declines one that would materialise more pairs than the tuples it could
/// prune.
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
                "esm": "2.0.0",
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

#[cfg(test)]
mod saturated_subscript_tests {
    //! A subscript of `±inf` or `±1e300` saturates to `i64::MIN`/`i64::MAX`
    //! in `eval_index_args`; the periodic fold of CONFORMANCE_SPEC §5.5.5,
    //! `((i − 1) mod N) + 1`, must still be the exact residue of that
    //! integer, with no overflow.
    use super::{GatherKind, Value, index_into, periodic_offset};
    use crate::simulate_array::ConstArrayScope;
    use crate::value_invention::BoundaryKind;
    use ndarray::{ArrayD, IxDyn};

    fn read(raw: i64, kind: BoundaryKind) -> f64 {
        let arr = ArrayD::from_shape_vec(IxDyn(&[5]), vec![10.0, 20.0, 30.0, 40.0, 50.0]).unwrap();
        let scope = ConstArrayScope::default().with_boundary("M", vec![kind]);
        let kind = GatherKind::ConstArray {
            name: "M",
            scope: &scope,
        };
        match index_into(&arr, &[raw], true, kind) {
            Value::Scalar(v) => v,
            _ => panic!("scalar expected"),
        }
    }

    #[test]
    fn periodic_fold_of_a_saturated_subscript() {
        for raw in [i64::MIN, i64::MIN + 1, i64::MAX, i64::MAX - 1, -7, 0, 6] {
            let want = (raw as i128 - 1).rem_euclid(5) as usize;
            assert_eq!(periodic_offset(raw, 5), want, "{raw}");
            assert_eq!(
                read(raw, BoundaryKind::Periodic),
                10.0 * (want + 1) as f64,
                "{raw}"
            );
        }
        // (i64::MIN − 1) mod 5 = 1: element 2, not the wrapped i64::MAX's 3.
        assert_eq!(read(f64::NEG_INFINITY as i64, BoundaryKind::Periodic), 20.0);
        assert_eq!(read(-1e300_f64 as i64, BoundaryKind::Periodic), 20.0);
        assert_eq!(read(f64::INFINITY as i64, BoundaryKind::Periodic), 20.0);
    }

    #[test]
    fn clamp_of_a_saturated_subscript() {
        assert_eq!(read(i64::MIN, BoundaryKind::Clamp), 10.0);
        assert_eq!(read(i64::MAX, BoundaryKind::Clamp), 50.0);
    }

    #[test]
    fn zero_ghost_of_a_saturated_subscript() {
        let arr = ArrayD::from_shape_vec(IxDyn(&[5]), vec![10.0, 20.0, 30.0, 40.0, 50.0]).unwrap();
        for raw in [i64::MIN, i64::MAX] {
            match index_into(&arr, &[raw], true, GatherKind::ZeroGhost) {
                Value::Scalar(v) => assert_eq!(v.to_bits(), 0.0f64.to_bits(), "{raw}"),
                _ => panic!("scalar expected"),
            }
        }
    }
}
