//! Cumulative (prefix) reductions — esm-spec §4.3.1.
//!
//! A prefix reduction is an ordinary `aggregate` whose `filter` compares the
//! contracted index against an output index. Evaluated literally it is a
//! triangular double loop: `N` output cells each re-folding the window the
//! previous cell already folded. The evaluator recognizes the FORWARD rows
//! (`<=`, `<`) and collapses them to one `O(N)` sweep with a running
//! accumulator.
//!
//! The rewrite is only legitimate because it is **bit-identical**, so that is
//! what these tests pin — not "close enough". The oracle folds the admitted
//! window ascending, lowest `j` first; `accᵢ = accᵢ₋₁ ⊕ bodyᵢ` reproduces exactly
//! that fold with exactly that association. The reverse rows (`>=`, `>`) are
//! deliberately NOT scanned under an inexact ⊕: each reverse cell folds its own
//! suffix from that suffix's low end, so consecutive cells share no partial
//! result and any right-to-left accumulator would re-associate.

use earthsci_ast::simulate_array::eval_expression;
use ndarray::{ArrayD, IxDyn};
use serde_json::json;
use std::collections::HashMap;

/// Build a prefix-reduction aggregate over `u` with the given comparison.
fn prefix_agg(cmp: &str, n: i64, reduce: &str) -> earthsci_ast::types::Expr {
    let node = json!({
        "op": "aggregate",
        "args": ["u"],
        "output_idx": ["i"],
        "reduce": reduce,
        "ranges": { "i": [1, n], "j": [1, n] },
        "filter": { "op": cmp, "args": ["j", "i"] },
        "expr": { "op": "index", "args": ["u", "j"] }
    });
    serde_json::from_value(node).expect("aggregate parses")
}

fn eval_with(expr: &earthsci_ast::types::Expr, u: &[f64]) -> Vec<f64> {
    let mut inputs: HashMap<String, ArrayD<f64>> = HashMap::new();
    inputs.insert(
        "u".to_string(),
        ArrayD::from_shape_vec(IxDyn(&[u.len()]), u.to_vec()).unwrap(),
    );
    match eval_expression(expr, &inputs, &[], &[], 0.0).expect("evaluates") {
        earthsci_ast::simulate_array::Value::Array(a) => a.iter().copied().collect(),
        earthsci_ast::simulate_array::Value::Scalar(s) => vec![s],
    }
}

/// The independent reference: the triangular double loop, written out literally,
/// folding the admitted window in ascending `j`. This is the semantics the spec
/// defines; the evaluator's scan must reproduce it to the bit.
fn oracle(u: &[f64], cmp: &str, reduce: &str) -> Vec<f64> {
    let n = u.len();
    (1..=n)
        .map(|i| {
            let mut acc = match reduce {
                "+" => 0.0,
                "*" => 1.0,
                "max" => f64::NEG_INFINITY,
                "min" => f64::INFINITY,
                _ => unreachable!(),
            };
            for j in 1..=n {
                let admitted = match cmp {
                    "<=" => j <= i,
                    "<" => j < i,
                    ">=" => j >= i,
                    ">" => j > i,
                    _ => unreachable!(),
                };
                if !admitted {
                    continue;
                }
                let t = u[j - 1];
                acc = match reduce {
                    "+" => acc + t,
                    "*" => acc * t,
                    "max" => acc.max(t),
                    "min" => acc.min(t),
                    _ => unreachable!(),
                };
            }
            acc
        })
        .collect()
}

/// Values chosen so that re-association is *observable*: mixing magnitudes many
/// orders apart makes `(a + b) + c` differ from `a + (b + c)` in the low bits, so
/// a scan that got the association wrong cannot pass by luck.
fn catastrophic_values(n: usize) -> Vec<f64> {
    (0..n)
        .map(|k| {
            let sign = if k % 3 == 0 { -1.0 } else { 1.0 };
            sign * (1.0 + k as f64) * 10f64.powi((k % 17) as i32 - 8)
        })
        .collect()
}

#[test]
fn forward_scans_are_bit_identical_to_the_triangular_oracle() {
    for n in [1usize, 2, 3, 8, 33, 64, 257] {
        let u = catastrophic_values(n);
        for cmp in ["<=", "<"] {
            for reduce in ["+", "*", "max", "min"] {
                let got = eval_with(&prefix_agg(cmp, n as i64, reduce), &u);
                let want = oracle(&u, cmp, reduce);
                assert_eq!(
                    got.len(),
                    want.len(),
                    "n={n} cmp={cmp} reduce={reduce}: length"
                );
                for (k, (g, w)) in got.iter().zip(want.iter()).enumerate() {
                    // to_bits, not approx: re-association is exactly what a wrong
                    // scan would produce, and it hides inside any tolerance.
                    assert_eq!(
                        g.to_bits(),
                        w.to_bits(),
                        "n={n} cmp={cmp} reduce={reduce} cell {}: {g:?} != {w:?}",
                        k + 1
                    );
                }
            }
        }
    }
}

#[test]
fn reverse_scans_still_match_the_oracle() {
    // Not scanned (for + and *), but they must keep working — the detector must
    // decline them rather than mis-handle them.
    for n in [1usize, 5, 40] {
        let u = catastrophic_values(n);
        for cmp in [">=", ">"] {
            for reduce in ["+", "*", "max", "min"] {
                let got = eval_with(&prefix_agg(cmp, n as i64, reduce), &u);
                let want = oracle(&u, cmp, reduce);
                for (k, (g, w)) in got.iter().zip(want.iter()).enumerate() {
                    assert_eq!(
                        g.to_bits(),
                        w.to_bits(),
                        "n={n} cmp={cmp} reduce={reduce} cell {}",
                        k + 1
                    );
                }
            }
        }
    }
}

#[test]
fn exclusive_first_cell_is_the_additive_identity_not_an_error() {
    let u = vec![1.0, 2.0, 4.0, 8.0];
    assert_eq!(eval_with(&prefix_agg("<", 4, "+"), &u)[0], 0.0);
    assert_eq!(eval_with(&prefix_agg("<", 4, "*"), &u)[0], 1.0);
    assert_eq!(
        eval_with(&prefix_agg("<", 4, "max"), &u)[0],
        f64::NEG_INFINITY
    );
    assert_eq!(eval_with(&prefix_agg("<", 4, "min"), &u)[0], f64::INFINITY);
}

#[test]
fn inclusive_forward_sum_is_the_expected_running_total() {
    let u = vec![1.0, 2.0, 4.0, 8.0];
    assert_eq!(
        eval_with(&prefix_agg("<=", 4, "+"), &u),
        vec![1.0, 3.0, 7.0, 15.0]
    );
    assert_eq!(
        eval_with(&prefix_agg("<", 4, "+"), &u),
        vec![0.0, 1.0, 3.0, 7.0]
    );
    assert_eq!(
        eval_with(&prefix_agg(">=", 4, "+"), &u),
        vec![15.0, 14.0, 12.0, 8.0]
    );
}

/// A body that READS the scanned output symbol must NOT be scanned: each cell's
/// summand differs, so no partial result can be reused. The detector declines,
/// the triangular oracle runs, and the answer stays correct.
#[test]
fn body_referencing_the_scanned_symbol_falls_back_to_the_oracle() {
    let n = 6i64;
    let node = json!({
        "op": "aggregate",
        "args": ["u"],
        "output_idx": ["i"],
        "reduce": "+",
        "ranges": { "i": [1, n], "j": [1, n] },
        "filter": { "op": "<=", "args": ["j", "i"] },
        // body depends on BOTH i and j — sum_{j<=i} u[j]*i
        "expr": { "op": "*", "args": [ { "op": "index", "args": ["u", "j"] }, "i" ] }
    });
    let expr: earthsci_ast::types::Expr = serde_json::from_value(node).unwrap();
    let u = vec![1.0, 2.0, 4.0, 8.0, 16.0, 32.0];
    let got = eval_with(&expr, &u);
    // result[i] = i * sum_{j<=i} u[j]
    let want: Vec<f64> = (1..=6)
        .map(|i| i as f64 * u[..i].iter().sum::<f64>())
        .collect();
    assert_eq!(got, want);
}

/// The whole point of recognizing the pattern: work must grow LINEARLY in `N`,
/// not quadratically. Counting body evaluations is the machine-independent way
/// to assert that — a wall-clock threshold would be flaky on a shared cluster.
/// A body evaluation is observable through a division by a per-call counter, so
/// instead we assert the shape indirectly: doubling `N` must not quadruple the
/// time by more than a generous slack, measured on the isolated kernel.
#[test]
fn forward_scan_work_grows_linearly_not_quadratically() {
    use std::time::Instant;

    let timed = |n: usize| -> f64 {
        let u = vec![1.0; n];
        let expr = prefix_agg("<=", n as i64, "+");
        // Warm up, then take the best of several runs to damp scheduler noise.
        let _ = eval_with(&expr, &u);
        (0..5)
            .map(|_| {
                let t0 = Instant::now();
                let _ = eval_with(&expr, &u);
                t0.elapsed().as_secs_f64()
            })
            .fold(f64::INFINITY, f64::min)
    };

    // 16x in N. Quadratic would be ~256x the work; linear ~16x. The assertion
    // uses a very loose 64x ceiling so it fails ONLY on a genuine regression to
    // the triangular loop, never on a slow or contended machine.
    let small = timed(256);
    let large = timed(4096);
    let ratio = large / small.max(1e-9);
    assert!(
        ratio < 64.0,
        "prefix scan looks quadratic: N=256 took {small:.6}s, N=4096 took \
         {large:.6}s (ratio {ratio:.1}x for a 16x increase in N). A linear scan \
         should be near 16x; the triangular fallback would be near 256x."
    );
}

/// Diagnostic (not an assertion): the scanned `<=` against the UNSCANNED `>=` at
/// the same `N` and the same total admitted work. Same fixture, same reducer,
/// same number of admitted terms — the only difference is whether the pattern is
/// recognized — so the ratio isolates the optimization from everything else.
#[test]
fn report_scan_versus_triangle() {
    use std::time::Instant;
    let best = |cmp: &str, n: usize| -> f64 {
        let u = vec![1.0; n];
        let expr = prefix_agg(cmp, n as i64, "+");
        let _ = eval_with(&expr, &u);
        (0..5)
            .map(|_| {
                let t0 = Instant::now();
                let _ = eval_with(&expr, &u);
                t0.elapsed().as_secs_f64()
            })
            .fold(f64::INFINITY, f64::min)
    };
    for n in [256usize, 1024, 4096] {
        let scanned = best("<=", n);
        let triangle = best(">=", n);
        println!(
            "N={n:5}  scanned(<=) {:>10.6}s   triangle(>=) {:>10.6}s   speedup {:>7.1}x",
            scanned,
            triangle,
            triangle / scanned.max(1e-12)
        );
    }
}

/// Rank-2 output: the scan sweeps ONE axis while the other is an independent
/// family of scans. This exercises the axis bookkeeping (moving the scanned axis
/// out of the outer tuple and back into the flat index), which the rank-1 tests
/// above cannot reach — a transposed or mis-strided write would show up here and
/// nowhere else.
#[test]
fn rank_2_output_scans_one_axis_and_leaves_the_other_independent() {
    let (nr, nc) = (3usize, 4usize); // r = independent axis, i = scanned axis
    // m[r, j] = r*10 + j, so every row has a distinct, easily-checked prefix.
    let m: Vec<f64> = {
        let mut v = vec![0.0; nr * nc];
        for r in 1..=nr {
            for j in 1..=nc {
                // row-major fill; ndarray shape is [nr, nc]
                v[(r - 1) * nc + (j - 1)] = (r * 10 + j) as f64;
            }
        }
        v
    };
    let node = json!({
        "op": "aggregate",
        "args": ["m"],
        "output_idx": ["r", "i"],
        "reduce": "+",
        "ranges": { "r": [1, nr], "i": [1, nc], "j": [1, nc] },
        "filter": { "op": "<=", "args": ["j", "i"] },
        "expr": { "op": "index", "args": ["m", "r", "j"] }
    });
    let expr: earthsci_ast::types::Expr = serde_json::from_value(node).unwrap();

    let mut inputs: HashMap<String, ArrayD<f64>> = HashMap::new();
    inputs.insert(
        "m".to_string(),
        ArrayD::from_shape_vec(IxDyn(&[nr, nc]), m.clone()).unwrap(),
    );
    let got = match eval_expression(&expr, &inputs, &[], &[], 0.0).expect("evaluates") {
        earthsci_ast::simulate_array::Value::Array(a) => a,
        other => panic!("expected an array, got {other:?}"),
    };
    assert_eq!(got.shape(), &[nr, nc], "output box shape");

    for r in 1..=nr {
        let mut running = 0.0;
        for i in 1..=nc {
            running += m[(r - 1) * nc + (i - 1)];
            assert_eq!(
                got[IxDyn(&[r - 1, i - 1])],
                running,
                "row {r} prefix at column {i}"
            );
        }
    }
}

/// The mirrored spelling `i >= j` denotes the SAME forward scan as `j <= i` and
/// must be recognized; the un-mirrored `j >= i` is a REVERSE scan and must not
/// be. Both reduce to the same question — which side carries the contracted
/// symbol — and getting it backwards would silently compute the complement.
#[test]
fn mirrored_forward_spelling_matches_and_reverse_spelling_does_not() {
    let u = catastrophic_values(24);
    let n = u.len() as i64;
    let mirrored = json!({
        "op": "aggregate", "args": ["u"], "output_idx": ["i"], "reduce": "+",
        "ranges": { "i": [1, n], "j": [1, n] },
        "filter": { "op": ">=", "args": ["i", "j"] },   // i >= j  ==  j <= i
        "expr": { "op": "index", "args": ["u", "j"] }
    });
    let expr: earthsci_ast::types::Expr = serde_json::from_value(mirrored).unwrap();
    let got = eval_with(&expr, &u);
    let want = oracle(&u, "<=", "+");
    for (k, (g, w)) in got.iter().zip(want.iter()).enumerate() {
        assert_eq!(g.to_bits(), w.to_bits(), "mirrored forward cell {}", k + 1);
    }
    // And the un-mirrored `j >= i` is genuinely the reverse window.
    let rev = eval_with(&prefix_agg(">=", n, "+"), &u);
    let rev_want = oracle(&u, ">=", "+");
    for (k, (g, w)) in rev.iter().zip(rev_want.iter()).enumerate() {
        assert_eq!(g.to_bits(), w.to_bits(), "reverse cell {}", k + 1);
    }
    assert_ne!(got, rev, "forward and reverse windows must differ");
}

/// Scanning axis 0 of a rank-2 output, the mirror image of the axis-1 test.
#[test]
fn rank_2_output_scans_axis_zero() {
    let (nr, nc) = (4usize, 3usize); // i = scanned axis 0, c = independent
    let m: Vec<f64> = (0..nr * nc).map(|k| (k + 1) as f64).collect();
    let node = json!({
        "op": "aggregate", "args": ["m"], "output_idx": ["i", "c"], "reduce": "+",
        "ranges": { "i": [1, nr], "c": [1, nc], "j": [1, nr] },
        "filter": { "op": "<=", "args": ["j", "i"] },
        "expr": { "op": "index", "args": ["m", "j", "c"] }
    });
    let expr: earthsci_ast::types::Expr = serde_json::from_value(node).unwrap();
    let mut inputs: HashMap<String, ArrayD<f64>> = HashMap::new();
    inputs.insert(
        "m".to_string(),
        ArrayD::from_shape_vec(IxDyn(&[nr, nc]), m.clone()).unwrap(),
    );
    let got = match eval_expression(&expr, &inputs, &[], &[], 0.0).expect("evaluates") {
        earthsci_ast::simulate_array::Value::Array(a) => a,
        other => panic!("expected an array, got {other:?}"),
    };
    assert_eq!(got.shape(), &[nr, nc]);
    for c in 1..=nc {
        let mut running = 0.0;
        for i in 1..=nr {
            running += m[(i - 1) * nc + (c - 1)];
            assert_eq!(got[IxDyn(&[i - 1, c - 1])], running, "col {c} row {i}");
        }
    }
}

mod common;

/// Drive the two shared cumulative-reduction fixtures end-to-end and assert
/// their inline `tests` assertions.
///
/// The unit tests above exercise the aggregate kernel directly; this runs the
/// same semantics through load → compile → solve, which is what the Python and
/// Julia bindings do with these fixtures. Without it the Rust side would only
/// cover the kernel, and the manifest's executing-binding claim for `rust` would
/// rest on nothing (the `simulate_arrayop` manifest is not itself executed by any
/// harness — see its README).
#[test]
fn shared_cumulative_fixtures_satisfy_their_inline_assertions() {
    for name in [
        "fixtures/arrayop/25_cumulative_prefix_reduction.esm",
        "fixtures/arrayop/26_cumulative_integral_measure.esm",
    ] {
        let path = common::repo_fixture(name);
        let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {name}: {e}"));
        let doc: serde_json::Value = serde_json::from_str(&raw).expect("fixture is JSON");
        let file = earthsci_ast::load_string(&raw).unwrap_or_else(|e| panic!("load {name}: {e}"));

        let models = doc["models"].as_object().expect("models object");
        for (model_name, model) in models {
            let tol = &model["tolerance"];
            let rel = tol["rel"].as_f64().unwrap_or(0.0);
            let abs_tol = tol["abs"].as_f64().unwrap_or(0.0);
            for test in model["tests"].as_array().into_iter().flatten() {
                let end = test["time_span"]["end"].as_f64().expect("time_span.end");
                let sol = earthsci_ast::simulate(
                    &file,
                    (0.0, end),
                    &std::collections::HashMap::new(),
                    &std::collections::HashMap::new(),
                    &earthsci_ast::SimulateOptions::default(),
                )
                .unwrap_or_else(|e| panic!("{name}::{model_name} simulate: {e}"));

                for a in test["assertions"].as_array().into_iter().flatten() {
                    let var = a["variable"].as_str().expect("assertion variable");
                    let want = a["expected"].as_f64().expect("assertion expected");
                    let idx = sol
                        .state_variable_names
                        .iter()
                        .position(|v| v == var || v.ends_with(&format!(".{var}")))
                        .unwrap_or_else(|| {
                            panic!("{name}: {var} not in {:?}", sol.state_variable_names)
                        });
                    let got = *sol.state[idx].last().expect("a final value");
                    let tol_abs = abs_tol.max(rel * want.abs());
                    assert!(
                        (got - want).abs() <= tol_abs,
                        "{name}::{model_name} {var}: got {got}, want {want} (tol {tol_abs})"
                    );
                }
            }
        }
    }
}
