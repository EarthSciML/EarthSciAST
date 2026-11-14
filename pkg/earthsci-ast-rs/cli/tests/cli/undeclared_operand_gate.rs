//! An operand bound by NOTHING is an error on EVERY route — CONFORMANCE_SPEC
//! §5.23 — including `esm simulate`, the route a person actually takes. The
//! library routes, and the account of the defect, are in `earthsci-ast`'s
//! `tests/undeclared_operand_gate.rs`.
//!
//! Gated on this crate's `diffsol` feature: a build with no time integrator
//! refuses `esm simulate`.

#![cfg(feature = "diffsol")]

/// The phrase both routes must produce. Pinned as a substring rather than
/// a whole message so the two are held to naming the SAME variable in the SAME
/// words (the build refuses it by the validator's `undefined_variable`, the
/// pipeline by its free-variable gate; both say "'<name>' referenced in") — an error that says only "build failed" would let the routes drift
/// apart again while both looked red.
const NAMED: &str = "'undeclaredFloor' referenced in";

/// `esm simulate` on the fixture must EXIT NON-ZERO and name the operand.
///
/// This is the route a person actually takes, and it is the one that was
/// silent: `simulate`'s static branch rebuilds with the pipeline on in order to
/// materialize an array observed at all, so a document with nothing to
/// integrate — every MOVES-shaped calculator — reached the defect without
/// anyone opting into anything. It wrote `clamped = 2` and exited 0.
///
/// Asserted at the process boundary rather than through the library because
/// that is where "the run succeeded" is decided: a previous verification here
/// reported an exit code that belonged to `tail`, not to the command.
#[test]
fn esm_simulate_exits_non_zero_and_names_the_operand() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_esm"))
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .args([
            "simulate",
            "../../../tests/fixtures/undeclared_operand/undeclared_operand_in_max.esm",
            "--time",
            "0",
        ])
        .output()
        .unwrap_or_else(|e| panic!("could not run the esm binary: {e}"));
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    assert!(
        !out.status.success(),
        "`esm simulate` SUCCEEDED on a document whose operand is declared nowhere. \
         Output was:\n{text}"
    );
    assert!(
        text.contains(NAMED),
        "`esm simulate` must name the undeclared operand; got:\n{text}"
    );
    assert!(
        !text.contains("clamped[1] = 2"),
        "`esm simulate` reported the laundered value; got:\n{text}"
    );
}
