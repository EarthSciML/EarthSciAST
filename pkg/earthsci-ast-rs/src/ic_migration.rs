//! esm 2.5.0: the deprecated `initialization_equations` block, read at the wire
//! boundary (esm-spec §11.4.4), and the load-time shape check of an `ic` node
//! (esm-spec §4.2, `ic`).
//!
//! For each model (top level and inline `subsystems` at any depth) that
//! carries `initialization_equations`, the field is removed and:
//!
//! - a model with a time derivative (some equation's left-hand side holds a
//!   `D`): every reference to an unknown `w` in each equation — bare, scoped or
//!   indexed — becomes `ic(w)`, and every time derivative `D(w)` becomes
//!   `ic(D(w))`; the equations are appended to `equations` in the field's order;
//! - a model with none (esm-spec §11.4.4 "A model with no time derivative"):
//!   each `v ~ e` with a bare unknown `v` becomes `guesses[v] = e` unless
//!   `guesses` already has `v`; any other equation is refused with
//!   `deprecated_field` as an error.
//!
//! Each non-empty block is one site of the document's `deprecated_field`
//! warning. Idempotent: a second pass finds nothing. Mirrors the Julia and
//! Python loaders.

use serde_json::{Map, Value};

use crate::diagnostic::{DiagnosticError, codes, err};

/// Rewrite every model's `initialization_equations` of `doc` in place and
/// return the sites, as `<model pointer>/initialization_equations
/// (initialization_equations)`.
pub(crate) fn migrate_initialization_equations(
    doc: &mut Value,
) -> Result<Vec<String>, DiagnosticError> {
    let mut sites = Vec::new();
    if !has_initialization_equations(doc) {
        return Ok(sites);
    }
    let root = doc.clone();
    let Some(models) = doc.get_mut("models").and_then(Value::as_object_mut) else {
        return Ok(sites);
    };
    for (name, model) in models.iter_mut() {
        let ptr = format!("/models/{}", token(name));
        migrate_model(model, &ptr, &root, &mut sites)?;
    }
    Ok(sites)
}

/// Whether any model of `doc` (at any depth) carries the old block.
pub(crate) fn has_initialization_equations(doc: &Value) -> bool {
    fn model_has(m: &Value) -> bool {
        let Some(o) = m.as_object() else {
            return false;
        };
        o.contains_key("initialization_equations")
            || o.get("subsystems")
                .and_then(Value::as_object)
                .is_some_and(|s| s.values().any(model_has))
    }
    doc.get("models")
        .and_then(Value::as_object)
        .is_some_and(|m| m.values().any(model_has))
}

fn token(k: &str) -> String {
    k.replace('~', "~0").replace('/', "~1")
}

fn migrate_model(
    model: &mut Value,
    ptr: &str,
    root: &Value,
    sites: &mut Vec<String>,
) -> Result<(), DiagnosticError> {
    let Some(obj) = model.as_object_mut() else {
        return Ok(());
    };
    if let Some(subs) = obj.get_mut("subsystems").and_then(Value::as_object_mut) {
        for (name, sub) in subs.iter_mut() {
            let sub_ptr = format!("{ptr}/subsystems/{}", token(name));
            migrate_model(sub, &sub_ptr, root, sites)?;
        }
    }
    let Some(block) = obj.remove("initialization_equations") else {
        return Ok(());
    };
    let eqs: Vec<Value> = match block {
        Value::Array(v) => v,
        Value::Null => Vec::new(),
        other => {
            return Err(err(
                codes::DEPRECATED_FIELD,
                format!("{ptr}/initialization_equations: expected a list of equations, got {other}"),
            ));
        }
    };
    if eqs.is_empty() {
        return Ok(());
    }
    sites.push(format!(
        "{ptr}/initialization_equations (initialization_equations)"
    ));
    let snapshot = Value::Object(obj.clone());
    let is_unknown = |name: &str| names_unknown(name, &snapshot, root);
    let has_time_derivative = obj
        .get("equations")
        .and_then(Value::as_array)
        .is_some_and(|es| es.iter().any(|e| e.get("lhs").is_some_and(contains_d)));
    if has_time_derivative {
        let mut migrated = Vec::with_capacity(eqs.len());
        for mut eq in eqs {
            if let Some(eo) = eq.as_object_mut() {
                for side in ["lhs", "rhs"] {
                    if let Some(e) = eo.get_mut(side) {
                        *e = wrap_unknowns(e, &is_unknown);
                    }
                }
            }
            migrated.push(eq);
        }
        let target = obj
            .entry("equations")
            .or_insert_with(|| Value::Array(Vec::new()));
        if let Value::Array(list) = target {
            list.extend(migrated);
        }
        return Ok(());
    }
    // No time derivative: starting points for the model's own solve.
    let mut guesses: Map<String, Value> = obj
        .get("guesses")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let locals = obj.get("variables").cloned().unwrap_or(Value::Null);
    for (k, eq) in eqs.into_iter().enumerate() {
        let lhs = eq.get("lhs").and_then(Value::as_str).filter(|v| {
            locals
                .get(*v)
                .and_then(|d| d.get("type"))
                .and_then(Value::as_str)
                == Some("unknown")
        });
        let Some(v) = lhs else {
            return Err(err(
                codes::DEPRECATED_FIELD,
                format!(
                    "{ptr}/initialization_equations/{k}: the model has no time derivative, so \
                     its initialization equations are starting points for its solve and move \
                     into `guesses` (esm-spec §11.4.4); this one's left-hand side is not a bare \
                     unknown, so it has no reading as a starting point. Write a `guesses` entry \
                     instead"
                ),
            ));
        };
        if !guesses.contains_key(v) {
            let rhs = eq.get("rhs").cloned().unwrap_or(Value::Null);
            guesses.insert(v.to_string(), rhs);
        }
    }
    obj.insert("guesses".to_string(), Value::Object(guesses));
    Ok(())
}

/// Whether the expression holds an op `D` node anywhere.
fn contains_d(e: &Value) -> bool {
    match e {
        Value::Object(m) => {
            m.get("op").and_then(Value::as_str) == Some("D") || m.values().any(contains_d)
        }
        Value::Array(items) => items.iter().any(contains_d),
        _ => false,
    }
}

fn ic_of(arg: Value) -> Value {
    let mut m = Map::new();
    m.insert("op".to_string(), Value::from("ic"));
    m.insert("args".to_string(), Value::Array(vec![arg]));
    Value::Object(m)
}

/// `e` with every unknown reference `w` written `ic(w)` and every time
/// derivative `D(w)` of an unknown written `ic(D(w))`.
fn wrap_unknowns(e: &Value, is_unknown: &dyn Fn(&str) -> bool) -> Value {
    match e {
        Value::String(s) if is_unknown(s) => ic_of(e.clone()),
        Value::Object(m) => {
            let op = m.get("op").and_then(Value::as_str);
            if op == Some("ic") {
                return e.clone();
            }
            let time = matches!(m.get("wrt"), None | Some(Value::Null))
                || m.get("wrt").and_then(Value::as_str) == Some("t");
            if op == Some("D")
                && time
                && m.get("args")
                    .and_then(Value::as_array)
                    .and_then(|a| a.first())
                    .and_then(Value::as_str)
                    .is_some_and(is_unknown)
            {
                return ic_of(e.clone());
            }
            let mut out = Map::new();
            for (k, v) in m {
                let nv = match k.as_str() {
                    "args" | "expr" | "filter" | "values" => wrap_in(v, is_unknown),
                    _ => v.clone(),
                };
                out.insert(k.clone(), nv);
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

fn wrap_in(v: &Value, is_unknown: &dyn Fn(&str) -> bool) -> Value {
    match v {
        Value::Array(items) => Value::Array(items.iter().map(|x| wrap_in(x, is_unknown)).collect()),
        other => wrap_unknowns(other, is_unknown),
    }
}

/// Whether `name` names an unknown seen from `model`: a local variable of type
/// `unknown`, or a scoped reference resolving, relative to the model's
/// subsystems first and then from the document root, to a variable of type
/// `unknown` or to a reaction-system species.
fn names_unknown(name: &str, model: &Value, root: &Value) -> bool {
    let is_unknown_var = |m: &Value, v: &str| {
        m.get("variables")
            .and_then(|vs| vs.get(v))
            .and_then(|d| d.get("type"))
            .and_then(Value::as_str)
            == Some("unknown")
    };
    let Some((scope, leaf)) = name.rsplit_once('.') else {
        return is_unknown_var(model, name);
    };
    let path: Vec<&str> = scope.split('.').collect();
    let descend = |mut m: &Value, segs: &[&str]| -> Option<Value> {
        for s in segs {
            m = m.get("subsystems")?.get(*s)?;
        }
        Some(m.clone())
    };
    if let Some(m) = descend(model, &path)
        && is_unknown_var(&m, leaf)
    {
        return true;
    }
    if let Some(top) = root.get("models").and_then(|ms| ms.get(path[0]))
        && let Some(m) = descend(top, &path[1..])
        && is_unknown_var(&m, leaf)
    {
        return true;
    }
    if let Some(rs) = root.get("reaction_systems").and_then(|r| r.get(path[0])) {
        let mut cur = rs.clone();
        for s in &path[1..] {
            match cur.get("subsystems").and_then(|x| x.get(*s)) {
                Some(n) => cur = n.clone(),
                None => return false,
            }
        }
        return cur.get("species").and_then(|sp| sp.get(leaf)).is_some();
    }
    false
}

/// A typed model's `initialization_equations` (a [`crate::Model`] built in
/// code, which no loader read) in the form the loader gives them: `ic`
/// equations, for a model with a time derivative. Empty otherwise.
pub(crate) fn typed_initialization_equations(model: &crate::Model) -> Vec<crate::Equation> {
    let Some(eqs) = model.initialization_equations.as_ref().filter(|e| !e.is_empty()) else {
        return Vec::new();
    };
    let has_d = model.equations.iter().any(|e| {
        serde_json::to_value(&e.lhs)
            .map(|v| contains_d(&v))
            .unwrap_or(false)
    });
    if !has_d {
        return Vec::new();
    }
    let is_unknown = |n: &str| {
        model
            .variables
            .get(n)
            .is_some_and(|v| v.var_type == crate::types::VariableType::Unknown)
    };
    eqs.iter()
        .filter_map(|eq| {
            let lhs = wrap_unknowns(&serde_json::to_value(&eq.lhs).ok()?, &is_unknown);
            let rhs = wrap_unknowns(&serde_json::to_value(&eq.rhs).ok()?, &is_unknown);
            Some(crate::Equation {
                lhs: serde_json::from_value(lhs).ok()?,
                rhs: serde_json::from_value(rhs).ok()?,
                comment: eq.comment.clone(),
            })
        })
        .collect()
}

/// The load-time shape check of an `ic` node (esm-spec §4.2, `ic`): its one
/// argument is a variable reference or `D` of one. `ic(index(u, i))` and
/// `ic(a + b)` are malformed; an element of `ic(u)` is `index(ic(u), i…)`.
pub(crate) fn check_ic_node(map: &Map<String, Value>, at: &str) -> Result<(), DiagnosticError> {
    let args = map.get("args").and_then(Value::as_array);
    let ok = match args.map(Vec::as_slice) {
        Some([Value::String(_)]) => true,
        Some([Value::Object(d)]) => {
            d.get("op").and_then(Value::as_str) == Some("D")
                && matches!(
                    d.get("args").and_then(Value::as_array).map(Vec::as_slice),
                    Some([Value::String(_)])
                )
        }
        _ => false,
    };
    if ok {
        return Ok(());
    }
    Err(err(
        codes::UNSUPPORTED_CONSTRUCT,
        format!(
            "{at}: malformed `ic`: its one argument must be a variable reference or `D` of one \
             (esm-spec §4.2); an element's starting value is written `index(ic(u), i)`, not \
             `ic(index(u, i))`"
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn unknowns_are_wrapped_and_parameters_kept() {
        let mut doc = json!({"models": {"M": {
            "variables": {"x": {"type": "unknown"}, "v": {"type": "unknown", "shape": ["n"]},
                          "k": {"type": "parameter"}},
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": "k"}],
            "initialization_equations": [
                {"lhs": "x", "rhs": {"op": "index", "args": ["v", "i"]}},
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 0}
            ]}}});
        let sites = migrate_initialization_equations(&mut doc).unwrap();
        assert_eq!(
            sites,
            ["/models/M/initialization_equations (initialization_equations)"]
        );
        let eqs = doc["models"]["M"]["equations"].as_array().unwrap();
        assert_eq!(eqs.len(), 3);
        assert_eq!(eqs[1]["lhs"], json!({"op": "ic", "args": ["x"]}));
        assert_eq!(
            eqs[1]["rhs"],
            json!({"op": "index", "args": [{"op": "ic", "args": ["v"]}, "i"]})
        );
        assert_eq!(
            eqs[2]["lhs"],
            json!({"op": "ic", "args": [{"op": "D", "args": ["x"], "wrt": "t"}]})
        );
        assert!(doc["models"]["M"].get("initialization_equations").is_none());
        assert!(
            migrate_initialization_equations(&mut doc)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn ic_argument_shapes() {
        let ok = |v: Value| check_ic_node(v.as_object().unwrap(), "/").is_ok();
        assert!(ok(json!({"op": "ic", "args": ["u"]})));
        assert!(ok(json!({"op": "ic", "args": [{"op": "D", "args": ["u"], "wrt": "t"}]})));
        assert!(!ok(json!({"op": "ic", "args": [{"op": "index", "args": ["u", 1]}]})));
        assert!(!ok(json!({"op": "ic", "args": ["u", "v"]})));
    }
}
