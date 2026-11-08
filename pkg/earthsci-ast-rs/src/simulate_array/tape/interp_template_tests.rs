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
//!   * the derivative is the `fn` spelling's (`interp.linear`, …), bit for bit;
//!   * the per-cell program does not grow with the number of cells.

use super::super::{ArrayCompiled, RhsStats};
use super::ir::*;
use super::lowering_limit_tests::{count, counts, flat_in_n, oracle_ab};
use super::tests::seeded_state;
use serde_json::{Value, json};
use std::collections::HashMap;

fn op(o: &str, args: Vec<Value>) -> Value {
    json!({"op": o, "args": args})
}

fn ix(v: &str, subs: Vec<Value>) -> Value {
    let mut args = vec![json!(v)];
    args.extend(subs);
    json!({"op": "index", "args": args})
}

fn konst(v: Value) -> Value {
    json!({"op": "const", "args": [], "value": v})
}

/// The library's `expression_templates`, read from `lib/interp.esm`.
fn library() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../lib/interp.esm");
    let text = std::fs::read_to_string(&path).expect("lib/interp.esm");
    let lib: Value = serde_json::from_str(&text).expect("lib/interp.esm parses");
    lib["expression_templates"].clone()
}

/// The seeded states fall in [0.25, 2.5]: the axes below cover part of that
/// range, so the probes reach both clamps, every interior cell and the knots.
const AXIS: [f64; 7] = [0.5, 0.75, 1.0, 1.5, 1.75, 2.0, 2.25];
const TABLE: [f64; 7] = [10.0, 20.0, 40.0, 80.0, 160.0, 170.0, 171.5];
const AXIS_X: [f64; 5] = [0.5, 1.0, 1.25, 2.0, 2.2];
const AXIS_Y: [f64; 4] = [0.4, 1.1, 1.7, 2.3];
const XS: [f64; 6] = [0.5, 1.0, 1.0, 1.0, 1.75, 2.0];

fn table_2d() -> Value {
    let rows: Vec<Vec<f64>> = (0..AXIS_X.len())
        .map(|i| {
            (0..AXIS_Y.len())
                .map(|j| (i * i) as f64 * 3.0 + j as f64 * 0.5 - (i * j) as f64)
                .collect()
        })
        .collect();
    json!(rows)
}

#[derive(Clone, Copy, PartialEq)]
enum Lookup {
    Searchsorted,
    Linear,
    Bilinear,
}

#[derive(Clone, Copy, PartialEq)]
enum Spelling {
    Template,
    Fn,
}

/// The lookup at queries `x` (and `y`, for bilinear).
fn lookup(which: Lookup, spelling: Spelling, x: Value, y: Value) -> Value {
    let apply = |name: &str, b: Value| json!({"op": "apply_expression_template", "args": [], "name": name, "bindings": b});
    let call = |name: &str, args: Vec<Value>| json!({"op": "fn", "name": name, "args": args});
    match (which, spelling) {
        (Lookup::Searchsorted, Spelling::Template) => apply(
            "searchsorted",
            json!({"x": x, "xs": konst(json!(XS)), "n": XS.len()}),
        ),
        (Lookup::Searchsorted, Spelling::Fn) => {
            call("interp.searchsorted", vec![x, konst(json!(XS))])
        }
        (Lookup::Linear, Spelling::Template) => apply(
            "linear",
            json!({"table": konst(json!(TABLE)), "axis": konst(json!(AXIS)), "x": x,
                   "n": AXIS.len()}),
        ),
        (Lookup::Linear, Spelling::Fn) => call(
            "interp.linear",
            vec![konst(json!(TABLE)), konst(json!(AXIS)), x],
        ),
        (Lookup::Bilinear, Spelling::Template) => apply(
            "bilinear",
            json!({"table": konst(table_2d()), "axis_x": konst(json!(AXIS_X)),
                   "axis_y": konst(json!(AXIS_Y)), "x": x, "y": y,
                   "nx": AXIS_X.len(), "ny": AXIS_Y.len()}),
        ),
        (Lookup::Bilinear, Spelling::Fn) => call(
            "interp.bilinear",
            vec![
                konst(table_2d()),
                konst(json!(AXIS_X)),
                konst(json!(AXIS_Y)),
                x,
                y,
            ],
        ),
    }
}

/// A model reading the lookup: per cell (`cells = Some(m)`: `c[l]` over
/// `l in [1, m]` at the queries `u[l]`, `w[l]`) or once (`None`: the scalar
/// `c` at the scalar states `u`, `w`). `u` relaxes toward `c`. `nan` replaces
/// the `x` query by a NaN computed from it.
fn model(which: Lookup, spelling: Spelling, cells: Option<i64>, nan: bool) -> Value {
    let at = |v: &str| match cells {
        Some(_) => ix(v, vec![json!("l")]),
        None => json!(v),
    };
    let mut x = at("u");
    if nan {
        let d = op("-", vec![x.clone(), x.clone()]);
        x = op("/", vec![d.clone(), d]);
    }
    let body = lookup(which, spelling, x, at("w"));
    let shape = |v: Value| match cells {
        Some(_) => {
            let mut v = v;
            v["shape"] = json!(["lev"]);
            v
        }
        None => v,
    };
    let per_cell = |e: Value| match cells {
        Some(m) => json!({"op": "faq", "args": [], "output_idx": ["l"],
                          "ranges": {"l": [1, m]}, "expr": e}),
        None => e,
    };
    let d_lhs = |v: &str| match cells {
        Some(m) => json!({"op": "faq", "args": [], "output_idx": ["l"],
                          "ranges": {"l": [1, m]},
                          "expr": {"op": "D", "args": [ix(v, vec![json!("l")])], "wrt": "t"}}),
        None => json!({"op": "D", "args": [v], "wrt": "t"}),
    };
    let mut m = json!({
        "variables": {
            "u": shape(json!({"type": "unknown", "default": 1.0})),
            "w": shape(json!({"type": "unknown", "default": 1.0})),
            "c": shape(json!({"type": "unknown"}))
        },
        "equations": [
            {"lhs": "c", "rhs": per_cell(body)},
            {"lhs": d_lhs("u"), "rhs": per_cell(op("+", vec![
                op("*", vec![json!(-0.1), at("u")]),
                op("*", vec![json!(0.01), at("c")])]))},
            {"lhs": d_lhs("w"), "rhs": per_cell(op("*", vec![json!(-0.05), at("w")]))}
        ]
    });
    if spelling == Spelling::Template {
        m["expression_templates"] = library();
    }
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "interp_template_on_the_tape"},
        "models": {"M": m}
    })
}

/// The taped `dy` of `doc` at a few seeded states, as bits.
fn taped_dy(doc: &Value) -> Vec<Vec<u64>> {
    let file = crate::parse::load_string(&doc.to_string()).expect("loads");
    let compiled = ArrayCompiled::from_file(&file).expect("compiles");
    let n = compiled.state_variable_names().len();
    let p = compiled.debug_resolve_params(&HashMap::new());
    let mut scratch = compiled.debug_new_scratch_taped().expect("taped");
    (0..4u64)
        .map(|seed| {
            let state = seeded_state(n, seed, 0.25, 2.5);
            let mut out = vec![0.0; n];
            compiled.debug_eval_rhs_into(
                &state,
                0.0,
                &p,
                &mut out,
                &mut scratch,
                &mut RhsStats::default(),
            );
            out.iter().map(|x| x.to_bits()).collect()
        })
        .collect()
}

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
fn interp_templates_per_cell_query_count_once_and_match_fn() {
    for (which, name) in LOOKUPS {
        let prog = flat_in_n(|m| model(which, Spelling::Template, Some(m), false), 4, 33);
        assert_eq!(counts(&prog), expected_counts(which), "{name}: per cell");
        assert_eq!(count(&prog, "Reduce"), 0, "{name}: no fold is left");
        assert_eq!(
            taped_dy(&model(which, Spelling::Template, Some(17), false)),
            taped_dy(&model(which, Spelling::Fn, Some(17), false)),
            "{name}: the template's derivative is the fn form's"
        );
    }
}

#[test]
fn interp_templates_scalar_query_count_once_and_match_fn() {
    for (which, name) in LOOKUPS {
        let (prog, _) = oracle_ab(model(which, Spelling::Template, None, false));
        assert_eq!(counts(&prog), expected_counts(which), "{name}: scalar");
        assert_eq!(count(&prog, "Reduce"), 0, "{name}: no fold is left");
        assert_eq!(
            taped_dy(&model(which, Spelling::Template, None, false)),
            taped_dy(&model(which, Spelling::Fn, None, false)),
            "{name}: the template's derivative is the fn form's"
        );
    }
}

/// A NaN query: searchsorted counts every knot (`n + 1`), linear and
/// bilinear propagate the NaN — the fn form's answers, through the counts.
#[test]
fn interp_templates_nan_query() {
    for (which, name) in LOOKUPS {
        for cells in [None, Some(5)] {
            let (prog, _) = oracle_ab(model(which, Spelling::Template, cells, true));
            assert_eq!(counts(&prog).len(), expected_counts(which).len(), "{name}");
            let nan_eq = |d: &Value| {
                taped_dy(d)
                    .into_iter()
                    .map(|v| {
                        v.into_iter()
                            .map(|b| {
                                if f64::from_bits(b).is_nan() {
                                    u64::MAX
                                } else {
                                    b
                                }
                            })
                            .collect::<Vec<_>>()
                    })
                    .collect::<Vec<_>>()
            };
            assert_eq!(
                nan_eq(&model(which, Spelling::Template, cells, true)),
                nan_eq(&model(which, Spelling::Fn, cells, true)),
                "{name}: NaN query"
            );
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
    use super::array_tests::{d_eq, doc, idx};
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
    d["models"]["M"]["expression_templates"] = library();
    d
}

fn apply(name: &str, bindings: Value) -> Value {
    json!({"op": "apply_expression_template", "args": [], "name": name, "bindings": bindings})
}

/// The executor's scalar loop of a lookup: `linear` over a literal axis at
/// a scalar query that reaches both clamps and the interior (every jump of
/// its two `ifelse`s, taken and not), and `linear` over the STATE `u` as its
/// axis, a window the lowering cannot see sorted, so the count checks it on
/// every call and counts the unsorted seeded states entry by entry.
#[test]
fn scalar_lookup_loop_matches_the_oracle() {
    use super::array_tests::{ab, compile, no_params, opcount};
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
fn scalar_lookup_gather_past_the_end_matches_the_oracle() {
    use super::array_tests::{ab, compile, idx, no_params, opcount};
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
