//! esm-spec §9.6.11: the build's elementwise lift of a template application
//! gathers every array operand of the lifted right-hand side, whatever the
//! order of the equations (issue #714).
//!
//! The documents are the issue's `col_template_obs.esm` and the files it
//! imports, written to a temporary directory at run time: a 0-D reaction
//! system `Mech` whose rate `Rates.k1` is lifted over `lev` by a pointwise
//! `variable_map` of the column temperature, composed with a column model
//! `Col` whose tendency is a component-local template and whose observed
//! `dA ~ D(A)` comes before the lifted rate's definition. The lifted `dA`
//! read `Rates.k1` by bare name, and the build refused it
//! (`faq_bare_array_operand`).
#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{
    Compiler, ProblemOptions, SolveOptions, esm_problem, load_path, run_inline_tests_with_base_dir,
};
use std::path::{Path, PathBuf};

/// `rates.esm`: the rate model the mechanism reads.
fn rates_document() -> serde_json::Value {
    let scalar = |units: &str, default: f64| serde_json::json!({"type": "parameter", "units": units, "default": default});
    serde_json::json!({
        "esm": "1.2.0",
        "metadata": {"name": "Rates", "authors": ["probe"]},
        "models": {"Rates": {
            "variables": {
                "T": scalar("K", 300.0),
                "c_b": scalar("1", 0.0),
                "k1": {"type": "unknown", "units": "1/s"},
                "k2": {"type": "unknown", "units": "1/s"}
            },
            "equations": [
                {"lhs": "k1", "rhs": {"op": "*", "args": [0.001,
                    {"op": "/", "args": ["T", 300.0]}]}},
                {"lhs": "k2", "rhs": {"op": "*", "args": [0.01, "c_b"]}}
            ]
        }}
    })
}

/// `chem.esm`: the 0-D mechanism, and a model that reads its tendencies.
fn chem_document() -> serde_json::Value {
    serde_json::json!({
        "esm": "1.2.0",
        "metadata": {"name": "Chem", "authors": ["probe"]},
        "models": {
            "Rates": {"ref": "./rates.esm"},
            "Tend": {
                "variables": {
                    "dA_dt": {"type": "unknown", "units": "1/s"},
                    "dB_dt": {"type": "unknown", "units": "1/s"}
                },
                "equations": [
                    {"lhs": "dA_dt", "rhs": {"op": "D", "args": ["Mech.A"], "wrt": "t"}},
                    {"lhs": "dB_dt", "rhs": {"op": "D", "args": ["Mech.B"], "wrt": "t"}}
                ]
            }
        },
        "reaction_systems": {"Mech": {
            "species": {
                "A": {"units": "1", "default": 1.0},
                "B": {"units": "1", "default": 0.5}
            },
            "parameters": {},
            "reactions": [
                {"id": "R1", "substrates": [{"species": "A", "stoichiometry": 1}],
                 "products": [{"species": "B", "stoichiometry": 1}], "rate": "Rates.k1"},
                {"id": "R2", "substrates": [{"species": "B", "stoichiometry": 1}],
                 "products": null, "rate": "Rates.k2"}
            ]
        }},
        "coupling": [{"type": "coupling_import", "ref": "./looplib.esm",
                      "bind": {"Mech": "Mech", "Rates": "Rates"}}]
    })
}

/// `looplib.esm`: the coupling library that feeds `Mech.B` to the rates.
fn looplib_document() -> serde_json::Value {
    serde_json::json!({
        "esm": "1.2.0",
        "metadata": {"name": "LoopLib", "description": "probe"},
        "coupling_roles": {"Mech": {"description": "m"}, "Rates": {"description": "r"}},
        "coupling": [{"type": "variable_map", "from": "Mech.B", "to": "Rates.c_b",
                      "transform": "param_to_var"}]
    })
}

/// The four documents in a fresh directory; the path of the column document.
fn write_documents(dir: &Path) -> PathBuf {
    for (name, doc) in [
        ("rates.esm", rates_document()),
        ("chem.esm", chem_document()),
        ("looplib.esm", looplib_document()),
        ("col_template_obs.esm", column_document()),
    ] {
        std::fs::write(dir.join(name), doc.to_string()).expect("write");
    }
    dir.join("col_template_obs.esm")
}

/// `col_template_obs.esm`: the column, composed with the mechanism.
fn column_document() -> serde_json::Value {
    let lev = |v: [f64; 3]| serde_json::json!(v);
    let column = |units: &str, ty: &str, default: Option<f64>| {
        let mut v = serde_json::json!({"type": ty, "units": units, "shape": ["lev"]});
        if let Some(d) = default {
            v["default"] = serde_json::json!(d);
        }
        v
    };
    let assertion = |k: usize, expected: f64| {
        serde_json::json!({"variable": format!("Col.dA[{k}]"), "time": 0.0,
            "expected": expected, "tolerance": {"abs": 1e-15, "rel": 0.0}})
    };
    serde_json::json!({
        "esm": "1.2.0",
        "metadata": {"name": "Col", "authors": ["probe"]},
        "index_sets": {"lev": {"kind": "interval", "size": 3}},
        "models": {
            "Rates": {"ref": "./rates.esm"},
            "Tend": {"ref": "./chem.esm", "model": "Tend"},
            "Col": {
                "variables": {
                    "T": column("K", "parameter", Some(300.0)),
                    "src": column("1/s", "parameter", Some(0.0)),
                    "A0": column("1", "parameter", Some(1.0)),
                    "B0": column("1", "parameter", Some(0.5)),
                    "A": column("1", "unknown", None),
                    "B": column("1", "unknown", None),
                    "dA": column("1/s", "unknown", None)
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["A"], "wrt": "t"},
                     "rhs": {"op": "apply_expression_template", "args": [],
                             "name": "src_term", "bindings": {"s": "src"}}},
                    {"lhs": {"op": "D", "args": ["B"], "wrt": "t"}, "rhs": 0.0},
                    {"lhs": {"op": "ic", "args": ["A"]}, "rhs": "A0"},
                    {"lhs": {"op": "ic", "args": ["B"]}, "rhs": "B0"},
                    {"lhs": "dA", "rhs": {"op": "D", "args": ["A"], "wrt": "t"}}
                ],
                "expression_templates": {
                    "src_term": {"params": ["s"], "body": {"op": "*", "args": [1.0, "s"]}}
                },
                "tests": [{
                    "id": "lift",
                    "parameter_overrides": {
                        "Col.T": lev([300.0, 600.0, 150.0]),
                        "Col.src": lev([0.0001, 0.0, -0.0002]),
                        "Col.A0": lev([1.0, 2.0, 4.0]),
                        "Col.B0": lev([0.5, 0.1, 1.0])
                    },
                    "time_span": {"start": 0, "end": 0},
                    // dA = src - k1 A, with k1 = 0.001 T / 300 at each level.
                    "assertions": [
                        assertion(1, -0.0009),
                        assertion(2, -0.004),
                        assertion(3, -0.0022)
                    ]
                }]
            }
        },
        "reaction_systems": {"Mech": {"ref": "./chem.esm", "reaction_system": "Mech"}},
        "coupling": [
            {"type": "coupling_import", "ref": "./looplib.esm",
             "bind": {"Mech": "Mech", "Rates": "Rates"}},
            {"type": "variable_map", "from": "Col.T", "to": "Rates.T",
             "transform": "param_to_var", "lifting": "pointwise"},
            {"type": "operator_compose", "systems": ["Col", "Mech"],
             "translate": {"Col.A": "Mech.A", "Col.B": "Mech.B"}}
        ]
    })
}

#[test]
fn a_lifted_rate_defined_after_its_reader_is_gathered() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = write_documents(dir.path());
    let file = load_path(&path).expect("the document loads");
    let results =
        run_inline_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent());
    assert_eq!(results.len(), 3, "{results:?}");
    for r in &results {
        assert!(r.passed, "{}: {} ({:?})", r.variable, r.message, r.actual);
    }
}

#[test]
fn both_compilers_build_the_composed_column() {
    let dir = tempfile::tempdir().expect("tempdir");
    let file = load_path(write_documents(dir.path())).expect("the document loads");
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let opts = ProblemOptions {
            compiler: Some(compiler),
            ..Default::default()
        };
        if let Err(e) = esm_problem(&file, (0.0, 1.0), opts) {
            panic!("{compiler:?}: {e}");
        }
    }
}
