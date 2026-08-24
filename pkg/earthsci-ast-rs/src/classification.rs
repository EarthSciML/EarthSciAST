//! Derived variable classification (esm-spec §6.3.1).
//!
//! esm 1.0.0 declares **two** variable types, `unknown` and `parameter`.
//! Everything finer that a solver needs — which unknowns are ODE states, which
//! parameters are Brownian — is DERIVED from the equations and from each
//! parameter's `distribution` / `update`. This module is the single derivation
//! the whole binding shares: **no site may branch on a declared type to answer
//! a derived question**, which is precisely what 1.0.0 removes.
//!
//! Two partitions, pinned by `tests/conformance/classification/`:
//!
//! | Unknowns | |
//! |---|---|
//! | [`ode_states`] | appear under `D(·, t)` on some equation LHS |
//! | [`observed_unknowns`] | defined by a bare-variable LHS (`y ~ f(…)`) |
//! | [`algebraic_unknowns`] | constrained only implicitly (`H*H*SO4 ~ Ksp`) |
//!
//! | Parameters | |
//! |---|---|
//! | [`brownian_parameters`] | `update.kind == "wiener"` |
//! | [`discrete_parameters`] | any OTHER update |
//! | [`sampled_parameters`] | a `distribution` and no update |
//! | [`constant_parameters`] | neither |
//!
//! Both are partitions of the model's declared variables, asserted by
//! [`Classification::assert_partitions`] and by the conformance suite.
//!
//! Every list this module returns is sorted lexicographically by UTF-8 code
//! point, so the answer never depends on `HashMap` iteration order (the
//! conformance goldens compare order-independently for exactly that reason).

use crate::types::{Equation, Expr, Model, ModelVariable, VariableType};
use indexmap::IndexMap;
use std::collections::{BTreeMap, BTreeSet};

/// The `wrt` value naming the independent (time) variable.
const TIME: &str = "t";

/// Sugar ops that ARE a spatial derivative regardless of any `wrt`/`dim`
/// (esm-spec §4.2 calculus ops; the §6.3.1 `pde` test).
const SPATIAL_SUGAR_OPS: [&str; 3] = ["grad", "div", "laplacian"];

/// The derived system kind (esm-spec §6.3.1).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum SystemKind {
    /// Any Brownian parameter.
    Sde,
    /// Any equation contains a spatial derivative.
    Pde,
    /// No time-derivative equation at all.
    Nonlinear,
    /// Everything else.
    #[default]
    Ode,
}

impl SystemKind {
    /// The wire spelling of the kind, as the `system_kind` field carries it.
    pub fn as_str(self) -> &'static str {
        match self {
            SystemKind::Sde => "sde",
            SystemKind::Pde => "pde",
            SystemKind::Nonlinear => "nonlinear",
            SystemKind::Ode => "ode",
        }
    }
}

impl std::fmt::Display for SystemKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One model's complete §6.3.1 classification, computed once.
///
/// The free functions below ([`ode_states`], [`brownian_parameters`], …) are
/// thin wrappers over this; build it directly when a caller needs several sets,
/// so the equation walk happens once.
#[derive(Debug, Clone, Default)]
pub struct Classification {
    /// Unknowns appearing under `D(·, t)` on some equation LHS.
    pub ode_states: Vec<String>,
    /// Unknowns defined by a bare-variable OR indexed-variable LHS
    /// (esm-spec §6.3.1) — the semantic "defined by an equation" set.
    pub observed_unknowns: Vec<String>,
    /// The NARROWER set alongside [`Self::observed_unknowns`]: the observed
    /// unknowns whose defining LHS is a BARE variable, so they are eliminable
    /// **by inlining** (esm-spec §6.3.1, "Note that *eliminable* and
    /// *inlineable* are not the same thing"). An ARRAYED definition
    /// (`y[i] ~ f(i)`) is observed too, but it materializes into a buffer its
    /// consumers index rather than being substituted away, so it is NOT here.
    /// Spelled `inlined_unknowns` in the Python oracle; it does not narrow the
    /// §6.3.1 partition, it sits beside it.
    pub inlined_unknowns: Vec<String>,
    /// Unknowns constrained only implicitly.
    pub algebraic_unknowns: Vec<String>,
    /// Parameters whose update is `wiener`.
    pub brownian_parameters: Vec<String>,
    /// Parameters carrying any OTHER update.
    pub discrete_parameters: Vec<String>,
    /// Parameters with a distribution and no update.
    pub sampled_parameters: Vec<String>,
    /// Parameters with neither.
    pub constant_parameters: Vec<String>,
    /// The DERIVED system kind.
    pub system_kind: SystemKind,
    /// Each observed unknown's defining RHS, keyed by the unknown's name — the
    /// 1.0.0 home of what used to sit in `variables[v].expression`.
    pub observed_definitions: BTreeMap<String, Expr>,
}

impl Classification {
    /// Classify one model node. Classification is per MODEL NODE: a subsystem's
    /// equations classify the subsystem's variables, never the parent's.
    pub fn of(model: &Model) -> Classification {
        Self::from_parts(&model.variables, &model.equations)
    }

    /// Classify from the raw parts, for callers holding a variables map and an
    /// equation list rather than a whole [`Model`] (the JSON-level cadence
    /// pass, the flatten/compile pipelines).
    pub fn from_parts(
        variables: &IndexMap<String, ModelVariable>,
        equations: &[Equation],
    ) -> Classification {
        let mut ode_states = BTreeSet::new();
        let mut observed = BTreeSet::new();
        let mut inlined = BTreeSet::new();
        let mut observed_definitions = BTreeMap::new();

        let unknowns: BTreeSet<&str> = variables
            .iter()
            .filter(|(_, v)| v.var_type == VariableType::Unknown)
            .map(|(k, _)| k.as_str())
            .collect();

        for eq in equations {
            match lhs_form(&eq.lhs) {
                // `D(x)/dt ~ …`, including the wrapped spellings `D(x[i])` and
                // an `aggregate` whose `expr` is the derivative.
                LhsForm::Derivative(name) => {
                    if unknowns.contains(name.as_str()) {
                        ode_states.insert(name);
                    }
                }
                // `y ~ f(…)` / `y[i] ~ f(…)` — the LHS DEFINES y.
                LhsForm::Bare(name) => {
                    if unknowns.contains(name.as_str()) {
                        if !observed.contains(&name) {
                            observed_definitions.insert(name.clone(), eq.rhs.clone());
                        }
                        if matches!(eq.lhs, Expr::Variable(_)) {
                            inlined.insert(name.clone());
                        }
                        observed.insert(name);
                    }
                }
                // An expression LHS constrains its unknowns only implicitly.
                LhsForm::Expression => {}
            }
        }

        // An unknown that is BOTH differentiated somewhere and bare-LHS
        // elsewhere is an ODE state: the derivative is what the solver
        // integrates, and the partition must stay disjoint.
        for name in &ode_states {
            observed.remove(name);
            inlined.remove(name);
            observed_definitions.remove(name);
        }

        // The three sets partition the unknowns, so `algebraic` is exactly what
        // neither of the first two claimed. That also gives an unknown named by
        // NO equation a home — such a model is unbalanced and
        // `equation_count_mismatch` reports it, but it must not fall out of the
        // partition here.
        let algebraic: Vec<String> = unknowns
            .iter()
            .filter(|n| !ode_states.contains(**n) && !observed.contains(**n))
            .map(|n| (*n).to_string())
            .collect();

        let mut brownian = Vec::new();
        let mut discrete = Vec::new();
        let mut sampled = Vec::new();
        let mut constant = Vec::new();
        for (name, var) in variables {
            if var.var_type != VariableType::Parameter {
                continue;
            }
            match (&var.update, &var.distribution) {
                (Some(update), _) if update.is_wiener() => brownian.push(name.clone()),
                (Some(_), _) => discrete.push(name.clone()),
                (None, Some(_)) => sampled.push(name.clone()),
                (None, None) => constant.push(name.clone()),
            }
        }
        for set in [&mut brownian, &mut discrete, &mut sampled, &mut constant] {
            set.sort();
        }

        let system_kind = derive_system_kind(&brownian, equations, &ode_states);

        Classification {
            ode_states: ode_states.into_iter().collect(),
            observed_unknowns: observed.into_iter().collect(),
            inlined_unknowns: inlined.into_iter().collect(),
            algebraic_unknowns: algebraic,
            brownian_parameters: brownian,
            discrete_parameters: discrete,
            sampled_parameters: sampled,
            constant_parameters: constant,
            system_kind,
            observed_definitions,
        }
    }

    /// Classify a model held as raw JSON — the form the cadence-partition pass
    /// and the CLI work in.
    ///
    /// Reads only `variables` and `equations`, and IGNORES every other key, so
    /// a model carrying the document registries merged down onto it (as
    /// [`crate::cadence::model_with_loaders`] does) classifies the same as the
    /// bare one.
    ///
    /// A VARIABLE that does not deserialize is an error: mis-reading the
    /// declared type set is exactly the failure this module exists to prevent,
    /// and it would silently classify as "no variables". An individual
    /// EQUATION that does not deserialize is SKIPPED, because the passes that
    /// call this run over partially-lowered intermediate JSON whose
    /// well-formedness is the schema layer's business, not classification's.
    pub fn from_json(model: &serde_json::Value) -> Result<Classification, serde_json::Error> {
        let variables: IndexMap<String, ModelVariable> = match model.get("variables") {
            Some(v) => serde_json::from_value(v.clone())?,
            None => IndexMap::new(),
        };
        let equations: Vec<Equation> = model
            .get("equations")
            .and_then(|v| v.as_array())
            .map(|eqs| {
                eqs.iter()
                    .filter_map(|eq| serde_json::from_value::<Equation>(eq.clone()).ok())
                    .collect()
            })
            .unwrap_or_default();
        Ok(Classification::from_parts(&variables, &equations))
    }

    /// Membership test for [`Classification::ode_states`].
    pub fn is_ode_state(&self, name: &str) -> bool {
        self.ode_states.iter().any(|s| s == name)
    }

    /// Membership test for [`Classification::observed_unknowns`].
    pub fn is_observed(&self, name: &str) -> bool {
        self.observed_unknowns.iter().any(|s| s == name)
    }

    /// Membership test for [`Classification::inlined_unknowns`].
    pub fn is_inlined(&self, name: &str) -> bool {
        self.inlined_unknowns.iter().any(|s| s == name)
    }

    /// Membership test for [`Classification::brownian_parameters`].
    pub fn is_brownian(&self, name: &str) -> bool {
        self.brownian_parameters.iter().any(|s| s == name)
    }

    /// Membership test for [`Classification::discrete_parameters`].
    pub fn is_discrete_parameter(&self, name: &str) -> bool {
        self.discrete_parameters.iter().any(|s| s == name)
    }

    /// Every unknown of the model, sorted — the union of the three unknown
    /// sets.
    pub fn unknowns(&self) -> Vec<String> {
        let mut all: Vec<String> = self
            .ode_states
            .iter()
            .chain(&self.observed_unknowns)
            .chain(&self.algebraic_unknowns)
            .cloned()
            .collect();
        all.sort();
        all
    }

    /// Every parameter of the model, sorted — the union of the four parameter
    /// sets.
    pub fn parameters(&self) -> Vec<String> {
        let mut all: Vec<String> = self
            .brownian_parameters
            .iter()
            .chain(&self.discrete_parameters)
            .chain(&self.sampled_parameters)
            .chain(&self.constant_parameters)
            .cloned()
            .collect();
        all.sort();
        all
    }

    /// Assert the two §6.3.1 partition laws against the model this was derived
    /// from: the three unknown sets partition the unknowns, and the four
    /// parameter sets partition the parameters — both disjointly and totally.
    ///
    /// Returns the first violation as an `Err`, so a caller can surface it as a
    /// diagnostic rather than panicking.
    pub fn assert_partitions(&self, model: &Model) -> Result<(), String> {
        let declared_unknowns: BTreeSet<&str> = model
            .variables
            .iter()
            .filter(|(_, v)| v.var_type == VariableType::Unknown)
            .map(|(k, _)| k.as_str())
            .collect();
        let declared_parameters: BTreeSet<&str> = model
            .variables
            .iter()
            .filter(|(_, v)| v.var_type == VariableType::Parameter)
            .map(|(k, _)| k.as_str())
            .collect();

        let unknown_total: usize =
            self.ode_states.len() + self.observed_unknowns.len() + self.algebraic_unknowns.len();
        let unknown_union: BTreeSet<&str> = self
            .ode_states
            .iter()
            .chain(&self.observed_unknowns)
            .chain(&self.algebraic_unknowns)
            .map(String::as_str)
            .collect();
        if unknown_union.len() != unknown_total {
            return Err("unknown sets overlap: ode_states / observed_unknowns / \
                        algebraic_unknowns must be disjoint"
                .to_string());
        }
        if unknown_union != declared_unknowns {
            return Err(format!(
                "unknown sets do not cover the declared unknowns: got {unknown_union:?}, \
                 declared {declared_unknowns:?}"
            ));
        }

        let param_total: usize = self.brownian_parameters.len()
            + self.discrete_parameters.len()
            + self.sampled_parameters.len()
            + self.constant_parameters.len();
        let param_union: BTreeSet<&str> = self
            .brownian_parameters
            .iter()
            .chain(&self.discrete_parameters)
            .chain(&self.sampled_parameters)
            .chain(&self.constant_parameters)
            .map(String::as_str)
            .collect();
        if param_union.len() != param_total {
            return Err(
                "parameter sets overlap: brownian / discrete / sampled / constant \
                        must be disjoint"
                    .to_string(),
            );
        }
        if param_union != declared_parameters {
            return Err(format!(
                "parameter sets do not cover the declared parameters: got {param_union:?}, \
                 declared {declared_parameters:?}"
            ));
        }
        Ok(())
    }
}

// === The §6.3.1 API =======================================================

/// Unknowns appearing under `D(·, t)` on some equation LHS.
pub fn ode_states(model: &Model) -> Vec<String> {
    Classification::of(model).ode_states
}

/// Unknowns defined by a bare-variable LHS (`y ~ f(…)`) — eliminable,
/// materializable.
pub fn observed_unknowns(model: &Model) -> Vec<String> {
    Classification::of(model).observed_unknowns
}

/// The observed unknowns whose defining LHS is a BARE variable — the strict
/// `y ~ f(…)` form that is eliminable by INLINING (esm-spec §6.3.1). An arrayed
/// definition is observed but materializes into a buffer, so it is excluded.
pub fn inlined_unknowns(model: &Model) -> Vec<String> {
    Classification::of(model).inlined_unknowns
}

/// Unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`).
pub fn algebraic_unknowns(model: &Model) -> Vec<String> {
    Classification::of(model).algebraic_unknowns
}

/// Membership test for [`ode_states`].
pub fn is_ode_state(model: &Model, name: &str) -> bool {
    Classification::of(model).is_ode_state(name)
}

/// Parameters whose `update.kind` is `wiener` — the SDE noise sources.
pub fn brownian_parameters(model: &Model) -> Vec<String> {
    Classification::of(model).brownian_parameters
}

/// Parameters carrying any OTHER update — piecewise-constant between
/// refreshes.
pub fn discrete_parameters(model: &Model) -> Vec<String> {
    Classification::of(model).discrete_parameters
}

/// Parameters with a `distribution` and no update — drawn once at setup.
pub fn sampled_parameters(model: &Model) -> Vec<String> {
    Classification::of(model).sampled_parameters
}

/// Parameters with neither a distribution nor an update — plain constants.
pub fn constant_parameters(model: &Model) -> Vec<String> {
    Classification::of(model).constant_parameters
}

/// The DERIVED system kind (esm-spec §6.3.1), which a binding uses when the
/// `system_kind` field is absent and checks against when it is present.
pub fn system_kind(model: &Model) -> SystemKind {
    Classification::of(model).system_kind
}

/// Each observed unknown's defining RHS, keyed by name.
///
/// This is where an observed's definition lives from 1.0.0: the model's
/// `equations`, not a `variables[v].expression` field. Every site that used to
/// read that field reads this map instead.
pub fn observed_definitions(model: &Model) -> BTreeMap<String, Expr> {
    Classification::of(model).observed_definitions
}

/// An observed unknown's defining RHS, read from a model held as RAW JSON.
///
/// The JSON-view counterpart of [`observed_definitions`], for the passes and
/// tools that work on `serde_json::Value` (the cadence partition, the
/// projection-pushdown desugar, the CLI). It is the 1.0.0 replacement for
/// reading `model["variables"][name]["expression"]`, which no longer exists.
pub fn observed_definition_json<'a>(
    model: &'a serde_json::Value,
    name: &str,
) -> Option<&'a serde_json::Value> {
    model
        .get("equations")?
        .as_array()?
        .iter()
        .find(|eq| eq.get("lhs").and_then(serde_json::Value::as_str) == Some(name))?
        .get("rhs")
}

// === LHS forms ============================================================

/// What an equation's LHS says about the unknown it names (esm-spec §6.3.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LhsForm {
    /// A time derivative of the named base variable — an ODE state.
    Derivative(String),
    /// A bare variable — an observed (eliminable) definition.
    Bare(String),
    /// Anything else: an implicit algebraic constraint.
    Expression,
}

/// Classify an equation LHS.
///
/// A derivative LHS may be WRAPPED and still credits its base variable:
/// `D(u)`, `D(u[i])` (an `index` under the `D`), and an `aggregate` whose
/// `expr` is a `D(…)` — the arrayed spelling every discretized fixture uses.
/// The same unwrapping applies to a bare LHS, so `aggregate{expr: y[i]}` still
/// reads as a definition of `y`.
pub fn lhs_form(lhs: &Expr) -> LhsForm {
    match lhs {
        Expr::Variable(name) => LhsForm::Bare(name.clone()),
        Expr::Operator(node) => match node.op.as_str() {
            // `D(x)` / `D(x[i])`, time only: a `wrt` naming a SPATIAL
            // dimension is a spatial derivative and defines no ODE state.
            "D" if node.wrt.as_deref().unwrap_or(TIME) == TIME => node
                .args
                .first()
                .and_then(base_variable)
                .map(LhsForm::Derivative)
                .unwrap_or(LhsForm::Expression),
            // An `aggregate`/`arrayop` LHS is a shell around the real form.
            "aggregate" | "arrayop" => node
                .expr
                .as_deref()
                .map(lhs_form)
                .unwrap_or(LhsForm::Expression),
            // `u[i] ~ …` defines `u`.
            "index" => node
                .args
                .first()
                .and_then(base_variable)
                .map(LhsForm::Bare)
                .unwrap_or(LhsForm::Expression),
            _ => LhsForm::Expression,
        },
        Expr::Integer(_) | Expr::Number(_) => LhsForm::Expression,
    }
}

/// The base variable of an LHS operand, peeling the wrappers that do not
/// change WHICH quantity is being written: `index`, `aggregate`/`arrayop`
/// shells, and `broadcast`.
fn base_variable(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Variable(name) => Some(name.clone()),
        Expr::Operator(node) => match node.op.as_str() {
            "index" | "broadcast" => node.args.first().and_then(base_variable),
            "aggregate" | "arrayop" => node
                .expr
                .as_deref()
                .and_then(base_variable)
                .or_else(|| node.args.first().and_then(base_variable)),
            _ => None,
        },
        _ => None,
    }
}

// === system_kind ==========================================================

/// Derive the system kind, testing the four §6.3.1 conditions IN ORDER and
/// taking the first that holds. The order is normative: `pde` is tested before
/// `nonlinear` (a steady-state PDE has no time derivative but is still a PDE),
/// and `sde` before `pde` (there is no `SPDESystem` constructor to select).
fn derive_system_kind(
    brownian: &[String],
    equations: &[Equation],
    ode_states: &BTreeSet<String>,
) -> SystemKind {
    if !brownian.is_empty() {
        return SystemKind::Sde;
    }
    if equations
        .iter()
        .any(|eq| has_spatial_derivative(&eq.lhs) || has_spatial_derivative(&eq.rhs))
    {
        return SystemKind::Pde;
    }
    if ode_states.is_empty() && !equations.iter().any(|eq| has_time_derivative(&eq.lhs)) {
        return SystemKind::Nonlinear;
    }
    SystemKind::Ode
}

/// True when the expression contains a SPATIAL derivative anywhere: a `D` whose
/// `wrt` is present and is not `"t"`, or a `grad` / `div` / `laplacian` sugar
/// op. The walk descends EVERY expression child, not just `args` (§4.9.5).
pub fn has_spatial_derivative(expr: &Expr) -> bool {
    match expr {
        Expr::Operator(node) => {
            let here = (node.op == "D" && node.wrt.as_deref().is_some_and(|w| w != TIME))
                || SPATIAL_SUGAR_OPS.contains(&node.op.as_str());
            here || node.any_child(&mut has_spatial_derivative)
        }
        _ => false,
    }
}

/// True when the expression contains a TIME derivative anywhere.
fn has_time_derivative(expr: &Expr) -> bool {
    match expr {
        Expr::Operator(node) => {
            let here = node.op == "D" && node.wrt.as_deref().unwrap_or(TIME) == TIME;
            here || node.any_child(&mut has_time_derivative)
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model(json: serde_json::Value) -> Model {
        serde_json::from_value(json).expect("model deserializes")
    }

    /// The esm-spec §6.3.1 worked example, verbatim.
    #[test]
    fn worked_example() {
        let m = model(serde_json::json!({
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
        }));
        let c = Classification::of(&m);
        assert_eq!(c.ode_states, ["c"]);
        assert_eq!(c.observed_unknowns, ["v_dep"]);
        assert_eq!(c.algebraic_unknowns, ["SO4"]);
        assert_eq!(c.brownian_parameters, ["eps"]);
        assert_eq!(c.constant_parameters, ["k"]);
        assert!(c.sampled_parameters.is_empty());
        assert!(c.discrete_parameters.is_empty());
        assert_eq!(c.system_kind, SystemKind::Sde);
        c.assert_partitions(&m).expect("partitions hold");
    }

    /// A distribution WITHOUT an update is sampled, not Brownian; an update
    /// that is not `wiener` is discrete, whatever its kind.
    #[test]
    fn parameter_partition_discriminates_distribution_from_update() {
        let m = model(serde_json::json!({
            "variables": {
                "u":    { "type": "unknown", "units": "1" },
                "p":    { "type": "parameter", "units": "1", "default": 1.0 },
                "samp": { "type": "parameter", "units": "1",
                          "distribution": { "kind": "uniform", "low": 0.0, "high": 1.0 } },
                "cond": { "type": "parameter", "units": "1", "default": 1.0,
                          "update": { "kind": "condition",
                                      "when": { "op": ">", "args": ["u", 1.0] },
                                      "expression": 0.5 } },
                "w":    { "type": "parameter", "units": "1",
                          "distribution": { "kind": "normal", "mean": 0.0, "std": 1.0 },
                          "update": { "kind": "wiener" } }
            },
            "equations": [
                { "lhs": { "op": "D", "args": ["u"], "wrt": "t" }, "rhs": "p" }
            ]
        }));
        let c = Classification::of(&m);
        assert_eq!(c.brownian_parameters, ["w"]);
        assert_eq!(c.discrete_parameters, ["cond"]);
        assert_eq!(c.sampled_parameters, ["samp"]);
        assert_eq!(c.constant_parameters, ["p"]);
        c.assert_partitions(&m).expect("partitions hold");
    }

    /// An update ARRAY is discrete, never Brownian (the schema forbids
    /// `wiener` inside one, so the array form can only ever be discrete).
    #[test]
    fn update_array_is_discrete() {
        let m = model(serde_json::json!({
            "variables": {
                "u": { "type": "unknown", "units": "1" },
                "season": { "type": "parameter", "units": "1", "default": 1.0,
                    "update": [
                        { "kind": "condition", "when": { "op": "==", "args": ["u", 1] },
                          "expression": 1.0 },
                        { "kind": "condition", "when": { "op": "==", "args": ["u", 2] },
                          "expression": 2.0 }
                    ] }
            },
            "equations": [
                { "lhs": { "op": "D", "args": ["u"], "wrt": "t" }, "rhs": "season" }
            ]
        }));
        let c = Classification::of(&m);
        assert_eq!(c.discrete_parameters, ["season"]);
        assert!(c.brownian_parameters.is_empty());
    }

    /// A derivative LHS may be wrapped: `D(u[i])` and an `aggregate` whose
    /// `expr` is the derivative both credit `u`.
    #[test]
    fn wrapped_derivative_lhs_credits_the_base_variable() {
        let m = model(serde_json::json!({
            "variables": {
                "u": { "type": "unknown", "units": "1", "shape": ["cells"] },
                "k": { "type": "parameter", "units": "1/s", "default": 1.0 }
            },
            "equations": [
                { "lhs": { "op": "aggregate", "output_idx": ["i"],
                           "ranges": { "i": { "from": "cells" } },
                           "args": ["u"],
                           "expr": { "op": "D",
                                     "args": [{ "op": "index", "args": ["u", "i"] }],
                                     "wrt": "t" } },
                  "rhs": "k" }
            ]
        }));
        assert_eq!(Classification::of(&m).ode_states, ["u"]);
    }

    /// system_kind's four conditions, in the normative order.
    #[test]
    fn system_kind_order() {
        // A steady-state PDE has no time derivative but is still a PDE.
        let steady = model(serde_json::json!({
            "variables": { "phi": { "type": "unknown" }, "f": { "type": "parameter" } },
            "equations": [ { "lhs": { "op": "laplacian", "args": ["phi"] }, "rhs": "f" } ]
        }));
        assert_eq!(system_kind(&steady), SystemKind::Pde);

        // Both signals: sde wins, because there is no SPDESystem to select.
        let both = model(serde_json::json!({
            "variables": {
                "v": { "type": "unknown" },
                "xi": { "type": "parameter",
                        "distribution": { "kind": "normal", "mean": 0.0, "std": 1.0 },
                        "update": { "kind": "wiener" } }
            },
            "equations": [ { "lhs": { "op": "D", "args": ["v"], "wrt": "t" },
                             "rhs": { "op": "*", "args": [{ "op": "grad", "args": ["v"], "dim": "x" }, "xi"] } } ]
        }));
        assert_eq!(system_kind(&both), SystemKind::Sde);

        // No derivative anywhere: nonlinear.
        let nl = model(serde_json::json!({
            "variables": { "H": { "type": "unknown" }, "SO4": { "type": "unknown" },
                           "Ksp": { "type": "parameter" } },
            "equations": [
                { "lhs": "H", "rhs": { "op": "*", "args": ["SO4", 2.0] } },
                { "lhs": { "op": "*", "args": ["H", "H", "SO4"] }, "rhs": "Ksp" }
            ]
        }));
        assert_eq!(system_kind(&nl), SystemKind::Nonlinear);

        // A plain time derivative: ode.
        let ode = model(serde_json::json!({
            "variables": { "u": { "type": "unknown" }, "r": { "type": "parameter" } },
            "equations": [ { "lhs": { "op": "D", "args": ["u"], "wrt": "t" }, "rhs": "r" } ]
        }));
        assert_eq!(system_kind(&ode), SystemKind::Ode);
    }

    /// Classification is a property of the equation SET, not of traversal
    /// order: definitions may appear out of dependency order.
    #[test]
    fn observed_chain_out_of_order() {
        let m = model(serde_json::json!({
            "variables": {
                "z": { "type": "unknown" }, "y": { "type": "unknown" },
                "x": { "type": "unknown" }, "a": { "type": "parameter" }
            },
            "equations": [
                { "lhs": "z", "rhs": { "op": "*", "args": ["y", 2.0] } },
                { "lhs": { "op": "D", "args": ["x"], "wrt": "t" }, "rhs": "a" },
                { "lhs": "y", "rhs": { "op": "+", "args": ["x", 1.0] } }
            ]
        }));
        let c = Classification::of(&m);
        assert_eq!(c.ode_states, ["x"]);
        assert_eq!(c.observed_unknowns, ["y", "z"]);
        assert!(c.observed_definitions.contains_key("y"));
        assert!(c.observed_definitions.contains_key("z"));
    }
}
