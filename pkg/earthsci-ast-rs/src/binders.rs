//! The names an expression node BINDS, and the names an expression reads free.
//!
//! A node binds names in several fields, and the walkers in this crate differ
//! on which of them count for their purpose. Those differences are spelled as
//! a [`Binders`] set rather than as separate definitions:
//!
//! * `ranges` keys — the loop symbols of a `faq` (output and contracted);
//! * `output_idx` entries — a `faq`'s output symbols, normally also `ranges`
//!   keys;
//! * `int_var` — the variable an `integral` integrates over;
//! * `bindings` keys — the formal parameters of an `apply_expression_template`;
//! * bare `index` subscripts — the names in `index(A, i, j)` after the array
//!   head. Only a BARE name counts; a subscript expression (`i + 1`) is a use
//!   of a symbol bound elsewhere.

use std::collections::HashSet;
use std::hash::BuildHasher;

use crate::types::{Expr, ExpressionNode};

/// A set of binder kinds, see the module documentation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Binders(u8);

impl Binders {
    pub(crate) const RANGES: Binders = Binders(1);
    pub(crate) const OUTPUT_IDX: Binders = Binders(2);
    pub(crate) const INT_VAR: Binders = Binders(4);
    pub(crate) const BINDINGS: Binders = Binders(8);
    pub(crate) const INDEX_SUBSCRIPTS: Binders = Binders(16);

    /// A `faq`'s loop symbols: `ranges` keys and `output_idx` entries.
    pub(crate) const LOOP: Binders = Self::RANGES.with(Self::OUTPUT_IDX);
    /// [`Self::LOOP`] plus an `integral`'s variable: every index or
    /// integration symbol a node scopes over its children.
    pub(crate) const SCOPE: Binders = Self::LOOP.with(Self::INT_VAR);
    /// [`Self::SCOPE`] plus a template application's parameter names: every
    /// name a node binds for its body.
    pub(crate) const BODY: Binders = Self::SCOPE.with(Self::BINDINGS);
    /// [`Self::BODY`] plus bare `index` subscripts.
    pub(crate) const ALL: Binders = Self::BODY.with(Self::INDEX_SUBSCRIPTS);

    pub(crate) const fn with(self, other: Binders) -> Binders {
        Binders(self.0 | other.0)
    }

    const fn has(self, kind: Binders) -> bool {
        self.0 & kind.0 != 0
    }
}

impl ExpressionNode {
    /// Call `f` on every name of the given kinds this node binds, in field
    /// order (`ranges`, `output_idx`, `int_var`, `bindings`, `index`
    /// subscripts). A name bound in two fields is visited twice.
    pub(crate) fn for_each_binder<'a>(&'a self, kinds: Binders, mut f: impl FnMut(&'a str)) {
        if kinds.has(Binders::RANGES)
            && let Some(r) = &self.ranges
        {
            r.keys().for_each(|k| f(k));
        }
        if kinds.has(Binders::OUTPUT_IDX)
            && let Some(idx) = &self.output_idx
        {
            idx.iter().for_each(|k| f(k));
        }
        if kinds.has(Binders::INT_VAR)
            && let Some(v) = &self.int_var
        {
            f(v);
        }
        // An operator reference's parameters are bound in its definition's
        // body, not over its own children: a binding's value is read in the
        // reference's scope (esm-spec §9.6.4), so they bind nothing here.
        if kinds.has(Binders::BINDINGS)
            && self.op != crate::operator_refs::APPLY_OP
            && let Some(b) = &self.bindings
        {
            b.keys().for_each(|k| f(k));
        }
        if kinds.has(Binders::INDEX_SUBSCRIPTS) && self.op == "index" {
            for arg in self.args.iter().skip(1) {
                if let Expr::Variable(name) = arg {
                    f(name);
                }
            }
        }
    }

    /// The names of the given kinds this node binds, see
    /// [`Self::for_each_binder`].
    pub(crate) fn binders(&self, kinds: Binders) -> Vec<&str> {
        let mut out = Vec::new();
        self.for_each_binder(kinds, |n| out.push(n));
        out
    }

    /// Whether this node carries any binder of the given kinds (a field that is
    /// present counts even when it is empty).
    pub(crate) fn carries_binders(&self, kinds: Binders) -> bool {
        (kinds.has(Binders::RANGES) && self.ranges.is_some())
            || (kinds.has(Binders::OUTPUT_IDX) && self.output_idx.is_some())
            || (kinds.has(Binders::INT_VAR) && self.int_var.is_some())
            || (kinds.has(Binders::BINDINGS)
                && self.op != crate::operator_refs::APPLY_OP
                && self.bindings.is_some())
            || (kinds.has(Binders::INDEX_SUBSCRIPTS)
                && self.op == "index"
                && self
                    .args
                    .iter()
                    .skip(1)
                    .any(|a| matches!(a, Expr::Variable(_))))
    }
}

/// Every name of the given kinds bound anywhere in `expr`, at any depth, added
/// to `out`. Not scoped: the union over the whole subtree.
pub(crate) fn collect_binders<S: BuildHasher>(
    expr: &Expr,
    kinds: Binders,
    out: &mut HashSet<String, S>,
) {
    if let Expr::Operator(node) = expr {
        node.for_each_binder(kinds, |n| {
            if !out.contains(n) {
                out.insert(n.to_string());
            }
        });
        node.for_each_child(&mut |child| collect_binders(child, kinds, out));
    }
}

/// Call `f` on every variable reference in `expr` that no enclosing node binds
/// as one of `kinds`: a node's binders are in scope for all of its children
/// ([`ExpressionNode::for_each_child`]). A name is visited once per free
/// occurrence.
pub(crate) fn for_each_free_name<'a>(expr: &'a Expr, kinds: Binders, f: &mut impl FnMut(&'a str)) {
    let mut bound: Vec<&'a str> = Vec::new();
    walk_free(expr, kinds, &mut bound, f);
}

fn walk_free<'a>(
    expr: &'a Expr,
    kinds: Binders,
    bound: &mut Vec<&'a str>,
    f: &mut impl FnMut(&'a str),
) {
    match expr {
        Expr::Variable(name) => {
            if !bound.contains(&name.as_str()) {
                f(name);
            }
        }
        Expr::Operator(node) => {
            let depth = bound.len();
            node.for_each_binder(kinds, |n| bound.push(n));
            node.for_each_child(&mut |child| walk_free(child, kinds, bound, f));
            bound.truncate(depth);
        }
        Expr::Number(_) | Expr::Integer(_) => {}
    }
}

/// The names `expr` reads free with respect to `kinds`, see
/// [`for_each_free_name`].
pub(crate) fn free_names(expr: &Expr, kinds: Binders) -> HashSet<String> {
    let mut out = HashSet::new();
    for_each_free_name(expr, kinds, &mut |n| {
        if !out.contains(n) {
            out.insert(n.to_string());
        }
    });
    out
}

/// Rename every free variable reference of `expr` in ONE pass: a reference
/// `n` that no enclosing node binds as one of `kinds` becomes `rename(n)` when
/// that is `Some`. The plain-string references a node's `join` clauses carry
/// ([`crate::types::JoinClause::map_reference_names`]) follow the same rule,
/// so a join column naming one of the node's own loop symbols is left alone.
///
/// One pass over a whole renaming is what keeps a renaming capture-free: a
/// name produced by one entry is never seen again by another, as it would be
/// by a sequence of single-name passes.
pub(crate) fn rename_free_names(
    expr: &Expr,
    kinds: Binders,
    rename: &dyn Fn(&str) -> Option<String>,
) -> Expr {
    let mut bound: Vec<String> = Vec::new();
    rename_walk(expr, kinds, rename, false, &mut bound)
}

/// [`rename_free_names`], leaving a reference alone where the name it would
/// become is bound there: an enclosing node binding `i` keeps `M.i` as
/// written rather than let it become, and be captured as, the loop symbol.
pub(crate) fn rename_free_names_uncaptured(
    expr: &Expr,
    kinds: Binders,
    rename: &dyn Fn(&str) -> Option<String>,
) -> Expr {
    let mut bound: Vec<String> = Vec::new();
    rename_walk(expr, kinds, rename, true, &mut bound)
}

fn rename_walk(
    expr: &Expr,
    kinds: Binders,
    rename: &dyn Fn(&str) -> Option<String>,
    uncaptured: bool,
    bound: &mut Vec<String>,
) -> Expr {
    let renamed = |n: &str, bound: &[String]| {
        if bound.iter().any(|b| b == n) {
            None
        } else {
            rename(n).filter(|to| !uncaptured || !bound.iter().any(|b| b == to))
        }
    };
    match expr {
        Expr::Variable(v) => renamed(v, bound).map_or_else(|| expr.clone(), Expr::Variable),
        Expr::Operator(node) => {
            let depth = bound.len();
            node.for_each_binder(kinds, |n| bound.push(n.to_string()));
            let mut out =
                node.map_children(&mut |c| rename_walk(c, kinds, rename, uncaptured, bound));
            if let Some(join) = &out.join {
                out.join = Some(
                    join.iter()
                        .map(|c| {
                            c.map_reference_names(|n| {
                                renamed(n, bound).unwrap_or_else(|| n.clone())
                            })
                        })
                        .collect(),
                );
            }
            bound.truncate(depth);
            Expr::operator(out)
        }
        Expr::Number(_) | Expr::Integer(_) => expr.clone(),
    }
}

/// Every bare (non-dotted, non-builtin) variable reference in `expr`, at any
/// depth and regardless of binders, added to `out`.
pub(crate) fn collect_bare_symbols<S: BuildHasher>(expr: &Expr, out: &mut HashSet<String, S>) {
    collect_symbols_where(expr, &|name| !name.contains('.'), out);
}

/// Every non-builtin variable reference in `expr`, dotted or not, at any depth
/// and regardless of binders, added to `out`: the walk of
/// [`collect_bare_symbols`] over a model whose own names are qualified (a
/// flattened system).
pub(crate) fn collect_symbols<S: BuildHasher>(expr: &Expr, out: &mut HashSet<String, S>) {
    collect_symbols_where(expr, &|_| true, out);
}

fn collect_symbols_where<S: BuildHasher>(
    expr: &Expr,
    keep: &dyn Fn(&str) -> bool,
    out: &mut HashSet<String, S>,
) {
    match expr {
        Expr::Variable(name) => {
            if keep(name) && !crate::op_registry::is_builtin_function_name(name) {
                out.insert(name.clone());
            }
        }
        Expr::Operator(node) => {
            node.for_each_child(&mut |child| collect_symbols_where(child, keep, out));
        }
        Expr::Number(_) | Expr::Integer(_) => {}
    }
}

/// [`ExpressionNode::for_each_binder`] restricted to [`Binders::LOOP`], over a
/// raw-JSON Expression node (an object with an `op`): `f` gets each `ranges`
/// key with [`Binders::RANGES`], then each string `output_idx` entry with
/// [`Binders::OUTPUT_IDX`]. Anything that is not a node binds nothing.
pub(crate) fn for_each_json_loop_binder<'a>(
    node: &'a serde_json::Value,
    mut f: impl FnMut(Binders, &'a str),
) {
    let Some(obj) = node.as_object() else {
        return;
    };
    if crate::json_visit::small_get(obj, "op").is_none() {
        return;
    }
    if let Some(ranges) =
        crate::json_visit::small_get(obj, "ranges").and_then(serde_json::Value::as_object)
    {
        ranges.keys().for_each(|k| f(Binders::RANGES, k));
    }
    if let Some(idx) =
        crate::json_visit::small_get(obj, "output_idx").and_then(serde_json::Value::as_array)
    {
        idx.iter()
            .filter_map(serde_json::Value::as_str)
            .for_each(|k| f(Binders::OUTPUT_IDX, k));
    }
}
