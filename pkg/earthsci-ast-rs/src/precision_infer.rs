//! Static precision inference: propagate `ModelVariable.element_type` over an
//! expression tree and mark the boundaries (esm-spec §11.3.1).
//!
//! # Why this exists
//!
//! `domain.element_type: "Float32"` is one switch for the whole document, and
//! it rounds *every* value to binary32. That is right for a model's
//! floating-point quantities and catastrophic for its keys: binary32 represents
//! every integer only to 2²⁴ = 16 777 216, and a relational model's join keys
//! are frequently far above it. A ten-digit SCC code is ≈2.26 × 10⁹ — 135×
//! beyond — so `2265007010` and `2265007015` both become `2265007104` and a
//! `join.on` over them merges two unrelated rows. The reference implementations
//! these models port are `real*4` in their quantities while their keys stay
//! `INTEGER`; one document-wide float precision cannot express that split.
//!
//! [`crate::types::ModelVariable::element_type`] expresses it, and this module
//! is what makes the declaration mean something beyond ingress. Exempting a key
//! column only where its data enters is **not** sufficient: the very first
//! expression over it undoes the exemption. `floor(scc/1000)*1000` is
//! `2260007000` in binary64 and `2260006912` in binary32, so the fallback
//! ladder that widens a key to its category would corrupt the key it was
//! handed intact.
//!
//! # The rule
//!
//! Precision is inferred bottom-up, once, at build time — the second of the two
//! routes (the other being a precision tag on every runtime `Value`, resolved
//! per operation). Statically, each node picks its kernel once instead of every
//! operation re-deciding, and — the deciding reason — a *static* pass can
//! **refuse** a mixed operator, which a dynamic widest-operand rule cannot: by
//! the time two operands meet at run time the only choices left are to widen or
//! to narrow, and both are silent.
//!
//! * A **numeric literal** has no precision of its own; it adopts its context,
//!   exactly as an unsuffixed constant does in C.
//! * A **variable** carries its declared `element_type`, or the document's.
//! * A name that is not a model variable — a loop symbol, `t`, a
//!   metaparameter, a relation tag — is likewise context-adopting.
//! * An **operator** evaluates at its operands' precision. Operands that
//!   disagree are [`CompileError::MixedElementType`], naming both variables.
//! * A **comparison or logical operator** returns an exact 0/1 flag, which is
//!   representable in every precision, so it is context-adopting *to its
//!   parent* while its own operands still have to agree with each other. This
//!   is what lets `sum(quant[i] * (key[i] == k))` be legal with `quant`
//!   binary32 and `key` binary64: the predicate is evaluated in binary64 and
//!   hands the arithmetic a flag, not a key.
//! * An **equation** stores at its left-hand side's precision; a right-hand
//!   side that disagrees is the same error. There is no implicit narrowing at
//!   the store either — the author says which precision a mixed step lands in
//!   by declaring the variable it lands in.
//!
//! Wherever an inferred precision differs from its context's, the subtree is
//! wrapped in a [`MARKER_OP`] node, which every evaluator honours by arming a
//! [`crate::precision::PrecisionGuard`] for the subtree. Nothing else in the
//! evaluators needs to know that per-variable element types exist.
//!
//! # Inertness
//!
//! The whole pass is skipped for a model in which no variable declares an
//! `element_type`. No marker is inserted, no check can fail, and every
//! document that exists today — Float64 or Float32 — evaluates through the
//! identical code path, bit for bit.

use std::collections::HashMap;
use std::sync::Arc;

use crate::compile_error::CompileError;
use crate::precision::Precision;
use crate::types::{Equation, Expr, ExpressionNode, Model};

/// The engine-internal operator that marks a precision boundary.
///
/// `{"op": "__precision", "name": "Float64", "args": [subtree]}` means
/// "evaluate `subtree` in binary64 whatever the enclosing precision is". It is
/// inserted by [`annotate_model`] AFTER the typed parse and is never written to
/// a document, so no authored file and no `parse → emit` round trip ever
/// contains one.
pub const MARKER_OP: &str = "__precision";

/// Read the precision off a [`MARKER_OP`] node.
///
/// `None` for any other operator. An unparseable `name` also yields `None` (the
/// node is then evaluated at the enclosing precision rather than at a guessed
/// one), which cannot arise from [`annotate_model`].
#[must_use]
pub fn marker_precision(node: &ExpressionNode) -> Option<Precision> {
    if node.op != MARKER_OP {
        return None;
    }
    Precision::from_element_type(node.name.as_deref()).ok()
}

/// [`marker_precision`] for the RAW-JSON form of a node.
///
/// The value-invention engine (`crate::value_invention`) evaluates the
/// document as `serde_json::Value` rather than as typed [`Expr`], so it needs
/// the same read against the untyped shape.
#[must_use]
pub fn marker_precision_json(node: &serde_json::Value) -> Option<Precision> {
    if node.get("op").and_then(serde_json::Value::as_str) != Some(MARKER_OP) {
        return None;
    }
    Precision::from_element_type(node.get("name").and_then(serde_json::Value::as_str)).ok()
}

/// Wrap `expr` in a [`MARKER_OP`] node for precision `p`.
fn mark(expr: Expr, p: Precision) -> Expr {
    Expr::Operator(Arc::new(ExpressionNode {
        op: MARKER_OP.to_string(),
        args: vec![expr],
        name: Some(p.element_type().to_string()),
        ..Default::default()
    }))
}

/// Operators whose result is an exact 0/1 flag and so carries no precision to
/// their parent. Their own operands must still agree with each other.
fn is_predicate_op(op: &str) -> bool {
    matches!(
        op,
        "==" | "!=" | "<" | "<=" | ">" | ">=" | "and" | "or" | "not"
    )
}

/// A precision together with the variable that supplied it, so a clash can name
/// both sides rather than reporting two anonymous element types.
#[derive(Clone, Copy)]
struct Source<'a> {
    prec: Precision,
    var: &'a str,
}

/// The inferred precision of a subtree: `None` when it is context-adopting
/// (literals, loop symbols, predicates).
type Inferred<'a> = Option<Source<'a>>;

/// Annotate every equation of `model` in place.
///
/// A no-op — not even a tree walk — unless some variable of `model` declares an
/// `element_type`.
///
/// # Errors
///
/// [`CompileError::UnsupportedElementType`] for a variable whose
/// `element_type` is neither `"Float64"` nor `"Float32"`, and
/// [`CompileError::MixedElementType`] for an operator or an equation whose
/// operands carry different ones.
pub fn annotate_model(model: &mut Model, document: Precision) -> Result<(), CompileError> {
    if !model
        .variables
        .values()
        .any(|v| v.element_type.is_some())
    {
        return Ok(());
    }
    let mut env: HashMap<String, Precision> = HashMap::with_capacity(model.variables.len());
    for (name, var) in &model.variables {
        let p = match var.element_type.as_deref() {
            None => document,
            some => Precision::from_element_type(some)?,
        };
        env.insert(name.clone(), p);
    }
    // Clone the names out of the map so the equation walk can borrow `model`
    // mutably. The map is one entry per variable, built once per model.
    let equations = std::mem::take(&mut model.equations);
    let annotated = annotate_equations(equations, &env, document);
    let init = model.initialization_equations.take();
    let annotated_init = init.map(|eqs| annotate_equations(eqs, &env, document));
    model.equations = annotated?;
    model.initialization_equations = annotated_init.transpose()?;
    Ok(())
}

fn annotate_equations(
    equations: Vec<Equation>,
    env: &HashMap<String, Precision>,
    document: Precision,
) -> Result<Vec<Equation>, CompileError> {
    equations
        .into_iter()
        .map(|eq| annotate_equation(eq, env, document))
        .collect()
}

fn annotate_equation(
    mut eq: Equation,
    env: &HashMap<String, Precision>,
    document: Precision,
) -> Result<Equation, CompileError> {
    // The store's precision is the left-hand side's. `D(u, t)` and other
    // structural left-hand sides resolve through the same walk: their variable
    // leaf is what carries the declaration.
    let (lhs_src, _) = infer(&eq.lhs, env)?;
    let target = lhs_src.map_or(document, |s| s.prec);
    let lhs_name = lhs_src.map_or("the left-hand side", |s| s.var).to_string();

    let (rhs_src, rhs) = infer(&eq.rhs, env)?;
    if let Some(src) = rhs_src
        && src.prec != target
    {
        return Err(CompileError::MixedElementType {
            op: "equation".to_string(),
            lhs_name,
            lhs_type: target.element_type().to_string(),
            rhs_name: src.var.to_string(),
            rhs_type: src.prec.element_type().to_string(),
        });
    }
    // The right-hand side is evaluated at the target precision. It needs a
    // marker only when that is not the precision already in force, which for a
    // top-level equation is the document's.
    eq.rhs = if target == document {
        rhs
    } else {
        mark(rhs, target)
    };
    Ok(eq)
}

/// Infer `expr`'s precision and return it rewritten with boundary markers.
///
/// The returned [`Inferred`] is the precision the subtree hands its PARENT:
/// `None` when the subtree adopts whatever precision surrounds it. The returned
/// `Expr` is self-contained — every internal boundary is already marked — so a
/// caller only has to mark the subtree itself if its own precision differs from
/// the context it is being placed in.
fn infer<'a>(
    expr: &Expr,
    env: &'a HashMap<String, Precision>,
) -> Result<(Inferred<'a>, Expr), CompileError> {
    match expr {
        // A literal has no precision of its own; it adopts its context.
        Expr::Integer(_) | Expr::Number(_) => Ok((None, expr.clone())),
        Expr::Variable(name) => match env.get_key_value(name.as_str()) {
            Some((k, p)) => Ok((
                Some(Source {
                    prec: *p,
                    var: k.as_str(),
                }),
                expr.clone(),
            )),
            // Not a model variable: a loop symbol, `t`, a metaparameter, a
            // relation tag. Context-adopting.
            None => Ok((None, expr.clone())),
        },
        Expr::Operator(node) => infer_op(node, env),
    }
}

fn infer_op<'a>(
    node: &ExpressionNode,
    env: &'a HashMap<String, Precision>,
) -> Result<(Inferred<'a>, Expr), CompileError> {
    // Infer every child first, remembering each one's own precision so a clash
    // can be reported against the operator that joins them.
    let mut children: Vec<(Inferred<'a>, Expr)> = Vec::new();
    let mut err: Option<CompileError> = None;
    let mut collect = |child: &Expr| {
        if err.is_some() {
            return;
        }
        match infer(child, env) {
            Ok(pair) => children.push(pair),
            Err(e) => err = Some(e),
        }
    };
    node.for_each_child(&mut collect);
    if let Some(e) = err {
        return Err(e);
    }

    // The operator's own precision: the one its operands agree on.
    let mut resolved: Inferred<'a> = None;
    for (src, _) in &children {
        let Some(src) = src else { continue };
        match resolved {
            None => resolved = Some(*src),
            Some(prev) if prev.prec == src.prec => {}
            Some(prev) => {
                return Err(CompileError::MixedElementType {
                    op: node.op.clone(),
                    lhs_name: prev.var.to_string(),
                    lhs_type: prev.prec.element_type().to_string(),
                    rhs_name: src.var.to_string(),
                    rhs_type: src.prec.element_type().to_string(),
                });
            }
        }
    }

    // Rebuild the node with the rewritten children, in the same order
    // `for_each_child` visited them.
    let mut rebuilt = node.clone();
    let mut rewritten = children.iter().map(|(_, e)| e.clone());
    rebuilt.for_each_child_mut(&mut |slot: &mut Expr| {
        if let Some(e) = rewritten.next() {
            *slot = e;
        }
    });
    let out = Expr::Operator(Arc::new(rebuilt));

    match resolved {
        // Every operand was context-adopting, and so is the result.
        None => Ok((None, out)),
        Some(src) if is_predicate_op(&node.op) => {
            // The flag it returns is exact in every precision, so the parent is
            // unconstrained — but the comparison itself must run at its
            // operands' precision, or a binary64 key would be narrowed to
            // binary32 before being compared and two distinct keys would test
            // equal. Marked here, because this is exactly the boundary the
            // parent will not create.
            Ok((None, mark(out, src.prec)))
        }
        Some(src) => Ok((Some(src), out)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ModelVariable, VariableType};

    fn var(element_type: Option<&str>) -> ModelVariable {
        ModelVariable {
            var_type: VariableType::Parameter,
            element_type: element_type.map(str::to_string),
            ..Default::default()
        }
    }

    fn model(vars: &[(&str, Option<&str>)], eqs: Vec<Equation>) -> Model {
        let mut m = Model::default();
        for (n, et) in vars {
            m.variables.insert((*n).to_string(), var(*et));
        }
        m.equations = eqs;
        m
    }

    fn eq(lhs: &str, rhs: Expr) -> Equation {
        Equation {
            lhs: Expr::Variable(lhs.to_string()),
            rhs,
            comment: None,
        }
    }

    fn op(name: &str, args: Vec<Expr>) -> Expr {
        Expr::Operator(Arc::new(ExpressionNode {
            op: name.to_string(),
            args,
            ..Default::default()
        }))
    }

    fn v(n: &str) -> Expr {
        Expr::Variable(n.to_string())
    }

    /// Rendered shape of a tree, so a test can assert WHERE a marker landed.
    fn shape(e: &Expr) -> String {
        match e {
            Expr::Integer(i) => i.to_string(),
            Expr::Number(n) => n.to_string(),
            Expr::Variable(s) => s.clone(),
            Expr::Operator(node) => {
                let mut parts = Vec::new();
                node.for_each_child(&mut |c| parts.push(shape(c)));
                let head = match node.name.as_deref() {
                    Some(n) if node.op == MARKER_OP => format!("{}:{n}", node.op),
                    _ => node.op.clone(),
                };
                format!("{head}({})", parts.join(","))
            }
        }
    }

    #[test]
    fn no_declaration_is_a_no_op() {
        let mut m = model(
            &[("a", None), ("b", None)],
            vec![eq("a", op("*", vec![v("b"), Expr::Number(0.1)]))],
        );
        let before = shape(&m.equations[0].rhs);
        annotate_model(&mut m, Precision::Float32).unwrap();
        assert_eq!(shape(&m.equations[0].rhs), before, "no marker inserted");
    }

    #[test]
    fn exempt_arithmetic_is_marked_float64() {
        // `bucket = floor(scc / 1000) * 1000`, every leaf exempt.
        let mut m = model(
            &[("scc", Some("Float64")), ("bucket", Some("Float64"))],
            vec![eq(
                "bucket",
                op(
                    "*",
                    vec![
                        op("floor", vec![op("/", vec![v("scc"), Expr::Integer(1000)])]),
                        Expr::Integer(1000),
                    ],
                ),
            )],
        );
        annotate_model(&mut m, Precision::Float32).unwrap();
        assert_eq!(
            shape(&m.equations[0].rhs),
            "__precision:Float64(*(floor(/(scc,1000)),1000))",
            "one marker at the equation boundary, none inside"
        );
    }

    #[test]
    fn a_predicate_over_exempt_keys_is_marked_inside_a_float32_equation() {
        // `q = quant * (key == 2260007005)`
        let mut m = model(
            &[("q", None), ("quant", None), ("key", Some("Float64"))],
            vec![eq(
                "q",
                op(
                    "*",
                    vec![
                        v("quant"),
                        op("==", vec![v("key"), Expr::Integer(2_260_007_005)]),
                    ],
                ),
            )],
        );
        annotate_model(&mut m, Precision::Float32).unwrap();
        assert_eq!(
            shape(&m.equations[0].rhs),
            "*(quant,__precision:Float64(==(key,2260007005)))",
            "the comparison runs in binary64; the product stays binary32"
        );
    }

    #[test]
    fn mixing_two_element_types_in_one_operator_is_refused() {
        let mut m = model(
            &[("q", None), ("quant", None), ("key", Some("Float64"))],
            vec![eq("q", op("*", vec![v("quant"), v("key")]))],
        );
        let err = annotate_model(&mut m, Precision::Float32).unwrap_err();
        let msg = format!("{err}");
        assert!(msg.contains("quant"), "{msg}");
        assert!(msg.contains("key"), "{msg}");
        assert!(msg.contains("mixed_element_type"), "{msg}");
    }

    #[test]
    fn storing_across_element_types_is_refused() {
        let mut m = model(
            &[("q", None), ("key", Some("Float64"))],
            vec![eq("q", op("+", vec![v("key"), Expr::Integer(1)]))],
        );
        let err = annotate_model(&mut m, Precision::Float32).unwrap_err();
        assert!(format!("{err}").contains("equation"), "{err}");
    }

    #[test]
    fn a_float64_document_can_declare_a_float32_variable() {
        let mut m = model(
            &[("q", Some("Float32")), ("r", Some("Float32"))],
            vec![eq("q", op("*", vec![v("r"), Expr::Number(0.1)]))],
        );
        annotate_model(&mut m, Precision::Float64).unwrap();
        assert_eq!(
            shape(&m.equations[0].rhs),
            "__precision:Float32(*(r,0.1))",
            "the narrowing is explicit and marked, not implied by the document"
        );
    }

    #[test]
    fn an_unknown_element_type_is_refused() {
        let mut m = model(&[("q", Some("Float16"))], vec![]);
        assert!(annotate_model(&mut m, Precision::Float64).is_err());
    }
}
