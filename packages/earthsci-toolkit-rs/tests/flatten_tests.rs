//! Spec §4.7.5 + §4.7.6 Core tier (broadcast + identity) integration tests
//! for [`earthsci_toolkit::flatten`].
//!
//! Paralleling the Julia `gt-xnr` and Python `gt-268` test suites so that
//! equivalent scenarios exercise the same algorithmic path in every
//! language. Scope limits (no PDE, no slice/project/regrid) match the bead
//! `gt-v8v` acceptance criteria — those cases raise
//! `FlattenError::UnsupportedMapping`.

use earthsci_toolkit::types::{
    CouplingEntry, Equation, EsmFile, Expr, ExpressionNode, Metadata, Model, ModelVariable,
    Parameter, Reaction, ReactionSystem, Species, StoichiometricEntry, VariableType,
};
use earthsci_toolkit::{FlattenError, flatten, flatten_model};
use std::collections::HashMap;

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
        esm: "0.1.0".to_string(),
        metadata: empty_metadata(),
        models: None,
        reaction_systems: None,
        data_loaders: None,
        operators: None,
        enums: None,

        coupling: None,
        domains: None,
        interfaces: None,
        grids: None,
        staggering_rules: None,
        discretizations: None,
        function_tables: None,
    }
}

fn ddt(var: &str) -> Expr {
    Expr::Operator(ExpressionNode {
        op: "D".to_string(),
        args: vec![Expr::Variable(var.to_string())],
        wrt: Some("t".to_string()),
        dim: None,
        ..Default::default()
    })
}

fn var(name: &str) -> Expr {
    Expr::Variable(name.to_string())
}

/// Recursively collect every variable name in an expression tree — test
/// helper so assertions can check "this rhs mentions x.foo" without caring
/// about tree shape.
fn collect_vars(expr: &Expr, out: &mut Vec<String>) {
    match expr {
        Expr::Variable(n) => out.push(n.clone()),
        Expr::Number(_) => {}
        Expr::Integer(_) => {}
        Expr::Operator(node) => {
            for a in &node.args {
                collect_vars(a, out);
            }
        }
    }
}

fn rhs_vars(eq: &Equation) -> Vec<String> {
    let mut out = Vec::new();
    collect_vars(&eq.rhs, &mut out);
    out
}

/// Build a reaction system for quick test fixtures.
fn reaction_system(
    species: Vec<(&str, Option<f64>)>,
    params: Vec<(&str, Option<f64>)>,
    reactions: Vec<Reaction>,
) -> ReactionSystem {
    let species = species
        .into_iter()
        .map(|(n, d)| {
            (
                n.to_string(),
                Species {
                    units: None,
                    default: d,
                    description: None,
                    constant: None,
                },
            )
        })
        .collect::<HashMap<_, _>>();
    let mut parameters = HashMap::new();
    for (name, default) in params {
        parameters.insert(
            name.to_string(),
            Parameter {
                units: None,
                default,
                description: None,
            },
        );
    }
    ReactionSystem {
        domain: None,
        coupletype: None,
        reference: None,
        species,
        parameters,
        reactions,
        constraint_equations: None,
        discrete_events: None,
        continuous_events: None,
        subsystems: None,
    }
}

fn stoich(name: &str, coeff: f64) -> StoichiometricEntry {
    StoichiometricEntry {
        species: name.to_string(),
        coefficient: coeff,
    }
}

// ============================================================================
// (1) flatten a reactions-only Model → mass-action ODEs per species
// ============================================================================
#[test]
fn flatten_reactions_only_file_produces_mass_action_odes() {
    let rs = reaction_system(
        vec![("A", Some(1.0)), ("B", Some(0.0))],
        vec![("k1", Some(0.1))],
        vec![Reaction {
            id: None,
            name: Some("r1".to_string()),
            substrates: Some(vec![stoich("A", 1.0)]),
            products: Some(vec![stoich("B", 1.0)]),
            rate: var("k1"),
            reference: None,
        }],
    );

    let mut reaction_systems = HashMap::new();
    reaction_systems.insert("chem".to_string(), rs);

    let file = EsmFile {
        reaction_systems: Some(reaction_systems),
        ..empty_file()
    };

    let flat = flatten(&file).unwrap();

    assert!(flat.state_variables.contains_key("chem.A"));
    assert!(flat.state_variables.contains_key("chem.B"));
    assert!(flat.parameters.contains_key("chem.k1"));

    // Two ODE equations — one per species.
    assert_eq!(flat.equations.len(), 2);

    // Every RHS reference must be namespaced.
    for eq in &flat.equations {
        for v in rhs_vars(eq) {
            assert!(v.contains('.'), "RHS variable '{v}' was not namespaced");
        }
    }
    assert_eq!(flat.metadata.source_systems, vec!["chem".to_string()]);
}

// ============================================================================
// (2) mixed equations + reactions (disjoint vars) → both contributions
// ============================================================================
#[test]
fn flatten_mixed_model_and_reaction_system() {
    let mut model_vars = HashMap::new();
    model_vars.insert(
        "y".to_string(),
        ModelVariable {
            var_type: VariableType::State,
            units: None,
            default: Some(0.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    let mut models = HashMap::new();
    models.insert(
        "dyn".to_string(),
        Model {
            regrid: None,
            domain: None,
            coupletype: None,
            subsystems: None,
            name: None,
            reference: None,
            variables: model_vars,
            equations: vec![Equation {
                lhs: ddt("y"),
                rhs: Expr::Number(1.0),
                ..Default::default()
            }],
            discrete_events: None,
            continuous_events: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        },
    );

    let rs = reaction_system(
        vec![("X", Some(1.0))],
        vec![("k", Some(0.5))],
        vec![Reaction {
            id: None,
            name: None,
            substrates: Some(vec![stoich("X", 1.0)]),
            products: Some(vec![]),
            rate: var("k"),
            reference: None,
        }],
    );
    let mut reaction_systems = HashMap::new();
    reaction_systems.insert("chem".to_string(), rs);

    let file = EsmFile {
        models: Some(models),
        reaction_systems: Some(reaction_systems),
        ..empty_file()
    };

    let flat = flatten(&file).unwrap();
    // Two equations: dyn.y and chem.X
    assert_eq!(flat.equations.len(), 2);
    assert!(flat.state_variables.contains_key("dyn.y"));
    assert!(flat.state_variables.contains_key("chem.X"));
    assert!(flat.parameters.contains_key("chem.k"));

    let lhses: Vec<String> = flat
        .equations
        .iter()
        .map(|eq| match &eq.lhs {
            Expr::Operator(n) if n.op == "D" => match &n.args[0] {
                Expr::Variable(v) => v.clone(),
                _ => String::new(),
            },
            _ => String::new(),
        })
        .collect();
    assert!(lhses.contains(&"dyn.y".to_string()));
    assert!(lhses.contains(&"chem.X".to_string()));
}

// ============================================================================
// (3) Autocatalytic A + B → 2B → d[B]/dt has net stoichiometry +1
// ============================================================================
#[test]
fn flatten_autocatalytic_reaction_net_stoichiometry() {
    let rs = reaction_system(
        vec![("A", Some(1.0)), ("B", Some(1.0))],
        vec![("k", Some(0.1))],
        vec![Reaction {
            id: None,
            name: None,
            substrates: Some(vec![stoich("A", 1.0), stoich("B", 1.0)]),
            products: Some(vec![stoich("B", 2.0)]),
            rate: var("k"),
            reference: None,
        }],
    );
    let mut reaction_systems = HashMap::new();
    reaction_systems.insert("auto".to_string(), rs);
    let file = EsmFile {
        reaction_systems: Some(reaction_systems),
        ..empty_file()
    };

    let flat = flatten(&file).unwrap();
    assert_eq!(flat.equations.len(), 2);

    // For species B: net stoich = products(2) - substrates(1) = +1. The
    // direct-contribution branch in lower_reactions_to_equations pushes the
    // enhanced rate expression directly (no leading *-1 or *coeff wrapper).
    let b_eq = flat
        .equations
        .iter()
        .find(|eq| {
            matches!(&eq.lhs,
            Expr::Operator(n) if n.op == "D"
                && matches!(&n.args[0], Expr::Variable(v) if v == "auto.B"))
        })
        .unwrap();

    // RHS must contain auto.A AND auto.B (the reaction rate enhanced with
    // mass-action substrate concentrations).
    let vs = rhs_vars(b_eq);
    assert!(vs.contains(&"auto.A".to_string()));
    assert!(vs.contains(&"auto.B".to_string()));
    assert!(vs.contains(&"auto.k".to_string()));
}

// ============================================================================
// (4) Source and sink reactions (null substrates / null products)
// ============================================================================
#[test]
fn flatten_source_and_sink_reactions() {
    let rs = reaction_system(
        vec![("X", Some(0.0))],
        vec![("k_src", Some(1.0)), ("k_sink", Some(0.1))],
        vec![
            // source: ∅ → X  (rate k_src, no substrates)
            Reaction {
                id: None,
                name: Some("src".to_string()),
                substrates: Some(vec![]),
                products: Some(vec![stoich("X", 1.0)]),
                rate: var("k_src"),
                reference: None,
            },
            // sink: X → ∅  (rate k_sink * X, enhanced with mass action)
            Reaction {
                id: None,
                name: Some("sink".to_string()),
                substrates: Some(vec![stoich("X", 1.0)]),
                products: Some(vec![]),
                rate: var("k_sink"),
                reference: None,
            },
        ],
    );
    let mut reaction_systems = HashMap::new();
    reaction_systems.insert("box".to_string(), rs);
    let file = EsmFile {
        reaction_systems: Some(reaction_systems),
        ..empty_file()
    };

    let flat = flatten(&file).unwrap();
    assert_eq!(flat.equations.len(), 1);
    let x_eq = &flat.equations[0];
    let vs = rhs_vars(x_eq);
    assert!(vs.contains(&"box.k_src".to_string()));
    assert!(vs.contains(&"box.k_sink".to_string()));
    assert!(vs.contains(&"box.X".to_string()));
}

// ============================================================================
// (5) CONFLICT: Model with explicit D(X, t) + reaction touching X
// ============================================================================
#[test]
fn flatten_conflicting_derivative_raises_error() {
    // A model named "sys" has an equation D(sys.X, t) = 0 referencing a
    // pre-namespaced variable. A reaction system ALSO named "sys" (allowed
    // since models and reaction_systems live in separate maps) has species
    // X that participates in a reaction. After namespacing, both produce
    // equations with LHS D(sys.X, t). With no operator_compose rule to
    // merge them, the flattener must raise ConflictingDerivative.
    let mut model_vars = HashMap::new();
    model_vars.insert(
        "X".to_string(),
        ModelVariable {
            var_type: VariableType::State,
            units: None,
            default: Some(0.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    let mut models = HashMap::new();
    models.insert(
        "sys".to_string(),
        Model {
            regrid: None,
            domain: None,
            coupletype: None,
            subsystems: None,
            name: None,
            reference: None,
            variables: model_vars,
            equations: vec![Equation {
                lhs: ddt("X"),
                rhs: Expr::Number(0.0),
                ..Default::default()
            }],
            discrete_events: None,
            continuous_events: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        },
    );

    let rs = reaction_system(
        vec![("X", Some(1.0))],
        vec![("k", Some(0.5))],
        vec![Reaction {
            id: None,
            name: None,
            substrates: Some(vec![stoich("X", 1.0)]),
            products: Some(vec![]),
            rate: var("k"),
            reference: None,
        }],
    );
    let mut reaction_systems = HashMap::new();
    reaction_systems.insert("sys".to_string(), rs);

    let file = EsmFile {
        models: Some(models),
        reaction_systems: Some(reaction_systems),
        ..empty_file()
    };

    let err = flatten(&file).unwrap_err();
    match err {
        FlattenError::ConflictingDerivative { species } => {
            assert!(
                species.iter().any(|s| s == "sys.X"),
                "expected conflict for sys.X, got {species:?}"
            );
        }
        other => panic!("expected ConflictingDerivative, got {other:?}"),
    }
}

// ============================================================================
// (6) Coupled 0D EsmFile with operator_compose → summed RHS, dot-namespaced
// ============================================================================
#[test]
fn flatten_operator_compose_sums_matched_rhses() {
    // Model A: d(u)/dt = k_A
    let mut vars_a = HashMap::new();
    vars_a.insert(
        "u".to_string(),
        ModelVariable {
            var_type: VariableType::State,
            units: None,
            default: Some(0.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    vars_a.insert(
        "k".to_string(),
        ModelVariable {
            var_type: VariableType::Parameter,
            units: None,
            default: Some(1.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    // Model B: d(A.u)/dt = k_B  (references A's state via a pre-namespaced
    // form, simulating what an operator_compose with matching LHSes looks
    // like after phase-1 namespacing).
    let mut vars_b = HashMap::new();
    vars_b.insert(
        "k".to_string(),
        ModelVariable {
            var_type: VariableType::Parameter,
            units: None,
            default: Some(2.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    let mut models = HashMap::new();
    models.insert(
        "A".to_string(),
        Model {
            regrid: None,
            domain: None,
            coupletype: None,
            subsystems: None,
            name: None,
            reference: None,
            variables: vars_a,
            equations: vec![Equation {
                lhs: ddt("u"),
                rhs: var("k"),
                ..Default::default()
            }],
            discrete_events: None,
            continuous_events: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        },
    );
    models.insert(
        "B".to_string(),
        Model {
            regrid: None,
            domain: None,
            coupletype: None,
            subsystems: None,
            name: None,
            reference: None,
            variables: vars_b,
            equations: vec![Equation {
                lhs: Expr::Operator(ExpressionNode {
                    op: "D".to_string(),
                    args: vec![Expr::Variable("A.u".to_string())],
                    wrt: Some("t".to_string()),
                    dim: None,
                    ..Default::default()
                }),
                rhs: var("k"),
                ..Default::default()
            }],
            discrete_events: None,
            continuous_events: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        },
    );

    let coupling = vec![CouplingEntry::OperatorCompose {
        systems: vec!["A".to_string(), "B".to_string()],
        translate: None,
        description: None,
    }];

    let file = EsmFile {
        models: Some(models),
        coupling: Some(coupling),
        ..empty_file()
    };

    let flat = flatten(&file).unwrap();
    // Exactly one equation survives for A.u — merged.
    let a_u_eqs: Vec<&Equation> = flat
        .equations
        .iter()
        .filter(|eq| {
            matches!(&eq.lhs,
            Expr::Operator(n) if n.op == "D"
                && matches!(&n.args[0], Expr::Variable(v) if v == "A.u"))
        })
        .collect();
    assert_eq!(
        a_u_eqs.len(),
        1,
        "expected 1 merged equation for A.u, got {}",
        a_u_eqs.len()
    );
    // Merged RHS references both A.k and B.k.
    let vs = rhs_vars(a_u_eqs[0]);
    assert!(vs.contains(&"A.k".to_string()));
    assert!(vs.contains(&"B.k".to_string()));
    assert!(
        flat.metadata
            .coupling_rules_applied
            .iter()
            .any(|r| r.contains("operator_compose"))
    );
}

// ============================================================================
// (7) variable_map param_to_var → substituted equations, target removed
// ============================================================================
#[test]
fn flatten_variable_map_param_to_var_substitutes_and_removes_parameter() {
    // Target model "M" has state u, parameter T, equation du/dt = T.
    let mut vars_m = HashMap::new();
    vars_m.insert(
        "u".to_string(),
        ModelVariable {
            var_type: VariableType::State,
            units: None,
            default: Some(0.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    vars_m.insert(
        "T".to_string(),
        ModelVariable {
            var_type: VariableType::Parameter,
            units: None,
            default: Some(298.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    // Source model "S" has observed T_out.
    let mut vars_s = HashMap::new();
    vars_s.insert(
        "T_out".to_string(),
        ModelVariable {
            var_type: VariableType::Observed,
            units: None,
            default: None,
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    let mut models = HashMap::new();
    models.insert(
        "M".to_string(),
        Model {
            regrid: None,
            domain: None,
            coupletype: None,
            subsystems: None,
            name: None,
            reference: None,
            variables: vars_m,
            equations: vec![Equation {
                lhs: ddt("u"),
                rhs: var("T"),
                ..Default::default()
            }],
            discrete_events: None,
            continuous_events: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        },
    );
    models.insert(
        "S".to_string(),
        Model {
            regrid: None,
            domain: None,
            coupletype: None,
            subsystems: None,
            name: None,
            reference: None,
            variables: vars_s,
            equations: vec![],
            discrete_events: None,
            continuous_events: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        },
    );

    let coupling = vec![CouplingEntry::VariableMap {
        from: "S.T_out".to_string(),
        to: "M.T".to_string(),
        transform: "param_to_var".to_string(),
        factor: None,
        description: None,
    }];

    let file = EsmFile {
        models: Some(models),
        coupling: Some(coupling),
        ..empty_file()
    };

    let flat = flatten(&file).unwrap();
    // M.T should no longer be in parameters.
    assert!(!flat.parameters.contains_key("M.T"));
    // The equation for M.u must now reference S.T_out on the RHS (replacing M.T).
    let u_eq = flat
        .equations
        .iter()
        .find(|eq| {
            matches!(&eq.lhs,
            Expr::Operator(n) if n.op == "D"
                && matches!(&n.args[0], Expr::Variable(v) if v == "M.u"))
        })
        .unwrap();
    let vs = rhs_vars(u_eq);
    assert!(vs.contains(&"S.T_out".to_string()));
    assert!(!vs.contains(&"M.T".to_string()));
}

// ============================================================================
// (8) couple with connector equations present in output
// ============================================================================
#[test]
fn flatten_couple_includes_connector_equations() {
    let mut vars_a = HashMap::new();
    vars_a.insert(
        "x".to_string(),
        ModelVariable {
            var_type: VariableType::State,
            units: None,
            default: Some(0.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    let mut models = HashMap::new();
    models.insert(
        "A".to_string(),
        Model {
            regrid: None,
            domain: None,
            coupletype: None,
            subsystems: None,
            name: None,
            reference: None,
            variables: vars_a,
            equations: vec![Equation {
                lhs: ddt("x"),
                rhs: Expr::Number(0.0),
                ..Default::default()
            }],
            discrete_events: None,
            continuous_events: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        },
    );
    // Connector with one equation: lhs Variable "bridge", rhs Variable "A.x"
    let connector = serde_json::json!({
        "equations": [
            { "lhs": "bridge", "rhs": "A.x" }
        ]
    });
    let coupling = vec![CouplingEntry::Couple {
        systems: vec!["A".to_string()],
        connector,
        description: None,
    }];
    let file = EsmFile {
        models: Some(models),
        coupling: Some(coupling),
        ..empty_file()
    };
    let flat = flatten(&file).unwrap();
    // The connector equation must appear in the final equation list.
    let found = flat
        .equations
        .iter()
        .any(|eq| matches!(&eq.lhs, Expr::Variable(v) if v == "bridge"));
    assert!(
        found,
        "connector equation not found in flattened equations: {:?}",
        flat.equations
    );
    assert!(
        flat.metadata
            .coupling_rules_applied
            .iter()
            .any(|r| r.contains("couple"))
    );
}

// ============================================================================
// (9) flatten_model convenience wraps a Model and namespaces under its name
// ============================================================================
#[test]
fn flatten_model_wraps_and_namespaces_under_declared_name() {
    let mut vars = HashMap::new();
    vars.insert(
        "q".to_string(),
        ModelVariable {
            var_type: VariableType::State,
            units: None,
            default: Some(0.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    let model = Model {
        regrid: None,
        domain: None,
        coupletype: None,
        subsystems: None,
        name: Some("Nested".to_string()),
        reference: None,
        variables: vars,
        equations: vec![Equation {
            lhs: ddt("q"),
            rhs: Expr::Number(1.0),
            ..Default::default()
        }],
        discrete_events: None,
        continuous_events: None,
        description: None,
        tolerance: None,
        tests: None,
        initialization_equations: None,
        guesses: None,
        system_kind: None,
    };
    let flat = flatten_model(&model).unwrap();
    assert!(flat.state_variables.contains_key("Nested.q"));
    assert_eq!(flat.equations.len(), 1);
}

// ============================================================================
// (10) UNSUPPORTED: spatial operators → UnsupportedMapping
// ============================================================================
#[test]
fn flatten_rejects_spatial_operators() {
    let mut vars = HashMap::new();
    vars.insert(
        "c".to_string(),
        ModelVariable {
            var_type: VariableType::State,
            units: None,
            default: Some(0.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    let mut models = HashMap::new();
    models.insert(
        "transport".to_string(),
        Model {
            regrid: None,
            domain: None,
            coupletype: None,
            subsystems: None,
            name: None,
            reference: None,
            variables: vars,
            equations: vec![Equation {
                lhs: ddt("c"),
                // RHS contains grad(c, x) — not supported at Rust Core tier.
                rhs: Expr::Operator(ExpressionNode {
                    op: "grad".to_string(),
                    args: vec![var("c")],
                    wrt: None,
                    dim: Some("x".to_string()),
                    ..Default::default()
                }),
                ..Default::default()
            }],
            discrete_events: None,
            continuous_events: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        },
    );
    let file = EsmFile {
        models: Some(models),
        ..empty_file()
    };
    let err = flatten(&file).unwrap_err();
    match err {
        FlattenError::UnsupportedMapping { mapping_type, .. } => {
            assert_eq!(mapping_type, "grad");
        }
        other => panic!("expected UnsupportedMapping, got {other:?}"),
    }
}

// ============================================================================
// (11) UNSUPPORTED: non-time derivative D(c, x) → UnsupportedMapping("slice"-style)
// ============================================================================
#[test]
fn flatten_rejects_non_time_derivative_and_exposes_slice_variant() {
    // Non-time derivative path: D with wrt != "t"
    let mut vars = HashMap::new();
    vars.insert(
        "c".to_string(),
        ModelVariable {
            var_type: VariableType::State,
            units: None,
            default: Some(0.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    let mut models = HashMap::new();
    models.insert(
        "pde".to_string(),
        Model {
            regrid: None,
            domain: None,
            coupletype: None,
            subsystems: None,
            name: None,
            reference: None,
            variables: vars,
            equations: vec![Equation {
                lhs: ddt("c"),
                rhs: Expr::Operator(ExpressionNode {
                    op: "D".to_string(),
                    args: vec![var("c")],
                    wrt: Some("x".to_string()),
                    dim: None,
                    ..Default::default()
                }),
                ..Default::default()
            }],
            discrete_events: None,
            continuous_events: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        },
    );
    let file = EsmFile {
        models: Some(models),
        ..empty_file()
    };
    let err = flatten(&file).unwrap_err();
    match err {
        FlattenError::UnsupportedMapping { mapping_type, .. } => {
            assert!(
                mapping_type.starts_with("D(wrt="),
                "unexpected mapping_type '{mapping_type}'"
            );
        }
        other => panic!("expected UnsupportedMapping, got {other:?}"),
    }

    // Type-level parity check: the FlattenError::UnsupportedMapping variant
    // is also the channel for slice/project/regrid unsupported mappings.
    // When a future Rust tier gains Interface support it will raise one of
    // these; for now we exercise the Display message so the error name
    // stays part of the library's public surface.
    let err_slice = FlattenError::UnsupportedMapping {
        mapping_type: "slice".to_string(),
        reason: "slice not implemented in Rust Core tier".to_string(),
    };
    let msg = format!("{err_slice}");
    assert!(msg.contains("slice"));
    assert!(msg.contains("Rust Core tier"));
}
