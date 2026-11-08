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

/// One scalar observed `r = rhs` over two const rings (`src`, `tgt`) and a
/// scalar state `u` that relaxes toward it.
fn scalar_branch_doc(rhs: Value) -> Value {
    let src = cells(&[10.0, 11.0], &[40.0, 41.0]);
    let tgt = cells(&[10.25, 10.75, 11.5], &[40.5, 41.5]);
    let mut model = json!({
        "variables": {
            "src": {"type": "unknown", "shape": ["sc", "cv", "co"]},
            "tgt": {"type": "unknown", "shape": ["tc", "cv", "co"]},
            "u": {"type": "unknown", "default": 0.5},
            "r": {"type": "unknown"}
        },
        "equations": [
            {"lhs": "src", "rhs": {"op": "const", "args": [], "value": src}},
            {"lhs": "tgt", "rhs": {"op": "const", "args": [], "value": tgt}},
            {"lhs": "r", "rhs": rhs},
            {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
             "rhs": op("-", vec![op("*", vec![json!(1.0e-3), json!("r")]), json!("u")])}
        ]
    });
    model["expression_templates"] = library("geometry.esm");
    document(
        "scalar_branch_block",
        json!({"sc": {"kind": "interval", "size": 1}, "tc": {"kind": "interval", "size": 2},
               "cv": {"kind": "interval", "size": 4}, "co": {"kind": "interval", "size": 2}}),
        model,
    )
}

/// The sections the `JmpIfZero`s of `prog` sit in.
fn branch_sections(prog: &super::ir::TapeProgram) -> Vec<super::ir::Cadence> {
    (0..prog.instrs.len())
        .filter(|&pc| matches!(prog.instrs[pc], Instr::JmpIfZero { .. }))
        .map(|pc| prog.section_of(pc))
        .collect()
}

fn planar_area(cell_b: i64) -> Value {
    apply(
        "overlap_area_planar",
        json!({"ring_a": "src", "cell_a": 1, "nv_a": 4, "ring_b": "tgt", "cell_b": cell_b, "nv_b": 4}),
    )
}

/// The instructions of `prog`'s per-call section.
fn per_call(prog: &super::ir::TapeProgram) -> Vec<&Instr> {
    (0..prog.instrs.len())
        .filter(|&pc| prog.section_of(pc) == super::ir::Cadence::Continuous)
        .map(|pc| &prog.instrs[pc])
        .collect()
}

/// A scalar `ifelse` whose condition, arms and every instruction are
/// build-time data and pure runs once, in the CONST section, even inside an
/// expression that reads the state (the planar overlap template as a plain
/// scalar observed, its nested branches included), and so does a pure
/// build-time instruction inside a branch taken at run time (the template in
/// the arm of a condition on `t`): nothing of the template is left in the
/// per-call section. The oracle's bits.
#[test]
fn build_time_branch_block_runs_once() {
    let scale = op("+", vec![json!(1), json!("u")]);
    let sum = op(
        "+",
        vec![
            op("*", vec![planar_area(1), scale.clone()]),
            op("*", vec![planar_area(2), scale]),
        ],
    );
    let on_t = op(
        "ifelse",
        vec![
            op(">", vec![json!("t"), json!(0.5)]),
            planar_area(1),
            json!(0),
        ],
    );
    for rhs in [sum, on_t] {
        let (prog, _) = oracle_ab(scalar_branch_doc(rhs.clone()));
        let work: Vec<_> = per_call(&prog)
            .into_iter()
            .filter(|i| {
                matches!(
                    i,
                    Instr::JmpIfZero { .. }
                        | Instr::Reduce { .. }
                        | Instr::Gather { .. }
                        | Instr::DataGather { .. }
                        | Instr::Fused { .. }
                )
            })
            .collect();
        assert!(work.is_empty(), "{rhs}: per-call template work {work:?}");
    }
}

/// Near misses keep the block on every call: a condition on `t` and on
/// build-time data, each with an arm that reads the state and is too large
/// to compute unconditionally.
#[test]
fn branch_block_reading_time_or_state_stays_per_call() {
    let kc = json!({"op": "faq", "args": [], "output_idx": [], "ranges": {"k": [1, 4]},
                    "expr": ix("src", vec![json!(1), json!("k"), json!(1)])});
    let big = op(
        "sin",
        vec![op(
            "cos",
            vec![op("exp", vec![op("*", vec![json!(2), json!("u")])])],
        )],
    );
    for cond in [
        op(">", vec![json!("t"), json!(0.5)]),
        op(">", vec![kc, json!(0)]),
    ] {
        let rhs = op("ifelse", vec![cond, big.clone(), json!(1)]);
        let (prog, _) = oracle_ab(scalar_branch_doc(rhs.clone()));
        let secs = branch_sections(&prog);
        assert_eq!(secs, vec![super::ir::Cadence::Continuous], "{rhs}");
    }
}

/// A scalar observed `r = rhs` over a const axis `ax` of 8 entries and a
/// scalar state `u`, with `x = 3 u + 1` (the seeded states move it across
/// the axis and past both ends).
fn scalar_select_doc(rhs: Value) -> Value {
    let ax = json!([0.5, 1.0, 1.5, 2.25, 3.0, 4.5, 6.0, 7.5]);
    let model = json!({
        "variables": {
            "ax": {"type": "unknown", "shape": ["k"]},
            "u": {"type": "unknown", "default": 0.5},
            "x": {"type": "unknown"},
            "r": {"type": "unknown"}
        },
        "equations": [
            {"lhs": "ax", "rhs": {"op": "const", "args": [], "value": ax}},
            {"lhs": "x", "rhs": op("+", vec![op("*", vec![json!(3), json!("u")]), json!(1)])},
            {"lhs": "r", "rhs": rhs},
            {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
             "rhs": op("-", vec![op("*", vec![json!(0.1), json!("r")]), json!("u")])}
        ]
    });
    document(
        "scalar_select",
        json!({"k": {"kind": "interval", "size": 8}}),
        model,
    )
}

fn count_of(prog: &super::ir::TapeProgram, pred: impl Fn(&Instr) -> bool) -> usize {
    prog.instrs.iter().filter(|i| pred(i)).count()
}

/// A scalar `ifelse` whose arms are values already computed, or at most two
/// pure instructions, lowers to `Instr::Select` instead of a jump and two
/// copies: the flat clamp `ifelse(x <= ax[1], ax[1], ifelse(x >= ax[8],
/// ax[8], x))` the interpolation templates spell, with a NaN `x` among the
/// queries; the oracle's bits, and no jump left.
#[test]
fn small_pure_scalar_branches_become_selects() {
    let lo = ix("ax", vec![json!(1)]);
    let hi = ix("ax", vec![json!(8)]);
    let clamp = op(
        "ifelse",
        vec![
            op("<=", vec![json!("x"), lo.clone()]),
            lo,
            op(
                "ifelse",
                vec![op(">=", vec![json!("x"), hi.clone()]), hi, json!("x")],
            ),
        ],
    );
    let nan_x = op(
        "ifelse",
        vec![
            op(">", vec![json!("u"), json!(1.0)]),
            op("/", vec![json!(0.0), json!(0.0)]),
            json!("x"),
        ],
    );
    for rhs in [clamp.clone(), op("*", vec![clamp, nan_x])] {
        let (prog, _) = oracle_ab(scalar_select_doc(rhs.clone()));
        assert_eq!(
            count_of(&prog, |i| matches!(i, Instr::JmpIfZero { .. })),
            0,
            "{rhs}"
        );
        let selects = count_of(&prog, |i| matches!(i, Instr::Select { .. }))
            + prog
                .lanes
                .iter()
                .flat_map(|l| l.micro.iter())
                .filter(|m| format!("{m:?}").starts_with("Select"))
                .count();
        assert!(selects >= 2, "{rhs}: {selects} selects");
    }
}

/// Near misses keep the jump: an arm of more than two instructions, and an
/// arm holding a const read that may fault (its subscript reads the state).
#[test]
fn large_or_faulting_scalar_branches_keep_the_jump() {
    let big = op(
        "sin",
        vec![op(
            "cos",
            vec![op("exp", vec![op("*", vec![json!("x"), json!("u")])])],
        )],
    );
    let faulting = ix(
        "ax",
        vec![op("floor", vec![op("*", vec![json!(4), json!("u")])])],
    );
    for arm in [big, faulting] {
        let rhs = op(
            "ifelse",
            vec![op(">", vec![json!("x"), json!(2.0)]), arm, json!(1.0)],
        );
        let file =
            crate::parse::load_string(&scalar_select_doc(rhs.clone()).to_string()).expect("loads");
        let compiled = ArrayCompiled::from_file(&file).expect("compiles");
        let (prog, _) = compiled.tape(&HashSet::new());
        let prog = prog.as_ref().expect("taped");
        assert_eq!(
            count_of(prog, |i| matches!(i, Instr::JmpIfZero { .. })),
            1,
            "{rhs}"
        );
        let _ = taped_dy(&scalar_select_doc(rhs));
    }
}
