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
//! Python loaders. This is the one copy of the migration: the loader, the
//! printers (through the canonical form) and `flatten` of a document built
//! in code ([`migrate_typed`]) all run it.

use serde_json::{Map, Value};

use crate::diagnostic::{DiagnosticError, codes, err};

/// Rewrite every model's `initialization_equations` of `doc` in place and
/// return the sites, as `<model pointer>/initialization_equations
/// (initialization_equations)`.
pub(crate) fn migrate_initialization_equations(
    doc: &mut Value,
) -> Result<Vec<String>, DiagnosticError> {
    let mut sites = Vec::new();
    if !needs_migration(doc) {
        return Ok(sites);
    }
    let legacy = declares_before_2_5_0(doc);
    let root = doc.clone();
    let Some(models) = doc.get_mut("models").and_then(Value::as_object_mut) else {
        return Ok(sites);
    };
    for (name, model) in models.iter_mut() {
        let ptr = format!("/models/{}", token(name));
        migrate_model(model, &ptr, &root, legacy, &mut sites)?;
    }
    Ok(sites)
}

/// Whether [`migrate_initialization_equations`] may have anything to do on
/// `doc`: a model carries the old block, or a document below esm 2.5.0 holds
/// an `ic` (perhaps of a parameter).
pub(crate) fn needs_migration(doc: &Value) -> bool {
    has_initialization_equations(doc) || (declares_before_2_5_0(doc) && contains_ic(doc))
}

/// Whether `doc` declares an `esm` version below 2.5.0, where `ic(k) ~ v` of
/// a parameter `k` was how a document set a parameter's starting value.
fn declares_before_2_5_0(doc: &Value) -> bool {
    let Some(v) = doc.get("esm").and_then(Value::as_str) else {
        return false;
    };
    let parts: Vec<u64> = v.split('.').map_while(|p| p.parse().ok()).collect();
    matches!(parts.as_slice(), [major, minor, ..] if (*major, *minor) < (2, 5))
}

/// Whether `v` holds an `ic` node anywhere.
fn contains_ic(v: &Value) -> bool {
    match v {
        Value::Object(m) => {
            m.get("op").and_then(Value::as_str) == Some("ic") || m.values().any(contains_ic)
        }
        Value::Array(items) => items.iter().any(contains_ic),
        _ => false,
    }
}

/// esm-spec §11.4.4 "An initial condition of a parameter": each equation of
/// `eqs` whose left-hand side names a declared parameter `k` of the model
/// (`ic(k)`, or bare `k` when `bare` is set) becomes `k`'s `default` and is
/// removed; its right-hand side must be a number (`ic_invalid_argument`
/// otherwise). Returns whether any was moved.
fn move_parameter_initial_conditions(
    obj: &mut Map<String, Value>,
    eqs: &mut Vec<Value>,
    bare: bool,
    at: &str,
) -> Result<bool, DiagnosticError> {
    let is_parameter = |obj: &Map<String, Value>, k: &str| {
        obj.get("variables")
            .and_then(|vs| vs.get(k))
            .and_then(|d| d.get("type"))
            .and_then(Value::as_str)
            == Some("parameter")
    };
    let mut moved = false;
    let mut kept = Vec::with_capacity(eqs.len());
    for (i, eq) in std::mem::take(eqs).into_iter().enumerate() {
        let lhs = eq.get("lhs");
        let target = match lhs {
            Some(Value::String(k)) if bare => Some(k.clone()),
            Some(Value::Object(m)) if m.get("op").and_then(Value::as_str) == Some("ic") => {
                match m.get("args").and_then(Value::as_array).map(Vec::as_slice) {
                    Some([Value::String(k)]) => Some(k.clone()),
                    _ => None,
                }
            }
            _ => None,
        };
        let Some(k) = target.filter(|k| is_parameter(obj, k)) else {
            kept.push(eq);
            continue;
        };
        let Some(value) = eq.get("rhs").filter(|v| v.is_number()).cloned() else {
            return Err(err(
                codes::IC_INVALID_ARGUMENT,
                format!(
                    "ic_invalid_argument: {at}/{i}: an initial condition of '{k}', a declared \
                     parameter, migrates into its `default`, so its right-hand side must be a \
                     number (esm-spec §11.4.4)"
                ),
            ));
        };
        if let Some(decl) = obj
            .get_mut("variables")
            .and_then(|vs| vs.get_mut(&k))
            .and_then(Value::as_object_mut)
        {
            decl.insert("default".to_string(), value);
        }
        moved = true;
    }
    *eqs = kept;
    Ok(moved)
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
    legacy: bool,
    sites: &mut Vec<String>,
) -> Result<(), DiagnosticError> {
    let Some(obj) = model.as_object_mut() else {
        return Ok(());
    };
    if let Some(subs) = obj.get_mut("subsystems").and_then(Value::as_object_mut) {
        for (name, sub) in subs.iter_mut() {
            let sub_ptr = format!("{ptr}/subsystems/{}", token(name));
            migrate_model(sub, &sub_ptr, root, legacy, sites)?;
        }
    }
    // Below esm 2.5.0, `ic(k) ~ v` of a parameter in `equations` set its
    // starting value: it becomes `k`'s default.
    if legacy && let Some(Value::Array(mut list)) = obj.remove("equations") {
        let at = format!("{ptr}/equations");
        let moved = move_parameter_initial_conditions(obj, &mut list, false, &at);
        obj.insert("equations".to_string(), Value::Array(list));
        if moved? {
            sites.push(format!("{at} (ic of a parameter)"));
        }
    }
    let Some(block) = obj.remove("initialization_equations") else {
        return Ok(());
    };
    let mut eqs: Vec<Value> = match block {
        Value::Array(v) => v,
        Value::Null => Vec::new(),
        other => {
            return Err(err(
                codes::DEPRECATED_FIELD,
                format!(
                    "{ptr}/initialization_equations: expected a list of equations, got {other}"
                ),
            ));
        }
    };
    if eqs.is_empty() {
        return Ok(());
    }
    sites.push(format!(
        "{ptr}/initialization_equations (initialization_equations)"
    ));
    // An initial condition of a parameter, in any version, becomes its
    // default before the rest is rewritten.
    move_parameter_initial_conditions(
        obj,
        &mut eqs,
        true,
        &format!("{ptr}/initialization_equations"),
    )?;
    if eqs.is_empty() {
        return Ok(());
    }
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
                    "deprecated_field: {ptr}/initialization_equations/{k}: the model has no time \
                     derivative, so \
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
                let nv = match (k.as_str(), v) {
                    ("args" | "expr" | "filter" | "values" | "lower" | "upper" | "key", _) => {
                        wrap_in(v, is_unknown)
                    }
                    // An operator call's arguments (esm-spec §9.6.12): a map
                    // from a param name to the expression it binds.
                    ("bindings", Value::Object(b)) => Value::Object(
                        b.iter()
                            .map(|(p, e)| (p.clone(), wrap_unknowns(e, is_unknown)))
                            .collect(),
                    ),
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

/// Whether `name` names an unknown seen from `model` (a variable of type
/// `unknown`, or a reaction-system species).
fn names_unknown(name: &str, model: &Value, root: &Value) -> bool {
    matches!(var_type(name, model, root), Some("unknown" | "species"))
}

/// The type of the variable `name` names seen from `model`: a local
/// variable's `type`, or — for a scoped reference, resolved relative to the
/// model's subsystems first and then from the document root — that
/// variable's `type`, or `"species"` for a reaction-system species.
fn var_type<'a>(name: &str, model: &'a Value, root: &'a Value) -> Option<&'a str> {
    let type_in = |m: &'a Value, v: &str| -> Option<&'a str> {
        m.get("variables")?.get(v)?.get("type")?.as_str()
    };
    let Some((scope, leaf)) = name.rsplit_once('.') else {
        return type_in(model, name);
    };
    let path: Vec<&str> = scope.split('.').collect();
    let descend = |mut m: &'a Value, segs: &[&str]| -> Option<&'a Value> {
        for s in segs {
            m = m.get("subsystems")?.get(*s)?;
        }
        Some(m)
    };
    if let Some(t) = descend(model, &path).and_then(|m| type_in(m, leaf)) {
        return Some(t);
    }
    if let Some(t) = root
        .get("models")
        .and_then(|ms| ms.get(path[0]))
        .and_then(|top| descend(top, &path[1..]))
        .and_then(|m| type_in(m, leaf))
    {
        return Some(t);
    }
    let rs = descend(root.get("reaction_systems")?.get(path[0])?, &path[1..])?;
    if rs.get("species").and_then(|sp| sp.get(leaf)).is_some() {
        return Some("species");
    }
    rs.get("parameters")
        .and_then(|ps| ps.get(leaf))
        .map(|_| "parameter")
}

/// esm-spec §4.2 (`ic`): an `ic` whose argument names a declared parameter,
/// bare or scoped (`ic(k)`, `ic(D(k))`), is malformed — a parameter has no
/// starting value of its own — and refused with `ic_invalid_argument` naming
/// the node's JSON pointer. Checked over every model's equations (at any
/// `subsystems` depth) of a loaded document, after the migration.
pub(crate) fn check_ic_parameter_arguments(doc: &Value) -> Result<(), DiagnosticError> {
    fn walk(e: &Value, at: &str, model: &Value, root: &Value) -> Result<(), DiagnosticError> {
        match e {
            Value::Object(m) => {
                if m.get("op").and_then(Value::as_str) == Some("ic") {
                    let name = match m.get("args").and_then(|a| a.get(0)) {
                        Some(Value::String(v)) => Some(v.as_str()),
                        Some(Value::Object(d)) => {
                            d.get("args").and_then(|a| a.get(0)).and_then(Value::as_str)
                        }
                        _ => None,
                    };
                    if let Some(n) = name
                        && var_type(n, model, root) == Some("parameter")
                    {
                        return Err(err(
                            codes::IC_INVALID_ARGUMENT,
                            format!(
                                "ic_invalid_argument: {at}: `ic` of '{n}', a declared \
                                 parameter: a parameter has no starting value of its own; \
                                 read its value as `{n}` (esm-spec §4.2)"
                            ),
                        ));
                    }
                    return Ok(());
                }
                for (k, v) in m {
                    walk(v, &format!("{at}/{}", token(k)), model, root)?;
                }
                Ok(())
            }
            Value::Array(items) => {
                for (i, v) in items.iter().enumerate() {
                    walk(v, &format!("{at}/{i}"), model, root)?;
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }
    fn model_walk(model: &Value, ptr: &str, root: &Value) -> Result<(), DiagnosticError> {
        if let Some(eqs) = model.get("equations") {
            walk(eqs, &format!("{ptr}/equations"), model, root)?;
        }
        if let Some(subs) = model.get("subsystems").and_then(Value::as_object) {
            for (name, sub) in subs {
                model_walk(sub, &format!("{ptr}/subsystems/{}", token(name)), root)?;
            }
        }
        Ok(())
    }
    for (name, model) in doc
        .get("models")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
    {
        model_walk(model, &format!("/models/{}", token(name)), doc)?;
    }
    Ok(())
}

/// A document built in code (no loader read it) that still carries the
/// deprecated `initialization_equations`, migrated exactly as the loader
/// migrates it ([`migrate_initialization_equations`]); `None` when no model
/// carries the field.
pub(crate) fn migrate_typed(
    file: &crate::EsmFile,
) -> Result<Option<crate::EsmFile>, DiagnosticError> {
    use crate::types::HasSubsystems;
    fn carries(m: &crate::Model) -> bool {
        m.initialization_equations.is_some() || m.inline_subsystems().any(|(_, s)| carries(s))
    }
    if !file.models.iter().flatten().any(|(_, m)| carries(m)) {
        return Ok(None);
    }
    let bad = |e: serde_json::Error| {
        err(
            codes::DEPRECATED_FIELD,
            format!("initialization_equations: the document does not round-trip: {e}"),
        )
    };
    let mut doc = serde_json::to_value(file).map_err(bad)?;
    migrate_initialization_equations(&mut doc)?;
    serde_json::from_value(doc).map(Some).map_err(bad)
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
        codes::IC_INVALID_ARGUMENT,
        format!(
            "ic_invalid_argument: {at}: malformed `ic`: its one argument must be a variable reference or `D` of one \
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
    fn operator_call_bindings_are_rewritten() {
        let mut doc = json!({"models": {"M": {
        "variables": {"x": {"type": "unknown"}, "k": {"type": "parameter"}},
        "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": "k"}],
        "initialization_equations": [{"lhs": "x", "rhs": {"op": "apply_operator",
            "args": [], "name": "f", "bindings": {"a": "x", "b": "k"}}}]}}});
        migrate_initialization_equations(&mut doc).unwrap();
        let rhs = &doc["models"]["M"]["equations"][1]["rhs"];
        assert_eq!(rhs["bindings"]["a"], json!({"op": "ic", "args": ["x"]}));
        assert_eq!(rhs["bindings"]["b"], json!("k"));
    }

    #[test]
    fn an_old_initial_condition_of_a_parameter_becomes_its_default() {
        let model = json!({
            "variables": {"u": {"type": "unknown"},
                          "p": {"type": "parameter", "default": 1.0},
                          "q": {"type": "parameter", "default": 3.0}},
            "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": 0},
                          {"lhs": {"op": "ic", "args": ["q"]}, "rhs": 2.0}],
            "initialization_equations": [{"lhs": "p", "rhs": 5.0}]});
        let mut old = json!({"esm": "2.4.0", "models": {"M": model.clone()}});
        let sites = migrate_initialization_equations(&mut old).unwrap();
        assert_eq!(sites.len(), 2);
        let m = &old["models"]["M"];
        assert_eq!(m["variables"]["p"]["default"], json!(5.0));
        assert_eq!(m["variables"]["q"]["default"], json!(2.0));
        assert_eq!(m["equations"].as_array().unwrap().len(), 1);
        check_ic_parameter_arguments(&old).unwrap();

        // At esm 2.5.0, `ic(q)` of a parameter is refused, with its location.
        let mut new = json!({"esm": "2.5.0", "models": {"M": model}});
        migrate_initialization_equations(&mut new).unwrap();
        let e = check_ic_parameter_arguments(&new).unwrap_err();
        assert_eq!(e.code, codes::IC_INVALID_ARGUMENT);
        assert!(
            e.message.contains("/models/M/equations/1/lhs"),
            "{}",
            e.message
        );

        // A right-hand side that is not a number has no reading as a default.
        let mut bad = json!({"esm": "2.4.0", "models": {"M": {
            "variables": {"p": {"type": "parameter"}},
            "equations": [{"lhs": {"op": "ic", "args": ["p"]}, "rhs": "p0"}]}}});
        let e = migrate_initialization_equations(&mut bad).unwrap_err();
        assert_eq!(e.code, codes::IC_INVALID_ARGUMENT);
    }

    #[test]
    fn ic_argument_shapes() {
        let ok = |v: Value| check_ic_node(v.as_object().unwrap(), "/").is_ok();
        assert!(ok(json!({"op": "ic", "args": ["u"]})));
        assert!(ok(
            json!({"op": "ic", "args": [{"op": "D", "args": ["u"], "wrt": "t"}]})
        ));
        assert!(!ok(
            json!({"op": "ic", "args": [{"op": "index", "args": ["u", 1]}]})
        ));
        assert!(!ok(json!({"op": "ic", "args": ["u", "v"]})));
    }
}
