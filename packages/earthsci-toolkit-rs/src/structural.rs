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
use crate::units::{Unit, build_unit_env, parse_unit, validate_equation_dimensions_with_coords};
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

    // Check equation-unknown balance
    let ode_equations = count_ode_equations(&model.equations);
    if ode_equations != state_vars.len() {
        let (extra_equations_for, missing_equations_for) =
            analyze_equation_mismatch(&model.equations, &state_vars);

        let mut details = serde_json::json!({
            "state_variables": state_vars,
            "ode_equations": ode_equations
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
                "Number of ODE equations ({}) does not match number of state variables ({})",
                ode_equations,
                state_vars.len()
            ),
            details,
        });
    }

    // Build a unit environment once per model — expression-level
    // dimensional propagation walks the Expr AST using this map.
    let unit_env = build_unit_env(&model.variables);

    // Build the coordinate-units map for the model's referenced domain, if
    // any. Used by `grad`/`div`/`laplacian` propagation to divide by the
    // declared coordinate units rather than a hardcoded metre denominator
    // (gt-ui96). Coordinates declared without units are stored as
    // dimensionless so the downstream propagator falls back to metres;
    // `validate_model_gradient_units` separately emits the
    // `unit_inconsistency` structural error for that case.
    let coord_env = build_coordinate_unit_env(esm_file, model);
    let coord_env_ref = coord_env.as_ref();

    // Check that all equation references are defined and validate dimensional consistency
    for (eq_idx, equation) in model.equations.iter().enumerate() {
        let eq_path = format!("{model_path}/equations/{eq_idx}");
        for expr in [&equation.lhs, &equation.rhs] {
            validate_expression_references_with_systems(
                expr,
                &defined_vars,
                system_refs,
                &eq_path,
                eq_idx,
                errors,
            );
        }

        // Validate dimensional consistency of equation via expression-level
        // propagation over the Expr AST.
        if let Err(unit_error) =
            validate_equation_dimensions_with_coords(equation, &unit_env, coord_env_ref)
        {
            warnings.push(format!("Equation {eq_idx}: {unit_error} (in {eq_path})"));
        }
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
                    "variable_name": var_name,
                    "field": "expression"
                }),
            });
        } else if variable.var_type == crate::VariableType::Observed {
            // If the expression exists, validate its variable references
            if let Some(ref expr) = variable.expression {
                let expr_path = format!("{model_path}/variables/{var_name}/expression");
                validate_expression_references_with_systems(
                    expr,
                    &defined_vars,
                    system_refs,
                    &expr_path,
                    0,
                    errors,
                );
            }
        }
    }

    // Validate discrete events
    if let Some(ref discrete_events) = model.discrete_events {
        for (event_idx, event) in discrete_events.iter().enumerate() {
            validate_discrete_event(event, event_idx, &model_path, &defined_vars, errors);
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
        errors.push(StructuralError {
            path: format!("/models/{model_name}/variables/{target}"),
            code: StructuralErrorCode::UnitInconsistency,
            message: "Physical constant used with incorrect dimensional analysis".to_string(),
            details: serde_json::json!({
                "constant_name": constant_name,
                "constant_description": description,
                "declared_units": declared,
                "canonical_units": canonical,
            }),
        });
    }
}

/// Build a map of spatial-coordinate name → parsed [`Unit`] for use by
/// `Unit::propagate_with_coords` in grad/div/laplacian propagation. A
/// coordinate declared without `units` (or whose `units` string fails to
/// parse) is stored as dimensionless — the propagator then falls back to
/// the legacy metre denominator so downstream comparisons remain
/// conservative. Returns `None` when there is no resolvable spatial table.
fn build_coordinate_unit_env(
    esm_file: &EsmFile,
    model: &crate::Model,
) -> Option<HashMap<String, Unit>> {
    let coords = collect_coordinate_units(esm_file, model)?;
    let mut env = HashMap::new();
    for (dim_name, units) in coords {
        let unit = units
            .as_deref()
            .and_then(|s| parse_unit(s).ok())
            .unwrap_or_else(Unit::dimensionless);
        env.insert(dim_name, unit);
    }
    Some(env)
}

/// Build a map of spatial-coordinate names → declared units string for the
/// model's referenced domain.
///
/// As of ESM v0.8.0 the bespoke `Domain.spatial` coordinate table was removed
/// (grid geometry is now ordinary data / `aggregate` FAQs), so there is no
/// per-coordinate units table to collect. This always returns `None`, leaving
/// grad/div/laplacian unit propagation on the legacy metre-denominator fallback
/// in `units.rs` — matching the other bindings' behaviour when no spatial
/// coordinate units are declared.
fn collect_coordinate_units(
    _esm_file: &EsmFile,
    _model: &crate::Model,
) -> Option<HashMap<String, Option<String>>> {
    None
}

/// Walk equation expressions looking for `grad`/`div`/`laplacian` nodes whose
/// `dim` names a coordinate that the enclosing model's domain declares without
/// units. When found, emit a structured `unit_inconsistency` error mirroring
/// the TypeScript binding (see `packages/earthsci-toolkit/src/units.ts`) and
/// the Julia binding (`validate.jl::_check_gradient_ops`, gt-sosg).
///
/// Coordinates present in `domain.spatial` but absent from this lookup, and
/// models without a resolvable domain, are left to the legacy metre-denominator
/// fallback in `units.rs` — matching other bindings' silent behaviour in those
/// cases.
pub(crate) fn validate_model_gradient_units(
    esm_file: &EsmFile,
    model_name: &str,
    model: &crate::Model,
    errors: &mut Vec<StructuralError>,
) {
    let Some(coords) = collect_coordinate_units(esm_file, model) else {
        return;
    };
    for (eq_idx, equation) in model.equations.iter().enumerate() {
        let eq_path = format!("/models/{model_name}/equations/{eq_idx}");
        check_gradient_ops(&equation.lhs, &coords, model, &eq_path, eq_idx, errors);
        check_gradient_ops(&equation.rhs, &coords, model, &eq_path, eq_idx, errors);
    }
}

fn check_gradient_ops(
    expr: &crate::Expr,
    coords: &HashMap<String, Option<String>>,
    model: &crate::Model,
    eq_path: &str,
    eq_index: usize,
    errors: &mut Vec<StructuralError>,
) {
    let crate::Expr::Operator(node) = expr else {
        return;
    };
    if matches!(node.op.as_str(), "grad" | "div" | "laplacian")
        && let Some(dim_name) = node.dim.as_deref()
        && let Some(entry) = coords.get(dim_name)
        && entry.is_none()
    {
        // Coordinate declared in the domain but without units — we cannot
        // infer the result's dimension, so flag it rather than silently
        // assuming metres.
        let (variable, variable_units) = match node.args.first() {
            Some(crate::Expr::Variable(v)) => (
                Some(v.clone()),
                model.variables.get(v).and_then(|mv| mv.units.clone()),
            ),
            _ => (None, None),
        };
        let mut details = serde_json::json!({
            "operator": node.op,
            "dim": dim_name,
            "coordinate_units": serde_json::Value::Null,
            "equation_index": eq_index,
        });
        if let Some(v) = variable {
            details["variable"] = serde_json::Value::String(v);
        }
        if let Some(u) = variable_units {
            details["variable_units"] = serde_json::Value::String(u);
        }
        errors.push(StructuralError {
            path: eq_path.to_string(),
            code: StructuralErrorCode::UnitInconsistency,
            message: "Gradient operator applied to variable with incompatible spatial units"
                .to_string(),
            details,
        });
    }
    node.for_each_child(&mut |child| {
        check_gradient_ops(child, coords, model, eq_path, eq_index, errors)
    });
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

fn count_ode_equations(equations: &[crate::Equation]) -> usize {
    equations.iter().filter(|eq| {
        // Check if LHS is a time derivative (D operation with wrt="t")
        matches!(&eq.lhs, crate::Expr::Operator(op) if op.op == "D" && op.wrt.as_deref() == Some("t"))
    }).count()
}

fn analyze_equation_mismatch(
    equations: &[crate::Equation],
    state_vars: &[String],
) -> (Vec<String>, Vec<String>) {
    let mut lhs_vars = HashSet::new();

    // Extract variables from LHS of ODE equations
    for equation in equations {
        if let crate::Expr::Operator(op) = &equation.lhs
            && op.op == "D"
            && op.wrt.as_deref() == Some("t")
            && let Some(crate::Expr::Variable(var_name)) = op.args.first()
        {
            lhs_vars.insert(var_name.clone());
        }
    }

    let state_vars_set: HashSet<_> = state_vars.iter().cloned().collect();

    let extra_equations_for: Vec<_> = lhs_vars.difference(&state_vars_set).cloned().collect();
    let missing_equations_for: Vec<_> = state_vars_set.difference(&lhs_vars).cloned().collect();

    (extra_equations_for, missing_equations_for)
}

pub(crate) fn validate_reaction_system(
    rs_name: &str,
    rs: &crate::ReactionSystem,
    _system_refs: &HashMap<String, SystemInfo>,
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

        // Check substrate references
        for substrate in reaction.substrates.iter().flatten() {
            if !defined_species.contains(&substrate.species) {
                errors.push(StructuralError {
                    path: rxn_path.clone(),
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

        // Check product references
        for product in reaction.products.iter().flatten() {
            if !defined_species.contains(&product.species) {
                errors.push(StructuralError {
                    path: rxn_path.clone(),
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

        // Validate rate expression references
        validate_rate_expression(
            &reaction.rate,
            &defined_parameters,
            &rxn_path,
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
    let mut env: HashMap<String, Unit> = HashMap::new();
    for (name, species) in &rs.species {
        let unit = match &species.units {
            Some(s) => match parse_unit(s) {
                Ok(u) => u,
                Err(_) => continue,
            },
            None => continue,
        };
        env.insert(name.clone(), unit);
    }
    for (name, param) in &rs.parameters {
        let unit = match &param.units {
            Some(s) => match parse_unit(s) {
                Ok(u) => u,
                Err(_) => continue,
            },
            None => continue,
        };
        env.insert(name.clone(), unit);
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

        let expected_rate_unit = conc_unit.power(1 - total_order as i32).divide(&time);
        if !rate_unit.is_compatible(&expected_rate_unit) {
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

fn validate_rate_expression(
    rate: &crate::Expr,
    defined_parameters: &HashSet<String>,
    reaction_path: &str,
    reaction_id: &str,
    errors: &mut Vec<StructuralError>,
) {
    match rate {
        crate::Expr::Variable(var_name) => {
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
            for arg in &op_node.args {
                validate_rate_expression(
                    arg,
                    defined_parameters,
                    reaction_path,
                    reaction_id,
                    errors,
                );
            }
        }
        crate::Expr::Number(_) | crate::Expr::Integer(_) => {
            // Numbers are always valid
        }
    }
}

pub(crate) fn validate_expression_references_with_systems(
    expr: &crate::Expr,
    defined_vars: &HashSet<String>,
    system_refs: &HashMap<String, SystemInfo>,
    base_path: &str,
    equation_index: usize,
    errors: &mut Vec<StructuralError>,
) {
    match expr {
        crate::Expr::Variable(var_name) => {
            // Skip derivatives, time variable, and built-in functions
            if var_name.starts_with("d(")
                || var_name.starts_with("t")
                || var_name == "t"
                || is_builtin_function(var_name)
            {
                return; // These are always valid
            }

            // Check for scoped references (e.g., "ModelA.x")
            if let Some(dot_pos) = var_name.find('.') {
                let system_name = &var_name[..dot_pos];
                let var_suffix = &var_name[dot_pos + 1..];

                // Validate scoped reference
                if let Some(system) = system_refs.get(system_name) {
                    let var_exists = system.variables.contains(var_suffix)
                        || system.species.contains(var_suffix)
                        || system.parameters.contains(var_suffix);

                    if !var_exists {
                        errors.push(StructuralError {
                            path: base_path.to_string(),
                            code: StructuralErrorCode::UnresolvedScopedRef,
                            message: format!("Scoped reference '{var_name}' cannot be resolved"),
                            details: serde_json::json!({
                                "reference": var_name,
                                "equation_index": equation_index,
                                "missing_component": var_suffix
                            }),
                        });
                    }
                    // If scoped reference is valid, don't generate undefined variable error
                } else {
                    errors.push(StructuralError {
                        path: base_path.to_string(),
                        code: StructuralErrorCode::UnresolvedScopedRef,
                        message: format!("Scoped reference '{var_name}' cannot be resolved"),
                        details: serde_json::json!({
                            "reference": var_name,
                            "equation_index": equation_index,
                            "missing_component": system_name
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
            // Recursively validate operands
            for arg in &op_node.args {
                validate_expression_references_with_systems(
                    arg,
                    defined_vars,
                    system_refs,
                    base_path,
                    equation_index,
                    errors,
                );
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
    errors: &mut Vec<StructuralError>,
) {
    let event_path = format!("{parent_path}/discrete_events/{event_idx}");

    // Validate trigger expression
    if let crate::DiscreteEventTrigger::Condition { expression } = &event.trigger {
        validate_event_expression(
            expression,
            defined_vars,
            &event_path,
            "condition",
            event.name.as_deref().unwrap_or("unnamed"),
            "discrete",
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
            event.name.as_deref().unwrap_or("unnamed"),
            "discrete",
            errors,
        );
    }

    // Note: discrete_parameters field validation would go here when DiscreteEvent type supports it
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

    for condition in &event.conditions {
        validate_event_expression(
            condition,
            defined_vars,
            &event_path,
            "condition",
            event_name,
            "continuous",
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
    for affect in affects {
        if !defined_vars.contains(&affect.lhs) {
            errors.push(StructuralError {
                path: event_path.to_string(),
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
        validate_event_expression(
            &affect.rhs,
            defined_vars,
            event_path,
            location,
            event_name,
            event_type,
            errors,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn validate_event_expression(
    expr: &crate::Expr,
    defined_vars: &HashSet<String>,
    event_path: &str,
    location: &str,
    event_name: &str,
    event_type: &str,
    errors: &mut Vec<StructuralError>,
) {
    match expr {
        crate::Expr::Variable(var_name) => {
            if !var_name.starts_with("t")
                && var_name != "t"
                && !is_builtin_function(var_name)
                && !defined_vars.contains(var_name)
            {
                errors.push(StructuralError {
                    path: event_path.to_string(),
                    code: StructuralErrorCode::EventVarUndeclared,
                    message: format!("Variable '{var_name}' in event {location} is not declared"),
                    details: serde_json::json!({
                        "variable": var_name,
                        "event_name": event_name,
                        "event_type": event_type,
                        "location": location,
                        "expected_in": "variables"
                    }),
                });
            }
        }
        crate::Expr::Operator(op_node) => {
            op_node.for_each_child(&mut |arg| {
                validate_event_expression(
                    arg,
                    defined_vars,
                    event_path,
                    location,
                    event_name,
                    event_type,
                    errors,
                )
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
            extract_model_dependencies(&equation.rhs, &mut model_deps);

            // Check LHS for scoped references (though less common)
            extract_model_dependencies(&equation.lhs, &mut model_deps);
        }

        // Also check observed variable expressions
        for variable in model.variables.values() {
            if let Some(ref expr) = variable.expression {
                extract_model_dependencies(expr, &mut model_deps);
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
fn extract_model_dependencies(expr: &crate::Expr, deps: &mut HashSet<String>) {
    match expr {
        crate::Expr::Variable(var_name) => {
            // Check if it's a scoped reference (e.g., "ModelA.x")
            if let Some(dot_pos) = var_name.find('.') {
                let model_name = &var_name[..dot_pos];
                deps.insert(model_name.to_string());
            }
        }
        crate::Expr::Operator(op_node) => {
            for arg in &op_node.args {
                extract_model_dependencies(arg, deps);
            }
        }
        crate::Expr::Number(_) | crate::Expr::Integer(_) => {
            // Numbers don't reference models
        }
    }
}

/// Check for cycles using depth-first search
fn has_cycle_dfs(
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

/// Find the actual cycle path for error reporting
fn find_cycle(graph: &HashMap<String, HashSet<String>>, start: &str) -> Vec<String> {
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
    if path.contains(&current.to_string()) {
        // Found cycle - include the current node to complete the cycle
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
