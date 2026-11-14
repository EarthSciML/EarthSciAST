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
    ComponentUnitEnv, Unit, UnitEnv, build_unit_env, equation_findings, expression_findings,
    parse_unit,
};
use crate::validate::{StructuralError, StructuralErrorCode, SystemInfo, UnitWarning};
use std::collections::{HashMap, HashSet};

#[allow(clippy::too_many_arguments)]
pub(crate) fn validate_model(
    esm_file: &EsmFile,
    model_name: &str,
    model: &crate::Model,
    system_refs: &HashMap<String, SystemInfo>,
    document_units: &HashMap<String, Unit>,
    scope: crate::validate::ValidationScope,
    errors: &mut Vec<StructuralError>,
    warnings: &mut Vec<UnitWarning>,
) {
    let ctx = ModelCtx::new(esm_file, model_name, model, system_refs, document_units);
    if scope == crate::validate::ValidationScope::References {
        validate_model_references(&ctx, errors);
        return;
    }

    // esm-spec §4.9.1.1. A `variables` key spelled with a globally-scoped name
    // is unreachable — `ModelCtx::new` puts the independent variable and `_var`
    // into scope BY NAME, ahead of the declaration map, so every reader of the
    // name receives the implicit symbol instead of the declared quantity
    // (issue #200).
    check_reserved_declaration_names(
        esm_file,
        model.variables.keys(),
        &format!("/models/{model_name}/variables"),
        &format!("Model '{model_name}'"),
        "variable",
        errors,
    );
    // A subsystem is a model, so its `variables` map is a declaration map too —
    // and a MOUNTED subsystem is exactly the shape issue #200 was reported in.
    if let Some(subsystems) = &model.subsystems {
        check_reserved_subsystem_names(
            esm_file,
            subsystems.iter(),
            &format!("/models/{model_name}/subsystems"),
            errors,
        );
    }
    // esm-spec §6.3: inline array data is a shaped variable's value, so on a
    // variable with no `shape` it has nothing to fill.
    check_array_defaults_have_shape(
        model,
        &format!("/models/{model_name}"),
        &format!("Model '{model_name}'"),
        errors,
    );

    // esm-spec §6.3.1: what an equation's left-hand side may name — never a
    // parameter, and no index symbol no `faq` binds. Subsystems included.
    errors.extend(lhs_name_errors(esm_file, model_name, model));

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

    // An observed defined (transitively) in terms of itself has no evaluation
    // order, and the equations alone decide it — esm-spec §4.9.6. Checked here,
    // beside the other whole-model structural checks, so `esm validate` names
    // the cycle instead of the build naming an innocent bystander (issue #181).
    check_observed_dependency_cycle(model_name, model, ctx.class(), errors);

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
/// The reference-integrity half of [`validate_model`]
/// ([`crate::validate::ValidationScope::References`]): the same checks, in the
/// same order, less those that report only other codes (declaration names,
/// array defaults, left-hand-side names, equation counts, units, observed
/// cycles, broadcast shapes).
fn validate_model_references(ctx: &ModelCtx<'_>, errors: &mut Vec<StructuralError>) {
    ctx.check_initialization_equation_refs(errors);
    ctx.check_guess_refs(errors);
    ctx.check_test_reference_refs(errors);
    ctx.check_equation_refs(errors);
    ctx.check_aggregate_nodes(errors);
    ctx.check_update_expression_refs(errors);
    ctx.check_discrete_events(errors);
    ctx.check_continuous_events(errors);
}

/// Whether a name is declared, for the event checks, which read both a model's
/// [`DeclaredNames`] and a reaction system's plain set.
trait DeclaredLookup {
    fn declares(&self, name: &str) -> bool;
}

impl<S: std::hash::BuildHasher> DeclaredLookup for HashSet<String, S> {
    fn declares(&self, name: &str) -> bool {
        self.contains(name)
    }
}

/// The names a model's expressions may read: its own variables, borrowed, and
/// the implicitly declared (and, for a coupled model, document-declared) ones.
struct DeclaredNames<'a> {
    vars: HashSet<&'a str, rustc_hash::FxBuildHasher>,
    other: HashSet<String, rustc_hash::FxBuildHasher>,
}

impl DeclaredLookup for DeclaredNames<'_> {
    fn declares(&self, name: &str) -> bool {
        self.vars.contains(name) || self.other.contains(name)
    }
}

struct ModelCtx<'a> {
    esm_file: &'a EsmFile,
    model_name: &'a str,
    model: &'a crate::Model,
    system_refs: &'a HashMap<String, SystemInfo>,
    /// The document's top-level scoped-reference units
    /// ([`crate::units::document_scoped_units`]), built once per validation.
    document_units: &'a HashMap<String, Unit>,
    model_path: String,
    /// The §6.3.1 classification of this model, derived once: which unknowns are
    /// ODE states, which are observed (and by which equation), and which
    /// parameters are Brownian / discrete. Every check below that used to branch
    /// on a declared type reads it.
    /// Computed on first use: the reference checks need it only for a
    /// `distinct` `faq` node.
    class: std::cell::OnceCell<crate::classification::Classification>,
    defined_vars: DeclaredNames<'a>,
    /// Which equations contain a `faq` node, noted by the equation reference
    /// check (which walks every equation first) so the aggregate check walks
    /// only those. `None` until the reference check has run.
    faq_equations: std::cell::RefCell<Option<Vec<bool>>>,
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
        document_units: &'a HashMap<String, Unit>,
    ) -> Self {
        let model_path = format!("/models/{model_name}");
        let mut defined_vars = DeclaredNames {
            vars: model.variables.keys().map(String::as_str).collect(),
            other: HashSet::default(),
        };

        // esm-spec §4.9.1: three classes of symbol are in scope WITHOUT appearing in
        // the `variables` map, and none of them is an `undefined_variable`. Adding
        // them to the in-scope set here is what lets every reference check below —
        // equations, observed expressions, event conditions and event affects —
        // resolve them uniformly.
        defined_vars
            .other
            .extend(implicitly_declared_symbols(esm_file));

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
            defined_vars.other.extend(document_declared_names(esm_file));
        }

        ModelCtx {
            esm_file,
            model_name,
            model,
            system_refs,
            document_units,
            model_path,
            class: std::cell::OnceCell::new(),
            defined_vars,
            faq_equations: std::cell::RefCell::new(None),
            local_scoped,
            is_coupled,
        }
    }

    fn class(&self) -> &crate::classification::Classification {
        self.class
            .get_or_init(|| crate::classification::Classification::of(self.model))
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
        self.check_refs_bound(expr, path, idx, &HashSet::new(), errs);
    }

    /// [`Self::check_refs`] with `bound` — binders the surrounding construct
    /// (the other side of an equation) introduces — also in scope.
    fn check_refs_bound(
        &self,
        expr: &crate::Expr,
        path: &str,
        idx: usize,
        bound: &HashSet<String>,
        errs: &mut Vec<StructuralError>,
    ) {
        // Any binder introduced ANYWHERE in this expression is in scope
        // throughout it (a `makearray` binds its grid indices for every
        // value; see `collect_bound_symbols`). Seed those before the descent,
        // which then adds nested binders on top per node.
        // The binders are layered over the declared set rather than joined to
        // a copy of it, which would make this check quadratic in the
        // equation count.
        let mut binders: HashSet<String> = bound.clone();
        collect_bound_symbols(expr, &mut binders);
        self.check_refs_with(expr, path, idx, &binders, errs);
    }

    /// [`Self::check_refs_bound`] with every binder of `expr` already in
    /// `binders`.
    fn check_refs_with(
        &self,
        expr: &crate::Expr,
        path: &str,
        idx: usize,
        binders: &HashSet<String>,
        errs: &mut Vec<StructuralError>,
    ) {
        self.check_refs_seen(expr, path, idx, binders, errs, &mut RefWalkSeen::default());
    }

    /// [`Self::check_refs_with`], noting what the walk met in `seen`.
    fn check_refs_seen(
        &self,
        expr: &crate::Expr,
        path: &str,
        idx: usize,
        binders: &HashSet<String>,
        errs: &mut Vec<StructuralError>,
        seen: &mut RefWalkSeen,
    ) {
        let is_declared = |name: &str| self.defined_vars.declares(name);
        let declared = NameScope::Set(&is_declared);
        let scope = if binders.is_empty() {
            declared
        } else {
            NameScope::WithSet(&declared, binders)
        };
        references_in_scope(
            expr,
            &scope,
            self.system_refs,
            &self.local_scoped,
            path,
            idx,
            errs,
            seen,
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
        if self.is_coupled {
            return;
        }
        // The model's UNKNOWNS, sorted. Sorted rather than declaration-ordered
        // because `Model::variables` is a `HashMap`, which discards the JSON key
        // order at parse: a stable answer is the only one this binding can give.
        let unknown_vars: Vec<String> = self.class().unknowns();
        let defining_equations = count_defining_equations(&self.model.equations);
        if defining_equations != unknown_vars.len() {
            let (extra_equations_for, missing_equations_for) =
                analyze_equation_mismatch(&self.model.equations, &unknown_vars);

            // The settled cross-binding detail key is `unknowns`
            // (tests/invalid/expected_errors.json): esm 1.0.0 balances UNKNOWNS
            // against equations, and `state_variables` named a type that no longer
            // exists.
            let mut details = serde_json::json!({
                "unknowns": unknown_vars,
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
                    unknown_vars.len()
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
    fn check_unit_declarations(&self, errors: &mut Vec<StructuralError>) -> ComponentUnitEnv<'a> {
        let (own, unit_parse_failures) = build_unit_env(&self.model.variables);
        let unit_env =
            ComponentUnitEnv::new(own, self.model.subsystems.as_ref(), self.document_units);
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
            // A binder either side introduces is in scope on both: an indexed
            // definition `w[k+1] ~ faq{k}(…)` subscripts its LHS with the
            // RHS's loop index.
            let mut eq_bound = HashSet::new();
            collect_bound_symbols(&equation.lhs, &mut eq_bound);
            collect_bound_symbols(&equation.rhs, &mut eq_bound);
            for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
                self.check_refs_bound(
                    expr,
                    &format!("{eq_path}/{field}"),
                    eq_idx,
                    &eq_bound,
                    errors,
                );
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
        unit_env: &ComponentUnitEnv<'_>,
        errors: &mut Vec<StructuralError>,
        warnings: &mut Vec<UnitWarning>,
    ) {
        let mut faq = Vec::with_capacity(self.model.equations.len());
        for (eq_idx, equation) in self.model.equations.iter().enumerate() {
            let eq_path = format!("{}/equations/{eq_idx}", self.model_path);
            faq.push(self.check_one_equation_refs(eq_idx, equation, &eq_path, errors));
            for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
                // A declared `const` unit string that does not resolve is a
                // defect at the containing expression field (esm-spec §4.8.5).
                for units in crate::units::unresolvable_const_units(expr) {
                    errors.push(StructuralError {
                        path: format!("{eq_path}/{field}"),
                        code: StructuralErrorCode::UnitParseError,
                        message: format!("Unit string '{units}' is not a recognised unit"),
                        details: serde_json::json!({ "units": units }),
                    });
                }
            }

            // Validate dimensional consistency of the equation via expression-level
            // propagation over the Expr AST. Every finding is reported: a provable
            // mismatch is a hard `unit_inconsistency` error, an undeterminable
            // dimension stays a non-blocking warning. See `record_unit_findings`.
            record_unit_findings(
                equation_findings(equation, unit_env),
                &eq_path,
                &format!("Equation {eq_idx}"),
                errors,
                warnings,
            );
        }
        *self.faq_equations.borrow_mut() = Some(faq);
    }

    /// The reference-integrity part of [`Self::check_equations`].
    fn check_equation_refs(&self, errors: &mut Vec<StructuralError>) {
        let mut faq = Vec::with_capacity(self.model.equations.len());
        for (eq_idx, equation) in self.model.equations.iter().enumerate() {
            let eq_path = format!("{}/equations/{eq_idx}", self.model_path);
            faq.push(self.check_one_equation_refs(eq_idx, equation, &eq_path, errors));
        }
        *self.faq_equations.borrow_mut() = Some(faq);
    }

    /// Returns whether the equation contains a `faq` node.
    fn check_one_equation_refs(
        &self,
        eq_idx: usize,
        equation: &crate::types::Equation,
        eq_path: &str,
        errors: &mut Vec<StructuralError>,
    ) -> bool {
        // Reference integrity attaches to the containing expression FIELD
        // (§7.1.2): an undefined name on the RHS is reported at
        // `.../equations/<i>/rhs`, not at the whole equation. (Dimensional
        // findings stay at the equation level — an inconsistency is a
        // property of the equation, not of one side.)
        // A binder either side introduces is in scope on both: an indexed
        // definition `w[k+1] ~ faq{k}(…)` subscripts its LHS with the
        // RHS's loop index.
        // Most equations bind nothing, and then the binders of both sides are
        // the empty set: walk once on that assumption, and collect the binders
        // and walk again only when the walk meets a binding node (or an `enum`
        // node, whose subtree it does not enter).
        let no_binders = HashSet::new();
        let mut found = Vec::new();
        let mut seen = RefWalkSeen::default();
        for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
            let path = format!("{eq_path}/{field}");
            self.check_refs_seen(expr, &path, eq_idx, &no_binders, &mut found, &mut seen);
        }
        if !seen.binder && !seen.enum_node {
            errors.append(&mut found);
            return seen.faq;
        }
        let mut eq_bound = HashSet::new();
        let mut faq = false;
        collect_bound_symbols_noting_faq(&equation.lhs, &mut eq_bound, &mut faq);
        collect_bound_symbols_noting_faq(&equation.rhs, &mut eq_bound, &mut faq);
        // `eq_bound` holds every binder of both sides already.
        for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
            self.check_refs_with(
                expr,
                &format!("{eq_path}/{field}"),
                eq_idx,
                &eq_bound,
                errors,
            );
        }
        faq
    }

    /// Static `faq`-node constraints (RFC semiring-faq-unified-ir): an
    /// undeclared `from` index set, a value-equality join over an unportable
    /// (float/null) categorical key, and a value-invention `distinct` node that
    /// reads a state variable (relational work on the continuous hot path). Each
    /// is decidable from this one document, so it belongs in `validate()`.
    fn check_aggregate_nodes(&self, errors: &mut Vec<StructuralError>) {
        // The leaves that seed CONTINUOUS in the cadence partition
        // (CONFORMANCE_SPEC.md §5.7.2): ODE states, algebraic unknowns, and
        // Brownian parameters. A `faq` reading any of them classes
        // CONTINUOUS, which guard 2 forbids for relational work. (An OBSERVED
        // unknown's class depends on its defining equation, which only the cadence
        // pass resolves; this static check stays with the leaves it can decide.)
        let state_var_set: std::cell::OnceCell<HashSet<&str>> = std::cell::OnceCell::new();
        let is_state = |name: &str| {
            state_var_set
                .get_or_init(|| {
                    let class = self.class();
                    class
                        .ode_states
                        .iter()
                        .chain(&class.algebraic_unknowns)
                        .chain(&class.brownian_parameters)
                        .map(String::as_str)
                        .collect()
                })
                .contains(name)
        };
        validate_aggregate_constraints(
            self.esm_file,
            &format!("/models/{}", self.model_name),
            self.model,
            &is_state,
            self.faq_equations.borrow().as_deref(),
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
        unit_env: &ComponentUnitEnv<'_>,
        errors: &mut Vec<StructuralError>,
        warnings: &mut Vec<UnitWarning>,
    ) {
        for (var_name, rhs) in &self.class().observed_definitions {
            let Some(variable) = self.model.variables.get(var_name) else {
                continue;
            };
            let declared = variable.units.as_deref().and_then(|u| parse_unit(u).ok());
            record_unit_findings(
                expression_findings(rhs, declared.as_ref(), unit_env),
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
        // Only a variable with an `update` carries an expression here.
        let mut var_names: Vec<&String> = self
            .model
            .variables
            .iter()
            .filter(|(_, v)| v.update.is_some())
            .map(|(n, _)| n)
            .collect();
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
    // Identical scales ⇒ no conversion is implied ⇒ the coefficient is free.
    // Decided exactly (esm-spec §4.8.1): a tolerance here would let the order a
    // binding folded its scale arithmetic in decide whether a coefficient is
    // checked at all.
    if src.exact_scale() == declared.exact_scale() {
        return;
    }

    // The expected factor is formed EXACTLY and rounded once; the tolerance
    // below only absorbs the literal's own decimal spelling.
    let expected = src.exact_scale().divide(declared.exact_scale()).to_f64();
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
        // Only a variable with an `update` names a source.
        let mut var_names: Vec<&String> = model
            .variables
            .iter()
            .filter(|(_, v)| v.update.is_some())
            .map(|(n, _)| n)
            .collect();
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

/// Does the document still hold a `{ref}` mount: a subsystem, at any depth of
/// a model or reaction system, that is still a `{"ref": …}` edge? Mounting one
/// merges its file's `index_sets` into the document's (esm-spec §4.7), so an
/// index set the document does not declare may still arrive.
pub(crate) fn has_unmounted_refs(esm_file: &EsmFile) -> bool {
    fn walk(node: &serde_json::Value) -> bool {
        node.get("ref").is_some()
            || node
                .get("subsystems")
                .and_then(|s| s.as_object())
                .is_some_and(|subs| subs.values().any(walk))
    }
    let in_models = esm_file
        .models
        .iter()
        .flatten()
        .any(|(_, m)| m.subsystems.iter().flatten().any(|(_, s)| walk(s)));
    let in_reaction_systems = esm_file
        .reaction_systems
        .iter()
        .flatten()
        .any(|(_, r)| r.subsystems.iter().flatten().any(|(_, s)| walk(s)));
    in_models || in_reaction_systems
}

/// Is index set `name` a RECORD AXIS: an `interval` carrying `"records": true`
/// (esm-spec §8.5.1)? `None` when that is not decidable yet: the document does
/// not declare `name` while `unmounted_refs` (a `{ref}` still to be mounted
/// could declare it). An index set nothing can declare any more is not one.
pub(crate) fn record_axis_state(
    esm_file: &EsmFile,
    name: &str,
    unmounted_refs: bool,
) -> Option<bool> {
    match esm_file.index_sets.as_ref().and_then(|s| s.get(name)) {
        Some(set) => Some(set.kind == "interval" && set.records == Some(true)),
        None if unmounted_refs => None,
        None => Some(false),
    }
}

/// The declared `shape` of the variable a scoped name `Model[.Sub…].var` (or
/// `ReactionSystem[.Sub…].parameter`, or `…species`) names: `Some(None)` when
/// it declares none, `None` when the document does not reach that declaration
/// (no such component or variable, or one still behind an unmounted `ref`).
/// Walks the document by reference.
pub(crate) fn declared_variable_shape(
    esm_file: &EsmFile,
    scoped: &str,
) -> Option<Option<Vec<String>>> {
    let mut parts: Vec<&str> = scoped.split('.').collect();
    let var = parts.pop()?;
    let (first, rest) = parts.split_first()?;
    let (subsystems, tables): (_, &[&str]) =
        if let Some(model) = esm_file.models.as_ref().and_then(|m| m.get(*first)) {
            if rest.is_empty() {
                return Some(model.variables.get(var)?.shape.clone());
            }
            (model.subsystems.as_ref(), &["variables"])
        } else {
            let rs = esm_file.reaction_systems.as_ref()?.get(*first)?;
            if rest.is_empty() {
                if let Some(p) = rs.parameters.get(var) {
                    return Some(p.shape.clone());
                }
                rs.species.get(var)?;
                return Some(None);
            }
            (rs.subsystems.as_ref(), &["parameters", "species"])
        };
    let (sub, deeper) = rest.split_first()?;
    let mut node = subsystems?.get(*sub)?;
    for seg in deeper {
        node = node.get("subsystems")?.get(*seg)?;
    }
    let decl = tables
        .iter()
        .find_map(|t| node.get(*t).and_then(|vars| vars.get(var)))?;
    match decl.get("shape") {
        None | Some(serde_json::Value::Null) => Some(None),
        Some(shape) => shape
            .as_array()?
            .iter()
            .map(|d| d.as_str().map(str::to_string))
            .collect::<Option<Vec<_>>>()
            .map(Some),
    }
}

/// One parameter carrying an `update`, as [`for_each_updated_variable`] hands
/// it out.
struct UpdatedVariable<'a> {
    /// The dotted `Component[.Sub…].name`.
    scoped: &'a str,
    /// The JSON pointer of the variable's (or reaction-system parameter's)
    /// declaration.
    pointer: &'a str,
    name: &'a str,
    /// Its declared `shape`, `None` when it declares none.
    shape: Option<&'a [String]>,
    update: &'a crate::ParameterUpdateSpec,
}

/// Calls `f` for every variable carrying an `update`: each model's
/// `variables` and each reaction system's `parameters`, in every top-level
/// component and every subsystem at any depth, in sorted name order within
/// each component. Subsystems are read in place: only a declaration that
/// carries an `update` is decoded, and only its `shape` and `update`; one that
/// does not decode is the schema's finding and is skipped.
fn for_each_updated_variable(esm_file: &EsmFile, f: &mut impl FnMut(UpdatedVariable<'_>)) {
    fn sorted_updated<'v, V>(
        vars: impl Iterator<Item = (&'v String, &'v V)>,
        has_update: impl Fn(&V) -> bool,
    ) -> Vec<(&'v String, &'v V)> {
        let mut out: Vec<_> = vars.filter(|(_, v)| has_update(v)).collect();
        out.sort_by(|a, b| a.0.cmp(b.0));
        out
    }
    fn subsystem(
        sub: &serde_json::Value,
        table: &str,
        scope: &str,
        path: &str,
        f: &mut impl FnMut(UpdatedVariable<'_>),
    ) {
        if let Some(vars) = sub.get(table).and_then(|v| v.as_object()) {
            for (name, decl) in sorted_updated(vars.iter(), |v| v.get("update").is_some()) {
                let Ok(update) = <crate::ParameterUpdateSpec as serde::Deserialize>::deserialize(
                    &decl["update"],
                ) else {
                    continue;
                };
                let shape: Option<Vec<String>> = match decl.get("shape") {
                    None | Some(serde_json::Value::Null) => None,
                    Some(s) => match <Vec<String> as serde::Deserialize>::deserialize(s) {
                        Ok(s) => Some(s),
                        Err(_) => continue,
                    },
                };
                f(UpdatedVariable {
                    scoped: &format!("{scope}.{name}"),
                    pointer: &format!("{path}/{table}/{name}"),
                    name,
                    shape: shape.as_deref(),
                    update: &update,
                });
            }
        }
        for (name, inner) in sub
            .get("subsystems")
            .and_then(|s| s.as_object())
            .into_iter()
            .flatten()
        {
            subsystem(
                inner,
                table,
                &format!("{scope}.{name}"),
                &format!("{path}/subsystems/{name}"),
                f,
            );
        }
    }
    for (model_name, model) in esm_file.models.iter().flatten() {
        let path = format!("/models/{model_name}");
        for (name, var) in sorted_updated(model.variables.iter(), |v| v.update.is_some()) {
            let Some(update) = var.update.as_ref() else {
                continue;
            };
            f(UpdatedVariable {
                scoped: &format!("{model_name}.{name}"),
                pointer: &format!("{path}/variables/{name}"),
                name,
                shape: var.shape.as_deref(),
                update,
            });
        }
        for (name, sub) in model.subsystems.iter().flatten() {
            subsystem(
                sub,
                "variables",
                &format!("{model_name}.{name}"),
                &format!("{path}/subsystems/{name}"),
                f,
            );
        }
    }
    for (rs_name, rs) in esm_file.reaction_systems.iter().flatten() {
        let path = format!("/reaction_systems/{rs_name}");
        for (name, param) in sorted_updated(rs.parameters.iter(), |p| p.update.is_some()) {
            let Some(update) = param.update.as_ref() else {
                continue;
            };
            f(UpdatedVariable {
                scoped: &format!("{rs_name}.{name}"),
                pointer: &format!("{path}/parameters/{name}"),
                name,
                shape: param.shape.as_deref(),
                update,
            });
        }
        for (name, sub) in rs.subsystems.iter().flatten() {
            subsystem(
                sub,
                "parameters",
                &format!("{rs_name}.{name}"),
                &format!("{path}/subsystems/{name}"),
                f,
            );
        }
    }
}

/// The JSON pointer of rule `i` of the `update` of the variable declared at
/// `var_pointer`: `/update` for the single-rule form, `/update/<i>` for the
/// array form (esm-spec §8.5.1).
fn update_rule_pointer(var_pointer: &str, is_array: bool, i: usize) -> String {
    if is_array {
        format!("{var_pointer}/update/{i}")
    } else {
        format!("{var_pointer}/update")
    }
}

/// The `to` of every `variable_map` entry with transform `param_to_var` in a
/// coupling sequence, keyed by its `from`, in coupling order. Built once per
/// pass, so a parameter's record shapes cost one lookup, not a coupling scan.
pub(crate) fn param_to_var_targets(coupling: &[crate::CouplingEntry]) -> HashMap<&str, Vec<&str>> {
    let mut out: HashMap<&str, Vec<&str>> = HashMap::new();
    for entry in coupling {
        if let crate::CouplingEntry::VariableMap {
            from,
            to,
            transform: crate::VariableMapTransform::Named(t),
            ..
        } = entry
            && t == "param_to_var"
        {
            out.entry(from.as_str()).or_default().push(to.as_str());
        }
    }
    out
}

/// The record shapes of a data-fed parameter (esm-spec §8.5.1) that a
/// document shows, gathered by [`record_shapes`].
pub(crate) struct RecordShapes {
    /// Every record shape that could be decided: the declared `shape` when
    /// the parameter declares one (`[]` included), else the declared `shape`
    /// of each `param_to_var` target whose declaration resolves.
    pub(crate) shapes: Vec<Vec<String>>,
    /// The parameter declares no `shape` and is the `from` of no
    /// `param_to_var` entry of the coupling: its record shape is empty.
    pub(crate) unmapped: bool,
}

/// The record shapes of the parameter scoped `me`, declaring `own_shape`,
/// against the `param_to_var` edges `targets` (esm-spec §8.5.1 "The record
/// shape"). The one statement of which shapes are a parameter's record
/// shapes; validation passes the loaded coupling's edges, `flatten` those of
/// the coupling expanded past every `coupling_import`. A target whose
/// declaration does not resolve is left out, never read as empty.
pub(crate) fn record_shapes(
    esm_file: &EsmFile,
    targets: &HashMap<&str, Vec<&str>>,
    me: &str,
    own_shape: Option<&[String]>,
) -> RecordShapes {
    if let Some(own_shape) = own_shape {
        return RecordShapes {
            shapes: vec![own_shape.to_vec()],
            unmapped: false,
        };
    }
    let Some(mapped) = targets.get(me) else {
        return RecordShapes {
            shapes: Vec::new(),
            unmapped: true,
        };
    };
    RecordShapes {
        shapes: mapped
            .iter()
            .filter_map(|to| declared_variable_shape(esm_file, to))
            .map(Option::unwrap_or_default)
            .collect(),
        unmapped: false,
    }
}

/// esm-spec §8.5.1 over a parameter's record shapes, given what a record axis
/// is (`None`: not decidable yet, an index set an unmounted `{ref}` could
/// still declare). `Err(shape)` names a shape that breaks rule 2
/// (`record_axis_misplaced`): a known record axis anywhere but first, or
/// decidable shapes that disagree about beginning with one. Otherwise
/// `Ok(Some(2))` when the decidable shapes begin with a record axis,
/// `Ok(Some(1))` when they do not (or there are no shapes at all: an empty
/// record shape), and `Ok(None)` when no shape's first entry is decidable.
/// Shared by validation, `flatten` (`loader_fields`) and the raw-document
/// EarthSciIO caller.
pub(crate) fn records_from_shapes(
    shapes: &[Vec<String>],
    is_record_axis: impl Fn(&str) -> Option<bool>,
) -> Result<Option<u8>, Vec<String>> {
    if let Some(bad) = shapes
        .iter()
        .find(|s| s.iter().skip(1).any(|d| is_record_axis(d) == Some(true)))
    {
        return Err(bad.clone());
    }
    if shapes.is_empty() {
        return Ok(Some(1));
    }
    let begins = |s: &Vec<String>| match s.first() {
        None => Some(false),
        Some(d) => is_record_axis(d),
    };
    let mut decided = shapes.iter().filter_map(|s| begins(s).map(|b| (s, b)));
    let Some((_, first)) = decided.next() else {
        return Ok(None);
    };
    if let Some((bad, _)) = decided.find(|(_, b)| *b != first) {
        return Err(bad.clone());
    }
    Ok(Some(if first { 2 } else { 1 }))
}

/// Is a source with this `temporal` block time-varying: does the block anchor
/// at a non-empty `start` (esm-spec §8.5.1 rule 3)? Without one the source is
/// time-invariant and has no successor record.
fn source_has_temporal_start(temporal: &crate::types::DataSourceTemporal) -> bool {
    temporal.start.as_deref().is_some_and(|s| !s.is_empty())
}

/// One esm-spec §8.5.1 finding on a parameter's `update` rule.
struct RecordFinding {
    code: &'static str,
    message: String,
    details: serde_json::Value,
}

impl RecordFinding {
    fn structural_code(&self) -> StructuralErrorCode {
        match self.code {
            crate::diagnostic::codes::RECORD_AXIS_MISPLACED => {
                StructuralErrorCode::RecordAxisMisplaced
            }
            crate::diagnostic::codes::RECORD_AXIS_TIME_INVARIANT_SOURCE => {
                StructuralErrorCode::RecordAxisTimeInvariantSource
            }
            _ => StructuralErrorCode::RecordsPerSampleInvalid,
        }
    }
}

/// What one pass over a document's record shapes knows: the `param_to_var`
/// edges (built once), whether an empty record shape may still be filled by
/// a `coupling_import` (`defer_empty`), and whether an undeclared index set
/// may still be declared by an unmounted `{ref}`.
struct RecordPass<'a> {
    esm_file: &'a EsmFile,
    targets: HashMap<&'a str, Vec<&'a str>>,
    defer_empty: bool,
    unmounted_refs: bool,
}

impl<'a> RecordPass<'a> {
    fn new(esm_file: &'a EsmFile, defer_empty: bool) -> Self {
        Self {
            esm_file,
            targets: param_to_var_targets(esm_file.coupling.as_deref().unwrap_or_default()),
            defer_empty,
            unmounted_refs: has_unmounted_refs(esm_file),
        }
    }

    /// The record count of the parameter scoped `me`, declaring `own_shape`:
    /// `Err(shape)` on a rule-2 break, `Ok(None)` when not decidable here.
    fn count(
        &self,
        me: &str,
        own_shape: Option<&[String]>,
    ) -> (RecordShapes, Result<Option<u8>, Vec<String>>) {
        let found = record_shapes(self.esm_file, &self.targets, me, own_shape);
        let n = records_from_shapes(&found.shapes, |d| {
            record_axis_state(self.esm_file, d, self.unmounted_refs)
        });
        (found, n)
    }
}

/// Rules 2 and 3 of esm-spec §8.5.1 and the agreement of a written
/// (deprecated) `records_per_sample` with the record shape, for ONE `data`
/// rule of the parameter `var_name` reading `source`, given its record shapes
/// and their count from [`RecordPass::count`]. A record shape that cannot be
/// decided is skipped; an empty record shape is judged against a written
/// value only when nothing could still bring a target (`defer_empty` off, or
/// the parameter not unmapped). Rule 2 first; rule 3 only when the shape
/// gives two records; the agreement independently.
fn check_data_rule(
    pass: &RecordPass<'_>,
    found: &RecordShapes,
    counted: &Result<Option<u8>, Vec<String>>,
    var_name: &str,
    source_name: &str,
    source: &crate::DataSource,
    binding: &crate::types::DataSourceBinding,
) -> Vec<RecordFinding> {
    use crate::diagnostic::codes;
    let records = match counted {
        Ok(Some(n)) => *n,
        Ok(None) => return Vec::new(),
        Err(shape) => {
            return vec![RecordFinding {
                code: codes::RECORD_AXIS_MISPLACED,
                message: format!(
                    "Parameter '{var_name}' is fed by data source '{source_name}' and its \
                     record shape {shape:?} names a record axis anywhere but first, or its \
                     record shapes disagree about beginning with one (esm-spec §8.5.1)"
                ),
                details: serde_json::json!({"variable": var_name, "shape": shape}),
            }];
        }
    };
    let mut out = Vec::new();
    if records == 2
        && !source
            .temporal
            .as_ref()
            .is_some_and(source_has_temporal_start)
    {
        let why = if source.temporal.is_none() {
            "declares no temporal block"
        } else {
            "declares no temporal start"
        };
        out.push(RecordFinding {
            code: codes::RECORD_AXIS_TIME_INVARIANT_SOURCE,
            message: format!(
                "Parameter '{var_name}' has a record shape beginning with a record axis, so it \
                 receives two records per sample from data source '{source_name}', which \
                 {why}, so it is time-invariant and has no successor record"
            ),
            details: serde_json::json!({"variable": var_name, "source": source_name}),
        });
    }
    let decided = !found.shapes.is_empty() || (found.unmapped && !pass.defer_empty);
    if let Some(written) = binding.written_records_per_sample(Some(source))
        && written != records
        && decided
    {
        out.push(RecordFinding {
            code: codes::RECORDS_PER_SAMPLE_INVALID,
            message: format!(
                "Parameter '{var_name}' writes the deprecated records_per_sample {written}, \
                 but its record shape {:?} gives it {records} record(s) per sample: two \
                 exactly when the record shape begins with an interval index set carrying \
                 \"records\": true (esm-spec §8.5.1)",
                found.shapes.first().cloned().unwrap_or_default()
            ),
            details: serde_json::json!({
                "variable": var_name,
                "written": written,
                "records": records,
            }),
        });
    }
    out
}

/// Walks every rule of a parameter `update`, at any depth, of a model or a
/// reaction system: calls `f(pointer, finding)` for each esm-spec §8.5.1
/// finding, and returns the number of records each data-fed parameter whose
/// rules raised none receives, keyed by its scoped name. The findings are
/// [`check_data_rule`] on each `data` rule whose source is declared (an
/// undeclared one is `data_source_undefined`'s) and, with `report_non_data`,
/// the deprecated `from.records_per_sample` on a non-`data` rule, which only
/// validation reports (esm-spec §8.5.1; `flatten` never does).
fn for_each_record_finding(
    pass: &RecordPass<'_>,
    report_non_data: bool,
    f: &mut impl FnMut(String, RecordFinding),
) -> HashMap<String, u8> {
    let esm_file = pass.esm_file;
    let mut counts = HashMap::new();
    for_each_updated_variable(esm_file, &mut |v| {
        let is_array = matches!(v.update, crate::ParameterUpdateSpec::Several(_));
        let mut counted = None;
        let mut clean = true;
        for (i, rule) in v.update.rules().iter().enumerate() {
            let Some(binding) = rule.value().and_then(|u| u.from.as_ref()) else {
                continue;
            };
            let at = update_rule_pointer(v.pointer, is_array, i);
            let Some(source_name) = rule.data_source() else {
                if report_non_data && binding.records_per_sample.is_some() {
                    f(
                        at,
                        RecordFinding {
                            code: crate::diagnostic::codes::RECORDS_PER_SAMPLE_INVALID,
                            message: format!(
                                "Parameter '{}' sets from.records_per_sample on a \
                                 '{}' rule; only a 'data' rule names a source to read \
                                 records from",
                                v.name,
                                rule.kind()
                            ),
                            details: serde_json::json!({
                                "variable": v.name,
                                "kind": rule.kind(),
                            }),
                        },
                    );
                }
                continue;
            };
            let Some(source) = esm_file
                .data_sources
                .as_ref()
                .and_then(|d| d.get(source_name))
            else {
                continue;
            };
            let (found, n) = counted.get_or_insert_with(|| pass.count(v.scoped, v.shape));
            for finding in check_data_rule(pass, found, n, v.name, source_name, source, binding) {
                clean = false;
                f(at.clone(), finding);
            }
        }
        if clean && let Some((_, Ok(n))) = counted {
            counts.insert(v.scoped.to_string(), n.unwrap_or(1));
        }
    });
    counts
}

/// Record axes (esm-spec §8.5.1), at structural validation:
/// `record_axis_invalid` on an index set carrying `"records": true` whose
/// (folded) `size` is not 2; and, for every parameter `update` rule of a model
/// or reaction system, `record_axis_misplaced`,
/// `record_axis_time_invariant_source` and `records_per_sample_invalid`
/// against the record shapes the loaded document shows. A `param_to_var`
/// target that does not resolve is skipped, and so is a record shape whose
/// first entry is an index set an unmounted `{ref}` could still declare; an
/// empty record shape is judged only when the parameter is the `from` of no
/// inline `param_to_var` entry and the coupling holds no `coupling_import`.
/// What this cannot decide [`check_record_axes_at_flatten`] checks.
pub(crate) fn validate_record_axes(esm_file: &EsmFile, errors: &mut Vec<StructuralError>) {
    for (name, set) in esm_file.index_sets.iter().flatten() {
        if set.kind != "interval" || set.records != Some(true) {
            continue;
        }
        // A size still symbolic (or absent) is not judged here.
        if let Some(size) = set.size
            && size != 2
        {
            errors.push(StructuralError {
                path: format!("/index_sets/{name}"),
                code: StructuralErrorCode::RecordAxisInvalid,
                message: format!(
                    "Index set '{name}' is a record axis (\"records\": true), so its size \
                     must be 2, the record at or before the query time and the next; it is \
                     {size}"
                ),
                details: serde_json::json!({"index_set": name, "size": size}),
            });
        }
    }
    let defer_empty = esm_file
        .coupling
        .iter()
        .flatten()
        .any(|e| matches!(e, crate::CouplingEntry::CouplingImport { .. }));
    let pass = RecordPass::new(esm_file, defer_empty);
    for_each_record_finding(&pass, true, &mut |path, finding| {
        errors.push(StructuralError {
            path,
            code: finding.structural_code(),
            message: finding.message,
            details: finding.details,
        });
    });
}

/// Rules 2 and 3 of esm-spec §8.5.1 and the agreement of a written
/// `records_per_sample`, at flatten, against the `param_to_var` edges of
/// `esm_file`'s coupling, which flatten has already expanded past every
/// `coupling_import` and whose refs are mounted. An empty record shape is
/// judged here. Returns the first finding, its code carried and its message
/// led by the rule's JSON pointer; otherwise the number of records each
/// data-fed parameter receives, keyed by its scoped name, which `flatten`
/// reports in `loader_fields`. `record_axis_invalid` and the deprecated field
/// on a non-`data` rule are validation's, which sees them in full.
pub(crate) fn check_record_axes_at_flatten(
    esm_file: &EsmFile,
) -> Result<HashMap<String, u8>, crate::diagnostic::DiagnosticError> {
    let mut first_error = None;
    let pass = RecordPass::new(esm_file, false);
    let counts = for_each_record_finding(&pass, false, &mut |at, finding| {
        if first_error.is_none() {
            first_error = Some(crate::diagnostic::err(
                finding.code,
                format!("{at}: {}", finding.message),
            ));
        }
    });
    first_error.map_or(Ok(counts), Err)
}

/// The JSON pointers at which the deprecated `records_per_sample` is written
/// in `file` (esm-spec §8.5.1), sorted by plain byte order:
/// `/data_sources/<S>/temporal/records_per_sample`,
/// `/models/<M>[/subsystems/<S>…]/variables/<v>/update[/<i>]/from/records_per_sample`
/// and
/// `/reaction_systems/<R>[/subsystems/<S>…]/parameters/<p>/update[/<i>]/from/records_per_sample`
/// (`/<i>` only for an array-form `update`). Loading a document for which
/// this is non-empty warns once, `deprecated_records_per_sample`. Runs on
/// every load, so a subsystem is scanned as raw JSON for the key, never
/// decoded.
pub fn deprecated_records_per_sample_sites(file: &EsmFile) -> Vec<String> {
    /// The written sites among the rules of one raw `update` value.
    fn raw_update(update: &serde_json::Value, var_pointer: &str, out: &mut Vec<String>) {
        let written = |rule: &serde_json::Value| {
            rule.get("from")
                .and_then(|f| f.get("records_per_sample"))
                .is_some()
        };
        match update {
            serde_json::Value::Array(rules) => {
                for (i, rule) in rules.iter().enumerate() {
                    if written(rule) {
                        out.push(format!(
                            "{}/from/records_per_sample",
                            update_rule_pointer(var_pointer, true, i)
                        ));
                    }
                }
            }
            rule if written(rule) => out.push(format!(
                "{}/from/records_per_sample",
                update_rule_pointer(var_pointer, false, 0)
            )),
            _ => {}
        }
    }
    fn raw_subsystem(sub: &serde_json::Value, table: &str, path: &str, out: &mut Vec<String>) {
        for (name, decl) in sub
            .get(table)
            .and_then(|v| v.as_object())
            .into_iter()
            .flatten()
        {
            if let Some(update) = decl.get("update") {
                raw_update(update, &format!("{path}/{table}/{name}"), out);
            }
        }
        for (name, inner) in sub
            .get("subsystems")
            .and_then(|s| s.as_object())
            .into_iter()
            .flatten()
        {
            raw_subsystem(inner, table, &format!("{path}/subsystems/{name}"), out);
        }
    }
    /// The written sites among the rules of one typed `update`.
    fn typed_update(spec: &crate::ParameterUpdateSpec, var_pointer: &str, out: &mut Vec<String>) {
        let is_array = matches!(spec, crate::ParameterUpdateSpec::Several(_));
        for (i, rule) in spec.rules().iter().enumerate() {
            if rule
                .value()
                .and_then(|v| v.from.as_ref())
                .is_some_and(|b| b.records_per_sample.is_some())
            {
                out.push(format!(
                    "{}/from/records_per_sample",
                    update_rule_pointer(var_pointer, is_array, i)
                ));
            }
        }
    }

    let mut out = Vec::new();
    for (name, source) in file.data_sources.iter().flatten() {
        if source
            .temporal
            .as_ref()
            .is_some_and(|t| t.records_per_sample.is_some())
        {
            out.push(format!("/data_sources/{name}/temporal/records_per_sample"));
        }
    }
    for (model_name, model) in file.models.iter().flatten() {
        let path = format!("/models/{model_name}");
        for (name, var) in &model.variables {
            if let Some(spec) = &var.update {
                typed_update(spec, &format!("{path}/variables/{name}"), &mut out);
            }
        }
        for (name, sub) in model.subsystems.iter().flatten() {
            raw_subsystem(
                sub,
                "variables",
                &format!("{path}/subsystems/{name}"),
                &mut out,
            );
        }
    }
    for (rs_name, rs) in file.reaction_systems.iter().flatten() {
        let path = format!("/reaction_systems/{rs_name}");
        for (name, param) in &rs.parameters {
            if let Some(spec) = &param.update {
                typed_update(spec, &format!("{path}/parameters/{name}"), &mut out);
            }
        }
        for (name, sub) in rs.subsystems.iter().flatten() {
            raw_subsystem(
                sub,
                "parameters",
                &format!("{path}/subsystems/{name}"),
                &mut out,
            );
        }
    }
    out.sort();
    out
}

/// The `deprecated_records_per_sample` load warning for `file`, or `None`
/// when it writes the deprecated field nowhere.
pub(crate) fn deprecated_records_per_sample_warning(file: &EsmFile) -> Option<String> {
    let sites = deprecated_records_per_sample_sites(file);
    (!sites.is_empty()).then(|| {
        format!(
            "deprecated_records_per_sample: `records_per_sample` is deprecated and is removed \
             at esm 3.0.0; the number of records a data-fed parameter receives is said by its \
             record shape, two when its first axis is an interval index set with \
             \"records\": true (esm-spec §8.5.1). Written at: {}.",
            sites.join(", ")
        )
    })
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

/// Why a name is reserved, for the `reserved_variable_name` details payload.
fn reserved_declaration_reason(
    esm_file: &EsmFile,
    name: &str,
) -> Option<(&'static str, &'static str)> {
    if name == independent_variable(esm_file) {
        Some((
            "independent_variable",
            "the document's independent variable",
        ))
    } else if name == crate::flatten::VAR_PLACEHOLDER {
        Some(("operator_placeholder", "the operator-model placeholder"))
    } else {
        None
    }
}

/// `reserved_variable_name` for every key of one declaration map spelled with a
/// globally-scoped name (esm-spec §4.9.1.1).
///
/// The independent variable and `_var` are in scope in every component and are
/// resolved BY NAME ahead of the declaration maps — `ModelCtx::new` extends
/// `defined_vars` with exactly these two — so the declaration is unreachable:
/// the implicit symbol shadows it, not the other way round. Same reserved set as
/// `parse::reject_reserved_index_symbols` uses for a `faq` binder,
/// stated once per rule so the two cannot drift.
///
/// Findings are emitted in sorted key order, matching the peer bindings: two of
/// the five cannot reproduce the authored key order at all (Go decodes
/// `variables` into a plain map and this crate's own typed layer sorts its
/// unknowns for the same reason), so sorted is the ordering every binding can
/// give. Takes the KEYS rather than the map so the three declaration maps —
/// which are not all the same container type — share one implementation.
fn check_reserved_declaration_names<'a, I: IntoIterator<Item = &'a String>>(
    esm_file: &EsmFile,
    declarations: I,
    container_path: &str,
    owner: &str,
    kind: &str,
    errors: &mut Vec<StructuralError>,
) {
    let mut found: Vec<(&String, _)> = declarations
        .into_iter()
        .filter_map(|name| Some((name, reserved_declaration_reason(esm_file, name)?)))
        .collect();
    found.sort_by(|a, b| a.0.cmp(b.0));
    for (name, (reason, role)) in found {
        errors.push(StructuralError {
            path: format!("{container_path}/{name}"),
            code: StructuralErrorCode::ReservedVariableName,
            message: format!("{owner} declares a {kind} named '{name}', which is {role}"),
            details: serde_json::json!({ "name": name, "reserved_as": reason }),
        });
    }
}

/// Every `reserved_variable_name` finding of `esm_file` (esm-spec §4.9.1.1),
/// over all three declaration maps — each model's `variables` with its inline
/// subsystems, and each reaction system's `species` and `parameters` — in
/// sorted order. The same findings `validate` reports; the build refuses on
/// them too (`crate::problem`).
pub(crate) fn reserved_declaration_errors(esm_file: &EsmFile) -> Vec<StructuralError> {
    let mut errors = Vec::new();
    if let Some(models) = &esm_file.models {
        let mut names: Vec<&String> = models.keys().collect();
        names.sort();
        for model_name in names {
            let model = &models[model_name];
            check_reserved_declaration_names(
                esm_file,
                model.variables.keys(),
                &format!("/models/{model_name}/variables"),
                &format!("Model '{model_name}'"),
                "variable",
                &mut errors,
            );
            if let Some(subsystems) = &model.subsystems {
                check_reserved_subsystem_names(
                    esm_file,
                    subsystems.iter(),
                    &format!("/models/{model_name}/subsystems"),
                    &mut errors,
                );
            }
        }
    }
    if let Some(systems) = &esm_file.reaction_systems {
        let mut names: Vec<&String> = systems.keys().collect();
        names.sort();
        for rs_name in names {
            let rs = &systems[rs_name];
            let owner = format!("Reaction system '{rs_name}'");
            for (map, kind, keys) in [
                ("species", "species", rs.species.keys().collect::<Vec<_>>()),
                ("parameters", "parameter", rs.parameters.keys().collect()),
            ] {
                check_reserved_declaration_names(
                    esm_file,
                    keys,
                    &format!("/reaction_systems/{rs_name}/{map}"),
                    &owner,
                    kind,
                    &mut errors,
                );
            }
        }
    }
    errors
}

/// [`check_reserved_declaration_names`] over every INLINE subsystem of a model,
/// recursively (esm-spec §4.9.1.1).
///
/// A subsystem is a model, so its `variables` map declares symbols of the
/// assembled system exactly as the parent's does; the failure reported in issue
/// #200 was a subsystem mount. `Model::subsystems` is untyped because an entry
/// may be an unresolved `{"ref": …}`, which carries no `variables` key and
/// contributes nothing — by the time validation runs the ref resolver has
/// spliced a resolved mount into the same `{variables, equations}` shape, so
/// one walk covers both. Keys are visited in sorted order, as the sibling
/// declaration-map check is.
fn check_reserved_subsystem_names<'a, I>(
    esm_file: &EsmFile,
    subsystems: I,
    base_path: &str,
    errors: &mut Vec<StructuralError>,
) where
    I: IntoIterator<Item = (&'a String, &'a serde_json::Value)>,
{
    let mut entries: Vec<(&String, &serde_json::Value)> = subsystems.into_iter().collect();
    entries.sort_by(|a, b| a.0.cmp(b.0));
    for (name, value) in entries {
        let sub_path = format!("{base_path}/{name}");
        if let Some(vars) = value.get("variables").and_then(|v| v.as_object()) {
            check_reserved_declaration_names(
                esm_file,
                vars.keys(),
                &format!("{sub_path}/variables"),
                &format!("Model '{name}'"),
                "variable",
                errors,
            );
        }
        if let Some(nested) = value.get("subsystems").and_then(|v| v.as_object()) {
            check_reserved_subsystem_names(
                esm_file,
                nested.iter(),
                &format!("{sub_path}/subsystems"),
                errors,
            );
        }
    }
}

/// One `array_default_without_shape` finding, at the offending `default` field.
fn array_default_without_shape(
    model_path: &str,
    owner: &str,
    name: &str,
    var_type: &str,
) -> StructuralError {
    StructuralError {
        path: format!("{model_path}/variables/{name}/default"),
        code: StructuralErrorCode::ArrayDefaultWithoutShape,
        message: format!(
            "{owner} variable '{name}' has inline array data as its default but declares no \
             shape; inline array data is a shaped variable's value (esm-spec §6.3)"
        ),
        details: serde_json::json!({ "variable": name, "variable_type": var_type }),
    }
}

/// `array_default_without_shape` for every variable of `model`, and of its
/// inline subsystems, whose `default` is inline ARRAY data but which declares
/// no `shape` (esm-spec §6.3).
///
/// Inline array data is a SHAPED variable's value, so with no shape (omitted,
/// null or empty) there is nothing for it to fill. `prepare::scalar_params`
/// still keeps such a parameter out of the build's scalar scope, so a route
/// that skips validation reads it fail-closed rather than as a fabricated
/// number; this is the load-time rejection that names the declaration.
fn check_array_defaults_have_shape(
    model: &crate::Model,
    model_path: &str,
    owner: &str,
    errors: &mut Vec<StructuralError>,
) {
    let mut unshaped: Vec<(&String, &crate::ModelVariable)> = model
        .variables
        .iter()
        .filter(|(_, var)| {
            let is_array = matches!(var.default, Some(crate::types::InlineValue::Array(_)));
            let shaped = var.shape.as_ref().is_some_and(|s| !s.is_empty());
            is_array && !shaped
        })
        .collect();
    unshaped.sort_by(|a, b| a.0.cmp(b.0));
    for (name, var) in unshaped {
        let var_type = serde_json::to_value(var.var_type)
            .ok()
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_default();
        errors.push(array_default_without_shape(
            model_path, owner, name, &var_type,
        ));
    }
    if let Some(subsystems) = &model.subsystems {
        check_subsystem_array_defaults(
            subsystems.iter(),
            &format!("{model_path}/subsystems"),
            errors,
        );
    }
}

/// [`check_array_defaults_have_shape`] over every INLINE subsystem, recursively.
/// `Model::subsystems` is untyped (an entry may be an unresolved `{"ref": …}`,
/// which has no `variables`), so the walk is over raw JSON.
fn check_subsystem_array_defaults<'a, I>(
    subsystems: I,
    base_path: &str,
    errors: &mut Vec<StructuralError>,
) where
    I: IntoIterator<Item = (&'a String, &'a serde_json::Value)>,
{
    let mut entries: Vec<(&String, &serde_json::Value)> = subsystems.into_iter().collect();
    entries.sort_by(|a, b| a.0.cmp(b.0));
    for (name, value) in entries {
        let sub_path = format!("{base_path}/{name}");
        if let Some(vars) = value.get("variables").and_then(|v| v.as_object()) {
            let mut keys: Vec<&String> = vars.keys().collect();
            keys.sort();
            for key in keys {
                let var = &vars[key.as_str()];
                let is_array = var.get("default").is_some_and(|d| d.is_array());
                let shaped = var
                    .get("shape")
                    .and_then(|s| s.as_array())
                    .is_some_and(|s| !s.is_empty());
                if is_array && !shaped {
                    let var_type = var.get("type").and_then(|t| t.as_str()).unwrap_or("");
                    errors.push(array_default_without_shape(
                        &sub_path,
                        &format!("Model '{name}'"),
                        key,
                        var_type,
                    ));
                }
            }
        }
        if let Some(nested) = value.get("subsystems").and_then(|v| v.as_object()) {
            check_subsystem_array_defaults(
                nested.iter(),
                &format!("{sub_path}/subsystems"),
                errors,
            );
        }
    }
}

// ---------------------------------------------------------------------------
// esm-spec §6.3.1 "What a left-hand side may name"
// ---------------------------------------------------------------------------

/// Every `equation_defines_parameter` and `unbound_index_symbol` finding for
/// one top-level model and the inline subsystems it mounts, at each equation's
/// `lhs` pointer. Shared by `validate` and by `esm_problem`, which refuses the
/// first (a binding that dropped such an equation, or let it override the
/// parameter, would answer with a number the document does not describe).
pub(crate) fn lhs_name_errors(
    esm_file: &EsmFile,
    model_name: &str,
    model: &crate::Model,
) -> Vec<StructuralError> {
    let mut out = Vec::new();
    let mut scope: HashSet<String> = esm_file
        .metaparameters
        .as_ref()
        .and_then(|m| m.as_object())
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default();
    scope.insert(independent_variable(esm_file));
    lhs_name_errors_in(
        esm_file,
        &format!("/models/{model_name}"),
        LhsModel::Typed(model),
        &scope,
        &mut out,
    );
    out
}

/// A model as [`lhs_name_errors_in`] reads it: the typed top-level model, or
/// an inline subsystem, which [`crate::Model`] keeps as JSON. Reading the
/// typed model in place keeps the check linear in the equations' size (each
/// equation's left-hand side is the only part turned into JSON).
#[derive(Clone, Copy)]
enum LhsModel<'a> {
    Typed(&'a crate::Model),
    Json(&'a serde_json::Value),
}

impl<'a> LhsModel<'a> {
    fn declares(self, name: &str) -> bool {
        match self {
            LhsModel::Typed(m) => m.variables.contains_key(name),
            LhsModel::Json(m) => m.get("variables").and_then(|v| v.get(name)).is_some(),
        }
    }

    fn subsystem(self, name: &str) -> Option<&'a serde_json::Value> {
        match self {
            LhsModel::Typed(m) => m.subsystems.as_ref()?.get(name),
            LhsModel::Json(m) => m.get("subsystems")?.get(name),
        }
    }

    fn subsystem_names(self) -> Vec<&'a String> {
        match self {
            LhsModel::Typed(m) => m.subsystems.iter().flat_map(|s| s.keys()).collect(),
            LhsModel::Json(m) => m
                .get("subsystems")
                .and_then(|v| v.as_object())
                .map(|subs| subs.keys().collect())
                .unwrap_or_default(),
        }
    }

    /// Whether the variable at the scoped path `rest` (subsystem names, then
    /// the variable) is a parameter; `None` when there is no such variable.
    fn is_param(self, rest: &[&str]) -> Option<bool> {
        let (last, subs) = rest.split_last()?;
        let mut cur = self;
        for p in subs {
            cur = LhsModel::Json(cur.subsystem(p)?);
        }
        match cur {
            LhsModel::Typed(m) => {
                Some(m.variables.get(*last)?.var_type == crate::VariableType::Parameter)
            }
            LhsModel::Json(m) => {
                let v = m.get("variables")?.get(*last)?;
                Some(v.get("type").and_then(|t| t.as_str()) == Some("parameter"))
            }
        }
    }

    /// Each equation's left-hand side and, when its right-hand side is a
    /// `faq`, the right-hand side's `output_idx` names.
    fn for_each_equation(self, mut f: impl FnMut(usize, LhsSide<'_>, Option<Vec<String>>)) {
        match self {
            LhsModel::Typed(m) => {
                for (k, eq) in m.equations.iter().enumerate() {
                    let faq_idx = match &eq.rhs {
                        // An integer entry is written as a number, which
                        // names no subscript (as `json_output_idx` reads it).
                        crate::Expr::Operator(n) if n.op == "faq" => Some(
                            n.output_idx
                                .iter()
                                .flatten()
                                .filter(|s| !is_integer_literal(s))
                                .cloned()
                                .collect(),
                        ),
                        _ => None,
                    };
                    f(k, LhsSide::Typed(&eq.lhs), faq_idx);
                }
            }
            LhsModel::Json(m) => {
                for (k, eq) in m
                    .get("equations")
                    .and_then(|v| v.as_array())
                    .into_iter()
                    .flatten()
                    .enumerate()
                {
                    let Some(lhs) = eq.get("lhs") else { continue };
                    let faq_idx = eq
                        .get("rhs")
                        .filter(|rhs| matches!(rhs.get("op").and_then(|o| o.as_str()), Some("faq")))
                        .map(json_output_idx);
                    f(k, LhsSide::Json(lhs), faq_idx);
                }
            }
        }
    }
}

/// An equation's left-hand side as [`lhs_name_errors_in`] reads it: typed, or
/// JSON in an inline subsystem. The typed readings mirror the JSON ones.
#[derive(Clone, Copy)]
enum LhsSide<'a> {
    Typed(&'a crate::Expr),
    Json(&'a serde_json::Value),
}

impl<'a> LhsSide<'a> {
    fn is_ic(self) -> bool {
        match self {
            LhsSide::Typed(e) => is_ic_equation(e),
            LhsSide::Json(v) => v.get("op").and_then(|o| o.as_str()) == Some("ic"),
        }
    }

    fn defined_name(self) -> Option<&'a str> {
        match self {
            LhsSide::Typed(lhs) => {
                let mut e = lhs;
                loop {
                    let crate::Expr::Operator(n) = e else {
                        return match e {
                            crate::Expr::Variable(s) => Some(s),
                            _ => None,
                        };
                    };
                    e = match n.op.as_str() {
                        "faq" => n.expr.as_deref()?,
                        "index" => n.args.first()?,
                        "D" if matches!(n.wrt.as_deref(), None | Some("t")) => n.args.first()?,
                        _ => return None,
                    };
                }
            }
            LhsSide::Json(v) => lhs_defined_name(v),
        }
    }

    fn subject_name(self) -> Option<&'a str> {
        match self {
            LhsSide::Typed(lhs) => {
                let mut e = lhs;
                loop {
                    let crate::Expr::Operator(n) = e else {
                        return match e {
                            crate::Expr::Variable(s) => Some(s),
                            _ => None,
                        };
                    };
                    e = match n.op.as_str() {
                        "faq" => n.expr.as_deref()?,
                        "index" | "D" => n.args.first()?,
                        _ => return None,
                    };
                }
            }
            LhsSide::Json(v) => lhs_subject_name(v),
        }
    }

    fn free_subscripts(
        self,
        bound: &HashSet<String>,
        names: &dyn Fn(&str) -> bool,
        out: &mut Vec<String>,
    ) {
        match self {
            LhsSide::Typed(e) => collect_free_lhs_subscripts_typed(e, bound, names, out),
            LhsSide::Json(v) => collect_free_lhs_subscripts(v, bound, names, out),
        }
    }
}

/// The `equation_defines_parameter` findings of every model in `esm_file`,
/// in model-name order — what `esm_problem` refuses before it builds.
pub(crate) fn parameter_definition_errors(esm_file: &EsmFile) -> Vec<StructuralError> {
    let Some(models) = &esm_file.models else {
        return Vec::new();
    };
    let mut names: Vec<&String> = models.keys().collect();
    names.sort();
    names
        .into_iter()
        .flat_map(|n| lhs_name_errors(esm_file, n, &models[n]))
        .filter(|e| matches!(e.code, StructuralErrorCode::EquationDefinesParameter))
        .collect()
}

/// One model's equations, then its inline subsystems.
fn lhs_name_errors_in(
    esm_file: &EsmFile,
    path: &str,
    model: LhsModel<'_>,
    doc_scope: &HashSet<String>,
    out: &mut Vec<StructuralError>,
) {
    let names = |sym: &str| doc_scope.contains(sym) || model.declares(sym);
    model.for_each_equation(|k, lhs, faq_idx| {
        let lhs_path = || format!("{path}/equations/{k}/lhs");
        if lhs.is_ic() {
            return;
        }
        if let Some(name) = lhs.defined_name()
            && lhs_names_parameter(esm_file, model, name)
        {
            out.push(StructuralError {
                path: lhs_path(),
                code: StructuralErrorCode::EquationDefinesParameter,
                message: format!(
                    "Equation {k} defines '{name}', which is a parameter; an equation \
                     defines unknowns only"
                ),
                details: serde_json::json!({ "variable": name }),
            });
        }
        // The bare-index definition `index(V, k) ~ faq{k}(…)` takes its
        // subscripts from the right-hand side's `output_idx`.
        let bound: HashSet<String> = faq_idx.into_iter().flatten().collect();
        let mut free: Vec<String> = Vec::new();
        lhs.free_subscripts(&bound, &names, &mut free);
        let subject = lhs.subject_name();
        for symbol in free {
            let defining = subject.map_or(String::new(), |v| format!(" (defining '{v}')"));
            out.push(StructuralError {
                path: lhs_path(),
                code: StructuralErrorCode::UnboundIndexSymbol,
                message: format!(
                    "Equation {k}{defining} subscripts its left-hand side with \
                     '{symbol}', which no faq binds"
                ),
                details: serde_json::json!({ "symbol": symbol, "variable": subject }),
            });
        }
    });
    let mut sub_names = model.subsystem_names();
    sub_names.sort();
    for s in sub_names {
        let Some(sub) = model.subsystem(s) else {
            continue;
        };
        if sub.get("ref").is_some() {
            continue; // an unresolved mount: nothing inline to check
        }
        lhs_name_errors_in(
            esm_file,
            &format!("{path}/subsystems/{s}"),
            LhsModel::Json(sub),
            doc_scope,
            out,
        );
    }
}

/// The variable a left-hand side names, read through its `faq` and `index`
/// wrappers and a time derivative (`D(…)` with `wrt` absent or `t`: a parameter
/// may have neither a definition nor dynamics. The axis is the LITERAL `t`,
/// never `domain.independent_variable`, esm-spec §4.2); `None` for an `ic`, or an
/// expression that names no single variable.
fn lhs_defined_name(lhs: &serde_json::Value) -> Option<&str> {
    let mut e = lhs;
    loop {
        if let Some(s) = e.as_str() {
            return Some(s);
        }
        match e.get("op").and_then(|o| o.as_str())? {
            "faq" => e = e.get("expr")?,
            "index" => e = e.get("args")?.as_array()?.first()?,
            "D" if matches!(e.get("wrt").and_then(|w| w.as_str()), None | Some("t")) => {
                e = e.get("args")?.as_array()?.first()?
            }
            _ => return None,
        }
    }
}

/// Whether `name`, written on a left-hand side in `model`, names a parameter:
/// a local variable, a scoped path into `model`'s subsystems, or a path from a
/// top-level model of the document (which may be `model` itself).
fn lhs_names_parameter(esm_file: &EsmFile, model: LhsModel<'_>, name: &str) -> bool {
    let parts: Vec<&str> = name.split('.').collect();
    if let Some(found) = model.is_param(&parts) {
        return found;
    }
    if parts.len() > 1
        && let Some(models) = &esm_file.models
        && let Some(top) = models.get(parts[0])
        && let Some(found) = LhsModel::Typed(top).is_param(&parts[1..])
    {
        return found;
    }
    false
}

/// The variable a left-hand side is about, read through `faq`, `index` and
/// `D` wrappers alike (for naming it in a diagnostic).
fn lhs_subject_name(lhs: &serde_json::Value) -> Option<&str> {
    let mut e = lhs;
    loop {
        if let Some(s) = e.as_str() {
            return Some(s);
        }
        match e.get("op").and_then(|o| o.as_str())? {
            "faq" => e = e.get("expr")?,
            "index" | "D" => e = e.get("args")?.as_array()?.first()?,
            _ => return None,
        }
    }
}

/// Whether an `output_idx` entry is a canonical integer, which the typed
/// node stores as a string and writes back as a number.
fn is_integer_literal(s: &str) -> bool {
    matches!(s.parse::<i64>(), Ok(v) if v.to_string() == s)
}

fn json_output_idx(node: &serde_json::Value) -> Vec<String> {
    node.get("output_idx")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
        .filter_map(|x| x.as_str().map(str::to_string))
        .collect()
}

/// The string subscripts of `index` nodes in a left-hand side that name no
/// variable or metaparameter in scope and no enclosing `faq` binds, in order,
/// without repeats.
fn collect_free_lhs_subscripts(
    e: &serde_json::Value,
    bound: &HashSet<String>,
    names: &dyn Fn(&str) -> bool,
    out: &mut Vec<String>,
) {
    let Some(obj) = e.as_object() else { return };
    let op = obj.get("op").and_then(|o| o.as_str()).unwrap_or("");
    let args: &[serde_json::Value] = obj
        .get("args")
        .and_then(|a| a.as_array())
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    match op {
        "faq" => {
            let mut inner = bound.clone();
            inner.extend(json_output_idx(e));
            if let Some(r) = obj.get("ranges").and_then(|r| r.as_object()) {
                inner.extend(r.keys().cloned());
            }
            if let Some(x) = obj.get("expr") {
                collect_free_lhs_subscripts(x, &inner, names, out);
            }
            for a in args {
                collect_free_lhs_subscripts(a, &inner, names, out);
            }
        }
        "index" => {
            if let Some(base) = args.first() {
                collect_free_lhs_subscripts(base, bound, names, out);
            }
            for s in args.iter().skip(1) {
                match s.as_str() {
                    Some(sym) => {
                        if !bound.contains(sym) && !names(sym) && !out.iter().any(|o| o == sym) {
                            out.push(sym.to_string());
                        }
                    }
                    None => collect_free_lhs_subscripts(s, bound, names, out),
                }
            }
        }
        _ => {
            for a in args {
                collect_free_lhs_subscripts(a, bound, names, out);
            }
        }
    }
}

/// [`collect_free_lhs_subscripts`] over a typed left-hand side.
fn collect_free_lhs_subscripts_typed(
    e: &crate::Expr,
    bound: &HashSet<String>,
    names: &dyn Fn(&str) -> bool,
    out: &mut Vec<String>,
) {
    let crate::Expr::Operator(node) = e else {
        return;
    };
    match node.op.as_str() {
        "faq" => {
            let mut inner = bound.clone();
            inner.extend(
                node.output_idx
                    .iter()
                    .flatten()
                    .filter(|s| !is_integer_literal(s))
                    .cloned(),
            );
            if let Some(r) = &node.ranges {
                inner.extend(r.keys().cloned());
            }
            if let Some(x) = node.expr.as_deref() {
                collect_free_lhs_subscripts_typed(x, &inner, names, out);
            }
            for a in &node.args {
                collect_free_lhs_subscripts_typed(a, &inner, names, out);
            }
        }
        "index" => {
            if let Some(base) = node.args.first() {
                collect_free_lhs_subscripts_typed(base, bound, names, out);
            }
            for s in node.args.iter().skip(1) {
                match s {
                    crate::Expr::Variable(sym) => {
                        if !bound.contains(sym) && !names(sym) && !out.iter().any(|o| o == sym) {
                            out.push(sym.clone());
                        }
                    }
                    _ => collect_free_lhs_subscripts_typed(s, bound, names, out),
                }
            }
        }
        _ => {
            for a in &node.args {
                collect_free_lhs_subscripts_typed(a, bound, names, out);
            }
        }
    }
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

/// Static `faq`-node constraints (RFC semiring-faq-unified-ir), decidable
/// from this single document. Walk every `faq` node in the model's
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
    model_path: &str,
    model: &crate::Model,
    is_state: &dyn Fn(&str) -> bool,
    faq_equations: Option<&[bool]>,
    errors: &mut Vec<StructuralError>,
) {
    // A join key may name a DATA COLUMN, whose range symbol comes from its
    // declared 1-D shape — so the side checks below need the model's shapes.
    let var_shapes = crate::join::declared_var_shapes(model);
    // Array-shaped unknowns: the only variables a causal self-reference can
    // define (esm-spec §4.3.1.1).
    let array_shaped: HashSet<&str> = model
        .variables
        .iter()
        .filter(|(_, v)| v.shape.as_ref().is_some_and(|s| !s.is_empty()))
        .map(|(n, _)| n.as_str())
        .collect();
    // esm-spec §4.3.1.2: each member of a recurrence group is checked with its
    // peers' `index` reads counted as causal reads, and the members' frames
    // are compared once every member has one.
    let groups = recurrence_groups_of_parts(&model.variables, &model.equations);
    let mut frames: Vec<(usize, &str, RecurrenceFrame)> = Vec::new();
    for (eq_idx, equation) in model.equations.iter().enumerate() {
        // An equation the reference check saw no `faq` node in has none to check.
        if faq_equations.is_none_or(|faq| faq.get(eq_idx).copied().unwrap_or(true)) {
            // As authored: a template application, which load expanded and
            // marked, is opaque.
            faq_bare_array_operand_errors(
                &equation.lhs,
                &equation.rhs,
                &format!("{model_path}/equations/{eq_idx}/rhs"),
                &var_shapes,
                true,
                errors,
            );
            for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
                let field_path = || format!("{model_path}/equations/{eq_idx}/{field}");
                check_aggregates_in_expr(
                    expr,
                    &field_path,
                    esm_file,
                    is_state,
                    &var_shapes,
                    errors,
                );
            }
        }
        if let Some((var, _)) = recurrence_lhs_target(&equation.lhs)
            && array_shaped.contains(var)
        {
            let group = groups.iter().find(|g| g.contains(var));
            if let Some(frame) = check_recurrence_equation(
                equation,
                &format!("{model_path}/equations/{eq_idx}/rhs"),
                esm_file,
                &array_shaped,
                group,
                errors,
            ) && group.is_some()
            {
                frames.push((eq_idx, var, frame));
            }
        }
    }
    check_recurrence_group_frames(&groups, &frames, model_path, errors);
    // Each inline subsystem is a model whose equations take the same checks,
    // against its own declarations. An unresolved `{ref}` mount carries none.
    let mut subsystems: Vec<(&String, &serde_json::Value)> =
        model.subsystems.iter().flatten().collect();
    subsystems.sort_by(|a, b| a.0.cmp(b.0));
    for (name, value) in subsystems {
        if value.get("ref").is_some() {
            continue;
        }
        let Ok(sub) = serde_json::from_value::<crate::Model>(value.clone()) else {
            continue;
        };
        let class = crate::classification::Classification::of(&sub);
        let states: HashSet<&str> = class
            .ode_states
            .iter()
            .chain(&class.algebraic_unknowns)
            .chain(&class.brownian_parameters)
            .map(String::as_str)
            .collect();
        validate_aggregate_constraints(
            esm_file,
            &format!("{model_path}/subsystems/{name}"),
            &sub,
            &|n: &str| states.contains(n),
            None,
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

/// Guidance appended to the not-affine refusal of a causal self-read. The case
/// it names is the one authors reach for: a lag read from DATA
/// (`k - index(lag, k)`), where `lag[k]` is a value rather than a symbol with a
/// range. Shared by the validator and the compile path so the two refusals say
/// the same thing.
pub(crate) fn data_lag_guidance(var: &str, sym: &str) -> String {
    format!(
        "If the offset is read from data (`{sym} - index(lag, {sym})`), it has no direct \
         spelling; contract it instead: either order the axis so the predecessor is the \
         preceding position and the lag is the constant 1, or range a contracted index `a` \
         over the lag's bounds and select the matching term with \
         `ifelse(index(lag, {sym}) == a, <term reading index({var}, {sym} - a)>, 0)`."
    )
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
    /// The variable read: the equation's own variable, or (esm-spec §4.3.1.2)
    /// a peer in its recurrence group.
    target: &'a str,
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
    vars: &[&str],
    esm_file: &EsmFile,
    env: &mut Vec<(String, (i64, i64))>,
    blocked: bool,
    out: &mut Vec<StructuralSelfRead<'a>>,
    bare: &mut Option<&'a str>,
) {
    let crate::Expr::Operator(node) = e else {
        if let crate::Expr::Variable(v) = e
            && vars.contains(&v.as_str())
            && bare.is_none()
        {
            *bare = Some(v.as_str());
        }
        return;
    };
    let pushed = if node.op == "faq" {
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
    let self_target = match node.args.first() {
        Some(crate::Expr::Variable(v)) if node.op == "index" && vars.contains(&v.as_str()) => {
            Some(v.as_str())
        }
        _ => None,
    };
    let is_self_index = self_target.is_some();
    if let Some(target) = self_target {
        let mut snapshot: HashMap<String, (i64, i64)> = HashMap::new();
        for (k, v) in env.iter() {
            snapshot.insert(k.clone(), *v);
        }
        out.push(StructuralSelfRead {
            target,
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
        collect_structural_self_reads(a, vars, esm_file, env, blocked_children, out, bare);
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
        collect_structural_self_reads(side, vars, esm_file, env, blocked_children, out, bare);
    }
    if let Some(vs) = node.values.as_ref() {
        for v in vs {
            collect_structural_self_reads(v, vars, esm_file, env, true, out, bare);
        }
    }
    env.truncate(env.len() - pushed);
}

/// The variable an equation DEFINES, if its LHS names one: a bare variable, or
/// the §4.3 indexed-`faq` LHS form `faq{expr: index(V, k…)}`. A
/// derivative LHS (`D(u)`) defines no array algebraically — a stencil read of
/// `u` at `i−1` there is a gather on the solver's state, not a self-reference —
/// so it deliberately yields `None`.
fn recurrence_lhs_target(lhs: &crate::Expr) -> Option<(&str, Option<&Vec<String>>)> {
    match lhs {
        crate::Expr::Variable(v) => Some((v.as_str(), None)),
        crate::Expr::Operator(node) if node.op == "faq" => {
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
    group: Option<&std::collections::BTreeSet<String>>,
    errors: &mut Vec<StructuralError>,
) -> Option<RecurrenceFrame> {
    let (var, lhs_idx) = recurrence_lhs_target(&equation.lhs)?;
    if !array_shaped.contains(var) {
        return None;
    }
    // The names whose `index` reads are causal reads here: the variable
    // itself, plus — for a member of a §4.3.1.2 recurrence group — every peer.
    let mut vars: Vec<&str> = vec![var];
    if let Some(g) = group {
        vars.extend(g.iter().map(String::as_str).filter(|n| *n != var));
    }
    let mut env: Vec<(String, (i64, i64))> = Vec::new();
    let mut reads: Vec<StructuralSelfRead> = Vec::new();
    let mut bare: Option<&str> = None;
    collect_structural_self_reads(
        &equation.rhs,
        &vars,
        esm_file,
        &mut env,
        false,
        &mut reads,
        &mut bare,
    );
    if reads.is_empty() {
        return None;
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
    if let Some(name) = bare {
        let whose = if name == var {
            "its own defining equation".to_string()
        } else {
            format!("the definition of '{var}', a member of its recurrence group")
        };
        push(
            errors,
            StructuralErrorCode::RecurrenceNotWellfounded,
            format!(
                "'{name}' is read bare inside {whose} as well as through `index`. A bare read \
                 names the whole array, which does not exist while the recurrence sweeps it \
                 (esm-spec §4.3.1.1, §4.3.1.2)."
            ),
            None,
        );
        return None;
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
                 as one `faq` with the base case as an `ifelse` guard in the body."
            ),
            None,
        );
        return None;
    }
    // The cell frame: the indexed-`faq` LHS's own indices, else the RHS
    // aggregate's.
    let rhs_idx = match &equation.rhs {
        crate::Expr::Operator(node) if node.op == "faq" => node.output_idx.as_ref(),
        _ => None,
    };
    let Some(idx_names) = lhs_idx.or(rhs_idx) else {
        push(
            errors,
            StructuralErrorCode::RecurrenceUnsupportedForm,
            format!(
                "the definition of '{var}' reads '{var}' at another position, but the equation \
                 declares no cell frame to sweep: its RHS is not a `faq` over the \
                 variable's axes and its LHS is not the indexed-`faq` form \
                 `aggregate{{expr: index({var}, k…)}}` (esm-spec §4.3.1.1)."
            ),
            None,
        );
        return None;
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
        return None;
    }
    let frame_env: HashMap<String, (i64, i64)> = match &equation.rhs {
        crate::Expr::Operator(node) if node.op == "faq" => node
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
    let mut same_cell: Vec<String> = Vec::new();
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
            return None;
        }
        let mut env = frame_env.clone();
        for (k, v) in &read.env {
            env.insert(k.clone(), *v);
        }
        let mut lagged: Option<usize> = None;
        // Whether every value of the lag on the recurrence axis was shown
        // `>= 1` statically. A self-read need not be (esm-spec §4.3.1.1: the
        // runtime's fail-closed read rules out the rest); a PEER read must be
        // (§4.3.1.2), because an unpublished-cell fault is not order-free
        // between two variables.
        let mut proven = true;
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
                         the recurrence axis and its direction decidable (esm-spec §4.3.1.1). \
                         {}",
                        data_lag_guidance(var, sym)
                    ),
                    None,
                );
                return None;
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
                return None;
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
                    return None;
                }
                lagged = Some(d);
                proven = false;
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
                return None;
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
                return None;
            }
            lagged = Some(d);
            proven &= lag_lo >= 1;
        }
        let Some(d) = lagged else {
            // A read of a PEER at the cell being written is an ordering WITHIN
            // the cell (esm-spec §4.3.1.2 rule 1): admitted here and recorded,
            // and the group check rejects it only if such reads form a cycle.
            if read.target != var {
                same_cell.push(read.target.to_string());
                continue;
            }
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
            return None;
        };
        if read.target != var && !proven {
            push(
                errors,
                StructuralErrorCode::RecurrenceNotWellfounded,
                format!(
                    "the read of '{}' in the definition of '{var}' — a peer in its recurrence \
                     group — is not provably strictly earlier on axis '{}'. A read of a PEER \
                     must be strictly earlier for every value of its lag (esm-spec §4.3.1.2): \
                     unlike a self-read, whose same-cell values simply have not been published, \
                     a same-position read of another variable would make the result depend on \
                     which member the sweep evaluates first.",
                    read.target, idx_names[d]
                ),
                Some(&idx_names[d]),
            );
            return None;
        }
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
                return None;
            }
        }
    }
    // Each axis's range as the validator can resolve it — bounds when an
    // interval or an index set proves them, the authored spec otherwise — so
    // `{from: steps}` and `[1, 4]` over a 4-element `steps` are one frame. The
    // ranges are the frame-declaring `faq`'s: the indexed-`faq` LHS's own when
    // the LHS is that form, else the RHS aggregate's.
    let frame_node = if lhs_idx.is_some() {
        &equation.lhs
    } else {
        &equation.rhs
    };
    let ranges = match frame_node {
        crate::Expr::Operator(node) if node.op == "faq" => node.ranges.as_ref().map(|m| {
            idx_names
                .iter()
                .map(|n| {
                    m.get(n)
                        .map(|spec| match validator_symbol_bounds(spec, esm_file) {
                            Some((lo, hi)) => format!("{lo}..{hi}"),
                            None => serde_json::to_string(spec).unwrap_or_default(),
                        })
                })
                .collect::<Vec<_>>()
        }),
        _ => None,
    };
    Some(RecurrenceFrame {
        idx_names: idx_names.clone(),
        ranges,
        axis,
        same_cell,
    })
}

/// Every member of a recurrence group must sweep the same frame along the same
/// axis (esm-spec §4.3.1.2). Compared against the group's first member, in
/// equation order, that has a recurrence axis, and reported at the first member
/// that disagrees. A member
/// whose own check already failed has no frame and is skipped: one diagnosis
/// per defect.
fn check_recurrence_group_frames(
    groups: &[std::collections::BTreeSet<String>],
    frames: &[(usize, &str, RecurrenceFrame)],
    model_path: &str,
    errors: &mut Vec<StructuralError>,
) {
    for g in groups {
        let in_group: Vec<&(usize, &str, RecurrenceFrame)> =
            frames.iter().filter(|(_, v, _)| g.contains(*v)).collect();
        // The frame of reference: the first member, in equation order, that
        // folds along an axis.
        let Some(reference) = in_group.iter().find(|(_, _, f)| f.axis.is_some()) else {
            continue;
        };
        let (first_var, first) = (reference.1, &reference.2);
        if let Some((eq_idx, var, frame)) = in_group
            .iter()
            .map(|x| (x.0, x.1, &x.2))
            .find(|(_, _, f)| !f.same_frame(first))
        {
            let what = if frame.idx_names != first.idx_names {
                format!(
                    "its output indices {:?} differ from {:?}",
                    frame.idx_names, first.idx_names
                )
            } else if frame.ranges != first.ranges {
                "its ranges differ".to_string()
            } else {
                format!(
                    "it folds along '{}' where '{first_var}' folds along '{}'",
                    frame.idx_names[frame.axis.unwrap_or(0)],
                    first.idx_names[first.axis.unwrap_or(0)]
                )
            };
            errors.push(StructuralError {
                path: format!("{model_path}/equations/{eq_idx}/rhs"),
                code: StructuralErrorCode::RecurrenceGroupAxisMismatch,
                message: format!(
                    "'{var}' and '{first_var}' read each other as a recurrence group, but \
                     '{var}' does not sweep the same frame: {what}. Every member of a group \
                     shares one cell frame — the same `output_idx`, the same ranges — and one \
                     recurrence axis (esm-spec §4.3.1.2)."
                ),
                details: serde_json::json!({
                    "variable": var,
                    "group": g,
                }),
            });
            continue;
        }
        // Rule 1: the same-cell reads between members must admit an order.
        let edges: std::collections::BTreeMap<String, std::collections::BTreeSet<String>> =
            in_group
                .iter()
                .map(|(_, v, f)| (v.to_string(), f.same_cell.iter().cloned().collect()))
                .collect();
        if let Some(cycle) = crate::classification::first_observed_cycle(&edges) {
            let (eq_idx, var) = in_group
                .iter()
                .find(|(_, v, _)| cycle.iter().any(|c| c == v))
                .map(|(i, v, _)| (*i, *v))
                .expect("a cycle is among the group's members");
            errors.push(StructuralError {
                path: format!("{model_path}/equations/{eq_idx}/rhs"),
                code: StructuralErrorCode::RecurrenceNotWellfounded,
                message: format!(
                    "the members of a recurrence group read one another at the cell being \
                     written in a cycle ({}), so no order within the cell satisfies them. Reads \
                     between members at the same position must be acyclic (esm-spec §4.3.1.2 \
                     rule 1); break the cycle with a read at an earlier position.",
                    cycle.join(" -> ")
                ),
                details: serde_json::json!({ "variable": var, "cycle": cycle }),
            });
        }
    }
}

/// What a recurrence definition sweeps over: its output indices, their
/// authored ranges (when the RHS is the `faq` that declares them), and the
/// recurrence axis. Every member of a §4.3.1.2 recurrence group must agree on
/// all three (`recurrence_group_axis_mismatch`).
#[derive(Debug)]
struct RecurrenceFrame {
    idx_names: Vec<String>,
    ranges: Option<Vec<Option<String>>>,
    /// `None` for a member whose every causal read is a same-cell peer read.
    axis: Option<usize>,
    /// The peers this member reads at the cell being written (esm-spec
    /// §4.3.1.2 rule 1): the within-cell order the group must be able to take.
    same_cell: Vec<String>,
}

impl RecurrenceFrame {
    /// Whether two members sweep one frame: the same indices, the same
    /// ranges, and — where both fold along an axis — the same axis.
    fn same_frame(&self, other: &RecurrenceFrame) -> bool {
        self.idx_names == other.idx_names
            && self.ranges == other.ranges
            && match (self.axis, other.axis) {
                (Some(a), Some(b)) => a == b,
                _ => true,
            }
    }
}

// ---------------------------------------------------------------------------
// Observed dependency cycles — esm-spec §4.9.6
// ---------------------------------------------------------------------------

/// The model's recurrence CANDIDATES: array-shaped unknowns whose own defining
/// RHS reads them back through at least one `index` (esm-spec §4.3.1.1).
///
/// This is the predicate CONFORMANCE_SPEC §5.19.5 requires every check that
/// would otherwise fire on the self-edge to be exempted by — *candidacy*, not
/// the well-foundedness verdict. Gating on the verdict would let the cycle
/// check fire on an ill-founded self-read and collapse the document to one
/// cycle error, giving back exactly the named `recurrence_*` diagnosis the
/// construct exists to produce. Gating on "is this a self-edge at all" is the
/// mirror-image mistake and is just as wrong: it would swallow a scalar
/// `x ~ x + 1` and a bare `s ~ s + 1`, which have no axis to fold along and can
/// never be recurrences, and drop the cycle error they must keep getting.
fn recurrence_candidate_vars(model: &crate::Model) -> HashSet<String> {
    recurrence_candidate_vars_of_parts(&model.variables, &model.equations)
}

/// [`recurrence_candidate_vars`] over a model node's raw parts, for the
/// document-wide `circular_dependency` graph, which holds a subsystem as its
/// `variables` and `equations` rather than as a whole [`crate::Model`].
fn recurrence_candidate_vars_of_parts(
    variables: &indexmap::IndexMap<String, crate::ModelVariable>,
    equations: &[crate::Equation],
) -> HashSet<String> {
    let array_shaped: HashSet<&str> = variables
        .iter()
        .filter(|(_, v)| v.shape.as_ref().is_some_and(|s| !s.is_empty()))
        .map(|(n, _)| n.as_str())
        .collect();
    let mut out = HashSet::new();
    for equation in equations {
        let Some((var, _)) = recurrence_lhs_target(&equation.lhs) else {
            continue;
        };
        if array_shaped.contains(var) && has_index_self_read(&equation.rhs, var) {
            out.insert(var.to_string());
        }
    }
    out
}

/// Does `expr` gather `var` through at least one `index` node — the second half
/// of the §4.3.1.1 candidacy predicate?
///
/// Deliberately its own walk rather than a call into
/// [`collect_structural_self_reads`], because THE TWO WALKS MUST SEE THE SAME
/// TREE. The edge set of the cycle graph comes from [`collect_free_symbols`],
/// which descends the canonical child set (`ExpressionNode::for_each_child` —
/// esm-spec §4.9.5 requires every Expression-valued field, `bindings` and
/// `axes` included). `collect_structural_self_reads` descends the smaller set
/// the recurrence LOWERING has to reason about, and says so: it skips
/// `bindings` on the stated grounds that five bindings mirror that field set
/// and §5.19.5 is exact agreement. Where the two disagree, a self-read is
/// visible as an EDGE and invisible as a CANDIDATE — and a legal recurrence is
/// reported as a cycle of length one.
///
/// That gap is reachable, not theoretical. `apply_expression_template` carries
/// its call-site arguments in `bindings`, and from `esm: 0.9.0` a reference is
/// preserved uninlined (§9.6.4 rule 2), so a self-read bound to a template
/// parameter — `twice(v = s[k-1])`, which is
/// `tests/fixtures/recurrence/09_recurrence_through_expression_template.esm` —
/// reaches the validator still wrapped. Widening the WALK rather than the RULE
/// is what keeps this faithful: the exemption is still "an array-shaped unknown
/// with at least one `index` self-read in its own defining RHS", still gated on
/// CANDIDACY and never on the well-foundedness verdict (CONFORMANCE_SPEC
/// §5.19.5), and still narrower than "reads its own name" — a bare
/// `s ~ s + 1` has no `index` read anywhere and stays a cycle of length one.
/// Narrowing the EDGE walk instead would be wrong: a template binding naming a
/// DIFFERENT observed is a real dependency once the application expands.
/// Python resolves this the same way, for the same reason.
fn has_index_self_read(expr: &crate::Expr, var: &str) -> bool {
    let crate::Expr::Operator(node) = expr else {
        return false;
    };
    if node.op == "index" && matches!(node.args.first(), Some(crate::Expr::Variable(v)) if v == var)
    {
        return true;
    }
    node.any_child(&mut |child| has_index_self_read(child, var))
}

/// The observeds each observed's defining RHS names, as a sorted adjacency map.
///
/// Sorted (`BTreeMap`/`BTreeSet`) rather than hashed because the cycle the
/// diagnostic NAMES is chosen by the traversal order, and a `HashMap` would
/// hand a different member of the same cycle to two runs of the same binary.
/// Binder symbols are subtracted first, so a `faq` range key that
/// happens to share a name with an observed does not manufacture an edge.
fn observed_dependency_graph(
    class: &crate::classification::Classification,
    candidates: &HashSet<String>,
    groups: &[std::collections::BTreeSet<String>],
) -> std::collections::BTreeMap<String, std::collections::BTreeSet<String>> {
    let observed: HashSet<&str> = class.observed_unknowns.iter().map(String::as_str).collect();
    class
        .observed_definitions
        .iter()
        .map(|(name, rhs)| {
            let mut free = HashSet::new();
            collect_free_symbols(rhs, &mut free);
            let mut bound = HashSet::new();
            collect_bound_symbols(rhs, &mut bound);
            let mut deps: std::collections::BTreeSet<String> = free
                .into_iter()
                .filter(|s| !bound.contains(s) && observed.contains(s.as_str()))
                .collect();
            // esm-spec §4.3.1.1: a well-founded causal self-read is an ORDERING
            // within one variable, not a dependency between two, so `V → V` is
            // dropped from this graph — for a CANDIDATE, and only for one.
            if candidates.contains(name) {
                deps.remove(name);
            }
            // esm-spec §4.3.1.2: the edges INSIDE a recurrence group candidate
            // are orderings along the group's shared axis, exactly as a
            // candidate's self-edge is — dropped on CANDIDACY, with the
            // well-foundedness verdict left to `check_recurrence_equation`.
            if let Some(g) = groups.iter().find(|g| g.contains(name)) {
                deps.retain(|d| !g.contains(d));
            }
            (name.clone(), deps)
        })
        .collect()
}

/// Does `expr` gather `var` through an `index` with at least one argument that
/// is not a bare name — a read that could be offset along an axis?
fn has_offset_index_read(expr: &crate::Expr, var: &str) -> bool {
    let crate::Expr::Operator(node) = expr else {
        return false;
    };
    if node.op == "index"
        && matches!(node.args.first(), Some(crate::Expr::Variable(v)) if v == var)
        && node.args[1..]
            .iter()
            .any(|a| !matches!(a, crate::Expr::Variable(_)))
    {
        return true;
    }
    node.any_child(&mut |child| has_offset_index_read(child, var))
}

/// The recurrence GROUP candidates of one model node (esm-spec §4.3.1.2): each
/// strongly connected component of two or more observeds, in the dependency
/// graph with every recurrence candidate's self-edge already dropped, whose
/// members are all array-shaped and whose every internal edge is carried by at
/// least one `index` read.
///
/// Like a single recurrence's candidacy, this is the predicate the cycle
/// exemption is gated on, never the well-foundedness verdict (CONFORMANCE_SPEC
/// §5.19.5): a group with an ill-founded read is still a candidate, so it
/// reaches the named `recurrence_*` diagnosis instead of collapsing to
/// `observed_cycle`. A component with a scalar member, or an internal edge
/// that is only a bare read, is no candidate and stays a cycle.
pub(crate) fn recurrence_groups_of_parts(
    variables: &indexmap::IndexMap<String, crate::ModelVariable>,
    equations: &[crate::Equation],
) -> Vec<std::collections::BTreeSet<String>> {
    let class = crate::classification::Classification::from_parts(variables, equations);
    if class.observed_definitions.len() < 2 {
        return Vec::new();
    }
    let candidates = recurrence_candidate_vars_of_parts(variables, equations);
    let deps = observed_dependency_graph(&class, &candidates, &[]);
    let array_shaped = |n: &str| {
        variables
            .get(n)
            .is_some_and(|v| v.shape.as_ref().is_some_and(|s| !s.is_empty()))
    };
    crate::classification::observed_sccs(&deps)
        .into_iter()
        .filter(|scc| {
            // At least one read inside the component must be OFFSET — not a
            // plain gather whose every index is a bare name. A cycle closed by
            // same-cell gathers alone has no axis to fold along, exactly as a
            // bare `s ~ s + 1` has none, and stays an `observed_cycle`.
            scc.iter().any(|u| {
                class
                    .observed_definitions
                    .get(u)
                    .is_some_and(|rhs| scc.iter().any(|v| has_offset_index_read(rhs, v)))
            }) && scc.iter().all(|m| array_shaped(m))
                && scc.iter().all(|u| {
                    let Some(rhs) = class.observed_definitions.get(u) else {
                        return false;
                    };
                    deps.get(u).is_none_or(|succ| {
                        succ.iter()
                            .filter(|v| *v != u && scc.contains(*v))
                            .all(|v| has_index_self_read(rhs, v))
                    })
                })
        })
        .collect()
}

/// Reject a dependency cycle among a model's observed unknowns
/// (esm-spec §4.9.6; issue #181).
///
/// An observed is *defined* by its equation's RHS, so the definitions induce a
/// dependency graph over the observed names, and a cycle in it means no
/// evaluation order satisfies every definition. That is decidable from the
/// equations alone — no shapes, no values, no solver — which is why it is a
/// hard error here rather than a surprise at build time. Before this check,
/// `esm validate` accepted a cyclic document and the build reported
/// `E_TREEWALK_UNBOUND_NAME` against whichever name its walk reached first
/// *after* the cycle, which is generally an innocent one.
///
/// One cycle is reported per model (the first the sorted DFS closes), like
/// [`check_circular_dependencies_in_models`]: a second cycle is usually the
/// same defect seen from another entry point, and the author fixes them one at
/// a time anyway.
fn check_observed_dependency_cycle(
    model_name: &str,
    model: &crate::Model,
    class: &crate::classification::Classification,
    errors: &mut Vec<StructuralError>,
) {
    if class.observed_definitions.is_empty() {
        return;
    }
    let candidates = recurrence_candidate_vars(model);
    let groups = recurrence_groups_of_parts(&model.variables, &model.equations);
    let deps = observed_dependency_graph(class, &candidates, &groups);

    if let Some(cycle) = crate::classification::first_observed_cycle(&deps) {
        errors.push(StructuralError {
            path: format!("/models/{model_name}"),
            code: StructuralErrorCode::ObservedCycle,
            message: format!(
                "Observed dependency cycle: {}. Each of these observed variables is defined \
                 in terms of the next, so no evaluation order satisfies every definition \
                 (esm-spec §4.9.6). Break the cycle by splitting one observed into a \
                 pre-value and a post-value.",
                cycle.join(" -> ")
            ),
            details: serde_json::json!({
                "cycle": cycle,
                "dependency_type": "observed_definitions",
            }),
        });
    }
}

/// Reject a BARE array-level expression whose operand carries an index set the
/// result does not (esm-spec §4.3.4; issue #100).
///
/// A **bare** array-level expression is one written over whole arrays with no
/// explicit index symbols — `D(dp) ~ w2 * z1`, `p3 ~ w2 * z1` — as opposed to
/// the `faq` spelling, where the author names the axes and there is
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
/// its own contract: a `faq` and a `makearray` name their axes, an
/// `index` gathers, and the shape ops restructure.
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

/// `faq_bare_array_operand` (esm-spec §4.3.1 "Shaped variables inside a
/// `faq`", issue #441): every `faq` node in `expr` whose `expr` or `filter`
/// reads a variable declared with a non-empty `shape` by BARE name in an
/// elementwise position, reported at `path`.
///
/// A `faq` names its axes by its range symbols, and an elementwise operator
/// inside its body is evaluated once per index tuple, so a whole array there
/// has no defined meaning: nothing says WHICH of the node's symbols its axes
/// are. Every evaluator nonetheless gave it one, and they disagreed. Rust's
/// per-cell reference aligned an array-valued `filter` to the output box by
/// position and treated a rank mismatch as "keep the term", so with two
/// output indices the filter was silently ignored; Python's whole-box tiers
/// let numpy broadcasting align the array's axis with the LAST box axis, which
/// is a different symbol whenever the extents coincide; the tape refused it.
/// The document has to say which index it means, `index(a_val, i)`, and a
/// document that says so cannot silently mean the wrong one.
///
/// The descent is the one [`collect_bare_array_operands`] uses (elementwise
/// operators only): a shaped variable consumed whole by its own operator
/// contract (an `index` base, a nested `faq`, a shape op) is not a per-tuple
/// read. A name bound as a loop
/// symbol by this node or an enclosing one shadows the declaration and is not
/// a variable read. Nested `faq` nodes are checked in their own right.
///
/// With `opaque_applications`, a template application is opaque: an array
/// bound to one of its arguments is not a bare read here. That is how
/// `validate` decides the rule, on the equations as authored: a reference, or
/// an expansion the load marked as one
/// ([`crate::types::ExpressionNode::template_origin`]), is not entered. The
/// build passes `false` and checks what the applications expanded into, after
/// the elementwise lift (esm-spec §9.6.11).
///
/// `expr` is an equation's right-hand side and `lhs` its left-hand side. A
/// variable an observed or recurrence definition's left-hand side names is
/// skipped: a bare read of the variable such an equation defines is a causal
/// self-reference read whole, which `recurrence_not_wellfounded` (esm-spec
/// §4.3.1.1) or `observed_cycle` already reports, and one defect is reported
/// once. A derivative left-hand side — `D(y)`, or the array-equation
/// `faq[i](D(y[i]))` — skips nothing: no other check reports
/// `D(y) ~ faq(… y …)`.
pub(crate) fn faq_bare_array_operand_errors(
    lhs: &crate::Expr,
    expr: &crate::Expr,
    path: &str,
    var_shapes: &HashMap<String, Vec<String>>,
    opaque_applications: bool,
    errors: &mut Vec<StructuralError>,
) {
    let mut defined = HashSet::new();
    fn holds_derivative(e: &crate::Expr) -> bool {
        let crate::Expr::Operator(n) = e else {
            return false;
        };
        let mut found = n.op == "D";
        n.for_each_child(&mut |c| found = found || holds_derivative(c));
        found
    }
    if !holds_derivative(lhs) {
        collect_variable_refs(lhs, &mut defined);
    }
    let declared_axes: HashMap<&str, &Vec<String>> = var_shapes
        .iter()
        .filter(|(n, s)| !s.is_empty() && !defined.contains(n.as_str()))
        .map(|(n, s)| (n.as_str(), s))
        .collect();
    if declared_axes.is_empty() {
        return;
    }
    let mut bound: Vec<String> = Vec::new();
    let mut visited = HashMap::new();
    let walk = BareWalk {
        path,
        declared_axes: &declared_axes,
        opaque_applications,
    };
    walk.faq_operands(expr, &mut bound, &mut visited, errors);
}

/// One [`faq_bare_array_operand_errors`] walk's fixed inputs.
struct BareWalk<'a> {
    path: &'a str,
    declared_axes: &'a HashMap<&'a str, &'a Vec<String>>,
    opaque_applications: bool,
}

impl BareWalk<'_> {
    /// Whether the walk does not enter `node`: a template application, which
    /// is opaque to it (see [`faq_bare_array_operand_errors`]).
    fn is_opaque(&self, node: &crate::types::ExpressionNode) -> bool {
        node.op == "apply_expression_template"
            || (self.opaque_applications && node.template_origin.is_some())
    }
}

/// The walk is DAG-safe: a node shared by many parents (a lifted or folded
/// chain on the build's expanded model) is visited once per distinct
/// loop-symbol scope, not once per path.
impl BareWalk<'_> {
    fn faq_operands(
        &self,
        expr: &crate::Expr,
        bound: &mut Vec<String>,
        visited: &mut HashMap<*const crate::types::ExpressionNode, Vec<Vec<String>>>,
        errors: &mut Vec<StructuralError>,
    ) {
        let (path, declared_axes) = (self.path, self.declared_axes);
        let crate::Expr::Operator(node) = expr else {
            return;
        };
        if self.is_opaque(node) {
            return;
        }
        let scopes = visited.entry(std::sync::Arc::as_ptr(node)).or_default();
        if scopes.iter().any(|s| s == bound) {
            return;
        }
        scopes.push(bound.clone());
        let is_faq = crate::faq::is_faq_op(&node.op);
        let pushed = if is_faq {
            let syms = bound_index_symbols(node);
            let n = syms.len();
            bound.extend(syms);
            n
        } else {
            0
        };
        if is_faq {
            for (field, part) in [
                ("expr", node.expr.as_deref()),
                ("filter", node.filter.as_deref()),
            ] {
                let Some(part) = part else { continue };
                let mut operands: Vec<&str> = Vec::new();
                self.collect_operands(part, &mut HashSet::new(), &mut operands);
                let mut seen: HashSet<&str> = HashSet::new();
                for operand in operands {
                    if bound.iter().any(|b| b == operand) || !seen.insert(operand) {
                        continue;
                    }
                    let axes = declared_axes[operand];
                    let syms: Vec<String> = node
                        .ranges
                        .as_ref()
                        .map(|r| {
                            let mut k: Vec<&String> = r.keys().collect();
                            k.sort();
                            k.into_iter().cloned().collect()
                        })
                        .unwrap_or_default();
                    errors.push(StructuralError {
                        path: path.to_string(),
                        code: StructuralErrorCode::FaqBareArrayOperand,
                        message: format!(
                            "faq `{field}` reads '{operand}', declared over [{}], by bare name. A \
                         faq names its axes by its range symbols ({}), and its `{field}` is \
                         evaluated once per index tuple, so a whole array there does not say \
                         which symbol each of its axes is. Read it through `index`, e.g. \
                         index({operand}, <symbol>…) (esm-spec §4.3.1)",
                            axes.join(", "),
                            if syms.is_empty() {
                                "none".to_string()
                            } else {
                                syms.join(", ")
                            },
                        ),
                        details: serde_json::json!({
                            "field": field,
                            "variable": operand,
                            "shape": axes,
                        }),
                    });
                }
            }
        }
        node.for_each_child(&mut |child| {
            self.faq_operands(child, bound, visited, errors);
        });
        bound.truncate(bound.len() - pushed);
    }

    /// [`collect_bare_array_operands`], visiting each shared node once and not
    /// entering an opaque application.
    fn collect_operands<'e>(
        &self,
        expr: &'e crate::Expr,
        seen: &mut HashSet<*const crate::types::ExpressionNode>,
        out: &mut Vec<&'e str>,
    ) {
        match expr {
            crate::Expr::Variable(name) if self.declared_axes.contains_key(name.as_str()) => {
                out.push(name.as_str());
            }
            crate::Expr::Operator(node) => {
                if !crate::op_registry::is_elementwise_node(node)
                    || self.is_opaque(node)
                    || !seen.insert(std::sync::Arc::as_ptr(node))
                {
                    return;
                }
                node.for_each_child(&mut |child| self.collect_operands(child, seen, out));
            }
            _ => {}
        }
    }
}

/// Every variable's index-set axes as the build sees them: the declared
/// `shape`, or, for a variable declared without one, the shape its defining
/// (bare left-hand side) equation infers. The inference is Julia's
/// `promote_downstream_shapes` (`shape_promotion.jl`) and Python's
/// `_promoted_axes`: a `faq` / `makearray` over named ranges has its output
/// axes' index sets, one over inline `[1, n]` ranges has anonymous axes, an
/// `index` gather and a geometry kernel are scalar, and every other op
/// broadcasts its operands' axes by name, the superset winning. The
/// definitions are inferred in dependency order
/// ([`dependency_first_order`]), each after every definition it reads, so a
/// definition is never inferred from operands not yet inferred, whatever the
/// order of the equations; one on a cycle of definitions is then retried
/// until nothing changes. A variable declared `shape: []` is a scalar and
/// never inferred.
pub(crate) fn promoted_var_shapes(model: &crate::Model) -> HashMap<String, Vec<String>> {
    let mut shapes: HashMap<String, Vec<String>> = HashMap::new();
    let mut declared_scalar: HashSet<&str> = HashSet::new();
    for (name, var) in &model.variables {
        match &var.shape {
            Some(s) if s.is_empty() => {
                declared_scalar.insert(name.as_str());
            }
            Some(s) => {
                shapes.insert(name.clone(), s.clone());
            }
            None => {}
        }
    }
    let open: Vec<(&str, &crate::Expr)> = model
        .equations
        .iter()
        .filter_map(|eq| match &eq.lhs {
            crate::Expr::Variable(n) => Some((n.as_str(), &eq.rhs)),
            _ => None,
        })
        .filter(|(n, _)| !shapes.contains_key(*n) && !declared_scalar.contains(n))
        .collect();
    for (name, rhs) in &open {
        if let Some(axes) = inline_producer_axes(rhs, name) {
            shapes.insert((*name).to_string(), axes);
        }
    }
    let def_of: HashMap<&str, usize> = open
        .iter()
        .enumerate()
        .rev()
        .map(|(i, (n, _))| (*n, i))
        .collect();
    let deps: Vec<Vec<usize>> = open
        .iter()
        .map(|(_, rhs)| {
            let mut out = Vec::new();
            for_each_variable(rhs, &mut |n| out.extend(def_of.get(n).copied()));
            out
        })
        .collect();
    for i in dependency_first_order(&deps) {
        let (name, rhs) = open[i];
        if shapes.contains_key(name) {
            continue;
        }
        let inferred = infer_expr_axes(rhs, &shapes, &mut HashMap::new());
        if !inferred.is_empty() {
            shapes.insert(name.to_string(), inferred);
        }
    }
    // Only a definition on a cycle can still be open with an operand shaped.
    loop {
        let mut changed = false;
        for (name, rhs) in &open {
            if shapes.contains_key(*name) {
                continue;
            }
            let inferred = infer_expr_axes(rhs, &shapes, &mut HashMap::new());
            if !inferred.is_empty() {
                shapes.insert((*name).to_string(), inferred);
                changed = true;
            }
        }
        if !changed {
            return shapes;
        }
    }
}

/// An order of `deps.len()` definitions in which each comes after every
/// definition it reads: `deps[i]` lists, by position, the definitions
/// definition `i` reads. Otherwise in the order given, each definition's
/// unplaced dependencies pulled ahead of it. On a cycle, the definition the
/// walk enters first comes after the others, which read it before it is
/// placed. Iterative, so a long chain of definitions does not deepen the
/// stack.
///
/// The shape inferences that resolve a definition from the shapes of the
/// names it reads ([`promoted_var_shapes`],
/// [`crate::elementwise_lift::plan_elementwise_lift`]) visit definitions in
/// this order, so what they infer does not depend on the order of the
/// equations.
pub(crate) fn dependency_first_order(deps: &[Vec<usize>]) -> Vec<usize> {
    #[derive(Clone, Copy, PartialEq)]
    enum Mark {
        New,
        Open,
        Done,
    }
    let mut mark = vec![Mark::New; deps.len()];
    let mut order = Vec::with_capacity(deps.len());
    let mut stack: Vec<(usize, usize)> = Vec::new();
    for root in 0..deps.len() {
        if mark[root] != Mark::New {
            continue;
        }
        mark[root] = Mark::Open;
        stack.push((root, 0));
        while let Some(top) = stack.last_mut() {
            let (v, next) = *top;
            match deps[v].get(next) {
                Some(&w) => {
                    top.1 += 1;
                    if mark[w] == Mark::New {
                        mark[w] = Mark::Open;
                        stack.push((w, 0));
                    }
                }
                None => {
                    mark[v] = Mark::Done;
                    order.push(v);
                    stack.pop();
                }
            }
        }
    }
    order
}

/// Call `f` with every variable name `expr` holds, in any field, visiting
/// each shared node once.
fn for_each_variable<'e>(expr: &'e crate::Expr, f: &mut dyn FnMut(&'e str)) {
    fn go<'e>(
        e: &'e crate::Expr,
        seen: &mut HashSet<*const crate::types::ExpressionNode>,
        f: &mut dyn FnMut(&'e str),
    ) {
        match e {
            crate::Expr::Variable(n) => f(n),
            crate::Expr::Operator(node) if seen.insert(std::sync::Arc::as_ptr(node)) => {
                node.for_each_child(&mut |c| go(c, seen, f));
            }
            _ => {}
        }
    }
    go(expr, &mut HashSet::new(), f);
}

/// The ops whose result is an array over their own `output_idx`.
fn is_array_producer_op(op: &str) -> bool {
    crate::faq::is_faq_op(op) || op == "makearray"
}

/// The anonymous axes of a `faq` / `makearray` whose every output index ranges
/// over an inline `[1, n]` interval.
fn inline_producer_axes(rhs: &crate::Expr, name: &str) -> Option<Vec<String>> {
    let crate::Expr::Operator(node) = rhs else {
        return None;
    };
    if !is_array_producer_op(&node.op) {
        return None;
    }
    let (idx, ranges) = (node.output_idx.as_ref()?, node.ranges.as_ref()?);
    if idx.is_empty() {
        return None;
    }
    idx.iter()
        .map(|sym| match ranges.get(sym) {
            Some(crate::types::RangeSpec::Interval([1, _])) => Some(format!("{name}__{sym}")),
            _ => None,
        })
        .collect()
}

/// Julia's `_infer_expr_shape`: the index-set axes `expr` evaluates over.
fn infer_expr_axes(
    expr: &crate::Expr,
    shapes: &HashMap<String, Vec<String>>,
    memo: &mut HashMap<*const crate::types::ExpressionNode, Vec<String>>,
) -> Vec<String> {
    let node = match expr {
        crate::Expr::Variable(n) => return shapes.get(n).cloned().unwrap_or_default(),
        crate::Expr::Operator(node) => node,
        _ => return Vec::new(),
    };
    let key = std::sync::Arc::as_ptr(node);
    if let Some(hit) = memo.get(&key) {
        return hit.clone();
    }
    let out = if node.op == "index" {
        Vec::new()
    } else if is_array_producer_op(&node.op) {
        node.output_idx
            .iter()
            .flatten()
            .map(|sym| match node.ranges.as_ref().and_then(|r| r.get(sym)) {
                Some(crate::types::RangeSpec::IndexSetRef { from, .. }) => Some(from.clone()),
                _ => None,
            })
            .collect::<Option<Vec<String>>>()
            .unwrap_or_default()
    } else {
        let mut result: Vec<String> = Vec::new();
        for arg in &node.args {
            let a = infer_expr_axes(arg, shapes, memo);
            if a.is_empty() || a.iter().all(|x| result.contains(x)) {
                continue;
            }
            if result.is_empty() || result.iter().all(|x| a.contains(x)) {
                result = a;
            }
        }
        result
    };
    memo.insert(key, out.clone());
    out
}

/// Recurse through `expr`, applying [`check_aggregate_node`] to every
/// `faq` node reached (including nested ones), each reported at
/// `field_path()` — the top-level equation side that contains it.
fn check_aggregates_in_expr(
    expr: &crate::Expr,
    field_path: &dyn Fn() -> String,
    esm_file: &EsmFile,
    is_state: &dyn Fn(&str) -> bool,
    var_shapes: &HashMap<String, Vec<String>>,
    errors: &mut Vec<StructuralError>,
) {
    let crate::Expr::Operator(node) = expr else {
        return;
    };
    if node.op == "faq" {
        let path = field_path();
        check_aggregate_node(node, &path, esm_file, is_state, var_shapes, errors);
    }
    node.for_each_child(&mut |child| {
        check_aggregates_in_expr(child, field_path, esm_file, is_state, var_shapes, errors);
    });
}

/// The two static `join` SIDE checks of CONFORMANCE_SPEC §5.5.8, decidable from
/// this one document — the node's `ranges`, the declared variable shapes and the
/// clause itself are all here, so no evaluation, no runtime data and no other
/// file are needed. Both are stated about the DOCUMENT rather than about where
/// any one implementation happens to resolve a join, which is what lets all five
/// bindings pin the same fixtures (`tests/invalid/expected_errors.json`).
///
/// - `join_syms_unknown_symbol` — a clause's `syms` entry that is not a key of
///   that node's `ranges`. Unchecked, the side would resolve to no symbol at
///   all and §5.3's degenerate-positional rule would silently DROP the pair: an
///   ungated full product, reported as a number rather than as a failure.
/// - `join_side_ambiguous` — an `on` key for which the document does not
///   determine a range symbol. A key names a range symbol, an index set, or a
///   declared 1-D variable; in the latter two the symbol comes from the index
///   set (named outright, or the variable's single shape axis). If that set is
///   drawn `{from}` by more than one of the node's ranges and the clause carries
///   no `syms`, the key does not say which. TWO candidates are resolved by the
///   default side assignment only when the key is a DATA COLUMN — a key naming
///   the index set can already say which side it means by naming the range
///   symbol instead, so that spelling is ambiguous at two as well.
fn check_join_sides(
    node: &crate::types::ExpressionNode,
    field_path: &str,
    var_shapes: &HashMap<String, Vec<String>>,
    errors: &mut Vec<StructuralError>,
) {
    let (Some(joins), Some(ranges)) = (node.join.as_ref(), node.ranges.as_ref()) else {
        return;
    };
    // index-set name -> how many of this node's ranges draw it, and which.
    let mut set_to_syms: HashMap<&str, Vec<&str>> = HashMap::new();
    for (sym, spec) in ranges {
        if let crate::types::RangeSpec::IndexSetRef { from, .. } = spec {
            set_to_syms.entry(from.as_str()).or_default().push(sym);
        }
    }
    for syms in set_to_syms.values_mut() {
        syms.sort_unstable();
    }

    for clause in joins {
        if let Some([sl, sr]) = clause.syms.as_ref() {
            for s in [sl, sr] {
                if !ranges.contains_key(s) {
                    let mut declared: Vec<&str> = ranges.keys().map(String::as_str).collect();
                    declared.sort_unstable();
                    errors.push(StructuralError {
                        path: field_path.to_string(),
                        code: StructuralErrorCode::JoinSymsUnknownSymbol,
                        message: format!(
                            "Aggregate join `syms` names '{s}', which is not a range symbol of this aggregate; both entries must name one of its `ranges`"
                        ),
                        details: serde_json::json!({
                            "join_syms_entry": s,
                            "declared_ranges": declared,
                        }),
                    });
                    return; // one finding per node is enough
                }
            }
            // An explicit `syms` answers the ambiguity for every pair here.
            continue;
        }
        for pair in &clause.on {
            for (side, key) in [("left", pair[0].as_str()), ("right", pair[1].as_str())] {
                // A key naming a range symbol outright is never ambiguous.
                if ranges.contains_key(key) {
                    continue;
                }
                // Otherwise the symbol comes from an index set: the one this key
                // names, or the sole axis of the declared 1-D variable it names.
                let (set_name, via_column) = match set_to_syms.get(key) {
                    Some(_) => (key, false),
                    None => match var_shapes.get(key) {
                        Some(shape) if shape.len() == 1 => (shape[0].as_str(), true),
                        _ => continue, // resolves to nothing here; not this check's business
                    },
                };
                let Some(cands) = set_to_syms.get(set_name) else {
                    continue;
                };
                // One candidate: the ordinary join of two distinct relations.
                // Two: resolved by the default assignment, but only for a data
                // column. Three or more: never.
                if cands.len() < 2 || (cands.len() == 2 && via_column) {
                    continue;
                }
                errors.push(StructuralError {
                    path: field_path.to_string(),
                    code: StructuralErrorCode::JoinSideAmbiguous,
                    message: if via_column {
                        format!(
                            "Aggregate join key column '{key}' lives on index set '{set_name}', which {} range symbols of this aggregate draw, so the document does not determine which one the key is read at; name the clause's two sides with `syms`",
                            cands.len()
                        )
                    } else {
                        format!(
                            "Aggregate join key '{key}' names an index set that {} range symbols of this aggregate draw; reference the range symbol directly, or name the clause's two sides with `syms`",
                            cands.len()
                        )
                    },
                    details: serde_json::json!({
                        "join_key": key,
                        "side": side,
                        "index_set": set_name,
                        "candidate_range_symbols": cands,
                    }),
                });
                return; // one finding per node is enough
            }
        }
    }
}

/// Whether `node` is a value-invention `faq`: `distinct: true`, or a
/// `distinct` body. Over such a node a ragged range binds the MEMBER
/// `values[parent, k]` itself (esm-spec §4.3.1 "Ragged ranges"), so its
/// `values` gather is implicit rather than authored.
fn is_value_invention_faq(node: &crate::types::ExpressionNode) -> bool {
    node.distinct == Some(true)
        || matches!(
            node.expr.as_deref(),
            Some(crate::Expr::Operator(body)) if body.op == "distinct"
        )
}

/// Whether `expr` holds a surviving `apply_expression_template` reference
/// (esm-spec §9.6.4), whose body a static walk of this document cannot see.
fn contains_template_reference(expr: &crate::Expr) -> bool {
    let crate::Expr::Operator(node) = expr else {
        return false;
    };
    if node.op == "apply_expression_template" {
        return true;
    }
    let mut found = false;
    node.for_each_child(&mut |child| found = found || contains_template_reference(child));
    found
}

/// Collect every variable-reference name in `expr`, scoped (dotted) names
/// included.
fn collect_variable_refs(expr: &crate::Expr, out: &mut HashSet<String>) {
    match expr {
        crate::Expr::Variable(name) => {
            out.insert(name.clone());
        }
        crate::Expr::Operator(node) => {
            node.for_each_child(&mut |child| collect_variable_refs(child, out));
        }
        crate::Expr::Number(_) | crate::Expr::Integer(_) => {}
    }
}

/// Apply the three static aggregate checks to a single `faq` node.
fn check_aggregate_node(
    node: &crate::types::ExpressionNode,
    field_path: &str,
    esm_file: &EsmFile,
    is_state: &dyn Fn(&str) -> bool,
    var_shapes: &HashMap<String, Vec<String>>,
    errors: &mut Vec<StructuralError>,
) {
    let index_sets = esm_file.index_sets.as_ref();
    check_join_sides(node, field_path, var_shapes, errors);

    // (a) undefined_index_set: a `{from: NAME}` range absent from the registry.
    //
    // Run only when the document DECLARES a registry. A document that declares
    // none is a §9.7.10 discretization-agnostic PDE leaf: its index sets arrive
    // from a discretization library injected into this component's scope by a
    // composing document, a subsystem-ref edge or an inline test (§6.6.6), so
    // the effective registry exists only in that per-run build and resolving
    // `{from: NAME}` against the empty local registry would reject every
    // conforming leaf. The check is deferred there, mirroring §9.6.1's
    // standalone exemption for `template_constraint_unknown_index_set`; a name
    // still unresolved once injection has run is rejected by the evaluating
    // bindings' resolvers (issue #185).
    let registry_declared = index_sets.is_some_and(|m| !m.is_empty());
    if let Some(ranges) = &node.ranges
        && registry_declared
    {
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

    // (d) ragged_values_not_gathered (esm-spec §4.3.1 "Ragged ranges", issue
    // #259): a range over a `kind: "ragged"` index set binds the POSITION k in
    // 1..offsets[parent], never a member, so a body (`expr` / `filter`) that
    // never reads the set's `values` array reads positions where the author
    // meant members. Not decided for a value-invention node, which binds the
    // member itself, nor for a body still holding a template reference, which
    // may do the gather out of sight.
    if let (Some(ranges), Some(sets)) = (&node.ranges, index_sets)
        && !is_value_invention_faq(node)
    {
        let body: Vec<&crate::Expr> = [node.expr.as_deref(), node.filter.as_deref()]
            .into_iter()
            .flatten()
            .collect();
        if !body.iter().any(|part| contains_template_reference(part)) {
            let mut refs = HashSet::new();
            for part in &body {
                collect_variable_refs(part, &mut refs);
            }
            let mut syms: Vec<&String> = ranges.keys().collect();
            syms.sort();
            for sym in syms {
                let crate::types::RangeSpec::IndexSetRef { from, of } = &ranges[sym] else {
                    continue;
                };
                let Some(iset) = sets.get(from) else {
                    continue;
                };
                if iset.kind != "ragged" {
                    continue;
                }
                let Some(values) = iset.values.as_deref() else {
                    continue;
                };
                let scoped = format!(".{values}");
                if refs.iter().any(|r| r == values || r.ends_with(&scoped)) {
                    continue;
                }
                let parent = of
                    .as_ref()
                    .filter(|p| !p.is_empty())
                    .map(|p| p.join(", "))
                    .unwrap_or_else(|| "<parent>".to_string());
                let offsets = iset.offsets.as_deref().unwrap_or("offsets");
                errors.push(StructuralError {
                    path: field_path.to_string(),
                    code: StructuralErrorCode::RaggedValuesNotGathered,
                    message: format!(
                        "faq range '{sym}' iterates ragged index set '{from}', so it binds the POSITION k in 1..{offsets}[{parent}], not a member; the body never reads the set's `values` array '{values}'. Gather the member explicitly: index({values}, {parent}, {sym})"
                    ),
                    details: serde_json::json!({
                        "range": sym,
                        "index_set": from,
                        "values": values,
                    }),
                });
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
        let mut states_read: Vec<String> = free.into_iter().filter(|name| is_state(name)).collect();
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
/// `units.KNOWN_PHYSICAL_CONSTANTS`.
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
/// `units.UnitValidator._check_physical_constants` (gt-j91l / gt-3tgv).
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
    document_units: &HashMap<String, Unit>,
    errors: &mut Vec<StructuralError>,
) {
    let rs_path = format!("/reaction_systems/{rs_name}");

    // Create a map of defined species (species name is the HashMap key)
    let defined_species: HashSet<String> = rs.species.keys().cloned().collect();

    // Rate expressions can reference both parameters and species names.
    let defined_parameters: HashSet<String> = rs.parameters.keys().cloned().collect();

    // esm-spec §4.9.1.1, the same rule as for a model's `variables`: a species
    // and a reaction parameter become symbols of the derived ODE system exactly
    // as a `variables` entry does (§7.4), so all three declaration maps collide
    // with the globally-scoped names identically.
    let owner = format!("Reaction system '{rs_name}'");
    check_reserved_declaration_names(
        esm_file,
        rs.species.keys(),
        &format!("{rs_path}/species"),
        &owner,
        "species",
        errors,
    );
    check_reserved_declaration_names(
        esm_file,
        rs.parameters.keys(),
        &format!("{rs_path}/parameters"),
        &owner,
        "parameter",
        errors,
    );

    let rate_scope: HashSet<String> = defined_parameters
        .union(&defined_species)
        .cloned()
        .chain(implicitly_declared_symbols(esm_file))
        .collect();

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
        // A rate law reads species concentrations as well as parameters (a
        // non-mass-action `k*A*B`, a water-vapour factor `H2O`), and the
        // implicit symbols (§4.9.1) are in scope as everywhere else, so none
        // of those is an undeclared parameter.
        validate_rate_expression(
            &reaction.rate,
            &rate_scope,
            system_refs,
            &format!("{rxn_path}/rate"),
            reaction_label,
            errors,
        );
    }

    // The names a reaction system's constraint equations, events and inline-test
    // references resolve against: its species and parameters plus the implicit
    // symbols (§4.9.1), widened to the document scope when the system is coupled,
    // as `ModelCtx::new` scopes a model.
    let mut rs_scope: HashSet<String> = defined_species
        .union(&defined_parameters)
        .cloned()
        .collect();
    rs_scope.extend(implicitly_declared_symbols(esm_file));
    if coupled_system_names(esm_file).contains(rs_name) {
        rs_scope.extend(document_declared_names(esm_file));
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
            // expression over the system's species and parameters — reported at
            // the side that carries the defect, as a model equation is.
            let ce_path = format!("{rs_path}/constraint_equations/{ce_idx}");
            for (side, expr) in [("lhs", &eq.lhs), ("rhs", &eq.rhs)] {
                let mut ref_scope = rs_scope.clone();
                collect_bound_symbols(expr, &mut ref_scope);
                validate_expression_references_with_systems(
                    expr,
                    &ref_scope,
                    system_refs,
                    &HashSet::new(),
                    &format!("{ce_path}/{side}"),
                    ce_idx,
                    errors,
                );
            }
        }
    }

    // A reaction system's events are the same sites as a model's. A reaction
    // system has no `variables` map, so there is no parameter for an affect to
    // write and `event_affects_parameter` cannot arise here.
    let no_variables = indexmap::IndexMap::new();
    for (event_idx, event) in rs.discrete_events.iter().flatten().enumerate() {
        validate_discrete_event(event, event_idx, &rs_path, &rs_scope, &no_variables, errors);
    }
    for (event_idx, event) in rs.continuous_events.iter().flatten().enumerate() {
        validate_continuous_event(event, event_idx, &rs_path, &rs_scope, &no_variables, errors);
    }

    // An inline test's assertion `reference` (§6.6) is the same site on a
    // reaction system as on a model.
    for (t_idx, test) in rs.tests.iter().flatten().enumerate() {
        for (a_idx, assertion) in test.assertions.iter().enumerate() {
            let Some(crate::types::AssertionReference::Expression(reference)) =
                &assertion.reference
            else {
                continue;
            };
            let mut ref_scope = rs_scope.clone();
            collect_bound_symbols(reference, &mut ref_scope);
            validate_expression_references_with_systems(
                reference,
                &ref_scope,
                system_refs,
                &HashSet::new(),
                &format!("{rs_path}/tests/{t_idx}/assertions/{a_idx}/reference"),
                0,
                errors,
            );
        }
    }

    // Stoichiometric rate-dimension check (spec §7.4).
    validate_reaction_rate_units(rs_name, rs, document_units, errors);
}

/// Enforce the mass-action dimensional constraint from spec §7.4: rate
/// dimensions must equal concentration^(1-total_order)/time, where the
/// reference concentration unit is the first substrate's units. Mirrors the
/// Julia/Python/TS/Go checks so the same invalid fixtures are rejected across
/// all bindings. Skipped when the reference concentration (first substrate) is
/// dimensionless — mole-fraction and ppm species commonly bake a
/// number-density factor into the rate constant.
///
/// A rate may read another system's quantity by scoped reference (`Other.k`,
/// `Sub.k`); it is typed exactly as in a model ([`ComponentUnitEnv`]): the
/// system's own species and parameters, then paths relative to its own
/// subsystems, then the document's top-level systems.
fn validate_reaction_rate_units(
    rs_name: &str,
    rs: &crate::ReactionSystem,
    document_units: &HashMap<String, Unit>,
    errors: &mut Vec<StructuralError>,
) {
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

    let env = ComponentUnitEnv::new(env, rs.subsystems.as_ref(), document_units);
    let time = Unit::base(crate::units::Dimension::Time, 1, 1.0);

    for (rxn_idx, reaction) in rs.reactions.iter().enumerate() {
        let rxn_path = format!("/reaction_systems/{rs_name}/reactions/{rxn_idx}");
        let reaction_label = reaction
            .id
            .as_deref()
            .or(reaction.name.as_deref())
            .unwrap_or("unnamed");

        // Rate dimension from expression propagation.
        let rate_unit = match Unit::propagate_in(&reaction.rate, &env) {
            Ok(u) => u,
            Err(_) => continue,
        };

        let substrates = match reaction.substrates.as_ref() {
            Some(s) if !s.is_empty() => s,
            _ => continue,
        };

        // Reference concentration unit = first substrate's species units.
        let first_sp_name = &substrates[0].species;
        let conc_unit = match env.unit_of(first_sp_name) {
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
            if !env.contains(&entry.species) {
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
/// `output_idx` and `ranges` keys (`faq`) and the `integral` op's `var`.
/// These are in scope for the
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
/// `index` element positions, `output_idx`/`ranges` keys, integral vars and
/// template `bindings`. Per-node scoping alone binds
/// a symbol only for the subtree UNDER the node that introduces it, which is too
/// narrow for a `makearray` stencil: it binds the grid indices `i`/`j` for ALL
/// its `values`, yet an index spelled `i + 1` in one value is a USE of the `i`
/// bound (as a bare `index` position) in another. Scanning the whole expression
/// once and holding the union in scope throughout it matches Go
/// `collectBoundSymbols` / TS `collectIndexSymbols`.
/// [`collect_bound_symbols`], also noting in `faq` whether a `faq` node was
/// reached.
fn collect_bound_symbols_noting_faq(expr: &crate::Expr, out: &mut HashSet<String>, faq: &mut bool) {
    if let crate::Expr::Operator(node) = expr {
        *faq |= node.op == "faq";
        for sym in bound_index_symbols(node) {
            out.insert(sym);
        }
        node.for_each_child(&mut |child| collect_bound_symbols_noting_faq(child, out, faq));
    }
}

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
///
/// Nested subsystems expose their members at every depth, under the relative
/// dotted path from the owning model (`A.B.C.var`, esm-spec §4.9.2): stopping at
/// the first level is the two-segment shortcut §4.9.2 rules out, and rejected
/// an `ic` of a state five subsystems down.
fn subsystem_scoped_refs(model: &crate::Model) -> HashSet<String> {
    let mut refs = HashSet::new();
    if let Some(subs) = &model.subsystems {
        collect_subsystem_scoped_refs("", subs.iter(), &mut refs);
    }
    refs
}

/// [`subsystem_scoped_refs`] for one `subsystems` map, whose entries sit under
/// the dotted `prefix` (empty at the owning model).
fn collect_subsystem_scoped_refs<'a>(
    prefix: &str,
    subs: impl Iterator<Item = (&'a String, &'a serde_json::Value)>,
    refs: &mut HashSet<String>,
) {
    for (sub_name, value) in subs {
        let path = if prefix.is_empty() {
            sub_name.clone()
        } else {
            format!("{prefix}.{sub_name}")
        };
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
        //
        // An inlined `ref` may also still carry the WHOLE referenced document —
        // `{esm, metadata, models: {<one>: …}}`, the post-resolution shape the
        // simulator's `parse_subsystem_model` accepts — so its single component
        // is the one whose members are exposed.
        let component = value
            .get("models")
            .or_else(|| value.get("reaction_systems"))
            .and_then(|m| m.as_object())
            .filter(|m| m.len() == 1)
            .and_then(|m| m.values().next())
            .unwrap_or(value);
        for field in ["variables", "species"] {
            let Some(members) = component.get(field).and_then(|v| v.as_object()) else {
                continue;
            };
            for var in members.keys() {
                refs.insert(format!("{path}.{var}"));
            }
        }
        if let Some(nested) = component.get("subsystems").and_then(|v| v.as_object()) {
            collect_subsystem_scoped_refs(&path, nested.iter(), refs);
        }
    }
}

/// `<System>.<member>` → declared unit string for every member of the
/// document's top-level models and reaction systems (and, through their
/// subsystems, `<System>.<sub>.<member>`) that declares units (esm-spec
/// §4.9.2).
///
/// A mounted component is, after resolution, identical to one written inline
/// (§4.7 "Resolution timing"), so a member reached across a `{ref}` mount edge
/// — a `subsystems.<k>` mount or a top-level `models.<k>` mount — carries the
/// units its declaration states, exactly as a local one does (§4.8.4).
pub(crate) fn toplevel_reference_units(esm_file: &EsmFile) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut insert = |name: String, units: Option<&str>| {
        if let Some(units) = units {
            out.insert(name, units.to_string());
        }
    };
    for (name, model) in esm_file.models.iter().flatten() {
        for (var, decl) in &model.variables {
            insert(format!("{name}.{var}"), decl.units.as_deref());
        }
        if let Some(subs) = &model.subsystems {
            collect_subsystem_units(name, subs.iter(), &mut insert);
        }
    }
    for (name, rs) in esm_file.reaction_systems.iter().flatten() {
        for (member, units) in rs
            .species
            .iter()
            .map(|(k, v)| (k, &v.units))
            .chain(rs.parameters.iter().map(|(k, v)| (k, &v.units)))
        {
            insert(format!("{name}.{member}"), units.as_deref());
        }
        if let Some(subs) = &rs.subsystems {
            collect_subsystem_units(name, subs.iter(), &mut insert);
        }
    }
    out
}

/// `<sub>.<member>` → declared unit string, relative to a component whose
/// `subsystems` map this is, at any depth. A member that declares NO units is
/// still present (as `None`): the relative path is what the name resolves to,
/// so it must shadow a top-level member with the same dotted name.
pub(crate) fn subsystem_reference_units(
    subsystems: &indexmap::IndexMap<String, serde_json::Value>,
) -> HashMap<String, Option<String>> {
    let mut out = HashMap::new();
    collect_subsystem_units("", subsystems.iter(), &mut |name, units| {
        out.insert(name, units.map(str::to_string));
    });
    out
}

/// Visit every member of one raw `subsystems` map whose entries sit under the
/// dotted `prefix` (empty at the owning component), with its declared unit
/// string if any. Mirrors [`collect_subsystem_scoped_refs`]: the same members,
/// with their units.
fn collect_subsystem_units<'a>(
    prefix: &str,
    subs: impl Iterator<Item = (&'a String, &'a serde_json::Value)>,
    visit: &mut impl FnMut(String, Option<&str>),
) {
    for (sub_name, value) in subs {
        let path = if prefix.is_empty() {
            sub_name.clone()
        } else {
            format!("{prefix}.{sub_name}")
        };
        let component = value
            .get("models")
            .or_else(|| value.get("reaction_systems"))
            .and_then(|m| m.as_object())
            .filter(|m| m.len() == 1)
            .and_then(|m| m.values().next())
            .unwrap_or(value);
        for field in ["variables", "species", "parameters"] {
            let Some(members) = component.get(field).and_then(|v| v.as_object()) else {
                continue;
            };
            for (member, decl) in members {
                let units = decl.get("units").and_then(|u| u.as_str());
                visit(format!("{path}.{member}"), units);
            }
        }
        if let Some(nested) = component.get("subsystems").and_then(|v| v.as_object()) {
            collect_subsystem_units(&path, nested.iter(), visit);
        }
    }
}

pub(crate) fn validate_expression_references_with_systems<S: std::hash::BuildHasher>(
    expr: &crate::Expr,
    defined_vars: &HashSet<String, S>,
    system_refs: &HashMap<String, SystemInfo>,
    local_scoped: &HashSet<String>,
    base_path: &str,
    equation_index: usize,
    errors: &mut Vec<StructuralError>,
) {
    references_in_scope(
        expr,
        &NameScope::Set(&|name: &str| defined_vars.contains(name)),
        system_refs,
        local_scoped,
        base_path,
        equation_index,
        errors,
        &mut RefWalkSeen::default(),
    );
}

/// The names in scope at one point of an expression: a declared set, with the
/// index symbols bound on the way down layered over it, so entering a binding
/// node does not copy the declared set.
#[derive(Clone, Copy)]
enum NameScope<'a> {
    Set(&'a dyn Fn(&str) -> bool),
    With(&'a NameScope<'a>, &'a [String]),
    WithSet(&'a NameScope<'a>, &'a HashSet<String>),
}

impl NameScope<'_> {
    fn contains(&self, name: &str) -> bool {
        match self {
            NameScope::Set(declared) => declared(name),
            NameScope::With(outer, names) => {
                names.iter().any(|n| n == name) || outer.contains(name)
            }
            NameScope::WithSet(outer, names) => names.contains(name) || outer.contains(name),
        }
    }
}

/// [`validate_expression_references_with_systems`] over a [`NameScope`].
/// What a [`references_in_scope`] walk met besides references: a node that
/// binds index symbols, a `faq` node, an `enum` node (whose subtree it skips).
#[derive(Default)]
struct RefWalkSeen {
    binder: bool,
    faq: bool,
    enum_node: bool,
}

#[allow(clippy::too_many_arguments)]
fn references_in_scope(
    expr: &crate::Expr,
    defined_vars: &NameScope<'_>,
    system_refs: &HashMap<String, SystemInfo>,
    local_scoped: &HashSet<String>,
    base_path: &str,
    equation_index: usize,
    errors: &mut Vec<StructuralError>,
    seen: &mut RefWalkSeen,
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
            // An `enum` node's operands are an enum NAME and a SYMBOL (esm-spec
            // §9.3), resolved against the `enums` block, not variable
            // references. Reading them as variables reported every `enum` use
            // as two undefined variables.
            if op_node.op == "enum" {
                seen.enum_node = true;
                return;
            }
            seen.faq |= op_node.op == "faq";
            // Recursively validate every expression-bearing child via the
            // canonical walker — args PLUS the sidecar fields (integral bounds,
            // aggregate/faq bodies, filter predicates, table axes,
            // aggregate keys, template bindings) — so a reference hidden
            // outside `args` is not missed. Index symbols the node BINDS
            // (`output_idx`/`ranges`/`var`/`arg`) are added to the in-scope set
            // for the descent so a bound loop index is not flagged as
            // undefined.
            let bound = bound_index_symbols(op_node);
            seen.binder |= !bound.is_empty();
            let scope = if bound.is_empty() {
                *defined_vars
            } else {
                NameScope::With(defined_vars, &bound)
            };
            op_node.for_each_child(&mut |child| {
                references_in_scope(
                    child,
                    &scope,
                    system_refs,
                    local_scoped,
                    base_path,
                    equation_index,
                    errors,
                    seen,
                )
            });
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

fn validate_discrete_event<D: DeclaredLookup + ?Sized>(
    event: &crate::DiscreteEvent,
    event_idx: usize,
    parent_path: &str,
    defined_vars: &D,
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
fn validate_continuous_event<D: DeclaredLookup + ?Sized>(
    event: &crate::ContinuousEvent,
    event_idx: usize,
    parent_path: &str,
    defined_vars: &D,
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
struct EventAffectsCtx<'a, D: ?Sized> {
    defined_vars: &'a D,
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
fn validate_event_affects<D: DeclaredLookup + ?Sized>(
    affects: &[crate::AffectEquation],
    ctx: &EventAffectsCtx<'_, D>,
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
        if !defined_vars.declares(&affect.lhs) {
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
fn validate_event_ref_expression<D: DeclaredLookup + ?Sized>(
    expr: &crate::Expr,
    defined_vars: &D,
    path: &str,
    errors: &mut Vec<StructuralError>,
) {
    match expr {
        crate::Expr::Variable(var_name) => {
            if !is_builtin_function_name(var_name) && !defined_vars.declares(var_name) {
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

// ---------------------------------------------------------------------------
// Cross-scope observed dependency cycles — esm-spec §4.9.7
// ---------------------------------------------------------------------------

/// One model node of the document — a top-level model or a subsystem at any
/// depth — as the `circular_dependency` graph needs it: its §6.3.1
/// classification (the observeds and their defining right-hand sides), its
/// §4.3.1.1 recurrence candidates, the names it declares, and the dotted names
/// its equations put under `D(·, t)`.
pub(crate) struct ObservedScope {
    /// The node's full scoped name: `ModelA`, `ModelN.Sub`.
    pub(crate) path: String,
    pub(crate) class: crate::classification::Classification,
    candidates: HashSet<String>,
    /// Its §4.3.1.2 recurrence group candidates, by local name.
    groups: Vec<std::collections::BTreeSet<String>>,
    /// Every variable the node declares, whatever its kind: a reference
    /// resolves by DECLARATION (a state found first shadows an observed found
    /// later), and only then asks whether its target is an observed.
    pub(crate) declared: HashSet<String>,
    /// The dotted names on a `D(·, t)` left-hand side, read the §6.3.1 way
    /// ([`crate::classification::lhs_form_ref`]: `D(a + b)` credits no
    /// variable). A bare one is this node's own state, which `class` counts.
    differentiated_refs: Vec<String>,
}

impl ObservedScope {
    pub(crate) fn new(
        path: String,
        variables: &indexmap::IndexMap<String, crate::ModelVariable>,
        equations: &[crate::Equation],
    ) -> Self {
        let differentiated_refs = equations
            .iter()
            .filter_map(|eq| match crate::classification::lhs_form_ref(&eq.lhs) {
                crate::classification::LhsFormRef::Derivative(name) if name.contains('.') => {
                    Some(name.to_string())
                }
                _ => None,
            })
            .collect();
        ObservedScope {
            path,
            class: crate::classification::Classification::from_parts(variables, equations),
            candidates: recurrence_candidate_vars_of_parts(variables, equations),
            groups: recurrence_groups_of_parts(variables, equations),
            declared: variables.keys().cloned().collect(),
            differentiated_refs,
        }
    }
}

/// A node of the `circular_dependency` graph: the scope that declares the
/// observed, and the observeds its defining RHS reads, by full scoped name.
struct ObservedNode<'a> {
    scope: &'a str,
    successors: std::collections::BTreeSet<String>,
}

/// Every model node of `models`, top-level and subsystems at every depth, in
/// document order (a model, then its subsystems depth-first), handed to `f`
/// as its full scoped name (`ModelA`, `ModelN.Sub`), its JSON pointer
/// (`/models/ModelN/subsystems/Sub`), its variables and its equations.
///
/// A top-level model is read from its typed form. A subsystem is held as raw
/// JSON (`Model::subsystems` is untyped because an entry may be an unresolved
/// `{"ref": …}` mount), so its `variables` and `equations` are deserialized
/// THROUGH a borrow of that JSON — no clone of the subtree, and nothing else of
/// it is read. The loader resolves every `{"ref": …}` mount before a document
/// reaches a check, so a ref still standing here can only come from a caller
/// that built the `EsmFile` by hand without resolving it; such a mount declares
/// nothing. An equation that does not type is skipped, exactly as
/// [`crate::classification::Classification::from_json`] skips it.
#[allow(clippy::type_complexity)]
pub(crate) fn for_each_model_node(
    models: &indexmap::IndexMap<String, crate::Model>,
    f: &mut dyn FnMut(
        &str,
        &str,
        &indexmap::IndexMap<String, crate::ModelVariable>,
        &[crate::Equation],
    ),
) {
    #[allow(clippy::type_complexity)]
    fn subsystems(
        prefix: &str,
        pointer: &str,
        entries: &mut dyn Iterator<Item = (&String, &serde_json::Value)>,
        f: &mut dyn FnMut(
            &str,
            &str,
            &indexmap::IndexMap<String, crate::ModelVariable>,
            &[crate::Equation],
        ),
    ) {
        use serde::Deserialize as _;
        for (name, value) in entries {
            let path = format!("{prefix}.{name}");
            let sub_pointer = format!("{pointer}/subsystems/{name}");
            let variables = value
                .get("variables")
                .and_then(|v| {
                    indexmap::IndexMap::<String, crate::ModelVariable>::deserialize(v).ok()
                })
                .unwrap_or_default();
            let equations: Vec<crate::Equation> = value
                .get("equations")
                .and_then(serde_json::Value::as_array)
                .map(|eqs| {
                    eqs.iter()
                        .filter_map(|eq| crate::Equation::deserialize(eq).ok())
                        .collect()
                })
                .unwrap_or_default();
            f(&path, &sub_pointer, &variables, &equations);
            if let Some(nested) = value.get("subsystems").and_then(|s| s.as_object()) {
                subsystems(&path, &sub_pointer, &mut nested.iter(), f);
            }
        }
    }

    for (name, model) in models {
        let pointer = format!("/models/{name}");
        f(name, &pointer, &model.variables, &model.equations);
        if let Some(subs) = &model.subsystems {
            subsystems(name, &pointer, &mut subs.iter(), f);
        }
    }
}

/// Every model node of `models` as the `circular_dependency` graph reads it
/// ([`for_each_model_node`]'s order).
pub(crate) fn observed_scopes(
    models: &indexmap::IndexMap<String, crate::Model>,
) -> Vec<ObservedScope> {
    let mut out = Vec::new();
    for_each_model_node(models, &mut |path, _, variables, equations| {
        out.push(ObservedScope::new(path.to_string(), variables, equations));
    });
    out
}

/// The full scoped name a reference read from the model node `from` names,
/// by the reference-integrity walk's precedence (esm-spec §4.8.4, "A scoped
/// reference carries its target's units"; §4.9.7): `from`'s own declared
/// names, then a dotted path relative to `from`'s own subsystems, then a
/// top-level system path. `None` when no model node declares it (an
/// unresolved reference, or one into a reaction system or a data loader,
/// none of which declares an observed).
pub(crate) fn resolve_observed_ref(
    scopes: &HashMap<&str, &ObservedScope>,
    from: &str,
    name: &str,
) -> Option<String> {
    if scopes.get(from).is_some_and(|s| s.declared.contains(name)) {
        return Some(format!("{from}.{name}"));
    }
    if !name.contains('.') {
        return None;
    }
    [format!("{from}.{name}"), name.to_string()]
        .into_iter()
        .find(|full| {
            full.rsplit_once('.').is_some_and(|(system, var)| {
                scopes.get(system).is_some_and(|s| s.declared.contains(var))
            })
        })
}

/// Every name in `expr` that a reference may resolve through: the free bare
/// symbols ([`collect_free_symbols`], the §4.9.6 walk, minus the binders
/// [`collect_bound_symbols`] finds) and every dotted reference, descending
/// every Expression child.
pub(crate) fn referenced_names(expr: &crate::Expr) -> HashSet<String> {
    fn dotted(expr: &crate::Expr, out: &mut HashSet<String>) {
        match expr {
            crate::Expr::Variable(name) if name.contains('.') => {
                out.insert(name.clone());
            }
            crate::Expr::Operator(op) => op.for_each_child(&mut |c| dotted(c, out)),
            _ => {}
        }
    }
    let mut names = HashSet::new();
    collect_free_symbols(expr, &mut names);
    let mut bound = HashSet::new();
    collect_bound_symbols(expr, &mut bound);
    names.retain(|n| !bound.contains(n));
    dotted(expr, &mut names);
    names
}

/// The full scoped names of every observed of the document (esm-spec §6.3.1,
/// §4.9.7): each node's observeds, less any that another node differentiates
/// through a scoped name, which that `D(·, t)` makes a state.
pub(crate) fn document_observeds(
    scopes: &[ObservedScope],
    by_path: &HashMap<&str, &ObservedScope>,
) -> HashSet<String> {
    let states: HashSet<String> = scopes
        .iter()
        .flat_map(|s| {
            s.differentiated_refs
                .iter()
                .filter_map(|r| resolve_observed_ref(by_path, &s.path, r))
        })
        .collect();
    scopes
        .iter()
        .flat_map(|s| {
            s.class
                .observed_definitions
                .keys()
                .map(move |v| format!("{}.{v}", s.path))
        })
        .filter(|n| !states.contains(n))
        .collect()
}

/// The document-wide observed dependency graph of esm-spec §4.9.7, keyed by
/// full scoped name: §4.9.6's graph with its edges extended across scope
/// boundaries. Every reference resolves by [`resolve_observed_ref`]; one that
/// resolves to anything but an observed (a state, a parameter, a species, an
/// algebraic or an undefined unknown, an undeclared name) is no edge. An
/// observed another node differentiates through a scoped name is a state, so
/// it is no node. The recurrence self-edge is dropped for a candidate exactly
/// as in [`observed_dependency_graph`].
fn document_observed_graph(
    scopes: &[ObservedScope],
) -> std::collections::BTreeMap<String, ObservedNode<'_>> {
    let by_path: HashMap<&str, &ObservedScope> =
        scopes.iter().map(|s| (s.path.as_str(), s)).collect();
    let observed = document_observeds(scopes, &by_path);
    let mut nodes = std::collections::BTreeMap::new();
    for scope in scopes {
        for (name, rhs) in &scope.class.observed_definitions {
            let node = format!("{}.{name}", scope.path);
            if !observed.contains(&node) {
                continue;
            }
            let mut successors: std::collections::BTreeSet<String> = referenced_names(rhs)
                .iter()
                .filter_map(|r| resolve_observed_ref(&by_path, &scope.path, r))
                .filter(|full| observed.contains(full))
                .collect();
            if scope.candidates.contains(name) {
                successors.remove(&node);
            }
            nodes.insert(
                node,
                ObservedNode {
                    scope: scope.path.as_str(),
                    successors,
                },
            );
        }
    }
    // esm-spec §4.3.1.2: a recurrence group is swept as ONE unit, so here it
    // is one node — its first member — carrying every member's external reads.
    // CONTRACTED, not merely stripped of its internal edges: a cycle that
    // leaves the group through another scope and comes back
    // (`a →(group) b → X.c → a`) is a real cycle, and dropping `a → b` would
    // hide it. Within one scope the strongly connected component a group is
    // drawn from is already maximal, so §4.9.6 can simply drop the edges.
    for scope in scopes {
        for g in &scope.groups {
            let members: Vec<String> = g
                .iter()
                .map(|m| format!("{}.{m}", scope.path))
                .filter(|n| nodes.contains_key(n))
                .collect();
            let Some(rep) = members.first().cloned() else {
                continue;
            };
            let mut merged = std::collections::BTreeSet::new();
            for m in &members {
                if let Some(n) = nodes.get(m) {
                    merged.extend(n.successors.iter().cloned());
                }
            }
            for m in &members[1..] {
                nodes.remove(m);
            }
            merged.retain(|s| !members.contains(s));
            for n in nodes.values_mut() {
                if n.successors.iter().any(|s| members.contains(s)) {
                    n.successors.retain(|s| !members.contains(s));
                    n.successors.insert(rep.clone());
                }
            }
            if let Some(n) = nodes.get_mut(&rep) {
                merged.remove(&rep);
                n.successors = merged;
            }
        }
    }
    nodes
}

/// The first cycle of the pinned §4.9.7 traversal that crosses a scope
/// boundary: a depth-first search with roots and successors in lexicographic
/// order, where the first back edge `V → W` closes the cycle from `W` along the
/// search path to `V` and back to `W`. A back edge whose cycle lies in one
/// scope is `observed_cycle`'s (§4.9.6), so it is skipped and the search goes
/// on. Iterative for the reason [`crate::classification::first_observed_cycle`]
/// is: the depth is the length of the longest observed chain, which the
/// document, not the schema, bounds.
fn first_cross_scope_cycle(
    graph: &std::collections::BTreeMap<String, ObservedNode<'_>>,
) -> Option<Vec<String>> {
    const ON_CHAIN: u8 = 1;
    const FINISHED: u8 = 2;
    let mut state: HashMap<&str, u8> = HashMap::new();
    for root in graph.keys() {
        if state.contains_key(root.as_str()) {
            continue;
        }
        state.insert(root.as_str(), ON_CHAIN);
        let mut chain: Vec<&str> = vec![root.as_str()];
        let mut cursors = vec![graph[root].successors.iter()];
        while let Some(&name) = chain.last() {
            let Some(successor) = cursors.last_mut().and_then(Iterator::next) else {
                state.insert(name, FINISHED);
                chain.pop();
                cursors.pop();
                continue;
            };
            match state.get(successor.as_str()).copied() {
                Some(ON_CHAIN) => {
                    let start = chain
                        .iter()
                        .position(|c| *c == successor.as_str())
                        .unwrap_or(0);
                    let on_cycle = &chain[start..];
                    let scope = graph[successor].scope;
                    if on_cycle.iter().all(|n| graph[*n].scope == scope) {
                        continue;
                    }
                    let mut cycle: Vec<String> =
                        on_cycle.iter().map(|s| (*s).to_string()).collect();
                    cycle.push(successor.clone());
                    return Some(cycle);
                }
                Some(_) => {}
                None => {
                    state.insert(successor.as_str(), ON_CHAIN);
                    chain.push(successor.as_str());
                    cursors.push(graph[successor].successors.iter());
                }
            }
        }
    }
    None
}

/// Reject a dependency cycle among observeds that crosses a scope boundary —
/// two top-level models, or a model and one of its subsystems
/// (`circular_dependency`, esm-spec §4.9.7).
///
/// Only an observed is computed during an evaluation, so only a read inside an
/// observed's definition orders two computations: reading a state or a
/// parameter never closes a loop, and neither does a model-level "M reads N
/// and N reads M" whose variable-level chains do not close
/// (`tests/valid/cross_model_observed_reads_no_loop.esm`). One cycle is
/// reported per document, at `/models`, with `details.cycle` the scoped names
/// on it and the entry node repeated.
pub(crate) fn check_circular_dependencies_in_models(
    models: &indexmap::IndexMap<String, crate::Model>,
    errors: &mut Vec<StructuralError>,
) {
    let scopes = observed_scopes(models);
    let graph = document_observed_graph(&scopes);
    if let Some(cycle) = first_cross_scope_cycle(&graph) {
        errors.push(StructuralError {
            path: "/models".to_string(),
            code: StructuralErrorCode::CircularDependency,
            message: format!(
                "Circular dependency among observeds: {}",
                cycle.join(" \u{2192} ")
            ),
            details: serde_json::json!({ "cycle": cycle }),
        });
    }
}

#[cfg(test)]
mod dependency_order_tests {
    use super::*;

    #[test]
    fn each_definition_comes_after_what_it_reads() {
        // 0 reads 1, 1 reads 2; 3 is independent; 4 and 5 read each other.
        let deps = vec![vec![1], vec![2], vec![], vec![], vec![5], vec![4]];
        let order = dependency_first_order(&deps);
        let at = |i: usize| order.iter().position(|&o| o == i).unwrap();
        assert_eq!(order.len(), deps.len());
        assert!(at(2) < at(1) && at(1) < at(0), "{order:?}");
        // On the cycle, the one entered first is placed last.
        assert!(at(5) < at(4), "{order:?}");
    }

    #[test]
    fn a_promoted_shape_does_not_depend_on_the_equation_order() {
        // `k` reads `u` [c] and `w`, defined after it over [c, l].
        let doc = serde_json::json!({
            "esm": "2.0.0", "metadata": {"name": "order_probe"},
            "index_sets": {"c": {"kind": "interval", "size": 3},
                           "l": {"kind": "interval", "size": 2}},
            "models": {"M": {
                "variables": {
                    "u": {"type": "parameter", "shape": ["c"], "default": 1.0},
                    "v": {"type": "parameter", "shape": ["c", "l"], "default": 1.0},
                    "k": {"type": "unknown"}, "w": {"type": "unknown"},
                    "s": {"type": "unknown", "default": 0.0}},
                "equations": [
                    {"lhs": "k", "rhs": {"op": "*", "args": ["u", "w"]}},
                    {"lhs": "w", "rhs": {"op": "*", "args": [2, "v"]}},
                    {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 0.0}
                ]
            }}
        });
        let file = crate::parse::load_string(&doc.to_string()).expect("loads");
        let model = file.models.as_ref().expect("models")["M"].clone();
        let shapes = promoted_var_shapes(&model);
        assert_eq!(
            shapes.get("k"),
            Some(&vec!["c".to_string(), "l".to_string()]),
            "{shapes:?}"
        );
    }
}
