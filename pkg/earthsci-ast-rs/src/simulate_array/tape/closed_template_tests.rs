//! The phase-3 standard-library templates on the tape: `lib/calendar.esm`,
//! `lib/geometry.esm` and `lib/relational.esm`, expanded inside a `faq` over
//! an index set, lower with no declined rule and write the per-cell oracle's
//! `dy` bit for bit through every executor ([`oracle_ab`]):
//!
//!   * the nine calendar fields per cell, also against the `fn datetime.*`
//!     spelling;
//!   * the planar and spherical overlap areas of every source x target cell
//!     pair, whose next-vertex subscript `ifelse(k < nv, k + 1, 1)` is known
//!     to stay in range ([`super::lower`]'s `int_range`), so the gathers at it
//!     record no fault;
//!   * the argmin of a per-call distance (its candidates read a state).
//!
//! And the subscript bounds on their own: the cyclic successor and the clamp
//! `min(k + 1, n)` inside an `ifelse` arm of a rank-0 reduction lower and
//! agree with the oracle; a successor that does leave the array
//! (`ifelse(k < n, k + 2, 1)`, `ifelse(k <= n, k + 1, 1)`) still declines.

use super::super::{ArrayCompiled, RhsStats};
use super::ir::Instr;
use super::lowering_limit_tests::oracle_ab;
use super::tests::seeded_state;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

fn op(o: &str, args: Vec<Value>) -> Value {
    json!({"op": o, "args": args})
}

fn ix(v: &str, subs: Vec<Value>) -> Value {
    let mut args = vec![json!(v)];
    args.extend(subs);
    json!({"op": "index", "args": args})
}

fn apply(name: &str, bindings: Value) -> Value {
    json!({"op": "apply_expression_template", "args": [], "name": name, "bindings": bindings})
}

fn faq(expr: Value, out: Vec<&str>, ranges: Value) -> Value {
    json!({"op": "faq", "args": [], "output_idx": out, "ranges": ranges, "expr": expr})
}

fn d_lhs(v: &str, out: Vec<&str>, ranges: Value) -> Value {
    let subs = out.iter().map(|s| json!(s)).collect();
    faq(
        json!({"op": "D", "args": [ix(v, subs)], "wrt": "t"}),
        out,
        ranges,
    )
}

/// `lib/<file>`'s `expression_templates`.
fn library(file: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../lib")
        .join(file);
    let text = std::fs::read_to_string(&path).expect("library file");
    let lib: Value = serde_json::from_str(&text).expect("library parses");
    lib["expression_templates"].clone()
}

fn document(name: &str, sets: Value, model: Value) -> Value {
    json!({"esm": "1.2.0", "metadata": {"name": name}, "index_sets": sets, "models": {"M": model}})
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
                0.7,
                &p,
                &mut out,
                &mut scratch,
                &mut RhsStats::default(),
            );
            out.iter().map(|x| x.to_bits()).collect()
        })
        .collect()
}

const FIELDS: [&str; 9] = [
    "year",
    "month",
    "day",
    "hour",
    "minute",
    "second",
    "day_of_year",
    "julian_day",
    "is_leap_year",
];

/// Per cell `l` of 24, `tu[l] = t0 + 3601 l + 1e5 u[l]` (the state moves it
/// across days and years), and each field relaxes a state of its own.
fn calendar_doc(t0: f64, template: bool) -> Value {
    let l = json!({"l": [1, 24]});
    let mut vars = json!({
        "u": {"type": "unknown", "shape": ["lev"], "default": 1.0},
        "tu": {"type": "unknown", "shape": ["lev"]}
    });
    let mut eqs = vec![
        json!({"lhs": "tu", "rhs": faq(op("+", vec![json!(t0), op("*", vec![json!(3601), json!("l")]),
            op("*", vec![json!(1.0e5), ix("u", vec![json!("l")])])]), vec!["l"], l.clone())}),
        json!({"lhs": d_lhs("u", vec!["l"], l.clone()),
               "rhs": faq(op("*", vec![json!(-0.1), ix("u", vec![json!("l")])]), vec!["l"], l.clone())}),
    ];
    for f in FIELDS {
        let at = ix("tu", vec![json!("l")]);
        let call = if template {
            apply(f, json!({"t": at}))
        } else {
            json!({"op": "fn", "name": format!("datetime.{f}"), "args": [at]})
        };
        let s = format!("s_{f}");
        vars[&s] = json!({"type": "unknown", "shape": ["lev"], "default": 0.0});
        eqs.push(json!({"lhs": d_lhs(&s, vec!["l"], l.clone()),
            "rhs": faq(op("-", vec![call, ix(&s, vec![json!("l")])]), vec!["l"], l.clone())}));
    }
    let mut model = json!({"variables": vars, "equations": eqs});
    if template {
        model["expression_templates"] = library("calendar.esm");
    }
    document(
        "calendar_on_the_tape",
        json!({"lev": {"kind": "interval", "size": 24}}),
        model,
    )
}

#[test]
fn calendar_templates_match_the_oracle_and_the_fn_form() {
    for t0 in [1.6e9, -2.2e9, 951_782_400.0] {
        oracle_ab(calendar_doc(t0, true));
        assert_eq!(
            taped_dy(&calendar_doc(t0, true)),
            taped_dy(&calendar_doc(t0, false)),
            "t0 {t0}: the templates' derivative is the fn form's"
        );
    }
}

/// Lat-lon cells, counter-clockwise from the south-west corner.
fn cells(lons: &[f64], lats: &[f64]) -> Value {
    let mut out = Vec::new();
    for b in 0..lats.len() - 1 {
        for a in 0..lons.len() - 1 {
            out.push(json!([
                [lons[a], lats[b]],
                [lons[a + 1], lats[b]],
                [lons[a + 1], lats[b + 1]],
                [lons[a], lats[b + 1]]
            ]));
        }
    }
    Value::Array(out)
}

/// Every source x target pair's overlap area (2 x 2 one-degree cells onto
/// the 3 x 3 grid of 2/3-degree cells over them, with one repeated vertex in
/// a target ring), weighting a state per source cell into a state per target
/// cell.
fn overlap_doc(spherical: bool) -> Value {
    let src = cells(&[10.0, 11.0, 12.0], &[40.0, 41.0, 42.0]);
    let th = [10.0, 10.0 + 2.0 / 3.0, 10.0 + 4.0 / 3.0, 12.0];
    let ta = [40.0, 40.0 + 2.0 / 3.0, 40.0 + 4.0 / 3.0, 42.0];
    let mut tgt = cells(&th, &ta);
    // A padded ring: its first vertex repeated in the last slot.
    let v0 = tgt[4][0].clone();
    tgt[4][3] = v0;
    let r = json!({"i": [1, 4], "j": [1, 9]});
    let (a, b, name) = if spherical {
        ("sx", "tx", "overlap_area_spherical")
    } else {
        ("src", "tgt", "overlap_area_planar")
    };
    let area = apply(
        name,
        json!({"ring_a": a, "cell_a": "i", "nv_a": 4, "ring_b": b, "cell_b": "j", "nv_b": 4}),
    );
    let mut vars = json!({
        "src": {"type": "unknown", "shape": ["sc", "cv", "co"]},
        "tgt": {"type": "unknown", "shape": ["tc", "cv", "co"]},
        "A": {"type": "unknown", "shape": ["sc", "tc"]},
        "u": {"type": "unknown", "shape": ["sc"], "default": 1.0},
        "w": {"type": "unknown", "shape": ["tc"], "default": 0.0}
    });
    let mut eqs = vec![
        json!({"lhs": "src", "rhs": {"op": "const", "args": [], "value": src}}),
        json!({"lhs": "tgt", "rhs": {"op": "const", "args": [], "value": tgt}}),
        json!({"lhs": "A", "rhs": faq(area, vec!["i", "j"], r.clone())}),
        json!({"lhs": d_lhs("u", vec!["i"], json!({"i": [1, 4]})),
               "rhs": faq(op("*", vec![json!(-0.1), ix("u", vec![json!("i")])]), vec!["i"], json!({"i": [1, 4]}))}),
        json!({"lhs": d_lhs("w", vec!["j"], json!({"j": [1, 9]})),
               "rhs": faq(op("-", vec![op("*", vec![ix("A", vec![json!("i"), json!("j")]), ix("u", vec![json!("i")])]),
                    ix("w", vec![json!("j")])]), vec!["j"], r.clone())}),
    ];
    if spherical {
        for (xyz, ring, n) in [("sx", "src", 4), ("tx", "tgt", 9)] {
            vars[xyz] =
                json!({"type": "unknown", "shape": [if n == 4 { "sc" } else { "tc" }, "cv", "d3"]});
            eqs.push(json!({"lhs": xyz, "rhs": faq(apply("lonlat_to_unit",
                json!({"ring": ring, "cell": "c", "vert": "v", "comp": "d"})),
                vec!["c", "v", "d"], json!({"c": [1, n], "v": [1, 4], "d": [1, 3]}))}));
        }
    }
    let mut model = json!({"variables": vars, "equations": eqs});
    model["expression_templates"] = library("geometry.esm");
    document(
        "overlap_on_the_tape",
        json!({"sc": {"kind": "interval", "size": 4}, "tc": {"kind": "interval", "size": 9},
               "cv": {"kind": "interval", "size": 4}, "co": {"kind": "interval", "size": 2},
               "d3": {"kind": "interval", "size": 3}}),
        model,
    )
}

#[test]
fn overlap_area_templates_lower_and_match_the_oracle() {
    for spherical in [false, true] {
        oracle_ab(overlap_doc(spherical));
    }
}

/// `assign[i] = argmin_g (x[i] - gx[g])^2`, the candidates reading the state
/// `x`; ties are real (generators at equal distances).
fn argmin_doc() -> Value {
    let gx = json!([0.5, 1.0, 1.5, 1.0, 2.0, 2.5]);
    let dist = op(
        "*",
        vec![
            op(
                "-",
                vec![
                    ix("x", vec![json!("i")]),
                    ix("gx", vec![json!("k_argmin_1")]),
                ],
            ),
            op(
                "-",
                vec![
                    ix("x", vec![json!("i")]),
                    ix("gx", vec![json!("k_argmin_1")]),
                ],
            ),
        ],
    );
    let r = json!({"i": [1, 7]});
    let mut model = json!({
        "variables": {
            "gx": {"type": "unknown", "shape": ["g"]},
            "x": {"type": "unknown", "shape": ["p"], "default": 1.0},
            "assign": {"type": "unknown", "shape": ["p"]}
        },
        "equations": [
            {"lhs": "gx", "rhs": {"op": "const", "args": [], "value": gx}},
            {"lhs": "assign", "rhs": faq(apply("argmin", json!({"f": dist, "n": 6})), vec!["i"], r.clone())},
            {"lhs": d_lhs("x", vec!["i"], r.clone()),
             "rhs": faq(op("-", vec![op("*", vec![json!(0.1), ix("assign", vec![json!("i")])]),
                 ix("x", vec![json!("i")])]), vec!["i"], r.clone())}
        ]
    });
    model["expression_templates"] = library("relational.esm");
    document(
        "argmin_on_the_tape",
        json!({"p": {"kind": "interval", "size": 7}, "g": {"kind": "interval", "size": 6}}),
        model,
    )
}

#[test]
fn argmin_template_lowers_and_matches_the_oracle() {
    oracle_ab(argmin_doc());
}

/// `s[c] = sum_k ifelse(P[c, k, 1] > 0.5, P[c, sub, 1], 0)` over a const
/// ring stack: the gather at `sub` sits in a lazily evaluated arm of a
/// rank-0 reduction, where a read that may leave the array is refused.
fn successor_doc(sub: Value) -> Value {
    let p = json!([
        [[0, 0], [1, 0], [1, 1], [0, 1]],
        [[1, 0], [2, 0], [2, 1], [1, 1]]
    ]);
    let body = op(
        "ifelse",
        vec![
            op(
                ">",
                vec![ix("P", vec![json!("c"), json!("k"), json!(1)]), json!(0.5)],
            ),
            ix("P", vec![json!("c"), sub, json!(1)]),
            json!(0),
        ],
    );
    let inner = json!({"op": "faq", "args": [], "output_idx": [], "reduce": "+",
                       "ranges": {"k": [1, 4]}, "expr": body});
    let c = json!({"c": [1, 2]});
    document(
        "successor",
        json!({"cells": {"kind": "interval", "size": 2},
               "verts": {"kind": "interval", "size": 4}, "coord": {"kind": "interval", "size": 2}}),
        json!({
            "variables": {
                "P": {"type": "unknown", "shape": ["cells", "verts", "coord"]},
                "s": {"type": "unknown", "shape": ["cells"]},
                "u": {"type": "unknown", "shape": ["cells"], "default": 0.0}
            },
            "equations": [
                {"lhs": "P", "rhs": {"op": "const", "args": [], "value": p}},
                {"lhs": "s", "rhs": faq(inner, vec!["c"], c.clone())},
                {"lhs": d_lhs("u", vec!["c"], c.clone()),
                 "rhs": faq(op("-", vec![ix("s", vec![json!("c")]), ix("u", vec![json!("c")])]), vec!["c"], c.clone())}
            ]
        }),
    )
}

/// Whether every rule of `doc` lowers.
fn lowers(doc: &Value) -> bool {
    let file = crate::parse::load_string(&doc.to_string()).expect("loads");
    let compiled = ArrayCompiled::from_file(&file).expect("compiles");
    compiled.build_tape_opts(&HashSet::new(), None).0.is_ok()
}

#[test]
fn successor_subscripts_bounded_by_their_condition() {
    let k = || json!("k");
    let succ = |cmp: &str, step: i64| {
        op(
            "ifelse",
            vec![
                op(cmp, vec![k(), json!(4)]),
                op("+", vec![k(), json!(step)]),
                json!(1),
            ],
        )
    };
    // In range: the cyclic successor (either comparison spelling) and a clamp.
    for sub in [
        succ("<", 1),
        op(
            "ifelse",
            vec![
                op(">=", vec![k(), json!(4)]),
                json!(1),
                op("+", vec![k(), json!(1)]),
            ],
        ),
        op("min", vec![op("+", vec![k(), json!(1)]), json!(4)]),
    ] {
        oracle_ab(successor_doc(sub));
    }
    // Near misses: each reads past the last vertex at some cell the oracle
    // reaches, so the read may fault and the rule is refused as before.
    for sub in [succ("<", 2), succ("<=", 1), op("+", vec![k(), json!(1)])] {
        assert!(!lowers(&successor_doc(sub.clone())), "{sub}: must decline");
    }
}

/// The scaling family's conservative regrid with its overlap areas written
/// as the planar template, `dx` the bin width.
fn template_regrid(n: usize, dx: f64) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../tests/conformance/scaling/fixtures/regrid/regrid_N{n}.esm"
    ));
    let mut doc: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).expect("fixture")).expect("parses");
    let m = &mut doc["models"]["Regrid"];
    for eq in m["equations"].as_array_mut().expect("equations") {
        if eq["lhs"] == json!("A_ij") {
            eq["rhs"]["expr"] = apply(
                "overlap_area_planar",
                json!({"ring_a": "src_poly", "cell_a": "i", "nv_a": 4,
                       "ring_b": "tgt_poly", "cell_b": "j", "nv_b": 4}),
            );
        }
    }
    m["variables"]["dx"]["default"] = json!(dx);
    m["expression_templates"] = library("geometry.esm");
    doc
}

/// The largest element count any instruction of `prog` writes.
fn widest(prog: &super::ir::TapeProgram) -> usize {
    prog.instrs
        .iter()
        .map(|ins| match ins {
            Instr::Fused { spec } => prog.fused[*spec as usize].shape.iter().product::<usize>(),
            _ => ins.out().map_or(0, |o| {
                prog.slots[o as usize].shape.iter().product::<usize>()
            }),
        })
        .max()
        .unwrap_or(0)
}

/// A join-gated pointwise `faq` whose gate keeps few cells evaluates its body
/// at the candidate cells only: no instruction spans the source x target box
/// times a vertex loop, and every executor writes the oracle's `dy`. When
/// the gate keeps most cells (one bin holds every cell) the body runs over
/// the whole box, as before, with the same agreement.
#[test]
fn gated_pointwise_faq_compacts_to_its_candidate_cells() {
    let n = 100;
    let sparse = super::tests::ab_check(template_regrid(n, 2.0), 0.5, 2.0);
    assert!(
        widest(&sparse) <= n * n,
        "the overlap body ran over a box of {} elements",
        widest(&sparse)
    );
    let dense = super::tests::ab_check(template_regrid(n, 1.0e6), 0.5, 2.0);
    assert!(
        widest(&dense) >= n * n * 4,
        "a gate keeping every cell is not compacted"
    );
}

/// The other lib/relational.esm templates per cell of a state: a gated
/// arg-witness (`argmin_where` / `argmax_where`, a contracted `faq` with a
/// `filter`; no candidate passing gives `n + 1`), the composite keys
/// `pair_key` / `edge_key` (NaN for an out-of-range or non-integral
/// component), `rank_of` over literal members and `rank_of_set` over an
/// index set the call names.
fn relational_doc() -> Value {
    let x = || ix("x", vec![json!("i")]);
    let g = |k: &str| ix("gx", vec![json!(k)]);
    let d = |k: &str| {
        op(
            "*",
            vec![op("-", vec![x(), g(k)]), op("-", vec![x(), g(k)])],
        )
    };
    // Candidates above the cell's own value compete (none for the largest).
    let pass = |k: &str| op(">", vec![g(k), x()]);
    let key_a = op("floor", vec![op("*", vec![json!(3), x()])]);
    let key_b = op("floor", vec![op("*", vec![json!(2), x()])]);
    let r = json!({"i": [1, 7]});
    let cell = |e: Value| faq(e, vec!["i"], r.clone());
    let sum = op(
        "+",
        vec![
            apply(
                "argmin_where",
                json!({"f": d("k_argmin_where_1"), "p": pass("k_argmin_where_1"), "n": 6}),
            ),
            apply(
                "argmax_where",
                json!({"f": d("k_argmax_where_1"), "p": pass("k_argmax_where_1"), "n": 6}),
            ),
            apply(
                "pair_key",
                json!({"a": key_a, "b": key_b, "lo_a": 0, "lo_b": 1, "n_a": 8, "n_b": 5}),
            ),
            apply("edge_key", json!({"u": key_a, "v": key_b, "lo": 0, "n": 8})),
            apply(
                "rank_of",
                json!({"x": x(), "members": {"op": "const", "args": [], "value": [0.5, 1.0, 1.5, 2.25]}, "n": 4}),
            ),
            apply("rank_of_set", json!({"x": x(), "members": "gx", "S": "g"})),
        ],
    );
    let mut model = json!({
        "variables": {
            "gx": {"type": "unknown", "shape": ["g"]},
            "x": {"type": "unknown", "shape": ["p"], "default": 1.0},
            "y": {"type": "unknown", "shape": ["p"]}
        },
        "equations": [
            {"lhs": "gx", "rhs": {"op": "const", "args": [], "value": [0.5, 1.0, 1.5, 1.0, 2.0, 2.5]}},
            {"lhs": "y", "rhs": cell(sum)},
            {"lhs": d_lhs("x", vec!["i"], r.clone()),
             "rhs": cell(op("-", vec![op("*", vec![json!(0.01), ix("y", vec![json!("i")])]), x()]))}
        ]
    });
    model["expression_templates"] = library("relational.esm");
    document(
        "relational_on_the_tape",
        json!({"p": {"kind": "interval", "size": 7}, "g": {"kind": "interval", "size": 6}}),
        model,
    )
}

#[test]
fn keyed_and_gated_relational_templates_lower_and_match_the_oracle() {
    oracle_ab(relational_doc());
}

/// A mesh's per-face state relaxing to the sum of the per-edge state over its
/// three edges, read through the face-to-edge connectivity:
/// `D(q[f]) = Σ_le w[edge(f, le)] - q[f]` (the `mesh_rank` workload's shape),
/// the sum an array-producing nested `faq` over `f` under the `-`. The
/// connectivity is an observed's values or an inline const. With `observed`,
/// the same shape also defines an array observed `r[f] = 2 Σ_le w[…] - q[f]`
/// that a second state reads, so the observed per-cell walk is covered too.
fn mesh_face_sum_doc(observed_connectivity: bool, observed: bool) -> Value {
    let conn = [[1, 2, 3], [3, 4, 5], [5, 6, 1], [2, 4, 6]];
    let conn_lit = json!({"op": "const", "args": [], "value": conn});
    let fl = json!({"f": {"from": "faces"}, "le": {"from": "local_edges"}});
    let f = json!({"f": {"from": "faces"}});
    let e = if observed_connectivity {
        json!("edge_of")
    } else {
        conn_lit.clone()
    };
    let face_sum = || {
        let mut s = faq(
            ix("w", vec![ix_any(e.clone(), vec![json!("f"), json!("le")])]),
            vec!["f"],
            fl.clone(),
        );
        s["semiring"] = json!("sum_product");
        s
    };
    let qf = || ix("q", vec![json!("f")]);
    let mut vars = json!({
        "w": {"type": "unknown", "shape": ["edge_ids"], "default": 0.0},
        "q": {"type": "unknown", "shape": ["faces"], "default": 0.0}
    });
    let mut eqs = vec![
        json!({"lhs": d_lhs("w", vec!["e"], json!({"e": {"from": "edge_ids"}})),
               "rhs": faq(op("-", vec![json!("e"), ix("w", vec![json!("e")])]), vec!["e"],
                          json!({"e": {"from": "edge_ids"}}))}),
        json!({"lhs": d_lhs("q", vec!["f"], f.clone()),
               "rhs": op("-", vec![face_sum(), qf()])}),
    ];
    if observed_connectivity {
        vars["edge_of"] = json!({"type": "unknown", "shape": ["faces", "local_edges"]});
        eqs.insert(0, json!({"lhs": "edge_of", "rhs": conn_lit}));
    }
    if observed {
        vars["r"] = json!({"type": "unknown", "shape": ["faces"]});
        vars["p"] = json!({"type": "unknown", "shape": ["faces"], "default": 0.0});
        eqs.push(json!({"lhs": ix("r", vec![json!("f")]),
            "rhs": faq(op("-", vec![op("*", vec![json!(2.0), face_sum()]), qf()]), vec!["f"], f.clone())}));
        eqs.push(json!({"lhs": d_lhs("p", vec!["f"], f.clone()),
            "rhs": faq(ix("r", vec![json!("f")]), vec!["f"], f)}));
    }
    document(
        "mesh_face_sum",
        json!({
            "faces": {"kind": "interval", "size": 4},
            "local_edges": {"kind": "interval", "size": 3},
            "edge_ids": {"kind": "interval", "size": 6}
        }),
        json!({"variables": vars, "equations": eqs}),
    )
}

fn ix_any(base: Value, subs: Vec<Value>) -> Value {
    let mut args = vec![base];
    args.extend(subs);
    json!({"op": "index", "args": args})
}

/// The per-cell oracle reads an array-producing nested `faq` under an
/// elementwise operator at the current output cell, as the whole-array
/// overlay and the tape do: it used to answer NaN for every face.
#[test]
fn nested_face_sum_through_connectivity_matches_the_oracle() {
    for observed_connectivity in [true, false] {
        for observed in [false, true] {
            let doc = mesh_face_sum_doc(observed_connectivity, observed);
            let file = crate::parse::load_string(&doc.to_string()).expect("loads");
            let compiled = ArrayCompiled::from_file(&file).expect("compiles");
            let n = compiled.state_variable_names().len();
            let state = seeded_state(n, 1, 0.25, 2.5);
            let (dy, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), true);
            assert!(
                dy.iter().all(|x| x.is_finite()),
                "the per-cell oracle answers every face: {dy:?}"
            );
            oracle_ab(doc);
        }
    }
}

/// `D(q[f]) = faq_f(w[f]) - q[f]` over faces 1..4, the nested node's `f`
/// over `nested_range` instead (a sub-range, or the same range by another set).
fn mismatched_nested_box_doc(nested: Value) -> Value {
    let f = json!({"f": {"from": "faces"}});
    let mut inner = faq(ix("w", vec![json!("f")]), vec!["f"], json!({"f": nested}));
    inner["semiring"] = json!("sum_product");
    document(
        "nested_box",
        json!({
            "faces": {"kind": "interval", "size": 4},
            "cells": {"kind": "interval", "size": 4}
        }),
        json!({
            "variables": {
                "w": {"type": "unknown", "shape": ["faces"], "default": 0.0},
                "q": {"type": "unknown", "shape": ["faces"], "default": 0.0}
            },
            "equations": [
                {"lhs": d_lhs("w", vec!["f"], f.clone()),
                 "rhs": faq(op("*", vec![json!(-0.5), ix("w", vec![json!("f")])]), vec!["f"], f.clone())},
                {"lhs": d_lhs("q", vec!["f"], f),
                 "rhs": op("-", vec![inner, ix("q", vec![json!("f")])])}
            ]
        }),
    )
}

/// A nested `faq` over a sub-range of the output box is not read at the
/// cell: the per-cell oracle latches `E_TREEWALK_NESTED_BOX_MISMATCH` naming
/// the equation and leaves those cells NaN, rather than reading the element of
/// another cell, and the tape refuses the rule. Over the same `[1, 4]` by
/// another index set it is the same box, and every evaluator agrees.
#[test]
fn nested_faq_over_another_box_is_not_read_at_the_cell() {
    use crate::simulate_array::take_const_array_oob;
    for nested in [json!([2, 4]), json!([1, 3])] {
        let doc = mismatched_nested_box_doc(nested.clone());
        let file = crate::parse::load_string(&doc.to_string()).expect("loads");
        let compiled = ArrayCompiled::from_file(&file).expect("compiles");
        let names = compiled.state_variable_names();
        let state = seeded_state(names.len(), 1, 0.25, 2.5);
        take_const_array_oob();
        let (dy, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), true);
        let fault = take_const_array_oob().expect("the oracle latches a fault");
        assert!(
            fault.starts_with("E_TREEWALK_NESTED_BOX_MISMATCH")
                && fault.contains("the equation for 'q'"),
            "{nested}: {fault}"
        );
        for (name, v) in names.iter().zip(&dy) {
            assert_eq!(v.is_nan(), name.contains("q["), "{nested}: {name} = {v}");
        }
        let (_, report) = compiled.build_tape_opts(&HashSet::new(), None);
        assert!(
            report.fallbacks.iter().any(|(rule, _)| rule == "D(q)"),
            "{nested}: the tape refuses the rule: {:?}",
            report.fallbacks
        );
    }
    oracle_ab(mismatched_nested_box_doc(json!({"from": "cells"})));
}
