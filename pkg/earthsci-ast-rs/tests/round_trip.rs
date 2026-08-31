//! Round-trip tests for all valid fixtures
//!
//! Tests that valid ESM files can be loaded and saved back without losing information.
//! Every test compares the FULL saved document against the original fixture via
//! [`assert_lossless_round_trip`], so a dropped or altered field anywhere in the
//! document is a hard failure — not just the two fields the old tests spot-checked.
//!
//! # Coverage, and the fixtures deliberately NOT here
//!
//! The fixture list below is hardcoded `include_str!`s, not the shared corpus
//! manifest, so it pins a subset of `tests/valid/**` rather than all of it.
//! Promoting it to the manifest is owned separately; until then, a field fixed
//! against a drop should gain an entry here so the fix stays pinned.
//!
//! A whole-corpus `load` → `save` sweep does NOT come back clean, and most of
//! what it reports is CORRECT behaviour that a future audit should not re-flag.
//! Three load-time transforms are specified to change the document:
//!
//! * **Eager template expansion** (esm-spec §9.6.4 rule 3) — a reference whose
//!   template is target-bearing expands before emit.
//! * **Metaparameter folding** (§9.7.6) — `index_sets` sizes and bounds
//!   spelled as open metaparameter expressions fold to integers.
//! * **Subsystem `ref` resolution** (§4.7) — a `subsystems` entry's `ref` is
//!   replaced by the inlined component it names.
//!
//! And per §9.6.4 rule 5, a **component-level authored `match` rule** — one
//! consumed by the §9.6.3 fixpoint and invocable by nothing — is REQUIRED to be
//! dropped from the emitted component. `advection_reaction_loaded_ic_bc.esm`
//! and `derivative_trailing_boundary_operands.esm` each lose a component
//! `expression_templates` registry to exactly that rule; both are correct.
//!
//! The one genuine gap the sweep still shows is `expression_templates_arrhenius.esm`,
//! whose component registry holds a **match-less** entry. Rule 5 says those
//! "survive verbatim (they remain referenceable)", so emitting it expanded is a
//! divergence from Option B — but a deliberate, documented one: this binding's
//! typed IR is Expand-at-build (see the comment on `expand` in `parse.rs`), so
//! the typed structs never see an `apply_expression_template` node or an
//! `expression_templates` block, and a round-trip through them is Option-A by
//! construction. Closing that needs the reference-preserving emit path, not a
//! type change here.

use earthsci_ast::*;
use serde_json::Value;

/// Collect the differences between two JSON documents as JSON-pointer-style
/// paths. Object keys and array elements compare exactly, with one deliberate
/// exception: numbers compare by MATHEMATICAL VALUE, not by spelling.
///
/// That exception is a TOLERANCE for where the crate stands TODAY, not a
/// statement of a rule it keeps everywhere. The canonical-number rule
/// (CONFORMANCE_SPEC.md §5.5.3.1 rule 1) does say an integral,
/// `i64`-representable value must be written as an integer literal, and the
/// crate implements it at the sites that are settled — `Expr::Number` via
/// `serialize_canonical_f64`, `canon_number` in the golden emitter, and
/// `StoichiometricEntry::coefficient`. It is not yet applied to every typed
/// `f64` field: `time_span`, `default`, `factor` and friends still go through
/// derived serde, and their spelling diverges across the five bindings — both
/// integral `.0` retention and exponent form (`1e-9` vs `1e-09` vs `1.0e-9`).
///
/// That divergence is being closed, not tolerated forever: the ruling is to
/// extend rule 1 to the whole document `save()` path in all five bindings, so
/// integral typed floats become integer literals everywhere. That work is
/// scoped separately. Until it lands in all five, comparing by value is what
/// keeps these round-trips honest about STRUCTURE and CONTENT — tightening to
/// a spelling comparison today would simply go red on the fields still
/// awaiting the change. Once it lands, this SHOULD be tightened.
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
/// `comprehensive_compatibility_test.esm` has its own test below: it carries
/// the reaction-system parameter `shape`/`update` fields the round-trip once
/// dropped.
#[test]
fn test_version_compatibility_round_trip() {
    assert_lossless_round_trip(
        "version_1_0_0_baseline",
        include_str!("../../../tests/version_compatibility/version_1_0_0_baseline.esm"),
    );
}

#[test]
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
/// `test_index_outside_arrayop_lossless`, which also pins the fixture's
/// equation `_comment` fields.
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
/// aside — see [`value_diff`]). The INTEGRAL coefficients in this fixture do
/// additionally survive byte-identically, which
/// [`test_stoichiometry_emits_integer_literal`] pins directly.
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

/// An integral stoichiometric coefficient must reach the wire as an INTEGER
/// literal — `"stoichiometry": 1`, never `"stoichiometry": 1.0` — per
/// CONFORMANCE_SPEC.md §5.5.3.1 rule 1, and matching what the Julia, Python,
/// Go and TypeScript bindings all emit.
///
/// This asserts on the emitted TEXT rather than a reparsed `serde_json::Value`
/// on purpose. `StoichiometricEntry::coefficient` is a typed `f64`, so a
/// parsed comparison — including [`value_diff`] above, which compares numbers
/// by value — cannot see the difference between `1` and `1.0` and stayed blind
/// to a real divergence from all four sibling bindings for as long as it
/// existed. Deleting the `serialize_with` attribute on that field must turn
/// this test red.
///
/// Modeled on Go's `TestSaveTypedFloatFields`
/// (`pkg/earthsci-ast-go/pkg/esm/canonical_test.go`), which pins the same
/// property for `VariableMapCoupling.Factor`.
#[test]
fn test_stoichiometry_emits_integer_literal() {
    // `minimal_chemistry` is the first entry of the cross-language round-trip
    // manifest, and every one of its coefficients is spelled as an integer.
    let fixture = include_str!("../../../tests/valid/minimal_chemistry.esm");
    assert!(
        fixture.contains("\"stoichiometry\": 1\n") || fixture.contains("\"stoichiometry\": 1,"),
        "fixture precondition: minimal_chemistry spells its coefficients as integers"
    );

    let parsed: EsmFile = load_string(fixture).expect("parse minimal_chemistry");
    let serialized = to_json(&parsed).expect("serialize minimal_chemistry");

    assert!(
        serialized.contains("\"stoichiometry\": 1"),
        "expected an integer-literal coefficient in the emitted text"
    );
    assert!(
        !serialized.contains("\"stoichiometry\": 1.0"),
        "integral coefficient emitted with a trailing `.0`, diverging from the \
         Julia / Python / Go / TypeScript bindings:\n{serialized}"
    );

    // Fractional coefficients keep their float spelling: the rule normalizes
    // integral values only, it does not round anything.
    let frac_src = include_str!("../../../tests/valid/fractional_stoichiometry.esm");
    // This fixture spells one integral coefficient as `2.0`, which exercises
    // the "regardless of source spelling" half of the rule.
    assert!(
        frac_src.contains("\"stoichiometry\": 2.0"),
        "fixture precondition: fractional_stoichiometry spells one coefficient `2.0`"
    );

    let frac: EsmFile = load_string(frac_src).expect("parse fractional_stoichiometry");
    let frac_json = to_json(&frac).expect("serialize fractional_stoichiometry");
    assert!(
        frac_json.contains("\"stoichiometry\": 0.87"),
        "fractional coefficients must survive as floats"
    );
    assert!(
        !frac_json.contains("\"stoichiometry\": 2.0"),
        "the source-spelled `2.0` must normalize to the integer literal `2`:\n{frac_json}"
    );
}

/// The `metadata.discretized_from` / `metadata.x_esd` stamps round-trip.
///
/// This fixture exists because nothing else in the corpus sets either key, and
/// their absence hid two defects at once (fixed 2026-08-31):
///
/// * `discretized_from` is schema-typed an OBJECT (`{"name": …}`) but was
///   declared `Option<String>` here, so a schema-valid discretized document was
///   a hard serde DESERIALIZATION ERROR — a load failure, not a silent drop —
///   and this binding's own `discretize()` emitted a schema-INVALID bare string.
/// * `x_esd` had no field at all, so it was silently dropped, in violation of
///   its own normative description: core tooling "MUST NOT assign meaning to
///   them and MUST preserve them across parse → emit like any other metadata
///   field".
///
/// The typed assertions below are what make this test fail for the RIGHT reason
/// if either regresses: the whole-document comparison alone would still pass if
/// both the load and the emit reverted to the bare-string spelling together.
#[test]
fn test_metadata_discretized_stamps_round_trip() {
    let parsed = assert_lossless_round_trip(
        "metadata_discretized_stamps",
        include_str!("../../../tests/valid/metadata_discretized_stamps.esm"),
    );

    let from = parsed
        .metadata
        .discretized_from
        .as_ref()
        .expect("discretized_from must survive load");
    assert_eq!(from.name.as_deref(), Some("DampedOscillatorContinuous"));

    // `x_esd` is opaque to core tooling, so assert it arrives byte-for-byte as
    // authored rather than probing any structure the core is entitled to know.
    let x_esd = parsed.metadata.x_esd.as_ref().expect("x_esd must survive");
    let original: Value = serde_json::from_str(include_str!(
        "../../../tests/valid/metadata_discretized_stamps.esm"
    ))
    .unwrap();
    assert_eq!(x_esd, &original["metadata"]["x_esd"]);
}

/// `expect_cadence` — the optional AUTHOR assertion on a node's cadence class
/// (CONFORMANCE_SPEC.md §5.7.6 rule 3) — survives parse → emit on every node.
///
/// It is a diagnostic/test hook that changes no semantics: the
/// dependency-partition pass DERIVES each node's class and merely errors when a
/// present assertion disagrees. Nothing consumes it, so it is authored content
/// and must round-trip — as it already did in the Go and TypeScript bindings
/// while Rust dropped it. Dropping it silently disarmed the assertion that
/// guards the whole §5.7 contract on any document this binding re-emitted, and
/// these fixtures carry one on every meaningful node.
#[test]
fn test_expect_cadence_round_trip() {
    let fixtures = [
        (
            "cadence/mixed_stencil",
            include_str!("../../../tests/valid/cadence/mixed_stencil.esm"),
        ),
        (
            "cadence/pure_topology",
            include_str!("../../../tests/valid/cadence/pure_topology.esm"),
        ),
        (
            "cadence/pure_pointwise",
            include_str!("../../../tests/valid/cadence/pure_pointwise.esm"),
        ),
        (
            "cadence/discrete_remesh_stencil",
            include_str!("../../../tests/valid/cadence/discrete_remesh_stencil.esm"),
        ),
        (
            "cadence/loader_const_seed",
            include_str!("../../../tests/valid/cadence/loader_const_seed.esm"),
        ),
        (
            "cadence/loader_temporal_seed",
            include_str!("../../../tests/valid/cadence/loader_temporal_seed.esm"),
        ),
        (
            "cadence/observed_leaf_seeds",
            include_str!("../../../tests/valid/cadence/observed_leaf_seeds.esm"),
        ),
    ];

    for (name, fixture) in fixtures {
        assert_lossless_round_trip(name, fixture);
    }
}

/// `coupling[].lifting` survives on a `variable_map` entry, not only on the
/// `operator_compose` entry that was the sole variant carrying the field.
///
/// The schema declares `lifting` on `CouplingOperatorCompose`, `CouplingCouple`
/// AND `CouplingVariableMap`; this binding typed it only on the first, so the
/// six `variable_map` entries in this fixture lost theirs on emit. Only
/// `operator_compose` acts on the value (the `"pointwise"` promotion in the
/// flattener) — on the other two variants it is carried for round-trip alone.
#[test]
fn test_coupling_lifting_round_trip() {
    assert_lossless_round_trip(
        "wildfire_atmosphere_ocean",
        include_str!("../../../tests/valid/wildfire_atmosphere_ocean.esm"),
    );
}

/// v0.5.0: tests_analyses_comprehensive fixture (includes multi-series y array form) round-trips.
#[test]
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
