//! Value invention whose key columns come from the caller (`const_arrays`) and
//! whose scalar inputs come from `p`, through `esm_problem`, under both
//! compilers. Each expected value is the Julia reference's for the same
//! document and data (`EarthSciAST.jl/test/value_invention_frontdoor_test.jl`
//! and `vi_on_drive_test.jl` supply the same arrays), and native agrees with the
//! interpreter bit for bit.
//!
//! Without its data each document is refused by name — a shaped parameter with
//! no value (`E_TREEWALK_MISSING_DATA`), or the derived set it cannot size
//! (`derived_index_set_unmaterialized`) — never as an `unevaluable_operator`.

#![cfg(all(not(target_arch = "wasm32"), feature = "solve"))]

use earthsci_ast::simulate_array::RhsStats;
use earthsci_ast::{Compiler, EsmProblem, ProblemOptions, Rhs, esm_problem, observed_field};
use ndarray::{ArrayD, IxDyn};
use std::collections::HashMap;

use crate::common;

fn arr(shape: &[usize], v: &[f64]) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(shape), v.to_vec()).unwrap()
}

fn build(
    rel: &str,
    arrays: &[(&str, ArrayD<f64>)],
    p: &[(&str, f64)],
    model: Option<&str>,
    compiler: Compiler,
    rhs: Rhs,
) -> Result<EsmProblem, String> {
    let opts = ProblemOptions {
        compiler: Some(compiler),
        rhs,
        model_name: model.map(str::to_string),
        const_arrays: arrays
            .iter()
            .map(|(k, v)| (k.to_string(), v.clone()))
            .collect(),
        p: p.iter().map(|(k, v)| (k.to_string(), *v)).collect(),
        ..Default::default()
    };
    // These documents leave their states' starting values to the harness
    // (esm-spec §11.4).
    let text = std::fs::read_to_string(common::repo_fixture(rel)).map_err(|e| e.to_string())?;
    let mut doc: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    common::supply_state_defaults(&mut doc);
    esm_problem(&doc, (0.0, 1.0), opts).map_err(|e| e.to_string())
}

/// `dy` at `u = 1 + 0.1 sin(0.37 k)` under both compilers: the same bits, and
/// keyed by state name.
fn rhs_both(rel: &str, arrays: &[(&str, ArrayD<f64>)], p: &[(&str, f64)]) -> HashMap<String, f64> {
    let mut out: Vec<(Vec<String>, Vec<f64>)> = Vec::new();
    for c in [Compiler::Interpreter, Compiler::Native] {
        let prob = build(rel, arrays, p, None, c, Rhs::Always)
            .unwrap_or_else(|e| panic!("{rel} [{}]: {e}", c.as_str()));
        let comp = prob.debug_array_compiled().expect("a right-hand side");
        let names = comp.state_variable_names();
        let state: Vec<f64> = (0..names.len())
            .map(|k| 1.0 + 0.1 * (0.37 * k as f64).sin())
            .collect();
        let dy = if c == Compiler::Native {
            // The taped right-hand side, with no rule off the tape.
            let _precision = comp.debug_precision_env().enter();
            let params = comp.debug_resolve_params(prob.p());
            let mut dy = vec![0.0f64; state.len()];
            let mut scratch = comp
                .debug_new_scratch_taped()
                .expect("the tape lowers every rule");
            let mut stats = RhsStats::default();
            comp.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
            assert!(scratch.has_tape(), "{rel}: the tape declined a rule");
            dy
        } else {
            comp.debug_eval_rhs(&state, 0.0, prob.p(), true).0
        };
        out.push((names.to_vec(), dy));
    }
    assert_eq!(out[0].0, out[1].0, "{rel}: state order");
    let bits = |v: &[f64]| v.iter().map(|x| x.to_bits()).collect::<Vec<_>>();
    assert_eq!(bits(&out[0].1), bits(&out[1].1), "{rel}: native dy differs");
    out[0]
        .0
        .iter()
        .cloned()
        .zip(out[0].1.iter().copied())
        .collect()
}

/// A state-free document's build-time field under both compilers.
fn field_both(
    rel: &str,
    arrays: &[(&str, ArrayD<f64>)],
    p: &[(&str, f64)],
    model: Option<&str>,
    name: &str,
) -> Vec<f64> {
    let mut out: Vec<Vec<f64>> = Vec::new();
    for c in [Compiler::Interpreter, Compiler::Native] {
        let prob = build(rel, arrays, p, model, c, Rhs::Auto)
            .unwrap_or_else(|e| panic!("{rel} [{}]: {e}", c.as_str()));
        let f = observed_field(&prob, name)
            .unwrap_or_else(|e| panic!("{rel} [{}] {name}: {e}", c.as_str()));
        out.push(f.iter().copied().collect());
    }
    assert_eq!(out[0], out[1], "{rel} {name}: compilers disagree");
    out.pop().unwrap()
}

fn extent(rel: &str, arrays: &[(&str, ArrayD<f64>)], p: &[(&str, f64)], faq: &str) -> i64 {
    let mut out = Vec::new();
    for c in [Compiler::Interpreter, Compiler::Native] {
        let prob = build(rel, arrays, p, None, c, Rhs::Auto)
            .unwrap_or_else(|e| panic!("{rel} [{}]: {e}", c.as_str()));
        out.push(prob.extents()[faq]);
    }
    assert_eq!(out[0], out[1]);
    out[0]
}

const EDGE: &str = "valid/faq/edge_enumeration_area_eff.esm";

fn edge_arrays() -> Vec<(&'static str, ArrayD<f64>)> {
    vec![
        ("n_verts_on_face", arr(&[2], &[3., 3.])),
        ("verts_on_face", arr(&[2, 3], &[1., 2., 3., 2., 3., 4.])),
        ("n_edges_on_cell", arr(&[2], &[3., 3.])),
        ("edges_on_cell", arr(&[2, 3], &[1., 2., 3., 3., 4., 5.])),
        ("dc", arr(&[5], &[2., 3., 5., 7., 11.])),
        ("dv", arr(&[5], &[13., 17., 19., 23., 29.])),
    ]
}

#[test]
fn edge_enumeration_keys_size_the_derived_edge_set() {
    // Undirected edges, keyed by the `pair_key` template; five of them over
    // the two triangles. area_eff[i] = 1/4 sum over the cell's edges of dc dv.
    let dy = rhs_both(EDGE, &edge_arrays(), &[]);
    assert_eq!(dy["area_eff[1]"], 43.0);
    assert_eq!(dy["area_eff[2]"], 143.75);
}

#[test]
fn distinct_edge_ranks_build_with_their_edge_endpoints() {
    let (mut lo, mut hi) = (Vec::new(), Vec::new());
    for f in 1..=12usize {
        for l in 1..=3usize {
            let a = ((f + l - 1) % 5 + 1) as f64;
            lo.push(a);
            hi.push(a + 1.0);
        }
    }
    let arrays = [
        ("edge_lo", arr(&[12, 3], &lo)),
        ("edge_hi", arr(&[12, 3], &hi)),
    ];
    let dy = rhs_both("valid/faq/skolem_distinct_rank.esm", &arrays, &[]);
    assert_eq!(dy["u"], -1.0);
}

#[test]
fn composite_keys_count_three_members() {
    let arrays = [("engTechID", arr(&[4], &[1., 2., 1., 2.]))];
    let rel = "conformance/value_invention_materialize/fixtures/absent_key_factor_template.esm";
    assert_eq!(extent(rel, &arrays, &[], "key_set"), 3);
    assert_eq!(
        field_both(rel, &arrays, &[], None, "distinctKeyCount"),
        vec![3.0]
    );
}

#[test]
fn a_p_override_reaches_the_bin_width() {
    // dx, dy declare no default: the caller's `p` is the only bin width.
    let arrays = [
        ("src_lon", arr(&[4], &[0.2, 1.2, 2.2, 3.2])),
        ("src_lat", arr(&[4], &[0.; 4])),
        ("tgt_lon", arr(&[4], &[0.2, 1.2, 2.2, 9.9])),
        ("tgt_lat", arr(&[4], &[0.; 4])),
    ];
    let p = [("dx", 1.0), ("dy", 1.0)];
    let rel = "valid/geometry/bin_skolem_spatial_join.esm";
    assert_eq!(extent(rel, &arrays, &p, "candidate_set"), 3);
    // A wider bin puts every cell but the last target in one bin.
    assert_eq!(
        extent(rel, &arrays, &[("dx", 5.0), ("dy", 1.0)], "candidate_set"),
        12
    );
}

#[test]
fn nearest_generator_assignment_reads_the_selected_models_arrays() {
    // Generators at x = 0, 1, 2; point 3 is equidistant from 2 and 3 and takes
    // the smaller id. A bare key names the selected model's parameter.
    let arrays = [
        ("gx", arr(&[3], &[0., 1., 2.])),
        ("gy", arr(&[3], &[0., 0., 0.])),
        ("px", arr(&[4], &[0., 1., 1.5, 2.])),
        ("py", arr(&[4], &[0., 0.5, 0., 0.])),
    ];
    let rel = "valid/faq/nearest_generator_argmin.esm";
    let model = Some("NearestGeneratorArgmin");
    assert_eq!(
        field_both(rel, &arrays, &[], model, "assign"),
        vec![1., 2., 2., 3.]
    );
}

#[test]
fn nearest_generator_centroid_reads_the_assignment() {
    let arrays = [
        ("gx", arr(&[3], &[0., 1., 2.])),
        ("px", arr(&[4], &[0., 0.75, 1.25, 2.])),
        ("rho", arr(&[4], &[1., 1., 3., 4.])),
    ];
    let rel = "valid/faq/nearest_generator_centroid.esm";
    assert_eq!(
        field_both(rel, &arrays, &[], None, "assign"),
        vec![1., 2., 2., 3.]
    );
    assert_eq!(
        field_both(rel, &arrays, &[], None, "num"),
        vec![0.0, 4.5, 8.0]
    );
    assert_eq!(
        field_both(rel, &arrays, &[], None, "den"),
        vec![1.0, 4.0, 4.0]
    );
    assert_eq!(
        field_both(rel, &arrays, &[], None, "centroid"),
        vec![0.0, 1.125, 2.0]
    );
}

#[test]
fn without_its_data_a_producer_is_refused_by_name() {
    for c in [Compiler::Interpreter, Compiler::Native] {
        let e = build(EDGE, &[], &[], None, c, Rhs::Always)
            .err()
            .unwrap_or_else(|| panic!("{EDGE} built with no data"));
        assert!(
            e.contains("derived_index_set_unmaterialized") || e.contains("E_TREEWALK_MISSING_DATA"),
            "{EDGE} [{}]: {e}",
            c.as_str()
        );
        assert!(!e.contains("unevaluable_operator"), "{EDGE}: {e}");
    }
}
