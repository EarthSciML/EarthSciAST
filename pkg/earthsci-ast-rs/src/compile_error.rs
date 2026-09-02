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

    /// A `broadcast` node whose `fn` field is absent or does not name a scalar
    /// operator (esm-spec §4.3.4). `broadcast` is the one op whose OPERATOR is
    /// data — the node says `broadcast`, the arithmetic is named by a sibling
    /// string — and nothing used to check that string, so a typo'd or missing
    /// `fn` was silently evaluated as `+` (issue #101).
    #[error("invalid_broadcast_fn: {reason}")]
    InvalidBroadcastFn {
        /// Why the `fn` is rejected.
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

    /// `domain.element_type` names a precision this evaluator does not have.
    ///
    /// Reported rather than defaulted to binary64: a document that asks for a
    /// precision and silently gets a different one is the same class of defect
    /// as an `element_type` that is accepted and then ignored.
    #[error(
        "unsupported_element_type: domain.element_type '{element_type}' is not a precision this \
         evaluator implements — use \"Float64\" (the default) or \"Float32\" (esm-spec §11.3)"
    )]
    UnsupportedElementType {
        /// The offending `element_type` spelling.
        element_type: String,
    },

    /// A construct that cannot be evaluated in binary32 appears in a document
    /// declaring `domain.element_type: "Float32"`.
    ///
    /// The alternative — evaluating just that construct in binary64 — is a
    /// silent fallback: the document asked for one precision and part of the
    /// answer would be computed in another, with nothing in the result to say
    /// which part. So it is an error naming the construct.
    #[error(
        "float32_unsupported: {construct} cannot be evaluated under \
         `domain.element_type: \"Float32\"` — {reason}. Remove the construct, or evaluate the \
         document in Float64 (esm-spec §11.3)"
    )]
    Float32Unsupported {
        /// The offending construct, named (e.g. ``operator `intersect_polygon` ``).
        construct: String,
        /// Why binary32 cannot carry it.
        reason: String,
    },

    /// One operator's operands carry DIFFERENT declared element types
    /// (`ModelVariable.element_type`, esm-spec §11.3.1).
    ///
    /// Refused rather than resolved by a usual-arithmetic-conversions rule,
    /// because every resolution is a silent answer to a question only the
    /// author can settle. Widening to the wider operand makes a quantity
    /// declared binary32 come out binary64 — the declaration ignored, with
    /// nothing in the result to say so. Narrowing to the narrower destroys the
    /// binary64 operand, which is the very corruption per-variable element
    /// types exist to prevent (a ten-digit key rounded to binary32 collides
    /// with its neighbours). So the mix is an error naming both variables, and
    /// the author states the intent by computing the mixed step into a variable
    /// whose own `element_type` says which precision it is in.
    #[error(
        "mixed_element_type: operator '{op}' mixes operands of different element types — \
         {lhs_name} is {lhs_type} and {rhs_name} is {rhs_type}. One operator cannot be both; \
         neither widening nor narrowing is silently applied. Compute one side into a variable \
         whose own `element_type` states which precision that step lands in, then combine the \
         declared variables (esm-spec §11.3.1)"
    )]
    MixedElementType {
        /// The operator whose operands disagree (or `"equation"` for an
        /// equation whose right-hand side disagrees with its left-hand side).
        op: String,
        /// A variable supplying the first element type.
        lhs_name: String,
        /// That variable's element type.
        lhs_type: String,
        /// A variable supplying the conflicting element type.
        rhs_name: String,
        /// That variable's element type.
        rhs_type: String,
    },

    /// A BARE array-level expression whose operand is declared over an index
    /// set the result does not have (esm-spec §4.3.4).
    ///
    /// Operands of an array-level expression align by index-set NAME: an
    /// operand declared over a SUBSET of the result's index sets broadcasts
    /// along the ones it is missing. An operand carrying an index set the
    /// result does not carry has no axis to align to and no defensible value to
    /// take, so it is rejected rather than reinterpreted positionally — the
    /// positional flatten this replaces produced plausible, non-`NaN`,
    /// zero-padded garbage (issue #100).
    ///
    /// The shapes are fully known statically, so `validate()` reports the same
    /// defect as an `array_shape_mismatch` structural error before any build is
    /// attempted; this is the build-time backstop for a model compiled without
    /// being validated first.
    #[error(
        "array_shape_mismatch: operand '{operand}' of the array-level expression for '{result}' \
         is declared over index set '{axis}', which '{result}' (shape {result_axes:?}) does not \
         have — an operand's index sets must be a subset of the result's (esm-spec §4.3.4)"
    )]
    UnalignableArrayShape {
        /// The offending operand's variable name.
        operand: String,
        /// The index set the operand carries and the result does not.
        axis: String,
        /// The name of the array-level expression's result.
        result: String,
        /// The result's declared index sets, in declaration order.
        result_axes: Vec<String>,
    },

    /// The convenience constructors flattened the input first; that step
    /// failed.
    #[error("Flatten failed: {0}")]
    Flatten(#[from] FlattenError),
}

impl CompileError {
    /// Shorthand constructor for [`CompileError::InterpreterBuildError`], the
    /// catch-all build failure, whose `{ details: format!(…) }` spelling is
    /// otherwise repeated at every raise site.
    pub fn build_err(details: impl Into<String>) -> Self {
        CompileError::InterpreterBuildError {
            details: details.into(),
        }
    }
}
