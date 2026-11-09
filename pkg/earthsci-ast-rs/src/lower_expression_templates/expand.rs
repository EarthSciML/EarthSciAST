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
/// What [`expand`] does to a document with no template machinery (no
/// non-empty `expression_templates` block, no `apply_expression_template` op
/// anywhere): there is nothing to expand, so it only drops each component's
/// `expression_templates` key.
pub(crate) fn strip_component_template_blocks(value: &mut Value) {
    let Some(root) = value.as_object_mut() else {
        return;
    };
    for compkind in ["models", "reaction_systems"] {
        let Some(Value::Object(comps)) = root.get_mut(compkind) else {
            continue;
        };
        for (_, comp_value) in comps.iter_mut() {
            if let Value::Object(comp) = comp_value {
                comp.remove("expression_templates");
            }
        }
    }
}

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

/// The private JSON key on which a load marks the root of each template
/// expansion with its template's name ([`crate::types::ExpressionNode::template_origin`]).
/// Its value starts with [`template_origin_nonce`], so a key an author wrote
/// is never taken for one: the schema refuses it.
pub(crate) const TEMPLATE_ORIGIN_KEY: &str = "__esm_template_origin";

/// This process's prefix of every [`TEMPLATE_ORIGIN_KEY`] value.
fn template_origin_nonce() -> &'static str {
    static NONCE: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    NONCE.get_or_init(|| {
        use std::hash::BuildHasher;
        let n = std::collections::hash_map::RandomState::new().hash_one(std::process::id());
        format!("{n:016x}:")
    })
}

thread_local! {
    /// Whether the load in progress marks expansions (see [`MarkTemplateOrigins`]).
    static LOAD_MARKS: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Whether [`expand_all`] marks the expansions it makes right now.
    static MARKING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// How many marks this thread has placed, so a load can tell whether a
    /// mount it resolved placed any before the schema check.
    static MARKS_PLACED: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// While alive, [`expand`] marks the root of each expansion it makes in a
/// component with its template's name (esm-spec §9.6.11: the elementwise lift
/// applies only to an application, and this binding expands applications at
/// load). Held by the typed load around ref resolution and its own expansion;
/// the public expansion seams, whose output is a document, never mark.
pub(crate) struct MarkTemplateOrigins(bool);

impl MarkTemplateOrigins {
    pub(crate) fn on() -> Self {
        MarkTemplateOrigins(LOAD_MARKS.with(|f| f.replace(true)))
    }
}

impl Drop for MarkTemplateOrigins {
    fn drop(&mut self) {
        LOAD_MARKS.with(|f| f.set(self.0));
    }
}

/// How many template-origin marks this thread has placed so far.
pub(crate) fn template_origins_placed() -> u64 {
    MARKS_PLACED.with(std::cell::Cell::get)
}

/// `expansion` marked as the root of an expansion of `name`, when marking is
/// on and it is an object; otherwise unchanged.
pub(super) fn mark_template_origin(expansion: Sv, name: &str) -> Sv {
    if !MARKING.with(std::cell::Cell::get) {
        return expansion;
    }
    let SNode::Obj(fields) = &*expansion else {
        return expansion;
    };
    let mut out: Vec<(String, Sv)> = fields
        .iter()
        .filter(|(k, _)| k != TEMPLATE_ORIGIN_KEY)
        .cloned()
        .collect();
    out.push((
        TEMPLATE_ORIGIN_KEY.to_string(),
        Rc::new(SNode::Str(format!("{}{name}", template_origin_nonce()))),
    ));
    MARKS_PLACED.with(|c| c.set(c.get() + 1));
    Rc::new(SNode::Obj(out))
}

/// `value` with every template-origin mark this process placed removed: the
/// document as authored and expanded, for the schema check, which a mark (a
/// private key) would fail. A key an author wrote stays, and fails it.
pub(crate) fn strip_template_origins(value: &mut Value) {
    match value {
        Value::Object(map) => {
            if map
                .get(TEMPLATE_ORIGIN_KEY)
                .and_then(Value::as_str)
                .is_some_and(|s| s.starts_with(template_origin_nonce()))
            {
                map.remove(TEMPLATE_ORIGIN_KEY);
            }
            map.values_mut().for_each(strip_template_origins);
        }
        Value::Array(items) => items.iter_mut().for_each(strip_template_origins),
        _ => {}
    }
}

/// Serializes a component's raw `subsystems` map with the template-origin
/// marks taken off. The map is held as JSON, so the marks a load placed on a
/// mounted leaf's expansions stay in it for the build to read; they are load
/// provenance and never go on the wire (esm-spec §9.6.11).
pub(crate) fn serialize_subsystems_unmarked<S: serde::Serializer>(
    subsystems: &Option<indexmap::IndexMap<String, Value>>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    use serde::Serialize;
    match subsystems {
        Some(map) => {
            let mut map = map.clone();
            map.values_mut().for_each(strip_template_origins);
            map.serialize(serializer)
        }
        None => serializer.serialize_none(),
    }
}

/// Restores [`MARKING`] when dropped.
struct MarkingScope(bool);

impl MarkingScope {
    fn set(on: bool) -> Self {
        MarkingScope(MARKING.with(|f| f.replace(on)))
    }
}

impl Drop for MarkingScope {
    fn drop(&mut self) {
        MARKING.with(|f| f.set(self.0));
    }
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
                let Some(child) = comp.get_mut(&k) else {
                    continue;
                };
                let parked = park_plain(child, false);
                let shared = to_shared(child);
                let mut memo = PtrMemo::default();
                let _marking = MarkingScope::set(LOAD_MARKS.with(std::cell::Cell::get));
                let expanded = expand_all(&shared, &named, &format!("{scope}.{k}"), &mut memo);
                let expanded = match expanded {
                    Ok(x) => x,
                    Err(e) => {
                        if let Some(child) = comp.get_mut(&k) {
                            unpark_plain(child, parked);
                        }
                        return Err(e);
                    }
                };
                if !Rc::ptr_eq(&expanded, &shared) {
                    comp.insert(k.clone(), to_value(&expanded));
                }
                if let Some(child) = comp.get_mut(&k) {
                    unpark_plain(child, parked);
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
