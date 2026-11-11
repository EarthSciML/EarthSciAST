//! Issue #441: a `faq` `filter` that names a shaped variable by BARE name.
//!
//! With one output index the reference evaluator happened to apply it (the
//! array lined up with the output box by position); with two it kept every
//! term, so the filter was silently ignored. esm-spec §4.3.1 now refuses the
//! spelling (`faq_bare_array_operand`): `validate` on the authored document,
//! and the build on the template-EXPANDED one, under every compiler. The
//! per-cell filter gate, for an array no declaration gives a shape, faults
//! rather than include the cell.

#![cfg(all(not(target_arch = "wasm32"), feature = "solve"))]

use earthsci_ast::{
    Compiler, ProblemOptions, esm_problem, flatten, load_string, observed_field, validate,
};
use serde_json::{Value, json};

fn idx(v: &str, s: &str) -> Value {
    json!({"op": "index", "args": [v, s]})
}

fn gate(operand: Value) -> Value {
    json!({"op": "ifelse", "args": [{"op": ">", "args": [operand, 1.5]}, 1.0, 0.0]})
}

/// `a_val = [1, 2, 3]`, `c_val = [10, 20]`, and `y[i, g] = a_val[i] c_val[g]`
/// under `filter`. `a_shape` is `a_val`'s declared shape (`None` declares none).
fn doc(filter: Value, a_shape: Option<Value>, templates: Option<Value>) -> Value {
    let mut a_val = json!({"type": "unknown", "units": "1"});
    if let Some(shape) = a_shape {
        a_val["shape"] = shape;
    }
    let mut model = json!({
        "variables": {
            "a_val": a_val,
            "c_val": {"type": "unknown", "units": "1", "shape": ["c_rows"]},
            "y": {"type": "unknown", "units": "1", "shape": ["a_rows", "c_rows"]}
        },
        "equations": [
            {"lhs": "a_val", "rhs": {"op": "const", "args": [], "value": [1.0, 2.0, 3.0]}},
            {"lhs": "c_val", "rhs": {"op": "const", "args": [], "value": [10.0, 20.0]}},
            {"lhs": "y", "rhs": {
                "op": "faq", "args": [], "semiring": "sum_product",
                "output_idx": ["i", "g"],
                "ranges": {"i": {"from": "a_rows"}, "g": {"from": "c_rows"}},
                "filter": filter,
                "expr": {"op": "*", "args": [idx("a_val", "i"), idx("c_val", "g")]}
            }}
        ]
    });
    if let Some(t) = templates {
        model["expression_templates"] = t;
    }
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "issue441", "authors": ["test"]},
        "index_sets": {
            "a_rows": {"kind": "interval", "size": 3},
            "c_rows": {"kind": "interval", "size": 2}
        },
        "models": {"M": model}
    })
}

/// The field `y` under `compiler`, or the build/evaluation error.
fn y(doc: &Value, compiler: Compiler) -> Result<Vec<f64>, String> {
    let opts = ProblemOptions {
        compiler: Some(compiler),
        ..Default::default()
    };
    let prob = esm_problem(doc, (0.0, 0.0), opts).map_err(|e| e.to_string())?;
    let field = observed_field(&prob, "y")
        .or_else(|_| observed_field(&prob, "M.y"))
        .map_err(|e| e.to_string())?;
    Ok(field.iter().copied().collect())
}

const COMPILERS: [Compiler; 2] = [Compiler::Interpreter, Compiler::Native];

/// The positive control: `index(a_val, i)` excludes row 1 under both compilers.
#[test]
fn indexed_filter_over_two_outputs_applies() {
    let d = doc(gate(idx("a_val", "i")), Some(json!(["a_rows"])), None);
    for c in COMPILERS {
        let got = y(&d, c).unwrap_or_else(|e| panic!("{}: {e}", c.as_str()));
        assert_eq!(
            got,
            vec![0.0, 0.0, 20.0, 40.0, 30.0, 60.0],
            "{}",
            c.as_str()
        );
    }
}

/// The issue's repro: refused by name under both compilers, where the
/// interpreter used to return `[10, 20, 20, 40, 30, 60]`.
#[test]
fn bare_shaped_filter_is_refused_at_build() {
    let d = doc(gate(json!("a_val")), Some(json!(["a_rows"])), None);
    for c in COMPILERS {
        let err = y(&d, c).expect_err(c.as_str());
        assert!(
            err.contains("faq_bare_array_operand"),
            "{}: {err}",
            c.as_str()
        );
    }
}

/// The spelling the issue was found in: the bare name arrives through an
/// `apply_expression_template` binding, which `validate` cannot see into.
#[test]
fn bare_shaped_filter_through_a_template_is_refused_at_build() {
    let templates = json!({"gate": {"params": ["x"], "body": gate(json!("x"))}});
    let filter = json!({
        "op": "apply_expression_template", "args": [], "name": "gate",
        "bindings": {"x": "a_val"}
    });
    let d = doc(filter, Some(json!(["a_rows"])), Some(templates));
    for c in COMPILERS {
        let err = y(&d, c).expect_err(c.as_str());
        assert!(
            err.contains("faq_bare_array_operand"),
            "{}: {err}",
            c.as_str()
        );
    }
}

/// An array whose shape NO declaration states reaches the filter gate as a
/// rank-1 value against a two-index output box. It cannot be aligned, so it
/// must fail on every path rather than include every cell.
#[test]
fn undeclared_array_filter_of_the_wrong_rank_fails_closed() {
    let d = doc(gate(json!("a_val")), None, None);
    for c in COMPILERS {
        match y(&d, c) {
            Err(_) => {}
            Ok(v) => panic!(
                "{}: an unalignable array filter produced {v:?} instead of an error",
                c.as_str()
            ),
        }
    }
}

fn refused_everywhere(d: &Value) {
    for c in COMPILERS {
        let err = y(d, c).expect_err(c.as_str());
        assert!(
            err.contains("faq_bare_array_operand"),
            "{}: {err}",
            c.as_str()
        );
    }
}

/// `a_val` declares no shape; its defining `faq` over `a_rows` makes it an
/// array. `validate` reads declarations only and passes it; the build reads
/// inferred shapes, as Julia's and Python's builds do, and refuses the bare
/// read.
#[test]
fn bare_read_of_an_inferred_shape_is_refused_at_build() {
    let mut d = doc(gate(json!("a_val")), None, None);
    d["models"]["M"]["variables"]["base"] =
        json!({"type": "parameter", "units": "1", "shape": ["a_rows"], "default": [1.0, 2.0, 3.0]});
    d["models"]["M"]["equations"][0]["rhs"] = json!({
        "op": "faq", "args": [], "output_idx": ["i"],
        "ranges": {"i": {"from": "a_rows"}}, "expr": idx("base", "i")
    });
    let file = load_string(&d.to_string()).expect("loads");
    assert!(validate(&file).structural_errors.is_empty());
    refused_everywhere(&d);
}

/// The check runs on the model the build compiles, so an already-flattened
/// input is refused as a document is.
#[test]
fn bare_shaped_filter_in_a_flattened_input_is_refused() {
    let d = doc(gate(json!("a_val")), Some(json!(["a_rows"])), None);
    let flat = flatten(&load_string(&d.to_string()).expect("loads")).expect("flattens");
    for c in COMPILERS {
        let opts = ProblemOptions {
            compiler: Some(c),
            ..Default::default()
        };
        let err = esm_problem(&flat, (0.0, 0.0), opts)
            .map(|_| ())
            .expect_err(c.as_str())
            .to_string();
        assert!(
            err.contains("faq_bare_array_operand"),
            "{}: {err}",
            c.as_str()
        );
    }
}

/// A shaped variable of another model, read by its scoped name `Other.a_val`,
/// and a subsystem's equation, delivered bare through a template so that
/// `validate` passes them: both refused at build.
#[test]
fn cross_model_and_subsystem_bare_reads_are_refused_at_build() {
    let templates = json!({"gate": {"params": ["x"], "body": gate(json!("x"))}});
    let via = |x: &str| {
        json!({
            "op": "apply_expression_template", "args": [], "name": "gate",
            "bindings": {"x": x}
        })
    };

    // Cross-model: M's filter gates on Other.a_val.
    let mut d = doc(
        via("Other.a_val"),
        Some(json!(["a_rows"])),
        Some(templates.clone()),
    );
    d["models"]["Other"] = json!({
        "variables": {"a_val": {"type": "unknown", "units": "1", "shape": ["a_rows"]}},
        "equations": [{"lhs": "a_val", "rhs": {"op": "const", "args": [], "value": [1.0, 2.0, 3.0]}}]
    });
    let file = load_string(&d.to_string()).expect("loads");
    assert!(
        validate(&file)
            .structural_errors
            .iter()
            .all(|e| e.code.to_string() != "faq_bare_array_operand")
    );
    refused_everywhere(&d);

    // Subsystem: the whole of M mounted under Host.
    // A subsystem's applications expand against its top-level model's
    // registry, so the template is declared on Host.
    let inner = doc(via("a_val"), Some(json!(["a_rows"])), None);
    let mut d = inner.clone();
    d["models"] = json!({"Host": {
        "variables": {"z": {"type": "unknown", "units": "1"}},
        "equations": [{"lhs": "z", "rhs": 1.0}],
        "expression_templates": templates,
        "subsystems": {"M": inner["models"]["M"].clone()}
    }});
    let file = load_string(&d.to_string()).expect("loads");
    assert!(
        validate(&file)
            .structural_errors
            .iter()
            .all(|e| e.code.to_string() != "faq_bare_array_operand")
    );
    for c in COMPILERS {
        let opts = ProblemOptions {
            compiler: Some(c),
            ..Default::default()
        };
        let err = esm_problem(&d, (0.0, 0.0), opts)
            .and_then(|p| observed_field(&p, "Host.M.y").map(|_| ()))
            .expect_err(c.as_str())
            .to_string();
        assert!(
            err.contains("faq_bare_array_operand"),
            "{}: {err}",
            c.as_str()
        );
    }
}

/// `D(y) ~ faq(… twice(y) …)`: the template hides the bare state from
/// `validate`, and the build check does not exempt a derivative's own state.
#[test]
fn derivative_state_delivered_bare_by_a_template_is_refused_at_build() {
    let mut d: Value = serde_json::from_str(include_str!(
        "../../../tests/invalid/faq/bare_array_operand_derivative.esm"
    ))
    .unwrap();
    let model = &mut d["models"]["Probe"];
    model["equations"].as_array_mut().unwrap().truncate(1);
    model["variables"].as_object_mut().unwrap().remove("z");
    model["expression_templates"] =
        json!({"twice": {"params": ["x"], "body": {"op": "*", "args": [2.0, "x"]}}});
    model["equations"][0]["rhs"]["expr"]["args"][1] = json!({
        "op": "apply_expression_template", "args": [], "name": "twice",
        "bindings": {"x": "y"}
    });
    let file = load_string(&d.to_string()).expect("loads");
    assert!(validate(&file).structural_errors.is_empty());
    for c in COMPILERS {
        let opts = ProblemOptions {
            compiler: Some(c),
            ..Default::default()
        };
        let err = esm_problem(&d, (0.0, 1.0), opts)
            .map(|_| ())
            .expect_err(c.as_str())
            .to_string();
        assert!(
            err.contains("faq_bare_array_operand"),
            "{}: {err}",
            c.as_str()
        );
    }
}

/// A 0-D mechanism lifted pointwise onto a grid, whose loss coefficient a
/// `variable_map` feeds from `Grid.kk = 0.1 * rho`: `kk` declares no shape,
/// and is an array because `rho` is (esm-spec §4.3.4). The authored equations
/// read it elementwise and outside any `faq`; the pointwise lift (§10.5) is
/// what puts it inside one, so the lift reads it at the cell, as it reads a
/// declared array, and the build does not refuse what the lift wrote. The
/// flattened system, written out and read back, builds too.
#[test]
fn the_pointwise_lift_reads_an_inferred_array_at_the_cell() {
    use earthsci_ast::{initial_state, rhs_program};
    let d = json!({
        "esm": "1.3.0",
        "metadata": {"name": "lift_inferred_operand", "authors": ["test"]},
        "index_sets": {"cell": {"kind": "interval", "size": 4}},
        "models": {
            "Chem": {
                "variables": {
                    "c": {"type": "unknown", "units": "1", "default": 1.0},
                    "k": {"type": "parameter", "units": "1/s", "default": 0.5}
                },
                "equations": [{
                    "lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                    "rhs": {"op": "*", "args": [{"op": "-", "args": ["k"]}, "c"]}
                }]
            },
            "Grid": {
                "variables": {
                    "rho": {"type": "parameter", "units": "1/s", "shape": ["cell"],
                            "default": [1.0, 2.0, 3.0, 4.0]},
                    "kk": {"type": "unknown", "units": "1/s"}
                },
                "equations": [{"lhs": "kk", "rhs": {"op": "*", "args": [0.1, "rho"]}}]
            },
            "Dep": {
                "variables": {"kd": {"type": "parameter", "units": "1/s", "default": 0.0}},
                "equations": [{
                    "lhs": {"op": "D", "args": ["_var"], "wrt": "t"},
                    "rhs": {"op": "makearray", "args": [], "regions": [[[1, 4]]],
                        "values": [{"op": "faq", "args": [], "output_idx": ["i"],
                            "ranges": {"i": [1, 4]},
                            "expr": {"op": "*", "args": [
                                {"op": "-", "args": ["kd"]}, idx("_var", "i")]}}]}
                }]
            }
        },
        "coupling": [
            {"type": "operator_compose", "systems": ["Chem", "Dep"], "lifting": "pointwise"},
            {"type": "variable_map", "from": "Grid.kk", "to": "Chem.k", "transform": "param_to_var"}
        ]
    });
    let file = load_string(&d.to_string()).expect("loads");
    let flat = flatten(&file).expect("flattens");
    let rhs = serde_json::to_string(&flat.equations).unwrap();
    assert!(
        rhs.contains(r#"{"op":"index","args":["Grid.kk","i"]}"#),
        "the lift reads Grid.kk at the cell: {rhs}"
    );
    // The flattened system as a document: one model per component, every
    // reference fully qualified.
    let written = crate::flatten_wire_conformance::flattened_document(&flat);
    let read_back = load_string(&written.to_string()).expect("the written-out system loads");
    for input in [&file, &read_back] {
        for c in COMPILERS {
            let opts = ProblemOptions {
                compiler: Some(c),
                ..Default::default()
            };
            let prob = esm_problem(input, (0.0, 1.0), opts)
                .unwrap_or_else(|e| panic!("{}: {e}", c.as_str()));
            let prog = rhs_program(&prob).expect("rhs_program");
            let u = initial_state(&prob).expect("initial_state");
            let p = prog
                .parameter_vector(&std::collections::HashMap::new())
                .expect("parameters");
            let mut ws = prog.new_workspace();
            let mut du = vec![0.0; prog.n_states()];
            prog.eval_into(&u, &[], &p, 0.0, &prog.default_forcing(), &mut du, &mut ws)
                .expect("eval");
            let want: Vec<f64> = [1.0, 2.0, 3.0, 4.0].iter().map(|r| -(0.1 * r)).collect();
            assert_eq!(du, want, "{}", c.as_str());
        }
    }
}
