//! Cross-language conformance: a test's `parameter_overrides` reach the
//! BUILD-TIME evaluation scope (esm-spec §6.6.5 "Build-time evaluation scope",
//! §11.4.1 coordinate-expression `ic`, §6.6 "keyed by local parameter name").
//!
//! Shared fixture + Julia-minted golden live under
//! `tests/conformance/pde_inline_ic_param_override/` (repo root); the Julia
//! runner (`conformance_pde_inline_ic_param_override_test.jl`) and the Python
//! runner (`test_pde_inline_ic_param_override_conformance.py`) gate the same
//! golden.
//!
//! Model `M` carries a parameter `A` (default 1.0) that appears ONLY inside
//! `ic(u) = A cos(pi x)` and inside the analytic `reference` of two assertions
//! — never in an equation. So an inline test overriding `A` can change the
//! answer through the build-time scope and through nothing else, which is what
//! makes the three tests (`A` defaulted / overridden to 0 / overridden to 2)
//! discriminate. State `v` is seeded by the parameter-FREE `ic(v) = cos(pi x)`
//! and is the independent anchor the `A`-dependent reference is measured
//! against, so a binding that ignored the override in BOTH the ic and the
//! reference cannot have the two errors cancel and still pass.
//!
//! The Rust array runtime strips the single-model `<namespace>.` prefix from
//! override keys (`canonicalize_override_keys`), so the local spelling
//! already bound here; this suite pins that against the reference binding.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string};
use std::collections::HashMap;
use std::fs;

use crate::common;
use crate::common::tier::{GoldenCheck, Tier};

#[test]
fn ic_param_override_matches_golden() {
    Tier::open("pde_inline_ic_param_override").check_all(&GoldenCheck {
        by_test_id: true,
        ..Default::default()
    });
}

/// Direct coverage of the naming contract the category gates: esm-spec §6.6
/// keys `parameter_overrides` by LOCAL parameter name, while flattening
/// qualifies it (`M.A`). Both spellings must reach the coordinate-expression
/// `ic` seed.
#[test]
fn local_and_qualified_override_keys_both_bind_the_build_scope() {
    let dir = common::category_dir("pde_inline_ic_param_override");
    let path = dir.join("fixtures/ic_param_override.esm");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let file = load_string(&text).expect("fixture loads");
    let mut opts = SolveOptions {
        alg: Alg::Erk,
        reltol: Some(1e-12),
        abstol: Some(1e-14),
        ..Default::default()
    };
    opts.saveat = Some(vec![0.0]);

    for key in ["A", "M.A"] {
        let mut params = HashMap::new();
        params.insert(key.to_string(), 0.0);
        let sol = earthsci_ast::esm_problem(
            &file,
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                p: params.clone(),
                u0: HashMap::new().clone(),
                rhs: earthsci_ast::Rhs::Always,
                ..Default::default()
            },
        )
        .and_then(|prob| earthsci_ast::solve(&prob, &opts))
        .unwrap_or_else(|e| panic!("{key}: simulate failed: {e}"));
        let cells = earthsci_ast::state_cells(&sol.state_variable_names, "u", "M");
        assert_eq!(cells.len(), 5);
        for (cell, row) in &cells {
            assert_eq!(sol.state[*row][0], 0.0, "{key}: cell {cell:?} not zeroed");
        }
    }
}
