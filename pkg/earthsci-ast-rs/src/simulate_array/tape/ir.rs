//! The tape IR: a flat, straight-line instruction program compiled from the
//! post-CSE expression graph of one model's RHS + observed rules.
//!
//! This is the compile-time half of tape compilation (Step 3a). Step 3b's
//! fast slab executor (`super::exec`) runs the program as the production RHS
//! hot path; a slow, allocation-happy *reference* executor lives in the
//! test-support module and pins the lowering bit-for-bit against the
//! production interpreter independently of the slab coloring.
//!
//! ## Semantics contract
//!
//! Every instruction's element semantics is DEFINED to be the corresponding
//! kernel of the vectorized overlay (`vectorized.rs`), which is itself pinned
//! bit-identical to the per-cell oracle:
//!
//! * [`Instr::Bin`] applies [`binary_kernel_of`] elementwise in `(a, b)` order
//!   (scalar operands broadcast), exactly like `vec_combine`.
//! * [`Instr::Un`] applies [`unary_kernel_of`]; [`Instr::Neg`] applies `x → -x`
//!   (`vec_negate` — NOT `0 - x`, which differs on signed zero).
//! * [`Instr::Select`] is `vec_select`: `out[k] = cond[k] != 0 ? a[k] : b[k]`,
//!   with BOTH branches already evaluated. A scalar `cond` operand broadcasts
//!   (the §5.3 runtime-scalar filter gate), which is elementwise-identical to
//!   the overlay's whole-term keep/replace.
//! * [`Instr::JmpIfZero`] is the scalar-`ifelse` short circuit: the untaken
//!   branch's instructions are NEVER executed.
//! * [`Instr::Gather`] is a precompiled `eval_vec_index`: per-axis
//!   shift/wrap/fixed/broadcast segments with ghost-0 (homogeneous Dirichlet)
//!   fill outside the source extent.
//! * [`Instr::Ramp`] is the coordinate-ramp idiom of `eval_vec_variable`.
//! * [`Instr::Region`] is one `eval_vec_makearray` region write (later regions
//!   overwrite earlier ones).
//!
//! Array operands within one instruction share one box (shape + 1-based
//! origin), checked at lowering time — the same precondition `vec_combine`
//! enforces at runtime (a mismatch there bails the rule to the oracle; here it
//! marks the rule as a fallback).

// A few descriptor fields are read only by the test-gated reference executor
// and the diagnostics, which the lib-only dead-code pass cannot see.
#![allow(dead_code)]

use super::super::{BinCode, UnCode};
use super::super::{DimI, DimU};
use smallvec::SmallVec;

/// Index of a value slot (SSA-style: each instruction defines a fresh slot;
/// slab coloring maps slots onto shared storage afterwards).
pub(crate) type SlotId = u32;

/// Which section of the program an instruction / slot belongs to. Sections run
/// in order; CONST runs once per solve, SEGMENT once per integration segment,
/// CONTINUOUS on every RHS call. Classification is *structural only* in this
/// step (no epoch/invalidation machinery): an instruction lands in the
/// earliest section its operands allow, mirroring the driver's
/// `classify_static_observeds` / `classify_segment_invariant_observeds` tiers
/// and the CSE overlay's box-pure (ess-lih) hoist.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub(crate) enum Cadence {
    Const = 0,
    Segment = 1,
    Continuous = 2,
}

/// A value read by an instruction.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Operand {
    /// A slot defined earlier in the program (scalar or array per its desc).
    Slot(SlotId),
    /// An `f64` literal (number/integer leaves, folded scalar constants, bound
    /// contraction-index values).
    Lit(f64),
    /// The scalar parameter at this index of the positional parameter vector.
    Param(u16),
    /// The current solver time `t`.
    Time,
    /// The whole persistent array of state variable `state_vars[i]`, read from
    /// the current state vector (origin all-1s). A 0-d state variable reads as
    /// a scalar — exactly `eval_vec_variable`'s state arm.
    State(u16),
    /// The whole persistent observed array `obs_reads[i]`, resolved BY NAME in
    /// the runtime observed map (origin all-1s; 0-d reads as a scalar). Used
    /// for observeds produced by fallback rules or seeded static observeds.
    Obs(u16),
}

/// An array source for [`Instr::Gather`] / [`Instr::LoadElem`].
#[derive(Clone, Copy, Debug)]
pub(crate) enum SrcRef {
    Slot(SlotId),
    State(u16),
    Obs(u16),
}

/// One tape instruction. See the module docs for the semantics contract.
#[derive(Clone, Debug)]
pub(crate) enum Instr {
    /// `out[k] = kernel(op)(a[k], b[k])` — elementwise, scalar operands
    /// broadcast, array operands share `out`'s box.
    Bin {
        op: BinCode,
        a: Operand,
        b: Operand,
        out: SlotId,
    },
    /// `out[k] = kernel(op)(a[k])`.
    Un { op: UnCode, a: Operand, out: SlotId },
    /// `out[k] = -a[k]` (`vec_negate`; distinct from `0 - x` on signed zero).
    Neg { a: Operand, out: SlotId },
    /// `out[k] = cond[k] != 0 ? a[k] : b[k]`; both `a` and `b` are already
    /// evaluated (`vec_select` / array-`ifelse` / filter-gate semantics).
    Select {
        cond: Operand,
        a: Operand,
        b: Operand,
        out: SlotId,
    },
    /// Precompiled `eval_vec_index`: gather `src` through `plans[plan]` into
    /// `out` (ghost positions stay 0).
    Gather { src: SrcRef, plan: u32, out: SlotId },
    /// Read the single element at (0-based) `idx` of `src` into scalar `out`
    /// (the all-fixed `index(...)` select).
    LoadElem {
        src: SrcRef,
        idx: SmallVec<[usize; 4]>,
        out: SlotId,
    },
    /// Coordinate ramp: element `p` along `axis` of `out`'s box holds
    /// `(lo + p) as f64`; constant along every other axis.
    Ramp { axis: u8, lo: i64, out: SlotId },
    /// Fill `out` with the scalar operand `v` (array `out`: broadcast fill;
    /// scalar `out`: plain copy).
    Fill { v: Operand, out: SlotId },
    /// Copy `a` into `out` (same box, or scalar → scalar). Used to join the
    /// two branches of a [`Instr::JmpIfZero`] into one phi slot and to
    /// re-origin an observed value to the 1-based convention.
    Copy { a: Operand, out: SlotId },
    /// `out = base` with `regions[region]` overwritten by `src` (a scalar fill
    /// or an array spanning the region box). Later regions overwrite.
    Region {
        base: SlotId,
        src: Operand,
        region: u32,
        out: SlotId,
    },
    /// Scalar-`ifelse` short circuit: if `cond != 0`, execute the next
    /// `n_true` instructions then skip the following `n_false`; else skip
    /// `n_true` and execute the following `n_false`. The untaken branch is
    /// NEVER executed. Both branches end by defining the same phi slot.
    JmpIfZero {
        cond: Operand,
        n_true: u32,
        n_false: u32,
    },
    /// Evaluate fallback rule `rules[rule]` through the existing interpreter
    /// (observed materialization or the per-cell RHS oracle), at exactly this
    /// point in the program order.
    Fallback { rule: u32 },
    /// Publish `slot` into the runtime observed map as `exports[export].0`
    /// (a scalar slot publishes a 0-d array).
    Export { slot: SlotId, export: u32 },
    /// Scatter `dy_writes[write]` into the flat `dy` vector (column-major
    /// sub-block placement), at exactly this point in the program order.
    DyWrite { write: u32 },
    /// Step 4: execute the fused elementwise group `fused[spec]` — a
    /// straight-line micro-program applied once per element of the group box,
    /// replacing a DAG segment of same-box elementwise instructions (and any
    /// folded shifted-read gathers). Per element it applies EXACTLY the same
    /// scalar kernels in the same order as the unfused instructions, so bit
    /// identity is by construction (elementwise maps are independent across
    /// elements; no reductions are ever fused).
    Fused { spec: u32 },
}

impl Instr {
    /// Slot this instruction defines, if any.
    pub(crate) fn out(&self) -> Option<SlotId> {
        match self {
            Instr::Bin { out, .. }
            | Instr::Un { out, .. }
            | Instr::Neg { out, .. }
            | Instr::Select { out, .. }
            | Instr::Gather { out, .. }
            | Instr::LoadElem { out, .. }
            | Instr::Ramp { out, .. }
            | Instr::Fill { out, .. }
            | Instr::Copy { out, .. }
            | Instr::Region { out, .. } => Some(*out),
            Instr::JmpIfZero { .. }
            | Instr::Fallback { .. }
            | Instr::Export { .. }
            | Instr::DyWrite { .. }
            | Instr::Fused { .. } => None,
        }
    }

    /// Visit every slot this instruction DEFINES ([`Instr::out`] plus the
    /// multi-output [`Instr::Fused`] case).
    pub(crate) fn for_each_def(&self, fused: &[FusedSpec], mut f: impl FnMut(SlotId)) {
        match self {
            Instr::Fused { spec } => {
                for &(_, slot) in &fused[*spec as usize].outputs {
                    f(slot);
                }
            }
            other => {
                if let Some(o) = other.out() {
                    f(o);
                }
            }
        }
    }

    /// Visit every slot this instruction READS.
    pub(crate) fn for_each_read(
        &self,
        dy_writes: &[DyWrite],
        fused: &[FusedSpec],
        mut f: impl FnMut(SlotId),
    ) {
        let mut op = |o: &Operand| {
            if let Operand::Slot(s) = o {
                f(*s);
            }
        };
        match self {
            Instr::Bin { a, b, .. } => {
                op(a);
                op(b);
            }
            Instr::Un { a, .. } | Instr::Neg { a, .. } => op(a),
            Instr::Select { cond, a, b, .. } => {
                op(cond);
                op(a);
                op(b);
            }
            Instr::Gather { src, .. } | Instr::LoadElem { src, .. } => {
                if let SrcRef::Slot(s) = src {
                    f(*s);
                }
            }
            Instr::Ramp { .. } => {}
            Instr::Fill { v, .. } => op(v),
            Instr::Copy { a, .. } => op(a),
            Instr::Region { base, src, .. } => {
                op(src);
                op(&Operand::Slot(*base));
            }
            Instr::JmpIfZero { cond, .. } => op(cond),
            Instr::Fallback { .. } => {}
            Instr::Export { slot, .. } => f(*slot),
            Instr::DyWrite { write } => f(dy_writes[*write as usize].slot),
            Instr::Fused { spec } => {
                let fs = &fused[*spec as usize];
                for inp in &fs.inputs {
                    if let SrcRef::Slot(s) = inp.src {
                        op(&Operand::Slot(s));
                    }
                }
                for sc in &fs.scalars {
                    op(sc);
                }
            }
        }
    }

    /// A short opcode name for diagnostics.
    pub(crate) fn opcode(&self) -> &'static str {
        match self {
            Instr::Bin { .. } => "Bin",
            Instr::Un { .. } => "Un",
            Instr::Neg { .. } => "Neg",
            Instr::Select { .. } => "Select",
            Instr::Gather { .. } => "Gather",
            Instr::LoadElem { .. } => "LoadElem",
            Instr::Ramp { .. } => "Ramp",
            Instr::Fill { .. } => "Fill",
            Instr::Copy { .. } => "Copy",
            Instr::Region { .. } => "Region",
            Instr::JmpIfZero { .. } => "JmpIfZero",
            Instr::Fallback { .. } => "Fallback",
            Instr::Export { .. } => "Export",
            Instr::DyWrite { .. } => "DyWrite",
            Instr::Fused { .. } => "Fused",
        }
    }
}

// ---------------------------------------------------------------------------
// Step 4: fused elementwise groups.
// ---------------------------------------------------------------------------

/// Reference to a value inside a fused micro-program.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MRef {
    /// Temporary register defined by an earlier micro-op of the same group.
    Reg(u16),
    /// Array input `FusedSpec::inputs[i]`, read at the current element (for a
    /// folded gather: at the current element plus the run's source offset).
    In(u16),
    /// Scalar input `FusedSpec::scalars[i]`, broadcast over the box.
    Scal(u16),
}

/// One micro-op of a fused group. Element semantics are EXACTLY the scalar
/// kernels of the corresponding [`Instr`] (`binary_kernel_of` /
/// `unary_kernel_of` / `-x` / `vec_select`'s per-element pick / a plain move),
/// applied in program order per element.
#[derive(Clone, Debug)]
pub(crate) enum MicroOp {
    Bin {
        op: BinCode,
        a: MRef,
        b: MRef,
        out: u16,
    },
    Un {
        op: UnCode,
        a: MRef,
        out: u16,
    },
    Neg {
        a: MRef,
        out: u16,
    },
    Select {
        cond: MRef,
        a: MRef,
        b: MRef,
        out: u16,
    },
    /// `out = a` (a fused `Fill`/`Copy`).
    Mov {
        a: MRef,
        out: u16,
    },
    /// Superop: `t = kernel(op1)(a, b); out = swap ? kernel(op2)(c, t)
    /// : kernel(op2)(t, c)` — two adjacent Bin micro-ops whose intermediate
    /// `t` has exactly one consumer, merged into one loop. Element semantics
    /// are EXACTLY the two constituent kernels applied in order (the
    /// intermediate lives in a register instead of a chunk buffer — no value
    /// change).
    Bin2 {
        op1: BinCode,
        a: MRef,
        b: MRef,
        op2: BinCode,
        c: MRef,
        swap: bool,
        out: u16,
    },
    /// Step 4b superop: a three-op `+ - * /` chain whose two intermediates
    /// each have exactly one consumer (the next op):
    /// `t1 = kernel(op1)(a, b); t2 = swap2 ? kernel(op2)(c, t1) :
    /// kernel(op2)(t1, c); out = swap3 ? kernel(op3)(d, t2) :
    /// kernel(op3)(t2, d)`. Element semantics are EXACTLY the three
    /// constituent kernels applied in order — never a hardware FMA, which
    /// would change bits. Executed all-pointer: scalar operands read from
    /// splat registers, ghost inputs from the zero register (identical
    /// values, so identical bits).
    Bin3 {
        op1: BinCode,
        a: MRef,
        b: MRef,
        op2: BinCode,
        c: MRef,
        swap2: bool,
        op3: BinCode,
        d: MRef,
        swap3: bool,
        out: u16,
    },
}

/// One array input of a fused group.
#[derive(Clone, Debug)]
pub(crate) struct FusedInput {
    pub src: SrcRef,
    /// `Some(i)`: a folded shifted-read gather — the source flat offset for a
    /// run lives at `FusedRun::in_off[i]`. `None`: aligned (the source is read
    /// at the same flat offset as the output).
    pub shifted_ix: Option<u16>,
    /// The source array's expected shape (equals the group box for aligned
    /// inputs; a folded gather's source box may differ — its run offsets are
    /// flat in THIS shape's row-major layout). Validated at execution.
    pub src_shape: DimU,
    /// Per-element source advance within a run (1 = contiguous; a LINEAR
    /// folded gather — e.g. a level slice of a deeper box — advances by a
    /// constant stride). Meaningful only for shifted inputs.
    pub elem_stride: i64,
    /// For a shifted input with `elem_stride != 1`: the chunk register the
    /// executor pre-loads this input into (`u16::MAX` otherwise).
    pub load_reg: u16,
}

/// Sentinel source offset: the input reads the gather's Dirichlet ghost
/// (`+0.0`) over the whole run.
pub(crate) const GHOST_OFF: i64 = i64::MIN;

/// One contiguous run of a fused group's precompiled schedule. Runs partition
/// the (row-major flat) output box; within a run every shifted input is either
/// a single constant flat offset into its source or entirely ghost.
#[derive(Clone, Debug)]
pub(crate) struct FusedRun {
    pub out_off: u32,
    pub len: u32,
    /// Per SHIFTED input (indexed by `FusedInput::shifted_ix`): the 0-based
    /// flat source offset of the run's first element, or [`GHOST_OFF`].
    pub in_off: SmallVec<[i64; 2]>,
}

/// A fused elementwise group: a straight-line micro-program over virtual
/// registers, executed once per element of `shape` (in one pass over the box),
/// then its live-out registers stored to the slab.
#[derive(Clone, Debug)]
pub(crate) struct FusedSpec {
    /// The group box shape (the run schedule is row-major flat over it).
    pub shape: DimU,
    pub inputs: Vec<FusedInput>,
    /// Scalar operands (literals, params, `t`, scalar slots, 0-d state),
    /// resolved once per call.
    pub scalars: Vec<Operand>,
    pub micro: Vec<MicroOp>,
    /// Physical register count after last-use recycling. An op's `out`
    /// register never aliases one of its operand registers.
    pub n_regs: u16,
    /// Additional registers appended after `n_regs` for strided-input
    /// pre-loads (`FusedInput::load_reg` indexes into `n_regs..n_regs +
    /// n_load_regs`).
    pub n_load_regs: u16,
    /// Step 4b: registers appended after the load registers for the
    /// all-pointer superops ([`MicroOp::Bin3`]): one splat register per
    /// entry of `scalars` (filled once per call) plus a trailing zero
    /// register (the ghost read). 0 when the micro-program has no Bin3.
    pub n_splat_regs: u16,
    /// `(register, slot)` live-outs stored back to the slab.
    pub outputs: SmallVec<[(u16, SlotId); 2]>,
    /// Precompiled run schedule (see [`FusedRun`]); a group with no shifted
    /// inputs has the single run `(0, n_elems, [])`.
    pub runs: Vec<FusedRun>,
    /// Diagnostics: original instructions replaced (members incl. deleted
    /// folded gathers).
    pub n_fused_instrs: u32,
    pub n_folded_gathers: u32,
}

impl FusedSpec {
    pub(crate) fn n_elems(&self) -> usize {
        self.shape.iter().product::<usize>().max(1)
    }
}

/// Fusion-pass diagnostics carried on the program for the build report.
#[derive(Clone, Debug, Default)]
pub struct FuseStats {
    /// Whole-program instruction count before / after fusion.
    pub instrs_before: usize,
    pub instrs_after: usize,
    /// Fused groups emitted.
    pub n_groups: usize,
    /// Original instructions absorbed into groups (incl. folded gathers).
    pub n_member_instrs: usize,
    /// Gathers folded into consumers as shifted reads (instruction deleted).
    pub n_gathers_folded: usize,
    /// Gathers that stayed materialized (unfoldable plan, external readers of
    /// the gathered value are counted as folded — this counts kept Gather
    /// instructions in the fused program).
    pub n_gathers_kept: usize,
    /// Group size histogram buckets: [2-3, 4-7, 8-15, 16-31, 32-63, 64+]
    /// member instructions.
    pub group_size_hist: [usize; 6],
    /// Step 4b diagnostics (weighted by group element count, i.e. per-RHS
    /// element-op cost): final micro-op kind histogram, descending.
    pub micro_hist: Vec<(String, usize)>,
    /// Pre-superop single-use producer→consumer adjacency histogram
    /// (`"producer>consumer"`), descending — the data that drives which
    /// deeper superop shapes are worth monomorphizing.
    pub adj_hist: Vec<(String, usize)>,
    /// Pre-superop maximal arith (`+ - * /` Bin) chain lengths (single-use,
    /// consumed by the immediately following op), weighted by element count.
    pub chain_hist: Vec<(usize, usize)>,
}

/// Descriptor of one value slot.
#[derive(Clone, Debug)]
pub(crate) struct SlotDesc {
    /// Array shape (empty for a scalar).
    pub shape: DimU,
    /// Per-axis 1-based origin (empty for a scalar).
    pub origin: DimI,
    /// A single `f64` rather than an array.
    pub scalar: bool,
    /// Section the defining instruction lives in.
    pub cadence: Cadence,
    /// Storage bucket assigned by slab coloring (index into
    /// [`SlabLayout::storages`]); `u32::MAX` until colored.
    pub storage: u32,
}

impl SlotDesc {
    pub(crate) fn elems(&self) -> usize {
        if self.scalar {
            1
        } else {
            self.shape.iter().copied().product::<usize>().max(1)
        }
    }
}

/// A precompiled `eval_vec_index` plan. All classification (affine shifts,
/// periodic wraps, fixed selects, broadcast axes) has been resolved at build
/// time; execution is a pure segment-copy schedule.
#[derive(Clone, Debug)]
pub(crate) struct GatherPlan {
    /// Fixed source axes as `(src_axis, 0-based index)`, sorted DESCENDING by
    /// axis so `index_axis` application keeps lower axis numbers valid —
    /// exactly `eval_vec_index`'s `fixed_desc`.
    pub fixed_desc: SmallVec<[(usize, usize); 4]>,
    /// Permutation applied to the remaining (mapped) source axes so they land
    /// in output-axis order (`eval_vec_index`'s `perm`).
    pub perm: SmallVec<[usize; 4]>,
    /// Per output axis: `true` if a source axis maps onto it, `false` if the
    /// source is broadcast (stride-0) along it.
    pub mapped: SmallVec<[bool; 4]>,
    /// Per output axis: copy segments `(out_off, len, src_off)` (0-based)
    /// into the reduced/permuted/broadcast source view. Ghost (uncovered)
    /// positions keep the zero fill.
    pub segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]>,
    /// The output box.
    pub shape: DimU,
    pub origin: DimI,
    /// The expected source box (validation).
    pub src_shape: DimU,
    pub src_origin: DimI,
}

/// One makearray region: placement of a region write within its bounding box.
#[derive(Clone, Debug)]
pub(crate) struct RegionSpec {
    /// 0-based start of the region within the base slot's box.
    pub dest_lo: DimU,
    /// Region extent.
    pub shape: DimU,
}

/// A state variable the program reads/writes, snapshot of its `VarShape`.
#[derive(Clone, Debug)]
pub(crate) struct StateRef {
    pub name: String,
    pub shape: DimU,
    pub origin: DimI,
    pub flat_offset: usize,
}

/// One taped `D(var) = …` result scatter: slot → column-major sub-block of the
/// variable's flat `dy` block (`scatter_col_major_offset` placement).
#[derive(Clone, Debug)]
pub(crate) struct DyWrite {
    pub slot: SlotId,
    /// Index into [`TapeProgram::state_vars`].
    pub var: u16,
    /// 0-based sub-block start per axis (from `subblock_dest`).
    pub dest_lo: SmallVec<[usize; 4]>,
    /// Single flat slot for scalar rules (`RhsRule::Scalar`/`IndexedScalar`):
    /// when `Some`, `slot` is scalar and is written to `dy[flat]` directly.
    pub scalar_flat: Option<usize>,
}

/// What kind of source rule a program rule entry describes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RuleKind {
    /// `observed_rules[i]`.
    Observed(usize),
    /// `rhs_rules[i]`.
    Rhs(usize),
}

/// Whether a rule was lowered onto the tape or left to the interpreter.
#[derive(Clone, Debug)]
pub(crate) enum RuleStatus {
    Taped,
    /// Reason string mirrors the overlay's `note_bail` taxonomy: the DEEPEST
    /// bail site reached while attempting to lower the rule.
    Fallback(String),
}

/// One rule of the program, in evaluation order (observed rules in dependency
/// order, then RHS rules).
#[derive(Clone, Debug)]
pub(crate) struct RuleInfo {
    pub name: String,
    pub kind: RuleKind,
    pub cadence: Cadence,
    pub status: RuleStatus,
}

/// One storage bucket of the slab: several slots may share it (recycling).
#[derive(Clone, Debug)]
pub(crate) struct StorageDesc {
    /// Element count (1 for scalars).
    pub elems: usize,
    /// Flat `f64` offset within the slab.
    pub offset: usize,
    /// Section whose lifetime this storage belongs to. CONST/SEGMENT storages
    /// holding cross-section-live values are dedicated (never recycled).
    pub cadence: Cadence,
    /// `true` when the storage holds a value read by a LATER section and is
    /// therefore never recycled.
    pub dedicated: bool,
}

/// Slab layout summary produced by liveness + greedy interval coloring.
#[derive(Clone, Debug, Default)]
pub(crate) struct SlabLayout {
    pub storages: Vec<StorageDesc>,
    /// Total slab size in `f64` elements.
    pub total_elems: usize,
    /// Elements held by dedicated (cross-section-live) CONST storages.
    pub const_elems: usize,
    /// Elements held by dedicated SEGMENT storages.
    pub segment_elems: usize,
    /// Elements in recycled (within-section) storages.
    pub recycled_elems: usize,
}

/// The compiled tape program.
pub(crate) struct TapeProgram {
    /// All instructions: CONST section, then SEGMENT, then CONTINUOUS.
    pub instrs: Vec<Instr>,
    /// Instruction count of the CONST section.
    pub n_const: u32,
    /// Instruction count of the SEGMENT section.
    pub n_segment: u32,
    pub slots: Vec<SlotDesc>,
    pub plans: Vec<GatherPlan>,
    pub regions: Vec<RegionSpec>,
    pub state_vars: Vec<StateRef>,
    /// Observed names resolved through the runtime observed map
    /// (`Operand::Obs`/`SrcRef::Obs` index here).
    pub obs_reads: Vec<String>,
    pub dy_writes: Vec<DyWrite>,
    /// Observed values published back into the runtime observed map: names a
    /// fallback rule or the samples/observed-trajectory dependency cone reads.
    pub exports: Vec<(String, SlotId)>,
    /// All rules in program order, taped or fallback.
    pub rules: Vec<RuleInfo>,
    pub slab: SlabLayout,
    /// Rule ordinal (into `rules`) per instruction, parallel to `instrs`.
    pub provenance: Vec<u32>,
    /// Length of the positional parameter vector this program binds.
    pub params_len: usize,
    /// Step 4: fused elementwise groups (`Instr::Fused` indexes here).
    pub fused: Vec<FusedSpec>,
    /// Fusion-pass diagnostics (all-zero when fusion is disabled).
    pub fuse_stats: FuseStats,
}

impl TapeProgram {
    /// The `[start, end)` instruction range of a section.
    pub(crate) fn section_range(&self, c: Cadence) -> std::ops::Range<usize> {
        let nc = self.n_const as usize;
        let ns = self.n_segment as usize;
        match c {
            Cadence::Const => 0..nc,
            Cadence::Segment => nc..nc + ns,
            Cadence::Continuous => nc + ns..self.instrs.len(),
        }
    }

    /// Section an instruction index belongs to.
    pub(crate) fn section_of(&self, i: usize) -> Cadence {
        if i < self.n_const as usize {
            Cadence::Const
        } else if i < (self.n_const + self.n_segment) as usize {
            Cadence::Segment
        } else {
            Cadence::Continuous
        }
    }
}
