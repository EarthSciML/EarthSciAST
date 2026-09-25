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
//! * [`Instr::Assemble`] is a whole `eval_vec_makearray`: the zero-filled
//!   bounding box with every region written in order, in one instruction.
//! * [`Instr::ConstArray`] materializes an inline array literal: the elements
//!   `eval_const`/`json_to_value` produce for that node, in row-major order,
//!   already precision-rounded at ingress — the same `f64`s the interpreter
//!   would have read out of the same `Value::Array`.
//! * [`Instr::Interp`] evaluates one esm-spec §9.2 `interp.*` entry over a
//!   compile-time-constant table, elementwise in the query. Its element
//!   semantics are the registry functions themselves, which is what the
//!   per-cell oracle's `eval_fn` calls, so the agreement is by shared code.
//! * [`Instr::Reduce`] folds a source box down over a set of axes with a
//!   binary kernel, visiting the source in ROW-MAJOR order. That order is the
//!   per-cell oracle's contraction odometer (`CartesianTuples`, LAST name
//!   fastest) from the reduction identity, which is what makes a scalar
//!   reduction bit-identical to `reduce_contraction`'s `acc = combine(acc,
//!   term)` loop.
//! * [`Instr::Scan`] is `run_prefix_scan` over a whole box: a running fold
//!   along one axis, ascending, independently for every position of the
//!   other axes, writing the inclusive or exclusive partial result.
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
    Param(u32),
    /// The current solver time `t`.
    Time,
    /// The whole persistent array of state variable `state_vars[i]`, read from
    /// the current state vector (origin all-1s). A 0-d state variable reads as
    /// a scalar — exactly `eval_vec_variable`'s state arm.
    State(u32),
    /// The whole persistent observed array `obs_reads[i]`, resolved BY NAME in
    /// the runtime observed map (origin all-1s; 0-d reads as a scalar). Used
    /// for observeds produced by fallback rules or seeded static observeds.
    Obs(u32),
}

/// An array source for [`Instr::Gather`] / [`Instr::LoadElem`].
#[derive(Clone, Copy, Debug)]
pub(crate) enum SrcRef {
    Slot(SlotId),
    State(u32),
    Obs(u32),
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
    /// A whole `makearray` in one instruction: `out` zero-filled, then each
    /// part of `assemblies[table]` written over its region IN ORDER (a later
    /// region overwrites an earlier one) — what a chain of [`Instr::Region`]
    /// writes computes, with no per-region copy of the box. `out` never
    /// aliases a part's source.
    Assemble { table: u32, out: SlotId },
    /// Evaluate the §9.2 `interp.*` entry `interp_tables[table]` elementwise
    /// over `out`'s box: `out[k] = f(table, x[k], y[k])`, with a scalar query
    /// operand broadcasting exactly as [`Instr::Bin`]'s operands do.
    ///
    /// The table and axes are COMPILE-TIME CONSTANTS — esm-spec §9.2's
    /// "argument shape contract" requires literal `const`-op arrays, and their
    /// load-time validity (lengths, strict monotonicity, NaN-freedom) is
    /// checked once at lowering — so the instruction carries only the query.
    /// `y` is `Some` exactly for [`InterpKind::Bilinear`].
    ///
    /// Element semantics ARE the closed-function registry's own arithmetic
    /// ([`crate::registered_functions::interp_linear_at`] and its siblings):
    /// the same functions the per-cell oracle reaches through `eval_fn`,
    /// called on the same operands. A taped `interp.*` is bit-identical to the
    /// interpreter by sharing its code, not by restating it.
    Interp {
        table: u32,
        x: Operand,
        y: Option<Operand>,
        out: SlotId,
    },
    /// Materialize the inline array literal `const_data[data]` into `out`:
    /// a straight row-major store of the literal's elements, origin all-1s.
    ///
    /// One instruction regardless of the literal's size — the payload lives in
    /// [`TapeProgram::const_data`], not in the instruction stream — and it is
    /// classified CONST, so a solve stores each literal exactly once. (An
    /// XlaBuilder emitter lowers this to a `ConstantLiteral` of the same
    /// row-major buffer.)
    ConstArray { data: u32, out: SlotId },
    /// Reduce `src` over `axes` with `op`'s kernel, from `init`:
    ///
    /// ```text
    /// out[*] = init
    /// for k in ROW-MAJOR order of src_shape:
    ///     out[drop(k, axes)] = kernel(op)(out[drop(k, axes)], src[k])
    /// ```
    ///
    /// `axes` is ascending and duplicate-free; `out`'s box is `src_shape` with
    /// those axes dropped (a scalar slot when every axis is reduced, which is
    /// the rank-0 `faq` case). `init` is always the reduction's identity.
    ///
    /// **The visiting order is load-bearing.** Floating-point `+` is not
    /// associative, so a reduction is only bit-identical to the interpreter if
    /// it folds the same terms in the same order. Row-major (last axis
    /// fastest) over the contraction box IS the per-cell oracle's
    /// `CartesianTuples` odometer over the contracted names, and the tape
    /// lowers the contraction box with its axes in that same name order. An
    /// emitter that cannot promise this order (XLA's `reduce` leaves the
    /// association to the backend) is free to emit it anyway — but then it is
    /// no longer bitwise-pinned to the interpreter, only numerically equal.
    Reduce {
        op: BinCode,
        init: f64,
        src: SrcRef,
        /// Source axes folded away, ASCENDING and duplicate-free.
        axes: SmallVec<[u8; 4]>,
        /// The expected source box (validation).
        src_shape: DimU,
        out: SlotId,
    },
    /// Forward prefix scan (esm-spec §4.3.1) of `src` along `axis`, with
    /// `op`'s kernel from `init`, independently for every position of the
    /// other axes:
    ///
    /// ```text
    /// acc = init
    /// for k in 0..len(axis), ascending:
    ///     inclusive:  acc = kernel(op)(acc, src[k]);  out[k] = acc
    ///     exclusive:  out[k] = acc;  acc = kernel(op)(acc, src[k])
    /// ```
    ///
    /// `out`'s box is `src_shape`. This is `run_prefix_scan`'s sweep, folding
    /// each window in the same association (`init` is the reduction identity
    /// and the first combine is NOT elided: `0.0 + (-0.0)` is `0.0`), so a
    /// scan is bit-identical to the per-cell oracle. One instruction, whatever
    /// the scanned length.
    Scan {
        op: BinCode,
        init: f64,
        src: SrcRef,
        axis: u8,
        inclusive: bool,
        /// The expected source (and output) box (validation).
        src_shape: DimU,
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
            | Instr::Region { out, .. }
            | Instr::Assemble { out, .. }
            | Instr::ConstArray { out, .. }
            | Instr::Interp { out, .. }
            | Instr::Reduce { out, .. }
            | Instr::Scan { out, .. } => Some(*out),
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
                let fs = &fused[*spec as usize];
                for &(_, slot) in &fs.outputs {
                    f(slot);
                }
                if let Some(r) = &fs.reduce {
                    f(r.out);
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
        assemblies: &[AssembleSpec],
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
            Instr::Gather { src, .. }
            | Instr::LoadElem { src, .. }
            | Instr::Reduce { src, .. }
            | Instr::Scan { src, .. } => {
                if let SrcRef::Slot(s) = src {
                    f(*s);
                }
            }
            Instr::Ramp { .. } | Instr::ConstArray { .. } => {}
            Instr::Interp { x, y, .. } => {
                op(x);
                if let Some(y) = y {
                    op(y);
                }
            }
            Instr::Fill { v, .. } => op(v),
            Instr::Copy { a, .. } => op(a),
            Instr::Region { base, src, .. } => {
                op(src);
                op(&Operand::Slot(*base));
            }
            Instr::Assemble { table, .. } => {
                for (src, _) in &assemblies[*table as usize].parts {
                    op(src);
                }
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
            Instr::Assemble { .. } => "Assemble",
            Instr::ConstArray { .. } => "ConstArray",
            Instr::Interp { .. } => "Interp",
            Instr::Reduce { .. } => "Reduce",
            Instr::Scan { .. } => "Scan",
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

/// An index local to one fused group: a register, an array input, a scalar
/// input or a shifted input. It stays 16-bit because the executor walks the
/// micro-program once per chunk and a compact op is part of that loop's
/// cost; the fusion pass closes a group before any of its tables could
/// outgrow it (`GBuilder::has_room`). Indices into the program's own tables
/// (states, observed reads, parameters, slots) are 32-bit.
pub(crate) type GroupIx = u16;

/// Reference to a value inside a fused micro-program.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MRef {
    /// Temporary register defined by an earlier micro-op of the same group.
    Reg(GroupIx),
    /// Array input `FusedSpec::inputs[i]`, read at the current element (for a
    /// folded gather: at the current element plus the run's source offset).
    In(GroupIx),
    /// Scalar input `FusedSpec::scalars[i]`, broadcast over the box.
    Scal(GroupIx),
}

/// One micro-op of a fused group. Element semantics are EXACTLY the scalar
/// kernels of the corresponding [`Instr`] (`binary_kernel_of` /
/// `unary_kernel_of` / `-x` / `vec_select`'s per-element pick / a plain move),
/// applied in program order per element. The single executable definition is
/// `exec::eval_micro_op` (which the per-element interpreters share; the
/// chunked executor's monomorphized loops are pinned bit-identical to it by
/// the A/B tests).
#[derive(Clone, Debug)]
pub(crate) enum MicroOp {
    Bin {
        op: BinCode,
        a: MRef,
        b: MRef,
        out: GroupIx,
    },
    Un {
        op: UnCode,
        a: MRef,
        out: GroupIx,
    },
    Neg {
        a: MRef,
        out: GroupIx,
    },
    Select {
        cond: MRef,
        a: MRef,
        b: MRef,
        out: GroupIx,
    },
    /// `out = a` (a fused `Fill`/`Copy`).
    Mov {
        a: MRef,
        out: GroupIx,
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
        out: GroupIx,
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
        out: GroupIx,
    },
}

/// One array input of a fused group.
#[derive(Clone, Debug)]
pub(crate) struct FusedInput {
    pub src: SrcRef,
    /// `Some(i)`: a folded shifted-read gather — the source flat offset for a
    /// run lives at `FusedRun::in_off[i]`. `None`: aligned (the source is read
    /// at the same flat offset as the output).
    pub shifted_ix: Option<GroupIx>,
    /// The source array's expected shape (equals the group box for aligned
    /// inputs; a folded gather's source box may differ — its run offsets are
    /// flat in THIS shape's row-major layout). Validated at execution.
    pub src_shape: DimU,
    /// Per-element source advance within a run (1 = contiguous; a LINEAR
    /// folded gather — e.g. a level slice of a deeper box — advances by a
    /// constant stride). Meaningful only for shifted inputs.
    pub elem_stride: i64,
    /// For a shifted input with `elem_stride != 1`: the chunk register the
    /// executor pre-loads this input into (`GroupIx::MAX` otherwise).
    pub load_reg: GroupIx,
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
    pub n_regs: GroupIx,
    /// Additional registers appended after `n_regs` for strided-input
    /// pre-loads (`FusedInput::load_reg` indexes into `n_regs..n_regs +
    /// n_load_regs`).
    pub n_load_regs: GroupIx,
    /// Step 4b: registers appended after the load registers for the
    /// all-pointer superops ([`MicroOp::Bin3`]): one splat register per
    /// entry of `scalars` (filled once per call) plus a trailing zero
    /// register (the ghost read). 0 when the micro-program has no Bin3.
    pub n_splat_regs: GroupIx,
    /// `(register, slot)` live-outs stored back to the slab.
    pub outputs: SmallVec<[(GroupIx, SlotId); 2]>,
    /// Precompiled run schedule (see [`FusedRun`]); a group with no shifted
    /// inputs has the single run `(0, n_elems, [])`.
    pub runs: Vec<FusedRun>,
    /// An absorbed [`Instr::Reduce`] over the group box, folding one register
    /// instead of storing it (see [`FusedReduce`]).
    pub reduce: Option<FusedReduce>,
    /// Diagnostics: original instructions replaced (members incl. deleted
    /// folded gathers).
    pub n_fused_instrs: u32,
    pub n_folded_gathers: u32,
}

/// The fold of a fused group's value over its box's LEADING axes — an
/// [`Instr::Reduce`] whose source only the group produced and only the
/// reduction reads, so the source never materializes:
///
/// ```text
/// out[*] = init
/// for k in ROW-MAJOR order of the group box:
///     out[k % n_inner] = kernel(op)(out[k % n_inner], reg[k])
/// ```
///
/// Runs and their chunks execute in ascending flat order, which is the
/// `Reduce` visiting order, so every output cell folds the same terms in the
/// same association as the unfused instruction.
#[derive(Clone, Debug)]
pub(crate) struct FusedReduce {
    /// The register holding the folded value (physical, after allocation).
    pub reg: GroupIx,
    pub op: BinCode,
    pub init: f64,
    /// The reduction's output slot: the group box with the leading axes
    /// dropped (a scalar slot when every axis is folded).
    pub out: SlotId,
    /// Elements per leading-axes position (the output's element count).
    pub n_inner: usize,
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
    /// Reductions absorbed into the group producing their source
    /// ([`FusedReduce`]; the `Reduce` instruction is deleted).
    pub n_reduces_folded: usize,
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

/// The payload of one [`Instr::ConstArray`]: an inline array literal's
/// elements, materialized once at build time by `eval_const` and stored
/// row-major (the layout every slab slot uses). Held on the program rather
/// than in the instruction so the instruction stream stays O(1) per literal.
#[derive(Clone, Debug)]
pub(crate) struct ConstArrayData {
    pub shape: DimU,
    /// Row-major elements, exactly as `json_to_value` produced them
    /// (precision-rounded at ingress under `element_type: "Float32"`).
    pub values: Vec<f64>,
}

/// Which esm-spec §9.2 `interp.*` entry an [`Instr::Interp`] evaluates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum InterpKind {
    /// `interp.linear(table, axis, x)`.
    Linear,
    /// `interp.bilinear(table, axis_x, axis_y, x, y)`.
    Bilinear,
    /// `interp.searchsorted(x, xs)`.
    SearchSorted,
}

impl InterpKind {
    /// The kind a §9.2 registry name selects, or `None` for a name outside
    /// the `interp.*` family.
    pub(crate) fn from_name(name: &str) -> Option<InterpKind> {
        match name {
            "interp.linear" => Some(InterpKind::Linear),
            "interp.bilinear" => Some(InterpKind::Bilinear),
            "interp.searchsorted" => Some(InterpKind::SearchSorted),
            _ => None,
        }
    }

    /// The registry name this kind evaluates, for diagnostics.
    pub(crate) fn name(self) -> &'static str {
        match self {
            InterpKind::Linear => "interp.linear",
            InterpKind::Bilinear => "interp.bilinear",
            InterpKind::SearchSorted => "interp.searchsorted",
        }
    }
}

/// The constant payload of one [`Instr::Interp`]: the §9.2 lookup table and
/// its axes, as `eval_const` produced them (so a taped call reads exactly the
/// `f64`s the per-cell oracle would have read out of the same `const` node,
/// including the Float32 ingress rounding).
///
/// Validated ONCE, at lowering, against the registry itself: a table the
/// registry would reject never reaches here, because the lowering bails and
/// the rule falls back to the oracle, which is what produces the registry's
/// NaN sentinel.
#[derive(Clone, Debug)]
pub(crate) struct InterpTable {
    pub kind: InterpKind,
    /// `interp.linear`: `table`. `interp.bilinear`: `table` flattened
    /// row-major (`table[i * axis_y.len() + j]`, the §9.2 layout).
    /// `interp.searchsorted`: empty — the entry has no table beyond `xs`.
    pub table: Vec<f64>,
    /// `axis` (linear), `axis_x` (bilinear) or `xs` (searchsorted).
    pub axis_x: Vec<f64>,
    /// `axis_y`; empty for every kind but [`InterpKind::Bilinear`].
    pub axis_y: Vec<f64>,
}

impl InterpTable {
    /// Evaluate this entry at one query point — the SINGLE definition the fast
    /// executor, the reference executor and the build-time constant fold all
    /// call. `y` is read only by [`InterpKind::Bilinear`].
    pub(crate) fn at(&self, x: f64, y: f64) -> f64 {
        use crate::registered_functions::{interp_bilinear_at, interp_linear_at, searchsorted_at};
        match self.kind {
            InterpKind::Linear => interp_linear_at(&self.table, &self.axis_x, x),
            InterpKind::Bilinear => {
                interp_bilinear_at(&self.table, &self.axis_x, &self.axis_y, x, y)
            }
            // `eval_fn` lifts the registry's integer result with
            // `ClosedValue::as_f64`, so the tape stores the same `f64`.
            InterpKind::SearchSorted => searchsorted_at(x, &self.axis_x) as f64,
        }
    }
}

/// One makearray region: placement of a region write within its bounding box.
#[derive(Clone, Debug)]
pub(crate) struct RegionSpec {
    /// 0-based start of the region within the base slot's box.
    pub dest_lo: DimU,
    /// Region extent.
    pub shape: DimU,
}

/// The parts of one [`Instr::Assemble`]: each source (a scalar fill or an
/// array spanning its region) and the region it is written over, in the
/// `makearray`'s region order.
#[derive(Clone, Debug)]
pub(crate) struct AssembleSpec {
    /// `(source, index into TapeProgram::regions)`.
    pub parts: Vec<(Operand, u32)>,
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
    pub var: u32,
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
    /// `makearray` assemblies (`Instr::Assemble` indexes here).
    pub assemblies: Vec<AssembleSpec>,
    /// Inline array-literal payloads (`Instr::ConstArray` indexes here).
    pub const_data: Vec<ConstArrayData>,
    /// §9.2 `interp.*` constant tables (`Instr::Interp` indexes here).
    pub interp_tables: Vec<InterpTable>,
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
