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

    /// The flattened system still carries a spatial independent variable — a
    /// spatial operator that was never discretized into an `arrayop` stencil.
    /// Discretized PDEs fold their spatial axis into array dimensions, leaving
    /// `independent_variables == ["t"]`, and simulate fine.
    #[error(
        "Unsupported dimensionality {independent_variables:?}: the simulator integrates systems whose only independent variable is time (independent_variables == [\"t\"]). A remaining spatial independent variable means a spatial operator was not discretized — apply the discretization template (an `expression_templates` `match` rewrite) that lowers it to an `arrayop` stencil, then simulate. Discretized PDEs run natively in this backend."
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

    /// An evaluable-core operator (esm-spec §4.2) applied to the wrong number
    /// of arguments — e.g. `atan2` with one argument, or `min` with fewer than
    /// two. The schema cannot express per-operator arity (`args` is
    /// `minItems: 0`), so this is the gate that keeps a malformed-but-
    /// schema-valid node out of the evaluators, where it would otherwise either
    /// panic on an out-of-bounds index or — worse — be silently assigned two
    /// different values by the per-cell oracle and the vectorized overlay.
    /// See [`crate::op_registry`].
    #[error(
        "invalid_operator_arity: operator '{op}' takes {expected} argument(s), got {got} \
         (esm-spec §4.2)"
    )]
    InvalidOperatorArity {
        /// The offending operator name (e.g. `"atan2"`).
        op: String,
        /// How many arguments the node actually carried.
        got: usize,
        /// What the spec says the operator takes (e.g. `"exactly 2"`).
        expected: String,
    },

    /// A `makearray` node whose `regions` are malformed: either the regions
    /// disagree on rank (a ragged `regions` list), or a bound pair is inverted
    /// beyond the legal empty spelling. Per esm-spec §4.3.2 a pair with
    /// `stop == start - 1` is the canonical **empty** region and is legal;
    /// anything further inverted (`stop < start - 1`) is rejected with
    /// `makearray_region_inverted`.
    #[error("makearray_region_inverted: {reason} (esm-spec §4.3.2)")]
    MakearrayRegionInvalid {
        /// What is wrong with the regions.
        reason: String,
    },

    /// An evaluable-core operator (esm-spec §4.2) that this interpreter has no
    /// evaluation rule for reached the evaluator.
    ///
    /// These ops are legal in an AST but are *eliminated before* the per-cell
    /// evaluator ever runs: the build-time query ops (`skolem`, `rank`,
    /// `distinct`, `argmin`, `argmax`) are resolved by
    /// [`crate::value_invention`], and the form/lowering ops (`ic`, `true`,
    /// `enum`, `table_lookup`, `apply_expression_template`) are consumed by
    /// their respective lowering passes. One arriving at the evaluator means the
    /// pipeline is broken.
    ///
    /// It is reported rather than evaluated to a NaN sentinel: a silent NaN is
    /// indistinguishable from a legitimate numerical result and would propagate
    /// into the solution, whereas the pipeline stage that should have eliminated
    /// the op is the actual defect.
    #[error(
        "unevaluable_operator: operator '{op}' is an evaluable-core op with no evaluation rule \
         in the array interpreter — it must be eliminated by an earlier pipeline stage \
         (value invention, or a lowering pass) before evaluation (esm-spec §4.2)"
    )]
    UnevaluableOperatorError {
        /// The offending operator name (e.g. `"skolem"`).
        op: String,
    },

    /// The convenience constructors flattened the input first; that step
    /// failed.
    #[error("Flatten failed: {0}")]
    Flatten(#[from] FlattenError),
}
