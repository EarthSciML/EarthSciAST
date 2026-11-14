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
//! In the large case the source grid is 200 x 200 cells and the target
//! 15 x 15, so that promoted box is 40 000 x 225 x 4 x 4 = 144 000 000
//! elements, over the budget. Driven, the narrow phase runs over the
//! candidate pairs only.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::extension::broad_phase::{overlap_enum_visits, reset_overlap_enum_visits};
use earthsci_ast::{
    Compiler, EsmProblem, ProblemOptions, Remake, esm_problem, observed_field, remake,
};
use serde_json::{Value, json};
use std::collections::HashMap;

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
    build_with(doc, compiler, HashMap::new())
}

fn build_with(doc: &Value, compiler: Compiler, p: HashMap<String, f64>) -> (EsmProblem, u64) {
    reset_overlap_enum_visits();
    let p = esm_problem(
        doc,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(compiler),
            model_name: Some("Regrid".into()),
            p,
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

/// The covered area of every target cell (both grids tile `[0, L]^2`, so it
/// is the cell's own area), one source cell's share of the first target, and
/// a pruned pair, which holds the identity.
fn check_areas(p: &EsmProblem, sx: usize, sy: usize, tx: usize, ty: usize) {
    let area = (L / tx as f64) * (L / ty as f64);
    let a_j: Vec<f64> = observed_field(p, "A_j")
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
    // Row-major over (src_cells, tgt_cells).
    let a_ij: Vec<f64> = observed_field(p, "A_ij")
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

/// The gate is driven under both compilers, which agree bit for bit.
#[test]
fn a_parameter_ring_stack_gate_is_driven_and_both_compilers_agree() {
    let (sx, sy, tx, ty) = (12usize, 12usize, 3usize, 3usize);
    let doc = doc(sx, sy, tx, ty);

    let (native, _) = build(&doc, Compiler::Native);
    let (interp, interp_visits) = build(&doc, Compiler::Interpreter);

    // The interpreter visits the broad phase's candidate pairs only (the
    // counter moves only on a driven gate). Per axis, the 12 source columns
    // each meet their own target column, and the 4 that touch an interior
    // target edge (the closed predicate admits edge contact) meet one more:
    // 16 x 16 = 256 candidate pairs of the 1296-pair product, walked once by
    // A_ij and once by A_j.
    assert_eq!(
        interp_visits,
        2 * 256,
        "the ring-stack gate is not driven over its candidate pairs"
    );
    assert_eq!(bits(&native, "A_ij"), bits(&interp, "A_ij"));
    assert_eq!(bits(&native, "A_j"), bits(&interp, "A_j"));
    check_areas(&native, sx, sy, tx, ty);
}

/// At a size whose dense narrow phase does not fit, `native` builds it over
/// the candidate pairs (it used to refuse: "a rank-0 output's promoted box is
/// too large").
#[test]
fn native_compiles_a_ring_stack_gate_too_large_to_run_dense() {
    let (sx, sy, tx, ty) = (200usize, 200usize, 15usize, 15usize);
    let (native, _) = build(&doc(sx, sy, tx, ty), Compiler::Native);
    check_areas(&native, sx, sy, tx, ty);
}

/// Two builds on ONE thread whose gates name the same ring stacks at the same
/// sizes, but over different geometry (here the target grid moves by half a
/// cell). The interpreter keeps its candidate-pair index in a per-thread
/// cache across builds, so it must key the index by the rings' contents, not
/// only their names: keyed by name, the second build was served the first
/// build's candidate pairs and silently lost the overlaps the shift created.
/// Each build is checked against `native`, which builds its own pairs.
#[test]
fn two_builds_with_the_same_ring_names_and_different_geometry_both_answer_correctly() {
    let (sx, sy, tx, ty) = (12usize, 12usize, 3usize, 3usize);
    let doc = doc(sx, sy, tx, ty);
    let shifted = || HashMap::from([("tgt_x0".to_string(), 0.5 * L / tx as f64)]);

    let (first, _) = build(&doc, Compiler::Interpreter);
    let (second, _) = build_with(&doc, Compiler::Interpreter, shifted());
    let (native_first, _) = build(&doc, Compiler::Native);
    let (native_second, _) = build_with(&doc, Compiler::Native, shifted());

    assert_eq!(bits(&first, "A_ij"), bits(&native_first, "A_ij"));
    assert_eq!(bits(&second, "A_ij"), bits(&native_second, "A_ij"));
    assert_eq!(bits(&second, "A_j"), bits(&native_second, "A_j"));
    assert_ne!(
        bits(&first, "A_ij"),
        bits(&second, "A_ij"),
        "the shift changes the overlaps"
    );
}

/// The model `doc` builds, as a mutable JSON object.
fn regrid_model(doc: &mut Value) -> &mut Value {
    &mut doc["models"]["Regrid"]
}

/// A ring stack that reads a STATE is not build-time data (CONFORMANCE_SPEC
/// §5.5.6: an envelope factor MUST be build-time const-array data). Both
/// compilers refuse it, with Julia's code; `native` used to refuse it at its
/// own gate while `interpreter` declined the gate and ran the full product.
#[test]
fn a_ring_stack_read_from_a_state_is_refused_by_both_compilers() {
    let (sx, sy, tx, ty) = (4usize, 4usize, 2usize, 2usize);
    let mut doc = doc(sx, sy, tx, ty);
    let m = regrid_model(&mut doc);
    m["variables"]["s"] = json!({"type": "unknown", "units": "1", "default": 0.0});
    m["variables"]["x0s"] = json!({"type": "unknown", "units": "1"});
    m["variables"]["area"] =
        json!({"type": "unknown", "units": "1", "shape": ["tgt_cells"], "default": 0.0});
    let eqs = m["equations"].as_array_mut().unwrap();
    eqs[1]["rhs"] = rings(tx, "x0s", "tgt_y0", "tgt_dx", "tgt_dy", "tgt_cells");
    eqs.push(json!({"lhs": "x0s", "rhs": op("+", vec![json!("tgt_x0"), json!("s")])}));
    eqs.push(json!({"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 0.0}));
    eqs.push(json!({"lhs": {"op": "D", "args": ["area"], "wrt": "t"}, "rhs": "A_j"}));

    for compiler in [Compiler::Interpreter, Compiler::Native] {
        let err = esm_problem(
            &doc,
            (0.0, 1.0),
            ProblemOptions {
                compiler: Some(compiler),
                model_name: Some("Regrid".into()),
                ..Default::default()
            },
        )
        .err()
        .unwrap_or_else(|| panic!("{compiler:?} built a gate over a state-dependent ring"))
        .to_string();
        assert!(
            err.contains("E_TREEWALK_JOIN_OVERLAP") && err.contains("tgt_poly"),
            "{compiler:?}: {err}"
        );
        assert!(err.contains("the state `s`"), "{compiler:?}: {err}");
    }
}

/// A ring stack another COMPONENT defines: the gate in `Regrid` names
/// `Grid.src_poly` / `Grid.tgt_poly`, whose rings read `Grid`'s own grid
/// parameters by their bare names. The parameters the build bakes follow that
/// reference across components, so both compilers build the gate from the
/// same baked values and agree, and a later substitution of one of them is
/// refused, naming the join as the cause.
#[test]
fn a_ring_stack_defined_in_another_component_is_baked() {
    let (sx, sy, tx, ty) = (6usize, 6usize, 2usize, 2usize);
    let mut doc = doc(sx, sy, tx, ty);
    let single = regrid_model(&mut doc).take();
    let vars = single["variables"].as_object().unwrap();
    let eqs = single["equations"].as_array().unwrap();
    let grid_vars: serde_json::Map<String, Value> = vars
        .iter()
        .filter(|(k, _)| {
            k.contains("_x0") || k.contains("_y0") || k.contains("_d") || k.ends_with("_poly")
        })
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    let regrid_vars: serde_json::Map<String, Value> = vars
        .iter()
        .filter(|(k, _)| !grid_vars.contains_key(*k))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    let qualify = |e: &Value| -> Value {
        serde_json::from_str(
            &serde_json::to_string(e)
                .unwrap()
                .replace("\"src_poly\"", "\"Grid.src_poly\"")
                .replace("\"tgt_poly\"", "\"Grid.tgt_poly\""),
        )
        .unwrap()
    };
    doc["models"] = json!({
        "Grid": {"variables": grid_vars, "equations": [eqs[0].clone(), eqs[1].clone()]},
        "Regrid": {
            "expression_template_imports": single["expression_template_imports"].clone(),
            "variables": regrid_vars,
            "equations": [qualify(&eqs[2]), qualify(&eqs[3])]
        }
    });
    let shifted = HashMap::from([("Grid.tgt_x0".to_string(), 0.5 * L / tx as f64)]);
    let build = |compiler: Compiler| {
        esm_problem(
            &doc,
            (0.0, 0.0),
            ProblemOptions {
                compiler: Some(compiler),
                p: shifted.clone(),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{compiler:?} build: {e}"))
    };
    let native = build(Compiler::Native);
    let interp = build(Compiler::Interpreter);
    assert_eq!(bits(&native, "Regrid.A_ij"), bits(&interp, "Regrid.A_ij"));
    // The shifted target origin reached the rings: the first target cell
    // starts half a cell in, so the first source cell does not reach it.
    let a_ij: Vec<f64> = observed_field(&native, "Regrid.A_ij")
        .expect("A_ij")
        .iter()
        .copied()
        .collect();
    assert_eq!(a_ij[0], 0.0, "{a_ij:?}");

    for compiler_problem in [&native, &interp] {
        let Err(err) = remake(
            compiler_problem,
            &Remake {
                p: HashMap::from([("Grid.tgt_x0".to_string(), 0.0)]),
                ..Default::default()
            },
        ) else {
            panic!("a ring parameter is baked, so its remake is refused");
        };
        let err = err.to_string();
        assert!(err.contains("overlap"), "{err}");
    }
}
