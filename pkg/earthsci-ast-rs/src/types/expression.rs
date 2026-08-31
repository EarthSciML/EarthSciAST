use serde::{Deserialize, Serialize};
use std::collections::HashMap;

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
    /// a §9.7-expanded discretization repeats the same subtree tens of thousands
    /// of times — on a real model, millions of occurrences over a few thousand
    /// distinct subtrees — and with an unboxed several-hundred-byte node every
    /// occurrence was a full copy. Sharing the payload lets the load-time interner
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
// subtree. On a real model that made serde the overwhelming majority of load
// time, nearly all of it in `Content` cloning/dropping and the allocator traffic
// they drive. The failed-variant attempts also each construct a discarded
// `serde_json::Error`.
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

/// One bound of a `makearray` region box (esm-spec §4.3.2).
///
/// Almost always a concrete integer: esm-spec §9.7.6 folds metaparameter bound
/// expressions to integers at LOAD time, so every `regions` entry that reaches
/// an evaluator is an [`RegionBound::Int`], and every consumer here treats a
/// still-symbolic bound the way it treats a malformed region — it refuses the
/// node rather than guessing an extent.
///
/// The [`RegionBound::Expr`] variant exists for the PRE-load form the schema
/// admits (`"regions": [[[2, {"op": "-", "args": ["NLON", 1]}]]]`, whose bound
/// pairs are `MetaparameterExpression`s) and which
/// [`crate::parse_expression`] reconstructs from the text surface
/// `makearray([2:NLON - 1, …] = …)`. Without it the Rust AST could not hold —
/// and the printer could not reproduce — a document the other bindings load
/// unchanged.
///
/// [`RegionBound::Int`] is listed FIRST in this untagged enum so a JSON integer
/// still binds to it (and round-trips as an integer), exactly as before.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RegionBound {
    /// A concrete inclusive bound.
    Int(i64),
    /// An unfolded bound expression (a metaparameter reference or arithmetic
    /// over one). Never reaches an evaluator: §9.7.6 folding replaces it with
    /// [`RegionBound::Int`] at load.
    Expr(Expr),
}

impl RegionBound {
    /// The concrete integer value of this bound, or `None` when it is still a
    /// symbolic (unfolded) expression.
    #[must_use]
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            RegionBound::Int(i) => Some(*i),
            RegionBound::Expr(Expr::Integer(i)) => Some(*i),
            RegionBound::Expr(Expr::Number(n))
                if n.fract() == 0.0 && n.abs() < 9_223_372_036_854_775_808.0 =>
            {
                Some(*n as i64)
            }
            RegionBound::Expr(_) => None,
        }
    }
}

impl From<i64> for RegionBound {
    fn from(i: i64) -> Self {
        RegionBound::Int(i)
    }
}

/// The concrete `[lo, hi]` pair of a region dimension, or `None` when either
/// bound is still a symbolic expression. Every extent / bounding-box computation
/// goes through this, so an unfolded bound can never be silently read as `0`.
#[must_use]
pub fn region_bounds(pair: &[RegionBound; 2]) -> Option<[i64; 2]> {
    Some([pair[0].as_i64()?, pair[1].as_i64()?])
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
    /// The build-time resolution of this clause's `on` pairs into the two loop
    /// symbols they gate and the key columns supplying each side's values
    /// (CONFORMANCE_SPEC §5.5.8), attached by
    /// [`crate::join::resolve_aggregate_joins`]. It is what lets the equality
    /// gate DRIVE enumeration — bind the two gated symbols from the match set
    /// instead of testing every tuple of the full product — exactly as
    /// [`OverlapClause::sym_src`] / [`OverlapClause::sym_tgt`] do for the
    /// spatial gate. `None` before resolution, and for a clause whose pairs are
    /// positional no-ops.
    ///
    /// NOT part of the wire form: `#[serde(skip)]` keeps every document's
    /// parse -> emit round trip byte-identical.
    #[serde(skip)]
    pub on_gate: Option<crate::join::OnGate>,
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
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "output_idx_serde"
    )]
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
    ///
    /// A bound is normally a concrete integer; the schema also admits an
    /// unfolded metaparameter bound EXPRESSION, which is why the element type
    /// is [`RegionBound`] rather than `i64` — see that type's docs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub regions: Option<Vec<Vec<[RegionBound; 2]>>>,

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

    /// Optional AUTHOR assertion on this node's cadence class — one of
    /// `"const"`, `"discrete"`, `"continuous"` (RFC semiring-faq-unified-ir
    /// §6.1; CONFORMANCE_SPEC.md §5.7.6 rule 3).
    ///
    /// A diagnostic/test hook only: it changes no semantics. The
    /// dependency-partition pass DERIVES every node's class from the
    /// data-dependency DAG and, where this is present, errors if the derived
    /// class disagrees. The pass only READS it — nothing consumes or rewrites
    /// it — so it is authored content that must survive parse → emit, exactly
    /// as it already does in the Go and TypeScript bindings. Dropping it
    /// silently disarmed the assertion guarding the whole §5.7 contract on any
    /// document this binding re-emitted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expect_cadence: Option<String>,

    /// Named scalar attributes for an OPEN rewrite-target op (esm-spec §4.2).
    ///
    /// Mirrors the role of the fixed `dim`/`side`/`wrt`/`var` slots core ops
    /// use, but is open: a custom op (e.g. `godunov_hamiltonian`) carries its
    /// scheme parameters here, and in a rewrite rule's `match` an
    /// `attrs.<key>` whose value is a bare param name binds that param to the
    /// matched literal (esm-spec §9.6.1). Evaluable-core ops MUST NOT use
    /// `attrs`, so it never appears on a lowered tree — but it is authored
    /// content on the pre-lowering tree and must round-trip.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attrs: Option<serde_json::Value>,
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
    assert!(
        j == N,
        "child-key count does not match the declared array length"
    );
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
        for a in &$node.$field {
            $f(a);
        }
    };
    (@each opt_array, $node:tt, $f:ident, $field:ident) => {
        if let Some(vs) = &$node.$field {
            for v in vs {
                $f(v);
            }
        }
    };
    (@each scalar, $node:tt, $f:ident, $field:ident) => {
        if let Some(e) = $node.$field.as_deref() {
            $f(e);
        }
    };
    (@each map, $node:tt, $f:ident, $field:ident) => {
        if let Some(m) = &$node.$field {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            for k in keys {
                $f(&m[k]);
            }
        }
    };

    // for_each_child_mut: mutable; maps visited in sorted-key order.
    (@each_mut array, $node:tt, $f:ident, $field:ident) => {
        for a in &mut $node.$field {
            $f(a);
        }
    };
    (@each_mut opt_array, $node:tt, $f:ident, $field:ident) => {
        if let Some(vs) = &mut $node.$field {
            for v in vs {
                $f(v);
            }
        }
    };
    (@each_mut scalar, $node:tt, $f:ident, $field:ident) => {
        if let Some(e) = $node.$field.as_deref_mut() {
            $f(e);
        }
    };
    (@each_mut map, $node:tt, $f:ident, $field:ident) => {
        if let Some(m) = &mut $node.$field {
            let mut keys: Vec<String> = m.keys().cloned().collect();
            keys.sort();
            for k in keys {
                if let Some(v) = m.get_mut(&k) {
                    $f(v);
                }
            }
        }
    };

    // any_child: a short-circuiting bool per field (the OR result is
    // order-independent, so maps need not be sorted here).
    (@any array, $node:tt, $f:ident, $field:ident) => {
        $node.$field.iter().any(&mut *$f)
    };
    (@any opt_array, $node:tt, $f:ident, $field:ident) => {
        $node
            .$field
            .as_ref()
            .is_some_and(|vs| vs.iter().any(&mut *$f))
    };
    (@any scalar, $node:tt, $f:ident, $field:ident) => {
        $node.$field.as_deref().is_some_and(|e| $f(e))
    };
    (@any map, $node:tt, $f:ident, $field:ident) => {
        $node
            .$field
            .as_ref()
            .is_some_and(|m| m.values().any(&mut *$f))
    };

    // map_children: rebuild each child field onto `$out` (maps not reordered —
    // a rebuilt `HashMap`'s iteration order is irrelevant).
    (@map array, $node:tt, $out:ident, $f:ident, $field:ident) => {
        $out.$field = $node.$field.iter().map(&mut *$f).collect();
    };
    (@map opt_array, $node:tt, $out:ident, $f:ident, $field:ident) => {
        $out.$field = $node
            .$field
            .as_ref()
            .map(|vs| vs.iter().map(&mut *$f).collect());
    };
    (@map scalar, $node:tt, $out:ident, $f:ident, $field:ident) => {
        $out.$field = $node.$field.as_deref().map(|e| Box::new($f(e)));
    };
    (@map map, $node:tt, $out:ident, $f:ident, $field:ident) => {
        $out.$field = $node
            .$field
            .as_ref()
            .map(|m| m.iter().map(|(k, v)| (k.clone(), $f(v))).collect());
    };

    // Shape → JSON-key-constant bucket tag.
    (@tag array) => {
        CHILD_ARRAY
    };
    (@tag opt_array) => {
        CHILD_ARRAY
    };
    (@tag scalar) => {
        CHILD_SCALAR
    };
    (@tag map) => {
        CHILD_MAP
    };
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
            /// family (or [`Self::map_children`] / [`Self::any_child`] /
            /// [`Self::try_for_each_child`]) rather
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

impl ExpressionNode {
    /// Error-propagating [`Self::for_each_child`]: visits the same child set
    /// in the same contractual order and returns the FIRST error `f` raises
    /// (later children are not passed to `f`).
    ///
    /// Defined in terms of `for_each_child` itself, so the two can never
    /// disagree about which fields carry children. This is the walker for the
    /// recursive "check every child, fail on the first offender" passes that
    /// previously hand-captured the first error in a closure at each call
    /// site.
    pub fn try_for_each_child<'a, E>(
        &'a self,
        f: &mut impl FnMut(&'a Expr) -> Result<(), E>,
    ) -> Result<(), E> {
        let mut first_err: Option<E> = None;
        self.for_each_child(&mut |child| {
            if first_err.is_none()
                && let Err(e) = f(child)
            {
                first_err = Some(e);
            }
        });
        match first_err {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// Mutable [`Self::try_for_each_child`], defined in terms of
    /// [`Self::for_each_child_mut`] the same way. Children after the first
    /// error are not passed to `f`, so they are left unmodified.
    pub fn try_for_each_child_mut<E>(
        &mut self,
        f: &mut impl FnMut(&mut Expr) -> Result<(), E>,
    ) -> Result<(), E> {
        let mut first_err: Option<E> = None;
        self.for_each_child_mut(&mut |child| {
            if first_err.is_none()
                && let Err(e) = f(child)
            {
                first_err = Some(e);
            }
        });
        match first_err {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }
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
        for src in [
            "null",
            "true",
            "false",
            "[]",
            "[1,2]",
            "{}",
            r#"{"op":"x"}"#,
        ] {
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
        assert_eq!(
            EXPR_SCALAR_CHILD_KEYS,
            ["lower", "upper", "expr", "filter", "key"]
        );
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
                "args0", "lower", "upper", "expr", "filter", "values0", "axes_a",
                "axes_z", // axes: sorted by key
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

        // try_for_each_child: same sequence on Ok; the first Err propagates
        // and later children are not visited. Same for the mutable variant.
        let mut seen_try = Vec::new();
        let ok: Result<(), ()> = node.try_for_each_child(&mut |c| {
            if let Expr::Variable(v) = c {
                seen_try.push(v.clone());
            }
            Ok(())
        });
        assert_eq!(ok, Ok(()));
        assert_eq!(seen, seen_try);

        let mut before_err = Vec::new();
        let failed = node.try_for_each_child(&mut |c| {
            if let Expr::Variable(v) = c {
                before_err.push(v.clone());
                if v == "expr" {
                    return Err(format!("stopped at {v}"));
                }
            }
            Ok(())
        });
        assert_eq!(failed, Err("stopped at expr".to_string()));
        assert_eq!(before_err, vec!["args0", "lower", "upper", "expr"]);

        let mut count_try_mut = 0usize;
        let failed_mut: Result<(), ()> = node.try_for_each_child_mut(&mut |_c| {
            count_try_mut += 1;
            if count_try_mut == 2 { Err(()) } else { Ok(()) }
        });
        assert_eq!(failed_mut, Err(()));
        assert_eq!(count_try_mut, 2);
    }
}
