//! The esm-spec §9.2 closed-function argument checks, the §9.5.5 function
//! table checks and the `table_lookup` node checks, run at load and in
//! `validate()` (rulings Q-106, Q-112).
//!
//! All three are load-time rules: a document with a broken `function_tables`
//! entry, an `interp.*` call whose arguments break §9.2, or a `table_lookup`
//! node that names no table or binds the wrong axes or output, does not load —
//! whether or not anything references the table or evaluates the node. Every
//! table is checked before any expression node (ruling Q-113), so a document
//! with both is reported with the table's code. The rules themselves live with
//! the code that relies on them ([`crate::lower_table_lookup::validate_table`],
//! [`crate::lower_table_lookup::check_lookup`],
//! [`crate::registered_functions::check_closed_function_args`]); this module
//! only decides WHERE they run:
//!
//! * at load, on the raw document after the load-time rewrites (template
//!   expansion, enum lowering), so a `fn` node inside an expression-template
//!   body is checked where the template is applied, on the arguments the
//!   expansion gave it, and every expression-bearing field is reached without
//!   a list of them to keep current;
//! * in `validate()`, on a typed document, for one built or edited in
//!   memory that never went through load.
//!
//! The evaluators and the build repeat the checks where they read a table
//! (they MAY, esm-spec §9.2 / §9.5.5): a document built in memory can reach
//! them without passing through either entry point.

use std::collections::HashSet;

use indexmap::IndexMap;
use serde_json::Value;

use crate::json_visit::JsonPath;
use crate::registered_functions::{
    ClosedArgLiteral, check_closed_function_args, has_load_time_argument_checks,
};
use crate::types::{EsmFile, Expr, ExpressionNode, FunctionTable};
use crate::validate::{StructuralError, StructuralErrorCode};

/// A load-time finding: the diagnostic code, the JSON pointer of the table or
/// `fn` node, and the message.
pub(crate) struct Finding {
    pub(crate) code: String,
    pub(crate) path: String,
    pub(crate) message: String,
}

impl std::fmt::Display for Finding {
    /// `[code] message (at path)` — the `[code]` prefix every load-time
    /// diagnostic of this binding carries (as `enum_duplicate_value` does).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {} (at {})", self.code, self.message, self.path)
    }
}

/// A §9.5.5 table or lookup diagnostic as a [`Finding`] at `path`.
fn compile_finding(e: crate::compile_error::CompileError, path: String) -> Finding {
    match e {
        crate::compile_error::CompileError::TableLookupLowering { code, reason } => Finding {
            code: code.to_string(),
            path,
            message: reason,
        },
        other => Finding {
            code: String::new(),
            path,
            message: other.to_string(),
        },
    }
}

/// The ten esm-spec §9.5.5 checks on one table, as a [`Finding`].
fn check_table(table: &FunctionTable, id: &str) -> Result<(), Finding> {
    crate::lower_table_lookup::validate_table(table, id)
        .map_err(|e| compile_finding(e, format!("/function_tables/{id}")))
}

/// Whether `value` is a node load checks: a `fn` node naming one of the
/// functions whose arguments §9.2 checks, or a `table_lookup` node — what the
/// loader's template scan looks for, so a document with none is not walked
/// again.
pub(crate) fn is_load_checked_node(value: &Value) -> bool {
    is_checked_fn_node(value) || is_table_lookup_node(value)
}

fn op_of(value: &Value) -> Option<&str> {
    let Value::Object(obj) = value else {
        return None;
    };
    crate::json_visit::small_get(obj, "op").and_then(Value::as_str)
}

fn is_checked_fn_node(value: &Value) -> bool {
    op_of(value) == Some("fn")
        && value
            .get("name")
            .and_then(Value::as_str)
            .is_some_and(has_load_time_argument_checks)
}

fn is_table_lookup_node(value: &Value) -> bool {
    op_of(value) == Some("table_lookup")
}

/// The §9.5.5 checks on every entry of the raw document's `function_tables`
/// block, in declaration order; the first failure is returned. On success,
/// the tables, for the lookup checks.
pub(crate) fn check_raw_function_tables(
    doc: &Value,
) -> Result<IndexMap<String, FunctionTable>, Finding> {
    let mut out = IndexMap::new();
    let Some(tables) = doc.get("function_tables").and_then(Value::as_object) else {
        return Ok(out);
    };
    for (id, raw) in tables {
        // The schema has already accepted the entry, so it deserializes; a
        // failure here would be a schema/type drift, reported rather than
        // skipped.
        let table =
            <FunctionTable as serde::Deserialize>::deserialize(raw).map_err(|e| Finding {
                code: crate::diagnostic::codes::TABLE_DATA_SHAPE_MISMATCH.to_string(),
                path: format!("/function_tables/{id}"),
                message: format!("table `{id}` does not deserialize: {e}"),
            })?;
        check_table(&table, id)?;
        out.insert(id.clone(), table);
    }
    Ok(out)
}

/// The §9.2 argument checks on every `interp.*` `fn` node and the §9.5.5
/// lookup checks on every `table_lookup` node of the raw document, in
/// document order; the first failure is returned. `tables` is what
/// [`check_raw_function_tables`] returned.
///
/// `expression_templates` blocks are not entered: a template body is checked
/// where it is applied (esm-spec §9.2), and by the time this runs the loader
/// has expanded every application.
pub(crate) fn check_raw_expression_nodes(
    doc: &Value,
    tables: &IndexMap<String, FunctionTable>,
) -> Result<(), Finding> {
    walk_raw(doc, &JsonPath::Root(""), Some(tables), &mut Err)
}

/// Pre-order walk of a raw value, handing each failing node's finding to
/// `sink`; the walk stops at the first `Err` the sink returns.
fn walk_raw(
    value: &Value,
    path: &JsonPath<'_>,
    tables: Option<&IndexMap<String, FunctionTable>>,
    sink: &mut dyn FnMut(Finding) -> Result<(), Finding>,
) -> Result<(), Finding> {
    match value {
        Value::Object(obj) => {
            if is_checked_fn_node(value)
                && let Err(f) = check_raw_fn_node(obj, path)
            {
                sink(f)?;
            }
            if is_table_lookup_node(value)
                && let Err(f) = check_raw_lookup_node(value, path, tables)
            {
                sink(f)?;
            }
            for (key, child) in obj {
                if key == "expression_templates" {
                    continue;
                }
                walk_raw(child, &JsonPath::Key(path, key), tables, sink)?;
            }
            Ok(())
        }
        Value::Array(items) => {
            for (i, child) in items.iter().enumerate() {
                walk_raw(child, &JsonPath::Index(path, i), tables, sink)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn check_raw_lookup_node(
    value: &Value,
    path: &JsonPath<'_>,
    tables: Option<&IndexMap<String, FunctionTable>>,
) -> Result<(), Finding> {
    // The schema has accepted the node, so it deserializes; it is small (its
    // axis inputs are the only expressions under it).
    let node = match <Expr as serde::Deserialize>::deserialize(value) {
        Ok(Expr::Operator(node)) => node,
        Ok(_) => return Ok(()),
        Err(e) => {
            return Err(Finding {
                code: crate::diagnostic::codes::TABLE_LOOKUP_UNKNOWN_TABLE.to_string(),
                path: path.to_string(),
                message: format!("a `table_lookup` node does not deserialize: {e}"),
            });
        }
    };
    crate::lower_table_lookup::check_lookup(&node, tables)
        .map_err(|e| compile_finding(e, path.to_string()))
}

fn check_raw_fn_node(
    obj: &serde_json::Map<String, Value>,
    path: &JsonPath<'_>,
) -> Result<(), Finding> {
    let name = obj.get("name").and_then(Value::as_str).unwrap_or_default();
    let args: Vec<ClosedArgLiteral> = obj
        .get("args")
        .and_then(Value::as_array)
        .map(|args| args.iter().map(ClosedArgLiteral::from_json).collect())
        .unwrap_or_default();
    check_closed_function_args(name, &args).map_err(|e| Finding {
        code: e.code,
        path: path.to_string(),
        message: e.message,
    })
}

// ---------------------------------------------------------------------------
// validate(): the same checks on a typed document
// ---------------------------------------------------------------------------

/// Every §9.5.5 table finding, then every §9.2 argument finding and §9.5.5
/// lookup finding of `file`, as structural errors: one per failing table (its
/// first rule, in the pinned order) and one per failing `fn` or `table_lookup`
/// node.
pub(crate) fn validate_findings(file: &EsmFile, errors: &mut Vec<StructuralError>) {
    let mut findings = Vec::new();
    for (id, table) in file.function_tables.iter().flatten() {
        if let Err(f) = check_table(table, id) {
            findings.push(f);
        }
    }
    let mut walk = TypedWalk {
        seen: HashSet::new(),
        tables: file.function_tables.as_ref(),
        findings: &mut findings,
    };
    walk.document(file);
    errors.extend(findings.into_iter().filter_map(|f| {
        Some(StructuralError {
            code: StructuralErrorCode::from_load_check_code(&f.code)?,
            path: f.path,
            message: f.message,
            details: serde_json::json!({}),
        })
    }));
}

/// The typed counterpart of [`check_raw_expression_nodes`]: every expression-bearing field of a
/// typed document, and the raw-JSON fields it carries (subsystems, guesses,
/// coupling) through [`walk_raw`] itself.
struct TypedWalk<'f> {
    /// `fn` nodes already checked. Operator subtrees are shared after load
    /// ([`crate::intern`]), so one node can sit at many positions; it is
    /// checked — and reported — once.
    seen: HashSet<*const ExpressionNode>,
    tables: Option<&'f IndexMap<String, FunctionTable>>,
    findings: &'f mut Vec<Finding>,
}

impl TypedWalk<'_> {
    fn document(&mut self, file: &EsmFile) {
        for (name, model) in file.models.iter().flatten() {
            self.model(model, &format!("/models/{name}"));
        }
        for (name, rs) in file.reaction_systems.iter().flatten() {
            let base = format!("/reaction_systems/{name}");
            for (pname, param) in &rs.parameters {
                if let Some(spec) = &param.update {
                    let update_base = format!("{base}/parameters/{pname}/update");
                    spec.for_each_expression_at(&mut |expr, site| {
                        self.expr(expr, &format!("{update_base}{site}"));
                    });
                }
            }
            for (i, rxn) in rs.reactions.iter().enumerate() {
                self.expr(&rxn.rate, &format!("{base}/reactions/{i}/rate"));
            }
            self.equations(
                rs.constraint_equations.iter().flatten(),
                &format!("{base}/constraint_equations"),
            );
            self.events(
                rs.discrete_events.as_deref(),
                rs.continuous_events.as_deref(),
                &base,
            );
            self.tests(rs.tests.as_deref(), &base);
            self.raw_map(rs.subsystems.as_ref(), &format!("{base}/subsystems"));
        }
        for (i, entry) in file.coupling.iter().flatten().enumerate() {
            if let Ok(raw) = serde_json::to_value(entry) {
                self.raw(&raw, &format!("/coupling/{i}"));
            }
        }
    }

    fn model(&mut self, model: &crate::Model, base: &str) {
        self.equations(model.equations.iter(), &format!("{base}/equations"));
        self.equations(
            model.initialization_equations.iter().flatten(),
            &format!("{base}/initialization_equations"),
        );
        self.events(
            model.discrete_events.as_deref(),
            model.continuous_events.as_deref(),
            base,
        );
        for (name, var) in &model.variables {
            let var_base = format!("{base}/variables/{name}/update");
            var.for_each_expression_at(&mut |expr, site| {
                self.expr(expr, &format!("{var_base}{site}"));
            });
        }
        self.tests(model.tests.as_deref(), base);
        self.raw_map(model.subsystems.as_ref(), &format!("{base}/subsystems"));
        if let Some(guesses) = &model.guesses {
            for (name, raw) in guesses {
                self.raw(raw, &format!("{base}/guesses/{name}"));
            }
        }
    }

    fn equations<'e>(&mut self, eqs: impl Iterator<Item = &'e crate::Equation>, base: &str) {
        for (i, eq) in eqs.enumerate() {
            self.expr(&eq.lhs, &format!("{base}/{i}/lhs"));
            self.expr(&eq.rhs, &format!("{base}/{i}/rhs"));
        }
    }

    fn events(
        &mut self,
        discrete: Option<&[crate::DiscreteEvent]>,
        continuous: Option<&[crate::ContinuousEvent]>,
        base: &str,
    ) {
        for (i, ev) in discrete.into_iter().flatten().enumerate() {
            let ev_base = format!("{base}/discrete_events/{i}");
            if let crate::DiscreteEventTrigger::Condition { expression } = &ev.trigger {
                self.expr(expression, &format!("{ev_base}/trigger/expression"));
            }
            for (j, affect) in ev.affects.iter().flatten().enumerate() {
                self.expr(&affect.rhs, &format!("{ev_base}/affects/{j}/rhs"));
            }
        }
        for (i, ev) in continuous.into_iter().flatten().enumerate() {
            let ev_base = format!("{base}/continuous_events/{i}");
            for (j, cond) in ev.conditions.iter().enumerate() {
                self.expr(cond, &format!("{ev_base}/conditions/{j}"));
            }
            for (j, affect) in ev.affects.iter().enumerate() {
                self.expr(&affect.rhs, &format!("{ev_base}/affects/{j}/rhs"));
            }
            for (j, affect) in ev.affect_neg.iter().flatten().enumerate() {
                self.expr(&affect.rhs, &format!("{ev_base}/affect_neg/{j}/rhs"));
            }
        }
    }

    fn tests(&mut self, tests: Option<&[crate::types::ModelTest]>, base: &str) {
        for (i, test) in tests.into_iter().flatten().enumerate() {
            for (j, assertion) in test.assertions.iter().enumerate() {
                if let Some(crate::types::AssertionReference::Expression(expr)) =
                    assertion.reference.as_ref()
                {
                    self.expr(expr, &format!("{base}/tests/{i}/assertions/{j}/reference"));
                }
            }
        }
    }

    fn raw_map(&mut self, map: Option<&indexmap::IndexMap<String, Value>>, base: &str) {
        for (name, raw) in map.into_iter().flatten() {
            self.raw(raw, &format!("{base}/{name}"));
        }
    }

    /// Every failing node under a raw-JSON field (not only the first).
    fn raw(&mut self, value: &Value, base: &str) {
        let findings = &mut *self.findings;
        let _ = walk_raw(value, &JsonPath::Root(base), self.tables, &mut |f| {
            findings.push(f);
            Ok(())
        });
    }

    fn expr(&mut self, expr: &Expr, path: &str) {
        let Expr::Operator(node) = expr else {
            return;
        };
        if !self.seen.insert(std::sync::Arc::as_ptr(node)) {
            return;
        }
        if node.op == "table_lookup"
            && let Err(e) = crate::lower_table_lookup::check_lookup(node, self.tables)
        {
            self.findings.push(compile_finding(e, path.to_string()));
        }
        if node.op == "fn"
            && let Some(name) = node.name.as_deref()
            && has_load_time_argument_checks(name)
        {
            let args: Vec<ClosedArgLiteral> =
                node.args.iter().map(ClosedArgLiteral::from_expr).collect();
            if let Err(e) = check_closed_function_args(name, &args) {
                self.findings.push(Finding {
                    code: e.code,
                    path: path.to_string(),
                    message: e.message,
                });
            }
        }
        node.for_each_child(&mut |child| self.expr(child, path));
    }
}
