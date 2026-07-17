//! Integration tests for the `variable_map.transform` expression widening
//! (esm-spec §10.4, v0.8.0): a coupling `variable_map`'s `transform` may be an
//! Expression operator node instead of one of the legacy named strings. The
//! flattener then removes the target parameter and re-declares it as an
//! observed defined by the transform expression VERBATIM — identical to the
//! author having declared the target as an observed.
//!
//! Mirrors the Julia / Python reference semantics: serde round-trip, the
//! factor+expression rejection, the `from`-reference contract, load-time
//! template expansion against the RECEIVING component's registry, and the
//! end-to-end simulate path.

use earthsci_ast::types::{
    CouplingEntry, Equation, EsmFile, Expr, ExpressionNode, Metadata, Model, ModelVariable,
    VariableMapTransform, VariableType,
};
use earthsci_ast::{FlattenError, flatten, validate};
use serde_json::json;
use std::collections::HashMap;

// ============================================================================
// Test helpers
// ============================================================================

fn empty_metadata() -> Metadata {
    Metadata {
        name: None,
        description: None,
        authors: None,
        license: None,
        created: None,
        modified: None,
        tags: None,
        references: None,
        system_class: None,
        dae_info: None,
        discretized_from: None,
    }
}

fn empty_file() -> EsmFile {
    EsmFile {
        expression_templates: None,
        metaparameters: None,
        coupling_roles: None,
        domain: None,
        index_sets: None,
        esm: "0.8.0".to_string(),
        metadata: empty_metadata(),
        models: None,
        reaction_systems: None,
        data_loaders: None,
        operators: None,
        enums: None,
        coupling: None,
        function_tables: None,
    }
}

fn model_variable(var_type: VariableType, default: Option<f64>) -> ModelVariable {
    ModelVariable {
        default_units: None,
        var_type,
        units: None,
        default,
        description: None,
        expression: None,
        shape: None,
        location: None,
        noise_kind: None,
        correlation_group: None,
    }
}

fn make_model(variables: HashMap<String, ModelVariable>, equations: Vec<Equation>) -> Model {
    Model {
        subsystems: None,
        name: None,
        reference: None,
        variables,
        equations,
        discrete_events: None,
        continuous_events: None,
        description: None,
        tolerance: None,
        tests: None,
        initialization_equations: None,
        guesses: None,
        system_kind: None,
    }
}

fn ddt(var: &str) -> Expr {
    Expr::Operator(ExpressionNode {
        op: "D".to_string(),
        args: vec![Expr::Variable(var.to_string())],
        wrt: Some("t".to_string()),
        ..Default::default()
    })
}

/// The canonical expression transform used throughout:
/// `2.0 * Src.F + Sink.offset`.
fn transform_node() -> ExpressionNode {
    ExpressionNode {
        op: "+".to_string(),
        args: vec![
            Expr::Operator(ExpressionNode {
                op: "*".to_string(),
                args: vec![Expr::Number(2.0), Expr::Variable("Src.F".to_string())],
                ..Default::default()
            }),
            Expr::Variable("Sink.offset".to_string()),
        ],
        ..Default::default()
    }
}

/// The tiny scalar fixture: `Src` has observed `F = 4.0`; `Sink` has
/// parameters `offset` (default 1.5) and `F_in` (with units / description
/// metadata to verify carry-over), and state `u` with `d(u)/dt = F_in`;
/// coupling maps `Src.F -> Sink.F_in` via the given transform.
fn expression_transform_fixture(transform: VariableMapTransform, factor: Option<f64>) -> EsmFile {
    let mut vars_src = HashMap::new();
    let mut f = model_variable(VariableType::Observed, None);
    f.expression = Some(Expr::Number(4.0));
    vars_src.insert("F".to_string(), f);

    let mut vars_sink = HashMap::new();
    vars_sink.insert(
        "offset".to_string(),
        model_variable(VariableType::Parameter, Some(1.5)),
    );
    let mut f_in = model_variable(VariableType::Parameter, None);
    f_in.units = Some("kg/s".to_string());
    f_in.description = Some("coupled inflow".to_string());
    vars_sink.insert("F_in".to_string(), f_in);
    vars_sink.insert(
        "u".to_string(),
        model_variable(VariableType::State, Some(0.0)),
    );

    let mut models = HashMap::new();
    models.insert("Src".to_string(), make_model(vars_src, vec![]));
    models.insert(
        "Sink".to_string(),
        make_model(
            vars_sink,
            vec![Equation {
                lhs: ddt("u"),
                rhs: Expr::Variable("F_in".to_string()),
            }],
        ),
    );

    EsmFile {
        coupling_roles: None,
        models: Some(models),
        coupling: Some(vec![CouplingEntry::VariableMap {
            from: "Src.F".to_string(),
            to: "Sink.F_in".to_string(),
            transform,
            factor,
            description: None,
        }]),
        ..empty_file()
    }
}

/// Recursively collect every variable name in an expression tree.
fn collect_vars(expr: &Expr, out: &mut Vec<String>) {
    match expr {
        Expr::Variable(n) => out.push(n.clone()),
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Operator(node) => {
            for a in &node.args {
                collect_vars(a, out);
            }
        }
    }
}

// ============================================================================
// (1) Serde: string -> Named, object -> Expression, lossless round-trip
// ============================================================================

#[test]
fn variable_map_expression_transform_serde_round_trip() {
    let entry_json = json!({
        "type": "variable_map",
        "from": "Src.F",
        "to": "Sink.F_in",
        "transform": {"op": "+", "args": [{"op": "*", "args": [2.0, "Src.F"]}, "Sink.offset"]}
    });

    let entry: CouplingEntry = serde_json::from_value(entry_json.clone()).unwrap();
    match &entry {
        CouplingEntry::VariableMap { transform, .. } => {
            let node = transform
                .as_expression()
                .expect("object transform must deserialize to the Expression arm");
            assert_eq!(node.op, "+");
            assert!(transform.is_expression());
            assert_eq!(transform.as_named(), None);
        }
        _ => panic!("Expected VariableMap variant"),
    }

    // Canonical round-trip: the transform structure round-trips, and the
    // integral float coefficient `2.0` canonicalizes to the integer `2`
    // (§5.5.3.1), matching the JS/Julia/Python bindings. Compare against the
    // canonical expected value rather than the raw `2.0` input.
    let expected_canonical = json!({
        "type": "variable_map",
        "from": "Src.F",
        "to": "Sink.F_in",
        "transform": {"op": "+", "args": [{"op": "*", "args": [2, "Src.F"]}, "Sink.offset"]}
    });
    let back = serde_json::to_value(&entry).unwrap();
    assert_eq!(back, expected_canonical);
}

#[test]
fn variable_map_named_transform_serde_round_trip() {
    let entry_json = json!({
        "type": "variable_map",
        "from": "Src.F",
        "to": "Sink.F_in",
        "transform": "param_to_var"
    });
    let entry: CouplingEntry = serde_json::from_value(entry_json.clone()).unwrap();
    match &entry {
        CouplingEntry::VariableMap { transform, .. } => {
            assert_eq!(transform.as_named(), Some("param_to_var"));
        }
        _ => panic!("Expected VariableMap variant"),
    }
    let back = serde_json::to_value(&entry).unwrap();
    assert_eq!(back, entry_json);
}

#[test]
fn variable_map_transform_rejects_bare_number() {
    // Expression transforms are always operator-node OBJECTS; a bare number
    // is neither a named transform nor an admissible Expression spelling.
    let entry_json = json!({
        "type": "variable_map",
        "from": "Src.F",
        "to": "Sink.F_in",
        "transform": 2.0
    });
    assert!(serde_json::from_value::<CouplingEntry>(entry_json).is_err());
}

// ============================================================================
// (2) factor + expression transform is rejected
// ============================================================================

#[test]
fn factor_with_expression_transform_rejected_by_validate() {
    let file = expression_transform_fixture(
        VariableMapTransform::Expression(transform_node()),
        Some(3.0),
    );
    let result = validate(&file);
    assert!(!result.is_valid);
    let err = result
        .structural_errors
        .iter()
        .find(|e| e.code.to_string() == "factor_with_expression_transform")
        .expect("expected a factor_with_expression_transform structural error");
    assert!(err.message.contains("takes no `factor`"), "{}", err.message);
    assert_eq!(err.path, "/coupling/0");
}

#[test]
fn factor_with_expression_transform_rejected_by_flatten() {
    let file = expression_transform_fixture(
        VariableMapTransform::Expression(transform_node()),
        Some(3.0),
    );
    let err = flatten(&file).expect_err("flatten must reject factor + expression transform");
    match err {
        FlattenError::VariableMapFactorWithExpression { from, to } => {
            assert_eq!(from, "Src.F");
            assert_eq!(to, "Sink.F_in");
        }
        other => panic!("expected VariableMapFactorWithExpression, got {other:?}"),
    }
}

#[test]
fn factor_with_expression_transform_rejected_by_load() {
    // The embedded schema's allOf guard restricts `factor` to the scaling
    // NAMED transforms, so an object-valued transform alongside `factor`
    // fails schema validation inside `load`.
    let doc = json!({
        "esm": "0.8.0",
        "metadata": {"name": "factor_expr_reject", "authors": ["t"]},
        "models": {
            "Src": {"variables": {"F": {"type": "observed", "expression": 4.0}}, "equations": []},
            "Sink": {
                "variables": {
                    "offset": {"type": "parameter", "default": 1.5},
                    "F_in": {"type": "parameter"},
                    "u": {"type": "state", "default": 0.0}
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": "F_in"}
                ]
            }
        },
        "coupling": [{
            "type": "variable_map",
            "from": "Src.F",
            "to": "Sink.F_in",
            "transform": {"op": "+", "args": [{"op": "*", "args": [2.0, "Src.F"]}, "Sink.offset"]},
            "factor": 3.0
        }]
    });
    let err = earthsci_ast::load(&doc.to_string())
        .expect_err("load must reject factor + expression transform");
    let msg = format!("{err}");
    assert!(
        msg.to_lowercase().contains("schema") || msg.contains("transform"),
        "unexpected error: {msg}"
    );
}

// ============================================================================
// (3) Flatten: expression transform -> observed, parameter removed
// ============================================================================

#[test]
fn flatten_expression_transform_creates_observed_and_removes_parameter() {
    let node = transform_node();
    let file = expression_transform_fixture(VariableMapTransform::Expression(node.clone()), None);
    let flat = flatten(&file).unwrap();

    // The target parameter is promoted out of the flattened parameters.
    assert!(!flat.parameters.contains_key("Sink.F_in"));
    // `Sink.offset` is untouched.
    assert!(flat.parameters.contains_key("Sink.offset"));

    // An observed named exactly `Sink.F_in` exists, defined by the transform
    // expression VERBATIM (fully-scoped references, no namespacing).
    let obs = flat
        .observed_variables
        .get("Sink.F_in")
        .expect("expected observed Sink.F_in");
    assert_eq!(obs.var_type, VariableType::Observed);
    assert_eq!(obs.expression, Some(Expr::Operator(node)));
    // Units / description metadata carry over from the removed parameter.
    assert_eq!(obs.units.as_deref(), Some("kg/s"));
    assert_eq!(obs.description.as_deref(), Some("coupled inflow"));

    // The state equation still references Sink.F_in — NOT substituted; it now
    // resolves to the observed.
    let u_eq = flat
        .equations
        .iter()
        .find(|eq| {
            matches!(&eq.lhs,
                Expr::Operator(n) if n.op == "D"
                    && matches!(&n.args[0], Expr::Variable(v) if v == "Sink.u"))
        })
        .expect("expected equation for Sink.u");
    let mut vs = Vec::new();
    collect_vars(&u_eq.rhs, &mut vs);
    assert_eq!(vs, vec!["Sink.F_in".to_string()]);

    // Provenance names the expression transform.
    assert!(
        flat.metadata
            .coupling_rules_applied
            .iter()
            .any(|r| r.contains("variable_map(Src.F -> Sink.F_in, expression)")),
        "rules applied: {:?}",
        flat.metadata.coupling_rules_applied
    );
}

#[test]
fn flatten_expression_transform_missing_from_reference_errors() {
    // The transform references only Sink.offset — never the entry's `from`
    // variable Src.F — so flattening must fail.
    let node = ExpressionNode {
        op: "*".to_string(),
        args: vec![Expr::Number(2.0), Expr::Variable("Sink.offset".to_string())],
        ..Default::default()
    };
    let file = expression_transform_fixture(VariableMapTransform::Expression(node), None);
    let err = flatten(&file).expect_err("flatten must reject a transform that ignores `from`");
    match err {
        FlattenError::VariableMapExpressionMissingFrom { from, to } => {
            assert_eq!(from, "Src.F");
            assert_eq!(to, "Sink.F_in");
        }
        other => panic!("expected VariableMapExpressionMissingFrom, got {other:?}"),
    }
    let msg = format!(
        "{}",
        FlattenError::VariableMapExpressionMissingFrom {
            from: "Src.F".to_string(),
            to: "Sink.F_in".to_string(),
        }
    );
    assert!(msg.contains("Src.F") && msg.contains("Sink.F_in"), "{msg}");
}

// ============================================================================
// (4) Load-time template expansion in coupling transforms
// ============================================================================

#[test]
fn lower_templates_expands_coupling_transform_against_receiving_component() {
    let mut doc = json!({
        "esm": "0.8.0",
        "metadata": {"name": "coupling_transform_templates", "authors": ["t"]},
        "models": {
            "Src": {
                "variables": {"F": {"type": "observed", "expression": 4.0}},
                "equations": []
            },
            "Sink": {
                "variables": {
                    "offset": {"type": "parameter", "default": 1.5},
                    "F_in": {"type": "parameter"},
                    "u": {"type": "state", "default": 0.0}
                },
                "expression_templates": {
                    "double_plus": {
                        "params": ["x", "off"],
                        "body": {"op": "+", "args": [{"op": "*", "args": [2.0, "x"]}, "off"]}
                    }
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": "F_in"}
                ]
            }
        },
        "coupling": [{
            "type": "variable_map",
            "from": "Src.F",
            "to": "Sink.F_in",
            "transform": {
                "op": "apply_expression_template",
                "name": "double_plus",
                "args": [],
                "bindings": {"x": "Src.F", "off": "Sink.offset"}
            }
        }]
    });

    earthsci_ast::lower_expression_templates::lower_expression_templates(&mut doc)
        .expect("template expansion");
    // Option B: `double_plus`'s body is pure evaluable-core, so the transform
    // reference SURVIVES load; `expand` produces the Option-A image the build
    // path sees (RFC out-of-line-expression-templates §7.7).
    earthsci_ast::lower_expression_templates::expand(&mut doc).expect("expand");

    // The transform is rewritten against the RECEIVING component (`Sink`, the
    // first dot-segment of `to`) to the expanded AST.
    assert_eq!(
        doc["coupling"][0]["transform"],
        json!({"op": "+", "args": [{"op": "*", "args": [2.0, "Src.F"]}, "Sink.offset"]})
    );
    // The receiving component's templates block is stripped by `expand`.
    assert!(doc["models"]["Sink"].get("expression_templates").is_none());
}

#[test]
fn lower_templates_leaves_apply_free_coupling_transform_untouched() {
    // The receiving component has no expression_templates block and the
    // transform contains no apply nodes: the pass must leave it unrewritten
    // and must NOT raise a "component lacking expression_templates" error.
    let transform =
        json!({"op": "+", "args": [{"op": "*", "args": [2.0, "Src.F"]}, "Sink.offset"]});
    let mut doc = json!({
        "esm": "0.8.0",
        "metadata": {"name": "no_templates_coupling", "authors": ["t"]},
        "models": {
            "Src": {
                "variables": {"F": {"type": "observed", "expression": 4.0}},
                // Give Src a template so the pass has machinery to run — the
                // RECEIVING component (Sink) still has none.
                "expression_templates": {
                    "quadruple": {"params": ["x"], "body": {"op": "*", "args": [4.0, "x"]}}
                },
                "equations": []
            },
            "Sink": {
                "variables": {
                    "offset": {"type": "parameter", "default": 1.5},
                    "F_in": {"type": "parameter"},
                    "u": {"type": "state", "default": 0.0}
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": "F_in"}
                ]
            }
        },
        "coupling": [{
            "type": "variable_map",
            "from": "Src.F",
            "to": "Sink.F_in",
            "transform": transform.clone()
        }]
    });

    earthsci_ast::lower_expression_templates::lower_expression_templates(&mut doc)
        .expect("apply-free transform must not error");
    assert_eq!(doc["coupling"][0]["transform"], transform);
}

// ============================================================================
// (5) End-to-end: flatten -> compile -> simulate
// ============================================================================

/// `d(u)/dt = Sink.F_in` where `Sink.F_in` is the flattened observed
/// `2 * Src.F + Sink.offset = 2 * 4.0 + 1.5 = 9.5`, so `u(1) = 9.5`.
#[cfg(not(target_arch = "wasm32"))]
#[test]
fn simulate_variable_map_expression_transform_end_to_end() {
    use earthsci_ast::{SimulateOptions, simulate};

    let file =
        expression_transform_fixture(VariableMapTransform::Expression(transform_node()), None);

    let opts = SimulateOptions {
        output_times: Some(vec![0.0, 1.0]),
        ..Default::default()
    };
    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
        .expect("simulate failed");

    assert_eq!(sol.state_variable_names, vec!["Sink.u".to_string()]);
    let last = sol.time.len() - 1;
    let u_final = sol.state[0][last];
    let expected = 9.5;
    let rel_err = (u_final - expected).abs() / expected;
    assert!(
        rel_err < 1e-6,
        "u(1) = {u_final}, expected {expected} (rel err {rel_err})"
    );
}
