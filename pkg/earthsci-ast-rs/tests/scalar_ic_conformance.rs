//! Cross-language conformance: 0-D (`scalar`) `ic` equations seed their state
//! (esm-spec §11.4 "Initial conditions (the `ic` op)", its "Run-time
//! overrides", §6.6.5 "Build-time evaluation scope").
//!
//! Shared fixtures + Julia-minted goldens live under
//! `tests/conformance/scalar_ic/` (repo root); the Julia runner
//! (`conformance_scalar_ic_test.jl`) and the Python runner
//! (`test_scalar_ic_conformance.py`) gate the same goldens.
//!
//! A binding that drops a 0-D `ic` does not error: the state silently starts
//! at its declared `default`. Every state in `scalar_ic.esm` declares a
//! `default` that DIFFERS from its `ic` so that substitution cannot hide, and
//! `y` integrates `D(y)/dt = u` so the seeded value must reach the trajectory
//! too. `scalar_ic_in_array_model.esm` re-runs the contract inside the array
//! runtime.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string};
use std::collections::HashMap;
use std::fs;

use crate::common;
use crate::common::tier::{GoldenCheck, Tier};

#[test]
fn scalar_ic_matches_golden() {
    Tier::open("scalar_ic").check_all(&GoldenCheck {
        by_test_id: true,
        ..Default::default()
    });
}

/// Direct coverage of the esm-spec §11.4 seeding precedence on the scalar
/// interpreter: an explicit `initial_conditions` entry wins, else the state's
/// own `ic` equation (parameters bound to their override-or-default values,
/// §6.6.5), else the declared `default`.
#[test]
fn scalar_ic_seeding_precedence() {
    let dir = common::category_dir("scalar_ic");
    let path = dir.join("fixtures/scalar_ic.esm");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let file = load_string(&text).expect("fixture loads");
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: Some(1e-12),
        abstol: Some(1e-14),
        saveat: Some(vec![0.0]),
        ..Default::default()
    };

    let at0 = |sol: &earthsci_ast::Solution, name: &str| -> f64 {
        // See `Solution::index_of`: either spelling resolves.
        let i = sol
            .index_of(name)
            .unwrap_or_else(|| panic!("no state {name} in {:?}", sol.state_variable_names));
        sol.state[i][0]
    };

    // (1) Defaults: each state takes its own ic; `z` declares none and takes 7.
    let sol = earthsci_ast::esm_problem(
        &file,
        (0.0, 1.0),
        earthsci_ast::ProblemOptions {
            p: HashMap::new().clone(),
            u0: HashMap::new().clone(),
            rhs: earthsci_ast::Rhs::Always,
            ..Default::default()
        },
    )
    .and_then(|prob| earthsci_ast::solve(&prob, &opts))
    .expect("defaults simulate");
    assert_eq!(at0(&sol, "M.u"), 3.0);
    assert_eq!(at0(&sol, "M.q"), 2.0);
    assert_eq!(at0(&sol, "M.w"), 4.0);
    assert_eq!(at0(&sol, "M.z"), 7.0);

    // (2) A parameter override reaches the ic's build-time scope, under either
    // spelling of the key (§6.6.2).
    for key in ["A", "M.A"] {
        let params = HashMap::from([(key.to_string(), 10.0)]);
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
        assert_eq!(at0(&sol, "M.w"), 20.0, "{key}");
        assert_eq!(at0(&sol, "M.u"), 3.0, "{key}: parameter-free ic moved");
    }

    // (3) A run-time `initial_conditions` entry beats the ic equation.
    for key in ["u", "M.u"] {
        let ics = HashMap::from([(key.to_string(), 9.0)]);
        let sol = earthsci_ast::esm_problem(
            &file,
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                p: HashMap::new().clone(),
                u0: ics.clone(),
                rhs: earthsci_ast::Rhs::Always,
                ..Default::default()
            },
        )
        .and_then(|prob| earthsci_ast::solve(&prob, &opts))
        .unwrap_or_else(|e| panic!("{key}: simulate failed: {e}"));
        assert_eq!(at0(&sol, "M.u"), 9.0, "{key}");
        assert_eq!(at0(&sol, "M.w"), 4.0, "{key}: unnamed state lost its ic");
    }
}

/// esm 2.5.0 (esm-spec §11.4.3, §11.4.4): the old sequential reading of
/// `faq`-valued initialization equations is gone. Migrated, `u ~ A*i + v` reads
/// `ic(v)` and `v ~ 3*u` (cells 2..3) reads `ic(u)`: the two determine each
/// other, v's cells 1 and 4 are determined by nothing (a `default` is not an
/// equation of the system), so both compilers refuse the system — as
/// unbalanced, or, with a `u0` that balances it, as an implicit (cyclic)
/// system — rather than seed it in document order.
#[test]
fn faq_initialization_equations_seed_in_order_on_both_compilers() {
    use earthsci_ast::{Compiler, ProblemOptions, Rhs, esm_problem};
    let faq = |ranges: serde_json::Value, expr: serde_json::Value| {
        serde_json::json!({"op": "faq", "args": [], "output_idx": ["i"],
                           "ranges": ranges, "expr": expr})
    };
    let idx = |v: &str| serde_json::json!({"op": "index", "args": [v, "i"]});
    let d = |v: &str| serde_json::json!({"op": "D", "wrt": "t", "args": [idx(v)]});
    let all = serde_json::json!({"i": [1, 4]});
    let doc = serde_json::json!({
        "esm": "2.0.0",
        "metadata": {"name": "faq_init_order"},
        "index_sets": {"x": {"kind": "interval", "size": 4}},
        "models": {"M": {
            "variables": {
                "A": {"type": "parameter", "units": "1", "default": 0.25},
                "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
                "v": {"type": "unknown", "units": "1", "shape": ["x"], "default": 2.0}
            },
            "equations": [
                {"lhs": faq(all.clone(), d("u")), "rhs": faq(all.clone(), serde_json::json!(0))},
                {"lhs": faq(all.clone(), d("v")), "rhs": faq(all.clone(), serde_json::json!(0))}
            ],
            "initialization_equations": [
                // u = A*i + v, reading v's default (or the caller's value).
                {"lhs": "u", "rhs": faq(all.clone(), serde_json::json!(
                    {"op": "+", "args": [{"op": "*", "args": ["A", "i"]}, idx("v")]}))},
                // v = 3*u over cells 2..3, reading the u just seeded.
                {"lhs": "v", "rhs": faq(serde_json::json!({"i": [2, 3]}), serde_json::json!(
                    {"op": "*", "args": [3.0, idx("u")]}))}
            ]
        }}
    });
    let file = load_string(&doc.to_string()).expect("document loads");
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        for u0 in [&[][..], &[("v[1]", 10.0), ("u[3]", -1.0)][..]] {
            let err = esm_problem(
                &file,
                (0.0, 1.0),
                ProblemOptions {
                    rhs: Rhs::Always,
                    compiler: Some(compiler),
                    u0: u0.iter().map(|&(k, v)| (k.to_string(), v)).collect(),
                    ..Default::default()
                },
            )
            .err()
            .unwrap_or_else(|| panic!("{compiler:?} {u0:?}: the system is refused"));
            // Unbalanced without a `u0`; with one, balanced but cyclic, so a
            // truly implicit system this binding cannot solve.
            let e = err.to_string();
            assert!(
                e.contains("ic_system_unbalanced") || e.contains("unsupported_construct"),
                "{compiler:?} {u0:?}: {e}"
            );
        }
    }
}

/// esm-spec §6.2: a `faq`-valued initialization equation seeds the initial
/// state on every build route. A document of two models is flattened before it
/// is compiled, so the equation reaches the build through the flattened
/// system, under its namespaced names (`M.u`); a subsystem's is mounted with
/// it. The seeded cells are the ones the one-model document gets.
#[test]
fn faq_initialization_equations_seed_a_flattened_document() {
    use earthsci_ast::{ProblemOptions, Rhs, esm_problem, solve};
    let faq = |expr: serde_json::Value| {
        serde_json::json!({"op": "faq", "args": [], "output_idx": ["i"],
                           "ranges": {"i": {"from": "x"}}, "expr": expr})
    };
    let idx = |v: &str| serde_json::json!({"op": "index", "args": [v, "i"]});
    let d = |v: &str| serde_json::json!({"op": "D", "wrt": "t", "args": [idx(v)]});
    let model = |init_rhs: serde_json::Value| {
        serde_json::json!({
            "variables": {
                "A": {"type": "parameter", "units": "1", "default": 0.25},
                "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0}
            },
            "equations": [{"lhs": faq(d("u")), "rhs": faq(serde_json::json!(0))}],
            "initialization_equations": [{"lhs": "u", "rhs": faq(init_rhs)}]
        })
    };
    let mut m = model(serde_json::json!({"op": "*", "args": ["A", "i"]}));
    m["subsystems"] = serde_json::json!({
        "Sub": model(serde_json::json!({"op": "+", "args": ["A", "i"]}))
    });
    let doc = |two: bool| {
        let mut models = serde_json::json!({"M": m.clone()});
        if two {
            models["Other"] = serde_json::json!({
                "variables": {"y": {"type": "unknown", "units": "1", "default": 5.0}},
                "equations": [{"lhs": {"op": "D", "wrt": "t", "args": ["y"]}, "rhs": 0}]
            });
        }
        serde_json::json!({
            "esm": "2.0.0",
            "metadata": {"name": "faq_init_flattened"},
            "index_sets": {"x": {"kind": "interval", "size": 3}},
            "models": models
        })
    };
    let u0 = |two: bool| -> Vec<(String, f64)> {
        let file = load_string(&doc(two).to_string()).expect("document loads");
        let prob = esm_problem(
            &file,
            (0.0, 1.0),
            ProblemOptions {
                rhs: Rhs::Always,
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("builds (two models: {two}): {e}"));
        let sol = solve(
            &prob,
            &SolveOptions {
                saveat: Some(vec![0.0]),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("solves (two models: {two}): {e}"));
        sol.state_variable_names
            .iter()
            .zip(&sol.state)
            .filter(|(n, _)| n.starts_with("M."))
            .map(|(n, row)| (n.clone(), row[0]))
            .collect()
    };
    let expected: Vec<(String, f64)> = [
        ("M.u[1]", 0.25),
        ("M.u[2]", 0.5),
        ("M.u[3]", 0.75),
        ("M.Sub.u[1]", 1.25),
        ("M.Sub.u[2]", 2.25),
        ("M.Sub.u[3]", 3.25),
    ]
    .iter()
    .map(|(n, v)| (n.to_string(), *v))
    .collect();
    let sorted = |mut v: Vec<(String, f64)>| {
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v
    };
    assert_eq!(sorted(u0(false)), sorted(expected.clone()), "one model");
    assert_eq!(sorted(u0(true)), sorted(expected), "two models");
}
