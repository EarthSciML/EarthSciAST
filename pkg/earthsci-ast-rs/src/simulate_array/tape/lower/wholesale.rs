//! Whole-array bodies: a rule body lowered as the per-cell `eval` reads
//! it, its array operations whole (elementwise, transpose, reshape,
//! concatenation, index, aggregate), and the standalone scalar reduction.

use super::*;
use crate::op_registry::{CoreOp, OtherOp as O};

impl<'m> TapeBuilder<'m> {
    // -- wholesale-body lowering (the per-cell `eval` mirror) -----------------
    //
    // A `Scalar` rule's body — a declared observed's whole expression, or a
    // 0-d state's RHS — is evaluated by the per-cell oracle's `eval`
    // WHOLESALE: a variable reference resolves to the whole array, elementwise
    // arithmetic broadcasts over it, and a top-level `faq`/`makearray`
    // materializes its own box (`eval_faq` / `eval_makearray`). This mirror covers the
    // wholesale algebra where it agrees exactly with the tape's instruction
    // semantics:
    //
    //   * equal-shape (or scalar-broadcast) elementwise operands — `combine` /
    //     `broadcast_binary` reduce to the aligned Zip that `Instr::Bin`
    //     performs; a rank/shape mismatch (Julia trailing-pad broadcast) bails;
    //   * every wholesale array is origin-normalized to all-1s, matching how
    //     `lookup_variable` serves stored arrays (origin-blind).
    pub(super) fn lower_wholesale(&mut self, e: &Expr) -> LResult<LV> {
        match e {
            Expr::Number(n) => Ok(LV::Lit(crate::precision::round(*n))),
            Expr::Integer(n) => Ok(LV::Lit(crate::precision::round(*n as f64))),
            Expr::Variable(name) => self.resolve_wholesale_var(name),
            Expr::Operator(node) => {
                if !self.rule.scope_frames.last().is_some_and(|f| f.wholesale) {
                    return self.lower_wholesale_op(node);
                }
                let key = VnKey::Node(Arc::as_ptr(node) as usize);
                if let Some(hit) = self.rule.scope_frames.last().and_then(|f| f.map.get(&key)) {
                    self.vn_scope_hits += 1;
                    return Ok(hit.clone());
                }
                // A node whose lowering notes a fault is not shared: where
                // the fault sorts depends on the occurrence.
                let notes = self.fault.notes;
                let lv = self.lower_wholesale_op(node)?;
                if self.fault.notes == notes
                    && self.rule.scope_frames.last().is_some_and(|f| f.wholesale)
                {
                    self.frame_put(key, &lv);
                }
                Ok(lv)
            }
        }
    }

    /// Mirror of `lookup_variable` (no loop binds on the compiled-rule path):
    /// `t`, state, observed, parameter, else bail (production would read
    /// forcing or the NaN sentinel — the interpreter handles both).
    pub(super) fn resolve_wholesale_var(&mut self, name: &str) -> LResult<LV> {
        if name == "t" {
            return Ok(LV::Time);
        }
        if let Some(&ix) = self.state_ix.get(name) {
            return Ok(LV::State(tape_index(ix, "state variables")?));
        }
        if let Some(ov) = self.obs_defined.get(name).cloned() {
            return match ov {
                ObsVal::Taped(lv) => Ok(lv),
                ObsVal::Declined => {
                    bail_tape!("variable: observed `{name}` is produced by a declined rule")
                }
            };
        }
        if let Some(&i) = self.param_ix.get(name) {
            return Ok(LV::Param(tape_index(i, "parameters")?));
        }
        if let Some(lv) = self.forcing_read(name)? {
            return Ok(lv);
        }
        bail_tape!("wholesale: unresolved symbol (forcing/NaN sentinel?) `{name}`")
    }

    pub(super) fn lower_wholesale_op(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        self.lower_wholesale_op_named(node.op.as_str(), node)
    }

    /// [`Self::lower_wholesale_op`] with the operator name given separately, so
    /// the `broadcast` arm can re-enter with its `fn` against the SAME node —
    /// the oracle's `eval_broadcast` → `eval_op_named` (esm-spec §4.3.4).
    pub(super) fn lower_wholesale_op_named(
        &mut self,
        op: &str,
        node: &Arc<ExpressionNode>,
    ) -> LResult<LV> {
        let Some(core) = CoreOp::from_name(op) else {
            bail_tape!("wholesale: unsupported op `{op}`");
        };
        match core {
            CoreOp::Unary(_)
            | CoreOp::Compare(_)
            | CoreOp::Other(
                O::Add
                | O::Sub
                | O::Mul
                | O::Div
                | O::Pow
                | O::PowWord
                | O::Min
                | O::Max
                | O::And
                | O::Or
                | O::Neg
                | O::Not
                | O::Atan2,
            ) => self.lower_wholesale_elementwise(op, node, None),
            CoreOp::Other(O::Ifelse) => {
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
                    None => self.lower_branchy_ifelse(
                        cond,
                        &node.args[1],
                        &node.args[2],
                        false,
                        |s, e| s.lower_wholesale(e),
                    ),
                    Some(_) => {
                        let a = self.lower_wholesale(&node.args[1])?;
                        let b = self.lower_wholesale(&node.args[2])?;
                        self.emit_select_wholesale(cond, a, b)
                    }
                }
            }
            // Unreachable: esm-spec §4.2's right-hand-side `D` is resolved to a
            // tendency by `flatten`'s phase 5b′, or refused with
            // `unlowered_operator` before this lowering runs. `NaN` is the
            // sentinel that cannot be mistaken for a result.
            CoreOp::Other(O::D) => Ok(LV::Lit(f64::NAN)),
            CoreOp::Other(O::Pre) => match node.args.first() {
                None => Ok(LV::Lit(f64::NAN)),
                Some(a) => self.lower_wholesale(a),
            },
            CoreOp::Other(O::Const) => match eval_const(node) {
                Value::Scalar(s) => Ok(LV::Lit(s)),
                // The wholesale `eval` serves an inline array literal as the
                // whole array, origin-blind — which is exactly a materialized
                // 1-origin box. `Instr::ConstArray` stores it once per solve.
                Value::Array(a) => self.const_literal_array(node, &a, None),
            },
            CoreOp::Other(O::True) => Ok(LV::Lit(1.0)),
            CoreOp::Other(O::False) => Ok(LV::Lit(0.0)),
            CoreOp::Other(O::Broadcast) => {
                let Some(fn_name) = node.broadcast_fn.as_deref() else {
                    bail_tape!("wholesale: `broadcast` with no `fn`");
                };
                if !crate::op_registry::is_scalar_operator(fn_name) {
                    bail_tape!("wholesale: broadcast fn `{fn_name}` is not a scalar operator");
                }
                self.lower_wholesale_op_named(fn_name, node)
            }
            CoreOp::Other(O::Precision) => {
                let (arg, _precision) = self.marker_operand(node)?;
                self.lower_wholesale(arg)
            }
            CoreOp::Other(O::Reshape) => self.lower_wholesale_reshape(node),
            CoreOp::Other(O::Transpose) => self.lower_wholesale_transpose(node),
            CoreOp::Other(O::Concat) => self.lower_wholesale_concat(node),
            CoreOp::Other(O::Index) => self.lower_wholesale_index(node),
            CoreOp::Other(O::Faq) => self.lower_wholesale_aggregate(node),
            CoreOp::Other(O::Makearray) => self.lower_wholesale_makearray(node),
            CoreOp::Other(O::ApplyExpressionTemplate) => self.lower_call_wholesale(node),
            CoreOp::Other(O::Ic | O::Enum | O::Distinct) => {
                bail_tape!("wholesale: unsupported op `{op}`")
            }
        }
    }

    /// The elementwise arms of [`Self::lower_wholesale_op_named`] (every op
    /// except `ifelse`). With `shape`, the op is on the value path of an
    /// observed declaring that box, and an operand holding an `ifelse` there
    /// is lowered by [`Self::lower_wholesale_shaped`]: the oracle fills the
    /// rule's scalar result over the box, and an elementwise op over a scalar
    /// filled into the box gives every cell the same value, so a scalar arm
    /// may be filled into its array arm's box before the op rather than
    /// after it. Anywhere else the oracle's result rank follows the taken arm,
    /// and mixed arms stay refused.
    pub(super) fn lower_wholesale_elementwise(
        &mut self,
        op: &str,
        node: &Arc<ExpressionNode>,
        shape: Option<&[usize]>,
    ) -> LResult<LV> {
        let Some(core) = CoreOp::from_name(op) else {
            bail_tape!("wholesale: `{op}` is not an elementwise op");
        };
        match core {
            // n-ary arithmetic + logical connectives: `eval_arith` is a left
            // fold of `apply_binary` over scalars AND arrays (the all-scalar
            // `fold_scalar` and the `and`/`or` all/any forms agree with the
            // left fold at every legal arity), so a chained `Bin` reproduces
            // it bit for bit — for equal-shape operands.
            CoreOp::Other(
                O::Add
                | O::Sub
                | O::Mul
                | O::Div
                | O::Pow
                | O::PowWord
                | O::Min
                | O::Max
                | O::And
                | O::Or,
            ) => {
                let Some((first, rest)) = node.args.split_first() else {
                    return Ok(LV::Lit(f64::NAN)); // fold_scalar's empty-arity sentinel
                };
                if core == CoreOp::Other(O::Sub) && rest.is_empty() {
                    let v = self.lower_wholesale_operand(shape, first)?;
                    return self.emit_neg(v);
                }
                let mut acc = self.lower_wholesale_operand(shape, first)?;
                for a in rest {
                    let v = self.lower_wholesale_operand(shape, a)?;
                    acc = self.emit_bin_wholesale(BinCode::from_core(core), acc, v)?;
                }
                Ok(acc)
            }
            CoreOp::Other(O::Neg) => {
                if node.args.len() != 1 {
                    return Ok(LV::Lit(f64::NAN));
                }
                let v = self.lower_wholesale_operand(shape, &node.args[0])?;
                self.emit_neg(v)
            }
            CoreOp::Unary(_) | CoreOp::Other(O::Not) => {
                // `eval_unary` evaluates args[0] only; no args ⇒ NaN sentinel.
                let Some(first) = node.args.first() else {
                    return Ok(LV::Lit(f64::NAN));
                };
                let v = self.lower_wholesale_operand(shape, first)?;
                Ok(self.emit_un(UnCode::of(op), v))
            }
            CoreOp::Other(O::Atan2) => {
                // `eval_binary`: first two args, NaN sentinel below arity 2.
                let ([a, b] | [a, b, ..]) = &node.args[..] else {
                    return Ok(LV::Lit(f64::NAN));
                };
                let av = self.lower_wholesale_operand(shape, a)?;
                let bv = self.lower_wholesale_operand(shape, b)?;
                self.emit_bin_wholesale(BinCode::Atan2, av, bv)
            }
            CoreOp::Compare(_) => {
                if node.args.len() != 2 {
                    return Ok(LV::Lit(f64::NAN));
                }
                let av = self.lower_wholesale_operand(shape, &node.args[0])?;
                let bv = self.lower_wholesale_operand(shape, &node.args[1])?;
                self.emit_bin_wholesale(BinCode::from_core(core), av, bv)
            }
            CoreOp::Other(
                O::Precision
                | O::Ifelse
                | O::D
                | O::Ic
                | O::Pre
                | O::Const
                | O::True
                | O::False
                | O::Enum
                | O::ApplyExpressionTemplate
                | O::Faq
                | O::Makearray
                | O::Index
                | O::Broadcast
                | O::Reshape
                | O::Transpose
                | O::Concat
                | O::Distinct,
            ) => bail_tape!("wholesale: `{op}` is not an elementwise op"),
        }
    }

    /// One operand of [`Self::lower_wholesale_elementwise`].
    pub(super) fn lower_wholesale_operand(
        &mut self,
        shape: Option<&[usize]>,
        e: &Expr,
    ) -> LResult<LV> {
        match shape {
            Some(shape) if value_path_has_ifelse(e) => self.lower_wholesale_shaped(e, shape),
            _ => self.lower_wholesale(e),
        }
    }

    /// `combine` on the wholesale path: two arrays of different shapes
    /// broadcast first (`broadcast_binary` — esm-spec §4.3.4's positional
    /// rule for operands with no declared index sets: left-aligned, the
    /// lower rank padded with TRAILING singletons). Shapes that do not
    /// broadcast give the oracle's `NaN` array.
    pub(super) fn emit_bin_wholesale(&mut self, code: BinCode, a: LV, b: LV) -> LResult<LV> {
        if let (Some((sa, _)), Some((sb, _))) = (self.lv_box(&a), self.lv_box(&b))
            && sa != sb
        {
            if sa.contains(&0) || sb.contains(&0) {
                bail_tape!("wholesale: broadcast of an empty array");
            }
            let target = broadcast_shape(&sa, &sb);
            if target.contains(&0) {
                // `broadcast_binary`'s NaN sentinel, over the target with the
                // clashing extent read as 1.
                let nan_shape: DimU = target.iter().map(|&d| d.max(1)).collect();
                let ones = DimI::from_elem(1, nan_shape.len());
                return Ok(self.emit_fill(&LV::Lit(f64::NAN), &nan_shape, &ones, Cadence::Const));
            }
            let a = self.broadcast_to(a, &target)?;
            let b = self.broadcast_to(b, &target)?;
            return self.emit_bin(code, a, b);
        }
        self.emit_bin(code, a, b)
    }

    /// `eval_ifelse` under an ARRAY condition: the condition and both arms
    /// broadcast to one target, then select element by element.
    pub(super) fn emit_select_wholesale(&mut self, cond: LV, a: LV, b: LV) -> LResult<LV> {
        let mut target: SmallVec<[usize; 4]> = SmallVec::new();
        for v in [&cond, &a, &b] {
            if let Some((sh, _)) = self.lv_box(v) {
                target = broadcast_shape(&target, &sh).into();
            }
        }
        if target.contains(&0) {
            bail_tape!("wholesale: `ifelse` operands whose shapes do not broadcast");
        }
        let cond = self.broadcast_to(cond, &target)?;
        let a = self.broadcast_to(a, &target)?;
        let b = self.broadcast_to(b, &target)?;
        self.emit_select(cond, a, b)
    }

    /// The body of an observed that DECLARES `shape`, which the oracle
    /// materializes as `eval(body)` with a scalar filled over `shape`.
    ///
    /// Plain [`Self::lower_wholesale`] plus that fill — except that an
    /// `ifelse` under a runtime SCALAR condition returns ONE of its arms
    /// verbatim, scalar or array, so the fill belongs inside each arm: both
    /// arms then carry the declared box and join on one phi. (Filling after
    /// the join is not expressible: the phi needs one box on both arms.)
    pub(super) fn lower_wholesale_shaped(&mut self, e: &Expr, shape: &[usize]) -> LResult<LV> {
        let ones = DimI::from_elem(1, shape.len());
        let op = match e {
            Expr::Operator(node) => crate::op_registry::elementwise_op(node).map(|op| (op, node)),
            _ => None,
        };
        if let Some(("ifelse", node)) = op
            && node.args.len() == 3
        {
            let cond = self.lower_wholesale(&node.args[0])?;
            if let LV::Lit(c) = cond {
                let taken = if c != 0.0 {
                    &node.args[1]
                } else {
                    &node.args[2]
                };
                return self.lower_wholesale_shaped(taken, shape);
            }
            if self.lv_box(&cond).is_none() {
                return self.lower_branchy_ifelse(
                    cond,
                    &node.args[1],
                    &node.args[2],
                    false,
                    |s, e| s.lower_wholesale_shaped(e, shape),
                );
            }
            let a = self.lower_wholesale(&node.args[1])?;
            let b = self.lower_wholesale(&node.args[2])?;
            let v = self.emit_select_wholesale(cond, a, b)?;
            return Ok(v);
        }
        let v = match op {
            Some((op, node)) if node.args.iter().any(value_path_has_ifelse) => {
                self.lower_wholesale_elementwise(op, node, Some(shape))?
            }
            _ => self.lower_wholesale(e)?,
        };
        Ok(if self.lv_box(&v).is_none() {
            self.emit_fill(&v, shape, &ones, Cadence::Const)
        } else {
            v
        })
    }

    /// `v` broadcast to the whole-array box `target` (origin all-1s) under
    /// the trailing-pad rule: a scalar stays a scalar (every instruction
    /// broadcasts it), an array of that shape stays as it is, and any other
    /// array is gathered — each of its axes of extent 1 held at its one
    /// element, each padded axis broadcast.
    pub(super) fn broadcast_to(&mut self, v: LV, target: &[usize]) -> LResult<LV> {
        let Some((shape, _)) = self.lv_box(&v) else {
            return Ok(v);
        };
        if shape.as_slice() == target {
            return Ok(v);
        }
        if shape.len() > target.len() {
            bail_tape!("wholesale: broadcast to a lower rank");
        }
        let mut fixed_desc: SmallVec<[(usize, usize); 4]> = SmallVec::new();
        let mut mapped_src: SmallVec<[usize; 4]> = SmallVec::new();
        let mut flags: SmallVec<[bool; 4]> = SmallVec::new();
        let mut segs: SmallVec<[SmallVec<[(usize, usize, usize); 2]>; 4]> = SmallVec::new();
        for (a, &n) in target.iter().enumerate() {
            let mut one = SmallVec::new();
            one.push((0usize, n, 0usize));
            segs.push(one);
            match shape.get(a) {
                Some(&m) if m == n => {
                    mapped_src.push(a);
                    flags.push(true);
                }
                Some(&1) => {
                    fixed_desc.push((a, 0));
                    flags.push(false);
                }
                Some(_) => bail_tape!("wholesale: shapes that do not broadcast"),
                None => flags.push(false),
            }
        }
        let ones = DimI::from_elem(1, target.len());
        Ok(self.emit_gather(&v, fixed_desc, &mapped_src, flags, segs, target, &ones))
    }

    /// `eval_transpose`: the operand's axes permuted (`perm`, default the
    /// reversal) — one [`Instr::Gather`] with the permutation and no shift.
    pub(super) fn lower_wholesale_transpose(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let Some(arg0) = node.args.first() else {
            return Ok(LV::Lit(f64::NAN));
        };
        let v = self.lower_wholesale(arg0)?;
        let Some((shape, _)) = self.lv_box(&v) else {
            return Ok(v);
        };
        let nd = shape.len();
        let perm: SmallVec<[usize; 4]> = match &node.perm {
            Some(p) => {
                let mut seen = SmallVec::<[bool; 4]>::from_elem(false, nd);
                let mut out = SmallVec::new();
                for &x in p {
                    let ok = x >= 0 && (x as usize) < nd && !seen[x as usize];
                    if !ok {
                        return Ok(LV::Lit(f64::NAN)); // `is_valid_permutation`
                    }
                    seen[x as usize] = true;
                    out.push(x as usize);
                }
                if out.len() != nd {
                    return Ok(LV::Lit(f64::NAN));
                }
                out
            }
            None => (0..nd).rev().collect(),
        };
        Ok(self.emit_permute(&v, &shape, &perm))
    }

    /// Output axis `j` of the result reads source axis `perm[j]`.
    pub(super) fn emit_permute(&mut self, v: &LV, shape: &[usize], perm: &[usize]) -> LV {
        if perm.iter().enumerate().all(|(j, &p)| j == p) {
            return v.clone();
        }
        let out_shape: DimU = perm.iter().map(|&p| shape[p]).collect();
        let segs = out_shape
            .iter()
            .map(|&n| {
                let mut one = SmallVec::new();
                one.push((0usize, n, 0usize));
                one
            })
            .collect();
        let ones = DimI::from_elem(1, out_shape.len());
        let flags = SmallVec::from_elem(true, out_shape.len());
        self.emit_gather(v, SmallVec::new(), perm, flags, segs, &out_shape, &ones)
    }

    /// `eval_reshape`, which is COLUMN-major: flatten in column-major order,
    /// refill the new shape in column-major order. On row-major slots that is
    /// an axis reversal, a row-major [`Instr::Reshape`] to the reversed target,
    /// and an axis reversal back (a reversal of a rank-1 box is nothing).
    pub(super) fn lower_wholesale_reshape(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let Some(arg0) = node.args.first() else {
            return Ok(LV::Lit(f64::NAN));
        };
        let v = self.lower_wholesale(arg0)?;
        let target_raw = node.shape.clone().unwrap_or_default();
        if target_raw.is_empty() || target_raw.iter().any(|&d| d < 1) {
            bail_tape!("wholesale: `reshape` to an empty or rank-0 shape");
        }
        let target: DimU = target_raw.iter().map(|&d| d as usize).collect();
        let n_target: usize = target.iter().product();
        let ones = DimI::from_elem(1, target.len());
        let Some((shape, _)) = self.lv_box(&v) else {
            // A scalar is one element.
            return Ok(if n_target == 1 {
                self.emit_fill(&v, &target, &ones, Cadence::Const)
            } else {
                LV::Lit(f64::NAN)
            });
        };
        if shape.iter().product::<usize>() != n_target {
            return Ok(LV::Lit(f64::NAN)); // the element count disagrees
        }
        if shape == target {
            return Ok(v);
        }
        let rev_src: SmallVec<[usize; 4]> = (0..shape.len()).rev().collect();
        let flipped = self.emit_permute(&v, &shape, &rev_src);
        let rev_target: DimU = target.iter().rev().copied().collect();
        let sec = self.placement(self.lv_cadence(&flipped));
        let out = self.new_slot(&rev_target, &ones, false, sec);
        let instr = Instr::Reshape {
            src: self.src_of(&flipped),
            out,
        };
        self.emit(instr, sec);
        let rev_out: SmallVec<[usize; 4]> = (0..target.len()).rev().collect();
        Ok(self.emit_permute(&LV::Arr(out), &rev_target, &rev_out))
    }

    /// `eval_concat`: the operands joined along `axis` (a scalar is a
    /// one-element array) — one [`Instr::Assemble`], each operand written
    /// over its slab of the result. Operands `ndarray::concatenate` would
    /// refuse give the oracle's `NaN`.
    pub(super) fn lower_wholesale_concat(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let axis = node.axis.unwrap_or(0);
        let mut parts: Vec<(LV, DimU)> = Vec::with_capacity(node.args.len());
        for a in &node.args {
            let v = self.lower_wholesale(a)?;
            let shape = match self.lv_box(&v) {
                Some((sh, _)) => sh,
                None => DimU::from_elem(1, 1),
            };
            parts.push((v, shape));
        }
        let Some((_, first)) = parts.first() else {
            return Ok(LV::Lit(f64::NAN));
        };
        let nd = first.len();
        if axis < 0 || axis as usize >= nd {
            return Ok(LV::Lit(f64::NAN));
        }
        let ax = axis as usize;
        let mut out_shape = first.clone();
        out_shape[ax] = 0;
        for (_, sh) in &parts {
            let fits = sh.len() == nd && (0..nd).all(|d| d == ax || sh[d] == first[d]);
            if !fits {
                return Ok(LV::Lit(f64::NAN));
            }
            out_shape[ax] += sh[ax];
        }
        if out_shape.contains(&0) {
            bail_tape!("wholesale: `concat` into an empty array");
        }
        let mut spec_parts: Vec<(Operand, u32)> = Vec::with_capacity(parts.len());
        let mut want = Cadence::Const;
        let mut at = 0usize;
        for (v, sh) in &parts {
            if sh[ax] == 0 {
                continue;
            }
            let mut dest_lo = DimU::from_elem(0, nd);
            dest_lo[ax] = at;
            at += sh[ax];
            want = want.max(self.lv_cadence(v));
            let region = tape_index(self.tables.regions.len(), "makearray regions")?;
            self.tables.regions.push(RegionSpec {
                dest_lo,
                shape: sh.clone(),
            });
            spec_parts.push((self.op_of(v), region));
        }
        let table = tape_index(self.tables.assemblies.len(), "makearray assemblies")?;
        self.tables
            .assemblies
            .push(AssembleSpec { parts: spec_parts });
        let sec = self.placement(want);
        let ones = DimI::from_elem(1, nd);
        let out = self.new_slot(&out_shape, &ones, false, sec);
        self.emit(Instr::Assemble { table, out }, sec);
        Ok(LV::Arr(out))
    }

    /// `eval_index` mirror (wholesale): LITERAL 1-based indices into a known
    /// array (`index_into` semantics — out-of-bounds reads the Dirichlet
    /// ghost 0; a partial index yields a sub-array and bails).
    pub(super) fn lower_wholesale_index(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let Some((base, idx_args)) = node.args.split_first() else {
            return Ok(LV::Lit(f64::NAN));
        };
        let const_base = self.const_arrays.is_const_base(base);
        let basev = self.lower_wholesale(base)?;
        let Some((shape, origin)) = self.lv_box(&basev) else {
            // `index(x)` with no subscript is the identity on a 0-D value.
            if idx_args.is_empty() {
                return Ok(basev);
            }
            // Subscripts on a 0-D value: the fail-closed
            // `E_TREEWALK_INDEX_ON_SCALAR`, where the oracle is certain to
            // raise it.
            return self.index_on_scalar(base, &basev, idx_args.len(), None);
        };
        if origin.iter().any(|&o| o != 1) {
            bail_tape!("wholesale: index base is not origin-1");
        }
        let mut subs: SmallVec<[LV; 4]> = SmallVec::new();
        for a in idx_args {
            subs.push(self.lower_wholesale(a)?);
        }
        if subs.iter().any(|s| !matches!(s, LV::Lit(_))) {
            // A subscript known only at run time (`Ri1[kpbl1 - 1]`): read
            // through a one-element computed-subscript gather.
            if subs.len() != shape.len() {
                bail_tape!("wholesale: computed subscripts whose count is not the source rank");
            }
            if subs.iter().any(|s| self.lv_box(s).is_some()) {
                bail_tape!("wholesale: an array-valued index argument");
            }
            return self.emit_data_gather(base, &basev, &subs, None);
        }
        let raw: SmallVec<[i64; 4]> = subs
            .iter()
            .map(|s| match s {
                LV::Lit(f) => f.round() as i64,
                _ => unreachable!("every subscript is a literal here"),
            })
            .collect();
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
            if const_base {
                // §5.5.5, as `index_into` resolves it: the declared policy of
                // each dim in turn, and the first one out of range with none
                // is the fault (the gather reads `NaN`).
                let name = match base {
                    Expr::Variable(v) => v.as_str(),
                    _ => INLINE_CONST_NAME,
                };
                let policy = if dim == 0 {
                    BoundaryKind::Error
                } else {
                    self.const_arrays.boundary(name, d)
                };
                match resolve_const_index(policy, one_based, dim) {
                    Some(i0) => idx.push(i0),
                    None => {
                        let msg = const_oob_message(name, one_based, dim, d);
                        self.note_fault(None, msg, None)?;
                        return Ok(LV::Lit(f64::NAN));
                    }
                }
                continue;
            }
            if one_based < 1 || one_based > dim {
                in_bounds = false;
            }
            idx.push(one_based.saturating_sub(1).max(0) as usize);
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

    /// `eval_faq` mirror (a standalone aggregate evaluated wholesale):
    /// prefix scans get the running-fold lowering, rank-0 reductions the
    /// scalar-reduction lowering, a drivable join gate the tuple-list form, and
    /// everything else the same [`Self::lower_faq`] as the compiled rules.
    pub(super) fn lower_wholesale_aggregate(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let level = self.enter_fault_level(None);
        let v = self.lower_wholesale_aggregate_in_level(node);
        self.leave_fault_level(level);
        v
    }

    pub(super) fn lower_wholesale_aggregate_in_level(
        &mut self,
        node: &Arc<ExpressionNode>,
    ) -> LResult<LV> {
        let Some(spec) = faq_spec(node) else {
            return Ok(LV::Lit(f64::NAN)); // eval_faq's missing-body sentinel
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
            let v = self.lower_prefix_scan(&Contraction::of(&spec), &spec.ranges, scan)?;
            return Ok(self.reorigin_to_one(v));
        }
        // A join gate drives the contraction (`eval_faq` resolves its gates
        // for everything but a prefix scan): the tuple-list form.
        if spec.has_drivable_overlap() {
            let v =
                self.lower_tuple_contraction(&Contraction::of(&spec), &spec.ranges, spec.join)?;
            return Ok(self.reorigin_to_one(v));
        }
        if spec.ranges.is_empty() {
            return self.lower_scalar_reduction(&spec);
        }
        let v = self.lower_faq(&Contraction::of(&spec), &spec.ranges)?;
        Ok(self.reorigin_to_one(v))
    }

    /// A rank-0 `faq` — every index contracted, no output axis — compiled as
    /// "promote the contracted indices to a box, then fold the box away".
    ///
    /// The per-cell oracle evaluates it in [`reduce_contraction`]: `acc =
    /// identity`, then one `acc = reduce.combine(acc, term)` per contraction
    /// tuple, enumerated by `CartesianTuples` — lexicographic over
    /// `contract_names`, LAST name fastest. [`Instr::Reduce`] folds its source
    /// box in row-major order, and the box built here carries the contracted
    /// names as axes in that same order, so the two fold the same terms in the
    /// same association.
    ///
    /// A `filter` is lowered as a SKIP: the oracle skips an excluded tuple
    /// (`continue`, not `acc ⊕ 0̄`), so an excluded term is replaced by a value
    /// `v` with `acc ⊕ v == acc`, bit for bit, for EVERY accumulator: `-0.0`
    /// for a sum (`+0.0` would turn a `-0.0` accumulator positive), and the
    /// identity for the others — `acc · 1` is exact, and a `max`/`min`
    /// accumulator is never `NaN` (the kernels ignore a `NaN` operand), so
    /// `max(acc, -∞)` is `acc`. The fold then combines the oracle's terms in
    /// the oracle's order and nothing else.
    ///
    /// A scalar `bool_and_or` reduction folds with `BinCode::Or` from `0.0`
    /// (CONFORMANCE_SPEC §5.6.1): every accumulator is a crisp `0.0`/`1.0`, so
    /// the skip value `0.0` leaves it unchanged, as the oracle's `continue` does.
    pub(super) fn lower_scalar_reduction(&mut self, spec: &ArrayOpSpec) -> LResult<LV> {
        let combine_op = scalar_combine_op(spec.reduce);
        let identity = spec.reduce.identity();
        if spec.contract_names.is_empty() {
            // No axes at all: `reduce_contraction`'s pointwise arm evaluates
            // the body once and scalarizes it.
            let v = self.lower_wholesale(spec.body)?;
            return Ok(if self.lv_box(&v).is_some() {
                LV::Lit(f64::NAN)
            } else {
                v
            });
        }
        let mut lo: DimI = DimI::new();
        let mut shape: DimU = DimU::new();
        for d in &spec.contract_dims {
            match d {
                ContractDim::Static(l, h) => {
                    lo.push(*l);
                    shape.push((h - l + 1).max(0) as usize);
                }
                _ => {
                    return self.lower_tuple_contraction(
                        &Contraction::of(spec),
                        &spec.ranges,
                        None,
                    );
                }
            }
        }
        // An empty window enumerates no tuples: the fold is the identity.
        if shape.contains(&0) {
            return Ok(LV::Lit(identity));
        }
        // The body over the contraction box: the contracted names ARE its
        // axis symbols, in `faq_spec`'s (sorted) order. The filter first: the
        // oracle tests it before the body at every tuple.
        let txn = self.sub_txn();
        let query = self.wholesale_count_query(spec);
        self.push_scope();
        let bx = LBox::new(&spec.contract_names, lo.clone(), shape.clone());
        let count = self.try_lower_indicator_count(spec, &bx, false, query.clone());
        self.pop_scope();
        if let Some(v) = count {
            return Ok(v);
        }
        if query.is_some() {
            self.sub_rollback(txn);
        }
        let plan = PromotedPlan::new(
            PromotedKind::Scalar,
            &[],
            &DimI::new(),
            &DimU::new(),
            std::iter::empty(),
            &spec.contract_names,
            &lo,
            &shape,
            false,
        );
        plan.check()?;
        // A body constant over the window still contributes one term PER
        // tuple: `lower_promoted` broadcasts it over the box and folds that.
        self.lower_promoted(plan, combine_op, identity, false, |s, bx| {
            let keep = match spec.filter {
                None => None,
                Some(f) => {
                    let fv = s.lower_expr(f, bx)?;
                    match fv {
                        // No tuple is kept: the body never runs.
                        LV::Lit(0.0) => return Ok(None),
                        LV::Lit(_) => None,
                        fv if s.is_bare_view(&fv) => {
                            bail_tape!("reduction: filter reduced to a bare whole-array view")
                        }
                        fv => Some(fv),
                    }
                }
            };
            // A kept-only body is evaluated by the oracle at kept tuples alone.
            let v = match &keep {
                None => s.lower_expr(spec.body, bx),
                Some(fv) => {
                    s.fault.lazy_depth += 1;
                    let v = s.reached_where(fv, true, |s| s.lower_expr(spec.body, bx));
                    s.fault.lazy_depth -= 1;
                    v
                }
            };
            let v = v?;
            // Same bail as `lower_faq`: the oracle scalarizes a bare
            // whole-array body (`eval(body).as_scalar()` ⇒ NaN), which this
            // box lowering does not reproduce.
            if s.is_bare_view(&v) {
                bail_tape!("reduction: body reduced to a bare whole-array view");
            }
            Ok(Some(match keep {
                None => v,
                Some(fv) => {
                    let skip = match spec.reduce {
                        ReduceKind::Sum => -0.0,
                        other => other.identity(),
                    };
                    s.emit_select(fv, v, LV::Lit(skip))?
                }
            }))
        })
    }

    /// A rank-0 `faq` that counts the entries of a rank-1 axis standing in one
    /// comparison to a query ([`detect_indicator_count`]), lowered to one
    /// [`Instr::Count`]; `None` for every other shape, which the caller
    /// lowers as before.
    ///
    /// The oracle folds `ifelse(axis[k] REL x, 1, 0)` over the window from
    /// `+0.0`: every term is `0.0` or `1.0`, so the fold is the count of
    /// entries that satisfy the comparison, exactly, and the instruction's
    /// count is that number whatever the axis holds. An axis whose window is
    /// a build-time literal the lowering finds non-decreasing is marked
    /// `sorted`, so the instruction bisects it without checking it first; a
    /// build-time literal in any other order is counted through a sorted copy
    /// of its non-NaN entries, also bisected.
    ///
    /// `nested` is the per-cell form: `bx` is the enclosing box the query
    /// reads, and the count is an array over it. Otherwise `bx` is the
    /// contraction box of a standalone reduction, which the query does not
    /// read, and the count is one scalar.
    ///
    /// The attempt is speculative: whatever it cannot lower (a query that
    /// would note a fail-closed fault in the per-cell form, a query over
    /// another box, an axis the resolver refuses) declines, and everything it
    /// emitted is undone, so the general reduction lowers the `faq` as if no
    /// count had been tried and reports anything it refuses itself.
    pub(super) fn try_lower_indicator_count(
        &mut self,
        spec: &ArrayOpSpec,
        bx: &LBox,
        nested: bool,
        query: Option<LV>,
    ) -> Option<LV> {
        if !self.count_fold || bx.tuple != 0 || self.rule.sweep.is_some() {
            return None;
        }
        let ic = detect_indicator_count(spec)?;
        let txn = self.sub_txn();
        match self.lower_indicator_count(&ic, bx, nested, query) {
            Ok(Some(v)) => Some(v),
            // The general reduction reports what it refuses itself.
            Ok(None) | Err(_) => {
                self.sub_rollback(txn);
                None
            }
        }
    }

    /// The query of a standalone comparison count in a whole-body rule,
    /// lowered in the rule's own frame rather than the contraction's: it
    /// reads no contraction index, so it is one value for the whole window,
    /// and an identical sub-tree elsewhere in the rule (an interpolation's
    /// clamped coordinate, read again by its weight) is shared with it. `None`
    /// (and nothing emitted) for any other reduction, outside a whole-body
    /// frame, or when the query notes a fault or is not a scalar.
    pub(super) fn wholesale_count_query(&mut self, spec: &ArrayOpSpec) -> Option<LV> {
        if !self.count_fold
            || self.rule.sweep.is_some()
            || !self.rule.scope_frames.last().is_some_and(|f| f.wholesale)
        {
            return None;
        }
        let ic = detect_indicator_count(spec)?;
        let txn = self.sub_txn();
        let notes = self.fault.notes;
        match self.lower_wholesale(ic.x) {
            Ok(x) if self.fault.notes == notes && self.lv_box(&x).is_none() => Some(x),
            _ => {
                self.sub_rollback(txn);
                None
            }
        }
    }

    /// [`Self::try_lower_indicator_count`]'s lowering of a detected count;
    /// `Ok(None)` or a bail declines it.
    pub(super) fn lower_indicator_count(
        &mut self,
        ic: &IndicatorCount,
        bx: &LBox,
        nested: bool,
        query: Option<LV>,
    ) -> LResult<Option<LV>> {
        // The axis, read whole. A name an enclosing box binds is not an
        // array; anything the resolver would refuse is left to the general
        // path, which reports it.
        let axis = match ic.axis {
            Expr::Variable(name) => {
                if bx.syms.iter().chain(bx.cnames.iter()).any(|s| s == name) {
                    return Ok(None);
                }
                if let Some(&ix) = self.state_ix.get(name.as_str()) {
                    LV::State(tape_index(ix, "state variables")?)
                } else if let Some(ObsVal::Taped(lv)) = self.obs_defined.get(name.as_str()) {
                    lv.clone()
                } else if self.obs_defined.contains_key(name.as_str())
                    || self.param_ix.contains_key(name.as_str())
                {
                    return Ok(None);
                } else if let Some(lv) = self.forcing_read(name)? {
                    lv
                } else {
                    return Ok(None);
                }
            }
            Expr::Operator(lit) => match eval_const(lit) {
                Value::Array(a) if a.ndim() == 1 && !a.is_empty() => {
                    self.const_literal_array(lit, &a, Some(bx))?
                }
                _ => return Ok(None),
            },
            _ => return Ok(None),
        };
        let Some((ashape, aorigin)) = self.lv_box(&axis) else {
            return Ok(None);
        };
        if ashape.len() != 1 {
            return Ok(None);
        }
        // The window, inside the axis: no ghost read, no out-of-range fault.
        let start = ic.lo - aorigin[0];
        let n = ic.hi - ic.lo + 1;
        if start < 0 || n < 1 || start + n > ashape[0] as i64 {
            return Ok(None);
        }
        if self.tile.is_some() && self.tile_source(&axis).is_some() {
            return Ok(None);
        }
        let (Ok(start), Ok(n)) = (u32::try_from(start), u32::try_from(n)) else {
            return Ok(None);
        };
        // The query, as the oracle evaluates it at each cell.
        let notes = self.fault.notes;
        let x = match query {
            Some(x) => x,
            None => self.lower_expr(ic.x, bx)?,
        };
        if nested && self.fault.notes != notes {
            return Ok(None);
        }
        let (shape, origin, scalar) = if nested {
            (bx.shape.clone(), bx.lo.clone(), false)
        } else {
            (DimU::new(), DimI::new(), true)
        };
        match self.lv_box(&x) {
            None => {}
            Some((s, o)) if !scalar && s == shape && o == origin => {}
            Some(_) => return Ok(None),
        }
        // A window known at build: counted as it stands when non-decreasing,
        // else through a sorted copy of its non-NaN entries. The count is the
        // same number either way: a NaN entry satisfies no comparison, and
        // reordering the entries does not change how many satisfy one. The
        // copy is sorted under the comparison itself, so -0.0 and +0.0 stay
        // equal neighbours. The complement below still subtracts from the
        // whole window, NaN entries included, as the fold counts them.
        let window: Option<Vec<f64>> = match &axis {
            LV::Arr(s) => self
                .known_slice(*s)
                .map(|v| v[start as usize..(start + n) as usize].to_vec()),
            _ => None,
        };
        let (axis, start, count_n, sorted) = match window {
            Some(w) if non_decreasing(w.len(), |j| w[j]) => (axis, start, n, true),
            Some(w) => {
                let mut keys: Vec<f64> = w.into_iter().filter(|v| !v.is_nan()).collect();
                if keys.is_empty() {
                    // No entry satisfies the comparison.
                    let zero = LV::Lit(0.0);
                    return Ok(Some(if !ic.complement {
                        if scalar {
                            zero
                        } else {
                            self.emit_fill(&zero, &shape, &origin, Cadence::Const)
                        }
                    } else {
                        let all = LV::Lit(f64::from(n));
                        if scalar {
                            all
                        } else {
                            self.emit_fill(&all, &shape, &origin, Cadence::Const)
                        }
                    }));
                }
                keys.sort_by(|a, b| a.partial_cmp(b).expect("NaN entries are set aside"));
                let m = u32::try_from(keys.len()).expect("no longer than the window");
                let copy = self.emit_const_data(&[keys.len()], &[1], Arc::new(keys), true)?;
                (LV::Arr(copy), 0, m, true)
            }
            None => (axis, start, n, false),
        };
        let sec = self.placement(self.lv_cadence(&axis).max(self.lv_cadence(&x)));
        let axis_src = self.src_of(&axis);
        let out = self.new_slot(&shape, &origin, scalar, sec);
        let instr = Instr::Count {
            rel: ic.rel,
            axis: axis_src,
            lo: start,
            n: count_n,
            sorted,
            x: self.op_of(&x),
            out,
        };
        self.emit(instr, sec);
        let count = if scalar {
            LV::Scalar(out)
        } else {
            LV::Arr(out)
        };
        if !ic.complement {
            return Ok(Some(count));
        }
        // Each term of the oracle's sum is 0 or 1, so the sum is an integer
        // below 2^53 reached exactly, and so is `n - count`: the two are the
        // same binary64 (both +0.0 when nothing is counted).
        Ok(Some(self.emit_bin(
            BinCode::Sub,
            LV::Lit(f64::from(n)),
            count,
        )?))
    }

    /// `eval_makearray` mirror (wholesale): the bounding-box assembly around
    /// region writes; an empty bounding-box axis declines to the per-cell
    /// path. A region value that is a prefix scan lowers to the running fold,
    /// through [`Self::lower_faq`].
    pub(super) fn lower_wholesale_makearray(&mut self, node: &Arc<ExpressionNode>) -> LResult<LV> {
        let regions: &[Vec<[crate::types::RegionBound; 2]>] =
            node.regions.as_deref().unwrap_or(&[]);
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
                let Some([r_lo, r_hi]) = crate::types::region_bounds(r) else {
                    return Ok(LV::Lit(f64::NAN));
                };
                lo[d] = lo[d].min(r_lo);
                hi[d] = hi[d].max(r_hi);
            }
        }
        let shape: DimU = (0..ndim)
            .map(|d| (hi[d] - lo[d] + 1).max(0) as usize)
            .collect();
        if shape.contains(&0) {
            bail_tape!("makearray: empty bounding-box axis (per-cell path)");
        }
        let bx = LBox {
            syms: &[],
            lo,
            shape,
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        let level = self.enter_fault_level(None);
        let v = self.lower_makearray(node, &bx);
        self.leave_fault_level(level);
        Ok(self.reorigin_to_one(v?))
    }

    /// A prefix scan (esm-spec §4.3.1): the term over the whole
    /// output box, then one [`Instr::Scan`] along the scanned axis — the
    /// vectorized analogue of `run_prefix_scan`, and one instruction whatever
    /// the scanned length.
    ///
    /// Bit-identical: `run_prefix_scan` evaluates the body at step `i` with
    /// both the scanned output symbol and the contracted symbol bound to `i`,
    /// and the body never reads the scanned output symbol (the detector
    /// rejects such bodies), so the term at step `i` is the body over a box
    /// whose scanned axis is named by the CONTRACTED symbol. The scan then
    /// folds each window in the sweep's order (ascending, or descending for a
    /// reverse scan) in the same association.
    ///
    /// A body whose whole-box lowering bails keeps the per-step form
    /// ([`Self::lower_prefix_scan_steps`]), which binds the step position as
    /// a constant.
    pub(super) fn lower_prefix_scan(
        &mut self,
        c: &Contraction,
        ranges: &[(i64, i64)],
        scan: PrefixScan,
    ) -> LResult<LV> {
        let Contraction {
            idx_names,
            body,
            reduce,
            ..
        } = *c;
        let j_name = c.contract_names[0].as_str();
        let combine_op = self.array_combine_op(reduce, "scan")?;
        let full_lo: DimI = ranges.iter().map(|(l, _)| *l).collect();
        let full_shape: DimU = ranges
            .iter()
            .map(|(l, h)| (h - l + 1).max(0) as usize)
            .collect();
        if full_shape.contains(&0) {
            // No cell to scan: the empty array.
            return Ok(self.emit_zero_array(&full_shape, &full_lo));
        }
        let txn = self.sub_txn();
        let mut syms: Vec<String> = idx_names.to_vec();
        syms[scan.axis] = j_name.to_string();
        self.push_scope();
        let bx = LBox::new(&syms, full_lo.clone(), full_shape.clone());
        let term = self.lower_expr(body, &bx);
        self.pop_scope();
        let term = term.and_then(|v| {
            // The oracle scalarizes a bare whole-array body (NaN); see the
            // same bail in `lower_faq`.
            if self.is_bare_view(&v) {
                bail_tape!("scan: body reduced to a bare whole-array view");
            }
            match self.lv_box(&v) {
                None => Ok(self.emit_fill(&v, &full_shape, &full_lo, Cadence::Const)),
                Some((s, o)) if s == full_shape && o == full_lo => Ok(v),
                Some(_) => bail_tape!("scan: term box does not match the output box"),
            }
        });
        let term = match term {
            Ok(t) => t,
            Err(_) => {
                self.sub_rollback(txn);
                return self.lower_prefix_scan_steps(c, ranges, scan, combine_op);
            }
        };
        let axis = u8::try_from(scan.axis)
            .map_err(|_| Bail::new("scan: axis index out of range".into()))?;
        let sec = self.placement(self.lv_cadence(&term));
        let out = self.new_slot(&full_shape, &full_lo, false, sec);
        let instr = Instr::Scan {
            op: combine_op,
            init: reduce.identity(),
            src: self.src_of(&term),
            axis,
            inclusive: scan.inclusive,
            reverse: scan.reverse,
            src_shape: full_shape,
            out,
        };
        self.emit(instr, sec);
        Ok(LV::Arr(out))
    }

    /// The per-step form of [`Self::lower_prefix_scan`]: one step box per
    /// scanned position with the step bound as a constant, each written into
    /// the result by a full-box region write. Its length grows with the
    /// scanned extent; it serves only bodies the whole-box form cannot lower.
    pub(super) fn lower_prefix_scan_steps(
        &mut self,
        c: &Contraction,
        ranges: &[(i64, i64)],
        scan: PrefixScan,
        combine_op: BinCode,
    ) -> LResult<LV> {
        let Contraction {
            idx_names,
            body,
            reduce,
            ..
        } = *c;
        let j_name = c.contract_names[0].as_str();
        let full_lo: DimI = ranges.iter().map(|(l, _)| *l).collect();
        let full_shape: DimU = ranges
            .iter()
            .map(|(l, h)| (h - l + 1).max(0) as usize)
            .collect();
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
        let steps: Vec<i64> = if scan.reverse {
            (slo..=shi).rev().collect()
        } else {
            (slo..=shi).collect()
        };
        for i in steps {
            self.push_scope();
            let bx = LBox {
                syms: idx_names,
                lo: full_lo.clone(),
                shape: step_shape.clone(),
                cnames: &cnames,
                cvals: SmallVec::from_slice(&[i, i]),
                tuple: 0,
                visit: SmallVec::new(),
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
            let region_ix = self.tables.regions.len() as u32;
            let mut dest_lo: DimU = DimU::from_elem(0usize, full_shape.len());
            dest_lo[scan.axis] = (i - slo) as usize;
            self.tables.regions.push(RegionSpec {
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
    pub(super) fn lower_branchy_ifelse<F>(
        &mut self,
        cond: LV,
        t_expr: &Expr,
        f_expr: &Expr,
        in_box: bool,
        mut low: F,
    ) -> LResult<LV>
    where
        F: FnMut(&mut Self, &Expr) -> LResult<LV>,
    {
        self.lower_branchy(cond, in_box, |s, taken| {
            low(s, if taken { t_expr } else { f_expr })
        })
    }

    /// A runtime-scalar-condition branch (JmpIfZero + phi) whose arms are
    /// lowered by `arm(self, true)` and `arm(self, false)`. `in_box` says the
    /// arms are values over an output box, where a scalar arm broadcasts
    /// against an array one; on the wholesale path the oracle's result shape
    /// follows the taken arm, so mixed arms stay refused there.
    pub(super) fn lower_branchy<F>(&mut self, cond: LV, in_box: bool, mut arm: F) -> LResult<LV>
    where
        F: FnMut(&mut Self, bool) -> LResult<LV>,
    {
        let mark = self.push_branch();
        self.fault.reach.push((cond.clone(), true));
        let tv = arm(self, true);
        self.fault.reach.pop();
        let tv = match tv {
            Ok(v) => v,
            Err(e) => {
                self.pop_branch(mark);
                return Err(e);
            }
        };
        let (mut tbuf, tsec) = self.pop_branch(mark);
        let mark = self.push_branch();
        self.fault.reach.push((cond.clone(), false));
        let fv = arm(self, false);
        self.fault.reach.pop();
        let fv = match fv {
            Ok(v) => v,
            Err(e) => {
                self.pop_branch(mark);
                return Err(e);
            }
        };
        let (mut fbuf, fsec) = self.pop_branch(mark);
        let tb = self.lv_box(&tv);
        let fb = self.lv_box(&fv);
        // One arm a scalar and the other an array over a box: the join is
        // that box, and the scalar arm broadcasts into it. The per-cell oracle
        // takes the same arm at every cell (the condition is one scalar), so
        // each cell reads the scalar or its own element, as the join does.
        let (shape, origin, scalar) = match (&tb, &fb) {
            (None, None) => (DimU::new(), DimI::new(), true),
            (Some((s, o)), Some((s2, o2))) if s == s2 && o == o2 => (s.clone(), o.clone(), false),
            (Some((s, o)), None) | (None, Some((s, o)))
                if in_box && matches!((&tv, &fv), (LV::Arr(_), _) | (_, LV::Arr(_))) =>
            {
                (s.clone(), o.clone(), false)
            }
            _ => bail_tape!("ifelse: branch value boxes differ under a runtime scalar condition"),
        };
        // Two scalar arms of at most `IF_CONVERT_MAX` pure instructions that
        // cannot fault: both are computed and the condition picks one
        // (`Instr::Select` reads `cond != 0` as the jump does), the same value
        // for less than the jump and the two copies into a join cost.
        const IF_CONVERT_MAX: usize = 2;
        if scalar
            && self.rule.sweep.is_none()
            && tbuf.len() + fbuf.len() <= IF_CONVERT_MAX
            && tbuf
                .iter()
                .chain(fbuf.iter())
                .all(|(i, _)| Self::hoistable(i))
        {
            let home = self.home;
            for (i, p) in tbuf.into_iter().chain(fbuf) {
                self.emit_tagged(i, p, home);
            }
            return self.emit_select(cond, tv, fv);
        }
        let phi = self.new_slot(&shape, &origin, scalar, self.home);
        let prec = crate::precision::active();
        let join = |s: &Self, v: &LV, arm_box: &Option<(DimU, DimI)>| {
            let a = s.op_of(v);
            if arm_box.is_none() && !scalar {
                Instr::Fill { v: a, out: phi }
            } else {
                Instr::Copy { a, out: phi }
            }
        };
        tbuf.push((join(self, &tv, &tb), prec));
        fbuf.push((join(self, &fv, &fb), prec));
        let jmp = Instr::JmpIfZero {
            cond: self.op_of(&cond),
            n_true: tbuf.len() as u32,
            n_false: fbuf.len() as u32,
        };
        // The block runs in the earliest section its condition, its arms'
        // values and every instruction in it allow, when all of it is pure
        // and cannot fault (a block of build-time data then runs once, not on
        // every call); otherwise at the rule's home, as before. Every slot it
        // defines takes that section.
        let sec = if self.rule.sweep.is_none() {
            let want = tsec
                .max(fsec)
                .max(self.lv_cadence(&cond))
                .max(self.lv_cadence(&tv))
                .max(self.lv_cadence(&fv));
            let pure = tbuf
                .iter()
                .chain(fbuf.iter())
                .all(|(i, _)| Self::hoistable(i) || matches!(i, Instr::JmpIfZero { .. }));
            if pure { want.min(self.home) } else { self.home }
        } else {
            self.home
        };
        if self.rule.sweep.is_none() {
            let mut defs: SmallVec<[SlotId; 8]> = SmallVec::new();
            let tables = self.slot_tables();
            for (i, _) in tbuf.iter().chain(fbuf.iter()) {
                i.for_each_def(&tables, |s| defs.push(s));
            }
            for s in defs {
                self.tables.slots[s as usize].cadence = sec;
            }
        }
        if self.rule.sweep.is_some() {
            // Inside a recurrence body the block moves as one: its skip counts
            // must stay exact. It runs per cell when anything in it depends on
            // the cell or it sits in an enclosing branch; otherwise once,
            // ahead of the sweep.
            let block: Vec<Tagged> = std::iter::once((jmp, prec))
                .chain(tbuf)
                .chain(fbuf)
                .collect();
            let per_cell = self.in_branch() || block.iter().any(|(i, _)| self.reads_body(i));
            for (i, p) in block {
                self.track_known(&i);
                if per_cell {
                    self.mark_body_defs(&i);
                    self.push_body(i, p);
                } else {
                    self.push_stream(i, p, sec);
                }
            }
        } else if self.in_branch() && sec < self.home {
            // A block that moved out of its enclosing branch runs there whole,
            // so its skip counts stay exact.
            for (i, p) in std::iter::once((jmp, prec)).chain(tbuf).chain(fbuf) {
                self.track_known(&i);
                self.track_range(&i);
                self.push_stream(i, p, sec);
            }
        } else {
            self.emit(jmp, sec);
            for (i, p) in tbuf.into_iter().chain(fbuf) {
                self.emit_tagged(i, p, sec);
            }
        }
        // Each Copy into the join carried its branch's build-time value, the
        // false branch's last. Which branch runs is a runtime question, so
        // the join is build-time data only when the two agree bit for bit.
        let agree = match (&tv, &fv) {
            (LV::Arr(a), LV::Arr(b)) => match (self.known_slice(*a), self.known_slice(*b)) {
                (Some(x), Some(y)) => {
                    x.len() == y.len()
                        && x.iter()
                            .zip(y.iter())
                            .all(|(p, q)| p.to_bits() == q.to_bits())
                }
                _ => false,
            },
            _ => false,
        };
        if !agree {
            self.known.remove(&phi);
        }
        Ok(if scalar {
            LV::Scalar(phi)
        } else {
            LV::Arr(phi)
        })
    }

    /// Materialize an LV into a slot (for exports / dy writes of folded
    /// values).
    pub(super) fn ensure_slot(&mut self, lv: &LV) -> SlotId {
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
            LV::State(_) => {
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
