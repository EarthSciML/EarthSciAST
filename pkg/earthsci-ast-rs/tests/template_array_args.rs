//! esm-spec §9.6.11: an expression template applied with an array bound to a
//! scalar-role parameter is evaluated elementwise. The nine single-model cases
//! run as the `template_array_args` inline-test conformance tier; this pins the
//! coupled case — parameters the component declares scalar, fed grid arrays by
//! `variable_map` — bit for bit against the `interp.*` form, under both
//! compilers, the refusals (arrays over unrelated index sets, an anonymous
//! array argument), and what is not lifted: a template whose operands its body
//! takes whole, and a shaped read written by hand.
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
    rhs_of(&load_path(path).expect("load"), compiler)
}

fn rhs_of(file: &earthsci_ast::EsmFile, compiler: Compiler) -> Vec<(String, f64)> {
    let opts = ProblemOptions {
        compiler: Some(compiler),
        ..Default::default()
    };
    let prob = esm_problem(file, (0.0, 1.0), opts).expect("esm_problem");
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

/// The coupled case's flattened system keeps its meaning on the wire
/// (esm-spec §9.6.11, "A flattened system keeps its applications' meaning on
/// the wire"). This binding expands templates at load, and the mark that makes
/// an expansion an application is not serialized; unlifted, the flattened
/// `linear` and `bilinear` expansions read `Grid.levc` and the other coupled
/// grid fields by bare name inside their bracket counts, and the written-out
/// document is refused with `faq_bare_array_operand`. Flatten writes the lift,
/// so the read-back document builds, bit for bit the `fn` form.
#[test]
fn the_flattened_coupled_case_written_out_and_read_back_matches_the_fn_form() {
    let file = load_path(fixture("template.esm")).expect("load");
    let flat = earthsci_ast::flatten(&file).expect("flatten");
    let text = crate::flatten_wire_conformance::flattened_document(&flat).to_string();
    assert!(
        !text.contains("apply_expression_template"),
        "the flattened system holds expansions"
    );
    let read_back = load_string(&text).expect("load the written-out flattened system");
    for compiler in [Compiler::Interpreter, Compiler::Native] {
        let reference = rhs_at_u0(&fixture("fn.esm"), compiler);
        let written = rhs_of(&read_back, compiler);
        assert_eq!(reference.len(), 48);
        assert_eq!(reference.len(), written.len());
        for ((rn, rv), (wn, wv)) in reference.iter().zip(&written) {
            assert_eq!(rn, wn);
            assert_eq!(
                rv.to_bits(),
                wv.to_bits(),
                "{rn} under {compiler:?}: {rv} vs {wv}"
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

/// A one-model document over index sets `c`, `verts` and `coord`; `extra`
/// is spliced into the model object.
fn model_doc(variables: &str, equations: &str, extra: &str) -> String {
    format!(
        r#"{{"esm": "1.2.0", "metadata": {{"name": "taa_probe"}},
          "index_sets": {{"c": {{"kind": "interval", "size": 3}},
                         "verts": {{"kind": "interval", "size": 4}},
                         "coord": {{"kind": "interval", "size": 2}}}},
          "models": {{"M": {{"variables": {variables}, "equations": {equations}{extra}}}}}}}"#
    )
}

fn problem(doc: &str, compiler: Compiler) -> Result<earthsci_ast::EsmProblem, String> {
    let file = load_string(doc).expect("load");
    let opts = ProblemOptions {
        compiler: Some(compiler),
        ..Default::default()
    };
    esm_problem(&file, (0.0, 1.0), opts).map_err(|e| e.to_string())
}

#[test]
fn an_anonymous_array_argument_is_refused() {
    let doc = model_doc(
        r#"{"y": {"type": "unknown"}, "s": {"type": "unknown", "default": 0.0}}"#,
        r#"[{"lhs": "y", "rhs": {"op": "apply_expression_template", "args": [], "name": "linear",
              "bindings": {"table": {"op": "const", "args": [], "value": [1.0, 2.0, 4.0]},
                           "axis": {"op": "const", "args": [], "value": [0.0, 1.0, 2.0]},
                           "x": {"op": "const", "args": [], "value": [0.5, 1.5]}, "n": 3}}},
            {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 1.0}]"#,
        r#", "expression_template_imports": [{"ref": "esm:std/interp.esm", "only": ["linear"]}]"#,
    );
    for compiler in [Compiler::Interpreter, Compiler::Native] {
        let err = problem(&doc, compiler).expect_err("refused");
        assert!(err.contains("array_shape_mismatch: '"), "{err}");
        assert!(err.contains("anonymous array"), "{err}");
    }
}

#[test]
fn a_template_over_geometry_operands_is_not_lifted() {
    // Both rings are array-role (a geometry operator takes them whole), so
    // binding arrays to them is not an elementwise application: it builds and
    // gives the overlap area (`elementwise_lift`'s unit tests pin that the
    // equation is left as written).
    let doc = model_doc(
        r#"{"pa": {"type": "parameter", "shape": ["verts", "coord"],
                   "default": [[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0]]},
            "pb": {"type": "parameter", "shape": ["verts", "coord"],
                   "default": [[1.0, 1.0], [3.0, 1.0], [3.0, 3.0], [1.0, 3.0]]},
            "area": {"type": "unknown"}, "s": {"type": "unknown", "default": 0.0}}"#,
        r#"[{"lhs": "area", "rhs": {"op": "apply_expression_template", "args": [],
              "name": "overlap", "bindings": {"a": "pa", "b": "pb"}}},
            {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "area"}]"#,
        r#", "expression_templates": {"overlap": {"params": ["a", "b"],
              "body": {"op": "polygon_intersection_area", "manifold": "planar", "args": ["a", "b"]}}}"#,
    );
    for compiler in [Compiler::Interpreter, Compiler::Native] {
        let prob = problem(&doc, compiler).expect("builds");
        let prog = rhs_program(&prob).expect("rhs_program");
        let u = initial_state(&prob).expect("initial_state");
        let p = prog.parameter_vector(&HashMap::new()).expect("parameters");
        let mut ws = prog.new_workspace();
        let mut du = vec![0.0; prog.n_states()];
        prog.eval_into(&u, &[], &p, 0.0, &prog.default_forcing(), &mut du, &mut ws)
            .expect("eval");
        assert_eq!(du, vec![1.0], "{compiler:?}");
    }
}
