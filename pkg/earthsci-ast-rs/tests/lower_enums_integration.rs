//! End-to-end load-time enum-lowering tests.
//!
//! Mirrors Python's `test_enums_lowered_to_const` and Julia's equivalent
//! coverage so that all three bindings agree on the §4.5 / §9.3 contract.

use earthsci_ast::*;
use serde_json::Value;

#[test]
fn enums_categorical_lookup_fixture_lowers_enum_ops() {
    let fixture = include_str!("../../../tests/valid/enums_categorical_lookup.esm");
    let file: EsmFile = load(fixture).expect("Failed to load enums_categorical_lookup fixture");

    let enums = file.enums.as_ref().expect("enums block should round-trip");
    assert_eq!(enums["season"]["summer"], 3);
    assert_eq!(enums["land_use_class"]["deciduous_forest"], 3);

    let model = file
        .models
        .as_ref()
        .expect("file should have models")
        .get("DryDep")
        .expect("DryDep model present");
    let r_c = model.variables.get("r_c").expect("r_c variable present");
    let expr = r_c.expression.as_ref().expect("r_c has expression");

    let Expr::Operator(node) = expr else {
        panic!("r_c expression must be an Operator node, got {expr:?}");
    };
    assert_eq!(node.op, "index");

    // args[1] (season) must have lowered to a `const` integer of value 3.
    let Expr::Operator(season_node) = &node.args[1] else {
        panic!("season arg must be an Operator node after lowering");
    };
    assert_eq!(season_node.op, "const");
    assert_eq!(season_node.value, Some(Value::Number(3.into())));

    // args[2] (land_use_class) must have lowered to a `const` integer of value 3.
    let Expr::Operator(lu_node) = &node.args[2] else {
        panic!("land_use_class arg must be an Operator node after lowering");
    };
    assert_eq!(lu_node.op, "const");
    assert_eq!(lu_node.value, Some(Value::Number(3.into())));
}

#[test]
fn enums_block_round_trips_through_save_reload() {
    let fixture = include_str!("../../../tests/valid/enums_categorical_lookup.esm");
    let file: EsmFile = load(fixture).expect("load");
    let serialized = save(&file).expect("save");
    let reloaded: EsmFile = load(&serialized).expect("reload");
    assert_eq!(file.enums, reloaded.enums);
}

#[test]
fn unknown_enum_rejected_at_load() {
    let bad = r#"{
      "esm": "0.3.0",
      "metadata": {"name": "BadEnum"},
      "enums": {"season": {"summer": 3}},
      "models": {
        "M": {
          "variables": {
            "x": {
              "type": "observed",
              "expression": {"op": "enum", "args": ["weekday", "monday"]}
            }
          },
          "equations": []
        }
      }
    }"#;
    let err = load(bad).expect_err("expected unknown_enum diagnostic");
    let msg = format!("{err}");
    assert!(
        msg.contains("unknown_enum"),
        "diagnostic missing code: {msg}"
    );
}

#[test]
fn unknown_enum_symbol_rejected_at_load() {
    let bad = r#"{
      "esm": "0.3.0",
      "metadata": {"name": "BadEnumSym"},
      "enums": {"season": {"summer": 3}},
      "models": {
        "M": {
          "variables": {
            "x": {
              "type": "observed",
              "expression": {"op": "enum", "args": ["season", "winter"]}
            }
          },
          "equations": []
        }
      }
    }"#;
    let err = load(bad).expect_err("expected unknown_enum_symbol diagnostic");
    let msg = format!("{err}");
    assert!(
        msg.contains("unknown_enum_symbol"),
        "diagnostic missing code: {msg}"
    );
}
