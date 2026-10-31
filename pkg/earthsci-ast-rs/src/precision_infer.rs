//! Static precision inference: propagate `ModelVariable.element_type` over an
//! expression tree and mark the boundaries (esm-spec §11.3.1).
//!
//! # Why this exists
//!
//! `domain.element_type: "Float32"` is one switch for the whole document, and
//! it rounds *every* value to binary32. That is right for a model's
//! floating-point quantities and catastrophic for its keys: binary32 represents
//! every integer only to 2²⁴ = 16 777 216, and a relational model's join keys
//! are frequently far above it. A ten-digit category code is ≈2.26 × 10⁹ — 135×
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
//! Precision is then carried in two places, at the two granularities it
//! actually varies at:
//!
//! * **Per equation** — by the rule the equation compiles to, read back at
//!   evaluation as `precision::of_variable(rule.var)`. Nothing is added to the
//!   tree, so every pass that pattern-matches an equation's right-hand side
//!   (the `faq` an `AlgebraicRule::ArrayLoop` is built from, the
//!   relational lowering, the value-invention detector) still sees what it saw.
//! * **Per subtree** — by a [`MARKER_OP`] node wrapping any subtree INSIDE an
//!   expression whose precision differs from the equation's, which is exactly
//!   the predicate case above. Every evaluator honours it by arming a
//!   [`crate::precision::PrecisionGuard`] for the subtree.
//!
//! # Two things this pass quietly guarantees
//!
//! **A shared subtree cannot span two precisions.** Load-time interning
//! ([`crate::intern`]) collapses structurally identical `Expr::Operator` nodes
//! onto one `Arc`, and the evaluator's CSE memo is keyed on that ADDRESS — so a
//! subtree shared between two rules of different precision would be memoized at
//! one and served at the other. It cannot happen twice over: a shared subtree
//! that mentions any variable carries that variable's precision, so both rules
//! carry it too (a rule that did not would be `MixedElementType`); and this
//! pass rebuilds every operator node of every equation of a model that declares
//! an `element_type`, so those equations share no `Arc` with anything. The
//! rebuild is therefore load-bearing, not incidental — do not turn it into an
//! in-place edit that preserves node identity.
//!
//! **`join.on` needs nothing from this pass.** A join clause names its key
//! COLUMNS as strings and the relational engine compares the array values
//! directly; it applies no kernel and so does no rounding. An exempt column
//! that arrives unrounded therefore joins exactly, which is the whole point.
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

use crate::precision::{Env, Precision, VarPrecisions};
use crate::types::{Equation, Expr, ExpressionNode, Model};
use serde::Deserialize;

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

/// Wrap `expr` so it is evaluated in binary64 — an EXACT comparison of stored
/// carriers — whatever the document's working precision is.
///
/// The one caller is `crate::join::equality_predicate`, and the reason is
/// normative. A `join.on` key is an exact-equality value (CONFORMANCE_SPEC.md
/// §5.5.8: an integer ID or a categorical member; **floats are forbidden**), so
/// the lowered `left == right` predicate is a KEY COMPARISON and not
/// arithmetic. Narrowed to binary32 it stops being one: a NONROAD `SCC` such as
/// `2265007010` and `2265007015` are 5 apart and *the same* binary32 number, so
/// the predicate reports two different keys equal.
///
/// That mattered because §5.5.8 rests the driver's safety on the predicate:
/// "declining to drive costs time, never correctness" is true only if the
/// `filter` still tests the SAME equality the gate does. The gate compares
/// exact `i64` keys; a binary32 predicate compares fewer bits, so the two
/// disagreed, and WHICH CLAUSE DROVE decided a MOVES roll-up's answer —
/// exactly the freedom §5.5.8 grants and calls result-neutral.
///
/// This pass runs before `join::resolve_aggregate_joins`, so the lowered
/// predicate is created after annotation and would otherwise inherit the
/// ambient precision with no marker of its own. Marking it here is also why the
/// rule does not depend on the pass having run: it is unconditional.
pub(crate) fn mark_exact_key_comparison(expr: Expr) -> Expr {
    mark(expr, Precision::Float64)
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
    let subs = subsystem_declarations_of(model);
    annotate_model_with(model, "", &subs, document, &HashMap::new())
}

/// The precision a variable carries: its declaration, or the document's.
fn variable_precision(
    var: &crate::types::ModelVariable,
    document: Precision,
) -> Result<Precision, CompileError> {
    match var.element_type.as_deref() {
        None => Ok(document),
        some => Precision::from_element_type(some),
    }
}

/// Annotate every model of a document, sharing one QUALIFIED table across them.
///
/// A scoped reference (`Other.x`, esm-spec §4.6) reaches out of the model that
/// writes it, so a per-model table would read it as an unknown name and treat
/// it as context-adopting — silently widening or narrowing whatever it names.
/// The qualified table is what keeps a cross-model reference subject to the
/// same rules as a local one.
///
/// # Errors
///
/// As [`annotate_model`].
pub fn annotate_models(
    models: &mut indexmap::IndexMap<String, Model>,
    document: Precision,
) -> Result<(), CompileError> {
    let subs: Vec<SubsystemDeclarations> = models.values().map(subsystem_declarations_of).collect();
    annotate_models_with(models, &subs, document)
}

/// [`annotate_models`] with each model's [`subsystem_declarations_of`]
/// already computed (`subs[i]` for the `i`th model), so the subsystem trees
/// are walked once per build rather than once per question asked of them.
fn annotate_models_with(
    models: &mut indexmap::IndexMap<String, Model>,
    subs: &[SubsystemDeclarations],
    document: Precision,
) -> Result<(), CompileError> {
    if !models
        .values()
        .zip(subs)
        .any(|(m, s)| declares_element_type(m, s))
    {
        return Ok(());
    }
    let mut qualified: HashMap<String, Precision> = HashMap::new();
    for ((mname, model), model_subs) in models.iter().zip(subs) {
        for (vname, var) in &model.variables {
            qualified.insert(
                format!("{mname}.{vname}"),
                variable_precision(var, document)?,
            );
        }
        // A subsystem's variables under their full `Model.Sub.var` spelling,
        // which is how a scoped reference reaches them from another model.
        for (path, et) in model_subs {
            qualified.insert(
                format!("{mname}.{path}"),
                declared_precision(et.as_deref(), document)?,
            );
        }
    }
    for ((mname, model), model_subs) in models.iter_mut().zip(subs) {
        annotate_model_with(model, mname, model_subs, document, &qualified)?;
    }
    Ok(())
}

/// `(Sub.path.var, declared element_type)` for every variable of a model's
/// subsystems, at any depth.
type SubsystemDeclarations = Vec<(String, Option<String>)>;

/// Does `model` — or any subsystem it carries, at any depth (`subs`, its
/// [`subsystem_declarations_of`]) — declare an `element_type` on some
/// variable?
fn declares_element_type(model: &Model, subs: &SubsystemDeclarations) -> bool {
    model.variables.values().any(|v| v.element_type.is_some())
        || subs.iter().any(|(_, et)| et.is_some())
}

/// Every variable of `model`'s subsystems, at any depth, as `(Sub.path.var,
/// declared element_type)`.
fn subsystem_declarations_of(model: &Model) -> SubsystemDeclarations {
    crate::precision::subsystem_declarations_in(model.subsystems.iter().flatten())
}

/// The precision a declaration spelled `et` carries: itself, or the document's.
fn declared_precision(et: Option<&str>, document: Precision) -> Result<Precision, CompileError> {
    match et {
        None => Ok(document),
        some => Precision::from_element_type(some),
    }
}

/// Annotate `model` (keyed `owner` in its document, `""` when it stands
/// alone), whose subsystems declare `subs`.
fn annotate_model_with(
    model: &mut Model,
    owner: &str,
    subs: &SubsystemDeclarations,
    document: Precision,
    qualified: &HashMap<String, Precision>,
) -> Result<(), CompileError> {
    if !declares_element_type(model, subs) && !qualified.values().any(|p| *p != document) {
        return Ok(());
    }
    let mut env: HashMap<String, Precision> = qualified.clone();
    env.reserve(model.variables.len() + subs.len());
    for (name, var) in &model.variables {
        env.insert(name.clone(), variable_precision(var, document)?);
    }
    // A mounted subsystem's variables are in scope here under their
    // model-local `Sub.path.var` spelling (esm-spec §4.7), so an equation of
    // this model over one carries its precision rather than adopting context.
    for (path, et) in subs {
        env.insert(path.clone(), declared_precision(et.as_deref(), document)?);
    }
    // Clone the names out of the map so the equation walk can borrow `model`
    // mutably. The map is one entry per variable, built once per model.
    let equations = std::mem::take(&mut model.equations);
    let annotated = annotate_equations(equations, &env, document);
    let init = model.initialization_equations.take();
    let annotated_init = init.map(|eqs| annotate_equations(eqs, &env, document));
    model.equations = annotated?;
    model.initialization_equations = annotated_init.transpose()?;
    if let Some(subsystems) = model.subsystems.as_mut() {
        for (name, sub) in subsystems.iter_mut() {
            let path = if owner.is_empty() {
                name.clone()
            } else {
                format!("{owner}.{name}")
            };
            annotate_subsystem(&path, sub, document, &env)?;
        }
    }
    Ok(())
}

/// Annotate the equations of one `subsystems.<k>` component, and of its own
/// subsystems at any depth, in place in its raw form. `path` is the
/// component's full dotted path (`Model.Sub`, `Model.Sub.Inner`), used only
/// to name it in an error.
///
/// A subsystem stays raw JSON on the typed model until a build mounts it
/// (`crate::simulate_array::mount_subsystems`, and `flatten`'s subsystem
/// lowering), which splices its equations into the model with every sibling
/// name prefixed. The markers this pass writes are ordinary operator nodes, so
/// they survive that splice, and the mounted rule `Sub.var` is armed at
/// `precision::of_variable("Sub.var")`.
///
/// Only the component's `equations` and `initialization_equations` are
/// deserialized, and the variables' `element_type`s read off the raw JSON: a
/// whole-file leaf (an MPAS mesh) is not cloned or parsed whole here.
///
/// `enclosing` is the environment of the component that mounts this one. The
/// names this component's equations resolve locally are exactly the names the
/// mount renames: its own variables and, already prefixed, its nested
/// subsystems' (`Inner.x`). Anything else resolves against `enclosing`, as
/// the mount leaves it unrenamed.
///
/// # Errors
///
/// As [`annotate_model`], and [`CompileError::ElementTypeUncarried`] for a
/// component this pass cannot read whose variables declare a precision other
/// than the document's — it is refused, never evaluated in the document's. A
/// component that cannot be read and declares nothing is left for the mount to
/// refuse, with its own message.
fn annotate_subsystem(
    path: &str,
    value: &mut serde_json::Value,
    document: Precision,
    enclosing: &HashMap<String, Precision>,
) -> Result<(), CompileError> {
    let comp = crate::precision::subsystem_component(value);
    let parts = readable_component(comp);
    let (equations, init) = match parts {
        Ok(parts) => parts,
        Err(why) => {
            let name = path.rsplit('.').next().unwrap_or(path);
            let decls = crate::precision::subsystem_declarations_in([(&name.to_string(), &*value)]);
            let prefix = &path[..path.len() - name.len()];
            for (p, et) in decls {
                if declared_precision(et.as_deref(), document)? != document {
                    return Err(CompileError::ElementTypeUncarried {
                        construct: format!("subsystem variable '{prefix}{p}'"),
                        reason: format!(
                            "it declares `element_type: \"{}\"` and the document evaluates in \
                             {}, but its component could not be read for precision inference \
                             ({why})",
                            et.as_deref().unwrap_or_default(),
                            document.element_type()
                        ),
                    });
                }
            }
            return Ok(());
        }
    };
    let mut env = enclosing.clone();
    if let Some(vars) = comp.get("variables").and_then(serde_json::Value::as_object) {
        for (v, d) in vars {
            let et = d.get("element_type").and_then(serde_json::Value::as_str);
            env.insert(v.clone(), declared_precision(et, document)?);
        }
    }
    let nested = comp
        .get("subsystems")
        .and_then(serde_json::Value::as_object);
    for (p, et) in crate::precision::subsystem_declarations_in(nested.into_iter().flatten()) {
        env.insert(p, declared_precision(et.as_deref(), document)?);
    }
    let equations = annotate_equations(equations, &env, document)?;
    let init = init
        .map(|eqs| annotate_equations(eqs, &env, document))
        .transpose()?;
    let to_json = |eqs: &Vec<Equation>| {
        serde_json::to_value(eqs).map_err(|e| {
            CompileError::build_err(format!(
                "subsystem '{path}': re-serializing its annotated equations: {e}"
            ))
        })
    };
    let comp = crate::precision::subsystem_component_mut(value);
    let Some(obj) = comp.as_object_mut() else {
        return Ok(());
    };
    obj.insert("equations".to_string(), to_json(&equations)?);
    if let Some(init) = &init {
        obj.insert("initialization_equations".to_string(), to_json(init)?);
    }
    if let Some(nested) = obj
        .get_mut("subsystems")
        .and_then(serde_json::Value::as_object_mut)
    {
        for (k, v) in nested.iter_mut() {
            annotate_subsystem(&format!("{path}.{k}"), v, document, &env)?;
        }
    }
    Ok(())
}

/// The equations and initialization equations of a subsystem component
/// (`comp`, already [`crate::precision::subsystem_component`]), or why it
/// cannot be read as one: not an object, an unresolved `{"ref": ...}`, a file
/// that does not hold exactly one model, or equations that do not parse.
fn readable_component(
    comp: &serde_json::Value,
) -> Result<(Vec<Equation>, Option<Vec<Equation>>), String> {
    let obj = comp.as_object().ok_or("it is not a JSON object")?;
    if obj.contains_key("ref") {
        return Err("it is an unresolved {\"ref\": ...}".to_string());
    }
    if obj.contains_key("models") {
        return Err("it is a file that does not hold exactly one model".to_string());
    }
    let parse = |key: &str| -> Result<Option<Vec<Equation>>, String> {
        obj.get(key)
            .map(|v| Vec::<Equation>::deserialize(v).map_err(|e| format!("its `{key}`: {e}")))
            .transpose()
    };
    Ok((
        parse("equations")?.unwrap_or_default(),
        parse("initialization_equations")?,
    ))
}

/// The precision environment `file` declares: its `domain.element_type`, and
/// every `ModelVariable.element_type` under it, keyed by both the bare and the
/// `Model.name` spelling.
///
/// # Errors
///
/// [`CompileError::UnsupportedElementType`] for any spelling that is neither
/// `"Float64"` nor `"Float32"`.
pub fn env_of_file(file: &crate::types::EsmFile) -> Result<Env, CompileError> {
    let document =
        Precision::from_element_type(file.domain.as_ref().and_then(|d| d.element_type.as_deref()))?;
    let vars = match file.models.as_ref() {
        Some(models) => {
            VarPrecisions::from_declarations(&model_declarations(models), document, None)?
        }
        None => VarPrecisions::default(),
    };
    Ok(Env {
        document,
        variables: std::sync::Arc::new(vars),
    })
}

/// The per-model variable declarations [`VarPrecisions::from_declarations`]
/// reads, off a typed document's models.
#[must_use]
pub fn model_declarations(
    models: &indexmap::IndexMap<String, crate::types::Model>,
) -> Vec<crate::precision::ModelDeclarations<'_>> {
    models
        .iter()
        .map(|(mname, model)| crate::precision::ModelDeclarations {
            model: mname,
            variables: model
                .variables
                .iter()
                .map(|(v, d)| (v.as_str(), d.element_type.as_deref()))
                .collect(),
            subsystem_variables: subsystem_declarations_of(model),
        })
        .collect()
}

/// `file` with every equation annotated, or `None` when it declares no
/// per-variable `element_type` and is therefore already what the evaluator
/// should see.
///
/// The `None` arm is what keeps the public build entries free of a
/// whole-document clone: only a document that uses the feature pays for one.
///
/// # Errors
///
/// As [`annotate_model`].
pub fn annotated(
    file: &crate::types::EsmFile,
) -> Result<Option<crate::types::EsmFile>, CompileError> {
    let Some(models) = file.models.as_ref() else {
        return Ok(None);
    };
    let subs: Vec<SubsystemDeclarations> = models.values().map(subsystem_declarations_of).collect();
    if !models
        .values()
        .zip(&subs)
        .any(|(m, s)| declares_element_type(m, s))
    {
        return Ok(None);
    }
    let document =
        Precision::from_element_type(file.domain.as_ref().and_then(|d| d.element_type.as_deref()))?;
    let mut out = file.clone();
    if let Some(models) = out.models.as_mut() {
        annotate_models_with(models, &subs, document)?;
    }
    Ok(Some(out))
}

/// Check a FLATTENED system's equations for `mixed_element_type` (esm-spec
/// §11.3.1).
///
/// The per-model pass ([`annotate_models`]) runs before flattening, one model at
/// a time, so it cannot see what a coupling does across models: a
/// `variable_map` that feeds a mounted binary32 quantity into a binary64
/// model's parameter produces, after flattening, an equation mixing the two —
/// and without this check it evaluated silently in the rule's precision
/// (§4.7 "Working precision crosses a mount"). A no-op, with no walk at all,
/// when no flattened variable declares an `element_type`.
///
/// # Errors
///
/// [`CompileError::MixedElementType`] naming both variables, or
/// [`CompileError::UnsupportedElementType`] for a bad spelling.
pub fn check_flattened(flat: &crate::flatten::FlattenedSystem) -> Result<(), CompileError> {
    let registries = [
        &flat.state_variables,
        &flat.parameters,
        &flat.observed_variables,
        &flat.algebraic_variables,
        &flat.brownian_parameters,
        &flat.discrete_parameters,
    ];
    if !registries
        .iter()
        .any(|r| r.values().any(|v| v.element_type.is_some()))
    {
        return Ok(());
    }
    let document =
        Precision::from_element_type(flat.domain.as_ref().and_then(|d| d.element_type.as_deref()))?;
    let mut env: HashMap<String, Precision> = HashMap::new();
    for r in registries {
        for (name, var) in r {
            env.insert(name.clone(), variable_precision(var, document)?);
        }
    }
    for eq in &flat.equations {
        annotate_equation(eq.clone(), &env, document)?;
    }
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
    // NO marker at the equation root. An equation's precision is its left-hand
    // side's, and it is carried by the RULE the equation compiles to
    // (`precision::of_variable(rule.var)`), not by a wrapper node — because a
    // wrapper at the root is invisible to the evaluator but very visible to
    // every pass that pattern-matches an equation's right-hand side. Wrapping
    // `out_key ~ aggregate(…)` in one turned the equation from an
    // `AlgebraicRule::ArrayLoop` over an aggregate into a scalar rule over an
    // unrecognised op, and the key came out corrupted for a second reason
    // entirely. Markers therefore appear only INSIDE an expression, where a
    // subtree's precision genuinely differs from the equation's.
    eq.rhs = rhs;
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
            "*(floor(/(scc,1000)),1000)",
            "no marker: the equation is uniformly binary64 and the RULE carries \
             that, so every pass that matches on the right-hand side's root \
             still sees the operator it did"
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
            "*(r,0.1)",
            "uniformly binary32 inside a binary64 document; the rule carries it"
        );
    }

    #[test]
    fn a_scoped_reference_to_another_model_carries_that_model_s_element_type() {
        // `B.q` is binary32 (the document's) and `key` is binary64: the mix is
        // refused across the model boundary exactly as it is within one. A
        // per-model table would have read `B.q` as an unknown name, treated it
        // as context-adopting, and silently widened it.
        let mut models: indexmap::IndexMap<String, Model> = indexmap::IndexMap::new();
        models.insert(
            "A".to_string(),
            model(
                &[("out", Some("Float64")), ("key", Some("Float64"))],
                vec![eq("out", op("*", vec![v("key"), v("B.q")]))],
            ),
        );
        models.insert("B".to_string(), model(&[("q", None)], vec![]));
        let err = annotate_models(&mut models, Precision::Float32).unwrap_err();
        let msg = format!("{err}");
        assert!(msg.contains("B.q"), "{msg}");
        assert!(msg.contains("key"), "{msg}");
    }

    #[test]
    fn an_unknown_element_type_is_refused() {
        let mut m = model(&[("q", Some("Float16"))], vec![]);
        assert!(annotate_model(&mut m, Precision::Float64).is_err());
    }
}
