//! Round-trip tests for all valid fixtures
//!
//! Tests that valid ESM files can be loaded and saved back without losing information.

use earthsci_toolkit::*;

/// Test round-trip serialization for minimal chemistry fixture
#[test]
fn test_minimal_chemistry_round_trip() {
    let fixture = include_str!("../../../tests/valid/minimal_chemistry.esm");

    let parsed: EsmFile = load(fixture).expect("Failed to parse minimal chemistry fixture");
    let serialized = save(&parsed).expect("Failed to serialize back to JSON");

    // Parse again to ensure roundtrip works
    let reparsed: EsmFile = load(&serialized).expect("Failed to reparse serialized output");

    // Basic structural checks
    assert_eq!(parsed.esm, reparsed.esm);
    assert_eq!(parsed.metadata.name, reparsed.metadata.name);
}

/// Test round-trip for metadata variations
#[test]
fn test_metadata_variations_round_trip() {
    let fixtures = [
        include_str!("../../../tests/valid/metadata_minimal.esm"),
        include_str!("../../../tests/valid/metadata_author_variations.esm"),
        include_str!("../../../tests/valid/metadata_reference_types.esm"),
        include_str!("../../../tests/valid/metadata_date_formats.esm"),
        include_str!("../../../tests/valid/metadata_tags_license.esm"),
    ];

    for (i, fixture) in fixtures.iter().enumerate() {
        let parsed: EsmFile =
            load(fixture).unwrap_or_else(|e| panic!("Failed to parse metadata fixture {i}: {e}"));
        let serialized = save(&parsed)
            .unwrap_or_else(|e| panic!("Failed to serialize metadata fixture {i}: {e}"));
        let reparsed: EsmFile = load(&serialized)
            .unwrap_or_else(|e| panic!("Failed to reparse metadata fixture {i}: {e}"));

        assert_eq!(parsed.esm, reparsed.esm);
        assert_eq!(parsed.metadata.name, reparsed.metadata.name);
    }
}

/// Test round-trip for coupled atmospheric system
#[test]
fn test_coupled_atmospheric_system_round_trip() {
    let fixture = include_str!("../../../tests/end_to_end/coupled_atmospheric_system.esm");

    let parsed: EsmFile = load(fixture).expect("Failed to parse coupled atmospheric system");
    let serialized = save(&parsed).expect("Failed to serialize coupled atmospheric system");
    let reparsed: EsmFile =
        load(&serialized).expect("Failed to reparse coupled atmospheric system");

    assert_eq!(parsed.esm, reparsed.esm);
    if let (Some(models1), Some(models2)) = (&parsed.models, &reparsed.models) {
        assert_eq!(models1.len(), models2.len());
    }
    if let (Some(rs1), Some(rs2)) = (&parsed.reaction_systems, &reparsed.reaction_systems) {
        assert_eq!(rs1.len(), rs2.len());
    }
}

/// Test round-trip for comprehensive events
#[test]
fn test_comprehensive_events_round_trip() {
    let fixture = include_str!("../../../tests/events/comprehensive_events.esm");

    let parsed: EsmFile = load(fixture).expect("Failed to parse comprehensive events");
    let serialized = save(&parsed).expect("Failed to serialize comprehensive events");
    let reparsed: EsmFile = load(&serialized).expect("Failed to reparse comprehensive events");

    assert_eq!(parsed.esm, reparsed.esm);
    // Check that events are preserved
    if let (Some(models1), Some(models2)) = (&parsed.models, &reparsed.models) {
        for (name, model1) in models1 {
            let model2 = &models2[name];
            // Compare discrete events
            match (&model1.discrete_events, &model2.discrete_events) {
                (Some(events1), Some(events2)) => assert_eq!(events1.len(), events2.len()),
                (None, None) => {}
                _ => panic!("Discrete events structure mismatch for model {name}"),
            }
            // Compare continuous events
            match (&model1.continuous_events, &model2.continuous_events) {
                (Some(events1), Some(events2)) => assert_eq!(events1.len(), events2.len()),
                (None, None) => {}
                _ => panic!("Continuous events structure mismatch for model {name}"),
            }
        }
    }
}

/// Test round-trip for spatial operators
#[test]
fn test_spatial_operators_round_trip() {
    let fixtures = [
        include_str!("../../../tests/spatial/finite_difference_operators.esm"),
        include_str!("../../../tests/spatial/boundary_conditions.esm"),
    ];

    for (i, fixture) in fixtures.iter().enumerate() {
        let parsed: EsmFile =
            load(fixture).unwrap_or_else(|e| panic!("Failed to parse spatial fixture {i}: {e}"));
        let serialized = save(&parsed)
            .unwrap_or_else(|e| panic!("Failed to serialize spatial fixture {i}: {e}"));
        let reparsed: EsmFile = load(&serialized)
            .unwrap_or_else(|e| panic!("Failed to reparse spatial fixture {i}: {e}"));

        assert_eq!(parsed.esm, reparsed.esm);
        // Check operators are preserved
        if let (Some(ops1), Some(ops2)) = (&parsed.operators, &reparsed.operators) {
            assert_eq!(ops1.len(), ops2.len());
        }
    }
}

/// Test round-trip for coupling scenarios
#[test]
fn test_coupling_round_trip() {
    let fixtures = [
        include_str!("../../../tests/coupling/advanced_coupling.esm"),
        include_str!("../../../tests/coupling/complete_coupling_types.esm"),
        include_str!("../../../tests/coupling/coupling_resolution_algorithm.esm"),
    ];

    for (i, fixture) in fixtures.iter().enumerate() {
        let parsed: EsmFile =
            load(fixture).unwrap_or_else(|e| panic!("Failed to parse coupling fixture {i}: {e}"));
        let serialized = save(&parsed)
            .unwrap_or_else(|e| panic!("Failed to serialize coupling fixture {i}: {e}"));
        let reparsed: EsmFile = load(&serialized)
            .unwrap_or_else(|e| panic!("Failed to reparse coupling fixture {i}: {e}"));

        assert_eq!(parsed.esm, reparsed.esm);
        // Check coupling is preserved
        if let (Some(coupling1), Some(coupling2)) = (&parsed.coupling, &reparsed.coupling) {
            assert_eq!(coupling1.len(), coupling2.len());
        }
    }
}

/// Test round-trip for data loaders
#[test]
fn test_data_loaders_round_trip() {
    let fixture = include_str!("../../../tests/valid/data_loaders_comprehensive.esm");

    let parsed: EsmFile = load(fixture).expect("Failed to parse data loaders");
    let serialized = save(&parsed).expect("Failed to serialize data loaders");
    let reparsed: EsmFile = load(&serialized).expect("Failed to reparse data loaders");

    assert_eq!(parsed.esm, reparsed.esm);
    if let (Some(loaders1), Some(loaders2)) = (&parsed.data_loaders, &reparsed.data_loaders) {
        assert_eq!(loaders1.len(), loaders2.len());
    }
}

/// Test round-trip for version compatibility fixtures
#[test]
fn test_version_compatibility_round_trip() {
    let fixtures = [
        include_str!("../../../tests/version_compatibility/version_0_1_0_baseline.esm"),
        include_str!("../../../tests/version_compatibility/version_0_2_0_minor_upgrade.esm"),
        include_str!("../../../tests/version_compatibility/version_0_1_5_patch_upgrade.esm"),
        include_str!("../../../tests/version_compatibility/version_0_0_1_backwards_compat.esm"),
    ];

    for (i, fixture) in fixtures.iter().enumerate() {
        let parsed: EsmFile =
            load(fixture).unwrap_or_else(|e| panic!("Failed to parse version fixture {i}: {e}"));
        let serialized = save(&parsed)
            .unwrap_or_else(|e| panic!("Failed to serialize version fixture {i}: {e}"));
        let reparsed: EsmFile = load(&serialized)
            .unwrap_or_else(|e| panic!("Failed to reparse version fixture {i}: {e}"));

        assert_eq!(parsed.esm, reparsed.esm);
        assert_eq!(parsed.metadata.name, reparsed.metadata.name);
    }
}

/// Test round-trip for mathematical correctness fixtures
#[test]
fn test_mathematical_correctness_round_trip() {
    let fixtures = [
        include_str!("../../../tests/mathematical_correctness/conservation_laws.esm"),
        include_str!("../../../tests/mathematical_correctness/dimensional_analysis.esm"),
        include_str!("../../../tests/validation/mathematical_correctness.esm"),
    ];

    for (i, fixture) in fixtures.iter().enumerate() {
        let parsed: EsmFile =
            load(fixture).unwrap_or_else(|e| panic!("Failed to parse math fixture {i}: {e}"));
        let serialized =
            save(&parsed).unwrap_or_else(|e| panic!("Failed to serialize math fixture {i}: {e}"));
        let reparsed: EsmFile =
            load(&serialized).unwrap_or_else(|e| panic!("Failed to reparse math fixture {i}: {e}"));

        assert_eq!(parsed.esm, reparsed.esm);
    }
}

/// Round-trip for the `index`-outside-arrayop fixture (RFC discretization §5.1).
/// Confirms that `{op:"index", args:[V, i]}` nodes sitting on a scalar equation
/// RHS (rather than inside `arrayop.expr`) survive a load → save → load cycle
/// under the typed parser, with both integer-literal and composite-arithmetic
/// index arguments preserved.
#[test]
fn test_index_outside_arrayop_round_trip() {
    let fixture = include_str!("../../../tests/indexing/idx_outside_arrayop.esm");

    let parsed: EsmFile = load(fixture).expect("Failed to parse idx_outside_arrayop");
    let serialized = save(&parsed).expect("Failed to serialize idx_outside_arrayop");
    let reparsed: EsmFile = load(&serialized).expect("Failed to reparse idx_outside_arrayop");

    assert_eq!(parsed.esm, reparsed.esm);
    assert_eq!(parsed.metadata.name, reparsed.metadata.name);

    // Idempotency: a second save→load cycle must be a fixed point on the
    // JSON value (modulo map key ordering).
    let serialized_again = save(&reparsed).expect("second serialize");
    let reparsed_again: EsmFile = load(&serialized_again).expect("second reparse");
    assert_eq!(
        serde_json::to_value(&reparsed).expect("reparsed as value"),
        serde_json::to_value(&reparsed_again).expect("reparsed_again as value"),
        "save/load must be a fixed point on idx_outside_arrayop"
    );
}

/// Test round-trip for scoping fixtures
#[test]
fn test_scoping_round_trip() {
    let fixtures = [
        include_str!("../../../tests/scoping/nested_subsystems.esm"),
        include_str!("../../../tests/scoping/hierarchical_subsystems.esm"),
    ];

    for (i, fixture) in fixtures.iter().enumerate() {
        let parsed: EsmFile =
            load(fixture).unwrap_or_else(|e| panic!("Failed to parse scoping fixture {i}: {e}"));
        let serialized = save(&parsed)
            .unwrap_or_else(|e| panic!("Failed to serialize scoping fixture {i}: {e}"));
        let reparsed: EsmFile = load(&serialized)
            .unwrap_or_else(|e| panic!("Failed to reparse scoping fixture {i}: {e}"));

        assert_eq!(parsed.esm, reparsed.esm);
    }
}

/// Test round-trip for metadata inheritance
#[test]
fn test_metadata_inheritance_round_trip() {
    let fixture = include_str!("../../../tests/valid/metadata_inheritance_coupled.esm");

    let parsed: EsmFile = load(fixture).expect("Failed to parse metadata inheritance");
    let serialized = save(&parsed).expect("Failed to serialize metadata inheritance");
    let reparsed: EsmFile = load(&serialized).expect("Failed to reparse metadata inheritance");

    assert_eq!(parsed.esm, reparsed.esm);
    assert_eq!(parsed.metadata.name, reparsed.metadata.name);
}

/// Round-trip for a fixture that carries `tests` and `tolerance` blocks on
/// the `Model` struct (gt-c6w). Verifies that the typed `ModelTest`,
/// `ModelTestAssertion`, `TimeSpan`, and `Tolerance` fields survive a
/// load → save → load cycle and produce JSON equivalent to the original
/// modulo key ordering.
#[test]
fn test_model_tests_tolerance_round_trip() {
    let fixture = include_str!("../../../tests/fixtures/arrayop/01_pure_ode_analytical.esm");

    let parsed: EsmFile = load(fixture).expect("load fixture with tests/tolerance");

    // The fixture has one model (PureODE) with a tolerance and one test.
    let models = parsed.models.as_ref().expect("fixture has models");
    let model = models.get("PureODE").expect("PureODE model present");

    let tol = model.tolerance.as_ref().expect("model tolerance present");
    assert_eq!(tol.rel, Some(1.0e-6));
    assert_eq!(tol.abs, None);

    let tests = model.tests.as_ref().expect("model tests present");
    assert_eq!(tests.len(), 1);
    let t = &tests[0];
    assert_eq!(t.id, "analytical_t1");
    assert_eq!(t.time_span.start, 0.0);
    assert_eq!(t.time_span.end, 1.0);
    assert_eq!(
        t.initial_conditions
            .as_ref()
            .expect("initial conditions present")
            .get("u[1]"),
        Some(&1.0)
    );
    assert_eq!(t.assertions.len(), 5);
    assert_eq!(t.assertions[0].variable, "u[1]");
    assert_eq!(t.assertions[0].time, 1.0);
    assert!((t.assertions[0].expected - 0.36787944117144233).abs() < 1e-15);

    // Round-trip: save and reload, confirm typed fields survive.
    let serialized = save(&parsed).expect("serialize model with tests/tolerance");
    let reparsed: EsmFile = load(&serialized).expect("reparse serialized fixture");
    let rmodel = reparsed
        .models
        .as_ref()
        .and_then(|m| m.get("PureODE"))
        .expect("reparsed PureODE present");
    let rtol = rmodel.tolerance.as_ref().expect("reparsed tolerance");
    assert_eq!(rtol.rel, tol.rel);
    assert_eq!(rtol.abs, tol.abs);
    let rtests = rmodel.tests.as_ref().expect("reparsed tests");
    assert_eq!(rtests.len(), tests.len());
    assert_eq!(rtests[0].id, t.id);
    assert_eq!(rtests[0].time_span.start, t.time_span.start);
    assert_eq!(rtests[0].time_span.end, t.time_span.end);
    assert_eq!(rtests[0].assertions.len(), t.assertions.len());

    // Idempotency: once through the typed parser, a second save→load must
    // be a fixed point. This is a JSON-value equality check (modulo map key
    // ordering). We compare parsed → save → load against parsed, because
    // ryu's shortest-round-trip float formatting may differ from the
    // original fixture's textual representation while preserving the
    // underlying f64 values.
    let serialized_again = save(&reparsed).expect("second serialize");
    let reparsed_again: EsmFile = load(&serialized_again).expect("second reparse");
    assert_eq!(
        serde_json::to_value(&reparsed).expect("reparsed as value"),
        serde_json::to_value(&reparsed_again).expect("reparsed_again as value"),
        "save/load must be a fixed point on typed round-tripped EsmFile"
    );
}

/// Round-trip the Ornstein-Uhlenbeck SDE fixture, asserting that the
/// brownian variable type and its `noise_kind` field survive load/save.
#[test]
fn test_ornstein_uhlenbeck_sde_round_trip() {
    let fixture = include_str!("../../../tests/fixtures/sde/ornstein_uhlenbeck.esm");

    let parsed: EsmFile = load(fixture).expect("failed to parse OU SDE fixture");
    let model = parsed
        .models
        .as_ref()
        .and_then(|m| m.get("OU"))
        .expect("OU model missing");
    let bw = model.variables.get("Bw").expect("Bw variable missing");
    assert_eq!(bw.var_type, VariableType::Brownian);
    assert_eq!(bw.noise_kind.as_deref(), Some("wiener"));

    let serialized = save(&parsed).expect("failed to serialize OU SDE");
    let reparsed: EsmFile = load(&serialized).expect("failed to reparse OU SDE");

    // Serialization must preserve the brownian type and noise_kind.
    let rbw = reparsed
        .models
        .as_ref()
        .and_then(|m| m.get("OU"))
        .and_then(|m| m.variables.get("Bw"))
        .expect("Bw missing after round-trip");
    assert_eq!(rbw.var_type, VariableType::Brownian);
    assert_eq!(rbw.noise_kind.as_deref(), Some("wiener"));

    // Idempotency.
    let serialized_again = save(&reparsed).expect("second serialize");
    assert_eq!(
        serde_json::to_value(&parsed).expect("parsed as value"),
        serde_json::to_value(&reparsed).expect("reparsed as value"),
        "typed OU SDE round-trip must be a fixed point"
    );
    let reparsed_again: EsmFile = load(&serialized_again).expect("second reparse");
    assert_eq!(
        serde_json::to_value(&reparsed).expect("reparsed as value"),
        serde_json::to_value(&reparsed_again).expect("reparsed_again as value"),
    );
}

/// Correlated-noise SDE fixture: two brownian vars sharing a `correlation_group`.
#[test]
fn test_correlated_noise_sde_round_trip() {
    let fixture = include_str!("../../../tests/fixtures/sde/correlated_noise.esm");

    let parsed: EsmFile = load(fixture).expect("failed to parse correlated-noise fixture");
    let model = parsed
        .models
        .as_ref()
        .and_then(|m| m.get("TwoBody"))
        .expect("TwoBody model missing");
    for name in ["Bx", "By"] {
        let bv = model
            .variables
            .get(name)
            .unwrap_or_else(|| panic!("{name} missing"));
        assert_eq!(bv.var_type, VariableType::Brownian);
        assert_eq!(bv.correlation_group.as_deref(), Some("wind"));
    }

    let serialized = save(&parsed).expect("failed to serialize");
    let reparsed: EsmFile = load(&serialized).expect("failed to reparse");
    assert_eq!(
        serde_json::to_value(&parsed).expect("parsed as value"),
        serde_json::to_value(&reparsed).expect("reparsed as value"),
    );

    // Flattening must surface brownians in their own collection.
    use earthsci_toolkit::flatten::flatten;
    let flat = flatten(&parsed).expect("flatten");
    assert_eq!(flat.brownian_variables.len(), 2);
    assert!(flat.brownian_variables.contains_key("TwoBody.Bx"));
    assert!(flat.brownian_variables.contains_key("TwoBody.By"));
}

/// Round-trip: nonlinear models with initialization_equations, guesses, system_kind (gt-ebuq).
#[test]
fn test_nonlinear_isorropia_shape_round_trip() {
    let fixture = include_str!("../../../tests/valid/nonlinear_isorropia_shape.esm");
    let parsed: EsmFile = load(fixture).expect("load isorropia fixture");
    let serialized = save(&parsed).expect("save isorropia fixture");
    let reparsed: EsmFile = load(&serialized).expect("reload isorropia fixture");
    assert_eq!(
        serde_json::to_value(&parsed).expect("parsed as value"),
        serde_json::to_value(&reparsed).expect("reparsed as value"),
    );

    let model = parsed
        .models
        .as_ref()
        .and_then(|m| m.get("IsorropiaEq"))
        .expect("IsorropiaEq model missing");
    assert_eq!(model.system_kind.as_deref(), Some("nonlinear"));
    assert_eq!(
        model
            .initialization_equations
            .as_ref()
            .map(|eqs| eqs.len())
            .unwrap_or(0),
        2,
        "expected two initialization equations",
    );
    assert_eq!(
        model.guesses.as_ref().map(|g| g.len()).unwrap_or(0),
        2,
        "expected two guess entries",
    );
}

#[test]
fn test_nonlinear_mogi_shape_round_trip() {
    let fixture = include_str!("../../../tests/valid/nonlinear_mogi_shape.esm");
    let parsed: EsmFile = load(fixture).expect("load mogi fixture");
    let serialized = save(&parsed).expect("save mogi fixture");
    let reparsed: EsmFile = load(&serialized).expect("reload mogi fixture");
    assert_eq!(
        serde_json::to_value(&parsed).expect("parsed as value"),
        serde_json::to_value(&reparsed).expect("reparsed as value"),
    );
    let model = parsed
        .models
        .as_ref()
        .and_then(|m| m.get("MogiModel"))
        .expect("MogiModel missing");
    assert_eq!(model.system_kind.as_deref(), Some("nonlinear"));
    assert!(model.initialization_equations.is_none());
    assert!(model.guesses.is_none());
}

/// Reservoir species: Species.constant=true must round-trip through parse → save → reparse
/// and be preserved byte-identical for the flagged species while absent for ordinary ones.
#[test]
fn test_reservoir_species_constant_round_trip() {
    let fixture = include_str!("../../../tests/valid/reservoir_species_constant.esm");
    let parsed: EsmFile = load(fixture).expect("load reservoir fixture");
    let serialized = save(&parsed).expect("save reservoir fixture");
    let reparsed: EsmFile = load(&serialized).expect("reload reservoir fixture");
    assert_eq!(
        serde_json::to_value(&parsed).expect("parsed as value"),
        serde_json::to_value(&reparsed).expect("reparsed as value"),
    );
    let rs = parsed
        .reaction_systems
        .as_ref()
        .and_then(|m| m.get("SuperFastSubset"))
        .expect("SuperFastSubset missing");
    for name in &["O2", "CH4", "H2O"] {
        assert_eq!(
            rs.species.get(*name).and_then(|s| s.constant),
            Some(true),
            "species {name} should be constant=true",
        );
    }
    for name in &["O3", "OH", "HO2"] {
        assert!(
            rs.species.get(*name).and_then(|s| s.constant).is_none(),
            "species {name} should have no constant flag",
        );
    }
}

/// Reaction systems with fractional stoichiometries (ISOP+O3 → 0.87 CH2O, …)
/// must load and re-serialize without truncating the coefficients. Per
/// gt-1e96, parser/serializer preserve integer vs float numeric type, so the
/// round-tripped JSON is value-equal to the source fixture.
#[test]
fn test_fractional_stoichiometry_round_trip() {
    let fixture = include_str!("../../../tests/valid/fractional_stoichiometry.esm");
    let parsed: EsmFile = load(fixture).expect("load fractional_stoichiometry fixture");
    let serialized = save(&parsed).expect("save fractional_stoichiometry fixture");
    let reparsed: EsmFile = load(&serialized).expect("reload fractional_stoichiometry fixture");

    assert_eq!(
        serde_json::to_value(&parsed).expect("parsed as value"),
        serde_json::to_value(&reparsed).expect("reparsed as value"),
    );

    let rs = parsed
        .reaction_systems
        .as_ref()
        .and_then(|rs| rs.get("SuperFastLike"))
        .expect("SuperFastLike reaction system missing");

    let r1 = &rs.reactions[0];
    let products = r1.products.as_ref().expect("R1 products missing");
    let ch2o = products
        .iter()
        .find(|p| p.species == "CH2O")
        .expect("CH2O missing from R1 products");
    assert!((ch2o.coefficient - 0.87).abs() < 1e-12);

    let ch3o2 = products
        .iter()
        .find(|p| p.species == "CH3O2")
        .expect("CH3O2 missing from R1 products");
    assert!((ch3o2.coefficient - 1.86).abs() < 1e-12);

    let r4 = &rs.reactions[3];
    let substrates = r4.substrates.as_ref().expect("R4 substrates missing");
    assert_eq!(substrates[0].coefficient, 2.0);
}

/// v0.5.0: tests_examples_comprehensive fixture (includes multi-series y array form) round-trips.
#[test]
fn test_tests_examples_comprehensive_round_trip() {
    let fixture = include_str!("../../../tests/valid/tests_examples_comprehensive.esm");

    let parsed: EsmFile = load(fixture)
        .expect("tests_examples_comprehensive.esm must load (schema accepts array-form plots.y)");
    let serialized = save(&parsed).expect("serialize comprehensive fixture");
    let reparsed: EsmFile = load(&serialized).expect("re-load serialized comprehensive fixture");

    assert_eq!(parsed.esm, reparsed.esm);
    assert_eq!(parsed.metadata.name, reparsed.metadata.name);
}

/// v0.5.0: inline array-form plots.y passes schema validation.
#[test]
fn test_inline_multi_y_schema_validation() {
    let esm = r#"{
        "esm": "0.5.0",
        "metadata": { "name": "multi_y_test" },
        "models": {
            "AB": {
                "variables": {
                    "A": { "type": "state", "default": 1.0 },
                    "B": { "type": "state", "default": 0.0 }
                },
                "equations": [
                    { "lhs": { "op": "D", "args": ["A"], "wrt": "t" }, "rhs": { "op": "*", "args": [-0.1, "A"] } },
                    { "lhs": { "op": "D", "args": ["B"], "wrt": "t" }, "rhs": { "op": "*", "args": [0.1, "A"] } }
                ],
                "examples": [
                    {
                        "id": "ab_trace",
                        "time_span": { "start": 0.0, "end": 10.0 },
                        "plots": [
                            {
                                "id": "ab_multi",
                                "type": "line",
                                "x": { "variable": "t" },
                                "y": [
                                    { "variable": "A", "label": "Species A" },
                                    { "variable": "B", "label": "Species B" }
                                ]
                            }
                        ]
                    }
                ]
            }
        }
    }"#;

    let parsed: EsmFile = load(esm).expect("inline array-form plots.y must pass schema validation");
    assert_eq!(parsed.esm, "0.5.0");
}

/// Test round-trip for the point cell-averaging `regrid` / `missing_value`
/// config slot (RFC pure-io-data-loaders §5.2, §6; ess-v9a.6).
#[test]
fn test_regrid_point_missing_value_round_trip() {
    let fixture = include_str!("../../../tests/valid/regrid_point_missing_value.esm");

    let parsed: EsmFile = load(fixture).expect("Failed to parse regrid fixture");
    let model = parsed.models.as_ref().unwrap().get("OpenAQCoupler").unwrap();
    let spec = model
        .regrid
        .as_ref()
        .expect("regrid map present")
        .get("PM2_5")
        .expect("PM2_5 regrid entry present");
    assert_eq!(spec.method.as_deref(), Some("cell_average"));
    assert_eq!(spec.missing_value, Some(-999.0));

    // Idempotent re-save: regrid (incl. missing_value) survives load -> save -> load.
    let serialized = save(&parsed).expect("Failed to serialize regrid fixture");
    let reparsed: EsmFile = load(&serialized).expect("Failed to reparse regrid output");
    let respec = reparsed.models.as_ref().unwrap()["OpenAQCoupler"].regrid.as_ref().unwrap()["PM2_5"].clone();
    assert_eq!(respec.method.as_deref(), Some("cell_average"));
    assert_eq!(respec.missing_value, Some(-999.0));
}
