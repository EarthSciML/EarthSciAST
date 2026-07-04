//! Validation for `coupling` entries: scoped references between systems and
//! operator-application well-formedness.
//!
//! Schema validation, the public `ValidationResult` types, and the top-level
//! orchestrator live in [`crate::validate`]; structural validation
//! (equation balance, models, reactions, events) lives in
//! [`crate::structural`].

use crate::EsmFile;
use crate::validate::{StructuralError, StructuralErrorCode, SystemInfo};
use std::collections::{HashMap, HashSet};

pub(crate) fn validate_coupling(
    coupling: &[crate::CouplingEntry],
    system_refs: &HashMap<String, SystemInfo>,
    esm_file: &EsmFile,
    errors: &mut Vec<StructuralError>,
) {
    for (idx, entry) in coupling.iter().enumerate() {
        let coupling_path = format!("/coupling/{idx}");

        match entry {
            crate::CouplingEntry::VariableMap {
                from,
                to,
                transform,
                factor,
                ..
            } => {
                validate_scoped_reference(
                    from,
                    system_refs,
                    &coupling_path,
                    "variable_map",
                    errors,
                );
                validate_scoped_reference(to, system_refs, &coupling_path, "variable_map", errors);
                // An expression transform spells its own arithmetic, so a
                // separate `factor` slot is a modeling error (esm-spec §10.4)
                // — rejected rather than silently ignored, mirroring the
                // schema's `allOf` guard and the Julia / Python
                // construction-time rejection.
                if factor.is_some() && transform.is_expression() {
                    errors.push(StructuralError {
                        path: coupling_path.clone(),
                        code: StructuralErrorCode::FactorWithExpressionTransform,
                        message: format!(
                            "variable_map({from} -> {to}): an expression `transform` takes no `factor` (fold the scaling into the expression)"
                        ),
                        details: serde_json::json!({
                            "coupling_type": "variable_map",
                            "from": from,
                            "to": to,
                            "factor": factor,
                        }),
                    });
                }
            }
            crate::CouplingEntry::OperatorApply { operator, .. } => {
                if let Some(ref operators) = esm_file.operators {
                    if !operators.contains_key(operator) {
                        errors.push(StructuralError {
                            path: coupling_path.clone(),
                            code: StructuralErrorCode::UndefinedOperator,
                            message: format!("Operator '{operator}' referenced in operator_apply coupling is not declared"),
                            details: serde_json::json!({
                                "operator": operator,
                                "coupling_type": "operator_apply",
                                "expected_in": "operators"
                            }),
                        });
                    } else {
                        // Validate operator variables
                        if let Some(op) = operators.get(operator) {
                            // Collect all available variables from all systems
                            let mut available_vars = HashSet::new();
                            for system_info in system_refs.values() {
                                available_vars.extend(system_info.variables.iter().cloned());
                                available_vars.extend(system_info.species.iter().cloned());
                                available_vars.extend(system_info.parameters.iter().cloned());
                            }

                            // Check needed_vars
                            for needed_var in &op.needed_vars {
                                if !available_vars.contains(needed_var) {
                                    errors.push(StructuralError {
                                        path: format!("{coupling_path}.needed_vars"),
                                        code: StructuralErrorCode::OperatorVariableMissing,
                                        message: format!("Operator '{operator}' requires variable '{needed_var}' which is not available"),
                                        details: serde_json::json!({
                                            "operator": operator,
                                            "variable": needed_var,
                                            "field": "needed_vars",
                                            "available_variables": available_vars.clone().into_iter().collect::<Vec<_>>()
                                        }),
                                    });
                                }
                            }

                            // Check modifies variables (if specified)
                            if let Some(ref modifies) = op.modifies {
                                for modified_var in modifies {
                                    if !available_vars.contains(modified_var) {
                                        errors.push(StructuralError {
                                            path: format!("{coupling_path}.modifies"),
                                            code: StructuralErrorCode::OperatorVariableMissing,
                                            message: format!("Operator '{operator}' modifies variable '{modified_var}' which is not available"),
                                            details: serde_json::json!({
                                                "operator": operator,
                                                "variable": modified_var,
                                                "field": "modifies",
                                                "available_variables": available_vars.clone().into_iter().collect::<Vec<_>>()
                                            }),
                                        });
                                    }
                                }
                            }
                        }
                    }
                } else {
                    errors.push(StructuralError {
                        path: coupling_path,
                        code: StructuralErrorCode::UndefinedOperator,
                        message: format!(
                            "Operator '{operator}' referenced but no operators are declared"
                        ),
                        details: serde_json::json!({
                            "operator": operator,
                            "coupling_type": "operator_apply",
                            "expected_in": "operators"
                        }),
                    });
                }
            }
            crate::CouplingEntry::Couple { systems, .. } => {
                validate_pairwise_systems(systems, "Couple", "couple", &coupling_path, system_refs, errors);
            }
            crate::CouplingEntry::OperatorCompose { systems, .. } => {
                validate_pairwise_systems(
                    systems,
                    "OperatorCompose",
                    "operator_compose",
                    &coupling_path,
                    system_refs,
                    errors,
                );
            }
            _ => {
                // Handle other coupling types as needed
            }
        }
    }
}

/// Validate a `couple` / `operator_compose` entry: the first two systems must
/// exist, and exactly 2 systems are required. `label` is the human-readable
/// coupling name in the arity error; `coupling_type` is the snake-case tag
/// echoed into the error details.
fn validate_pairwise_systems(
    systems: &[String],
    label: &str,
    coupling_type: &str,
    coupling_path: &str,
    system_refs: &HashMap<String, SystemInfo>,
    errors: &mut Vec<StructuralError>,
) {
    if systems.len() >= 2 {
        for system in systems.iter().take(2) {
            if !system_refs.contains_key(system) {
                errors.push(StructuralError {
                    path: coupling_path.to_string(),
                    code: StructuralErrorCode::UndefinedSystem,
                    message: format!("Coupling entry references nonexistent system '{system}'"),
                    details: serde_json::json!({
                        "system": system,
                        "coupling_type": coupling_type,
                        "expected_in": "models, reaction_systems, data_loaders, operators"
                    }),
                });
            }
        }
    } else {
        errors.push(StructuralError {
            path: coupling_path.to_string(),
            code: StructuralErrorCode::UndefinedSystem,
            message: format!("{label} coupling requires exactly 2 systems"),
            details: serde_json::json!({
                "coupling_type": coupling_type,
                "systems_count": systems.len(),
                "expected_count": 2
            }),
        });
    }
}

fn validate_scoped_reference(
    reference: &str,
    system_refs: &HashMap<String, SystemInfo>,
    coupling_path: &str,
    coupling_type: &str,
    errors: &mut Vec<StructuralError>,
) {
    let parts: Vec<&str> = reference.split('.').collect();
    if parts.len() < 2 {
        return; // Not a scoped reference
    }

    let system_name = parts[0];
    let var_name = parts[parts.len() - 1];

    // Check if system exists
    if let Some(system) = system_refs.get(system_name) {
        // Check if variable exists in the system
        let var_exists = system.variables.contains(var_name)
            || system.species.contains(var_name)
            || system.parameters.contains(var_name);

        if !var_exists {
            errors.push(StructuralError {
                path: coupling_path.to_string(),
                code: StructuralErrorCode::UnresolvedScopedRef,
                message: format!("Scoped reference '{reference}' cannot be resolved"),
                details: serde_json::json!({
                    "reference": reference,
                    "coupling_type": coupling_type,
                    "missing_component": var_name
                }),
            });
        }
    } else {
        errors.push(StructuralError {
            path: coupling_path.to_string(),
            code: StructuralErrorCode::UnresolvedScopedRef,
            message: format!("Scoped reference '{reference}' cannot be resolved"),
            details: serde_json::json!({
                "reference": reference,
                "coupling_type": coupling_type,
                "missing_component": system_name
            }),
        });
    }
}
