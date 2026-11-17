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

use super::compile::{
    VariableAxes, apply_shape_rewrites, model_from_flattened, set_declared_shapes,
};
use super::recurrence_group::lower_recurrence_groups;
use super::{HashMap, IndexSet};
use crate::flatten::{BuiltShapes, ConditionalShapes, FlattenedSystem};
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
    /// `inherited` declares the shapes a system this one was cut from decided
    /// (`ArrayCompiled::from_flattened_shaped`).
    Flattened {
        flat: &'a FlattenedSystem,
        inherited: Option<&'a BuiltShapes>,
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
    /// The shapes the build gave unshaped variables (esm-spec §4.3.4,
    /// §9.6.11), and the variables only data can shape.
    pub(crate) shapes: ConditionalShapes,
    /// Every variable's index-set axes, declared or inferred.
    pub(crate) axes: VariableAxes,
}

/// Normalize `input` against the document's `index_sets` registry. The stages
/// run in this order, and each needs the one before it:
///
/// 1. the system's variables merged into one registry
///    ([`model_from_flattened`]), shown model-locally for a model built alone;
/// 2. the shape rewrites ([`apply_shape_rewrites`]): the elementwise lift and
///    the shapes of unshaped mixed-rank `ifelse` variables, then the
///    bare-array-operand check on the lifted equations;
/// 3. stack each recurrence group, which reads the shapes step 2 decided.
pub(crate) fn normalize(
    input: BuildInput<'_>,
    mut index_sets: HashMap<String, IndexSet>,
) -> Result<NormalizedModel, CompileError> {
    let (mut model, inherited) = match input {
        BuildInput::Local { flat, model: local } => {
            let mut model = model_from_flattened(flat);
            unqualify(&mut model, local);
            (model, None)
        }
        BuildInput::Flattened { flat, inherited } => {
            let mut model = model_from_flattened(flat);
            if let Some(shapes) = inherited {
                set_declared_shapes(&mut model, shapes);
            }
            (model, inherited)
        }
    };
    let (mut shapes, axes) = apply_shape_rewrites(&mut model, &index_sets)?;
    // The inherited shapes were declared before the rewrites ran, so the
    // promotion did not record them; they are the build's all the same.
    if let Some(inherited) = inherited {
        shapes
            .built
            .extend(inherited.iter().map(|(k, v)| (k.clone(), v.clone())));
    }
    lower_recurrence_groups(&mut model, &mut index_sets)?;
    Ok(NormalizedModel {
        model,
        index_sets,
        shapes,
        axes,
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
