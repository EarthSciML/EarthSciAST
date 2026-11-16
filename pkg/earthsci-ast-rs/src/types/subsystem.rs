//! The entries of a component's `subsystems` map, and the one walk over a
//! component and the subsystems it holds at every depth.

use super::{Model, ReactionSystem};
use indexmap::IndexMap;
use serde::de::{DeserializeOwned, Error as _};
use serde::{Deserialize, Deserializer, Serialize};

/// One entry of a component's `subsystems` map (esm-spec §4.7): a child
/// component written inline, or a `{"ref": …}` mount edge.
///
/// `C` is the owning component's kind: a [`Model`]'s subsystems are models,
/// a [`ReactionSystem`]'s are reaction systems. Every `load_*` entry point
/// resolves each mount edge before it types the document, so a loaded
/// document holds only [`Subsystem::Inline`] entries; a
/// [`Subsystem::Reference`] is what a document built in code holds before it
/// is resolved.
///
/// An entry with a `ref` key reads as a reference; any other entry must
/// decode as `C`, and one that does not is a decode error.
#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum Subsystem<C> {
    /// A child component written inline (or spliced in by the loader).
    Inline(Box<C>),
    /// An unresolved `{"ref": …}` mount edge.
    Reference(SubsystemRef),
}

/// An unresolved `{"ref": …}` mount edge (schema `SubsystemRef`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SubsystemRef {
    /// The local path or URL of the referenced document.
    #[serde(rename = "ref")]
    pub target: String,
    /// The edge's other keys (`model`, `reaction_system`, `bindings`,
    /// `index_set_rename`, …), as written.
    #[serde(flatten)]
    pub edge: serde_json::Map<String, serde_json::Value>,
}

impl<C> Subsystem<C> {
    /// An inline entry holding `component`.
    pub fn inline(component: C) -> Self {
        Subsystem::Inline(Box::new(component))
    }

    /// The inline component, `None` for an unresolved reference.
    pub fn as_inline(&self) -> Option<&C> {
        match self {
            Subsystem::Inline(c) => Some(c),
            Subsystem::Reference(_) => None,
        }
    }

    /// The inline component, mutably; `None` for an unresolved reference.
    pub fn as_inline_mut(&mut self) -> Option<&mut C> {
        match self {
            Subsystem::Inline(c) => Some(c),
            Subsystem::Reference(_) => None,
        }
    }

    /// The mount edge, `None` for an inline entry.
    pub fn as_reference(&self) -> Option<&SubsystemRef> {
        match self {
            Subsystem::Inline(_) => None,
            Subsystem::Reference(r) => Some(r),
        }
    }
}

impl<'de, C: DeserializeOwned> Deserialize<'de> for Subsystem<C> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        if value.get("ref").is_some() {
            serde_json::from_value(value)
                .map(Subsystem::Reference)
                .map_err(D::Error::custom)
        } else {
            serde_json::from_value(value)
                .map(Subsystem::inline)
                .map_err(D::Error::custom)
        }
    }
}

/// A component that holds `subsystems` of its own kind: [`Model`] and
/// [`ReactionSystem`].
pub trait HasSubsystems: Sized {
    /// The component's `subsystems` map.
    fn subsystems(&self) -> Option<&IndexMap<String, Subsystem<Self>>>;

    /// The component's `subsystems` map, mutably.
    fn subsystems_mut(&mut self) -> Option<&mut IndexMap<String, Subsystem<Self>>>;

    /// The component's inline subsystems, in declaration order; an
    /// unresolved reference is left out.
    fn inline_subsystems(&self) -> impl Iterator<Item = (&String, &Self)> {
        self.subsystems()
            .into_iter()
            .flatten()
            .filter_map(|(name, sub)| Some((name, sub.as_inline()?)))
    }

    /// The component's inline subsystems, mutably.
    fn inline_subsystems_mut(&mut self) -> impl Iterator<Item = (&String, &mut Self)> {
        self.subsystems_mut()
            .into_iter()
            .flatten()
            .filter_map(|(name, sub)| Some((name, sub.as_inline_mut()?)))
    }

    /// The inline subsystem `name`, `None` when there is none (or it is an
    /// unresolved reference).
    fn inline_subsystem(&self, name: &str) -> Option<&Self> {
        self.subsystems()?.get(name)?.as_inline()
    }

    /// The inline subsystem the keys `path` lead to below this component
    /// (`["Sub", "Inner"]` for `Sub.Inner`); the component itself for an
    /// empty path.
    fn inline_subsystem_at<'a>(&'a self, path: &[&str]) -> Option<&'a Self> {
        path.iter()
            .try_fold(self, |cur, seg| cur.inline_subsystem(seg))
    }
}

impl HasSubsystems for Model {
    fn subsystems(&self) -> Option<&IndexMap<String, Subsystem<Self>>> {
        self.subsystems.as_ref()
    }
    fn subsystems_mut(&mut self) -> Option<&mut IndexMap<String, Subsystem<Self>>> {
        self.subsystems.as_mut()
    }
}

impl HasSubsystems for ReactionSystem {
    fn subsystems(&self) -> Option<&IndexMap<String, Subsystem<Self>>> {
        self.subsystems.as_ref()
    }
    fn subsystems_mut(&mut self) -> Option<&mut IndexMap<String, Subsystem<Self>>> {
        self.subsystems.as_mut()
    }
}

/// One component reached by [`component_tree`] or [`subsystem_tree`].
#[derive(Debug, Clone)]
pub struct ComponentVisit<'a, C> {
    /// The component's dotted path: the walk's `scope`, then the subsystem
    /// keys leading to it (`Model.Sub.Inner`; `Sub.Inner` under an empty
    /// scope).
    pub path: String,
    /// The component's JSON pointer: the walk's `pointer`, then a
    /// `/subsystems/<key>` pair per level.
    pub pointer: String,
    /// The subsystem key the component sits under; empty for the walk's root.
    pub key: &'a str,
    /// How many subsystem levels below the walk's root it sits (0 for the
    /// root).
    pub depth: usize,
    /// The component itself.
    pub component: &'a C,
}

/// The order [`component_tree`] visits the subsystems of one component in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TreeOrder {
    /// The order the `subsystems` map declares them in.
    Declared,
    /// Sorted by key.
    Sorted,
}

/// `component` and every inline subsystem below it at any depth, depth first
/// (a component, then its subsystems in `order`, each followed by its own).
/// `scope` and `pointer` are the root's dotted path and JSON pointer. An
/// unresolved reference declares nothing and is not visited.
pub fn component_tree<'a, C: HasSubsystems>(
    component: &'a C,
    scope: &str,
    pointer: &str,
    order: TreeOrder,
) -> Vec<ComponentVisit<'a, C>> {
    let mut out = vec![ComponentVisit {
        path: scope.to_string(),
        pointer: pointer.to_string(),
        key: "",
        depth: 0,
        component,
    }];
    push_subsystems(component, scope, pointer, 1, order, &mut out);
    out
}

/// [`component_tree`] less its root: the inline subsystems below `component`.
pub fn subsystem_tree<'a, C: HasSubsystems>(
    component: &'a C,
    scope: &str,
    pointer: &str,
    order: TreeOrder,
) -> Vec<ComponentVisit<'a, C>> {
    let mut out = Vec::new();
    push_subsystems(component, scope, pointer, 1, order, &mut out);
    out
}

fn push_subsystems<'a, C: HasSubsystems>(
    component: &'a C,
    scope: &str,
    pointer: &str,
    depth: usize,
    order: TreeOrder,
    out: &mut Vec<ComponentVisit<'a, C>>,
) {
    let mut subs: Vec<(&'a String, &'a C)> = component.inline_subsystems().collect();
    if order == TreeOrder::Sorted {
        subs.sort_by(|a, b| a.0.cmp(b.0));
    }
    for (key, sub) in subs {
        let path = if scope.is_empty() {
            key.clone()
        } else {
            format!("{scope}.{key}")
        };
        let pointer = format!("{pointer}/subsystems/{key}");
        out.push(ComponentVisit {
            path: path.clone(),
            pointer: pointer.clone(),
            key,
            depth,
            component: sub,
        });
        push_subsystems(sub, &path, &pointer, depth + 1, order, out);
    }
}

/// Calls `f` with the dotted path and each inline subsystem below
/// `component`, mutably, in [`subsystem_tree`]'s order.
pub fn for_each_subsystem_mut<C: HasSubsystems>(
    component: &mut C,
    scope: &str,
    f: &mut dyn FnMut(&str, &mut C),
) {
    for (key, sub) in component.inline_subsystems_mut() {
        let path = if scope.is_empty() {
            key.clone()
        } else {
            format!("{scope}.{key}")
        };
        f(&path, sub);
        for_each_subsystem_mut(sub, &path, f);
    }
}
