//! esm-spec §9.6.4 rules 1 and 7, §10.7 at a §4.7 mount edge: a mounted leaf
//! keeps its template references, and its components' template definitions
//! join the mounting component's registry in the leaf's OWN names by flatten's
//! registry-merge rule (deep-equal entries kept once; a name two non-equal
//! entries share renamed to `<owner path>.<name>`, one entry per distinct
//! definition named after its first owner, references following). A body's
//! free names are read in the scope of the subsystem that owns the reference,
//! so Expand is plain substitution; flatten closes every body (its free names
//! become trailing parameters). Drives
//! `tests/conformance/expression_templates/mount_registry_merge/` and
//! `mount_shared_definition/` against the Julia-generated goldens
//! (`flattened_registry.esm`, `inline_flattened_registry.esm`,
//! `inline_emitted.esm`, `loaded_registry.esm`), byte for byte.
#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::extension::lower_expression_templates::{
    emit_document, emit_esm_string, expand, lower_expression_templates,
};
use earthsci_ast::{
    Compiler, EsmFile, ProblemOptions, esm_problem, flatten, initial_state, load_path, load_string,
    resolve_subsystem_refs_raw, rhs_program,
};
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::path::PathBuf;

use crate::common;

fn dir(case: &str) -> PathBuf {
    common::repo_fixture("conformance/expression_templates").join(case)
}

fn read(case: &str, name: &str) -> String {
    std::fs::read_to_string(dir(case).join(name)).expect("read fixture file")
}

/// `reg` written as the goldens write it: one `expression_templates` block,
/// so its entry order is kept.
fn block_text(reg: impl IntoIterator<Item = (String, Value)>) -> String {
    let block: Map<String, Value> = reg.into_iter().collect();
    let mut doc = Map::new();
    doc.insert("operators".to_string(), Value::Object(block));
    emit_esm_string(&Value::Object(doc))
}

/// The flattened system's merged template registry.
fn flattened_registry(case: &str, name: &str) -> String {
    let file = load_path(dir(case).join(name)).expect("load");
    let flat = flatten(&file).expect("flatten");
    block_text(flat.template_registry)
}

/// The loaded file's registry of the top-level component `models.Host`.
fn host_registry(file: &EsmFile) -> Map<String, Value> {
    file.component_templates
        .as_ref()
        .and_then(|ct| ct.get("models.Host"))
        .and_then(Value::as_object)
        .expect("models.Host carries a registry")
        .clone()
}

fn loaded_registry(case: &str, name: &str) -> String {
    block_text(host_registry(
        &load_path(dir(case).join(name)).expect("load"),
    ))
}

/// The document `name` with its mounts resolved, lowered and fully expanded
/// (Expand of the load), as a JSON value.
fn expanded_value(case: &str, name: &str) -> Value {
    let mut raw: Value = serde_json::from_str(&read(case, name)).expect("parse");
    resolve_subsystem_refs_raw(&mut raw, &dir(case)).expect("resolve mounts");
    lower_expression_templates(&mut raw).expect("lower");
    expand(&mut raw).expect("expand");
    // The goldens are the expansion of the LOADED document, which carries
    // the §9.6.4 rule-8 version floor (esm 2.4.0) a load stamps on a document
    // with template machinery.
    raw["esm"] = Value::from("2.4.0");
    raw
}

/// The right-hand side at the initial state and t = 0.3, by state name,
/// under the native compiler.
fn du(file: &EsmFile) -> HashMap<String, f64> {
    let opts = ProblemOptions {
        compiler: Some(Compiler::Native),
        ..Default::default()
    };
    let prob = esm_problem(file, (0.0, 1.0), opts).expect("problem");
    let prog = rhs_program(&prob).expect("rhs program");
    let u = initial_state(&prob).expect("initial state");
    let p = prog
        .parameter_vector(&HashMap::new())
        .expect("parameter vector");
    let mut ws = prog.new_workspace();
    let mut d = vec![0.0; prog.n_states()];
    prog.eval_into(&u, &[], &p, 0.3, &prog.default_forcing(), &mut d, &mut ws)
        .expect("evaluate");
    prog.state_layout()
        .iter()
        .map(|b| (b.name.clone(), d[b.flat_offset]))
        .collect()
}

#[test]
fn a_mounted_leafs_registry_merges_into_the_mounting_component() {
    let c = "mount_registry_merge";
    assert_eq!(
        flattened_registry(c, "fixture.esm"),
        read(c, "flattened_registry.esm")
    );
    assert_eq!(
        loaded_registry(c, "fixture.esm"),
        read(c, "loaded_registry.esm")
    );
}

#[test]
fn an_inline_subsystems_registry_merges_by_the_same_rule() {
    let c = "mount_registry_merge";
    assert_eq!(
        flattened_registry(c, "inline_form.esm"),
        read(c, "inline_flattened_registry.esm")
    );
}

#[test]
fn the_inline_form_emits_the_merged_registry() {
    let c = "mount_registry_merge";
    let raw: Value = serde_json::from_str(&read(c, "inline_form.esm")).expect("parse");
    let emitted = emit_document(&raw, &dir(c)).expect("emit");
    assert_eq!(emit_esm_string(&emitted), read(c, "inline_emitted.esm"));
}

/// The mounted and inline forms denote the same system: the leaf's `match`
/// rule `dbl(a) -> a + a` fired in the leaf, and the inline form spells that
/// sum out; every renamed reference reaches its own owner's body.
#[test]
fn the_mounted_and_inline_forms_flatten_to_the_same_equations() {
    let c = "mount_registry_merge";
    // `flatten` keeps references: the two forms reference their definitions
    // differently (the inline form names one template its mount wraps) and
    // denote the same equations, so they are compared expanded, here in the
    // test only.
    let eqs = |name: &str| {
        let flat = flatten(&load_path(dir(c).join(name)).expect("load")).expect("flatten");
        let flat = crate::flatten_wire_conformance::expanded(&flat);
        flat.equations
            .iter()
            .map(|e| serde_json::to_string(e).expect("serialize"))
            .collect::<Vec<_>>()
    };
    let mounted = eqs("fixture.esm");
    assert_eq!(mounted, eqs("inline_form.esm"));
    let all = mounted.join("\n");
    // Host's own `scale` (2x), the leaf's (3x, read through `rate`, whose body
    // reads the leaf's own `k`: substituted into Sub, it is Sub's `k`), and
    // Inner's reference to Host's.
    let want = [
        r#"{"lhs":{"op":"D","args":["Host.y"],"wrt":"t"},"rhs":{"op":"-","args":[{"op":"*","args":[2,"Host.y"]}]}}"#,
        r#"{"lhs":{"op":"D","args":["Host.z"],"wrt":"t"},"rhs":{"op":"-","args":[{"op":"/","args":["Host.z",2]}]}}"#,
        r#"{"lhs":{"op":"D","args":["Host.Sub.c"],"wrt":"t"},"rhs":{"op":"-","args":[{"op":"*","args":["Host.Sub.k",{"op":"*","args":[3,"Host.Sub.c"]}]}]}}"#,
        r#"{"lhs":{"op":"D","args":["Host.Sub.d"],"wrt":"t"},"rhs":{"op":"-","args":[{"op":"+","args":[{"op":"/","args":["Host.Sub.d",2]},{"op":"/","args":["Host.Sub.d",2]}]}]}}"#,
        r#"{"lhs":{"op":"D","args":["Host.Inner.w"],"wrt":"t"},"rhs":{"op":"-","args":[{"op":"*","args":[2,"Host.Inner.w"]}]}}"#,
    ];
    assert_eq!(mounted, want, "{all}");
}

/// The run of each form equals the run of its expanded document.
#[test]
#[ignore = "native compiles references once: QUESTIONS.md Q1"]
fn mount_registry_merge_runs_as_its_expansion() {
    let c = "mount_registry_merge";
    for f in ["fixture.esm", "inline_form.esm"] {
        let n = du(&load_path(dir(c).join(f)).expect("load"));
        let expanded = load_string(&expanded_value(c, f).to_string()).expect("load expanded");
        assert_eq!(n, du(&expanded), "{f}");
        assert_eq!(n["Host.Sub.c"], -(0.25 * 3.0 * 1.0), "{f}");
    }
}

/// One leaf mounted twice brings ONE definition of each template, in the
/// leaf's own names.
#[test]
fn mount_shared_definition_registries_match_the_goldens() {
    let c = "mount_shared_definition";
    assert_eq!(
        flattened_registry(c, "fixture.esm"),
        read(c, "flattened_registry.esm")
    );
    assert_eq!(
        loaded_registry(c, "fixture.esm"),
        read(c, "loaded_registry.esm")
    );
    let reg = host_registry(&load_path(dir(c).join("fixture.esm")).expect("load"));
    let mut names: Vec<&str> = reg.keys().map(String::as_str).collect();
    names.sort_unstable();
    assert_eq!(names, ["Host.rate", "Sub1.rate", "loss", "pull"]);
    assert_eq!(
        reg["Sub1.rate"]["body"],
        json!({"op": "*", "args": ["k", "x"]})
    );
}

/// Each mount's references read its own `k` (a coupling gives Sub2's another
/// value), and Inner's reference to Host's `pull` reads Inner's own `g`:
/// Expand substitutes the body into the subsystem, and the run agrees with the
/// run of the expanded document.
#[test]
#[ignore = "native compiles references once: QUESTIONS.md Q1"]
fn mount_shared_definition_reads_each_sites_own_names() {
    let c = "mount_shared_definition";
    let n = du(&load_path(dir(c).join("fixture.esm")).expect("load"));
    let value = expanded_value(c, "fixture.esm");
    let expanded = load_string(&value.to_string()).expect("load expanded");
    assert_eq!(n, du(&expanded));
    assert_eq!(n["Host.Sub1.c"], -0.25);
    assert_eq!(n["Host.Sub2.c"], -2.0);
    assert_eq!(n["Host.Sub1.d"], -0.0625);
    assert_eq!(n["Host.Sub2.d"], -0.5);
    assert_eq!(n["Host.y"], -2.0);
    assert_eq!(n["Host.z"], -1.0);
    assert_eq!(n["Host.Inner.w"], -9.0);

    // Expand(load): Sub1's equations read Sub1's own `k`, Inner's read Inner's
    // own `g`, each spelled as the subsystem reads it.
    let subs = &value["models"]["Host"]["subsystems"];
    let rhs = |sub: &str, i: usize| subs[sub]["equations"][i]["rhs"].clone();
    assert_eq!(
        rhs("Sub1", 0),
        json!({"op": "-", "args": [{"op": "*", "args": ["k", "c"]}]})
    );
    assert_eq!(
        rhs("Sub1", 1),
        json!({"op": "-", "args": [{"op": "*", "args": ["k", "d", "d"]}]})
    );
    assert_eq!(
        rhs("Inner", 0),
        json!({"op": "-", "args": [{"op": "*", "args": ["g", "w"]}]})
    );
}

/// Number-tolerant structural equality (Julia writes an integral float in an
/// operand position as an integer).
fn json_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.get(k).is_some_and(|w| json_eq(v, w)))
        }
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(v, w)| json_eq(v, w))
        }
        _ => a == b,
    }
}

/// esm-spec §9.6.3: Host's `match` rule `cube` fires on the content of the
/// models Host mounts, at any depth (Sub, Sub's own mount Deep, and Bare,
/// which declares no templates), as on an authored subsystem's.
#[test]
#[ignore = "native compiles references once: QUESTIONS.md Q1"]
fn mount_host_rule_fires_in_the_mounted_content() {
    let c = "mount_host_rule";
    assert_eq!(
        loaded_registry(c, "fixture.esm"),
        read(c, "loaded_registry.esm")
    );
    assert_eq!(
        flattened_registry(c, "fixture.esm"),
        read(c, "flattened_registry.esm")
    );
    let golden: Value = serde_json::from_str(&read(c, "expanded.esm")).expect("parse golden");
    let value = expanded_value(c, "fixture.esm");
    assert!(
        json_eq(&value, &golden),
        "Expand of the mounted document != expanded.esm:\n{}",
        serde_json::to_string_pretty(&value).unwrap()
    );
    // Expand of the typed load gives the same document.
    let file = load_path(dir(c).join("fixture.esm")).expect("load");
    let mut loaded: Value =
        serde_json::from_str(&earthsci_ast::to_json(&file).expect("save")).expect("parse");
    expand(&mut loaded).expect("expand");
    assert!(
        json_eq(&loaded["models"], &golden["models"]),
        "Expand of the load != expanded.esm:\n{}",
        serde_json::to_string_pretty(&loaded["models"]).unwrap()
    );
    let n = du(&file);
    let expanded = load_string(&value.to_string()).expect("load expanded");
    assert_eq!(n, du(&expanded));
    assert_eq!(n["Host.y"], -(1.5f64.powi(3)));
    assert_eq!(n["Host.Sub.c"], -1.0);
    assert_eq!(n["Host.Sub.d"], -1.0);
    assert_eq!(n["Host.Sub.e"], -(0.25 * 8.0));
    assert_eq!(n["Host.Sub.Deep.h"], -(2.0 * 0.125));
    assert_eq!(n["Host.Bare.g"], -27.0);
}

/// esm-spec §10.7: a body's `join` clauses name component variables it reads
/// nowhere else (an overlap gate's envelope factors, an `on` clause's key
/// columns); closing makes them parameters, as it does the body's variable
/// leaves.
#[test]
fn flatten_closes_join_names() {
    let c = "flatten_closes_join_names";
    assert_eq!(
        flattened_registry(c, "fixture.esm"),
        read(c, "flattened_registry.esm")
    );
}

/// A leaf model declaring `def` (one defined operator, raw JSON), with one
/// state `c` whose equation is `D(c) = rhs`.
fn leaf_model(def_name: &str, def: Value, rhs: Value) -> Value {
    json!({
        "operators": {def_name: def},
        "variables": {"c": {"type": "unknown", "units": "1", "default": 1.0}},
        "equations": [{"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs": rhs}]
    })
}

/// A host document whose model `Host` has one state `y` with
/// `D(y) = rhs`, the definitions `ops`, and the subsystem `Sub` = `sub`.
fn host_doc(ops: Value, rhs: Value, sub: Value) -> Value {
    let mut host = json!({
        "variables": {"y": {"type": "unknown", "units": "1", "default": 1.0}},
        "equations": [{"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": rhs}],
        "subsystems": {"Sub": sub}
    });
    if ops.is_object() {
        host["operators"] = ops;
    }
    json!({"esm": "2.4.0", "metadata": {"name": "host"}, "models": {"Host": host}})
}

/// `host` loaded from a directory that also holds `leaf` as `leaf.esm`.
fn load_with_leaf(host: &Value, leaf: &Value) -> Result<EsmFile, String> {
    let d = tempfile::tempdir().expect("tempdir");
    std::fs::write(d.path().join("leaf.esm"), leaf.to_string()).expect("write leaf");
    std::fs::write(d.path().join("host.esm"), host.to_string()).expect("write host");
    load_path(d.path().join("host.esm")).map_err(|e| format!("{} {e}", e.code().unwrap_or("")))
}

fn saved(file: &EsmFile) -> Value {
    serde_json::from_str(&earthsci_ast::to_json(file).expect("save")).expect("json")
}

/// The leaf `leaf.esm` defining `scale(x) = 3*x`, with `D(c) = -scale(c)`.
fn scale_leaf() -> Value {
    json!({
        "esm": "2.4.0",
        "metadata": {"name": "leaf"},
        "models": {"Leaf": leaf_model(
            "scale",
            json!({"params": ["x"], "body": {"op": "*", "args": [3, "x"]}}),
            json!({"op": "-", "args": [{"op": "scale", "args": ["c"]}]}),
        )}
    })
}

/// esm-spec §4.7, §9.6.12: a mounted leaf's definitions are local to the leaf.
/// A call in the mounting component of an operator only the leaf defines is a
/// placeholder there, not a call of the leaf's definition; the leaf's own call
/// keeps resolving to it.
#[test]
fn a_mounted_leafs_definition_does_not_resolve_the_mounting_components_call() {
    let host = host_doc(
        Value::Null,
        json!({"op": "-", "args": [{"op": "scale", "args": ["y"]}]}),
        json!({"ref": "./leaf.esm"}),
    );
    let v = saved(&load_with_leaf(&host, &scale_leaf()).expect("load"));
    assert_eq!(
        v["models"]["Host"]["equations"][0]["rhs"],
        json!({"op": "-", "args": [{"op": "scale", "args": ["y"]}]}),
        "the host's call must stay a placeholder"
    );
    assert_eq!(
        v["models"]["Host"]["subsystems"]["Sub"]["equations"][0]["rhs"],
        json!({"op": "-", "args": [{"op": "*", "args": [3, "c"]}]}),
    );
}

/// The same with the subsystem written inline: its definitions resolve its own
/// calls, and only its own.
#[test]
fn an_inline_subsystems_definition_resolves_only_its_own_calls() {
    let sub = leaf_model(
        "scale",
        json!({"params": ["x"], "body": {"op": "*", "args": [3, "x"]}}),
        json!({"op": "-", "args": [{"op": "scale", "args": ["c"]}]}),
    );
    let host = host_doc(
        Value::Null,
        json!({"op": "-", "args": [{"op": "scale", "args": ["y"]}]}),
        sub,
    );
    let v = saved(&load_string(&host.to_string()).expect("load"));
    assert_eq!(
        v["models"]["Host"]["equations"][0]["rhs"],
        json!({"op": "-", "args": [{"op": "scale", "args": ["y"]}]}),
    );
    assert_eq!(
        v["models"]["Host"]["subsystems"]["Sub"]["equations"][0]["rhs"],
        json!({"op": "-", "args": [{"op": "*", "args": [3, "c"]}]}),
    );
}

/// esm-spec §9.6.12 "Arity": a mounted leaf's definitions do not count toward
/// the arity of a call in the mounting component. With no definition of its
/// own, the host's two-operand call is a placeholder; with one, it resolves to
/// it.
#[test]
#[ignore = "native compiles references once: QUESTIONS.md Q1"]
fn a_mounted_leafs_definition_does_not_count_for_the_mounting_components_arity() {
    let leaf = json!({
        "esm": "2.4.0",
        "metadata": {"name": "leaf"},
        "models": {"Leaf": leaf_model(
            "pair",
            json!({"params": ["x"], "body": {"op": "*", "args": [3, "x"]}}),
            json!({"op": "-", "args": [{"op": "pair", "args": ["c"]}]}),
        )}
    });
    let call = json!({"op": "-", "args": [{"op": "pair", "args": ["y", "y"]}]});
    let placeholder = host_doc(Value::Null, call.clone(), json!({"ref": "./leaf.esm"}));
    let v = saved(&load_with_leaf(&placeholder, &leaf).expect("a placeholder loads"));
    assert_eq!(v["models"]["Host"]["equations"][0]["rhs"], call);

    let defined = host_doc(
        json!({"pair": {"params": ["a", "b"], "body": {"op": "+", "args": ["a", "b"]}}}),
        call,
        json!({"ref": "./leaf.esm"}),
    );
    let file = load_with_leaf(&defined, &leaf).expect("load");
    let n = du(&file);
    assert_eq!(n["Host.y"], -2.0);
    assert_eq!(n["Host.Sub.c"], -3.0);
}

/// The emitted form of a host whose call is a placeholder next to a
/// subsystem's definition of the same operator emits again unchanged. The
/// subsystem's definition joins the host's registry at emit, so this needs it
/// written `reference_only` there (esm-spec §9.6.1).
#[test]
fn a_subsystems_definition_stays_uncallable_after_emit() {
    let sub = leaf_model(
        "scale",
        json!({"params": ["x"], "body": {"op": "*", "args": [3, "x"]}}),
        json!({"op": "-", "args": [{"op": "scale", "args": ["c"]}]}),
    );
    let host = host_doc(
        Value::Null,
        json!({"op": "-", "args": [{"op": "scale", "args": ["y"]}]}),
        sub,
    );
    let d = tempfile::tempdir().expect("tempdir");
    let doc = emit_document(&host, d.path()).expect("emit");
    assert_eq!(
        doc["models"]["Host"]["equations"][0]["rhs"],
        json!({"op": "-", "args": [{"op": "scale", "args": ["y"]}]}),
    );
    let emitted = emit_esm_string(&doc);
    let again = emit_document(&serde_json::from_str(&emitted).unwrap(), d.path()).expect("emit");
    assert_eq!(emit_esm_string(&again), emitted);
}
