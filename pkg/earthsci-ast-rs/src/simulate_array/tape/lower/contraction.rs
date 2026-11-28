//! Contractions: a nested aggregate, the `faq` node over an output box,
//! and their promoted-box, unrolled and prefix-scan forms.

use super::*;

impl<'m> TapeBuilder<'m> {
    // -- nested aggregate -----------------------------------------------------

    /// A `faq` nested in a box, hoisted out of the per-cell loop and evaluated
    /// once over its own box when it is binding-independent — the shared
    /// [`nested_aggregate_capture`] predicate. There are no loop binds at
    /// build time, which is why only the box's own symbols and contraction
    /// names are offered to it.
    pub(super) fn lower_nested_aggregate(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
    ) -> LResult<LV> {
        let Some(spec) = faq_spec(node) else {
            bail_tape!("aggregate: node carries no `expr` body");
        };
        // A rank-0 aggregate evaluated at one recurrence cell — the cell body
        // of a recurrence with a contraction is exactly this.
        if self.rule.sweep.is_some()
            && spec.ranges.is_empty()
            && bx.shape.is_empty()
            && bx.tuple == 0
        {
            if spec.join.is_some() || node.key.is_some() || node.distinct == Some(true) {
                bail_tape!("aggregate: a gated or keyed contraction inside a recurrence body");
            }
            return self.lower_cell_contraction(&spec, bx);
        }
        // A rank-0 aggregate nested in a box: the reference is the per-cell
        // oracle, which reduces it afresh at every cell of the box.
        if spec.ranges.is_empty() {
            return self.lower_nested_scalar_reduction(node, &spec, bx);
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
            return self.lower_tuple_contraction(&Contraction::of(&spec), &spec.ranges, spec.join);
        }
        let level = self.enter_fault_level(Some(bx));
        let v = self.lower_faq(&Contraction::of(&spec), &spec.ranges);
        self.leave_fault_level(level);
        v
    }

    /// A rank-0 `faq` nested in the box `bx`, which the per-cell oracle
    /// reduces at every cell of the box with [`reduce_contraction`]: `acc =
    /// identity`, then `acc = acc ⊕ term` per contraction tuple, the last
    /// contracted name fastest.
    ///
    /// A body that reads none of the box's symbols reduces to the same value
    /// at every cell, by the same fold: it is lowered once, as the wholesale
    /// scalar reduction ([`Self::lower_scalar_reduction`]), and its faults
    /// sort at the box's first cell, where the oracle meets them first.
    ///
    /// A body that does read them is a reduction PER CELL: the body over the
    /// box extended by the contracted axes (after the box's, in
    /// `contract_names` order) and one [`Instr::Reduce`] folding those axes
    /// away: its row-major walk visits each cell's terms in the oracle's
    /// order. An excluded tuple is skipped
    /// as [`Self::lower_scalar_reduction`] skips it.
    pub(super) fn lower_nested_scalar_reduction(
        &mut self,
        node: &Arc<ExpressionNode>,
        spec: &ArrayOpSpec,
        bx: &LBox,
    ) -> LResult<LV> {
        if bx.tuple != 0 {
            let frame_names: Vec<String> = self
                .rule
                .tuple_frames
                .iter()
                .rev()
                .find(|f| f.id() == bx.tuple)
                .map(|f| f.names().to_vec())
                .unwrap_or_default();
            if nested_aggregate_capture(spec, frame_names.iter()).is_none() {
                let level = self.enter_fault_level(Some(bx));
                let v = self.lower_wholesale_aggregate_in_level(node);
                self.leave_fault_level(level);
                return v;
            }
            if spec.has_drivable_overlap() || node.key.is_some() || node.distinct == Some(true) {
                bail_tape!("aggregate: a gated or keyed rank-0 output that reads its tuple list");
            }
            return self.lower_nested_scalar_in_tuples(node, spec, bx);
        }
        if nested_aggregate_capture(spec, bx.syms.iter().chain(bx.cnames.iter())).is_none() {
            let level = self.enter_fault_level(Some(bx));
            let v = self.lower_wholesale_aggregate_in_level(node);
            self.leave_fault_level(level);
            return v;
        }
        if spec.has_drivable_overlap() || node.key.is_some() || node.distinct == Some(true) {
            bail_tape!("aggregate: a gated or keyed rank-0 output that reads its enclosing box");
        }
        if !bx.cnames.is_empty() {
            bail_tape!(
                "aggregate: a rank-0 output that reads its enclosing box, inside an unrolled \
                 contraction"
            );
        }
        // A body that reads only some of the box's axes reduces to the same
        // value along the others: reduce over the axes it reads, once per
        // position of those, and broadcast along the rest.
        let read: SmallVec<[usize; 4]> = (0..bx.syms.len())
            .filter(|&a| nested_aggregate_capture(spec, std::iter::once(&bx.syms[a])).is_some())
            .collect();
        if read.len() < bx.syms.len() {
            return self.lower_nested_scalar_reduction_on(node, spec, bx, &read);
        }
        if let Some(v) = self.try_lower_indicator_count(spec, bx, true, None) {
            return Ok(v);
        }
        let nc = spec.contract_names.len();
        if nc == 0 {
            bail_tape!("aggregate: a rank-0 output with no contracted index reads its box");
        }
        let combine_op = scalar_combine_op(spec.reduce);
        let identity = spec.reduce.identity();
        // The box's axes, then the contracted ones: a read of the body that
        // follows the box (`u[i, j, l]`) is then the source's own layout, not
        // a transposing gather.
        let mut wlo: DimI = DimI::new();
        let mut wshape: DimU = DimU::new();
        for d in &spec.contract_dims {
            let (l, n) = match d {
                ContractDim::Static(l, h) => (*l, (h - l + 1).max(0) as usize),
                other => bail_tape!(
                    "aggregate: a rank-0 output that reads its enclosing box, over a \
                     non-static contraction dim ({other:?})"
                ),
            };
            wlo.push(l);
            wshape.push(n);
        }
        // An empty window enumerates no tuple: the fold is the identity.
        if wshape.contains(&0) {
            return Ok(self.emit_fill(&LV::Lit(identity), &bx.shape, &bx.lo, Cadence::Const));
        }
        let plan = PromotedPlan::new(
            PromotedKind::PerCell,
            bx.syms,
            &bx.lo,
            &bx.shape,
            (0..bx.shape.len()).map(|k| bx.visit_axis(k) as u8),
            &spec.contract_names,
            &wlo,
            &wshape,
            false,
        );
        plan.check()?;
        let skip = match spec.reduce {
            ReduceKind::Sum => -0.0,
            other => other.identity(),
        };
        // A fault here would sort by the promoted box's cells, which do not
        // place it among the enclosing box's own faults: refused instead.
        let notes = self.fault.notes;
        self.lower_promoted(plan, combine_op, identity, false, |s, ebx| {
            let term = s.lower_filtered(spec.body, spec.filter, ebx, LV::Lit(skip))?;
            if s.fault.notes != notes {
                bail_tape!(
                    "fault: a fail-closed fault inside a rank-0 output that reads its enclosing box"
                );
            }
            Ok(term)
        })
    }

    /// The state array `lv` copies element for element, when the instruction
    /// that defines it (in the open branch or the current rule's chunks) is a
    /// gather of a whole state over its own box: no fixed or broadcast axis,
    /// no permutation, one full segment per axis.
    pub(super) fn identity_state_gather(&self, lv: &LV) -> Option<u32> {
        let LV::Arr(slot) = lv else {
            return None;
        };
        let defs = self.rule.branch_bufs.iter().flatten().chain(
            self.streams
                .iter()
                .filter_map(|st| st.last().filter(|c| c.rule == self.cur_rule))
                .flat_map(|c| c.instrs.iter()),
        );
        for (instr, _) in defs {
            let Instr::Gather {
                src: SrcRef::State(ix),
                plan,
                out,
            } = instr
            else {
                continue;
            };
            if out != slot {
                continue;
            }
            let p = &self.tables.plans[*plan as usize];
            let whole = p.fixed_desc.is_empty()
                && p.mapped.iter().all(|&m| m)
                && p.perm.iter().enumerate().all(|(i, &d)| i == d)
                && p.shape == p.src_shape
                && p.origin == p.src_origin
                && p.segs
                    .iter()
                    .zip(&p.shape)
                    .all(|(s, &n)| s[..] == [(0usize, n, 0usize)]);
            return whole.then_some(*ix);
        }
        None
    }

    /// Whether `lv` is a whole state array read as a value, which the
    /// per-cell oracle scalarizes where a body reduces to one: every form
    /// that lowers a body over a box refuses it.
    pub(super) fn is_bare_view(&self, lv: &LV) -> bool {
        matches!(lv, LV::State(_)) && self.lv_box(lv).is_some()
    }

    /// `term` as an array over `shape`/`lo`: a scalar broadcast over it, an
    /// array over it kept; a bare whole-array view, or an array over any
    /// other box, refused, naming `what` and the box as `target`.
    pub(super) fn fit_term(
        &mut self,
        term: LV,
        shape: &DimU,
        lo: &DimI,
        what: &str,
        target: &str,
    ) -> LResult<LV> {
        if self.is_bare_view(&term) {
            bail_tape!("{what} reduced to a bare whole-array view");
        }
        match self.lv_box(&term) {
            None => Ok(self.emit_fill(&term, shape, lo, Cadence::Const)),
            Some((s, o)) if s == *shape && o == *lo => Ok(term),
            Some(_) => bail_tape!("{what} box does not match {target}"),
        }
    }

    /// Lower a contraction over its promoted box (`plan`, already
    /// [checked](PromotedPlan::check)): the term over the box, `None` when
    /// the filter keeps no tuple, fitted to the box, then one
    /// [`Instr::Reduce`] folding the contracted axes away with `op` from
    /// `identity`, its one axis from the top when `reverse`. Its row-major
    /// walk folds each result's terms in the oracle's order.
    pub(super) fn lower_promoted(
        &mut self,
        plan: PromotedPlan,
        op: BinCode,
        identity: f64,
        reverse: bool,
        term: impl FnOnce(&mut Self, &LBox) -> LResult<Option<LV>>,
    ) -> LResult<LV> {
        let what = plan.what;
        let ebx = LBox {
            visit: plan.visit.clone(),
            ..LBox::new(&plan.syms, plan.lo.clone(), plan.shape.clone())
        };
        self.push_scope();
        let t = term(self, &ebx);
        self.pop_scope();
        let t = match (t?, plan.kind) {
            (Some(t), _) => t,
            // No tuple is kept: every result is the identity.
            (None, PromotedKind::PerCell) => {
                let (s, o) = plan.out.as_ref().expect("a per-cell result has a box");
                return Ok(self.emit_fill(&LV::Lit(identity), s, o, Cadence::Const));
            }
            (None, PromotedKind::Output) => LV::Lit(identity),
            (None, PromotedKind::Scalar) => return Ok(LV::Lit(identity)),
        };
        let src = self.fit_term(
            t,
            &plan.shape,
            &plan.lo,
            &format!("{what} term"),
            "the promoted box",
        )?;
        let sec = self.placement(self.lv_cadence(&src));
        let src_ref = match plan.kind {
            // A term that is the state array read whole, in its own layout
            // (the column sum `u[i, j, l]`), is folded from the state in place.
            PromotedKind::PerCell => match self.identity_state_gather(&src) {
                Some(ix) => SrcRef::State(ix),
                None => self.src_of(&src),
            },
            PromotedKind::Output => self.src_of(&src),
            PromotedKind::Scalar => match src {
                LV::Arr(s) => SrcRef::Slot(s),
                _ => unreachable!("the reduction source is an array slot"),
            },
        };
        let (out, result) = match &plan.out {
            Some((s, o)) => {
                let out = self.new_slot(s, o, false, sec);
                (out, LV::Arr(out))
            }
            None => {
                let out = self.new_slot(&[], &[], true, sec);
                (out, LV::Scalar(out))
            }
        };
        self.emit(
            Instr::Reduce {
                op,
                init: identity,
                src: src_ref,
                axes: plan.axes,
                reverse,
                src_shape: plan.shape,
                out,
            },
            sec,
        );
        Ok(result)
    }

    /// [`Self::lower_nested_scalar_reduction`] over the sub-box of `bx`'s
    /// axes `read` (ascending), the only ones the body reads, broadcast back
    /// over `bx` by one [`Instr::Gather`]. Every cell's value is the fold the
    /// oracle computes there; cells that differ only along an axis the body
    /// does not read share it.
    pub(super) fn lower_nested_scalar_reduction_on(
        &mut self,
        node: &Arc<ExpressionNode>,
        spec: &ArrayOpSpec,
        bx: &LBox,
        read: &[usize],
    ) -> LResult<LV> {
        let sub_syms: Vec<String> = read.iter().map(|&a| bx.syms[a].clone()).collect();
        let sub = LBox {
            syms: &sub_syms,
            lo: read.iter().map(|&a| bx.lo[a]).collect(),
            shape: read.iter().map(|&a| bx.shape[a]).collect(),
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            visit: if bx.visit.is_empty() {
                SmallVec::new()
            } else {
                (0..bx.shape.len())
                    .filter_map(|k| read.iter().position(|&a| a == bx.visit_axis(k)))
                    .map(|p| p as u8)
                    .collect()
            },
        };
        self.push_scope();
        let v = self.lower_nested_scalar_reduction(node, spec, &sub);
        self.pop_scope();
        let v = v?;
        let (s, o) = self
            .lv_box(&v)
            .expect("a reduction that reads its box is an array over it");
        if s != sub.shape || o != sub.lo {
            bail_tape!("aggregate: a rank-0 output's box does not match its read axes");
        }
        let mapped: SmallVec<[bool; 4]> = (0..bx.shape.len()).map(|a| read.contains(&a)).collect();
        let segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = bx
            .shape
            .iter()
            .map(|&n| {
                let mut one = SmallVec::new();
                one.push((0usize, n, 0usize));
                one
            })
            .collect();
        let mapped_src: SmallVec<[usize; 4]> = (0..read.len()).collect();
        Ok(self.emit_gather(
            &v,
            SmallVec::new(),
            &mapped_src,
            mapped,
            segs,
            &bx.shape,
            &bx.lo,
        ))
    }

    // -- faq (the try_eval_faq_vectorized mirror) ---------------------

    pub(super) fn lower_faq(&mut self, c: &Contraction, ranges: &[(i64, i64)]) -> LResult<LV> {
        let Contraction {
            idx_names,
            body,
            contract_names,
            contract_dims,
            reduce,
            filter,
        } = *c;
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
        // A prefix scan (a `makearray` region value, a filtered rule body):
        // the oracle sweeps it with `run_prefix_scan`, so it gets the
        // running-fold lowering, never the filtered triangular box below. A
        // forward scan's bits agree either way, but the box is O(N^2); a
        // reverse scan folds each suffix from its high end, which only the
        // sweep reproduces.
        let static_ranges = static_contract_ranges(contract_dims);
        if let Some(scan) = detect_prefix_scan(
            idx_names,
            ranges,
            contract_names,
            static_ranges.as_deref(),
            body,
            filter,
        ) {
            return self.lower_prefix_scan(c, ranges, scan);
        }
        // A filter that pins an output index by equality: one pass over the
        // contracted box, each admitted term scattered into its cell
        // (esm-spec §4.3.1, [`scatter`]). A body the tuple-list form cannot
        // lower keeps the dense lowering below.
        let mut scatter_decline = None;
        if !contract_names.is_empty() && filter.is_some() {
            match self.attempt(|b| b.lower_equality_scatter(c, &lo, &shape, &[])) {
                Ok(Some(v)) => return Ok(v),
                Ok(None) => {}
                Err(e) => scatter_decline = Some(e),
            }
        }
        let dense = |this: &mut Self| -> LResult<LV> {
            this.push_scope();
            let v = if contract_names.is_empty() {
                let bx = LBox::new(idx_names, lo.clone(), shape.clone());
                let identity = LV::Lit(reduce.identity());
                let r = this
                    .lower_filtered(body, filter, &bx, identity.clone())
                    .map(|v| {
                        v.unwrap_or_else(|| this.emit_fill(&identity, &shape, &lo, Cadence::Const))
                    });
                this.pop_scope();
                r?
            } else {
                let r = this.lower_contracted(c, &lo, &shape);
                this.pop_scope();
                r?
            };
            // The oracle scalarizes a bare whole-array body, so the tape refuses
            // it.
            this.fit_term(v, &shape, &lo, "faq: body", "the output box")
        };
        let r = dense(self);
        after_decline(scatter_decline, r)
    }

    /// A static contraction: the body over the output box EXTENDED by the
    /// contracted axes, folded away by one [`Instr::Reduce`] — one
    /// instruction whatever the window's length
    /// ([`Self::lower_contracted_box`]). A body that form cannot lower keeps
    /// the unrolled form ([`Self::lower_contracted_unrolled`]).
    pub(super) fn lower_contracted(
        &mut self,
        c: &Contraction,
        lo: &DimI,
        shape: &DimU,
    ) -> LResult<LV> {
        let Contraction {
            idx_names,
            contract_names,
            contract_dims,
            reduce,
            filter,
            ..
        } = *c;
        let combine_op = self.array_combine_op(reduce, "contracted")?;
        let nc = contract_names.len();
        if nc == 0 {
            bail_tape!("contracted: no contracted index");
        }
        if contract_dims.iter().any(|d| !self.dim_is_fixed(d)) {
            // The tuple-list form folds each row ascending; a reverse
            // window folds it from the top (esm-spec §4.3.1).
            if folds_from_the_top(idx_names, contract_names, filter) {
                bail_tape!("contracted: a reverse-window filter over a ragged range");
            }
            // A ragged bound varies per output cell: the tuple-list form.
            let ranges: Vec<(i64, i64)> = lo
                .iter()
                .zip(shape)
                .map(|(&l, &n)| (l, l + n as i64 - 1))
                .collect();
            return self.lower_tuple_contraction(c, &ranges, None);
        }
        let mut clo: SmallVec<[i64; 4]> = SmallVec::from_elem(0, nc);
        let mut chi: SmallVec<[i64; 4]> = SmallVec::from_elem(0, nc);
        for (i, d) in contract_dims.iter().enumerate() {
            match d {
                ContractDim::Static(l, h) => {
                    clo[i] = *l;
                    chi[i] = *h;
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
        match self.attempt(|b| b.lower_contracted_box(c, lo, shape, &window, combine_op)) {
            Ok(v) => Ok(v),
            Err(first) => {
                let r = self.lower_contracted_unrolled(c, lo, shape, &window, combine_op);
                after_decline(Some(first), r)
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
    pub(super) fn lower_contracted_box(
        &mut self,
        c: &Contraction,
        lo: &DimI,
        shape: &DimU,
        window: &ContractWindow,
        combine_op: BinCode,
    ) -> LResult<LV> {
        let Contraction {
            idx_names,
            body,
            filter,
            ..
        } = *c;
        let identity = c.reduce.identity();
        let nc = window.names.len();
        // Where the contracted axes go. Leading, a fold over them is one
        // contiguous row per tuple. A program whose state is stored
        // axis-reversed (`layout`) stores a box reversed too, so there they
        // go LAST: stored, they lead again, and a term that reads the state
        // in its own axis order (`u[c, l]` summed over `l`) is the state's
        // own layout instead of a transposed copy. Either way each output
        // cell folds its tuples in the same order.
        let trailing = self
            .state_vars
            .iter()
            .any(|sv| !super::super::layout::order_free(&sv.shape));
        let win_shape: DimU = (0..nc)
            .map(|i| (window.hi[i] - window.lo[i] + 1) as usize)
            .collect();
        let plan = PromotedPlan::new(
            PromotedKind::Output,
            idx_names,
            lo,
            shape,
            0..shape.len() as u8,
            window.names,
            window.lo,
            &win_shape,
            trailing,
        );
        plan.check()?;
        // A reverse window the scan lowering did not claim (its body reads
        // the output index, or its range is not the output axis's) folds
        // each cell's suffix from its high end (esm-spec §4.3.1).
        let reverse = folds_from_the_top(idx_names, window.names, filter);
        self.lower_promoted(plan, combine_op, identity, reverse, |s, bx| {
            s.lower_filtered(body, filter, bx, LV::Lit(identity))
        })
    }

    /// The unrolled form of a static contraction: one term per contraction
    /// tuple, each over the output box with the tuple bound as constants,
    /// left-folded into an identity-filled accumulator. Tuples are visited
    /// in the per-cell oracle's `CartesianTuples` order (the last contracted
    /// name fastest), so the fold is the interpreter's. Its length grows with
    /// the window; it serves only bodies the looped form cannot lower (a
    /// read whose index mixes an output and a contracted symbol, such as a
    /// stencil window `u[i + k]`).
    pub(super) fn lower_contracted_unrolled(
        &mut self,
        c: &Contraction,
        lo: &DimI,
        shape: &DimU,
        window: &ContractWindow,
        combine_op: BinCode,
    ) -> LResult<LV> {
        let Contraction {
            idx_names,
            body,
            filter,
            ..
        } = *c;
        let identity = c.reduce.identity();
        let nc = window.names.len();
        let contract_names = window.names;
        let (clo, chi) = (window.lo, window.hi);
        // Accumulator: identity-filled buffer over the output box.
        let mut acc = self.emit_fill(&LV::Lit(identity), shape, lo, Cadence::Const);
        // A reverse window (one contracted name) is visited from its high
        // end (esm-spec §4.3.1).
        let reverse = folds_from_the_top(idx_names, contract_names, filter);

        let mut cvals: SmallVec<[i64; 4]> = SmallVec::from_slice(if reverse { chi } else { clo });
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

            if reverse {
                cvals[0] -= 1;
                if cvals[0] < clo[0] {
                    break;
                }
                continue;
            }
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
}
