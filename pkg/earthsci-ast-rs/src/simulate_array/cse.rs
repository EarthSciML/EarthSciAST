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
        let lo = if self.count == 0 { min_new } else { self.lo.min(min_new) };
        let hi = self.hi.max(max_new);
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

#[derive(Default)]
struct Inner {
    classes: ClassTable,
    /// `classes.memoizable`, resolved for the hot path.
    addrs: AddrClasses,
    /// Set when the analysed addresses could not be resolved (see
    /// [`AddrClasses::add`]); `class_of` then reads `classes.memoizable`.
    addrs_unusable: bool,
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
        }
    }

    /// Analyse a rule body so its repeated subtrees become memoizable. Cheap to
    /// call repeatedly: the walk runs once per distinct body root.
    pub(super) fn analyse(&self, body: &Expr) {
        if cse_disabled() {
            return;
        }
        let mut i = self.inner.borrow_mut();
        i.classes.analyse(body);
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
        if std::env::var("ESS_CSE_DBG").is_ok() {
            let want = i.classes.memoizable.get(&addr).copied();
            let got = i.addrs.get(addr);
            assert_eq!(want, got, "addr table disagrees at {addr:#x}");
            if std::env::var("ESS_CSE_DBG").as_deref() == Ok("map") {
                return want;
            }
        }
        if i.addrs_unusable {
            // The analysed trees could not be indexed by a 32-bit ordinal; the
            // map is still authoritative, so fall back to it rather than lose
            // the overlay.
            return i.classes.memoizable.get(&addr).copied();
        }
        i.addrs.get(addr)
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

    /// Serve a memoized value for `class` in the current scope.
    pub(super) fn get<'a>(&'a self, class: u32) -> Option<VecValue<'a>> {
        let i = self.inner.borrow();
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
    pub(super) fn put<'a>(&'a self, class: u32, v: VecValue<'a>) -> VecValue<'a> {
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
            rt.analyse(b);
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
        rt.analyse(&body);
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
        rt.analyse(&body);
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
        rt.put(3, VecValue::Scalar(1.0));
        {
            let _inner = rt.scope(&mut pool);
            assert!(rt.get(3).is_none(), "a fresh scope starts empty");
            rt.put(3, VecValue::Scalar(2.0));
            assert!(matches!(rt.get(3), Some(VecValue::Scalar(v)) if v == 2.0));
        }
        assert!(
            matches!(rt.get(3), Some(VecValue::Scalar(v)) if v == 1.0),
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
            rt.put(5, VecValue::Scalar(1.0));
        }
        {
            let _b = rt.scope(&mut pool);
            assert!(rt.get(5).is_none(), "a sibling scope must not see the entry");
        }
        drop(outer);
        // …nor may the next top-level evaluation.
        let _next = rt.scope(&mut pool);
        assert!(rt.get(5).is_none(), "a new evaluation must not see it either");
    }
}
