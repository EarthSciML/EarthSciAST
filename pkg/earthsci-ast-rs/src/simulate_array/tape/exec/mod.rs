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
//!
//! The executor is split along the stages one call passes through. This
//! module owns the environment switches, the per-scratch executor state and
//! the per-call entry; `resolve` turns an operand into a scalar or a strided
//! view; `kernels` holds the strided loops those views feed; `fused` holds
//! the chunked fused-group executor together with the kernel dispatch tables
//! both executors expand; `interp` is the instruction loop that drives them;
//! and `oracle` is the per-cell fallback evaluator, kept apart because the
//! test-only reference executor shares it.

use super::super::*;
use super::ir::*;
use ndarray::ArrayD;
use smallvec::SmallVec;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

mod fused;
mod interp;
mod kernels;
mod oracle;
mod resolve;
#[cfg(test)]
mod simd_tests;

// Re-exported at the `exec` boundary for the test-only reference executor
// (`super::refexec`), which shares the micro-op scalar semantics and the
// per-cell fallback oracle so the two executors cannot drift.
#[cfg(test)]
pub(super) use fused::eval_micro_op;
#[cfg(test)]
pub(super) use oracle::run_rhs_oracle;

use fused::FCHUNK;
use interp::run_range;
use kernels::copy_strided;
use resolve::{cm_strides, rm_strides};

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
    pub(in crate::simulate_array) fn new(
        prog: Rc<TapeProgram>,
        observed_rules: Rc<Vec<AlgebraicRule>>,
    ) -> Self {
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

impl<'a> Env<'a> {
    /// The interpreter environment for the fallback arms that re-enter the
    /// per-cell oracle: no CSE memo, and the compiled-RHS derived-extents map
    /// is empty (see `EvalCtx::derived_extents`).
    fn eval_env(&self) -> EvalEnv<'a> {
        EvalEnv {
            state_arrays: self.state_arrays,
            params: self.params,
            param_names: self.param_names,
            t: self.t,
            derived_rings: self.derived_rings,
            derived_extents: empty_derived_extents(),
            forcing: self.forcing,
            cse: None,
            const_arrays: self.const_arrays,
        }
    }
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
/// The caller supplies the shared per-call inputs as an [`RhsCall`] (the
/// remaining [`Env`] fields — the program, the FULL observed-rule list, the
/// intra-call ring registry, and the row-major state mirror — are owned by
/// the tape context or created inside the call).
pub(in crate::simulate_array) fn run_tape_call(
    ctx: &mut TapeCtx,
    call: &RhsCall,
    state_arrays: &ArrMap,
    const_arrays: &ConstArrayScope,
    dy: &mut [f64],
    stats: &mut RhsStats,
) {
    let &RhsCall {
        rhs_rules,
        var_shapes,
        param_names,
        state,
        params,
        forcing,
        t,
        ..
    } = call;
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
    exec.state_rm = state_rm;

    stats.taped_rules += exec.n_taped;
    stats.fallback_rules += exec.n_fallback;
}
