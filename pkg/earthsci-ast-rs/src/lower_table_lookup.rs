//! `table_lookup` → `interp.linear` / `interp.bilinear` / `index` lowering —
//! esm-spec §9.5.3.
//!
//! A `table_lookup` node is SUGAR. It names a `function_tables` entry plus one
//! input expression per declared axis, and §9.5.3 gives the exact §9.2
//! closed-function tree it stands for. Nothing downstream of the loader
//! evaluates `table_lookup` itself: the array interpreter's evaluable-core gate
//! refuses it with `unevaluable_operator`, naming "an earlier pipeline stage"
//! that — until this module — existed only inside the conformance harness
//! (`tests/function_tables_lowering.rs`). `esm validate` accepted such a
//! document and `esm test` could not evaluate a single assertion depending on
//! it (issue #188).
//!
//! **This runs at BUILD, not at load, and that is the point.** §9.5.4 makes
//! `function_tables` / `table_lookup` first-class AUTHORED constructs that must
//! survive a round trip, and this binding serializes the typed [`EsmFile`] it
//! loaded — so rewriting in `parse::load_value` would emit the lowered `fn`
//! form and break §9.5.4. §9.5.3 explicitly admits either an in-memory
//! transformation or a direct evaluator dispatch; lowering the typed document
//! on its way into a build satisfies the first while leaving the loaded image
//! (and therefore `emit`) authored-as-written.
//!
//! Bit-equivalence with the hand-written inline-`const` lookup (§9.5's central
//! promise) comes for free: the lowered tree drives the very same
//! [`crate::registered_functions`] `interp.linear` / `interp.bilinear`
//! implementations an author would have invoked by hand.
//!
//! **Not implemented:** `out_of_bounds: "error"`. The lowered `interp.*` form
//! clamps, which is the v0.4.0 required behavior (`"error"` is "conformant when
//! implemented", §9.5.1); a table declaring it is lowered to the clamping form
//! like every other.

use indexmap::IndexMap;
use serde_json::Value;

use crate::compile_error::CompileError;
use crate::types::{EsmFile, Expr, ExpressionNode, FunctionTable, FunctionTableAxis};

/// The op this pass consumes.
const TABLE_LOOKUP: &str = "table_lookup";

// esm-spec §9.5.5 diagnostic codes. Local `const`s rather than entries in
// `crate::diagnostic::codes`: that registry is the CROSS-BINDING vocabulary
// and its own docs require a code added there to be coordinated across all
// five bindings, which no other binding emits yet.
const UNKNOWN_TABLE: &str = "table_lookup_unknown_table";
const AXIS_NAME_MISMATCH: &str = "table_lookup_axis_name_mismatch";
const OUTPUT_OUT_OF_RANGE: &str = "table_lookup_output_out_of_range";
const INTERPOLATION_AXES_MISMATCH: &str = "table_interpolation_axes_mismatch";
const DATA_SHAPE_MISMATCH: &str = "table_data_shape_mismatch";
const AXIS_NAN: &str = "table_axis_nan";

fn err(code: &'static str, reason: impl Into<String>) -> CompileError {
    CompileError::TableLookupLowering {
        code,
        reason: reason.into(),
    }
}

/// Rewrite every `table_lookup` node in `file` to its §9.5.3 form, in place.
///
/// A no-op — not even a walk — for the overwhelmingly common document that
/// declares no `function_tables`, and idempotent: after one pass no
/// `table_lookup` node survives, so a second finds nothing to do. That matters
/// because [`crate::problem::esm_problem`] calls it on both the typed input it
/// was handed and the typed parse of a prepared raw document, and either (or
/// both) may already have been lowered.
pub(crate) fn lower_table_lookups(file: &mut EsmFile) -> Result<(), CompileError> {
    // Destructured rather than field-accessed so the tables stay READABLE
    // while the models and reaction systems are rewritten.
    let EsmFile {
        function_tables,
        models,
        reaction_systems,
        ..
    } = file;
    let Some(tables) = function_tables.as_ref().filter(|t| !t.is_empty()) else {
        return Ok(());
    };

    // `map_exprs_in_*` map with an infallible `FnMut(&Expr) -> Expr`, so the
    // first failure is captured in the closure and raised after the walk —
    // the same shape `ExpressionNode::try_for_each_child` uses. The offending
    // expression is left untouched; the error is returned, so nothing
    // downstream sees the half-lowered tree.
    let mut first_err: Option<CompileError> = None;
    let mut lower = |expr: &Expr| -> Expr {
        match lower_expr(expr, tables) {
            Ok(lowered) => lowered,
            Err(e) => {
                first_err.get_or_insert(e);
                expr.clone()
            }
        }
    };

    if let Some(models) = models.as_mut() {
        for model in models.values_mut() {
            *model = crate::substitute::map_exprs_in_model(model, &mut lower);
        }
    }
    if let Some(systems) = reaction_systems.as_mut() {
        for system in systems.values_mut() {
            *system = crate::substitute::map_exprs_in_reaction_system(system, &mut lower);
        }
    }

    match first_err {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// Whether `expr` carries a `table_lookup` anywhere. The guard that keeps a
/// document whose tables are used in one equation from having its entire AST
/// rebuilt (and re-interned) equation by equation.
fn has_table_lookup(expr: &Expr) -> bool {
    match expr {
        Expr::Operator(node) => {
            node.op == TABLE_LOOKUP || node.any_child(&mut |child| has_table_lookup(child))
        }
        _ => false,
    }
}

/// Lower `expr` bottom-up: children first, so a `table_lookup` nested inside
/// another node's axis input (or body, or filter, …) is already an `interp.*`
/// tree by the time its parent is rewritten.
fn lower_expr(expr: &Expr, tables: &IndexMap<String, FunctionTable>) -> Result<Expr, CompileError> {
    if !has_table_lookup(expr) {
        return Ok(expr.clone());
    }
    let Expr::Operator(node) = expr else {
        return Ok(expr.clone());
    };
    let mut first_err: Option<CompileError> = None;
    let rebuilt = node.map_children(&mut |child| match lower_expr(child, tables) {
        Ok(lowered) => lowered,
        Err(e) => {
            first_err.get_or_insert(e);
            child.clone()
        }
    });
    if let Some(e) = first_err {
        return Err(e);
    }
    if rebuilt.op != TABLE_LOOKUP {
        return Ok(Expr::operator(rebuilt));
    }
    lower_node(&rebuilt, tables)
}

/// The §9.5.3 lowering of one `table_lookup` node.
fn lower_node(
    node: &ExpressionNode,
    tables: &IndexMap<String, FunctionTable>,
) -> Result<Expr, CompileError> {
    let table_id = node.table.as_deref().ok_or_else(|| {
        err(
            UNKNOWN_TABLE,
            "a `table_lookup` node carries no `table` id (esm-spec §9.5.2)",
        )
    })?;
    let table = tables.get(table_id).ok_or_else(|| {
        err(
            UNKNOWN_TABLE,
            format!(
                "`table_lookup` references table `{table_id}`, which the document's \
                 `function_tables` block does not declare"
            ),
        )
    })?;
    let inputs = axis_inputs(node, table, table_id)?;
    let output = output_index(node, table, table_id)?;
    let data = output_slice(table, output, table_id)?;

    let kind = table.interpolation.as_deref().unwrap_or("linear");
    match (kind, table.axes.as_slice()) {
        ("linear", [x]) => Ok(closed_fn(
            "interp.linear",
            vec![
                const_expr(data.clone()),
                axis_const(x, table_id)?,
                inputs[0].clone(),
            ],
        )),
        ("bilinear", [x, y]) => Ok(closed_fn(
            "interp.bilinear",
            vec![
                const_expr(data.clone()),
                axis_const(x, table_id)?,
                axis_const(y, table_id)?,
                inputs[0].clone(),
                inputs[1].clone(),
            ],
        )),
        // `nearest` is an `index` of the table slice at the searchsorted
        // position, not an `interp` blend.
        ("nearest", [x]) => Ok(Expr::operator(ExpressionNode {
            op: "index".to_string(),
            args: vec![
                const_expr(data.clone()),
                closed_fn(
                    "interp.searchsorted",
                    vec![inputs[0].clone(), axis_const(x, table_id)?],
                ),
            ],
            ..Default::default()
        })),
        _ => Err(err(
            INTERPOLATION_AXES_MISMATCH,
            format!(
                "table `{table_id}` declares `interpolation: \"{kind}\"` over {} axes; \
                 `linear` and `nearest` require 1, `bilinear` requires 2 (esm-spec §9.5.1)",
                table.axes.len()
            ),
        )),
    }
}

/// The node's per-axis input expressions, in the table's DECLARED axis order
/// (which is the order `data`'s inner dimensions are in, and therefore the
/// argument order of `interp.bilinear`).
fn axis_inputs(
    node: &ExpressionNode,
    table: &FunctionTable,
    table_id: &str,
) -> Result<Vec<Expr>, CompileError> {
    if !node.args.is_empty() {
        return Err(err(
            AXIS_NAME_MISMATCH,
            format!(
                "`table_lookup` on table `{table_id}` carries {} positional `args`; the per-axis \
                 inputs live under `axes` and `args` MUST be empty (esm-spec §9.5.2)",
                node.args.len()
            ),
        ));
    }
    let axes = node.axes.as_ref();
    let supplied = axes.map_or(0, |a| a.len());
    let mut out = Vec::with_capacity(table.axes.len());
    for axis in &table.axes {
        let Some(input) = axes.and_then(|a| a.get(&axis.name)) else {
            return Err(err(
                AXIS_NAME_MISMATCH,
                format!(
                    "`table_lookup` on table `{table_id}` supplies no input for its declared \
                     axis `{}`",
                    axis.name
                ),
            ));
        };
        out.push(input.clone());
    }
    if supplied != table.axes.len() {
        let declared: Vec<&str> = table.axes.iter().map(|a| a.name.as_str()).collect();
        return Err(err(
            AXIS_NAME_MISMATCH,
            format!(
                "`table_lookup` on table `{table_id}` supplies {supplied} axis inputs but the \
                 table declares {} ({}); the key sets must match exactly (esm-spec §9.5.2)",
                declared.len(),
                declared.join(", ")
            ),
        ));
    }
    Ok(out)
}

/// Resolve `output` (absent, integer index, or name) to a 0-based row index
/// into `data`'s leading dimension.
fn output_index(
    node: &ExpressionNode,
    table: &FunctionTable,
    table_id: &str,
) -> Result<usize, CompileError> {
    let out_of_range = |detail: String| err(OUTPUT_OUT_OF_RANGE, detail);
    match (&node.output, table.outputs.as_deref()) {
        (None, _) => Ok(0),
        (Some(Value::Number(n)), outputs) => {
            let Some(i) = n.as_u64().map(|i| i as usize) else {
                return Err(out_of_range(format!(
                    "`table_lookup.output` on table `{table_id}` is {n}; an integer output index \
                     must be ≥ 0"
                )));
            };
            match outputs {
                Some(names) if i < names.len() => Ok(i),
                Some(names) => Err(out_of_range(format!(
                    "`table_lookup.output` {i} on table `{table_id}` is out of range: the table \
                     declares {} outputs",
                    names.len()
                ))),
                // No `outputs` list means the table is single-output and
                // `data` has no leading output dimension at all (§9.5.1), so
                // 0 is the only index that names anything.
                None if i == 0 => Ok(0),
                None => Err(out_of_range(format!(
                    "`table_lookup.output` {i} on table `{table_id}`, which declares no `outputs` \
                     and is therefore single-output"
                ))),
            }
        }
        (Some(Value::String(s)), Some(names)) => {
            names.iter().position(|name| name == s).ok_or_else(|| {
                out_of_range(format!(
                    "`table_lookup.output` \"{s}\" is not one of table `{table_id}`'s outputs \
                     ({})",
                    names.join(", ")
                ))
            })
        }
        (Some(Value::String(s)), None) => Err(out_of_range(format!(
            "`table_lookup.output` \"{s}\" names an output, but table `{table_id}` declares no \
             `outputs` list"
        ))),
        (Some(other), _) => Err(out_of_range(format!(
            "`table_lookup.output` on table `{table_id}` must be a non-negative integer or an \
             output name, not {other}"
        ))),
    }
}

/// The `data` sub-array the lowered `const` carries: row `output` of the
/// leading dimension for a multi-output table, and the whole literal for a
/// single-output one (which has no leading output dimension, §9.5.1).
fn output_slice<'a>(
    table: &'a FunctionTable,
    output: usize,
    table_id: &str,
) -> Result<&'a Value, CompileError> {
    if table.outputs.is_none() {
        return Ok(&table.data);
    }
    table
        .data
        .as_array()
        .and_then(|rows| rows.get(output))
        .ok_or_else(|| {
            err(
                DATA_SHAPE_MISMATCH,
                format!(
                    "table `{table_id}`: `data` has no row {output} for the selected output — its \
                     leading dimension must equal `len(outputs)` (esm-spec §9.5.1)"
                ),
            )
        })
}

/// `{"op": "const", "value": <axis values>}` for one declared axis.
fn axis_const(axis: &FunctionTableAxis, table_id: &str) -> Result<Expr, CompileError> {
    let values = serde_json::to_value(&axis.values).map_err(|_| {
        err(
            AXIS_NAN,
            format!(
                "table `{table_id}`: axis `{}` carries a non-finite value; axis `values` must be \
                 strictly-increasing FINITE floats (esm-spec §9.5.1)",
                axis.name
            ),
        )
    })?;
    Ok(const_expr(values))
}

fn const_expr(value: Value) -> Expr {
    Expr::operator(ExpressionNode {
        op: "const".to_string(),
        value: Some(value),
        ..Default::default()
    })
}

fn closed_fn(name: &str, args: Vec<Expr>) -> Expr {
    Expr::operator(ExpressionNode {
        op: "fn".to_string(),
        name: Some(name.to_string()),
        args,
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::load_string;

    /// A 1-axis linear table plus the `table_lookup` that reads it, and a
    /// sibling equation spelling the SAME lookup by hand.
    const FIXTURE: &str = r#"{
      "esm": "1.0.0",
      "metadata": { "name": "tl", "authors": ["test"] },
      "function_tables": {
        "t_prof": {
          "axes": [{"name": "p", "values": [1.0, 2.0, 3.0, 4.0]}],
          "interpolation": "linear",
          "data": [10.0, 20.0, 30.0, 40.0]
        }
      },
      "models": {
        "M": {
          "variables": {
            "y": {"type": "unknown", "default": 0.0},
            "p": {"type": "parameter", "default": 2.5}
          },
          "equations": [
            {"lhs": "y",
             "rhs": {"op": "table_lookup", "table": "t_prof", "axes": {"p": "p"}, "args": []}}
          ]
        }
      }
    }"#;

    fn rhs(file: &EsmFile) -> Expr {
        file.models.as_ref().unwrap()["M"].equations[0].rhs.clone()
    }

    #[test]
    fn lowers_a_one_axis_linear_lookup_to_the_spec_form() {
        let mut file = load_string(FIXTURE).expect("loads");
        lower_table_lookups(&mut file).expect("lowers");
        let expected = serde_json::json!({
            "op": "fn",
            "name": "interp.linear",
            "args": [
                {"op": "const", "args": [], "value": [10.0, 20.0, 30.0, 40.0]},
                {"op": "const", "args": [], "value": [1.0, 2.0, 3.0, 4.0]},
                "p"
            ]
        });
        assert_eq!(serde_json::to_value(rhs(&file)).unwrap(), expected);
    }

    /// The `tests/conformance/function_tables/bilinear` shape, inline: a
    /// multi-output 2-axis table read once by output NAME and once by INDEX.
    const BILINEAR: &str = r#"{
      "esm": "1.0.0",
      "metadata": { "name": "tl2", "authors": ["test"] },
      "function_tables": {
        "F_actinic": {
          "axes": [
            {"name": "P", "values": [10.0, 100.0, 1000.0]},
            {"name": "cos_sza", "values": [0.1, 0.5, 1.0]}
          ],
          "interpolation": "bilinear",
          "outputs": ["NO2", "O3", "HCHO"],
          "data": [
            [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]],
            [[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]],
            [[3.0, 3.5, 4.0], [3.1, 3.6, 4.1], [3.2, 3.7, 4.2]]
          ]
        }
      },
      "models": {
        "M": {
          "variables": {
            "j_NO2": {"type": "unknown", "default": 0.0},
            "j_O3": {"type": "unknown", "default": 0.0},
            "P_atm": {"type": "parameter", "default": 100.0},
            "cos_sza": {"type": "parameter", "default": 0.5}
          },
          "equations": [
            {"lhs": "j_NO2",
             "rhs": {"op": "table_lookup", "table": "F_actinic",
                     "axes": {"P": "P_atm", "cos_sza": "cos_sza"},
                     "output": "NO2", "args": []}},
            {"lhs": "j_O3",
             "rhs": {"op": "table_lookup", "table": "F_actinic",
                     "axes": {"P": "P_atm", "cos_sza": "cos_sza"},
                     "output": 1, "args": []}}
          ]
        }
      }
    }"#;

    /// The axis `const`s go in the table's DECLARED axis order (which is the
    /// order of `data`'s inner dimensions), the inputs follow in that same
    /// order, and `output` picks the row of `data`'s leading dimension —
    /// whether spelled as a name or as an index.
    #[test]
    fn lowers_a_multi_output_bilinear_lookup_to_the_spec_form() {
        let mut file = load_string(BILINEAR).expect("loads");
        lower_table_lookups(&mut file).expect("lowers");
        let eqs = &file.models.as_ref().unwrap()["M"].equations;

        let by_name = serde_json::to_value(eqs[0].rhs.clone()).unwrap();
        assert_eq!(by_name["op"], "fn");
        assert_eq!(by_name["name"], "interp.bilinear");
        assert_eq!(
            by_name["args"][0]["value"],
            serde_json::json!([[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]]),
            "output \"NO2\" is the first row"
        );
        assert_eq!(
            by_name["args"][1]["value"],
            serde_json::json!([10.0, 100.0, 1000.0])
        );
        assert_eq!(
            by_name["args"][2]["value"],
            serde_json::json!([0.1, 0.5, 1.0])
        );
        assert_eq!(by_name["args"][3], serde_json::json!("P_atm"));
        assert_eq!(by_name["args"][4], serde_json::json!("cos_sza"));

        let by_index = serde_json::to_value(eqs[1].rhs.clone()).unwrap();
        assert_eq!(
            by_index["args"][0]["value"],
            serde_json::json!([[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]]),
            "output 1 is the second row"
        );
    }

    #[test]
    fn an_out_of_range_output_is_a_named_diagnostic() {
        let source = BILINEAR.replace("\"output\": 1,", "\"output\": 7,");
        let mut file = load_string(&source).expect("loads");
        let e = lower_table_lookups(&mut file).expect_err("output out of range");
        assert!(
            e.to_string().starts_with(OUTPUT_OUT_OF_RANGE),
            "expected {OUTPUT_OUT_OF_RANGE}, got: {e}"
        );
    }

    #[test]
    fn lowering_is_idempotent() {
        let mut file = load_string(FIXTURE).expect("loads");
        lower_table_lookups(&mut file).expect("lowers");
        let once = rhs(&file);
        lower_table_lookups(&mut file).expect("lowers again");
        assert_eq!(once, rhs(&file));
    }

    #[test]
    fn an_unknown_table_is_a_named_diagnostic_not_a_panic() {
        let source = FIXTURE.replace("\"table\": \"t_prof\"", "\"table\": \"nope\"");
        let mut file = load_string(&source).expect("loads");
        let e = lower_table_lookups(&mut file).expect_err("unknown table");
        assert!(
            e.to_string().starts_with(UNKNOWN_TABLE),
            "expected {UNKNOWN_TABLE}, got: {e}"
        );
    }

    #[test]
    fn a_misnamed_axis_is_a_named_diagnostic() {
        let source = FIXTURE.replace("\"axes\": {\"p\": \"p\"}", "\"axes\": {\"q\": \"p\"}");
        let mut file = load_string(&source).expect("loads");
        let e = lower_table_lookups(&mut file).expect_err("axis mismatch");
        assert!(
            e.to_string().starts_with(AXIS_NAME_MISMATCH),
            "expected {AXIS_NAME_MISMATCH}, got: {e}"
        );
    }

    #[test]
    fn a_document_with_no_tables_is_left_alone() {
        let source = r#"{
          "esm": "1.0.0",
          "metadata": { "name": "plain", "authors": ["test"] },
          "models": { "M": {
            "variables": {"x": {"type": "unknown", "default": 1.0}},
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                           "rhs": {"op": "neg", "args": ["x"]}}]
          }}
        }"#;
        let mut file = load_string(source).expect("loads");
        let before = rhs(&file);
        lower_table_lookups(&mut file).expect("no-op");
        assert_eq!(before, rhs(&file));
    }
}
