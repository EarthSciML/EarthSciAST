use super::*;

// ===========================================================================
// `expand` — the public full-expansion function (esm-spec §9.6.4 rule 2)
// ===========================================================================

/// Fully expand every surviving `apply_expression_template` reference in a
/// document `value` loaded by [`lower_expression_templates`] (Option B),
/// producing the Option-A image: every reference replaced by its expansion
/// (pure substitution to the acyclic fixpoint, §9.6.4 rule 2) and every
/// per-component `expression_templates` block stripped. Deterministic — the DAG
/// is acyclic and substitution confluent, so `expand(load_string(f))` is structurally
/// equal to the pre-0.9.0 expanded form. Mutates `value` in place. Mirrors the
/// Julia reference `expand_document` / `Expand`.
/// Capture every component's `expression_templates` registry BEFORE
/// [`expand`] strips the blocks from the document.
///
/// Keyed `"models.<name>"` / `"reaction_systems.<name>"` in document order,
/// each value the component's registry object verbatim (post
/// `expression_template_imports` resolution). The typed `EsmFile` deliberately
/// never sees an `expression_templates` block — the build path is
/// Expand-at-build (RFC out-of-line-expression-templates §7.7) — so this is the
/// only place the per-component registries survive to reach
/// [`crate::flatten::merged_template_registry`], which needs them to build the
/// step-4 merged registry. Returns `None` when no component declares one, so a
/// document without templates costs nothing.
pub fn capture_component_templates(value: &Value) -> Option<indexmap::IndexMap<String, Value>> {
    let root = value.as_object()?;
    let mut out: indexmap::IndexMap<String, Value> = indexmap::IndexMap::new();
    for compkind in ["models", "reaction_systems"] {
        let Some(comps) = root.get(compkind).and_then(|v| v.as_object()) else {
            continue;
        };
        for (cname, comp) in comps {
            let Some(tpl) = comp.get("expression_templates") else {
                continue;
            };
            if !tpl.is_object() {
                continue;
            }
            out.insert(format!("{compkind}.{cname}"), tpl.clone());
        }
    }
    (!out.is_empty()).then_some(out)
}

pub fn expand(value: &mut Value) -> Result<(), ExpressionTemplateError> {
    let Some(root) = value.as_object_mut() else {
        return Ok(());
    };

    // Capture each component's named registry BEFORE stripping the blocks.
    let mut comp_named: std::collections::HashMap<(String, String), Named> =
        std::collections::HashMap::new();
    for compkind in ["models", "reaction_systems"] {
        if let Some(comps) = root.get(compkind).and_then(|v| v.as_object()) {
            for (cname, comp) in comps {
                let named = comp
                    .get("expression_templates")
                    .and_then(|v| v.as_object())
                    .map(build_named)
                    .unwrap_or_default();
                comp_named.insert((compkind.to_string(), cname.clone()), named);
            }
        }
    }

    for compkind in ["models", "reaction_systems"] {
        let Some(Value::Object(comps)) = root.get_mut(compkind) else {
            continue;
        };
        for (cname, comp_value) in comps.iter_mut() {
            let Value::Object(comp) = comp_value else {
                continue;
            };
            let named = comp_named
                .get(&(compkind.to_string(), cname.clone()))
                .cloned()
                .unwrap_or_default();
            let scope = format!("{compkind}.{cname}");
            let keys: Vec<String> = comp.keys().cloned().collect();
            for k in keys {
                if k == "expression_templates" || k == "expression_template_imports" {
                    continue;
                }
                let Some(child) = comp.get(&k) else { continue };
                let shared = to_shared(child);
                let mut memo = PtrMemo::default();
                let expanded = expand_all(&shared, &named, &format!("{scope}.{k}"), &mut memo)?;
                if !Rc::ptr_eq(&expanded, &shared) {
                    comp.insert(k, to_value(&expanded));
                }
            }
            comp.remove("expression_templates");
        }
    }

    if let Some(Value::Array(entries)) = root.get_mut("coupling") {
        for (idx, entry) in entries.iter_mut().enumerate() {
            let Some(obj) = entry.as_object_mut() else {
                continue;
            };
            if obj.get("type").and_then(|v| v.as_str()) != Some("variable_map") {
                continue;
            }
            let Some(transform) = obj.get("transform").filter(|t| t.is_object()).cloned() else {
                continue;
            };
            let Some(comp_name) = obj
                .get("to")
                .and_then(|v| v.as_str())
                .map(|t| t.split('.').next().unwrap_or("").to_string())
            else {
                continue;
            };
            let named = comp_named
                .get(&("models".to_string(), comp_name.clone()))
                .or_else(|| comp_named.get(&("reaction_systems".to_string(), comp_name.clone())));
            let Some(named) = named else { continue };
            let shared = to_shared(&transform);
            let mut memo = PtrMemo::default();
            let expanded = expand_all(
                &shared,
                named,
                &format!("coupling[{idx}].transform"),
                &mut memo,
            )?;
            if !Rc::ptr_eq(&expanded, &shared) {
                obj.insert("transform".to_string(), to_value(&expanded));
            }
        }
    }

    Ok(())
}
