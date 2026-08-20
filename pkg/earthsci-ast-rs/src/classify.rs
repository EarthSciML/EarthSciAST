//! Classification: the finer solver categories, DERIVED (esm-spec §6.3.1).
//!
//! esm 1.0.0 declares exactly two variable types, `unknown` and `parameter`.
//! Everything else a solver needs — which unknowns are ODE states, which
//! parameters are Brownian or discrete — is recovered from the model's
//! equations and its parameters' `update` blocks by the functions here.
//!
//! These are the *only* sanctioned way to ask those questions. A site that
//! used to branch on `variable.type == "state"` calls [`is_ode_state`]; one
//! that branched on `"observed"` calls [`observed_unknowns`]. Reading a
//! declared type to answer a derived question is precisely what 1.0.0 removes.
//!
//! Two partition invariants hold and are asserted in the tests:
//!
//! - [`ode_states`] + [`observed_unknowns`] + [`algebraic_unknowns`]
//!   == the model's unknowns, disjointly.
//! - [`brownian_parameters`] + [`discrete_parameters`] + [`sampled_parameters`]
//!   + [`constant_parameters`] == the model's parameters, disjointly.
//!
//! Every returned list is sorted lexicographically by UTF-8 code point, so a
//! comparison against the cross-language goldens in
//! `tests/conformance/classification/` is order-independent.

use crate::types::{Equation, Expr, Model, VariableType};
use std::collections::BTreeSet;

/// The derived kind of system a model represents (esm-spec §6.3.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SystemKind {
    /// Any Brownian parameter is present.
    Sde,
    /// No time-derivative equation at all.
    Nonlinear,
    /// A spatial domain plus differential operators.
    Pde,
    /// The default: at least one time derivative, no noise.
    Ode,
}

impl SystemKind {
    /// The discriminator as the `system_kind` field spells it.
    pub fn as_str(self) -> &'static str {
        match self {
            SystemKind::Sde => "sde",
            SystemKind::Nonlinear => "nonlinear",
            SystemKind::Pde => "pde",
            SystemKind::Ode => "ode",
        }
    }
}

impl std::fmt::Display for SystemKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

// ---------------------------------------------------------------------------
// LHS shape analysis
// ---------------------------------------------------------------------------

/// The base variable an equation LHS ultimately writes, when the LHS is a
/// STRUCTURAL time derivative.
///
/// `wrt: "t"` and an absent `wrt` both mean the structural time derivative
/// (esm-spec §4.2); a spatial `wrt` is a rewrite target and never credits an
/// ODE state. The derivative may be wrapped: `D(u)`, `D(u[i])`, and an
/// `aggregate` whose `expr` is a `D(...)` all credit `u`.
fn time_derivative_base(expr: &Expr) -> Option<&str> {
    let Expr::Operator(node) = expr else {
        return None;
    };
    match node.op.as_str() {
        "D" => {
            let is_time = node.wrt.as_deref().map(|w| w == "t").unwrap_or(true);
            if !is_time {
                return None;
            }
            node.args.first().and_then(base_variable)
        }
        // An aggregate/arrayop wrapping a derivative writes the derivative's
        // base once per index tuple; the base is still an ODE state.
        "aggregate" | "arrayop" => node.expr.as_deref().and_then(time_derivative_base),
        _ => None,
    }
}

/// The base variable of an lvalue-shaped expression: a bare name, or a name
/// under index/selection wrappers that do not change WHICH variable is written.
fn base_variable(expr: &Expr) -> Option<&str> {
    match expr {
        Expr::Variable(name) => Some(name.as_str()),
        Expr::Operator(node) => match node.op.as_str() {
            "index" | "broadcast" | "reshape" | "transpose" => {
                node.args.first().and_then(base_variable)
            }
            _ => None,
        },
        _ => None,
    }
}

/// The variable an equation defines when its LHS is a BARE variable (possibly
/// indexed) rather than a derivative or a compound expression.
///
/// `y ~ f(...)` and `y[i] ~ f(...)` define `y`; `H*H*SO4 ~ Ksp` defines
/// nothing (it is an implicit constraint), and `D(u,t) ~ ...` is handled by
/// [`time_derivative_base`].
fn bare_lhs_base(expr: &Expr) -> Option<&str> {
    // `ic(u) ~ <field>` declares an initial condition, not a defining
    // equation for u, so it must not make u observed.
    if let Expr::Operator(node) = expr {
        if node.op == "ic" {
            return None;
        }
    }
    if time_derivative_base(expr).is_some() {
        return None;
    }
    base_variable(expr)
}

/// True when this equation's LHS is a structural time derivative.
fn is_time_derivative_equation(eq: &Equation) -> bool {
    time_derivative_base(&eq.lhs).is_some()
}

// ---------------------------------------------------------------------------
// Unknowns
// ---------------------------------------------------------------------------

fn equations_of(model: &Model) -> &[Equation] {
    model.equations.as_slice()
}

/// Names declared with `type: "unknown"`, sorted.
fn declared_unknowns(model: &Model) -> BTreeSet<&str> {
    declared_of_type(model, VariableType::Unknown)
}

/// Names declared with `type: "parameter"`, sorted.
fn declared_parameters(model: &Model) -> BTreeSet<&str> {
    declared_of_type(model, VariableType::Parameter)
}

fn declared_of_type(model: &Model, want: VariableType) -> BTreeSet<&str> {
    model
        .variables
        .iter()
        .filter(|(_, v)| v.var_type == want)
        .map(|(k, _)| k.as_str())
        .collect()
}

/// Unknowns appearing under `D(·, t)` on some equation LHS (esm-spec §6.3.1).
pub fn ode_states(model: &Model) -> Vec<String> {
    let unknowns = declared_unknowns(model);
    let mut out = BTreeSet::new();
    for eq in equations_of(model) {
        if let Some(base) = time_derivative_base(&eq.lhs) {
            if unknowns.contains(base) {
                out.insert(base);
            }
        }
    }
    to_owned_sorted(out)
}

/// Membership test for [`ode_states`].
pub fn is_ode_state(model: &Model, name: &str) -> bool {
    let unknowns = declared_unknowns(model);
    if !unknowns.contains(name) {
        return false;
    }
    equations_of(model)
        .iter()
        .any(|eq| time_derivative_base(&eq.lhs) == Some(name))
}

/// Unknowns defined by a bare-variable LHS (`y ~ f(…)`) — eliminable,
/// materializable (esm-spec §6.3.1).
///
/// An unknown that ALSO has a derivative equation is an ODE state, not an
/// observed: the three sets partition, and `ode_states` wins.
pub fn observed_unknowns(model: &Model) -> Vec<String> {
    let unknowns = declared_unknowns(model);
    let states: BTreeSet<String> = ode_states(model).into_iter().collect();
    let mut out = BTreeSet::new();
    for eq in equations_of(model) {
        if let Some(base) = bare_lhs_base(&eq.lhs) {
            if unknowns.contains(base) && !states.contains(base) {
                out.insert(base);
            }
        }
    }
    to_owned_sorted(out)
}

/// The DEFINING equation RHS of each observed unknown, in equation order.
///
/// Since 1.0.0 an unknown's behaviour is stated by an equation and nowhere
/// else, so this replaces every 0.x read of `variables[v].expression`. The
/// cadence pass in particular seeds an observed leaf from the class of the
/// expression returned here (CONFORMANCE_SPEC §5.7.2).
pub fn observed_definitions(model: &Model) -> Vec<(&str, &Expr)> {
    let unknowns = declared_unknowns(model);
    let states: BTreeSet<String> = ode_states(model).into_iter().collect();
    let mut out = Vec::new();
    for eq in equations_of(model) {
        if let Some(base) = bare_lhs_base(&eq.lhs) {
            if unknowns.contains(base) && !states.contains(base) {
                out.push((base, &eq.rhs));
            }
        }
    }
    out
}

/// The defining RHS of one observed unknown, if it has one.
pub fn observed_definition<'a>(model: &'a Model, name: &str) -> Option<&'a Expr> {
    observed_definitions(model)
        .into_iter()
        .find(|(n, _)| *n == name)
        .map(|(_, e)| e)
}

/// Unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`) — the remainder of
/// the unknowns once ODE states and observeds are taken out (esm-spec §6.3.1).
pub fn algebraic_unknowns(model: &Model) -> Vec<String> {
    let states: BTreeSet<String> = ode_states(model).into_iter().collect();
    let observed: BTreeSet<String> = observed_unknowns(model).into_iter().collect();
    let mut out = BTreeSet::new();
    for name in declared_unknowns(model) {
        if !states.contains(name) && !observed.contains(name) {
            out.insert(name);
        }
    }
    to_owned_sorted(out)
}

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

/// Parameters whose update is `kind: "wiener"` — the SDE noise sources
/// (esm-spec §6.3.1).
pub fn brownian_parameters(model: &Model) -> Vec<String> {
    parameters_where(model, |v| {
        v.update.as_ref().is_some_and(|u| u.is_brownian())
    })
}

/// Parameters carrying any update OTHER than `wiener` — piecewise-constant
/// between refreshes (esm-spec §6.3.1).
pub fn discrete_parameters(model: &Model) -> Vec<String> {
    parameters_where(model, |v| {
        v.update.as_ref().is_some_and(|u| !u.is_brownian())
    })
}

/// Parameters with a `distribution` and no `update` — drawn once at setup
/// (esm-spec §6.3.1).
pub fn sampled_parameters(model: &Model) -> Vec<String> {
    parameters_where(model, |v| {
        v.distribution.is_some() && v.update.is_none()
    })
}

/// Parameters with neither a `distribution` nor an `update` — plain constants
/// (esm-spec §6.3.1).
pub fn constant_parameters(model: &Model) -> Vec<String> {
    parameters_where(model, |v| {
        v.distribution.is_none() && v.update.is_none()
    })
}

fn parameters_where(
    model: &Model,
    pred: impl Fn(&crate::types::ModelVariable) -> bool,
) -> Vec<String> {
    let mut out = BTreeSet::new();
    for name in declared_parameters(model) {
        if let Some(v) = model.variables.get(name) {
            if pred(v) {
                out.insert(name);
            }
        }
    }
    to_owned_sorted(out)
}

// ---------------------------------------------------------------------------
// System kind
// ---------------------------------------------------------------------------

/// Derive what the `system_kind` field declares (esm-spec §6.3.1):
/// any Brownian parameter ⇒ `sde`; no time-derivative equation at all ⇒
/// `nonlinear`; a spatial domain plus differential operators ⇒ `pde`;
/// otherwise `ode`.
///
/// A binding uses this when the field is absent, and reports
/// `system_kind_mismatch` when a present field contradicts it.
pub fn system_kind(model: &Model) -> SystemKind {
    if !brownian_parameters(model).is_empty() {
        return SystemKind::Sde;
    }
    let has_time_derivative = equations_of(model).iter().any(is_time_derivative_equation);
    if !has_time_derivative {
        return SystemKind::Nonlinear;
    }
    if has_differential_operator(model) {
        return SystemKind::Pde;
    }
    SystemKind::Ode
}

/// True when some equation carries a NON-time (spatial) differential operator,
/// i.e. a rewrite-target `D` or one of the vector-calculus ops.
///
/// The spec phrases the PDE case as "a spatial domain plus differential
/// operators". `domain` is a DOCUMENT-level field while this function is a
/// pure function of one MODEL (esm-spec §6.3.1 fixes the signature), so the
/// spatial operator is the model-local evidence: a `D` with a spatial `wrt`,
/// or a vector-calculus op, only makes sense against a spatial domain.
fn has_differential_operator(model: &Model) -> bool {
    equations_of(model)
        .iter()
        .any(|eq| expr_has_spatial_operator(&eq.lhs) || expr_has_spatial_operator(&eq.rhs))
}

fn expr_has_spatial_operator(expr: &Expr) -> bool {
    let Expr::Operator(node) = expr else {
        return false;
    };
    let here = match node.op.as_str() {
        // A `D` with a spatial `wrt` is a rewrite target, never the structural
        // time derivative.
        "D" => node.wrt.as_deref().is_some_and(|w| w != "t"),
        "grad" | "div" | "curl" | "laplacian" | "integral" => true,
        _ => false,
    };
    here || node
        .args
        .iter()
        .chain(node.expr.as_deref())
        .chain(node.lower.as_deref())
        .chain(node.upper.as_deref())
        .any(expr_has_spatial_operator)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn to_owned_sorted(set: BTreeSet<&str>) -> Vec<String> {
    set.into_iter().map(str::to_string).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model(json: serde_json::Value) -> Model {
        serde_json::from_value(json).expect("fixture model should deserialize")
    }

    /// The esm-spec §6.3.1 worked example.
    fn worked_example() -> Model {
        model(serde_json::json!({
            "variables": {
                "c":     { "type": "unknown",   "units": "kg" },
                "v_dep": { "type": "unknown",   "units": "m/s" },
                "SO4":   { "type": "unknown",   "units": "mol" },
                "k":     { "type": "parameter", "units": "1/s", "default": 0.1 },
                "eps":   { "type": "parameter", "units": "1/s^0.5",
                           "distribution": { "kind": "normal", "mean": 0.0, "std": 1.0 },
                           "update": { "kind": "wiener" } }
            },
            "equations": [
                { "lhs": { "op": "D", "args": ["c"], "wrt": "t" },
                  "rhs": { "op": "*", "args": ["k", "c", "eps"] } },
                { "lhs": "v_dep", "rhs": { "op": "/", "args": [1, "k"] } },
                { "lhs": { "op": "*", "args": ["SO4", "SO4"] }, "rhs": "k" }
            ]
        }))
    }

    #[test]
    fn worked_example_partitions_as_the_spec_says() {
        let m = worked_example();
        assert_eq!(ode_states(&m), vec!["c"]);
        assert_eq!(observed_unknowns(&m), vec!["v_dep"]);
        assert_eq!(algebraic_unknowns(&m), vec!["SO4"]);
        assert_eq!(brownian_parameters(&m), vec!["eps"]);
        assert_eq!(constant_parameters(&m), vec!["k"]);
        assert!(discrete_parameters(&m).is_empty());
        assert!(sampled_parameters(&m).is_empty());
        assert_eq!(system_kind(&m), SystemKind::Sde);
        assert!(is_ode_state(&m, "c"));
        assert!(!is_ode_state(&m, "v_dep"));
        assert!(!is_ode_state(&m, "k"));
    }

    #[test]
    fn the_three_unknown_sets_partition() {
        let m = worked_example();
        let mut all: Vec<String> = ode_states(&m);
        all.extend(observed_unknowns(&m));
        all.extend(algebraic_unknowns(&m));
        let uniq: BTreeSet<&String> = all.iter().collect();
        assert_eq!(uniq.len(), all.len(), "unknown sets must be disjoint");
        let declared: BTreeSet<String> = declared_unknowns(&m)
            .into_iter()
            .map(str::to_string)
            .collect();
        assert_eq!(
            all.into_iter().collect::<BTreeSet<_>>(),
            declared,
            "unknown sets must cover every declared unknown"
        );
    }

    #[test]
    fn the_four_parameter_sets_partition() {
        let m = worked_example();
        let mut all: Vec<String> = brownian_parameters(&m);
        all.extend(discrete_parameters(&m));
        all.extend(sampled_parameters(&m));
        all.extend(constant_parameters(&m));
        let uniq: BTreeSet<&String> = all.iter().collect();
        assert_eq!(uniq.len(), all.len(), "parameter sets must be disjoint");
        let declared: BTreeSet<String> = declared_parameters(&m)
            .into_iter()
            .map(str::to_string)
            .collect();
        assert_eq!(
            all.into_iter().collect::<BTreeSet<_>>(),
            declared,
            "parameter sets must cover every declared parameter"
        );
    }

    #[test]
    fn a_distribution_alone_is_sampled_not_brownian() {
        let m = model(serde_json::json!({
            "variables": {
                "s": { "type": "parameter", "units": "1",
                       "distribution": { "kind": "uniform", "low": 0.0, "high": 1.0 } },
                "w": { "type": "parameter", "units": "1",
                       "distribution": { "kind": "normal", "mean": 0.0, "std": 1.0 },
                       "update": { "kind": "wiener" } }
            },
            "equations": []
        }));
        assert_eq!(sampled_parameters(&m), vec!["s"]);
        assert_eq!(brownian_parameters(&m), vec!["w"]);
        assert!(discrete_parameters(&m).is_empty());
    }

    #[test]
    fn any_non_wiener_update_is_discrete() {
        let m = model(serde_json::json!({
            "variables": {
                "p_cond": { "type": "parameter", "units": "1", "default": 0.0,
                            "update": { "kind": "condition", "when": true,
                                        "expression": 1.0 } },
                "p_data": { "type": "parameter", "units": "1", "default": 0.0,
                            "shape": [],
                            "update": { "kind": "data", "source": "S",
                                        "from": { "file_variable": "x" } } }
            },
            "equations": []
        }));
        let mut d = discrete_parameters(&m);
        d.sort();
        assert_eq!(d, vec!["p_cond", "p_data"]);
        assert!(brownian_parameters(&m).is_empty());
    }

    #[test]
    fn an_update_array_is_discrete_and_ordered() {
        let m = model(serde_json::json!({
            "variables": {
                "p": { "type": "parameter", "units": "1", "default": 0.0,
                       "update": [
                           { "kind": "condition", "when": true, "expression": 1.0 },
                           { "kind": "condition", "when": false, "expression": 2.0 }
                       ] }
            },
            "equations": []
        }));
        assert_eq!(discrete_parameters(&m), vec!["p"]);
        assert!(brownian_parameters(&m).is_empty());
        let spec = m.variables["p"].update.as_ref().unwrap();
        assert_eq!(spec.rules().len(), 2, "declaration order is preserved");
    }

    #[test]
    fn a_wrapped_derivative_still_credits_an_ode_state() {
        // D(u[i]) and an aggregate over D(...) both credit `u`.
        let m = model(serde_json::json!({
            "variables": {
                "u": { "type": "unknown", "units": "1", "shape": ["cells"] },
                "v": { "type": "unknown", "units": "1", "shape": ["cells"] }
            },
            "equations": [
                { "lhs": { "op": "D",
                           "args": [{ "op": "index", "args": ["u", "i"] }],
                           "wrt": "t" },
                  "rhs": 0.0 },
                { "lhs": { "op": "aggregate", "output_idx": ["i"],
                           "expr": { "op": "D", "args": ["v"], "wrt": "t" } },
                  "rhs": 0.0 }
            ]
        }));
        let mut s = ode_states(&m);
        s.sort();
        assert_eq!(s, vec!["u", "v"]);
        assert!(observed_unknowns(&m).is_empty());
    }

    #[test]
    fn a_spatial_derivative_lhs_is_not_an_ode_state() {
        let m = model(serde_json::json!({
            "variables": { "u": { "type": "unknown", "units": "1" } },
            "equations": [
                { "lhs": { "op": "D", "args": ["u"], "wrt": "x" }, "rhs": 0.0 }
            ]
        }));
        assert!(ode_states(&m).is_empty());
        // No time derivative anywhere ⇒ nonlinear.
        assert_eq!(system_kind(&m), SystemKind::Nonlinear);
    }

    #[test]
    fn an_absent_wrt_means_the_time_derivative() {
        let m = model(serde_json::json!({
            "variables": { "u": { "type": "unknown", "units": "1" } },
            "equations": [{ "lhs": { "op": "D", "args": ["u"] }, "rhs": 0.0 }]
        }));
        assert_eq!(ode_states(&m), vec!["u"]);
        assert_eq!(system_kind(&m), SystemKind::Ode);
    }

    #[test]
    fn an_ic_lhs_does_not_make_an_unknown_observed() {
        let m = model(serde_json::json!({
            "variables": { "u": { "type": "unknown", "units": "1" } },
            "equations": [
                { "lhs": { "op": "D", "args": ["u"], "wrt": "t" }, "rhs": 0.0 },
                { "lhs": { "op": "ic", "args": ["u"] }, "rhs": 1.0 }
            ]
        }));
        assert_eq!(ode_states(&m), vec!["u"]);
        assert!(observed_unknowns(&m).is_empty());
    }

    #[test]
    fn nonlinear_derives_without_any_time_derivative() {
        let m = model(serde_json::json!({
            "variables": {
                "H":   { "type": "unknown", "units": "mol" },
                "SO4": { "type": "unknown", "units": "mol" },
                "Ksp": { "type": "parameter", "units": "mol^3", "default": 4.0 }
            },
            "equations": [
                { "lhs": "H", "rhs": { "op": "*", "args": ["SO4", 2.0] } },
                { "lhs": { "op": "*", "args": ["H", "H", "SO4"] }, "rhs": "Ksp" }
            ]
        }));
        assert_eq!(system_kind(&m), SystemKind::Nonlinear);
        assert_eq!(observed_unknowns(&m), vec!["H"]);
        assert_eq!(algebraic_unknowns(&m), vec!["SO4"]);
    }
}
