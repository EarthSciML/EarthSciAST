//! `halo` (RFC U3 §3): how far an operator's owned output reaches into each
//! state along each decomposed or face index set.
//!
//! Each rule's own reach is measured one slab at a time: the rule restricted
//! to the output cells at coordinate `c` along a decomposed set (the whole of
//! every other axis), its reads taken relative to `c`. That restriction clips
//! every makearray to the regions that apply at `c`, so a reach that occurs
//! only in a boundary slab is counted there and nowhere else, and the report
//! is the maximum over regions. Reads along a periodic axis are taken at their
//! nearest periodic image, so an explicit wrap (`f[N]` read from cell 1)
//! counts as a reach of one across the seam. Reaches compose through
//! observeds by interval sum: if `du[i]` reads `F[i]` and `F[i+1]`, and `F[j]`
//! reads `u[j-3..j+2]`, then `u` is reached over `-3..3`.

use super::tile::refusal_error;
use super::walk::{AxisSpec, Scope, VarInfo, Walker};
use super::{Decomposition, HaloReport, RhsProgram, range_error, var_infos};
use crate::diagnostic::codes;
use crate::simulate::SimulateError;
use crate::simulate_array::{AlgebraicRule, RhsRule};
use crate::types::Expr;
use std::collections::HashMap;

/// Per (variable, decomposed cell set): the reach interval relative to the
/// output cell.
type Reach = HashMap<(String, String), (i64, i64)>;

fn widen(r: &mut Reach, key: (String, String), lo: i64, hi: i64) {
    let e = r.entry(key).or_insert((lo, hi));
    *e = (e.0.min(lo), e.1.max(hi));
}

/// The offset `g − c` taken at its nearest periodic image when the axis has a
/// period and `g` is in the domain.
fn offset(g: i64, c: i64, spec: &AxisSpec) -> i64 {
    let d = g - c;
    match spec {
        AxisSpec::Cut {
            period: Some(n),
            hi,
            ..
        } if g >= 1 && g <= *hi => {
            let mut m = d.rem_euclid(*n);
            if m > n / 2 {
                m -= n;
            }
            m
        }
        _ => d,
    }
}

/// One rule's own reach: its output symbols run along `syms` over `ranges`,
/// output axis `d` along the cut set `sets[d]`.
#[allow(clippy::too_many_arguments)]
fn local_reach(
    vars: &HashMap<String, VarInfo>,
    rule: &str,
    syms: &[String],
    ranges: &[(i64, i64)],
    sets: &[Option<String>],
    contracted: &[String],
    bodies: &[&Expr],
) -> Result<Reach, SimulateError> {
    let mut reach = Reach::new();
    for (a, set) in sets.iter().enumerate() {
        let Some(set) = set else { continue };
        for c in ranges[a].0..=ranges[a].1 {
            let mut lo: Vec<i64> = ranges.iter().map(|r| r.0).collect();
            let mut hi: Vec<i64> = ranges.iter().map(|r| r.1).collect();
            lo[a] = c;
            hi[a] = c;
            let sc = Scope {
                syms: syms.to_vec(),
                lo,
                hi,
                sets: sets.to_vec(),
                contracted: contracted.to_vec(),
            };
            let mut w = Walker::new(vars, rule.to_string());
            for b in bodies {
                w.expr(b, &sc).map_err(refusal_error)?;
            }
            for r in &w.reads {
                let Some(info) = vars.get(&r.var) else {
                    continue;
                };
                let spec = &info.axes[r.axis];
                if spec.cut_cell() != Some(set.as_str()) {
                    continue;
                }
                let key = (r.var.clone(), set.clone());
                if r.lo == r.hi {
                    let o = offset(r.lo, c, spec);
                    widen(&mut reach, key, o, o);
                } else {
                    widen(&mut reach, key, r.lo - c, r.hi - c);
                }
            }
        }
    }
    Ok(reach)
}

/// A state-dependent observed computed wholesale (not cell by cell): every
/// output cell sees the whole value, so a read of a state (or of a
/// state-dependent observed) along a decomposed axis is one no box of reach
/// bounds. The walk refuses a whole-array read or a reduction along such an
/// axis; any other read along one (a fixed cell) is `range_global_locality`.
/// `states` holds the walker's view of the states and the state-dependent
/// observeds only.
fn wholesale_reach(
    states: &HashMap<String, VarInfo>,
    var: &str,
    body: &Expr,
) -> Result<(), SimulateError> {
    let mut w = Walker::new(states, var.to_string());
    w.expr(body, &Scope::default()).map_err(refusal_error)?;
    for r in &w.reads {
        if let Some(AxisSpec::Cut { set, .. }) = states[&r.var].axes.get(r.axis) {
            return Err(range_error(
                codes::RANGE_GLOBAL_LOCALITY,
                format!(
                    "observed `{var}` is computed whole and reads `{}` along the decomposed axis \
                     `{set}`, so its locality is global along `{set}`",
                    r.var
                ),
            ));
        }
    }
    Ok(())
}

pub(super) fn halo(prog: &RhsProgram, dec: &Decomposition) -> Result<HaloReport, SimulateError> {
    let vars = var_infos(prog, dec);
    let compiled = &*prog.inner.model;
    let mut top = Reach::new();
    for rule in &compiled.rhs_rules {
        let RhsRule::ArrayLoop {
            var_name,
            output_idx_names,
            output_ranges,
            body,
            contract_names,
            filter,
            ..
        } = rule
        else {
            continue;
        };
        let info = &vars[var_name];
        let sets: Vec<Option<String>> = info
            .axes
            .iter()
            .map(|a| a.cut_cell().map(str::to_string))
            .collect();
        let mut bodies: Vec<&Expr> = vec![body];
        if let Some(f) = filter {
            bodies.push(f);
        }
        let local = local_reach(
            &vars,
            &format!("D({var_name})"),
            output_idx_names,
            output_ranges,
            &sets,
            contract_names,
            &bodies,
        )?;
        for (k, (lo, hi)) in local {
            widen(&mut top, k, lo, hi);
        }
    }
    // The states the program reads: the free names of its derivatives,
    // closed through the observeds they read.
    let mut read: std::collections::HashSet<String> = std::collections::HashSet::new();
    for rule in &compiled.rhs_rules {
        match rule {
            RhsRule::Scalar { body, .. } | RhsRule::IndexedScalar { body, .. } => {
                read.extend(crate::expression::free_variables(body));
            }
            RhsRule::ArrayLoop { body, filter, .. } => {
                read.extend(crate::expression::free_variables(body));
                if let Some(f) = filter {
                    read.extend(crate::expression::free_variables(f));
                }
            }
        }
    }
    for rule in compiled.observed_rules.iter().rev() {
        let (var, body) = match rule {
            AlgebraicRule::Scalar { var, body, .. }
            | AlgebraicRule::ArrayLoop { var, body, .. }
            | AlgebraicRule::Recurrence { var, body, .. } => (var, body),
        };
        if read.contains(var) {
            read.extend(crate::expression::free_variables(body));
        }
    }
    let dependent = super::tile::state_dependent(compiled);
    let dependent_vars: HashMap<String, VarInfo> = vars
        .iter()
        .filter(|(n, _)| compiled.var_shapes.contains_key(*n) || dependent.contains(*n))
        .map(|(n, v)| (n.clone(), v.clone()))
        .collect();
    for rule in compiled.observed_rules.iter().rev() {
        let converted = super::tile::as_loop(rule);
        let rule = converted.as_ref().unwrap_or(rule);
        let (var, output_idx_names, output_ranges, body) = match rule {
            AlgebraicRule::ArrayLoop {
                var,
                output_idx_names,
                output_ranges,
                body,
            } => (var, output_idx_names, output_ranges, body),
            AlgebraicRule::Recurrence {
                var,
                output_idx_names,
                output_ranges,
                body,
                axis,
                ..
            } => {
                if !read.contains(var) || !dependent.contains(var) {
                    continue;
                }
                if let Some(AxisSpec::Cut { set, .. }) = vars[var].axes.get(*axis) {
                    return Err(range_error(
                        codes::RANGE_GLOBAL_LOCALITY,
                        format!(
                            "observed `{var}` is a recurrence along the decomposed axis `{set}`, \
                             so its locality is global along `{set}`"
                        ),
                    ));
                }
                (var, output_idx_names, output_ranges, body)
            }
            AlgebraicRule::Scalar { var, body, .. } => {
                if read.contains(var) && dependent.contains(var) {
                    wholesale_reach(&dependent_vars, var, body)?;
                }
                continue;
            }
        };
        let info = &vars[var];
        let sets: Vec<Option<String>> = info
            .axes
            .iter()
            .map(|a| a.cut_cell().map(str::to_string))
            .collect();
        let reached: Vec<(String, (i64, i64))> = sets
            .iter()
            .flatten()
            .filter_map(|s| top.get(&(var.clone(), s.clone())).map(|r| (s.clone(), *r)))
            .collect();
        if reached.is_empty() {
            continue;
        }
        let local = local_reach(
            &vars,
            var,
            output_idx_names,
            output_ranges,
            &sets,
            &[],
            &[body],
        )?;
        for ((x, set), (lo, hi)) in local {
            if let Some((_, (a, b))) = reached.iter().find(|(s, _)| *s == set) {
                widen(&mut top, (x, set), a + lo, b + hi);
            }
        }
    }
    let mut entries = std::collections::BTreeMap::new();
    for name in prog
        .inner
        .writes
        .iter()
        .chain(&prog.inner.aux)
        .filter(|n| read.contains(*n))
    {
        let info = &vars[name];
        for spec in &info.axes {
            let AxisSpec::Cut { set, cell, .. } = spec else {
                continue;
            };
            let (lo, hi) = top
                .get(&(name.clone(), cell.clone()))
                .copied()
                .unwrap_or((0, 0));
            entries.insert((name.clone(), set.clone()), ((-lo).max(0), hi.max(0)));
        }
    }
    Ok(HaloReport { reach: entries })
}
