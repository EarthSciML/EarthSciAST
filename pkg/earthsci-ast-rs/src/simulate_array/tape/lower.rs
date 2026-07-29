//! Lowering: compile the post-CSE expression graph of a model's observed +
//! RHS rules into a flat [`TapeProgram`].
//!
//! The load-bearing principle: **compile the vectorized overlay's own
//! decision procedures, don't invent new semantics.** Every classification
//! this pass performs is the overlay's own `pub(super)` classifier
//! (`classify_axis_role`, `parse_wrap_axis_any`, `lhs_constant_shifts`,
//! `subblock_dest`, `vec_op_code`, …), and every construct `eval_vec_op`
//! would bail on becomes a *fallback rule* carrying the bail reason — so a
//! rule is taped exactly when the overlay vectorizes it today.
//!
//! ## Value numbering
//!
//! The runtime CSE overlay ([`super::super::cse`]) memoizes per `(scope,
//! structural class)`, with a fresh scope per output box (each arrayop entry,
//! each contraction tuple, each makearray region) — and hoists box-pure
//! subtrees into a persistent store keyed by `(box signature, class)`. The
//! build-time equivalent here:
//!
//! * scope-local numbering keyed by the interned node's `Arc` pointer
//!   (structural identity IS pointer identity for interned subtrees; the few
//!   address-unique nodes — `value`/`output`/`join` carriers, which the
//!   interner refuses — merely under-share, which recomputes the same value),
//!   consulted in the INNERMOST open scope only, mirroring the runtime memo's
//!   current-scope stamp;
//! * a cross-rule hoist map keyed by `(owned box key, node pointer)` for
//!   values whose operand cadence is ≤ SEGMENT — the structural analogue of
//!   the ess-lih persistent store (same box + same subtree + constant-tier
//!   leaves ⇒ same value for the whole solve/segment).
//!
//! Both reuse paths substitute a slot for a recomputation of the *identical*
//! value, so availability differences from the runtime memo (which is
//! dynamic) cannot change `dy`. Values defined inside a [`Instr::JmpIfZero`]
//! branch never escape it (the branch may not execute), enforced with an
//! insertion journal rolled back at branch exit.

use super::super::driver::{
    dependency_cone, expr_blocks_output_pruning, observed_rule_is_array_valued,
};
use super::super::*;
use super::ir::*;
use crate::types::ExpressionNode;
use rustc_hash::FxHashMap;
use std::collections::HashSet;
use std::sync::Arc;

// ---------------------------------------------------------------------------
// Bail (fallback) plumbing.
// ---------------------------------------------------------------------------

/// Why a rule could not be lowered. Carries the DEEPEST bail site, mirroring
/// the overlay's `note_bail` convention (the first log entry is the actual
/// unsupported construct).
#[derive(Debug)]
pub(crate) struct Bail {
    pub reason: String,
}

macro_rules! bail_tape {
    ($($t:tt)*) => {
        return Err(Bail { reason: format!($($t)*) })
    };
}

type LResult<T> = Result<T, Bail>;

// ---------------------------------------------------------------------------
// Lowering-time values.
// ---------------------------------------------------------------------------

/// A lowering-time value: what the overlay's `VecValue` is at runtime, made
/// symbolic. Scalar kinds are `Lit`/`Param`/`Time`/`Scalar` (a scalar slot)
/// plus 0-d `StateView`/`ObsView`; array kinds carry a box (shape + origin).
#[derive(Clone, Debug)]
enum LV {
    Lit(f64),
    Param(u16),
    Time,
    /// A scalar slot.
    Scalar(SlotId),
    /// An array slot (box in the slot desc).
    Arr(SlotId),
    /// Whole persistent state array `state_vars[ix]` (origin all-1s; 0-d ⇒
    /// scalar semantics) — the zero-copy `VecValue::View` analogue.
    State(u16),
    /// Whole observed array resolved by name at run time (`obs_reads[ix]`),
    /// with its statically known shape (empty ⇒ 0-d scalar semantics).
    Obs {
        ix: u16,
        shape: DimU,
        tier: Cadence,
    },
}

/// The lowering-time output box (the `VecBox` analogue with owned lo/shape).
struct LBox<'a> {
    syms: &'a [String],
    lo: DimI,
    shape: DimU,
    cnames: &'a [String],
    cvals: SmallVec<[i64; 4]>,
}

impl<'a> LBox<'a> {
    fn as_vecbox(&self) -> VecBox<'_> {
        VecBox {
            syms: self.syms,
            lo: &self.lo,
            shape: &self.shape,
            cnames: self.cnames,
            cvals: &self.cvals,
        }
    }

    fn cbind(&self, name: &str) -> Option<i64> {
        self.cnames
            .iter()
            .position(|n| n == name)
            .map(|i| self.cvals[i])
    }
}

/// Owned hoist key: everything a box-pure value can read from its box — the
/// structural analogue of the runtime `box_sig` + binder-set check.
#[derive(Hash, PartialEq, Eq, Clone)]
struct BoxKey {
    syms: Vec<String>,
    lo: Vec<i64>,
    shape: Vec<usize>,
    cnames: Vec<String>,
    cvals: Vec<i64>,
}

impl BoxKey {
    fn of(bx: &LBox) -> BoxKey {
        BoxKey {
            syms: bx.syms.to_vec(),
            lo: bx.lo.to_vec(),
            shape: bx.shape.to_vec(),
            cnames: bx.cnames.to_vec(),
            cvals: bx.cvals.to_vec(),
        }
    }
}

/// Scope-local value-numbering key.
#[derive(Hash, PartialEq, Eq, Clone, Copy)]
enum VnKey {
    /// Interned operator node address (`Arc::as_ptr`).
    Node(usize),
    /// Coordinate ramp along this output axis.
    Ramp(usize),
}

#[derive(Default)]
struct ScopeFrame {
    map: FxHashMap<VnKey, LV>,
    /// Insertions made while inside a conditional branch, for rollback.
    journal: Vec<(VnKey, Option<LV>)>,
}

/// What a (taped or fallback) observed rule left behind for later readers.
#[derive(Clone, Debug)]
enum ObsVal {
    /// Taped: the produced value, origin-normalized to all-1s.
    Taped(LV),
    /// Produced by a fallback rule (read through the runtime observed map).
    /// `shape` is the statically known array shape (`Some(empty)` = 0-d),
    /// `None` = statically unknown (readers must themselves fall back).
    External { shape: Option<DimU>, tier: Cadence },
}

// ---------------------------------------------------------------------------
// Builder.
// ---------------------------------------------------------------------------

struct Chunk {
    rule: u32,
    instrs: Vec<Instr>,
}

pub(crate) struct TapeBuilder<'m> {
    var_shapes: &'m IndexMap<String, VarShape>,
    param_names: &'m [String],
    /// Per-name observed cadence tier (from the driver's classifiers).
    obs_tier: FxHashMap<String, Cadence>,

    // Program under construction -------------------------------------------
    slots: Vec<SlotDesc>,
    plans: Vec<GatherPlan>,
    regions: Vec<RegionSpec>,
    state_vars: Vec<StateRef>,
    state_ix: FxHashMap<String, u16>,
    obs_reads: Vec<String>,
    obs_read_ix: FxHashMap<String, u16>,
    dy_writes: Vec<DyWrite>,
    rules: Vec<RuleInfo>,
    /// Per-section chunk streams (index = Cadence as usize).
    streams: [Vec<Chunk>; 3],
    /// Home-stream chunk index per rule ordinal (for export insertion).
    rule_home_chunk: Vec<Option<usize>>,

    // Lowering state ---------------------------------------------------------
    cur_rule: u32,
    home: Cadence,
    scope_frames: Vec<ScopeFrame>,
    /// Nested conditional-branch buffers (top = innermost).
    branch_bufs: Vec<Vec<Instr>>,
    hoist: FxHashMap<(BoxKey, VnKey), LV>,
    /// Hoist insertions of the CURRENT rule (rollback on bail).
    hoist_journal: Vec<(BoxKey, VnKey)>,
    /// Observed values defined so far, in rule order.
    obs_defined: FxHashMap<String, ObsVal>,

    // Diagnostics ------------------------------------------------------------
    vn_scope_hits: usize,
    vn_hoist_hits: usize,
}

/// Snapshot for transactional per-rule lowering.
struct RuleTxn {
    slots: usize,
    plans: usize,
    regions: usize,
    dy_writes: usize,
    stream_lens: [usize; 3],
    hoist_journal: usize,
}

impl<'m> TapeBuilder<'m> {
    fn new(
        var_shapes: &'m IndexMap<String, VarShape>,
        param_names: &'m [String],
        obs_tier: FxHashMap<String, Cadence>,
    ) -> Self {
        let mut state_vars = Vec::with_capacity(var_shapes.len());
        let mut state_ix = FxHashMap::default();
        for (name, vs) in var_shapes {
            state_ix.insert(name.clone(), state_vars.len() as u16);
            state_vars.push(StateRef {
                name: name.clone(),
                shape: vs.shape.iter().copied().collect(),
                origin: vs.origin.iter().copied().collect(),
                flat_offset: vs.flat_offset,
            });
        }
        TapeBuilder {
            var_shapes,
            param_names,
            obs_tier,
            slots: Vec::new(),
            plans: Vec::new(),
            regions: Vec::new(),
            state_vars,
            state_ix,
            obs_reads: Vec::new(),
            obs_read_ix: FxHashMap::default(),
            dy_writes: Vec::new(),
            rules: Vec::new(),
            streams: [Vec::new(), Vec::new(), Vec::new()],
            rule_home_chunk: Vec::new(),
            cur_rule: 0,
            home: Cadence::Continuous,
            scope_frames: Vec::new(),
            branch_bufs: Vec::new(),
            hoist: FxHashMap::default(),
            hoist_journal: Vec::new(),
            obs_defined: FxHashMap::default(),
            vn_scope_hits: 0,
            vn_hoist_hits: 0,
        }
    }

    // -- emission ------------------------------------------------------------

    fn in_branch(&self) -> bool {
        !self.branch_bufs.is_empty()
    }

    /// Section an instruction with operand cadence `want` lands in.
    fn placement(&self, want: Cadence) -> Cadence {
        if self.in_branch() {
            self.home
        } else {
            debug_assert!(
                want <= self.home,
                "instruction cadence {want:?} exceeds rule home {:?}",
                self.home
            );
            want.min(self.home)
        }
    }

    fn emit(&mut self, instr: Instr, section: Cadence) {
        if let Some(buf) = self.branch_bufs.last_mut() {
            buf.push(instr);
            return;
        }
        let stream = &mut self.streams[section as usize];
        match stream.last_mut() {
            Some(c) if c.rule == self.cur_rule => c.instrs.push(instr),
            _ => stream.push(Chunk {
                rule: self.cur_rule,
                instrs: vec![instr],
            }),
        }
    }

    fn new_slot(
        &mut self,
        shape: &[usize],
        origin: &[i64],
        scalar: bool,
        cadence: Cadence,
    ) -> SlotId {
        let id = self.slots.len() as SlotId;
        self.slots.push(SlotDesc {
            shape: shape.iter().copied().collect(),
            origin: origin.iter().copied().collect(),
            scalar,
            cadence,
            storage: u32::MAX,
        });
        id
    }

    // -- LV helpers -----------------------------------------------------------

    /// The array box of an LV, or `None` for a scalar kind.
    fn lv_box(&self, lv: &LV) -> Option<(DimU, DimI)> {
        match lv {
            LV::Lit(_) | LV::Param(_) | LV::Time | LV::Scalar(_) => None,
            LV::Arr(s) => {
                let d = &self.slots[*s as usize];
                Some((d.shape.clone(), d.origin.clone()))
            }
            LV::State(ix) => {
                let sv = &self.state_vars[*ix as usize];
                if sv.shape.is_empty() {
                    None
                } else {
                    Some((sv.shape.clone(), DimI::from_elem(1, sv.shape.len())))
                }
            }
            LV::Obs { shape, .. } => {
                if shape.is_empty() {
                    None
                } else {
                    Some((shape.clone(), DimI::from_elem(1, shape.len())))
                }
            }
        }
    }

    fn lv_cadence(&self, lv: &LV) -> Cadence {
        match lv {
            LV::Lit(_) | LV::Param(_) => Cadence::Const,
            LV::Time | LV::State(_) => Cadence::Continuous,
            LV::Scalar(s) | LV::Arr(s) => self.slots[*s as usize].cadence,
            LV::Obs { tier, .. } => *tier,
        }
    }

    fn op_of(&self, lv: &LV) -> Operand {
        match lv {
            LV::Lit(v) => Operand::Lit(*v),
            LV::Param(p) => Operand::Param(*p),
            LV::Time => Operand::Time,
            LV::Scalar(s) | LV::Arr(s) => Operand::Slot(*s),
            LV::State(ix) => Operand::State(*ix),
            LV::Obs { ix, .. } => Operand::Obs(*ix),
        }
    }

    fn src_of(&self, lv: &LV) -> SrcRef {
        match lv {
            LV::Arr(s) => SrcRef::Slot(*s),
            LV::State(ix) => SrcRef::State(*ix),
            LV::Obs { ix, .. } => SrcRef::Obs(*ix),
            _ => unreachable!("src_of called on a scalar LV"),
        }
    }

    fn obs_read(&mut self, name: &str) -> u16 {
        if let Some(&ix) = self.obs_read_ix.get(name) {
            return ix;
        }
        let ix = self.obs_reads.len() as u16;
        self.obs_reads.push(name.to_string());
        self.obs_read_ix.insert(name.to_string(), ix);
        ix
    }

    // -- scopes / VN ----------------------------------------------------------

    fn push_scope(&mut self) {
        self.scope_frames.push(ScopeFrame::default());
    }

    fn pop_scope(&mut self) {
        self.scope_frames.pop();
    }

    fn vn_get(&mut self, key: VnKey, bx: &LBox) -> Option<LV> {
        if let Some(frame) = self.scope_frames.last() {
            if let Some(lv) = frame.map.get(&key) {
                self.vn_scope_hits += 1;
                return Some(lv.clone());
            }
        }
        if let Some(lv) = self.hoist.get(&(BoxKey::of(bx), key)) {
            self.vn_hoist_hits += 1;
            return Some(lv.clone());
        }
        None
    }

    fn vn_put(&mut self, key: VnKey, lv: &LV, bx: &LBox) {
        let in_branch = self.in_branch();
        if let Some(frame) = self.scope_frames.last_mut() {
            let prev = frame.map.insert(key, lv.clone());
            if in_branch {
                frame.journal.push((key, prev));
            }
        }
        // The cross-rule hoist (ess-lih analogue): only for values whose
        // cadence is ≤ SEGMENT — pure functions of (box, structure, constant
        // tier) — and only when computed UNCONDITIONALLY.
        if !in_branch && self.lv_cadence(lv) <= Cadence::Segment {
            let hk = (BoxKey::of(bx), key);
            if self.hoist.insert(hk.clone(), lv.clone()).is_none() {
                self.hoist_journal.push(hk);
            }
        }
    }

    // -- conditional branches -------------------------------------------------

    fn push_branch(&mut self) -> usize {
        self.branch_bufs.push(Vec::new());
        self.scope_frames
            .last()
            .map(|f| f.journal.len())
            .unwrap_or(0)
    }

    /// Close the innermost branch: roll back VN insertions made inside it and
    /// return its instruction buffer.
    fn pop_branch(&mut self, journal_mark: usize) -> Vec<Instr> {
        let buf = self.branch_bufs.pop().expect("branch buffer open");
        if let Some(frame) = self.scope_frames.last_mut() {
            while frame.journal.len() > journal_mark {
                let (key, prev) = frame.journal.pop().expect("journal entry");
                match prev {
                    Some(v) => {
                        frame.map.insert(key, v);
                    }
                    None => {
                        frame.map.remove(&key);
                    }
                }
            }
        }
        buf
    }

    // -- expression lowering (the eval_vec mirror) ---------------------------

    fn lower_expr(&mut self, e: &Expr, bx: &LBox) -> LResult<LV> {
        match e {
            Expr::Number(n) => Ok(LV::Lit(*n)),
            Expr::Integer(n) => Ok(LV::Lit(*n as f64)),
            Expr::Variable(name) => self.resolve_var(name, bx),
            Expr::Operator(node) => {
                let key = VnKey::Node(Arc::as_ptr(node) as usize);
                if let Some(hit) = self.vn_get(key, bx) {
                    return Ok(hit);
                }
                let lv = self.lower_op(node, bx)?;
                self.vn_put(key, &lv, bx);
                Ok(lv)
            }
        }
    }

    /// Mirror of `eval_vec_variable`, in ITS resolution order: `t`, bound
    /// contraction index, output box symbol (ramp), state, observed, param,
    /// bail (forcing / unknown loop bind).
    fn resolve_var(&mut self, name: &str, bx: &LBox) -> LResult<LV> {
        if name == "t" {
            return Ok(LV::Time);
        }
        if let Some(v) = bx.cbind(name) {
            return Ok(LV::Lit(v as f64));
        }
        if let Some(a) = bx.syms.iter().position(|s| s == name) {
            let key = VnKey::Ramp(a);
            if let Some(hit) = self.vn_get(key, bx) {
                return Ok(hit);
            }
            let sec = self.placement(Cadence::Const);
            let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
            self.emit(
                Instr::Ramp {
                    axis: a as u8,
                    lo: bx.lo[a],
                    out,
                },
                sec,
            );
            let lv = LV::Arr(out);
            self.vn_put(key, &lv, bx);
            return Ok(lv);
        }
        if let Some(&ix) = self.state_ix.get(name) {
            return Ok(LV::State(ix));
        }
        if let Some(ov) = self.obs_defined.get(name).cloned() {
            return match ov {
                ObsVal::Taped(lv) => Ok(lv),
                ObsVal::External {
                    shape: Some(shape),
                    tier,
                } => {
                    let ix = self.obs_read(name);
                    Ok(LV::Obs { ix, shape, tier })
                }
                ObsVal::External { shape: None, .. } => {
                    bail_tape!(
                        "variable: observed `{name}` has a statically-unknown shape (fallback producer)"
                    )
                }
            };
        }
        if let Some(i) = self.param_names.iter().position(|p| p == name) {
            return Ok(LV::Param(i as u16));
        }
        bail_tape!("variable: unresolved symbol (forcing/loop-bind?): {name}")
    }

    /// Mirror of `eval_vec_op`'s dispatch (via the SAME `vec_op_code`).
    fn lower_op(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        match vec_op_code(&node.op) {
            VecOp::Arith(code) => {
                let Some((first, rest)) = node.args.split_first() else {
                    bail_tape!("op: `{}` with no arguments", node.op);
                };
                if code == BinCode::Sub && rest.is_empty() {
                    let v = self.lower_expr(first, bx)?;
                    return self.emit_neg(v);
                }
                let mut acc = self.lower_expr(first, bx)?;
                for a in rest {
                    let v = self.lower_expr(a, bx)?;
                    acc = self.emit_bin(code, acc, v)?;
                }
                Ok(acc)
            }
            VecOp::Neg => {
                let Some(first) = node.args.first() else {
                    bail_tape!("op: `neg` with no arguments");
                };
                let v = self.lower_expr(first, bx)?;
                self.emit_neg(v)
            }
            VecOp::Index => self.lower_index(node, bx),
            VecOp::Aggregate => self.lower_nested_aggregate(node, bx),
            VecOp::Makearray => self.lower_makearray(node, bx),
            VecOp::Const => match eval_const(node) {
                Value::Scalar(s) => Ok(LV::Lit(s)),
                Value::Array(_) => bail_tape!("op: array-valued `const`"),
            },
            VecOp::Cmp(code) => {
                if node.args.len() != 2 {
                    bail_tape!(
                        "op: comparison `{}` with arity {}",
                        node.op,
                        node.args.len()
                    );
                }
                let a = self.lower_expr(&node.args[0], bx)?;
                let b = self.lower_expr(&node.args[1], bx)?;
                self.emit_bin(code, a, b)
            }
            VecOp::Ifelse => self.lower_ifelse(node, bx),
            VecOp::Unary(code) => {
                if node.args.len() != 1 {
                    bail_tape!("op: unary `{}` with arity {}", node.op, node.args.len());
                }
                let v = self.lower_expr(&node.args[0], bx)?;
                Ok(self.emit_un(code, v))
            }
            VecOp::Broadcast => {
                let code = BinCode::of(node.broadcast_fn.as_deref().unwrap_or("+"));
                let mut it = node.args.iter();
                let Some(first) = it.next() else {
                    bail_tape!("op: `broadcast` with no operands");
                };
                let mut acc = self.lower_expr(first, bx)?;
                for a in it {
                    let v = self.lower_expr(a, bx)?;
                    acc = self.emit_bin(code, acc, v)?;
                }
                Ok(acc)
            }
            VecOp::Unsupported => {
                bail_tape!("op: unsupported operator `{}`/{}", node.op, node.args.len())
            }
        }
    }

    /// `vec_combine` made symbolic: fold literals with the SAME kernel table,
    /// require array operands to share one box, broadcast scalars.
    fn emit_bin(&mut self, code: BinCode, a: LV, b: LV) -> LResult<LV> {
        if let (LV::Lit(x), LV::Lit(y)) = (&a, &b) {
            return Ok(LV::Lit(binary_kernel_of(code)(*x, *y)));
        }
        let ba = self.lv_box(&a);
        let bb = self.lv_box(&b);
        let (shape, origin, scalar) = match (&ba, &bb) {
            (None, None) => (DimU::new(), DimI::new(), true),
            (Some((s, o)), None) | (None, Some((s, o))) => (s.clone(), o.clone(), false),
            (Some((sa, oa)), Some((sb, ob))) => {
                if sa != sb || oa != ob {
                    bail_tape!(
                        "combine: array operand boxes differ ({sa:?}@{oa:?} vs {sb:?}@{ob:?})"
                    );
                }
                (sa.clone(), oa.clone(), false)
            }
        };
        let want = self.lv_cadence(&a).max(self.lv_cadence(&b));
        let sec = self.placement(want);
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Bin {
            op: code,
            a: self.op_of(&a),
            b: self.op_of(&b),
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    fn emit_un(&mut self, code: UnCode, a: LV) -> LV {
        if let LV::Lit(x) = &a {
            return LV::Lit(unary_kernel_of(code)(*x));
        }
        let (shape, origin, scalar) = match self.lv_box(&a) {
            None => (DimU::new(), DimI::new(), true),
            Some((s, o)) => (s, o, false),
        };
        let sec = self.placement(self.lv_cadence(&a));
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Un {
            op: code,
            a: self.op_of(&a),
            out,
        };
        self.emit(instr, sec);
        if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        }
    }

    fn emit_neg(&mut self, a: LV) -> LResult<LV> {
        if let LV::Lit(x) = &a {
            return Ok(LV::Lit(-x));
        }
        let (shape, origin, scalar) = match self.lv_box(&a) {
            None => (DimU::new(), DimI::new(), true),
            Some((s, o)) => (s, o, false),
        };
        let sec = self.placement(self.lv_cadence(&a));
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Neg {
            a: self.op_of(&a),
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    /// A zero-filled array over `box` (the ghost-only gather results).
    fn emit_zero_array(&mut self, shape: &[usize], origin: &[i64]) -> LV {
        let sec = self.placement(Cadence::Const);
        let out = self.new_slot(shape, origin, false, sec);
        self.emit(
            Instr::Fill {
                v: Operand::Lit(0.0),
                out,
            },
            sec,
        );
        LV::Arr(out)
    }

    /// Fill an array slot over `box` with a scalar LV (`Fill` broadcast).
    fn emit_fill(&mut self, v: &LV, shape: &[usize], origin: &[i64], cad_floor: Cadence) -> LV {
        let want = self.lv_cadence(v).max(cad_floor);
        let sec = self.placement(want);
        let out = self.new_slot(shape, origin, false, sec);
        self.emit(
            Instr::Fill {
                v: self.op_of(v),
                out,
            },
            sec,
        );
        LV::Arr(out)
    }

    // -- ifelse ---------------------------------------------------------------

    fn lower_ifelse(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        if node.args.len() != 3 {
            bail_tape!("op: `ifelse` with arity {}", node.args.len());
        }
        let cond = self.lower_expr(&node.args[0], bx)?;
        // Compile-time-known scalar condition: lower ONLY the taken branch —
        // exactly what the overlay evaluates (the untaken branch is never
        // visited, so an unsupported construct there must not bail the rule).
        if let LV::Lit(c) = &cond {
            let c = *c;
            return if c != 0.0 {
                self.lower_expr(&node.args[1], bx)
            } else {
                self.lower_expr(&node.args[2], bx)
            };
        }
        match self.lv_box(&cond) {
            // Runtime SCALAR condition: short-circuit via JmpIfZero — the
            // untaken branch's instructions are never executed.
            None => self.lower_branchy_ifelse(cond, &node.args[1], &node.args[2], |s, e| {
                s.lower_expr(e, bx)
            }),
            // ARRAY condition: evaluate BOTH branches and select elementwise
            // (`vec_select`).
            Some(_) => {
                let a = self.lower_expr(&node.args[1], bx)?;
                let b = self.lower_expr(&node.args[2], bx)?;
                self.emit_select(cond, a, b)
            }
        }
    }

    /// `vec_select` made symbolic: `cond`'s box is the output box; `a`/`b` are
    /// scalars (broadcast) or arrays over the same box. A scalar `cond` is the
    /// filter-gate shape (whole-term keep/replace — elementwise identical).
    fn emit_select(&mut self, cond: LV, a: LV, b: LV) -> LResult<LV> {
        let cb = self.lv_box(&cond);
        let (shape, origin, scalar) = match &cb {
            Some((s, o)) => (s.clone(), o.clone(), false),
            None => {
                // Scalar condition gate (§5.3 runtime filter): output box is
                // the term's own box (or scalar if both are).
                let ab = self.lv_box(&a);
                let bb = self.lv_box(&b);
                match (&ab, &bb) {
                    (None, None) => (DimU::new(), DimI::new(), true),
                    (Some((s, o)), None) | (None, Some((s, o))) => (s.clone(), o.clone(), false),
                    (Some((sa, oa)), Some((sb, ob))) => {
                        if sa != sb || oa != ob {
                            bail_tape!("select: branch boxes differ");
                        }
                        (sa.clone(), oa.clone(), false)
                    }
                }
            }
        };
        if cb.is_some() {
            let box_ok = |v: Option<(DimU, DimI)>| match v {
                None => true,
                Some((s, o)) => s == shape && o == origin,
            };
            if !box_ok(self.lv_box(&a)) || !box_ok(self.lv_box(&b)) {
                bail_tape!("select: operand box does not match the condition box");
            }
        }
        let want = self
            .lv_cadence(&cond)
            .max(self.lv_cadence(&a))
            .max(self.lv_cadence(&b));
        let sec = self.placement(want);
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Select {
            cond: self.op_of(&cond),
            a: self.op_of(&a),
            b: self.op_of(&b),
            out,
        };
        self.emit(instr, sec);
        Ok(if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        })
    }

    // -- index (gather) -------------------------------------------------------

    /// Compile-time mirror of `eval_vec_index`, reusing the overlay's OWN axis
    /// classifier. Everything is static except the source data.
    fn lower_index(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        if node.args.is_empty() {
            bail_tape!("index: no arguments");
        }
        let arg0 = self.lower_expr(&node.args[0], bx)?;
        let n = node.args.len() - 1;
        let Some((src_shape, src_origin)) = self.lv_box(&arg0) else {
            return if n == 0 {
                Ok(arg0)
            } else {
                bail_tape!("index: base is a scalar but {n} index args given")
            };
        };
        let src_ndim = src_shape.len();
        if n != src_ndim {
            bail_tape!("index: arg count != source rank ({n} args vs rank {src_ndim})");
        }
        let out_ndim = bx.shape.len();
        let vb = bx.as_vecbox();

        let mut mapped: SmallVec<[Option<(usize, AxisIndex)>; 4]> =
            (0..out_ndim).map(|_| None).collect();
        let mut n_mapped = 0usize;
        let mut fixed: SmallVec<[(usize, i64); 4]> = SmallVec::new();
        let mut any_fixed_oob = false;
        for d in 0..n {
            let e = &node.args[1 + d];
            match classify_axis_role(e, &vb) {
                Some(AxisRole::Map { out_axis, ax }) if mapped[out_axis].is_none() => {
                    mapped[out_axis] = Some((d, ax));
                    n_mapped += 1;
                }
                Some(AxisRole::Const(idx1)) => {
                    let i0 = idx1 - src_origin[d];
                    if i0 < 0 || i0 >= src_shape[d] as i64 {
                        any_fixed_oob = true;
                        fixed.push((d, 0));
                    } else {
                        fixed.push((d, i0));
                    }
                }
                _ => bail_tape!(
                    "index: axis {d} is neither an affine/wrap map of an unclaimed output symbol nor a constant select"
                ),
            }
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
            let mut idx: SmallVec<[usize; 4]> = SmallVec::from_elem(0usize, n);
            for &(d, i0) in &fixed {
                idx[d] = i0 as usize;
            }
            let sec = self.placement(self.lv_cadence(&arg0));
            let out = self.new_slot(&[], &[], true, sec);
            let instr = Instr::LoadElem {
                src: self.src_of(&arg0),
                idx,
                out,
            };
            self.emit(instr, sec);
            return Ok(LV::Scalar(out));
        }

        // Per-axis copy segments, verbatim from `eval_vec_index`.
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
                AxisIndex::Wrap { k, period } => {
                    let (k, period) = (*k, *period);
                    if so != bx.lo[a] || ssz != period || bx.shape[a] as i64 != period {
                        bail_tape!("index: periodic wrap axis is not a full-period roll");
                    }
                    let p = period as usize;
                    let s = (((k % period) + period) % period) as usize;
                    let mut segs = SmallVec::new();
                    if s == 0 {
                        segs.push((0usize, p, 0usize));
                    } else {
                        segs.push((0usize, p - s, s));
                        segs.push((p - s, s, 0usize));
                    }
                    axis_segs.push(segs);
                }
            }
        }

        // Reduction schedule: fixed axes (descending), then the permutation of
        // the mapped source axes into output order, then broadcast axes.
        let mut fixed_desc: SmallVec<[(usize, usize); 4]> =
            fixed.iter().map(|&(d, i0)| (d, i0 as usize)).collect();
        fixed_desc.sort_by(|a, b| b.0.cmp(&a.0));
        let mut mapped_src: SmallVec<[usize; 4]> =
            mapped.iter().flatten().map(|(d, _)| *d).collect();
        mapped_src.sort_unstable();
        let perm: SmallVec<[usize; 4]> = (0..out_ndim)
            .filter_map(|a| mapped[a].as_ref())
            .map(|(d, _)| {
                mapped_src
                    .iter()
                    .position(|s| s == d)
                    .expect("mapped source axis is in mapped_src")
            })
            .collect();
        let mapped_flags: SmallVec<[bool; 4]> =
            (0..out_ndim).map(|a| mapped[a].is_some()).collect();

        let plan_ix = self.plans.len() as u32;
        self.plans.push(GatherPlan {
            fixed_desc,
            perm,
            mapped: mapped_flags,
            segs: axis_segs,
            shape: bx.shape.clone(),
            origin: bx.lo.clone(),
            src_shape,
            src_origin,
        });
        let sec = self.placement(self.lv_cadence(&arg0));
        let out = self.new_slot(&bx.shape, &bx.lo, false, sec);
        let instr = Instr::Gather {
            src: self.src_of(&arg0),
            plan: plan_ix,
            out,
        };
        self.emit(instr, sec);
        Ok(LV::Arr(out))
    }

    // -- makearray ------------------------------------------------------------

    fn lower_makearray(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        let Some(regions) = node.regions.as_ref() else {
            bail_tape!("makearray: no `regions`");
        };
        let Some(values) = node.values.as_ref() else {
            bail_tape!("makearray: no `values`");
        };
        if regions.is_empty() || values.len() != regions.len() {
            bail_tape!("makearray: empty or mismatched regions/values");
        }
        let ndim = regions[0].len();
        if ndim != bx.shape.len() {
            bail_tape!("makearray: region rank != output box rank");
        }
        let mut lo_bb = DimI::from_elem(i64::MAX, ndim);
        let mut hi_bb = DimI::from_elem(i64::MIN, ndim);
        for region in regions.iter() {
            if region.len() != ndim {
                bail_tape!("makearray: ragged region rank");
            }
            for (d, r) in region.iter().enumerate() {
                lo_bb[d] = lo_bb[d].min(r[0]);
                hi_bb[d] = hi_bb[d].max(r[1]);
            }
        }
        let bb_shape: DimU = (0..ndim)
            .map(|d| (hi_bb[d] - lo_bb[d] + 1) as usize)
            .collect();

        let sec0 = self.placement(Cadence::Const);
        let mut cur = self.new_slot(&bb_shape, &lo_bb, false, sec0);
        self.emit(
            Instr::Fill {
                v: Operand::Lit(0.0),
                out: cur,
            },
            sec0,
        );
        let mut cur_cad = sec0;

        for (region, value_expr) in regions.iter().zip(values.iter()) {
            let r_lo: DimI = region.iter().map(|r| r[0]).collect();
            let r_shape: DimU = region.iter().map(|r| (r[1] - r[0] + 1) as usize).collect();
            if r_shape.contains(&0) {
                bail_tape!("makearray: empty region");
            }
            // A region is its own box (and CSE scope): a ramp / shifted gather
            // means something different inside it.
            self.push_scope();
            let rbx = LBox {
                syms: bx.syms,
                lo: r_lo.clone(),
                shape: r_shape.clone(),
                cnames: bx.cnames,
                cvals: bx.cvals.clone(),
            };
            let v = self.lower_expr(value_expr, &rbx);
            self.pop_scope();
            let v = v?;
            // An array region value must match the region box exactly.
            if let Some((s, o)) = self.lv_box(&v) {
                if s != r_shape || o != r_lo {
                    bail_tape!("makearray: region value box does not match the region");
                }
            }
            let region_ix = self.regions.len() as u32;
            self.regions.push(RegionSpec {
                dest_lo: (0..ndim).map(|d| (r_lo[d] - lo_bb[d]) as usize).collect(),
                shape: r_shape,
            });
            let want = cur_cad.max(self.lv_cadence(&v));
            let sec = self.placement(want);
            let out = self.new_slot(&bb_shape, &lo_bb, false, sec);
            let instr = Instr::Region {
                base: cur,
                src: self.op_of(&v),
                region: region_ix,
                out,
            };
            self.emit(instr, sec);
            cur = out;
            cur_cad = sec;
        }
        Ok(LV::Arr(cur))
    }

    // -- nested aggregate -----------------------------------------------------

    /// Mirror of `eval_vec_nested_aggregate` (same `arrayop_spec`, same
    /// binding-independence precondition).
    fn lower_nested_aggregate(&mut self, node: &Arc<ExpressionNode>, bx: &LBox) -> LResult<LV> {
        let Some(spec) = arrayop_spec(node) else {
            bail_tape!("aggregate: node carries no `expr` body");
        };
        if spec.ranges.is_empty() {
            bail_tape!("aggregate: rank-0 output (scalar reduction)");
        }
        for name in bx.syms.iter().chain(bx.cnames.iter()) {
            if expr_mentions(spec.body, name) || spec.filter.is_some_and(|f| expr_mentions(f, name))
            {
                bail_tape!("aggregate: nested body depends on an enclosing bound index `{name}`");
            }
        }
        self.lower_arrayop(
            spec.idx_names,
            &spec.ranges,
            spec.body,
            &spec.contract_names,
            &spec.contract_dims,
            spec.reduce,
            spec.filter,
        )
    }

    // -- arrayop (the try_eval_arrayop_vectorized mirror) ---------------------

    #[allow(clippy::too_many_arguments)]
    fn lower_arrayop(
        &mut self,
        idx_names: &[String],
        ranges: &[(i64, i64)],
        body: &Expr,
        contract_names: &[String],
        contract_dims: &[ContractDim],
        reduce: ReduceKind,
        filter: Option<&Expr>,
    ) -> LResult<LV> {
        let lo: DimI = ranges.iter().map(|(l, _)| *l).collect();
        let shape: DimU = ranges.iter().map(|(l, h)| (h - l + 1) as usize).collect();
        if shape.contains(&0) {
            bail_tape!("arrayop: empty output box");
        }
        self.push_scope();
        let v = if contract_names.is_empty() {
            let bx = LBox {
                syms: idx_names,
                lo: lo.clone(),
                shape: shape.clone(),
                cnames: &[],
                cvals: SmallVec::new(),
            };
            let r = self.lower_expr(body, &bx).and_then(|body_v| match filter {
                None => Ok(body_v),
                Some(f) => {
                    let fv = self.lower_expr(f, &bx)?;
                    match fv {
                        LV::Lit(c) => {
                            if c != 0.0 {
                                Ok(body_v)
                            } else {
                                Ok(self.emit_fill(
                                    &LV::Lit(reduce.identity()),
                                    &shape,
                                    &lo,
                                    Cadence::Const,
                                ))
                            }
                        }
                        fv => self.emit_select(fv, body_v, LV::Lit(reduce.identity())),
                    }
                }
            });
            self.pop_scope();
            r?
        } else {
            let r = self.lower_contracted(
                idx_names,
                &lo,
                &shape,
                body,
                contract_names,
                contract_dims,
                reduce,
                filter,
            );
            self.pop_scope();
            r?
        };
        // Mirror of the top-level bare-View bail: the oracle scalarizes a bare
        // whole-array body, so the overlay refuses it — and so do we.
        if matches!(&v, LV::State(_) | LV::Obs { .. }) && self.lv_box(&v).is_some() {
            bail_tape!("arrayop: body reduced to a bare whole-array view (oracle scalarizes it)");
        }
        match self.lv_box(&v) {
            None => Ok(self.emit_fill(&v, &shape, &lo, Cadence::Const)),
            Some((s, o)) => {
                if s == shape && o == lo {
                    Ok(v)
                } else {
                    bail_tape!("arrayop: result box does not match the output box");
                }
            }
        }
    }

    /// Mirror of `eval_vec_contracted`: unroll the static contraction window
    /// in ITS ascending mixed-radix tuple order (dim 0 fastest) and left-fold
    /// with the reduction's combine kernel from an identity-filled
    /// accumulator.
    #[allow(clippy::too_many_arguments)]
    fn lower_contracted(
        &mut self,
        idx_names: &[String],
        lo: &DimI,
        shape: &DimU,
        body: &Expr,
        contract_names: &[String],
        contract_dims: &[ContractDim],
        reduce: ReduceKind,
        filter: Option<&Expr>,
    ) -> LResult<LV> {
        let Some(combine_op) = reduce_combine_op(reduce) else {
            bail_tape!("contracted: boolean reduction (or/and) not vectorized");
        };
        const MAXC: usize = 4;
        let nc = contract_names.len();
        if nc == 0 || nc > MAXC {
            bail_tape!("contracted: contraction rank out of range ({nc})");
        }
        let mut clo = [0i64; MAXC];
        let mut chi = [0i64; MAXC];
        for (i, d) in contract_dims.iter().enumerate() {
            match d {
                ContractDim::Static(l, h) => {
                    clo[i] = *l;
                    chi[i] = *h;
                }
                other => bail_tape!("contracted: non-static contraction dim ({other:?})"),
            }
        }

        // Accumulator: identity-filled buffer over the output box.
        let identity = reduce.identity();
        let mut acc = self.emit_fill(&LV::Lit(identity), shape, lo, Cadence::Const);

        // An empty window contributes no terms — the result is the identity.
        if (0..nc).any(|i| clo[i] > chi[i]) {
            return Ok(acc);
        }

        let mut cvals = [0i64; MAXC];
        cvals[..nc].copy_from_slice(&clo[..nc]);
        loop {
            // Each contraction tuple is a DISTINCT box (and CSE scope).
            self.push_scope();
            let bx = LBox {
                syms: idx_names,
                lo: lo.clone(),
                shape: shape.clone(),
                cnames: contract_names,
                cvals: SmallVec::from_slice(&cvals[..nc]),
            };
            let term = (|| -> LResult<LV> {
                let term = self.lower_expr(body, &bx)?;
                match filter {
                    None => Ok(term),
                    Some(f) => {
                        let fv = self.lower_expr(f, &bx)?;
                        match fv {
                            LV::Lit(c) => {
                                if c != 0.0 {
                                    Ok(term)
                                } else {
                                    Ok(self.emit_fill(
                                        &LV::Lit(identity),
                                        shape,
                                        lo,
                                        Cadence::Const,
                                    ))
                                }
                            }
                            fv => self.emit_select(fv, term, LV::Lit(identity)),
                        }
                    }
                }
            })();
            self.pop_scope();
            let term = term?;
            acc = self.emit_bin(combine_op, acc, term)?;

            // Mixed-radix increment over the contraction window (dim 0
            // fastest — `eval_vec_contracted`'s order, NOT the per-cell
            // oracle's odometer).
            let mut d = 0;
            let mut done = false;
            loop {
                if d == nc {
                    done = true;
                    break;
                }
                cvals[d] += 1;
                if cvals[d] <= chi[d] {
                    break;
                }
                cvals[d] = clo[d];
                d += 1;
            }
            if done {
                break;
            }
        }
        Ok(acc)
    }

    // -- wholesale-body lowering (the per-cell `eval` mirror) -----------------
    //
    // A `Scalar` rule's body — a declared observed's whole expression, or a
    // 0-d state's RHS — is evaluated by the per-cell oracle's `eval`
    // WHOLESALE: a variable reference resolves to the whole array, elementwise
    // arithmetic broadcasts over it, and a top-level `aggregate`/`makearray`
    // materializes its own box (trying the SAME vectorized overlay this pass
    // compiles — `eval_arrayop` / `eval_makearray`). This mirror covers the
    // wholesale algebra where it agrees exactly with the tape's instruction
    // semantics:
    //
    //   * equal-shape (or scalar-broadcast) elementwise operands — `combine` /
    //     `broadcast_binary` reduce to the aligned Zip that `Instr::Bin`
    //     performs; a rank/shape mismatch (Julia trailing-pad broadcast) bails;
    //   * every wholesale array is origin-normalized to all-1s, matching how
    //     `lookup_variable` serves stored arrays (origin-blind).
    fn lower_wholesale(&mut self, e: &Expr) -> LResult<LV> {
        match e {
            Expr::Number(n) => Ok(LV::Lit(*n)),
            Expr::Integer(n) => Ok(LV::Lit(*n as f64)),
            Expr::Variable(name) => self.resolve_wholesale_var(name),
            Expr::Operator(node) => self.lower_wholesale_op(node),
        }
    }

    /// Mirror of `lookup_variable` (no loop binds on the compiled-rule path):
    /// `t`, state, observed, parameter, else bail (production would read
    /// forcing or the NaN sentinel — the fallback interpreter handles both).
    fn resolve_wholesale_var(&mut self, name: &str) -> LResult<LV> {
        if name == "t" {
            return Ok(LV::Time);
        }
        if let Some(&ix) = self.state_ix.get(name) {
            return Ok(LV::State(ix));
        }
        if let Some(ov) = self.obs_defined.get(name).cloned() {
            return match ov {
                ObsVal::Taped(lv) => Ok(lv),
                ObsVal::External {
                    shape: Some(shape),
                    tier,
                } => {
                    let ix = self.obs_read(name);
                    Ok(LV::Obs { ix, shape, tier })
                }
                ObsVal::External { shape: None, .. } => bail_tape!(
                    "variable: observed `{name}` has a statically-unknown shape (fallback producer)"
                ),
            };
        }
        if let Some(i) = self.param_names.iter().position(|p| p == name) {
            return Ok(LV::Param(i as u16));
        }
        bail_tape!("wholesale: unresolved symbol (forcing/NaN sentinel?) `{name}`")
    }

    fn lower_wholesale_op(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let op = node.op.as_str();
        match op {
            // n-ary arithmetic + logical connectives: `eval_arith` is a left
            // fold of `apply_binary` over scalars AND arrays (the all-scalar
            // `fold_scalar` and the `and`/`or` all/any forms agree with the
            // left fold at every legal arity), so a chained `Bin` reproduces
            // it bit for bit — for equal-shape operands.
            "+" | "-" | "*" | "/" | "^" | "min" | "max" | "and" | "or" => {
                let Some((first, rest)) = node.args.split_first() else {
                    return Ok(LV::Lit(f64::NAN)); // fold_scalar's empty-arity sentinel
                };
                if op == "-" && rest.is_empty() {
                    let v = self.lower_wholesale(first)?;
                    return self.emit_neg(v);
                }
                let mut acc = self.lower_wholesale(first)?;
                for a in rest {
                    let v = self.lower_wholesale(a)?;
                    acc = self.emit_bin(BinCode::of(op), acc, v)?;
                }
                Ok(acc)
            }
            "neg" => {
                if node.args.len() != 1 {
                    return Ok(LV::Lit(f64::NAN));
                }
                let v = self.lower_wholesale(&node.args[0])?;
                self.emit_neg(v)
            }
            "exp" | "log" | "ln" | "log10" | "sqrt" | "abs" | "sign" | "floor" | "ceil" | "sin"
            | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh" | "asinh"
            | "acosh" | "atanh" | "not" => {
                // `eval_unary` evaluates args[0] only; no args ⇒ NaN sentinel.
                let Some(first) = node.args.first() else {
                    return Ok(LV::Lit(f64::NAN));
                };
                let v = self.lower_wholesale(first)?;
                Ok(self.emit_un(UnCode::of(op), v))
            }
            "atan2" => {
                // `eval_binary`: first two args, NaN sentinel below arity 2.
                let ([a, b] | [a, b, ..]) = &node.args[..] else {
                    return Ok(LV::Lit(f64::NAN));
                };
                let av = self.lower_wholesale(a)?;
                let bv = self.lower_wholesale(b)?;
                self.emit_bin(BinCode::Atan2, av, bv)
            }
            "==" | "!=" | "<" | "<=" | ">" | ">=" => {
                if node.args.len() != 2 {
                    return Ok(LV::Lit(f64::NAN));
                }
                let av = self.lower_wholesale(&node.args[0])?;
                let bv = self.lower_wholesale(&node.args[1])?;
                self.emit_bin(BinCode::of(op), av, bv)
            }
            "ifelse" => {
                if node.args.len() != 3 {
                    return Ok(LV::Lit(f64::NAN));
                }
                let cond = self.lower_wholesale(&node.args[0])?;
                if let LV::Lit(c) = &cond {
                    let c = *c;
                    return if c != 0.0 {
                        self.lower_wholesale(&node.args[1])
                    } else {
                        self.lower_wholesale(&node.args[2])
                    };
                }
                match self.lv_box(&cond) {
                    None => {
                        self.lower_branchy_ifelse(cond, &node.args[1], &node.args[2], |s, e| {
                            s.lower_wholesale(e)
                        })
                    }
                    Some(_) => {
                        let a = self.lower_wholesale(&node.args[1])?;
                        let b = self.lower_wholesale(&node.args[2])?;
                        self.emit_select(cond, a, b)
                    }
                }
            }
            "D" => Ok(LV::Lit(0.0)),
            "Pre" => match node.args.first() {
                None => Ok(LV::Lit(f64::NAN)),
                Some(a) => self.lower_wholesale(a),
            },
            "const" => match eval_const(node) {
                Value::Scalar(s) => Ok(LV::Lit(s)),
                Value::Array(_) => bail_tape!("wholesale: array-valued `const`"),
            },
            "index" => self.lower_wholesale_index(node),
            "aggregate" => self.lower_wholesale_aggregate(node),
            "makearray" => self.lower_wholesale_makearray(node),
            other => bail_tape!("wholesale: unsupported op `{other}`"),
        }
    }

    /// `eval_index` mirror (wholesale): LITERAL 1-based indices into a known
    /// array (`index_into` semantics — out-of-bounds reads the Dirichlet
    /// ghost 0; a partial index yields a sub-array and bails).
    fn lower_wholesale_index(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let Some((base, idx_args)) = node.args.split_first() else {
            return Ok(LV::Lit(f64::NAN));
        };
        let basev = self.lower_wholesale(base)?;
        let Some((shape, origin)) = self.lv_box(&basev) else {
            // Scalar base: identity with 0 index args, NaN otherwise.
            return if idx_args.is_empty() {
                Ok(basev)
            } else {
                Ok(LV::Lit(f64::NAN))
            };
        };
        if origin.iter().any(|&o| o != 1) {
            bail_tape!("wholesale: index base is not origin-1");
        }
        let mut raw: SmallVec<[i64; 4]> = SmallVec::new();
        for a in idx_args {
            match self.lower_wholesale(a)? {
                LV::Lit(f) => raw.push(f.round() as i64),
                _ => bail_tape!("wholesale: non-literal index argument"),
            }
        }
        if raw.len() > shape.len() {
            return Ok(LV::Lit(f64::NAN)); // `index_into`'s over-index arm
        }
        if raw.len() < shape.len() {
            bail_tape!("wholesale: partial index yields a sub-array");
        }
        let mut idx: SmallVec<[usize; 4]> = SmallVec::new();
        let mut in_bounds = true;
        for (d, &one_based) in raw.iter().enumerate() {
            let dim = shape[d] as i64;
            if one_based < 1 || one_based > dim {
                in_bounds = false;
            }
            idx.push((one_based - 1).max(0) as usize);
        }
        if !in_bounds {
            return Ok(LV::Lit(0.0));
        }
        let cad = self.lv_cadence(&basev);
        let sec = self.placement(cad);
        let out = self.new_slot(&[], &[], true, sec);
        let src = self.src_of(&basev);
        self.emit(Instr::LoadElem { src, idx, out }, sec);
        Ok(LV::Scalar(out))
    }

    /// `eval_arrayop` mirror (a standalone aggregate evaluated wholesale):
    /// prefix scans get the running-fold lowering, rank-0 reductions stay
    /// per-cell (fallback), everything else goes through the same overlay
    /// entry as the compiled rules.
    fn lower_wholesale_aggregate(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let Some(spec) = arrayop_spec(node) else {
            return Ok(LV::Lit(f64::NAN)); // eval_arrayop's missing-body sentinel
        };
        let static_ranges = static_contract_ranges(&spec.contract_dims);
        if let Some(scan) = detect_prefix_scan(
            spec.idx_names,
            &spec.ranges,
            &spec.contract_names,
            static_ranges.as_deref(),
            spec.body,
            spec.filter,
        ) {
            let v = self.lower_prefix_scan(
                spec.idx_names,
                &spec.ranges,
                scan,
                &spec.contract_names[0],
                spec.body,
                spec.reduce,
            )?;
            return Ok(self.reorigin_to_one(v));
        }
        if spec.ranges.is_empty() {
            bail_tape!("aggregate: rank-0 output (scalar reduction, per-cell)");
        }
        let v = self.lower_arrayop(
            spec.idx_names,
            &spec.ranges,
            spec.body,
            &spec.contract_names,
            &spec.contract_dims,
            spec.reduce,
            spec.filter,
        )?;
        Ok(self.reorigin_to_one(v))
    }

    /// `eval_makearray` mirror (wholesale): the bounding-box assembly around
    /// region writes, with the same gates production applies before routing to
    /// the overlay (`shape` non-empty, no prefix-scan region value).
    fn lower_wholesale_makearray(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let regions: &[Vec<[i64; 2]>] = node.regions.as_deref().unwrap_or(&[]);
        let values: &[Expr] = node.values.as_deref().unwrap_or(&[]);
        if regions.is_empty() || values.len() != regions.len() {
            return Ok(LV::Lit(f64::NAN));
        }
        if crate::op_registry::check_makearray_regions(node).is_err() {
            return Ok(LV::Lit(f64::NAN));
        }
        let ndim = regions[0].len();
        let mut lo = DimI::from_elem(i64::MAX, ndim);
        let mut hi = DimI::from_elem(i64::MIN, ndim);
        for region in regions {
            for (d, r) in region.iter().enumerate() {
                lo[d] = lo[d].min(r[0]);
                hi[d] = hi[d].max(r[1]);
            }
        }
        let shape: DimU = (0..ndim)
            .map(|d| (hi[d] - lo[d] + 1).max(0) as usize)
            .collect();
        if shape.contains(&0) {
            bail_tape!("makearray: empty bounding-box axis (per-cell path)");
        }
        if values.iter().any(region_value_is_prefix_scan) {
            bail_tape!("makearray: prefix-scan region value (per-cell path)");
        }
        let bx = LBox {
            syms: &[],
            lo,
            shape,
            cnames: &[],
            cvals: SmallVec::new(),
        };
        let v = self.lower_makearray(node, &bx)?;
        Ok(self.reorigin_to_one(v))
    }

    /// A forward prefix scan (esm-spec §4.3.1) compiled as a whole-plane
    /// running fold along the scanned axis — the vectorized analogue of
    /// `run_prefix_scan`. Bit-identical: every output cell folds the same
    /// admitted window ascending in the same association (`acc = identity`,
    /// then `acc ⊕= term` per step, inclusive folding before the write and
    /// exclusive after), the fold is elementwise independent across the outer
    /// axes, and the per-step plane is evaluated with the same overlay-pinned
    /// instruction semantics as everything else.
    fn lower_prefix_scan(
        &mut self,
        idx_names: &[String],
        ranges: &[(i64, i64)],
        scan: PrefixScan,
        j_name: &str,
        body: &Expr,
        reduce: ReduceKind,
    ) -> LResult<LV> {
        let Some(combine_op) = reduce_combine_op(reduce) else {
            bail_tape!("scan: boolean reduction not compiled (per-cell path)");
        };
        let full_lo: DimI = ranges.iter().map(|(l, _)| *l).collect();
        let full_shape: DimU = ranges
            .iter()
            .map(|(l, h)| (h - l + 1).max(0) as usize)
            .collect();
        if full_shape.contains(&0) {
            bail_tape!("scan: empty output box (per-cell path)");
        }
        let (slo, shi) = ranges[scan.axis];
        // Step box: the full box with the scanned axis collapsed to extent 1.
        // The body never references the scanned OUTPUT symbol (the detector
        // rejects such bodies), so the step box's position along that axis is
        // pure metadata; pinning it at the axis lo lets every step's operands
        // share one box (and the accumulator chain type-check).
        let mut step_shape = full_shape.clone();
        step_shape[scan.axis] = 1;
        // Result base: zero-filled full box; every plane is overwritten once.
        let sec0 = self.placement(Cadence::Const);
        let mut cur = self.new_slot(&full_shape, &full_lo, false, sec0);
        self.emit(
            Instr::Fill {
                v: Operand::Lit(0.0),
                out: cur,
            },
            sec0,
        );
        let mut cur_cad = sec0;
        // `acc = identity` before the sweep; the first combine is
        // `identity ⊕ term` (NOT elided — `0.0 + (-0.0)` is `0.0`).
        let identity = reduce.identity();
        let mut acc = self.emit_fill(&LV::Lit(identity), &step_shape, &full_lo, Cadence::Const);
        // Bind BOTH the scanned output symbol and the contracted symbol to the
        // step position, exactly as `run_prefix_scan`'s `term_at` does.
        let cnames: Vec<String> = vec![idx_names[scan.axis].clone(), j_name.to_string()];
        for i in slo..=shi {
            self.push_scope();
            let bx = LBox {
                syms: idx_names,
                lo: full_lo.clone(),
                shape: step_shape.clone(),
                cnames: &cnames,
                cvals: SmallVec::from_slice(&[i, i]),
            };
            let term = self.lower_expr(body, &bx);
            self.pop_scope();
            let term = term?;
            if scan.inclusive {
                acc = self.emit_bin(combine_op, acc, term.clone())?;
            }
            // Write the current plane at scan position i (a direct region
            // write; shapes match by construction, so no box check needed).
            let LV::Arr(acc_slot) = &acc else {
                unreachable!("scan accumulator is always an array");
            };
            let acc_slot = *acc_slot;
            let region_ix = self.regions.len() as u32;
            let mut dest_lo: DimU = DimU::from_elem(0usize, full_shape.len());
            dest_lo[scan.axis] = (i - slo) as usize;
            self.regions.push(RegionSpec {
                dest_lo,
                shape: step_shape.clone(),
            });
            let want = cur_cad.max(self.lv_cadence(&acc));
            let sec = self.placement(want);
            let out = self.new_slot(&full_shape, &full_lo, false, sec);
            self.emit(
                Instr::Region {
                    base: cur,
                    src: Operand::Slot(acc_slot),
                    region: region_ix,
                    out,
                },
                sec,
            );
            cur = out;
            cur_cad = sec;
            if !scan.inclusive {
                acc = self.emit_bin(combine_op, acc, term)?;
            }
        }
        Ok(LV::Arr(cur))
    }

    /// Shared runtime-scalar-condition `ifelse` lowering (JmpIfZero + phi),
    /// parameterized over the branch-lowering recursion.
    fn lower_branchy_ifelse<F>(
        &mut self,
        cond: LV,
        t_expr: &Expr,
        f_expr: &Expr,
        mut low: F,
    ) -> LResult<LV>
    where
        F: FnMut(&mut Self, &Expr) -> LResult<LV>,
    {
        let mark = self.push_branch();
        let tv = match low(self, t_expr) {
            Ok(v) => v,
            Err(e) => {
                self.pop_branch(mark);
                return Err(e);
            }
        };
        let mut tbuf = self.pop_branch(mark);
        let mark = self.push_branch();
        let fv = match low(self, f_expr) {
            Ok(v) => v,
            Err(e) => {
                self.pop_branch(mark);
                return Err(e);
            }
        };
        let mut fbuf = self.pop_branch(mark);
        let tb = self.lv_box(&tv);
        let fb = self.lv_box(&fv);
        let (shape, origin, scalar) = match (&tb, &fb) {
            (None, None) => (DimU::new(), DimI::new(), true),
            (Some((s, o)), Some((s2, o2))) if s == s2 && o == o2 => (s.clone(), o.clone(), false),
            _ => bail_tape!("ifelse: branch value boxes differ under a runtime scalar condition"),
        };
        let phi = self.new_slot(&shape, &origin, scalar, self.home);
        tbuf.push(Instr::Copy {
            a: self.op_of(&tv),
            out: phi,
        });
        fbuf.push(Instr::Copy {
            a: self.op_of(&fv),
            out: phi,
        });
        let jmp = Instr::JmpIfZero {
            cond: self.op_of(&cond),
            n_true: tbuf.len() as u32,
            n_false: fbuf.len() as u32,
        };
        let sec = self.home;
        self.emit(jmp, sec);
        for i in tbuf {
            self.emit(i, sec);
        }
        for i in fbuf {
            self.emit(i, sec);
        }
        Ok(if scalar {
            LV::Scalar(phi)
        } else {
            LV::Arr(phi)
        })
    }

    /// Materialize an LV into a slot (for exports / dy writes of folded
    /// values).
    fn ensure_slot(&mut self, lv: &LV) -> SlotId {
        match lv {
            LV::Scalar(s) | LV::Arr(s) => *s,
            LV::Lit(_) | LV::Param(_) | LV::Time => {
                let sec = self.placement(self.lv_cadence(lv));
                let out = self.new_slot(&[], &[], true, sec);
                self.emit(
                    Instr::Fill {
                        v: self.op_of(lv),
                        out,
                    },
                    sec,
                );
                out
            }
            LV::State(_) | LV::Obs { .. } => {
                let (shape, origin, scalar) = match self.lv_box(lv) {
                    None => (DimU::new(), DimI::new(), true),
                    Some((s, o)) => (s, o, false),
                };
                let sec = self.placement(self.lv_cadence(lv));
                let out = self.new_slot(&shape, &origin, scalar, sec);
                self.emit(
                    Instr::Copy {
                        a: self.op_of(lv),
                        out,
                    },
                    sec,
                );
                out
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Rule-level driving, exports, liveness/coloring, report — in build().
// ---------------------------------------------------------------------------

/// Result of building the tape for one compiled model. Returns the program
/// and the `(scope, hoist)` value-numbering hit counts.
pub(super) fn build_tape_program(
    rhs_rules: &[RhsRule],
    observed_rules: &[AlgebraicRule],
    var_shapes: &IndexMap<String, VarShape>,
    param_names: &[String],
    const_names: &HashSet<String>,
    seg_invariant_names: &HashSet<String>,
) -> (TapeProgram, (usize, usize)) {
    let observed_names: HashSet<String> = observed_rules
        .iter()
        .map(|r| observed_rule_var(r).clone())
        .collect();
    let mut obs_tier: FxHashMap<String, Cadence> = FxHashMap::default();
    for r in observed_rules {
        let name = observed_rule_var(r);
        let tier = if const_names.contains(name) {
            Cadence::Const
        } else if seg_invariant_names.contains(name) {
            Cadence::Segment
        } else {
            Cadence::Continuous
        };
        obs_tier.insert(name.clone(), tier);
    }

    let mut b = TapeBuilder::new(var_shapes, param_names, obs_tier);

    // ---- observed rules, in dependency order -------------------------------
    for (i, rule) in observed_rules.iter().enumerate() {
        let name = observed_rule_var(rule).clone();
        let tier = *b.obs_tier.get(&name).expect("tier classified");
        b.begin_rule(RuleInfo {
            name: name.clone(),
            kind: RuleKind::Observed(i),
            cadence: tier,
            status: RuleStatus::Taped,
        });
        let txn = b.txn();
        let lowered = b.lower_observed_rule(rule);
        match lowered {
            Ok(obs_val) => {
                b.obs_defined.insert(name, obs_val);
            }
            Err(bail) => {
                b.rollback(txn);
                let ord = b.cur_rule;
                b.emit(Instr::Fallback { rule: ord }, b.home);
                b.rules[ord as usize].status = RuleStatus::Fallback(bail.reason);
                let shape = fallback_observed_shape(rule);
                b.obs_defined.insert(name, ObsVal::External { shape, tier });
            }
        }
        b.end_rule();
    }

    // ---- RHS rules ---------------------------------------------------------
    for (i, rule) in rhs_rules.iter().enumerate() {
        let name = match rule {
            RhsRule::Scalar { slot, .. } => format!("D(slot {slot})"),
            RhsRule::IndexedScalar { slot, .. } => format!("D(slot {slot})"),
            RhsRule::ArrayLoop { var_name, .. } => format!("D({var_name})"),
        };
        b.begin_rule(RuleInfo {
            name,
            kind: RuleKind::Rhs(i),
            cadence: Cadence::Continuous,
            status: RuleStatus::Taped,
        });
        let txn = b.txn();
        match b.lower_rhs_rule(rule) {
            Ok(()) => {}
            Err(bail) => {
                b.rollback(txn);
                let ord = b.cur_rule;
                b.emit(Instr::Fallback { rule: ord }, b.home);
                b.rules[ord as usize].status = RuleStatus::Fallback(bail.reason);
            }
        }
        b.end_rule();
    }

    // ---- exports -----------------------------------------------------------
    let exports = b.compute_exports(observed_rules, rhs_rules, &observed_names);

    // ---- flatten + liveness + coloring -------------------------------------
    let vn_hits = b.vn_hits();
    (b.finish(exports), vn_hits)
}

/// The statically-known runtime shape of a fallback observed rule's value
/// (origin-1 convention), or `None` when it cannot be known without
/// evaluating.
fn fallback_observed_shape(rule: &AlgebraicRule) -> Option<DimU> {
    match rule {
        // The per-cell (and vectorized) ArrayLoop paths both materialize the
        // padded `[1, hi]` box.
        AlgebraicRule::ArrayLoop { output_ranges, .. } => Some(
            output_ranges
                .iter()
                .map(|(_, hi)| (*hi).max(0) as usize)
                .collect(),
        ),
        AlgebraicRule::Scalar { body, .. } => match &**body {
            Expr::Operator(node) if node.op == "aggregate" => {
                let spec = arrayop_spec(node)?;
                Some(
                    spec.ranges
                        .iter()
                        .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                        .collect(),
                )
            }
            Expr::Operator(node) if node.op == "makearray" => {
                let regions = node.regions.as_ref()?;
                let first = regions.first()?;
                let ndim = first.len();
                if regions.iter().any(|r| r.len() != ndim) {
                    return None;
                }
                let mut lo = vec![i64::MAX; ndim];
                let mut hi = vec![i64::MIN; ndim];
                for region in regions {
                    for (d, r) in region.iter().enumerate() {
                        lo[d] = lo[d].min(r[0]);
                        hi[d] = hi[d].max(r[1]);
                    }
                }
                Some(
                    (0..ndim)
                        .map(|d| (hi[d] - lo[d] + 1).max(0) as usize)
                        .collect(),
                )
            }
            // A literal / scalar-arithmetic body materializes 0-d; anything
            // else (an array alias, a reshape, …) is unknowable statically.
            Expr::Number(_) | Expr::Integer(_) => Some(DimU::new()),
            _ => None,
        },
    }
}

impl<'m> TapeBuilder<'m> {
    fn begin_rule(&mut self, info: RuleInfo) {
        self.cur_rule = self.rules.len() as u32;
        self.home = info.cadence;
        self.rules.push(info);
        self.rule_home_chunk.push(None);
        self.scope_frames.clear();
        self.branch_bufs.clear();
        self.hoist_journal.clear();
    }

    fn end_rule(&mut self) {
        // Record the rule's home-stream chunk (for export insertion).
        let stream = &self.streams[self.home as usize];
        if let Some((idx, c)) = stream.iter().enumerate().last() {
            if c.rule == self.cur_rule {
                self.rule_home_chunk[self.cur_rule as usize] = Some(idx);
            }
        }
        debug_assert!(self.scope_frames.is_empty());
        debug_assert!(self.branch_bufs.is_empty());
    }

    fn txn(&self) -> RuleTxn {
        RuleTxn {
            slots: self.slots.len(),
            plans: self.plans.len(),
            regions: self.regions.len(),
            dy_writes: self.dy_writes.len(),
            stream_lens: [
                self.streams[0].len(),
                self.streams[1].len(),
                self.streams[2].len(),
            ],
            hoist_journal: self.hoist_journal.len(),
        }
    }

    /// Roll back everything the current rule's failed lowering emitted.
    fn rollback(&mut self, txn: RuleTxn) {
        self.slots.truncate(txn.slots);
        self.plans.truncate(txn.plans);
        self.regions.truncate(txn.regions);
        self.dy_writes.truncate(txn.dy_writes);
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
        self.scope_frames.clear();
        self.branch_bufs.clear();
    }

    /// Lower one observed rule; returns the recorded observed value.
    fn lower_observed_rule(&mut self, rule: &AlgebraicRule) -> LResult<ObsVal> {
        match rule {
            AlgebraicRule::ArrayLoop {
                output_idx_names,
                output_ranges,
                body,
                ..
            } => {
                // Mirror of `materialize_observeds_append`'s vectorized-path
                // guard: 1-origin ranges over a non-empty padded box.
                let padded_shape: Vec<usize> =
                    output_ranges.iter().map(|(_, hi)| *hi as usize).collect();
                if output_ranges.is_empty() {
                    bail_tape!("observed: rank-0 ArrayLoop");
                }
                if !output_ranges.iter().all(|(lo, _)| *lo == 1) {
                    bail_tape!("observed: non-unit-origin output ranges (per-cell path)");
                }
                if padded_shape.contains(&0) {
                    bail_tape!("observed: empty padded box (per-cell path)");
                }
                let v = self.lower_arrayop(
                    output_idx_names,
                    output_ranges,
                    body,
                    &[],
                    &[],
                    ReduceKind::Sum,
                    None,
                )?;
                // Origin is all-1 by the guard, so no re-origin copy needed.
                Ok(ObsVal::Taped(v))
            }
            AlgebraicRule::Scalar { body, .. } => {
                // The whole-body `eval` mirror: covers scalar algebra, whole-
                // array elementwise algebra, top-level aggregates (incl. the
                // prefix-scan sweep) and makearrays. Readers see materialized
                // arrays at origin 1s.
                let v = self.lower_wholesale(body)?;
                let v = self.reorigin_to_one(v);
                Ok(ObsVal::Taped(v))
            }
        }
    }

    /// Copy an array LV into a slot whose origin is all-1s (the convention
    /// under which readers see a materialized observed). No-op when already.
    fn reorigin_to_one(&mut self, v: LV) -> LV {
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

    /// Lower one RHS rule, emitting its `DyWrite`.
    fn lower_rhs_rule(&mut self, rule: &RhsRule) -> LResult<()> {
        match rule {
            RhsRule::Scalar { slot, body } | RhsRule::IndexedScalar { slot, body } => {
                let v = self.lower_wholesale(body)?;
                // The oracle scalarizes: an array-valued body writes the NaN
                // sentinel (`eval(body).as_scalar().unwrap_or(NAN)`).
                let v = if self.lv_box(&v).is_some() {
                    LV::Lit(f64::NAN)
                } else {
                    v
                };
                let s = self.ensure_slot(&v);
                let w = self.dy_writes.len() as u32;
                self.dy_writes.push(DyWrite {
                    slot: s,
                    var: 0,
                    dest_lo: SmallVec::new(),
                    scalar_flat: Some(*slot),
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
                let Some(shifts) = lhs_constant_shifts(lhs_idx_exprs, output_idx_names) else {
                    bail_tape!("rule: LHS is not a constant per-axis shift of the output indices");
                };
                let Some(dest_lo) = subblock_dest(vs, output_ranges, &shifts) else {
                    bail_tape!("rule: shifted output box does not fit the variable block");
                };
                let v = self.lower_arrayop(
                    output_idx_names,
                    output_ranges,
                    body,
                    contract_names,
                    contract_dims,
                    *reduce,
                    filter.as_deref(),
                )?;
                let s = self.ensure_slot(&v);
                let var_ix = *self.state_ix.get(var_name).expect("state var known");
                let w = self.dy_writes.len() as u32;
                self.dy_writes.push(DyWrite {
                    slot: s,
                    var: var_ix,
                    dest_lo,
                    scalar_flat: None,
                });
                self.emit(Instr::DyWrite { write: w }, Cadence::Continuous);
                Ok(())
            }
        }
    }

    /// Names to publish into the runtime observed map: everything a fallback
    /// rule reads, plus the samples/observed-trajectory dependency cone
    /// (mirroring `append_scalar_observed_trajectories`'s probe seeds).
    fn compute_exports(
        &mut self,
        observed_rules: &[AlgebraicRule],
        rhs_rules: &[RhsRule],
        observed_names: &HashSet<String>,
    ) -> Vec<(String, SlotId)> {
        let mut needed: HashSet<String> = HashSet::new();

        // (a) Direct observed reads of every fallback rule body: the
        // interpreter resolves them through the runtime observed map, so a
        // taped producer must publish there.
        for info in self.rules.clone() {
            if !matches!(info.status, RuleStatus::Fallback(_)) {
                continue;
            }
            let mut refs = HashSet::new();
            match info.kind {
                RuleKind::Observed(i) => {
                    collect_expr_var_refs(observed_rule_body(&observed_rules[i]), &mut refs)
                }
                RuleKind::Rhs(i) => match &rhs_rules[i] {
                    RhsRule::Scalar { body, .. } | RhsRule::IndexedScalar { body, .. } => {
                        collect_expr_var_refs(body, &mut refs)
                    }
                    RhsRule::ArrayLoop { body, filter, .. } => {
                        collect_expr_var_refs(body, &mut refs);
                        if let Some(f) = filter {
                            collect_expr_var_refs(f, &mut refs);
                        }
                    }
                },
            }
            for r in refs {
                if observed_names.contains(&r) {
                    needed.insert(r);
                }
            }
        }

        // (b) The samples pass' probe cone: potentially-scalar observeds and
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
                continue; // fallback-produced: already in the map at run time
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
                Some(ci) => self.streams[home as usize][ci].instrs.push(instr),
                None => {
                    // The rule emitted nothing into its home stream (its whole
                    // value hoisted to an earlier section): open a chunk now.
                    self.streams[home as usize].push(Chunk {
                        rule: rule_ord as u32,
                        instrs: vec![instr],
                    });
                    // Note: appended at the END of the stream, which keeps
                    // every consumer ordering valid only because a fallback
                    // reader in the SAME stream always sits in a later chunk
                    // than the producer would... to stay strictly safe, only
                    // rules that emitted nothing anywhere can take this path,
                    // and their export value lives in an earlier section, so
                    // any same-stream reader still reads a defined slot.
                }
            }
            exports.push((name, slot));
        }
        exports
    }

    /// `ensure_slot` variant used by the export pass, which appends into an
    /// arbitrary earlier rule's chunk rather than the live tail.
    fn ensure_slot_at_rule(&mut self, lv: &LV, rule: u32, home: Cadence) -> SlotId {
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
                    Some(ci) => self.streams[home as usize][ci].instrs.push(instr),
                    None => {
                        self.streams[home as usize].push(Chunk {
                            rule,
                            instrs: vec![instr],
                        });
                        self.rule_home_chunk[rule as usize] =
                            Some(self.streams[home as usize].len() - 1);
                    }
                }
                out
            }
        }
    }

    /// Flatten the chunk streams, run liveness + slab coloring, and assemble
    /// the final program.
    fn finish(mut self, exports: Vec<(String, SlotId)>) -> TapeProgram {
        let mut instrs: Vec<Instr> = Vec::new();
        let mut provenance: Vec<u32> = Vec::new();
        let mut n_const = 0u32;
        let mut n_segment = 0u32;
        for (sec, stream) in self.streams.iter_mut().enumerate() {
            let start = instrs.len();
            for chunk in stream.drain(..) {
                provenance.extend(std::iter::repeat_n(chunk.rule, chunk.instrs.len()));
                instrs.extend(chunk.instrs);
            }
            let count = (instrs.len() - start) as u32;
            match sec {
                0 => n_const = count,
                1 => n_segment = count,
                _ => {}
            }
        }

        let mut prog = TapeProgram {
            instrs,
            n_const,
            n_segment,
            slots: std::mem::take(&mut self.slots),
            plans: std::mem::take(&mut self.plans),
            regions: std::mem::take(&mut self.regions),
            state_vars: std::mem::take(&mut self.state_vars),
            obs_reads: std::mem::take(&mut self.obs_reads),
            dy_writes: std::mem::take(&mut self.dy_writes),
            exports,
            rules: std::mem::take(&mut self.rules),
            slab: SlabLayout::default(),
            provenance,
            params_len: self.param_names.len(),
        };
        color_slab(&mut prog);
        prog
    }

    pub(crate) fn vn_hits(&self) -> (usize, usize) {
        (self.vn_scope_hits, self.vn_hoist_hits)
    }
}

// ---------------------------------------------------------------------------
// Liveness + greedy interval slab coloring.
// ---------------------------------------------------------------------------

/// Assign each slot a storage bucket. Cross-section-live slots (a CONST ramp
/// read by the CONTINUOUS section every call) get dedicated storages; slots
/// whose whole lifetime sits inside one section recycle storage greedily by
/// element count (linear-scan last-use over the straight-line program —
/// conservative and sound under the structured `JmpIfZero` skips, which only
/// ever shorten execution).
fn color_slab(prog: &mut TapeProgram) {
    let n_slots = prog.slots.len();
    let mut def: Vec<usize> = vec![usize::MAX; n_slots];
    let mut last_use: Vec<usize> = vec![0; n_slots];
    for (i, instr) in prog.instrs.iter().enumerate() {
        if let Some(out) = instr.out() {
            let d = &mut def[out as usize];
            if *d == usize::MAX {
                *d = i;
            } else {
                // A RE-definition (the phi slot's second branch `Copy`): the
                // storage must stay reserved through it, so count it as a use.
                last_use[out as usize] = last_use[out as usize].max(i);
            }
        }
        instr.for_each_read(&prog.dy_writes, |s| {
            last_use[s as usize] = last_use[s as usize].max(i);
        });
    }

    // Persistence: read from a later section than the defining one.
    let mut dedicated: Vec<bool> = vec![false; n_slots];
    for s in 0..n_slots {
        if def[s] == usize::MAX {
            continue; // never defined (unused slot — possible after rollbacks)
        }
        let def_sec = prog.section_of(def[s]);
        let use_sec = prog.section_of(last_use[s].max(def[s]));
        if use_sec > def_sec {
            dedicated[s] = true;
        }
    }

    // Storage assignment.
    let mut storages: Vec<StorageDesc> = Vec::new();
    // Free storages per element count (recycled class only).
    let mut free: FxHashMap<usize, Vec<u32>> = FxHashMap::default();
    // Slots whose storage frees after instruction i: (i → slots).
    let mut dying_at: Vec<Vec<u32>> = vec![Vec::new(); prog.instrs.len() + 1];
    for s in 0..n_slots {
        if def[s] != usize::MAX && !dedicated[s] {
            dying_at[last_use[s].max(def[s])].push(s as u32);
        }
    }

    for i in 0..prog.instrs.len() {
        // Aliasing hazard: a Gather/Region reads its source through shifted
        // offsets while writing out, so out must not reuse a source buffer
        // freed by this very instruction. Release dying operands BEFORE
        // allocating out only for alias-safe (index-aligned elementwise)
        // instructions.
        let alias_safe = !matches!(prog.instrs[i], Instr::Gather { .. } | Instr::Region { .. });
        let out = prog.instrs[i].out();
        let is_first_def = out.is_some_and(|o| def[o as usize] == i);
        if alias_safe {
            for &s in &dying_at[i] {
                let st = prog.slots[s as usize].storage;
                if st != u32::MAX {
                    free.entry(storages[st as usize].elems)
                        .or_default()
                        .push(st);
                }
            }
        }
        if let (Some(o), true) = (out, is_first_def) {
            let desc = &prog.slots[o as usize];
            let elems = desc.elems();
            let storage = if dedicated[o as usize] {
                storages.push(StorageDesc {
                    elems,
                    offset: 0,
                    cadence: desc.cadence,
                    dedicated: true,
                });
                (storages.len() - 1) as u32
            } else if let Some(st) = free.get_mut(&elems).and_then(|v| v.pop()) {
                st
            } else {
                storages.push(StorageDesc {
                    elems,
                    offset: 0,
                    cadence: desc.cadence,
                    dedicated: false,
                });
                (storages.len() - 1) as u32
            };
            prog.slots[o as usize].storage = storage;
        }
        if !alias_safe {
            for &s in &dying_at[i] {
                let st = prog.slots[s as usize].storage;
                if st != u32::MAX {
                    free.entry(storages[st as usize].elems)
                        .or_default()
                        .push(st);
                }
            }
        }
    }

    // Flat offsets + summary.
    let mut offset = 0usize;
    let mut const_elems = 0usize;
    let mut segment_elems = 0usize;
    let mut recycled_elems = 0usize;
    for st in &mut storages {
        st.offset = offset;
        offset += st.elems;
        if st.dedicated {
            match st.cadence {
                Cadence::Const => const_elems += st.elems,
                Cadence::Segment => segment_elems += st.elems,
                Cadence::Continuous => recycled_elems += st.elems,
            }
        } else {
            recycled_elems += st.elems;
        }
    }
    prog.slab = SlabLayout {
        storages,
        total_elems: offset,
        const_elems,
        segment_elems,
        recycled_elems,
    };
}
