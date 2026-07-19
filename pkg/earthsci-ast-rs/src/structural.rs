//! Structural validation: equation balance, model references, reactions,
//! events, and inter-model dependency cycles.
//!
//! This module is the equation/structural half of the validation surface.
//! Schema validation, the public `ValidationResult` types, and the top-level
//! orchestrator live in [`crate::validate`]; coupling-entry validation lives
//! in [`crate::coupling`].
//!
//! A parallel LOAD-TIME stack lives in `crate::parse`
//! (`validate_structural_json`): it runs on raw JSON inside `load()` with
//! cross-binding-pinned String messages, and some rules deliberately exist in
//! both layers — see the note in parse.rs before changing a shared rule.

use crate::EsmFile;
use crate::units::{
    build_unit_env, check_equation_dimensions, check_expression_dimensions, parse_unit,
};
use crate::validate::{StructuralError, StructuralErrorCode, SystemInfo};
use std::collections::{HashMap, HashSet};

pub(crate) fn validate_model(
    esm_file: &EsmFile,
    model_name: &str,
    model: &crate::Model,
    system_refs: &HashMap<String, SystemInfo>,
    errors: &mut Vec<StructuralError>,
    warnings: &mut Vec<String>,
) {
    let model_path = format!("/models/{model_name}");

    // Create a map of defined variables by type
    let mut state_vars = Vec::new();
    let mut defined_vars = HashSet::new();

    for (var_name, var) in &model.variables {
        defined_vars.insert(var_name.clone());

        if matches!(var.var_type, crate::VariableType::State) {
            state_vars.push(var_name.clone());
        }

        // Note: The current type system doesn't have expressions on ModelVariable yet
        // This validation would be added once the types are updated to match the spec
    }

    // esm-spec §4.9.1: three classes of symbol are in scope WITHOUT appearing in
    // the `variables` map, and none of them is an `undefined_variable`. Adding
    // them to the in-scope set here is what lets every reference check below —
    // equations, observed expressions, event conditions and event affects —
    // resolve them uniformly.
    defined_vars.extend(implicitly_declared_symbols(esm_file));

    // Scoped references this model's equations may use that are NOT top-level
    // systems: the `<sub>.<var>` fields of each DataLoader mounted as a
    // subsystem (flatten lowers these to observeds `<model>.<sub>.<var>`).
    let local_scoped = loader_subsystem_scoped_refs(model);

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

    // Every reference check routes through this one gate, which keeps the five
    // call sites below uniform. A coupled model is checked too (F-1) — its
    // `defined_vars` was widened to the document scope above — so the gate no
    // longer short-circuits. Unit propagation is a separate pass: the dimensions
    // of what a model spells must agree regardless of which system owns a name.
    let check_refs =
        |expr: &crate::Expr, path: &str, idx: usize, errs: &mut Vec<StructuralError>| {
            // Any binder introduced ANYWHERE in this expression is in scope
            // throughout it (a `makearray` binds its grid indices for every
            // value; see `collect_bound_symbols`). Seed those before the descent,
            // which then adds nested binders on top per node.
            let mut scope = defined_vars.clone();
            collect_bound_symbols(expr, &mut scope);
            validate_expression_references_with_systems(
                expr,
                &scope,
                system_refs,
                &local_scoped,
                path,
                idx,
                errs,
            );
        };

    // Check the equation/unknown balance (esm-spec §4.9.4).
    //
    // The check is UNKNOWNS vs EQUATIONS — not "state variables vs
    // time-derivative equations". An equation is credited whichever form its LHS
    // takes: a derivative (`D(x)/dt ~ …`), a bare variable (`x ~ …`, an
    // algebraic/observed equation), or an EXPRESSION (`H*H*SO4 ~ Ksp`, an
    // implicit algebraic constraint). Crediting only a bare-variable derivative
    // LHS undercounts every algebraic equation, which is why a
    // `system_kind: "nonlinear"` equilibrium model — no time derivative anywhere
    // — was reported as "0 ODE equations, 2 state variables" and rejected.
    //
    // `initialization_equations` (§6.2) are a separate block with a separate
    // balance and are deliberately NOT counted here.
    let defining_equations = count_defining_equations(&model.equations);
    if !is_coupled && defining_equations != state_vars.len() {
        let (extra_equations_for, missing_equations_for) =
            analyze_equation_mismatch(&model.equations, &state_vars);

        let mut details = serde_json::json!({
            "state_variables": state_vars,
            "equations": defining_equations,
        });

        if !missing_equations_for.is_empty() {
            details["missing_equations_for"] = serde_json::json!(missing_equations_for);
        }
        if !extra_equations_for.is_empty() {
            details["extra_equations_for"] = serde_json::json!(extra_equations_for);
        }

        errors.push(StructuralError {
            path: model_path.clone(),
            code: StructuralErrorCode::EquationCountMismatch,
            message: format!(
                "Number of equations ({}) does not match number of unknowns ({})",
                defining_equations,
                state_vars.len()
            ),
            details,
        });
    }

    // Build a unit environment once per model — expression-level dimensional
    // propagation walks the Expr AST using this map. A variable with NO declared
    // units is simply absent from the env (dimension unknown, not
    // dimensionless), so expressions mentioning it are skipped rather than
    // checked against a fabricated dimension.
    //
    // A variable whose declared unit string denotes no real unit is a different
    // matter: it is a HARD `unit_parse_error` at the variable's own pointer
    // (esm-spec §4.8.4). Coercing it to dimensionless would fabricate a
    // dimension, and treating it as merely unknown would let a typo silently
    // switch off every dimensional check that depends on it.
    let (unit_env, unit_parse_failures) = build_unit_env(&model.variables);
    for failure in unit_parse_failures {
        errors.push(StructuralError {
            path: format!("{model_path}/variables/{}", failure.name),
            code: StructuralErrorCode::UnitParseError,
            message: format!("Unit string '{}' is not a recognised unit", failure.units),
            details: serde_json::json!({
                "variable": failure.name,
                "units": failure.units,
            }),
        });
    }

    // Reference integrity applies to EVERY expression-bearing block, not just
    // `equations`. `initialization_equations` (§6.2) are a separate block with a
    // separate balance — but they are still expressions over the model's
    // symbols, and nothing checked them, so an undefined name in an initial
    // condition was a silent FALSE NEGATIVE. (The sidecar fields *within* an
    // expression — `expr`, `filter`, `key`, `lower`/`upper`, `values`, `axes`,
    // `bindings` — are covered by the walker itself, which descends via
    // `ExpressionNode::for_each_child` rather than `args` alone.)
    for (eq_idx, equation) in model.initialization_equations.iter().flatten().enumerate() {
        let eq_path = format!("{model_path}/initialization_equations/{eq_idx}");
        // The pointer is the containing expression FIELD (§7.1.2) — `.../<eq>/lhs`
        // or `.../<eq>/rhs` — not the whole equation.
        for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
            check_refs(expr, &format!("{eq_path}/{field}"), eq_idx, errors);
        }
    }

    // `guesses` (§6.3) — an initial guess for a nonlinear solve is an Expression
    // over the model's symbols. Stored as raw JSON, so it is parsed here.
    for (var_name, guess) in model.guesses.iter().flatten() {
        let Ok(expr) = serde_json::from_value::<crate::Expr>(guess.clone()) else {
            continue; // not an expression (a bare number is fine)
        };
        check_refs(
            &expr,
            &format!("{model_path}/guesses/{var_name}"),
            0,
            errors,
        );
    }

    // `tests[].assertions[].reference` (§6.6) — an analytic reference solution is
    // an Expression over the model's symbols.
    for (t_idx, test) in model.tests.iter().flatten().enumerate() {
        for (a_idx, assertion) in test.assertions.iter().enumerate() {
            // Only the inline analytic-Expression form names symbols; a
            // `{type: "from_file"}` reference points at a snapshot.
            let Some(crate::types::AssertionReference::Expression(reference)) =
                &assertion.reference
            else {
                continue;
            };
            check_refs(
                reference,
                &format!("{model_path}/tests/{t_idx}/assertions/{a_idx}/reference"),
                0,
                errors,
            );
        }
    }

    // Check that all equation references are defined and validate dimensional consistency
    for (eq_idx, equation) in model.equations.iter().enumerate() {
        let eq_path = format!("{model_path}/equations/{eq_idx}");
        // Reference integrity attaches to the containing expression FIELD
        // (§7.1.2): an undefined name on the RHS is reported at
        // `.../equations/<i>/rhs`, not at the whole equation. (Dimensional
        // findings below stay at the equation level — an inconsistency is a
        // property of the equation, not of one side.)
        for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
            check_refs(expr, &format!("{eq_path}/{field}"), eq_idx, errors);
        }

        // Validate dimensional consistency of the equation via expression-level
        // propagation over the Expr AST. Every finding is reported: a provable
        // mismatch is a hard `unit_inconsistency` error, an undeterminable
        // dimension stays a non-blocking warning. See `record_unit_findings`.
        record_unit_findings(
            check_equation_dimensions(equation, &unit_env),
            &eq_path,
            &format!("Equation {eq_idx}"),
            errors,
            warnings,
        );
    }

    // Static `aggregate`-node constraints (RFC semiring-faq-unified-ir): an
    // undeclared `from` index set, a value-equality join over an unportable
    // (float/null) categorical key, and a value-invention `distinct` node that
    // reads a state variable (relational work on the continuous hot path). Each
    // is decidable from this one document, so it belongs in `validate()`.
    let state_var_set: HashSet<String> = state_vars.iter().cloned().collect();
    validate_aggregate_constraints(esm_file, model_name, model, &state_var_set, errors);

    // A `default_units` that names a unit OTHER than the declared `units` means
    // the `default` NUMBER is expressed in the wrong unit — `units: "K"` with
    // `default: 25.0, default_units: "degC"` stores 25 for a variable that
    // actually reads 298.15 (esm-spec §4.8; `tests/invalid/
    // units_parameter_default_mismatch.esm`).
    //
    // The comparison is on unit IDENTITY, not dimension: `K` and `degC` share a
    // dimension and (in a purely multiplicative model) a scale, differing only
    // by an affine OFFSET that `Unit` cannot represent — so a dimensional check
    // is structurally incapable of catching this, which is why every binding but
    // Python missed it. Matching Python, any difference is reported.
    for (var_name, variable) in &model.variables {
        let (Some(declared), Some(default_units)) =
            (variable.units.as_deref(), variable.default_units.as_deref())
        else {
            continue;
        };
        if declared.trim() == default_units.trim() {
            continue;
        }
        errors.push(StructuralError {
            path: format!("{model_path}/variables/{var_name}"),
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

    // Validate observed variable expressions
    for (var_name, variable) in &model.variables {
        if variable.var_type == crate::VariableType::Observed && variable.expression.is_none() {
            errors.push(StructuralError {
                path: format!("{model_path}/variables/{var_name}"),
                code: StructuralErrorCode::MissingObservedExpr,
                message: format!(
                    "Observed variable \"{var_name}\" is missing its expression field"
                ),
                details: serde_json::json!({
                    // The settled cross-binding key is `variable`
                    // (CONFORMANCE_SPEC row (j)), not `variable_name`.
                    "variable": var_name,
                    "field": "expression"
                }),
            });
        } else if variable.var_type == crate::VariableType::Observed {
            // If the expression exists, validate its variable references
            if let Some(ref expr) = variable.expression {
                let expr_path = format!("{model_path}/variables/{var_name}/expression");
                check_refs(expr, &expr_path, 0, errors);

                // Dimension-check the defining expression. This is where most
                // of the shared `units_*.esm` fixtures put their defect (an
                // observed variable whose expression adds `m` to `kg`, or takes
                // `ln` of a mass), and it went entirely unchecked while only
                // `equations` were propagated. The error path is the VARIABLE
                // — `/models/<M>/variables/<v>` — as pinned by
                // `tests/invalid/expected_errors.json`.
                let declared = variable.units.as_deref().and_then(|u| parse_unit(u).ok());
                record_unit_findings(
                    check_expression_dimensions(expr, declared.as_ref(), &unit_env),
                    &format!("{model_path}/variables/{var_name}"),
                    &format!("Observed variable \"{var_name}\""),
                    errors,
                    warnings,
                );

                if let Some(declared) = &declared {
                    check_linear_conversion_factor(
                        expr,
                        declared,
                        model,
                        &format!("{model_path}/variables/{var_name}"),
                        var_name,
                        errors,
                    );
                }
            }
        }
    }

    // Validate discrete events
    if let Some(ref discrete_events) = model.discrete_events {
        for (event_idx, event) in discrete_events.iter().enumerate() {
            validate_discrete_event(
                event,
                event_idx,
                &model_path,
                &defined_vars,
                &model.variables,
                errors,
            );
        }
    }

    check_physical_constant_units(model_name, model, errors);

    // Validate continuous events
    if let Some(ref continuous_events) = model.continuous_events {
        for (event_idx, event) in continuous_events.iter().enumerate() {
            validate_continuous_event(event, event_idx, &model_path, &defined_vars, errors);
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

/// Reference-check every data-loader variable's `unit_conversion` Expression
/// (esm-spec §8.5, §4.9.5).
///
/// A `unit_conversion` is applied to the value coming off disk and may name any
/// declared symbol in the document (a scale parameter typically lives in the
/// consuming model), so it resolves against the DOCUMENT-WIDE declared set
/// rather than the loader's own variables alone. Nothing checked this field at
/// all, so a typo'd conversion factor silently produced a wrongly-scaled input.
pub(crate) fn validate_data_loader_unit_conversions(
    esm_file: &EsmFile,
    system_refs: &HashMap<String, SystemInfo>,
    errors: &mut Vec<StructuralError>,
) {
    let Some(loaders) = &esm_file.data_loaders else {
        return;
    };

    // Every name declared anywhere in the document, plus the implicit symbols.
    let mut scope = implicitly_declared_symbols(esm_file);
    scope.extend(document_declared_names(esm_file));

    let empty = HashSet::new();
    for (loader_name, loader) in loaders {
        for (var_name, var) in &loader.variables {
            let Some(crate::types::UnitConversion::Expression(expr)) = &var.unit_conversion else {
                continue; // a bare multiplicative factor names nothing
            };
            validate_expression_references_with_systems(
                expr,
                &scope,
                system_refs,
                &empty,
                &format!("/data_loaders/{loader_name}/variables/{var_name}/unit_conversion"),
                0,
                errors,
            );
        }
    }
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
///    `affects`/`affect_neg`, a `functional_affect`'s `read_vars`).
/// Every name DECLARED anywhere in the document: each model's `variables`, each
/// reaction system's `species` and `parameters`, and each data loader's
/// `variables`. Does NOT include the implicit symbols (`t`, coordinates, index
/// sets, `_var`, callback-injected names) — combine with
/// `implicitly_declared_symbols` for the full document scope. Mirrors Julia
/// `_document_declared_names`, TS `documentDeclaredNames`, Go `documentWideScope`.
fn document_declared_names(esm_file: &EsmFile) -> HashSet<String> {
    let mut names = HashSet::new();
    for model in esm_file.models.iter().flatten().map(|(_, m)| m) {
        names.extend(model.variables.keys().cloned());
    }
    for rs in esm_file.reaction_systems.iter().flatten().map(|(_, r)| r) {
        names.extend(rs.species.keys().cloned());
        names.extend(rs.parameters.keys().cloned());
    }
    for loader in esm_file.data_loaders.iter().flatten().map(|(_, l)| l) {
        names.extend(loader.variables.keys().cloned());
    }
    names
}

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
                if let Some(expr) = &var.expression {
                    collect_coordinate_symbols(expr, &mut symbols);
                }
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
            if !name.contains('.') && !is_builtin_function(name) {
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
    for (eq_idx, equation) in model.equations.iter().enumerate() {
        for (field, expr) in [("lhs", &equation.lhs), ("rhs", &equation.rhs)] {
            let field_path = format!("{model_path}/equations/{eq_idx}/{field}");
            check_aggregates_in_expr(expr, &field_path, esm_file, state_vars, errors);
        }
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
    warnings: &mut Vec<String>,
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
            warnings.push(format!("{subject}: {} (in {path})", finding.message));
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
        let mut usage_site: Option<&str> = None;
        for (other_name, other_var) in &model.variables {
            if other_var.var_type != crate::VariableType::Observed {
                continue;
            }
            let Some(expr) = other_var.expression.as_ref() else {
                continue;
            };
            if expr_references_name(expr, constant_name) {
                usage_site = Some(other_name);
                break;
            }
        }
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

/// The full scoped references `<sub>.<var>` exposed by each DataLoader mounted as
/// a subsystem of `model` (RFC pure-io-data-loaders §4.3). `flatten` lowers each
/// to a const-array-backed observed `<model>.<sub>.<var>`, so the owning model's
/// own equations may reference it (`raw.k`, `index(raw.wind, …)`) even though
/// `raw` is not a top-level system. A nested MODEL subsystem is not a DataLoader
/// and contributes nothing. Empty for a model with no subsystems.
fn loader_subsystem_scoped_refs(model: &crate::Model) -> HashSet<String> {
    let mut refs = HashSet::new();
    let Some(subs) = &model.subsystems else {
        return refs;
    };
    for (sub_name, value) in subs {
        // ANY mounted subsystem exposes `<sub>.<var>` to the owning model — a
        // DataLoader (RFC pure-io-data-loaders §4.3) and equally a MODEL mounted
        // by `ref` (§4.7 subsystem inclusion, e.g. `Solar` from lib/solar.esm,
        // read as `Solar.solar_zenith_angle`). Matching only the DataLoader
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
            if var_name.starts_with("d(") || is_builtin_function(var_name) {
                return; // These are always valid
            }

            // A model-local scoped reference — a DataLoader mounted as a
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

/// Check if a variable name is a built-in function
fn is_builtin_function(name: &str) -> bool {
    matches!(
        name,
        "exp"
            | "log"
            | "log10"
            | "sqrt"
            | "abs"
            | "sign"
            | "sin"
            | "cos"
            | "tan"
            | "asin"
            | "acos"
            | "atan"
            | "atan2"
            | "sinh"
            | "cosh"
            | "tanh"
            | "asinh"
            | "acosh"
            | "atanh"
            | "min"
            | "max"
            | "floor"
            | "ceil"
            | "ifelse"
            | "Pre"
    )
}

fn validate_discrete_event(
    event: &crate::DiscreteEvent,
    event_idx: usize,
    parent_path: &str,
    defined_vars: &HashSet<String>,
    variables: &HashMap<String, crate::types::ModelVariable>,
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

    // Validate affects
    if let Some(ref affects) = event.affects {
        validate_event_affects(
            affects,
            defined_vars,
            &event_path,
            "affects",
            event_name,
            "discrete",
            errors,
        );
    }

    // `discrete_parameters` (§5.3): every entry must name a variable of type
    // `parameter` — not a state/observed variable and not an undeclared name.
    // The carrying field (§7.1.2) is the `discrete_parameters` array itself.
    if let Some(ref dps) = event.discrete_parameters {
        for dp in dps {
            let declared_type = variables.get(dp).map(|v| &v.var_type);
            if matches!(declared_type, Some(crate::VariableType::Parameter)) {
                continue;
            }
            let found = match declared_type {
                Some(crate::VariableType::State) => "found as state variable",
                Some(crate::VariableType::Observed) => "found as observed variable",
                Some(_) => "found as non-parameter variable",
                None => "not declared in model",
            };
            errors.push(StructuralError {
                path: format!("{event_path}/discrete_parameters"),
                code: StructuralErrorCode::InvalidDiscreteParam,
                message: format!(
                    "Discrete parameter '{dp}' in event is not declared as a parameter ({found})"
                ),
                details: serde_json::json!({
                    "parameter": dp,
                    "event_name": event_name,
                    "event_type": "discrete",
                    "expected_in": "parameters",
                }),
            });
        }
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
        defined_vars,
        &event_path,
        "affects",
        event_name,
        "continuous",
        errors,
    );
    if let Some(ref affect_neg) = event.affect_neg {
        validate_event_affects(
            affect_neg,
            defined_vars,
            &event_path,
            "affect_neg",
            event_name,
            "continuous",
            errors,
        );
    }
}

/// Shared affect-equation checks for discrete and continuous events: each
/// LHS must be a declared variable, and each RHS expression must reference
/// only declared names.
#[allow(clippy::too_many_arguments)]
fn validate_event_affects(
    affects: &[crate::AffectEquation],
    defined_vars: &HashSet<String>,
    event_path: &str,
    location: &str,
    event_name: &str,
    event_type: &str,
    errors: &mut Vec<StructuralError>,
) {
    for (affect_idx, affect) in affects.iter().enumerate() {
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
            if !is_builtin_function(var_name) && !defined_vars.contains(var_name) {
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
    models: &HashMap<String, crate::Model>,
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

        // Also check observed variable expressions
        for variable in model.variables.values() {
            if let Some(ref expr) = variable.expression {
                extract_model_dependencies(expr, &mut model_deps, model_name, models);
            }
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
    models: &HashMap<String, crate::Model>,
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
