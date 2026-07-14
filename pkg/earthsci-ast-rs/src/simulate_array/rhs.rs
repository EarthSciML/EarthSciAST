//! Runtime RHS evaluation: the zero-allocation scratch ([`RhsScratch`]),
//! observed (algebraic) rule materialization, dependency ordering, and the
//! per-call rule driver [`evaluate_rhs_with_scratch`].

use super::*;
use ndarray::ArrayViewD;
use std::collections::HashSet;

// ============================================================================
// Zero-allocation RHS scratch (ess-mro).
//
// The vectorized stencil evaluator used to allocate `O(#AST-nodes)` arrays per
// RHS call (one owned `ArrayD` per `index`/combine/`makearray` node, a fresh
// per-variable state map, and a column-major scatter `Vec`). diffsol's RHS is
// in-place (`call_inplace` writes the solver-owned `dy`), so there is no
// allocation floor. `RhsScratch` carries the reusable buffers across diffsol
// steps so the steady-state vectorized RHS performs **zero** heap allocations:
//   * `state_arrays` — one persistent logical array per variable, refilled in
//     place from the flat state each call;
//   * `observed_arrays` — reused container for algebraic observeds;
//   * `pool` — a free-list of `f64` buffers recycling kernel intermediates.
// ============================================================================

/// Persistent per-call scratch for [`evaluate_rhs_with_scratch`] (ess-mro). One
/// is owned per RHS closure (the FD Jacobian closure carries its own), guarded
/// by a `RefCell` because diffsol's RHS is an `Fn`, not `FnMut`.
pub struct RhsScratch {
    /// Per-variable state arrays, logical row-major over each variable's shape,
    /// refilled in place from the flat state slice each call.
    state_arrays: ArrMap,
    /// Observed (algebraic) arrays; the container is reused across calls.
    observed_arrays: ArrMap,
    /// Recycled `f64` buffers for vectorized kernel intermediates.
    pool: Pool,
    /// Names of the hoisted STATE-FREE / `t`-free observeds (ess: static-observed
    /// hoist). Their arrays are seeded into `observed_arrays` ONCE by
    /// [`Self::set_static`] and then RETAINED in place across every RHS eval
    /// (never cleared, never re-cloned), so a build-once product — the
    /// conservative-regrid geometry (`intersect_polygon` over the src×tgt cell
    /// rings, incl. the large `A_ij`/`W_ij` weight matrices), the regridded
    /// terrain + slopes, the Rothermel coefficients derived from the CONST
    /// forcing — is materialized once, not recomputed on every step. The
    /// `observed_rules` the RHS is handed is correspondingly the *varying*
    /// subset. Empty for a model with no such observeds (the debug/oracle entry
    /// points leave it empty and pass the full rule set, so a plain `clear` +
    /// full materialize is recovered — byte-identical to the un-hoisted path).
    static_keys: HashSet<String>,
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
            pool: Pool::default(),
            static_keys: HashSet::new(),
        }
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

/// Scatter a logical array's values into the flat `dy` block at `offset`, in
/// column-major order (the state-vector convention), in place — replacing the
/// old `arrayd_to_col_major` + `copy_from_slice` (which allocated a `Vec` per
/// rule). Addresses elements explicitly, so it is layout-agnostic.
/// Scatter a logical array into a *sub-block* of a variable's flat `dy` block,
/// in column-major order (the state-vector layout). `dest_lo[d]` is the 0-based
/// start of the sub-block along axis `d` within the variable's box (extent
/// `vs.shape`); the array's own extent must fit (`dest_lo[d] + arr.shape()[d] ≤
/// vs.shape[d]`, guaranteed by [`subblock_dest`]). This is the placement for an
/// affine-shifted LHS `D(u[i+c]) = …`; the bare-index method-of-lines case is
/// `dest_lo = 0…` with `arr` spanning the whole variable box.
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
        AlgebraicRule::Scalar { var, .. } | AlgebraicRule::ArrayLoop { var, .. } => var,
    }
}

/// The defining body expression of an observed algebraic rule.
pub(super) fn observed_rule_body(rule: &AlgebraicRule) -> &Expr {
    match rule {
        AlgebraicRule::Scalar { body, .. } | AlgebraicRule::ArrayLoop { body, .. } => body,
    }
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
/// original order; any rule left in a dependency cycle is appended in original
/// order so the build still proceeds (the evaluator then surfaces a clear
/// unresolved read rather than the driver hanging). Mirrors the Python
/// `simulation._order_observed_equations`.
pub(super) fn dependency_order_observed(rules: Vec<AlgebraicRule>) -> Vec<AlgebraicRule> {
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
            break; // a cycle — append the rest in original order below
        }
    }
    order.extend(remaining);

    // Reassemble in the computed order, moving each rule out exactly once.
    let mut slots: Vec<Option<AlgebraicRule>> = rules.into_iter().map(Some).collect();
    order
        .into_iter()
        .map(|i| slots[i].take().expect("each index visited once"))
        .collect()
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

/// Evaluate the observed algebraic rules (already dependency-ordered at build
/// time) at the given state/time into a name→array map, registering any
/// FAQ-materialized derived ring under its producer id in `derived_rings`. An
/// observed whose body yields an array (a `const` polygon, the clip ring) is
/// stored as an array so downstream `index(...)` reads address it; a scalar body
/// (an `area` FAQ) is a 0-D array. Shared by the RHS driver ([`evaluate_rhs`])
/// and the output-time observed exposure ([`ArrayCompiled::simulate`]) so both
/// see identical observed values.
#[allow(clippy::too_many_arguments)]
pub(super) fn materialize_observeds(
    observed_rules: &[AlgebraicRule],
    state_arrays: &ArrMap,
    params: &[f64],
    param_names: &[String],
    t: f64,
    derived_rings: &RefCell<HashMap<String, ArrayD<f64>>>,
    forcing: &RefCell<HashMap<String, ArrayD<f64>>>,
) -> ArrMap {
    let mut observed_arrays: ArrMap = ArrMap::default();
    materialize_observeds_into(
        &mut observed_arrays,
        observed_rules,
        state_arrays,
        params,
        param_names,
        t,
        derived_rings,
        forcing,
    );
    observed_arrays
}

/// Like [`materialize_observeds`] but writes into a reused container (ess-mro),
/// so the observed map is not reallocated each RHS call. The container is
/// cleared (capacity retained) then repopulated; for models with no observeds
/// — the vectorized PDE path — it stays empty and nothing is allocated. The
/// observed *value* arrays themselves are still materialized fresh (only models
/// that actually carry algebraic observeds pay that, and they are outside the
/// zero-allocation stencil path being verified).
pub(super) fn materialize_observeds_into(
    dst: &mut ArrMap,
    observed_rules: &[AlgebraicRule],
    state_arrays: &ArrMap,
    params: &[f64],
    param_names: &[String],
    t: f64,
    derived_rings: &RefCell<HashMap<String, ArrayD<f64>>>,
    forcing: &RefCell<HashMap<String, ArrayD<f64>>>,
) {
    dst.clear();
    materialize_observeds_append(
        dst,
        observed_rules,
        state_arrays,
        params,
        param_names,
        t,
        derived_rings,
        forcing,
        // Build/setup materialization: use the vectorized overlay (bit-identical
        // to the oracle, and this runs once, off the per-step hot path).
        false,
        &mut RhsStats::default(),
    );
}

/// Like [`materialize_observeds_into`] but does NOT clear `dst` first — the
/// rules are evaluated and their outputs inserted on top of whatever is already
/// there. This is what lets the RHS seed the hoisted static observeds (ess:
/// static-observed hoist) into `dst` and then materialize only the *varying*
/// rules over them, without recomputing the statics every step. A varying rule
/// may reference an already-seeded static observed by name (they are read from
/// `dst`), so the seed must be in place before this runs.
#[allow(clippy::too_many_arguments)]
pub(super) fn materialize_observeds_append(
    dst: &mut ArrMap,
    observed_rules: &[AlgebraicRule],
    state_arrays: &ArrMap,
    params: &[f64],
    param_names: &[String],
    t: f64,
    derived_rings: &RefCell<HashMap<String, ArrayD<f64>>>,
    forcing: &RefCell<HashMap<String, ArrayD<f64>>>,
    // When true, evaluate array observeds via the per-cell oracle (the
    // correctness reference), skipping the vectorized whole-array fast path.
    // Production passes `false`; the equivalence test passes `true` to obtain
    // the reference values — mirroring the `force_scalar` contract the RHS-rule
    // driver already honours (see [`RhsStats`]).
    force_scalar: bool,
    // Records how each array observed was materialized (vectorized vs per-cell),
    // mirroring the `vectorized_rules`/`scalar_rules` split for state rules.
    stats: &mut RhsStats,
) {
    for rule in observed_rules {
        match rule {
            AlgebraicRule::Scalar { var, body } => {
                let mut ctx = EvalCtx {
                    state_arrays,
                    observed_arrays: &*dst,
                    params,
                    param_names,
                    loop_binds: IdxMap::default(),
                    t,
                    derived_rings,
                    forcing,
                };
                let arr = match eval(body, &mut ctx) {
                    Value::Array(a) => a,
                    Value::Scalar(s) => ArrayD::from_elem(IxDyn(&[]), s),
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

                // ---- Vectorized (whole-array) fast path --------------------
                // A pure-map observed (output_idx over `ranges`, no contraction
                // or filter) is structurally a `RhsRule::ArrayLoop` with no
                // contracted index — a whole-array map. Evaluate it through the
                // same verified vectorized overlay (`try_eval_arrayop_vectorized`
                // → `eval_vec`) the state-derivative rules use, instead of
                // walking the body once per grid cell. This is the dominant cost
                // for models with time/space-varying observeds (a coupled
                // behaviour stack re-materialized every RHS step); the level-set
                // stencil already vectorized, but observeds never had this path.
                //
                // Guarded to 1-origin ranges so the produced `[lo, shape]` box
                // equals the padded `[1, hi]` array the per-cell path below
                // materializes (an observed array is 1-based over its full shape,
                // so this holds in practice; a non-unit origin falls through to
                // the oracle). Bit-identical to the per-cell result by the same
                // overlay-equivalence argument that covers the RHS rules
                // (downstream reads are logical `index`/`lookup`, so the pooled
                // row-major storage is immaterial).
                if !force_scalar
                    && !output_ranges.is_empty()
                    && output_ranges.iter().all(|(lo, _)| *lo == 1)
                    && !padded_shape.contains(&0)
                {
                    let materialized = {
                        let ctx = EvalCtx {
                            state_arrays,
                            observed_arrays: &*dst,
                            params,
                            param_names,
                            loop_binds: IdxMap::default(),
                            t,
                            derived_rings,
                            forcing,
                        };
                        let mut pool = Pool::default();
                        try_eval_arrayop_vectorized(
                            output_idx_names,
                            output_ranges,
                            body,
                            &[],
                            &[],
                            ReduceKind::Sum,
                            None,
                            &ctx,
                            &mut pool,
                        )
                        .map(|(val, _ops)| {
                            let arr = val
                                .view()
                                .expect("vectorized observed value has a view")
                                .to_owned();
                            val.release(&mut pool);
                            arr
                        })
                    };
                    if let Some(arr) = materialized {
                        dst.insert(var.clone(), arr);
                        stats.obs_vectorized_rules += 1;
                        continue;
                    }
                }

                // ---- Per-cell oracle (fallback) ----------------------------
                stats.obs_scalar_rules += 1;
                let padded_origin: Vec<i64> = vec![1i64; padded_shape.len()];
                let total = padded_shape.iter().copied().product::<usize>().max(1);
                let mut buf = vec![0.0f64; total];
                {
                    // One eval context for the whole cell loop (scoped so its
                    // read borrow of `dst` releases before the write below). The
                    // output index names are the same every cell, so `set_bind`
                    // rebinds in place — no per-cell `IdxMap` alloc or key clone.
                    let mut ctx = EvalCtx {
                        state_arrays,
                        observed_arrays: &*dst,
                        params,
                        param_names,
                        loop_binds: IdxMap::default(),
                        t,
                        derived_rings,
                        forcing,
                    };
                    let mut tuples = CartesianTuples::new(output_ranges);
                    while let Some(tuple) = tuples.next() {
                        for (name, val) in output_idx_names.iter().zip(tuple.iter()) {
                            set_bind(&mut ctx.loop_binds, name, *val);
                        }
                        let v = eval(body, &mut ctx).as_scalar().unwrap_or(f64::NAN);
                        let flat = multi_to_flat_col_major(tuple, &padded_shape, &padded_origin);
                        if flat < buf.len() {
                            buf[flat] = v;
                        }
                    }
                }
                let arr = col_major_to_arrayd(&buf, &padded_shape);
                dst.insert(var.clone(), arr);
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn evaluate_rhs_with_scratch(
    rhs_rules: &[RhsRule],
    observed_rules: &[AlgebraicRule],
    var_shapes: &IndexMap<String, VarShape>,
    param_names: &[String],
    state: &[f64],
    params: &[f64],
    // External refreshable forcing-array channel (PR-1, ess-14f.7): the
    // model-lifetime buffer a discrete-cadence driver refreshes between
    // segments. Borrowed (not owned by the per-call scratch) so the same buffer
    // is read across every RHS call within a segment. Empty ⇒ no behaviour
    // change vs. the scalar-`p` path.
    forcing: &RefCell<HashMap<String, ArrayD<f64>>>,
    t: f64,
    dy: &mut [f64],
    // When true, skip the vectorized fast path and evaluate every array-op
    // derivative via the per-cell oracle. Production always passes `false`
    // (vectorized); the equivalence test passes `true` to obtain the
    // reference values. See [`RhsStats`].
    force_scalar: bool,
    stats: &mut RhsStats,
    // Reused buffers (ess-mro): persistent per-variable state arrays + observed
    // container + kernel buffer pool, so the steady-state vectorized RHS does
    // not allocate.
    scratch: &mut RhsScratch,
) {
    // (a) Refill the persistent per-variable state arrays in place from the
    //     flat state vector (no per-call allocation).
    refill_state_arrays(&mut scratch.state_arrays, var_shapes, state);

    // FAQ-materialized derived rings (RFC §8.1), keyed by producer node id. An
    // `intersect_polygon` clip self-registers its closed overlap ring here as it
    // evaluates (see `eval_intersect_polygon`); a downstream `aggregate` over a
    // `kind:"derived"` index set then sizes its contraction from the ring's
    // vertex count. Shared (interior-mutable) across the observed materialization
    // and the RHS rules so a ring registered while `clip` materializes is visible
    // both when `area` runs and in any state derivative that reads a derived set.
    // Empty (no allocation) for models without geometry, i.e. the stencil path —
    // and, on the hoisted `simulate` path, for the *varying* observeds too: any
    // geometry op is state-free (a build-once regrid), so it is a static observed
    // materialized once at setup with its rings produced-and-consumed there, and
    // no varying rule reads a static ring.
    let derived_rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());

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
        materialize_observeds_append(
            observed_arrays,
            observed_rules,
            state_arrays,
            params,
            param_names,
            t,
            &derived_rings,
            forcing,
            // Honour the oracle contract: `force_scalar` runs observeds per-cell
            // too, so the reference trajectory is fully un-vectorized.
            force_scalar,
            stats,
        );
    }

    // Emit observed shapes we need for downstream variable lookups.

    // Split the scratch into disjoint field borrows: the state/observed arrays
    // are read (shared) while the buffer pool is checked out (exclusive).
    let state_arrays = &scratch.state_arrays;
    let observed_arrays = &scratch.observed_arrays;
    let pool = &mut scratch.pool;

    // (c) Evaluate each RHS rule and write into dy.
    for rule in rhs_rules {
        match rule {
            RhsRule::Scalar { slot, body } => {
                let mut ctx = EvalCtx {
                    state_arrays,
                    observed_arrays,
                    params,
                    param_names,
                    loop_binds: IdxMap::default(),
                    t,
                    derived_rings: &derived_rings,
                    forcing,
                };
                let v = eval(body, &mut ctx).as_scalar().unwrap_or(f64::NAN);
                dy[*slot] = v;
            }
            RhsRule::IndexedScalar { slot, body } => {
                let mut ctx = EvalCtx {
                    state_arrays,
                    observed_arrays,
                    params,
                    param_names,
                    loop_binds: IdxMap::default(),
                    t,
                    derived_rings: &derived_rings,
                    forcing,
                };
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

                // ---- Vectorized (whole-array) fast path (ess-bdm, ess-p9s) --
                // A discretized spatial derivative whose LHS addresses the state
                // by a constant per-axis shift of the output indices
                // (`D(u[i+c])`, `c` constant; the bare-index method-of-lines
                // case is `c = 0`) is evaluated as whole-array kernels:
                //   * shifted slices for affine-ghost neighbours `index(u,i±k)`,
                //   * cyclic rolls for periodic-wrap neighbours,
                //   * a small static fold over einsum contraction indices,
                //   * region sub-range writes for boundary makearrays,
                //   * broadcast arithmetic for coefficients,
                // then the dy sub-block is scattered in place. No per-element
                // scalar loop walks the body, and (ess-mro) no heap allocation
                // occurs: intermediates come from `pool`. A static `filter` is
                // carried by masking each term with the reduction identity
                // (`try_eval_arrayop_vectorized`); a ragged/derived-bound filter
                // (dynamic contraction window) bails to the per-cell oracle.
                let lhs_shifts = lhs_constant_shifts(lhs_idx_exprs, output_idx_names);
                if !force_scalar {
                    if let Some(dest_lo) = lhs_shifts
                        .as_ref()
                        .and_then(|shifts| subblock_dest(vs, output_ranges, shifts))
                    {
                        let ctx = EvalCtx {
                            state_arrays,
                            observed_arrays,
                            params,
                            param_names,
                            loop_binds: IdxMap::default(),
                            t,
                            derived_rings: &derived_rings,
                            forcing,
                        };
                        if let Some((val, ops)) = try_eval_arrayop_vectorized(
                            output_idx_names,
                            output_ranges,
                            body,
                            contract_names,
                            contract_dims,
                            *reduce,
                            filter,
                            &ctx,
                            pool,
                        ) {
                            let total = vs.shape.iter().copied().product::<usize>().max(1);
                            if vs.flat_offset + total <= dy.len() {
                                if let Some(view) = val.view() {
                                    scatter_col_major_offset(view, dy, vs, &dest_lo);
                                }
                                val.release(pool);
                                stats.kernel_ops += ops;
                                stats.vectorized_rules += 1;
                                continue;
                            }
                            val.release(pool);
                        }
                    }
                }

                // ---- Per-cell oracle (fallback / forced reference) ---------
                stats.scalar_rules += 1;
                // Hoist the eval context and the static contraction bounds out of
                // the per-cell loop: the bound key set (output_idx + contract
                // names) is identical every cell, so `set_bind` rebinds in place
                // and we avoid both a fresh `IdxMap` allocation and the per-cell
                // range re-derivation on every output tuple.
                let static_ranges = static_contract_ranges(contract_dims);
                // Origin of the output box — the alignment an ARRAY-valued §5.3
                // `filter` is resolved against, so a per-cell mask means the same
                // thing here as it does on the vectorized path.
                let output_origin: Vec<i64> = output_ranges.iter().map(|(lo, _)| *lo).collect();
                let mut ctx = EvalCtx {
                    state_arrays,
                    observed_arrays,
                    params,
                    param_names,
                    loop_binds: IdxMap::default(),
                    t,
                    derived_rings: &derived_rings,
                    forcing,
                };
                let mut tuples = CartesianTuples::new(output_ranges);
                while let Some(tuple) = tuples.next() {
                    for (name, val) in output_idx_names.iter().zip(tuple.iter()) {
                        set_bind(&mut ctx.loop_binds, name, *val);
                    }
                    // Generalized einsum: contracted indices (incl. ragged
                    // per-cell dynamic bounds) are unrolled and ⊕-combined here.
                    let v = reduce_contraction(
                        contract_names,
                        contract_dims,
                        static_ranges.as_deref(),
                        body,
                        *reduce,
                        filter,
                        Some(&CellBox {
                            names: output_idx_names,
                            origin: &output_origin,
                        }),
                        &mut ctx,
                    );
                    let actual_multi: Vec<i64> = lhs_idx_exprs
                        .iter()
                        .map(|e| eval_simple_index(e, &ctx.loop_binds))
                        .collect();
                    let flat = multi_to_flat_col_major(&actual_multi, &vs.shape, &vs.origin);
                    dy[vs.flat_offset + flat] = v;
                }
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
    //! broadcasts the elementwise ops over it — and `materialize_observeds`
    //! builds them in dependency order, so the decomposition runs as authored
    //! with no special per-cell lift. This is the Rust mirror of the Julia
    //! `_fold_elementwise_array_observeds` pass; the test locks the behaviour so
    //! the same `.esm` keeps running identically in both toolkits.
    use super::*;
    use crate::simulate::{SimulateOptions, SolverChoice, simulate};
    use crate::types::EsmFile;
    use serde_json::json;

    fn typed(doc: serde_json::Value) -> EsmFile {
        serde_json::from_value(doc).expect("test document deserializes")
    }
    fn erk() -> SimulateOptions {
        SimulateOptions {
            solver: SolverChoice::Erk,
            reltol: 1e-10,
            abstol: 1e-12,
            output_times: Some(vec![1.0]),
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
            "esm": "0.8.0",
            "metadata": {"name": "ew_obs"},
            "index_sets": {"c": {"kind": "interval", "size": 3}},
            "models": {"M": {
                "variables": {
                    "psi": {"type": "state", "units": "1", "shape": ["c"]},
                    "k": {"type": "observed", "shape": ["c"],
                          "expression": {"op": "const", "value": [1.0, 2.0, 3.0], "args": []}},
                    "a": {"type": "observed", "shape": ["c"],
                          "expression": {"op": "+", "args": ["psi", "k"]}}
                },
                "equations": [
                    {"lhs": {"op": "ic", "args": ["psi"]}, "rhs": 0.0},
                    {"lhs": {"op": "D", "args": ["psi"], "wrt": "t"}, "rhs": {"op": "-", "args": ["a"]}}
                ]
            }}
        });
        let file = typed(doc);
        let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &HashMap::new(), &erk())
            .expect("simulates");
        let ti = sol.time.len() - 1;
        let cells = crate::pde_inline_tests::state_cells(&sol.state_variable_names, "psi", "M");
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
