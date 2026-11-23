//! The front half every build into the array runtime shares: one function,
//! [`normalize`], turns the flattened system a build reads — the whole
//! document's, or one model's built alone — into the model it compiles, each
//! recurrence group stacked and the shape of every unshaped mixed-rank
//! `ifelse` decided.
//!
//! The compile path ([`ArrayCompiled`]'s constructors, which always build from
//! a flattened system) and the build pipeline (`crate::prepare`) both call it,
//! so neither assembles these stages by hand and they run in one order. Their
//! product, [`NormalizedModel`], is the only input the later stages accept.

use super::compile::{apply_shape_rewrites, model_from_flattened};
use super::recurrence_group::lower_recurrence_groups;
use super::shape_table::ShapeTable;
use super::{HashMap, IndexSet};
use crate::flatten::FlattenedSystem;
use crate::simulate::CompileError;
use crate::types::Model;

/// What a build reads.
pub(crate) enum BuildInput<'a> {
    /// The flattened system of one model built alone (`model`, its key in
    /// the document), its names shown model-locally: the `model.` every name
    /// of the model begins with is dropped, so a variable `x` is `x` and a
    /// mounted one `Sub.x`, as the build pipeline's model-local build names
    /// them.
    Local {
        flat: &'a FlattenedSystem,
        model: &'a str,
    },
    /// A flattened system: every name dot-namespaced, the coupling applied.
    /// `inherited` is the shape table of the build of a system this one was
    /// cut from (`ArrayCompiled::from_flattened_shaped`), whose decided
    /// shapes this one may no longer decide.
    Flattened {
        flat: &'a FlattenedSystem,
        inherited: Option<&'a ShapeTable>,
    },
}

/// A model ready for compilation: one registry of variables over one list of
/// equations, every subsystem mounted under its dotted name, every right-hand
/// side `D` resolved, every scaled angle argument in radians, each recurrence
/// group stacked into one recurrence (esm-spec §4.3.1.2), and the index-set
/// registry those rewrites extended.
pub(crate) struct NormalizedModel {
    pub(crate) model: Model,
    pub(crate) index_sets: HashMap<String, IndexSet>,
    /// Every variable's index-set axes, declared or decided by the build
    /// (esm-spec §4.3.4, §9.6.11), and the variables only data can shape.
    pub(crate) shapes: ShapeTable,
    /// The flattened system's operator registry, which the references of
    /// [`Self::model`] resolve against (esm-spec §9.6.4 rule 7).
    pub(crate) operators: crate::operator_refs::OperatorRegistry,
}

/// Normalize `input` against the document's `index_sets` registry. The stages
/// run in this order, and each needs the one before it:
///
/// 1. the system's variables merged into one registry
///    ([`model_from_flattened`]), shown model-locally for a model built alone;
/// 2. the shape rewrites ([`apply_shape_rewrites`]): the inherited shapes,
///    the elementwise lift and the shapes of unshaped mixed-rank `ifelse`
///    variables, then the bare-array-operand check on the lifted equations,
///    which leave the build's [`ShapeTable`];
/// 3. stack each recurrence group, which reads the shapes step 2 decided,
///    and record each stacked variable's shape in the table.
pub(crate) fn normalize(
    input: BuildInput<'_>,
    mut index_sets: HashMap<String, IndexSet>,
) -> Result<NormalizedModel, CompileError> {
    let operators = match &input {
        BuildInput::Local { flat, .. } | BuildInput::Flattened { flat, .. } => flat.operators(),
    };
    let (mut model, inherited) = match input {
        BuildInput::Local { flat, model: local } => {
            // esm-spec §4.2: a right-hand-side `D` flatten could not resolve is
            // refused here, as `from_flattened` refuses it on the other route.
            if crate::flatten::first_unresolved_rhs_time_derivative(flat).is_some() {
                return Err(CompileError::UnloweredOperatorError {
                    op: "D".to_string(),
                    why: String::new(),
                });
            }
            let mut model = model_from_flattened(flat);
            unqualify(&mut model, local);
            (model, None)
        }
        BuildInput::Flattened { flat, inherited } => (model_from_flattened(flat), inherited),
    };
    let mut shapes = apply_shape_rewrites(&mut model, &index_sets, inherited)?;
    shapes.record_stacked(lower_recurrence_groups(&mut model, &mut index_sets)?);
    Ok(NormalizedModel {
        model,
        index_sets,
        shapes,
        operators,
    })
}

/// Drop `local.` from every name of `model` that begins with it: its
/// variables, and every free reference of its equations and initialization
/// equations, except one an enclosing node binds the shorter name of.
pub(super) fn unqualify(model: &mut Model, local: &str) {
    let prefix = format!("{local}.");
    let strip = |n: &str| n.strip_prefix(prefix.as_str()).map(str::to_string);
    model.variables = std::mem::take(&mut model.variables)
        .into_iter()
        .map(|(n, v)| (strip(&n).unwrap_or(n), v))
        .collect();
    let rename = |e: &crate::types::Expr| {
        crate::binders::rename_free_names_uncaptured(e, crate::binders::Binders::BODY, &strip)
    };
    for eq in model
        .equations
        .iter_mut()
        .chain(model.initialization_equations.iter_mut().flatten())
    {
        eq.lhs = rename(&eq.lhs);
        eq.rhs = rename(&eq.rhs);
    }
}
