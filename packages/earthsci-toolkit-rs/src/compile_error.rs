//! Build-time error type shared by the simulate pipeline and the non-gated
//! `aggregate` / `join` resolution passes.
//!
//! [`CompileError`] lives in its own module rather than inside `simulate`
//! because `simulate` (and `simulate_array`) are `#[cfg(not(target_arch =
//! "wasm32"))]` — they pull in the native ODE backend. The `aggregate` and
//! `join` modules surface build-time resolution failures as `CompileError`
//! but are compiled on every target, including `wasm32-unknown-unknown`.
//! Keeping the type here lets those modules compile for WASM while `simulate`
//! re-exports it unchanged for the native API (`crate::simulate::CompileError`).

use crate::flatten::FlattenError;
use thiserror::Error;

/// Errors raised when building a compiled model from a flattened system.
#[derive(Error, Debug)]
pub enum CompileError {
    /// The flattened system contains a feature the v1 simulator does not support
    /// (e.g. continuous or discrete events).
    #[error("Unsupported feature '{feature}': {message}")]
    UnsupportedFeatureError {
        /// Feature name (e.g. `"continuous_events"`).
        feature: String,
        /// Why this is rejected and what to do about it.
        message: String,
    },

    /// The flattened system has independent variables other than `["t"]`
    /// (i.e. is a hybrid spatial / temporal system, not a pure ODE).
    #[error(
        "Unsupported dimensionality {independent_variables:?}: v1 only supports pure ODEs (independent_variables == [\"t\"]). Spatial / hybrid systems require the future Rust PDE bead."
    )]
    UnsupportedDimensionalityError {
        /// The actual independent variables found.
        independent_variables: Vec<String>,
    },

    /// The interpreter could not build a callable representation of the
    /// flattened equations.
    #[error("Interpreter build failed: {details}")]
    InterpreterBuildError {
        /// Human-readable failure description.
        details: String,
    },

    /// A spatial differential operator (`grad`, `div`, `laplacian`, ...) was
    /// found in an equation reaching the simulator. Per the canonical
    /// pipeline contract, ESD discretization rules MUST rewrite these into
    /// `arrayop` AST before any binding's simulator evaluates the equations.
    /// Encountering one here means `discretize` was skipped or did not
    /// rewrite this node — silently producing zeros (the previous behavior)
    /// would mask a broken pipeline. (esm-i7b)
    #[error(
        "UnreachableSpatialOperatorError: encountered '{op}' node in simulation evaluation. \
         Spatial operators must be rewritten by ESD discretization rules before reaching the \
         simulator. Pipeline contract violated."
    )]
    UnreachableSpatialOperatorError {
        /// The offending operator name (e.g. `"grad"`).
        op: String,
    },

    /// The convenience constructors flattened the input first; that step
    /// failed.
    #[error("Flatten failed: {0}")]
    Flatten(#[from] FlattenError),
}
