//! An overlap-gated conservative regrid whose SOURCE FIELD is live forcing
//! (a DISCRETE provider, or a run-time array parameter), the twin of the Julia
//! binding's `overlap_gate_live_forcing_test.jl` (issue #657).
//!
//! With the source field build-time data the regrid materializes at setup. A
//! live field keeps the gated apply step — source field times overlap area,
//! summed per target cell — in the right-hand side, where `native` must read
//! the field at the contracted index `F[i]` from the forcing buffer at each
//! call. Native and the interpreter must agree bit for bit, and a second
//! forcing set must move the answer.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::provider::{CadenceProvider, NativeField, ProviderError};
use earthsci_ast::{Compiler, ProblemOptions, RhsProgram, esm_problem, rhs_program};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;

fn op(o: &str, args: Vec<Value>) -> Value {
    json!({"op": o, "args": args})
}
fn ix(f: &str, idx: &[&str]) -> Value {
    let mut a = vec![json!(f)];
    a.extend(idx.iter().map(|s| json!(s)));
    op("index", a)
}
fn faq(out: &[&str], ranges: &[(&str, &str)], expr: Value, extra: Value) -> Value {
    let mut r = serde_json::Map::new();
    for (k, v) in ranges {
        r.insert((*k).into(), json!({"from": v}));
    }
    let mut f = json!({
        "op": "faq", "semiring": "sum_product", "args": [],
        "output_idx": out, "ranges": r, "expr": expr
    });
    if let Value::Object(m) = extra {
        for (k, v) in m {
            f[k] = v;
        }
    }
    f
}

/// Source cells: unit squares at x ∈ [0,1], [1.5,2.5], [3,4] (a ring stack
/// built from the parameter `pitch`). Targets: [0,2] and [3.5,4.5]. Surviving
/// overlaps: (1,1) = 1, (2,1) = 0.5, (3,2) = 0.5, so
/// `F_tgt = [(F1 + 0.5 F2) / 1.5, F3]`. `fed` makes `F` data-fed; otherwise it
/// is a plain shaped parameter with an inline default.
fn document(fed: bool) -> Value {
    let gate =
        json!([{"overlap": {"src_env": ["src_poly"], "tgt_env": ["tgt_poly"], "eps": 1.0e-9}}]);
    let ij = [("i", "src_cells"), ("j", "tgt_cells")];
    let sliver = op(">", vec![ix("A_ij", &["i", "j"]), json!("atol")]);
    let ring = op(
        "ifelse",
        vec![
            op("<", vec![json!("k"), json!(2)]),
            op(
                "+",
                vec![
                    op(
                        "*",
                        vec![op("-", vec![json!("c"), json!(1)]), json!("pitch")],
                    ),
                    op(
                        "ifelse",
                        vec![
                            op("<", vec![json!("v"), json!(2)]),
                            json!(0.0),
                            op(
                                "ifelse",
                                vec![op("<", vec![json!("v"), json!(4)]), json!(1.0), json!(0.0)],
                            ),
                        ],
                    ),
                ],
            ),
            op(
                "ifelse",
                vec![op("<", vec![json!("v"), json!(3)]), json!(0.0), json!(1.0)],
            ),
        ],
    );
    let mut f = json!({"type": "parameter", "units": "1", "shape": ["src_cells"]});
    if fed {
        f["default"] = json!(1.0);
        f["update"] = json!({"kind": "data", "source": "Src", "from": {"file_variable": "F"}});
    } else {
        f["default"] = json!([1.0, 2.0, 3.0]);
    }
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "overlap_gate_live_forcing"},
        "index_sets": {
            "src_cells": {"kind": "interval", "size": 3},
            "tgt_cells": {"kind": "interval", "size": 2},
            "verts": {"kind": "interval", "size": 4},
            "coord": {"kind": "interval", "size": 2}
        },
        "data_sources": {"Src": {"kind": "static", "source": {"url_template": "{unused_placeholder}"}}},
        "models": {"M": {
            "variables": {
                "pitch": {"type": "parameter", "units": "1", "default": 1.5},
                "atol": {"type": "parameter", "units": "1", "default": 1.0e-12},
                "F": f,
                "src_poly": {"type": "unknown", "units": "1", "shape": ["src_cells", "verts", "coord"]},
                "tgt_poly": {"type": "unknown", "units": "1", "shape": ["tgt_cells", "verts", "coord"]},
                "A_ij": {"type": "unknown", "units": "1", "shape": ["src_cells", "tgt_cells"]},
                "A_j": {"type": "unknown", "units": "1", "shape": ["tgt_cells"]},
                "F_tgt": {"type": "unknown", "units": "1", "shape": ["tgt_cells"]},
                "u": {"type": "unknown", "units": "1", "shape": ["tgt_cells"], "default": 0.0}
            },
            "equations": [
                {"lhs": "src_poly", "rhs": faq(
                    &["c", "v", "k"], &[("c", "src_cells"), ("v", "verts"), ("k", "coord")], ring, json!({}))},
                {"lhs": "tgt_poly", "rhs": {"op": "const", "args": [],
                    "value": [[[0, 0], [2, 0], [2, 1], [0, 1]], [[3.5, 0], [4.5, 0], [4.5, 1], [3.5, 1]]]}},
                {"lhs": "A_ij", "rhs": faq(&["i", "j"], &ij, json!({
                    "op": "polygon_intersection_area", "manifold": "planar",
                    "args": [ix("src_poly", &["i"]), ix("tgt_poly", &["j"])]}), json!({"join": gate}))},
                {"lhs": "A_j", "rhs": faq(&["j"], &ij, ix("A_ij", &["i", "j"]),
                    json!({"join": gate, "filter": sliver}))},
                {"lhs": "F_tgt", "rhs": faq(&["j"], &ij,
                    op("/", vec![op("*", vec![ix("A_ij", &["i", "j"]), ix("F", &["i"])]), ix("A_j", &["j"])]),
                    json!({"join": gate, "filter": sliver}))},
                {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                 "rhs": faq(&["j"], &[("j", "tgt_cells")], ix("F_tgt", &["j"]), json!({}))}
            ]
        }}
    })
}

fn expected(f: &[f64]) -> Vec<f64> {
    vec![(f[0] + 0.5 * f[1]) / 1.5, f[2]]
}

/// A DISCRETE provider: one record, in effect from `t = 0`.
struct Discrete(Vec<f64>);

impl Discrete {
    fn sample(&self) -> HashMap<String, NativeField> {
        let a = ArrayD::from_shape_vec(IxDyn(&[3]), self.0.clone()).expect("field");
        HashMap::from([("F".to_string(), NativeField::new(a))])
    }
}

impl CadenceProvider for Discrete {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        Ok(self.sample())
    }
    fn refresh(&mut self, _t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        Ok(Some(self.sample()))
    }
    fn refresh_times(&self) -> Vec<f64> {
        vec![0.0]
    }
}

fn program(compiler: Compiler, fed: bool, f: &[f64]) -> RhsProgram {
    let mut opts = ProblemOptions {
        compiler: Some(compiler),
        ..Default::default()
    };
    if fed {
        opts.providers = HashMap::from([(
            "F".to_string(),
            Box::new(Discrete(f.to_vec())) as Box<dyn CadenceProvider>,
        )]);
    } else {
        opts.runtime_array_parameters = true;
    }
    let prob = esm_problem(&document(fed), (0.0, 1.0), opts)
        .unwrap_or_else(|e| panic!("{compiler} builds the live-source regrid: {e}"));
    rhs_program(&prob).unwrap_or_else(|e| panic!("{compiler}: program: {e}"))
}

/// `du` at the declared state, with `F` in the forcing set replaced by `f`.
fn rhs(prog: &RhsProgram, f: &[f64]) -> Vec<f64> {
    let slot = prog
        .forcing_slots()
        .iter()
        .position(|s| s.name.ends_with("F"))
        .expect("F is a forcing slot");
    let forcing = prog
        .default_forcing()
        .replace(slot, Arc::from(f.to_vec()))
        .expect("replace F");
    let (u, aux) = prog.default_state();
    let p = prog.parameter_vector(&HashMap::new()).expect("parameters");
    let mut du = vec![f64::NAN; u.len()];
    let mut ws = prog.new_workspace();
    prog.eval_into(&u, &aux, &p, 0.0, &forcing, &mut du, &mut ws)
        .expect("eval");
    du
}

fn bits(v: &[f64]) -> Vec<u64> {
    v.iter().map(|x| x.to_bits()).collect()
}

#[test]
fn a_gated_regrid_reads_a_live_source_field_under_native() {
    for fed in [true, false] {
        let f0 = [1.0, 2.0, 3.0];
        let native = program(Compiler::Native, fed, &f0);
        let interp = program(Compiler::Interpreter, fed, &f0);
        for f in [f0.to_vec(), vec![2.0, -4.0, 6.0]] {
            let got = rhs(&native, &f);
            let want = rhs(&interp, &f);
            assert_eq!(
                bits(&got),
                bits(&want),
                "fed={fed} F={f:?}: native vs interpreter"
            );
            let exp = expected(&f);
            for (g, e) in got.iter().zip(&exp) {
                assert!(
                    (g - e).abs() <= 1e-12 * e.abs().max(1.0),
                    "fed={fed} F={f:?}: {got:?} vs {exp:?}"
                );
            }
        }
    }
}
