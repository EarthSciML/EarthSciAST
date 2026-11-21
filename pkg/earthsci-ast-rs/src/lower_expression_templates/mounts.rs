use super::*;

use std::collections::{HashMap, HashSet};

use crate::binders::Binders;
use crate::types::Expr;

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
            let Some(Value::Object(block)) = comp.get("expression_templates") else {
                continue;
            };
            let keep: Map<String, Value> = block
                .iter()
                .filter(|(_, d)| d.get("match").is_none())
                .map(|(n, d)| (n.clone(), d.clone()))
                .collect();
            let used = comp
                .iter()
                .any(|(k, v)| k != "expression_templates" && has_apply_op(v));
            if keep.is_empty() || !used {
                comp.shift_remove("expression_templates");
            } else {
                comp.insert("expression_templates".to_string(), Value::Object(keep));
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

/// For each template of `block`, the loop symbols its body binds (`output_idx`
/// entries, `ranges` keys, `integral` variables). Template application is
/// substitution, so a name in a reference's binding value that the body binds
/// is that loop index once substituted, not a variable of the component.
/// Mirrors the Julia reference `template_captures`.
pub(crate) fn template_captures(block: &Map<String, Value>) -> HashMap<String, HashSet<String>> {
    fn walk(e: &Expr, out: &mut HashSet<String>) {
        if let Expr::Operator(node) = e {
            node.for_each_binder(Binders::SCOPE, |n| {
                out.insert(n.to_string());
            });
            node.for_each_child(&mut |c| walk(c, out));
        }
    }
    let mut out = HashMap::new();
    for (name, decl) in block {
        let Some(body) = decl.get("body") else {
            continue;
        };
        let Ok(body) = serde_json::from_value::<Expr>(body.clone()) else {
            continue;
        };
        let mut bound = HashSet::new();
        walk(&body, &mut bound);
        if !bound.is_empty() {
            out.insert(name.clone(), bound);
        }
    }
    out
}

/// The mounted model `sub`'s match-less definitions with each body's free
/// names of `sub` (its variables, species, parameters and subsystems — not the
/// template's parameters) written as its parent reads them, `path.name`.
/// Mirrors the Julia reference `_mounted_block_as_read_from_parent`.
fn mounted_block_as_read_from_parent(sub: &Map<String, Value>, path: &str) -> Map<String, Value> {
    let Some(Value::Object(block)) = sub.get("expression_templates") else {
        return Map::new();
    };
    let mut local_names: HashSet<String> = HashSet::new();
    for key in ["variables", "species", "parameters", "subsystems"] {
        match sub.get(key) {
            Some(Value::Object(o)) => local_names.extend(o.keys().cloned()),
            Some(Value::Array(a)) => local_names.extend(
                a.iter()
                    .filter_map(|x| x.get("name").and_then(Value::as_str))
                    .map(str::to_string),
            ),
            _ => {}
        }
    }
    let captures = template_captures(block);
    let mut out = Map::new();
    for (name, decl) in block {
        if decl.get("match").is_some() {
            continue;
        }
        let Some(body) = decl.get("body") else {
            out.insert(name.clone(), decl.clone());
            continue;
        };
        let params: HashSet<&str> = decl
            .get("params")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        let locals: HashSet<String> = local_names
            .iter()
            .filter(|n| !params.contains(n.as_str()))
            .cloned()
            .collect();
        // A body that is not an Expression is carried verbatim, as flatten's
        // registry scoping carries it.
        let scoped = serde_json::from_value::<Expr>(body.clone())
            .ok()
            .map(|e| {
                crate::flatten::scope_template_body(&e, path, &locals, &HashSet::new(), &captures)
            })
            .and_then(|e| serde_json::to_value(&e).ok());
        let mut nd = decl.clone();
        if let (Some(scoped), Some(obj)) = (scoped, nd.as_object_mut()) {
            obj.insert("body".to_string(), scoped);
        }
        out.insert(name.clone(), nd);
    }
    out
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
        if sub
            .get("expression_templates")
            .is_some_and(Value::is_object)
        {
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
        if sub
            .get("expression_templates")
            .is_some_and(Value::is_object)
        {
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

/// Merge into the component `comp`'s `expression_templates` block the template
/// definitions that models mounted as its subsystems (esm-spec §4.7) brought
/// with them (esm-spec §9.6.4 rule 1). Each mounted block joins `comp`'s by
/// flatten's registry-merge rule ([`merge_flat_registry`]): deep-equal entries
/// are kept once, and a name two non-equal entries share is renamed in every
/// owner to `<owner path>.<name>`, with that owner's references renamed in
/// lockstep. The owner path of `comp`'s own entries is `cname`, of a mounted
/// block its subsystem path below `comp` (`Sub` or `Sub.Inner`).
///
/// A mounted body's free names are first written as `comp` reads them (`T`
/// becomes `Sub.T`). The mounted subtree keeps naming its own entries (under
/// its renames); only `comp`'s other sites follow `comp`'s renames. `comp`'s
/// `match` rules stay, ahead of the merged entries. Mirrors the Julia reference
/// `_hoist_mounted_templates!`.
pub(crate) fn hoist_mounted_templates(comp: &mut Map<String, Value>, cname: &str) {
    let mut mounts: Vec<Vec<String>> = Vec::new();
    collect_mounted_blocks(comp, &[], &mut mounts);
    if mounts.is_empty() {
        return;
    }
    let own: Map<String, Value> = comp
        .get("expression_templates")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let mut blocks: Vec<(String, Map<String, Value>)> = vec![(
        cname.to_string(),
        own.iter()
            .filter(|(_, d)| d.get("match").is_none())
            .map(|(n, d)| (n.clone(), d.clone()))
            .collect(),
    )];
    for path in &mounts {
        let p = path.join(".");
        let sub = subsystem_at_mut(comp, path).expect("collected mount point");
        let block = mounted_block_as_read_from_parent(sub, &p);
        blocks.push((p, block));
    }
    let (merged, rename) = merge_flat_registry(&blocks);
    // Each mounted model's own references follow its renames; its block has
    // joined `comp`'s.
    for path in &mounts {
        let p = path.join(".");
        let sub = subsystem_at_mut(comp, path).expect("collected mount point");
        if let Some(rm) = rename.get(&p) {
            for (k, v) in sub.iter_mut() {
                if k != "expression_templates" {
                    rename_apply_refs(v, rm);
                }
            }
        }
        sub.shift_remove("expression_templates");
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
            if k != "expression_templates" && k != "subsystems" {
                rename_apply_refs(v, rn);
            }
        }
        rename_outside_mounts(comp, rn);
    }
    comp.insert("expression_templates".to_string(), Value::Object(newblock));
}

/// The component registry `block` as a site inside its subsystem at `path`
/// reads it: in each body, a free name under that subsystem (`path.n`, as
/// [`hoist_mounted_templates`] writes a mounted body's names, or as an
/// authored body spells a name under it) is spelled as the subsystem reads it
/// (`n`). The rename touches variable names only, and only bodies that hold
/// such a name. Used by this binding's load-time expansion ([`expand`]) when it
/// expands a reference that sits inside a subsystem, so that the expansion
/// reads what the reference-preserving form reads in the owning component's
/// scope (`<component>.<path>.n` after flatten).
pub(crate) fn registry_read_from_subsystem(
    block: &Map<String, Value>,
    path: &str,
) -> Map<String, Value> {
    fn mentions(v: &Value, dotted: &str) -> bool {
        match v {
            Value::String(s) => s.starts_with(dotted),
            Value::Array(a) => a.iter().any(|x| mentions(x, dotted)),
            Value::Object(o) => o.values().any(|x| mentions(x, dotted)),
            _ => false,
        }
    }
    fn rebase(e: &Expr, dotted: &str) -> Expr {
        match e {
            Expr::Variable(n) => match n.strip_prefix(dotted) {
                Some(rest) => Expr::Variable(rest.to_string()),
                None => e.clone(),
            },
            Expr::Operator(node) => Expr::operator(node.map_children(&mut |c| rebase(c, dotted))),
            _ => e.clone(),
        }
    }
    let dotted = format!("{path}.");
    let mut out = block.clone();
    for decl in out.values_mut() {
        let Some(body) = decl.get("body").filter(|b| mentions(b, &dotted)) else {
            continue;
        };
        let Some(rebased) = serde_json::from_value::<Expr>(body.clone())
            .ok()
            .and_then(|e| serde_json::to_value(rebase(&e, &dotted)).ok())
        else {
            continue;
        };
        if let Some(obj) = decl.as_object_mut() {
            obj.insert("body".to_string(), rebased);
        }
    }
    out
}
