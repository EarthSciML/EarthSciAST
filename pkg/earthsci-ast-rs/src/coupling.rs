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

/// Union of every system's declared variable/species/parameter names, plus a
/// sorted copy for embedding in diagnostics — error `details` must be
/// deterministic, so the HashSet is never serialized directly.
fn collect_available_vars(
    system_refs: &HashMap<String, SystemInfo>,
) -> (HashSet<String>, Vec<String>) {
    let mut available_vars = HashSet::new();
    for system_info in system_refs.values() {
        available_vars.extend(system_info.variables.iter().cloned());
        available_vars.extend(system_info.species.iter().cloned());
        available_vars.extend(system_info.parameters.iter().cloned());
    }
    let mut sorted: Vec<String> = available_vars.iter().cloned().collect();
    sorted.sort();
    (available_vars, sorted)
}

/// Flag every name in `vars` (an operator's `needed_vars` or `modifies` list)
/// that no system declares.
fn check_operator_vars(
    operator: &str,
    vars: &[String],
    field: &str,
    available: &HashSet<String>,
    available_sorted: &[String],
    coupling_path: &str,
    errors: &mut Vec<StructuralError>,
) {
    let verb = if field == "needed_vars" {
        "requires"
    } else {
        "modifies"
    };
    for var in vars {
        if !available.contains(var) {
            errors.push(StructuralError {
                path: format!("{coupling_path}.{field}"),
                code: StructuralErrorCode::OperatorVariableMissing,
                message: format!(
                    "Operator '{operator}' {verb} variable '{var}' which is not available"
                ),
                details: serde_json::json!({
                    "operator": operator,
                    "variable": var,
                    "field": field,
                    "available_variables": available_sorted,
                }),
            });
        }
    }
}

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
                    } else if let Some(op) = operators.get(operator) {
                        // Validate operator variables against the union of
                        // every system's declared names.
                        let (available_vars, available_sorted) =
                            collect_available_vars(system_refs);
                        check_operator_vars(
                            operator,
                            &op.needed_vars,
                            "needed_vars",
                            &available_vars,
                            &available_sorted,
                            &coupling_path,
                            errors,
                        );
                        if let Some(ref modifies) = op.modifies {
                            check_operator_vars(
                                operator,
                                modifies,
                                "modifies",
                                &available_vars,
                                &available_sorted,
                                &coupling_path,
                                errors,
                            );
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
                validate_pairwise_systems(
                    systems,
                    "Couple",
                    "couple",
                    &coupling_path,
                    system_refs,
                    errors,
                );
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
            // Exhaustive on purpose: a future CouplingEntry variant must
            // decide its validation story here rather than silently skipping.
            crate::CouplingEntry::Callback { .. } => {
                // Callback couplings reference platform handlers; nothing to
                // validate against the document's system tables.
            }
            crate::CouplingEntry::Event { .. } => {
                // Cross-system event affects are validated by the JSON-level
                // event checks in `parse` (mirroring Python).
            }
            crate::CouplingEntry::CouplingImport { .. } => {
                // A `coupling_import` is resolved and its bindings checked at
                // flatten (esm-spec §10.10.3 / §10.11), where the library `ref`
                // is loaded and every role→component bind is verified; the
                // structural validator has no library document to check against.
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
