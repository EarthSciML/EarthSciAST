//! Name-based broadcast in BARE array-level expressions (esm-spec §4.3.4;
//! issue #100).
//!
//! A whole-array equation written without index symbols — `D(dp) ~ w1`,
//! `D(dp) ~ w2 * z1` — aligns its operands by index-set NAME: an operand whose
//! declared `shape` is a SUBSET of the result's broadcasts along the axes it is
//! missing, and axis ORDER does not matter. The oracle for every case here is
//! the explicit `aggregate` spelling of the same maths, which names the axes
//! and has always been right; the two spellings must agree BIT for BIT, not
//! merely to a tolerance.
//!
//! Before the fix each operand was instead flattened into the result's linear
//! (column-major) layout with the short one zero-padded, which produced
//! plausible, finite, wrong numbers under a clean `validate()`.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::pde_inline_tests::run_pde_tests;
use earthsci_ast::validate::{StructuralErrorCode, validate};
use earthsci_ast::{Model, SimulateOptions, SolverChoice, load, simulate};
use std::collections::HashMap;
use std::path::PathBuf;

mod common;

fn opts() -> SimulateOptions {
    SimulateOptions {
        solver: SolverChoice::Bdf,
        reltol: 1e-12,
        abstol: 1e-14,
        ..Default::default()
    }
}

/// Integrate a document from t=0 to t=1, sampling exactly the two endpoints.
fn run(
    file: &earthsci_ast::EsmFile,
) -> Result<earthsci_ast::Solution, earthsci_ast::simulate::SimulateError> {
    let mut o = opts();
    o.output_times = Some(vec![0.0, 1.0]);
    simulate(file, (0.0, 1.0), &HashMap::new(), &HashMap::new(), &o)
}

fn read(path: &PathBuf) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// Run one shared fixture's inline §6.6.5 `coords` assertions.
fn run_shared_fixture(name: &str) {
    let path = common::repo_fixture("valid/array_broadcast").join(name);
    let file = load(&read(&path)).unwrap_or_else(|e| panic!("{name} does not load: {e}"));

    let report = validate(&file);
    assert!(
        report.is_valid,
        "{name} must validate cleanly: {:?}",
        report.structural_errors
    );

    let results = run_pde_tests(&file, None, &opts());
    assert!(!results.is_empty(), "{name}: no inline assertions ran");
    for r in &results {
        assert!(
            r.passed,
            "{name}/{}#{} ({} @ t={}): {}",
            r.test_id, r.assertion_idx, r.variable, r.time, r.message
        );
    }
}

/// Case A — a rank-1 `[lat]` operand under a rank-3 `[lon,lat,lev]` result
/// replicates along `lon` and `lev`.
#[test]
fn bare_rank_lift_fixture() {
    run_shared_fixture("bare_rank_lift.esm");
}

/// Case B — `[lon,lat] * [lev]`: two operands missing DIFFERENT axes, the case
/// no positional rank-padding convention can express.
#[test]
fn bare_mixed_rank_product_fixture() {
    run_shared_fixture("bare_mixed_rank_product.esm");
}

/// Axis ORDER is immaterial: a `[lat,lon]` operand in a `[lon,lat,lev]` result
/// transposes rather than being reinterpreted.
#[test]
fn bare_axis_permuted_operand_fixture() {
    run_shared_fixture("bare_axis_permuted_operand.esm");
}

/// The same mixed-rank product written with an explicit `broadcast` node —
/// same index sets, same operands, same expected values. Only the spelling
/// differs, and it must not change a single number.
#[test]
fn broadcast_node_mixed_rank_fixture() {
    run_shared_fixture("broadcast_node_mixed_rank.esm");
}

/// An operand carrying an index set the result does not have is a HARD
/// structural error at `validate()` — both shapes are declared, so it is
/// decidable without running anything.
#[test]
fn operand_index_set_absent_from_result_is_a_structural_error() {
    let path =
        common::repo_fixture("invalid/array_broadcast").join("operand_index_set_not_in_result.esm");
    let file = load(&read(&path)).expect("fixture is schema-valid; only the shapes are wrong");
    let report = validate(&file);

    assert!(!report.is_valid, "unalignable operand must not validate");
    let err = report
        .structural_errors
        .iter()
        .find(|e| matches!(e.code, StructuralErrorCode::ArrayShapeMismatch))
        .expect("expected an array_shape_mismatch structural error");
    assert_eq!(
        err.path,
        "/models/OperandIndexSetNotInResult/equations/0/rhs"
    );
    assert_eq!(err.details["operand"], "z1");
    assert_eq!(err.details["missing_index_set"], "lev");

    // …and the build refuses it too, for a caller that skipped validation.
    let e = run(&file).expect_err("compile must reject the unalignable operand");
    assert!(
        format!("{e}").contains("array_shape_mismatch"),
        "unexpected error: {e}"
    );
}

/// Load a shared fixture with its single equation's RHS replaced.
fn fixture_with_rhs(name: &str, rhs: serde_json::Value) -> earthsci_ast::EsmFile {
    let path = common::repo_fixture("valid/array_broadcast").join(name);
    let mut doc: serde_json::Value = serde_json::from_str(&read(&path)).expect("fixture is JSON");
    let models = doc["models"].as_object_mut().expect("models");
    let model = models.values_mut().next().expect("one model");
    model["equations"][0]["rhs"] = rhs;
    load(&doc.to_string()).unwrap_or_else(|e| panic!("{name} (rewritten): {e}"))
}

/// Assert two documents integrate to bit-identical trajectories.
fn assert_same_trajectory(label: &str, a: &earthsci_ast::EsmFile, b: &earthsci_ast::EsmFile) {
    let sa = run(a).unwrap_or_else(|e| panic!("{label} (a): {e}"));
    let sb = run(b).unwrap_or_else(|e| panic!("{label} (b): {e}"));
    assert_eq!(sa.state_variable_names, sb.state_variable_names, "{label}");
    for (slot, name) in sa.state_variable_names.iter().enumerate() {
        for (t, va) in sa.state[slot].iter().enumerate() {
            let vb = sb.state[slot][t];
            assert_eq!(
                va.to_bits(),
                vb.to_bits(),
                "{label}: {name} at sample {t}: {va} vs {vb}"
            );
        }
    }
}

/// `broadcast(fn: F, args)` MEANS `{op: F, args}`, so the two spellings of one
/// array-level expression must align their operands identically and produce
/// bit-identical trajectories (esm-spec §4.3.4).
///
/// Treating `broadcast` as opaque made the implementation narrower than the
/// normative text: the bare form aligned by index-set name while the
/// `broadcast` form silently kept the positional flatten — `w2 * z1` over
/// `[lon,lat,lev]` returned 1100, 2400, 0 instead of 1100, 1200, 1300. That is
/// the exact divergence issue #100 exists to close, reappearing one spelling
/// over.
#[test]
fn broadcast_and_bare_spellings_are_bit_identical() {
    for (fixture, bare, broadcast) in [
        // A rank-1 `[lat]` operand lifted into a `[lon,lat,lev]` result.
        (
            "bare_rank_lift.esm",
            serde_json::json!({"op": "*", "args": ["w1", 1.0]}),
            serde_json::json!({"op": "broadcast", "fn": "*", "args": ["w1", 1.0]}),
        ),
        // Two operands missing DIFFERENT axes — the case no positional
        // convention can express.
        (
            "bare_mixed_rank_product.esm",
            serde_json::json!({"op": "*", "args": ["w2", "z1"]}),
            serde_json::json!({"op": "broadcast", "fn": "*", "args": ["w2", "z1"]}),
        ),
        // A `[lat,lon]` operand that must transpose, not be reinterpreted.
        (
            "bare_axis_permuted_operand.esm",
            serde_json::json!({"op": "*", "args": ["wT", 1.0]}),
            serde_json::json!({"op": "broadcast", "fn": "*", "args": ["wT", 1.0]}),
        ),
    ] {
        assert_same_trajectory(
            fixture,
            &fixture_with_rhs(fixture, bare),
            &fixture_with_rhs(fixture, broadcast),
        );
    }
}

/// The unalignable-operand rejection reaches through a `broadcast` too — the
/// checker and the builder must not disagree with the bare spelling about
/// whether a document is well-formed.
#[test]
fn broadcast_spelled_unalignable_operand_is_rejected() {
    let path =
        common::repo_fixture("invalid/array_broadcast").join("operand_index_set_not_in_result.esm");
    let mut doc: serde_json::Value = serde_json::from_str(&read(&path)).expect("fixture is JSON");
    let models = doc["models"].as_object_mut().expect("models");
    let model = models.values_mut().next().expect("one model");
    model["equations"][0]["rhs"] =
        serde_json::json!({"op": "broadcast", "fn": "*", "args": ["z1", 1.0]});
    let file = load(&doc.to_string()).expect("still schema-valid");

    let report = validate(&file);
    assert!(
        report
            .structural_errors
            .iter()
            .any(|e| matches!(e.code, StructuralErrorCode::ArrayShapeMismatch)),
        "a `broadcast`-spelled unalignable operand must be reported too: {:?}",
        report.structural_errors
    );
    let e = run(&file).expect_err("compile must reject it as well");
    assert!(
        format!("{e}").contains("array_shape_mismatch"),
        "unexpected error: {e}"
    );
}

/// The BARE spelling and the explicit `aggregate` spelling of the same maths
/// must agree BIT for BIT — the aggregate form is the correctness oracle,
/// because its axes are named by the author and were never inferred.
#[test]
fn bare_and_aggregate_spellings_are_bit_identical() {
    for (fixture, aggregate_rhs) in [
        // sum_{i,j,k} w1[j]
        ("bare_rank_lift.esm", r#"{"op":"index","args":["w1","j"]}"#),
        // sum_{i,j,k} w2[i,j] * z1[k]
        (
            "bare_mixed_rank_product.esm",
            r#"{"op":"*","args":[{"op":"index","args":["w2","i","j"]},
                                 {"op":"index","args":["z1","k"]}]}"#,
        ),
        // sum_{i,j,k} wT[j,i]
        (
            "bare_axis_permuted_operand.esm",
            r#"{"op":"index","args":["wT","j","i"]}"#,
        ),
    ] {
        let path = common::repo_fixture("valid/array_broadcast").join(fixture);
        let text = read(&path);
        let bare = load(&text).unwrap_or_else(|e| panic!("{fixture}: {e}"));

        // Rewrite the single equation's RHS into the equivalent full-map
        // `aggregate` over every axis — a reduction over nothing, so the two
        // documents describe the same function.
        let mut doc: serde_json::Value = serde_json::from_str(&text).expect("fixture is JSON");
        let models = doc["models"].as_object_mut().expect("models");
        let model = models.values_mut().next().expect("one model");
        model["equations"][0]["rhs"] = serde_json::json!({
            "op": "aggregate",
            "args": [],
            "output_idx": ["i", "j", "k"],
            "ranges": {
                "i": {"from": "lon"}, "j": {"from": "lat"}, "k": {"from": "lev"}
            },
            "expr": serde_json::from_str::<serde_json::Value>(aggregate_rhs).unwrap(),
        });
        let agg = load(&doc.to_string()).unwrap_or_else(|e| panic!("{fixture} (aggregate): {e}"));

        let a = run(&bare).unwrap_or_else(|e| panic!("{fixture} (bare): {e}"));
        let b = run(&agg).unwrap_or_else(|e| panic!("{fixture} (aggregate): {e}"));

        assert_eq!(a.state_variable_names, b.state_variable_names, "{fixture}");
        for (slot, name) in a.state_variable_names.iter().enumerate() {
            for (t, ta) in a.state[slot].iter().enumerate() {
                let tb = b.state[slot][t];
                assert_eq!(
                    ta.to_bits(),
                    tb.to_bits(),
                    "{fixture}: {name} at sample {t}: bare {ta} vs aggregate {tb}"
                );
            }
        }
    }
}

/// The ANONYMOUS-shape fallback is untouched: `broadcast(+, a, reshape(b,[1,3]))`
/// keeps the positional, trailing-singleton convention of esm-spec §4.3.4,
/// because a `reshape` result names no index sets to align by.
#[test]
fn anonymous_shapes_keep_positional_broadcast() {
    let path = common::repo_tests_dir().join("fixtures/arrayop/14_broadcast_elementwise.esm");
    let file = load(&read(&path)).expect("fixture loads");
    let ics: HashMap<String, f64> = [
        ("a[1]", 1.0),
        ("a[2]", 2.0),
        ("a[3]", 3.0),
        ("b[1]", 100.0),
        ("b[2]", 200.0),
        ("b[3]", 300.0),
        ("corner", 0.0),
        ("middle", 0.0),
        ("far", 0.0),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    let mut o = opts();
    o.output_times = Some(vec![0.0, 1.0]);
    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &ics, &o)
        .expect("positional broadcast still simulates");

    // result[i, j] = a[i] + b[j] with a = [1,2,3], b = [100,200,300].
    for (name, want) in [("corner", 101.0), ("middle", 302.0), ("far", 203.0)] {
        let slot = sol
            .state_variable_names
            .iter()
            .position(|n| n == name)
            .unwrap_or_else(|| panic!("no state {name}"));
        let got = sol.state[slot][sol.state[slot].len() - 1];
        assert!(
            (got - want).abs() < 1e-9,
            "{name}: expected {want}, got {got}"
        );
    }
}

/// A declared array-shaped OBSERVED is governed by the same rule: its body is a
/// bare array-level expression over the axes its own `shape` declares, so a
/// mixed-rank product must broadcast by name there too rather than be
/// materialized by the positional wholesale broadcast.
#[test]
fn array_shaped_observed_broadcasts_by_name() {
    let path = common::repo_fixture("valid/array_broadcast").join("bare_mixed_rank_product.esm");
    let mut doc: serde_json::Value = serde_json::from_str(&read(&path)).expect("fixture is JSON");
    let models = doc["models"].as_object_mut().expect("models");
    let model = models.values_mut().next().expect("one model");

    // Hoist `w2 * z1` into a declared [lon,lat,lev] observed and drive `dp`
    // from that instead. The trajectory must not change.
    model["variables"]["p3"] = serde_json::json!({
        "type": "observed",
        "units": "1",
        "shape": ["lon", "lat", "lev"],
        "expression": {"op": "*", "args": ["w2", "z1"]}
    });
    model["equations"][0]["rhs"] = serde_json::json!("p3");

    let hoisted = load(&doc.to_string()).expect("hoisted document loads");
    let direct = load(&read(&path)).expect("fixture loads");

    let a = run(&direct).expect("direct");
    let b = run(&hoisted).expect("hoisted through an array observed");
    for (slot, name) in a.state_variable_names.iter().enumerate() {
        for (t, ta) in a.state[slot].iter().enumerate() {
            let tb = b.state[slot][t];
            assert_eq!(
                ta.to_bits(),
                tb.to_bits(),
                "{name} at sample {t}: inline {ta} vs observed {tb}"
            );
        }
    }
}

/// Every shared fixture is a single-model document whose one equation is the
/// bare array-level form the rule governs — a guard against the fixtures
/// drifting into a shape that no longer exercises it.
#[test]
fn shared_fixtures_are_bare_array_level_equations() {
    for name in [
        "bare_rank_lift.esm",
        "bare_mixed_rank_product.esm",
        "bare_axis_permuted_operand.esm",
        "broadcast_node_mixed_rank.esm",
    ] {
        let path = common::repo_fixture("valid/array_broadcast").join(name);
        let file = load(&read(&path)).unwrap_or_else(|e| panic!("{name}: {e}"));
        let models = file.models.as_ref().expect("models");
        assert_eq!(models.len(), 1, "{name}");
        let model: &Model = models.values().next().unwrap();
        assert_eq!(model.equations.len(), 1, "{name}");
        // A bare `D(dp)` LHS: no `index`, no `aggregate` — the whole array.
        let earthsci_ast::Expr::Operator(lhs) = &model.equations[0].lhs else {
            panic!("{name}: LHS is not an operator")
        };
        assert_eq!(lhs.op, "D", "{name}");
        assert!(
            matches!(lhs.args.first(), Some(earthsci_ast::Expr::Variable(v)) if v == "dp"),
            "{name}: LHS must be a bare whole-array D(dp)"
        );
    }
}
