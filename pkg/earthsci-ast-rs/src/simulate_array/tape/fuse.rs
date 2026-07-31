//! Step 4: kernel fusion on the tape.
//!
//! A build-time post-pass over the lowered (pre-coloring) [`TapeProgram`] that
//! merges DAG segments of same-box elementwise instructions
//! (`Bin`/`Un`/`Neg`/`Select`/`Fill`/`Copy`) into [`Instr::Fused`] groups: one
//! straight-line micro-program executed per element in a single pass over the
//! box, with only the group's live-out values materialized to the slab. A
//! [`Instr::Gather`] whose plan is a pure constant shift/wrap of an
//! equal-shape source (no fixed axes, no broadcast axes, no transposition) is
//! *folded into* its consumers as a shifted read: the group's precompiled run
//! schedule partitions the box into contiguous runs on which every folded
//! input is either one constant flat source offset or entirely the gather's
//! Dirichlet ghost (`+0.0`) — so the per-element value is byte-identical to
//! reading the materialized gather output.
//!
//! ## Bit identity by construction
//!
//! Per element, a fused group applies exactly the same scalar kernels in the
//! same order as the instructions it replaces; all fused ops are elementwise
//! maps (no reductions, scans, or cross-element reads other than the
//! precompiled constant-shift gathers, whose sources are always values
//! defined OUTSIDE the group), so element iteration order cannot change any
//! output bit. `Select` keeps evaluate-both semantics (both operands are
//! computed per element, then picked), exactly like the vectorized
//! `vec_select`.
//!
//! ## Soundness of the reordering
//!
//! The pass buffers group members while passing other instructions through,
//! so a group's single `Fused` instruction executes at the position of the
//! member that *forced* the flush. This is sound because:
//!
//! * slots are SSA (defined once; the phi double-definition only occurs
//!   inside `JmpIfZero` regions, which are hard barriers copied verbatim);
//! * any instruction that READS a slot defined by an open group flushes that
//!   group first, so no reader ever precedes the `Fused` that defines it;
//! * `Fallback` (which touches the runtime observed map) and `JmpIfZero`
//!   regions flush every open group, so side-effectful ordering is preserved;
//! * passed-through instructions keep their original relative order.
//!
//! Coloring runs AFTER fusion, so liveness (and the alias discipline — a
//! `Fused` is treated like a `Gather`: its outputs never recycle a source
//! buffer dying at the same instruction) is computed on the fused program,
//! and the internal values that no longer materialize shrink the slab.

use super::super::BinCode;
use super::ir::*;
use rustc_hash::{FxHashMap, FxHashSet};
use smallvec::SmallVec;
use std::collections::BTreeSet;

/// `ESS_TAPE_FUSE_DISABLE=1`: build the unfused program (bitwise-identical
/// results either way; this is the Step 4 kill switch).
pub(crate) fn fuse_disabled() -> bool {
    use std::sync::OnceLock;
    static OFF: OnceLock<bool> = OnceLock::new();
    *OFF.get_or_init(|| {
        std::env::var("ESS_TAPE_FUSE_DISABLE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false)
    })
}

/// Maximum simultaneously open groups (oldest is flushed beyond this).
const MAX_OPEN_GROUPS: usize = 4;

/// Row-major strides (elements) of `shape`.
fn rm_strides(shape: &[usize]) -> SmallVec<[i64; 4]> {
    let n = shape.len();
    let mut st = SmallVec::from_elem(0i64, n);
    let mut acc = 1i64;
    for d in (0..n).rev() {
        st[d] = acc;
        acc *= shape[d] as i64;
    }
    st
}

// ---------------------------------------------------------------------------
// Operand / source keys for deduplication.
// ---------------------------------------------------------------------------

#[derive(Hash, PartialEq, Eq, Clone, Copy)]
enum ScalKey {
    Lit(u64),
    Param(u16),
    Time,
    Slot(SlotId),
    State(u16),
}

/// Dedupe key for ALIGNED array inputs (observed operands are never fused,
/// so no `Obs` arm is needed).
#[derive(Hash, PartialEq, Eq, Clone, Copy)]
enum SrcKey {
    Slot(SlotId),
    State(u16),
}

// ---------------------------------------------------------------------------
// Group builder.
// ---------------------------------------------------------------------------

type AxisSegs = SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]>;

/// Geometry of one folded (shifted-read) gather input.
#[derive(Clone)]
enum ShiftedGeom {
    /// Piecewise per-axis segments (stride-1 within runs; ghost gaps).
    Segs(AxisSegs, super::super::DimU),
    /// Globally linear: `flat_src = a * flat_out + b` over the whole box
    /// (e.g. a level slice of a deeper box). Single run, element stride `a`.
    Linear { a: i64, b: i64 },
}

struct GBuilder {
    shape: super::super::DimU,
    /// Original instruction indices absorbed (in original order).
    member_instrs: Vec<u32>,
    members: FxHashSet<u32>,
    /// Group-defined slot -> value reference (Reg for computed members,
    /// In for folded gathers).
    val_of: FxHashMap<SlotId, MRef>,
    micro: Vec<MicroOp>,
    inputs: Vec<FusedInput>,
    /// Per SHIFTED input: its fold geometry.
    shifted_segs: Vec<ShiftedGeom>,
    aligned_ix: FxHashMap<SrcKey, u16>,
    scalars: Vec<Operand>,
    scalar_ix: FxHashMap<ScalKey, u16>,
    /// Computed member slots in definition order: `(slot, ssa register)`.
    defs: Vec<(SlotId, u16)>,
    /// Folded gathers: `(original instr index, out slot, input index)`.
    folded: Vec<(u32, SlotId, u16)>,
    /// Rule ordinal of the first member (provenance of the emitted Fused).
    prov: u32,
}

/// Operand resolved for group membership (pre-commit description).
enum ResOp {
    Existing(MRef),
    NewScalar(ScalKey, Operand),
    NewAligned(SrcKey, SrcRef),
}

impl GBuilder {
    fn new(shape: super::super::DimU, prov: u32) -> Self {
        GBuilder {
            shape,
            member_instrs: Vec::new(),
            members: FxHashSet::default(),
            val_of: FxHashMap::default(),
            micro: Vec::new(),
            inputs: Vec::new(),
            shifted_segs: Vec::new(),
            aligned_ix: FxHashMap::default(),
            scalars: Vec::new(),
            scalar_ix: FxHashMap::default(),
            defs: Vec::new(),
            folded: Vec::new(),
            prov,
        }
    }

    fn defines(&self, s: SlotId) -> bool {
        self.val_of.contains_key(&s)
    }

    /// Resolve an operand for use inside the group; `None` = unfusable
    /// operand (an observed read, whose rank is not statically known here, or
    /// a foreign-box array).
    fn resolve(&self, op: &Operand, prog: &TapeProgram) -> Option<ResOp> {
        match op {
            Operand::Lit(v) => Some(self.scal(ScalKey::Lit(v.to_bits()), *op)),
            Operand::Param(p) => Some(self.scal(ScalKey::Param(*p), *op)),
            Operand::Time => Some(self.scal(ScalKey::Time, *op)),
            Operand::Slot(s) => {
                if let Some(m) = self.val_of.get(s) {
                    return Some(ResOp::Existing(*m));
                }
                let d = &prog.slots[*s as usize];
                if d.scalar {
                    Some(self.scal(ScalKey::Slot(*s), *op))
                } else if d.shape == self.shape {
                    Some(self.aligned(SrcKey::Slot(*s), SrcRef::Slot(*s)))
                } else {
                    None
                }
            }
            Operand::State(ix) => {
                let sv = &prog.state_vars[*ix as usize];
                if sv.shape.is_empty() {
                    Some(self.scal(ScalKey::State(*ix), *op))
                } else if sv.shape == self.shape {
                    Some(self.aligned(SrcKey::State(*ix), SrcRef::State(*ix)))
                } else {
                    None
                }
            }
            // An observed operand's rank (0-d scalar vs array) is resolved at
            // run time by the unfused executor; keep such instructions
            // unfused rather than guess.
            Operand::Obs(_) => None,
        }
    }

    fn scal(&self, key: ScalKey, op: Operand) -> ResOp {
        match self.scalar_ix.get(&key) {
            Some(&i) => ResOp::Existing(MRef::Scal(i)),
            None => ResOp::NewScalar(key, op),
        }
    }

    fn aligned(&self, key: SrcKey, src: SrcRef) -> ResOp {
        match self.aligned_ix.get(&key) {
            Some(&i) => ResOp::Existing(MRef::In(i)),
            None => ResOp::NewAligned(key, src),
        }
    }

    fn commit(&mut self, r: ResOp) -> MRef {
        match r {
            ResOp::Existing(m) => m,
            ResOp::NewScalar(key, op) => {
                let i = self.scalars.len() as u16;
                self.scalars.push(op);
                self.scalar_ix.insert(key, i);
                MRef::Scal(i)
            }
            ResOp::NewAligned(key, src) => {
                let i = self.inputs.len() as u16;
                self.inputs.push(FusedInput {
                    src,
                    shifted_ix: None,
                    src_shape: self.shape.clone(),
                    elem_stride: 1,
                    load_reg: u16::MAX,
                });
                self.aligned_ix.insert(key, i);
                MRef::In(i)
            }
        }
    }

    /// Try to absorb an elementwise instruction whose out slot has this
    /// group's shape. Returns `false` (group untouched) if an operand is
    /// unfusable.
    fn try_add(&mut self, ix: u32, ins: &Instr, prog: &TapeProgram) -> bool {
        let (ops, out): (SmallVec<[&Operand; 3]>, SlotId) = match ins {
            Instr::Bin { a, b, out, .. } => (SmallVec::from_slice(&[a, b]), *out),
            Instr::Un { a, out, .. } | Instr::Neg { a, out } => {
                (SmallVec::from_slice(&[a]), *out)
            }
            Instr::Select { cond, a, b, out } => (SmallVec::from_slice(&[cond, a, b]), *out),
            Instr::Fill { v, out } => (SmallVec::from_slice(&[v]), *out),
            Instr::Copy { a, out } => (SmallVec::from_slice(&[a]), *out),
            _ => return false,
        };
        let mut resolved: SmallVec<[ResOp; 3]> = SmallVec::new();
        for op in &ops {
            match self.resolve(op, prog) {
                Some(r) => resolved.push(r),
                None => return false,
            }
        }
        let mut mrefs: SmallVec<[MRef; 3]> = SmallVec::new();
        for r in resolved {
            mrefs.push(self.commit(r));
        }
        let ssa = self.micro.len() as u16;
        let mop = match ins {
            Instr::Bin { op, .. } => MicroOp::Bin {
                op: *op,
                a: mrefs[0],
                b: mrefs[1],
                out: ssa,
            },
            Instr::Un { op, .. } => MicroOp::Un {
                op: *op,
                a: mrefs[0],
                out: ssa,
            },
            Instr::Neg { .. } => MicroOp::Neg {
                a: mrefs[0],
                out: ssa,
            },
            Instr::Select { .. } => MicroOp::Select {
                cond: mrefs[0],
                a: mrefs[1],
                b: mrefs[2],
                out: ssa,
            },
            Instr::Fill { .. } | Instr::Copy { .. } => MicroOp::Mov {
                a: mrefs[0],
                out: ssa,
            },
            _ => unreachable!(),
        };
        self.micro.push(mop);
        self.val_of.insert(out, MRef::Reg(ssa));
        self.defs.push((out, ssa));
        self.members.insert(ix);
        self.member_instrs.push(ix);
        true
    }

    /// Absorb a foldable gather as a shifted input.
    fn add_folded_gather(
        &mut self,
        ix: u32,
        src: SrcRef,
        plan: &GatherPlan,
        geom: ShiftedGeom,
        out: SlotId,
    ) {
        let input_ix = self.inputs.len() as u16;
        let shifted_ix = self.shifted_segs.len() as u16;
        let elem_stride = match &geom {
            ShiftedGeom::Segs(..) => 1,
            ShiftedGeom::Linear { a, .. } => *a,
        };
        self.inputs.push(FusedInput {
            src,
            shifted_ix: Some(shifted_ix),
            src_shape: plan.src_shape.clone(),
            elem_stride,
            load_reg: u16::MAX,
        });
        self.shifted_segs.push(geom);
        self.val_of.insert(out, MRef::In(input_ix));
        self.folded.push((ix, out, input_ix));
        self.members.insert(ix);
        self.member_instrs.push(ix);
    }
}

/// A gather plan is foldable as a shifted read when it is a pure constant
/// per-axis shift/wrap of a same-rank source: no fixed axes, no broadcast
/// axes, no axis permutation (the source box may differ — an interior-subset
/// stencil read). Its per-axis copy segments then give, for every covered
/// run, a constant flat source offset (the source's last axis advances with
/// stride 1, exactly like the output's), and every uncovered position reads
/// the ghost `+0.0` — byte-identical to the materialized gather.
fn foldable_plan(plan: &GatherPlan) -> bool {
    plan.fixed_desc.is_empty()
        && plan.mapped.iter().all(|&m| m)
        && plan.perm.iter().enumerate().all(|(i, &p)| p == i)
        && plan.src_shape.len() == plan.shape.len()
        && !plan.shape.is_empty()
        && !plan.shape.contains(&0)
}

/// Cap on the fold's run-schedule shattering: a fold must keep runs coarse
/// (a shift along the innermost axis of a deep box would shatter the box
/// into per-row runs and eat the chunked executor's dispatch amortization —
/// such gathers stay materialized).
fn fold_runs_acceptable(shape: &[usize], geom: &ShiftedGeom) -> bool {
    let n_elems: usize = shape.iter().product::<usize>().max(1);
    let runs = build_runs(shape, std::slice::from_ref(geom));
    runs.len() <= 8 || n_elems / runs.len() >= 64
}

/// Detect the globally-linear fold: `flat_src = a * flat_out + b` over the
/// whole box. Covers full-cover constant shifts with a common stride ratio,
/// fixed source axes (which contribute to `b`), and broadcast output axes of
/// extent 1 (which contribute nothing) — the classic instance is a level
/// slice `index(u, i, j, K)` materialized on an `[nx, ny, 1]` box from an
/// `[nx, ny, nz]` source (`a = nz`, `b = K`).
fn linear_fold(plan: &GatherPlan) -> Option<ShiftedGeom> {
    if plan.shape.is_empty() || plan.shape.contains(&0) || plan.src_shape.len() > 16 {
        return None;
    }
    let nd_out = plan.shape.len();
    let sstr = rm_strides(&plan.src_shape);
    let ostr = rm_strides(&plan.shape);
    let mut b = 0i64;
    let mut fixed_mask = [false; 16];
    for &(d, i0) in &plan.fixed_desc {
        fixed_mask[d] = true;
        b += sstr[d] * i0 as i64;
    }
    // Non-fixed source strides in ascending axis order, permuted into output
    // order exactly as `exec_gather` does.
    let reduced: Vec<i64> = (0..plan.src_shape.len())
        .filter(|d| !fixed_mask[*d])
        .map(|d| sstr[d])
        .collect();
    let mut mpos = 0usize;
    let mut ratio: Option<i64> = None;
    for a in 0..nd_out {
        if plan.mapped[a] {
            let eff = reduced[plan.perm[mpos]];
            mpos += 1;
            let segs = &plan.segs[a];
            if segs.len() != 1 {
                return None;
            }
            let (o, l, so) = segs[0];
            if o != 0 || l != plan.shape[a] {
                return None;
            }
            b += so as i64 * eff;
            if plan.shape[a] > 1 {
                if ostr[a] == 0 || eff % ostr[a] != 0 {
                    return None;
                }
                let r = eff / ostr[a];
                match ratio {
                    None => ratio = Some(r),
                    Some(p) if p == r => {}
                    _ => return None,
                }
            }
        } else if plan.shape[a] != 1 {
            // A broadcast axis of extent > 1 repeats source elements — not
            // expressible as a constant element stride.
            return None;
        }
    }
    Some(ShiftedGeom::Linear {
        a: ratio.unwrap_or(1),
        b,
    })
}

// ---------------------------------------------------------------------------
// Run-schedule construction.
// ---------------------------------------------------------------------------

/// Build the contiguous-run schedule for a group box `shape` with the given
/// shifted-input geometries. Runs are emitted ascending in `out_off` and
/// maximally coalesced. Within a run every shifted input advances by its
/// constant element stride through its own row-major source, so a run stores
/// one flat source offset (or ghost) per shifted input.
fn build_runs(shape: &[usize], shifted: &[ShiftedGeom]) -> Vec<FusedRun> {
    let n_elems: usize = shape.iter().product::<usize>().max(1);
    if shifted.is_empty() {
        return vec![FusedRun {
            out_off: 0,
            len: n_elems as u32,
            in_off: SmallVec::new(),
        }];
    }
    let nd = shape.len();
    let strides = rm_strides(shape);
    let n_shift = shifted.len();
    // Per-input element stride (coalescing contiguity is offset + len*stride).
    let elem_stride: SmallVec<[i64; 2]> = shifted
        .iter()
        .map(|g| match g {
            ShiftedGeom::Segs(..) => 1,
            ShiftedGeom::Linear { a, .. } => *a,
        })
        .collect();
    let seg_strides: SmallVec<[Option<SmallVec<[i64; 4]>>; 2]> = shifted
        .iter()
        .map(|g| match g {
            ShiftedGeom::Segs(_, ss) => Some(rm_strides(ss)),
            ShiftedGeom::Linear { .. } => None,
        })
        .collect();
    // Per axis: merged interval list
    // [(start, len, per-input Option<source start position on this axis>)]
    // (`None` for Linear inputs, which impose no cuts).
    #[allow(clippy::type_complexity)]
    let mut axis_ivals: Vec<Vec<(usize, usize, SmallVec<[Option<i64>; 2]>)>> =
        Vec::with_capacity(nd);
    for d in 0..nd {
        let mut cuts: BTreeSet<usize> = BTreeSet::new();
        cuts.insert(0);
        cuts.insert(shape[d]);
        for g in shifted {
            if let ShiftedGeom::Segs(segs, _) = g {
                for &(o, l, _) in &segs[d] {
                    cuts.insert(o);
                    cuts.insert(o + l);
                }
            }
        }
        let cuts: Vec<usize> = cuts.into_iter().collect();
        let mut ivals = Vec::with_capacity(cuts.len() - 1);
        for w in cuts.windows(2) {
            let (a, b) = (w[0], w[1]);
            let mut src_start: SmallVec<[Option<i64>; 2]> = SmallVec::new();
            for g in shifted {
                let mut pos = None;
                if let ShiftedGeom::Segs(segs, _) = g {
                    for &(o, l, so) in &segs[d] {
                        if a >= o && b <= o + l {
                            pos = Some(so as i64 + (a as i64 - o as i64));
                            break;
                        }
                    }
                }
                src_start.push(pos);
            }
            ivals.push((a, b - a, src_start));
        }
        axis_ivals.push(ivals);
    }

    // Cartesian product over per-axis intervals (tiles); each tile emits its
    // rows (inner-axis contiguous pieces) as runs.
    let mut runs: Vec<FusedRun> = Vec::new();
    let mut pick: SmallVec<[usize; 4]> = SmallVec::from_elem(0usize, nd);
    loop {
        // Per Segs-input per-axis source base of this tile (ghost if any axis
        // is uncovered).
        let mut ghost: SmallVec<[bool; 2]> = SmallVec::from_elem(false, n_shift);
        let mut src_base: SmallVec<[i64; 2]> = SmallVec::from_elem(0i64, n_shift);
        for d in 0..nd {
            let (_, _, ref starts) = axis_ivals[d][pick[d]];
            for j in 0..n_shift {
                if let Some(sstr) = &seg_strides[j] {
                    match starts[j] {
                        Some(p) => src_base[j] += p * sstr[d],
                        None => ghost[j] = true,
                    }
                }
            }
        }
        // Iterate the tile's rows: odometer over axes 0..nd-1 inside the
        // tile, inner axis (nd-1) is one contiguous piece per row.
        let inner = &axis_ivals[nd - 1][pick[nd - 1]];
        let (inner_start, inner_len) = (inner.0, inner.1);
        let mut row: SmallVec<[usize; 4]> = SmallVec::from_elem(0usize, nd.saturating_sub(1));
        loop {
            let mut off = inner_start as i64 * strides[nd - 1];
            for d in 0..nd - 1 {
                let (st, _, _) = axis_ivals[d][pick[d]];
                off += (st + row[d]) as i64 * strides[d];
            }
            let in_off: SmallVec<[i64; 2]> = (0..n_shift)
                .map(|j| match &shifted[j] {
                    ShiftedGeom::Linear { a, b } => a * off + b,
                    ShiftedGeom::Segs(..) => {
                        if ghost[j] {
                            GHOST_OFF
                        } else {
                            let sstr = seg_strides[j].as_ref().expect("segs have strides");
                            let mut so = src_base[j];
                            for d in 0..nd - 1 {
                                so += row[d] as i64 * sstr[d];
                            }
                            so
                        }
                    }
                })
                .collect();
            runs.push(FusedRun {
                out_off: off as u32,
                len: inner_len as u32,
                in_off,
            });
            // advance row odometer (innermost leading axis fastest)
            let mut d = nd - 1;
            let mut done = true;
            while d > 0 {
                d -= 1;
                row[d] += 1;
                if row[d] < axis_ivals[d][pick[d]].1 {
                    done = false;
                    break;
                }
                row[d] = 0;
            }
            if nd == 1 || done {
                break;
            }
        }
        // advance tile odometer
        let mut d = nd;
        let mut done = true;
        while d > 0 {
            d -= 1;
            pick[d] += 1;
            if pick[d] < axis_ivals[d].len() {
                done = false;
                break;
            }
            pick[d] = 0;
        }
        if done {
            break;
        }
    }

    // Sort ascending and coalesce adjacent runs.
    runs.sort_by_key(|r| r.out_off);
    let mut out: Vec<FusedRun> = Vec::with_capacity(runs.len());
    for r in runs {
        if let Some(last) = out.last_mut() {
            let contiguous = last.out_off + last.len == r.out_off
                && last
                    .in_off
                    .iter()
                    .zip(r.in_off.iter())
                    .enumerate()
                    .all(|(j, (&a, &b))| {
                        (a == GHOST_OFF && b == GHOST_OFF)
                            || (a != GHOST_OFF
                                && b != GHOST_OFF
                                && a + last.len as i64 * elem_stride[j] == b)
                    });
            if contiguous {
                last.len += r.len;
                continue;
            }
        }
        out.push(r);
    }
    debug_assert_eq!(
        out.iter().map(|r| r.len as usize).sum::<usize>(),
        n_elems,
        "run schedule must tile the box"
    );
    out
}

// ---------------------------------------------------------------------------
// Superop peephole.
// ---------------------------------------------------------------------------

fn bin2_arith(op: BinCode) -> bool {
    matches!(
        op,
        BinCode::Add | BinCode::Sub | BinCode::Mul | BinCode::Div
    )
}

/// Which superops the peephole may form. All settings are bit-identical (a
/// superop applies the identical scalar kernels in the identical order); the
/// knobs exist because the WIN is configuration-dependent, and were set by
/// measurement on simpleclimate.esm (36×19×10, medians of ≥7 interleaved,
/// AVX-512 clones active).
#[derive(Clone, Copy, Debug)]
pub(crate) struct SuperopCfg {
    /// Merge `+ - * /` three-op chains into [`MicroOp::Bin3`]. Default OFF:
    /// measured at ~+0.2 ms/RHS — the chunked executor is bound by the
    /// per-op loads/stores through the (L2-resident) register file, not by
    /// dispatch, and Bin3's all-pointer form adds a fourth input stream plus
    /// splat-register traffic that outweighs the two intermediate
    /// round-trips it saves. Opt-in via `ESS_TAPE_BIN3=1`.
    pub bin3: bool,
    /// Extend Bin2 beyond the `+ - * /` square to the mask/clamp pairs of
    /// [`bin2_pair_ok`]. Default ON: −0.2 ms/RHS generic, neutral under the
    /// SIMD clones, and 8% fewer element-ops. `ESS_TAPE_EXTPAIR_DISABLE=1`
    /// reverts.
    pub ext_pairs: bool,
}

impl SuperopCfg {
    /// The production configuration (env-overridable, read once).
    pub(crate) fn from_env() -> Self {
        use std::sync::OnceLock;
        static CFG: OnceLock<SuperopCfg> = OnceLock::new();
        let truthy = |k: &str| {
            std::env::var(k)
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false)
        };
        *CFG.get_or_init(|| SuperopCfg {
            bin3: truthy("ESS_TAPE_BIN3"),
            ext_pairs: !truthy("ESS_TAPE_EXTPAIR_DISABLE"),
        })
    }
}

/// The (op1, op2) pairs the executor monomorphizes as [`MicroOp::Bin2`]: the
/// full `+ - * /` square, plus the pairs the simpleclimate adjacency
/// histogram showed material (a multiply feeding a comparison mask; the
/// min/max clamp and limiter idioms). MUST stay in sync with the executor's
/// `Bin2` match arms — an unlisted pair is simply never merged.
fn bin2_pair_ok(op1: BinCode, op2: BinCode, ext_pairs: bool) -> bool {
    use BinCode::{Ge, Gt, Le, Lt, Max, Min, Mul};
    (bin2_arith(op1) && bin2_arith(op2))
        || ext_pairs && matches!(
            (op1, op2),
            (Mul, Gt)
                | (Mul, Ge)
                | (Mul, Lt)
                | (Mul, Le)
                | (Min, Max)
                | (Max, Min)
                | (Mul, Min)
                | (Min, Mul)
                | (Mul, Max)
                | (Max, Mul)
        )
}

/// Visit every operand of a micro-op.
fn for_each_operand(op: &MicroOp, mut f: impl FnMut(&MRef)) {
    match op {
        MicroOp::Bin { a, b, .. } => {
            f(a);
            f(b);
        }
        MicroOp::Un { a, .. } | MicroOp::Neg { a, .. } | MicroOp::Mov { a, .. } => f(a),
        MicroOp::Select { cond, a, b, .. } => {
            f(cond);
            f(a);
            f(b);
        }
        MicroOp::Bin2 { a, b, c, .. } => {
            f(a);
            f(b);
            f(c);
        }
        MicroOp::Bin3 { a, b, c, d, .. } => {
            f(a);
            f(b);
            f(c);
            f(d);
        }
    }
}

/// SSA register use counts (live-outs count as a use). Valid only while the
/// micro-program is in SSA form (op `i` defines register `i`).
fn ssa_uses(micro: &[MicroOp], outputs: &[(u16, SlotId)]) -> Vec<u32> {
    let mut uses = vec![0u32; micro.len()];
    for op in micro {
        for_each_operand(op, |m| {
            if let MRef::Reg(r) = m {
                uses[*r as usize] += 1;
            }
        });
    }
    for &(ssa, _) in outputs {
        uses[ssa as usize] += 1;
    }
    uses
}

/// `true` when `op` reads SSA register `r`.
fn reads_reg(op: &MicroOp, r: u16) -> bool {
    let mut hit = false;
    for_each_operand(op, |m| {
        if *m == MRef::Reg(r) {
            hit = true;
        }
    });
    hit
}

/// Short kind label for the step-4b composition/adjacency histograms.
fn mop_label(op: &MicroOp) -> String {
    match op {
        MicroOp::Bin { op, .. } => format!("Bin({op:?})"),
        MicroOp::Un { op, .. } => format!("Un({op:?})"),
        MicroOp::Neg { .. } => "Neg".to_string(),
        MicroOp::Select { .. } => "Select".to_string(),
        MicroOp::Mov { .. } => "Mov".to_string(),
        MicroOp::Bin2 { op1, op2, swap, .. } => {
            format!("Bin2({op1:?},{op2:?}{})", if *swap { ",swap" } else { "" })
        }
        MicroOp::Bin3 { op1, op2, op3, .. } => {
            format!("Bin3({op1:?},{op2:?},{op3:?})")
        }
    }
}

/// Merge adjacent `Bin` pairs whose intermediate has exactly one consumer
/// (the very next op) into [`MicroOp::Bin2`]: the intermediate then lives in
/// a CPU register instead of a chunk buffer — one store + one load + one
/// dispatch fewer per element, with the identical two kernels applied in the
/// identical order (bit-identity is untouched). Restricted to the
/// `+ - * /` kernels the executor monomorphizes.
fn merge_superops(micro: &mut Vec<MicroOp>, outputs: &mut [(u16, SlotId)], cfg: SuperopCfg) {
    let n_ssa = micro.len();
    // Use counts per SSA register (live-outs count as a use).
    let mut uses = vec![0u32; n_ssa];
    let count = |m: &MRef, uses: &mut Vec<u32>| {
        if let MRef::Reg(r) = m {
            uses[*r as usize] += 1;
        }
    };
    for op in micro.iter() {
        match op {
            MicroOp::Bin { a, b, .. } => {
                count(a, &mut uses);
                count(b, &mut uses);
            }
            MicroOp::Un { a, .. } | MicroOp::Neg { a, .. } | MicroOp::Mov { a, .. } => {
                count(a, &mut uses)
            }
            MicroOp::Select { cond, a, b, .. } => {
                count(cond, &mut uses);
                count(a, &mut uses);
                count(b, &mut uses);
            }
            MicroOp::Bin2 { .. } | MicroOp::Bin3 { .. } => unreachable!("peephole runs once"),
        }
    }
    for &(ssa, _) in outputs.iter() {
        uses[ssa as usize] += 1;
    }

    /// How the SSA register `t` is consumed by a `Bin` op: `Some((swap,
    /// other))` when exactly one operand is `t` (`swap` = `t` is the RIGHT
    /// operand), `None` when neither or both are `t`.
    fn consumes<'a>(ca: &'a MRef, cb: &'a MRef, t: u16) -> Option<(bool, &'a MRef)> {
        let t = MRef::Reg(t);
        if *ca == t && *cb != t {
            Some((false, cb))
        } else if *cb == t && *ca != t {
            Some((true, ca))
        } else {
            None
        }
    }

    let mut merged: Vec<MicroOp> = Vec::with_capacity(micro.len());
    // old SSA id -> new SSA id (None = merged away, never referenced again).
    let mut new_of: Vec<Option<u16>> = vec![None; n_ssa];
    let remap = |m: &MRef, new_of: &[Option<u16>]| -> MRef {
        match m {
            MRef::Reg(r) => MRef::Reg(new_of[*r as usize].expect("operand defined")),
            other => *other,
        }
    };
    let mut i = 0usize;
    while i < micro.len() {
        // Try to merge micro[i..i+3] into a Bin3 (a `+ - * /` three-op chain
        // whose two intermediates are each single-use, consumed by the next
        // op), then micro[i..i+2] into a Bin2.
        if i + 2 < micro.len() && cfg.bin3 {
            if let (
                MicroOp::Bin {
                    op: op1,
                    a,
                    b,
                    out: t1,
                },
                MicroOp::Bin {
                    op: op2,
                    a: ca,
                    b: cb,
                    out: t2,
                },
                MicroOp::Bin {
                    op: op3,
                    a: da,
                    b: db,
                    ..
                },
            ) = (&micro[i], &micro[i + 1], &micro[i + 2])
            {
                if let (Some((swap2, other2)), Some((swap3, other3))) =
                    (consumes(ca, cb, *t1), consumes(da, db, *t2))
                {
                    if uses[*t1 as usize] == 1
                        && uses[*t2 as usize] == 1
                        && bin2_arith(*op1)
                        && bin2_arith(*op2)
                        && bin2_arith(*op3)
                        && *other3 != MRef::Reg(*t1)
                    {
                        let new_id = merged.len() as u16;
                        let mop = MicroOp::Bin3 {
                            op1: *op1,
                            a: remap(a, &new_of),
                            b: remap(b, &new_of),
                            op2: *op2,
                            c: remap(other2, &new_of),
                            swap2,
                            op3: *op3,
                            d: remap(other3, &new_of),
                            swap3,
                            out: new_id,
                        };
                        merged.push(mop);
                        new_of[i + 2] = Some(new_id); // final consumer's value
                        i += 3;
                        continue;
                    }
                }
            }
        }
        // Try to merge micro[i] (producer) into micro[i+1] (consumer).
        if i + 1 < micro.len() {
            if let (
                MicroOp::Bin {
                    op: op1,
                    a,
                    b,
                    out: t,
                },
                MicroOp::Bin {
                    op: op2,
                    a: ca,
                    b: cb,
                    ..
                },
            ) = (&micro[i], &micro[i + 1])
            {
                if let Some((swap, other)) = consumes(ca, cb, *t) {
                    if uses[*t as usize] == 1 && bin2_pair_ok(*op1, *op2, cfg.ext_pairs) {
                        let new_id = merged.len() as u16;
                        let mop = MicroOp::Bin2 {
                            op1: *op1,
                            a: remap(a, &new_of),
                            b: remap(b, &new_of),
                            op2: *op2,
                            c: remap(other, &new_of),
                            swap,
                            out: new_id,
                        };
                        merged.push(mop);
                        new_of[i + 1] = Some(new_id); // consumer's value
                        i += 2;
                        continue;
                    }
                }
            }
        }
        let new_id = merged.len() as u16;
        let mut op = micro[i].clone();
        match &mut op {
            MicroOp::Bin { a, b, out, .. } => {
                *a = remap(a, &new_of);
                *b = remap(b, &new_of);
                *out = new_id;
            }
            MicroOp::Un { a, out, .. } | MicroOp::Neg { a, out } | MicroOp::Mov { a, out } => {
                *a = remap(a, &new_of);
                *out = new_id;
            }
            MicroOp::Select { cond, a, b, out } => {
                *cond = remap(cond, &new_of);
                *a = remap(a, &new_of);
                *b = remap(b, &new_of);
                *out = new_id;
            }
            MicroOp::Bin2 { .. } | MicroOp::Bin3 { .. } => unreachable!(),
        }
        merged.push(op);
        new_of[i] = Some(new_id);
        i += 1;
    }
    for (ssa, _) in outputs.iter_mut() {
        *ssa = new_of[*ssa as usize].expect("live-out survives merging");
    }
    *micro = merged;
}

// ---------------------------------------------------------------------------
// Register allocation.
// ---------------------------------------------------------------------------

/// Remap SSA micro registers onto a small recycled physical register file.
/// An op's `out` register is allocated BEFORE its dying operands are freed,
/// so `out` never aliases an operand register (which lets the executor's
/// chunk loops use disjoint slices).
fn allocate_registers(micro: &mut [MicroOp], outputs: &mut [(u16, SlotId)]) -> u16 {
    let n_ssa = micro.len();
    let mut last_use = vec![usize::MAX; n_ssa]; // MAX = never used
    let use_at = |m: &MRef, i: usize, last_use: &mut Vec<usize>| {
        if let MRef::Reg(r) = m {
            let lu = &mut last_use[*r as usize];
            *lu = if *lu == usize::MAX { i } else { (*lu).max(i) };
        }
    };
    for (i, op) in micro.iter().enumerate() {
        for_each_operand(op, |m| use_at(m, i, &mut last_use));
    }
    // Live-outs are used "after the end".
    for &(ssa, _) in outputs.iter() {
        last_use[ssa as usize] = usize::MAX.wrapping_sub(1).max(n_ssa); // sentinel: beyond program
    }
    // Correction: distinguish "never used, not output" (dead) from live-out.
    // Recompute: dead = last_use == usize::MAX and not an output.
    let is_output: Vec<bool> = {
        let mut v = vec![false; n_ssa];
        for &(ssa, _) in outputs.iter() {
            v[ssa as usize] = true;
        }
        v
    };

    let mut phys_of = vec![u16::MAX; n_ssa];
    let mut free: Vec<u16> = Vec::new();
    let mut n_phys: u16 = 0;
    for i in 0..n_ssa {
        // Allocate out.
        let p = free.pop().unwrap_or_else(|| {
            n_phys += 1;
            n_phys - 1
        });
        phys_of[i] = p;
        // Free operands dying at i (after allocation, so out != operand).
        let free_if_dies = |m: &MRef, free: &mut Vec<u16>| {
            if let MRef::Reg(r) = m {
                let r = *r as usize;
                if last_use[r] == i && !is_output[r] {
                    free.push(phys_of[r]);
                }
            }
        };
        let mut seen: SmallVec<[MRef; 4]> = SmallVec::new();
        for_each_operand(&micro[i], |m| {
            if !seen.contains(m) {
                seen.push(*m);
            }
        });
        for m in &seen {
            free_if_dies(m, &mut free);
        }
        // A dead value (never read, not an output) frees immediately.
        if last_use[i] == usize::MAX && !is_output[i] {
            free.push(p);
        }
    }

    // Remap.
    let remap = |m: &mut MRef| {
        if let MRef::Reg(r) = m {
            *m = MRef::Reg(phys_of[*r as usize]);
        }
    };
    for op in micro.iter_mut() {
        match op {
            MicroOp::Bin { a, b, out, .. } => {
                remap(a);
                remap(b);
                *out = phys_of[*out as usize];
            }
            MicroOp::Un { a, out, .. } | MicroOp::Neg { a, out } | MicroOp::Mov { a, out } => {
                remap(a);
                *out = phys_of[*out as usize];
            }
            MicroOp::Select { cond, a, b, out } => {
                remap(cond);
                remap(a);
                remap(b);
                *out = phys_of[*out as usize];
            }
            MicroOp::Bin2 { a, b, c, out, .. } => {
                remap(a);
                remap(b);
                remap(c);
                *out = phys_of[*out as usize];
            }
            MicroOp::Bin3 { a, b, c, d, out, .. } => {
                remap(a);
                remap(b);
                remap(c);
                remap(d);
                *out = phys_of[*out as usize];
            }
        }
    }
    for (ssa, _) in outputs.iter_mut() {
        *ssa = phys_of[*ssa as usize];
    }
    n_phys
}


// ---------------------------------------------------------------------------
// The pass.
// ---------------------------------------------------------------------------

pub(super) fn fuse_program(prog: &mut TapeProgram, cfg: SuperopCfg) {
    let n = prog.instrs.len();
    // Global reader index sets per slot.
    let mut readers: Vec<SmallVec<[u32; 4]>> = vec![SmallVec::new(); prog.slots.len()];
    for (i, ins) in prog.instrs.iter().enumerate() {
        ins.for_each_read(&prog.dy_writes, &prog.fused, |s| {
            readers[s as usize].push(i as u32)
        });
    }

    let mut sink = Sink {
        stats: FuseStats {
            instrs_before: n,
            ..Default::default()
        },
        fused: Vec::new(),
        instrs: Vec::with_capacity(n),
        prov: Vec::with_capacity(n),
        micro_hist: FxHashMap::default(),
        adj_hist: FxHashMap::default(),
        chain_hist: FxHashMap::default(),
    };

    let mut section_counts = [0usize; 3];
    for (sec, cad) in [Cadence::Const, Cadence::Segment, Cadence::Continuous]
        .into_iter()
        .enumerate()
    {
        let range = prog.section_range(cad);
        let start_len = sink.instrs.len();
        fuse_section(prog, range, &readers, &mut sink, cfg);
        section_counts[sec] = sink.instrs.len() - start_len;
    }

    sink.stats.instrs_after = sink.instrs.len();
    let desc = |m: FxHashMap<String, usize>| -> Vec<(String, usize)> {
        let mut v: Vec<_> = m.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        v
    };
    sink.stats.micro_hist = desc(sink.micro_hist);
    sink.stats.adj_hist = desc(sink.adj_hist);
    sink.stats.chain_hist = {
        let mut v: Vec<_> = sink.chain_hist.into_iter().collect();
        v.sort_by_key(|&(len, _)| len);
        v
    };
    prog.instrs = sink.instrs;
    prog.provenance = sink.prov;
    prog.n_const = section_counts[0] as u32;
    prog.n_segment = section_counts[1] as u32;
    prog.fused = sink.fused;
    prog.fuse_stats = sink.stats;
}

/// The rewritten program under construction.
struct Sink {
    stats: FuseStats,
    fused: Vec<FusedSpec>,
    instrs: Vec<Instr>,
    prov: Vec<u32>,
    /// Step 4b histogram accumulators (weighted by group element count).
    micro_hist: FxHashMap<String, usize>,
    adj_hist: FxHashMap<String, usize>,
    chain_hist: FxHashMap<usize, usize>,
}

impl Sink {
    fn passthrough(&mut self, prog: &TapeProgram, i: usize) {
        if matches!(prog.instrs[i], Instr::Gather { .. }) {
            self.stats.n_gathers_kept += 1;
        }
        self.instrs.push(prog.instrs[i].clone());
        self.prov.push(prog.provenance[i]);
    }
}

/// Finalize one group: emit either its `Fused` instruction (plus any
/// re-materialized gathers) or, for trivial groups, the original
/// instructions verbatim.
fn flush_one(
    g: GBuilder,
    prog: &TapeProgram,
    readers: &[SmallVec<[u32; 4]>],
    sink: &mut Sink,
    cfg: SuperopCfg,
) {
    let has_compute = g.micro.iter().any(|m| !matches!(m, MicroOp::Mov { .. }));
    if g.member_instrs.len() < 2 || g.micro.is_empty() || !has_compute {
        for &ix in &g.member_instrs {
            sink.passthrough(prog, ix as usize);
        }
        return;
    }
    let GBuilder {
        shape,
        member_instrs,
        members,
        mut micro,
        mut inputs,
        shifted_segs,
        scalars,
        defs,
        folded,
        prov,
        ..
    } = g;

    // Folded gathers whose value is ALSO read outside the group must stay
    // materialized: re-emit the Gather and rewire the input to an aligned
    // read of its output slot.
    let mut kept_shifted: Vec<bool> = vec![true; shifted_segs.len()];
    for &(orig_ix, slot, input_ix) in &folded {
        let external = readers[slot as usize].iter().any(|r| !members.contains(r));
        if external {
            sink.passthrough(prog, orig_ix as usize);
            let old = inputs[input_ix as usize].shifted_ix.expect("was shifted");
            kept_shifted[old as usize] = false;
            inputs[input_ix as usize] = FusedInput {
                src: SrcRef::Slot(slot),
                shifted_ix: None,
                src_shape: shape.clone(),
                elem_stride: 1,
                load_reg: u16::MAX,
            };
        } else {
            sink.stats.n_gathers_folded += 1;
        }
    }
    // Compact the shifted-input table.
    let mut new_segs: Vec<ShiftedGeom> = Vec::new();
    let mut new_ix: Vec<u16> = vec![u16::MAX; kept_shifted.len()];
    for (i, segs) in shifted_segs.into_iter().enumerate() {
        if kept_shifted[i] {
            new_ix[i] = new_segs.len() as u16;
            new_segs.push(segs);
        }
    }
    for inp in inputs.iter_mut() {
        if let Some(s) = inp.shifted_ix {
            inp.shifted_ix = Some(new_ix[s as usize]);
        }
    }

    // Live-outs.
    let mut outputs: SmallVec<[(u16, SlotId); 2]> = SmallVec::new();
    for &(slot, ssa) in &defs {
        let external = readers[slot as usize].iter().any(|r| !members.contains(r));
        if external {
            outputs.push((ssa, slot));
        }
    }

    // Step 4b histograms (pre-superop, while the program is SSA): single-use
    // producer→consumer adjacency and maximal arith chain lengths, weighted by
    // the group's element count (= per-RHS element-op cost).
    let n_elems: usize = shape.iter().product::<usize>().max(1);
    {
        let uses = ssa_uses(&micro, &outputs);
        for i in 0..micro.len().saturating_sub(1) {
            if uses[i] == 1 && reads_reg(&micro[i + 1], i as u16) {
                let key = format!("{}>{}", mop_label(&micro[i]), mop_label(&micro[i + 1]));
                *sink.adj_hist.entry(key).or_insert(0) += n_elems;
            }
        }
        let arith = |op: &MicroOp| matches!(op, MicroOp::Bin { op, .. } if bin2_arith(*op));
        let mut i = 0usize;
        while i < micro.len() {
            if arith(&micro[i]) {
                let mut len = 1usize;
                while i + len < micro.len()
                    && arith(&micro[i + len])
                    && uses[i + len - 1] == 1
                    && reads_reg(&micro[i + len], (i + len - 1) as u16)
                {
                    len += 1;
                }
                if len >= 2 {
                    *sink.chain_hist.entry(len).or_insert(0) += n_elems;
                }
                i += len;
            } else {
                i += 1;
            }
        }
    }

    merge_superops(&mut micro, &mut outputs, cfg);
    for op in &micro {
        *sink.micro_hist.entry(mop_label(op)).or_insert(0) += n_elems;
    }
    let n_regs = allocate_registers(&mut micro, &mut outputs);
    // Bin3 executes all-pointer: its scalar operands read from per-scalar
    // splat registers and ghost reads from a trailing zero register, all
    // appended after the load registers and filled once per call.
    let n_splat_regs = if micro.iter().any(|m| matches!(m, MicroOp::Bin3 { .. })) {
        scalars.len() as u16 + 1
    } else {
        0
    };
    let runs = build_runs(&shape, &new_segs);
    // Strided shifted inputs are pre-loaded into dedicated chunk registers
    // appended after the micro register file.
    let mut n_load_regs: u16 = 0;
    for inp in inputs.iter_mut() {
        if inp.shifted_ix.is_some() && inp.elem_stride != 1 {
            inp.load_reg = n_regs + n_load_regs;
            n_load_regs += 1;
        }
    }

    let n_members = member_instrs.len();
    sink.stats.n_groups += 1;
    sink.stats.n_member_instrs += n_members;
    let bucket = match n_members {
        0..=3 => 0,
        4..=7 => 1,
        8..=15 => 2,
        16..=31 => 3,
        32..=63 => 4,
        _ => 5,
    };
    sink.stats.group_size_hist[bucket] += 1;

    let spec_ix = sink.fused.len() as u32;
    sink.fused.push(FusedSpec {
        shape,
        inputs,
        scalars,
        micro,
        n_regs,
        n_load_regs,
        n_splat_regs,
        outputs,
        runs,
        n_fused_instrs: n_members as u32,
        n_folded_gathers: folded.len() as u32,
    });
    sink.instrs.push(Instr::Fused { spec: spec_ix });
    sink.prov.push(prov);
}

fn fuse_section(
    prog: &TapeProgram,
    range: std::ops::Range<usize>,
    readers: &[SmallVec<[u32; 4]>],
    sink: &mut Sink,
    cfg: SuperopCfg,
) {
    let mut open: Vec<GBuilder> = Vec::new();

    // Flush every open group that DEFINES one of the slots `ins` reads,
    // except (optionally) the group with shape `keep_shape` that `ins` is
    // about to join. Returns the surviving groups untouched.
    fn flush_hazards(
        ins: &Instr,
        keep_shape: Option<&super::super::DimU>,
        open: &mut Vec<GBuilder>,
        prog: &TapeProgram,
        readers: &[SmallVec<[u32; 4]>],
        sink: &mut Sink,
        cfg: SuperopCfg,
    ) {
        let mut hazard: Vec<usize> = Vec::new();
        ins.for_each_read(&prog.dy_writes, &prog.fused, |s| {
            for (gi, g) in open.iter().enumerate() {
                if keep_shape != Some(&g.shape) && g.defines(s) && !hazard.contains(&gi) {
                    hazard.push(gi);
                }
            }
        });
        hazard.sort_unstable();
        for &gi in hazard.iter().rev() {
            let g = open.remove(gi);
            flush_one(g, prog, readers, sink, cfg);
        }
    }

    /// Find the open group with `shape`, or open a new one (flushing the
    /// oldest beyond the cap).
    fn find_or_open(
        open: &mut Vec<GBuilder>,
        shape: super::super::DimU,
        prov: u32,
        prog: &TapeProgram,
        readers: &[SmallVec<[u32; 4]>],
        sink: &mut Sink,
        cfg: SuperopCfg,
    ) -> usize {
        if let Some(gi) = open.iter().position(|g| g.shape == shape) {
            return gi;
        }
        if open.len() >= MAX_OPEN_GROUPS {
            let g = open.remove(0);
            flush_one(g, prog, readers, sink, cfg);
        }
        open.push(GBuilder::new(shape, prov));
        open.len() - 1
    }

    let mut i = range.start;
    while i < range.end {
        let ins = &prog.instrs[i];

        // Hard barriers: conditional regions (copied verbatim — their skip
        // counts must stay exact and phi slots are double-defined inside) and
        // fallback rules (interpreter side effects).
        if let Instr::JmpIfZero {
            n_true, n_false, ..
        } = ins
        {
            for g in open.drain(..) {
                flush_one(g, prog, readers, sink, cfg);
            }
            let zone_end = (i + 1 + *n_true as usize + *n_false as usize).min(range.end);
            for j in i..zone_end {
                sink.passthrough(prog, j);
            }
            i = zone_end;
            continue;
        }
        if matches!(ins, Instr::Fallback { .. }) {
            for g in open.drain(..) {
                flush_one(g, prog, readers, sink, cfg);
            }
            sink.passthrough(prog, i);
            i += 1;
            continue;
        }

        // Foldable gather: absorb as a shifted input of its box's group.
        if let Instr::Gather { src, plan, out } = ins {
            let plan_ref = &prog.plans[*plan as usize];
            let out_desc = &prog.slots[*out as usize];
            let geom: Option<ShiftedGeom> = if out_desc.shape == plan_ref.shape {
                linear_fold(plan_ref).or_else(|| {
                    if !foldable_plan(plan_ref) {
                        return None;
                    }
                    let g = ShiftedGeom::Segs(
                        plan_ref.segs.clone(),
                        plan_ref.src_shape.clone(),
                    );
                    fold_runs_acceptable(&out_desc.shape, &g).then_some(g)
                })
            } else {
                None
            };
            if let Some(geom) = geom {
                // A gather whose SOURCE is defined by an open group forces
                // that group to materialize first.
                flush_hazards(ins, None, &mut open, prog, readers, sink, cfg);
                let shape = out_desc.shape.clone();
                let gi = find_or_open(&mut open, shape, prog.provenance[i], prog, readers, sink, cfg);
                open[gi].add_folded_gather(i as u32, *src, plan_ref, geom, *out);
                i += 1;
                continue;
            }
            // Unfoldable: pass through (with the usual read hazards).
            flush_hazards(ins, None, &mut open, prog, readers, sink, cfg);
            sink.passthrough(prog, i);
            i += 1;
            continue;
        }

        // Elementwise array-out instruction?
        let elem_shape: Option<super::super::DimU> = match ins {
            Instr::Bin { out, .. }
            | Instr::Un { out, .. }
            | Instr::Neg { out, .. }
            | Instr::Select { out, .. }
            | Instr::Fill { out, .. }
            | Instr::Copy { out, .. } => {
                let d = &prog.slots[*out as usize];
                if !d.scalar && !d.shape.is_empty() && !d.shape.contains(&0) {
                    Some(d.shape.clone())
                } else {
                    None
                }
            }
            _ => None,
        };
        if let Some(shape) = elem_shape {
            flush_hazards(ins, Some(&shape), &mut open, prog, readers, sink, cfg);
            let gi = find_or_open(
                &mut open,
                shape.clone(),
                prog.provenance[i],
                prog,
                readers,
                sink,
                cfg,
            );
            if open[gi].try_add(i as u32, ins, prog) {
                i += 1;
                continue;
            }
            // Unfusable operand (an observed read): the target group may
            // still hold slots this instruction reads — flush it too.
            flush_hazards(ins, None, &mut open, prog, readers, sink, cfg);
            sink.passthrough(prog, i);
            i += 1;
            continue;
        }

        // Everything else passes through, flushing any group it reads from.
        flush_hazards(ins, None, &mut open, prog, readers, sink, cfg);
        sink.passthrough(prog, i);
        i += 1;
    }
    for g in open.drain(..) {
        flush_one(g, prog, readers, sink, cfg);
    }
}
