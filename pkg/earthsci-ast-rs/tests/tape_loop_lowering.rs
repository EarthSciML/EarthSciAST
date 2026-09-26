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
    /// Folds: `Reduce` instructions plus reductions fusion absorbed.
    reductions: usize,
    /// Instruction counts per opcode.
    opcodes: HashMap<String, usize>,
}

impl Checked {
    fn count(&self, opcode: &str) -> usize {
        self.opcodes.get(opcode).copied().unwrap_or(0)
    }
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
        reductions: report
            .opcode_counts
            .iter()
            .find(|(k, _)| k == "Reduce")
            .map_or(0, |(_, n)| *n)
            + report.fuse.n_reduces_folded,
        opcodes: report.opcode_counts.iter().cloned().collect(),
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
    // Both sizes above eight rows: fusion folds a broadcast read into its
    // consumer by the run schedule it would need, and a box of at most eight
    // runs always qualifies.
    let c = flat_in_n(make, 12, 90);
    assert_eq!(c.rules, 3);
}

// ---------------------------------------------------------------------------
// Prefix scans
// ---------------------------------------------------------------------------

fn faq(output_idx: Value, ranges: Value, expr: Value) -> Value {
    json!({"op": "faq", "args": [], "output_idx": output_idx, "ranges": ranges, "expr": expr})
}

fn deriv_faq(var: &str, idx: &[&str], ranges: Value, rhs_expr: Value) -> Value {
    let mut ix = vec![json!(var)];
    ix.extend(idx.iter().map(|i| json!(i)));
    json!({
        "lhs": {"op": "faq", "args": [], "output_idx": idx,
                "expr": {"op": "D", "args": [{"op": "index", "args": ix}], "wrt": "t"},
                "ranges": ranges.clone()},
        "rhs": faq(json!(idx), ranges, rhs_expr)
    })
}

fn index(args: Value) -> Value {
    op("index", args)
}

/// The scaling tier's `prefix_scan` family: an inclusive measure-weighted
/// running sum over a non-uniform layer thickness, feeding the right-hand side.
#[test]
fn a_prefix_scan_is_one_instruction() {
    let make = |n: i64| {
        let mut burden = faq(
            json!(["i"]),
            json!({"i": {"from": "x"}, "j": {"from": "x"}}),
            op(
                "*",
                json!([index(json!(["u", "j"])), index(json!(["dz", "j"]))]),
            ),
        );
        burden["filter"] = op("<=", json!(["j", "i"]));
        burden["reduce"] = json!("+");
        doc(
            json!({"x": {"kind": "interval", "size": n}}),
            json!({
                "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
                "dz": {"type": "unknown", "units": "1", "shape": ["x"]},
                "b": {"type": "unknown", "units": "1", "shape": ["x"]}
            }),
            json!([
                {"lhs": "dz", "rhs": faq(json!(["i"]), json!({"i": {"from": "x"}}),
                    op("*", json!([100.0, op("+", json!([1, op("*", json!([0.5, op("sin", json!(["i"]))]))]))])))},
                deriv_faq("u", &["i"], json!({"i": {"from": "x"}}),
                    op("*", json!([-0.001, index(json!(["b", "i"]))]))),
                {"lhs": "b", "rhs": burden}
            ]),
        )
    };
    let c = flat_in_n(make, 9, 400);
    assert_eq!(c.count("Scan"), 1);
    assert_eq!(c.count("Region"), 0, "no per-step region writes");
}

/// Every forward spelling and semiring, along either axis of a rank-2 box
/// whose other axis the body reads.
#[test]
fn prefix_scans_along_either_axis_match_the_oracle() {
    for (cmp, scanned_first) in [("<=", true), ("<", true), (">=", false), (">", false)] {
        for reduce in ["+", "*", "max", "min"] {
            for axis in [0usize, 1] {
                let make = |n: i64| {
                    // `c[i, k]` scans along `i` (axis 0) or `k` (axis 1); the
                    // body reads the other output symbol as a value.
                    let (scanned, other) = if axis == 0 { ("i", "k") } else { ("k", "i") };
                    let filter = if scanned_first {
                        op(cmp, json!(["j", scanned]))
                    } else {
                        op(cmp, json!([scanned, "j"]))
                    };
                    let q_ix = if axis == 0 {
                        json!(["q", "j", "k"])
                    } else {
                        json!(["q", "i", "j"])
                    };
                    let mut ranges = json!({"i": {"from": "x"}, "k": {"from": "y"}});
                    ranges["j"] = json!({"from": if axis == 0 { "x" } else { "y" }});
                    let mut c = faq(
                        json!(["i", "k"]),
                        ranges,
                        op(
                            "*",
                            json!([
                                index(q_ix),
                                op("+", json!([1.0, op("*", json!([0.01, other]))]))
                            ]),
                        ),
                    );
                    c["filter"] = filter;
                    c["reduce"] = json!(reduce);
                    let (nx, ny) = if axis == 0 { (n, 3) } else { (3, n) };
                    doc(
                        json!({"x": {"kind": "interval", "size": nx}, "y": {"kind": "interval", "size": ny}}),
                        json!({
                            "q": {"type": "unknown", "units": "1", "shape": ["x", "y"], "default": 1.0},
                            "c": {"type": "unknown", "units": "1", "shape": ["x", "y"]}
                        }),
                        json!([
                            deriv_faq("q", &["i", "k"],
                                json!({"i": {"from": "x"}, "k": {"from": "y"}}),
                                op("*", json!([-0.5, index(json!(["c", "i", "k"]))]))),
                            {"lhs": "c", "rhs": c}
                        ]),
                    )
                };
                let a = check(&make(4));
                let b = check(&make(60));
                assert_eq!(a.code_size, b.code_size, "{cmp} {reduce} axis {axis}");
                assert_eq!(b.count("Scan"), 1, "{cmp} {reduce} axis {axis}");
            }
        }
    }
}

/// A scan body the whole-box form cannot lower (a strided read, `u[2j]`,
/// which is no per-axis shift of the box) keeps the per-step form, and still
/// agrees with the oracle — the whole-box attempt leaves nothing behind.
#[test]
fn a_scan_body_without_a_whole_box_form_keeps_the_per_step_form() {
    let mut burden = faq(
        json!(["i"]),
        json!({"i": {"from": "x"}, "j": {"from": "x"}}),
        op(
            "+",
            json!([
                index(json!(["u", op("*", json!([2, "j"]))])),
                op("*", json!([0.25, index(json!(["u", "j"]))]))
            ]),
        ),
    );
    burden["filter"] = op("<", json!(["j", "i"]));
    let d = doc(
        json!({"x": {"kind": "interval", "size": 11}}),
        json!({
            "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
            "b": {"type": "unknown", "units": "1", "shape": ["x"]}
        }),
        json!([
            deriv_faq("u", &["i"], json!({"i": {"from": "x"}}), index(json!(["b", "i"]))),
            {"lhs": "b", "rhs": burden}
        ]),
    );
    let c = check(&d);
    assert_eq!(c.count("Scan"), 0);
    assert!(c.count("Region") >= 11, "one region write per step");
}

// ---------------------------------------------------------------------------
// Contractions
// ---------------------------------------------------------------------------

/// The scaling tier's `source_receptor` family: a dense square contraction
/// over a non-uniform matrix the document defines by formula.
#[test]
fn a_dense_contraction_is_one_reduction() {
    let make = |n: i64| {
        doc(
            json!({"rcv": {"kind": "interval", "size": n}, "src": {"kind": "interval", "size": n}}),
            json!({
                "c": {"type": "unknown", "units": "1", "shape": ["rcv"], "default": 0.0},
                "e": {"type": "unknown", "units": "1", "shape": ["src"], "default": 1.0},
                "K": {"type": "unknown", "units": "1", "shape": ["rcv", "src"]},
                "kd": {"type": "parameter", "units": "1", "default": 0.1}
            }),
            json!([
                {"lhs": "K", "rhs": faq(json!(["i", "j"]),
                    json!({"i": {"from": "rcv"}, "j": {"from": "src"}}),
                    op("*", json!([0.001, op("+", json!([1, op("sin", json!([op("*", json!(["i", "j"]))]))]))])))},
                deriv_faq("c", &["i"], json!({"i": {"from": "rcv"}, "j": {"from": "src"}}),
                    op("*", json!([index(json!(["K", "i", "j"])), index(json!(["e", "j"]))]))),
                deriv_faq("e", &["j"], json!({"j": {"from": "src"}}),
                    op("*", json!([op("-", json!(["kd"])), index(json!(["e", "j"]))])))
            ]),
        )
    };
    let c = flat_in_n(make, 6, 150);
    assert_eq!(c.reductions, 1);
}

/// Two contracted indices, every semiring: the fold visits the window in the
/// oracle's order (the last contracted name fastest), whether the contraction
/// is looped or — for a window read that mixes an output and a contracted
/// symbol — unrolled.
#[test]
fn a_two_index_contraction_folds_in_the_oracle_order() {
    for reduce in ["+", "*", "max", "min"] {
        // Looped: every read is a map of one box symbol.
        let looped = |n: i64| {
            let mut rhs = faq(
                json!(["i"]),
                json!({"i": {"from": "x"}, "a": {"from": "y"}, "b": {"from": "z"}}),
                op(
                    "*",
                    json!([
                        index(json!(["W", "i", "a", "b"])),
                        index(json!(["v", "a"])),
                        op("+", json!([1.0, index(json!(["v", "b"]))]))
                    ]),
                ),
            );
            rhs["reduce"] = json!(reduce);
            doc(
                json!({"x": {"kind": "interval", "size": n}, "y": {"kind": "interval", "size": 4},
                       "z": {"kind": "interval", "size": 4}}),
                json!({
                    "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 0.0},
                    "v": {"type": "unknown", "units": "1", "shape": ["y"], "default": 1.0},
                    "W": {"type": "unknown", "units": "1", "shape": ["x", "y", "z"]}
                }),
                json!([
                    {"lhs": "W", "rhs": faq(json!(["i", "a", "b"]),
                        json!({"i": {"from": "x"}, "a": {"from": "y"}, "b": {"from": "z"}}),
                        op("cos", json!([op("+", json!([op("*", json!([0.7, "i"])), op("*", json!([1.3, "a"])), op("*", json!([2.9, "b"]))]))])))},
                    {"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                             "expr": {"op": "D", "args": [index(json!(["u", "i"]))], "wrt": "t"},
                             "ranges": {"i": {"from": "x"}}},
                     "rhs": rhs},
                    deriv_faq("v", &["a"], json!({"a": {"from": "y"}}), index(json!(["v", "a"])))
                ]),
            )
        };
        let c = flat_in_n(looped, 3, 40);
        assert_eq!(c.reductions, 1, "{reduce}");

        // Unrolled: `u[i + a - b]` mixes an output and two contracted symbols.
        let mut rhs = faq(
            json!(["i"]),
            json!({"i": [1, 30], "a": [0, 2], "b": [0, 3]}),
            op(
                "*",
                json!([
                    index(json!([
                        "u",
                        op("-", json!([op("+", json!(["i", "a"])), "b"]))
                    ])),
                    op(
                        "+",
                        json!([op("*", json!([0.3, "a"])), op("*", json!([1.7, "b"])), 0.1])
                    )
                ]),
            ),
        );
        rhs["reduce"] = json!(reduce);
        let unrolled = doc(
            json!({}),
            json!({"u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0}}),
            json!([{"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                            "expr": {"op": "D", "args": [index(json!(["u", "i"]))], "wrt": "t"},
                            "ranges": {"i": [1, 30]}},
                    "rhs": rhs}]),
        );
        let c = check(&unrolled);
        assert_eq!(c.reductions, 0, "{reduce}: the window stays unrolled");
    }
}

/// A filter that is not a prefix scan masks each excluded tuple's term.
#[test]
fn a_filtered_contraction_is_one_reduction() {
    for cmp in [">=", "!=", ">"] {
        let make = |n: i64| {
            let mut rhs = faq(
                json!(["i"]),
                json!({"i": {"from": "x"}, "j": {"from": "x"}}),
                op(
                    "*",
                    json!([
                        index(json!(["u", "j"])),
                        op("+", json!(["i", op("*", json!([0.1, "j"]))]))
                    ]),
                ),
            );
            rhs["filter"] = op(cmp, json!(["j", "i"]));
            doc(
                json!({"x": {"kind": "interval", "size": n}}),
                json!({"u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0}}),
                json!([{"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                                "expr": {"op": "D", "args": [index(json!(["u", "i"]))], "wrt": "t"},
                                "ranges": {"i": {"from": "x"}}},
                        "rhs": rhs}]),
            )
        };
        let c = flat_in_n(make, 5, 120);
        assert_eq!(c.reductions, 1, "{cmp}");
    }
}

// ---------------------------------------------------------------------------
// makearray
// ---------------------------------------------------------------------------

fn makearray(regions: Vec<Value>, values: Vec<Value>) -> Value {
    json!({"op": "makearray", "args": [], "regions": regions, "values": values})
}

/// A table of one literal region per cell (the shape of a join's code table)
/// is one constant array, however many regions it has.
#[test]
fn a_literal_region_table_is_one_constant() {
    let make = |n: i64| {
        let regions: Vec<Value> = (1..=n).map(|p| json!([[p, p]])).collect();
        let values: Vec<Value> = (1..=n)
            .map(|p| json!(0.5 + 0.25 * (p % 7) as f64))
            .collect();
        doc(
            json!({"x": {"kind": "interval", "size": n}}),
            json!({
                "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
                "tab": {"type": "unknown", "units": "1", "shape": ["x"]}
            }),
            json!([
                {"lhs": "tab", "rhs": makearray(regions, values)},
                deriv_faq("u", &["i"], json!({"i": {"from": "x"}}),
                    op("*", json!([index(json!(["tab", "i"])), index(json!(["u", "i"]))])))
            ]),
        )
    };
    let c = flat_in_n(make, 5, 200);
    assert_eq!(c.count("Region"), 0);
}

/// A boundary-dispatch `makearray` (the shape every discretization template
/// expands to): one instruction assembling the regions, with no per-region
/// copy of the box; later regions overwrite earlier ones.
#[test]
fn a_boundary_dispatch_makearray_is_one_instruction() {
    let make = |n: i64| {
        let interior = index(json!(["u", op("-", json!(["i", 1]))]));
        let regions = vec![
            json!([[1, n]]),
            json!([[1, 1]]),
            json!([[2, n - 1]]),
            json!([[n, n]]),
        ];
        let values = vec![
            json!(7.0),
            op("*", json!([2.0, index(json!(["u", "i"]))])),
            op(
                "-",
                json!([index(json!(["u", op("+", json!(["i", 1]))])), interior]),
            ),
            op("-", json!([index(json!(["u", "i"]))])),
        ];
        doc(
            json!({"x": {"kind": "interval", "size": n}}),
            json!({"u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0}}),
            json!([deriv_faq(
                "u",
                &["i"],
                json!({"i": {"from": "x"}}),
                op(
                    "*",
                    json!([0.5, index(json!([makearray(regions, values), "i"]))])
                )
            )]),
        )
    };
    let c = flat_in_n(make, 6, 300);
    assert_eq!(c.count("Region"), 0);
    assert_eq!(c.count("Assemble"), 1);
}
