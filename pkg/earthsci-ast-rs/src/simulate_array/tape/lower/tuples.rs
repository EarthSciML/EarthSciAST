//! Tuple-list contractions: a contraction whose admitted tuples are not a
//! box, compiled as the explicit list of those tuples and one
//! [`Instr::SegReduce`] over it.
//!
//! Two constructs admit a tuple set that is not the product of static
//! ranges:
//!
//! * a **join gate** (CONFORMANCE_SPEC §5.5.6 / §5.5.8), whose match set
//!   drives the interpreter's enumeration (`reduce_contraction_gated`);
//! * a **ragged** contraction bound `[1, offsets[parent]]` (esm-spec §4.3.1),
//!   which the interpreter re-derives per output cell (`ContractDim::concrete`).
//!
//! Both become the same form. At BUILD time the admitted tuples are
//! enumerated once, per output cell in row-major order and within a cell in
//! the interpreter's odometer order (the last contracted name fastest), from
//! build-time data: the gate's key columns or envelope factors and the ragged
//! offsets factor, each of which must be a value the build knows (an array
//! literal). Every loop symbol then becomes a constant column over the list,
//! the body and the filter are lowered once over that 1-D "tuple box", and
//! [`Instr::SegReduce`] folds each cell's run of terms in list order,
//! SKIPPING a term the filter excludes — `reduce_contraction`'s `continue`,
//! not a combine of the identity.
//!
//! A gate only ever narrows: the interpreter's gated walk is the exact
//! order-preserving subsequence of the full product that the gate admits, and
//! the filter still decides every leaf (an `on` gate's equality is lowered
//! into it by `crate::join`). So the list enumerated here, which applies the
//! same gates the same way, is a superset of the admitted tuples in the same
//! order, and the filter mask does the rest. That is what makes the fold
//! bit-identical, and it is also why a gate this build cannot resolve is a
//! refusal rather than a silent fallback to the full product: the fallback
//! would be correct but O(N²) to build and to run.
//!
//! Inside the body, `index` becomes an [`Instr::TableGather`] whose positions
//! are resolved here, from subscripts that are themselves build-time data
//! over the list (a loop symbol, a literal, or a gather of an array literal,
//! as in `u[cols[i, k]]`), exactly as `index_into` resolves them.

use super::*;
use crate::broad_phase::OverlapIndex;
use crate::simulate_array::eval::{EqSides, narrow_reach, reach_of};
use crate::simulate_array::gate_walk::{GatePlan, TupleSink};
use crate::types::JoinClause;

/// An open tuple-list box: its loop symbols' columns.
pub(in crate::simulate_array::tape) struct TupleFrame {
    id: u32,
    /// Output index names, then contracted names.
    names: Vec<String>,
    /// The column of each name, until it is first read (then its values live
    /// in the `ConstArray` that `slots` names).
    cols: Vec<Vec<f64>>,
    slots: Vec<Option<SlotId>>,
    len: usize,
}

/// One contracted dimension's bound, before an output cell is chosen.
pub(super) enum DimBound {
    Static(i64, i64),
    /// `[1, offsets[parent...]]`: the offsets factor's row-major values and
    /// shape (empty for a scalar), and where each parent is bound.
    Ragged {
        shape: DimU,
        vals: Arc<Vec<f64>>,
        parents: Vec<Parent>,
    },
}

/// Where a ragged bound's parent index is bound: an output axis (fixed for
/// the whole cell) or another contracted dim (bound by an outer level of the
/// cell's nest, esm-spec §4.3.1 "Ragged ranges").
#[derive(Clone, Copy)]
pub(super) enum Parent {
    Output(usize),
    Contracted(usize),
}

impl DimBound {
    /// Does this bound read a contracted dim, so it is only known once that
    /// dim is bound?
    pub(super) fn reads_contracted(&self) -> bool {
        matches!(self, DimBound::Ragged { parents, .. }
            if parents.iter().any(|p| matches!(p, Parent::Contracted(_))))
    }

    /// The bound under the output `cell` and the contracted values `cur`
    /// bound so far.
    pub(super) fn at(&self, cell: &[i64], cur: &[i64]) -> (i64, i64) {
        match self {
            DimBound::Static(l, h) => (*l, *h),
            DimBound::Ragged {
                shape,
                vals,
                parents,
            } => (1, ragged_bound(shape, vals, parents, cell, cur)),
        }
    }
}

/// An `on` clause the gate planner is pricing ([`TapeBuilder::build_join_gates`]).
struct EqCand<'a> {
    g: &'a crate::join::OnGate,
    clause_ix: usize,
    matches: usize,
    n_l: usize,
    n_r: usize,
    /// The keyed sides, held for the cheapest candidate only.
    sides: Option<EqSides>,
}

/// A join gate resolved from build-time data.
pub(super) struct BuiltGate {
    sym_src: String,
    sym_tgt: String,
    index: OverlapIndex,
    n_src: usize,
    n_tgt: usize,
    clause_ix: usize,
    /// The gate's test is also a conjunct of the aggregate's `filter` (an
    /// `on` gate, which `crate::join` lowers into it), so the gate only
    /// narrows an enumeration and never has to mask a cell itself.
    in_filter: bool,
}

/// The build-time value of one observed a folded tuple-list contraction
/// reads ([`TapeBuilder::tuple_fold_inputs`]): its shape (empty for a scalar)
/// and row-major values, shared by every chunk's tape.
pub(super) struct FoldInput {
    name: String,
    shape: DimU,
    vals: Arc<Vec<f64>>,
}

/// The admitted tuple list: per output cell a contiguous run.
pub(super) struct TupleList {
    pub(super) rows: Vec<u32>,
    /// One column per loop symbol (output names, then contracted names).
    pub(super) cols: Vec<Vec<f64>>,
}

impl TupleList {
    /// How many tuples the list holds.
    fn len(&self) -> usize {
        *self.rows.last().expect("rows has n_out + 1 entries") as usize
    }
}

/// The `(positions, keys)` of a 1-D data column keyed by each value's bits,
/// `-0.0` folded onto `+0.0` so that every pair `==` admits shares a key.
fn float_key_column(a: &ndarray::ArrayD<f64>) -> Option<(Vec<i64>, Vec<crate::relational::Key>)> {
    if a.ndim() != 1 {
        return None;
    }
    let keys = a
        .iter()
        .map(|&v| crate::relational::Key::Int((if v == 0.0 { 0.0 } else { v }).to_bits() as i64))
        .collect();
    Some(((1..=a.len() as i64).collect(), keys))
}

/// A tuple-list contraction with its bounds and gates resolved: what
/// [`TapeBuilder::lower_tuple_list`] lowers, and what
/// [`TapeBuilder::walk_tuple_contraction`] folds a chunk of cells' runs of at
/// a time.
#[derive(Clone, Copy)]
pub(super) struct TupleSpec<'a> {
    pub(super) idx_names: &'a [String],
    pub(super) ranges: &'a [(i64, i64)],
    pub(super) body: &'a Expr,
    pub(super) contract_names: &'a [String],
    pub(super) bounds: &'a [DimBound],
    pub(super) gates: &'a [BuiltGate],
    pub(super) reduce: ReduceKind,
    pub(super) filter: Option<&'a Expr>,
    /// What each cell's fold starts from: the semiring's identity, or the
    /// accumulator the previous window of the same cell's run left
    /// ([`TupleStream`]).
    pub(super) init: f64,
}

/// The default [`tuple_list_budget`]: about a million tuples. A tuple list
/// costs on the order of a hundred bytes per tuple once lowered and run (its
/// loop-symbol columns, one position table per gather, the gathered values
/// the build knows, and the slab's per-tuple registers), so this holds what
/// one program's tuple lists cost to roughly 100 MB however many pairs its
/// joins match.
pub(in crate::simulate_array) const DEFAULT_TUPLE_LIST_BUDGET: usize = 1 << 20;

thread_local! {
    static TUPLE_LIST_BUDGET: std::cell::Cell<Option<usize>> =
        const { std::cell::Cell::new(None) };
}

/// The most tuples one program's tuple lists may hold together: a CONST
/// contraction whose list would take the program past it is folded at build
/// time a chunk at a time ([`TapeBuilder::walk_tuple_contraction`]) instead
/// of being materialized whole (`ESS_TUPLE_LIST_BUDGET`, default
/// [`DEFAULT_TUPLE_LIST_BUDGET`]). It is the program's total and not a
/// per-list cap because a list's arrays live as long as the program does: a
/// hundred lists each under a per-list cap cost a hundred times it.
///
/// A tuning threshold, not a strategy switch: both sides of it run the same
/// lowering on the same kernels and answer bit for bit the same; it bounds
/// what a join that matches a large share of its product costs in memory.
/// Thread-local (seeded from the environment once), so one test process can
/// measure both arms.
pub(in crate::simulate_array) fn tuple_list_budget() -> usize {
    TUPLE_LIST_BUDGET.with(|c| match c.get() {
        Some(v) => v,
        None => {
            static ENV: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
            let v = *ENV.get_or_init(|| {
                std::env::var("ESS_TUPLE_LIST_BUDGET")
                    .ok()
                    .and_then(|v| v.trim().parse::<usize>().ok())
                    .unwrap_or(DEFAULT_TUPLE_LIST_BUDGET)
            });
            c.set(Some(v));
            v
        }
    })
}

/// Set [`tuple_list_budget`] for THIS thread, returning the previous value.
#[cfg(test)]
pub(in crate::simulate_array) fn set_tuple_list_budget(tuples: usize) -> usize {
    let prev = tuple_list_budget();
    TUPLE_LIST_BUDGET.with(|c| c.set(Some(tuples)));
    prev
}

#[cfg(test)]
thread_local! {
    /// Per chunk program [`TapeBuilder::eval_tuple_chunk`] built on this
    /// thread: the names of the inputs whose payload the program holds.
    static CHUNK_INPUTS_HELD: std::cell::RefCell<Vec<Vec<String>>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// Take what [`CHUNK_INPUTS_HELD`] recorded on this thread.
#[cfg(test)]
pub(in crate::simulate_array) fn take_chunk_inputs_held() -> Vec<Vec<String>> {
    CHUNK_INPUTS_HELD.with(|c| std::mem::take(&mut *c.borrow_mut()))
}

#[cfg(test)]
thread_local! {
    /// How many [`visit_tuples`] walks ran on this thread, and the tuple
    /// count of each list [`TapeBuilder::eval_tuple_chunk`] folded (a chunk
    /// of cells, or a window of one cell's run), in fold order.
    static TUPLE_WALKS: std::cell::RefCell<(usize, Vec<usize>)> =
        const { std::cell::RefCell::new((0, Vec::new())) };
}

/// Take what [`TUPLE_WALKS`] recorded on this thread: `(walks, chunk
/// lengths)`.
#[cfg(test)]
pub(in crate::simulate_array) fn take_tuple_walks() -> (usize, Vec<usize>) {
    TUPLE_WALKS.with(|c| std::mem::take(&mut *c.borrow_mut()))
}

impl TapeBuilder<'_> {
    /// Lower a join-gated or ragged contraction as a tuple list (module
    /// docs). The result is over the output box `ranges` (a scalar for a
    /// rank-0 output).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn lower_tuple_contraction(
        &mut self,
        idx_names: &[String],
        ranges: &[(i64, i64)],
        body: &Expr,
        contract_names: &[String],
        contract_dims: &[ContractDim],
        reduce: ReduceKind,
        filter: Option<&Expr>,
        join: Option<&[JoinClause]>,
    ) -> LResult<LV> {
        // A scalar reduction may be `bool_and_or`; an array-valued one may not
        // (CONFORMANCE_SPEC §5.6.1), outside the build pipeline.
        let combine_op = if ranges.is_empty() {
            scalar_combine_op(reduce)
        } else {
            self.array_combine_op(reduce, "contracted")?
        };
        // With nothing contracted the interpreter returns the body itself,
        // not `identity ⊕ body` (they differ on a `-0.0` term): each output
        // cell is one combination, kept or not by the gate.
        if contract_names.is_empty() {
            return self.lower_pointwise_gated(idx_names, ranges, body, reduce, filter, join);
        }
        let lo: DimI = ranges.iter().map(|(l, _)| *l).collect();
        let shape: DimU = ranges
            .iter()
            .map(|(l, h)| (h - l + 1).max(0) as usize)
            .collect();
        if shape.contains(&0) {
            bail_tape!("faq: empty output box");
        }
        let bounds = self.tuple_dim_bounds(idx_names, contract_names, contract_dims)?;
        let gates = match join {
            Some(j) => self.build_join_gates(j)?,
            None => Vec::new(),
        };
        if !gates.is_empty() && bounds.iter().any(DimBound::reads_contracted) {
            bail_tape!("contracted: a join gate over a ragged range whose parent is contracted");
        }
        let spec = TupleSpec {
            idx_names,
            ranges,
            body,
            contract_names,
            bounds: &bounds,
            gates: &gates,
            reduce,
            filter,
            init: reduce.identity(),
        };
        // One walk lists the tuples while they fit what is left of the
        // program's budget and, once they outgrow it, folds them a chunk at a
        // time as it goes ([`Self::walk_tuple_contraction`]): a list that fits
        // costs one walk, and so does one that is folded.
        let budget = tuple_list_budget() as u64;
        let room = budget
            .saturating_sub(self.tuples_held)
            .min(MAX_PROMOTED_ELEMS as u64) as usize;
        let too_long = || Bail {
            reason: format!("contracted: tuple list too long (over {MAX_PROMOTED_ELEMS} tuples)"),
        };
        let list = match self.walk_tuple_contraction(&spec, room, combine_op)? {
            Walked::Listed(list) => list,
            Walked::Folded(values) => {
                log_tuple_walk(&spec, "folded", None);
                return Ok(if ranges.is_empty() {
                    LV::Lit(values[0])
                } else {
                    LV::Arr(self.emit_const_data(&shape, &lo, Arc::new(values), false)?)
                });
            }
            Walked::TooLong => return Err(too_long()),
            // A chunk did not fold: list the whole contraction after all.
            Walked::Declined => {
                enumerate_tuples(&spec, MAX_PROMOTED_ELEMS)?.ok_or_else(too_long)?
            }
        };
        log_tuple_walk(&spec, "listed", Some(list.len()));
        // Charged whether or not the list fit: a list the fold declined is
        // held all the same.
        self.tuples_held = self.tuples_held.saturating_add(list.len() as u64);
        self.lower_tuple_list(&spec, list, &lo, &shape, combine_op)
    }

    /// The tuple-list form itself (module docs): lower the filter and the
    /// body once over the 1-D box of `list`, `spec`'s admitted tuples, and
    /// fold each cell's run with one [`Instr::SegReduce`].
    pub(super) fn lower_tuple_list(
        &mut self,
        spec: &TupleSpec<'_>,
        list: TupleList,
        lo: &DimI,
        shape: &DimU,
        combine_op: BinCode,
    ) -> LResult<LV> {
        let &TupleSpec {
            idx_names,
            ranges,
            body,
            contract_names,
            filter,
            init,
            ..
        } = spec;
        let (lo, shape) = (lo.clone(), shape.clone());
        // The value an empty run folds to, and each run's starting point.
        let identity = init;
        let m = list.len();
        let rank0 = ranges.is_empty();
        if m == 0 {
            // No cell admits a tuple: every cell is the identity.
            return Ok(if rank0 {
                LV::Lit(identity)
            } else {
                self.emit_fill(&LV::Lit(identity), &shape, &lo, Cadence::Const)
            });
        }

        let mut names: Vec<String> = idx_names.to_vec();
        names.extend(contract_names.iter().cloned());
        let id = self.next_tuple;
        self.next_tuple += 1;
        self.tuple_frames.push(TupleFrame {
            id,
            names,
            cols: list.cols,
            slots: vec![None; idx_names.len() + contract_names.len()],
            len: m,
        });
        self.push_scope();
        let bx = LBox {
            syms: &[],
            lo: DimI::from_elem(1, 1),
            shape: DimU::from_elem(m, 1),
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: id,
            visit: SmallVec::new(),
        };
        // The filter first: the oracle tests it before the body at every
        // tuple, and evaluates the body only at the tuples it keeps (a lazily
        // evaluated position). `None` for the term when no tuple is kept.
        let lowered = (|| -> LResult<(Option<LV>, Option<LV>)> {
            let mask = match filter {
                None => None,
                Some(f) => Some(self.lower_expr(f, &bx)?),
            };
            let lazy = match &mask {
                None => false,
                Some(LV::Lit(c)) if *c == 0.0 => return Ok((None, mask)),
                Some(LV::Lit(_)) => false,
                Some(_) => true,
            };
            self.lazy_depth += u32::from(lazy);
            let term = self.lower_expr(body, &bx);
            self.lazy_depth -= u32::from(lazy);
            Ok((Some(term?), mask))
        })();
        self.pop_scope();
        self.tuple_frames.pop();
        let (term, mask) = lowered?;
        let Some(term) = term else {
            // The filter excludes every tuple.
            return Ok(if rank0 {
                LV::Lit(identity)
            } else {
                self.emit_fill(&LV::Lit(identity), &shape, &lo, Cadence::Const)
            });
        };

        let tuple_box = |s: &Self, v: &LV| -> LResult<Option<SlotId>> {
            match (v, s.lv_box(v)) {
                (_, None) => Ok(None),
                (LV::Arr(slot), Some((sh, o))) if sh.as_slice() == [m] && o.as_slice() == [1] => {
                    Ok(Some(*slot))
                }
                _ => bail_tape!("contracted: a tuple-list term is not over the tuple list"),
            }
        };
        let src = match tuple_box(self, &term)? {
            Some(slot) => slot,
            None => match self.emit_fill(&term, &[m], &[1], Cadence::Const) {
                LV::Arr(slot) => slot,
                _ => unreachable!("a fill defines an array slot"),
            },
        };
        let mask = match mask {
            None | Some(LV::Lit(_)) => None,
            Some(v) => match tuple_box(self, &v)? {
                Some(slot) => Some(slot),
                None => match self.emit_fill(&v, &[m], &[1], Cadence::Const) {
                    LV::Arr(slot) => Some(slot),
                    _ => unreachable!("a fill defines an array slot"),
                },
            },
        };

        let table = tape_index(self.seg_tables.len(), "segmented reductions")?;
        self.seg_tables.push(SegTable { rows: list.rows });
        let mut want = self.slots[src as usize].cadence;
        if let Some(mk) = mask {
            want = want.max(self.slots[mk as usize].cadence);
        }
        let sec = self.placement(want);
        let out = if rank0 {
            self.new_slot(&[], &[], true, sec)
        } else {
            self.new_slot(&shape, &lo, false, sec)
        };
        self.emit(
            Instr::SegReduce {
                op: combine_op,
                init: identity,
                src,
                mask,
                table,
                out,
            },
            sec,
        );
        Ok(if rank0 { LV::Scalar(out) } else { LV::Arr(out) })
    }

    /// Walk `spec`'s admitted tuples ONCE ([`visit_tuples`]), listing them
    /// while they fit `room`, what is left of the program's
    /// [`tuple_list_budget`]. A CONST contraction whose list outgrows it is
    /// then folded at build time as the walk goes, a chunk of at most the
    /// budget's tuples at a time ([`TupleStream`]), into the values of its
    /// output box (one value for a rank-0 output). A contraction that is not
    /// build-time data (it reads a parameter, a state, the time or a forcing
    /// input) goes on being listed whole.
    ///
    /// The whole list is O(tuples), and a tuple costs about a hundred bytes
    /// lowered and run, which made peak memory track every candidate pair a
    /// join matches — times the width of every output axis the join does not
    /// gate — rather than the arrays a document declares (EarthSciAST#418's
    /// shape, returned by the tape). A cell's value depends only on that
    /// cell's run of tuples, and each chunk is the same lowering of the same
    /// expression on the same kernels ([`super::standalone`]) over whole
    /// cells' runs, so the folded array is bit-identical to what the
    /// materialized list computes; only the peak changes, to one chunk's.
    /// A cell whose run alone is over the budget is folded a window at a
    /// time, each window starting from the accumulator the last one left:
    /// `seg_reduce` is a left fold in list order, so that is the whole run's
    /// fold exactly, wherever the windows break.
    ///
    /// [`Walked::Declined`] when a chunk would not fold (it faults, or does
    /// not lower to a CONST): the caller then lists the whole contraction.
    fn walk_tuple_contraction(
        &self,
        spec: &TupleSpec<'_>,
        room: usize,
        combine_op: BinCode,
    ) -> LResult<Walked> {
        let n_cells: usize = spec
            .ranges
            .iter()
            .map(|(l, h)| (h - l + 1).max(0) as usize)
            .product();
        let mut s = TupleStream {
            b: self,
            spec,
            combine_op,
            n_cells,
            cols: vec![Vec::new(); spec.idx_names.len() + spec.contract_names.len()],
            rows: vec![0],
            cells: Vec::new(),
            held: 0,
            cell: 0,
            cap: room,
            fold_tried: false,
            fold: None,
            window: None,
            declined: false,
        };
        let whole = visit_tuples(spec, &mut s)?;
        if s.declined {
            return Ok(Walked::Declined);
        }
        if !whole {
            return Ok(Walked::TooLong);
        }
        if s.fold.is_none() {
            return Ok(Walked::Listed(TupleList {
                rows: s.rows,
                cols: s.cols,
            }));
        }
        if !s.cells.is_empty() && !s.flush_cells() {
            return Ok(Walked::Declined);
        }
        let fold = s.fold.expect("folding");
        Ok(Walked::Folded(fold.values))
    }

    /// The build-time value of every observed `spec`'s body and filter read
    /// ([`Self::known_named`]); `None` when one of them has none. Names that
    /// are not observeds are left to the chunk's own build, which declines
    /// what it cannot resolve.
    ///
    /// Taken once per fold and shared by every chunk's tape: each binds the
    /// same `Arc`, so no chunk copies an input
    /// ([`TapeBuilder::defer_consts`]).
    fn tuple_fold_inputs(&self, spec: &TupleSpec<'_>) -> Option<Vec<FoldInput>> {
        let mut reads: HashSet<String> = HashSet::new();
        standalone::collect_variable_names(spec.body, &mut reads);
        if let Some(f) = spec.filter {
            standalone::collect_variable_names(f, &mut reads);
        }
        let mut names: Vec<&String> = reads
            .iter()
            .filter(|n| !spec.idx_names.contains(n) && !spec.contract_names.contains(n))
            .filter(|n| self.obs_defined.contains_key(n.as_str()))
            .collect();
        names.sort();
        names
            .into_iter()
            .map(|name| {
                let (shape, vals) = self.known_named(name)?;
                (shape.iter().product::<usize>() == vals.len()).then(|| FoldInput {
                    name: name.clone(),
                    shape,
                    vals,
                })
            })
            .collect()
    }

    /// Lower the tuple `list` of `chunk` alone on a standalone tape over
    /// `inputs`, run it once, and return its row-major values; `None` when it
    /// does not lower, is not CONST, or notes a fault (whose order only the
    /// whole list places).
    fn eval_tuple_chunk(
        &self,
        chunk: &TupleSpec<'_>,
        list: TupleList,
        inputs: &[FoldInput],
        combine_op: BinCode,
    ) -> Option<Vec<f64>> {
        let name = "\u{0}tuple-list chunk";
        #[cfg(test)]
        TUPLE_WALKS.with(|c| c.borrow_mut().1.push(list.len()));
        standalone::with_standalone_builder(
            name,
            &[],
            self.const_arrays,
            self.f32_document,
            self.array_bool_reductions,
            |mut b| {
                b.defer_consts = true;
                for FoldInput { name, shape, vals } in inputs {
                    // A scalar is bound as the literal the enclosing build
                    // holds, unrounded, as that build reads it.
                    let lv = if shape.is_empty() {
                        LV::Lit(vals[0])
                    } else {
                        b.standalone_known_input(shape, Arc::clone(vals)).ok()?
                    };
                    b.obs_defined.insert(name.clone(), ObsVal::Taped(lv));
                }
                let lo: DimI = chunk.ranges.iter().map(|(l, _)| *l).collect();
                let shape: DimU = chunk
                    .ranges
                    .iter()
                    .map(|(l, h)| (h - l + 1) as usize)
                    .collect();
                let v = b
                    .lower_tuple_list(chunk, list, &lo, &shape, combine_op)
                    .ok()?;
                if b.fault_notes != 0
                    || b.fault_first.is_some()
                    || b.lv_cadence(&v) != Cadence::Const
                {
                    return None;
                }
                let v = match v {
                    LV::Lit(x) => return Some(vec![x; shape.iter().product()]),
                    v @ (LV::Arr(_) | LV::Scalar(_)) => v,
                    _ => return None,
                };
                b.obs_defined.insert(name.to_string(), ObsVal::Taped(v));
                // The rule stands for the chunk only so that its value is
                // exported.
                let rule = AlgebraicRule::Scalar {
                    var: name.to_string(),
                    body: std::sync::Arc::new(Expr::Number(0.0)),
                    declared_shape: (!shape.is_empty()).then(|| shape.to_vec()),
                };
                let prog = b.finish_standalone(&rule);
                #[cfg(test)]
                CHUNK_INPUTS_HELD.with(|c| {
                    let held = inputs
                        .iter()
                        .filter(|i| {
                            let n = i.vals.len();
                            prog.const_data.iter().any(|d| {
                                Arc::ptr_eq(&d.values, &i.vals)
                                    || (n > 1 && d.values.len() == n && d.values[..] == i.vals[..])
                            })
                        })
                        .map(|i| i.name.clone())
                        .collect();
                    c.borrow_mut().push(held);
                });
                let a = standalone::run_standalone_export(prog, name, &[], &[]).ok()?;
                Some(a.iter().copied().collect())
            },
        )
    }

    /// A join-gated aggregate with no contracted index: the gate admits or
    /// rejects each output cell, which the build resolves from its data into a
    /// constant mask. An admitted cell is the body (under the `filter`); a
    /// rejected one is the semiring's identity, and its body is not evaluated
    /// (a lazily evaluated position).
    fn lower_pointwise_gated(
        &mut self,
        idx_names: &[String],
        ranges: &[(i64, i64)],
        body: &Expr,
        reduce: ReduceKind,
        filter: Option<&Expr>,
        join: Option<&[JoinClause]>,
    ) -> LResult<LV> {
        let identity = reduce.identity();
        let gates = match join {
            Some(j) => self.build_join_gates(j)?,
            None => Vec::new(),
        };
        let lo: DimI = ranges.iter().map(|(l, _)| *l).collect();
        let shape: DimU = ranges
            .iter()
            .map(|(l, h)| (h - l + 1).max(0) as usize)
            .collect();
        if shape.contains(&0) {
            bail_tape!("faq: empty output box");
        }
        // Few candidate cells (the pairs a join matches, of a source x target
        // box): the body runs over those only (`lower_pointwise_compacted`),
        // when that lowers.
        if !ranges.is_empty()
            && let Some(cand) = pointwise_keep(idx_names, ranges, &gates, true)?
        {
            let kept = cand.iter().filter(|&&k| k != 0.0).count();
            if kept > 0 && kept * COMPACT_KEEP_DENOM <= cand.len() {
                let txn = self.sub_txn();
                match self
                    .lower_pointwise_compacted(idx_names, ranges, cand, body, filter, identity)
                {
                    Ok(v) => return Ok(v),
                    Err(_) => self.sub_rollback(txn),
                }
            }
        }
        let keep = pointwise_keep(idx_names, ranges, &gates, false)?;
        if keep.as_ref().is_some_and(|k| k.iter().all(|&k| k == 0.0)) {
            return Ok(if ranges.is_empty() {
                LV::Lit(identity)
            } else {
                self.emit_fill(&LV::Lit(identity), &shape, &lo, Cadence::Const)
            });
        }
        let bx = LBox {
            syms: idx_names,
            lo: lo.clone(),
            shape: shape.clone(),
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        let Some(keep) = keep.filter(|k| !k.iter().all(|&k| k != 0.0)) else {
            // The output box is its own value-numbering scope, as every box
            // lowering's is: the enclosing frame is a whole-body rule's (which
            // numbers whole values, not this box's) or another box's.
            self.push_scope();
            let term = self.lower_filtered(body, filter, &bx, LV::Lit(identity));
            self.pop_scope();
            return term.map(|t| t.unwrap_or(LV::Lit(identity)));
        };
        if ranges.is_empty() {
            bail_tape!("aggregate: a rank-0 join gate");
        }
        let mask_slot = self.emit_const_data(&shape, &lo, Arc::new(keep), false)?;
        self.lazy_depth += 1;
        self.push_scope();
        let term = self.lower_filtered(body, filter, &bx, LV::Lit(identity));
        self.pop_scope();
        self.lazy_depth -= 1;
        let term = term?.unwrap_or(LV::Lit(identity));
        self.emit_select(LV::Arr(mask_slot), term, LV::Lit(identity))
    }

    /// A join-gated pointwise `faq` whose gate keeps few cells, with the body
    /// evaluated at the kept cells only, as the oracle evaluates it. The kept
    /// cells are listed in row-major order as a 1-D box over `PW_SYM`; each
    /// output index becomes a read of its column, an inline literal, so
    /// `src[i]` reads `src[index([i at each kept cell], k)]`. The body and the
    /// filter are lowered once over that box, then every output cell gathers
    /// its own position in the list and the gate's mask selects the identity
    /// at the others: each kept cell holds the body's own value, bit for bit,
    /// and the work and the program grow with the kept cells, not the box
    /// (a conservative regrid's overlap areas: the candidate pairs, not
    /// source x target). The substituted body keeps the body's sharing: a
    /// node reached twice maps to one node.
    fn lower_pointwise_compacted(
        &mut self,
        idx_names: &[String],
        ranges: &[(i64, i64)],
        keep: Vec<f64>,
        body: &Expr,
        filter: Option<&Expr>,
        identity: f64,
    ) -> LResult<LV> {
        let bx = LBox {
            syms: idx_names,
            lo: ranges.iter().map(|(l, _)| *l).collect(),
            shape: ranges
                .iter()
                .map(|(l, h)| (h - l + 1).max(0) as usize)
                .collect(),
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        let bx = &bx;
        let nd = bx.shape.len();
        let mut strides = vec![1usize; nd];
        for d in (0..nd.saturating_sub(1)).rev() {
            strides[d] = strides[d + 1] * bx.shape[d + 1];
        }
        let mut cols: Vec<Vec<f64>> = vec![Vec::new(); nd];
        // Each output cell's 0-based position in the list (the first kept
        // cell at a dropped one, whose gathered value the mask discards).
        let mut pos = vec![0u32; keep.len()];
        let mut m = 0usize;
        for (p, &k) in keep.iter().enumerate() {
            if k == 0.0 {
                continue;
            }
            pos[p] = tape_index(m, "compacted cells")?;
            m += 1;
            for d in 0..nd {
                cols[d].push((bx.lo[d] + ((p / strides[d]) % bx.shape[d]) as i64) as f64);
            }
        }
        if m == 0 {
            bail_tape!("faq: no kept cell to compact");
        }
        let mut subs: FxHashMap<&str, Expr> = FxHashMap::default();
        for d in 0..nd {
            let col = Expr::operator(ExpressionNode {
                op: "const".to_string(),
                value: Some(serde_json::json!(cols[d])),
                ..Default::default()
            });
            subs.insert(
                bx.syms[d].as_str(),
                Expr::operator(ExpressionNode {
                    op: "index".to_string(),
                    args: vec![col, Expr::Variable(PW_SYM.to_string())],
                    ..Default::default()
                }),
            );
        }
        let mut memo: FxHashMap<*const ExpressionNode, Expr> = FxHashMap::default();
        let cbody = subst_shared(body, &subs, &mut memo);
        let cfilter = filter.map(|f| subst_shared(f, &subs, &mut memo));
        let syms = [PW_SYM.to_string()];
        let cbx = LBox {
            syms: &syms,
            lo: DimI::from_elem(1, 1),
            shape: DimU::from_elem(m, 1),
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        self.push_scope();
        let term = self.lower_filtered(&cbody, cfilter.as_ref(), &cbx, LV::Lit(identity));
        self.pop_scope();
        self.held_exprs.push(cbody);
        self.held_exprs.extend(cfilter);
        let term = term?.unwrap_or(LV::Lit(identity));
        let vals = match self.lv_box(&term) {
            Some((sh, o)) if sh.as_slice() == [m] && o.as_slice() == [1] => term,
            Some(_) => bail_tape!("faq: a compacted term is not over the kept cells"),
            None => self.emit_fill(&term, &[m], &[1], Cadence::Const),
        };
        // Every output cell gathers its position in the list, known at build:
        // one table gather into the box's cells in row-major order, then the
        // box's own shape.
        let n = pos.len();
        let table = tape_index(self.gather_tables.len(), "gather tables")?;
        self.gather_tables.push(GatherTable {
            src_shape: DimU::from_elem(m, 1),
            pos,
        });
        let sec = self.placement(self.lv_cadence(&vals));
        let flat = if nd == 1 {
            self.new_slot(&bx.shape, &bx.lo, false, sec)
        } else {
            self.new_slot(&[n], &[1], false, sec)
        };
        let instr = Instr::TableGather {
            src: self.src_of(&vals),
            table,
            out: flat,
        };
        self.emit(instr, sec);
        let gathered = if nd == 1 {
            LV::Arr(flat)
        } else {
            let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
            let instr = Instr::Reshape {
                src: SrcRef::Slot(flat),
                out,
            };
            self.emit(instr, sec);
            LV::Arr(out)
        };
        let mask_slot = self.emit_const_data(&bx.shape, &bx.lo, Arc::new(keep), false)?;
        self.emit_select(LV::Arr(mask_slot), gathered, LV::Lit(identity))
    }

    /// Resolve each contracted dimension's bound: a static interval as it
    /// stands, a ragged one against its offsets factor's build-time values.
    pub(super) fn tuple_dim_bounds(
        &mut self,
        idx_names: &[String],
        contract_names: &[String],
        contract_dims: &[ContractDim],
    ) -> LResult<Vec<DimBound>> {
        let mut out = Vec::with_capacity(contract_dims.len());
        for d in contract_dims {
            out.push(match d {
                ContractDim::Static(l, h) => DimBound::Static(*l, *h),
                ContractDim::Ragged { offsets, of } => {
                    // A parent is an output index (read from the cell) or
                    // another contracted index (read from the nest, which
                    // binds it first; see `parent_first_order`).
                    let parents = of
                        .iter()
                        .map(|p| {
                            if let Some(i) = idx_names.iter().position(|n| n == p) {
                                Ok(Parent::Output(i))
                            } else if let Some(i) = contract_names.iter().position(|n| n == p) {
                                Ok(Parent::Contracted(i))
                            } else {
                                Err(Bail {
                                    reason: format!(
                                        "contracted: ragged bound's parent `{p}` is not an index \
                                         of the node"
                                    ),
                                })
                            }
                        })
                        .collect::<LResult<Vec<Parent>>>()?;
                    let (shape, vals) = self.known_named(offsets).ok_or_else(|| Bail {
                        reason: format!(
                            "contracted: ragged offsets factor `{offsets}` is not build-time data"
                        ),
                    })?;
                    DimBound::Ragged {
                        shape,
                        vals,
                        parents,
                    }
                }
                ContractDim::Derived { from_faq } => match self.ring_extent(from_faq) {
                    Some(n) => DimBound::Static(1, n),
                    None => {
                        bail_tape!("contracted: derived contraction bound (from `{from_faq}`)")
                    }
                },
            });
        }
        Ok(out)
    }

    /// The build-time value of the variable `name` — an observed whose value
    /// the build knows, or a CONST-cadence observed it can fold
    /// ([`Self::fold_const_observed`]) — as `(shape, row-major values)`; a
    /// scalar has an empty shape and one value.
    pub(super) fn known_named(&self, name: &str) -> Option<(DimU, Arc<Vec<f64>>)> {
        match self.obs_defined.get(name)? {
            ObsVal::Taped(LV::Lit(x)) => Some((DimU::new(), Arc::new(vec![*x]))),
            ObsVal::Taped(LV::Arr(s)) => {
                let shape = self.slots[*s as usize].shape.clone();
                match self.known_values(*s) {
                    Some(v) => Some((shape, v)),
                    None => self.fold_const_observed(name),
                }
            }
            _ => None,
        }
    }

    /// Why an observed's value is not build-time data, for a refusal that
    /// names it: empty for a name that is not one of this program's
    /// observeds.
    fn not_foldable_note(&self, name: &str) -> &'static str {
        if self
            .observed_rules
            .iter()
            .any(|r| observed_rule_var(r) == name)
        {
            " (an observed whose value reads a parameter, a state, the time or a forcing \
             input, directly or through another observed, so it is not constant at build \
             time; CONFORMANCE_SPEC §5.5.8)"
        } else {
            ""
        }
    }

    /// A slot's build-time values, if the build knows them.
    pub(super) fn known_values(&self, s: SlotId) -> Option<Arc<Vec<f64>>> {
        match self.known.get(&s)? {
            Known::Data(d) => Some(Arc::clone(&self.const_data[*d as usize].values)),
            Known::Vals(v) | Known::Deferred { vals: v, .. } => Some(Arc::clone(v)),
        }
    }

    /// A slot's build-time values, borrowed, for a reader that only compares
    /// or looks up its elements.
    pub(super) fn known_slice(&self, s: SlotId) -> Option<&[f64]> {
        match self.known.get(&s)? {
            Known::Data(d) => Some(&self.const_data[*d as usize].values),
            Known::Vals(v) | Known::Deferred { vals: v, .. } => Some(v),
        }
    }

    /// Both keyed sides of an `on` clause, `(positions, keys)` left then
    /// right, from build-time data.
    fn on_gate_sides(&self, g: &crate::join::OnGate) -> LResult<EqSides> {
        // `exact_ints`: each data column must hold exact integers, which is
        // what the interpreter drives on. A clause over other values is
        // not a gate there — the filter's `==` decides every pair of the
        // full product — so here it drives on the values' bits instead
        // (`float_key_column`): the same pairs the filter admits, and
        // a NaN pair the filter then rejects, so the walk is still the
        // filtered product's order-preserving subsequence.
        let side = |cols: &[crate::join::KeyColumn], exact_ints: bool| -> LResult<_> {
            let mut parts = Vec::with_capacity(cols.len());
            for c in cols {
                parts.push(match c {
                    crate::join::KeyColumn::Const { positions, values } => {
                        if !exact_ints {
                            return Ok(None);
                        }
                        const_key_column(positions, values)
                    }
                    crate::join::KeyColumn::Column(name) => {
                        let a = self
                            .known_named(name)
                            .and_then(|(shape, vals)| {
                                ndarray::ArrayD::from_shape_vec(
                                    ndarray::IxDyn(&shape),
                                    (*vals).clone(),
                                )
                                .ok()
                            })
                            .ok_or_else(|| Bail {
                                reason: format!(
                                    "aggregate: join key column `{name}` is not build-time \
                                     data{}",
                                    self.not_foldable_note(name)
                                ),
                            })?;
                        let col = if exact_ints {
                            data_key_column(&a)
                        } else {
                            float_key_column(&a)
                        };
                        match col {
                            Some(col) => col,
                            None if exact_ints => return Ok(None),
                            None => bail_tape!(
                                "aggregate: join key column `{name}` is not a 1-D column"
                            ),
                        }
                    }
                });
            }
            composite_side_keys(parts).map(Some).ok_or_else(|| Bail {
                reason: "aggregate: a composite join key's columns disagree in length".to_string(),
            })
        };
        let sides = match (side(&g.cols_l, true)?, side(&g.cols_r, true)?) {
            (Some(l), Some(r)) => Some((l, r)),
            _ => match (side(&g.cols_l, false)?, side(&g.cols_r, false)?) {
                (Some(l), Some(r)) => Some((l, r)),
                _ => None,
            },
        };
        let Some(((pos_l, keys_l), (pos_r, keys_r))) = sides else {
            bail_tape!(
                "aggregate: a join clause pairs a literal key with a column that is not \
                 exact integers"
            );
        };
        Ok((pos_l, keys_l, pos_r, keys_r))
    }

    /// Resolve every drivable clause of `join` from build-time data, most
    /// selective first (the interpreter's §5.24 order). A drivable clause
    /// whose data the build does not know is a refusal (module docs).
    fn build_join_gates(&mut self, join: &[JoinClause]) -> LResult<Vec<BuiltGate>> {
        let mut gates = Vec::new();
        // How many distinct positions each gated symbol can still take, given
        // the gates built so far (the interpreter's `reach`).
        let mut reach: HashMap<String, usize> = HashMap::new();
        let mut candidates: Vec<EqCand<'_>> = Vec::new();
        let mut cheapest: Option<(usize, EqSides)> = None;
        for (clause_ix, clause) in join.iter().enumerate() {
            if let Some(ov) = &clause.overlap {
                let (Some(sym_src), Some(sym_tgt)) = (&ov.sym_src, &ov.sym_tgt) else {
                    continue;
                };
                let mut arrays: HashMap<String, ndarray::ArrayD<f64>> = HashMap::new();
                for name in ov.src_env.iter().chain(ov.tgt_env.iter()) {
                    let Some((shape, vals)) = self.known_named(name) else {
                        bail_tape!(
                            "aggregate: overlap join gate factor `{name}` is not build-time data"
                        );
                    };
                    let a =
                        ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&shape), (*vals).clone())
                            .map_err(|e| Bail {
                                reason: format!(
                                    "aggregate: overlap join gate factor `{name}`: {e}"
                                ),
                            })?;
                    arrays.insert(name.clone(), a);
                }
                let env = |names: &[String]| {
                    crate::broad_phase::envelope_vectors(names, &arrays).map_err(|e| Bail {
                        reason: format!("aggregate: overlap join gate: {e}"),
                    })
                };
                let (src, tgt) = (env(&ov.src_env)?, env(&ov.tgt_env)?);
                let pairs =
                    crate::broad_phase::broad_phase_candidates(&src, &tgt, ov.eps.unwrap_or(0.0));
                let index = OverlapIndex::from_zero_based(&pairs);
                narrow_reach(&mut reach, sym_src, index.len());
                narrow_reach(&mut reach, sym_tgt, index.len());
                gates.push(BuiltGate {
                    sym_src: sym_src.clone(),
                    sym_tgt: sym_tgt.clone(),
                    index,
                    n_src: src.len(),
                    n_tgt: tgt.len(),
                    clause_ix,
                    in_filter: false,
                });
                continue;
            }
            let Some(g) = &clause.on_gate else {
                continue;
            };
            if g.cols_l.len() != g.cols_r.len() || g.cols_l.is_empty() {
                continue;
            }
            // Priced before it is built, as the interpreter's planner prices
            // it (`resolve_gates`): only the cheapest candidate's keyed sides
            // are held while the others are counted.
            let sides = self.on_gate_sides(g)?;
            let matches = crate::relational::equijoin_match_count(&sides.1, &sides.3);
            let (n_l, n_r) = (sides.0.len(), sides.2.len());
            if cheapest.as_ref().is_none_or(|&(i, _)| {
                let c: &EqCand<'_> = &candidates[i];
                matches < c.matches
            }) {
                cheapest = Some((candidates.len(), sides));
            }
            candidates.push(EqCand {
                g,
                clause_ix,
                matches,
                n_l,
                n_r,
                sides: None,
            });
        }
        if let Some((slot, sides)) = cheapest {
            candidates[slot].sides = Some(sides);
        }
        // CHEAPEST FIRST, and an UNECONOMIC gate — one that would materialise
        // more pairs than the tuples it could prune — is declined when another
        // already drives. The tape built every gate, which is how a six-valued
        // key against a 1.4-million-row table came to hold a 1.2-billion-pair
        // index the interpreter never builds (EarthSciAST#418, PR #423).
        // Declining only widens the enumeration: an `on` gate's equality is
        // also a conjunct of the filter (`in_filter`), which masks the extra
        // tuples, and the walk stays the product's order-preserving
        // subsequence, so the fold is the same.
        candidates.sort_by_key(|c| (c.matches, c.clause_ix));
        let ratio = crate::broad_phase::gate_plan_ratio();
        let floor = crate::broad_phase::gate_plan_floor();
        for c in candidates {
            let space = (reach_of(&reach, &c.g.sym_l, c.n_l) as u128)
                .saturating_mul(reach_of(&reach, &c.g.sym_r, c.n_r) as u128);
            if !gates.is_empty()
                && c.matches >= floor
                && (c.matches as u128) > space.saturating_mul(ratio)
            {
                crate::broad_phase::bump_gate_plan_declines();
                continue;
            }
            let sides = match c.sides {
                Some(s) => s,
                None => self.on_gate_sides(c.g)?,
            };
            let (index, n_src, n_tgt) = index_from_sides(sides);
            narrow_reach(&mut reach, &c.g.sym_l, index.len());
            narrow_reach(&mut reach, &c.g.sym_r, index.len());
            gates.push(BuiltGate {
                sym_src: c.g.sym_l.clone(),
                sym_tgt: c.g.sym_r.clone(),
                index,
                n_src,
                n_tgt,
                clause_ix: c.clause_ix,
                in_filter: true,
            });
        }
        // `JoinGate::selectivity_cmp`: admitted fraction, then clause order.
        gates.sort_by(|a, b| {
            let (a1, s1) = (a.index.len() as i128, (a.n_src * a.n_tgt) as i128);
            let (a2, s2) = (b.index.len() as i128, (b.n_src * b.n_tgt) as i128);
            (a1 * s2)
                .cmp(&(a2 * s1))
                .then_with(|| a.clause_ix.cmp(&b.clause_ix))
        });
        Ok(gates)
    }

    /// The column slot of loop symbol `name` in tuple frame `id`, created on
    /// first read. `None` when `name` is not one of the frame's symbols.
    pub(super) fn tuple_column(&mut self, id: u32, name: &str) -> LResult<Option<LV>> {
        let Some(fi) = self.tuple_frames.iter().rposition(|f| f.id == id) else {
            return Ok(None);
        };
        let Some(ci) = self.tuple_frames[fi].names.iter().position(|n| n == name) else {
            return Ok(None);
        };
        if let Some(s) = self.tuple_frames[fi].slots[ci] {
            return Ok(Some(LV::Arr(s)));
        }
        let frame = &mut self.tuple_frames[fi];
        let len = frame.len;
        let values = std::mem::take(&mut frame.cols[ci]);
        // Every later read shares this slot, so it is defined unconditionally:
        // a first read inside a conditional branch still places the column
        // ahead of the branch, not in it.
        let out = self.emit_const_data(&[len], &[1], Arc::new(values), true)?;
        self.tuple_frames[fi].slots[ci] = Some(out);
        Ok(Some(LV::Arr(out)))
    }

    /// The per-tuple values of a subscript over the list, when the build
    /// knows them: a literal, a loop symbol, a gather of known data, or
    /// arithmetic (`+ - * /`) of those, folded with the interpreter's own
    /// kernel ([`apply_binary`], left to right as `eval` folds an n-ary node)
    /// so the positions are the ones `eval_index_args` computes. Arithmetic
    /// emits nothing: only the positions it yields are used.
    pub(super) fn tuple_known_values(
        &mut self,
        e: &Expr,
        bx: &LBox,
    ) -> LResult<Option<Arc<Vec<f64>>>> {
        let m = bx.shape[0];
        if let Expr::Operator(n) = e
            && matches!(n.op.as_str(), "+" | "-" | "*" | "/")
            && !n.args.is_empty()
            && n.expr.is_none()
        {
            let mut parts = Vec::with_capacity(n.args.len());
            for a in &n.args {
                match self.tuple_known_values(a, bx)? {
                    Some(v) => parts.push(v),
                    None => return Ok(None),
                }
            }
            let mut acc: Vec<f64> = if n.op == "-" && parts.len() == 1 {
                parts[0].iter().map(|&x| -x).collect()
            } else {
                (*parts[0]).clone()
            };
            if n.op == "-" && parts.len() > 2 || n.op == "/" && parts.len() != 2 {
                return Ok(None);
            }
            for p in &parts[1..] {
                for (a, &b) in acc.iter_mut().zip(p.iter()) {
                    *a = apply_binary(&n.op, *a, b);
                }
            }
            return Ok(Some(Arc::new(acc)));
        }
        Ok(match self.lower_expr(e, bx)? {
            LV::Lit(x) => Some(Arc::new(vec![x; m])),
            LV::Arr(s) => self.known_values(s).filter(|v| v.len() == m),
            _ => None,
        })
    }

    /// `index` inside a tuple-list body: the base is an array the body does
    /// not iterate (a variable, an inline literal, or a standalone
    /// expression), and every subscript is build-time data over the list, so
    /// each element's source position is resolved here — as `index_into`
    /// resolves it — into one [`Instr::TableGather`].
    pub(super) fn lower_tuple_index(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
    ) -> LResult<LV> {
        let Some((base_e, subs)) = node.args.split_first() else {
            bail_tape!("index: no arguments");
        };
        if let Expr::Variable(name) = base_e
            && self.tuple_column(bx.tuple, name)?.is_some()
        {
            bail_tape!("index: the base `{name}` is a loop symbol");
        }
        // The provenance `eval_index` gives the gather: a named const factor
        // or an inline literal obeys its boundary policy, anything else the
        // zero ghost.
        let const_name: Option<&str> = match base_e {
            Expr::Variable(name) if self.const_arrays.is_const(name) => Some(name.as_str()),
            b if ConstArrayScope::is_inline_const(b) => Some(INLINE_CONST_NAME),
            _ => None,
        };
        let base = self.lower_wholesale(base_e)?;
        let Some((src_shape, src_origin)) = self.lv_box(&base) else {
            return if subs.is_empty() {
                Ok(base)
            } else {
                bail_tape!(
                    "index: base is a scalar but {} index args given",
                    subs.len()
                )
            };
        };
        if subs.len() != src_shape.len() {
            bail_tape!(
                "index: arg count != source rank ({} args vs rank {})",
                subs.len(),
                src_shape.len()
            );
        }
        if src_origin.iter().any(|&o| o != 1) {
            bail_tape!("index: a tuple-list gather from an array whose origin is not 1");
        }
        let m = bx.shape[0];
        // Each subscript's per-tuple values.
        let mut sub_vals: Vec<Arc<Vec<f64>>> = Vec::with_capacity(subs.len());
        for e in subs {
            match self.tuple_known_values(e, bx)? {
                Some(vals) => sub_vals.push(vals),
                None => bail_tape!("index: a subscript that is not build-time data over the list"),
            }
        }
        let n_src: usize = src_shape.iter().product();
        if n_src >= GATHER_GHOST as usize {
            bail_tape!("index: gather source too large for a position table");
        }
        let mut strides: Vec<usize> = vec![1; src_shape.len()];
        for d in (0..src_shape.len().saturating_sub(1)).rev() {
            strides[d] = strides[d + 1] * src_shape[d + 1];
        }
        let mut pos: Vec<u32> = Vec::with_capacity(m);
        for k in 0..m {
            let mut flat = 0usize;
            let mut ghost = false;
            for (d, vals) in sub_vals.iter().enumerate() {
                // `eval_index_args`: the subscript rounded (NaN reads as 0).
                let raw = round_to_i64(vals[k]);
                let n = src_shape[d] as i64;
                let mut i1 = raw;
                if raw < 1 || raw > n {
                    match const_name {
                        None => ghost = true,
                        // `index_into`: an empty axis can never be wrapped
                        // or clamped into, so it is the error whatever the
                        // policy.
                        Some(name) => match (n >= 1).then(|| self.const_arrays.boundary(name, d)) {
                            Some(BoundaryKind::Periodic) => i1 = (raw - 1).rem_euclid(n) + 1,
                            Some(BoundaryKind::Clamp) => i1 = raw.clamp(1, n),
                            Some(BoundaryKind::Error) | None => bail_tape!(
                                "index: const-array gather out of range (§5.5.5) in a \
                                 tuple-list body"
                            ),
                        },
                    }
                }
                flat += ((i1 - 1).max(0) as usize) * strides[d];
            }
            pos.push(if ghost { GATHER_GHOST } else { flat as u32 });
        }
        // The gathered values, when the base's are known (a subscript of a
        // later gather reads them).
        let vals = match &base {
            LV::Arr(s) => self.known_slice(*s).map(|b| {
                pos.iter()
                    .map(|&p| {
                        if p == GATHER_GHOST {
                            0.0
                        } else {
                            b[p as usize]
                        }
                    })
                    .collect::<Vec<f64>>()
            }),
            _ => None,
        };
        // Under `defer_consts` the gathered values ARE the gather's result:
        // the `TableGather` would copy exactly these elements (the ghost as
        // `+0.0`) out of a slot that holds the whole base.
        if self.defer_consts
            && self.lv_cadence(&base) == Cadence::Const
            && let Some(v) = vals
        {
            return Ok(LV::Arr(self.emit_const_data(
                &[m],
                &[1],
                Arc::new(v),
                false,
            )?));
        }
        let table = tape_index(self.gather_tables.len(), "gather tables")?;
        self.gather_tables.push(GatherTable { src_shape, pos });
        let sec = self.placement(self.lv_cadence(&base));
        let out = self.new_slot(&[m], &[1], false, sec);
        let instr = Instr::TableGather {
            src: self.src_of(&base),
            table,
            out,
        };
        self.emit(instr, sec);
        if let Some(v) = vals {
            self.known.insert(out, Known::Vals(Arc::new(v)));
        }
        Ok(LV::Arr(out))
    }
}

/// The tape builder's counterpart of the interpreter's per-node `[join-gate]`
/// stderr line: which gates drove a tuple-list contraction, over how many
/// output cells, and how many tuples it listed (or that it was folded in
/// chunks instead). Only for a gated node, as in the interpreter, and only
/// when `ESS_JOIN_GATE_LOG` asks for it
/// ([`crate::broad_phase::join_gate_log_enabled`]).
fn log_tuple_walk(spec: &TupleSpec<'_>, how: &str, tuples: Option<usize>) {
    if !crate::broad_phase::join_gate_log_enabled() {
        return;
    }
    if spec.gates.is_empty() {
        return;
    }
    let desc = spec
        .gates
        .iter()
        .map(|g| format!("{}~{}:{}", g.sym_src, g.sym_tgt, g.index.len()))
        .collect::<Vec<_>>()
        .join(",");
    // Saturating: a large output box must not overflow a diagnostic.
    let cells: u128 = spec
        .ranges
        .iter()
        .map(|(l, h)| (h - l + 1).max(0) as u128)
        .fold(1u128, u128::saturating_mul);
    match tuples {
        Some(n) => eprintln!("[join-gate] tape gates={desc} cells={cells} {how} tuples={n}"),
        None => eprintln!("[join-gate] tape gates={desc} cells={cells} {how}"),
    }
}

/// Enumerate the tuple list of `spec`: output cells in row-major order, each
/// cell's contraction tuples in the odometer order under the cell's bounds and
/// the gates, exactly as `reduce_contraction_gated` walks them. `None` as soon
/// as it would hold more than `cap` tuples, so an over-long list is abandoned
/// at `cap` rather than built whole.
fn enumerate_tuples(spec: &TupleSpec<'_>, cap: usize) -> LResult<Option<TupleList>> {
    struct Enumerate {
        cols: Vec<Vec<f64>>,
        rows: Vec<u32>,
        len: usize,
        cap: usize,
    }
    impl VisitTuples for Enumerate {
        #[inline]
        fn tuple(&mut self, cell: &[i64], t: &[i64]) -> bool {
            if self.len == self.cap {
                return false;
            }
            for (col, &v) in self.cols.iter_mut().zip(cell.iter().chain(t)) {
                col.push(v as f64);
            }
            self.len += 1;
            true
        }
        fn cell_done(&mut self) -> LResult<()> {
            self.rows.push(self.len as u32);
            Ok(())
        }
    }
    let mut e = Enumerate {
        cols: vec![Vec::new(); spec.idx_names.len() + spec.contract_names.len()],
        rows: vec![0],
        len: 0,
        cap,
    };
    let whole = visit_tuples(spec, &mut e)?;
    Ok(whole.then_some(TupleList {
        rows: e.rows,
        cols: e.cols,
    }))
}

/// What [`TapeBuilder::walk_tuple_contraction`]'s one walk produced.
enum Walked {
    /// The whole list, within the room the program's budget left.
    Listed(TupleList),
    /// The output box's values, row-major, folded a chunk at a time.
    Folded(Vec<f64>),
    /// A chunk would not fold: list the whole contraction instead.
    Declined,
    /// Not build-time data, and over [`MAX_PROMOTED_ELEMS`] tuples.
    TooLong,
}

/// The fold state of a [`TupleStream`] once its list outgrew its room.
struct StreamFold {
    inputs: Vec<FoldInput>,
    /// The output box's values, row-major; a cell with no tuple keeps the
    /// identity.
    values: Vec<f64>,
    /// The most tuples one chunk (or one window of a cell's run) holds.
    budget: usize,
}

/// The visitor of [`TapeBuilder::walk_tuple_contraction`]'s walk: it lists
/// each admitted tuple, and once the list outgrows `cap` (and the
/// contraction is build-time data) folds what it holds and goes on folding,
/// a chunk at a time, as the walk produces tuples.
///
/// While listing, `rows` has an entry for every cell walked. While folding,
/// `cols` holds the pending chunk: the runs of the cells in `cells` (only
/// cells with at least one tuple; `rows` bounds their runs), then the run so
/// far of the cell being walked. A chunk is flushed when the next tuple would
/// take it past the budget; a cell whose run alone fills it is folded a
/// window at a time, its accumulator in `window`.
struct TupleStream<'s, 'b, 'a> {
    b: &'s TapeBuilder<'b>,
    spec: &'s TupleSpec<'a>,
    combine_op: BinCode,
    n_cells: usize,
    cols: Vec<Vec<f64>>,
    rows: Vec<u32>,
    cells: Vec<usize>,
    /// How many tuples `cols` holds.
    held: usize,
    /// The row-major position of the cell being walked.
    cell: usize,
    /// While listing: the most tuples the list may hold.
    cap: usize,
    fold_tried: bool,
    fold: Option<StreamFold>,
    window: Option<f64>,
    /// A chunk did not fold: the walk stopped, and the caller lists.
    declined: bool,
}

impl TupleStream<'_, '_, '_> {
    /// The list holds `cap` tuples and one more is coming: switch to folding
    /// if the contraction is build-time data, or go on listing up to
    /// [`MAX_PROMOTED_ELEMS`]. `false` when neither has room.
    fn outgrown(&mut self) -> bool {
        if !self.fold_tried {
            self.fold_tried = true;
            if let Some(inputs) = self.b.tuple_fold_inputs(self.spec) {
                // A window's run table is `u32`, and a chunk is held whole.
                let budget = tuple_list_budget().clamp(1, MAX_PROMOTED_ELEMS);
                // Keep only the cells with a run: an empty one is the
                // identity, which `values` already holds.
                let mut rows = vec![0u32];
                let mut cells = Vec::new();
                for (c, w) in self.rows.windows(2).enumerate() {
                    if w[1] > w[0] {
                        cells.push(c);
                        rows.push(w[1]);
                    }
                }
                self.rows = rows;
                self.cells = cells;
                self.fold = Some(StreamFold {
                    inputs,
                    values: vec![self.spec.reduce.identity(); self.n_cells.max(1)],
                    budget,
                });
                // `cap` (the room left) is never over the whole budget, so
                // what the list holds fits one chunk.
                return true;
            }
        }
        if self.cap < MAX_PROMOTED_ELEMS {
            self.cap = MAX_PROMOTED_ELEMS;
            return true;
        }
        false
    }

    /// Fold the runs of the complete cells the chunk holds, and keep only
    /// the run so far of the cell being walked. `false` when the chunk does
    /// not fold.
    fn flush_cells(&mut self) -> bool {
        let start = *self.rows.last().expect("rows starts at 0") as usize;
        let tail: Vec<Vec<f64>> = self.cols.iter_mut().map(|c| c.split_off(start)).collect();
        let list = TupleList {
            rows: std::mem::replace(&mut self.rows, vec![0]),
            cols: std::mem::replace(&mut self.cols, tail),
        };
        self.held -= start;
        let cells = std::mem::take(&mut self.cells);
        // The chunk's cells as one run of output positions: a rank-0 output
        // is its one cell.
        let flat = [(1i64, cells.len() as i64)];
        let ranges: &[(i64, i64)] = if self.spec.ranges.is_empty() {
            &[]
        } else {
            &flat
        };
        let chunk = TupleSpec {
            ranges,
            ..*self.spec
        };
        let fold = self.fold.as_mut().expect("folding");
        match self
            .b
            .eval_tuple_chunk(&chunk, list, &fold.inputs, self.combine_op)
        {
            Some(v) if v.len() == cells.len() => {
                for (c, x) in cells.into_iter().zip(v) {
                    fold.values[c] = x;
                }
                true
            }
            _ => false,
        }
    }

    /// Fold what the chunk holds, all of it the run so far of the cell being
    /// walked, as one window from the accumulator the last window left.
    /// `false` when the window does not fold.
    fn flush_window(&mut self) -> bool {
        let width = self.cols.len();
        let fold = self.fold.as_ref().expect("folding");
        let init = self.window.unwrap_or(self.spec.reduce.identity());
        let list = TupleList {
            rows: vec![0, self.held as u32],
            cols: std::mem::replace(&mut self.cols, vec![Vec::new(); width]),
        };
        self.held = 0;
        let one = [(1i64, 1i64)];
        let ranges: &[(i64, i64)] = if self.spec.ranges.is_empty() {
            &[]
        } else {
            &one
        };
        let chunk = TupleSpec {
            ranges,
            init,
            ..*self.spec
        };
        match self
            .b
            .eval_tuple_chunk(&chunk, list, &fold.inputs, self.combine_op)
            .as_deref()
        {
            Some(&[x]) => {
                self.window = Some(x);
                true
            }
            _ => false,
        }
    }
}

impl VisitTuples for TupleStream<'_, '_, '_> {
    #[inline]
    fn tuple(&mut self, cell: &[i64], t: &[i64]) -> bool {
        if self.declined {
            return false;
        }
        if self.fold.is_none() && self.held == self.cap && !self.outgrown() {
            return false;
        }
        // The chunk is full. Fold the complete cells it holds, which leaves
        // the run so far of this cell, under the budget; or, when it holds
        // nothing else, that run is a window of its own.
        if let Some(f) = &self.fold
            && self.held >= f.budget
        {
            let ok = if self.cells.is_empty() {
                self.flush_window()
            } else {
                self.flush_cells()
            };
            if !ok {
                self.declined = true;
                return false;
            }
        }
        for (col, &v) in self.cols.iter_mut().zip(cell.iter().chain(t)) {
            col.push(v as f64);
        }
        self.held += 1;
        true
    }

    fn cell_done(&mut self) -> LResult<()> {
        let start = *self.rows.last().expect("rows starts at 0") as usize;
        if self.fold.is_none() {
            self.rows.push(self.held as u32);
        } else if self.window.is_some() {
            // The rest of a windowed cell's run (the chunk holds nothing
            // else) is its last window.
            if self.held > 0 && !self.flush_window() {
                self.declined = true;
            }
            let acc = self.window.take().expect("windowed");
            self.fold.as_mut().expect("folding").values[self.cell] = acc;
        } else if self.held > start {
            self.cells.push(self.cell);
            self.rows.push(self.held as u32);
        }
        self.cell += 1;
        Ok(())
    }
}

/// What [`visit_tuples`] hands each admitted tuple and each finished cell to.
/// Generic rather than a `dyn` callback, so that the per-tuple step inlines
/// into the walk.
trait VisitTuples {
    /// One admitted `(cell, contracted tuple)`; `false` stops the walk.
    fn tuple(&mut self, cell: &[i64], t: &[i64]) -> bool;
    /// Called once per output cell, row-major, after that cell's tuples.
    fn cell_done(&mut self) -> LResult<()>;
}

/// The walk [`enumerate_tuples`] and
/// [`TapeBuilder::walk_tuple_contraction`] share: `v` sees each admitted
/// `(cell, contracted tuple)` of `spec` in list order, and each output cell,
/// row-major, once its tuples are done. A tuple the visitor refuses stops
/// the walk, and the result is then `false`.
fn visit_tuples(spec: &TupleSpec<'_>, v: &mut impl VisitTuples) -> LResult<bool> {
    #[cfg(test)]
    TUPLE_WALKS.with(|c| c.borrow_mut().0 += 1);
    let &TupleSpec {
        idx_names,
        ranges,
        contract_names,
        bounds,
        gates,
        ..
    } = spec;
    let nc = contract_names.len();
    // The cell-independent plan (built once, not per cell), and each gate's
    // output position for the symbols a cell binds.
    let plan = GatePlan::new(
        nc,
        gates.iter().map(|g| {
            (
                &g.index,
                gate_axis(&g.sym_src, idx_names, contract_names),
                gate_axis(&g.sym_tgt, idx_names, contract_names),
            )
        }),
    );
    let out_pos = |name: &str| idx_names.iter().position(|n| n == name);
    let bound_at: Vec<(Option<usize>, Option<usize>)> = gates
        .iter()
        .map(|g| (out_pos(&g.sym_src), out_pos(&g.sym_tgt)))
        .collect();
    let mut bufs = plan.bufs();

    let mut cell: Vec<i64> = ranges.iter().map(|(l, _)| *l).collect();
    let n_cells: usize = ranges
        .iter()
        .map(|(l, h)| (h - l + 1).max(0) as usize)
        .product::<usize>()
        .max(1);
    let mut cur: Vec<i64> = vec![0; nc];
    // A ragged dim whose parent is contracted has no bound until that parent
    // is bound: the cell's tuples are then a nest, not a box (no gates here;
    // `lower_tuple_contraction` refuses the pair).
    let nest = bounds
        .iter()
        .any(DimBound::reads_contracted)
        .then(|| parent_first_order(bounds));
    // This cell's contraction bounds, in a buffer reused across cells.
    let mut cell_ranges: Vec<(i64, i64)> = Vec::with_capacity(nc);
    for _ in 0..n_cells {
        if let Some(order) = &nest {
            let mut push = |t: &[i64]| v.tuple(&cell, t);
            if !walk_nest(bounds, order, 0, &cell, &mut cur, &mut push) {
                return Ok(false);
            }
            v.cell_done()?;
            next_cell(&mut cell, ranges);
            continue;
        }
        cell_ranges.clear();
        cell_ranges.extend(bounds.iter().map(|b| b.at(&cell, &cur)));
        // The gates' conjunction, the empty-range guard and the propagation,
        // then the walk: all shared with the interpreter
        // (`crate::simulate_array::gate_walk`).
        let admitted = plan.restrict_cell(
            &cell_ranges,
            |g, src| {
                let (a, b) = bound_at[g];
                (if src { a } else { b }).map(|p| cell[p])
            },
            &mut bufs,
        );
        if admitted {
            let mut sink = PushSink { cell: &cell, v };
            if !plan.walk_cell(&cell_ranges, &mut bufs, &mut sink) {
                return Ok(false);
            }
        }
        v.cell_done()?;
        next_cell(&mut cell, ranges);
    }
    Ok(true)
}

/// Step `cell` to the next output cell of `ranges`, row-major.
fn next_cell(cell: &mut [i64], ranges: &[(i64, i64)]) {
    let mut d = cell.len();
    while d > 0 {
        d -= 1;
        cell[d] += 1;
        if cell[d] <= ranges[d].1 {
            break;
        }
        cell[d] = ranges[d].0;
    }
}

/// The contracted dims' nest order: the odometer's own order (first dim
/// outermost), except that a ragged dim moves after every contracted parent
/// it reads, stably — the interpreter's `parent_first_order`.
pub(super) fn parent_first_order(bounds: &[DimBound]) -> Vec<usize> {
    let n = bounds.len();
    let parents_of = |i: usize| -> Vec<usize> {
        match &bounds[i] {
            DimBound::Ragged { parents, .. } => parents
                .iter()
                .filter_map(|p| match p {
                    Parent::Contracted(j) if *j != i => Some(*j),
                    _ => None,
                })
                .collect(),
            DimBound::Static(..) => Vec::new(),
        }
    };
    let mut order = Vec::with_capacity(n);
    let mut placed = vec![false; n];
    while order.len() < n {
        let next = (0..n)
            .find(|&i| !placed[i] && parents_of(i).iter().all(|&j| placed[j]))
            .or_else(|| (0..n).find(|&i| !placed[i]))
            .expect("an unplaced dim remains");
        placed[next] = true;
        order.push(next);
    }
    order
}

/// The nest over the contracted dims in `order`, each level's bound resolved
/// once every outer level is bound, ascending at every level: the order the
/// interpreter's `fold_dependent_nest` visits. `cur` stays indexed by
/// contracted position, so the tuple's columns keep their usual order.
pub(super) fn walk_nest(
    bounds: &[DimBound],
    order: &[usize],
    depth: usize,
    cell: &[i64],
    cur: &mut Vec<i64>,
    push: &mut impl FnMut(&[i64]) -> bool,
) -> bool {
    if depth == order.len() {
        return push(cur);
    }
    let d = order[depth];
    let (lo, hi) = bounds[d].at(cell, cur);
    for v in lo..=hi {
        cur[d] = v;
        if !walk_nest(bounds, order, depth + 1, cell, cur, push) {
            return false;
        }
    }
    true
}

/// A gated pointwise `faq` is compacted to its kept cells when at most one
/// cell in this many is kept.
const COMPACT_KEEP_DENOM: usize = 4;

/// The loop symbol of a compacted pointwise box (never an authored name).
const PW_SYM: &str = "__esm_pw_k";

/// `e` with each read of a name in `subs` replaced, a node reached twice
/// mapping to one node (by address), and a sub-tree with nothing to replace
/// returned as it stands.
fn subst_shared(
    e: &Expr,
    subs: &FxHashMap<&str, Expr>,
    memo: &mut FxHashMap<*const ExpressionNode, Expr>,
) -> Expr {
    match e {
        Expr::Variable(v) => subs.get(v.as_str()).cloned().unwrap_or_else(|| e.clone()),
        Expr::Operator(n) => {
            let key = Arc::as_ptr(n);
            if let Some(hit) = memo.get(&key) {
                return hit.clone();
            }
            let mut changed = false;
            let node = n.map_children(&mut |c| {
                let r = subst_shared(c, subs, memo);
                changed |= !same_expr(&r, c);
                r
            });
            let out = if changed {
                Expr::operator(node)
            } else {
                e.clone()
            };
            memo.insert(key, out.clone());
            out
        }
        _ => e.clone(),
    }
}

fn same_expr(a: &Expr, b: &Expr) -> bool {
    match (a, b) {
        (Expr::Operator(x), Expr::Operator(y)) => Arc::ptr_eq(x, y),
        (Expr::Variable(x), Expr::Variable(y)) => x == y,
        (Expr::Integer(x), Expr::Integer(y)) => x == y,
        (Expr::Number(x), Expr::Number(y)) => x.to_bits() == y.to_bits(),
        _ => false,
    }
}

/// The admitted cells of a gated aggregate with no contracted index, as a
/// row-major 0/1 mask over the output box: what [`enumerate_tuples`] admits
/// with nothing contracted (a cell is kept when every gate over two output
/// symbols holds its pair), built from each gate's pair list rather than by
/// testing every cell. A gate the aggregate's `filter` already tests is left
/// to the filter (with `with_filtered`, its pairs narrow the mask too, to a
/// superset of the admitted cells the filter then decides); `None` when no
/// gate masks a cell.
fn pointwise_keep(
    idx_names: &[String],
    ranges: &[(i64, i64)],
    gates: &[BuiltGate],
    with_filtered: bool,
) -> LResult<Option<Vec<f64>>> {
    let shape: Vec<usize> = ranges
        .iter()
        .map(|(l, h)| (h - l + 1).max(0) as usize)
        .collect();
    let n: usize = shape.iter().product::<usize>().max(1);
    let mut strides = vec![1usize; shape.len()];
    for d in (0..shape.len().saturating_sub(1)).rev() {
        strides[d] = strides[d + 1] * shape[d + 1];
    }
    // `None` until a gate applies: then the cells every applicable gate so
    // far admits.
    let mut keep: Option<Vec<f64>> = None;
    for g in gates.iter().filter(|g| with_filtered || !g.in_filter) {
        let pos = |s: &str| idx_names.iter().position(|x| x == s);
        let (Some(a), Some(b)) = (pos(&g.sym_src), pos(&g.sym_tgt)) else {
            continue;
        };
        // Offsets of every combination of the other output axes.
        let mut offsets = vec![0usize];
        for d in 0..shape.len() {
            if d == a || d == b {
                continue;
            }
            let (len, stride) = (shape[d], strides[d]);
            offsets = offsets
                .iter()
                .flat_map(|&o| (0..len).map(move |k| o + k * stride))
                .collect();
        }
        let in_range = |d: usize, v: i64| v >= ranges[d].0 && v <= ranges[d].1;
        let mut admitted = vec![0.0f64; n];
        for (s, t) in g.index.pairs() {
            if !in_range(a, s) || !in_range(b, t) || (a == b && s != t) {
                continue;
            }
            let base = (s - ranges[a].0) as usize * strides[a]
                + if a == b {
                    0
                } else {
                    (t - ranges[b].0) as usize * strides[b]
                };
            for &o in &offsets {
                admitted[base + o] = match &keep {
                    Some(k) => k[base + o],
                    None => 1.0,
                };
            }
        }
        keep = Some(admitted);
    }
    if let Some(k) = &keep
        && n > MAX_PROMOTED_ELEMS
    {
        let m = k.iter().filter(|&&k| k != 0.0).count();
        if m > MAX_PROMOTED_ELEMS {
            bail_tape!("contracted: tuple list too long ({m} tuples)");
        }
    }
    Ok(keep)
}

/// [`visit_tuples`]' [`TupleSink`]: hand each admitted tuple, with its output
/// cell, to the visitor.
struct PushSink<'a, V> {
    cell: &'a [i64],
    v: &'a mut V,
}

impl<V: VisitTuples> TupleSink for PushSink<'_, V> {
    #[inline]
    fn bind(&mut self, _d: usize, _v: i64) {}

    #[inline]
    fn leaf(&mut self, cur: &[i64]) -> bool {
        self.v.tuple(self.cell, cur)
    }
}

/// `ragged_upper_bound` over build-time values: the offsets factor at the
/// parents' values (from the output `cell` or the contracted values `cur`),
/// rounded; `0` for a parent below 1 or out of range, or for a factor whose
/// rank is not the parent count.
pub(super) fn ragged_bound(
    shape: &[usize],
    vals: &[f64],
    parents: &[Parent],
    cell: &[i64],
    cur: &[i64],
) -> i64 {
    if shape.is_empty() {
        return round_to_i64(vals[0]);
    }
    if parents.len() != shape.len() {
        return 0;
    }
    let mut flat = 0usize;
    for (d, &p) in parents.iter().enumerate() {
        let v = match p {
            Parent::Output(i) => cell[i],
            Parent::Contracted(i) => cur[i],
        };
        if v < 1 || v as usize > shape[d] {
            return 0;
        }
        flat = flat * shape[d] + (v - 1) as usize;
    }
    round_to_i64(vals[flat])
}

/// `x.round() as i64`, bit for bit, without the call to libm's `round` (not
/// an instruction on baseline x86-64) when `x` is already integral, as a
/// subscript or a ragged bound almost always is: then the truncating cast is
/// exact and is the rounded value. A value it does not round-trip (a
/// fraction, a NaN, or one past `i64`'s range) takes `round` as before.
#[inline]
pub(super) fn round_to_i64(x: f64) -> i64 {
    let i = x as i64;
    if i as f64 == x { i } else { x.round() as i64 }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [`round_to_i64`] is `round() as i64` on every class of value: exact
    /// integers, halves (away from zero), signed zeros, NaN, infinities and
    /// values past `i64`'s range on both sides.
    #[test]
    fn round_to_i64_is_round_then_cast() {
        let mut xs = vec![
            0.0,
            -0.0,
            0.5,
            -0.5,
            1.5,
            2.5,
            -2.5,
            0.49999999999999994,
            -0.49999999999999994,
            3.0,
            -7.0,
            1e15 + 0.5,
            4503599627370497.0,
            9.223372036854776e18,
            -9.223372036854776e18,
            1e300,
            -1e300,
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::MIN_POSITIVE,
            f64::EPSILON,
        ];
        xs.extend((-40..=40).map(|k| k as f64 * 0.25));
        for x in xs {
            assert_eq!(round_to_i64(x), x.round() as i64, "{x:e}");
        }
    }

    fn gate(src: &str, tgt: &str, pairs: &[(i64, i64)], clause_ix: usize) -> BuiltGate {
        BuiltGate {
            sym_src: src.to_string(),
            sym_tgt: tgt.to_string(),
            index: OverlapIndex::from_pairs(pairs),
            n_src: 0,
            n_tgt: 0,
            clause_ix,
            in_filter: false,
        }
    }

    /// The pair-driven mask admits exactly the cells the per-cell walk does:
    /// gates over two of three output axes (in either order, one reaching
    /// outside the box), a gate on a symbol that is not an output axis, and
    /// no gate at all.
    #[test]
    fn pointwise_keep_matches_the_cell_walk() {
        let names: Vec<String> = ["i", "k", "j"].iter().map(|s| s.to_string()).collect();
        let ranges = [(1, 4), (0, 2), (2, 6)];
        let gate_sets = vec![
            vec![],
            vec![gate(
                "i",
                "j",
                &[(1, 2), (1, 5), (3, 3), (4, 6), (4, 9), (9, 2)],
                0,
            )],
            vec![
                gate("j", "i", &[(2, 1), (3, 3), (6, 4), (5, 2)], 0),
                gate("k", "i", &[(0, 1), (2, 3), (1, 4), (2, 4)], 1),
            ],
            vec![gate("i", "q", &[(1, 1)], 0)],
        ];
        let body = Expr::Number(0.0);
        for gates in &gate_sets {
            let spec = TupleSpec {
                idx_names: &names,
                ranges: &ranges,
                body: &body,
                contract_names: &[],
                bounds: &[],
                gates,
                reduce: ReduceKind::Sum,
                filter: None,
                init: 0.0,
            };
            let list = enumerate_tuples(&spec, usize::MAX)
                .expect("walks")
                .expect("uncapped");
            let walked: Vec<f64> = list
                .rows
                .windows(2)
                .map(|w| if w[1] > w[0] { 1.0 } else { 0.0 })
                .collect();
            let keep = pointwise_keep(&names, &ranges, gates, false)
                .expect("keeps")
                .unwrap_or_else(|| vec![1.0; walked.len()]);
            assert_eq!(keep, walked);
        }
    }

    /// The tuple list under both-contracted gates is exactly the admitted
    /// tuples in odometer order — no more (every gate restricts, and a pin
    /// propagates), no fewer (many-to-many partners all survive) — for a star
    /// into the last contracted dim and a chain off an output pin.
    #[test]
    fn contracted_gates_list_exactly_the_admitted_tuples() {
        // Output `w` over 1..=3; contracted `a, b, c` over 1..=4.
        let names: Vec<String> = vec!["w".into()];
        let contracted: Vec<String> = ["a", "b", "c"].iter().map(|s| s.to_string()).collect();
        let ranges = [(1, 3)];
        let bounds = [
            DimBound::Static(1, 4),
            DimBound::Static(1, 4),
            DimBound::Static(1, 4),
        ];
        let p = |v: &[(i64, i64)]| v.to_vec();
        let ab = p(&[(1, 2), (1, 3), (2, 2), (3, 4), (4, 1), (4, 3)]);
        let ac = p(&[(1, 1), (1, 4), (2, 2), (3, 3), (4, 4), (4, 1)]);
        let bc = p(&[(2, 1), (2, 4), (3, 3), (1, 2), (4, 4), (3, 1)]);
        let wc = p(&[(1, 1), (1, 4), (2, 3), (3, 2)]);
        let gate_sets: Vec<Vec<BuiltGate>> = vec![
            // Star into `c`.
            vec![gate("a", "c", &ac, 0), gate("b", "c", &bc, 1)],
            // Star into `c` with `c` pinned by the output.
            vec![
                gate("a", "c", &ac, 0),
                gate(
                    "c",
                    "b",
                    &bc.iter().map(|&(x, y)| (y, x)).collect::<Vec<_>>(),
                    1,
                ),
                gate("w", "c", &wc, 2),
            ],
            // Chain `w~c`, `b~c`, `a~b`: the pin crosses two gates.
            vec![
                gate("w", "c", &wc, 0),
                gate("b", "c", &bc, 1),
                gate("a", "b", &ab, 2),
            ],
            // All three pairwise, plus the pin.
            vec![
                gate("a", "b", &ab, 0),
                gate("a", "c", &ac, 1),
                gate("b", "c", &bc, 2),
                gate("w", "c", &wc, 3),
            ],
        ];
        let body = Expr::Number(0.0);
        for gates in &gate_sets {
            let spec = TupleSpec {
                idx_names: &names,
                ranges: &ranges,
                body: &body,
                contract_names: &contracted,
                bounds: &bounds,
                gates,
                reduce: ReduceKind::Sum,
                filter: None,
                init: 0.0,
            };
            let list = enumerate_tuples(&spec, usize::MAX)
                .expect("walks")
                .expect("uncapped");
            let sym = |n: &str, w: i64, t: &[i64]| -> i64 {
                match n {
                    "w" => w,
                    "a" => t[0],
                    "b" => t[1],
                    _ => t[2],
                }
            };
            let mut want: Vec<Vec<f64>> = vec![Vec::new(); 4];
            let mut rows = vec![0u32];
            for w in 1..=3 {
                for a in 1..=4 {
                    for b in 1..=4 {
                        for c in 1..=4 {
                            let t = [a, b, c];
                            if gates.iter().all(|g| {
                                g.index
                                    .contains(sym(&g.sym_src, w, &t), sym(&g.sym_tgt, w, &t))
                            }) {
                                for (k, v) in [w, a, b, c].into_iter().enumerate() {
                                    want[k].push(v as f64);
                                }
                            }
                        }
                    }
                }
                rows.push(want[0].len() as u32);
            }
            assert!(!want[0].is_empty());
            assert_eq!(list.rows, rows);
            assert_eq!(list.cols, want);
        }
    }
}
