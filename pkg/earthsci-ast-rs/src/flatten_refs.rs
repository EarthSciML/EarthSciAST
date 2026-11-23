//! How `flatten` carries operator references through collection (esm-spec
//! §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 steps 2 and 4).
//!
//! A loaded document keeps every reference, each resolving against its
//! component's materialized registry ([`crate::EsmFile::component_operators`]).
//! Flatten carries them into the flattened system, which holds ONE merged
//! registry:
//!
//! * every component's registry is closed first: a body's free names (the
//!   names it reads in the scope of each reference's site) become explicit
//!   parameters, appended sorted ([`crate::flatten::close_template_bodies`]);
//! * the closed registries merge into one, deep-equal entries kept once and a
//!   name whose definitions differ renamed `<component>.<name>` per owner
//!   ([`crate::lower_expression_templates::merge_flat_registry`]);
//! * at every reference site of a component, as it is namespaced, the
//!   reference binds each added parameter to the same name (which the
//!   namespacing then scopes to the site's subsystem) and follows its
//!   component's rename ([`ComponentRefs`], used by the namespacer);
//! * a `variable_map` expression transform's references are owned by the
//!   receiving component ([`own_transform_refs`]).
//!
//! Nothing is expanded. Mirrors the Julia reference `_collect_components`,
//! `_collect_model!`, `_own_transform_refs` and `template_captures`.

use std::collections::{HashMap, HashSet};

use indexmap::IndexMap;
use serde_json::{Map, Value};

use crate::operator_refs::APPLY_OP;
use crate::types::{CouplingEntry, EsmFile, Expr, ExpressionNode, VariableMapTransform};

/// What a component's reference sites need from the registry preparation.
#[derive(Debug, Clone, Default)]
pub(crate) struct ComponentRefs {
    /// Per definition, the free names closing its body appended to its
    /// parameters (each reference binds them to the same names).
    pub(crate) added: HashMap<String, Vec<String>>,
    /// The component's slice of the merged registry's collision rename.
    pub(crate) rename: HashMap<String, String>,
    /// Per definition, the loop symbols its body binds: a name a reference
    /// binds that the body binds as a loop symbol is that loop symbol where
    /// the body reads it, not a variable of the site's component.
    pub(crate) captures: HashMap<String, HashSet<String>>,
    /// Per definition, the parameters its body spells only in a scalar field
    /// (`wrt`, `dim`, a `ranges` bound, …): a bare name bound to one is
    /// scoped as that field scopes it (only when it names a local of the
    /// site), as the expansion would have it.
    pub(crate) literal: HashMap<String, HashSet<String>>,
}

impl ComponentRefs {
    /// Whether this component's sites need nothing rewritten.
    pub(crate) fn is_empty(&self) -> bool {
        self.added.is_empty()
            && self.rename.is_empty()
            && self.captures.is_empty()
            && self.literal.is_empty()
    }

    /// `node`, a reference, binding each parameter its definition gained to
    /// the same name; a binding the reference already has is kept. `None`
    /// when nothing is added.
    pub(crate) fn bind_added(&self, node: &ExpressionNode) -> Option<ExpressionNode> {
        if node.op != APPLY_OP {
            return None;
        }
        let names = self.added.get(node.name.as_deref()?)?;
        let b = node.bindings.as_ref();
        if names.iter().all(|n| b.is_some_and(|b| b.contains_key(n))) {
            return None;
        }
        let mut out = node.clone();
        let b = out.bindings.get_or_insert_with(Default::default);
        for n in names {
            b.entry(n.clone())
                .or_insert_with(|| Expr::Variable(n.clone()));
        }
        Some(out)
    }
}

/// The merged registry and what each component's sites need.
#[derive(Debug, Clone, Default)]
pub(crate) struct FlatRegistry {
    /// The merged registry, closed (esm-spec §9.6.4 rule 7), in document
    /// order.
    pub(crate) registry: IndexMap<String, Value>,
    /// By component path key (`"models.<M>"`, `"reaction_systems.<R>"`).
    pub(crate) components: HashMap<String, ComponentRefs>,
}

impl FlatRegistry {
    /// What the sites of component `compkey` need, if anything.
    pub(crate) fn component(&self, compkey: &str) -> Option<&ComponentRefs> {
        self.components.get(compkey).filter(|c| !c.is_empty())
    }
}

/// `block` without the load-private keys a writer never emits.
fn without_private_keys(block: &Map<String, Value>) -> Map<String, Value> {
    let key = crate::lower_expression_templates::FIXED_UNITS_KEY;
    block
        .iter()
        .map(|(n, d)| {
            let d = match d.as_object() {
                Some(o) if o.contains_key(key) => {
                    let mut o = o.clone();
                    o.shift_remove(key);
                    Value::Object(o)
                }
                _ => d.clone(),
            };
            (n.clone(), d)
        })
        .collect()
}

/// The merged, closed registry of `file` and each component's site rewrites
/// (see the module docs). Components in the order `file.component_templates`
/// holds them, which is the document's (models, then reaction systems).
/// Mirrors the Julia reference's registry preparation in `_collect_components`.
pub(crate) fn prepare(file: &EsmFile) -> FlatRegistry {
    let Some(ct) = &file.component_templates else {
        return FlatRegistry::default();
    };
    let mut blocks: Vec<(String, Map<String, Value>)> = Vec::new();
    let mut components: HashMap<String, ComponentRefs> = HashMap::new();
    let mut paths: Vec<(String, String)> = Vec::new();
    for (compkey, block) in ct {
        let Some((_, cname)) = compkey.split_once('.') else {
            continue;
        };
        let Some(obj) = block.as_object() else {
            continue;
        };
        let (closed, added) = crate::flatten::close_template_bodies(&without_private_keys(obj));
        blocks.push((cname.to_string(), closed));
        let typed = crate::operator_refs::OperatorRegistry::from_json(obj);
        let captures = typed
            .iter()
            .filter(|(_, d)| d.body.is_some() && !d.body_binders().is_empty())
            .map(|(n, d)| (n.clone(), d.body_binders().clone()))
            .collect();
        let literal = typed
            .iter()
            .filter_map(|(n, d)| {
                let ps: HashSet<String> = d
                    .param_roles()
                    .iter()
                    .filter(|(_, r)| r.literal && !r.operand)
                    .map(|(p, _)| p.clone())
                    .collect();
                (!ps.is_empty()).then(|| (n.clone(), ps))
            })
            .collect();
        components.insert(
            compkey.clone(),
            ComponentRefs {
                added,
                rename: HashMap::new(),
                captures,
                literal,
            },
        );
        paths.push((compkey.clone(), cname.to_string()));
    }
    let (merged, mut rename) = crate::lower_expression_templates::merge_flat_registry(&blocks);
    for (compkey, cname) in paths {
        if let (Some(c), Some(rn)) = (components.get_mut(&compkey), rename.remove(&cname)) {
            c.rename = rn;
        }
    }
    FlatRegistry {
        registry: merged.into_iter().collect(),
        components,
    }
}

/// `e` with every reference renamed through `rename` (old name to new),
/// bindings included. `None` when nothing is renamed.
pub(crate) fn rename_refs(e: &Expr, rename: &HashMap<String, String>) -> Option<Expr> {
    if rename.is_empty() || !crate::operator_refs::has_reference(e) {
        return None;
    }
    fn go(e: &Expr, rename: &HashMap<String, String>) -> Expr {
        let Expr::Operator(node) = e else {
            return e.clone();
        };
        if !crate::operator_refs::has_reference(e) {
            return e.clone();
        }
        let mut out = node.map_children(&mut |c| go(c, rename));
        if out.op == APPLY_OP
            && let Some(n) = out.name.as_ref().and_then(|n| rename.get(n))
        {
            out.name = Some(n.clone());
        }
        Expr::operator(out)
    }
    let out = go(e, rename);
    (out != *e).then_some(out)
}

/// `e`'s references bound to their definitions' added parameters, each such
/// binding (a name bound to itself) scoped `owner.name`, and renamed through
/// `refs.rename`. `None` when nothing changes.
fn own_expr(e: &Expr, refs: &ComponentRefs, owner: &str) -> Option<Expr> {
    fn go(e: &Expr, refs: &ComponentRefs, owner: &str) -> Expr {
        let Expr::Operator(node) = e else {
            return e.clone();
        };
        if !crate::operator_refs::has_reference(e) {
            return e.clone();
        }
        let mut out = node.map_children(&mut |c| go(c, refs, owner));
        if out.op == APPLY_OP {
            if let Some(names) = out.name.as_ref().and_then(|n| refs.added.get(n)) {
                let b = out.bindings.get_or_insert_with(Default::default);
                for n in names {
                    let scope = match b.get(n) {
                        Some(Expr::Variable(v)) => v == n,
                        Some(_) => false,
                        None => true,
                    };
                    if scope {
                        b.insert(n.clone(), Expr::Variable(format!("{owner}.{n}")));
                    }
                }
            }
            if let Some(n) = out.name.as_ref().and_then(|n| refs.rename.get(n)) {
                out.name = Some(n.clone());
            }
        }
        Expr::operator(out)
    }
    if !crate::operator_refs::has_reference(e) {
        return None;
    }
    let out = go(e, refs, owner);
    (out != *e).then_some(out)
}

/// `file` with the references of every `variable_map` expression transform
/// owned by the receiving component (the first segment of `to`, esm-spec
/// §10.4): they bind its definitions' added parameters to its scoped names
/// and follow its slice of the registry rename. `None` when nothing changes.
/// Mirrors the Julia reference `_own_transform_refs`.
pub(crate) fn own_transform_refs(file: &EsmFile, reg: &FlatRegistry) -> Option<EsmFile> {
    let entries = file.coupling.as_ref()?;
    let mut changed = false;
    let mut out = entries.clone();
    for entry in &mut out {
        let CouplingEntry::VariableMap {
            to,
            transform: VariableMapTransform::Expression(node),
            ..
        } = entry
        else {
            continue;
        };
        let owner = to.split('.').next().unwrap_or("").to_string();
        let refs = ["models", "reaction_systems"]
            .iter()
            .find_map(|k| reg.component(&format!("{k}.{owner}")));
        let Some(refs) = refs else { continue };
        let e = Expr::operator(node.clone());
        if let Some(Expr::Operator(n)) = own_expr(&e, refs, &owner) {
            *node = ExpressionNode::clone(&n);
            changed = true;
        }
    }
    changed.then(|| {
        let mut f = file.clone();
        f.coupling = Some(out);
        f
    })
}
