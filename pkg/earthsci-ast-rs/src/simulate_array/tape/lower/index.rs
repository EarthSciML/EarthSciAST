//! Index reads: the `index` node over a box, lowered to gathers of every
//! kind (shifted, data-subscripted, table, clamped bracket) and the reads
//! a recurrence body makes of its own cells.

use super::*;
use crate::simulate_array::index_cell::ElementwiseCell;

impl<'m> TapeBuilder<'m> {
    // -- index (gather) -------------------------------------------------------

    pub(super) fn fixed_elementwise_index(
        &self,
        node: &ExpressionNode,
        bx: Option<&LBox>,
    ) -> Option<Expr> {
        let (base, indices) = node.args.split_first()?;
        let raw: Option<DimI> = indices
            .iter()
            .map(|i| match i {
                Expr::Integer(i) => Some(crate::precision::round(*i as f64).round() as i64),
                Expr::Number(i) => Some(crate::precision::round(*i).round() as i64),
                _ => None,
            })
            .collect();
        let raw = raw?;
        let plan = self.elementwise_index_plan(base, indices.len(), bx)?;
        Some(plan.select(&raw))
    }

    pub(super) fn elementwise_index_plan<'e>(
        &self,
        base: &'e Expr,
        rank: usize,
        bx: Option<&LBox>,
    ) -> Option<ElementwiseCell<'e>> {
        ElementwiseCell::plan(base, rank, &|name| {
            if name == "t"
                || self.param_ix.contains_key(name)
                || bx.is_some_and(|bx| bx.syms.iter().chain(bx.cnames).any(|n| n == name))
            {
                return Some(DimU::new());
            }
            if let Some(&i) = self.state_ix.get(name) {
                return Some(self.state_vars[i].shape.clone());
            }
            if let Some(ObsVal::Taped(v)) = self.obs_defined.get(name) {
                return Some(self.lv_box(v).map_or_else(DimU::new, |(shape, _)| shape));
            }
            self.forcing_shapes.get(name).cloned()
        })
    }

    /// Lower an `index` gather, classifying each axis with the shared axis
    /// analyses ([`classify_axis_role`]). Everything is static except the
    /// source data.
    pub(super) fn lower_index(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        if bx.tuple != 0 {
            return self.lower_tuple_index(node, bx);
        }
        if node.args.is_empty() {
            bail_tape!("index: no arguments");
        }
        if self.rule.sweep.is_some() && bx.shape.is_empty() {
            return self.lower_cell_index(node, bx);
        }
        if let (Some(sw), Expr::Variable(v)) = (&self.rule.sweep, &node.args[0])
            && *v == sw.var
        {
            bail_tape!(
                "index: causal self-read of `{v}` inside an array-valued part of its \
                 recurrence body (a self-read is evaluated one cell at a time)"
            );
        }
        if let Some(v) = self.lower_index_on_sub_box(node, bx)? {
            return Ok(v);
        }
        if let Some(v) = self.lower_index_of_makearray(node, bx)? {
            return Ok(v);
        }
        if let Some(cell) = self.fixed_elementwise_index(node, Some(bx)) {
            // The projection owns fresh AST nodes, so their addresses can
            // only act as value-numbering keys while this scope is open.
            self.push_scope();
            let result = self.lower_expr(&cell, bx);
            self.pop_scope();
            return result;
        }
        // A const-array gather may not use the ghost-0 fill (§5.5.5).
        let const_base = self.const_arrays.is_const_base(&node.args[0]);
        // An inline array literal as the base is read whole, as the oracle's
        // gather reads it (the payload's own array): one CONST-section literal. It
        // is lowered here and nowhere else in a box, where an array value in
        // an elementwise position would mean something else per cell.
        let arg0 = match &node.args[0] {
            // A makearray [`Self::lower_index_of_makearray`] left here is the
            // same array at every cell.
            Expr::Operator(ma)
                if ma.op == "makearray"
                    && self.per_cell_makearray_box(bx)
                    && !makearray_reads_box(ma, bx) =>
            {
                self.lower_makearray_once(ma, bx)?
            }
            Expr::Operator(lit) if lit.op == "const" => match eval_const(lit) {
                Value::Array(a) => self.const_literal_array(lit, &a, Some(bx))?,
                Value::Scalar(s) => LV::Lit(s),
            },
            // A shape-op or `broadcast` base (esm-spec §4.3.4, §4.3.5) is a
            // whole array whatever the box, as the oracle's gather evaluates
            // it: relabelled (or broadcast) once by the wholesale lowering,
            // then read at the subscripts.
            Expr::Operator(t)
                if matches!(
                    t.op.as_str(),
                    "transpose" | "reshape" | "concat" | "broadcast"
                ) =>
            {
                self.lower_wholesale(&node.args[0])?
            }
            // Likewise an elementwise combination one of whose operands is a
            // shape op (the bare `a + reshape(b, [1, 3])` spelling).
            base @ Expr::Operator(_) if mentions_shape_op(base) => self.lower_wholesale(base)?,
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

        // A const array read at a subscript that is itself build-time data
        // (`gx[assign[i]]`, a build-time index buffer gathered by a
        // right-hand side) has no affine form; its positions are resolved here.
        if const_base
            && out_ndim == 1
            && (0..n).any(|d| classify_axis_role(&node.args[1 + d], &vb).is_none())
        {
            // A rank-1 const array at one computed subscript whose bounds
            // keep it inside the array (a clamped bracket) has no
            // out-of-range read for a policy to resolve: it is read as any
            // array is, by one indexed gather. The bounds are those of the
            // lowered subscript, so the subscript is lowered speculatively:
            // when the bounds do not prove the read inside, or anything in
            // the attempt bails, everything it emitted (faults included) is
            // undone and the read goes to the routes below as if no attempt
            // had been made.
            let mut bracket_decline = None;
            if n == 1 && src_origin[0] == 1 && self.tile.is_none() {
                let txn = self.sub_txn();
                match self.lower_clamped_bracket_read(node, bx, &arg0, src_shape[0]) {
                    Ok(Some(v)) => return Ok(v),
                    Ok(None) => self.sub_rollback(txn),
                    Err(e) => {
                        self.sub_rollback(txn);
                        bracket_decline = Some(e);
                    }
                }
            }
            let r = match self.lower_const_data_gather(node, bx, &arg0, &src_shape, &src_origin) {
                Ok(Some(v)) => Ok(v),
                Ok(None) => self.lower_data_gather(node, bx, &arg0),
                Err(e) => Err(e),
            };
            return after_decline(bracket_decline, r);
        }
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
                // A second computed subscript, a computed subscript into a
                // const array, or a repeated output symbol (a diagonal): no
                // segment form, so every subscript is evaluated per element.
                _ => return self.lower_data_gather(node, bx, &arg0),
            }
        }
        let read = IndexRead {
            src_shape: &src_shape,
            src_origin: &src_origin,
            mapped: &mapped,
            fixed_raw: &fixed_raw,
            data_axis,
        };
        if let Some((name, axes)) = self.tile_source(&arg0) {
            if data_axis.is_some() {
                return self.lower_tile_index_gather(node, bx, &arg0, &name, &axes, &read);
            }
            return self.lower_tile_gather(bx, &arg0, &name, &axes, &read);
        }
        if const_base {
            return self.lower_const_gather(node, bx, arg0, &read);
        }
        let (fixed, any_fixed_oob) = read.fixed_positions();
        if data_axis.is_some() {
            if let Some(v) = self.lower_index_gather(node, bx, &arg0, &read)? {
                return Ok(v);
            }
            return self.lower_data_gather(node, bx, &arg0);
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

        // Per-axis copy segments.
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
                AxisIndex::Wrap { k, period, lo } => {
                    let segs = wrap_segs(so, ssz, bx.lo[a], bx.shape[a], (*k, *lo, *period));
                    if segs.is_empty() {
                        // Every subscript leaves the source: all ghost-0.
                        return Ok(self.emit_zero_array(&bx.shape, &bx.lo));
                    }
                    axis_segs.push(segs);
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

    /// A data-subscript gather that reads only some of the box's axes
    /// (`u[c, max(1, cnt[c])]` in a `(c, l)` box): evaluated once over the
    /// sub-box of the axes it names and broadcast along the others, as the
    /// per-cell oracle's value at a cell depends on those axes alone. Only
    /// where nothing in it can fault — no const-array read, no closed
    /// function — so no fault's place in the oracle's order moves. `None`
    /// when the gather reads every axis or does not qualify.
    pub(super) fn lower_index_on_sub_box(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
    ) -> LResult<Option<LV>> {
        if bx.syms.len() < 2
            || bx.syms.len() > 31
            || bx.shape.len() != bx.syms.len()
            || bx.tuple != 0
            || self.rule.sweep.is_some()
        {
            return Ok(None);
        }
        let vb = bx.as_vecbox();
        if node.args[1..]
            .iter()
            .all(|e| classify_axis_role(e, &vb).is_some())
        {
            return Ok(None);
        }
        // The axes it reads. A read that could fault (a const array) is
        // still taken when its lowering over the sub-box notes no fault and
        // emits no gather that checks at run time; see below.
        let mut used = vec![false; bx.syms.len()];
        if self.const_arrays.is_const_base(&node.args[0])
            || !self.fault_free_reads(&Expr::Operator(Arc::clone(node)), bx, &mut used)
        {
            let Some(m) = self.sub_box_mask(node, bx) else {
                return Ok(None);
            };
            for (a, u) in used.iter_mut().enumerate() {
                *u = m & (1 << a) != 0;
            }
        }
        let keep: Vec<usize> = (0..bx.syms.len()).filter(|&a| used[a]).collect();
        if keep.is_empty() || keep.len() == bx.syms.len() {
            return Ok(None);
        }
        let syms: Vec<String> = keep.iter().map(|&a| bx.syms[a].clone()).collect();
        let sub = LBox {
            syms: &syms,
            lo: keep.iter().map(|&a| bx.lo[a]).collect(),
            shape: keep.iter().map(|&a| bx.shape[a]).collect(),
            cnames: bx.cnames,
            cvals: bx.cvals.clone(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        // A scope of its own: the value-numbering frame is keyed by node,
        // not by box, so a subexpression this lowers over the sub-box must
        // not answer for the same node over the full box (a template's
        // shared subscript), nor the reverse.
        //
        // The sub-box is only a narrower box for a value that the scan above
        // judged independent of the other axes; a read that scan does not
        // see through (a bare array aligned with the full box by name) does
        // not lower over it. That is this route not applying, not the rule
        // failing: everything the attempt emitted is undone and the gather
        // is lowered over the full box, which declines on its own if the
        // gather cannot be lowered at all. Nothing in it can fault, so no
        // fault is dropped with it.
        let txn = self.sub_txn();
        let guard = self.sub_box_guard();
        let fkey = self.enter_sub_frame(&sub);
        let v = self.lower_index(node, &sub);
        self.leave_sub_frame(fkey);
        let v = match v {
            Ok(v) if self.sub_box_clean(guard) => v,
            _ => {
                self.sub_box_undo(txn, guard);
                return Ok(None);
            }
        };
        let Some((vs, vo)) = self.lv_box(&v) else {
            return Ok(Some(v));
        };
        if vs != sub.shape || vo != sub.lo {
            self.sub_box_undo(txn, guard);
            return Ok(None);
        }
        // Broadcast: output axis `keep[j]` reads source axis `j`.
        let mapped: SmallVec<[bool; 4]> = (0..bx.shape.len()).map(|a| used[a]).collect();
        let segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = (0..bx.shape.len())
            .map(|a| {
                let mut s = SmallVec::new();
                s.push((0usize, bx.shape[a], 0usize));
                s
            })
            .collect();
        let mapped_src: Vec<usize> = (0..keep.len()).collect();
        Ok(Some(self.emit_gather(
            &v,
            SmallVec::new(),
            &mapped_src,
            mapped,
            segs,
            &bx.shape,
            &bx.lo,
        )))
    }

    /// An elementwise operation over a box of two or more axes whose value
    /// depends on only some of them (a term of a nested reduction that does
    /// not read the inner reduction's index): evaluated once over the sub-box
    /// of the axes it reads and broadcast along the others. Each cell of the
    /// sub-box computes what every cell of the full box it stands for would
    /// have computed, with the same operations in the same order, so the
    /// broadcast values are the full-box values bit for bit; only the
    /// repeats along the unread axes are gone.
    ///
    /// Applies to arithmetic, comparisons, unary maps and `ifelse` whose
    /// leaves are literals, the box's loop symbols, scalar names, and
    /// `index` reads of a named array or literal; anything else, or a term
    /// that reads every axis or none, takes the full box. A term whose
    /// lowering over the sub-box notes a fail-closed fault is lowered over
    /// the full box instead, so every fault keeps its place in the oracle's
    /// order.
    pub(super) fn lower_on_sub_box(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
    ) -> LResult<Option<LV>> {
        let n = bx.syms.len();
        if !(2..=31).contains(&n)
            || bx.shape.len() != n
            || bx.tuple != 0
            || self.rule.sweep.is_some()
            || !matches!(
                vec_op_code(&node.op),
                VecOp::Arith(_) | VecOp::Cmp(_) | VecOp::Unary(_) | VecOp::Neg | VecOp::Ifelse
            )
        {
            return Ok(None);
        }
        let Some(used) = self.sub_box_mask(node, bx) else {
            return Ok(None);
        };
        let used = used & !SUB_BOX_OP;
        let full = (1u32 << n) - 1;
        if used == 0 || used == full {
            return Ok(None);
        }
        // The broadcast is a pass over the full box of its own, and a short
        // term left in the box fuses with its neighbours: only a term of
        // several operations is worth moving.
        if !Self::has_sub_box_ops(node, SUB_BOX_MIN_OPS) {
            return Ok(None);
        }
        let keep: Vec<usize> = (0..n).filter(|&a| used & (1 << a) != 0).collect();
        let syms: Vec<String> = keep.iter().map(|&a| bx.syms[a].clone()).collect();
        let sub = LBox {
            syms: &syms,
            lo: keep.iter().map(|&a| bx.lo[a]).collect(),
            shape: keep.iter().map(|&a| bx.shape[a]).collect(),
            cnames: bx.cnames,
            cvals: bx.cvals.clone(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        // Its own value-numbering scope, as in `lower_index_on_sub_box`: a
        // node lowered over the sub-box must not answer for the same node
        // over the full box.
        let txn = self.sub_txn();
        let guard = self.sub_box_guard();
        let fkey = self.enter_sub_frame(&sub);
        let v = self.lower_op(node, &sub);
        self.leave_sub_frame(fkey);
        let v = match v {
            Ok(v) if self.sub_box_clean(guard) => v,
            _ => {
                self.sub_box_undo(txn, guard);
                return Ok(None);
            }
        };
        let Some((vs, vo)) = self.lv_box(&v) else {
            return Ok(Some(v));
        };
        if vs != sub.shape || vo != sub.lo {
            self.sub_box_undo(txn, guard);
            return Ok(None);
        }
        let mapped: SmallVec<[bool; 4]> = (0..n).map(|a| used & (1 << a) != 0).collect();
        let segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = (0..n)
            .map(|a| {
                let mut s = SmallVec::new();
                s.push((0usize, bx.shape[a], 0usize));
                s
            })
            .collect();
        let mapped_src: Vec<usize> = (0..keep.len()).collect();
        Ok(Some(self.emit_gather(
            &v,
            SmallVec::new(),
            &mapped_src,
            mapped,
            segs,
            &bx.shape,
            &bx.lo,
        )))
    }

    /// Open the value-numbering frame of sub-box `sub` of the box whose frame
    /// is innermost: the one an earlier term moved to `sub` left, at this
    /// branch depth, or a fresh one. A node lowered over the sub-box never
    /// answers for the same node over the box, nor the reverse.
    pub(super) fn enter_sub_frame(&mut self, sub: &LBox) -> (BoxKey, usize) {
        let key = (BoxKey::of(sub), self.rule.branch_bufs.len());
        let frame = self
            .rule
            .scope_frames
            .last_mut()
            .and_then(|f| f.subs.remove(&key))
            .unwrap_or_default();
        self.rule.scope_frames.push(frame);
        key
    }

    /// Close the frame [`Self::enter_sub_frame`] opened, keeping it for the
    /// next term moved to the same sub-box.
    pub(super) fn leave_sub_frame(&mut self, key: (BoxKey, usize)) {
        let frame = self.rule.scope_frames.pop().expect("sub-box frame open");
        if let Some(parent) = self.rule.scope_frames.last_mut() {
            parent.subs.insert(key, frame);
        }
    }

    /// The fault counters a sub-box lowering must leave as they were:
    /// noted faults (certain and lazy) and run-time-checked gathers.
    pub(super) fn sub_box_guard(&self) -> (u32, u32, usize) {
        (
            self.fault.notes,
            self.fault.lazy_notes,
            self.tables.data_gathers.len(),
        )
    }

    /// Whether nothing since `guard` can fault: a fault over the sub-box
    /// would be placed by the sub-box's cells, not the full box's.
    pub(super) fn sub_box_clean(&self, guard: (u32, u32, usize)) -> bool {
        self.fault.notes == guard.0
            && self.fault.lazy_notes == guard.1
            && self.tables.data_gathers[guard.2..]
                .iter()
                .all(|d| d.order.is_none())
    }

    pub(super) fn sub_box_undo(&mut self, txn: SubTxn, guard: (u32, u32, usize)) {
        self.sub_rollback(txn);
        self.fault.notes = guard.0;
        self.fault.lazy_notes = guard.1;
    }

    /// [`Self::sub_box_axes`] of `node` over `bx`, through the current
    /// rule's memo for `bx`.
    pub(super) fn sub_box_mask(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> Option<u32> {
        let ix = match self.sub_box_memo.iter().position(|(k, _)| k.is_of(bx)) {
            Some(ix) => ix,
            None => {
                self.sub_box_memo
                    .push((BoxKey::of(bx), FxHashMap::default()));
                self.sub_box_memo.len() - 1
            }
        };
        let mut memo = std::mem::take(&mut self.sub_box_memo[ix].1);
        let m = self.sub_box_axes(&Expr::Operator(Arc::clone(node)), bx, &mut memo);
        self.sub_box_memo[ix].1 = memo;
        m
    }

    /// Whether the term `node` holds at least `min` distinct operations of
    /// the kinds [`Self::sub_box_axes`] marks with [`SUB_BOX_OP`], walking
    /// what that scan walks (an `index` node's subscripts, not its base) and
    /// stopping at the `min`-th. Called only on a term the scan accepted.
    pub(super) fn has_sub_box_ops(node: &Arc<ExpressionNode>, min: usize) -> bool {
        let mut ops = 0;
        let mut stack: SmallVec<[&ExpressionNode; 8]> = SmallVec::new();
        stack.push(node);
        let mut visited: rustc_hash::FxHashSet<usize> = rustc_hash::FxHashSet::default();
        while let Some(nd) = stack.pop() {
            if !visited.insert(nd as *const ExpressionNode as usize) {
                continue;
            }
            let args = match vec_op_code(&nd.op) {
                VecOp::Arith(_) | VecOp::Cmp(_) | VecOp::Unary(_) | VecOp::Neg | VecOp::Ifelse => {
                    ops += 1;
                    if ops >= min {
                        return true;
                    }
                    &nd.args[..]
                }
                VecOp::Index => nd.args.get(1..).unwrap_or(&[]),
                _ => &[],
            };
            for a in args.iter().rev() {
                if let Expr::Operator(c) = a {
                    stack.push(c);
                }
            }
        }
        false
    }

    /// The box axes `e` reads, as a bit mask over `bx.syms`, for
    /// [`Self::lower_on_sub_box`]; `None` when `e` holds anything that rule
    /// does not take (a reduction, an array builder, a whole-array name). `memo` keys a node by address: an expanded
    /// template shares its subterms, and a tree walk of the sharing would
    /// repeat them.
    pub(super) fn sub_box_axes(
        &self,
        e: &Expr,
        bx: &LBox,
        memo: &mut FxHashMap<usize, Option<u32>>,
    ) -> Option<u32> {
        match e {
            Expr::Number(_) | Expr::Integer(_) => Some(0),
            Expr::Variable(v) => {
                if let Some(a) = bx.syms.iter().position(|s| s == v) {
                    return Some(1 << a);
                }
                self.scalar_name(v, bx).then_some(0)
            }
            Expr::Operator(nd) => {
                let key = Arc::as_ptr(nd) as usize;
                if let Some(hit) = memo.get(&key) {
                    return *hit;
                }
                let r = self.sub_box_axes_op(nd, bx, memo);
                memo.insert(key, r);
                r
            }
        }
    }

    pub(super) fn sub_box_axes_op(
        &self,
        nd: &Arc<ExpressionNode>,
        bx: &LBox,
        memo: &mut FxHashMap<usize, Option<u32>>,
    ) -> Option<u32> {
        let args = |b: &Self, xs: &[Expr], memo: &mut FxHashMap<usize, Option<u32>>| {
            xs.iter()
                .try_fold(0u32, |acc, a| Some(acc | b.sub_box_axes(a, bx, memo)?))
        };
        match vec_op_code(&nd.op) {
            VecOp::Arith(_) | VecOp::Cmp(_) | VecOp::Unary(_) | VecOp::Neg | VecOp::Ifelse => {
                args(self, &nd.args, memo).map(|m| m | SUB_BOX_OP)
            }
            VecOp::Const => match eval_const(nd) {
                Value::Scalar(_) => Some(0),
                Value::Array(_) => None,
            },
            VecOp::BoolLit(_) => Some(0),
            VecOp::Index => {
                let (base, subs) = nd.args.split_first()?;
                let base_ok = match base {
                    Expr::Variable(_) => true,
                    Expr::Operator(b) => b.op == "const",
                    _ => false,
                };
                if !base_ok || subs.is_empty() {
                    return None;
                }
                args(self, subs, memo).map(|m| m & !SUB_BOX_OP)
            }
            _ => None,
        }
    }

    /// Whether `e` reads nothing that can fault (no const array or array
    /// literal, no nested aggregate or array builder),
    /// marking in `used` each box axis whose symbol it names.
    pub(super) fn fault_free_reads(&self, e: &Expr, bx: &LBox, used: &mut [bool]) -> bool {
        match e {
            Expr::Number(_) | Expr::Integer(_) => true,
            Expr::Variable(v) => {
                if let Some(a) = bx.syms.iter().position(|s| s == v) {
                    used[a] = true;
                }
                !self.const_arrays.is_const(v)
            }
            Expr::Operator(n) => {
                if matches!(n.op.as_str(), "const" | "faq" | "makearray" | "broadcast")
                    && !(n.op == "const"
                        && n.value.as_ref().is_some_and(crate::ConstValue::is_number))
                {
                    return false;
                }
                if n.op == "index" && self.const_arrays.is_const_base(&n.args[0]) {
                    return false;
                }
                n.args.iter().all(|a| self.fault_free_reads(a, bx, used))
            }
        }
    }

    /// `index(c, s…)` over a rank-1 box, `c` a const array and some subscript
    /// build-time data rather than an affine map of the box. Each cell's
    /// source position is resolved here, as `index_into` resolves it (the
    /// subscript rounded; out of range obeys `c`'s boundary policy), into one
    /// [`Instr::TableGather`]. `None` when a subscript is not build-time
    /// data, or a position is out of range under the `error` policy: the
    /// caller then evaluates the subscripts per element instead
    /// ([`Self::lower_data_gather`]), which faults where the oracle does.
    pub(super) fn lower_const_data_gather(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
        base: &LV,
        src_shape: &[usize],
        src_origin: &[i64],
    ) -> LResult<Option<LV>> {
        if src_origin.iter().any(|&o| o != 1) {
            bail_tape!("index: const-array gather on a source not at origin 1");
        }
        let name = match &node.args[0] {
            Expr::Variable(v) => v.as_str(),
            _ => INLINE_CONST_NAME,
        };
        let m = bx.shape[0];
        let mut sub_vals: Vec<Vec<f64>> = Vec::with_capacity(src_shape.len());
        for e in &node.args[1..] {
            match self.build_time_subscript(e, bx)? {
                Some(v) => sub_vals.push(v),
                None => return Ok(None),
            }
        }
        let n_src: usize = src_shape.iter().product();
        if n_src >= GATHER_GHOST as usize {
            return Ok(None);
        }
        let Ok(pos) = self.const_positions(name, src_shape, &sub_vals, m) else {
            return Ok(None);
        };
        // Every position is in range (`const_positions` resolves or
        // declines each), so no element is a ghost.
        let vals = match base {
            LV::Arr(s) => self
                .known_slice(*s)
                .map(|b| pos.iter().map(|&p| b[p as usize]).collect::<Vec<f64>>()),
            _ => None,
        };
        // Under `defer_consts` the gathered values ARE the gather's result:
        // the `TableGather` would copy exactly these elements out of a slot
        // that holds the whole base.
        if self.defer_consts
            && self.lv_cadence(base) == Cadence::Const
            && let Some(v) = vals
        {
            let out = self.emit_const_data(&bx.shape, &bx.lo, Arc::new(v), false)?;
            return Ok(Some(LV::Arr(out)));
        }
        let table = tape_index(self.tables.gather_tables.len(), "gather tables")?;
        self.tables.gather_tables.push(GatherTable {
            src_shape: src_shape.iter().copied().collect(),
            pos,
        });
        let sec = self.placement(self.lv_cadence(base));
        let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
        let instr = Instr::TableGather {
            src: self.src_of(base),
            table,
            out,
        };
        self.emit(instr, sec);
        if let Some(v) = vals {
            self.known.insert(out, Known::Vals(Arc::new(v)));
        }
        Ok(Some(LV::Arr(out)))
    }

    /// `index(base, s)` on a rank-1 const array of `len` entries at origin 1,
    /// read by one indexed gather when the lowered subscript's bounds keep
    /// every read inside it; `Ok(None)` otherwise.
    pub(super) fn lower_clamped_bracket_read(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
        base: &LV,
        len: usize,
    ) -> LResult<Option<LV>> {
        let sub = self.lower_expr(&node.args[1], bx)?;
        let inside = self
            .operand_range(&self.op_of(&sub))
            .is_some_and(|(lo, hi)| subscript_of(lo) >= 1 && subscript_of(hi) <= len as i64);
        if !inside {
            return Ok(None);
        }
        let read = IndexRead {
            src_shape: &[len],
            src_origin: &[1],
            mapped: &[None],
            fixed_raw: &[],
            data_axis: Some(0),
        };
        self.lower_index_gather(node, bx, base, &read)
    }

    /// `index(base, s…)` with every subscript evaluated per element of the
    /// box: one [`Instr::DataGather`]. This is the oracle's per-cell
    /// `eval_index` for any subscript the segment and table gathers have no
    /// form for — a reversed or parameter-offset axis, a data-dependent
    /// `c[j[i]]`, a clamp, a `mod`/`floor` unflattening.
    pub(super) fn lower_data_gather(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
        base: &LV,
    ) -> LResult<LV> {
        if let Some(v) = self.lower_known_subscript_gather(node, bx, base)? {
            return Ok(v);
        }
        let mut subs: SmallVec<[LV; 4]> = SmallVec::new();
        for e in &node.args[1..] {
            let s = self.lower_expr(e, bx)?;
            self.note_int_range(&s, e, bx);
            subs.push(s);
        }
        self.emit_data_gather(&node.args[0], base, &subs, Some(bx))
    }

    /// `index(base, s…)` over a rank-1 box whose every subscript is
    /// build-time data ([`Self::build_time_subscript`]) and lands inside
    /// `base` at every element: the positions are resolved here into one
    /// [`Instr::TableGather`], which reads the elements the per-element
    /// gather would. A read with any position outside `base`, whose
    /// resolution depends on the source's kind, is left to that gather.
    pub(super) fn lower_known_subscript_gather(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
        base: &LV,
    ) -> LResult<Option<LV>> {
        if bx.shape.len() != 1 || bx.tuple != 0 || self.rule.sweep.is_some() {
            return Ok(None);
        }
        let Some((src_shape, src_origin)) = self.lv_box(base) else {
            return Ok(None);
        };
        let subs_e = &node.args[1..];
        if subs_e.len() != src_shape.len() {
            return Ok(None);
        }
        let n_src: usize = src_shape.iter().product();
        if n_src >= GATHER_GHOST as usize {
            return Ok(None);
        }
        let mut subs: Vec<Vec<f64>> = Vec::with_capacity(subs_e.len());
        for e in subs_e {
            match self.build_time_subscript(e, bx)? {
                Some(v) => subs.push(v),
                None => return Ok(None),
            }
        }
        let m = bx.shape[0];
        let mut pos = Vec::with_capacity(m);
        for p in 0..m {
            let mut flat = 0usize;
            for (d, sv) in subs.iter().enumerate() {
                let k = subscript_of(sv[p]) - src_origin[d];
                if k < 0 || k >= src_shape[d] as i64 {
                    return Ok(None);
                }
                flat = flat * src_shape[d] + k as usize;
            }
            pos.push(flat as u32);
        }
        let table = tape_index(self.tables.gather_tables.len(), "gather tables")?;
        self.tables.gather_tables.push(GatherTable {
            src_shape: src_shape.iter().copied().collect(),
            pos,
        });
        let sec = self.placement(self.lv_cadence(base));
        let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
        let instr = Instr::TableGather {
            src: self.src_of(base),
            table,
            out,
        };
        self.emit(instr, sec);
        Ok(Some(LV::Arr(out)))
    }

    /// How an `index` on `base` (a source of extents `shape`) resolves an
    /// out-of-range subscript: the declared boundary policy of a const array
    /// (`error` for an empty axis, whatever is declared), else the zero
    /// ghost.
    pub(super) fn gather_kind(&self, base: &Expr, shape: &[usize]) -> ScalarReadKind {
        if !self.const_arrays.is_const_base(base) {
            return ScalarReadKind::ZeroGhost;
        }
        let name = match base {
            Expr::Variable(v) => v.clone(),
            _ => INLINE_CONST_NAME.to_string(),
        };
        let policy = (0..shape.len())
            .map(|d| {
                if shape[d] == 0 {
                    BoundaryKind::Error
                } else {
                    self.const_arrays.boundary(&name, d)
                }
            })
            .collect();
        ScalarReadKind::ConstArray { name, policy }
    }

    /// Emit the [`Instr::DataGather`] of `src` (the value of `base`) at the
    /// subscripts `subs`, over `bx` (`None`: one scalar read, the wholesale
    /// path). A const-array source whose policy can fault records where the
    /// oracle reaches each element ([`FaultOrder`]), so the latch keeps the
    /// fault the oracle raises first; where the oracle evaluates only some
    /// elements (an elementwise `ifelse` arm, a filtered term, a recurrence
    /// body) that order is not the element order, and the rule is refused.
    pub(super) fn emit_data_gather(
        &mut self,
        base: &Expr,
        src: &LV,
        subs: &[LV],
        bx: Option<&LBox>,
    ) -> LResult<LV> {
        let Some((src_shape, src_origin)) = self.lv_box(src) else {
            bail_tape!("index: computed subscripts on a source with no axes");
        };
        if src_origin.iter().any(|&o| o != 1) {
            bail_tape!("index: computed-subscript read of a source not at origin 1");
        }
        if subs.len() != src_shape.len() {
            bail_tape!(
                "index: {} computed subscripts on a rank-{} source",
                subs.len(),
                src_shape.len()
            );
        }
        let (shape, lo): (DimU, DimI) = match bx {
            Some(b) => (b.shape.clone(), b.lo.clone()),
            None => (DimU::new(), DimI::new()),
        };
        let mut want = self.lv_cadence(src);
        for s in subs {
            if let Some((ss, so)) = self.lv_box(s)
                && (ss != shape || so != lo)
            {
                bail_tape!("index: a computed subscript's box is not the output box");
            }
            want = want.max(self.lv_cadence(s));
        }
        let kind = self.gather_kind(base, &src_shape);
        // Subscripts whose bounds put every element inside the source (a
        // clamped bracket, `table[i_lo]` and `table[i_lo + 1]`) cannot fault.
        let in_range = subs.iter().zip(src_shape.iter()).all(|(s, &n)| {
            self.operand_range(&self.op_of(s))
                .is_some_and(|(lo, hi)| subscript_of(lo) >= 1 && subscript_of(hi) <= n as i64)
        });
        let faults = !in_range
            && matches!(&kind, ScalarReadKind::ConstArray { policy, .. }
            if policy.iter().any(|p| matches!(p, BoundaryKind::Error)));
        let lazy = faults && self.fault.lazy_depth > 0;
        let order = if lazy {
            // The oracle reads this gather only at the cells its conditions
            // admit: the rule's `FaultScan` checks those cells, and the
            // instruction itself only reads `NaN` where one would fault.
            let ScalarReadKind::ConstArray { name, policy } = &kind else {
                unreachable!("only a const-array gather faults");
            };
            let dims = subs
                .iter()
                .zip(policy.iter())
                .zip(src_shape.iter())
                .map(|((s, p), &n)| OobDim {
                    n: n as i64,
                    error: matches!(p, BoundaryKind::Error),
                    sub: match s {
                        LV::Lit(v) => OobSub::Fixed(subscript_of(*v)),
                        other => OobSub::Data {
                            op: self.op_of(other),
                            array: self.lv_box(other).is_some(),
                        },
                    },
                })
                .collect();
            let what = FaultWhat::ConstOob {
                name: name.clone(),
                dims,
            };
            let msg = format!("E_TREEWALK_CONSTARRAY_OOB: const array '{name}'");
            match bx {
                Some(b) => {
                    let first: SmallVec<[i64; 4]> = SmallVec::from_elem(0, b.shape.len());
                    self.note_fault(Some((b, &first)), msg, Some(what))?;
                }
                None => self.note_fault(None, msg, Some(what))?,
            }
            None
        } else if faults {
            if self.rule.sweep.is_some() {
                bail_tape!(
                    "fault: `E_TREEWALK_CONSTARRAY_OOB` of a computed-subscript gather inside \
                     a recurrence body"
                );
            }
            let (axes, tail) = match bx {
                Some(b) => {
                    let axes: SmallVec<[u8; 4]> = if b.syms.is_empty() {
                        SmallVec::new()
                    } else {
                        (0..b.shape.len()).map(|k| b.visit_axis(k) as u8).collect()
                    };
                    (
                        axes,
                        b.cvals.iter().copied().collect::<SmallVec<[i64; 8]>>(),
                    )
                }
                None => (SmallVec::new(), SmallVec::new()),
            };
            let mut tail = tail;
            tail.push(self.fault.seq);
            self.fault.seq += 1;
            Some(FaultOrder {
                rule: self.cur_rule,
                head: self.fault.prefix.clone(),
                axes,
                lo: lo.clone(),
                tail,
            })
        } else {
            None
        };
        let faults = order.is_some();
        let spec = tape_index(self.tables.data_gathers.len(), "computed-subscript gathers")?;
        self.tables.data_gathers.push(DataGatherSpec {
            subs: subs.iter().map(|s| self.op_of(s)).collect(),
            kind,
            src_shape,
            shape: shape.clone(),
            order,
            reversed: false,
        });
        let mut sec = self.placement(want);
        if faults {
            // No earlier than an earlier rule's run-time faults; within the
            // home section, where the rule's readers of `out` run.
            sec = sec.max(self.fault.floor.min(self.home));
            self.fault.rule_sec = self.fault.rule_sec.max(sec);
        }
        let out = self.new_slot(&shape, &lo, shape.is_empty(), sec);
        let instr = Instr::DataGather {
            src: self.src_of(src),
            spec,
            out,
            faults,
        };
        self.emit(instr, sec);
        Ok(if shape.is_empty() {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    /// Flat row-major source positions of a const-array gather whose
    /// per-cell subscripts (1-based, before rounding) are `sub_vals`.
    pub(super) fn const_positions(
        &self,
        name: &str,
        src_shape: &[usize],
        sub_vals: &[Vec<f64>],
        m: usize,
    ) -> LResult<Vec<u32>> {
        let mut strides: Vec<usize> = vec![1; src_shape.len()];
        for d in (0..src_shape.len().saturating_sub(1)).rev() {
            strides[d] = strides[d + 1] * src_shape[d + 1];
        }
        let mut pos: Vec<u32> = Vec::with_capacity(m);
        for k in 0..m {
            let mut flat = 0usize;
            for (d, vals) in sub_vals.iter().enumerate() {
                // `eval_index_args`: the subscript rounded (NaN reads as 0).
                let raw = vals[k].round() as i64;
                let n = src_shape[d] as i64;
                let kind = if n == 0 {
                    BoundaryKind::Error
                } else {
                    self.const_arrays.boundary(name, d)
                };
                let Some(i0) = resolve_const_index(kind, raw, n) else {
                    bail_tape!("index: const-array gather out of range (§5.5.5)");
                };
                flat += i0 * strides[d];
            }
            pos.push(flat as u32);
        }
        Ok(pos)
    }

    /// The per-cell values of an `index` subscript over a rank-1 box, when the
    /// build knows them: an affine map of the box's symbol, a constant, a
    /// const-array gather at build-time subscripts, or a slot whose values the
    /// build computed. `None` otherwise.
    pub(super) fn build_time_subscript(
        &mut self,
        e: &Expr,
        bx: &LBox,
    ) -> LResult<Option<Vec<f64>>> {
        let m = bx.shape[0];
        match classify_axis_role(e, &bx.as_vecbox()) {
            Some(AxisRole::Map {
                out_axis: 0,
                ax: AxisIndex::Affine(k),
            }) => {
                return Ok(Some(
                    (0..m).map(|p| (bx.lo[0] + p as i64 + k) as f64).collect(),
                ));
            }
            Some(AxisRole::Const(i)) => return Ok(Some(vec![i as f64; m])),
            _ => {}
        }
        if let Expr::Operator(n) = e
            && n.op == "index"
            && let Some(Expr::Variable(name)) = n.args.first()
            && self.const_arrays.is_const(name)
            && let Some((shape, vals)) = self.known_named(name)
            && shape.len() + 1 == n.args.len()
        {
            let mut subs: Vec<Vec<f64>> = Vec::with_capacity(shape.len());
            for a in &n.args[1..] {
                match self.build_time_subscript(a, bx)? {
                    Some(v) => subs.push(v),
                    None => return Ok(None),
                }
            }
            let Ok(pos) = self.const_positions(name, &shape, &subs, m) else {
                return Ok(None);
            };
            return Ok(Some(pos.iter().map(|&p| vals[p as usize]).collect()));
        }
        // The same read of an inline literal (`index([…], k)`).
        if let Expr::Operator(n) = e
            && n.op == "index"
            && let Some(Expr::Operator(c)) = n.args.first()
            && c.op == "const"
            && let Value::Array(a) = eval_const(c)
            && a.ndim() + 1 == n.args.len()
        {
            let shape: Vec<usize> = a.shape().to_vec();
            let vals: Vec<f64> = a.iter().copied().collect();
            let mut subs: Vec<Vec<f64>> = Vec::with_capacity(shape.len());
            for x in &n.args[1..] {
                match self.build_time_subscript(x, bx)? {
                    Some(v) => subs.push(v),
                    None => return Ok(None),
                }
            }
            let Ok(pos) = self.const_positions(INLINE_CONST_NAME, &shape, &subs, m) else {
                return Ok(None);
            };
            return Ok(Some(pos.iter().map(|&p| vals[p as usize]).collect()));
        }
        Ok(None)
    }

    /// `index(x, i…)` inside a recurrence cell body, where every subscript is
    /// one scalar: an [`Instr::ScalarRead`], resolved at run time exactly as
    /// `eval_index` resolves it. A read of the variable being defined is the
    /// causal self-read (fail-closed on a cell the sweep has not published);
    /// any other source reads by its provenance — the zero ghost for a state
    /// or observed array, the declared boundary policy (else the fault) for a
    /// const array. A read whose subscripts are all constants is the same at
    /// every cell and lands ahead of the sweep ([`Self::emit_tagged`]).
    pub(super) fn lower_cell_index(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
    ) -> LResult<LV> {
        let base = &node.args[0];
        let n = node.args.len() - 1;
        let sweep = self
            .rule
            .sweep
            .as_ref()
            .map(|sw| (sw.spec, sw.out, sw.var.clone()));
        let (src, src_shape, kind) = match (&sweep, base) {
            (Some((spec, out, var)), Expr::Variable(v)) if v == var => {
                let shape = self.tables.sweeps[*spec as usize].shape.clone();
                (
                    LV::Arr(*out),
                    shape,
                    ScalarReadKind::SelfRead { sweep: *spec },
                )
            }
            _ => {
                let lv = match base {
                    Expr::Operator(lit) if lit.op == "const" => match eval_const(lit) {
                        Value::Array(a) => self.const_literal_array(lit, &a, Some(bx))?,
                        Value::Scalar(s) => LV::Lit(s),
                    },
                    other => self.lower_expr(other, bx)?,
                };
                let Some((shape, origin)) = self.lv_box(&lv) else {
                    return if n == 0 {
                        Ok(lv)
                    } else {
                        self.index_on_scalar(base, &lv, n, Some(bx))
                    };
                };
                if origin.iter().any(|&o| o != 1) {
                    bail_tape!("index: run-time-subscript read of a source not at origin 1");
                }
                let kind = if self.const_arrays.is_const_base(base) {
                    let name = match base {
                        Expr::Variable(v) => v.clone(),
                        _ => INLINE_CONST_NAME.to_string(),
                    };
                    let policy = (0..shape.len())
                        .map(|d| {
                            if shape[d] == 0 {
                                BoundaryKind::Error
                            } else {
                                self.const_arrays.boundary(&name, d)
                            }
                        })
                        .collect();
                    ScalarReadKind::ConstArray { name, policy }
                } else {
                    ScalarReadKind::ZeroGhost
                };
                (lv, shape, kind)
            }
        };
        if n != src_shape.len() {
            bail_tape!(
                "index: {n} subscripts on a rank-{} source inside a recurrence body (a \
                 partial read selects a sub-array, which a cell cannot hold)",
                src_shape.len()
            );
        }
        let mut subs: SmallVec<[Operand; 4]> = SmallVec::new();
        let mut want = self.lv_cadence(&src);
        for e in &node.args[1..] {
            let v = self.lower_expr(e, bx)?;
            if self.lv_box(&v).is_some() {
                bail_tape!("index: an array-valued subscript inside a recurrence body");
            }
            want = want.max(self.lv_cadence(&v));
            subs.push(self.op_of(&v));
        }
        let sec = self.placement(want);
        let out = self.new_slot(&[], &[], true, sec);
        let spec = tape_index(self.tables.scalar_reads.len(), "run-time-subscript reads")?;
        self.tables.scalar_reads.push(ScalarReadSpec { subs, kind });
        let instr = Instr::ScalarRead {
            src: self.src_of(&src),
            spec,
            out,
        };
        self.emit(instr, sec);
        Ok(LV::Scalar(out))
    }

    /// `LoadElem` of the element `fixed` (0-based, per source dim) names.
    pub(super) fn emit_load_elem(&mut self, src: &LV, fixed: &[(usize, i64)]) -> LV {
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
    /// the mapped source axes into output order — is [`GatherPlan`]'s.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn emit_gather(
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
        let plan_ix = self.tables.plans.len() as u32;
        self.tables.plans.push(GatherPlan {
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
    pub(super) fn index_on_scalar(
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
                self.note_fault(Some((b, &first)), msg, None)?;
            }
            None => self.note_fault(None, msg, None)?,
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
    pub(super) fn lower_const_gather(
        &mut self,
        node: &Arc<ExpressionNode>,
        bx: &LBox,
        src: LV,
        read: &IndexRead,
    ) -> LResult<LV> {
        let IndexRead {
            src_shape,
            src_origin,
            mapped,
            fixed_raw,
            ..
        } = *read;
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
                Some((d, AxisIndex::Wrap { k, period, lo })) => {
                    // Each run of the wrap is an affine read of its own, and
                    // neighbouring copy runs merge back into one, so a full
                    // roll stays the single two-segment copy it always was.
                    let n_d = src_shape[*d] as i64;
                    for (start, len, shift) in wrap_pieces(bx.lo[a], n_a, *k, *lo, *period) {
                        let base = bx.lo[a] + start as i64 + shift;
                        for (s0, l0, run) in affine_const_runs(base, len, n_d, policy(*d)) {
                            let at = start + s0;
                            if let (ConstRun::Copy(segs), Some((ps, pl, ConstRun::Copy(prev)))) =
                                (&run, rs.last_mut())
                            {
                                debug_assert_eq!(*ps + *pl, at, "runs tile the axis");
                                let off = at - *ps;
                                prev.extend(segs.iter().map(|&(o, l, so)| (o + off, l, so)));
                                *pl += l0;
                                continue;
                            }
                            rs.push((at, l0, run));
                        }
                    }
                }
                Some((d, AxisIndex::Affine(k))) => {
                    // The 1-based subscript at position `p` is `base + p`.
                    let n_d = src_shape[*d] as i64;
                    rs.extend(affine_const_runs(bx.lo[a] + *k, n_a, n_d, policy(*d)));
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
            let msg = self.const_oob_first(bx, name, read, fixed_oob, &runs);
            let cell = msg.0;
            // Which cells fault, for a read the oracle evaluates at only some
            // of them: per source dim, its subscript at each cell.
            let what = (self.in_branch() || self.fault.lazy_depth > 0).then(|| {
                let dims = (0..src_shape.len())
                    .map(|d| {
                        let sub = match fixed_raw.iter().find(|(fd, _)| *fd == d) {
                            Some(&(_, raw)) => OobSub::Fixed(raw),
                            None => {
                                let (a, ax) = mapped
                                    .iter()
                                    .enumerate()
                                    .find_map(|(a, m)| {
                                        m.as_ref().filter(|(md, _)| *md == d).map(|(_, ax)| (a, ax))
                                    })
                                    .expect("every source dim is fixed or mapped");
                                let raw = (0..bx.shape[a] as i64)
                                    .map(|p| match ax {
                                        AxisIndex::Affine(k) => bx.lo[a] + p + k,
                                        AxisIndex::Wrap { k, period, lo } => {
                                            wrap_subscript(bx.lo[a], p, (*k, *lo, *period))
                                        }
                                    })
                                    .collect();
                                OobSub::Axis { axis: a as u8, raw }
                            }
                        };
                        OobDim {
                            n: src_shape[d] as i64,
                            error: matches!(policy(d), BoundaryKind::Error),
                            sub,
                        }
                    })
                    .collect();
                FaultWhat::ConstOob {
                    name: name.to_string(),
                    dims,
                }
            });
            self.note_fault(Some((bx, &cell)), msg.1, what)?;
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
            let region = tape_index(self.tables.regions.len(), "makearray regions")?;
            self.tables.regions.push(RegionSpec {
                dest_lo: DimU::from_elem(0, out_ndim),
                shape: bx.shape.clone(),
            });
            spec_parts.push((Operand::Lit(f64::NAN), region));
        }
        let mut want = Cadence::Const;
        for (v, dest, shape) in &parts {
            want = want.max(self.lv_cadence(v));
            let region = tape_index(self.tables.regions.len(), "makearray regions")?;
            self.tables.regions.push(RegionSpec {
                dest_lo: dest.clone(),
                shape: shape.clone(),
            });
            spec_parts.push((self.op_of(v), region));
        }
        let table = tape_index(self.tables.assemblies.len(), "makearray assemblies")?;
        self.tables
            .assemblies
            .push(AssembleSpec { parts: spec_parts });
        let sec = self.placement(want);
        let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
        self.emit(Instr::Assemble { table, out }, sec);
        Ok(LV::Arr(out))
    }
}
