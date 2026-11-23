//! The pure-AST interpolation templates of `lib/interp.esm` (`searchsorted`,
//! `linear`, `bilinear`) on the tape. Applied with `const` tables and axes and
//! a literal axis length, each expansion's bracket is a rank-0 indicator sum
//! over `[1, n]`, which the count rewrite states as one `Instr::Count`. Pinned
//! for a scalar query and for a per-cell query inside a `faq` over an index
//! set (`faq_l linear(table, axis, q[l], n)`):
//!
//!   * every rule is taped, and every executor writes the per-cell oracle's
//!     `dy` bit for bit ([`oracle_ab`]);
//!   * each bracket is counted once, however many times the body repeats its
//!     sub-tree (value numbering shares the identical interned node), and no
//!     general fold is left;
//!   * the per-cell program does not grow with the number of cells.

use super::ir::*;
use super::template_fixtures::{AXIS, Lookup, TABLE, lookup_model};
use super::test_support::{apply, counts, flat_in_n, konst, library, op, opcount, oracle_ab};
use serde_json::{Value, json};

/// The counts each lookup's expansion should leave: one per bracket.
fn expected_counts(which: Lookup) -> Vec<(CountRel, bool)> {
    match which {
        Lookup::Searchsorted => vec![(CountRel::Ge, true)],
        Lookup::Linear => vec![(CountRel::Le, true)],
        Lookup::Bilinear => vec![(CountRel::Le, true), (CountRel::Le, true)],
    }
}

const LOOKUPS: [(Lookup, &str); 3] = [
    (Lookup::Searchsorted, "searchsorted"),
    (Lookup::Linear, "linear"),
    (Lookup::Bilinear, "bilinear"),
];

#[test]
#[ignore = "native compiles references once: QUESTIONS.md Q1"]
fn interp_templates_per_cell_query_count_once() {
    for (which, name) in LOOKUPS {
        let prog = flat_in_n(|m| lookup_model(which, Some(m), false), 4, 33);
        assert_eq!(counts(&prog), expected_counts(which), "{name}: per cell");
        assert_eq!(opcount(&prog, "Reduce"), 0, "{name}: no fold is left");
        oracle_ab(lookup_model(which, Some(17), false));
    }
}

#[test]
#[ignore = "native compiles references once: QUESTIONS.md Q1"]
fn interp_templates_scalar_query_count_once() {
    for (which, name) in LOOKUPS {
        let (prog, _) = oracle_ab(lookup_model(which, None, false));
        assert_eq!(counts(&prog), expected_counts(which), "{name}: scalar");
        assert_eq!(opcount(&prog, "Reduce"), 0, "{name}: no fold is left");
    }
}

/// A NaN query: searchsorted counts every knot (`n + 1`), linear and
/// bilinear propagate the NaN, through the counts, as the oracle does.
#[test]
#[ignore = "native compiles references once: QUESTIONS.md Q1"]
fn interp_templates_nan_query() {
    for (which, name) in LOOKUPS {
        for cells in [None, Some(5)] {
            let (prog, _) = oracle_ab(lookup_model(which, cells, true));
            assert_eq!(counts(&prog).len(), expected_counts(which).len(), "{name}");
        }
    }
}

// ---------------------------------------------------------------------------
// The scalar lookup's instructions in the executor's scalar loop: loads,
// one-element gathers, counts and the `ifelse` jumps run there, and every
// case they do not cover (a gather that faults, an unsorted window) still
// writes the oracle's `dy` and latches its fault.
// ---------------------------------------------------------------------------

/// A document of a scalar query state `s`, a rank-1 state `u` over `i` in
/// `[1, n]` whose derivative reads the scalar observed `c = body`, with the
/// interpolation library loaded.
fn scalar_lookup_doc(n: i64, body: Value) -> Value {
    use super::test_support::{d_eq, doc, idx};
    let mut d = doc(
        json!({
            "u": {"type": "unknown", "shape": ["i"]},
            "s": {"type": "unknown"},
            "c": {"type": "unknown"}
        }),
        vec![
            json!({"lhs": "c", "rhs": body}),
            d_eq(
                "u",
                n,
                op("*", vec![json!("c"), idx(json!("u"), &[json!("i")])]),
            ),
            json!({"lhs": {"op": "D", "args": ["s"], "wrt": "t"},
                   "rhs": op("*", vec![json!(-0.1), json!("s")])}),
        ],
    );
    d["models"]["M"]["operators"] = library("interp.esm");
    d
}

/// The executor's scalar loop of a lookup: `linear` over a literal axis at
/// a scalar query that reaches both clamps and the interior (every jump of
/// its two `ifelse`s, taken and not), and `linear` over the STATE `u` as its
/// axis, a window the lowering cannot see sorted, so the count checks it on
/// every call and counts the unsorted seeded states entry by entry.
#[test]
#[ignore = "native compiles references once: QUESTIONS.md Q1"]
fn scalar_lookup_loop_matches_the_oracle() {
    use super::test_support::{ab, compile, no_params, opcount};
    let axis: Vec<f64> = AXIS.iter().map(|a| a * 1.6 - 2.0).collect();
    // Three queries, `s`, `4 s` and `s / 5`, so each seeded state reaches
    // the interior and, mostly, a clamp.
    let at = |x: Value| {
        apply(
            "linear",
            json!({"table": konst(json!(TABLE)), "axis": konst(json!(axis)), "x": x,
                   "n": AXIS.len()}),
        )
    };
    let literal = op(
        "+",
        vec![
            op(
                "+",
                vec![at(json!("s")), at(op("*", vec![json!(4.0), json!("s")]))],
            ),
            at(op("/", vec![json!("s"), json!(5.0)])),
        ],
    );
    let prog = ab(&compile(scalar_lookup_doc(7, literal)), &no_params());
    assert_eq!(counts(&prog), vec![(CountRel::Le, true); 3]);
    assert!(opcount(&prog, "JmpIfZero") >= 2, "the clamps short-circuit");
    let state_axis = apply(
        "linear",
        json!({"table": konst(json!(TABLE)), "axis": "u", "x": "s", "n": 7}),
    );
    let prog = ab(&compile(scalar_lookup_doc(7, state_axis)), &no_params());
    assert_eq!(counts(&prog), vec![(CountRel::Le, false)]);
}

/// A count used unclamped as a subscript: `searchsorted` is `n + 1` above
/// the last knot, one past the end of a table of `n` entries. Read from an
/// inline const the gather faults there (the oracle's fault, latched by the
/// general path), from the state `u` it reads the zero ghost; in range it is
/// the entry. Seeded queries fall on both sides.
#[test]
#[ignore = "native compiles references once: QUESTIONS.md Q1"]
fn scalar_lookup_gather_past_the_end_matches_the_oracle() {
    use super::test_support::{ab, compile, idx, no_params, opcount};
    let xs = [-1.5, -1.0, -0.5, 0.0, 0.5, 1.0];
    let bracket = |x: Value| {
        apply(
            "searchsorted",
            json!({"x": x, "xs": konst(json!(xs)), "n": xs.len()}),
        )
    };
    for base in [konst(json!(TABLE[..6])), json!("u")] {
        // At `s` and at `4 s`, which is past the last knot more often.
        let body = op(
            "+",
            vec![
                idx(base.clone(), &[bracket(json!("s"))]),
                idx(
                    base.clone(),
                    &[bracket(op("*", vec![json!(4.0), json!("s")]))],
                ),
            ],
        );
        let prog = ab(&compile(scalar_lookup_doc(6, body)), &no_params());
        assert_eq!(counts(&prog), vec![(CountRel::Ge, true); 2], "{base}");
        assert_eq!(opcount(&prog, "DataGather"), 2, "{base}");
    }
}
