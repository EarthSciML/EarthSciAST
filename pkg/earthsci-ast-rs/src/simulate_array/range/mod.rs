//! Range-restricted and operator-restricted right-hand sides (API_SPEC §5.8,
//! RFC U3): [`RhsProgram`] and the programs it restricts to.
//!
//! * [`RhsProgram::select`] keeps the summands of each `D(x)` whose provenance
//!   (esm-libraries-spec §4.7.5) is selected and writes only the selected
//!   variables; the states it reads but does not write become a read-only
//!   `aux` input. It is a rewrite of the flattened system, recompiled.
//! * [`RhsProgram::halo`] reports how far each owned cell reaches into each
//!   state along each decomposed or face index set.
//! * [`RhsProgram::tile`] restricts a `native` program to an owned box that
//!   reads a storage box (RFC U3 §4): a re-lowering of the tape over the need
//!   boxes, with global index space, so boundary regions apply exactly where
//!   the global domain has a boundary.
//! * [`RhsProgram::lanes`] evaluates a pointwise or column operator over a run-time
//!   list of cells.
//!
//! The contract is bitwise: a tile's owned rows, and every lane, equal the
//! same program evaluated over the whole domain by the same compiler.

mod analysis;
mod forcing;
mod lanes;
mod model;
mod select;
mod tile;
mod walk;

pub use forcing::{ForcingSet, ForcingSlot, ParamSlot, RhsError, SlotKind, StateBlock};
pub use lanes::{LaneInputs, LaneProgram};
use model::ProgramModel;
pub use tile::TileProgram;

use super::tape::{CallInputs, ForcingView, TapeCtx, TapeProgram, run_tape_inputs};
use super::{ArrayCompiled, RhsCall, RhsScratch, RhsStats, evaluate_rhs_with_scratch};
use crate::flatten::{FlattenedSystem, TermOrigin};
use crate::problem::{Compiler, EsmProblem, ProgramSource};
use crate::simulate::SimulateError;
use ndarray::{ArrayD, IxDyn, ShapeBuilder};
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::marker::PhantomData;
use std::ops::RangeInclusive;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use walk::{AxisSpec, VarInfo};

/// Which terms and which variables an operator keeps (API_SPEC §5.8,
/// `select`). `None` keeps every term, or writes every state.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RhsSelection {
    /// The variables the operator writes, `W_k`, by flattened name.
    pub writes: Option<Vec<String>>,
    /// The provenance tags whose summands are kept, matched by equality
    /// against each summand's origins (esm-libraries-spec §4.7.5).
    pub terms: Option<Vec<TermOrigin>>,
}

/// One decomposed horizontal index set: its name and its period, when the
/// axis is periodic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AxisCut {
    pub index_set: String,
    pub period: Option<i64>,
}

/// The horizontal decomposition a tile cuts (RFC U3 §1): the decomposed index
/// sets and the face sets that stagger off them, `(face set, cell set)`.
/// Every other index set is whole on every tile.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Decomposition {
    pub axes: Vec<AxisCut>,
    pub faces: Vec<(String, String)>,
}

/// One tile's owned box and storage box, one inclusive range per decomposed
/// index set, in global 1-based indices; a periodic storage range is
/// unwrapped (it may run below 1 or past `N`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TileBox {
    pub owned: Vec<(String, RangeInclusive<i64>)>,
    pub storage: Vec<(String, RangeInclusive<i64>)>,
}

/// The locality a lane program evaluates over (RFC U3 §6), with the index
/// sets one lane's `cells` column names, in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaneKind {
    /// One lane per cell: `sets` are every spatial index set of the output.
    Cells { sets: Vec<String> },
    /// One lane per column: `sets` are the horizontal index sets; every other
    /// axis is whole in each lane.
    Columns { sets: Vec<String> },
}

impl LaneKind {
    /// The index sets a lane's `cells` column names.
    pub fn sets(&self) -> &[String] {
        match self {
            LaneKind::Cells { sets } | LaneKind::Columns { sets } => sets,
        }
    }
}

/// [`RhsProgram::halo`]'s report (RFC U3 §3): for each state the program
/// reads and each decomposed or face index set on its shape, keyed
/// `(variable, index set)`, how far the owned output reaches into it: `lo`
/// cells below the owned box, `hi` above it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HaloReport {
    pub reach: BTreeMap<(String, String), (i64, i64)>,
}

impl HaloReport {
    /// The `(lo, hi)` reach into `variable` along `index_set`, if reported.
    pub fn get(&self, variable: &str, index_set: &str) -> Option<(i64, i64)> {
        self.reach
            .get(&(variable.to_string(), index_set.to_string()))
            .copied()
    }
}

/// Which input a variable's block lives in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TileInput {
    /// `u`: the variables the program writes.
    U,
    /// `aux`: the states it reads but does not write.
    Aux,
}

/// One variable's block in a program's inputs (RFC U3 §5): a column-major
/// block over its storage box, first index fastest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Block {
    pub(crate) name: String,
    pub(crate) input: TileInput,
    /// Offset of the block in its input.
    pub(crate) base: usize,
    /// The index-set name of each axis (empty when the declaration names
    /// none).
    pub(crate) index_sets: Vec<String>,
    /// Inclusive storage range per axis, in global indices.
    pub(crate) storage: Vec<(i64, i64)>,
    /// Column-major strides per axis.
    pub(crate) strides: Vec<usize>,
    /// Inclusive owned range per axis: the rows a call writes (for a `u`
    /// variable).
    pub(crate) owned: Vec<(i64, i64)>,
}

/// A program's input layout as the program addresses it: `u` blocks, then
/// `aux` blocks, each in flat-layout order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Blocks {
    pub(crate) vars: Vec<Block>,
    pub(crate) u_len: usize,
    pub(crate) aux_len: usize,
}

/// One variable's block in a tile's (or a whole-domain program's) inputs
/// (API_SPEC §5.8, "Tile layout"): a column-major block over its storage box,
/// first index fastest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TileBlock {
    pub name: String,
    /// The index-set name of each axis, in shape order (empty when the
    /// declaration names none).
    pub sets: Vec<String>,
    /// Inclusive storage range per axis, in global indices.
    pub storage: Vec<(i64, i64)>,
    /// Inclusive owned range per axis: the rows a call writes. Empty for an
    /// `aux` block.
    pub owned: Vec<(i64, i64)>,
    /// 0-based offset of the block in its buffer.
    pub base: usize,
    /// Column-major strides per axis.
    pub strides: Vec<usize>,
}

impl TileBlock {
    /// The buffer slot of the global multi-index `g`, or `None` outside the
    /// storage box.
    pub fn slot(&self, g: &[i64]) -> Option<usize> {
        let mut off = self.base;
        for (d, &x) in g.iter().enumerate() {
            let (lo, hi) = *self.storage.get(d)?;
            if x < lo || x > hi {
                return None;
            }
            off += (x - lo) as usize * self.strides[d];
        }
        Some(off)
    }

    /// The number of elements in the block.
    pub fn len(&self) -> usize {
        self.storage
            .iter()
            .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
            .product()
    }

    /// Whether the block holds no element.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// A program's `u` and `aux` layout (API_SPEC §5.8): the written variables'
/// blocks, then the read-only ones, each list in flat-layout order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TileLayout {
    pub u: Vec<TileBlock>,
    pub aux: Vec<TileBlock>,
    pub u_len: usize,
    pub aux_len: usize,
}

impl TileLayout {
    /// The block of `name`, in `u` or `aux`.
    pub fn block(&self, name: &str) -> Option<&TileBlock> {
        self.u.iter().chain(&self.aux).find(|b| b.name == name)
    }
}

/// One variable's block in a lane program's inputs (API_SPEC §5.8, "Lanes"):
/// its index sets outside the lane sets, their extents, and its offset in
/// units of lanes. Element `e` (1-based, column-major over `sets`) of lane `l`
/// is at slot `(offset + e - 1)·L + l` (`l` 0-based in Rust).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaneBlock {
    pub name: String,
    pub sets: Vec<String>,
    pub extents: Vec<usize>,
    pub offset: usize,
}

/// A lane program's `u` and `aux` layout, with the lane sets a column of
/// `cells` indexes and the capacity `L`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LaneLayout {
    pub u: Vec<LaneBlock>,
    pub aux: Vec<LaneBlock>,
    pub sets: Vec<String>,
    pub capacity: usize,
    pub u_len: usize,
    pub aux_len: usize,
}

impl LaneLayout {
    /// The block of `name`, in `u` or `aux`.
    pub fn block(&self, name: &str) -> Option<&LaneBlock> {
        self.u.iter().chain(&self.aux).find(|b| b.name == name)
    }
}

impl Blocks {
    /// The block of `name`.
    pub(crate) fn var(&self, name: &str) -> Option<&Block> {
        self.vars.iter().find(|v| v.name == name)
    }

    /// The public record of this layout.
    pub(crate) fn public(&self) -> TileLayout {
        let block = |v: &Block| TileBlock {
            name: v.name.clone(),
            sets: v.index_sets.clone(),
            storage: v.storage.clone(),
            owned: if v.input == TileInput::U {
                v.owned.clone()
            } else {
                Vec::new()
            },
            base: v.base,
            strides: v.strides.clone(),
        };
        TileLayout {
            u: self
                .vars
                .iter()
                .filter(|v| v.input == TileInput::U)
                .map(block)
                .collect(),
            aux: self
                .vars
                .iter()
                .filter(|v| v.input == TileInput::Aux)
                .map(block)
                .collect(),
            u_len: self.u_len,
            aux_len: self.aux_len,
        }
    }

    /// The public record of a lane layout: each block's first axis is the
    /// lane axis of `capacity` lanes.
    pub(crate) fn lane_public(&self, sets: &[String], capacity: usize) -> LaneLayout {
        let block = |v: &Block| LaneBlock {
            name: v.name.clone(),
            sets: v.index_sets[1..].to_vec(),
            extents: v.storage[1..]
                .iter()
                .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                .collect(),
            offset: v.base / capacity.max(1),
        };
        LaneLayout {
            u: self
                .vars
                .iter()
                .filter(|v| v.input == TileInput::U)
                .map(block)
                .collect(),
            aux: self
                .vars
                .iter()
                .filter(|v| v.input == TileInput::Aux)
                .map(block)
                .collect(),
            sets: sets.to_vec(),
            capacity,
            u_len: self.u_len,
            aux_len: self.aux_len,
        }
    }

    /// Build a layout over the given per-variable boxes, `u` variables first.
    fn build(
        entries: Vec<(
            String,
            TileInput,
            Vec<String>,
            Vec<(i64, i64)>,
            Vec<(i64, i64)>,
        )>,
    ) -> Blocks {
        let mut vars = Vec::with_capacity(entries.len());
        let mut u_len = 0usize;
        let mut aux_len = 0usize;
        for (name, input, index_sets, storage, owned) in entries {
            let mut strides = Vec::with_capacity(storage.len());
            let mut acc = 1usize;
            for &(lo, hi) in &storage {
                strides.push(acc);
                acc *= (hi - lo + 1).max(0) as usize;
            }
            let len = if storage.is_empty() { 1 } else { acc };
            let base = match input {
                TileInput::U => {
                    u_len += len;
                    u_len - len
                }
                TileInput::Aux => {
                    aux_len += len;
                    aux_len - len
                }
            };
            vars.push(Block {
                name,
                input,
                base,
                index_sets,
                storage,
                strides,
                owned,
            });
        }
        Blocks {
            vars,
            u_len,
            aux_len,
        }
    }
}

/// The per-call buffers of one program (API_SPEC §5.8): reused across calls,
/// so a warm call allocates nothing. Made by the program that runs it, and
/// usable only with that program (or a clone of it), one call at a time. It
/// may move between threads (`Send`); it is not `Sync`.
pub struct RhsWorkspace {
    owner: u64,
    state: Vec<f64>,
    dy: Vec<f64>,
    exec: WsExec,
    _not_sync: PhantomData<Cell<()>>,
}

enum WsExec {
    Tape(Box<TapeCtx>),
    Interp(Box<InterpWs>),
    Lanes {
        main: Box<TapeCtx>,
        pre: Box<TapeCtx>,
    },
}

/// The interpreter's per-call state: its scratch, and the forcing buffer it
/// reads by name, rebuilt from a forcing set only when the set's epoch moves.
struct InterpWs {
    scratch: RhsScratch,
    forcing: RefCell<HashMap<String, ArrayD<f64>>>,
    epoch: u64,
}

impl std::fmt::Debug for RhsWorkspace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RhsWorkspace")
            .field("state_len", &self.state.len())
            .finish()
    }
}

/// A process-unique identity for a program, carried by every clone of it
/// and recorded by the workspaces it makes.
fn next_program_id() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

fn range_error(code: &'static str, message: String) -> SimulateError {
    SimulateError::RangeRestriction { code, message }
}

fn build_error(message: String) -> SimulateError {
    SimulateError::Compile(crate::compile_error::CompileError::build_err(message))
}

/// `compiler_unavailable` for `call` on a program not built with `native`.
fn native_only(compiler: Compiler, call: &str) -> SimulateError {
    SimulateError::CompilerUnavailable {
        compiler: compiler.as_str(),
        details: format!(
            "`{call}` restricts the native tape, and this program was built with `{}`; build it \
             with `compiler = native`",
            compiler.as_str()
        ),
    }
}

/// A compiled right-hand side, possibly restricted to one operator's terms
/// and writes (API_SPEC §5.8). Made by [`rhs_program`].
///
/// Built once and immutable: `Send + Sync`, and cheap to clone (every clone
/// shares one program). Evaluate it concurrently with one [`RhsWorkspace`]
/// per thread; a call never starts a thread of its own.
#[derive(Clone)]
pub struct RhsProgram {
    inner: Arc<ProgramInner>,
}

struct ProgramInner {
    id: u64,
    /// The flattened system the program was compiled from (`None` for the
    /// solve's own program, which is never restricted).
    flat: Option<Arc<FlattenedSystem>>,
    model: Arc<ProgramModel>,
    compiler: Compiler,
    runtime_array_parameters: bool,
    /// The native tape, built at construction (`None` under `interpreter`).
    tape: Option<Arc<TapeProgram>>,
    /// The forcing slot each of the tape's forcing loads reads.
    slot_of: Vec<u32>,
    writes: Vec<String>,
    aux: Vec<String>,
    blocks: Blocks,
    layout: TileLayout,
    state_layout: Vec<StateBlock>,
    params: Vec<ParamSlot>,
    slots: Arc<[ForcingSlot]>,
    /// The Problem's forcing when the program was built.
    default_set: ForcingSet,
    /// Per variable of the compiled state vector, in its order: the input it
    /// is read from and the block offsets `(input base, state offset, len)`.
    scatter: Vec<(TileInput, usize, usize, usize)>,
    /// Whether `u` is the compiled state vector itself (every state written,
    /// each at its own offset), so a call reads `u` and writes `du` in place.
    identity: bool,
    declared: Arc<HashSet<String>>,
}

impl ProgramInner {
    fn flat(&self) -> &FlattenedSystem {
        self.flat
            .as_deref()
            .expect("a program built by `rhs_program` keeps its flattened system")
    }
}

impl std::fmt::Debug for RhsProgram {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RhsProgram")
            .field("compiler", &self.inner.compiler)
            .field("writes", &self.inner.writes)
            .field("aux", &self.inner.aux)
            .finish()
    }
}

/// The right-hand side `prob` compiled, as a program [`RhsProgram::select`],
/// [`RhsProgram::halo`], [`RhsProgram::tile`] and [`RhsProgram::lanes`]
/// accept (API_SPEC §5.8). Its names are the flattened (dot-namespaced)
/// names on every route; it writes every state.
///
/// `native` and `interpreter` problems are accepted; any other compiler is
/// `compiler_unavailable`. Under `native` a rule the tape cannot express is
/// `compiler_refused_rule`.
pub fn rhs_program(prob: &EsmProblem) -> Result<RhsProgram, SimulateError> {
    let compiler = prob.compiler;
    if !matches!(compiler, Compiler::Native | Compiler::Interpreter) {
        return Err(SimulateError::CompilerUnavailable {
            compiler: compiler.as_str(),
            details: "`rhs_program` serves the `native` and `interpreter` compilers".to_string(),
        });
    }
    let Some(source) = prob.program_source.as_ref() else {
        return Err(build_error(
            "`rhs_program`: this problem has no right-hand side to restrict".to_string(),
        ));
    };
    let _precision = prob.precision.enter();
    let flat = match &**source {
        ProgramSource::Flattened(f) => (**f).clone(),
        ProgramSource::File(file) => {
            let annotated =
                crate::precision_infer::annotated(file).map_err(SimulateError::Compile)?;
            let file = annotated.as_ref().unwrap_or(file);
            crate::flatten::flatten(file)
                .map_err(|e| SimulateError::Compile(crate::compile_error::CompileError::from(e)))?
        }
    };
    let forcing = match &*prob.backend {
        crate::problem::Backend::Array(c) => problem_forcing(c, &flat),
        crate::problem::Backend::Static(_) => HashMap::new(),
    };
    RhsProgram::compile(
        Arc::new(flat),
        compiler,
        None,
        ForcingSource::Problem(&forcing),
        prob.runtime_array_parameters,
    )
}

/// The Problem's forcing buffer, keyed by the flattened names: an entry whose
/// name the flattened system does not declare is matched to the one
/// flattened parameter it is the bare name of.
fn problem_forcing(c: &ArrayCompiled, flat: &FlattenedSystem) -> HashMap<String, ArrayD<f64>> {
    c.forcing
        .borrow()
        .iter()
        .filter_map(|(k, v)| {
            if flat.parameters.contains_key(k) {
                return Some((k.clone(), v.clone()));
            }
            let suffix = format!(".{k}");
            let mut m = flat.parameters.keys().filter(|n| n.ends_with(&suffix));
            match (m.next(), m.next()) {
                (Some(n), None) => Some((n.clone(), v.clone())),
                _ => None,
            }
        })
        .collect()
}

/// Where a program's forcing slots and their default buffers come from.
enum ForcingSource<'a> {
    /// The Problem's forcing buffer, by flattened name.
    Problem(&'a HashMap<String, ArrayD<f64>>),
    /// The program a selection is made from: the same slots and buffers.
    Parent(&'a ProgramInner),
}

/// `names` in flat-layout order (API_SPEC §5.8): 0-d states by sorted name,
/// then arrays by sorted name.
fn flat_layout_order(names: &mut [String], model: &ProgramModel) {
    names.sort_by(|a, b| {
        let rank = |n: &String| !model.var_shapes[n].shape.is_empty();
        (rank(a), a).cmp(&(rank(b), b))
    });
}

/// A row-major array's elements in column-major order (first index fastest).
fn column_major(a: &ArrayD<f64>) -> Arc<[f64]> {
    a.view().reversed_axes().iter().copied().collect()
}

/// The forcing slots of `model`: every name its forcing buffer serves that
/// has a shape, in byte order of the name, each with its default buffer (the
/// Problem's data, else the declared default, else `NaN`: a slot nothing
/// fills has no value until the caller's set gives it one).
fn forcing_slots(
    model: &ProgramModel,
    problem: &HashMap<String, ArrayD<f64>>,
    array_params: &HashSet<String>,
) -> (Vec<ForcingSlot>, Vec<Arc<[f64]>>) {
    let mut names: Vec<&String> = model.forcing_decls.keys().collect();
    names.sort();
    let mut slots = Vec::new();
    let mut defaults = Vec::new();
    for name in names {
        let Some(shape) = model.forcing_decls[name].clone() else {
            continue;
        };
        let len = shape.iter().product::<usize>();
        let default = match problem.get(name) {
            Some(a) => Some(column_major(a)),
            None => model
                .forcing_defaults
                .get(name)
                .cloned()
                .flatten()
                .and_then(|(s, v)| ArrayD::from_shape_vec(IxDyn(&s), v).ok())
                .map(|a| column_major(&a)),
        }
        .filter(|b| b.len() == len)
        .unwrap_or_else(|| vec![f64::NAN; len].into());
        slots.push(ForcingSlot {
            name: name.clone(),
            shape,
            kind: if array_params.contains(name) {
                SlotKind::ArrayParameter
            } else {
                SlotKind::Forcing
            },
        });
        defaults.push(default);
    }
    (slots, defaults)
}

/// The slot each forcing load of `tape` reads, refusing a load of a name no
/// slot serves or at a shape the slot does not have.
fn slot_map(tape: &TapeProgram, slots: &[ForcingSlot]) -> Result<Vec<u32>, SimulateError> {
    tape.forcings
        .iter()
        .map(|fr| {
            let k = slots
                .iter()
                .position(|s| s.name == fr.name)
                .ok_or_else(|| {
                    build_error(format!(
                        "`rhs_program`: the program reads forcing `{}`, which no forcing slot serves",
                        fr.name
                    ))
                })?;
            if slots[k].shape[..] != fr.shape[..] {
                return Err(build_error(format!(
                    "`rhs_program`: the program reads forcing `{}` as {:?}, its slot is {:?}",
                    fr.name, &fr.shape[..], slots[k].shape
                )));
            }
            Ok(k as u32)
        })
        .collect()
}

impl RhsProgram {
    /// Compile `flat` under `compiler`. `writes` is the selection's `W_k`
    /// (`None`: every state).
    fn compile(
        flat: Arc<FlattenedSystem>,
        compiler: Compiler,
        writes: Option<&[String]>,
        forcing: ForcingSource,
        runtime_array_parameters: bool,
    ) -> Result<RhsProgram, SimulateError> {
        let mut compiled = ArrayCompiled::from_flattened_with(&flat, runtime_array_parameters)?;
        compiled.runtime_mode = match compiler {
            Compiler::Interpreter => super::RuntimeMode::Interpreter,
            _ => super::RuntimeMode::Native,
        };
        // Every forcing read compiles against the shape the data has.
        let shapes: Vec<(String, Vec<usize>)> = match &forcing {
            ForcingSource::Problem(m) => m
                .iter()
                .map(|(k, a)| (k.clone(), a.shape().to_vec()))
                .collect(),
            ForcingSource::Parent(p) => p
                .slots
                .iter()
                .map(|s| (s.name.clone(), s.shape.clone()))
                .collect(),
        };
        for (name, shape) in shapes {
            if let Some(decl) = compiled.forcing_decls.get_mut(&name) {
                *decl = Some(shape);
            }
        }
        let tape = match compiler {
            Compiler::Native => {
                let discrete: HashSet<String> = compiled.forcing_decls.keys().cloned().collect();
                Some(compiled.strict_tape(&discrete)?)
            }
            _ => None,
        };
        let model = ProgramModel::from_compiled(compiled);
        let array_params: HashSet<String> = if runtime_array_parameters {
            model
                .forcing_decls
                .keys()
                .filter(|n| {
                    flat.parameters.get(*n).is_some_and(|v| {
                        v.update.is_none() && v.shape.as_ref().is_some_and(|s| !s.is_empty())
                    })
                })
                .cloned()
                .collect()
        } else {
            HashSet::new()
        };
        let default_set = match forcing {
            ForcingSource::Problem(m) => {
                let (s, d) = forcing_slots(&model, m, &array_params);
                ForcingSet::for_slots(s.into(), d).expect("each default holds its slot's shape")
            }
            ForcingSource::Parent(p) => p.default_set.clone(),
        };
        let slots = default_set.slots_arc();
        let slot_of = match &tape {
            Some(t) => slot_map(t, &slots)?,
            None => Vec::new(),
        };
        let states: Vec<String> = model.var_shapes.keys().cloned().collect();
        let mut writes: Vec<String> = match writes {
            None => states.clone(),
            Some(w) => states.iter().filter(|s| w.contains(s)).cloned().collect(),
        };
        let mut aux: Vec<String> = states
            .iter()
            .filter(|s| !writes.contains(s))
            .cloned()
            .collect();
        flat_layout_order(&mut writes, &model);
        flat_layout_order(&mut aux, &model);
        let set_names = state_set_names(&flat, &model);
        let mut entries = Vec::new();
        for (input, names) in [(TileInput::U, &writes), (TileInput::Aux, &aux)] {
            for name in names {
                let vs = &model.var_shapes[name];
                let bx: Vec<(i64, i64)> = vs
                    .shape
                    .iter()
                    .zip(&vs.origin)
                    .map(|(&n, &o)| (o, o + n as i64 - 1))
                    .collect();
                entries.push((name.clone(), input, set_names[name].clone(), bx.clone(), bx));
            }
        }
        let blocks = Blocks::build(entries);
        let layout = blocks.public();
        let scatter: Vec<(TileInput, usize, usize, usize)> = model
            .var_shapes
            .iter()
            .map(|(name, vs)| {
                let v = blocks.var(name).expect("every state is in the layout");
                let len = vs.shape.iter().product::<usize>().max(1);
                (v.input, v.base, vs.flat_offset, len)
            })
            .collect();
        let identity = scatter
            .iter()
            .all(|&(input, base, off, _)| input == TileInput::U && base == off);
        let state_layout = layout
            .u
            .iter()
            .map(|b| StateBlock {
                name: b.name.clone(),
                flat_offset: b.base,
                shape: b
                    .storage
                    .iter()
                    .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                    .collect(),
            })
            .collect();
        let params = model
            .param_names
            .iter()
            .zip(&model.param_defaults)
            .map(|(name, default)| ParamSlot {
                name: name.clone(),
                default: *default,
            })
            .collect();
        let declared = Arc::new(model.declared_names.clone());
        Ok(RhsProgram {
            inner: Arc::new(ProgramInner {
                id: next_program_id(),
                flat: Some(flat),
                model: Arc::new(model),
                compiler,
                runtime_array_parameters,
                tape,
                slot_of,
                writes,
                aux,
                blocks,
                layout,
                state_layout,
                params,
                slots,
                default_set,
                scatter,
                identity,
                declared,
            }),
        })
    }

    pub(super) fn slots_arc(&self) -> Arc<[ForcingSlot]> {
        Arc::clone(&self.inner.slots)
    }

    /// The compiler this program was built with.
    pub fn compiler(&self) -> Compiler {
        self.inner.compiler
    }

    /// The variables the program writes (`u`), in flat-layout order.
    pub fn writes(&self) -> &[String] {
        &self.inner.writes
    }

    /// The states the program reads but does not write (`aux`), in
    /// flat-layout order.
    pub fn aux(&self) -> &[String] {
        &self.inner.aux
    }

    /// The whole-domain layout of `u` and `aux`.
    pub fn layout(&self) -> &TileLayout {
        &self.inner.layout
    }

    /// The length of `u` (and of `du`).
    pub fn n_states(&self) -> usize {
        self.inner.blocks.u_len
    }

    /// `u`'s blocks in flat order, each column-major (first index fastest):
    /// the `u` half of [`Self::layout`].
    pub fn state_layout(&self) -> &[StateBlock] {
        &self.inner.state_layout
    }

    /// The parameters `p` holds, in its order: the order the program's tape
    /// reads them in (sorted flattened names).
    pub fn parameters(&self) -> &[ParamSlot] {
        &self.inner.params
    }

    /// The parameter vector with `overrides` applied over the declared
    /// defaults. Strict: a key naming no parameter, or a parameter with
    /// neither an override nor a default, is an error naming it.
    pub fn parameter_vector(
        &self,
        overrides: &HashMap<String, f64>,
    ) -> Result<Vec<f64>, SimulateError> {
        self.inner.model.parameter_vector(overrides)
    }

    /// The buffers a [`ForcingSet`] for this program holds, in its order.
    pub fn forcing_slots(&self) -> &[ForcingSlot] {
        &self.inner.slots
    }

    /// The Problem's forcing when the program was built: provider data, a
    /// caller's array, or the declared default, and for an array-parameter
    /// slot the parameter's value. Every call returns the same set (the same
    /// buffers and epoch). A slot none of these fills holds `NaN`.
    pub fn default_forcing(&self) -> ForcingSet {
        self.inner.default_set.clone()
    }

    /// The declared default of every state cell, as `(u, aux)` in this
    /// program's whole-domain layout (`NaN` where none is declared).
    pub fn default_state(&self) -> (Vec<f64>, Vec<f64>) {
        let inner = &*self.inner;
        let mut u = vec![f64::NAN; inner.blocks.u_len];
        let mut aux = vec![f64::NAN; inner.blocks.aux_len];
        for ((name, vs), default) in inner
            .model
            .var_shapes
            .iter()
            .zip(&inner.model.state_defaults)
        {
            let v = inner
                .blocks
                .var(name)
                .expect("every state is in the layout");
            let dst = match v.input {
                TileInput::U => &mut u,
                TileInput::Aux => &mut aux,
            };
            let len = vs.shape.iter().product::<usize>().max(1);
            match default {
                super::StateDefault::Scalar(Some(x)) => dst[v.base..v.base + len].fill(*x),
                super::StateDefault::Scalar(None) => {}
                super::StateDefault::Field(rm) => {
                    // Row-major data into the column-major block.
                    let shape = &vs.shape;
                    for (k, &x) in rm.iter().enumerate().take(len) {
                        let mut rem = k;
                        let mut off = 0usize;
                        let mut stride_cm = vec![1usize; shape.len()];
                        for d in 1..shape.len() {
                            stride_cm[d] = stride_cm[d - 1] * shape[d - 1];
                        }
                        for d in (0..shape.len()).rev() {
                            let i = rem % shape[d];
                            rem /= shape[d];
                            off += i * stride_cm[d];
                        }
                        dst[v.base + off] = x;
                    }
                }
            }
        }
        (u, aux)
    }

    /// The flattened system this program was compiled from.
    pub fn flattened(&self) -> &FlattenedSystem {
        self.inner.flat()
    }

    /// The program for one operator: the summands of each `D(x)` whose
    /// provenance is in `sel.terms`, writing only `sel.writes` (API_SPEC
    /// §5.8). `range_selection_writes_incomplete` when `writes` omits a
    /// variable a kept summand writes. It takes the same forcing sets.
    pub fn select(&self, sel: &RhsSelection) -> Result<RhsProgram, SimulateError> {
        let (flat, writes) = select::select(self.inner.flat(), sel)?;
        let _precision = self.inner.model.precision.enter();
        RhsProgram::compile(
            Arc::new(flat),
            self.inner.compiler,
            Some(&writes),
            ForcingSource::Parent(&self.inner),
            self.inner.runtime_array_parameters,
        )
    }

    /// How far the owned output reaches into each state along each decomposed
    /// or face index set of `dec` (RFC U3 §3). `native` only.
    pub fn halo(&self, dec: &Decomposition) -> Result<HaloReport, SimulateError> {
        if self.inner.compiler != Compiler::Native {
            return Err(native_only(self.inner.compiler, "halo"));
        }
        analysis::halo(self, dec)
    }

    /// This program restricted to one tile of `dec` (RFC U3 §4). `native` only.
    pub fn tile(&self, dec: &Decomposition, bx: &TileBox) -> Result<TileProgram, SimulateError> {
        if self.inner.compiler != Compiler::Native {
            return Err(native_only(self.inner.compiler, "tile"));
        }
        tile::build(self, dec, bx)
    }

    /// This program over a run-time list of at most `capacity` cells or
    /// columns (RFC U3 §6). `native` only.
    pub fn lanes(&self, kind: LaneKind, capacity: usize) -> Result<LaneProgram, SimulateError> {
        if self.inner.compiler != Compiler::Native {
            return Err(native_only(self.inner.compiler, "lanes"));
        }
        lanes::build(self, &kind, capacity)
    }

    /// Buffers for [`Self::eval_into`].
    pub fn new_workspace(&self) -> RhsWorkspace {
        let inner = &*self.inner;
        let exec = match &inner.tape {
            Some(t) => {
                let mut ctx = TapeCtx::new(Arc::clone(t));
                ctx.set_serial();
                WsExec::Tape(Box::new(ctx))
            }
            None => {
                let mut s = RhsScratch::new(&inner.model.var_shapes);
                s.set_const_arrays(Arc::clone(&inner.model.const_scope));
                WsExec::Interp(Box::new(InterpWs {
                    scratch: s,
                    forcing: RefCell::new(HashMap::new()),
                    epoch: 0,
                }))
            }
        };
        let n = if inner.identity {
            0
        } else {
            inner.model.n_states
        };
        RhsWorkspace {
            owner: inner.id,
            state: vec![0.0; n],
            dy: vec![0.0; n],
            exec,
            _not_sync: PhantomData,
        }
    }

    /// Evaluate the program over the whole domain: `du = f(u, aux, p, t)` in
    /// [`Self::layout`], reading `forcing`. Every element of `du` is written
    /// (zero for a state with no `D` equation). This is the reference every
    /// tile and lane of the program is bitwise against.
    ///
    /// The result depends only on the program and the arguments' values:
    /// not on the thread, the workspace's history, or any other call.
    #[allow(clippy::too_many_arguments)]
    pub fn eval_into(
        &self,
        u: &[f64],
        aux: &[f64],
        p: &[f64],
        t: f64,
        forcing: &ForcingSet,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), RhsError> {
        let inner = &*self.inner;
        check_lengths(&inner.blocks, u, aux, du, p, inner.params.len())?;
        check_owner(ws, inner.id)?;
        check_forcing(forcing, &inner.slots)?;
        let _precision = inner.model.precision.enter();
        let scope = super::FaultScope::enter();
        self.run(u, aux, p, t, Forcing::Set(forcing), du, ws);
        match scope.finish() {
            Some(msg) => {
                if let WsExec::Tape(ctx) = &mut ws.exec {
                    ctx.invalidate_sections();
                }
                Err(forcing::fault(msg))
            }
            None => Ok(()),
        }
    }

    /// The program the solve integrates (`native`): `c`'s own state vector
    /// as `u` (so a call reads `y` and writes `dy` in place) and the solve's
    /// tape, reading the forcing buffer the solve refreshes.
    #[cfg(feature = "solve")]
    pub(in crate::simulate_array) fn for_solve(
        c: &ArrayCompiled,
        tape: Arc<TapeProgram>,
    ) -> RhsProgram {
        let entries = c
            .var_shapes
            .iter()
            .map(|(name, vs)| {
                let bx: Vec<(i64, i64)> = vs
                    .shape
                    .iter()
                    .zip(&vs.origin)
                    .map(|(&n, &o)| (o, o + n as i64 - 1))
                    .collect();
                (name.clone(), TileInput::U, Vec::new(), bx.clone(), bx)
            })
            .collect();
        let blocks = Blocks::build(entries);
        let layout = blocks.public();
        let model = ProgramModel {
            var_shapes: c.var_shapes.clone(),
            param_names: c.param_names.clone(),
            n_states: c.n_states,
            precision: c.precision.clone(),
            ..ProgramModel::default()
        };
        RhsProgram {
            inner: Arc::new(ProgramInner {
                id: next_program_id(),
                flat: None,
                compiler: Compiler::Native,
                runtime_array_parameters: false,
                tape: Some(tape),
                slot_of: Vec::new(),
                writes: c.var_shapes.keys().cloned().collect(),
                aux: Vec::new(),
                state_layout: Vec::new(),
                params: Vec::new(),
                slots: Arc::from(Vec::new()),
                default_set: ForcingSet::for_slots(Arc::from(Vec::new()), Vec::new())
                    .expect("an empty set"),
                scatter: Vec::new(),
                identity: true,
                declared: Arc::new(c.declared_names.clone()),
                blocks,
                layout,
                model: Arc::new(model),
            }),
        }
    }

    /// A workspace for [`Self::eval_solve`]: the executor may split a call
    /// across the process pool, as the solve's right-hand side always has.
    #[cfg(feature = "solve")]
    pub(in crate::simulate_array) fn solve_workspace(&self) -> RhsWorkspace {
        let tape = self
            .inner
            .tape
            .as_ref()
            .expect("the solve's program is taped");
        RhsWorkspace {
            owner: self.inner.id,
            state: Vec::new(),
            dy: Vec::new(),
            exec: WsExec::Tape(Box::new(TapeCtx::new(Arc::clone(tape)))),
            _not_sync: PhantomData,
        }
    }

    /// The solve's right-hand side: [`Self::eval_into`]'s evaluation, reading
    /// the forcing buffer by name. A fault stays latched on the thread for
    /// the solve to report after the run (the integrator's right-hand side
    /// has no error channel), and the SEGMENT section re-runs when the solve
    /// says the buffer was refreshed ([`RhsWorkspace::forcing_refreshed`]).
    #[cfg(feature = "solve")]
    pub(in crate::simulate_array) fn eval_solve(
        &self,
        u: &[f64],
        p: &[f64],
        t: f64,
        forcing: &HashMap<String, ArrayD<f64>>,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) {
        let _precision = self.inner.model.precision.enter();
        self.run(u, &[], p, t, Forcing::Buffer(forcing), du, ws);
    }

    /// One evaluation: `u`/`aux` into the state the program addresses, the
    /// program run, the written rows out to `du`.
    #[allow(clippy::too_many_arguments)]
    fn run(
        &self,
        u: &[f64],
        aux: &[f64],
        p: &[f64],
        t: f64,
        forcing: Forcing,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) {
        let inner = &*self.inner;
        let RhsWorkspace {
            state, dy, exec, ..
        } = ws;
        let (state, dy): (&[f64], &mut [f64]) = if inner.identity {
            (u, &mut *du)
        } else {
            for &(input, base, off, len) in &inner.scatter {
                let src = match input {
                    TileInput::U => u,
                    TileInput::Aux => aux,
                };
                state[off..off + len].copy_from_slice(&src[base..base + len]);
            }
            (state.as_slice(), dy.as_mut_slice())
        };
        match exec {
            WsExec::Tape(ctx) => {
                let (view, epoch) = match forcing {
                    Forcing::Set(set) => (
                        ForcingView::Slots {
                            bufs: set.bufs(),
                            slot_of: &inner.slot_of,
                        },
                        Some(set.epoch()),
                    ),
                    Forcing::Buffer(map) => (ForcingView::Map(map), None),
                };
                let inputs = CallInputs {
                    state,
                    params: p,
                    forcing: view,
                    forcing_epoch: epoch,
                    t,
                    declared: &inner.declared,
                };
                run_tape_inputs(ctx, &inputs, dy, true);
            }
            WsExec::Lanes { .. } => unreachable!("a whole-domain workspace runs one program"),
            WsExec::Interp(iw) => {
                let Forcing::Set(set) = forcing else {
                    unreachable!("the solve's program is taped");
                };
                if iw.epoch != set.epoch() {
                    fill_forcing_map(&mut iw.forcing.borrow_mut(), set);
                    iw.epoch = set.epoch();
                }
                let m = &*inner.model;
                evaluate_rhs_with_scratch(
                    &RhsCall {
                        rhs_rules: &m.rhs_rules,
                        observed_rules: &m.observed_rules,
                        rule_set: m.rule_set,
                        var_shapes: &m.var_shapes,
                        param_names: &m.param_names,
                        state,
                        params: p,
                        forcing: &iw.forcing,
                        t,
                        declared: &m.declared_names,
                    },
                    dy,
                    true,
                    &mut RhsStats::default(),
                    &mut iw.scratch,
                );
            }
        }
        if !inner.identity {
            for &(input, base, off, len) in &inner.scatter {
                if input == TileInput::U {
                    du[base..base + len].copy_from_slice(&ws.dy[off..off + len]);
                }
            }
        }
    }
}

/// What a call's forcing loads read.
#[derive(Clone, Copy)]
enum Forcing<'a> {
    /// A forcing set (every public call).
    Set(&'a ForcingSet),
    /// The solve's forcing buffer, by name.
    #[cfg_attr(not(feature = "solve"), allow(dead_code))]
    Buffer(&'a HashMap<String, ArrayD<f64>>),
}

impl RhsWorkspace {
    /// The solve refreshed its forcing buffer: the next call re-runs the
    /// SEGMENT section.
    #[cfg(feature = "solve")]
    pub(in crate::simulate_array) fn forcing_refreshed(&mut self) {
        if let WsExec::Tape(ctx) = &mut self.exec {
            ctx.bump_forcing_epoch();
        }
    }
}

/// The by-name forcing buffer the per-cell evaluator reads, from `set`:
/// row-major arrays, overwritten in place when one of that shape is there.
fn fill_forcing_map(map: &mut HashMap<String, ArrayD<f64>>, set: &ForcingSet) {
    for (k, slot) in set.slots().iter().enumerate() {
        let src = ndarray::ArrayViewD::from_shape(IxDyn(&slot.shape).f(), set.buffer(k))
            .expect("a forcing set's buffer holds its slot's shape");
        match map.get_mut(&slot.name) {
            Some(a) if a.shape() == &slot.shape[..] => a.assign(&src),
            _ => {
                map.insert(slot.name.clone(), src.as_standard_layout().into_owned());
            }
        }
    }
}

fn check_forcing(set: &ForcingSet, slots: &Arc<[ForcingSlot]>) -> Result<(), RhsError> {
    if !set.fits(slots) {
        return Err(set.mismatch(slots));
    }
    Ok(())
}

fn check_owner(ws: &RhsWorkspace, id: u64) -> Result<(), RhsError> {
    if ws.owner != id {
        return Err(RhsError::ForeignProgram { what: "workspace" });
    }
    Ok(())
}

/// The fault a tape call latched, as an error, forgetting the sections the
/// call primed (they hold the fault's values).
fn tape_fault(scope: super::FaultScope, ctx: &mut TapeCtx) -> Result<(), RhsError> {
    match scope.finish() {
        Some(msg) => {
            ctx.invalidate_sections();
            Err(forcing::fault(msg))
        }
        None => Ok(()),
    }
}

fn check_lengths(
    layout: &Blocks,
    u: &[f64],
    aux: &[f64],
    du: &[f64],
    p: &[f64],
    n_params: usize,
) -> Result<(), RhsError> {
    if u.len() != layout.u_len {
        return Err(forcing::shape("u", layout.u_len, u.len()));
    }
    if du.len() != layout.u_len {
        return Err(forcing::shape("du", layout.u_len, du.len()));
    }
    if aux.len() != layout.aux_len {
        return Err(forcing::shape("aux", layout.aux_len, aux.len()));
    }
    if p.len() != n_params {
        return Err(forcing::shape("p", n_params, p.len()));
    }
    Ok(())
}

/// The index-set name of each axis of each compiled state, from its
/// flattened declaration (empty when it names none at the compiled rank).
fn state_set_names(
    flat: &FlattenedSystem,
    compiled: &ProgramModel,
) -> HashMap<String, Vec<String>> {
    let sizes = index_set_sizes(flat);
    compiled
        .var_shapes
        .iter()
        .map(|(name, vs)| {
            let declared = flat.state_variables.get(name).and_then(|v| v.shape.clone());
            let extents: Vec<i64> = vs.shape.iter().map(|&n| n as i64).collect();
            (name.clone(), axis_set_names(declared, &extents, &sizes))
        })
        .collect()
}

/// The index-set name of each axis of extents `extents`: the declared shape
/// when it names one per axis, else, axis by axis, the one interval index set
/// of that size when exactly one has it (a state the pointwise lift promoted
/// carries no declared shape), else none.
fn axis_set_names(
    declared: Option<Vec<String>>,
    extents: &[i64],
    sizes: &HashMap<String, i64>,
) -> Vec<String> {
    if let Some(d) = declared.filter(|d| d.len() == extents.len()) {
        return d;
    }
    let names: Vec<Option<String>> = extents
        .iter()
        .map(|&n| {
            let mut c = sizes
                .iter()
                .filter(|(_, m)| **m == n)
                .map(|(k, _)| k.clone());
            match (c.next(), c.next()) {
                (Some(k), None) => Some(k),
                _ => None,
            }
        })
        .collect();
    if names.iter().all(Option::is_some) {
        names.into_iter().flatten().collect()
    } else {
        Vec::new()
    }
}

/// The size of each index set the flattened system declares (an interval
/// set's `size`).
fn index_set_sizes(flat: &FlattenedSystem) -> HashMap<String, i64> {
    flat.index_sets
        .iter()
        .filter_map(|(k, v)| v.size.map(|n| (k.clone(), n)))
        .collect()
}

/// How one axis named `set` (of global extent `lo..=hi`) sits in `dec`.
fn axis_spec(dec: &Decomposition, set: Option<&str>, sizes: &HashMap<String, i64>) -> AxisSpec {
    let Some(set) = set else {
        return AxisSpec::Whole { set: None };
    };
    if let Some(cut) = dec.axes.iter().find(|a| a.index_set == set) {
        let n = sizes.get(set).copied().unwrap_or(0);
        return AxisSpec::Cut {
            set: set.to_string(),
            cell: set.to_string(),
            hi: n,
            period: cut.period,
            face: false,
        };
    }
    if let Some((_, cell)) = dec.faces.iter().find(|(f, _)| f == set)
        && let Some(cut) = dec.axes.iter().find(|a| &a.index_set == cell)
    {
        let n = sizes.get(cell.as_str()).copied().unwrap_or(0);
        return AxisSpec::Cut {
            set: set.to_string(),
            cell: cell.clone(),
            hi: n + 1,
            period: cut.period,
            face: true,
        };
    }
    AxisSpec::Whole {
        set: Some(set.to_string()),
    }
}

/// The walker's view of every state and every array observed of `prog` under
/// `dec`.
fn var_infos(prog: &RhsProgram, dec: &Decomposition) -> HashMap<String, VarInfo> {
    let prog = &*prog.inner;
    let flat = prog.flat();
    let sizes = index_set_sizes(flat);
    let set_names = state_set_names(flat, &prog.model);
    let mut out = HashMap::new();
    for (name, vs) in &prog.model.var_shapes {
        let sets = &set_names[name];
        let axes = (0..vs.shape.len())
            .map(|d| axis_spec(dec, sets.get(d).map(String::as_str), &sizes))
            .collect();
        let extent = vs
            .shape
            .iter()
            .zip(&vs.origin)
            .map(|(&n, &o)| (o, o + n as i64 - 1))
            .collect();
        out.insert(name.clone(), VarInfo { axes, extent });
    }
    for rule in &prog.model.observed_rules {
        let (var, ranges) = match rule {
            super::AlgebraicRule::ArrayLoop {
                var, output_ranges, ..
            }
            | super::AlgebraicRule::Recurrence {
                var, output_ranges, ..
            } => (var, output_ranges.clone()),
            super::AlgebraicRule::Scalar {
                var,
                declared_shape,
                ..
            } => (
                var,
                declared_shape
                    .as_ref()
                    .map(|s| s.iter().map(|&n| (1, n as i64)).collect())
                    .unwrap_or_default(),
            ),
        };
        let declared = flat
            .observed_variables
            .get(var)
            .or_else(|| flat.state_variables.get(var))
            .and_then(|v| v.shape.clone());
        let extents: Vec<i64> = ranges.iter().map(|r| r.1).collect();
        let sets = axis_set_names(declared, &extents, &sizes);
        let axes = (0..ranges.len())
            .map(|d| axis_spec(dec, sets.get(d).map(String::as_str), &sizes))
            .collect();
        let extent = ranges.iter().map(|&(_, hi)| (1, hi)).collect();
        out.insert(var.clone(), VarInfo { axes, extent });
    }
    out
}
