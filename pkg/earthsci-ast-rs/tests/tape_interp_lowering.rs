//! The §9.2 `interp.*` family on the tape (`Instr::Interp`).
//!
//! `interp.linear`, `interp.bilinear` and `interp.searchsorted` were the
//! largest single reason a document left the tape — 463 fallback rules across
//! 46 documents in the 2026-09-21 corpus census, plus most of the
//! `statically-unknown shape` cascades downstream of them. What is pinned here
//! is what a caller can observe now that they lower:
//!
//!   1. the taped rule and the per-cell oracle produce THE SAME BITS at every
//!      probe, including the two extrapolate-flat clamps, every exact knot, a
//!      NaN query and (for `interp.searchsorted`) a duplicate run;
//!   2. those bits are the closed-function registry's own answer, checked
//!      against `evaluate_closed_function` directly rather than against a
//!      recorded number, so this is a correctness test and not a snapshot;
//!   3. the query may be an ARRAY over the rule's output box — a per-cell
//!      lookup on a gridded field — and the elementwise result still agrees
//!      cell by cell;
//!   4. an observed that READS an `interp.*` observed lowers too: the cascade
//!      that used to fire (`observed has a statically-unknown shape`, because
//!      the producer was itself a fallback) does not;
//!   5. the public surface agrees: the three conformance fixtures build under
//!      `Compiler::Native`, whose report says every rule is taped, and their
//!      trajectories match `Compiler::Interpreter` bit for bit.
//!
//! The probe comparison goes through `ArrayCompiled::debug_eval_rhs`, whose
//! `force_scalar` flag is exactly the tape/per-cell-oracle switch: `false`
//! runs the tape, `true` walks the tree once per output cell. That is the same
//! reference `tests/xla_compiled_rhs.rs` measures the emitter against.

#![cfg(all(feature = "solve", not(target_arch = "wasm32")))]

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{
    ClosedArg, Compiler, ProblemOptions, Rhs, SolveOptions, esm_problem, evaluate_closed_function,
    load_string, solve,
};

// ---------------------------------------------------------------------------
// The tables the documents below share with their expectations.
// ---------------------------------------------------------------------------

/// A non-uniform axis, so a wrong cell choice cannot be hidden by even
/// spacing, and a table whose values are not affine in the axis, so a
/// misattributed weight shows up.
const AXIS: [f64; 5] = [0.0, 1.0, 2.5, 3.0, 7.0];
const TABLE: [f64; 5] = [10.0, 20.0, 40.0, 80.0, 160.0];

const AXIS_X: [f64; 3] = [0.0, 1.0, 2.0];
const AXIS_Y: [f64; 4] = [0.0, 10.0, 25.0, 30.0];
/// Row-major: `TABLE_2D[i][j]` sits at `(AXIS_X[i], AXIS_Y[j])`.
const TABLE_2D: [[f64; 4]; 3] = [
    [0.0, 1.0, 2.0, 3.0],
    [10.0, 11.5, 12.0, 13.0],
    [20.0, 21.0, 22.5, 23.0],
];

/// A NON-decreasing table with a duplicate run — legal for
/// `interp.searchsorted` (it returns an index, not a blend) and the case its
/// left-side bias exists for.
const XS: [f64; 6] = [1.0, 2.0, 2.0, 2.0, 4.0, 5.0];

/// Queries that span every branch of the 1-D lowering: below range, on the
/// first knot, inside each cell, on every interior knot, on the last knot,
/// above range, and NaN.
fn linear_probes() -> Vec<f64> {
    let mut v = vec![-3.0, -1e-300, 0.5, 1.25, 2.4, 2.75, 3.5, 6.999, 7.5, 40.0];
    v.extend(AXIS);
    v.push(f64::NAN);
    v
}

fn json_array(v: &[f64]) -> String {
    let items: Vec<String> = v.iter().map(|x| format!("{x:?}")).collect();
    format!("[{}]", items.join(", "))
}

fn json_array_2d(rows: &[[f64; 4]]) -> String {
    let items: Vec<String> = rows.iter().map(|r| json_array(r)).collect();
    format!("[{}]", items.join(", "))
}

// ---------------------------------------------------------------------------
// Harness.
// ---------------------------------------------------------------------------

fn compile(doc: &str) -> ArrayCompiled {
    let file = load_string(doc).unwrap_or_else(|e| panic!("load: {e:?}"));
    ArrayCompiled::from_file(&file).unwrap_or_else(|e| panic!("compile: {e:?}"))
}

/// The tape's answer and the per-cell oracle's, for one probe state.
fn both(compiled: &ArrayCompiled, u: &[f64], t: f64) -> (Vec<f64>, Vec<f64>) {
    let p: HashMap<String, f64> = HashMap::new();
    let (taped, _) = compiled.debug_eval_rhs(u, t, &p, false);
    let (oracle, _) = compiled.debug_eval_rhs(u, t, &p, true);
    (taped, oracle)
}

/// Bitwise equality, with every NaN treated as one value: the two evaluators
/// must agree on WHICH number, and a NaN payload is not part of that contract
/// (nothing downstream can read it).
fn same_bits(a: f64, b: f64) -> bool {
    (a.is_nan() && b.is_nan()) || a.to_bits() == b.to_bits()
}

fn assert_same_bits(what: &str, taped: &[f64], oracle: &[f64]) {
    assert_eq!(taped.len(), oracle.len(), "{what}: length");
    for (i, (a, b)) in taped.iter().zip(oracle.iter()).enumerate() {
        assert!(
            same_bits(*a, *b),
            "{what}: element {i}: tape {a:?} ({:#x}) vs oracle {b:?} ({:#x})",
            a.to_bits(),
            b.to_bits()
        );
    }
}

/// The index of a state variable in the flat vector, by its bare name.
fn slot(compiled: &ArrayCompiled, bare: &str) -> usize {
    compiled
        .state_variable_names()
        .iter()
        .position(|n| n == bare || n.split_once('.').map(|x| x.1) == Some(bare))
        .unwrap_or_else(|| {
            panic!(
                "no state named {bare:?}; have {:?}",
                compiled.state_variable_names()
            )
        })
}

/// Nothing in this document may leave the tape. A fallback here would make
/// every agreement below vacuous: the two sides would be the same oracle.
fn assert_fully_taped(compiled: &ArrayCompiled, what: &str) {
    let report = compiled.debug_build_tape_report();
    assert!(
        report.fallbacks.is_empty(),
        "{what}: rules left the tape: {:?}",
        report.fallbacks
    );
}

// ---------------------------------------------------------------------------
// interp.linear
// ---------------------------------------------------------------------------

fn linear_doc() -> String {
    format!(
        r#"{{
  "esm": "1.0.0",
  "metadata": {{ "name": "TapeInterpLinear", "description": "d(y)/dt = interp.linear(table, axis, q); q is a state so a probe can place it anywhere, including outside the axis and at NaN." }},
  "models": {{ "M": {{ "variables": {{
      "q": {{ "type": "unknown", "units": "1", "default": 0.0 }},
      "y": {{ "type": "unknown", "units": "1", "default": 0.0 }}
    }},
    "equations": [
      {{ "lhs": {{ "op": "D", "args": ["q"], "wrt": "t" }}, "rhs": 0.0 }},
      {{ "lhs": {{ "op": "D", "args": ["y"], "wrt": "t" }},
        "rhs": {{ "op": "fn", "name": "interp.linear", "args": [
          {{ "op": "const", "args": [], "value": {table} }},
          {{ "op": "const", "args": [], "value": {axis} }},
          "q" ]}} }}
    ] }} }}
}}"#,
        table = json_array(&TABLE),
        axis = json_array(&AXIS)
    )
}

#[test]
fn interp_linear_is_taped_and_matches_the_oracle_bit_for_bit() {
    let compiled = compile(&linear_doc());
    assert_fully_taped(&compiled, "interp.linear");
    let (iq, iy) = (slot(&compiled, "q"), slot(&compiled, "y"));

    for x in linear_probes() {
        let mut u = vec![0.0; compiled.state_variable_names().len()];
        u[iq] = x;
        let (taped, oracle) = both(&compiled, &u, 0.0);
        assert_same_bits(&format!("interp.linear at q={x:?}"), &taped, &oracle);

        // And the shared answer IS the registry's.
        let want = evaluate_closed_function(
            "interp.linear",
            &[
                ClosedArg::Array(TABLE.to_vec()),
                ClosedArg::Array(AXIS.to_vec()),
                ClosedArg::Scalar(x),
            ],
        )
        .expect("the registry accepts this table")
        .as_f64();
        assert!(
            same_bits(taped[iy], want),
            "interp.linear at q={x:?}: tape {:?} vs registry {want:?}",
            taped[iy]
        );
    }
}

/// An exact knot must come back as the table entry itself, not as a blend that
/// rounds to it: §9.2 pins `t[i] + w * (t[i+1] - t[i])` precisely so that
/// `w == 0` recovers `t[i]` exactly.
#[test]
fn interp_linear_at_a_knot_is_the_table_entry_exactly() {
    let compiled = compile(&linear_doc());
    let (iq, iy) = (slot(&compiled, "q"), slot(&compiled, "y"));
    for (k, &knot) in AXIS.iter().enumerate() {
        let mut u = vec![0.0; compiled.state_variable_names().len()];
        u[iq] = knot;
        let (taped, oracle) = both(&compiled, &u, 0.0);
        assert_eq!(
            taped[iy].to_bits(),
            TABLE[k].to_bits(),
            "knot {k} ({knot}): tape gave {:?}, want {:?}",
            taped[iy],
            TABLE[k]
        );
        assert_eq!(taped[iy].to_bits(), oracle[iy].to_bits());
    }
}

// ---------------------------------------------------------------------------
// interp.linear over an ARRAY query — the per-cell lookup on a gridded field
// ---------------------------------------------------------------------------

fn linear_gridded_doc() -> String {
    format!(
        r#"{{
  "esm": "1.1.0",
  "metadata": {{ "name": "TapeInterpLinearGridded", "description": "The same lookup with the query a rank-1 FIELD, so the rule's output box is an array and the instruction runs elementwise." }},
  "index_sets": {{ "cell": {{ "kind": "interval", "size": 5 }} }},
  "models": {{ "M": {{ "variables": {{
      "q": {{ "type": "unknown", "units": "1", "shape": ["cell"], "default": 0.0 }},
      "y": {{ "type": "unknown", "units": "1", "shape": ["cell"], "default": 0.0 }}
    }},
    "equations": [
      {{ "lhs": {{ "op": "D", "args": ["q"], "wrt": "t" }}, "rhs": 0.0 }},
      {{ "lhs": {{ "op": "D", "args": ["y"], "wrt": "t" }},
        "rhs": {{ "op": "fn", "name": "interp.linear", "args": [
          {{ "op": "const", "args": [], "value": {table} }},
          {{ "op": "const", "args": [], "value": {axis} }},
          "q" ]}} }}
    ] }} }}
}}"#,
        table = json_array(&TABLE),
        axis = json_array(&AXIS)
    )
}

#[test]
fn interp_linear_over_an_array_query_is_elementwise() {
    let compiled = compile(&linear_gridded_doc());
    assert_fully_taped(&compiled, "interp.linear (gridded)");
    let names = compiled.state_variable_names().to_vec();
    assert_eq!(names.len(), 10, "two rank-1 fields of 5 cells: {names:?}");

    // One cell per branch: below range, first knot, mid-cell, last knot, NaN.
    let qs = [-4.0, AXIS[0], 2.75, AXIS[4], f64::NAN];
    // `q` occupies the first block of the flat vector or the second; find it
    // by name rather than assuming.
    let q0 = slot(&compiled, "q[1]");
    let y0 = slot(&compiled, "y[1]");
    let mut u = vec![0.0; names.len()];
    for (k, v) in qs.iter().enumerate() {
        u[q0 + k] = *v;
    }
    let (taped, oracle) = both(&compiled, &u, 0.0);
    assert_same_bits("interp.linear over a field", &taped, &oracle);
    for (k, x) in qs.iter().enumerate() {
        let want = evaluate_closed_function(
            "interp.linear",
            &[
                ClosedArg::Array(TABLE.to_vec()),
                ClosedArg::Array(AXIS.to_vec()),
                ClosedArg::Scalar(*x),
            ],
        )
        .expect("registry")
        .as_f64();
        assert!(
            same_bits(taped[y0 + k], want),
            "cell {k} (q={x:?}): tape {:?} vs registry {want:?}",
            taped[y0 + k]
        );
    }
}

// ---------------------------------------------------------------------------
// interp.bilinear
// ---------------------------------------------------------------------------

fn bilinear_doc() -> String {
    format!(
        r#"{{
  "esm": "1.0.0",
  "metadata": {{ "name": "TapeInterpBilinear", "description": "d(z)/dt = interp.bilinear(table, axis_x, axis_y, a, b) with both queries states, so a probe can place either inside, on a knot, outside or at NaN independently." }},
  "models": {{ "M": {{ "variables": {{
      "a": {{ "type": "unknown", "units": "1", "default": 0.0 }},
      "b": {{ "type": "unknown", "units": "1", "default": 0.0 }},
      "z": {{ "type": "unknown", "units": "1", "default": 0.0 }}
    }},
    "equations": [
      {{ "lhs": {{ "op": "D", "args": ["a"], "wrt": "t" }}, "rhs": 0.0 }},
      {{ "lhs": {{ "op": "D", "args": ["b"], "wrt": "t" }}, "rhs": 0.0 }},
      {{ "lhs": {{ "op": "D", "args": ["z"], "wrt": "t" }},
        "rhs": {{ "op": "fn", "name": "interp.bilinear", "args": [
          {{ "op": "const", "args": [], "value": {table} }},
          {{ "op": "const", "args": [], "value": {ax} }},
          {{ "op": "const", "args": [], "value": {ay} }},
          "a", "b" ]}} }}
    ] }} }}
}}"#,
        table = json_array_2d(&TABLE_2D),
        ax = json_array(&AXIS_X),
        ay = json_array(&AXIS_Y)
    )
}

#[test]
fn interp_bilinear_is_taped_and_matches_the_oracle_bit_for_bit() {
    let compiled = compile(&bilinear_doc());
    assert_fully_taped(&compiled, "interp.bilinear");
    let (ia, ib, iz) = (
        slot(&compiled, "a"),
        slot(&compiled, "b"),
        slot(&compiled, "z"),
    );

    // Corners, interior knots in either axis, mid-cell blends, each axis out
    // of range on either side, and NaN in either query.
    let xs = [-1.0, 0.0, 0.4, 1.0, 1.75, 2.0, 5.0, f64::NAN];
    let ys = [-6.0, 0.0, 7.0, 10.0, 18.0, 25.0, 30.0, 44.0, f64::NAN];
    for x in xs {
        for y in ys {
            let mut u = vec![0.0; compiled.state_variable_names().len()];
            u[ia] = x;
            u[ib] = y;
            let (taped, oracle) = both(&compiled, &u, 0.0);
            assert_same_bits(
                &format!("interp.bilinear at ({x:?}, {y:?})"),
                &taped,
                &oracle,
            );

            let want = evaluate_closed_function(
                "interp.bilinear",
                &[
                    ClosedArg::Array2D(TABLE_2D.iter().map(|r| r.to_vec()).collect()),
                    ClosedArg::Array(AXIS_X.to_vec()),
                    ClosedArg::Array(AXIS_Y.to_vec()),
                    ClosedArg::Scalar(x),
                    ClosedArg::Scalar(y),
                ],
            )
            .expect("registry")
            .as_f64();
            assert!(
                same_bits(taped[iz], want),
                "interp.bilinear at ({x:?}, {y:?}): tape {:?} vs registry {want:?}",
                taped[iz]
            );
        }
    }
}

// ---------------------------------------------------------------------------
// interp.searchsorted
// ---------------------------------------------------------------------------

fn searchsorted_doc() -> String {
    format!(
        r#"{{
  "esm": "1.0.0",
  "metadata": {{ "name": "TapeInterpSearchsorted", "description": "d(y)/dt = interp.searchsorted(q, xs) with a duplicate run in xs, so the left-side bias is exercised." }},
  "models": {{ "M": {{ "variables": {{
      "q": {{ "type": "unknown", "units": "1", "default": 0.0 }},
      "y": {{ "type": "unknown", "units": "1", "default": 0.0 }}
    }},
    "equations": [
      {{ "lhs": {{ "op": "D", "args": ["q"], "wrt": "t" }}, "rhs": 0.0 }},
      {{ "lhs": {{ "op": "D", "args": ["y"], "wrt": "t" }},
        "rhs": {{ "op": "fn", "name": "interp.searchsorted", "args": [
          "q", {{ "op": "const", "args": [], "value": {xs} }} ]}} }}
    ] }} }}
}}"#,
        xs = json_array(&XS)
    )
}

#[test]
fn interp_searchsorted_is_taped_and_matches_the_oracle_bit_for_bit() {
    let compiled = compile(&searchsorted_doc());
    assert_fully_taped(&compiled, "interp.searchsorted");
    let (iq, iy) = (slot(&compiled, "q"), slot(&compiled, "y"));

    let probes = [
        0.0,
        1.0,
        1.5,
        // On the duplicate run: the left-side bias must return the FIRST of
        // the three, not any of them.
        2.0,
        2.5,
        4.0,
        5.0,
        5.5,
        f64::NAN,
    ];
    for x in probes {
        let mut u = vec![0.0; compiled.state_variable_names().len()];
        u[iq] = x;
        let (taped, oracle) = both(&compiled, &u, 0.0);
        assert_same_bits(&format!("interp.searchsorted at q={x:?}"), &taped, &oracle);
        let want = evaluate_closed_function(
            "interp.searchsorted",
            &[ClosedArg::Scalar(x), ClosedArg::Array(XS.to_vec())],
        )
        .expect("registry")
        .as_f64();
        assert!(
            same_bits(taped[iy], want),
            "interp.searchsorted at q={x:?}: tape {:?} vs registry {want:?}",
            taped[iy]
        );
    }

    // The duplicate run, spelled out: `xs[2..4]` are all 2.0 and the answer is
    // 2 (1-based), the smallest index with `xs[i] >= x`.
    let mut u = vec![0.0; compiled.state_variable_names().len()];
    u[iq] = 2.0;
    let (taped, _) = both(&compiled, &u, 0.0);
    assert_eq!(taped[iy], 2.0, "left-side bias on a duplicate run");
}

// ---------------------------------------------------------------------------
// The cascade: an observed that reads an `interp.*` observed
// ---------------------------------------------------------------------------

/// `observed has a statically-unknown shape (fallback producer)` fired
/// whenever a rule read an observed that was ITSELF a fallback — 333 rules in
/// the census, 327 of them CONST-tier and downstream of exactly this gap. With
/// the producer taped the consumer has a shape and lowers too, so the whole
/// chain is on the tape rather than just its head.
#[test]
fn an_observed_reading_an_interp_observed_lowers_too() {
    let doc = format!(
        r#"{{
  "esm": "1.0.0",
  "metadata": {{ "name": "TapeInterpCascade", "description": "lookup -> scaled -> the state derivative: a three-link chain whose head is an interp.linear observed." }},
  "models": {{ "M": {{ "variables": {{
      "q": {{ "type": "unknown", "units": "1", "default": 0.0 }},
      "lookup": {{ "type": "unknown", "units": "1" }},
      "scaled": {{ "type": "unknown", "units": "1" }},
      "y": {{ "type": "unknown", "units": "1", "default": 0.0 }}
    }},
    "equations": [
      {{ "lhs": {{ "op": "D", "args": ["q"], "wrt": "t" }}, "rhs": 0.0 }},
      {{ "lhs": "lookup",
        "rhs": {{ "op": "fn", "name": "interp.linear", "args": [
          {{ "op": "const", "args": [], "value": {table} }},
          {{ "op": "const", "args": [], "value": {axis} }},
          "q" ]}} }},
      {{ "lhs": "scaled", "rhs": {{ "op": "*", "args": ["lookup", 3.0] }} }},
      {{ "lhs": {{ "op": "D", "args": ["y"], "wrt": "t" }},
        "rhs": {{ "op": "+", "args": ["scaled", 1.0] }} }}
    ] }} }}
}}"#,
        table = json_array(&TABLE),
        axis = json_array(&AXIS)
    );
    let compiled = compile(&doc);
    let report = compiled.debug_build_tape_report();
    assert!(
        report.fallbacks.is_empty(),
        "the chain must be wholly taped, not just its head: {:?}",
        report.fallbacks
    );

    let (iq, iy) = (slot(&compiled, "q"), slot(&compiled, "y"));
    for x in linear_probes() {
        let mut u = vec![0.0; compiled.state_variable_names().len()];
        u[iq] = x;
        let (taped, oracle) = both(&compiled, &u, 0.0);
        assert_same_bits(&format!("cascade at q={x:?}"), &taped, &oracle);
        let base = evaluate_closed_function(
            "interp.linear",
            &[
                ClosedArg::Array(TABLE.to_vec()),
                ClosedArg::Array(AXIS.to_vec()),
                ClosedArg::Scalar(x),
            ],
        )
        .expect("registry")
        .as_f64();
        assert!(same_bits(taped[iy], base * 3.0 + 1.0), "cascade at q={x:?}");
    }
}

// ---------------------------------------------------------------------------
// What a caller sees: the conformance fixtures under `native`
// ---------------------------------------------------------------------------

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

fn fixture(rel: &str) -> PathBuf {
    let p = repo_root().join(rel);
    assert!(p.exists(), "fixture {} is missing", p.display());
    p
}

const CANONICAL: &[&str] = &[
    "tests/closed_functions/interp/linear/canonical.esm",
    "tests/closed_functions/interp/bilinear/canonical.esm",
    "tests/closed_functions/interp/searchsorted/canonical.esm",
];

fn build_at(path: &Path, compiler: Compiler) -> earthsci_ast::EsmProblem {
    esm_problem(
        path,
        (0.0, 1.0),
        ProblemOptions {
            rhs: Rhs::Always,
            compiler: Some(compiler),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{} under {compiler}: {e:?}", path.display()))
}

/// The three documents `native` used to refuse, with the reason naming the
/// function. They build now, and the report says every rule is taped — the
/// half a "no longer refused" assertion would miss, since a document whose
/// rules all fell back to the oracle would also build.
#[test]
fn the_canonical_fixtures_build_under_native_with_every_rule_taped() {
    for rel in CANONICAL {
        let path = fixture(rel);
        let prob = build_at(&path, Compiler::Native);
        assert_eq!(prob.compiler(), Compiler::Native);
        let report = prob.compiler_report();
        assert!(!report.rules().is_empty(), "{rel}: no rules reported");
        assert_eq!(report.n_oracle(), 0, "{rel}: a rule is off the tape");
        assert_eq!(report.n_taped(), report.rules().len(), "{rel}");
        for r in report.rules() {
            assert!(r.reason.is_none(), "{rel}: {} — {:?}", r.rule, r.reason);
        }
    }
}

#[test]
fn the_canonical_fixtures_agree_with_the_interpreter_bit_for_bit() {
    let opts = SolveOptions {
        saveat: Some(vec![0.0, 0.25, 0.5, 0.75, 1.0]),
        ..Default::default()
    };
    for rel in CANONICAL {
        let path = fixture(rel);
        let native = build_at(&path, Compiler::Native);
        let reference = build_at(&path, Compiler::Interpreter);
        let a = solve(&native, &opts).unwrap_or_else(|e| panic!("{rel} native solve: {e}"));
        let b = solve(&reference, &opts).unwrap_or_else(|e| panic!("{rel} interpreter solve: {e}"));
        assert_eq!(a.state_variable_names, b.state_variable_names, "{rel}");
        assert_eq!(a.state.len(), b.state.len(), "{rel}");
        for (row, (xs, ys)) in a.state.iter().zip(b.state.iter()).enumerate() {
            assert_eq!(xs.len(), ys.len(), "{rel} row {row}");
            for (k, (x, y)) in xs.iter().zip(ys.iter()).enumerate() {
                assert!(
                    same_bits(*x, *y),
                    "{rel} row {row} at t index {k}: native {x:e} vs interpreter {y:e}"
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// What still leaves the tape, and why
// ---------------------------------------------------------------------------

/// §9.2 requires the table and the axes to be literal `const`-op arrays
/// (diagnostics `interp_table_not_const` / `interp_axis_not_const`), so the
/// lowering reads them at build time. A document that violates that must BAIL
/// rather than lower something else — the oracle is where the registry's
/// refusal turns into the NaN sentinel a caller sees.
#[test]
fn a_non_const_table_bails_by_name() {
    let doc = r#"{
  "esm": "1.0.0",
  "metadata": { "name": "TapeInterpRuntimeTable", "description": "The axis is an expression, not a const literal: outside the §9.2 contract, so the tape must decline rather than invent a table." },
  "models": { "M": { "variables": {
      "q": { "type": "unknown", "units": "1", "default": 0.0 },
      "y": { "type": "unknown", "units": "1", "default": 0.0 }
    },
    "equations": [
      { "lhs": { "op": "D", "args": ["q"], "wrt": "t" }, "rhs": 0.0 },
      { "lhs": { "op": "D", "args": ["y"], "wrt": "t" },
        "rhs": { "op": "fn", "name": "interp.linear", "args": [
          { "op": "const", "args": [], "value": [10.0, 20.0] },
          { "op": "*", "args": [{ "op": "const", "args": [], "value": [0.0, 1.0] }, 2.0] },
          "q" ]} }
    ] } }
}"#;
    let compiled = compile(doc);
    let report = compiled.debug_build_tape_report();
    let reasons: Vec<&str> = report.fallbacks.iter().map(|f| f.1.as_str()).collect();
    assert!(
        reasons
            .iter()
            .any(|r| r.contains("interp.linear") && (r.contains("const") || r.contains("§9.2"))),
        "the decline must name the function and say the argument is not a const array: {reasons:?}"
    );
}

/// A table the registry itself rejects — here an axis that is not strictly
/// increasing — must bail for the same reason: the registry answers such a
/// call with an error, `eval_fn` turns that into the NaN sentinel, and only
/// the oracle produces it.
#[test]
fn a_table_the_registry_rejects_bails_rather_than_blending() {
    let doc = r#"{
  "esm": "1.0.0",
  "metadata": { "name": "TapeInterpBadAxis", "description": "A decreasing axis: interp_non_monotonic_axis at load time in the registry, so the tape must not lower it." },
  "models": { "M": { "variables": {
      "q": { "type": "unknown", "units": "1", "default": 0.0 },
      "y": { "type": "unknown", "units": "1", "default": 0.0 }
    },
    "equations": [
      { "lhs": { "op": "D", "args": ["q"], "wrt": "t" }, "rhs": 0.0 },
      { "lhs": { "op": "D", "args": ["y"], "wrt": "t" },
        "rhs": { "op": "fn", "name": "interp.linear", "args": [
          { "op": "const", "args": [], "value": [10.0, 20.0, 30.0] },
          { "op": "const", "args": [], "value": [0.0, 2.0, 1.0] },
          "q" ]} }
    ] } }
}"#;
    let compiled = compile(doc);
    let report = compiled.debug_build_tape_report();
    let reasons: Vec<&str> = report.fallbacks.iter().map(|f| f.1.as_str()).collect();
    assert!(
        reasons
            .iter()
            .any(|r| r.contains("interp.linear") && r.contains("interp_non_monotonic_axis")),
        "the decline must carry the registry's own diagnostic code: {reasons:?}"
    );
    // And the rule still answers what it always did.
    let iy = slot(&compiled, "y");
    let (taped, oracle) = both(&compiled, &[0.5, 0.0], 0.0);
    assert!(taped[iy].is_nan(), "the sentinel survives the bail");
    assert_same_bits("bad axis", &taped, &oracle);
}
