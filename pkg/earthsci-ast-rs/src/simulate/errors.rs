use super::*;

// ============================================================================
// Errors
// ============================================================================

// `CompileError` is defined in the non-gated `crate::compile_error` module so
// the WASM-compiled `faq` / `join` passes can name it; re-exported here
// to preserve the native `crate::simulate::CompileError` path.
pub use crate::compile_error::CompileError;

/// Errors raised when running [`Compiled::simulate`] or the convenience
/// [`crate::problem::solve`] entry point.
#[derive(Error, Debug)]
pub enum SimulateError {
    /// Wraps a CompileError raised by [`crate::problem::esm_problem`]
    /// before solving even starts.
    #[error("Compile failed: {0}")]
    Compile(#[from] CompileError),

    /// diffsol returned a solver-internal error (build failure, step failure,
    /// etc.).
    #[error("diffsol error: {details}")]
    DiffsolError {
        /// The underlying diffsol error message.
        details: String,
    },

    /// The integrator could not satisfy the requested tolerances.
    #[error("Tolerance not met")]
    ToleranceNotMet,

    /// [`crate::problem::solve`] was called on a EsmProblem whose document
    /// declares no differential equations, so there is nothing to integrate.
    /// Its build-time products are still readable with
    /// [`crate::problem::observed_field`].
    #[error("Nothing to integrate: {details}")]
    NotDynamic {
        /// Why the EsmProblem carries no integrable right-hand side.
        details: String,
    },

    /// A build progress observer asked [`crate::problem::esm_problem`] to
    /// stop (returned [`Flow::Cancel`]).
    ///
    /// Distinct from every other variant in that nothing went wrong: it is the
    /// caller's own decision. It stays an ERROR — unlike a cancelled *solve*,
    /// which is [`ReturnCode::Terminated`] with a partial trajectory — because a
    /// half-built EsmProblem is not a usable result.
    #[error("Cancelled by the caller during the build: {details}")]
    Cancelled {
        /// The phase and item the build stopped at.
        details: String,
    },

    /// [`crate::problem::remake`] was asked to substitute a binding the
    /// EsmProblem cannot honour without redoing part of construction.
    ///
    /// Raised rather than silently rebuilding or silently ignoring the
    /// substitution (`esm-libraries-spec.md` §2.5.5): the name and the class
    /// that makes it un-substitutable are both reported so the caller knows to
    /// build a fresh EsmProblem instead.
    #[error("Cannot remake '{name}': {class}")]
    UnsubstitutableBinding {
        /// The binding the caller tried to substitute.
        name: String,
        /// The class that makes it un-substitutable.
        class: String,
    },

    /// The user supplied a parameter name that does not appear in the
    /// flattened system.
    #[error("Invalid parameter '{name}'")]
    InvalidParameter {
        /// The unknown parameter name.
        name: String,
    },

    /// The user supplied a key that two or more of the flattened system's
    /// parameters carry as a DOTTED SUFFIX — a shared local name (`gain` for
    /// `Left.gain` and `Right.gain`) or a shared partial qualification
    /// (`sub.g` for `Left.sub.g` and `Right.sub.g`), esm-spec §6.6.2 rule 4.
    /// Distinct from [`SimulateError::InvalidParameter`]: the name exists, it
    /// just does not identify ONE parameter, and binding it to either
    /// candidate would be a wrong answer rather than a missing one.
    #[error(
        "Ambiguous parameter '{name}': carried as a suffix by {candidates:?} — qualify it further with its owning component"
    )]
    AmbiguousParameter {
        /// The ambiguous local or partially qualified name.
        name: String,
        /// The qualified parameters that carry it.
        candidates: Vec<String>,
    },

    /// Two or more NON-EXACT `parameter_overrides` keys designate the one
    /// flattened parameter (esm-spec §6.6.2): a bare local spelling and a
    /// more-qualified one (`solo` and `Doc.Left.solo` both landing on
    /// `Left.solo`), or two more-qualified ones (`A.M.g` and `B.M.g` both
    /// landing on `M.g`). The caller wrote two overrides and only one can take
    /// effect, so picking a winner would be a wrong answer rather than a
    /// missing one. An EXACT key is never part of a collision — it identifies
    /// its parameter outright and wins over any suffix or bare claim on it.
    #[error(
        "parameter_overrides: {} keys designate the parameter '{name}' ({}). Supply exactly one override key per name (esm-spec §6.6.2).",
        .keys.len(), .keys.join(", ")
    )]
    CollidingParameterKeys {
        /// The flattened parameter every colliding key designates.
        name: String,
        /// The colliding keys, sorted.
        keys: Vec<String>,
    },

    /// The user supplied an initial condition for a name that is not a state
    /// variable, or a state variable has no initial value (no entry in
    /// `initial_conditions` and no `default` on the `ModelVariable`).
    #[error("Invalid initial condition '{name}'")]
    InvalidInitialCondition {
        /// The variable name.
        name: String,
    },

    /// The user supplied a key that two or more of the flattened system's
    /// states carry as a DOTTED SUFFIX (esm-spec §6.6.2 rule 4). The
    /// state-side counterpart of [`SimulateError::AmbiguousParameter`].
    #[error(
        "Ambiguous initial condition '{name}': carried as a suffix by {candidates:?} — qualify it further with its owning component"
    )]
    AmbiguousInitialCondition {
        /// The ambiguous local or partially qualified name.
        name: String,
        /// The qualified states that carry it.
        candidates: Vec<String>,
    },

    /// Two or more NON-EXACT `initial_conditions` keys designate the one state
    /// element (esm-spec §6.6.2). The state-side counterpart of
    /// [`SimulateError::CollidingParameterKeys`].
    #[error(
        "initial_conditions: {} keys designate the state '{name}' ({}). Supply exactly one override key per name (esm-spec §6.6.2).",
        .keys.len(), .keys.join(", ")
    )]
    CollidingInitialConditionKeys {
        /// The state element every colliding key designates.
        name: String,
        /// The colliding keys, sorted.
        keys: Vec<String>,
    },

    /// An `ic(target)` field initial condition could not be resolved to a
    /// per-cell value. Carries the `ic(...)` target state name plus a
    /// diagnostic saying why (wrong field rank, unresolvable RHS, ...), so
    /// the name field stays a plain identifier.
    #[error("Invalid field initial condition for '{name}': {details}")]
    InvalidFieldInitialCondition {
        /// The `ic(...)` target state name.
        name: String,
        /// Why the initial condition could not be resolved.
        details: String,
    },

    /// A data provider bound in [`crate::problem::ProblemOptions`] failed to
    /// materialize its loader field, or produced the wrong number of fields for
    /// its target forcing variable.
    #[error("Provider for '{name}': {details}")]
    ProviderError {
        /// The forcing variable the provider was bound to.
        name: String,
        /// What went wrong.
        details: String,
    },
}

impl SimulateError {
    /// Whether this is a build progress observer's own [`Flow::Cancel`] rather
    /// than something going wrong — the counterpart of reading
    /// [`ReturnCode::Terminated`] off a [`Solution`].
    pub fn is_cancelled(&self) -> bool {
        matches!(self, SimulateError::Cancelled { .. })
    }
}
