#![cfg(all(not(target_arch = "wasm32"), feature = "solve"))]
//! The convex overlap-area templates of `lib/geometry.esm` against the
//! `polygon_intersection_area` leaf.
//!
//! Every polygon pair of `tests/conformance/geometry_templates/pairs.json` (the
//! cell pairs the repository's polygon and regridding documents clip, generated
//! by `scripts/gen-geometry-template-pairs.py`) runs through the expanded
//! template (`overlap_area_planar`, or `overlap_area_spherical` over unit vectors
//! built with `lonlat_to_unit`) under the interpreter, and through the leaf (the
//! planar Sutherland–Hodgman clip, the `s2rst` spherical clip). The template must
//! agree with the leaf and with the pair's exact / 40-digit reference area within
//! the CONFORMANCE_SPEC §5.8.2 tolerance, give the planar reference exactly on a
//! pair of cells from one grid, and give the same bits on the padded copy of
//! every group (repeated vertices contribute exactly zero).

use std::collections::HashMap;

use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{
    LoadOptions, Manifold, intersect_polygon, load_string_with_options, polygon_area,
};
use serde_json::{Value, json};

use crate::common;

fn pairs() -> Value {
    let path = common::repo_fixture("conformance/geometry_templates/pairs.json");
    serde_json::from_str(&std::fs::read_to_string(&path).expect("pairs.json"))
        .expect("pairs.json parses")
}

fn konst(v: Value) -> Value {
    json!({"op": "const", "args": [], "value": v})
}

fn apply(name: &str, bindings: Value) -> Value {
    json!({"op": "apply_expression_template", "args": [], "name": name, "bindings": bindings})
}

/// `D(out_k) = rhs[k]` for every k in one document importing `lib/geometry.esm`,
/// evaluated once by the interpreter: the derivatives are the values. One
/// document per batch, since every import re-validates the library.
fn values(rhs: &[Value]) -> Vec<f64> {
    let mut variables = serde_json::Map::new();
    let mut equations = Vec::new();
    for (k, r) in rhs.iter().enumerate() {
        let v = format!("out_{k}");
        variables.insert(
            v.clone(),
            json!({"type": "unknown", "default": 0.0, "units": "1"}),
        );
        equations.push(json!({"lhs": {"op": "D", "args": [v], "wrt": "t"}, "rhs": r}));
    }
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "geometry_template_probe", "authors": ["test"]},
        "models": {"M": {
            "expression_template_imports": [{"ref": "lib/geometry.esm"}],
            "variables": variables,
            "equations": equations
        }}
    })
    .to_string();
    let options = LoadOptions {
        base_path: Some(common::repo_tests_dir().join("..")),
        ..Default::default()
    };
    let file = load_string_with_options(&doc, &options).expect("load");
    let compiled = ArrayCompiled::from_file(&file).expect("compile");
    let names = compiled.state_variable_names().to_vec();
    let u = vec![0.0; names.len()];
    let (du, _) = compiled.debug_eval_rhs(&u, 0.0, &HashMap::new(), true);
    (0..rhs.len())
        .map(|k| {
            let bare = format!("out_{k}");
            let slot = names
                .iter()
                .position(|n| *n == bare || n.split_once('.').map(|x| x.1) == Some(bare.as_str()))
                .unwrap_or_else(|| panic!("no state {bare}"));
            du[slot]
        })
        .collect()
}

fn unit_calls(stack: &Value) -> Vec<Value> {
    let cells = stack.as_array().unwrap();
    let nv = cells[0].as_array().unwrap().len();
    let mut out = Vec::new();
    for c in 1..=cells.len() {
        for v in 1..=nv {
            for d in 1..=3 {
                out.push(apply(
                    "lonlat_to_unit",
                    json!({"ring": konst(stack.clone()), "cell": c, "vert": v, "comp": d}),
                ));
            }
        }
    }
    out
}

fn restack(stack: &Value, vals: &mut impl Iterator<Item = f64>) -> Value {
    let cells: Vec<Value> = stack
        .as_array()
        .unwrap()
        .iter()
        .map(|cell| {
            let verts: Vec<Value> = cell
                .as_array()
                .unwrap()
                .iter()
                .map(|_| {
                    json!([
                        vals.next().unwrap(),
                        vals.next().unwrap(),
                        vals.next().unwrap()
                    ])
                })
                .collect();
            Value::Array(verts)
        })
        .collect();
    Value::Array(cells)
}

/// Template area of every pair, by group id.
fn template_values(groups: &[Value]) -> HashMap<String, Vec<f64>> {
    let spherical: Vec<&Value> = groups
        .iter()
        .filter(|g| g["manifold"] != "planar")
        .collect();
    let mut calls = Vec::new();
    for g in &spherical {
        calls.extend(unit_calls(&g["ring_a"]));
        calls.extend(unit_calls(&g["ring_b"]));
    }
    let unit_vals = if calls.is_empty() {
        Vec::new()
    } else {
        values(&calls)
    };
    let mut it = unit_vals.into_iter();
    let mut stacks: HashMap<String, (Value, Value)> = HashMap::new();
    for g in &spherical {
        let a = restack(&g["ring_a"], &mut it);
        let b = restack(&g["ring_b"], &mut it);
        stacks.insert(g["id"].as_str().unwrap().to_string(), (a, b));
    }
    let mut calls = Vec::new();
    let mut owners = Vec::new();
    for g in groups {
        let id = g["id"].as_str().unwrap().to_string();
        let (name, ra, rb) = if g["manifold"] == "planar" {
            (
                "overlap_area_planar",
                g["ring_a"].clone(),
                g["ring_b"].clone(),
            )
        } else {
            let (a, b) = stacks[&id].clone();
            ("overlap_area_spherical", a, b)
        };
        for p in g["pairs"].as_array().unwrap() {
            calls.push(apply(
                name,
                json!({"ring_a": konst(ra.clone()), "cell_a": p["i"], "nv_a": g["nv_a"],
                       "ring_b": konst(rb.clone()), "cell_b": p["j"], "nv_b": g["nv_b"]}),
            ));
            owners.push(id.clone());
        }
    }
    let mut out: HashMap<String, Vec<f64>> = HashMap::new();
    for (id, v) in owners.into_iter().zip(values(&calls)) {
        out.entry(id).or_default().push(v);
    }
    out
}

fn ring(stack: &Value, k: &Value) -> Vec<(f64, f64)> {
    let k = k.as_u64().unwrap() as usize;
    stack[k - 1]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| (p[0].as_f64().unwrap(), p[1].as_f64().unwrap()))
        .collect()
}

/// The leaf's area, or `None` when it refuses an operand.
fn leaf(g: &Value, p: &Value) -> Option<f64> {
    let manifold = Manifold::from_flag(g["manifold"].as_str().unwrap()).unwrap();
    let clip = intersect_polygon(
        &ring(&g["ring_a"], &p["i"]),
        &ring(&g["ring_b"], &p["j"]),
        manifold,
    )
    .ok()?;
    if clip.len() < 3 {
        return Some(0.0);
    }
    polygon_area(&clip, manifold).ok()
}

fn atol(g: &Value, factor: f64) -> f64 {
    if g["manifold"] != "planar" {
        return factor;
    }
    let mut m: f64 = 1.0;
    for key in ["ring_a", "ring_b"] {
        for r in g[key].as_array().unwrap() {
            for pt in r.as_array().unwrap() {
                for x in pt.as_array().unwrap() {
                    m = m.max(x.as_f64().unwrap().abs());
                }
            }
        }
    }
    factor * m * m
}

#[test]
fn geometry_templates_agree_with_polygon_intersection_area() {
    let corpus = pairs();
    let rtol = corpus["tolerance"]["rtol"].as_f64().unwrap();
    let factor = corpus["tolerance"]["atol_factor"].as_f64().unwrap();
    let groups = corpus["groups"].as_array().unwrap();
    let tvals = template_values(groups);
    let mut failures = Vec::new();
    for g in groups {
        let id = g["id"].as_str().unwrap();
        let tol = atol(g, factor);
        let (mut max_ref, mut max_leaf) = (0.0_f64, 0.0_f64);
        for (p, &t) in g["pairs"].as_array().unwrap().iter().zip(&tvals[id]) {
            let label = format!("{id} ({}, {})", p["i"], p["j"]);
            if !t.is_finite() {
                failures.push(format!("{label}: template gives {t:?}"));
                continue;
            }
            if let Some(r) = p["reference"].as_f64() {
                max_ref = max_ref.max((t - r).abs());
                if (t - r).abs() > tol + rtol * r.abs() {
                    failures.push(format!("{label}: template {t:?} vs reference {r:?}"));
                }
                if p["same_grid"] == true && g["manifold"] == "planar" && t.to_bits() != r.to_bits()
                {
                    failures.push(format!("{label}: same-grid pair not exact: {t:?} vs {r:?}"));
                }
            }
            if let Some(l) = leaf(g, p) {
                max_leaf = max_leaf.max((t - l).abs());
                if (t - l).abs() > tol + rtol * l.abs() {
                    failures.push(format!("{label}: template {t:?} vs leaf {l:?}"));
                }
            }
        }
        if let Some(of) = g["padding_of"].as_str() {
            for (a, b) in tvals[id].iter().zip(&tvals[of]) {
                if a.to_bits() != b.to_bits() {
                    failures.push(format!("{id}: padded {a:?} vs unpadded {b:?}"));
                }
            }
        }
        if std::env::var("ESM_GEOMETRY_TEMPLATE_REPORT").as_deref() == Ok("1") {
            println!(
                "geometry template {id}: max |template - reference| = {max_ref:e}, max |template - leaf| = {max_leaf:e}"
            );
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn lonlat_to_unit_is_the_leaf_conversion() {
    let ring = json!([[[0.0, 0.0], [30.0, 45.0], [-120.5, -60.25], [179.9, 89.0]]]);
    let got = values(&unit_calls(&ring));
    let mut k = 0;
    for p in ring[0].as_array().unwrap() {
        let (lon, lat) = (p[0].as_f64().unwrap(), p[1].as_f64().unwrap());
        let (lo, la) = (
            lon * (std::f64::consts::PI / 180.0),
            lat * (std::f64::consts::PI / 180.0),
        );
        let want = [la.cos() * lo.cos(), la.cos() * lo.sin(), la.sin()];
        for w in want {
            assert_eq!(
                got[k].to_bits(),
                w.to_bits(),
                "({lon}, {lat}) component {k}"
            );
            k += 1;
        }
    }
}
