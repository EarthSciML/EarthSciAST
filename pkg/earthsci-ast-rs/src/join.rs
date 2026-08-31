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
//!   symbols — `["i", "j"]` over two categorical sets with duplicate members, or
//!   a pair of genuine **data columns** (`["srcTypeID", "tgtTypeID"]`, each a
//!   declared 1-D variable whose shape index set names one of the node's
//!   ranges — the MOVES/NONROAD shape, and the normal case). Resolution is
//!   TWO-SIDED:
//!   * a member-value-equality predicate is ANDed into the node's `filter`, so
//!     every evaluation path — the vectorized overlay, the tape, the per-cell
//!     oracle — stays correct with no new value-equality path of its own. For a
//!     loop-symbol pair the two sides are dense-coded by rank in the sorted union
//!     of their distinct values (same equality classes, independent of declared
//!     member order); for a data column the predicate reads the column directly
//!     (`index(col, sym)`).
//!   * an [`OnGate`] — the resolved key columns and the two loop symbols — is
//!     ATTACHED to the surviving `join` clause so the evaluator can build the
//!     match set once and let it **DRIVE enumeration**, exactly as a
//!     `join.overlap` gate does (CONFORMANCE_SPEC.md §5.5.8). Without it the
//!     contraction is an `O(N·M)` nested loop that merely *tests* equality; with
//!     it the cost is `O(|matches|·∏ungated)`. The filter is then a redundant
//!     re-check on the driven leaves — the same relationship §5.5.6 gives the
//!     overlap gate's narrow phase — which is what makes the driver a pure
//!     optimisation, verifiable by differential testing against the undriven
//!     path.
//! - **Unresolvable.** The `left` key names neither a loop symbol of this node,
//!   nor an index set one of its ranges draws from, nor a declared 1-D variable
//!   over such an index set; rejected with a clear error rather than silently
//!   mis-combined.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;

use crate::aggregate::is_aggregate_op;
use crate::compile_error::CompileError;
use crate::types::{Expr, ExpressionNode, IndexSet, JoinClause, Model, RangeSpec, RegionBound};

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

/// Where one side of a resolved `on` key pair gets its key VALUES.
///
/// The two arms are the two legible spellings of a join key (§5.3): an
/// **iterated index** whose values are the declared members of the index set it
/// draws from (known at build time), and a genuine **data column** — a declared
/// 1-D variable over that same index set, which is how MOVES/NONROAD spells
/// every join (one table's `sourceTypeID` column against another's). Encoding a
/// key column as a categorical index set whose members ARE the key values is a
/// workable fallback, but it transcribes data into the schema; the legible form
/// needs the column itself, so both are first-class here.
#[derive(Debug, Clone, PartialEq)]
pub enum KeyColumn {
    /// Build-time constant key values: `positions[k]` is a value the loop symbol
    /// takes, and `values[k]` is that position's key. Positions are the symbol's
    /// own values (a categorical / index-set range is `1..=N`, a bare interval
    /// range `[lo, hi]` is `lo..=hi`), matching the enumeration bindings.
    Const {
        /// The loop symbol's values, ascending.
        positions: Vec<i64>,
        /// The key value at each position, in the same order.
        values: Vec<JoinKey>,
    },
    /// A declared 1-D data column read at evaluation time; position `p`
    /// (1-based) is `column[p]`. Kept as a NAME, not a value list: the column is
    /// data, not schema.
    Column(String),
}

/// A resolved value-equality (`on`) join gate: the two loop symbols the clause
/// gates and, per listed key pair, the key column that supplies each side's
/// values. The structural mirror of [`crate::types::OverlapClause`]'s
/// `sym_src` / `sym_tgt` (CONFORMANCE_SPEC.md §5.5.6 / §5.5.8), and like those it
/// is resolved at build time and is NOT part of the wire form.
///
/// A multi-pair `on` clause (a **composite key**) resolving to the same symbol
/// pair collapses into ONE gate carrying one column per pair; the evaluator
/// combines them with [`crate::relational::skolem`] into a canonical composite
/// key, so a `[["a1","b1"],["a2","b2"]]` clause matches iff BOTH pairs agree —
/// the inner-join semantics of §5.3, not two independent gates.
#[derive(Debug, Clone, PartialEq)]
pub struct OnGate {
    /// A process-unique id, so the evaluator can memoize this gate's match set
    /// without hashing its (potentially large) key columns on every lookup.
    pub id: u64,
    /// The loop symbol the LEFT key columns run over.
    pub sym_l: String,
    /// The loop symbol the RIGHT key columns run over.
    pub sym_r: String,
    /// One left-side key column per listed key pair.
    pub cols_l: Vec<KeyColumn>,
    /// One right-side key column per listed key pair, positionally paired with
    /// [`Self::cols_l`].
    pub cols_r: Vec<KeyColumn>,
}

impl OnGate {
    /// This gate with every DATA-COLUMN name rewritten by `f` — the resolved
    /// mirror of the namespacing / `variable_map` renaming a flattener applies
    /// to the wire-form `on` names (CONFORMANCE_SPEC.md §5.5.6 "Join names are
    /// REFERENCES"). A [`KeyColumn::Const`] carries values, not a reference, so
    /// it is left alone, as are the loop symbols (which the node BINDS).
    ///
    /// Resolution runs after flattening in the standard pipeline, so in practice
    /// this maps `None`; it exists so the two orders agree.
    pub fn map_column_names(&self, f: impl Fn(&String) -> String) -> OnGate {
        let map = |cols: &Vec<KeyColumn>| -> Vec<KeyColumn> {
            cols.iter()
                .map(|c| match c {
                    KeyColumn::Column(n) => KeyColumn::Column(f(n)),
                    other => other.clone(),
                })
                .collect()
        };
        OnGate {
            id: self.id,
            sym_l: self.sym_l.clone(),
            sym_r: self.sym_r.clone(),
            cols_l: map(&self.cols_l),
            cols_r: map(&self.cols_r),
        }
    }
}

/// Source of [`OnGate::id`]. A gate is resolved once per node per build, and the
/// id only ever has to distinguish gates *within* one process's evaluator cache.
static NEXT_GATE_ID: AtomicU64 = AtomicU64::new(1);

fn next_gate_id() -> u64 {
    NEXT_GATE_ID.fetch_add(1, Ordering::Relaxed)
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
    // Resolve each OVERLAP clause's two range symbols FIRST — that resolution
    // needs the declared shapes of the model's variables. The same shapes are
    // what let an `on` key column name a genuine DATA COLUMN (a 1-D variable
    // over the index set its loop symbol draws from), so they are computed once
    // here and threaded into the per-node lowering too.
    let var_shapes = declared_var_shapes(model);
    resolve_overlap_join_syms(model);
    for eq in &mut model.equations {
        lower_expr_joins(&mut eq.lhs, index_sets, &var_shapes)?;
        lower_expr_joins(&mut eq.rhs, index_sets, &var_shapes)?;
    }
    if let Some(init_eqs) = &mut model.initialization_equations {
        for eq in init_eqs {
            lower_expr_joins(&mut eq.lhs, index_sets, &var_shapes)?;
            lower_expr_joins(&mut eq.rhs, index_sets, &var_shapes)?;
        }
    }
    // Parameter-update expressions are the only Expressions still carried on a
    // variable from esm 1.0.0; an unknown's definition is an equation, lowered
    // above.
    for var in model.variables.values_mut() {
        var.try_for_each_expression_mut(&mut |expr| {
            lower_expr_joins(expr, index_sets, &var_shapes)
        })?;
    }
    Ok(())
}

/// `true` iff any node in `e`'s subtree carries a `join` clause. The
/// sharing-aware gate for [`lower_expr_joins`]: after load-time interning
/// (`crate::intern`) operator payloads are shared `Arc`s, and a mutable
/// descent copy-on-write splits every node it touches — so a join-free
/// subtree (every subtree of a §9.7-expanded discretization) must be left
/// alone entirely, not walked mutably.
fn contains_join(e: &Expr) -> bool {
    match e {
        Expr::Operator(node) => node.join.is_some() || node.any_child(&mut contains_join),
        _ => false,
    }
}

/// Recursively lower `join` clauses on a node and all its children.
fn lower_expr_joins(
    expr: &mut Expr,
    index_sets: &HashMap<String, IndexSet>,
    var_shapes: &HashMap<String, Vec<String>>,
) -> Result<(), CompileError> {
    // Sharing-aware gate: only branches actually containing a `join` clause
    // are descended (and thereby copy-on-write split); see `contains_join`.
    if !contains_join(expr) {
        return Ok(());
    }
    let Some(node) = expr.node_mut() else {
        return Ok(());
    };

    if node.join.is_some() {
        lower_node_joins(node, index_sets, var_shapes)?;
    }

    // Recurse into every expression-bearing child via the canonical walker
    // (args, lower, upper, expr, filter, values, axes, key, bindings) so a
    // `join`-bearing aggregate nested in a grouping `key` or a template
    // `bindings` value is lowered too — not just the hand-picked subset this
    // used to enumerate (bug D: `key`/`bindings` were skipped, leaving a `join`
    // clause in the typed IR). The first lowering error propagates.
    node.try_for_each_child_mut(&mut |child| lower_expr_joins(child, index_sets, var_shapes))
}

/// Classify and lower one aggregate node's join clauses (see the module docs):
/// each data-derived pair becomes a member-value-equality predicate ANDed into
/// the node `filter` **and** contributes to an [`OnGate`] retained on the node
/// for the evaluator to drive enumeration from; positional pairs are dropped as
/// no-ops.
fn lower_node_joins(
    node: &mut ExpressionNode,
    index_sets: &HashMap<String, IndexSet>,
    var_shapes: &HashMap<String, Vec<String>>,
) -> Result<(), CompileError> {
    if !is_aggregate_op(&node.op) {
        return Err(CompileError::build_err(format!(
            "`join` is only valid on an aggregate/arrayop node, but appears on op '{}' \
             (RFC semiring-faq-unified-ir §5.3)",
            node.op
        )));
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
    // A spatial OVERLAP gate (CONFORMANCE_SPEC §5.5.6) is NOT lowered to a
    // filter and is NOT dropped: since the gate DRIVES enumeration on any
    // aggregate — an ordinary dense reduction as much as a `distinct` producer
    // — the clause has to survive lowering so the evaluator can build its
    // broad-phase candidate set and walk one candidate partner list per output
    // cell instead of the full product. (It used to be dropped here as a
    // numerically-inert no-op, which was true of the RESULT but left the COST
    // at `O(∏ranges)`.) Carried through verbatim, with the range symbols
    // `resolve_overlap_join_syms` resolved still attached.
    //
    // A value-equality `on` gate (§5.5.8) survives for exactly the same reason,
    // additionally carrying the [`OnGate`] resolved below. Unlike the overlap
    // broad phase it is EXACT rather than conservative, so the coded `filter`
    // predicate is emitted as well: every path that does not consult the gate
    // (the whole-array overlay, the tape, the compiled RHS loop) then still
    // computes the same answer, and the driven path's answer is verifiably
    // identical to the undriven one.
    let mut kept: Vec<JoinClause> = Vec::new();
    for clause in &joins {
        if clause.overlap.is_some() {
            kept.push(clause.clone());
            continue;
        }
        if clause.on.is_empty() {
            return Err(CompileError::build_err(
                "`join` clause has an empty `on` list; at least one [left, right] \
                 key-column pair is required (RFC semiring-faq-unified-ir §5.3)",
            ));
        }
        // Resolved key pairs, grouped by the SYMBOL PAIR they gate: several
        // `on` entries over the same two loop symbols are ONE composite-key
        // gate (all pairs must agree), not several independent ones.
        let mut groups: Vec<(String, String, Vec<KeyColumn>, Vec<KeyColumn>)> = Vec::new();
        for pair in &clause.on {
            let left = pair[0].as_str();
            let right = pair[1].as_str();

            // The left key drives matching; it must resolve to one of this
            // node's loop symbols, either by naming it (or the index set it
            // draws from) or by naming a 1-D data column over that index set.
            let l = resolve_side(left, &declared, &set_to_syms, &ranges, index_sets, var_shapes)?
                .ok_or_else(|| CompileError::UnsupportedFeatureError {
                    feature: "value-equality join over data-derived columns".to_string(),
                    message: format!(
                        "join key column '{left}' does not resolve to a loop index of this \
                         aggregate ({declared:?}): it names neither a range symbol, nor an index \
                         set one of those ranges draws from, nor a declared 1-D data column over \
                         such an index set (RFC semiring-faq-unified-ir §5.3)"
                    ),
                })?;

            // A right key resolving to no loop symbol at all is the degenerate
            // positional case: the factors already combine on the shared symbol,
            // so the join is a structural no-op.
            let Some(r) =
                resolve_side(right, &declared, &set_to_syms, &ranges, index_sets, var_shapes)?
            else {
                continue;
            };
            // Same symbol AND the same key column ⇒ the pair compares a column
            // with itself: trivially true, a structural no-op (the common dense
            // categorical disaggregation, §7.2).
            if l.sym == r.sym && l.col == r.col {
                continue;
            }

            // Value-equality: admit `(sym_l, sym_r)` iff the key columns carry
            // equal values. Lowered to a predicate the evaluator gates on like
            // any other `filter` …
            conjuncts.push(equality_predicate(&l, &r)?);

            // … and, when the two sides run over DISTINCT loop symbols, also
            // recorded as a gate the evaluator can drive enumeration from. A
            // same-symbol pair (two different columns of one table) gates a
            // single axis, which no pair-driven enumeration can accelerate, so
            // it stays predicate-only.
            if l.sym != r.sym {
                let slot = groups.iter_mut().find(|(a, b, _, _)| {
                    (*a == l.sym && *b == r.sym) || (*a == r.sym && *b == l.sym)
                });
                match slot {
                    // Pairs spelled in the opposite orientation still belong to
                    // the same gate; swap the columns into the group's order.
                    Some((a, _, cl, cr)) if *a == r.sym => {
                        cl.push(r.col);
                        cr.push(l.col);
                    }
                    Some((_, _, cl, cr)) => {
                        cl.push(l.col);
                        cr.push(r.col);
                    }
                    None => groups.push((l.sym, r.sym, vec![l.col], vec![r.col])),
                }
            }
        }
        for (sym_l, sym_r, cols_l, cols_r) in groups {
            kept.push(JoinClause {
                // The wire form is preserved verbatim — resolution is additive.
                on: clause.on.clone(),
                overlap: None,
                on_gate: Some(OnGate {
                    id: next_gate_id(),
                    sym_l,
                    sym_r,
                    cols_l,
                    cols_r,
                }),
            });
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
            Expr::operator(ExpressionNode {
                op: "*".into(),
                args: conjuncts,
                ..Default::default()
            })
        };
        node.filter = Some(Box::new(pred));
    }
    if !kept.is_empty() {
        node.join = Some(kept);
    }

    Ok(())
}

/// One side of an `on` key pair, resolved to the loop symbol it gates and the
/// column supplying that symbol's key values.
#[derive(Debug, Clone, PartialEq)]
struct ResolvedSide {
    sym: String,
    col: KeyColumn,
}

/// Resolve one `on` key column (RFC §5.3), in the normative precedence order of
/// CONFORMANCE_SPEC.md §5.5.6 ("binders shadow declarations"):
///
/// 1. a **loop symbol** of this node — or the index set one of its ranges draws
///    from — whose key values are the set's declared members / the interval's
///    integer IDs, known at build time;
/// 2. otherwise a **data column**: a declared 1-D variable whose single shape
///    index set names one of this node's ranges. This is the MOVES/NONROAD
///    shape (one table's `sourceTypeID` column against another's) and the
///    normal case for a relational port, not an exotic one.
///
/// `None` when it resolves to neither; the caller decides whether that is the
/// degenerate positional no-op (right key) or an error (left key).
fn resolve_side(
    key: &str,
    declared: &HashSet<&str>,
    set_to_syms: &HashMap<&str, Vec<&str>>,
    ranges: &HashMap<String, RangeSpec>,
    index_sets: &HashMap<String, IndexSet>,
    var_shapes: &HashMap<String, Vec<String>>,
) -> Result<Option<ResolvedSide>, CompileError> {
    if let Some(sym) = resolve_key(key, declared, set_to_syms) {
        let (positions, values) = key_column(&sym, ranges, index_sets)?;
        return Ok(Some(ResolvedSide {
            sym,
            col: KeyColumn::Const { positions, values },
        }));
    }
    if let Some(shape) = var_shapes.get(key)
        && shape.len() == 1
        && let Some(sym) = resolve_key(&shape[0], declared, set_to_syms)
    {
        return Ok(Some(ResolvedSide {
            sym,
            col: KeyColumn::Column(key.to_string()),
        }));
    }
    Ok(None)
}

/// The `filter` predicate for one resolved key pair: `<left key> == <right key>`.
///
/// Two **constant** columns are dense-CODED against each other first — each
/// value replaced by its rank in the sorted union of the pair's distinct values
/// ([`encode_columns`]) — which is what lets categorical *string* members be
/// compared by a purely numeric evaluator, and makes the equality classes
/// independent of declared member order. As soon as one side is a data column
/// there is no build-time value set to code against, so both sides are compared
/// on their RAW values: a data column reads `index(col, sym)`, and a constant
/// column becomes a constant table of its integer IDs.
fn equality_predicate(l: &ResolvedSide, r: &ResolvedSide) -> Result<Expr, CompileError> {
    let (le, re) = match (&l.col, &r.col) {
        (
            KeyColumn::Const {
                positions: pl,
                values: vl,
            },
            KeyColumn::Const {
                positions: pr,
                values: vr,
            },
        ) => {
            let (cl, cr) = encode_columns(vl, vr);
            (code_lookup(pl, &cl, &l.sym), code_lookup(pr, &cr, &r.sym))
        }
        _ => (raw_key_expr(l)?, raw_key_expr(r)?),
    };
    Ok(Expr::operator(ExpressionNode {
        op: "==".into(),
        args: vec![le, re],
        ..Default::default()
    }))
}

/// One side of a raw (uncoded) key comparison — see [`equality_predicate`].
fn raw_key_expr(s: &ResolvedSide) -> Result<Expr, CompileError> {
    match &s.col {
        KeyColumn::Column(name) => Ok(Expr::operator(ExpressionNode {
            op: "index".into(),
            args: vec![Expr::Variable(name.clone()), Expr::Variable(s.sym.clone())],
            ..Default::default()
        })),
        KeyColumn::Const { positions, values } => {
            let ints = values
                .iter()
                .map(|v| match v {
                    JoinKey::Int(i) => Ok(*i),
                    JoinKey::Cat(c) => Err(CompileError::UnsupportedFeatureError {
                        feature: "value-equality join of a categorical member column against a \
                                  numeric data column"
                            .to_string(),
                        message: format!(
                            "join key '{}' carries the categorical member '{c}', but the other \
                             side of the pair is a numeric data column; an index-set member \
                             column equi-joined against a data column must carry integer IDs \
                             (RFC semiring-faq-unified-ir §5.3 / §5.7 rule 1)",
                            s.sym
                        ),
                    }),
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok(code_lookup(positions, &ints, &s.sym))
        }
    }
}

/// Resolve every OVERLAP join clause's two range symbols in `model`, in place.
///
/// An overlap gate names const-array envelope FACTORS, not loop symbols; like
/// an `on` key column, each factor is a 1-D buffer whose shape index set names
/// the join range, so the first factor of a side identifies that side's
/// aggregate range symbol. That mapping needs BOTH the node's own ranges (with
/// their `{ "from": <index set> }` linkage intact) and the model's declared
/// variable shapes — which is why it lives here rather than inside
/// [`lower_node_joins`], and why it must run BEFORE
/// [`crate::aggregate::resolve_aggregate_ranges`] erases the linkage.
///
/// Mirrors the Julia `_overlap_env_sym` (`tree_walk/semiring.jl`). Deliberately
/// INFALLIBLE: a factor whose shape is unknown or not 1-D, or an index set no
/// range draws from, simply leaves the symbol `None`, and the enumeration
/// driver then declines to drive that gate (the full product still runs and
/// still produces the same answer). Erroring here would turn documents whose
/// overlap gate the dense evaluator has always ignored into build failures.
pub fn resolve_overlap_join_syms(model: &mut Model) {
    let var_shapes = declared_var_shapes(model);
    for eq in &mut model.equations {
        resolve_overlap_syms_expr(&mut eq.lhs, &var_shapes);
        resolve_overlap_syms_expr(&mut eq.rhs, &var_shapes);
    }
    if let Some(init_eqs) = &mut model.initialization_equations {
        for eq in init_eqs {
            resolve_overlap_syms_expr(&mut eq.lhs, &var_shapes);
            resolve_overlap_syms_expr(&mut eq.rhs, &var_shapes);
        }
    }
    for var in model.variables.values_mut() {
        var.for_each_expression_mut(&mut |expr| resolve_overlap_syms_expr(expr, &var_shapes));
    }
}

/// Every declared variable's shape (index-set names), for
/// [`resolve_overlap_join_syms`]. Mirrors the Julia `_declared_var_shapes`.
pub fn declared_var_shapes(model: &Model) -> HashMap<String, Vec<String>> {
    model
        .variables
        .iter()
        .filter_map(|(n, v)| v.shape.as_ref().map(|s| (n.clone(), s.clone())))
        .collect()
}

/// [`resolve_overlap_join_syms`] over one expression tree.
pub fn resolve_overlap_syms_expr(expr: &mut Expr, var_shapes: &HashMap<String, Vec<String>>) {
    // Sharing-aware gate: only branches actually containing a `join` clause are
    // descended (and thereby copy-on-write split); see `contains_join`.
    if !contains_join(expr) {
        return;
    }
    let Some(node) = expr.node_mut() else {
        return;
    };
    if node.join.is_some() {
        let ranges = node.ranges.clone().unwrap_or_default();
        let declared: HashSet<&str> = ranges.keys().map(String::as_str).collect();
        let mut set_to_syms: HashMap<&str, Vec<&str>> = HashMap::new();
        for (sym, spec) in &ranges {
            if let RangeSpec::IndexSetRef { from, .. } = spec {
                set_to_syms.entry(from.as_str()).or_default().push(sym);
            }
        }
        // A set drawn by two symbols is ambiguous; sort so at least the CHOICE
        // is deterministic, then reject the ambiguous case below.
        for syms in set_to_syms.values_mut() {
            syms.sort_unstable();
        }
        let env_sym = |env: &[String]| -> Option<String> {
            let shape = var_shapes.get(env.first()?)?;
            if shape.len() != 1 {
                return None;
            }
            resolve_key(&shape[0], &declared, &set_to_syms)
        };
        if let Some(joins) = &mut node.join {
            for clause in joins.iter_mut() {
                if let Some(ov) = &mut clause.overlap {
                    ov.sym_src = env_sym(&ov.src_env);
                    ov.sym_tgt = env_sym(&ov.tgt_env);
                }
            }
        }
    }
    node.for_each_child_mut(&mut |child| resolve_overlap_syms_expr(child, var_shapes));
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
                CompileError::build_err(format!(
                    "join key '{sym}' references index set '{from}', which is not declared \
                             in the document `index_sets` registry (RFC semiring-faq-unified-ir §5.3)"
                ))
            })?;
            match set.kind.as_str() {
                "categorical" => {
                    let members = set.members.as_ref().ok_or_else(|| {
                        CompileError::build_err(format!(
                            "categorical index set '{from}' (join key '{sym}') has no `members`"
                        ))
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
                        .ok_or_else(|| {
                            CompileError::build_err(format!(
                                "interval index set '{from}' (join key '{sym}') has no `size`"
                            ))
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
        None => Err(CompileError::build_err(format!(
            "join key '{sym}' has no declared range on this aggregate"
        ))),
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
        CompileError::build_err(format!(
            "{why} in join key index set '{set_name}': join keys must be integer IDs or \
             categorical members — floats / nulls are forbidden (equality is not portable \
             across bindings; RFC semiring-faq-unified-ir §5.3 / §5.7 rule 1)"
        ))
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
    let mut regions: Vec<Vec<[RegionBound; 2]>> = Vec::with_capacity(hi.max(0) as usize);
    let mut values: Vec<Expr> = Vec::with_capacity(hi.max(0) as usize);
    for p in 1..=hi {
        regions.push(vec![[RegionBound::Int(p), RegionBound::Int(p)]]);
        values.push(Expr::Integer(code_at.get(&p).copied().unwrap_or(0)));
    }
    let table = Expr::operator(ExpressionNode {
        op: "makearray".into(),
        regions: Some(regions),
        values: Some(values),
        ..Default::default()
    });
    Expr::operator(ExpressionNode {
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

    /// A model with no declared variable shapes — the fixtures below key every
    /// join on a loop symbol, so no data column can resolve.
    fn no_shapes() -> HashMap<String, Vec<String>> {
        HashMap::new()
    }

    fn categorical(members: &[&str]) -> IndexSet {
        IndexSet {
            kind: "categorical".into(),
            size: None,
            members: Some(members.iter().map(|m| Value::from(*m)).collect()),
            from_faq: None,
            member_factor: None,
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
        Expr::operator(ExpressionNode {
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
        let mut expr = Expr::operator(ExpressionNode {
            op: "aggregate".into(),
            ranges: Some(range_map),
            output_idx: Some(vec![]),
            join: Some(vec![JoinClause {
                on: vec![["i".into(), "j".into()]],
                ..Default::default()
            }]),
            expr: Some(Box::new(Expr::Number(1.0))),
            ..Default::default()
        });
        let mut isets = HashMap::new();
        isets.insert("sources".to_string(), categorical(&["coal", "coal", "oil"]));
        isets.insert("factors".to_string(), categorical(&["coal", "coal", "gas"]));

        lower_expr_joins(&mut expr, &isets, &no_shapes()).unwrap();
        let Expr::Operator(node) = &expr else {
            panic!("expr is not an operator");
        };
        let filter = node
            .filter
            .as_ref()
            .expect("data-derived join adds a filter");
        let Expr::Operator(f) = filter.as_ref() else {
            panic!("filter is not an operator");
        };
        assert_eq!(f.op, "==", "a single key pair lowers to one equality gate");
        // …and the clause SURVIVES carrying the resolved gate, so the evaluator
        // can drive enumeration from the match set (§5.5.8) instead of testing
        // the predicate over the full product.
        let gate = node
            .join
            .as_ref()
            .and_then(|j| j.first())
            .and_then(|c| c.on_gate.as_ref())
            .expect("data-derived join attaches a drivable gate");
        assert_eq!((gate.sym_l.as_str(), gate.sym_r.as_str()), ("i", "j"));
        assert_eq!(gate.cols_l.len(), 1, "one column per listed key pair");
        assert!(matches!(
            gate.cols_l[0],
            KeyColumn::Const { .. } | KeyColumn::Column(_)
        ));
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
            ..Default::default()
        }];
        let mut expr = agg_with_join(join, vec!["src", "fuel"]);
        lower_expr_joins(&mut expr, &HashMap::new(), &no_shapes()).unwrap();
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
            ..Default::default()
        }];
        let mut expr = agg_with_join(join, vec!["src", "fuel"]);
        let err = lower_expr_joins(&mut expr, &HashMap::new(), &no_shapes()).unwrap_err();
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
        let join = vec![JoinClause {
            on: vec![],
            ..Default::default()
        }];
        let mut expr = agg_with_join(join, vec!["src"]);
        assert!(lower_expr_joins(&mut expr, &HashMap::new(), &no_shapes()).is_err());
    }

    #[test]
    fn rejects_join_on_non_aggregate_op() {
        // A `join` smuggled onto a non-aggregate op is a build error.
        let mut bogus = Expr::operator(ExpressionNode {
            op: "+".into(),
            join: Some(vec![JoinClause {
                on: vec![["a".into(), "b".into()]],
                ..Default::default()
            }]),
            args: vec![Expr::Variable("x".into())],
            ..Default::default()
        });
        assert!(lower_expr_joins(&mut bogus, &HashMap::new(), &no_shapes()).is_err());
    }

    #[test]
    fn noop_when_no_join_present() {
        // An aggregate node with no join clause resolves trivially, and the walk
        // recurses into nested children without spurious errors.
        let mut agg = Expr::operator(ExpressionNode {
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
        lower_expr_joins(&mut agg, &HashMap::new(), &no_shapes()).unwrap();
        let Expr::Operator(node) = &agg else {
            panic!("expr is not an operator");
        };
        assert!(node.filter.is_none(), "no join ⇒ no synthesized filter");
    }
}
