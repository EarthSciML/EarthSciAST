//! Build-time relational engine — the five primitives the unified-IR
//! value-invention pass (RFC `semiring-faq-unified-ir` §5.5, §6.1) runs **once at
//! setup**, off the per-timestep hot path, to materialise the data-derived index
//! sets and dense IDs that the numeric stencil then consumes:
//!
//! 1. [`distinct`]        — deduplicate tuples (unique mesh edges from face→vertex lists)
//! 2. `equijoin`          — value-equality equi-join (connectivity inversion, *edges of cell i*)
//! 3. [`skolem`] / [`skolem_edge`] — deterministic content-addressed key from a tuple
//! 4. [`rank`]            — dense integer renumbering of a distinct set
//! 5. [`group_aggregate`] — group-by + associative/commutative semiring `⊕` (sum/min/max/…)
//!
//! # Determinism (the reason this module exists)
//!
//! `earthsci-ast` is **parallel native implementations** (Julia, Rust, Python)
//! verified by a conformance suite, not one core behind FFI. So the hard problem is
//! **bit-for-bit determinism across the bindings**: identical deduped sets,
//! identical dense IDs, identical skolem keys. The governing principle
//! (`CONFORMANCE_SPEC.md` §5.5 = RFC §5.7) is that *every emitted set, key, and
//! dense ID is a pure function of a defined total order over tuples* — **no
//! observable output may depend on hash-table iteration order or a language-native
//! hash value** (Rust `HashMap`/`HashSet` use a per-instance random SipHash seed,
//! so their iteration order is not portable).
//!
//! This is the Rust side of bead `ess-my4.3.4`; the Julia
//! (`EarthSciAST.Relational`, `ess-my4.3.3`) and Python (`ess-my4.3.5`)
//! bindings implement the same §5.5 contract, so all three produce byte-identical
//! index sets and identical (base-normalised) dense-ID arrays. Concretely, per
//! `CONFORMANCE_SPEC.md` §5.5.1:
//!
//! - **Total order** — lexicographic over tuple fields; integers by value; strings
//!   by Unicode code-point (UTF-8 byte) order. Rust's derived [`Ord`] on [`Key`]
//!   gives exactly this: `i64` by value, `String` by UTF-8 bytes (= code-point
//!   order), and `Vec<Key>` lexicographically. **Floats are forbidden in keys**
//!   (rule 1) — enforced *by construction*: [`Key`] has no float variant, and the
//!   JSON boundary constructor [`Key::try_from_json`] rejects float components with
//!   [`FloatKeyError`]. (Float *values* in a [`group_aggregate`] are allowed; see
//!   [`Num`].)
//! - **`distinct`** — sort by the total order, drop *adjacent* duplicates; output
//!   order *is* sorted order, never first-seen / insertion order (rule 2).
//! - **`rank`** — dense IDs by position in the sorted distinct sequence. Rust emits
//!   **0-based** (`CONFORMANCE_SPEC.md` §5.5.1 rule 3 pins Rust = base 0 = the
//!   canonical numbering); [`rank_with_base`] supports an arbitrary base for the
//!   conformance base-pin round-trip (`canonical = reported − base`).
//! - **`skolem`** — a canonical *tuple*, never a hash (rule 4): sort components for
//!   a symmetric relation (undirected edge `(min,max)`), preserve order for a
//!   directed one.
//! - **`join` / group-by** — hashing may bucket only (we use [`indexmap::IndexMap`],
//!   whose iteration order is insertion order, independent of the hasher); the
//!   result is emitted **sorted by the canonical key** (rule 5). The semiring `⊕`
//!   must be associative + commutative; for a floating-point `⊕` the per-bucket
//!   reduction is done sequentially in canonical value order to avoid last-ULP
//!   drift.
//!
//! # Implementation notes (RFC Appendix A.4, Rust)
//!
//! Built on `indexmap` (already a dep) `IndexMap` for bucketing + `sort_unstable`
//! on the full tuple. The float-normalisation helper [`format_canonical_float`] is
//! reused from [`crate::canonicalize`] for the skolem/distinct float-value
//! serialisation base, and the sort-then-enumerate `rank` pattern mirrors
//! `src/performance.rs`. `polars`/`datafusion`/`arrow` are rejected (heavy, out of
//! proportion — RFC A.3/A.4); a non-portable fast hasher (`ahash`,
//! `rustc-hash`/FxHash) MUST NEVER drive emitted order or keys.

use crate::canonicalize::format_canonical_float;
use indexmap::IndexMap;
use std::cmp::Ordering;

/// Raised when a relational key contains a floating-point (or otherwise
/// non-integer / out-of-domain) component, violating `CONFORMANCE_SPEC.md`
/// §5.5.1 rule 1 ("floats are forbidden in keys"). Normalise the value to an
/// integer / categorical ID before the build-time pre-pass.
///
/// In Rust rule 1 is enforced *by construction* — [`Key`] simply has no float
/// variant — so this error only arises at the untyped JSON boundary
/// ([`Key::try_from_json`]), the analogue of the Julia/Python reference's
/// per-primitive `assert_key` runtime check.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("FloatKeyError: {0}")]
pub struct FloatKeyError(pub String);

/// A relational **key** component: an integer / categorical ID, or a tuple
/// thereof. This is the orderable, float-free domain over which the five
/// primitives operate.
///
/// The derived [`Ord`] *is* the `CONFORMANCE_SPEC.md` §5.5.1 rule-1 total order
/// **within a type**: [`Key::Int`] by value, [`Key::Str`] by UTF-8 byte order
/// (= Unicode code-point order, *not* locale collation), and [`Key::Tuple`]
/// lexicographically. Cross-type comparison (e.g. an `Int` against a `Str`) falls
/// back to the variant declaration order; it is deterministic but never exercised
/// by a conformant index set, whose rows are homogeneous.
///
/// There is deliberately **no float variant** — that is how rule 1 ("floats are
/// forbidden in keys") is enforced in a statically-typed binding. Float *values*
/// for aggregation live in [`Num`], not here.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Key {
    /// An integer ID (vertex / cell index, scale 10⁴–10⁷).
    Int(i64),
    /// A categorical string ID. Ordered by UTF-8 byte / Unicode code-point order.
    Str(String),
    /// A boolean ID (boolean-or keys). Ordered `false < true`.
    Bool(bool),
    /// A tuple of components (e.g. a mesh edge `(v_lo, v_hi)`). Ordered
    /// lexicographically.
    Tuple(Vec<Key>),
}

impl Key {
    /// Construct a [`Key`] from an untyped JSON value, **rejecting floats**
    /// (rule 1) at the boundary — the analogue of the Julia/Python reference's
    /// `assert_key`. A JSON number with a fractional part or exponent (e.g.
    /// `1.5`, `1.0`) is a float and raises [`FloatKeyError`]; a bare integer
    /// (`1`, `-3`) becomes [`Key::Int`]. `null` and objects are not valid keys.
    pub fn try_from_json(value: &serde_json::Value) -> Result<Key, FloatKeyError> {
        match value {
            serde_json::Value::Bool(b) => Ok(Key::Bool(*b)),
            serde_json::Value::String(s) => Ok(Key::Str(s.clone())),
            serde_json::Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    Ok(Key::Int(i))
                } else if let Some(u) = n.as_u64() {
                    Err(FloatKeyError(format!(
                        "integer {u} out of range for a relational key (i64 domain)"
                    )))
                } else {
                    Err(FloatKeyError(format!(
                        "float {n} forbidden in a relational key; keys must be \
                         integer / categorical IDs (CONFORMANCE_SPEC.md §5.5.1 \
                         rule 1) — normalise to an ID before the build-time \
                         relational pre-pass"
                    )))
                }
            }
            serde_json::Value::Array(items) => {
                let mut out = Vec::with_capacity(items.len());
                for item in items {
                    out.push(Key::try_from_json(item)?);
                }
                Ok(Key::Tuple(out))
            }
            serde_json::Value::Null | serde_json::Value::Object(_) => Err(FloatKeyError(format!(
                "unsupported relational key component {value}; keys must be \
                 integer / categorical IDs or tuples thereof"
            ))),
        }
    }

    /// Append this key's canonical-JSON token to `out` (`CONFORMANCE_SPEC.md`
    /// §5.5.3): integers as bare digits, booleans as `true`/`false`, strings as
    /// JSON-escaped quoted strings (UTF-8, no `\uXXXX` escaping of non-ASCII),
    /// tuples as nested arrays. Compact — no spaces.
    fn write_token(&self, out: &mut String) {
        match self {
            Key::Int(i) => out.push_str(&i.to_string()),
            Key::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            // serde_json gives exactly the canonical JSON string escaping
            // (escape `"`, `\`, and control chars; raw UTF-8 otherwise), matching
            // the Julia `JSON3.write` and Python `json.dumps(ensure_ascii=False)`
            // reference serialisers byte-for-byte.
            Key::Str(s) => {
                out.push_str(&serde_json::to_string(s).expect("a string always serialises to JSON"))
            }
            Key::Tuple(items) => write_array(out, items, |o, k| k.write_token(o)),
        }
    }
}

/// A numeric **value** for [`group_aggregate`]. Unlike [`Key`], values may be
/// floating-point (only *keys* are float-forbidden, rule 1). Integer aggregates
/// stay integer (so a sum serialises as `5`, not `5.0`); a float anywhere in a
/// bucket promotes the reduction to `f64`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Num {
    /// An exact integer value.
    Int(i64),
    /// A floating-point value.
    Float(f64),
}

impl Num {
    fn as_f64(self) -> f64 {
        match self {
            Num::Int(i) => i as f64,
            Num::Float(f) => f,
        }
    }

    /// Total order over values, used only to put each bucket's values into a
    /// canonical order before the sequential reduction (rule 5). `Int` sorts
    /// before `Float` (the two never mix in a conformant bucket); floats use
    /// [`f64::total_cmp`] so `-0.0`/`NaN` are still totally ordered.
    fn canonical_cmp(&self, other: &Num) -> Ordering {
        match (self, other) {
            (Num::Int(a), Num::Int(b)) => a.cmp(b),
            (Num::Float(a), Num::Float(b)) => a.total_cmp(b),
            (Num::Int(_), Num::Float(_)) => Ordering::Less,
            (Num::Float(_), Num::Int(_)) => Ordering::Greater,
        }
    }

    /// Append this value's canonical-JSON token to `out`. Integers are bare
    /// digits; floats use [`format_canonical_float`] (the RFC §5.4.6 form, reused
    /// from [`crate::canonicalize`]).
    fn write_token(&self, out: &mut String) {
        match self {
            Num::Int(i) => out.push_str(&i.to_string()),
            Num::Float(f) => out.push_str(&format_canonical_float(*f)),
        }
    }
}

/// An associative + commutative semiring combiner for [`group_aggregate`]
/// (rule 5). Every registry `⊕` is one of these, so input and bucket order can
/// never change the result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SemiringOp {
    /// Sum (`+`).
    Sum,
    /// Product (`*`).
    Prod,
    /// Minimum.
    Min,
    /// Maximum.
    Max,
}

impl SemiringOp {
    /// Combine two values. Integer inputs stay integer (with wrapping `i64`
    /// arithmetic, matching Julia's native `Int64`); if either input is a float
    /// the reduction promotes to `f64`.
    fn apply(self, a: Num, b: Num) -> Num {
        match (a, b) {
            (Num::Int(x), Num::Int(y)) => Num::Int(match self {
                SemiringOp::Sum => x.wrapping_add(y),
                SemiringOp::Prod => x.wrapping_mul(y),
                SemiringOp::Min => x.min(y),
                SemiringOp::Max => x.max(y),
            }),
            _ => {
                let (x, y) = (a.as_f64(), b.as_f64());
                Num::Float(match self {
                    SemiringOp::Sum => x + y,
                    SemiringOp::Prod => x * y,
                    SemiringOp::Min => x.min(y),
                    SemiringOp::Max => x.max(y),
                })
            }
        }
    }
}

// ── Primitive 3: skolem (canonical-tuple content-addressed key) ─────────────

/// Canonical key for an **undirected** pair (a symmetric relation):
/// `(min(a,b), max(a,b))`. The deterministic, content-addressed identity of a
/// mesh edge (RFC §5.5 generalises ESI `pack`). It is **not** a hash (rule 4) —
/// the tuple itself is the key, so the dense ID later assigned by [`rank`] is
/// reproducible across bindings. Equal components are preserved (`(7,7)`).
pub fn skolem_edge(a: Key, b: Key) -> Key {
    if a <= b {
        Key::Tuple(vec![a, b])
    } else {
        Key::Tuple(vec![b, a])
    }
}

/// Canonical-tuple Skolem key (rule 4). For a `symmetric` relation the
/// components are sorted (generalising [`skolem_edge`] to arity > 2); for a
/// directed relation the order is preserved, so `(1, 2)` and `(2, 1)` stay
/// distinct. Never a native hash — the tuple *is* the content-addressed key; the
/// dense ID then comes from [`rank`].
pub fn skolem(mut components: Vec<Key>, symmetric: bool) -> Key {
    if symmetric {
        components.sort_unstable();
    }
    Key::Tuple(components)
}

// ── Primitive 1: distinct (sort + drop adjacent duplicates) ─────────────────

/// Set semantics over `rows`: sort by the §5.5.1 total order, then drop
/// **adjacent** duplicates (rule 2). The returned order **is** the sorted order
/// — never first-seen / insertion order. A pure function of the input multiset,
/// so duplicate, reversed, and permuted inputs all collapse to the identical
/// output.
///
/// Mirrors the DuckDB oracle `SELECT DISTINCT … ORDER BY …`.
pub fn distinct(rows: &[Key]) -> Vec<Key> {
    let mut v = rows.to_vec();
    v.sort_unstable();
    v.dedup(); // removes *consecutive* equal elements ⇒ adjacent dedup after sort
    v
}

// ── Primitive 4: rank (dense integer renumbering) ───────────────────────────

/// Result of [`rank`].
///
/// - `order` — the distinct tuples in §5.5.1 total order.
/// - `id` — `id[t]` is the dense integer assigned to tuple `t` (insertion order
///   equals sorted order, since it is filled in `order` sequence).
/// - `base` — the emission base. Rust emits **0-based** (`CONFORMANCE_SPEC.md`
///   §5.5.1 rule 3, the canonical numbering); the conformance adapter recovers
///   the canonical 0-based ID via `canonical = reported − base`.
#[derive(Debug, Clone)]
pub struct Ranking {
    /// The distinct tuples in total order.
    pub order: Vec<Key>,
    /// Map from tuple to its dense integer ID.
    pub id: IndexMap<Key, i64>,
    /// The emission base (Rust native = 0).
    pub base: i64,
}

impl Ranking {
    /// The emitted dense IDs in `order` sequence: `[base, base+1, …]`.
    pub fn dense_ids(&self) -> Vec<i64> {
        (0..self.order.len() as i64)
            .map(|i| i + self.base)
            .collect()
    }

    /// The canonical 0-based dense IDs (`reported − base`): always `[0, 1, …]`.
    /// This is what the cross-binding conformance suite asserts on.
    pub fn canonical_dense_ids(&self) -> Vec<i64> {
        (0..self.order.len() as i64).collect()
    }
}

/// Dense integer renumbering (rule 3) at Rust's native **0-based** emission:
/// assign IDs by position in the sorted [`distinct`] sequence. Equivalent to SQL
/// `dense_rank() OVER (ORDER BY …)` over the deduplicated rows.
pub fn rank(rows: &[Key]) -> Ranking {
    rank_with_base(rows, 0)
}

/// [`rank`] with an explicit emission `base`. `base = 0` is the canonical
/// numbering the conformance suite asserts on; `base = 1` mirrors Julia's native
/// 1-based emission for the base-pin round-trip test.
pub fn rank_with_base(rows: &[Key], base: i64) -> Ranking {
    let order = distinct(rows);
    let mut id = IndexMap::with_capacity(order.len());
    for (i, t) in order.iter().enumerate() {
        id.insert(t.clone(), i as i64 + base);
    }
    Ranking { order, id, base }
}

// ── Primitive 5: group-by + semiring aggregate ──────────────────────────────

/// Group-by + semiring aggregate (rule 5). Bucket `rows` by their [`Key`]
/// (hashing only to bucket, via [`IndexMap`]), combine each group's [`Num`]
/// values with the semiring `op` (`⊕`), and emit `(key, aggregate)` pairs
/// **sorted by the canonical key**.
///
/// `op` is associative + commutative (every registry `⊕`), so the result is
/// independent of input / bucket order. The per-bucket reduction is a **left
/// fold over the values in canonical (sorted) order** so that a **floating-point**
/// `op` produces a reproducible last-ULP result (rule 5); the integer path uses
/// the same canonical order (immaterial there, but one code path).
///
/// Mirrors the DuckDB oracle `SELECT key, ⊕(value) … GROUP BY key ORDER BY key`.
pub fn group_aggregate(rows: &[(Key, Num)], op: SemiringOp) -> Vec<(Key, Num)> {
    let mut buckets: IndexMap<Key, Vec<Num>> = IndexMap::new();
    for (k, v) in rows {
        buckets.entry(k.clone()).or_default().push(*v);
    }
    let mut keys: Vec<Key> = buckets.keys().cloned().collect();
    keys.sort_unstable(); // canonical key order — never IndexMap bucket order
    let mut out = Vec::with_capacity(keys.len());
    for key in keys {
        let mut vals = buckets.swap_remove(&key).expect("key came from the map");
        vals.sort_by(Num::canonical_cmp); // canonical value order ⇒ reproducible float ⊕
        let agg = vals
            .into_iter()
            .reduce(|acc, x| op.apply(acc, x))
            .expect("each bucket has ≥ 1 value");
        out.push((key, agg));
    }
    out
}

// ── Canonical serialization (CONFORMANCE_SPEC.md §5.5.3) ─────────────────────

/// Canonical byte form of an index set (`CONFORMANCE_SPEC.md` §5.5.3): the
/// [`distinct`] rows, each tuple serialised as a JSON array, in §5.5.1 sorted
/// order, as **compact JSON** (`,` / `:` separators, no spaces, UTF-8, no
/// `\uXXXX` escaping). Two conforming bindings MUST produce byte-for-byte
/// identical output for the same input multiset.
///
/// This is the artifact the adversarial conformance harness (§5.5.4) compares
/// byte-for-byte across duplicate / reversed / permuted inputs.
pub fn canonical_index_set_json(rows: &[Key]) -> String {
    serialize_keys(&distinct(rows))
}

/// Serialise an already-distinct, already-sorted slice of keys to the canonical
/// compact-JSON index-set form (no further dedup/sort).
pub fn serialize_keys(rows: &[Key]) -> String {
    let mut out = String::new();
    write_array(&mut out, rows, |o, k| k.write_token(o));
    out
}

/// Serialise the `(key, aggregate)` output of [`group_aggregate`] to the
/// canonical compact-JSON form, each pair as a two-element array `[key, value]`.
pub fn serialize_pairs(rows: &[(Key, Num)]) -> String {
    let mut out = String::new();
    write_array(&mut out, rows, |o, (k, v)| {
        o.push('[');
        k.write_token(o);
        o.push(',');
        v.write_token(o);
        o.push(']');
    });
    out
}

/// Write `items` as a compact JSON array `[e0,e1,…]` using `emit` per element.
fn write_array<T>(out: &mut String, items: &[T], emit: impl Fn(&mut String, &T)) {
    out.push('[');
    for (i, item) in items.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        emit(out, item);
    }
    out.push(']');
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── concise constructors for tuples/keys in tests ───────────────────────
    fn ki(i: i64) -> Key {
        Key::Int(i)
    }
    fn ks(s: &str) -> Key {
        Key::Str(s.to_string())
    }
    fn t2(a: i64, b: i64) -> Key {
        Key::Tuple(vec![ki(a), ki(b)])
    }
    fn tup(items: Vec<Key>) -> Key {
        Key::Tuple(items)
    }
    /// Directed edges of each face (consecutive vertices, with wraparound),
    /// canonicalised to undirected `(min,max)` skolem keys — the mesh-edge
    /// enumeration producer (matches the harness `directed_edges_from_faces` +
    /// undirected `skolem`).
    fn undirected_edges(faces: &[Vec<i64>]) -> Vec<Key> {
        let mut edges = Vec::new();
        for face in faces {
            let n = face.len();
            for i in 0..n {
                edges.push(skolem_edge(ki(face[i]), ki(face[(i + 1) % n])));
            }
        }
        edges
    }

    // ── Primitive 1: distinct ───────────────────────────────────────────────
    #[test]
    fn distinct_sorts_and_dedups() {
        // Integers: output is SORTED, not first-seen order [3,1,2] (rule 2 /
        // the `first_seen_order` negative control).
        assert_eq!(
            distinct(&[ki(3), ki(1), ki(2), ki(1)]),
            vec![ki(1), ki(2), ki(3)]
        );
        // Tuples, lexicographic.
        assert_eq!(
            distinct(&[t2(2, 1), t2(1, 2), t2(2, 1)]),
            vec![t2(1, 2), t2(2, 1)]
        );
        // Strings: code-point order ("B" < "Z" < "a"), capitals before lowercase.
        assert_eq!(
            distinct(&[ks("a"), ks("Z"), ks("B"), ks("a")]),
            vec![ks("B"), ks("Z"), ks("a")]
        );
        // Empty input → empty.
        assert_eq!(distinct(&[]), Vec::<Key>::new());
    }

    // ── Primitive 3: skolem ─────────────────────────────────────────────────
    #[test]
    fn skolem_edge_canonicalises_undirected() {
        assert_eq!(skolem_edge(ki(2), ki(5)), t2(2, 5));
        assert_eq!(skolem_edge(ki(5), ki(2)), t2(2, 5)); // reversed → same
        assert_eq!(skolem_edge(ki(7), ki(7)), t2(7, 7)); // equal preserved
    }

    #[test]
    fn skolem_directed_preserves_symmetric_sorts() {
        // directed: order preserved, (1,2) ≠ (2,1)
        assert_eq!(skolem(vec![ki(1), ki(2)], false), t2(1, 2));
        assert_eq!(skolem(vec![ki(2), ki(1)], false), t2(2, 1));
        // symmetric: components sorted (generalises skolem_edge to arity > 2)
        assert_eq!(
            skolem(vec![ki(3), ki(1), ki(2)], true),
            tup(vec![ki(1), ki(2), ki(3)])
        );
    }

    // ── Primitive 4: rank ───────────────────────────────────────────────────
    #[test]
    fn rank_dense_ids_zero_based_and_base_pin_roundtrip() {
        let rows = [ki(30), ki(10), ki(20), ki(10)];
        let rk = rank(&rows); // Rust native base 0
        assert_eq!(rk.order, vec![ki(10), ki(20), ki(30)]);
        assert_eq!(rk.base, 0);
        assert_eq!(rk.id[&ki(10)], 0);
        assert_eq!(rk.id[&ki(20)], 1);
        assert_eq!(rk.id[&ki(30)], 2);
        assert_eq!(rk.dense_ids(), vec![0, 1, 2]);
        assert_eq!(rk.canonical_dense_ids(), vec![0, 1, 2]);

        // base-pin round-trip: Julia emits 1-based; `reported − base` recovers
        // the canonical 0-based numbering (CONFORMANCE_SPEC.md §5.5.1 rule 3).
        let rk1 = rank_with_base(&rows, 1);
        assert_eq!(rk1.id[&ki(10)], 1);
        assert_eq!(rk1.id[&ki(20)], 2);
        assert_eq!(rk1.id[&ki(30)], 3);
        for t in &rk.order {
            assert_eq!(rk.id[t] - rk.base, rk1.id[t] - rk1.base);
        }
        assert_eq!(rk1.canonical_dense_ids(), vec![0, 1, 2]);
    }

    // ── Primitive 5: group_aggregate ────────────────────────────────────────
    #[test]
    fn group_aggregate_semirings_and_permutation_invariance() {
        let rows = [
            (ks("b"), Num::Int(3)),
            (ks("a"), Num::Int(1)),
            (ks("b"), Num::Int(4)),
            (ks("a"), Num::Int(10)),
            (ks("c"), Num::Int(5)),
        ];
        let sum = group_aggregate(&rows, SemiringOp::Sum);
        assert_eq!(
            sum,
            vec![
                (ks("a"), Num::Int(11)),
                (ks("b"), Num::Int(7)),
                (ks("c"), Num::Int(5))
            ]
        );
        let max = group_aggregate(&rows, SemiringOp::Max);
        assert_eq!(
            max,
            vec![
                (ks("a"), Num::Int(10)),
                (ks("b"), Num::Int(4)),
                (ks("c"), Num::Int(5))
            ]
        );
        let min = group_aggregate(&rows, SemiringOp::Min);
        assert_eq!(
            min,
            vec![
                (ks("a"), Num::Int(1)),
                (ks("b"), Num::Int(3)),
                (ks("c"), Num::Int(5))
            ]
        );

        // Permuting the input rows cannot change any bucket result (assoc+comm).
        let rows_r: Vec<(Key, Num)> = rows.iter().rev().cloned().collect();
        assert_eq!(group_aggregate(&rows_r, SemiringOp::Sum), sum);

        // Product semiring.
        assert_eq!(
            group_aggregate(
                &[
                    (ki(1), Num::Int(2)),
                    (ki(1), Num::Int(3)),
                    (ki(1), Num::Int(4))
                ],
                SemiringOp::Prod
            ),
            vec![(ki(1), Num::Int(24))]
        );
    }

    #[test]
    fn group_aggregate_bool_keys_allowed() {
        // Bool is an allowed categorical key (boolean-or keys); false < true.
        let rows = [
            (Key::Bool(true), Num::Int(1)),
            (Key::Bool(false), Num::Int(2)),
            (Key::Bool(true), Num::Int(3)),
        ];
        assert_eq!(
            group_aggregate(&rows, SemiringOp::Sum),
            vec![
                (Key::Bool(false), Num::Int(2)),
                (Key::Bool(true), Num::Int(4))
            ]
        );
    }

    #[test]
    fn group_aggregate_float_values_reduced_in_canonical_order() {
        // Float *values* are allowed (only keys are float-forbidden). The
        // per-bucket reduction is a left fold over ascending-sorted values, so
        // the last-ULP result is reproducible: ((0.1 + 0.2) + 0.3).
        let rows = [
            (ki(1), Num::Float(0.3)),
            (ki(1), Num::Float(0.1)),
            (ki(1), Num::Float(0.2)),
        ];
        let got = group_aggregate(&rows, SemiringOp::Sum);
        let want = (0.1_f64 + 0.2_f64) + 0.3_f64;
        assert_eq!(got, vec![(ki(1), Num::Float(want))]);
        // And it serialises through the canonical float formatter.
        assert_eq!(
            serialize_pairs(&got),
            format!("[[1,{}]]", format_canonical_float(want))
        );
    }

    // ── Canonical serialization (§5.5.3) ────────────────────────────────────
    #[test]
    fn canonical_index_set_json_matches_reference() {
        assert_eq!(
            canonical_index_set_json(&[ki(3), ki(1), ki(2), ki(1)]),
            "[1,2,3]"
        );
        assert_eq!(
            canonical_index_set_json(&[t2(2, 1), t2(1, 2)]),
            "[[1,2],[2,1]]"
        );
        // code-point order + JSON-escaped quoted strings
        assert_eq!(
            canonical_index_set_json(&[ks("a"), ks("B")]),
            "[\"B\",\"a\"]"
        );
        assert_eq!(canonical_index_set_json(&[]), "[]");
    }

    // ── §5.5.4 golden + adversarial collapse ────────────────────────────────
    // Golden values are the cross-binding determinism manifest
    // (tests/conformance/determinism/manifest.json) = the DuckDB throwaway oracle
    // output (SELECT DISTINCT … ORDER BY …; dense_rank() OVER (ORDER BY …)),
    // 0-based dense IDs. Every adversarial variant MUST collapse to it.

    #[test]
    fn fixture_edge_enumeration_undirected() {
        let golden_set = vec![t2(1, 2), t2(1, 3), t2(2, 3), t2(2, 4), t2(3, 4)];
        let golden_json = "[[1,2],[1,3],[2,3],[2,4],[3,4]]";
        let golden_ids = vec![0, 1, 2, 3, 4];

        let canonical = vec![vec![1, 2, 3], vec![3, 2, 4]];
        let variants = [
            ("permuted_faces", vec![vec![3, 2, 4], vec![1, 2, 3]]),
            ("reversed_winding", vec![vec![3, 2, 1], vec![4, 2, 3]]),
            (
                "duplicate_face",
                vec![vec![1, 2, 3], vec![3, 2, 4], vec![1, 2, 3]],
            ),
        ];
        for faces in std::iter::once(&("canonical", canonical.clone()))
            .chain(variants.iter())
            .map(|(_, f)| f)
        {
            let edges = undirected_edges(faces);
            assert_eq!(distinct(&edges), golden_set);
            assert_eq!(canonical_index_set_json(&edges), golden_json);
            assert_eq!(rank(&edges).canonical_dense_ids(), golden_ids);
        }
    }

    #[test]
    fn fixture_directed_arcs() {
        let golden_set = vec![t2(1, 2), t2(2, 1), t2(2, 3)];
        let golden_json = "[[1,2],[2,1],[2,3]]";
        let golden_ids = vec![0, 1, 2];

        let canonical = vec![t2(1, 2), t2(2, 1), t2(2, 3), t2(1, 2)];
        let variants: Vec<Vec<Key>> = vec![
            vec![t2(2, 3), t2(1, 2), t2(2, 1), t2(1, 2)], // permuted_input
            vec![t2(1, 2), t2(2, 1), t2(2, 3), t2(1, 2), t2(2, 3)], // duplicate_arc
        ];
        for arcs in std::iter::once(&canonical).chain(variants.iter()) {
            // skolem directed preserves order; distinct sorts + dedups.
            let keyed: Vec<Key> = arcs.iter().map(|k| skolem(field_pair(k), false)).collect();
            assert_eq!(distinct(&keyed), golden_set);
            assert_eq!(canonical_index_set_json(&keyed), golden_json);
            assert_eq!(rank(&keyed).canonical_dense_ids(), golden_ids);
        }
    }

    /// Split a 2-tuple key back into its components (for re-skolemising arcs).
    fn field_pair(k: &Key) -> Vec<Key> {
        match k {
            Key::Tuple(v) => v.clone(),
            _ => panic!("expected a tuple arc"),
        }
    }

    #[test]
    fn fixture_group_by_sum_string_keys() {
        let golden = vec![
            (ks("B"), Num::Int(5)),
            (ks("Z"), Num::Int(1)),
            (ks("a"), Num::Int(9)),
        ];
        let golden_json = "[[\"B\",5],[\"Z\",1],[\"a\",9]]";
        let golden_ids = vec![0, 1, 2];

        let canonical = vec![
            (ks("B"), Num::Int(2)),
            (ks("a"), Num::Int(5)),
            (ks("B"), Num::Int(3)),
            (ks("Z"), Num::Int(1)),
            (ks("a"), Num::Int(4)),
        ];
        let permuted = vec![
            (ks("a"), Num::Int(4)),
            (ks("Z"), Num::Int(1)),
            (ks("B"), Num::Int(2)),
            (ks("a"), Num::Int(5)),
            (ks("B"), Num::Int(3)),
        ];
        for rows in [&canonical, &permuted] {
            let agg = group_aggregate(rows, SemiringOp::Sum);
            assert_eq!(agg, golden);
            assert_eq!(serialize_pairs(&agg), golden_json);
            // dense IDs rank the emitted (sorted) distinct keys.
            let keys: Vec<Key> = agg.iter().map(|(k, _)| k.clone()).collect();
            assert_eq!(rank(&keys).canonical_dense_ids(), golden_ids);
        }
    }

    // ── Negative controls (manifest negative_controls) ──────────────────────
    #[test]
    fn float_in_key_rejected_at_boundary() {
        // `float_in_key`: a float key component must raise, not silently bucket
        // on a platform-dependent float repr (rule 1).
        assert!(Key::try_from_json(&serde_json::json!(1.5)).is_err());
        assert!(Key::try_from_json(&serde_json::json!(1.0)).is_err()); // 1.0 is a float in JSON
        assert!(Key::try_from_json(&serde_json::json!([1, 2.5])).is_err());
        // Integers and strings are fine.
        assert_eq!(Key::try_from_json(&serde_json::json!(7)).unwrap(), ki(7));
        assert_eq!(
            Key::try_from_json(&serde_json::json!("B")).unwrap(),
            ks("B")
        );
        assert_eq!(
            Key::try_from_json(&serde_json::json!([1, 2])).unwrap(),
            t2(1, 2)
        );
        // Bool is an allowed categorical key.
        assert_eq!(
            Key::try_from_json(&serde_json::json!(true)).unwrap(),
            Key::Bool(true)
        );
    }
}
