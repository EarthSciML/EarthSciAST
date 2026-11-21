use super::*;

// ===========================================================================
// Reference-preserving emit (esm-spec §9.6.4 rule 5, §9.6.7)
// ===========================================================================

/// The transitive closure of the templates named by `refnames` (surviving-
/// reference names), following references inside materialized bodies, keeping
/// only MATCH-LESS entries (match rules are never materialized). Mirrors the
/// Julia reference `_ref_closure`.
fn ref_closure(
    refnames: &std::collections::BTreeSet<String>,
    named: &Named,
) -> std::collections::BTreeSet<String> {
    let mut out: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut stack: Vec<String> = refnames.iter().cloned().collect();
    while let Some(n) = stack.pop() {
        if out.contains(&n) {
            continue;
        }
        let Some(decl) = named.get(&n) else { continue };
        if decl_has_match(decl) {
            continue; // match rules not materialized
        }
        out.insert(n.clone());
        let body = decl_body(decl);
        let mut refs = Vec::new();
        collect_apply_names_sv(&body, &mut refs, &mut PtrSet::default());
        for r in refs {
            stack.push(r);
        }
    }
    out
}

/// Per-component template names authored in-file in `raw_source`
/// (compkind.cname → ordered names). Emit keeps these in authored position
/// (esm-spec §9.6.4 rule 5): a match-less entry always, a `match` rule only
/// when a firing referenced it (it is then materialized without `match`,
/// `where` and `priority`); imported/derived templates are materialized
/// instead. Mirrors `_authored_template_names`.
pub(crate) fn authored_template_names(
    raw_source: &Value,
) -> std::collections::HashMap<String, Vec<String>> {
    let mut authored: std::collections::HashMap<String, Vec<String>> =
        std::collections::HashMap::new();
    let Some(root) = raw_source.as_object() else {
        return authored;
    };
    for compkind in ["models", "reaction_systems"] {
        let Some(comps) = root.get(compkind).and_then(|v| v.as_object()) else {
            continue;
        };
        for (cname, comp) in comps {
            let Some(tpl) = comp.get("expression_templates").and_then(|v| v.as_object()) else {
                continue;
            };
            let mut names = Vec::new();
            for (n, d) in tpl {
                if d.is_object() {
                    names.push(n.clone());
                }
            }
            authored.insert(format!("{compkind}.{cname}"), names);
        }
    }
    authored
}

/// The template names referenced by the `variable_map` transforms each
/// component RECEIVES, keyed by component name (the first segment of `to`; the
/// first component of that name, models before reaction systems, as the
/// lowering pairs them). The transforms keep their references (esm-spec
/// §10.4); the receiving component owns them, so its emitted block
/// materializes their closure (§9.6.4 rule 5). Mirrors the Julia reference
/// `_received_transform_refs`.
pub(crate) fn received_transform_refs(
    root: &Map<String, Value>,
) -> std::collections::HashMap<String, Vec<String>> {
    let mut out: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
    let Some(Value::Array(entries)) = root.get("coupling") else {
        return out;
    };
    for entry in entries {
        let Some(obj) = entry.as_object() else {
            continue;
        };
        if obj.get("type").and_then(|v| v.as_str()) != Some("variable_map") {
            continue;
        }
        let Some(transform) = obj.get("transform").filter(|t| t.is_object()) else {
            continue;
        };
        let Some(comp_name) = obj
            .get("to")
            .and_then(|v| v.as_str())
            .map(|t| t.split('.').next().unwrap_or(""))
        else {
            continue;
        };
        collect_apply_names(transform, out.entry(comp_name.to_string()).or_default());
    }
    out
}

/// One component's `expression_templates` block as emit materializes it
/// (esm-spec §9.6.4 rule 5): the entries authored in-file (`authored_here`,
/// read off the source before resolution) first, in authored order — a `match`
/// rule only once rule 3 materialized it without its `match` — then the
/// transitive closure of the component's surviving references not authored
/// here, sorted by UTF-8 bytes. Also answers whether the component holds a
/// surviving reference and whether a non-authored entry was carried (the
/// §9.6.4 rule-8 stamp). Shared by [`emit_document`] and the typed load path's
/// registry capture, as the Julia reference `_materialize_components!` is.
/// `received` names the references of the coupling transforms the component
/// receives ([`received_transform_refs`]), which count as its own.
pub(crate) fn materialize_component_block(
    comp: &Map<String, Value>,
    authored_here: &[String],
    received: &[String],
) -> (Map<String, Value>, bool, bool) {
    let block = comp.get("expression_templates").and_then(|v| v.as_object());
    let named = block.map(build_named).unwrap_or_default();
    // Surviving-reference names across every non-template field.
    let mut refnames: std::collections::BTreeSet<String> = received.iter().cloned().collect();
    for (k, v) in comp.iter() {
        if k == "expression_templates" || k == "expression_template_imports" {
            continue;
        }
        let mut names = Vec::new();
        collect_apply_names(v, &mut names);
        refnames.extend(names);
    }
    let materialized = ref_closure(&refnames, &named);
    let authored_set: std::collections::HashSet<&str> =
        authored_here.iter().map(String::as_str).collect();
    let mut emit_block = Map::new();
    let mut carried = false;
    for n in authored_here {
        if let Some(decl) = block
            .and_then(|t| t.get(n))
            .filter(|d| d.get("match").is_none())
        {
            emit_block.insert(n.clone(), decl.clone());
        }
    }
    for n in &materialized {
        if authored_set.contains(n.as_str()) {
            continue;
        }
        if let Some(decl) = block.and_then(|t| t.get(n)) {
            emit_block.insert(n.clone(), decl.clone());
            carried = true;
        }
    }
    (emit_block, !refnames.is_empty(), carried)
}

/// Produce the reference-preserving, self-contained emitted document (esm-spec
/// §9.6.4 rule 5, RFC out-of-line-expression-templates §7.5) from a source
/// document `raw_source` (a fixture, or an already-emitted document for the
/// idempotency property). Resolves + loads `raw_source` under Option B, then for
/// every component builds its emitted `expression_templates` block — authored
/// match-less entries first in authored order, then the materialized transitive
/// closure of its surviving references (match-less), lexicographically sorted —
/// drops consumed `expression_template_imports`, and version-stamps `esm: 0.9.0`
/// when any surviving reference or materialized entry remains (rule 8). Mirrors
/// the Julia reference `emit_document`. `emit_esm_string ∘ emit_document` is a
/// byte-wise fixed point under reload.
///
/// A copy of `raw_source` runs the load passes an emit source takes
/// (`crate::parse::DocRole::EmitSource`): the wire boundary a load applies (a
/// removed op is refused, and a deprecated `neg` / `pow` is rewritten with the
/// `deprecated_op` warning, so neither spelling survives into the emitted
/// document, esm-spec §4.2), the §9.7 template machinery, and template
/// lowering.
pub fn emit_document(
    raw_source: &Value,
    base_path: &std::path::Path,
) -> Result<Value, ExpressionTemplateError> {
    let authored = authored_template_names(raw_source);
    let options = crate::parse::LoadOptions {
        base_path: Some(base_path.to_path_buf()),
        ..Default::default()
    };
    let mut source = crate::parse::Doc::new(
        raw_source.clone(),
        crate::parse::DocRole::EmitSource,
        &options,
    );
    source.run_passes().map_err(|e| match e {
        crate::parse::PassError::Schema(d) | crate::parse::PassError::Structural(d) => d,
        crate::parse::PassError::Esm(crate::EsmError::SchemaDiagnostic {
            code, message, ..
        }) => crate::diagnostic::err(code, message),
        crate::parse::PassError::Esm(other) => {
            crate::diagnostic::err(codes::REMOVED_OP, other.to_string())
        }
    })?;
    let mut loaded = source.value;
    let Some(root) = loaded.as_object_mut() else {
        return Ok(loaded);
    };
    let mut bump = false;
    let mut received = received_transform_refs(root);

    for compkind in ["models", "reaction_systems"] {
        let Some(Value::Object(comps)) = root.get_mut(compkind) else {
            continue;
        };
        for (cname, comp_value) in comps.iter_mut() {
            let Value::Object(comp) = comp_value else {
                continue;
            };
            let key = format!("{compkind}.{cname}");
            let authored_here = authored.get(&key).cloned().unwrap_or_default();
            let here = received.remove(cname.as_str()).unwrap_or_default();
            let (emit_block, refs, carried) =
                materialize_component_block(comp, &authored_here, &here);
            bump |= refs || carried;

            if emit_block.is_empty() {
                comp.remove("expression_templates");
            } else {
                comp.insert(
                    "expression_templates".to_string(),
                    Value::Object(emit_block),
                );
            }
            comp.remove("expression_template_imports");
        }
    }

    root.remove("expression_template_imports");
    if bump {
        // The §9.6.4 rule-8 emit stamp is a FLOOR, not an assignment: an emitted
        // document carrying a surviving reference or a materialized entry "MUST
        // declare `esm: 0.9.0` OR LATER". A document already at or above the
        // floor keeps its OWN declared version.
        //
        // This wrote `SCHEMA_VERSION` unconditionally, which is a different rule
        // that happened to agree while the current version WAS 1.0.0. At esm
        // 1.1.0 the two diverged and this binding started stamping 1.0.0
        // documents up to 1.1.0 on re-emit — five `emitted.esm` goldens stopped
        // matching byte-for-byte, and TypeScript and Julia (which apply the
        // floor) would have disagreed with it on every such document. Raising
        // the stamp is not harmless: it claims the document uses a format
        // version it does not, and needlessly puts it out of reach of a 1.0.x
        // reader.
        //
        // In practice the floor never fires: esm 1.0.0 is a clean break that
        // rejects every 0.x document at load, so anything reaching emit already
        // declares >= 1.0.0. It is written out anyway so the rule is stated
        // where it is applied rather than resting on that coincidence.
        const RULE8_FLOOR: (u32, u32, u32) = (0, 9, 0);
        let declared = root
            .get("esm")
            .and_then(|v| v.as_str())
            .and_then(crate::diagnostic::parse_semver);
        if declared.is_none_or(|d| d < RULE8_FLOOR) {
            root.insert("esm".to_string(), Value::String("0.9.0".to_string()));
        }
    }
    Ok(loaded)
}

// --- Canonical byte writer (2-space indent, keys sorted except the ordered
//     `expression_templates` block) — the cross-binding byte-identity surface. ---

/// Canonicalize a JSON number to the JSON3-read equivalent the goldens were
/// generated against: an integral, finite, `i64`-representable float is an
/// integer literal (JSON3 reads `0.0` as `0`); non-integral floats are kept.
fn canon_number(n: &serde_json::Number) -> serde_json::Number {
    if n.is_i64() || n.is_u64() {
        return n.clone();
    }
    match n.as_f64().and_then(crate::types::canonical_i64) {
        Some(i) => serde_json::Number::from(i),
        None => n.clone(),
    }
}

/// Write `value` canonically into `out` at nesting `indent`. Object keys are
/// emitted lexicographically (UTF-8 byte order) EXCEPT the direct entries of an
/// `expression_templates` object, which preserve their insertion order
/// (`preserve = true`). Mirrors the Julia reference `_emit_write`.
fn emit_write(out: &mut String, value: &Value, indent: usize, preserve: bool) {
    let pad = "  ".repeat(indent);
    let pad1 = "  ".repeat(indent + 1);
    match value {
        Value::Object(map) => {
            if map.is_empty() {
                out.push_str("{}");
                return;
            }
            let mut keys: Vec<&String> = map.keys().collect();
            if !preserve {
                keys.sort_unstable();
            }
            out.push_str("{\n");
            for (i, k) in keys.iter().enumerate() {
                out.push_str(&pad1);
                out.push_str(&serde_json::to_string(k).expect("string key"));
                out.push_str(": ");
                let child = map.get(k.as_str()).expect("key present");
                emit_write(out, child, indent + 1, k.as_str() == "expression_templates");
                if i + 1 < keys.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            out.push_str(&pad);
            out.push('}');
        }
        Value::Array(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push_str("[\n");
            for (i, v) in items.iter().enumerate() {
                out.push_str(&pad1);
                emit_write(out, v, indent + 1, false);
                if i + 1 < items.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            out.push_str(&pad);
            out.push(']');
        }
        Value::Number(n) => out.push_str(&canon_number(n).to_string()),
        _ => out.push_str(&serde_json::to_string(value).expect("scalar")),
    }
}

/// Canonical byte serialization of an emitted document (esm-spec §9.6.4 rule
/// 5): 2-space indent, object keys sorted lexicographically EXCEPT the entries
/// of an `expression_templates` object, which preserve their authored-first /
/// materialized-sorted order. Trailing newline. The cross-binding byte-identity
/// surface for the Option-B emitted form and the target of the `emitted.esm`
/// goldens. Mirrors the Julia reference `emit_esm_string`.
pub fn emit_esm_string(doc: &Value) -> String {
    let mut out = String::new();
    emit_write(&mut out, doc, 0, false);
    out.push('\n');
    out
}

// ===========================================================================
// Flatten: template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
// esm-libraries-spec §4.7.5)
// ===========================================================================

/// Rewrite the `name` of every `apply_expression_template` reference in `value`
/// according to `rename` (old name → new name), in lockstep with a registry
/// rename. Mirrors the Julia reference `_rename_apply_refs`.
pub(crate) fn rename_apply_refs(
    value: &mut Value,
    rename: &std::collections::HashMap<String, String>,
) {
    crate::json_visit::visit_values_mut(value, &mut |v| {
        let Some(map) = v.as_object_mut() else { return };
        if map.get("op").and_then(|w| w.as_str()) == Some(APPLY_OP)
            && let Some(Value::String(n)) = map.get("name")
            && let Some(newname) = rename.get(n)
        {
            let newname = newname.clone();
            map.insert("name".to_string(), Value::String(newname));
        }
    });
}

/// The set of template names the flatten-time registry merge MUST owner-path
/// rename (esm-spec §9.6.4 rule 7 / §10.7). `byname` maps a template name to its
/// per-component occurrences `[(path, decl), …]`.
///
/// A name collides directly when its occurrences are not all deep-equal. The set
/// is then closed under the reference DAG: **if a declaration references a
/// colliding name, that declaration collides too**, in every component carrying
/// it. That propagation is what makes the rename total.
///
/// Without it the common multi-model shape silently breaks. Two components
/// import one rule library; the leaf stencil folds differently per component (a
/// rebind, a metaparameter, or the §10.7 component-scoping of its free
/// variables) and renames to `A.leaf` / `B.leaf`, while the intermediate wrapper
/// that REFERENCES the leaf is byte-identical and would dedup under its bare
/// name. That single deduped body then carries a reference the registry no
/// longer holds, and expansion fails with
/// `apply_expression_template_unknown_template` naming a template no component
/// ever mentioned. Renaming the wrapper per owner lets each copy's nested
/// reference be rewritten to its own owner's leaf.
///
/// A consequence worth relying on: a name left OUT of the returned set never
/// references a name inside it, so deduped entries need no reference rewriting.
///
/// Mirrors the Julia reference `_registry_collision_names`.
pub(crate) fn registry_collision_names(
    byname: &[(String, Vec<(String, Value)>)],
) -> std::collections::HashSet<String> {
    let mut collide: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut refs: Vec<std::collections::HashSet<String>> = Vec::with_capacity(byname.len());
    for (name, occ) in byname {
        if !occ.iter().all(|o| o.1 == occ[0].1) {
            collide.insert(name.clone());
        }
        let mut seen = std::collections::HashSet::new();
        for (_path, decl) in occ {
            let mut names = Vec::new();
            collect_apply_names(decl, &mut names);
            seen.extend(names);
        }
        refs.push(seen);
    }
    // Close under the reference edges (monotone; <= byname.len() rounds).
    let mut changed = true;
    while changed {
        changed = false;
        for (i, (name, _)) in byname.iter().enumerate() {
            if collide.contains(name) {
                continue;
            }
            if refs[i].iter().any(|r| collide.contains(r)) {
                collide.insert(name.clone());
                changed = true;
            }
        }
    }
    collide
}

/// Per owner path, the registry renames (old name → new name) a
/// [`merge_flat_registry`] made.
pub(crate) type RegistryRenames =
    std::collections::HashMap<String, std::collections::HashMap<String, String>>;

/// Merge per-owner match-less registries `blocks` (`(owner path, block)`, in
/// document order) into one registry, by the rule flatten merges component
/// registries with (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5
/// step 4): entries in document order (owners as given, entries as each block
/// declares them); deep-equal same-name entries kept once, at first occurrence;
/// a colliding name ([`registry_collision_names`]: not deep-equal, or reaching
/// one that is) renamed in EVERY owner to `<owner path>.<name>`, with the
/// renamed bodies' own references following their owner's renames.
///
/// Returns the merged registry and each owner's renames, which the caller MUST
/// apply to that owner's reference sites. Shared by the flattened registry
/// ([`crate::flatten::merged_template_registry`]) and the mount hoist
/// ([`hoist_mounted_templates`]). Mirrors the Julia reference
/// `_merge_flat_registry`.
pub(crate) fn merge_flat_registry(
    blocks: &[(String, Map<String, Value>)],
) -> (Map<String, Value>, RegistryRenames) {
    let mut byname: Vec<(String, Vec<(String, Value)>)> = Vec::new();
    let mut slot: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for (path, block) in blocks {
        for (name, decl) in block {
            let i = *slot.entry(name.clone()).or_insert_with(|| {
                byname.push((name.clone(), Vec::new()));
                byname.len() - 1
            });
            byname[i].1.push((path.clone(), decl.clone()));
        }
    }
    let collide = registry_collision_names(&byname);
    let mut merged = Map::new();
    let mut rename = RegistryRenames::new();
    for (name, occ) in &byname {
        if collide.contains(name) {
            for (path, decl) in occ {
                let newname = format!("{path}.{name}");
                merged.insert(newname.clone(), decl.clone());
                rename
                    .entry(path.clone())
                    .or_default()
                    .insert(name.clone(), newname);
            }
        } else {
            merged.insert(name.clone(), occ[0].1.clone()); // deep-equal dedup
        }
    }
    // A renamed body's own nested references follow its OWNER's map, so a
    // per-owner wrapper reaches its owner's leaf and never the other owner's.
    for per_owner in rename.values() {
        for new in per_owner.values() {
            if let Some(decl) = merged.get_mut(new) {
                rename_apply_refs(decl, per_owner);
            }
        }
    }
    (merged, rename)
}

/// The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
/// esm-libraries-spec §4.7.5 step 4). Given an Option-B loaded multi-component
/// document `loaded`, merge every component's `expression_templates` registry
/// into a single document-scoped merged registry: deep-equal same-name entries
/// dedupe at first occurrence; a colliding name (see
/// [`registry_collision_names`] — non-deep-equal, or reaching one that is)
/// renames its entry in EVERY owning component to `<ComponentPath>.<name>` and
/// rewrites their references in lockstep. Returns the rewritten document
/// (component reference sites updated, per-component blocks dropped) and the
/// merged registry (order-preserving).
/// Mirrors the Julia reference `flatten_template_registries`.
pub fn flatten_template_registries(loaded: &Value) -> (Value, Map<String, Value>) {
    let mut root = loaded.clone();
    // (path, match-less named registry as owned Values), in model then
    // reaction-system, component-declaration order.
    let mut comps: Vec<(String, Map<String, Value>)> = Vec::new();
    if let Some(root_obj) = root.as_object() {
        for compkind in ["models", "reaction_systems"] {
            let Some(cs) = root_obj.get(compkind).and_then(|v| v.as_object()) else {
                continue;
            };
            for (cname, comp) in cs {
                let mut named = Map::new();
                if let Some(tpl) = comp.get("expression_templates").and_then(|v| v.as_object()) {
                    for (n, d) in tpl {
                        if d.as_object().is_some_and(|o| o.contains_key("match")) {
                            continue; // match rules not merged
                        }
                        named.insert(n.clone(), d.clone());
                    }
                }
                comps.push((cname.clone(), named));
            }
        }
    }

    // Group each template name across components (preserving first-seen path).
    let mut byname: Vec<(String, Vec<(String, Value)>)> = Vec::new();
    for (path, named) in &comps {
        let mut names: Vec<&String> = named.keys().collect();
        names.sort_unstable();
        for n in names {
            match byname.iter_mut().find(|(k, _)| k == n) {
                Some((_, occ)) => occ.push((path.clone(), named[n].clone())),
                None => byname.push((n.clone(), vec![(path.clone(), named[n].clone())])),
            }
        }
    }
    byname.sort_by(|a, b| a.0.cmp(&b.0));

    let mut merged: Map<String, Value> = Map::new();
    // path => (old => new)
    let mut rename: std::collections::HashMap<String, std::collections::HashMap<String, String>> =
        std::collections::HashMap::new();
    let collide = registry_collision_names(&byname);
    for (name, occ) in &byname {
        if collide.contains(name) {
            for (path, decl) in occ {
                let newname = format!("{path}.{name}");
                merged.insert(newname.clone(), decl.clone());
                rename
                    .entry(path.clone())
                    .or_default()
                    .insert(name.clone(), newname);
            }
        } else {
            merged.insert(name.clone(), occ[0].1.clone()); // deep-equal dedup
        }
    }

    // Rewrite reference sites in lockstep (component expression positions and
    // the carried bodies of the renamed entries), then drop per-component blocks.
    let paths: Vec<String> = comps.iter().map(|(p, _)| p.clone()).collect();
    if let Some(root_obj) = root.as_object_mut() {
        for compkind in ["models", "reaction_systems"] {
            let Some(Value::Object(cs)) = root_obj.get_mut(compkind) else {
                continue;
            };
            for (cname, comp_value) in cs.iter_mut() {
                let Value::Object(comp) = comp_value else {
                    continue;
                };
                if let Some(rn) = rename.get(cname) {
                    let keys: Vec<String> = comp.keys().cloned().collect();
                    for k in keys {
                        if k == "expression_templates" {
                            continue;
                        }
                        if let Some(v) = comp.get_mut(&k) {
                            rename_apply_refs(v, rn);
                        }
                    }
                }
                comp.remove("expression_templates");
            }
        }
    }
    // Rewrite nested references inside the renamed merged bodies.
    for path in &paths {
        if let Some(rn) = rename.get(path) {
            for new in rn.values() {
                if let Some(decl) = merged.get_mut(new) {
                    rename_apply_refs(decl, rn);
                }
            }
        }
    }

    (root, merged)
}
