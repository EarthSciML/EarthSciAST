//! Issue #234: a bare alias between two unknowns, read by a per-cell rule.
//!
//! An observed whose whole body is a bare variable (`Tsfc = Tsfc_raw`) emits
//! nothing into its home chunk, and the export pass used to append its
//! `Instr::Export` at the END of the cadence stream — after the
//! `Instr::Fallback` of the later rule that reads it, which then read the
//! preallocated `0.0`. PR #255 fixed that by opening the home chunk at the
//! rule's own place in rule order.
//!
//! #255 was written for issue #207, whose fixtures are in
//! `coupled_const_array_fold.rs`: a const-array gather subscripted by the
//! ghost zero, which raises `E_TREEWALK_CONSTARRAY_OOB` and is therefore
//! LOUD. The shape here is the SILENT one — the zero lands in a relaxation
//! term as a plausible number, so the model integrates on and merely gives
//! wrong answers. Nothing covered it, which is why #234 was reported
//! separately, four days later, as a solver failure at 59 levels.
//!
//! Four cells is enough: the defect never depended on the grid size, only on
//! whether the corrupted right-hand side happened to defeat the Newton solve.

#![cfg(not(target_arch = "wasm32"))]

use std::path::PathBuf;

use earthsci_ast::{Compiler, ProblemOptions, Rhs, esm_problem};

use crate::common::rhs::ProblemRhs;

/// The four cells' initial temperature, and the forcing's mean: at `t = 0` the
/// column is isothermal at exactly the surface value.
const T_UNIFORM: f64 = 288.0;

/// `rlx` in the fixtures. The ghost zero made cell 1's tendency
/// `rlx * (0 - 288) = -0.288 K/s` instead of `0`.
const RLX: f64 = 1.0e-3;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/alias_export_order")
        .join(name)
}

/// The fixture's right-hand side under `compiler`, through the public program.
fn rhs(name: &str, compiler: Compiler) -> ProblemRhs {
    // The fixtures leave their states' starting values to the caller; the
    // probes pass the state explicitly, so any value builds the Problem.
    let text = std::fs::read_to_string(fixture(name)).expect("the fixture reads");
    let mut doc: serde_json::Value = serde_json::from_str(&text).expect("the fixture parses");
    crate::common::supply_state_defaults(&mut doc);
    let prob = esm_problem(
        &doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            rhs: Rhs::Always,
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{name} does not build under {compiler}: {e}"));
    ProblemRhs::new(&prob)
}

/// The production route: the strict tape, which refuses the program if any
/// rule leaves it.
fn taped(name: &str) -> ProblemRhs {
    rhs(name, Compiler::Native)
}

/// The per-cell oracle.
fn oracle(name: &str) -> ProblemRhs {
    rhs(name, Compiler::Interpreter)
}

/// States and times that exercise the alias at its mean and away from it.
fn probe_points() -> Vec<(Vec<f64>, f64)> {
    vec![
        (vec![T_UNIFORM; 4], 0.0),
        (vec![T_UNIFORM; 4], 4000.0),
        (vec![287.0, 288.5, 289.25, 286.75], 0.0),
        (vec![287.0, 288.5, 289.25, 286.75], 12_000.0),
    ]
}

/// The value test, independent of the oracle: at `t = 0` the column is
/// isothermal at the surface temperature, so every tendency is exactly zero.
///
/// Before #255 this read `-0.288 K/s` in cell 1 — `rlx * (0 - 288)`, the
/// signature of the alias reaching the consumer as the preallocated zero.
#[test]
fn the_alias_value_reaches_a_per_cell_observed() {
    let dy = taped("bare_alias_observed.esm").eval(&[T_UNIFORM; 4], 0.0);
    for (k, v) in dy.iter().enumerate() {
        assert!(
            v.abs() < 1e-12,
            "cell {k} tendency {v:e}, want 0 — a ghost zero for the alias gives {:e} in cell 0",
            -RLX * T_UNIFORM
        );
    }
}

/// The same alias read straight from the `D(T, t)` rule body, with no
/// intermediate per-cell observed. Both spellings were corrupted.
#[test]
fn the_alias_value_reaches_a_derivative_rule() {
    let dy = taped("bare_alias_in_derivative.esm").eval(&[T_UNIFORM; 4], 0.0);
    for (k, v) in dy.iter().enumerate() {
        assert!(
            v.abs() < 1e-12,
            "cell {k} tendency {v:e}, want 0 — a ghost zero for the alias gives {:e} in cell 0",
            -RLX * T_UNIFORM
        );
    }
}

/// The structural test: whatever the numbers are, the taped path and the
/// per-cell oracle must agree bitwise. This is the `ESS_TAPE_CHECK=1`
/// invariant, pinned for this shape without the environment variable, and it
/// keeps biting even if someone changes the fixture's arithmetic.
#[test]
fn the_taped_path_agrees_with_the_oracle() {
    for name in ["bare_alias_observed.esm", "bare_alias_in_derivative.esm"] {
        let (mut tape, mut walk) = (taped(name), oracle(name));
        for (state, t) in probe_points() {
            let taped = tape.eval(&state, t);
            let oracle = walk.eval(&state, t);
            for (k, (a, b)) in taped.iter().zip(oracle.iter()).enumerate() {
                assert_eq!(
                    a.to_bits(),
                    b.to_bits(),
                    "{name}: dy[{k}] diverged at t={t}: tape {a:e} vs oracle {b:e}"
                );
            }
        }
    }
}

/// The alias is semantically inert, so removing it must not change a single
/// number. A failure here means the fixtures drifted apart, not that the
/// export ordering regressed.
#[test]
fn the_alias_changes_no_number_against_the_inlined_control() {
    let mut aliased = taped("bare_alias_observed.esm");
    let mut control = taped("no_alias_control.esm");
    for (state, t) in probe_points() {
        let a = aliased.eval(&state, t);
        let b = control.eval(&state, t);
        for (k, (x, y)) in a.iter().zip(b.iter()).enumerate() {
            assert_eq!(
                x.to_bits(),
                y.to_bits(),
                "dy[{k}] at t={t}: aliased {x:e} vs inlined {y:e}"
            );
        }
    }
}
