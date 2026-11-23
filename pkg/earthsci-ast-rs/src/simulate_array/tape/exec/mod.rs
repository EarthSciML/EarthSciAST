//! Step 3b: the fast tape executor — the production RHS hot path.
//!
//! Executes a [`TapeProgram`] over a preallocated `f64` slab with **zero
//! per-call heap allocation** (after warm-up), **no hashing on the kernel
//! path**, and **zero recursion**. Array kernels are strided loops over raw
//! `(pointer, shape, strides)` triples dispatched through the SAME
//! `BinCode`/`UnCode` kernel fn-pointer tables the per-cell oracle uses,
//! so every element is computed by the same kernel the interpreter would have
//! called — bit identity is structural, not coincidental:
//!
//! * elementwise instructions apply a pure per-element kernel, so iteration
//!   order cannot change any output bit;
//! * gathers execute the precompiled segment-copy plans (pure data movement
//!   over a `+0.0` ghost fill);
//! * contractions were already unrolled by the lowering into the per-cell
//!   oracle's fold order;
//! * `JmpIfZero` short-circuits with the reference executor's pending-skip
//!   discipline, so an untaken branch never executes.
//!
//! **State access**: a state variable's flat block is column-major over its
//! logical shape, i.e. it *is* a strided view with strides
//! `[1, s0, s0·s1, …]`. Instructions read the flat state vector directly
//! through those strides — no per-call refill or copy.
//!
//! **No interpreter**: the executor is handed no rule, no `EvalCtx` and none
//! of the interpreter's per-variable state arrays, and the instruction set
//! has no arm that would want them (a program exists only when every rule
//! lowered; see [`DeclinedTape`]). Per-cell evaluation is unreachable from
//! here by construction.
//!
//! **Scalar slots** live in the slab like array slots (their storages are
//! 1-element buckets assigned by the same coloring); a scalar read is one
//! indexed load either way, and keeping one address space keeps the executor
//! uniform.
//!
//! **Sections/invalidation**: the CONST section runs once per scratch and
//! parameter vector, guarded by a parameter-generation hash: a caller that reuses one scratch across a
//! parameter change (a sweep through `debug_eval_rhs_into`) re-primes instead
//! of being served stale CONST values. The SEGMENT section also re-runs when
//! the forcing epoch moves, which the driver bumps after each forcing refresh
//! on the scratch it keeps for the whole solve.
//!
//! The executor is split along the stages one call passes through. This
//! module owns the environment switches, the per-scratch executor state and
//! the per-call entry; `resolve` turns an operand into a scalar or a strided
//! view; `kernels` holds the strided loops those views feed; `fused` holds
//! the chunked fused-group executor together with the kernel dispatch tables
//! both executors expand; and `interp` is the instruction loop that drives
//! them.

use super::super::*;
use super::ir::*;
use super::prepared::Prepared;
pub(super) use super::prepared::UNSTORED;
use ndarray::ArrayD;
use smallvec::SmallVec;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

#[cfg(not(target_arch = "wasm32"))]
mod chain;
mod fused;
mod interp;
mod kernels;
mod lane_fold;
mod lanes;
#[cfg(not(target_arch = "wasm32"))]
mod par;
#[cfg(all(test, not(target_arch = "wasm32")))]
mod par_tests;
#[cfg(all(test, not(target_arch = "wasm32")))]
pub(super) use par::force_split;
#[cfg(not(target_arch = "wasm32"))]
mod plan;
#[cfg(not(target_arch = "wasm32"))]
mod pool;
mod resolve;
#[cfg(test)]
mod simd_tests;

// Re-exported at the `exec` boundary for the test-only reference executor
// (`super::refexec`), which shares the micro-op scalar semantics so the two
// executors cannot drift.
#[cfg(test)]
pub(super) use fused::eval_micro_op;
#[cfg(test)]
pub(super) use fused::fold_fused_op;

use fused::FCHUNK;
use interp::run_range;
// A large block copy splits across the pool on native targets.
#[cfg(not(target_arch = "wasm32"))]
use par::copy_strided as copy_strided_maybe_split;

/// The wasm build's block copy: always serial.
///
/// # Safety
/// As for [`kernels::copy_strided`].
#[cfg(target_arch = "wasm32")]
unsafe fn copy_strided_maybe_split(
    _call: usize,
    dst: *mut f64,
    dstr: &[i64],
    src: *const f64,
    sstr: &[i64],
    shape: &[usize],
) {
    unsafe { kernels::copy_strided(dst, dstr, src, sstr, shape) }
}

/// The current call's split width (always 1 on wasm).
fn call_ways(exec: &TapeExec) -> usize {
    #[cfg(not(target_arch = "wasm32"))]
    {
        exec.scratch.fscratch.workers.call_ways
    }
    #[cfg(target_arch = "wasm32")]
    {
        let _ = exec;
        1
    }
}
pub(super) use super::layout::dy_strides;
use resolve::{cm_strides, rm_strides};

// ---------------------------------------------------------------------------
// Device selection (read once and cached).
// ---------------------------------------------------------------------------

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

/// Select the clone, once: AVX2 where the CPU has it, the generic codegen
/// otherwise.
///
/// The AVX-512 clone is opt-in. Its loops run in 512-bit registers, and on
/// the Xeon cores this tier is measured on that lowers the core clock for the
/// whole call, the scalar pieces included (scan chains, gathers, the per-call
/// passes), which costs more than the wider lanes give back.
///
/// `ESS_TAPE_SIMD_DISABLE=1` forces the generic codegen and
/// `ESS_TAPE_SIMD_LEVEL=generic|avx2|avx512` chooses a level (one the CPU
/// lacks falls back to the next narrower): DEVICE selection, not strategy
/// selection — every level runs
/// the same program and is bit-identical (`simd_clone_bit_identity`), so
/// neither is a way to reach a different evaluator
/// (`esm-libraries-spec.md` §2.5.10).
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
        // `ESS_TAPE_SIMD_LEVEL=generic|avx2|avx512` (measurement aid; a level
        // the CPU lacks falls back). Unset = AVX2 where available.
        let cap = std::env::var("ESS_TAPE_SIMD_LEVEL").unwrap_or_default();
        if cap.eq_ignore_ascii_case("generic") {
            return SimdLevel::Generic;
        }
        #[cfg(target_arch = "x86_64")]
        {
            let allow512 = cap.eq_ignore_ascii_case("avx512");
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

// ---------------------------------------------------------------------------
// Executor state.
// ---------------------------------------------------------------------------

/// Per-scratch executor state: the slab and everything preallocated so a
/// steady-state call performs zero heap allocation.
pub(crate) struct TapeExec {
    /// Flat `f64` slab backing every storage bucket.
    slab: Vec<f64>,
    /// Per-slot flat offset into the slab (`usize::MAX` for never-defined
    /// slots, which no reachable instruction references): the program's own
    /// layout ([`Prepared::slot_off`]), or the current call plan's once one
    /// is built.
    slot_off: Vec<usize>,
    /// The published observeds: an export enters it the first time its
    /// `Export` runs, and later publishes overwrite it in place. Nothing in
    /// a call reads it; it is for the caller that asked for exports.
    pub(crate) obs: ArrMap,
    /// Export target arrays, preallocated and indexed like `prog.exports`:
    /// `Some` until the export's first publish moves it into `obs`, so no
    /// publish allocates.
    parked: Vec<Option<(String, ArrayD<f64>)>>,
    /// Pending `(resume_pc, skip)` records for taken `JmpIfZero` branches
    /// (the reference executor's discipline). Capacity preallocated.
    pending: Vec<(u32, u32)>,
    /// The decoded form of the scalar instructions (see
    /// [`interp::ScalarCode`]), for the slot layout of generation `layout`.
    scalar: interp::ScalarCode,
    /// Bumped whenever `slot_off` changes, so `scalar` is decoded again.
    layout: u64,
    /// Step 4 epochs: the parameter / forcing epochs the CONST resp. SEGMENT
    /// sections last primed under (0 = never primed; live epochs start at 1).
    /// Checked per call as two integer compares — see `run_tape_call`.
    primed_param_epoch: u64,
    primed_forcing_epoch: u64,
    /// The calling thread's scratch for straight-line instructions.
    scratch: Scratch,
    /// Per fused group: the resolved positions of its folded gathers whose
    /// subscripts the CONST or SEGMENT section defines, refilled each time
    /// those sections run.
    idx_tables: Vec<Vec<Option<fused::IndexTable>>>,
    /// The lane programs' chunk registers.
    lscratch: lanes::LaneScratch,
    /// Step 4 export demotion: `Export` instructions only execute when
    /// a caller explicitly requested them ([`TapeCtx::set_exports_active`]):
    /// nothing inside a call reads the published arrays. With no possible reader they are
    /// skipped (the exported values themselves are still computed — they are
    /// ordinary slots — only the publish memcpy is elided).
    exports_active: bool,
    /// Rule count, cached off the program for the per-call stats.
    pub(crate) n_taped: usize,
    /// Whether every call runs on the calling thread alone: no split, no
    /// fork-join on the process-wide pool. Set on a program's workspace
    /// (API_SPEC §5.8: a program evaluation starts no thread).
    serial: bool,
    /// Step 4b: the SIMD clone this executor runs its fused loops through,
    /// selected ONCE at executor construction (never per element).
    simd: SimdLevel,
    /// Estimated element-operations of one steady call, which sets how wide
    /// a call splits (see `par::call_ways`).
    #[cfg(not(target_arch = "wasm32"))]
    call_work: usize,
    #[cfg(not(target_arch = "wasm32"))]
    chain_scratch: chain::ChainScratch,
    /// The phases a threaded call runs in (see `plan`), built by the first
    /// call at a split width and kept while the width holds.
    #[cfg(not(target_arch = "wasm32"))]
    plan: Option<plan::CallPlan>,
    /// The scratch of each thread beside the calling one in a planned call,
    /// grown the first time a call forks wider.
    #[cfg(not(target_arch = "wasm32"))]
    peers: Vec<Scratch>,
    /// The execution context of each function this program calls
    /// ([`TapeProgram::funcs`]), made by its first call. A call runs on the
    /// calling thread ([`Instr::may_run_on_worker`]), one at a time.
    funcs: Vec<Option<Box<TapeCtx>>>,
}

/// One thread's mutable scratch for straight-line instructions (see
/// [`interp::exec_straight`]): the calling thread's lives in [`TapeExec`].
pub(super) struct Scratch {
    /// Step 4: chunk register file for fused groups
    /// (`max n_regs over specs × FCHUNK` doubles, recycled across groups).
    fregs: Vec<f64>,
    /// A fused group's resolved operands, sized for the largest group so a
    /// call never allocates.
    fscratch: fused::FusedScratch,
    /// The resolved parts of the assembly being split (native targets
    /// only), sized by the first split so steady calls do not allocate.
    #[cfg(not(target_arch = "wasm32"))]
    asm_parts: Vec<par::AsmPart>,
}

impl TapeExec {
    pub(crate) fn new(prog: &TapeProgram) -> Self {
        let slab = vec![0.0f64; prog.slab.total_elems];
        let obs: ArrMap = ArrMap::with_capacity_and_hasher(prog.exports.len(), Default::default());
        let parked = prog
            .exports
            .iter()
            .map(|(name, slot)| {
                let desc = &prog.tables.slots[*slot as usize];
                // The published array is logical: a column-major program's
                // box is stored reversed.
                let shape: Vec<usize> = if desc.scalar {
                    Vec::new()
                } else if prog.col_major {
                    desc.shape.iter().rev().copied().collect()
                } else {
                    desc.shape.to_vec()
                };
                Some((name.clone(), ArrayD::<f64>::zeros(IxDyn(&shape))))
            })
            .collect();
        let max_fregs = prog
            .fused
            .iter()
            .map(|f| f.n_regs as usize + f.n_load_regs as usize)
            .max()
            .unwrap_or(0);
        TapeExec {
            slab,
            slot_off: prog.prepared().slot_off.clone(),
            obs,
            parked,
            pending: Vec::with_capacity(16),
            scalar: interp::ScalarCode::default(),
            layout: 0,
            primed_param_epoch: 0,
            primed_forcing_epoch: 0,
            scratch: Scratch {
                fregs: vec![0.0f64; max_fregs * FCHUNK],
                fscratch: fused::FusedScratch::for_program(prog),
                #[cfg(not(target_arch = "wasm32"))]
                asm_parts: Vec::new(),
            },
            idx_tables: fused::index_tables_for(prog),
            lscratch: lanes::LaneScratch::for_program(prog),
            exports_active: false,
            n_taped: prog.rules.len(),
            serial: false,
            simd: simd_level(),
            #[cfg(not(target_arch = "wasm32"))]
            call_work: par::program_work(prog),
            #[cfg(not(target_arch = "wasm32"))]
            chain_scratch: chain::ChainScratch::default(),
            #[cfg(not(target_arch = "wasm32"))]
            plan: None,
            #[cfg(not(target_arch = "wasm32"))]
            peers: Vec::new(),
            funcs: (0..prog.funcs.len()).map(|_| None).collect(),
        }
    }
}

/// The compiled-tape context a [`super::super::RhsScratch`] carries. `None`
/// on a scratch means "legacy interpreter path".
/// Row-major mirror of the flat state vector for a program stored row-major
/// ([`TapeProgram::col_major`] false), refilled once per call for the
/// variables `mirror` marks (each column-major block transposed in place at
/// the SAME flat offset), so reads of state run over contiguous memory. Pure
/// data movement, so bit-identical to reading the strided view directly.
///
/// Kept beside the [`TapeExec`] rather than inside it: a call borrows it
/// shared (through [`Env`]) while the executor is borrowed mutably.
pub(in crate::simulate_array) struct StateMirror {
    /// The mirrored values. Empty when no variable needs it.
    state_rm: Vec<f64>,
    /// Per state variable: whether reads go through `state_rm`. False for a
    /// column-major program (its boxes ARE the state's layout) and for a
    /// variable whose two layouts are the same walk; those read the caller's
    /// state in place.
    mirror: Vec<bool>,
    /// The variables `mirror` marks, so a call's refill does not walk every
    /// state variable (a 0-d state model has one per state).
    mirror_vars: Vec<u32>,
}

impl StateMirror {
    fn new(prog: &TapeProgram) -> Self {
        let mirror: Vec<bool> = prog
            .state_vars
            .iter()
            // A function's state variables are its array arguments, which the
            // call resolves to the caller's row-major views.
            .map(|sv| !prog.is_function && !prog.col_major && !super::layout::order_free(&sv.shape))
            .collect();
        let n_state: usize = prog
            .state_vars
            .iter()
            .zip(&mirror)
            .filter(|(_, m)| **m)
            .map(|(sv, _)| sv.flat_offset + sv.shape.iter().product::<usize>().max(1))
            .max()
            .unwrap_or(0);
        StateMirror {
            state_rm: vec![0.0f64; n_state],
            mirror_vars: (0..mirror.len() as u32)
                .filter(|&i| mirror[i as usize])
                .collect(),
            mirror,
        }
    }
}

pub(in crate::simulate_array) struct TapeCtx {
    pub(crate) prog: Arc<TapeProgram>,
    pub(crate) exec: TapeExec,
    mirror: StateMirror,
    /// Step 4 epoch counters (see `run_tape_call`). The parameter epoch is
    /// bumped whenever the caller's params slice differs, bit for bit, from
    /// the one the last call saw (the slice is the only channel callers have,
    /// so it remains the epoch SOURCE); the forcing epoch is a driver-owned
    /// counter, bumped between segments when the live forcing buffer is
    /// refreshed, which re-runs only the SEGMENT section.
    param_epoch: u64,
    forcing_epoch: u64,
    /// The params slice the last call ran with (`None` before the first).
    last_params: Option<Vec<f64>>,
}

impl TapeCtx {
    pub(in crate::simulate_array) fn new(prog: Arc<TapeProgram>) -> Self {
        let exec = TapeExec::new(&prog);
        let mirror = StateMirror::new(&prog);
        TapeCtx {
            prog,
            exec,
            mirror,
            param_epoch: 0,
            forcing_epoch: 1,
            last_params: None,
        }
    }

    /// Invalidate the SEGMENT section: the driver calls this after refreshing
    /// the live forcing buffer between integration segments, keeping one warm
    /// executor for the whole solve (`driver::SolveScratches`). The next call
    /// re-runs the SEGMENT section, where the DISCRETE forcing loads live, and
    /// not the CONST one.
    pub(crate) fn bump_forcing_epoch(&mut self) {
        self.forcing_epoch += 1;
    }

    /// Run every call of this context on the calling thread alone.
    pub(crate) fn set_serial(&mut self) {
        self.exec.serial = true;
    }

    /// Forget the primed CONST and SEGMENT sections, so the next call runs
    /// both again: a call that latched a fault in them leaves values behind
    /// that a later call must not be served.
    pub(crate) fn invalidate_sections(&mut self) {
        self.last_params = None;
        self.exec.primed_param_epoch = 0;
        self.exec.primed_forcing_epoch = 0;
        for f in &mut self.exec.funcs {
            *f = None;
        }
    }

    /// Force `Export` instructions on/off (off by default; a harvesting
    /// scratch turns them on because it IS the reader).
    pub(crate) fn set_exports_active(&mut self, on: bool) {
        self.exec.exports_active = on;
    }

    /// The observed arrays the last call published.
    ///
    /// Complete only when the program was built to export every observed —
    /// which a `native` build is (see `compute_exports`) — and when the
    /// publishes are active.
    pub(in crate::simulate_array) fn exported_observeds(&self) -> &ArrMap {
        &self.exec.obs
    }
}

// ---------------------------------------------------------------------------
// The per-call entry.
// ---------------------------------------------------------------------------

/// Everything immutable an instruction may consult, bundled so the
/// interpreter loop can split-borrow the mutable executor pieces beside it.
struct Env<'a> {
    prog: &'a TapeProgram,
    /// The program's executor-side analyses ([`TapeProgram::prepared`]).
    prep: &'a Prepared,
    forcing: ForcingView<'a>,
    state: &'a [f64],
    /// Row-major per-variable mirror of `state` (see [`StateMirror`]).
    state_rm: &'a [f64],
    /// Per state variable: read through `state_rm` (see [`StateMirror`]).
    mirror: &'a [bool],
    params: &'a [f64],
    t: f64,
    /// The model's declared-name set (see `EvalCtx::declared`), for the
    /// forcing load's missing-entry fault.
    declared: &'a HashSet<String>,
    /// In a function program ([`TapeProgram::is_function`]): where each of
    /// its state variables (the running call's array arguments) starts.
    /// Empty otherwise.
    arrays: &'a [*const f64],
}

/// [`Instr::LoadForcing`]'s element semantics, shared by the fast and the
/// reference executor: `lookup_variable`'s forcing arm written into `dst`.
///
/// The entry is copied in row-major order whatever its memory layout (an
/// `ArrayD` iterates logically), and a 0-d entry is rounded to the active
/// precision as the lookup's scalar arm rounds it; an array entry is not,
/// because it was rounded where it entered the problem. A missing entry
/// latches the lookup's own fault, and an entry of another shape the
/// mismatch fault; both leave `dst` `NaN`.
///
/// `reversed` is a column-major program's load ([`TapeProgram::col_major`]):
/// `dst` is the entry's box axis-reversed, so the entry is copied in the
/// row-major order of its reversed view.
pub(in crate::simulate_array::tape) fn load_forcing(
    fr: &ForcingRef,
    buffer: &HashMap<String, ArrayD<f64>>,
    declared: &HashSet<String>,
    reversed: bool,
    dst: &mut [f64],
) {
    let Some(a) = buffer.get(&fr.name) else {
        latch_unbound_read(&fr.name, declared);
        dst.fill(f64::NAN);
        return;
    };
    if a.shape() != &fr.shape[..] {
        latch_forcing_shape_mismatch(&fr.name, &fr.shape, a.shape());
        dst.fill(f64::NAN);
        return;
    }
    if fr.shape.is_empty() {
        dst[0] = crate::precision::active().round(a[IxDyn(&[])]);
    } else if reversed && !super::layout::order_free(&fr.shape) {
        for (d, v) in dst.iter_mut().zip(a.view().reversed_axes().iter()) {
            *d = *v;
        }
    } else if let Some(src) = a.as_slice() {
        dst.copy_from_slice(src);
    } else {
        for (d, v) in dst.iter_mut().zip(a.iter()) {
            *d = *v;
        }
    }
}

/// Where a call's forcing loads read from.
#[derive(Clone, Copy)]
pub(in crate::simulate_array) enum ForcingView<'a> {
    /// The forcing buffer, by name (row-major arrays).
    Map(&'a HashMap<String, ArrayD<f64>>),
    /// A forcing set's buffers (column-major, first index fastest), with the
    /// buffer each of the program's [`ForcingRef`]s reads, resolved when the
    /// program was built against the set's slots.
    Slots {
        bufs: &'a [Arc<[f64]>],
        slot_of: &'a [u32],
    },
}

/// [`Instr::LoadForcing`] from a forcing set's buffer `src`, column-major over
/// `fr.shape` and of its length (both checked when the set was made). The
/// same values [`load_forcing`] writes from a row-major entry of the same
/// field: a column-major program's box is the column-major order itself, a
/// row-major program's is transposed on the way, and a 0-d entry is rounded
/// to the active precision.
pub(in crate::simulate_array::tape) fn load_forcing_slot(
    fr: &ForcingRef,
    src: &[f64],
    col_major: bool,
    dst: &mut [f64],
) {
    if fr.shape.is_empty() {
        dst[0] = crate::precision::active().round(src[0]);
    } else if col_major || super::layout::order_free(&fr.shape) {
        dst.copy_from_slice(src);
    } else {
        let rm = rm_strides(&fr.shape);
        let cm = cm_strides(&fr.shape);
        // SAFETY: `dst` and `src` both hold the box's element count, and the
        // strides address that box.
        unsafe { kernels::copy_strided(dst.as_mut_ptr(), &rm, src.as_ptr(), &cm, &fr.shape) }
    }
}

/// The number of `f64`s [`load_forcing`] writes for `fr`: one for a 0-d entry,
/// else the element count of its box (zero for an empty one).
pub(in crate::simulate_array::tape) fn forcing_len(fr: &ForcingRef) -> usize {
    if fr.shape.is_empty() {
        1
    } else {
        fr.shape.iter().product()
    }
}

/// Run the call's continuous instructions `range`: as a plan of phases when
/// the call splits and publishes nothing (see `plan`), else through the
/// instruction loop.
fn run_continuous(env: &Env, range: std::ops::Range<usize>, exec: &mut TapeExec, dy: &mut [f64]) {
    #[cfg(not(target_arch = "wasm32"))]
    {
        let ways = call_ways(exec);
        if ways > 1 && !exec.exports_active {
            if !exec.plan.as_ref().is_some_and(|p| p.fits(&range, ways)) {
                exec.plan = plan::CallPlan::build(env.prog, env.prep, range.clone(), ways);
                // Every later call, planned or not, runs in the plan's
                // layout: the slots it moved hold no value across calls.
                if let Some(p) = &exec.plan {
                    if exec.slab.len() < p.slab_len {
                        exec.slab.resize(p.slab_len, 0.0);
                    }
                    exec.slot_off.clone_from(&p.slot_off);
                    // The scalar code holds slab offsets of the old layout.
                    exec.layout += 1;
                }
            }
            if let Some(p) = exec.plan.take() {
                plan::run_plan(&p, env, exec, dy);
                exec.plan = Some(p);
                return;
            }
        }
    }
    run_range(env, range, exec, dy);
}

#[cfg(test)]
thread_local! {
    static SECTION_PRIMES: std::cell::Cell<(u64, u64)> = const { std::cell::Cell::new((0, 0)) };
}

/// Test hook: how many times this thread's tape calls ran the CONST and
/// SEGMENT sections together, and how many ran the SEGMENT section alone
/// (a forcing-epoch bump).
#[cfg(test)]
pub(crate) fn section_primes() -> (u64, u64) {
    SECTION_PRIMES.with(std::cell::Cell::get)
}

/// Whether `params` is, bit for bit, the slice `last` recorded (so `-0.0`
/// and `0.0` differ and a NaN equals only the same NaN).
/// Run function program `ctx.prog` ([`TapeProgram::is_function`]) for one
/// [`Instr::Call`]: its state variables read `arrays` in place, its
/// parameters are `scalars`. Returns where its result (its one export)
/// starts in its slab. The function writes no `dy` and publishes nothing; it
/// runs on the calling thread.
pub(super) fn run_function(
    ctx: &mut TapeCtx,
    arrays: &[*const f64],
    scalars: &[f64],
    t: f64,
    forcing: ForcingView,
    declared: &HashSet<String>,
) -> *const f64 {
    match &mut ctx.last_params {
        Some(last) if same_params(last, scalars) => {}
        slot => {
            let last = slot.get_or_insert_with(Vec::new);
            last.clear();
            last.extend_from_slice(scalars);
            ctx.param_epoch += 1;
        }
    }
    let param_epoch = ctx.param_epoch;
    let TapeCtx {
        prog, exec, mirror, ..
    } = ctx;
    let prog = &**prog;
    let prep = prog.prepared();
    let env = Env {
        prog,
        prep,
        forcing,
        state: &[],
        state_rm: &mirror.state_rm,
        mirror: &mirror.mirror,
        params: scalars,
        t,
        declared,
        arrays,
    };
    let prime_end = (prog.n_const + prog.n_segment) as usize;
    let mut no_dy: [f64; 0] = [];
    if exec.primed_param_epoch != param_epoch {
        exec.primed_param_epoch = param_epoch;
        interp::run_range(&env, 0..prime_end, exec, &mut no_dy);
        refill_primed(prog, exec);
    }
    interp::run_range(&env, prime_end..prog.instrs.len(), exec, &mut no_dy);
    let (_, result) = prog.exports[0];
    exec.slab.as_ptr().wrapping_add(exec.slot_off[result as usize])
}

fn same_params(last: &[f64], params: &[f64]) -> bool {
    last.len() == params.len()
        && last
            .iter()
            .zip(params)
            .all(|(a, b)| a.to_bits() == b.to_bits())
}

/// Rebuild what the CONST and SEGMENT sections feed and later calls read
/// from tables of their own (the folded gathers' positions, the compacted
/// chains' tuples), after those sections ran.
fn refill_primed(prog: &TapeProgram, exec: &mut TapeExec) {
    let slab = resolve::Slab::new(&mut exec.slab, &exec.slot_off, &prog.tables.slots);
    // SAFETY: the sections ran on this thread, and nothing else touches the
    // slab between calls.
    unsafe { fused::refill_index_tables(&mut exec.idx_tables, slab) };
    #[cfg(not(target_arch = "wasm32"))]
    // SAFETY: as above.
    unsafe {
        chain::refill_compact(
            &prog.prepared().seg_chains,
            &mut exec.chain_scratch,
            prog,
            slab,
        )
    };
}

/// Execute one RHS call through the tape: prime the CONST + SEGMENT sections
/// if needed (first call of the scratch, or a changed parameter vector), then
/// run the CONTINUOUS section. Writes every element of `dy` (zero where no
/// rule writes it) and bumps `stats`.
/// The caller supplies the shared per-call inputs as an [`RhsCall`] (the
/// remaining [`Env`] fields — the program and the row-major state mirror —
/// are owned by the tape context).
pub(in crate::simulate_array) fn run_tape_call(
    ctx: &mut TapeCtx,
    call: &RhsCall,
    dy: &mut [f64],
    stats: &mut RhsStats,
) {
    let &RhsCall {
        state,
        params,
        forcing,
        t,
        declared,
        ..
    } = call;
    let forcing = forcing.borrow();
    let inputs = CallInputs {
        state,
        params,
        forcing: ForcingView::Map(&forcing),
        forcing_epoch: None,
        t,
        declared,
    };
    run_tape_inputs(ctx, &inputs, dy, true);
    stats.taped_rules += ctx.exec.n_taped;
}

/// The per-call inputs of [`run_tape_inputs`]: the state vector the program's
/// state layout addresses, the positional parameters, the forcing buffer's
/// entries, the time, and the declared-name set for the forcing fault.
pub(in crate::simulate_array) struct CallInputs<'a> {
    pub(in crate::simulate_array) state: &'a [f64],
    pub(in crate::simulate_array) params: &'a [f64],
    pub(in crate::simulate_array) forcing: ForcingView<'a>,
    /// The epoch of the forcing the call reads, when the caller names one
    /// (a forcing set's): the SEGMENT section re-runs when it differs from
    /// the epoch the context last primed under. `None` keeps the context's
    /// own counter ([`TapeCtx::bump_forcing_epoch`]).
    pub(in crate::simulate_array) forcing_epoch: Option<u64>,
    pub(in crate::simulate_array) t: f64,
    pub(in crate::simulate_array) declared: &'a HashSet<String>,
}

/// [`run_tape_call`]'s body. With `zero_dy` the elements of `dy` no rule
/// writes are zeroed first; without it they are left as the caller holds them,
/// which is what a range-restricted program promises (API_SPEC §5.8: only the
/// owned rows of the written variables are touched).
pub(in crate::simulate_array) fn run_tape_inputs(
    ctx: &mut TapeCtx,
    inputs: &CallInputs,
    dy: &mut [f64],
    zero_dy: bool,
) {
    let &CallInputs {
        state,
        params,
        forcing,
        forcing_epoch,
        t,
        declared,
    } = inputs;
    if let Some(epoch) = forcing_epoch {
        ctx.forcing_epoch = epoch;
    }
    // Parameter epoch: a params slice that differs bit for bit from the last
    // one bumps it (the negative-control test in `tests/tape_exec.rs` guards
    // this: bypassing it serves stale CONST values). The kept copy only
    // reallocates when the slice grows.
    match &mut ctx.last_params {
        Some(last) if same_params(last, params) => {}
        slot => {
            let last = slot.get_or_insert_with(Vec::new);
            last.clear();
            last.extend_from_slice(params);
            ctx.param_epoch += 1;
        }
    }
    let (param_epoch, forcing_epoch) = (ctx.param_epoch, ctx.forcing_epoch);
    let TapeCtx {
        prog, exec, mirror, ..
    } = ctx;
    let prog = &**prog;
    #[cfg(not(target_arch = "wasm32"))]
    {
        let (ways, threads) = if exec.serial {
            (1, 1)
        } else {
            (par::call_ways(exec.call_work), par::thread_budget())
        };
        exec.scratch.fscratch.workers.call_ways = ways;
        exec.scratch.fscratch.workers.threads = threads;
    }
    let prep = prog.prepared();
    // Every position the program writes lies in `dy`; the writes below are
    // unchecked, so this is checked once per call, in every build.
    assert!(
        dy.len() >= prep.dy.min_len,
        "dy has {} elements, but the program writes {}",
        dy.len(),
        prep.dy.min_len
    );
    // Zero what no rule writes; every other element is overwritten below.
    if zero_dy {
        for (a, b) in prep.dy.zero_ranges(dy.len()) {
            dy[a..b].fill(0.0);
        }
    }
    // Refill the row-major state mirror: one strided pass per mirrored
    // variable block (column-major flat -> row-major at the same offset).
    let ways = call_ways(exec);
    for &i in &mirror.mirror_vars {
        let sv = &prog.state_vars[i as usize];
        let rm = rm_strides(&sv.shape);
        let cm = cm_strides(&sv.shape);
        unsafe {
            copy_strided_maybe_split(
                ways,
                mirror.state_rm.as_mut_ptr().add(sv.flat_offset),
                &rm,
                state.as_ptr().add(sv.flat_offset),
                &cm,
                &sv.shape,
            );
        }
    }
    let env = Env {
        prog,
        prep,
        forcing,
        state,
        state_rm: &mirror.state_rm,
        mirror: &mirror.mirror,
        params,
        t,
        declared,
        arrays: &[],
    };

    // Section invalidation: two integer compares per steady-state call.
    // CONST depends on the parameter epoch alone; SEGMENT additionally on the
    // forcing epoch (a forcing refresh re-runs only the SEGMENT section).
    let const_end = prog.n_const as usize;
    let prime_end = (prog.n_const + prog.n_segment) as usize;
    if exec.primed_param_epoch != param_epoch {
        exec.primed_param_epoch = param_epoch;
        exec.primed_forcing_epoch = forcing_epoch;
        #[cfg(test)]
        SECTION_PRIMES.with(|c| c.set((c.get().0 + 1, c.get().1)));
        run_range(&env, 0..prime_end, exec, dy);
        refill_primed(prog, exec);
    } else if exec.primed_forcing_epoch != forcing_epoch {
        exec.primed_forcing_epoch = forcing_epoch;
        #[cfg(test)]
        SECTION_PRIMES.with(|c| c.set((c.get().0, c.get().1 + 1)));
        run_range(&env, const_end..prime_end, exec, dy);
        refill_primed(prog, exec);
    }
    // With nothing reading the published observeds, the output-only tail of
    // the section is not run.
    let end = if exec.exports_active {
        prog.instrs.len()
    } else {
        prime_end + prog.n_rhs as usize
    };
    run_continuous(&env, prime_end..end, exec, dy);
}
