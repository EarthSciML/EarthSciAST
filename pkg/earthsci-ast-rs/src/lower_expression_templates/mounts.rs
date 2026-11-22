use super::*;

use std::collections::HashMap;

// ===========================================================================
// Template definitions across a §4.7 mount edge (esm-spec §9.6.4 rule 1)
// ===========================================================================
//
// A mounted leaf keeps its references: it is lowered in its own file, and
// each of its components keeps the match-less template definitions its
// references read ([`mounted_registries`]). At a top-level mount that block is
// the mounted component's registry; at a subsystem mount the mounting
// component's lowering merges it into its own registry
// ([`hoist_mounted_templates`]) by flatten's registry-merge rule
// ([`merge_flat_registry`]). Nothing here expands a reference.

/// The lowered leaf `doc` with each component's `expression_templates` block
/// kept for the mounting document: its match-less entries only (the `match`
/// rules have fired in the leaf, and a rule a firing referenced is
/// materialized match-less), and none on a component no reference reads.
/// Mirrors the Julia reference `_mounted_registries!`.
pub(crate) fn mounted_registries(doc: &mut Value) {
    let Some(root) = doc.as_object_mut() else {
        return;
    };
    for compkind in ["models", "reaction_systems"] {
        let Some(Value::Object(comps)) = root.get_mut(compkind) else {
            continue;
        };
        for comp in comps.values_mut() {
            let Value::Object(comp) = comp else {
                continue;
            };
            let Some(Value::Object(block)) = comp.get("operators") else {
                continue;
            };
            let keep: Map<String, Value> = block
                .iter()
                .filter(|(_, d)| d.get("match").is_none())
                .map(|(n, d)| (n.clone(), d.clone()))
                .collect();
            let used = comp
                .iter()
                .any(|(k, v)| k != "operators" && has_apply_op(v));
            if keep.is_empty() || !used {
                comp.shift_remove("operators");
            } else {
                comp.insert("operators".to_string(), Value::Object(keep));
            }
        }
    }
}

/// Whether `v` holds an `apply_expression_template` op anywhere.
fn has_apply_op(v: &Value) -> bool {
    let mut names = Vec::new();
    collect_apply_names(v, &mut names);
    !names.is_empty()
}

/// The subsystems below `node` that carry a template block — a mount point,
/// or an authored subsystem with its own block — as key paths. The walk stops
/// at such a subsystem: its own subtree's blocks were merged into it when its
/// file was lowered. Mirrors the Julia reference `_collect_mounted_blocks!`.
fn collect_mounted_blocks(
    node: &Map<String, Value>,
    prefix: &[String],
    out: &mut Vec<Vec<String>>,
) {
    let Some(Value::Object(subs)) = node.get("subsystems") else {
        return;
    };
    for (k, sub) in subs {
        let Value::Object(sub) = sub else {
            continue;
        };
        let mut path = prefix.to_vec();
        path.push(k.clone());
        if sub.get("operators").is_some_and(Value::is_object) {
            out.push(path);
        } else {
            collect_mounted_blocks(sub, &path, out);
        }
    }
}

/// The subsystem of `comp` at the key path `path`.
fn subsystem_at_mut<'a>(
    comp: &'a mut Map<String, Value>,
    path: &[String],
) -> Option<&'a mut Map<String, Value>> {
    let mut node = comp;
    for k in path {
        node = node
            .get_mut("subsystems")?
            .as_object_mut()?
            .get_mut(k)?
            .as_object_mut()?;
    }
    Some(node)
}

/// `node`'s subsystems with the references outside every mount point renamed
/// by `rn`. Mirrors the Julia reference `_rename_outside_mounts!`.
fn rename_outside_mounts(node: &mut Map<String, Value>, rn: &HashMap<String, String>) {
    let Some(Value::Object(subs)) = node.get_mut("subsystems") else {
        return;
    };
    for sub in subs.values_mut() {
        let Value::Object(sub) = sub else {
            continue;
        };
        if sub.get("operators").is_some_and(Value::is_object) {
            continue;
        }
        for (k, v) in sub.iter_mut() {
            if k != "subsystems" {
                rename_apply_refs(v, rn);
            }
        }
        rename_outside_mounts(sub, rn);
    }
}

/// `decl` carrying its `defines`, inferred under `name` when absent (esm-spec
/// §9.6.12). Mirrors the Julia reference `_with_defines`.
pub(crate) fn with_defines(name: &str, decl: &Value) -> Value {
    match decl {
        Value::Object(obj) if !obj.contains_key("defines") => {
            let mut nd = obj.clone();
            nd.insert(
                "defines".to_string(),
                Value::String(definition_defines(name, decl)),
            );
            Value::Object(nd)
        }
        _ => decl.clone(),
    }
}

/// Per merged registry entry, the owner paths that carry it: `""` for the
/// mounting component itself, `Sub` or `Sub.Inner` for a subsystem below it.
/// An entry with no record (no subsystem block was merged) is the
/// component's own.
pub(crate) type Owners = HashMap<String, Vec<String>>;

/// Merge into the component `comp`'s `operators` block the template
/// definitions that models mounted as its subsystems (esm-spec §4.7) brought
/// with them (esm-spec §9.6.4 rule 1). Each mounted block joins `comp`'s by
/// flatten's registry-merge rule ([`merge_flat_registry`]): deep-equal entries
/// are kept once, and a name two non-equal entries share is renamed to
/// `<owner path>.<name>`, one entry per distinct definition (named after its
/// first owner), with each owner's references renamed in lockstep. The owner
/// path of `comp`'s own entries is `cname`, of a mounted block its subsystem
/// path below `comp` (`Sub` or `Sub.Inner`).
///
/// A mounted body keeps the mounted model's own names: its free names are read
/// in the scope of the subsystem that owns the reference, as an authored
/// body's are at its call site, so a leaf mounted twice brings two identical
/// blocks, which keep one definition. The mounted subtree keeps naming its own
/// entries (under its renames); only `comp`'s other sites follow `comp`'s
/// renames. `comp`'s `match` rules stay, ahead of the merged entries. Mirrors
/// the Julia reference `_hoist_mounted_templates!`.
///
/// Returns the owners of each merged match-less entry ([`Owners`]). A
/// definition a subsystem brought is local to that subsystem (esm-spec §4.7,
/// §9.6.12): it resolves a call, and counts for an arity, only at a position
/// inside that subsystem; references reach it from anywhere.
pub(crate) fn hoist_mounted_templates(comp: &mut Map<String, Value>, cname: &str) -> Owners {
    let mut mounts: Vec<Vec<String>> = Vec::new();
    collect_mounted_blocks(comp, &[], &mut mounts);
    if mounts.is_empty() {
        return Owners::new();
    }
    let own: Map<String, Value> = comp
        .get("operators")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    // Each entry records the defined operator it defines under the key it was
    // declared with, before a collision rename (esm-spec §9.6.12
    // "Provenance").
    let mut blocks: Vec<(String, Map<String, Value>)> = vec![(
        cname.to_string(),
        own.iter()
            .filter(|(_, d)| d.get("match").is_none())
            .map(|(n, d)| (n.clone(), with_defines(n, d)))
            .collect(),
    )];
    for path in &mounts {
        let p = path.join(".");
        let sub = subsystem_at_mut(comp, path).expect("collected mount point");
        let block: Map<String, Value> = sub
            .get("operators")
            .and_then(Value::as_object)
            .map(|b| {
                b.iter()
                    .filter(|(_, d)| d.get("match").is_none())
                    .map(|(n, d)| (n.clone(), with_defines(n, d)))
                    .collect()
            })
            .unwrap_or_default();
        blocks.push((p, block));
    }
    let (merged, rename) = merge_flat_registry(&blocks);
    // The owners of each merged entry, under its merged name: `""` for
    // `comp` itself, the subsystem path below `comp` for a mounted block.
    let mut owners = Owners::new();
    for (path, block) in &blocks {
        let rm = rename.get(path);
        let owner = if path == cname { "" } else { path.as_str() };
        for n in block.keys() {
            let key = rm.and_then(|m| m.get(n)).unwrap_or(n);
            let os = owners.entry(key.clone()).or_default();
            if !os.iter().any(|o| o == owner) {
                os.push(owner.to_string());
            }
        }
    }
    // Each mounted model's own references follow its renames; its block has
    // joined `comp`'s.
    for path in &mounts {
        let p = path.join(".");
        let sub = subsystem_at_mut(comp, path).expect("collected mount point");
        if let Some(rm) = rename.get(&p) {
            for (k, v) in sub.iter_mut() {
                if k != "operators" {
                    rename_apply_refs(v, rm);
                }
            }
        }
        sub.shift_remove("operators");
    }
    let rn = rename.get(cname);
    let mut newblock = Map::new();
    for (n, d) in &own {
        if d.get("match").is_none() {
            continue;
        }
        let mut d = d.clone();
        if let Some(rn) = rn {
            rename_apply_refs(&mut d, rn);
        }
        newblock.insert(n.clone(), d);
    }
    newblock.extend(merged);
    // `comp`'s own sites, outside the mount points.
    if let Some(rn) = rn {
        for (k, v) in comp.iter_mut() {
            if k != "operators" && k != "subsystems" {
                rename_apply_refs(v, rn);
            }
        }
        rename_outside_mounts(comp, rn);
    }
    comp.insert("operators".to_string(), Value::Object(newblock));
    owners
}
