//! What each definition reads, and how often its value changes.
//!
//! A definition is a name with a defining expression: an observed and its
//! right-hand side, an observed rule of the array runtime and its body. Every
//! consumer that has to know what a definition depends on — the cadence
//! classifier ([`crate::cadence`]), the solve session's three-tier observed
//! split and the tape's sections, the build pipeline's observed order and
//! state-dependence, the join-key cone, the inline-test runner — reads it from
//! one [`DependencySummary`] per definition, built here on the shared
//! [`crate::binders::free_names`] rule.
//!
//! [`Reads`] is what one body names directly. [`DependencySummaries`] closes
//! those reads over the other definitions: whether a definition reads a
//! state, the independent variable `t`, or a discretely refreshed input,
//! directly or through another definition, and from that its
//! [`Cadence`] (`const ⊏ discrete ⊏ continuous`).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use crate::binders::Binders;
use crate::cadence::Cadence;
use crate::types::{Expr, ExpressionNode};

/// The independent variable, as an expression spells it.
pub(crate) const TIME: &str = "t";

/// What one body names directly.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Reads {
    /// Every variable reference no enclosing node binds ([`Binders::BODY`]):
    /// parameters, states, other definitions, `t`.
    pub(crate) names: HashSet<String>,
    /// The key columns and envelope factors of every `join` clause in the
    /// body. They are strings on the clause rather than expressions, so
    /// [`Self::names`] does not hold them. A join's match set is built once,
    /// at build time, so these are build-time reads: they order a definition
    /// after what they name, and do not make it vary.
    pub(crate) join_names: HashSet<String>,
}

impl Reads {
    /// What `expr` names. A subtree shared by several parents (an expanded
    /// template's body) is walked once where no enclosing binder can change
    /// what it reads.
    pub(crate) fn of(expr: &Expr) -> Reads {
        Self::walk(expr, None)
    }

    /// What `expr` names, its operator references read through `registry`
    /// as their expansion reads them (esm-spec §9.6.4 rule 2): the bindings
    /// the definition reads as values, and the names its body reads free at
    /// the site ([`crate::operator_refs::DefinitionReads`]). [`Self::of`]
    /// reads every binding of a reference, which is what a reference into a
    /// flattened system's closed registry reads.
    pub(crate) fn of_in(expr: &Expr, registry: &crate::operator_refs::OperatorRegistry) -> Reads {
        Self::walk(expr, Some(registry))
    }

    fn walk(expr: &Expr, registry: Option<&crate::operator_refs::OperatorRegistry>) -> Reads {
        let mut out = Reads::default();
        let mut walk = Walk {
            bound: Vec::new(),
            seen_unbound: HashSet::new(),
            seen_join: HashSet::new(),
            registry,
        };
        walk.names(expr, &mut out.names);
        walk.joins(expr, &mut out.join_names);
        out
    }

    /// These reads without `name`: the self-edge of a definition whose
    /// self-read is an ordering within one definition (a recurrence), not a
    /// dependency on another.
    pub(crate) fn without(mut self, name: &str) -> Reads {
        self.names.remove(name);
        self.join_names.remove(name);
        self
    }

    /// Every name read, by an expression or by a join clause.
    pub(crate) fn all(&self) -> impl Iterator<Item = &String> {
        self.names.iter().chain(&self.join_names)
    }
}

struct Walk<'a> {
    bound: Vec<&'a str>,
    /// Nodes already walked with nothing bound around them.
    seen_unbound: HashSet<*const ExpressionNode>,
    /// Nodes whose join clauses were already collected.
    seen_join: HashSet<*const ExpressionNode>,
    /// The registry operator references are read through, if any.
    registry: Option<&'a crate::operator_refs::OperatorRegistry>,
}

impl<'a> Walk<'a> {
    fn names(&mut self, expr: &'a Expr, out: &mut HashSet<String>) {
        match expr {
            Expr::Variable(name) => {
                if !self.bound.contains(&name.as_str()) && !out.contains(name) {
                    out.insert(name.clone());
                }
            }
            Expr::Operator(node) => {
                if self.bound.is_empty() && !self.seen_unbound.insert(std::sync::Arc::as_ptr(node))
                {
                    return;
                }
                let depth = self.bound.len();
                if let Some(r) = crate::operator_refs::reference_node(node) {
                    // A reference's binding keys are its definition's
                    // params, never names bound at the site.
                    if let Some(reg) = self.registry
                        && let Some(def) = reg.resolve(&r)
                    {
                        let reads = def.reads(reg);
                        for n in &reads.free {
                            if !self.bound.contains(&n.as_str()) && !out.contains(n) {
                                out.insert(n.clone());
                            }
                        }
                        self.bound.extend(def.body_binders().iter().map(String::as_str));
                        for (k, b) in r.bindings {
                            if reads.params.contains(k) {
                                self.names(b, out);
                            }
                        }
                    } else {
                        r.bindings.values().for_each(|b| self.names(b, out));
                    }
                    self.bound.truncate(depth);
                    return;
                }
                node.for_each_binder(Binders::BODY, |n| self.bound.push(n));
                node.for_each_child(&mut |c| self.names(c, out));
                self.bound.truncate(depth);
            }
            Expr::Number(_) | Expr::Integer(_) => {}
        }
    }

    fn joins(&mut self, expr: &'a Expr, out: &mut HashSet<String>) {
        let Expr::Operator(node) = expr else { return };
        if !self.seen_join.insert(std::sync::Arc::as_ptr(node)) {
            return;
        }
        for clause in node.join.iter().flatten() {
            out.extend(clause.on.iter().flatten().cloned());
            if let Some(ov) = &clause.overlap {
                out.extend(ov.src_env.iter().chain(&ov.tgt_env).cloned());
            }
        }
        node.for_each_child(&mut |c| self.joins(c, out));
    }
}

/// What a name that is not a definition contributes to a definition reading
/// it. `t` is [`Leaf::Time`] whatever the caller's function says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Leaf {
    /// Fixed for the whole run: a constant or sampled parameter, a loop or
    /// index-set symbol, a literal.
    Const,
    /// Refreshed only at discrete events: a discretely fed parameter or
    /// forcing field.
    Discrete,
    /// Changes every step: a state (an ODE state, an algebraic unknown, a
    /// Brownian parameter).
    State,
    /// The independent variable.
    Time,
}

/// What one definition reads, directly and through other definitions.
#[derive(Clone, Debug)]
pub(crate) struct DependencySummary {
    /// What the body names directly.
    pub(crate) reads: Reads,
    /// Reads a state.
    pub(crate) reads_state: bool,
    /// Reads `t`.
    pub(crate) reads_t: bool,
    /// Reads a discretely refreshed input.
    pub(crate) reads_discrete: bool,
    /// On, or downstream of, a dependency cycle among the definitions: no
    /// evaluation order puts it after everything it reads.
    pub(crate) unordered: bool,
}

impl DependencySummary {
    /// How often the value changes: CONTINUOUS when it reads a state or `t`
    /// (or cannot be ordered, so cannot be evaluated ahead of a step),
    /// DISCRETE when it reads a discretely refreshed input, else CONST.
    pub(crate) fn cadence(&self) -> Cadence {
        if self.reads_state || self.reads_t || self.unordered {
            Cadence::Continuous
        } else if self.reads_discrete {
            Cadence::Discrete
        } else {
            Cadence::Const
        }
    }
}

/// One [`DependencySummary`] per definition of a set, and their dependency
/// order.
#[derive(Clone, Debug, Default)]
pub(crate) struct DependencySummaries {
    defs: HashMap<String, DependencySummary>,
    /// The ordered definitions, each after every definition it reads.
    order: Vec<String>,
    /// The definitions left unordered, each with the definitions it reads
    /// among them.
    residue: BTreeMap<String, BTreeSet<String>>,
}

impl DependencySummaries {
    /// Summarize `defs`. `leaf` says what a name that is not one of them
    /// contributes. A definition's edges are the definitions its
    /// [`Reads`] name, join names included; a self-read is an edge (drop it
    /// with [`Reads::without`] where it is an ordering instead).
    ///
    /// The order is the one a round-by-round sweep gives: each round takes
    /// every definition whose reads are all placed, sorted by name.
    pub(crate) fn new(
        defs: impl IntoIterator<Item = (String, Reads)>,
        leaf: impl Fn(&str) -> Leaf,
    ) -> DependencySummaries {
        let defs: HashMap<String, Reads> = defs.into_iter().collect();
        let deps: HashMap<&str, BTreeSet<&str>> = defs
            .iter()
            .map(|(n, r)| {
                let d = r
                    .all()
                    .filter(|x| defs.contains_key(x.as_str()))
                    .map(String::as_str)
                    .collect();
                (n.as_str(), d)
            })
            .collect();

        let mut order: Vec<String> = Vec::with_capacity(defs.len());
        let mut placed: HashSet<&str> = HashSet::new();
        let mut pending: BTreeSet<&str> = defs.keys().map(String::as_str).collect();
        loop {
            let ready: Vec<&str> = pending
                .iter()
                .copied()
                .filter(|n| deps[n].iter().all(|d| placed.contains(d)))
                .collect();
            if ready.is_empty() {
                break;
            }
            for n in ready {
                pending.remove(n);
                placed.insert(n);
                order.push(n.to_string());
            }
        }

        // The direct flags of every definition, then propagated: in order for
        // the ordered ones, to a fixpoint over the residue.
        let direct = |r: &Reads| -> (bool, bool, bool) {
            let (mut state, mut time, mut discrete) = (false, false, false);
            for n in &r.names {
                if defs.contains_key(n) {
                    continue;
                }
                match if n == TIME { Leaf::Time } else { leaf(n) } {
                    Leaf::Const => {}
                    Leaf::Discrete => discrete = true,
                    Leaf::State => state = true,
                    Leaf::Time => time = true,
                }
            }
            (state, time, discrete)
        };
        let mut summaries: HashMap<String, DependencySummary> = defs
            .iter()
            .map(|(n, r)| {
                let (reads_state, reads_t, reads_discrete) = direct(r);
                let s = DependencySummary {
                    reads: r.clone(),
                    reads_state,
                    reads_t,
                    reads_discrete,
                    unordered: pending.contains(n.as_str()),
                };
                (n.clone(), s)
            })
            .collect();
        let propagate = |summaries: &mut HashMap<String, DependencySummary>, n: &str| -> bool {
            let s = &summaries[n];
            let (mut state, mut time, mut discrete) = (s.reads_state, s.reads_t, s.reads_discrete);
            // Only value reads carry a definition's variation; a join name
            // orders without making the reader vary.
            for d in s.reads.names.iter().filter(|d| d.as_str() != n) {
                if let Some(ds) = summaries.get(d) {
                    state |= ds.reads_state;
                    time |= ds.reads_t;
                    discrete |= ds.reads_discrete;
                }
            }
            let s = summaries.get_mut(n).expect("a definition");
            let changed = (state, time, discrete) != (s.reads_state, s.reads_t, s.reads_discrete);
            (s.reads_state, s.reads_t, s.reads_discrete) = (state, time, discrete);
            changed
        };
        for n in &order {
            propagate(&mut summaries, n);
        }
        loop {
            let mut changed = false;
            for n in &pending {
                changed |= propagate(&mut summaries, n);
            }
            if !changed {
                break;
            }
        }

        let residue = pending
            .iter()
            .map(|n| {
                let reads = deps[n]
                    .iter()
                    .filter(|d| pending.contains(*d))
                    .map(|d| d.to_string())
                    .collect();
                (n.to_string(), reads)
            })
            .collect();
        DependencySummaries {
            defs: summaries,
            order,
            residue,
        }
    }

    /// The summary of the definition `name`.
    pub(crate) fn get(&self, name: &str) -> Option<&DependencySummary> {
        self.defs.get(name)
    }

    /// The definitions in dependency order, without the unordered ones.
    pub(crate) fn order(&self) -> &[String] {
        &self.order
    }

    /// A dependency cycle among the definitions, as a path with its entry
    /// repeated (`["a", "b", "a"]`), when there is one: the same walk the
    /// validator's `observed_cycle` check names.
    pub(crate) fn cycle(&self) -> Option<Vec<String>> {
        if self.residue.is_empty() {
            return None;
        }
        Some(
            crate::classification::first_observed_cycle(&self.residue)
                .unwrap_or_else(|| self.residue.keys().cloned().collect()),
        )
    }

    /// The definitions whose cadence is at most `ceiling`.
    pub(crate) fn at_most(&self, ceiling: Cadence) -> HashSet<String> {
        self.defs
            .iter()
            .filter(|(_, s)| s.cadence() <= ceiling)
            .map(|(n, _)| n.clone())
            .collect()
    }

    /// The definitions that read a name in `targets`, directly or through
    /// another definition, by an expression or by a join clause. A target
    /// that is itself a definition is not in the answer for being one.
    pub(crate) fn reaching(&self, targets: &HashSet<String>) -> HashSet<String> {
        let mut out: HashSet<String> = HashSet::new();
        loop {
            let before = out.len();
            for (n, s) in &self.defs {
                if !out.contains(n)
                    && s.reads
                        .all()
                        .any(|r| targets.contains(r) || out.contains(r))
                {
                    out.insert(n.clone());
                }
            }
            if out.len() == before {
                return out;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn expr(v: serde_json::Value) -> Expr {
        serde_json::from_value(v).expect("an expression")
    }

    fn summaries(defs: &[(&str, serde_json::Value)]) -> DependencySummaries {
        DependencySummaries::new(
            defs.iter()
                .map(|(n, e)| (n.to_string(), Reads::of(&expr(e.clone())))),
            |n| match n {
                "u" => Leaf::State,
                "f" => Leaf::Discrete,
                _ => Leaf::Const,
            },
        )
    }

    #[test]
    fn reads_are_free_names_and_join_columns() {
        let e = expr(json!({
            "op": "faq", "semiring": "sum_product", "args": [], "output_idx": [],
            "ranges": {"i": {"from": "cells"}},
            "expr": {"op": "*", "args": [{"op": "index", "args": ["a", "i"]}, "k"]},
            "join": [{"on": [["src", "dst"]]}]
        }));
        let r = Reads::of(&e);
        let names: BTreeSet<&str> = r.names.iter().map(String::as_str).collect();
        assert_eq!(names, BTreeSet::from(["a", "k"]));
        let joins: BTreeSet<&str> = r.join_names.iter().map(String::as_str).collect();
        assert_eq!(joins, BTreeSet::from(["src", "dst"]));
    }

    #[test]
    fn variation_is_transitive_and_the_order_follows_reads() {
        let s = summaries(&[
            ("c", json!({"op": "*", "args": ["b", 2]})),
            ("b", json!({"op": "+", "args": ["a", "f"]})),
            ("a", json!({"op": "*", "args": ["k", 3]})),
            ("w", json!({"op": "+", "args": ["c", "u"]})),
            ("z", json!({"op": "+", "args": ["a", "t"]})),
        ]);
        assert_eq!(s.order(), ["a", "b", "z", "c", "w"]);
        assert_eq!(s.get("a").unwrap().cadence(), Cadence::Const);
        assert_eq!(s.get("b").unwrap().cadence(), Cadence::Discrete);
        assert_eq!(s.get("c").unwrap().cadence(), Cadence::Discrete);
        assert_eq!(s.get("w").unwrap().cadence(), Cadence::Continuous);
        assert!(s.get("w").unwrap().reads_state && !s.get("w").unwrap().reads_t);
        assert!(s.get("z").unwrap().reads_t);
        let reaching = s.reaching(&HashSet::from(["a".to_string()]));
        assert_eq!(
            reaching.iter().map(String::as_str).collect::<BTreeSet<_>>(),
            BTreeSet::from(["b", "c", "w", "z"])
        );
        assert!(s.cycle().is_none());
    }

    #[test]
    fn a_cycle_is_unordered_and_named() {
        let s = summaries(&[
            ("a", json!({"op": "+", "args": ["b", 1]})),
            ("b", json!({"op": "+", "args": ["a", 1]})),
            ("c", json!({"op": "+", "args": ["a", 1]})),
            ("d", json!({"op": "+", "args": ["k", 1]})),
        ]);
        assert_eq!(s.order(), ["d"]);
        assert!(s.get("c").unwrap().unordered);
        assert_eq!(s.get("c").unwrap().cadence(), Cadence::Continuous);
        assert_eq!(s.cycle().unwrap(), ["a", "b", "a"]);
    }
}
