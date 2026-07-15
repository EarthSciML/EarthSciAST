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
                // The carrying field (§7.1.2) is the `from` / `to` endpoint that
                // holds the unresolvable reference, not the whole coupling entry.
                validate_scoped_reference(
                    from,
                    system_refs,
                    &format!("{coupling_path}/from"),
                    "variable_map",
                    errors,
                );
                validate_scoped_reference(
                    to,
                    system_refs,
                    &format!("{coupling_path}/to"),
                    "variable_map",
                    errors,
                );
                // esm-spec §4.7.6: an `identity` variable_map asserts the two
                // ends are the SAME quantity, so declared, non-empty, DIFFERING
                // units on `from` vs `to` are a modeling error. This is the same
                // check `crate::flatten::check_variable_map_units` runs at
                // flatten time (raising `FlattenError::DomainUnitMismatch`),
                // mirrored into `validate()` as a static structural finding at
                // the coupling-entry pointer. `param_to_var` / `conversion_factor`
                // / expression transforms are exempt (the conversion is declared,
                // or the mapping does not imply unit equivalence at the site), and
                // a missing/empty unit on either side is the valid unchecked case.
                if transform.as_named() == Some("identity")
                    && let (Some(source_units), Some(target_units)) = (
                        crate::flatten::lookup_variable_units(esm_file, from),
                        crate::flatten::lookup_variable_units(esm_file, to),
                    )
                    && !source_units.is_empty()
                    && !target_units.is_empty()
                    && source_units != target_units
                {
                    errors.push(StructuralError {
                        path: coupling_path.clone(),
                        code: StructuralErrorCode::DomainUnitMismatch,
                        message: format!(
                            "variable_map({from} -> {to}, identity): declared units '{source_units}' and '{target_units}' differ; an identity map requires matching units"
                        ),
                        details: serde_json::json!({
                            "coupling_type": "variable_map",
                            "from": from,
                            "to": to,
                            "source_units": source_units,
                            "target_units": target_units,
                        }),
                    });
                }

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

                // The Expression form of a `transform` does real arithmetic over
                // scoped references, and nothing checked its symbols (§4.9.5).
                if let Some(node) = transform.as_expression() {
                    validate_coupling_expression(
                        &crate::Expr::Operator(node.clone()),
                        &HashSet::new(),
                        system_refs,
                        &format!("{coupling_path}/transform"),
                        "variable_map",
                        errors,
                    );
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
            crate::CouplingEntry::Couple {
                systems, connector, ..
            } => {
                validate_pairwise_systems(
                    systems,
                    "Couple",
                    "couple",
                    &coupling_path,
                    system_refs,
                    errors,
                );

                // A connector equation's `expression` is the arithmetic the
                // coupling performs; its symbols are scoped references and
                // nothing checked them (§4.9.5). `connector` is raw JSON, so the
                // expression is parsed out here.
                for (eq_idx, eq) in connector
                    .get("equations")
                    .and_then(|e| e.as_array())
                    .into_iter()
                    .flatten()
                    .enumerate()
                {
                    let Some(raw) = eq.get("expression") else {
                        continue;
                    };
                    let Ok(expr) = serde_json::from_value::<crate::Expr>(raw.clone()) else {
                        continue;
                    };
                    validate_coupling_expression(
                        &expr,
                        &HashSet::new(),
                        system_refs,
                        &format!("{coupling_path}/connector/equations/{eq_idx}/expression"),
                        "couple",
                        errors,
                    );
                }
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
    // The carrying field (§7.1.2) is the entry's `systems` array, not the whole
    // coupling entry.
    let systems_path = format!("{coupling_path}/systems");
    if systems.len() >= 2 {
        for system in systems.iter().take(2) {
            if !system_refs.contains_key(system) {
                errors.push(StructuralError {
                    path: systems_path.clone(),
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
            path: systems_path,
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

/// Reference-check every symbol in a coupling Expression (esm-spec §4.9.5).
///
/// Coupling expressions live in the FLATTENED coupled system's scope, so their
/// variable references are fully qualified §4.6 scoped references — an
/// unresolvable one is an `unresolved_scoped_ref`. Descends via
/// `for_each_child`, so a reference buried in a sidecar (an aggregate body, a
/// filter predicate) is reached too, and credits the index symbols a node BINDS.
///
/// Nothing walked these fields at all: a `variable_map` `transform` and a
/// connector equation's `expression` are the two places a coupling does real
/// arithmetic, and a typo in either silently produced a wrong coupled system.
fn validate_coupling_expression(
    expr: &crate::Expr,
    bound: &std::collections::HashSet<String>,
    system_refs: &HashMap<String, SystemInfo>,
    path: &str,
    coupling_type: &str,
    errors: &mut Vec<StructuralError>,
) {
    match expr {
        crate::Expr::Variable(name) => {
            // A bound index symbol is a loop position, not a reference.
            if bound.contains(name) {
                return;
            }
            // Only a SCOPED reference is resolvable here; a bare name in a
            // coupling expression names nothing in the flattened scope, and
            // `validate_scoped_reference` returns early on it rather than
            // inventing a diagnostic the corpus does not pin.
            validate_scoped_reference(name, system_refs, path, coupling_type, errors);
        }
        crate::Expr::Operator(node) => {
            let mut scope = bound.clone();
            if let Some(idx) = &node.output_idx {
                scope.extend(idx.iter().cloned());
            }
            if let Some(ranges) = &node.ranges {
                scope.extend(ranges.keys().cloned());
            }
            node.for_each_child(&mut |child| {
                validate_coupling_expression(
                    child,
                    &scope,
                    system_refs,
                    path,
                    coupling_type,
                    errors,
                );
            });
        }
        crate::Expr::Number(_) | crate::Expr::Integer(_) => {}
    }
}

fn validate_scoped_reference(
    reference: &str,
    system_refs: &HashMap<String, SystemInfo>,
    coupling_path: &str,
    coupling_type: &str,
    errors: &mut Vec<StructuralError>,
) {
    // A scoped reference is a dot path of ARBITRARY DEPTH (esm-spec §4.9.2):
    // `A.B.c` walks A → B and takes `c`. The NAME is the LAST segment and the
    // SYSTEM is everything before it — taking segment [0] as the system reports
    // `EarthSystem.Atmosphere.Chemistry.O3` against the top-level `EarthSystem`
    // rather than the subsystem two levels down. `build_system_reference_map`
    // registers each nested subsystem under its full dotted path, so the walk is
    // a single prefix lookup.
    let Some((system_name, var_name)) = reference.rsplit_once('.') else {
        return; // Not a scoped reference
    };

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
