//! One-pass scatter for a `faq` whose filter pins an output index by
//! equality (esm-spec §4.3.1, EarthSciAST#613).
//!
//! A filter that is a conjunction holding, for an output index `j`, a
//! conjunct `j == e` (or `e == j`) where `e` reads no output index admits,
//! at each point of the contracted box, at most one value of `j`: the value
//! of `e` there. The naive evaluation walks the output box and, in every
//! cell, the whole contracted box, testing the filter at each pair, so a
//! transposed band product `out[j] = Σ_{i : i + 1 = j} a[i]·u[i]` costs
//! `|j| × |i|`. Here the contracted box is walked ONCE, in the order the
//! interpreter's per-cell walk visits it (the odometer over the contracted
//! names, the last one fastest); `e` and every other conjunct the build can
//! evaluate are evaluated at each point, and the point is appended to the run
//! of output cell `e`. A stable bucketing by cell keeps each cell's run in
//! that visit order, so each cell receives exactly the terms the naive walk
//! admits, in the same order: the tuple-list form ([`TupleList`],
//! [`Instr::SegReduce`]) then folds each run left to right from the
//! semiring's identity, bit for bit the interpreter's fold for every ⊕.
//! Output indices no conjunct pins are outer loops: the pass is repeated for
//! each of their cells.
//!
//! The map from points to cells is computed here, at build time, so `e` must
//! be build-time data: index names, literals, baked parameters, build-time
//! scalars and gathers of build-time arrays, combined by arithmetic,
//! `floor`, `ceil`, `abs`, `sign` and comparisons ([`IxNode`]), each
//! evaluated with the interpreter's own scalar kernels. An `e` that reads a run-time value (a state, a tunable parameter,
//! the time) is declined, and the contraction keeps its dense lowering. A
//! remaining conjunct the build cannot evaluate stays in the filter the tuple
//! list lowers as a run-time mask, which skips a term exactly as the
//! interpreter's `continue` does.

use super::tuples::{DimBound, TupleList, TupleSpec, parent_first_order, walk_nest};
use super::*;
use crate::simulate_array::eval::{apply_binary, apply_unary, fold_scalar};
use std::rc::Rc;

/// The most points one scatter's build-time walk visits: a bound on build
/// time only (the dense lowering's own box limit is
/// [`MAX_PROMOTED_ELEMS`] terms).
const MAX_SCATTER_VISITS: u64 = 1 << 34;

/// A build-time integer-index expression over one point's loop symbols.
enum IxNode {
    Lit(f64),
    /// A loop symbol: its position in the point's value vector.
    Sym(usize),
    Neg(Box<IxNode>),
    /// `floor`, `ceil`, `abs`, `sign`: `eval_unary`'s kernel.
    Un(&'static str, Box<IxNode>),
    /// An n-ary `+ - * / and or`, folded as `eval_arith` folds it.
    Fold(&'static str, Vec<IxNode>),
    /// A two-operand comparison, `eval_binary`'s kernel.
    Cmp(&'static str, Box<IxNode>, Box<IxNode>),
    /// `index(a, subs…)` of an array the build knows, row-major.
    Index {
        vals: Rc<Vec<f64>>,
        shape: DimU,
        subs: Vec<IxNode>,
    },
}

/// Why an [`IxNode`] produced no value at a point: a gather the build cannot
/// place (a subscript outside its array). The interpreter would read a
/// ghost or fault there; the scatter declines instead of guessing which.
struct NotStatic;

impl IxNode {
    fn eval(&self, pt: &[f64]) -> Result<f64, NotStatic> {
        Ok(match self {
            IxNode::Lit(x) => *x,
            IxNode::Sym(k) => pt[*k],
            IxNode::Neg(a) => -a.eval(pt)?,
            IxNode::Un(op, a) => apply_unary(op, a.eval(pt)?),
            IxNode::Fold(op, args) => {
                let mut vs: SmallVec<[f64; 4]> = SmallVec::with_capacity(args.len());
                for a in args {
                    vs.push(a.eval(pt)?);
                }
                fold_scalar(op, &vs)
            }
            IxNode::Cmp(op, a, b) => apply_binary(op, a.eval(pt)?, b.eval(pt)?),
            IxNode::Index { vals, shape, subs } => {
                let mut flat = 0usize;
                for (d, s) in subs.iter().enumerate() {
                    // `eval_index_args`: the subscript rounded.
                    let raw = s.eval(pt)?.round();
                    if !(raw >= 1.0 && raw <= shape[d] as f64) {
                        return Err(NotStatic);
                    }
                    flat = flat * shape[d] + (raw as usize - 1);
                }
                // A read of a bound array rounds on entry, as a literal does.
                crate::precision::active().round(vals[flat])
            }
        })
    }
}

/// The conjuncts of a filter: the arguments of a top-level `and`, else the
/// filter itself.
fn conjuncts(filter: &Expr) -> (&[Expr], bool) {
    match filter {
        Expr::Operator(n) if n.op == "and" && is_plain(n) && !n.args.is_empty() => {
            (&n.args[..], true)
        }
        _ => (std::slice::from_ref(filter), false),
    }
}

/// An operator node with no sidecar body, filter or ranges: a plain call.
fn is_plain(n: &ExpressionNode) -> bool {
    n.expr.is_none()
        && n.filter.is_none()
        && n.ranges.is_none()
        && n.join.is_none()
        && n.key.is_none()
        && n.values.is_none()
}

/// Whether `e` mentions any of `names` as a variable (sidecars included).
fn reads_any(e: &Expr, names: &[String]) -> bool {
    let mut seen: HashSet<String> = HashSet::new();
    standalone::collect_variable_names(e, &mut seen);
    names.iter().any(|n| seen.contains(n))
}

/// The output index a conjunct pins, and the expression it pins it to:
/// `j == e` or `e == j` with `j` an output index and `e` reading none.
fn pin_of<'e>(c: &'e Expr, idx_names: &[String]) -> Option<(usize, &'e Expr)> {
    let Expr::Operator(n) = c else {
        return None;
    };
    if n.op != "==" || n.args.len() != 2 || !is_plain(n) {
        return None;
    }
    for (a, b) in [(&n.args[0], &n.args[1]), (&n.args[1], &n.args[0])] {
        if let Expr::Variable(v) = a
            && let Some(d) = idx_names.iter().position(|s| s == v)
            && !reads_any(b, idx_names)
        {
            return Some((d, b));
        }
    }
    None
}

impl TapeBuilder<'_> {
    /// Compile `e` as a build-time expression over the loop symbols `syms`;
    /// `None` when it reads anything the build does not know. Every leaf
    /// but a loop symbol is rounded to the working precision, as the
    /// interpreter rounds literals and bindings on entry (`precision`
    /// module docs); the operators' kernels already round per operation.
    fn ix_compile(&self, e: &Expr, syms: &[String]) -> Option<IxNode> {
        let lit = |x: f64| IxNode::Lit(crate::precision::active().round(x));
        Some(match e {
            Expr::Integer(n) => lit(*n as f64),
            Expr::Number(x) => lit(*x),
            Expr::Variable(v) => {
                if let Some(k) = syms.iter().position(|s| s == v) {
                    IxNode::Sym(k)
                } else if let Some(&x) = self.baked_params.get(v.as_str()) {
                    lit(x)
                } else {
                    match self.known_named(v)? {
                        (shape, vals) if shape.is_empty() && vals.len() == 1 => lit(vals[0]),
                        _ => return None,
                    }
                }
            }
            Expr::Operator(n) if is_plain(n) => {
                let op: &'static str = match n.op.as_str() {
                    "+" => "+",
                    "-" => "-",
                    "*" => "*",
                    "/" => "/",
                    "and" => "and",
                    "or" => "or",
                    "==" => "==",
                    "!=" => "!=",
                    "<" => "<",
                    "<=" => "<=",
                    ">" => ">",
                    ">=" => ">=",
                    "index" => return self.ix_compile_index(n, syms),
                    "floor" | "ceil" | "abs" | "sign" => {
                        let op: &'static str = match n.op.as_str() {
                            "floor" => "floor",
                            "ceil" => "ceil",
                            "abs" => "abs",
                            _ => "sign",
                        };
                        let [a] = &n.args[..] else {
                            return None;
                        };
                        return Some(IxNode::Un(op, Box::new(self.ix_compile(a, syms)?)));
                    }
                    _ => return None,
                };
                if n.args.is_empty() {
                    return None;
                }
                let args = n
                    .args
                    .iter()
                    .map(|a| self.ix_compile(a, syms))
                    .collect::<Option<Vec<_>>>()?;
                match op {
                    "==" | "!=" | "<" | "<=" | ">" | ">=" => {
                        let [a, b]: [IxNode; 2] = args.try_into().ok()?;
                        IxNode::Cmp(op, Box::new(a), Box::new(b))
                    }
                    "-" if args.len() == 1 => {
                        IxNode::Neg(Box::new(args.into_iter().next().expect("one operand")))
                    }
                    // The registry's arities; anything else is not folded here.
                    "-" | "/" if args.len() != 2 => return None,
                    _ => IxNode::Fold(op, args),
                }
            }
            _ => return None,
        })
    }

    fn ix_compile_index(&self, n: &ExpressionNode, syms: &[String]) -> Option<IxNode> {
        let (Expr::Variable(base), subs) = n.args.split_first()? else {
            return None;
        };
        if syms.contains(base) {
            return None;
        }
        let (shape, vals) = self.known_named(base)?;
        if shape.is_empty() || shape.len() != subs.len() || shape.contains(&0) {
            return None;
        }
        let subs = subs
            .iter()
            .map(|s| self.ix_compile(s, syms))
            .collect::<Option<Vec<_>>>()?;
        Some(IxNode::Index { vals, shape, subs })
    }

    /// The one-pass equality scatter (module docs), or `None` when the
    /// contraction is not one it serves — no conjunct pins an output index,
    /// a pinned value is not build-time data, a ragged bound reads a pinned index —
    /// or a point's value cannot be placed. Nothing is emitted before the
    /// tuple list is lowered, so a `None` needs no rollback; an `Err` comes
    /// from that lowering, and the caller rolls it back.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn lower_equality_scatter(
        &mut self,
        idx_names: &[String],
        lo: &DimI,
        shape: &DimU,
        body: &Expr,
        contract_names: &[String],
        contract_dims: &[ContractDim],
        reduce: ReduceKind,
        filter: Option<&Expr>,
    ) -> LResult<Option<LV>> {
        let Some(filter) = filter else {
            return Ok(None);
        };
        let nr = idx_names.len();
        let nc = contract_names.len();
        if nr == 0 || nc == 0 {
            return Ok(None);
        }
        let (parts, is_and) = conjuncts(filter);
        // The first conjunct to pin an index pins it; a later one that pins
        // the same index is an ordinary remaining conjunct.
        let mut pins: Vec<Option<&Expr>> = vec![None; nr];
        let mut pinned_by: Vec<bool> = vec![false; parts.len()];
        for (k, c) in parts.iter().enumerate() {
            if let Some((d, e)) = pin_of(c, idx_names)
                && pins[d].is_none()
            {
                pins[d] = Some(e);
                pinned_by[k] = true;
            }
        }
        if pins.iter().all(Option::is_none) {
            return Ok(None);
        }
        // The contracted ranges. A ragged bound may read a free output index
        // or a contracted one, never a pinned output index: a pinned cell is
        // not known until its point is.
        for d in contract_dims {
            match d {
                ContractDim::Ragged { of, .. } => {
                    for p in of {
                        match idx_names.iter().position(|n| n == p) {
                            Some(k) if pins[k].is_some() => return Ok(None),
                            Some(_) => {}
                            None if contract_names.contains(p) => {}
                            None => return Ok(None),
                        }
                    }
                }
                ContractDim::Derived { from_faq } if self.ring_extent(from_faq).is_none() => {
                    return Ok(None);
                }
                _ => {}
            }
        }
        let Ok(bounds) = self.tuple_dim_bounds(idx_names, contract_names, contract_dims) else {
            return Ok(None);
        };
        let Ok(combine_op) = self.array_combine_op(reduce, "contracted") else {
            return Ok(None);
        };
        if let Some(v) = self.lower_shift_scatter(
            idx_names,
            lo,
            shape,
            body,
            contract_names,
            &bounds,
            reduce,
            parts,
            &pins,
        )? {
            return Ok(Some(v));
        }
        // A point's values: the output indices, then the contracted names
        // (the tuple list's column order).
        let mut syms: Vec<String> = idx_names.to_vec();
        syms.extend(contract_names.iter().cloned());
        let mut pin_nodes: Vec<Option<IxNode>> = Vec::with_capacity(nr);
        for p in &pins {
            pin_nodes.push(match p {
                Some(e) => match self.ix_compile(e, &syms) {
                    Some(n) => Some(n),
                    // A run-time pin: no build-time map (module docs).
                    None => return Ok(None),
                },
                None => None,
            });
        }
        // The remaining conjuncts: evaluated here when the build can, else
        // kept for the run-time mask.
        let mut static_rest: Vec<IxNode> = Vec::new();
        let mut runtime_rest: Vec<Expr> = Vec::new();
        for (k, c) in parts.iter().enumerate() {
            if pinned_by[k] {
                continue;
            }
            match self.ix_compile(c, &syms) {
                Some(n) => static_rest.push(n),
                None => runtime_rest.push(c.clone()),
            }
        }

        let free: Vec<usize> = (0..nr).filter(|&d| pins[d].is_none()).collect();
        let n_free: usize = free.iter().map(|&d| shape[d]).product();
        let n_out: usize = shape.iter().product();
        if n_out >= u32::MAX as usize {
            return Ok(None);
        }
        let mut strides = vec![1usize; nr];
        for d in (0..nr.saturating_sub(1)).rev() {
            strides[d] = strides[d + 1] * shape[d + 1];
        }
        let prec = crate::precision::active();
        // The walk: the free cells row-major, and in each one the contracted
        // names in the interpreter's order — an odometer, the last name
        // fastest, or, when a ragged bound reads a contracted index, the
        // nest that binds each parent before the ranges it bounds
        // (`reduce_contraction`, [`walk_nest`]). Each admitted point is
        // recorded as its cell and contracted values.
        let order: Vec<usize> = if bounds.iter().any(DimBound::reads_contracted) {
            parent_first_order(&bounds)
        } else {
            (0..nc).collect()
        };
        let mut cell_of: Vec<u32> = Vec::new();
        let mut at: Vec<i64> = Vec::new();
        let mut visits: u64 = 0;
        let mut declined = false;
        let mut pt: Vec<f64> = vec![0.0; nr + nc];
        let mut cell_ix: Vec<i64> = vec![0; nr];
        let mut cur: Vec<i64> = vec![0; nc];
        let mut fdig: SmallVec<[usize; 4]> = SmallVec::from_elem(0, free.len());
        for _ in 0..n_free {
            for (k, &d) in free.iter().enumerate() {
                cell_ix[d] = lo[d] + fdig[k] as i64;
                pt[d] = cell_ix[d] as f64;
            }
            let mut point = |c: &[i64]| -> bool {
                visits += 1;
                if visits > MAX_SCATTER_VISITS {
                    declined = true;
                    return false;
                }
                for k in 0..nc {
                    pt[nr + k] = c[k] as f64;
                }
                let mut cell = 0usize;
                for d in 0..nr {
                    if let Some(node) = &pin_nodes[d] {
                        let Ok(v) = node.eval(&pt) else {
                            declined = true;
                            return false;
                        };
                        let off = v - lo[d] as f64;
                        if !(v.fract() == 0.0 && off >= 0.0 && off < shape[d] as f64) {
                            return true;
                        }
                        pt[d] = v;
                    }
                    cell += (pt[d] as i64 - lo[d]) as usize * strides[d];
                }
                for n in &static_rest {
                    let Ok(v) = n.eval(&pt) else {
                        declined = true;
                        return false;
                    };
                    // `fold_scalar`'s `and`: nonzero at the working
                    // precision; a bare conjunct, the filter's own
                    // `== 0.0` test.
                    let held = if is_and {
                        prec.round(v) != 0.0
                    } else {
                        v != 0.0
                    };
                    if !held {
                        return true;
                    }
                }
                if cell_of.len() >= MAX_PROMOTED_ELEMS {
                    declined = true;
                    return false;
                }
                cell_of.push(cell as u32);
                at.extend_from_slice(c);
                true
            };
            if !walk_nest(&bounds, &order, 0, &cell_ix, &mut cur, &mut point) || declined {
                return Ok(None);
            }
            for k in (0..free.len()).rev() {
                fdig[k] += 1;
                if fdig[k] < shape[free[k]] {
                    break;
                }
                fdig[k] = 0;
            }
        }

        // Stable bucketing by cell: each cell's run in visit order.
        let m = cell_of.len();
        let mut rows: Vec<u32> = vec![0; n_out + 1];
        for &c in &cell_of {
            rows[c as usize + 1] += 1;
        }
        for c in 0..n_out {
            rows[c + 1] += rows[c];
        }
        let mut next: Vec<u32> = rows[..n_out].to_vec();
        let mut order: Vec<u32> = vec![0; m];
        for (k, &c) in cell_of.iter().enumerate() {
            order[next[c as usize] as usize] = k as u32;
            next[c as usize] += 1;
        }
        drop(next);
        let mut cols: Vec<Vec<f64>> = (0..nr + nc).map(|_| Vec::with_capacity(m)).collect();
        for &k in &order {
            let k = k as usize;
            let mut cell = cell_of[k] as usize;
            for d in 0..nr {
                cols[d].push((lo[d] + (cell / strides[d]) as i64) as f64);
                cell %= strides[d];
            }
            for c in 0..nc {
                cols[nr + c].push(at[k * nc + c] as f64);
            }
        }
        drop(order);
        drop(cell_of);
        drop(at);

        // The filter left for run-time: the conjuncts the build could not
        // evaluate, still under `and` so a kept term is the same flag test.
        let residual: Option<Expr> = match runtime_rest.len() {
            0 => None,
            _ if !is_and => runtime_rest.pop(),
            1 => {
                runtime_rest.push(Expr::Integer(1));
                Some(and_of(runtime_rest))
            }
            _ => Some(and_of(runtime_rest)),
        };
        let ranges: Vec<(i64, i64)> = lo
            .iter()
            .zip(shape)
            .map(|(&l, &n)| (l, l + n as i64 - 1))
            .collect();
        let spec = TupleSpec {
            idx_names,
            ranges: &ranges,
            body,
            contract_names,
            bounds: &[],
            gates: &[],
            reduce,
            filter: residual.as_ref(),
            init: reduce.identity(),
        };
        self.tuples_held = self.tuples_held.saturating_add(m as u64);
        let list = TupleList { rows, cols };
        let v = self.lower_tuple_list(&spec, list, lo, shape, combine_op);
        self.held_exprs.extend(residual);
        v.map(Some)
    }
}

impl TapeBuilder<'_> {
    /// The scatter whose one pin is a unit shift of the one contracted index,
    /// `j == i + k` (or `i - k`, `i`, mirrored), with nothing else in the
    /// filter: each cell `j` of the shifted range receives exactly one term,
    /// the body at `i = j - k`, and every other cell none. That is a stencil
    /// read, not a scatter: the body is lowered over the output box with `i`
    /// replaced by `j - k`, filtered to the cells that receive a term, and
    /// combined once into the identity, `identity ⊕ term` — the fold of a
    /// one-term run. No point is walked at build time.
    ///
    /// Only for `+` and `*`, whose one-term fold is the elementwise kernel
    /// itself; `max` / `min` keep the tuple list, whose fold step is the
    /// reduction's own.
    #[allow(clippy::too_many_arguments)]
    fn lower_shift_scatter(
        &mut self,
        idx_names: &[String],
        lo: &DimI,
        shape: &DimU,
        body: &Expr,
        contract_names: &[String],
        bounds: &[DimBound],
        reduce: ReduceKind,
        parts: &[Expr],
        pins: &[Option<&Expr>],
    ) -> LResult<Option<LV>> {
        if !matches!(reduce, ReduceKind::Sum | ReduceKind::Product) || parts.len() != 1 {
            return Ok(None);
        }
        let ([i_name], [DimBound::Static(ilo, ihi)]) = (contract_names, bounds) else {
            return Ok(None);
        };
        let Some(d) = pins.iter().position(Option::is_some) else {
            return Ok(None);
        };
        let Some(k) = pins[d].and_then(|e| unit_shift(e, i_name)) else {
            return Ok(None);
        };
        if !is_plain_tree(body) {
            return Ok(None);
        }
        let Some(jlo) = ilo.checked_add(k) else {
            return Ok(None);
        };
        let Some(jhi) = ihi.checked_add(k) else {
            return Ok(None);
        };
        // The cells that receive a term.
        let out_hi = lo[d] + shape[d] as i64 - 1;
        let (a, b) = (jlo.max(lo[d]), jhi.min(out_hi));
        let identity = reduce.identity();
        if a > b {
            return Ok(Some(self.emit_fill(
                &LV::Lit(identity),
                shape,
                lo,
                Cadence::Const,
            )));
        }
        // `i` read as `j - k`: the same integer, so every value the body
        // computes from it is the same.
        let j = Expr::Variable(idx_names[d].clone());
        let i_as = match k {
            0 => j,
            k if k > 0 => Expr::operator(ExpressionNode {
                op: "-".to_string(),
                args: vec![j, Expr::Integer(k)],
                ..Default::default()
            }),
            k => Expr::operator(ExpressionNode {
                op: "+".to_string(),
                args: vec![j, Expr::Integer(-k)],
                ..Default::default()
            }),
        };
        let body = substitute(body, i_name, &i_as);
        // The cells outside the shifted range receive no term: a filter on
        // `j` alone, under which the body is a lazily evaluated position
        // there, as it is at every excluded point of the naive walk.
        let mut keep: Vec<Expr> = Vec::new();
        let jv = || Expr::Variable(idx_names[d].clone());
        let cmp = |op: &str, x: Expr, y: Expr| {
            Expr::operator(ExpressionNode {
                op: op.to_string(),
                args: vec![x, y],
                ..Default::default()
            })
        };
        if a > lo[d] {
            keep.push(cmp(">=", jv(), Expr::Integer(a)));
        }
        if b < out_hi {
            keep.push(cmp("<=", jv(), Expr::Integer(b)));
        }
        let keep = match keep.len() {
            0 => None,
            1 => keep.pop(),
            _ => Some(and_of(keep)),
        };
        self.push_scope();
        let bx = LBox {
            syms: idx_names,
            lo: lo.clone(),
            shape: shape.clone(),
            cnames: &[],
            cvals: SmallVec::new(),
            tuple: 0,
            visit: SmallVec::new(),
        };
        let term = self.lower_filtered(&body, keep.as_ref(), &bx, LV::Lit(identity));
        self.pop_scope();
        self.held_exprs.push(body);
        self.held_exprs.extend(keep);
        let Some(term) = term? else {
            return Ok(Some(self.emit_fill(
                &LV::Lit(identity),
                shape,
                lo,
                Cadence::Const,
            )));
        };
        if matches!(&term, LV::State(_)) && self.lv_box(&term).is_some() {
            bail_tape!("scatter: term reduced to a bare whole-array view");
        }
        let term = match self.lv_box(&term) {
            None => self.emit_fill(&term, shape, lo, Cadence::Const),
            Some((s, o)) if s == *shape && o == *lo => term,
            Some(_) => bail_tape!("scatter: term box does not match the output box"),
        };
        let combine_op = self.array_combine_op(reduce, "contracted")?;
        self.emit_bin(combine_op, LV::Lit(identity), term).map(Some)
    }
}

/// `k` when `e` is `i + k`, `k + i`, `i - k` (as `-k`) or `i` (`0`), with
/// `k` an integer literal.
fn unit_shift(e: &Expr, i_name: &str) -> Option<i64> {
    let int = |e: &Expr| match e {
        Expr::Integer(n) => Some(*n),
        Expr::Number(x) if x.fract() == 0.0 && x.abs() < 1e15 => Some(*x as i64),
        _ => None,
    };
    let is_i = |e: &Expr| matches!(e, Expr::Variable(v) if v == i_name);
    match e {
        Expr::Variable(v) if v == i_name => Some(0),
        Expr::Operator(n) if is_plain(n) && n.args.len() == 2 => match n.op.as_str() {
            "+" if is_i(&n.args[0]) => int(&n.args[1]),
            "+" if is_i(&n.args[1]) => int(&n.args[0]),
            "-" if is_i(&n.args[0]) => int(&n.args[1]).and_then(i64::checked_neg),
            _ => None,
        },
        _ => None,
    }
}

/// Whether every node of `e` is a plain call (no node binds a name of its
/// own, so a substitution reaches every read).
fn is_plain_tree(e: &Expr) -> bool {
    match e {
        Expr::Operator(n) => {
            is_plain(n)
                && n.lower.is_none()
                && n.upper.is_none()
                && n.int_var.is_none()
                && n.output_idx.is_none()
                && n.regions.is_none()
                && n.args.iter().all(is_plain_tree)
        }
        _ => true,
    }
}

/// `e` with every read of `name` replaced by `with`.
fn substitute(e: &Expr, name: &str, with: &Expr) -> Expr {
    match e {
        Expr::Variable(v) if v == name => with.clone(),
        Expr::Operator(n) => {
            let mut node = (**n).clone();
            node.args = n.args.iter().map(|a| substitute(a, name, with)).collect();
            Expr::operator(node)
        }
        other => other.clone(),
    }
}

fn and_of(args: Vec<Expr>) -> Expr {
    Expr::operator(ExpressionNode {
        op: "and".to_string(),
        args,
        ..Default::default()
    })
}
