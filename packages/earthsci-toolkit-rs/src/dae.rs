//! RFC §12 DAE binding contract — rust binding strategy.
//!
//! rust's strategy per `docs/rfcs/dae-binding-strategies.md` is
//! **trivial-DAE preprocessing**: before handing the system off to the
//! ODE assembler, the preprocessor factors out every algebraic equation
//! of the form `var ~ expr` where `var` does not appear in `expr`
//! (acyclic, transitively closable) by symbolically substituting
//! `var -> expr` into every remaining equation.
//!
//! If any algebraic equations remain after factoring (cyclic algebraic
//! equations, implicit constraints like `x^2 + y^2 = 1`, or equations
//! whose LHS is not a bare variable), [`apply_dae_contract`] returns a
//! [`DaeError`] with code `E_NONTRIVIAL_DAE`. rust has no native DAE
//! assembler; full DAE support lives in the Julia binding (RFC §12).
//!
//! When `dae_support` is false on input that *does* contain algebraic
//! equations (trivial or otherwise), [`apply_dae_contract`] returns
//! `E_NO_DAE_SUPPORT` — this matches the shared RFC §12 contract all
//! bindings implement.

use std::collections::HashMap;

use crate::expression::contains;
use crate::substitute::substitute;
use crate::types::{DaeInfo, Domain, Equation, EsmFile, Expr, Model};

/// Error returned by [`apply_dae_contract`] / [`discretize`] when the
/// RFC §12 DAE binding contract cannot be satisfied.
#[derive(Debug, Clone, PartialEq)]
pub struct DaeError {
    /// Normative error code (`E_NO_DAE_SUPPORT` or `E_NONTRIVIAL_DAE`).
    pub code: String,
    /// Human-readable message naming at least one offending equation path
    /// and the binding's disable knob.
    pub message: String,
}

impl std::fmt::Display for DaeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for DaeError {}

/// Options for [`discretize`]. The §11 pipeline options (max passes,
/// strict unrewritten) will be added when that pipeline lands; today
/// only the DAE knob exists.
#[derive(Debug, Clone, Copy)]
pub struct DiscretizeOptions {
    /// Whether the binding's DAE support is enabled. `false` aborts
    /// with `E_NO_DAE_SUPPORT` on any input containing algebraic
    /// equations; `true` runs the trivial-factoring preprocessor and
    /// aborts with `E_NONTRIVIAL_DAE` only on residual algebraic
    /// equations the preprocessor cannot eliminate.
    pub dae_support: bool,
}

impl Default for DiscretizeOptions {
    fn default() -> Self {
        Self {
            dae_support: default_dae_support(),
        }
    }
}

/// Resolve the effective default for `dae_support` from the environment:
/// `ESM_DAE_SUPPORT=0` (or `false`/`no`/`off`) disables DAE support.
/// Anything else (including unset) defaults to enabled.
pub fn default_dae_support() -> bool {
    match std::env::var("ESM_DAE_SUPPORT") {
        Ok(v) => !matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "no" | "off"
        ),
        Err(_) => true,
    }
}

/// Run the RFC §12 DAE binding contract on `esm` **in place** and
/// return the classification summary.
///
/// Behavior (rust strategy):
///
/// 1. Classify every equation as `differential` (LHS is `D(x, wrt=<indep>)`
///    where `<indep>` is the enclosing model's domain's
///    `independent_variable`, default `"t"`) or `algebraic` (everything
///    else — authored observed equations, explicit constraints, etc).
/// 2. If no algebraic equations exist, stamp
///    `metadata.system_class = "ode"` and `metadata.dae_info` and return.
/// 3. If `dae_support` is `false`, return `E_NO_DAE_SUPPORT` naming the
///    first offending path.
/// 4. Otherwise, run the trivial-factoring preprocessor: repeatedly
///    pick any algebraic equation `lhs = Variable(v)` whose `rhs` does
///    not reference `v`, substitute `v -> rhs` into every remaining
///    equation (differential and algebraic), and drop the factored
///    equation. Repeat until fixed point.
/// 5. If algebraic equations remain (cyclic, implicit, or non-bare-LHS),
///    return `E_NONTRIVIAL_DAE` naming every residual path.
/// 6. Otherwise, stamp `metadata.system_class = "ode"`,
///    `metadata.dae_info.algebraic_equation_count = 0`, and
///    `metadata.dae_info.factored_equation_count = <count>`.
///
/// The input `esm` is mutated: factored algebraic equations are removed
/// and their substitutions applied to the remaining equations.
pub fn apply_dae_contract(esm: &mut EsmFile, dae_support: bool) -> Result<DaeInfo, DaeError> {
    let indep_by_domain = domain_indep_map(esm);

    let mut pre_factor_count = 0usize;
    let mut first_path: Option<String> = None;
    if let Some(models) = esm.models.as_ref() {
        for (mname, model) in models.iter() {
            let indep = model_indep(model, &indep_by_domain);
            for (i, eq) in model.equations.iter().enumerate() {
                if is_algebraic(eq, &indep) {
                    pre_factor_count += 1;
                    if first_path.is_none() {
                        first_path = Some(format!("models.{mname}.equations[{i}]"));
                    }
                }
            }
        }
    }

    if pre_factor_count == 0 {
        let info = DaeInfo {
            algebraic_equation_count: 0,
            per_model: per_model_zero(esm),
            factored_equation_count: Some(0),
        };
        stamp_metadata(esm, "ode", &info);
        return Ok(info);
    }

    if !dae_support {
        let where_ = first_path.as_deref().unwrap_or("(unknown)");
        return Err(DaeError {
            code: "E_NO_DAE_SUPPORT".into(),
            message: format!(
                "discretize() input contains {pre_factor_count} algebraic equation(s) \
                 (first at {where_}); DAE support is disabled \
                 (DiscretizeOptions::dae_support=false / ESM_DAE_SUPPORT=0). \
                 Enable DAE support or remove the algebraic constraint(s). See RFC §12."
            ),
        });
    }

    // Trivial-factoring preprocessor. Run per-model: algebraic equations
    // are defined within the model scope, and substitutions apply only
    // to equations of the same model.
    let mut factored_total = 0usize;
    let mut residual_paths: Vec<String> = Vec::new();
    let mut per_model: HashMap<String, usize> = HashMap::new();

    if let Some(models) = esm.models.as_mut() {
        // Collect keys first to avoid borrow conflicts while we mutate.
        let mnames: Vec<String> = models.keys().cloned().collect();
        for mname in mnames {
            let indep = {
                let model = models.get(&mname).expect("model key just listed");
                model_indep(model, &indep_by_domain)
            };
            let model = models.get_mut(&mname).expect("model key just listed");
            let (factored, residual) = factor_model(model, &indep);
            factored_total += factored;
            for idx in &residual {
                residual_paths.push(format!("models.{mname}.equations[{idx}]"));
            }
            per_model.insert(mname, residual.len());
        }
    }

    if !residual_paths.is_empty() {
        let residual_count = residual_paths.len();
        return Err(DaeError {
            code: "E_NONTRIVIAL_DAE".into(),
            message: format!(
                "discretize() input contains {residual_count} non-trivial \
                 algebraic equation(s) that cannot be factored into the ODE \
                 system ({factored_total} were factored out): {paths}. \
                 The rust binding supports only trivially substitutable \
                 algebraic equations (form `var ~ expr` where `var` does \
                 not appear in `expr`, acyclic). For full DAE support use \
                 the Julia binding (EarthSciSerialization.jl). See RFC §12 \
                 and docs/rfcs/dae-binding-strategies.md.",
                paths = residual_paths.join(", "),
            ),
        });
    }

    let info = DaeInfo {
        algebraic_equation_count: 0,
        per_model,
        factored_equation_count: Some(factored_total),
    };
    stamp_metadata(esm, "ode", &info);
    Ok(info)
}

/// Top-level `discretize()` entry point per RFC §11/§12 for the rust binding.
///
/// Today this function only applies the RFC §12 DAE binding contract
/// (trivial factoring + error otherwise). The RFC §11 pipeline
/// (canonicalize, rule engine, PDE-op check, provenance) will be wired in
/// when that lands as a separate bead.
///
/// Returns a discretized [`EsmFile`] with `metadata.system_class`,
/// `metadata.dae_info`, and `metadata.discretized_from` stamped.
pub fn discretize(esm: &EsmFile, options: DiscretizeOptions) -> Result<EsmFile, DaeError> {
    let mut out = esm.clone();
    let input_name = esm.metadata.name.clone();
    apply_dae_contract(&mut out, options.dae_support)?;
    out.metadata.discretized_from = input_name;
    Ok(out)
}

// ----- helpers --------------------------------------------------------------

fn domain_indep_map(esm: &EsmFile) -> HashMap<String, String> {
    let mut out = HashMap::new();
    if let Some(domains) = esm.domains.as_ref() {
        for (name, d) in domains.iter() {
            out.insert(name.clone(), domain_indep(d));
        }
    }
    out
}

fn domain_indep(d: &Domain) -> String {
    d.independent_variable.clone().unwrap_or_else(|| "t".into())
}

fn model_indep(model: &Model, map: &HashMap<String, String>) -> String {
    match model.domain.as_deref() {
        Some(name) => map.get(name).cloned().unwrap_or_else(|| "t".into()),
        None => "t".into(),
    }
}

fn is_differential(eq: &Equation, indep: &str) -> bool {
    match &eq.lhs {
        Expr::Operator(node) if node.op == "D" => {
            match node.wrt.as_deref() {
                // Explicit wrt matches the model's independent variable.
                Some(w) => w == indep,
                // Unspecified wrt: treat as differential (defaults to indep
                // per §5.4 conventions).
                None => true,
            }
        }
        _ => false,
    }
}

fn is_algebraic(eq: &Equation, indep: &str) -> bool {
    !is_differential(eq, indep)
}

fn per_model_zero(esm: &EsmFile) -> HashMap<String, usize> {
    let mut out = HashMap::new();
    if let Some(models) = esm.models.as_ref() {
        for name in models.keys() {
            out.insert(name.clone(), 0);
        }
    }
    out
}

fn stamp_metadata(esm: &mut EsmFile, system_class: &str, info: &DaeInfo) {
    esm.metadata.system_class = Some(system_class.into());
    esm.metadata.dae_info = Some(info.clone());
}

/// Run the trivial-factoring loop for one model.
///
/// Returns `(factored_count, residual_indices)` where `residual_indices`
/// are indices (into the original `model.equations` vector) of algebraic
/// equations that could not be factored. On success, `residual_indices`
/// is empty and the factored algebraic equations have been removed from
/// `model.equations`.
fn factor_model(model: &mut Model, indep: &str) -> (usize, Vec<usize>) {
    // Track original indices so residual paths reference the caller's view.
    // Each entry: (original_index, is_algebraic, equation).
    let originals: Vec<(usize, bool, Equation)> = model
        .equations
        .drain(..)
        .enumerate()
        .map(|(i, eq)| {
            let alg = is_algebraic(&eq, indep);
            (i, alg, eq)
        })
        .collect();

    // Working lists. `alive` holds equations still in the system.
    let mut alive: Vec<(usize, bool, Equation)> = originals;

    let mut factored: usize = 0;
    loop {
        // Find the first algebraic equation with a bare-variable LHS
        // where the variable does not appear in the RHS. That's the
        // factorable pattern.
        let pick = alive.iter().position(|(_, is_alg, eq)| {
            if !*is_alg {
                return false;
            }
            match &eq.lhs {
                Expr::Variable(v) => !contains(&eq.rhs, v),
                _ => false,
            }
        });

        let Some(idx) = pick else { break };

        // Remove the picked equation, capture var+rhs.
        let (_orig_idx, _, picked) = alive.remove(idx);
        let var = match picked.lhs {
            Expr::Variable(v) => v,
            _ => unreachable!("pick guaranteed bare-variable LHS"),
        };
        let rhs = picked.rhs;

        // Substitute `var -> rhs` into every remaining equation.
        let mut subs: HashMap<String, Expr> = HashMap::new();
        subs.insert(var, rhs);
        for (_, _, eq) in alive.iter_mut() {
            eq.lhs = substitute(&eq.lhs, &subs);
            eq.rhs = substitute(&eq.rhs, &subs);
        }

        // Also substitute into model variables' observed expressions and
        // into initialization equations so the model remains consistent.
        for var_def in model.variables.values_mut() {
            if let Some(expr) = var_def.expression.as_mut() {
                *expr = substitute(expr, &subs);
            }
        }
        if let Some(init_eqs) = model.initialization_equations.as_mut() {
            for eq in init_eqs.iter_mut() {
                eq.lhs = substitute(&eq.lhs, &subs);
                eq.rhs = substitute(&eq.rhs, &subs);
            }
        }

        factored += 1;
    }

    // Write back alive equations; collect residual algebraic indices.
    let mut residual: Vec<usize> = Vec::new();
    let mut out_eqs: Vec<Equation> = Vec::with_capacity(alive.len());
    for (orig_idx, is_alg, eq) in alive {
        if is_alg {
            residual.push(orig_idx);
        }
        out_eqs.push(eq);
    }
    model.equations = out_eqs;
    (factored, residual)
}

// ----- tests ----------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ExpressionNode, Metadata, ModelVariable, VariableType};

    fn var(name: &str) -> Expr {
        Expr::Variable(name.into())
    }

    fn op(op: &str, args: Vec<Expr>) -> Expr {
        Expr::Operator(ExpressionNode {
            op: op.into(),
            args,
            ..Default::default()
        })
    }

    fn op_wrt(op: &str, args: Vec<Expr>, wrt: &str) -> Expr {
        Expr::Operator(ExpressionNode {
            op: op.into(),
            args,
            wrt: Some(wrt.into()),
            ..Default::default()
        })
    }

    fn minimal_esm(model_name: &str, model: Model) -> EsmFile {
        let mut models = HashMap::new();
        models.insert(model_name.into(), model);
        EsmFile {
            esm: "0.2.0".into(),
            metadata: Metadata {
                name: Some("test".into()),
                description: None,
                authors: None,
                license: None,
                created: None,
                modified: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_loaders: None,
            operators: None,
            enums: None,
            coupling: None,
            domains: None,
            interfaces: None,
            grids: None,
            staggering_rules: None,
            discretizations: None,
            function_tables: None,
        }
    }

    fn state_var() -> ModelVariable {
        ModelVariable {
            var_type: VariableType::State,
            units: None,
            default: Some(1.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        }
    }

    fn observed_var() -> ModelVariable {
        ModelVariable {
            var_type: VariableType::Observed,
            units: None,
            default: None,
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        }
    }

    fn param_var() -> ModelVariable {
        ModelVariable {
            var_type: VariableType::Parameter,
            units: None,
            default: Some(0.5),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        }
    }

    fn empty_model() -> Model {
        Model {
            regrid: None,
            name: None,
            domain: None,
            index_sets: None,
            coupletype: None,
            reference: None,
            variables: HashMap::new(),
            equations: vec![],
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
            description: None,
            tolerance: None,
            tests: None,
            boundary_conditions: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        }
    }

    #[test]
    fn pure_ode_stamps_ode_system_class() {
        // dx/dt = -k*x
        let mut m = empty_model();
        m.variables.insert("x".into(), state_var());
        m.variables.insert("k".into(), param_var());
        m.equations.push(Equation {
            lhs: op_wrt("D", vec![var("x")], "t"),
            rhs: op("*", vec![op("-", vec![var("k")]), var("x")]),
            ..Default::default()
        });
        let mut esm = minimal_esm("M", m);

        let info = apply_dae_contract(&mut esm, true).expect("pure ODE");
        assert_eq!(info.algebraic_equation_count, 0);
        assert_eq!(info.factored_equation_count, Some(0));
        assert_eq!(esm.metadata.system_class.as_deref(), Some("ode"));
        assert_eq!(
            esm.metadata
                .dae_info
                .as_ref()
                .unwrap()
                .algebraic_equation_count,
            0
        );
        // No factoring happened, no rewriting of equations.
        assert_eq!(esm.models.as_ref().unwrap()["M"].equations.len(), 1);
    }

    #[test]
    fn trivial_observed_is_factored_out() {
        // y = x^2, dx/dt = y  -->  dx/dt = x^2; y eq removed.
        let mut m = empty_model();
        m.variables.insert("x".into(), state_var());
        m.variables.insert("y".into(), observed_var());
        m.equations.push(Equation {
            lhs: var("y"),
            rhs: op("^", vec![var("x"), Expr::Integer(2)]),
            ..Default::default()
        });
        m.equations.push(Equation {
            lhs: op_wrt("D", vec![var("x")], "t"),
            rhs: var("y"),
            ..Default::default()
        });
        let mut esm = minimal_esm("M", m);

        let info = apply_dae_contract(&mut esm, true).expect("trivially factored");
        assert_eq!(info.algebraic_equation_count, 0);
        assert_eq!(info.factored_equation_count, Some(1));
        assert_eq!(esm.metadata.system_class.as_deref(), Some("ode"));

        let eqs = &esm.models.as_ref().unwrap()["M"].equations;
        assert_eq!(eqs.len(), 1, "algebraic eq removed after factoring");
        // The remaining equation's RHS should be x^2 (y substituted).
        match &eqs[0].rhs {
            Expr::Operator(n) if n.op == "^" => {
                assert_eq!(n.args.len(), 2);
                assert!(matches!(n.args[0], Expr::Variable(ref v) if v == "x"));
                assert!(matches!(n.args[1], Expr::Integer(2)));
            }
            other => panic!("expected x^2 after substitution, got {other:?}"),
        }
    }

    #[test]
    fn transitive_trivial_chain_factors_out() {
        // z = x + 1; y = z * 2; dx/dt = y
        // All three are acyclic / transitively factorable.
        let mut m = empty_model();
        m.variables.insert("x".into(), state_var());
        m.variables.insert("y".into(), observed_var());
        m.variables.insert("z".into(), observed_var());
        m.equations.push(Equation {
            lhs: var("z"),
            rhs: op("+", vec![var("x"), Expr::Integer(1)]),
            ..Default::default()
        });
        m.equations.push(Equation {
            lhs: var("y"),
            rhs: op("*", vec![var("z"), Expr::Integer(2)]),
            ..Default::default()
        });
        m.equations.push(Equation {
            lhs: op_wrt("D", vec![var("x")], "t"),
            rhs: var("y"),
            ..Default::default()
        });
        let mut esm = minimal_esm("M", m);

        let info = apply_dae_contract(&mut esm, true).expect("chain factors");
        assert_eq!(info.factored_equation_count, Some(2));
        assert_eq!(info.algebraic_equation_count, 0);
        assert_eq!(esm.models.as_ref().unwrap()["M"].equations.len(), 1);
    }

    #[test]
    fn cyclic_algebraic_errors_nontrivial() {
        // y = x + w; w = y - 1; dx/dt = y
        // y and w mutually refer to each other — neither is factorable.
        let mut m = empty_model();
        m.variables.insert("x".into(), state_var());
        m.variables.insert("y".into(), observed_var());
        m.variables.insert("w".into(), observed_var());
        m.equations.push(Equation {
            lhs: var("y"),
            rhs: op("+", vec![var("x"), var("w")]),
            ..Default::default()
        });
        m.equations.push(Equation {
            lhs: var("w"),
            rhs: op("-", vec![var("y"), Expr::Integer(1)]),
            ..Default::default()
        });
        m.equations.push(Equation {
            lhs: op_wrt("D", vec![var("x")], "t"),
            rhs: var("y"),
            ..Default::default()
        });
        let mut esm = minimal_esm("M", m);

        let err = apply_dae_contract(&mut esm, true).expect_err("cycle");
        assert_eq!(err.code, "E_NONTRIVIAL_DAE");
        assert!(err.message.contains("models.M.equations"));
        assert!(err.message.contains("Julia"));
        assert!(err.message.contains("RFC §12"));
    }

    #[test]
    fn implicit_constraint_errors_nontrivial() {
        // x^2 + y^2 = 1 (LHS is not a bare variable) -> non-trivial.
        let mut m = empty_model();
        m.variables.insert("x".into(), state_var());
        m.variables.insert("y".into(), state_var());
        m.equations.push(Equation {
            lhs: op(
                "+",
                vec![
                    op("^", vec![var("x"), Expr::Integer(2)]),
                    op("^", vec![var("y"), Expr::Integer(2)]),
                ],
            ),
            rhs: Expr::Integer(1),
            ..Default::default()
        });
        m.equations.push(Equation {
            lhs: op_wrt("D", vec![var("x")], "t"),
            rhs: var("y"),
            ..Default::default()
        });
        let mut esm = minimal_esm("M", m);

        let err = apply_dae_contract(&mut esm, true).expect_err("implicit");
        assert_eq!(err.code, "E_NONTRIVIAL_DAE");
    }

    #[test]
    fn self_referential_algebraic_errors_nontrivial() {
        // y = y + 1 -> LHS is bare but RHS references y -> not factorable.
        let mut m = empty_model();
        m.variables.insert("x".into(), state_var());
        m.variables.insert("y".into(), observed_var());
        m.equations.push(Equation {
            lhs: var("y"),
            rhs: op("+", vec![var("y"), Expr::Integer(1)]),
            ..Default::default()
        });
        m.equations.push(Equation {
            lhs: op_wrt("D", vec![var("x")], "t"),
            rhs: var("y"),
            ..Default::default()
        });
        let mut esm = minimal_esm("M", m);

        let err = apply_dae_contract(&mut esm, true).expect_err("self ref");
        assert_eq!(err.code, "E_NONTRIVIAL_DAE");
    }

    #[test]
    fn dae_support_disabled_errors_on_algebraic() {
        let mut m = empty_model();
        m.variables.insert("x".into(), state_var());
        m.variables.insert("y".into(), observed_var());
        m.equations.push(Equation {
            lhs: var("y"),
            rhs: op("^", vec![var("x"), Expr::Integer(2)]),
            ..Default::default()
        });
        m.equations.push(Equation {
            lhs: op_wrt("D", vec![var("x")], "t"),
            rhs: var("y"),
            ..Default::default()
        });
        let mut esm = minimal_esm("M", m);

        let err = apply_dae_contract(&mut esm, false).expect_err("no dae support");
        assert_eq!(err.code, "E_NO_DAE_SUPPORT");
        assert!(err.message.contains("models.M.equations"));
        assert!(err.message.contains("ESM_DAE_SUPPORT"));
    }

    #[test]
    fn dae_support_disabled_accepts_pure_ode() {
        let mut m = empty_model();
        m.variables.insert("x".into(), state_var());
        m.equations.push(Equation {
            lhs: op_wrt("D", vec![var("x")], "t"),
            rhs: op("-", vec![var("x")]),
            ..Default::default()
        });
        let mut esm = minimal_esm("M", m);

        let info = apply_dae_contract(&mut esm, false).expect("pure ODE under disabled");
        assert_eq!(info.algebraic_equation_count, 0);
        assert_eq!(esm.metadata.system_class.as_deref(), Some("ode"));
    }

    #[test]
    fn discretize_stamps_discretized_from() {
        let mut m = empty_model();
        m.variables.insert("x".into(), state_var());
        m.equations.push(Equation {
            lhs: op_wrt("D", vec![var("x")], "t"),
            rhs: Expr::Integer(0),
            ..Default::default()
        });
        let esm = minimal_esm("M", m);

        let out = discretize(&esm, DiscretizeOptions { dae_support: true }).expect("ok");
        assert_eq!(out.metadata.discretized_from.as_deref(), Some("test"));
        assert_eq!(out.metadata.system_class.as_deref(), Some("ode"));
    }

    #[test]
    fn custom_independent_variable_is_respected() {
        // Domain with independent_variable = "s". D(x, wrt=s) is
        // differential; D(x, wrt=t) is algebraic under this indep.
        let mut m = empty_model();
        m.domain = Some("space".into());
        m.variables.insert("x".into(), state_var());
        m.equations.push(Equation {
            lhs: op_wrt("D", vec![var("x")], "t"),
            rhs: Expr::Integer(0),
            ..Default::default()
        });
        let mut esm = minimal_esm("M", m);
        let mut domains = HashMap::new();
        domains.insert(
            "space".into(),
            Domain {
                independent_variable: Some("s".into()),
                temporal: None,
                spatial: None,
                coordinate_transforms: None,
                spatial_ref: None,
                initial_conditions: None,
                boundary_conditions: None,
                element_type: None,
                array_type: None,
            },
        );
        esm.domains = Some(domains);

        // With non-bare LHS (D(...)) the equation cannot be factored;
        // since wrt=t doesn't match indep=s it is algebraic.
        let err = apply_dae_contract(&mut esm, true).expect_err("non-trivial");
        assert_eq!(err.code, "E_NONTRIVIAL_DAE");
    }
}
