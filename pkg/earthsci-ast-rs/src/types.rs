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

    /// Document-scoped, OPTIONAL registry of coordinate variables
    /// (RFC streaming-output-sinks §8.3), keyed by name.
    ///
    /// Purely additive: a document without it validates and emits exactly as
    /// before (bare integer axes). Each entry marks an existing data array —
    /// referenced by name, exactly as a `ragged` [`IndexSet`] references its
    /// `offsets`/`values` factors — or an inline literal `values` vector as a
    /// physical coordinate, and attaches CF metadata. It is read by
    /// [`crate::data_output::derive_output_meta`] so a streaming writer can
    /// emit CF dimension/auxiliary coordinates.
    ///
    /// The key is already in `esm-schema.json` and in the Julia `EsmFile`, but
    /// the Rust binding did not model it at all — so a `parse → emit` round
    /// trip silently DROPPED the whole registry (the same class of defect as
    /// the `IndexSet::member_factor` omission below).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coordinates: Option<HashMap<String, Coordinate>>,

    /// Top-level rewrite-rule registry — the payload of a template-library file
    /// (esm-spec §9.7.1).
    ///
    /// A DECLARATION, and a peer of `index_sets` — not an
    /// `apply_expression_template` call site. Option A expands call sites; it
    /// does not delete declarations (§9.6.4 rule 5), so this survives
    /// `parse → emit` VERBATIM and a template-library file round-trips to
    /// itself. Held as raw JSON precisely so that "verbatim" is achievable: a
    /// typed re-serialization could not promise byte-identity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expression_templates: Option<serde_json::Value>,

    /// Top-level metaparameter block (esm-spec §9.7.1) — likewise a DECLARATION
    /// that survives `parse → emit` verbatim (§9.6.4 rule 5).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metaparameters: Option<serde_json::Value>,

    /// ODE-based model components, keyed by unique identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub models: Option<HashMap<String, Model>>,

    /// Reaction network components, keyed by unique identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reaction_systems: Option<HashMap<String, ReactionSystem>>,

    /// Document-scoped ingest registry (esm-spec §8): named external data
    /// sources, keyed by id. NOT components — a source is not a coupling
    /// endpoint, a subsystem, or a scoped-reference path root; a model consumes
    /// one through a parameter `update` naming it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data_sources: Option<HashMap<String, DataSource>>,

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

    /// Coupling-library formal component roles (esm-spec §10.9). Present only
    /// in a coupling-library file, which pairs it with a role-scoped `coupling`
    /// array and declares no models/reaction_systems/data_sources/domain/
    /// index_sets/metaparameters/expression_templates. Presence of this key is
    /// the sole positive identifier of the coupling-library file kind.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coupling_roles: Option<HashMap<String, CouplingRole>>,

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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
/// [`Expr::Integer`]. The hand-written [`Deserialize`] impl below dispatches on
/// the incoming JSON token type directly, which is what an
/// `#[serde(untagged)]` derive would decide by trying `Integer` before
/// `Number`: strict integer JSON tokens bind to `Integer`, float tokens to
/// `Number`.
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    /// Integer literal (JSON integer token, no `.`, no `e`/`E`).
    Integer(i64),

    /// Float literal (JSON number token with `.`, `e`, or `E`).
    Number(f64),

    /// Variable or parameter reference string
    Variable(String),

    /// Operator node with children.
    ///
    /// The payload is an `Arc<ExpressionNode>`, not an inline `ExpressionNode`:
    /// a §9.7-expanded discretization repeats the same subtree tens of
    /// thousands of times (measured on `simpleclimate.esm` at the production
    /// grid: 1.21M operator/leaf occurrences, 6,961 distinct subtrees — 0.58%),
    /// and with an unboxed 832-byte node every occurrence was a full copy
    /// (~978 MiB). Sharing the payload lets the load-time interner
    /// ([`crate::intern`]) collapse structurally identical subtrees to one
    /// allocation, and makes `Expr::clone` O(1) for operator trees. `Arc`
    /// rather than `Rc` so `Expr` stays `Send + Sync` (the feature-gated
    /// `performance::ParallelEvaluator` iterates `&[Expr]` with rayon); the
    /// atomic refcount is off every evaluation hot path.
    ///
    /// Mutation goes through [`std::sync::Arc::make_mut`] (see
    /// [`Expr::node_mut`]), i.e. copy-on-write: a mutated node is split from
    /// its sharers first, so sharing is invisible to single-tree semantics.
    Operator(std::sync::Arc<ExpressionNode>),
}

impl Expr {
    /// Wrap `node` as an [`Expr::Operator`], interning it when a load-scoped
    /// interner is active on this thread (see [`crate::intern`]); otherwise a
    /// plain fresh allocation.
    pub fn operator(node: ExpressionNode) -> Expr {
        Expr::Operator(crate::intern::intern_node(node))
    }

    /// Mutable access to an operator payload, copy-on-write. Returns `None`
    /// for a leaf. Splits the node from any sharers first (`Arc::make_mut`),
    /// so mutating through this never affects another tree.
    pub fn node_mut(&mut self) -> Option<&mut ExpressionNode> {
        match self {
            Expr::Operator(rc) => Some(std::sync::Arc::make_mut(rc)),
            _ => None,
        }
    }
}

impl From<ExpressionNode> for Expr {
    fn from(node: ExpressionNode) -> Expr {
        Expr::operator(node)
    }
}

// `Expr` used to derive `Deserialize` with `#[serde(untagged)]`. That derive
// works by buffering the ENTIRE incoming subtree into serde's `Content` tree
// and then replaying it against each variant in turn until one sticks. `Expr`
// is the crate's most common node type and it nests (an operator node's `args`
// are themselves `Expr`s), so every level of an expression re-buffered its own
// subtree: a load-phase profile of simpleclimate.esm attributed ~88% of the
// 15 s load to serde, of which `content_clone` (8.9% self), the matching
// `drop_in_place::<Content>` (8.9% self) and the allocator traffic they drive
// (`_int_malloc` 22%, `malloc_consolidate` 11%, `cfree` 10%, `_int_free` 7%)
// were the bulk. The failed-variant attempts also each construct a discarded
// `serde_json::Error` (`make_error`, 0.5% self).
//
// The hand-written impl below dispatches on the token type the deserializer
// reports, which is exactly the decision the untagged derive reached by trial:
//
//   * a signed integer token        -> `Integer`
//   * an unsigned token that fits `i64` -> `Integer`; one that does not -> `Number`
//     (untagged: `i64`'s visitor rejects it, so the `Number(f64)` variant, whose
//     `deserialize_float` accepts `Content::U64` via `visit_u64`, wins)
//   * a float token                 -> `Number` (`deserialize_integer` rejects
//     `Content::F64`, so the untagged derive fell through to `Number` too)
//   * a string token                -> `Variable`
//   * a map                         -> `Operator` (`ExpressionNode`)
//   * a seq                         -> `Operator`, positionally. Obscure, but
//     serde's `ContentDeserializer::deserialize_struct` visits `Content::Seq`
//     as a seq, so the untagged derive accepted a full-length positional array
//     as an `ExpressionNode`; `SeqAccessDeserializer` reproduces that.
//   * anything else (null, bool, …) -> error, as before. Only the message text
//     changes: the untagged derive said "data did not match any variant of
//     untagged enum Expr", this says which type was found instead.
//
// Everything streams: no `Content`, no subtree clone, no speculative errors.
impl<'de> Deserialize<'de> for Expr {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(ExprVisitor)
    }
}

/// Visitor backing [`Expr`]'s hand-written [`Deserialize`]. The unimplemented
/// `visit_*` hooks fall through to serde's defaults, which widen the narrow
/// integer/float types onto `visit_i64` / `visit_u64` / `visit_f64` and route
/// borrowed strings onto `visit_str` — the same widening `Content` performed.
struct ExprVisitor;

impl<'de> serde::de::Visitor<'de> for ExprVisitor {
    type Value = Expr;

    fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("an expression: a number, a variable name, or an operator node")
    }

    fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<Self::Value, E> {
        Ok(Expr::Integer(v))
    }

    fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<Self::Value, E> {
        // Above `i64::MAX` the untagged derive's `Integer` variant failed and
        // `Number` took it as a float; keep that.
        Ok(match i64::try_from(v) {
            Ok(i) => Expr::Integer(i),
            Err(_) => Expr::Number(v as f64),
        })
    }

    fn visit_f64<E: serde::de::Error>(self, v: f64) -> Result<Self::Value, E> {
        Ok(Expr::Number(v))
    }

    fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Self::Value, E> {
        Ok(Expr::Variable(v.to_owned()))
    }

    fn visit_string<E: serde::de::Error>(self, v: String) -> Result<Self::Value, E> {
        Ok(Expr::Variable(v))
    }

    fn visit_map<A>(self, map: A) -> Result<Self::Value, A::Error>
    where
        A: serde::de::MapAccess<'de>,
    {
        ExpressionNode::deserialize(serde::de::value::MapAccessDeserializer::new(map))
            .map(Expr::operator)
    }

    fn visit_seq<A>(self, seq: A) -> Result<Self::Value, A::Error>
    where
        A: serde::de::SeqAccess<'de>,
    {
        ExpressionNode::deserialize(serde::de::value::SeqAccessDeserializer::new(seq))
            .map(Expr::operator)
    }
}

// `Expr` deserializes by hand (above) and serializes by hand so that the
// `Number` variant obeys the ESM canonical-number rule (§5.5.3.1): an integral
// float value re-serializes as an INTEGER literal (`0.0` → `0`, `9.0` → `9`),
// exactly as the JS / Julia / Python bindings do. A derived untagged
// `Serialize` would instead emit `0.0`, diverging on every integral-valued
// float operand.
impl Serialize for Expr {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Expr::Integer(i) => serializer.serialize_i64(*i),
            Expr::Number(n) => serialize_canonical_f64(*n, serializer),
            Expr::Variable(v) => serializer.serialize_str(v),
            Expr::Operator(node) => node.serialize(serializer),
        }
    }
}

/// Serialize an `f64` in ESM canonical form (§5.5.3.1): a finite value whose
/// magnitude is integral and fits `i64` is emitted as an INTEGER literal (no
/// trailing `.0`), matching the JS / Julia / Python bindings; every other
/// finite value keeps serde_json's shortest round-trip float form. Non-finite
/// values fall through to `serialize_f64` (serde_json emits `null`), preserving
/// the pre-existing behavior for a rule the canonical writer otherwise rejects.
pub(crate) fn serialize_canonical_f64<S: serde::Serializer>(
    n: f64,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    // 2^63; an integral f64 strictly below this in magnitude round-trips
    // losslessly through `i64`.
    if n.is_finite() && n.fract() == 0.0 && n.abs() < 9_223_372_036_854_775_808.0 {
        serializer.serialize_i64(n as i64)
    } else {
        serializer.serialize_f64(n)
    }
}

/// A single `arrayop`/`aggregate` index range (RFC semiring-faq-unified-ir
/// §5.2). Either a dense inclusive integer interval `[lo, hi]` (the original,
/// and still the most common form) or a reference to a declared index set.
///
/// Index-set references are resolved to concrete `[lo, hi]` intervals against
/// the document `index_sets` registry by
/// [`crate::aggregate::resolve_aggregate_ranges`] before the evaluator runs, so
/// every range the evaluator actually iterates is a [`RangeSpec::Interval`].
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RangeSpec {
    /// Dense inclusive integer interval `[lo, hi]`.
    Interval([i64; 2]),
    /// Dense inclusive integer interval with an explicit stride `[lo, hi, step]`
    /// (the strided authored form the semiring index-range grammar also admits;
    /// property-corpus fixtures exercise it). The evaluator treats it as the
    /// `[lo, hi]` interval for bound purposes — `step` is carried verbatim so it
    /// round-trips. Placed right after [`RangeSpec::Interval`] in this untagged
    /// enum: a 2-element array binds to `Interval`, a 3-element array to this,
    /// and neither collides with the object-shaped variants below.
    Strided([i64; 3]),
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
            RangeSpec::Strided(iv) => Some([iv[0], iv[1]]),
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
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct JoinClause {
    /// The `[left, right]` key-column pairs to equi-join on. Empty when this is
    /// a spatial `overlap` gate clause instead of a value-equality clause.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub on: Vec<[String; 2]>,
    /// A spatial OVERLAP broad-phase gate (CONFORMANCE_SPEC §5.5.6). Mutually
    /// exclusive with `on`. Resolved on the value-invention (raw-JSON) path via
    /// [`crate::value_invention`]; on the dense array evaluator it is a
    /// numerically-inert broad-phase superset (every real overlap survives the
    /// exact narrow-phase `filter`), so join lowering treats it as a no-op.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub overlap: Option<OverlapClause>,
}

/// A spatial overlap join-gate clause (`{ "overlap": { … } }`), the broad-phase
/// alternative to an `on` value-equality clause on an `aggregate` (CONFORMANCE_SPEC
/// §5.5.6). `src_env`/`tgt_env` name const-array envelope factors (arity 1 rings /
/// 2 point / 4 rectangle); `eps` inflates both envelopes outward before the
/// closed-AABB intersection test. Resolved by [`crate::value_invention`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OverlapClause {
    /// QUERY-side envelope factor name(s).
    pub src_env: Vec<String>,
    /// INDEXED (cell) side envelope factor name(s).
    pub tgt_env: Vec<String>,
    /// Non-negative outward envelope inflation (default `0.0`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub eps: Option<f64>,
    /// The aggregate range symbol the `src_env` axis runs over, resolved at
    /// build time by [`crate::join::resolve_overlap_join_syms`] while each
    /// range still carries its `{ "from": <index set> }` linkage. `None` until
    /// then, and `None` for a clause whose env factors could not be traced to a
    /// loop symbol — the enumeration driver then declines to drive and the
    /// evaluator walks the full product, exactly as it did before the gate
    /// became a driver.
    ///
    /// NOT part of the wire form: `#[serde(skip)]` keeps every document's
    /// parse -> emit round trip byte-identical.
    #[serde(skip)]
    pub sym_src: Option<String>,
    /// The aggregate range symbol the `tgt_env` axis runs over. See [`Self::sym_src`].
    #[serde(skip)]
    pub sym_tgt: Option<String>,
}

/// (De)serialize [`ExpressionNode::output_idx`] as a heterogeneous list of
/// index names and integer literals while storing each entry as a `String`.
///
/// On the wire an entry is either a string (`"i"`) or an integer (`1`, a
/// singleton-dimension marker). On deserialize an integer entry is stored as
/// its canonical decimal string; on serialize a stored string that is exactly a
/// canonical `i64` literal is emitted as a JSON integer, everything else as a
/// JSON string. Because symbolic index names are identifiers (never bare
/// decimal integers), this preserves both `["i"] ↔ ["i"]` and `[1] ↔ [1]`
/// byte-for-byte.
mod output_idx_serde {
    use serde::de::Error as _;
    use serde::ser::SerializeSeq;
    use serde::{Deserialize, Deserializer, Serializer};
    use serde_json::Value;

    pub(super) fn serialize<S: Serializer>(
        value: &Option<Vec<String>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        // `skip_serializing_if = "Option::is_none"` guarantees `Some` here.
        let items = value
            .as_ref()
            .expect("serialize_with is only reached when the field is Some");
        let mut seq = serializer.serialize_seq(Some(items.len()))?;
        for item in items {
            // A canonical `i64` literal round-trips as an integer; any other
            // string (every real index name) stays a string.
            match item.parse::<i64>() {
                Ok(n) if n.to_string() == *item => seq.serialize_element(&n)?,
                _ => seq.serialize_element(item)?,
            }
        }
        seq.end()
    }

    pub(super) fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Option<Vec<String>>, D::Error> {
        let Some(items) = Option::<Vec<Value>>::deserialize(deserializer)? else {
            return Ok(None);
        };
        let mut out = Vec::with_capacity(items.len());
        for v in items {
            match v {
                Value::String(s) => out.push(s),
                Value::Number(n) if n.is_i64() || n.is_u64() => out.push(n.to_string()),
                other => {
                    return Err(D::Error::custom(format!(
                        "output_idx entries must be an index name (string) or an integer, got {other}"
                    )));
                }
            }
        }
        Ok(Some(out))
    }
}

/// Expression node representing an operator with operands.
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

    /// Output index names for `arrayop`/`aggregate` (e.g. `["i", "j"]`).
    ///
    /// Each entry is normally a symbolic index name (string), but the schema
    /// (and the semiring IR) also admits a bare integer literal for a singleton
    /// dimension — property-corpus fixtures carry `output_idx: [1]`. Stored as
    /// `String` so the ~15 evaluator/scope call sites keep their `&[String]`
    /// ergonomics; the [`output_idx_serde`] adaptor round-trips an integer entry
    /// back to a JSON integer (never a stringified `"1"`), so byte identity with
    /// the JS/Julia/Python bindings holds. Symbolic index names are always
    /// identifiers, never bare decimal integers, so the "looks like an integer ⇒
    /// emit as integer" rule cannot misfire on a real name.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "output_idx_serde")]
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

    /// Documentary relation tag for a `skolem` node (e.g. `"edge"`, `"bin"`,
    /// `"pair"`). Purely a human-readable annotation of which relation the
    /// invented key belongs to — it is NOT a key component and is ignored by
    /// value invention. Kept out of `args` so a mistyped key component can never
    /// masquerade as a tag (and vice versa). A scalar, so it is deliberately not
    /// traversed by `for_each_child`/`map_children`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,

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

    /// For the `apply_expression_template` op (esm-spec §9.7): template
    /// parameter → argument-expression map. Keys are the template's formal
    /// parameter names; values are the bound expressions substituted at
    /// instantiation. Rendered in sorted-key order.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bindings: Option<HashMap<String, Expr>>,

    /// For the `argmin` / `argmax` arg-witness ops: the single output index
    /// name the witness is reported over.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arg: Option<String>,

    /// For the `aggregate` op: when `true`, contract over distinct key values
    /// only (RFC semiring-faq-unified-ir §5.3).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub distinct: Option<bool>,

    /// For the `aggregate` op: grouping-key expression (RFC
    /// semiring-faq-unified-ir §5.3).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<Box<Expr>>,
}

// ───────────────────────────────────────────────────────────────────────────
// ExpressionNode child-`Expr` field spec — SINGLE SOURCE OF TRUTH.
//
// Every child-`Expr`-bearing field of `ExpressionNode` is declared exactly once,
// in traversal order, by the `expr_children! { … }` invocation below. From that
// one ordered spec we generate BOTH the typed walkers (`for_each_child` /
// `for_each_child_mut` / `any_child` / `map_children`) AND the crate-internal
// `EXPR_{SCALAR,ARRAY,MAP}_CHILD_KEYS` JSON-key constants that the pre-lowering
// raw-JSON walker in `crate::parse` iterates. Adding a child field is a one-line
// spec edit that updates all seven sites at once, so the historical "add a
// field, forget a walker (or a key constant)" drift class is now impossible.
//
// Traversal order is CONTRACT (other crates depend on it): args, lower, upper,
// expr, filter, values, axes (sorted key), key, bindings (sorted key).

/// Child-field wire-shape tags for each [`EXPR_CHILD_FIELDS`] entry. The two
/// array shapes (`Vec<Expr>` for `args`, `Option<Vec<Expr>>` for `values`) share
/// one JSON-key bucket but need different walker code, so they are distinct spec
/// tokens (`array` / `opt_array`) that both map to `CHILD_ARRAY` here.
const CHILD_ARRAY: u8 = 0;
const CHILD_SCALAR: u8 = 1; // `Option<Box<Expr>>`
const CHILD_MAP: u8 = 2; // `Option<HashMap<String, Expr>>`, visited sorted-key

/// Const-fold the ordered [`EXPR_CHILD_FIELDS`] spec to the JSON keys of one wire
/// shape, preserving spec order. `N` MUST equal the number of fields carrying
/// `tag`; a mismatch is a compile-time error (an index-out-of-bounds write or the
/// `assert!`), which is what keeps the three derived key arrays honest.
const fn child_keys<const N: usize>(tag: u8) -> [&'static str; N] {
    let mut out = [""; N];
    let mut i = 0;
    let mut j = 0;
    while i < EXPR_CHILD_FIELDS.len() {
        if EXPR_CHILD_FIELDS[i].1 == tag {
            out[j] = EXPR_CHILD_FIELDS[i].0;
            j += 1;
        }
        i += 1;
    }
    assert!(j == N, "child-key count does not match the declared array length");
    out
}

/// Per-walker, per-shape code fragments. Each `expr_children!`-generated method
/// body is a repetition of one of these over the ordered spec, so the four
/// walkers cannot disagree about which fields carry children or in what order.
///
/// The node receiver is threaded through as a `:tt` (matches the `self`
/// keyword), and the visitor / rebuild target as `:ident`, so both keep the
/// generated method's hygiene context.
macro_rules! expr_child_visit {
    // for_each_child: immutable; maps visited in sorted-key order.
    (@each array, $node:tt, $f:ident, $field:ident) => {
        for a in &$node.$field { $f(a); }
    };
    (@each opt_array, $node:tt, $f:ident, $field:ident) => {
        if let Some(vs) = &$node.$field { for v in vs { $f(v); } }
    };
    (@each scalar, $node:tt, $f:ident, $field:ident) => {
        if let Some(e) = $node.$field.as_deref() { $f(e); }
    };
    (@each map, $node:tt, $f:ident, $field:ident) => {
        if let Some(m) = &$node.$field {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            for k in keys { $f(&m[k]); }
        }
    };

    // for_each_child_mut: mutable; maps visited in sorted-key order.
    (@each_mut array, $node:tt, $f:ident, $field:ident) => {
        for a in &mut $node.$field { $f(a); }
    };
    (@each_mut opt_array, $node:tt, $f:ident, $field:ident) => {
        if let Some(vs) = &mut $node.$field { for v in vs { $f(v); } }
    };
    (@each_mut scalar, $node:tt, $f:ident, $field:ident) => {
        if let Some(e) = $node.$field.as_deref_mut() { $f(e); }
    };
    (@each_mut map, $node:tt, $f:ident, $field:ident) => {
        if let Some(m) = &mut $node.$field {
            let mut keys: Vec<String> = m.keys().cloned().collect();
            keys.sort();
            for k in keys {
                if let Some(v) = m.get_mut(&k) { $f(v); }
            }
        }
    };

    // any_child: a short-circuiting bool per field (the OR result is
    // order-independent, so maps need not be sorted here).
    (@any array, $node:tt, $f:ident, $field:ident) => {
        $node.$field.iter().any(&mut *$f)
    };
    (@any opt_array, $node:tt, $f:ident, $field:ident) => {
        $node.$field.as_ref().is_some_and(|vs| vs.iter().any(&mut *$f))
    };
    (@any scalar, $node:tt, $f:ident, $field:ident) => {
        $node.$field.as_deref().is_some_and(|e| $f(e))
    };
    (@any map, $node:tt, $f:ident, $field:ident) => {
        $node.$field.as_ref().is_some_and(|m| m.values().any(&mut *$f))
    };

    // map_children: rebuild each child field onto `$out` (maps not reordered —
    // a rebuilt `HashMap`'s iteration order is irrelevant).
    (@map array, $node:tt, $out:ident, $f:ident, $field:ident) => {
        $out.$field = $node.$field.iter().map(&mut *$f).collect();
    };
    (@map opt_array, $node:tt, $out:ident, $f:ident, $field:ident) => {
        $out.$field = $node.$field.as_ref().map(|vs| vs.iter().map(&mut *$f).collect());
    };
    (@map scalar, $node:tt, $out:ident, $f:ident, $field:ident) => {
        $out.$field = $node.$field.as_deref().map(|e| Box::new($f(e)));
    };
    (@map map, $node:tt, $out:ident, $f:ident, $field:ident) => {
        $out.$field = $node.$field.as_ref().map(|m| m.iter().map(|(k, v)| (k.clone(), $f(v))).collect());
    };

    // Shape → JSON-key-constant bucket tag.
    (@tag array) => { CHILD_ARRAY };
    (@tag opt_array) => { CHILD_ARRAY };
    (@tag scalar) => { CHILD_SCALAR };
    (@tag map) => { CHILD_MAP };
}

/// Declare the ordered child-field spec once; expand it into the flat
/// [`EXPR_CHILD_FIELDS`] table plus the four `ExpressionNode` walkers.
macro_rules! expr_children {
    ($( $field:ident : $shape:ident ),* $(,)?) => {
        /// The ordered, shape-tagged child-`Expr` field spec — the single source
        /// the walkers (above, generated) and the [`EXPR_SCALAR_CHILD_KEYS`] /
        /// [`EXPR_ARRAY_CHILD_KEYS`] / [`EXPR_MAP_CHILD_KEYS`] constants (below,
        /// derived via [`child_keys`]) are all produced from.
        const EXPR_CHILD_FIELDS: &[(&str, u8)] = &[
            $( (stringify!($field), expr_child_visit!(@tag $shape)) ),*
        ];

        impl ExpressionNode {
            /// Visit every expression-bearing child of this node, in the
            /// contractual order: `args` first, then the scalar sidecars `lower`,
            /// `upper`, `expr`, `filter`, then `values`, then `axes` entries
            /// sorted by key, then `key`, then `bindings` entries sorted by key.
            ///
            /// This is the ONE canonical definition of which fields carry child
            /// `Expr`s. Every AST traversal in this crate must go through this
            /// family (or [`Self::map_children`] / [`Self::any_child`]) rather
            /// than enumerating fields by hand — hand-rolled walkers historically
            /// each covered a different subset and missed variables hidden in
            /// aggregate bodies, `filter` predicates, integral bounds,
            /// `table_lookup` axes, aggregate `key`s, or template `bindings`.
            ///
            /// Note: this enumerates children only. `output_idx`, `ranges`,
            /// `int_var` (and `arg`) *bind* index symbols for the node's body;
            /// callers that resolve variable names decide how to treat them.
            pub fn for_each_child<'a>(&'a self, f: &mut impl FnMut(&'a Expr)) {
                $( expr_child_visit!(@each $shape, self, f, $field); )*
            }

            /// Mutable variant of [`Self::for_each_child`], visiting the same
            /// field set in the same deterministic order.
            pub fn for_each_child_mut(&mut self, f: &mut impl FnMut(&mut Expr)) {
                $( expr_child_visit!(@each_mut $shape, self, f, $field); )*
            }

            /// Short-circuiting predicate over the same child set as
            /// [`Self::for_each_child`]: true iff `f` returns true for any
            /// expression-bearing child.
            pub fn any_child(&self, f: &mut impl FnMut(&Expr) -> bool) -> bool {
                $( if expr_child_visit!(@any $shape, self, f, $field) { return true; } )*
                false
            }

            /// Rebuild this node with `f` applied to every expression-bearing
            /// child (the [`Self::for_each_child`] field set), preserving ALL
            /// other fields by cloning.
            ///
            /// This is the safe replacement for the
            /// `ExpressionNode { op, args, ..Default::default() }` rebuild
            /// pattern, which silently drops sidecar fields (`expr`, `filter`,
            /// `values`, `regions`, `ranges`, …) and corrupts array / integral /
            /// table nodes — see the corruption note on `crate::flatten`'s
            /// variable substitution.
            pub fn map_children(&self, f: &mut impl FnMut(&Expr) -> Expr) -> ExpressionNode {
                let mut out = self.clone();
                $( expr_child_visit!(@map $shape, self, out, f, $field); )*
                out
            }
        }
    };
}

// The single ordered child-field spec. Order here IS the `for_each_child`
// traversal order (contract); the shape token drives both the walker code and
// the JSON-key bucket.
expr_children! {
    args: array,
    lower: scalar,
    upper: scalar,
    expr: scalar,
    filter: scalar,
    values: opt_array,
    axes: map,
    key: scalar,
    bindings: map,
}

/// Single-child slots (`Option<Box<Expr>>`), derived from [`EXPR_CHILD_FIELDS`].
pub(crate) const EXPR_SCALAR_CHILD_KEYS: [&str; 5] = child_keys::<5>(CHILD_SCALAR);
/// Array-of-children slots (`Vec<Expr>` / `Option<Vec<Expr>>`).
pub(crate) const EXPR_ARRAY_CHILD_KEYS: [&str; 2] = child_keys::<2>(CHILD_ARRAY);
/// Name→child-`Expr` map slots (`Option<HashMap<String, Expr>>`), visited in
/// sorted-key order.
pub(crate) const EXPR_MAP_CHILD_KEYS: [&str; 2] = child_keys::<2>(CHILD_MAP);

/// Pins the JSON-token → [`Expr`] variant mapping that the hand-written
/// `Deserialize` impl performs, INCLUDING the corner cases where it has to
/// reproduce a decision the old `#[serde(untagged)]` derive reached only by
/// trying variants in order. A hand-written impl that silently widened or
/// narrowed what parses is the one real hazard of dropping the derive, so each
/// case below states which untagged behavior it is standing in for.
#[cfg(test)]
mod expr_deserialize_token_mapping_tests {
    use super::*;

    fn parse(src: &str) -> Result<Expr, serde_json::Error> {
        serde_json::from_str::<Expr>(src)
    }

    /// The same document routed through `serde_json::Value` — the shape the
    /// LOADER actually uses (`load_with_options` ends in a `from_value`) —
    /// must land on the same variant as parsing the text directly.
    fn parse_via_value(src: &str) -> Result<Expr, serde_json::Error> {
        let v: serde_json::Value = serde_json::from_str(src).expect("fixture is JSON");
        serde_json::from_value::<Expr>(v)
    }

    #[test]
    fn integer_tokens_bind_to_integer_and_float_tokens_to_number() {
        // Untagged tried `Integer(i64)` first; `deserialize_integer` accepts
        // only Content's integer variants, so a float token fell through to
        // `Number`. §5.4.6 round-trip parse rule.
        for (src, want) in [
            ("0", Expr::Integer(0)),
            ("-7", Expr::Integer(-7)),
            ("9223372036854775807", Expr::Integer(i64::MAX)),
            ("-9223372036854775808", Expr::Integer(i64::MIN)),
            ("0.0", Expr::Number(0.0)),
            ("9.0", Expr::Number(9.0)),
            ("1e3", Expr::Number(1e3)),
            ("-104.52369275835723", Expr::Number(-104.52369275835723)),
        ] {
            assert_eq!(parse(src).expect(src), want, "from_str {src}");
            assert_eq!(parse_via_value(src).expect(src), want, "from_value {src}");
        }
    }

    #[test]
    fn unsigned_tokens_above_i64_max_become_number() {
        // Untagged: `i64`'s visitor rejects `visit_u64` past `i64::MAX`, so the
        // `Number(f64)` variant took it (its `deserialize_float` forwards
        // `Content::U64` to `visit_u64`, which `f64` accepts).
        let src = "9223372036854775808";
        let want = Expr::Number(9223372036854775808u64 as f64);
        assert_eq!(parse(src).expect(src), want);
        assert_eq!(parse_via_value(src).expect(src), want);
    }

    #[test]
    fn string_tokens_bind_to_variable() {
        assert_eq!(parse(r#""theta""#).unwrap(), Expr::Variable("theta".into()));
        assert_eq!(
            parse_via_value(r#""theta""#).unwrap(),
            Expr::Variable("theta".into())
        );
        // A numeric-looking STRING is still a variable reference, never a
        // number: `Integer` / `Number` reject `Content::Str`.
        assert_eq!(parse(r#""12""#).unwrap(), Expr::Variable("12".into()));
    }

    #[test]
    fn objects_bind_to_operator_nodes() {
        let src = r#"{"op":"+","args":[1,2.5,"x"]}"#;
        let Expr::Operator(node) = parse(src).expect(src) else {
            panic!("expected an operator node");
        };
        assert_eq!(node.op, "+");
        assert_eq!(
            node.args,
            vec![
                Expr::Integer(1),
                Expr::Number(2.5),
                Expr::Variable("x".into())
            ]
        );
        assert_eq!(parse_via_value(src).expect(src), Expr::Operator(node));
    }

    #[test]
    fn non_expression_tokens_are_rejected() {
        // Untagged rejected these too (no variant matched) — only the message
        // wording changes. `[1,2]` is a SHORT positional array: it stands in
        // for the seq case, which `ExpressionNode`'s derived `visit_seq`
        // rejects for want of the remaining fields, exactly as it did when
        // `ContentDeserializer::deserialize_struct` fed it a `Content::Seq`.
        // `{"op":"x"}` covers the required-field rule: `ExpressionNode::args`
        // carries no `#[serde(default)]`, so an operator node without `args`
        // is rejected here exactly as it was under the derive.
        for src in ["null", "true", "false", "[]", "[1,2]", "{}", r#"{"op":"x"}"#] {
            assert!(parse(src).is_err(), "{src} must not parse as an Expr");
            assert!(
                parse_via_value(src).is_err(),
                "{src} must not parse as an Expr via Value"
            );
        }
    }

    #[test]
    fn nested_expressions_recurse_through_every_child_slot() {
        // The nesting is the whole reason the untagged derive was expensive
        // (each level re-buffered its own subtree); make sure the streaming
        // impl still reaches children in `args`, the scalar slots, and the
        // map slots.
        let src = r#"{
            "op":"arrayop","args":[],"output_idx":["i"],
            "expr":{"op":"*","args":[{"op":"-","args":["a",1]},2.0]},
            "filter":{"op":">","args":["i",0]},
            "axes":{"z":{"op":"+","args":["b",3]}}
        }"#;
        let Expr::Operator(node) = parse(src).expect("nested fixture parses") else {
            panic!("expected an operator node");
        };
        let Some(Expr::Operator(inner)) = node.expr.as_deref() else {
            panic!("expr slot must hold an operator node");
        };
        assert_eq!(inner.op, "*");
        assert_eq!(inner.args[1], Expr::Number(2.0));
        let Expr::Operator(lhs) = &inner.args[0] else {
            panic!("nested arg must be an operator node");
        };
        assert_eq!(lhs.args, vec![Expr::Variable("a".into()), Expr::Integer(1)]);
        assert!(node.filter.is_some());
        assert!(node.axes.as_ref().is_some_and(|m| m.contains_key("z")));
    }

    #[test]
    fn parse_emit_round_trip_is_byte_identical() {
        // The `Serialize` half is unchanged, but the round trip is what the
        // AST byte-identity conformance actually pins, so guard the pair.
        for src in [
            r#"{"op":"+","args":[1,"x"]}"#,
            r#"{"op":"/","args":[{"op":"sin","args":["t"]},2.5]}"#,
        ] {
            let expr = parse(src).expect(src);
            assert_eq!(serde_json::to_string(&expr).unwrap(), src);
        }
    }
}

#[cfg(test)]
mod expr_child_spec_tests {
    use super::*;

    /// Drift guard 1: the three shape-partitioned key constants derived from the
    /// single `EXPR_CHILD_FIELDS` spec still equal the historical, cross-file-
    /// pinned key sets (the `crate::parse` raw-JSON walker depends on these), and
    /// every spec entry lands in exactly one bucket (no empty derived key).
    #[test]
    fn child_key_constants_match_pinned_sets() {
        assert_eq!(EXPR_ARRAY_CHILD_KEYS, ["args", "values"]);
        assert_eq!(EXPR_SCALAR_CHILD_KEYS, ["lower", "upper", "expr", "filter", "key"]);
        assert_eq!(EXPR_MAP_CHILD_KEYS, ["axes", "bindings"]);

        let bucketed =
            EXPR_ARRAY_CHILD_KEYS.len() + EXPR_SCALAR_CHILD_KEYS.len() + EXPR_MAP_CHILD_KEYS.len();
        assert_eq!(bucketed, EXPR_CHILD_FIELDS.len());
        assert!(EXPR_CHILD_FIELDS.iter().all(|(k, _)| !k.is_empty()));
    }

    /// Drift guard 2: `for_each_child` visits exactly one child per
    /// child-bearing field, in the CONTRACTUAL order (args, lower, upper, expr,
    /// filter, values, axes sorted, key, bindings sorted). `any_child` and
    /// `map_children` agree on the same set. Adding a child-bearing field without
    /// wiring it into the spec changes the visited sequence and fails here.
    #[test]
    fn walkers_cover_all_child_fields_in_contract_order() {
        let mut node = ExpressionNode {
            op: "probe".into(),
            args: vec![Expr::Variable("args0".into())],
            lower: Some(Box::new(Expr::Variable("lower".into()))),
            upper: Some(Box::new(Expr::Variable("upper".into()))),
            expr: Some(Box::new(Expr::Variable("expr".into()))),
            filter: Some(Box::new(Expr::Variable("filter".into()))),
            values: Some(vec![Expr::Variable("values0".into())]),
            key: Some(Box::new(Expr::Variable("key".into()))),
            ..Default::default()
        };
        let mut axes = HashMap::new();
        axes.insert("z_axis".to_string(), Expr::Variable("axes_z".into()));
        axes.insert("a_axis".to_string(), Expr::Variable("axes_a".into()));
        node.axes = Some(axes);
        let mut bindings = HashMap::new();
        bindings.insert("z_bind".to_string(), Expr::Variable("bind_z".into()));
        bindings.insert("a_bind".to_string(), Expr::Variable("bind_a".into()));
        node.bindings = Some(bindings);

        let mut seen = Vec::new();
        node.for_each_child(&mut |c| {
            if let Expr::Variable(v) = c {
                seen.push(v.clone());
            }
        });
        assert_eq!(
            seen,
            vec![
                "args0", "lower", "upper", "expr", "filter", "values0",
                "axes_a", "axes_z", // axes: sorted by key
                "key", "bind_a", "bind_z", // bindings: sorted by key
            ]
        );

        // for_each_child_mut visits the same set (touch each, then re-read).
        let mut count_mut = 0usize;
        node.for_each_child_mut(&mut |_c| count_mut += 1);
        assert_eq!(count_mut, seen.len());

        // any_child membership matches; map_children preserves every child.
        assert!(node.any_child(&mut |c| matches!(c, Expr::Variable(v) if v == "filter")));
        assert!(node.any_child(&mut |c| matches!(c, Expr::Variable(v) if v == "bind_z")));
        assert!(!node.any_child(&mut |c| matches!(c, Expr::Variable(v) if v == "absent")));

        let rebuilt = node.map_children(&mut |c| c.clone());
        let mut seen_rebuilt = Vec::new();
        rebuilt.for_each_child(&mut |c| {
            if let Expr::Variable(v) = c {
                seen_rebuilt.push(v.clone());
            }
        });
        assert_eq!(seen, seen_rebuilt);
    }
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

/// The `reference` solution of an error-norm assertion (esm-spec §6.6.5):
/// either an inline Expression evaluated over the component's domain
/// coordinates, or a `{type: "from_file", path, format?}` shape pointing at a
/// precomputed snapshot (parsed and carried verbatim; not evaluated by this
/// binding). Untagged: the `from_file` object shape is tried first — an
/// Expression operator node always carries `op`, so the two never collide.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AssertionReference {
    /// `{type: "from_file", path, format?}` precomputed-snapshot pointer.
    FromFile(FromFileReference),
    /// Inline analytic Expression over the domain coordinates (boxed — an
    /// [`Expr`] is large, and most assertions carry no reference at all).
    Expression(Box<Expr>),
}

/// The `{type: "from_file", path, format?}` shape of a §6.6.5 assertion
/// `reference` (schema `Assertion.reference` oneOf, second branch).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FromFileReference {
    /// Discriminator; the schema pins it to the constant `"from_file"`.
    #[serde(rename = "type")]
    pub ref_type: String,

    /// Path of the precomputed reference snapshot.
    pub path: String,

    /// Optional file-format hint (e.g. `"netcdf"`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
}

/// A single scalar `(variable, time, expected)` check inside a [`ModelTest`],
/// or one of its §6.6.5 PDE-aware variants: `coords` point-samples an array
/// state at physical coordinates, `reduce` collapses the variable's spatial
/// field to a scalar (`L2_error`/`Linf_error` against `reference`, or the
/// pure collapsers `integral`/`mean`/`max`/`min`). `coords` and `reduce` are
/// mutually exclusive per the schema.
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

    /// Spatial-point evaluation (esm-spec §6.6.5): index-set / dimension name
    /// → numeric coordinate at which to sample the field. Mutually exclusive
    /// with `reduce`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coords: Option<HashMap<String, f64>>,

    /// Domain reduction (esm-spec §6.6.5): one of `integral`, `mean`, `max`,
    /// `min`, `L2_error`, `Linf_error`. The error norms require `reference`.
    /// Mutually exclusive with `coords`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reduce: Option<String>,

    /// Reference (analytic or precomputed) solution required by the
    /// error-norm reductions (esm-spec §6.6.5).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<AssertionReference>,
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

    /// esm-spec §9.7.10 form C / §6.6.6: raw §9.7.2 import entries injected into
    /// the ENCLOSING component's template scope for THIS test's run only — the
    /// discretization a discretization-agnostic PDE leaf is lowered under in the
    /// per-test ephemeral build ([`crate::pde_inline_tests::ephemeral_injected_file`]).
    /// Authored per-run config (a peer of `parameter_overrides` / `tolerance`),
    /// so unlike a component's own imports it DOES survive `parse → emit`; the
    /// enclosing component round-trips with its rewrite-targets intact. Empty
    /// for a non-PDE / discretization-free test.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub expression_template_imports: Vec<serde_json::Value>,
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

    /// Members-fed-back-as-const-factor for `kind: "derived"` (projection-
    /// pushdown Phase 2b Hook 1, CONFORMANCE_SPEC §5.5.6).
    ///
    /// Names a model `parameter` const factor that the build fills with this
    /// set's materialized value-invention MEMBERS — the invented 1-based
    /// full-grid ids, `vi.members[from_faq]` — so an in-model gather
    /// `index(W, index(<member_factor>, c))` can pull the full-grid rows the
    /// compact derived axis selects. There is no `member(set, c)` IR op; this
    /// feedback IS the mechanism.
    ///
    /// `None` for every non-feedback set, so ordinary sets round-trip
    /// byte-identically. Mirrors the Julia reference's `IndexSet.member_factor`
    /// and the `member_factor` property of esm-schema.json. Without it the Rust
    /// binding silently DROPPED a normative field on parse, so a parse→emit
    /// round-trip of an overlap-gated document (the shared
    /// `overlap_gate_point_in_rect.esm` fixture among them) lost it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub member_factor: Option<String>,

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

/// One entry of the document-scoped [`EsmFile::coordinates`] registry
/// (RFC streaming-output-sinks §8.3): marks an existing data array — or an
/// inline literal vector — as a physical coordinate and attaches CF metadata.
///
/// Exactly one of `source` and `values` is present. The coordinate's shape
/// comes from its source, so it is NOT attached to any single axis: that one
/// rule covers rectilinear (1-D monotonic → CF *dimension* coordinate),
/// unstructured (1-D over a shared dimension) and curvilinear (2-D `lat(y,x)`)
/// grids, the latter two emitting CF *auxiliary* coordinates.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Coordinate {
    /// Name of an existing data array (model variable, parameter, or loader
    /// field) supplying this coordinate's values. Mutually exclusive with
    /// `values`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,

    /// Inline literal 1-D coordinate vector for the simple rectilinear case,
    /// mirroring [`FunctionTableAxis::values`]. Mutually exclusive with
    /// `source`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<Vec<f64>>,

    /// CF standard name (e.g. `"latitude"`), emitted verbatim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub standard_name: Option<String>,

    /// CF/UDUNITS units string (e.g. `"degrees_north"`). Advisory at load
    /// time, matching [`FunctionTableAxis::units`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,

    /// CF axis role (`"X"` / `"Y"` / `"Z"` / `"T"`) for a 1-D monotonic
    /// dimension coordinate; absent for auxiliary coordinates, which have no
    /// single axis.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub axis: Option<String>,
}

/// ODE-based model component
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Model {
    /// Human-readable model name
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

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

    /// The unit the `default` VALUE is expressed in, when it is not the
    /// variable's declared `units` (schema `ModelVariable.default_units`).
    ///
    /// The schema's contract is that `default` is given in the declared `units`,
    /// so a `default_units` naming a DIFFERENT unit is a defect: `units: "K"`
    /// with `default: 25.0, default_units: "degC"` means the stored number is 25
    /// but the variable actually reads 298.15. Rust did not model the field at
    /// all, so the mismatch was silently dropped on load.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_units: Option<String>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

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

    /// Parameter-only: draw the value from a distribution instead of fixing it
    /// at `default` (esm-spec §6.3, schema `ModelVariable.distribution`).
    /// Mutually exclusive with `default`. With no `update` the draw happens
    /// ONCE at setup (`sampled_parameters`); with `update.kind: "wiener"` it is
    /// redrawn every step with √dt scaling (`brownian_parameters`), which is
    /// what promotes the enclosing model to an SDE. This subsumes the 0.x
    /// `brownian` type's `noise_kind` / `correlation_group` tags: correlated
    /// noise is one vector-valued parameter carrying a `cov` matrix, which the
    /// tags never actually gave.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub distribution: Option<Distribution>,

    /// Parameter-only: when this parameter refreshes and what from
    /// (esm-spec §5.4). Absent means it never changes after setup. One
    /// mechanism replacing three 0.x constructs — the `brownian` type, the
    /// `discrete` type's `refresh` trigger, and the `discrete_parameters`
    /// event lists with their `functional_affect`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update: Option<ParameterUpdateSpec>,
}

impl ModelVariable {
    /// Visit every Expression this variable carries, in a stable order.
    ///
    /// From esm 1.0.0 a variable has no `expression` field — an unknown's
    /// definition is an EQUATION. What is left on the variable is the
    /// parameter's `update`: each rule's `when` trigger, its `expression`
    /// value form, and the `unit_conversion` of a `from` binding. All three
    /// are Expression positions and so are subject to reference integrity
    /// (esm-spec §4.9.5), which is what this walk exists to serve.
    pub fn for_each_expression(&self, f: &mut impl FnMut(&Expr)) {
        let Some(spec) = &self.update else { return };
        for rule in spec.rules() {
            if let Some(when) = rule.when() {
                f(when);
            }
            let Some(value) = rule.value() else { continue };
            if let Some(expr) = &value.expression {
                f(expr);
            }
            if let Some(UnitConversion::Expression(expr)) =
                value.from.as_ref().and_then(|b| b.unit_conversion.as_ref())
            {
                f(expr);
            }
        }
    }

    /// Mutable counterpart of [`ModelVariable::for_each_expression`], for the
    /// namespacing / renaming / range-resolution passes.
    pub fn for_each_expression_mut(&mut self, f: &mut impl FnMut(&mut Expr)) {
        let Some(spec) = &mut self.update else { return };
        let rules: &mut [ParameterUpdate] = match spec {
            ParameterUpdateSpec::Single(rule) => std::slice::from_mut(rule),
            ParameterUpdateSpec::Several(rules) => rules,
        };
        for rule in rules {
            if let Some(when) = rule.when_mut() {
                f(when);
            }
            let Some(value) = rule.value_mut() else {
                continue;
            };
            if let Some(expr) = &mut value.expression {
                f(expr);
            }
            if let Some(UnitConversion::Expression(expr)) = value
                .from
                .as_mut()
                .and_then(|b| b.unit_conversion.as_mut())
            {
                f(expr);
            }
        }
    }

    /// The `data_sources` keys this variable's update rules read from.
    pub fn update_sources(&self) -> Vec<&str> {
        self.update
            .iter()
            .flat_map(|spec| spec.rules())
            .filter_map(|rule| rule.data_source())
            .collect()
    }
}

/// A parameter's value drawn from a probability distribution rather than fixed
/// (esm-spec §6.3, schema `Distribution`). The closed set is `normal`,
/// `lognormal`, `uniform` — bindings implement exactly these and reject
/// anything else.
///
/// Univariate when the location parameter is a number, multivariate when it is
/// an array — in which case `cov` gives the full covariance matrix and the
/// parameter's `shape` must agree.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Distribution {
    /// Gaussian. Exactly one of `std` (independent components) or `cov`.
    Normal {
        /// Mean — a number (scalar) or one entry per component (vector).
        mean: DistributionParam,
        /// Standard deviation of INDEPENDENT components. Excludes `cov`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        std: Option<DistributionParam>,
        /// Full covariance matrix, row-major. Excludes `std`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cov: Option<CovarianceMatrix>,
    },
    /// Log-normal: `ln(value)` is normal with mean `mu` and spread
    /// `sigma` / `cov` (both on the LOG scale).
    Lognormal {
        /// Mean of the underlying normal (log scale).
        mu: DistributionParam,
        /// Standard deviation of the underlying normal. Excludes `cov`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sigma: Option<DistributionParam>,
        /// Full covariance matrix on the log scale. Excludes `sigma`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cov: Option<CovarianceMatrix>,
    },
    /// Uniform on `[low, high]`. Components are independent by construction, so
    /// there is no covariance form.
    Uniform {
        /// Lower bound(s).
        low: DistributionParam,
        /// Upper bound(s).
        high: DistributionParam,
    },
}

impl Distribution {
    /// The distribution's `kind` string, as it appears on the wire.
    pub fn kind(&self) -> &'static str {
        match self {
            Distribution::Normal { .. } => "normal",
            Distribution::Lognormal { .. } => "lognormal",
            Distribution::Uniform { .. } => "uniform",
        }
    }

    /// The LOCATION parameter (`mean` / `mu` / `low`), whose form decides
    /// whether the distribution is univariate or multivariate.
    pub fn location(&self) -> &DistributionParam {
        match self {
            Distribution::Normal { mean, .. } => mean,
            Distribution::Lognormal { mu, .. } => mu,
            Distribution::Uniform { low, .. } => low,
        }
    }

    /// True when the location parameter is an array — the schema's
    /// univariate/multivariate discriminator.
    pub fn is_multivariate(&self) -> bool {
        self.location().is_vector()
    }

    /// The full covariance matrix, when this distribution carries one.
    pub fn cov(&self) -> Option<&CovarianceMatrix> {
        match self {
            Distribution::Normal { cov, .. } | Distribution::Lognormal { cov, .. } => cov.as_ref(),
            Distribution::Uniform { .. } => None,
        }
    }
}

/// A distribution's location/scale parameter: a number for a scalar parameter,
/// an array for a vector-valued one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum DistributionParam {
    /// Scalar (univariate) form.
    Scalar(f64),
    /// Per-component (multivariate) form.
    Vector(Vec<f64>),
}

impl DistributionParam {
    /// True when this is the multivariate (array) form.
    pub fn is_vector(&self) -> bool {
        matches!(self, DistributionParam::Vector(_))
    }
}

/// Symmetric positive-semidefinite covariance matrix, row-major: entry
/// `[i][j]` is the covariance of components `i` and `j`.
pub type CovarianceMatrix = Vec<Vec<f64>>;

/// A parameter's update behaviour (esm-spec §5.4, schema
/// `ParameterUpdateSpec`): EITHER a single rule, OR an ordered array of two or
/// more applied in declaration order.
///
/// A single rule MUST be the object form — a one-element array is invalid — so
/// every update set has exactly one spelling and the round trip is stable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ParameterUpdateSpec {
    /// The object form: exactly one rule.
    Single(ParameterUpdate),
    /// The array form: two or more rules, applied in declaration order.
    Several(Vec<ParameterUpdate>),
}

impl ParameterUpdateSpec {
    /// The rules, in declaration order. The single form yields a one-element
    /// slice, so every consumer reads one shape.
    pub fn rules(&self) -> &[ParameterUpdate] {
        match self {
            ParameterUpdateSpec::Single(rule) => std::slice::from_ref(rule),
            ParameterUpdateSpec::Several(rules) => rules,
        }
    }

    /// True iff ANY rule is `wiener` — the `brownian_parameters` test
    /// (esm-spec §6.3.1). The schema forbids `wiener` inside the array form,
    /// so in practice only the single form can answer true.
    pub fn is_wiener(&self) -> bool {
        self.rules()
            .iter()
            .any(|r| matches!(r, ParameterUpdate::Wiener))
    }

    /// True iff any rule requires the variable to declare a `shape` —
    /// `schedule`, `data`, or `remesh` (esm-spec §5.4 "Cadence"): such a
    /// parameter is a buffer whose extent is fixed at setup.
    pub fn requires_shape(&self) -> bool {
        self.rules().iter().any(|r| {
            matches!(
                r,
                ParameterUpdate::Schedule { .. }
                    | ParameterUpdate::Data { .. }
                    | ParameterUpdate::Remesh { .. }
            )
        })
    }
}

/// One update rule: WHEN a parameter refreshes, and WHAT from
/// (esm-spec §5.4). Every kind except `wiener` carries exactly one value form
/// — `expression`, `from`, or `handler` — held in the flattened
/// [`UpdateValue`]; `wiener` carries none, because the parameter's
/// `distribution` IS its value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ParameterUpdate {
    /// A driving Wiener (Brownian) process: the parameter's `distribution` is
    /// resampled every step with √dt increment scaling. Any such parameter
    /// promotes the enclosing model from an ODE system to an SDE system.
    Wiener,
    /// Time-driven refresh at preset `times` and/or on a periodic `interval`
    /// (at least one of the two is present) — the MTK `PresetTimeCallback` /
    /// `tstops` analogue.
    Schedule {
        /// Explicit simulation times (the tstops) at which to refresh.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        times: Option<Vec<f64>>,
        /// Periodic refresh interval in simulation time units.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        interval: Option<f64>,
        /// Offset from t=0 for the first periodic refresh.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        initial_offset: Option<f64>,
        /// The value form.
        #[serde(flatten)]
        value: UpdateValue,
    },
    /// Refresh at the end of any timestep at which the boolean `when` is true.
    Condition {
        /// Boolean expression tested at the end of each timestep.
        when: Expr,
        /// The value form.
        #[serde(flatten)]
        value: UpdateValue,
    },
    /// Refresh when `when` crosses zero, located by root-finding.
    Crossing {
        /// Expression whose zero crossing triggers the refresh.
        when: Expr,
        /// Which crossings count: `up`, `down`, or `any` (the default).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        direction: Option<String>,
        /// The value form.
        #[serde(flatten)]
        value: UpdateValue,
    },
    /// Refresh when the named `data_sources` entry advances a record.
    Data {
        /// Key of the `data_sources` entry driving the refresh. MUST resolve
        /// (`data_source_undefined`).
        source: String,
        /// The value form.
        #[serde(flatten)]
        value: UpdateValue,
    },
    /// Refresh on a mesh-topology change (AMR refinement, moving mesh).
    Remesh {
        /// Optional name of the remesh hook. Absent ⇒ any remesh event.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        hook: Option<String>,
        /// The value form.
        #[serde(flatten)]
        value: UpdateValue,
    },
}

impl ParameterUpdate {
    /// The rule's `kind` string, as it appears on the wire.
    pub fn kind(&self) -> &'static str {
        match self {
            ParameterUpdate::Wiener => "wiener",
            ParameterUpdate::Schedule { .. } => "schedule",
            ParameterUpdate::Condition { .. } => "condition",
            ParameterUpdate::Crossing { .. } => "crossing",
            ParameterUpdate::Data { .. } => "data",
            ParameterUpdate::Remesh { .. } => "remesh",
        }
    }

    /// The rule's value form, or `None` for `wiener` (which has none).
    pub fn value(&self) -> Option<&UpdateValue> {
        match self {
            ParameterUpdate::Wiener => None,
            ParameterUpdate::Schedule { value, .. }
            | ParameterUpdate::Condition { value, .. }
            | ParameterUpdate::Crossing { value, .. }
            | ParameterUpdate::Data { value, .. }
            | ParameterUpdate::Remesh { value, .. } => Some(value),
        }
    }

    /// Mutable access to the rule's value form, or `None` for `wiener`.
    pub fn value_mut(&mut self) -> Option<&mut UpdateValue> {
        match self {
            ParameterUpdate::Wiener => None,
            ParameterUpdate::Schedule { value, .. }
            | ParameterUpdate::Condition { value, .. }
            | ParameterUpdate::Crossing { value, .. }
            | ParameterUpdate::Data { value, .. }
            | ParameterUpdate::Remesh { value, .. } => Some(value),
        }
    }

    /// The boolean/zero-crossing trigger expression (`condition` / `crossing`).
    pub fn when(&self) -> Option<&Expr> {
        match self {
            ParameterUpdate::Condition { when, .. } | ParameterUpdate::Crossing { when, .. } => {
                Some(when)
            }
            _ => None,
        }
    }

    /// Mutable access to the trigger expression (`condition` / `crossing`).
    pub fn when_mut(&mut self) -> Option<&mut Expr> {
        match self {
            ParameterUpdate::Condition { when, .. } | ParameterUpdate::Crossing { when, .. } => {
                Some(when)
            }
            _ => None,
        }
    }

    /// The `data_sources` key this rule refreshes from, for the `data` kind.
    pub fn data_source(&self) -> Option<&str> {
        match self {
            ParameterUpdate::Data { source, .. } => Some(source.as_str()),
            _ => None,
        }
    }
}

/// The value form of an update rule: exactly one of `expression`, `from`, or
/// `handler` (esm-spec §5.4, "What: exactly one value form"). Modelled as three
/// options rather than an enum so the flattened round trip stays verbatim; the
/// "exactly one" constraint is a schema-layer check.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct UpdateValue {
    /// The new value, computed symbolically (§4).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expression: Option<Expr>,

    /// The new value, read from the `data_sources` entry named by
    /// `update.source` (§8).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<DataSourceBinding>,

    /// The new value, computed by a registered handler (§5.5).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handler: Option<FunctionalUpdate>,
}

/// A registered handler computing a parameter's new value when its update
/// fires (esm-spec §5.5). The 0.x event `functional_affect`, relocated onto the
/// parameter it writes — which is why it needs no `modified_params` list: it
/// writes exactly one thing, the parameter carrying it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FunctionalUpdate {
    /// Registered identifier for the handler implementation.
    pub handler_id: String,

    /// Unknowns read by the handler. Absent means none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_vars: Option<Vec<String>>,

    /// Parameters read by the handler. Absent means none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_params: Option<Vec<String>>,

    /// Handler-specific configuration, passed through verbatim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config: Option<serde_json::Value>,
}

/// Binds a parameter to ONE variable of a `data_sources` entry (esm-spec §8.5).
/// The 0.x `DataLoaderVariable` minus `units`: the units are the parameter's
/// own, declared once on the parameter instead of twice.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DataSourceBinding {
    /// Name of the variable in the source file supplying the values.
    pub file_variable: String,

    /// Multiplicative factor or Expression AST reaching the parameter's
    /// declared `units`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit_conversion: Option<UnitConversion>,

    /// Text-label decoding table, passed through verbatim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codes: Option<serde_json::Value>,

    /// Per-parameter override of the source-level `select`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub select: Option<serde_json::Value>,

    /// Brief description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Academic citation or data source reference.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,
}

/// Type of model variable (esm-spec §6.3). There are **two** declared types
/// and no third: everything else a solver needs — which unknowns are ODE
/// states, which parameters are Brownian — is DERIVED by
/// [`crate::classification`], never declared.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VariableType {
    /// A quantity the solver solves for. Its behaviour is stated by the
    /// model's `equations` and NOWHERE else — there is no `expression` field
    /// on a variable. Subsumes the 0.x `state` and `observed` types; which of
    /// the two an unknown is follows from the form of the equation LHS that
    /// defines it ([`crate::classification::ode_states`] /
    /// [`crate::classification::observed_unknowns`] /
    /// [`crate::classification::algebraic_unknowns`]).
    Unknown,
    /// A quantity supplied to the solver. Its value is `default` or a
    /// `distribution`, optionally refreshed by an `update` (§5.4). Subsumes
    /// the 0.x `parameter`, `brownian` and `discrete` types
    /// ([`crate::classification::brownian_parameters`] /
    /// [`crate::classification::discrete_parameters`] /
    /// [`crate::classification::sampled_parameters`] /
    /// [`crate::classification::constant_parameters`]).
    Parameter,
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
// Boxing the large variant would change the wire-facing construction/match
// ergonomics on one of the crate's most-touched types for a size win that
// profiling has not justified; when a variant IS boxed the field carries its
// own rationale (see AssertionReference::Expression).
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

/// Generic, runtime-agnostic description of an external data source
/// (esm-spec §8).
///
/// A `DataSource` is pure I/O (RFC pure-io-data-loaders §4.1): it locates,
/// reads, decodes, slices and filters bytes and nothing else. From esm 1.0.0 it
/// **exposes no variables and is not a component** — not a coupling endpoint,
/// not a subsystem, not a scoped-name path root. A model consumes it by
/// declaring a PARAMETER whose [`ParameterUpdate::Data`] names this entry and
/// binds one of its file variables ([`DataSourceBinding`]); the parameter owns
/// the units. Grid geometry a source reads arrives the same way, as ordinary
/// parameters, and is transformed downstream by `aggregate` FAQs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DataSource {
    /// Structural kind of the dataset. Scientific role (emissions,
    /// meteorology, elevation, ...) is not schema-validated and belongs in
    /// `metadata.tags`.
    pub kind: DataSourceKind,

    /// File discovery configuration.
    pub source: DataSourceLocation,

    /// Temporal coverage and record layout. ABSENT means non-time-varying,
    /// which is what refines a `data`-updated parameter's cadence seed from
    /// DISCRETE down to CONST (CONFORMANCE_SPEC.md §5.7.2).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temporal: Option<DataSourceTemporal>,

    /// Reproducibility contract — endian / float_format / integer_width
    /// (esm-spec §8.9.2). A binding that cannot honor the declared
    /// contract MUST reject the file at load.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub determinism: Option<DataSourceDeterminism>,

    /// Format-specific DECODE options, passed through to the format reader
    /// verbatim (esm-spec §8.9.1). Held as raw JSON — the set of keys is the
    /// bound reader's, not the schema's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reader_options: Option<serde_json::Value>,

    /// Source-level default slicing (esm-spec §8.9.2), overridable per
    /// parameter by [`DataSourceBinding::select`]. Raw JSON passthrough.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub select: Option<serde_json::Value>,

    /// Which records are real (esm-spec §8.9.3). Raw JSON passthrough.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub record_filter: Option<serde_json::Value>,

    /// A source that discovers its own size (esm-spec §8.9.4). Raw JSON
    /// passthrough.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extent: Option<serde_json::Value>,

    /// Academic citation or data source reference.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,

    /// Free-form metadata about the data source. Tags convey scientific role.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<DataSourceMetadata>,
}

/// Structural kind of a data loader dataset.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DataSourceKind {
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
pub struct DataSourceDeterminism {
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
pub struct DataSourceLocation {
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
pub struct DataSourceTemporal {
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

/// Multiplicative factor (number) or Expression AST used to convert source-
/// file values to the declared units.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
// Boxing the large variant would change the wire-facing construction/match
// ergonomics on one of the crate's most-touched types for a size win that
// profiling has not justified; when a variant IS boxed the field carries its
// own rationale (see AssertionReference::Expression).
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
pub struct DataSourceMetadata {
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

/// A `variable_map` coupling `transform` (esm-spec §10.4): either one of the
/// legacy NAMED transform strings (`"param_to_var"`, `"identity"`,
/// `"additive"`, `"multiplicative"`, `"conversion_factor"`) or an Expression
/// evaluated on the source value(s) in the flattened coupled system's scope
/// (the v0.8.0 additive widening — the regridding form).
///
/// On the wire an Expression transform is always an operator-node OBJECT: the
/// degenerate bare-reference and literal Expression spellings are not
/// admissible (the named string transforms already cover bare replacement,
/// and the string space is reserved for them), so a JSON string deserializes
/// to [`VariableMapTransform::Named`], an object to
/// [`VariableMapTransform::Expression`], and a bare number is rejected.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
// Boxing the large variant would change the wire-facing construction/match
// ergonomics on one of the crate's most-touched types for a size win that
// profiling has not justified; when a variant IS boxed the field carries its
// own rationale (see AssertionReference::Expression).
#[allow(clippy::large_enum_variant)]
pub enum VariableMapTransform {
    /// Legacy named transform string.
    Named(String),
    /// Expression transform: an operator node whose variable references are
    /// fully scoped and which MUST reference the entry's `from` variable
    /// (esm-spec §10.4). Template invocations inside it are expanded at load.
    Expression(ExpressionNode),
}

impl VariableMapTransform {
    /// The named transform string, if this is the legacy string form.
    pub fn as_named(&self) -> Option<&str> {
        match self {
            VariableMapTransform::Named(s) => Some(s.as_str()),
            VariableMapTransform::Expression(_) => None,
        }
    }

    /// The Expression operator node, if this is the expression form.
    pub fn as_expression(&self) -> Option<&ExpressionNode> {
        match self {
            VariableMapTransform::Named(_) => None,
            VariableMapTransform::Expression(node) => Some(node),
        }
    }

    /// Whether this is the expression form.
    pub fn is_expression(&self) -> bool {
        matches!(self, VariableMapTransform::Expression(_))
    }
}

impl std::fmt::Display for VariableMapTransform {
    /// Named transforms display as their string; expression transforms as the
    /// fixed token `expression` (matching the Julia / Python provenance
    /// descriptions in `coupling_rules_applied`).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VariableMapTransform::Named(s) => write!(f, "{s}"),
            VariableMapTransform::Expression(_) => write!(f, "expression"),
        }
    }
}

/// Coupling entry with discriminated union based on type field
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
// Boxing the large variant would change the wire-facing construction/match
// ergonomics on one of the crate's most-touched types for a size win that
// profiling has not justified; when a variant IS boxed the field carries its
// own rationale (see AssertionReference::Expression).
#[allow(clippy::large_enum_variant)]
pub enum CouplingEntry {
    /// Operator composition coupling
    OperatorCompose {
        /// The two systems to compose
        systems: Vec<String>,
        /// Variable mappings when LHS variables don't have matching names
        #[serde(skip_serializing_if = "Option::is_none")]
        translate: Option<serde_json::Value>,
        /// Spatial-lift strategy for the merged state ODEs (esm-spec §10.5).
        /// `"pointwise"` array-ifies each merged reaction+operator state ODE onto
        /// the operator's grid (the flattener's pointwise lift); `None` leaves the
        /// merged 0-D equations as-is.
        #[serde(skip_serializing_if = "Option::is_none")]
        lifting: Option<String>,
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
        /// How the mapping is applied: a named transform string or an
        /// Expression operator node (esm-spec §10.4).
        transform: VariableMapTransform,
        /// Conversion factor (for the scaling transforms only — not
        /// permitted with an Expression transform)
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
    /// Reuse of a coupling-library file (esm-spec §10.9, §10.10): imports the
    /// library named by `ref` and binds each of its declared roles to an
    /// assembly component. Expands at flatten into concrete
    /// `variable_map`/`couple`/`operator_compose`/`event` edges by substituting
    /// bound actuals for role names; the entry itself round-trips intact.
    CouplingImport {
        /// §4.7 reference to a coupling-library file (a document with a
        /// top-level `coupling_roles` map). `ref` is a Rust keyword, so the
        /// field is spelled `reference` and renamed on the wire.
        #[serde(rename = "ref")]
        reference: String,
        /// Total map from every library role name to a scoped component
        /// reference in the assembly (esm-spec §10.10.1).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        bind: Option<HashMap<String, String>>,
        /// Optional description
        #[serde(skip_serializing_if = "Option::is_none")]
        description: Option<String>,
    },
}

/// A coupling-library formal component role (esm-spec §10.9). Present only in
/// a coupling-library file's top-level `coupling_roles` map; each entry carries
/// an optional human-readable description. Roles are formal parameters (names,
/// not types), bound to actual components at a `coupling_import`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CouplingRole {
    /// Human-readable description of the role.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
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

#[cfg(test)]
mod coupling_field_tests {
    use super::*;

    #[test]
    fn test_operator_compose_new_fields() {
        // Test OperatorCompose with new systems field
        let json = r#"{
            "type": "operator_compose",
            "systems": ["system1", "system2"]
        }"#;

        let entry: CouplingEntry = serde_json::from_str(json).unwrap();
        match entry {
            CouplingEntry::OperatorCompose { systems, .. } => {
                assert_eq!(systems, vec!["system1", "system2"]);
            }
            _ => panic!("Expected OperatorCompose variant"),
        }
    }

    #[test]
    fn test_couple_new_fields() {
        // Test Couple with new systems field
        let json = r#"{
            "type": "couple",
            "systems": ["system1", "system2"],
            "connector": {
                "equations": []
            }
        }"#;

        let entry: CouplingEntry = serde_json::from_str(json).unwrap();
        match entry {
            CouplingEntry::Couple { systems, .. } => {
                assert_eq!(systems, vec!["system1", "system2"]);
            }
            _ => panic!("Expected Couple variant"),
        }
    }

    #[test]
    fn test_variable_map_new_fields() {
        // Test VariableMap with new from/to fields
        let json = r#"{
            "type": "variable_map",
            "from": "source.var",
            "to": "target.param",
            "transform": "identity"
        }"#;

        let entry: CouplingEntry = serde_json::from_str(json).unwrap();
        match entry {
            CouplingEntry::VariableMap {
                from,
                to,
                transform,
                ..
            } => {
                assert_eq!(from, "source.var");
                assert_eq!(to, "target.param");
                assert_eq!(
                    transform,
                    crate::types::VariableMapTransform::Named("identity".to_string())
                );
            }
            _ => panic!("Expected VariableMap variant"),
        }
    }

    #[test]
    fn test_coupling_serialization_round_trip() {
        // Test serialization round-trip
        let coupling = CouplingEntry::OperatorCompose {
            lifting: None,
            systems: vec!["sys1".to_string(), "sys2".to_string()],
            translate: None,
            description: None,
        };

        let serialized = serde_json::to_string(&coupling).unwrap();
        let deserialized: CouplingEntry = serde_json::from_str(&serialized).unwrap();

        match deserialized {
            CouplingEntry::OperatorCompose { systems, .. } => {
                assert_eq!(systems, vec!["sys1", "sys2"]);
            }
            _ => panic!("Round-trip failed"),
        }
    }
}

#[cfg(test)]
mod discrete_event_test {
    use super::*;

    #[test]
    fn test_discrete_event_fields_present() {
        // Test that we can create a DiscreteEvent with discrete_parameters and reinitialize
        let event = DiscreteEvent {
            name: Some("test_event".to_string()),
            trigger: DiscreteEventTrigger::Condition {
                expression: Expr::Number(1.0),
            },
            affects: None,
            functional_affect: None,
            discrete_parameters: Some(vec!["param1".to_string(), "param2".to_string()]),
            reinitialize: Some(true),
            description: Some("Test event".to_string()),
        };

        // Test serialization
        let json = serde_json::to_string(&event).expect("Serialization should work");
        assert!(
            json.contains("discrete_parameters"),
            "JSON should contain discrete_parameters field"
        );
        assert!(
            json.contains("reinitialize"),
            "JSON should contain reinitialize field"
        );
        assert!(
            json.contains("param1"),
            "JSON should contain the parameter values"
        );

        // Test deserialization
        let deserialized: DiscreteEvent =
            serde_json::from_str(&json).expect("Deserialization should work");

        assert_eq!(
            deserialized.discrete_parameters,
            Some(vec!["param1".to_string(), "param2".to_string()])
        );
        assert_eq!(deserialized.reinitialize, Some(true));
    }

    #[test]
    fn test_discrete_event_json_parsing() {
        let json = r#"
        {
            "trigger": {
                "type": "condition",
                "expression": 1.0
            },
            "discrete_parameters": ["param1", "param2"],
            "reinitialize": true
        }
        "#;

        let event: DiscreteEvent = serde_json::from_str(json)
            .expect("Should parse JSON with discrete_parameters and reinitialize");

        assert_eq!(
            event.discrete_parameters,
            Some(vec!["param1".to_string(), "param2".to_string()])
        );
        assert_eq!(event.reinitialize, Some(true));
    }
}
