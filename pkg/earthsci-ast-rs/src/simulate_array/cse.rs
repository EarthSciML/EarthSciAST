//! Common-subexpression elimination for the vectorized whole-array overlay
//! (ess-cse).
//!
//! ## Why
//!
//! A discretization template is expanded at every reference site, so the
//! lowered body of one tendency is enormously redundant. Measured over
//! `simpleclimate.esm` at 12×7×7 (every observed body plus every equation RHS,
//! counting `Expr::Operator` nodes — the metric in which `advx_theta` is
//! 45,791 nodes and `advz_theta` 57,484):
//!
//! ```text
//! operator-node occurrences, all bodies : 482,961
//! distinct structural classes           :   6,814   (1.41%)
//! distinct evaluations, scope-exact CSE :  14,208   (34.0x fewer)
//! ```
//!
//! The vectorized overlay pays ~0.5 µs of fixed per-node overhead (pool
//! check-out, shape/origin bookkeeping, kernel dispatch) on top of ~1 ns per
//! element, so at practical grid sizes the RHS cost is proportional to that
//! node *count*, not to the number of cells. Evaluating each distinct subtree
//! once per scope and letting every other occurrence read the result is
//! therefore the dominant lever. It is the same move the Julia binding made for
//! array observeds — factor a repeated array-valued computation into a
//! per-call buffer instead of inlining it at every reader.
//!
//! ## The equivalence relation (this is the part that must be right)
//!
//! Two occurrences of a structurally identical subtree may share one evaluation
//! only when they evaluate in the **same binding environment**. For the
//! vectorized overlay the environment is exactly the [`VecBox`] in force: the
//! output index symbols and their per-axis `lo`/extent, plus the bound
//! contraction values. So:
//!
//! * **Structural identity** is decided by hash-consing (a `HashMap` on an
//!   exact key, never on a bare hash), over the node's operator, its
//!   non-child attributes, and the *class ids* of its children. Equal class ⇒
//!   syntactically identical subtree.
//! * **Environment identity** is enforced by keying the runtime memo on
//!   `(scope, class)`, where a fresh `scope` is minted at every point the
//!   overlay constructs a new `VecBox`: each `try_eval_arrayop_vectorized`
//!   entry, each contraction tuple in `eval_vec_contracted`, and each region of
//!   `eval_vec_makearray`. Two occurrences under different boxes never share.
//!
//! Every binder in the IR (an `aggregate`/`arrayop` `output_idx` or `ranges`
//! key, an `integral` `var`, a skolem `arg`, a template `bindings` key) either
//! opens a new box on the vectorized path — and therefore a new scope here — or
//! is not evaluated by the overlay at all, in which case [`ClassTable`] refuses
//! to classify the node and no sharing is possible through it. That is why a
//! plain name-based structural key is sound: **inside one scope no symbol is
//! rebound**, so two syntactically identical subtrees denote the same value.
//! The classifier is closed over an explicit allowlist of box-transparent
//! operators; anything else (including any node carrying a `join`, `axes`,
//! `bindings`, `manifold`, … attribute) is left unclassified AND opens a fresh
//! scope for its children, so an unknown construct can only cost the
//! optimization, never correctness.
//!
//! Only classes that actually occur **twice or more within one static scope**
//! are memoized. That keeps the memo small, and it means the root of a scope
//! (multiplicity 1) is never memoized — which matters, because
//! `try_eval_arrayop_vectorized` bails when its top-level result is a
//! `VecValue::View`, and a memo hit is served as a view.
//!
//! ## Storage
//!
//! A memo hit must not cost an array copy: with ~469k hits per RHS call a copy
//! per hit would eat the win. Entries therefore live in boxed slabs whose
//! addresses are stable, and a hit is served as a borrowed
//! [`VecValue::View`] — the same zero-copy shape a state-array read already
//! takes, so every downstream kernel handles it unchanged. See [`CseRt::get`]
//! for the aliasing argument.

use super::*;
use crate::types::{Expr, ExpressionNode};
use rustc_hash::{FxHashMap, FxHashSet};
use std::cell::RefCell;

/// Operators the vectorized overlay evaluates **in the caller's box** — it
/// passes its own `bx` straight down to every operand. A node whose op is on
/// this list keeps its children in the enclosing scope; every other node opens
/// a fresh scope for its children (and stays unclassified), so a construct this
/// module has not been taught about can never leak a sharing decision.
///
/// Kept in lockstep with `eval_vec_op`: `aggregate` and `makearray` are
/// deliberately ABSENT because they rebind the box (`eval_vec_nested_aggregate`
/// re-enters `try_eval_arrayop_vectorized`; `eval_vec_makearray` builds a
/// per-region `rbx`), and everything else in `eval_vec_op` bails.
const BOX_TRANSPARENT_OPS: &[&str] = &[
    "+", "-", "*", "/", "^", "min", "max", "atan2", "and", "or", "neg", "index", "==", "!=", "<",
    "<=", ">", ">=", "ifelse", "exp", "log", "ln", "log10", "sqrt", "abs", "sign", "floor", "ceil",
    "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
    "not", "broadcast",
];

/// `true` when the CSE overlay is switched off by `ESS_CSE_DISABLE=1`. The A/B
/// kill switch for this optimization, mirroring `ESS_VEC_DISABLE` for the
/// vectorizer: with it set, [`CseRt::class_of`] returns `None` everywhere and
/// the evaluator runs exactly as it did before.
pub(super) fn cse_disabled() -> bool {
    use std::sync::OnceLock;
    static OFF: OnceLock<bool> = OnceLock::new();
    *OFF.get_or_init(|| {
        std::env::var("ESS_CSE_DISABLE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false)
    })
}

// ============================================================================
// Structural classification (build time — once per rule body, per scratch).
// ============================================================================

/// An exact hash-cons key. Equality on this key IS syntactic identity of the
/// subtree: `attrs` captures every non-child field that can change the node's
/// meaning, and `kids` holds the already-interned class ids of the children in
/// the fixed traversal order.
#[derive(PartialEq, Eq, Hash)]
enum CseKey {
    Int(i64),
    /// Float literals are keyed by their raw bits so `-0.0` and `0.0` — which
    /// compare equal but are not interchangeable under `1/x` — stay distinct,
    /// and so `NaN` keys are usable at all.
    Num(u64),
    /// Interned variable name (see [`ClassTable::intern_str`]).
    Var(u32),
    Op {
        /// Interned rendering of every non-child attribute (see [`attrs_key`]).
        /// For the overwhelmingly common bare node this is just the operator
        /// name, so classifying one costs a hash lookup and NO allocation —
        /// which matters, because the analysis walks every node of every body.
        attrs: u32,
        kids: SmallVec<[u32; 4]>,
    },
}

/// Per-body structural analysis: which AST nodes are worth memoizing, and under
/// which class id.
#[derive(Default)]
struct ClassTable {
    /// Hash-cons: exact structural key → class id.
    keys: FxHashMap<CseKey, u32>,
    next_class: u32,
    /// String interner for operator names, variable names, and rendered
    /// attribute blobs. Equal ids ⇔ equal strings, so keys stay EXACT.
    strs: FxHashMap<Box<str>, u32>,
    /// Node address → class id, restricted to nodes whose class occurs ≥ 2×
    /// within their own static scope. A node absent here is never memoized.
    memoizable: FxHashMap<usize, u32>,
    /// Body roots already analysed, so the walk runs once per body per scratch.
    analysed_roots: FxHashSet<usize>,
    /// Scratch reused across `analyse` calls: (static scope, class) → count.
    counts: FxHashMap<(u32, u32), u32>,
    /// Scratch reused across `analyse` calls: (address, static scope, class).
    seen: Vec<(usize, u32, u32)>,
    next_static_scope: u32,
}

impl ClassTable {
    /// Analyse one body root, recording every node that is worth memoizing.
    /// Idempotent per root address.
    fn analyse(&mut self, root: &Expr) {
        let key = root as *const Expr as usize;
        if !self.analysed_roots.insert(key) {
            return;
        }
        self.counts.clear();
        self.seen.clear();
        let scope = self.new_static_scope();
        self.walk(root, scope, true);
        // Only a class seen twice or more *inside one static scope* can ever be
        // served from the memo, so only those addresses are recorded.
        for &(addr, scope, class) in &std::mem::take(&mut self.seen) {
            // The body ROOT is deliberately never memoized. A memo hit is served
            // as a `VecValue::View`, and `try_eval_arrayop_vectorized` bails to
            // the per-cell oracle when its top-level result is a view (the oracle
            // scalarizes a bare whole-array body, so returning one would diverge)
            // — so memoizing the root could silently push a rule off the
            // vectorized path. It is a singleton in every real body anyway.
            if addr != key && self.counts.get(&(scope, class)).copied().unwrap_or(0) >= 2 {
                self.memoizable.insert(addr, class);
            }
        }
    }

    fn new_static_scope(&mut self) -> u32 {
        self.next_static_scope += 1;
        self.next_static_scope
    }

    fn intern_str(&mut self, s: &str) -> u32 {
        if let Some(&i) = self.strs.get(s) {
            return i;
        }
        let n = self.strs.len() as u32;
        self.strs.insert(s.into(), n);
        n
    }

    fn intern(&mut self, key: CseKey) -> u32 {
        let next = self.next_class;
        match self.keys.entry(key) {
            std::collections::hash_map::Entry::Occupied(e) => *e.get(),
            std::collections::hash_map::Entry::Vacant(e) => {
                e.insert(next);
                self.next_class += 1;
                next
            }
        }
    }

    /// Assign a class to `e` under static `scope`, recording the occurrence.
    /// Returns `None` for a node this module refuses to classify — an operator
    /// outside [`BOX_TRANSPARENT_OPS`] that is not a recognised box-opener, or
    /// one whose attributes it cannot key exactly. An unclassified node makes
    /// every ancestor unclassified too (their value depends on it).
    ///
    /// `evaluated` says whether `eval_vec` ever reaches this position. A node it
    /// never evaluates still needs a CLASS (it is part of its parent's key) but
    /// never needs a memo entry, so it is left out of the occurrence census.
    /// That is a large saving: an `index` node's axis expressions are *parsed*
    /// (`classify_axis_index`), never evaluated, and they are the majority of
    /// the nodes in a lowered stencil.
    fn walk(&mut self, e: &Expr, scope: u32, evaluated: bool) -> Option<u32> {
        let class = match e {
            Expr::Integer(i) => self.intern(CseKey::Int(*i)),
            Expr::Number(n) => self.intern(CseKey::Num(n.to_bits())),
            Expr::Variable(v) => {
                let id = self.intern_str(v);
                self.intern(CseKey::Var(id))
            }
            Expr::Operator(node) => {
                let transparent = BOX_TRANSPARENT_OPS.contains(&node.op.as_str());
                let opener = matches!(node.op.as_str(), "aggregate" | "arrayop" | "makearray");
                // Children of a box-transparent node stay in this scope; every
                // other node's children go into a fresh one.
                let child_scope = if transparent {
                    scope
                } else {
                    self.new_static_scope()
                };
                let attrs = if transparent || opener {
                    self.attrs_id(node)
                } else {
                    None
                };
                // A node the overlay bails on evaluates none of its children; a
                // nested aggregate underneath is analysed separately when the
                // oracle reaches it through its own `try_eval_arrayop_vectorized`.
                let kids_evaluated = evaluated && (transparent || opener);
                let mut kids: SmallVec<[u32; 4]> = SmallVec::new();
                let mut ok = attrs.is_some();
                if node.op == "index" {
                    // `index(src, ax…)`: only `src` is evaluated; the axis
                    // expressions are classified for the key alone. (An `index`
                    // node carries no sidecar children, so iterating `args`
                    // covers the whole `for_each_child` set.)
                    for (i, c) in node.args.iter().enumerate() {
                        match self.walk(c, child_scope, kids_evaluated && i == 0) {
                            Some(k) => kids.push(k),
                            None => ok = false,
                        }
                    }
                } else {
                    node.for_each_child(&mut |c| {
                        // `for_each_child` visits `axes`/`bindings` maps in
                        // sorted key order, but `attrs_key` refuses any node
                        // carrying them, so such a node is already unclassified.
                        match self.walk(c, child_scope, kids_evaluated) {
                            Some(k) => kids.push(k),
                            None => ok = false,
                        }
                    });
                }
                if !ok {
                    return None;
                }
                self.intern(CseKey::Op {
                    attrs: attrs.expect("checked above"),
                    kids,
                })
            }
        };
        if evaluated {
            let addr = e as *const Expr as usize;
            *self.counts.entry((scope, class)).or_insert(0) += 1;
            self.seen.push((addr, scope, class));
        }
        Some(class)
    }
}

/// An exact, order-deterministic rendering of every NON-child field of `node`
/// that can change what it computes, interned to a `u32`. `None` means "this
/// node carries a field this module does not key" — the caller then leaves it
/// unclassified.
///
/// `args`/`lower`/`upper`/`expr`/`filter`/`values` are children (handled by
/// class id) and so are absent here. `axes`/`key`/`bindings` are also children
/// but live in `HashMap`s / template machinery the overlay never evaluates, so
/// their presence is rejected outright rather than keyed.
///
/// The bare case — a node with the operator and its operands and nothing else,
/// which is essentially all of a lowered stencil — interns the operator name
/// directly and allocates nothing. A rendered blob always contains `|`, which
/// an operator name never does, so the two families cannot collide.
impl ClassTable {
    fn attrs_id(&mut self, node: &ExpressionNode) -> Option<u32> {
        let rendered = attrs_key(node)?;
        Some(match rendered {
            Rendered::Bare => self.intern_str(&node.op),
            Rendered::Blob(s) => self.intern_str(&s),
        })
    }
}

/// Either "nothing but the operator name" or a fully rendered attribute blob.
enum Rendered {
    Bare,
    Blob(String),
}

fn attrs_key(node: &ExpressionNode) -> Option<Rendered> {
    // Fields whose presence means "not a construct this module keys".
    if node.join.is_some()
        || node.axes.is_some()
        || node.bindings.is_some()
        || node.key.is_some()
        || node.table.is_some()
        || node.output.is_some()
        || node.manifold.is_some()
        || node.arg.is_some()
        || node.int_var.is_some()
    {
        return None;
    }
    // The common case by a wide margin: a bare arithmetic / index / ifelse node
    // with no sidecar attribute at all.
    let bare = node.wrt.is_none()
        && node.dim.is_none()
        && node.output_idx.is_none()
        && node.ranges.is_none()
        && node.reduce.is_none()
        && node.semiring.is_none()
        && node.regions.is_none()
        && node.shape.is_none()
        && node.perm.is_none()
        && node.axis.is_none()
        && node.broadcast_fn.is_none()
        && node.name.is_none()
        && node.label.is_none()
        && node.value.is_none()
        && node.id.is_none();
    if bare {
        return Some(Rendered::Bare);
    }
    let mut s = String::with_capacity(node.op.len() + 64);
    s.push_str(&node.op);
    use std::fmt::Write as _;
    let _ = write!(
        s,
        "|w={:?}|d={:?}|oi={:?}|rd={:?}|sr={:?}|rg={:?}|sh={:?}|pm={:?}|ax={:?}|bf={:?}|nm={:?}|lb={:?}|id={:?}",
        node.wrt,
        node.dim,
        node.output_idx,
        node.reduce,
        node.semiring,
        node.regions,
        node.shape,
        node.perm,
        node.axis,
        node.broadcast_fn,
        node.name,
        node.label,
        node.id,
    );
    // `ranges` is a `HashMap`, so it must be rendered in a deterministic order.
    if let Some(r) = &node.ranges {
        let mut ks: Vec<&String> = r.keys().collect();
        ks.sort_unstable();
        s.push_str("|rn=");
        for k in ks {
            let spec = serde_json::to_string(&r[k]).ok()?;
            let _ = write!(s, "{k}={spec};");
        }
    }
    // A `const`'s payload IS its value.
    if let Some(v) = &node.value {
        s.push_str("|v=");
        s.push_str(&serde_json::to_string(v).ok()?);
    }
    Some(Rendered::Blob(s))
}

// ============================================================================
// Runtime memo.
// ============================================================================

/// One memoized array, boxed so its address is stable while the backing `Vec`
/// of slabs grows.
struct Slab {
    data: ArrayD<f64>,
    origin: DimI,
}

impl Slab {
    /// A placeholder that owns no buffer (`Vec::new()` does not allocate), used
    /// when a slab's array has been handed back to the pool.
    fn empty() -> Slab {
        Slab {
            data: ArrayD::from_shape_vec(IxDyn(&[0]), Vec::new()).expect("0-length array"),
            origin: DimI::new(),
        }
    }
}

enum Slot {
    Scalar(f64),
    Arr(usize),
}

#[derive(Default)]
struct Inner {
    classes: ClassTable,
    /// Live memo for the CURRENT top-level evaluation: (scope, class) → slot.
    memo: FxHashMap<(u32, u32), Slot>,
    slabs: Vec<Box<Slab>>,
    /// Number of `slabs` entries holding live values this evaluation. Slabs at
    /// or above this index are free for reuse.
    used: usize,
    /// Nesting depth of `enter_scope`. Zero means no vectorized evaluation is
    /// in flight, which is the only point at which the memo may be recycled.
    depth: u32,
    next_scope: u32,
    scope: u32,
    scope_stack: SmallVec<[u32; 8]>,
}

/// Per-`RhsScratch` CSE state: the structural class table (built once per body)
/// and the per-evaluation memo. Interior-mutable for the same reason
/// [`RhsScratch`] is: the evaluator holds it through a shared `EvalCtx` borrow.
#[derive(Default)]
pub(super) struct CseRt {
    inner: RefCell<Inner>,
}

impl CseRt {
    /// Analyse a rule body so its repeated subtrees become memoizable. Cheap to
    /// call repeatedly: the walk runs once per distinct body root.
    ///
    /// SOUNDNESS: the table is keyed by AST node ADDRESS, so a `CseRt` is only
    /// valid for the rule set whose bodies it analysed. That holds by
    /// construction — a `CseRt` lives inside a [`RhsScratch`], which is already
    /// model-specific (it is sized to one model's variable shapes) and is
    /// co-owned with the cloned rule bodies by the RHS closure, so the analysed
    /// trees outlive it.
    pub(super) fn analyse(&self, body: &Expr) {
        if cse_disabled() {
            return;
        }
        self.inner.borrow_mut().classes.analyse(body);
    }

    /// Open a fresh evaluation scope (a new [`VecBox`]) for as long as the
    /// returned guard lives. A guard is used rather than a paired
    /// `enter`/`exit` because the overlay's bail paths (`bail_vec!`, `?`)
    /// return early from every one of the call sites; `Drop` closes the scope
    /// on those paths too, which a manual pair would not.
    pub(super) fn scope(&self, pool: &mut Pool) -> CseScope<'_> {
        self.enter_scope(pool);
        CseScope { rt: self }
    }

    /// Open a fresh evaluation scope (a new [`VecBox`]). At the outermost entry
    /// the previous evaluation's memo is recycled into `pool`.
    fn enter_scope(&self, pool: &mut Pool) -> u32 {
        let mut i = self.inner.borrow_mut();
        if i.depth == 0 {
            // SOUNDNESS: recycling here is safe precisely because `depth == 0`
            // means no vectorized evaluation is in flight, and every caller of
            // `try_eval_arrayop_vectorized` consumes its result (copies the view
            // into an owned array, or scatters it into `dy`) before returning —
            // so no `VecValue` borrowing a slab can still be alive.
            i.memo.clear();
            for idx in 0..i.used {
                let old = std::mem::replace(&mut *i.slabs[idx], Slab::empty());
                pool.give_array(old.data);
            }
            i.used = 0;
            i.next_scope = 0;
            i.scope_stack.clear();
            i.scope = 0;
        }
        i.depth += 1;
        i.next_scope += 1;
        let s = i.next_scope;
        let prev = i.scope;
        i.scope_stack.push(prev);
        i.scope = s;
        s
    }

    /// Close the scope opened by the matching [`Self::scope`].
    fn exit_scope(&self) {
        let mut i = self.inner.borrow_mut();
        i.scope = i.scope_stack.pop().unwrap_or(0);
        i.depth = i.depth.saturating_sub(1);
    }

    /// The class id of `expr` if it is worth memoizing here, else `None`.
    pub(super) fn class_of(&self, expr: &Expr) -> Option<u32> {
        if cse_disabled() {
            return None;
        }
        let i = self.inner.borrow();
        if i.depth == 0 {
            return None;
        }
        i.classes
            .memoizable
            .get(&(expr as *const Expr as usize))
            .copied()
    }

    /// Serve a memoized value for `class` in the current scope.
    ///
    /// SAFETY of the borrow extension: the array lives in a `Box<Slab>` whose
    /// address does not move when `slabs` grows, and slabs below `used` are
    /// never written again for the duration of the evaluation — [`Self::put`]
    /// only ever writes slabs at index `>= used`, and recycling only happens in
    /// [`Self::enter_scope`] at `depth == 0`, where no value can still be alive.
    /// So the reference is valid for as long as the caller can observe it.
    pub(super) fn get<'a>(&'a self, class: u32) -> Option<VecValue<'a>> {
        let i = self.inner.borrow();
        match i.memo.get(&(i.scope, class))? {
            Slot::Scalar(s) => Some(VecValue::Scalar(*s)),
            Slot::Arr(idx) => {
                let slab: &Slab = &i.slabs[*idx];
                let origin = slab.origin.clone();
                let ptr: *const ArrayD<f64> = &slab.data;
                Some(VecValue::View {
                    data: unsafe { &*ptr },
                    origin,
                })
            }
        }
    }

    /// Record `v` for `class` in the current scope and return the value the
    /// caller should propagate. An `Owned` array is MOVED into a slab and
    /// served back as a borrowed view (so the memo owns exactly one copy); a
    /// scalar is stored by value; a `View` is passed through unmemoized,
    /// because it is already a zero-cost borrow of a persistent array.
    pub(super) fn put<'a>(&'a self, class: u32, v: VecValue<'a>) -> VecValue<'a> {
        match v {
            VecValue::Scalar(s) => {
                let mut i = self.inner.borrow_mut();
                let scope = i.scope;
                i.memo.insert((scope, class), Slot::Scalar(s));
                VecValue::Scalar(s)
            }
            VecValue::View { data, origin } => VecValue::View { data, origin },
            VecValue::Owned { data, origin } => {
                let mut i = self.inner.borrow_mut();
                let idx = i.used;
                if idx == i.slabs.len() {
                    i.slabs.push(Box::new(Slab::empty()));
                }
                let out_origin = origin.clone();
                *i.slabs[idx] = Slab { data, origin };
                i.used += 1;
                let scope = i.scope;
                i.memo.insert((scope, class), Slot::Arr(idx));
                let ptr: *const ArrayD<f64> = &i.slabs[idx].data;
                // SAFETY: see `get` — the slab is boxed, is below `used` from
                // here on, and is not recycled while this evaluation is live.
                VecValue::View {
                    data: unsafe { &*ptr },
                    origin: out_origin,
                }
            }
        }
    }

    /// Number of distinct evaluations memoized during the last top-level
    /// evaluation (diagnostics only).
    #[cfg(test)]
    pub(super) fn memo_len(&self) -> usize {
        self.inner.borrow().memo.len()
    }
}

/// RAII scope handle: closes the evaluation scope on every exit path, including
/// the overlay's early `None` bails.
pub(super) struct CseScope<'r> {
    rt: &'r CseRt,
}

impl Drop for CseScope<'_> {
    fn drop(&mut self) {
        self.rt.exit_scope();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::ExpressionNode;

    fn op(name: &str, args: Vec<Expr>) -> Expr {
        Expr::Operator(ExpressionNode {
            op: name.to_string(),
            args,
            ..Default::default()
        })
    }

    /// Two syntactically identical siblings in one scope are one class and are
    /// marked memoizable; a singleton is not.
    #[test]
    fn repeated_sibling_is_memoizable_singleton_is_not() {
        // (a - b) * (a - b) + c
        let dup = || op("-", vec![Expr::Variable("a".into()), Expr::Variable("b".into())]);
        let body = op(
            "+",
            vec![op("*", vec![dup(), dup()]), Expr::Variable("c".into())],
        );
        let mut t = ClassTable::default();
        t.analyse(&body);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        let Expr::Operator(mul) = &root.args[0] else {
            unreachable!()
        };
        let l = &mul.args[0] as *const Expr as usize;
        let r = &mul.args[1] as *const Expr as usize;
        assert_eq!(
            t.memoizable.get(&l).copied(),
            t.memoizable.get(&r).copied(),
            "identical siblings must share a class"
        );
        assert!(t.memoizable.contains_key(&l), "the repeat is memoizable");
        let root_addr = &body as *const Expr as usize;
        assert!(
            !t.memoizable.contains_key(&root_addr),
            "a singleton (the root) must not be memoized"
        );
    }

    /// A repeat that straddles an `aggregate` boundary is NOT shared: the two
    /// occurrences evaluate under different boxes.
    #[test]
    fn repeat_across_a_binder_is_not_shared() {
        let inner = op("-", vec![Expr::Variable("a".into()), Expr::Variable("b".into())]);
        let agg = Expr::Operator(ExpressionNode {
            op: "aggregate".to_string(),
            args: vec![],
            output_idx: Some(vec!["i".to_string()]),
            expr: Some(Box::new(inner)),
            ..Default::default()
        });
        let outer = op("-", vec![Expr::Variable("a".into()), Expr::Variable("b".into())]);
        let body = op("+", vec![agg, outer]);
        let mut t = ClassTable::default();
        t.analyse(&body);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        let Expr::Operator(agg_n) = &root.args[0] else {
            unreachable!()
        };
        let inner_addr = agg_n.expr.as_deref().expect("body") as *const Expr as usize;
        let outer_addr = &root.args[1] as *const Expr as usize;
        assert!(
            !t.memoizable.contains_key(&inner_addr) && !t.memoizable.contains_key(&outer_addr),
            "occurrences in different scopes must not be marked shareable"
        );
    }

    /// An operator the overlay does not evaluate in the caller's box leaves its
    /// subtree unclassified, and its presence does not make its PARENT
    /// shareable either.
    #[test]
    fn unknown_operator_blocks_classification() {
        let weird = || {
            Expr::Operator(ExpressionNode {
                op: "reshape".to_string(),
                args: vec![Expr::Variable("a".into())],
                shape: Some(vec![2, 2]),
                ..Default::default()
            })
        };
        let body = op("+", vec![weird(), weird()]);
        let mut t = ClassTable::default();
        t.analyse(&body);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        for i in 0..2 {
            let a = &root.args[i] as *const Expr as usize;
            assert!(!t.memoizable.contains_key(&a), "unknown op stays unshared");
        }
    }

    /// `0.0` and `-0.0` are distinct classes: they compare equal but are not
    /// interchangeable (`1/0.0` vs `1/-0.0`).
    #[test]
    fn signed_zero_literals_are_distinct_classes() {
        let mut t = ClassTable::default();
        let a = t.intern(CseKey::Num(0.0f64.to_bits()));
        let b = t.intern(CseKey::Num((-0.0f64).to_bits()));
        assert_ne!(a, b);
    }
}
