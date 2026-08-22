//! Load-scoped structural interning (hash-consing) of [`ExpressionNode`]s.
//!
//! ## Why
//!
//! A §9.7-expanded discretization repeats the same subtrees relentlessly:
//! measured on `simpleclimate.esm` at the production grid, the typed model
//! holds 1.21M expression-node occurrences but only 6,961 structurally
//! distinct subtrees (0.58%). With an inline `ExpressionNode` payload every
//! occurrence was a full ~832-byte copy — ~978 MiB of typed AST, the dominant
//! load-phase allocation. [`Expr::Operator`] now carries
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
//! * a node carrying a field this module does not key **exactly** —
//!   `value` / `output` (arbitrary `serde_json::Value` payloads) or `join`
//!   (clauses with float `eps`) — is refused outright ([`internable`]) and
//!   allocated fresh, so an unkeyed attribute can never cause two different
//!   nodes to merge.
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
use rustc_hash::FxHashSet;
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
    set: FxHashSet<Key>,
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
        let key = Key(Arc::new(node));
        match interner.set.get(&key) {
            Some(canon) => Arc::clone(&canon.0),
            None => {
                let out = Arc::clone(&key.0);
                interner.set.insert(key);
                out
            }
        }
    })
}

/// Whether this module can key `node` exactly. `value` / `output` carry
/// arbitrary `serde_json::Value` payloads and `join` carries float-bearing
/// clause structs; rather than invent a keying for those rare fields, a node
/// carrying one is simply never shared.
fn internable(node: &ExpressionNode) -> bool {
    node.value.is_none() && node.output.is_none() && node.join.is_none()
}

/// Interning key: an owned canonical candidate with structural hash/equality.
struct Key(Arc<ExpressionNode>);

impl PartialEq for Key {
    fn eq(&self, other: &Self) -> bool {
        node_eq(&self.0, &other.0)
    }
}
impl Eq for Key {}

impl Hash for Key {
    fn hash<H: Hasher>(&self, h: &mut H) {
        node_hash(&self.0, h);
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
        label,
        value,
        table,
        axes,
        output,
        id,
        manifold,
        bindings,
        arg,
        distinct,
        key,
    } = a;
    // `internable` refused these; assert the contract rather than compare.
    debug_assert!(value.is_none() && output.is_none() && join.is_none());
    debug_assert!(b.value.is_none() && b.output.is_none() && b.join.is_none());
    op == &b.op
        && child_vec_eq(args, &b.args)
        && wrt == &b.wrt
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
        && label == &b.label
        && table == &b.table
        && child_map_eq(axes, &b.axes)
        && id == &b.id
        && manifold == &b.manifold
        && child_map_eq(bindings, &b.bindings)
        && arg == &b.arg
        && distinct == &b.distinct
        && opt_child_eq(key, &b.key)
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
        label,
        value: _,
        table,
        axes,
        output: _,
        id,
        manifold,
        bindings,
        arg,
        distinct,
        key,
    } = n;
    op.hash(h);
    args.len().hash(h);
    for a in args {
        child_hash(a, h);
    }
    wrt.hash(h);
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
    label.hash(h);
    table.hash(h);
    child_map_hash(axes, h);
    id.hash(h);
    manifold.hash(h);
    child_map_hash(bindings, h);
    arg.hash(h);
    distinct.hash(h);
    opt_child_hash(key, h);
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
            let mut n = op("aggregate", vec![]);
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
            let mut n = op("aggregate", vec![]);
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

    /// Nodes carrying fields this module refuses to key (`value` / `output` /
    /// `join`) are never shared, even when byte-identical.
    #[test]
    fn unkeyed_fields_refuse_interning() {
        let _scope = InternScope::new();
        let mk = || {
            let mut n = op("const", vec![]);
            n.value = Some(serde_json::json!([1.0, 2.0]));
            Expr::operator(n)
        };
        let (a, b) = (mk(), mk());
        let (Expr::Operator(x), Expr::Operator(y)) = (&a, &b) else {
            unreachable!()
        };
        assert!(!Arc::ptr_eq(x, y), "value-bearing nodes are never merged");
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
