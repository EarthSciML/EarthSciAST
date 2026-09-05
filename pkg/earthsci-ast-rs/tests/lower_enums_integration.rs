//! End-to-end load-time enum-lowering tests.
//!
//! Mirrors Python's `test_enums_lowered_to_const` and Julia's equivalent
//! coverage so that all three bindings agree on the §4.5 / §9.3 contract.

use earthsci_ast::*;
use serde_json::Value;

#[test]
fn enums_categorical_lookup_fixture_lowers_enum_ops() {
    let fixture = include_str!("../../../tests/valid/enums_categorical_lookup.esm");
    let file: EsmFile =
        load_string(fixture).expect("Failed to load enums_categorical_lookup fixture");

    let enums = file.enums.as_ref().expect("enums block should round-trip");
    assert_eq!(enums["season"]["summer"], 3);
    assert_eq!(enums["land_use_class"]["deciduous_forest"], 3);

    let model = file
        .models
        .as_ref()
        .expect("file should have models")
        .get("DryDep")
        .expect("DryDep model present");
    // `r_c` is an OBSERVED unknown; its defining expression is the RHS of the
    // bare-variable-LHS equation (esm-spec §6.3.1), not a field on the variable.
    let defs = earthsci_ast::observed_definitions(model);
    let expr = defs.get("r_c").expect("r_c has a defining equation");

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
    let file: EsmFile = load_string(fixture).expect("load");
    let serialized = to_json(&file).expect("save");
    let reloaded: EsmFile = load_string(&serialized).expect("reload");
    assert_eq!(file.enums, reloaded.enums);
}

#[test]
fn unknown_enum_rejected_at_load() {
    let bad = r#"
        {
          "esm": "1.0.0",
          "metadata": {
            "name": "BadEnum"
          },
          "enums": {
            "season": {
              "summer": 3
            }
          },
          "models": {
            "M": {
              "variables": {
                "x": {
                  "type": "unknown"
                }
              },
              "equations": [
                {
                  "lhs": "x",
                  "rhs": {
                    "op": "enum",
                    "args": [
                      "weekday",
                      "monday"
                    ]
                  }
                }
              ]
            }
          }
        }
        "#;
    let err = load_string(bad).expect_err("expected unknown_enum diagnostic");
    let msg = format!("{err}");
    assert!(
        msg.contains("unknown_enum"),
        "diagnostic missing code: {msg}"
    );
}

#[test]
fn unknown_enum_symbol_rejected_at_load() {
    let bad = r#"
        {
          "esm": "1.0.0",
          "metadata": {
            "name": "BadEnumSym"
          },
          "enums": {
            "season": {
              "summer": 3
            }
          },
          "models": {
            "M": {
              "variables": {
                "x": {
                  "type": "unknown"
                }
              },
              "equations": [
                {
                  "lhs": "x",
                  "rhs": {
                    "op": "enum",
                    "args": [
                      "season",
                      "winter"
                    ]
                  }
                }
              ]
            }
          }
        }
        "#;
    let err = load_string(bad).expect_err("expected unknown_enum_symbol diagnostic");
    let msg = format!("{err}");
    assert!(
        msg.contains("unknown_enum_symbol"),
        "diagnostic missing code: {msg}"
    );
}

/// An `enums` member may be ANY integer -- negative, zero or positive
/// (esm-spec §9.3, CONFORMANCE_SPEC §5.26). The `minimum: 1` this format used
/// to carry on `EnumDeclaration.additionalProperties` made a zero-valued
/// identifier unnameable, which is a real loss: MOVES's
/// `operatingmode.opModeID = 0` is Braking, an emitting mode with its own
/// rate, and `opmodepolprocassoc.polProcessID = -1` marks the drive-cycle
/// modes associated with no pollutant/process.
///
/// This pins BOTH halves: the document LOADS, and the members resolve to
/// exactly `0` and `-1` -- a binding that accepted the document but clamped
/// or dropped the sign would still be wrong.
#[test]
fn zero_and_negative_enum_members_load_and_resolve_to_themselves() {
    let fixture = include_str!("../../../tests/valid/enums_zero_and_negative.esm");
    let file: EsmFile = load_string(fixture).expect("a zero/negative enum member must load");

    let enums = file.enums.as_ref().expect("enums block should round-trip");
    assert_eq!(enums["operating_mode"]["Braking"], 0);
    assert_eq!(enums["pol_process"]["Unassociated"], -1);

    let model = file
        .models
        .as_ref()
        .expect("file should have models")
        .get("EnumsZeroAndNegative")
        .expect("EnumsZeroAndNegative model present");
    let defs = earthsci_ast::observed_definitions(model);
    let expr = defs.get("mode_code").expect("mode_code has a defining equation");
    let Expr::Operator(node) = expr else {
        panic!("mode_code expression must be an Operator node, got {expr:?}");
    };
    assert_eq!(node.op, "makearray");
    let values = node.values.as_ref().expect("makearray carries `values`");

    // values[0] — the zero-valued member, lowered to `const 0`.
    let Expr::Operator(zero_node) = &values[0] else {
        panic!("values[0] must be an Operator node after lowering");
    };
    assert_eq!(zero_node.op, "const");
    assert_eq!(zero_node.value, Some(Value::Number(0.into())));

    // values[1] — the negative member, lowered to `const -1`.
    let Expr::Operator(neg_node) = &values[1] else {
        panic!("values[1] must be an Operator node after lowering");
    };
    assert_eq!(neg_node.op, "const");
    assert_eq!(neg_node.value, Some(Value::Number((-1).into())));

    // values[2] — both read through ARITHMETIC: 0 + 10*1 + (-1) = 9. The
    // fixture's inline test asserts the evaluated 9; here we only pin that the
    // sub-nodes lowered, so a regression is localized to lowering.
    let Expr::Operator(sum_node) = &values[2] else {
        panic!("values[2] must be an Operator node after lowering");
    };
    assert_eq!(sum_node.op, "+");
}

/// The same file round-trips: a zero and a negative member survive
/// serialize → reload unchanged (a serializer that wrote `0` as absent, or
/// dropped a `-`, would be caught here).
#[test]
fn zero_and_negative_enum_members_round_trip() {
    let fixture = include_str!("../../../tests/valid/enums_zero_and_negative.esm");
    let file: EsmFile = load_string(fixture).expect("load");
    let serialized = to_json(&file).expect("save");
    let reloaded: EsmFile = load_string(&serialized).expect("reload");
    assert_eq!(file.enums, reloaded.enums);
    let enums = reloaded.enums.as_ref().expect("enums survive the round trip");
    assert_eq!(enums["operating_mode"]["Braking"], 0);
    assert_eq!(enums["pol_process"]["Unassociated"], -1);
}
