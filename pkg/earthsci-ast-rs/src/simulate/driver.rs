use super::*;

// ============================================================================
// Routing from a document into the array runtime
// ============================================================================

/// The coupled array route builds from the flattened system, and `flatten` lifts
/// only the top-level components' events, so an event an inline subsystem owns
/// is refused here, while the document still holds it.
fn refuse_coupled_subsystem_event(file: &EsmFile) -> Result<(), CompileError> {
    match crate::compile_error::first_event_in_file(file) {
        Some((construct, name)) => Err(crate::compile_error::event_refusal(
            construct,
            crate::compile_error::ARRAY_EVALUATOR,
            name.as_deref(),
        )),
        None => Ok(()),
    }
}

/// Whether the document's WHOLE content is one model — the only shape
/// `ArrayCompiled::from_file` can consume, since it takes that one raw `Model`
/// and nothing else.
///
/// A reaction system beside the model counts as content: its reactions lower
/// to `D(species, t) = …` during flattening, and a build that skipped them
/// would drop every species from the compiled system. A system with NO
/// reactions lowers to nothing, so it is not content.
pub(crate) fn whole_document_is_one_model(file: &EsmFile) -> bool {
    let one_model = file.models.as_ref().map_or(0, |m| m.len()) == 1;
    let has_reactions = file
        .reaction_systems
        .as_ref()
        .is_some_and(|systems| systems.iter().any(|(_, rs)| !rs.reactions.is_empty()));
    one_model && !has_reactions
}

/// Whether `file` has array-op nodes or spatial model structure — the
/// documents [`compile_array`] accepts.
pub(crate) fn is_array_file(file: &EsmFile) -> bool {
    crate::simulate_array::file_has_array_ops(file)
        || crate::simulate_array::file_has_spatial_model(file)
}

/// Build the array/spatial runtime for `file`. A coupled (multi-model) file has
/// no single raw `Model` for `ArrayCompiled::from_file` to consume — it rejects
/// `models.len() != 1` — so flatten the coupling into one namespaced system first
/// and build from that (ess-14f.8). The single-model path is byte-identical to
/// the original `from_file` call. Shared by all three public entry points.
///
/// **The single-model arm is for a document whose WHOLE content is that one
/// model.** Two other shapes must flatten first, and both used to reach
/// `from_file`:
///
///   * no `models` map at all — a document whose whole content is a
///     `reaction_systems` block, which has no models until flattening lowers
///     each reaction to `D(species, t) = …`. `from_file` refused it with "File
///     has no models to simulate"; every pure-chemistry document in the wild
///     is that shape (`pollu`, `superfast`, `geoschem_fullchem`), and the
///     2026-09-21 census counted 25 of them, all fully taped once flattened;
///   * one model BESIDE a reaction system. `from_file` consumes the single
///     `Model` and DROPS the reaction system, so the species and their
///     reactions vanish from the compiled system — silently, because what is
///     left still builds. A `dAdt = D(Chem.A)` observed then fails as an
///     unlowered `D` and an assertion on `Chem.A` finds no such state.
///
/// `runtime_array_parameters` (API_SPEC §5.8): every shaped parameter that
/// has a value and no `update` is read from the forcing buffer, seeded with
/// that value, rather than folded in.
///
/// `flattened` is `flatten(file)` when the caller already holds it (the build
/// pipeline's whole-document build); it is used in place of flattening `file`
/// again, unless a per-variable element type makes the build work from an
/// annotated copy, which is flattened afresh.
pub(crate) fn build_array_compiled(
    file: &EsmFile,
    flattened: Option<&crate::flatten::FlattenedSystem>,
    runtime_array_parameters: bool,
    compiler: crate::Compiler,
) -> Result<crate::simulate_array::ArrayCompiled, SimulateError> {
    build_array(
        std::borrow::Cow::Borrowed(file),
        flattened,
        runtime_array_parameters,
        compiler,
    )
}

/// [`build_array_compiled`] over a borrowed or an owned document. An owned
/// one is consumed: dropped right after flattening on the coupled route, and
/// its single model moved into the compiled rules on the single-model route
/// ([`crate::simulate_array::ArrayCompiled::from_file_owned`]).
fn build_array(
    file: std::borrow::Cow<'_, EsmFile>,
    flattened: Option<&crate::flatten::FlattenedSystem>,
    runtime_array_parameters: bool,
    compiler: crate::Compiler,
) -> Result<crate::simulate_array::ArrayCompiled, SimulateError> {
    use crate::simulate_array::ArrayCompiled;
    use std::borrow::Cow;
    // Arm the document's whole precision environment for the build
    // (`crate::precision`) — its `domain.element_type` AND the per-variable
    // `element_type` overrides under it (esm-spec §11.3.1). These are public
    // entries that do not go through `EsmProblem`, and the compiled artifact
    // records the environment it folded its constants in. Re-arming what
    // `EsmProblem` already set is a no-op.
    let env = crate::precision_infer::env_of_file(&file).map_err(SimulateError::Compile)?;
    let _precision_guard = env.enter();
    // Under a per-variable element type the equations need their precision
    // boundaries marked before they are lowered, which means working from an
    // annotated COPY (`None`, and no copy at all, for every other document).
    let (file, flattened) =
        match crate::precision_infer::annotated(&file).map_err(SimulateError::Compile)? {
            Some(annotated) => (Cow::Owned(annotated), None),
            None => (file, flattened),
        };
    if !whole_document_is_one_model(&file) {
        refuse_coupled_subsystem_event(&file)?;
        let owned;
        let flat = match flattened {
            Some(flat) => flat,
            None => {
                owned = flatten(&file).map_err(CompileError::from)?;
                &owned
            }
        };
        drop(file);
        Ok(ArrayCompiled::from_flattened_with(
            flat,
            runtime_array_parameters,
            compiler,
        )?)
    } else {
        Ok(match file {
            Cow::Borrowed(file) => {
                ArrayCompiled::from_file_with(file, runtime_array_parameters, compiler)?
            }
            Cow::Owned(file) => {
                ArrayCompiled::from_file_owned_with(file, runtime_array_parameters, compiler)?
            }
        })
    }
}

/// Two-step entry point for array/spatial files: CONSUME the parsed
/// [`EsmFile`] and compile it into the array runtime's
/// [`crate::simulate_array::ArrayCompiled`], which the caller then solves
/// with [`crate::simulate_array::ArrayCompiled::solve`]. The one-shot
/// [`crate::problem::esm_problem`] borrows `file` and so keeps it alive for the
/// whole build; for a large expanded discretization the typed file is on the
/// order of the compiled rules themselves, and taking the file by value both
/// lets it die before
/// the solve AND lets the single-model build move the observed bodies into
/// the compiled rules instead of deep-copying them
/// ([`crate::simulate_array::ArrayCompiled::from_file_owned`]).
///
/// ```text
/// let compiled = compile_array(file)?;          // file is consumed here
/// let sol = compiled.solve(tspan, &params, &ics, &opts)?;
/// ```
///
/// Routing matches the one-shot entry points ([`build_array_compiled`]): a
/// coupled (multi-model) file is flattened first (the file is dropped right
/// after flattening); a single-model file compiles directly. Errors with
/// [`SimulateError`] if `file` has no array-op or spatial structure — a
/// pure-scalar file is built by [`crate::problem::esm_problem`], whose build
/// is cheap enough for it that a two-step split buys nothing.
pub fn compile_array(file: EsmFile) -> Result<crate::simulate_array::ArrayCompiled, SimulateError> {
    if !is_array_file(&file) {
        return Err(SimulateError::Compile(
            CompileError::InterpreterBuildError {
                details: "compile_array requires an array/spatial model (this file has none); \
                      use esm_problem for pure-scalar files"
                    .to_string(),
            },
        ));
    }
    build_array(
        std::borrow::Cow::Owned(file),
        None,
        false,
        crate::Compiler::Native,
    )
}
