//! The dependency cone of a set of requested observeds
//! ([`crate::problem::ProblemOptions::observed_cone`]).
//!
//! A document with nothing to integrate is its observed graph, and a caller
//! that wants a few of its fields need not pay for the rest: each requested
//! observed, and transitively every observed its definition NAMES, is the cone;
//! everything outside it can be left unevaluated without moving a value inside
//! it, because an observed in the cone is evaluated exactly as before, from the
//! same inputs.
//!
//! "Names" is deliberately an over-approximation of what an evaluation reads:
//! any string anywhere in a definition's serialized form — a bare reference, a
//! `join.on` column, a table name, a range's source, a map key — that is an
//! observed's key. A cone that is too wide costs only time; one that is too
//! narrow would drop an input, so the walk errs wide.

use std::collections::HashSet;

use crate::types::Expr;

/// Every string in `expr`'s serialized form, map keys included: a superset of
/// the names its evaluation can read, whichever field of a node carries them.
pub(crate) fn named_strings(expr: &Expr) -> HashSet<String> {
    let mut out = HashSet::new();
    // Serializing an in-memory expression does not fail; were it ever to, a
    // reference this walk misses is an unbound name at evaluation — a loud
    // build error, not a wrong value.
    if let Ok(v) = serde_json::to_value(expr) {
        json_strings(&v, &mut out);
    }
    out
}

/// Every string value and object key under `v`.
pub(crate) fn json_strings(v: &serde_json::Value, out: &mut HashSet<String>) {
    match v {
        serde_json::Value::String(s) => {
            out.insert(s.clone());
        }
        serde_json::Value::Array(a) => a.iter().for_each(|x| json_strings(x, out)),
        serde_json::Value::Object(m) => {
            for (k, x) in m {
                out.insert(k.clone());
                json_strings(x, out);
            }
        }
        _ => {}
    }
}

/// Whether the caller-spelled `name` may address the key `key`, under the
/// resolution rules of [`crate::problem::observed_field`] taken as a superset:
/// the key itself, the key under `prefix` (the built model's `"<Model>."`), or
/// — for a name with no dot — any key whose last dotted segment it is. A name
/// with dots also addresses a key it is a dot-boundary tail of (`Sub.x` names
/// `Model.Sub.x` in a whole-document build).
pub(crate) fn addresses(key: &str, name: &str, prefix: Option<&str>) -> bool {
    key == name
        || prefix
            .and_then(|p| name.strip_prefix(p))
            .is_some_and(|rest| rest == key)
        || key
            .strip_suffix(name)
            .is_some_and(|head| head.ends_with('.'))
}

/// Whether any of `names` [`addresses`] `key`, without a scan of `names`: the
/// key, the key under `prefix`, and each of its dot-boundary tails are looked
/// up instead.
pub(crate) fn addressed_by_any(key: &str, names: &HashSet<String>, prefix: Option<&str>) -> bool {
    names.contains(key)
        || prefix.is_some_and(|p| names.contains(&format!("{p}{key}")))
        || key
            .match_indices('.')
            .any(|(i, _)| names.contains(&key[i + 1..]))
}

/// Every name an index set's fields carry — a ragged set's `offsets` and
/// `values`, a derived set's `from_faq` and `member_factor`, the parents it
/// ranges `of` — but not a categorical set's `members`, which are data. A
/// range over the set never names these, so an observed that backs one (a
/// ragged set's per-parent counts) is in no definition's names; it sizes an
/// axis, and the cone keeps it whatever the request.
pub(crate) fn index_set_names<'a>(
    sets: impl IntoIterator<Item = &'a crate::types::IndexSet>,
) -> HashSet<String> {
    let mut out = HashSet::new();
    for set in sets {
        if let Ok(serde_json::Value::Object(fields)) = serde_json::to_value(set) {
            for (field, v) in &fields {
                if field != "members" {
                    json_strings(v, &mut out);
                }
            }
        }
    }
    out
}

/// The closure of `seeds` under `reads`: every name reachable from a seed by
/// following `reads(name)`, restricted to names `is_node` accepts.
pub(crate) fn closure<'a>(
    seeds: impl IntoIterator<Item = String>,
    is_node: impl Fn(&str) -> bool,
    reads: impl Fn(&str) -> Option<&'a HashSet<String>>,
) -> HashSet<String> {
    let mut cone: HashSet<String> = HashSet::new();
    let mut frontier: Vec<String> = Vec::new();
    for s in seeds {
        if is_node(&s) && cone.insert(s.clone()) {
            frontier.push(s);
        }
    }
    while let Some(name) = frontier.pop() {
        let Some(rs) = reads(&name) else { continue };
        for r in rs {
            if is_node(r) && cone.insert(r.clone()) {
                frontier.push(r.clone());
            }
        }
    }
    cone
}

/// The observed an equation's left-hand side defines: `x`, or `x` in an
/// element-wise `index(x, …)`. `None` for anything else (a derivative, an
/// expression LHS), which pruning therefore never removes.
fn defined_name(lhs: &Expr) -> Option<&str> {
    match lhs {
        Expr::Variable(n) => Some(n),
        Expr::Operator(node) if node.op == "index" => match node.args.first() {
            Some(Expr::Variable(n)) => Some(n),
            _ => None,
        },
        _ => None,
    }
}

/// Narrow a STATE-FREE flattened system to the cone of `requested`: remove
/// every equation that defines an observed outside it, and that observed's
/// declaration.
///
/// Kept whatever the request: every equation that defines no observed, and
/// every observed an index set, an event or a field initial condition names —
/// a derived set's producer, member factor or extent source sizes an axis,
/// and the cone of a sizing observed is kept with it.
pub(crate) fn prune_flattened(flat: &mut crate::flatten::FlattenedSystem, requested: &[String]) {
    let observed: HashSet<&str> = flat.observed_variables.keys().map(String::as_str).collect();
    let mut reads: std::collections::HashMap<String, HashSet<String>> =
        std::collections::HashMap::new();
    for eq in &flat.equations {
        if let Some(n) = defined_name(&eq.lhs).filter(|n| observed.contains(n)) {
            let entry = reads.entry(n.to_string()).or_default();
            entry.extend(named_strings(&eq.rhs));
            entry.extend(named_strings(&eq.lhs));
        }
    }
    let mut pinned = index_set_names(flat.index_sets.values());
    let side = (
        serde_json::to_value(&flat.continuous_events),
        serde_json::to_value(&flat.discrete_events),
        serde_json::to_value(&flat.field_ics),
    );
    for v in [side.0, side.1, side.2] {
        match v {
            Ok(v) => json_strings(&v, &mut pinned),
            // Cannot see what sizes the system: leave it whole.
            Err(_) => return,
        }
    }
    // The pins are spelled as the document wrote them (an index set's
    // `offsets` is model-local) and the keys are qualified, so a pin matches
    // the way a request does.
    let seeds = observed
        .iter()
        .filter(|k| {
            addressed_by_any(k, &pinned, None) || requested.iter().any(|n| addresses(k, n, None))
        })
        .map(|k| k.to_string());
    let cone = closure(seeds, |n| observed.contains(n), |n| reads.get(n));

    let drop: HashSet<String> = observed
        .iter()
        .filter(|n| !cone.contains(**n))
        .map(|n| n.to_string())
        .collect();
    if drop.is_empty() {
        return;
    }
    let keep: Vec<bool> = flat
        .equations
        .iter()
        .map(|eq| defined_name(&eq.lhs).is_none_or(|n| !drop.contains(n)))
        .collect();
    // One pass over the mask compacts the equations and the two per-equation
    // records that run parallel to them (when they do: either may be empty).
    let n = keep.len();
    let contributions = flat.equation_contributions.len() == n;
    let lifted = flat.equation_lifted.len() == n;
    let mut kept = 0;
    for (i, _) in keep.iter().enumerate().filter(|(_, k)| **k) {
        flat.equations.swap(kept, i);
        if contributions {
            flat.equation_contributions.swap(kept, i);
        }
        if lifted {
            flat.equation_lifted.swap(kept, i);
        }
        kept += 1;
    }
    flat.equations.truncate(kept);
    if contributions {
        flat.equation_contributions.truncate(kept);
    }
    if lifted {
        flat.equation_lifted.truncate(kept);
    }
    flat.observed_variables.retain(|n, _| !drop.contains(n));
    flat.state_variables.retain(|n, _| !drop.contains(n));
}

#[cfg(test)]
mod tests {
    use super::{addressed_by_any, addresses};

    #[test]
    fn a_request_addresses_its_key_its_tail_and_its_prefixed_spelling() {
        assert!(addresses("Rel.x", "Rel.x", None));
        assert!(addresses("Rel.x", "x", None));
        assert!(addresses("Rel.Sub.x", "Sub.x", None));
        assert!(addresses("x", "Rel.x", Some("Rel.")));
        assert!(!addresses("Rel.xx", "x", None));
        assert!(!addresses("Rel.x", "Other.x", None));
    }

    #[test]
    fn addressed_by_any_agrees_with_addresses() {
        let names: std::collections::HashSet<String> = ["x", "Sub.y", "Rel.z", "Rel.w"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        for key in [
            "x",
            "Rel.x",
            "Rel.Sub.y",
            "Sub.y",
            "y",
            "z",
            "w",
            "Rel.xx",
            "Rel.Sub",
        ] {
            for prefix in [None, Some("Rel.")] {
                assert_eq!(
                    addressed_by_any(key, &names, prefix),
                    names.iter().any(|n| addresses(key, n, prefix)),
                    "{key} under {prefix:?}"
                );
            }
        }
    }
}
