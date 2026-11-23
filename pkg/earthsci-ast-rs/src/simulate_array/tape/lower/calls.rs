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
    /// A binding that reads a loop symbol the body binds, compiled into the
    /// instance (its wire text): the body reads it where it reads the
    /// parameter, inside its own loops, as Julia's build does. The names it
    /// reads from the caller are arguments of their own.
    Inline(String),
}

/// The key of one function: the instance, what each parameter is, and the
/// call's box.
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
}

pub(super) type SharedFuncs = Rc<RefCell<FuncTable>>;

impl FuncTable {
    /// Every function program, finished in the layout of the program that
    /// calls them (`col_major`), in id order: a function calls only
    /// functions with smaller ids, which it holds.
    pub(super) fn finish(
        &mut self,
        col_major: bool,
        fuse: Option<super::super::fuse::SuperopCfg>,
    ) -> Result<Vec<Arc<TapeProgram>>, String> {
        let mut done: Vec<Arc<TapeProgram>> = Vec::with_capacity(self.progs.len());
        for mut prog in std::mem::take(&mut self.progs) {
            prog.funcs = done.clone();
            finish_program(&mut prog, Layout::Forced(col_major), fuse)?;
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
/// (fusion), liveness and slab coloring.
pub(super) fn finish_program(
    prog: &mut TapeProgram,
    layout: Layout,
    fuse: Option<super::super::fuse::SuperopCfg>,
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
        if bx.tuple != 0 || !bx.cnames.is_empty() || self.rule.sweep.is_some() {
            bail_tape!(
                "operator reference `{name}`: a call inside a contraction, tuple list or \
                 recurrence body is not compiled yet"
            );
        }
        let Some(r) = crate::operator_refs::reference_node(node) else {
            bail_tape!("operator reference without a name");
        };
        let binders = inst.binders();
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
            let reads = crate::expression::free_variables(b);
            let reads_box = reads.iter().any(|n| bx.syms.contains(n));
            if reads_box || (!binders.is_empty() && reads.iter().any(|n| binders.contains(n))) {
                // A binding that reads a loop symbol, of the call's box or of
                // the body, has no value before the call: it is compiled into
                // the instance (its structure is part of the key) and read
                // where the body reads the parameter. Every other name it
                // reads is an argument of its own, named by position, so two
                // sites that read different arrays the same way share one
                // function.
                let mut caller_names: Vec<&String> = reads
                    .iter()
                    .filter(|n| !binders.contains(*n) && !bx.syms.contains(n))
                    .collect();
                caller_names.sort();
                let mut rename: FxHashMap<String, String> = FxHashMap::default();
                for n in caller_names {
                    let pos = format!("\0arg{}", n_free);
                    n_free += 1;
                    let v = Expr::Variable(n.clone());
                    let lv = if wholesale {
                        self.lower_wholesale(&v)?
                    } else {
                        self.lower_expr(&v, bx)?
                    };
                    cadence = cadence.max(self.lv_cadence(&lv));
                    let kind =
                        self.arg_kind(lv, &mut arrays, &mut scalars, &mut arr_lvs, &mut sc_lvs);
                    params.push((pos.clone(), kind));
                    rename.insert(n.clone(), pos);
                }
                let text = serde_json::to_string(&rename_free(b, &rename)).unwrap_or_default();
                params.push((p.clone(), ArgKind::Inline(text)));
                continue;
            }
            let lv = if wholesale {
                self.lower_wholesale(b)?
            } else {
                self.lower_expr(b, bx)?
            };
            cadence = cadence.max(self.lv_cadence(&lv));
            let kind = self.arg_kind(lv, &mut arrays, &mut scalars, &mut arr_lvs, &mut sc_lvs);
            params.push((p.clone(), kind));
        }
        let key = FuncKey {
            instance: Arc::as_ptr(&inst) as usize,
            wholesale,
            params,
            syms: bx.syms.to_vec(),
            lo: bx.lo.clone(),
            shape: bx.shape.clone(),
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
                        let id = tape_index(t.progs.len(), "functions")?;
                        t.progs.push(prog);
                        t.held.push(Arc::clone(&inst));
                        t.by_key.insert(key, Some((id, res.clone())));
                        (id, res)
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
        let call = tape_index(self.tables.calls.len(), "calls")?;
        self.tables.calls.push(CallSpec {
            func,
            arrays,
            scalars,
        });
        let sec = self.placement(cadence);
        let out = self.new_slot(&res.shape, &res.origin, res.scalar, sec);
        self.emit(Instr::Call { call, out }, sec);
        Ok(if res.scalar { LV::Scalar(out) } else { LV::Arr(out) })
    }

    /// What the function sees of an argument the caller lowered to `lv`,
    /// recording it as an array or scalar argument where it is one.
    fn arg_kind(
        &self,
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
                arrays.push(SrcRef::Slot(s));
                arr_lvs.push(lv);
                ArgKind::Array(shape, origin)
            }
            LV::State(ix) => match self.lv_box(&lv) {
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
        let mut lits: FxHashMap<String, f64> = FxHashMap::default();
        let mut times: HashSet<String> = HashSet::new();
        let mut inline: FxHashMap<String, Expr> = FxHashMap::default();
        for (p, kind) in &key.params {
            match kind {
                ArgKind::Lit(bits) => {
                    lits.insert(p.clone(), f64::from_bits(*bits));
                }
                ArgKind::Time => {
                    times.insert(p.clone());
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
                ArgKind::Inline(text) => {
                    let e: Expr = serde_json::from_str(text)
                        .map_err(|e| Bail::new(format!("operator reference `{name}`: {e}")))?;
                    inline.insert(p.clone(), e);
                }
            }
        }
        let no_forcing = ForcingInputs {
            shapes: FxHashMap::default(),
            unsized_: HashSet::new(),
            discrete: self.discrete_forcing,
        };
        let mut f = TapeBuilder::new(
            &var_shapes,
            &param_names,
            FxHashMap::default(),
            self.const_arrays,
            &no_forcing,
        );
        f.ops = self.ops;
        f.funcs = Rc::clone(&self.funcs);
        f.count_fold = self.count_fold;
        f.is_function = true;
        f.fn_lits = lits;
        f.fn_times = times;
        f.fn_inline = inline;
        f.begin_rule(RuleInfo {
            name: format!("operator {name}"),
            kind: RuleKind::Observed(0),
            cadence: Cadence::Continuous,
        });
        let lv = if key.wholesale {
            f.lower_wholesale_rule(|f| f.lower_wholesale(&inst.body))?
        } else {
            let fbox = LBox::new(&key.syms, bx.lo.clone(), bx.shape.clone());
            f.push_scope();
            let lv = f.lower_expr(&inst.body, &fbox);
            f.pop_scope();
            lv?
        };
        if f.fault.first.is_some() || !f.fault.lazy.is_empty() || f.fault.notes > 0 {
            bail_tape!(
                "operator reference `{name}`: its body can latch a fail-closed fault, which a \
                 called function does not order yet"
            );
        }
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
        Ok(Built::Function(prog, res))
    }
}

/// `e` with each free variable named in `rename` renamed: a name a node of
/// `e` binds is not free below it.
fn rename_free(e: &Expr, rename: &FxHashMap<String, String>) -> Expr {
    match e {
        Expr::Variable(n) => match rename.get(n) {
            Some(r) => Expr::Variable(r.clone()),
            None => e.clone(),
        },
        Expr::Operator(node) => {
            let bound = node.binders(crate::binders::Binders::SCOPE);
            if bound.iter().any(|b| rename.contains_key(*b)) {
                let mut inner = rename.clone();
                for b in bound {
                    inner.remove(b);
                }
                Expr::operator(node.map_children(&mut |c| rename_free(c, &inner)))
            } else {
                Expr::operator(node.map_children(&mut |c| rename_free(c, rename)))
            }
        }
        _ => e.clone(),
    }
}

/// What lowering a body gave.
enum Built {
    Function(TapeProgram, FuncResult),
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
