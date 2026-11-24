//! Runtime RHS evaluation: the zero-allocation scratch ([`RhsScratch`]),
//! observed (algebraic) rule materialization, dependency ordering, and the
//! per-call rule driver [`evaluate_rhs_with_scratch`].

use super::tape::{TapeCtx, TapeProgram, run_tape_call};
use super::*;
use crate::simulate::CompileError;
#[cfg(test)]
use ndarray::ArrayViewD;
use std::collections::HashSet;

/// Persistent per-call scratch for [`evaluate_rhs_with_scratch`]: either a
/// compiled tape, or the per-cell oracle's reusable state and observed arrays.
/// One is owned per evaluator (the Jacobian carries its own), guarded by a
/// `RefCell` because diffsol's RHS is an `Fn`, not `FnMut`.
pub struct RhsScratch {
    /// Per-variable state arrays, logical row-major over each variable's shape,
    /// refilled in place from the flat state slice each call.
    state_arrays: ArrMap,
    /// Observed (algebraic) arrays; the container is reused across calls.
    observed_arrays: ArrMap,
    /// Names of the hoisted STATE-FREE / `t`-free observeds (ess: static-observed
    /// hoist). Their arrays are seeded into `observed_arrays` ONCE by
    /// [`Self::set_static`] and then RETAINED in place across every RHS eval
    /// (never cleared, never re-cloned), so a build-once product — the
    /// conservative-regrid weights (the large `A_ij`/`W_ij` matrices over the
    /// src×tgt cell pairs), the regridded
    /// terrain + slopes, the Rothermel coefficients derived from the CONST
    /// forcing — is materialized once, not recomputed on every step. The
    /// `observed_rules` the RHS is handed is correspondingly the *varying*
    /// subset. Empty for a model with no such observeds (the debug/oracle entry
    /// points leave it empty and pass the full rule set, so a plain `clear` +
    /// full materialize is recovered — byte-identical to the un-hoisted path).
    static_keys: HashSet<String>,
    /// The compiled tape context ([`Self::install_tape`]). `None` means
    /// [`evaluate_rhs_with_scratch`] runs the per-cell oracle.
    tape: Option<TapeCtx>,
    /// The model's CONST-ARRAY provenance (CONFORMANCE_SPEC §5.5.5), installed
    /// by [`Self::set_const_arrays`]. Carried on the scratch rather than passed
    /// per call because it is a property of the compiled MODEL, not of a step;
    /// it reaches every [`EvalCtx`] the RHS builds. Empty by default, so a
    /// scratch nobody configures reads byte-identically to the pre-§5.5.5
    /// evaluator.
    const_arrays: std::sync::Arc<ConstArrayScope>,
}

impl RhsScratch {
    /// Build a scratch sized to a model's variable shapes. State arrays are
    /// allocated once here (zero-filled); subsequent RHS calls only overwrite
    /// their contents. Observed value arrays are materialized lazily.
    pub(super) fn new(var_shapes: &IndexMap<String, VarShape>) -> Self {
        let mut state_arrays = ArrMap::with_capacity_and_hasher(var_shapes.len(), FxBuildHasher);
        for (name, vs) in var_shapes {
            state_arrays.insert(name.clone(), ArrayD::<f64>::zeros(IxDyn(&vs.shape)));
        }
        RhsScratch {
            state_arrays,
            observed_arrays: ArrMap::default(),
            static_keys: HashSet::new(),
            tape: None,
            const_arrays: std::sync::Arc::new(ConstArrayScope::default()),
        }
    }

    /// Install the compiled model's const-array registry (§5.5.5), so a gather
    /// on one of those factors resolves an out-of-range index by its declared
    /// boundary policy instead of the state gather's zero ghost.
    pub(super) fn set_const_arrays(&mut self, scope: std::sync::Arc<ConstArrayScope>) {
        self.const_arrays = scope;
    }

    /// The installed const-array registry.
    pub(super) fn const_arrays(&self) -> &std::sync::Arc<ConstArrayScope> {
        &self.const_arrays
    }

    /// Install a compiled tape program (Step 3b). Called by the driver on the
    /// production RHS closure's scratch. Subsequent
    /// [`evaluate_rhs_with_scratch`] calls run the tape.
    pub(super) fn install_tape(&mut self, prog: std::sync::Arc<TapeProgram>) {
        self.tape = Some(TapeCtx::new(prog));
    }

    /// The forcing buffer was refreshed: an installed tape re-runs its
    /// SEGMENT section on the next call. No-op on a scratch with no tape,
    /// which reads the buffer on every call.
    #[cfg(test)]
    pub(super) fn bump_forcing_epoch(&mut self) {
        if let Some(tape) = self.tape.as_mut() {
            tape.bump_forcing_epoch();
        }
    }

    /// Whether this scratch carries a compiled tape (test observability).
    pub fn has_tape(&self) -> bool {
        self.tape.is_some()
    }

    /// Force the tape's `Export` publishes on, so a caller can read every
    /// observed's value back after a call.
    ///
    /// Production leaves it off — with nothing able to read a published
    /// array the publish is a pure cost — so a scratch built to HARVEST
    /// observeds has to say so. No-op on a scratch with no tape.
    pub(super) fn set_exports_active(&mut self, on: bool) {
        if let Some(tape) = self.tape.as_mut() {
            tape.set_exports_active(on);
        }
    }

    /// The observeds the last untaped call materialized. On a scratch that
    /// carries a tape, read [`Self::taped_observeds`] instead.
    pub(super) fn observed_arrays(&self) -> &ArrMap {
        &self.observed_arrays
    }

    /// The observeds the tape published on the last call, or `None` on a
    /// scratch that carries no tape.
    pub(super) fn taped_observeds(&self) -> Option<&ArrMap> {
        self.tape
            .as_ref()
            .map(super::tape::TapeCtx::exported_observeds)
    }

    /// Install the hoisted static observeds (see [`Self::static_keys`]): seed
    /// their arrays into `observed_arrays` once and remember their names so each
    /// RHS eval retains them in place. Called once per `simulate` closure setup;
    /// the debug entry points never call it, so they clear + materialize the full
    /// rule set every call as before.
    pub(super) fn set_static(&mut self, static_observeds: ArrMap) {
        self.static_keys = static_observeds.keys().cloned().collect();
        for (name, arr) in static_observeds {
            self.observed_arrays.insert(name, arr);
        }
    }
}

/// Overwrite each persistent state array with the current flat state, reading
/// each variable's column-major block into its logical array in place. The
/// per-element address is computed explicitly, so no per-call allocation and no
/// reliance on ndarray iteration order is needed.
pub(super) fn refill_state_arrays(
    state_arrays: &mut ArrMap,
    var_shapes: &IndexMap<String, VarShape>,
    state: &[f64],
) {
    for (name, vs) in var_shapes {
        let total = vs.shape.iter().copied().product::<usize>().max(1);
        let block = &state[vs.flat_offset..vs.flat_offset + total];
        let arr = state_arrays
            .get_mut(name)
            .expect("scratch has a state array for every variable");
        if vs.shape.is_empty() {
            arr[IxDyn(&[])] = block[0];
            continue;
        }
        let n = vs.shape.len();
        let mut multi = DimU::from_elem(0usize, n);
        for _ in 0..total {
            let mut cm = 0usize;
            let mut stride = 1usize;
            for d in 0..n {
                cm += multi[d] * stride;
                stride *= vs.shape[d];
            }
            arr[IxDyn(&multi)] = block[cm];
            for d in (0..n).rev() {
                multi[d] += 1;
                if multi[d] < vs.shape[d] {
                    break;
                }
                multi[d] = 0;
            }
        }
    }
}

/// Scatter a logical array into a *sub-block* of a variable's flat `dy` block,
/// in column-major order (the state-vector layout). `dest_lo[d]` is the 0-based
/// start of the sub-block along axis `d` within the variable's box (extent
/// `vs.shape`); the array's own extent must fit (`dest_lo[d] + arr.shape()[d] ≤
/// vs.shape[d]`, guaranteed by [`subblock_dest`]). This is the placement for an
/// affine-shifted LHS `D(u[i+c]) = …`; the bare-index method-of-lines case is
/// `dest_lo = 0…` with `arr` spanning the whole variable box.
#[cfg(test)]
pub(super) fn scatter_col_major_offset(
    arr: ArrayViewD<f64>,
    dy: &mut [f64],
    vs: &VarShape,
    dest_lo: &[usize],
) {
    let n = arr.ndim();
    if n == 0 {
        dy[vs.flat_offset] = arr[IxDyn(&[])];
        return;
    }
    let total: usize = arr.shape().iter().product();
    let mut multi = DimU::from_elem(0usize, n);
    for _ in 0..total {
        // Column-major flat index of (dest_lo + multi) within the variable box.
        let mut cm = 0usize;
        let mut stride = 1usize;
        for d in 0..n {
            cm += (dest_lo[d] + multi[d]) * stride;
            stride *= vs.shape[d];
        }
        dy[vs.flat_offset + cm] = arr[IxDyn(&multi)];
        for d in (0..n).rev() {
            multi[d] += 1;
            if multi[d] < arr.shape()[d] {
                break;
            }
            multi[d] = 0;
        }
    }
}

/// The target variable an observed algebraic rule defines.
pub(super) fn observed_rule_var(rule: &AlgebraicRule) -> &String {
    match rule {
        AlgebraicRule::Scalar { var, .. }
        | AlgebraicRule::ArrayLoop { var, .. }
        | AlgebraicRule::Recurrence { var, .. } => var,
    }
}

/// The defining body expression of an observed algebraic rule.
pub(super) fn observed_rule_body(rule: &AlgebraicRule) -> &Expr {
    match rule {
        AlgebraicRule::Scalar { body, .. }
        | AlgebraicRule::ArrayLoop { body, .. }
        | AlgebraicRule::Recurrence { body, .. } => body,
    }
}

/// The cell frame of a recurrence: column-major extents and 1-based origin.
pub(super) fn recur_frame(output_ranges: &[(i64, i64)]) -> (DimU, DimI) {
    (
        output_ranges
            .iter()
            .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
            .collect(),
        output_ranges.iter().map(|(lo, _)| *lo).collect(),
    )
}

/// Run one causal-self-reference sweep into `scope` and return the finished
/// array (esm-spec §4.3.1.1, CONFORMANCE_SPEC §5.19).
///
/// THE single implementation of the construct's evaluation order, shared by the
/// per-step observed materialization and by the build pipeline
/// (`prepare::eval_observed`). Two call sites with two copies is how this
/// construct came to evaluate correctly under `esm test` and return a
/// plausible wrong answer under `esm simulate`; one function is the structural
/// fix for that, not a cleanup.
///
/// The CALLER owns `scope`, which is what makes the borrow work without
/// `unsafe`: the scope has to outlive the `&mut EvalCtx` it is installed into,
/// and only the caller's stack frame can promise that.
pub(super) fn sweep_recurrence<'a>(
    scope: &'a RecurScope<'a>,
    output_idx_names: &[String],
    output_ranges: &[(i64, i64)],
    body: &Expr,
    axis: usize,
    ctx: &mut EvalCtx<'a>,
) -> ArrayD<f64> {
    // Every axis EXCEPT the recurrence axis forms the inner product; the
    // recurrence axis is swept outside it, ascending. Cells sharing a
    // recurrence coordinate cannot read one another (every self-read is
    // strictly earlier on that axis), so their relative order is immaterial to
    // the values — it is fixed anyway, `output_idx` order ascending, so nothing
    // about the result is left to an implementation.
    let (lo, hi) = output_ranges[axis];
    let inner_ranges: Vec<(i64, i64)> = output_ranges
        .iter()
        .enumerate()
        .filter(|(d, _)| *d != axis)
        .map(|(_, r)| *r)
        .collect();
    let inner_axes: Vec<(usize, &String)> = output_idx_names
        .iter()
        .enumerate()
        .filter(|(d, _)| *d != axis)
        .collect();
    let saved = ctx.recur.take();
    ctx.recur = Some(scope);
    let mut full = vec![0i64; output_ranges.len()];
    'sweep: for i in lo..=hi {
        set_bind(&mut ctx.loop_binds, &output_idx_names[axis], i);
        full[axis] = i;
        let mut inner = CartesianTuples::new(&inner_ranges);
        while let Some(tuple) = inner.next() {
            for ((d, name), val) in inner_axes.iter().zip(tuple.iter()) {
                set_bind(&mut ctx.loop_binds, name, *val);
                full[*d] = *val;
            }
            let v = eval(body, ctx).as_scalar().unwrap_or(f64::NAN);
            // Published BEFORE the axis advances, which is the whole construct:
            // the next cell's self-read must observe this value, not a default.
            scope.publish(&full, v);
            super::eval::note_per_cell_cell();
            // A strict caller refuses the sweep; its first cell was for the
            // diagnostic (`super::eval::CellWalks`).
            if ctx.walks.after_first_cell() {
                break 'sweep;
            }
        }
    }
    ctx.recur = saved;
    scope.finish()
}

/// Collect every variable-reference leaf (`Expr::Variable`) in `expr`, walking
/// the canonical expression-bearing child set
/// ([`ExpressionNode::for_each_child`]) so a dependency edge is never missed.
/// Loop indices and other non-observed names are gathered too; the caller
/// intersects with the observed-name set to keep only the meaningful edges.
pub(super) fn collect_expr_var_refs(expr: &Expr, out: &mut HashSet<String>) {
    match expr {
        Expr::Variable(name) => {
            out.insert(name.clone());
        }
        Expr::Operator(node) => {
            node.for_each_child(&mut |child| collect_expr_var_refs(child, out));
        }
        Expr::Number(_) | Expr::Integer(_) => {}
    }
}

/// Stable topological sort of observed algebraic rules so each follows every
/// observed its body references (RFC §8.1). Independent observeds keep their
/// original order. Mirrors the Python `simulation._order_observed_equations`.
///
/// A rule set that cannot be ordered — a dependency cycle among observeds,
/// esm-spec §4.9.6 — is a hard [`CompileError::ObservedCycle`] naming the
/// cycle. This sweep used to append the stuck rules in declaration order
/// instead, on the theory that "the build still proceeds (the evaluator then
/// surfaces a clear unresolved read)". The read was not clear: materialization
/// ran the stuck rules anyway, one of them read an observed that had no value
/// yet, and `E_TREEWALK_UNBOUND_NAME` named whichever name the walk reached
/// first — which is generally an observed that is declared, defined and
/// referenced correctly, and has nothing to do with the cycle (issue #181).
/// Proceeding past an unsatisfiable order buys nothing and costs the diagnosis.
///
/// The self-edge of a recurrence is already dropped below (`n != self_name`),
/// so a well-founded causal self-read (esm-spec §4.3.1.1) is an ordering within
/// one rule and never reaches this error.
pub(super) fn dependency_order_observed(
    rules: Vec<AlgebraicRule>,
) -> Result<Vec<AlgebraicRule>, CompileError> {
    let names: HashSet<String> = rules.iter().map(|r| observed_rule_var(r).clone()).collect();
    // Per-rule dependency set, restricted to *other* observed names.
    let deps: Vec<HashSet<String>> = rules
        .iter()
        .map(|r| {
            let mut refs = HashSet::new();
            collect_expr_var_refs(observed_rule_body(r), &mut refs);
            let self_name = observed_rule_var(r);
            refs.retain(|n| names.contains(n) && n != self_name);
            refs
        })
        .collect();

    let mut placed: HashSet<String> = HashSet::new();
    let mut order: Vec<usize> = Vec::with_capacity(rules.len());
    let mut remaining: Vec<usize> = (0..rules.len()).collect();
    while !remaining.is_empty() {
        let mut progress = false;
        let mut still: Vec<usize> = Vec::new();
        for i in std::mem::take(&mut remaining) {
            if deps[i].iter().all(|d| placed.contains(d)) {
                placed.insert(observed_rule_var(&rules[i]).clone());
                order.push(i);
                progress = true;
            } else {
                still.push(i);
            }
        }
        remaining = still;
        if !progress {
            // Nothing became ready and rules are left: the residue contains at
            // least one cycle. Name it (esm-spec §4.9.6) instead of proceeding
            // into an evaluation that cannot succeed.
            return Err(CompileError::ObservedCycle {
                cycle: first_cycle_among(&rules, &deps, &remaining),
            });
        }
    }

    // Reassemble in the computed order, moving each rule out exactly once.
    let mut slots: Vec<Option<AlgebraicRule>> = rules.into_iter().map(Some).collect();
    Ok(order
        .into_iter()
        .map(|i| slots[i].take().expect("each index visited once"))
        .collect())
}

/// The first cycle among the rules that could not be ordered, as a path with
/// its entry node repeated (`["a", "b", "a"]`).
///
/// The residue is indexed by rule POSITION and its adjacency sets are
/// `HashSet`s, neither of which iterates stably, so it is re-keyed by name into
/// the sorted graph [`first_observed_cycle`] walks — the same walk, and the
/// same output shape, the validator's `observed_cycle` check uses. The two
/// remain separate CALLERS because they read different inputs (the validator
/// reads a model's equations, this reads lowered rules), and agreeing on the
/// walk is what makes their answers comparable for a document that reached here
/// unvalidated.
fn first_cycle_among(
    rules: &[AlgebraicRule],
    deps: &[HashSet<String>],
    residue: &[usize],
) -> Vec<String> {
    let stuck: std::collections::BTreeMap<String, std::collections::BTreeSet<String>> = residue
        .iter()
        .map(|&i| {
            let name = observed_rule_var(&rules[i]).clone();
            let ds: std::collections::BTreeSet<String> = deps[i].iter().cloned().collect();
            (name, ds)
        })
        .collect();

    // Unreachable in practice — the residue is non-empty precisely because no
    // rule was ready, which requires an unsatisfied dependency inside it — but
    // a name is more useful than a panic if the invariant ever moves.
    crate::classification::first_observed_cycle(&stuck)
        .unwrap_or_else(|| stuck.keys().cloned().collect())
}

// ============================================================================
// Runtime: evaluate one RHS call.
// ============================================================================

/// Build per-variable ndarray views from the flat state vector (owned copies —
/// fast enough at fixture sizes). A scalar variable becomes a 0-D array; an
/// array variable is read column-major over its inferred shape.
pub(super) fn build_state_arrays(var_shapes: &IndexMap<String, VarShape>, state: &[f64]) -> ArrMap {
    let mut state_arrays: ArrMap = ArrMap::default();
    for (name, vs) in var_shapes {
        let total = vs.shape.iter().copied().product::<usize>().max(1);
        let block = &state[vs.flat_offset..vs.flat_offset + total];
        if vs.shape.is_empty() {
            state_arrays.insert(name.clone(), ArrayD::from_elem(IxDyn(&[]), block[0]));
        } else {
            // The flat block is column-major over vs.shape.
            state_arrays.insert(name.clone(), col_major_to_arrayd(block, &vs.shape));
        }
    }
    state_arrays
}

/// Materialize `observed_rules` into `dst` WITHOUT clearing it first — the
/// rules are evaluated and their outputs inserted on top of whatever is already
/// there. This is what lets the RHS seed the hoisted static observeds (ess:
/// static-observed hoist) into `dst` and then materialize only the *varying*
/// rules over them, without recomputing the statics every step. A varying rule
/// may reference an already-seeded static observed by name (they are read from
/// `dst`), so the seed must be in place before this runs.
///
/// Every rule is evaluated by the per-cell oracle. `stats` counts the
/// array-shaped observeds.
pub(super) fn materialize_observeds_pass(
    dst: &mut ArrMap,
    observed_rules: &[AlgebraicRule],
    env: &EvalEnv,
    stats: &mut RhsStats,
) {
    for rule in observed_rules {
        materialize_observed(dst, rule, env, stats);
    }
}

/// Arm the working precision of one algebraic rule for as long as the returned
/// guard lives (esm-spec §11.3.1).
fn precision_of_rule(rule: &AlgebraicRule) -> Option<crate::precision::PrecisionGuard> {
    let var = match rule {
        AlgebraicRule::Scalar { var, .. }
        | AlgebraicRule::ArrayLoop { var, .. }
        | AlgebraicRule::Recurrence { var, .. } => var,
    };
    crate::precision::enter_variable(var)
}

/// Materialize one observed rule into `dst` (see [`materialize_observeds_pass`]).
fn materialize_observed(
    dst: &mut ArrMap,
    rule: &AlgebraicRule,
    env: &EvalEnv,
    stats: &mut RhsStats,
) {
    // The rule's own working precision (esm-spec §11.3.1). An equation is
    // evaluated at the element type of the variable it defines, which is
    // the document's unless that variable declared its own — so this is a
    // thread-local read and a no-op swap for every document that declares
    // none. Held for the whole rule, which is the scope its expression is
    // evaluated in; any subtree inside that differs carries its own
    // `precision_infer::MARKER_OP` and re-arms.
    let _rule_precision = precision_of_rule(rule);
    match rule {
        AlgebraicRule::Scalar { var, body, .. } => {
            // `derived_extents` is EMPTY on every compiled-RHS context in
            // this file, and deliberately so: `ArrayCompiled::from_model`
            // densifies each value-invented derived set to an `interval`
            // (via `rewrite_derived_index_sets`) BEFORE resolving ranges,
            // so a compiled rule's axes are already static bounds and no
            // `DerivedDyn` survives to consult the map. The channel earns
            // its keep on the standalone `eval_expression_with_extents`
            // entry point instead. See `EvalCtx::derived_extents`.
            let mut ctx = env.ctx(&*dst);
            let arr = match eval(body, &mut ctx) {
                Value::Array(a) => *a,
                // A scalar fills the rule's shape (esm-spec §4.3.4): its
                // declared one, or the one the data bound to its data-fed
                // parameters has — the same buffer the tape's build reads.
                Value::Scalar(s) => {
                    let shape = rule
                        .fill_shape(|n| ctx.forcing.borrow().get(n).map(|a| a.shape().to_vec()))
                        .unwrap_or_default();
                    ArrayD::from_elem(IxDyn(&shape), s)
                }
            };
            dst.insert(var.clone(), arr);
        }
        // Causal self-reference (esm-spec §4.3.1.1). The one rule kind whose
        // output cells are NOT independent, so the sweep is factored into
        // `sweep_recurrence` and shared with the BUILD-PIPELINE path
        // (`prepare::eval_observed`). That sharing is not tidiness: the two
        // paths having separate implementations is exactly how the
        // construct came to work under `esm test` and be dead under
        // `esm simulate`, so there is now one sweep and both callers use it.
        AlgebraicRule::Recurrence {
            var,
            output_idx_names,
            output_ranges,
            body,
            axis,
            max_lag: _,
            lag_proven: _,
        } => {
            stats.obs_scalar_rules += 1;
            let (shape, origin) = recur_frame(output_ranges);
            let scope = RecurScope::new(var.as_str(), shape, origin);
            let arr = {
                let mut ctx = env.ctx(&*dst);
                sweep_recurrence(
                    &scope,
                    output_idx_names,
                    output_ranges,
                    body,
                    *axis,
                    &mut ctx,
                )
            };
            dst.insert(var.clone(), arr);
        }
        AlgebraicRule::ArrayLoop {
            var,
            output_idx_names,
            output_ranges,
            body,
        } => {
            let padded_shape: Vec<usize> =
                output_ranges.iter().map(|(_, hi)| *hi as usize).collect();

            stats.obs_scalar_rules += 1;
            let padded_origin: Vec<i64> = vec![1i64; padded_shape.len()];
            let total = padded_shape.iter().copied().product::<usize>().max(1);
            let mut buf = vec![0.0f64; total];
            {
                // Scoped so the context's read borrow of `dst` releases before
                // the write below.
                let mut ctx = env.ctx(&*dst);
                FaqCells::new(
                    output_idx_names,
                    output_ranges,
                    body,
                    &[],
                    &[],
                    ReduceKind::Sum,
                    None,
                    Some(var.as_str()),
                    &[],
                )
                .walk(&mut ctx, |cell, v, _| {
                    let flat = multi_to_flat_col_major(cell, &padded_shape, &padded_origin);
                    if flat < buf.len() {
                        buf[flat] = v;
                    }
                });
            }
            let arr = col_major_to_arrayd(&buf, &padded_shape);
            dst.insert(var.clone(), arr);
        }
    }
}

/// The per-call RHS inputs shared by every evaluation path — the compiled
/// rules, the model tables, and the solver-supplied state/parameter/time
/// slices — grouped so the per-cell oracle and the tape executor take one
/// argument instead of a dozen.
pub(super) struct RhsCall<'a> {
    pub(super) rhs_rules: &'a [RhsRule],
    pub(super) observed_rules: &'a [AlgebraicRule],
    pub(super) var_shapes: &'a IndexMap<String, VarShape>,
    pub(super) param_names: &'a [String],
    pub(super) state: &'a [f64],
    pub(super) params: &'a [f64],
    /// External refreshable forcing-array channel (PR-1, ess-14f.7): the
    /// model-lifetime buffer a discrete-cadence driver refreshes between
    /// segments. Borrowed (not owned by the per-call scratch) so the same
    /// buffer is read across every RHS call within a segment. Empty ⇒ no
    /// behaviour change vs. the scalar-`p` path.
    pub(super) forcing: &'a RefCell<HashMap<String, ArrayD<f64>>>,
    pub(super) t: f64,
    /// See [`EvalCtx::declared`] — the compiled model's declared-name set,
    /// carried so the evaluator's fault arm can name the right defect.
    pub(super) declared: &'a HashSet<String>,
}

impl<'a> RhsCall<'a> {
    /// The evaluation environment of this call over `state_arrays`.
    fn env<'b>(&self, state_arrays: &'b ArrMap, const_arrays: &'b ConstArrayScope) -> EvalEnv<'b>
    where
        'a: 'b,
    {
        EvalEnv {
            state_arrays,
            params: self.params,
            param_names: self.param_names,
            t: self.t,
            derived_extents: empty_derived_extents(),
            forcing: self.forcing,
            const_arrays,
            declared: self.declared,
        }
    }
}

/// Evaluate one RHS call: through the tape when the scratch carries one
/// ([`RhsScratch::install_tape`]), otherwise through the per-cell oracle, the
/// reference the tape is checked against.
///
/// Every element of `dy` is written: a state no rule writes reads zero. The
/// caller need not clear it; the tape zeroes only the elements it does not
/// write.
pub(super) fn evaluate_rhs_with_scratch(
    call: &RhsCall,
    dy: &mut [f64],
    stats: &mut RhsStats,
    scratch: &mut RhsScratch,
) {
    match scratch.tape.as_mut() {
        Some(tape) => run_tape_call(tape, call, dy, stats),
        None => {
            dy.fill(0.0);
            evaluate_rhs_per_cell(call, dy, stats, scratch);
        }
    }
}

/// The per-cell oracle's right-hand side: every observed and every state rule
/// walked cell by cell.
fn evaluate_rhs_per_cell(
    call: &RhsCall,
    dy: &mut [f64],
    stats: &mut RhsStats,
    scratch: &mut RhsScratch,
) {
    let &RhsCall {
        rhs_rules,
        observed_rules,
        var_shapes,
        state,
        ..
    } = call;
    // (a) Refill the persistent per-variable state arrays in place from the
    //     flat state vector (no per-call allocation).
    refill_state_arrays(&mut scratch.state_arrays, var_shapes, state);

    // The model's const-array registry (§5.5.5) — cloned `Rc` so it outlives the
    // disjoint field borrows of `scratch` taken below.
    let const_scope = std::sync::Arc::clone(scratch.const_arrays());
    let const_arrays: &ConstArrayScope = &const_scope;

    // (b) Materialize observed algebraic rules (dependency-ordered at build time)
    //     into the reused observed container before the state derivatives read
    //     them. RETAIN the hoisted STATE-FREE/`t`-free observeds in place (seeded
    //     once by `set_static`, keyed in `static_keys`) — they are never cleared
    //     or re-cloned — then materialize (append, overwriting) only the
    //     `observed_rules` handed in: the varying subset on the `simulate` path,
    //     the full set on the debug/oracle path (where `static_keys` is empty, so
    //     `retain` degenerates to a full clear — byte-identical to the un-hoisted
    //     materialize). For a model with no observeds this leaves the container
    //     empty and allocates nothing.
    {
        let RhsScratch {
            state_arrays,
            observed_arrays,
            static_keys,
            ..
        } = &mut *scratch;
        observed_arrays.retain(|k, _| static_keys.contains(k));
        let env = call.env(state_arrays, const_arrays);
        materialize_observeds_pass(observed_arrays, observed_rules, &env, stats);
    }

    let observed_arrays = &scratch.observed_arrays;
    let env = call.env(&scratch.state_arrays, const_arrays);

    // (c) Evaluate each RHS rule and write into dy.
    for rule in rhs_rules {
        // The rule's working precision is its state's (esm-spec §11.3.1).
        let _rule_precision = rule.enter_precision(var_shapes);
        match rule {
            RhsRule::Scalar { slot, body } => {
                let mut ctx = env.ctx(observed_arrays);
                let v = eval(body, &mut ctx).as_scalar().unwrap_or(f64::NAN);
                dy[*slot] = v;
            }
            RhsRule::IndexedScalar { slot, body } => {
                let mut ctx = env.ctx(observed_arrays);
                let v = eval(body, &mut ctx).as_scalar().unwrap_or(f64::NAN);
                dy[*slot] = v;
            }
            RhsRule::ArrayLoop {
                var_name,
                output_idx_names,
                output_ranges,
                lhs_idx_exprs,
                body,
                contract_names,
                contract_dims,
                reduce,
                filter,
            } => {
                let vs = &var_shapes[var_name];
                let filter = filter.as_deref();

                stats.scalar_rules += 1;
                let mut ctx = env.ctx(observed_arrays);
                FaqCells::new(
                    output_idx_names,
                    output_ranges,
                    body,
                    contract_names,
                    contract_dims,
                    *reduce,
                    filter,
                    Some(var_name.as_str()),
                    &[],
                )
                .walk(&mut ctx, |_, v, ctx| {
                    // Address the destination through the LHS index
                    // expressions under the cell's binds, not by assuming a
                    // bare index.
                    let actual_multi: Vec<i64> = lhs_idx_exprs
                        .iter()
                        .map(|e| eval_simple_index(e, &ctx.loop_binds))
                        .collect();
                    let flat = multi_to_flat_col_major(&actual_multi, &vs.shape, &vs.origin);
                    dy[vs.flat_offset + flat] = v;
                });
            }
        }
    }
}

#[cfg(test)]
mod elementwise_array_observed_tests {
    //! WS4: a discretization-agnostic PDE leaf may be authored with readable
    //! intermediate ARRAY-shaped observeds (a level-set's `grad_mag`, `U_n`,
    //! `S_n`, …) rather than one inlined `D(state)` RHS. The array runtime
    //! evaluates each declared array observed WHOLESALE — `eval` looks every
    //! array-valued observed reference up in the observed-array map and
    //! broadcasts the elementwise ops over it — and `materialize_observeds_pass`
    //! builds them in dependency order, so the decomposition runs as authored
    //! with no special per-cell lift. This is the Rust mirror of the Julia
    //! `_fold_elementwise_array_observeds` pass; the test locks the behaviour so
    //! the same `.esm` keeps running identically in both toolkits.
    use super::*;
    use crate::simulate::{Alg, SolveOptions};
    use crate::types::EsmFile;
    use serde_json::json;

    fn typed(doc: serde_json::Value) -> EsmFile {
        serde_json::from_value(doc).expect("test document deserializes")
    }
    fn erk() -> SolveOptions {
        SolveOptions {
            alg: Alg::Erk,
            reltol: Some(1e-10),
            abstol: Some(1e-12),
            saveat: Some(vec![1.0]),
            ..Default::default()
        }
    }

    /// A spatial state psi[c] fed by a chain of ELEMENTWISE array observeds
    /// (`k[c]` const field, `a = psi + k`) with `D(psi,t) = -a`. From psi(0)=0
    /// the solution is psi(1) = -k·(1 - e⁻¹), DISTINCT per cell — so a correct
    /// result proves the observeds are evaluated element-wise (not collapsed to
    /// a scalar) and feed the state per cell.
    #[test]
    fn elementwise_array_observed_chain_drives_state_per_cell() {
        let doc = json!({
            "esm": "2.0.0",
            "metadata": {"name": "ew_obs"},
            "index_sets": {"c": {"kind": "interval", "size": 3}},
            "models": {"M": {
                "variables": {
                    "psi": {"type": "unknown", "units": "1", "shape": ["c"]},
                    "k": {"type": "unknown", "shape": ["c"]},
                    "a": {"type": "unknown", "shape": ["c"]}
                },
                "equations": [
                {"lhs": "k", "rhs": {"op": "const", "value": [1.0, 2.0, 3.0], "args": []}},
                {"lhs": "a", "rhs": {"op": "+", "args": ["psi", "k"]}},
                    {"lhs": {"op": "ic", "args": ["psi"]}, "rhs": 0.0},
                    {"lhs": {"op": "D", "args": ["psi"], "wrt": "t"}, "rhs": {"op": "-", "args": ["a"]}}
                ]
            }}
        });
        let file = typed(doc);
        let sol = crate::problem::esm_problem(
            &file,
            (0.0, 1.0),
            crate::problem::ProblemOptions {
                p: HashMap::new().clone(),
                u0: HashMap::new().clone(),
                rhs: crate::problem::Rhs::Always,
                ..Default::default()
            },
        )
        .and_then(|prob| crate::problem::solve(&prob, &erk()))
        .expect("simulates");
        let ti = sol.time.len() - 1;
        let cells = crate::inline_tests::state_cells(&sol.state_variable_names, "psi", "M");
        assert_eq!(cells.len(), 3);
        let psi: Vec<f64> = cells.iter().map(|(_, row)| sol.state[*row][ti]).collect();
        let one_minus_em1 = 1.0 - (-1.0f64).exp();
        for (i, k) in [1.0f64, 2.0, 3.0].iter().enumerate() {
            let expect = -k * one_minus_em1;
            assert!(
                (psi[i] - expect).abs() < 1e-6,
                "psi[{}](1) = {} != {}",
                i + 1,
                psi[i],
                expect
            );
        }
    }
}
