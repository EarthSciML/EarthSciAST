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
mod lanes;
mod select;
mod tile;
mod walk;

pub use lanes::{LaneInputs, LaneProgram};
pub use tile::TileProgram;

use super::tape::{CallInputs, TapeCtx, TapeProgram, run_tape_inputs};
use super::{ArrayCompiled, RhsCall, RhsScratch, RhsStats, evaluate_rhs_with_scratch};
use crate::flatten::{FlattenedSystem, TermOrigin};
use crate::problem::{Compiler, EsmProblem, ProgramSource};
use crate::simulate::SimulateError;
use ndarray::ArrayD;
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ops::RangeInclusive;
use std::rc::Rc;
use std::sync::Arc;
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

/// The per-call buffers of one program (RFC U3 §5): reused across calls, so
/// a warm call allocates nothing. Made by the program that runs it.
pub struct RhsWorkspace {
    owner: usize,
    state: Vec<f64>,
    dy: Vec<f64>,
    exec: WsExec,
}

enum WsExec {
    Tape(Box<TapeCtx>),
    Scratch(Box<RhsScratch>),
    Lanes {
        main: Box<TapeCtx>,
        pre: Box<TapeCtx>,
    },
}

impl std::fmt::Debug for RhsWorkspace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RhsWorkspace")
            .field("state_len", &self.state.len())
            .finish()
    }
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
pub struct RhsProgram {
    flat: Rc<FlattenedSystem>,
    compiled: Rc<ArrayCompiled>,
    compiler: Compiler,
    /// The native tape, built at construction (`None` under `interpreter`).
    tape: Option<Arc<TapeProgram>>,
    writes: Vec<String>,
    aux: Vec<String>,
    blocks: Blocks,
    layout: TileLayout,
    /// The forcing buffers the program was built against: the Problem's.
    forcing: Arc<HashMap<String, ArrayD<f64>>>,
    /// Per variable of the compiled state vector, in its order: the input it
    /// is read from and the block offsets `(input base, state offset, len)`.
    scatter: Vec<(TileInput, usize, usize, usize)>,
    declared: Arc<HashSet<String>>,
    /// The forcing buffers in the form the per-cell evaluator reads them,
    /// built once (`None` under `native`, whose tape reads `forcing`).
    interp_forcing: Option<RefCell<HashMap<String, ArrayD<f64>>>>,
    /// This program's identity, matched against the workspaces it made. A
    /// counter value rather than an address, so it survives a move of the
    /// program.
    id: usize,
}

/// A fresh [`RhsProgram`] identity.
fn next_program_id() -> usize {
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

impl std::fmt::Debug for RhsProgram {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RhsProgram")
            .field("compiler", &self.compiler)
            .field("writes", &self.writes)
            .field("aux", &self.aux)
            .finish()
    }
}

/// The right-hand side `prob` compiled, as a program [`RhsProgram::select`],
/// [`RhsProgram::halo`], [`RhsProgram::tile`] and [`RhsProgram::lanes`]
/// accept (API_SPEC §5.8). Its names are the flattened (dot-namespaced)
/// names on every route; it writes every state.
///
/// `native` and `interpreter` problems are accepted; any other compiler is
/// `compiler_unavailable`.
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
    RhsProgram::compile(Rc::new(flat), compiler, None, Arc::new(forcing))
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

/// `names` in flat-layout order (API_SPEC §5.8): 0-d states by sorted name,
/// then arrays by sorted name.
fn flat_layout_order(names: &mut [String], compiled: &ArrayCompiled) {
    names.sort_by(|a, b| {
        let rank = |n: &String| !compiled.var_shapes[n].shape.is_empty();
        (rank(a), a).cmp(&(rank(b), b))
    });
}

impl RhsProgram {
    /// Compile `flat` under `compiler`. `writes` is the selection's `W_k`
    /// (`None`: every state).
    fn compile(
        flat: Rc<FlattenedSystem>,
        compiler: Compiler,
        writes: Option<&[String]>,
        forcing: Arc<HashMap<String, ArrayD<f64>>>,
    ) -> Result<RhsProgram, SimulateError> {
        let mut compiled = ArrayCompiled::from_flattened(&flat)?;
        compiled.runtime_mode = match compiler {
            Compiler::Interpreter => super::RuntimeMode::Interpreter,
            _ => super::RuntimeMode::Native,
        };
        let tape = match compiler {
            Compiler::Native => Some(compiled.strict_tape(&HashSet::new())?),
            _ => None,
        };
        let states: Vec<String> = compiled.var_shapes.keys().cloned().collect();
        let mut writes: Vec<String> = match writes {
            None => states.clone(),
            Some(w) => states.iter().filter(|s| w.contains(s)).cloned().collect(),
        };
        let mut aux: Vec<String> = states
            .iter()
            .filter(|s| !writes.contains(s))
            .cloned()
            .collect();
        flat_layout_order(&mut writes, &compiled);
        flat_layout_order(&mut aux, &compiled);
        let set_names = state_set_names(&flat, &compiled);
        let mut entries = Vec::new();
        for (input, names) in [(TileInput::U, &writes), (TileInput::Aux, &aux)] {
            for name in names {
                let vs = &compiled.var_shapes[name];
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
        let scatter = compiled
            .var_shapes
            .iter()
            .map(|(name, vs)| {
                let v = blocks.var(name).expect("every state is in the layout");
                let len = vs.shape.iter().product::<usize>().max(1);
                (v.input, v.base, vs.flat_offset, len)
            })
            .collect();
        let declared = Arc::new(compiled.declared_names.clone());
        let interp_forcing =
            (compiler == Compiler::Interpreter).then(|| RefCell::new((*forcing).clone()));
        Ok(RhsProgram {
            flat,
            compiled: Rc::new(compiled),
            compiler,
            tape,
            writes,
            aux,
            blocks,
            layout,
            forcing,
            scatter,
            declared,
            interp_forcing,
            id: next_program_id(),
        })
    }

    /// The compiler this program was built with.
    pub fn compiler(&self) -> Compiler {
        self.compiler
    }

    /// The variables the program writes (`u`), in flat-layout order.
    pub fn writes(&self) -> &[String] {
        &self.writes
    }

    /// The states the program reads but does not write (`aux`), in
    /// flat-layout order.
    pub fn aux(&self) -> &[String] {
        &self.aux
    }

    /// The whole-domain layout of `u` and `aux`.
    pub fn layout(&self) -> &TileLayout {
        &self.layout
    }

    /// The positional parameter names `p` is read against.
    pub fn parameter_names(&self) -> &[String] {
        &self.compiled.param_names
    }

    /// The parameter vector of the declared defaults (`NaN` where a parameter
    /// declares none).
    pub fn default_parameters(&self) -> Vec<f64> {
        self.compiled
            .param_defaults
            .iter()
            .map(|d| d.unwrap_or(f64::NAN))
            .collect()
    }

    /// The declared default of every state cell, as `(u, aux)` in this
    /// program's whole-domain layout (`NaN` where none is declared).
    pub fn default_state(&self) -> (Vec<f64>, Vec<f64>) {
        let mut u = vec![f64::NAN; self.blocks.u_len];
        let mut aux = vec![f64::NAN; self.blocks.aux_len];
        for ((name, vs), default) in self
            .compiled
            .var_shapes
            .iter()
            .zip(&self.compiled.state_defaults)
        {
            let v = self.blocks.var(name).expect("every state is in the layout");
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
        &self.flat
    }

    /// The program for one operator: the summands of each `D(x)` whose
    /// provenance is in `sel.terms`, writing only `sel.writes` (API_SPEC
    /// §5.8). `range_selection_writes_incomplete` when `writes` omits a
    /// variable a kept summand writes.
    pub fn select(&self, sel: &RhsSelection) -> Result<RhsProgram, SimulateError> {
        let (flat, writes) = select::select(&self.flat, sel)?;
        RhsProgram::compile(
            Rc::new(flat),
            self.compiler,
            Some(&writes),
            Arc::clone(&self.forcing),
        )
    }

    /// How far the owned output reaches into each state along each decomposed
    /// or face index set of `dec` (RFC U3 §3). `native` only.
    pub fn halo(&self, dec: &Decomposition) -> Result<HaloReport, SimulateError> {
        if self.compiler != Compiler::Native {
            return Err(native_only(self.compiler, "halo"));
        }
        analysis::halo(self, dec)
    }

    /// This program restricted to one tile of `dec` (RFC U3 §4). `native` only.
    pub fn tile(&self, dec: &Decomposition, bx: &TileBox) -> Result<TileProgram, SimulateError> {
        if self.compiler != Compiler::Native {
            return Err(native_only(self.compiler, "tile"));
        }
        tile::build(self, dec, bx)
    }

    /// This program over a run-time list of at most `capacity` cells or
    /// columns (RFC U3 §6). `native` only.
    pub fn lanes(&self, kind: LaneKind, capacity: usize) -> Result<LaneProgram, SimulateError> {
        if self.compiler != Compiler::Native {
            return Err(native_only(self.compiler, "lanes"));
        }
        lanes::build(self, &kind, capacity)
    }

    /// Buffers for [`Self::eval_into`].
    pub fn new_workspace(&self) -> RhsWorkspace {
        let exec = match &self.tape {
            Some(t) => WsExec::Tape(Box::new(TapeCtx::new(Arc::clone(t)))),
            None => {
                let mut s = RhsScratch::new(&self.compiled.var_shapes);
                s.set_const_arrays(Rc::clone(&self.compiled.const_scope));
                WsExec::Scratch(Box::new(s))
            }
        };
        RhsWorkspace {
            owner: self.id,
            state: vec![0.0; self.compiled.n_states],
            dy: vec![0.0; self.compiled.n_states],
            exec,
        }
    }

    /// Evaluate the program over the whole domain: `du = f(u, aux, p, t)` in
    /// [`Self::layout`]. This is the reference every tile and lane of the
    /// program is bitwise against.
    #[allow(clippy::too_many_arguments)]
    pub fn eval_into(
        &self,
        u: &[f64],
        aux: &[f64],
        p: &[f64],
        t: f64,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), SimulateError> {
        check_lengths(&self.blocks, u, aux, du, p, self.compiled.param_names.len())?;
        let forcing = &*self.forcing;
        if ws.owner != self.id {
            return Err(build_error(
                "`eval_into`: the workspace was made by another program".to_string(),
            ));
        }
        for &(input, base, off, len) in &self.scatter {
            let src = match input {
                TileInput::U => u,
                TileInput::Aux => aux,
            };
            ws.state[off..off + len].copy_from_slice(&src[base..base + len]);
        }
        let _precision = self.compiled.precision.enter();
        super::take_const_array_oob();
        match &mut ws.exec {
            WsExec::Tape(ctx) => {
                let inputs = CallInputs {
                    state: &ws.state,
                    params: p,
                    forcing,
                    t,
                    declared: &self.declared,
                };
                run_tape_inputs(ctx, &inputs, &mut ws.dy, true);
            }
            WsExec::Lanes { .. } => unreachable!("a whole-domain workspace runs one program"),
            WsExec::Scratch(scratch) => {
                let cell = self
                    .interp_forcing
                    .as_ref()
                    .expect("an interpreter program holds its forcing cell");
                let mut stats = RhsStats::default();
                evaluate_rhs_with_scratch(
                    &RhsCall {
                        rhs_rules: &self.compiled.rhs_rules,
                        observed_rules: &self.compiled.observed_rules,
                        rule_set: self.compiled.rule_set,
                        var_shapes: &self.compiled.var_shapes,
                        param_names: &self.compiled.param_names,
                        state: &ws.state,
                        params: p,
                        forcing: cell,
                        t,
                        declared: &self.compiled.declared_names,
                    },
                    &mut ws.dy,
                    true,
                    &mut stats,
                    scratch,
                );
            }
        }
        take_fault()?;
        for &(input, base, off, len) in &self.scatter {
            if input == TileInput::U {
                du[base..base + len].copy_from_slice(&ws.dy[off..off + len]);
            }
        }
        Ok(())
    }
}

/// The fail-closed evaluation fault the call latched, as an error.
fn take_fault() -> Result<(), SimulateError> {
    match super::take_const_array_oob() {
        Some(details) => {
            Err(crate::compile_error::CompileError::InterpreterBuildError { details }.into())
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
) -> Result<(), SimulateError> {
    let bad = |what: &str, got: usize, want: usize| {
        Err(build_error(format!(
            "`eval_into`: `{what}` has {got} elements, the program's layout {want}"
        )))
    };
    if u.len() != layout.u_len {
        return bad("u", u.len(), layout.u_len);
    }
    if du.len() != layout.u_len {
        return bad("du", du.len(), layout.u_len);
    }
    if aux.len() != layout.aux_len {
        return bad("aux", aux.len(), layout.aux_len);
    }
    if p.len() != n_params {
        return bad("p", p.len(), n_params);
    }
    Ok(())
}

/// The index-set name of each axis of each compiled state, from its
/// flattened declaration (empty when it names none at the compiled rank).
fn state_set_names(
    flat: &FlattenedSystem,
    compiled: &ArrayCompiled,
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
    let sizes = index_set_sizes(&prog.flat);
    let set_names = state_set_names(&prog.flat, &prog.compiled);
    let mut out = HashMap::new();
    for (name, vs) in &prog.compiled.var_shapes {
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
    for rule in &prog.compiled.observed_rules {
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
        let declared = prog
            .flat
            .observed_variables
            .get(var)
            .or_else(|| prog.flat.state_variables.get(var))
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
