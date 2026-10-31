//! The one-pass equality scatter (`lower/scatter.rs`): which lowering each
//! shape takes, bit-identical to the interpreter in both executors.

use super::ir::*;
use super::tests::ab_check;
use serde_json::{Value, json};

fn count(prog: &TapeProgram, opcode: &str) -> usize {
    prog.instrs.iter().filter(|i| i.opcode() == opcode).count()
}

fn fixture(rel: &str) -> Value {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel);
    let text = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    serde_json::from_str(&text).expect("fixture is JSON")
}

/// `D(u[j]) = Σ_{i : filter} body` over `j, i ∈ [1, n]`.
fn scatter_doc(n: i64, filter: Value, body: Value) -> Value {
    json!({
        "esm": "1.3.0",
        "metadata": {"name": "scatter_tape", "authors": ["tape tests"]},
        "index_sets": {"x": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0}},
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["j"], "ranges": {"j": {"from": "x"}},
                        "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "j"]}], "wrt": "t"}},
                "rhs": {"op": "faq", "args": [], "output_idx": ["j"], "reduce": "+",
                        "ranges": {"j": {"from": "x"}, "i": {"from": "x"}},
                        "filter": filter, "expr": body}
            }]
        }}
    })
}

/// The band transpose's unit shifts are stencil reads: no tuple list, no
/// contracted box.
#[test]
fn a_unit_shift_scatter_lowers_without_a_tuple_list_or_a_box() {
    let prog = ab_check(
        fixture("tests/conformance/scaling/fixtures/band_transpose/band_transpose_N1000.esm"),
        -2.0,
        2.0,
    );
    assert_eq!(count(&prog, "SegReduce"), 0);
    assert_eq!(count(&prog, "Reduce"), 0);
}

/// A pin that is not a unit shift takes the build-time scatter map: one
/// segmented reduction, no dense reduction.
#[test]
fn a_non_shift_pin_lowers_to_one_segmented_reduction() {
    let body = json!({"op": "index", "args": ["u", "i"]});
    for filter in [
        json!({"op": "==", "args": ["j", {"op": "/", "args": ["i", 2]}]}),
        json!({"op": "==", "args": [{"op": "-", "args": [10, "i"]}, "j"]}),
        json!({"op": "and", "args": [
            {"op": "==", "args": ["j", {"op": "+", "args": ["i", 1]}]},
            {"op": ">", "args": [{"op": "index", "args": ["u", "i"]}, 0]}]}),
    ] {
        let prog = ab_check(scatter_doc(12, filter.clone(), body.clone()), -2.0, 2.0);
        assert_eq!(count(&prog, "SegReduce"), 1, "{filter}");
        assert_eq!(count(&prog, "Reduce"), 0, "{filter}");
    }
}

/// A pin that reads the state has no build-time map: the dense lowering.
#[test]
fn a_run_time_pin_keeps_the_dense_lowering() {
    let prog = ab_check(
        scatter_doc(
            6,
            json!({"op": "==", "args": ["j", {"op": "index", "args": ["u", "i"]}]}),
            json!({"op": "index", "args": ["u", "i"]}),
        ),
        -2.0,
        2.0,
    );
    assert_eq!(count(&prog, "SegReduce"), 0);
}
