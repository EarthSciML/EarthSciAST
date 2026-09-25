//! Tape lowerings whose length does not depend on the grid size.
//!
//! Three document shapes used to lower to a tape that grew with N:
//!
//!   * a whole-array derivative with no array producer on its right side
//!     (`D(u) = -k*u + s` over a shaped `u`) expanded into one scalar rule per
//!     cell;
//!   * a prefix scan unrolled into one step, and one full-box region write,
//!     per scanned position;
//!   * a contraction unrolled into one term per contraction tuple.
//!
//! Each now lowers to a fixed number of instructions. What is pinned here, for
//! each shape and at two sizes: the tape has the same length at both, no rule
//! leaves the tape, and the taped right-hand side is BIT-identical to the
//! per-cell oracle (the interpreter) at a state chosen so that a re-associated
//! fold would show in the low bits.

use earthsci_ast::load_string;
use earthsci_ast::simulate_array::{ArrayCompiled, RhsStats};
use serde_json::{Value, json};
use std::collections::HashMap;

/// A state whose elements span many orders of magnitude and both signs, so a
/// sum folded in a different order differs in its low bits.
fn probe_state(n: usize) -> Vec<f64> {
    (0..n)
        .map(|k| {
            let sign = if k % 3 == 0 { -1.0 } else { 1.0 };
            sign * (1.0 + 0.37 * k as f64) * 10f64.powi((k % 13) as i32 - 6)
        })
        .collect()
}

struct Checked {
    /// Tape instructions over all three sections.
    code_size: usize,
    /// Instructions before fusion.
    lowered: usize,
    rules: usize,
}

/// Build `doc`, check the taped right-hand side against the oracle bit for
/// bit, and return the tape's size.
fn check(doc: &Value) -> Checked {
    let file = load_string(&doc.to_string()).expect("document loads");
    let compiled = ArrayCompiled::from_file(&file).expect("document compiles");
    let report = compiled.debug_build_tape_report();
    assert!(
        report.fallbacks.is_empty(),
        "every rule must stay on the tape: {:?}",
        report.fallbacks
    );
    let n = compiled.state_variable_names().len();
    let state = probe_state(n);
    let params: HashMap<String, f64> = HashMap::new();
    let (oracle, _) = compiled.debug_eval_rhs(&state, 0.0, &params, true);

    let param_vec = compiled.debug_resolve_params(&params);
    let mut scratch = compiled.debug_new_scratch_taped();
    let mut stats = RhsStats::default();
    let mut taped = vec![0.0; n];
    compiled.debug_eval_rhs_into(
        &state,
        0.0,
        &param_vec,
        &mut taped,
        &mut scratch,
        &mut stats,
    );
    assert_eq!(
        stats.fallback_rules, 0,
        "no rule may leave the tape at run time"
    );
    for (k, (a, b)) in taped.iter().zip(oracle.iter()).enumerate() {
        assert_eq!(
            a.to_bits(),
            b.to_bits(),
            "{}: taped {a:e} vs oracle {b:e}",
            compiled.state_variable_names()[k]
        );
    }
    Checked {
        code_size: report.n_instr_const + report.n_instr_segment + report.n_instr_continuous,
        lowered: report.fuse.instrs_before,
        rules: report.n_rules,
    }
}

/// Check `make(n)` at two sizes and require the same tape at both.
fn flat_in_n(make: impl Fn(i64) -> Value, small: i64, large: i64) -> Checked {
    let a = check(&make(small));
    let b = check(&make(large));
    assert_eq!(
        (a.code_size, a.lowered),
        (b.code_size, b.lowered),
        "the tape must not grow with N ({small} vs {large})"
    );
    b
}

fn doc(index_sets: Value, variables: Value, equations: Value) -> Value {
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_loops"},
        "index_sets": index_sets,
        "models": {"M": {"variables": variables, "equations": equations}}
    })
}

fn op(name: &str, args: Value) -> Value {
    json!({"op": name, "args": args})
}

fn d(var: &str) -> Value {
    json!({"op": "D", "args": [var], "wrt": "t"})
}

// ---------------------------------------------------------------------------
// Whole-array derivatives
// ---------------------------------------------------------------------------

#[test]
fn a_bare_whole_array_derivative_is_one_rule() {
    let make = |n: i64| {
        doc(
            json!({"x": {"kind": "interval", "size": n}}),
            json!({
                "u": {"type": "unknown", "units": "1", "default": 1.0, "shape": ["x"]},
                "k": {"type": "parameter", "units": "1", "default": 0.1},
                "s": {"type": "parameter", "units": "1", "default": 0.01}
            }),
            json!([{"lhs": d("u"), "rhs": op("+", json!([op("*", json!([op("-", json!(["k"])), "u"])), "s"]))}]),
        )
    };
    let c = flat_in_n(make, 7, 300);
    assert_eq!(c.rules, 1, "one rule for the whole array, not one per cell");
}

/// Operands aligned by index-set NAME (esm-spec §4.3.4): a rank-1 operand
/// replicated along the axes it does not carry, and a transposed operand.
#[test]
fn a_name_aligned_whole_array_derivative_is_one_rule_per_state() {
    let make = |n: i64| {
        doc(
            json!({
                "lon": {"kind": "interval", "size": n},
                "lat": {"kind": "interval", "size": 3}
            }),
            json!({
                "q": {"type": "unknown", "units": "1", "default": 1.0, "shape": ["lon", "lat"]},
                "w": {"type": "unknown", "units": "1", "default": 2.0, "shape": ["lat"]},
                "r": {"type": "unknown", "units": "1", "default": 3.0, "shape": ["lat", "lon"]},
                "k": {"type": "parameter", "units": "1", "default": 0.5}
            }),
            json!([
                {"lhs": d("q"), "rhs": op("-", json!([op("*", json!(["w", "q"])), op("/", json!(["r", "k"]))]))},
                {"lhs": d("w"), "rhs": op("*", json!(["k", "w"]))},
                {"lhs": d("r"), "rhs": op("sin", json!(["r"]))}
            ]),
        )
    };
    let c = flat_in_n(make, 4, 90);
    assert_eq!(c.rules, 3);
}
