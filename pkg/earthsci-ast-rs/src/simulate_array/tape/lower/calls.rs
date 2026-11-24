//! Operator references compiled as calls (esm-spec §9.6.4 rule 2).
//!
//! A reference is never expanded. Each definition INSTANCE the program
//! reaches is lowered once, by a builder of its own, into a function program
//! ([`TapeProgram::is_function`]) whose state variables are its array
//! arguments and whose parameters are its scalar arguments; a reference
//! lowers to an [`Instr::Call`] that passes the caller's sources by
//! reference. Two references whose bindings have the same kind, box and
//! literal values call the same function.
//!
//! What the function sees of each parameter is decided by the argument the
//! reference binds to it, never by substituting the binding into the body:
//!
//! * a literal is a literal of the instance (the lowering folds it exactly as
//!   it folds the literal the expansion would have put there);
//! * `t` is the time;
//! * a bare loop symbol of the call's box is that axis of the function's box
//!   (the function is lowered over the call's box with the axis named after
//!   the parameter);
//! * a whole array (a state block, an observed, a constant array, a value the
//!   caller computed over its box) is an array argument read in place: a
//!   state variable of the function with the argument's box;
//! * a scalar value is a scalar argument: a parameter of the function.
//!
//! The lowering of the body is the lowering the expansion got, with each
//! parameter resolving to what it stands for, so the function computes the
//! same values with the same kernels in the same order.

use super::*;
use crate::operator_refs::CallInstance;
use std::cell::RefCell;
use std::rc::Rc;

/// What a reference binds to one parameter, as the function sees it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum ArgKind {
    /// A literal: the bits of the value.
    Lit(u64),
    /// The time `t`.
    Time,
    /// An array argument over a box (shape, origin): the function's state
    /// variable of the next array position.
    Array(DimU, DimI),
    /// A scalar argument: the function's parameter of the next scalar
    /// position.
    Scalar,
    /// An array whose values the build knows (a constant payload): part of
    /// the instance, materialized once in the function's CONST section, so
    /// the lowering reads it as build-time data exactly as the caller would
    /// (a sorted axis, an in-range gather). Box and the payload's identity.
    Known(DimU, DimI, usize),
    /// An argument the function cannot take yet: the call declines.
    Unsupported,
    /// An inline `const` array literal, passed by reference like any array
    /// and read in the function as a constant array (its out-of-range reads
    /// fault as the literal's do). Its box.
    ConstLit(DimU, DimI, bool),
    /// A binding that reads a loop symbol the body binds, compiled into the
    /// instance (its wire text): the body reads it where it reads the
    /// parameter, inside its own loops, as Julia's build does. The names it
    /// reads from the caller are arguments of their own.
    Inline(String),
}

/// The key of one function: the instance, what each parameter is, the
/// call's box, and the precision the body is lowered at.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct FuncKey {
    instance: usize,
    /// Lowered whole-array, as the per-cell `eval` reads a scalar rule's
    /// body ([`TapeBuilder::lower_wholesale`]), rather than over a box.
    wholesale: bool,
    params: Vec<(String, ArgKind)>,
    /// The call's box: its loop symbols (an inlined binding reads them by
    /// name), origin and extent.
    syms: Vec<String>,
    lo: DimI,
    shape: DimU,
    /// The precision in force at the call (esm-spec §11.3.1), which the
    /// body runs at: a call at another precision is another function.
    precision: crate::precision::Precision,
}

/// What a finished function returns, in the caller's terms.
#[derive(Clone, Debug)]
pub(super) struct FuncResult {
    pub shape: DimU,
    pub origin: DimI,
    pub scalar: bool,
}

/// The functions one build compiles, shared by the program's builder and
/// every function builder: assembled function programs (laid out, fused and
/// colored once the caller's layout is known, [`FuncTable::finish`]) by key.
#[derive(Default)]
pub(super) struct FuncTable {
    by_key: FxHashMap<FuncKey, Option<(u32, FuncResult)>>,
    progs: Vec<TapeProgram>,
    /// The instances lowered, held so the address keying them is not reused.
    held: Vec<Arc<CallInstance>>,
    /// Build-time payloads passed as [`ArgKind::Known`], by address (held, so
    /// the address is not reused).
    known_vals: FxHashMap<usize, Arc<Vec<f64>>>,
    /// Each function's program text ([`fingerprint`]) and the precision it
    /// runs at: two instances that compile to the same program at one
    /// precision are one function. A body whose instructions carry no
    /// precision of their own runs at its caller's, so the program text
    /// alone does not tell two precisions apart.
    by_program: FxHashMap<(u128, crate::precision::Precision), (u32, FuncResult)>,
}

/// The whole text of an assembled function program: its instructions, its
/// tables, its state variables, its parameter count, its precision and its
/// result. Two programs with the same text compute the same function of
/// their arguments.
fn fingerprint(prog: &TapeProgram) -> u128 {
    // Hashed as it is written: the text is never held.
    struct H(
        std::collections::hash_map::DefaultHasher,
        std::collections::hash_map::DefaultHasher,
    );
    impl std::fmt::Write for H {
        fn write_str(&mut self, s: &str) -> std::fmt::Result {
            use std::hash::Hasher;
            self.0.write(s.as_bytes());
            self.1.write_u8(0xa5);
            self.1.write(s.as_bytes());
            Ok(())
        }
    }
    use std::fmt::Write as _;
    use std::hash::Hasher;
    let mut h = H(Default::default(), Default::default());
    let t = &prog.tables;
    let _ = write!(
        h,
        "{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}",
        prog.instrs,
        t.slots,
        t.plans,
        t.regions,
        t.assemblies,
        t.index_gathers,
        t.gather_tables,
        t.seg_tables,
        t.faults,
        t.fault_order,
        t.fault_scans,
        t.sweeps,
        t.scalar_reads,
        t.data_gathers,
        t.dy_writes,
        t.calls,
    );
    // Constant payloads by their bits (formatting them is the slow part).
    for d in &t.const_data {
        let _ = write!(h, "|{:?}:", d.shape);
        for v in d.values.iter() {
            h.0.write_u64(v.to_bits());
            h.1.write_u64(v.to_bits() ^ 0x5bd1_e995);
        }
    }
    let _ = write!(
        h,
        "|{:?}|{}|{:?}|{:?}|{}|{}",
        prog.state_vars
            .iter()
            .map(|sv| (&sv.shape, &sv.origin))
            .collect::<Vec<_>>(),
        prog.params_len,
        prog.precision,
        prog.exports.iter().map(|(_, s)| *s).collect::<Vec<_>>(),
        prog.n_const,
        prog.n_segment
    );
    (u128::from(h.0.finish()) << 64) | u128::from(h.1.finish())
}

pub(super) type SharedFuncs = Rc<RefCell<FuncTable>>;

/// A call's identity: its function, its array arguments' sources, its
/// scalar arguments' operands, and the precision it runs at (the one in
/// force where it is emitted).
pub(super) type CallKey = (
    u32,
    Vec<SrcRef>,
    Vec<OperandKey>,
    crate::precision::Precision,
);

/// Whether every slot `key` names (its arguments) is below `n_slots`: a
/// rolled-back slot's id is handed out again, so a call naming one goes.
pub(super) fn call_key_live(key: &CallKey, n_slots: SlotId) -> bool {
    key.1
        .iter()
        .all(|a| !matches!(a, SrcRef::Slot(s) if *s >= n_slots))
        && key
            .2
            .iter()
            .all(|o| !matches!(o, OperandKey::Slot(s) if *s >= n_slots))
}

impl FuncTable {
    /// Per function compiled so far: whether running it can latch a fault.
    pub(super) fn can_fault(&self) -> Vec<bool> {
        funcs_can_fault(&self.progs)
    }

    /// Whether every function compiled so far can be laid out axis-reversed,
    /// which a column-major caller needs of each of them.
    pub(super) fn all_reversible(&self) -> bool {
        self.progs.iter().all(super::super::layout::reversible)
    }

    /// Every function program, finished in the layout of the program that
    /// calls them (`col_major`), in id order: a function calls only
    /// functions with smaller ids, which it holds.
    pub(super) fn finish(
        &mut self,
        col_major: bool,
        fuse: Option<super::super::fuse::SuperopCfg>,
    ) -> Result<Vec<Arc<TapeProgram>>, String> {
        let mut done: Vec<Arc<TapeProgram>> = Vec::with_capacity(self.progs.len());
        let mut faults: Vec<bool> = Vec::with_capacity(self.progs.len());
        for mut prog in std::mem::take(&mut self.progs) {
            prog.funcs = done.clone();
            finish_program(&mut prog, Layout::Forced(col_major), fuse, &faults)?;
            faults.push(prog.can_fault_with(&faults));
            done.push(Arc::new(prog));
        }
        Ok(done)
    }
}

/// How a program is laid out: chosen for its own state, or the layout of the
/// program that calls it.
pub(super) enum Layout {
    Chosen(bool),
    Forced(bool),
}

/// The passes after lowering: constant dedup, scan rewrites, the layout,
/// (fusion), call batching, liveness and slab coloring. `funcs_fault` says
/// per function the program calls whether it can latch a fault.
pub(super) fn finish_program(
    prog: &mut TapeProgram,
    layout: Layout,
    fuse: Option<super::super::fuse::SuperopCfg>,
    funcs_fault: &[bool],
) -> Result<(), String> {
    super::super::dedup::dedup_const(prog);
    super::super::scan_shift::rewrite_scan_makearray_reads(prog);
    match layout {
        Layout::Chosen(true) => super::super::layout::align_state_layout(prog),
        Layout::Chosen(false) | Layout::Forced(false) => {}
        Layout::Forced(true) => {
            if !super::super::layout::reverse_forced(prog) {
                return Err(
                    "an operator definition's body cannot be laid out as its caller's \
                     column-major program"
                        .to_string(),
                );
            }
        }
    }
    if let Some(cfg) = fuse {
        // A function's state variables are the running call's arguments, at
        // addresses only the call knows: the lane programs, which address the
        // state by flat offset, are not made for one.
        if !prog.is_function {
            super::super::reroll::reroll_program(prog);
        }
        super::super::prune::split_output_only(prog);
        super::super::sink::sink_const_broadcasts(prog);
        super::super::fuse::fuse_program(prog, cfg);
        super::super::prune::split_output_only(prog);
    } else {
        prog.n_rhs = prog.section_range(Cadence::Continuous).len() as u32;
    }
    if prog.is_function {
        // A function's result is its export: every instruction runs.
        prog.n_rhs = prog.section_range(Cadence::Continuous).len() as u32;
    }
    super::super::batch::batch_calls(prog, funcs_fault);
    super::super::slab::color_slab(prog);
    Ok(())
}

impl<'m> TapeBuilder<'m> {
    /// Lower the reference `node` over `bx` as a call of its instance's
    /// function.
    pub(super) fn lower_call(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        self.lower_call_in(node, Some(bx))
    }

    /// Lower the reference `node` in a whole-array body
    /// ([`Self::lower_wholesale`]) as a call of its instance's function,
    /// whose body is lowered whole-array too.
    pub(super) fn lower_call_wholesale(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        self.lower_call_in(node, None)
    }

    fn lower_call_in(&mut self, node: &Arc<ExpressionNode>, bx: Option<&LBox>) -> LResult<LV> {
        let empty_syms: [String; 0] = [];
        let plain = LBox::new(&empty_syms, DimI::new(), DimU::new());
        let wholesale = bx.is_none();
        let bx = bx.unwrap_or(&plain);
        let name = node.name.as_deref().unwrap_or("");
        let Some(ops) = self.ops else {
            bail_tape!("operator reference `{name}`: this build has no operator registry");
        };
        let inst = ops
            .instance_of_node(node)
            .map_err(|e| Bail::new(e.to_string()))?;
        if bx.tuple != 0 || !bx.cnames.is_empty() {
            bail_tape!(
                "operator reference `{name}`: a call inside an unrolled contraction or a tuple \
                 list is not compiled yet"
            );
        }
        let Some(r) = crate::operator_refs::reference_node(node) else {
            bail_tape!("operator reference without a name");
        };
        // The loop symbols the expansion would bind around a binding: those
        // the instance body binds and those of the bodies it reaches.
        let mut binders: HashSet<String> = inst.binders().clone();
        binders.extend(
            ops.registry()
                .captured_symbols(&inst.definition.name)
                .iter()
                .cloned(),
        );
        let binders = &binders;
        let mut params: Vec<(String, ArgKind)> = Vec::new();
        let mut arrays: Vec<SrcRef> = Vec::new();
        let mut scalars: Vec<Operand> = Vec::new();
        // The caller's value of each array and each scalar argument.
        let mut arr_lvs: Vec<LV> = Vec::new();
        let mut sc_lvs: Vec<LV> = Vec::new();
        let mut cadence = Cadence::Const;
        let mut n_free = 0usize;
        for p in &inst.definition.params {
            if inst.instance_params.iter().any(|ip| ip == p) {
                continue;
            }
            let Some(b) = r.binding(p) else { continue };
            // A parameter the body never reads: its expansion never evaluates
            // the binding, and neither does the call.
            if inst.definition.param_roles().get(p).is_none() {
                continue;
            }
            // An inline `const` is build-time data the lowering reads (a
            // sorted axis, a lookup table): it is compiled into the instance,
            // as a literal is.
            if let Expr::Operator(c) = b
                && c.op == "const"
            {
                match eval_const(c) {
                    // An empty array has no slot form: compiled into the
                    // instance, as a literal is.
                    Value::Array(a) if a.is_empty() => {
                        let text = serde_json::to_string(b).unwrap_or_default();
                        params.push((p.clone(), ArgKind::Inline(text)));
                    }
                    Value::Array(a) => {
                        let lv = self.const_literal_array(c, &a, None)?;
                        let LV::Arr(slot) = lv else {
                            bail_tape!("operator reference `{name}`: a constant array argument");
                        };
                        let (shape, origin) = self.lv_box(&lv).expect("an array slot has a box");
                        arrays.push(SrcRef::Slot(slot));
                        arr_lvs.push(lv);
                        let vals: Vec<f64> = a.iter().copied().collect();
                        let sorted = non_decreasing(vals.len(), |j| vals[j]);
                        params.push((p.clone(), ArgKind::ConstLit(shape, origin, sorted)));
                    }
                    Value::Scalar(x) => {
                        params.push((
                            p.clone(),
                            ArgKind::Lit(crate::precision::round(x).to_bits()),
                        ));
                    }
                }
                continue;
            }
            // The names the binding reads free: a loop symbol a node of the
            // binding binds is its own.
            let reads = crate::binders::free_names(b, crate::binders::Binders::SCOPE);
            // A tuple list's symbols are columns of the list, not axes: a
            // binding that reads one is an array argument over the list.
            let reads_box = bx.tuple == 0 && reads.iter().any(|n| bx.syms.contains(n));
            // A constant array is build-time data the lowering reads by its
            // name (its values, its boundary policy): a binding that reads
            // one is compiled into the instance under that name.
            let reads_const = reads.iter().any(|n| self.const_arrays.is_const(n));
            if reads_box
                || reads_const
                || (!binders.is_empty() && reads.iter().any(|n| binders.contains(n)))
            {
                // A binding that reads a loop symbol, of the call's box or of
                // the body, has no value before the call: it is compiled into
                // the instance (its structure is part of the key) and read
                // where the body reads the parameter. Every other name it
                // reads is an argument of its own, named by position, so two
                // sites that read different arrays the same way share one
                // function.
                let mut caller_names: Vec<&String> = reads
                    .iter()
                    .filter(|n| !binders.contains(*n) && (bx.tuple != 0 || !bx.syms.contains(n)))
                    .collect();
                caller_names.sort();
                let mut rename: FxHashMap<String, String> = FxHashMap::default();
                for n in caller_names {
                    // A constant array keeps its name (the function reads it
                    // as the caller does); any other name is positional.
                    let pos = if self.const_arrays.is_const(n) {
                        n.clone()
                    } else {
                        n_free += 1;
                        format!("\0arg{}", n_free - 1)
                    };
                    if params.iter().any(|(q, _)| *q == pos) {
                        continue;
                    }
                    if let Some(kind) = self.known_name_arg(n) {
                        params.push((pos.clone(), kind));
                        rename.insert(n.clone(), pos);
                        continue;
                    }
                    let v = Expr::Variable(n.clone());
                    let lv = if wholesale {
                        self.lower_wholesale(&v)?
                    } else {
                        self.lower_expr(&v, bx)?
                    };
                    cadence = cadence.max(self.lv_cadence(&lv));
                    let kind =
                        self.arg_kind(lv, &mut arrays, &mut scalars, &mut arr_lvs, &mut sc_lvs);
                    if kind == ArgKind::Unsupported {
                        bail_tape!(
                            "operator reference `{name}`: `{n}` is an array over a box that does \
                             not start at 1, which a called function does not take yet"
                        );
                    }
                    params.push((pos.clone(), kind));
                    rename.insert(n.clone(), pos);
                }
                let renamed =
                    crate::binders::rename_free_names(b, crate::binders::Binders::SCOPE, &|n| {
                        rename.get(n).cloned()
                    });
                let text = serde_json::to_string(&renamed).unwrap_or_default();
                params.push((p.clone(), ArgKind::Inline(text)));
                continue;
            }
            if let Expr::Variable(n) = b
                && let Some(kind) = self.known_name_arg(n)
            {
                params.push((p.clone(), kind));
                continue;
            }
            let lv = if wholesale {
                self.lower_wholesale(b)
            } else {
                self.lower_expr(b, bx)
            }
            .map_err(|e| {
                Bail::new(format!(
                    "operator reference `{name}`, binding of `{p}` (box {:?}{}): {}",
                    bx.syms,
                    if wholesale { ", whole-array" } else { "" },
                    e.reason
                ))
            })?;
            cadence = cadence.max(self.lv_cadence(&lv));
            let kind = self.arg_kind(lv, &mut arrays, &mut scalars, &mut arr_lvs, &mut sc_lvs);
            if kind == ArgKind::Unsupported {
                bail_tape!(
                    "operator reference `{name}`: the binding of `{p}` is an array over a box \
                     that does not start at 1, which a called function does not take yet"
                );
            }
            params.push((p.clone(), kind));
        }
        // An instance parameter's value is spelled into the instance body
        // (esm-spec §9.6.4 rule 3); a name of the caller that it spells and
        // the body also reads as a variable is an argument under that name.
        {
            let mut free: Vec<String> =
                crate::binders::free_names(&inst.body, crate::binders::Binders::SCOPE)
                    .into_iter()
                    .filter(|n| {
                        n != "t"
                            && !n.starts_with('\0')
                            && !inst.definition.params.iter().any(|p| p == n)
                            && !params.iter().any(|(q, _)| q == n)
                    })
                    .collect();
            free.sort();
            // The key columns and envelope factors of a `join` in the body
            // name build-time data as strings: each is passed as data.
            let mut join_names: Vec<String> = Vec::new();
            collect_join_names(&inst.body, &mut join_names);
            join_names.sort();
            join_names.dedup();
            for n in join_names {
                if free.contains(&n) || params.iter().any(|(q, _)| *q == n) {
                    continue;
                }
                if let Some(kind) = self.known_name_arg(&n) {
                    params.push((n, kind));
                }
            }
            for n in free {
                if let Some(kind) = self.known_name_arg(&n) {
                    params.push((n, kind));
                    continue;
                }
                let v = Expr::Variable(n.clone());
                let lv = if wholesale {
                    self.lower_wholesale(&v)?
                } else {
                    self.lower_expr(&v, bx)?
                };
                cadence = cadence.max(self.lv_cadence(&lv));
                let kind = self.arg_kind(lv, &mut arrays, &mut scalars, &mut arr_lvs, &mut sc_lvs);
                if kind == ArgKind::Unsupported {
                    bail_tape!(
                        "operator reference `{name}`: `{n}` is an array over a box that does not \
                         start at 1, which a called function does not take yet"
                    );
                }
                params.push((n, kind));
            }
        }
        let key = FuncKey {
            instance: Arc::as_ptr(&inst) as usize,
            wholesale,
            params,
            syms: bx.syms.to_vec(),
            lo: bx.lo.clone(),
            shape: bx.shape.clone(),
            precision: crate::precision::active(),
        };
        let funcs = Rc::clone(&self.funcs);
        let known = funcs.borrow().by_key.get(&key).cloned();
        let (func, res) = match known {
            Some(Some(f)) => f,
            Some(None) => bail_tape!(
                "operator reference `{name}`: its definition reaches itself (esm-spec §9.7.3)"
            ),
            None => {
                funcs.borrow_mut().by_key.insert(key.clone(), None);
                let built = self.build_function(&inst, &key, bx);
                let mut t = funcs.borrow_mut();
                match built {
                    Ok(Built::Function(prog, res)) => {
                        let text = (fingerprint(&prog), key.precision);
                        t.held.push(Arc::clone(&inst));
                        if let Some(same) = t.by_program.get(&text).cloned() {
                            t.by_key.insert(key, Some(same.clone()));
                            same
                        } else {
                            let id = tape_index(t.progs.len(), "functions")?;
                            t.progs.push(*prog);
                            t.by_program.insert(text, (id, res.clone()));
                            t.by_key.insert(key, Some((id, res.clone())));
                            (id, res)
                        }
                    }
                    Ok(Built::Value(v)) => {
                        // No instruction: the body is a literal, the time, or
                        // one of its arguments returned whole.
                        t.by_key.remove(&key);
                        drop(t);
                        return Ok(match v {
                            Passthrough::Lit(x) => LV::Lit(x),
                            Passthrough::Time => LV::Time,
                            Passthrough::Array(k) => arr_lvs[k].clone(),
                            Passthrough::Scalar(k) => sc_lvs[k].clone(),
                        });
                    }
                    Err(b) => {
                        t.by_key.remove(&key);
                        return Err(b);
                    }
                }
            }
        };
        // The same function over the same arguments (by identity: the same
        // source slots and views, the same scalar operands) at the same
        // precision computes the same values: a call computed
        // unconditionally before is read instead.
        let key: CallKey = (
            func,
            arrays.clone(),
            scalars.iter().map(Operand::key).collect(),
            crate::precision::active(),
        );
        if let Some(&(out, scalar)) = self.call_memo.get(&key) {
            return Ok(if scalar {
                LV::Scalar(out)
            } else {
                LV::Arr(out)
            });
        }
        let call = tape_index(self.tables.calls.len(), "calls")?;
        self.tables.calls.push(CallSpec {
            func,
            arrays,
            scalars,
        });
        let sec = self.placement(cadence);
        let out = self.new_slot(&res.shape, &res.origin, res.scalar, sec);
        self.emit(Instr::Call { call, out }, sec);
        // Only a call every later read is sure to follow: not one inside a
        // conditional branch or a recurrence body.
        if !self.in_branch() && self.rule.sweep.is_none() {
            self.call_memo.insert(key, (out, res.scalar));
        }
        Ok(if res.scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    /// A caller name whose value the build knows (a constant observed it can
    /// fold, a known payload): the instance takes it as build-time data.
    fn known_name_arg(&mut self, n: &str) -> Option<ArgKind> {
        let (shape, vals) = self.known_named(n)?;
        if shape.is_empty() {
            return None;
        }
        let id = Arc::as_ptr(&vals) as usize;
        self.funcs.borrow_mut().known_vals.insert(id, vals);
        let origin: DimI = shape.iter().map(|_| 1).collect();
        Some(ArgKind::Known(shape, origin, id))
    }

    /// What the function sees of an argument the caller lowered to `lv`,
    /// recording it as an array or scalar argument where it is one.
    fn arg_kind(
        &mut self,
        lv: LV,
        arrays: &mut Vec<SrcRef>,
        scalars: &mut Vec<Operand>,
        arr_lvs: &mut Vec<LV>,
        sc_lvs: &mut Vec<LV>,
    ) -> ArgKind {
        match lv {
            LV::Lit(x) => ArgKind::Lit(x.to_bits()),
            LV::Time => ArgKind::Time,
            LV::Param(i) => {
                scalars.push(Operand::Param(i));
                sc_lvs.push(lv);
                ArgKind::Scalar
            }
            LV::Scalar(s) => {
                scalars.push(Operand::Slot(s));
                sc_lvs.push(lv);
                ArgKind::Scalar
            }
            LV::Arr(s) => {
                let (shape, origin) = self.lv_box(&lv).expect("an array slot has a box");
                if origin.iter().any(|&o| o != 1) {
                    // A function's state variable is a whole array from 1;
                    // a value over a box that starts elsewhere has no
                    // argument form yet.
                    return ArgKind::Unsupported;
                }
                // A payload the build knows is passed by reference like any
                // array: the instance is not specialized on its values.
                arrays.push(SrcRef::Slot(s));
                arr_lvs.push(lv);
                ArgKind::Array(shape, origin)
            }
            LV::State(ix) => match self.lv_box(&lv) {
                Some((_, origin)) if origin.iter().any(|&o| o != 1) => ArgKind::Unsupported,
                Some((shape, origin)) => {
                    arrays.push(SrcRef::State(ix));
                    arr_lvs.push(lv);
                    ArgKind::Array(shape, origin)
                }
                None => {
                    scalars.push(Operand::State(ix));
                    sc_lvs.push(lv);
                    ArgKind::Scalar
                }
            },
        }
    }

    /// Lower `inst`'s body once, for the arguments `key` describes, into a
    /// function program.
    fn build_function(&self, inst: &Arc<CallInstance>, key: &FuncKey, bx: &LBox) -> LResult<Built> {
        let name = &inst.definition.name;
        let mut var_shapes: IndexMap<String, VarShape> = IndexMap::new();
        let mut param_names: Vec<String> = Vec::new();
        // What the instance is compiled with in place of a parameter: a
        // literal, the time, or a binding that reads a loop symbol. The
        // instance body is specialized with them once, here; every other
        // parameter is an argument of the call.
        let mut fixed: FxHashMap<String, Expr> = FxHashMap::default();
        let mut known: Vec<(String, DimU, DimI, Arc<Vec<f64>>)> = Vec::new();
        let mut const_aliases: Vec<String> = Vec::new();
        let mut sorted_names: Vec<String> = Vec::new();
        for (p0, kind) in &key.params {
            // A runtime argument named like the time would read as the time
            // (the lowering resolves `t` first): it is renamed in the body.
            let renamed;
            let p = if p0 == "t"
                && matches!(
                    kind,
                    ArgKind::Array(..) | ArgKind::Scalar | ArgKind::Known(..)
                ) {
                renamed = "\0param_t".to_string();
                fixed.insert(p0.clone(), Expr::Variable(renamed.clone()));
                &renamed
            } else {
                p0
            };
            match kind {
                ArgKind::Lit(bits) => {
                    fixed.insert(p.clone(), Expr::Number(f64::from_bits(*bits)));
                }
                ArgKind::Time => {
                    fixed.insert(p.clone(), Expr::Variable("t".to_string()));
                }
                ArgKind::Array(shape, origin) => {
                    var_shapes.insert(
                        p.clone(),
                        VarShape {
                            shape: shape.to_vec(),
                            origin: origin.to_vec(),
                            flat_offset: 0,
                        },
                    );
                }
                ArgKind::Scalar => param_names.push(p.clone()),
                ArgKind::Unsupported => unreachable!("declined at the call"),
                ArgKind::ConstLit(shape, origin, sorted) => {
                    if *sorted {
                        sorted_names.push(p.clone());
                    }
                    var_shapes.insert(
                        p.clone(),
                        VarShape {
                            shape: shape.to_vec(),
                            origin: origin.to_vec(),
                            flat_offset: 0,
                        },
                    );
                    const_aliases.push(p.clone());
                }
                ArgKind::Known(shape, origin, id) => {
                    let vals = Arc::clone(&self.funcs.borrow().known_vals[id]);
                    known.push((p.clone(), shape.clone(), origin.clone(), vals));
                }
                ArgKind::Inline(text) => {
                    let e: Expr = serde_json::from_str(text)
                        .map_err(|e| Bail::new(format!("operator reference `{name}`: {e}")))?;
                    fixed.insert(p.clone(), e);
                }
            }
        }
        let no_forcing = ForcingInputs {
            shapes: FxHashMap::default(),
            unsized_: HashSet::new(),
            discrete: self.discrete_forcing,
        };
        let scope;
        let const_scope: &ConstArrayScope = if const_aliases.is_empty() {
            self.const_arrays
        } else {
            let mut sc = self.const_arrays.clone();
            for p in &const_aliases {
                sc = sc.with_alias(p);
            }
            scope = sc;
            &scope
        };
        let mut f = TapeBuilder::new(
            &var_shapes,
            &param_names,
            FxHashMap::default(),
            const_scope,
            &no_forcing,
        );
        f.ops = self.ops;
        for n in &sorted_names {
            if let Some(&ix) = f.state_ix.get(n.as_str()) {
                f.sorted_states.insert(ix as u32);
            }
        }
        f.funcs = Rc::clone(&self.funcs);
        f.count_fold = self.count_fold;
        f.is_function = true;
        // Rebuilt under the interner, so a subtree the body repeats is one
        // node and value numbering shares its lowering, as it shares the
        // repeated subtrees of a loaded expression.
        // A binding compiled into the instance may read an argument that is
        // itself a literal or the time: those are substituted into it first.
        let plain: FxHashMap<String, Expr> = fixed
            .iter()
            .filter(|(p, _)| {
                key.params
                    .iter()
                    .any(|(q, k)| q == *p && matches!(k, ArgKind::Lit(_) | ArgKind::Time))
            })
            .map(|(p, e)| (p.clone(), e.clone()))
            .collect();
        if !plain.is_empty() {
            for (p, e) in fixed.iter_mut() {
                if !plain.contains_key(p) {
                    *e = specialize(e, &plain);
                }
            }
        }
        let body = {
            let _intern = crate::intern::InternScope::new();
            specialize(&inst.body, &fixed)
        };
        // Held so the address value numbering keys its nodes by stays its.
        f.held_exprs.push(body.clone());
        f.begin_rule(RuleInfo {
            name: format!("operator {name}"),
            kind: RuleKind::Observed(0),
            cadence: Cadence::Continuous,
        });
        for (p, shape, origin, vals) in known {
            let slot = f.emit_const_data(&shape, &origin, vals, false)?;
            f.obs_defined.insert(p, ObsVal::Taped(LV::Arr(slot)));
        }

        let lv = if key.wholesale {
            f.lower_wholesale_rule(|f| f.lower_wholesale(&body))?
        } else {
            let fbox = LBox::new(&key.syms, bx.lo.clone(), bx.shape.clone());
            f.push_scope();
            let lv = f.lower_expr(&body, &fbox);
            f.pop_scope();
            lv?
        };
        // A fail-closed fault the body can latch is emitted in the function
        // (its `Fault` / `FaultScan`), and latches when a call runs it.
        f.flush_rule_fault()?;
        f.end_rule();
        let state_count = var_shapes.len();
        let result = match lv {
            LV::Lit(x) => return Ok(Built::Value(Passthrough::Lit(x))),
            LV::Time => return Ok(Built::Value(Passthrough::Time)),
            LV::State(k) if (k as usize) < state_count => {
                return Ok(Built::Value(Passthrough::Array(k as usize)));
            }
            LV::Param(k) => return Ok(Built::Value(Passthrough::Scalar(k as usize))),
            LV::State(_) => bail_tape!("operator reference `{name}`: an unexpected state read"),
            LV::Scalar(s) | LV::Arr(s) => s,
        };
        let d = &f.tables.slots[result as usize];
        let res = FuncResult {
            shape: d.shape.clone(),
            origin: d.origin.clone(),
            scalar: d.scalar,
        };
        let export = Instr::Export {
            slot: result,
            export: 0,
        };
        f.emit(export, Cadence::Continuous);
        let mut prog = f.assemble(vec![("result".to_string(), result)]);
        prog.is_function = true;
        Ok(Built::Function(Box::new(prog), res))
    }
}

/// Every name a `join` clause in `e` spells (key columns, overlap envelope
/// factors).
fn collect_join_names(e: &Expr, out: &mut Vec<String>) {
    if let Expr::Operator(node) = e {
        for clause in node.join.iter().flatten() {
            out.extend(clause.on.iter().flatten().cloned());
            if let Some(ov) = &clause.overlap {
                out.extend(ov.src_env.iter().chain(ov.tgt_env.iter()).cloned());
            }
        }
        node.for_each_child(&mut |c| collect_join_names(c, out));
    }
}

/// `body` with each parameter of `fixed` that it reads replaced by what the
/// instance fixes it to, where a node of `body` does not rebind the name.
fn specialize(body: &Expr, fixed: &FxHashMap<String, Expr>) -> Expr {
    match body {
        Expr::Variable(n) => fixed.get(n).cloned().unwrap_or_else(|| body.clone()),
        Expr::Operator(node) => {
            let bound = node.binders(crate::binders::Binders::SCOPE);
            if bound.iter().any(|b| fixed.contains_key(*b)) {
                let mut inner = fixed.clone();
                for b in bound {
                    inner.remove(b);
                }
                Expr::operator(node.map_children(&mut |c| specialize(c, &inner)))
            } else {
                Expr::operator(node.map_children(&mut |c| specialize(c, fixed)))
            }
        }
        _ => body.clone(),
    }
}

/// What lowering a body gave.
enum Built {
    Function(Box<TapeProgram>, FuncResult),
    Value(Passthrough),
}

/// A body whose value needs no instruction.
#[derive(Clone, Copy)]
enum Passthrough {
    Lit(f64),
    Time,
    /// The k-th array argument.
    Array(usize),
    /// The k-th scalar argument.
    Scalar(usize),
}
