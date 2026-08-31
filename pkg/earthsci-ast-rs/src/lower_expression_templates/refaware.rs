use super::*;

// ---------------------------------------------------------------------------
// Reference-aware validation discharge (esm-spec §9.6.9, Option B)
// ---------------------------------------------------------------------------

/// esm-spec §9.6.9: `makearray_region_inverted` is discharged at registration
/// on the composed, metaparameter-folded template bodies — region bounds cannot
/// carry template params (they are metaparameter expressions, §9.7.6), so the
/// check is instantiation-independent. Every retained template body (match and
/// match-less) is validated directly. Mirrors the Julia reference
/// `_validate_makearray_regions_in_registries`.
pub(super) fn validate_makearray_regions_in_registries(
    registries: &std::collections::HashMap<String, CompRegistry>,
) -> Result<(), ExpressionTemplateError> {
    for reg in registries.values() {
        for (tname, decl) in &reg.named {
            let body = decl_body(decl);
            if matches!(&*body, SNode::Null) {
                continue;
            }
            validate_makearray_regions(
                &to_value(&body),
                &format!("expression_templates.{tname}/body"),
            )?;
        }
    }
    Ok(())
}

/// Which templates can produce a geometry-kernel node (`GEOMETRY_MANIFOLD_OPS`)
/// — directly in the body or transitively through a referenced template. Only
/// references to these need per-instantiation manifold validation (§9.6.9).
/// Mirrors the Julia reference `_template_manifold_bearing`.
fn template_manifold_bearing(named: &Named) -> std::collections::HashMap<String, bool> {
    fn direct(node: &Sv, seen: &mut PtrSet) -> bool {
        match &**node {
            SNode::Arr(items) => {
                if !seen.insert(node) {
                    return false;
                }
                items.iter().any(|c| direct(c, seen))
            }
            SNode::Obj(fields) => {
                if !seen.insert(node) {
                    return false;
                }
                if let Some(op) = obj_op(fields)
                    && GEOMETRY_MANIFOLD_OPS.contains(&op)
                {
                    return true;
                }
                fields.iter().any(|(_, v)| direct(v, seen))
            }
            _ => false,
        }
    }
    transitive_reachable(named, |body| direct(body, &mut PtrSet::default()))
}

/// esm-spec §9.6.9: `geometry_manifold_invalid` is discharged per-instantiation
/// (a `manifold` may be a template param). Direct geometry nodes in the
/// reference-preserving tree are checked as before; every surviving
/// `apply_expression_template` reference whose template can produce a geometry
/// kernel is additionally expanded ONCE and its expansion validated. Mirrors
/// the Julia reference `_validate_geometry_manifolds_refaware`.
pub(super) fn validate_geometry_manifolds_refaware(
    value: &Value,
    registries: &std::collections::HashMap<String, CompRegistry>,
) -> Result<(), ExpressionTemplateError> {
    // Direct nodes on the reference-preserving tree (skips template blocks and
    // does not see manifold params hidden behind references).
    validate_geometry_manifolds(value, "")?;
    let Some(root) = value.as_object() else {
        return Ok(());
    };
    for compkind in ["models", "reaction_systems"] {
        let Some(comps) = root.get(compkind).and_then(|v| v.as_object()) else {
            continue;
        };
        for (cname, comp) in comps {
            let Some(comp_obj) = comp.as_object() else {
                continue;
            };
            let Some(reg) = registries.get(cname) else {
                continue;
            };
            let manifold_bearing = template_manifold_bearing(&reg.named);
            if !manifold_bearing.values().any(|b| *b) {
                continue; // no geometry: nothing to check
            }
            let mut memo = PtrSet::default();
            for (k, v) in comp_obj {
                if k == "expression_templates" {
                    continue;
                }
                // An EQUATION whose LHS is a bare variable is the definition of
                // that unknown (esm-spec 6.3.1), so label the call site with the
                // NAME rather than the array index: from esm 1.0.0 that is
                // where an observed's expression lives, and a diagnostic naming
                // `equations/1/rhs` says less than one naming `area_bad`.
                if k == "equations"
                    && let Some(items) = v.as_array()
                {
                    for (i, eq) in items.iter().enumerate() {
                        let label = eq
                            .get("lhs")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                            .unwrap_or_else(|| i.to_string());
                        let shared = to_shared(eq);
                        validate_manifolds_in_refs(
                            &shared,
                            &reg.named,
                            &manifold_bearing,
                            &format!("{compkind}.{cname}.equations/{label}"),
                            &mut memo,
                        )?;
                    }
                    continue;
                }
                let shared = to_shared(v);
                validate_manifolds_in_refs(
                    &shared,
                    &reg.named,
                    &manifold_bearing,
                    &format!("{compkind}.{cname}.{k}"),
                    &mut memo,
                )?;
            }
        }
    }
    Ok(())
}

fn validate_manifolds_in_refs(
    node: &Sv,
    named: &Named,
    manifold_bearing: &std::collections::HashMap<String, bool>,
    path: &str,
    memo: &mut PtrSet,
) -> Result<(), ExpressionTemplateError> {
    match &**node {
        SNode::Arr(items) => {
            if !memo.insert(node) {
                return Ok(());
            }
            for (i, c) in items.iter().enumerate() {
                validate_manifolds_in_refs(
                    c,
                    named,
                    manifold_bearing,
                    &format!("{path}/{i}"),
                    memo,
                )?;
            }
        }
        SNode::Obj(fields) => {
            if !memo.insert(node) {
                return Ok(());
            }
            let name = if obj_op(fields) == Some(APPLY_OP) {
                match obj_get(fields, "name").map(|v| &**v) {
                    Some(SNode::Str(s)) => s.as_str(),
                    _ => "",
                }
            } else {
                ""
            };
            // Per-instantiation manifold check (§9.6.9): expand ONLY references
            // whose template can produce a geometry-kernel node.
            if !name.is_empty() && manifold_bearing.get(name).copied().unwrap_or(false) {
                let mut expand_memo = PtrMemo::default();
                if let Ok(expansion) = expand_all(node, named, path, &mut expand_memo) {
                    let ev = to_value(&expansion);
                    if let Err(e) = validate_geometry_manifolds(&ev, "") {
                        if e.code == codes::GEOMETRY_MANIFOLD_INVALID {
                            return Err(err(
                                codes::GEOMETRY_MANIFOLD_INVALID,
                                format!(
                                    "{path}: instantiation of template '{name}' — {} \
                                     (esm-spec §9.6.9; per-instantiation manifold check)",
                                    e.message
                                ),
                            ));
                        }
                        return Err(e);
                    }
                }
            }
            for (k, v) in fields {
                validate_manifolds_in_refs(
                    v,
                    named,
                    manifold_bearing,
                    &format!("{path}/{k}"),
                    memo,
                )?;
            }
        }
        _ => {}
    }
    Ok(())
}
