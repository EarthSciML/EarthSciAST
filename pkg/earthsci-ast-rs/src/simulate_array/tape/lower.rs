//! Lowering: compile the post-CSE expression graph of a model's observed +
//! RHS rules into a flat [`TapeProgram`].
//!
//! The load-bearing principle: **compile the vectorized overlay's own
//! decision procedures, don't invent new semantics.** Every classification
//! this pass performs is the overlay's own `pub(super)` classifier
//! (`classify_axis_role`, `parse_wrap_axis_any`, `lhs_constant_shifts`,
//! `subblock_dest`, `vec_op_code`, …), and every construct `eval_vec_op`
//! would bail on becomes a *fallback rule* carrying the bail reason — so a
//! rule is taped essentially when the overlay vectorizes it today.
//!
//! *Essentially*, because there is exactly one deliberate exception, and it
//! is documented where it lives ([`TapeBuilder::lower_scalar_reduction`]): a
//! rank-0 `faq` — every index contracted, scalar result — which the overlay
//! declines outright (`eval_faq` gates its fast path on a non-empty output
//! box) and production therefore evaluates in the per-cell oracle. The tape
//! lowers it as a boxed body plus one [`Instr::Reduce`], whose ROW-MAJOR
//! visiting order IS the oracle's `CartesianTuples` odometer — so the
//! reference the lowering is pinned against there is the oracle rather than
//! the overlay, which is the same equivalence every other arm rests on, just
//! reached directly.
//!
//! ## Value numbering
//!
//! The runtime CSE overlay ([`super::super::cse`]) memoizes per `(scope,
//! structural class)`, with a fresh scope per output box (each faq entry,
//! each contraction tuple, each makearray region) — and hoists box-pure
//! subtrees into a persistent store keyed by `(box signature, class)`. The
//! build-time equivalent here:
//!
//! * scope-local numbering keyed by the interned node's `Arc` pointer
//!   (structural identity IS pointer identity for interned subtrees; the few
//!   address-unique nodes — `value`/`output`/`join` carriers, which the
//!   interner refuses — merely under-share, which recomputes the same value),
//!   consulted in the INNERMOST open scope only, mirroring the runtime memo's
//!   current-scope stamp;
//! * a cross-rule hoist map keyed by `(owned box key, node pointer)` for
//!   values whose operand cadence is ≤ SEGMENT — the structural analogue of
//!   the ess-lih persistent store (same box + same subtree + constant-tier
//!   leaves ⇒ same value for the whole solve/segment).
//!
//! Both reuse paths substitute a slot for a recomputation of the *identical*
//! value, so availability differences from the runtime memo (which is
//! dynamic) cannot change `dy`. Values defined inside a [`Instr::JmpIfZero`]
//! branch never escape it (the branch may not execute), enforced with an
//! insertion journal rolled back at branch exit.

use super::super::driver::{
    dependency_cone, expr_blocks_output_pruning, observed_rule_is_array_valued,
};
use super::super::*;
use super::ir::*;
use crate::precision::Precision;
use crate::simulate_array::eval::const_oob_message;
use crate::types::ExpressionNode;
use crate::value_invention::BoundaryKind;
use rustc_hash::FxHashMap;
use std::collections::HashSet;
use std::sync::Arc;

// ---------------------------------------------------------------------------
// Bail (fallback) plumbing.
// ---------------------------------------------------------------------------

/// Why a rule could not be lowered. Carries the DEEPEST bail site, mirroring
/// the overlay's `note_bail` convention (the first log entry is the actual
/// unsupported construct).
#[derive(Debug)]
pub(crate) struct Bail {
    pub reason: String,
}

macro_rules! bail_tape {
    ($($t:tt)*) => {
        return Err(Bail { reason: format!($($t)*) })
    };
}

/// The IR index of entry `n` of one of the program's operand tables (state
/// variables, observed reads, parameters). The IR stores these as `u32`; a
/// table that outgrows that refuses the rule by name rather than wrapping onto
/// another entry.
fn tape_index(n: usize, table: &str) -> LResult<u32> {
    u32::try_from(n).map_err(|_| Bail {
        reason: format!(
            "tape index overflow: the program has more than {} {table}",
            u32::MAX
        ),
    })
}

type LResult<T> = Result<T, Bail>;

mod tuples;

/// What a build knows about the forcing buffer: the box a read of each name
/// it can serve compiles against, and which of them a provider refreshes
/// between segments (see `ArrayCompiled::forcing_inputs`).
pub(super) struct ForcingInputs<'a> {
    pub shapes: FxHashMap<String, DimU>,
    /// Externally refreshed parameters with no box to compile against: the
    /// buffer does not hold them and their declared shape does not size.
    pub unsized_: HashSet<String>,
    pub discrete: &'a HashSet<String>,
}

/// Most contracted indices one contraction may carry.
const MAX_CONTRACT: usize = 4;

/// Highest rank a contraction is promoted to: the executor's per-axis tables
/// hold four axes inline, so a deeper box would allocate on every call.
const MAX_RANK: usize = 4;

/// Largest box a contraction is promoted to (`window × output` elements, one
/// term each): beyond it the contraction stays unrolled rather than
/// materialize its terms.
const MAX_PROMOTED_ELEMS: usize = 1 << 27;

/// A static contraction window: the contracted names and their inclusive
/// bounds, in `contract_names` order.
struct ContractWindow<'a> {
    names: &'a [String],
    lo: &'a [i64],
    hi: &'a [i64],
}

/// One run of output positions along an axis of a const-array gather, with
/// the read its boundary policy resolves it to ([`TapeBuilder::lower_const_gather`]).
#[derive(Clone, Debug)]
enum ConstRun {
    /// Copy segments `(out_off, len, src_off)`, relative to the run's start.
    Copy(SmallVec<[(usize, usize, usize); 2]>),
    /// One source position (a clamped edge, 0-based), read by every cell.
    Edge(usize),
    /// An output axis no source dim maps to (a broadcast axis).
    Bcast,
    /// Out of range with no policy: `NaN`, and a fault.
    Oob,
}

/// `index_into`'s resolution of the 1-based subscript `raw` into a dim of
/// extent `n` under `policy`: the 0-based position, or `None` for the fault.
fn resolve_const_index(policy: BoundaryKind, raw: i64, n: i64) -> Option<usize> {
    if (1..=n).contains(&raw) {
        return Some((raw - 1) as usize);
    }
    match policy {
        BoundaryKind::Periodic if n >= 1 => Some((raw - 1).rem_euclid(n) as usize),
        BoundaryKind::Clamp if n >= 1 => Some((raw.clamp(1, n) - 1) as usize),
        _ => None,
    }
}

/// The copy segments of a periodic wrap axis, which the tape lowers only as a
/// full-period roll: source and output both span exactly one period from the
/// same origin.
fn full_roll_segs(
    src_origin: i64,
    src_len: i64,
    out_lo: i64,
    out_len: usize,
    k: i64,
    period: i64,
) -> LResult<SmallVec<[(usize, usize, usize); 2]>> {
    if src_origin != out_lo || src_len != period || out_len as i64 != period {
        bail_tape!("index: periodic wrap axis is not a full-period roll");
    }
    let p = period as usize;
    let s = (((k % period) + period) % period) as usize;
    let mut segs = SmallVec::new();
    if s == 0 {
        segs.push((0usize, p, 0usize));
    } else {
        segs.push((0usize, p - s, s));
        segs.push((p - s, s, 0usize));
    }
    Ok(segs)
}

// ---------------------------------------------------------------------------
// Lowering-time values.
// ---------------------------------------------------------------------------

/// A lowering-time value: what the overlay's `VecValue` is at runtime, made
/// symbolic. Scalar kinds are `Lit`/`Param`/`Time`/`Scalar` (a scalar slot)
/// plus 0-d `StateView`/`ObsView`; array kinds carry a box (shape + origin).
#[derive(Clone, Debug)]
enum LV {
    Lit(f64),
    Param(u32),
    Time,
    /// A scalar slot.
    Scalar(SlotId),
    /// An array slot (box in the slot desc).
    Arr(SlotId),
    /// Whole persistent state array `state_vars[ix]` (origin all-1s; 0-d ⇒
    /// scalar semantics) — the zero-copy `VecValue::View` analogue.
    State(u32),
    /// Whole observed array resolved by name at run time (`obs_reads[ix]`),
    /// with its statically known shape (empty ⇒ 0-d scalar semantics).
    Obs {
        ix: u32,
        shape: DimU,
        tier: Cadence,
    },
}

/// The lowering-time output box (the `VecBox` analogue with owned lo/shape).
struct LBox<'a> {
    syms: &'a [String],
    lo: DimI,
    shape: DimU,
    cnames: &'a [String],
    cvals: SmallVec<[i64; 4]>,
    /// Nonzero for a TUPLE-LIST box (see `tuples`): the 1-D box of a
    /// contraction's admitted tuples, whose loop symbols are build-time
    /// columns in the builder's frame with this id rather than axes.
    tuple: u32,
    /// The box's axes in the order the per-cell oracle visits their cells,
    /// slowest first; empty means row-major (axis 0 slowest). Only the
    /// promoted contraction box differs: its contracted axes lead, but the
    /// oracle walks the output cells first and the contraction tuples within
    /// each. Consulted only to place a fail-closed fault ([`FaultKey`]).
    visit: SmallVec<[u8; 4]>,
}

impl<'a> LBox<'a> {
    /// Axis `k` of the visiting order (see [`LBox::visit`]).
    fn visit_axis(&self, k: usize) -> usize {
        if self.visit.is_empty() {
            k
        } else {
            self.visit[k] as usize
        }
    }

    fn as_vecbox(&self) -> VecBox<'_> {
        VecBox {
            syms: self.syms,
            lo: &self.lo,
            shape: &self.shape,
            cnames: self.cnames,
            cvals: &self.cvals,
        }
    }

    fn cbind(&self, name: &str) -> Option<i64> {
        self.cnames
            .iter()
            .position(|n| n == name)
            .map(|i| self.cvals[i])
    }
}

/// Owned hoist key: everything a box-pure value can read from its box — the
/// structural analogue of the runtime `box_sig` + binder-set check.
#[derive(Hash, PartialEq, Eq, Clone)]
struct BoxKey {
    syms: Vec<String>,
    lo: Vec<i64>,
    shape: Vec<usize>,
    cnames: Vec<String>,
    cvals: Vec<i64>,
    /// Two tuple-list boxes of one length are different boxes.
    tuple: u32,
}

impl BoxKey {
    fn of(bx: &LBox) -> BoxKey {
        BoxKey {
            syms: bx.syms.to_vec(),
            lo: bx.lo.to_vec(),
            shape: bx.shape.to_vec(),
            cnames: bx.cnames.to_vec(),
            cvals: bx.cvals.to_vec(),
            tuple: bx.tuple,
        }
    }
}

/// Scope-local value-numbering key.
#[derive(Hash, PartialEq, Eq, Clone, Copy)]
enum VnKey {
    /// Interned operator node address (`Arc::as_ptr`).
    Node(usize),
    /// Coordinate ramp along this output axis.
    Ramp(usize),
}

#[derive(Default)]
struct ScopeFrame {
    map: FxHashMap<VnKey, LV>,
    /// Insertions made while inside a conditional branch, for rollback.
    journal: Vec<(VnKey, Option<LV>)>,
}

/// What a (taped or fallback) observed rule left behind for later readers.
#[derive(Clone, Debug)]
enum ObsVal {
    /// Taped: the produced value, origin-normalized to all-1s.
    Taped(LV),
    /// Produced by a fallback rule (read through the runtime observed map).
    /// `shape` is the statically known array shape (`Some(empty)` = 0-d),
    /// `None` = statically unknown (readers must themselves fall back).
    External { shape: Option<DimU>, tier: Cadence },
}

/// Where, in the per-cell oracle's evaluation of one rule, a fail-closed
/// fault first fires: compared lexicographically, the smallest is the fault
/// the oracle latches first. It is the path of nested boxes down to the fault
/// site, each level contributing its first faulting cell in visiting order
/// (and the bound contraction tuple of an unrolled term), then a sequence
/// number in lowering order, which is the oracle's expression order within
/// one cell.
type FaultKey = SmallVec<[i64; 12]>;

// ---------------------------------------------------------------------------
// Builder.
// ---------------------------------------------------------------------------

/// An instruction and the precision its kernels run at: the one in force
/// while it was lowered (esm-spec §11.3.1).
type Tagged = (Instr, Precision);

struct Chunk {
    rule: u32,
    instrs: Vec<Tagged>,
}

pub(crate) struct TapeBuilder<'m> {
    var_shapes: &'m IndexMap<String, VarShape>,
    param_names: &'m [String],
    /// Per-name observed cadence tier (from the driver's classifiers).
    obs_tier: FxHashMap<String, Cadence>,
    /// The model's CONST-ARRAY registry (CONFORMANCE_SPEC §5.5.5). A gather on
    /// one of these may not compile to this module's ghost-0 fill: an
    /// out-of-range const-array index resolves by the factor's declared
    /// boundary policy, and with no declared policy it is
    /// `E_TREEWALK_CONSTARRAY_OOB`. Each out-of-range arm therefore BAILS to
    /// the per-cell oracle fallback when the base is one; an in-range gather
    /// compiles exactly as before.
    const_arrays: &'m ConstArrayScope,
    /// The DOCUMENT's working precision, read off the compiled model rather
    /// than off the thread-local (`crate::precision::is_f32`), which is not
    /// guaranteed to be standing while the tape is built. Only the §9.2
    /// closed-function lowering consults it: that lowering is exact integer
    /// arithmetic carried in `f64`, and the kernels it emits are resolved at
    /// EXECUTION, so under Float32 they would be binary32 kernels running on
    /// day counts and Julian day numbers that binary32 cannot hold.
    f32_document: bool,
    /// The shaped parameters whose declared default the compiler lowered into
    /// a `const` observed, as the dense row-major data that literal was
    /// written from ([`ArrayCompiled::inline_param_arrays`]), so the tape takes
    /// the numbers directly rather than reading the literal's JSON back.
    inline_params: Option<&'m HashMap<String, (Vec<usize>, Vec<f64>)>>,

    // Program under construction -------------------------------------------
    slots: Vec<SlotDesc>,
    plans: Vec<GatherPlan>,
    regions: Vec<RegionSpec>,
    assemblies: Vec<AssembleSpec>,
    /// Inline array-literal payloads, one per lowered array-valued `const`.
    const_data: Vec<ConstArrayData>,
    interp_tables: Vec<InterpTable>,
    geoms: Vec<GeomSpec>,
    index_gathers: Vec<IndexGatherSpec>,
    /// `(producer id, distinct-vertex count)` of every `intersect_polygon`
    /// ring evaluated at build ([`TapeBuilder::lower_intersect_polygon`]):
    /// the extent a `kind: "derived"` range over that ring has, which the
    /// interpreter reads off its runtime ring registry (`derived_extent`).
    rings: Vec<(String, i64)>,
    gather_tables: Vec<GatherTable>,
    seg_tables: Vec<SegTable>,
    /// Slots whose VALUES the build knows: array literals, and what the
    /// tuple-list lowering derives from them (`tuples`). Read only to resolve
    /// build-time data — a gather's subscripts, a join's key columns, a
    /// ragged bound — never to fold a value the program computes.
    known: FxHashMap<SlotId, Known>,
    /// Open tuple-list boxes, innermost last (`tuples`).
    tuple_frames: Vec<tuples::TupleFrame>,
    /// The id the next tuple-list box gets (0 means "not a tuple box").
    next_tuple: u32,
    /// Fail-closed fault messages (`Instr::Fault` indexes here).
    faults: Vec<String>,
    state_vars: Vec<StateRef>,
    /// Position in `state_vars`; narrowed to the IR's `u32` by [`tape_index`]
    /// where it is emitted.
    state_ix: FxHashMap<String, usize>,
    obs_reads: Vec<String>,
    obs_read_ix: FxHashMap<String, u32>,
    /// Every name the forcing buffer can serve, with the box a read of it
    /// compiles against ([`ForcingInputs`]).
    forcing_shapes: FxHashMap<String, DimU>,
    forcing_unsized: HashSet<String>,
    /// The forcing names a provider refreshes between segments; their loads
    /// go in the SEGMENT section, every other forcing load in CONST.
    discrete_forcing: &'m HashSet<String>,
    forcings: Vec<ForcingRef>,
    forcing_ix: FxHashMap<String, u32>,
    /// The slot an UNCONDITIONAL load of `forcings[i]` defined, so every later
    /// read shares it; `forcing_journal` records the insertions of the current
    /// rule for rollback.
    forcing_loaded: FxHashMap<u32, LV>,
    forcing_journal: Vec<u32>,
    dy_writes: Vec<DyWrite>,
    rules: Vec<RuleInfo>,
    /// Per-section chunk streams (index = Cadence as usize).
    streams: [Vec<Chunk>; 3],
    /// Home-stream chunk index per rule ordinal (for export insertion).
    rule_home_chunk: Vec<Option<usize>>,

    // Lowering state ---------------------------------------------------------
    cur_rule: u32,
    home: Cadence,
    scope_frames: Vec<ScopeFrame>,
    /// Nested conditional-branch buffers (top = innermost).
    branch_bufs: Vec<Vec<Tagged>>,
    hoist: FxHashMap<(BoxKey, VnKey), LV>,
    /// Hoist insertions of the CURRENT rule (rollback on bail).
    hoist_journal: Vec<(BoxKey, VnKey)>,
    /// Observed values defined so far, in rule order.
    obs_defined: FxHashMap<String, ObsVal>,
    /// The current rule's first fail-closed fault in the oracle's evaluation
    /// order, with its message: emitted as one [`Instr::Fault`] when the rule
    /// lowers ([`Self::flush_rule_fault`]).
    fault_first: Option<(FaultKey, String)>,
    /// Sequence number for the next fault site or nested box (lowering order).
    fault_seq: i64,
    /// The [`FaultKey`] prefix of the box being lowered: one entry per
    /// enclosing box the oracle evaluates whole at each cell of its parent.
    fault_prefix: FaultKey,
    /// Depth of positions the oracle evaluates for only SOME cells or tuples:
    /// the arms of an elementwise `ifelse`, a filtered term. A fault there
    /// may not fire where the tape would place it, so it is lowered only
    /// when an earlier certain fault makes it irrelevant.
    lazy_depth: u32,

    // Diagnostics ------------------------------------------------------------
    vn_scope_hits: usize,
    vn_hoist_hits: usize,
}

/// A slot's build-time value (see `TapeBuilder::known`).
#[derive(Clone, Debug)]
enum Known {
    /// The payload of the `ConstArray` that defines it.
    Data(u32),
    /// Values the build computed itself, row-major.
    Vals(std::rc::Rc<Vec<f64>>),
}

/// Snapshot for transactional per-rule lowering.
struct RuleTxn {
    slots: usize,
    plans: usize,
    regions: usize,
    assemblies: usize,
    const_data: usize,
    interp_tables: usize,
    geoms: usize,
    index_gathers: usize,
    rings: usize,
    gather_tables: usize,
    seg_tables: usize,
    faults: usize,
    dy_writes: usize,
    stream_lens: [usize; 3],
    hoist_journal: usize,
    forcing_journal: usize,
}

/// Snapshot for undoing a failed ATTEMPT inside one rule (a looped form that
/// bails and hands over to its unrolled equivalent), as opposed to
/// [`RuleTxn`], which undoes a whole rule. The attempt keeps its own
/// value-numbering scopes balanced, so only emitted state is recorded: the
/// tables, and how far each stream (or the open branch buffer) had grown.
struct SubTxn {
    slots: usize,
    plans: usize,
    regions: usize,
    assemblies: usize,
    const_data: usize,
    interp_tables: usize,
    geoms: usize,
    index_gathers: usize,
    gather_tables: usize,
    seg_tables: usize,
    /// Per stream: `(chunk count, instructions in the last chunk)`.
    streams: [(usize, usize); 3],
    branch_len: Option<usize>,
    hoist_journal: usize,
    forcing_journal: usize,
    fault_first: Option<(FaultKey, String)>,
    fault_seq: i64,
}

impl<'m> TapeBuilder<'m> {
    fn new(
        var_shapes: &'m IndexMap<String, VarShape>,
        param_names: &'m [String],
        obs_tier: FxHashMap<String, Cadence>,
        const_arrays: &'m ConstArrayScope,
        f32_document: bool,
        forcing: &ForcingInputs<'m>,
    ) -> Self {
        let mut state_vars = Vec::with_capacity(var_shapes.len());
        let mut state_ix = FxHashMap::default();
        for (name, vs) in var_shapes {
            state_ix.insert(name.clone(), state_vars.len());
            state_vars.push(StateRef {
                name: name.clone(),
                shape: vs.shape.iter().copied().collect(),
                origin: vs.origin.iter().copied().collect(),
                flat_offset: vs.flat_offset,
            });
        }
        TapeBuilder {
            var_shapes,
            param_names,
            obs_tier,
            const_arrays,
            f32_document,
            inline_params: None,
            slots: Vec::new(),
            plans: Vec::new(),
            regions: Vec::new(),
            assemblies: Vec::new(),
            const_data: Vec::new(),
            interp_tables: Vec::new(),
            geoms: Vec::new(),
            index_gathers: Vec::new(),
            rings: Vec::new(),
            gather_tables: Vec::new(),
            seg_tables: Vec::new(),
            known: FxHashMap::default(),
            tuple_frames: Vec::new(),
            next_tuple: 1,
            faults: Vec::new(),
            state_vars,
            state_ix,
            obs_reads: Vec::new(),
            obs_read_ix: FxHashMap::default(),
            forcing_shapes: forcing.shapes.clone(),
            forcing_unsized: forcing.unsized_.clone(),
            discrete_forcing: forcing.discrete,
            forcings: Vec::new(),
            forcing_ix: FxHashMap::default(),
            forcing_loaded: FxHashMap::default(),
            forcing_journal: Vec::new(),
            dy_writes: Vec::new(),
            rules: Vec::new(),
            streams: [Vec::new(), Vec::new(), Vec::new()],
            rule_home_chunk: Vec::new(),
            cur_rule: 0,
            home: Cadence::Continuous,
            scope_frames: Vec::new(),
            branch_bufs: Vec::new(),
            hoist: FxHashMap::default(),
            hoist_journal: Vec::new(),
            obs_defined: FxHashMap::default(),
            fault_first: None,
            fault_seq: 0,
            fault_prefix: FaultKey::new(),
            lazy_depth: 0,
            vn_scope_hits: 0,
            vn_hoist_hits: 0,
        }
    }

    // -- emission ------------------------------------------------------------

    fn in_branch(&self) -> bool {
        !self.branch_bufs.is_empty()
    }

    /// Section an instruction with operand cadence `want` lands in.
    fn placement(&self, want: Cadence) -> Cadence {
        if self.in_branch() {
            self.home
        } else {
            debug_assert!(
                want <= self.home,
                "instruction cadence {want:?} exceeds rule home {:?}",
                self.home
            );
            want.min(self.home)
        }
    }

    fn emit(&mut self, instr: Instr, section: Cadence) {
        self.emit_tagged(instr, crate::precision::active(), section);
    }

    /// [`Self::emit`] at a stated precision (a branch's buffered
    /// instructions keep the precision they were lowered at).
    fn emit_tagged(&mut self, instr: Instr, prec: Precision, section: Cadence) {
        match &instr {
            Instr::ConstArray { data, out } => {
                self.known.insert(*out, Known::Data(*data));
            }
            Instr::Copy {
                a: Operand::Slot(a),
                out,
            } if !self.slots[*out as usize].scalar => {
                if let Some(k) = self.known.get(a).cloned() {
                    self.known.insert(*out, k);
                }
            }
            _ => {}
        }
        if let Some(buf) = self.branch_bufs.last_mut() {
            buf.push((instr, prec));
            return;
        }
        let stream = &mut self.streams[section as usize];
        match stream.last_mut() {
            Some(c) if c.rule == self.cur_rule => c.instrs.push((instr, prec)),
            _ => stream.push(Chunk {
                rule: self.cur_rule,
                instrs: vec![(instr, prec)],
            }),
        }
    }

    fn new_slot(
        &mut self,
        shape: &[usize],
        origin: &[i64],
        scalar: bool,
        cadence: Cadence,
    ) -> SlotId {
        let id = self.slots.len() as SlotId;
        self.slots.push(SlotDesc {
            shape: shape.iter().copied().collect(),
            origin: origin.iter().copied().collect(),
            scalar,
            cadence,
            storage: u32::MAX,
        });
        id
    }

    // -- LV helpers -----------------------------------------------------------

    /// The array box of an LV, or `None` for a scalar kind.
    fn lv_box(&self, lv: &LV) -> Option<(DimU, DimI)> {
        match lv {
            LV::Lit(_) | LV::Param(_) | LV::Time | LV::Scalar(_) => None,
            LV::Arr(s) => {
                let d = &self.slots[*s as usize];
                Some((d.shape.clone(), d.origin.clone()))
            }
            LV::State(ix) => {
                let sv = &self.state_vars[*ix as usize];
                if sv.shape.is_empty() {
                    None
                } else {
                    Some((sv.shape.clone(), DimI::from_elem(1, sv.shape.len())))
                }
            }
            LV::Obs { shape, .. } => {
                if shape.is_empty() {
                    None
                } else {
                    Some((shape.clone(), DimI::from_elem(1, shape.len())))
                }
            }
        }
    }

    fn lv_cadence(&self, lv: &LV) -> Cadence {
        match lv {
            LV::Lit(_) | LV::Param(_) => Cadence::Const,
            LV::Time | LV::State(_) => Cadence::Continuous,
            LV::Scalar(s) | LV::Arr(s) => self.slots[*s as usize].cadence,
            LV::Obs { tier, .. } => *tier,
        }
    }

    fn op_of(&self, lv: &LV) -> Operand {
        match lv {
            LV::Lit(v) => Operand::Lit(*v),
            LV::Param(p) => Operand::Param(*p),
            LV::Time => Operand::Time,
            LV::Scalar(s) | LV::Arr(s) => Operand::Slot(*s),
            LV::State(ix) => Operand::State(*ix),
            LV::Obs { ix, .. } => Operand::Obs(*ix),
        }
    }

    fn src_of(&self, lv: &LV) -> SrcRef {
        match lv {
            LV::Arr(s) => SrcRef::Slot(*s),
            LV::State(ix) => SrcRef::State(*ix),
            LV::Obs { ix, .. } => SrcRef::Obs(*ix),
            _ => unreachable!("src_of called on a scalar LV"),
        }
    }

    fn obs_read(&mut self, name: &str) -> LResult<u32> {
        if let Some(&ix) = self.obs_read_ix.get(name) {
            return Ok(ix);
        }
        let ix = tape_index(self.obs_reads.len(), "observed reads")?;
        self.obs_reads.push(name.to_string());
        self.obs_read_ix.insert(name.to_string(), ix);
        Ok(ix)
    }

    /// A read of `name` served by the forcing buffer: `lookup_variable`'s last
    /// arm, reached only after `t`, the state, the observeds and the
    /// parameters, exactly as there. `None` when the buffer cannot serve the
    /// name.
    ///
    /// One [`Instr::LoadForcing`] per forcing, in the section its cadence
    /// allows, shared by every later read. A load made inside a conditional
    /// branch is not shared, since the branch may not run.
    fn forcing_read(&mut self, name: &str) -> LResult<Option<LV>> {
        let Some(shape) = self.forcing_shapes.get(name).cloned() else {
            if self.forcing_unsized.contains(name) {
                bail_tape!(
                    "forcing `{name}`: its declared shape names an index set the registry \
                     cannot size, and the forcing buffer held no entry for it when the tape \
                     was built, so there is no box to compile its read against"
                );
            }
            return Ok(None);
        };
        let ix = match self.forcing_ix.get(name) {
            Some(&ix) => ix,
            None => {
                let ix = tape_index(self.forcings.len(), "forcing reads")?;
                self.forcings.push(ForcingRef {
                    name: name.to_string(),
                    shape: shape.clone(),
                });
                self.forcing_ix.insert(name.to_string(), ix);
                ix
            }
        };
        if let Some(lv) = self.forcing_loaded.get(&ix) {
            return Ok(Some(lv.clone()));
        }
        let cadence = if self.discrete_forcing.contains(name) {
            Cadence::Segment
        } else {
            Cadence::Const
        };
        let sec = self.placement(cadence);
        let scalar = shape.is_empty();
        let out = self.new_slot(&shape, &DimI::from_elem(1, shape.len()), scalar, sec);
        self.emit(Instr::LoadForcing { forcing: ix, out }, sec);
        let lv = if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        };
        if !self.in_branch() {
            self.forcing_loaded.insert(ix, lv.clone());
            self.forcing_journal.push(ix);
        }
        Ok(Some(lv))
    }

    // -- scopes / VN ----------------------------------------------------------

    fn push_scope(&mut self) {
        self.scope_frames.push(ScopeFrame::default());
    }

    fn pop_scope(&mut self) {
        self.scope_frames.pop();
    }

    fn vn_get(&mut self, key: VnKey, bx: &LBox) -> Option<LV> {
        if let Some(frame) = self.scope_frames.last() {
            if let Some(lv) = frame.map.get(&key) {
                self.vn_scope_hits += 1;
                return Some(lv.clone());
            }
        }
        if let Some(lv) = self.hoist.get(&(BoxKey::of(bx), key)) {
            self.vn_hoist_hits += 1;
            return Some(lv.clone());
        }
        None
    }

    fn vn_put(&mut self, key: VnKey, lv: &LV, bx: &LBox) {
        let in_branch = self.in_branch();
        if let Some(frame) = self.scope_frames.last_mut() {
            let prev = frame.map.insert(key, lv.clone());
            if in_branch {
                frame.journal.push((key, prev));
            }
        }
        // The cross-rule hoist (ess-lih analogue): only for values whose
        // cadence is ≤ SEGMENT — pure functions of (box, structure, constant
        // tier) — and only when computed UNCONDITIONALLY.
        if !in_branch && self.lv_cadence(lv) <= Cadence::Segment {
            let hk = (BoxKey::of(bx), key);
            if self.hoist.insert(hk.clone(), lv.clone()).is_none() {
                self.hoist_journal.push(hk);
            }
        }
    }

    // -- conditional branches -------------------------------------------------

    fn push_branch(&mut self) -> usize {
        self.branch_bufs.push(Vec::new());
        self.scope_frames
            .last()
            .map(|f| f.journal.len())
            .unwrap_or(0)
    }

    /// Close the innermost branch: roll back VN insertions made inside it and
    /// return its instruction buffer.
    fn pop_branch(&mut self, journal_mark: usize) -> Vec<Tagged> {
        let buf = self.branch_bufs.pop().expect("branch buffer open");
        if let Some(frame) = self.scope_frames.last_mut() {
            while frame.journal.len() > journal_mark {
                let (key, prev) = frame.journal.pop().expect("journal entry");
                match prev {
                    Some(v) => {
                        frame.map.insert(key, v);
                    }
                    None => {
                        frame.map.remove(&key);
                    }
                }
            }
        }
        buf
    }

    // -- fail-closed faults -------------------------------------------------
    //
    // The per-cell oracle has no error channel: a fault (an out-of-range read
    // of a const array with no boundary policy, a subscript on a 0-D
    // parameter) latches a message, the read yields `NaN`, and the caller
    // drains the FIRST latched message. The tape reproduces both halves: the
    // `NaN` in ordinary instructions at the faulting positions, and one
    // `Instr::Fault` per rule carrying the message of the rule's first fault
    // in the oracle's order (see [`FaultKey`]).

    /// The [`FaultKey`] entries of `cell` of `bx`: the cell's absolute
    /// coordinates in visiting order, then the bound contraction tuple. A box
    /// with no symbols is evaluated once, not per cell, and adds nothing.
    fn fault_cell_key(bx: &LBox, cell: &[i64]) -> FaultKey {
        let mut key = FaultKey::new();
        if !bx.syms.is_empty() {
            for k in 0..bx.shape.len() {
                let a = bx.visit_axis(k);
                key.push(bx.lo[a] + cell[a]);
            }
        }
        key.extend(bx.cvals.iter().copied());
        key
    }

    /// Record a fault the oracle latches at `cell` (0-based) of `bx` — or,
    /// with `None`, at the point of a single evaluation — keeping the rule's
    /// first. A fault that may not fire (in a branch, or a lazily evaluated
    /// position) is admitted only when an earlier certain fault makes it
    /// unobservable.
    fn note_fault(&mut self, at: Option<(&LBox, &[i64])>, msg: String) -> LResult<()> {
        let mut key = self.fault_prefix.clone();
        if let Some((bx, cell)) = at {
            key.extend(Self::fault_cell_key(bx, cell));
        }
        key.push(self.fault_seq);
        self.fault_seq += 1;
        let preceded = self.fault_first.as_ref().is_some_and(|(k, _)| *k < key);
        if self.in_branch() || self.lazy_depth > 0 {
            if preceded {
                return Ok(());
            }
            let head: String = msg.chars().take_while(|c| *c != ':').collect();
            bail_tape!(
                "fault: `{head}` where the oracle evaluates only some cells (a conditional \
                 branch or a filtered term), with no earlier fault in the rule to settle \
                 which one it latches"
            );
        }
        if !preceded {
            self.fault_first = Some((key, msg));
        }
        Ok(())
    }

    /// Enter a box the oracle evaluates whole at each cell of `parent` (a
    /// nested aggregate; with `None`, an aggregate on the wholesale path):
    /// its faults sort at the parent's first cell, in expression order.
    /// Returns the prefix [`Self::leave_fault_level`] restores.
    fn enter_fault_level(&mut self, parent: Option<&LBox>) -> FaultKey {
        let saved = self.fault_prefix.clone();
        if let Some(p) = parent {
            let first: SmallVec<[i64; 4]> = SmallVec::from_elem(0, p.shape.len());
            let k = Self::fault_cell_key(p, &first);
            self.fault_prefix.extend(k);
        }
        self.fault_prefix.push(self.fault_seq);
        self.fault_seq += 1;
        saved
    }

    fn leave_fault_level(&mut self, saved: FaultKey) {
        self.fault_prefix = saved;
    }

    // -- expression lowering (the eval_vec mirror) ---------------------------

    fn lower_expr(&mut self, e: &Expr, bx: &LBox) -> LResult<LV> {
        match e {
            // Literals round on ingress, exactly as the oracle's `eval` arm
            // does (`crate::precision`) — a tape literal and an interpreted
            // literal must be the same number under Float32.
            Expr::Number(n) => Ok(LV::Lit(crate::precision::round(*n))),
            Expr::Integer(n) => Ok(LV::Lit(crate::precision::round(*n as f64))),
            Expr::Variable(name) => self.resolve_var(name, bx),
            Expr::Operator(node) => {
                let key = VnKey::Node(Arc::as_ptr(node) as usize);
                if let Some(hit) = self.vn_get(key, bx) {
                    return Ok(hit);
                }
                let lv = self.lower_op(node, bx)?;
                self.vn_put(key, &lv, bx);
                Ok(lv)
            }
        }
    }

    /// Mirror of `eval_vec_variable`, in ITS resolution order: `t`, bound
    /// contraction index, output box symbol (ramp), state, observed, param,
    /// bail (forcing / unknown loop bind).
    fn resolve_var(&mut self, name: &str, bx: &LBox) -> LResult<LV> {
        if name == "t" {
            return Ok(LV::Time);
        }
        if let Some(v) = bx.cbind(name) {
            return Ok(LV::Lit(v as f64));
        }
        if bx.tuple != 0 {
            if let Some(col) = self.tuple_column(bx.tuple, name)? {
                return Ok(col);
            }
            // Anything else a tuple-list body reads is one value for every
            // tuple; a whole array there is not an element of the list.
            let plain = LBox {
                syms: &[],
                lo: DimI::new(),
                shape: DimU::new(),
                cnames: &[],
                cvals: SmallVec::new(),
                tuple: 0,
                visit: SmallVec::new(),
            };
            let v = self.resolve_var(name, &plain)?;
            if self.lv_box(&v).is_some() {
                bail_tape!("variable: whole array `{name}` read inside a tuple-list body");
            }
            return Ok(v);
        }
        if let Some(a) = bx.syms.iter().position(|s| s == name) {
            let key = VnKey::Ramp(a);
            if let Some(hit) = self.vn_get(key, bx) {
                return Ok(hit);
            }
            let sec = self.placement(Cadence::Const);
            let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
            self.emit(
                Instr::Ramp {
                    axis: a as u8,
                    lo: bx.lo[a],
                    out,
                },
                sec,
            );
            let lv = LV::Arr(out);
            self.vn_put(key, &lv, bx);
            return Ok(lv);
        }
        if let Some(&ix) = self.state_ix.get(name) {
            return Ok(LV::State(tape_index(ix, "state variables")?));
        }
        if let Some(ov) = self.obs_defined.get(name).cloned() {
            return match ov {
                ObsVal::Taped(lv) => Ok(lv),
                ObsVal::External {
                    shape: Some(shape),
                    tier,
                } => {
                    let ix = self.obs_read(name)?;
                    Ok(LV::Obs { ix, shape, tier })
                }
                ObsVal::External { shape: None, .. } => {
                    bail_tape!(
                        "variable: observed `{name}` has a statically-unknown shape (fallback producer)"
                    )
                }
            };
        }
        if let Some(i) = self.param_names.iter().position(|p| p == name) {
            return Ok(LV::Param(tape_index(i, "parameters")?));
        }
        if let Some(lv) = self.forcing_read(name)? {
            return Ok(lv);
        }
        bail_tape!("variable: unresolved symbol (forcing/loop-bind?): {name}")
    }

    /// Mirror of `eval_vec_op`'s dispatch (via the SAME `vec_op_code`).
    ///
    /// One operator is dispatched AHEAD of that mirror: the §9.2 closed-function
    /// call `fn`. The overlay has no arm for it (`vec_op_code` classifies it
    /// `Unsupported`, which is what routes it to the per-cell oracle in
    /// production), so there is no overlay decision to compile — the tape
    /// lowers the `datetime.*` family into its own arithmetic instead, and the
    /// reference it is pinned against is the oracle's closed-function registry.
    fn lower_op(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        if node.op == "fn" {
            return self.lower_closed_fn(node, bx);
        }
        // The overlay has no geometry arm either (`vec_op_code` classifies it
        // `Unsupported`), so the reference here is the per-cell oracle's
        // `eval_polygon_intersection_area`, called on each cell's two rings.
        if node.op == "polygon_intersection_area" {
            return self.lower_poly_area(node, Some(bx));
        }
        self.lower_op_code(vec_op_code(&node.op), node, bx)
    }

    /// [`Self::lower_op`] with the operator already resolved to a [`VecOp`], so
    /// the `Broadcast` arm can re-enter with the code of its `fn` against the
    /// SAME node (mirroring `eval_vec_op_code` and the oracle's
    /// `eval_op_named` — the tape's half of the issue-#101 fix).
    fn lower_op_code(&mut self, code: VecOp, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        match code {
            // The precision-boundary marker (`crate::precision_infer`). The
            // tape resolves its kernels at EXECUTION, from the thread-local
            // precision, so a boundary cannot be honoured by a guard held only
            // while lowering: the instruction it emitted would run later, in
            // whatever precision was then in force. Bail to the vectorized
            // overlay / per-cell oracle, both of which evaluate the marker
            // where its guard is still standing. Reachable only in a document
            // that declares a per-variable `element_type`.
            VecOp::Precision => {
                let (arg, _precision) = self.marker_operand(node)?;
                self.lower_expr(arg, bx)
            }
            VecOp::Arith(code) => {
                let Some((first, rest)) = node.args.split_first() else {
                    bail_tape!("op: `{}` with no arguments", node.op);
                };
                if code == BinCode::Sub && rest.is_empty() {
                    let v = self.lower_expr(first, bx)?;
                    return self.emit_neg(v);
                }
                let mut acc = self.lower_expr(first, bx)?;
                for a in rest {
                    let v = self.lower_expr(a, bx)?;
                    acc = self.emit_bin(code, acc, v)?;
                }
                Ok(acc)
            }
            VecOp::Neg => {
                let Some(first) = node.args.first() else {
                    bail_tape!("op: `neg` with no arguments");
                };
                let v = self.lower_expr(first, bx)?;
                self.emit_neg(v)
            }
            VecOp::Index => self.lower_index(node, bx),
            VecOp::Aggregate => self.lower_nested_aggregate(node, bx),
            VecOp::Makearray => self.lower_makearray(node, bx),
            VecOp::Const => match eval_const(node) {
                Value::Scalar(s) => Ok(LV::Lit(s)),
                Value::Array(_) => bail_tape!("op: array-valued `const`"),
            },
            VecOp::BoolLit(b) => Ok(LV::Lit(if b { 1.0 } else { 0.0 })),
            VecOp::Cmp(code) => {
                if node.args.len() != 2 {
                    bail_tape!(
                        "op: comparison `{}` with arity {}",
                        node.op,
                        node.args.len()
                    );
                }
                let a = self.lower_expr(&node.args[0], bx)?;
                let b = self.lower_expr(&node.args[1], bx)?;
                self.emit_bin(code, a, b)
            }
            VecOp::Ifelse => self.lower_ifelse(node, bx),
            VecOp::Unary(code) => {
                if node.args.len() != 1 {
                    bail_tape!("op: unary `{}` with arity {}", node.op, node.args.len());
                }
                let v = self.lower_expr(&node.args[0], bx)?;
                Ok(self.emit_un(code, v))
            }
            // esm-spec §4.3.4: apply the scalar operator named in `fn`
            // element-wise. Lower it as the bare `{"op": fn, "args": args}` node
            // would be lowered, so the tape emits the same instructions the
            // overlay and the oracle evaluate (issue #101 — this arm used to
            // resolve `fn` through the BINARY table and left-fold, so a
            // one-operand `broadcast` lowered to a bare copy of `args[0]`).
            VecOp::Broadcast => {
                let Some(fn_name) = node.broadcast_fn.as_deref() else {
                    bail_tape!("op: `broadcast` with no `fn`");
                };
                if !crate::op_registry::is_scalar_operator(fn_name) {
                    bail_tape!("op: broadcast fn `{fn_name}` is not a scalar operator");
                }
                self.lower_op_code(vec_op_code(fn_name), node, bx)
            }
            VecOp::Unsupported => {
                bail_tape!("op: unsupported operator `{}`/{}", node.op, node.args.len())
            }
        }
    }

    /// `vec_combine` made symbolic: fold literals with the SAME kernel table,
    /// require array operands to share one box, broadcast scalars.
    fn emit_bin(&mut self, code: BinCode, a: LV, b: LV) -> LResult<LV> {
        if let (LV::Lit(x), LV::Lit(y)) = (&a, &b) {
            return Ok(LV::Lit(binary_kernel_of(code)(*x, *y)));
        }
        let ba = self.lv_box(&a);
        let bb = self.lv_box(&b);
        let (shape, origin, scalar) = match (&ba, &bb) {
            (None, None) => (DimU::new(), DimI::new(), true),
            (Some((s, o)), None) | (None, Some((s, o))) => (s.clone(), o.clone(), false),
            (Some((sa, oa)), Some((sb, ob))) => {
                if sa != sb || oa != ob {
                    bail_tape!(
                        "combine: array operand boxes differ ({sa:?}@{oa:?} vs {sb:?}@{ob:?})"
                    );
                }
                (sa.clone(), oa.clone(), false)
            }
        };
        let want = self.lv_cadence(&a).max(self.lv_cadence(&b));
        let sec = self.placement(want);
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Bin {
            op: code,
            a: self.op_of(&a),
            b: self.op_of(&b),
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    fn emit_un(&mut self, code: UnCode, a: LV) -> LV {
        if let LV::Lit(x) = &a {
            return LV::Lit(unary_kernel_of(code)(*x));
        }
        let (shape, origin, scalar) = match self.lv_box(&a) {
            None => (DimU::new(), DimI::new(), true),
            Some((s, o)) => (s, o, false),
        };
        let sec = self.placement(self.lv_cadence(&a));
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Un {
            op: code,
            a: self.op_of(&a),
            out,
        };
        self.emit(instr, sec);
        if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        }
    }

    fn emit_neg(&mut self, a: LV) -> LResult<LV> {
        if let LV::Lit(x) = &a {
            return Ok(LV::Lit(-x));
        }
        let (shape, origin, scalar) = match self.lv_box(&a) {
            None => (DimU::new(), DimI::new(), true),
            Some((s, o)) => (s, o, false),
        };
        let sec = self.placement(self.lv_cadence(&a));
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Neg {
            a: self.op_of(&a),
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    /// A zero-filled array over `box` (the ghost-only gather results).
    fn emit_zero_array(&mut self, shape: &[usize], origin: &[i64]) -> LV {
        let sec = self.placement(Cadence::Const);
        let out = self.new_slot(shape, origin, false, sec);
        self.emit(
            Instr::Fill {
                v: Operand::Lit(0.0),
                out,
            },
            sec,
        );
        LV::Arr(out)
    }

    /// Materialize an inline array literal as a CONST-section slot
    /// ([`Instr::ConstArray`]): one instruction and one slab store per solve,
    /// whatever the literal's size. The box is the literal's own shape at the
    /// all-1s origin — the convention under which a wholesale-evaluated array
    /// is read (`lookup_variable` serves stored arrays origin-blind).
    fn emit_const_array(&mut self, a: &ndarray::ArrayD<f64>) -> LResult<LV> {
        let shape: DimU = a.shape().iter().copied().collect();
        if shape.is_empty() {
            // `json_to_value` never produces one (a rank-0 literal arrives as
            // `Value::Scalar`), and a 0-d array slot would need scalar, not
            // array, operand semantics.
            bail_tape!("wholesale: rank-0 array-valued `const`");
        }
        if shape.contains(&0) {
            bail_tape!("wholesale: empty array-valued `const`");
        }
        // `iter()` is the LOGICAL row-major walk, which is the slab layout.
        let values: Vec<f64> = a.iter().copied().collect();
        let data = self.const_data.len() as u32;
        self.const_data.push(ConstArrayData {
            shape: shape.clone(),
            values,
        });
        let sec = self.placement(Cadence::Const);
        let origin = DimI::from_elem(1, shape.len());
        let out = self.new_slot(&shape, &origin, false, sec);
        self.emit(Instr::ConstArray { data, out }, sec);
        Ok(LV::Arr(out))
    }

    /// Fill an array slot over `box` with a scalar LV (`Fill` broadcast).
    fn emit_fill(&mut self, v: &LV, shape: &[usize], origin: &[i64], cad_floor: Cadence) -> LV {
        let want = self.lv_cadence(v).max(cad_floor);
        let sec = self.placement(want);
        let out = self.new_slot(shape, origin, false, sec);
        self.emit(
            Instr::Fill {
                v: self.op_of(v),
                out,
            },
            sec,
        );
        LV::Arr(out)
    }

    // -- closed functions (esm-spec §9.2): the `datetime.*` family ------------
    //
    // The family is lowered HERE, into instructions the tape already has, so
    // the fast executor, the reference executor and the XlaBuilder emitter all
    // gain it without a new opcode and without three chances to disagree.
    //
    // That is possible because the spec's own recipe — ONE floored divmod of
    // `t_utc` by 86400, then exact integer arithmetic on the resulting (days,
    // seconds-of-day) pair — carries in `f64` with no rounding at all. Every
    // intermediate is an integer well inside binary64's 2^53 exact-integer
    // range, where `+`, `-` and `*` are exact; and `floor(a / b)` for integer
    // `a`, `b` is the integer quotient whenever `|a| << 2^52`, because the
    // division's <= 0.5 ulp error is then far smaller than the `1/b` gap that
    // separates a non-integral quotient from the integer below it. IEEE-754
    // pins `floor`, `ceil`, `+`, `-` and `*` identically in the interpreter's
    // kernels and in XLA, so the compiled lane returns the same bits rather
    // than merely the same numbers.
    //
    // `/` IS THE ONE EXCEPTION, and it is why every floored and truncated
    // division below recovers its quotient from the remainder instead of
    // trusting it: a compiled backend may answer `x / c` with `x * fl(1/c)`,
    // which is a second rounding, and at an exact-integer quotient that reads
    // one short. See `dt_floor_div`.
    //
    // The reference reproduced step for step is `crate::registered_functions`
    // (Hinnant's `civil_from_days` for the calendar, Fliegel-van Flandern for
    // the Julian day), because that is what the per-cell oracle evaluates for
    // a `fn` node and what a taped rule has to agree with bit for bit.
    //
    // DOMAIN: the agreement holds wherever the reference's own `i64` pipeline
    // is meaningful, i.e. for `t_utc` whose day count stays far inside 2^52.
    // Beyond that the reference is casting a non-integral `f64` to `i64`
    // anyway, so there is no shared answer to reproduce.

    /// Lower a §9.2 closed-function call inside an output box. The `datetime.*`
    /// family is expanded into tape arithmetic, the `interp.*` family into one
    /// [`Instr::Interp`]; everything else in the registry bails by name.
    fn lower_closed_fn(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        let name = self.closed_fn_name(node)?;
        if let Some(kind) = InterpKind::from_name(name) {
            return self.lower_interp(kind, node, Some(bx));
        }
        self.datetime_call_ok(name, node)?;
        let t = self.lower_expr(&node.args[0], bx)?;
        // A value whose box IS the enclosing output box is the vectorization of
        // a per-cell SCALAR, which is what the registry wants; anything else
        // (an inline array literal, say) is an array argument, which the
        // registry rejects with `closed_function_arg_type`.
        if let Some((shape, origin)) = self.lv_box(&t)
            && (shape.as_slice() != bx.shape.as_slice() || origin.as_slice() != bx.lo.as_slice())
        {
            bail_tape!(
                "op: closed function `{name}` on an array-valued argument (the registry \
                 takes a scalar `t_utc`)"
            );
        }
        self.lower_datetime(name, t)
    }

    /// [`Self::lower_closed_fn`] on the wholesale (scalar-`eval` mirror) path,
    /// where there is no output box: an array-valued argument is simply an
    /// array argument, which the registry rejects.
    fn lower_wholesale_closed_fn(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let name = self.closed_fn_name(node)?;
        if let Some(kind) = InterpKind::from_name(name) {
            return self.lower_interp(kind, node, None);
        }
        self.datetime_call_ok(name, node)?;
        let t = self.lower_wholesale(&node.args[0])?;
        if self.lv_box(&t).is_some() {
            bail_tape!(
                "wholesale: closed function `{name}` on an array-valued argument (the \
                 registry takes a scalar `t_utc`)"
            );
        }
        self.lower_datetime(name, t)
    }

    /// The name of a `fn` node this lowering can expand, or a bail saying why
    /// not. Only membership is decided here; each family checks its own arity
    /// (they differ) in [`Self::datetime_call_ok`] / [`Self::lower_interp`].
    fn closed_fn_name<'n>(&self, node: &'n Arc<ExpressionNode>) -> LResult<&'n str> {
        let Some(name) = node.name.as_deref() else {
            bail_tape!("op: `fn` with no `name`");
        };
        /// The nine calendar entries of the v1 closed-function registry.
        const DATETIME: &[&str] = &[
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
        if !DATETIME.contains(&name) && InterpKind::from_name(name).is_none() {
            bail_tape!("op: closed function `{name}` has no tape lowering (esm-spec §9.2)");
        }
        Ok(name)
    }

    /// The `datetime.*`-only half of what [`Self::closed_fn_name`] used to
    /// check: unary arity and the binary64 precision precondition. Both call
    /// sites run it, so they agree on what they refuse.
    fn datetime_call_ok(&self, name: &str, node: &Arc<ExpressionNode>) -> LResult<()> {
        if node.args.len() != 1 {
            // The registry answers a wrong arity with `closed_function_arity`,
            // which `eval_fn` turns into its NaN sentinel. Bailing routes the
            // rule to the oracle, which produces exactly that.
            bail_tape!(
                "op: closed function `{name}` with arity {}",
                node.args.len()
            );
        }
        if self.f32_document {
            bail_tape!(
                "op: closed function `{name}` under a Float32 document (the calendar \
                 decomposition is exact integer arithmetic in binary64, and the tape \
                 resolves its kernels at execution)"
            );
        }
        Ok(())
    }

    // -- closed functions (esm-spec §9.2): the `interp.*` family -------------
    //
    // Unlike `datetime.*`, this family is NOT expanded into tape arithmetic.
    // Its cell search is a scan of a table whose length is fixed at build time
    // but is not small — the corpus runs to 94x49 — and unrolling that into a
    // select chain would put thousands of instructions on the tape per call
    // site, times the 460-odd call sites the corpus has. So it gets one
    // instruction whose element semantics ARE the registry functions
    // (`Instr::Interp`), which is what `eval_fn` calls: the taped rule and the
    // per-cell oracle run the same code on the same operands.
    //
    // That also removes the reason `datetime.*` bails under a Float32
    // document. The calendar lowering emits ordinary tape instructions, whose
    // kernels resolve to binary32 there; this one does not emit any, and
    // `eval_fn` lifts the registry's binary64 result without rounding it, so
    // the two agree at either document precision.
    //
    // The table and the axes are read at build time, which the format
    // guarantees: §9.2's argument shape contract requires them to be literal
    // `const`-op arrays (diagnostics `interp_table_not_const` /
    // `interp_axis_not_const`), so there is no runtime-table case to lower.

    /// Lower one §9.2 `interp.*` call into a single [`Instr::Interp`].
    ///
    /// `bx` is `Some` inside an output box — where an array-valued query is
    /// the vectorization of a per-cell scalar and must therefore span exactly
    /// that box — and `None` on the wholesale path, where an array-valued
    /// query is a genuine array argument.
    fn lower_interp(
        &mut self,
        kind: InterpKind,
        node: &Arc<ExpressionNode>,
        bx: Option<&LBox>,
    ) -> LResult<LV> {
        let name = kind.name();
        // §9.2 puts the query LAST for the two tensor entries and FIRST for
        // the search entry.
        let (arity, ix, iy) = match kind {
            InterpKind::Linear => (3, 2, None),
            InterpKind::Bilinear => (5, 3, Some(4)),
            InterpKind::SearchSorted => (2, 0, None),
        };
        if node.args.len() != arity {
            bail_tape!(
                "op: closed function `{name}` with arity {}",
                node.args.len()
            );
        }
        let table = self.interp_table(kind, node)?;
        let x = self.lower_interp_query(&node.args[ix], bx)?;
        let y = match iy {
            Some(i) => Some(self.lower_interp_query(&node.args[i], bx)?),
            None => None,
        };

        // The output box, taken from whichever queries are arrays.
        let mut obox: Option<(DimU, DimI)> = None;
        for q in [Some(&x), y.as_ref()].into_iter().flatten() {
            let Some((shape, origin)) = self.lv_box(q) else {
                continue;
            };
            match &obox {
                None => obox = Some((shape, origin)),
                Some((s, o)) => {
                    if s.as_slice() != shape.as_slice() || o.as_slice() != origin.as_slice() {
                        bail_tape!(
                            "op: closed function `{name}` with query arguments in \
                             different boxes"
                        );
                    }
                }
            }
        }
        if let Some((shape, origin)) = &obox {
            match bx {
                // Inside a box, anything that is not THE box is a real array
                // argument, which the registry rejects with
                // `closed_function_arg_type`.
                Some(b)
                    if shape.as_slice() != b.shape.as_slice()
                        || origin.as_slice() != b.lo.as_slice() =>
                {
                    bail_tape!(
                        "op: closed function `{name}` on an array-valued query (the \
                         registry takes a scalar)"
                    );
                }
                // Wholesale, `eval_fn` broadcasts an array query over the
                // fixed table for `interp.linear` ONLY; the other two entries
                // reach `expect_scalar` and come back as the NaN sentinel,
                // which only the oracle produces.
                None if kind != InterpKind::Linear => {
                    bail_tape!(
                        "wholesale: closed function `{name}` on an array-valued query \
                         (the registry takes a scalar)"
                    );
                }
                Some(_) | None => {}
            }
        }

        // A call whose queries are all compile-time known is one number —
        // unless it is a strict table's out-of-range query, whose fault must
        // be raised by the evaluation that reads it, not by this lowering.
        let lit_y = match &y {
            None => Some(f64::NAN),
            Some(LV::Lit(v)) => Some(*v),
            Some(_) => None,
        };
        if let (LV::Lit(xv), Some(yv)) = (&x, lit_y)
            && table.out_of_bounds(*xv, yv).is_none()
        {
            return Ok(LV::Lit(table.at(*xv, yv)));
        }

        let tix = self.interp_tables.len() as u32;
        self.interp_tables.push(table);
        let want = self
            .lv_cadence(&x)
            .max(y.as_ref().map_or(Cadence::Const, |v| self.lv_cadence(v)));
        let sec = self.placement(want);
        let (shape, origin, scalar) = match &obox {
            None => (DimU::new(), DimI::new(), true),
            Some((s, o)) => (s.clone(), o.clone(), false),
        };
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Interp {
            table: tix,
            x: self.op_of(&x),
            y: y.as_ref().map(|v| self.op_of(v)),
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    /// Lower one query argument of an `interp.*` call, on whichever of the two
    /// paths the call arrived by.
    fn lower_interp_query(&mut self, arg: &Expr, bx: Option<&LBox>) -> LResult<LV> {
        match bx {
            Some(b) => self.lower_expr(arg, b),
            None => self.lower_wholesale(arg),
        }
    }

    /// Read and validate the constant table + axes of an `interp.*` call.
    ///
    /// Validation is delegated to the registry itself — the table is offered
    /// to `evaluate_closed_function` with a probe query, and every §9.2
    /// load-time diagnostic (length mismatch, too-short axis, NaN in an axis,
    /// non-monotonic axis) is raised there before the query is looked at. So
    /// the tape's acceptance condition IS the registry's, with no second
    /// statement of the rules to drift from it, and a table the registry
    /// rejects bails to the oracle, which is what turns the registry error
    /// into `eval_fn`'s NaN sentinel.
    fn interp_table(&self, kind: InterpKind, node: &Arc<ExpressionNode>) -> LResult<InterpTable> {
        use crate::registered_functions::{ClosedArg, evaluate_closed_function};
        let name = kind.name();
        let (table, axis_x, axis_y, probe) = match kind {
            InterpKind::Linear => {
                let (_, t) = self.interp_const_arg(name, &node.args[0], "table", 1)?;
                let (_, ax) = self.interp_const_arg(name, &node.args[1], "axis", 1)?;
                let probe = vec![
                    ClosedArg::Array(t.clone()),
                    ClosedArg::Array(ax.clone()),
                    ClosedArg::Scalar(0.0),
                ];
                (t, ax, Vec::new(), probe)
            }
            InterpKind::Bilinear => {
                let (_, ax) = self.interp_const_arg(name, &node.args[1], "axis_x", 1)?;
                let (_, ay) = self.interp_const_arg(name, &node.args[2], "axis_y", 1)?;
                let t = self.interp_const_arg_2d(name, &node.args[0], ay.len())?;
                let probe = vec![
                    ClosedArg::Array2D(t.chunks(ay.len().max(1)).map(<[f64]>::to_vec).collect()),
                    ClosedArg::Array(ax.clone()),
                    ClosedArg::Array(ay.clone()),
                    ClosedArg::Scalar(0.0),
                    ClosedArg::Scalar(0.0),
                ];
                (t, ax, ay, probe)
            }
            InterpKind::SearchSorted => {
                let (_, xs) = self.interp_const_arg(name, &node.args[1], "xs", 1)?;
                let probe = vec![ClosedArg::Scalar(0.0), ClosedArg::Array(xs.clone())];
                (Vec::new(), xs, Vec::new(), probe)
            }
        };
        if let Err(e) = evaluate_closed_function(name, &probe) {
            bail_tape!(
                "op: closed function `{name}` whose table the registry rejects ({}): {}",
                e.code,
                e.message
            );
        }
        Ok(InterpTable {
            kind,
            table,
            axis_x,
            axis_y,
            strict: crate::lower_table_lookup::strict_table(node).map(str::to_string),
        })
    }

    /// One rank-1 `const`-op array argument of an `interp.*` call, flattened
    /// through `eval_const` — the same walk the oracle's `eval` performs on
    /// that node, so the two read the same numbers (Float32 ingress rounding
    /// included).
    fn interp_const_arg(
        &self,
        name: &str,
        arg: &Expr,
        label: &str,
        rank: usize,
    ) -> LResult<(Vec<usize>, Vec<f64>)> {
        let Expr::Operator(n) = arg else {
            bail_tape!(
                "op: closed function `{name}`'s `{label}` argument is not an inline \
                 `const` array (esm-spec §9.2 requires a literal `const`)"
            );
        };
        if n.op != "const" {
            bail_tape!(
                "op: closed function `{name}`'s `{label}` argument is a `{}` node, not \
                 an inline `const` array (esm-spec §9.2)",
                n.op
            );
        }
        match eval_const(n) {
            // `iter()` is the LOGICAL row-major walk, which for the rank-2
            // `interp.bilinear` table is §9.2's `table[i][j]` layout.
            Value::Array(a) if a.ndim() == rank => {
                Ok((a.shape().to_vec(), a.iter().copied().collect()))
            }
            _ => bail_tape!(
                "op: closed function `{name}`'s `{label}` argument is not a rank-{rank} \
                 `const` array"
            ),
        }
    }

    /// The rank-2 `table` argument of `interp.bilinear`, flattened ROW-MAJOR.
    ///
    /// The inner extent is taken from the LITERAL's own shape and checked
    /// against `len(axis_y)` here, rather than inferred by dividing the
    /// element count: the oracle builds its nested `ClosedArg::Array2D` from
    /// that same shape, so a table whose rows are the wrong length has to be
    /// refused even when the element count happens to divide.
    fn interp_const_arg_2d(&self, name: &str, arg: &Expr, ny: usize) -> LResult<Vec<f64>> {
        let (shape, flat) = self.interp_const_arg(name, arg, "table", 2)?;
        if shape[1] != ny {
            bail_tape!(
                "op: closed function `{name}`'s `table` row length {} != len(axis_y)={ny} \
                 (interp_axis_length_mismatch)",
                shape[1]
            );
        }
        Ok(flat)
    }

    /// Expand one `datetime.*` entry over an already-lowered `t_utc`.
    ///
    /// Each arm computes only the half of the divmod it reads: the tape has no
    /// dead-code pass, so an unconditional seconds-of-day would be six
    /// instructions the interpreter runs on every call of `datetime.year`.
    fn lower_datetime(&mut self, name: &str, t: LV) -> LResult<LV> {
        let day = self.dt_day_count(t.clone())?;
        match name {
            "datetime.hour" | "datetime.minute" | "datetime.second" => {
                let sec = self.dt_sec_in_day(t, day)?;
                let (hour, minute, second) = self.dt_hms(sec)?;
                Ok(match name {
                    "datetime.hour" => hour,
                    "datetime.minute" => minute,
                    _ => second,
                })
            }
            "datetime.julian_day" => {
                let sec = self.dt_sec_in_day(t, day.clone())?;
                self.dt_julian_day(day, sec)
            }
            _ => {
                let (y, m, d) = self.dt_civil_from_days(day)?;
                match name {
                    "datetime.year" => Ok(y),
                    "datetime.month" => Ok(m),
                    "datetime.day" => Ok(d),
                    "datetime.is_leap_year" => self.dt_is_leap_year(y),
                    // `datetime.day_of_year`
                    _ => self.dt_day_of_year(y, m, d),
                }
            }
        }
    }

    /// `a <op> literal` — the shape nearly every step of the decomposition takes.
    fn dt_op(&mut self, code: BinCode, a: LV, k: f64) -> LResult<LV> {
        self.emit_bin(code, a, LV::Lit(k))
    }

    /// [`Self::emit_select`] that folds a compile-time-known condition, so a
    /// `datetime.*` call on a literal time collapses to one literal at build
    /// time instead of leaving a dozen dead instructions on the tape.
    fn dt_select(&mut self, cond: LV, a: LV, b: LV) -> LResult<LV> {
        if let LV::Lit(c) = cond {
            return Ok(if c != 0.0 { a } else { b });
        }
        self.emit_select(cond, a, b)
    }

    /// `trunc(q)` — round toward zero, which is what Rust's `as i64` and its
    /// integer `/` do, and what `f64::trunc` does in the reference.
    fn dt_trunc(&mut self, q: LV) -> LResult<LV> {
        let neg = self.dt_op(BinCode::Lt, q.clone(), 0.0)?;
        let up = self.emit_un(UnCode::Ceil, q.clone());
        let down = self.emit_un(UnCode::Floor, q);
        self.dt_select(neg, up, down)
    }

    /// `floor(a / k)` — floored integer division (`k > 0`), with the quotient
    /// RECOVERED FROM THE REMAINDER rather than trusted.
    ///
    /// The module header's argument — `floor(a / k)` on exact integers is the
    /// exact integer quotient, because the division's rounding is far smaller
    /// than the gap separating a non-integral quotient from the integer below
    /// it — assumes a CORRECTLY ROUNDED DIVIDE, and a compiled backend is not
    /// obliged to give one. XLA's algebraic simplifier rewrites `x / c` for a
    /// constant `c` into `x * fl(1/c)`, and a reciprocal is a second rounding.
    /// Of this family's divisors, `146097` (days per 400-year era) is the one
    /// that does not survive it: `fl(1/146097)` is below the true reciprocal,
    /// so a `z` sitting exactly on an era boundary comes back a hair under the
    /// integer and `floor` reads the era one short. Nothing about the calendar
    /// is wrong there — the DIVIDE is, by one unit in the last place — but the
    /// result is a whole day of error in the date, which no tolerance class
    /// covers and none should.
    ///
    /// It is also the kind of defect a compiled lane ships with: it fires only
    /// where the quotient is an exact integer, so every other day of the era is
    /// right, and the host path (which the A/B tests exercise) is never
    /// affected at all.
    ///
    /// So the quotient is a CANDIDATE. `r = a - q*k` is exact whenever `a` and
    /// `q*k` are exact integers below `2^53`, which this family's precondition
    /// already guarantees, and the true floor is the unique `q` with
    /// `0 <= r < k`. Two selects therefore repair any quotient within one unit
    /// of the truth — which every divide of any kind is, correctly rounded or
    /// not — and on a host, where `q` was already right, both are no-ops and
    /// the value is bit for bit what the bare `floor(a / k)` returned. Branch
    /// free, so it stays the same kind of program a bare divide was.
    fn dt_floor_div(&mut self, a: LV, k: f64) -> LResult<LV> {
        let q = self.dt_op(BinCode::Div, a.clone(), k)?;
        let q = self.emit_un(UnCode::Floor, q);
        let whole = self.dt_op(BinCode::Mul, q.clone(), k)?;
        let r = self.emit_bin(BinCode::Sub, a, whole)?;
        let below = self.dt_op(BinCode::Lt, r.clone(), 0.0)?;
        let above = self.dt_op(BinCode::Ge, r, k)?;
        let down = self.dt_op(BinCode::Sub, q.clone(), 1.0)?;
        let up = self.dt_op(BinCode::Add, q.clone(), 1.0)?;
        let inner = self.dt_select(above, up, q)?;
        self.dt_select(below, down, inner)
    }

    /// `a / k` rounded TOWARD ZERO — Rust's `i64` division, which the
    /// Fliegel-van Flandern formula depends on (using a floored division for
    /// its `(m - 14) / 12` term would shift January and February by a day).
    ///
    /// Built on [`Self::dt_floor_div`]'s repaired quotient rather than on a raw
    /// one, for the reason spelled out there, and then stepped back toward zero
    /// on the negative side: for `k > 0` the two roundings agree except where
    /// `a` is negative AND the division does not come out even, and the
    /// repaired remainder is exactly the evenness test.
    fn dt_trunc_div(&mut self, a: LV, k: f64) -> LResult<LV> {
        let q = self.dt_floor_div(a.clone(), k)?;
        let whole = self.dt_op(BinCode::Mul, q.clone(), k)?;
        let r = self.emit_bin(BinCode::Sub, a.clone(), whole)?; // exact, in [0, k)
        let uneven = self.dt_op(BinCode::Gt, r, 0.0)?;
        let neg = self.dt_op(BinCode::Lt, a, 0.0)?;
        let step = self.emit_bin(BinCode::And, neg, uneven)?;
        let up = self.dt_op(BinCode::Add, q.clone(), 1.0)?;
        self.dt_select(step, up, q)
    }

    /// The reference casts the day count and the truncated seconds-of-day to
    /// `i64` before doing any integer work, and Rust's float-to-int cast
    /// saturates: NaN becomes 0. So `datetime.year(NaN)` there is 1970, not
    /// NaN. Reproduce that — otherwise a NaN state during a rejected solver
    /// step would be the one input on which the tape and the oracle disagree.
    fn dt_nan_to_zero(&mut self, v: LV) -> LResult<LV> {
        let is_nan = self.emit_bin(BinCode::Ne, v.clone(), v.clone())?;
        self.dt_select(is_nan, LV::Lit(0.0), v)
    }

    /// The day half of `floor_div_mod` — the ONE floored divmod by 86400 the
    /// spec allows before all the arithmetic goes integer.
    fn dt_day_count(&mut self, t: LV) -> LResult<LV> {
        self.dt_floor_div(t, 86400.0)
    }

    /// The seconds-of-day half, in `[0, 86400)`.
    fn dt_sec_in_day(&mut self, t: LV, day: LV) -> LResult<LV> {
        let off = self.dt_op(BinCode::Mul, day, 86400.0)?;
        let sec = self.emit_bin(BinCode::Sub, t, off)?;
        // The reference re-maps a `sec` that floating-point rounding pushed out
        // of [0, 86400) and deliberately leaves the day count alone; mirror
        // both halves, including the `else if` (so the two adjustments cannot
        // both apply).
        let hi = self.dt_op(BinCode::Ge, sec.clone(), 86400.0)?;
        let lo = self.dt_op(BinCode::Lt, sec.clone(), 0.0)?;
        let down = self.dt_op(BinCode::Sub, sec.clone(), 86400.0)?;
        let up = self.dt_op(BinCode::Add, sec.clone(), 86400.0)?;
        let inner = self.dt_select(lo, up, sec)?;
        self.dt_select(hi, down, inner)
    }

    /// Hinnant's `civil_from_days`: a day count since 1970-01-01 to
    /// `(year, month, day)` on the proleptic-Gregorian calendar.
    fn dt_civil_from_days(&mut self, day_count: LV) -> LResult<(LV, LV, LV)> {
        let day_count = self.dt_nan_to_zero(day_count)?;
        let z = self.dt_op(BinCode::Add, day_count, 719468.0)?;
        // The reference spells `era` as `(z >= 0 ? z : z - 146096) / 146097`
        // with C's truncating `/`, which is the standard way to write
        // `floor(z / 146097)` in integers — so emit the floored division.
        let era = self.dt_floor_div(z.clone(), 146097.0)?;
        let era_days = self.dt_op(BinCode::Mul, era.clone(), 146097.0)?;
        let doe = self.emit_bin(BinCode::Sub, z, era_days)?; // [0, 146096]
        // yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365, left to right.
        let q1460 = self.dt_floor_div(doe.clone(), 1460.0)?;
        let q36524 = self.dt_floor_div(doe.clone(), 36524.0)?;
        let q146096 = self.dt_floor_div(doe.clone(), 146096.0)?;
        let acc = self.emit_bin(BinCode::Sub, doe.clone(), q1460)?;
        let acc = self.emit_bin(BinCode::Add, acc, q36524)?;
        let acc = self.emit_bin(BinCode::Sub, acc, q146096)?;
        let yoe = self.dt_floor_div(acc, 365.0)?; // [0, 399]
        let y = self.dt_op(BinCode::Mul, era, 400.0)?;
        let y = self.emit_bin(BinCode::Add, y, yoe.clone())?;
        // doy = doe - (365*yoe + yoe/4 - yoe/100)
        let leap_days = self.dt_op(BinCode::Mul, yoe.clone(), 365.0)?;
        let q4 = self.dt_floor_div(yoe.clone(), 4.0)?;
        let q100 = self.dt_floor_div(yoe, 100.0)?;
        let start = self.emit_bin(BinCode::Add, leap_days, q4)?;
        let start = self.emit_bin(BinCode::Sub, start, q100)?;
        let doy = self.emit_bin(BinCode::Sub, doe, start)?; // [0, 365], March-based
        // mp = (5*doy + 2) / 153
        let n = self.dt_op(BinCode::Mul, doy.clone(), 5.0)?;
        let n = self.dt_op(BinCode::Add, n, 2.0)?;
        let mp = self.dt_floor_div(n, 153.0)?; // [0, 11]
        // d = doy - (153*mp + 2)/5 + 1
        let off = self.dt_op(BinCode::Mul, mp.clone(), 153.0)?;
        let off = self.dt_op(BinCode::Add, off, 2.0)?;
        let off = self.dt_floor_div(off, 5.0)?;
        let d = self.emit_bin(BinCode::Sub, doy, off)?;
        let d = self.dt_op(BinCode::Add, d, 1.0)?; // [1, 31]
        // m = mp < 10 ? mp + 3 : mp - 9
        let early = self.dt_op(BinCode::Lt, mp.clone(), 10.0)?;
        let m_early = self.dt_op(BinCode::Add, mp.clone(), 3.0)?;
        let m_late = self.dt_op(BinCode::Sub, mp, 9.0)?;
        let m = self.dt_select(early, m_early, m_late)?; // [1, 12]
        // The March-based year rolls over at January: y += (m <= 2).
        let jan_feb = self.dt_op(BinCode::Le, m.clone(), 2.0)?;
        let y_next = self.dt_op(BinCode::Add, y.clone(), 1.0)?;
        let y = self.dt_select(jan_feb, y_next, y)?;
        Ok((y, m, d))
    }

    /// `(hour, minute, second)` from the seconds-of-day. The reference
    /// truncates the fractional second away first, then does `i64` `/` and `%`
    /// — both round toward zero.
    fn dt_hms(&mut self, sec_in_day: LV) -> LResult<(LV, LV, LV)> {
        let s = self.dt_trunc(sec_in_day)?;
        let s = self.dt_nan_to_zero(s)?;
        let hour = self.dt_trunc_div(s.clone(), 3600.0)?;
        let whole_hours = self.dt_op(BinCode::Mul, hour.clone(), 3600.0)?;
        let rem = self.emit_bin(BinCode::Sub, s.clone(), whole_hours)?; // s % 3600
        let minute = self.dt_trunc_div(rem, 60.0)?;
        let whole_minutes = self.dt_trunc_div(s.clone(), 60.0)?;
        let whole_minutes = self.dt_op(BinCode::Mul, whole_minutes, 60.0)?;
        let second = self.emit_bin(BinCode::Sub, s, whole_minutes)?; // s % 60
        Ok((hour, minute, second))
    }

    /// `1.0` when `y` is a proleptic-Gregorian leap year, else `0.0`.
    ///
    /// The remainders are FLOORED where the reference's `%` truncates; the two
    /// conventions differ only in the sign of a non-zero remainder, and every
    /// test here is against zero.
    fn dt_is_leap_year(&mut self, y: LV) -> LResult<LV> {
        let r4 = self.dt_rem(y.clone(), 4.0)?;
        let r100 = self.dt_rem(y.clone(), 100.0)?;
        let r400 = self.dt_rem(y, 400.0)?;
        let by4 = self.dt_op(BinCode::Eq, r4, 0.0)?;
        let not100 = self.dt_op(BinCode::Ne, r100, 0.0)?;
        let by400 = self.dt_op(BinCode::Eq, r400, 0.0)?;
        let common = self.emit_bin(BinCode::And, by4, not100)?;
        self.emit_bin(BinCode::Or, common, by400)
    }

    /// `a - k * floor(a / k)` — the floored remainder.
    fn dt_rem(&mut self, a: LV, k: f64) -> LResult<LV> {
        let q = self.dt_floor_div(a.clone(), k)?;
        let whole = self.dt_op(BinCode::Mul, q, k)?;
        self.emit_bin(BinCode::Sub, a, whole)
    }

    /// Day of year, 1 = January 1.
    ///
    /// The reference adds a cumulative-days table lookup to the day of month
    /// and then a leap-day correction for March onwards. The table is
    /// `floor((367*m - 362) / 12) - 2` for `m >= 3` and `floor((367*m - 362) /
    /// 12)` for January and February — the classic closed form, which agrees
    /// with all twelve of its entries — so the whole thing is
    /// `floor((367*m - 362) / 12) + d` minus 2 for March onwards, plus 1 back
    /// in a leap year. No 12-way select, and no per-element table read.
    fn dt_day_of_year(&mut self, y: LV, m: LV, d: LV) -> LResult<LV> {
        let leap = self.dt_is_leap_year(y)?;
        let base = self.dt_op(BinCode::Mul, m.clone(), 367.0)?;
        let base = self.dt_op(BinCode::Sub, base, 362.0)?;
        let base = self.dt_floor_div(base, 12.0)?;
        let jan_feb = self.dt_op(BinCode::Le, m, 2.0)?;
        let shift = self.emit_bin(BinCode::Sub, LV::Lit(2.0), leap)?;
        let shift = self.dt_select(jan_feb, LV::Lit(0.0), shift)?;
        let doy = self.emit_bin(BinCode::Add, base, d)?;
        self.emit_bin(BinCode::Sub, doy, shift)
    }

    /// Fliegel-van Flandern (1968) Julian Day Number on the date part, plus the
    /// fractional day measured from noon UTC. The one floating-point divide is
    /// the final `/ 86400`, which is where the spec's "<= 1 ulp" allowance for
    /// this entry (and only this entry) comes from.
    fn dt_julian_day(&mut self, day_count: LV, sec_in_day: LV) -> LResult<LV> {
        let (y, m, d) = self.dt_civil_from_days(day_count)?;
        // `a = (m - 14) / 12` truncated. With `m` in [1, 12] the numerator is
        // in [-13, -2], so the quotient is -1 exactly for January and February
        // and 0 otherwise — one select instead of a division.
        let jan_feb = self.dt_op(BinCode::Le, m.clone(), 2.0)?;
        let a = self.dt_select(jan_feb, LV::Lit(-1.0), LV::Lit(0.0))?;
        // (1461 * (y + 4800 + a)) / 4
        let t1 = self.dt_op(BinCode::Add, y.clone(), 4800.0)?;
        let t1 = self.emit_bin(BinCode::Add, t1, a.clone())?;
        let t1 = self.dt_op(BinCode::Mul, t1, 1461.0)?;
        let t1 = self.dt_trunc_div(t1, 4.0)?;
        // (367 * (m - 2 - 12*a)) / 12
        let t2 = self.dt_op(BinCode::Sub, m, 2.0)?;
        let a12 = self.dt_op(BinCode::Mul, a.clone(), 12.0)?;
        let t2 = self.emit_bin(BinCode::Sub, t2, a12)?;
        let t2 = self.dt_op(BinCode::Mul, t2, 367.0)?;
        let t2 = self.dt_trunc_div(t2, 12.0)?;
        // (3 * ((y + 4900 + a) / 100)) / 4
        let t3 = self.dt_op(BinCode::Add, y, 4900.0)?;
        let t3 = self.emit_bin(BinCode::Add, t3, a)?;
        let t3 = self.dt_trunc_div(t3, 100.0)?;
        let t3 = self.dt_op(BinCode::Mul, t3, 3.0)?;
        let t3 = self.dt_trunc_div(t3, 4.0)?;
        let jdn = self.emit_bin(BinCode::Add, t1, t2)?;
        let jdn = self.emit_bin(BinCode::Sub, jdn, t3)?;
        let jdn = self.emit_bin(BinCode::Add, jdn, d)?;
        let jdn = self.dt_op(BinCode::Sub, jdn, 32075.0)?;
        // (jdn as f64) + (sec_in_day - 43200.0) / 86400.0
        let frac = self.dt_op(BinCode::Sub, sec_in_day, 43200.0)?;
        let frac = self.dt_op(BinCode::Div, frac, 86400.0)?;
        self.emit_bin(BinCode::Add, jdn, frac)
    }

    // -- ifelse ---------------------------------------------------------------

    /// The operand of a precision-boundary marker (`crate::precision_infer`)
    /// and the precision it names, which the operand is lowered under: every
    /// instruction it emits is tagged with that precision and runs at it.
    fn marker_operand<'n>(
        &self,
        node: &'n Arc<ExpressionNode>,
    ) -> LResult<(&'n Expr, Option<crate::precision::PrecisionGuard>)> {
        let [arg] = &node.args[..] else {
            bail_tape!("op: `{}` with arity {}", node.op, node.args.len());
        };
        Ok((
            arg,
            crate::precision_infer::marker_precision(node).map(crate::precision::enter),
        ))
    }

    fn lower_ifelse(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        if node.args.len() != 3 {
            bail_tape!("op: `ifelse` with arity {}", node.args.len());
        }
        let cond = self.lower_expr(&node.args[0], bx)?;
        // Compile-time-known scalar condition: lower ONLY the taken branch —
        // exactly what the overlay evaluates (the untaken branch is never
        // visited, so an unsupported construct there must not bail the rule).
        if let LV::Lit(c) = &cond {
            let c = *c;
            return if c != 0.0 {
                self.lower_expr(&node.args[1], bx)
            } else {
                self.lower_expr(&node.args[2], bx)
            };
        }
        match self.lv_box(&cond) {
            // Runtime SCALAR condition: short-circuit via JmpIfZero — the
            // untaken branch's instructions are never executed.
            None => self.lower_branchy_ifelse(cond, &node.args[1], &node.args[2], |s, e| {
                s.lower_expr(e, bx)
            }),
            // ARRAY condition: evaluate BOTH branches and select elementwise
            // (`vec_select`). The oracle, walking the box cell by cell, takes
            // one arm per cell, so each arm is a lazily evaluated position.
            Some(_) => {
                let lazy = u32::from(!bx.syms.is_empty());
                self.lazy_depth += lazy;
                let arms = self
                    .lower_expr(&node.args[1], bx)
                    .and_then(|a| Ok((a, self.lower_expr(&node.args[2], bx)?)));
                self.lazy_depth -= lazy;
                let (a, b) = arms?;
                self.emit_select(cond, a, b)
            }
        }
    }

    /// `vec_select` made symbolic: `cond`'s box is the output box; `a`/`b` are
    /// scalars (broadcast) or arrays over the same box. A scalar `cond` is the
    /// filter-gate shape (whole-term keep/replace — elementwise identical).
    fn emit_select(&mut self, cond: LV, a: LV, b: LV) -> LResult<LV> {
        let cb = self.lv_box(&cond);
        let (shape, origin, scalar) = match &cb {
            Some((s, o)) => (s.clone(), o.clone(), false),
            None => {
                // Scalar condition gate (§5.3 runtime filter): output box is
                // the term's own box (or scalar if both are).
                let ab = self.lv_box(&a);
                let bb = self.lv_box(&b);
                match (&ab, &bb) {
                    (None, None) => (DimU::new(), DimI::new(), true),
                    (Some((s, o)), None) | (None, Some((s, o))) => (s.clone(), o.clone(), false),
                    (Some((sa, oa)), Some((sb, ob))) => {
                        if sa != sb || oa != ob {
                            bail_tape!("select: branch boxes differ");
                        }
                        (sa.clone(), oa.clone(), false)
                    }
                }
            }
        };
        if cb.is_some() {
            let box_ok = |v: Option<(DimU, DimI)>| match v {
                None => true,
                Some((s, o)) => s == shape && o == origin,
            };
            if !box_ok(self.lv_box(&a)) || !box_ok(self.lv_box(&b)) {
                bail_tape!("select: operand box does not match the condition box");
            }
        }
        let want = self
            .lv_cadence(&cond)
            .max(self.lv_cadence(&a))
            .max(self.lv_cadence(&b));
        let sec = self.placement(want);
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Select {
            cond: self.op_of(&cond),
            a: self.op_of(&a),
            b: self.op_of(&b),
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    /// A `faq` term under an optional §5.3 `filter`, over one box: the
    /// filter first, then the body, which the oracle evaluates only where
    /// the filter keeps the cell or tuple (a lazily evaluated position); an
    /// excluded term reads `excluded`. `None` when the filter is the literal
    /// false — no term is kept and the body is never evaluated.
    fn lower_filtered(
        &mut self,
        body: &Expr,
        filter: Option<&Expr>,
        bx: &LBox,
        excluded: LV,
    ) -> LResult<Option<LV>> {
        let keep = match filter {
            None => return self.lower_expr(body, bx).map(Some),
            Some(f) => self.lower_expr(f, bx)?,
        };
        match keep {
            LV::Lit(0.0) => Ok(None),
            LV::Lit(_) => self.lower_expr(body, bx).map(Some),
            keep => {
                self.lazy_depth += 1;
                let term = self.lower_expr(body, bx);
                self.lazy_depth -= 1;
                self.emit_select(keep, term?, excluded).map(Some)
            }
        }
    }

    // -- index (gather) -------------------------------------------------------

    /// Compile-time mirror of `eval_vec_index`, reusing the overlay's OWN axis
    /// classifier. Everything is static except the source data.
    fn lower_index(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        if bx.tuple != 0 {
            return self.lower_tuple_index(node, bx);
        }
        if node.args.is_empty() {
            bail_tape!("index: no arguments");
        }
        // See the same guard in `eval_vec_index`: a const-array gather may not
        // use the ghost-0 fill (§5.5.5).
        let const_base = self.const_arrays.is_const_base(&node.args[0]);
        // An inline array literal as the base is read whole, as the oracle's
        // gather reads it (`const_lit_array`): one CONST-section literal. It
        // is lowered here and nowhere else in a box, where an array value in
        // an elementwise position would mean something else per cell.
        let arg0 = match &node.args[0] {
            Expr::Operator(lit) if lit.op == "const" => match eval_const(lit) {
                Value::Array(a) => self.emit_const_array(&a)?,
                Value::Scalar(s) => LV::Lit(s),
            },
            base => self.lower_expr(base, bx)?,
        };
        let n = node.args.len() - 1;
        let Some((src_shape, src_origin)) = self.lv_box(&arg0) else {
            return if n == 0 {
                Ok(arg0)
            } else {
                self.index_on_scalar(&node.args[0], &arg0, n, Some(bx))
            };
        };
        let src_ndim = src_shape.len();
        if n != src_ndim {
            bail_tape!("index: arg count != source rank ({n} args vs rank {src_ndim})");
        }
        let out_ndim = bx.shape.len();
        let vb = bx.as_vecbox();

        let mut mapped: SmallVec<[Option<(usize, AxisIndex)>; 4]> =
            (0..out_ndim).map(|_| None).collect();
        let mut n_mapped = 0usize;
        // `(source dim, 1-based index)` of every constant subscript.
        let mut fixed_raw: SmallVec<[(usize, i64); 4]> = SmallVec::new();
        // The one source axis whose subscript is DATA (`u[nbr[i, k]]`), if
        // any: an indexed gather rather than a segment copy.
        let mut data_axis: Option<usize> = None;
        for d in 0..n {
            let e = &node.args[1 + d];
            match classify_axis_role(e, &vb) {
                Some(AxisRole::Map { out_axis, ax }) if mapped[out_axis].is_none() => {
                    mapped[out_axis] = Some((d, ax));
                    n_mapped += 1;
                }
                Some(AxisRole::Const(idx1)) => fixed_raw.push((d, idx1)),
                None if data_axis.is_none() && !const_base => data_axis = Some(d),
                _ => bail_tape!(
                    "index: axis {d} is neither an affine/wrap map of an unclaimed output symbol nor a constant select"
                ),
            }
        }
        if const_base {
            return self.lower_const_gather(
                node,
                bx,
                arg0,
                &src_shape,
                &src_origin,
                &mapped,
                &fixed_raw,
            );
        }
        let mut fixed: SmallVec<[(usize, i64); 4]> = SmallVec::new();
        let mut any_fixed_oob = false;
        for &(d, idx1) in &fixed_raw {
            let i0 = idx1 - src_origin[d];
            if i0 < 0 || i0 >= src_shape[d] as i64 {
                any_fixed_oob = true;
                fixed.push((d, 0));
            } else {
                fixed.push((d, i0));
            }
        }
        if let Some(d) = data_axis {
            return self.lower_index_gather(node, bx, &arg0, d, &mapped, &fixed, any_fixed_oob);
        }

        // A fixed axis out of bounds ⇒ every read is the Dirichlet ghost 0.
        if any_fixed_oob {
            return Ok(if n_mapped == 0 {
                LV::Lit(0.0)
            } else {
                self.emit_zero_array(&bx.shape, &bx.lo)
            });
        }

        // All-fixed ⇒ a single source element, broadcast as a scalar.
        if n_mapped == 0 {
            return Ok(self.emit_load_elem(&arg0, &fixed));
        }

        // Per-axis copy segments, verbatim from `eval_vec_index`.
        let mut axis_segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = SmallVec::new();
        for a in 0..out_ndim {
            let Some((orig_d, ax)) = &mapped[a] else {
                let mut segs = SmallVec::new();
                segs.push((0usize, bx.shape[a], 0usize));
                axis_segs.push(segs);
                continue;
            };
            let so = src_origin[*orig_d];
            let ssz = src_shape[*orig_d] as i64;
            match ax {
                AxisIndex::Affine(k) => {
                    let k = *k;
                    let lo_p = (so - bx.lo[a] - k).max(0);
                    let hi_p = (so + ssz - bx.lo[a] - k).min(bx.shape[a] as i64); // exclusive
                    if lo_p >= hi_p {
                        // Entirely out of bounds ⇒ the whole result is ghost-0.
                        return Ok(self.emit_zero_array(&bx.shape, &bx.lo));
                    }
                    let mut segs = SmallVec::new();
                    segs.push((
                        lo_p as usize,
                        (hi_p - lo_p) as usize,
                        (bx.lo[a] + lo_p + k - so) as usize,
                    ));
                    axis_segs.push(segs);
                }
                AxisIndex::Wrap { k, period } => {
                    axis_segs.push(full_roll_segs(so, ssz, bx.lo[a], bx.shape[a], *k, *period)?);
                }
            }
        }
        let fixed_desc: SmallVec<[(usize, usize); 4]> =
            fixed.iter().map(|&(d, i0)| (d, i0 as usize)).collect();
        let mapped_flags: SmallVec<[bool; 4]> =
            (0..out_ndim).map(|a| mapped[a].is_some()).collect();
        let mapped_src: SmallVec<[usize; 4]> = (0..out_ndim)
            .filter_map(|a| mapped[a].as_ref().map(|(d, _)| *d))
            .collect();
        Ok(self.emit_gather(
            &arg0,
            fixed_desc,
            &mapped_src,
            mapped_flags,
            axis_segs,
            &bx.shape,
            &bx.lo,
        ))
    }

    /// `LoadElem` of the element `fixed` (0-based, per source dim) names.
    fn emit_load_elem(&mut self, src: &LV, fixed: &[(usize, i64)]) -> LV {
        let mut idx: SmallVec<[usize; 4]> = SmallVec::from_elem(0usize, fixed.len());
        for &(d, i0) in fixed {
            idx[d] = i0 as usize;
        }
        let sec = self.placement(self.lv_cadence(src));
        let out = self.new_slot(&[], &[], true, sec);
        let instr = Instr::LoadElem {
            src: self.src_of(src),
            idx,
            out,
        };
        self.emit(instr, sec);
        LV::Scalar(out)
    }

    /// Emit one [`Instr::Gather`] of `src` into the box `shape`@`origin`.
    /// `mapped_src[j]` is the source dim the `j`-th mapped output axis reads;
    /// the reduction schedule — fixed axes descending, then the permutation of
    /// the mapped source axes into output order — is `eval_vec_index`'s.
    #[allow(clippy::too_many_arguments)]
    fn emit_gather(
        &mut self,
        src: &LV,
        mut fixed_desc: SmallVec<[(usize, usize); 4]>,
        mapped_src: &[usize],
        mapped: SmallVec<[bool; 4]>,
        segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]>,
        shape: &[usize],
        origin: &[i64],
    ) -> LV {
        let (src_shape, src_origin) = self.lv_box(src).expect("gather source is an array");
        fixed_desc.sort_by_key(|x| std::cmp::Reverse(x.0));
        let mut sorted: SmallVec<[usize; 4]> = mapped_src.iter().copied().collect();
        sorted.sort_unstable();
        let perm: SmallVec<[usize; 4]> = mapped_src
            .iter()
            .map(|d| {
                sorted
                    .iter()
                    .position(|s| s == d)
                    .expect("mapped source axis is in mapped_src")
            })
            .collect();
        let plan_ix = self.plans.len() as u32;
        self.plans.push(GatherPlan {
            fixed_desc,
            perm,
            mapped,
            segs,
            shape: shape.iter().copied().collect(),
            origin: origin.iter().copied().collect(),
            src_shape,
            src_origin,
        });
        let sec = self.placement(self.lv_cadence(src));
        let out = self.new_slot(shape, origin, false, sec);
        let instr = Instr::Gather {
            src: self.src_of(src),
            plan: plan_ix,
            out,
        };
        self.emit(instr, sec);
        LV::Arr(out)
    }

    /// `index(x, i…)` where `x` has no axes. The oracle latches
    /// `E_TREEWALK_INDEX_ON_SCALAR` and reads `NaN`, without evaluating the
    /// subscripts — for certain only when `x` is a parameter or a numeric
    /// literal, which it evaluates to a bare scalar. (A 0-D state or observed
    /// is served as a 0-D array, which the oracle's gather reads differently.)
    fn index_on_scalar(
        &mut self,
        base: &Expr,
        v: &LV,
        subscripts: usize,
        bx: Option<&LBox>,
    ) -> LResult<LV> {
        let certain = match base {
            Expr::Number(_) | Expr::Integer(_) => true,
            Expr::Variable(_) => matches!(v, LV::Param(_)),
            Expr::Operator(_) => false,
        };
        if !certain {
            bail_tape!("index: base is a scalar but {subscripts} index args given");
        }
        let msg = crate::simulate_array::eval::index_on_scalar_message(base, subscripts);
        match bx {
            Some(b) => {
                let first: SmallVec<[i64; 4]> = SmallVec::from_elem(0, b.shape.len());
                self.note_fault(Some((b, &first)), msg)?;
            }
            None => self.note_fault(None, msg)?,
        }
        Ok(LV::Lit(f64::NAN))
    }

    /// A gather on a CONST array (CONFORMANCE_SPEC §5.5.5), which never reads
    /// the state gather's zero ghost. Each source dim resolves an out-of-range
    /// subscript by the factor's declared policy, at build time: `periodic`
    /// wraps (more copy segments), `clamp` edge-extends (the edge element
    /// broadcast over the out-of-range run), and no policy is the oracle's
    /// fail-closed fault — `NaN` at those cells and one
    /// `E_TREEWALK_CONSTARRAY_OOB` for the first of them. The result is the
    /// plain gather when every read is in range, else an [`Instr::Assemble`]
    /// of per-run sub-gathers over a `NaN` fill: at most three runs per axis,
    /// so its size does not depend on the box.
    #[allow(clippy::too_many_arguments)]
    fn lower_const_gather(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
        src: LV,
        src_shape: &[usize],
        src_origin: &[i64],
        mapped: &[Option<(usize, AxisIndex)>],
        fixed_raw: &[(usize, i64)],
    ) -> LResult<LV> {
        if src_origin.iter().any(|&o| o != 1) {
            // A const array is a literal or a materialized observed, both
            // served at origin 1; the policy arithmetic below assumes it.
            bail_tape!("index: const-array gather on a source not at origin 1");
        }
        let name = match &node.args[0] {
            Expr::Variable(v) => v.as_str(),
            _ => INLINE_CONST_NAME,
        };
        let policy = |d: usize| -> BoundaryKind {
            if src_shape[d] == 0 {
                // `index_into`: an empty dimension is the error whatever the
                // policy.
                BoundaryKind::Error
            } else {
                self.const_arrays.boundary(name, d)
            }
        };
        // Fixed source dims, resolved (0-based), or `None` out of range.
        let mut fixed: SmallVec<[(usize, Option<usize>); 4]> = SmallVec::new();
        for &(d, raw) in fixed_raw {
            fixed.push((d, resolve_const_index(policy(d), raw, src_shape[d] as i64)));
        }
        let out_ndim = bx.shape.len();
        // Per output axis: its runs `(start, len, run)`, ascending, tiling it.
        let mut runs: SmallVec<[SmallVec<[(usize, usize, ConstRun); 3]>; 4]> = SmallVec::new();
        for a in 0..out_ndim {
            let n_a = bx.shape[a];
            let mut rs: SmallVec<[(usize, usize, ConstRun); 3]> = SmallVec::new();
            match &mapped[a] {
                None => rs.push((0, n_a, ConstRun::Bcast)),
                Some((d, AxisIndex::Wrap { k, period })) => {
                    let segs = full_roll_segs(1, src_shape[*d] as i64, bx.lo[a], n_a, *k, *period)?;
                    rs.push((0, n_a, ConstRun::Copy(segs)));
                }
                Some((d, AxisIndex::Affine(k))) => {
                    let n_d = src_shape[*d] as i64;
                    // The 1-based subscript at position `p` is `base + p`.
                    let base = bx.lo[a] + *k;
                    let na = n_a as i64;
                    let below = (1 - base).clamp(0, na) as usize;
                    let above = (n_d + 1 - base).clamp(0, na) as usize;
                    match policy(*d) {
                        BoundaryKind::Periodic if n_d > 1 => {
                            let mut segs: SmallVec<[(usize, usize, usize); 2]> = SmallVec::new();
                            let mut p = 0i64;
                            while p < na {
                                let s = (base + p - 1).rem_euclid(n_d);
                                let len = (n_d - s).min(na - p);
                                segs.push((p as usize, len as usize, s as usize));
                                p += len;
                            }
                            rs.push((0, n_a, ConstRun::Copy(segs)));
                        }
                        // A period of one reads its one element everywhere.
                        BoundaryKind::Periodic => rs.push((0, n_a, ConstRun::Edge(0))),
                        kind => {
                            let (lo_run, hi_run) = match kind {
                                BoundaryKind::Clamp => {
                                    (ConstRun::Edge(0), ConstRun::Edge(n_d as usize - 1))
                                }
                                _ => (ConstRun::Oob, ConstRun::Oob),
                            };
                            if below > 0 {
                                rs.push((0, below, lo_run));
                            }
                            if above > below {
                                let mut segs = SmallVec::new();
                                segs.push((0, above - below, (base + below as i64 - 1) as usize));
                                rs.push((below, above - below, ConstRun::Copy(segs)));
                            }
                            if n_a > above.max(below) {
                                let from = above.max(below);
                                rs.push((from, n_a - from, hi_run));
                            }
                        }
                    }
                }
            }
            runs.push(rs);
        }

        let fixed_oob = fixed.iter().any(|(_, r)| r.is_none());
        let any_oob = fixed_oob
            || runs
                .iter()
                .any(|rs| rs.iter().any(|(_, _, r)| matches!(r, ConstRun::Oob)));
        if any_oob {
            let msg =
                self.const_oob_first(bx, name, src_shape, mapped, fixed_raw, fixed_oob, &runs);
            let cell = msg.0;
            self.note_fault(Some((bx, &cell)), msg.1)?;
        }

        let n_mapped = mapped.iter().filter(|m| m.is_some()).count();
        if n_mapped == 0 {
            if fixed_oob {
                return Ok(LV::Lit(f64::NAN));
            }
            let at: SmallVec<[(usize, i64); 4]> = fixed
                .iter()
                .map(|&(d, r)| (d, r.expect("resolved") as i64))
                .collect();
            return Ok(self.emit_load_elem(&src, &at));
        }
        if fixed_oob {
            return Ok(self.emit_fill(&LV::Lit(f64::NAN), &bx.shape, &bx.lo, Cadence::Const));
        }

        // One sub-gather per combination of in-range runs.
        let mut parts: Vec<(LV, DimU, DimU)> = Vec::new();
        let mut pick: SmallVec<[usize; 4]> = SmallVec::from_elem(0, out_ndim);
        'combos: loop {
            let chosen: SmallVec<[&(usize, usize, ConstRun); 4]> =
                (0..out_ndim).map(|a| &runs[a][pick[a]]).collect();
            if !chosen.iter().any(|(_, _, r)| matches!(r, ConstRun::Oob)) {
                let mut fixed_desc: SmallVec<[(usize, usize); 4]> = fixed
                    .iter()
                    .map(|&(d, r)| (d, r.expect("resolved")))
                    .collect();
                let mut mapped_src: SmallVec<[usize; 4]> = SmallVec::new();
                let mut flags: SmallVec<[bool; 4]> = SmallVec::new();
                let mut segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = SmallVec::new();
                let mut sub_lo = DimI::new();
                let mut sub_shape = DimU::new();
                let mut dest = DimU::new();
                for (a, (start, len, run)) in chosen.iter().enumerate() {
                    sub_lo.push(bx.lo[a] + *start as i64);
                    sub_shape.push(*len);
                    dest.push(*start);
                    match run {
                        ConstRun::Copy(s) => {
                            let d = mapped[a].as_ref().expect("a copy run reads a source dim").0;
                            mapped_src.push(d);
                            flags.push(true);
                            // Segment offsets are relative to the run's start.
                            segs.push(s.clone());
                        }
                        ConstRun::Edge(e) => {
                            let d = mapped[a]
                                .as_ref()
                                .expect("an edge run reads a source dim")
                                .0;
                            fixed_desc.push((d, *e));
                            flags.push(false);
                            let mut one = SmallVec::new();
                            one.push((0usize, *len, 0usize));
                            segs.push(one);
                        }
                        ConstRun::Bcast => {
                            flags.push(false);
                            let mut one = SmallVec::new();
                            one.push((0usize, *len, 0usize));
                            segs.push(one);
                        }
                        ConstRun::Oob => unreachable!("an out-of-range run is skipped"),
                    }
                }
                let v = self.emit_gather(
                    &src,
                    fixed_desc,
                    &mapped_src,
                    flags,
                    segs,
                    &sub_shape,
                    &sub_lo,
                );
                parts.push((v, dest, sub_shape));
            }
            let mut a = out_ndim;
            loop {
                if a == 0 {
                    break 'combos;
                }
                a -= 1;
                pick[a] += 1;
                if pick[a] < runs[a].len() {
                    break;
                }
                pick[a] = 0;
            }
        }
        if !any_oob && parts.len() == 1 {
            return Ok(parts.pop().expect("one part").0);
        }
        if parts.is_empty() {
            return Ok(self.emit_fill(&LV::Lit(f64::NAN), &bx.shape, &bx.lo, Cadence::Const));
        }
        let mut spec_parts: Vec<(Operand, u32)> = Vec::with_capacity(parts.len() + 1);
        if any_oob {
            let region = tape_index(self.regions.len(), "makearray regions")?;
            self.regions.push(RegionSpec {
                dest_lo: DimU::from_elem(0, out_ndim),
                shape: bx.shape.clone(),
            });
            spec_parts.push((Operand::Lit(f64::NAN), region));
        }
        let mut want = Cadence::Const;
        for (v, dest, shape) in &parts {
            want = want.max(self.lv_cadence(v));
            let region = tape_index(self.regions.len(), "makearray regions")?;
            self.regions.push(RegionSpec {
                dest_lo: dest.clone(),
                shape: shape.clone(),
            });
            spec_parts.push((self.op_of(v), region));
        }
        let table = tape_index(self.assemblies.len(), "makearray assemblies")?;
        self.assemblies.push(AssembleSpec { parts: spec_parts });
        let sec = self.placement(want);
        let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
        self.emit(Instr::Assemble { table, out }, sec);
        Ok(LV::Arr(out))
    }

    // -- geometry -------------------------------------------------------------

    /// `polygon_intersection_area` (esm-spec §4.2): one [`Instr::PolyArea`]
    /// over the box `bx`, or over a scalar slot when `bx` is `None` (the
    /// wholesale form, or a box neither ring varies over).
    ///
    /// Mirrors `eval_polygon_intersection_area` / `eval_clip_operands`: a
    /// required in-enum `manifold`, exactly two operands, each a `[V, 2]`
    /// ring, and the NaN sentinel wherever that contract fails in a way the
    /// box alone decides (the wrong arity, no manifold, an operand that is a
    /// scalar or not `[V, 2]`). What the tape takes as a ring is narrower than
    /// what the oracle evaluates — a partial `index(table, s…)` whose
    /// subscripts are affine in one output symbol or constant, or a whole
    /// array — and every other operand, and any ring position outside its
    /// table, is a refusal naming it rather than a guess at the oracle.
    fn lower_poly_area(&mut self, node: &Arc<ExpressionNode>, bx: Option<&LBox>) -> LResult<LV> {
        use crate::geometry::Manifold;
        if self.f32_document {
            bail_tape!("geometry: `polygon_intersection_area` in a Float32 document");
        }
        let [a_expr, b_expr] = node.args.as_slice() else {
            return Ok(LV::Lit(f64::NAN));
        };
        let Some(manifold) = node.manifold.as_deref().and_then(Manifold::from_flag) else {
            return Ok(LV::Lit(f64::NAN));
        };
        let Some((ta, ra)) = self.lower_ring_operand(a_expr, bx)? else {
            return Ok(LV::Lit(f64::NAN));
        };
        let Some((tb, rb)) = self.lower_ring_operand(b_expr, bx)? else {
            return Ok(LV::Lit(f64::NAN));
        };
        let (axes_a, axes_b) = (ra.axes(), rb.axes());
        // A box neither ring varies over holds one value: compute it once.
        let bx = bx.filter(|_| !axes_a.is_empty() || !axes_b.is_empty());
        let pairs = match (&axes_a[..], &axes_b[..]) {
            ([x], [y]) if manifold == Manifold::Planar && x != y => Some((*x, *y)),
            _ => None,
        };
        let (shape, lo) = match bx {
            Some(bx) => (bx.shape.clone(), bx.lo.clone()),
            None => (DimU::new(), DimI::new()),
        };
        let cad = self.lv_cadence(&ta).max(self.lv_cadence(&tb));
        let sec = self.placement(cad);
        let geom = self.geoms.len() as u32;
        self.geoms.push(GeomSpec {
            manifold,
            a: ra,
            b: rb,
            shape: shape.clone(),
            pairs,
        });
        let scalar = bx.is_none();
        let out = self.new_slot(&shape, &lo, scalar, sec);
        let instr = Instr::PolyArea {
            a: self.src_of(&ta),
            b: self.src_of(&tb),
            geom,
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    /// One ring operand of [`Self::lower_poly_area`]: the table it reads
    /// (the WHOLE array, as the oracle's `eval` of the base yields it) and how
    /// each leading table axis is addressed. `None` when the operand is, for
    /// every cell, not a `[V, 2]` array — a scalar, or a table whose ring is
    /// not two-column — which `eval_clip_operands` answers with NaN.
    fn lower_ring_operand(
        &mut self,
        e: &Expr,
        bx: Option<&LBox>,
    ) -> LResult<Option<(LV, RingRef)>> {
        let (base, subs): (&Expr, &[Expr]) = match e {
            Expr::Operator(n) if n.op == "index" => match n.args.split_first() {
                Some((base, subs)) => (base, subs),
                None => return Ok(None),
            },
            other => (other, &[]),
        };
        let table = self.lower_wholesale(base)?;
        let Some((tshape, torigin)) = self.lv_box(&table) else {
            if subs.is_empty() {
                return Ok(None);
            }
            // Subscripts on a 0-D value are the interpreter's fail-closed
            // fault, which only the oracle can raise.
            bail_tape!("geometry: ring operand subscripts a scalar");
        };
        if torigin.iter().any(|&o| o != 1) {
            bail_tape!("geometry: ring table is not origin-1");
        }
        if tshape.len() != subs.len() + 2 || tshape[tshape.len() - 1] != 2 {
            if subs.is_empty() {
                return Ok(None);
            }
            bail_tape!(
                "geometry: ring operand of box {:?} with {} subscripts is not a [V, 2] ring",
                &tshape[..],
                subs.len()
            );
        }
        let mut sel: SmallVec<[RingSel; 3]> = SmallVec::new();
        for (d, sub) in subs.iter().enumerate() {
            let extent = tshape[d] as i64;
            let s = match bx {
                Some(bx) => match classify_axis_role(sub, &bx.as_vecbox()) {
                    Some(AxisRole::Map {
                        out_axis,
                        ax: AxisIndex::Affine(k),
                    }) => {
                        // 0-based table position `p + off` at output position p.
                        let off = bx.lo[out_axis] + k - 1;
                        let last = off + bx.shape[out_axis] as i64 - 1;
                        if off < 0 || last >= extent {
                            bail_tape!(
                                "geometry: ring subscript {d} leaves its table (1..{extent})"
                            );
                        }
                        RingSel::Axis {
                            axis: out_axis as u8,
                            off,
                        }
                    }
                    Some(AxisRole::Const(i1)) => Self::ring_fixed(i1, extent, d)?,
                    _ => bail_tape!(
                        "geometry: ring subscript {d} is neither affine in one output symbol nor constant"
                    ),
                },
                None => match self.lower_wholesale(sub)? {
                    LV::Lit(f) => Self::ring_fixed(f.round() as i64, extent, d)?,
                    _ => bail_tape!("geometry: ring subscript {d} is not a literal"),
                },
            };
            sel.push(s);
        }
        Ok(Some((
            table,
            RingRef {
                src_shape: tshape,
                sel,
            },
        )))
    }

    /// `intersect_polygon` (RFC §8.1) evaluated wholesale: the closed overlap
    /// ring, `[n + 1, 2]`, with `n` data-dependent.
    ///
    /// A slot's box is fixed when the tape is built, and the length of a clip
    /// is known only once the clip has run, so the ring is computed HERE, at
    /// build, when both operands are compile-time constants (literal `const`
    /// data), by the interpreter's own `eval_intersect_polygon` steps: the
    /// kernel clip, then `close_ring`. The ring becomes an ordinary
    /// [`Instr::ConstArray`], and its distinct-vertex count is recorded under
    /// the node's `id` for a `kind: "derived"` range over it, which is what the
    /// interpreter's ring registry would answer. Where the interpreter's clip
    /// yields its NaN sentinel and registers nothing (an operand that is not a
    /// `[V, 2]` array, no manifold, a clip the kernel refuses), so does this,
    /// and the derived range is empty. Operands that are rings but not
    /// constants (a parameter, the state, an observed computed at run time)
    /// and an empty ring are refusals naming the reason.
    fn lower_intersect_polygon(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        use crate::geometry::Manifold;
        if self.f32_document {
            bail_tape!("geometry: `intersect_polygon` in a Float32 document");
        }
        let no_ring = |b: &mut Self| {
            if let Some(id) = &node.id {
                b.rings.push((id.clone(), 0));
            }
            Ok(LV::Lit(f64::NAN))
        };
        let [a_expr, b_expr] = node.args.as_slice() else {
            return no_ring(self);
        };
        let Some(manifold) = node.manifold.as_deref().and_then(Manifold::from_flag) else {
            return no_ring(self);
        };
        let mut rings: [Vec<(f64, f64)>; 2] = [Vec::new(), Vec::new()];
        for (k, e) in [a_expr, b_expr].into_iter().enumerate() {
            let Some((table, r)) = self.lower_ring_operand(e, None)? else {
                return no_ring(self);
            };
            let Some(data) = self.const_slot_data(&table) else {
                bail_tape!(
                    "geometry: `intersect_polygon` of a ring that is not a compile-time \
                     constant: its overlap has a data-dependent length, and a tape slot's \
                     box is fixed when the tape is built"
                );
            };
            let lead = r.sel.len();
            // Row-major strides of the literal, which is how it is stored.
            let mut st = vec![1usize; data.shape.len()];
            for d in (0..data.shape.len().saturating_sub(1)).rev() {
                st[d] = st[d + 1] * data.shape[d + 1];
            }
            let mut base = 0usize;
            for (d, s) in r.sel.iter().enumerate() {
                let RingSel::Fixed(i) = *s else {
                    unreachable!("a wholesale ring subscript is fixed");
                };
                base += st[d] * i;
            }
            rings[k] = (0..data.shape[lead])
                .map(|v| {
                    let p = base + st[lead] * v;
                    (data.values[p], data.values[p + st[lead + 1]])
                })
                .collect();
        }
        let ring = match crate::geometry::intersect_polygon(&rings[0], &rings[1], manifold) {
            Ok(ring) => super::super::eval::close_ring(&ring),
            Err(_) => return no_ring(self),
        };
        if ring.is_empty() {
            bail_tape!("geometry: `intersect_polygon` ring is empty (a disjoint clip)");
        }
        let arr = super::super::eval::lonlat_to_arrayd(&ring);
        if let Some(id) = &node.id {
            self.rings.push((id.clone(), ring.len() as i64 - 1));
        }
        self.emit_const_array(&arr)
    }

    /// The literal data behind an array LV the tape stores with an
    /// [`Instr::ConstArray`] in the CONST section, if that is what it is.
    fn const_slot_data(&self, lv: &LV) -> Option<&ConstArrayData> {
        let LV::Arr(slot) = lv else {
            return None;
        };
        self.streams[Cadence::Const as usize]
            .iter()
            .flat_map(|c| c.instrs.iter())
            .find_map(|(i, _)| match i {
                Instr::ConstArray { data, out } if out == slot => {
                    Some(&self.const_data[*data as usize])
                }
                _ => None,
            })
    }

    /// The distinct-vertex count of the build-time ring produced under `id`.
    fn ring_extent(&self, id: &str) -> Option<i64> {
        self.rings
            .iter()
            .rev()
            .find(|(r, _)| r == id)
            .map(|(_, n)| *n)
    }

    /// Whether a contracted dimension has one extent for every output cell: a
    /// static interval, or a derived range over an `intersect_polygon` ring
    /// evaluated at build ([`Self::ring_extent`]).
    fn dim_is_fixed(&self, d: &ContractDim) -> bool {
        match d {
            ContractDim::Static(..) => true,
            ContractDim::Derived { from_faq } => self.ring_extent(from_faq).is_some(),
            ContractDim::Ragged { .. } => false,
        }
    }

    /// A constant 1-based ring subscript as a fixed 0-based table position.
    fn ring_fixed(one_based: i64, extent: i64, d: usize) -> LResult<RingSel> {
        if one_based < 1 || one_based > extent {
            bail_tape!("geometry: ring subscript {d} leaves its table (1..{extent})");
        }
        Ok(RingSel::Fixed((one_based - 1) as usize))
    }

    /// The indexed-gather arm of [`Self::lower_index`]: source axis `data_d`
    /// is subscripted by a value (`u[nbr[i, k]]` on an unstructured mesh), so
    /// the read position is data, not a shift. One [`Instr::IndexGather`]
    /// over the box, whatever its size.
    ///
    /// The oracle's rule is `eval_index` → `index_into` with a state or
    /// observed base: the subscript is `round()`ed to an integer and a
    /// position outside the source reads the zero ghost. The other axes stay
    /// what the segment gather supports, in range for every cell (a shifted
    /// read that leaves the source, or a periodic wrap, is refused here rather
    /// than mixed with a data subscript). A const-array base never reaches
    /// here: its out-of-range rule is the factor's boundary policy, which
    /// needs the subscript values to decide.
    #[allow(clippy::too_many_arguments)]
    fn lower_index_gather(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
        base: &LV,
        data_d: usize,
        mapped: &[Option<(usize, AxisIndex)>],
        fixed: &[(usize, i64)],
        any_fixed_oob: bool,
    ) -> LResult<LV> {
        let (src_shape, src_origin) = self.lv_box(base).expect("an array base");
        if src_origin.iter().any(|&o| o != 1) {
            bail_tape!("index: data subscript into a base that is not origin-1");
        }
        if any_fixed_oob {
            bail_tape!("index: data subscript with an out-of-range fixed axis");
        }
        let mut axes: SmallVec<[GatherAxis; 4]> =
            SmallVec::from_elem(GatherAxis::Fixed(0), src_shape.len());
        axes[data_d] = GatherAxis::Data;
        for &(d, i0) in fixed {
            axes[d] = GatherAxis::Fixed(i0 as usize);
        }
        for (a, m) in mapped.iter().enumerate() {
            let Some((d, ax)) = m else { continue };
            let AxisIndex::Affine(k) = ax else {
                bail_tape!("index: data subscript with a periodic-wrap axis");
            };
            // 0-based source position `p + off` at output position p.
            let off = bx.lo[a] + k - src_origin[*d];
            let last = off + bx.shape[a] as i64 - 1;
            if off < 0 || last >= src_shape[*d] as i64 {
                bail_tape!("index: data subscript with a shifted axis that leaves the source");
            }
            axes[*d] = GatherAxis::Affine { axis: a as u8, off };
        }
        let sub = self.lower_expr(&node.args[1 + data_d], bx)?;
        if let Some((s, o)) = self.lv_box(&sub)
            && (s != bx.shape || o != bx.lo)
        {
            bail_tape!("index: data subscript box does not match the output box");
        }
        let cad = self.lv_cadence(base).max(self.lv_cadence(&sub));
        let sec = self.placement(cad);
        let spec = self.index_gathers.len() as u32;
        self.index_gathers.push(IndexGatherSpec {
            axes,
            src_shape,
            shape: bx.shape.clone(),
        });
        let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
        let instr = Instr::IndexGather {
            src: self.src_of(base),
            idx: self.op_of(&sub),
            spec,
            out,
        };
        self.emit(instr, sec);
        Ok(LV::Arr(out))
    }

    /// The first cell (0-based, in `bx`) at which an out-of-range const gather
    /// faults in the oracle's visiting order, and the message it latches
    /// there: `index_into` checks the source dims in order and reports the
    /// first one out of range with no policy.
    #[allow(clippy::too_many_arguments)]
    fn const_oob_first(
        &self,
        bx: &LBox,
        name: &str,
        src_shape: &[usize],
        mapped: &[Option<(usize, AxisIndex)>],
        fixed_raw: &[(usize, i64)],
        fixed_oob: bool,
        runs: &[SmallVec<[(usize, usize, ConstRun); 3]>],
    ) -> (SmallVec<[i64; 4]>, String) {
        let nd = bx.shape.len();
        // Every out-of-range cell set is a union of axis-aligned slabs, so its
        // first cell in any visiting order is one slab's corner: the origin
        // (a fixed dim out of range), or the first position of an
        // out-of-range run along one axis with every other axis at 0.
        let mut candidates: Vec<SmallVec<[i64; 4]>> = Vec::new();
        let origin: SmallVec<[i64; 4]> = SmallVec::from_elem(0, nd);
        if fixed_oob {
            candidates.push(origin.clone());
        }
        for (a, rs) in runs.iter().enumerate() {
            if let Some((start, _, _)) = rs.iter().find(|(_, _, r)| matches!(r, ConstRun::Oob)) {
                let mut c = origin.clone();
                c[a] = *start as i64;
                candidates.push(c);
            }
        }
        let visit_key = |c: &SmallVec<[i64; 4]>| -> SmallVec<[i64; 4]> {
            (0..nd).map(|k| c[bx.visit_axis(k)]).collect()
        };
        let cell = candidates
            .into_iter()
            .min_by_key(|c| visit_key(c))
            .expect("an out-of-range gather has an out-of-range cell");
        // The subscript of every source dim at that cell, in dim order.
        let mut raw_at: SmallVec<[i64; 4]> = SmallVec::from_elem(0, src_shape.len());
        for &(d, raw) in fixed_raw {
            raw_at[d] = raw;
        }
        for (a, m) in mapped.iter().enumerate() {
            if let Some((d, ax)) = m {
                raw_at[*d] = match ax {
                    AxisIndex::Affine(k) => bx.lo[a] + cell[a] + k,
                    // A full roll never leaves the axis.
                    AxisIndex::Wrap { .. } => 1,
                };
            }
        }
        for (d, &raw) in raw_at.iter().enumerate() {
            let n_d = src_shape[d] as i64;
            let policy = if n_d == 0 {
                BoundaryKind::Error
            } else {
                self.const_arrays.boundary(name, d)
            };
            if (raw < 1 || raw > n_d) && matches!(policy, BoundaryKind::Error) {
                return (cell, const_oob_message(name, raw, n_d, d));
            }
        }
        unreachable!("the first out-of-range cell has an out-of-range dim")
    }

    // -- makearray ------------------------------------------------------------

    fn lower_makearray(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        if bx.tuple != 0 {
            bail_tape!("makearray: inside a tuple-list contraction body");
        }
        let Some(regions) = node.regions.as_ref() else {
            bail_tape!("makearray: no `regions`");
        };
        let Some(values) = node.values.as_ref() else {
            bail_tape!("makearray: no `values`");
        };
        if regions.is_empty() || values.len() != regions.len() {
            bail_tape!("makearray: empty or mismatched regions/values");
        }
        let ndim = regions[0].len();
        if ndim != bx.shape.len() {
            bail_tape!("makearray: region rank != output box rank");
        }
        let mut lo_bb = DimI::from_elem(i64::MAX, ndim);
        let mut hi_bb = DimI::from_elem(i64::MIN, ndim);
        for region in regions.iter() {
            if region.len() != ndim {
                bail_tape!("makearray: ragged region rank");
            }
            for (d, r) in region.iter().enumerate() {
                let Some([r_lo, r_hi]) = crate::types::region_bounds(r) else {
                    bail_tape!("makearray: unfolded (symbolic) region bound");
                };
                lo_bb[d] = lo_bb[d].min(r_lo);
                hi_bb[d] = hi_bb[d].max(r_hi);
            }
        }
        let bb_shape: DimU = (0..ndim)
            .map(|d| (hi_bb[d] - lo_bb[d] + 1).max(0) as usize)
            .collect();
        if bb_shape.contains(&0) {
            bail_tape!("makearray: empty bounding box");
        }

        // Every region value first, then ONE instruction assembling them: a
        // makearray whose values are all literals is a constant array, built
        // here; any other is an `Instr::Assemble`.
        let mut parts: Vec<(LV, u32)> = Vec::with_capacity(regions.len());
        for (region, value_expr) in regions.iter().zip(values.iter()) {
            if region
                .iter()
                .any(|r| crate::types::region_bounds(r).is_none())
            {
                bail_tape!("makearray: unfolded (symbolic) region bound");
            }
            let r_lo: DimI = region.iter().map(|r| r[0].as_i64().unwrap_or(0)).collect();
            let r_shape: DimU = region
                .iter()
                .map(|r| {
                    let [lo, hi] = crate::types::region_bounds(r).unwrap_or([0, -1]);
                    (hi - lo + 1) as usize
                })
                .collect();
            // A region is its own box (and CSE scope): a ramp / shifted gather
            // means something different inside it.
            let rbx = LBox {
                syms: bx.syms,
                lo: r_lo.clone(),
                shape: r_shape.clone(),
                cnames: bx.cnames,
                cvals: bx.cvals.clone(),
                tuple: bx.tuple,
                visit: SmallVec::new(),
            };
            // The legal EMPTY spelling (`stop == start - 1`, §4.3.2) covers no
            // cell, but the oracle still evaluates its value, and an array
            // value that does not fit poisons the whole makearray with `NaN`.
            // Its instructions are dropped; a fault it raises is kept.
            if r_shape.contains(&0) {
                let txn = self.sub_txn();
                self.push_scope();
                let v = self.lower_expr(value_expr, &rbx);
                self.pop_scope();
                let v = v?;
                let fits = match self.lv_box(&v) {
                    None => true,
                    Some((s, _)) => s.is_empty() || region_value_axes(&s, &r_shape).is_some(),
                };
                let fault = (self.fault_first.take(), self.fault_seq);
                self.sub_rollback(txn);
                (self.fault_first, self.fault_seq) = fault;
                if !fits {
                    bail_tape!("makearray: an empty region's array value does not fit it");
                }
                continue;
            }
            self.push_scope();
            let v = self.lower_expr(value_expr, &rbx);
            self.pop_scope();
            let v = v?;
            // An array region value must fit the region, excluding its
            // singleton axes (esm-spec §4.3.2). It is placed by shape: the
            // oracle's arrays carry no origin. A lower-rank value — a face
            // region's aggregate over its one free axis — is broadcast over
            // the singleton axes it does not name.
            let v = match self.lv_box(&v) {
                None => v,
                Some((s, _)) => match region_value_axes(&s, &r_shape) {
                    Some(covered) if covered.iter().all(|&c| c) => v,
                    Some(covered) => {
                        let src_axes: SmallVec<[usize; 4]> = (0..s.len()).collect();
                        let segs = r_shape
                            .iter()
                            .map(|&n| {
                                let mut one = SmallVec::new();
                                one.push((0usize, n, 0usize));
                                one
                            })
                            .collect();
                        self.emit_gather(
                            &v,
                            SmallVec::new(),
                            &src_axes,
                            covered,
                            segs,
                            &r_shape,
                            &r_lo,
                        )
                    }
                    None => bail_tape!("makearray: region value box does not match the region"),
                },
            };
            let region_ix = tape_index(self.regions.len(), "makearray regions")?;
            self.regions.push(RegionSpec {
                dest_lo: (0..ndim).map(|d| (r_lo[d] - lo_bb[d]) as usize).collect(),
                shape: r_shape,
            });
            parts.push((v, region_ix));
        }

        if parts.iter().all(|(v, _)| matches!(v, LV::Lit(_))) {
            let mut values = ndarray::ArrayD::<f64>::zeros(ndarray::IxDyn(&bb_shape));
            for (v, region_ix) in &parts {
                let LV::Lit(x) = v else { unreachable!() };
                let spec = &self.regions[*region_ix as usize];
                let mut view = values.view_mut();
                for d in 0..ndim {
                    view.slice_axis_inplace(
                        ndarray::Axis(d),
                        ndarray::Slice::from(spec.dest_lo[d]..spec.dest_lo[d] + spec.shape[d]),
                    );
                }
                view.fill(*x);
            }
            let data = tape_index(self.const_data.len(), "array constants")?;
            self.const_data.push(ConstArrayData {
                shape: bb_shape.clone(),
                values: values.iter().copied().collect(),
            });
            let sec = self.placement(Cadence::Const);
            let out = self.new_slot(&bb_shape, &lo_bb, false, sec);
            self.emit(Instr::ConstArray { data, out }, sec);
            return Ok(LV::Arr(out));
        }

        let want = parts
            .iter()
            .map(|(v, _)| self.lv_cadence(v))
            .max()
            .unwrap_or(Cadence::Const);
        let sec = self.placement(want);
        let table = tape_index(self.assemblies.len(), "makearray assemblies")?;
        let spec = AssembleSpec {
            parts: parts.iter().map(|(v, r)| (self.op_of(v), *r)).collect(),
        };
        self.assemblies.push(spec);
        let out = self.new_slot(&bb_shape, &lo_bb, false, sec);
        self.emit(Instr::Assemble { table, out }, sec);
        Ok(LV::Arr(out))
    }

    // -- nested aggregate -----------------------------------------------------

    /// Mirror of `eval_vec_nested_aggregate` (same `faq_spec`, same
    /// binding-independence precondition — the SHARED
    /// [`nested_aggregate_capture`] predicate, so the two paths cannot drift;
    /// there is no `ctx.loop_binds` at build time, which is why only the box's
    /// own symbols and contraction names are offered to it).
    fn lower_nested_aggregate(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        let Some(spec) = faq_spec(node) else {
            bail_tape!("aggregate: node carries no `expr` body");
        };
        // A rank-0 aggregate NESTED in a box stays per-cell, mirroring
        // `eval_vec_nested_aggregate`'s own bail: the enclosing rule would
        // otherwise be taped under semantics the overlay does not implement.
        // (The WHOLESALE rank-0 case is different and IS lowered — see
        // [`Self::lower_scalar_reduction`] — because there the reference is
        // the per-cell oracle, which the fold order reproduces exactly.)
        if spec.ranges.is_empty() {
            bail_tape!("aggregate: rank-0 output (scalar reduction, nested in a box)");
        }
        if bx.tuple != 0 {
            bail_tape!("aggregate: nested inside a tuple-list contraction body");
        }
        if let Some(name) = nested_aggregate_capture(&spec, bx.syms.iter().chain(bx.cnames.iter()))
        {
            bail_tape!("aggregate: nested body depends on an enclosing bound index `{name}`");
        }
        // A join gate drives the contraction: the tuple-list form.
        if spec.has_drivable_overlap() {
            return self.lower_tuple_contraction(
                spec.idx_names,
                &spec.ranges,
                spec.body,
                &spec.contract_names,
                &spec.contract_dims,
                spec.reduce,
                spec.filter,
                spec.join,
            );
        }
        let level = self.enter_fault_level(Some(bx));
        let v = self.lower_faq(
            spec.idx_names,
            &spec.ranges,
            spec.body,
            &spec.contract_names,
            &spec.contract_dims,
            spec.reduce,
            spec.filter,
        );
        self.leave_fault_level(level);
        v
    }

    // -- faq (the try_eval_faq_vectorized mirror) ---------------------

    #[allow(clippy::too_many_arguments)]
    fn lower_faq(
        &mut self,
        idx_names: &[String],
        ranges: &[(i64, i64)],
        body: &Expr,
        contract_names: &[String],
        contract_dims: &[ContractDim],
        reduce: ReduceKind,
        filter: Option<&Expr>,
    ) -> LResult<LV> {
        let lo: DimI = ranges.iter().map(|(l, _)| *l).collect();
        let shape: DimU = ranges
            .iter()
            .map(|(l, h)| (h - l + 1).max(0) as usize)
            .collect();
        // An empty output box (a size-0 index set) has no cell to evaluate:
        // the oracle's result is the empty array, and nothing in the body or
        // filter runs.
        if shape.contains(&0) {
            return Ok(self.emit_zero_array(&shape, &lo));
        }
        self.push_scope();
        let v = if contract_names.is_empty() {
            let bx = LBox {
                syms: idx_names,
                lo: lo.clone(),
                shape: shape.clone(),
                cnames: &[],
                cvals: SmallVec::new(),
                tuple: 0,
                visit: SmallVec::new(),
            };
            let identity = LV::Lit(reduce.identity());
            let r = self
                .lower_filtered(body, filter, &bx, identity.clone())
                .map(|v| {
                    v.unwrap_or_else(|| self.emit_fill(&identity, &shape, &lo, Cadence::Const))
                });
            self.pop_scope();
            r?
        } else {
            let r = self.lower_contracted(
                idx_names,
                &lo,
                &shape,
                body,
                contract_names,
                contract_dims,
                reduce,
                filter,
            );
            self.pop_scope();
            r?
        };
        // Mirror of the top-level bare-View bail: the oracle scalarizes a bare
        // whole-array body, so the overlay refuses it — and so do we.
        if matches!(&v, LV::State(_) | LV::Obs { .. }) && self.lv_box(&v).is_some() {
            bail_tape!("faq: body reduced to a bare whole-array view (oracle scalarizes it)");
        }
        match self.lv_box(&v) {
            None => Ok(self.emit_fill(&v, &shape, &lo, Cadence::Const)),
            Some((s, o)) => {
                if s == shape && o == lo {
                    Ok(v)
                } else {
                    bail_tape!("faq: result box does not match the output box");
                }
            }
        }
    }

    /// A static contraction: the body over the output box EXTENDED by the
    /// contracted axes, folded away by one [`Instr::Reduce`] — one
    /// instruction whatever the window's length
    /// ([`Self::lower_contracted_box`]). A body that form cannot lower keeps
    /// the unrolled form ([`Self::lower_contracted_unrolled`]).
    #[allow(clippy::too_many_arguments)]
    fn lower_contracted(
        &mut self,
        idx_names: &[String],
        lo: &DimI,
        shape: &DimU,
        body: &Expr,
        contract_names: &[String],
        contract_dims: &[ContractDim],
        reduce: ReduceKind,
        filter: Option<&Expr>,
    ) -> LResult<LV> {
        let Some(combine_op) = reduce_combine_op(reduce) else {
            bail_tape!("contracted: boolean reduction (or/and) not vectorized");
        };
        let nc = contract_names.len();
        if nc == 0 || nc > MAX_CONTRACT {
            bail_tape!("contracted: contraction rank out of range ({nc})");
        }
        if contract_dims.iter().any(|d| !self.dim_is_fixed(d)) {
            // A ragged bound varies per output cell: the tuple-list form.
            let ranges: Vec<(i64, i64)> = lo
                .iter()
                .zip(shape)
                .map(|(&l, &n)| (l, l + n as i64 - 1))
                .collect();
            return self.lower_tuple_contraction(
                idx_names,
                &ranges,
                body,
                contract_names,
                contract_dims,
                reduce,
                filter,
                None,
            );
        }
        let mut clo = [0i64; MAX_CONTRACT];
        let mut chi = [0i64; MAX_CONTRACT];
        for (i, d) in contract_dims.iter().enumerate() {
            match d {
                ContractDim::Static(l, h) => {
                    clo[i] = *l;
                    chi[i] = *h;
                }
                ContractDim::Derived { from_faq } if self.ring_extent(from_faq).is_some() => {
                    clo[i] = 1;
                    chi[i] = self.ring_extent(from_faq).unwrap_or(0);
                }
                other => bail_tape!("contracted: non-static contraction dim ({other:?})"),
            }
        }
        let identity = reduce.identity();
        // An empty window contributes no terms — the result is the identity.
        if (0..nc).any(|i| clo[i] > chi[i]) {
            return Ok(self.emit_fill(&LV::Lit(identity), shape, lo, Cadence::Const));
        }
        let window = ContractWindow {
            names: contract_names,
            lo: &clo[..nc],
            hi: &chi[..nc],
        };
        let txn = self.sub_txn();
        match self.lower_contracted_box(
            idx_names, lo, shape, body, &window, combine_op, identity, filter,
        ) {
            Ok(v) => Ok(v),
            Err(_) => {
                self.sub_rollback(txn);
                self.lower_contracted_unrolled(
                    idx_names, lo, shape, body, &window, combine_op, identity, filter,
                )
            }
        }
    }

    /// The looped form of a static contraction. The term is lowered ONCE over
    /// the box `window × output` — the contracted names are its LEADING axes,
    /// in `contract_names` order — and one [`Instr::Reduce`] folds those axes
    /// away. `Reduce` visits its source row-major, so every output cell folds
    /// its terms in the per-cell oracle's `CartesianTuples` order (the last
    /// contracted name fastest), each combine `acc ⊕ term` from the identity,
    /// exactly as `reduce_contraction` does. A `filter` masks an excluded
    /// tuple's term to the identity, as the unrolled form does.
    ///
    /// The promoted box holds one term per (tuple, output cell); a window
    /// whose box would exceed [`MAX_PROMOTED_ELEMS`] stays unrolled.
    #[allow(clippy::too_many_arguments)]
    fn lower_contracted_box(
        &mut self,
        idx_names: &[String],
        lo: &DimI,
        shape: &DimU,
        body: &Expr,
        window: &ContractWindow,
        combine_op: BinCode,
        identity: f64,
        filter: Option<&Expr>,
    ) -> LResult<LV> {
        let nc = window.names.len();
        if shape.is_empty() || shape.len() + nc > MAX_RANK {
            bail_tape!("contracted: promoted box rank out of range");
        }
        let mut ext_syms: Vec<String> = window.names.to_vec();
        ext_syms.extend(idx_names.iter().cloned());
        let mut ext_lo: DimI = window.lo.iter().copied().collect();
        ext_lo.extend(lo.iter().copied());
        let mut ext_shape: DimU = (0..nc)
            .map(|i| (window.hi[i] - window.lo[i] + 1) as usize)
            .collect();
        ext_shape.extend(shape.iter().copied());
        let elems = ext_shape
            .iter()
            .try_fold(1usize, |acc, &n| acc.checked_mul(n))
            .filter(|&n| n <= MAX_PROMOTED_ELEMS);
        if elems.is_none() {
            bail_tape!("contracted: promoted box too large");
        }
        self.push_scope();
        let bx = LBox {
            syms: &ext_syms,
            lo: ext_lo.clone(),
            shape: ext_shape.clone(),
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            // The oracle walks the output cells, and each cell's tuples.
            visit: (nc..ext_shape.len())
                .chain(0..nc)
                .map(|a| a as u8)
                .collect(),
        };
        let term = self
            .lower_filtered(body, filter, &bx, LV::Lit(identity))
            .map(|t| t.unwrap_or(LV::Lit(identity)));
        self.pop_scope();
        let term = term?;
        if matches!(&term, LV::State(_) | LV::Obs { .. }) && self.lv_box(&term).is_some() {
            bail_tape!("contracted: term reduced to a bare whole-array view");
        }
        let src = match self.lv_box(&term) {
            None => self.emit_fill(&term, &ext_shape, &ext_lo, Cadence::Const),
            Some((s, o)) if s == ext_shape && o == ext_lo => term,
            Some(_) => bail_tape!("contracted: term box does not match the promoted box"),
        };
        let sec = self.placement(self.lv_cadence(&src));
        let out = self.new_slot(shape, lo, false, sec);
        let instr = Instr::Reduce {
            op: combine_op,
            init: identity,
            src: self.src_of(&src),
            axes: (0..nc as u8).collect(),
            src_shape: ext_shape,
            out,
        };
        self.emit(instr, sec);
        Ok(LV::Arr(out))
    }

    /// The unrolled form of a static contraction: one term per contraction
    /// tuple, each over the output box with the tuple bound as constants,
    /// left-folded into an identity-filled accumulator. Tuples are visited
    /// in the per-cell oracle's `CartesianTuples` order (the last contracted
    /// name fastest), so the fold is the interpreter's. Its length grows with
    /// the window; it serves only bodies the looped form cannot lower (a
    /// read whose index mixes an output and a contracted symbol, such as a
    /// stencil window `u[i + k]`).
    #[allow(clippy::too_many_arguments)]
    fn lower_contracted_unrolled(
        &mut self,
        idx_names: &[String],
        lo: &DimI,
        shape: &DimU,
        body: &Expr,
        window: &ContractWindow,
        combine_op: BinCode,
        identity: f64,
        filter: Option<&Expr>,
    ) -> LResult<LV> {
        let nc = window.names.len();
        let contract_names = window.names;
        let (clo, chi) = (window.lo, window.hi);
        // Accumulator: identity-filled buffer over the output box.
        let mut acc = self.emit_fill(&LV::Lit(identity), shape, lo, Cadence::Const);

        let mut cvals = [0i64; MAX_CONTRACT];
        cvals[..nc].copy_from_slice(clo);
        loop {
            // Each contraction tuple is a DISTINCT box (and CSE scope).
            self.push_scope();
            let bx = LBox {
                syms: idx_names,
                lo: lo.clone(),
                shape: shape.clone(),
                cnames: contract_names,
                cvals: SmallVec::from_slice(&cvals[..nc]),
                tuple: 0,
                visit: SmallVec::new(),
            };
            let term = self
                .lower_filtered(body, filter, &bx, LV::Lit(identity))
                .map(|t| {
                    t.unwrap_or_else(|| {
                        self.emit_fill(&LV::Lit(identity), shape, lo, Cadence::Const)
                    })
                });
            self.pop_scope();
            let term = term?;
            acc = self.emit_bin(combine_op, acc, term)?;

            // Odometer over the window, the LAST contracted name fastest —
            // the per-cell oracle's `CartesianTuples` order.
            let mut d = nc;
            let mut done = true;
            while d > 0 {
                d -= 1;
                cvals[d] += 1;
                if cvals[d] <= chi[d] {
                    done = false;
                    break;
                }
                cvals[d] = clo[d];
            }
            if done {
                break;
            }
        }
        Ok(acc)
    }

    // -- wholesale-body lowering (the per-cell `eval` mirror) -----------------
    //
    // A `Scalar` rule's body — a declared observed's whole expression, or a
    // 0-d state's RHS — is evaluated by the per-cell oracle's `eval`
    // WHOLESALE: a variable reference resolves to the whole array, elementwise
    // arithmetic broadcasts over it, and a top-level `faq`/`makearray`
    // materializes its own box (trying the SAME vectorized overlay this pass
    // compiles — `eval_faq` / `eval_makearray`). This mirror covers the
    // wholesale algebra where it agrees exactly with the tape's instruction
    // semantics:
    //
    //   * equal-shape (or scalar-broadcast) elementwise operands — `combine` /
    //     `broadcast_binary` reduce to the aligned Zip that `Instr::Bin`
    //     performs; a rank/shape mismatch (Julia trailing-pad broadcast) bails;
    //   * every wholesale array is origin-normalized to all-1s, matching how
    //     `lookup_variable` serves stored arrays (origin-blind).
    fn lower_wholesale(&mut self, e: &Expr) -> LResult<LV> {
        match e {
            Expr::Number(n) => Ok(LV::Lit(crate::precision::round(*n))),
            Expr::Integer(n) => Ok(LV::Lit(crate::precision::round(*n as f64))),
            Expr::Variable(name) => self.resolve_wholesale_var(name),
            Expr::Operator(node) => self.lower_wholesale_op(node),
        }
    }

    /// Mirror of `lookup_variable` (no loop binds on the compiled-rule path):
    /// `t`, state, observed, parameter, else bail (production would read
    /// forcing or the NaN sentinel — the fallback interpreter handles both).
    fn resolve_wholesale_var(&mut self, name: &str) -> LResult<LV> {
        if name == "t" {
            return Ok(LV::Time);
        }
        if let Some(&ix) = self.state_ix.get(name) {
            return Ok(LV::State(tape_index(ix, "state variables")?));
        }
        if let Some(ov) = self.obs_defined.get(name).cloned() {
            return match ov {
                ObsVal::Taped(lv) => Ok(lv),
                ObsVal::External {
                    shape: Some(shape),
                    tier,
                } => {
                    let ix = self.obs_read(name)?;
                    Ok(LV::Obs { ix, shape, tier })
                }
                ObsVal::External { shape: None, .. } => bail_tape!(
                    "variable: observed `{name}` has a statically-unknown shape (fallback producer)"
                ),
            };
        }
        if let Some(i) = self.param_names.iter().position(|p| p == name) {
            return Ok(LV::Param(tape_index(i, "parameters")?));
        }
        if let Some(lv) = self.forcing_read(name)? {
            return Ok(lv);
        }
        bail_tape!("wholesale: unresolved symbol (forcing/NaN sentinel?) `{name}`")
    }

    fn lower_wholesale_op(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        self.lower_wholesale_op_named(node.op.as_str(), node)
    }

    /// [`Self::lower_wholesale_op`] with the operator name given separately, so
    /// the `broadcast` arm can re-enter with its `fn` against the SAME node —
    /// the oracle's `eval_broadcast` → `eval_op_named` (esm-spec §4.3.4).
    fn lower_wholesale_op_named(&mut self, op: &str, node: &Arc<ExpressionNode>) -> LResult<LV> {
        match op {
            // n-ary arithmetic + logical connectives: `eval_arith` is a left
            // fold of `apply_binary` over scalars AND arrays (the all-scalar
            // `fold_scalar` and the `and`/`or` all/any forms agree with the
            // left fold at every legal arity), so a chained `Bin` reproduces
            // it bit for bit — for equal-shape operands.
            "+" | "-" | "*" | "/" | "^" | "pow" | "min" | "max" | "and" | "or" => {
                let Some((first, rest)) = node.args.split_first() else {
                    return Ok(LV::Lit(f64::NAN)); // fold_scalar's empty-arity sentinel
                };
                if op == "-" && rest.is_empty() {
                    let v = self.lower_wholesale(first)?;
                    return self.emit_neg(v);
                }
                let mut acc = self.lower_wholesale(first)?;
                for a in rest {
                    let v = self.lower_wholesale(a)?;
                    acc = self.emit_bin_wholesale(BinCode::of(op), acc, v)?;
                }
                Ok(acc)
            }
            "neg" => {
                if node.args.len() != 1 {
                    return Ok(LV::Lit(f64::NAN));
                }
                let v = self.lower_wholesale(&node.args[0])?;
                self.emit_neg(v)
            }
            "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil" | "sin"
            | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh" | "asinh"
            | "acosh" | "atanh" | "not" => {
                // `eval_unary` evaluates args[0] only; no args ⇒ NaN sentinel.
                let Some(first) = node.args.first() else {
                    return Ok(LV::Lit(f64::NAN));
                };
                let v = self.lower_wholesale(first)?;
                Ok(self.emit_un(UnCode::of(op), v))
            }
            "atan2" => {
                // `eval_binary`: first two args, NaN sentinel below arity 2.
                let ([a, b] | [a, b, ..]) = &node.args[..] else {
                    return Ok(LV::Lit(f64::NAN));
                };
                let av = self.lower_wholesale(a)?;
                let bv = self.lower_wholesale(b)?;
                self.emit_bin_wholesale(BinCode::Atan2, av, bv)
            }
            "==" | "!=" | "<" | "<=" | ">" | ">=" => {
                if node.args.len() != 2 {
                    return Ok(LV::Lit(f64::NAN));
                }
                let av = self.lower_wholesale(&node.args[0])?;
                let bv = self.lower_wholesale(&node.args[1])?;
                self.emit_bin_wholesale(BinCode::of(op), av, bv)
            }
            "ifelse" => {
                if node.args.len() != 3 {
                    return Ok(LV::Lit(f64::NAN));
                }
                let cond = self.lower_wholesale(&node.args[0])?;
                if let LV::Lit(c) = &cond {
                    let c = *c;
                    return if c != 0.0 {
                        self.lower_wholesale(&node.args[1])
                    } else {
                        self.lower_wholesale(&node.args[2])
                    };
                }
                match self.lv_box(&cond) {
                    None => {
                        self.lower_branchy_ifelse(cond, &node.args[1], &node.args[2], |s, e| {
                            s.lower_wholesale(e)
                        })
                    }
                    Some(_) => {
                        let a = self.lower_wholesale(&node.args[1])?;
                        let b = self.lower_wholesale(&node.args[2])?;
                        self.emit_select_wholesale(cond, a, b)
                    }
                }
            }
            // Unreachable: esm-spec §4.2's right-hand-side `D` is resolved to a
            // tendency by `flatten`'s phase 5b′, or refused with
            // `unlowered_operator` before this lowering runs. The literal `0.0`
            // this used to emit was the third of three evaluators agreeing on a
            // wrong number; `NaN` is the sentinel that cannot be mistaken for a
            // result.
            "D" => Ok(LV::Lit(f64::NAN)),
            "Pre" => match node.args.first() {
                None => Ok(LV::Lit(f64::NAN)),
                Some(a) => self.lower_wholesale(a),
            },
            "const" => match eval_const(node) {
                Value::Scalar(s) => Ok(LV::Lit(s)),
                // The wholesale `eval` serves an inline array literal as the
                // whole array, origin-blind — which is exactly a materialized
                // 1-origin box. `Instr::ConstArray` stores it once per solve.
                Value::Array(a) => self.emit_const_array(&a),
            },
            "true" => Ok(LV::Lit(1.0)),
            "false" => Ok(LV::Lit(0.0)),
            "broadcast" => {
                let Some(fn_name) = node.broadcast_fn.as_deref() else {
                    bail_tape!("wholesale: `broadcast` with no `fn`");
                };
                if !crate::op_registry::is_scalar_operator(fn_name) {
                    bail_tape!("wholesale: broadcast fn `{fn_name}` is not a scalar operator");
                }
                self.lower_wholesale_op_named(fn_name, node)
            }
            "fn" => self.lower_wholesale_closed_fn(node),
            crate::precision_infer::MARKER_OP => {
                let (arg, _precision) = self.marker_operand(node)?;
                self.lower_wholesale(arg)
            }
            "reshape" => self.lower_wholesale_reshape(node),
            "transpose" => self.lower_wholesale_transpose(node),
            "concat" => self.lower_wholesale_concat(node),
            "index" => self.lower_wholesale_index(node),
            "faq" => self.lower_wholesale_aggregate(node),
            "makearray" => self.lower_wholesale_makearray(node),
            "polygon_intersection_area" => self.lower_poly_area(node, None),
            "intersect_polygon" => self.lower_intersect_polygon(node),
            other => bail_tape!("wholesale: unsupported op `{other}`"),
        }
    }

    /// `combine` on the wholesale path: two arrays of different shapes
    /// broadcast first (`broadcast_binary` — esm-spec §4.3.4's positional
    /// rule for operands with no declared index sets: left-aligned, the
    /// lower rank padded with TRAILING singletons). Shapes that do not
    /// broadcast give the oracle's `NaN` array.
    fn emit_bin_wholesale(&mut self, code: BinCode, a: LV, b: LV) -> LResult<LV> {
        if let (Some((sa, _)), Some((sb, _))) = (self.lv_box(&a), self.lv_box(&b))
            && sa != sb
        {
            if sa.contains(&0) || sb.contains(&0) {
                bail_tape!("wholesale: broadcast of an empty array");
            }
            let target = broadcast_shape(&sa, &sb);
            if target.contains(&0) {
                // `broadcast_binary`'s NaN sentinel, over the target with the
                // clashing extent read as 1.
                let nan_shape: DimU = target.iter().map(|&d| d.max(1)).collect();
                let ones = DimI::from_elem(1, nan_shape.len());
                return Ok(self.emit_fill(&LV::Lit(f64::NAN), &nan_shape, &ones, Cadence::Const));
            }
            let a = self.broadcast_to(a, &target)?;
            let b = self.broadcast_to(b, &target)?;
            return self.emit_bin(code, a, b);
        }
        self.emit_bin(code, a, b)
    }

    /// `eval_ifelse` under an ARRAY condition: the condition and both arms
    /// broadcast to one target, then select element by element.
    fn emit_select_wholesale(&mut self, cond: LV, a: LV, b: LV) -> LResult<LV> {
        let mut target: SmallVec<[usize; 4]> = SmallVec::new();
        for v in [&cond, &a, &b] {
            if let Some((sh, _)) = self.lv_box(v) {
                target = broadcast_shape(&target, &sh).into();
            }
        }
        if target.contains(&0) {
            bail_tape!("wholesale: `ifelse` operands whose shapes do not broadcast");
        }
        let cond = self.broadcast_to(cond, &target)?;
        let a = self.broadcast_to(a, &target)?;
        let b = self.broadcast_to(b, &target)?;
        self.emit_select(cond, a, b)
    }

    /// The body of an observed that DECLARES `shape`, which the oracle
    /// materializes as `eval(body)` with a scalar filled over `shape`.
    ///
    /// Plain [`Self::lower_wholesale`] plus that fill — except that an
    /// `ifelse` under a runtime SCALAR condition returns ONE of its arms
    /// verbatim, scalar or array, so the fill belongs inside each arm: both
    /// arms then carry the declared box and join on one phi. (Filling after
    /// the join is not expressible: the phi needs one box on both arms.)
    fn lower_wholesale_shaped(&mut self, e: &Expr, shape: &[usize]) -> LResult<LV> {
        let ones = DimI::from_elem(1, shape.len());
        if let Expr::Operator(node) = e
            && node.op == "ifelse"
            && node.args.len() == 3
        {
            let cond = self.lower_wholesale(&node.args[0])?;
            if let LV::Lit(c) = cond {
                let taken = if c != 0.0 {
                    &node.args[1]
                } else {
                    &node.args[2]
                };
                return self.lower_wholesale_shaped(taken, shape);
            }
            if self.lv_box(&cond).is_none() {
                return self.lower_branchy_ifelse(cond, &node.args[1], &node.args[2], |s, e| {
                    s.lower_wholesale_shaped(e, shape)
                });
            }
            let a = self.lower_wholesale(&node.args[1])?;
            let b = self.lower_wholesale(&node.args[2])?;
            let v = self.emit_select_wholesale(cond, a, b)?;
            return Ok(v);
        }
        let v = self.lower_wholesale(e)?;
        Ok(if self.lv_box(&v).is_none() {
            self.emit_fill(&v, shape, &ones, Cadence::Const)
        } else {
            v
        })
    }

    /// `v` broadcast to the whole-array box `target` (origin all-1s) under
    /// the trailing-pad rule: a scalar stays a scalar (every instruction
    /// broadcasts it), an array of that shape stays as it is, and any other
    /// array is gathered — each of its axes of extent 1 held at its one
    /// element, each padded axis broadcast.
    fn broadcast_to(&mut self, v: LV, target: &[usize]) -> LResult<LV> {
        let Some((shape, _)) = self.lv_box(&v) else {
            return Ok(v);
        };
        if shape.as_slice() == target {
            return Ok(v);
        }
        if shape.len() > target.len() {
            bail_tape!("wholesale: broadcast to a lower rank");
        }
        let mut fixed_desc: SmallVec<[(usize, usize); 4]> = SmallVec::new();
        let mut mapped_src: SmallVec<[usize; 4]> = SmallVec::new();
        let mut flags: SmallVec<[bool; 4]> = SmallVec::new();
        let mut segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = SmallVec::new();
        for (a, &n) in target.iter().enumerate() {
            let mut one = SmallVec::new();
            one.push((0usize, n, 0usize));
            segs.push(one);
            match shape.get(a) {
                Some(&m) if m == n => {
                    mapped_src.push(a);
                    flags.push(true);
                }
                Some(&1) => {
                    fixed_desc.push((a, 0));
                    flags.push(false);
                }
                Some(_) => bail_tape!("wholesale: shapes that do not broadcast"),
                None => flags.push(false),
            }
        }
        let ones = DimI::from_elem(1, target.len());
        Ok(self.emit_gather(&v, fixed_desc, &mapped_src, flags, segs, target, &ones))
    }

    /// `eval_transpose`: the operand's axes permuted (`perm`, default the
    /// reversal) — one [`Instr::Gather`] with the permutation and no shift.
    fn lower_wholesale_transpose(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let Some(arg0) = node.args.first() else {
            return Ok(LV::Lit(f64::NAN));
        };
        let v = self.lower_wholesale(arg0)?;
        let Some((shape, _)) = self.lv_box(&v) else {
            return Ok(v);
        };
        let nd = shape.len();
        let perm: SmallVec<[usize; 4]> = match &node.perm {
            Some(p) => {
                let mut seen = SmallVec::<[bool; 4]>::from_elem(false, nd);
                let mut out = SmallVec::new();
                for &x in p {
                    let ok = x >= 0 && (x as usize) < nd && !seen[x as usize];
                    if !ok {
                        return Ok(LV::Lit(f64::NAN)); // `is_valid_permutation`
                    }
                    seen[x as usize] = true;
                    out.push(x as usize);
                }
                if out.len() != nd {
                    return Ok(LV::Lit(f64::NAN));
                }
                out
            }
            None => (0..nd).rev().collect(),
        };
        Ok(self.emit_permute(&v, &shape, &perm))
    }

    /// Output axis `j` of the result reads source axis `perm[j]`.
    fn emit_permute(&mut self, v: &LV, shape: &[usize], perm: &[usize]) -> LV {
        if perm.iter().enumerate().all(|(j, &p)| j == p) {
            return v.clone();
        }
        let out_shape: DimU = perm.iter().map(|&p| shape[p]).collect();
        let segs = out_shape
            .iter()
            .map(|&n| {
                let mut one = SmallVec::new();
                one.push((0usize, n, 0usize));
                one
            })
            .collect();
        let ones = DimI::from_elem(1, out_shape.len());
        let flags = SmallVec::from_elem(true, out_shape.len());
        self.emit_gather(v, SmallVec::new(), perm, flags, segs, &out_shape, &ones)
    }

    /// `eval_reshape`, which is COLUMN-major: flatten in column-major order,
    /// refill the new shape in column-major order. On row-major slots that is
    /// an axis reversal, a row-major [`Instr::Reshape`] to the reversed target,
    /// and an axis reversal back (a reversal of a rank-1 box is nothing).
    fn lower_wholesale_reshape(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let Some(arg0) = node.args.first() else {
            return Ok(LV::Lit(f64::NAN));
        };
        let v = self.lower_wholesale(arg0)?;
        let target_raw = node.shape.clone().unwrap_or_default();
        if target_raw.is_empty() || target_raw.iter().any(|&d| d < 1) {
            bail_tape!("wholesale: `reshape` to an empty or rank-0 shape");
        }
        let target: DimU = target_raw.iter().map(|&d| d as usize).collect();
        let n_target: usize = target.iter().product();
        let ones = DimI::from_elem(1, target.len());
        let Some((shape, _)) = self.lv_box(&v) else {
            // A scalar is one element.
            return Ok(if n_target == 1 {
                self.emit_fill(&v, &target, &ones, Cadence::Const)
            } else {
                LV::Lit(f64::NAN)
            });
        };
        if shape.iter().product::<usize>() != n_target {
            return Ok(LV::Lit(f64::NAN)); // the element count disagrees
        }
        if shape == target {
            return Ok(v);
        }
        let rev_src: SmallVec<[usize; 4]> = (0..shape.len()).rev().collect();
        let flipped = self.emit_permute(&v, &shape, &rev_src);
        let rev_target: DimU = target.iter().rev().copied().collect();
        let sec = self.placement(self.lv_cadence(&flipped));
        let out = self.new_slot(&rev_target, &ones, false, sec);
        let instr = Instr::Reshape {
            src: self.src_of(&flipped),
            out,
        };
        self.emit(instr, sec);
        let rev_out: SmallVec<[usize; 4]> = (0..target.len()).rev().collect();
        Ok(self.emit_permute(&LV::Arr(out), &rev_target, &rev_out))
    }

    /// `eval_concat`: the operands joined along `axis` (a scalar is a
    /// one-element array) — one [`Instr::Assemble`], each operand written
    /// over its slab of the result. Operands `ndarray::concatenate` would
    /// refuse give the oracle's `NaN`.
    fn lower_wholesale_concat(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let axis = node.axis.unwrap_or(0);
        let mut parts: Vec<(LV, DimU)> = Vec::with_capacity(node.args.len());
        for a in &node.args {
            let v = self.lower_wholesale(a)?;
            let shape = match self.lv_box(&v) {
                Some((sh, _)) => sh,
                None => DimU::from_elem(1, 1),
            };
            parts.push((v, shape));
        }
        let Some((_, first)) = parts.first() else {
            return Ok(LV::Lit(f64::NAN));
        };
        let nd = first.len();
        if axis < 0 || axis as usize >= nd {
            return Ok(LV::Lit(f64::NAN));
        }
        let ax = axis as usize;
        let mut out_shape = first.clone();
        out_shape[ax] = 0;
        for (_, sh) in &parts {
            let fits = sh.len() == nd && (0..nd).all(|d| d == ax || sh[d] == first[d]);
            if !fits {
                return Ok(LV::Lit(f64::NAN));
            }
            out_shape[ax] += sh[ax];
        }
        if out_shape.contains(&0) {
            bail_tape!("wholesale: `concat` into an empty array");
        }
        let mut spec_parts: Vec<(Operand, u32)> = Vec::with_capacity(parts.len());
        let mut want = Cadence::Const;
        let mut at = 0usize;
        for (v, sh) in &parts {
            if sh[ax] == 0 {
                continue;
            }
            let mut dest_lo = DimU::from_elem(0, nd);
            dest_lo[ax] = at;
            at += sh[ax];
            want = want.max(self.lv_cadence(v));
            let region = tape_index(self.regions.len(), "makearray regions")?;
            self.regions.push(RegionSpec {
                dest_lo,
                shape: sh.clone(),
            });
            spec_parts.push((self.op_of(v), region));
        }
        let table = tape_index(self.assemblies.len(), "makearray assemblies")?;
        self.assemblies.push(AssembleSpec { parts: spec_parts });
        let sec = self.placement(want);
        let ones = DimI::from_elem(1, nd);
        let out = self.new_slot(&out_shape, &ones, false, sec);
        self.emit(Instr::Assemble { table, out }, sec);
        Ok(LV::Arr(out))
    }

    /// `eval_index` mirror (wholesale): LITERAL 1-based indices into a known
    /// array (`index_into` semantics — out-of-bounds reads the Dirichlet
    /// ghost 0; a partial index yields a sub-array and bails).
    fn lower_wholesale_index(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let Some((base, idx_args)) = node.args.split_first() else {
            return Ok(LV::Lit(f64::NAN));
        };
        let const_base = self.const_arrays.is_const_base(base);
        let basev = self.lower_wholesale(base)?;
        let Some((shape, origin)) = self.lv_box(&basev) else {
            // `index(x)` with no subscript is the identity on a 0-D value.
            if idx_args.is_empty() {
                return Ok(basev);
            }
            // Subscripts on a 0-D value: the fail-closed
            // `E_TREEWALK_INDEX_ON_SCALAR`, where the oracle is certain to
            // raise it.
            return self.index_on_scalar(base, &basev, idx_args.len(), None);
        };
        if origin.iter().any(|&o| o != 1) {
            bail_tape!("wholesale: index base is not origin-1");
        }
        let mut raw: SmallVec<[i64; 4]> = SmallVec::new();
        for a in idx_args {
            match self.lower_wholesale(a)? {
                LV::Lit(f) => raw.push(f.round() as i64),
                _ => bail_tape!("wholesale: non-literal index argument"),
            }
        }
        if raw.len() > shape.len() {
            return Ok(LV::Lit(f64::NAN)); // `index_into`'s over-index arm
        }
        if raw.len() < shape.len() {
            bail_tape!("wholesale: partial index yields a sub-array");
        }
        let mut idx: SmallVec<[usize; 4]> = SmallVec::new();
        let mut in_bounds = true;
        for (d, &one_based) in raw.iter().enumerate() {
            let dim = shape[d] as i64;
            if const_base {
                // §5.5.5, as `index_into` resolves it: the declared policy of
                // each dim in turn, and the first one out of range with none
                // is the fault (the gather reads `NaN`).
                let name = match base {
                    Expr::Variable(v) => v.as_str(),
                    _ => INLINE_CONST_NAME,
                };
                let policy = if dim == 0 {
                    BoundaryKind::Error
                } else {
                    self.const_arrays.boundary(name, d)
                };
                match resolve_const_index(policy, one_based, dim) {
                    Some(i0) => idx.push(i0),
                    None => {
                        self.note_fault(None, const_oob_message(name, one_based, dim, d))?;
                        return Ok(LV::Lit(f64::NAN));
                    }
                }
                continue;
            }
            if one_based < 1 || one_based > dim {
                in_bounds = false;
            }
            idx.push((one_based - 1).max(0) as usize);
        }
        if !in_bounds {
            return Ok(LV::Lit(0.0));
        }
        let cad = self.lv_cadence(&basev);
        let sec = self.placement(cad);
        let out = self.new_slot(&[], &[], true, sec);
        let src = self.src_of(&basev);
        self.emit(Instr::LoadElem { src, idx, out }, sec);
        Ok(LV::Scalar(out))
    }

    /// `eval_faq` mirror (a standalone aggregate evaluated wholesale):
    /// prefix scans get the running-fold lowering, rank-0 reductions stay
    /// per-cell (fallback), everything else goes through the same overlay
    /// entry as the compiled rules.
    fn lower_wholesale_aggregate(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let level = self.enter_fault_level(None);
        let v = self.lower_wholesale_aggregate_in_level(node);
        self.leave_fault_level(level);
        v
    }

    fn lower_wholesale_aggregate_in_level(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let Some(spec) = faq_spec(node) else {
            return Ok(LV::Lit(f64::NAN)); // eval_faq's missing-body sentinel
        };
        let static_ranges = static_contract_ranges(&spec.contract_dims);
        if let Some(scan) = detect_prefix_scan(
            spec.idx_names,
            &spec.ranges,
            &spec.contract_names,
            static_ranges.as_deref(),
            spec.body,
            spec.filter,
        ) {
            let v = self.lower_prefix_scan(
                spec.idx_names,
                &spec.ranges,
                scan,
                &spec.contract_names[0],
                spec.body,
                spec.reduce,
            )?;
            return Ok(self.reorigin_to_one(v));
        }
        // A join gate drives the contraction (`eval_faq` resolves its gates
        // for everything but a prefix scan): the tuple-list form.
        if spec.has_drivable_overlap() {
            let v = self.lower_tuple_contraction(
                spec.idx_names,
                &spec.ranges,
                spec.body,
                &spec.contract_names,
                &spec.contract_dims,
                spec.reduce,
                spec.filter,
                spec.join,
            )?;
            return Ok(self.reorigin_to_one(v));
        }
        if spec.ranges.is_empty() {
            return self.lower_scalar_reduction(&spec);
        }
        let v = self.lower_faq(
            spec.idx_names,
            &spec.ranges,
            spec.body,
            &spec.contract_names,
            &spec.contract_dims,
            spec.reduce,
            spec.filter,
        )?;
        Ok(self.reorigin_to_one(v))
    }

    /// A rank-0 `faq` — every index contracted, no output axis — compiled as
    /// "promote the contracted indices to a box, then fold the box away".
    ///
    /// This is the one aggregate shape the whole-array overlay declines
    /// (`eval_faq` gates its fast path on `!shape.is_empty()`), so production
    /// evaluates it in the per-cell oracle's [`reduce_contraction`]: `acc =
    /// identity`, then one `acc = reduce.combine(acc, term)` per contraction
    /// tuple, enumerated by `CartesianTuples` — lexicographic over
    /// `contract_names`, LAST name fastest. [`Instr::Reduce`] folds its source
    /// box in row-major order, and the box built here carries the contracted
    /// names as axes in that same order, so the two fold the same terms in the
    /// same association.
    ///
    /// A `filter` is lowered as a SKIP: the oracle skips an excluded tuple
    /// (`continue`, not `acc ⊕ 0̄`), so an excluded term is replaced by a value
    /// `v` with `acc ⊕ v == acc`, bit for bit, for EVERY accumulator: `-0.0`
    /// for a sum (`+0.0` would turn a `-0.0` accumulator positive), and the
    /// identity for the others — `acc · 1` is exact, and a `max`/`min`
    /// accumulator is never `NaN` (the kernels ignore a `NaN` operand), so
    /// `max(acc, -∞)` is `acc`. The fold then combines the oracle's terms in
    /// the oracle's order and nothing else.
    ///
    /// A boolean reduction (`or`/`and`) stays per-cell: it has no binary
    /// kernel.
    fn lower_scalar_reduction(&mut self, spec: &ArrayOpSpec) -> LResult<LV> {
        let Some(combine_op) = reduce_combine_op(spec.reduce) else {
            bail_tape!("reduction: boolean reduction (or/and) has no combine kernel");
        };
        let identity = spec.reduce.identity();
        if spec.contract_names.is_empty() {
            // No axes at all: `reduce_contraction`'s pointwise arm evaluates
            // the body once and scalarizes it.
            let v = self.lower_wholesale(spec.body)?;
            return Ok(if self.lv_box(&v).is_some() {
                LV::Lit(f64::NAN)
            } else {
                v
            });
        }
        let mut lo: DimI = DimI::new();
        let mut shape: DimU = DimU::new();
        for d in &spec.contract_dims {
            match d {
                ContractDim::Static(l, h) => {
                    lo.push(*l);
                    shape.push((h - l + 1).max(0) as usize);
                }
                ContractDim::Derived { from_faq } if self.ring_extent(from_faq).is_some() => {
                    lo.push(1);
                    shape.push(self.ring_extent(from_faq).unwrap_or(0).max(0) as usize);
                }
                _ => {
                    return self.lower_tuple_contraction(
                        spec.idx_names,
                        &spec.ranges,
                        spec.body,
                        &spec.contract_names,
                        &spec.contract_dims,
                        spec.reduce,
                        spec.filter,
                        None,
                    );
                }
            }
        }
        // An empty window enumerates no tuples: the fold is the identity.
        if shape.contains(&0) {
            return Ok(LV::Lit(identity));
        }
        // The body over the contraction box: the contracted names ARE its
        // axis symbols, in `faq_spec`'s (sorted) order. The filter first: the
        // oracle tests it before the body at every tuple.
        self.push_scope();
        let bx = LBox {
            syms: &spec.contract_names,
            lo: lo.clone(),
            shape: shape.clone(),
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        let lowered = (|| -> LResult<Option<LV>> {
            let keep = match spec.filter {
                None => None,
                Some(f) => {
                    let fv = self.lower_expr(f, &bx)?;
                    match fv {
                        // No tuple is kept: the body never runs.
                        LV::Lit(0.0) => return Ok(None),
                        LV::Lit(_) => None,
                        LV::State(_) | LV::Obs { .. } if self.lv_box(&fv).is_some() => {
                            bail_tape!("reduction: filter reduced to a bare whole-array view")
                        }
                        fv => Some(fv),
                    }
                }
            };
            // A kept-only body is evaluated by the oracle at kept tuples alone.
            if keep.is_some() {
                self.lazy_depth += 1;
            }
            let v = self.lower_expr(spec.body, &bx);
            if keep.is_some() {
                self.lazy_depth -= 1;
            }
            let v = v?;
            // Same bail as `lower_faq`: the oracle scalarizes a bare
            // whole-array body (`eval(body).as_scalar()` ⇒ NaN), which this
            // box lowering does not reproduce.
            if matches!(&v, LV::State(_) | LV::Obs { .. }) && self.lv_box(&v).is_some() {
                bail_tape!("reduction: body reduced to a bare whole-array view");
            }
            Ok(Some(match keep {
                None => v,
                Some(fv) => {
                    let skip = match spec.reduce {
                        ReduceKind::Sum => -0.0,
                        other => other.identity(),
                    };
                    self.emit_select(fv, v, LV::Lit(skip))?
                }
            }))
        })();
        self.pop_scope();
        let Some(v) = lowered? else {
            return Ok(LV::Lit(identity));
        };
        // A body constant over the window still contributes one term PER
        // tuple, so broadcast it over the box and fold that.
        let src = match self.lv_box(&v) {
            None => self.emit_fill(&v, &shape, &lo, Cadence::Const),
            Some((s, o)) => {
                if s != shape || o != lo {
                    bail_tape!("reduction: body box does not match the contraction window");
                }
                v
            }
        };
        let LV::Arr(src_slot) = src else {
            unreachable!("the reduction source is an array slot");
        };
        let sec = self.placement(self.slots[src_slot as usize].cadence);
        let out = self.new_slot(&[], &[], true, sec);
        self.emit(
            Instr::Reduce {
                op: combine_op,
                init: identity,
                src: SrcRef::Slot(src_slot),
                axes: (0..shape.len() as u8).collect(),
                src_shape: shape,
                out,
            },
            sec,
        );
        Ok(LV::Scalar(out))
    }

    /// `eval_makearray` mirror (wholesale): the bounding-box assembly around
    /// region writes, with the same gates production applies before routing to
    /// the overlay (`shape` non-empty, no prefix-scan region value).
    fn lower_wholesale_makearray(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let regions: &[Vec<[crate::types::RegionBound; 2]>] =
            node.regions.as_deref().unwrap_or(&[]);
        let values: &[Expr] = node.values.as_deref().unwrap_or(&[]);
        if regions.is_empty() || values.len() != regions.len() {
            return Ok(LV::Lit(f64::NAN));
        }
        if crate::op_registry::check_makearray_regions(node).is_err() {
            return Ok(LV::Lit(f64::NAN));
        }
        let ndim = regions[0].len();
        let mut lo = DimI::from_elem(i64::MAX, ndim);
        let mut hi = DimI::from_elem(i64::MIN, ndim);
        for region in regions {
            for (d, r) in region.iter().enumerate() {
                let Some([r_lo, r_hi]) = crate::types::region_bounds(r) else {
                    return Ok(LV::Lit(f64::NAN));
                };
                lo[d] = lo[d].min(r_lo);
                hi[d] = hi[d].max(r_hi);
            }
        }
        let shape: DimU = (0..ndim)
            .map(|d| (hi[d] - lo[d] + 1).max(0) as usize)
            .collect();
        if shape.contains(&0) {
            bail_tape!("makearray: empty bounding-box axis (per-cell path)");
        }
        if values.iter().any(region_value_is_prefix_scan) {
            bail_tape!("makearray: prefix-scan region value (per-cell path)");
        }
        let bx = LBox {
            syms: &[],
            lo,
            shape,
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        let level = self.enter_fault_level(None);
        let v = self.lower_makearray(node, &bx);
        self.leave_fault_level(level);
        Ok(self.reorigin_to_one(v?))
    }

    /// A forward prefix scan (esm-spec §4.3.1): the term over the whole
    /// output box, then one [`Instr::Scan`] along the scanned axis — the
    /// vectorized analogue of `run_prefix_scan`, and one instruction whatever
    /// the scanned length.
    ///
    /// Bit-identical: `run_prefix_scan` evaluates the body at step `i` with
    /// both the scanned output symbol and the contracted symbol bound to `i`,
    /// and the body never reads the scanned output symbol (the detector
    /// rejects such bodies), so the term at step `i` is the body over a box
    /// whose scanned axis is named by the CONTRACTED symbol. The scan then
    /// folds each window ascending in the same association.
    ///
    /// A body whose whole-box lowering bails keeps the per-step form
    /// ([`Self::lower_prefix_scan_steps`]), which binds the step position as
    /// a constant.
    fn lower_prefix_scan(
        &mut self,
        idx_names: &[String],
        ranges: &[(i64, i64)],
        scan: PrefixScan,
        j_name: &str,
        body: &Expr,
        reduce: ReduceKind,
    ) -> LResult<LV> {
        let Some(combine_op) = reduce_combine_op(reduce) else {
            bail_tape!("scan: boolean reduction not compiled (per-cell path)");
        };
        let full_lo: DimI = ranges.iter().map(|(l, _)| *l).collect();
        let full_shape: DimU = ranges
            .iter()
            .map(|(l, h)| (h - l + 1).max(0) as usize)
            .collect();
        if full_shape.contains(&0) {
            // No cell to scan: the empty array.
            return Ok(self.emit_zero_array(&full_shape, &full_lo));
        }
        let txn = self.sub_txn();
        let mut syms: Vec<String> = idx_names.to_vec();
        syms[scan.axis] = j_name.to_string();
        self.push_scope();
        let bx = LBox {
            syms: &syms,
            lo: full_lo.clone(),
            shape: full_shape.clone(),
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        let term = self.lower_expr(body, &bx);
        self.pop_scope();
        let term = term.and_then(|v| {
            // The oracle scalarizes a bare whole-array body (NaN); see the
            // same bail in `lower_faq`.
            if matches!(&v, LV::State(_) | LV::Obs { .. }) && self.lv_box(&v).is_some() {
                bail_tape!("scan: body reduced to a bare whole-array view");
            }
            match self.lv_box(&v) {
                None => Ok(self.emit_fill(&v, &full_shape, &full_lo, Cadence::Const)),
                Some((s, o)) if s == full_shape && o == full_lo => Ok(v),
                Some(_) => bail_tape!("scan: term box does not match the output box"),
            }
        });
        let term = match term {
            Ok(t) => t,
            Err(_) => {
                self.sub_rollback(txn);
                return self.lower_prefix_scan_steps(
                    idx_names, ranges, scan, j_name, body, combine_op, reduce,
                );
            }
        };
        let axis = u8::try_from(scan.axis).map_err(|_| Bail {
            reason: "scan: axis index out of range".into(),
        })?;
        let sec = self.placement(self.lv_cadence(&term));
        let out = self.new_slot(&full_shape, &full_lo, false, sec);
        let instr = Instr::Scan {
            op: combine_op,
            init: reduce.identity(),
            src: self.src_of(&term),
            axis,
            inclusive: scan.inclusive,
            src_shape: full_shape,
            out,
        };
        self.emit(instr, sec);
        Ok(LV::Arr(out))
    }

    /// The per-step form of [`Self::lower_prefix_scan`]: one step box per
    /// scanned position with the step bound as a constant, each written into
    /// the result by a full-box region write. Its length grows with the
    /// scanned extent; it serves only bodies the whole-box form cannot lower.
    #[allow(clippy::too_many_arguments)]
    fn lower_prefix_scan_steps(
        &mut self,
        idx_names: &[String],
        ranges: &[(i64, i64)],
        scan: PrefixScan,
        j_name: &str,
        body: &Expr,
        combine_op: BinCode,
        reduce: ReduceKind,
    ) -> LResult<LV> {
        let full_lo: DimI = ranges.iter().map(|(l, _)| *l).collect();
        let full_shape: DimU = ranges
            .iter()
            .map(|(l, h)| (h - l + 1).max(0) as usize)
            .collect();
        let (slo, shi) = ranges[scan.axis];
        // Step box: the full box with the scanned axis collapsed to extent 1.
        // The body never references the scanned OUTPUT symbol (the detector
        // rejects such bodies), so the step box's position along that axis is
        // pure metadata; pinning it at the axis lo lets every step's operands
        // share one box (and the accumulator chain type-check).
        let mut step_shape = full_shape.clone();
        step_shape[scan.axis] = 1;
        // Result base: zero-filled full box; every plane is overwritten once.
        let sec0 = self.placement(Cadence::Const);
        let mut cur = self.new_slot(&full_shape, &full_lo, false, sec0);
        self.emit(
            Instr::Fill {
                v: Operand::Lit(0.0),
                out: cur,
            },
            sec0,
        );
        let mut cur_cad = sec0;
        // `acc = identity` before the sweep; the first combine is
        // `identity ⊕ term` (NOT elided — `0.0 + (-0.0)` is `0.0`).
        let identity = reduce.identity();
        let mut acc = self.emit_fill(&LV::Lit(identity), &step_shape, &full_lo, Cadence::Const);
        // Bind BOTH the scanned output symbol and the contracted symbol to the
        // step position, exactly as `run_prefix_scan`'s `term_at` does.
        let cnames: Vec<String> = vec![idx_names[scan.axis].clone(), j_name.to_string()];
        for i in slo..=shi {
            self.push_scope();
            let bx = LBox {
                syms: idx_names,
                lo: full_lo.clone(),
                shape: step_shape.clone(),
                cnames: &cnames,
                cvals: SmallVec::from_slice(&[i, i]),
                tuple: 0,
                visit: SmallVec::new(),
            };
            let term = self.lower_expr(body, &bx);
            self.pop_scope();
            let term = term?;
            if scan.inclusive {
                acc = self.emit_bin(combine_op, acc, term.clone())?;
            }
            // Write the current plane at scan position i (a direct region
            // write; shapes match by construction, so no box check needed).
            let LV::Arr(acc_slot) = &acc else {
                unreachable!("scan accumulator is always an array");
            };
            let acc_slot = *acc_slot;
            let region_ix = self.regions.len() as u32;
            let mut dest_lo: DimU = DimU::from_elem(0usize, full_shape.len());
            dest_lo[scan.axis] = (i - slo) as usize;
            self.regions.push(RegionSpec {
                dest_lo,
                shape: step_shape.clone(),
            });
            let want = cur_cad.max(self.lv_cadence(&acc));
            let sec = self.placement(want);
            let out = self.new_slot(&full_shape, &full_lo, false, sec);
            self.emit(
                Instr::Region {
                    base: cur,
                    src: Operand::Slot(acc_slot),
                    region: region_ix,
                    out,
                },
                sec,
            );
            cur = out;
            cur_cad = sec;
            if !scan.inclusive {
                acc = self.emit_bin(combine_op, acc, term)?;
            }
        }
        Ok(LV::Arr(cur))
    }

    /// Shared runtime-scalar-condition `ifelse` lowering (JmpIfZero + phi),
    /// parameterized over the branch-lowering recursion.
    fn lower_branchy_ifelse<F>(
        &mut self,
        cond: LV,
        t_expr: &Expr,
        f_expr: &Expr,
        mut low: F,
    ) -> LResult<LV>
    where
        F: FnMut(&mut Self, &Expr) -> LResult<LV>,
    {
        let mark = self.push_branch();
        let tv = match low(self, t_expr) {
            Ok(v) => v,
            Err(e) => {
                self.pop_branch(mark);
                return Err(e);
            }
        };
        let mut tbuf = self.pop_branch(mark);
        let mark = self.push_branch();
        let fv = match low(self, f_expr) {
            Ok(v) => v,
            Err(e) => {
                self.pop_branch(mark);
                return Err(e);
            }
        };
        let mut fbuf = self.pop_branch(mark);
        let tb = self.lv_box(&tv);
        let fb = self.lv_box(&fv);
        let (shape, origin, scalar) = match (&tb, &fb) {
            (None, None) => (DimU::new(), DimI::new(), true),
            (Some((s, o)), Some((s2, o2))) if s == s2 && o == o2 => (s.clone(), o.clone(), false),
            _ => bail_tape!("ifelse: branch value boxes differ under a runtime scalar condition"),
        };
        let phi = self.new_slot(&shape, &origin, scalar, self.home);
        let prec = crate::precision::active();
        tbuf.push((
            Instr::Copy {
                a: self.op_of(&tv),
                out: phi,
            },
            prec,
        ));
        fbuf.push((
            Instr::Copy {
                a: self.op_of(&fv),
                out: phi,
            },
            prec,
        ));
        let jmp = Instr::JmpIfZero {
            cond: self.op_of(&cond),
            n_true: tbuf.len() as u32,
            n_false: fbuf.len() as u32,
        };
        let sec = self.home;
        self.emit(jmp, sec);
        for (i, p) in tbuf.into_iter().chain(fbuf) {
            self.emit_tagged(i, p, sec);
        }
        // Each Copy into the join carried its branch's build-time value, the
        // false branch's last. Which branch runs is a runtime question, so
        // the join is build-time data only when the two agree bit for bit.
        let agree = match (&tv, &fv) {
            (LV::Arr(a), LV::Arr(b)) => match (self.known_values(*a), self.known_values(*b)) {
                (Some(x), Some(y)) => {
                    x.len() == y.len()
                        && x.iter()
                            .zip(y.iter())
                            .all(|(p, q)| p.to_bits() == q.to_bits())
                }
                _ => false,
            },
            _ => false,
        };
        if !agree {
            self.known.remove(&phi);
        }
        Ok(if scalar {
            LV::Scalar(phi)
        } else {
            LV::Arr(phi)
        })
    }

    /// Materialize an LV into a slot (for exports / dy writes of folded
    /// values).
    fn ensure_slot(&mut self, lv: &LV) -> SlotId {
        match lv {
            LV::Scalar(s) | LV::Arr(s) => *s,
            LV::Lit(_) | LV::Param(_) | LV::Time => {
                let sec = self.placement(self.lv_cadence(lv));
                let out = self.new_slot(&[], &[], true, sec);
                self.emit(
                    Instr::Fill {
                        v: self.op_of(lv),
                        out,
                    },
                    sec,
                );
                out
            }
            LV::State(_) | LV::Obs { .. } => {
                let (shape, origin, scalar) = match self.lv_box(lv) {
                    None => (DimU::new(), DimI::new(), true),
                    Some((s, o)) => (s, o, false),
                };
                let sec = self.placement(self.lv_cadence(lv));
                let out = self.new_slot(&shape, &origin, scalar, sec);
                self.emit(
                    Instr::Copy {
                        a: self.op_of(lv),
                        out,
                    },
                    sec,
                );
                out
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Rule-level driving, exports, liveness/coloring, report — in build().
// ---------------------------------------------------------------------------

/// Result of building the tape for one compiled model (the rules, tables and
/// const-array registry are read straight off `compiled`). Returns the
/// program and the `(scope, hoist)` value-numbering hit counts.
pub(super) fn build_tape_program(
    compiled: &ArrayCompiled,
    const_names: &HashSet<String>,
    seg_invariant_names: &HashSet<String>,
    forcing: &ForcingInputs<'_>,
    // Step 4: run the kernel-fusion post-pass with the given superop
    // configuration (`None` = the unfused program, bitwise-identical
    // results — the arm `build_tape_opts` gives the fused-vs-unfused tests).
    fuse: Option<super::fuse::SuperopCfg>,
) -> (TapeProgram, (usize, usize)) {
    let rhs_rules: &[RhsRule] = &compiled.rhs_rules;
    let observed_rules: &[AlgebraicRule] = &compiled.observed_rules;
    let var_shapes = &compiled.var_shapes;
    let param_names: &[String] = &compiled.param_names;
    let const_arrays: &ConstArrayScope = &compiled.const_scope;
    let observed_names: HashSet<String> = observed_rules
        .iter()
        .map(|r| observed_rule_var(r).clone())
        .collect();
    let mut obs_tier: FxHashMap<String, Cadence> = FxHashMap::default();
    for r in observed_rules {
        let name = observed_rule_var(r);
        let tier = if const_names.contains(name) {
            Cadence::Const
        } else if seg_invariant_names.contains(name) {
            Cadence::Segment
        } else {
            Cadence::Continuous
        };
        obs_tier.insert(name.clone(), tier);
    }

    let mut b = TapeBuilder::new(
        var_shapes,
        param_names,
        obs_tier,
        const_arrays,
        compiled.precision.is_f32(),
        forcing,
    );
    b.inline_params = Some(&compiled.inline_param_arrays);

    // ---- observed rules, in dependency order -------------------------------
    for (i, rule) in observed_rules.iter().enumerate() {
        let name = observed_rule_var(rule).clone();
        let tier = *b.obs_tier.get(&name).expect("tier classified");
        b.begin_rule(RuleInfo {
            name: name.clone(),
            kind: RuleKind::Observed(i),
            cadence: tier,
            status: RuleStatus::Taped,
        });
        let txn = b.txn();
        // The rule's own working precision, as `materialize_observeds_pass`
        // arms it: every instruction it emits is tagged with it.
        let _rule_precision = crate::precision::has_variable_overrides()
            .then(|| crate::precision::enter(crate::precision::of_variable(&name)));
        let lowered = b
            .lower_observed_rule(rule)
            .and_then(|v| b.flush_rule_fault().map(|()| v));
        match lowered {
            Ok(obs_val) => {
                b.obs_defined.insert(name, obs_val);
            }
            Err(bail) => {
                b.rollback(txn);
                let ord = b.cur_rule;
                b.emit(Instr::Fallback { rule: ord }, b.home);
                b.rules[ord as usize].status = RuleStatus::Fallback(bail.reason);
                let shape = b.fallback_observed_shape(rule);
                b.obs_defined.insert(name, ObsVal::External { shape, tier });
            }
        }
        b.end_rule();
    }

    // ---- RHS rules ---------------------------------------------------------
    for (i, rule) in rhs_rules.iter().enumerate() {
        // The state's NAME, not its slot index. A refusal has to name the
        // rule an author can find (esm-libraries-spec §2.5.10: "naming the
        // compiler, the rule — an equation or an observed,
        // component-qualified — and the reason"), and `D(slot 0)` names
        // nothing: the flat slot order is an implementation detail that
        // coupling reorders.
        let name = match rule {
            RhsRule::Scalar { slot, .. } | RhsRule::IndexedScalar { slot, .. } => {
                match super::super::layout::slot_name(&compiled.var_shapes, *slot) {
                    Some(var) => format!("D({var})"),
                    None => format!("D(slot {slot})"),
                }
            }
            RhsRule::ArrayLoop { var_name, .. } => format!("D({var_name})"),
        };
        b.begin_rule(RuleInfo {
            name,
            kind: RuleKind::Rhs(i),
            cadence: Cadence::Continuous,
            status: RuleStatus::Taped,
        });
        let txn = b.txn();
        match b.lower_rhs_rule(rule).and_then(|()| b.flush_rule_fault()) {
            Ok(()) => {}
            Err(bail) => {
                b.rollback(txn);
                let ord = b.cur_rule;
                b.emit(Instr::Fallback { rule: ord }, b.home);
                b.rules[ord as usize].status = RuleStatus::Fallback(bail.reason);
            }
        }
        b.end_rule();
    }

    // ---- exports -----------------------------------------------------------
    let exports = b.compute_exports(
        observed_rules,
        rhs_rules,
        &observed_names,
        compiled.tape_serves_passes(),
    );

    // ---- flatten + fusion + liveness + coloring ----------------------------
    let vn_hits = b.vn_hits();
    (b.finish(exports, fuse), vn_hits)
}

impl<'m> TapeBuilder<'m> {
    /// The statically-known runtime shape of a FALLBACK observed rule's
    /// published array (origin-1 convention), or `None` when it cannot be
    /// known without evaluating.
    ///
    /// This is what closes the shape cascade. A rule that reads an observed
    /// resolves it to [`LV::Obs`], and every array instruction needs that
    /// value's box at build time; before this existed, a `None` here made
    /// EVERY reader of a per-cell-produced observed bail too, so one
    /// unsupported producer took its whole downstream cone with it. The shapes
    /// come from the same places the interpreter's do — `var_shapes` for a
    /// state, the already-recorded shape for an earlier observed, the `faq`
    /// ranges / `makearray` bounding box / `const` literal for a materializing
    /// operator — so a claimed box is the box the interpreter will publish.
    /// Anything not derivable stays `None`, which is the old behaviour.
    fn fallback_observed_shape(&self, rule: &AlgebraicRule) -> Option<DimU> {
        match rule {
            // The per-cell (and vectorized) ArrayLoop paths both materialize
            // the padded `[1, hi]` box; so does the recurrence sweep over its
            // frame.
            AlgebraicRule::ArrayLoop { output_ranges, .. }
            | AlgebraicRule::Recurrence { output_ranges, .. } => Some(
                output_ranges
                    .iter()
                    .map(|(_, hi)| (*hi).max(0) as usize)
                    .collect(),
            ),
            // `materialize_observeds_pass` stores `eval(body)` verbatim, except
            // that a scalar on a variable with a declared shape fills that
            // shape; an undeclared scalar stays a 0-d array.
            AlgebraicRule::Scalar {
                body,
                declared_shape,
                ..
            } => match (self.wholesale_shape(body), declared_shape) {
                (Some(s), Some(d)) if s.is_empty() => Some(d.iter().copied().collect()),
                (s, _) => s,
            },
        }
    }

    /// Shape-only mirror of [`Self::lower_wholesale`]: what box would
    /// `eval(e)` produce, without lowering (or evaluating) anything? `None`
    /// = not statically derivable. `Some(empty)` = a scalar / 0-d value.
    ///
    /// Deliberately partial and deliberately conservative: every arm that
    /// cannot pin the box exactly returns `None`, because a WRONG box here is
    /// not a missed optimization — a reader would compile a kernel against a
    /// box the interpreter does not publish.
    fn wholesale_shape(&self, e: &Expr) -> Option<DimU> {
        match e {
            Expr::Number(_) | Expr::Integer(_) => Some(DimU::new()),
            Expr::Variable(name) => self.wholesale_var_shape(name),
            Expr::Operator(node) => self.wholesale_op_shape(node),
        }
    }

    fn wholesale_var_shape(&self, name: &str) -> Option<DimU> {
        if name == "t" {
            return Some(DimU::new());
        }
        if let Some(&ix) = self.state_ix.get(name) {
            return Some(self.state_vars[ix].shape.clone());
        }
        if let Some(ov) = self.obs_defined.get(name) {
            return match ov {
                ObsVal::Taped(lv) => Some(match self.lv_box(lv) {
                    None => DimU::new(),
                    Some((s, _)) => s,
                }),
                ObsVal::External { shape, .. } => shape.clone(),
            };
        }
        if self.param_names.iter().any(|p| p == name) {
            return Some(DimU::new());
        }
        // A forcing read compiles against the box `forcing_read` loads; any
        // other name is the NaN sentinel, whose shape nothing pins.
        self.forcing_shapes.get(name).cloned()
    }

    /// Broadcast two operand shapes the way `combine` does for the shapes the
    /// TAPE admits: equal boxes, or a scalar against a box. A rank/extent
    /// mismatch is ndarray's trailing-pad broadcast, which the tape does not
    /// lower and this pass does not predict.
    fn broadcast_shape(a: Option<DimU>, b: Option<DimU>) -> Option<DimU> {
        let (a, b) = (a?, b?);
        if a.is_empty() {
            Some(b)
        } else if b.is_empty() || a == b {
            Some(a)
        } else {
            None
        }
    }

    fn wholesale_op_shape(&self, node: &Arc<ExpressionNode>) -> Option<DimU> {
        self.wholesale_op_shape_named(node.op.as_str(), node)
    }

    /// [`Self::wholesale_op_shape`] with the operator name given separately,
    /// for the `broadcast` re-entry [`Self::lower_wholesale_op_named`] makes.
    fn wholesale_op_shape_named(&self, op: &str, node: &Arc<ExpressionNode>) -> Option<DimU> {
        match op {
            "broadcast" => {
                let fn_name = node.broadcast_fn.as_deref()?;
                if !crate::op_registry::is_scalar_operator(fn_name) {
                    return None;
                }
                self.wholesale_op_shape_named(fn_name, node)
            }
            "true" | "false" => Some(DimU::new()),
            "+" | "-" | "*" | "/" | "^" | "pow" | "min" | "max" | "and" | "or" | "atan2" | "=="
            | "!=" | "<" | "<=" | ">" | ">=" => {
                let mut acc = self.wholesale_shape(node.args.first()?)?;
                for a in &node.args[1..] {
                    acc = Self::broadcast_shape(Some(acc), self.wholesale_shape(a))?;
                }
                Some(acc)
            }
            "neg" | "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil"
            | "sin" | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh"
            | "asinh" | "acosh" | "atanh" | "not" | "Pre" => {
                self.wholesale_shape(node.args.first()?)
            }
            // Mirrors `eval_ifelse`: a scalar condition picks ONE branch at run
            // time, so the shape is pinned only when both branches agree; an
            // array condition selects element-wise over the broadcast of the
            // condition and both branches, so a scalar-branch `ifelse` over an
            // array test publishes the TEST's box.
            "ifelse" => {
                if node.args.len() != 3 {
                    return Some(DimU::new()); // the NaN sentinel
                }
                let c = self.wholesale_shape(&node.args[0])?;
                let t = self.wholesale_shape(&node.args[1])?;
                let f = self.wholesale_shape(&node.args[2])?;
                if c.is_empty() {
                    return (t == f).then_some(t);
                }
                Self::broadcast_shape(Self::broadcast_shape(Some(c), Some(t)), Some(f))
            }
            "D" => Some(DimU::new()), // the NaN sentinel
            // The fused geometry leaf is a scalar area (or the NaN sentinel).
            "polygon_intersection_area" => Some(DimU::new()),
            "const" => match eval_const(node) {
                Value::Scalar(_) => Some(DimU::new()),
                Value::Array(a) => Some(a.shape().iter().copied().collect()),
            },
            // `index_into` with a full index yields one element; a partial
            // index yields a sub-array whose extents this pass does not chase.
            "index" => {
                let (base, idx) = node.args.split_first()?;
                let bshape = self.wholesale_shape(base)?;
                if bshape.is_empty() {
                    return idx.is_empty().then(DimU::new);
                }
                (idx.len() >= bshape.len()).then(DimU::new)
            }
            // `eval_faq` materializes exactly its output box (rank-0 ⇒ a 0-d
            // array), whichever inner path it takes.
            "faq" => {
                let spec = faq_spec(node)?;
                Some(
                    spec.ranges
                        .iter()
                        .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                        .collect(),
                )
            }
            // `eval_makearray` assembles the regions' bounding box.
            "makearray" => {
                let regions = node.regions.as_ref()?;
                let first = regions.first()?;
                let ndim = first.len();
                if regions.iter().any(|r| r.len() != ndim) {
                    return None;
                }
                let mut lo = vec![i64::MAX; ndim];
                let mut hi = vec![i64::MIN; ndim];
                for region in regions {
                    for (d, r) in region.iter().enumerate() {
                        let [r_lo, r_hi] = crate::types::region_bounds(r)?;
                        lo[d] = lo[d].min(r_lo);
                        hi[d] = hi[d].max(r_hi);
                    }
                }
                Some(
                    (0..ndim)
                        .map(|d| (hi[d] - lo[d] + 1).max(0) as usize)
                        .collect(),
                )
            }
            _ => None,
        }
    }

    fn begin_rule(&mut self, info: RuleInfo) {
        self.cur_rule = self.rules.len() as u32;
        self.home = info.cadence;
        self.rules.push(info);
        self.rule_home_chunk.push(None);
        self.scope_frames.clear();
        self.branch_bufs.clear();
        self.hoist_journal.clear();
        self.fault_first = None;
        self.fault_seq = 0;
        self.fault_prefix.clear();
        self.lazy_depth = 0;
    }

    /// Emit the lowered rule's first fault (if any) as one [`Instr::Fault`],
    /// AHEAD of the rule's CONST-section instructions. It reads nothing, and
    /// the CONST section runs first, so it latches before anything else of
    /// this rule — which is where the oracle, walking the rule cell by cell,
    /// latches its first fault — and after every earlier rule's.
    fn flush_rule_fault(&mut self) -> LResult<()> {
        let Some((_, msg)) = self.fault_first.take() else {
            return Ok(());
        };
        let fault = tape_index(self.faults.len(), "faults")?;
        self.faults.push(msg);
        let instr = (Instr::Fault { fault }, crate::precision::active());
        let stream = &mut self.streams[Cadence::Const as usize];
        match stream.last_mut() {
            Some(c) if c.rule == self.cur_rule => c.instrs.insert(0, instr),
            _ => stream.push(Chunk {
                rule: self.cur_rule,
                instrs: vec![instr],
            }),
        }
        Ok(())
    }

    fn end_rule(&mut self) {
        // Record the rule's home-stream chunk (for export insertion).
        let stream = &self.streams[self.home as usize];
        if let Some((idx, c)) = stream.iter().enumerate().next_back() {
            if c.rule == self.cur_rule {
                self.rule_home_chunk[self.cur_rule as usize] = Some(idx);
            }
        }
        debug_assert!(self.scope_frames.is_empty());
        debug_assert!(self.branch_bufs.is_empty());
    }

    fn txn(&self) -> RuleTxn {
        RuleTxn {
            slots: self.slots.len(),
            plans: self.plans.len(),
            regions: self.regions.len(),
            assemblies: self.assemblies.len(),
            const_data: self.const_data.len(),
            interp_tables: self.interp_tables.len(),
            geoms: self.geoms.len(),
            index_gathers: self.index_gathers.len(),
            rings: self.rings.len(),
            gather_tables: self.gather_tables.len(),
            seg_tables: self.seg_tables.len(),
            faults: self.faults.len(),
            dy_writes: self.dy_writes.len(),
            stream_lens: [
                self.streams[0].len(),
                self.streams[1].len(),
                self.streams[2].len(),
            ],
            hoist_journal: self.hoist_journal.len(),
            forcing_journal: self.forcing_journal.len(),
        }
    }

    /// Roll back everything the current rule's failed lowering emitted.
    fn rollback(&mut self, txn: RuleTxn) {
        self.slots.truncate(txn.slots);
        self.plans.truncate(txn.plans);
        self.regions.truncate(txn.regions);
        self.assemblies.truncate(txn.assemblies);
        self.const_data.truncate(txn.const_data);
        self.interp_tables.truncate(txn.interp_tables);
        self.geoms.truncate(txn.geoms);
        self.index_gathers.truncate(txn.index_gathers);
        self.rings.truncate(txn.rings);
        self.gather_tables.truncate(txn.gather_tables);
        self.seg_tables.truncate(txn.seg_tables);
        let n_slots = self.slots.len() as SlotId;
        self.known.retain(|s, _| *s < n_slots);
        self.tuple_frames.clear();
        self.faults.truncate(txn.faults);
        self.dy_writes.truncate(txn.dy_writes);
        for s in 0..3 {
            let stream = &mut self.streams[s];
            stream.truncate(txn.stream_lens[s]);
            // The rule may also have APPENDED to a pre-existing chunk? It
            // cannot: chunks are keyed by rule ordinal and a fresh rule always
            // opens a fresh chunk (see `emit`).
        }
        while self.hoist_journal.len() > txn.hoist_journal {
            let key = self.hoist_journal.pop().expect("journal entry");
            self.hoist.remove(&key);
        }
        self.rollback_forcing_loads(txn.forcing_journal);
        self.scope_frames.clear();
        self.branch_bufs.clear();
        self.fault_first = None;
        self.fault_prefix.clear();
        self.lazy_depth = 0;
    }

    /// Forget the forcing loads recorded since `mark`: their instructions were
    /// just discarded.
    fn rollback_forcing_loads(&mut self, mark: usize) {
        while self.forcing_journal.len() > mark {
            let ix = self.forcing_journal.pop().expect("journal entry");
            self.forcing_loaded.remove(&ix);
        }
    }

    fn sub_txn(&self) -> SubTxn {
        let stream = |s: usize| {
            let st = &self.streams[s];
            (st.len(), st.last().map_or(0, |c| c.instrs.len()))
        };
        SubTxn {
            slots: self.slots.len(),
            plans: self.plans.len(),
            regions: self.regions.len(),
            assemblies: self.assemblies.len(),
            const_data: self.const_data.len(),
            interp_tables: self.interp_tables.len(),
            geoms: self.geoms.len(),
            index_gathers: self.index_gathers.len(),
            gather_tables: self.gather_tables.len(),
            seg_tables: self.seg_tables.len(),
            streams: [stream(0), stream(1), stream(2)],
            branch_len: self.branch_bufs.last().map(Vec::len),
            hoist_journal: self.hoist_journal.len(),
            forcing_journal: self.forcing_journal.len(),
            fault_first: self.fault_first.clone(),
            fault_seq: self.fault_seq,
        }
    }

    /// Undo everything emitted since `txn` was taken, within the current rule.
    fn sub_rollback(&mut self, txn: SubTxn) {
        self.slots.truncate(txn.slots);
        self.plans.truncate(txn.plans);
        self.regions.truncate(txn.regions);
        self.assemblies.truncate(txn.assemblies);
        self.const_data.truncate(txn.const_data);
        self.interp_tables.truncate(txn.interp_tables);
        self.geoms.truncate(txn.geoms);
        self.index_gathers.truncate(txn.index_gathers);
        self.gather_tables.truncate(txn.gather_tables);
        self.seg_tables.truncate(txn.seg_tables);
        let n_slots = self.slots.len() as SlotId;
        self.known.retain(|s, _| *s < n_slots);
        for (s, &(n_chunks, last_len)) in txn.streams.iter().enumerate() {
            let stream = &mut self.streams[s];
            stream.truncate(n_chunks);
            if n_chunks > 0 {
                stream[n_chunks - 1].instrs.truncate(last_len);
            }
        }
        if let (Some(buf), Some(n)) = (self.branch_bufs.last_mut(), txn.branch_len) {
            buf.truncate(n);
        }
        while self.hoist_journal.len() > txn.hoist_journal {
            let key = self.hoist_journal.pop().expect("journal entry");
            self.hoist.remove(&key);
        }
        self.rollback_forcing_loads(txn.forcing_journal);
        self.fault_first = txn.fault_first;
        self.fault_seq = txn.fault_seq;
    }

    /// Lower one observed rule; returns the recorded observed value.
    fn lower_observed_rule(&mut self, rule: &AlgebraicRule) -> LResult<ObsVal> {
        match rule {
            // CONFORMANCE_SPEC §5.19.2: a recurrence's cells are not
            // independent, so it may not be taped — the tape's scheduler
            // (fusion, liveness coloring, SIMD super-ops) is free to reorder
            // and batch, which is exactly what the construct forbids. Bail to
            // the interpreter's sequential sweep, which is the ONLY
            // implementation of this rule kind.
            AlgebraicRule::Recurrence { .. } => {
                bail_tape!(
                    "observed: causal self-reference (recurrence) — sequential sweep only \
                     (esm-spec §4.3.1.1, CONFORMANCE_SPEC §5.19.2)"
                )
            }
            AlgebraicRule::ArrayLoop {
                output_idx_names,
                output_ranges,
                body,
                ..
            } => {
                // Mirror of `materialize_observeds_pass`'s vectorized-path
                // guard: 1-origin ranges over a non-empty padded box.
                let padded_shape: Vec<usize> =
                    output_ranges.iter().map(|(_, hi)| *hi as usize).collect();
                if output_ranges.is_empty() {
                    bail_tape!("observed: rank-0 ArrayLoop");
                }
                if !output_ranges.iter().all(|(lo, _)| *lo == 1) {
                    bail_tape!("observed: non-unit-origin output ranges (per-cell path)");
                }
                if padded_shape.contains(&0) {
                    // No cell to evaluate: the empty array the oracle
                    // materializes.
                    let ones = DimI::from_elem(1, padded_shape.len());
                    return Ok(ObsVal::Taped(self.emit_zero_array(&padded_shape, &ones)));
                }
                let v = self.lower_faq(
                    output_idx_names,
                    output_ranges,
                    body,
                    &[],
                    &[],
                    ReduceKind::Sum,
                    None,
                )?;
                // Origin is all-1 by the guard, so no re-origin copy needed.
                Ok(ObsVal::Taped(v))
            }
            AlgebraicRule::Scalar {
                var,
                body,
                declared_shape,
            } => {
                // The whole-body `eval` mirror: covers scalar algebra, whole-
                // array elementwise algebra, top-level aggregates (incl. the
                // prefix-scan sweep) and makearrays. Readers see materialized
                // arrays at origin 1s. A scalar on a shaped variable fills its
                // declared box, as the interpreter does.
                let v = match (self.inline_param_literal(var, body), declared_shape) {
                    (Some(a), _) => self.emit_const_array(&a)?,
                    (None, Some(shape)) => self.lower_wholesale_shaped(body, shape)?,
                    (None, None) => self.lower_wholesale(body)?,
                };
                let v = match declared_shape {
                    Some(shape) if self.lv_box(&v).is_none() => {
                        let origin = DimI::from_elem(1, shape.len());
                        self.emit_fill(&v, shape, &origin, Cadence::Const)
                    }
                    _ => self.reorigin_to_one(v),
                };
                Ok(ObsVal::Taped(v))
            }
        }
    }

    /// The array a lowered shaped-parameter default (`var := const(...)`)
    /// evaluates to, built from its dense data: the value `json_to_value`
    /// reads back from the literal, rounded to the precision in force the
    /// same way. `None` for any other rule, and for data the literal does
    /// NOT read back as that array — a non-finite value (written as `null`)
    /// or an empty extent — which then takes the literal's own path.
    fn inline_param_literal(&self, var: &str, body: &Expr) -> Option<ndarray::ArrayD<f64>> {
        let Expr::Operator(node) = body else {
            return None;
        };
        if node.op != "const" {
            return None;
        }
        let (shape, values) = self.inline_params?.get(var)?;
        // The literal is the one written from this data: same outer extent.
        let outer = node.value.as_ref()?.as_array()?.len();
        if shape.first() != Some(&outer)
            || values.is_empty()
            || values.iter().any(|v| !v.is_finite())
        {
            return None;
        }
        let prec = crate::precision::active();
        let data: Vec<f64> = values.iter().map(|&v| prec.round(v)).collect();
        ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(shape), data).ok()
    }

    /// Copy an array LV into a slot whose origin is all-1s (the convention
    /// under which readers see a materialized observed). No-op when already.
    fn reorigin_to_one(&mut self, v: LV) -> LV {
        let Some((shape, origin)) = self.lv_box(&v) else {
            return v;
        };
        if origin.iter().all(|&o| o == 1) {
            return v;
        }
        let ones = DimI::from_elem(1, shape.len());
        let sec = self.placement(self.lv_cadence(&v));
        let out = self.new_slot(&shape, &ones, false, sec);
        self.emit(
            Instr::Copy {
                a: self.op_of(&v),
                out,
            },
            sec,
        );
        LV::Arr(out)
    }

    /// Lower one RHS rule, emitting its `DyWrite`.
    fn lower_rhs_rule(&mut self, rule: &RhsRule) -> LResult<()> {
        match rule {
            RhsRule::Scalar { slot, body } | RhsRule::IndexedScalar { slot, body } => {
                let v = self.lower_wholesale(body)?;
                // The oracle scalarizes: an array-valued body writes the NaN
                // sentinel (`eval(body).as_scalar().unwrap_or(NAN)`).
                let v = if self.lv_box(&v).is_some() {
                    LV::Lit(f64::NAN)
                } else {
                    v
                };
                let s = self.ensure_slot(&v);
                let w = self.dy_writes.len() as u32;
                self.dy_writes.push(DyWrite {
                    slot: s,
                    var: 0,
                    dest_lo: SmallVec::new(),
                    scalar_flat: Some(*slot),
                });
                self.emit(Instr::DyWrite { write: w }, Cadence::Continuous);
                Ok(())
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
                let vs = &self.var_shapes[var_name];
                let Some(shifts) = lhs_constant_shifts(lhs_idx_exprs, output_idx_names) else {
                    bail_tape!("rule: LHS is not a constant per-axis shift of the output indices");
                };
                let Some(dest_lo) = subblock_dest(vs, output_ranges, &shifts) else {
                    bail_tape!("rule: shifted output box does not fit the variable block");
                };
                let v = self.lower_faq(
                    output_idx_names,
                    output_ranges,
                    body,
                    contract_names,
                    contract_dims,
                    *reduce,
                    filter.as_deref(),
                )?;
                let s = self.ensure_slot(&v);
                let var_ix = tape_index(
                    *self.state_ix.get(var_name).expect("state var known"),
                    "state variables",
                )?;
                let w = self.dy_writes.len() as u32;
                self.dy_writes.push(DyWrite {
                    slot: s,
                    var: var_ix,
                    dest_lo,
                    scalar_flat: None,
                });
                self.emit(Instr::DyWrite { write: w }, Cadence::Continuous);
                Ok(())
            }
        }
    }

    /// Names to publish into the runtime observed map: everything a fallback
    /// rule reads, plus the samples/observed-trajectory dependency cone
    /// (mirroring `append_scalar_observed_trajectories`'s probe seeds).
    fn compute_exports(
        &mut self,
        observed_rules: &[AlgebraicRule],
        rhs_rules: &[RhsRule],
        observed_names: &HashSet<String>,
        // The STRICT compilers, `native` and `xla` (API_SPEC §5.8): export
        // EVERY observed, because under them the build-time hoist, the
        // per-segment seed, the inspection snapshot and the output-node pass
        // are all served from this program rather than from the whole-array
        // overlay, and each of them may read an observed the probe cone below
        // does not reach — a caller-requested array
        // observed, or a hoisted static field. A publish nothing reads costs
        // nothing anyway: `Export` only executes when a reader asked for it
        // (`TapeExec::exports_active`).
        export_all: bool,
    ) -> Vec<(String, SlotId)> {
        let mut needed: HashSet<String> = HashSet::new();
        if export_all {
            for r in observed_rules {
                needed.insert(observed_rule_var(r).clone());
            }
        }

        // (a) Direct observed reads of every fallback rule body: the
        // interpreter resolves them through the runtime observed map, so a
        // taped producer must publish there.
        for info in self.rules.clone() {
            if !matches!(info.status, RuleStatus::Fallback(_)) {
                continue;
            }
            let mut refs = HashSet::new();
            match info.kind {
                RuleKind::Observed(i) => {
                    collect_expr_var_refs(observed_rule_body(&observed_rules[i]), &mut refs)
                }
                RuleKind::Rhs(i) => match &rhs_rules[i] {
                    RhsRule::Scalar { body, .. } | RhsRule::IndexedScalar { body, .. } => {
                        collect_expr_var_refs(body, &mut refs)
                    }
                    RhsRule::ArrayLoop { body, filter, .. } => {
                        collect_expr_var_refs(body, &mut refs);
                        if let Some(f) = filter {
                            collect_expr_var_refs(f, &mut refs);
                        }
                    }
                },
            }
            for r in refs {
                if observed_names.contains(&r) {
                    needed.insert(r);
                }
            }
        }

        // (b) The samples pass' probe cone: potentially-scalar observeds and
        // their transitive dependencies (driver's `dependency_cone` seeds).
        let prune_valid = observed_rules
            .iter()
            .all(|r| !expr_blocks_output_pruning(observed_rule_body(r)));
        let seeds: HashSet<String> = observed_rules
            .iter()
            .filter(|r| !observed_rule_is_array_valued(r))
            .map(|r| observed_rule_var(r).clone())
            .collect();
        if !prune_valid {
            for r in observed_rules {
                needed.insert(observed_rule_var(r).clone());
            }
        } else {
            match dependency_cone(observed_rules, &seeds) {
                None => {
                    for r in observed_rules {
                        needed.insert(observed_rule_var(r).clone());
                    }
                }
                Some(cone) => {
                    for r in &cone {
                        needed.insert(observed_rule_var(r).clone());
                    }
                }
            }
        }

        // Emit Export instructions at each producing (taped) rule's tail.
        let mut exports: Vec<(String, SlotId)> = Vec::new();
        let mut sorted: Vec<String> = needed.into_iter().collect();
        sorted.sort();
        for name in sorted {
            let Some(ObsVal::Taped(lv)) = self.obs_defined.get(&name).cloned() else {
                continue; // fallback-produced: already in the map at run time
            };
            // Find the producing rule and append the Export to its home chunk.
            let Some(rule_ord) = self
                .rules
                .iter()
                .position(|r| matches!(r.kind, RuleKind::Observed(_)) && r.name == name)
            else {
                continue;
            };
            let home = self.rules[rule_ord].cadence;
            self.cur_rule = rule_ord as u32;
            self.home = home;
            let export_ix = exports.len() as u32;
            let slot = self.ensure_slot_at_rule(&lv, rule_ord as u32, home);
            let chunk = self.rule_home_chunk[rule_ord];
            let instr = Instr::Export {
                slot,
                export: export_ix,
            };
            match chunk {
                Some(ci) => self.streams[home as usize][ci]
                    .instrs
                    .push((instr, crate::precision::active())),
                None => {
                    // The rule emitted nothing into its home stream (its whole
                    // value hoisted to an earlier section): open a chunk now,
                    // AT THE RULE'S OWN PLACE in the stream (see
                    // [`Self::open_home_chunk`]) rather than at the end.
                    let ci = self.open_home_chunk(rule_ord as u32, home);
                    self.streams[home as usize][ci]
                        .instrs
                        .push((instr, crate::precision::active()));
                }
            }
            exports.push((name, slot));
        }
        exports
    }

    /// Open a fresh home chunk for `rule` in `home`'s stream, INSERTED at the
    /// rule's own place in rule order rather than appended at the end.
    ///
    /// The export pass reaches this for a producing rule that emitted nothing
    /// into its home stream — a scalar observed whose whole value folded to a
    /// literal, say, or one whose value was hoisted to an earlier section.
    ///
    /// Appending at the END is what issue #207 was: a later rule that BAILED
    /// to the oracle (`Instr::Fallback`) resolves its observed reads through
    /// the runtime observed map, and the producer's `Instr::Export` — the
    /// memcpy that publishes into that map — then ran *after* the fallback that
    /// reads it. The fallback saw the preallocated `0.0`. In the reported
    /// document that zero became a const-array subscript of `0 - 159`, i.e.
    /// `E_TREEWALK_CONSTARRAY_OOB … index -159`; a fallback over a
    /// state-variable gather would instead have silently read the zero ghost.
    ///
    /// Inserting in rule order is both sufficient and safe. Sufficient: an
    /// observed can only be read by a LATER rule than the one defining it
    /// (`observed_rules` is dependency-ordered), so the producer's place
    /// precedes every reader's chunk in this stream. Safe: every stream is
    /// built in nondecreasing rule order (rules are lowered in ordinal order
    /// and [`Self::emit`] appends), so the insertion preserves that order; and
    /// the value being exported is either a literal filled by the instruction
    /// beside it or a slot computed in this or an earlier SECTION, which the
    /// section concatenation in [`Self::finish`] has already run.
    ///
    /// Chunk indices shift on insert, so every `rule_home_chunk` entry at or
    /// after the insertion point **in this stream** is fixed up — entries for
    /// other sections index other streams and are left alone.
    fn open_home_chunk(&mut self, rule: u32, home: Cadence) -> usize {
        let pos = {
            let stream = &mut self.streams[home as usize];
            let pos = stream
                .iter()
                .position(|c| c.rule > rule)
                .unwrap_or(stream.len());
            stream.insert(
                pos,
                Chunk {
                    rule,
                    instrs: Vec::new(),
                },
            );
            pos
        };
        for r in 0..self.rule_home_chunk.len() {
            if self.rules[r].cadence != home {
                continue;
            }
            if let Some(ci) = self.rule_home_chunk[r]
                && ci >= pos
            {
                self.rule_home_chunk[r] = Some(ci + 1);
            }
        }
        self.rule_home_chunk[rule as usize] = Some(pos);
        pos
    }

    /// `ensure_slot` variant used by the export pass, which appends into an
    /// arbitrary earlier rule's chunk rather than the live tail.
    fn ensure_slot_at_rule(&mut self, lv: &LV, rule: u32, home: Cadence) -> SlotId {
        match lv {
            LV::Scalar(s) | LV::Arr(s) => *s,
            other => {
                // Materialize into the rule's home chunk.
                let (shape, origin, scalar) = match self.lv_box(other) {
                    None => (DimU::new(), DimI::new(), true),
                    Some((s, o)) => (s, o, false),
                };
                let out = self.new_slot(&shape, &origin, scalar, home);
                let instr = match other {
                    LV::Lit(_) | LV::Param(_) | LV::Time => Instr::Fill {
                        v: self.op_of(other),
                        out,
                    },
                    _ => Instr::Copy {
                        a: self.op_of(other),
                        out,
                    },
                };
                match self.rule_home_chunk[rule as usize] {
                    Some(ci) => self.streams[home as usize][ci]
                        .instrs
                        .push((instr, crate::precision::active())),
                    // Same ordering rule as the export itself: the chunk goes
                    // at the rule's own place in the stream, never at the end
                    // (issue #207; see [`Self::open_home_chunk`]).
                    None => {
                        let ci = self.open_home_chunk(rule, home);
                        self.streams[home as usize][ci]
                            .instrs
                            .push((instr, crate::precision::active()));
                    }
                }
                out
            }
        }
    }

    /// Flatten the chunk streams, run the fusion post-pass (Step 4), then
    /// liveness + slab coloring, and assemble the final program.
    fn finish(
        mut self,
        exports: Vec<(String, SlotId)>,
        fuse: Option<super::fuse::SuperopCfg>,
    ) -> TapeProgram {
        let mut instrs: Vec<Instr> = Vec::new();
        let mut precision: Vec<Precision> = Vec::new();
        let mut provenance: Vec<u32> = Vec::new();
        let mut n_const = 0u32;
        let mut n_segment = 0u32;
        for (sec, stream) in self.streams.iter_mut().enumerate() {
            let start = instrs.len();
            for chunk in stream.drain(..) {
                provenance.extend(std::iter::repeat_n(chunk.rule, chunk.instrs.len()));
                for (i, p) in chunk.instrs {
                    instrs.push(i);
                    precision.push(p);
                }
            }
            let count = (instrs.len() - start) as u32;
            match sec {
                0 => n_const = count,
                1 => n_segment = count,
                _ => {}
            }
        }

        // Uniform — the precision the program runs under — for every document
        // without a per-variable element type, and then not stored at all.
        let build = crate::precision::active();
        if precision.iter().all(|&p| p == build) {
            precision.clear();
        }
        let mut prog = TapeProgram {
            instrs,
            precision,
            n_const,
            n_segment,
            slots: std::mem::take(&mut self.slots),
            plans: std::mem::take(&mut self.plans),
            regions: std::mem::take(&mut self.regions),
            assemblies: std::mem::take(&mut self.assemblies),
            const_data: std::mem::take(&mut self.const_data),
            interp_tables: std::mem::take(&mut self.interp_tables),
            geoms: std::mem::take(&mut self.geoms),
            index_gathers: std::mem::take(&mut self.index_gathers),
            gather_tables: std::mem::take(&mut self.gather_tables),
            seg_tables: std::mem::take(&mut self.seg_tables),
            faults: std::mem::take(&mut self.faults),
            state_vars: std::mem::take(&mut self.state_vars),
            obs_reads: std::mem::take(&mut self.obs_reads),
            forcings: std::mem::take(&mut self.forcings),
            dy_writes: std::mem::take(&mut self.dy_writes),
            exports,
            rules: std::mem::take(&mut self.rules),
            slab: SlabLayout::default(),
            provenance,
            params_len: self.param_names.len(),
            fused: Vec::new(),
            fuse_stats: FuseStats::default(),
        };
        if let Some(cfg) = fuse {
            super::fuse::fuse_program(&mut prog, cfg);
        }
        color_slab(&mut prog);
        prog
    }

    pub(crate) fn vn_hits(&self) -> (usize, usize) {
        (self.vn_scope_hits, self.vn_hoist_hits)
    }
}

// ---------------------------------------------------------------------------
// Liveness + greedy interval slab coloring.
// ---------------------------------------------------------------------------

/// Assign each slot a storage bucket. Cross-section-live slots (a CONST ramp
/// read by the CONTINUOUS section every call) get dedicated storages; slots
/// whose whole lifetime sits inside one section recycle storage greedily by
/// element count (linear-scan last-use over the straight-line program —
/// conservative and sound under the structured `JmpIfZero` skips, which only
/// ever shorten execution).
fn color_slab(prog: &mut TapeProgram) {
    let n_slots = prog.slots.len();
    let mut def: Vec<usize> = vec![usize::MAX; n_slots];
    let mut last_use: Vec<usize> = vec![0; n_slots];
    for (i, instr) in prog.instrs.iter().enumerate() {
        instr.for_each_def(&prog.fused, |out| {
            let d = &mut def[out as usize];
            if *d == usize::MAX {
                *d = i;
            } else {
                // A RE-definition (the phi slot's second branch `Copy`): the
                // storage must stay reserved through it, so count it as a use.
                last_use[out as usize] = last_use[out as usize].max(i);
            }
        });
        instr.for_each_read(&prog.dy_writes, &prog.fused, &prog.assemblies, |s| {
            last_use[s as usize] = last_use[s as usize].max(i);
        });
    }

    // Persistence: read from a later section than the defining one.
    let mut dedicated: Vec<bool> = vec![false; n_slots];
    for s in 0..n_slots {
        if def[s] == usize::MAX {
            continue; // never defined (unused slot — possible after rollbacks)
        }
        let def_sec = prog.section_of(def[s]);
        let use_sec = prog.section_of(last_use[s].max(def[s]));
        if use_sec > def_sec {
            dedicated[s] = true;
        }
    }

    // Storage assignment.
    let mut storages: Vec<StorageDesc> = Vec::new();
    // Free storages per element count (recycled class only).
    let mut free: FxHashMap<usize, Vec<u32>> = FxHashMap::default();
    // Slots whose storage frees after instruction i: (i → slots).
    let mut dying_at: Vec<Vec<u32>> = vec![Vec::new(); prog.instrs.len() + 1];
    for s in 0..n_slots {
        if def[s] != usize::MAX && !dedicated[s] {
            dying_at[last_use[s].max(def[s])].push(s as u32);
        }
    }

    for i in 0..prog.instrs.len() {
        // Aliasing hazard: a Gather/Region reads its source through shifted
        // offsets while writing out — and a Fused group's outputs are written
        // run-by-run while inputs may still be read at shifted offsets by
        // later runs — so out must not reuse a source buffer freed by this
        // very instruction. Release dying operands BEFORE allocating out only
        // for alias-safe (index-aligned elementwise) instructions.
        let alias_safe = !matches!(
            prog.instrs[i],
            Instr::Gather { .. }
                | Instr::Region { .. }
                | Instr::Fused { .. }
                | Instr::Reduce { .. }
                | Instr::Scan { .. }
                | Instr::Assemble { .. }
                | Instr::PolyArea { .. }
                | Instr::IndexGather { .. }
                | Instr::TableGather { .. }
                | Instr::SegReduce { .. }
                | Instr::Reshape { .. }
        );
        let mut defs_here: SmallVec<[SlotId; 2]> = SmallVec::new();
        prog.instrs[i].for_each_def(&prog.fused, |o| {
            if def[o as usize] == i {
                defs_here.push(o);
            }
        });
        if alias_safe {
            for &s in &dying_at[i] {
                let st = prog.slots[s as usize].storage;
                if st != u32::MAX {
                    free.entry(storages[st as usize].elems)
                        .or_default()
                        .push(st);
                }
            }
        }
        for &o in &defs_here {
            let desc = &prog.slots[o as usize];
            let elems = desc.elems();
            let storage = if dedicated[o as usize] {
                storages.push(StorageDesc {
                    elems,
                    offset: 0,
                    cadence: desc.cadence,
                    dedicated: true,
                });
                (storages.len() - 1) as u32
            } else if let Some(st) = free.get_mut(&elems).and_then(|v| v.pop()) {
                st
            } else {
                storages.push(StorageDesc {
                    elems,
                    offset: 0,
                    cadence: desc.cadence,
                    dedicated: false,
                });
                (storages.len() - 1) as u32
            };
            prog.slots[o as usize].storage = storage;
        }
        if !alias_safe {
            for &s in &dying_at[i] {
                let st = prog.slots[s as usize].storage;
                if st != u32::MAX {
                    free.entry(storages[st as usize].elems)
                        .or_default()
                        .push(st);
                }
            }
        }
    }

    // Flat offsets + summary.
    let mut offset = 0usize;
    let mut const_elems = 0usize;
    let mut segment_elems = 0usize;
    let mut recycled_elems = 0usize;
    for st in &mut storages {
        st.offset = offset;
        offset += st.elems;
        if st.dedicated {
            match st.cadence {
                Cadence::Const => const_elems += st.elems,
                Cadence::Segment => segment_elems += st.elems,
                Cadence::Continuous => recycled_elems += st.elems,
            }
        } else {
            recycled_elems += st.elems;
        }
    }
    prog.slab = SlabLayout {
        storages,
        total_elems: offset,
        const_elems,
        segment_elems,
        recycled_elems,
    };
}
