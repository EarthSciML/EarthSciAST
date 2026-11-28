//! Initialization equations and the initialization system (esm 2.5.0;
//! esm-spec §11.4.2–§11.4.3).
//!
//! This module is the one place that answers the questions every stage asks
//! about an equation that mentions `ic`:
//!
//! - **the classifier**: whether an equation is an initialization equation
//!   ([`is_initialization_equation`]), whether it is an explicit initial
//!   condition as the document spells it ([`explicit_form`]), and which `ic`
//!   target a diagnostic names ([`ic_subject`]). `flatten`, `validate`, the
//!   main balance, `strip` and the build all use these;
//! - **the counts**: the cells a `faq` range covers ([`range_cells`],
//!   [`faq_box`]), the cells an explicit initial condition sets
//!   ([`mark_coverage`]), and the over-determination `validate` reports
//!   ([`document_over_determination`]);
//! - **the system** ([`InitSystem`]): the initialization equations of a
//!   flattened system that are not explicit initial conditions, analysed
//!   once at build:
//!   - **expansion** (§11.4.2 item 8): `ic(y)` of an observed `y` is `y`'s
//!     definition with every unknown `w` written `ic(w)`; `ic(D(x))` is `x`'s
//!     tendency written the same way;
//!   - **solved form**: one side exactly `ic(u)`, `u` a state, the other side
//!     (expanded) not reading `ic(u)`;
//!   - and, per supplied values ([`InitSystem::plan`]), the **knowns** (the
//!     explicit initial conditions, the supplied values of ODE states, and
//!     the declared default of an ODE state no solved-form equation targets),
//!     the **balance** (scalar equations vs scalar unknowns plus an
//!     assignment, a maximum flow over the variable-level incidence weighted
//!     by element counts) and the **order** of the solved equations. A cycle
//!     among them, an equation not in solved form, and every solved equation
//!     that reads a value they determine form the **implicit part**, which a
//!     binding with no nonlinear solver refuses (`unsupported_construct`) or
//!     hands to the caller (`strip` class `initialization`, API_SPEC §5.8).
//!
//! The triangular part is evaluated by the array build, after the explicit
//! initial conditions, the supplied values and the defaults are in the state,
//! with each `ic(w)` read as `w`'s starting value (the state binds by name in
//! the build-time scope).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use crate::flatten::{FlattenedSystem, TermOrigin};
use crate::simulate::SimulateError;
use crate::types::{Equation, Expr, ExpressionNode, Model, RangeSpec};

// ============================================================================
// The classifier
// ============================================================================

/// Whether `e` holds an `ic` node anywhere.
pub(crate) fn mentions_ic(e: &Expr) -> bool {
    match e {
        Expr::Operator(n) => n.op == "ic" || n.any_child(&mut |c| mentions_ic(c)),
        _ => false,
    }
}

/// Whether the equation is an initialization equation: it mentions `ic` on
/// either side (esm-spec §11.4). It holds at `t0` only, stays out of the main
/// balance, and is never a dynamics equation.
pub(crate) fn is_initialization_equation(eq: &Equation) -> bool {
    mentions_ic(&eq.lhs) || mentions_ic(&eq.rhs)
}

/// `u` when `e` is exactly `ic(u)`, `u` a variable reference.
pub(crate) fn ic_name(e: &Expr) -> Option<&str> {
    match e {
        Expr::Operator(n) if n.op == "ic" && n.args.len() == 1 => match &n.args[0] {
            Expr::Variable(v) => Some(v),
            _ => None,
        },
        _ => None,
    }
}

/// Whether `e` holds `ic(u)`.
fn mentions_ic_of(e: &Expr, u: &str) -> bool {
    match e {
        Expr::Operator(n) if n.op == "ic" => {
            matches!(n.args.first(), Some(Expr::Variable(v)) if v == u)
        }
        Expr::Operator(n) => n.any_child(&mut |c| mentions_ic_of(c, u)),
        _ => false,
    }
}

/// The first of `(lhs, rhs)` and `(rhs, lhs)` whose first member is exactly
/// `ic(u)` and whose second `accept`s `u`: `(u, the other side)`.
fn ic_side<'e>(
    sides: [(&'e Expr, &'e Expr); 2],
    accept: impl Fn(&str, &Expr) -> bool,
) -> Option<(&'e str, &'e Expr)> {
    sides.into_iter().find_map(|(side, other)| {
        ic_name(side)
            .filter(|u| accept(u, other))
            .map(|u| (u, other))
    })
}

/// The explicit-initial-condition spelling (esm-spec §11.4.3): one side
/// exactly `ic(u)`, the other mentioning no `ic`, as `(u, e)`. `ic(u) ~ e` and
/// the mirrored `e ~ ic(u)` alike. Whether it IS an explicit initial
/// condition depends on `u` too (not an observed); `validate`, which cannot
/// tell observeds, reads every one as explicit.
pub(crate) fn explicit_form(eq: &Equation) -> Option<(&str, &Expr)> {
    ic_side([(&eq.lhs, &eq.rhs), (&eq.rhs, &eq.lhs)], |_, other| {
        !mentions_ic(other)
    })
}

/// The `ic` target an initialization equation's diagnostics name: the
/// argument of its first `ic` node, left-hand side first (`x` for `ic(x)`,
/// `D(x)` for `ic(D(x))`).
pub(crate) fn ic_subject(eq: &Equation) -> String {
    fn first(e: &Expr) -> Option<String> {
        let Expr::Operator(n) = e else { return None };
        if n.op == "ic" {
            return n.args.first().map(|a| match a {
                Expr::Variable(v) => v.clone(),
                other => other.to_string(),
            });
        }
        let mut found = None;
        n.any_child(&mut |c| {
            found = first(c);
            found.is_some()
        });
        found
    }
    first(&eq.lhs)
        .or_else(|| first(&eq.rhs))
        .unwrap_or_default()
}

/// `e` with every `ic(a)` read as `a`: the form the build evaluates (the
/// state binds by name to its starting value), and the shape of a residual
/// (a starting value has its unknown's shape).
pub(crate) fn read_ic_as_value(e: &Expr) -> Expr {
    match e {
        Expr::Operator(n) if n.op == "ic" && n.args.len() == 1 => read_ic_as_value(&n.args[0]),
        Expr::Operator(n) => Expr::operator(n.map_children(&mut |c| read_ic_as_value(c))),
        other => other.clone(),
    }
}

fn ic_node(arg: Expr) -> Expr {
    Expr::operator(ExpressionNode {
        op: "ic".to_string(),
        args: vec![arg],
        ..Default::default()
    })
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

fn is_time_derivative(n: &ExpressionNode) -> bool {
    n.op == "D" && n.wrt.as_deref().is_none_or(|w| w == "t")
}

fn holds_time_derivative(e: &Expr) -> Option<String> {
    match e {
        Expr::Operator(n) if is_time_derivative(n) => Some(match n.args.first() {
            Some(Expr::Variable(v)) => v.clone(),
            _ => String::new(),
        }),
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

// ============================================================================
// The counts
// ============================================================================

/// The cells a `faq` range covers along its axis, 0-based and half-open: a
/// literal `[lo, hi]`, or a declared index set of known size (`size`). `None`
/// when the extent cannot be read.
pub(crate) fn range_cells(
    r: &RangeSpec,
    size: &dyn Fn(&str) -> Option<usize>,
) -> Option<(usize, usize)> {
    match r {
        RangeSpec::IndexSetRef { from, of: None } => size(from).map(|n| (0, n)),
        other => {
            let [lo, hi] = other.bounds()?;
            let lo = (lo.max(1) - 1) as usize;
            Some((lo, (hi.max(0) as usize).max(lo)))
        }
    }
}

/// What a top-level `faq` with output indices covers (esm-spec §4.3.4).
pub(crate) enum FaqBox {
    /// Not a `faq` with output indices.
    NotFaq,
    /// One of its ranges has no readable extent.
    Unreadable,
    /// Its box, one `(lo, hi)` (0-based, half-open) per output index.
    Box(Vec<(usize, usize)>),
}

impl FaqBox {
    /// Its cell count, when it is a readable box.
    pub(crate) fn cells(&self) -> Option<usize> {
        match self {
            FaqBox::Box(b) => Some(b.iter().map(|(lo, hi)| hi - lo).product()),
            _ => None,
        }
    }
}

/// The box of `e` when it is a `faq` with output indices.
pub(crate) fn faq_box(e: &Expr, size: &dyn Fn(&str) -> Option<usize>) -> FaqBox {
    let Expr::Operator(n) = e else {
        return FaqBox::NotFaq;
    };
    let Some(out) = n
        .output_idx
        .as_ref()
        .filter(|o| crate::faq::is_faq_op(&n.op) && !o.is_empty())
    else {
        return FaqBox::NotFaq;
    };
    let ranges = n.ranges.as_ref();
    out.iter()
        .map(|i| range_cells(ranges?.get(i)?, size))
        .collect::<Option<Vec<_>>>()
        .map_or(FaqBox::Unreadable, FaqBox::Box)
}

/// Mark in `mask` (column-major over `ext`) the cells an explicit initial
/// condition with right-hand side `rhs` sets: a `faq` with output indices
/// sets the cells of its box, anything else every cell.
pub(crate) fn mark_coverage(
    rhs: &Expr,
    ext: &[usize],
    size: &dyn Fn(&str) -> Option<usize>,
    mask: &mut [bool],
) {
    let ranges: Vec<(usize, usize)> = match faq_box(rhs, size) {
        FaqBox::Box(b) if b.len() == ext.len() => b
            .into_iter()
            .zip(ext)
            .map(|((lo, hi), &n)| (lo.min(n), hi.min(n)))
            .collect(),
        _ => {
            mask.fill(true);
            return;
        }
    };
    if ranges.iter().any(|(lo, hi)| lo >= hi) {
        return;
    }
    let mut cell: Vec<usize> = ranges.iter().map(|r| r.0).collect();
    loop {
        let mut flat_ix = 0usize;
        let mut stride = 1usize;
        for (d, &c) in cell.iter().enumerate() {
            flat_ix += c * stride;
            stride *= ext[d];
        }
        if let Some(m) = mask.get_mut(flat_ix) {
            *m = true;
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

/// The over-determination of a model's initialization system that the
/// document shows by itself (esm-spec §11.4.3 "What `validate` reports"), as
/// `(the system equations' indices, their scalar count, the free cells)`,
/// when the equations outnumber the cells.
///
/// The system equations are the model's initialization equations that are
/// not in the explicit spelling ([`explicit_form`]; `validate` cannot tell
/// observeds, so `ic(y) ~ 4` counts as explicit). Each is one scalar
/// equation per cell of a side that is a `faq` with output indices, else
/// one. A starting value they mention counts all its cells unless the
/// model's explicit initial conditions of it cover every one. No finding
/// when an extent cannot be read: an index set without a size, a scoped
/// name, a name the model does not declare, `ic(D(x))`.
pub(crate) fn document_over_determination(
    model: &Model,
    size: &dyn Fn(&str) -> Option<usize>,
) -> Option<(Vec<usize>, usize, usize)> {
    let system: Vec<usize> = model
        .equations
        .iter()
        .enumerate()
        .filter(|(_, eq)| is_initialization_equation(eq) && explicit_form(eq).is_none())
        .map(|(k, _)| k)
        .collect();
    if system.is_empty() {
        return None;
    }
    let mut n_equations = 0usize;
    let mut mentioned: BTreeSet<String> = BTreeSet::new();
    for &k in &system {
        let eq = &model.equations[k];
        let cells = match faq_box(&eq.lhs, size) {
            FaqBox::NotFaq => match faq_box(&eq.rhs, size) {
                FaqBox::NotFaq => Some(1),
                other => other.cells(),
            },
            other => other.cells(),
        }?;
        n_equations += cells;
        for side in [&eq.lhs, &eq.rhs] {
            ic_arguments(side, &mut mentioned)?;
        }
    }
    let extents = |name: &str| -> Option<Vec<usize>> {
        model
            .variables
            .get(name)?
            .shape
            .iter()
            .flatten()
            .map(|s| size(s))
            .collect()
    };
    let mut free_cells = 0usize;
    for name in &mentioned {
        if name.contains('.') {
            return None;
        }
        let ext = extents(name)?;
        let n = ext.iter().product::<usize>().max(1);
        let mut covered = vec![false; n];
        for eq in &model.equations {
            if let Some((u, rhs)) = explicit_form(eq)
                && u == name
            {
                mark_coverage(rhs, &ext, size, &mut covered);
            }
        }
        if !covered.iter().all(|&c| c) {
            free_cells += n;
        }
    }
    (n_equations > free_cells).then_some((system, n_equations, free_cells))
}

/// The names `ic` reads in `e`; `None` for an `ic` of anything but a name.
fn ic_arguments(e: &Expr, out: &mut BTreeSet<String>) -> Option<()> {
    let Expr::Operator(n) = e else {
        return Some(());
    };
    if n.op == "ic" {
        let Some(Expr::Variable(v)) = n.args.first() else {
            return None;
        };
        out.insert(v.clone());
        return Some(());
    }
    let mut ok = true;
    n.for_each_child(&mut |c| ok &= ic_arguments(c, out).is_some());
    ok.then_some(())
}

// ============================================================================
// The initialization system
// ============================================================================

/// A refusal that holds whatever is supplied.
#[derive(Debug, Clone)]
enum Refusal {
    /// `ic_reads_state` (esm-spec §11.4.2).
    ReadsState { name: String, details: String },
    /// `unsupported_construct`: an expansion with nothing to expand to.
    Unsupported(String),
}

impl Refusal {
    fn error(&self) -> SimulateError {
        match self {
            Refusal::ReadsState { name, details } => SimulateError::IcReadsState {
                name: name.clone(),
                details: details.clone(),
            },
            Refusal::Unsupported(detail) => unsupported(detail.clone()),
        }
    }
}

fn unsupported(detail: String) -> SimulateError {
    SimulateError::Compile(crate::compile_error::CompileError::UnsupportedConstruct {
        construct: crate::compile_error::INITIALIZATION_SYSTEM,
        evaluator: crate::compile_error::ARRAY_EVALUATOR,
        detail,
    })
}

/// One equation of the initialization system.
#[derive(Debug, Clone)]
pub(crate) struct SystemEquation {
    pub(crate) equation: Equation,
    pub(crate) origin: TermOrigin,
    /// `u` for the solved form `ic(u) ~ e` (whichever side `ic(u)` is on).
    pub(crate) target: Option<String>,
    /// The right-hand side the build evaluates for the solved form: expanded,
    /// with every `ic(w)` read as `w`.
    eval_rhs: Option<Expr>,
    /// The states whose starting values the expanded equation mentions.
    mentions: BTreeSet<String>,
    /// How many scalar equations it is.
    n_scalar: usize,
}

impl SystemEquation {
    fn shown(&self) -> String {
        format!("`{} ~ {}`", self.equation.lhs, self.equation.rhs)
    }
}

/// The analysed initialization system of a flattened system: everything that
/// does not depend on the supplied values. [`Self::plan`] adds them.
#[derive(Debug, Default)]
pub(crate) struct InitSystem {
    pub(crate) equations: Vec<SystemEquation>,
    /// Extents of the states the system touches (`[]` for a scalar).
    extents: HashMap<String, Vec<usize>>,
    /// Cells an explicit initial condition sets, per state (column-major).
    explicit: HashMap<String, Vec<bool>>,
    /// The algebraic unknowns: a supplied value or default of one is a guess.
    algebraic: HashSet<String>,
    /// The ODE states that declare a `default`: a known starting value
    /// unless a solved-form equation targets them (esm-spec §11.4.3,
    /// "Declared defaults").
    defaulted: HashSet<String>,
    refusal: Option<Refusal>,
}

/// The initialization system under one set of supplied values: what the
/// build evaluates, and what it leaves to a caller.
#[derive(Debug, Default, Clone)]
pub(crate) struct InitPlan {
    /// The solved-form equations evaluated by substitution, in order.
    pub(crate) order: Vec<usize>,
    /// The implicit part, in equation order.
    pub(crate) removed: Vec<usize>,
    /// The cells (column-major) of each state the implicit part determines.
    pub(crate) unknowns: BTreeMap<String, Vec<usize>>,
}

impl InitPlan {
    /// Whether anything is left for a nonlinear solve.
    pub(crate) fn has_implicit_part(&self) -> bool {
        !self.removed.is_empty()
    }
}

/// Expands every `ic` node of an expression down to `ic` of states
/// (esm-spec §11.4.2 item 8).
struct Expander<'f> {
    flat: &'f FlattenedSystem,
    /// An observed's `y ~ e`.
    observed: HashMap<&'f str, &'f Expr>,
    /// A state's `D(x) ~ e`.
    tendencies: HashMap<&'f str, &'f Expr>,
    unsupported: Option<String>,
}

impl<'f> Expander<'f> {
    fn new(flat: &'f FlattenedSystem) -> Self {
        let mut observed = HashMap::new();
        let mut tendencies = HashMap::new();
        for eq in &flat.equations {
            match &eq.lhs {
                Expr::Variable(n) if flat.observed_variables.contains_key(n) => {
                    observed.entry(n.as_str()).or_insert(&eq.rhs);
                }
                Expr::Operator(n) if is_time_derivative(n) => {
                    if let Some(Expr::Variable(x)) = n.args.first() {
                        tendencies.entry(x.as_str()).or_insert(&eq.rhs);
                    }
                }
                _ => {}
            }
        }
        Expander {
            flat,
            observed,
            tendencies,
            unsupported: None,
        }
    }

    fn is_state(&self, n: &str) -> bool {
        self.flat.state_variables.contains_key(n) && !self.is_observed(n)
    }

    fn is_observed(&self, n: &str) -> bool {
        self.flat.observed_variables.contains_key(n)
    }

    /// `ic` pushed inward over `e`: each unknown, and each time derivative of
    /// one, read as its starting value.
    fn wrap(&self, e: &Expr) -> Expr {
        match e {
            Expr::Variable(n)
                if self.flat.state_variables.contains_key(n) || self.is_observed(n) =>
            {
                ic_node(e.clone())
            }
            Expr::Operator(n) if n.op == "ic" || is_time_derivative(n) => ic_node(e.clone()),
            Expr::Operator(n) => Expr::operator(n.map_children(&mut |c| self.wrap(c))),
            other => other.clone(),
        }
    }

    fn expand(&mut self, e: &Expr, depth: usize) -> Expr {
        let Expr::Operator(n) = e else {
            return e.clone();
        };
        if n.op != "ic" {
            return Expr::operator(n.map_children(&mut |c| self.expand(c, depth)));
        }
        if depth > 64 {
            self.unsupported
                .get_or_insert_with(|| format!("{e}: the expansion does not end"));
            return e.clone();
        }
        let inner = match n.args.first() {
            Some(Expr::Variable(w)) => match self.observed.get(w.as_str()) {
                Some(def) if !self.is_state(w) => self.wrap(def),
                // A state's starting value, or a name the build refuses.
                _ => return e.clone(),
            },
            Some(Expr::Operator(d)) if is_time_derivative(d) => match d.args.first() {
                Some(Expr::Variable(x)) => match self.tendencies.get(x.as_str()) {
                    Some(def) => self.wrap(def),
                    None => {
                        self.unsupported.get_or_insert_with(|| {
                            format!("{e}: '{x}' has no time-derivative equation")
                        });
                        return e.clone();
                    }
                },
                _ => return e.clone(),
            },
            // `flatten` resolves a right-hand-side `D(x)` to `x`'s tendency
            // (esm-libraries-spec §4.7.5 step 3a), inside `ic` too, which
            // leaves `ic(<tendency>)`: `ic` pushes inward over it the same way.
            Some(other) => self.wrap(other),
            None => return e.clone(),
        };
        self.expand(&inner, depth + 1)
    }

    /// The states whose starting values `e` (expanded) reads.
    fn ic_states(&self, e: &Expr, out: &mut BTreeSet<String>) {
        if let Expr::Operator(n) = e {
            if n.op == "ic" {
                if let Some(Expr::Variable(w)) = n.args.first()
                    && self.is_state(w)
                {
                    out.insert(w.clone());
                }
                return;
            }
            n.for_each_child(&mut |c| self.ic_states(c, out));
        }
    }
}

impl InitSystem {
    /// Analyse the initialization system of `flat`.
    pub(crate) fn of(flat: &FlattenedSystem) -> InitSystem {
        let mut sys = InitSystem {
            algebraic: flat.algebraic_variables.keys().cloned().collect(),
            ..Default::default()
        };
        sys.defaulted = flat
            .state_variables
            .iter()
            .filter(|(n, v)| {
                v.default.is_some()
                    && !sys.algebraic.contains(*n)
                    && !flat.observed_variables.contains_key(*n)
            })
            .map(|(n, _)| n.clone())
            .collect();
        let size = |s: &str| set_size(flat, s);

        // Explicit initial conditions: the cells each sets.
        for (target, rhs) in &flat.field_ics {
            let Some(ext) = state_extents(flat, target) else {
                continue;
            };
            let n: usize = ext.iter().product::<usize>().max(1);
            let mask = sys.explicit.entry(target.clone()).or_insert(vec![false; n]);
            mark_coverage(rhs, &ext, &size, mask);
            sys.extents.insert(target.clone(), ext);
        }

        let mut x = Expander::new(flat);
        for (k, eq) in flat.initialization_equations.iter().enumerate() {
            // A trajectory read in an equation that holds at t0 only (§11.4.2).
            if sys.refusal.is_none() {
                sys.refusal = trajectory_read(eq, &|n| x.is_state(n), &x.observed);
            }
            let lhs = x.expand(&eq.lhs, 0);
            let rhs = x.expand(&eq.rhs, 0);
            let mut mentions = BTreeSet::new();
            x.ic_states(&lhs, &mut mentions);
            x.ic_states(&rhs, &mut mentions);
            for m in &mentions {
                if !sys.extents.contains_key(m)
                    && let Some(ext) = state_extents(flat, m)
                {
                    sys.extents.insert(m.clone(), ext);
                }
            }
            // `ic(u) ~ e`, or `e ~ ic(u)`, `u` a state and `e` (expanded) not
            // reading `ic(u)`.
            let solved = ic_side([(&eq.lhs, &rhs), (&eq.rhs, &lhs)], |u, other| {
                x.is_state(u) && !mentions_ic_of(other, u)
            });
            let raw_value = |u: &str| {
                if ic_name(&eq.lhs) == Some(u) {
                    &eq.rhs
                } else {
                    &eq.lhs
                }
            };
            let n_scalar = match solved {
                Some((u, _)) => faq_box(raw_value(u), &size).cells().unwrap_or_else(|| {
                    sys.extents
                        .get(u)
                        .map_or(1, |e| e.iter().product::<usize>().max(1))
                }),
                None => faq_box(&eq.lhs, &size)
                    .cells()
                    .or_else(|| faq_box(&eq.rhs, &size).cells())
                    .unwrap_or_else(|| union_size(flat, &[&eq.lhs, &eq.rhs])),
            };
            sys.equations.push(SystemEquation {
                equation: eq.clone(),
                origin: flat.initialization_origins.get(k).cloned().unwrap_or(
                    TermOrigin::Component {
                        component: String::new(),
                    },
                ),
                eval_rhs: solved.map(|(_, value)| read_ic_as_value(value)),
                target: solved.map(|(u, _)| u.to_string()),
                mentions,
                n_scalar,
            });
        }
        if sys.refusal.is_none()
            && let Some(why) = x.unsupported
        {
            sys.refusal = Some(Refusal::Unsupported(why));
        }
        sys
    }

    /// The `ic_reads_state` refusal of an initialization equation that reads
    /// a state's trajectory value (esm-spec §11.4.2), if any.
    pub(crate) fn reads_state(&self) -> Option<SimulateError> {
        self.refusal
            .as_ref()
            .filter(|r| matches!(r, Refusal::ReadsState { .. }))
            .map(Refusal::error)
    }

    /// Whether there is nothing to check or evaluate.
    pub(crate) fn is_empty(&self) -> bool {
        self.equations.is_empty() && self.refusal.is_none()
    }

    /// The equations in solved form, in equation order: the steps a build
    /// compiles. [`Self::plan`] picks the ones it evaluates, and their order.
    pub(crate) fn solved_equations(&self) -> Vec<usize> {
        (0..self.equations.len())
            .filter(|&k| self.equations[k].target.is_some())
            .collect()
    }

    /// The steps of [`Self::solved_equations`] as equations `u ~ e`, in the
    /// same order, with every `ic(w)` read as `w`.
    pub(crate) fn step_equations(&self) -> Vec<Equation> {
        self.solved_equations()
            .into_iter()
            .map(|k| {
                let e = &self.equations[k];
                Equation {
                    lhs: Expr::Variable(e.target.clone().unwrap_or_default()),
                    rhs: e.eval_rhs.clone().unwrap_or(Expr::Integer(0)),
                    comment: None,
                }
            })
            .collect()
    }

    fn extent(&self, w: &str) -> usize {
        self.extents
            .get(w)
            .map_or(1, |e| e.iter().product::<usize>().max(1))
    }

    /// The system under the supplied values (`supplied`: per state, the
    /// cells a caller's `u0` or a run-time override sets, column-major), in
    /// the order §11.4.3 runs its checks: the structural refusals, the
    /// balance, then the order of the solved equations and the implicit part
    /// they leave. `algebraic_stripped`: the caller took the algebraic
    /// equations (`strip` class `algebraic`), so the starting value of an
    /// algebraic unknown no explicit initial condition sets is the caller's,
    /// and an equation that reads it belongs to the implicit part.
    pub(crate) fn plan(
        &self,
        supplied: &HashMap<String, Vec<usize>>,
        algebraic_stripped: bool,
    ) -> Result<InitPlan, SimulateError> {
        if let Some(r) = &self.refusal {
            return Err(r.error());
        }
        if self.equations.is_empty() {
            return Ok(InitPlan::default());
        }
        let vars: BTreeSet<&str> = self
            .equations
            .iter()
            .flat_map(|e| e.mentions.iter().map(String::as_str))
            .collect();
        // Known cells: the explicit initial conditions and the supplied
        // values of ODE states.
        let mut known: HashMap<&str, Vec<bool>> = HashMap::new();
        let mut known_by_supply: Vec<&str> = Vec::new();
        for &w in &vars {
            let n = self.extent(w);
            let mut mask = self.explicit.get(w).cloned().unwrap_or(vec![false; n]);
            mask.resize(n, false);
            if !self.algebraic.contains(w)
                && let Some(cells) = supplied.get(w)
            {
                let mut hit = false;
                for &i in cells {
                    if i < n && !mask[i] {
                        mask[i] = true;
                        hit = true;
                    }
                }
                if hit {
                    known_by_supply.push(w);
                }
            }
            known.insert(w, mask);
        }
        // A solved-form equation is explicit in its target only while no cell
        // of the target is known already (esm-spec §11.4.3).
        let target_of = |k: usize| {
            self.equations[k]
                .target
                .as_deref()
                .filter(|t| known.get(t).is_none_or(|m| m.iter().all(|&b| !b)))
        };
        let targets: HashSet<&str> = (0..self.equations.len()).filter_map(target_of).collect();
        let held = |w: &str| algebraic_stripped && self.algebraic.contains(w);
        // The cells of each mentioned state that are unknowns of the system.
        let unknown_cells: HashMap<&str, Vec<usize>> = vars
            .iter()
            .map(|&w| {
                let default_known = self.defaulted.contains(w) && !targets.contains(w);
                let cells = if held(w) || default_known {
                    Vec::new()
                } else {
                    (0..self.extent(w)).filter(|&i| !known[w][i]).collect()
                };
                (w, cells)
            })
            .collect();
        self.balance(&vars, &unknown_cells, &known_by_supply)?;

        // Order the effective solved equations by dependency.
        let mut done: HashSet<&str> = HashSet::new();
        let mut placed = vec![false; self.equations.len()];
        let mut order = Vec::new();
        loop {
            let mut progressed = false;
            for (k, (e, is_placed)) in self.equations.iter().zip(placed.iter_mut()).enumerate() {
                let Some(me) = target_of(k) else { continue };
                if *is_placed || done.contains(me) {
                    continue;
                }
                let ready = e.mentions.iter().all(|w| {
                    let w = w.as_str();
                    w == me || done.contains(w) || (!held(w) && unknown_cells[w].is_empty())
                });
                if ready {
                    *is_placed = true;
                    order.push(k);
                    done.insert(me);
                    progressed = true;
                }
            }
            if !progressed {
                break;
            }
        }
        let removed: Vec<usize> = (0..self.equations.len()).filter(|&k| !placed[k]).collect();
        let mut unknowns: BTreeMap<String, Vec<usize>> = BTreeMap::new();
        for &k in &removed {
            for w in &self.equations[k].mentions {
                let cells = &unknown_cells[w.as_str()];
                if !done.contains(w.as_str()) && !cells.is_empty() {
                    unknowns.insert(w.clone(), cells.clone());
                }
            }
        }
        Ok(InitPlan {
            order,
            removed,
            unknowns,
        })
    }

    /// [`Self::plan`], refusing an implicit part the caller did not take
    /// (`strip_initialization`) with `unsupported_construct`.
    pub(crate) fn check(
        &self,
        supplied: &HashMap<String, Vec<usize>>,
        algebraic_stripped: bool,
        strip_initialization: bool,
    ) -> Result<InitPlan, SimulateError> {
        let plan = self.plan(supplied, algebraic_stripped)?;
        if plan.has_implicit_part() && !strip_initialization {
            let eqs: Vec<String> = plan
                .removed
                .iter()
                .map(|&k| self.equations[k].shown())
                .collect();
            return Err(unsupported(format!(
                "{} (esm-spec §11.4.3: it must be solved simultaneously, or is not explicit in \
                 its unknown, and this binding has no nonlinear solver; a caller that solves it \
                 asks for it with `strip` class `initialization`)",
                eqs.join(", ")
            )));
        }
        Ok(plan)
    }

    /// The balance of §11.4.3: as many scalar equations as scalar unknowns,
    /// and an assignment of a distinct equation to every unknown (a maximum
    /// flow: source → equation (its scalar count) → each state with unknown
    /// cells it mentions → sink (its unknown count)).
    fn balance(
        &self,
        vars: &BTreeSet<&str>,
        unknown_cells: &HashMap<&str, Vec<usize>>,
        known_by_supply: &[&str],
    ) -> Result<(), SimulateError> {
        let vars: Vec<&str> = vars
            .iter()
            .copied()
            .filter(|w| !unknown_cells[w].is_empty())
            .collect();
        let n_unknown = |w: &str| unknown_cells[w].len();
        let total_eq: usize = self.equations.iter().map(|e| e.n_scalar).sum();
        let total_unk: usize = vars.iter().map(|w| n_unknown(w)).sum();

        let ne = self.equations.len();
        let nv = vars.len();
        let (src, sink) = (0usize, 1 + ne + nv);
        let n_nodes = sink + 1;
        let mut cap = vec![vec![0usize; n_nodes]; n_nodes];
        let var_ix: HashMap<&str, usize> = vars
            .iter()
            .enumerate()
            .map(|(i, w)| (*w, 1 + ne + i))
            .collect();
        for (k, e) in self.equations.iter().enumerate() {
            cap[src][1 + k] = e.n_scalar;
            for w in &e.mentions {
                if let Some(&j) = var_ix.get(w.as_str()) {
                    cap[1 + k][j] = usize::MAX / 4;
                }
            }
        }
        for (i, w) in vars.iter().enumerate() {
            cap[1 + ne + i][sink] = n_unknown(w);
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
        let left_unknowns: Vec<&str> = vars
            .iter()
            .enumerate()
            .filter(|(i, _)| cap[1 + ne + i][sink] > 0)
            .map(|(_, w)| *w)
            .collect();
        let left_equations: Vec<String> = self
            .equations
            .iter()
            .enumerate()
            .filter(|(k, _)| cap[src][1 + k] > 0)
            .map(|(_, e)| e.shown())
            .collect();
        let none = |v: Vec<String>| {
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
            none(left_unknowns.iter().map(|w| w.to_string()).collect()),
            none(left_equations)
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
        details.push_str(
            " A `default` is never an equation of the system: an ODE state's default is a \
             known unless an equation is in solved form for that state (esm-spec §11.4.3, \
             \"Declared defaults\").",
        );
        Err(SimulateError::IcSystemUnbalanced { details })
    }
}

/// `ic_reads_state` for an initialization equation that reads a state's
/// trajectory value outside `ic`: bare, as `D(w)`, or through observeds.
fn trajectory_read(
    eq: &Equation,
    is_state: &dyn Fn(&str) -> bool,
    observed_defs: &HashMap<&str, &Expr>,
) -> Option<Refusal> {
    let name = ic_subject(eq);
    let shown = format!("`{} ~ {}`", eq.lhs, eq.rhs);
    let refusal = |details: String| {
        Some(Refusal::ReadsState {
            name: name.clone(),
            details,
        })
    };
    for side in [&eq.lhs, &eq.rhs] {
        let out = outside_ic(side);
        if let Some(x) = holds_time_derivative(&out) {
            return refusal(format!(
                "appears in an initialization equation ({shown} mentions `ic`, so it holds at \
                 t0 only) that reads `D({x})` outside `ic`, a state's trajectory value. Write \
                 `ic(D({x}))` for the tendency at the start, and keep dynamics out of \
                 initialization equations (esm-spec §11.4.2)"
            ));
        }
        let mut reads: Vec<String> = free(&out).into_iter().collect();
        reads.sort();
        for r in reads {
            if is_state(&r) {
                return refusal(format!(
                    "reads '{r}', a state, outside `ic` (in {shown}, an initialization \
                     equation, which holds at t0 only); its starting value is `ic({r})` \
                     (esm-spec §11.4.2)"
                ));
            }
            let mut chain = vec![r.clone()];
            let mut seen = HashSet::new();
            if let Some(s) = observed_chain(&r, is_state, observed_defs, &mut chain, &mut seen) {
                return refusal(format!(
                    "reads '{}', which reads '{s}', a state, outside `ic` (esm-spec §11.4.2)",
                    chain.join("', which reads '")
                ));
            }
        }
    }
    None
}

fn observed_chain(
    n: &str,
    is_state: &dyn Fn(&str) -> bool,
    defs: &HashMap<&str, &Expr>,
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
        if defs.contains_key(r.as_str()) {
            chain.push(r.clone());
            if let Some(s) = observed_chain(&r, is_state, defs, chain, seen) {
                return Some(s);
            }
            chain.pop();
        }
    }
    None
}

/// Size of an index set of `flat`: its `size`, else its member count.
pub(crate) fn set_size(flat: &FlattenedSystem, set: &str) -> Option<usize> {
    index_set_size(flat.index_sets.get(set)?)
}

/// Size of an index set: its `size`, else its member count.
pub(crate) fn index_set_size(s: &crate::types::IndexSet) -> Option<usize> {
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
pub(crate) fn state_extents(flat: &FlattenedSystem, name: &str) -> Option<Vec<usize>> {
    let sets = var_sets(flat, name)?;
    sets.iter().map(|s| set_size(flat, s)).collect()
}

/// The element count of the union, by name, of the index sets of every
/// variable an equation reads (§11.4.3 "Arrays"); an operand consumed by
/// `index` contributes none.
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

#[cfg(test)]
mod tests {
    use super::*;

    fn eq(lhs: serde_json::Value, rhs: serde_json::Value) -> Equation {
        Equation {
            lhs: serde_json::from_value(lhs).unwrap(),
            rhs: serde_json::from_value(rhs).unwrap(),
            comment: None,
        }
    }

    #[test]
    fn read_ic_as_value_reads_states_by_name() {
        let e: Expr = serde_json::from_value(serde_json::json!(
            {"op": "+", "args": [{"op": "ic", "args": ["x"]}, 1]}
        ))
        .unwrap();
        assert!(mentions_ic(&e));
        assert!(!mentions_ic(&read_ic_as_value(&e)));
    }

    #[test]
    fn explicit_form_reads_both_spellings() {
        let ic = |v: &str| serde_json::json!({"op": "ic", "args": [v]});
        let e = eq(ic("u"), serde_json::json!(1));
        assert_eq!(explicit_form(&e).map(|(u, _)| u), Some("u"));
        let m = eq(serde_json::json!(2), ic("u"));
        assert_eq!(explicit_form(&m).map(|(u, _)| u), Some("u"));
        let sys = eq(ic("a"), ic("b"));
        assert!(explicit_form(&sys).is_none());
        assert_eq!(ic_subject(&sys), "a");
    }

    #[test]
    fn faq_box_reads_index_set_ranges() {
        let e: Expr = serde_json::from_value(serde_json::json!(
            {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "n"}},
             "expr": "i"}
        ))
        .unwrap();
        let size = |s: &str| (s == "n").then_some(3);
        assert_eq!(faq_box(&e, &size).cells(), Some(3));
        let none = |_: &str| None;
        assert!(matches!(faq_box(&e, &none), FaqBox::Unreadable));
        let mut mask = vec![false; 3];
        mark_coverage(&e, &[3], &size, &mut mask);
        assert_eq!(mask, [true, true, true]);
    }
}
