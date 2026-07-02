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

    /// A rewrite-target operator (a spatial / right-hand-side `D`, or the
    /// optional sugar ops `grad` / `div` / `laplacian` / ...) survived the
    /// lowering fixpoint into an evaluation position (esm-spec §4.2 / §9.6.8).
    /// Such ops carry NO evaluator: a discretization `match` rewrite rule MUST
    /// lower them to an `aggregate` / `makearray` stencil before evaluation.
    /// The gate fires here — before evaluation, not at load — with the uniform
    /// `unlowered_operator` code that supersedes the former per-binding
    /// `UnreachableSpatialOperatorError` / `UnsupportedDimensionality` errors.
    /// Silently producing zeros (the previous behavior) would mask a broken
    /// pipeline. This format ships no discretization rules — they live in
    /// EarthSciDiscretizations.
    #[error(
        "unlowered_operator: rewrite-target operator '{op}' reached evaluation without being \
         lowered to a stencil by a rewrite rule (esm-spec §4.2 / §9.6.8). Discretization rules \
         live in EarthSciDiscretizations, not this format."
    )]
    UnloweredOperatorError {
        /// The offending operator name (e.g. `"grad"` or `"D"`).
        op: String,
    },

    /// The convenience constructors flattened the input first; that step
    /// failed.
    #[error("Flatten failed: {0}")]
    Flatten(#[from] FlattenError),
}
