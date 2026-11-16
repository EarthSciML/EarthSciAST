//! The front half every build into the array runtime shares: one function,
//! [`normalize`], turns what a build reads — one authored model, or a
//! flattened system — into the model it compiles, with every subsystem
//! mounted, `flatten`'s rewrites made, each recurrence group stacked and the
//! shape of every unshaped mixed-rank `ifelse` decided.
//!
//! The compile path ([`ArrayCompiled`]'s constructors) and the build pipeline
//! (`crate::prepare`) both call it, so neither assembles these stages by hand
//! and they run in one order. Their product, [`NormalizedModel`], is the only
//! input the later stages accept.

use super::compile::{
    VariableAxes, apply_flatten_rewrites, model_from_flattened, mount_subsystems,
    resolve_model_self_references, set_declared_shapes,
};
use super::recurrence_group::lower_recurrence_groups;
use super::{HashMap, IndexSet};
use crate::flatten::{BuiltShapes, ConditionalShapes, FlattenedSystem};
use crate::simulate::CompileError;
use crate::types::Model;

/// What a build reads.
pub(crate) enum BuildInput<'a> {
    /// One authored document model, owned. `name` is its key in the
    /// document: with a name, a self-qualified reference (`M.x`, `M.sub.x`)
    /// resolves to its local spelling once the subsystems are mounted.
    Authored {
        model: Box<Model>,
        name: Option<&'a str>,
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
/// 1. mount the subsystems (authored input only; a flattened system is
///    mounted already), so every later stage sees a subsystem's variables
///    and equations under their mounted names;
/// 2. resolve self-qualified references, which can only be recognized once
///    the names they spell are mounted;
/// 3. `flatten`'s rewrites ([`apply_flatten_rewrites`]): right-hand-side `D`,
///    angle arguments, the elementwise lift and the shapes of unshaped
///    mixed-rank `ifelse` variables, then the bare-array-operand check on the
///    lifted equations;
/// 4. stack each recurrence group, which reads the shapes step 3 decided.
pub(crate) fn normalize(
    input: BuildInput<'_>,
    mut index_sets: HashMap<String, IndexSet>,
) -> Result<NormalizedModel, CompileError> {
    let (mut model, inherited) = match input {
        BuildInput::Authored { model, name } => {
            let mut model = *model;
            mount_subsystems(&mut model)?;
            if let Some(name) = name {
                resolve_model_self_references(&mut model, name);
            }
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
    let (mut shapes, axes) = apply_flatten_rewrites(&mut model, &index_sets)?;
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
