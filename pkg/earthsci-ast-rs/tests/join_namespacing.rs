//! CROSS-BINDING conformance for §5.5.6 join-name namespacing under flattening.
//!
//! A relational `join` carries its references as plain STRINGS — an `on` key
//! column, and an `overlap` clause's `src_env` / `tgt_env` envelope factors —
//! rather than as `Expr::Variable` children. That is an ENCODING choice, not a
//! scoping one: the value-invention materializer resolves every one of those
//! names against the variable registry (`vi_join_index_sym` → `ctx.variables`,
//! `broad_phase::envelope_vectors` → `ctx.const_arrays`), and after flattening
//! that registry is the dot-namespaced one. So they must be namespaced with
//! everything else, under the same declared-local gate — a loop symbol or a
//! document-scoped index set named by an `on` column is NOT a local variable
//! and passes through untouched.
//!
//! Before this was fixed, Rust flattened the SAME six names two different ways
//! within one node: `args` (expression children) became `ISRM.X`… while
//! `src_env`/`tgt_env` stayed bare `X`… — and materialising the flattened model
//! died with `join references unknown variable "X"`. Julia
//! (`namespacing.jl::_namespace_join`) had it right all along.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::flatten::flatten;
use earthsci_ast::types::Expr;
use earthsci_ast::value_invention::materialize_value_invention;
use ndarray::{ArrayD, IxDyn};
use serde_json::{Map, Value};

const FIXTURE: &str = "tests/fixtures/pushdown/overlap_gate_point_in_rect.esm";

fn col(v: Vec<f64>) -> ArrayD<f64> {
    let n = v.len();
    ArrayD::from_shape_vec(IxDyn(&[n]), v).expect("1-D column")
}

/// The ISRM L1 geometry (3x3 grid of 2x2 cells; 5 points in cells {1,2,4,9}),
/// keyed under `prefix` — `"ISRM."` for the flattened registry.
fn l1_geometry(prefix: &str) -> HashMap<String, ArrayD<f64>> {
    [
        ("W", vec![0.0, 2.0, 4.0, 0.0, 2.0, 4.0, 0.0, 2.0, 4.0]),
        ("E", vec![2.0, 4.0, 6.0, 2.0, 4.0, 6.0, 2.0, 4.0, 6.0]),
        ("S", vec![0.0, 0.0, 0.0, 2.0, 2.0, 2.0, 4.0, 4.0, 4.0]),
        ("N", vec![2.0, 2.0, 2.0, 4.0, 4.0, 4.0, 6.0, 6.0, 6.0]),
        ("X", vec![1.0, 3.0, 1.0, 5.0, 1.5]),
        ("Y", vec![1.0, 1.0, 3.0, 5.0, 1.5]),
    ]
    .into_iter()
    .map(|(k, v)| (format!("{prefix}{k}"), col(v)))
    .collect()
}

/// The single aggregate RHS of the flattened fixture.
fn flattened_producer(
    flat_eqs: &[earthsci_ast::types::Equation],
) -> &earthsci_ast::types::ExpressionNode {
    match &flat_eqs[0].rhs {
        Expr::Operator(n) => n,
        other => panic!("expected an aggregate RHS, got {other:?}"),
    }
}

/// Re-assemble a flattened system into the raw-JSON model view the
/// value-invention engine consumes (variables + equations + the
/// document-scoped `index_sets` registry as a sibling), exactly as
/// `run_value_invention` does for a typed `Model`.
fn flattened_model_json(doc: &Value, flat: &earthsci_ast::flatten::FlattenedSystem) -> Value {
    let mut vars = Map::new();
    for (k, v) in flat
        .parameters
        .iter()
        .chain(flat.state_variables.iter())
        .chain(flat.observed_variables.iter())
    {
        vars.insert(k.clone(), serde_json::to_value(v).expect("variable"));
    }
    let mut m = Map::new();
    m.insert("variables".into(), Value::Object(vars));
    m.insert(
        "equations".into(),
        serde_json::to_value(&flat.equations).expect("equations"),
    );
    m.insert("index_sets".into(), doc["index_sets"].clone());
    Value::Object(m)
}

/// Flattening namespaces an `overlap` clause's envelope factors, because they
/// name variables. The regression this pins: `args` and `src_env`/`tgt_env`
/// name the SAME six factors in the same node, so they must agree after
/// flattening.
#[test]
fn flatten_namespaces_overlap_envelope_factors() {
    let text = std::fs::read_to_string(FIXTURE).expect("fixture");
    let file = earthsci_ast::parse::load(&text).expect("parse");
    let flat = flatten(&file).expect("flatten");
    let node = flattened_producer(&flat.equations);

    let join = node.join.as_ref().expect("the producer carries a join");
    let overlap = join[0].overlap.as_ref().expect("an overlap clause");
    assert_eq!(
        overlap.src_env,
        vec!["ISRM.X".to_string(), "ISRM.Y".to_string()],
        "src_env envelope factors must be namespaced with the registry they resolve against"
    );
    assert_eq!(
        overlap.tgt_env,
        vec![
            "ISRM.W".to_string(),
            "ISRM.S".to_string(),
            "ISRM.E".to_string(),
            "ISRM.N".to_string()
        ],
        "tgt_env envelope factors must be namespaced with the registry they resolve against"
    );

    // The same six names, as expression children, in the same node.
    let args: Vec<String> = node
        .args
        .iter()
        .map(|a| match a {
            Expr::Variable(v) => v.clone(),
            other => panic!("expected a bare factor arg, got {other:?}"),
        })
        .collect();
    let mut envs = overlap.src_env.clone();
    envs.extend(overlap.tgt_env.iter().cloned());
    envs.sort();
    let mut args_sorted = args.clone();
    args_sorted.sort();
    assert_eq!(
        args_sorted, envs,
        "a node must not spell the same factor two ways: args={args:?}"
    );

    // The flattened parameter registry is what those names must resolve in.
    for name in &envs {
        assert!(
            flat.parameters.contains_key(name),
            "{name} is not in the flattened parameter registry"
        );
    }
}

/// End-to-end: the FLATTENED model materialises the Julia golden support set
/// `[1,2,4,9]`. Before the fix this errored with
/// `join references unknown variable "X"` — the flattened registry holds only
/// `ISRM.X`, and there is no component-local registry left to resolve against.
#[test]
fn flattened_overlap_producer_materializes_the_golden_support_set() {
    let text = std::fs::read_to_string(FIXTURE).expect("fixture");
    let doc: Value = serde_json::from_str(&text).expect("json");
    let file = earthsci_ast::parse::load(&text).expect("parse");
    let flat = flatten(&file).expect("flatten");

    let model = flattened_model_json(&doc, &flat);
    let result = materialize_value_invention(
        &model,
        &l1_geometry("ISRM."),
        &HashMap::new(),
        &HashMap::new(),
    )
    .expect("the flattened overlap-gated producer must materialize");

    let members = result
        .members
        .get("emis_src_cells_faq")
        .expect("the producer's derived member set");
    let ids: Vec<i64> = members
        .iter()
        .map(|k| match k {
            earthsci_ast::Key::Int(i) => *i,
            other => panic!("expected integer member keys, got {other:?}"),
        })
        .collect();
    assert_eq!(
        ids,
        vec![1, 2, 4, 9],
        "flattening must not change the support set (§5.5.6: integer keys, byte-identical)"
    );
}

/// The gate is `locals`, not "every bare string". A `join.on` key column that
/// names a LOOP SYMBOL (a `ranges` key) or a document-scoped INDEX SET is not a
/// component-local variable and must survive flattening untouched — the exact
/// case Python's flattener cited as its reason for namespacing nothing at all,
/// and the reason Rust cannot simply prefix every bare name the way it does an
/// `Expr::Variable`. The committed M2 fixture's join is all four of them.
#[test]
fn join_on_loop_symbols_and_index_sets_are_left_alone() {
    let fixture = include_str!("../../../tests/valid/aggregate/join_filter.esm");
    let file = earthsci_ast::parse::load(fixture).expect("parse");
    let flat = flatten(&file).expect("flatten");
    let node = flattened_producer(&flat.equations);
    let on = &node.join.as_ref().expect("join")[0].on;
    assert_eq!(
        on,
        &vec![
            ["src".to_string(), "sourceType".to_string()],
            ["fuel".to_string(), "fuelType".to_string()],
        ],
        "loop symbols (`src`/`fuel`) and index sets (`sourceType`/`fuelType`) are not \
         component-local variables and must not be namespaced"
    );
}

/// ...and the positive half of the same gate: a `join.on` key column that DOES
/// name a component-local variable — a value-invention bin buffer, the
/// conservative regridder's `join.on [[rg_src_bin, rg_tgt_bin]]` — follows the
/// registry like any other reference.
#[test]
fn join_on_key_column_naming_a_local_buffer_is_namespaced() {
    let fixture = include_str!("../../../tests/valid/aggregate/join_filter.esm");
    let mut doc: Value = serde_json::from_str(fixture).expect("json");
    let vars = doc["models"]["EmissionsAggregate"]["variables"]
        .as_object_mut()
        .unwrap();
    vars.insert("src_bin".into(), serde_json::json!({ "type": "parameter" }));
    vars.insert("tgt_bin".into(), serde_json::json!({ "type": "parameter" }));
    doc["models"]["EmissionsAggregate"]["equations"][0]["rhs"]["join"] =
        serde_json::json!([{ "on": [["src_bin", "tgt_bin"], ["src", "sourceType"]] }]);

    let file = earthsci_ast::parse::load(&doc.to_string()).expect("parse");
    let flat = flatten(&file).expect("flatten");
    let node = flattened_producer(&flat.equations);
    let on = &node.join.as_ref().expect("join")[0].on;
    assert_eq!(
        on,
        &vec![
            [
                "EmissionsAggregate.src_bin".to_string(),
                "EmissionsAggregate.tgt_bin".to_string()
            ],
            ["src".to_string(), "sourceType".to_string()],
        ],
        "a declared local buffer is namespaced; a loop symbol / index set beside it is not"
    );
}

/// A `variable_map` that REMOVES the mapped parameter must carry the join names
/// with it, or the join points at a variable the flattened system no longer
/// declares. Mirrors Julia `coupling_apply.jl::_rename_join_names`.
#[test]
fn variable_map_removal_renames_join_envelope_names() {
    let text = std::fs::read_to_string(FIXTURE).expect("fixture");
    let mut doc: Value = serde_json::from_str(&text).expect("json");

    // A second component that publishes the west edge, mapped onto ISRM's own
    // `W` parameter (which `param_to_var` then removes from the flat system).
    doc["models"]["EDGE"] = serde_json::json!({
        "variables": { "src_W": { "type": "parameter", "shape": ["pop_cells"] } },
        "equations": []
    });
    doc["coupling"] = serde_json::json!([{
        "type": "variable_map",
        "from": "EDGE.src_W",
        "to": "ISRM.W",
        "transform": "param_to_var"
    }]);

    let file = earthsci_ast::parse::load(&doc.to_string()).expect("parse");
    let flat = flatten(&file).expect("flatten");
    assert!(
        !flat.parameters.contains_key("ISRM.W"),
        "param_to_var removes the mapped parameter"
    );

    let node = flat
        .equations
        .iter()
        .find_map(|eq| match &eq.rhs {
            Expr::Operator(n) if n.join.is_some() => Some(n),
            _ => None,
        })
        .expect("the producer survives coupling");
    let overlap = node.join.as_ref().unwrap()[0]
        .overlap
        .as_ref()
        .expect("overlap clause");
    assert_eq!(
        overlap.tgt_env[0], "EDGE.src_W",
        "the join must follow the variable_map, not point at the removed parameter"
    );
    for name in &overlap.tgt_env {
        assert!(
            flat.parameters.contains_key(name),
            "{name} is not declared in the flattened system"
        );
    }
}

/// A LOOP SYMBOL SHADOWED by a same-named declared variable stays a loop symbol.
///
/// esm-spec §4.3.1 lets one string be a variable reference in most contexts and
/// an index symbol inside an `aggregate`'s `output_idx` / `expr` / `ranges` keys,
/// so a model may legally declare a variable named `src` while an aggregate
/// binds `src` as a range. Inside the node the string denotes the LOOP SYMBOL,
/// and an `on` key column is resolved against THIS node's ranges — so prefixing
/// it makes the column resolve to nothing. The declared-local gate alone gets
/// this wrong: `src` is a declared local, so it would be prefixed. The node's
/// own binder set must win.
#[test]
fn shadowed_loop_symbol_stays_a_loop_symbol() {
    let fixture = include_str!("../../../tests/valid/aggregate/join_filter.esm");
    let mut doc: Value = serde_json::from_str(fixture).expect("json");
    // `src` is now BOTH a declared parameter and a `ranges` key of the producer.
    doc["models"]["EmissionsAggregate"]["variables"]["src"] =
        serde_json::json!({ "type": "parameter" });

    let file = earthsci_ast::parse::load(&doc.to_string()).expect("parse");
    let flat = flatten(&file).expect("flatten");
    let node = flattened_producer(&flat.equations);
    assert_eq!(
        &node.join.as_ref().expect("join")[0].on,
        &vec![
            ["src".to_string(), "sourceType".to_string()],
            ["fuel".to_string(), "fuelType".to_string()],
        ],
        "a loop symbol shadowed by a declared variable must not be namespaced"
    );
}

/// The other binder position: an `output_idx` entry shadowed by a declared
/// variable. `output_idx` also admits literal singleton dimensions, which the
/// binder scan must skip rather than trip over.
#[test]
fn shadowed_output_index_stays_a_binder() {
    let fixture = include_str!("../../../tests/valid/aggregate/join_filter.esm");
    let mut doc: Value = serde_json::from_str(fixture).expect("json");
    doc["models"]["EmissionsAggregate"]["variables"]["o"] =
        serde_json::json!({ "type": "parameter" });
    let rhs = &mut doc["models"]["EmissionsAggregate"]["equations"][0]["rhs"];
    rhs["output_idx"] = serde_json::json!(["o", 1]);
    rhs["join"] = serde_json::json!([{ "on": [["o", "sourceType"], ["src", "sourceType"]] }]);

    let file = earthsci_ast::parse::load(&doc.to_string()).expect("parse");
    let flat = flatten(&file).expect("flatten");
    let node = flattened_producer(&flat.equations);
    assert_eq!(
        &node.join.as_ref().expect("join")[0].on,
        &vec![
            ["o".to_string(), "sourceType".to_string()],
            ["src".to_string(), "sourceType".to_string()],
        ],
        "an output_idx binder shadowed by a declared variable must not be namespaced"
    );
}
