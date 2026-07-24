//! End-to-end regression guard for DEEP expression-template chains
//! (esm-spec §9.6.4 Option B expand-at-build).
//!
//! `tests/fixtures/discretization/advection_1d_ppm_periodic.esm` is the
//! EarthSciDiscretizations 1-D periodic PPM advection problem
//! (`problems/advection_1d_ppm_periodic.esm` driving
//! `grids/cartesian_uniform_1d/rules/ppm_D_periodic`) with its whole
//! `expression_template_imports` chain — rule → `ppm_D_interior` → `ppm_flux`
//! → `ppm_face_value_mono` → `ppm_slope{,_mono}` → `ppm_limit_right` → grid —
//! resolved INLINE, so this crate can exercise a genuine high-order
//! reconstruction stencil without the sibling repository on disk.
//!
//! It exists because the Option-B `expand` pass silently CORRUPTED exactly
//! this shape of document: its pointer-identity memo keyed nodes by
//! `Rc::as_ptr` without retaining the key, so a freshly substituted template
//! body — dropped as soon as its expansion was spliced in — could have its
//! address recycled by the next allocation and alias a stale memo entry. The
//! visible symptom was an `args` array replaced by an unrelated operator
//! object, surfacing as the useless `data did not match any variant of
//! untagged enum Expr` at the final `EsmFile` deserialize. Every high-order
//! case (PPM 1-D/3-D, WENO5, upwind flux) failed to LOAD; nothing shallow did.
//!
//! The guard is deliberately end-to-end (load → expand → build → integrate):
//! the aliasing was invisible to any single-pass unit test and only a document
//! whose expansion is large enough to churn the allocator reproduces it.

use std::collections::{BTreeMap, HashMap};

use earthsci_ast::parse::load_path_with_options;
use earthsci_ast::simulate::{SimulateOptions, SolverChoice, simulate};
use earthsci_ast::types::Expr;

const FIXTURE: &str = "tests/fixtures/discretization/advection_1d_ppm_periodic.esm";

fn load_at(n: i64) -> earthsci_ast::EsmFile {
    let mut bindings: BTreeMap<String, i64> = BTreeMap::new();
    bindings.insert("N".to_string(), n);
    load_path_with_options(FIXTURE, &bindings)
        .unwrap_or_else(|e| panic!("loading the PPM problem at N={n} must succeed, got: {e}"))
}

/// Walk an expression, asserting no rewrite-target or template-reference op
/// survived the load, and count the nodes so the test can assert the chain
/// really did expand into something large.
fn assert_lowered(expr: &Expr, count: &mut usize) {
    let Expr::Operator(node) = expr else {
        *count += 1;
        return;
    };
    *count += 1;
    assert_ne!(
        node.op, "apply_expression_template",
        "load must leave no surviving template reference in the built IR"
    );
    assert!(
        !(node.op == "D" && node.wrt.as_deref() != Some("t")),
        "load must rewrite the spatial D away (rule ppm_D_periodic)"
    );
    for a in &node.args {
        assert_lowered(a, count);
    }
    for sub in [&node.expr, &node.lower, &node.upper, &node.filter, &node.key]
        .into_iter()
        .flatten()
    {
        assert_lowered(sub, count);
    }
    if let Some(values) = &node.values {
        for v in values {
            assert_lowered(v, count);
        }
    }
}

/// The regression proper: the PPM chain LOADS. Before the memo keep-alive fix
/// this failed in ~0.1 s with `data did not match any variant of untagged enum
/// Expr`.
#[test]
fn ppm_template_chain_loads_and_lowers() {
    let file = load_at(16);
    let model = file
        .models
        .as_ref()
        .and_then(|m| m.get("AdvectionPPM"))
        .expect("fixture declares model AdvectionPPM");

    let mut nodes = 0usize;
    let mut saw_time_derivative = false;
    for eq in &model.equations {
        if let Expr::Operator(lhs) = &eq.lhs
            && lhs.op == "D"
            && lhs.wrt.as_deref() == Some("t")
        {
            saw_time_derivative = true;
        }
        assert_lowered(&eq.rhs, &mut nodes);
    }
    assert!(saw_time_derivative, "fixture has a u_t equation");
    assert!(
        nodes > 5_000,
        "the PPM chain should expand into a large tree; got only {nodes} nodes \
         (a suspiciously small expansion means the chain did not resolve)"
    );
}

/// Expansion must be a pure function of the document. The corrupted memo was
/// allocator-dependent, so a second load in the same process could differ from
/// the first; equality across repeated loads pins that down independently of
/// whether any one load happens to trip the aliasing.
#[test]
fn ppm_expansion_is_deterministic_across_loads() {
    let first = serde_json::to_value(load_at(16)).expect("loaded file serializes");
    for i in 1..3 {
        let again = serde_json::to_value(load_at(16)).expect("loaded file serializes");
        assert_eq!(first, again, "load #{i} of the PPM chain differed from #0");
    }
}

/// …and the loaded problem actually integrates. A couple of steps of the
/// periodic semi-discrete PPM flux difference: every value stays finite, the
/// tracer moves, and the telescoping flux difference conserves the mean
/// (the discrete sine has analytic mean 0 over the full period).
#[test]
fn ppm_problem_simulates_a_few_steps() {
    let n = 16i64;
    let file = load_at(n);
    let opts = SimulateOptions {
        solver: SolverChoice::Erk,
        reltol: 1e-8,
        abstol: 1e-10,
        output_times: Some(vec![0.0, 0.005, 0.01]),
        ..Default::default()
    };
    let sol = simulate(&file, (0.0, 0.01), &HashMap::new(), &HashMap::new(), &opts)
        .expect("the PPM problem integrates");

    assert_eq!(sol.time.len(), 3);
    for (row, name) in sol.state.iter().zip(&sol.state_variable_names) {
        for (k, v) in row.iter().enumerate() {
            assert!(v.is_finite(), "{name} is not finite at output time {k}");
        }
    }

    // The tracer cells of `u` — `state_variable_names` also carries the
    // model-qualified scalar bookkeeping rows the builder emits.
    let cells: Vec<&Vec<f64>> = sol
        .state
        .iter()
        .zip(&sol.state_variable_names)
        .filter(|(_, name)| {
            name.rsplit('.')
                .next()
                .is_some_and(|leaf| leaf.starts_with("u["))
        })
        .map(|(row, _)| row)
        .collect();
    assert_eq!(
        cells.len(),
        n as usize,
        "one `u` cell per grid cell at N={n}; state rows are {:?}",
        sol.state_variable_names
    );

    let mean_at =
        |k: usize| -> f64 { cells.iter().map(|row| row[k]).sum::<f64>() / cells.len() as f64 };
    assert!(
        mean_at(2).abs() < 1e-9,
        "periodic PPM must conserve the (zero) mean; got {}",
        mean_at(2)
    );

    let moved: f64 = cells
        .iter()
        .map(|row| (row[2] - row[0]).abs())
        .fold(0.0, f64::max);
    assert!(
        moved > 1e-3,
        "the tracer should have advected over t=0.01; max |Δu| was {moved}"
    );
}
