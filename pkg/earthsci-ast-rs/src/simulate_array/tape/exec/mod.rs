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
//! **Sections/invalidation**: the CONST section runs once per scratch and
//! parameter vector, guarded by a `bind_params`-style parameter-generation
//! hash mirroring `cse.rs`: a caller that reuses one scratch across a
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
//! both executors expand; `interp` is the instruction loop that drives them;
//! and `oracle` is the per-cell fallback evaluator, kept apart because the
//! test-only reference executor shares it.

use super::super::*;
use super::ir::*;
use ndarray::ArrayD;
use smallvec::SmallVec;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

#[cfg(not(target_arch = "wasm32"))]
mod chain;
mod fused;
mod interp;
mod kernels;
mod lanes;
mod oracle;
#[cfg(not(target_arch = "wasm32"))]
mod par;
#[cfg(all(test, not(target_arch = "wasm32")))]
mod par_tests;
#[cfg(all(test, not(target_arch = "wasm32")))]
pub(super) use par::force_split;
#[cfg(not(target_arch = "wasm32"))]
mod pool;
mod resolve;
#[cfg(test)]
mod simd_tests;

// Re-exported at the `exec` boundary for the test-only reference executor
// (`super::refexec`), which shares the micro-op scalar semantics and the
// per-cell fallback oracle so the two executors cannot drift.
#[cfg(test)]
pub(super) use fused::eval_micro_op;
#[cfg(test)]
pub(super) use fused::fold_fused_op;
#[cfg(test)]
pub(super) use oracle::run_rhs_oracle;

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
        exec.fscratch.workers.call_ways
    }
    #[cfg(target_arch = "wasm32")]
    {
        let _ = exec;
        1
    }
}
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
    /// slots, which no reachable instruction references).
    slot_off: Vec<usize>,
    /// Runtime observed map: holds an export only while it is PUBLISHED (its
    /// `Export` has run in the current execution of its section); fallback
    /// observed rules insert their own outputs.
    pub(crate) obs: ArrMap,
    /// Export target arrays, preallocated and indexed like `prog.exports`:
    /// `Some` while the export is unpublished, `None` while its entry lives in
    /// `obs`. An `Export` moves the entry into `obs` and memcpys into it, and
    /// `run_range` moves it back out before re-running its section, so a read
    /// that precedes the publish finds no entry and FAULTS (CONFORMANCE_SPEC
    /// §5.23.1(2), §5.19.4) instead of reading the zero prealloc or the
    /// previous call's value. Moving an entry never allocates.
    parked: Vec<Option<(String, ArrayD<f64>)>>,
    /// `(pc, export)` for every `Export` instruction, in program order.
    export_sites: Vec<(usize, u32)>,
    /// Pending `(resume_pc, skip)` records for taken `JmpIfZero` branches
    /// (the reference executor's discipline). Capacity preallocated.
    pending: Vec<(u32, u32)>,
    /// Row-major mirror of the flat state vector for a program stored
    /// row-major ([`TapeProgram::col_major`] false), refilled once per call
    /// for the variables `mirror` marks (each column-major block transposed
    /// in place at the SAME flat offset), so reads of state run over
    /// contiguous memory. Pure data movement, so bit-identical to reading the
    /// strided view directly. Empty when no variable needs it.
    state_rm: Vec<f64>,
    /// Per state variable: whether reads go through `state_rm`. False for a
    /// column-major program (its boxes ARE the state's layout) and for a
    /// variable whose two layouts are the same walk; those read the caller's
    /// state in place.
    mirror: Vec<bool>,
    /// The variables `mirror` marks, so a call's refill does not walk every
    /// state variable (a 0-d state model has one per state).
    mirror_vars: Vec<u32>,
    /// The `[start, end)` ranges of `dy` no `DyWrite` is certain to write,
    /// which each call zeroes, for a `dy` of `dy_zero_len` elements
    /// (`usize::MAX` until the first call computes them).
    dy_zero: Vec<(usize, usize)>,
    dy_zero_len: usize,
    /// Per slot: the `dy` offset the slot is written to directly instead of
    /// the slab, or `usize::MAX` (see [`dy_homes`]); computed with
    /// `dy_zero`.
    dy_home: Vec<usize>,
    /// `dy_home` for a call that publishes no observeds: a fused output
    /// that only the output-only tail reads is [`UNSTORED`] (see
    /// [`quiet_homes`]).
    dy_home_quiet: Vec<usize>,
    /// Per gather plan: `true` when its per-axis segments tile the whole
    /// output box, so the ghost zero-fill can be skipped (every element is
    /// overwritten by a segment copy).
    plan_full: Vec<bool>,
    /// Per `makearray` assembly: `true` when its regions cover the whole
    /// output box, so its zero fill can be skipped (every element is
    /// overwritten by a part).
    asm_covered: Vec<bool>,
    /// The resolved parts of the assembly being split (native targets
    /// only), sized by the first split so steady calls do not allocate.
    #[cfg(not(target_arch = "wasm32"))]
    asm_parts: Vec<par::AsmPart>,
    /// Step 4 epochs: the parameter / forcing epochs the CONST resp. SEGMENT
    /// sections last primed under (0 = never primed; live epochs start at 1).
    /// Checked per call as two integer compares — see `run_tape_call`.
    primed_param_epoch: u64,
    primed_forcing_epoch: u64,
    /// Step 4: chunk register file for fused groups
    /// (`max n_regs over specs × FCHUNK` doubles, recycled across groups).
    fregs: Vec<f64>,
    /// A fused group's resolved operands, sized for the largest group so a
    /// call never allocates.
    fscratch: fused::FusedScratch,
    /// Per fused group: the resolved positions of its folded gathers whose
    /// subscripts the CONST or SEGMENT section defines, refilled each time
    /// those sections run.
    idx_tables: Vec<Vec<Option<fused::IndexTable>>>,
    /// The lane programs' chunk registers.
    lscratch: lanes::LaneScratch,
    /// Step 4 export demotion: `Export` instructions only execute when
    /// something can read the published arrays — a fallback rule is present,
    /// or a caller explicitly requested them
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
    /// Estimated element-operations of one steady call, which sets how wide
    /// a call splits (see `par::call_ways`).
    #[cfg(not(target_arch = "wasm32"))]
    call_work: usize,
    /// The continuous section's segmented reductions that split together
    /// with the work around them (see `chain`), in program order.
    #[cfg(not(target_arch = "wasm32"))]
    seg_chains: Vec<chain::SegChain>,
    #[cfg(not(target_arch = "wasm32"))]
    chain_scratch: chain::ChainScratch,
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
        let obs: ArrMap = ArrMap::with_capacity_and_hasher(prog.exports.len(), Default::default());
        let parked = prog
            .exports
            .iter()
            .map(|(name, slot)| {
                let desc = &prog.slots[*slot as usize];
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
        let export_sites = prog
            .instrs
            .iter()
            .enumerate()
            .filter_map(|(pc, i)| match i {
                Instr::Export { export, .. } => Some((pc, *export)),
                _ => None,
            })
            .collect();
        let n_fallback = prog
            .rules
            .iter()
            .filter(|r| matches!(r.status, RuleStatus::Fallback(_)))
            .count();
        let mirror: Vec<bool> = prog
            .state_vars
            .iter()
            .map(|sv| !prog.col_major && !super::layout::order_free(&sv.shape))
            .collect();
        let n_state: usize = prog
            .state_vars
            .iter()
            .zip(&mirror)
            .filter(|(_, m)| **m)
            .map(|(sv, _)| sv.flat_offset + sv.shape.iter().product::<usize>().max(1))
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
        #[cfg(not(target_arch = "wasm32"))]
        let seg_chains = chain::seg_chains(prog, &slot_off);
        TapeExec {
            slab,
            slot_off,
            obs,
            parked,
            export_sites,
            pending: Vec::with_capacity(16),
            state_rm: vec![0.0f64; n_state],
            mirror_vars: (0..mirror.len() as u32)
                .filter(|&i| mirror[i as usize])
                .collect(),
            mirror,
            dy_zero: Vec::new(),
            dy_zero_len: usize::MAX,
            dy_home: Vec::new(),
            dy_home_quiet: Vec::new(),
            plan_full,
            asm_covered: assemblies_covered(prog),
            #[cfg(not(target_arch = "wasm32"))]
            asm_parts: Vec::new(),
            primed_param_epoch: 0,
            primed_forcing_epoch: 0,
            fregs: vec![0.0f64; max_fregs * FCHUNK],
            fscratch: fused::FusedScratch::for_program(prog),
            idx_tables: fused::index_tables_for(prog),
            lscratch: lanes::LaneScratch::for_program(prog),
            exports_active: n_fallback > 0,
            n_taped: prog.rules.len() - n_fallback,
            n_fallback,
            simd: simd_level(),
            #[cfg(not(target_arch = "wasm32"))]
            call_work: par::program_work(prog),
            #[cfg(not(target_arch = "wasm32"))]
            seg_chains,
            #[cfg(not(target_arch = "wasm32"))]
            chain_scratch: chain::ChainScratch::default(),
        }
    }
}

/// Per assembly of `prog`, whether its regions cover every element of the box
/// it assembles (for every `Assemble` that uses it).
fn assemblies_covered(prog: &TapeProgram) -> Vec<bool> {
    let mut covered = vec![true; prog.assemblies.len()];
    for ins in &prog.instrs {
        let Instr::Assemble { table, out } = ins else {
            continue;
        };
        let shape = &prog.slots[*out as usize].shape;
        let rm = rm_strides(shape);
        let mut hit = vec![false; shape.iter().product::<usize>().max(1)];
        for (_, region) in &prog.assemblies[*table as usize].parts {
            let spec = &prog.regions[*region as usize];
            let n: usize = spec.shape.iter().product();
            let mut idx: DimU = SmallVec::from_elem(0, spec.shape.len());
            for _ in 0..n {
                let flat: i64 = (0..idx.len())
                    .map(|d| rm[d] * (spec.dest_lo[d] + idx[d]) as i64)
                    .sum();
                hit[flat as usize] = true;
                for d in (0..idx.len()).rev() {
                    idx[d] += 1;
                    if idx[d] < spec.shape[d] {
                        break;
                    }
                    idx[d] = 0;
                }
            }
        }
        covered[*table as usize] &= hit.iter().all(|&h| h);
    }
    covered
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
    pub(in crate::simulate_array) fn new(
        prog: Rc<TapeProgram>,
        observed_rules: Rc<Vec<AlgebraicRule>>,
    ) -> Self {
        let exec = TapeExec::new(&prog);
        TapeCtx {
            prog,
            observed_rules,
            exec,
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

    /// Force `Export` instructions on/off (production derives this from the
    /// fallback count; a harvesting scratch turns them on because it IS the
    /// reader).
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
    /// Per state variable: read through `state_rm` (see `TapeExec::mirror`).
    mirror: &'a [bool],
    params: &'a [f64],
    t: f64,
    /// The model's const-array registry (§5.5.5), for the fallback arms that
    /// re-enter the per-cell oracle.
    const_arrays: &'a ConstArrayScope,
    /// The inline-`const`-literal memo (see `EvalCtx::const_lits`). The fallback
    /// arms are exactly where a transcribed lookup table is gathered per cell,
    /// so the tape's oracle re-entry carries it.
    const_lits: &'a ConstLitMemo,
    /// The model's declared-name set (see `EvalCtx::declared`), likewise for
    /// the fallback arms.
    declared: &'a HashSet<String>,
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
            const_lits: Some(self.const_lits),
            const_arrays: self.const_arrays,
            declared: self.declared,
        }
    }
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

/// The number of `f64`s [`load_forcing`] writes for `fr`: one for a 0-d entry,
/// else the element count of its box (zero for an empty one).
pub(in crate::simulate_array::tape) fn forcing_len(fr: &ForcingRef) -> usize {
    if fr.shape.is_empty() {
        1
    } else {
        fr.shape.iter().product()
    }
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
fn same_params(last: &[f64], params: &[f64]) -> bool {
    last.len() == params.len()
        && last
            .iter()
            .zip(params)
            .all(|(a, b)| a.to_bits() == b.to_bits())
}

/// The `[start, end)` ranges of a `dy` of `n` elements that no `DyWrite` of
/// `prog` is certain to write on every call: everything when a fallback rule
/// may write it through the interpreter, else the complement of the writes
/// in the CONTINUOUS section outside any conditional region (a `JmpIfZero`
/// branch or a sweep body may not run).
fn dy_zero_ranges(prog: &TapeProgram, n: usize, n_fallback: usize) -> Vec<(usize, usize)> {
    if n_fallback > 0 {
        return vec![(0, n)];
    }
    let cont = prog.section_range(Cadence::Continuous);
    let conditional = conditional_mask(prog);
    let mut written = vec![false; n];
    for pc in cont {
        if conditional[pc] {
            continue;
        }
        let write = match &prog.instrs[pc] {
            Instr::DyWrite { write } => write,
            // A lane program writes each of its lanes' positions.
            Instr::Lanes { spec } => {
                let ls = &prog.lanes[*spec as usize];
                for w in &ls.writes {
                    if let LaneDst::Dy(pos) = &w.dst {
                        for l in 0..ls.lanes as usize {
                            written[pos.at(l) as usize] = true;
                        }
                    }
                }
                continue;
            }
            _ => continue,
        };
        let w = &prog.dy_writes[*write as usize];
        if let Some(pos) = &w.scatter {
            for &p in pos {
                written[p] = true;
            }
        } else if let Some(flat) = w.scalar_flat {
            written[flat] = true;
        } else {
            let sv = &prog.state_vars[w.var as usize];
            let shape = &prog.slots[w.slot as usize].shape;
            let st = dy_strides(prog, &sv.shape);
            let total: usize = shape.iter().product();
            let nd = shape.len();
            let mut idx: SmallVec<[usize; 4]> = SmallVec::from_elem(0, nd);
            for _ in 0..total {
                let mut off = sv.flat_offset;
                for d in 0..nd {
                    off += (w.dest_lo[d] + idx[d]) * st[d] as usize;
                }
                written[off] = true;
                let mut d = nd;
                while d > 0 {
                    d -= 1;
                    idx[d] += 1;
                    if idx[d] < shape[d] {
                        break;
                    }
                    idx[d] = 0;
                }
            }
        }
    }
    let mut ranges = Vec::new();
    let mut k = 0;
    while k < n {
        if written[k] {
            k += 1;
            continue;
        }
        let start = k;
        while k < n && !written[k] {
            k += 1;
        }
        ranges.push((start, k));
    }
    ranges
}

/// Per instruction: whether it sits in a region that may not run on a call
/// (a `JmpIfZero` branch or a sweep body).
fn conditional_mask(prog: &TapeProgram) -> Vec<bool> {
    let mut conditional = vec![false; prog.instrs.len()];
    for (pc, i) in prog.instrs.iter().enumerate() {
        let len = match i {
            Instr::JmpIfZero {
                n_true, n_false, ..
            } => (*n_true + *n_false) as usize,
            Instr::Sweep { spec } => prog.sweeps[*spec as usize].body_len as usize,
            _ => 0,
        };
        let end = (pc + 1 + len).min(conditional.len());
        conditional[pc + 1..end].fill(true);
    }
    conditional
}

/// Per slot, the `dy` offset a fused group writes it to directly, or
/// `usize::MAX` for the slab: a fused output whose only reader is one
/// whole-box `DyWrite` onto a CONTIGUOUS run of a `dy` of `n` elements, both
/// in the CONTINUOUS section and outside any conditional region. The group
/// then stores the derivative where the `DyWrite` would have copied it (the
/// same values, one pass fewer), and that `DyWrite` does nothing.
fn dy_homes(prog: &TapeProgram, n: usize) -> Vec<usize> {
    let mut home = vec![usize::MAX; prog.slots.len()];
    let tables = prog.tables();
    let mut readers = vec![0u32; prog.slots.len()];
    let mut defs = vec![0u32; prog.slots.len()];
    let mut def_pc = vec![usize::MAX; prog.slots.len()];
    for (pc, i) in prog.instrs.iter().enumerate() {
        i.for_each_read(&tables, |s| readers[s as usize] += 1);
        i.for_each_def(&tables, |s| {
            defs[s as usize] += 1;
            def_pc[s as usize] = pc;
        });
    }
    let cont = prog.section_range(Cadence::Continuous);
    let conditional = conditional_mask(prog);
    for pc in cont.clone() {
        let Instr::DyWrite { write } = &prog.instrs[pc] else {
            continue;
        };
        let w = &prog.dy_writes[*write as usize];
        let s = w.slot as usize;
        if conditional[pc] || w.scatter.is_some() || w.scalar_flat.is_some() {
            continue;
        }
        if readers[s] != 1 || defs[s] != 1 || !cont.contains(&def_pc[s]) || conditional[def_pc[s]] {
            continue;
        }
        let Instr::Fused { spec } = &prog.instrs[def_pc[s]] else {
            continue;
        };
        let fs = &prog.fused[*spec as usize];
        // A stored output over the group's box, or an absorbed reduction's
        // accumulator (folded in place, so straight into `dy`).
        let desc = &prog.slots[s];
        let fits = match &fs.reduce {
            Some(r) if r.out as usize == s => desc.elems() == r.n_inner,
            _ => fs.outputs.iter().any(|&(_, o)| o as usize == s) && desc.shape[..] == fs.shape[..],
        };
        if desc.scalar || !fits {
            continue;
        }
        let sv = &prog.state_vars[w.var as usize];
        let st = dy_strides(prog, &sv.shape);
        let rm = rm_strides(&desc.shape);
        let contiguous = (0..desc.shape.len()).all(|d| desc.shape[d] <= 1 || st[d] == rm[d]);
        let mut off = sv.flat_offset;
        for d in 0..desc.shape.len() {
            off += w.dest_lo[d] * st[d] as usize;
        }
        if contiguous && off + desc.elems() <= n {
            home[s] = off;
        }
    }
    home
}

/// A [`dy_homes`] entry: the fused output is not stored at all.
pub(super) const UNSTORED: usize = usize::MAX - 1;

/// `home` with [`UNSTORED`] for every output of a CONTINUOUS fused group
/// whose readers all sit in the section's output-only tail (past
/// [`TapeProgram::n_rhs`]), which a call that publishes no observeds does
/// not run: the group still computes the value (a later micro-op may need
/// it) but writes it nowhere.
fn quiet_homes(prog: &TapeProgram, home: &[usize]) -> Vec<usize> {
    let mut quiet = home.to_vec();
    let rhs_end = (prog.n_const + prog.n_segment + prog.n_rhs) as usize;
    let cont = prog.section_range(Cadence::Continuous);
    let tables = prog.tables();
    // Per slot: whether any instruction a quiet call runs reads it.
    let mut read_early = vec![false; prog.slots.len()];
    for i in prog.instrs.iter().take(rhs_end) {
        i.for_each_read(&tables, |s| read_early[s as usize] = true);
    }
    for pc in cont.start..rhs_end.min(cont.end) {
        let Instr::Fused { spec } = &prog.instrs[pc] else {
            continue;
        };
        for &(_, slot) in &prog.fused[*spec as usize].outputs {
            let s = slot as usize;
            if !read_early[s] && home[s] == usize::MAX {
                quiet[s] = UNSTORED;
            }
        }
    }
    quiet
}

/// The strides of a state variable's `dy` (and state) block over `shape`,
/// the box the program stores it as: row-major over a column-major
/// program's reversed box, column-major over a row-major program's.
pub(super) fn dy_strides(prog: &TapeProgram, shape: &[usize]) -> DimI {
    if prog.col_major {
        rm_strides(shape)
    } else {
        cm_strides(shape)
    }
}

/// Execute one RHS call through the tape: prime the CONST + SEGMENT sections
/// if needed (first call of the scratch, or a changed parameter vector), then
/// run the CONTINUOUS section. Writes every element of `dy` (zero where no
/// rule writes it) and bumps `stats`.
/// The caller supplies the shared per-call inputs as an [`RhsCall`] (the
/// remaining [`Env`] fields — the program, the FULL observed-rule list, the
/// intra-call ring registry, and the row-major state mirror — are owned by
/// the tape context or created inside the call).
pub(in crate::simulate_array) fn run_tape_call(
    ctx: &mut TapeCtx,
    call: &RhsCall,
    state_arrays: &ArrMap,
    const_arrays: &ConstArrayScope,
    const_lits: &ConstLitMemo,
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
        declared,
        ..
    } = call;
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
    let prog = &*ctx.prog;
    let exec = &mut ctx.exec;
    #[cfg(not(target_arch = "wasm32"))]
    {
        exec.fscratch.workers.call_ways = par::call_ways(exec.call_work);
        exec.fscratch.workers.threads = par::thread_budget();
    }
    // Zero what no rule writes; every other element is overwritten below.
    if exec.dy_zero_len != dy.len() {
        exec.dy_zero = dy_zero_ranges(prog, dy.len(), exec.n_fallback);
        exec.dy_home = dy_homes(prog, dy.len());
        exec.dy_home_quiet = quiet_homes(prog, &exec.dy_home);
        exec.dy_zero_len = dy.len();
    }
    for &(a, b) in &exec.dy_zero {
        dy[a..b].fill(0.0);
    }
    // Refill the row-major state mirror: one strided pass per mirrored
    // variable block (column-major flat -> row-major at the same offset).
    let ways = call_ways(exec);
    for &i in &exec.mirror_vars {
        let sv = &prog.state_vars[i as usize];
        let rm = rm_strides(&sv.shape);
        let cm = cm_strides(&sv.shape);
        unsafe {
            copy_strided_maybe_split(
                ways,
                exec.state_rm.as_mut_ptr().add(sv.flat_offset),
                &rm,
                state.as_ptr().add(sv.flat_offset),
                &cm,
                &sv.shape,
            );
        }
    }
    // Intra-call FAQ ring registry for fallback rules (`HashMap::new` does not
    // allocate until first insertion, so a fully-taped call touches no heap).
    let derived_rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
    let state_rm = std::mem::take(&mut exec.state_rm);
    let mirror = std::mem::take(&mut exec.mirror);
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
        mirror: &mirror,
        params,
        t,
        const_arrays,
        const_lits,
        declared,
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
        run_range(&env, 0..prime_end, exec, dy, stats);
        unsafe {
            fused::refill_index_tables(&mut exec.idx_tables, exec.slab.as_ptr(), &exec.slot_off)
        };
    } else if exec.primed_forcing_epoch != forcing_epoch {
        exec.primed_forcing_epoch = forcing_epoch;
        #[cfg(test)]
        SECTION_PRIMES.with(|c| c.set((c.get().0, c.get().1 + 1)));
        run_range(&env, const_end..prime_end, exec, dy, stats);
        unsafe {
            fused::refill_index_tables(&mut exec.idx_tables, exec.slab.as_ptr(), &exec.slot_off)
        };
    }
    // With nothing reading the published observeds, the output-only tail of
    // the section is not run.
    let end = if exec.exports_active {
        prog.instrs.len()
    } else {
        prime_end + prog.n_rhs as usize
    };
    run_range(&env, prime_end..end, exec, dy, stats);
    exec.state_rm = state_rm;
    exec.mirror = mirror;

    stats.taped_rules += exec.n_taped;
    stats.fallback_rules += exec.n_fallback;
}
