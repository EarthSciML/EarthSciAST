//! An OVERLAP join gate whose sides are `[pos, verts, coord]` RING STACKS
//! computed from scalar grid parameters (CONFORMANCE_SPEC §5.5.6, the one-name
//! envelope form), on a grid large enough that the dense narrow phase does not
//! fit the native compiler.
//!
//! This is the shape of reseact's `NEIRegrid.A_ij`: EarthSciDiscretizations'
//! `conservative_overlap_A_ij_gated` over rings built by
//! `cartesian_cell_rings_poly` from an origin and a spacing, with the
//! `esm:std/geometry.esm` `overlap_area_planar` template as the narrow phase.
//! The gate's range symbols used to resolve only from 1-D envelope factors, so
//! a ring-stack gate was never driven: the interpreter walked the full source
//! x target product, and the native compiler promoted the template's per-pair
//! vertex reductions over source x target x vertex x vertex and refused ("a
//! rank-0 output's promoted box is too large").
//!
//! Here the source grid is 200 x 200 cells and the target 15 x 15, so that
//! promoted box is 40 000 x 225 x 4 x 4 = 144 000 000 elements, over the
//! budget. Driven, the narrow phase runs over the candidate pairs only.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::extension::broad_phase::{overlap_enum_visits, reset_overlap_enum_visits};
use earthsci_ast::{Compiler, EsmProblem, ProblemOptions, esm_problem, observed_field};
use serde_json::{Value, json};

const L: f64 = 12.0;

fn op(name: &str, args: Vec<Value>) -> Value {
    json!({"op": name, "args": args})
}

/// The `cartesian_cell_rings_poly` ring stack over `gx`-wide rows: vertex
/// `v` of cell `c` is the CCW corner `(W,S), (E,S), (E,N), (W,N)`.
fn rings(gx: usize, x0: &str, y0: &str, dx: &str, dy: &str, cells: &str) -> Value {
    let row = op(
        "floor",
        vec![op(
            "/",
            vec![op("-", vec![json!("c"), json!(1)]), json!(gx)],
        )],
    );
    let col = op(
        "-",
        vec![
            op("-", vec![json!("c"), json!(1)]),
            op("*", vec![json!(gx), row.clone()]),
        ],
    );
    let is = |v: i64| op("==", vec![json!("v"), json!(v)]);
    let x = op(
        "+",
        vec![
            json!(x0),
            op("*", vec![col, json!(dx)]),
            op("*", vec![json!(dx), op("+", vec![is(2), is(3)])]),
        ],
    );
    let y = op(
        "+",
        vec![
            json!(y0),
            op("*", vec![row, json!(dy)]),
            op("*", vec![json!(dy), op("+", vec![is(3), is(4)])]),
        ],
    );
    json!({
        "op": "faq",
        "output_idx": ["c", "v", "k"],
        "ranges": {"c": {"from": cells}, "v": {"from": "verts"}, "k": {"from": "coord"}},
        "args": [],
        "expr": op("ifelse", vec![op("==", vec![json!("k"), json!(1)]), x, y])
    })
}

fn doc(sx: usize, sy: usize, tx: usize, ty: usize) -> Value {
    let gate =
        json!([{"overlap": {"src_env": ["src_poly"], "tgt_env": ["tgt_poly"], "eps": 1e-9}}]);
    let ranges = json!({"i": {"from": "src_cells"}, "j": {"from": "tgt_cells"}});
    let a_ij = json!({"op": "index", "args": ["A_ij", "i", "j"]});
    let par = |v: f64| json!({"type": "parameter", "units": "1", "default": v});
    let unknown = |shape: Value| json!({"type": "unknown", "units": "1", "shape": shape});
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "overlap_gate_ring_stack"},
        "index_sets": {
            "src_cells": {"kind": "interval", "size": sx * sy},
            "tgt_cells": {"kind": "interval", "size": tx * ty},
            "verts": {"kind": "interval", "size": 4},
            "coord": {"kind": "interval", "size": 2}
        },
        "models": {"Regrid": {
            "expression_template_imports": [
                {"ref": "esm:std/geometry.esm", "only": ["overlap_area_planar"]}
            ],
            "variables": {
                "atol": par(1e-12),
                "src_x0": par(0.0), "src_y0": par(0.0),
                "src_dx": par(L / sx as f64), "src_dy": par(L / sy as f64),
                "tgt_x0": par(0.0), "tgt_y0": par(0.0),
                "tgt_dx": par(L / tx as f64), "tgt_dy": par(L / ty as f64),
                "src_poly": unknown(json!(["src_cells", "verts", "coord"])),
                "tgt_poly": unknown(json!(["tgt_cells", "verts", "coord"])),
                "A_ij": unknown(json!(["src_cells", "tgt_cells"])),
                "A_j": unknown(json!(["tgt_cells"]))
            },
            "equations": [
                {"lhs": "src_poly", "rhs": rings(sx, "src_x0", "src_y0", "src_dx", "src_dy", "src_cells")},
                {"lhs": "tgt_poly", "rhs": rings(tx, "tgt_x0", "tgt_y0", "tgt_dx", "tgt_dy", "tgt_cells")},
                {"lhs": "A_ij", "rhs": {
                    "op": "faq", "args": [], "semiring": "sum_product",
                    "output_idx": ["i", "j"], "ranges": ranges, "join": gate,
                    "expr": {"op": "apply_expression_template", "args": [],
                             "name": "overlap_area_planar",
                             "bindings": {"ring_a": "src_poly", "cell_a": "i", "nv_a": 4,
                                          "ring_b": "tgt_poly", "cell_b": "j", "nv_b": 4}}
                }},
                {"lhs": "A_j", "rhs": {
                    "op": "faq", "args": [], "semiring": "sum_product",
                    "output_idx": ["j"], "ranges": ranges, "join": gate,
                    "filter": op(">", vec![a_ij.clone(), json!("atol")]),
                    "expr": a_ij
                }}
            ]
        }}
    })
}

fn build(doc: &Value, compiler: Compiler) -> (EsmProblem, u64) {
    reset_overlap_enum_visits();
    let p = esm_problem(
        doc,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(compiler),
            model_name: Some("Regrid".into()),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{compiler:?} build: {e}"));
    (p, overlap_enum_visits())
}

fn bits(p: &EsmProblem, name: &str) -> Vec<u64> {
    observed_field(p, name)
        .unwrap_or_else(|e| panic!("{name} materialized: {e}"))
        .iter()
        .map(|x| x.to_bits())
        .collect()
}

#[test]
fn a_parameter_ring_stack_gate_drives_the_narrow_phase_under_both_compilers() {
    let (sx, sy, tx, ty) = (200usize, 200usize, 15usize, 15usize);
    let doc = doc(sx, sy, tx, ty);

    let (native, _) = build(&doc, Compiler::Native);
    let (interp, interp_visits) = build(&doc, Compiler::Interpreter);

    // The interpreter visits the broad phase's candidate pairs only, not the
    // 9 000 000-pair product: the gate is driven.
    let product = (sx * sy * tx * ty) as u64;
    assert!(
        interp_visits > 0 && interp_visits < product / 100,
        "{interp_visits} visits against a {product}-pair product: the ring-stack gate is not driven"
    );

    // Native agrees with the reference evaluator bit for bit.
    assert_eq!(bits(&native, "A_ij"), bits(&interp, "A_ij"));
    assert_eq!(bits(&native, "A_j"), bits(&interp, "A_j"));

    // Both grids tile [0, L]^2, so every target's covered area is its own.
    let area = (L / tx as f64) * (L / ty as f64);
    let a_j: Vec<f64> = observed_field(&native, "A_j")
        .expect("A_j")
        .iter()
        .copied()
        .collect();
    assert_eq!(a_j.len(), tx * ty);
    for (j, a) in a_j.iter().enumerate() {
        assert!(
            (a - area).abs() < 1e-9 * area,
            "A_j[{j}] = {a}, want {area}"
        );
    }
    // One source cell's share of the first target, and a pruned pair.
    // Row-major over (src_cells, tgt_cells).
    let a_ij: Vec<f64> = observed_field(&native, "A_ij")
        .expect("A_ij")
        .iter()
        .copied()
        .collect();
    let src_area = (L / sx as f64) * (L / sy as f64);
    assert!(
        (a_ij[0] - src_area).abs() < 1e-12,
        "A_ij[1, 1] = {}",
        a_ij[0]
    );
    assert_eq!(
        a_ij[(sx * sy - 1) * tx * ty],
        0.0,
        "a pruned pair is the identity"
    );
}
