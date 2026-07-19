//! Build-time value-equality (`join.on`) resolution for `aggregate` /
//! `arrayop` nodes — the M2 core of RFC `semiring-faq-unified-ir` §5.3, under
//! the cross-binding determinism contract of §5.7 / `CONFORMANCE_SPEC.md` §5.5.
//!
//! `join.on` adds combination of factors by **value equality of key columns**
//! (an inner equi-join), subsuming ESI `join` and making connectivity gathers
//! first-class instead of a positional einsum on a shared index. The relational
//! semantics are fixed, not implementation-defined (§5.3):
//!
//! - **Inner only.** A combined ⊗-product term exists only for index
//!   combinations whose key columns are equal on *every* listed pair. An
//!   unmatched row contributes nothing — the additive identity `0̄` (§5.1) — so
//!   it adds zero to a `sum_product` aggregate and leaves a `min_sum` at `+∞`.
//! - **Many-to-many is defined.** A key occurring `m` times left and `n` times
//!   right yields all `m·n` combined tuples, each one ⊗-term into the enclosing
//!   ⊕-reduction. This is categorical disaggregation (ESI), specified — not an
//!   error to guard against.
//! - **Exact-equality keys only.** Keys are integer IDs or categorical members
//!   (strings compared by Unicode code point). **Floats are forbidden in keys**
//!   ([`JoinKey::from_json`] rejects them), for the same reason floats are
//!   forbidden in Skolem keys: equality is not portable across bindings.
//! - **Null / missing keys.** A null/absent key column makes a row unmatchable
//!   (it joins to nothing → `0̄`); nulls never compare equal, not even to each
//!   other. Emitting `null` *into* a key column is a build-time error.
//!
//! **Determinism (§5.7 rule 5).** Hashing may bucket only; the emitted result
//! MUST be **sorted by the canonical key**, never hash-iteration / first-seen
//! order. Codes here are assigned by rank in the sorted union of a key pair's
//! distinct values ([`JoinKey`] total order), so the equality classes are
//! independent of input order, duplicates, and declared member order. The ⊕ used
//! to combine matched terms is associative + commutative for every registry
//! semiring, so input and parallel order cannot change a reduced value. (The
//! runtime value-equality equi-join / group-by kernel proper lives in
//! [`crate::relational`]; this module lowers a build-time `join.on` to a coded
//! `filter` gate.)
//!
//! **Build-time, same artifact.** Like [`crate::aggregate::resolve_aggregate_ranges`],
//! [`resolve_aggregate_joins`] runs once on an owned model — **before** range
//! resolution, while each range still carries its `{ "from": <index set> }`
//! linkage — and classifies every `[left, right]` key pair:
//!
//! - **Degenerate positional (no-op).** Both keys resolve to the *same* loop
//!   symbol — e.g. `["src", "sourceType"]`, where `sourceType` is the set `src`
//!   draws `{from}` (the common dense-categorical disaggregation, §7.2). The
//!   dense einsum already combines those factors positionally, so resolution is
//!   a structural no-op and evaluation stays byte-identical to the no-join form.
//! - **Data-derived value-equality.** The keys resolve to two *distinct* loop
//!   symbols — e.g. `["i", "j"]` over two categorical sets with duplicate
//!   members. The pair is lowered into a member-value-equality predicate ANDed
//!   into the node's `filter`: the contraction admits `(i, j)` iff the key
//!   columns carry equal members, so a key occurring `m`×`n` times contributes
//!   all `m·n` ⊗-terms (the defined many-to-many cardinality). Codes are assigned
//!   by rank in the sorted union of the pair's distinct values (dense value
//!   coding — same equality classes, independent of declared member order), so
//!   the evaluator reuses its existing `filter` gate with no new value-equality
//!   path on the hot loop.
//! - **Unsupported.** The `left` key resolves to no loop symbol (a join keyed on
//!   a genuine data column, not an iterated index); rejected with a clear error
//!   rather than silently mis-combined.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde_json::Value;

use crate::aggregate::is_aggregate_op;
use crate::compile_error::CompileError;
use crate::types::{Expr, ExpressionNode, IndexSet, Model, RangeSpec};

/// One component of a join / group-by key. Exact-equality types only (§5.3):
/// an integer ID or a categorical member. **Floats are forbidden in keys**
/// (§5.7 rule 1) — they never reach this enum; [`JoinKey::from_json`] rejects
/// them at the boundary.
///
/// The derived [`Ord`] **is** the normative total order (§5.5.1 rule 1):
/// integers compare by value, strings by Rust `str` order which for valid UTF-8
/// is Unicode code-point order (equivalently UTF-8 byte order), *not* locale
/// collation — so `"B"` (U+0042) < `"Z"` (U+005A) < `"a"` (U+0061), which a
/// case-insensitive locale would wrongly interleave. The variant order pins the
/// cross-type tiebreak (`Int` before `Cat`); in practice a given key column is
/// homogeneous, but a defined total order must still be total.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum JoinKey {
    /// An integer index / categorical-by-id key component.
    Int(i64),
    /// A categorical member, compared by Unicode code point (UTF-8 byte order).
    Cat(String),
}

/// Why a JSON value cannot be a join key (§5.3 / §5.7 rule 1).
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum KeyError {
    /// A floating-point component — forbidden: equality is not portable across
    /// bindings (a `5.0` repr is platform-dependent). Carries the offending value.
    #[error("floating-point member {0} cannot be a join key")]
    Float(f64),
    /// A `null` / missing component emitted *into* a key column — a build-time
    /// error (§5.3: not silently dropped).
    #[error("null member cannot be a join key")]
    Null,
    /// A non-scalar (array / object) component, which cannot be an equality key.
    #[error("non-scalar member cannot be a join key")]
    NonScalar,
}

impl JoinKey {
    /// Project a JSON scalar into a [`JoinKey`], enforcing the §5.7 rule-1 key
    /// type discipline. Integers and strings pass; a JSON `null` is a
    /// build-time error ([`KeyError::Null`]); a genuine float is rejected
    /// ([`KeyError::Float`]) rather than silently bucketed on a
    /// platform-dependent representation. A JSON bool maps to `Int(0/1)` — a
    /// categorical 0/1 id, matching the reference primitives (Python treats
    /// `bool` as an `int` subclass).
    ///
    /// Note a JSON `5.0` (any number carrying a fractional/exponent token) is a
    /// float and is rejected, while `5` is an integer and yields `Int(5)` — the
    /// same integer-vs-float distinction the canonical number tokenizer draws.
    pub fn from_json(v: &Value) -> Result<JoinKey, KeyError> {
        match v {
            Value::Null => Err(KeyError::Null),
            Value::Bool(b) => Ok(JoinKey::Int(i64::from(*b))),
            Value::Number(n) => match n.as_i64() {
                Some(i) => Ok(JoinKey::Int(i)),
                // Not representable as an i64 ⇒ it is a float token (or an
                // out-of-range integer); either way it is not a portable
                // exact-equality key.
                None => Err(KeyError::Float(n.as_f64().unwrap_or(f64::NAN))),
            },
            Value::String(s) => Ok(JoinKey::Cat(s.clone())),
            Value::Array(_) | Value::Object(_) => Err(KeyError::NonScalar),
        }
    }
}

/// Resolve every `join.on` clause in `model` (RFC §5.3), in place. Call once on
/// an owned model **before** [`crate::aggregate::resolve_aggregate_ranges`], so
/// each aggregate range still carries its `{ "from": <index set> }` linkage and
/// the join key columns' member values can be read. Since v0.8.0 the
/// `index_sets` registry is document-scoped (one registry shared by all
/// models), so it is threaded in explicitly rather than read off the `Model`.
///
/// Each `[left, right]` key pair is classified (see the module docs): a pair
/// resolving to one loop symbol is a positional no-op, a pair over two distinct
/// loop symbols is lowered into a member-value-equality `filter`, and a pair
/// whose `left` names no loop symbol is an unsupported data-column join.
pub fn resolve_aggregate_joins(
    model: &mut Model,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    for eq in &mut model.equations {
        lower_expr_joins(&mut eq.lhs, index_sets)?;
        lower_expr_joins(&mut eq.rhs, index_sets)?;
    }
    if let Some(init_eqs) = &mut model.initialization_equations {
        for eq in init_eqs {
            lower_expr_joins(&mut eq.lhs, index_sets)?;
            lower_expr_joins(&mut eq.rhs, index_sets)?;
        }
    }
    for var in model.variables.values_mut() {
        if let Some(expr) = &mut var.expression {
            lower_expr_joins(expr, index_sets)?;
        }
    }
    Ok(())
}

/// Recursively lower `join` clauses on a node and all its children.
fn lower_expr_joins(
    expr: &mut Expr,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    let Expr::Operator(node) = expr else {
        return Ok(());
    };

    if node.join.is_some() {
        lower_node_joins(node, index_sets)?;
    }

    // Recurse into every expression-bearing child via the canonical walker
    // (args, lower, upper, expr, filter, values, axes, key, bindings) so a
    // `join`-bearing aggregate nested in a grouping `key` or a template
    // `bindings` value is lowered too — not just the hand-picked subset this
    // used to enumerate (bug D: `key`/`bindings` were skipped, leaving a `join`
    // clause in the typed IR). `for_each_child_mut`'s closure cannot return, so
    // the first lowering error is captured and propagated afterwards.
    let mut err: Option<CompileError> = None;
    node.for_each_child_mut(&mut |child| {
        if err.is_none()
            && let Err(e) = lower_expr_joins(child, index_sets)
        {
            err = Some(e);
        }
    });
    match err {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// Classify and lower one aggregate node's join clauses (see the module docs):
/// each data-derived pair becomes a member-value-equality predicate ANDed into
/// the node `filter`, positional pairs are dropped as no-ops, and the resolved
/// `join` clauses are consumed.
fn lower_node_joins(
    node: &mut ExpressionNode,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<(), CompileError> {
    if !is_aggregate_op(&node.op) {
        return Err(CompileError::InterpreterBuildError {
            details: format!(
                "`join` is only valid on an aggregate/arrayop node, but appears on op '{}' \
                 (RFC semiring-faq-unified-ir §5.3)",
                node.op
            ),
        });
    }

    let joins = node.join.take().unwrap_or_default();
    let ranges = node.ranges.clone().unwrap_or_default();

    // The loop symbols in scope (an aggregate's output indices also appear as
    // range keys). A join key naming one of these is positional on that symbol.
    let declared: HashSet<&str> = ranges.keys().map(String::as_str).collect();
    // index-set name -> the loop symbol(s) drawing `{from}` it, so a clause may
    // name the dimension (`"sourceType"`) instead of the loop symbol (`"src"`).
    let mut set_to_syms: HashMap<&str, Vec<&str>> = HashMap::new();
    for (sym, spec) in &ranges {
        if let RangeSpec::IndexSetRef { from, .. } = spec {
            set_to_syms.entry(from.as_str()).or_default().push(sym);
        }
    }

    let mut conjuncts: Vec<Expr> = Vec::new();
    for clause in &joins {
        if clause.on.is_empty() {
            return Err(CompileError::InterpreterBuildError {
                details: "`join` clause has an empty `on` list; at least one [left, right] \
                          key-column pair is required (RFC semiring-faq-unified-ir §5.3)"
                    .to_string(),
            });
        }
        for pair in &clause.on {
            let left = pair[0].as_str();
            let right = pair[1].as_str();

            // The left key drives matching; it must name a loop symbol. A left
            // key that names neither a loop symbol nor an index set bound by one
            // is a join keyed on a genuine data column — the unsupported case.
            let sym_l = resolve_key(left, &declared, &set_to_syms).ok_or_else(|| {
                CompileError::UnsupportedFeatureError {
                    feature: "value-equality join over data-derived columns".to_string(),
                    message: format!(
                        "join key column '{left}' does not resolve to a loop index of this \
                         aggregate ({declared:?}); a value-equality join keyed on a genuine data \
                         column requires the relational gather the dense Rust evaluator does not \
                         drive (RFC semiring-faq-unified-ir §5.3)"
                    ),
                }
            })?;

            // A right key resolving to the same loop symbol — or to no loop
            // symbol — is the degenerate positional case: the factors already
            // combine on that shared symbol, so the join is a structural no-op.
            let Some(sym_r) = resolve_key(right, &declared, &set_to_syms) else {
                continue;
            };
            if sym_l == sym_r {
                continue;
            }

            // Data-derived value-equality: admit (sym_l, sym_r) iff their key
            // columns carry equal member values. Lower to a coded-table equality
            // predicate the evaluator gates on like any other `filter`.
            let (pos_l, vals_l) = key_column(&sym_l, &ranges, index_sets)?;
            let (pos_r, vals_r) = key_column(&sym_r, &ranges, index_sets)?;
            let (codes_l, codes_r) = encode_columns(&vals_l, &vals_r);
            conjuncts.push(Expr::Operator(ExpressionNode {
                op: "==".into(),
                args: vec![
                    code_lookup(&pos_l, &codes_l, &sym_l),
                    code_lookup(&pos_r, &codes_r, &sym_r),
                ],
                ..Default::default()
            }));
        }
    }

    if !conjuncts.is_empty() {
        // Each gate is 0/1, so a product is their conjunction; fold in any
        // pre-existing filter so a combination survives only if every gate and
        // the original predicate hold.
        if let Some(existing) = node.filter.take() {
            conjuncts.push(*existing);
        }
        let pred = if conjuncts.len() == 1 {
            conjuncts.pop().unwrap()
        } else {
            Expr::Operator(ExpressionNode {
                op: "*".into(),
                args: conjuncts,
                ..Default::default()
            })
        };
        node.filter = Some(Box::new(pred));
    }

    Ok(())
}

/// Resolve a join key to the loop symbol it denotes: the key itself if it is a
/// declared range symbol, else the unique range symbol drawing `{from}` an index
/// set of that name (RFC §5.3 — a clause may name the dimension instead of the
/// loop symbol). `None` if it resolves to no single loop symbol (a positional /
/// non-loop key, handled by the caller).
fn resolve_key(
    key: &str,
    declared: &HashSet<&str>,
    set_to_syms: &HashMap<&str, Vec<&str>>,
) -> Option<String> {
    if declared.contains(key) {
        return Some(key.to_string());
    }
    match set_to_syms.get(key) {
        Some(syms) if syms.len() == 1 => Some(syms[0].to_string()),
        _ => None,
    }
}

/// The 1-based positions and per-position key values of a loop symbol's key
/// column (RFC §5.3). A categorical range contributes its declared members
/// (validated as exact-equality keys); an interval range — or a bare dense
/// integer interval — contributes the integer index itself.
fn key_column(
    sym: &str,
    ranges: &HashMap<String, RangeSpec>,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<(Vec<i64>, Vec<JoinKey>), CompileError> {
    match ranges.get(sym) {
        Some(RangeSpec::IndexSetRef { from, of }) => {
            if of.as_ref().is_some_and(|p| !p.is_empty()) {
                return Err(CompileError::UnsupportedFeatureError {
                    feature: "value-equality join over a ragged key column".to_string(),
                    message: format!(
                        "join key '{sym}' references index set '{from}' with a dependent `of` \
                         (ragged) binding; equi-join keys must be dense interval / categorical \
                         columns (RFC semiring-faq-unified-ir §5.3)"
                    ),
                });
            }
            let set = index_sets.get(from.as_str()).ok_or_else(|| {
                CompileError::InterpreterBuildError {
                    details: format!(
                        "join key '{sym}' references index set '{from}', which is not declared \
                             in the document `index_sets` registry (RFC semiring-faq-unified-ir §5.3)"
                    ),
                }
            })?;
            match set.kind.as_str() {
                "categorical" => {
                    let members = set.members.as_ref().ok_or_else(|| {
                        CompileError::InterpreterBuildError {
                            details: format!(
                                "categorical index set '{from}' (join key '{sym}') has no `members`"
                            ),
                        }
                    })?;
                    let positions: Vec<i64> = (1..=members.len() as i64).collect();
                    let vals = members
                        .iter()
                        .map(|m| join_key_member(m, from))
                        .collect::<Result<Vec<_>, _>>()?;
                    Ok((positions, vals))
                }
                "interval" => {
                    let size = set
                        .size
                        .ok_or_else(|| CompileError::InterpreterBuildError {
                            details: format!(
                                "interval index set '{from}' (join key '{sym}') has no `size`"
                            ),
                        })?;
                    let positions: Vec<i64> = (1..=size).collect();
                    let vals = positions.iter().map(|p| JoinKey::Int(*p)).collect();
                    Ok((positions, vals))
                }
                other => Err(CompileError::UnsupportedFeatureError {
                    feature: "value-equality join over a non-enumerable key column".to_string(),
                    message: format!(
                        "join key '{sym}' references index set '{from}' of kind '{other}'; only \
                         interval (integer IDs) and categorical members can be equi-joined (RFC \
                         semiring-faq-unified-ir §5.3)"
                    ),
                }),
            }
        }
        Some(RangeSpec::Interval([lo, hi])) | Some(RangeSpec::Strided([lo, hi, _])) => {
            // A strided range's stride is irrelevant to the enumerable key set —
            // the dense `[lo, hi]` integer IDs are the join keys, same as a plain
            // interval.
            let positions: Vec<i64> = (*lo..=*hi).collect();
            let vals = positions.iter().map(|p| JoinKey::Int(*p)).collect();
            Ok((positions, vals))
        }
        // A resolved ragged column is per-parent dynamic, so its key values are
        // not a single enumerable set — the same restriction as the unresolved
        // `IndexSetRef`-with-`of` case above. Join resolution runs before range
        // resolution, so this is defensive: a join key is still an `IndexSetRef`
        // here in practice.
        Some(RangeSpec::RaggedDyn { .. }) => Err(CompileError::UnsupportedFeatureError {
            feature: "value-equality join over a ragged key column".to_string(),
            message: format!(
                "join key '{sym}' is a ragged (per-parent dynamic) column; equi-join keys must be \
                 dense interval / categorical columns (RFC semiring-faq-unified-ir §5.3)"
            ),
        }),
        // A resolved derived column's extent is materialized per-eval by its FAQ
        // producer, so its key values are not a single enumerable set — the same
        // restriction as the ragged case above. Defensive: join resolution runs
        // before range resolution, so a join key is still an `IndexSetRef` here.
        Some(RangeSpec::DerivedDyn { .. }) => Err(CompileError::UnsupportedFeatureError {
            feature: "value-equality join over a derived key column".to_string(),
            message: format!(
                "join key '{sym}' is a derived (FAQ-materialized, data-dependent) column; equi-join \
                 keys must be dense interval / categorical columns (RFC semiring-faq-unified-ir §5.3)"
            ),
        }),
        None => Err(CompileError::InterpreterBuildError {
            details: format!("join key '{sym}' has no declared range on this aggregate"),
        }),
    }
}

/// Validate one categorical member used as a join key and project it to a
/// [`JoinKey`] (RFC §5.3 / §5.7 rule 1): integer IDs and string members pass;
/// floats and nulls are build-time errors (equality is not portable).
fn join_key_member(m: &Value, set_name: &str) -> Result<JoinKey, CompileError> {
    JoinKey::from_json(m).map_err(|e| {
        let why = match e {
            KeyError::Float(f) => format!("floating-point member {f}"),
            KeyError::Null => "null member".to_string(),
            KeyError::NonScalar => "non-scalar member".to_string(),
        };
        CompileError::InterpreterBuildError {
            details: format!(
                "{why} in join key index set '{set_name}': join keys must be integer IDs or \
                 categorical members — floats / nulls are forbidden (equality is not portable \
                 across bindings; RFC semiring-faq-unified-ir §5.3 / §5.7 rule 1)"
            ),
        }
    })
}

/// Assign each key value an integer code by its rank in the sorted union of the
/// two columns' distinct values ([`JoinKey`] total order, §5.7 rule 1): equal
/// values get equal codes across both columns, so code equality is exactly
/// member-value equality. This is the dense-coding form of a bucket-and-probe
/// equi-join and yields the same equality classes, independent of the
/// declared member order (the permuted-fixture determinism property). Codes
/// start at 1 so 0 stays free for the unused fill of a code table (see
/// [`code_lookup`]).
fn encode_columns(vals_l: &[JoinKey], vals_r: &[JoinKey]) -> (Vec<i64>, Vec<i64>) {
    let mut union: BTreeSet<JoinKey> = BTreeSet::new();
    for v in vals_l.iter().chain(vals_r.iter()) {
        union.insert(v.clone());
    }
    let codes: BTreeMap<JoinKey, i64> = union
        .into_iter()
        .enumerate()
        .map(|(i, k)| (k, i as i64 + 1))
        .collect();
    let map = |vals: &[JoinKey]| -> Vec<i64> { vals.iter().map(|k| codes[k]).collect() };
    (map(vals_l), map(vals_r))
}

/// Build `index(makearray(<code table>), sym)` — a constant per-position code
/// table indexed by the loop symbol. The table spans `[1, max position]` so the
/// 1-based `index` lookup reads the code for the symbol's current value; the
/// contraction visits only the column's own positions, so any lower fill (code
/// 0, which no real value carries) is never read.
fn code_lookup(positions: &[i64], codes: &[i64], sym: &str) -> Expr {
    let hi = positions.iter().copied().max().unwrap_or(0);
    let code_at: HashMap<i64, i64> = positions
        .iter()
        .copied()
        .zip(codes.iter().copied())
        .collect();
    let mut regions: Vec<Vec<[i64; 2]>> = Vec::with_capacity(hi.max(0) as usize);
    let mut values: Vec<Expr> = Vec::with_capacity(hi.max(0) as usize);
    for p in 1..=hi {
        regions.push(vec![[p, p]]);
        values.push(Expr::Integer(code_at.get(&p).copied().unwrap_or(0)));
    }
    let table = Expr::Operator(ExpressionNode {
        op: "makearray".into(),
        regions: Some(regions),
        values: Some(values),
        ..Default::default()
    });
    Expr::Operator(ExpressionNode {
        op: "index".into(),
        args: vec![table, Expr::Variable(sym.to_string())],
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ExpressionNode, JoinClause, RangeSpec};
    use std::collections::HashMap;

    // --- JoinKey total order (§5.5.1 rule 1) -------------------------------

    #[test]
    fn int_keys_order_by_value() {
        assert!(JoinKey::Int(2) < JoinKey::Int(10));
        assert!(JoinKey::Int(-1) < JoinKey::Int(0));
        let mut v = vec![JoinKey::Int(10), JoinKey::Int(2), JoinKey::Int(-5)];
        v.sort();
        assert_eq!(v, vec![JoinKey::Int(-5), JoinKey::Int(2), JoinKey::Int(10)]);
    }

    #[test]
    fn string_keys_order_by_code_point_not_locale() {
        // The §5.5.1 worked example: code-point order is 'B'<'Z'<'a'. A
        // case-insensitive locale would interleave 'a' among the capitals —
        // which is forbidden.
        let mut v = vec![
            JoinKey::Cat("a".into()),
            JoinKey::Cat("Z".into()),
            JoinKey::Cat("B".into()),
        ];
        v.sort();
        assert_eq!(
            v,
            vec![
                JoinKey::Cat("B".into()),
                JoinKey::Cat("Z".into()),
                JoinKey::Cat("a".into()),
            ]
        );
    }

    #[test]
    fn cross_type_order_is_total_int_before_cat() {
        assert!(JoinKey::Int(999) < JoinKey::Cat("".into()));
        // And tuples compare lexicographically (Vec<JoinKey>: Ord).
        let a = vec![JoinKey::Int(1), JoinKey::Cat("x".into())];
        let b = vec![JoinKey::Int(1), JoinKey::Cat("y".into())];
        assert!(a < b);
    }

    // --- Key-type discipline / rejection (§5.7 rule 1) ---------------------

    #[test]
    fn from_json_accepts_int_and_string() {
        assert_eq!(
            JoinKey::from_json(&Value::from(5)).unwrap(),
            JoinKey::Int(5)
        );
        assert_eq!(
            JoinKey::from_json(&Value::from("onroad")).unwrap(),
            JoinKey::Cat("onroad".into())
        );
    }

    #[test]
    fn from_json_rejects_float_keys() {
        // A fractional float and an integral-valued float token both reject —
        // a float repr is not a portable exact-equality key.
        assert_eq!(
            JoinKey::from_json(&serde_json::json!(1.5)),
            Err(KeyError::Float(1.5))
        );
        assert_eq!(
            JoinKey::from_json(&serde_json::json!(5.0)),
            Err(KeyError::Float(5.0))
        );
    }

    #[test]
    fn from_json_rejects_null_in_key() {
        // Emitting null INTO a key column is a build-time error (§5.3).
        assert_eq!(JoinKey::from_json(&Value::Null), Err(KeyError::Null));
    }

    #[test]
    fn from_json_bool_is_categorical_int() {
        assert_eq!(
            JoinKey::from_json(&Value::from(true)).unwrap(),
            JoinKey::Int(1)
        );
        assert_eq!(
            JoinKey::from_json(&Value::from(false)).unwrap(),
            JoinKey::Int(0)
        );
    }

    // --- Key-column coding (the data-derived value-equality core) -----------

    #[test]
    fn encode_columns_equal_codes_for_equal_members() {
        // The m2m disaggregation columns: "coal" recurs (mult. 2) on each side.
        let l = vec![
            JoinKey::Cat("coal".into()),
            JoinKey::Cat("coal".into()),
            JoinKey::Cat("oil".into()),
        ];
        let r = vec![
            JoinKey::Cat("coal".into()),
            JoinKey::Cat("coal".into()),
            JoinKey::Cat("gas".into()),
        ];
        let (cl, cr) = encode_columns(&l, &r);
        // "coal" gets one code shared across both columns; oil/gas differ.
        assert_eq!(cl[0], cl[1], "both 'coal' on the left share a code");
        assert_eq!(cl[0], cr[0], "'coal' == 'coal' across columns");
        assert_eq!(cl[0], cr[1]);
        assert_ne!(cl[2], cr[2], "'oil' != 'gas'");
        assert_ne!(cl[0], cl[2], "'coal' != 'oil'");
        // The defined m·n cardinality: coal(2) × coal(2) = 4 admitted combos.
        let admitted = (0..3)
            .flat_map(|a| (0..3).map(move |b| (a, b)))
            .filter(|&(a, b)| cl[a] == cr[b])
            .count();
        assert_eq!(admitted, 4, "coal 2×2 matches; oil/gas unmatched");
    }

    #[test]
    fn encode_columns_is_independent_of_member_order() {
        // Permuting the declared member order leaves the equality classes (and so
        // the admitted-combination count) unchanged — the determinism property of
        // join_disaggregation_m2m_permuted.esm.
        let count = |l: &[JoinKey], r: &[JoinKey]| {
            let (cl, cr) = encode_columns(l, r);
            (0..l.len())
                .flat_map(|a| (0..r.len()).map(move |b| (a, b)))
                .filter(|&(a, b)| cl[a] == cr[b])
                .count()
        };
        let cat = |s: &str| JoinKey::Cat(s.into());
        let canonical = count(
            &[cat("coal"), cat("coal"), cat("oil")],
            &[cat("coal"), cat("coal"), cat("gas")],
        );
        let permuted = count(
            &[cat("oil"), cat("coal"), cat("coal")],
            &[cat("gas"), cat("coal"), cat("coal")],
        );
        assert_eq!(canonical, permuted, "value-equality is order-independent");
        assert_eq!(canonical, 4);
    }

    // --- Build-time resolution / lowering pass ------------------------------
    //
    // These exercise the per-node lowering directly (the public
    // `resolve_aggregate_joins(model)` walk is covered end-to-end by the
    // join_filter.esm integration test and the m2m conformance fixtures).

    fn categorical(members: &[&str]) -> IndexSet {
        IndexSet {
            kind: "categorical".into(),
            size: None,
            members: Some(members.iter().map(|m| Value::from(*m)).collect()),
            from_faq: None,
            of: None,
            offsets: None,
            values: None,
        }
    }

    fn agg_with_join(joins: Vec<JoinClause>, ranges: Vec<&str>) -> Expr {
        let mut range_map = HashMap::new();
        for r in ranges {
            range_map.insert(r.to_string(), RangeSpec::Interval([1, 2]));
        }
        Expr::Operator(ExpressionNode {
            op: "aggregate".into(),
            ranges: Some(range_map),
            output_idx: Some(vec![]),
            join: Some(joins),
            expr: Some(Box::new(Expr::Variable("x".into()))),
            args: vec![Expr::Variable("x".into())],
            ..Default::default()
        })
    }

    #[test]
    fn lowers_data_derived_join_to_member_equality_filter() {
        // `[["i","j"]]` over two distinct categorical sets is the data-derived
        // case: it must synthesize a member-equality `filter` and consume `join`.
        let mut range_map = HashMap::new();
        range_map.insert(
            "i".to_string(),
            RangeSpec::IndexSetRef {
                from: "sources".into(),
                of: None,
            },
        );
        range_map.insert(
            "j".to_string(),
            RangeSpec::IndexSetRef {
                from: "factors".into(),
                of: None,
            },
        );
        let mut expr = Expr::Operator(ExpressionNode {
            op: "aggregate".into(),
            ranges: Some(range_map),
            output_idx: Some(vec![]),
            join: Some(vec![JoinClause {
                on: vec![["i".into(), "j".into()]],
            }]),
            expr: Some(Box::new(Expr::Number(1.0))),
            ..Default::default()
        });
        let mut isets = HashMap::new();
        isets.insert("sources".to_string(), categorical(&["coal", "coal", "oil"]));
        isets.insert("factors".to_string(), categorical(&["coal", "coal", "gas"]));

        lower_expr_joins(&mut expr, &isets).unwrap();
        let Expr::Operator(node) = &expr else {
            panic!("expr is not an operator");
        };
        assert!(node.join.is_none(), "resolved join must be consumed");
        let filter = node
            .filter
            .as_ref()
            .expect("data-derived join adds a filter");
        let Expr::Operator(f) = filter.as_ref() else {
            panic!("filter is not an operator");
        };
        assert_eq!(f.op, "==", "a single key pair lowers to one equality gate");
    }

    #[test]
    fn accepts_degenerate_positional_join() {
        // key columns src/fuel resolve to their own loop symbols (the index-set
        // names name the same dimension) ⇒ positional no-op: no filter is
        // synthesized and the join is consumed.
        let join = vec![JoinClause {
            on: vec![
                ["src".into(), "sourceType".into()],
                ["fuel".into(), "fuelType".into()],
            ],
        }];
        let mut expr = agg_with_join(join, vec!["src", "fuel"]);
        lower_expr_joins(&mut expr, &HashMap::new()).unwrap();
        let Expr::Operator(node) = &expr else {
            panic!("expr is not an operator");
        };
        assert!(node.join.is_none(), "resolved join must be consumed");
        assert!(
            node.filter.is_none(),
            "a degenerate positional join adds no filter"
        );
    }

    #[test]
    fn rejects_non_positional_join_as_unsupported() {
        // Left key column 'srcCol' resolves to no loop index ⇒ a join keyed on a
        // genuine data column ⇒ clear UnsupportedFeatureError.
        let join = vec![JoinClause {
            on: vec![["srcCol".into(), "sourceType".into()]],
        }];
        let mut expr = agg_with_join(join, vec!["src", "fuel"]);
        let err = lower_expr_joins(&mut expr, &HashMap::new()).unwrap_err();
        match err {
            CompileError::UnsupportedFeatureError { feature, message } => {
                assert!(feature.contains("value-equality join"));
                assert!(message.contains("srcCol"));
            }
            other => panic!("expected UnsupportedFeatureError, got {other:?}"),
        }
    }

    #[test]
    fn rejects_empty_on_list() {
        let join = vec![JoinClause { on: vec![] }];
        let mut expr = agg_with_join(join, vec!["src"]);
        assert!(lower_expr_joins(&mut expr, &HashMap::new()).is_err());
    }

    #[test]
    fn rejects_join_on_non_aggregate_op() {
        // A `join` smuggled onto a non-aggregate op is a build error.
        let mut bogus = Expr::Operator(ExpressionNode {
            op: "+".into(),
            join: Some(vec![JoinClause {
                on: vec![["a".into(), "b".into()]],
            }]),
            args: vec![Expr::Variable("x".into())],
            ..Default::default()
        });
        assert!(lower_expr_joins(&mut bogus, &HashMap::new()).is_err());
    }

    #[test]
    fn noop_when_no_join_present() {
        // An aggregate node with no join clause resolves trivially, and the walk
        // recurses into nested children without spurious errors.
        let mut agg = Expr::Operator(ExpressionNode {
            op: "aggregate".into(),
            ranges: Some(HashMap::from([(
                "i".to_string(),
                RangeSpec::Interval([1, 3]),
            )])),
            output_idx: Some(vec![]),
            expr: Some(Box::new(Expr::Variable("x".into()))),
            args: vec![Expr::Variable("x".into())],
            ..Default::default()
        });
        lower_expr_joins(&mut agg, &HashMap::new()).unwrap();
        let Expr::Operator(node) = &agg else {
            panic!("expr is not an operator");
        };
        assert!(node.filter.is_none(), "no join ⇒ no synthesized filter");
    }
}
