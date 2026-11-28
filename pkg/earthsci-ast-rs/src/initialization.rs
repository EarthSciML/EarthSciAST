//! The initialization system (esm 2.5.0; esm-spec §11.4.2–§11.4.3).
//!
//! An **initialization equation** is an equation that mentions `ic` anywhere.
//! An explicit initial condition `ic(u) ~ e` (`e` mentions no `ic`) is a
//! [`FlattenedSystem::field_ics`] entry, evaluated directly. Every other one is
//! an equation of one system ([`FlattenedSystem::initialization_equations`]),
//! analysed here:
//!
//! - **expansion** (§11.4.2 item 8): `ic(y)` of an observed `y` is `y`'s
//!   definition with every unknown `w` written `ic(w)`; `ic(D(x))` is `x`'s
//!   tendency written the same way (flatten has usually resolved the `D`
//!   already, leaving `ic(<tendency>)`, which pushes `ic` inward the same way);
//! - **solved form**: `ic(u) ~ e` with `u` a state (not an observed) and `e`
//!   not reading `ic(u)` after expansion; anything else is implicit;
//! - **balance** (§11.4.3 "Balance"), per supplied values: scalar equations vs
//!   scalar unknowns plus an assignment of equations to unknowns (a maximum
//!   flow over the variable-level incidence, weighted by element counts);
//! - **order**: the solved equations in dependency order. A cycle among them,
//!   an implicit equation, and every equation downstream of either form the
//!   **implicit part**, which a binding with no nonlinear solver refuses
//!   (`unsupported_construct`) or hands to the caller (`strip` class
//!   `initialization`, API_SPEC §5.8).
//!
//! The triangular part is evaluated by the array build, after the explicit
//! initial conditions, the supplied values and the defaults are in the state,
//! with each `ic(w)` read as `w`'s starting value (the state binds by name in
//! the build-time scope).

use std::collections::{BTreeSet, HashMap, HashSet};

use crate::flatten::{FlattenedSystem, TermOrigin};
use crate::simulate::SimulateError;
use crate::types::{Equation, Expr, ExpressionNode};

/// Whether `e` holds an `ic` node anywhere.
pub(crate) fn mentions_ic(e: &Expr) -> bool {
    match e {
        Expr::Operator(n) => n.op == "ic" || n.any_child(&mut |c| mentions_ic(c)),
        _ => false,
    }
}

/// Whether the equation is an initialization equation: it mentions `ic` on
/// either side (esm-spec §11.4).
pub(crate) fn is_initialization_equation(eq: &Equation) -> bool {
    mentions_ic(&eq.lhs) || mentions_ic(&eq.rhs)
}

/// The target of an explicit initial condition `ic(u) ~ e`, `e` mentioning no
/// `ic` (esm-spec §11.4.3).
pub(crate) fn explicit_target(eq: &Equation) -> Option<String> {
    let t = crate::flatten::extract_ic_target(&eq.lhs)?;
    (!mentions_ic(&eq.rhs)).then_some(t)
}

fn ic_node(arg: Expr) -> Expr {
    Expr::operator(ExpressionNode {
        op: "ic".to_string(),
        args: vec![arg],
        ..Default::default()
    })
}

/// `e` with every `ic(a)` replaced by `a`: the form the build evaluates, where
/// the state binds by name to its starting value.
fn strip_ic(e: &Expr) -> Expr {
    match e {
        Expr::Operator(n) if n.op == "ic" && n.args.len() == 1 => strip_ic(&n.args[0]),
        Expr::Operator(n) => Expr::operator(n.map_children(&mut |c| strip_ic(c))),
        other => other.clone(),
    }
}

/// `e` with every `ic(…)` subtree replaced by `0`: what an equation reads
/// outside `ic`.
fn outside_ic(e: &Expr) -> Expr {
    match e {
        Expr::Operator(n) if n.op == "ic" => Expr::Integer(0),
        Expr::Operator(n) => Expr::operator(n.map_children(&mut |c| outside_ic(c))),
        other => other.clone(),
    }
}

fn holds_time_derivative(e: &Expr) -> Option<String> {
    match e {
        Expr::Operator(n)
            if n.op == "D" && n.wrt.as_deref().is_none_or(|w| w == "t") =>
        {
            Some(match n.args.first() {
                Some(Expr::Variable(v)) => v.clone(),
                _ => String::new(),
            })
        }
        Expr::Operator(n) => {
            let mut found = None;
            n.any_child(&mut |c| {
                found = holds_time_derivative(c);
                found.is_some()
            });
            found
        }
        _ => None,
    }
}

fn free(e: &Expr) -> HashSet<String> {
    crate::binders::free_names(e, crate::binders::Binders::BODY)
}

/// One equation of the initialization system.
#[derive(Debug, Clone)]
pub(crate) struct SystemEquation {
    pub(crate) equation: Equation,
    pub(crate) origin: TermOrigin,
    /// `u` for the solved form `ic(u) ~ e`.
    pub(crate) target: Option<String>,
    /// The right-hand side the build evaluates for the solved form: expanded,
    /// with every `ic(w)` read as `w`.
    pub(crate) eval_rhs: Option<Expr>,
    /// The states whose starting values the expanded equation mentions.
    pub(crate) mentions: BTreeSet<String>,
    /// How many scalar equations it is.
    pub(crate) n_scalar: usize,
}

impl SystemEquation {
    fn shown(&self) -> String {
        format!("`{} ~ {}`", self.equation.lhs, self.equation.rhs)
    }
}

/// The analysed initialization system of a flattened system.
#[derive(Debug, Default)]
pub(crate) struct InitSystem {
    pub(crate) equations: Vec<SystemEquation>,
    /// Element counts and extents of the states the system touches.
    extents: HashMap<String, Vec<usize>>,
    /// Elements an explicit initial condition sets, per state (column-major).
    explicit: HashMap<String, Vec<bool>>,
    /// The algebraic unknowns: a supplied value of one is a starting guess.
    algebraic: HashSet<String>,
    /// A refusal that holds whatever is supplied (`ic_reads_state`, an
    /// expansion with nothing to expand to).
    refusal: Option<SimulateError>,
    /// The solved equations outside the implicit part, in evaluation order.
    pub(crate) order: Vec<usize>,
    /// The implicit part, in equation order.
    pub(crate) removed: Vec<usize>,
}

impl InitSystem {
    /// Analyse the initialization system of `flat`.
    pub(crate) fn of(flat: &FlattenedSystem) -> InitSystem {
        let mut sys = InitSystem::default();
        let is_state = |n: &str| flat.state_variables.contains_key(n);
        let is_observed = |n: &str| flat.observed_variables.contains_key(n);
        let is_unknown = |n: &str| is_state(n) || is_observed(n);
        sys.algebraic = flat.algebraic_variables.keys().cloned().collect();

        // Definitions the expansion reads: an observed's `y ~ e` and a state's
        // `D(x) ~ e`.
        let mut observed_defs: HashMap<String, Expr> = HashMap::new();
        let mut tendencies: HashMap<String, Expr> = HashMap::new();
        for eq in &flat.equations {
            match &eq.lhs {
                Expr::Variable(n) if is_observed(n) => {
                    observed_defs.entry(n.clone()).or_insert(eq.rhs.clone());
                }
                Expr::Operator(n)
                    if n.op == "D" && n.wrt.as_deref().is_none_or(|w| w == "t") =>
                {
                    if let Some(Expr::Variable(x)) = n.args.first() {
                        tendencies.entry(x.clone()).or_insert(eq.rhs.clone());
                    }
                }
                _ => {}
            }
        }

        // `ic` pushed inward over an expression: each unknown and each time
        // derivative of one read as its starting value.
        fn wrap(e: &Expr, is_unknown: &dyn Fn(&str) -> bool) -> Expr {
            match e {
                Expr::Variable(n) if is_unknown(n) => ic_node(e.clone()),
                Expr::Operator(n) if n.op == "ic" => e.clone(),
                Expr::Operator(n)
                    if n.op == "D" && n.wrt.as_deref().is_none_or(|w| w == "t") =>
                {
                    ic_node(e.clone())
                }
                Expr::Operator(n) => Expr::operator(n.map_children(&mut |c| wrap(c, is_unknown))),
                other => other.clone(),
            }
        }
        // Expand every `ic` node of `e` down to `ic` of states.
        let mut unsupported: Option<String> = None;
        fn expand(
            e: &Expr,
            depth: usize,
            is_state: &dyn Fn(&str) -> bool,
            is_unknown: &dyn Fn(&str) -> bool,
            observed: &HashMap<String, Expr>,
            tendencies: &HashMap<String, Expr>,
            unsupported: &mut Option<String>,
        ) -> Expr {
            let Expr::Operator(n) = e else {
                return e.clone();
            };
            if n.op != "ic" {
                return Expr::operator(n.map_children(&mut |c| {
                    expand(c, depth, is_state, is_unknown, observed, tendencies, unsupported)
                }));
            }
            if depth > 64 {
                unsupported.get_or_insert_with(|| format!("{e}: the expansion does not end"));
                return e.clone();
            }
            let inner = match n.args.first() {
                Some(Expr::Variable(w)) if is_state(w) => return e.clone(),
                Some(Expr::Variable(w)) => match observed.get(w) {
                    Some(def) => wrap(def, is_unknown),
                    // A parameter's or a name's value at t0 is itself.
                    None => return e.clone(),
                },
                Some(Expr::Operator(d))
                    if d.op == "D" && d.wrt.as_deref().is_none_or(|w| w == "t") =>
                {
                    match d.args.first() {
                        Some(Expr::Variable(x)) => match tendencies.get(x) {
                            Some(def) => wrap(def, is_unknown),
                            None => {
                                unsupported.get_or_insert_with(|| {
                                    format!("{e}: '{x}' has no time-derivative equation")
                                });
                                return e.clone();
                            }
                        },
                        _ => return e.clone(),
                    }
                }
                Some(other) => wrap(other, is_unknown),
                None => return e.clone(),
            };
            expand(
                &inner,
                depth + 1,
                is_state,
                is_unknown,
                observed,
                tendencies,
                unsupported,
            )
        }
        fn ic_states(e: &Expr, is_state: &dyn Fn(&str) -> bool, out: &mut BTreeSet<String>) {
            if let Expr::Operator(n) = e {
                if n.op == "ic" {
                    if let Some(Expr::Variable(w)) = n.args.first()
                        && is_state(w)
                    {
                        out.insert(w.clone());
                    }
                    return;
                }
                n.for_each_child(&mut |c| ic_states(c, is_state, out));
            }
        }

        // Explicit initial conditions: the elements each sets.
        for (target, rhs) in &flat.field_ics {
            let Some(ext) = state_extents(flat, target) else {
                continue;
            };
            let n: usize = ext.iter().product::<usize>().max(1);
            let mask = sys.explicit.entry(target.clone()).or_insert(vec![false; n]);
            mark_coverage(rhs, &ext, mask);
            sys.extents.insert(target.clone(), ext);
        }

        let origin_of = |k: usize| {
            flat.initialization_origins
                .get(k)
                .cloned()
                .unwrap_or(TermOrigin::Component {
                    component: String::new(),
                })
        };
        for (k, eq) in flat.initialization_equations.iter().enumerate() {
            // A trajectory read in an equation that holds at t0 only (§11.4.2).
            if sys.refusal.is_none() {
                sys.refusal = trajectory_read(eq, &is_state, &observed_defs);
            }
            let lhs = expand(
                &eq.lhs,
                0,
                &is_state,
                &is_unknown,
                &observed_defs,
                &tendencies,
                &mut unsupported,
            );
            let rhs = expand(
                &eq.rhs,
                0,
                &is_state,
                &is_unknown,
                &observed_defs,
                &tendencies,
                &mut unsupported,
            );
            let mut mentions = BTreeSet::new();
            ic_states(&lhs, &is_state, &mut mentions);
            ic_states(&rhs, &is_state, &mut mentions);
            let solved = crate::flatten::extract_ic_target(&eq.lhs)
                .filter(|u| is_state(u) && !is_observed(u))
                .filter(|u| {
                    let mut r = BTreeSet::new();
                    ic_states(&rhs, &is_state, &mut r);
                    !r.contains(u)
                });
            for m in &mentions {
                if !sys.extents.contains_key(m)
                    && let Some(ext) = state_extents(flat, m)
                {
                    sys.extents.insert(m.clone(), ext);
                }
            }
            let n_scalar = match &solved {
                Some(u) => faq_box(&eq.rhs).unwrap_or_else(|| {
                    sys.extents
                        .get(u)
                        .map_or(1, |e| e.iter().product::<usize>().max(1))
                }),
                None => faq_box(&eq.lhs)
                    .or_else(|| faq_box(&eq.rhs))
                    .unwrap_or_else(|| union_size(flat, &[&eq.lhs, &eq.rhs])),
            };
            sys.equations.push(SystemEquation {
                equation: eq.clone(),
                origin: origin_of(k),
                eval_rhs: solved.as_ref().map(|_| strip_ic(&rhs)),
                target: solved,
                mentions,
                n_scalar,
            });
        }
        if sys.refusal.is_none()
            && let Some(why) = unsupported
        {
            sys.refusal = Some(SimulateError::Compile(
                crate::compile_error::CompileError::UnsupportedConstruct {
                    construct: crate::compile_error::INITIALIZATION_SYSTEM,
                    evaluator: crate::compile_error::ARRAY_EVALUATOR,
                    detail: why,
                },
            ));
        }
        sys.order_equations();
        sys
    }

    /// Order the solved equations by dependency; everything else is the
    /// implicit part.
    fn order_equations(&mut self) {
        let explicit_full = |w: &str| {
            self.explicit
                .get(w)
                .is_some_and(|m| m.iter().all(|&b| b))
        };
        let solved: Vec<usize> = (0..self.equations.len())
            .filter(|&k| self.equations[k].target.is_some())
            .collect();
        let targets: HashSet<&str> = solved
            .iter()
            .filter_map(|&k| self.equations[k].target.as_deref())
            .collect();
        // The starting values the implicit equations determine.
        let mut implicit_vars: HashSet<String> = HashSet::new();
        for e in &self.equations {
            if e.target.is_none() {
                implicit_vars.extend(
                    e.mentions
                        .iter()
                        .filter(|w| !explicit_full(w))
                        .cloned(),
                );
            }
        }
        let mut done_targets: HashSet<String> = HashSet::new();
        let mut placed = vec![false; self.equations.len()];
        loop {
            let mut progressed = false;
            for &k in &solved {
                if placed[k] {
                    continue;
                }
                let e = &self.equations[k];
                let me = e.target.as_deref().unwrap_or("");
                let ready = e.mentions.iter().all(|w| {
                    w == me
                        || done_targets.contains(w)
                        || (!targets.contains(w.as_str()) && !implicit_vars.contains(w))
                });
                if ready {
                    placed[k] = true;
                    self.order.push(k);
                    done_targets.insert(me.to_string());
                    progressed = true;
                }
            }
            if !progressed {
                break;
            }
        }
        self.removed = (0..self.equations.len()).filter(|&k| !placed[k]).collect();
    }

    /// Whether anything is left for a nonlinear solve.
    pub(crate) fn has_implicit_part(&self) -> bool {
        !self.removed.is_empty()
    }

    /// The states the implicit part determines (sorted).
    pub(crate) fn implicit_unknowns(&self) -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        for &k in &self.removed {
            let e = &self.equations[k];
            for w in &e.mentions {
                let full = self.explicit.get(w).is_some_and(|m| m.iter().all(|&b| b));
                if !full {
                    out.insert(w.clone());
                }
            }
        }
        out
    }

    /// The triangular steps as equations `u ~ e` the build evaluates in order.
    pub(crate) fn step_equations(&self) -> Vec<Equation> {
        self.order
            .iter()
            .map(|&k| {
                let e = &self.equations[k];
                Equation {
                    lhs: Expr::Variable(e.target.clone().unwrap_or_default()),
                    rhs: e.eval_rhs.clone().unwrap_or(Expr::Integer(0)),
                    comment: None,
                }
            })
            .collect()
    }

    /// The refusals that hold whatever is supplied: a trajectory read, an
    /// expansion with nothing to expand to.
    pub(crate) fn structural_refusal(&self) -> Option<&SimulateError> {
        self.refusal.as_ref()
    }

    /// Every check of a build with these supplied values (`supplied`: per
    /// state, the elements a caller's `u0` or a run-time override sets,
    /// column-major), in the order §11.4.3 runs them: the structural refusals,
    /// the balance, then — unless `strip_initialization` — the refusal of an
    /// implicit part.
    pub(crate) fn check(
        &self,
        supplied: &HashMap<String, Vec<usize>>,
        strip_initialization: bool,
    ) -> Result<(), SimulateError> {
        if let Some(r) = &self.refusal {
            return Err(r.clone_error());
        }
        self.balance(supplied)?;
        if self.has_implicit_part() && !strip_initialization {
            let eqs: Vec<String> = self
                .removed
                .iter()
                .map(|&k| self.equations[k].shown())
                .collect();
            return Err(SimulateError::Compile(
                crate::compile_error::CompileError::UnsupportedConstruct {
                    construct: crate::compile_error::INITIALIZATION_SYSTEM,
                    evaluator: crate::compile_error::ARRAY_EVALUATOR,
                    detail: format!(
                        "{} (esm-spec §11.4.3: it must be solved simultaneously, or is not \
                         explicit in its unknown, and this binding has no nonlinear solver; a \
                         caller that solves it asks for it with `strip` class \
                         `initialization`)",
                        eqs.join(", ")
                    ),
                },
            ));
        }
        Ok(())
    }

    /// The balance of §11.4.3: as many scalar equations as scalar unknowns,
    /// and an assignment of a distinct equation to every unknown.
    pub(crate) fn balance(&self, supplied: &HashMap<String, Vec<usize>>) -> Result<(), SimulateError> {
        if self.equations.is_empty() {
            return Ok(());
        }
        // Unknown elements per state the system mentions.
        let mut vars: Vec<String> = self
            .equations
            .iter()
            .flat_map(|e| e.mentions.iter().cloned())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let mut known_by_supply: Vec<String> = Vec::new();
        let mut n_unknown: HashMap<String, usize> = HashMap::new();
        for w in &vars {
            let n = self
                .extents
                .get(w)
                .map_or(1, |e| e.iter().product::<usize>().max(1));
            let mut known = self.explicit.get(w).cloned().unwrap_or(vec![false; n]);
            known.resize(n, false);
            if !self.algebraic.contains(w)
                && let Some(els) = supplied.get(w)
            {
                let mut hit = false;
                for &i in els {
                    if i < n && !known[i] {
                        known[i] = true;
                        hit = true;
                    }
                }
                if hit {
                    known_by_supply.push(w.clone());
                }
            }
            n_unknown.insert(w.clone(), known.iter().filter(|&&b| !b).count());
        }
        vars.retain(|w| n_unknown[w] > 0);
        let total_eq: usize = self.equations.iter().map(|e| e.n_scalar).sum();
        let total_unk: usize = vars.iter().map(|w| n_unknown[w]).sum();

        // Maximum flow: source → equation (its scalar count) → each unknown
        // state it mentions (unbounded) → sink (its unknown count).
        let ne = self.equations.len();
        let nv = vars.len();
        let (src, sink) = (0usize, 1 + ne + nv);
        let n_nodes = sink + 1;
        let mut cap = vec![vec![0usize; n_nodes]; n_nodes];
        let var_ix: HashMap<&str, usize> =
            vars.iter().enumerate().map(|(i, w)| (w.as_str(), 1 + ne + i)).collect();
        for (k, e) in self.equations.iter().enumerate() {
            cap[src][1 + k] = e.n_scalar;
            for w in &e.mentions {
                if let Some(&j) = var_ix.get(w.as_str()) {
                    cap[1 + k][j] = usize::MAX / 4;
                }
            }
        }
        for (i, w) in vars.iter().enumerate() {
            cap[1 + ne + i][sink] = n_unknown[w];
        }
        let mut flow = 0usize;
        loop {
            // Breadth-first augmenting path.
            let mut prev = vec![usize::MAX; n_nodes];
            prev[src] = src;
            let mut queue = std::collections::VecDeque::from([src]);
            while let Some(u) = queue.pop_front() {
                for v in 0..n_nodes {
                    if prev[v] == usize::MAX && cap[u][v] > 0 {
                        prev[v] = u;
                        queue.push_back(v);
                    }
                }
            }
            if prev[sink] == usize::MAX {
                break;
            }
            let mut push = usize::MAX;
            let mut v = sink;
            while v != src {
                push = push.min(cap[prev[v]][v]);
                v = prev[v];
            }
            let mut v = sink;
            while v != src {
                let u = prev[v];
                cap[u][v] -= push;
                cap[v][u] += push;
                v = u;
            }
            flow += push;
        }
        if total_eq == total_unk && flow == total_eq {
            return Ok(());
        }
        let direction = if total_eq > total_unk {
            "over-determined"
        } else if total_eq < total_unk {
            "under-determined"
        } else {
            "unassignable: no assignment of a distinct equation to every unknown exists"
        };
        let left_unknowns: Vec<String> = vars
            .iter()
            .enumerate()
            .filter(|(i, _)| cap[1 + ne + i][sink] > 0)
            .map(|(_, w)| w.clone())
            .collect();
        let left_equations: Vec<String> = self
            .equations
            .iter()
            .enumerate()
            .filter(|(k, _)| cap[src][1 + k] > 0)
            .map(|(_, e)| e.shown())
            .collect();
        let none = |v: &[String]| {
            if v.is_empty() {
                "none".to_string()
            } else {
                v.join(", ")
            }
        };
        let mut details = format!(
            "the initialization system is {direction} ({total_eq} scalar equation(s), \
             {total_unk} scalar unknown(s)). Unknowns no equation is left to determine: {}. \
             Equations no unknown is left for: {}.",
            none(&left_unknowns),
            none(&left_equations)
        );
        if !known_by_supply.is_empty() {
            details.push_str(&format!(
                " The supplied value (u0 or run-time override) of {} is a known of the system \
                 (esm-spec §11.4.3, \"Precedence\").",
                known_by_supply
                    .iter()
                    .map(|w| format!("'{w}'"))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        details.push_str(" A `default` is never an equation of the system.");
        Err(SimulateError::IcSystemUnbalanced { details })
    }
}

impl SimulateError {
    /// A copy of a refusal this module keeps (the error type is not `Clone`).
    fn clone_error(&self) -> SimulateError {
        match self {
            SimulateError::IcReadsState { name, details } => SimulateError::IcReadsState {
                name: name.clone(),
                details: details.clone(),
            },
            SimulateError::Compile(crate::compile_error::CompileError::UnsupportedConstruct {
                construct,
                evaluator,
                detail,
            }) => SimulateError::Compile(crate::compile_error::CompileError::UnsupportedConstruct {
                construct,
                evaluator,
                detail: detail.clone(),
            }),
            other => SimulateError::IcSystemUnbalanced {
                details: other.to_string(),
            },
        }
    }
}

/// `ic_reads_state` for an initialization equation that reads a state's
/// trajectory value outside `ic`: bare, as `D(w)`, or through observeds.
fn trajectory_read(
    eq: &Equation,
    is_state: &dyn Fn(&str) -> bool,
    observed_defs: &HashMap<String, Expr>,
) -> Option<SimulateError> {
    let name = crate::flatten::extract_ic_target(&eq.lhs).unwrap_or_else(|| {
        format!("{} ~ {}", eq.lhs, eq.rhs)
    });
    let shown = format!("`{} ~ {}`", eq.lhs, eq.rhs);
    for side in [&eq.lhs, &eq.rhs] {
        let out = outside_ic(side);
        if let Some(x) = holds_time_derivative(&out) {
            return Some(SimulateError::IcReadsState {
                name,
                details: format!(
                    "is an initialization equation ({shown} mentions `ic`, so it holds at t0 \
                     only) and reads `D({x})` outside `ic`, a state's trajectory value. Write \
                     `ic(D({x}))` for the tendency at the start, and keep dynamics out of \
                     initialization equations (esm-spec §11.4.2)"
                ),
            });
        }
        let mut reads: Vec<String> = free(&out).into_iter().collect();
        reads.sort();
        for r in reads {
            if is_state(&r) {
                return Some(SimulateError::IcReadsState {
                    name,
                    details: format!(
                        "is an initialization equation ({shown} mentions `ic`, so it holds at \
                         t0 only) and reads '{r}', a state, outside `ic`; its starting value is \
                         `ic({r})` (esm-spec §11.4.2)"
                    ),
                });
            }
            // Through observeds.
            let mut chain = vec![r.clone()];
            let mut seen = HashSet::new();
            if let Some(s) = observed_chain(&r, is_state, observed_defs, &mut chain, &mut seen) {
                return Some(SimulateError::IcReadsState {
                    name,
                    details: format!(
                        "reads '{}', which reads '{s}', a state, outside `ic` (esm-spec \
                         §11.4.2)",
                        chain.join("', which reads '")
                    ),
                });
            }
        }
    }
    None
}

fn observed_chain(
    n: &str,
    is_state: &dyn Fn(&str) -> bool,
    defs: &HashMap<String, Expr>,
    chain: &mut Vec<String>,
    seen: &mut HashSet<String>,
) -> Option<String> {
    let def = defs.get(n)?;
    if !seen.insert(n.to_string()) {
        return None;
    }
    let mut reads: Vec<String> = free(&outside_ic(def)).into_iter().collect();
    reads.sort();
    for r in reads {
        if is_state(&r) {
            return Some(r);
        }
        if defs.contains_key(&r) {
            chain.push(r.clone());
            if let Some(s) = observed_chain(&r, is_state, defs, chain, seen) {
                return Some(s);
            }
            chain.pop();
        }
    }
    None
}

/// Size of an index set: its `size`, else its member count.
pub(crate) fn set_size(flat: &FlattenedSystem, set: &str) -> Option<usize> {
    let s = flat.index_sets.get(set)?;
    s.size
        .map(|n| n.max(0) as usize)
        .or_else(|| s.members.as_ref().map(Vec::len))
}

fn var_sets(flat: &FlattenedSystem, name: &str) -> Option<Vec<String>> {
    flat.state_variables
        .get(name)
        .or_else(|| flat.observed_variables.get(name))
        .or_else(|| flat.parameters.get(name))
        .map(|v| v.shape.clone().unwrap_or_default())
}

/// The extents of a state's declared shape (`[]` for a scalar).
fn state_extents(flat: &FlattenedSystem, name: &str) -> Option<Vec<usize>> {
    let sets = var_sets(flat, name)?;
    sets.iter().map(|s| set_size(flat, s)).collect()
}

/// A `faq` with output indices: its box's element count.
fn faq_box(e: &Expr) -> Option<usize> {
    let Expr::Operator(n) = e else { return None };
    if !crate::faq::is_faq_op(&n.op) {
        return None;
    }
    let out = n.output_idx.as_ref().filter(|o| !o.is_empty())?;
    let ranges = n.ranges.as_ref()?;
    let mut total = 1usize;
    for i in out {
        let [lo, hi] = ranges.get(i)?.bounds()?;
        total *= (hi - lo + 1).max(0) as usize;
    }
    Some(total)
}

/// The element count of the union, by name, of the index sets of every
/// variable an equation reads (§11.4.3 "Arrays"); an `index` read is one
/// element.
fn union_size(flat: &FlattenedSystem, sides: &[&Expr]) -> usize {
    fn collect(e: &Expr, flat: &FlattenedSystem, out: &mut Vec<String>) {
        match e {
            Expr::Variable(n) => {
                for s in var_sets(flat, n).unwrap_or_default() {
                    if !out.contains(&s) {
                        out.push(s);
                    }
                }
            }
            Expr::Operator(n) if n.op == "index" => {}
            Expr::Operator(n) => n.for_each_child(&mut |c| collect(c, flat, out)),
            _ => {}
        }
    }
    let mut sets = Vec::new();
    for s in sides {
        collect(s, flat, &mut sets);
    }
    sets.iter()
        .map(|s| set_size(flat, s).unwrap_or(1))
        .product::<usize>()
        .max(1)
}

/// Mark the elements an explicit initial condition's right-hand side sets: a
/// `faq` with output indices sets the cells of its ranges, anything else every
/// element.
fn mark_coverage(rhs: &Expr, ext: &[usize], mask: &mut [bool]) {
    let ranges: Option<Vec<(usize, usize)>> = (|| {
        let Expr::Operator(n) = rhs else { return None };
        if !crate::faq::is_faq_op(&n.op) {
            return None;
        }
        let out = n.output_idx.as_ref().filter(|o| !o.is_empty())?;
        if out.len() != ext.len() {
            return None;
        }
        let r = n.ranges.as_ref()?;
        out.iter()
            .zip(ext)
            .map(|(i, &e)| match r.get(i)?.bounds() {
                Some([lo, hi]) => Some(((lo.max(1) - 1) as usize, (hi.max(0) as usize).min(e))),
                None => Some((0, e)),
            })
            .collect()
    })();
    let Some(ranges) = ranges else {
        mask.fill(true);
        return;
    };
    // Column-major over the box.
    let mut cell: Vec<usize> = ranges.iter().map(|r| r.0).collect();
    if ranges.iter().any(|(lo, hi)| lo >= hi) {
        return;
    }
    loop {
        let mut flat_ix = 0usize;
        let mut stride = 1usize;
        for (d, &c) in cell.iter().enumerate() {
            flat_ix += c * stride;
            stride *= ext[d];
        }
        if flat_ix < mask.len() {
            mask[flat_ix] = true;
        }
        let mut d = 0;
        loop {
            if d == cell.len() {
                return;
            }
            cell[d] += 1;
            if cell[d] < ranges[d].1 {
                break;
            }
            cell[d] = ranges[d].0;
            d += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_ic_reads_states_by_name() {
        let e: Expr = serde_json::from_value(serde_json::json!(
            {"op": "+", "args": [{"op": "ic", "args": ["x"]}, 1]}
        ))
        .unwrap();
        assert!(mentions_ic(&e));
        assert!(!mentions_ic(&strip_ic(&e)));
    }
}
