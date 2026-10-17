//! One rule on its own tape, over inputs whose values the build already
//! holds.
//!
//! Two callers need a rule's value at build time and must not walk it per
//! cell:
//!
//! * the build pipeline (`crate::prepare`), which evaluates a document's
//!   state-free observeds before the model is compiled. Under a strict
//!   compiler, an observed the whole-array overlay declines is lowered here
//!   instead of being walked by the reference evaluator: its inputs (ingested
//!   columns, the build-time fields evaluated before it) are seeded as known
//!   [`Instr::ConstArray`] slots, the rule is lowered exactly as the model's
//!   own tape would lower it, and the program runs once;
//! * the tape builder itself, when a join key column (or another value the
//!   build has to know) is a CONST-cadence observed computed from index
//!   symbols, literals and other such observeds rather than a literal
//!   ([`TapeBuilder::fold_const_observed`]). Its values are what the same
//!   rule computes on this same executor, so folding it cannot disagree with
//!   the program that later recomputes it.
//!
//! Either way the value comes from the tape's own kernels, which match the
//! interpreter bit for bit, and a rule the tape cannot lower is a decline
//! with the tape's reason, never a per-cell walk.

use super::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// Why [`eval_standalone_rule`] produced no value.
#[derive(Debug)]
#[cfg_attr(target_arch = "wasm32", allow(dead_code))]
pub(crate) enum StandaloneError {
    /// The tape cannot lower the rule; the deepest decline reason.
    Declined(String),
    /// The program ran and latched a fail-closed fault (an out-of-range const
    /// gather, an unavailable recurrence read, …): the message the
    /// interpreter latches for the same document.
    Fault(String),
}

/// Lower `rule` alone, with each of `inputs` bound to its known value, and
/// run it once. `params` are the values of `param_names`; a name read that is
/// neither an input, a parameter nor a loop symbol declines.
///
/// `pipeline` is the build pipeline's route, which lowers an array-valued
/// `bool_and_or` reduction as its reference evaluator walks it
/// ([`TapeBuilder::array_bool_reductions`]).
///
/// The result is the rule's value at origin 1 on every axis, as the observed
/// passes publish it (a scalar is a 0-d array).
pub(in crate::simulate_array) fn eval_standalone_rule(
    rule: &AlgebraicRule,
    inputs: &[(&str, &ndarray::ArrayD<f64>)],
    param_names: &[String],
    params: &[f64],
    const_arrays: &ConstArrayScope,
    pipeline: bool,
) -> Result<ndarray::ArrayD<f64>, StandaloneError> {
    let prog = build_standalone_program(rule, inputs, param_names, const_arrays, pipeline)
        .map_err(|b| StandaloneError::Declined(b.reason))?;
    run_standalone_program(prog, rule, param_names, params)
}

fn build_standalone_program(
    rule: &AlgebraicRule,
    inputs: &[(&str, &ndarray::ArrayD<f64>)],
    param_names: &[String],
    const_arrays: &ConstArrayScope,
    pipeline: bool,
) -> LResult<TapeProgram> {
    let var_shapes: IndexMap<String, VarShape> = IndexMap::new();
    let discrete: HashSet<String> = HashSet::new();
    let forcing = ForcingInputs {
        shapes: FxHashMap::default(),
        unsized_: HashSet::new(),
        discrete: &discrete,
    };
    let name = observed_rule_var(rule).clone();
    let mut obs_tier: FxHashMap<String, Cadence> = FxHashMap::default();
    obs_tier.insert(name.clone(), Cadence::Const);
    let mut b = TapeBuilder::new(
        &var_shapes,
        param_names,
        obs_tier,
        const_arrays,
        crate::precision::is_f32(),
        &forcing,
    );
    b.array_bool_reductions = pipeline;
    b.begin_rule(RuleInfo {
        name: name.clone(),
        kind: RuleKind::Observed(0),
        cadence: Cadence::Const,
    });
    let _rule_precision = crate::precision::has_variable_overrides()
        .then(|| crate::precision::enter(crate::precision::of_variable(&name)));
    for (input, value) in inputs {
        let lv = if value.ndim() == 0 {
            // `lookup_variable`'s 0-d arm: a scalar, rounded to the precision
            // in force.
            LV::Lit(crate::precision::active().round(value[ndarray::IxDyn(&[])]))
        } else if value.is_empty() {
            // An empty table (a zero extent): a box with no element, whose
            // values the build knows to be none.
            let ones = DimI::from_elem(1, value.ndim());
            let lv = b.emit_zero_array(value.shape(), &ones);
            if let LV::Arr(s) = lv {
                b.known.insert(s, Known::Vals(Rc::new(Vec::new())));
            }
            lv
        } else {
            b.emit_const_array(value)?
        };
        b.obs_defined
            .insert((*input).to_string(), ObsVal::Taped(lv));
    }
    let v = b.lower_observed_rule(rule)?;
    b.flush_rule_fault()?;
    b.obs_defined.insert(name, v);
    b.end_rule();
    let exports = b.compute_exports(std::slice::from_ref(rule), true);
    Ok(b.finish(exports, None, false))
}

fn run_standalone_program(
    prog: TapeProgram,
    rule: &AlgebraicRule,
    param_names: &[String],
    params: &[f64],
) -> Result<ndarray::ArrayD<f64>, StandaloneError> {
    let name = observed_rule_var(rule).clone();
    let var_shapes: IndexMap<String, VarShape> = IndexMap::new();
    let forcing: RefCell<HashMap<String, ndarray::ArrayD<f64>>> = RefCell::new(HashMap::new());
    let mut ctx = super::super::TapeCtx::new(Rc::new(prog));
    ctx.set_exports_active(true);
    crate::simulate_array::take_const_array_oob();
    super::super::run_tape_call(
        &mut ctx,
        &RhsCall {
            rhs_rules: &[],
            observed_rules: std::slice::from_ref(rule),
            var_shapes: &var_shapes,
            param_names,
            state: &[],
            params,
            forcing: &forcing,
            t: 0.0,
            declared: empty_declared_names(),
        },
        &mut [],
        &mut RhsStats::default(),
    );
    if let Some(msg) = crate::simulate_array::take_const_array_oob() {
        return Err(StandaloneError::Fault(msg));
    }
    ctx.exported_observeds()
        .get(&name)
        .cloned()
        .ok_or_else(|| StandaloneError::Declined(format!("observed `{name}` was not exported")))
}

impl TapeBuilder<'_> {
    /// The build-time value of the CONST-cadence observed `name`, computed by
    /// lowering its rule on a standalone tape over the build-time values of
    /// the observeds it reads (module docs). `None` when the observed is not
    /// one the build can know: not an observed of this program, not
    /// CONST-cadence, or reading anything that is not itself build-time data
    /// — a parameter (tunable between solves), a state, the time, a forcing
    /// input.
    ///
    /// Memoized per name, so a key column several joins read is folded once.
    pub(super) fn fold_const_observed(&self, name: &str) -> Option<(DimU, Rc<Vec<f64>>)> {
        if let Some(hit) = self.folded.borrow().get(name) {
            return hit.clone();
        }
        let out = self.fold_const_observed_uncached(name);
        self.folded
            .borrow_mut()
            .insert(name.to_string(), out.clone());
        out
    }

    fn fold_const_observed_uncached(&self, name: &str) -> Option<(DimU, Rc<Vec<f64>>)> {
        if self.obs_tier.get(name) != Some(&Cadence::Const) {
            return None;
        }
        if !matches!(self.obs_defined.get(name), Some(ObsVal::Taped(_))) {
            return None;
        }
        let rule = self
            .observed_rules
            .iter()
            .find(|r| observed_rule_var(r) == name)?;
        // The observeds the rule reads, each by its own build-time value.
        let mut reads: HashSet<String> = HashSet::new();
        collect_variable_names(observed_rule_body(rule), &mut reads);
        let mut values: Vec<(String, ndarray::ArrayD<f64>)> = Vec::new();
        let mut names: Vec<&String> = reads
            .iter()
            .filter(|r| r.as_str() != name && self.obs_defined.contains_key(r.as_str()))
            .collect();
        names.sort();
        for dep in names {
            let (shape, vals) = self.known_named(dep)?;
            let a =
                ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&shape), (*vals).clone()).ok()?;
            values.push((dep.clone(), a));
        }
        // A baked parameter is build-time data (`baked_params`); any other is
        // constant only until the caller changes it, so is not.
        let mut baked: Vec<&String> = reads
            .iter()
            .filter(|r| self.baked_params.contains_key(r.as_str()))
            .collect();
        baked.sort();
        for p in baked {
            let x = ndarray::ArrayD::from_elem(ndarray::IxDyn(&[]), self.baked_params[p]);
            values.push((p.clone(), x));
        }
        let inputs: Vec<(&str, &ndarray::ArrayD<f64>)> =
            values.iter().map(|(n, a)| (n.as_str(), a)).collect();
        // No parameters beyond the baked ones.
        let a = eval_standalone_rule(rule, &inputs, &[], &[], self.const_arrays, false).ok()?;
        let shape: DimU = a.shape().iter().copied().collect();
        Some((shape, Rc::new(a.iter().copied().collect())))
    }
}

/// Every variable name `expr` mentions (a superset of what it reads: loop
/// symbols are included, and are filtered out by the caller's lookup).
pub(in crate::simulate_array) fn collect_variable_names(expr: &Expr, out: &mut HashSet<String>) {
    match expr {
        Expr::Variable(v) => {
            out.insert(v.clone());
        }
        Expr::Operator(node) => {
            for a in &node.args {
                collect_variable_names(a, out);
            }
            node.for_each_child(&mut |c| collect_variable_names(c, out));
            // A join names its key columns and envelope factors as strings,
            // not as expressions.
            for clause in node.join.iter().flatten() {
                out.extend(clause.on.iter().flatten().cloned());
                if let Some(ov) = &clause.overlap {
                    out.extend(ov.src_env.iter().chain(ov.tgt_env.iter()).cloned());
                }
            }
        }
        _ => {}
    }
}
