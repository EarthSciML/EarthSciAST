//! `tile` (API_SPEC §5.8, RFC U3 §4–§5): a `native` program restricted to an
//! owned box that reads a storage box.
//!
//! A tile is a re-lowering of the tape. The compiled rules are rewritten over
//! their need boxes ([`super::walk`]): each derivative over its owned rows, each
//! state-dependent array observed over the union of what its readers read, and
//! every makearray clipped to what is read of it. The state layout is the
//! storage box, at its global origin, so the existing slot addressing is
//! `base + Σ (g − S_lo)·stride`; the lowering classifies every state read
//! against the global domain (RFC U3 §4 rule 2). No document is parsed or
//! flattened.

use super::walk::{AxisSpec, Read, Refusal, Scope, VarInfo, Walker};
use super::{
    Blocks, Decomposition, RhsProgram, RhsWorkspace, TileBox, TileInput, TileLayout, WsExec,
    build_error, check_lengths, index_set_sizes, range_error, take_fault, var_infos,
};
use crate::diagnostic::codes;
use crate::simulate::SimulateError;
use crate::simulate_array::tape::{
    CallInputs, DeclinedTape, TapeCtx, TapeProgram, TileAxisDom, TileLowering, run_tape_inputs,
};
use crate::simulate_array::vectorized::lhs_constant_shifts;
use crate::simulate_array::{AlgebraicRule, ArrayCompiled, RhsRule, StateDefault, VarShape};
use crate::types::Expr;
use indexmap::IndexMap;
use ndarray::ArrayD;
use rustc_hash::FxHashMap;
use smallvec::SmallVec;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;

/// One tile of a [`RhsProgram`] (RFC U3 §4): it reads `u` and `aux` over their
/// storage boxes and writes only the owned rows of `du`.
///
/// `Send + Sync`: it holds the program and plain layout data, so tiles of one
/// rank can share it across threads, each with its own [`RhsWorkspace`].
pub struct TileProgram {
    prog: Arc<TapeProgram>,
    blocks: Blocks,
    layout: TileLayout,
    forcing: Arc<HashMap<String, ArrayD<f64>>>,
    n_params: usize,
    declared: Arc<HashSet<String>>,
    precision: crate::precision::Precision,
}

impl std::fmt::Debug for TileProgram {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TileProgram")
            .field("layout", &self.layout)
            .finish()
    }
}

impl TileProgram {
    /// The tile's input layout: every variable's storage and owned boxes.
    pub fn layout(&self) -> &TileLayout {
        &self.layout
    }

    /// Buffers for [`Self::eval_into`].
    pub fn new_workspace(&self) -> RhsWorkspace {
        let n = self.blocks.u_len + self.blocks.aux_len;
        RhsWorkspace {
            owner: Arc::as_ptr(&self.prog) as usize,
            state: vec![0.0; n],
            dy: Vec::new(),
            exec: WsExec::Tape(Box::new(TapeCtx::new(Arc::clone(&self.prog)))),
        }
    }

    /// Write the tile's owned rows of `du` (RFC U3 §4): `u` and `aux` hold
    /// every in-domain cell of their storage boxes (and, on a periodic axis,
    /// the wrapped values of the cells outside `1..N`); every other element of
    /// `du` is left as the caller holds it.
    #[allow(clippy::too_many_arguments)]
    pub fn eval_into(
        &self,
        u: &[f64],
        aux: &[f64],
        p: &[f64],
        t: f64,
        du: &mut [f64],
        ws: &mut RhsWorkspace,
    ) -> Result<(), SimulateError> {
        check_lengths(&self.blocks, u, aux, du, p, self.n_params)?;
        if ws.owner != Arc::as_ptr(&self.prog) as usize {
            return Err(build_error(
                "`eval_into`: the workspace was made by another program".to_string(),
            ));
        }
        let nu = self.blocks.u_len;
        ws.state[..nu].copy_from_slice(u);
        ws.state[nu..].copy_from_slice(aux);
        let WsExec::Tape(ctx) = &mut ws.exec else {
            unreachable!("a tile workspace runs a tape");
        };
        let _precision = crate::precision::enter(self.precision);
        crate::simulate_array::take_const_array_oob();
        let inputs = CallInputs {
            state: &ws.state,
            params: p,
            forcing: &self.forcing,
            t,
            declared: &self.declared,
        };
        run_tape_inputs(ctx, &inputs, du, false);
        take_fault()
    }
}

fn box_invalid(message: String) -> SimulateError {
    range_error(codes::RANGE_BOX_INVALID, message)
}

pub(super) fn refusal_error(r: Refusal) -> SimulateError {
    if r.code == codes::COMPILER_REFUSED_RULE {
        refused(r.message)
    } else {
        range_error(r.code, r.message)
    }
}

/// `compiler_refused_rule` under `native` for a range restriction.
pub(super) fn refused(reason: String) -> SimulateError {
    SimulateError::Compile(crate::compile_error::CompileError::CompilerRefusedRule {
        compiler: "native",
        kind: "state derivative",
        rule: reason
            .split('`')
            .nth(1)
            .unwrap_or("(range restriction)")
            .to_string(),
        tier: "continuous",
        reason,
    })
}

/// A declined restricted tape, as the error its first decline names: a
/// range diagnostic when the lowering raised one, else `compiler_refused_rule`.
pub(super) fn declined_error(d: &DeclinedTape, what: &str) -> SimulateError {
    let declined: Vec<(usize, &String)> = d
        .reasons
        .iter()
        .enumerate()
        .filter_map(|(k, r)| r.as_ref().map(|r| (k, r)))
        .collect();
    for code in [codes::RANGE_HALO_INSUFFICIENT, codes::RANGE_GLOBAL_LOCALITY] {
        if let Some((k, r)) = declined.iter().find(|(_, r)| r.starts_with(code)) {
            let msg = r.trim_start_matches(code).trim_start_matches(':').trim();
            return range_error(code, format!("{} (rule `{}`)", msg, d.rules[*k].name));
        }
    }
    let (k, reason) = declined[0];
    let rule = &d.rules[k];
    let reason = if reason.contains(what) {
        reason.clone()
    } else {
        format!("{what}: {reason}")
    };
    SimulateError::Compile(crate::compile_error::CompileError::CompilerRefusedRule {
        compiler: "native",
        kind: rule.kind_name(),
        rule: rule.name.clone(),
        tier: rule.cadence_name(),
        reason,
    })
}

/// The per-cut-set owned and storage ranges of a validated box.
struct Boxes {
    owned: HashMap<String, (i64, i64)>,
    storage: HashMap<String, (i64, i64)>,
}

fn validate(prog: &RhsProgram, dec: &Decomposition, bx: &TileBox) -> Result<Boxes, SimulateError> {
    let sizes = index_set_sizes(&prog.flat);
    for a in &dec.axes {
        if !sizes.contains_key(&a.index_set) {
            return Err(box_invalid(format!(
                "the decomposition cuts `{}`, which is not an interval index set of this program",
                a.index_set
            )));
        }
        if let Some(p) = a.period
            && p != sizes[&a.index_set]
        {
            return Err(box_invalid(format!(
                "the decomposition gives `{}` period {p}, and it has {} cells",
                a.index_set, sizes[&a.index_set]
            )));
        }
    }
    for (face, cell) in &dec.faces {
        if !dec.axes.iter().any(|a| &a.index_set == cell) {
            return Err(box_invalid(format!(
                "face set `{face}` is declared against `{cell}`, which the decomposition does \
                 not cut"
            )));
        }
        if !sizes.contains_key(face) {
            return Err(box_invalid(format!(
                "face set `{face}` is not an interval index set of this program"
            )));
        }
    }
    let collect = |list: &[(String, std::ops::RangeInclusive<i64>)], what: &str| {
        let mut out: HashMap<String, (i64, i64)> = HashMap::new();
        for (set, r) in list {
            if !dec.axes.iter().any(|a| &a.index_set == set) {
                return Err(box_invalid(format!(
                    "the {what} box names `{set}`, which the decomposition does not cut"
                )));
            }
            if out.insert(set.clone(), (*r.start(), *r.end())).is_some() {
                return Err(box_invalid(format!("the {what} box names `{set}` twice")));
            }
        }
        for a in &dec.axes {
            if !out.contains_key(&a.index_set) {
                return Err(box_invalid(format!(
                    "the {what} box has no range for the decomposed set `{}`",
                    a.index_set
                )));
            }
        }
        Ok(out)
    };
    let owned = collect(&bx.owned, "owned")?;
    let storage = collect(&bx.storage, "storage")?;
    for a in &dec.axes {
        let set = &a.index_set;
        let n = sizes[set];
        let (olo, ohi) = owned[set];
        let (slo, shi) = storage[set];
        if olo > ohi || olo < 1 || ohi > n {
            return Err(box_invalid(format!(
                "the owned range {olo}..{ohi} of `{set}` is not a non-empty range inside 1..{n}"
            )));
        }
        if slo > olo || shi < ohi {
            return Err(box_invalid(format!(
                "the owned range {olo}..{ohi} of `{set}` is not inside its storage range \
                 {slo}..{shi}"
            )));
        }
        if a.period.is_some() && shi - slo + 1 > 2 * n {
            return Err(box_invalid(format!(
                "the storage range {slo}..{shi} of the periodic set `{set}` spans more than two \
                 periods"
            )));
        }
    }
    Ok(Boxes { owned, storage })
}

/// The storage and owned range of one axis of a variable on this tile.
fn axis_ranges(spec: &AxisSpec, extent: (i64, i64), boxes: &Boxes) -> ((i64, i64), (i64, i64)) {
    match spec {
        AxisSpec::Whole { .. } => (extent, extent),
        AxisSpec::Cut { cell, face, hi, .. } => {
            let (slo, shi) = boxes.storage[cell];
            let (olo, ohi) = boxes.owned[cell];
            if *face {
                let n_cells = hi - 1;
                (
                    (slo, shi + 1),
                    (olo, if ohi == n_cells { ohi + 1 } else { ohi }),
                )
            } else {
                ((slo, shi), (olo, ohi))
            }
        }
    }
}

/// The free names of every rule body that reads `name`, transitively: whether
/// an observed depends on the state.
pub(super) fn state_dependent(compiled: &ArrayCompiled) -> HashSet<String> {
    let states: HashSet<&str> = compiled.var_shapes.keys().map(String::as_str).collect();
    let mut dep: HashSet<String> = HashSet::new();
    for rule in &compiled.observed_rules {
        let (var, body) = observed_parts(rule);
        let free = crate::expression::free_variables(body);
        if free
            .iter()
            .any(|n| states.contains(n.as_str()) || dep.contains(n))
        {
            dep.insert(var.clone());
        }
    }
    dep
}

fn observed_parts(rule: &AlgebraicRule) -> (&String, &Expr) {
    match rule {
        AlgebraicRule::Scalar { var, body, .. }
        | AlgebraicRule::ArrayLoop { var, body, .. }
        | AlgebraicRule::Recurrence { var, body, .. } => (var, body),
    }
}

/// An observed whose wholesale body is one array-valued `faq` with no
/// reduction index, over ranges `1..=n` matching its declared shape, as the
/// array loop over those ranges: the same cells, computed by the same
/// per-element kernels. `None` for every other rule.
pub(super) fn as_loop(rule: &AlgebraicRule) -> Option<AlgebraicRule> {
    let AlgebraicRule::Scalar {
        var,
        body,
        declared_shape: Some(shape),
    } = rule
    else {
        return None;
    };
    let Expr::Operator(node) = &**body else {
        return None;
    };
    if !matches!(node.op.as_str(), "faq" | "aggregate")
        || node.filter.is_some()
        || node.join.is_some()
    {
        return None;
    }
    let out = node.output_idx.as_ref().filter(|o| !o.is_empty())?;
    let ranges = node.ranges.as_ref()?;
    if out.len() != shape.len() || ranges.keys().any(|k| !out.contains(k)) {
        return None;
    }
    let mut bounds = Vec::with_capacity(out.len());
    for (d, name) in out.iter().enumerate() {
        let [lo, hi] = ranges.get(name)?.bounds()?;
        if lo != 1 || hi != shape[d] as i64 {
            return None;
        }
        bounds.push((lo, hi));
    }
    Some(AlgebraicRule::ArrayLoop {
        var: var.clone(),
        output_idx_names: out.clone(),
        output_ranges: bounds,
        body: std::sync::Arc::new(node.expr.as_deref()?.clone()),
    })
}

/// Hull the reads of each name into a box per axis.
fn hull_reads(
    reads: &[Read],
    into: &mut HashMap<String, Vec<(i64, i64)>>,
    vars: &HashMap<String, VarInfo>,
) {
    for r in reads {
        let Some(info) = vars.get(&r.var) else {
            continue;
        };
        let entry = into
            .entry(r.var.clone())
            .or_insert_with(|| vec![(i64::MAX, i64::MIN); info.axes.len()]);
        if let Some(e) = entry.get_mut(r.axis) {
            *e = (e.0.min(r.lo), e.1.max(r.hi));
        }
    }
}

/// The rules a tile runs, and the need box of every array observed it
/// restricts. `owned` maps each state's name to its owned box.
pub(super) struct ClippedRules {
    pub(super) rhs: Vec<RhsRule>,
    pub(super) observed: Vec<AlgebraicRule>,
    pub(super) need: FxHashMap<String, (SmallVec<[i64; 4]>, SmallVec<[i64; 4]>)>,
}

/// Rewrite `compiled`'s rules for a tile whose derivative of each written
/// state covers `owned[var]` (one inclusive range per axis).
pub(super) fn clip_rules(
    compiled: &ArrayCompiled,
    vars: &HashMap<String, VarInfo>,
    owned: &HashMap<String, Vec<(i64, i64)>>,
) -> Result<ClippedRules, SimulateError> {
    let mut reads: HashMap<String, Vec<(i64, i64)>> = HashMap::new();
    let mut needed: HashSet<String> = HashSet::new();
    let mut rhs = Vec::new();
    for rule in &compiled.rhs_rules {
        match rule {
            RhsRule::Scalar { slot, .. } => {
                let name = super::super::layout::slot_name(&compiled.var_shapes, *slot)
                    .unwrap_or_else(|| format!("slot {slot}"));
                return Err(range_error(
                    codes::RANGE_GLOBAL_LOCALITY,
                    format!("rule `D({name})` writes a 0-d state, which no tile owns"),
                ));
            }
            RhsRule::IndexedScalar { slot, .. } => {
                let name = super::super::layout::slot_name(&compiled.var_shapes, *slot)
                    .unwrap_or_else(|| format!("slot {slot}"));
                return Err(refused(format!(
                    "tile restriction: rule `D({name})` is a per-cell scalar rule, which a tile \
                     does not restrict"
                )));
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
                let rule_name = format!("D({var_name})");
                let info = &vars[var_name];
                let Some(shifts) = lhs_constant_shifts(lhs_idx_exprs, output_idx_names) else {
                    return Err(refused(format!(
                        "tile restriction: rule `{rule_name}` writes through a computed \
                         left-hand side"
                    )));
                };
                let own = &owned[var_name];
                let mut ranges = Vec::with_capacity(output_ranges.len());
                let mut sets = Vec::with_capacity(output_ranges.len());
                for (d, &(lo, hi)) in output_ranges.iter().enumerate() {
                    let (olo, ohi) = own[d];
                    ranges.push((lo.max(olo - shifts[d]), hi.min(ohi - shifts[d])));
                    sets.push(info.axes[d].cut_cell().map(str::to_string));
                }
                if ranges.iter().any(|(lo, hi)| lo > hi) {
                    continue;
                }
                let sc = Scope {
                    syms: output_idx_names.clone(),
                    lo: ranges.iter().map(|r| r.0).collect(),
                    hi: ranges.iter().map(|r| r.1).collect(),
                    sets,
                    contracted: contract_names.clone(),
                };
                let mut w = Walker::new(vars, rule_name);
                let body = w.expr(body, &sc).map_err(refusal_error)?;
                let filter = match filter {
                    Some(f) => Some(Box::new(w.expr(f, &sc).map_err(refusal_error)?)),
                    None => None,
                };
                hull_reads(&w.reads, &mut reads, vars);
                needed.extend(crate::expression::free_variables(&body));
                if let Some(f) = &filter {
                    needed.extend(crate::expression::free_variables(f));
                }
                rhs.push(RhsRule::ArrayLoop {
                    var_name: var_name.clone(),
                    output_idx_names: output_idx_names.clone(),
                    output_ranges: ranges,
                    lhs_idx_exprs: lhs_idx_exprs.clone(),
                    body: Box::new(body),
                    contract_names: contract_names.clone(),
                    contract_dims: contract_dims.clone(),
                    reduce: *reduce,
                    filter,
                });
            }
        }
    }

    let dependent = state_dependent(compiled);
    let mut need = FxHashMap::default();
    let mut kept: Vec<Option<AlgebraicRule>> = vec![None; compiled.observed_rules.len()];
    for (k, rule) in compiled.observed_rules.iter().enumerate().rev() {
        let as_array = as_loop(rule);
        let rule = as_array.as_ref().unwrap_or(rule);
        let (var, body) = observed_parts(rule);
        if !needed.contains(var) {
            continue;
        }
        let info = &vars[var];
        match rule {
            AlgebraicRule::ArrayLoop {
                output_idx_names,
                output_ranges,
                ..
            } if dependent.contains(var) && info.is_cut() => {
                let hull = reads.get(var).cloned();
                let mut nlo = SmallVec::new();
                let mut nhi = SmallVec::new();
                for (d, &(_, hi)) in output_ranges.iter().enumerate() {
                    let (a, b) = match (&info.axes[d], hull.as_ref().map(|h| h[d])) {
                        (AxisSpec::Cut { .. }, Some((a, b))) if a <= b => (a.max(1), b.min(hi)),
                        _ => (1, hi),
                    };
                    let (a, b) = if a > b { (1, hi) } else { (a, b) };
                    nlo.push(a);
                    nhi.push(b);
                }
                let ranges: Vec<(i64, i64)> = output_ranges
                    .iter()
                    .enumerate()
                    .map(|(d, &(lo, hi))| (lo.max(nlo[d]), hi.min(nhi[d])))
                    .collect();
                let new_body = if ranges.iter().any(|(lo, hi)| lo > hi) {
                    body.clone()
                } else {
                    let sc = Scope {
                        syms: output_idx_names.clone(),
                        lo: ranges.iter().map(|r| r.0).collect(),
                        hi: ranges.iter().map(|r| r.1).collect(),
                        sets: info
                            .axes
                            .iter()
                            .map(|a| a.cut_cell().map(str::to_string))
                            .collect(),
                        contracted: Vec::new(),
                    };
                    let mut w = Walker::new(vars, var.clone());
                    let b = w.expr(body, &sc).map_err(refusal_error)?;
                    hull_reads(&w.reads, &mut reads, vars);
                    b
                };
                needed.extend(crate::expression::free_variables(&new_body));
                need.insert(var.clone(), (nlo, nhi));
                kept[k] = Some(AlgebraicRule::ArrayLoop {
                    var: var.clone(),
                    output_idx_names: output_idx_names.clone(),
                    output_ranges: output_ranges.clone(),
                    body: std::sync::Arc::new(new_body),
                });
            }
            AlgebraicRule::Recurrence { axis, .. } if dependent.contains(var) && info.is_cut() => {
                if let Some(AxisSpec::Cut { set, .. }) = info.axes.get(*axis) {
                    return Err(range_error(
                        codes::RANGE_GLOBAL_LOCALITY,
                        format!(
                            "observed `{var}` is a recurrence along the decomposed axis `{set}`"
                        ),
                    ));
                }
                return Err(refused(format!(
                    "tile restriction: observed `{var}` is a recurrence over a decomposed array"
                )));
            }
            _ => {
                if dependent.contains(var) && info.is_cut() {
                    return Err(refused(format!(
                        "tile restriction: observed `{var}` is a whole-array expression of the \
                         state"
                    )));
                }
                needed.extend(crate::expression::free_variables(body));
                kept[k] = Some(rule.clone());
            }
        }
    }
    Ok(ClippedRules {
        rhs,
        observed: kept.into_iter().flatten().collect(),
        need,
    })
}

/// A shell model around restricted rules and a restricted state layout: the
/// input a tape build reads. Everything else is the program's.
pub(super) fn shell(
    compiled: &ArrayCompiled,
    var_shapes: IndexMap<String, VarShape>,
    rhs_rules: Vec<RhsRule>,
    observed_rules: Vec<AlgebraicRule>,
    held: HashSet<String>,
) -> ArrayCompiled {
    let n_states = var_shapes
        .values()
        .map(|v| v.shape.iter().product::<usize>().max(1))
        .sum();
    let state_defaults = vec![StateDefault::Scalar(None); var_shapes.len()];
    ArrayCompiled {
        runtime_mode: compiled.runtime_mode,
        #[cfg(feature = "xla")]
        xla_rhs: std::cell::OnceCell::new(),
        merged_renames: HashMap::new(),
        var_shapes,
        state_names: std::cell::OnceCell::new(),
        qualified_state_names: std::cell::OnceCell::new(),
        state_defaults,
        param_names: compiled.param_names.clone(),
        param_index: compiled.param_index.clone(),
        param_defaults: compiled.param_defaults.clone(),
        observed_rules,
        rhs_rules,
        rule_set: super::super::rhs::next_rule_set_id(),
        n_states,
        forcing: Rc::clone(&compiled.forcing),
        data_fed: compiled.data_fed.clone(),
        forcing_generation: std::cell::Cell::new(0),
        field_ics: Vec::new(),
        init_faqs: Vec::new(),
        ic_scope: Default::default(),
        index_sets: compiled.index_sets.clone(),
        const_scope: std::sync::Arc::clone(&compiled.const_scope),
        namespace: compiled.namespace.clone(),
        precision: compiled.precision.clone(),
        declared_names: compiled.declared_names.clone(),
        #[cfg(feature = "solve")]
        field_ic_memo: std::cell::RefCell::new(None),
        inline_param_arrays: compiled.inline_param_arrays.clone(),
        forcing_decls: compiled.forcing_decls.clone(),
        forcing_defaults: compiled.forcing_defaults.clone(),
        unvalued_shaped_params: compiled.unvalued_shaped_params.clone(),
        held_at_ic: held,
        tape_cache: crate::simulate_array::tape::TapeCache::new(),
    }
}

/// The document precision a restricted program runs at, refusing a document
/// with per-variable element types (whose environment is not `Send`).
pub(super) fn plain_precision(
    compiled: &ArrayCompiled,
    what: &str,
) -> Result<crate::precision::Precision, SimulateError> {
    let _env = compiled.precision.enter();
    if crate::precision::has_variable_overrides() {
        return Err(refused(format!(
            "{what}: the document declares per-variable element types, which a range-restricted \
             program does not carry"
        )));
    }
    Ok(compiled.precision.document)
}

pub(super) fn build(
    prog: &RhsProgram,
    dec: &Decomposition,
    bx: &TileBox,
) -> Result<TileProgram, SimulateError> {
    let boxes = validate(prog, dec, bx)?;
    let compiled = &*prog.compiled;
    let precision = plain_precision(compiled, "tile restriction")?;
    let vars = var_infos(prog, dec);
    for w in &prog.writes {
        if !vars[w].is_cut() {
            return Err(range_error(
                codes::RANGE_GLOBAL_LOCALITY,
                format!(
                    "the program writes `{w}`, which has no decomposed axis, so no tile owns its \
                     rows (rule `D({w})`)"
                ),
            ));
        }
    }
    let mut owned: HashMap<String, Vec<(i64, i64)>> = HashMap::new();
    let mut entries = Vec::new();
    let set_names = super::state_set_names(&prog.flat, compiled);
    for (input, names) in [(TileInput::U, &prog.writes), (TileInput::Aux, &prog.aux)] {
        for name in names {
            let info = &vars[name];
            let mut storage = Vec::new();
            let mut own = Vec::new();
            for (d, spec) in info.axes.iter().enumerate() {
                let (s, o) = axis_ranges(spec, info.extent[d], &boxes);
                storage.push(s);
                own.push(o);
            }
            owned.insert(name.clone(), own.clone());
            entries.push((name.clone(), input, set_names[name].clone(), storage, own));
        }
    }
    let layout = Blocks::build(entries);
    let clipped = clip_rules(compiled, &vars, &owned)?;

    let mut var_shapes: IndexMap<String, VarShape> = IndexMap::new();
    let mut doms = Vec::new();
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
        let info = &vars[&v.name];
        doms.push(
            info.axes
                .iter()
                .enumerate()
                .map(|(d, a)| match a {
                    AxisSpec::Whole { set } => TileAxisDom {
                        lo: info.extent[d].0,
                        hi: info.extent[d].1,
                        period: None,
                        set: set.clone().unwrap_or_else(|| format!("axis {}", d + 1)),
                    },
                    AxisSpec::Cut {
                        set, hi, period, ..
                    } => TileAxisDom {
                        lo: 1,
                        hi: *hi,
                        period: *period,
                        set: set.clone(),
                    },
                })
                .collect(),
        );
    }
    let lowering = TileLowering {
        states: doms,
        observed: clipped.need.clone(),
    };
    let held: HashSet<String> = prog.aux.iter().cloned().collect();
    let shell = shell(compiled, var_shapes, clipped.rhs, clipped.observed, held);
    let tape = {
        let _env = compiled.precision.enter();
        shell
            .build_tile_tape(&lowering)
            .map_err(|d| declined_error(&d, "tile restriction"))?
    };
    Ok(TileProgram {
        prog: Arc::new(tape),
        layout: layout.public(),
        blocks: layout,
        forcing: Arc::clone(&prog.forcing),
        n_params: compiled.param_names.len(),
        declared: Arc::clone(&prog.declared),
        precision,
    })
}
