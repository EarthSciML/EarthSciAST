//! Step 3b: the fast tape executor — the production RHS hot path.
//!
//! Executes a [`TapeProgram`] over a preallocated `f64` slab with **zero
//! per-call heap allocation** (after warm-up), **no hashing on the kernel
//! path**, and **zero recursion**. Array kernels are strided loops over raw
//! `(pointer, shape, strides)` triples dispatched through the SAME
//! `BinCode`/`UnCode` kernel fn-pointer tables the vectorized overlay uses,
//! so every element is computed by the same kernel the interpreter would have
//! called — bit identity is structural, not coincidental:
//!
//! * elementwise instructions apply a pure per-element kernel, so iteration
//!   order cannot change any output bit;
//! * gathers execute the precompiled segment-copy plans (pure data movement
//!   over a `+0.0` ghost fill, exactly `eval_vec_index`'s copy phase);
//! * contractions were already unrolled by the lowering into the overlay's
//!   own fold order;
//! * `JmpIfZero` short-circuits with the reference executor's pending-skip
//!   discipline, so an untaken branch never executes.
//!
//! **State access**: a state variable's flat block is column-major over its
//! logical shape, i.e. it *is* a strided view with strides
//! `[1, s0, s0·s1, …]`. Instructions read the flat state vector directly
//! through those strides — no per-call refill or copy. The legacy
//! `state_arrays` map is refilled only when the program carries fallback
//! rules (which evaluate through the interpreter's `EvalCtx`).
//!
//! **Scalar slots** live in the slab like array slots (their storages are
//! 1-element buckets assigned by the same coloring); a scalar read is one
//! indexed load either way, and keeping one address space keeps the executor
//! uniform.
//!
//! **Sections/invalidation**: the CONST and SEGMENT sections run once per
//! scratch (the driver builds a fresh scratch per integration segment — the
//! same cadence as the static-observed hoist), guarded by a
//! `bind_params`-style parameter-generation hash mirroring `cse.rs`: a caller
//! that reuses one scratch across a parameter change (a sweep through
//! `debug_eval_rhs_into`) re-primes instead of being served stale CONST
//! values. Full epoch machinery is Step 4.

use super::super::*;
use super::ir::*;
use ndarray::ArrayD;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

// ---------------------------------------------------------------------------
// Environment switches (read once and cached, matching ESS_VEC_DISABLE /
// ESS_CSE_DISABLE).
// ---------------------------------------------------------------------------

/// `ESS_TAPE_DISABLE=1`: wholesale kill switch — `simulate` never builds or
/// installs a tape and every RHS call runs the legacy interpreter path,
/// byte-identical to the pre-tape driver.
pub(crate) fn tape_disabled() -> bool {
    use std::sync::OnceLock;
    static OFF: OnceLock<bool> = OnceLock::new();
    *OFF.get_or_init(|| {
        std::env::var("ESS_TAPE_DISABLE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false)
    })
}

/// `ESS_TAPE_CHECK=N`: for the first N calls of each taped scratch, run BOTH
/// the legacy interpreter and the tape and assert bitwise-equal `dy` (then
/// drop the check buffer). 0 (the default) checks nothing.
pub(crate) fn tape_check_calls() -> u64 {
    use std::sync::OnceLock;
    static N: OnceLock<u64> = OnceLock::new();
    *N.get_or_init(|| {
        std::env::var("ESS_TAPE_CHECK")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0)
    })
}

// ---------------------------------------------------------------------------
// Executor state.
// ---------------------------------------------------------------------------

/// Per-scratch executor state: the slab and everything preallocated so a
/// steady-state call performs zero heap allocation.
pub(crate) struct TapeExec {
    /// Flat `f64` slab backing every storage bucket.
    slab: Vec<f64>,
    /// Per-slot flat offset into the slab (`usize::MAX` for never-defined
    /// slots, which no reachable instruction references).
    slot_off: Vec<usize>,
    /// Runtime observed map: export target arrays are PREALLOCATED here (an
    /// `Export` is a bounds-checked memcpy into an existing entry, no
    /// allocation); fallback observed rules insert their own outputs.
    pub(crate) obs: ArrMap,
    /// Pending `(resume_pc, skip)` records for taken `JmpIfZero` branches
    /// (the reference executor's discipline). Capacity preallocated.
    pending: Vec<(u32, u32)>,
    /// Row-major mirror of the flat state vector, refilled once per call
    /// (each variable's column-major block transposed in place at the SAME
    /// flat offset). Gathers and elementwise reads of state then run over
    /// contiguous memory instead of stride-684 walks. Pure data movement, so
    /// bit-identical to reading the strided view directly.
    state_rm: Vec<f64>,
    /// Per gather plan: `true` when its per-axis segments tile the whole
    /// output box, so the ghost zero-fill can be skipped (every element is
    /// overwritten by a segment copy).
    plan_full: Vec<bool>,
    /// CONST + SEGMENT sections have run for this scratch.
    primed: bool,
    /// Parameter-vector bit-hash the priming ran under (mirrors
    /// `CseRt::bind_params`).
    pgen: u64,
    /// Rule counts, cached off the program for the per-call stats.
    pub(crate) n_taped: usize,
    pub(crate) n_fallback: usize,
}

impl TapeExec {
    pub(crate) fn new(prog: &TapeProgram) -> Self {
        let slab = vec![0.0f64; prog.slab.total_elems];
        let slot_off: Vec<usize> = prog
            .slots
            .iter()
            .map(|s| {
                if s.storage == u32::MAX {
                    usize::MAX
                } else {
                    prog.slab.storages[s.storage as usize].offset
                }
            })
            .collect();
        let mut obs: ArrMap = ArrMap::default();
        for (name, slot) in &prog.exports {
            let desc = &prog.slots[*slot as usize];
            let shape: Vec<usize> = if desc.scalar {
                Vec::new()
            } else {
                desc.shape.to_vec()
            };
            obs.insert(name.clone(), ArrayD::<f64>::zeros(IxDyn(&shape)));
        }
        let n_fallback = prog
            .rules
            .iter()
            .filter(|r| matches!(r.status, RuleStatus::Fallback(_)))
            .count();
        let n_state: usize = prog
            .state_vars
            .iter()
            .map(|sv| sv.flat_offset + sv.shape.iter().product::<usize>().max(1))
            .max()
            .unwrap_or(0);
        let plan_full = prog
            .plans
            .iter()
            .map(|plan| {
                plan.shape.iter().enumerate().all(|(d, &extent)| {
                    let mut segs: Vec<(usize, usize)> =
                        plan.segs[d].iter().map(|&(o, l, _)| (o, l)).collect();
                    segs.sort_unstable();
                    let mut next = 0usize;
                    for (o, l) in segs {
                        if o != next {
                            return false;
                        }
                        next = o + l;
                    }
                    next == extent
                })
            })
            .collect();
        TapeExec {
            slab,
            slot_off,
            obs,
            pending: Vec::with_capacity(16),
            state_rm: vec![0.0f64; n_state],
            plan_full,
            primed: false,
            pgen: 0,
            n_taped: prog.rules.len() - n_fallback,
            n_fallback,
        }
    }
}

/// The compiled-tape context a [`super::super::RhsScratch`] carries. `None`
/// on a scratch means "legacy interpreter path".
pub(in crate::simulate_array) struct TapeCtx {
    pub(crate) prog: Rc<TapeProgram>,
    /// The FULL dependency-ordered observed rule list the program's
    /// `RuleKind::Observed(i)` indices resolve against (the per-call
    /// `observed_rules` argument is the driver's varying subset).
    pub(in crate::simulate_array) observed_rules: Rc<Vec<AlgebraicRule>>,
    pub(crate) exec: TapeExec,
    /// Remaining `ESS_TAPE_CHECK` dual-path calls.
    pub(crate) check_remaining: u64,
    /// Legacy-arm `dy` buffer for check mode (dropped when the check ends).
    pub(crate) check_buf: Vec<f64>,
}

impl TapeCtx {
    pub(in crate::simulate_array) fn new(prog: Rc<TapeProgram>, observed_rules: Rc<Vec<AlgebraicRule>>) -> Self {
        let exec = TapeExec::new(&prog);
        TapeCtx {
            prog,
            observed_rules,
            exec,
            check_remaining: tape_check_calls(),
            check_buf: Vec::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// The per-call entry.
// ---------------------------------------------------------------------------

/// Everything immutable an instruction may consult, bundled so the
/// interpreter loop can split-borrow the mutable executor pieces beside it.
struct Env<'a> {
    prog: &'a TapeProgram,
    observed_rules: &'a [AlgebraicRule],
    rhs_rules: &'a [RhsRule],
    var_shapes: &'a IndexMap<String, VarShape>,
    param_names: &'a [String],
    state_arrays: &'a ArrMap,
    forcing: &'a RefCell<HashMap<String, ArrayD<f64>>>,
    derived_rings: &'a RefCell<HashMap<String, ArrayD<f64>>>,
    state: &'a [f64],
    /// Row-major per-variable mirror of `state` (see `TapeExec::state_rm`).
    state_rm: &'a [f64],
    params: &'a [f64],
    t: f64,
}

/// `bind_params`-style parameter-vector generation hash (bit-exact).
fn params_gen(params: &[f64]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = rustc_hash::FxHasher::default();
    params.len().hash(&mut h);
    for p in params {
        p.to_bits().hash(&mut h);
    }
    // Avoid the (astronomically unlikely) collision with the `pgen: 0,
    // primed: false` initial state mattering: primed gates the first run.
    h.finish()
}

/// Execute one RHS call through the tape: prime the CONST + SEGMENT sections
/// if needed (first call of the scratch, or a changed parameter vector), then
/// run the CONTINUOUS section. Writes `dy` (caller-zeroed) and bumps `stats`.
#[allow(clippy::too_many_arguments)]
pub(in crate::simulate_array) fn run_tape_call(
    ctx: &mut TapeCtx,
    rhs_rules: &[RhsRule],
    var_shapes: &IndexMap<String, VarShape>,
    param_names: &[String],
    state_arrays: &ArrMap,
    forcing: &RefCell<HashMap<String, ArrayD<f64>>>,
    state: &[f64],
    params: &[f64],
    t: f64,
    dy: &mut [f64],
    stats: &mut RhsStats,
) {
    let prog = &*ctx.prog;
    let exec = &mut ctx.exec;
    // Refill the row-major state mirror: one strided pass per variable block
    // (column-major flat -> row-major at the same offset).
    for sv in &prog.state_vars {
        if sv.shape.is_empty() {
            exec.state_rm[sv.flat_offset] = state[sv.flat_offset];
        } else {
            let rm = rm_strides(&sv.shape);
            let cm = cm_strides(&sv.shape);
            unsafe {
                copy_strided(
                    exec.state_rm.as_mut_ptr().add(sv.flat_offset),
                    &rm,
                    state.as_ptr().add(sv.flat_offset),
                    &cm,
                    &sv.shape,
                );
            }
        }
    }
    // Intra-call FAQ ring registry for fallback rules (`HashMap::new` does not
    // allocate until first insertion, so a fully-taped call touches no heap).
    let derived_rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    let state_rm = std::mem::take(&mut exec.state_rm);
    let env = Env {
        prog,
        observed_rules: &ctx.observed_rules,
        rhs_rules,
        var_shapes,
        param_names,
        state_arrays,
        forcing,
        derived_rings: &derived_rings,
        state,
        state_rm: &state_rm,
        params,
        t,
    };

    let g = params_gen(params);
    let prime_end = (prog.n_const + prog.n_segment) as usize;
    if !exec.primed || exec.pgen != g {
        exec.primed = true;
        exec.pgen = g;
        run_range(&env, 0..prime_end, exec, dy, stats);
    }
    run_range(&env, prime_end..prog.instrs.len(), exec, dy, stats);
    drop(env);
    exec.state_rm = state_rm;

    stats.taped_rules += exec.n_taped;
    stats.fallback_rules += exec.n_fallback;
}

// ---------------------------------------------------------------------------
// Operand resolution.
// ---------------------------------------------------------------------------

/// Row-major strides (elements) of `shape` — the slab slot layout.
fn rm_strides(shape: &[usize]) -> DimI {
    let n = shape.len();
    let mut st = DimI::from_elem(0, n);
    let mut acc = 1i64;
    for d in (0..n).rev() {
        st[d] = acc;
        acc *= shape[d] as i64;
    }
    st
}

/// Column-major strides (elements) of `shape` — the flat state-vector layout
/// of each variable block.
fn cm_strides(shape: &[usize]) -> DimI {
    let n = shape.len();
    let mut st = DimI::from_elem(0, n);
    let mut acc = 1i64;
    for d in 0..n {
        st[d] = acc;
        acc *= shape[d] as i64;
    }
    st
}

/// A resolved operand for the elementwise kernels: a scalar value, or an
/// array view whose strides are aligned to the CONSUMER's logical shape.
enum Rv {
    S(f64),
    V { ptr: *const f64, strides: DimI },
}

/// A resolved gather/load source: pointer + its OWN shape and strides.
struct SrcView {
    ptr: *const f64,
    shape: DimU,
    strides: DimI,
}

/// Resolve an operand to a scalar. Panics on an array operand — the lowering
/// only feeds scalars where a scalar is consumed.
fn resolve_scalar(
    op: &Operand,
    env: &Env,
    slab_ptr: *const f64,
    slot_off: &[usize],
    obs: &ArrMap,
) -> f64 {
    match op {
        Operand::Lit(v) => *v,
        Operand::Param(p) => env.params[*p as usize],
        Operand::Time => env.t,
        Operand::Slot(s) => {
            debug_assert!(env.prog.slots[*s as usize].scalar, "scalar read of array slot");
            unsafe { *slab_ptr.add(slot_off[*s as usize]) }
        }
        Operand::State(ix) => {
            let sv = &env.prog.state_vars[*ix as usize];
            debug_assert!(sv.shape.is_empty(), "scalar read of array state");
            env.state[sv.flat_offset]
        }
        Operand::Obs(ix) => {
            let name = &env.prog.obs_reads[*ix as usize];
            let a = obs
                .get(name)
                .unwrap_or_else(|| panic!("observed `{name}` not materialized before read"));
            assert_eq!(a.ndim(), 0, "scalar read of array observed `{name}`");
            a[IxDyn(&[])]
        }
    }
}

/// Resolve an operand against a consumer box `shape` (the out slot's shape).
fn resolve_rv(
    op: &Operand,
    shape: &[usize],
    env: &Env,
    slab_ptr: *const f64,
    slot_off: &[usize],
    obs: &ArrMap,
) -> Rv {
    match op {
        Operand::Lit(v) => Rv::S(*v),
        Operand::Param(p) => Rv::S(env.params[*p as usize]),
        Operand::Time => Rv::S(env.t),
        Operand::Slot(s) => {
            let desc = &env.prog.slots[*s as usize];
            let off = slot_off[*s as usize];
            if desc.scalar {
                Rv::S(unsafe { *slab_ptr.add(off) })
            } else {
                debug_assert_eq!(&desc.shape[..], shape, "slot box mismatch");
                Rv::V {
                    ptr: unsafe { slab_ptr.add(off) },
                    strides: rm_strides(shape),
                }
            }
        }
        Operand::State(ix) => {
            let sv = &env.prog.state_vars[*ix as usize];
            if sv.shape.is_empty() {
                Rv::S(env.state[sv.flat_offset])
            } else {
                debug_assert_eq!(&sv.shape[..], shape, "state box mismatch");
                Rv::V {
                    ptr: unsafe { env.state_rm.as_ptr().add(sv.flat_offset) },
                    strides: rm_strides(&sv.shape),
                }
            }
        }
        Operand::Obs(ix) => {
            let name = &env.prog.obs_reads[*ix as usize];
            let a = obs
                .get(name)
                .unwrap_or_else(|| panic!("observed `{name}` not materialized before read"));
            if a.ndim() == 0 {
                Rv::S(a[IxDyn(&[])])
            } else {
                assert_eq!(a.shape(), shape, "observed `{name}` box mismatch");
                Rv::V {
                    ptr: a.as_ptr(),
                    strides: a.strides().iter().map(|&s| s as i64).collect(),
                }
            }
        }
    }
}

/// Resolve a gather/load-elem source to its own full view.
fn resolve_src(
    src: &SrcRef,
    env: &Env,
    slab_ptr: *const f64,
    slot_off: &[usize],
    obs: &ArrMap,
) -> SrcView {
    match src {
        SrcRef::Slot(s) => {
            let desc = &env.prog.slots[*s as usize];
            SrcView {
                ptr: unsafe { slab_ptr.add(slot_off[*s as usize]) },
                shape: desc.shape.clone(),
                strides: rm_strides(&desc.shape),
            }
        }
        SrcRef::State(ix) => {
            let sv = &env.prog.state_vars[*ix as usize];
            SrcView {
                ptr: unsafe { env.state_rm.as_ptr().add(sv.flat_offset) },
                shape: sv.shape.clone(),
                strides: rm_strides(&sv.shape),
            }
        }
        SrcRef::Obs(ix) => {
            let name = &env.prog.obs_reads[*ix as usize];
            let a = obs
                .get(name)
                .unwrap_or_else(|| panic!("observed `{name}` not materialized before read"));
            SrcView {
                ptr: a.as_ptr(),
                shape: a.shape().iter().copied().collect(),
                strides: a.strides().iter().map(|&s| s as i64).collect(),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Strided kernels. All pointers derive from live borrows held by the caller;
// shapes/strides come from the validated program, with the load-bearing
// invariants (equal boxes, in-bounds storages) established at lowering time
// and re-checked here as debug assertions (plus hard asserts on the runtime-
// shaped observed inputs).
// ---------------------------------------------------------------------------

/// `true` when `strides` is exactly the row-major layout of `shape`
/// (singleton axes are stride-agnostic).
fn is_contig(strides: &[i64], shape: &[usize]) -> bool {
    let mut acc = 1i64;
    for d in (0..shape.len()).rev() {
        if shape[d] != 1 && strides[d] != acc {
            return false;
        }
        acc *= shape[d] as i64;
    }
    true
}

fn total(shape: &[usize]) -> usize {
    shape.iter().product::<usize>().max(1)
}

/// `dst[k] = f(a[k])` — dst contiguous row-major over `shape`.
unsafe fn ew1(dst: *mut f64, shape: &[usize], a: &Rv, f: impl Fn(f64) -> f64 + Copy) {
    let za: f64;
    let zero;
    let (ap, astr): (*const f64, &[i64]) = match a {
        Rv::S(v) => {
            za = *v;
            zero = DimI::from_elem(0, shape.len());
            (&za as *const f64, &zero[..])
        }
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
    };
    let n = total(shape);
    // Slab/state/observed buffers either coincide EXACTLY (an alias-safe
    // in-place reuse at the same storage offset) or are disjoint, so the
    // contiguous fast paths can be expressed through slices — which is what
    // lets LLVM prove no partial aliasing and vectorize the loops.
    unsafe {
        if is_contig(astr, shape) {
            let d = std::slice::from_raw_parts_mut(dst, n);
            if std::ptr::eq(ap, dst as *const f64) {
                for x in d.iter_mut() {
                    *x = f(*x);
                }
            } else {
                let a = std::slice::from_raw_parts(ap, n);
                for (x, &v) in d.iter_mut().zip(a) {
                    *x = f(v);
                }
            }
        } else if astr.iter().all(|&s| s == 0) {
            let v = f(*ap);
            let d = std::slice::from_raw_parts_mut(dst, n);
            for x in d.iter_mut() {
                *x = v;
            }
        } else {
            zip_loop2(dst, shape, ap, astr, ap, astr, |x, _| f(x));
        }
    }
}

/// `dst[k] = f(a[k], b[k])` — dst contiguous row-major over `shape`.
unsafe fn ew2(dst: *mut f64, shape: &[usize], a: &Rv, b: &Rv, f: impl Fn(f64, f64) -> f64 + Copy) {
    let za: f64;
    let zb: f64;
    let zeroa;
    let zerob;
    let (ap, astr): (*const f64, &[i64]) = match a {
        Rv::S(v) => {
            za = *v;
            zeroa = DimI::from_elem(0, shape.len());
            (&za as *const f64, &zeroa[..])
        }
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
    };
    let (bp, bstr): (*const f64, &[i64]) = match b {
        Rv::S(v) => {
            zb = *v;
            zerob = DimI::from_elem(0, shape.len());
            (&zb as *const f64, &zerob[..])
        }
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
    };
    let n = total(shape);
    let ac = is_contig(astr, shape);
    let bc = is_contig(bstr, shape);
    let az = astr.iter().all(|&s| s == 0);
    let bz = bstr.iter().all(|&s| s == 0);
    // See `ew1`: contiguous operands either coincide exactly with `dst` or
    // are disjoint from it, so slice-based loops are sound and vectorizable.
    unsafe {
        if ac && bc {
            let d = std::slice::from_raw_parts_mut(dst, n);
            let a_al = std::ptr::eq(ap, dst as *const f64);
            let b_al = std::ptr::eq(bp, dst as *const f64);
            match (a_al, b_al) {
                (true, true) => {
                    for x in d.iter_mut() {
                        *x = f(*x, *x);
                    }
                }
                (true, false) => {
                    let b = std::slice::from_raw_parts(bp, n);
                    for (x, &y) in d.iter_mut().zip(b) {
                        *x = f(*x, y);
                    }
                }
                (false, true) => {
                    let a = std::slice::from_raw_parts(ap, n);
                    for (x, &v) in d.iter_mut().zip(a) {
                        *x = f(v, *x);
                    }
                }
                (false, false) => {
                    let a = std::slice::from_raw_parts(ap, n);
                    let b = std::slice::from_raw_parts(bp, n);
                    for k in 0..n {
                        *d.get_unchecked_mut(k) = f(*a.get_unchecked(k), *b.get_unchecked(k));
                    }
                }
            }
        } else if ac && bz {
            let y = *bp;
            let d = std::slice::from_raw_parts_mut(dst, n);
            if std::ptr::eq(ap, dst as *const f64) {
                for x in d.iter_mut() {
                    *x = f(*x, y);
                }
            } else {
                let a = std::slice::from_raw_parts(ap, n);
                for (x, &v) in d.iter_mut().zip(a) {
                    *x = f(v, y);
                }
            }
        } else if az && bc {
            let x0 = *ap;
            let d = std::slice::from_raw_parts_mut(dst, n);
            if std::ptr::eq(bp, dst as *const f64) {
                for x in d.iter_mut() {
                    *x = f(x0, *x);
                }
            } else {
                let b = std::slice::from_raw_parts(bp, n);
                for (x, &y) in d.iter_mut().zip(b) {
                    *x = f(x0, y);
                }
            }
        } else {
            zip_loop2(dst, shape, ap, astr, bp, bstr, f);
        }
    }
}

/// General two-source odometer loop; dst contiguous row-major over `shape`.
unsafe fn zip_loop2(
    dst: *mut f64,
    shape: &[usize],
    a: *const f64,
    astr: &[i64],
    b: *const f64,
    bstr: &[i64],
    f: impl Fn(f64, f64) -> f64,
) {
    let n = shape.len();
    unsafe {
        if n == 0 {
            *dst = f(*a, *b);
            return;
        }
        let inner = shape[n - 1];
        let (ai, bi) = (astr[n - 1], bstr[n - 1]);
        let tot = total(shape);
        if tot == 0 || inner == 0 {
            return;
        }
        let outer = tot / inner;
        let mut idx = DimU::from_elem(0, n);
        let (mut aoff, mut boff) = (0i64, 0i64);
        let mut dp = dst;
        for _ in 0..outer {
            let mut ap = a.offset(aoff as isize);
            let mut bp = b.offset(boff as isize);
            for k in 0..inner {
                *dp.add(k) = f(*ap, *bp);
                ap = ap.offset(ai as isize);
                bp = bp.offset(bi as isize);
            }
            dp = dp.add(inner);
            let mut d = n - 1;
            while d > 0 {
                d -= 1;
                idx[d] += 1;
                aoff += astr[d];
                boff += bstr[d];
                if idx[d] < shape[d] {
                    break;
                }
                aoff -= astr[d] * shape[d] as i64;
                boff -= bstr[d] * shape[d] as i64;
                idx[d] = 0;
            }
        }
    }
}

/// `dst[k] = cond[k] != 0 ? a[k] : b[k]` — the `vec_select` kernel.
unsafe fn ew_select(dst: *mut f64, shape: &[usize], cond: &Rv, a: &Rv, b: &Rv) {
    // A scalar condition is the filter-gate broadcast: whole-array pick.
    if let Rv::S(c) = cond {
        let pick = if *c != 0.0 { a } else { b };
        unsafe { ew1(dst, shape, pick, |x| x) };
        return;
    }
    let za: f64;
    let zb: f64;
    let zeroa;
    let zerob;
    let (cp, cstr): (*const f64, &[i64]) = match cond {
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
        Rv::S(_) => unreachable!(),
    };
    let (ap, astr): (*const f64, &[i64]) = match a {
        Rv::S(v) => {
            za = *v;
            zeroa = DimI::from_elem(0, shape.len());
            (&za as *const f64, &zeroa[..])
        }
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
    };
    let (bp, bstr): (*const f64, &[i64]) = match b {
        Rv::S(v) => {
            zb = *v;
            zerob = DimI::from_elem(0, shape.len());
            (&zb as *const f64, &zerob[..])
        }
        Rv::V { ptr, strides } => (*ptr, &strides[..]),
    };
    let n = shape.len();
    // Contiguous fast path (see `ew1`/`ew2` on why slices + exact-alias
    // branches are sound): the mask select is the hot limiter idiom, so it
    // deserves a vectorizable loop. Exact aliasing of `dst` with any operand
    // is handled by reading through `dst` itself.
    let tot = total(shape);
    if is_contig(cstr, shape) && is_contig(astr, shape) && is_contig(bstr, shape) {
        unsafe {
            let d = std::slice::from_raw_parts_mut(dst, tot);
            let dc = dst as *const f64;
            let anyal = std::ptr::eq(cp, dc) || std::ptr::eq(ap, dc) || std::ptr::eq(bp, dc);
            if anyal {
                for k in 0..tot {
                    let c = *cp.add(k);
                    let v = if c != 0.0 { *ap.add(k) } else { *bp.add(k) };
                    *d.get_unchecked_mut(k) = v;
                }
            } else {
                let c = std::slice::from_raw_parts(cp, tot);
                let a = std::slice::from_raw_parts(ap, tot);
                let b = std::slice::from_raw_parts(bp, tot);
                for k in 0..tot {
                    *d.get_unchecked_mut(k) = if *c.get_unchecked(k) != 0.0 {
                        *a.get_unchecked(k)
                    } else {
                        *b.get_unchecked(k)
                    };
                }
            }
        }
        return;
    }
    unsafe {
        if n == 0 {
            *dst = if *cp != 0.0 { *ap } else { *bp };
            return;
        }
        let inner = shape[n - 1];
        if tot == 0 || inner == 0 {
            return;
        }
        let (ci, ai, bi) = (cstr[n - 1], astr[n - 1], bstr[n - 1]);
        let outer = tot / inner;
        let mut idx = DimU::from_elem(0, n);
        let (mut coff, mut aoff, mut boff) = (0i64, 0i64, 0i64);
        let mut dp = dst;
        for _ in 0..outer {
            let mut cpp = cp.offset(coff as isize);
            let mut app = ap.offset(aoff as isize);
            let mut bpp = bp.offset(boff as isize);
            for k in 0..inner {
                *dp.add(k) = if *cpp != 0.0 { *app } else { *bpp };
                cpp = cpp.offset(ci as isize);
                app = app.offset(ai as isize);
                bpp = bpp.offset(bi as isize);
            }
            dp = dp.add(inner);
            let mut d = n - 1;
            while d > 0 {
                d -= 1;
                idx[d] += 1;
                coff += cstr[d];
                aoff += astr[d];
                boff += bstr[d];
                if idx[d] < shape[d] {
                    break;
                }
                coff -= cstr[d] * shape[d] as i64;
                aoff -= astr[d] * shape[d] as i64;
                boff -= bstr[d] * shape[d] as i64;
                idx[d] = 0;
            }
        }
    }
}

/// Strided-to-strided block copy (pure data movement).
unsafe fn copy_strided(
    dst: *mut f64,
    dstr: &[i64],
    src: *const f64,
    sstr: &[i64],
    shape: &[usize],
) {
    let n = shape.len();
    unsafe {
        if n == 0 {
            *dst = *src;
            return;
        }
        let tot = total(shape);
        if tot == 0 {
            return;
        }
        if is_contig(dstr, shape) && is_contig(sstr, shape) {
            if !std::ptr::eq(dst as *const f64, src) {
                std::ptr::copy_nonoverlapping(src, dst, tot);
            }
            return;
        }
        let inner = shape[n - 1];
        if inner == 0 {
            return;
        }
        let (di, si) = (dstr[n - 1], sstr[n - 1]);
        let outer = tot / inner;
        let mut idx = DimU::from_elem(0, n);
        let (mut doff, mut soff) = (0i64, 0i64);
        for _ in 0..outer {
            let mut dp = dst.offset(doff as isize);
            let mut sp = src.offset(soff as isize);
            for _ in 0..inner {
                *dp = *sp;
                dp = dp.offset(di as isize);
                sp = sp.offset(si as isize);
            }
            let mut d = n - 1;
            while d > 0 {
                d -= 1;
                idx[d] += 1;
                doff += dstr[d];
                soff += sstr[d];
                if idx[d] < shape[d] {
                    break;
                }
                doff -= dstr[d] * shape[d] as i64;
                soff -= sstr[d] * shape[d] as i64;
                idx[d] = 0;
            }
        }
    }
}

/// Strided fill with a scalar.
unsafe fn fill_strided(dst: *mut f64, dstr: &[i64], shape: &[usize], v: f64) {
    let n = shape.len();
    unsafe {
        if n == 0 {
            *dst = v;
            return;
        }
        let tot = total(shape);
        if tot == 0 {
            return;
        }
        if is_contig(dstr, shape) {
            for k in 0..tot {
                *dst.add(k) = v;
            }
            return;
        }
        let inner = shape[n - 1];
        if inner == 0 {
            return;
        }
        let di = dstr[n - 1];
        let outer = tot / inner;
        let mut idx = DimU::from_elem(0, n);
        let mut doff = 0i64;
        for _ in 0..outer {
            let mut dp = dst.offset(doff as isize);
            for _ in 0..inner {
                *dp = v;
                dp = dp.offset(di as isize);
            }
            let mut d = n - 1;
            while d > 0 {
                d -= 1;
                idx[d] += 1;
                doff += dstr[d];
                if idx[d] < shape[d] {
                    break;
                }
                doff -= dstr[d] * shape[d] as i64;
                idx[d] = 0;
            }
        }
    }
}

/// Execute one precompiled gather plan into a contiguous row-major `out` —
/// the raw-strides transliteration of `eval_vec_index`'s copy phase (and of
/// the reference executor's `exec_gather`).
unsafe fn exec_gather(plan: &GatherPlan, src: &SrcView, out: *mut f64, full_cover: bool) {
    assert_eq!(
        &src.shape[..],
        &plan.src_shape[..],
        "gather source shape mismatch"
    );
    let out_ndim = plan.shape.len();
    // 1. Reduce fixed axes: advance the base pointer, keep the rest ascending
    //    (fixed_desc is sorted descending, but we rebuild by skipping).
    let mut base = src.ptr;
    let mut fixed_mask = [false; 16];
    for &(d, i0) in &plan.fixed_desc {
        fixed_mask[d] = true;
        base = unsafe { base.offset((src.strides[d] * i0 as i64) as isize) };
    }
    let reduced: DimI = (0..src.shape.len())
        .filter(|d| !fixed_mask[*d])
        .map(|d| src.strides[d])
        .collect();
    // 2. Permute the mapped source axes into output order; broadcast axes get
    //    stride 0 (`insert_axis` + `broadcast`).
    let mut eff = DimI::from_elem(0, out_ndim);
    let mut mpos = 0usize;
    for a in 0..out_ndim {
        if plan.mapped[a] {
            eff[a] = reduced[plan.perm[mpos]];
            mpos += 1;
        }
    }
    // 3. Ghost fill: `+0.0` everywhere (ArrayD::zeros semantics) — skipped
    //    when the segment schedule provably overwrites every element.
    if !full_cover {
        let out_len = total(&plan.shape);
        unsafe {
            for k in 0..out_len {
                *out.add(k) = 0.0;
            }
        }
    }
    // 4. Segment-copy schedule (mixed-radix over per-axis segment picks,
    //    axis 0 fastest — disjoint blocks, so order is immaterial).
    let out_rm = rm_strides(&plan.shape);
    let mut pick = DimU::from_elem(0, out_ndim);
    let mut bshape = DimU::from_elem(0, out_ndim);
    loop {
        let mut dbase = 0i64;
        let mut sbase = 0i64;
        for d in 0..out_ndim {
            let (o, l, s) = plan.segs[d][pick[d]];
            dbase += out_rm[d] * o as i64;
            sbase += eff[d] * s as i64;
            bshape[d] = l;
        }
        unsafe {
            copy_strided(
                out.offset(dbase as isize),
                &out_rm,
                base.offset(sbase as isize),
                &eff,
                &bshape,
            );
        }
        let mut d = 0;
        let mut done = false;
        loop {
            if d == out_ndim {
                done = true;
                break;
            }
            pick[d] += 1;
            if pick[d] < plan.segs[d].len() {
                break;
            }
            pick[d] = 0;
            d += 1;
        }
        if done {
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// The interpreter loop.
// ---------------------------------------------------------------------------

/// Execute the instruction range `[range.start, range.end)` (one or more
/// whole sections). `JmpIfZero` regions never straddle a section boundary.
fn run_range(
    env: &Env,
    range: std::ops::Range<usize>,
    exec: &mut TapeExec,
    dy: &mut [f64],
    stats: &mut RhsStats,
) {
    let TapeExec {
        slab,
        slot_off,
        obs,
        pending,
        plan_full,
        ..
    } = exec;
    let prog = env.prog;
    let slab_ptr = slab.as_mut_ptr();
    let slot_off: &[usize] = slot_off;
    pending.clear();

    let mut pc = range.start;
    while pc < range.end {
        while let Some(&(pos, skip)) = pending.last() {
            if pc == pos as usize {
                pending.pop();
                pc += skip as usize;
            } else {
                break;
            }
        }
        if pc >= range.end {
            break;
        }
        match &prog.instrs[pc] {
            Instr::Bin { op, a, b, out } => {
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                if desc.scalar {
                    let f = binary_kernel_of(*op);
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    let y = resolve_scalar(b, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = f(x, y) };
                } else {
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
                    let bv = resolve_rv(b, &desc.shape, env, slab_ptr, slot_off, obs);
                    let dst = unsafe { slab_ptr.add(off) };
                    let sh = &desc.shape;
                    // Monomorphized hot kernels, mirroring `vec_combine`'s
                    // arms (plus the comparison relops feeding `Select`
                    // masks): each closure computes the IDENTICAL expression
                    // to `binary_kernel_of`'s arm, so this is a pure dispatch
                    // hoist — one indirect call per NODE becomes an inlined,
                    // vectorizable element loop.
                    unsafe {
                        match op {
                            BinCode::Add => ew2(dst, sh, &av, &bv, |x, y| x + y),
                            BinCode::Sub => ew2(dst, sh, &av, &bv, |x, y| x - y),
                            BinCode::Mul => ew2(dst, sh, &av, &bv, |x, y| x * y),
                            BinCode::Div => ew2(dst, sh, &av, &bv, |x, y| x / y),
                            BinCode::Pow => ew2(dst, sh, &av, &bv, |x: f64, y: f64| x.powf(y)),
                            BinCode::Min => ew2(dst, sh, &av, &bv, |x: f64, y: f64| x.min(y)),
                            BinCode::Max => ew2(dst, sh, &av, &bv, |x: f64, y: f64| x.max(y)),
                            BinCode::Eq => ew2(dst, sh, &av, &bv, |x, y| (x == y) as i32 as f64),
                            BinCode::Ne => ew2(dst, sh, &av, &bv, |x, y| (x != y) as i32 as f64),
                            BinCode::Lt => ew2(dst, sh, &av, &bv, |x, y| (x < y) as i32 as f64),
                            BinCode::Le => ew2(dst, sh, &av, &bv, |x, y| (x <= y) as i32 as f64),
                            BinCode::Gt => ew2(dst, sh, &av, &bv, |x, y| (x > y) as i32 as f64),
                            BinCode::Ge => ew2(dst, sh, &av, &bv, |x, y| (x >= y) as i32 as f64),
                            other => ew2(dst, sh, &av, &bv, binary_kernel_of(*other)),
                        }
                    }
                }
            }
            Instr::Un { op, a, out } => {
                let f = unary_kernel_of(*op);
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                if desc.scalar {
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = f(x) };
                } else {
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
                    unsafe { ew1(slab_ptr.add(off), &desc.shape, &av, f) };
                }
            }
            Instr::Neg { a, out } => {
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                if desc.scalar {
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = -x };
                } else {
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
                    unsafe { ew1(slab_ptr.add(off), &desc.shape, &av, |x| -x) };
                }
            }
            Instr::Select { cond, a, b, out } => {
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                if desc.scalar {
                    let c = resolve_scalar(cond, env, slab_ptr, slot_off, obs);
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    let y = resolve_scalar(b, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = if c != 0.0 { x } else { y } };
                } else {
                    let cv = resolve_rv(cond, &desc.shape, env, slab_ptr, slot_off, obs);
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
                    let bv = resolve_rv(b, &desc.shape, env, slab_ptr, slot_off, obs);
                    unsafe { ew_select(slab_ptr.add(off), &desc.shape, &cv, &av, &bv) };
                }
            }
            Instr::Gather { src, plan, out } => {
                let full = plan_full[*plan as usize];
                let plan = &prog.plans[*plan as usize];
                let sv = resolve_src(src, env, slab_ptr, slot_off, obs);
                let off = slot_off[*out as usize];
                unsafe { exec_gather(plan, &sv, slab_ptr.add(off), full) };
            }
            Instr::LoadElem { src, idx, out } => {
                let sv = resolve_src(src, env, slab_ptr, slot_off, obs);
                debug_assert_eq!(idx.len(), sv.shape.len());
                let mut soff = 0i64;
                for (d, &i0) in idx.iter().enumerate() {
                    debug_assert!(i0 < sv.shape[d], "LoadElem index out of bounds");
                    soff += sv.strides[d] * i0 as i64;
                }
                let off = slot_off[*out as usize];
                unsafe { *slab_ptr.add(off) = *sv.ptr.offset(soff as isize) };
            }
            Instr::Ramp { axis, lo, out } => {
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                let a = *axis as usize;
                let pre: usize = desc.shape[..a].iter().product();
                let ax = desc.shape[a];
                let post: usize = desc.shape[a + 1..].iter().product();
                let mut p = unsafe { slab_ptr.add(off) };
                for _ in 0..pre.max(1) {
                    for q in 0..ax {
                        let v = (*lo + q as i64) as f64;
                        unsafe {
                            for _ in 0..post.max(1) {
                                *p = v;
                                p = p.add(1);
                            }
                        }
                    }
                }
            }
            Instr::Fill { v, out } => {
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                let s = resolve_scalar(v, env, slab_ptr, slot_off, obs);
                if desc.scalar {
                    unsafe { *slab_ptr.add(off) = s };
                } else {
                    let n = desc.elems();
                    unsafe {
                        let p = slab_ptr.add(off);
                        for k in 0..n {
                            *p.add(k) = s;
                        }
                    }
                }
            }
            Instr::Copy { a, out } => {
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                if desc.scalar {
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = x };
                } else {
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
                    match av {
                        Rv::S(_) => panic!("array Copy from a scalar operand"),
                        Rv::V { ptr, strides } => unsafe {
                            copy_strided(
                                slab_ptr.add(off),
                                &rm_strides(&desc.shape),
                                ptr,
                                &strides,
                                &desc.shape,
                            );
                        },
                    }
                }
            }
            Instr::Region {
                base,
                src,
                region,
                out,
            } => {
                let spec = &prog.regions[*region as usize];
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                let base_off = slot_off[*base as usize];
                let n = desc.elems();
                unsafe {
                    // `out = base` (skip when the coloring aliased them, which
                    // it can only do at identical offsets).
                    if base_off != off {
                        std::ptr::copy_nonoverlapping(
                            slab_ptr.add(base_off) as *const f64,
                            slab_ptr.add(off),
                            n,
                        );
                    }
                }
                // Overwrite the region sub-block.
                let out_rm = rm_strides(&desc.shape);
                let mut dbase = 0i64;
                for d in 0..desc.shape.len() {
                    dbase += out_rm[d] * spec.dest_lo[d] as i64;
                }
                let sub_dst = unsafe { slab_ptr.add(off).offset(dbase as isize) };
                let sv = resolve_rv(src, &spec.shape, env, slab_ptr, slot_off, obs);
                match sv {
                    Rv::S(v) => unsafe { fill_strided(sub_dst, &out_rm, &spec.shape, v) },
                    Rv::V { ptr, strides } => unsafe {
                        copy_strided(sub_dst, &out_rm, ptr, &strides, &spec.shape);
                    },
                }
            }
            Instr::JmpIfZero {
                cond,
                n_true,
                n_false,
            } => {
                let c = resolve_scalar(cond, env, slab_ptr, slot_off, obs);
                if c != 0.0 {
                    // Execute the true region, then skip the false one.
                    pending.push(((pc + 1 + *n_true as usize) as u32, *n_false));
                } else {
                    pc += *n_true as usize; // skip straight to the false region
                }
            }
            Instr::Fallback { rule } => {
                let info = &prog.rules[*rule as usize];
                match info.kind {
                    RuleKind::Observed(i) => {
                        materialize_observeds_append(
                            obs,
                            std::slice::from_ref(&env.observed_rules[i]),
                            env.state_arrays,
                            env.params,
                            env.param_names,
                            env.t,
                            env.derived_rings,
                            env.forcing,
                            false,
                            stats,
                            None,
                        );
                    }
                    RuleKind::Rhs(i) => {
                        run_rhs_oracle(
                            &env.rhs_rules[i],
                            env.var_shapes,
                            env.param_names,
                            env.state_arrays,
                            obs,
                            env.params,
                            env.t,
                            env.derived_rings,
                            env.forcing,
                            dy,
                        );
                    }
                }
            }
            Instr::Export { slot, export } => {
                let name = &prog.exports[*export as usize].0;
                let a = obs.get_mut(name).expect("export array preallocated");
                let desc = &prog.slots[*slot as usize];
                let off = slot_off[*slot as usize];
                if desc.scalar {
                    a[IxDyn(&[])] = unsafe { *slab_ptr.add(off) };
                } else {
                    let dst = a
                        .as_slice_mut()
                        .expect("export arrays are standard layout");
                    unsafe {
                        std::ptr::copy_nonoverlapping(
                            slab_ptr.add(off) as *const f64,
                            dst.as_mut_ptr(),
                            desc.elems(),
                        );
                    }
                }
            }
            Instr::DyWrite { write } => {
                let w = &prog.dy_writes[*write as usize];
                let desc = &prog.slots[w.slot as usize];
                let off = slot_off[w.slot as usize];
                match w.scalar_flat {
                    Some(flat) => {
                        debug_assert!(desc.scalar);
                        dy[flat] = unsafe { *slab_ptr.add(off) };
                    }
                    None => {
                        let sv = &prog.state_vars[w.var as usize];
                        let cm = cm_strides(&sv.shape);
                        let mut dbase = sv.flat_offset as i64;
                        for d in 0..sv.shape.len() {
                            dbase += w.dest_lo[d] as i64 * cm[d];
                        }
                        debug_assert!(
                            sv.flat_offset
                                + sv.shape.iter().product::<usize>().max(1)
                                <= dy.len()
                        );
                        unsafe {
                            copy_strided(
                                dy.as_mut_ptr().offset(dbase as isize),
                                &cm,
                                slab_ptr.add(off) as *const f64,
                                &rm_strides(&desc.shape),
                                &desc.shape,
                            );
                        }
                    }
                }
            }
        }
        pc += 1;
    }
}

// ---------------------------------------------------------------------------
// The per-cell oracle for fallback RHS rules — shared with the test-only
// reference executor. A transliteration of `evaluate_rhs_with_scratch`'s
// fallback arm (without the prefix-scan rewrite, which is documented and
// pinned bit-identical to this plain loop).
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
pub(super) fn run_rhs_oracle(
    rule: &RhsRule,
    var_shapes: &IndexMap<String, VarShape>,
    param_names: &[String],
    state_arrays: &ArrMap,
    observed_arrays: &ArrMap,
    params: &[f64],
    t: f64,
    derived_rings: &RefCell<HashMap<String, ArrayD<f64>>>,
    forcing: &RefCell<HashMap<String, ArrayD<f64>>>,
    dy: &mut [f64],
) {
    let mut ctx = EvalCtx {
        state_arrays,
        observed_arrays,
        params,
        param_names,
        loop_binds: IdxMap::default(),
        t,
        derived_rings,
        derived_extents: empty_derived_extents(),
        forcing,
        cse: None,
    };
    match rule {
        RhsRule::Scalar { slot, body } | RhsRule::IndexedScalar { slot, body } => {
            dy[*slot] = eval(body, &mut ctx).as_scalar().unwrap_or(f64::NAN);
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
            let static_ranges = static_contract_ranges(contract_dims);
            let output_origin: Vec<i64> = output_ranges.iter().map(|(lo, _)| *lo).collect();
            let mut tuples = CartesianTuples::new(output_ranges);
            while let Some(tuple) = tuples.next() {
                for (name, val) in output_idx_names.iter().zip(tuple.iter()) {
                    set_bind(&mut ctx.loop_binds, name, *val);
                }
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
