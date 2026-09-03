//! Structural validation: equation balance, model references, reactions,
//! events, and inter-model dependency cycles.
//!
//! This module is the equation/structural half of the validation surface.
//! Schema validation, the public `ValidationResult` types, and the top-level
//! orchestrator live in [`crate::validate`]; coupling-entry validation lives
//! in [`crate::coupling`].
//!
//! A parallel LOAD-TIME stack lives in `crate::parse`
//! (`validate_structural_json`): it runs on raw JSON inside `load_string()` with
//! cross-binding-pinned String messages, and some rules deliberately exist in
//! both layers — see the note in parse.rs before changing a shared rule.

use crate::EsmFile;
use crate::op_registry::is_builtin_function_name;
use crate::units::{
    build_unit_env, check_equation_dimensions, check_expression_dimensions, parse_unit,
};
use crate::validate::{StructuralError, StructuralErrorCode, SystemInfo, UnitWarning};
use std::collections::{HashMap, HashSet};

pub(crate) fn validate_model(
    esm_file: &EsmFile,
    model_name: &str,
    model: &crate::Model,
    system_refs: &HashMap<String, SystemInfo>,
    errors: &mut Vec<StructuralError>,
    warnings: &mut Vec<UnitWarning>,
) {
    let ctx = ModelCtx::new(esm_file, model_name, model, system_refs);

    ctx.check_equation_balance(errors);
    let unit_env = ctx.check_unit_declarations(errors);
    ctx.check_initialization_equation_refs(errors);
    ctx.check_guess_refs(errors);
    ctx.check_test_reference_refs(errors);
    ctx.check_equations(&unit_env, errors, warnings);
    ctx.check_aggregate_nodes(errors);

    // Bare array-level expressions align their operands by index-set NAME
    // (esm-spec §4.3.4). An operand carrying an index set the result does not
    // have cannot be aligned at all — decidable from the declared shapes alone,
    // so it is decided here rather than being flattened positionally at run
    // time into plausible, zero-padded garbage.
    validate_array_broadcast_shapes(model_name, model, errors);

    ctx.check_default_units_identity(errors);
    ctx.check_observed_definitions(&unit_env, errors, warnings);
    ctx.check_update_expression_refs(errors);
    ctx.check_discrete_events(errors);
    check_physical_constant_units(model_name, model, errors);
    ctx.check_continuous_events(errors);
}

/// The per-model validation context the `check_*` passes below share: the
/// document, the model under check, and the scope sets every reference check
/// resolves against — derived once in [`ModelCtx::new`].
struct ModelCtx<'a> {
    esm_file: &'a EsmFile,
    model_name: &'a str,
    model: &'a crate::Model,
    system_refs: &'a HashMap<String, SystemInfo>,
    model_path: String,
    /// The §6.3.1 classification of this model, derived once: which unknowns are
    /// ODE states, which are observed (and by which equation), and which
    /// parameters are Brownian / discrete. Every check below that used to branch
    /// on a declared type reads it.
    class: crate::classification::Classification,
    /// The model's UNKNOWNS, sorted. Sorted rather than declaration-ordered
    /// because `Model::variables` is a `HashMap`, which discards the JSON key
    /// order at parse: a stable answer is the only one this binding can give.
    unknown_vars: Vec<String>,
    defined_vars: HashSet<String>,
    /// Scoped references this model's equations may use that are NOT top-level
    /// systems: the `<sub>.<var>` fields of each DataSource mounted as a
    /// subsystem (flatten lowers these to observeds `<model>.<sub>.<var>`).
    local_scoped: HashSet<String>,
    is_coupled: bool,
}

impl<'a> ModelCtx<'a> {
    fn new(
        esm_file: &'a EsmFile,
        model_name: &'a str,
        model: &'a crate::Model,
        system_refs: &'a HashMap<String, SystemInfo>,
    ) -> Self {
        let model_path = format!("/models/{model_name}");
        let class = crate::classification::Classification::of(model);
        let unknown_vars: Vec<String> = class.unknowns();
        let mut defined_vars: HashSet<String> = model.variables.keys().cloned().collect();

        // esm-spec §4.9.1: three classes of symbol are in scope WITHOUT appearing in
        // the `variables` map, and none of them is an `undefined_variable`. Adding
        // them to the in-scope set here is what lets every reference check below —
        // equations, observed expressions, event conditions and event affects —
        // resolve them uniformly.
        defined_vars.extend(implicitly_declared_symbols(esm_file));

        let local_scoped = subsystem_scoped_refs(model);

        // A COUPLED model — operator-composed or a coupling target — does not own
        // every name it mentions: `operator_compose`/`couple` merge the participating
        // systems' scopes, so it legitimately references another composed system's
        // state by bare name. Reference integrity therefore checks it against the
        // DOCUMENT-WIDE declared names plus the §6.4 `_var` placeholder (already in
        // `defined_vars` via `implicitly_declared_symbols`); a name declared NOWHERE
        // is still an `undefined_variable` (F-1). Only equation-unknown BALANCE stays
        // skipped (its unknowns may be driven by equations another system
        // contributes). Mirrors Go `validate.go`, TS `validate/orchestrator.ts` and
        // Python `global_symbols`.
        let is_coupled = coupled_system_names(esm_file).contains(model_name);
        if is_coupled {
            defined_vars.extend(document_declared_names(esm_file));
        }

        ModelCtx {
            esm_file,
            model_name,
            model,
            system_refs,
            model_path,
            class,
            unknown_vars,
            defined_vars,
            local_scoped,
            is_coupled,
        }
    }

    /// Every reference check routes through this one gate, which keeps the five
    /// call sites across the passes uniform. A coupled model is checked too (F-1) — its
    /// `defined_vars` was widened to the document scope in [`ModelCtx::new`] —
    /// so the gate no longer short-circuits. Unit propagation is a separate
    /// pass: the dimensions of what a model spells must agree regardless of
    /// which system owns a name.
    fn check_refs(
        &self,
        expr: &crate::Expr,
        path: &str,
        idx: usize,
        errs: &mut Vec<StructuralError>,
    ) {
        // Any binder introduced ANYWHERE in this expression is in scope
        // throughout it (a `makearray` binds its grid indices for every
        // value; see `collect_bound_symbols`). Seed those before the descent,
        // which then adds nested binders on top per node.
        let mut scope = self.defined_vars.clone();
        collect_bound_symbols(expr, &mut scope);
        validate_expression_references_with_systems(
            expr,
            &scope,
            self.system_refs,
            &self.local_scoped,
            path,
            idx,
            errs,
        );
    }

    /// Check the equation/unknown balance (esm-spec §4.9.4).
    ///
    /// The check is UNKNOWNS vs EQUATIONS — not "state variables vs
    /// time-derivative equations". An equation is credited whichever form its LHS
    /// takes: a derivative (`D(x)/dt ~ …`), a bare variable (`x ~ …`, an
    /// algebraic/observed equation), or an EXPRESSION (`H*H*SO4 ~ Ksp`, an
    /// implicit algebraic constraint). Crediting only a bare-variable derivative
    /// LHS undercounts every algebraic equation, which is why a
    /// `system_kind: "nonlinear"` equilibrium model — no time derivative anywhere
    /// — was reported as "0 ODE equations, 2 state variables" and rejected.
    ///
    /// `initialization_equations` (§6.2) are a separate block with a separate
    /// balance and are deliberately NOT counted here.
    fn check_equation_balance(&self, errors: &mut Vec<StructuralError>) {
        let defining_equations = count_defining_equations(&self.model.equations);
        if !self.is_coupled && defining_equations != self.unknown_vars.len() {
            let (extra_equations_for, missing_equations_for) =
                analyze_equation_mismatch(&self.model.equations, &self.unknown_vars);

            // The settled cross-binding detail key is `unknowns`
            // (tests/invalid/expected_errors.json): esm 1.0.0 balances UNKNOWNS
            // against equations, and `state_variables` named a type that no longer
            // exists.
            let mut details = serde_json::json!({
                "unknowns": self.unknown_vars,
                "equations": defining_equations,
            });

            if !missing_equations_for.is_empty() {
                details["missing_equations_for"] = serde_json::json!(missing_equations_for);
            }
            if !extra_equations_for.is_empty() {
                details["extra_equations_for"] = serde_json::json!(extra_equations_for);
            }

            errors.push(StructuralError {
                path: self.model_path.clone(),
                code: StructuralErrorCode::EquationCountMismatch,
                message: format!(
                    "Number of equations ({}) does not match number of unknowns ({})",
                    defining_equations,
                    self.unknown_vars.len()
                ),
                details,
            });
        }
    }

    /// Build a unit environment once per model — expression-level dimensional
    /// propagation walks the Expr AST using this map. A variable with NO declared
    /// units is simply absent from the env (dimension unknown, not
    /// dimensionless), so expressions mentioning it are skipped rather than
    /// checked against a fabricated dimension.
    ///
    /// A variable whose declared unit string denotes no real unit is a different
    /// matter: it is a HARD `unit_parse_error` at the variable's own pointer
    /// (esm-spec §4.8.4). Coercing it to dimensionless would fabricate a
    /// dimension, and treating it as merely unknown would let a typo silently
    /// switch off every dimensional check that depends on it.
    fn check_unit_declarations(
        &self,
        errors: &mut Vec<StructuralError>,
    ) -> HashMap<String, crate::units::Unit> {
        let (unit_env, unit_parse_failures) = build_unit_env(&self.model.variables);
        for failure in unit_parse_failures {
            errors.push(StructuralError {
                path: format!("{}/variables/{}", self.model_path, failure.name),
                code: StructuralErrorCode::UnitParseError,
                message: format!("Unit string '{}' is not a recognised unit", failure.units),
                details: serde_json::json!({
                    "variable": failure.name,
                    "units": failure.units,
                }),
            });
        }
        unit_env
    }

    /// Reference integrity applies to EVERY expression-bearing block, not just
    /// `equations`. `initialization_equations` (§6.2) are a separate block with a
    /// separate balance — but they are still expressions over the model's
    /// symbols, and nothing checked them, so an undefined name in an initial
    /// condition was a silent FALSE NEGATIVE. (The sidecar fields *within* an
    /// expression — `expr`, `filter`, `key`, `lower`/`upper`, `values`, `axes`,
    /// `bindings` — are covered by the walker itself, which descends via
    /// `ExpressionNode::for_each_child` rather than `args` alone.)
    fn check_initialization_equation_refs(&self, errors: &mut Vec<StructuralError>) {
        for (eq_idx, equation) in self
            .model
            .initialization_equations
            .iter()
            .flatten()
            .enumerate()
        {
            let eq_path = format!("{}/initialization_equations/{eq_idx}", self.model_path);
            // The pointer is the containing expression FIELD (§7.1.2) — `.../<eq>/lhs`
            // or `.../<eq>/rhs` — not the whole equation.
            for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
                self.check_refs(expr, &format!("{eq_path}/{field}"), eq_idx, errors);
            }
        }
    }

    /// `guesses` (§6.3) — an initial guess for a nonlinear solve is an Expression
    /// over the model's symbols. Stored as raw JSON, so it is parsed here.
    fn check_guess_refs(&self, errors: &mut Vec<StructuralError>) {
        for (var_name, guess) in self.model.guesses.iter().flatten() {
            let Ok(expr) = serde_json::from_value::<crate::Expr>(guess.clone()) else {
                continue; // not an expression (a bare number is fine)
            };
            self.check_refs(
                &expr,
                &format!("{}/guesses/{var_name}", self.model_path),
                0,
                errors,
            );
        }
    }

    /// `tests[].assertions[].reference` (§6.6) — an analytic reference solution is
    /// an Expression over the model's symbols.
    fn check_test_reference_refs(&self, errors: &mut Vec<StructuralError>) {
        for (t_idx, test) in self.model.tests.iter().flatten().enumerate() {
            for (a_idx, assertion) in test.assertions.iter().enumerate() {
                // Only the inline analytic-Expression form names symbols; a
                // `{type: "from_file"}` reference points at a snapshot.
                let Some(crate::types::AssertionReference::Expression(reference)) =
                    &assertion.reference
                else {
                    continue;
                };
                self.check_refs(
                    reference,
                    &format!(
                        "{}/tests/{t_idx}/assertions/{a_idx}/reference",
                        self.model_path
                    ),
                    0,
                    errors,
                );
            }
        }
    }

    /// Check that all equation references are defined and validate dimensional
    /// consistency.
    fn check_equations(
        &self,
        unit_env: &HashMap<String, crate::units::Unit>,
        errors: &mut Vec<StructuralError>,
        warnings: &mut Vec<UnitWarning>,
    ) {
        for (eq_idx, equation) in self.model.equations.iter().enumerate() {
            let eq_path = format!("{}/equations/{eq_idx}", self.model_path);
            // Reference integrity attaches to the containing expression FIELD
            // (§7.1.2): an undefined name on the RHS is reported at
            // `.../equations/<i>/rhs`, not at the whole equation. (Dimensional
            // findings below stay at the equation level — an inconsistency is a
            // property of the equation, not of one side.)
            for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
                self.check_refs(expr, &format!("{eq_path}/{field}"), eq_idx, errors);
            }

            // Validate dimensional consistency of the equation via expression-level
            // propagation over the Expr AST. Every finding is reported: a provable
            // mismatch is a hard `unit_inconsistency` error, an undeterminable
            // dimension stays a non-blocking warning. See `record_unit_findings`.
            record_unit_findings(
                check_equation_dimensions(equation, unit_env),
                &eq_path,
                &format!("Equation {eq_idx}"),
                errors,
                warnings,
            );
        }
    }

    /// Static `aggregate`-node constraints (RFC semiring-faq-unified-ir): an
    /// undeclared `from` index set, a value-equality join over an unportable
    /// (float/null) categorical key, and a value-invention `distinct` node that
    /// reads a state variable (relational work on the continuous hot path). Each
    /// is decidable from this one document, so it belongs in `validate()`.
    fn check_aggregate_nodes(&self, errors: &mut Vec<StructuralError>) {
        // The leaves that seed CONTINUOUS in the cadence partition
        // (CONFORMANCE_SPEC.md §5.7.2): ODE states, algebraic unknowns, and
        // Brownian parameters. An `aggregate` reading any of them classes
        // CONTINUOUS, which guard 2 forbids for relational work. (An OBSERVED
        // unknown's class depends on its defining equation, which only the cadence
        // pass resolves; this static check stays with the leaves it can decide.)
        let state_var_set: HashSet<String> = self
            .class
            .ode_states
            .iter()
            .chain(&self.class.algebraic_unknowns)
            .chain(&self.class.brownian_parameters)
            .cloned()
            .collect();
        validate_aggregate_constraints(
            self.esm_file,
            self.model_name,
            self.model,
            &state_var_set,
            errors,
        );
    }

    /// A `default_units` that names a unit OTHER than the declared `units` means
    /// the `default` NUMBER is expressed in the wrong unit — `units: "K"` with
    /// `default: 25.0, default_units: "degC"` stores 25 for a variable that
    /// actually reads 298.15 (esm-spec §4.8; `tests/invalid/
    /// units_parameter_default_mismatch.esm`).
    ///
    /// The comparison is on unit IDENTITY, not dimension: `K` and `degC` share a
    /// dimension and (in a purely multiplicative model) a scale, differing only
    /// by an affine OFFSET that `Unit` cannot represent — so a dimensional check
    /// is structurally incapable of catching this, which is why every binding but
    /// Python missed it. Matching Python, any difference is reported.
    fn check_default_units_identity(&self, errors: &mut Vec<StructuralError>) {
        for (var_name, variable) in &self.model.variables {
            let (Some(declared), Some(default_units)) =
                (variable.units.as_deref(), variable.default_units.as_deref())
            else {
                continue;
            };
            if declared.trim() == default_units.trim() {
                continue;
            }
            errors.push(StructuralError {
                path: format!("{}/variables/{var_name}", self.model_path),
                code: StructuralErrorCode::UnitInconsistency,
                message: "Parameter default value units do not match declared units".to_string(),
                details: serde_json::json!({
                    "variable": var_name,
                    "declared_units": declared,
                    "default_value": variable.default,
                    "inferred_default_units": default_units,
                }),
            });
        }
    }

    /// An OBSERVED unknown's defining expression is an EQUATION from esm 1.0.0
    /// — there is no `expression` field on a variable, and an observed with
    /// nothing defining it is no longer a malformed declaration but an
    /// UNBALANCED SYSTEM, already reported above as `equation_count_mismatch`
    /// (esm-spec §4.9.4). So the checks that used to run over
    /// `variables[v].expression` now run over that equation's RHS, keyed by the
    /// unknown it defines. Reference integrity on the RHS is covered by the
    /// equations loop above; what is specific here is the DIMENSIONAL check
    /// against the unknown's declared `units`, whose error path is the VARIABLE
    /// (`/models/<M>/variables/<v>`), as pinned by
    /// `tests/invalid/expected_errors.json`.
    fn check_observed_definitions(
        &self,
        unit_env: &HashMap<String, crate::units::Unit>,
        errors: &mut Vec<StructuralError>,
        warnings: &mut Vec<UnitWarning>,
    ) {
        for (var_name, rhs) in &self.class.observed_definitions {
            let Some(variable) = self.model.variables.get(var_name) else {
                continue;
            };
            let declared = variable.units.as_deref().and_then(|u| parse_unit(u).ok());
            record_unit_findings(
                check_expression_dimensions(rhs, declared.as_ref(), unit_env),
                &format!("{}/variables/{var_name}", self.model_path),
                &format!("Observed variable \"{var_name}\""),
                errors,
                warnings,
            );
            if let Some(declared) = &declared {
                check_linear_conversion_factor(
                    rhs,
                    declared,
                    self.model,
                    &format!("{}/variables/{var_name}", self.model_path),
                    var_name,
                    errors,
                );
            }
        }
    }

    /// The Expressions a VARIABLE still carries are the parameter-update ones
    /// (§5.4): each rule's `when` trigger, its `expression` value form, and a
    /// `from` binding's `unit_conversion`. Reference integrity applies to every
    /// expression-bearing field (§4.9.5), and nothing else walks these.
    fn check_update_expression_refs(&self, errors: &mut Vec<StructuralError>) {
        let mut var_names: Vec<&String> = self.model.variables.keys().collect();
        var_names.sort();
        for var_name in var_names {
            let variable = &self.model.variables[var_name];
            let base = format!("{}/variables/{var_name}/update", self.model_path);
            variable.for_each_expression_at(&mut |expr, site| {
                self.check_refs(expr, &format!("{base}{site}"), 0, errors)
            });
        }
    }

    /// Validate discrete events.
    fn check_discrete_events(&self, errors: &mut Vec<StructuralError>) {
        if let Some(ref discrete_events) = self.model.discrete_events {
            for (event_idx, event) in discrete_events.iter().enumerate() {
                validate_discrete_event(
                    event,
                    event_idx,
                    &self.model_path,
                    &self.defined_vars,
                    &self.model.variables,
                    errors,
                );
            }
        }
    }

    /// Validate continuous events.
    fn check_continuous_events(&self, errors: &mut Vec<StructuralError>) {
        if let Some(ref continuous_events) = self.model.continuous_events {
            for (event_idx, event) in continuous_events.iter().enumerate() {
                validate_continuous_event(
                    event,
                    event_idx,
                    &self.model_path,
                    &self.defined_vars,
                    &self.model.variables,
                    errors,
                );
            }
        }
    }
}

/// A literal-scaled UNIT CONVERSION whose numeric factor is wrong
/// (`tests/invalid/units_conversion_factor_error.esm`).
///
/// The shape is exactly `<literal> * <variable>` where the variable's declared
/// unit has the SAME DIMENSION as the observed variable's but a DIFFERENT SCALE
/// — that is what makes the expression a unit conversion rather than ordinary
/// arithmetic. In that case the literal is not free: it MUST be the conversion
/// factor between the two units. `converted_pressure [Pa] ~ 50000 * p_atm [atm]`
/// is dimensionally impeccable and numerically nonsense — the factor has to be
/// 101325.
///
/// The same-scale case is deliberately SKIPPED, and that is what keeps the check
/// sound: `y [m] ~ 2 * x [m]` is a legitimate coefficient, not a botched
/// conversion, and a naive "the literal must make the scales agree" rule would
/// reject it. No conversion is implied when the units are already identical, so
/// nothing is asserted about the coefficient. (This is the formulation Python
/// arrived at; Go and TS check neither case.)
fn check_linear_conversion_factor(
    expr: &crate::Expr,
    declared: &crate::units::Unit,
    model: &crate::Model,
    path: &str,
    var_name: &str,
    errors: &mut Vec<StructuralError>,
) {
    let crate::Expr::Operator(node) = expr else {
        return;
    };
    if node.op != "*" || node.args.len() != 2 {
        return;
    }

    // Exactly one literal factor and one bare variable reference.
    let (factor, src_name) = match (&node.args[0], &node.args[1]) {
        (crate::Expr::Number(f), crate::Expr::Variable(v)) => (*f, v),
        (crate::Expr::Variable(v), crate::Expr::Number(f)) => (*f, v),
        (crate::Expr::Integer(i), crate::Expr::Variable(v)) => (*i as f64, v),
        (crate::Expr::Variable(v), crate::Expr::Integer(i)) => (*i as f64, v),
        _ => return,
    };

    let Some(src_units) = model
        .variables
        .get(src_name)
        .and_then(|v| v.units.as_deref())
    else {
        return;
    };
    let Ok(src) = parse_unit(src_units) else {
        return;
    };

    // A dimension MISMATCH is a different defect, already reported by
    // `check_expression_dimensions`; do not double-report it here.
    if !src.same_dimensions(declared) {
        return;
    }

    let (src_scale, dst_scale) = (src.scale(), declared.scale());
    if !src_scale.is_finite() || !dst_scale.is_finite() || dst_scale == 0.0 {
        return;
    }
    // Identical units ⇒ no conversion is implied ⇒ the coefficient is free.
    if (src_scale - dst_scale).abs() <= 1e-9 * src_scale.abs().max(dst_scale.abs()) {
        return;
    }

    let expected = src_scale / dst_scale;
    if (factor - expected).abs() <= 1e-6 * expected.abs() {
        return;
    }

    errors.push(StructuralError {
        path: path.to_string(),
        code: StructuralErrorCode::UnitInconsistency,
        message: "Unit conversion factor is incorrect for specified unit transformation"
            .to_string(),
        details: serde_json::json!({
            "variable": var_name,
            "declared_units": model.variables[var_name].units,
            "source_units": src_units,
            "declared_factor": factor,
            "expected_factor": expected,
        }),
    });
}

/// Every system a coupling entry NAMES — as a `systems` member (including the
/// root of a dotted subsystem path) or as the system half of a `from`/`to`
/// scoped reference.
///
/// A COUPLED system does not own all the names its equations mention. An
/// operator-style model spells its operand as the §6.4 placeholder `_var` (or a
/// bare stand-in name), and a `variable_map` supplies a value the target model
/// never declares; its `equations` may likewise drive a state that lives in the
/// system it is composed with, so its own equation/unknown count need not
/// balance. Reference integrity and equation balance are therefore SKIPPED for
/// these systems — the settled cross-binding contract (Go `coupledSystemNames`,
/// TS `validate/orchestrator.ts` `coupledSystems`). Event consistency still runs
/// with `_var` credited, which is where a genuinely undeclared event target is
/// still caught.
///
/// Rust applied both checks unconditionally, which is why it rejected nine valid
/// coupled documents that Go and TS accept: `equation_count_mismatch` on models
/// whose equations live in their partner, and `undefined_variable` on the very
/// operands coupling supplies.
pub(crate) fn coupled_system_names(esm_file: &EsmFile) -> HashSet<String> {
    let mut coupled = HashSet::new();
    let mut add = |name: &str| {
        if name.is_empty() {
            return;
        }
        coupled.insert(name.to_string());
        // A dotted endpoint ("Atmosphere.Chemistry.O3") couples the ROOT system
        // too — that is the model whose checks must relax.
        if let Some((root, _)) = name.split_once('.') {
            coupled.insert(root.to_string());
        }
    };

    for entry in esm_file.coupling.iter().flatten() {
        match entry {
            crate::CouplingEntry::OperatorCompose { systems, .. }
            | crate::CouplingEntry::Couple { systems, .. } => {
                for s in systems {
                    add(s);
                }
            }
            crate::CouplingEntry::VariableMap { from, to, .. } => {
                add(from);
                add(to);
            }
            // `operator_apply`, `callback` and `event` do not name a pair of
            // systems whose equations merge, so they do not relax anything.
            _ => {}
        }
    }
    coupled
}

/// Check that every parameter `update` whose kind is `data` names a declared
/// `data_sources` entry (esm-spec §8.5; diagnostic `data_source_undefined`).
///
/// From esm 1.0.0 this is the ONLY way a document can name a data source, so it
/// is the only place the name can be wrong. It is schema-valid by construction
/// (any string), which is precisely why the check has to live here.
pub(crate) fn validate_data_source_references(
    esm_file: &EsmFile,
    errors: &mut Vec<StructuralError>,
) {
    let declared: Vec<String> = {
        let mut names: Vec<String> = esm_file
            .data_sources
            .iter()
            .flatten()
            .map(|(k, _)| k.clone())
            .collect();
        names.sort();
        names
    };

    for (model_name, model) in esm_file.models.iter().flatten() {
        let mut var_names: Vec<&String> = model.variables.keys().collect();
        var_names.sort();
        for var_name in var_names {
            let var = &model.variables[var_name];
            for source in var.update_sources() {
                if declared.iter().any(|d| d == source) {
                    continue;
                }
                errors.push(StructuralError {
                    path: format!("/models/{model_name}/variables/{var_name}/update"),
                    code: StructuralErrorCode::DataSourceUndefined,
                    message: format!(
                        "Parameter update names data source '{source}', which the document does not declare"
                    ),
                    details: serde_json::json!({
                        "variable": var_name,
                        "source": source,
                        "available_sources": declared,
                    }),
                });
            }
        }
    }
}

/// Every name DECLARED anywhere in the document: each model's `variables` and
/// each reaction system's `species` and `parameters`.
///
/// A data SOURCE contributes nothing from esm 1.0.0 — it exposes no variables
/// and is not a component (RFC unified-variable-model D2); the name belongs to
/// the parameter that consumes it, which the models loop already counts.
///
/// Does NOT include the implicit symbols (`t`, coordinates, index sets, `_var`,
/// callback-injected names) — combine with `implicitly_declared_symbols` for
/// the full document scope. Mirrors Julia `_document_declared_names`, TS
/// `documentDeclaredNames`, Go `documentWideScope`.
fn document_declared_names(esm_file: &EsmFile) -> HashSet<String> {
    let mut names = HashSet::new();
    for model in esm_file.models.iter().flatten().map(|(_, m)| m) {
        names.extend(model.variables.keys().cloned());
    }
    for rs in esm_file.reaction_systems.iter().flatten().map(|(_, r)| r) {
        names.extend(rs.species.keys().cloned());
        names.extend(rs.parameters.keys().cloned());
    }
    // A data source declares NO names from esm 1.0.0 (RFC
    // unified-variable-model D2): it exposes no variables and is not a
    // component, so it contributes nothing to the document scope. The
    // consuming parameter carries the name, and it is already counted above.
    names
}

/// The symbols that are in scope in every model's expressions WITHOUT appearing
/// in its `variables` map (esm-spec §4.9.1). None of these is an
/// `undefined_variable`, and each rule here exists because rejecting one of them
/// rejected a conforming file in the shared corpus.
///
/// 1. **The independent variable** — `domain.independent_variable`, default
///    `"t"`. Every time-dependent model may write `t`; an analytic forcing
///    `A*sin(omega*t)` is the ordinary spelling. (Rust used to hardcode the
///    literal `"t"` at one reference site, so a document that RENAMED its
///    independent variable had every mention of it flagged, while `t` was
///    accepted even in models that never declared a domain.)
///
/// 2. **Spatial coordinate names** — §11.4. A checker resolves as a coordinate
///    any free symbol that is (i) a key of `index_sets`, (ii) the `dim` field of
///    ANY node that carries one (resolved STRUCTURALLY, by field — the
///    spatial-calculus sugar ops carry no privileged status, so this is not
///    keyed on a `grad`/`div`/`curl`/`laplacian` op-name list), or (iii) a free
///    symbol in the RHS of an `ic` equation, which §11.4 *defines* to be a
///    coordinate expression.
///
/// 3. **`_var`** — §6.4, the operator-model placeholder, legal wherever a state
///    variable is legal (equation LHS/RHS, a continuous event's
///    `affects`/`affect_neg`). The 0.x `functional_affect`'s `read_vars` was a
///    fourth such site; esm 1.0.0 removed the construct.
fn implicitly_declared_symbols(esm_file: &EsmFile) -> HashSet<String> {
    let mut symbols = HashSet::new();

    // (1) The independent variable, defaulting to `t`.
    symbols.insert(independent_variable(esm_file));

    // (3) The operator placeholder.
    symbols.insert("_var".to_string());

    // (2i) Every declared index set names a coordinate axis.
    if let Some(index_sets) = &esm_file.index_sets {
        symbols.extend(index_sets.keys().cloned());
    }

    // A `callback` coupling DECLARES the variables it injects into its target
    // system, in `config.callback_variables[].name` — they are ordinary
    // declarations that simply live outside the model's own `variables` map
    // (esm-spec §4.9.5 / CONFORMANCE_SPEC row (k)). Omitting them turns the
    // reference-integrity fix into a FALSE REJECTION of every callback-coupled
    // model, which is a strictly worse bug than the false negative it closes.
    for entry in esm_file.coupling.iter().flatten() {
        let crate::CouplingEntry::Callback { config, .. } = entry else {
            continue;
        };
        let names = config
            .as_ref()
            .and_then(|c| c.get("callback_variables"))
            .and_then(|v| v.as_array())
            .into_iter()
            .flatten()
            .filter_map(|cv| cv.get("name").and_then(|n| n.as_str()))
            .map(str::to_string);
        symbols.extend(names);
    }

    // (2ii) + (2iii): walk every expression in the document once, collecting the
    // `dim` field of every node that carries one (structurally, by field) and
    // the free symbols of each `ic` RHS. Both are document-scoped: a coordinate
    // named by `{op: grad, dim: "x"}` in one model is the same axis `x` that
    // another model's initial condition may reference.
    if let Some(models) = &esm_file.models {
        for model in models.values() {
            for eq in &model.equations {
                // An `ic` equation's RHS is a COORDINATE EXPRESSION (§11.4): its
                // free symbols name spatial coordinates, e.g. an ignition front
                // at `x < x0`.
                if is_ic_equation(&eq.lhs) {
                    collect_free_symbols(&eq.rhs, &mut symbols);
                }
                collect_coordinate_symbols(&eq.lhs, &mut symbols);
                collect_coordinate_symbols(&eq.rhs, &mut symbols);
            }
            for var in model.variables.values() {
                var.for_each_expression(&mut |expr| collect_coordinate_symbols(expr, &mut symbols));
            }
        }
    }

    symbols
}

/// The document's independent variable — `domain.independent_variable`, or `t`.
fn independent_variable(esm_file: &EsmFile) -> String {
    esm_file
        .domain
        .as_ref()
        .and_then(|d| d.independent_variable.clone())
        .unwrap_or_else(|| "t".to_string())
}

/// True when this LHS marks an initial condition (`{"op": "ic", ...}`).
fn is_ic_equation(lhs: &crate::Expr) -> bool {
    matches!(lhs, crate::Expr::Operator(op) if op.op == "ic")
}

/// Collect the `dim` axis of every node that carries one, regardless of its
/// `op` (esm-spec §4.9.1 (ii), as revised).
///
/// The spatial-calculus sugar ops (`grad`/`div`/`laplacian`/`curl`/`∇`) are
/// ordinary open-tier rewrite targets with NO privileged status, so a
/// coordinate axis is resolved STRUCTURALLY — by the presence of a `dim` field
/// — not by matching a hardcoded operator-name list. Resolving by field also
/// credits an axis named by an unregistered user discretization op (e.g.
/// `godunov_hamiltonian`) or by `∇`, which a hand-maintained name list
/// silently missed.
fn collect_coordinate_symbols(expr: &crate::Expr, out: &mut HashSet<String>) {
    if let crate::Expr::Operator(op) = expr {
        if let Some(dim) = &op.dim {
            out.insert(dim.clone());
        }
        op.for_each_child(&mut |child| collect_coordinate_symbols(child, out));
    }
}

/// Collect every free symbol (bare variable reference) in `expr`.
fn collect_free_symbols(expr: &crate::Expr, out: &mut HashSet<String>) {
    match expr {
        crate::Expr::Variable(name) => {
            // A scoped reference names another system's variable, not a local
            // coordinate.
            if !name.contains('.') && !is_builtin_function_name(name) {
                out.insert(name.clone());
            }
        }
        crate::Expr::Operator(op) => {
            op.for_each_child(&mut |child| collect_free_symbols(child, out));
        }
        crate::Expr::Number(_) | crate::Expr::Integer(_) => {}
    }
}

/// Static `aggregate`-node constraints (RFC semiring-faq-unified-ir), decidable
/// from this single document. Walk every `aggregate` node in the model's
/// `equations` and emit, at the CONTAINING equation FIELD (`.../equations/<i>/lhs`
/// or `/rhs`, the pointer convention shared with the reference checks):
///
/// - `undefined_index_set` — a `ranges` entry `{ "from": NAME }` whose NAME is
///   not a key of the document `index_sets` registry (RFC §5.2: no implicit
///   interval is inferred for an undeclared name).
/// - `join_key_invalid_type` — a value-equality `join` whose key column ranges
///   over a categorical index set carrying a FLOAT or NULL member (RFC §5.3 /
///   §5.7 rule 1): a float is not portably equality-comparable, a null key is
///   unmatchable. Mirrors [`crate::join::JoinKey::from_json`]'s build-time rule.
/// - `relational_node_in_continuous` — a value-invention `distinct` aggregate
///   whose `key`/`expr` reads a model STATE variable, so the cadence partition
///   classes it CONTINUOUS and guard 2 forbids relational work on the per-step
///   hot path (CONFORMANCE_SPEC.md §5.7.6).
fn validate_aggregate_constraints(
    esm_file: &EsmFile,
    model_name: &str,
    model: &crate::Model,
    state_vars: &HashSet<String>,
    errors: &mut Vec<StructuralError>,
) {
    let model_path = format!("/models/{model_name}");
    // Array-shaped unknowns: the only variables a causal self-reference can
    // define (esm-spec §4.3.1.1).
    let array_shaped: HashSet<&str> = model
        .variables
        .iter()
        .filter(|(_, v)| v.shape.as_ref().is_some_and(|s| !s.is_empty()))
        .map(|(n, _)| n.as_str())
        .collect();
    for (eq_idx, equation) in model.equations.iter().enumerate() {
        for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
            let field_path = format!("{model_path}/equations/{eq_idx}/{field}");
            check_aggregates_in_expr(expr, &field_path, esm_file, state_vars, errors);
        }
        check_recurrence_equation(
            equation,
            &format!("{model_path}/equations/{eq_idx}/rhs"),
            esm_file,
            &array_shaped,
            errors,
        );
    }
}

// ---------------------------------------------------------------------------
// Causal self-reference (recurrence) well-foundedness — esm-spec §4.3.1.1
// ---------------------------------------------------------------------------
//
// The STATIC half of the construct, and the half every binding implements
// whether or not it evaluates anything (CONFORMANCE_SPEC §5.19.5). It decides
// two things about an equation that defines an array-shaped unknown `V` and
// reads `index(V, …)` in its own RHS:
//
//   * whether the read is well founded — affine in its frame symbol, offset on
//     exactly one axis, and not provably same-cell-or-later;
//   * whether the construct carrying the read can be sequenced cell by cell.
//
// It is deliberately CONSERVATIVE where it cannot prove a lag's sign: an
// unprovable lag is admitted here, because a self-read of a cell the sweep has
// not published cannot return a value at all (esm-spec §4.3.1.1 point 5), so
// soundness does not rest on this check. What rests on it is the DIAGNOSTIC —
// rejecting the shapes that are wrong for every document, at validation time,
// with a code rather than at evaluation time with a fault.

/// Bounds of an index symbol, resolved from the ranges available to the
/// VALIDATOR (unlike the runtime, which sees ranges already resolved against
/// the registry). A dense literal interval, or an `interval`-kind index set's
/// `1..size`; anything else is unknown, and an unknown symbol makes a lag
/// unprovable rather than illegal.
fn validator_symbol_bounds(
    spec: &crate::types::RangeSpec,
    esm_file: &EsmFile,
) -> Option<(i64, i64)> {
    match spec {
        crate::types::RangeSpec::Interval([lo, hi]) => Some((*lo, *hi)),
        crate::types::RangeSpec::Strided([lo, _, hi]) => Some((*lo, *hi)),
        crate::types::RangeSpec::IndexSetRef { from, of: None } => {
            let set = esm_file.index_sets.as_ref()?.get(from)?;
            // `interval` by declared size, `categorical` by member count. Both
            // are 1-origin dense ranges at evaluation, and the evaluator
            // resolves BOTH before rule building — so leaving `categorical` out
            // here would make the validator prove less than the evaluator and
            // reject a document the evaluator accepts.
            match set.kind.as_str() {
                "interval" => Some((1, set.size?)),
                "categorical" => Some((1, set.members.as_ref()?.len() as i64)),
                _ => None,
            }
        }
        _ => None,
    }
}

/// The affine form of an index expression with respect to the frame symbol
/// `sym`: the coefficient of `sym`, plus the bounds of the symbol-free part —
/// `None` for those bounds when they cannot be proved.
///
/// Mirrors the runtime's `affine_in_sym` exactly, and for the same reason the
/// runtime splits the two halves: the **coefficient** must be provable (without
/// it the read names no position relative to the cell being written), while an
/// unprovable **constant part** is a lag of unknown sign, which esm-spec
/// §4.3.1.1 admits and the runtime's fail-closed read guards.
///
/// The validator necessarily proves LESS than the evaluator — it sees ranges
/// before they are resolved against the registry — so a validator that treated
/// "unproven" as "illegal" would reject documents the evaluator accepts. That
/// is the one disagreement between the two which is never defensible, so the
/// unknown case is admitted here too.
struct StructuralAffine {
    coef: i64,
    konst: Option<(i64, i64)>,
}

fn structural_affine_in_sym(
    e: &crate::Expr,
    sym: &str,
    env: &HashMap<String, (i64, i64)>,
) -> Option<StructuralAffine> {
    let konst = |lo: i64, hi: i64| {
        Some(StructuralAffine {
            coef: 0,
            konst: Some((lo, hi)),
        })
    };
    match e {
        crate::Expr::Integer(n) => konst(*n, *n),
        crate::Expr::Number(f) if f.fract() == 0.0 && f.is_finite() => {
            let n = *f as i64;
            konst(n, n)
        }
        crate::Expr::Variable(v) if v == sym => Some(StructuralAffine {
            coef: 1,
            konst: Some((0, 0)),
        }),
        crate::Expr::Variable(v) => Some(StructuralAffine {
            coef: 0,
            konst: env.get(v).copied(),
        }),
        crate::Expr::Operator(node) if node.args.len() == 2 => {
            let a = structural_affine_in_sym(&node.args[0], sym, env)?;
            let b = structural_affine_in_sym(&node.args[1], sym, env)?;
            let both = a.konst.zip(b.konst);
            match node.op.as_str() {
                "+" => Some(StructuralAffine {
                    coef: a.coef + b.coef,
                    konst: both.map(|((la, ha), (lb, hb))| (la + lb, ha + hb)),
                }),
                "-" => Some(StructuralAffine {
                    coef: a.coef - b.coef,
                    konst: both.map(|((la, ha), (lb, hb))| (la - hb, ha - lb)),
                }),
                "*" => {
                    let (k, other) = match (a.coef, a.konst, b.coef, b.konst) {
                        (0, Some((lo, hi)), _, _) if lo == hi => (lo, &b),
                        (_, _, 0, Some((lo, hi))) if lo == hi => (lo, &a),
                        _ => return None,
                    };
                    Some(StructuralAffine {
                        coef: other.coef * k,
                        konst: other.konst.map(|(lo, hi)| {
                            let (p, q) = (lo * k, hi * k);
                            (p.min(q), p.max(q))
                        }),
                    })
                }
                _ => None,
            }
        }
        _ => None,
    }
}

/// One self-read the structural walk found: its index arguments, the symbol
/// bounds in scope where it was found, and whether it was reached only through
/// a construct that cannot be restricted to one cell.
struct StructuralSelfRead<'a> {
    args: &'a [crate::Expr],
    env: HashMap<String, (i64, i64)>,
    unsequenceable: bool,
}

/// Ops whose operands are consumed WHOLE — a self-read underneath one of these
/// names a cell of an array that has to exist in full before the op can run, so
/// no cell-by-cell sweep can supply it (esm-spec §4.3.1.1 `recurrence_unsupported_form`).
fn op_blocks_cell_restriction(op: &str) -> bool {
    // `apply_expression_template` is deliberately NOT here. Its operands ride
    // the `bindings` field, which this walk does not visit (and must not start
    // visiting unilaterally — five bindings mirror this field set, and §5.19.5
    // is exact agreement), so listing it would have been a rule that barely
    // reached what it named. It is also unreachable in practice: a template
    // application surviving into an evaluation position is already an
    // `unlowered_operator` error (esm-spec §9.6.4), so this list names only the
    // ops that legitimately reach evaluation and consume an operand whole.
    matches!(op, "reshape" | "transpose" | "concat" | "broadcast")
}

fn collect_structural_self_reads<'a>(
    e: &'a crate::Expr,
    var: &str,
    esm_file: &EsmFile,
    env: &mut Vec<(String, (i64, i64))>,
    blocked: bool,
    out: &mut Vec<StructuralSelfRead<'a>>,
    bare: &mut bool,
) {
    let crate::Expr::Operator(node) = e else {
        if let crate::Expr::Variable(v) = e
            && v == var
        {
            *bare = true;
        }
        return;
    };
    let pushed = if node.op == "aggregate" {
        let add: Vec<(String, (i64, i64))> = node
            .ranges
            .as_ref()
            .map(|m| {
                m.iter()
                    .filter_map(|(k, spec)| {
                        validator_symbol_bounds(spec, esm_file).map(|b| (k.clone(), b))
                    })
                    .collect()
            })
            .unwrap_or_default();
        let n = add.len();
        env.extend(add);
        n
    } else {
        0
    };
    let is_self_index = node.op == "index"
        && matches!(node.args.first(), Some(crate::Expr::Variable(v)) if v == var);
    if is_self_index {
        let mut snapshot: HashMap<String, (i64, i64)> = HashMap::new();
        for (k, v) in env.iter() {
            snapshot.insert(k.clone(), *v);
        }
        out.push(StructuralSelfRead {
            args: &node.args[1..],
            env: snapshot,
            unsequenceable: blocked,
        });
    }
    // A `makearray` REGION VALUE is evaluated once for the whole region, so a
    // self-read inside one cannot be sequenced; the region ORDER decides which
    // write wins, not which cell is evaluated when (esm-spec §4.3.2).
    let blocked_children = blocked || op_blocks_cell_restriction(&node.op);
    let skip = usize::from(is_self_index);
    for a in node.args.iter().skip(skip) {
        collect_structural_self_reads(a, var, esm_file, env, blocked_children, out, bare);
    }
    for side in [
        node.expr.as_deref(),
        node.filter.as_deref(),
        node.key.as_deref(),
        node.lower.as_deref(),
        node.upper.as_deref(),
    ]
    .into_iter()
    .flatten()
    {
        collect_structural_self_reads(side, var, esm_file, env, blocked_children, out, bare);
    }
    if let Some(vs) = node.values.as_ref() {
        for v in vs {
            collect_structural_self_reads(v, var, esm_file, env, true, out, bare);
        }
    }
    env.truncate(env.len() - pushed);
}

/// The variable an equation DEFINES, if its LHS names one: a bare variable, or
/// the §4.3 indexed-aggregate LHS form `aggregate{expr: index(V, k…)}`. A
/// derivative LHS (`D(u)`) defines no array algebraically — a stencil read of
/// `u` at `i−1` there is a gather on the solver's state, not a self-reference —
/// so it deliberately yields `None`.
fn recurrence_lhs_target(lhs: &crate::Expr) -> Option<(&str, Option<&Vec<String>>)> {
    match lhs {
        crate::Expr::Variable(v) => Some((v.as_str(), None)),
        crate::Expr::Operator(node) if node.op == "aggregate" => {
            let crate::Expr::Operator(inner) = node.expr.as_deref()? else {
                return None;
            };
            if inner.op != "index" {
                return None;
            }
            let crate::Expr::Variable(v) = inner.args.first()? else {
                return None;
            };
            Some((v.as_str(), node.output_idx.as_ref()))
        }
        _ => None,
    }
}

/// Check one equation for a well-founded causal self-reference
/// (esm-spec §4.3.1.1). Emits nothing when the RHS contains no self-read, which
/// is every equation in every document that does not use the construct.
fn check_recurrence_equation(
    equation: &crate::types::Equation,
    field_path: &str,
    esm_file: &EsmFile,
    array_shaped: &HashSet<&str>,
    errors: &mut Vec<StructuralError>,
) {
    let Some((var, lhs_idx)) = recurrence_lhs_target(&equation.lhs) else {
        return;
    };
    if !array_shaped.contains(var) {
        return;
    }
    let mut env: Vec<(String, (i64, i64))> = Vec::new();
    let mut reads: Vec<StructuralSelfRead> = Vec::new();
    let mut bare = false;
    collect_structural_self_reads(
        &equation.rhs,
        var,
        esm_file,
        &mut env,
        false,
        &mut reads,
        &mut bare,
    );
    if reads.is_empty() {
        return;
    }
    let push = |errors: &mut Vec<StructuralError>,
                code: StructuralErrorCode,
                message: String,
                axis: Option<&str>| {
        errors.push(StructuralError {
            path: field_path.to_string(),
            code,
            message,
            details: serde_json::json!({
                "variable": var,
                "recurrence_axis": axis,
            }),
        });
    };
    if bare {
        push(
            errors,
            StructuralErrorCode::RecurrenceNotWellfounded,
            format!(
                "'{var}' is read bare inside its own defining equation as well as through \
                 `index`. A bare read names the whole array, which does not exist while the \
                 recurrence sweeps it (esm-spec §4.3.1.1)."
            ),
            None,
        );
        return;
    }
    if let Some(read) = reads.iter().find(|r| r.unsequenceable) {
        let _ = read;
        push(
            errors,
            StructuralErrorCode::RecurrenceUnsupportedForm,
            format!(
                "a causal self-read of '{var}' is reached only through a construct that \
                 evaluates its operand whole — a `makearray` region value, or a \
                 `reshape`/`transpose`/`concat`/`broadcast` operand — so no cell-by-cell sweep \
                 can supply it. A `makearray`'s region order fixes which write WINS, not the \
                 order cells are EVALUATED in (esm-spec §4.3.1.1, §4.3.2); write the recurrence \
                 as one `aggregate` with the base case as an `ifelse` guard in the body."
            ),
            None,
        );
        return;
    }
    // The cell frame: the indexed-aggregate LHS's own indices, else the RHS
    // aggregate's.
    let rhs_idx = match &equation.rhs {
        crate::Expr::Operator(node) if node.op == "aggregate" => node.output_idx.as_ref(),
        _ => None,
    };
    let Some(idx_names) = lhs_idx.or(rhs_idx) else {
        push(
            errors,
            StructuralErrorCode::RecurrenceUnsupportedForm,
            format!(
                "the definition of '{var}' reads '{var}' at another position, but the equation \
                 declares no cell frame to sweep: its RHS is not an `aggregate` over the \
                 variable's axes and its LHS is not the indexed-aggregate form \
                 `aggregate{{expr: index({var}, k…)}}` (esm-spec §4.3.1.1)."
            ),
            None,
        );
        return;
    };
    if idx_names.is_empty() || idx_names.iter().any(|n| n.parse::<i64>().is_ok()) {
        push(
            errors,
            StructuralErrorCode::RecurrenceUnsupportedForm,
            format!(
                "the recurrence definition of '{var}' has no symbolic output index to fold \
                 along ({idx_names:?}); a literal singleton dimension cannot be a recurrence \
                 axis (esm-spec §4.3.1.1)."
            ),
            None,
        );
        return;
    }
    let frame_env: HashMap<String, (i64, i64)> = match &equation.rhs {
        crate::Expr::Operator(node) if node.op == "aggregate" => node
            .ranges
            .as_ref()
            .map(|m| {
                m.iter()
                    .filter_map(|(k, spec)| {
                        validator_symbol_bounds(spec, esm_file).map(|b| (k.clone(), b))
                    })
                    .collect()
            })
            .unwrap_or_default(),
        _ => HashMap::new(),
    };

    let mut axis: Option<usize> = None;
    for read in &reads {
        if read.args.len() != idx_names.len() {
            push(
                errors,
                StructuralErrorCode::RecurrenceNotWellfounded,
                format!(
                    "a causal self-read of '{var}' supplies {} indices but its frame has {} \
                     axes; every self-read indexes every axis (esm-spec §4.3.1.1).",
                    read.args.len(),
                    idx_names.len()
                ),
                None,
            );
            return;
        }
        let mut env = frame_env.clone();
        for (k, v) in &read.env {
            env.insert(k.clone(), *v);
        }
        let mut lagged: Option<usize> = None;
        for (d, arg) in read.args.iter().enumerate() {
            let sym = &idx_names[d];
            let Some(StructuralAffine { coef, konst }) = structural_affine_in_sym(arg, sym, &env)
            else {
                push(
                    errors,
                    StructuralErrorCode::RecurrenceNotWellfounded,
                    format!(
                        "index {d} of a causal self-read of '{var}' is not affine in its frame \
                         symbol '{sym}'. A self-read names a position RELATIVE to the cell being \
                         written (`{sym} - 1`, `{sym} - a`, `{sym} - a - 2`), which is what makes \
                         the recurrence axis and its direction decidable (esm-spec §4.3.1.1)."
                    ),
                    None,
                );
                return;
            };
            if coef != 1 {
                push(
                    errors,
                    StructuralErrorCode::RecurrenceNotWellfounded,
                    format!(
                        "index {d} of a causal self-read of '{var}' carries its frame symbol \
                         '{sym}' with coefficient {coef}, not 1, so it does not name a position \
                         relative to the cell being written (esm-spec §4.3.1.1)."
                    ),
                    None,
                );
                return;
            }
            // lag = sym - arg. An unprovable constant part is a lag of
            // unknown sign: this axis IS the recurrence axis (it is not the
            // identity), and the cells where the lag would be non-causal cannot
            // be read because the sweep has not published them.
            let Some((clo, chi)) = konst else {
                if lagged.is_some() {
                    push(
                        errors,
                        StructuralErrorCode::RecurrenceNotWellfounded,
                        format!(
                            "a causal self-read of '{var}' is offset on more than one axis. A \
                             recurrence folds along exactly ONE axis; every other index must be \
                             the bare frame symbol (esm-spec §4.3.1.1)."
                        ),
                        Some(sym),
                    );
                    return;
                }
                lagged = Some(d);
                continue;
            };
            let (lag_lo, lag_hi) = (-chi, -clo);
            if lag_lo == 0 && lag_hi == 0 {
                continue;
            }
            if lag_hi <= 0 {
                push(
                    errors,
                    StructuralErrorCode::RecurrenceNotWellfounded,
                    format!(
                        "index {d} of a causal self-read of '{var}' names the cell being \
                         written, or a later one, on axis '{sym}'. A causal self-reference reads \
                         strictly EARLIER positions; no sweep order can satisfy a same-cell or \
                         forward read (esm-spec §4.3.1.1)."
                    ),
                    Some(sym),
                );
                return;
            }
            if lagged.is_some() {
                push(
                    errors,
                    StructuralErrorCode::RecurrenceNotWellfounded,
                    format!(
                        "a causal self-read of '{var}' is offset on more than one axis. A \
                         recurrence folds along exactly ONE axis; every other index must be the \
                         bare frame symbol (esm-spec §4.3.1.1)."
                    ),
                    Some(sym),
                );
                return;
            }
            lagged = Some(d);
        }
        let Some(d) = lagged else {
            push(
                errors,
                StructuralErrorCode::RecurrenceNotWellfounded,
                format!(
                    "a causal self-read of '{var}' is at the same cell on every axis, so it \
                     defines '{var}' in terms of itself rather than of an earlier position \
                     (esm-spec §4.3.1.1)."
                ),
                None,
            );
            return;
        };
        match axis {
            None => axis = Some(d),
            Some(prev) if prev == d => {}
            Some(prev) => {
                push(
                    errors,
                    StructuralErrorCode::RecurrenceNotWellfounded,
                    format!(
                        "the causal self-reads of '{var}' disagree on the recurrence axis: one \
                         folds along '{}' and another along '{}'. A definition folds along \
                         exactly one axis (esm-spec §4.3.1.1).",
                        idx_names[prev], idx_names[d]
                    ),
                    Some(&idx_names[d]),
                );
                return;
            }
        }
    }
}

/// Reject a BARE array-level expression whose operand carries an index set the
/// result does not (esm-spec §4.3.4; issue #100).
///
/// A **bare** array-level expression is one written over whole arrays with no
/// explicit index symbols — `D(dp) ~ w2 * z1`, `p3 ~ w2 * z1` — as opposed to
/// the `aggregate` spelling, where the author names the axes and there is
/// nothing to infer. Its operands align by index-set NAME: an operand declared
/// over a SUBSET of the result's index sets broadcasts along the ones it is
/// missing (a `[lat]` operand replicates along `lon` and `lev` in a
/// `[lon,lat,lev]` result), and axis ORDER is immaterial (a `[lat,lon]` operand
/// transposes). An operand carrying an index set the result does NOT have has
/// no axis to align to and no defensible value to take.
///
/// Both shapes are declared, so the check is static. It is deliberately
/// CONSERVATIVE: it fires only where both the result and the operand carry
/// declared, non-repeating index-set names, and it descends only through
/// ELEMENTWISE operators. Anonymous shapes (the results of `reshape` /
/// `transpose` / `concat` / `makearray` / literal arrays) keep the positional
/// `broadcast` convention of §4.3.4 and are not checked here.
fn validate_array_broadcast_shapes(
    model_name: &str,
    model: &crate::Model,
    errors: &mut Vec<StructuralError>,
) {
    let model_path = format!("/models/{model_name}");
    let declared_axes: HashMap<&str, &Vec<String>> = model
        .variables
        .iter()
        .filter_map(|(name, var)| {
            var.shape
                .as_ref()
                .filter(|s| !s.is_empty())
                .map(|s| (name.as_str(), s))
        })
        .collect();
    if declared_axes.is_empty() {
        return;
    }

    // Equations whose LHS names a whole array: `D(var) ~ rhs` and `var ~ rhs`.
    // An INDEXED LHS (`D(var[i]) ~ …`) is a per-cell equation whose RHS axes are
    // the author's to spell, so it is left alone.
    for (eq_idx, equation) in model.equations.iter().enumerate() {
        let Some(target) = whole_array_lhs_target(&equation.lhs) else {
            continue;
        };
        check_operand_axes(
            &equation.rhs,
            target,
            &declared_axes,
            &format!("{model_path}/equations/{eq_idx}/rhs"),
            errors,
        );
    }

    // An OBSERVED unknown's defining expression is an equation with a
    // bare-variable LHS, already covered by the equation loop above: its
    // `check_operand_axes` target is the LHS variable, which is exactly this
    // check. esm 1.0.0 leaves nothing array-shaped on the variable itself.
}

/// The whole-array variable an equation LHS defines: `D(var, t)` or a bare
/// `var`. `None` for an indexed / aggregate / expression LHS.
fn whole_array_lhs_target(lhs: &crate::Expr) -> Option<&str> {
    match lhs {
        crate::Expr::Variable(name) => Some(name.as_str()),
        crate::Expr::Operator(node) if node.op == "D" => match node.args.first() {
            Some(crate::Expr::Variable(name)) => Some(name.as_str()),
            _ => None,
        },
        _ => None,
    }
}

/// Report every operand of the bare array-level expression `expr` whose
/// declared index sets are not a subset of `target`'s. See
/// [`validate_array_broadcast_shapes`] for the rule and its deliberate limits.
fn check_operand_axes(
    expr: &crate::Expr,
    target: &str,
    declared_axes: &HashMap<&str, &Vec<String>>,
    path: &str,
    errors: &mut Vec<StructuralError>,
) {
    let Some(target_axes) = declared_axes.get(target) else {
        return;
    };
    // A repeated axis name gives no unambiguous position to align to; the
    // runtime keeps the positional lowering there, so do not reject it here.
    if (1..target_axes.len()).any(|d| target_axes[..d].contains(&target_axes[d])) {
        return;
    }
    let mut operands: Vec<&str> = Vec::new();
    collect_bare_array_operands(expr, declared_axes, &mut operands);
    for operand in operands {
        let Some(operand_axes) = declared_axes.get(operand) else {
            continue;
        };
        for axis in operand_axes.iter() {
            if target_axes.contains(axis) {
                continue;
            }
            errors.push(StructuralError {
                path: path.to_string(),
                code: StructuralErrorCode::ArrayShapeMismatch,
                message: format!(
                    "Operand '{operand}' of the array-level expression for '{target}' is \
                     declared over index set '{axis}', which '{target}' is not shaped over"
                ),
                details: serde_json::json!({
                    "variable": target,
                    "operand": operand,
                    "operand_shape": operand_axes,
                    "result_shape": target_axes,
                    "missing_index_set": axis,
                }),
            });
            break;
        }
    }
}

/// Collect the declared array-shaped variables an expression references in BARE
/// (whole-array, elementwise) position.
///
/// The descent enters only ELEMENTWISE nodes
/// ([`crate::op_registry::is_elementwise_node`]) — arithmetic, the elementary
/// functions, the conditionals, and a `broadcast` whose `fn` names one of them
/// — because those are the only ones for which "corresponding elements" is
/// what the expression means. Every other op consumes its operands whole under
/// its own contract: an `aggregate` and a `makearray` name their axes, an
/// `index` gathers, the shape ops restructure, and a geometry kernel like
/// `intersect_polygon` legitimately takes `[src_verts, coord]` operands and
/// returns a `[clip_ring, coord]` result.
/// This mirrors the descent the array-runtime lowering uses when it wraps
/// leaves in per-cell gathers
/// (`simulate_array::compile::collect_wrapped_array_leaves`) — the two must
/// agree on WHICH references the alignment rule governs.
fn collect_bare_array_operands<'a>(
    expr: &'a crate::Expr,
    declared_axes: &HashMap<&str, &Vec<String>>,
    out: &mut Vec<&'a str>,
) {
    match expr {
        crate::Expr::Variable(name) if declared_axes.contains_key(name.as_str()) => {
            out.push(name.as_str());
        }
        crate::Expr::Operator(node) => {
            if !crate::op_registry::is_elementwise_node(node) {
                return;
            }
            node.for_each_child(&mut |child| {
                collect_bare_array_operands(child, declared_axes, out)
            });
        }
        _ => {}
    }
}

/// Recurse through `expr`, applying [`check_aggregate_node`] to every
/// `aggregate` node reached (including nested ones), each reported at
/// `field_path` — the top-level equation side that contains it.
fn check_aggregates_in_expr(
    expr: &crate::Expr,
    field_path: &str,
    esm_file: &EsmFile,
    state_vars: &HashSet<String>,
    errors: &mut Vec<StructuralError>,
) {
    let crate::Expr::Operator(node) = expr else {
        return;
    };
    if node.op == "aggregate" {
        check_aggregate_node(node, field_path, esm_file, state_vars, errors);
    }
    node.for_each_child(&mut |child| {
        check_aggregates_in_expr(child, field_path, esm_file, state_vars, errors);
    });
}

/// Apply the three static aggregate checks to a single `aggregate` node.
fn check_aggregate_node(
    node: &crate::types::ExpressionNode,
    field_path: &str,
    esm_file: &EsmFile,
    state_vars: &HashSet<String>,
    errors: &mut Vec<StructuralError>,
) {
    let index_sets = esm_file.index_sets.as_ref();

    // (a) undefined_index_set: a `{from: NAME}` range absent from the registry.
    if let Some(ranges) = &node.ranges {
        let mut undeclared: Vec<String> = ranges
            .values()
            .filter_map(|r| match r {
                crate::types::RangeSpec::IndexSetRef { from, .. } => Some(from.clone()),
                _ => None,
            })
            .filter(|name| index_sets.is_none_or(|m| !m.contains_key(name)))
            .collect();
        undeclared.sort();
        undeclared.dedup();
        if let Some(first) = undeclared.first() {
            errors.push(StructuralError {
                path: field_path.to_string(),
                code: StructuralErrorCode::UndefinedIndexSet,
                message: format!("Aggregate range references undeclared index set '{first}'"),
                details: serde_json::json!({ "undeclared_index_sets": undeclared }),
            });
        }
    }

    // (b) join_key_invalid_type: a value-equality join whose key column ranges
    // over a categorical index set with a FLOAT or NULL member.
    if let Some(joins) = &node.join
        && !joins.is_empty()
    {
        // The key columns are the index symbols named in every `on` pair.
        let cols: Vec<&str> = joins
            .iter()
            .flat_map(|jc| jc.on.iter())
            .flat_map(|pair| [pair[0].as_str(), pair[1].as_str()])
            .collect();
        let ranges = node.ranges.as_ref();
        'cols: for col in cols {
            let Some(crate::types::RangeSpec::IndexSetRef { from, .. }) =
                ranges.and_then(|r| r.get(col))
            else {
                continue;
            };
            let Some(iset) = index_sets.and_then(|m| m.get(from)) else {
                continue;
            };
            if iset.kind != "categorical" {
                continue;
            }
            let Some(members) = &iset.members else {
                continue;
            };
            // A member that cannot project to a portable equality key (a float or
            // a null) poisons the whole column. `JoinKey::from_json` is the exact
            // build-time discipline (RFC §5.7 rule 1).
            if members
                .iter()
                .any(|m| crate::join::JoinKey::from_json(m).is_err())
            {
                errors.push(StructuralError {
                    path: field_path.to_string(),
                    code: StructuralErrorCode::JoinKeyInvalidType,
                    message: format!(
                        "Aggregate join key column '{col}' ranges over categorical index set '{from}' whose members are not portable equality keys (a float or null member)"
                    ),
                    details: serde_json::json!({
                        "join_key_column": col,
                        "index_set": from,
                    }),
                });
                break 'cols;
            }
        }
    }

    // (c) relational_node_in_continuous: a `distinct` value-invention node whose
    // `key`/`expr` reads a STATE variable (⇒ CONTINUOUS class ⇒ guard 2 rejects).
    if node.distinct == Some(true) {
        let mut free = HashSet::new();
        if let Some(key) = node.key.as_deref() {
            collect_free_symbols(key, &mut free);
        }
        if let Some(body) = node.expr.as_deref() {
            collect_free_symbols(body, &mut free);
        }
        let mut states_read: Vec<String> = free
            .into_iter()
            .filter(|name| state_vars.contains(name))
            .collect();
        if !states_read.is_empty() {
            states_read.sort();
            errors.push(StructuralError {
                path: field_path.to_string(),
                code: StructuralErrorCode::RelationalNodeInContinuous,
                message: "Value-invention aggregate (distinct) reads a state variable, so it classes continuous; relational work is not permitted on the per-step hot path".to_string(),
                details: serde_json::json!({ "state_variables_read": states_read }),
            });
        }
    }
}

/// Route dimensional findings to the right channel.
///
/// This is the one place the cross-binding units severity policy is applied:
///
/// * A PROVABLE dimensional mismatch ([`UnitSeverity::Error`]) becomes a hard
///   `unit_inconsistency` structural error at `path`, so `is_valid` is false.
///   The shared corpus requires this — `tests/invalid/expected_errors.json`
///   pins every `units_*.esm` fixture as `is_valid: false` with a structural
///   error, so keeping these as warnings would ACCEPT files the corpus pins
///   invalid. The code and JSON-Pointer path match the TypeScript reference
///   (`validate/orchestrator.ts::promoteUnitWarningsToErrors`).
///
/// * An ANALYSIS finding — the checker could not DETERMINE a dimension
///   (unknown variable, unparseable unit, symbolic exponent, an op with no
///   dimensional rule) — stays a non-blocking warning. It reports what the
///   checker could not conclude, not a defect in the file.
fn record_unit_findings(
    findings: Vec<crate::units::UnitFinding>,
    path: &str,
    subject: &str,
    errors: &mut Vec<StructuralError>,
    warnings: &mut Vec<UnitWarning>,
) {
    for finding in findings {
        if finding.is_error() {
            errors.push(StructuralError {
                path: path.to_string(),
                code: StructuralErrorCode::UnitInconsistency,
                message: finding.message.clone(),
                details: serde_json::json!({
                    "subject": subject,
                    "detail": finding.message,
                }),
            });
        } else {
            // Classified at the RAISE SITE from the finding's severity, never
            // recovered from the prose (`UnitFinding::code`). `message` keeps
            // the exact composed string this field carried when it was a
            // `Vec<String>`; `lhs_units` / `rhs_units` stay empty because an
            // `analysis` finding is precisely one whose operand dimensions the
            // checker could not determine.
            warnings.push(UnitWarning {
                path: path.to_string(),
                code: finding.code().to_string(),
                message: format!("{subject}: {} (in {path})", finding.message),
                lhs_units: String::new(),
                rhs_units: String::new(),
            });
        }
    }
}

/// Well-known physical constants whose declared units can be dimensionally
/// verified against a canonical form. Conservative on purpose — names chosen
/// to minimize collision with common non-constant uses (e.g., no `c` for
/// speed of light, which conflicts with concentration). Mirrors Python's
/// `_KNOWN_PHYSICAL_CONSTANTS`.
fn known_physical_constants() -> &'static [(&'static str, &'static str, &'static str)] {
    &[
        ("R", "J/(mol*K)", "ideal gas constant"),
        ("k_B", "J/K", "Boltzmann constant"),
        ("N_A", "1/mol", "Avogadro constant"),
    ]
}

/// Message pinned for a physical-constant dimensional error
/// (`tests/invalid/expected_errors.json`). Named so the same string drives
/// both the emitted record and the supersession filter below.
const PHYSICAL_CONSTANT_UNIT_MESSAGE: &str =
    "Physical constant used with incorrect dimensional analysis";

/// Flag parameters whose name matches a well-known physical constant but whose
/// declared units are dimensionally incompatible with the canonical form
/// (e.g., `R` declared as `kcal/mol` — missing temperature — instead of
/// `J/(mol*K)`). Reports at the first observed-variable usage site in the
/// same model; otherwise at the declaration. Mirrors Python's
/// `parse._check_physical_constant_units` (gt-j91l / gt-3tgv).
fn check_physical_constant_units(
    model_name: &str,
    model: &crate::Model,
    errors: &mut Vec<StructuralError>,
) {
    for (constant_name, canonical, description) in known_physical_constants() {
        let Some(var) = model.variables.get(*constant_name) else {
            continue;
        };
        if var.var_type != crate::VariableType::Parameter {
            continue;
        }
        let Some(declared) = var.units.as_deref() else {
            continue;
        };
        if declared.is_empty() {
            continue;
        }
        let Ok(declared_unit) = parse_unit(declared) else {
            continue;
        };
        let Ok(canonical_unit) = parse_unit(canonical) else {
            continue;
        };
        if declared_unit.is_compatible(&canonical_unit) {
            continue;
        }
        // The observed unknown that USES the constant, if any: its defining
        // equation's RHS is where the wrong dimension actually shows up, and
        // that RHS lives in `equations` from esm 1.0.0. Iterated in sorted
        // order so the reported site does not depend on map iteration.
        let observed = crate::classification::Classification::of(model).observed_definitions;
        let usage_site: Option<&str> = observed
            .iter()
            .find(|(_, rhs)| expr_references_name(rhs, constant_name))
            .and_then(|(name, _)| {
                model
                    .variables
                    .get_key_value(name.as_str())
                    .map(|(k, _)| k.as_str())
            });
        let target = usage_site.unwrap_or(constant_name);
        let target_path = format!("/models/{model_name}/variables/{target}");
        // A wrong-dimensioned physical constant ALSO makes the observed
        // expression that uses it fail the generic expression-dimension check
        // (`record_unit_findings`), which already pushed a second
        // `unit_inconsistency` record at this very path. This physical-constant
        // diagnostic is the root-cause report and the single record the shared
        // corpus pins (tests/invalid/expected_errors.json), so it supersedes
        // the redundant generic one — each (code, path) is emitted exactly once.
        errors.retain(|e| {
            !(matches!(e.code, StructuralErrorCode::UnitInconsistency)
                && e.path == target_path
                && e.message != PHYSICAL_CONSTANT_UNIT_MESSAGE)
        });
        errors.push(StructuralError {
            path: target_path,
            code: StructuralErrorCode::UnitInconsistency,
            message: PHYSICAL_CONSTANT_UNIT_MESSAGE.to_string(),
            details: serde_json::json!({
                "constant_name": constant_name,
                "constant_description": description,
                "declared_units": declared,
                "canonical_units": canonical,
            }),
        });
    }
}

/// Returns true if the expression references a variable by exact name
/// (string leaf match). Walks the canonical expression-bearing child set
/// ([`crate::types::ExpressionNode::any_child`]).
fn expr_references_name(expr: &crate::Expr, name: &str) -> bool {
    match expr {
        crate::Expr::Variable(v) => v == name,
        crate::Expr::Operator(node) => node.any_child(&mut |a| expr_references_name(a, name)),
        crate::Expr::Number(_) | crate::Expr::Integer(_) => false,
    }
}

/// Count the equations that DEFINE the model's unknowns (esm-spec §4.9.4).
///
/// Every equation is credited regardless of the form of its LHS — a derivative
/// (`D(x)/dt ~ …`), a bare variable (`x ~ …`), or an expression (`H*H*SO4 ~
/// Ksp`) — because the balance is unknowns vs equations, and an algebraic
/// constraint is just as much an equation as an ODE.
///
/// The one exclusion is an `ic` equation: an initial condition CONSTRAINS a
/// state at t₀, it does not define its evolution, so counting it would make
/// every PDE with an initial condition look over-determined.
fn count_defining_equations(equations: &[crate::Equation]) -> usize {
    equations
        .iter()
        .filter(|eq| !is_ic_equation(&eq.lhs))
        .count()
}

/// Attribute equations to unknowns, for the DETAIL payload of an
/// `equation_count_mismatch` (esm-spec §4.9.4).
///
/// An equation is credited to an unknown whichever form its LHS takes:
///
/// * a derivative LHS — `D(x)/dt ~ …` credits `x`;
/// * a bare-variable LHS — `x ~ …`, an algebraic/observed equation, credits `x`;
/// * an EXPRESSION LHS — `H*H*SO4 ~ Ksp`, an implicit algebraic constraint —
///   credits every state variable it mentions, since the constraint is what
///   pins them jointly. (Crediting nothing here is what made the ISORROPIA
///   equilibrium shape report both of its unknowns as "missing an equation".)
fn analyze_equation_mismatch(
    equations: &[crate::Equation],
    state_vars: &[String],
) -> (Vec<String>, Vec<String>) {
    let state_vars_set: HashSet<_> = state_vars.iter().cloned().collect();
    let mut lhs_vars = HashSet::new();

    for equation in equations {
        if is_ic_equation(&equation.lhs) {
            continue; // an initial condition defines nothing (see count above)
        }
        match &equation.lhs {
            // Derivative LHS: `D(x)/dt ~ …`.
            crate::Expr::Operator(op) if op.op == "D" => {
                if let Some(crate::Expr::Variable(var_name)) = op.args.first() {
                    lhs_vars.insert(var_name.clone());
                }
            }
            // Bare-variable LHS: `x ~ …`.
            crate::Expr::Variable(var_name) => {
                lhs_vars.insert(var_name.clone());
            }
            // Expression LHS: an implicit constraint over whichever unknowns it
            // names.
            crate::Expr::Operator(_) => {
                let mut free = HashSet::new();
                collect_free_symbols(&equation.lhs, &mut free);
                lhs_vars.extend(free.intersection(&state_vars_set).cloned());
            }
            crate::Expr::Number(_) | crate::Expr::Integer(_) => {}
        }
    }

    let extra_equations_for: Vec<_> = lhs_vars.difference(&state_vars_set).cloned().collect();
    let missing_equations_for: Vec<_> = state_vars_set.difference(&lhs_vars).cloned().collect();

    (extra_equations_for, missing_equations_for)
}

pub(crate) fn validate_reaction_system(
    esm_file: &EsmFile,
    rs_name: &str,
    rs: &crate::ReactionSystem,
    system_refs: &HashMap<String, SystemInfo>,
    errors: &mut Vec<StructuralError>,
) {
    let rs_path = format!("/reaction_systems/{rs_name}");

    // Create a map of defined species (species name is the HashMap key)
    let defined_species: HashSet<String> = rs.species.keys().cloned().collect();

    // Rate expressions can reference both parameters and species names.
    let defined_parameters: HashSet<String> = rs.parameters.keys().cloned().collect();

    // Check that all reaction references are defined
    for (rxn_idx, reaction) in rs.reactions.iter().enumerate() {
        let rxn_path = format!("{rs_path}/reactions/{rxn_idx}");
        let reaction_label = reaction
            .id
            .as_deref()
            .or(reaction.name.as_deref())
            .unwrap_or("unnamed");

        // Check for null reaction (both substrates and products are null/empty)
        let substrates_empty = reaction.substrates.as_ref().is_none_or(|v| v.is_empty());
        let products_empty = reaction.products.as_ref().is_none_or(|v| v.is_empty());

        if substrates_empty && products_empty {
            errors.push(StructuralError {
                path: rxn_path.clone(),
                code: StructuralErrorCode::NullReaction,
                message: "Reaction has both substrates: null and products: null".to_string(),
                details: serde_json::json!({
                    "reaction_id": reaction_label
                }),
            });
        }

        // Check substrate references. The pointer is the offending stoichiometry
        // entry's own `species` FIELD (§7.1.2) — `.../reactions/<i>/substrates/<j>/species`
        // — not the enclosing reaction, so the finding names the exact leaf that
        // carries the undeclared name.
        for (sub_idx, substrate) in reaction.substrates.iter().flatten().enumerate() {
            if !defined_species.contains(&substrate.species) {
                errors.push(StructuralError {
                    path: format!("{rxn_path}/substrates/{sub_idx}/species"),
                    code: StructuralErrorCode::UndefinedSpecies,
                    message: format!(
                        "Species '{}' referenced in reaction substrates is not declared",
                        substrate.species
                    ),
                    details: serde_json::json!({
                        "species": substrate.species,
                        "reaction_id": reaction_label,
                        "location": "substrates",
                        "expected_in": "species"
                    }),
                });
            }
        }

        // Check product references (pointer is the entry's own `species` field).
        for (prod_idx, product) in reaction.products.iter().flatten().enumerate() {
            if !defined_species.contains(&product.species) {
                errors.push(StructuralError {
                    path: format!("{rxn_path}/products/{prod_idx}/species"),
                    code: StructuralErrorCode::UndefinedSpecies,
                    message: format!(
                        "Species '{}' referenced in reaction products is not declared",
                        product.species
                    ),
                    details: serde_json::json!({
                        "species": product.species,
                        "reaction_id": reaction_label,
                        "location": "products",
                        "expected_in": "species"
                    }),
                });
            }
        }

        // Validate rate expression references. The carrying field is the
        // reaction's `rate` (§7.1.2), so the pointer is `.../reactions/<i>/rate`.
        validate_rate_expression(
            &reaction.rate,
            &defined_parameters,
            system_refs,
            &format!("{rxn_path}/rate"),
            reaction_label,
            errors,
        );
    }

    // v0.8.0 §11.4.1: an `ic`-op equation MUST NOT appear inside a reaction
    // system's `constraint_equations`. A reaction system has no `equations`
    // field and hosts no ICs — a species' initial value is its scalar
    // `species.default`, or a scoped-reference `ic` equation in a MODEL. The
    // document is schema-valid (`constraint_equations` is an array of Equation
    // and `ic` is a legal op) but is rejected here structurally.
    if let Some(constraint_eqs) = &rs.constraint_equations {
        for (ce_idx, eq) in constraint_eqs.iter().enumerate() {
            if let crate::Expr::Operator(node) = &eq.lhs
                && node.op == "ic"
            {
                let species = match node.args.first() {
                    Some(crate::Expr::Variable(s)) => s.clone(),
                    _ => String::new(),
                };
                errors.push(StructuralError {
                    path: format!("{rs_path}/constraint_equations/{ce_idx}"),
                    code: StructuralErrorCode::IcInReactionSystem,
                    message: "ic equation not allowed in a reaction system; a reaction system has no equations field and hosts no ic equations (ICs are model-hosted: species.default, or a scoped-reference ic equation in a model, spec §11.4.1)".to_string(),
                    details: serde_json::json!({
                        "system": rs_name,
                        "species": species,
                        "constraint_equation_index": ce_idx,
                    }),
                });
            }

            // Reference integrity applies to a constraint equation too — it is an
            // expression over the system's species and parameters, and nothing
            // checked it, so an undefined name inside one was a silent FALSE
            // NEGATIVE (the same blind spot as `initialization_equations`).
            let mut scope: HashSet<String> = defined_species
                .union(&defined_parameters)
                .cloned()
                .collect();
            // The independent variable and `_var` are in scope here too (§4.9.1).
            scope.extend(implicitly_declared_symbols(esm_file));
            let ce_path = format!("{rs_path}/constraint_equations/{ce_idx}");
            for expr in [&eq.lhs, &eq.rhs] {
                validate_expression_references_with_systems(
                    expr,
                    &scope,
                    system_refs,
                    &HashSet::new(),
                    &ce_path,
                    ce_idx,
                    errors,
                );
            }
        }
    }

    // Stoichiometric rate-dimension check (spec §7.4).
    validate_reaction_rate_units(rs_name, rs, errors);

    // Note: Event validation would go here when ReactionSystem types support events
}

/// Enforce the mass-action dimensional constraint from spec §7.4: rate
/// dimensions must equal concentration^(1-total_order)/time, where the
/// reference concentration unit is the first substrate's units. Mirrors the
/// Julia/Python/TS/Go checks so the same invalid fixtures are rejected across
/// all bindings. Skipped when the reference concentration (first substrate) is
/// dimensionless — mole-fraction and ppm species commonly bake a
/// number-density factor into the rate constant.
fn validate_reaction_rate_units(
    rs_name: &str,
    rs: &crate::ReactionSystem,
    errors: &mut Vec<StructuralError>,
) {
    use crate::units::{Unit, parse_unit};

    // Build unit environment: species + parameters → Unit.
    //
    // A declared unit string that denotes no real unit is a hard
    // `unit_parse_error` at the declaration's own pointer, exactly as for a
    // model variable (esm-spec §4.8.4) — a species whose units are a typo would
    // otherwise silently drop out of the env and disable the rate-dimension
    // check below. A declaration with NO units simply stays out of the env.
    let mut env: HashMap<String, Unit> = HashMap::new();
    let mut parse_failures: Vec<(String, String, String)> = Vec::new();
    for (name, species) in &rs.species {
        match &species.units {
            Some(s) => match parse_unit(s) {
                Ok(u) => {
                    env.insert(name.clone(), u);
                }
                Err(_) => parse_failures.push(("species".into(), name.clone(), s.clone())),
            },
            None => continue,
        }
    }
    for (name, param) in &rs.parameters {
        match &param.units {
            Some(s) => match parse_unit(s) {
                Ok(u) => {
                    env.insert(name.clone(), u);
                }
                Err(_) => parse_failures.push(("parameters".into(), name.clone(), s.clone())),
            },
            None => continue,
        }
    }
    // `species`/`parameters` are HashMaps — sort for a deterministic report.
    parse_failures.sort();
    for (kind, name, units) in parse_failures {
        errors.push(StructuralError {
            path: format!("/reaction_systems/{rs_name}/{kind}/{name}"),
            code: StructuralErrorCode::UnitParseError,
            message: format!("Unit string '{units}' is not a recognised unit"),
            details: serde_json::json!({
                "name": name,
                "units": units,
            }),
        });
    }

    let time = Unit::base(crate::units::Dimension::Time, 1, 1.0);

    for (rxn_idx, reaction) in rs.reactions.iter().enumerate() {
        let rxn_path = format!("/reaction_systems/{rs_name}/reactions/{rxn_idx}");
        let reaction_label = reaction
            .id
            .as_deref()
            .or(reaction.name.as_deref())
            .unwrap_or("unnamed");

        // Rate dimension from expression propagation.
        let rate_unit = match Unit::propagate(&reaction.rate, &env) {
            Ok(u) => u,
            Err(_) => continue,
        };

        let substrates = match reaction.substrates.as_ref() {
            Some(s) if !s.is_empty() => s,
            _ => continue,
        };

        // Reference concentration unit = first substrate's species units.
        let first_sp_name = &substrates[0].species;
        let conc_unit = match env.get(first_sp_name) {
            Some(u) => u.clone(),
            None => continue,
        };
        if conc_unit.is_dimensionless() {
            continue;
        }

        // Unit exponents must be integer, so skip the rate-units compatibility
        // check when any substrate carries a fractional stoichiometry (v0.2.x
        // allows them; fractional *products* — the common atmospheric-chemistry
        // case — never enter this branch).
        let mut total_order: u32 = 0;
        let mut resolvable = true;
        let mut fractional_substrate = false;
        for entry in substrates {
            if !env.contains_key(&entry.species) {
                resolvable = false;
                break;
            }
            if entry.coefficient.fract() != 0.0 || !entry.coefficient.is_finite() {
                fractional_substrate = true;
                break;
            }
            total_order += entry.coefficient as u32;
        }
        if !resolvable || fractional_substrate {
            continue;
        }

        // The `rate` field is spelled BOTH ways in the shared corpus, and the
        // AST cannot tell them apart:
        //
        //   * as the rate CONSTANT k (`rate: "k"`), whose units for an
        //     n-th-order reaction are conc^(1-n)/time — this is what
        //     `units_reaction_rate_mismatch.esm` pins; and
        //   * as the full mass-action VELOCITY (`rate: k*exp(-Ea/RT)*A*B`),
        //     which already carries the substrate concentrations and so has
        //     units of conc/time — as in `expr_graphs_variable_deps.esm`.
        //
        // Only a rate that fits NEITHER reading is provably inconsistent.
        // Assuming the rate-constant reading alone reported a false mismatch on
        // every fixture that writes out the full rate law.
        let expected_rate_constant = conc_unit.power(1 - total_order as i32).divide(&time);
        let expected_velocity = conc_unit.divide(&time);
        if !rate_unit.is_compatible(&expected_rate_constant)
            && !rate_unit.is_compatible(&expected_velocity)
        {
            let rate_units_str = reaction_rate_units_str(&reaction.rate, rs);
            let first_sp_units = rs
                .species
                .get(first_sp_name)
                .and_then(|s| s.units.clone())
                .unwrap_or_default();
            errors.push(StructuralError {
                path: rxn_path,
                code: StructuralErrorCode::UnitInconsistency,
                message:
                    "Reaction rate expression has incompatible units for reaction stoichiometry"
                        .to_string(),
                details: serde_json::json!({
                    "reaction_id": reaction_label,
                    "rate_units": rate_units_str,
                    "expected_rate_units": format_expected_rate_units(&first_sp_units, total_order),
                    "reaction_order": total_order,
                }),
            });
        }
    }
}

/// Compose the canonical rate-unit string from the reference species unit
/// string and total reaction order, matching the contract in
/// `tests/invalid/expected_errors.json`. Examples:
///
/// - `("mol/L", 2)` → `"L/(mol*s)"`
/// - `("mol/L", 1)` → `"1/s"`
/// - `("mol/L", 0)` → `"mol/(L*s)"`
/// - `("mol/m^3", 2)` → `"m^3/(mol*s)"`
fn format_expected_rate_units(species_units: &str, total_order: u32) -> String {
    let exp: i32 = 1 - total_order as i32;
    if exp == 0 {
        return "1/s".to_string();
    }
    let (mut num, mut den) = split_unit_num_den(species_units);
    let mut exp_abs = exp;
    if exp < 0 {
        std::mem::swap(&mut num, &mut den);
        exp_abs = -exp;
    }
    let num_str = power_factor(&num, exp_abs);
    let mut den_factors: Vec<String> = Vec::new();
    let df = power_factor(&den, exp_abs);
    if !df.is_empty() {
        den_factors.push(df);
    }
    den_factors.push("s".to_string());
    let num_out = if num_str.is_empty() {
        "1".to_string()
    } else {
        num_str
    };
    if den_factors.len() == 1 {
        format!("{}/{}", num_out, den_factors[0])
    } else {
        format!("{}/({})", num_out, den_factors.join("*"))
    }
}

/// Split a unit string like `"mol/L"` into `("mol", "L")`, or `"mol/(L*s)"`
/// into `("mol", "L*s")`. The split is on the first top-level `/`. Returns
/// `("", "")` for an empty input. If no `/` appears, the whole string is the
/// numerator.
fn split_unit_num_den(s: &str) -> (String, String) {
    let s = s.trim();
    if s.is_empty() {
        return (String::new(), String::new());
    }
    let mut depth = 0i32;
    for (i, c) in s.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => depth -= 1,
            '/' if depth == 0 => {
                let num = s[..i].trim().to_string();
                let den_raw = s[i + 1..].trim();
                let den = den_raw
                    .strip_prefix('(')
                    .and_then(|t| t.strip_suffix(')'))
                    .unwrap_or(den_raw)
                    .to_string();
                return (num, den);
            }
            _ => {}
        }
    }
    (s.to_string(), String::new())
}

/// Raise a unit factor to an integer power, rendering the result as a string.
/// Parenthesises compound factors for clarity when the power is not 1.
fn power_factor(s: &str, n: i32) -> String {
    let s = s.trim();
    if s.is_empty() {
        return String::new();
    }
    if n == 1 {
        return s.to_string();
    }
    if s.contains('*') || s.contains('/') {
        format!("({s})^{n}")
    } else {
        format!("{s}^{n}")
    }
}

/// Best-effort rendering of a rate expression's declared units when the rate
/// is a bare variable reference. Returns an empty string for compound
/// expressions because raw-source rendering is not round-trippable here.
fn reaction_rate_units_str(rate: &crate::Expr, rs: &crate::ReactionSystem) -> String {
    if let crate::Expr::Variable(name) = rate {
        if let Some(p) = rs.parameters.get(name)
            && let Some(u) = &p.units
        {
            return u.clone();
        }
        if let Some(s) = rs.species.get(name)
            && let Some(u) = &s.units
        {
            return u.clone();
        }
    }
    String::new()
}

/// The index / integration symbols an operator node BINDS for its own body:
/// `output_idx` and `ranges` keys (`aggregate`/`arrayop`), the `integral` op's
/// `var`, and the `argmin`/`argmax` witness `arg`. These are in scope for the
/// node's child expressions (the aggregate body, filter predicate, grouping
/// key, integral bounds) but are NOT model/parameter declarations, so a
/// reference-checking walk that descends into those children (via
/// [`crate::types::ExpressionNode::for_each_child`], which enumerates children
/// only) must treat them as defined to avoid spurious "undefined" errors on
/// bound loop indices such as the `i` in `index(u, i)`.
fn bound_index_symbols(node: &crate::types::ExpressionNode) -> Vec<String> {
    let mut syms = Vec::new();
    if let Some(idx) = &node.output_idx {
        syms.extend(idx.iter().cloned());
    }
    if let Some(ranges) = &node.ranges {
        syms.extend(ranges.keys().cloned());
    }
    if let Some(v) = &node.int_var {
        syms.push(v.clone());
    }
    if let Some(a) = &node.arg {
        syms.push(a.clone());
    }
    // `index(array, i, j, …)` BINDS its element positions: the names after the
    // array head are loop positions, not declared variables. This is the binder
    // the doc above always claimed ("the `i` in `index(u, i)`") but that the
    // code never actually credited — so the LHS of every indexed array equation
    // (`index(nearest, i) ~ aggregate(output_idx: ["i"], …)`) reported its own
    // output index as an `undefined_variable`. Only a BARE name is a binder; an
    // index position that is an expression (`i + 1`) is a USE of a symbol bound
    // further out, and is checked normally.
    if node.op == "index" {
        for arg in node.args.iter().skip(1) {
            if let crate::Expr::Variable(name) = arg {
                syms.push(name.clone());
            }
        }
    }
    // `apply_expression_template` binds its formal parameter names.
    if let Some(bindings) = &node.bindings {
        syms.extend(bindings.keys().cloned());
    }
    syms
}

/// Collect every binder-introduced symbol anywhere in an expression subtree —
/// `index` element positions, `output_idx`/`ranges` keys, integral vars,
/// argmin/argmax witnesses and template `bindings`. Per-node scoping alone binds
/// a symbol only for the subtree UNDER the node that introduces it, which is too
/// narrow for a `makearray` stencil: it binds the grid indices `i`/`j` for ALL
/// its `values`, yet an index spelled `i + 1` in one value is a USE of the `i`
/// bound (as a bare `index` position) in another. Scanning the whole expression
/// once and holding the union in scope throughout it matches Go
/// `collectBoundSymbols` / TS `collectIndexSymbols`.
fn collect_bound_symbols(expr: &crate::Expr, out: &mut HashSet<String>) {
    if let crate::Expr::Operator(node) = expr {
        for sym in bound_index_symbols(node) {
            out.insert(sym);
        }
        node.for_each_child(&mut |child| collect_bound_symbols(child, out));
    }
}

/// Which half of a scoped reference `<system>.<name>` failed to resolve against
/// the system-reference map. The borrowed slice is the exact segment a caller
/// reports as its `missing_component`.
pub(crate) enum MissingScopedComponent<'a> {
    /// The dotted system prefix is not a known system.
    System(&'a str),
    /// The system exists but does not expose the final component.
    Component(&'a str),
}

/// Resolve a scoped reference `<system>.<name>` against the system-reference map.
///
/// A scoped reference is a dot path of ARBITRARY DEPTH (esm-spec §4.9.2):
/// `A.B.c` walks A → B and takes `c`, so the NAME is the LAST segment and the
/// SYSTEM is the entire dotted prefix — splitting on the FIRST dot instead turns
/// every three-or-more-segment reference into a spurious miss.
/// `build_system_reference_map` registers each nested subsystem under its full
/// dotted path, so the walk is a single prefix lookup.
///
/// Returns `Ok(())` when the string has no `.` (not a scoped reference) or when
/// the system exists AND exposes the component; otherwise reports WHICH half is
/// missing so each caller can build its own `details`/message. This is the one
/// shared resolver behind the three call sites (equation refs, reaction rates,
/// coupling refs) — the resolution rule lives here; only the error records differ.
pub(crate) fn resolve_scoped_ref<'a>(
    name: &'a str,
    system_refs: &HashMap<String, SystemInfo>,
) -> Result<(), MissingScopedComponent<'a>> {
    let Some((system_name, component)) = name.rsplit_once('.') else {
        return Ok(()); // Not a scoped reference — nothing to resolve.
    };
    match system_refs.get(system_name) {
        Some(system) => {
            if system.variables.contains(component)
                || system.species.contains(component)
                || system.parameters.contains(component)
            {
                Ok(())
            } else {
                Err(MissingScopedComponent::Component(component))
            }
        }
        None => Err(MissingScopedComponent::System(system_name)),
    }
}

fn validate_rate_expression(
    rate: &crate::Expr,
    defined_parameters: &HashSet<String>,
    system_refs: &HashMap<String, SystemInfo>,
    reaction_path: &str,
    reaction_id: &str,
    errors: &mut Vec<StructuralError>,
) {
    match rate {
        crate::Expr::Variable(var_name) => {
            // esm-spec §4.9.3: a reaction RATE MAY contain SCOPED REFERENCES. A
            // rate that depends on a coupled system's temperature or photolysis
            // rate (`MeteorologicalSystem.solar_intensity`) is ordinary
            // atmospheric chemistry. Resolving a rate's free symbols against the
            // LOCAL reaction system's parameters only — and reporting
            // `undefined_parameter` for anything dotted — is wrong.
            if var_name.contains('.') {
                // Arbitrary depth (§4.9.2): the NAME is the last segment. A rate
                // ref only cares WHETHER it resolves, not which half is missing.
                if resolve_scoped_ref(var_name, system_refs).is_err() {
                    errors.push(StructuralError {
                        path: reaction_path.to_string(),
                        code: StructuralErrorCode::UnresolvedScopedRef,
                        message: format!("Scoped reference '{var_name}' cannot be resolved"),
                        details: serde_json::json!({
                            "reference": var_name,
                            "reaction_id": reaction_id,
                        }),
                    });
                }
                return;
            }

            if !defined_parameters.contains(var_name) {
                errors.push(StructuralError {
                    path: reaction_path.to_string(),
                    code: StructuralErrorCode::UndefinedParameter,
                    message: format!(
                        "Parameter '{var_name}' referenced in rate expression is not declared"
                    ),
                    details: serde_json::json!({
                        "parameter": var_name,
                        "reaction_id": reaction_id,
                        "expected_in": "parameters"
                    }),
                });
            }
        }
        crate::Expr::Operator(op_node) => {
            // Descend every expression-bearing child (not just `args`), adding
            // any index symbols the node BINDS to the in-scope parameter set so
            // a bound loop index inside the body is not mistaken for an
            // undeclared parameter.
            let bound = bound_index_symbols(op_node);
            if bound.is_empty() {
                op_node.for_each_child(&mut |arg| {
                    validate_rate_expression(
                        arg,
                        defined_parameters,
                        system_refs,
                        reaction_path,
                        reaction_id,
                        errors,
                    )
                });
            } else {
                let mut scope = defined_parameters.clone();
                scope.extend(bound);
                op_node.for_each_child(&mut |arg| {
                    validate_rate_expression(
                        arg,
                        &scope,
                        system_refs,
                        reaction_path,
                        reaction_id,
                        errors,
                    )
                });
            }
        }
        crate::Expr::Number(_) | crate::Expr::Integer(_) => {
            // Numbers are always valid
        }
    }
}

/// The full scoped references `<sub>.<var>` exposed by each DataSource mounted as
/// a subsystem of `model` (RFC pure-io-data-loaders §4.3). `flatten` lowers each
/// to a const-array-backed observed `<model>.<sub>.<var>`, so the owning model's
/// own equations may reference it (`raw.k`, `index(raw.wind, …)`) even though
/// `raw` is not a top-level system. A nested MODEL subsystem is not a DataSource
/// and contributes nothing. Empty for a model with no subsystems.
fn subsystem_scoped_refs(model: &crate::Model) -> HashSet<String> {
    let mut refs = HashSet::new();
    let Some(subs) = &model.subsystems else {
        return refs;
    };
    for (sub_name, value) in subs {
        // ANY mounted subsystem exposes `<sub>.<var>` to the owning model — a
        // DataSource (RFC pure-io-data-loaders §4.3) and equally a MODEL mounted
        // by `ref` (§4.7 subsystem inclusion, e.g. `Solar` from lib/solar.esm,
        // read as `Solar.solar_zenith_angle`). Matching only the DataSource
        // SHAPE meant a ref-mounted model subsystem resolved to nothing, and
        // every reference into it was reported `unresolved_scoped_ref` — which
        // rejected both standard-library inclusion fixtures. The ref resolver
        // has already flattened the mount to `{variables, equations}` by now, so
        // one pass over `variables` (plus `species`, for a reaction subsystem)
        // covers every mount kind.
        for field in ["variables", "species"] {
            let Some(members) = value.get(field).and_then(|v| v.as_object()) else {
                continue;
            };
            for var in members.keys() {
                refs.insert(format!("{sub_name}.{var}"));
            }
        }
    }
    refs
}

pub(crate) fn validate_expression_references_with_systems(
    expr: &crate::Expr,
    defined_vars: &HashSet<String>,
    system_refs: &HashMap<String, SystemInfo>,
    local_scoped: &HashSet<String>,
    base_path: &str,
    equation_index: usize,
    errors: &mut Vec<StructuralError>,
) {
    match expr {
        crate::Expr::Variable(var_name) => {
            // Skip derivatives and built-in functions. The independent variable
            // (`t`), the spatial coordinates and `_var` are NOT special-cased
            // here: they are seeded into `defined_vars` as implicitly-declared
            // symbols (esm-spec §4.9.1), so they resolve like any other name.
            if var_name.starts_with("d(") || is_builtin_function_name(var_name) {
                return; // These are always valid
            }

            // A model-local scoped reference — a DataSource mounted as a
            // subsystem exposes `<sub>.<var>` to the owning model's equations
            // (RFC pure-io-data-loaders §4.3). It is not a top-level system, so
            // it would otherwise be flagged UnresolvedScopedRef.
            if local_scoped.contains(var_name) {
                return;
            }

            // A scoped reference is a dot path of ARBITRARY DEPTH (esm-spec
            // §4.9.2): `A.B.c` walks A → B and takes `c` from it. So the NAME is
            // the LAST segment and the SYSTEM is everything before it —
            // splitting on the FIRST dot and treating segment [1] as the
            // variable turned every three-or-more-segment reference in the
            // corpus into a spurious `unresolved_scoped_ref` (reporting
            // `Meteorology.Temperature.surface_temp` as "variable
            // `Temperature.surface_temp` not found in system `Meteorology`").
            //
            // `build_system_reference_map` registers each nested subsystem under
            // its full dotted path, so the walk is a single lookup of the
            // prefix.
            if var_name.contains('.') {
                // Scoped reference — resolve against the system map. If it
                // resolves, DON'T also flag it as an undefined variable.
                if let Err(missing) = resolve_scoped_ref(var_name, system_refs) {
                    let missing_component = match missing {
                        MissingScopedComponent::System(s) => s,
                        MissingScopedComponent::Component(c) => c,
                    };
                    errors.push(StructuralError {
                        path: base_path.to_string(),
                        code: StructuralErrorCode::UnresolvedScopedRef,
                        message: format!("Scoped reference '{var_name}' cannot be resolved"),
                        details: serde_json::json!({
                            "reference": var_name,
                            "equation_index": equation_index,
                            "missing_component": missing_component
                        }),
                    });
                }
            } else {
                // Regular variable - check if defined locally
                if !defined_vars.contains(var_name) {
                    errors.push(StructuralError {
                        path: base_path.to_string(),
                        code: StructuralErrorCode::UndefinedVariable,
                        message: format!(
                            "Variable '{var_name}' referenced in equation is not declared"
                        ),
                        details: serde_json::json!({
                            "variable": var_name,
                            "equation_index": equation_index,
                            "expected_in": "variables"
                        }),
                    });
                }
            }
        }
        crate::Expr::Operator(op_node) => {
            // esm-spec §4.3.4: a `broadcast` node's `fn` MUST name a scalar
            // operator, and the operand count must be one that operator accepts.
            //
            // This rides the reference walker deliberately. `broadcast.fn` is a
            // NAME embedded in an expression, exactly like the variable names
            // this function resolves, and every expression-bearing block of the
            // document already routes through here — model equations,
            // `initialization_equations`, `guesses`, `tests[].reference`,
            // observed expressions, event conditions and affects, reaction
            // rates, and data-loader `unit_conversion`s. A separate pass would
            // have had to re-enumerate all of them and would have drifted.
            if op_node.op == "broadcast" {
                check_broadcast_fn_node(op_node, base_path, equation_index, errors);
            }
            // Recursively validate every expression-bearing child via the
            // canonical walker — args PLUS the sidecar fields (integral bounds,
            // aggregate/arrayop bodies, filter predicates, table axes,
            // aggregate keys, template bindings) — so a reference hidden
            // outside `args` is not missed. Index symbols the node BINDS
            // (`output_idx`/`ranges`/`var`/`arg`) are added to the in-scope set
            // for the descent so a bound loop index is not flagged as
            // undefined.
            let bound = bound_index_symbols(op_node);
            if bound.is_empty() {
                op_node.for_each_child(&mut |child| {
                    validate_expression_references_with_systems(
                        child,
                        defined_vars,
                        system_refs,
                        local_scoped,
                        base_path,
                        equation_index,
                        errors,
                    )
                });
            } else {
                let mut scope = defined_vars.clone();
                scope.extend(bound);
                op_node.for_each_child(&mut |child| {
                    validate_expression_references_with_systems(
                        child,
                        &scope,
                        system_refs,
                        local_scoped,
                        base_path,
                        equation_index,
                        errors,
                    )
                });
            }
        }
        crate::Expr::Number(_) | crate::Expr::Integer(_) => {
            // Numbers are always valid
        }
    }
}

/// Report a `broadcast` node whose `fn` is unusable (esm-spec §4.3.4).
///
/// The rule is delegated wholesale to [`crate::op_registry::check_broadcast_fn`]
/// — the single source of truth for the operator vocabulary — so `validate()`
/// and the simulate-time gate cannot disagree about which files are acceptable.
/// Both failure shapes it can return become the one `invalid_broadcast_fn`
/// structural code, because from the file's point of view they are one defect:
/// this `fn`/`args` pair is not a scalar operator application.
///
/// Note the deliberately NARROW scope. This is not a general op-registry sweep
/// inside `validate()`: arities of ordinary `op` nodes are still checked only at
/// compile time. `broadcast.fn` is singled out because it is the one operator
/// name that no `op`-keyed check can ever see, and because getting it wrong is
/// silent (issue #101) rather than loud.
fn check_broadcast_fn_node(
    node: &crate::types::ExpressionNode,
    base_path: &str,
    equation_index: usize,
    errors: &mut Vec<StructuralError>,
) {
    use crate::op_registry::OpError;
    let Err(err) = crate::op_registry::check_broadcast_fn(node) else {
        return;
    };
    let (message, details) = match err {
        OpError::BroadcastFn { fn_name, reason } => (
            reason,
            serde_json::json!({
                "broadcast_fn": fn_name,
                "equation_index": equation_index,
            }),
        ),
        OpError::Arity { op, got, expected } => (
            format!(
                "'broadcast' fn '{op}' takes {expected} argument(s), got {got} (esm-spec §4.3.4)"
            ),
            serde_json::json!({
                "broadcast_fn": op,
                "got": got,
                "expected": expected,
                "equation_index": equation_index,
            }),
        ),
        // `check_broadcast_fn` returns only the two shapes above.
        other => (other.to_string(), serde_json::json!({})),
    };
    errors.push(StructuralError {
        path: base_path.to_string(),
        code: StructuralErrorCode::InvalidBroadcastFn,
        message,
        details,
    });
}

fn validate_discrete_event(
    event: &crate::DiscreteEvent,
    event_idx: usize,
    parent_path: &str,
    defined_vars: &HashSet<String>,
    variables: &indexmap::IndexMap<String, crate::types::ModelVariable>,
    errors: &mut Vec<StructuralError>,
) {
    let event_path = format!("{parent_path}/discrete_events/{event_idx}");
    let event_name = event.name.as_deref().unwrap_or("unnamed");

    // A `condition` trigger's expression (§5.3) is an ordinary predicate: an
    // undeclared bare name in it is an `undefined_variable`, carried by the
    // trigger's `expression` field.
    if let crate::DiscreteEventTrigger::Condition { expression } = &event.trigger {
        validate_event_ref_expression(
            expression,
            defined_vars,
            &format!("{event_path}/trigger/expression"),
            errors,
        );
    }

    // Validate affects. The `discrete_parameters` list that used to be checked
    // here is GONE from esm 1.0.0 (RFC unified-variable-model D5): an event may
    // affect unknowns only, so the check that a listed name really was a
    // parameter has become its inverse — `event_affects_parameter`, reached
    // through `affects` — and lives in `validate_event_affects`.
    //
    // A document that still SPELLS `discrete_parameters` (or the companion
    // `functional_affect`) is refused one layer up, not here: every event def in
    // the schema — `DiscreteEvent`, `ContinuousEvent`, and the coupling
    // `CouplingEvent` — is `additionalProperties: false` and lists neither key,
    // so the key never reaches a typed value this pass could inspect. Do not add
    // a structural mirror of that refusal; it would be unreachable. The pin is
    // `test_coupling_event_rejects_removed_0x_keys` in
    // `tests/basic_functionality.rs`.
    if let Some(ref affects) = event.affects {
        validate_event_affects(
            affects,
            &EventAffectsCtx {
                defined_vars,
                variables,
                trigger: Some(&event.trigger),
                event_path: &event_path,
                location: "affects",
                event_name,
                event_type: "discrete",
            },
            errors,
        );
    }
}

/// Structural checks for a continuous event (esm-spec §6.3): every zero-cross
/// `conditions` expression and every `affects`/`affect_neg` equation must
/// reference only declared variables. Mirrors [`validate_discrete_event`].
fn validate_continuous_event(
    event: &crate::ContinuousEvent,
    event_idx: usize,
    parent_path: &str,
    defined_vars: &HashSet<String>,
    variables: &indexmap::IndexMap<String, crate::types::ModelVariable>,
    errors: &mut Vec<StructuralError>,
) {
    let event_path = format!("{parent_path}/continuous_events/{event_idx}");
    let event_name = event.name.as_deref().unwrap_or("unnamed");

    for (cond_idx, condition) in event.conditions.iter().enumerate() {
        validate_event_ref_expression(
            condition,
            defined_vars,
            &format!("{event_path}/conditions/{cond_idx}"),
            errors,
        );
    }
    validate_event_affects(
        &event.affects,
        &EventAffectsCtx {
            defined_vars,
            variables,
            trigger: None,
            event_path: &event_path,
            location: "affects",
            event_name,
            event_type: "continuous",
        },
        errors,
    );
    if let Some(ref affect_neg) = event.affect_neg {
        validate_event_affects(
            affect_neg,
            &EventAffectsCtx {
                defined_vars,
                variables,
                trigger: None,
                event_path: &event_path,
                location: "affect_neg",
                event_name,
                event_type: "continuous",
            },
            errors,
        );
    }
}

/// What [`validate_event_affects`] checks a list of affect equations against:
/// the scope and declarations the names must resolve in, plus what identifies
/// the owning event (and its trigger, when discrete) in a finding.
struct EventAffectsCtx<'a> {
    defined_vars: &'a HashSet<String>,
    variables: &'a indexmap::IndexMap<String, crate::types::ModelVariable>,
    trigger: Option<&'a crate::DiscreteEventTrigger>,
    event_path: &'a str,
    /// The affects list being checked: `"affects"` or `"affect_neg"`.
    location: &'a str,
    event_name: &'a str,
    /// `"discrete"` or `"continuous"`, for the finding's detail payload.
    event_type: &'a str,
}

/// Shared affect-equation checks for discrete and continuous events: each
/// LHS must be a declared variable, and each RHS expression must reference
/// only declared names.
fn validate_event_affects(
    affects: &[crate::AffectEquation],
    ctx: &EventAffectsCtx<'_>,
    errors: &mut Vec<StructuralError>,
) {
    let &EventAffectsCtx {
        defined_vars,
        variables,
        trigger,
        event_path,
        location,
        event_name,
        event_type,
    } = ctx;
    for (affect_idx, affect) in affects.iter().enumerate() {
        // esm 1.0.0: an event may affect UNKNOWNS only. A parameter that
        // changes during a run declares its own `update` block (esm-spec §5.4),
        // which is what replaced `discrete_parameters` and `functional_affect`.
        // The check keys off the AFFECTS TARGET, never off the trigger kind.
        if variables.get(&affect.lhs).map(|v| v.var_type) == Some(crate::VariableType::Parameter) {
            let mut details = serde_json::json!({
                "variable": affect.lhs,
                "variable_type": "parameter",
                "event_name": event_name,
                "event_type": event_type,
                "remedy": remedy_for(&affect.lhs, trigger),
            });
            if let Some(kind) = trigger.map(trigger_kind) {
                details["trigger_type"] = serde_json::json!(kind);
            }
            errors.push(StructuralError {
                path: format!("{event_path}/{location}/{affect_idx}"),
                code: StructuralErrorCode::EventAffectsParameter,
                message: format!(
                    "Event '{event_name}' affects '{}', which is a parameter; an event may affect unknowns only",
                    affect.lhs
                ),
                details,
            });
        }
        // The assignment TARGET (LHS) must be a declared variable — a distinct
        // defect (`event_var_undeclared`) from an ordinary reference. The
        // carrying field (§7.1.2) is the affect's own `lhs`.
        if !defined_vars.contains(&affect.lhs) {
            errors.push(StructuralError {
                path: format!("{event_path}/{location}/{affect_idx}/lhs"),
                code: StructuralErrorCode::EventVarUndeclared,
                message: format!(
                    "Variable '{}' in event {location} is not declared",
                    affect.lhs
                ),
                details: serde_json::json!({
                    "variable": affect.lhs,
                    "event_name": event_name,
                    "event_type": event_type,
                    "location": location,
                    "expected_in": "variables"
                }),
            });
        }
        // The RHS is an ordinary expression: an undeclared bare name in it is an
        // `undefined_variable`, carried by the affect's `rhs` field.
        validate_event_ref_expression(
            &affect.rhs,
            defined_vars,
            &format!("{event_path}/{location}/{affect_idx}/rhs"),
            errors,
        );
    }
}

/// The `kind` string of a discrete trigger, for an `event_affects_parameter`
/// detail payload.
fn trigger_kind(trigger: &crate::DiscreteEventTrigger) -> &'static str {
    match trigger {
        crate::DiscreteEventTrigger::Condition { .. } => "condition",
        crate::DiscreteEventTrigger::Periodic { .. } => "periodic",
        crate::DiscreteEventTrigger::PresetTimes { .. } => "preset_times",
    }
}

/// The 1.0.0 replacement for an event that wrote a parameter, spelled out for
/// the trigger at hand: a `periodic` trigger has an exact one
/// (`update: {kind: "schedule", interval}`), the others are pointed at §5.4.
fn remedy_for(variable: &str, trigger: Option<&crate::DiscreteEventTrigger>) -> String {
    match trigger {
        Some(crate::DiscreteEventTrigger::Periodic { interval, .. }) => format!(
            "declare the change as update: {{kind: \"schedule\", interval: {interval:?}}} on '{variable}' (esm-spec 5.4)"
        ),
        Some(crate::DiscreteEventTrigger::PresetTimes { times }) => format!(
            "declare the change as update: {{kind: \"schedule\", times: {times:?}}} on '{variable}' (esm-spec 5.4)"
        ),
        _ => "declare the change as the parameter's own update (esm-spec 5.4)".to_string(),
    }
}

/// Reference-check an event expression — a continuous/discrete condition, a
/// discrete `condition`-trigger, or an affect RHS. An undeclared bare name is an
/// ordinary `undefined_variable`, reported at `path` (the containing expression
/// FIELD, §7.1.2). The independent variable, `_var`, and the spatial coordinates
/// are already seeded into `defined_vars` (esm-spec §4.9.1), so they resolve like
/// any other name; built-in function heads are skipped.
fn validate_event_ref_expression(
    expr: &crate::Expr,
    defined_vars: &HashSet<String>,
    path: &str,
    errors: &mut Vec<StructuralError>,
) {
    match expr {
        crate::Expr::Variable(var_name) => {
            if !is_builtin_function_name(var_name) && !defined_vars.contains(var_name) {
                errors.push(StructuralError {
                    path: path.to_string(),
                    code: StructuralErrorCode::UndefinedVariable,
                    message: format!(
                        "Variable \"{var_name}\" referenced in event expression is not declared"
                    ),
                    details: serde_json::json!({ "variable": var_name }),
                });
            }
        }
        crate::Expr::Operator(op_node) => {
            op_node.for_each_child(&mut |arg| {
                validate_event_ref_expression(arg, defined_vars, path, errors)
            });
        }
        crate::Expr::Number(_) | crate::Expr::Integer(_) => {
            // Numbers are always valid
        }
    }
}

/// Check for circular dependencies between models
pub(crate) fn check_circular_dependencies_in_models(
    models: &indexmap::IndexMap<String, crate::Model>,
    errors: &mut Vec<StructuralError>,
) {
    let mut dependencies: HashMap<String, HashSet<String>> = HashMap::new();

    // Build dependency graph by analyzing scoped references in equations
    for (model_name, model) in models {
        let mut model_deps = HashSet::new();

        for equation in &model.equations {
            // Check RHS for scoped references
            extract_model_dependencies(&equation.rhs, &mut model_deps, model_name, models);

            // Check LHS for scoped references (though less common)
            extract_model_dependencies(&equation.lhs, &mut model_deps, model_name, models);
        }

        // ...and the Expressions a VARIABLE still carries: a parameter
        // `update`'s trigger / value / unit conversion (§5.4). An observed
        // unknown's defining expression is an equation, walked above.
        for variable in model.variables.values() {
            variable.for_each_expression(&mut |expr| {
                extract_model_dependencies(expr, &mut model_deps, model_name, models)
            });
        }

        dependencies.insert(model_name.clone(), model_deps);
    }

    // Detect cycles using DFS
    let mut visited = HashSet::new();
    let mut rec_stack = HashSet::new();

    for model_name in models.keys() {
        if !visited.contains(model_name)
            && has_cycle_dfs(model_name, &dependencies, &mut visited, &mut rec_stack)
        {
            // Find the actual cycle for error reporting
            let cycle = find_cycle(&dependencies, model_name);
            errors.push(StructuralError {
                path: "/models".to_string(),
                code: StructuralErrorCode::CircularDependency,
                message: format!(
                    "Circular dependency detected in model dependencies: {}",
                    cycle.join(" -> ")
                ),
                details: serde_json::json!({
                    "cycle": cycle,
                    "dependency_type": "model_references"
                }),
            });
            break; // Report only the first cycle found
        }
    }
}

/// Extract model dependencies from an expression by finding scoped references
fn extract_model_dependencies(
    expr: &crate::Expr,
    deps: &mut HashSet<String>,
    self_name: &str,
    models: &indexmap::IndexMap<String, crate::Model>,
) {
    match expr {
        crate::Expr::Variable(var_name) => {
            // Check if it's a scoped reference (e.g., "ModelA.x")
            if let Some(dot_pos) = var_name.find('.') {
                let model_name = &var_name[..dot_pos];
                // A model reading into its OWN mounted subsystem
                // (`EarthSystem.Atmosphere.temp` from inside `EarthSystem`) is
                // NOT a dependency on itself — it is a reference DOWNWARD into
                // its own contents. Counting it produced the self-edge
                // `EarthSystem -> EarthSystem`, which the cycle detector then
                // reported as a circular dependency, rejecting the valid
                // scoped_refs_nested.esm. Mirrors Go `addModelDep`'s
                // `root == self` guard.
                if model_name == self_name {
                    return;
                }
                // Only a real model can be depended ON: a dotted ref into a data
                // loader or a reaction system is not a model edge.
                if models.contains_key(model_name) {
                    deps.insert(model_name.to_string());
                }
            }
        }
        crate::Expr::Operator(op_node) => {
            // Walk every expression-bearing child (args plus the sidecar
            // fields) so cross-model scoped refs hidden in aggregate bodies,
            // filter predicates, integral bounds, etc. are picked up. Only
            // dotted `System.var` refs matter here, so the node's bound index
            // symbols (bare names) are naturally ignored.
            op_node.for_each_child(&mut |arg| {
                extract_model_dependencies(arg, deps, self_name, models)
            });
        }
        crate::Expr::Number(_) | crate::Expr::Integer(_) => {
            // Numbers don't reference models
        }
    }
}

/// Check for cycles using depth-first search.
///
/// Shared with the load-time gate in [`crate::parse`], which builds the same
/// model-dependency graph over raw JSON and must reject circular documents at
/// load — so the ONE DFS lives here and both stacks call it.
pub(crate) fn has_cycle_dfs(
    node: &str,
    graph: &HashMap<String, HashSet<String>>,
    visited: &mut HashSet<String>,
    rec_stack: &mut HashSet<String>,
) -> bool {
    visited.insert(node.to_string());
    rec_stack.insert(node.to_string());

    if let Some(neighbors) = graph.get(node) {
        for neighbor in neighbors {
            if !visited.contains(neighbor) {
                if has_cycle_dfs(neighbor, graph, visited, rec_stack) {
                    return true;
                }
            } else if rec_stack.contains(neighbor) {
                return true;
            }
        }
    }

    rec_stack.remove(node);
    false
}

/// Find the actual cycle path for error reporting. Shared with [`crate::parse`]'s
/// load-time cycle gate (see [`has_cycle_dfs`]).
pub(crate) fn find_cycle(graph: &HashMap<String, HashSet<String>>, start: &str) -> Vec<String> {
    let mut path = vec![];
    let mut visited = HashSet::new();

    if find_cycle_path(start, graph, &mut path, &mut visited) {
        path
    } else {
        vec![start.to_string()] // Fallback
    }
}

/// Helper function to find the actual cycle path
fn find_cycle_path(
    current: &str,
    graph: &HashMap<String, HashSet<String>>,
    path: &mut Vec<String>,
    visited: &mut HashSet<String>,
) -> bool {
    if let Some(start) = path.iter().position(|n| n.as_str() == current) {
        // Found cycle. Drop the acyclic prefix that led INTO the cycle so the
        // reported path names only nodes actually on the cycle, then repeat the
        // start node to close it (e.g. `B -> C -> B`, not `A -> B -> C -> B`).
        path.drain(..start);
        path.push(current.to_string());
        return true;
    }

    if visited.contains(current) {
        return false;
    }

    visited.insert(current.to_string());
    path.push(current.to_string());

    if let Some(neighbors) = graph.get(current) {
        for neighbor in neighbors {
            if find_cycle_path(neighbor, graph, path, visited) {
                return true;
            }
        }
    }

    path.pop();
    false
}
