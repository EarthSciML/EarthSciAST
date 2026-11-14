//! The deprecated op spellings `neg` and `pow` (esm-spec §4.2 "Deprecated
//! ops", CONFORMANCE_SPEC `deprecated_op`), on the corpus documents kept to pin
//! them: each still loads, is rewritten to its replacement at the wire
//! boundary, and neither spelling survives into the emitted document.

use crate::common::load_repo_fixture;
use serde_json::Value;

/// Every `op` and `broadcast` `fn` string anywhere in `v`.
fn op_tags(v: &Value, out: &mut Vec<String>) {
    match v {
        Value::Object(map) => {
            for key in ["op", "fn"] {
                if let Some(Value::String(s)) = map.get(key) {
                    out.push(s.clone());
                }
            }
            map.values().for_each(|c| op_tags(c, out));
        }
        Value::Array(items) => items.iter().for_each(|c| op_tags(c, out)),
        _ => {}
    }
}

fn emitted(rel: &str) -> Value {
    let file = load_repo_fixture(rel);
    let text = earthsci_ast::to_json(&file).expect("emit");
    serde_json::from_str(&text).expect("emitted JSON")
}

fn rhs_of<'a>(doc: &'a Value, model: &str, lhs: &str) -> &'a Value {
    doc["models"][model]["equations"]
        .as_array()
        .expect("equations")
        .iter()
        .find(|e| e["lhs"] == lhs)
        .map(|e| &e["rhs"])
        .unwrap_or_else(|| panic!("no equation for {lhs}"))
}

#[test]
fn pow_alias_loads_as_caret() {
    let doc = emitted("conformance/scalar_operator_semantics/fixtures/pow_alias.esm");
    assert_eq!(
        rhs_of(&doc, "PowAlias", "pow_power"),
        &serde_json::json!({"op": "^", "args": ["two", 3]})
    );
    let mut tags = Vec::new();
    op_tags(&doc, &mut tags);
    assert!(!tags.iter().any(|t| t == "pow" || t == "neg"), "{tags:?}");
}

#[test]
fn negated_observed_loads_as_unary_minus() {
    let doc =
        emitted("conformance/scalar_operator_semantics/fixtures/scalar_operator_semantics.esm");
    assert_eq!(
        rhs_of(&doc, "Ops", "negated"),
        &serde_json::json!({"op": "-", "args": ["four"]})
    );
    let mut tags = Vec::new();
    op_tags(&doc, &mut tags);
    assert!(!tags.iter().any(|t| t == "pow" || t == "neg"), "{tags:?}");
}

#[test]
fn broadcast_fn_neg_loads_as_minus() {
    let doc = emitted("fixtures/faq/27_broadcast_unary.esm");
    let mut tags = Vec::new();
    op_tags(&doc, &mut tags);
    assert!(!tags.iter().any(|t| t == "neg"), "{tags:?}");
    assert!(tags.iter().filter(|t| *t == "-").count() >= 2, "{tags:?}");
}

/// A `neg` with two operands is NOT rewritten to binary `-` (which would
/// silently mean subtraction): it stays `neg`, and building the model refuses
/// it with the arity error it always had.
#[test]
fn wrong_arity_neg_is_left_alone_and_refused() {
    let json = r#"{
      "esm": "2.0.0",
      "metadata": {"name": "bad_neg"},
      "models": {"M": {
        "variables": {
          "x": {"type": "unknown", "units": "1", "default": 0.0},
          "a": {"type": "parameter", "units": "1", "default": 1.0},
          "b": {"type": "parameter", "units": "1", "default": 2.0}
        },
        "equations": [{
          "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
          "rhs": {"op": "neg", "args": ["a", "b"]}
        }]
      }}
    }"#;
    let file = earthsci_ast::load_string(json).expect("loads; arity is a build check");
    let doc: Value =
        serde_json::from_str(&earthsci_ast::to_json(&file).expect("emit")).expect("JSON");
    assert_eq!(
        doc["models"]["M"]["equations"][0]["rhs"]["op"], "neg",
        "must not become binary `-`"
    );
    #[cfg(feature = "solve")]
    {
        let built =
            earthsci_ast::esm_problem(&file, (0.0, 1.0), earthsci_ast::ProblemOptions::default());
        let Err(err) = built else {
            panic!("a two-operand neg must not build");
        };
        let msg = err.to_string();
        assert!(msg.contains("neg"), "{msg}");
    }
}
