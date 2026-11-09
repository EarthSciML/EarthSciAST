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
    let mut pinned: HashSet<String> = HashSet::new();
    let side = (
        serde_json::to_value(&flat.index_sets),
        serde_json::to_value(&flat.continuous_events),
        serde_json::to_value(&flat.discrete_events),
        serde_json::to_value(&flat.field_ics),
    );
    for v in [side.0, side.1, side.2, side.3] {
        match v {
            Ok(v) => json_strings(&v, &mut pinned),
            // Cannot see what sizes the system: leave it whole.
            Err(_) => return,
        }
    }
    let seeds = observed
        .iter()
        .filter(|k| {
            pinned.contains(**k) || requested.iter().any(|n| addresses(k, n, None))
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
    let mut i = 0;
    flat.equations.retain(|_| {
        i += 1;
        keep[i - 1]
    });
    if flat.equation_contributions.len() == keep.len() {
        let mut i = 0;
        flat.equation_contributions.retain(|_| {
            i += 1;
            keep[i - 1]
        });
    }
    if flat.equation_lifted.len() == keep.len() {
        let mut i = 0;
        flat.equation_lifted.retain(|_| {
            i += 1;
            keep[i - 1]
        });
    }
    flat.observed_variables.retain(|n, _| !drop.contains(n));
    flat.state_variables.retain(|n, _| !drop.contains(n));
}

#[cfg(test)]
mod tests {
    use super::addresses;

    #[test]
    fn a_request_addresses_its_key_its_tail_and_its_prefixed_spelling() {
        assert!(addresses("Rel.x", "Rel.x", None));
        assert!(addresses("Rel.x", "x", None));
        assert!(addresses("Rel.Sub.x", "Sub.x", None));
        assert!(addresses("x", "Rel.x", Some("Rel.")));
        assert!(!addresses("Rel.xx", "x", None));
        assert!(!addresses("Rel.x", "Other.x", None));
    }
}
