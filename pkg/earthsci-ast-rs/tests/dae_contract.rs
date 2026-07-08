//! Integration tests for the RFC §12 DAE binding contract in the rust
//! binding. Exercises the trivial-factor preprocessor against real JSON
//! fixtures plus the two error paths (`E_NO_DAE_SUPPORT`, `E_NONTRIVIAL_DAE`).
//!
//! See `pkg/earthsci-ast-rs/tests/fixtures/dae/README.md` for
//! fixture provenance and the rust strategy per
//! `docs/rfcs/dae-binding-strategies.md`.

use earthsci_ast::{DiscretizeOptions, EsmFile, Expr, apply_dae_contract, discretize, load};

fn load_fixture(name: &str) -> EsmFile {
    let path = format!("tests/fixtures/dae/{name}.json");
    let src = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    load(&src).unwrap_or_else(|e| panic!("parse {path}: {e:?}"))
}

#[test]
fn pure_ode_fixture_stamps_ode_class() {
    let esm = load_fixture("pure_ode");
    let out = discretize(&esm, DiscretizeOptions { dae_support: true }).expect("pure ODE succeeds");

    assert_eq!(out.metadata.system_class.as_deref(), Some("ode"));
    let info = out.metadata.dae_info.as_ref().expect("dae_info stamped");
    assert_eq!(info.algebraic_equation_count, 0);
    assert_eq!(info.factored_equation_count, Some(0));
    assert_eq!(info.per_model.get("M").copied(), Some(0));
    assert_eq!(out.metadata.discretized_from.as_deref(), Some("pure_ode"));
}

#[test]
fn trivial_observed_fixture_factors_cleanly() {
    let esm = load_fixture("trivial_observed");
    let out = discretize(&esm, DiscretizeOptions { dae_support: true })
        .expect("trivial DAE factored to ODE");

    assert_eq!(out.metadata.system_class.as_deref(), Some("ode"));
    let info = out.metadata.dae_info.as_ref().expect("dae_info stamped");
    assert_eq!(info.algebraic_equation_count, 0);
    assert_eq!(info.factored_equation_count, Some(1));

    let models = out.models.as_ref().expect("models retained");
    let m = &models["M"];
    assert_eq!(m.equations.len(), 1, "algebraic eq removed after factoring");

    // The remaining equation is D(x, t) = -k * x^2 (y substituted to x^2).
    // Drill into the RHS and confirm that no `y` reference survives.
    fn contains_var(e: &Expr, v: &str) -> bool {
        match e {
            Expr::Variable(n) => n == v,
            Expr::Operator(node) => node.args.iter().any(|a| contains_var(a, v)),
            _ => false,
        }
    }
    assert!(
        !contains_var(&m.equations[0].rhs, "y"),
        "y must not appear in RHS after factoring; got {:?}",
        m.equations[0].rhs
    );
    assert!(
        contains_var(&m.equations[0].rhs, "x"),
        "x must appear in RHS (substituted from y = x^2)"
    );
}

#[test]
fn nontrivial_implicit_fixture_errors_nontrivial_dae() {
    let esm = load_fixture("nontrivial_implicit");
    let err = discretize(&esm, DiscretizeOptions { dae_support: true })
        .expect_err("implicit x^2+y^2=1 constraint is non-trivial");

    assert_eq!(err.code, "E_NONTRIVIAL_DAE");
    assert!(err.message.contains("Circle.equations"));
    assert!(err.message.contains("Julia"));
    assert!(err.message.contains("RFC §12"));
}

#[test]
fn trivial_observed_fixture_dae_disabled_errors_no_dae_support() {
    let esm = load_fixture("trivial_observed");
    let err = discretize(&esm, DiscretizeOptions { dae_support: false })
        .expect_err("dae_support=false aborts even for trivially factorable input");

    assert_eq!(err.code, "E_NO_DAE_SUPPORT");
    assert!(err.message.contains("models.M.equations"));
    assert!(err.message.contains("ESM_DAE_SUPPORT"));
}

#[test]
fn pure_ode_fixture_dae_disabled_succeeds() {
    // Guard against false-positive E_NO_DAE_SUPPORT emission on pure ODEs.
    let esm = load_fixture("pure_ode");
    let out = discretize(&esm, DiscretizeOptions { dae_support: false })
        .expect("pure ODE succeeds even with dae_support=false");

    assert_eq!(out.metadata.system_class.as_deref(), Some("ode"));
}

#[test]
fn apply_dae_contract_mutates_in_place() {
    // Contract-level (no-wrap) path: apply_dae_contract modifies the input
    // EsmFile directly. This keeps the door open for §11 pipeline authors
    // who want to thread DAE handling into a larger discretize() call.
    let mut esm = load_fixture("trivial_observed");
    let info = apply_dae_contract(&mut esm, true).expect("factored");
    assert_eq!(info.factored_equation_count, Some(1));
    assert_eq!(esm.metadata.system_class.as_deref(), Some("ode"));
    // `discretized_from` is NOT stamped by apply_dae_contract — that is the
    // job of the wrapping `discretize()` entry point.
    assert!(esm.metadata.discretized_from.is_none());
}
