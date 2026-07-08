//! Bit-equivalent table_lookup → interp.* lowering harness (esm-lhm).
//!
//! For each conformance fixture under `tests/conformance/function_tables/`,
//! load the file, walk the model equations, lower every `table_lookup` node
//! to the structurally-equivalent inline-`const` `interp.linear` /
//! `interp.bilinear` invocation prescribed by esm-spec §9.5.3, and assert
//! IEEE-754 `binary64` agreement with the equivalent hand-written
//! inline-`const` lookup at the §9.2 tolerance contract (`abs: 0, rel: 0`,
//! non-FMA reference path).
//!
//! The assertion is bit-equality: both arms drive the same
//! `interp.linear` / `interp.bilinear` evaluator. The harness catches
//! lowering-side mistakes (wrong output slice, swapped axis order, dropped
//! input expression) by computing the "expected" value from the raw
//! `function_tables` block independently of the parsed `table_lookup` node.

use std::path::PathBuf;

use earthsci_ast::registered_functions::{ClosedArg, ClosedValue, evaluate_closed_function};
use earthsci_ast::{EsmFile, Expr, ExpressionNode, load_path};
use serde_json::Value;

mod common;

fn fixtures_dir() -> PathBuf {
    common::repo_fixture("conformance/function_tables")
}

fn nested_to_1d(v: &Value) -> Vec<f64> {
    v.as_array()
        .expect("data slice is array")
        .iter()
        .map(|x| x.as_f64().expect("finite f64"))
        .collect()
}

fn nested_to_2d(v: &Value) -> Vec<Vec<f64>> {
    v.as_array()
        .expect("data slice is 2-D array")
        .iter()
        .map(nested_to_1d)
        .collect()
}

/// Resolve `table_lookup.output` to a 0-based row index into the leading
/// dimension of `data`, per esm-spec §9.5.2 / §9.5.3.
fn resolve_output_index(node: &ExpressionNode, outputs: Option<&[String]>) -> usize {
    match (&node.output, outputs) {
        (None, _) => 0,
        (Some(Value::Number(n)), _) => n.as_u64().expect("non-negative") as usize,
        (Some(Value::String(s)), Some(names)) => names
            .iter()
            .position(|x| x == s)
            .unwrap_or_else(|| panic!("output name {s:?} not in outputs list")),
        _ => panic!("table_lookup.output must be int or known string"),
    }
}

/// Resolve a per-axis input expression to a scalar value, given the model's
/// variables map (parameter / state defaults). Numeric literals pass through;
/// variable references look up `default`.
fn resolve_axis_value(
    expr: &Expr,
    vars: &std::collections::HashMap<String, earthsci_ast::ModelVariable>,
) -> f64 {
    match expr {
        Expr::Number(n) => *n,
        Expr::Integer(i) => *i as f64,
        Expr::Variable(name) => vars
            .get(name)
            .unwrap_or_else(|| panic!("axis input variable {name:?} not in model"))
            .default
            .expect("variable has default"),
        Expr::Operator(_) => {
            panic!("complex axis input expression not exercised by these fixtures")
        }
    }
}

fn evaluate_interp(name: &str, args: Vec<ClosedArg>) -> f64 {
    match evaluate_closed_function(name, &args).expect("evaluator success") {
        ClosedValue::Float(f) => f,
        ClosedValue::Integer(_) => panic!("{name} must return float"),
    }
}

/// Lower a parsed `table_lookup` node + its `function_tables` entry to the
/// inline-`const` interp.* invocation form prescribed by §9.5.3, evaluate it,
/// and return the scalar result.
fn lower_and_evaluate(
    node: &ExpressionNode,
    file: &EsmFile,
    model_vars: &std::collections::HashMap<String, earthsci_ast::ModelVariable>,
) -> f64 {
    assert_eq!(node.op, "table_lookup");
    assert!(node.args.is_empty(), "table_lookup.args MUST be empty");
    let table_id = node.table.as_deref().expect("table_lookup.table required");
    let tables = file
        .function_tables
        .as_ref()
        .expect("function_tables block present");
    let table = tables
        .get(table_id)
        .unwrap_or_else(|| panic!("unknown table {table_id:?}"));
    let axes_map = node.axes.as_ref().expect("table_lookup.axes required");

    let kind = table.interpolation.as_deref().unwrap_or("linear");
    let out_idx = resolve_output_index(node, table.outputs.as_deref());

    match (kind, table.axes.len()) {
        ("linear", 1) => {
            let axis = &table.axes[0];
            let data_slice: Vec<f64> = if table.outputs.is_some() {
                nested_to_1d(&table.data.as_array().expect("data array")[out_idx])
            } else {
                nested_to_1d(&table.data)
            };
            let x = resolve_axis_value(&axes_map[&axis.name], model_vars);
            evaluate_interp(
                "interp.linear",
                vec![
                    ClosedArg::Array(data_slice),
                    ClosedArg::Array(axis.values.clone()),
                    ClosedArg::Scalar(x),
                ],
            )
        }
        ("bilinear", 2) => {
            let ax = &table.axes[0];
            let ay = &table.axes[1];
            let data_slice: Vec<Vec<f64>> = if table.outputs.is_some() {
                nested_to_2d(&table.data.as_array().expect("data array")[out_idx])
            } else {
                nested_to_2d(&table.data)
            };
            let x = resolve_axis_value(&axes_map[&ax.name], model_vars);
            let y = resolve_axis_value(&axes_map[&ay.name], model_vars);
            evaluate_interp(
                "interp.bilinear",
                vec![
                    ClosedArg::Array2D(data_slice),
                    ClosedArg::Array(ax.values.clone()),
                    ClosedArg::Array(ay.values.clone()),
                    ClosedArg::Scalar(x),
                    ClosedArg::Scalar(y),
                ],
            )
        }
        (other, n) => panic!("unsupported lowering: interpolation={other} axes={n}"),
    }
}

/// Independent reference-path computation: the same result computed by reading
/// the §9.5.3 source-of-truth (the raw `function_tables` block + the variable
/// defaults), without going through the parsed `table_lookup` node. If the
/// lowering picks the wrong output slice, swaps axis order, or drops the
/// input expression, this value disagrees and the test fails.
fn reference_inline_const(
    table_id: &str,
    output: Option<&str>,
    output_idx_int: Option<usize>,
    axis_inputs: &[(&str, &str)],
    file: &EsmFile,
    model_vars: &std::collections::HashMap<String, earthsci_ast::ModelVariable>,
) -> f64 {
    let table = &file.function_tables.as_ref().unwrap()[table_id];
    let kind = table.interpolation.as_deref().unwrap_or("linear");
    let out_idx = match (output, output_idx_int, table.outputs.as_ref()) {
        (Some(name), _, Some(names)) => names.iter().position(|n| n == name).unwrap(),
        (None, Some(i), _) => i,
        (None, None, _) => 0,
        _ => panic!("ambiguous output spec"),
    };

    match (kind, table.axes.len()) {
        ("linear", 1) => {
            let axis = &table.axes[0];
            let data: Vec<f64> = if table.outputs.is_some() {
                nested_to_1d(&table.data.as_array().unwrap()[out_idx])
            } else {
                nested_to_1d(&table.data)
            };
            let (axis_name, var_name) = axis_inputs[0];
            assert_eq!(axis_name, axis.name);
            let x = model_vars[var_name].default.unwrap();
            evaluate_interp(
                "interp.linear",
                vec![
                    ClosedArg::Array(data),
                    ClosedArg::Array(axis.values.clone()),
                    ClosedArg::Scalar(x),
                ],
            )
        }
        ("bilinear", 2) => {
            let ax = &table.axes[0];
            let ay = &table.axes[1];
            let data: Vec<Vec<f64>> = if table.outputs.is_some() {
                nested_to_2d(&table.data.as_array().unwrap()[out_idx])
            } else {
                nested_to_2d(&table.data)
            };
            let (axn0, vn0) = axis_inputs[0];
            let (axn1, vn1) = axis_inputs[1];
            assert_eq!(axn0, ax.name);
            assert_eq!(axn1, ay.name);
            let x = model_vars[vn0].default.unwrap();
            let y = model_vars[vn1].default.unwrap();
            evaluate_interp(
                "interp.bilinear",
                vec![
                    ClosedArg::Array2D(data),
                    ClosedArg::Array(ax.values.clone()),
                    ClosedArg::Array(ay.values.clone()),
                    ClosedArg::Scalar(x),
                    ClosedArg::Scalar(y),
                ],
            )
        }
        (other, n) => panic!("unsupported reference: interpolation={other} axes={n}"),
    }
}

fn first_table_lookup<'a>(file: &'a EsmFile, model_id: &str, eq_idx: usize) -> &'a ExpressionNode {
    let model = &file.models.as_ref().unwrap()[model_id];
    match &model.equations[eq_idx].rhs {
        Expr::Operator(node) => node,
        other => panic!("expected Expr::Operator at eq {eq_idx}, got {other:?}"),
    }
}

#[test]
fn linear_fixture_lowering_is_bit_equivalent() {
    let path = fixtures_dir().join("linear").join("fixture.esm");
    let file: EsmFile = load_path(&path).expect("load linear fixture");
    let model = &file.models.as_ref().unwrap()["M"];
    let vars = &model.variables;

    let node = first_table_lookup(&file, "M", 0);
    let lowered = lower_and_evaluate(node, &file, vars);
    let reference = reference_inline_const(
        "sigma_O3_298",
        None,
        None,
        &[("lambda_idx", "lambda")],
        &file,
        vars,
    );

    // abs: 0, rel: 0 — both arms feed the same evaluator, so the lowering
    // is bit-equivalent to the inline-const reference by construction.
    assert_eq!(
        lowered.to_bits(),
        reference.to_bits(),
        "linear lowering bits diverged: lowered={lowered} reference={reference}"
    );

    // Sanity: x=4.5 lands in [4,5] with weight 0.5 → t[3] + 0.5*(t[4]-t[3])
    //                                              = 8.7e-18 + 0.5*(7.9e-18 - 8.7e-18)
    let expected = 8.7e-18f64 + 0.5_f64 * (7.9e-18_f64 - 8.7e-18_f64);
    assert_eq!(lowered.to_bits(), expected.to_bits());
}

#[test]
fn bilinear_fixture_lowering_is_bit_equivalent() {
    let path = fixtures_dir().join("bilinear").join("fixture.esm");
    let file: EsmFile = load_path(&path).expect("load bilinear fixture");
    let model = &file.models.as_ref().unwrap()["M"];
    let vars = &model.variables;

    // Equation 0: output by name "NO2" (index 0).
    let node0 = first_table_lookup(&file, "M", 0);
    let lowered0 = lower_and_evaluate(node0, &file, vars);
    let reference0 = reference_inline_const(
        "F_actinic",
        Some("NO2"),
        None,
        &[("P", "P_atm"), ("cos_sza", "cos_sza")],
        &file,
        vars,
    );
    assert_eq!(
        lowered0.to_bits(),
        reference0.to_bits(),
        "bilinear NO2 lowering bits diverged"
    );

    // Equation 1: output by integer index 1 ("O3").
    let node1 = first_table_lookup(&file, "M", 1);
    let lowered1 = lower_and_evaluate(node1, &file, vars);
    let reference1 = reference_inline_const(
        "F_actinic",
        None,
        Some(1),
        &[("P", "P_atm"), ("cos_sza", "cos_sza")],
        &file,
        vars,
    );
    assert_eq!(
        lowered1.to_bits(),
        reference1.to_bits(),
        "bilinear O3 lowering bits diverged"
    );

    // Sanity: at P=100, cos_sza=0.5 we sit on the (1,1) interior knot of
    // F_actinic, so wx=wy=0 and the result is the corner value.
    assert_eq!(lowered0, 1.6_f64); // NO2: data[0][1][1]
    assert_eq!(lowered1, 2.6_f64); // O3:  data[1][1][1]
}

#[test]
fn roundtrip_fixture_lowering_matches_inline_const_companion() {
    let path = fixtures_dir().join("roundtrip").join("fixture.esm");
    let file: EsmFile = load_path(&path).expect("load roundtrip fixture");
    let model = &file.models.as_ref().unwrap()["M"];
    let vars = &model.variables;

    // The fixture pairs a table_lookup (eq 0) with the equivalent inline-
    // const interp.linear call (eq 1). Both must evaluate bit-identically
    // on the same data and the same query point.
    let node = first_table_lookup(&file, "M", 0);
    let lowered = lower_and_evaluate(node, &file, vars);

    // Inline-const companion: walk eq 1's args, extract the const arrays
    // and the variable reference, evaluate via the same evaluator.
    let inline_node = match &model.equations[1].rhs {
        Expr::Operator(n) => n,
        other => panic!("eq 1 rhs must be fn-op, got {other:?}"),
    };
    assert_eq!(inline_node.op, "fn");
    assert_eq!(inline_node.name.as_deref(), Some("interp.linear"));
    let table_arg = match &inline_node.args[0] {
        Expr::Operator(c) => c.value.as_ref().expect("const-op carries value"),
        _ => panic!("arg 0 must be const-op"),
    };
    let axis_arg = match &inline_node.args[1] {
        Expr::Operator(c) => c.value.as_ref().expect("const-op carries value"),
        _ => panic!("arg 1 must be const-op"),
    };
    let x = resolve_axis_value(&inline_node.args[2], vars);
    let inline_val = evaluate_interp(
        "interp.linear",
        vec![
            ClosedArg::Array(nested_to_1d(table_arg)),
            ClosedArg::Array(nested_to_1d(axis_arg)),
            ClosedArg::Scalar(x),
        ],
    );

    assert_eq!(
        lowered.to_bits(),
        inline_val.to_bits(),
        "table_lookup lowering must match its inline-const companion bit-for-bit"
    );
}
