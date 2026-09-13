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

use std::collections::HashMap;
use std::path::PathBuf;

use earthsci_ast::load_path;
use earthsci_ast::simulate_array::{ArrayCompiled, RhsStats};

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

fn compiled(name: &str) -> ArrayCompiled {
    let path = fixture(name);
    let file = load_path(&path).unwrap_or_else(|e| panic!("{name} does not load: {e}"));
    ArrayCompiled::from_file(&file).unwrap_or_else(|e| panic!("{name} does not compile: {e}"))
}

/// The production route: a scratch with the compiled tape installed, which is
/// what the solver's RHS closure carries.
fn taped_rhs(c: &ArrayCompiled, state: &[f64], t: f64) -> Vec<f64> {
    let params = c.debug_resolve_params(&HashMap::new());
    let mut scratch = c.debug_new_scratch_taped();
    assert!(
        scratch.has_tape(),
        "this test is about the TAPED path; without a tape it proves nothing"
    );
    let mut dy = vec![0.0f64; c.state_variable_names().len()];
    let mut stats = RhsStats::default();
    c.debug_eval_rhs_into(state, t, &params, &mut dy, &mut scratch, &mut stats);
    assert!(stats.taped_rules > 0, "no rule was taped");
    dy
}

/// The per-cell oracle — the legacy interpreter, unchanged by #255.
fn oracle_rhs(c: &ArrayCompiled, state: &[f64], t: f64) -> Vec<f64> {
    let (dy, _) = c.debug_eval_rhs(state, t, &HashMap::new(), true);
    dy
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
    let dy = taped_rhs(&compiled("bare_alias_observed.esm"), &[T_UNIFORM; 4], 0.0);
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
    let dy = taped_rhs(
        &compiled("bare_alias_in_derivative.esm"),
        &[T_UNIFORM; 4],
        0.0,
    );
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
        let c = compiled(name);
        for (state, t) in probe_points() {
            let taped = taped_rhs(&c, &state, t);
            let oracle = oracle_rhs(&c, &state, t);
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
    let aliased = compiled("bare_alias_observed.esm");
    let control = compiled("no_alias_control.esm");
    for (state, t) in probe_points() {
        let a = taped_rhs(&aliased, &state, t);
        let b = taped_rhs(&control, &state, t);
        for (k, (x, y)) in a.iter().zip(b.iter()).enumerate() {
            assert_eq!(
                x.to_bits(),
                y.to_bits(),
                "dy[{k}] at t={t}: aliased {x:e} vs inlined {y:e}"
            );
        }
    }
}
