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
//! * [`Instr::Calendar`] evaluates one esm-spec §9.2 `datetime.*` entry
//!   elementwise through the registry, on the binary64 argument, and keeps the
//!   binary64 result: `eval_fn`'s arithmetic, by sharing its code. Only a
//!   Float32 document emits it; under Float64 the family is expanded into the
//!   instructions above.
//! * [`Instr::Reduce`] folds a source box down over a set of axes with a
//!   binary kernel, visiting the source in ROW-MAJOR order. That order is the
//!   per-cell oracle's contraction odometer (`CartesianTuples`, LAST name
//!   fastest) from the reduction identity, which is what makes a scalar
//!   reduction bit-identical to `reduce_contraction`'s `acc = combine(acc,
//!   term)` loop.
//! * [`Instr::Scan`] is `run_prefix_scan` over a whole box: a running fold
//!   along one axis, ascending, independently for every position of the
//!   other axes, writing the inclusive or exclusive partial result.
//! * [`Instr::PolyArea`] is `eval_polygon_intersection_area` per element of
//!   its box: each element's two rings are read out of the two ring tables
//!   and measured by the interpreter's own `clip_area_value`. Pairs a planar
//!   broad phase proves bounding-box disjoint are not clipped; they hold the
//!   value the kernel's own bounding-box reject returns for them.
//! * [`Instr::IndexGather`] is `index_into` with one subscript that is DATA:
//!   the subscript operand is rounded (`f64::round`, then `as i64`, exactly
//!   `eval_index_args`) and an out-of-range position reads the zero ghost.
//! * [`Instr::TableGather`] reads its source at positions fixed at build
//!   time (one per output element, or the ghost `+0.0`): an `index` whose
//!   subscripts are build-time data rather than an affine map of the box.
//! * [`Instr::SegReduce`] is a compressed-row reduction: each output cell
//!   folds its own contiguous run of a term list, skipping the terms a mask
//!   excludes, which is `reduce_contraction`'s loop over an explicit list of
//!   admitted contraction tuples (a join-gated or ragged contraction).
//! * [`Instr::LoadForcing`] is `lookup_variable`'s forcing arm: the entry the
//!   forcing buffer holds for the name, copied in row-major order (a 0-d entry
//!   read as a scalar, rounded to the active precision), and the same
//!   fail-closed fault when the buffer holds none.
//! * [`Instr::Reshape`] is a row-major reinterpretation: the source's
//!   elements, in row-major order, under the output slot's box.
//! * [`Instr::Sweep`] is `sweep_recurrence`: its body runs once per cell of
//!   a recurrence's frame, the recurrence axis outermost and ascending, and
//!   each cell is published (rounded to the working precision) before the
//!   next one runs.
//! * [`Instr::ScalarRead`] is `eval_index` with every subscript a run-time
//!   scalar: a causal self-read (`RecurScope::read`, fail-closed), or
//!   `index_into` on a state, observed or const array.
//! * [`Instr::Fault`] latches one fail-closed evaluation fault
//!   (`E_TREEWALK_CONSTARRAY_OOB`, `E_TREEWALK_INDEX_ON_SCALAR`) exactly as
//!   the per-cell oracle's `latch_gather_fault` does at the same point: the
//!   FIRST fault latched in an evaluation wins, and the caller drains it.
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
    /// `out[k] = f(a[k])` for the §9.2 calendar entry `f =
    /// CALENDAR_FNS[func]`, evaluated by the closed-function registry on the
    /// binary64 value of `a[k]`, the result kept unrounded and a registry
    /// error read as `NaN` ([`calendar_at`]) — what the per-cell oracle's
    /// `eval_fn` computes, by calling the same function. A scalar `a`
    /// broadcasts as [`Instr::Un`]'s operand does.
    ///
    /// Emitted for a Float32 document only. There the tape's arithmetic
    /// kernels are binary32, so the expansion the Float64 lowering uses (an
    /// exact integer decomposition in binary64) would round at every step,
    /// while the oracle runs the registry in binary64 and hands back its
    /// result without rounding it.
    Calendar { func: u8, a: Operand, out: SlotId },
    /// Materialize the inline array literal `const_data[data]` into `out`:
    /// a straight row-major store of the literal's elements, origin all-1s.
    ///
    /// One instruction regardless of the literal's size — the payload lives in
    /// [`TapeProgram::const_data`], not in the instruction stream — and it is
    /// classified CONST, so a solve stores each literal exactly once. (An
    /// XlaBuilder emitter lowers this to a `ConstantLiteral` of the same
    /// row-major buffer.)
    ConstArray { data: u32, out: SlotId },
    /// Copy the forcing-buffer entry `forcings[forcing]` names into `out`
    /// (row-major, origin all-1s; a scalar slot for a 0-d entry).
    ///
    /// The forcing buffer only changes between integration segments, so this
    /// runs in the CONST section for a forcing nothing refreshes and in the
    /// SEGMENT section for a DISCRETE one, and every reader takes the slot:
    /// no instruction ever reads the buffer itself. A missing entry latches
    /// the fault the interpreter's lookup raises and fills `out` with `NaN`;
    /// an entry whose shape is not the one the program was built against
    /// latches a fault naming both.
    LoadForcing { forcing: u32, out: SlotId },
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
    /// `polygon_intersection_area` over `out`'s box (a scalar slot for a
    /// single pair): element `k`'s rings are `a` and `b` read at the positions
    /// `geoms[geom]` derives from `k`, and its value is the interpreter's
    /// `clip_area_value` of the two. See [`GeomSpec`] for the broad phase.
    PolyArea {
        a: SrcRef,
        b: SrcRef,
        geom: u32,
        out: SlotId,
    },
    /// `out[k] = src[pos(k)]`, where source axis `index_gathers[spec].data_axis`
    /// is addressed by the 1-based subscript `idx[k]` (a data value, rounded
    /// as the interpreter rounds it) and every other source axis by an affine
    /// map of an output axis or a fixed position. A subscript outside the
    /// source extent reads the zero ghost, `eval_index`'s state and observed
    /// rule; a const-array base is never lowered here.
    IndexGather {
        src: SrcRef,
        idx: Operand,
        spec: u32,
        out: SlotId,
    },
    /// `out[k] = src[pos[k]]`, with `pos = gather_tables[table].pos` the
    /// ROW-MAJOR flat position of each element's source cell, resolved at
    /// build time; a [`GATHER_GHOST`] position reads `+0.0` (the zero ghost of
    /// an out-of-range read). `out` is a 1-D box of `pos.len()` elements.
    ///
    /// This is `eval_index` with every subscript already evaluated: the
    /// lowering computes each position exactly as `index_into` does (the
    /// subscript rounded, then the zero ghost or the const-array boundary
    /// policy), so the element read is the one the interpreter reads.
    TableGather {
        src: SrcRef,
        table: u32,
        out: SlotId,
    },
    /// A compressed-row reduction over the 1-D term list `src`:
    ///
    /// ```text
    /// for c in 0..n_out:
    ///     acc = init
    ///     for k in rows[c] .. rows[c + 1]:
    ///         if mask is None or mask[k] != 0:  acc = kernel(op)(acc, src[k])
    ///     out[c] = acc
    /// ```
    ///
    /// with `rows = seg_tables[table].rows` (`n_out + 1` ascending offsets,
    /// the last equal to `src`'s length) and `c` the ROW-MAJOR cell of
    /// `out`'s box (a scalar `out` has one cell). Each cell's run lists its
    /// admitted contraction tuples in the interpreter's odometer order (the
    /// last contracted name fastest), and an excluded term is SKIPPED, not
    /// combined as the identity, exactly as `reduce_contraction`'s `continue`
    /// does — so the fold is bit-identical, signed zeros and NaNs included.
    SegReduce {
        op: BinCode,
        init: f64,
        src: SlotId,
        mask: Option<SlotId>,
        table: u32,
        out: SlotId,
    },
    /// `out`'s elements, in ROW-MAJOR order, are `src`'s elements in
    /// row-major order: the same element count under a different box. A
    /// column-major reshape (`eval_reshape`) is this between two axis
    /// reversals, which are plain [`Instr::Gather`] permutations.
    Reshape { src: SrcRef, out: SlotId },
    /// Latch `faults[fault]` as the evaluation's fail-closed fault, unless an
    /// earlier one is already latched (the oracle's `latch_gather_fault`,
    /// which keeps the FIRST). The lowering emits one where the per-cell
    /// oracle latches for certain whenever this point executes — an
    /// out-of-range read of a const array with no boundary policy, a
    /// subscript on a 0-D parameter — and it defines no slot: the value the
    /// oracle substitutes there (`NaN`) is carried by the ordinary
    /// instructions around it.
    Fault { fault: u32 },
    /// A causal self-reference sweep (esm-spec §4.3.1.1) over
    /// `sweeps[spec]`: the next `body_len` instructions are the recurrence's
    /// cell body, lowered once over the sweep position, and they run once per
    /// cell of the frame, in the order the spec fixes:
    ///
    /// ```text
    /// for cell in frame, recurrence axis outermost ascending,
    ///                    the other axes inside it in output_idx order:
    ///     coords[d] = cell[d] (1-based)
    ///     run the body
    ///     out[cell] = round(result)      // published before the next cell
    /// ```
    ///
    /// `round` is this instruction's own working precision, the rule's
    /// (`RecurScope::publish`). This is the interpreter's `sweep_recurrence`
    /// loop: every cell is evaluated by itself, in the normative order, and
    /// nothing is batched or reordered (CONFORMANCE_SPEC §5.19.2). Fusion
    /// copies it and its body verbatim.
    Sweep { spec: u32 },
    /// `out = src[subs]`, every subscript a scalar known only at run time
    /// (`scalar_reads[spec]`): each one rounded as `eval_index_args` rounds
    /// it, then resolved by the spec's kind — a causal self-read of the array
    /// an [`Instr::Sweep`] is building (the fail-closed
    /// `E_TREEWALK_RECUR_UNAVAILABLE` for a cell the sweep has not published),
    /// a state or observed read (the zero ghost out of range), or a
    /// const-array read (its boundary policy, else
    /// `E_TREEWALK_CONSTARRAY_OOB`). This is `index_into` with one full
    /// subscript tuple, and the recurrence scope's `read`.
    ScalarRead { src: SrcRef, spec: u32, out: SlotId },
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
    /// Execute the lane program `lanes[spec]`: one scalar micro-program run
    /// once per lane, each lane reading its own scalar sources and writing
    /// its own `dy` positions (see [`LaneSpec`]). Defines no slot.
    ///
    /// The rerolling pass ([`super::reroll`]) emits it: scalar instructions
    /// repeated with one structure over different scalars (one box of a
    /// many-box chemistry document per repetition) become one lane each.
    /// Per lane it applies exactly the kernels the scalar instructions
    /// applied, in their order, to the same operand values, so every value
    /// is the one the scalar program computed.
    Lanes { spec: u32 },
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
            | Instr::LoadForcing { out, .. }
            | Instr::Interp { out, .. }
            | Instr::Calendar { out, .. }
            | Instr::Reduce { out, .. }
            | Instr::Scan { out, .. }
            | Instr::PolyArea { out, .. }
            | Instr::IndexGather { out, .. }
            | Instr::TableGather { out, .. }
            | Instr::SegReduce { out, .. }
            | Instr::Reshape { out, .. }
            | Instr::ScalarRead { out, .. } => Some(*out),
            Instr::JmpIfZero { .. }
            | Instr::Sweep { .. }
            | Instr::Fault { .. }
            | Instr::Fallback { .. }
            | Instr::Export { .. }
            | Instr::DyWrite { .. }
            | Instr::Fused { .. }
            | Instr::Lanes { .. } => None,
        }
    }

    /// Visit every slot this instruction DEFINES ([`Instr::out`] plus the
    /// multi-output [`Instr::Fused`] and [`Instr::Sweep`] cases: a sweep
    /// defines the array it builds and its coordinate slots).
    pub(crate) fn for_each_def(&self, t: &SlotTables, mut f: impl FnMut(SlotId)) {
        match self {
            Instr::Sweep { spec } => {
                let sw = &t.sweeps[*spec as usize];
                f(sw.out);
                for &c in &sw.coords {
                    f(c);
                }
            }
            Instr::Lanes { spec } => {
                for w in &t.lanes[*spec as usize].writes {
                    if let LaneDst::Slot(s) = w.dst {
                        f(s);
                    }
                }
            }
            Instr::Fused { spec } => {
                let fs = &t.fused[*spec as usize];
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
    ///
    /// An [`Instr::Sweep`] reports the result it stores after each pass
    /// through its body; that read happens at the END of the body, which is
    /// where the slab coloring keeps it live to (`color_slab`). The body's
    /// instructions report their own reads.
    pub(crate) fn for_each_read(&self, t: &SlotTables, mut f: impl FnMut(SlotId)) {
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
            Instr::Un { a, .. } | Instr::Neg { a, .. } | Instr::Calendar { a, .. } => op(a),
            Instr::Select { cond, a, b, .. } => {
                op(cond);
                op(a);
                op(b);
            }
            Instr::Gather { src, .. }
            | Instr::LoadElem { src, .. }
            | Instr::Reduce { src, .. }
            | Instr::Scan { src, .. }
            | Instr::TableGather { src, .. }
            | Instr::Reshape { src, .. } => {
                if let SrcRef::Slot(s) = src {
                    f(*s);
                }
            }
            Instr::PolyArea { a, b, .. } => {
                for src in [a, b] {
                    if let SrcRef::Slot(s) = src {
                        f(*s);
                    }
                }
            }
            Instr::IndexGather { src, idx, .. } => {
                if let SrcRef::Slot(s) = src {
                    op(&Operand::Slot(*s));
                }
                op(idx);
            }
            Instr::SegReduce { src, mask, .. } => {
                f(*src);
                if let Some(m) = mask {
                    f(*m);
                }
            }
            Instr::Ramp { .. } | Instr::ConstArray { .. } | Instr::LoadForcing { .. } => {}
            Instr::Lanes { spec } => {
                let ls = &t.lanes[*spec as usize];
                for inp in &ls.inputs {
                    if inp.kind == LaneKind::Slot {
                        for l in 0..ls.lanes as usize {
                            op(&Operand::Slot(inp.ix.at(l)));
                        }
                    }
                }
                for sc in &ls.scalars {
                    op(sc);
                }
            }
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
                for (src, _) in &t.assemblies[*table as usize].parts {
                    op(src);
                }
            }
            Instr::ScalarRead { src, spec, .. } => {
                if let SrcRef::Slot(s) = src {
                    op(&Operand::Slot(*s));
                }
                let sp = &t.scalar_reads[*spec as usize];
                for s in &sp.subs {
                    op(s);
                }
                if let ScalarReadKind::SelfRead { sweep } = sp.kind {
                    for &c in &t.sweeps[sweep as usize].coords {
                        op(&Operand::Slot(c));
                    }
                }
            }
            Instr::JmpIfZero { cond, .. } => op(cond),
            Instr::Sweep { spec } => op(&t.sweeps[*spec as usize].result),
            Instr::Fallback { .. } | Instr::Fault { .. } => {}
            Instr::Export { slot, .. } => f(*slot),
            Instr::DyWrite { write } => f(t.dy_writes[*write as usize].slot),
            Instr::Fused { spec } => {
                let fs = &t.fused[*spec as usize];
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
            Instr::LoadForcing { .. } => "LoadForcing",
            Instr::Interp { .. } => "Interp",
            Instr::Calendar { .. } => "Calendar",
            Instr::Reduce { .. } => "Reduce",
            Instr::Scan { .. } => "Scan",
            Instr::PolyArea { .. } => "PolyArea",
            Instr::IndexGather { .. } => "IndexGather",
            Instr::TableGather { .. } => "TableGather",
            Instr::SegReduce { .. } => "SegReduce",
            Instr::Reshape { .. } => "Reshape",
            Instr::Fault { .. } => "Fault",
            Instr::Sweep { .. } => "Sweep",
            Instr::ScalarRead { .. } => "ScalarRead",
            Instr::JmpIfZero { .. } => "JmpIfZero",
            Instr::Fallback { .. } => "Fallback",
            Instr::Export { .. } => "Export",
            Instr::DyWrite { .. } => "DyWrite",
            Instr::Fused { .. } => "Fused",
            Instr::Lanes { .. } => "Lanes",
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
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
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
    /// An absorbed [`Instr::Scan`] along one axis of the group box: `row`
    /// steps along that axis, each `post` flat elements apart (the extent of
    /// the axes after it). Lane `q = flat % post` keeps its running fold of
    /// `a` from `init` in carry slot `carry + q`, restarted where the step
    /// index `(flat / post) % row` is 0 and carried across chunks and runs.
    /// Inclusive: `acc = kernel(op)(acc, a); out = acc`; exclusive: `out =
    /// acc; acc = kernel(op)(acc, a)`. A group visits its box in ascending
    /// flat order, which visits every lane's steps in ascending order, so
    /// every element folds the same terms in the same association as
    /// `Instr::Scan`.
    Scan {
        op: BinCode,
        a: MRef,
        init: f64,
        inclusive: bool,
        row: u32,
        post: u32,
        carry: u32,
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
    /// constant stride; 0 = one source element for the whole run, a read
    /// broadcast along the box's innermost axis). Meaningful only for shifted
    /// inputs.
    pub elem_stride: i64,
    /// For a shifted input with `elem_stride` other than 1 and 0 (and 0 too in
    /// a group with a `Bin3` superop): the chunk register the executor
    /// pre-loads this input into (`GroupIx::MAX` otherwise; a zero-stride
    /// input is then read as the run's one element). A folded data-subscript
    /// gather is always pre-loaded.
    pub load_reg: GroupIx,
    /// `Some((by, n))`: a folded [`Instr::IndexGather`] of a rank-1 source
    /// of extent `n`. The element at output offset `k` is
    /// `src[data_subscript(inputs[by][k], n)]`, the zero ghost when that is
    /// `None`; `inputs[by]` is the subscript array, an aligned input.
    pub index: Option<(GroupIx, usize)>,
    /// `Some`: a folded [`Instr::Gather`] whose shifts would split the box
    /// into too many runs to fold as a shifted read (a shift along the
    /// innermost axis), read through its plan into this input's chunk
    /// register one chunk at a time (see [`ChunkGather`]). An aligned input
    /// otherwise.
    pub gather: Option<Box<ChunkGather>>,
}

/// A same-rank gather plan with no fixed, broadcast or permuted axes, read
/// over a flat range of its output box: the element at row-major output
/// position `(i_0, .., i_{d-1})` is the source element at `src_off + Σ
/// strides[a] · (so_a + i_a - o_a)` when every `i_a` lies in a segment
/// `(o_a, len, so_a)` of axis `a`, and the zero ghost otherwise — the
/// element `Instr::Gather` would write there (its segments are disjoint).
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ChunkGather {
    /// Per output axis: copy segments `(out_off, len, src_off)`, ascending in
    /// `out_off`.
    pub segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]>,
    /// Per output axis: the source's row-major flat stride.
    pub strides: SmallVec<[i64; 4]>,
    /// The output box.
    pub shape: DimU,
    /// Read the whole box once when the group starts, into the executor's
    /// scratch, and then like an aligned input — for rows so short, or a
    /// group so light, that the per-row work of a chunk read costs more. The
    /// choice changes no instruction, so it may depend on the box.
    pub whole: bool,
}

impl ChunkGather {
    /// The source coordinate along axis `a` at output coordinate `i`, or
    /// `None` in the ghost.
    #[inline(always)]
    fn coord(&self, a: usize, i: usize) -> Option<usize> {
        self.segs[a]
            .iter()
            .find(|&&(o, l, _)| o <= i && i < o + l)
            .map(|&(o, _, so)| so + (i - o))
    }

    /// The flat source offset of output position `flat`, or `None` in the
    /// ghost (the per-element definition the reference executor uses).
    pub(crate) fn src_offset(&self, flat: usize) -> Option<i64> {
        let mut rest = flat;
        let mut off = 0i64;
        for a in (0..self.shape.len()).rev() {
            let i = rest % self.shape[a];
            rest /= self.shape[a];
            off += self.strides[a] * self.coord(a, i)? as i64;
        }
        Some(off)
    }

    /// Write output positions `at .. at + c` into `dst[0 .. c]`, one row of
    /// the innermost axis at a time: the leading axes' source offset is
    /// carried from row to row like an odometer, and each row is its
    /// innermost-axis segments copied and the gaps between them zeroed. A
    /// plain shift ([`Self::flat_shift`]) is copied in one piece instead.
    ///
    /// # Safety
    /// `src` must hold the plan's source box row-major and `dst` `c`
    /// elements, disjoint from it.
    #[inline(always)]
    pub(crate) unsafe fn fill(&self, src: *const f64, at: usize, c: usize, dst: *mut f64) {
        if let Some(delta) = self.flat_shift() {
            unsafe { self.fill_shifted(delta, src, at, c, dst) };
            return;
        }
        let nd = self.shape.len();
        let last = self.shape[nd - 1];
        let s_last = self.strides[nd - 1];
        // The leading coordinates of the first row, and each one's source
        // contribution (`None` in the ghost).
        let mut idx: SmallVec<[usize; 4]> = SmallVec::from_elem(0, nd - 1);
        let mut part: SmallVec<[Option<i64>; 4]> = SmallVec::from_elem(None, nd - 1);
        let mut rest = at / last;
        for a in (0..nd - 1).rev() {
            idx[a] = rest % self.shape[a];
            rest /= self.shape[a];
            part[a] = self.coord(a, idx[a]).map(|x| self.strides[a] * x as i64);
        }
        let mut col = at % last;
        let mut k = 0usize;
        while k < c {
            let len = (c - k).min(last - col);
            let off = part.iter().try_fold(0i64, |o, p| p.map(|p| o + p));
            unsafe {
                let d = std::slice::from_raw_parts_mut(dst.add(k), len);
                match off {
                    None => d.fill(0.0),
                    Some(off) => {
                        // Segments are disjoint; walk them in output order,
                        // zeroing what lies between.
                        let mut pos = col;
                        for &(o, l, so) in &self.segs[nd - 1] {
                            let lo = o.max(col);
                            let hi = (o + l).min(col + len);
                            if lo >= hi {
                                continue;
                            }
                            if lo > pos {
                                d[pos - col..lo - col].fill(0.0);
                            }
                            let s = src.offset((off + s_last * (so + lo - o) as i64) as isize);
                            let out = &mut d[lo - col..hi - col];
                            if s_last == 1 {
                                out.copy_from_slice(std::slice::from_raw_parts(s, hi - lo));
                            } else {
                                for (j, x) in out.iter_mut().enumerate() {
                                    *x = *s.offset(j as isize * s_last as isize);
                                }
                            }
                            pos = pos.max(hi);
                        }
                        if pos < col + len {
                            d[pos - col..].fill(0.0);
                        }
                    }
                }
            }
            k += len;
            col = 0;
            // Next row: advance the leading odometer.
            let mut a = nd - 1;
            while a > 0 {
                a -= 1;
                idx[a] += 1;
                if idx[a] < self.shape[a] {
                    part[a] = self.coord(a, idx[a]).map(|x| self.strides[a] * x as i64);
                    break;
                }
                idx[a] = 0;
                part[a] = self.coord(a, 0).map(|x| self.strides[a] * x as i64);
            }
        }
    }

    /// The flat offset `delta` when the gather is one shift of a source laid
    /// out like its output box (`strides` row-major over `shape`, one
    /// non-empty segment per axis): output position `flat` inside the
    /// segment box then reads source position `flat + delta`.
    #[inline(always)]
    fn flat_shift(&self) -> Option<i64> {
        let mut stride = 1i64;
        let mut delta = 0i64;
        for a in (0..self.shape.len()).rev() {
            let &[(o, l, so)] = &self.segs[a][..] else {
                return None;
            };
            if self.strides[a] != stride || l == 0 {
                return None;
            }
            delta += stride * (so as i64 - o as i64);
            stride *= self.shape[a] as i64;
        }
        Some(delta)
    }

    /// [`Self::fill`] for a [`Self::flat_shift`] gather: the window's part of
    /// the segment box's flat span copied in one piece, then the ghost
    /// positions in it zeroed, axis by axis (each axis's out-of-segment
    /// slabs, a ghost reached twice is zeroed twice).
    ///
    /// # Safety
    /// As for [`Self::fill`].
    #[inline(always)]
    unsafe fn fill_shifted(&self, delta: i64, src: *const f64, at: usize, c: usize, dst: *mut f64) {
        let nd = self.shape.len();
        let (mut first, mut last, mut stride) = (0usize, 0usize, 1usize);
        for a in (0..nd).rev() {
            let (o, l, _) = self.segs[a][0];
            first += stride * o;
            last += stride * (o + l - 1);
            stride *= self.shape[a];
        }
        let end = at + c;
        let (lo, hi) = (at.max(first), end.min(last + 1));
        if lo < hi {
            // Every position of `[first, last]` reads in bounds: its ends
            // read the segment box's first and last source elements.
            unsafe {
                std::ptr::copy_nonoverlapping(
                    src.offset(lo as isize + delta as isize),
                    dst.add(lo - at),
                    hi - lo,
                )
            };
        }
        let mut inner = 1usize;
        for a in (0..nd).rev() {
            let (o, l, _) = self.segs[a][0];
            let n = self.shape[a];
            let blk = n * inner;
            if o > 0 || o + l < n {
                let gaps = [(0, o * inner), ((o + l) * inner, blk)];
                let mut q = at - at % blk;
                while q < end {
                    for &(g0, g1) in &gaps {
                        let (s, e) = ((q + g0).max(at), (q + g1).min(end));
                        if s >= e {
                            continue;
                        }
                        // One-element gaps (a unit shift's ghost row ends)
                        // are stored directly rather than through `memset`.
                        unsafe {
                            if e - s == 1 {
                                *dst.add(s - at) = 0.0;
                            } else {
                                std::slice::from_raw_parts_mut(dst.add(s - at), e - s).fill(0.0);
                            }
                        }
                    }
                    q += blk;
                }
            }
            inner = blk;
        }
    }
}

/// Sentinel source offset: the input reads the gather's Dirichlet ghost
/// (`+0.0`) over the whole run.
pub(crate) const GHOST_OFF: i64 = i64::MIN;

/// One contiguous run of a fused group's precompiled schedule. Runs partition
/// the (row-major flat) output box; within a run every shifted input is either
/// a single constant flat offset into its source or entirely ghost.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FusedRun {
    pub out_off: u32,
    pub len: u32,
    /// Per SHIFTED input (indexed by `FusedInput::shifted_ix`): the 0-based
    /// flat source offset of the run's first element, or [`GHOST_OFF`].
    pub in_off: SmallVec<[i64; 2]>,
}

impl FusedRun {
    /// This run moved `k` steps of `(out_step, in_step)`: every offset
    /// advanced, a ghost input left ghost.
    pub(crate) fn stepped(&self, k: i64, out_step: i64, in_step: &[i64]) -> FusedRun {
        FusedRun {
            out_off: (self.out_off as i64 + k * out_step) as u32,
            len: self.len,
            in_off: self
                .in_off
                .iter()
                .zip(in_step)
                .map(|(&o, &s)| if o == GHOST_OFF { o } else { o + k * s })
                .collect(),
        }
    }
}

/// One node of a [`RunSchedule`].
#[derive(Clone, Debug)]
pub(crate) enum RunNode {
    Run(FusedRun),
    /// The `body` nodes that follow (a subtree), executed `count` (>= 2)
    /// times in order; the `k`-th time (from 0) every run in them has its
    /// `out_off` advanced by `k * out_step` and every non-ghost `in_off[j]`
    /// by `k * in_step[j]`. A regular sequence of rows -- one row's runs
    /// repeated at a constant stride in the output and in every source -- is
    /// one such node, so the schedule's size does not grow with the box.
    Repeat {
        count: u32,
        body: u32,
        out_step: i64,
        in_step: SmallVec<[i64; 2]>,
    },
}

/// A fused group's precompiled run schedule: the runs, in ascending
/// `out_off` and maximally coalesced, that partition its box, with regular
/// repetitions kept as [`RunNode::Repeat`] instead of written out.
#[derive(Clone, Debug)]
pub(crate) struct RunSchedule {
    /// Pre-order: a `Repeat` is followed by its body.
    pub nodes: Vec<RunNode>,
    /// The runs it executes (a repeated body counted once per repetition).
    pub n_runs: usize,
    /// The deepest nesting of `Repeat` nodes.
    pub depth: usize,
}

impl RunSchedule {
    /// The one-run schedule `(0, n_elems, [])` of a group with no shifted
    /// inputs.
    pub(crate) fn whole(n_elems: usize) -> Self {
        RunSchedule {
            nodes: vec![RunNode::Run(FusedRun {
                out_off: 0,
                len: n_elems as u32,
                in_off: SmallVec::new(),
            })],
            n_runs: 1,
            depth: 0,
        }
    }

    /// Every run the schedule executes, in execution order, with its
    /// repetition applied (diagnostics and the reference executor; the
    /// production executor walks the nodes without expanding them).
    pub(crate) fn for_each_run(&self, mut f: impl FnMut(&FusedRun)) {
        fn walk(nodes: &[RunNode], out_d: i64, in_d: &[i64], f: &mut impl FnMut(&FusedRun)) {
            let mut i = 0usize;
            while i < nodes.len() {
                match &nodes[i] {
                    RunNode::Run(r) => {
                        f(&r.stepped(1, out_d, in_d));
                        i += 1;
                    }
                    RunNode::Repeat {
                        count,
                        body,
                        out_step,
                        in_step,
                    } => {
                        let body_nodes = &nodes[i + 1..i + 1 + *body as usize];
                        for k in 0..*count as i64 {
                            let d: SmallVec<[i64; 2]> =
                                in_d.iter().zip(in_step).map(|(&a, &s)| a + k * s).collect();
                            walk(body_nodes, out_d + k * out_step, &d, f);
                        }
                        i += 1 + *body as usize;
                    }
                }
            }
        }
        let n_in = self.nodes.iter().find_map(|n| match n {
            RunNode::Run(r) => Some(r.in_off.len()),
            RunNode::Repeat { .. } => None,
        });
        let zeros: SmallVec<[i64; 2]> = SmallVec::from_elem(0, n_in.unwrap_or(0));
        walk(&self.nodes, 0, &zeros, &mut f);
    }

    /// The expanded runs (see [`Self::for_each_run`]).
    pub(crate) fn expanded(&self) -> Vec<FusedRun> {
        let mut v = Vec::with_capacity(self.n_runs);
        self.for_each_run(|r| v.push(r.clone()));
        v
    }
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
    /// `(micro-op, output)`: the micro-op writes that entry of `outputs`
    /// straight to its destination instead of its register, which is then
    /// not stored. It is the register's last writer, no later micro-op (nor
    /// the reduction) reads the register, and no other output names it. A
    /// group's outputs never share storage with its inputs (a `Fused`
    /// instruction is not alias-safe for the slab coloring), so an early
    /// store cannot change what a later micro-op reads.
    pub direct: SmallVec<[(u32, u32); 2]>,
    /// Absorbed scans the executor runs in one loop with their single-use
    /// `+ - * /` neighbours (see [`ScanFuse`]).
    pub scan_fuse: SmallVec<[ScanFuse; 1]>,
    /// Precompiled run schedule (see [`RunSchedule`]); a group with no
    /// shifted inputs has the single run `(0, n_elems, [])`.
    pub schedule: RunSchedule,
    /// An absorbed [`Instr::Reduce`] over the group box, folding one register
    /// instead of storing it (see [`FusedReduce`]).
    pub reduce: Option<FusedReduce>,
    /// For a group with an absorbed reduction whose box is a few leading
    /// positions of one run each (run `k` covering `[k * n_inner, (k + 1) *
    /// n_inner)`) and no scan: those runs, expanded. The executor then walks
    /// the accumulator chunk by chunk, folding every position into a chunk
    /// before the next — the same per-output fold order.
    pub interleave: Option<Vec<FusedRun>>,
    /// Diagnostics: original instructions replaced (members incl. deleted
    /// folded gathers).
    pub n_fused_instrs: u32,
    pub n_folded_gathers: u32,
}

/// A [`MicroOp::Scan`] along the group box's last axis (`post == 1`) whose
/// operand, when `pre`, is the `Bin` just before it (read by the scan
/// alone), and whose value, when `post`, no micro-op but the `Bin` just
/// after it reads (it may still be a live-out, which `keep` says). The
/// neighbours are `+ - * /`, the scan a sum or a product. Under Float64 the
/// executor runs them as one loop, element by element in order: `x =
/// pre(..)`, the scan's combine, `out = post(..)` — the same kernels in the
/// same order as the three passes, with the absorbed neighbours' registers
/// never written. The latency-bound fold then carries the neighbours' loads
/// and stores, which otherwise each take a pass of their own.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ScanFuse {
    /// The scan's micro-op index.
    pub scan: u32,
    pub pre: bool,
    pub post: bool,
    /// With `post`: the scan's value is also a live-out, so the loop stores
    /// it to its register as well (unless no output it feeds is stored).
    pub keep: bool,
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
    /// Scans absorbed into a group as [`MicroOp::Scan`] (the `Scan`
    /// instruction is deleted).
    pub n_scans_folded: usize,
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
    /// Row-major elements, exactly as `json_to_value` produces them from the
    /// literal (precision-rounded at ingress under `element_type: "Float32"`)
    /// — taken from the declared data directly for a lowered shaped-parameter
    /// default.
    pub values: Vec<f64>,
}

/// The position an [`Instr::TableGather`] element reads when its source cell
/// is out of range: the element is the zero ghost `+0.0`.
pub(crate) const GATHER_GHOST: u32 = u32::MAX;

/// The build-time positions of one [`Instr::TableGather`].
#[derive(Clone, Debug)]
pub(crate) struct GatherTable {
    /// The source box the positions are row-major flat offsets into.
    pub src_shape: DimU,
    /// One source position per output element, or [`GATHER_GHOST`].
    pub pos: Vec<u32>,
}

/// The row offsets of one [`Instr::SegReduce`]: output cell `c` folds terms
/// `rows[c] .. rows[c + 1]`.
#[derive(Clone, Debug)]
pub(crate) struct SegTable {
    pub rows: Vec<u32>,
}

/// The constant part of one [`Instr::Sweep`].
#[derive(Clone, Debug)]
pub(crate) struct SweepSpec {
    /// The variable the recurrence defines, as the compiled model spells it:
    /// the name an unavailable self-read's fault message carries.
    pub var: String,
    /// The array being built: the whole frame, row-major, origin all 1s.
    pub out: SlotId,
    /// One scalar slot per frame axis, in `output_idx` order, holding the
    /// current cell's 1-based coordinate while the body runs.
    pub coords: SmallVec<[SlotId; 4]>,
    /// The frame's extents (origin all 1s).
    pub shape: DimU,
    /// The recurrence axis: the outermost loop, ascending.
    pub axis: u8,
    /// The body: this many instructions after the `Sweep`.
    pub body_len: u32,
    /// The cell's value, read after each pass through the body.
    pub result: Operand,
}

impl SweepSpec {
    /// Cells in the frame (0 when an extent is 0).
    pub(crate) fn n_cells(&self) -> usize {
        self.shape.iter().product()
    }

    /// The frame axes in sweep order, slowest first: the recurrence axis,
    /// then every other axis in `output_idx` order.
    fn order(&self) -> impl DoubleEndedIterator<Item = usize> + '_ {
        let axis = self.axis as usize;
        std::iter::once(axis).chain((0..self.shape.len()).filter(move |&d| d != axis))
    }

    /// Advance the 0-based frame cell `cell` to the next one in sweep order
    /// (the last axis of the order fastest, as `CartesianTuples` walks the
    /// inner axes); `false` after the last cell.
    pub(crate) fn advance(&self, cell: &mut [usize]) -> bool {
        for d in self.order().rev() {
            cell[d] += 1;
            if cell[d] < self.shape[d] {
                return true;
            }
            cell[d] = 0;
        }
        false
    }

    /// Where the 0-based frame cell `cell` falls in the sweep.
    pub(crate) fn ordinal(&self, cell: &[usize]) -> usize {
        self.order().fold(0, |o, d| o * self.shape[d] + cell[d])
    }

    /// Row-major flat offset of the 0-based frame cell `cell` in `out`.
    pub(crate) fn flat(&self, cell: &[usize]) -> usize {
        (0..self.shape.len()).fold(0, |o, d| o * self.shape[d] + cell[d])
    }
}

/// How an [`Instr::ScalarRead`] resolves its subscripts.
#[derive(Clone, Debug)]
pub(crate) enum ScalarReadKind {
    /// A causal self-read of the array `sweeps[sweep]` is building
    /// (`RecurScope::read`): a cell outside the frame, or one the sweep has
    /// not published yet — at or after the current cell in sweep order — is
    /// the fail-closed `E_TREEWALK_RECUR_UNAVAILABLE`, never a value. A read
    /// cell is rounded to the working precision, as the scope rounds it.
    SelfRead { sweep: u32 },
    /// A state or observed array: out of range reads the zero ghost.
    ZeroGhost,
    /// A const array (CONFORMANCE_SPEC §5.5.5): out of range resolves by
    /// `policy[d]` (already `Error` for an empty dimension), and the error is
    /// `E_TREEWALK_CONSTARRAY_OOB` naming `name`.
    ConstArray {
        name: String,
        policy: SmallVec<[crate::value_invention::BoundaryKind; 4]>,
    },
}

/// The constant part of one [`Instr::ScalarRead`].
#[derive(Clone, Debug)]
pub(crate) struct ScalarReadSpec {
    /// One scalar subscript per source axis.
    pub subs: SmallVec<[Operand; 4]>,
    pub kind: ScalarReadKind,
}

/// What an [`Instr::ScalarRead`] reads, once its subscripts are known.
pub(crate) enum ScalarReadAt {
    /// The source element at these 0-based positions.
    Elem(SmallVec<[usize; 4]>),
    /// The zero ghost.
    Ghost,
    /// A fail-closed fault with this message; the value is `NaN`.
    Fault(String),
}

impl ScalarReadSpec {
    /// Resolve the 1-based subscripts `raw` (each already rounded by
    /// [`subscript_of`]) against a source of extents `src_shape`. `cur` is the
    /// sweep's current 0-based cell, read only by a self-read.
    ///
    /// The single definition every executor calls, so their reads cannot
    /// drift from one another; it restates `index_into` (the zero ghost, the
    /// const-array policies, the first faulting dimension's message) and
    /// `RecurScope::read` + `latch_recur_unavailable`.
    pub(crate) fn resolve(
        &self,
        raw: &[i64],
        src_shape: &[usize],
        sweeps: &[SweepSpec],
        cur: &[usize],
    ) -> ScalarReadAt {
        match &self.kind {
            ScalarReadKind::SelfRead { sweep } => {
                let sw = &sweeps[*sweep as usize];
                let mut cell: SmallVec<[usize; 4]> = SmallVec::new();
                for (d, &r) in raw.iter().enumerate() {
                    if r < 1 || r > sw.shape[d] as i64 {
                        return ScalarReadAt::Fault(
                            crate::simulate_array::eval::recur_unavailable_message(&sw.var, raw),
                        );
                    }
                    cell.push((r - 1) as usize);
                }
                if sw.ordinal(&cell) >= sw.ordinal(cur) {
                    return ScalarReadAt::Fault(
                        crate::simulate_array::eval::recur_unavailable_message(&sw.var, raw),
                    );
                }
                ScalarReadAt::Elem(cell)
            }
            ScalarReadKind::ZeroGhost => {
                let mut ix: SmallVec<[usize; 4]> = SmallVec::new();
                for (d, &r) in raw.iter().enumerate() {
                    if r < 1 || r > src_shape[d] as i64 {
                        return ScalarReadAt::Ghost;
                    }
                    ix.push((r - 1) as usize);
                }
                ScalarReadAt::Elem(ix)
            }
            ScalarReadKind::ConstArray { name, policy } => {
                use crate::value_invention::BoundaryKind;
                let mut ix: SmallVec<[usize; 4]> = SmallVec::new();
                for (d, &r) in raw.iter().enumerate() {
                    let n = src_shape[d] as i64;
                    let at = if (1..=n).contains(&r) {
                        Some((r - 1) as usize)
                    } else {
                        match policy[d] {
                            BoundaryKind::Periodic if n >= 1 => {
                                Some((r - 1).rem_euclid(n) as usize)
                            }
                            BoundaryKind::Clamp if n >= 1 => Some((r.clamp(1, n) - 1) as usize),
                            _ => None,
                        }
                    };
                    match at {
                        Some(i) => ix.push(i),
                        None => {
                            return ScalarReadAt::Fault(
                                crate::simulate_array::eval::const_oob_message(name, r, n, d),
                            );
                        }
                    }
                }
                ScalarReadAt::Elem(ix)
            }
        }
    }
}

/// The 1-based position an index expression's value names: `eval_index_args`'
/// `f.round() as i64` (NaN reads as 0, and an out-of-range value saturates).
#[inline]
pub(crate) fn subscript_of(v: f64) -> i64 {
    v.round() as i64
}

/// The program tables an instruction's slot reads and definitions are found
/// through ([`Instr::for_each_read`], [`Instr::for_each_def`]).
pub(crate) struct SlotTables<'a> {
    pub dy_writes: &'a [DyWrite],
    pub fused: &'a [FusedSpec],
    pub assemblies: &'a [AssembleSpec],
    pub sweeps: &'a [SweepSpec],
    pub scalar_reads: &'a [ScalarReadSpec],
    pub lanes: &'a [LaneSpec],
}

/// One forcing-buffer entry the program reads ([`Instr::LoadForcing`]).
#[derive(Clone, Debug)]
pub(crate) struct ForcingRef {
    /// The buffer key, which is the variable's name as the compiled model
    /// spells it.
    pub name: String,
    /// The box the program was built against (empty for a 0-d entry): the
    /// entry's shape when the buffer held it at build time, else the
    /// variable's declared shape.
    pub shape: DimU,
}

/// The nine calendar entries of the esm-spec §9.2 closed-function registry;
/// [`Instr::Calendar`]'s `func` indexes here.
pub(crate) const CALENDAR_FNS: [&str; 9] = [
    "datetime.year",
    "datetime.month",
    "datetime.day",
    "datetime.hour",
    "datetime.minute",
    "datetime.second",
    "datetime.day_of_year",
    "datetime.julian_day",
    "datetime.is_leap_year",
];

/// [`Instr::Calendar`]'s element: the registry's answer for `CALENDAR_FNS[func]`
/// at the binary64 `t_utc`, promoted to `f64` without rounding, or `NaN` when
/// the registry refuses the argument — `eval_fn`'s own reading of a `fn` node.
pub(crate) fn calendar_at(func: u8, t_utc: f64) -> f64 {
    use crate::registered_functions::{ClosedArg, evaluate_closed_function};
    evaluate_closed_function(CALENDAR_FNS[func as usize], &[ClosedArg::Scalar(t_utc)])
        .map(|v| v.as_f64())
        .unwrap_or(f64::NAN)
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
    /// The id of the `out_of_bounds: "error"` table this call was lowered
    /// from (esm-spec §9.5.1), or `None` for a clamping lookup. When set,
    /// every query is checked against its axis before the blend.
    pub strict: Option<String>,
}

impl InterpTable {
    /// Evaluate this entry at one query point — the SINGLE definition the fast
    /// executor, the reference executor and the build-time constant fold all
    /// call. `y` is read only by [`InterpKind::Bilinear`].
    ///
    /// A strict table's out-of-range query latches the oracle's
    /// `table_lookup_out_of_bounds` fault and yields the `NaN` the oracle
    /// substitutes alongside it.
    pub(crate) fn at(&self, x: f64, y: f64) -> f64 {
        use crate::registered_functions::{interp_bilinear_at, interp_linear_at, searchsorted_at};
        if let Some(fault) = self.out_of_bounds(x, y) {
            crate::simulate_array::eval::latch_gather_fault(fault);
            return f64::NAN;
        }
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

    /// The fault a strict table raises for this query point, checked in the
    /// oracle's order (the first axis, then the second), or `None`.
    pub(crate) fn out_of_bounds(&self, x: f64, y: f64) -> Option<String> {
        use crate::lower_table_lookup::out_of_bounds_fault;
        let id = self.strict.as_deref()?;
        out_of_bounds_fault(id, 1, &self.axis_x, x).or_else(|| match self.kind {
            InterpKind::Bilinear => out_of_bounds_fault(id, 2, &self.axis_y, y),
            InterpKind::Linear | InterpKind::SearchSorted => None,
        })
    }
}

/// Where one [`Instr::PolyArea`] element reads a ring along one LEADING axis
/// of the ring table (the table is `[.., V, 2]`: the last two axes are the
/// ring's vertices and its `(lon, lat)` pair).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RingSel {
    /// This 0-based position, for every element.
    Fixed(usize),
    /// Position `p + off` for the element at position `p` along output axis
    /// `axis` (a partial `index(table, i)` whose subscript is `i + k`). Every
    /// position the box reaches is inside the table, checked at lowering.
    Axis { axis: u8, off: i64 },
}

/// One ring operand of an [`Instr::PolyArea`]: the table's box and how each
/// of its leading axes is addressed. No selectors means the operand is the
/// whole `[V, 2]` array, the same ring for every element.
#[derive(Clone, Debug)]
pub(crate) struct RingRef {
    /// The expected table box (validation).
    pub src_shape: DimU,
    pub sel: SmallVec<[RingSel; 3]>,
}

impl RingRef {
    /// The output axes this operand's ring varies along.
    pub(crate) fn axes(&self) -> SmallVec<[u8; 3]> {
        let mut v: SmallVec<[u8; 3]> = SmallVec::new();
        for s in &self.sel {
            if let RingSel::Axis { axis, .. } = s
                && !v.contains(axis)
            {
                v.push(*axis);
            }
        }
        v
    }
}

/// The constant part of one [`Instr::PolyArea`].
///
/// `pairs` is the broad phase: `Some((axis_a, axis_b))` when the manifold is
/// planar and ring `a` varies along output axis `axis_a` only and ring `b`
/// along the different axis `axis_b` only. The instruction then clips just
/// the candidate pairs whose bounding boxes are not strictly disjoint (an
/// R*-tree query over the two rings' boxes, so the work is `O(n log n)` plus
/// the candidates, not the product) and writes every other element the value
/// the kernel's own disjoint-box reject returns. That reject is part of
/// `crate::geometry::intersect_polygon`, which is what makes the skipped
/// pairs exact rather than approximately zero. Every element is still a pure
/// function of its own pair, so the order pairs are visited in cannot reach
/// a result, and a fold over the box downstream is unchanged.
#[derive(Clone, Debug)]
pub(crate) struct GeomSpec {
    pub manifold: crate::geometry::Manifold,
    pub a: RingRef,
    pub b: RingRef,
    /// The output box (empty for a scalar slot).
    pub shape: DimU,
    pub pairs: Option<(u8, u8)>,
}

/// How one source axis of an [`Instr::IndexGather`] is addressed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum GatherAxis {
    /// By the data subscript (the instruction's `idx` operand).
    Data,
    /// 0-based position `p + off` for output position `p` along `axis`; in
    /// range for every position, checked at lowering.
    Affine { axis: u8, off: i64 },
    /// This 0-based position.
    Fixed(usize),
}

/// The constant part of one [`Instr::IndexGather`].
#[derive(Clone, Debug)]
pub(crate) struct IndexGatherSpec {
    /// One entry per source axis; exactly one is [`GatherAxis::Data`].
    pub axes: SmallVec<[GatherAxis; 4]>,
    /// The expected source box (validation).
    pub src_shape: DimU,
    /// The output box.
    pub shape: DimU,
}

impl IndexGatherSpec {
    /// The source axis the data subscript addresses.
    pub(crate) fn data_axis(&self) -> usize {
        self.axes
            .iter()
            .position(|a| *a == GatherAxis::Data)
            .expect("an IndexGather has one data axis")
    }
}

/// The 0-based source position a data subscript `v` addresses along an axis
/// of extent `n`, or `None` for the zero ghost — `eval_index_args` then
/// `index_into` exactly: `v.round() as i64` (NaN reads as 0, out-of-range
/// values saturate), and a 1-based position outside `1..=n` is out of range.
#[inline]
pub(crate) fn data_subscript(v: f64, n: usize) -> Option<usize> {
    let one_based = v.round() as i64;
    (one_based >= 1 && one_based <= n as i64).then(|| (one_based - 1) as usize)
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
    /// A left-hand side that is not a constant shift of the output indices
    /// (`D(u[n + 1 - i])`, `D(m[j, i])` over `[i, j]`): the absolute `dy`
    /// position of each element of `slot`, in its ROW-MAJOR order, written in
    /// that order, so where two cells address one position the later one
    /// stands — the per-cell oracle's walk over the output box. `dest_lo` is
    /// unused when this is `Some`.
    pub scatter: Option<Vec<usize>>,
}

/// What the entries of a [`LaneTable`] address.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum LaneKind {
    /// A flat offset into the state vector (a scalar state's element).
    State,
    /// A position in the parameter vector.
    Param,
    /// A scalar slot.
    Slot,
}

/// One `u32` per lane: a table, or `base + l * step` when the lanes are
/// evenly spaced (stored without the table).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum LaneIx {
    Affine { base: u32, step: u32 },
    Table(Vec<u32>),
}

impl LaneIx {
    /// The compact form of `ix`.
    pub(crate) fn of(ix: Vec<u32>) -> Self {
        if let [b, n, ..] = ix[..]
            && n >= b
        {
            let step = n - b;
            if ix
                .iter()
                .enumerate()
                .all(|(l, &v)| u64::from(b) + l as u64 * u64::from(step) == u64::from(v))
            {
                return LaneIx::Affine { base: b, step };
            }
        }
        LaneIx::Table(ix)
    }

    /// Lane `l`'s entry.
    #[inline(always)]
    pub(crate) fn at(&self, l: usize) -> u32 {
        match self {
            LaneIx::Affine { base, step } => base + l as u32 * step,
            LaneIx::Table(t) => t[l],
        }
    }
}

/// The per-lane scalar sources of one lane-program input, all of one kind.
#[derive(Clone, Debug)]
pub(crate) struct LaneTable {
    pub kind: LaneKind,
    pub ix: LaneIx,
}

/// Where a lane program's write lands.
#[derive(Clone, Debug)]
pub(crate) enum LaneDst {
    /// Lane `l` writes `dy[pos.at(l)]`.
    Dy(LaneIx),
    /// The scalar slot (a one-lane program only): a value read after the
    /// program.
    Slot(SlotId),
}

/// One write of a lane program, after its micro-program.
#[derive(Clone, Debug)]
pub(crate) struct LaneWrite {
    pub src: MRef,
    pub dst: LaneDst,
}

/// A lane program ([`Instr::Lanes`]): `micro` runs once per lane over a
/// register file of `n_regs` registers, `MRef::In(i)` reading lane `l`'s
/// entry of `inputs[i]` and `MRef::Scal(i)` the operand `scalars[i]` (the
/// same for every lane). Then each write stores its value at its lane's `dy`
/// position, or (one lane only) in its slot. The `dy` positions of all lanes
/// and writes are distinct, so the order lanes run in reaches no result.
///
/// A one-lane program is a compiled straight run of scalar instructions:
/// its operands are all scalars, read once, and its micro-ops run one
/// after another over a scalar register file.
#[derive(Clone, Debug)]
pub(crate) struct LaneSpec {
    pub lanes: u32,
    pub inputs: Vec<LaneTable>,
    pub scalars: Vec<Operand>,
    pub micro: Vec<MicroOp>,
    pub n_regs: GroupIx,
    pub writes: Vec<LaneWrite>,
    /// `(micro-op, write)`: the micro-op stores its chunk straight into the
    /// `dy` run of that write (an evenly spaced, unit-step `Dy` write),
    /// which then does nothing. It is the last writer of the write's
    /// register, nothing after it reads that register, and no other write
    /// names it. Empty for a one-lane program.
    pub direct: Vec<(u32, u32)>,
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
    /// Per instruction, the precision its kernels run at (esm-spec §11.3.1):
    /// the precision in force while it was lowered — its observed rule's
    /// variable's, or a precision-boundary marker's inside it. Every executor
    /// arms it around the instruction. EMPTY when every instruction runs at
    /// the precision the program executes under, which is every document that
    /// declares no per-variable element type.
    pub precision: Vec<crate::precision::Precision>,
    /// Instruction count of the CONST section.
    pub n_const: u32,
    /// Instruction count of the SEGMENT section.
    pub n_segment: u32,
    /// How many leading CONTINUOUS instructions a call whose exports are
    /// off runs: the ones a derivative or a fault depends on. The rest
    /// compute observeds only the observed and output passes read
    /// (`prune`).
    pub n_rhs: u32,
    pub slots: Vec<SlotDesc>,
    pub plans: Vec<GatherPlan>,
    pub regions: Vec<RegionSpec>,
    /// `makearray` assemblies (`Instr::Assemble` indexes here).
    pub assemblies: Vec<AssembleSpec>,
    /// Inline array-literal payloads (`Instr::ConstArray` indexes here).
    pub const_data: Vec<ConstArrayData>,
    /// §9.2 `interp.*` constant tables (`Instr::Interp` indexes here).
    pub interp_tables: Vec<InterpTable>,
    /// Geometry instructions' constant parts (`Instr::PolyArea` indexes here).
    pub geoms: Vec<GeomSpec>,
    /// Data-subscript gathers' constant parts (`Instr::IndexGather` indexes
    /// here).
    pub index_gathers: Vec<IndexGatherSpec>,
    /// Build-time gather positions (`Instr::TableGather` indexes here).
    pub gather_tables: Vec<GatherTable>,
    /// Compressed-row offsets (`Instr::SegReduce` indexes here).
    pub seg_tables: Vec<SegTable>,
    /// Fail-closed fault messages (`Instr::Fault` indexes here), each the
    /// text the per-cell oracle latches at the same point.
    pub faults: Vec<String>,
    /// Recurrence sweeps (`Instr::Sweep` indexes here).
    pub sweeps: Vec<SweepSpec>,
    /// Run-time-subscript reads (`Instr::ScalarRead` indexes here).
    pub scalar_reads: Vec<ScalarReadSpec>,
    pub state_vars: Vec<StateRef>,
    /// Observed names resolved through the runtime observed map
    /// (`Operand::Obs`/`SrcRef::Obs` index here).
    pub obs_reads: Vec<String>,
    /// Forcing-buffer entries the program loads (`Instr::LoadForcing`
    /// indexes here).
    pub forcings: Vec<ForcingRef>,
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
    /// Lane programs (`Instr::Lanes` indexes here).
    pub lanes: Vec<LaneSpec>,
    /// Fusion-pass diagnostics (all-zero when fusion is disabled).
    pub fuse_stats: FuseStats,
    /// Every box in the program is stored AXIS-REVERSED (see
    /// [`super::layout`]): slot and state shapes, plans, regions, axis
    /// fields and table positions all count axes from the last logical axis,
    /// so a row-major slot is the column-major array the state vector holds.
    /// A state block is then read in place and a whole-box `dy` write is one
    /// copy. The boundaries with logical arrays (forcing loads, exports)
    /// transpose. `false` is the program exactly as lowered.
    pub col_major: bool,
}

impl TapeProgram {
    /// The tables [`Instr::for_each_read`] and [`Instr::for_each_def`] read.
    pub(crate) fn tables(&self) -> SlotTables<'_> {
        SlotTables {
            dy_writes: &self.dy_writes,
            fused: &self.fused,
            assemblies: &self.assemblies,
            sweeps: &self.sweeps,
            scalar_reads: &self.scalar_reads,
            lanes: &self.lanes,
        }
    }

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
