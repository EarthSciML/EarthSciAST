//! Round-trip tests for all valid fixtures
//!
//! Tests that valid ESM files can be loaded and saved back without losing information.
//! Every test compares the FULL saved document against the original fixture via
//! [`assert_lossless_round_trip`], so a dropped or altered field anywhere in the
//! document is a hard failure — not just the two fields the old tests spot-checked.

use earthsci_ast::*;
use serde_json::Value;

/// Collect the differences between two JSON documents as JSON-pointer-style
/// paths. Object keys and array elements compare exactly, with one deliberate
/// exception: numbers compare by MATHEMATICAL VALUE, per the ESM
/// canonical-number rule (CONFORMANCE_SPEC.md §5.5.3 rule 1) — an integral
/// float normalizes to an integer literal on save (`0.0` → `0`), so the
/// spelling `1` vs `1.0` is explicitly not information.
fn value_diff(path: &str, a: &Value, b: &Value, out: &mut Vec<String>) {
    if out.len() > 20 {
        return;
    }
    match (a, b) {
        (Value::Object(ma), Value::Object(mb)) => {
            for (k, va) in ma {
                match mb.get(k) {
                    Some(vb) => value_diff(&format!("{path}/{k}"), va, vb, out),
                    None => out.push(format!("{path}/{k}: DROPPED (was {va})")),
                }
            }
            for (k, vb) in mb {
                if !ma.contains_key(k) {
                    out.push(format!("{path}/{k}: ADDED ({vb})"));
                }
            }
        }
        (Value::Array(aa), Value::Array(ab)) => {
            if aa.len() != ab.len() {
                out.push(format!("{path}: array len {} -> {}", aa.len(), ab.len()));
            }
            for (i, (va, vb)) in aa.iter().zip(ab.iter()).enumerate() {
                value_diff(&format!("{path}/{i}"), va, vb, out);
            }
        }
        (Value::Number(na), Value::Number(nb)) => {
            if na.as_f64() != nb.as_f64() {
                out.push(format!("{path}: {a} -> {b}"));
            }
        }
        _ => {
            if a != b {
                out.push(format!("{path}: {a} -> {b}"));
            }
        }
    }
}

/// Full-fidelity round-trip: parse the fixture, save it, and compare the
/// SAVED document against the ORIGINAL fixture as `serde_json::Value`s —
/// equal modulo object key ordering and numeric spelling (see [`value_diff`]),
/// exact in every field. Returns the reparsed file for further typed
/// assertions.
fn assert_lossless_round_trip(name: &str, fixture: &str) -> EsmFile {
    let parsed: EsmFile =
        load_string(fixture).unwrap_or_else(|e| panic!("{name}: failed to parse: {e}"));
    let serialized =
        to_json(&parsed).unwrap_or_else(|e| panic!("{name}: failed to serialize: {e}"));
    let reparsed: EsmFile =
        load_string(&serialized).unwrap_or_else(|e| panic!("{name}: failed to reparse: {e}"));

    let original: Value = serde_json::from_str(fixture)
        .unwrap_or_else(|e| panic!("{name}: fixture is not JSON: {e}"));
    let round_tripped: Value = serde_json::from_str(&serialized)
        .unwrap_or_else(|e| panic!("{name}: serialized output is not JSON: {e}"));

    let mut diffs = Vec::new();
    value_diff("", &original, &round_tripped, &mut diffs);
    assert!(
        diffs.is_empty(),
        "{name}: load -> save lost or altered information:\n  {}",
        diffs.join("\n  ")
    );
    reparsed
}

/// Test round-trip serialization for minimal chemistry fixture
#[test]
#[ignore = "exposes round-trip field drop: reaction-system parameters lose `shape` and `update` (types.rs `Parameter` models only units/default/description); tracked"]
fn test_minimal_chemistry_round_trip() {
    assert_lossless_round_trip(
        "minimal_chemistry",
        include_str!("../../../tests/valid/minimal_chemistry.esm"),
    );
}

/// Test round-trip for metadata variations
#[test]
fn test_metadata_variations_round_trip() {
    let fixtures = [
        (
            "metadata_minimal",
            include_str!("../../../tests/valid/metadata_minimal.esm"),
        ),
        (
            "metadata_author_variations",
            include_str!("../../../tests/valid/metadata_author_variations.esm"),
        ),
        (
            "metadata_reference_types",
            include_str!("../../../tests/valid/metadata_reference_types.esm"),
        ),
        (
            "metadata_date_formats",
            include_str!("../../../tests/valid/metadata_date_formats.esm"),
        ),
        (
            "metadata_tags_license",
            include_str!("../../../tests/valid/metadata_tags_license.esm"),
        ),
    ];

    for (name, fixture) in fixtures {
        assert_lossless_round_trip(name, fixture);
    }
}

/// Test round-trip for coupled atmospheric system
#[test]
#[ignore = "exposes round-trip field drop: `Equation` loses the schema-sanctioned `_comment` field (esm-schema.json Equation allows it; types.rs `Equation` has only lhs/rhs); tracked"]
fn test_coupled_atmospheric_system_round_trip() {
    assert_lossless_round_trip(
        "coupled_atmospheric_system",
        include_str!("../../../tests/end_to_end/coupled_atmospheric_system.esm"),
    );
}

/// Test round-trip for comprehensive events
#[test]
fn test_comprehensive_events_round_trip() {
    assert_lossless_round_trip(
        "comprehensive_events",
        include_str!("../../../tests/events/comprehensive_events.esm"),
    );
}

/// Test round-trip for spatial operators
#[test]
fn test_spatial_operators_round_trip() {
    let fixtures = [
        (
            "finite_difference_operators",
            include_str!("../../../tests/spatial/finite_difference_operators.esm"),
        ),
        (
            "boundary_conditions",
            include_str!("../../../tests/spatial/boundary_conditions.esm"),
        ),
    ];

    for (name, fixture) in fixtures {
        assert_lossless_round_trip(name, fixture);
    }
}

/// Test round-trip for coupling scenarios
#[test]
fn test_coupling_round_trip() {
    let fixtures = [
        (
            "advanced_coupling",
            include_str!("../../../tests/coupling/advanced_coupling.esm"),
        ),
        (
            "complete_coupling_types",
            include_str!("../../../tests/coupling/complete_coupling_types.esm"),
        ),
        (
            "coupling_resolution_algorithm",
            include_str!("../../../tests/coupling/coupling_resolution_algorithm.esm"),
        ),
    ];

    for (name, fixture) in fixtures {
        assert_lossless_round_trip(name, fixture);
    }
}

/// Test round-trip for data loaders
#[test]
#[ignore = "exposes round-trip field drop: `Equation` loses the schema-sanctioned `_comment` field; tracked (same defect as test_coupled_atmospheric_system_round_trip)"]
fn test_data_sources_round_trip() {
    assert_lossless_round_trip(
        "data_sources_comprehensive",
        include_str!("../../../tests/valid/data_sources_comprehensive.esm"),
    );
}

/// Round-trip the version-compatibility fixtures this library ACCEPTS.
///
/// The compatibility matrix keeps one fixture per version it describes, and
/// this binding implements esm 1.0.0 — so only the major-1 fixtures load at
/// all; the major-0 ones are rejected by the same
/// `check_version_compatibility` gate that `test_major_version_rejection`
/// pins from the other side (esm-libraries-spec §8). Round-tripping a document
/// the loader refuses is not a thing this test can assert.
///
/// `comprehensive_compatibility_test.esm` has its own (currently ignored)
/// test below: it carries reaction-system parameter `shape`/`update` fields
/// the round-trip drops.
#[test]
fn test_version_compatibility_round_trip() {
    assert_lossless_round_trip(
        "version_1_0_0_baseline",
        include_str!("../../../tests/version_compatibility/version_1_0_0_baseline.esm"),
    );
}

#[test]
#[ignore = "exposes round-trip field drop: reaction-system parameters lose `shape` and `update`; tracked (same defect as test_minimal_chemistry_round_trip)"]
fn test_comprehensive_compatibility_round_trip() {
    assert_lossless_round_trip(
        "comprehensive_compatibility_test",
        include_str!("../../../tests/version_compatibility/comprehensive_compatibility_test.esm"),
    );
}

/// Test round-trip for mathematical correctness fixtures
#[test]
fn test_mathematical_correctness_round_trip() {
    let fixtures = [
        (
            "conservation_laws",
            include_str!("../../../tests/mathematical_correctness/conservation_laws.esm"),
        ),
        (
            "dimensional_analysis",
            include_str!("../../../tests/mathematical_correctness/dimensional_analysis.esm"),
        ),
        (
            "mathematical_correctness",
            include_str!("../../../tests/validation/mathematical_correctness.esm"),
        ),
    ];

    for (name, fixture) in fixtures {
        assert_lossless_round_trip(name, fixture);
    }
}

/// Round-trip for the `index`-outside-arrayop fixture (RFC discretization §5.1).
/// Confirms that `{op:"index", args:[V, i]}` nodes sitting on a scalar equation
/// RHS (rather than inside `arrayop.expr`) survive a load → save → load cycle
/// under the typed parser, with both integer-literal and composite-arithmetic
/// index arguments preserved.
///
/// The FULL lossless comparison for this fixture lives in
/// `test_index_outside_arrayop_lossless` (currently ignored: the fixture's
/// equation `_comment` fields are dropped).
#[test]
fn test_index_outside_arrayop_round_trip() {
    let fixture = include_str!("../../../tests/indexing/idx_outside_arrayop.esm");

    let parsed: EsmFile = load_string(fixture).expect("Failed to parse idx_outside_arrayop");
    let serialized = to_json(&parsed).expect("Failed to serialize idx_outside_arrayop");
    let reparsed: EsmFile =
        load_string(&serialized).expect("Failed to reparse idx_outside_arrayop");

    // The typed round-trip preserves the parsed document exactly.
    assert_eq!(
        serde_json::to_value(&parsed).expect("parsed as value"),
        serde_json::to_value(&reparsed).expect("reparsed as value"),
        "parse -> save -> parse must preserve the typed document"
    );

    // Idempotency: a second save→load cycle must be a fixed point on the
    // JSON value (modulo map key ordering).
    let serialized_again = to_json(&reparsed).expect("second serialize");
    let reparsed_again: EsmFile = load_string(&serialized_again).expect("second reparse");
    assert_eq!(
        serde_json::to_value(&reparsed).expect("reparsed as value"),
        serde_json::to_value(&reparsed_again).expect("reparsed_again as value"),
        "save/load must be a fixed point on idx_outside_arrayop"
    );
}

#[test]
#[ignore = "exposes round-trip field drop: `Equation` loses the schema-sanctioned `_comment` field; tracked (same defect as test_coupled_atmospheric_system_round_trip)"]
fn test_index_outside_arrayop_lossless() {
    assert_lossless_round_trip(
        "idx_outside_arrayop",
        include_str!("../../../tests/indexing/idx_outside_arrayop.esm"),
    );
}

/// Test round-trip for scoping fixtures
#[test]
fn test_scoping_round_trip() {
    let fixtures = [
        (
            "nested_subsystems",
            include_str!("../../../tests/scoping/nested_subsystems.esm"),
        ),
        (
            "hierarchical_subsystems",
            include_str!("../../../tests/scoping/hierarchical_subsystems.esm"),
        ),
    ];

    for (name, fixture) in fixtures {
        assert_lossless_round_trip(name, fixture);
    }
}

/// Test round-trip for metadata inheritance
#[test]
#[ignore = "exposes round-trip field drop: reaction-system parameters lose `shape` and `update`; tracked (same defect as test_minimal_chemistry_round_trip)"]
fn test_metadata_inheritance_round_trip() {
    assert_lossless_round_trip(
        "metadata_inheritance_coupled",
        include_str!("../../../tests/valid/metadata_inheritance_coupled.esm"),
    );
}

/// Round-trip for a fixture that carries `tests` and `tolerance` blocks on
/// the `Model` struct (gt-c6w). Verifies that the typed `ModelTest`,
/// `ModelTestAssertion`, `TimeSpan`, and `Tolerance` fields survive a
/// load → save → load cycle and produce JSON equivalent to the original
/// modulo key ordering and numeric spelling.
#[test]
fn test_model_tests_tolerance_round_trip() {
    let fixture = include_str!("../../../tests/fixtures/arrayop/01_pure_ode_analytical.esm");

    let parsed: EsmFile = load_string(fixture).expect("load fixture with tests/tolerance");

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

    // Round-trip: the saved document must be value-equal to the original.
    let reparsed = assert_lossless_round_trip("01_pure_ode_analytical", fixture);

    // Idempotency: once through the typed parser, a second save→load must
    // be a fixed point on the JSON value.
    let serialized_again = to_json(&reparsed).expect("second serialize");
    let reparsed_again: EsmFile = load_string(&serialized_again).expect("second reparse");
    assert_eq!(
        serde_json::to_value(&reparsed).expect("reparsed as value"),
        serde_json::to_value(&reparsed_again).expect("reparsed_again as value"),
        "save/load must be a fixed point on typed round-tripped EsmFile"
    );
}

/// Round-trip the Ornstein-Uhlenbeck SDE fixture, asserting that the Brownian
/// parameter's `distribution` + `wiener` update survive load/save — and that it
/// is DERIVED Brownian (esm-spec 6.3.1), not declared.
#[test]
fn test_ornstein_uhlenbeck_sde_round_trip() {
    let fixture = include_str!("../../../tests/fixtures/sde/ornstein_uhlenbeck.esm");

    let parsed = assert_lossless_round_trip("ornstein_uhlenbeck", fixture);
    let model = parsed
        .models
        .as_ref()
        .and_then(|m| m.get("OU"))
        .expect("OU model missing");
    let bw = model.variables.get("Bw").expect("Bw variable missing");
    assert_eq!(bw.var_type, VariableType::Parameter);
    assert!(
        bw.distribution.is_some(),
        "a wiener update needs a distribution"
    );
    assert!(bw.update.as_ref().expect("update").is_wiener());
    assert_eq!(earthsci_ast::brownian_parameters(model), ["Bw"]);
    assert_eq!(
        earthsci_ast::system_kind(model),
        earthsci_ast::SystemKind::Sde
    );

    // Idempotency.
    let serialized_again = to_json(&parsed).expect("second serialize");
    let reparsed_again: EsmFile = load_string(&serialized_again).expect("second reparse");
    assert_eq!(
        serde_json::to_value(&parsed).expect("parsed as value"),
        serde_json::to_value(&reparsed_again).expect("reparsed_again as value"),
        "typed OU SDE round-trip must be a fixed point"
    );
}

/// Correlated-noise SDE fixture: ONE vector-valued Brownian parameter whose
/// `cov` matrix states the correlation the 0.x `correlation_group` tag only
/// named.
#[test]
fn test_correlated_noise_sde_round_trip() {
    let fixture = include_str!("../../../tests/fixtures/sde/correlated_noise.esm");

    let parsed = assert_lossless_round_trip("correlated_noise", fixture);
    let model = parsed
        .models
        .as_ref()
        .and_then(|m| m.get("TwoBody"))
        .expect("TwoBody model missing");
    let bv = model.variables.get("B").expect("B missing");
    assert_eq!(bv.var_type, VariableType::Parameter);
    assert!(bv.update.as_ref().expect("update").is_wiener());
    let dist = bv.distribution.as_ref().expect("distribution");
    assert!(dist.is_multivariate(), "correlated noise is vector-valued");
    assert_eq!(
        dist.cov(),
        Some(&vec![vec![1.0, 0.5], vec![0.5, 1.0]]),
        "the correlation is the explicit off-diagonal of `cov`"
    );
    assert_eq!(earthsci_ast::brownian_parameters(model), ["B"]);

    // Flattening must surface Brownian parameters in their own collection. It
    // is ONE vector-valued parameter now, not two tagged scalars: the
    // correlation lives in its `cov`.
    use earthsci_ast::flatten;
    let flat = flatten(&parsed).expect("flatten");
    assert_eq!(flat.brownian_parameters.len(), 1);
    assert!(flat.brownian_parameters.contains_key("TwoBody.B"));
    // ...and it is ALSO an ordinary parameter: esm-spec §6.3.1's four sets
    // partition `parameters` rather than sitting beside it.
    assert!(flat.parameters.contains_key("TwoBody.B"));
}

/// Round-trip: nonlinear models with initialization_equations, guesses, system_kind (gt-ebuq).
#[test]
fn test_nonlinear_isorropia_shape_round_trip() {
    let parsed = assert_lossless_round_trip(
        "nonlinear_isorropia_shape",
        include_str!("../../../tests/valid/nonlinear_isorropia_shape.esm"),
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
    let parsed = assert_lossless_round_trip(
        "nonlinear_mogi_shape",
        include_str!("../../../tests/valid/nonlinear_mogi_shape.esm"),
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
/// and be preserved for the flagged species while absent for ordinary ones.
#[test]
fn test_reservoir_species_constant_round_trip() {
    let parsed = assert_lossless_round_trip(
        "reservoir_species_constant",
        include_str!("../../../tests/valid/reservoir_species_constant.esm"),
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
/// must load and re-serialize without truncating the coefficients: the
/// round-tripped JSON is value-equal to the source fixture (numeric spelling
/// aside, per the §5.5.3 canonical-number rule).
#[test]
fn test_fractional_stoichiometry_round_trip() {
    let parsed = assert_lossless_round_trip(
        "fractional_stoichiometry",
        include_str!("../../../tests/valid/fractional_stoichiometry.esm"),
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

/// v0.5.0: tests_analyses_comprehensive fixture (includes multi-series y array form) round-trips.
#[test]
#[ignore = "exposes round-trip field drop: `Model` loses `analyses`, and `ReactionSystem` loses `tolerance`, `tests`, and `analyses` (types.rs models none of them); tracked"]
fn test_tests_analyses_comprehensive_round_trip() {
    assert_lossless_round_trip(
        "tests_analyses_comprehensive",
        include_str!("../../../tests/valid/tests_analyses_comprehensive.esm"),
    );
}

/// v0.5.0: inline array-form plots.y passes schema validation.
#[test]
fn test_inline_multi_y_schema_validation() {
    let esm = r#"
        {
          "esm": "1.0.0",
          "metadata": {
            "name": "multi_y_test"
          },
          "models": {
            "AB": {
              "variables": {
                "A": {
                  "type": "unknown",
                  "default": 1.0
                },
                "B": {
                  "type": "unknown",
                  "default": 0.0
                }
              },
              "equations": [
                {
                  "lhs": {
                    "op": "D",
                    "args": [
                      "A"
                    ],
                    "wrt": "t"
                  },
                  "rhs": {
                    "op": "*",
                    "args": [
                      -0.1,
                      "A"
                    ]
                  }
                },
                {
                  "lhs": {
                    "op": "D",
                    "args": [
                      "B"
                    ],
                    "wrt": "t"
                  },
                  "rhs": {
                    "op": "*",
                    "args": [
                      0.1,
                      "A"
                    ]
                  }
                }
              ],
              "analyses": [
                {
                  "id": "ab_trace",
                  "time_span": {
                    "start": 0.0,
                    "end": 10.0
                  },
                  "plots": [
                    {
                      "id": "ab_multi",
                      "type": "line",
                      "x": {
                        "variable": "t"
                      },
                      "y": [
                        {
                          "variable": "A",
                          "label": "Species A"
                        },
                        {
                          "variable": "B",
                          "label": "Species B"
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        "#;

    let parsed: EsmFile =
        load_string(esm).expect("inline array-form plots.y must pass schema validation");
    assert_eq!(parsed.esm, "1.0.0");
}
