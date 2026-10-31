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
use crate::broad_phase::{OverlapIndex, Side};
use crate::simulate_array::eval::{EqSides, narrow_reach, reach_of};
use crate::types::JoinClause;
use std::rc::Rc;

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
enum DimBound {
    Static(i64, i64),
    /// `[1, offsets[parent...]]`: the offsets factor's row-major values and
    /// shape (empty for a scalar), and where each parent is bound.
    Ragged {
        shape: DimU,
        vals: Rc<Vec<f64>>,
        parents: Vec<Parent>,
    },
}

/// Where a ragged bound's parent index is bound: an output axis (fixed for
/// the whole cell) or another contracted dim (bound by an outer level of the
/// cell's nest, esm-spec §4.3.1 "Ragged ranges").
#[derive(Clone, Copy)]
enum Parent {
    Output(usize),
    Contracted(usize),
}

impl DimBound {
    /// Does this bound read a contracted dim, so it is only known once that
    /// dim is bound?
    fn reads_contracted(&self) -> bool {
        matches!(self, DimBound::Ragged { parents, .. }
            if parents.iter().any(|p| matches!(p, Parent::Contracted(_))))
    }

    /// The bound under the output `cell` and the contracted values `cur`
    /// bound so far.
    fn at(&self, cell: &[i64], cur: &[i64]) -> (i64, i64) {
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
struct BuiltGate {
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

/// The admitted tuple list: per output cell a contiguous run.
struct TupleList {
    rows: Vec<u32>,
    /// One column per loop symbol (output names, then contracted names).
    cols: Vec<Vec<f64>>,
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

/// One contracted dimension's enumeration source within one output cell.
enum Src<'a> {
    Range(i64, i64),
    List(&'a [i64]),
}

/// A tuple-list contraction with its bounds and gates resolved: what
/// [`TapeBuilder::lower_tuple_list`] lowers, and what
/// [`TapeBuilder::fold_tuple_contraction`] folds a sub-box of at a time.
#[derive(Clone, Copy)]
struct TupleSpec<'a> {
    idx_names: &'a [String],
    ranges: &'a [(i64, i64)],
    body: &'a Expr,
    contract_names: &'a [String],
    bounds: &'a [DimBound],
    gates: &'a [BuiltGate],
    reduce: ReduceKind,
    filter: Option<&'a Expr>,
    /// What each cell's fold starts from: the semiring's identity, or the
    /// accumulator the previous window of the same cell's run left
    /// ([`TapeBuilder::fold_cell_in_windows`]).
    init: f64,
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
/// time a sub-box at a time ([`TapeBuilder::fold_tuple_contraction`]) instead
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
        // The list is built in the same walk that measures it, and abandoned
        // once it outgrows what is left of the program's budget, so a list
        // that fits costs one walk and one that does not costs at most the
        // budget before it is folded instead.
        let budget = tuple_list_budget() as u64;
        let room = budget
            .saturating_sub(self.tuples_held)
            .min(MAX_PROMOTED_ELEMS as u64) as usize;
        let list = match enumerate_tuples(&spec, room)? {
            Some(list) => list,
            None => {
                if let Some(v) = self.fold_tuple_contraction(&spec, &lo, &shape, combine_op)? {
                    return Ok(v);
                }
                enumerate_tuples(&spec, MAX_PROMOTED_ELEMS)?.ok_or_else(|| Bail {
                    reason: format!(
                        "contracted: tuple list too long (over {MAX_PROMOTED_ELEMS} tuples)"
                    ),
                })?
            }
        };
        // Charged whether or not the list fit: a list the fold declined is
        // held all the same.
        self.tuples_held = self.tuples_held.saturating_add(list.len() as u64);
        self.lower_tuple_list(&spec, list, &lo, &shape, combine_op)
    }

    /// The tuple-list form itself (module docs): lower the filter and the
    /// body once over the 1-D box of `list`, `spec`'s admitted tuples, and
    /// fold each cell's run with one [`Instr::SegReduce`].
    fn lower_tuple_list(
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

    /// Fold a CONST tuple-list contraction whose list would take the program
    /// past [`tuple_list_budget`] at build time, one output sub-box at a time,
    /// into a single [`Instr::ConstArray`] (a literal, for a rank-0 output).
    /// `None` when anything the contraction reads is not build-time data (a
    /// parameter, a state, the time, a forcing input), or when a chunk would
    /// fault: the caller then lowers the whole list as before.
    ///
    /// The whole list is O(tuples), and a tuple costs about a hundred bytes
    /// lowered and run, which made peak memory track every candidate pair a
    /// join matches — times the width of every output axis the join does not
    /// gate — rather than the arrays a document declares (EarthSciAST#418's
    /// shape, returned by the tape). A cell's value depends only on that
    /// cell's run of tuples, and each chunk is the same lowering of the same
    /// expression on the same kernels ([`super::standalone`]) over a sub-box
    /// of whole cells, so the folded array is bit-identical to what the
    /// materialized list computes; only the peak changes, to one chunk's.
    fn fold_tuple_contraction(
        &mut self,
        spec: &TupleSpec<'_>,
        lo: &DimI,
        shape: &DimU,
        combine_op: BinCode,
    ) -> LResult<Option<LV>> {
        let Some(inputs) = self.tuple_fold_inputs(spec) else {
            return Ok(None);
        };
        // A window's run table is `u32`, and a chunk is enumerated whole.
        let budget = (tuple_list_budget() as u64).clamp(1, MAX_PROMOTED_ELEMS as u64);
        // A rank-0 output is one cell: there is no sub-box to split it into,
        // so its run is folded a window at a time.
        if spec.ranges.is_empty() {
            let acc = self.fold_cell_in_windows(spec, &inputs, combine_op, budget)?;
            return Ok(acc.map(LV::Lit));
        }
        let counts = count_tuples(spec)?;
        let n_cells: usize = shape.iter().product();
        let mut strides = vec![1usize; shape.len()];
        for d in (0..shape.len().saturating_sub(1)).rev() {
            strides[d] = strides[d + 1] * shape[d + 1];
        }
        let mut values = vec![spec.reduce.identity(); n_cells];
        for sub in plan_chunks(spec.ranges, shape, &strides, &counts, budget) {
            let sub_shape: Vec<usize> = sub.iter().map(|(l, h)| (h - l + 1) as usize).collect();
            let base: usize = sub
                .iter()
                .zip(spec.ranges)
                .zip(&strides)
                .map(|(((l, _), (l0, _)), st)| (l - l0) as usize * st)
                .sum();
            // The sub-box's cells, row-major, as flat positions in the box.
            let mut cells: Vec<usize> = vec![base];
            for (&n, &st) in sub_shape.iter().zip(&strides) {
                let mut next = Vec::with_capacity(cells.len() * n);
                for &c in &cells {
                    next.extend((0..n).map(|k| c + k * st));
                }
                cells = next;
            }
            if cells.iter().all(|&c| counts[c] == 0) {
                continue; // every cell is the identity already
            }
            let chunk = TupleSpec {
                ranges: &sub,
                ..*spec
            };
            if let [c] = cells[..]
                && counts[c] > budget
            {
                // One cell whose run alone is over the budget.
                let Some(acc) = self.fold_cell_in_windows(&chunk, &inputs, combine_op, budget)?
                else {
                    return Ok(None);
                };
                values[c] = acc;
                continue;
            }
            let Some(list) = enumerate_tuples(&chunk, MAX_PROMOTED_ELEMS)? else {
                return Ok(None);
            };
            let Some(v) = self.eval_tuple_chunk(&chunk, list, &inputs, combine_op) else {
                return Ok(None);
            };
            if v.len() != cells.len() {
                return Ok(None);
            }
            for (&c, x) in cells.iter().zip(v) {
                values[c] = x;
            }
        }
        let data = tape_index(self.const_data.len(), "array constants")?;
        self.const_data.push(ConstArrayData {
            shape: shape.clone(),
            values,
        });
        let sec = self.placement(Cadence::Const);
        let out = self.new_slot(shape, lo, false, sec);
        self.emit(Instr::ConstArray { data, out }, sec);
        Ok(Some(LV::Arr(out)))
    }

    /// Fold the run of `cell`'s one output cell (a single-cell sub-box, or a
    /// rank-0 output) a window of at most `budget` tuples at a time, each
    /// window starting from the accumulator the last one left. `seg_reduce`
    /// is a left fold in list order, so this is the whole run's fold exactly.
    /// The run is walked once and only one window is held at a time. `None`
    /// when a window does not fold ([`Self::eval_tuple_chunk`]).
    fn fold_cell_in_windows(
        &self,
        cell: &TupleSpec<'_>,
        inputs: &[(String, ndarray::ArrayD<f64>)],
        combine_op: BinCode,
        budget: u64,
    ) -> LResult<Option<f64>> {
        let nr = cell.idx_names.len();
        let width = nr + cell.contract_names.len();
        let mut acc = Some(cell.reduce.identity());
        let mut cols: Vec<Vec<f64>> = vec![Vec::new(); width];
        let mut held = 0u64;
        let flush = |cols: &mut Vec<Vec<f64>>, held: &mut u64, acc: &mut Option<f64>| {
            let window = TupleList {
                rows: vec![0, *held as u32],
                cols: std::mem::replace(cols, vec![Vec::new(); width]),
            };
            *held = 0;
            *acc = acc.and_then(|init| {
                let chunk = TupleSpec { init, ..*cell };
                match self
                    .eval_tuple_chunk(&chunk, window, inputs, combine_op)
                    .as_deref()
                {
                    Some(&[x]) => Some(x),
                    _ => None,
                }
            });
        };
        visit_tuples(
            cell,
            &mut |c: &[i64], t: &[i64]| {
                for (k, &v) in c.iter().chain(t).enumerate() {
                    cols[k].push(v as f64);
                }
                held += 1;
                if held >= budget {
                    flush(&mut cols, &mut held, &mut acc);
                }
                // A window that does not fold ends the walk.
                acc.is_some()
            },
            &mut || Ok(()),
        )?;
        if held > 0 {
            flush(&mut cols, &mut held, &mut acc);
        }
        Ok(acc)
    }

    /// The build-time value of every observed `spec`'s body and filter read
    /// ([`Self::known_inputs`]); `None` when one of them has none. Names that
    /// are not observeds are left to the chunk's own build, which declines
    /// what it cannot resolve.
    fn tuple_fold_inputs(
        &self,
        spec: &TupleSpec<'_>,
    ) -> Option<Vec<(String, ndarray::ArrayD<f64>)>> {
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
        self.known_inputs(names)
    }

    /// Lower the tuple `list` of `chunk` alone on a standalone tape over
    /// `inputs`, run it once, and return its row-major values; `None` when it
    /// does not lower, is not CONST, or notes a fault (whose order only the
    /// whole list places).
    fn eval_tuple_chunk(
        &self,
        chunk: &TupleSpec<'_>,
        list: TupleList,
        inputs: &[(String, ndarray::ArrayD<f64>)],
        combine_op: BinCode,
    ) -> Option<Vec<f64>> {
        let name = "\u{0}tuple-list chunk";
        standalone::with_standalone_builder(
            name,
            &[],
            self.const_arrays,
            self.f32_document,
            self.array_bool_reductions,
            |mut b| {
                for (input, value) in inputs {
                    // A scalar is bound as the literal the enclosing build
                    // holds, unrounded, as that build reads it.
                    let lv = match value.ndim() {
                        0 => LV::Lit(value[ndarray::IxDyn(&[])]),
                        _ => b.standalone_array_input(value).ok()?,
                    };
                    b.obs_defined.insert(input.clone(), ObsVal::Taped(lv));
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
        let keep = pointwise_keep(idx_names, ranges, &gates)?;
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
            return self
                .lower_filtered(body, filter, &bx, LV::Lit(identity))
                .map(|t| t.unwrap_or(LV::Lit(identity)));
        };
        if ranges.is_empty() {
            bail_tape!("aggregate: a rank-0 join gate");
        }
        let data = tape_index(self.const_data.len(), "array constants")?;
        self.const_data.push(ConstArrayData {
            shape: shape.clone(),
            values: keep,
        });
        let sec = self.placement(Cadence::Const);
        let mask_slot = self.new_slot(&shape, &lo, false, sec);
        self.emit(
            Instr::ConstArray {
                data,
                out: mask_slot,
            },
            sec,
        );
        self.known.insert(mask_slot, Known::Data(data));
        self.lazy_depth += 1;
        let term = self.lower_filtered(body, filter, &bx, LV::Lit(identity));
        self.lazy_depth -= 1;
        let term = term?.unwrap_or(LV::Lit(identity));
        self.emit_select(LV::Arr(mask_slot), term, LV::Lit(identity))
    }

    /// Resolve each contracted dimension's bound: a static interval as it
    /// stands, a ragged one against its offsets factor's build-time values.
    fn tuple_dim_bounds(
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
    pub(super) fn known_named(&self, name: &str) -> Option<(DimU, Rc<Vec<f64>>)> {
        match self.obs_defined.get(name)? {
            ObsVal::Taped(LV::Lit(x)) => Some((DimU::new(), Rc::new(vec![*x]))),
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
    pub(super) fn known_values(&self, s: SlotId) -> Option<Rc<Vec<f64>>> {
        match self.known.get(&s)? {
            Known::Data(d) => Some(Rc::new(self.const_data[*d as usize].values.clone())),
            Known::Vals(v) => Some(Rc::clone(v)),
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
        let data = tape_index(self.const_data.len(), "array constants")?;
        self.const_data.push(ConstArrayData {
            shape: DimU::from_elem(len, 1),
            values,
        });
        let sec = self.placement(Cadence::Const);
        let out = self.new_slot(&[len], &[1], false, sec);
        // Every later read shares this slot, so it is defined unconditionally:
        // a first read inside a conditional branch still places the column
        // ahead of the branch, not in it.
        let branches = std::mem::take(&mut self.branch_bufs);
        self.emit(Instr::ConstArray { data, out }, sec);
        self.branch_bufs = branches;
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
    ) -> LResult<Option<Rc<Vec<f64>>>> {
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
            return Ok(Some(Rc::new(acc)));
        }
        Ok(match self.lower_expr(e, bx)? {
            LV::Lit(x) => Some(Rc::new(vec![x; m])),
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
        let mut sub_vals: Vec<Rc<Vec<f64>>> = Vec::with_capacity(subs.len());
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
                let raw = vals[k].round() as i64;
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
            LV::Arr(s) => self.known_values(*s).map(|b| {
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
            self.known.insert(out, Known::Vals(Rc::new(v)));
        }
        Ok(LV::Arr(out))
    }
}

/// Enumerate the tuple list of `spec`: output cells in row-major order, each
/// cell's contraction tuples in the odometer order under the cell's bounds and
/// the gates, exactly as `reduce_contraction_gated` walks them. `None` as soon
/// as it would hold more than `cap` tuples, so an over-long list is abandoned
/// at `cap` rather than built whole.
fn enumerate_tuples(spec: &TupleSpec<'_>, cap: usize) -> LResult<Option<TupleList>> {
    let width = spec.idx_names.len() + spec.contract_names.len();
    let mut cols: Vec<Vec<f64>> = vec![Vec::new(); width];
    let mut rows: Vec<u32> = vec![0];
    let len = std::cell::Cell::new(0usize);
    let whole = visit_tuples(
        spec,
        &mut |cell: &[i64], t: &[i64]| {
            if len.get() == cap {
                return false;
            }
            for (k, &v) in cell.iter().chain(t).enumerate() {
                cols[k].push(v as f64);
            }
            len.set(len.get() + 1);
            true
        },
        &mut || {
            rows.push(len.get() as u32);
            Ok(())
        },
    )?;
    Ok(whole.then_some(TupleList { rows, cols }))
}

/// How many tuples [`enumerate_tuples`] admits in each output cell of `spec`,
/// in the same row-major cell order, without materializing a column: what
/// [`TapeBuilder::fold_tuple_contraction`] splits the output box by.
fn count_tuples(spec: &TupleSpec<'_>) -> LResult<Vec<u64>> {
    let mut counts: Vec<u64> = Vec::new();
    let here = std::cell::Cell::new(0u64);
    visit_tuples(
        spec,
        &mut |_: &[i64], _: &[i64]| {
            here.set(here.get() + 1);
            true
        },
        &mut || {
            counts.push(here.replace(0));
            Ok(())
        },
    )?;
    Ok(counts)
}

/// The walk [`enumerate_tuples`], [`count_tuples`] and
/// [`TapeBuilder::fold_cell_in_windows`] share: `tuple` sees each admitted
/// `(cell, contracted tuple)` of `spec` in list order, and `cell_done` is
/// called once per output cell, row-major, after that cell's tuples. `tuple`
/// returning `false` stops the walk, and the result is then `false`.
fn visit_tuples(
    spec: &TupleSpec<'_>,
    tuple: &mut dyn FnMut(&[i64], &[i64]) -> bool,
    cell_done: &mut dyn FnMut() -> LResult<()>,
) -> LResult<bool> {
    let &TupleSpec {
        idx_names,
        ranges,
        contract_names,
        bounds,
        gates,
        ..
    } = spec;
    let nc = contract_names.len();
    let placed: Vec<(GateAxis, GateAxis)> = gates
        .iter()
        .map(|g| {
            (
                gate_axis(&g.sym_src, idx_names, contract_names),
                gate_axis(&g.sym_tgt, idx_names, contract_names),
            )
        })
        .collect();
    let out_pos = |name: &str| idx_names.iter().position(|n| n == name);

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
    for _ in 0..n_cells {
        if let Some(order) = &nest {
            let mut push = |t: &[i64]| tuple(&cell, t);
            if !walk_nest(bounds, order, 0, &cell, &mut cur, &mut push) {
                return Ok(false);
            }
            cell_done()?;
            next_cell(&mut cell, ranges);
            continue;
        }
        // This cell's contraction bounds.
        let cell_ranges: Vec<(i64, i64)> = bounds.iter().map(|b| b.at(&cell, &cur)).collect();
        // The gates' conjunction for this cell (`reduce_contraction_gated`,
        // phase 1).
        let mut restrict: Vec<Option<Vec<i64>>> = vec![None; nc];
        let mut pair: Option<(&BuiltGate, usize, usize, bool)> = None;
        let mut reject = false;
        for (g, &(ps, pt)) in gates.iter().zip(&placed) {
            match (ps, pt) {
                (GateAxis::Output, GateAxis::Output) => {
                    let (Some(a), Some(b)) = (out_pos(&g.sym_src), out_pos(&g.sym_tgt)) else {
                        continue;
                    };
                    if !g.index.contains(cell[a], cell[b]) {
                        reject = true;
                    }
                }
                (GateAxis::Contracted(d), GateAxis::Output) => {
                    let Some(b) = out_pos(&g.sym_tgt) else {
                        continue;
                    };
                    let (lo, hi) = cell_ranges[d];
                    let parts = g.index.partners_in(Side::Tgt, cell[b], lo, hi);
                    if !intersect(&mut restrict[d], parts) {
                        reject = true;
                    }
                }
                (GateAxis::Output, GateAxis::Contracted(d)) => {
                    let Some(a) = out_pos(&g.sym_src) else {
                        continue;
                    };
                    let (lo, hi) = cell_ranges[d];
                    let parts = g.index.partners_in(Side::Src, cell[a], lo, hi);
                    if !intersect(&mut restrict[d], parts) {
                        reject = true;
                    }
                }
                // The first (most selective) both-contracted gate drives.
                (GateAxis::Contracted(a), GateAxis::Contracted(b)) if a != b && pair.is_none() => {
                    pair = Some(if a < b {
                        (g, a, b, true)
                    } else {
                        (g, b, a, false)
                    });
                }
                _ => {}
            }
            if reject {
                break;
            }
        }
        if !reject && nc > 0 {
            let srcs: Vec<Src> = (0..nc)
                .map(|d| match &restrict[d] {
                    Some(v) => Src::List(v),
                    None => Src::Range(cell_ranges[d].0, cell_ranges[d].1),
                })
                .collect();
            let mut push = |t: &[i64]| tuple(&cell, t);
            if !walk(&srcs, pair, 0, &mut cur, &mut push) {
                return Ok(false);
            }
        } else if !reject && !tuple(&cell, &[]) {
            // No contracted index: the pointwise term, once.
            return Ok(false);
        }
        cell_done()?;
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
fn parent_first_order(bounds: &[DimBound]) -> Vec<usize> {
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
fn walk_nest(
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

/// Split the output box `ranges` (of `shape`, row-major `strides`) into
/// sub-boxes of whole cells holding at most `budget` tuples each, by
/// `counts` (per cell, row-major): runs of consecutive values along the
/// leading axis, and a value whose slice alone is over the budget split the
/// same way along the next axis. A single cell over the budget is a chunk of
/// its own — a cell's run is never split, so each cell still folds its own
/// tuples in list order.
fn plan_chunks(
    ranges: &[(i64, i64)],
    shape: &[usize],
    strides: &[usize],
    counts: &[u64],
    budget: u64,
) -> Vec<Vec<(i64, i64)>> {
    fn split(
        d: usize,
        base: usize,
        sub: &mut Vec<(i64, i64)>,
        g: (&[(i64, i64)], &[usize], &[usize], &[u64], u64),
        out: &mut Vec<Vec<(i64, i64)>>,
    ) {
        let (ranges, shape, strides, counts, budget) = g;
        let run = strides[d];
        let l0 = ranges[d].0;
        let flush =
            |sub: &mut Vec<(i64, i64)>, out: &mut Vec<Vec<(i64, i64)>>, a: usize, b: usize| {
                sub[d] = (l0 + a as i64, l0 + b as i64 - 1);
                out.push(sub.clone());
            };
        let (mut start, mut acc) = (0usize, 0u64);
        for v in 0..shape[d] {
            let c: u64 = counts[base + v * run..base + (v + 1) * run].iter().sum();
            if c > budget && d + 1 < shape.len() {
                if start < v {
                    flush(sub, out, start, v);
                }
                sub[d] = (l0 + v as i64, l0 + v as i64);
                split(d + 1, base + v * run, sub, g, out);
                sub[d + 1..].copy_from_slice(&ranges[d + 1..]);
                (start, acc) = (v + 1, 0);
                continue;
            }
            if acc + c > budget && start < v {
                flush(sub, out, start, v);
                (start, acc) = (v, 0);
            }
            acc += c;
        }
        if start < shape[d] {
            flush(sub, out, start, shape[d]);
        }
    }
    let mut out = Vec::new();
    let mut sub = ranges.to_vec();
    split(
        0,
        0,
        &mut sub,
        (ranges, shape, strides, counts, budget),
        &mut out,
    );
    out
}

/// The admitted cells of a gated aggregate with no contracted index, as a
/// row-major 0/1 mask over the output box: what [`enumerate_tuples`] admits
/// with nothing contracted (a cell is kept when every gate over two output
/// symbols holds its pair), built from each gate's pair list rather than by
/// testing every cell. A gate the aggregate's `filter` already tests is left
/// to the filter; `None` when no other gate masks a cell.
fn pointwise_keep(
    idx_names: &[String],
    ranges: &[(i64, i64)],
    gates: &[BuiltGate],
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
    for g in gates.iter().filter(|g| !g.in_filter) {
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

/// The odometer over `srcs` (last dimension fastest), the later dimension of
/// a both-contracted gate walking only its partners of the earlier one's
/// current value (`drive_partner_restricted`). `false` once `push` asks to
/// stop.
fn walk(
    srcs: &[Src],
    pair: Option<(&BuiltGate, usize, usize, bool)>,
    d: usize,
    cur: &mut Vec<i64>,
    push: &mut impl FnMut(&[i64]) -> bool,
) -> bool {
    if d == srcs.len() {
        return push(cur);
    }
    if let Some((g, p, q, bound_is_src)) = pair
        && d == q
    {
        let side = if bound_is_src { Side::Src } else { Side::Tgt };
        let bound = cur[p];
        match &srcs[q] {
            Src::Range(lo, hi) => {
                for &v in g.index.partners_in(side, bound, *lo, *hi) {
                    cur[d] = v;
                    if !walk(srcs, pair, d + 1, cur, push) {
                        return false;
                    }
                }
            }
            Src::List(vals) => {
                let parts = g.index.partners(side, bound);
                let (mut i, mut j) = (0usize, 0usize);
                while i < vals.len() && j < parts.len() {
                    match vals[i].cmp(&parts[j]) {
                        std::cmp::Ordering::Less => i += 1,
                        std::cmp::Ordering::Greater => j += 1,
                        std::cmp::Ordering::Equal => {
                            cur[d] = vals[i];
                            if !walk(srcs, pair, d + 1, cur, push) {
                                return false;
                            }
                            i += 1;
                            j += 1;
                        }
                    }
                }
            }
        }
        return true;
    }
    match &srcs[d] {
        Src::Range(lo, hi) => {
            for v in *lo..=*hi {
                cur[d] = v;
                if !walk(srcs, pair, d + 1, cur, push) {
                    return false;
                }
            }
        }
        Src::List(vals) => {
            for &v in *vals {
                cur[d] = v;
                if !walk(srcs, pair, d + 1, cur, push) {
                    return false;
                }
            }
        }
    }
    true
}

/// `slot ∩ parts`, both ascending; `false` when the result is empty.
fn intersect(slot: &mut Option<Vec<i64>>, parts: &[i64]) -> bool {
    let next = match slot.take() {
        None => parts.to_vec(),
        Some(cur) => {
            let mut out = Vec::with_capacity(cur.len().min(parts.len()));
            let (mut i, mut j) = (0usize, 0usize);
            while i < cur.len() && j < parts.len() {
                match cur[i].cmp(&parts[j]) {
                    std::cmp::Ordering::Less => i += 1,
                    std::cmp::Ordering::Greater => j += 1,
                    std::cmp::Ordering::Equal => {
                        out.push(cur[i]);
                        i += 1;
                        j += 1;
                    }
                }
            }
            out
        }
    };
    let ok = !next.is_empty();
    *slot = Some(next);
    ok
}

/// `ragged_upper_bound` over build-time values: the offsets factor at the
/// parents' values (from the output `cell` or the contracted values `cur`),
/// rounded; `0` for a parent below 1 or out of range, or for a factor whose
/// rank is not the parent count.
fn ragged_bound(
    shape: &[usize],
    vals: &[f64],
    parents: &[Parent],
    cell: &[i64],
    cur: &[i64],
) -> i64 {
    if shape.is_empty() {
        return vals[0].round() as i64;
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
    vals[flat].round() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

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
            let keep = pointwise_keep(&names, &ranges, gates)
                .expect("keeps")
                .unwrap_or_else(|| vec![1.0; walked.len()]);
            assert_eq!(keep, walked);
        }
    }
}
