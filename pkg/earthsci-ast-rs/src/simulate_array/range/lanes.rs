//! `lanes` (API_SPEC §5.8, RFC U3 §6): a pointwise or column operator over a
//! run-time list of cells or columns.
//!
//! A lane program is the operator's rules rewritten over one lane axis of
//! `capacity` lanes (and, for a column operator, the whole of every other
//! axis), and re-lowered: a state read at the lane's own cell becomes a read
//! of the lane block, and every value that depends on the cell's index — a
//! coordinate, a level gate, an affine read of an array parameter, a forcing
//! buffer or a state-free observed — is computed from the lane's entry of
//! `cells`, which the call copies into the program's state each time. One
//! build serves every batch of up to `capacity` lanes; a lane's result
//! depends only on its own inputs, so lane order, duplicates and padding
//! cannot change a value.
//!
//! The pre-gather plan ([`LaneProgram::lane_inputs`]) hoists every read of a
//! non-state array whose subscripts depend on the lane's cell alone into a
//! per-lane buffer: [`LaneProgram::gather_lane_inputs`] fills the buffers once
//! per batch, and [`LaneProgram::eval_gathered_into`] runs the program with
//! those reads replaced by reads of the buffers.

use super::tile::{declined_error, plain_precision, refused, shell};
use super::walk::AxisSpec;
use super::{
    Blocks, Decomposition, LaneKind, LaneLayout, RhsProgram, RhsWorkspace, TileInput, WsExec,
    build_error, check_lengths, index_set_sizes, take_fault, var_infos,
};
use crate::simulate::SimulateError;
use crate::simulate_array::tape::{
    CallInputs, TapeCtx, TapeProgram, TileLowering, run_tape_inputs,
};
use crate::simulate_array::{AlgebraicRule, ArrayCompiled, RhsRule, VarShape};
use crate::types::{Expr, ExpressionNode, RegionBound};
use indexmap::IndexMap;
use ndarray::ArrayD;
use rustc_hash::FxHashMap;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;

/// The lane symbol every rewritten rule runs over.
const LANE: &str = "__lane";

fn cell_var(set: &str) -> String {
    format!("__cell_{set}")
}

fn input_var(k: usize) -> String {
    format!("__lane_input_{k}")
}

/// A lane program (RFC U3 §6). `Send + Sync`.
pub struct LaneProgram {
    main: Arc<TapeProgram>,
    pre: Arc<TapeProgram>,
    gather: Arc<TapeProgram>,
    blocks: Blocks,
    layout: LaneLayout,
    forcing: Arc<HashMap<String, ArrayD<f64>>>,
    capacity: usize,
    sets: Vec<String>,
    /// The global extent of each lane set, for validating `cells`.
    extents: Vec<i64>,
    n_inputs: usize,
    n_params: usize,
    declared: Arc<HashSet<String>>,
    precision: crate::precision::Precision,
}

impl std::fmt::Debug for LaneProgram {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LaneProgram")
            .field("capacity", &self.capacity)
            .field("sets", &self.sets)
            .field("layout", &self.layout)
            .finish()
    }
}

/// The per-lane buffers of a lane program's pre-gather plan: one run of
/// `capacity` values per hoisted read. Filled by
/// [`LaneProgram::gather_lane_inputs`], read by
/// [`LaneProgram::eval_gathered_into`].
pub struct LaneInputs {
    owner: usize,
    values: Vec<f64>,
    state: Vec<f64>,
    ctx: Box<TapeCtx>,
}

impl std::fmt::Debug for LaneInputs {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LaneInputs")
            .field("len", &self.values.len())
            .finish()
    }
}

impl LaneInputs {
    /// The gathered values: hoisted read `k`'s lanes at `k * capacity ..`.
    pub fn values(&self) -> &[f64] {
        &self.values
    }
}

impl LaneProgram {
    /// The lane layout (RFC U3 §6): each variable a column-major block whose
    /// first axis is the lane (`1..=capacity`) and whose other axes are the
    /// variable's axes outside the lane's sets, in order.
    pub fn layout(&self) -> &LaneLayout {
        &self.layout
    }

    /// The number of lanes the program was built for.
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// The number of hoisted reads the pre-gather plan fills.
    pub fn n_lane_inputs(&self) -> usize {
        self.n_inputs
    }

    /// Buffers for [`Self::eval_into`] and [`Self::eval_gathered_into`].
    pub fn new_workspace(&self) -> RhsWorkspace {
        let n = self.blocks.u_len
            + self.blocks.aux_len
            + self.capacity * (self.sets.len() + self.n_inputs);
        RhsWorkspace {
            owner: Arc::as_ptr(&self.main) as usize,
            state: vec![0.0; n],
            dy: Vec::new(),
            exec: WsExec::Lanes {
                main: Box::new(TapeCtx::new(Arc::clone(&self.main))),
                pre: Box::new(TapeCtx::new(Arc::clone(&self.pre))),
            },
        }
    }

    /// Copy `cells` (`[D, L]`, column-major, 1-based global indices) into the
    /// lane rows of `state` starting at `at`, as `f64`. Only lanes `1..=n` are
    /// read from `cells` (and range-checked); every lane past `n` repeats lane
    /// 1 (or cell 1 when `n = 0`), so the padding lanes the tape still
    /// computes read in-range indices whatever the tail of `cells` holds.
    fn write_cells(
        &self,
        state: &mut [f64],
        at: usize,
        cells: &[i32],
        n: usize,
    ) -> Result<(), SimulateError> {
        let d = self.sets.len();
        if n > self.capacity {
            return Err(build_error(format!(
                "`lanes`: n = {n} exceeds the program's capacity {}",
                self.capacity
            )));
        }
        if !cells.len().is_multiple_of(d.max(1))
            || cells.len() / d.max(1) < n
            || cells.len() / d.max(1) > self.capacity
        {
            return Err(build_error(format!(
                "`lanes`: `cells` holds {} entries, which is not D = {d} times a lane count \
                 between n = {n} and the capacity {}",
                cells.len(),
                self.capacity
            )));
        }
        for (a, &ext) in self.extents.iter().enumerate() {
            let rows = &mut state[at + a * self.capacity..at + (a + 1) * self.capacity];
            for (l, row) in rows.iter_mut().enumerate() {
                let c = match (l < n, n > 0) {
                    (true, _) => cells[l * d + a],
                    (false, true) => cells[a],
                    (false, false) => 1,
                };
                if l < n && (i64::from(c) < 1 || i64::from(c) > ext) {
                    return Err(build_error(format!(
                        "`lanes`: lane {} names {} = {c}, outside 1..{ext}",
                        l + 1,
                        self.sets[a]
                    )));
                }
                *row = f64::from(c);
            }
        }
        Ok(())
    }

    /// Evaluate lanes `1..=n` (RFC U3 §6): for each lane `l` and each written
    /// variable, `du` holds the whole-domain program's value at `cells[:, l]`.
    #[allow(clippy::too_many_arguments)]
    pub fn eval_into(
        &self,
        u: &[f64],
        aux: &[f64],
        p: &[f64],
        t: f64,
        cells: &[i32],
        n: usize,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), SimulateError> {
        self.run(u, aux, None, p, t, cells, n, du, ws)
    }

    /// The pre-gather plan's buffers, unfilled.
    pub fn lane_inputs(&self) -> LaneInputs {
        LaneInputs {
            owner: Arc::as_ptr(&self.main) as usize,
            values: vec![0.0; self.capacity * self.n_inputs],
            state: vec![0.0; self.capacity * (self.n_inputs + self.sets.len())],
            ctx: Box::new(TapeCtx::new(Arc::clone(&self.gather))),
        }
    }

    /// Fill `inputs` for lanes `1..=n` of `cells`: every hoisted read of a
    /// non-state input, at each lane's cell.
    pub fn gather_lane_inputs(
        &self,
        inputs: &mut LaneInputs,
        p: &[f64],
        t: f64,
        cells: &[i32],
        n: usize,
    ) -> Result<(), SimulateError> {
        if inputs.owner != Arc::as_ptr(&self.main) as usize {
            return Err(build_error(
                "`gather_lane_inputs`: the inputs were made by another program".to_string(),
            ));
        }
        if p.len() != self.n_params {
            return Err(build_error(format!(
                "`gather_lane_inputs`: `p` has {} elements, the program {}",
                p.len(),
                self.n_params
            )));
        }
        self.write_cells(&mut inputs.state, self.capacity * self.n_inputs, cells, n)?;
        let _precision = crate::precision::enter(self.precision);
        crate::simulate_array::take_const_array_oob();
        let call = CallInputs {
            state: &inputs.state,
            params: p,
            forcing: &self.forcing,
            t,
            declared: &self.declared,
        };
        run_tape_inputs(&mut inputs.ctx, &call, &mut inputs.values, false);
        take_fault()
    }

    /// [`Self::eval_into`] with every hoisted read taken from `inputs`.
    #[allow(clippy::too_many_arguments)]
    pub fn eval_gathered_into(
        &self,
        u: &[f64],
        aux: &[f64],
        inputs: &LaneInputs,
        p: &[f64],
        t: f64,
        cells: &[i32],
        n: usize,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), SimulateError> {
        if inputs.owner != Arc::as_ptr(&self.main) as usize {
            return Err(build_error(
                "`eval_gathered_into`: the inputs were made by another program".to_string(),
            ));
        }
        self.run(u, aux, Some(&inputs.values), p, t, cells, n, du, ws)
    }

    #[allow(clippy::too_many_arguments)]
    fn run(
        &self,
        u: &[f64],
        aux: &[f64],
        gathered: Option<&[f64]>,
        p: &[f64],
        t: f64,
        cells: &[i32],
        n: usize,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), SimulateError> {
        check_lengths(&self.blocks, u, aux, du, p, self.n_params)?;
        if ws.owner != Arc::as_ptr(&self.main) as usize {
            return Err(build_error(
                "`eval_into`: the workspace was made by another program".to_string(),
            ));
        }
        let (nu, na) = (self.blocks.u_len, self.blocks.aux_len);
        ws.state[..nu].copy_from_slice(u);
        ws.state[nu..nu + na].copy_from_slice(aux);
        let mut state = std::mem::take(&mut ws.state);
        let res = self.write_cells(&mut state, nu + na, cells, n);
        let at = nu + na + self.capacity * self.sets.len();
        if let Some(g) = gathered {
            state[at..at + g.len()].copy_from_slice(g);
        }
        ws.state = state;
        res?;
        let WsExec::Lanes { main, pre } = &mut ws.exec else {
            unreachable!("a lane workspace runs lane tapes");
        };
        let ctx = if gathered.is_some() { pre } else { main };
        let _precision = crate::precision::enter(self.precision);
        crate::simulate_array::take_const_array_oob();
        let call = CallInputs {
            state: &ws.state,
            params: p,
            forcing: &self.forcing,
            t,
            declared: &self.declared,
        };
        run_tape_inputs(ctx, &call, du, false);
        take_fault()
    }
}

/// The rewrite of one program's rules over the lane axis.
struct Rewriter<'a> {
    /// The index-set name of each axis of each state and array observed.
    axes: &'a HashMap<String, Vec<Option<String>>>,
    /// The states and state-dependent observeds that become lane blocks.
    lane_vars: &'a HashSet<String>,
    sets: &'a [String],
    sizes: &'a HashMap<String, i64>,
    cells: bool,
    capacity: i64,
    rule: String,
    /// The hoisted non-state reads of the pre-gather plan.
    gathers: Vec<Expr>,
    /// Replace each hoisted read by its lane buffer.
    pre: bool,
}

/// The symbols in force while rewriting: the original output symbols that
/// run along a lane set (each mapped to that set), and every other symbol.
#[derive(Clone, Default)]
struct LScope {
    lane_syms: Vec<(String, String)>,
    inner: Vec<String>,
}

impl LScope {
    fn lane_set(&self, sym: &str) -> Option<&str> {
        self.lane_syms
            .iter()
            .find(|(s, _)| s == sym)
            .map(|(_, set)| set.as_str())
    }
}

type RResult<T> = Result<T, SimulateError>;

fn lane_read(set: &str) -> Expr {
    Expr::operator(ExpressionNode {
        op: "index".to_string(),
        args: vec![
            Expr::Variable(cell_var(set)),
            Expr::Variable(LANE.to_string()),
        ],
        ..Default::default()
    })
}

fn mentions(e: &Expr, pred: &mut dyn FnMut(&str) -> bool) -> bool {
    match e {
        Expr::Variable(v) => pred(v),
        Expr::Operator(n) => n.any_child(&mut |c| mentions(c, pred)),
        _ => false,
    }
}

impl Rewriter<'_> {
    fn refuse<T>(&self, what: impl std::fmt::Display) -> RResult<T> {
        Err(refused(format!("lane: rule `{}` {what}", self.rule)))
    }

    fn expr(&mut self, e: &Expr, sc: &LScope) -> RResult<Expr> {
        match e {
            Expr::Number(_) | Expr::Integer(_) => Ok(e.clone()),
            Expr::Variable(v) => {
                if let Some(set) = sc.lane_set(v) {
                    return Ok(lane_read(set));
                }
                if sc.inner.contains(v) {
                    return Ok(e.clone());
                }
                if self.lane_vars.contains(v) && self.axes.get(v).is_some_and(|a| !a.is_empty()) {
                    return self.refuse(format_args!("reads the array `{v}` whole"));
                }
                Ok(e.clone())
            }
            Expr::Operator(node) => match node.op.as_str() {
                "index" if !node.args.is_empty() => self.index(node, sc),
                "makearray" => self.refuse("holds a makearray outside a subscripted read"),
                "faq" | "aggregate" => {
                    if node.output_idx.as_ref().is_some_and(|o| !o.is_empty()) {
                        return self.refuse("holds an array-valued faq in an elementwise position");
                    }
                    let mut inner = sc.clone();
                    if let Some(r) = &node.ranges {
                        for k in r.keys() {
                            inner.lane_syms.retain(|(s, _)| s != k);
                            if !inner.inner.contains(k) {
                                inner.inner.push(k.clone());
                            }
                        }
                    }
                    let mut n = ExpressionNode::clone(node);
                    if let Some(b) = node.expr.as_deref() {
                        n.expr = Some(Box::new(self.expr(b, &inner)?));
                    }
                    if let Some(f) = node.filter.as_deref() {
                        n.filter = Some(Box::new(self.expr(f, &inner)?));
                    }
                    Ok(Expr::operator(n))
                }
                _ => {
                    let mut err = None;
                    let out = node.map_children(&mut |c| match self.expr(c, sc) {
                        Ok(x) => x,
                        Err(r) => {
                            err.get_or_insert(r);
                            c.clone()
                        }
                    });
                    match err {
                        Some(r) => Err(r),
                        None => Ok(Expr::operator(out)),
                    }
                }
            },
        }
    }

    fn index(&mut self, node: &Arc<ExpressionNode>, sc: &LScope) -> RResult<Expr> {
        let base = &node.args[0];
        let subs = &node.args[1..];
        match base {
            Expr::Variable(v) if self.lane_vars.contains(v) => {
                let axes = self.axes.get(v).cloned().unwrap_or_default();
                if axes.len() != subs.len() {
                    return self.refuse(format_args!("reads `{v}` at the wrong rank"));
                }
                let mut new_args = vec![base.clone(), Expr::Variable(LANE.to_string())];
                for (d, s) in subs.iter().enumerate() {
                    match axes[d]
                        .as_deref()
                        .filter(|set| self.sets.iter().any(|x| x == set))
                    {
                        Some(set) => {
                            let own = matches!(s, Expr::Variable(x) if sc.lane_set(x) == Some(set));
                            if !own {
                                return self.refuse(format_args!(
                                    "reads `{v}` off its own lane's cell along `{set}`, which is \
                                     not {} locality",
                                    if self.cells { "pointwise" } else { "column" }
                                ));
                            }
                        }
                        None => new_args.push(self.expr(s, sc)?),
                    }
                }
                let mut n = ExpressionNode::clone(node);
                n.args = new_args;
                Ok(Expr::operator(n))
            }
            Expr::Variable(_) => {
                let mut new_subs = Vec::with_capacity(subs.len());
                for s in subs {
                    new_subs.push(self.expr(s, sc)?);
                }
                let mut n = ExpressionNode::clone(node);
                n.args = std::iter::once(base.clone()).chain(new_subs).collect();
                let read = Expr::operator(n);
                // A read whose subscripts depend on the lane's cell alone
                // (and on no other symbol) is one value per lane: hoisted.
                let by_cell = read_mentions_lane(&read)
                    && !mentions(&read, &mut |x| sc.inner.iter().any(|s| s == x));
                if !by_cell {
                    return Ok(read);
                }
                let k = match self.gathers.iter().position(|g| *g == read) {
                    Some(k) => k,
                    None => {
                        self.gathers.push(read.clone());
                        self.gathers.len() - 1
                    }
                };
                if self.pre {
                    return Ok(Expr::operator(ExpressionNode {
                        op: "index".to_string(),
                        args: vec![
                            Expr::Variable(input_var(k)),
                            Expr::Variable(LANE.to_string()),
                        ],
                        ..Default::default()
                    }));
                }
                Ok(read)
            }
            Expr::Operator(m) if m.op == "makearray" => self.makearray_read(node, m, sc),
            _ => self.refuse("subscripts an array expression a lane cannot restrict"),
        }
    }

    /// `index(makearray(…), syms…)` with the box's own symbols in order: a
    /// makearray whose regions span the whole of every lane set, rewritten
    /// over the lane axis and the other axes.
    fn makearray_read(
        &mut self,
        node: &Arc<ExpressionNode>,
        m: &Arc<ExpressionNode>,
        sc: &LScope,
    ) -> RResult<Expr> {
        let subs = &node.args[1..];
        let (Some(regions), Some(values)) = (m.regions.as_ref(), m.values.as_ref()) else {
            return self.refuse("holds a makearray with no regions");
        };
        // Per axis: the lane set it runs along, if any.
        let mut lane_axes: Vec<Option<String>> = Vec::with_capacity(subs.len());
        let mut inner_subs = Vec::new();
        for s in subs {
            match s {
                Expr::Variable(x) if sc.lane_set(x).is_some() => {
                    lane_axes.push(sc.lane_set(x).map(str::to_string));
                }
                Expr::Variable(x) if sc.inner.contains(x) => {
                    lane_axes.push(None);
                    inner_subs.push(s.clone());
                }
                _ => {
                    return self.refuse("subscripts a makearray at a shifted or computed position");
                }
            }
        }
        let mut new_regions = Vec::with_capacity(regions.len());
        let mut new_values = Vec::with_capacity(values.len());
        for (region, value) in regions.iter().zip(values) {
            if region.len() != subs.len() {
                return self.refuse("reads a makearray at the wrong rank");
            }
            let mut r = vec![[RegionBound::Int(1), RegionBound::Int(self.capacity)]];
            let inner_sc = sc.clone();
            for (d, b) in region.iter().enumerate() {
                let Some([lo, hi]) = crate::types::region_bounds(b) else {
                    return self.refuse("holds a makearray with a symbolic region bound");
                };
                match &lane_axes[d] {
                    Some(set) => {
                        let n = self.sizes.get(set).copied().unwrap_or(-1);
                        if lo != 1 || hi != n {
                            return self.refuse(format_args!(
                                "holds a makearray region {lo}..{hi} along the lane set `{set}`, \
                                 which depends on the lane's cell"
                            ));
                        }
                    }
                    None => r.push(b.clone()),
                }
            }
            if let Expr::Operator(v) = value
                && (v.op == "faq" || v.op == "aggregate")
                && v.output_idx.as_ref().is_some_and(|o| !o.is_empty())
            {
                return self.refuse("holds a faq region value");
            }
            new_values.push(self.expr(value, &inner_sc)?);
            new_regions.push(r);
        }
        let mut nm = ExpressionNode::clone(m);
        nm.regions = Some(new_regions);
        nm.values = Some(new_values);
        let mut n = ExpressionNode::clone(node);
        n.args = std::iter::once(Expr::operator(nm))
            .chain(std::iter::once(Expr::Variable(LANE.to_string())))
            .chain(inner_subs)
            .collect();
        Ok(Expr::operator(n))
    }
}

fn read_mentions_lane(e: &Expr) -> bool {
    mentions(e, &mut |x| x.starts_with("__cell_"))
}

struct Rewritten {
    rhs: Vec<RhsRule>,
    observed: Vec<AlgebraicRule>,
    gathers: Vec<Expr>,
}

#[allow(clippy::too_many_arguments)]
fn rewrite(
    compiled: &ArrayCompiled,
    axes: &HashMap<String, Vec<Option<String>>>,
    lane_vars: &HashSet<String>,
    dependent: &HashSet<String>,
    sets: &[String],
    sizes: &HashMap<String, i64>,
    cells: bool,
    capacity: i64,
    pre: bool,
) -> RResult<Rewritten> {
    let mut rw = Rewriter {
        axes,
        lane_vars,
        sets,
        sizes,
        cells,
        capacity,
        rule: String::new(),
        gathers: Vec::new(),
        pre,
    };
    // The lane box of a rule writing `var` over `syms`/`ranges`.
    let lane_box = |rw: &Rewriter,
                    var: &str,
                    syms: &[String],
                    ranges: &[(i64, i64)]|
     -> RResult<(LScope, Vec<String>, Vec<(i64, i64)>)> {
        let var_axes = axes.get(var).cloned().unwrap_or_default();
        if var_axes.len() != syms.len() {
            return rw.refuse(format_args!(
                "writes `{var}` through a reshaped left-hand side"
            ));
        }
        let mut sc = LScope::default();
        let mut out_syms = vec![LANE.to_string()];
        let mut out_ranges = vec![(1, capacity)];
        for (d, s) in syms.iter().enumerate() {
            match var_axes[d]
                .as_deref()
                .filter(|set| sets.iter().any(|x| x == set))
            {
                Some(set) => {
                    let n = sizes.get(set).copied().unwrap_or(-1);
                    if ranges[d] != (1, n) {
                        return rw.refuse(format_args!(
                            "writes `{var}` over {}..{} of the lane set `{set}`, not the whole of it",
                            ranges[d].0, ranges[d].1
                        ));
                    }
                    sc.lane_syms.push((s.clone(), set.to_string()));
                }
                None => {
                    if cells {
                        return rw.refuse(format_args!(
                            "writes `{var}` along `{}`, which is not one of the lane's sets",
                            var_axes[d].as_deref().unwrap_or("an unnamed axis")
                        ));
                    }
                    sc.inner.push(s.clone());
                    out_syms.push(s.clone());
                    out_ranges.push(ranges[d]);
                }
            }
        }
        Ok((sc, out_syms, out_ranges))
    };
    let mut rhs = Vec::new();
    for rule in &compiled.rhs_rules {
        let RhsRule::ArrayLoop {
            var_name,
            output_idx_names,
            output_ranges,
            lhs_idx_exprs,
            body,
            contract_names,
            contract_dims,
            reduce,
            filter,
        } = rule
        else {
            return Err(refused(
                "lane: a scalar or per-cell rule has no lane form".to_string(),
            ));
        };
        rw.rule = format!("D({var_name})");
        let identity = lhs_idx_exprs.len() == output_idx_names.len()
            && lhs_idx_exprs
                .iter()
                .zip(output_idx_names)
                .all(|(e, s)| matches!(e, Expr::Variable(x) if x == s));
        if !identity {
            return rw.refuse("writes through a shifted or computed left-hand side");
        }
        let (mut sc, syms, ranges) = lane_box(&rw, var_name, output_idx_names, output_ranges)?;
        sc.inner.extend(contract_names.iter().cloned());
        let body = rw.expr(body, &sc)?;
        let filter = match filter {
            Some(f) => Some(Box::new(rw.expr(f, &sc)?)),
            None => None,
        };
        rhs.push(RhsRule::ArrayLoop {
            var_name: var_name.clone(),
            lhs_idx_exprs: syms.iter().map(|s| Expr::Variable(s.clone())).collect(),
            output_idx_names: syms,
            output_ranges: ranges,
            body: Box::new(body),
            contract_names: contract_names.clone(),
            contract_dims: contract_dims.clone(),
            reduce: *reduce,
            filter,
        });
    }
    let mut observed = Vec::new();
    for rule in &compiled.observed_rules {
        let var = match rule {
            AlgebraicRule::Scalar { var, .. }
            | AlgebraicRule::ArrayLoop { var, .. }
            | AlgebraicRule::Recurrence { var, .. } => var,
        };
        if !dependent.contains(var) {
            observed.push(rule.clone());
            continue;
        }
        rw.rule = var.clone();
        match rule {
            AlgebraicRule::ArrayLoop {
                output_idx_names,
                output_ranges,
                body,
                ..
            } if lane_vars.contains(var) => {
                let (sc, syms, ranges) = lane_box(&rw, var, output_idx_names, output_ranges)?;
                let body = rw.expr(body, &sc)?;
                observed.push(AlgebraicRule::ArrayLoop {
                    var: var.clone(),
                    output_idx_names: syms,
                    output_ranges: ranges,
                    body: Rc::new(body),
                });
            }
            AlgebraicRule::Scalar { body, .. } if axes.get(var).is_none_or(Vec::is_empty) => {
                let body = rw.expr(body, &LScope::default())?;
                if mentions(&body, &mut |x| x.starts_with("__cell_") || x == LANE) {
                    return rw.refuse("is a scalar observed that reads the lane state");
                }
                observed.push(rule.clone());
            }
            _ => return rw.refuse("is a state-dependent observed with no lane form"),
        }
    }
    Ok(Rewritten {
        rhs,
        observed,
        gathers: rw.gathers,
    })
}

pub(super) fn build(
    prog: &RhsProgram,
    kind: &LaneKind,
    capacity: usize,
) -> Result<LaneProgram, SimulateError> {
    let compiled = &*prog.compiled;
    let precision = plain_precision(compiled, "lane")?;
    if capacity == 0 {
        return Err(build_error(
            "`lanes`: capacity must be at least 1".to_string(),
        ));
    }
    let sets: Vec<String> = kind.sets().to_vec();
    let sizes = index_set_sizes(&prog.flat);
    let box_invalid =
        |m: String| super::range_error(crate::diagnostic::codes::RANGE_BOX_INVALID, m);
    for s in &sets {
        if !sizes.contains_key(s) {
            return Err(box_invalid(format!(
                "`lanes`: `{s}` is not an interval index set of this program"
            )));
        }
    }
    let cells_mode = matches!(kind, LaneKind::Cells { .. });
    // Every axis's index-set name (the decomposition is empty: lanes cut
    // nothing, they only name sets).
    let infos = var_infos(prog, &Decomposition::default());
    let axes: HashMap<String, Vec<Option<String>>> = infos
        .iter()
        .map(|(k, v)| {
            (
                k.clone(),
                v.axes
                    .iter()
                    .map(|a| match a {
                        AxisSpec::Whole { set } => set.clone(),
                        AxisSpec::Cut { set, .. } => Some(set.clone()),
                    })
                    .collect(),
            )
        })
        .collect();
    // Every state in `u` and `aux` carries every lane set; for `cells` the
    // lane sets are exactly the written variables' index sets.
    for name in prog.writes.iter().chain(&prog.aux) {
        let var_sets: Vec<String> = axes[name].iter().flatten().cloned().collect();
        if let Some(s) = sets.iter().find(|s| !var_sets.contains(s)) {
            return Err(box_invalid(format!(
                "`lanes`: the state `{name}` does not carry the lane set `{s}`"
            )));
        }
        if cells_mode
            && prog.writes.contains(name)
            && let Some(s) = var_sets.iter().find(|s| !sets.contains(s))
        {
            return Err(box_invalid(format!(
                "`lanes`: `cells` lanes name every index set of the written variables, and \
                 `{name}` also has `{s}`"
            )));
        }
    }
    let dependent = super::tile::state_dependent(compiled);
    let mut lane_vars: HashSet<String> = compiled.var_shapes.keys().cloned().collect();
    for rule in &compiled.observed_rules {
        if let AlgebraicRule::ArrayLoop { var, .. } = rule
            && dependent.contains(var)
        {
            lane_vars.insert(var.clone());
        }
    }
    let cap = capacity as i64;
    let main = rewrite(
        compiled, &axes, &lane_vars, &dependent, &sets, &sizes, cells_mode, cap, false,
    )?;
    let pre = rewrite(
        compiled, &axes, &lane_vars, &dependent, &sets, &sizes, cells_mode, cap, true,
    )?;

    // The lane layout: u, then aux, each block `[capacity, inner…]`.
    let mut entries = Vec::new();
    for (input, names) in [(TileInput::U, &prog.writes), (TileInput::Aux, &prog.aux)] {
        for name in names {
            let vs = &compiled.var_shapes[name];
            let var_axes = &axes[name];
            if cells_mode
                && var_axes
                    .iter()
                    .any(|a| a.as_deref().is_none_or(|s| !sets.iter().any(|x| x == s)))
                && !vs.shape.is_empty()
            {
                return Err(refused(format!(
                    "lane: `{name}` has an axis outside the lane's sets {sets:?}"
                )));
            }
            let mut storage = vec![(1, cap)];
            let mut index_sets = vec!["lane".to_string()];
            for (d, a) in var_axes.iter().enumerate() {
                if a.as_deref().is_some_and(|s| sets.iter().any(|x| x == s)) {
                    continue;
                }
                let o = vs.origin[d];
                storage.push((o, o + vs.shape[d] as i64 - 1));
                index_sets.push(a.clone().unwrap_or_default());
            }
            if vs.shape.is_empty() {
                return Err(refused(format!(
                    "lane: `{name}` is a 0-d state, which no lane holds"
                )));
            }
            entries.push((name.clone(), input, index_sets, storage.clone(), storage));
        }
    }
    let layout = Blocks::build(entries);

    // The internal state: u, aux, the lane cells, then the hoisted inputs.
    let mut var_shapes: IndexMap<String, VarShape> = IndexMap::new();
    for v in &layout.vars {
        let flat_offset = match v.input {
            TileInput::U => v.base,
            TileInput::Aux => layout.u_len + v.base,
        };
        var_shapes.insert(
            v.name.clone(),
            VarShape {
                shape: v
                    .storage
                    .iter()
                    .map(|(lo, hi)| (hi - lo + 1) as usize)
                    .collect(),
                origin: v.storage.iter().map(|r| r.0).collect(),
                flat_offset,
            },
        );
    }
    let add = |shapes: &mut IndexMap<String, VarShape>, name: String, at: &mut usize| {
        shapes.insert(
            name,
            VarShape {
                shape: vec![capacity],
                origin: vec![1],
                flat_offset: *at,
            },
        );
        *at += capacity;
    };
    let mut at = layout.u_len + layout.aux_len;
    for s in &sets {
        add(&mut var_shapes, cell_var(s), &mut at);
    }
    let mut pre_shapes = var_shapes.clone();
    let mut pre_at = at;
    for k in 0..pre.gathers.len() {
        add(&mut pre_shapes, input_var(k), &mut pre_at);
    }
    let held: HashSet<String> = prog
        .aux
        .iter()
        .cloned()
        .chain(sets.iter().map(|s| cell_var(s)))
        .collect();
    let empty = TileLowering {
        states: Vec::new(),
        observed: FxHashMap::default(),
    };
    let build_tape = |c: &ArrayCompiled| -> Result<TapeProgram, SimulateError> {
        let _env = compiled.precision.enter();
        c.build_tile_tape(&empty)
            .map_err(|d| declined_error(&d, "lane"))
    };
    let main_tape = build_tape(&shell(
        compiled,
        var_shapes.clone(),
        main.rhs,
        main.observed,
        held.clone(),
    ))?;
    let mut pre_held = held.clone();
    pre_held.extend((0..pre.gathers.len()).map(input_var));
    let pre_tape = build_tape(&shell(
        compiled,
        pre_shapes,
        pre.rhs,
        pre.observed,
        pre_held,
    ))?;

    // The gather program: one rule per hoisted read, writing its lanes.
    let mut gshapes: IndexMap<String, VarShape> = IndexMap::new();
    let mut gat = 0usize;
    for k in 0..main.gathers.len() {
        add(&mut gshapes, input_var(k), &mut gat);
    }
    for s in &sets {
        add(&mut gshapes, cell_var(s), &mut gat);
    }
    // The gather program's `du` is the inputs alone, so the cells follow
    // them in its state; the call passes the cells there.
    let n_inputs = main.gathers.len();
    let grules: Vec<RhsRule> = main
        .gathers
        .iter()
        .enumerate()
        .map(|(k, g)| RhsRule::ArrayLoop {
            var_name: input_var(k),
            output_idx_names: vec![LANE.to_string()],
            output_ranges: vec![(1, cap)],
            lhs_idx_exprs: vec![Expr::Variable(LANE.to_string())],
            body: Box::new(g.clone()),
            contract_names: Vec::new(),
            contract_dims: Vec::new(),
            reduce: crate::faq::ReduceKind::Sum,
            filter: None,
        })
        .collect();
    let gobserved: Vec<AlgebraicRule> = compiled
        .observed_rules
        .iter()
        .filter(|r| {
            let var = match r {
                AlgebraicRule::Scalar { var, .. }
                | AlgebraicRule::ArrayLoop { var, .. }
                | AlgebraicRule::Recurrence { var, .. } => var,
            };
            !dependent.contains(var)
        })
        .cloned()
        .collect();
    let gheld: HashSet<String> = sets.iter().map(|s| cell_var(s)).collect();
    let gather_tape = if n_inputs == 0 {
        build_tape(&shell(compiled, gshapes, Vec::new(), Vec::new(), gheld))?
    } else {
        build_tape(&shell(compiled, gshapes, grules, gobserved, gheld))?
    };
    Ok(LaneProgram {
        main: Arc::new(main_tape),
        pre: Arc::new(pre_tape),
        gather: Arc::new(gather_tape),
        layout: layout.lane_public(&sets, capacity),
        blocks: layout,
        forcing: Arc::clone(&prog.forcing),
        capacity,
        extents: sets.iter().map(|s| sizes[s]).collect(),
        sets,
        n_inputs,
        n_params: compiled.param_names.len(),
        declared: Arc::clone(&prog.declared),
        precision,
    })
}
