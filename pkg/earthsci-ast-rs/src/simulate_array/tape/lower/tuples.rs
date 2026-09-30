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
    /// shape (empty for a scalar), and the output-axis position of each parent.
    Ragged {
        shape: DimU,
        vals: Rc<Vec<f64>>,
        parents: Vec<usize>,
    },
}

/// A join gate resolved from build-time data.
struct BuiltGate {
    sym_src: String,
    sym_tgt: String,
    index: OverlapIndex,
    n_src: usize,
    n_tgt: usize,
    clause_ix: usize,
}

/// The admitted tuple list: per output cell a contiguous run.
struct TupleList {
    rows: Vec<u32>,
    /// One column per loop symbol (output names, then contracted names).
    cols: Vec<Vec<f64>>,
}

/// One contracted dimension's enumeration source within one output cell.
enum Src<'a> {
    Range(i64, i64),
    List(&'a [i64]),
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
        // (CONFORMANCE_SPEC §5.6.1).
        let combine_op = if ranges.is_empty() {
            scalar_combine_op(reduce)
        } else {
            let Some(op) = reduce_combine_op(reduce) else {
                bail_tape!(
                    "contracted: an array-valued bool_and_or reduction (the numeric \
                     evaluators reject it, CONFORMANCE_SPEC §5.6.1)"
                );
            };
            op
        };
        // With nothing contracted the interpreter returns the body itself,
        // not `identity ⊕ body` (they differ on a `-0.0` term).
        if contract_names.is_empty() {
            bail_tape!("aggregate: a join gate on an aggregate with no contracted index");
        }
        let lo: DimI = ranges.iter().map(|(l, _)| *l).collect();
        let shape: DimU = ranges
            .iter()
            .map(|(l, h)| (h - l + 1).max(0) as usize)
            .collect();
        if shape.contains(&0) {
            bail_tape!("faq: empty output box");
        }
        let identity = reduce.identity();
        let bounds = self.tuple_dim_bounds(idx_names, contract_dims)?;
        let gates = match join {
            Some(j) => self.build_join_gates(j)?,
            None => Vec::new(),
        };
        let list = enumerate_tuples(idx_names, ranges, contract_names, &bounds, &gates)?;
        let m = *list.rows.last().expect("rows has n_out + 1 entries") as usize;
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

    /// Resolve each contracted dimension's bound: a static interval as it
    /// stands, a ragged one against its offsets factor's build-time values.
    fn tuple_dim_bounds(
        &mut self,
        idx_names: &[String],
        contract_dims: &[ContractDim],
    ) -> LResult<Vec<DimBound>> {
        let mut out = Vec::with_capacity(contract_dims.len());
        for d in contract_dims {
            out.push(match d {
                ContractDim::Static(l, h) => DimBound::Static(*l, *h),
                ContractDim::Ragged { offsets, of } => {
                    // The interpreter reads each parent from the output
                    // cell's binds; a parent bound by the contraction itself
                    // would be read before it is bound.
                    let parents = of
                        .iter()
                        .map(|p| {
                            idx_names.iter().position(|n| n == p).ok_or_else(|| Bail {
                                reason: format!(
                                    "contracted: ragged bound's parent `{p}` is not an output \
                                     index"
                                ),
                            })
                        })
                        .collect::<LResult<Vec<usize>>>()?;
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
    /// the build knows — as `(shape, row-major values)`; a scalar has an
    /// empty shape and one value.
    pub(super) fn known_named(&self, name: &str) -> Option<(DimU, Rc<Vec<f64>>)> {
        match self.obs_defined.get(name)? {
            ObsVal::Taped(LV::Lit(x)) => Some((DimU::new(), Rc::new(vec![*x]))),
            ObsVal::Taped(LV::Arr(s)) => {
                let shape = self.slots[*s as usize].shape.clone();
                Some((shape, self.known_values(*s)?))
            }
            _ => None,
        }
    }

    /// A slot's build-time values, if the build knows them.
    pub(super) fn known_values(&self, s: SlotId) -> Option<Rc<Vec<f64>>> {
        match self.known.get(&s)? {
            Known::Data(d) => Some(Rc::new(self.const_data[*d as usize].values.clone())),
            Known::Vals(v) => Some(Rc::clone(v)),
        }
    }

    /// Resolve every drivable clause of `join` from build-time data, most
    /// selective first (the interpreter's §5.24 order). A drivable clause
    /// whose data the build does not know is a refusal (module docs).
    fn build_join_gates(&mut self, join: &[JoinClause]) -> LResult<Vec<BuiltGate>> {
        let mut gates = Vec::new();
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
                gates.push(BuiltGate {
                    sym_src: sym_src.clone(),
                    sym_tgt: sym_tgt.clone(),
                    index: OverlapIndex::from_zero_based(&pairs),
                    n_src: src.len(),
                    n_tgt: tgt.len(),
                    clause_ix,
                });
                continue;
            }
            let Some(g) = &clause.on_gate else {
                continue;
            };
            if g.cols_l.len() != g.cols_r.len() || g.cols_l.is_empty() {
                continue;
            }
            let side = |cols: &[crate::join::KeyColumn]| -> LResult<_> {
                let mut parts = Vec::with_capacity(cols.len());
                for c in cols {
                    parts.push(match c {
                        crate::join::KeyColumn::Const { positions, values } => {
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
                                        "aggregate: join key column `{name}` is not build-time data"
                                    ),
                                })?;
                            data_key_column(&a).ok_or_else(|| Bail {
                                reason: format!(
                                    "aggregate: join key column `{name}` is not a 1-D column of \
                                     exact integers"
                                ),
                            })?
                        }
                    });
                }
                composite_side_keys(parts).ok_or_else(|| Bail {
                    reason: "aggregate: a composite join key's columns disagree in length"
                        .to_string(),
                })
            };
            let (pos_l, keys_l) = side(&g.cols_l)?;
            let (pos_r, keys_r) = side(&g.cols_r)?;
            let (index, n_src, n_tgt) = index_from_sides((pos_l, keys_l, pos_r, keys_r));
            gates.push(BuiltGate {
                sym_src: g.sym_l.clone(),
                sym_tgt: g.sym_r.clone(),
                index,
                n_src,
                n_tgt,
                clause_ix,
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
            let v = self.lower_expr(e, bx)?;
            sub_vals.push(match v {
                LV::Lit(x) => Rc::new(vec![x; m]),
                LV::Arr(s) => match self.known_values(s) {
                    Some(vals) if vals.len() == m => vals,
                    _ => bail_tape!("index: a subscript that is not build-time data over the list"),
                },
                _ => bail_tape!("index: a subscript that is not build-time data over the list"),
            });
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

/// Enumerate the tuple list: output cells in row-major order, each cell's
/// contraction tuples in the odometer order under the cell's bounds and the
/// gates, exactly as `reduce_contraction_gated` walks them.
fn enumerate_tuples(
    idx_names: &[String],
    ranges: &[(i64, i64)],
    contract_names: &[String],
    bounds: &[DimBound],
    gates: &[BuiltGate],
) -> LResult<TupleList> {
    let nr = idx_names.len();
    let nc = contract_names.len();
    let mut cols: Vec<Vec<f64>> = vec![Vec::new(); nr + nc];
    let mut rows: Vec<u32> = vec![0];
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
    for _ in 0..n_cells {
        // This cell's contraction bounds.
        let cell_ranges: Vec<(i64, i64)> = bounds
            .iter()
            .map(|b| match b {
                DimBound::Static(l, h) => (*l, *h),
                DimBound::Ragged {
                    shape,
                    vals,
                    parents,
                } => (1, ragged_bound(shape, vals, parents, &cell)),
            })
            .collect();
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
            let mut push = |t: &[i64]| {
                for (c, &v) in cell.iter().enumerate() {
                    cols[c].push(v as f64);
                }
                for (d, &v) in t.iter().enumerate() {
                    cols[nr + d].push(v as f64);
                }
            };
            walk(&srcs, pair, 0, &mut cur, &mut push);
        } else if !reject {
            // No contracted index: the pointwise term, once.
            for (c, &v) in cell.iter().enumerate() {
                cols[c].push(v as f64);
            }
        }
        let m = cols.first().map_or(0, Vec::len);
        if m > MAX_PROMOTED_ELEMS {
            bail_tape!("contracted: tuple list too long ({m} tuples)");
        }
        rows.push(m as u32);
        // Next output cell, row-major.
        let mut d = nr;
        while d > 0 {
            d -= 1;
            cell[d] += 1;
            if cell[d] <= ranges[d].1 {
                break;
            }
            cell[d] = ranges[d].0;
        }
    }
    Ok(TupleList { rows, cols })
}

/// The odometer over `srcs` (last dimension fastest), the later dimension of
/// a both-contracted gate walking only its partners of the earlier one's
/// current value (`drive_partner_restricted`).
fn walk(
    srcs: &[Src],
    pair: Option<(&BuiltGate, usize, usize, bool)>,
    d: usize,
    cur: &mut Vec<i64>,
    push: &mut impl FnMut(&[i64]),
) {
    if d == srcs.len() {
        push(cur);
        return;
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
                    walk(srcs, pair, d + 1, cur, push);
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
                            walk(srcs, pair, d + 1, cur, push);
                            i += 1;
                            j += 1;
                        }
                    }
                }
            }
        }
        return;
    }
    match &srcs[d] {
        Src::Range(lo, hi) => {
            for v in *lo..=*hi {
                cur[d] = v;
                walk(srcs, pair, d + 1, cur, push);
            }
        }
        Src::List(vals) => {
            for &v in *vals {
                cur[d] = v;
                walk(srcs, pair, d + 1, cur, push);
            }
        }
    }
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
/// cell's parents, rounded; `0` for a parent below 1 or out of range, or for
/// a factor whose rank is not the parent count.
fn ragged_bound(shape: &[usize], vals: &[f64], parents: &[usize], cell: &[i64]) -> i64 {
    if shape.is_empty() {
        return vals[0].round() as i64;
    }
    if parents.len() != shape.len() {
        return 0;
    }
    let mut flat = 0usize;
    for (d, &p) in parents.iter().enumerate() {
        let v = cell[p];
        if v < 1 || v as usize > shape[d] {
            return 0;
        }
        flat = flat * shape[d] + (v - 1) as usize;
    }
    vals[flat].round() as i64
}
