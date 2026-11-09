//! esm-spec §9.6.11: an expression template applied with an array bound to a
//! scalar-role parameter is evaluated elementwise. The nine single-model cases
//! run as the `template_array_args` inline-test conformance tier; this pins the
//! coupled case — parameters the component declares scalar, fed grid arrays by
//! `variable_map` — bit for bit against the `interp.*` form, under both
//! compilers, and the refusal of arrays over unrelated index sets.
#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{
    Compiler, ProblemOptions, esm_problem, initial_state, load_path, load_string, rhs_program,
};
use std::collections::HashMap;
use std::path::PathBuf;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/template_array_args/coupled")
        .join(name)
}

fn rhs_at_u0(path: &PathBuf, compiler: Compiler) -> Vec<(String, f64)> {
    let file = load_path(path).expect("load");
    let opts = ProblemOptions {
        compiler: Some(compiler),
        ..Default::default()
    };
    let prob = esm_problem(&file, (0.0, 1.0), opts).expect("esm_problem");
    let prog = rhs_program(&prob).expect("rhs_program");
    let u = initial_state(&prob).expect("initial_state");
    let p = prog.parameter_vector(&HashMap::new()).expect("parameters");
    let fs = prog.default_forcing();
    let mut ws = prog.new_workspace();
    let mut du = vec![0.0; prog.n_states()];
    prog.eval_into(&u, &[], &p, 0.0, &fs, &mut du, &mut ws)
        .expect("eval");
    let mut rows = Vec::new();
    for b in prog.state_layout() {
        let n: usize = b.shape.iter().product::<usize>().max(1);
        for k in 0..n {
            rows.push((format!("{}[{k}]", b.name), du[b.flat_offset + k]));
        }
    }
    rows.sort_by(|a, b| a.0.cmp(&b.0));
    rows
}

#[test]
fn coupled_scalar_parameters_fed_grid_arrays_match_the_fn_form() {
    for compiler in [Compiler::Interpreter, Compiler::Native] {
        let reference = rhs_at_u0(&fixture("fn.esm"), compiler);
        let template = rhs_at_u0(&fixture("template.esm"), compiler);
        assert_eq!(reference.len(), 48);
        assert_eq!(reference.len(), template.len());
        for ((rn, rv), (tn, tv)) in reference.iter().zip(&template) {
            assert_eq!(rn, tn);
            assert_eq!(
                rv.to_bits(),
                tv.to_bits(),
                "{rn} under {compiler:?}: {rv} vs {tv}"
            );
        }
    }
}

#[test]
fn arrays_over_unrelated_index_sets_are_refused() {
    let doc = r#"{"esm": "1.2.0", "metadata": {"name": "taa_mismatch"},
      "index_sets": {"a": {"kind": "interval", "size": 2}, "b": {"kind": "interval", "size": 3}},
      "models": {"M": {
        "expression_template_imports": [{"ref": "esm:std/interp.esm", "only": ["bilinear"]}],
        "variables": {
          "px": {"type": "parameter", "shape": ["a"], "default": [0.5, 1.5]},
          "py": {"type": "parameter", "shape": ["b"], "default": [10.0, 15.0, 20.0]},
          "B": {"type": "unknown"},
          "s": {"type": "unknown", "default": 0.0}},
        "equations": [
          {"lhs": "B", "rhs": {"op": "apply_expression_template", "args": [], "name": "bilinear",
            "bindings": {"table": {"op": "const", "args": [], "value": [[1.0, 2.0], [3.0, 4.0]]},
                         "axis_x": {"op": "const", "args": [], "value": [0.0, 2.0]},
                         "axis_y": {"op": "const", "args": [], "value": [10.0, 20.0]},
                         "x": "px", "y": "py", "nx": 2, "ny": 2}}},
          {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 1.0}]}}}"#;
    let file = load_string(doc).expect("load");
    for compiler in [Compiler::Interpreter, Compiler::Native] {
        let opts = ProblemOptions {
            compiler: Some(compiler),
            ..Default::default()
        };
        let err = esm_problem(&file, (0.0, 1.0), opts).expect_err("refused");
        assert!(err.to_string().contains("array_shape_mismatch"), "{err}");
    }
}
