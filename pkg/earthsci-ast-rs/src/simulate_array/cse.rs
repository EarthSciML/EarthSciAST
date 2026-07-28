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
//! Outcome on that model, RHS wall time at u0, bit-identical throughout:
//!
//! ```text
//!                        12x7x7      24x13x13    ratio (6.9x the cells)
//!   before (ef51292c)    0.3332 s    0.7303 s    2.19x
//!   after                0.0136 s    0.0479 s    3.52x
//! ```
//!
//! The ratio moving toward the cell ratio is the point: what was removed is the
//! FIXED per-node component, so what is left is closer to real per-element work.
//! A 0.25-day solve of `simpleclimate.esm` goes 360.2 s -> 60.1 s (the Julia
//! reference for the same run is 92 s).
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
//! takes, so every downstream kernel handles it unchanged. See
//! [`CseRt::slab_view`] for the aliasing argument.
//!
//! ## Hoisting the CONST subexpressions out of the RHS entirely (ess-lih)
//!
//! The memo above is discarded at every top-level evaluation, so a subtree that
//! is *the same on every RHS call of the whole solve* is still recomputed 3,926
//! times in a 0.25-day `simpleclimate` run. The driver already hoists such work
//! at WHOLE-OBSERVED granularity (`classify_static_observeds` — a rule whose
//! transitive references reach neither state nor `t` is materialized once at
//! setup). What that cannot reach is the invariant *subexpression* buried inside
//! a rule that is otherwise state-dependent: `T_eq`'s `sin(φ)²`/`cos(φ)²`
//! survive as a whole-observed candidate only if the entire Held–Suarez
//! equilibrium temperature is state-free, which it is not.
//!
//! So the same idea is applied one level down. A node is **box-pure** when every
//! variable leaf beneath it is either
//!
//! * an index symbol bound by the [`VecBox`] in force — [`eval_vec_variable`]
//!   resolves those from `bx.cvals` or as a coordinate RAMP over `bx.lo` /
//!   `bx.shape`, all of which the box signature captures — or
//! * a CONST-tier name: a hoisted static observed (retained in place by
//!   [`RhsScratch`] for its whole lifetime) or an unshadowed scalar parameter.
//!
//! Such a subtree reads no state, no `t`, no varying observed and no forcing, so
//! its value is a pure function of `(structural class, box signature)` — which
//! is exactly the key of the persistent store ([`Inner::pmemo`]). Only MAXIMAL
//! box-pure nodes get an entry: a pure node under a pure parent is never
//! reached, because the parent's hit short-circuits it.
//!
//! The mark rides IN the class id ([`PURE_BIT`]): `memoizable` and the resolved
//! [`AddrClasses`] store `class | PURE_BIT` for a hoistable node, so the hot
//! path still pays a SINGLE probe and [`CseRt::get`]/[`CseRt::put`] dispatch on
//! the bit. A `PURE_BIT` id deliberately never reaches the dense per-scope memo
//! rows (which are indexed by class), so the bit cannot inflate them.
//!
//! ### Invalidation
//!
//! A stale hoisted value is the failure mode here, and it is quiet: the first
//! call is right, so nothing looks wrong. The store is therefore dropped
//! whenever anything it can be derived from is replaced —
//!
//! * the rule set ([`CseRt::retarget`]: class ids are reassigned by a fresh
//!   [`ClassTable`], so a surviving entry would answer for a different subtree),
//! * the hoisted static observeds ([`RhsScratch::set_static`] →
//!   [`CseRt::invalidate_consts`]), and
//! * the parameter vector ([`CseRt::bind_params`]).
//!
//! On the `simulate` path the first two cannot change within one store's life
//! anyway: the driver builds a fresh `RhsScratch` per integration segment, which
//! is the same cadence at which the CONST/DISCRETE observeds are themselves
//! re-materialized. The parameter guard exists for `debug_eval_rhs_into`, whose
//! caller owns the scratch and may legitimately sweep parameters through it.
//! `tests/pde_const_hoist.rs` pins both properties; removing `bind_params` makes
//! it fail.
//!
//! ## Lookup
//!
//! Both of the overlay's per-node questions — "is this node memoizable, and
//! under what class?" and "is that class already evaluated in this scope?" —
//! are asked once per node VISIT, ~483k times per RHS call and ~1.9e9 times
//! over a 0.25-day solve of `simpleclimate.esm`. Asking them of a `HashMap` put
//! the answer behind a hash and two cache misses, which measured at 8.6% of the
//! solve (7.1% of it in `class_of` alone) — a third of what the overlay had left
//! per node visit.
//!
//! Neither question needs a hash, because both key spaces are fixed once the
//! analysis has run:
//!
//! * node → class is fixed for a rule set (that is exactly what
//!   [`CseRt::retarget`] guarantees), so it is resolved, at [`CseRt::analyse`]
//!   time, into [`AddrClasses`] — a flat open-addressed table keyed by a 32-bit
//!   node ordinal, one cache line per probe.
//! * class ids are DENSE (6,734 of them here against 662k classified nodes), so
//!   the memo is a dense row of class-indexed cells per open scope, stamped with
//!   the scope that wrote it. See [`Inner::memo`].
//!
//! Both structures are exact re-encodings, not approximations: they answer what
//! the maps answered, and `ESS_CSE_PARANOID=1` asserts that node-visit by
//! node-visit over a whole solve.

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
pub(super) const BOX_TRANSPARENT_OPS: &[&str] = &[
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

/// `true` when `ESS_CSE_PARANOID=1` asks [`CseRt::class_of`] to cross-check the
/// resolved class table against the map on every node visit.
fn cse_paranoid() -> bool {
    use std::sync::OnceLock;
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| {
        std::env::var("ESS_CSE_PARANOID")
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

/// Flag bit OR-ed into a class id in [`ClassTable::memoizable`] (and therefore
/// into [`AddrClasses`]' value word) to mark a **box-pure** node (ess-lih): one
/// whose value is a pure function of its structural class and the [`VecBox`] in
/// force, served from the PERSISTENT store (which survives across RHS calls)
/// rather than the per-evaluation memo. Class ids are dense from 0 and a
/// lowered model reaches at most tens of thousands, so bit 31 is free;
/// [`ClassTable::intern`] asserts it. A `PURE_BIT`-carrying id must never index
/// the dense memo rows — [`CseRt::get`]/[`CseRt::put`] strip-and-dispatch on it
/// before any row access, and [`CseRt::store`] refuses it outright.
const PURE_BIT: u32 = 1 << 31;

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
    ///
    /// This is the AUTHORITATIVE classification, but it is not what the hot
    /// path reads: [`CseRt::class_of`] probes [`AddrClasses`], which is this map
    /// resolved into a flat array. The map stays as the source those
    /// resolutions are built from and as the fallback when they are impossible.
    memoizable: FxHashMap<usize, u32>,
    /// Entries added to `memoizable` since the last drain, so [`CseRt::analyse`]
    /// can extend the resolved table incrementally instead of rebuilding it once
    /// per body (113 bodies for `simpleclimate.esm`, 662k entries).
    pending: Vec<(usize, u32)>,
    /// Body roots already analysed, so the walk runs once per body per scratch.
    analysed_roots: FxHashSet<usize>,
    /// Scratch reused across `analyse` calls: (static scope, class) → count.
    counts: FxHashMap<(u32, u32), u32>,
    /// Scratch reused across `analyse` calls: (address, static scope, class).
    seen: Vec<(usize, u32, u32)>,
    /// Scratch reused across `analyse` calls: the MAXIMAL box-pure nodes found
    /// by the current walk, as (address, class). "Maximal" because a pure node
    /// whose parent is also pure is never reached at runtime (the parent's memo
    /// hit short-circuits it), so [`Self::walk`] drops a child's entry as soon
    /// as its parent turns out pure too.
    pure_cand: FxHashMap<usize, u32>,
    next_static_scope: u32,
}

impl ClassTable {
    /// Analyse one body root, recording every node that is worth memoizing.
    /// Idempotent per root address.
    ///
    /// `idx_binders` / `c_binders` are the index symbols the caller's
    /// [`VecBox`] binds (`output_idx_names` and `contract_names`), and
    /// `consts` / `const_arrays` the CONST-tier leaf names (see
    /// [`CseRt::set_const_names`]). Together they drive the box-pure analysis —
    /// see [`Self::walk`].
    fn analyse(
        &mut self,
        root: &Expr,
        idx_binders: &[String],
        c_binders: &[String],
        consts: &FxHashSet<String>,
        const_arrays: &FxHashSet<String>,
    ) {
        let key = root as *const Expr as usize;
        if !self.analysed_roots.insert(key) {
            return;
        }
        self.counts.clear();
        self.seen.clear();
        self.pure_cand.clear();
        let scope = self.new_static_scope();
        let binders = Binders {
            idx: idx_binders,
            c: c_binders,
            consts,
            const_arrays,
        };
        self.walk(root, scope, true, Some(&binders));
        // Only a class seen twice or more *inside one static scope* can ever be
        // served from the memo, so only those addresses are recorded.
        for &(addr, scope, class) in &std::mem::take(&mut self.seen) {
            // The body ROOT is deliberately never memoized. A memo hit is served
            // as a `VecValue::View`, and `try_eval_arrayop_vectorized` bails to
            // the per-cell oracle when its top-level result is a view (the oracle
            // scalarizes a bare whole-array body, so returning one would diverge)
            // — so memoizing the root could silently push a rule off the
            // vectorized path. It is a singleton in every real body anyway.
            if addr != key
                && self.counts.get(&(scope, class)).copied().unwrap_or(0) >= 2
                // An address can be RE-classified: the trees handed to
                // `analyse` are not all long-lived (a lowered aggregate body is
                // rebuilt per call on the `eval_arrayop` path), so a later root
                // can occupy storage an earlier one was analysed in. The map
                // resolves that by last-writer-wins — the live tree is always
                // the one that wrote last — so `pending` must carry an update,
                // not just a first insert, or the resolved table goes stale
                // against it.
                && self.memoizable.insert(addr, class) != Some(class)
            {
                self.pending.push((addr, class));
            }
        }
        // Box-pure wins over the per-evaluation memo wherever both apply: it is
        // the same value, kept for the whole solve instead of one evaluation.
        // Runs AFTER the base loop so the `PURE_BIT` id is the last writer in
        // both the map and (via `pending`) the resolved table. Same root
        // exclusion, same reason; same re-classification contract, so an update
        // is pushed to `pending`, not just a first insert.
        for (addr, class) in std::mem::take(&mut self.pure_cand) {
            if addr != key && self.memoizable.insert(addr, class | PURE_BIT) != Some(class | PURE_BIT)
            {
                self.pending.push((addr, class | PURE_BIT));
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
                // `PURE_BIT` is stolen from the top of the class id, so the id
                // space must stay below it. A lowered model reaches ~10^4
                // classes; 2^31 is not approachable in practice.
                assert!(next < PURE_BIT, "CSE class id space exhausted");
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
    ///
    /// `binders` drives the **box-pure** analysis (ess-lih) reported in
    /// `Walked::pure`. A node is box-pure when every variable leaf beneath it is
    /// either
    ///
    /// * an index symbol the enclosing [`VecBox`] binds — [`eval_vec_variable`]
    ///   resolves those from `bx.cvals` (a bound contraction value) or as a
    ///   coordinate RAMP over `bx.lo` / `bx.shape`, all of which the box
    ///   signature captures exactly — or
    /// * a CONST-tier name (see [`Binders::consts`]): a hoisted static observed
    ///   or an unshadowed scalar parameter, both fixed for the whole lifetime of
    ///   the owning [`RhsScratch`].
    ///
    /// Such a subtree reads NO state, NO `t`, NO *varying* observed and NO
    /// forcing, so its value is a pure function of (class, box) — constant for
    /// the whole solve, which is what licenses caching it across RHS calls.
    ///
    /// `binders = None` means "no box symbol is in scope here", which makes the
    /// whole subtree non-pure. That is the conservative treatment given to every
    /// binder-introducing operator (`aggregate`/`arrayop`/`makearray`): those
    /// re-enter the overlay under a DIFFERENT box, whose symbols this walk does
    /// not know, so nothing beneath them is ever cached.
    fn walk(
        &mut self,
        e: &Expr,
        scope: u32,
        evaluated: bool,
        binders: Option<&Binders<'_>>,
    ) -> Walked {
        // Accumulated over the children: box-purity, and whether the subtree
        // touches anything ARRAY-valued (a subtree of bare literals or scalar
        // CONSTs folds to a scalar, so caching it would cost a hash probe and
        // save nothing).
        let mut pure = true;
        let mut uses_idx = false;
        let class = match e {
            Expr::Integer(i) => self.intern(CseKey::Int(*i)),
            Expr::Number(n) => self.intern(CseKey::Num(n.to_bits())),
            Expr::Variable(v) => {
                // `t` is resolved by `eval_vec_variable` BEFORE the box symbols,
                // so a model that named an index `t` would not get a ramp here.
                match binders {
                    Some(b) if v != "t" && b.is_idx(v) => uses_idx = true,
                    // A CONST leaf keeps the subtree pure; whether it makes the
                    // subtree worth a memo slot depends on it being an ARRAY.
                    Some(b) if v != "t" && b.is_const(v) => {
                        uses_idx |= b.const_arrays.contains(v);
                    }
                    _ => {
                        pure = false;
                    }
                }
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
                // Only a box-TRANSPARENT node keeps its children under this box,
                // so only there does the caller's binder set still describe them.
                // Every other node — `aggregate`/`arrayop`/`makearray`, or a
                // construct the overlay bails on — evaluates its children under a
                // DIFFERENT box whose symbols this walk does not know, so nothing
                // beneath one is ever treated as pure. A nested aggregate
                // re-enters `try_eval_arrayop_vectorized`, which analyses its own
                // body against its own binders, so nothing is permanently lost.
                let child_binders = if transparent { binders } else { None };
                let mut kids: SmallVec<[u32; 4]> = SmallVec::new();
                let mut ok = attrs.is_some();
                // Addresses of the direct children, so a pure parent can drop
                // their (now unreachable) pure entries — see `pure_cand`.
                let mut kid_addrs: SmallVec<[usize; 4]> = SmallVec::new();
                // An operator can only be box-pure if the overlay evaluates it in
                // the caller's box AND this module keys its attributes exactly.
                pure = transparent && attrs.is_some();
                if node.op == "index" {
                    // `index(src, ax…)`: only `src` is evaluated; the axis
                    // expressions are classified for the key alone. (An `index`
                    // node carries no sidecar children, so iterating `args`
                    // covers the whole `for_each_child` set.) The axes still
                    // decide WHICH elements are gathered, so their purity counts
                    // towards the node's.
                    for (i, c) in node.args.iter().enumerate() {
                        let w = self.walk(c, child_scope, kids_evaluated && i == 0, child_binders);
                        kid_addrs.push(c as *const Expr as usize);
                        pure &= w.pure;
                        uses_idx |= w.uses_idx;
                        match w.class {
                            Some(k) => kids.push(k),
                            None => ok = false,
                        }
                    }
                } else {
                    node.for_each_child(&mut |c| {
                        // `for_each_child` visits `axes`/`bindings` maps in
                        // sorted key order, but `attrs_key` refuses any node
                        // carrying them, so such a node is already unclassified.
                        let w = self.walk(c, child_scope, kids_evaluated, child_binders);
                        kid_addrs.push(c as *const Expr as usize);
                        pure &= w.pure;
                        uses_idx |= w.uses_idx;
                        match w.class {
                            Some(k) => kids.push(k),
                            None => ok = false,
                        }
                    });
                }
                if !ok {
                    return Walked::unclassified();
                }
                if pure {
                    // This node subsumes its children: a persistent hit here
                    // never descends, so their entries would never be reached.
                    for a in &kid_addrs {
                        self.pure_cand.remove(a);
                    }
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
            if pure && uses_idx {
                self.pure_cand.insert(addr, class);
            }
        }
        Walked {
            class: Some(class),
            pure,
            uses_idx,
        }
    }
}

/// The leaf names a box-pure subtree may read: the index symbols the enclosing
/// [`VecBox`] binds, and the CONST-tier names. Membership in `idx`/`c` is
/// exactly the condition under which [`eval_vec_variable`] resolves a bare
/// symbol from the BOX rather than from state / observeds / parameters /
/// forcing.
struct Binders<'a> {
    idx: &'a [String],
    c: &'a [String],
    /// CONST-tier names: the already-hoisted static observeds plus the
    /// unshadowed scalar parameters (see [`CseRt::set_const_names`]). Both are
    /// fixed for the whole lifetime of the owning [`RhsScratch`], so a leaf that
    /// resolves to one is as good as a literal for this analysis. Unlike an
    /// index symbol they do NOT vary with the box, but including them in the key
    /// is unnecessary for the same reason: they are the same value under every
    /// box, and the box signature already separates everything that is not.
    consts: &'a FxHashSet<String>,
    /// The subset of `consts` that is ARRAY-valued. A pure subtree built only
    /// from scalar CONSTs folds to a scalar, which is not worth a memo slot; one
    /// that touches a box ramp or a CONST array is a whole-array computation,
    /// which is.
    const_arrays: &'a FxHashSet<String>,
}

impl Binders<'_> {
    /// A leaf that resolves from the BOX (an index ramp or a bound contraction
    /// value), so its value varies with the box signature.
    fn is_idx(&self, name: &str) -> bool {
        self.idx.iter().any(|s| s == name) || self.c.iter().any(|s| s == name)
    }

    /// A leaf whose value is fixed for the whole solve — either box-bound or
    /// CONST-tier.
    fn is_const(&self, name: &str) -> bool {
        self.is_idx(name) || self.consts.contains(name)
    }
}

/// What [`ClassTable::walk`] learned about one node.
#[derive(Clone, Copy)]
struct Walked {
    /// Structural class, or `None` for a node this module refuses to classify.
    class: Option<u32>,
    /// Box-pure: value determined entirely by the class and the box in force.
    pure: bool,
    /// The subtree touches something ARRAY-valued (a box index ramp or a CONST
    /// array), so its value is a whole array worth a memo slot rather than a
    /// folded scalar.
    uses_idx: bool,
}

impl Walked {
    fn unclassified() -> Walked {
        Walked {
            class: None,
            pure: false,
            uses_idx: false,
        }
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
// The resolved node → class table (the hot-path lookup).
// ============================================================================

/// Free-slot marker, and therefore the one ordinal [`AddrClasses`] cannot
/// represent. See [`AddrClasses::add`].
const EMPTY_KEY: u32 = u32::MAX;

/// Every `Expr` is 8-byte aligned (it holds `f64`/`i64`/pointer fields), so the
/// low bits of a node address carry no information and are shifted out of the
/// key. Written as a const so the shift is a compile-time constant.
const ADDR_SHIFT: u32 = std::mem::align_of::<Expr>().trailing_zeros();

/// The base address is rounded down to a 4 GiB boundary, so a body analysed
/// later at a *lower* address almost never forces a rehash.
const BASE_ALIGN_MASK: usize = 0xFFFF_FFFF;

/// [`ClassTable::memoizable`] resolved into a flat open-addressed table.
///
/// This is the hottest lookup in the whole program: `eval_vec` probes it once
/// per node visit — ~483k times per RHS call on `simpleclimate.esm`, ~1.9e9
/// times over a 0.25-day solve. Reading `memoizable` directly costs a
/// `HashMap` probe over 662k entries (~17 MB, so two DRAM round-trips: the
/// control-byte group, then the bucket). The class assignment is FIXED for a
/// rule set — that is exactly what [`CseRt::retarget`] guarantees — so it is
/// worth resolving it once into a shape that probes in one:
///
/// * the key is a 32-bit node ORDINAL, `(addr - base) >> 3`, not the 64-bit
///   address, so key and class share a single 8-byte word and the table is
///   less than half the size of the map it replaces (~7.6 MB here);
/// * open addressing with linear probing: no control bytes, no SIMD group
///   load, and a collision costs the next word — usually the same cache line.
///
/// The stored key is the address, bijectively re-encoded, so this is EXACT: it
/// cannot hand back another node's class the way a fingerprint scheme could.
#[derive(Default)]
struct AddrClasses {
    /// `(key, class)`, with `key == EMPTY_KEY` marking a free slot.
    slots: Box<[(u32, u32)]>,
    /// Address the ordinals are relative to; 4 GiB-aligned.
    base: usize,
    /// Occupied slots, i.e. the live entry count.
    count: usize,
    /// Lowest / highest address ever added, kept so a rebase can tell whether
    /// the whole set still fits a `u32` ordinal.
    lo: usize,
    hi: usize,
}

impl AddrClasses {
    /// Multiply-shift into `[0, len)`. `len` carries no power-of-two
    /// constraint, so the table is sized to the key set rather than rounded up
    /// to the next power of two (which at 662k entries would waste ~4 MB).
    #[inline(always)]
    fn bucket(key: u32, len: usize) -> usize {
        let h = key.wrapping_mul(0x9E37_79B1);
        ((h as u64 * len as u64) >> 32) as usize
    }

    /// The class recorded for the node at `addr`, or `None`.
    #[inline]
    fn get(&self, addr: usize) -> Option<u32> {
        let len = self.slots.len();
        if len == 0 {
            return None;
        }
        // `wrapping_sub` folds an address below `base` into a huge ordinal,
        // which the range check rejects along with anything past a `u32`.
        let ord = addr.wrapping_sub(self.base) >> ADDR_SHIFT;
        if ord >= EMPTY_KEY as usize {
            return None;
        }
        let key = ord as u32;
        let mut i = Self::bucket(key, len);
        loop {
            let (k, class) = self.slots[i];
            if k == key {
                return Some(class);
            }
            if k == EMPTY_KEY {
                return None;
            }
            i += 1;
            if i == len {
                i = 0;
            }
        }
    }

    /// Record `entries` (addresses not already present). Returns `false` when
    /// the address set cannot be indexed by a `u32` ordinal — i.e. the analysed
    /// trees are spread over more than ~34 GB of address space, which no
    /// allocator does for one model's rule bodies (`simpleclimate.esm`'s 662k
    /// nodes span 1.05 GB). The caller then abandons the resolved table and
    /// reads the map, so this is a performance fallback, never a correctness
    /// one.
    fn add(&mut self, entries: &[(usize, u32)]) -> bool {
        if entries.is_empty() {
            return true;
        }
        let (min_new, max_new) = entries
            .iter()
            .fold((usize::MAX, 0usize), |(lo, hi), &(a, _)| (lo.min(a), hi.max(a)));
        // `count == 0` means nothing is stored, so the recorded bounds say
        // nothing and the new batch defines them outright.
        let (lo, hi) = if self.count == 0 {
            (min_new, max_new)
        } else {
            (self.lo.min(min_new), self.hi.max(max_new))
        };
        let new_base = lo & !BASE_ALIGN_MASK;
        if (hi - new_base) >> ADDR_SHIFT >= EMPTY_KEY as usize {
            return false;
        }
        let want = self.count + entries.len();
        // Grow geometrically: a hundred-body model then pays a handful of
        // rehashes rather than one full rebuild per body.
        if new_base != self.base || self.slots.len() * 7 < want * 10 {
            let cap = (want * 10 / 7 + 16).max(self.slots.len() * 2);
            // Addresses are recoverable from the keys, so a rebase does not
            // need the map.
            let carried: Vec<(usize, u32)> = self
                .slots
                .iter()
                .filter(|(k, _)| *k != EMPTY_KEY)
                .map(|&(k, c)| (self.base + ((k as usize) << ADDR_SHIFT), c))
                .collect();
            self.slots = vec![(EMPTY_KEY, 0u32); cap].into_boxed_slice();
            self.base = new_base;
            self.count = 0;
            for (addr, class) in carried {
                self.insert(addr, class);
            }
        }
        self.lo = lo;
        self.hi = hi;
        for &(addr, class) in entries {
            self.insert(addr, class);
        }
        true
    }

    /// Insert into a table already known to have room and range for `addr`.
    fn insert(&mut self, addr: usize, class: u32) {
        let len = self.slots.len();
        let key = ((addr - self.base) >> ADDR_SHIFT) as u32;
        let mut i = Self::bucket(key, len);
        loop {
            if self.slots[i].0 == EMPTY_KEY {
                self.slots[i] = (key, class);
                self.count += 1;
                return;
            }
            if self.slots[i].0 == key {
                // A re-classified address (see `ClassTable::analyse`): update in
                // place, and do NOT count it — the slot was already occupied.
                self.slots[i].1 = class;
                return;
            }
            i += 1;
            if i == len {
                i = 0;
            }
        }
    }
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

#[derive(Clone, Copy)]
enum Slot {
    Scalar(f64),
    Arr(usize),
}

/// One memo cell: the value recorded for a class at one scope level.
///
/// `stamp` is the evaluation scope the value belongs to. Scope ids are minted
/// monotonically and NEVER reused, so a stamp mismatch is a miss and the table
/// needs no clearing pass — which matters, because a scope is opened per
/// contraction tuple and per `makearray` region.
#[derive(Clone, Copy)]
struct MemoCell {
    stamp: u64,
    slot: Slot,
}

impl Default for MemoCell {
    fn default() -> Self {
        // 0 is not a scope id (`next_scope` is pre-incremented), so a default
        // cell is a guaranteed miss.
        MemoCell { stamp: 0, slot: Slot::Scalar(0.0) }
    }
}

/// A hash of everything a box-pure subtree can read from its box: the index
/// symbols and their per-axis `lo`/extent, and the bound contraction names and
/// values. Two boxes with the same signature resolve every box symbol
/// identically, so one class evaluated under both yields the same array — which
/// is exactly the entitlement the persistent memo needs.
///
/// A 64-bit digest rather than an owned key: it is computed on the hot path
/// (per box-pure node visit), and an owned `(Vec<String>, Vec<i64>, …)` key
/// would allocate on every probe. `FxHasher` is a fixed seed, so the digest is
/// deterministic run to run.
fn box_sig(bx: &VecBox) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = rustc_hash::FxHasher::default();
    bx.syms.len().hash(&mut h);
    for s in bx.syms {
        s.hash(&mut h);
    }
    bx.lo.hash(&mut h);
    bx.shape.hash(&mut h);
    bx.cnames.len().hash(&mut h);
    for s in bx.cnames {
        s.hash(&mut h);
    }
    bx.cvals.hash(&mut h);
    h.finish()
}

/// Ceilings on the persistent box-pure store (ess-lih). It is never recycled
/// within a solve, so it needs a bound: past either limit the store stops
/// accepting entries and the remaining pure nodes simply re-evaluate, exactly
/// as before this pass. The invariant geometry of a real model is a handful of
/// arrays; these are generous enough that only a pathological body reaches
/// them.
const PURE_MAX_ENTRIES: usize = 4096;
const PURE_MAX_ELEMS: usize = 8 << 20; // 8 Mi f64 = 64 MiB

#[derive(Default)]
struct Inner {
    classes: ClassTable,
    /// `classes.memoizable`, resolved for the hot path.
    addrs: AddrClasses,
    /// Set when the analysed addresses could not be resolved (see
    /// [`AddrClasses::add`]); `class_of` then reads `classes.memoizable`.
    addrs_unusable: bool,
    /// Set from `ESS_CSE_PARANOID`; see [`CseRt::verify_class`]. Kept as a field
    /// rather than read from the environment in `class_of` so the hot path pays
    /// one perfectly-predicted branch on a byte it already has in cache.
    verify: bool,
    /// Live memo, indexed `memo[depth - 1][class]`: one dense row per OPEN
    /// scope, stamped with the scope that wrote it.
    ///
    /// This replaces a `HashMap<(scope, class), Slot>` and reproduces it
    /// exactly. The stack of open scopes is precisely levels `1..=depth`, and a
    /// scope id belongs to exactly one level (each `enter_scope` mints one id
    /// at one depth), so "the cell at this level whose stamp is the current
    /// scope" IS the `(scope, class)` entry. Returning from a nested scope
    /// finds the enclosing scope's row untouched, as the map did; a closed
    /// sibling's leftovers at the same level carry its own — now unreachable —
    /// scope id and so cannot be mistaken for a hit.
    ///
    /// Rows are dense over the class space (6,734 classes for
    /// `simpleclimate.esm`, ~160 KB a row), so a probe is an array index into
    /// something that stays resident, not a hash.
    memo: Vec<Vec<MemoCell>>,
    // `Box` is load-bearing, not incidental: a memo hit hands out a reference
    // INTO a slab, so the slab's address must not move when this `Vec` grows.
    #[allow(clippy::vec_box)]
    slabs: Vec<Box<Slab>>,
    /// Number of `slabs` entries holding live values this evaluation. Slabs at
    /// or above this index are free for reuse.
    used: usize,
    /// PERSISTENT memo for box-pure nodes (ess-lih): (box signature, stripped
    /// class) → slot. Unlike `memo` this is never cleared between evaluations —
    /// an entry is a pure function of its key plus the CONST tier (see
    /// `ClassTable::walk`), so the only things that can invalidate it are a
    /// rebuilt class table ([`CseRt::retarget`]), replaced static observeds
    /// ([`CseRt::invalidate_consts`]) and a changed parameter vector
    /// ([`CseRt::bind_params`]) — all three of which drop it. A sparse map, not
    /// a dense row: entries are few (295 for `simpleclimate.esm`) and probed
    /// only at `PURE_BIT` nodes, so density buys nothing here.
    pmemo: FxHashMap<(u64, u32), Slot>,
    /// Backing store for `pmemo`. `Box` for the same reason as `slabs`: a hit
    /// hands out a reference INTO a slab, so its address must be stable.
    /// Entries are append-only between clears and never overwritten, so a live
    /// view can never alias a write.
    #[allow(clippy::vec_box)]
    pslabs: Vec<Box<Slab>>,
    /// Total elements held in `pslabs`, against [`PURE_MAX_ELEMS`].
    pelems: usize,
    /// Digest of the parameter vector the persistent store was filled against;
    /// see [`CseRt::bind_params`].
    pgen: u64,
    pgen_set: bool,
    /// CONST-tier leaf names for the box-pure analysis; see
    /// [`CseRt::set_const_names`].
    const_names: FxHashSet<String>,
    const_arrays: FxHashSet<String>,
    const_names_set: bool,
    /// Identity of the rule set the class table was built against. See
    /// [`CseRt::retarget`].
    tag: u64,
    /// Nesting depth of `enter_scope`. Zero means no vectorized evaluation is
    /// in flight, which is the only point at which the memo may be recycled.
    depth: u32,
    /// Monotonic scope-id source. Deliberately NOT reset between evaluations:
    /// these ids are the memo's staleness stamps, so reusing one would make a
    /// previous evaluation's cell look live.
    next_scope: u64,
    scope: u64,
    scope_stack: SmallVec<[u64; 8]>,
}

impl Inner {
    fn clear_persistent(&mut self) {
        self.pmemo.clear();
        self.pslabs.clear();
        self.pelems = 0;
    }
}

/// Per-`RhsScratch` CSE state: the structural class table (built once per body)
/// and the per-evaluation memo. Interior-mutable for the same reason
/// [`RhsScratch`] is: the evaluator holds it through a shared `EvalCtx` borrow.
#[derive(Default)]
pub(super) struct CseRt {
    inner: RefCell<Inner>,
}

impl CseRt {
    /// Point the class table at a rule set, discarding it if this is a
    /// DIFFERENT one from the last call.
    ///
    /// The table is keyed by AST node ADDRESS, which is only meaningful while
    /// the analysed trees are alive. That holds by construction today — a
    /// `CseRt` lives inside a [`RhsScratch`], which is already model-specific
    /// (it is sized to one model's variable shapes) and is co-owned with the
    /// cloned rule bodies by the RHS closure, so the trees outlive it. This
    /// guard makes a violation of that contract (a scratch reused across two
    /// models whose rule bodies happened to land on the same addresses) cost a
    /// re-analysis rather than produce a wrong sharing decision: `tag` is
    /// derived from the rule slices' own identity, so a different rule set
    /// invalidates the table.
    pub(super) fn retarget(&self, tag: u64) {
        if cse_disabled() {
            return;
        }
        let mut i = self.inner.borrow_mut();
        if i.tag != tag {
            i.tag = tag;
            i.classes = ClassTable::default();
            // The resolved table is keyed by the SAME addresses and must go
            // with it; keeping it would be exactly the stale-classification bug
            // this guard exists to prevent. The memo rows are indexed by class
            // id, and class ids restart from 0, so they go too.
            i.addrs = AddrClasses::default();
            i.addrs_unusable = false;
            i.memo.clear();
            // The persistent box-pure store is keyed by class id, and a fresh
            // class table reassigns those ids from 0 — so an entry kept across
            // a retarget would be served for an unrelated subtree. Drop it, and
            // the CONST-name set the classification was made against, with the
            // table they belong to.
            i.clear_persistent();
            i.const_names = FxHashSet::default();
            i.const_arrays = FxHashSet::default();
            i.const_names_set = false;
        }
    }

    /// Bind the persistent box-pure store to THIS parameter vector, discarding
    /// it if the values have changed (ess-lih).
    ///
    /// A box-pure subtree may read CONST-tier leaves, and the scalar parameters
    /// are among them — so a stored value is only valid while `params` holds
    /// still. On the `simulate` path it does, by construction: the driver builds
    /// a fresh [`RhsScratch`] per integration segment, and `param_vec` is fixed
    /// for the whole solve. The `debug_eval_rhs_into` entry point, however, lets
    /// a caller drive one scratch with a *different* `param_vec` — a param sweep
    /// reusing its buffers — and without this guard that caller would be served
    /// values computed from the previous parameters. Hashing ~10 f64 per call is
    /// far below the noise floor; a sweep pays one store rebuild per change.
    pub(super) fn bind_params(&self, params: &[f64]) {
        if cse_disabled() {
            return;
        }
        use std::hash::{Hash, Hasher};
        let mut h = rustc_hash::FxHasher::default();
        params.len().hash(&mut h);
        for p in params {
            p.to_bits().hash(&mut h);
        }
        let g = h.finish();
        let mut i = self.inner.borrow_mut();
        if !i.pgen_set || i.pgen != g {
            i.pgen = g;
            i.pgen_set = true;
            i.clear_persistent();
        }
    }

    /// Drop the persistent box-pure store AND the CONST-name set it was
    /// classified against. Called when the hoisted static observeds are
    /// (re)installed (`RhsScratch::set_static`): both the stored values and the
    /// names that made subtrees eligible are derived from them.
    pub(super) fn invalidate_consts(&self) {
        let mut i = self.inner.borrow_mut();
        i.clear_persistent();
        i.const_names = FxHashSet::default();
        i.const_arrays = FxHashSet::default();
        i.const_names_set = false;
    }

    /// Install the CONST-tier leaf names, the second half of the box-pure
    /// criterion (ess-lih). `build` runs at most once per [`Self::retarget`] —
    /// the set is fixed for the lifetime of the owning [`RhsScratch`], which the
    /// driver creates fresh per integration segment, i.e. at exactly the cadence
    /// at which the CONST/DISCRETE observeds and the parameter vector are
    /// themselves re-materialized. That is the whole invalidation story: a
    /// hoisted value cannot outlive the constants it was computed from.
    pub(super) fn set_const_names(
        &self,
        build: impl FnOnce() -> (FxHashSet<String>, FxHashSet<String>),
    ) {
        if cse_disabled() {
            return;
        }
        let mut i = self.inner.borrow_mut();
        if !i.const_names_set {
            i.const_names_set = true;
            let (all, arrays) = build();
            i.const_names = all;
            i.const_arrays = arrays;
        }
    }

    /// Analyse a rule body so its repeated subtrees become memoizable. Cheap to
    /// call repeatedly: the walk runs once per distinct body root.
    ///
    /// `idx_binders` / `c_binders` are the index symbols the caller's box binds
    /// (its `output_idx_names` / `contract_names`), which the box-pure analysis
    /// (ess-lih) needs — see [`ClassTable::walk`].
    pub(super) fn analyse(&self, body: &Expr, idx_binders: &[String], c_binders: &[String]) {
        if cse_disabled() {
            return;
        }
        let mut i = self.inner.borrow_mut();
        i.verify = cse_paranoid();
        {
            let Inner {
                classes,
                const_names,
                const_arrays,
                ..
            } = &mut *i;
            classes.analyse(body, idx_binders, c_binders, const_names, const_arrays);
        }
        if i.classes.pending.is_empty() {
            return;
        }
        // Fold whatever the walk just classified into the resolved table, so
        // `class_of` never has to consult the map. Only what is new is added,
        // so the cost over a whole model is one pass plus a few rehashes.
        let pending = std::mem::take(&mut i.classes.pending);
        if !i.addrs_unusable && !i.addrs.add(&pending) {
            i.addrs_unusable = true;
            i.addrs = AddrClasses::default();
        }
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
    /// the previous evaluation's slabs are recycled into `pool`.
    fn enter_scope(&self, pool: &mut Pool) {
        let mut i = self.inner.borrow_mut();
        if i.depth == 0 {
            // SOUNDNESS: recycling here is safe precisely because `depth == 0`
            // means no vectorized evaluation is in flight, and every caller of
            // `try_eval_arrayop_vectorized` consumes its result (copies the view
            // into an owned array, or scatters it into `dy`) before returning —
            // so no `VecValue` borrowing a slab can still be alive.
            //
            // The memo itself needs no clearing: its cells are stamped with
            // scope ids, and `next_scope` never rewinds, so every cell left
            // over from the evaluation just finished is already a miss.
            for idx in 0..i.used {
                let old = std::mem::replace(&mut *i.slabs[idx], Slab::empty());
                pool.give_array(old.data);
            }
            i.used = 0;
            i.scope_stack.clear();
            i.scope = 0;
        }
        i.depth += 1;
        i.next_scope += 1;
        let s = i.next_scope;
        let prev = i.scope;
        i.scope_stack.push(prev);
        i.scope = s;
        // Size this level's row to the classes known so far. `resize_with`
        // keeps the cells already there, whose stamps belong to scopes closed
        // at this level and are therefore already misses.
        let level = i.depth as usize - 1;
        let classes = i.classes.next_class as usize;
        if i.memo.len() <= level {
            i.memo.resize_with(level + 1, Vec::new);
        }
        if i.memo[level].len() < classes {
            i.memo[level].resize_with(classes, MemoCell::default);
        }
    }

    /// Close the scope opened by the matching [`Self::scope`].
    fn exit_scope(&self) {
        let mut i = self.inner.borrow_mut();
        i.scope = i.scope_stack.pop().unwrap_or(0);
        i.depth = i.depth.saturating_sub(1);
    }

    /// The class id of `expr` if it is worth memoizing here, else `None`.
    ///
    /// This runs once per node visit and is the single hottest lookup in the
    /// vectorized RHS, so it is a flat-array probe rather than a hash-map one;
    /// see [`AddrClasses`] for what was resolved and when.
    #[inline]
    pub(super) fn class_of(&self, expr: &Expr) -> Option<u32> {
        if cse_disabled() {
            return None;
        }
        let i = self.inner.borrow();
        if i.depth == 0 {
            return None;
        }
        let addr = expr as *const Expr as usize;
        if i.verify {
            return Self::verify_class(&i, addr);
        }
        if i.addrs_unusable {
            // The analysed trees could not be indexed by a 32-bit ordinal; the
            // map is still authoritative, so fall back to it rather than lose
            // the overlay.
            return i.classes.memoizable.get(&addr).copied();
        }
        i.addrs.get(addr)
    }

    /// `ESS_CSE_PARANOID=1`: assert on EVERY node visit that the resolved table
    /// answers exactly what the map it was resolved from would, and answer from
    /// the map. That equality is the entire correctness basis of the resolved
    /// table, so being able to assert it over a real solve — rather than over
    /// fixtures — is worth a switch; it makes the solve several times slower.
    #[cold]
    #[inline(never)]
    fn verify_class(i: &Inner, addr: usize) -> Option<u32> {
        let want = i.classes.memoizable.get(&addr).copied();
        assert_eq!(
            i.addrs.get(addr),
            want,
            "resolved CSE class table disagrees with the map at {addr:#x}"
        );
        want
    }

    /// Borrow the array in slab `idx` for the caller's `'a`.
    ///
    /// SAFETY: the array lives in a `Box<Slab>` whose address does not move
    /// when `slabs` grows, and slabs below `used` are never written again for
    /// the duration of the evaluation — [`Self::put`] only ever writes slabs at
    /// index `>= used`, and recycling only happens in [`Self::enter_scope`] at
    /// `depth == 0`, where no value can still be alive. So the reference is
    /// valid for as long as the caller can observe it.
    ///
    /// This is the ONLY place the memo extends a borrow out of the `RefCell`;
    /// both [`Self::get`] and [`Self::put`] route through it, so the argument
    /// above is made once rather than restated per call site.
    fn slab_view<'a>(&'a self, i: &Inner, idx: usize) -> VecValue<'a> {
        let slab: &Slab = &i.slabs[idx];
        let origin = slab.origin.clone();
        let ptr: *const ArrayD<f64> = &slab.data;
        VecValue::View {
            data: unsafe { &*ptr },
            origin,
        }
    }

    /// Borrow the array in persistent slab `idx` for the caller's `'a`.
    ///
    /// SAFETY: same argument as [`Self::slab_view`], transposed to `pslabs`,
    /// whose discipline is stricter still — it is append-only between clears
    /// (an entry is written exactly once, on the miss that creates it, and is
    /// never overwritten), and the three things that clear it
    /// ([`Self::retarget`], [`Self::bind_params`], [`Self::invalidate_consts`])
    /// all run either at the top of an RHS call or at scratch construction,
    /// with no vectorized evaluation in flight, so no live `VecValue` can
    /// borrow a dropped slab. The slabs are boxed, so growing the `Vec` does
    /// not move them.
    fn pslab_view<'a>(&'a self, i: &Inner, idx: usize) -> VecValue<'a> {
        let slab: &Slab = &i.pslabs[idx];
        let origin = slab.origin.clone();
        let ptr: *const ArrayD<f64> = &slab.data;
        VecValue::View {
            data: unsafe { &*ptr },
            origin,
        }
    }

    /// Serve a memoized value for `class` — from the PERSISTENT box-pure store
    /// when the id carries [`PURE_BIT`] (keyed by `bx`'s signature, valid
    /// across RHS calls), else from the current scope's dense row.
    pub(super) fn get<'a>(&'a self, class: u32, bx: &VecBox) -> Option<VecValue<'a>> {
        let i = self.inner.borrow();
        if class & PURE_BIT != 0 {
            let slot = *i.pmemo.get(&(box_sig(bx), class & !PURE_BIT))?;
            return match slot {
                Slot::Scalar(s) => Some(VecValue::Scalar(s)),
                Slot::Arr(idx) => Some(self.pslab_view(&i, idx)),
            };
        }
        let level = (i.depth as usize).checked_sub(1)?;
        let cell = *i.memo.get(level)?.get(class as usize)?;
        if cell.stamp != i.scope {
            return None;
        }
        match cell.slot {
            Slot::Scalar(s) => Some(VecValue::Scalar(s)),
            Slot::Arr(idx) => Some(self.slab_view(&i, idx)),
        }
    }

    /// Record `slot` for `class` in the current scope.
    fn store(&self, class: u32, slot: Slot) {
        // A `PURE_BIT` id must never index the dense rows: `resize_with(2^31)`
        // is a 34 GB allocation. `put` dispatches those to `pput` before this
        // point, so reaching here with one is a bug — refuse rather than OOM.
        debug_assert!(class & PURE_BIT == 0, "PURE class reached the dense memo");
        if class & PURE_BIT != 0 {
            return;
        }
        let mut i = self.inner.borrow_mut();
        let Some(level) = (i.depth as usize).checked_sub(1) else {
            return;
        };
        let stamp = i.scope;
        if i.memo.len() <= level {
            i.memo.resize_with(level + 1, Vec::new);
        }
        let row = &mut i.memo[level];
        // A body analysed *inside* an open scope can mint classes past the row
        // length this scope was sized to, so grow on demand as well.
        if row.len() <= class as usize {
            row.resize_with(class as usize + 1, MemoCell::default);
        }
        row[class as usize] = MemoCell { stamp, slot };
    }

    /// Record `v` for `class` in the current scope and return the value the
    /// caller should propagate. An `Owned` array is MOVED into a slab and
    /// served back as a borrowed view (so the memo owns exactly one copy); a
    /// scalar is stored by value; a `View` is passed through unmemoized,
    /// because it is already a zero-cost borrow of a persistent array.
    pub(super) fn put<'a>(&'a self, class: u32, v: VecValue<'a>, bx: &VecBox) -> VecValue<'a> {
        if class & PURE_BIT != 0 {
            return self.pput(class, v, bx);
        }
        match v {
            VecValue::Scalar(s) => {
                self.store(class, Slot::Scalar(s));
                VecValue::Scalar(s)
            }
            VecValue::View { data, origin } => VecValue::View { data, origin },
            VecValue::Owned { data, origin } => {
                let idx = {
                    let mut i = self.inner.borrow_mut();
                    let idx = i.used;
                    if idx == i.slabs.len() {
                        i.slabs.push(Box::new(Slab::empty()));
                    }
                    *i.slabs[idx] = Slab { data, origin };
                    i.used += 1;
                    idx
                };
                self.store(class, Slot::Arr(idx));
                // The exclusive borrows above have been released; derive the
                // returned reference from a fresh SHARED borrow so no `&mut` to
                // this slab is ever live at the same time as it. The origin
                // comes back off the slab, so what the writer propagates is by
                // construction what a later hit will see.
                let i = self.inner.borrow();
                self.slab_view(&i, idx)
            }
        }
    }

    /// Record a BOX-PURE value: it goes into the persistent store, which
    /// survives every subsequent RHS call. Returns the value the caller should
    /// propagate — a borrowed view of the stored array, or `v` unchanged when
    /// the store is full or the value is already a persistent borrow. See
    /// [`Self::pslab_view`] for the borrow-extension argument.
    fn pput<'a>(&'a self, class: u32, v: VecValue<'a>, bx: &VecBox) -> VecValue<'a> {
        let key = (box_sig(bx), class & !PURE_BIT);
        match v {
            VecValue::Scalar(s) => {
                self.inner.borrow_mut().pmemo.insert(key, Slot::Scalar(s));
                VecValue::Scalar(s)
            }
            // Already a zero-cost borrow of a persistent array; nothing to gain.
            VecValue::View { data, origin } => VecValue::View { data, origin },
            VecValue::Owned { data, origin } => {
                let n = data.len();
                {
                    let i = self.inner.borrow();
                    if i.pslabs.len() >= PURE_MAX_ENTRIES || i.pelems + n > PURE_MAX_ELEMS {
                        return VecValue::Owned { data, origin };
                    }
                }
                let idx = {
                    let mut i = self.inner.borrow_mut();
                    i.pelems += n;
                    i.pslabs.push(Box::new(Slab { data, origin }));
                    let idx = i.pslabs.len() - 1;
                    i.pmemo.insert(key, Slot::Arr(idx));
                    idx
                };
                // The exclusive borrow above has been released; derive the
                // returned reference from a fresh SHARED borrow so no `&mut` to
                // this slab is ever live at the same time as it.
                let i = self.inner.borrow();
                self.pslab_view(&i, idx)
            }
        }
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

    /// A box with no symbols at all, for tests exercising the non-pure paths
    /// (where the box only matters to `PURE_BIT` ids).
    fn nobox() -> VecBox<'static> {
        VecBox {
            syms: &[],
            lo: &[],
            shape: &[],
            cnames: &[],
            cvals: &[],
        }
    }

    /// `ClassTable::analyse` with no binders and no CONST tier — the exact
    /// behaviour the pre-ess-lih analysis had.
    fn analyse_plain(t: &mut ClassTable, body: &Expr) {
        t.analyse(body, &[], &[], &FxHashSet::default(), &FxHashSet::default());
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
        analyse_plain(&mut t, &body);
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
        analyse_plain(&mut t, &body);
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
        analyse_plain(&mut t, &body);
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

    /// A body with several repeated subexpressions, named so that bodies do not
    /// collapse into one another's classes.
    fn repeats_body(k: usize) -> Expr {
        let a = format!("a{k}");
        let dup = || {
            op(
                "-",
                vec![Expr::Variable(a.clone()), Expr::Variable("b".into())],
            )
        };
        let sq = || op("*", vec![dup(), dup()]);
        op(
            "+",
            vec![
                op("*", vec![sq(), sq()]),
                op("min", vec![op("abs", vec![dup()]), sq()]),
                Expr::Variable("c".into()),
            ],
        )
    }

    /// The resolved table is what `class_of` actually reads, so it must agree
    /// with the map it was resolved from on EVERY analysed address — a
    /// disagreement is a wrong class, i.e. a wrong number. Several bodies are
    /// analysed one at a time so the incremental `add` path and its geometric
    /// rehash are both exercised.
    #[test]
    fn the_resolved_table_agrees_with_the_map() {
        if cse_disabled() {
            return;
        }
        let bodies: Vec<Expr> = (0..24).map(repeats_body).collect();
        let rt = CseRt::default();
        for b in &bodies {
            rt.analyse(b, &[], &[]);
        }
        let i = rt.inner.borrow();
        assert!(!i.addrs_unusable, "these addresses are resolvable");
        assert!(!i.classes.memoizable.is_empty(), "something was classified");
        assert_eq!(
            i.addrs.count,
            i.classes.memoizable.len(),
            "every memoizable address is in the resolved table exactly once"
        );
        for (&addr, &class) in &i.classes.memoizable {
            assert_eq!(
                i.addrs.get(addr),
                Some(class),
                "resolved table disagrees at {addr:#x}"
            );
        }
        // A body root is never memoizable, so it must miss in both.
        for b in &bodies {
            let root = b as *const Expr as usize;
            assert!(!i.classes.memoizable.contains_key(&root));
            assert_eq!(i.addrs.get(root), None, "the root must not resolve");
        }
    }

    /// A rule-set change must discard the RESOLVED table too, not just the map:
    /// a stale resolution would keep answering for an address that is no longer
    /// classified, which is exactly the silent-wrong-answer failure mode.
    #[test]
    fn retarget_discards_the_resolved_table() {
        if cse_disabled() {
            return;
        }
        let body = repeats_body(0);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        let Expr::Operator(mul) = &root.args[0] else {
            unreachable!()
        };
        let shared = &mul.args[0];

        let rt = CseRt::default();
        let mut pool = Pool::default();
        rt.retarget(1);
        rt.analyse(&body, &[], &[]);
        {
            let _s = rt.scope(&mut pool);
            assert!(rt.class_of(shared).is_some(), "the repeat is classified");
        }
        rt.retarget(2);
        {
            let _s = rt.scope(&mut pool);
            assert!(
                rt.class_of(shared).is_none(),
                "a different rule set must invalidate the resolved table"
            );
        }
        rt.analyse(&body, &[], &[]);
        {
            let _s = rt.scope(&mut pool);
            assert!(
                rt.class_of(shared).is_some(),
                "re-analysis under the new tag repopulates it"
            );
        }
    }

    /// The address set must be representable as a 32-bit ordinal; when it is
    /// not, `add` refuses (and leaves what it already held intact) so the
    /// caller can fall back to the map rather than answer wrongly.
    #[test]
    fn the_resolved_table_refuses_an_unrepresentable_span() {
        let mut t = AddrClasses::default();
        assert!(t.add(&[(0x5000_0000_1000, 7), (0x5000_0000_2000, 9)]));
        assert_eq!(t.get(0x5000_0000_1000), Some(7));
        assert_eq!(t.get(0x5000_0000_2000), Some(9));
        assert_eq!(t.get(0x5000_0000_3000), None);
        // 64 TB apart: no `u32` ordinal spans that.
        assert!(!t.add(&[(0x1000, 11)]));
        assert_eq!(t.get(0x5000_0000_1000), Some(7), "the refusal is non-destructive");
    }

    /// Exhaustive round trip over a dense, collision-heavy address run: every
    /// key must come back, and nothing else may.
    #[test]
    fn the_resolved_table_round_trips_a_dense_run() {
        let base = 0x7f00_0000_0000usize;
        let stride = std::mem::size_of::<Expr>();
        let entries: Vec<(usize, u32)> =
            (0..5000).map(|k| (base + k * stride, k as u32)).collect();
        let mut t = AddrClasses::default();
        // Fed in chunks, so the table grows and rehashes mid-stream.
        for chunk in entries.chunks(97) {
            assert!(t.add(chunk));
        }
        assert_eq!(t.count, entries.len());
        for &(addr, class) in &entries {
            assert_eq!(t.get(addr), Some(class));
        }
        for k in 0..5000usize {
            // Halfway between two nodes: never an `Expr` address, never a hit.
            assert_eq!(t.get(base + k * stride + stride / 2 + 8), None);
        }
        assert_eq!(t.get(base - stride), None);
        assert_eq!(t.get(base + 5000 * stride), None);
    }

    /// The per-depth memo rows exist so that a nested scope does not evict the
    /// enclosing one — the property the old `(scope, class)` map had for free.
    #[test]
    fn a_nested_scope_does_not_evict_the_enclosing_one() {
        let rt = CseRt::default();
        let mut pool = Pool::default();
        let outer = rt.scope(&mut pool);
        rt.put(3, VecValue::Scalar(1.0), &nobox());
        {
            let _inner = rt.scope(&mut pool);
            assert!(rt.get(3, &nobox()).is_none(), "a fresh scope starts empty");
            rt.put(3, VecValue::Scalar(2.0), &nobox());
            assert!(matches!(rt.get(3, &nobox()), Some(VecValue::Scalar(v)) if v == 2.0));
        }
        assert!(
            matches!(rt.get(3, &nobox()), Some(VecValue::Scalar(v)) if v == 1.0),
            "the enclosing scope's entry must survive the nested one"
        );
        drop(outer);
    }

    /// Sibling scopes are different binding environments and must never share,
    /// even though they reuse the same memo row.
    #[test]
    fn sibling_scopes_do_not_share() {
        let rt = CseRt::default();
        let mut pool = Pool::default();
        let outer = rt.scope(&mut pool);
        {
            let _a = rt.scope(&mut pool);
            rt.put(5, VecValue::Scalar(1.0), &nobox());
        }
        {
            let _b = rt.scope(&mut pool);
            assert!(rt.get(5, &nobox()).is_none(), "a sibling scope must not see the entry");
        }
        drop(outer);
        // …nor may the next top-level evaluation.
        let _next = rt.scope(&mut pool);
        assert!(rt.get(5, &nobox()).is_none(), "a new evaluation must not see it either");
    }

    // ------------------------------------------------------------------
    // Box-pure hoist (ess-lih)
    // ------------------------------------------------------------------

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    fn set(v: &[&str]) -> FxHashSet<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    /// Analyse `body` as a rule body over output indices `idx`, with `consts`
    /// the CONST-tier names and `arrays` the array-valued ones. Returns the
    /// table so callers can probe `memoizable` by node address.
    fn analyse_pure(body: &Expr, idx: &[&str], consts: &[&str], arrays: &[&str]) -> ClassTable {
        let mut t = ClassTable::default();
        t.analyse(body, &names(idx), &[], &set(consts), &set(arrays));
        t
    }

    fn is_pure(t: &ClassTable, e: &Expr) -> bool {
        t.memoizable
            .get(&(e as *const Expr as usize))
            .is_some_and(|c| c & PURE_BIT != 0)
    }

    /// `dT_y · sin(j)²` — the shape of a Held–Suarez latitude factor. The `^`
    /// node is box-pure and MAXIMAL (its parent multiplies by a varying leaf, so
    /// the parent is not); the `sin` beneath it is pure but subsumed, so only
    /// the `^` carries a memo entry.
    #[test]
    fn maximal_box_pure_node_is_marked_and_its_children_are_not() {
        let body = op(
            "*",
            vec![
                Expr::Variable("u".into()), // a state variable: never pure
                op(
                    "^",
                    vec![
                        op("sin", vec![Expr::Variable("j".into())]),
                        Expr::Integer(2),
                    ],
                ),
            ],
        );
        let t = analyse_pure(&body, &["j"], &[], &[]);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        let powi = &root.args[1];
        let Expr::Operator(pn) = powi else { unreachable!() };
        assert!(is_pure(&t, powi), "sin(j)^2 must be box-pure");
        assert!(
            !is_pure(&t, &pn.args[0]),
            "the subsumed sin(j) must not carry its own entry"
        );
        assert!(!is_pure(&t, &body), "the root is never memoized");
    }

    /// A state / varying-observed leaf anywhere beneath a node makes it — and
    /// every ancestor — ineligible, which is the whole safety property.
    #[test]
    fn a_varying_leaf_blocks_box_purity() {
        let body = op(
            "*",
            vec![
                Expr::Variable("q".into()),
                op(
                    "^",
                    vec![
                        op("sin", vec![Expr::Variable("theta".into())]),
                        Expr::Integer(2),
                    ],
                ),
            ],
        );
        let t = analyse_pure(&body, &["j"], &[], &[]);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        assert!(
            !is_pure(&t, &root.args[1]),
            "a subtree reading a non-CONST name must never be hoisted"
        );
    }

    /// `t` is resolved by `eval_vec_variable` ahead of the box symbols, so a
    /// model that named an index `t` must not be treated as box-bound.
    #[test]
    fn t_is_never_a_box_binder() {
        let body = op(
            "*",
            vec![
                Expr::Variable("q".into()),
                op("sin", vec![Expr::Variable("t".into())]),
            ],
        );
        let t = analyse_pure(&body, &["t"], &[], &[]);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        assert!(!is_pure(&t, &root.args[1]), "sin(t) is time-varying");
    }

    /// A CONST-tier leaf (a hoisted static observed, or a parameter) keeps a
    /// subtree eligible — that is what lifts the pass beyond bare index
    /// arithmetic to real geometry factors.
    #[test]
    fn const_tier_leaves_keep_a_subtree_pure() {
        let body = op(
            "*",
            vec![
                Expr::Variable("q".into()),
                op(
                    "*",
                    vec![
                        Expr::Variable("a_earth".into()),
                        op(
                            "index",
                            vec![Expr::Variable("coslat3".into()), Expr::Variable("j".into())],
                        ),
                    ],
                ),
            ],
        );
        let t = analyse_pure(&body, &["j"], &["a_earth", "coslat3"], &["coslat3"]);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        assert!(is_pure(&t, &root.args[1]), "a_earth·coslat3[j] is CONST");
    }

    /// A subtree of nothing but SCALAR CONSTs folds to a scalar; caching it
    /// would buy a hash probe and save nothing, so it is left alone.
    #[test]
    fn scalar_only_const_subtree_is_not_cached() {
        let body = op(
            "*",
            vec![
                Expr::Variable("q".into()),
                op(
                    "*",
                    vec![Expr::Variable("a_earth".into()), Expr::Variable("Rd".into())],
                ),
            ],
        );
        let t = analyse_pure(&body, &["j"], &["a_earth", "Rd"], &[]);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        assert!(!is_pure(&t, &root.args[1]));
    }

    /// A binder-introducing operator re-enters the overlay under a box this walk
    /// does not know, so nothing beneath it is ever hoisted from here — even a
    /// subtree that looks index-only.
    #[test]
    fn nothing_below_a_nested_binder_is_hoisted() {
        let inner = op(
            "^",
            vec![
                op("sin", vec![Expr::Variable("j".into())]),
                Expr::Integer(2),
            ],
        );
        let agg = Expr::Operator(ExpressionNode {
            op: "aggregate".to_string(),
            args: vec![],
            output_idx: Some(vec!["j".to_string()]),
            expr: Some(Box::new(inner)),
            ..Default::default()
        });
        let body = op("*", vec![Expr::Variable("q".into()), agg]);
        let t = analyse_pure(&body, &["j"], &[], &[]);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        let Expr::Operator(agg_n) = &root.args[1] else {
            unreachable!()
        };
        let inner_ref = agg_n.expr.as_deref().expect("body");
        assert!(!is_pure(&t, inner_ref));
    }

    /// The persistent key must separate boxes that resolve index symbols
    /// differently — a different origin, extent, symbol set, or bound
    /// contraction tuple is a different value for the same subtree.
    #[test]
    fn box_signature_separates_distinguishable_boxes() {
        let syms = names(&["i"]);
        let other = names(&["k"]);
        let cn = names(&["c"]);
        let mk = |sy: &[String], lo: &[i64], sh: &[usize], cn: &[String], cv: &[i64]| {
            box_sig(&VecBox {
                syms: sy,
                lo,
                shape: sh,
                cnames: cn,
                cvals: cv,
            })
        };
        let base = mk(&syms, &[1], &[4], &[], &[]);
        assert_eq!(base, mk(&syms, &[1], &[4], &[], &[]), "same box, same key");
        assert_ne!(base, mk(&syms, &[2], &[4], &[], &[]), "origin matters");
        assert_ne!(base, mk(&syms, &[1], &[5], &[], &[]), "extent matters");
        assert_ne!(base, mk(&other, &[1], &[4], &[], &[]), "symbols matter");
        assert_ne!(
            mk(&syms, &[1], &[4], &cn, &[0]),
            mk(&syms, &[1], &[4], &cn, &[1]),
            "the bound contraction tuple matters"
        );
    }

    /// A `PURE_BIT` class must reach the RESOLVED table through `pending` like
    /// any other classification, and win over the plain entry for the same
    /// address — `class_of` reads only the resolved table on the hot path, so
    /// a mark that stayed in the map would never fire.
    #[test]
    fn pure_marks_reach_the_resolved_table() {
        if cse_disabled() {
            return;
        }
        // sin(j)^2 appears TWICE, so its address is also plain-memoizable —
        // the pure mark must be the one that survives resolution.
        let sq = || {
            op(
                "^",
                vec![
                    op("sin", vec![Expr::Variable("j".into())]),
                    Expr::Integer(2),
                ],
            )
        };
        let body = op(
            "*",
            vec![Expr::Variable("u".into()), op("+", vec![sq(), sq()])],
        );
        let rt = CseRt::default();
        rt.set_const_names(|| (FxHashSet::default(), FxHashSet::default()));
        rt.analyse(&body, &names(&["j"]), &[]);
        let Expr::Operator(root) = &body else {
            unreachable!()
        };
        let Expr::Operator(plus) = &root.args[1] else {
            unreachable!()
        };
        let mut pool = Pool::default();
        let _s = rt.scope(&mut pool);
        // Both `sq()`s are pure, so their PARENT `+` is the maximal pure node:
        // it carries the mark, and the subsumed `^` children keep their PLAIN
        // memoizable classes (they repeat within the scope).
        let c_plus = rt.class_of(&root.args[1]).expect("sin(j)^2+sin(j)^2 is classified");
        assert!(
            c_plus & PURE_BIT != 0,
            "the maximal pure node's PURE mark must win in the resolved table"
        );
        for a in &plus.args {
            let c = rt.class_of(a).expect("the repeated sq is plain-memoizable");
            assert!(c & PURE_BIT == 0, "a subsumed child must stay plain");
        }
        // And the map agrees with the resolved table (the paranoid invariant),
        // at the pure node and at the plain ones.
        let i = rt.inner.borrow();
        for e in std::iter::once(&root.args[1]).chain(plus.args.iter()) {
            let addr = e as *const Expr as usize;
            assert_eq!(i.addrs.get(addr), i.classes.memoizable.get(&addr).copied());
        }
    }
}
