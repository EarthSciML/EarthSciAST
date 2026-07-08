//! Semiring registry and index-set range resolution for `aggregate` /
//! `arrayop` nodes — the M1 core of RFC `semiring-faq-unified-ir`.
//!
//! This module is the strict-superset refactor of the existing reducer:
//!
//! - **§5.1 Semiring.** [`Semiring`] is the closed, exhaustive registry of the
//!   five named `(⊕, ⊗)` pairs with their **normative** identities `(0̄, 1̄)`.
//!   The `reduce` field names ⊕ only; ⊗ and both identities come from the
//!   registry table here, never from the file. [`effective_reduce_kind`] is the
//!   single entry point the evaluator uses to pick the ⊕ reducer for a node:
//!   the semiring wins when present, otherwise the legacy `reduce` string
//!   drives it exactly as before (the strict-superset promise).
//! - **§5.2 Index sets.** [`resolve_aggregate_ranges`] rewrites every
//!   `{ "from": <name> }` range reference against the model `index_sets`
//!   registry, **erroring on an undeclared name** (no implicit interval
//!   inference). `interval` and `categorical` sets resolve to dense static
//!   `[lo, hi]` intervals; a `ragged` set (a contracted/inner index only)
//!   resolves to a self-describing [`RangeSpec::RaggedDyn`] carrying its
//!   `offsets` backing-factor name, which the evaluator expands to the dynamic
//!   per-parent bound `[1, offsets[of…]]` per output tuple (the gather through
//!   the `values` factor is authored in the node body). `derived`
//!   (FAQ-materialized) sets are resolved by the build-time relational layer,
//!   not the per-timestep evaluator (mirroring the Julia reference), so they
//!   still produce a clear error here.
//! - **§5.6 Op tag.** [`is_aggregate_op`] accepts the canonical `"aggregate"`
//!   tag. (The legacy `"arrayop"` alias was removed in ESM v0.8.0.)

use std::collections::HashMap;

use crate::compile_error::CompileError;
use crate::types::{Expr, IndexSet, Model, RangeSpec};

/// The ⊕/⊗ operators the evaluator can fold with, each carrying its normative
/// identity (RFC §5.1). A single enum serves both the aggregation side (⊕) and
/// the product side (⊗) so the empty-reduction identity 0̄ and empty-product
/// identity 1̄ are pinned from one place.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReduceKind {
    Sum,
    Product,
    Max,
    Min,
    Or,
    And,
}

impl ReduceKind {
    /// The identity element — the value an empty fold returns. As a ⊕ this is
    /// 0̄ (empty reduction); as a ⊗ this is 1̄ (empty product).
    pub fn identity(self) -> f64 {
        match self {
            ReduceKind::Sum => 0.0,
            ReduceKind::Product => 1.0,
            ReduceKind::Max => f64::NEG_INFINITY,
            ReduceKind::Min => f64::INFINITY,
            ReduceKind::Or => 0.0,  // false
            ReduceKind::And => 1.0, // true
        }
    }

    /// Fold one term into the accumulator. The Boolean ops treat any non-zero
    /// value as true and return a crisp `0.0`/`1.0`.
    pub fn combine(self, acc: f64, term: f64) -> f64 {
        match self {
            ReduceKind::Sum => acc + term,
            ReduceKind::Product => acc * term,
            ReduceKind::Max => f64::max(acc, term),
            ReduceKind::Min => f64::min(acc, term),
            ReduceKind::Or => {
                if acc != 0.0 || term != 0.0 {
                    1.0
                } else {
                    0.0
                }
            }
            ReduceKind::And => {
                if acc != 0.0 && term != 0.0 {
                    1.0
                } else {
                    0.0
                }
            }
        }
    }
}

/// The closed, exhaustive semiring registry (RFC §5.1). A semiring is fully
/// specified by its two operators **and** their identities; adding one is a
/// spec change, not a per-file extension.
///
/// | `semiring` | ⊕ (`reduce`) | 0̄ | ⊗ | 1̄ |
/// |---|---|---|---|---|
/// | `sum_product` *(default)* | `+` | `0` | `×` | `1` |
/// | `max_product` | `max` | `-∞` | `×` | `1` |
/// | `min_sum` | `min` | `+∞` | `+` | `0` |
/// | `max_sum` | `max` | `-∞` | `+` | `0` |
/// | `bool_and_or` | `∨` | `false` | `∧` | `true` |
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Semiring {
    SumProduct,
    MaxProduct,
    MinSum,
    MaxSum,
    BoolAndOr,
}

impl Semiring {
    /// Parse a registry name; `None` for an unregistered name (the schema's
    /// closed enum normally rejects these before the evaluator is reached).
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "sum_product" => Semiring::SumProduct,
            "max_product" => Semiring::MaxProduct,
            "min_sum" => Semiring::MinSum,
            "max_sum" => Semiring::MaxSum,
            "bool_and_or" => Semiring::BoolAndOr,
            _ => return None,
        })
    }

    /// ⊕ — the aggregation operator named by `reduce`.
    pub fn oplus(self) -> ReduceKind {
        match self {
            Semiring::SumProduct => ReduceKind::Sum,
            Semiring::MaxProduct => ReduceKind::Max,
            Semiring::MinSum => ReduceKind::Min,
            Semiring::MaxSum => ReduceKind::Max,
            Semiring::BoolAndOr => ReduceKind::Or,
        }
    }

    /// ⊗ — the product operator. Applied in the node body for M1; defined here
    /// so the normative empty-product identity 1̄ (`otimes().identity()`) is
    /// pinned per §5.1 and asserted by conformance.
    pub fn otimes(self) -> ReduceKind {
        match self {
            Semiring::SumProduct => ReduceKind::Product,
            Semiring::MaxProduct => ReduceKind::Product,
            Semiring::MinSum => ReduceKind::Sum,
            Semiring::MaxSum => ReduceKind::Sum,
            Semiring::BoolAndOr => ReduceKind::And,
        }
    }
}

/// Resolve the effective ⊕ reducer for an `aggregate`/`arrayop` node.
///
/// Per RFC §5.1, when `semiring` is present it is authoritative: ⊕ and its
/// identity come from the registry, never the file. When absent, the legacy
/// `reduce` string names ⊕ directly (today's behavior — the strict-superset
/// promise). Total and infallible: an absent/unrecognized `reduce` falls back
/// to `Sum`, exactly matching the evaluator's pre-existing default.
pub fn effective_reduce_kind(semiring: Option<&str>, reduce: Option<&str>) -> ReduceKind {
    // A recognized semiring is authoritative for ⊕. An unrecognized name (the
    // schema's closed enum should have rejected it) falls through to the legacy
    // `reduce` string rather than mis-aggregating.
    if let Some(sr) = semiring.and_then(Semiring::from_name) {
        return sr.oplus();
    }
    match reduce {
        Some("*") => ReduceKind::Product,
        Some("max") => ReduceKind::Max,
        Some("min") => ReduceKind::Min,
        // "+", None, or anything else → today's default reducer.
        _ => ReduceKind::Sum,
    }
}

/// Whether `op` is the aggregate node tag. `"aggregate"` is the canonical tag
/// (RFC §5.6). The legacy `"arrayop"` alias was removed in ESM v0.8.0.
pub fn is_aggregate_op(op: &str) -> bool {
    op == "aggregate"
}

/// Rewrite every `{ "from": <name> }` range reference in `model` against the
/// document-scoped `index_sets` registry (RFC §5.2). Since v0.8.0 the registry
/// lives on the top-level document (one registry shared by all models), so it
/// is threaded in explicitly rather than read off the `Model`. Operates in
/// place; call once on an owned model before shape inference and rule building
/// so every downstream consumer sees only resolved [`RangeSpec::Interval`] /
/// [`RangeSpec::RaggedDyn`] forms (never an `IndexSetRef`).
///
/// Interval/categorical sets resolve to static intervals; a `ragged` contracted
/// index resolves to a [`RangeSpec::RaggedDyn`] dynamic bound. Errors on an
/// undeclared `from` name (no implicit interval inference), a `ragged` set used
/// as an output index or referenced without an `of` parent, and a `derived`
/// set (resolved by the build-time relational layer, not the evaluator).
///
/// An empty registry is fine: any `{from}` reference then errors as undeclared
/// (correct), and pure-interval files resolve as no-ops.
pub fn resolve_aggregate_ranges(
    model: &mut Model,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    for eq in &mut model.equations {
        resolve_expr_ranges(&mut eq.lhs, index_sets)?;
        resolve_expr_ranges(&mut eq.rhs, index_sets)?;
    }
    if let Some(init_eqs) = &mut model.initialization_equations {
        for eq in init_eqs {
            resolve_expr_ranges(&mut eq.lhs, index_sets)?;
            resolve_expr_ranges(&mut eq.rhs, index_sets)?;
        }
    }
    for var in model.variables.values_mut() {
        if let Some(expr) = &mut var.expression {
            resolve_expr_ranges(expr, index_sets)?;
        }
    }
    Ok(())
}

/// Recursively resolve `{from}` range references on a node and all its children.
/// `pub(crate)` so standalone build-time expressions — §6.6.5 analytic
/// `reference`s and coordinate-expression `ic` RHSs, which live outside the
/// model equations [`resolve_aggregate_ranges`] walks — can be resolved
/// against the document registry before evaluation
/// (`crate::simulate_array::eval_buildtime_field`).
pub(crate) fn resolve_expr_ranges(
    expr: &mut Expr,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    let Expr::Operator(node) = expr else {
        return Ok(());
    };

    // Resolve this node's own ranges in place. A ragged inner range carries no
    // static upper bound; it resolves to a self-describing `RaggedDyn` that the
    // evaluator expands per output tuple. Output indices may not be ragged
    // (their extent must be statically known to size the result array), so the
    // output/contracted distinction is passed down to reject that with a clear
    // error. Clone the output names up front to avoid aliasing `node.ranges`.
    let output_names: std::collections::HashSet<String> = node
        .output_idx
        .clone()
        .unwrap_or_default()
        .into_iter()
        .collect();
    if let Some(ranges) = &mut node.ranges {
        for (idx_name, spec) in ranges.iter_mut() {
            let is_output = output_names.contains(idx_name);
            let resolved = match spec {
                // Already-concrete and already-resolved forms are idempotent.
                RangeSpec::Interval(_)
                | RangeSpec::RaggedDyn { .. }
                | RangeSpec::DerivedDyn { .. } => continue,
                RangeSpec::IndexSetRef { from, of } => {
                    resolve_index_set_ref(from, of.as_deref(), idx_name, is_output, index_sets)?
                }
            };
            *spec = match resolved {
                ResolvedRange::Static(iv) => RangeSpec::Interval(iv),
                ResolvedRange::Ragged { offsets, of } => RangeSpec::RaggedDyn { offsets, of },
                ResolvedRange::Derived { from_faq } => RangeSpec::DerivedDyn { from_faq },
            };
        }
    }

    // Recurse into every expression-bearing child.
    for a in &mut node.args {
        resolve_expr_ranges(a, index_sets)?;
    }
    if let Some(b) = &mut node.expr {
        resolve_expr_ranges(b, index_sets)?;
    }
    if let Some(l) = &mut node.lower {
        resolve_expr_ranges(l, index_sets)?;
    }
    if let Some(u) = &mut node.upper {
        resolve_expr_ranges(u, index_sets)?;
    }
    if let Some(vals) = &mut node.values {
        for v in vals.iter_mut() {
            resolve_expr_ranges(v, index_sets)?;
        }
    }
    if let Some(axes) = &mut node.axes {
        for v in axes.values_mut() {
            resolve_expr_ranges(v, index_sets)?;
        }
    }
    Ok(())
}

/// The outcome of resolving one `{ from, of }` reference: either a static dense
/// interval (interval/categorical sets) or a dynamic ragged bound that the
/// evaluator expands per output tuple from the `offsets` backing factor.
#[derive(Debug)]
enum ResolvedRange {
    Static([i64; 2]),
    Ragged {
        offsets: String,
        of: Vec<String>,
    },
    /// A FAQ-materialized derived range (RFC §5.5 / §8.1): its extent is the
    /// vertex count of the ring the `from_faq` producer node materializes at
    /// eval time, so it carries only the producer id (resolved dynamically).
    Derived {
        from_faq: String,
    },
}

/// Resolve one `{ from, of }` reference.
///
/// Interval and categorical sets resolve to a 1-based dense interval
/// ([`ResolvedRange::Static`] `[1, size]` / `[1, |members|]`), matching the
/// existing file-level range convention; any `of` on the reference is ignored
/// for these (their extent is static), mirroring the Julia reference.
///
/// A `ragged` set resolves to a [`ResolvedRange::Ragged`] dynamic bound — but
/// only as a contracted (inner) index: a ragged *output* index is rejected
/// (`is_output`), since the result array's extent must be statically known. The
/// dynamic upper bound `offsets[of…]` needs the parent index variable(s) from
/// the *reference's* `of` (rejected if empty) and the `offsets` backing factor
/// from the set definition; the member gather through `values` is authored in
/// the node body, so it is not consulted here.
///
/// A `derived` (FAQ-materialized) set resolves to a [`ResolvedRange::Derived`]
/// dynamic bound carrying its `from_faq` producer id — but, like a ragged set,
/// only as a contracted (inner) index: a derived *output* index is rejected
/// (`is_output`), since the result array's extent must be statically known. The
/// per-eval upper bound is the vertex count of the ring the `from_faq` node
/// materializes at runtime (RFC §8.1).
fn resolve_index_set_ref(
    from: &str,
    of: Option<&[String]>,
    idx_name: &str,
    is_output: bool,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<ResolvedRange, CompileError> {
    let set = index_sets
        .get(from)
        .ok_or_else(|| CompileError::InterpreterBuildError {
            details: format!(
                "aggregate range '{idx_name}' references index set '{from}', which is not declared \
                 in the document `index_sets` registry (no implicit interval inference; RFC \
                 semiring-faq-unified-ir §5.2)"
            ),
        })?;

    match set.kind.as_str() {
        "interval" => {
            let size = set
                .size
                .ok_or_else(|| CompileError::InterpreterBuildError {
                    details: format!("index set '{from}' has kind \"interval\" but no `size`"),
                })?;
            Ok(ResolvedRange::Static([1, size]))
        }
        "categorical" => {
            let n = set
                .members
                .as_ref()
                .map(|m| m.len() as i64)
                .ok_or_else(|| CompileError::InterpreterBuildError {
                    details: format!(
                        "index set '{from}' has kind \"categorical\" but no `members`"
                    ),
                })?;
            Ok(ResolvedRange::Static([1, n]))
        }
        "ragged" => {
            // A ragged set's per-tuple length is a function of its parent
            // index, so it can size a reduction but not the output array.
            if is_output {
                return Err(CompileError::UnsupportedFeatureError {
                    feature: "ragged output index".to_string(),
                    message: format!(
                        "aggregate output index '{idx_name}' references ragged index set '{from}'; \
                         a ragged set's extent is per-parent dynamic and may only be a contracted \
                         (reduction) index, not an output index (RFC semiring-faq-unified-ir §5.2)"
                    ),
                });
            }
            let parents = of.unwrap_or_default();
            if parents.is_empty() {
                return Err(CompileError::InterpreterBuildError {
                    details: format!(
                        "ragged index set '{from}' (aggregate range '{idx_name}') is referenced \
                         without an `of` parent index; a ragged set's length is a function of its \
                         parent (RFC semiring-faq-unified-ir §5.2)"
                    ),
                });
            }
            let offsets =
                set.offsets
                    .clone()
                    .ok_or_else(|| CompileError::InterpreterBuildError {
                        details: format!(
                            "ragged index set '{from}' (aggregate range '{idx_name}') requires an \
                             `offsets` backing factor giving |set(parent)| per parent tuple"
                        ),
                    })?;
            Ok(ResolvedRange::Ragged {
                offsets,
                of: parents.to_vec(),
            })
        }
        "derived" => {
            // A FAQ-materialized derived set (RFC §5.5 / §8.1) sizes itself from
            // the ring its producer node materializes at runtime (the
            // `intersect_polygon` clip-ring case): `from_faq` names that producer's
            // `id`, and the derived set's extent is the count of distinct vertices
            // of the registered ring, read per-eval. Like a ragged set it has no
            // statically-known extent, so it may size a reduction (contracted
            // index) but not an output array (`is_output`).
            if is_output {
                return Err(CompileError::UnsupportedFeatureError {
                    feature: "derived output index".to_string(),
                    message: format!(
                        "aggregate output index '{idx_name}' references derived index set '{from}'; \
                         a derived (FAQ-materialized) set's extent is data-dependent and may only \
                         be a contracted (reduction) index, not an output index (RFC \
                         semiring-faq-unified-ir §5.5 / §8.1)"
                    ),
                });
            }
            let from_faq =
                set.from_faq
                    .clone()
                    .ok_or_else(|| CompileError::InterpreterBuildError {
                        details: format!(
                            "derived index set '{from}' (aggregate range '{idx_name}') is missing \
                             `from_faq` naming its producing FAQ node (RFC semiring-faq-unified-ir §5.5)"
                        ),
                    })?;
            Ok(ResolvedRange::Derived { from_faq })
        }
        other => Err(CompileError::InterpreterBuildError {
            details: format!("index set '{from}' has unknown kind '{other}'"),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn interval(size: i64) -> IndexSet {
        IndexSet {
            kind: "interval".into(),
            size: Some(size),
            members: None,
            from_faq: None,
            of: None,
            offsets: None,
            values: None,
        }
    }

    fn ragged(offsets: Option<&str>) -> IndexSet {
        IndexSet {
            kind: "ragged".into(),
            size: None,
            members: None,
            from_faq: None,
            of: Some(vec!["cells".into()]),
            offsets: offsets.map(str::to_string),
            values: Some("edgesOnCell".into()),
        }
    }

    /// Unwrap a [`ResolvedRange::Static`] in tests, panicking otherwise.
    fn static_bounds(r: ResolvedRange) -> [i64; 2] {
        match r {
            ResolvedRange::Static(iv) => iv,
            ResolvedRange::Ragged { .. } => panic!("expected a static range, got ragged"),
            ResolvedRange::Derived { .. } => panic!("expected a static range, got derived"),
        }
    }

    #[test]
    fn semiring_identities_match_rfc_table() {
        // (semiring, 0̄ = ⊕ identity, 1̄ = ⊗ identity) per RFC §5.1.
        let cases = [
            (Semiring::SumProduct, 0.0, 1.0),
            (Semiring::MaxProduct, f64::NEG_INFINITY, 1.0),
            (Semiring::MinSum, f64::INFINITY, 0.0),
            (Semiring::MaxSum, f64::NEG_INFINITY, 0.0),
            (Semiring::BoolAndOr, 0.0, 1.0), // false, true
        ];
        for (sr, zero_bar, one_bar) in cases {
            assert_eq!(sr.oplus().identity(), zero_bar, "{sr:?} 0̄");
            assert_eq!(sr.otimes().identity(), one_bar, "{sr:?} 1̄");
        }
    }

    #[test]
    fn semiring_is_authoritative_over_reduce() {
        // Semiring present → its ⊕ wins regardless of (or absent) `reduce`.
        assert_eq!(
            effective_reduce_kind(Some("min_sum"), None),
            ReduceKind::Min
        );
        assert_eq!(
            effective_reduce_kind(Some("max_sum"), Some("+")),
            ReduceKind::Max
        );
        assert_eq!(
            effective_reduce_kind(Some("max_product"), None),
            ReduceKind::Max
        );
        assert_eq!(
            effective_reduce_kind(Some("bool_and_or"), None),
            ReduceKind::Or
        );
        // No semiring → legacy reduce string, default "+".
        assert_eq!(effective_reduce_kind(None, None), ReduceKind::Sum);
        assert_eq!(effective_reduce_kind(None, Some("+")), ReduceKind::Sum);
        assert_eq!(effective_reduce_kind(None, Some("*")), ReduceKind::Product);
        assert_eq!(effective_reduce_kind(None, Some("max")), ReduceKind::Max);
        assert_eq!(effective_reduce_kind(None, Some("min")), ReduceKind::Min);
        // Unknown semiring falls back to the legacy reduce rather than panicking.
        assert_eq!(
            effective_reduce_kind(Some("bogus"), Some("min")),
            ReduceKind::Min
        );
    }

    #[test]
    fn or_and_reductions_are_crisp_boolean() {
        assert_eq!(ReduceKind::Or.combine(0.0, 0.0), 0.0);
        assert_eq!(ReduceKind::Or.combine(0.0, 3.0), 1.0);
        assert_eq!(ReduceKind::Or.combine(2.0, 0.0), 1.0);
        assert_eq!(ReduceKind::And.combine(1.0, 1.0), 1.0);
        assert_eq!(ReduceKind::And.combine(1.0, 0.0), 0.0);
        assert_eq!(ReduceKind::And.combine(0.0, 0.0), 0.0);
    }

    #[test]
    fn aggregate_op_alias() {
        assert!(is_aggregate_op("aggregate"));
        assert!(!is_aggregate_op("arrayop"));
        assert!(!is_aggregate_op("makearray"));
        assert!(!is_aggregate_op("+"));
    }

    #[test]
    fn resolve_interval_and_categorical_from() {
        let mut index_sets = HashMap::new();
        index_sets.insert("cells".to_string(), interval(5));
        index_sets.insert(
            "county".to_string(),
            IndexSet {
                kind: "categorical".into(),
                size: None,
                members: Some(vec![
                    serde_json::json!("Champaign"),
                    serde_json::json!("Cook"),
                    serde_json::json!("Sangamon"),
                ]),
                from_faq: None,
                of: None,
                offsets: None,
                values: None,
            },
        );
        assert_eq!(
            static_bounds(resolve_index_set_ref("cells", None, "i", false, &index_sets).unwrap()),
            [1, 5]
        );
        assert_eq!(
            static_bounds(resolve_index_set_ref("county", None, "c", false, &index_sets).unwrap()),
            [1, 3]
        );
        // An `of` on a reference to a *static* set is ignored (its extent is
        // static), mirroring the Julia reference — it no longer errors.
        assert_eq!(
            static_bounds(
                resolve_index_set_ref("cells", Some(&["i".into()]), "i", false, &index_sets)
                    .unwrap()
            ),
            [1, 5]
        );
    }

    #[test]
    fn undeclared_from_errors_naming_the_set() {
        let index_sets: HashMap<String, IndexSet> = HashMap::new();
        let err = resolve_index_set_ref("nonesuch", None, "i", false, &index_sets).unwrap_err();
        let msg = format!("{err:?}");
        assert!(msg.contains("nonesuch"), "error should name the set: {msg}");
    }

    #[test]
    fn ragged_contracted_index_resolves_to_dynamic_bound() {
        // A ragged set used as a *contracted* index (is_output=false) resolves
        // to a RaggedDyn carrying the `offsets` factor and the reference's `of`
        // parents — the per-output-tuple bound `[1, offsets[of…]]`.
        let mut index_sets = HashMap::new();
        index_sets.insert("edges".to_string(), ragged(Some("nEdgesOnCell")));
        let resolved =
            resolve_index_set_ref("edges", Some(&["i".into()]), "k", false, &index_sets).unwrap();
        match resolved {
            ResolvedRange::Ragged { offsets, of } => {
                assert_eq!(offsets, "nEdgesOnCell");
                assert_eq!(of, vec!["i".to_string()]);
            }
            ResolvedRange::Static(iv) => panic!("expected ragged, got static {iv:?}"),
            ResolvedRange::Derived { from_faq } => {
                panic!("expected ragged, got derived {from_faq}")
            }
        }
    }

    #[test]
    fn ragged_as_output_index_is_rejected() {
        // A ragged set may not be an output index: the result array's extent
        // must be statically known.
        let mut index_sets = HashMap::new();
        index_sets.insert("edges".to_string(), ragged(Some("nEdgesOnCell")));
        let err = resolve_index_set_ref("edges", Some(&["i".into()]), "k", true, &index_sets)
            .unwrap_err();
        let msg = format!("{err:?}");
        assert!(msg.contains("ragged"), "error should mention ragged: {msg}");
    }

    #[test]
    fn ragged_without_of_parent_is_rejected() {
        // A ragged set's length is a function of its parent, so a reference
        // without an `of` parent index is rejected.
        let mut index_sets = HashMap::new();
        index_sets.insert("edges".to_string(), ragged(Some("nEdgesOnCell")));
        assert!(resolve_index_set_ref("edges", None, "k", false, &index_sets).is_err());
        assert!(resolve_index_set_ref("edges", Some(&[]), "k", false, &index_sets).is_err());
    }

    #[test]
    fn ragged_missing_offsets_factor_is_rejected() {
        // A ragged set with no `offsets` backing factor cannot produce a bound.
        let mut index_sets = HashMap::new();
        index_sets.insert("edges".to_string(), ragged(None));
        assert!(
            resolve_index_set_ref("edges", Some(&["i".into()]), "k", false, &index_sets).is_err()
        );
    }

    #[test]
    fn derived_index_set_resolves_as_contracted_but_rejects_as_output() {
        // A `derived` (FAQ-materialized) set sizes a reduction from the ring its
        // `from_faq` producer materializes at runtime (RFC §8.1): as a contracted
        // index it resolves to a deferred `Derived` bound; as an output index it
        // is rejected (its extent is not statically known to size the result).
        let mut index_sets = HashMap::new();
        index_sets.insert(
            "clip_ring".to_string(),
            IndexSet {
                kind: "derived".into(),
                size: None,
                members: None,
                from_faq: Some("overlap_clip".into()),
                of: None,
                offsets: None,
                values: None,
            },
        );
        // Contracted (is_output=false): resolves, carrying the producer id.
        match resolve_index_set_ref("clip_ring", None, "v", false, &index_sets).unwrap() {
            ResolvedRange::Derived { from_faq } => assert_eq!(from_faq, "overlap_clip"),
            other => panic!("expected Derived, got {other:?}"),
        }
        // Output (is_output=true): rejected.
        let err = resolve_index_set_ref("clip_ring", None, "v", true, &index_sets).unwrap_err();
        let msg = format!("{err:?}");
        assert!(
            msg.contains("derived output index"),
            "error should reject a derived output index: {msg}"
        );
    }

    #[test]
    fn derived_index_set_without_from_faq_is_rejected() {
        // A `derived` set must name its producer node via `from_faq`.
        let mut index_sets = HashMap::new();
        index_sets.insert(
            "bad_set".to_string(),
            IndexSet {
                kind: "derived".into(),
                size: None,
                members: None,
                from_faq: None,
                of: None,
                offsets: None,
                values: None,
            },
        );
        let err = resolve_index_set_ref("bad_set", None, "e", false, &index_sets).unwrap_err();
        let msg = format!("{err:?}");
        assert!(
            msg.contains("from_faq"),
            "error should mention the missing from_faq: {msg}"
        );
    }
}
