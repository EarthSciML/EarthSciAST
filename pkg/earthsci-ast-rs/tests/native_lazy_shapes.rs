//! Shapes the native compiler used to refuse, run under `native` and the
//! per-cell interpreter (the oracle), which must agree to the bit and to the
//! message:
//!
//! * a rank-0 `faq` nested in an array `faq` body, with and without a read of
//!   the enclosing box;
//! * a runtime-scalar `ifelse` whose arms are a scalar and an array;
//! * an initial condition given by a gather of an inline `const`;
//! * an out-of-range const-array read behind a condition: the fault fires
//!   exactly where the oracle reaches the read, with the message of the first
//!   such cell (CONFORMANCE_SPEC §5.5.5).

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Compiler, InlineTestOptions, load_string, run_inline_tests_with_options};
use serde_json::{Value, json};

const C4: [f64; 4] = [10.0, 20.0, 30.0, 40.0];

fn c4() -> Value {
    json!({"op": "const", "args": [], "value": C4.to_vec()})
}

fn ix(base: Value, sub: Value) -> Value {
    json!({"op": "index", "args": [base, sub]})
}

fn op(o: &str, args: Vec<Value>) -> Value {
    json!({"op": o, "args": args})
}

fn faq(out: &[&str], set: &[&str], expr: Value) -> Value {
    let ranges: serde_json::Map<String, Value> = out
        .iter()
        .zip(set)
        .map(|(s, f)| (s.to_string(), json!({"from": f})))
        .collect();
    json!({"op": "faq", "args": [], "output_idx": out, "ranges": ranges, "expr": expr})
}

/// A one-model document: `variables`, `equations`, one test at `t = 0`
/// with `assertions`.
fn doc(variables: Value, equations: Value, assertions: Value) -> String {
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "native_lazy_shapes", "authors": ["test"]},
        "index_sets": {
            "rows": {"kind": "interval", "size": 4},
            "nodes": {"kind": "interval", "size": 5}
        },
        "models": {"M": {
            "tolerance": {"rel": 1e-12},
            "variables": variables,
            "equations": equations,
            "tests": [{"id": "t", "time_span": {"start": 0.0, "end": 0.0},
                       "assertions": assertions}]
        }}
    })
    .to_string()
}

/// Run `text`'s inline tests under the interpreter and under native; they
/// must agree on every assertion's verdict, value and message. Returns the
/// interpreter's results as `(passed, message)`.
fn agree(text: &str) -> Vec<(bool, String)> {
    let file = load_string(text).expect("document loads");
    let run = |compiler| {
        run_inline_tests_with_options(
            &file,
            &InlineTestOptions {
                model_name: Some("M".to_string()),
                compiler: Some(compiler),
                ..Default::default()
            },
            None,
        )
    };
    let oracle = run(Compiler::Interpreter);
    let native = run(Compiler::Native);
    assert_eq!(oracle.len(), native.len());
    for (o, n) in oracle.iter().zip(&native) {
        assert_eq!(
            (o.passed, &o.message, o.actual.map(f64::to_bits)),
            (n.passed, &n.message, n.actual.map(f64::to_bits)),
            "native and the interpreter disagree"
        );
    }
    oracle
        .into_iter()
        .map(|r| (r.passed, r.message))
        .collect()
}

fn all_pass(rs: &[(bool, String)]) {
    for (ok, msg) in rs {
        assert!(ok, "expected a pass: {msg}");
    }
}

fn all_fault(rs: &[(bool, String)], raw: i64) {
    let want = format!("index {raw}");
    for (ok, msg) in rs {
        assert!(
            !ok && msg.contains("E_TREEWALK_CONSTARRAY_OOB") && msg.contains(&want),
            "expected the out-of-range fault at subscript {raw}: {msg}"
        );
    }
}

fn unknown(shape: &[&str]) -> Value {
    json!({"type": "unknown", "units": "1", "shape": shape})
}

fn param_rows() -> Value {
    json!({"type": "parameter", "units": "1", "shape": ["rows"],
           "default": [1.0, 2.0, 3.0, 4.0]})
}

fn scalar_param(v: f64) -> Value {
    json!({"type": "parameter", "units": "1", "default": v})
}

fn at(var: &str, set: &str, k: i64, v: f64) -> Value {
    json!({"variable": var, "time": 0.0, "expected": v, "coords": {set: k}})
}

#[test]
fn a_guard_that_keeps_every_out_of_range_read_untaken_raises_nothing() {
    // y[i] over nodes(5) = ifelse(i <= 1, 0, ifelse(i > 4, 0, (c[i] + c[i-1]) / 2))
    let body = op(
        "ifelse",
        vec![
            op("<=", vec![json!("i"), json!(1)]),
            json!(0),
            op(
                "ifelse",
                vec![
                    op(">", vec![json!("i"), json!(4)]),
                    json!(0),
                    op(
                        "*",
                        vec![
                            json!(0.5),
                            op(
                                "+",
                                vec![
                                    ix(c4(), json!("i")),
                                    ix(c4(), op("-", vec![json!("i"), json!(1)])),
                                ],
                            ),
                        ],
                    ),
                ],
            ),
        ],
    );
    let text = doc(
        json!({"y": unknown(&["nodes"])}),
        json!([{"lhs": "y", "rhs": faq(&["i"], &["nodes"], body)}]),
        json!([at("y", "nodes", 1, 0.0), at("y", "nodes", 2, 15.0), at("y", "nodes", 5, 0.0)]),
    );
    all_pass(&agree(&text));
}

#[test]
fn a_guard_that_reaches_an_out_of_range_read_raises_it() {
    // y[i] over nodes(5) = ifelse(i > 4, c[i], 0): taken at i = 5.
    let body = op(
        "ifelse",
        vec![op(">", vec![json!("i"), json!(4)]), ix(c4(), json!("i")), json!(0)],
    );
    let text = doc(
        json!({"y": unknown(&["nodes"])}),
        json!([{"lhs": "y", "rhs": faq(&["i"], &["nodes"], body)}]),
        json!([at("y", "nodes", 1, 0.0)]),
    );
    all_fault(&agree(&text), 5);
}

/// `y[i] = ifelse(p[i] > a, c[i+1], 0) + ifelse(p[i] < b, c[i-1], 0)` with
/// `p = [1, 2, 3, 4]`: the first arm faults at i = 4 (subscript 5) when
/// `a < 4`, the second at i = 1 (subscript 0) when `b > 1`. The oracle meets
/// i = 1 first, so it reports subscript 0 whenever both are reached.
fn two_guards(a: f64, b: f64) -> String {
    let body = op(
        "+",
        vec![
            op(
                "ifelse",
                vec![
                    op(">", vec![ix(json!("p"), json!("i")), json!("a")]),
                    ix(c4(), op("+", vec![json!("i"), json!(1)])),
                    json!(0),
                ],
            ),
            op(
                "ifelse",
                vec![
                    op("<", vec![ix(json!("p"), json!("i")), json!("b")]),
                    ix(c4(), op("-", vec![json!("i"), json!(1)])),
                    json!(0),
                ],
            ),
        ],
    );
    doc(
        json!({"p": param_rows(), "a": scalar_param(a), "b": scalar_param(b),
               "y": unknown(&["rows"])}),
        json!([{"lhs": "y", "rhs": faq(&["i"], &["rows"], body)}]),
        json!([at("y", "rows", 2, if a < 2.0 { 30.0 } else { 0.0 }
                   + if b > 2.0 { 10.0 } else { 0.0 })]),
    )
}

#[test]
fn a_runtime_array_guard_faults_at_the_first_cell_it_admits() {
    all_pass(&agree(&two_guards(10.0, 0.0)));
    all_fault(&agree(&two_guards(3.5, 0.0)), 5);
    all_fault(&agree(&two_guards(10.0, 1.5)), 0);
    all_fault(&agree(&two_guards(3.5, 1.5)), 0);
}

/// `y[i] = ifelse(flag > 0.5, c[i+1], 0)`: a runtime-scalar branch.
fn scalar_branch(flag: f64) -> String {
    let body = op(
        "ifelse",
        vec![
            op(">", vec![json!("flag"), json!(0.5)]),
            ix(c4(), op("+", vec![json!("i"), json!(1)])),
            json!(0),
        ],
    );
    doc(
        json!({"flag": scalar_param(flag), "y": unknown(&["rows"])}),
        json!([{"lhs": "y", "rhs": faq(&["i"], &["rows"], body)}]),
        json!([at("y", "rows", 1, 0.0)]),
    )
}

#[test]
fn a_scalar_branch_faults_only_when_taken() {
    all_pass(&agree(&scalar_branch(0.0)));
    all_fault(&agree(&scalar_branch(1.0)), 5);
}

/// `s = sum_j c[j+1] filter (p[j] < thr)`, a filtered scalar reduction.
fn filtered_sum(thr: f64) -> String {
    let mut sum = faq(&[], &[], ix(c4(), op("+", vec![json!("j"), json!(1)])));
    sum["ranges"] = json!({"j": {"from": "rows"}});
    sum["filter"] = op("<", vec![ix(json!("p"), json!("j")), json!("thr")]);
    doc(
        json!({"p": param_rows(), "thr": scalar_param(thr),
               "s": {"type": "unknown", "units": "1"}}),
        json!([{"lhs": "s", "rhs": sum}]),
        json!([{"variable": "s", "time": 0.0, "expected": 90.0}]),
    )
}

#[test]
fn a_filtered_term_faults_only_where_the_filter_keeps_it() {
    all_pass(&agree(&filtered_sum(3.5)));
    all_fault(&agree(&filtered_sum(10.0)), 5);
}

/// `y[i] = (sum_j x[j]) * x[i]` and `z[i] = sum_j c[j] * x[j] filter (j != i)`
/// with `x = 2 p`.
#[test]
fn a_rank_0_faq_nested_in_a_box_reduces_per_cell() {
    let x = faq(
        &["r"],
        &["rows"],
        op("*", vec![json!(2.0), ix(json!("p"), json!("r"))]),
    );
    let mut total = faq(&[], &[], ix(json!("x"), json!("j")));
    total["ranges"] = json!({"j": {"from": "rows"}});
    let y = faq(
        &["i"],
        &["rows"],
        op("*", vec![total, ix(json!("x"), json!("i"))]),
    );
    let mut others = faq(
        &[],
        &[],
        op("*", vec![ix(c4(), json!("j")), ix(json!("x"), json!("j"))]),
    );
    others["ranges"] = json!({"j": {"from": "rows"}});
    others["filter"] = op("!=", vec![json!("j"), json!("i")]);
    let z = faq(&["i"], &["rows"], op("+", vec![others, json!(1.0)]));
    let text = doc(
        json!({"p": param_rows(), "x": unknown(&["rows"]), "y": unknown(&["rows"]),
               "z": unknown(&["rows"])}),
        json!([{"lhs": "x", "rhs": x}, {"lhs": "y", "rhs": y}, {"lhs": "z", "rhs": z}]),
        json!([
            at("y", "rows", 1, 40.0),
            at("y", "rows", 4, 160.0),
            // x = [2, 4, 6, 8], c·x = 20 + 80 + 180 + 320 = 600.
            at("z", "rows", 1, 600.0 - 20.0 + 1.0),
            at("z", "rows", 4, 600.0 - 320.0 + 1.0)
        ]),
    );
    all_pass(&agree(&text));
}

/// `y[i] = ifelse(flag > 0.5, 0, x[i])`.
fn mixed_arms(flag: f64) -> String {
    let x = faq(
        &["r"],
        &["rows"],
        op("*", vec![json!(2.0), ix(json!("p"), json!("r"))]),
    );
    let y = faq(
        &["i"],
        &["rows"],
        op(
            "ifelse",
            vec![
                op(">", vec![json!("flag"), json!(0.5)]),
                json!(0.0),
                ix(json!("x"), json!("i")),
            ],
        ),
    );
    doc(
        json!({"p": param_rows(), "flag": scalar_param(flag), "x": unknown(&["rows"]),
               "y": unknown(&["rows"])}),
        json!([{"lhs": "x", "rhs": x}, {"lhs": "y", "rhs": y}]),
        json!([at("y", "rows", 3, if flag > 0.5 { 0.0 } else { 6.0 })]),
    )
}

#[test]
fn a_scalar_condition_over_a_scalar_and_an_array_arm_broadcasts() {
    all_pass(&agree(&mixed_arms(0.0)));
    all_pass(&agree(&mixed_arms(1.0)));
}

#[test]
fn an_initial_condition_gathered_from_an_inline_const() {
    let table = json!({"op": "const", "args": [], "value": [[1.0, 2.0], [3.0, 4.0]]});
    let ic = json!({"op": "faq", "args": [], "output_idx": ["i", "j"],
                    "ranges": {"i": {"from": "rows"}, "j": {"from": "rows2"}},
                    "expr": {"op": "index", "args": [table, "i", "j"]}});
    let text = json!({
        "esm": "1.2.0",
        "metadata": {"name": "ic_gather", "authors": ["test"]},
        "index_sets": {"rows": {"kind": "interval", "size": 2},
                       "rows2": {"kind": "interval", "size": 2}},
        "models": {"M": {
            "tolerance": {"rel": 1e-12},
            "variables": {"u": unknown(&["rows", "rows2"])},
            "equations": [
                {"lhs": {"op": "ic", "args": ["u"]}, "rhs": ic},
                {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                 "rhs": faq(&["i", "j"], &["rows", "rows2"], json!(0.0))}
            ],
            "tests": [{"id": "t", "time_span": {"start": 0.0, "end": 1.0},
                       "assertions": [
                           {"variable": "u", "time": 1.0, "expected": 2.0,
                            "coords": {"rows": 1, "rows2": 2}},
                           {"variable": "u", "time": 1.0, "expected": 3.0,
                            "coords": {"rows": 2, "rows2": 1}}]}]
        }}
    })
    .to_string();
    all_pass(&agree(&text));
}
