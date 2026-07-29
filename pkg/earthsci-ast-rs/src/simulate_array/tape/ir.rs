//! The tape IR: a flat, straight-line instruction program compiled from the
//! post-CSE expression graph of one model's RHS + observed rules.
//!
//! This is the compile-time half of tape compilation (Step 3a). The program is
//! built and validated but NOT yet executed on the production path —
//! `evaluate_rhs_with_scratch` still runs the existing interpreter; a later
//! step adds the fast executor. A slow, allocation-happy *reference* executor
//! lives in the test-support module and pins the lowering bit-for-bit against
//! the production interpreter.
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

// Step 3a builds and validates the program; the production executor arrives in
// Step 3b. Until then several descriptor fields are read only by the
// test-gated reference executor, which the lib-only dead-code pass cannot see.
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
            | Instr::DyWrite { .. } => None,
        }
    }

    /// Visit every slot this instruction READS.
    pub(crate) fn for_each_read(&self, dy_writes: &[DyWrite], mut f: impl FnMut(SlotId)) {
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
        }
    }
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
