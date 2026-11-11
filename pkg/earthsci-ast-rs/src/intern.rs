//! Load-scoped structural interning (hash-consing) of [`ExpressionNode`]s.
//!
//! ## Why
//!
//! A §9.7-expanded discretization repeats the same subtrees relentlessly: on a
//! real model the typed AST holds millions of expression-node occurrences but
//! only a few thousand structurally distinct subtrees. With an inline
//! `ExpressionNode` payload every occurrence was a full several-hundred-byte
//! copy, which made the typed AST the dominant load-phase allocation.
//! [`Expr::Operator`] now carries
//! `Arc<ExpressionNode>`, and this module collapses structurally identical
//! nodes onto one allocation **while they are being deserialized**, so the
//! duplicate copies never exist even transiently.
//!
//! ## How
//!
//! A thread-local interner is armed by [`InternScope`] for the duration of one
//! `serde_json::from_value::<EsmFile>` call (see `crate::parse::load_with_options`).
//! [`Expr::operator`] — the single constructor every deserialized operator
//! node passes through — consults it: a node structurally equal to one
//! already seen returns a clone of the canonical `Arc`; a new node is
//! recorded. Deserialization is bottom-up (a node's children are built before
//! the node itself), so every `Operator` **child** of a candidate node is
//! already canonical, which is what licenses the pointer-based child rule
//! below. Without an active scope, [`intern_node`] is a plain `Arc::new`.
//!
//! ## The equivalence relation
//!
//! Two nodes are interned together only when they are **exactly** structurally
//! equal:
//!
//! * every non-child field is compared by value ([`node_eq`] destructures
//!   `ExpressionNode` exhaustively, so adding a field without deciding its
//!   role here is a compile error);
//! * float literals compare by **bit pattern** (`f64::to_bits`), so `0.0` and
//!   `-0.0` — which compare equal but are not interchangeable under `1/x` —
//!   stay distinct, and `NaN` payloads intern consistently. This matches the
//!   CSE overlay's `CseKey::Num` rule;
//! * child expressions compare leaves by value (same bit rule) and operator
//!   children by `Arc::ptr_eq`. Pointer equality of canonical children IS
//!   structural equality of the subtrees (the hash-consing invariant); a
//!   non-canonical child (constructed outside an interning scope) can only
//!   compare unequal, i.e. cost a missed dedup, never a wrong merge;
//! * `HashMap`-valued fields (`ranges`, `axes`, `bindings`) are compared as
//!   maps and hashed in sorted-key order;
//! * a `const` literal's `value` is keyed exactly ([`literal_eq`]): numbers
//!   by representation (signed, unsigned or float) and floats by bit
//!   pattern, arrays element by element, so the repeated `const` tables of an
//!   expanded template collapse onto one node — and with them every subtree
//!   that reads them;
//! * a node carrying a field this module does not key **exactly** — `join`
//!   (clauses with float `eps`) — is refused outright ([`internable`]) and allocated
//!   fresh, so an unkeyed attribute can never cause two different nodes to
//!   merge.
//!
//! ## What sharing must NOT break
//!
//! * **Mutation**: all mutation of operator payloads goes through
//!   `Arc::make_mut` (copy-on-write), so a mutated node splits from its
//!   sharers first; single-tree semantics are unchanged.
//! * **The address-keyed CSE overlay** (`simulate_array/cse.rs`): after
//!   interning, one node address appears under many rules and binder
//!   contexts. The overlay's per-scope memo and structural classes are
//!   context-free (safe under sharing); the two context-DEPENDENT pieces —
//!   the persistent box-pure (`PURE_BIT`) marks and the body-root exclusion —
//!   are hardened in `cse.rs` (binder-set-keyed validity for pure marks, a
//!   persistent root tombstone). See the module docs there.

use crate::types::{Expr, ExpressionNode};
use rustc_hash::FxHashMap;
use smallvec::SmallVec;
use std::cell::RefCell;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

thread_local! {
    static INTERNER: RefCell<Option<Interner>> = const { RefCell::new(None) };
}

#[derive(Default)]
struct Interner {
    /// Reentrancy depth of [`InternScope`]s; the map is dropped when the
    /// outermost scope closes.
    depth: usize,
    /// The canonical nodes by structural hash (nodes whose hashes collide
    /// share a bucket). Keyed by the hash rather than by the node, so a
    /// candidate is looked up before it is allocated: a duplicate is never
    /// boxed, and the map never re-reads a stored node to rehash it.
    set: FxHashMap<u64, SmallVec<[Arc<ExpressionNode>; 1]>>,
}

/// RAII guard arming the thread-local interner. Reentrant: nested scopes share
/// one map; the map is discarded when the outermost scope closes (interned
/// nodes stay alive through the trees that reference them).
pub struct InternScope {
    _not_send: std::marker::PhantomData<*const ()>,
}

impl InternScope {
    pub fn new() -> InternScope {
        INTERNER.with(|c| {
            let mut i = c.borrow_mut();
            let i = i.get_or_insert_with(Interner::default);
            i.depth += 1;
        });
        InternScope {
            _not_send: std::marker::PhantomData,
        }
    }
}

impl Default for InternScope {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for InternScope {
    fn drop(&mut self) {
        INTERNER.with(|c| {
            let mut slot = c.borrow_mut();
            if let Some(i) = slot.as_mut() {
                i.depth -= 1;
                if i.depth == 0 {
                    *slot = None;
                }
            }
        });
    }
}

/// Wrap `node` in an `Arc`, returning the canonical `Arc` for its structure
/// when a scope is active (and the node is [`internable`]); a fresh allocation
/// otherwise.
pub fn intern_node(node: ExpressionNode) -> Arc<ExpressionNode> {
    INTERNER.with(|c| {
        let mut slot = c.borrow_mut();
        let Some(interner) = slot.as_mut() else {
            return Arc::new(node);
        };
        if !internable(&node) {
            return Arc::new(node);
        }
        let mut hasher = rustc_hash::FxHasher::default();
        node_hash(&node, &mut hasher);
        let bucket = interner.set.entry(hasher.finish()).or_default();
        if let Some(canon) = bucket.iter().find(|c| node_eq(c, &node)) {
            return Arc::clone(canon);
        }
        let out = Arc::new(node);
        bucket.push(Arc::clone(&out));
        out
    })
}

/// Whether this module can key `node` exactly. `join` carries float-bearing
/// clause structs; rather than invent a keying for that rare field, a node
/// carrying one is simply never shared.
fn internable(node: &ExpressionNode) -> bool {
    node.join.is_none()
}

/// A JSON number by its exact representation: a float never equals an
/// integer spelling of the same value, and floats compare by bit pattern.
#[derive(PartialEq, Eq, Hash)]
enum NumberKey {
    Signed(i64),
    Unsigned(u64),
    Float(u64),
}

fn number_key(n: &serde_json::Number) -> NumberKey {
    if let Some(i) = n.as_i64() {
        NumberKey::Signed(i)
    } else if let Some(u) = n.as_u64() {
        NumberKey::Unsigned(u)
    } else {
        NumberKey::Float(n.as_f64().unwrap_or(f64::NAN).to_bits())
    }
}

/// Exact equality of two literal payloads (a `const` node's `value`):
/// numbers by [`NumberKey`], arrays and objects entry by entry in order.
fn literal_eq(a: &serde_json::Value, b: &serde_json::Value) -> bool {
    use serde_json::Value as V;
    match (a, b) {
        (V::Null, V::Null) => true,
        (V::Bool(x), V::Bool(y)) => x == y,
        (V::Number(x), V::Number(y)) => number_key(x) == number_key(y),
        (V::String(x), V::String(y)) => x == y,
        (V::Array(x), V::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| literal_eq(p, q))
        }
        (V::Object(x), V::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .zip(y)
                    .all(|((ka, va), (kb, vb))| ka == kb && literal_eq(va, vb))
        }
        _ => false,
    }
}

/// Hash consistent with [`literal_eq`].
fn literal_hash<H: Hasher>(v: &serde_json::Value, h: &mut H) {
    use serde_json::Value as V;
    match v {
        V::Null => 0u8.hash(h),
        V::Bool(b) => {
            1u8.hash(h);
            b.hash(h);
        }
        V::Number(n) => {
            2u8.hash(h);
            number_key(n).hash(h);
        }
        V::String(s) => {
            3u8.hash(h);
            s.hash(h);
        }
        V::Array(items) => {
            4u8.hash(h);
            items.len().hash(h);
            for x in items {
                literal_hash(x, h);
            }
        }
        V::Object(m) => {
            5u8.hash(h);
            m.len().hash(h);
            for (k, x) in m {
                k.hash(h);
                literal_hash(x, h);
            }
        }
    }
}

/// Child-expression equality under the hash-consing invariant: leaves by value
/// (floats by bits), operator children by pointer.
fn child_eq(a: &Expr, b: &Expr) -> bool {
    match (a, b) {
        (Expr::Integer(x), Expr::Integer(y)) => x == y,
        (Expr::Number(x), Expr::Number(y)) => x.to_bits() == y.to_bits(),
        (Expr::Variable(x), Expr::Variable(y)) => x == y,
        (Expr::Operator(x), Expr::Operator(y)) => Arc::ptr_eq(x, y),
        _ => false,
    }
}

fn child_hash<H: Hasher>(e: &Expr, h: &mut H) {
    match e {
        Expr::Integer(i) => {
            0u8.hash(h);
            i.hash(h);
        }
        Expr::Number(n) => {
            1u8.hash(h);
            n.to_bits().hash(h);
        }
        Expr::Variable(v) => {
            2u8.hash(h);
            v.hash(h);
        }
        Expr::Operator(rc) => {
            3u8.hash(h);
            (Arc::as_ptr(rc) as usize).hash(h);
        }
    }
}

fn opt_child_eq(a: &Option<Box<Expr>>, b: &Option<Box<Expr>>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(x), Some(y)) => child_eq(x, y),
        _ => false,
    }
}

fn opt_child_hash<H: Hasher>(e: &Option<Box<Expr>>, h: &mut H) {
    match e {
        None => 0u8.hash(h),
        Some(x) => {
            1u8.hash(h);
            child_hash(x, h);
        }
    }
}

fn child_vec_eq(a: &[Expr], b: &[Expr]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| child_eq(x, y))
}

fn child_map_eq(
    a: &Option<std::collections::HashMap<String, Expr>>,
    b: &Option<std::collections::HashMap<String, Expr>>,
) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(x), Some(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.get(k).map(|w| child_eq(v, w)).unwrap_or(false))
        }
        _ => false,
    }
}

fn child_map_hash<H: Hasher>(m: &Option<std::collections::HashMap<String, Expr>>, h: &mut H) {
    match m {
        None => 0u8.hash(h),
        Some(m) => {
            1u8.hash(h);
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort_unstable();
            keys.len().hash(h);
            for k in keys {
                k.hash(h);
                child_hash(&m[k], h);
            }
        }
    }
}

/// Exact structural equality of two internable nodes. Destructures
/// exhaustively so that a newly added `ExpressionNode` field is a compile
/// error here until its interning role is decided.
fn node_eq(a: &ExpressionNode, b: &ExpressionNode) -> bool {
    let ExpressionNode {
        op,
        args,
        wrt,
        dim,
        int_var,
        lower,
        upper,
        expr,
        output_idx,
        ranges,
        reduce,
        semiring,
        join,
        filter,
        regions,
        values,
        shape,
        perm,
        axis,
        broadcast_fn,
        name,
        value,
        units,
        id,
        bindings,
        distinct,
        key,
        expect_cadence,
        attrs,
        template_origin,
    } = a;
    // `internable` refused these; assert the contract rather than compare.
    debug_assert!(join.is_none());
    debug_assert!(b.join.is_none());
    op == &b.op
        && match (value, &b.value) {
            (None, None) => true,
            (Some(x), Some(y)) => literal_eq(x, y),
            _ => false,
        }
        && child_vec_eq(args, &b.args)
        && wrt == &b.wrt
        && units == &b.units
        && dim == &b.dim
        && int_var == &b.int_var
        && opt_child_eq(lower, &b.lower)
        && opt_child_eq(upper, &b.upper)
        && opt_child_eq(expr, &b.expr)
        && output_idx == &b.output_idx
        && ranges == &b.ranges
        && reduce == &b.reduce
        && semiring == &b.semiring
        && opt_child_eq(filter, &b.filter)
        && regions == &b.regions
        && match (values, &b.values) {
            (None, None) => true,
            (Some(x), Some(y)) => child_vec_eq(x, y),
            _ => false,
        }
        && shape == &b.shape
        && perm == &b.perm
        && axis == &b.axis
        && broadcast_fn == &b.broadcast_fn
        && name == &b.name
        && id == &b.id
        && child_map_eq(bindings, &b.bindings)
        && distinct == &b.distinct
        && opt_child_eq(key, &b.key)
        // Both are author-supplied annotations with no bearing on the value a
        // node computes, but they are still emitted, so two nodes differing
        // only in one of them MUST NOT collapse to a single allocation — that
        // would silently unify (and so drop one of) the two annotations.
        && expect_cadence == &b.expect_cadence
        && attrs == &b.attrs
        // Load provenance the elementwise lift reads (esm-spec §9.6.11): an
        // expansion root and an identical hand-written node are not one node.
        && template_origin == &b.template_origin
}

/// Structural hash consistent with [`node_eq`].
fn node_hash<H: Hasher>(n: &ExpressionNode, h: &mut H) {
    let ExpressionNode {
        op,
        args,
        wrt,
        dim,
        int_var,
        lower,
        upper,
        expr,
        output_idx,
        ranges,
        reduce,
        semiring,
        join: _,
        filter,
        regions,
        values,
        shape,
        perm,
        axis,
        broadcast_fn,
        name,
        value,
        units,
        id,
        bindings,
        distinct,
        key,
        expect_cadence,
        attrs,
        template_origin: _,
    } = n;
    op.hash(h);
    match value {
        None => 0u8.hash(h),
        Some(v) => {
            1u8.hash(h);
            literal_hash(v, h);
        }
    }
    args.len().hash(h);
    for a in args {
        child_hash(a, h);
    }
    wrt.hash(h);
    units.hash(h);
    dim.hash(h);
    int_var.hash(h);
    opt_child_hash(lower, h);
    opt_child_hash(upper, h);
    opt_child_hash(expr, h);
    output_idx.hash(h);
    match ranges {
        None => 0u8.hash(h),
        Some(r) => {
            1u8.hash(h);
            let mut keys: Vec<&String> = r.keys().collect();
            keys.sort_unstable();
            keys.len().hash(h);
            for k in keys {
                k.hash(h);
                r[k].hash(h);
            }
        }
    }
    reduce.hash(h);
    semiring.hash(h);
    opt_child_hash(filter, h);
    // `RegionBound` cannot derive `Hash` (its `Expr` variant carries an
    // `f64`), so hash it explicitly: the discriminant plus either the integer
    // or the child expression's structural hash.
    match regions {
        None => 0u8.hash(h),
        Some(rs) => {
            1u8.hash(h);
            rs.len().hash(h);
            for region in rs {
                region.len().hash(h);
                for pair in region {
                    for b in pair {
                        match b {
                            crate::types::RegionBound::Int(i) => {
                                0u8.hash(h);
                                i.hash(h);
                            }
                            crate::types::RegionBound::Expr(e) => {
                                1u8.hash(h);
                                child_hash(e, h);
                            }
                        }
                    }
                }
            }
        }
    }
    match values {
        None => 0u8.hash(h),
        Some(vs) => {
            1u8.hash(h);
            vs.len().hash(h);
            for v in vs {
                child_hash(v, h);
            }
        }
    }
    shape.hash(h);
    perm.hash(h);
    axis.hash(h);
    broadcast_fn.hash(h);
    name.hash(h);
    id.hash(h);
    child_map_hash(bindings, h);
    distinct.hash(h);
    opt_child_hash(key, h);
    expect_cadence.hash(h);
    // `serde_json::Value` is not `Hash`; its canonical text is, and equal
    // `Value`s that differ only in object key order still hash apart — which
    // costs a missed intern, never a wrong one (`node_eq` remains the arbiter).
    match attrs {
        None => 0u8.hash(h),
        Some(v) => {
            1u8.hash(h);
            v.to_string().hash(h);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn op(name: &str, args: Vec<Expr>) -> ExpressionNode {
        ExpressionNode {
            op: name.to_string(),
            args,
            ..Default::default()
        }
    }

    /// Identical structure interns to one allocation; different structure does
    /// not; and everything falls back to fresh allocations without a scope.
    #[test]
    fn identical_subtrees_share_one_allocation() {
        let _scope = InternScope::new();
        let mk = || Expr::operator(op("+", vec![Expr::Variable("a".into()), Expr::Integer(1)]));
        let (a, b) = (mk(), mk());
        let (Expr::Operator(x), Expr::Operator(y)) = (&a, &b) else {
            unreachable!()
        };
        assert!(Arc::ptr_eq(x, y), "identical nodes must intern together");
        let c = Expr::operator(op("+", vec![Expr::Variable("a".into()), Expr::Integer(2)]));
        let Expr::Operator(z) = &c else {
            unreachable!()
        };
        assert!(!Arc::ptr_eq(x, z), "different nodes must not merge");
    }

    #[test]
    fn no_scope_means_no_sharing() {
        let mk = || Expr::operator(op("+", vec![Expr::Variable("a".into()), Expr::Integer(1)]));
        let (a, b) = (mk(), mk());
        let (Expr::Operator(x), Expr::Operator(y)) = (&a, &b) else {
            unreachable!()
        };
        assert!(!Arc::ptr_eq(x, y), "without a scope every node is fresh");
    }

    /// Nested sharing: interning is bottom-up, so an outer node whose children
    /// interned to the same pointers is itself deduplicated.
    #[test]
    fn nesting_shares_whole_subtrees() {
        let _scope = InternScope::new();
        let mk = || {
            let inner =
                Expr::operator(op("*", vec![Expr::Variable("x".into()), Expr::Number(0.5)]));
            Expr::operator(op("sin", vec![inner]))
        };
        let (a, b) = (mk(), mk());
        let (Expr::Operator(x), Expr::Operator(y)) = (&a, &b) else {
            unreachable!()
        };
        assert!(Arc::ptr_eq(x, y));
    }

    /// `0.0` and `-0.0` compare equal as floats but must NOT intern together —
    /// they are not interchangeable under `1/x`, and the CSE overlay pins the
    /// same distinction (`CseKey::Num` keys raw bits).
    #[test]
    fn signed_zero_stays_distinct() {
        let _scope = InternScope::new();
        let a = Expr::operator(op("neg", vec![Expr::Number(0.0)]));
        let b = Expr::operator(op("neg", vec![Expr::Number(-0.0)]));
        let (Expr::Operator(x), Expr::Operator(y)) = (&a, &b) else {
            unreachable!()
        };
        assert!(!Arc::ptr_eq(x, y), "-0.0 and 0.0 must stay distinct");
        // NaN, by contrast, interns consistently with itself (same payload).
        let n1 = Expr::operator(op("neg", vec![Expr::Number(f64::NAN)]));
        let n2 = Expr::operator(op("neg", vec![Expr::Number(f64::NAN)]));
        let (Expr::Operator(p), Expr::Operator(q)) = (&n1, &n2) else {
            unreachable!()
        };
        assert!(Arc::ptr_eq(p, q), "same-bits NaN interns to one node");
    }

    /// Attribute-bearing nodes participate: equal attributes intern together,
    /// any differing attribute keeps nodes separate.
    #[test]
    fn attrs_participate_in_the_key() {
        let _scope = InternScope::new();
        let mk = |dim: &str| {
            let mut n = op("faq", vec![]);
            n.output_idx = Some(vec!["i".to_string()]);
            n.dim = Some(dim.to_string());
            n.expr = Some(Box::new(Expr::Variable("q".into())));
            Expr::operator(n)
        };
        let (a1, a2, b) = (mk("x"), mk("x"), mk("y"));
        let (Expr::Operator(x1), Expr::Operator(x2), Expr::Operator(y)) = (&a1, &a2, &b) else {
            unreachable!()
        };
        assert!(Arc::ptr_eq(x1, x2), "equal attrs intern together");
        assert!(!Arc::ptr_eq(x1, y), "a differing attr keeps nodes apart");
    }

    /// Binder-carrying subtrees (aggregate `output_idx`/`ranges`) DO intern —
    /// sharing them is safe because the CSE overlay's context-dependent state
    /// is validated against the binder set at runtime (see cse.rs); two
    /// aggregates differing only in `ranges` must stay distinct.
    #[test]
    fn ranges_are_keyed_exactly() {
        use crate::types::RangeSpec;
        let _scope = InternScope::new();
        let mk = |hi: i64| {
            let mut n = op("faq", vec![]);
            n.output_idx = Some(vec!["i".to_string()]);
            n.ranges = Some(
                [("i".to_string(), RangeSpec::Interval([1, hi]))]
                    .into_iter()
                    .collect(),
            );
            n.expr = Some(Box::new(Expr::Variable("q".into())));
            Expr::operator(n)
        };
        let (a1, a2, b) = (mk(4), mk(4), mk(5));
        let (Expr::Operator(x1), Expr::Operator(x2), Expr::Operator(y)) = (&a1, &a2, &b) else {
            unreachable!()
        };
        assert!(Arc::ptr_eq(x1, x2));
        assert!(!Arc::ptr_eq(x1, y), "different ranges must not merge");
    }

    /// Nodes carrying a field this module refuses to key (`join`) are never
    /// shared, even when byte-identical.
    #[test]
    fn unkeyed_fields_refuse_interning() {
        let _scope = InternScope::new();
        let mk = || {
            let mut n = op("faq", vec![]);
            n.join = Some(vec![crate::types::JoinClause::default()]);
            Expr::operator(n)
        };
        let (a, b) = (mk(), mk());
        let (Expr::Operator(x), Expr::Operator(y)) = (&a, &b) else {
            unreachable!()
        };
        assert!(!Arc::ptr_eq(x, y), "join-bearing nodes are never merged");
    }

    /// `const` literals are keyed exactly: the same array interns to one
    /// node (and so does a subtree reading it), while a float and an
    /// integer spelling of one value, `0.0` and `-0.0`, or a different
    /// nesting stay apart.
    #[test]
    fn const_literals_intern_exactly() {
        let _scope = InternScope::new();
        let lit = |v: serde_json::Value| {
            let mut n = op("const", vec![]);
            n.value = Some(v);
            Expr::operator(n)
        };
        let ptr = |e: &Expr| match e {
            Expr::Operator(rc) => Arc::as_ptr(rc),
            _ => unreachable!(),
        };
        let a = lit(serde_json::json!([1.0, 2.5, 4.0]));
        let b = lit(serde_json::json!([1.0, 2.5, 4.0]));
        assert_eq!(ptr(&a), ptr(&b), "equal literals intern together");
        let read = |t: Expr| Expr::operator(op("index", vec![t, Expr::Variable("k".into())]));
        assert_eq!(
            ptr(&read(a.clone())),
            ptr(&read(b)),
            "and so do their readers"
        );
        for other in [
            serde_json::json!([1, 2.5, 4.0]),
            serde_json::json!([1.0, 2.5]),
            serde_json::json!([[1.0, 2.5, 4.0]]),
            serde_json::json!([1.0, 2.5, -4.0]),
        ] {
            assert_ne!(ptr(&a), ptr(&lit(other.clone())), "{other}");
        }
        assert_ne!(
            ptr(&lit(serde_json::json!(0.0))),
            ptr(&lit(serde_json::json!(-0.0))),
            "-0.0 and 0.0 stay distinct"
        );
    }

    /// Copy-on-write: mutating one occurrence of a shared node must not change
    /// the other occurrence.
    #[test]
    fn make_mut_splits_shared_nodes() {
        let _scope = InternScope::new();
        let mk = || Expr::operator(op("+", vec![Expr::Variable("a".into()), Expr::Integer(1)]));
        let (mut a, b) = (mk(), mk());
        let n = a.node_mut().expect("operator");
        n.op = "-".to_string();
        let (Expr::Operator(x), Expr::Operator(y)) = (&a, &b) else {
            unreachable!()
        };
        assert!(!Arc::ptr_eq(x, y));
        assert_eq!(y.op, "+", "the sharer must be unaffected");
        assert_eq!(x.op, "-");
    }

    /// Deserializing a document inside a scope shares identical subtrees.
    #[test]
    fn deserialization_interns_bottom_up() {
        let _scope = InternScope::new();
        let src = r#"[{"op":"sin","args":[{"op":"+","args":["x",1]}]},
                      {"op":"cos","args":[{"op":"+","args":["x",1]}]}]"#;
        let exprs: Vec<Expr> = serde_json::from_str(src).expect("parses");
        let (Expr::Operator(sin), Expr::Operator(cos)) = (&exprs[0], &exprs[1]) else {
            unreachable!()
        };
        let (Expr::Operator(p), Expr::Operator(q)) = (&sin.args[0], &cos.args[0]) else {
            unreachable!()
        };
        assert!(
            Arc::ptr_eq(p, q),
            "the shared '+' subtree interns to one node"
        );
    }
}
