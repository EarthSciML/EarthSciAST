//! `lanes` (API_SPEC §5.8, RFC U3 §6): a pointwise or column operator over a
//! run-time list of cells or columns.
//!
//! A lane program is the operator's rules rewritten over one lane axis of
//! `capacity` lanes (and, for a column operator, the whole of every other
//! axis), and re-lowered: a state read at the lane's own cell becomes a read
//! of the lane block, and every value that depends on the cell's index — a
//! coordinate, a level gate, an affine read of an array parameter, a forcing
//! buffer or a state-free observed — is computed from the lane's entry of
//! `cells`, which the call copies into the program's state each time. One
//! build serves every batch of up to `capacity` lanes; a lane's result
//! depends only on its own inputs, so lane order, duplicates and padding
//! cannot change a value.
//!
//! The pre-gather plan ([`LaneProgram::lane_inputs`]) hoists every read of a
//! non-state array whose subscripts depend on the lane's cell alone into a
//! per-lane buffer: [`LaneProgram::gather_lane_inputs`] fills the buffers once
//! per batch, and [`LaneProgram::eval_gathered_into`] runs the program with
//! those reads replaced by reads of the buffers. A plain call gathers for
//! itself and runs the same program, so a call's work is proportional to its
//! lanes: the whole-domain values the hoisted reads reach (state-free
//! observeds of the data) live once per lane program, in the gather
//! program's context, computed once per parameter vector and forcing epoch
//! and shared by every workspace.

use super::forcing::{ForcingSet, ForcingSlot, RhsError, shape};
use super::tile::{declined_error, plain_precision, refused, shell};
use super::walk::AxisSpec;
use super::{
    Blocks, Decomposition, Ingress, InputPrecisions, LaneKind, LaneLayout, ProgramModel,
    RhsProgram, RhsWorkspace, TileInput, WsExec, build_error, check_forcing, check_lengths,
    check_owner, index_set_sizes, next_program_id, slot_map, tape_fault, var_infos,
};
use crate::simulate::SimulateError;
use crate::simulate_array::tape::{
    CallInputs, ForcingView, TapeCtx, TapeProgram, TileLowering, run_tape_inputs,
};
use crate::simulate_array::{AlgebraicRule, ArrayCompiled, RhsRule, VarShape};
use crate::types::{Expr, ExpressionNode, RegionBound};
use indexmap::IndexMap;
use rustc_hash::FxHashMap;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// The lane symbol every rewritten rule runs over.
const LANE: &str = "__lane";

fn cell_var(set: &str) -> String {
    format!("__cell_{set}")
}

fn input_var(k: usize) -> String {
    format!("__lane_input_{k}")
}

/// The lane block holding each lane's time (U19): `t` in a lane rule reads
/// its lane's entry.
const LANE_T: &str = "__lane_t";

fn lane_index(v: &str) -> Expr {
    Expr::operator(ExpressionNode {
        op: "index".to_string(),
        args: vec![
            Expr::Variable(v.to_string()),
            Expr::Variable(LANE.to_string()),
        ],
        ..Default::default()
    })
}

/// A lane program (RFC U3 §6). `Send + Sync + Clone`; it reads the forcing
/// sets of the program it was built from.
#[derive(Clone)]
pub struct LaneProgram {
    inner: Arc<LaneInner>,
}

struct LaneInner {
    id: u64,
    /// The rules rewritten over the lane axis, every hoisted read taken
    /// from its lane buffer: what every call runs.
    prog: Arc<TapeProgram>,
    /// The gather program's context, which every gather of this program
    /// and its clones runs in (see [`Shared`]). The gather program has one
    /// rule per hoisted read, and the whole-domain state-free observeds
    /// those reads reach.
    shared: Shared,
    /// The forcing slot each forcing load of `prog` and `gather` reads.
    slot_of: [Vec<u32>; 2],
    /// How `prog` reads the time (U19).
    timing: LaneTime,
    blocks: Blocks,
    layout: LaneLayout,
    default_set: ForcingSet,
    capacity: usize,
    sets: Vec<String>,
    /// The global extent of each lane set, for validating `cells`.
    extents: Vec<i64>,
    n_inputs: usize,
    n_params: usize,
    inputs: InputPrecisions,
    declared: Arc<HashSet<String>>,
    precision: crate::precision::Precision,
}

/// How a lane program reads `t` (U19).
enum LaneTime {
    /// Every rule reads `t` per lane, and every observed that depends on
    /// it is computed per lane: one program serves every batch, its lanes
    /// at one time or at several.
    PerLane,
    /// No rule reads `t`, or some state-free observed that depends on it
    /// has no lane form: that observed (with every observed of `t` it
    /// reads) stays whole-domain, evaluated at the call's one time, so a
    /// batch's lanes must share one time. The reason, when there is one,
    /// is the error a batch at mixed times returns.
    Once(Option<String>),
}

/// The gather program's context, shared by every workspace and lane input
/// of one lane program (and its clones): it holds the whole-domain values
/// of the state-free observeds the hoisted reads reach, computed once per
/// parameter vector and forcing epoch (the tape's CONST and SEGMENT
/// sections), so no workspace holds a whole-domain array. A gather is a
/// short critical section: it reads each hoisted value at each lane's cell.
struct Shared {
    ctx: std::sync::Mutex<Box<TapeCtx>>,
}

impl Shared {
    fn new(gather: &Arc<TapeProgram>) -> Self {
        let mut ctx = TapeCtx::new(Arc::clone(gather));
        ctx.set_serial();
        Shared {
            ctx: std::sync::Mutex::new(Box::new(ctx)),
        }
    }

    /// The context, primed sections forgotten if a call panicked in it.
    fn lock(&self) -> std::sync::MutexGuard<'_, Box<TapeCtx>> {
        match self.ctx.lock() {
            Ok(g) => g,
            Err(poisoned) => {
                self.ctx.clear_poison();
                let mut g = poisoned.into_inner();
                g.invalidate_sections();
                g
            }
        }
    }
}

impl std::fmt::Debug for LaneProgram {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LaneProgram")
            .field("capacity", &self.inner.capacity)
            .field("sets", &self.inner.sets)
            .field("layout", &self.inner.layout)
            .finish()
    }
}

/// A gather's per-lane buffers: its state (the cells, after room for the
/// values) and the values it writes, one run of `capacity` per hoisted read.
pub(super) struct GatherBufs {
    state: Vec<f64>,
    values: Vec<f64>,
}

/// The per-lane buffers of a lane program's pre-gather plan: one run of
/// `capacity` values per hoisted read. Filled by
/// [`LaneProgram::gather_lane_inputs`], read by
/// [`LaneProgram::eval_gathered_into`], which reads the forcing set they
/// were gathered from. `Send`, like a workspace.
pub struct LaneInputs {
    owner: u64,
    forcing: Option<ForcingSet>,
    bufs: GatherBufs,
    /// The gather's parameters, rounded to their precisions.
    ingress: Ingress,
}

impl std::fmt::Debug for LaneInputs {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LaneInputs")
            .field("len", &self.bufs.values.len())
            .finish()
    }
}

impl LaneInputs {
    /// The gathered values: hoisted read `k`'s lanes at `k * capacity ..`.
    pub fn values(&self) -> &[f64] {
        &self.bufs.values
    }
}

const PROG: usize = 0;
const GATHER: usize = 1;

impl LaneProgram {
    /// The lane layout (RFC U3 §6): each variable a column-major block whose
    /// first axis is the lane (`1..=capacity`) and whose other axes are the
    /// variable's axes outside the lane's sets, in order.
    pub fn layout(&self) -> &LaneLayout {
        &self.inner.layout
    }

    /// The number of lanes the program was built for.
    pub fn capacity(&self) -> usize {
        self.inner.capacity
    }

    /// The number of hoisted reads the pre-gather plan fills.
    pub fn n_lane_inputs(&self) -> usize {
        self.inner.n_inputs
    }

    /// The forcing slots a set for this program holds: the whole program's.
    pub fn forcing_slots(&self) -> &[ForcingSlot] {
        self.inner.default_set.slots()
    }

    fn gather_bufs(&self) -> GatherBufs {
        let inner = &*self.inner;
        GatherBufs {
            state: vec![0.0; inner.capacity * (inner.n_inputs + inner.sets.len())],
            values: vec![0.0; inner.capacity * inner.n_inputs],
        }
    }

    /// Buffers for [`Self::eval_into`] and [`Self::eval_gathered_into`].
    pub fn new_workspace(&self) -> RhsWorkspace {
        let inner = &*self.inner;
        let n = inner.blocks.u_len
            + inner.blocks.aux_len
            + inner.capacity * (inner.sets.len() + 1 + inner.n_inputs);
        let mut ctx = TapeCtx::new(Arc::clone(&inner.prog));
        ctx.set_serial();
        RhsWorkspace {
            owner: inner.id,
            state: vec![0.0; n],
            dy: Vec::new(),
            ingress: Default::default(),
            exec: WsExec::Lanes {
                ctx: Box::new(ctx),
                gather: self.gather_bufs(),
            },
            _not_sync: std::marker::PhantomData,
        }
    }

    /// Copy `cells` (`[D, L]`, column-major, 1-based global indices) into the
    /// lane rows of `state` starting at `at`, as `f64`. Only lanes `1..=n` are
    /// read from `cells` (and range-checked); every lane past `n` repeats lane
    /// 1 (or cell 1 when `n = 0`), so the padding lanes the tape still
    /// computes read in-range indices whatever the tail of `cells` holds.
    fn write_cells(
        &self,
        state: &mut [f64],
        at: usize,
        cells: &[i32],
        n: usize,
    ) -> Result<(), RhsError> {
        let inner = &*self.inner;
        let d = inner.sets.len();
        if n > inner.capacity {
            return Err(shape("n (lanes past the capacity)", inner.capacity, n));
        }
        if !cells.len().is_multiple_of(d.max(1))
            || cells.len() / d.max(1) < n
            || cells.len() / d.max(1) > inner.capacity
        {
            return Err(shape(
                "cells (D times a lane count between n and the capacity)",
                d * n.max(1),
                cells.len(),
            ));
        }
        for (a, &ext) in inner.extents.iter().enumerate() {
            let rows = &mut state[at + a * inner.capacity..at + (a + 1) * inner.capacity];
            for (l, row) in rows.iter_mut().enumerate() {
                let c = match (l < n, n > 0) {
                    (true, _) => cells[l * d + a],
                    (false, true) => cells[a],
                    (false, false) => 1,
                };
                if l < n && (i64::from(c) < 1 || i64::from(c) > ext) {
                    return Err(shape(
                        "cells (a lane's cell outside its index set)",
                        ext as usize,
                        c.max(0) as usize,
                    ));
                }
                *row = f64::from(c);
            }
        }
        Ok(())
    }

    /// Evaluate lanes `1..=n` (RFC U3 §6): for each lane `l` and each written
    /// variable, `du` holds the whole-domain program's value at `cells[:, l]`.
    #[allow(clippy::too_many_arguments)]
    pub fn eval_into(
        &self,
        u: &[f64],
        aux: &[f64],
        p: &[f64],
        t: f64,
        forcing: &ForcingSet,
        cells: &[i32],
        n: usize,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), RhsError> {
        self.run(u, aux, None, p, t, None, forcing, cells, n, du, ws)
    }

    /// [`Self::eval_into`] with each lane at its own time (U19): lane `l`
    /// evaluates at `ts[l]`, `ts` holding at least `n` and at most
    /// `capacity` times (a padding lane takes `ts[0]`). Lane `l`'s value is
    /// the whole-domain program's at `cells[:, l]` and time `ts[l]`, bit for
    /// bit, whatever the other lanes' times. When every `ts[l]` equals
    /// `ts[0]` this is [`Self::eval_into`] at `ts[0]`. Where an observed that
    /// depends on `t` has no per-lane form (it stays one whole-domain value
    /// per call), lanes at different times are [`RhsError::MixedTimes`].
    #[allow(clippy::too_many_arguments)]
    pub fn eval_times_into(
        &self,
        u: &[f64],
        aux: &[f64],
        p: &[f64],
        ts: &[f64],
        forcing: &ForcingSet,
        cells: &[i32],
        n: usize,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), RhsError> {
        let t = ts.first().copied().unwrap_or(0.0);
        self.run(u, aux, None, p, t, Some(ts), forcing, cells, n, du, ws)
    }

    /// The pre-gather plan's buffers, unfilled.
    pub fn lane_inputs(&self) -> LaneInputs {
        LaneInputs {
            owner: self.inner.id,
            forcing: None,
            bufs: self.gather_bufs(),
            ingress: Ingress::default(),
        }
    }

    /// Fill `inputs` for lanes `1..=n` of `cells`: every hoisted read of a
    /// non-state input, at each lane's cell.
    pub fn gather_lane_inputs(
        &self,
        inputs: &mut LaneInputs,
        p: &[f64],
        t: f64,
        forcing: &ForcingSet,
        cells: &[i32],
        n: usize,
    ) -> Result<(), RhsError> {
        let inner = &*self.inner;
        if inputs.owner != inner.id {
            return Err(RhsError::ForeignProgram {
                what: "lane inputs",
            });
        }
        // Cleared until this gather succeeds: a failed gather leaves the
        // buffers half-written, and they must not evaluate.
        inputs.forcing = None;
        if p.len() != inner.n_params {
            return Err(shape("p", inner.n_params, p.len()));
        }
        check_forcing(forcing, &inner.default_set)?;
        let at = inner.capacity * inner.n_inputs;
        self.write_cells(&mut inputs.bufs.state, at, cells, n)?;
        let (_, _, p) = inner.inputs.rounded(&mut inputs.ingress, &[], &[], p);
        self.gather(&mut inputs.bufs, p, t, forcing)?;
        // Kept so the evaluation reads the set these inputs came from (a
        // clone is reference counts, not an allocation).
        inputs.forcing = Some(forcing.clone());
        Ok(())
    }

    /// Run the gather for the cells already in `bufs.state`, with `p`
    /// rounded, in the shared context.
    fn gather(
        &self,
        bufs: &mut GatherBufs,
        p: &[f64],
        t: f64,
        forcing: &ForcingSet,
    ) -> Result<(), RhsError> {
        let inner = &*self.inner;
        if inner.n_inputs == 0 {
            return Ok(());
        }
        let _precision = crate::precision::enter(inner.precision);
        let mut ctx = inner.shared.lock();
        let scope = crate::simulate_array::FaultScope::enter();
        let call = CallInputs {
            state: &bufs.state,
            params: p,
            forcing: ForcingView::Slots {
                bufs: forcing.bufs(),
                slot_of: &inner.slot_of[GATHER],
            },
            forcing_epoch: Some(forcing.epoch()),
            t,
            declared: &inner.declared,
        };
        run_tape_inputs(&mut ctx, &call, &mut bufs.values, false);
        tape_fault(scope, &mut ctx)
    }

    /// [`Self::eval_into`] with every hoisted read taken from `inputs`, and
    /// the forcing set they were gathered from.
    #[allow(clippy::too_many_arguments)]
    pub fn eval_gathered_into(
        &self,
        u: &[f64],
        aux: &[f64],
        inputs: &LaneInputs,
        p: &[f64],
        t: f64,
        cells: &[i32],
        n: usize,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), RhsError> {
        if inputs.owner != self.inner.id {
            return Err(RhsError::ForeignProgram {
                what: "lane inputs",
            });
        }
        let Some(forcing) = &inputs.forcing else {
            return Err(RhsError::NotGathered);
        };
        self.run(
            u,
            aux,
            Some(&inputs.bufs.values),
            p,
            t,
            None,
            forcing,
            cells,
            n,
            du,
            ws,
        )
    }

    /// [`Self::eval_gathered_into`] with each lane at its own time (U19),
    /// as [`Self::eval_times_into`]. The gathered inputs do not depend on
    /// the time: a read whose subscripts involve `t` is never hoisted.
    #[allow(clippy::too_many_arguments)]
    pub fn eval_gathered_times_into(
        &self,
        u: &[f64],
        aux: &[f64],
        inputs: &LaneInputs,
        p: &[f64],
        ts: &[f64],
        cells: &[i32],
        n: usize,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), RhsError> {
        if inputs.owner != self.inner.id {
            return Err(RhsError::ForeignProgram {
                what: "lane inputs",
            });
        }
        let Some(forcing) = &inputs.forcing else {
            return Err(RhsError::NotGathered);
        };
        let t = ts.first().copied().unwrap_or(0.0);
        self.run(
            u,
            aux,
            Some(&inputs.bufs.values),
            p,
            t,
            Some(ts),
            forcing,
            cells,
            n,
            du,
            ws,
        )
    }

    /// One call: the lanes' inputs into the workspace's state, a gather of
    /// the hoisted reads unless `gathered` holds them, then the program.
    #[allow(clippy::too_many_arguments)]
    fn run(
        &self,
        u: &[f64],
        aux: &[f64],
        gathered: Option<&[f64]>,
        p: &[f64],
        t: f64,
        ts: Option<&[f64]>,
        forcing: &ForcingSet,
        cells: &[i32],
        n: usize,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), RhsError> {
        let inner = &*self.inner;
        check_lengths(&inner.blocks, u, aux, du, p, inner.n_params)?;
        check_owner(ws, inner.id)?;
        check_forcing(forcing, &inner.default_set)?;
        // U19: each lane's time; a padding lane takes lane 1's. A batch
        // whose lanes' times all equal (bit for bit) is the one-time call
        // at that time.
        let t = match ts {
            None => t,
            Some(ts) if ts.len() >= n && ts.len() <= inner.capacity => {
                let t0 = ts.first().copied().unwrap_or(t);
                let mixed = ts[..n].iter().any(|x| x.to_bits() != t0.to_bits());
                if let (true, LaneTime::Once(Some(why))) = (mixed, &inner.timing) {
                    return Err(RhsError::MixedTimes {
                        detail: why.clone(),
                    });
                }
                t0
            }
            Some(ts) => {
                return Err(shape(
                    "ts (one time per lane, between n and the capacity)",
                    n,
                    ts.len(),
                ));
            }
        };
        let mut ingress = std::mem::take(&mut ws.ingress);
        let (u, aux, p) = inner.inputs.rounded(&mut ingress, u, aux, p);
        let out = self
            .fill(u, aux, gathered, p, t, ts, forcing, cells, n, ws)
            .and_then(|()| {
                let WsExec::Lanes { ctx, .. } = &mut ws.exec else {
                    unreachable!("a lane workspace runs a lane tape");
                };
                let _precision = crate::precision::enter(inner.precision);
                let scope = crate::simulate_array::FaultScope::enter();
                let call = CallInputs {
                    state: &ws.state,
                    params: p,
                    forcing: ForcingView::Slots {
                        bufs: forcing.bufs(),
                        slot_of: &inner.slot_of[PROG],
                    },
                    forcing_epoch: Some(forcing.epoch()),
                    t,
                    declared: &inner.declared,
                };
                run_tape_inputs(ctx, &call, du, false);
                tape_fault(scope, ctx)
            });
        ws.ingress = ingress;
        out
    }

    /// Write a call's lane state into `ws.state`: `u` and `aux` (rounded),
    /// the cells, each lane's time and the hoisted values, gathered here
    /// (with `p` rounded) unless `gathered` holds them.
    #[allow(clippy::too_many_arguments)]
    fn fill(
        &self,
        u: &[f64],
        aux: &[f64],
        gathered: Option<&[f64]>,
        p: &[f64],
        t: f64,
        ts: Option<&[f64]>,
        forcing: &ForcingSet,
        cells: &[i32],
        n: usize,
        ws: &mut RhsWorkspace,
    ) -> Result<(), RhsError> {
        let inner = &*self.inner;
        let (nu, na) = (inner.blocks.u_len, inner.blocks.aux_len);
        let cap = inner.capacity;
        let state = &mut ws.state;
        state[..nu].copy_from_slice(u);
        state[nu..nu + na].copy_from_slice(aux);
        self.write_cells(state, nu + na, cells, n)?;
        let tat = nu + na + cap * inner.sets.len();
        for (l, x) in state[tat..tat + cap].iter_mut().enumerate() {
            *x = match ts {
                Some(ts) if l < n => ts[l],
                _ => t,
            };
        }
        let at = tat + cap;
        let len = cap * inner.n_inputs;
        match gathered {
            Some(g) => state[at..at + len].copy_from_slice(g),
            None => {
                let WsExec::Lanes { gather, .. } = &mut ws.exec else {
                    unreachable!("a lane workspace runs a lane tape");
                };
                let d = inner.sets.len();
                // The gather reads the cells after its values' room.
                gather.state[len..len + cap * d]
                    .copy_from_slice(&state[nu + na..nu + na + cap * d]);
                self.gather(gather, p, t, forcing)?;
                state[at..at + len].copy_from_slice(&gather.values);
            }
        }
        Ok(())
    }
}

/// The rewrite of one program's rules over the lane axis.
struct Rewriter<'a> {
    /// The index-set name of each axis of each state and array observed.
    axes: &'a HashMap<String, Vec<Option<String>>>,
    /// The states and state-dependent observeds that become lane blocks.
    lane_vars: &'a HashSet<String>,
    /// The scalar observeds that depend on a state or on `t`: one value per
    /// lane, read at the lane (U19). Empty in a one-time rewrite.
    lane_scalars: &'a HashSet<String>,
    /// A rewrite for lanes each at its own time: `t` reads the lane's time.
    timed: bool,
    /// The observeds that depend on a state or on `t`, which no hoisted
    /// read mentions: the gather program computes neither.
    no_hoist: &'a HashSet<String>,
    sets: &'a [String],
    sizes: &'a HashMap<String, i64>,
    cells: bool,
    capacity: i64,
    rule: String,
    /// The hoisted non-state reads of the pre-gather plan, each replaced
    /// by a read of its lane buffer.
    gathers: Vec<Expr>,
}

/// The symbols in force while rewriting: the original output symbols that
/// run along a lane set (each mapped to that set), every other symbol, and
/// the output indices of an array `faq` read at a non-lane subscript (each
/// mapped to its value there, an expression over the enclosing symbols that
/// is already rewritten).
#[derive(Clone, Default)]
struct LScope {
    lane_syms: Vec<(String, String)>,
    inner: Vec<String>,
    alias: Vec<(String, Expr)>,
    /// The range each of the rule's own non-lane loop symbols runs over.
    extents: Vec<(String, (i64, i64))>,
}

impl LScope {
    fn lane_set(&self, sym: &str) -> Option<&str> {
        self.lane_syms
            .iter()
            .find(|(s, _)| s == sym)
            .map(|(_, set)| set.as_str())
    }

    fn alias(&self, sym: &str) -> Option<&Expr> {
        self.alias.iter().find(|(s, _)| s == sym).map(|(_, e)| e)
    }

    /// `sym` as a plain non-lane loop symbol in force, with the range it
    /// runs over: itself, or the symbol an alias names.
    fn inner_extent(&self, sym: &str) -> Option<(String, (i64, i64))> {
        let sym = match self.alias(sym) {
            Some(Expr::Variable(y)) => y.as_str(),
            Some(_) => return None,
            None => sym,
        };
        if !self.inner.iter().any(|s| s == sym) {
            return None;
        }
        self.extents
            .iter()
            .find(|(s, _)| s == sym)
            .map(|(s, e)| (s.clone(), *e))
    }

    /// Whether `x`, a name in a rewritten expression, is a loop symbol of
    /// the enclosing rule: one in force, or one an alias's value names.
    fn is_loop(&self, x: &str) -> bool {
        self.inner.iter().any(|s| s == x)
            || self.alias.iter().any(|(_, e)| mentions(e, &mut |y| y == x))
    }

    /// Drop every meaning of `names`, which a nested binder rebinds.
    fn unbind(&mut self, names: &[&String]) {
        self.lane_syms.retain(|(s, _)| !names.contains(&s));
        self.inner.retain(|s| !names.contains(&s));
        self.alias.retain(|(s, _)| !names.contains(&s));
        self.extents.retain(|(s, _)| !names.contains(&s));
    }

    /// The alias in force whose value names one of `names`, which a nested
    /// binder is about to rebind: that binder would capture it.
    fn captured(&self, names: &[&String]) -> Option<&str> {
        self.alias
            .iter()
            .find(|(_, e)| mentions(e, &mut |x| names.iter().any(|n| *n == x)))
            .map(|(s, _)| s.as_str())
    }
}

/// How an output index of an array `faq` is bound where the `faq` is read.
enum OutBind {
    /// The lane's cell along this lane set.
    Lane(String),
    /// This (already rewritten) expression.
    At(Expr),
}

type RResult<T> = Result<T, SimulateError>;

fn lane_read(set: &str) -> Expr {
    Expr::operator(ExpressionNode {
        op: "index".to_string(),
        args: vec![
            Expr::Variable(cell_var(set)),
            Expr::Variable(LANE.to_string()),
        ],
        ..Default::default()
    })
}

fn mentions(e: &Expr, pred: &mut dyn FnMut(&str) -> bool) -> bool {
    match e {
        Expr::Variable(v) => pred(v),
        Expr::Operator(n) => n.any_child(&mut |c| mentions(c, pred)),
        _ => false,
    }
}

impl Rewriter<'_> {
    fn refuse<T>(&self, what: impl std::fmt::Display) -> RResult<T> {
        Err(refused(format!("lane: rule `{}` {what}", self.rule)))
    }

    fn expr(&mut self, e: &Expr, sc: &LScope) -> RResult<Expr> {
        match e {
            Expr::Number(_) | Expr::Integer(_) => Ok(e.clone()),
            Expr::Variable(v) => {
                if let Some(e) = sc.alias(v) {
                    return Ok(e.clone());
                }
                if let Some(set) = sc.lane_set(v) {
                    return Ok(lane_read(set));
                }
                if sc.inner.contains(v) {
                    return Ok(e.clone());
                }
                // U19: each lane is at its own time.
                if self.timed && v == "t" {
                    return Ok(lane_index(LANE_T));
                }
                if self.lane_scalars.contains(v) {
                    return Ok(lane_index(v));
                }
                if self.lane_vars.contains(v) && self.axes.get(v).is_some_and(|a| !a.is_empty()) {
                    return self.refuse(format_args!("reads the array `{v}` whole"));
                }
                Ok(e.clone())
            }
            Expr::Operator(node) => match node.op.as_str() {
                "index" if !node.args.is_empty() => self.index(node, sc),
                "makearray" => self.refuse("holds a makearray outside a subscripted read"),
                "faq" => {
                    if node.output_idx.as_ref().is_some_and(|o| !o.is_empty()) {
                        return self.refuse("holds an array-valued faq in an elementwise position");
                    }
                    let mut inner = sc.clone();
                    if let Some(r) = &node.ranges {
                        let keys: Vec<&String> = r.keys().collect();
                        inner.unbind(&keys);
                        if let Some(o) = inner.captured(&keys) {
                            return self.refuse(format_args!(
                                "reads an array faq whose output index `{o}` stands for a \
                                 subscript a nested faq rebinds"
                            ));
                        }
                        inner.inner.extend(keys.into_iter().cloned());
                    }
                    let mut n = ExpressionNode::clone(node);
                    if let Some(b) = node.expr.as_deref() {
                        n.expr = Some(Box::new(self.expr(b, &inner)?));
                    }
                    if let Some(f) = node.filter.as_deref() {
                        n.filter = Some(Box::new(self.expr(f, &inner)?));
                    }
                    Ok(Expr::operator(n))
                }
                _ => {
                    let mut err = None;
                    let out = node.map_children(&mut |c| match self.expr(c, sc) {
                        Ok(x) => x,
                        Err(r) => {
                            err.get_or_insert(r);
                            c.clone()
                        }
                    });
                    match err {
                        Some(r) => Err(r),
                        None => Ok(Expr::operator(out)),
                    }
                }
            },
        }
    }

    fn index(&mut self, node: &Arc<ExpressionNode>, sc: &LScope) -> RResult<Expr> {
        let base = &node.args[0];
        let subs = &node.args[1..];
        match base {
            Expr::Variable(v) if self.lane_vars.contains(v) => {
                let axes = self.axes.get(v).cloned().unwrap_or_default();
                if axes.len() != subs.len() {
                    return self.refuse(format_args!("reads `{v}` at the wrong rank"));
                }
                let mut new_args = vec![base.clone(), Expr::Variable(LANE.to_string())];
                for (d, s) in subs.iter().enumerate() {
                    match axes[d]
                        .as_deref()
                        .filter(|set| self.sets.iter().any(|x| x == set))
                    {
                        Some(set) => {
                            let own = matches!(s, Expr::Variable(x) if sc.lane_set(x) == Some(set));
                            if !own {
                                return self.refuse(format_args!(
                                    "reads `{v}` off its own lane's cell along `{set}`, which is \
                                     not {} locality",
                                    if self.cells { "pointwise" } else { "column" }
                                ));
                            }
                        }
                        None => new_args.push(self.expr(s, sc)?),
                    }
                }
                let mut n = ExpressionNode::clone(node);
                n.args = new_args;
                Ok(Expr::operator(n))
            }
            Expr::Variable(_) => {
                let mut new_subs = Vec::with_capacity(subs.len());
                for s in subs {
                    new_subs.push(self.expr(s, sc)?);
                }
                let mut n = ExpressionNode::clone(node);
                n.args = std::iter::once(base.clone()).chain(new_subs).collect();
                let read = Expr::operator(n);
                // A read whose subscripts depend on the lane's cell alone
                // (and on no other symbol) is one value per lane: hoisted.
                // A read that involves the time, or an observed that depends
                // on a state or on the time, is not one value per cell, so it
                // is not hoisted (U19).
                let by_cell = read_mentions_lane(&read)
                    && !mentions(&read, &mut |x| {
                        sc.is_loop(x) || x == "t" || x == LANE_T || self.no_hoist.contains(x)
                    });
                if !by_cell {
                    return Ok(read);
                }
                let k = match self.gathers.iter().position(|g| *g == read) {
                    Some(k) => k,
                    None => {
                        self.gathers.push(read.clone());
                        self.gathers.len() - 1
                    }
                };
                Ok(lane_index(&input_var(k)))
            }
            Expr::Operator(m) if m.op == "makearray" => self.makearray_read(node, m, sc),
            Expr::Operator(m)
                if m.op == "faq" && m.output_idx.as_ref().is_some_and(|o| !o.is_empty()) =>
            {
                self.faq_read(node, m, sc)
            }
            _ => self.refuse("subscripts an array expression a lane cannot restrict"),
        }
    }

    /// `index(makearray(…), syms…)` with the box's own symbols in order: a
    /// makearray whose regions span the whole of every lane set, rewritten
    /// over the lane axis and the other axes.
    fn makearray_read(
        &mut self,
        node: &Arc<ExpressionNode>,
        m: &Arc<ExpressionNode>,
        sc: &LScope,
    ) -> RResult<Expr> {
        let subs = &node.args[1..];
        let (Some(regions), Some(values)) = (m.regions.as_ref(), m.values.as_ref()) else {
            return self.refuse("holds a makearray with no regions");
        };
        // A region that covers only part of a lane set along the axis a lane
        // subscript runs on (a coefficient that exists only at the surface,
        // region 1..1 along `lev`): which regions hold a lane's element
        // depends on the lane's cell, so the read is lowered to region
        // membership instead, each lane taking the value of the last region
        // that holds its cell (esm-spec §4.3.2) and 0 where none does.
        let partial = regions.iter().any(|region| {
            region.iter().zip(subs).any(|(b, s)| match s {
                Expr::Variable(x) => sc.lane_set(x).is_some_and(|set| {
                    let n = self.sizes.get(set).copied().unwrap_or(-1);
                    crate::types::region_bounds(b).is_none_or(|[lo, hi]| lo != 1 || hi != n)
                }),
                _ => false,
            })
        });
        if partial {
            let lane_of: Vec<Option<String>> = subs
                .iter()
                .map(|s| match s {
                    Expr::Variable(x) => sc.lane_set(x).map(str::to_string),
                    _ => None,
                })
                .collect();
            let lowered = membership_read(regions, values, subs, &lane_of, self.axes)
                .map_err(|why| refused(format!("lane: rule `{}` {why}", self.rule)))?;
            return self.expr(&lowered, sc);
        }
        // Per axis: the lane set it runs along, if any.
        let mut lane_axes: Vec<Option<String>> = Vec::with_capacity(subs.len());
        let mut inner_subs = Vec::new();
        for s in subs {
            match s {
                Expr::Variable(x) if sc.lane_set(x).is_some() => {
                    lane_axes.push(sc.lane_set(x).map(str::to_string));
                }
                Expr::Variable(x) => {
                    // A loop symbol of the rule, or an output index an
                    // enclosing array faq read binds to one.
                    let y = match sc.alias(x) {
                        Some(Expr::Variable(y)) => y,
                        Some(_) => {
                            return self.refuse(
                                "subscripts a makearray at a shifted or computed position",
                            );
                        }
                        None => x,
                    };
                    if !sc.is_loop(y) {
                        return self
                            .refuse("subscripts a makearray at a shifted or computed position");
                    }
                    lane_axes.push(None);
                    inner_subs.push(Expr::Variable(y.clone()));
                }
                _ => {
                    return self.refuse("subscripts a makearray at a shifted or computed position");
                }
            }
        }
        // Where the assembled array starts along each axis: subscript `s`
        // reads the element at `origin + s - 1` (§4.3.2's bounding box).
        let mut origin = vec![i64::MAX; subs.len()];
        for region in regions {
            for (d, b) in region.iter().enumerate().take(subs.len()) {
                if let Some([lo, _]) = crate::types::region_bounds(b) {
                    origin[d] = origin[d].min(lo);
                }
            }
        }
        let mut new_regions = Vec::with_capacity(regions.len());
        let mut new_values = Vec::with_capacity(values.len());
        for (region, value) in regions.iter().zip(values) {
            if region.len() != subs.len() {
                return self.refuse("reads a makearray at the wrong rank");
            }
            let mut r = vec![[RegionBound::Int(1), RegionBound::Int(self.capacity)]];
            let inner_sc = sc.clone();
            for (d, b) in region.iter().enumerate() {
                let Some([lo, hi]) = crate::types::region_bounds(b) else {
                    return self.refuse("holds a makearray with a symbolic region bound");
                };
                match &lane_axes[d] {
                    Some(set) => {
                        let n = self.sizes.get(set).copied().unwrap_or(-1);
                        if lo != 1 || hi != n {
                            return self.refuse(format_args!(
                                "holds a makearray region {lo}..{hi} along the lane set `{set}`, \
                                 which depends on the lane's cell"
                            ));
                        }
                    }
                    None => r.push(b.clone()),
                }
            }
            let v = match value {
                Expr::Operator(v)
                    if v.op == "faq" && v.output_idx.as_ref().is_some_and(|o| !o.is_empty()) =>
                {
                    self.region_faq(v, region, &lane_axes, subs, &origin, &inner_sc)?
                }
                _ => self.expr(value, &inner_sc)?,
            };
            new_values.push(v);
            new_regions.push(r);
        }
        let mut nm = ExpressionNode::clone(m);
        nm.regions = Some(new_regions);
        nm.values = Some(new_values);
        let mut n = ExpressionNode::clone(node);
        n.args = std::iter::once(Expr::operator(nm))
            .chain(std::iter::once(Expr::Variable(LANE.to_string())))
            .chain(inner_subs)
            .collect();
        Ok(Expr::operator(n))
    }
}

impl Rewriter<'_> {
    /// An array `faq` region value of a makearray read at `subs`, at one
    /// cell of its region. The value must fit the region exactly — each
    /// output axis over the region's own bounds, along a lane set the whole
    /// set (`from` it or `[1, n]`) — and the assembled array must start at 1
    /// along every other axis; then the region's element at the read is the
    /// value's element at the same coordinate, so an output index along a
    /// lane set is bound to the lane's cell and one along another axis to
    /// that axis's subscript. Anything else is refused (the Julia binding
    /// refuses the same documents).
    fn region_faq(
        &mut self,
        f: &ExpressionNode,
        region: &[[RegionBound; 2]],
        lane_axes: &[Option<String>],
        subs: &[Expr],
        origin: &[i64],
        sc: &LScope,
    ) -> RResult<Expr> {
        let outs = f.output_idx.as_deref().unwrap_or_default();
        if outs.len() != region.len() {
            return self.refuse("holds a faq region value that does not fit its region");
        }
        let ranges = f.ranges.clone().unwrap_or_default();
        let mut binds = Vec::with_capacity(outs.len());
        for (d, o) in outs.iter().enumerate() {
            let Some([lo, hi]) = crate::types::region_bounds(&region[d]) else {
                return self.refuse("holds a makearray with a symbolic region bound");
            };
            let range = ranges.get(o);
            let b = match &lane_axes[d] {
                Some(set) => {
                    if !range.is_some_and(|r| self.whole_lane_range(r, set)) {
                        return self.refuse(format_args!(
                            "holds a faq region value whose axis `{o}` does not run over the \
                             whole lane set `{set}`"
                        ));
                    }
                    OutBind::Lane(set.clone())
                }
                None => {
                    if range.and_then(|r| self.range_bounds(r)) != Some((lo, hi)) {
                        return self.refuse(format_args!(
                            "holds a faq region value whose axis `{o}` does not run over its \
                             region {lo}..{hi}"
                        ));
                    }
                    if origin[d] != 1 {
                        return self.refuse(
                            "holds a faq region value in a makearray that does not start at 1",
                        );
                    }
                    let Expr::Variable(x) = &subs[d] else {
                        return self.refuse("subscripts a makearray at a computed position");
                    };
                    OutBind::At(sc.alias(x).cloned().unwrap_or_else(|| subs[d].clone()))
                }
            };
            binds.push((o.clone(), b));
        }
        self.faq_at(f, binds, sc)
    }

    /// Whether the range `r` runs over the whole lane set `set`: `from` it,
    /// or `[1, n]`.
    fn whole_lane_range(&self, r: &crate::types::RangeSpec, set: &str) -> bool {
        let n = self.sizes.get(set).copied().unwrap_or(-1);
        match r {
            crate::types::RangeSpec::IndexSetRef { from, of: None } => from == set,
            crate::types::RangeSpec::Interval([lo, hi]) => *lo == 1 && *hi == n,
            _ => false,
        }
    }

    /// `index(faq{output_idx o, ranges, expr}, s…)` at the lane's own cell:
    /// the array `faq` read where every subscript `s_d` is a lane symbol of
    /// a set the output axis `o_d` runs over whole, or one of the rule's
    /// own non-lane loop symbols over the range `o_d` runs over (from 1).
    /// That is the `faq`'s body with each `o_d` bound to the lane's cell
    /// along that set, or to the loop symbol: see [`Self::faq_at`]. The
    /// planner's whole-array right-hand sides `D(x) = faq{…}` arrive here,
    /// lowered to `index(faq{…}, loops…)`.
    fn faq_read(
        &mut self,
        node: &Arc<ExpressionNode>,
        f: &Arc<ExpressionNode>,
        sc: &LScope,
    ) -> RResult<Expr> {
        let subs = &node.args[1..];
        let outs = f.output_idx.as_deref().unwrap_or_default();
        if subs.len() != outs.len() {
            return self.refuse("reads an array faq at the wrong rank");
        }
        let ranges = f.ranges.clone().unwrap_or_default();
        let mut binds = Vec::with_capacity(outs.len());
        for (o, s) in outs.iter().zip(subs) {
            let Expr::Variable(x) = s else {
                return self.refuse("reads an array faq off the lane's own cell");
            };
            let range = ranges.get(o).and_then(|r| self.range_bounds(r));
            if let Some(set) = sc.lane_set(x) {
                if !ranges.get(o).is_some_and(|r| self.whole_lane_range(r, set)) {
                    return self.refuse(format_args!(
                        "reads an array faq whose axis `{o}` does not run over the whole lane \
                         set `{set}`"
                    ));
                }
                binds.push((o.clone(), OutBind::Lane(set.to_string())));
                continue;
            }
            let Some((y, (lo, hi))) = sc.inner_extent(x) else {
                return self.refuse("reads an array faq off the lane's own cell");
            };
            if lo != 1 || range != Some((1, hi)) {
                return self.refuse(format_args!(
                    "reads an array faq whose axis `{o}` does not run over the range {lo}..{hi} \
                     of its subscript `{x}`"
                ));
            }
            binds.push((o.clone(), OutBind::At(Expr::Variable(y))));
        }
        self.faq_at(f, binds, sc)
    }

    /// The value of the array `faq` `f` at one element: its body with each
    /// output index bound as `binds` says (an output index along a lane set
    /// to the lane's cell, any other to an expression over the enclosing
    /// symbols), rewritten in that scope. Any other range of the `faq` (a
    /// contraction) stays a scalar `faq` over it, with the `faq`'s filter;
    /// with no contraction, a filter selects the body where it holds and
    /// the reduction's identity elsewhere, as the array `faq`'s element is.
    /// An `args` list that names only operand variables is the list of
    /// arrays the body reads (esm-spec §4.3.1) and changes nothing; any
    /// other `args`, a `key`, a `join` or `distinct` is refused: those name
    /// the output indices too, and are not rewritten here.
    fn faq_at(
        &mut self,
        f: &ExpressionNode,
        binds: Vec<(String, OutBind)>,
        sc: &LScope,
    ) -> RResult<Expr> {
        if f.key.is_some()
            || !f.args.iter().all(|a| matches!(a, Expr::Variable(_)))
            || f.join.as_ref().is_some_and(|j| !j.is_empty())
            || f.distinct == Some(true)
        {
            return self.refuse(
                "reads an array faq that carries a `key`, a `join`, `distinct`, or `args` that \
                 are not only operand variables, which a lane does not rewrite",
            );
        }
        let Some(body) = f.expr.as_deref() else {
            return self.refuse("reads an array faq with no body");
        };
        let ranges = f.ranges.clone().unwrap_or_default();
        let outs: Vec<&String> = binds.iter().map(|(o, _)| o).collect();
        let contracted: HashMap<String, crate::types::RangeSpec> = ranges
            .into_iter()
            .filter(|(k, _)| !outs.contains(&k))
            .collect();
        for r in contracted.values() {
            let parents = match r {
                crate::types::RangeSpec::IndexSetRef { of: Some(of), .. }
                | crate::types::RangeSpec::RaggedDyn { of, .. } => of.as_slice(),
                _ => &[],
            };
            if parents.iter().any(|p| outs.contains(&p)) {
                return self.refuse(
                    "reads an array faq whose contraction runs over a set of one of its output \
                     indices",
                );
            }
        }
        let mut inner = sc.clone();
        let bound: Vec<&String> = outs.iter().copied().chain(contracted.keys()).collect();
        inner.unbind(&bound);
        let keys: Vec<&String> = contracted.keys().collect();
        let fresh: Vec<&Expr> = binds
            .iter()
            .filter_map(|(_, b)| match b {
                OutBind::At(e) => Some(e),
                OutBind::Lane(_) => None,
            })
            .collect();
        let captured = inner.captured(&keys).is_some()
            || fresh
                .iter()
                .any(|e| mentions(e, &mut |x| keys.iter().any(|k| *k == x)));
        if captured {
            return self
                .refuse("reads an array faq whose contraction rebinds one of its subscripts");
        }
        for (o, b) in binds {
            match b {
                OutBind::Lane(set) => inner.lane_syms.push((o, set)),
                OutBind::At(e) => inner.alias.push((o, e)),
            }
        }
        inner.inner.extend(keys.into_iter().cloned());
        let new_body = self.expr(body, &inner)?;
        if contracted.is_empty() {
            let Some(flt) = f.filter.as_deref() else {
                return Ok(new_body);
            };
            // The element where the filter holds, else the reduction's
            // identity, as the whole-domain program selects it.
            let Ok(oplus) =
                crate::faq::effective_reduce_kind(f.semiring.as_deref(), f.reduce.as_deref())
            else {
                return self.refuse("reads an array faq with an unknown reduction");
            };
            let flt = self.expr(flt, &inner)?;
            return Ok(Expr::operator(ExpressionNode {
                op: "ifelse".to_string(),
                args: vec![flt, new_body, Expr::Number(oplus.identity())],
                ..Default::default()
            }));
        }
        let mut n = ExpressionNode::clone(f);
        n.output_idx = Some(Vec::new());
        n.ranges = Some(contracted);
        n.expr = Some(Box::new(new_body));
        if let Some(flt) = f.filter.as_deref() {
            n.filter = Some(Box::new(self.expr(flt, &inner)?));
        }
        Ok(Expr::operator(n))
    }

    /// The `[lo, hi]` an output or contraction range runs over, when it is
    /// a unit-step interval or a whole interval index set.
    fn range_bounds(&self, r: &crate::types::RangeSpec) -> Option<(i64, i64)> {
        match r {
            crate::types::RangeSpec::Interval([lo, hi]) => Some((*lo, *hi)),
            crate::types::RangeSpec::IndexSetRef { from, of: None } => {
                self.sizes.get(from).map(|&n| (1, n))
            }
            _ => None,
        }
    }
}

fn read_mentions_lane(e: &Expr) -> bool {
    mentions(e, &mut |x| x.starts_with("__cell_"))
}

struct Rewritten {
    rhs: Vec<RhsRule>,
    observed: Vec<AlgebraicRule>,
    gathers: Vec<Expr>,
    /// The state-free observeds of `t` a per-lane-times rewrite found no
    /// lane form for, and why: the rewrite is to be run again with them
    /// whole-domain ([`Timing::new`]).
    fallen: Vec<(String, String)>,
}

/// Which observeds a rewrite computes per lane, and how it reads `t`.
struct Timing {
    /// A rewrite for lanes each at its own time (U19).
    timed: bool,
    /// The states and the observeds that become lane blocks.
    lane_vars: HashSet<String>,
    /// The 0-d observeds computed once per lane.
    lane_scalars: HashSet<String>,
    /// The observeds a lane computes for itself.
    dependent: HashSet<String>,
    /// The observeds that depend on a state.
    state: HashSet<String>,
}

impl Timing {
    /// The one-time rewrite (`timed` false: every lane at the call's `t`)
    /// computes per lane the observeds that depend on a state; the
    /// per-lane-times rewrite also those that depend on `t`, 0-d ones
    /// included, except the state-free ones in `whole`, which stay
    /// whole-domain. `observed` is the program's observed rules in their
    /// lane forms ([`lane_forms`]).
    fn new(
        compiled: &ProgramModel,
        observed: &[AlgebraicRule],
        axes: &HashMap<String, Vec<Option<String>>>,
        timed: bool,
        whole: &HashSet<String>,
    ) -> Self {
        let state = super::tile::state_dependent(compiled);
        let mut dependent = if timed {
            lane_dependent(compiled)
        } else {
            state.clone()
        };
        dependent.retain(|v| !whole.contains(v));
        let mut lane_vars: HashSet<String> = compiled.var_shapes.keys().cloned().collect();
        let mut lane_scalars = HashSet::new();
        for rule in observed {
            match rule {
                AlgebraicRule::ArrayLoop { var, .. } if dependent.contains(var) => {
                    lane_vars.insert(var.clone());
                }
                AlgebraicRule::Scalar { var, .. }
                    if timed
                        && dependent.contains(var)
                        && axes.get(var).is_none_or(Vec::is_empty) =>
                {
                    lane_scalars.insert(var.clone());
                }
                _ => {}
            }
        }
        Timing {
            timed,
            lane_vars,
            lane_scalars,
            dependent,
            state,
        }
    }
}

/// The program's observed rules in their lane forms: a wholesale array
/// observed of `t` or of a state, `x = faq{output_idx…}` (a rule the
/// compiler keeps whole, the `faq` its body), becomes the loop over its
/// output that reads the `faq` at the loop's symbols, `x[o…] =
/// index(faq{…}, o…)`, which the rewrite reads at the lane's cell (an array
/// `faq` read, API_SPEC §5.8). Every other rule is unchanged.
fn lane_forms(
    compiled: &ProgramModel,
    dependent: &HashSet<String>,
    axes: &HashMap<String, Vec<Option<String>>>,
    sizes: &HashMap<String, i64>,
) -> Vec<AlgebraicRule> {
    compiled
        .observed_rules
        .iter()
        .map(|rule| match rule {
            AlgebraicRule::Scalar { var, body, .. } if dependent.contains(var) => {
                wholesale_loop(var, body, axes, sizes)
                    .or_else(|| elementwise_loop(var, body, axes, sizes))
                    .unwrap_or_else(|| rule.clone())
            }
            _ => rule.clone(),
        })
        .collect()
}

/// `var = e`, `e` elementwise over arrays aligned by index-set name (esm-spec
/// §4.3.4: `x = 5e-7 * n`), as the loop `var[o…] = e[o…]`: each bare array
/// operand read at the loop symbols of its own sets. `None` when `e` holds
/// anything but elementwise operators, scalars and arrays whose sets are
/// each one of `var`'s, or `var`'s sets do not all span their index sets.
fn elementwise_loop(
    var: &str,
    body: &Expr,
    axes: &HashMap<String, Vec<Option<String>>>,
    sizes: &HashMap<String, i64>,
) -> Option<AlgebraicRule> {
    let var_axes = axes.get(var).filter(|a| !a.is_empty())?;
    let sets: Vec<&str> = var_axes
        .iter()
        .map(|a| a.as_deref())
        .collect::<Option<_>>()?;
    let output_ranges: Vec<(i64, i64)> = sets
        .iter()
        .map(|s| sizes.get(*s).map(|&n| (1, n)))
        .collect::<Option<_>>()?;
    let loops: Vec<String> = (0..sets.len()).map(|d| format!("__whole{d}")).collect();
    fn at(
        e: &Expr,
        sets: &[&str],
        loops: &[String],
        axes: &HashMap<String, Vec<Option<String>>>,
    ) -> Option<Expr> {
        match e {
            Expr::Number(_) | Expr::Integer(_) => Some(e.clone()),
            Expr::Variable(v) => match axes.get(v).filter(|a| !a.is_empty()) {
                None => Some(e.clone()),
                Some(a) => {
                    let mut args = vec![e.clone()];
                    for set in a {
                        let d = sets.iter().position(|s| Some(*s) == set.as_deref())?;
                        args.push(Expr::Variable(loops[d].clone()));
                    }
                    Some(op_node("index", args))
                }
            },
            // A scalar literal with a unit.
            Expr::Operator(n)
                if n.op == "const"
                    && n.args.is_empty()
                    && n.value.as_ref().is_some_and(|v| v.is_number()) =>
            {
                Some(e.clone())
            }
            Expr::Operator(n)
                if n.op != "broadcast" && crate::op_registry::is_elementwise_node(n) =>
            {
                let mut ok = true;
                let out = n.map_children(&mut |c| {
                    at(c, sets, loops, axes).unwrap_or_else(|| {
                        ok = false;
                        c.clone()
                    })
                });
                ok.then(|| Expr::operator(out))
            }
            _ => None,
        }
    }
    let body = at(body, &sets, &loops, axes)?;
    Some(AlgebraicRule::ArrayLoop {
        var: var.to_string(),
        output_idx_names: loops,
        output_ranges,
        body: std::sync::Arc::new(body),
    })
}

/// The index set each output axis of the array `faq` `body` runs over: the
/// set a range is `from`, or the one interval index set of the length of a
/// range `[1, n]`; `None` when one has no such set.
fn faq_output_sets(body: &Expr, sizes: &HashMap<String, i64>) -> Option<Vec<String>> {
    let Expr::Operator(f) = body else {
        return None;
    };
    let outs = f.output_idx.as_deref().filter(|o| !o.is_empty())?;
    let ranges = f.ranges.as_ref()?;
    if f.op != "faq" {
        return None;
    }
    outs.iter()
        .map(|o| match ranges.get(o)? {
            crate::types::RangeSpec::IndexSetRef { from, of: None } => Some(from.clone()),
            crate::types::RangeSpec::Interval([1, n]) => {
                let mut c = sizes.iter().filter(|(_, m)| **m == *n).map(|(k, _)| k);
                match (c.next(), c.next()) {
                    (Some(k), None) => Some(k.clone()),
                    _ => None,
                }
            }
            _ => None,
        })
        .collect()
}

/// `var = f`, `f` an array `faq` over the whole of each of `var`'s axes, as
/// the loop `var[o…] = index(f, o…)`; `None` for any other body.
fn wholesale_loop(
    var: &str,
    body: &Expr,
    axes: &HashMap<String, Vec<Option<String>>>,
    sizes: &HashMap<String, i64>,
) -> Option<AlgebraicRule> {
    let Expr::Operator(f) = body else {
        return None;
    };
    let outs = f.output_idx.as_deref()?;
    let var_axes = axes.get(var)?;
    if f.op != "faq" || outs.is_empty() || outs.len() != var_axes.len() {
        return None;
    }
    let ranges = f.ranges.as_ref()?;
    let mut output_ranges = Vec::with_capacity(outs.len());
    for (o, set) in outs.iter().zip(var_axes) {
        let n = match ranges.get(o)? {
            crate::types::RangeSpec::IndexSetRef { from, of: None }
                if set.as_deref() == Some(from.as_str()) =>
            {
                *sizes.get(from)?
            }
            crate::types::RangeSpec::Interval([1, hi]) => *hi,
            _ => return None,
        };
        output_ranges.push((1, n));
    }
    let loops: Vec<String> = (0..outs.len()).map(|d| format!("__whole{d}")).collect();
    let read = Expr::operator(ExpressionNode {
        op: "index".to_string(),
        args: std::iter::once(body.clone())
            .chain(loops.iter().map(|l| Expr::Variable(l.clone())))
            .collect(),
        ..Default::default()
    });
    Some(AlgebraicRule::ArrayLoop {
        var: var.to_string(),
        output_idx_names: loops,
        output_ranges,
        body: std::sync::Arc::new(read),
    })
}

#[allow(clippy::too_many_arguments)]
fn rewrite(
    compiled: &ProgramModel,
    lane_rules: &[AlgebraicRule],
    axes: &HashMap<String, Vec<Option<String>>>,
    timing: &Timing,
    no_hoist: &HashSet<String>,
    sets: &[String],
    sizes: &HashMap<String, i64>,
    cells: bool,
    capacity: i64,
) -> RResult<Rewritten> {
    let (lane_vars, dependent) = (&timing.lane_vars, &timing.dependent);
    let mut rw = Rewriter {
        axes,
        lane_vars,
        lane_scalars: &timing.lane_scalars,
        timed: timing.timed,
        no_hoist,
        sets,
        sizes,
        cells,
        capacity,
        rule: String::new(),
        gathers: Vec::new(),
    };
    // The lane box of a rule writing `var` over `syms`/`ranges`.
    let lane_box = |rw: &Rewriter,
                    var: &str,
                    syms: &[String],
                    ranges: &[(i64, i64)]|
     -> RResult<(LScope, Vec<String>, Vec<(i64, i64)>)> {
        let var_axes = axes.get(var).cloned().unwrap_or_default();
        if var_axes.len() != syms.len() {
            return rw.refuse(format_args!(
                "writes `{var}` through a reshaped left-hand side"
            ));
        }
        let mut sc = LScope::default();
        let mut out_syms = vec![LANE.to_string()];
        let mut out_ranges = vec![(1, capacity)];
        for (d, s) in syms.iter().enumerate() {
            match var_axes[d]
                .as_deref()
                .filter(|set| sets.iter().any(|x| x == set))
            {
                Some(set) => {
                    let n = sizes.get(set).copied().unwrap_or(-1);
                    if ranges[d] != (1, n) {
                        return rw.refuse(format_args!(
                            "writes `{var}` over {}..{} of the lane set `{set}`, not the whole of it",
                            ranges[d].0, ranges[d].1
                        ));
                    }
                    sc.lane_syms.push((s.clone(), set.to_string()));
                }
                None => {
                    if cells {
                        return rw.refuse(format_args!(
                            "writes `{var}` along `{}`, which is not one of the lane's sets",
                            var_axes[d].as_deref().unwrap_or("an unnamed axis")
                        ));
                    }
                    sc.inner.push(s.clone());
                    sc.extents.push((s.clone(), ranges[d]));
                    out_syms.push(s.clone());
                    out_ranges.push(ranges[d]);
                }
            }
        }
        Ok((sc, out_syms, out_ranges))
    };
    // The observeds first: a per-lane-times rewrite that finds no lane form
    // for a state-free observed of `t` records it and goes on, and the
    // caller runs it again with that observed whole-domain.
    let mut observed = Vec::new();
    let mut fallen = Vec::new();
    for (rule, lane_rule) in compiled.observed_rules.iter().zip(lane_rules) {
        let var = match rule {
            AlgebraicRule::Scalar { var, .. }
            | AlgebraicRule::ArrayLoop { var, .. }
            | AlgebraicRule::Recurrence { var, .. } => var,
        };
        if !dependent.contains(var) {
            observed.push(rule.clone());
            continue;
        }
        rw.rule = var.clone();
        let lane = match lane_rule {
            AlgebraicRule::ArrayLoop {
                output_idx_names,
                output_ranges,
                body,
                ..
            } if lane_vars.contains(var) => lane_box(&rw, var, output_idx_names, output_ranges)
                .and_then(|(sc, syms, ranges)| {
                    Ok(AlgebraicRule::ArrayLoop {
                        var: var.clone(),
                        output_idx_names: syms,
                        output_ranges: ranges,
                        body: std::sync::Arc::new(rw.expr(body, &sc)?),
                    })
                }),
            AlgebraicRule::Scalar { body, .. }
                if !timing.timed && axes.get(var).is_none_or(Vec::is_empty) =>
            {
                rw.expr(body, &LScope::default()).and_then(|body| {
                    if mentions(&body, &mut |x| x.starts_with("__cell_") || x == LANE) {
                        return rw.refuse("is a scalar observed that reads the lane state");
                    }
                    Ok(rule.clone())
                })
            }
            AlgebraicRule::Scalar { body, .. } if axes.get(var).is_none_or(Vec::is_empty) => {
                // A scalar observed that depends on a state or on `t` holds
                // one value per lane (U19).
                rw.expr(body, &LScope::default())
                    .map(|body| AlgebraicRule::ArrayLoop {
                        var: var.clone(),
                        output_idx_names: vec![LANE.to_string()],
                        output_ranges: vec![(1, capacity)],
                        body: std::sync::Arc::new(body),
                    })
            }
            _ => rw.refuse("is an observed of a state or of `t` with no lane form"),
        };
        match lane {
            Ok(r) => observed.push(r),
            Err(why) if timing.timed && !timing.state.contains(var) => {
                fallen.push((var.clone(), why.to_string()));
                observed.push(rule.clone());
            }
            Err(e) => return Err(e),
        }
    }
    let mut rhs = Vec::new();
    for rule in &compiled.rhs_rules {
        let RhsRule::ArrayLoop {
            var_name,
            output_idx_names,
            output_ranges,
            lhs_idx_exprs,
            body,
            contract_names,
            contract_dims,
            reduce,
            filter,
        } = rule
        else {
            return Err(refused(
                "lane: a scalar or per-cell rule has no lane form".to_string(),
            ));
        };
        rw.rule = format!("D({var_name})");
        let identity = lhs_idx_exprs.len() == output_idx_names.len()
            && lhs_idx_exprs
                .iter()
                .zip(output_idx_names)
                .all(|(e, s)| matches!(e, Expr::Variable(x) if x == s));
        if !identity {
            return rw.refuse("writes through a shifted or computed left-hand side");
        }
        let (mut sc, syms, ranges) = lane_box(&rw, var_name, output_idx_names, output_ranges)?;
        sc.inner.extend(contract_names.iter().cloned());
        let body = rw.expr(body, &sc)?;
        let filter = match filter {
            Some(f) => Some(Box::new(rw.expr(f, &sc)?)),
            None => None,
        };
        rhs.push(RhsRule::ArrayLoop {
            var_name: var_name.clone(),
            lhs_idx_exprs: syms.iter().map(|s| Expr::Variable(s.clone())).collect(),
            output_idx_names: syms,
            output_ranges: ranges,
            body: Box::new(body),
            contract_names: contract_names.clone(),
            contract_dims: contract_dims.clone(),
            reduce: *reduce,
            filter,
        });
    }
    Ok(Rewritten {
        rhs,
        observed,
        gathers: rw.gathers,
        fallen,
    })
}

/// Whether any rule of the program reads `t` (by name; a loop symbol
/// spelled `t` counts too, which only costs a second program).
fn reads_t(compiled: &ProgramModel) -> bool {
    let t = |e: &Expr| mentions(e, &mut |x| x == "t");
    compiled.rhs_rules.iter().any(|r| match r {
        RhsRule::ArrayLoop { body, filter, .. } => t(body) || filter.as_deref().is_some_and(t),
        RhsRule::Scalar { body, .. } | RhsRule::IndexedScalar { body, .. } => t(body),
    }) || compiled.observed_rules.iter().any(|r| match r {
        AlgebraicRule::Scalar { body, .. }
        | AlgebraicRule::ArrayLoop { body, .. }
        | AlgebraicRule::Recurrence { body, .. } => t(body),
    })
}

/// The observeds that depend on a state or on `t`, directly or through
/// other observeds (rules are in dependency order).
fn lane_dependent(compiled: &ProgramModel) -> HashSet<String> {
    let mut dep = super::tile::state_dependent(compiled);
    for rule in &compiled.observed_rules {
        let (var, body) = match rule {
            AlgebraicRule::Scalar { var, body, .. }
            | AlgebraicRule::ArrayLoop { var, body, .. }
            | AlgebraicRule::Recurrence { var, body, .. } => (var, body),
        };
        let free = crate::expression::free_variables(body);
        if free.iter().any(|n| n == "t" || dep.contains(n)) {
            dep.insert(var.clone());
        }
    }
    dep
}

/// The per-lane-times rewrite (U19), run again with each state-free
/// observed of `t` it finds no lane form for whole-domain, together with
/// every observed of `t` that one reads (a whole-domain rule reads whole
/// arrays), until none falls. The rewrite and how its program reads `t`;
/// the error of a rewrite that cannot be per lane at all.
fn per_lane_times(
    compiled: &ProgramModel,
    of_t: &HashSet<String>,
    mut rewrite_with: impl FnMut(&HashSet<String>) -> RResult<Rewritten>,
) -> Result<(Rewritten, LaneTime), String> {
    let bodies: HashMap<&str, &Expr> = compiled
        .observed_rules
        .iter()
        .map(|r| match r {
            AlgebraicRule::Scalar { var, body, .. }
            | AlgebraicRule::ArrayLoop { var, body, .. }
            | AlgebraicRule::Recurrence { var, body, .. } => (var.as_str(), &**body),
        })
        .collect();
    let mut whole: HashSet<String> = HashSet::new();
    let mut why: Vec<String> = Vec::new();
    let fall = |var: String, whole: &mut HashSet<String>| {
        let mut stack = vec![var];
        while let Some(v) = stack.pop() {
            if !whole.insert(v.clone()) {
                continue;
            }
            if let Some(body) = bodies.get(v.as_str()) {
                for x in crate::expression::free_variables(body) {
                    if of_t.contains(&x) && !whole.contains(&x) {
                        stack.push(x);
                    }
                }
            }
        }
    };
    loop {
        let rw = rewrite_with(&whole).map_err(|e| e.to_string())?;
        if rw.fallen.is_empty() {
            let timing = if whole.is_empty() {
                LaneTime::PerLane
            } else {
                LaneTime::Once(Some(why.join("; ")))
            };
            return Ok((rw, timing));
        }
        for (var, msg) in rw.fallen {
            why.push(msg);
            fall(var, &mut whole);
        }
    }
}

pub(super) fn build(
    prog: &RhsProgram,
    kind: &LaneKind,
    capacity: usize,
) -> Result<LaneProgram, SimulateError> {
    let compiled = &*prog.inner.model;
    let precision = plain_precision(compiled, "lane")?;
    if capacity == 0 {
        return Err(build_error(
            "`lanes`: capacity must be at least 1".to_string(),
        ));
    }
    let sets: Vec<String> = kind.sets().to_vec();
    let sizes = index_set_sizes(prog.inner.flat());
    let box_invalid =
        |m: String| super::range_error(crate::diagnostic::codes::RANGE_BOX_INVALID, m);
    for s in &sets {
        if !sizes.contains_key(s) {
            return Err(box_invalid(format!(
                "`lanes`: `{s}` is not an interval index set of this program"
            )));
        }
    }
    let cells_mode = matches!(kind, LaneKind::Cells { .. });
    // Every axis's index-set name (the decomposition is empty: lanes cut
    // nothing, they only name sets).
    let infos = var_infos(prog, &Decomposition::default());
    let mut axes: HashMap<String, Vec<Option<String>>> = infos
        .iter()
        .map(|(k, v)| {
            (
                k.clone(),
                v.axes
                    .iter()
                    .map(|a| match a {
                        AxisSpec::Whole { set } => set.clone(),
                        AxisSpec::Cut { set, .. } => Some(set.clone()),
                    })
                    .collect(),
            )
        })
        .collect();
    // An observed declared with no shape has the axes the build gave it
    // (an array observed the planner writes `x = faq{…}` or `x = 5e-7 * n`
    // for), which the rewrite reads by index-set name. One with no axes
    // recorded anywhere that is defined whole by an array `faq` (a
    // derivative the planner writes) has those its output runs over.
    for rule in &compiled.observed_rules {
        let var = observed_var(rule);
        if !axes.get(var).is_none_or(Vec::is_empty) {
            continue;
        }
        let found = match (prog.inner.shapes.axes(var), rule) {
            (Some(a), _) => Some(a.to_vec()),
            (None, AlgebraicRule::Scalar { body, .. }) => faq_output_sets(body, &sizes),
            _ => None,
        };
        if let Some(a) = found {
            axes.insert(var.to_string(), a.into_iter().map(Some).collect());
        }
    }
    // Every state in `u` and `aux` carries every lane set; for `cells` the
    // lane sets are exactly the written variables' index sets.
    for name in prog.inner.writes.iter().chain(&prog.inner.aux) {
        let var_sets: Vec<String> = axes[name].iter().flatten().cloned().collect();
        if let Some(s) = sets.iter().find(|s| !var_sets.contains(s)) {
            return Err(box_invalid(format!(
                "`lanes`: the state `{name}` does not carry the lane set `{s}`"
            )));
        }
        if cells_mode
            && prog.inner.writes.contains(name)
            && let Some(s) = var_sets.iter().find(|s| !sets.contains(s))
        {
            return Err(box_invalid(format!(
                "`lanes`: `cells` lanes name every index set of the written variables, and \
                 `{name}` also has `{s}`"
            )));
        }
    }
    // U19: the program reads `t` per lane and computes per lane every
    // observed that depends on a state or on `t`, so one program serves
    // every batch, at one time or at several, and no observed of `t` is
    // computed over the whole domain per call. A state-free observed of `t`
    // with no lane form stays whole-domain (with every observed of `t` it
    // reads), one value per call; the program then serves a batch at one
    // time only, and a batch at mixed times is an error naming why.
    let no_hoist = lane_dependent(compiled);
    let lane_rules = lane_forms(compiled, &no_hoist, &axes, &sizes);
    let cap = capacity as i64;
    let rewrite_with = |timed: bool, whole: &HashSet<String>| {
        let timing = Timing::new(compiled, &lane_rules, &axes, timed, whole);
        rewrite(
            compiled,
            &lane_rules,
            &axes,
            &timing,
            &no_hoist,
            &sets,
            &sizes,
            cells_mode,
            cap,
        )
    };
    let (rw, timing) = if reads_t(compiled) {
        per_lane_times(compiled, &no_hoist, |whole| rewrite_with(true, whole)).or_else(|why| {
            Ok::<_, SimulateError>((
                rewrite_with(false, &HashSet::new())?,
                LaneTime::Once(Some(why)),
            ))
        })?
    } else {
        (rewrite_with(false, &HashSet::new())?, LaneTime::Once(None))
    };

    // The lane layout: u, then aux, each block `[capacity, inner…]`.
    let mut entries = Vec::new();
    for (input, names) in [
        (TileInput::U, &prog.inner.writes),
        (TileInput::Aux, &prog.inner.aux),
    ] {
        for name in names {
            let vs = &compiled.var_shapes[name];
            let var_axes = &axes[name];
            if cells_mode
                && var_axes
                    .iter()
                    .any(|a| a.as_deref().is_none_or(|s| !sets.iter().any(|x| x == s)))
                && !vs.shape.is_empty()
            {
                return Err(refused(format!(
                    "lane: `{name}` has an axis outside the lane's sets {sets:?}"
                )));
            }
            let mut storage = vec![(1, cap)];
            let mut index_sets = vec!["lane".to_string()];
            for (d, a) in var_axes.iter().enumerate() {
                if a.as_deref().is_some_and(|s| sets.iter().any(|x| x == s)) {
                    continue;
                }
                let o = vs.origin[d];
                storage.push((o, o + vs.shape[d] as i64 - 1));
                index_sets.push(a.clone().unwrap_or_default());
            }
            if vs.shape.is_empty() {
                return Err(refused(format!(
                    "lane: `{name}` is a 0-d state, which no lane holds"
                )));
            }
            entries.push((name.clone(), input, index_sets, storage.clone(), storage));
        }
    }
    let layout = Blocks::build(entries);

    // The internal state: u, aux, the lane cells, each lane's time, then
    // the hoisted inputs.
    let mut var_shapes: IndexMap<String, VarShape> = IndexMap::new();
    for v in &layout.vars {
        let flat_offset = match v.input {
            TileInput::U => v.base,
            TileInput::Aux => layout.u_len + v.base,
        };
        var_shapes.insert(
            v.name.clone(),
            VarShape {
                shape: v
                    .storage
                    .iter()
                    .map(|(lo, hi)| (hi - lo + 1) as usize)
                    .collect(),
                origin: v.storage.iter().map(|r| r.0).collect(),
                flat_offset,
            },
        );
    }
    let add = |shapes: &mut IndexMap<String, VarShape>, name: String, at: &mut usize| {
        shapes.insert(
            name,
            VarShape {
                shape: vec![capacity],
                origin: vec![1],
                flat_offset: *at,
            },
        );
        *at += capacity;
    };
    let n_inputs = rw.gathers.len();
    let mut at = layout.u_len + layout.aux_len;
    for s in &sets {
        add(&mut var_shapes, cell_var(s), &mut at);
    }
    add(&mut var_shapes, LANE_T.to_string(), &mut at);
    for k in 0..n_inputs {
        add(&mut var_shapes, input_var(k), &mut at);
    }
    let held: HashSet<String> = prog
        .inner
        .aux
        .iter()
        .cloned()
        .chain(sets.iter().map(|s| cell_var(s)))
        .chain(std::iter::once(LANE_T.to_string()))
        .chain((0..n_inputs).map(input_var))
        .collect();
    let empty = TileLowering {
        states: Vec::new(),
        observed: FxHashMap::default(),
        names: Vec::new(),
    };
    let build_tape = |c: &ArrayCompiled| -> Result<TapeProgram, SimulateError> {
        let _env = compiled.precision.enter();
        c.build_tile_tape(&empty)
            .map_err(|d| declined_error(&d, "lane"))
    };
    let gathers = rw.gathers;
    // Only the observeds the rewritten rules read: a state-free observed
    // every read of which is hoisted lives in the gather program alone.
    let roots: Vec<&Expr> = rw.rhs.iter().flat_map(rhs_exprs).collect();
    let observed = reached(roots, rw.observed);
    let lane_tape = build_tape(&shell(compiled, var_shapes, rw.rhs, observed, held))?;

    // The gather program: one rule per hoisted read, writing its lanes.
    let mut gshapes: IndexMap<String, VarShape> = IndexMap::new();
    let mut gat = 0usize;
    for k in 0..n_inputs {
        add(&mut gshapes, input_var(k), &mut gat);
    }
    for s in &sets {
        add(&mut gshapes, cell_var(s), &mut gat);
    }
    // The gather program's `du` is the inputs alone, so the cells follow
    // them in its state; the call passes the cells there.
    let grules: Vec<RhsRule> = gathers
        .iter()
        .enumerate()
        .map(|(k, g)| RhsRule::ArrayLoop {
            var_name: input_var(k),
            output_idx_names: vec![LANE.to_string()],
            output_ranges: vec![(1, cap)],
            lhs_idx_exprs: vec![Expr::Variable(LANE.to_string())],
            body: Box::new(g.clone()),
            contract_names: Vec::new(),
            contract_dims: Vec::new(),
            reduce: crate::faq::ReduceKind::Sum,
            filter: None,
        })
        .collect();
    let gobserved = reached(
        gathers.iter().collect(),
        compiled
            .observed_rules
            .iter()
            .filter(|r| !no_hoist.contains(observed_var(r)))
            .cloned()
            .collect(),
    );
    let gheld: HashSet<String> = sets.iter().map(|s| cell_var(s)).collect();
    let gather_tape = if n_inputs == 0 {
        build_tape(&shell(compiled, gshapes, Vec::new(), Vec::new(), gheld))?
    } else {
        build_tape(&shell(compiled, gshapes, grules, gobserved, gheld))?
    };
    let inputs = InputPrecisions::new(&layout, &compiled.param_names, &compiled.precision);
    let slot_of = [
        slot_map(&lane_tape, &prog.inner.slots)?,
        slot_map(&gather_tape, &prog.inner.slots)?,
    ];
    let gather = Arc::new(gather_tape);
    Ok(LaneProgram {
        inner: Arc::new(LaneInner {
            id: next_program_id(),
            prog: Arc::new(lane_tape),
            shared: Shared::new(&gather),
            slot_of,
            timing,
            layout: layout.lane_public(&sets, capacity),
            blocks: layout,
            default_set: prog.default_forcing(),
            capacity,
            extents: sets.iter().map(|s| sizes[s]).collect(),
            sets,
            n_inputs,
            n_params: compiled.param_names.len(),
            inputs,
            declared: Arc::clone(&prog.inner.declared),
            precision,
        }),
    })
}

fn observed_var(rule: &AlgebraicRule) -> &str {
    match rule {
        AlgebraicRule::Scalar { var, .. }
        | AlgebraicRule::ArrayLoop { var, .. }
        | AlgebraicRule::Recurrence { var, .. } => var,
    }
}

/// The expressions of a right-hand-side rule.
fn rhs_exprs(rule: &RhsRule) -> Vec<&Expr> {
    match rule {
        RhsRule::ArrayLoop { body, filter, .. } => {
            std::iter::once(&**body).chain(filter.as_deref()).collect()
        }
        RhsRule::Scalar { body, .. } | RhsRule::IndexedScalar { body, .. } => vec![body],
    }
}

/// The rules of `observed` (in dependency order) that `roots` read,
/// directly or through other observeds, in their order.
fn reached(roots: Vec<&Expr>, observed: Vec<AlgebraicRule>) -> Vec<AlgebraicRule> {
    let mut need: HashSet<String> = HashSet::new();
    for e in roots {
        need.extend(crate::expression::free_variables(e));
    }
    let mut keep = vec![false; observed.len()];
    for (k, rule) in observed.iter().enumerate().rev() {
        if !need.contains(observed_var(rule)) {
            continue;
        }
        keep[k] = true;
        let body = match rule {
            AlgebraicRule::Scalar { body, .. }
            | AlgebraicRule::ArrayLoop { body, .. }
            | AlgebraicRule::Recurrence { body, .. } => body,
        };
        need.extend(crate::expression::free_variables(body));
    }
    observed
        .into_iter()
        .zip(keep)
        .filter_map(|(r, k)| k.then_some(r))
        .collect()
}

fn op_node(op: &str, args: Vec<Expr>) -> Expr {
    Expr::operator(ExpressionNode {
        op: op.to_string(),
        args,
        ..Default::default()
    })
}

/// `index(makearray(regions, values), subs…)` as region membership:
/// `ifelse(in_k, value_k at subs, …ifelse(in_1, value_1 at subs, 0))`, the
/// last region holding the element winning (esm-spec §4.3.2). A region value
/// is a scalar expression (the same at every element) or an array `faq`
/// whose output indices span either every dimension of its region or only
/// its non-singleton ones, starting at its ranges' lower bounds; it is read
/// at `sub − lo + start` on each dimension it spans. Anything else is an
/// error, which the caller refuses.
///
/// Inside a region one cell thick along a lane set (`lo == hi`), the lane's
/// coordinate there is `lo`, so a read of a state or array observed at the
/// literal `lo` on that axis is the read at the lane's own subscript, and is
/// written so (the lane rewrite reads a state only at its lane's cell).
fn membership_read(
    regions: &[Vec<[RegionBound; 2]>],
    values: &[Expr],
    subs: &[Expr],
    lane_of: &[Option<String>],
    axes: &HashMap<String, Vec<Option<String>>>,
) -> Result<Expr, String> {
    let int = |k: i64| Expr::Integer(k);
    let mut out = Expr::Number(0.0);
    for (region, value) in regions.iter().zip(values) {
        if region.len() != subs.len() {
            return Err("reads a makearray at the wrong rank".into());
        }
        let mut bounds = Vec::with_capacity(region.len());
        for b in region {
            let Some(lh) = crate::types::region_bounds(b) else {
                return Err("holds a makearray with a symbolic region bound".into());
            };
            bounds.push(lh);
        }
        let mut conds = Vec::new();
        for (s, [lo, hi]) in subs.iter().zip(&bounds) {
            if lo == hi {
                conds.push(op_node("==", vec![s.clone(), int(*lo)]));
            } else {
                conds.push(op_node(">=", vec![s.clone(), int(*lo)]));
                conds.push(op_node("<=", vec![s.clone(), int(*hi)]));
            }
        }
        // The lane sets this region is one cell thick along: (set, lo, sub).
        let thin: Vec<(&str, i64, &Expr)> = (0..subs.len())
            .filter_map(|d| {
                let set = lane_of[d].as_deref()?;
                (bounds[d][0] == bounds[d][1]).then_some((set, bounds[d][0], &subs[d]))
            })
            .collect();
        let value = &retarget_thin(value, &thin, axes);
        let read = match value {
            Expr::Operator(f)
                if f.op == "faq" && f.output_idx.as_ref().is_some_and(|o| !o.is_empty()) =>
            {
                let outs = f.output_idx.as_deref().unwrap_or_default();
                let dims: Vec<usize> = if outs.len() == region.len() {
                    (0..region.len()).collect()
                } else {
                    (0..region.len())
                        .filter(|&d| bounds[d][0] != bounds[d][1])
                        .collect()
                };
                if dims.len() != outs.len() {
                    return Err("holds a faq region value that does not fit its region".into());
                }
                // The value's element at the read: its body with each output
                // index renamed to the subscript, shifted onto the value's
                // own range (`sub - lo + start`). Inside the region's
                // condition the subscript lies in the region, so the value's
                // range need not span the lane set.
                let ranges = f.ranges.clone().unwrap_or_default();
                let mut renames: HashMap<String, Expr> = HashMap::new();
                for (o, &d) in outs.iter().zip(&dims) {
                    let start = match ranges.get(o) {
                        Some(crate::types::RangeSpec::Interval([lo, _])) => *lo,
                        Some(crate::types::RangeSpec::Strided([lo, _, _])) => *lo,
                        _ => 1,
                    };
                    let shift = start - bounds[d][0];
                    renames.insert(
                        o.clone(),
                        if shift == 0 {
                            subs[d].clone()
                        } else {
                            op_node("+", vec![subs[d].clone(), int(shift)])
                        },
                    );
                }
                let free: HashSet<String> = renames
                    .values()
                    .flat_map(|e| crate::binders::free_names(e, crate::binders::Binders::BODY))
                    .collect();
                let Some(body) = f.expr.as_deref() else {
                    return Err("holds a faq region value with no body".into());
                };
                let body = rename_free(body, &renames, &free)?;
                let contracted: HashMap<String, crate::types::RangeSpec> = ranges
                    .iter()
                    .filter(|(k, _)| !outs.contains(k))
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                if contracted.is_empty() && f.filter.is_none() {
                    body
                } else {
                    let mut g = (**f).clone();
                    g.output_idx = None;
                    g.ranges = Some(contracted);
                    g.expr = Some(Box::new(body));
                    if let Some(fl) = f.filter.as_deref() {
                        g.filter = Some(Box::new(rename_free(fl, &renames, &free)?));
                    }
                    Expr::operator(g)
                }
            }
            Expr::Operator(f) if f.op == "faq" || f.op == "makearray" => {
                return Err("holds an array region value a lane cannot read".into());
            }
            _ => value.clone(),
        };
        let cond = if conds.len() == 1 {
            conds.pop().expect("one")
        } else {
            op_node("and", conds)
        };
        out = op_node("ifelse", vec![cond, read, out]);
    }
    Ok(out)
}

/// `e` with every `index(v, …)` whose subscript on an axis of lane set `set`
/// is the literal `lo` of a `thin` entry read at that entry's subscript
/// instead ([`membership_read`]).
fn retarget_thin(
    e: &Expr,
    thin: &[(&str, i64, &Expr)],
    axes: &HashMap<String, Vec<Option<String>>>,
) -> Expr {
    if thin.is_empty() {
        return e.clone();
    }
    let Expr::Operator(n) = e else {
        return e.clone();
    };
    let mut out = ExpressionNode::clone(n);
    let mut f = |c: &Expr| retarget_thin(c, thin, axes);
    out = out.map_children(&mut f);
    if out.op == "index" {
        if let Some(Expr::Variable(v)) = out.args.first() {
            if let Some(ax) = axes.get(v) {
                for (p, a) in ax.iter().enumerate() {
                    let Some(set) = a.as_deref() else { continue };
                    if let Some(arg) = out.args.get_mut(p + 1) {
                        if let Some((_, _, sub)) = thin.iter().find(|(s, lo, _)| {
                            *s == set && matches!(arg, Expr::Integer(k) if k == lo)
                        }) {
                            *arg = (*sub).clone();
                        }
                    }
                }
            }
        }
    }
    Expr::operator(out)
}

/// `e` with each free variable of `renames` replaced, capture-avoiding: a
/// nested binder of a renamed name shadows it below, and one that binds a
/// name `free` (the replacements' own names) where a renamed name is free
/// would capture it, which is an error.
fn rename_free(
    e: &Expr,
    renames: &HashMap<String, Expr>,
    free: &HashSet<String>,
) -> Result<Expr, String> {
    match e {
        Expr::Variable(v) => Ok(renames.get(v).cloned().unwrap_or_else(|| e.clone())),
        Expr::Operator(n) => {
            let bound: Vec<String> = n
                .ranges
                .as_ref()
                .map(|r| r.keys().cloned().collect())
                .unwrap_or_default();
            let active: HashMap<String, Expr> = renames
                .iter()
                .filter(|(k, _)| !bound.contains(k))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
            if active.is_empty() {
                return Ok(e.clone());
            }
            if !bound.is_empty() && bound.iter().any(|b| free.contains(b)) {
                let names = crate::binders::free_names(e, crate::binders::Binders::BODY);
                if active.keys().any(|k| names.contains(k)) {
                    return Err(
                        "holds a region value whose nested binder would capture a subscript".into(),
                    );
                }
            }
            let mut err = None;
            let out = n.map_children(&mut |c: &Expr| match rename_free(c, &active, free) {
                Ok(x) => x,
                Err(m) => {
                    err.get_or_insert(m);
                    c.clone()
                }
            });
            match err {
                Some(m) => Err(m),
                None => Ok(Expr::operator(out)),
            }
        }
        _ => Ok(e.clone()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// A pointwise loss over `nlon x 3 x 2` reading a whole-domain observed
    /// of the data (each cell sums over the whole `lon` axis), an array
    /// observed of `t` that reads it, and one of `t` declared with no shape
    /// (`E = 0.5 S`).
    fn data_and_time_program(nlon: i64) -> RhsProgram {
        let r3 = json!({"i": {"from": "lon"}, "j": {"from": "lat"}, "l": {"from": "lev"}});
        let ix = |v: &str, s: &[&str]| {
            let mut args = vec![json!(v)];
            args.extend(s.iter().map(|x| json!(x)));
            json!({"op": "index", "args": args})
        };
        let doc = json!({
            "esm": "1.2.0",
            "metadata": {"name": "lane_cost", "authors": ["test"]},
            "index_sets": {
                "lon": {"kind": "interval", "size": nlon},
                "lat": {"kind": "interval", "size": 3},
                "lev": {"kind": "interval", "size": 2}
            },
            "models": {"M": {
                "variables": {
                    "A": {"type": "unknown", "units": "1", "shape": ["lon", "lat", "lev"],
                          "default": 1.0},
                    "C": {"type": "unknown", "units": "1", "shape": ["lon", "lat"]},
                    "S": {"type": "unknown", "units": "1", "shape": ["lon", "lat", "lev"]},
                    "E": {"type": "unknown", "units": "1"},
                    "k": {"type": "parameter", "units": "1/s", "default": 0.1}
                },
                "equations": [
                    {"lhs": "C", "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
                        "ranges": {"i": {"from": "lon"}, "j": {"from": "lat"}},
                        "expr": {"op": "faq", "args": [], "output_idx": [],
                            "ranges": {"m": {"from": "lon"}},
                            "expr": {"op": "/", "args": [
                                {"op": "+", "args": [1.0, {"op": "*", "args": [0.1, "m", "j"]}]},
                                {"op": "+", "args": ["i", "m"]}]}}}},
                    {"lhs": "S", "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j", "l"],
                        "ranges": r3,
                        "expr": {"op": "*", "args": [
                            {"op": "cos", "args": [{"op": "+", "args": ["t", "i", "l"]}]},
                            ix("C", &["i", "j"])]}}},
                    {"lhs": "E", "rhs": {"op": "*", "args": [0.5, "S"]}},
                    {"lhs": {"op": "faq", "args": [], "output_idx": ["i", "j", "l"], "ranges": r3,
                             "expr": {"op": "D", "args": [ix("A", &["i", "j", "l"])], "wrt": "t"}},
                     "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j", "l"], "ranges": r3,
                        "expr": {"op": "+", "args": [
                            {"op": "*", "args": [{"op": "-", "args": ["k"]},
                                ix("E", &["i", "j", "l"]), ix("A", &["i", "j", "l"])]},
                            {"op": "*", "args": [
                                {"op": "const", "args": [], "value": 0.01, "units": "1/s"},
                                ix("C", &["i", "j"])]}]}}}
                ]
            }}
        });
        let prob = crate::esm_problem(
            crate::ProblemInput::Json(&doc),
            (0.0, 1.0),
            crate::ProblemOptions {
                compiler: Some(crate::Compiler::Native),
                ..Default::default()
            },
        )
        .expect("builds");
        crate::rhs_program(&prob).expect("program")
    }

    /// The elements a call of `t` writes: every instruction past the
    /// sections primed once per parameter vector and forcing epoch.
    fn per_call_elements(t: &TapeProgram) -> usize {
        let start = (t.n_const + t.n_segment) as usize;
        let tables = t.slot_tables();
        let mut n = 0;
        for ins in &t.instrs[start..] {
            ins.for_each_def(&tables, |s| {
                let d = &t.tables.slots[s as usize];
                n += if d.scalar {
                    1
                } else {
                    d.shape.iter().product()
                };
            });
        }
        n
    }

    /// A lane call's work and a workspace's storage do not grow with the
    /// domain: an observed of `t` is computed per lane, and the whole-domain
    /// observed of the data lives once, in the shared gather context.
    #[test]
    fn a_lane_call_costs_its_lanes_not_the_domain() {
        let measure = |nlon: i64| {
            let prog = data_and_time_program(nlon);
            let lanes = prog
                .lanes(
                    LaneKind::Cells {
                        sets: vec!["lon".into(), "lat".into(), "lev".into()],
                    },
                    4,
                )
                .expect("lanes");
            let inner = &*lanes.inner;
            assert!(matches!(inner.timing, LaneTime::PerLane));
            let gather = Arc::clone(&inner.shared.lock().prog);
            (
                per_call_elements(&inner.prog),
                inner.prog.slab.total_elems,
                per_call_elements(&gather),
                gather.slab.total_elems,
            )
        };
        let (small, large) = (measure(6), measure(60));
        assert!(small.0 > 0);
        assert_eq!(small.0, large.0, "a lane call's work grows with the domain");
        assert_eq!(small.1, large.1, "a lane workspace grows with the domain");
        assert_eq!(small.2, large.2, "a gather's work grows with the domain");
        // The shared gather context holds the whole-domain observed.
        assert!(large.3 > small.3);
    }
}
