//! Cell-axis arrays under the projection-pushdown rewrite (CONFORMANCE_SPEC
//! §5.5.7 "Cell-axis arrays"). The Rust member of the triple; the peers are
//! `EarthSciAST.jl/test/pushdown_cell_geometry_test.jl` and
//! `earthsci-ast-py/tests/test_pushdown_cell_geometry.py`.
//!
//! The rewrite re-points a binning aggregate's reduction range onto the compact
//! derived support set, which RENUMBERS the cell symbol: after it fires, that
//! symbol counts support positions and support position `i` is grid cell
//! `member_factor[i]`. Every array the body reads through it must be renumbered
//! with it — not only the four envelope bounds of the containment predicate.
//!
//! Polygon allocation is the shape that makes the difference visible. Its weight
//! is `polygon_intersection_area(cell_ring[c], rec_ring[r]) / cell_area[c]`, so
//! the body reads a rank-3 `[cells, vertex, xy]` ring stack and a rank-1 area,
//! and neither is an envelope factor. Gathering only the envelopes leaves both
//! pointing at the full grid while the axis is compact: full-grid values read at
//! support positions, wrong numbers, no diagnostic anywhere.

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;

use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

use earthsci_ast::prepare::{AxisSel, PrepareError, PrepareOptions, PrepareProvider, prepare};
use earthsci_ast::pushdown_rewrite::desugar_pushdown;

fn ix(f: &str, idx: &[Value]) -> Value {
    let mut args = vec![json!(f)];
    args.extend(idx.iter().cloned());
    json!({"op": "index", "args": args})
}

fn param(shape: &[&str]) -> Value {
    json!({"type": "parameter", "default": 0.0, "shape": shape})
}

/// The polygon-allocation document: an envelope broad phase and an intersection
/// area for the narrow phase.
fn doc() -> Value {
    let env_overlap = json!({"op": "and", "args": [
        {"op": "<=", "args": [ix("src_W", &[json!("c")]), ix("rec_xmax", &[json!("r")])]},
        {"op": "<=", "args": [ix("rec_xmin", &[json!("r")]), ix("src_E", &[json!("c")])]},
        {"op": "<=", "args": [ix("src_S", &[json!("c")]), ix("rec_ymax", &[json!("r")])]},
        {"op": "<=", "args": [ix("rec_ymin", &[json!("r")]), ix("src_N", &[json!("c")])]},
    ]});
    let weight = json!({"op": "*", "args": [
        ix("emis_annual", &[json!("r")]),
        {"op": "/", "args": [
            {"op": "polygon_intersection_area", "manifold": "planar",
             "args": [ix("cell_ring", &[json!("c")]), ix("rec_ring", &[json!("r")])]},
            ix("cell_area", &[json!("c")])]}]});
    json!({
        "esm": "1.0.0",
        "metadata": {"name": "pushdown_cell_geometry"},
        "data_sources": {"MockSR": {"kind": "static", "source": {"url_template": "mock://sr"}}},
        "index_sets": {
            "src_cells": {"kind": "interval", "size": 4},
            "rcv_cells": {"kind": "interval", "size": 2},
            "emis_records": {"kind": "interval", "size": 3},
            "ring_vertex": {"kind": "interval", "size": 5},
            "xy": {"kind": "interval", "size": 2},
        },
        "models": {"Binned": {
            "variables": {
                "src_W": param(&["src_cells"]),
                "src_S": param(&["src_cells"]),
                "src_E": param(&["src_cells"]),
                "src_N": param(&["src_cells"]),
                "cell_area": param(&["src_cells"]),
                "cell_ring": param(&["src_cells", "ring_vertex", "xy"]),
                "rec_ring": param(&["emis_records", "ring_vertex", "xy"]),
                "rec_xmin": param(&["emis_records"]),
                "rec_ymin": param(&["emis_records"]),
                "rec_xmax": param(&["emis_records"]),
                "rec_ymax": param(&["emis_records"]),
                "emis_annual": param(&["emis_records"]),
                "SR_PM25": {"type": "parameter", "default": 0.0, "units": "1",
                            "shape": ["src_cells", "rcv_cells"],
                            "update": {"kind": "data", "source": "MockSR",
                                       "from": {"file_variable": "PM25"}}},
                "E_PM25": {"type": "unknown", "shape": ["src_cells"]},
                "conc_PM25": {"type": "unknown", "shape": ["rcv_cells"]},
            },
            "equations": [
                {"lhs": "E_PM25", "rhs": {
                    "op": "aggregate", "reduce": "+", "output_idx": ["c"],
                    "ranges": {"c": {"from": "src_cells"}, "r": {"from": "emis_records"}},
                    "args": ["src_W", "src_S", "src_E", "src_N",
                             "rec_xmin", "rec_ymin", "rec_xmax", "rec_ymax",
                             "cell_ring", "cell_area", "rec_ring", "emis_annual"],
                    "expr": {"op": "*", "args": [
                        {"op": "ifelse", "args": [env_overlap, 1.0, 0.0]}, weight]}}},
                {"lhs": "conc_PM25", "rhs": {
                    "op": "aggregate", "reduce": "+", "output_idx": ["rcv"],
                    "ranges": {"rcv": {"from": "rcv_cells"}, "s": {"from": "src_cells"}},
                    "args": ["SR_PM25", "E_PM25"],
                    "expr": {"op": "*", "args": [
                        ix("SR_PM25", &[json!("s"), json!("rcv")]),
                        ix("E_PM25", &[json!("s")])]}}},
            ]}}})
}

fn defs(out: &Value) -> Vec<(String, Value)> {
    out["models"]["Binned"]["equations"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|e| e["lhs"].as_str().map(|l| (l.to_string(), e["rhs"].clone())))
        .collect()
}

fn def_of(out: &Value, name: &str) -> Value {
    defs(out)
        .into_iter()
        .find(|(l, _)| l == name)
        .unwrap_or_else(|| panic!("no definition for {name}"))
        .1
}

/// Every `index(F, …)` base name reachable from `node`.
fn bases(node: &Value, out: &mut BTreeSet<String>) {
    match node {
        Value::Object(o) => {
            if o.get("op").and_then(Value::as_str) == Some("index")
                && let Some(a) = o.get("args").and_then(Value::as_array)
                && let Some(f) = a.first().and_then(Value::as_str)
            {
                out.insert(f.to_string());
            }
            for v in o.values() {
                bases(v, out);
            }
        }
        Value::Array(xs) => xs.iter().for_each(|x| bases(x, out)),
        _ => {}
    }
}

fn find_pia(node: &Value, out: &mut Vec<Value>) {
    match node {
        Value::Object(o) => {
            if o.get("op").and_then(Value::as_str) == Some("polygon_intersection_area") {
                out.push(node.clone());
            }
            for v in o.values() {
                find_pia(v, out);
            }
        }
        Value::Array(xs) => xs.iter().for_each(|x| find_pia(x, out)),
        _ => {}
    }
}

#[test]
fn every_cell_axis_array_is_gathered_rank_preserving() {
    let d = doc();
    let out = desugar_pushdown(&d, Some("Binned")).expect("rewrite");
    let vars = out["models"]["Binned"]["variables"].as_object().unwrap();
    let gathers: BTreeSet<&str> = vars
        .keys()
        .filter(|k| k.starts_with("pd_cell__"))
        .map(String::as_str)
        .collect();
    assert_eq!(
        gathers,
        BTreeSet::from([
            "pd_cell__src_cells__cell_area",
            "pd_cell__src_cells__cell_ring",
            "pd_cell__src_cells__src_E",
            "pd_cell__src_cells__src_N",
            "pd_cell__src_cells__src_S",
            "pd_cell__src_cells__src_W",
        ])
    );

    // RANK-PRESERVING: only the FIRST axis moves onto the derived set.
    assert_eq!(
        vars["pd_cell__src_cells__cell_ring"]["shape"],
        json!(["pd_support__src_cells", "ring_vertex", "xy"])
    );
    assert_eq!(
        vars["pd_cell__src_cells__cell_area"]["shape"],
        json!(["pd_support__src_cells"])
    );

    let ring_def = def_of(&out, "pd_cell__src_cells__cell_ring");
    // A MAP, not a reduction: every range is an output index.
    assert_eq!(ring_def["output_idx"], json!(["c", "pd_t0", "pd_t1"]));
    assert_eq!(ring_def["ranges"]["pd_t0"]["from"], json!("ring_vertex"));
    assert_eq!(ring_def["ranges"]["pd_t1"]["from"], json!("xy"));
    assert_eq!(ring_def["ranges"].as_object().unwrap().len(), 3);
    let ea = ring_def["expr"]["args"].as_array().unwrap();
    assert_eq!(ea[0], json!("cell_ring"));
    assert_eq!(ea[2], json!("pd_t0"));
    assert_eq!(ea[3], json!("pd_t1"));
    // The rank-1 arm is byte-identical to what it always emitted.
    assert_eq!(
        def_of(&out, "pd_cell__src_cells__src_W")["output_idx"],
        json!(["c"])
    );
}

#[test]
fn body_reads_are_repointed_onto_the_gathers() {
    let d = doc();
    let out = desugar_pushdown(&d, Some("Binned")).expect("rewrite");
    let body = def_of(&out, "E_PM25");
    assert_eq!(body["ranges"]["c"]["from"], json!("pd_support__src_cells"));

    let mut b = BTreeSet::new();
    bases(&body, &mut b);
    // NOTHING in the rewritten body still reads a full-grid cell-axis array.
    for stale in ["cell_ring", "cell_area", "src_W", "src_S", "src_E", "src_N"] {
        assert!(!b.contains(stale), "stale full-grid read of {stale}");
    }
    assert!(b.contains("pd_cell__src_cells__cell_ring"));
    assert!(b.contains("pd_cell__src_cells__cell_area"));

    // The polygon operand keeps its SLICED spelling: the base name changed and
    // nothing else did, which is what rank preservation buys.
    let mut pia = Vec::new();
    find_pia(&body, &mut pia);
    assert_eq!(pia.len(), 1);
    assert_eq!(
        pia[0]["args"][0],
        ix("pd_cell__src_cells__cell_ring", &[json!("c")])
    );
    assert_eq!(pia[0]["args"][1], ix("rec_ring", &[json!("r")]));
}

#[test]
fn computed_cell_position_is_refused_loudly() {
    // A cell-axis array read at `c + 1` cannot be re-pointed: the compact axis
    // is a renumbering and no arithmetic on a support position survives it. A
    // hard error naming the array and the subscript — declining silently would
    // hide an ungated fetch, and emitting anyway would be wrong numbers.
    let mut d = doc();
    d["models"]["Binned"]["equations"][0]["rhs"]["expr"]["args"][1]["args"][1]["args"][1] =
        ix("cell_area", &[json!({"op": "+", "args": ["c", 1]})]);
    let Err(err) = desugar_pushdown(&d, Some("Binned")) else {
        panic!("a computed cell position must be refused");
    };
    let msg = err.to_string();
    assert!(msg.contains("cell_area"), "{msg}");
    assert!(msg.contains("+(c, 1)"), "{msg}");
    assert!(msg.contains("COMPUTED cell position"), "{msg}");
}

#[test]
fn an_array_off_the_cell_axis_is_left_alone() {
    // A flat-offset gather into ANOTHER axis is not on the cell axis: it stays
    // full-grid, and it is still correct after the rewrite because nothing about
    // it moved. Gathering it would be the bug in the other direction.
    let mut d = doc();
    d["index_sets"]["all_cells"] = json!({"kind": "interval", "size": 8});
    d["models"]["Binned"]["variables"]["temperature"] = param(&["all_cells"]);
    let rhs = &mut d["models"]["Binned"]["equations"][0]["rhs"];
    rhs["args"].as_array_mut().unwrap().push(json!("temperature"));
    let prev = rhs["expr"].clone();
    rhs["expr"] = json!({"op": "*", "args": [
        prev, ix("temperature", &[json!({"op": "+", "args": ["c", 4]})])]});

    let out = desugar_pushdown(&d, Some("Binned")).expect("rewrite");
    assert!(
        out["models"]["Binned"]["variables"]
            .get("pd_cell__src_cells__temperature")
            .is_none()
    );
    let mut b = BTreeSet::new();
    bases(&def_of(&out, "E_PM25"), &mut b);
    assert!(b.contains("temperature"));
}

// --------------------------------------------------------------------------- //
// Numerics — the reason any of this matters
// --------------------------------------------------------------------------- //

/// A 2x2 grid of unit cells over [0,2]^2.
const W: [f64; 4] = [0.0, 1.0, 0.0, 1.0];
const S: [f64; 4] = [0.0, 0.0, 1.0, 1.0];
const E: [f64; 4] = [1.0, 2.0, 1.0, 2.0];
const N: [f64; 4] = [1.0, 1.0, 2.0, 2.0];
/// Record 0 straddles cells 0 and 1; record 1 sits inside cell 3; record 2 is
/// off the grid, so it contributes to no cell and joins no support member.
const RECS: [[f64; 4]; 3] = [
    [0.5, 0.25, 1.5, 0.75],
    [1.2, 1.2, 1.8, 1.8],
    [5.0, 5.0, 6.0, 6.0],
];
const EMIS: [f64; 3] = [10.0, 4.0, 7.0];
/// Cells 0 and 1 each take a quarter of record 0's 0.5 area; cell 3 takes all
/// of record 1's 0.36; cell 2 is met by nothing.
const EXPECT_E: [f64; 4] = [2.5, 2.5, 0.0, 1.44];

fn ring_rows(x0: f64, y0: f64, x1: f64, y1: f64) -> [[f64; 2]; 5] {
    [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]
}

fn stack_rings(rows: &[[[f64; 2]; 5]]) -> ArrayD<f64> {
    let mut a = ArrayD::zeros(IxDyn(&[rows.len(), 5, 2]));
    for (i, r) in rows.iter().enumerate() {
        for (v, xy) in r.iter().enumerate() {
            a[[i, v, 0]] = xy[0];
            a[[i, v, 1]] = xy[1];
        }
    }
    a
}

fn arr1(v: &[f64]) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
}

fn const_arrays() -> HashMap<String, ArrayD<f64>> {
    let cell_rings: Vec<_> = (0..4).map(|c| ring_rows(W[c], S[c], E[c], N[c])).collect();
    let rec_rings: Vec<_> = RECS
        .iter()
        .map(|r| ring_rows(r[0], r[1], r[2], r[3]))
        .collect();
    let mut sr = ArrayD::zeros(IxDyn(&[4, 2]));
    for (c, row) in [[1.0, 0.5], [2.0, 0.25], [3.0, 0.125], [4.0, 0.0625]]
        .iter()
        .enumerate()
    {
        sr[[c, 0]] = row[0];
        sr[[c, 1]] = row[1];
    }
    [
        ("src_W".to_string(), arr1(&W)),
        ("src_S".to_string(), arr1(&S)),
        ("src_E".to_string(), arr1(&E)),
        ("src_N".to_string(), arr1(&N)),
        ("cell_area".to_string(), arr1(&[1.0; 4])),
        ("cell_ring".to_string(), stack_rings(&cell_rings)),
        ("rec_ring".to_string(), stack_rings(&rec_rings)),
        ("rec_xmin".to_string(), arr1(&RECS.map(|r| r[0]))),
        ("rec_ymin".to_string(), arr1(&RECS.map(|r| r[1]))),
        ("rec_xmax".to_string(), arr1(&RECS.map(|r| r[2]))),
        ("rec_ymax".to_string(), arr1(&RECS.map(|r| r[3]))),
        ("emis_annual".to_string(), arr1(&EMIS)),
        ("SR_PM25".to_string(), sr),
    ]
    .into_iter()
    .collect()
}

/// A pushdown-capable provider: it records whether the engine asked for a
/// selection or took the whole array.
struct MockGated {
    full: ArrayD<f64>,
    calls: Rc<RefCell<Vec<Option<Vec<AxisSel>>>>>,
}

impl PrepareProvider for MockGated {
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
        self.calls.borrow_mut().push(None);
        Ok(self.full.clone())
    }

    fn supports_selection(&self) -> bool {
        true
    }

    fn sample_with_selection(
        &mut self,
        selection: &[AxisSel],
    ) -> Result<ArrayD<f64>, PrepareError> {
        self.calls.borrow_mut().push(Some(selection.to_vec()));
        let mut arr = self.full.clone();
        for (i, ax) in selection.iter().enumerate() {
            if let AxisSel::Indices(idx) = ax {
                arr = arr.select(ndarray::Axis(i), idx);
            }
        }
        Ok(arr)
    }
}

#[test]
fn rewritten_polygon_allocation_matches_the_dense_evaluation() {
    // The DENSE arm, checked against a hand oracle first, so a shared bug in
    // both arms cannot pass this test by agreeing with itself.
    let dense = prepare(
        &doc(),
        const_arrays(),
        Vec::new(),
        &PrepareOptions {
            model_name: Some("Binned".into()),
            ..Default::default()
        },
    )
    .expect("dense prepare");
    let e_dense = dense.observed_field("E_PM25").unwrap().clone();
    let conc_dense = dense.observed_field("conc_PM25").unwrap().clone();
    for (got, want) in e_dense.iter().zip(EXPECT_E.iter()) {
        assert!((got - want).abs() < 1e-12, "{e_dense:?} != {EXPECT_E:?}");
    }

    // The REWRITTEN arm: the ring stack rides the compact axis with the bounds,
    // and SR arrives GATED so its rows land in the same compact index space.
    let mut ca = const_arrays();
    let sr = ca.remove("SR_PM25").unwrap();
    let calls = Rc::new(RefCell::new(Vec::new()));
    let providers: Vec<(String, Box<dyn PrepareProvider>)> = vec![(
        "Binned.SR_PM25".into(),
        Box::new(MockGated {
            full: sr,
            calls: calls.clone(),
        }),
    )];
    let push = prepare(
        &doc(),
        ca,
        providers,
        &PrepareOptions {
            model_name: Some("Binned".into()),
            pushdown_rewrite: true,
            ..Default::default()
        },
    )
    .expect("pushdown prepare");
    let members = &push.members["pd_faq__src_cells"];
    assert_eq!(members, &vec![1, 2, 4]); // 1-based; cell 3 is met by nothing

    let e_push = push.observed_field("E_PM25").unwrap();
    assert_eq!(e_push.len(), members.len());
    for (i, m) in members.iter().enumerate() {
        let want = EXPECT_E[(*m - 1) as usize];
        assert!(
            (e_push[[i]] - want).abs() < 1e-12,
            "support {i} (cell {m}): {} != {want}",
            e_push[[i]]
        );
    }
    // `conc` is on the full receptor axis either way, so it compares exactly.
    let conc_push = push.observed_field("conc_PM25").unwrap();
    for (got, want) in conc_push.iter().zip(conc_dense.iter()) {
        assert!((got - want).abs() < 1e-12, "{conc_push:?} != {conc_dense:?}");
    }

    // And the gate did its job: the SR rows were selected, not taken wholesale.
    let log = calls.borrow();
    assert!(log.iter().all(Option::is_some), "SR was fetched wholesale");
    assert_eq!(log.len(), 1);
    assert_eq!(log[0].as_ref().unwrap()[0], AxisSel::Indices(vec![0, 1, 3]));
}
