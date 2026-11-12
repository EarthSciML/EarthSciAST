//! Variable bounds, `lb` / `ub` on a model variable (esm-spec §6.3.2):
//! round-trip, the four `validate` rules, the esm 2.1.0 version gate, and
//! flattening's renaming of a reference bound (esm-libraries-spec §4.7.5).

use earthsci_ast::{
    EsmFile, StructuralError, VariableBound, flatten, load_path, load_string, to_json, validate,
};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

fn tests_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests")
}

fn read(rel: &str) -> String {
    std::fs::read_to_string(tests_dir().join(rel)).unwrap_or_else(|e| panic!("read {rel}: {e}"))
}

fn errors_of(file: &EsmFile) -> Vec<StructuralError> {
    validate(file).structural_errors
}

/// The `lb` / `ub` of every variable of every model and subsystem, keyed by
/// the variable's JSON pointer.
fn bounds_in(doc: &Value) -> Vec<(String, Value)> {
    fn walk(component: &Value, pointer: &str, out: &mut Vec<(String, Value)>) {
        if let Some(vars) = component.get("variables").and_then(Value::as_object) {
            for (name, var) in vars {
                for key in ["lb", "ub"] {
                    if let Some(b) = var.get(key) {
                        out.push((format!("{pointer}/variables/{name}/{key}"), b.clone()));
                    }
                }
            }
        }
        if let Some(subs) = component.get("subsystems").and_then(Value::as_object) {
            for (name, sub) in subs {
                walk(sub, &format!("{pointer}/subsystems/{name}"), out);
            }
        }
    }
    let mut out = Vec::new();
    for (name, model) in doc["models"].as_object().unwrap() {
        walk(model, &format!("/models/{name}"), &mut out);
    }
    out
}

#[test]
fn valid_fixtures_round_trip_bounds_as_authored_and_validate() {
    for rel in [
        "valid/variable_bounds.esm",
        "valid/variable_bounds_shaped.esm",
        "valid/variable_bounds_coupled.esm",
        "version_compatibility/version_2_1_0_variable_bounds.esm",
    ] {
        let text = read(rel);
        let authored: Value = serde_json::from_str(&text).unwrap();
        let file = load_string(&text).unwrap_or_else(|e| panic!("{rel} must load: {e}"));
        let errs = errors_of(&file);
        assert!(errs.is_empty(), "{rel}: {errs:?}");
        let emitted: Value = serde_json::from_str(&to_json(&file).unwrap()).unwrap();
        let want = bounds_in(&authored);
        assert!(!want.is_empty(), "{rel} carries bounds");
        // Compared as serialized TEXT, so `0` must not come back as `0.0`.
        assert_eq!(
            format!("{:?}", bounds_in(&emitted)),
            format!("{want:?}"),
            "{rel}"
        );
    }
}

#[test]
fn a_number_bound_keeps_its_spelling_and_an_absent_bound_is_not_written() {
    let text = read("valid/variable_bounds.esm");
    let file = load_string(&text).unwrap();
    let emitted = to_json(&file).unwrap();
    assert!(emitted.contains("\"lb\": 0,") || emitted.contains("\"lb\":0,"));
    let doc: Value = serde_json::from_str(&emitted).unwrap();
    for (_, var) in doc["models"]["Salts"]["variables"].as_object().unwrap() {
        if let Some(lb) = var.get("lb") {
            assert!(!lb.is_null());
        }
        if let Some(ub) = var.get("ub") {
            assert!(!ub.is_null());
        }
    }
}

/// Every shared invalid fixture reports exactly the error pinned in
/// `tests/invalid/expected_errors.json`: code, pointer and details.
#[test]
fn shared_invalid_fixtures_match_expected_errors() {
    let expected: Value = serde_json::from_str(&read("invalid/expected_errors.json")).unwrap();
    for name in [
        "variable_bound_unresolved.esm",
        "variable_bound_shape_mismatch.esm",
        "variable_bound_shape_mismatch_axes.esm",
        "variable_bound_circular_self.esm",
        "variable_bound_circular_observed.esm",
        "variable_bounds_inverted.esm",
    ] {
        let entry = &expected[name];
        let file = load_path(tests_dir().join("invalid").join(name))
            .unwrap_or_else(|e| panic!("{name} must load (schema_errors: []): {e}"));
        let got = errors_of(&file);
        let want = entry["structural_errors"].as_array().unwrap();
        assert_eq!(got.len(), want.len(), "{name}: {got:?}");
        for (g, w) in got.iter().zip(want) {
            assert_eq!(g.code.to_string(), w["code"].as_str().unwrap(), "{name}");
            assert_eq!(g.path, w["path"].as_str().unwrap(), "{name}");
            assert_eq!(g.details, w["details"], "{name}");
        }
    }
}

#[test]
fn version_gate_rejects_bounds_below_2_1_0() {
    let err = load_path(tests_dir().join("invalid/variable_bounds_version_too_old.esm"))
        .expect_err("a 2.0.0 document with bounds is refused");
    let msg = err.to_string();
    assert!(msg.contains("[variable_bounds_version_too_old]"), "{msg}");
    assert!(msg.contains("/models/M/variables/x/lb"), "{msg}");
}

fn doc(esm: &str, models: Value) -> String {
    json!({"esm": esm, "metadata": {"name": "B"}, "models": models}).to_string()
}

fn decay(var: &str) -> Value {
    json!({"lhs": {"op": "D", "args": [var], "wrt": "t"}, "rhs": {"op": "-", "args": [var]}})
}

#[test]
fn version_gate_points_at_a_subsystem_and_spares_bound_free_documents() {
    let models = json!({"M": {
        "variables": {"x": {"type": "unknown", "default": 1.0}},
        "equations": [decay("x")],
        "subsystems": {"S": {
            "variables": {"y": {"type": "unknown", "default": 1.0, "ub": 2}},
            "equations": [decay("y")]
        }}
    }});
    let err = load_string(&doc("1.3.0", models.clone())).expect_err("1.3.0 refused");
    let msg = err.to_string();
    assert!(msg.contains("[variable_bounds_version_too_old]"), "{msg}");
    assert!(
        msg.contains("/models/M/subsystems/S/variables/y/ub"),
        "{msg}"
    );
    load_string(&doc("2.1.0", models)).expect("2.1.0 loads");

    let bare = json!({"M": {"variables": {"x": {"type": "unknown", "default": 1.0}},
        "equations": [decay("x")]}});
    load_string(&doc("2.0.0", bare)).expect("2.0.0 without bounds loads");
}

/// A 2.0.0 document may mount a 2.1.0 file that carries bounds: each file is
/// held to its own declared version (esm-spec §4.7).
#[test]
fn version_gate_reads_each_files_own_version() {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("variable_bounds_mount");
    std::fs::create_dir_all(&dir).unwrap();
    let leaf = doc(
        "2.1.0",
        json!({"Leaf": {"variables": {"y": {"type": "unknown", "default": 1.0, "lb": 0}},
            "equations": [decay("y")]}}),
    );
    std::fs::write(dir.join("leaf.esm"), &leaf).unwrap();
    let root = doc(
        "2.0.0",
        json!({"M": {"variables": {"x": {"type": "unknown", "default": 1.0}},
            "equations": [decay("x")],
            "subsystems": {"L": {"ref": "./leaf.esm"}}}}),
    );
    std::fs::write(dir.join("root.esm"), &root).unwrap();
    let loaded =
        load_path(dir.join("root.esm")).expect("a 2.0.0 root mounts a 2.1.0 leaf with bounds");
    // The resolved document now holds the leaf's bounds, so emit raises its
    // declared version to 2.1.0 and the emitted bytes load again.
    let emitted = to_json(&loaded).unwrap();
    let reloaded = load_string(&emitted).expect("the emitted resolved document reloads");
    assert_eq!(reloaded.esm, "2.1.0");
    assert_eq!(loaded.esm, "2.0.0", "emit does not change the loaded file");

    let old_leaf = leaf.replace("\"2.1.0\"", "\"2.0.0\"");
    std::fs::write(dir.join("leaf.esm"), &old_leaf).unwrap();
    let root_new = root.replace("\"2.0.0\"", "\"2.1.0\"");
    std::fs::write(dir.join("root.esm"), &root_new).unwrap();
    let err = load_path(dir.join("root.esm")).expect_err("a 2.0.0 leaf with bounds is refused");
    assert!(
        err.to_string().contains("variable_bounds_version_too_old"),
        "{err}"
    );
}

fn validate_models(models: Value) -> Vec<StructuralError> {
    let file = load_string(&doc("2.1.0", models)).expect("loads");
    errors_of(&file)
}

#[test]
fn rules_apply_inside_a_subsystem_with_its_pointer() {
    let errs = validate_models(json!({"M": {
        "variables": {"x": {"type": "unknown", "default": 1.0}},
        "equations": [decay("x")],
        "subsystems": {"S": {
            "variables": {
                "y": {"type": "unknown", "default": 1.0, "lb": "nope"},
                "z": {"type": "unknown", "default": 1.0, "lb": 3, "ub": 2},
                "w": {"type": "unknown", "default": 1.0, "ub": "w"}
            },
            "equations": [decay("y"), decay("z"), decay("w")]
        }}
    }}));
    let got: Vec<(String, String)> = errs
        .iter()
        .map(|e| (e.code.to_string(), e.path.clone()))
        .collect();
    assert_eq!(
        got,
        vec![
            (
                "undefined_variable".into(),
                "/models/M/subsystems/S/variables/y/lb".into()
            ),
            (
                "variable_bounds_inverted".into(),
                "/models/M/subsystems/S/variables/z".into()
            ),
            (
                "variable_bound_circular".into(),
                "/models/M/subsystems/S/variables/w/ub".into()
            ),
        ]
    );
    assert_eq!(errs[0].details, json!({"variable": "nope", "bound": "lb"}));
    assert_eq!(errs[1].details, json!({"variable": "z", "lb": 3, "ub": 2}));
}

#[test]
fn dotted_references_resolve_by_scope_precedence() {
    // `Sub.cap` is relative to M's own subsystem; `N.cap` is a top-level
    // path; a subsystem reaches its parent's sibling model by top-level path.
    let errs = validate_models(json!({
        "M": {
            "variables": {
                "x": {"type": "unknown", "default": 1.0, "lb": "Sub.cap", "ub": "N.cap"}
            },
            "equations": [decay("x")],
            "subsystems": {"Sub": {
                "variables": {
                    "cap": {"type": "parameter", "default": 2.0},
                    "y": {"type": "unknown", "default": 1.0, "ub": "N.cap"}
                },
                "equations": [decay("y")]
            }}
        },
        "N": {"variables": {"cap": {"type": "parameter", "default": 3.0}}, "equations": []}
    }));
    assert!(errs.is_empty(), "{errs:?}");

    let errs = validate_models(json!({
        "M": {
            "variables": {"x": {"type": "unknown", "default": 1.0, "ub": "Sub.missing"}},
            "equations": [decay("x")],
            "subsystems": {"Sub": {"variables": {}, "equations": []}}
        }
    }));
    assert_eq!(errs.len(), 1, "{errs:?}");
    assert_eq!(errs[0].code.to_string(), "undefined_variable");
    assert_eq!(errs[0].path, "/models/M/variables/x/ub");
}

#[test]
fn a_dotted_reference_into_a_shaped_variable_checks_its_shape() {
    let file = load_string(
        &json!({
            "esm": "2.1.0",
            "metadata": {"name": "B"},
            "index_sets": {"salt": {"kind": "interval", "size": 2}},
            "models": {
                "M": {
                    "variables": {"x": {"type": "unknown", "default": 1.0, "ub": "N.cap"}},
                    "equations": [decay("x")]
                },
                "N": {"variables": {"cap": {"type": "parameter", "shape": ["salt"],
                    "default": [1.0, 2.0]}}, "equations": []}
            }
        })
        .to_string(),
    )
    .expect("loads");
    let errs: Vec<_> = errors_of(&file)
        .into_iter()
        .filter(|e| e.path.contains("/ub"))
        .collect();
    assert_eq!(errs.len(), 1, "{errs:?}");
    assert_eq!(errs[0].code.to_string(), "variable_bound_shape_mismatch");
    assert_eq!(
        errs[0].details,
        json!({"variable": "x", "bound": "ub", "reference": "N.cap"})
    );
}

/// An observed bound is legal when its definition reaches some OTHER state,
/// and the walk stops at a state rather than following its equation.
#[test]
fn an_observed_bound_depending_on_another_state_is_legal() {
    let errs = validate_models(json!({"M": {
        "variables": {
            "x": {"type": "unknown", "default": 1.0, "ub": "a"},
            "y": {"type": "unknown", "default": 1.0},
            "a": {"type": "unknown"},
            "b": {"type": "unknown"}
        },
        "equations": [
            decay("x"),
            // y's derivative reads x; the walk does not follow a state.
            {"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": {"op": "-", "args": ["x"]}},
            {"lhs": "a", "rhs": {"op": "*", "args": [2, "b"]}},
            {"lhs": "b", "rhs": {"op": "+", "args": ["y", 1]}}
        ]
    }}));
    assert!(errs.is_empty(), "{errs:?}");
}

#[test]
fn equal_numeric_bounds_are_legal() {
    let errs = validate_models(json!({"M": {
        "variables": {"x": {"type": "unknown", "default": 1.0, "lb": 1, "ub": 1.0}},
        "equations": [decay("x")]
    }}));
    assert!(errs.is_empty(), "{errs:?}");
}

#[test]
fn flatten_renames_reference_bounds() {
    let file = load_path(tests_dir().join("valid/variable_bounds_coupled.esm")).expect("loads");
    let flat = flatten(&file).expect("flattens");
    let var = |name: &str| {
        flat.state_variables
            .get(name)
            .or_else(|| flat.parameters.get(name))
            .or_else(|| flat.observed_variables.get(name))
            .unwrap_or_else(|| panic!("{name} in the flattened system"))
            .clone()
    };
    let r = |s: &str| Some(VariableBound::Reference(s.to_string()));
    let n = |v: u64| Some(VariableBound::Number(v.into()));
    let x = var("Chem.x");
    assert_eq!((x.lb, x.ub), (r("Chem.x_min"), r("Met.cap_src")));
    let z = var("Chem.z");
    assert_eq!((z.lb, z.ub), (n(0), r("Chem.Sub.y")));
    let y = var("Chem.Sub.y");
    assert_eq!((y.lb, y.ub), (n(0), r("Chem.Sub.y_cap")));
    let cap = var("Met.cap_src");
    assert_eq!((cap.lb, cap.ub), (n(0), None));
    assert!(
        flat.parameters.get("Chem.x_cap").is_none(),
        "the variable_map target leaves the flattened system"
    );
}

/// A scaled `variable_map` leaves the replacement expression as the bound.
#[test]
fn a_scaled_replacement_leaves_an_expression_bound() {
    let file = load_string(
        &json!({
            "esm": "2.1.0",
            "metadata": {"name": "B"},
            "models": {
                "A": {"variables": {
                        "x": {"type": "unknown", "default": 1.0, "ub": "cap"},
                        "cap": {"type": "parameter", "default": 1.0}
                    },
                    "equations": [decay("x")]},
                "Src": {"variables": {"c": {"type": "parameter", "default": 2.0}},
                    "equations": []}
            },
            "coupling": [{"type": "variable_map", "from": "Src.c", "to": "A.cap",
                "transform": "multiplicative", "factor": 2.0}]
        })
        .to_string(),
    )
    .expect("loads");
    let flat = flatten(&file).expect("flattens");
    let ub = flat.state_variables["A.x"].ub.clone().expect("ub carried");
    match ub {
        VariableBound::Expression(e) => {
            assert_eq!(earthsci_ast::to_ascii(&e).replace(' ', ""), "2*Src.c")
        }
        other => panic!("expected an expression bound, got {other:?}"),
    }
}
