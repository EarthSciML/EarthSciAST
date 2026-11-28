//! The phase-3 standard-library templates on the tape: `lib/calendar.esm`,
//! `lib/geometry.esm` and `lib/relational.esm`, expanded inside a `faq` over
//! an index set, lower with no declined rule and write the per-cell oracle's
//! `dy` bit for bit through every executor ([`oracle_ab`]):
//!
//!   * the nine calendar fields per cell;
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

use super::ir::Instr;
use super::template_fixtures::{argmin_doc, calendar_doc, cells, overlap_doc, relational_doc};
use super::test_support::{
    ab_check_at_times, apply, compile, count_where, d_lhs, document, faq, fast_dy, idx, ix,
    library, op, oracle_ab, seeded_state,
};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

/// The taped `dy` of `doc` at a few seeded states, as bits.
fn taped_dy(doc: &Value) -> Vec<Vec<u64>> {
    let compiled = compile(doc.clone());
    let n = compiled.state_variable_names().len();
    let p = compiled.debug_resolve_params(&HashMap::new());
    let mut scratch = compiled.debug_new_scratch_taped().expect("taped");
    (0..4u64)
        .map(|seed| {
            let state = seeded_state(n, seed, 0.25, 2.5);
            fast_dy(&compiled, &mut scratch, &state, 0.7, &p)
                .iter()
                .map(|x| x.to_bits())
                .collect()
        })
        .collect()
}

#[test]
fn calendar_templates_match_the_oracle() {
    for t0 in [1.6e9, -2.2e9, 951_782_400.0] {
        oracle_ab(calendar_doc(t0));
    }
}

#[test]
fn overlap_area_templates_lower_and_match_the_oracle() {
    let (planar, _) = oracle_ab(overlap_doc(false));
    assert_unique_build_time_instructions(&planar);
    oracle_ab(overlap_doc(true));
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
                {"lhs": "s", "rhs": faq(&["c"], c.clone(), inner)},
                {"lhs": d_lhs("u", &["c"], c.clone()),
                 "rhs": faq(&["c"], c.clone(), op("-", vec![ix("s", vec![json!("c")]), ix("u", vec![json!("c")])]))}
            ]
        }),
    )
}

/// Whether every rule of `doc` lowers.
fn lowers(doc: &Value) -> bool {
    let compiled = compile(doc.clone());
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
/// as the planar template, using a prefix of the source cells and selected
/// target cells. `dx` is the bin width.
fn template_regrid(src_n: usize, targets: &[usize], dx: f64) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/scaling/fixtures/regrid/regrid_N100.esm");
    let mut doc: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).expect("fixture")).expect("parses");
    doc["index_sets"]["src_cells"]["size"] = json!(src_n);
    doc["index_sets"]["tgt_cells"]["size"] = json!(targets.len());
    let m = &mut doc["models"]["Regrid"];
    for eq in m["equations"].as_array_mut().expect("equations") {
        match eq["lhs"].as_str() {
            Some("src_poly") => {
                let rings = eq["rhs"]["value"].as_array_mut().expect("polygon rings");
                assert!(rings.len() >= src_n);
                rings.truncate(src_n);
            }
            Some("tgt_poly") => {
                let rings = eq["rhs"]["value"].as_array_mut().expect("polygon rings");
                *rings = targets.iter().map(|&i| rings[i].clone()).collect();
            }
            Some("A_ij") => {
                eq["rhs"]["expr"] = apply(
                    "overlap_area_planar",
                    json!({"ring_a": "src_poly", "cell_a": "i", "nv_a": 4,
                       "ring_b": "tgt_poly", "cell_b": "j", "nv_b": 4}),
                )
            }
            _ => {}
        }
    }
    m["variables"]["dx"]["default"] = json!(dx);
    m["operators"] = library("geometry.esm");
    doc
}

/// The largest element count any instruction of `prog` writes.
fn widest(prog: &super::ir::TapeProgram) -> usize {
    // The widest box of the program and of every function it calls.
    let own = widest_own(prog);
    prog.funcs
        .iter()
        .map(|f| widest_own(f))
        .fold(own, usize::max)
}

fn widest_own(prog: &super::ir::TapeProgram) -> usize {
    prog.instrs
        .iter()
        .map(|ins| match ins {
            Instr::Fused { spec } => prog.fused[*spec as usize].shape.iter().product::<usize>(),
            _ => ins.out().map_or(0, |o| {
                prog.tables.slots[o as usize]
                    .shape
                    .iter()
                    .product::<usize>()
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
    // Only the first two source and target cells share a bin. The four
    // admitted pairs have zero, half and full overlaps, and their 64 vertex
    // pairs fit within the 8 × 9 output box.
    let sparse_src = 8;
    let sparse_targets = [0, 1, 20, 21, 22, 23, 24, 25, 26];
    // The RHS has no time input.
    let times = &[0.37];
    let sparse = ab_check_at_times(
        template_regrid(sparse_src, &sparse_targets, 2.0),
        0.5,
        2.0,
        times,
    );
    assert!(
        widest(&sparse) <= sparse_src * sparse_targets.len(),
        "the overlap body ran over a box of {} elements",
        widest(&sparse)
    );
    // The build holds nothing per cell of the source x target box: no mask
    // over it and no table with an entry per cell, in the program or in any
    // function it calls.
    let cells_of_box = sparse_src * sparse_targets.len();
    for prog in std::iter::once(&sparse).chain(sparse.funcs.iter().map(|f| &**f)) {
        for d in &prog.tables.const_data {
            assert_ne!(
                d.shape.as_slice(),
                [sparse_src, sparse_targets.len()],
                "a build-time payload over the output box"
            );
        }
        for g in &prog.tables.gather_tables {
            assert!(
                g.pos.len() < cells_of_box,
                "a gather table with {} entries for a box of {cells_of_box} cells",
                g.pos.len()
            );
        }
    }

    // A single bin admits all 20 pairs, including zero and nonzero overlaps.
    let dense_src = 5;
    let dense_targets = [0, 1, 2, 3];
    let dense = ab_check_at_times(
        template_regrid(dense_src, &dense_targets, 1.0e6),
        0.5,
        2.0,
        times,
    );
    assert!(
        widest(&dense) >= dense_src * dense_targets.len() * 4,
        "a gate keeping every cell is not compacted"
    );
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
            &["f"],
            fl.clone(),
            ix("w", vec![idx(e.clone(), &[json!("f"), json!("le")])]),
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
        json!({"lhs": d_lhs("w", &["e"], json!({"e": {"from": "edge_ids"}})),
               "rhs": faq(&["e"], json!({"e": {"from": "edge_ids"}}), op("-", vec![json!("e"), ix("w", vec![json!("e")])]))}),
        json!({"lhs": d_lhs("q", &["f"], f.clone()),
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
            "rhs": faq(&["f"], f.clone(), op("-", vec![op("*", vec![json!(2.0), face_sum()]), qf()]))}));
        eqs.push(json!({"lhs": d_lhs("p", &["f"], f.clone()),
            "rhs": faq(&["f"], f, ix("r", vec![json!("f")]))}));
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

/// The per-cell oracle reads an array-producing nested `faq` under an
/// elementwise operator at the current output cell, as the tape does.
#[test]
fn nested_face_sum_through_connectivity_matches_the_oracle() {
    for observed_connectivity in [true, false] {
        for observed in [false, true] {
            let doc = mesh_face_sum_doc(observed_connectivity, observed);
            let compiled = compile(doc.clone());
            let n = compiled.state_variable_names().len();
            let state = seeded_state(n, 1, 0.25, 2.5);
            let (dy, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new());
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
    let mut inner = faq(&["f"], json!({"f": nested}), ix("w", vec![json!("f")]));
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
                {"lhs": d_lhs("w", &["f"], f.clone()),
                 "rhs": faq(&["f"], f.clone(), op("*", vec![json!(-0.5), ix("w", vec![json!("f")])]))},
                {"lhs": d_lhs("q", &["f"], f),
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
        let compiled = compile(doc.clone());
        let names = compiled.state_variable_names();
        let state = seeded_state(names.len(), 1, 0.25, 2.5);
        take_const_array_oob();
        let (dy, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new());
        let fault = take_const_array_oob().expect("the oracle latches a fault");
        assert!(
            fault.starts_with("E_TREEWALK_NESTED_BOX_MISMATCH")
                && fault.contains("the equation for 'M.q'"),
            "{nested}: {fault}"
        );
        for (name, v) in names.iter().zip(&dy) {
            assert_eq!(v.is_nan(), name.contains("q["), "{nested}: {name} = {v}");
        }
        let (_, report) = compiled.build_tape_opts(&HashSet::new(), None);
        assert!(
            report.fallbacks.iter().any(|(rule, _)| rule == "D(M.q)"),
            "{nested}: the tape refuses the rule: {:?}",
            report.fallbacks
        );
    }
    oracle_ab(mismatched_nested_box_doc(json!({"from": "cells"})));
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
    model["operators"] = library("geometry.esm");
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
            count_where(&prog, |i| matches!(i, Instr::JmpIfZero { .. })),
            0,
            "{rhs}"
        );
        let selects = count_where(&prog, |i| matches!(i, Instr::Select { .. }))
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
        let compiled = compile(scalar_select_doc(rhs.clone()));
        let (prog, _) = compiled.tape(&HashSet::new());
        let prog = prog.as_ref().expect("taped");
        assert_eq!(
            count_where(prog, |i| matches!(i, Instr::JmpIfZero { .. })),
            1,
            "{rhs}"
        );
        let _ = taped_dy(&scalar_select_doc(rhs));
    }
}

/// The repeated build-time work of the overlap template (its fan areas and
/// ramps, lowered once per box they are read at) is computed once: no two
/// pure CONST instructions of the program are the same computation.
fn assert_unique_build_time_instructions(prog: &super::ir::TapeProgram) {
    let canon: Vec<u32> = (0..prog.tables.slots.len() as u32).collect();
    let guarded = prog.guarded_positions();
    let mut seen = HashSet::new();
    for pc in 0..prog.n_const as usize {
        if guarded[pc] {
            continue;
        }
        if let Some(k) = super::dedup::key(prog, pc, &prog.instrs[pc], &canon) {
            assert!(seen.insert(k.clone()), "repeated: {:?}", prog.instrs[pc]);
        }
    }
}

/// Near misses are different computations: another literal (even `-0.0`
/// against `+0.0`, or another NaN payload), another operation, another
/// operand.
#[test]
fn different_build_time_instructions_stay_apart() {
    let (prog, _) = oracle_ab(scalar_select_doc(op("+", vec![json!("x"), json!(1)])));
    let canon: Vec<u32> = (0..prog.tables.slots.len() as u32).collect();
    let out = (0..prog.tables.slots.len() as u32)
        .find(|&s| prog.tables.slots[s as usize].scalar)
        .expect("a scalar slot");
    let other = (out + 1..prog.tables.slots.len() as u32)
        .find(|&s| prog.tables.slots[s as usize].scalar)
        .expect("another scalar slot");
    use super::ir::Operand;
    use crate::simulate_array::BinCode;
    let bin = |op: BinCode, a: Operand, b: Operand| Instr::Bin { op, a, b, out };
    let key = |i: &Instr| super::dedup::key(&prog, 0, i, &canon).expect("keyed");
    let x = Operand::Slot(other);
    let base = key(&bin(BinCode::Add, x, Operand::Lit(0.0)));
    for near in [
        bin(BinCode::Add, x, Operand::Lit(-0.0)),
        bin(BinCode::Sub, x, Operand::Lit(0.0)),
        bin(BinCode::Add, Operand::Slot(out), Operand::Lit(0.0)),
        bin(BinCode::Add, x, Operand::Time),
    ] {
        assert_ne!(key(&near), base, "{near:?}");
    }
    let nan_a = key(&bin(BinCode::Add, x, Operand::Lit(f64::NAN)));
    let nan_b = key(&bin(
        BinCode::Add,
        x,
        Operand::Lit(f64::from_bits(f64::NAN.to_bits() ^ 1)),
    ));
    assert_ne!(nan_a, nan_b);
    assert_eq!(base, key(&bin(BinCode::Add, x, Operand::Lit(0.0))));
}

/// Several scalar lookup sites (the `linear` and `bilinear` templates at a
/// scalar query each, the query moving past both ends of the axes and NaN at
/// some states) run their straight scalar runs as one block each, inside the
/// arms of the templates' branches too: the oracle's bits in every arm.
#[test]
fn scalar_lookup_blocks_match_the_oracle() {
    let ax = json!([0.5, 1.0, 1.5, 2.25, 3.0, 4.5, 6.0, 7.5]);
    let ay = json!([-1.0, 0.0, 2.0, 3.0]);
    let tx = json!([4.0, -1.5, 2.0, 0.25, 3.5, -2.0, 1.0, 6.0]);
    let tbl: Vec<Value> = (0..8)
        .map(|i| json!([i as f64, 0.5 * i as f64, -(i as f64), 2.0 + i as f64]))
        .collect();
    let mut eqs = vec![
        json!({"lhs": "x", "rhs": op("-", vec![op("*", vec![json!(4), json!("u")]), json!(2)])}),
        json!({"lhs": "y", "rhs": op("-", vec![op("*", vec![json!(2), json!("u")]), json!(1.5)])}),
    ];
    let mut vars = json!({
        "u": {"type": "unknown", "default": 0.5},
        "x": {"type": "unknown"},
        "y": {"type": "unknown"}
    });
    let mut sum = Vec::new();
    for s in 0..3 {
        let xq = if s == 2 {
            op(
                "ifelse",
                vec![
                    op(">", vec![json!("u"), json!(2.0)]),
                    op("/", vec![json!(0.0), json!(0.0)]),
                    json!("x"),
                ],
            )
        } else {
            op("+", vec![json!("x"), json!(0.25 * s as f64)])
        };
        let lin = format!("l{s}");
        let bil = format!("b{s}");
        vars[&lin] = json!({"type": "unknown"});
        vars[&bil] = json!({"type": "unknown"});
        eqs.push(json!({"lhs": lin, "rhs": apply("linear", json!({
            "table": {"op": "const", "args": [], "value": tx},
            "axis": {"op": "const", "args": [], "value": ax}, "x": xq, "n": 8}))}));
        eqs.push(json!({"lhs": bil, "rhs": apply("bilinear", json!({
            "table": {"op": "const", "args": [], "value": tbl},
            "axis_x": {"op": "const", "args": [], "value": ax},
            "axis_y": {"op": "const", "args": [], "value": ay},
            "x": xq, "y": "y", "nx": 8, "ny": 4}))}));
        sum.push(json!(lin));
        sum.push(json!(bil));
    }
    eqs.push(json!({"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
        "rhs": op("-", vec![op("*", vec![json!(0.01), op("+", sum)]), json!("u")])}));
    let mut model = json!({"variables": vars, "equations": eqs});
    model["operators"] = library("interp.esm");
    oracle_ab(document("scalar_lookup_blocks", json!({}), model));
}

/// A reference inside a rank-0 reduction at a recurrence cell, which is
/// lowered one contraction tuple at a time with the tuple bound as
/// constants: each binding that reads the bound index is passed its value at
/// that term, and the calls agree with the oracle bit for bit.
#[test]
fn a_call_inside_an_unrolled_contraction_matches_the_oracle() {
    let term = apply(
        "scaled",
        json!({"x": ix("u", vec![json!("j")]), "w": op("+", vec![json!("j"), json!(0.5)])}),
    );
    let inner = json!({"op": "faq", "args": [], "output_idx": [], "reduce": "+",
                       "ranges": {"j": [1, 3]}, "expr": term});
    let s = json!({"op": "faq", "args": [], "output_idx": ["k"], "ranges": {"k": {"from": "steps"}},
        "expr": op("ifelse", vec![
            op("<=", vec![json!("k"), json!(1)]),
            ix("u", vec![json!(1)]),
            op("+", vec![
                op("*", vec![json!(0.3), ix("s", vec![op("-", vec![json!("k"), json!(1)])])]),
                inner])])});
    let steps = json!({"k": [1, 5]});
    let model = json!({
        "variables": {
            "u": {"type": "unknown", "shape": ["steps"], "default": 0.0},
            "s": {"type": "unknown", "shape": ["steps"]}
        },
        "operators": {"scaled": {"params": ["x", "w"],
            "body": op("+", vec![op("*", vec![json!("x"), json!("w")]), json!(0.125)])}},
        "equations": [
            {"lhs": "s", "rhs": s},
            {"lhs": d_lhs("u", &["k"], steps.clone()),
             "rhs": faq(&["k"], steps, op("-", vec![ix("s", vec![json!("k")]), ix("u", vec![json!("k")])]))}
        ]
    });
    let (prog, _) = oracle_ab(document(
        "unrolled_call",
        json!({"steps": {"kind": "interval", "size": 5}}),
        model,
    ));
    assert!(count_where(&prog, |x| matches!(x, Instr::Call { .. })) > 0);
}
