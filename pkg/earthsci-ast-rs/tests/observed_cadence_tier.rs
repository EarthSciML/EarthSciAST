//! Cadence-tier classification for observed materialization (the DISCRETE-tier
//! fix). The array driver materializes observeds in three cadence tiers
//! (`cadence.rs` lattice `CONST ⊏ DISCRETE ⊏ CONTINUOUS`):
//!   * CONST      — once at setup;
//!   * DISCRETE   — once per cadence segment (state-free & `t`-free, but reaches
//!                  a refreshed forcing buffer, so constant *within* a segment);
//!   * CONTINUOUS — every RHS step (reaches `t` or state).
//!
//! The bug this guards against: collapsing DISCRETE into CONTINUOUS, which
//! recomputes the per-cell conservative-regrid observeds every solver step
//! instead of once per segment (the dominant cost of a coupled loader model).

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::load;
use earthsci_ast::simulate_array::ArrayCompiled;

/// A model with two algebraic (eliminated) array observeds:
///   * `g[i] := f[i] * 2`  — `f` is an undeclared name (resolves via the forcing
///     buffer at runtime); state-free & `t`-free → DISCRETE.
///   * `h[i] := u[i] * 2`  — reads the integrated state `u` → CONTINUOUS.
/// plus the state `D(u[i]) = g[i] + h[i]`.
const MODEL: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "cadence_tiers"},
 "models": {"M": {
   "variables": {
     "u": {"type": "state", "shape": ["i"]},
     "g": {"type": "state", "shape": ["i"]},
     "h": {"type": "state", "shape": ["i"]}
   },
   "equations": [
    {"lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "index", "args": ["g", "i"]}, "ranges": {"i": [1, 3]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "*", "args": [{"op": "index", "args": ["f", "i"]}, 2]}}},
    {"lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "index", "args": ["h", "i"]}, "ranges": {"i": [1, 3]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "*", "args": [{"op": "index", "args": ["u", "i"]}, 2]}}},
    {"lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, 3]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "+", "args": [
               {"op": "index", "args": ["g", "i"]},
               {"op": "index", "args": ["h", "i"]}]}}}
   ]
 }}
}"#;

fn has(v: &[String], name: &str) -> bool {
    v.iter().any(|n| n == name || n.ends_with(&format!(".{name}")))
}

#[test]
fn forcing_derived_state_free_observed_is_discrete_not_continuous() {
    let file = load(MODEL).expect("load model");
    let compiled = ArrayCompiled::from_file(&file).expect("compile model");

    // `f` is the discrete (refreshed) forcing field.
    let (const_, discrete, continuous) = compiled.debug_cadence_partition(&["f".to_string()]);

    // `g` reaches the discrete forcing `f` but neither `t` nor state → DISCRETE:
    // materialized once per segment, NOT every step.
    assert!(
        has(&discrete, "g"),
        "g should be DISCRETE (per-segment), got const={const_:?} discrete={discrete:?} continuous={continuous:?}"
    );
    assert!(!has(&continuous, "g"), "g must not be CONTINUOUS: {continuous:?}");

    // Critically, `g` must NOT be CONST: a discrete forcing buffer is refreshed
    // between segments, so freezing `g` at setup would read a stale first record.
    // It is DISCRETE — re-materialized once per segment against the fresh buffer.
    assert!(
        !has(&const_, "g"),
        "g reaches a DISCRETE forcing, so it must refresh per segment, not freeze at setup: {const_:?}"
    );

    // `h` reads the state `u` → CONTINUOUS: re-evaluated every step.
    assert!(
        has(&continuous, "h"),
        "h should be CONTINUOUS, got continuous={continuous:?}"
    );
    assert!(!has(&discrete, "h"), "h must not be DISCRETE: {discrete:?}");
}
