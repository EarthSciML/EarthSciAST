//! Rule driving: lowering each observed and right-hand-side rule in its
//! transaction, its fault and export bookkeeping, and assembling the
//! program the passes then rewrite.

use super::*;

impl<'m> TapeBuilder<'m> {
    pub(super) fn begin_rule(&mut self, info: RuleInfo) {
        self.cur_rule = self.rules.len() as u32;
        self.home = info.cadence;
        self.rules.push(info);
        self.declined.push(None);
        self.rule_home_chunk.push(None);
        self.rule.scope_frames.clear();
        self.rule.branch_bufs.clear();
        self.rule.branch_secs.clear();
        self.hoist_journal.clear();
        self.sub_box_memo.clear();
        self.fault.first = None;
        self.fault.seq = 0;
        self.fault.prefix.clear();
        self.fault.lazy_depth = 0;
        self.fault.reach.clear();
        self.fault.lazy.clear();
        self.fault.rule_sec = Cadence::Const;
    }

    /// Emit the lowered rule's first fault (if any) as one [`Instr::Fault`],
    /// AHEAD of the rule's CONST-section instructions. It reads nothing, and
    /// the CONST section runs first, so it latches before anything else of
    /// this rule — which is where the oracle, walking the rule cell by cell,
    /// latches its first fault — and after every earlier rule's. When an
    /// earlier rule latches in a later section ([`FaultTrack::floor`]), it
    /// goes at the end of the rule in that section instead.
    ///
    /// A rule with faults at lazily evaluated positions that the first
    /// certain one does not precede gets one [`Instr::FaultScan`] instead,
    /// holding them and the certain one: it runs after everything its
    /// conditions read, at the end of the rule in the latest section any of
    /// them is computed in (or the floor, if later).
    pub(super) fn flush_rule_fault(&mut self) -> LResult<()> {
        let floor = self.fault.floor;
        self.flush_rule_fault_at(floor)?;
        self.fault.floor = floor.max(self.fault.rule_sec);
        Ok(())
    }

    pub(super) fn flush_rule_fault_at(&mut self, floor: Cadence) -> LResult<()> {
        let lazy = std::mem::take(&mut self.fault.lazy);
        let first = self.fault.first.take();
        let mut cands: Vec<FaultCand> = lazy
            .into_iter()
            .filter(|(k, _)| first.as_ref().is_none_or(|(fk, _)| k < fk))
            .map(|(_, c)| c)
            .collect();
        if !cands.is_empty() {
            if let Some((key, msg)) = first {
                let m = tape_index(self.tables.faults.len(), "faults")?;
                self.tables.faults.push(msg);
                self.tables.fault_order.push((self.cur_rule, key.clone()));
                let (seq, prefix) = key
                    .split_last()
                    .expect("a fault key ends with its sequence");
                cands.push(FaultCand {
                    prefix: prefix.iter().copied().collect(),
                    cells: false,
                    shape: DimU::new(),
                    lo: DimI::new(),
                    visit: SmallVec::new(),
                    cvals: SmallVec::new(),
                    seq: *seq,
                    path: Vec::new(),
                    what: FaultWhat::Every(m),
                });
            }
            let mut sec = Cadence::Const;
            for c in &cands {
                for pc in &c.path {
                    let cad = match pc.op {
                        Operand::Lit(_) | Operand::Param(_) => Cadence::Const,
                        Operand::Slot(sl) => self.tables.slots[sl as usize].cadence,
                        _ => Cadence::Continuous,
                    };
                    sec = sec.max(cad);
                }
            }
            let spec = tape_index(self.tables.fault_scans.len(), "fault scans")?;
            self.tables.fault_scans.push(FaultScanSpec {
                rule: self.cur_rule,
                cands,
            });
            let sec = sec.min(self.home).max(floor);
            self.push_stream(Instr::FaultScan { spec }, crate::precision::active(), sec);
            self.fault.rule_sec = self.fault.rule_sec.max(sec);
            return Ok(());
        }
        let Some((key, msg)) = first else {
            return Ok(());
        };
        let fault = tape_index(self.tables.faults.len(), "faults")?;
        self.tables.faults.push(msg);
        self.tables.fault_order.push((self.cur_rule, key));
        if floor > Cadence::Const {
            self.push_stream(Instr::Fault { fault }, crate::precision::active(), floor);
            return Ok(());
        }
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

    pub(super) fn end_rule(&mut self) {
        // Record the rule's home-stream chunk (for export insertion).
        let stream = &self.streams[self.home as usize];
        if let Some((idx, c)) = stream.iter().enumerate().next_back() {
            if c.rule == self.cur_rule {
                self.rule_home_chunk[self.cur_rule as usize] = Some(idx);
            }
        }
        debug_assert!(self.rule.scope_frames.is_empty());
        debug_assert!(self.rule.branch_bufs.is_empty());
    }

    pub(super) fn txn(&self) -> RuleTxn {
        RuleTxn {
            tables: self.tables.mark(),
            stream_lens: [
                self.streams[0].len(),
                self.streams[1].len(),
                self.streams[2].len(),
            ],
            hoist_journal: self.hoist_journal.len(),
            forcing_journal: self.forcing_journal.len(),
            tuples_held: self.tuples_held,
        }
    }

    /// Roll back everything the current rule's failed lowering emitted.
    pub(super) fn rollback(&mut self, txn: RuleTxn) {
        self.tables.truncate_to(txn.tables);
        let n_slots = self.tables.slots.len() as SlotId;
        self.known.retain(|s, _| *s < n_slots);
        // A rolled-back slot's id is handed out again: its bounds go with it.
        self.ranges.retain(|s, _| *s < n_slots);
        self.range_defs.retain(|s| *s < n_slots);
        self.call_memo
            .retain(|k, v| v.0 < n_slots && super::calls::call_key_live(k, n_slots));
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
        self.tuples_held = txn.tuples_held;
        self.rule = RuleState::default();
        self.fault.reset_rule();
    }

    /// Forget the forcing loads recorded since `mark`: their instructions were
    /// just discarded.
    pub(super) fn rollback_forcing_loads(&mut self, mark: usize) {
        while self.forcing_journal.len() > mark {
            let ix = self.forcing_journal.pop().expect("journal entry");
            self.forcing_loaded.remove(&ix);
        }
    }

    pub(super) fn sub_txn(&self) -> SubTxn {
        let stream = |s: usize| {
            let st = &self.streams[s];
            (st.len(), st.last().map_or(0, |c| c.instrs.len()))
        };
        SubTxn {
            tables: self.tables.mark(),
            streams: [stream(0), stream(1), stream(2)],
            branch_len: self.rule.branch_bufs.last().map(Vec::len),
            sweep_body: self.rule.sweep.as_ref().map(|sw| sw.body.len()),
            hoist_journal: self.hoist_journal.len(),
            forcing_journal: self.forcing_journal.len(),
            fault_first: self.fault.first.clone(),
            fault_seq: self.fault.seq,
            lazy_faults: self.fault.lazy.len(),
            tuples_held: self.tuples_held,
        }
    }

    /// Run `f` as a trial lowering: when it declines, everything it emitted
    /// is undone and its decline handed back, for the caller to try another
    /// form (and to weigh the decline against that form's, [`after_decline`]).
    pub(super) fn attempt<T>(&mut self, f: impl FnOnce(&mut Self) -> LResult<T>) -> LResult<T> {
        let txn = self.sub_txn();
        let r = f(self);
        if r.is_err() {
            self.sub_rollback(txn);
        }
        r
    }

    /// Undo everything emitted since `txn` was taken, within the current rule.
    pub(super) fn sub_rollback(&mut self, txn: SubTxn) {
        self.tables.truncate_to(txn.tables);
        let n_slots = self.tables.slots.len() as SlotId;
        self.known.retain(|s, _| *s < n_slots);
        // A rolled-back slot's id is handed out again: its bounds go with it.
        self.ranges.retain(|s, _| *s < n_slots);
        self.range_defs.retain(|s| *s < n_slots);
        self.call_memo
            .retain(|k, v| v.0 < n_slots && super::calls::call_key_live(k, n_slots));
        // The attempt's value numbers in the frame it ran in: one naming a
        // rolled-back slot goes (a value it shadowed is simply recomputed).
        if let Some(frame) = self.rule.scope_frames.last_mut() {
            frame.retain_live(n_slots);
        }
        for frame in &mut self.rule.tuple_frames {
            frame.retain_live(n_slots);
        }
        for (s, &(n_chunks, last_len)) in txn.streams.iter().enumerate() {
            let stream = &mut self.streams[s];
            stream.truncate(n_chunks);
            if n_chunks > 0 {
                stream[n_chunks - 1].instrs.truncate(last_len);
            }
        }
        if let (Some(buf), Some(n)) = (self.rule.branch_bufs.last_mut(), txn.branch_len) {
            buf.truncate(n);
        }
        if let (Some(sw), Some(n)) = (self.rule.sweep.as_mut(), txn.sweep_body) {
            sw.body.truncate(n);
            sw.body_slots.retain(|s| *s < n_slots);
        }
        while self.hoist_journal.len() > txn.hoist_journal {
            let key = self.hoist_journal.pop().expect("journal entry");
            self.hoist.remove(&key);
        }
        self.rollback_forcing_loads(txn.forcing_journal);
        self.fault.first = txn.fault_first;
        self.fault.seq = txn.fault_seq;
        self.fault.lazy.truncate(txn.lazy_faults);
        self.tuples_held = txn.tuples_held;
    }

    /// Lower one observed rule; returns the recorded observed value.
    /// The rule's first unclassified read of a range-restricted source, as
    /// its decline.
    pub(super) fn take_tile_violation(&mut self) -> LResult<()> {
        match self.tile_violation.take() {
            Some(reason) => Err(Bail::new(reason)),
            None => Ok(()),
        }
    }

    /// A tile build's array observed: evaluated over its declared ranges
    /// clipped to its need box `lo..=hi` (RFC U3 §4 rule 3), in a slot over
    /// the need box itself with the cells below the declared ranges zero, as
    /// the whole-domain program's padded box holds them.
    pub(super) fn lower_tile_observed(
        &mut self,
        var: &str,
        output_idx_names: &[String],
        output_ranges: &[(i64, i64)],
        need: &TileObserved,
    ) -> LResult<ObsVal> {
        let nd = output_ranges.len();
        if need.lo.len() != nd || need.hi.len() != nd || need.period.len() != nd {
            bail_tape!("tile restriction: observed `{var}`: need box rank != output rank");
        }
        let shape: Vec<usize> = (0..nd)
            .map(|d| (need.hi[d] - need.lo[d] + 1).max(0) as usize)
            .collect();
        if shape.contains(&0) {
            bail_tape!("tile restriction: observed `{var}`: empty need box");
        }
        let axes: Vec<TileAxisDom> = (0..nd)
            .map(|d| TileAxisDom {
                lo: 1,
                hi: output_ranges[d].1,
                period: need.period[d],
                set: output_idx_names[d].clone(),
            })
            .collect();
        let origin: DimI = need.lo.clone();
        let whole = |p: &TilePiece| {
            (0..nd).all(|d| {
                p.dest_lo[d] == 0 && (p.ranges[d].1 - p.ranges[d].0 + 1) as usize == shape[d]
            })
        };
        let out = match need.pieces.as_slice() {
            [] => self.emit_zero_array(&shape, &origin),
            [p] if whole(p) => {
                self.lower_faq(&Contraction::map(output_idx_names, &p.body), &p.ranges)?
            }
            pieces => {
                let mut acc = self.emit_zero_array(&shape, &origin);
                for p in pieces {
                    let v =
                        self.lower_faq(&Contraction::map(output_idx_names, &p.body), &p.ranges)?;
                    let region_ix = self.tables.regions.len() as u32;
                    self.tables.regions.push(RegionSpec {
                        dest_lo: p.dest_lo.iter().copied().collect(),
                        shape: p
                            .ranges
                            .iter()
                            .map(|(lo, hi)| (hi - lo + 1) as usize)
                            .collect(),
                    });
                    let LV::Arr(base) = acc else {
                        unreachable!("a zero fill is an array slot");
                    };
                    let src = self.ensure_slot(&v);
                    let cad = self.lv_cadence(&v).max(self.lv_cadence(&acc));
                    let sec = self.placement(cad);
                    let out = self.new_slot(&shape, &origin, false, sec);
                    self.emit(
                        Instr::Region {
                            base,
                            src: Operand::Slot(src),
                            region: region_ix,
                            out,
                        },
                        sec,
                    );
                    acc = LV::Arr(out);
                }
                acc
            }
        };
        let LV::Arr(slot) = out else {
            bail_tape!("tile restriction: observed `{var}` did not lower to an array");
        };
        self.tile_pending = Some((slot, axes));
        Ok(ObsVal::Taped(out))
    }

    pub(super) fn lower_observed_rule(&mut self, rule: &AlgebraicRule) -> LResult<ObsVal> {
        match rule {
            // CONFORMANCE_SPEC §5.19.2: a recurrence's cells are not
            // independent, so it is never lowered as a box. It is one
            // `Sweep` over its frame, which fusion copies verbatim and whose
            // body runs cell by cell in the normative order.
            AlgebraicRule::Recurrence {
                var,
                output_idx_names,
                output_ranges,
                body,
                axis,
                ..
            } => self.lower_recurrence(var, output_idx_names, output_ranges, body, *axis),
            AlgebraicRule::ArrayLoop {
                var,
                output_idx_names,
                output_ranges,
                ..
            } if self.tile.is_some_and(|t| t.observed.contains_key(var)) => {
                let tile = self.tile.expect("tile build");
                self.lower_tile_observed(var, output_idx_names, output_ranges, &tile.observed[var])
            }
            AlgebraicRule::ArrayLoop {
                output_idx_names,
                output_ranges,
                body,
                ..
            } => {
                // `materialize_observeds_pass` materializes the observed at its
                // PADDED box, `[1, hi]` on every axis: the cells of the ranges
                // hold the body and the cells below a range that starts past 1
                // hold `0.0`.
                let padded_shape: Vec<usize> =
                    output_ranges.iter().map(|(_, hi)| *hi as usize).collect();
                if output_ranges.is_empty() {
                    bail_tape!("observed: rank-0 ArrayLoop");
                }
                if output_ranges.iter().any(|(lo, _)| *lo < 1) {
                    // The oracle clamps a subscript below 1 onto the first
                    // cell, so several cells write one; nothing to mirror.
                    bail_tape!("observed: output range starts below 1");
                }
                let ones = DimI::from_elem(1, padded_shape.len());
                if padded_shape.contains(&0) || output_ranges.iter().any(|(lo, hi)| lo > hi) {
                    // No cell to evaluate: the zeros the oracle materializes.
                    return Ok(ObsVal::Taped(self.emit_zero_array(&padded_shape, &ones)));
                }
                let v = self.lower_faq(&Contraction::map(output_idx_names, body), output_ranges)?;
                if output_ranges.iter().all(|(lo, _)| *lo == 1) {
                    return Ok(ObsVal::Taped(v));
                }
                // The ranges' box written over a zero fill of the padded box.
                let region_ix = self.tables.regions.len() as u32;
                self.tables.regions.push(RegionSpec {
                    dest_lo: output_ranges
                        .iter()
                        .map(|(lo, _)| (*lo - 1) as usize)
                        .collect(),
                    shape: output_ranges
                        .iter()
                        .map(|(lo, hi)| (hi - lo + 1) as usize)
                        .collect(),
                });
                let LV::Arr(base) = self.emit_zero_array(&padded_shape, &ones) else {
                    unreachable!("a zero fill is an array slot");
                };
                let src = self.ensure_slot(&v);
                let sec = self.placement(self.lv_cadence(&v));
                let out = self.new_slot(&padded_shape, &ones, false, sec);
                self.emit(
                    Instr::Region {
                        base,
                        src: Operand::Slot(src),
                        region: region_ix,
                        out,
                    },
                    sec,
                );
                Ok(ObsVal::Taped(LV::Arr(out)))
            }
            AlgebraicRule::Scalar { body, .. } => {
                // The whole-body `eval` mirror: covers scalar algebra, whole-
                // array elementwise algebra, top-level aggregates (incl. the
                // prefix-scan sweep) and makearrays. Readers see materialized
                // arrays at origin 1s. A scalar on a shaped variable fills its
                // declared box, as the interpreter does; so does one whose
                // shape the data bound to its data-fed parameters decides
                // (esm-spec §4.3.4), read from the forcing boxes this build
                // compiles against, as the oracle reads it from the buffer.
                let fill = rule.fill_shape(|n| self.forcing_shapes.get(n).map(|s| s.to_vec()));
                let declared_shape = fill.as_ref();
                let v = match declared_shape {
                    Some(shape) => {
                        self.lower_wholesale_rule(|s| s.lower_wholesale_shaped(body, shape))?
                    }
                    None => self.lower_wholesale_rule(|s| s.lower_wholesale(body))?,
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

    /// Copy an array LV into a slot whose origin is all-1s (the convention
    /// under which readers see a materialized observed). No-op when already.
    pub(super) fn reorigin_to_one(&mut self, v: LV) -> LV {
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

    /// The kernel that folds an array-valued reduction: [`reduce_combine_op`],
    /// or — under [`Self::array_bool_reductions`] — the scalar fold
    /// [`scalar_combine_op`], which is what the pipeline's reference evaluator
    /// runs at each cell of an array-valued `bool_and_or` (a crisp fold, so
    /// the box-wide fold matches it cell for cell).
    pub(super) fn array_combine_op(&self, reduce: ReduceKind, site: &str) -> LResult<BinCode> {
        match reduce_combine_op(reduce) {
            Some(op) => Ok(op),
            None if self.array_bool_reductions => Ok(scalar_combine_op(reduce)),
            None => bail_tape!(
                "{site}: an array-valued bool_and_or reduction (the numeric evaluators reject \
                 it, CONFORMANCE_SPEC §5.6.1)"
            ),
        }
    }

    /// Lower one RHS rule, emitting its `DyWrite`.
    pub(super) fn lower_rhs_rule(&mut self, rule: &RhsRule) -> LResult<()> {
        match rule {
            RhsRule::Scalar { slot, body } | RhsRule::IndexedScalar { slot, body } => {
                let v = self.lower_wholesale_rule(|s| s.lower_wholesale(body))?;
                // The oracle scalarizes: an array-valued body writes the NaN
                // sentinel (`eval(body).as_scalar().unwrap_or(NAN)`).
                let v = if self.lv_box(&v).is_some() {
                    LV::Lit(f64::NAN)
                } else {
                    v
                };
                let s = self.ensure_slot(&v);
                let w = self.tables.dy_writes.len() as u32;
                self.tables.dy_writes.push(DyWrite {
                    slot: s,
                    var: 0,
                    dest_lo: SmallVec::new(),
                    scalar_flat: Some(*slot),
                    scatter: None,
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
                // A constant per-axis shift places the output box as one
                // sub-block of the variable; any other left-hand side writes
                // through a per-cell position table.
                let (dest_lo, scatter) = match lhs_constant_shifts(lhs_idx_exprs, output_idx_names)
                    .and_then(|shifts| subblock_dest(vs, output_ranges, &shifts))
                {
                    Some(dest_lo) => (dest_lo, None),
                    None => (
                        SmallVec::new(),
                        Some(lhs_scatter_positions(
                            vs,
                            output_idx_names,
                            output_ranges,
                            lhs_idx_exprs,
                        )?),
                    ),
                };
                let c = Contraction {
                    idx_names: output_idx_names,
                    body,
                    contract_names,
                    contract_dims,
                    reduce: *reduce,
                    filter: filter.as_deref(),
                };
                let v = self.lower_faq(&c, output_ranges)?;
                let s = self.ensure_slot(&v);
                let var_ix = tape_index(
                    *self
                        .state_ix
                        .get(var_name.as_str())
                        .expect("state var known"),
                    "state variables",
                )?;
                let w = self.tables.dy_writes.len() as u32;
                self.tables.dy_writes.push(DyWrite {
                    slot: s,
                    var: var_ix,
                    dest_lo,
                    scalar_flat: None,
                    scatter,
                });
                self.emit(Instr::DyWrite { write: w }, Cadence::Continuous);
                Ok(())
            }
        }
    }

    /// Names to publish into the runtime observed map: the samples/
    /// observed-trajectory dependency cone (mirroring
    /// `append_scalar_observed_trajectories`'s probe seeds), or every observed
    /// under `export_all`.
    pub(super) fn compute_exports(
        &mut self,
        observed_rules: &[AlgebraicRule],
        // The STRICT compilers, `native` and `xla` (API_SPEC §5.8): export
        // EVERY observed, because under them the build-time hoist, the
        // per-segment seed, the inspection snapshot and the output-node pass
        // are all served from this program rather than by the reference
        // evaluator, and each of them may read an observed the probe cone below
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

        // The samples pass' probe cone: potentially-scalar observeds and
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
                continue;
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
    /// Inserting in rule order publishes each observed before any later rule
    /// runs, which is the order the interpreter's observed map fills in: an
    /// observed can only be read by a LATER rule than the one defining it
    /// (`observed_rules` is dependency-ordered), so the producer's place
    /// precedes every reader's chunk in this stream. It is safe: every stream is
    /// built in nondecreasing rule order (rules are lowered in ordinal order
    /// and [`Self::emit`] appends), so the insertion preserves that order; and
    /// the value being exported is either a literal filled by the instruction
    /// beside it or a slot computed in this or an earlier SECTION, which the
    /// section concatenation in [`Self::finish`] has already run.
    ///
    /// Chunk indices shift on insert, so every `rule_home_chunk` entry at or
    /// after the insertion point **in this stream** is fixed up — entries for
    /// other sections index other streams and are left alone.
    pub(super) fn open_home_chunk(&mut self, rule: u32, home: Cadence) -> usize {
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
    pub(super) fn ensure_slot_at_rule(&mut self, lv: &LV, rule: u32, home: Cadence) -> SlotId {
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

    /// Flatten the chunk streams, run the passes ([`calls::finish_program`]:
    /// fusion, liveness and slab coloring), then finish every function the
    /// program calls in its layout.
    pub(super) fn finish(
        self,
        exports: Vec<(String, SlotId)>,
        fuse: Option<super::super::fuse::SuperopCfg>,
        align_layout: bool,
    ) -> Result<TapeProgram, String> {
        let funcs = std::rc::Rc::clone(&self.funcs);
        // A function is laid out like its caller: a caller with a function
        // that has no axis-reversed form stays row-major.
        let align_layout = align_layout && funcs.borrow().all_reversible();
        let funcs_fault = funcs.borrow().can_fault();
        let mut prog = self.assemble(exports);
        super::calls::finish_program(
            &mut prog,
            super::calls::Layout::Chosen(align_layout),
            fuse,
            &funcs_fault,
        )?;
        prog.funcs = funcs.borrow_mut().finish(prog.col_major, fuse)?;
        Ok(prog)
    }

    /// The lowered program, its chunk streams flattened into sections, before
    /// any pass rewrites it.
    pub(super) fn assemble(mut self, exports: Vec<(String, SlotId)>) -> TapeProgram {
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
        debug_assert_eq!(
            self.tables.faults.len(),
            self.tables.fault_order.len(),
            "`fault_order` is parallel to `faults`"
        );
        TapeProgram {
            instrs,
            precision,
            n_const,
            n_segment,
            n_rhs: 0,
            tables: std::mem::take(&mut self.tables),
            state_vars: std::mem::take(&mut self.state_vars),
            forcings: std::mem::take(&mut self.forcings),
            exports,
            rules: std::mem::take(&mut self.rules),
            slab: SlabLayout::default(),
            provenance,
            params_len: self.param_names.len(),
            fused: Vec::new(),
            lanes: Vec::new(),
            fuse_stats: FuseStats::default(),
            col_major: false,
            prepared: Default::default(),
            funcs: Vec::new(),
            is_function: self.is_function,
            call_batches: Vec::new(),
        }
    }

    pub(crate) fn vn_hits(&self) -> (usize, usize) {
        (self.vn_scope_hits, self.vn_hoist_hits)
    }
}
