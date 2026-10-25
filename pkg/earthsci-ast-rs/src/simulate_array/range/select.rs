//! `select` (API_SPEC §5.8): a rewrite of the flattened system that keeps the
//! summands whose provenance is selected and the equations of the variables
//! the operator writes.

use super::{RhsSelection, build_error, range_error};
use crate::flatten::{FlattenedSystem, fold_contributions, lift_wrapper, rebuild_body};
use crate::simulate::SimulateError;
use crate::types::Expr;
use std::collections::{HashMap, HashSet};

/// The state an equation's left-hand side differentiates in time, in any of
/// the spellings flatten emits (`D(x)`, `D(x[i…])`, and either inside the
/// lift's `faq`).
pub(super) fn derivative_target(lhs: &Expr) -> Option<&str> {
    let mut e = lhs;
    let mut saw_d = false;
    loop {
        match e {
            Expr::Variable(v) => return saw_d.then_some(v.as_str()),
            Expr::Operator(n) if n.op == "faq" || n.op == "aggregate" => e = n.expr.as_deref()?,
            Expr::Operator(n) if n.op == "D" && matches!(n.wrt.as_deref(), None | Some("t")) => {
                saw_d = true;
                e = n.args.first()?;
            }
            Expr::Operator(n) if n.op == "index" && saw_d => e = n.args.first()?,
            _ => return None,
        }
    }
}

/// The variable an algebraic equation defines (`x ~ …`, `x[i…] ~ …`, or the
/// `faq` spelling of either), if its left-hand side names one.
fn defined_name(lhs: &Expr) -> Option<&str> {
    let mut e = lhs;
    loop {
        match e {
            Expr::Variable(v) => return Some(v),
            Expr::Operator(n) if n.op == "faq" || n.op == "aggregate" => e = n.expr.as_deref()?,
            Expr::Operator(n) if n.op == "index" => e = n.args.first()?,
            _ => return None,
        }
    }
}

/// `flat` restricted to `sel`, and the variables it writes.
pub(super) fn select(
    flat: &FlattenedSystem,
    sel: &RhsSelection,
) -> Result<(FlattenedSystem, Vec<String>), SimulateError> {
    if flat.equation_contributions.len() != flat.equations.len() {
        return Err(build_error(
            "`select`: the flattened system carries no per-term provenance (it was not built by \
             `flatten`)"
                .to_string(),
        ));
    }
    let derivative_targets: HashSet<&str> = flat
        .equations
        .iter()
        .filter_map(|eq| derivative_target(&eq.lhs))
        .collect();
    let writes: Vec<String> = match &sel.writes {
        None => derivative_targets.iter().map(|s| s.to_string()).collect(),
        Some(w) => {
            for name in w {
                if !flat.state_variables.contains_key(name) {
                    return Err(build_error(format!(
                        "`select`: `writes` names `{name}`, which is not a state variable of this \
                         program"
                    )));
                }
            }
            w.clone()
        }
    };
    let keeps = |origins: &[crate::flatten::TermOrigin]| match &sel.terms {
        None => true,
        Some(terms) => origins.iter().any(|o| terms.contains(o)),
    };

    let mut out = flat.clone();
    let mut equations = Vec::new();
    let mut contributions = Vec::new();
    let mut lifted_flags = Vec::new();
    for (i, eq) in flat.equations.iter().enumerate() {
        let contribs = &flat.equation_contributions[i];
        let lifted = flat.equation_lifted.get(i).copied().unwrap_or(false);
        let Some(target) = derivative_target(&eq.lhs) else {
            equations.push(eq.clone());
            contributions.push(contribs.clone());
            lifted_flags.push(lifted);
            continue;
        };
        let kept: Vec<_> = contribs
            .iter()
            .filter(|c| keeps(&c.origins))
            .cloned()
            .collect();
        if !writes.iter().any(|w| w == target) {
            if !kept.is_empty() {
                return Err(range_error(
                    crate::diagnostic::codes::RANGE_SELECTION_WRITES_INCOMPLETE,
                    format!(
                        "the selected terms write `{target}` (equation {i}), which `writes` does \
                         not list"
                    ),
                ));
            }
            continue;
        }
        let wrapper = lift_wrapper(&eq.rhs, lifted).cloned();
        let mut eq = eq.clone();
        eq.rhs = rebuild_body(wrapper, fold_contributions(&kept));
        equations.push(eq);
        contributions.push(kept);
        lifted_flags.push(lifted);
    }

    // The cone of what the kept derivatives read, closed through the
    // algebraic equations that define observeds.
    // An observed may be defined region by region (`x[1] ~ …`,
    // `x[2:N] ~ …`), so every defining equation is followed.
    let mut definers: HashMap<&str, Vec<usize>> = HashMap::new();
    for (k, eq) in equations.iter().enumerate() {
        if derivative_target(&eq.lhs).is_none()
            && let Some(name) = defined_name(&eq.lhs)
        {
            definers.entry(name).or_default().push(k);
        }
    }
    let mut cone: HashSet<String> = HashSet::new();
    let mut stack: Vec<String> = Vec::new();
    for eq in &equations {
        if derivative_target(&eq.lhs).is_some() {
            stack.extend(crate::expression::free_variables(&eq.rhs));
            stack.extend(crate::expression::free_variables(&eq.lhs));
        }
    }
    while let Some(name) = stack.pop() {
        if !cone.insert(name.clone()) {
            continue;
        }
        for &k in definers.get(name.as_str()).into_iter().flatten() {
            stack.extend(crate::expression::free_variables(&equations[k].rhs));
            stack.extend(crate::expression::free_variables(&equations[k].lhs));
        }
    }
    let mut kept_eqs = Vec::new();
    let mut kept_contribs = Vec::new();
    let mut kept_lifted = Vec::new();
    for ((eq, c), lifted) in equations.into_iter().zip(contributions).zip(lifted_flags) {
        let keep = match derivative_target(&eq.lhs) {
            Some(_) => true,
            None => defined_name(&eq.lhs).is_none_or(|n| cone.contains(n)),
        };
        if keep {
            kept_eqs.push(eq);
            kept_contribs.push(c);
            kept_lifted.push(lifted);
        }
    }
    out.equations = kept_eqs;
    out.equation_contributions = kept_contribs;
    if !out.equation_lifted.is_empty() {
        out.equation_lifted = kept_lifted;
    }
    out.state_variables
        .retain(|name, _| writes.contains(name) || cone.contains(name));
    out.observed_variables.retain(|name, _| cone.contains(name));
    out.algebraic_variables
        .retain(|name, _| writes.contains(name) || cone.contains(name));
    out.field_ics
        .retain(|(name, _)| out.state_variables.contains_key(name));
    Ok((out, writes))
}
