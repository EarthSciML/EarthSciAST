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
use smallvec::SmallVec;
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

/// Runtime-selected SIMD width for the fused-loop kernel clones (Step 4b).
///
/// The generic build targets baseline x86-64 (SSE-2), leaving 2x-4x of vector
/// width unused on AVX2/AVX-512 machines. The hot fused-loop bodies are
/// compiled again under `#[target_feature]` (same Rust source, same scalar
/// semantics, wider lanes — LLVM's auto-vectorizer is not permitted to
/// reassociate or contract FP ops, so the clones are bit-identical; pinned by
/// `simd_clone_bit_identity`), and ONE clone is selected per process — never
/// per element or per micro-op, which is the twice-measured dispatch trap.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum SimdLevel {
    /// The portable baseline codegen (and the only level off x86-64).
    Generic,
    #[cfg(target_arch = "x86_64")]
    Avx2,
    #[cfg(target_arch = "x86_64")]
    Avx512,
}

/// Detect the widest supported clone, once. `ESS_TAPE_SIMD_DISABLE=1` forces
/// the generic codegen (the Step 4b kill switch; bit-identical either way).
pub(crate) fn simd_level() -> SimdLevel {
    use std::sync::OnceLock;
    static LEVEL: OnceLock<SimdLevel> = OnceLock::new();
    *LEVEL.get_or_init(|| {
        let off = std::env::var("ESS_TAPE_SIMD_DISABLE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        if off {
            return SimdLevel::Generic;
        }
        // `ESS_TAPE_SIMD_LEVEL=generic|avx2|avx512`: cap the selection below
        // the detected width (measurement aid; a level the CPU lacks is
        // ignored). Unset = widest detected.
        let cap = std::env::var("ESS_TAPE_SIMD_LEVEL").unwrap_or_default();
        if cap.eq_ignore_ascii_case("generic") {
            return SimdLevel::Generic;
        }
        #[cfg(target_arch = "x86_64")]
        {
            let allow512 = !cap.eq_ignore_ascii_case("avx2");
            if allow512
                && std::arch::is_x86_feature_detected!("avx512f")
                && std::arch::is_x86_feature_detected!("avx512vl")
                && std::arch::is_x86_feature_detected!("avx512dq")
                && std::arch::is_x86_feature_detected!("avx512bw")
            {
                return SimdLevel::Avx512;
            }
            if std::arch::is_x86_feature_detected!("avx2") {
                return SimdLevel::Avx2;
            }
        }
        SimdLevel::Generic
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
    /// Step 4 epochs: the parameter / forcing epochs the CONST resp. SEGMENT
    /// sections last primed under (0 = never primed; live epochs start at 1).
    /// Checked per call as two integer compares — see `run_tape_call`.
    primed_param_epoch: u64,
    primed_forcing_epoch: u64,
    /// Step 4: chunk register file for fused groups
    /// (`max n_regs over specs × FCHUNK` doubles, recycled across groups).
    fregs: Vec<f64>,
    /// Step 4 export demotion: `Export` instructions only execute when
    /// something can read the published arrays — a fallback rule is present,
    /// `ESS_TAPE_CHECK` is active, or a caller explicitly requested them
    /// ([`TapeCtx::set_exports_active`]). With no possible reader they are
    /// skipped (the exported values themselves are still computed — they are
    /// ordinary slots — only the publish memcpy is elided).
    exports_active: bool,
    /// Rule counts, cached off the program for the per-call stats.
    pub(crate) n_taped: usize,
    pub(crate) n_fallback: usize,
    /// Step 4b: the SIMD clone this executor runs its fused loops through,
    /// selected ONCE at executor construction (never per element).
    simd: SimdLevel,
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
        let max_fregs = prog
            .fused
            .iter()
            .map(|f| f.n_regs as usize + f.n_load_regs as usize + f.n_splat_regs as usize)
            .max()
            .unwrap_or(0);
        TapeExec {
            slab,
            slot_off,
            obs,
            pending: Vec::with_capacity(16),
            state_rm: vec![0.0f64; n_state],
            plan_full,
            primed_param_epoch: 0,
            primed_forcing_epoch: 0,
            fregs: vec![0.0f64; max_fregs * FCHUNK],
            exports_active: n_fallback > 0 || tape_check_calls() > 0,
            n_taped: prog.rules.len() - n_fallback,
            n_fallback,
            simd: simd_level(),
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
    /// Step 4 epoch counters (see `run_tape_call`). The parameter epoch is
    /// bumped whenever the bit-exact generation hash of the caller's params
    /// slice changes (the slice is the only channel callers have, so the hash
    /// remains the epoch SOURCE — it is O(params_len) and negligible); the
    /// forcing epoch is a driver-owned counter, bumped between segments when
    /// the live forcing buffer is refreshed, which re-runs only the SEGMENT
    /// section.
    param_epoch: u64,
    forcing_epoch: u64,
    pgen: u64,
    pgen_set: bool,
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
            param_epoch: 0,
            forcing_epoch: 1,
            pgen: 0,
            pgen_set: false,
        }
    }

    /// Invalidate the SEGMENT section: the driver calls this after refreshing
    /// the live forcing buffer while keeping one warm executor. (The current
    /// driver builds a fresh scratch per segment, so nothing calls it yet;
    /// it is the forcing half of the Step 4 epoch machinery.)
    #[allow(dead_code)]
    pub(crate) fn bump_forcing_epoch(&mut self) {
        self.forcing_epoch += 1;
    }

    /// Force `Export` instructions on/off (test/diagnostic hook — production
    /// derives this from the fallback count and `ESS_TAPE_CHECK`).
    #[allow(dead_code)]
    pub(crate) fn set_exports_active(&mut self, on: bool) {
        self.exec.exports_active = on;
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
    /// The model's const-array registry (§5.5.5), for the fallback arms that
    /// re-enter the per-cell oracle.
    const_arrays: &'a ConstArrayScope,
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
    const_arrays: &ConstArrayScope,
) {
    // Parameter epoch: bit-exact generation hash of the params slice → epoch
    // bump on change (the negative-control test in `tests/tape_exec.rs`
    // guards this: bypassing it serves stale CONST values).
    let g = params_gen(params);
    if !ctx.pgen_set || ctx.pgen != g {
        ctx.pgen = g;
        ctx.pgen_set = true;
        ctx.param_epoch += 1;
    }
    let (param_epoch, forcing_epoch) = (ctx.param_epoch, ctx.forcing_epoch);
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
        const_arrays,
    };

    // Section invalidation: two integer compares per steady-state call.
    // CONST depends on the parameter epoch alone; SEGMENT additionally on the
    // forcing epoch (a forcing refresh re-runs only the SEGMENT section).
    let const_end = prog.n_const as usize;
    let prime_end = (prog.n_const + prog.n_segment) as usize;
    if exec.primed_param_epoch != param_epoch {
        exec.primed_param_epoch = param_epoch;
        exec.primed_forcing_epoch = forcing_epoch;
        run_range(&env, 0..prime_end, exec, dy, stats);
    } else if exec.primed_forcing_epoch != forcing_epoch {
        exec.primed_forcing_epoch = forcing_epoch;
        run_range(&env, const_end..prime_end, exec, dy, stats);
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
#[inline(never)]
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
#[inline(never)]
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
#[inline(never)]
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
#[inline(never)]
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
// Step 4: fused-group execution.
// ---------------------------------------------------------------------------

/// Chunk length of the strip-mined fused executor: intermediates live in a
/// small register file (`n_regs × FCHUNK` doubles, L1-resident) instead of
/// round-tripping ~55 KB slab arrays between every op.
pub(super) const FCHUNK: usize = 1024;

/// `ESS_TAPE_FUSE_MODE=elem`: run fused groups through the per-element
/// micro-op interpreter instead of the chunked one (measurement arm for the
/// Step 4 interpreter-design comparison; bit-identical either way).
fn fuse_elem_mode() -> bool {
    use std::sync::OnceLock;
    static ELEM: OnceLock<bool> = OnceLock::new();
    *ELEM.get_or_init(|| {
        std::env::var("ESS_TAPE_FUSE_MODE")
            .map(|v| v.eq_ignore_ascii_case("elem"))
            .unwrap_or(false)
    })
}

/// A micro-op operand resolved for one chunk: a pointer to `c` contiguous
/// values, or a constant broadcast over the chunk.
#[derive(Clone, Copy)]
enum MSrc {
    P(*const f64),
    C(f64),
}

/// `dst[k] = f(a[k])` over one chunk. `dst` is a register region; a `P`
/// operand is either a DIFFERENT register region (the allocator never assigns
/// an op's out register to one of its operands) or a slab/state/observed
/// buffer (disjoint from the register file), so slice-based loops are sound —
/// and vectorizable.
#[inline(always)]
unsafe fn fch1(dst: *mut f64, c: usize, a: MSrc, f: impl Fn(f64) -> f64 + Copy) {
    unsafe {
        let d = std::slice::from_raw_parts_mut(dst, c);
        match a {
            MSrc::P(pa) => {
                let a = std::slice::from_raw_parts(pa, c);
                for (x, &v) in d.iter_mut().zip(a) {
                    *x = f(v);
                }
            }
            MSrc::C(v) => {
                let y = f(v);
                for x in d.iter_mut() {
                    *x = y;
                }
            }
        }
    }
}

/// `dst[k] = f(a[k], b[k])` over one chunk (see `fch1` for the aliasing
/// argument; the two operands may alias EACH OTHER, which shared slices
/// permit).
#[inline(always)]
unsafe fn fch2(dst: *mut f64, c: usize, a: MSrc, b: MSrc, f: impl Fn(f64, f64) -> f64 + Copy) {
    unsafe {
        let d = std::slice::from_raw_parts_mut(dst, c);
        match (a, b) {
            (MSrc::P(pa), MSrc::P(pb)) => {
                let a = std::slice::from_raw_parts(pa, c);
                let b = std::slice::from_raw_parts(pb, c);
                for k in 0..c {
                    *d.get_unchecked_mut(k) = f(*a.get_unchecked(k), *b.get_unchecked(k));
                }
            }
            (MSrc::P(pa), MSrc::C(y)) => {
                let a = std::slice::from_raw_parts(pa, c);
                for (x, &v) in d.iter_mut().zip(a) {
                    *x = f(v, y);
                }
            }
            (MSrc::C(x0), MSrc::P(pb)) => {
                let b = std::slice::from_raw_parts(pb, c);
                for (x, &y) in d.iter_mut().zip(b) {
                    *x = f(x0, y);
                }
            }
            (MSrc::C(x0), MSrc::C(y0)) => {
                let v = f(x0, y0);
                for x in d.iter_mut() {
                    *x = v;
                }
            }
        }
    }
}

/// `dst[k] = g(a[k], b[k], c[k])` over one chunk (the Bin2 superop; see
/// `fch1` for the aliasing argument).
#[inline(always)]
unsafe fn fch3(
    dst: *mut f64,
    n: usize,
    a: MSrc,
    b: MSrc,
    cc: MSrc,
    g: impl Fn(f64, f64, f64) -> f64 + Copy,
) {
    unsafe {
        let d = std::slice::from_raw_parts_mut(dst, n);
        macro_rules! lp {
            ($ax:expr, $bx:expr, $cx:expr) => {
                for k in 0..n {
                    *d.get_unchecked_mut(k) = g($ax(k), $bx(k), $cx(k));
                }
            };
        }
        match (a, b, cc) {
            (MSrc::P(pa), MSrc::P(pb), MSrc::P(pc)) => {
                let (a, b, c) = (
                    std::slice::from_raw_parts(pa, n),
                    std::slice::from_raw_parts(pb, n),
                    std::slice::from_raw_parts(pc, n),
                );
                lp!(
                    |k: usize| *a.get_unchecked(k),
                    |k: usize| *b.get_unchecked(k),
                    |k: usize| *c.get_unchecked(k)
                );
            }
            (MSrc::P(pa), MSrc::P(pb), MSrc::C(z)) => {
                let (a, b) = (
                    std::slice::from_raw_parts(pa, n),
                    std::slice::from_raw_parts(pb, n),
                );
                lp!(
                    |k: usize| *a.get_unchecked(k),
                    |k: usize| *b.get_unchecked(k),
                    |_k: usize| z
                );
            }
            (MSrc::P(pa), MSrc::C(y), MSrc::P(pc)) => {
                let (a, c) = (
                    std::slice::from_raw_parts(pa, n),
                    std::slice::from_raw_parts(pc, n),
                );
                lp!(
                    |k: usize| *a.get_unchecked(k),
                    |_k: usize| y,
                    |k: usize| *c.get_unchecked(k)
                );
            }
            (MSrc::P(pa), MSrc::C(y), MSrc::C(z)) => {
                let a = std::slice::from_raw_parts(pa, n);
                lp!(|k: usize| *a.get_unchecked(k), |_k: usize| y, |_k: usize| z);
            }
            (MSrc::C(x), MSrc::P(pb), MSrc::P(pc)) => {
                let (b, c) = (
                    std::slice::from_raw_parts(pb, n),
                    std::slice::from_raw_parts(pc, n),
                );
                lp!(
                    |_k: usize| x,
                    |k: usize| *b.get_unchecked(k),
                    |k: usize| *c.get_unchecked(k)
                );
            }
            (MSrc::C(x), MSrc::P(pb), MSrc::C(z)) => {
                let b = std::slice::from_raw_parts(pb, n);
                lp!(|_k: usize| x, |k: usize| *b.get_unchecked(k), |_k: usize| z);
            }
            (MSrc::C(x), MSrc::C(y), MSrc::P(pc)) => {
                let c = std::slice::from_raw_parts(pc, n);
                lp!(|_k: usize| x, |_k: usize| y, |k: usize| *c.get_unchecked(k));
            }
            (MSrc::C(x), MSrc::C(y), MSrc::C(z)) => {
                let v = g(x, y, z);
                for w in d.iter_mut() {
                    *w = v;
                }
            }
        }
    }
}

/// `dst[k] = g(a[k], b[k], c[k], d[k])` over one chunk, all operands
/// pointers (the Bin3 superop; scalar/ghost operands were resolved to splat
/// registers by the caller). See `fch1` for the aliasing argument; operands
/// may alias each other, which shared slices permit.
#[inline(always)]
unsafe fn fch4(
    dst: *mut f64,
    n: usize,
    pa: *const f64,
    pb: *const f64,
    pc: *const f64,
    pd: *const f64,
    g: impl Fn(f64, f64, f64, f64) -> f64 + Copy,
) {
    unsafe {
        let o = std::slice::from_raw_parts_mut(dst, n);
        let a = std::slice::from_raw_parts(pa, n);
        let b = std::slice::from_raw_parts(pb, n);
        let c = std::slice::from_raw_parts(pc, n);
        let d = std::slice::from_raw_parts(pd, n);
        for k in 0..n {
            *o.get_unchecked_mut(k) = g(
                *a.get_unchecked(k),
                *b.get_unchecked(k),
                *c.get_unchecked(k),
                *d.get_unchecked(k),
            );
        }
    }
}

/// The `vec_select` pick over one chunk.
#[inline(always)]
unsafe fn fch_sel(dst: *mut f64, c: usize, cond: MSrc, a: MSrc, b: MSrc) {
    // A constant condition is the filter-gate broadcast: whole-chunk pick.
    if let MSrc::C(cv) = cond {
        let pick = if cv != 0.0 { a } else { b };
        unsafe { fch1(dst, c, pick, |x| x) };
        return;
    }
    let MSrc::P(cp) = cond else { unreachable!() };
    unsafe {
        let d = std::slice::from_raw_parts_mut(dst, c);
        let cs = std::slice::from_raw_parts(cp, c);
        // Monomorphized over the operand kinds so each arm is a branch-free
        // (blendable) loop rather than a per-element kind dispatch.
        match (a, b) {
            (MSrc::P(pa), MSrc::P(pb)) => {
                let a = std::slice::from_raw_parts(pa, c);
                let b = std::slice::from_raw_parts(pb, c);
                for k in 0..c {
                    // Load both, then select VALUES (evaluate-both semantics;
                    // a value select vectorizes to a blend, where a pointer
                    // select stays a scalar cmov+load).
                    let av = *a.get_unchecked(k);
                    let bv = *b.get_unchecked(k);
                    *d.get_unchecked_mut(k) = if *cs.get_unchecked(k) != 0.0 { av } else { bv };
                }
            }
            (MSrc::P(pa), MSrc::C(y)) => {
                let a = std::slice::from_raw_parts(pa, c);
                for k in 0..c {
                    let av = *a.get_unchecked(k);
                    *d.get_unchecked_mut(k) = if *cs.get_unchecked(k) != 0.0 { av } else { y };
                }
            }
            (MSrc::C(x), MSrc::P(pb)) => {
                let b = std::slice::from_raw_parts(pb, c);
                for k in 0..c {
                    let bv = *b.get_unchecked(k);
                    *d.get_unchecked_mut(k) = if *cs.get_unchecked(k) != 0.0 { x } else { bv };
                }
            }
            (MSrc::C(x), MSrc::C(y)) => {
                for k in 0..c {
                    *d.get_unchecked_mut(k) = if *cs.get_unchecked(k) != 0.0 { x } else { y };
                }
            }
        }
    }
}

/// Execute one fused group. Iterates the precompiled run schedule; each run
/// is strip-mined into `FCHUNK`-element chunks whose micro-ops execute over
/// the register file, then live-out registers store to the slab. Per element
/// this applies exactly the same scalar kernels in the same order as the
/// unfused instructions (elementwise maps — chunking cannot change a bit).
#[inline(never)]
unsafe fn exec_fused(
    fs: &FusedSpec,
    env: &Env,
    slab_ptr: *mut f64,
    slot_off: &[usize],
    obs: &ArrMap,
    fregs: &mut [f64],
    simd: SimdLevel,
) {
    // Resolve scalar inputs once.
    let mut svals: SmallVec<[f64; 8]> = SmallVec::new();
    for op in &fs.scalars {
        svals.push(resolve_scalar(op, env, slab_ptr, slot_off, obs));
    }
    // Resolve array input base pointers once.
    let mut bases: SmallVec<[*const f64; 8]> = SmallVec::new();
    for inp in &fs.inputs {
        let p: *const f64 = match &inp.src {
            SrcRef::Slot(s) => {
                debug_assert_eq!(&env.prog.slots[*s as usize].shape, &inp.src_shape);
                unsafe { slab_ptr.add(slot_off[*s as usize]) as *const f64 }
            }
            SrcRef::State(ix) => {
                let sv = &env.prog.state_vars[*ix as usize];
                debug_assert_eq!(&sv.shape, &inp.src_shape);
                unsafe { env.state_rm.as_ptr().add(sv.flat_offset) }
            }
            SrcRef::Obs(ix) => {
                let name = &env.prog.obs_reads[*ix as usize];
                let a = obs
                    .get(name)
                    .unwrap_or_else(|| panic!("observed `{name}` not materialized before read"));
                assert_eq!(
                    a.shape(),
                    &inp.src_shape[..],
                    "fused input `{name}` box mismatch"
                );
                assert!(a.is_standard_layout());
                a.as_ptr()
            }
        };
        bases.push(p);
    }
    // Output slab pointers.
    let mut outs: SmallVec<[(u16, *mut f64); 2]> = SmallVec::new();
    for &(reg, slot) in &fs.outputs {
        outs.push((reg, unsafe { slab_ptr.add(slot_off[slot as usize]) }));
    }

    if fuse_elem_mode() {
        unsafe { exec_fused_elem(fs, &svals, &bases, &outs) };
        return;
    }

    // Step 4b: run the chunked micro-program through the SIMD clone selected
    // at executor construction. Same source, same scalar semantics — the
    // `#[target_feature]` wrappers only widen the auto-vectorized lanes.
    match simd {
        SimdLevel::Generic => unsafe {
            exec_fused_runs_generic(fs, &svals, &bases, &outs, fregs)
        },
        #[cfg(target_arch = "x86_64")]
        SimdLevel::Avx2 => unsafe { exec_fused_runs_avx2(fs, &svals, &bases, &outs, fregs) },
        #[cfg(target_arch = "x86_64")]
        SimdLevel::Avx512 => unsafe { exec_fused_runs_avx512(fs, &svals, &bases, &outs, fregs) },
    }
}

/// The strip-mined chunk loop of [`exec_fused`], monomorphized per SIMD
/// level through the `#[target_feature]` wrappers below (`#[inline(always)]`
/// so each wrapper compiles the WHOLE loop nest — micro-op dispatch, chunk
/// kernels and stores — under its feature set).
#[inline(always)]
unsafe fn exec_fused_runs(
    fs: &FusedSpec,
    svals: &[f64],
    bases: &[*const f64],
    outs: &[(u16, *mut f64)],
    fregs: &mut [f64],
) {
    let rp = fregs.as_mut_ptr();
    // Bin3 splat registers: one FCHUNK broadcast per scalar plus a zero
    // register (the ghost read), filled once per call. The values are the
    // EXACT scalars / the exact `+0.0` ghost, so an all-pointer superop
    // reads identical bits to the `MSrc::C` broadcast it replaces.
    let splat_base = fs.n_regs as usize + fs.n_load_regs as usize;
    let zero_ix = splat_base + svals.len();
    if fs.n_splat_regs > 0 {
        debug_assert_eq!(fs.n_splat_regs as usize, svals.len() + 1);
        unsafe {
            for (i, &v) in svals.iter().enumerate() {
                let p = rp.add((splat_base + i) * FCHUNK);
                for k in 0..FCHUNK {
                    *p.add(k) = v;
                }
            }
            let z = rp.add(zero_ix * FCHUNK);
            for k in 0..FCHUNK {
                *z.add(k) = 0.0;
            }
        }
    }
    for run in &fs.runs {
        let mut done = 0usize;
        let len = run.len as usize;
        while done < len {
            let c = (len - done).min(FCHUNK);
            let at = run.out_off as usize + done;
            // Pre-load strided shifted inputs into their dedicated chunk
            // registers (a ghost run needs no load — reads resolve to 0.0).
            for (i, inp) in fs.inputs.iter().enumerate() {
                if inp.load_reg == u16::MAX {
                    continue;
                }
                let sx = inp.shifted_ix.expect("load_reg implies shifted");
                let o = run.in_off[sx as usize];
                if o == GHOST_OFF {
                    continue;
                }
                unsafe {
                    let dst = rp.add(inp.load_reg as usize * FCHUNK);
                    let base = bases[i].offset(o as isize + done as isize * inp.elem_stride as isize);
                    for k in 0..c {
                        *dst.add(k) = *base.offset(k as isize * inp.elem_stride as isize);
                    }
                }
            }
            let msrc = |m: &MRef| -> MSrc {
                match m {
                    MRef::Reg(r) => MSrc::P(unsafe { rp.add(*r as usize * FCHUNK) as *const f64 }),
                    MRef::Scal(i) => MSrc::C(svals[*i as usize]),
                    MRef::In(i) => {
                        let inp = &fs.inputs[*i as usize];
                        match inp.shifted_ix {
                            None => MSrc::P(unsafe { bases[*i as usize].add(at) }),
                            Some(s) => {
                                let o = run.in_off[s as usize];
                                if o == GHOST_OFF {
                                    MSrc::C(0.0)
                                } else if inp.load_reg != u16::MAX {
                                    MSrc::P(unsafe {
                                        rp.add(inp.load_reg as usize * FCHUNK) as *const f64
                                    })
                                } else {
                                    MSrc::P(unsafe {
                                        bases[*i as usize].offset(o as isize + done as isize)
                                    })
                                }
                            }
                        }
                    }
                }
            };
            // All-pointer operand resolution for the Bin3 superop: scalar
            // operands point at their splat registers, ghost reads at the
            // zero register — same values, so same bits, with ONE loop shape
            // per (op1, op2, op3) instead of 2^4 operand-kind arms.
            let msrc_p = |m: &MRef| -> *const f64 {
                match msrc(m) {
                    MSrc::P(p) => p,
                    MSrc::C(v) => {
                        if v == 0.0 && v.is_sign_positive() {
                            unsafe { rp.add(zero_ix * FCHUNK) as *const f64 }
                        } else {
                            match m {
                                MRef::Scal(i) => unsafe {
                                    rp.add((splat_base + *i as usize) * FCHUNK) as *const f64
                                },
                                _ => unreachable!("non-scalar constant operand"),
                            }
                        }
                    }
                }
            };
            for op in &fs.micro {
                match op {
                    MicroOp::Bin { op, a, b, out } => {
                        let (a, b) = (msrc(a), msrc(b));
                        let dst = unsafe { rp.add(*out as usize * FCHUNK) };
                        // Monomorphized over the same kernel bodies as the
                        // unfused `Instr::Bin` arm.
                        unsafe {
                            match op {
                                BinCode::Add => fch2(dst, c, a, b, |x, y| x + y),
                                BinCode::Sub => fch2(dst, c, a, b, |x, y| x - y),
                                BinCode::Mul => fch2(dst, c, a, b, |x, y| x * y),
                                BinCode::Div => fch2(dst, c, a, b, |x, y| x / y),
                                BinCode::Pow => fch2(dst, c, a, b, |x: f64, y: f64| x.powf(y)),
                                BinCode::Min => fch2(dst, c, a, b, |x: f64, y: f64| x.min(y)),
                                BinCode::Max => fch2(dst, c, a, b, |x: f64, y: f64| x.max(y)),
                                BinCode::Eq => fch2(dst, c, a, b, |x, y| (x == y) as i32 as f64),
                                BinCode::Ne => fch2(dst, c, a, b, |x, y| (x != y) as i32 as f64),
                                BinCode::Lt => fch2(dst, c, a, b, |x, y| (x < y) as i32 as f64),
                                BinCode::Le => fch2(dst, c, a, b, |x, y| (x <= y) as i32 as f64),
                                BinCode::Gt => fch2(dst, c, a, b, |x, y| (x > y) as i32 as f64),
                                BinCode::Ge => fch2(dst, c, a, b, |x, y| (x >= y) as i32 as f64),
                                other => fch2(dst, c, a, b, binary_kernel_of(*other)),
                            }
                        }
                    }
                    MicroOp::Un { op, a, out } => {
                        let a = msrc(a);
                        let dst = unsafe { rp.add(*out as usize * FCHUNK) };
                        unsafe {
                            match op {
                                UnCode::Abs => fch1(dst, c, a, |x: f64| x.abs()),
                                UnCode::Sqrt => fch1(dst, c, a, |x: f64| x.sqrt()),
                                UnCode::Exp => fch1(dst, c, a, |x: f64| x.exp()),
                                UnCode::Ln => fch1(dst, c, a, |x: f64| x.ln()),
                                UnCode::Log10 => fch1(dst, c, a, |x: f64| x.log10()),
                                UnCode::Sin => fch1(dst, c, a, |x: f64| x.sin()),
                                UnCode::Cos => fch1(dst, c, a, |x: f64| x.cos()),
                                UnCode::Tanh => fch1(dst, c, a, |x: f64| x.tanh()),
                                UnCode::Floor => fch1(dst, c, a, |x: f64| x.floor()),
                                UnCode::Ceil => fch1(dst, c, a, |x: f64| x.ceil()),
                                UnCode::Sign => fch1(dst, c, a, |x: f64| {
                                    if x > 0.0 {
                                        1.0
                                    } else if x < 0.0 {
                                        -1.0
                                    } else {
                                        0.0
                                    }
                                }),
                                other => fch1(dst, c, a, unary_kernel_of(*other)),
                            }
                        }
                    }
                    MicroOp::Neg { a, out } => {
                        let a = msrc(a);
                        unsafe { fch1(rp.add(*out as usize * FCHUNK), c, a, |x| -x) };
                    }
                    MicroOp::Select { cond, a, b, out } => {
                        let (cv, av, bv) = (msrc(cond), msrc(a), msrc(b));
                        unsafe { fch_sel(rp.add(*out as usize * FCHUNK), c, cv, av, bv) };
                    }
                    MicroOp::Mov { a, out } => {
                        let a = msrc(a);
                        unsafe { fch1(rp.add(*out as usize * FCHUNK), c, a, |x| x) };
                    }
                    MicroOp::Bin2 {
                        op1,
                        a,
                        b,
                        op2,
                        c: c3,
                        swap,
                        out,
                    } => {
                        let (av, bv, cv) = (msrc(a), msrc(b), msrc(c3));
                        let dst = unsafe { rp.add(*out as usize * FCHUNK) };
                        use BinCode::{Add, Div, Ge, Gt, Le, Lt, Max, Min, Mul, Sub};
                        // Monomorphized composition of the same two kernel
                        // bodies, applied in the same order (t = op1(a, b);
                        // out = swap ? op2(c, t) : op2(t, c)).
                        macro_rules! b2 {
                            ($f1:expr, $f2:expr) => {
                                if *swap {
                                    unsafe {
                                        fch3(dst, c, av, bv, cv, |x, y, z| $f2(z, $f1(x, y)))
                                    }
                                } else {
                                    unsafe {
                                        fch3(dst, c, av, bv, cv, |x, y, z| $f2($f1(x, y), z))
                                    }
                                }
                            };
                        }
                        let add = |x: f64, y: f64| x + y;
                        let sub = |x: f64, y: f64| x - y;
                        let mul = |x: f64, y: f64| x * y;
                        let div = |x: f64, y: f64| x / y;
                        let min = |x: f64, y: f64| x.min(y);
                        let max = |x: f64, y: f64| x.max(y);
                        let gt = |x: f64, y: f64| (x > y) as i32 as f64;
                        let ge = |x: f64, y: f64| (x >= y) as i32 as f64;
                        let lt = |x: f64, y: f64| (x < y) as i32 as f64;
                        let le = |x: f64, y: f64| (x <= y) as i32 as f64;
                        match (op1, op2) {
                            (Add, Add) => b2!(add, add),
                            (Add, Sub) => b2!(add, sub),
                            (Add, Mul) => b2!(add, mul),
                            (Add, Div) => b2!(add, div),
                            (Sub, Add) => b2!(sub, add),
                            (Sub, Sub) => b2!(sub, sub),
                            (Sub, Mul) => b2!(sub, mul),
                            (Sub, Div) => b2!(sub, div),
                            (Mul, Add) => b2!(mul, add),
                            (Mul, Sub) => b2!(mul, sub),
                            (Mul, Mul) => b2!(mul, mul),
                            (Mul, Div) => b2!(mul, div),
                            (Div, Add) => b2!(div, add),
                            (Div, Sub) => b2!(div, sub),
                            (Div, Mul) => b2!(div, mul),
                            (Div, Div) => b2!(div, div),
                            // Step 4b extended pairs (`bin2_pair_ok`): the
                            // multiply-into-mask and min/max clamp idioms the
                            // adjacency histogram showed material.
                            (Mul, Gt) => b2!(mul, gt),
                            (Mul, Ge) => b2!(mul, ge),
                            (Mul, Lt) => b2!(mul, lt),
                            (Mul, Le) => b2!(mul, le),
                            (Min, Max) => b2!(min, max),
                            (Max, Min) => b2!(max, min),
                            (Mul, Min) => b2!(mul, min),
                            (Min, Mul) => b2!(min, mul),
                            (Mul, Max) => b2!(mul, max),
                            (Max, Mul) => b2!(max, mul),
                            other => unreachable!("Bin2 pair not monomorphized ({other:?})"),
                        }
                    }
                    MicroOp::Bin3 {
                        op1,
                        a,
                        b,
                        op2,
                        c: c3,
                        swap2,
                        op3,
                        d: d4,
                        swap3,
                        out,
                    } => {
                        let (pa, pb, pc, pd) =
                            (msrc_p(a), msrc_p(b), msrc_p(c3), msrc_p(d4));
                        let dst = unsafe { rp.add(*out as usize * FCHUNK) };
                        use BinCode::{Add, Div, Mul, Sub};
                        // Monomorphized composition of the same three kernel
                        // bodies applied in order:
                        // t1 = op1(a, b); t2 = swap2 ? op2(c, t1) : op2(t1, c);
                        // out = swap3 ? op3(d, t2) : op3(t2, d).
                        macro_rules! b3 {
                            ($f1:expr, $f2:expr, $f3:expr) => {
                                match (*swap2, *swap3) {
                                    (false, false) => unsafe {
                                        fch4(dst, c, pa, pb, pc, pd, |x, y, z, w| {
                                            $f3($f2($f1(x, y), z), w)
                                        })
                                    },
                                    (true, false) => unsafe {
                                        fch4(dst, c, pa, pb, pc, pd, |x, y, z, w| {
                                            $f3($f2(z, $f1(x, y)), w)
                                        })
                                    },
                                    (false, true) => unsafe {
                                        fch4(dst, c, pa, pb, pc, pd, |x, y, z, w| {
                                            $f3(w, $f2($f1(x, y), z))
                                        })
                                    },
                                    (true, true) => unsafe {
                                        fch4(dst, c, pa, pb, pc, pd, |x, y, z, w| {
                                            $f3(w, $f2(z, $f1(x, y)))
                                        })
                                    },
                                }
                            };
                        }
                        let add = |x: f64, y: f64| x + y;
                        let sub = |x: f64, y: f64| x - y;
                        let mul = |x: f64, y: f64| x * y;
                        let div = |x: f64, y: f64| x / y;
                        macro_rules! b3_op12 {
                            ($f3:expr) => {
                                match (op1, op2) {
                                    (Add, Add) => b3!(add, add, $f3),
                                    (Add, Sub) => b3!(add, sub, $f3),
                                    (Add, Mul) => b3!(add, mul, $f3),
                                    (Add, Div) => b3!(add, div, $f3),
                                    (Sub, Add) => b3!(sub, add, $f3),
                                    (Sub, Sub) => b3!(sub, sub, $f3),
                                    (Sub, Mul) => b3!(sub, mul, $f3),
                                    (Sub, Div) => b3!(sub, div, $f3),
                                    (Mul, Add) => b3!(mul, add, $f3),
                                    (Mul, Sub) => b3!(mul, sub, $f3),
                                    (Mul, Mul) => b3!(mul, mul, $f3),
                                    (Mul, Div) => b3!(mul, div, $f3),
                                    (Div, Add) => b3!(div, add, $f3),
                                    (Div, Sub) => b3!(div, sub, $f3),
                                    (Div, Mul) => b3!(div, mul, $f3),
                                    (Div, Div) => b3!(div, div, $f3),
                                    other => {
                                        unreachable!("Bin3 restricted to + - * / ({other:?})")
                                    }
                                }
                            };
                        }
                        match op3 {
                            Add => b3_op12!(add),
                            Sub => b3_op12!(sub),
                            Mul => b3_op12!(mul),
                            Div => b3_op12!(div),
                            other => unreachable!("Bin3 restricted to + - * / ({other:?})"),
                        }
                    }
                }
            }
            for &(reg, optr) in outs {
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        rp.add(reg as usize * FCHUNK) as *const f64,
                        optr.add(at),
                        c,
                    );
                }
            }
            done += c;
        }
    }
}

/// Baseline-codegen instantiation of the fused chunk loop.
#[inline(never)]
unsafe fn exec_fused_runs_generic(
    fs: &FusedSpec,
    svals: &[f64],
    bases: &[*const f64],
    outs: &[(u16, *mut f64)],
    fregs: &mut [f64],
) {
    unsafe { exec_fused_runs(fs, svals, bases, outs, fregs) }
}

/// AVX2 clone: identical Rust source compiled under `avx2` (+`fma` is NOT
/// enabled — LLVM must not contract mul+add into fused multiply-add, which
/// would change bits). Reached only when `is_x86_feature_detected!` proved
/// support, so the `unsafe` target-feature contract holds.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn exec_fused_runs_avx2(
    fs: &FusedSpec,
    svals: &[f64],
    bases: &[*const f64],
    outs: &[(u16, *mut f64)],
    fregs: &mut [f64],
) {
    unsafe { exec_fused_runs(fs, svals, bases, outs, fregs) }
}

/// AVX-512 clone (f+vl+dq+bw, all runtime-checked). Note LLVM keeps its
/// preferred vector width at 256 bits for these targets unless told
/// otherwise, so this may codegen close to the AVX2 clone.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx512f", enable = "avx512vl", enable = "avx512dq", enable = "avx512bw")]
unsafe fn exec_fused_runs_avx512(
    fs: &FusedSpec,
    svals: &[f64],
    bases: &[*const f64],
    outs: &[(u16, *mut f64)],
    fregs: &mut [f64],
) {
    unsafe { exec_fused_runs(fs, svals, bases, outs, fregs) }
}

/// The per-element measurement arm (`ESS_TAPE_FUSE_MODE=elem`): one scalar
/// register file, micro-ops dispatched per element through the shared kernel
/// tables. Bit-identical to the chunked executor (same kernels, same order).
#[inline(never)]
unsafe fn exec_fused_elem(
    fs: &FusedSpec,
    svals: &[f64],
    bases: &[*const f64],
    outs: &[(u16, *mut f64)],
) {
    let mut regs: SmallVec<[f64; 32]> = SmallVec::from_elem(0.0f64, fs.n_regs as usize);
    for run in &fs.runs {
        for k in 0..run.len as usize {
            let at = run.out_off as usize + k;
            let get = |m: &MRef, regs: &[f64]| -> f64 {
                match m {
                    MRef::Reg(r) => regs[*r as usize],
                    MRef::Scal(i) => svals[*i as usize],
                    MRef::In(i) => {
                        let inp = &fs.inputs[*i as usize];
                        match inp.shifted_ix {
                            None => unsafe { *bases[*i as usize].add(at) },
                            Some(s) => {
                                let o = run.in_off[s as usize];
                                if o == GHOST_OFF {
                                    0.0
                                } else {
                                    unsafe {
                                        *bases[*i as usize].offset(
                                            o as isize + k as isize * inp.elem_stride as isize,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            };
            for op in &fs.micro {
                match op {
                    MicroOp::Bin { op, a, b, out } => {
                        let v = binary_kernel_of(*op)(get(a, &regs), get(b, &regs));
                        regs[*out as usize] = v;
                    }
                    MicroOp::Un { op, a, out } => {
                        let v = unary_kernel_of(*op)(get(a, &regs));
                        regs[*out as usize] = v;
                    }
                    MicroOp::Neg { a, out } => {
                        let v = -get(a, &regs);
                        regs[*out as usize] = v;
                    }
                    MicroOp::Select { cond, a, b, out } => {
                        let v = if get(cond, &regs) != 0.0 {
                            get(a, &regs)
                        } else {
                            get(b, &regs)
                        };
                        regs[*out as usize] = v;
                    }
                    MicroOp::Mov { a, out } => {
                        let v = get(a, &regs);
                        regs[*out as usize] = v;
                    }
                    MicroOp::Bin2 {
                        op1,
                        a,
                        b,
                        op2,
                        c,
                        swap,
                        out,
                    } => {
                        let t = binary_kernel_of(*op1)(get(a, &regs), get(b, &regs));
                        let cv = get(c, &regs);
                        let v = if *swap {
                            binary_kernel_of(*op2)(cv, t)
                        } else {
                            binary_kernel_of(*op2)(t, cv)
                        };
                        regs[*out as usize] = v;
                    }
                    MicroOp::Bin3 {
                        op1,
                        a,
                        b,
                        op2,
                        c,
                        swap2,
                        op3,
                        d,
                        swap3,
                        out,
                    } => {
                        let t1 = binary_kernel_of(*op1)(get(a, &regs), get(b, &regs));
                        let cv = get(c, &regs);
                        let t2 = if *swap2 {
                            binary_kernel_of(*op2)(cv, t1)
                        } else {
                            binary_kernel_of(*op2)(t1, cv)
                        };
                        let dv = get(d, &regs);
                        let v = if *swap3 {
                            binary_kernel_of(*op3)(dv, t2)
                        } else {
                            binary_kernel_of(*op3)(t2, dv)
                        };
                        regs[*out as usize] = v;
                    }
                }
            }
            for &(reg, optr) in outs {
                unsafe { *optr.add(at) = regs[reg as usize] };
            }
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
        fregs,
        exports_active,
        simd,
        ..
    } = exec;
    let exports_active = *exports_active;
    let simd = *simd;
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
                let desc = &prog.slots[*out as usize];
                let off = slot_off[*out as usize];
                if desc.scalar {
                    let f = unary_kernel_of(*op);
                    let x = resolve_scalar(a, env, slab_ptr, slot_off, obs);
                    unsafe { *slab_ptr.add(off) = f(x) };
                } else {
                    let av = resolve_rv(a, &desc.shape, env, slab_ptr, slot_off, obs);
                    let dst = unsafe { slab_ptr.add(off) };
                    let sh = &desc.shape;
                    // Step 4: monomorphized arms for the common unaries (the
                    // same closure bodies as `unary_kernel_of`, so a pure
                    // dispatch hoist — one fn-pointer call per ELEMENT becomes
                    // an inlined loop).
                    unsafe {
                        match op {
                            UnCode::Abs => ew1(dst, sh, &av, |x: f64| x.abs()),
                            UnCode::Sqrt => ew1(dst, sh, &av, |x: f64| x.sqrt()),
                            UnCode::Exp => ew1(dst, sh, &av, |x: f64| x.exp()),
                            UnCode::Ln => ew1(dst, sh, &av, |x: f64| x.ln()),
                            UnCode::Log10 => ew1(dst, sh, &av, |x: f64| x.log10()),
                            UnCode::Sin => ew1(dst, sh, &av, |x: f64| x.sin()),
                            UnCode::Cos => ew1(dst, sh, &av, |x: f64| x.cos()),
                            UnCode::Tanh => ew1(dst, sh, &av, |x: f64| x.tanh()),
                            UnCode::Floor => ew1(dst, sh, &av, |x: f64| x.floor()),
                            UnCode::Ceil => ew1(dst, sh, &av, |x: f64| x.ceil()),
                            UnCode::Sign => ew1(dst, sh, &av, |x: f64| {
                                if x > 0.0 {
                                    1.0
                                } else if x < 0.0 {
                                    -1.0
                                } else {
                                    0.0
                                }
                            }),
                            other => ew1(dst, sh, &av, unary_kernel_of(*other)),
                        }
                    }
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
                            env.const_arrays,
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
                            env.const_arrays,
                        );
                    }
                }
            }
            Instr::Export { slot, export } => {
                // Step 4 export demotion: no fallback rules, no check mode,
                // no explicit request ⇒ nothing can read the published
                // array — skip the publish memcpy.
                if !exports_active {
                    pc += 1;
                    continue;
                }
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
            Instr::Fused { spec } => {
                let fs = &prog.fused[*spec as usize];
                unsafe { exec_fused(fs, env, slab_ptr, slot_off, obs, fregs, simd) };
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
    const_arrays: &ConstArrayScope,
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
        const_arrays,
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

// ---------------------------------------------------------------------------
// Step 4b: SIMD-clone bit-identity tests. The `#[target_feature]` clones are
// the SAME Rust source under wider codegen; these tests pin that claim on
// adversarial inputs (NaNs, signed zeros, denormals, infinities, extreme
// magnitudes) across chunk boundaries, ghost runs and strided pre-loads. Any
// bit difference outside the documented NaN-payload latitude means the
// widened codegen reassociated or contracted something, and that clone must
// be rejected.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod simd_tests {
    use super::*;

    /// Adversarial + pseudorandom input of length `n`, seeded.
    ///
    /// NOTE on NaNs (`with_nan`): when BOTH operands of a commutative op are
    /// NaNs with different payloads, x86 propagates whichever payload lands
    /// in the first source slot — and LLVM (whose semantics leave NaN
    /// payloads nondeterministic) may commute operands differently per
    /// codegen width, so such cases legitimately differ between
    /// equally-correct clones without any reassociation. Measured here
    /// twice: a payload qNaN input trips it directly, and even a canonical
    /// qNaN input trips it in chains, when `inf - inf` GENERATES the
    /// negative hardware qNaN (fff8…) that then meets the positive input
    /// NaN (7ff8…). Therefore the strict byte-equality set excludes NaN
    /// inputs (all NaNs are then hardware-GENERATED — 0/0, inf-inf, 0*inf —
    /// which yield the identical fff8… at every width, keeping both-NaN
    /// cases deterministic), and a second set adds NaN inputs with NaN
    /// results compared by class (non-NaN results stay byte-strict).
    fn adversarial(n: usize, seed: u64, with_nan: bool) -> Vec<f64> {
        let specials = [
            if with_nan { f64::NAN } else { -7.25 },
            1.5e-310, // denormal
            0.0,
            -0.0,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::MIN_POSITIVE,          // smallest normal
            5e-324,                     // smallest denormal
            -5e-324,
            2.2e-308,                   // denormal
            f64::MAX,
            f64::MIN,
            1.0,
            -1.0,
            1.5,
            -2.5,
            1e308,
            -1e308,
            3.5e-320,                   // denormal
            0.1,
        ];
        let mut x = seed.wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(1);
        (0..n)
            .map(|k| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                if k % 3 == 0 {
                    specials[(x as usize) % specials.len()]
                } else {
                    // Mix magnitudes; keep bit-level variety.
                    let u = (x >> 11) as f64 / (1u64 << 53) as f64;
                    (u - 0.5) * 10f64.powi((x % 61) as i32 - 30)
                }
            })
            .collect()
    }

    /// Build a `FusedSpec` + inputs exercising every micro-op kind, run it
    /// through every available SIMD clone, and assert byte-identical outputs
    /// (NaN results compared by class when `with_nan` — see `adversarial`).
    fn drive(with_nan: bool) {
        const N: usize = 2500; // chunk boundaries at 1024, 2048 + short tail
        let a = adversarial(N, 1, with_nan);
        let b = adversarial(N, 2, with_nan);
        let shifted = adversarial(N + 16, 3, with_nan);
        let strided = adversarial(2 * N + 8, 4, with_nan);
        let svals = [
            if with_nan { f64::NAN } else { 3.75 },
            -0.0,
            2.5,
            5e-324,
            f64::INFINITY,
        ];

        let inputs = vec![
            // 0, 1: aligned reads.
            FusedInput {
                src: SrcRef::Slot(0),
                shifted_ix: None,
                src_shape: DimU::from_elem(N, 1),
                elem_stride: 1,
                load_reg: u16::MAX,
            },
            FusedInput {
                src: SrcRef::Slot(1),
                shifted_ix: None,
                src_shape: DimU::from_elem(N, 1),
                elem_stride: 1,
                load_reg: u16::MAX,
            },
            // 2: shifted stride-1 read (ghost over the last run).
            FusedInput {
                src: SrcRef::Slot(2),
                shifted_ix: Some(0),
                src_shape: DimU::from_elem(N + 16, 1),
                elem_stride: 1,
                load_reg: u16::MAX,
            },
            // 3: strided (elem_stride 2) read through a pre-load register.
            FusedInput {
                src: SrcRef::Slot(3),
                shifted_ix: Some(1),
                src_shape: DimU::from_elem(2 * N + 8, 1),
                elem_stride: 2,
                load_reg: u16::MAX, // patched below once n_regs is known
            },
        ];

        // Micro program: every Bin code, every monomorphized Un code, Neg,
        // Selects (register / input / scalar conds), Mov, and every Bin2
        // combo in both swap orientations, with operand kinds mixed.
        let mut micro: Vec<MicroOp> = Vec::new();
        let bins = [
            BinCode::Add,
            BinCode::Sub,
            BinCode::Mul,
            BinCode::Div,
            BinCode::Pow,
            BinCode::Min,
            BinCode::Max,
            BinCode::Eq,
            BinCode::Ne,
            BinCode::Lt,
            BinCode::Le,
            BinCode::Gt,
            BinCode::Ge,
        ];
        for (i, op) in bins.iter().enumerate() {
            let (a, b) = match i % 4 {
                0 => (MRef::In(0), MRef::In(1)),
                1 => (MRef::In(2), MRef::In(0)),
                2 => (MRef::Scal(i as u16 % 5), MRef::In(3)),
                _ => (MRef::In(1), MRef::Scal((i as u16 + 2) % 5)),
            };
            let out = micro.len() as u16;
            micro.push(MicroOp::Bin { op: *op, a, b, out });
        }
        let uns = [
            UnCode::Abs,
            UnCode::Sqrt,
            UnCode::Exp,
            UnCode::Ln,
            UnCode::Log10,
            UnCode::Sin,
            UnCode::Cos,
            UnCode::Tanh,
            UnCode::Floor,
            UnCode::Ceil,
            UnCode::Sign,
        ];
        for (i, op) in uns.iter().enumerate() {
            let a = match i % 3 {
                0 => MRef::In(0),
                1 => MRef::In(2),
                _ => MRef::Reg(i as u16), // an earlier Bin result
            };
            let out = micro.len() as u16;
            micro.push(MicroOp::Un { op: *op, a, out });
        }
        let out = micro.len() as u16;
        micro.push(MicroOp::Neg { a: MRef::In(3), out });
        let out = micro.len() as u16;
        micro.push(MicroOp::Select {
            cond: MRef::Reg(9), // an Lt mask
            a: MRef::In(0),
            b: MRef::In(1),
            out,
        });
        let out = micro.len() as u16;
        micro.push(MicroOp::Select {
            cond: MRef::In(2),
            a: MRef::Reg(0),
            b: MRef::Scal(1),
            out,
        });
        let out = micro.len() as u16;
        micro.push(MicroOp::Select {
            cond: MRef::Scal(2),
            a: MRef::In(1),
            b: MRef::In(0),
            out,
        });
        let out = micro.len() as u16;
        micro.push(MicroOp::Mov { a: MRef::In(3), out });
        let arith = [BinCode::Add, BinCode::Sub, BinCode::Mul, BinCode::Div];
        for op1 in arith {
            for op2 in arith {
                for swap in [false, true] {
                    let out = micro.len() as u16;
                    micro.push(MicroOp::Bin2 {
                        op1,
                        a: MRef::In(0),
                        b: MRef::In(1),
                        op2,
                        c: MRef::In(2),
                        swap,
                        out,
                    });
                }
            }
        }
        // Extended Bin2 pairs (`bin2_pair_ok` beyond the arith square).
        let ext = [
            (BinCode::Mul, BinCode::Gt),
            (BinCode::Mul, BinCode::Ge),
            (BinCode::Mul, BinCode::Lt),
            (BinCode::Mul, BinCode::Le),
            (BinCode::Min, BinCode::Max),
            (BinCode::Max, BinCode::Min),
            (BinCode::Mul, BinCode::Min),
            (BinCode::Min, BinCode::Mul),
            (BinCode::Mul, BinCode::Max),
            (BinCode::Max, BinCode::Mul),
        ];
        for (i, (op1, op2)) in ext.iter().enumerate() {
            for swap in [false, true] {
                let out = micro.len() as u16;
                micro.push(MicroOp::Bin2 {
                    op1: *op1,
                    a: MRef::In(1),
                    b: MRef::In(2),
                    op2: *op2,
                    c: if i % 2 == 0 { MRef::In(0) } else { MRef::Scal(i as u16 % 5) },
                    swap,
                    out,
                });
            }
        }
        // Bin3: the full arith cube in all four swap orientations, cycling
        // operand kinds through aligned / shifted (incl. ghost) / strided /
        // splat-scalar / register sources.
        let mut pat = 0usize;
        for op1 in arith {
            for op2 in arith {
                for op3 in arith {
                    for (swap2, swap3) in
                        [(false, false), (true, false), (false, true), (true, true)]
                    {
                        let (a, b, c, d) = match pat % 4 {
                            0 => (MRef::In(0), MRef::In(1), MRef::In(2), MRef::In(3)),
                            1 => (MRef::In(2), MRef::Scal(0), MRef::In(0), MRef::Scal(3)),
                            2 => (MRef::Scal(2), MRef::In(3), MRef::Scal(1), MRef::In(1)),
                            _ => (MRef::In(1), MRef::In(0), MRef::Reg(0), MRef::In(2)),
                        };
                        pat += 1;
                        let out = micro.len() as u16;
                        micro.push(MicroOp::Bin3 {
                            op1,
                            a,
                            b,
                            op2,
                            c,
                            swap2,
                            op3,
                            d,
                            swap3,
                            out,
                        });
                    }
                }
            }
        }
        let n_ops = micro.len();
        let n_regs = n_ops as u16;
        let mut inputs = inputs;
        inputs[3].load_reg = n_regs; // one strided pre-load register

        // Runs: [0, 1300) shifted-src offset 5; [1300, N) ghost for the
        // stride-1 shifted input. The strided input stays live in both.
        let runs = vec![
            FusedRun {
                out_off: 0,
                len: 1300,
                in_off: SmallVec::from_slice(&[5i64, 3]),
            },
            FusedRun {
                out_off: 1300,
                len: (N - 1300) as u32,
                in_off: SmallVec::from_slice(&[GHOST_OFF, 3 + 2 * 1300]),
            },
        ];
        let fs = FusedSpec {
            shape: DimU::from_elem(N, 1),
            inputs,
            scalars: Vec::new(), // svals are passed directly
            micro,
            n_regs,
            n_load_regs: 1,
            n_splat_regs: 6, // 5 scalars + the zero register
            outputs: SmallVec::new(), // outs are passed directly
            runs,
            n_fused_instrs: 0,
            n_folded_gathers: 0,
        };

        let bases: Vec<*const f64> = vec![a.as_ptr(), b.as_ptr(), shifted.as_ptr(), strided.as_ptr()];
        let mut run_level = |wider: u8| -> Vec<Vec<f64>> {
            let mut outbufs: Vec<Vec<f64>> = (0..n_ops).map(|_| vec![0.0f64; N]).collect();
            let outs: Vec<(u16, *mut f64)> = outbufs
                .iter_mut()
                .enumerate()
                .map(|(i, buf)| (i as u16, buf.as_mut_ptr()))
                .collect();
            let mut fregs = vec![0.0f64; (n_regs as usize + 1 + 6) * FCHUNK];
            match wider {
                0 => unsafe {
                    exec_fused_runs_generic(&fs, &svals, &bases, &outs, &mut fregs)
                },
                #[cfg(target_arch = "x86_64")]
                1 => unsafe { exec_fused_runs_avx2(&fs, &svals, &bases, &outs, &mut fregs) },
                #[cfg(target_arch = "x86_64")]
                2 => unsafe { exec_fused_runs_avx512(&fs, &svals, &bases, &outs, &mut fregs) },
                _ => panic!("level unavailable in this build"),
            }
            outbufs
        };

        let reference = run_level(0);
        let mut levels_checked = 0;
        #[cfg(target_arch = "x86_64")]
        {
            if std::arch::is_x86_feature_detected!("avx2") {
                let got = run_level(1);
                assert_bits_eq(&reference, &got, "avx2", with_nan);
                levels_checked += 1;
            }
            if std::arch::is_x86_feature_detected!("avx512f")
                && std::arch::is_x86_feature_detected!("avx512vl")
                && std::arch::is_x86_feature_detected!("avx512dq")
                && std::arch::is_x86_feature_detected!("avx512bw")
            {
                let got = run_level(2);
                assert_bits_eq(&reference, &got, "avx512", with_nan);
                levels_checked += 1;
            }
        }
        // On non-x86 hosts there is nothing to compare against — the test
        // degenerates to "the generic path runs" (levels_checked = 0).
        let _ = levels_checked;
    }

    /// Strict byte equality: NaN-free adversarial inputs (±inf, ±0,
    /// denormals, extremes); every NaN in the pipeline is hardware-generated
    /// and identical at every width, so results must match to the bit.
    #[test]
    fn simd_clone_bit_identity() {
        drive(false);
    }

    /// NaN-bearing inputs: non-NaN results byte-strict; NaN results
    /// class-compared (payload latitude under commutation, see
    /// `adversarial`).
    #[test]
    fn simd_clone_bit_identity_nan_inputs() {
        drive(true);
    }

    fn assert_bits_eq(want: &[Vec<f64>], got: &[Vec<f64>], label: &str, nan_class: bool) {
        for (op, (w, g)) in want.iter().zip(got.iter()).enumerate() {
            for (k, (a, b)) in w.iter().zip(g.iter()).enumerate() {
                if nan_class && a.is_nan() && b.is_nan() {
                    continue;
                }
                assert_eq!(
                    a.to_bits(),
                    b.to_bits(),
                    "{label}: micro-op {op} elem {k}: generic {a:?} ({:016x}) vs {label} {b:?} ({:016x})",
                    a.to_bits(),
                    b.to_bits()
                );
            }
        }
    }
}
