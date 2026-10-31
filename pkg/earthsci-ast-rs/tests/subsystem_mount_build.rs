//! esm-spec §6.6's sanctioned shape for asserting on a coupled system: "an
//! assembly that needs an assertion about the coupled system declares that
//! test on a component the assembly document itself declares". Concretely, a
//! model that mounts a leaf under `subsystems: {Leaf: ...}` and reads
//! `Leaf.<var>`. Two things blocked it on the ingesting build:
//!
//! * a `kind: data` parameter inside the subsystem was bound by nothing. The
//!   provider key is the full path `Parent.Leaf.p`; the mounted model spells
//!   the parameter `Leaf.p`, and nothing published that spelling;
//! * a subsystem variable's declared `element_type` was refused
//!   (`element_type_uncarried`), because precision inference and per-rule
//!   arming read top-level model variables only. Refusing was the safe answer;
//!   evaluating it in the document's precision would have been the silent
//!   precision change §11.3.1 forbids.
//!
//! Every assertion below is on a value the document's `default`s, or the
//! wrong precision, cannot produce, and each fix has a negative control.

#![cfg(not(target_arch = "wasm32"))]

use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

use earthsci_ast::{
    Compiler, PrepareError, PrepareProvider, ProblemOptions, esm_problem, load_string,
    observed_field,
};

struct MockConst(Vec<f64>);

impl PrepareProvider for MockConst {
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
        Ok(ArrayD::from_shape_vec(IxDyn(&[self.0.len()]), self.0.clone()).unwrap())
    }
}

/// A leaf with one data-fed column `p` over `rows` and its sum `total`.
/// `element_type`, when given, is declared on both.
fn data_leaf(element_type: Option<&str>) -> Value {
    let mut leaf = json!({
        "variables": {
            "p": {
                "type": "parameter", "units": "1", "default": 0.0,
                "shape": ["rows"],
                "update": {"kind": "data", "source": "src", "from": {"file_variable": "p"}}
            },
            "total": {"type": "unknown", "units": "1"}
        },
        "equations": [{
            "lhs": "total",
            "rhs": {
                "op": "faq", "args": [], "semiring": "sum_product", "output_idx": [],
                "ranges": {"r": {"from": "rows"}},
                "expr": {"op": "index", "args": ["p", "r"]}
            }
        }]
    });
    if let Some(et) = element_type {
        for v in ["p", "total"] {
            leaf["variables"][v]["element_type"] = json!(et);
        }
    }
    leaf
}

/// A document holding `models`, with the data source and the two-row axis the
/// leaf reads. The source is never opened: the test supplies the provider.
fn data_document(models: Value) -> Value {
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "subsystem_mount_build"},
        "index_sets": {"rows": {"kind": "interval", "size": 2}},
        "data_sources": {
            "src": {"kind": "static", "source": {"url_template": "never-read.parquet"}}
        },
        "models": models
    })
}

/// Build `model` of `doc` with one provider, keyed `key`, and read `var`.
fn build_and_read(
    doc: &Value,
    model: &str,
    key: &str,
    values: &[f64],
    var: &str,
) -> Result<f64, String> {
    let file = load_string(&doc.to_string()).map_err(|e| e.to_string())?;
    let prob = esm_problem(
        &file,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(Compiler::Interpreter),
            model_name: Some(model.to_string()),
            build_providers: vec![(
                key.to_string(),
                Box::new(MockConst(values.to_vec())) as Box<dyn PrepareProvider>,
            )],
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string())?;
    let arr = observed_field(&prob, var).map_err(|e| e.to_string())?;
    arr.iter()
        .next()
        .copied()
        .ok_or_else(|| format!("{var} evaluated to an empty field"))
}

// ---- a subsystem's data-fed parameter is bound ------------------------------

/// The control: the same leaf at the top level always bound.
#[test]
fn a_top_level_data_fed_leaf_binds() {
    let doc = data_document(json!({"Leaf": data_leaf(None)}));
    let got = build_and_read(&doc, "Leaf", "Leaf.p", &[3.0, 5.0], "total").unwrap();
    assert_eq!(got, 8.0);
}

/// The defect: mounted as a subsystem, the parameter was unbound.
#[test]
fn a_subsystem_data_fed_parameter_binds_under_its_model_local_name() {
    let doc = data_document(json!({
        "Parent": {
            "subsystems": {"Leaf": data_leaf(None)},
            "variables": {},
            "equations": []
        }
    }));
    let got = build_and_read(&doc, "Parent", "Parent.Leaf.p", &[3.0, 5.0], "Leaf.total")
        .unwrap_or_else(|e| panic!("the mounted leaf did not build: {e}"));
    assert_eq!(got, 8.0);
}

/// Negative control: the alias is EXACT. A provider keyed under another
/// model's path does not feed `Parent.Leaf.p`, so the sum is not 8 — the
/// build either refuses or evaluates the declared default.
#[test]
fn a_provider_under_another_models_path_does_not_bind_the_subsystem() {
    let doc = data_document(json!({
        "Parent": {
            "subsystems": {"Leaf": data_leaf(None)},
            "variables": {},
            "equations": []
        }
    }));
    let got = build_and_read(&doc, "Parent", "Other.Leaf.p", &[3.0, 5.0], "Leaf.total");
    assert!(
        !matches!(got, Ok(v) if v == 8.0),
        "a provider for `Other.Leaf.p` fed `Parent.Leaf.p`: {got:?}"
    );
}

// ---- a subsystem variable's declared element_type is evaluated -------------

/// `x` = 100*((100-a)/100)/(100-a): 0.99999994 in binary32, exactly 1 in
/// binary64. `key` is a ten-digit code above binary32's exact-integer limit.
fn precision_leaf(quantity: Option<&str>) -> Value {
    let mut leaf = json!({
        "variables": {
            "a": {"type": "parameter", "units": "1", "default": 73.5},
            "x": {"type": "unknown", "units": "1"},
            "key": {"type": "parameter", "units": "1", "default": 2265007010_i64,
                    "element_type": "Float64"},
            "key_next": {"type": "unknown", "units": "1", "element_type": "Float64"},
            "flag": {"type": "unknown", "units": "1"}
        },
        "equations": [
            {"lhs": "x", "rhs": {"op": "/", "args": [
                {"op": "*", "args": [100, {"op": "/", "args": [
                    {"op": "-", "args": [100, "a"]}, 100]}]},
                {"op": "-", "args": [100, "a"]}]}},
            {"lhs": "key_next", "rhs": {"op": "+", "args": ["key", 5]}},
            // 0 when the comparison runs in binary64; 1 when it is narrowed to
            // binary32, where 2265007015 and 2265007010 are one number.
            {"lhs": "flag", "rhs": {"op": "==", "args": ["key_next", 2265007010_i64]}}
        ]
    });
    if let Some(et) = quantity {
        for v in ["a", "x", "flag"] {
            leaf["variables"][v]["element_type"] = json!(et);
        }
    }
    leaf
}

fn host(leaf: Value, extra_equations: Vec<Value>, domain: Option<&str>) -> Value {
    let mut doc = json!({
        "esm": "1.2.0",
        "metadata": {"name": "subsystem_precision"},
        "models": {
            "Host": {
                "subsystems": {"Leaf": leaf},
                "variables": {"z": {"type": "unknown", "units": "1"}},
                "equations": extra_equations
            }
        }
    });
    if doc["models"]["Host"]["equations"]
        .as_array()
        .is_some_and(Vec::is_empty)
    {
        doc["models"]["Host"]["equations"] = json!([{"lhs": "z", "rhs": 2}]);
    }
    if let Some(d) = domain {
        doc["domain"] = json!({"element_type": d});
    }
    doc
}

fn evaluate(doc: &Value, var: &str) -> Result<f64, String> {
    let file = load_string(&doc.to_string()).map_err(|e| e.to_string())?;
    let prob = esm_problem(
        &file,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(Compiler::Interpreter),
            model_name: Some("Host".to_string()),
            build_pipeline: true,
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string())?;
    let arr = observed_field(&prob, var).map_err(|e| e.to_string())?;
    Ok(arr.iter().next().copied().expect("non-empty"))
}

const F32_WITNESS: f64 = 0.9999999403953552;

/// A binary32 subsystem inside a binary64 document: its quantities round,
/// its declared-binary64 key does not, and a comparison over the key runs in
/// binary64.
#[test]
fn a_float32_subsystem_of_a_float64_document_evaluates_in_binary32() {
    let doc = host(precision_leaf(Some("Float32")), vec![], None);
    let x = evaluate(&doc, "Leaf.x").unwrap();
    assert_eq!(x.to_bits(), F32_WITNESS.to_bits(), "Leaf.x = {x:?}");
    assert_eq!(evaluate(&doc, "Leaf.key_next").unwrap(), 2265007015.0);
    assert_eq!(evaluate(&doc, "Leaf.flag").unwrap(), 0.0);
    // The host's own variables stay binary64.
    assert_eq!(evaluate(&doc, "z").unwrap(), 2.0);
}

/// The other direction: a Float32 document whose subsystem declares binary64
/// keys. The quantity follows the document; the keys stay exact.
#[test]
fn a_float64_key_in_a_subsystem_of_a_float32_document_stays_exact() {
    let doc = host(precision_leaf(None), vec![], Some("Float32"));
    let x = evaluate(&doc, "Leaf.x").unwrap();
    assert_eq!(x.to_bits(), F32_WITNESS.to_bits(), "Leaf.x = {x:?}");
    assert_eq!(evaluate(&doc, "Leaf.key_next").unwrap(), 2265007015.0);
    assert_eq!(evaluate(&doc, "Leaf.flag").unwrap(), 0.0);
}

/// Control: with no declaration anywhere, the same leaf is plain binary64.
#[test]
fn an_undeclared_subsystem_is_unaffected() {
    let doc = host(precision_leaf(None), vec![], None);
    let mut doc = doc;
    doc["models"]["Host"]["subsystems"]["Leaf"]["variables"]["key"]
        .as_object_mut()
        .unwrap()
        .remove("element_type");
    doc["models"]["Host"]["subsystems"]["Leaf"]["variables"]["key_next"]
        .as_object_mut()
        .unwrap()
        .remove("element_type");
    assert_eq!(evaluate(&doc, "Leaf.x").unwrap(), 1.0);
}

/// Negative control: inference now SEES a subsystem's precisions, so mixing
/// one with the host's binary64 is the error §11.3.1 requires, at the host
/// and inside the subsystem alike — never a silent widening.
#[test]
fn mixing_a_subsystem_precision_is_mixed_element_type() {
    let at_host = host(
        precision_leaf(Some("Float32")),
        vec![json!({"lhs": "z", "rhs": {"op": "+", "args": ["Leaf.x", "Leaf.key"]}})],
        None,
    );
    let e = evaluate(&at_host, "z").expect_err("a mixed host equation built");
    assert!(e.contains("mixed_element_type"), "{e}");

    let mut inside = precision_leaf(Some("Float32"));
    inside["equations"]
        .as_array_mut()
        .unwrap()
        .push(json!({"lhs": "x2", "rhs": {"op": "+", "args": ["x", "key"]}}));
    inside["variables"]["x2"] = json!({"type": "unknown", "units": "1", "element_type": "Float32"});
    let e = evaluate(&host(inside, vec![], None), "Leaf.x2")
        .expect_err("a mixed subsystem equation built");
    assert!(e.contains("mixed_element_type"), "{e}");
}

/// Both fixes at once — the shape the moves.esm fixtures need: a binary32
/// data-fed column inside a subsystem of a binary64 document. The column is
/// rounded where it enters (under its full provider key) and summed in
/// binary32 (under its mounted rule name).
#[test]
fn a_float32_data_fed_subsystem_parameter_binds_and_sums_in_binary32() {
    let doc = data_document(json!({
        "Parent": {
            "subsystems": {"Leaf": data_leaf(Some("Float32"))},
            "variables": {},
            "equations": []
        }
    }));
    let got = build_and_read(&doc, "Parent", "Parent.Leaf.p", &[0.1, 0.2], "Leaf.total").unwrap();
    let want = f64::from(0.1_f32 + 0.2_f32);
    assert_eq!(got.to_bits(), want.to_bits(), "got {got:?}, want {want:?}");
    assert_ne!(got, 0.1 + 0.2, "summed in binary64");
}
