//! Core type definitions for the ESM format
//!
//! This module provides Rust types that correspond to the ESM JSON Schema.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Top-level ESM file structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EsmFile {
    /// Format version string (semver)
    pub esm: String,

    /// Authorship, provenance, description
    pub metadata: Metadata,

    /// Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2,
    /// v0.8.0). A single registry shared by every model in the document; it
    /// unifies grid dims and categorical index sets and is referenced from
    /// `aggregate`/`arrayop` `ranges` via `{ "from": <name> }` and from
    /// variable `shape`s. Declared once at the document top level (a sibling of
    /// `models`/`domain`), no longer per-`Model`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index_sets: Option<HashMap<String, IndexSet>>,

    /// ODE-based model components, keyed by unique identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub models: Option<HashMap<String, Model>>,

    /// Reaction network components, keyed by unique identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reaction_systems: Option<HashMap<String, ReactionSystem>>,

    /// External data source registrations (by reference)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data_loaders: Option<HashMap<String, DataLoader>>,

    /// Registered runtime operators (by reference)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operators: Option<HashMap<String, Operator>>,

    /// File-local enum declarations (esm-spec §9.3): each entry maps a
    /// symbolic name to a positive integer. The `enum` AST op resolves to a
    /// `const` integer at load time using these mappings.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enums: Option<HashMap<String, HashMap<String, i64>>>,

    /// Composition and coupling rules
    #[serde(skip_serializing_if = "Option::is_none")]
    pub coupling: Option<Vec<CouplingEntry>>,

    /// The single temporal domain shared by every component in the document
    /// (v0.8.0). A document has at most one domain; all spatial models live on
    /// it, and 0-D models simply have scalar-shaped variables. Spatiality is
    /// determined by variable shape, not by a per-component domain reference.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub domain: Option<Domain>,

    /// Component-scoped sampled function tables (esm-spec §9.5, v0.4.0).
    /// Keys are table ids; values are `FunctionTable` entries referenced by
    /// `table_lookup` AST nodes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub function_tables: Option<HashMap<String, FunctionTable>>,
}

/// A single named axis inside a [`FunctionTable`] (esm-spec §9.5).
///
/// `values` MUST be strictly-increasing finite floats with at least 2 entries
/// (mirrors the §9.2 interp.linear / interp.bilinear axis contract). `units`
/// is advisory only in v0.4.0 — recorded for documentation, not used for
/// load-time unit-checking.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FunctionTableAxis {
    /// Axis identifier; used as the key in `table_lookup.axes`.
    pub name: String,

    /// Strictly-increasing finite floats, ≥ 2 entries.
    pub values: Vec<f64>,

    /// Optional advisory units string.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,
}

/// A sampled function table referenced by `table_lookup` AST op nodes
/// (esm-spec §9.5, v0.4.0).
///
/// Tables are syntactic sugar over §9.2's `interp.linear` / `interp.bilinear`
/// / `index` — a `table_lookup` query MUST be bit-equivalent to the
/// equivalent inline-`const` lookup. Shape of `data` is
/// `[len(outputs), len(axes[0].values), len(axes[1].values), ...]` when
/// `outputs` is `Some`; `[len(axes[0].values), ...]` otherwise.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FunctionTable {
    /// Ordered list of named axes (1 or 2 in v0.4.0, matching the
    /// `interp.linear` / `interp.bilinear` arity).
    pub axes: Vec<FunctionTableAxis>,

    /// Nested-array literal of finite numbers.
    pub data: serde_json::Value,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// `"linear"` | `"bilinear"` | `"nearest"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interpolation: Option<String>,

    /// `"clamp"` | `"error"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out_of_bounds: Option<String>,

    /// Optional ordered output names.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outputs: Option<Vec<String>>,

    /// Optional redundant shape assertion.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shape: Option<Vec<u64>>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schema_version: Option<String>,
}

/// Academic citation or data source reference
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reference {
    /// DOI identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub doi: Option<String>,

    /// Full citation text
    #[serde(skip_serializing_if = "Option::is_none")]
    pub citation: Option<String>,

    /// URL reference
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,

    /// Additional notes
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

/// Metadata section
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Metadata {
    /// Human-readable model name
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Authors/contributors
    #[serde(skip_serializing_if = "Option::is_none")]
    pub authors: Option<Vec<String>>,

    /// License information
    #[serde(skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,

    /// Creation timestamp (ISO 8601)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created: Option<String>,

    /// Last modification timestamp (ISO 8601)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified: Option<String>,

    /// Tags for categorization
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,

    /// Academic citations and references
    #[serde(skip_serializing_if = "Option::is_none")]
    pub references: Option<Vec<Reference>>,

    /// System classification stamped by `discretize()` per RFC §12:
    /// `"ode"` if no algebraic equations remain after discretization,
    /// `"dae"` if any algebraic equations remain. Absent on undiscretized
    /// inputs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_class: Option<String>,

    /// DAE classification details stamped by `discretize()` per RFC §12.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dae_info: Option<DaeInfo>,

    /// Provenance stamp: the `metadata.name` of the input ESM that
    /// `discretize()` was called on. Absent on undiscretized inputs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discretized_from: Option<String>,
}

/// Summary of DAE classification stamped onto `metadata.dae_info` by
/// `discretize()` per RFC §12.
///
/// `algebraic_equation_count` is the post-`discretize()` total across all
/// models; `per_model` breaks it down by model name. `factored_equation_count`
/// is rust-binding-specific — it reports the number of trivially
/// substitutable algebraic equations the preprocessor eliminated before
/// classification (see `docs/rfcs/dae-binding-strategies.md`). `0` on
/// bindings that do not perform trivial factoring.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct DaeInfo {
    /// Total algebraic equations remaining after `discretize()` completes.
    pub algebraic_equation_count: usize,

    /// Per-model count, keyed by model name.
    pub per_model: HashMap<String, usize>,

    /// rust-binding-specific: number of trivially substitutable algebraic
    /// equations factored into the ODE system by the preprocessor. `None`
    /// on bindings that do not factor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub factored_equation_count: Option<usize>,
}

/// Mathematical expression: a number literal, variable reference, or operator node.
///
/// Per discretization RFC §5.4.1, integer and float literals are distinct AST
/// node kinds. On the wire (§5.4.6 round-trip parse rule), a JSON-number
/// token containing `.`, `e`, or `E` deserializes to [`Expr::Number`]; a token
/// matching the integer grammar `-?(0|[1-9][0-9]*)` deserializes to
/// [`Expr::Integer`]. `#[serde(untagged)]` tries variants in order; `Integer`
/// appears before `Number` so that the strict integer JSON tokens bind to
/// `Integer` and float tokens fall through to `Number`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
#[allow(clippy::large_enum_variant)]
pub enum Expr {
    /// Integer literal (JSON integer token, no `.`, no `e`/`E`).
    Integer(i64),

    /// Float literal (JSON number token with `.`, `e`, or `E`).
    Number(f64),

    /// Variable or parameter reference string
    Variable(String),

    /// Operator node with children
    Operator(ExpressionNode),
}

/// Expression node representing an operator with operands
/// A single `arrayop`/`aggregate` index range (RFC semiring-faq-unified-ir
/// §5.2). Either a dense inclusive integer interval `[lo, hi]` (the original,
/// and still the most common form) or a reference to a declared index set.
///
/// Index-set references are resolved to concrete `[lo, hi]` intervals against
/// the document `index_sets` registry by
/// [`crate::aggregate::resolve_aggregate_ranges`] before the evaluator runs, so
/// every range the evaluator actually iterates is a [`RangeSpec::Interval`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RangeSpec {
    /// Dense inclusive integer interval `[lo, hi]`.
    Interval([i64; 2]),
    /// Reference to a declared index set by name, optionally ragged/dependent
    /// (`of` names the parent index variables, e.g. the edges *of* cell `i`).
    IndexSetRef {
        /// Key into the model `index_sets` registry.
        from: String,
        /// Parent index variables for a ragged/dependent inner set.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        of: Option<Vec<String>>,
    },
    /// A resolved **ragged** inner range (RFC `semiring-faq-unified-ir` §5.2):
    /// the lower bound is implicitly `1` and the upper bound is the per-parent
    /// length `offsets[of…]`, gathered dynamically per output tuple at eval
    /// time. Produced only by [`crate::aggregate::resolve_aggregate_ranges`] on
    /// the simulation clone (it bakes the index set's `offsets` backing-factor
    /// name into the range so the evaluator needs no registry); it is never
    /// authored in or serialized back to a file, so it appears **last** in this
    /// untagged enum and existing `[lo,hi]` / `{from}` inputs still parse to
    /// `Interval` / `IndexSetRef` exactly as before.
    RaggedDyn {
        /// Name of the keyed factor giving `|set(of…)|` for each parent tuple.
        offsets: String,
        /// Parent index variables whose bound values address `offsets`.
        of: Vec<String>,
    },
    /// A resolved **derived** (FAQ-materialized) inner range (RFC
    /// `semiring-faq-unified-ir` §5.5 / §8.1): the lower bound is implicitly `1`
    /// and the upper bound is the data-dependent vertex count of the ring its
    /// producing FAQ node materialized at runtime, looked up by that node's id
    /// (`from_faq`). Produced only by [`crate::aggregate::resolve_aggregate_ranges`]
    /// on the simulation clone (it bakes the producer's id into the range so the
    /// evaluator needs no registry); like [`RangeSpec::RaggedDyn`] it is never
    /// authored in or serialized back to a file, so it appears **last** in this
    /// untagged enum (no authored range carries a `from_faq` field, so existing
    /// `[lo,hi]` / `{from}` inputs still parse to `Interval` / `IndexSetRef`).
    DerivedDyn {
        /// FAQ producer node id (the `intersect_polygon` clip's `id`) whose
        /// materialized overlap ring sizes this contraction at eval time.
        from_faq: String,
    },
}

impl RangeSpec {
    /// The concrete `[lo, hi]` bounds if this range is (or has been resolved
    /// to) a dense interval; `None` for an unresolved index-set reference or a
    /// dynamic (ragged / derived) range whose upper bound is only known per
    /// output tuple / after the producing FAQ node runs.
    pub fn bounds(&self) -> Option<[i64; 2]> {
        match self {
            RangeSpec::Interval(iv) => Some(*iv),
            RangeSpec::IndexSetRef { .. }
            | RangeSpec::RaggedDyn { .. }
            | RangeSpec::DerivedDyn { .. } => None,
        }
    }

    /// The `(offsets-factor-name, parent-index-names)` pair if this is a
    /// resolved ragged range; `None` otherwise. The evaluator uses this to
    /// compute the dynamic per-output-tuple upper bound `offsets[of…]`.
    pub fn ragged(&self) -> Option<(&str, &[String])> {
        match self {
            RangeSpec::RaggedDyn { offsets, of } => Some((offsets.as_str(), of.as_slice())),
            _ => None,
        }
    }

    /// The FAQ producer node id if this is a resolved derived range; `None`
    /// otherwise. The evaluator uses it to look up the materialized ring's
    /// vertex count (RFC §8.1) as the dynamic upper bound of the contraction.
    pub fn derived(&self) -> Option<&str> {
        match self {
            RangeSpec::DerivedDyn { from_faq } => Some(from_faq.as_str()),
            _ => None,
        }
    }
}

/// One value-equality join clause on an `aggregate`/`arrayop` node (RFC
/// semiring-faq-unified-ir §5.3). `on` lists one or more `[left, right]`
/// key-column pairs; a combined ⊗-product term is contributed only for index
/// combinations whose key columns are equal on **every** listed pair (an inner
/// equi-join). At least one pair is required and each pair is exactly length-2
/// (enforced by the schema). Resolved at build time by
/// [`crate::join::resolve_aggregate_joins`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JoinClause {
    /// The `[left, right]` key-column pairs to equi-join on.
    pub on: Vec<[String; 2]>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ExpressionNode {
    /// Operator name (e.g., "+", "-", "*", "/", "sin", "cos", etc.)
    pub op: String,

    /// Operand expressions
    pub args: Vec<Expr>,

    /// Differentiation variable (for derivatives)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wrt: Option<String>,

    /// Dimensional analysis hint; also names the spatial dimension a `grad` /
    /// `aggregate` op iterates over.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dim: Option<String>,

    /// Integration variable name for the `integral` op (spatial dimension being integrated over).
    /// Serialized under JSON key `var`. Required when op is "integral".
    #[serde(default, rename = "var", skip_serializing_if = "Option::is_none")]
    pub int_var: Option<String>,

    /// Lower integration bound for the `integral` op (any `Expr`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lower: Option<Box<Expr>>,

    /// Upper integration bound for the `integral` op (any `Expr`). May be the
    /// integration variable itself (a string) for a cumulative/partial integral.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upper: Option<Box<Expr>>,

    /// Body expression for `arrayop` nodes (the scalar body evaluated for
    /// each tuple of loop-index values). Out-of-band from `args` because the
    /// serialized schema uses a sidecar `expr` field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expr: Option<Box<Expr>>,

    /// Output index names for `arrayop` (e.g. `["i", "j"]`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_idx: Option<Vec<String>>,

    /// Per-index ranges for `arrayop`/`aggregate`. Each entry is either a dense
    /// inclusive integer interval `[lo, hi]` (the original form) or a reference
    /// to a declared index set, `{ "from": <name>, "of"?: [...] }` (RFC
    /// semiring-faq-unified-ir §5.2). Index-set references are resolved to
    /// concrete intervals against the model `index_sets` registry by
    /// [`crate::aggregate::resolve_aggregate_ranges`] before evaluation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ranges: Option<HashMap<String, RangeSpec>>,

    /// Reduction operator (`"+"`, `"*"`, `"max"`, `"min"`) for `arrayop`
    /// contractions over indices appearing in `expr` but not `output_idx`.
    /// Names the semiring's ⊕ only; see `semiring` for the full algebra.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reduce: Option<String>,

    /// Named semiring `(⊕, ⊗)` for `aggregate`/`arrayop` reductions (RFC
    /// semiring-faq-unified-ir §5.1). One of `sum_product` (default),
    /// `max_product`, `min_sum`, `max_sum`, `bool_and_or`. When present it is
    /// authoritative: ⊕ (the `reduce`) and both identities come from the closed
    /// registry table, never the file. Absent ⇒ today's `reduce`-string
    /// behavior (strict superset).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub semiring: Option<String>,

    /// Value-equality `join` clauses for `aggregate`/`arrayop` (RFC
    /// semiring-faq-unified-ir §5.3). An inner equi-join combining factors by
    /// the value equality of key columns, subsuming ESI `join`. Each clause's
    /// `on` lists `[left, right]` key-column pairs; absent ⇒ factors combine
    /// only by shared index name (positional einsum), exactly as today.
    /// Resolved at build time by [`crate::join::resolve_aggregate_joins`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub join: Option<Vec<JoinClause>>,

    /// Boolean predicate restricting which index combinations contribute a
    /// ⊗-product term to an `aggregate`/`arrayop` reduction (RFC
    /// semiring-faq-unified-ir §5.3 / §7.2). Combinations for which the
    /// predicate evaluates false contribute the additive identity `0̄` — the
    /// explicit way to express a guarded sum. May reference any index symbol in
    /// scope. Absent ⇒ every combination contributes (today's behavior).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter: Option<Box<Expr>>,

    /// Per-region per-dimension inclusive range lists for `makearray`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub regions: Option<Vec<Vec<[i64; 2]>>>,

    /// Per-region value expressions for `makearray`. Later regions overwrite
    /// earlier regions at overlapping positions.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<Vec<Expr>>,

    /// Target shape for `reshape`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shape: Option<Vec<i64>>,

    /// Permutation for `transpose` (defaults to reverse-axis for 2-D).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub perm: Option<Vec<i64>>,

    /// Concatenation axis for `concat` (0-indexed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub axis: Option<i64>,

    /// Elementwise operator name for `broadcast` (serialized as `fn`).
    #[serde(default, rename = "fn", skip_serializing_if = "Option::is_none")]
    pub broadcast_fn: Option<String>,

    /// For the `fn` op: dotted module path of the closed-registry function to
    /// invoke (esm-spec §4.4 / §9.2). Also used by the `enum` op (§4.5) when
    /// authors prefer a named-form `name`/symbol pair, though the canonical
    /// encoding for `enum` is positional `args`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// For the `const` op: inline literal value (any JSON number, integer,
    /// or nested array thereof). `args` MUST be empty when this is set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<serde_json::Value>,

    /// For the `table_lookup` op (esm-spec §9.5, v0.4.0): the
    /// `function_tables` entry id this node references. ``args`` MUST be
    /// empty for a `table_lookup` node — the per-axis input expressions live
    /// in `axes`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub table: Option<String>,

    /// For the `table_lookup` op: per-axis input-coordinate expression map.
    /// Keys MUST match the axis names declared on the referenced
    /// `FunctionTable`; values are arbitrary scalar `Expr`s. Stored under
    /// the JSON key `axes` on the wire.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub axes: Option<HashMap<String, Expr>>,

    /// For the `table_lookup` op: which output of a multi-output table to
    /// return. Either a non-negative integer index (0-based) or a string
    /// (entry of the table's `outputs` list). Single-output tables MAY omit
    /// this (defaults to 0 at lowering time).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<serde_json::Value>,

    /// Stable node id for value-invention (M3 / RFC semiring-faq-unified-ir
    /// §5.2, §8.1). A node that produces a data-dependent index set — a
    /// `distinct` aggregate, or an `intersect_polygon` clip whose overlap ring
    /// has data-dependent length — carries an `id`, and an `index_sets` entry
    /// with `kind:"derived"` references it via `from_faq`. Preserved through
    /// canonicalization so the producer↔derived-set linkage survives.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,

    /// Geometry manifold for the `intersect_polygon` op — one of `planar`,
    /// `spherical`, or `geodesic` (RFC semiring-faq-unified-ir §8.1;
    /// CONFORMANCE_SPEC.md §5.8.4). REQUIRED on every `intersect_polygon` node
    /// (the schema gives it no default): the geometric interpretation is part of
    /// the op's contract — `spherical`/`geodesic` clip along great-circle edges,
    /// `planar` along straight lon/lat edges — and two bindings may be compared
    /// only under the same declared manifold.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manifold: Option<String>,
}

/// Numerical comparison tolerance used by inline model tests.
///
/// Either or both of `abs` / `rel` may be set. An assertion passes when any
/// set bound is satisfied:
/// `|actual - expected| <= abs`  OR
/// `|actual - expected| / max(|expected|, epsilon) <= rel`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tolerance {
    /// Absolute tolerance bound.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub abs: Option<f64>,

    /// Relative tolerance bound.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rel: Option<f64>,
}

/// Simulation time interval used by inline model tests.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TimeSpan {
    /// Start of the simulation window (in the component's time units).
    pub start: f64,

    /// End of the simulation window (in the component's time units).
    pub end: f64,
}

/// A single scalar `(variable, time, expected)` check inside a [`ModelTest`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelTestAssertion {
    /// Name of the variable or species to check.
    pub variable: String,

    /// Simulation time at which to evaluate the assertion.
    pub time: f64,

    /// Expected scalar value of the variable at the given time.
    pub expected: f64,

    /// Per-assertion tolerance override. Takes precedence over test-level
    /// and model-level defaults when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tolerance: Option<Tolerance>,
}

/// Inline validation test for a [`Model`] (schema gt-cc1).
///
/// Defines the run configuration — initial conditions, parameter overrides,
/// simulation time span — and a list of scalar assertions that must hold.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelTest {
    /// Identifier unique within this component's `tests` array.
    pub id: String,

    /// Human-readable description of what this test verifies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Initial-value overrides for state variables, keyed by variable name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initial_conditions: Option<HashMap<String, f64>>,

    /// Parameter overrides, keyed by parameter name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parameter_overrides: Option<HashMap<String, f64>>,

    /// Simulation time interval for this test.
    pub time_span: TimeSpan,

    /// Test-level default tolerance applied to assertions that do not
    /// override it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tolerance: Option<Tolerance>,

    /// Scalar `(variable, time)` checks that define the pass/fail criterion.
    pub assertions: Vec<ModelTestAssertion>,
}

/// A document-scoped index set declared in a model's `index_sets` registry
/// (RFC semiring-faq-unified-ir §5.2 / §8). Unifies ESM `domain.spatial` grid
/// dims and ESI categorical index sets under one shape. `kind` selects which
/// optional fields are meaningful (enforced by the schema's kind-conditional
/// `allOf`):
/// - `interval`    → `size`
/// - `categorical` → `members`
/// - `derived`     → `from_faq`
/// - `ragged`      → `of`, `offsets`, `values`
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IndexSet {
    /// `"interval" | "categorical" | "derived" | "ragged"`.
    pub kind: String,

    /// Dense size for `kind: "interval"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<i64>,

    /// Enumerated members for `kind: "categorical"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub members: Option<Vec<serde_json::Value>>,

    /// Source FAQ-node id for `kind: "derived"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_faq: Option<String>,

    /// Parent index sets for `kind: "ragged"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub of: Option<Vec<String>>,

    /// CSR/length backing-factor name for `kind: "ragged"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offsets: Option<String>,

    /// Member backing-factor name for `kind: "ragged"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<String>,
}

/// ODE-based model component
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Model {
    /// Human-readable model name
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// Coupling type label
    #[serde(skip_serializing_if = "Option::is_none")]
    pub coupletype: Option<String>,

    /// Academic citation or data source reference
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,

    /// State variables, parameters, and observed quantities (keyed by name)
    pub variables: HashMap<String, ModelVariable>,

    /// Differential equations
    pub equations: Vec<Equation>,

    /// Discrete events
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discrete_events: Option<Vec<DiscreteEvent>>,

    /// Continuous events
    #[serde(skip_serializing_if = "Option::is_none")]
    pub continuous_events: Option<Vec<ContinuousEvent>>,

    /// Named child models (subsystems), keyed by unique identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subsystems: Option<HashMap<String, serde_json::Value>>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Model-level default numerical tolerance for inline tests.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tolerance: Option<Tolerance>,

    /// Inline validation tests that exercise this model in isolation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tests: Option<Vec<ModelTest>>,

    /// Equations that hold only at t=0 (initialization-only, not time-stepped).
    /// Introduced for aerosol equilibrium / plume-rise style models (gt-ebuq).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initialization_equations: Option<Vec<Equation>>,

    /// Initial-guess seeds for nonlinear solvers during initialization, keyed
    /// by variable name. Values may be numeric literals or Expression graphs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub guesses: Option<HashMap<String, serde_json::Value>>,

    /// MTK system-kind discriminator: "ode" (default), "nonlinear", "sde", "pde".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system_kind: Option<String>,
}

/// Variable within a model
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelVariable {
    /// Variable type
    #[serde(rename = "type")]
    pub var_type: VariableType,

    /// Physical units
    #[serde(skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,

    /// Default/initial value
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<f64>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Defining expression for observed variables
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expression: Option<Expr>,

    /// Arrayed-variable shape: ordered dimension names drawn from the
    /// enclosing model's domain.spatial. `None` means scalar.
    /// See discretization RFC §10.2.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shape: Option<Vec<String>>,

    /// Staggered-grid location tag (e.g., "cell_center", "edge_normal",
    /// "vertex"). `None` means no explicit staggering.
    /// See discretization RFC §10.2.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub location: Option<String>,

    /// Brownian-only: kind of stochastic process. Currently only "wiener".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub noise_kind: Option<String>,

    /// Brownian-only: opaque tag grouping correlated noise sources.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub correlation_group: Option<String>,
}

/// Type of model variable
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VariableType {
    /// State variable (appears in d/dt equations)
    State,
    /// Parameter (constant)
    Parameter,
    /// Observed quantity (computed from state/parameters)
    Observed,
    /// Brownian noise source (Wiener process). The presence of any brownian
    /// variable promotes the enclosing model from an ODE system to an SDE
    /// system. Maps to MTK `@brownians` and an `SDESystem`.
    Brownian,
}

/// Differential equation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Equation {
    /// Left-hand side expression
    pub lhs: Expr,

    /// Right-hand side expression
    pub rhs: Expr,
}

impl Default for Equation {
    fn default() -> Self {
        Equation {
            lhs: Expr::Integer(0),
            rhs: Expr::Integer(0),
        }
    }
}

/// Discrete event that can modify the system
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscreteEvent {
    /// Human-readable identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// When the event fires
    pub trigger: DiscreteEventTrigger,

    /// What happens when the event fires
    #[serde(skip_serializing_if = "Option::is_none")]
    pub affects: Option<Vec<AffectEquation>>,

    /// Functional affect specification
    #[serde(skip_serializing_if = "Option::is_none")]
    pub functional_affect: Option<FunctionalAffect>,

    /// Parameters modified by this event
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discrete_parameters: Option<Vec<String>>,

    /// Whether to reinitialize the system after the event
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reinitialize: Option<bool>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Trigger condition for discrete events
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[allow(clippy::large_enum_variant)]
pub enum DiscreteEventTrigger {
    /// Fires when boolean condition is true
    Condition { expression: Expr },
    /// Fires at regular intervals
    Periodic {
        /// Interval in simulation time units
        interval: f64,
        /// Offset from t=0 for first firing
        #[serde(skip_serializing_if = "Option::is_none")]
        initial_offset: Option<f64>,
    },
    /// Fires at preset times
    PresetTimes {
        /// Array of simulation times at which to fire
        times: Vec<f64>,
    },
}

/// Equation that modifies state/parameters when event fires
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AffectEquation {
    /// Left-hand side (variable to modify)
    pub lhs: String,

    /// Right-hand side (new value expression)
    pub rhs: Expr,
}

/// Continuous event that fires on zero-crossings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContinuousEvent {
    /// Human-readable identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// Condition expressions (zero-crossing detection)
    pub conditions: Vec<Expr>,

    /// What happens when the event fires on positive-going zero crossings
    pub affects: Vec<AffectEquation>,

    /// Separate affects for negative-going zero crossings
    #[serde(skip_serializing_if = "Option::is_none")]
    pub affect_neg: Option<Vec<AffectEquation>>,

    /// Root finding direction
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_find: Option<RootFindDirection>,

    /// Whether to reinitialize the system after the event
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reinitialize: Option<bool>,

    /// Parameters modified by this event
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discrete_parameters: Option<Vec<String>>,

    /// Event priority (lower number = higher priority)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<u32>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Functional affect specification for events
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionalAffect {
    /// Registered identifier for the affect implementation
    pub handler_id: String,

    /// State variables accessed by the handler
    pub read_vars: Vec<String>,

    /// Parameters accessed by the handler
    pub read_params: Vec<String>,

    /// Parameters modified by the handler
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified_params: Option<Vec<String>>,

    /// Handler-specific configuration
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config: Option<serde_json::Value>,
}

/// Root finding direction for continuous events
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RootFindDirection {
    /// Detect positive-going zero crossings
    Left,
    /// Detect negative-going zero crossings
    Right,
    /// Detect all zero crossings
    All,
}

/// Reaction network component
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReactionSystem {
    /// Coupling type label
    #[serde(skip_serializing_if = "Option::is_none")]
    pub coupletype: Option<String>,

    /// Academic citation or data source reference
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,

    /// Chemical species, keyed by species name
    pub species: HashMap<String, Species>,

    /// Named parameters (rate constants, temperature, photolysis rates, etc.)
    pub parameters: HashMap<String, Parameter>,

    /// Chemical reactions
    pub reactions: Vec<Reaction>,

    /// Additional algebraic or ODE constraints
    #[serde(skip_serializing_if = "Option::is_none")]
    pub constraint_equations: Option<Vec<Equation>>,

    /// Discrete events
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discrete_events: Option<Vec<DiscreteEvent>>,

    /// Continuous events
    #[serde(skip_serializing_if = "Option::is_none")]
    pub continuous_events: Option<Vec<ContinuousEvent>>,

    /// Named child reaction systems (subsystems), keyed by unique identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subsystems: Option<HashMap<String, serde_json::Value>>,
}

/// Chemical species in a reaction system. Keyed by name in the parent map.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Species {
    /// Physical units
    #[serde(skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,

    /// Default/initial concentration
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<f64>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Reservoir species: participates in reactions but held fixed (no ODE).
    /// Maps to Catalyst's `isconstantspecies=true`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub constant: Option<bool>,
}

/// Parameter in a reaction system
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Parameter {
    /// Physical units
    #[serde(skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,

    /// Default/initial value
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<f64>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Chemical reaction
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reaction {
    /// Unique reaction identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,

    /// Human-readable reaction name
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// Reactant species and stoichiometry. May be null for source reactions (∅ → X).
    /// Schema requires this field to be present (possibly null).
    #[serde(default)]
    pub substrates: Option<Vec<StoichiometricEntry>>,

    /// Product species and stoichiometry. May be null for sink reactions (X → ∅).
    /// Schema requires this field to be present (possibly null).
    #[serde(default)]
    pub products: Option<Vec<StoichiometricEntry>>,

    /// Rate law expression
    pub rate: Expr,

    /// Academic citation or data source reference
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,
}

/// Species with stoichiometric coefficient.
///
/// v0.2.x permits fractional coefficients (e.g. `0.87 CH2O` in atmospheric
/// chemistry) in addition to the historical integer case. The coefficient
/// MUST be positive and finite — NaN / ±∞ are rejected at parse time by
/// [`validate_stoichiometries`](crate::parse::validate_stoichiometries).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoichiometricEntry {
    /// Species name
    pub species: String,

    /// Stoichiometric coefficient (positive finite number; serialized as `stoichiometry`)
    #[serde(rename = "stoichiometry", default = "default_stoichiometry")]
    pub coefficient: f64,
}

fn default_stoichiometry() -> f64 {
    1.0
}

/// Generic, runtime-agnostic description of an external data source.
///
/// A `DataLoader` is pure I/O (RFC pure-io-data-loaders §4.1): it carries
/// enough structural information to locate files, map timestamps to files, and
/// describe variable semantics — rather than pointing at a runtime handler.
/// Grid geometry, reprojection, and regridding are expressed as ordinary data
/// and `aggregate` FAQ expressions downstream, not on the loader. Authentication
/// and algorithm-specific tuning are runtime-only and not part of the schema.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DataLoader {
    /// Structural kind of the dataset. Scientific role (emissions,
    /// meteorology, elevation, ...) is not schema-validated and belongs in
    /// `metadata.tags`.
    pub kind: DataLoaderKind,

    /// File discovery configuration.
    pub source: DataLoaderSource,

    /// Temporal coverage and record layout.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temporal: Option<DataLoaderTemporal>,

    /// Reproducibility contract — endian / float_format / integer_width
    /// (esm-spec §8.9.2). A binding that cannot honor the declared
    /// contract MUST reject the file at load.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub determinism: Option<DataLoaderDeterminism>,

    /// Variables exposed by this loader, keyed by schema-level variable name.
    pub variables: HashMap<String, DataLoaderVariable>,

    /// Academic citation or data source reference.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,

    /// Free-form metadata about the data source. Tags convey scientific role.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<DataLoaderMetadata>,
}

/// Structural kind of a data loader dataset.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DataLoaderKind {
    /// Gridded dataset.
    Grid,
    /// Point / observational dataset.
    Points,
    /// Static dataset (no time dimension).
    Static,
}

/// Reproducibility contract a loader advertises to bindings
/// (esm-spec §8.9.2).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DataLoaderDeterminism {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub endian: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub float_format: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub integer_width: Option<u32>,
}

/// File discovery configuration. Describes how to locate data files at
/// runtime via URL templates with date/variable substitutions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DataLoaderSource {
    /// Jinja-style URL template with substitutions. Supported:
    /// `{date:<strftime>}` (e.g. `{date:%Y%m%d}`), `{var}`, `{sector}`,
    /// `{species}`. Custom substitutions are allowed and must be passed
    /// through by the runtime.
    pub url_template: String,

    /// Ordered fallback URL templates. Runtime tries each in order.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mirrors: Option<Vec<String>>,
}

/// Temporal coverage and record layout for a data source.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DataLoaderTemporal {
    /// ISO 8601 datetime — first timestamp available from this source.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<String>,

    /// ISO 8601 datetime — last timestamp available from this source.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end: Option<String>,

    /// ISO 8601 duration describing how much time one file covers.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_period: Option<String>,

    /// ISO 8601 duration describing spacing between samples within a file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frequency: Option<String>,

    /// Number of time records per file. `"auto"` means read from file at
    /// runtime.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub records_per_file: Option<RecordsPerFile>,

    /// Name of the time coordinate variable in the file. Used when
    /// `records_per_file` is absent or `"auto"`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_variable: Option<String>,
}

/// Number of records per file — an integer, or the literal `"auto"`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RecordsPerFile {
    /// Fixed count (`>= 1`).
    Count(u32),
    /// `"auto"` — read from file at runtime.
    Auto(AutoRecords),
}

/// Carrier for the `"auto"` literal in [`RecordsPerFile`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AutoRecords {
    /// Runtime discovers the record count from file metadata.
    Auto,
}

/// A variable exposed by a data loader, mapped from a source-file variable.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DataLoaderVariable {
    /// Name of the variable inside the source file. May differ from the
    /// schema-level variable name.
    pub file_variable: String,

    /// Units of the variable as exposed to the schema.
    pub units: String,

    /// Optional multiplicative factor or Expression AST applied to convert
    /// source-file values to the declared units.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit_conversion: Option<UnitConversion>,

    /// Brief description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Academic citation or data source reference.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,
}

/// Multiplicative factor (number) or Expression AST used to convert source-
/// file values to the declared units.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
#[allow(clippy::large_enum_variant)]
pub enum UnitConversion {
    /// Simple multiplicative factor.
    Factor(f64),
    /// Expression AST applied to the source value.
    Expression(Expr),
}

/// Free-form metadata about a data loader.
///
/// The `tags` field is conventional for expressing scientific role
/// (e.g. `"emissions"`, `"reanalysis"`) and is not schema-validated.
/// Additional fields are preserved as raw JSON via `extra`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DataLoaderMetadata {
    /// Scientific role tags (freeform).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,

    /// Additional, loader-specific metadata fields.
    #[serde(flatten)]
    pub extra: HashMap<String, serde_json::Value>,
}

/// Runtime operator reference
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Operator {
    /// Registered identifier the runtime uses to find the implementation
    pub operator_id: String,

    /// Variables required by the operator
    pub needed_vars: Vec<String>,

    /// Variables the operator modifies
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modifies: Option<Vec<String>>,

    /// Academic citation or data source reference
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,

    /// Implementation-specific configuration
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config: Option<serde_json::Value>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Coupling entry with discriminated union based on type field
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[allow(clippy::large_enum_variant)]
pub enum CouplingEntry {
    /// Operator composition coupling
    OperatorCompose {
        /// The two systems to compose
        systems: Vec<String>,
        /// Variable mappings when LHS variables don't have matching names
        #[serde(skip_serializing_if = "Option::is_none")]
        translate: Option<serde_json::Value>,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Bi-directional coupling via explicit ConnectorSystem equations
    Couple {
        /// The two systems involved in coupling
        systems: Vec<String>,
        /// Connector definition with equations
        connector: serde_json::Value,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Variable mapping between systems
    VariableMap {
        /// Source variable (scoped reference)
        from: String,
        /// Target parameter (scoped reference)
        to: String,
        /// How the mapping is applied
        transform: String,
        /// Conversion factor (for conversion_factor transform)
        #[serde(skip_serializing_if = "Option::is_none")]
        factor: Option<f64>,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Apply operator to system
    OperatorApply {
        /// Operator reference
        operator: String,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Callback coupling
    Callback {
        /// Registered identifier for the callback
        callback_id: String,
        /// Configuration parameters
        #[serde(skip_serializing_if = "Option::is_none")]
        config: Option<serde_json::Value>,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
    /// Event-based coupling
    Event {
        /// Whether this is a continuous or discrete event
        event_type: String,
        /// Human-readable identifier
        #[serde(skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        /// Condition expressions (zero-crossing for continuous, boolean for discrete)
        #[serde(skip_serializing_if = "Option::is_none")]
        conditions: Option<Vec<Expr>>,
        /// Trigger specification (for discrete events)
        #[serde(skip_serializing_if = "Option::is_none")]
        trigger: Option<DiscreteEventTrigger>,
        /// Affect equations
        #[serde(skip_serializing_if = "Option::is_none")]
        affects: Option<Vec<AffectEquation>>,
        /// Functional affect handler
        #[serde(skip_serializing_if = "Option::is_none")]
        functional_affect: Option<FunctionalAffect>,
        /// Separate affects for negative-going zero crossings
        #[serde(skip_serializing_if = "Option::is_none")]
        affect_neg: Option<Vec<AffectEquation>>,
        /// Parameters modified by this event
        #[serde(skip_serializing_if = "Option::is_none")]
        discrete_parameters: Option<Vec<String>>,
        /// Root finding direction
        #[serde(skip_serializing_if = "Option::is_none")]
        root_find: Option<RootFindDirection>,
        /// Whether to reinitialize the system after the event
        #[serde(skip_serializing_if = "Option::is_none")]
        reinitialize: Option<bool>,
        /// Brief description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
}

/// Variable mapping between systems
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VariableMapping {
    /// Source variable name
    pub source_var: String,
    /// Target variable name
    pub target_var: String,
    /// Optional scaling factor
    #[serde(skip_serializing_if = "Option::is_none")]
    pub factor: Option<f64>,
}

/// Spatial/temporal domain specification
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Domain {
    /// Name of the independent (time) variable
    #[serde(skip_serializing_if = "Option::is_none")]
    pub independent_variable: Option<String>,

    /// Temporal domain
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temporal: Option<serde_json::Value>,

    /// Floating point precision
    #[serde(skip_serializing_if = "Option::is_none")]
    pub element_type: Option<String>,

    /// Array backend identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub array_type: Option<String>,
}
