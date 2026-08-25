//! Build-time reference resolution for the semiring-FAQ unified IR: the
//! intra-document node-id / index-set dependency DAG.
//!
//! Not to be confused with [`crate::ref_loading`], which inlines cross-file
//! `{ "ref": ... }` subsystem mounts at load time — this module never touches
//! the filesystem; it wires id-addressed edges inside one document.
//!
//! Implements *node addressing* and *reference-edge resolution* — the hard
//! prerequisite the §6.1 cadence-partition pass of the
//! `semiring-faq-unified-ir` RFC calls out:
//!
//! > "node addressing — referencing a node by id — is a hard prerequisite: the
//! > pass cannot be built until `from_faq` and join references are real edges
//! > in this DAG."
//!
//! The partition pass classifies every node by cadence (`CONST` / `DISCRETE` /
//! `CONTINUOUS`) by walking the *inter-node* dependency DAG bottom-up
//! (`class(n) = max` over inputs). For that walk to exist, three kinds of
//! name/id reference in the document must be resolved into real, queryable
//! graph edges (RFC §6.1 "Propagation"):
//!
//! * an aggregate node → an index set it references (`ranges[*].from`);
//! * a `kind:"derived"` index set → its `from_faq` node (by stable id);
//! * an aggregate `join.on` factor → the factor it names.
//!
//! Like the Julia and Python bindings, this pass operates on the **raw parsed
//! document** ([`serde_json::Value`]) rather than the typed [`crate::types`]
//! structs — not because the typed layer lacks these fields (it carries every
//! one: `EsmFile.index_sets`, `ExpressionNode.id`, the `from` of
//! `RangeSpec::IndexSetRef`, and `ExpressionNode.join`) but for parity with the
//! Julia and Python passes, which have no typed layer and resolve references
//! straight from the parsed JSON. Working the same raw shape keeps the three
//! bindings byte-for-byte in step.
//! The pass is self-contained and additive — a document using none of these
//! features yields an empty-but-valid graph.
//!
//! The [`ReferenceGraph`] output is the queryable surface the partition pass
//! consumes: [`ReferenceGraph::dependencies`] / [`ReferenceGraph::dependents`]
//! give the DAG adjacency, and [`ReferenceGraph::topological_order`] both
//! detects reference cycles (an out-of-scope implicit/iterative solve, RFC §6.1
//! "Acyclicity") and yields a bottom-up evaluation order.

use indexmap::IndexMap;
use serde_json::{Map, Value};
use std::collections::HashSet;
use thiserror::Error;

/// Deprecated alias of [`ReferenceResolutionError`].
///
/// API_SPEC.md §8 item 10: Julia, Python and Go all raise
/// `ReferenceResolutionError`; this binding alone spelled it `ReferenceError`.
/// The canonical spelling is now `ReferenceResolutionError`; this alias is kept
/// for one minor per API_SPEC.md §10 and will be removed at the next major.
#[deprecated(
    since = "0.2.0",
    note = "renamed to `ReferenceResolutionError` (API_SPEC.md §8 item 10)"
)]
pub type ReferenceError = ReferenceResolutionError;

/// A reference could not be resolved, or the reference graph has a cycle.
///
/// Variant names are deliberately cross-language-compatible so the Julia,
/// Python, and Rust bindings report the same failure mode under the same name
/// (mirrors the `E_REF_*` codes in the Python binding).
#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum ReferenceResolutionError {
    /// A `ranges[*].from` names an index set not declared in `index_sets`.
    #[error(
        "undeclared index set '{name}' referenced by range '{index}' of node {node} (model '{model}', at {path})"
    )]
    UndeclaredIndexSet {
        name: String,
        index: String,
        node: String,
        model: String,
        path: String,
    },

    /// A `kind:"derived"` index set's `from_faq` names no expression-node id.
    ///
    /// Resolved at DOCUMENT scope (esm-spec.md §9.7.5); `model` names the model
    /// whose graph was being built when the lookup failed.
    #[error(
        "derived index set '{index_set}' references from_faq '{from_faq}', which is not the id of any expression node in the document (model '{model}')"
    )]
    UnknownFaqNode {
        index_set: String,
        from_faq: String,
        model: String,
    },

    /// Two expression nodes in the same DOCUMENT share an explicit `id`.
    ///
    /// Node ids are unique per document, not per model (esm-spec.md §9.7.5);
    /// when the two occurrences are in different models the paths are
    /// model-qualified and `model` names the second occurrence's model.
    #[error("duplicate expression-node id '{id}' in model '{model}' (at {path} and {first})")]
    DuplicateNodeId {
        id: String,
        model: String,
        path: String,
        first: String,
    },

    /// A `join.on` factor reference names nothing in the node's scope.
    #[error(
        "join factor '{factor}' of node {node} names no factor, range, or output index in scope (model '{model}', at {path})"
    )]
    UnresolvedJoinFactor {
        factor: String,
        node: String,
        model: String,
        path: String,
    },

    /// A directed cycle exists among the reference edges (RFC §6.1 acyclicity).
    #[error("reference cycle detected: {}", .path.join(" -> "))]
    ReferenceCycle { path: Vec<String> },
}

/// The three kinds of vertex in the reference graph.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VertexKind {
    /// An expression node (aggregate / `id`-bearing).
    Node,
    /// A declared `index_sets` entry.
    IndexSet,
    /// A factor named by a `join.on` reference.
    Factor,
}

/// The three kinds of reference edge (RFC §6.1 "Propagation").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EdgeKind {
    /// Aggregate node → the index set it iterates (`ranges[*].from`).
    RangeFrom,
    /// `kind:"derived"` index set → the node that materialises it (`from_faq`).
    FromFaq,
    /// Aggregate node → a factor named by `join.on`.
    JoinFactor,
}

/// A vertex in the reference graph, addressed by a kind-namespaced `key`.
///
/// `key` is `"{kind}:{name}"`. For a [`VertexKind::Node`] vertex `name` is the
/// node's stable address: its explicit `id` when present, else its structural
/// path (e.g. `equations/0/rhs/expr`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReferenceVertex {
    pub key: String,
    pub kind: VertexKind,
    pub name: String,
    pub op: Option<String>,
    pub node_id: Option<String>,
    pub path: Option<String>,
}

/// A directed `source → target` edge: *source references / depends on target*.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReferenceEdge {
    pub source: String,
    pub target: String,
    pub kind: EdgeKind,
}

/// The resolved reference DAG for one model — the partition pass's input.
///
/// Edges point from a vertex to a vertex it *depends on*, so a bottom-up
/// ([`topological_order`](ReferenceGraph::topological_order)) walk visits each
/// vertex after its dependencies — the order `class(n) = max(class(inputs))`
/// propagation needs.
#[derive(Debug, Clone, Default)]
pub struct ReferenceGraph {
    pub model: String,
    pub vertices: IndexMap<String, ReferenceVertex>,
    pub edges: Vec<ReferenceEdge>,
    out: IndexMap<String, Vec<String>>,
    incoming: IndexMap<String, Vec<String>>,
}

impl ReferenceGraph {
    fn ensure_vertex(&mut self, vertex: ReferenceVertex) {
        if !self.vertices.contains_key(&vertex.key) {
            self.out.entry(vertex.key.clone()).or_default();
            self.incoming.entry(vertex.key.clone()).or_default();
            self.vertices.insert(vertex.key.clone(), vertex);
        }
    }

    fn add_edge(&mut self, source: &str, target: &str, kind: EdgeKind) {
        self.edges.push(ReferenceEdge {
            source: source.to_string(),
            target: target.to_string(),
            kind,
        });
        self.out
            .entry(source.to_string())
            .or_default()
            .push(target.to_string());
        self.incoming
            .entry(target.to_string())
            .or_default()
            .push(source.to_string());
    }

    /// Vertices `key` references / depends on (its out-neighbours).
    pub fn dependencies(&self, key: &str) -> Vec<String> {
        self.out.get(key).cloned().unwrap_or_default()
    }

    /// Vertices that reference / depend on `key` (its in-neighbours).
    pub fn dependents(&self, key: &str) -> Vec<String> {
        self.incoming.get(key).cloned().unwrap_or_default()
    }

    /// All edges of a given kind, in insertion order.
    pub fn edges_of_kind(&self, kind: EdgeKind) -> Vec<&ReferenceEdge> {
        self.edges.iter().filter(|e| e.kind == kind).collect()
    }

    /// Return a reference cycle as a vertex-key path (`[v, …, v]`), or `None`.
    ///
    /// Three-colour DFS over the dependency edges, deterministic (sorted
    /// vertices, sorted neighbours).
    pub fn detect_cycle(&self) -> Option<Vec<String>> {
        #[derive(Clone, Copy, PartialEq)]
        enum Colour {
            White,
            Grey,
            Black,
        }
        let mut colour: IndexMap<String, Colour> = self
            .vertices
            .keys()
            .map(|k| (k.clone(), Colour::White))
            .collect();
        let mut starts: Vec<String> = self.vertices.keys().cloned().collect();
        starts.sort();

        for start in starts {
            if colour.get(&start).copied().unwrap_or(Colour::White) != Colour::White {
                continue;
            }
            let mut stack: Vec<(String, usize)> = vec![(start.clone(), 0)];
            let mut path: Vec<String> = vec![start.clone()];
            colour.insert(start.clone(), Colour::Grey);
            while let Some((node, i)) = stack.last().cloned() {
                let mut neigh = self.out.get(&node).cloned().unwrap_or_default();
                neigh.sort();
                if i < neigh.len() {
                    stack.last_mut().unwrap().1 = i + 1;
                    let nxt = neigh[i].clone();
                    match colour.get(&nxt).copied().unwrap_or(Colour::White) {
                        Colour::Grey => {
                            let idx = path.iter().position(|p| *p == nxt).unwrap_or(0);
                            let mut cyc: Vec<String> = path[idx..].to_vec();
                            cyc.push(nxt);
                            return Some(cyc);
                        }
                        Colour::White => {
                            colour.insert(nxt.clone(), Colour::Grey);
                            stack.push((nxt.clone(), 0));
                            path.push(nxt);
                        }
                        Colour::Black => {}
                    }
                } else {
                    colour.insert(node.clone(), Colour::Black);
                    stack.pop();
                    path.pop();
                }
            }
        }
        None
    }

    /// Bottom-up order (dependencies before dependents).
    ///
    /// Errors with [`ReferenceResolutionError::ReferenceCycle`] if the graph is cyclic —
    /// a cycle among reference edges is an out-of-scope implicit/iterative solve
    /// (RFC §6.1 "Acyclicity").
    pub fn topological_order(&self) -> Result<Vec<String>, ReferenceResolutionError> {
        // Two deliberate passes rather than one Kahn sweep: `detect_cycle`'s
        // DFS reports the actual cycle PATH (Kahn's leftover-vertex set
        // cannot name the path), and the wave loop below emits ready vertices
        // in sorted-key order per wave, keeping the materialization order
        // deterministic. Document node counts are small, so the O(V²) scan
        // is irrelevant; after the cycle check the no-progress break is
        // unreachable.
        if let Some(cyc) = self.detect_cycle() {
            return Err(ReferenceResolutionError::ReferenceCycle { path: cyc });
        }
        let mut emitted: Vec<String> = Vec::new();
        let mut done: HashSet<String> = HashSet::new();
        let mut keys: Vec<String> = self.vertices.keys().cloned().collect();
        keys.sort();
        while emitted.len() < self.vertices.len() {
            let mut progressed = false;
            for k in &keys {
                if done.contains(k) {
                    continue;
                }
                let deps = self.out.get(k).cloned().unwrap_or_default();
                if deps.iter().all(|d| done.contains(d)) {
                    emitted.push(k.clone());
                    done.insert(k.clone());
                    progressed = true;
                }
            }
            if !progressed {
                break;
            }
        }
        Ok(emitted)
    }
}

fn node_key(addr: &str) -> String {
    format!("node:{addr}")
}
fn index_set_key(name: &str) -> String {
    format!("index_set:{name}")
}
fn factor_key(name: &str) -> String {
    format!("factor:{name}")
}

fn nonempty_str(value: Option<&Value>) -> Option<&str> {
    value.and_then(|v| v.as_str()).filter(|s| !s.is_empty())
}

/// The names a `join.on` reference may resolve to: the node's string
/// factor-args, its declared range keys, and its symbolic `output_idx`.
fn factor_scope(map: &Map<String, Value>) -> HashSet<String> {
    let mut names = HashSet::new();
    if let Some(args) = map.get("args").and_then(|v| v.as_array()) {
        for a in args {
            if let Some(s) = a.as_str() {
                names.insert(s.to_string());
            }
        }
    }
    if let Some(ranges) = map.get("ranges").and_then(|v| v.as_object()) {
        for k in ranges.keys() {
            names.insert(k.clone());
        }
    }
    if let Some(oi) = map.get("output_idx").and_then(|v| v.as_array()) {
        for o in oi {
            if let Some(s) = o.as_str() {
                names.insert(s.to_string());
            }
        }
    }
    names
}

/// One id-bearing expression node, as the `from_faq` scope sees it.
#[derive(Clone, Debug)]
struct DocNode {
    addr: String,
    path: String,
    op: Option<String>,
}

#[allow(clippy::too_many_arguments)]
fn register_and_process(
    map: &Map<String, Value>,
    path: &str,
    model_name: &str,
    index_sets: Option<&Map<String, Value>>,
    graph: &mut ReferenceGraph,
    id_to_addr: &mut IndexMap<String, DocNode>,
) -> Result<(), ReferenceResolutionError> {
    let op = map.get("op").and_then(|v| v.as_str());
    let nid = nonempty_str(map.get("id"));
    let is_agg = op.map(crate::aggregate::is_aggregate_op).unwrap_or(false);
    // only aggregate / FAQ nodes and any node carrying an explicit id become
    // addressable vertices.
    if !is_agg && nid.is_none() {
        return Ok(());
    }
    let addr = nid
        .map(|s| s.to_string())
        .unwrap_or_else(|| path.to_string());
    let key = node_key(&addr);

    if let Some(id) = nid {
        if let Some(first) = id_to_addr.get(id) {
            return Err(ReferenceResolutionError::DuplicateNodeId {
                id: id.to_string(),
                model: model_name.to_string(),
                path: path.to_string(),
                first: first.path.clone(),
            });
        }
        id_to_addr.insert(
            id.to_string(),
            DocNode {
                addr: addr.clone(),
                path: path.to_string(),
                op: op.map(|s| s.to_string()),
            },
        );
    }

    graph.ensure_vertex(ReferenceVertex {
        key: key.clone(),
        kind: VertexKind::Node,
        name: addr.clone(),
        op: op.map(|s| s.to_string()),
        node_id: nid.map(|s| s.to_string()),
        path: Some(path.to_string()),
    });

    // ranges[*].from -> index set
    if let Some(ranges) = map.get("ranges").and_then(|v| v.as_object()) {
        for (idx_name, spec) in ranges {
            if let Some(spec_obj) = spec.as_object()
                && let Some(from) = spec_obj.get("from")
            {
                let target = from.as_str().unwrap_or("");
                let declared = index_sets.map(|m| m.contains_key(target)).unwrap_or(false);
                if target.is_empty() || !declared {
                    return Err(ReferenceResolutionError::UndeclaredIndexSet {
                        name: target.to_string(),
                        index: idx_name.clone(),
                        node: key.clone(),
                        model: model_name.to_string(),
                        path: path.to_string(),
                    });
                }
                graph.add_edge(&key, &index_set_key(target), EdgeKind::RangeFrom);
            }
        }
    }

    // join[*].on[*] -> factor
    if let Some(join) = map.get("join").and_then(|v| v.as_array()) {
        let scope = factor_scope(map);
        for clause in join {
            let on = match clause.get("on").and_then(|v| v.as_array()) {
                Some(on) => on,
                None => continue,
            };
            for pair in on {
                let reference = pair
                    .as_array()
                    .and_then(|p| p.first())
                    .and_then(|v| v.as_str());
                match reference {
                    Some(r) if scope.contains(r) => {
                        graph.ensure_vertex(ReferenceVertex {
                            key: factor_key(r),
                            kind: VertexKind::Factor,
                            name: r.to_string(),
                            op: None,
                            node_id: None,
                            path: None,
                        });
                        graph.add_edge(&key, &factor_key(r), EdgeKind::JoinFactor);
                    }
                    other => {
                        return Err(ReferenceResolutionError::UnresolvedJoinFactor {
                            factor: other.unwrap_or("").to_string(),
                            node: key.clone(),
                            model: model_name.to_string(),
                            path: path.to_string(),
                        });
                    }
                }
            }
        }
    }

    Ok(())
}

fn walk(
    value: &Value,
    path: &str,
    model_name: &str,
    index_sets: Option<&Map<String, Value>>,
    graph: &mut ReferenceGraph,
    id_to_addr: &mut IndexMap<String, DocNode>,
) -> Result<(), ReferenceResolutionError> {
    match value {
        Value::Object(map) => {
            if map.contains_key("op") {
                register_and_process(map, path, model_name, index_sets, graph, id_to_addr)?;
            }
            for (k, v) in map {
                walk(
                    v,
                    &format!("{path}/{k}"),
                    model_name,
                    index_sets,
                    graph,
                    id_to_addr,
                )?;
            }
        }
        Value::Array(arr) => {
            for (i, v) in arr.iter().enumerate() {
                walk(
                    v,
                    &format!("{path}/{i}"),
                    model_name,
                    index_sets,
                    graph,
                    id_to_addr,
                )?;
            }
        }
        _ => {}
    }
    Ok(())
}

/// The model members whose expression trees carry addressable nodes.
const WALK_ROOTS: [&str; 2] = ["equations", "initialization_equations"];

/// Collect every explicit expression-node `id` under one model's `value`.
fn collect_ids(
    value: &Value,
    path: &str,
    model_name: &str,
    nodes: &mut IndexMap<String, DocNode>,
) -> Result<(), ReferenceResolutionError> {
    match value {
        Value::Object(map) => {
            if map.contains_key("op")
                && let Some(id) = nonempty_str(map.get("id"))
            {
                let qualified = format!("models/{model_name}/{path}");
                if let Some(first) = nodes.get(id) {
                    return Err(ReferenceResolutionError::DuplicateNodeId {
                        id: id.to_string(),
                        model: model_name.to_string(),
                        path: qualified,
                        first: first.path.clone(),
                    });
                }
                nodes.insert(
                    id.to_string(),
                    DocNode {
                        addr: id.to_string(),
                        path: qualified,
                        op: map
                            .get("op")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string()),
                    },
                );
            }
            for (k, v) in map {
                collect_ids(v, &format!("{path}/{k}"), model_name, nodes)?;
            }
        }
        Value::Array(arr) => {
            for (i, v) in arr.iter().enumerate() {
                collect_ids(v, &format!("{path}/{i}"), model_name, nodes)?;
            }
        }
        _ => {}
    }
    Ok(())
}

/// Every explicit expression-node `id` in `document`, keyed by id.
///
/// `from_faq` resolves at DOCUMENT scope (esm-spec.md §9.7.5): a document-scoped
/// `index_sets` entry is visible to every model, so the node it names may live
/// in any of them. This pass therefore runs over all models BEFORE any single
/// model's graph is built.
///
/// Because ids from different models share one namespace, uniqueness is a
/// DOCUMENT-wide requirement: a duplicate `id` anywhere in the document is
/// [`ReferenceResolutionError::DuplicateNodeId`].
fn collect_document_node_ids(
    document: &Value,
) -> Result<IndexMap<String, DocNode>, ReferenceResolutionError> {
    let mut nodes = IndexMap::new();
    if let Some(models) = document.get("models").and_then(|v| v.as_object()) {
        for (model_name, model) in models {
            for root in WALK_ROOTS {
                if let Some(v) = model.get(root) {
                    collect_ids(v, root, model_name, &mut nodes)?;
                }
            }
        }
    }
    Ok(nodes)
}

/// Deprecated alias of [`build_reference_graph`].
///
/// API_SPEC.md §8 item 17: a binding that exposes the explicit index-set
/// registry keeps it as an optional TRAILING argument of
/// `build_reference_graph`, not as a separate name. Kept for one minor per
/// API_SPEC.md §10.
#[deprecated(
    since = "0.2.0",
    note = "the registry is now the trailing argument of `build_reference_graph` (API_SPEC.md §8 item 17)"
)]
pub fn build_reference_graph_with_index_sets(
    model: &Value,
    model_name: &str,
    doc_index_sets: Option<&Map<String, Value>>,
) -> Result<ReferenceGraph, ReferenceResolutionError> {
    build_reference_graph(model, model_name, doc_index_sets)
}

/// Resolve the reference edges of one `model` value into a graph, against the
/// **document-scoped** `index_sets` registry.
///
/// One name, with the registry as an optional TRAILING argument (API_SPEC.md
/// §8 item 17) — the shape Python (`index_sets=None`) and Go (`docIndexSets`)
/// already have. Pass `None` for a direct caller holding only a raw model;
/// [`resolve_references`], which is the DOCUMENT-scoped entry point, derives
/// the registry from the document itself and threads it in for every model.
///
/// Since v0.8.0 the `index_sets` registry is a sibling of `models`, shared by
/// every model, rather than nested inside each model (mirrors
/// [`crate::cadence::model_with_loaders`]). Any (pre-0.8.0) model-nested
/// `index_sets` is *merged* on top — a model-level entry wins on a key
/// collision — so the older nested shape keeps working unchanged.
///
/// Errors on a duplicate node id, an undeclared `ranges[*].from` index set, a
/// `from_faq` naming no node, or an unresolved `join.on` factor. Cycles are
/// reported lazily by [`ReferenceGraph::topological_order`], or eagerly by
/// [`resolve_references`].
pub fn build_reference_graph(
    model: &Value,
    model_name: &str,
    doc_index_sets: Option<&Map<String, Value>>,
) -> Result<ReferenceGraph, ReferenceResolutionError> {
    build_reference_graph_impl(model, model_name, doc_index_sets, None)
}

/// [`build_reference_graph`], plus the document-wide `from_faq` scope.
///
/// `document_nodes` is the map [`collect_document_node_ids`] builds over every
/// model. When it is `None` the model's own nodes are the scope.
fn build_reference_graph_impl(
    model: &Value,
    model_name: &str,
    doc_index_sets: Option<&Map<String, Value>>,
    document_nodes: Option<&IndexMap<String, DocNode>>,
) -> Result<ReferenceGraph, ReferenceResolutionError> {
    let mut graph = ReferenceGraph {
        model: model_name.to_string(),
        ..Default::default()
    };

    // Merge the document-scoped registry (v0.8.0+) with any model-nested one
    // (pre-0.8.0); model-level entries take precedence on a key collision.
    let model_index_sets = model.get("index_sets").and_then(|v| v.as_object());
    let merged_index_sets: Option<Map<String, Value>> = match (doc_index_sets, model_index_sets) {
        (None, None) => None,
        (Some(d), None) => Some(d.clone()),
        (None, Some(m)) => Some(m.clone()),
        (Some(d), Some(m)) => {
            let mut merged = d.clone();
            for (k, v) in m {
                merged.insert(k.clone(), v.clone());
            }
            Some(merged)
        }
    };
    let index_sets = merged_index_sets.as_ref();

    // Pass 1 — register declared index sets as vertices.
    if let Some(is) = index_sets {
        for name in is.keys() {
            graph.ensure_vertex(ReferenceVertex {
                key: index_set_key(name),
                kind: VertexKind::IndexSet,
                name: name.clone(),
                op: None,
                node_id: None,
                path: None,
            });
        }
    }

    // Pass 2 — walk every expression node: assign a stable address, register
    // aggregate / id-bearing nodes, and add the within-node reference edges
    // (ranges[*].from, join.on). Builds id -> address for from_faq.
    let mut id_to_addr: IndexMap<String, DocNode> = IndexMap::new();
    for root in WALK_ROOTS {
        if let Some(v) = model.get(root) {
            walk(v, root, model_name, index_sets, &mut graph, &mut id_to_addr)?;
        }
    }

    // Pass 3 — derived index sets resolve their from_faq to a node by id, at
    // DOCUMENT scope (esm-spec.md §9.7.5): the producing node may live in any
    // model, since the registry entry naming it is visible to all of them.
    let faq_scope = document_nodes.unwrap_or(&id_to_addr);
    if let Some(is) = index_sets {
        for (name, entry) in is {
            if entry.get("kind").and_then(|v| v.as_str()) == Some("derived") {
                let faq = entry.get("from_faq").and_then(|v| v.as_str());
                match faq.and_then(|f| faq_scope.get(f)) {
                    Some(target) => {
                        // The producer may belong to another model; give this
                        // graph a vertex for it so the edge has a real endpoint.
                        // Idempotent: a local producer was registered in pass 2.
                        graph.ensure_vertex(ReferenceVertex {
                            key: node_key(&target.addr),
                            kind: VertexKind::Node,
                            name: target.addr.clone(),
                            op: target.op.clone(),
                            node_id: faq.map(|s| s.to_string()),
                            path: Some(target.path.clone()),
                        });
                        graph.add_edge(
                            &index_set_key(name),
                            &node_key(&target.addr),
                            EdgeKind::FromFaq,
                        );
                    }
                    None => {
                        return Err(ReferenceResolutionError::UnknownFaqNode {
                            index_set: name.clone(),
                            from_faq: faq.unwrap_or("").to_string(),
                            model: model_name.to_string(),
                        });
                    }
                }
            }
        }
    }

    Ok(graph)
}

/// Resolve reference edges for every model in `document`.
///
/// Returns a `{model_name: ReferenceGraph}` map. Errors on any unresolved
/// reference *or* reference cycle (each model's graph is checked acyclic).
///
/// Node ids are collected from EVERY model first, so a derived index set's
/// `from_faq` may name a producer in any model (esm-spec.md §9.7.5) and a
/// duplicate id anywhere in the document is an error.
pub fn resolve_references(
    document: &Value,
) -> Result<IndexMap<String, ReferenceGraph>, ReferenceResolutionError> {
    let mut out = IndexMap::new();
    let models = match document.get("models").and_then(|v| v.as_object()) {
        Some(m) => m,
        None => return Ok(out),
    };
    // Since v0.8.0 the index_sets registry is document-scoped (a sibling of
    // `models`); thread it down so each model's ranges[*].from resolves.
    let doc_index_sets = document.get("index_sets").and_then(|v| v.as_object());
    let document_nodes = collect_document_node_ids(document)?;
    for (model_name, model) in models {
        let graph =
            build_reference_graph_impl(model, model_name, doc_index_sets, Some(&document_nodes))?;
        if let Some(cyc) = graph.detect_cycle() {
            return Err(ReferenceResolutionError::ReferenceCycle { path: cyc });
        }
        out.insert(model_name.clone(), graph);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn agg(extra: Value) -> Value {
        let mut base = json!({"op": "aggregate", "args": []});
        if let (Some(b), Some(e)) = (base.as_object_mut(), extra.as_object()) {
            for (k, v) in e {
                b.insert(k.clone(), v.clone());
            }
        }
        base
    }

    // (1) from_faq resolves to a specific node ------------------------------

    #[test]
    fn from_faq_resolves_to_node_by_id() {
        let producer = agg(json!({"id": "edge_faq", "output_idx": ["edge"],
                                  "ranges": {"f": {"from": "faces"}}}));
        let model = json!({
            "index_sets": {
                "faces": {"kind": "interval", "size": 8},
                "edges": {"kind": "derived", "from_faq": "edge_faq"}
            },
            "equations": [{"lhs": producer, "rhs": 0}]
        });
        let g = build_reference_graph(&model, "M", None).unwrap();
        let from_faq = g.edges_of_kind(EdgeKind::FromFaq);
        assert_eq!(from_faq.len(), 1);
        assert_eq!(from_faq[0].source, "index_set:edges");
        assert_eq!(from_faq[0].target, "node:edge_faq");
        assert_eq!(
            g.vertices["node:edge_faq"].node_id.as_deref(),
            Some("edge_faq")
        );
        assert!(
            g.dependencies("index_set:edges")
                .contains(&"node:edge_faq".to_string())
        );
    }

    #[test]
    fn from_faq_unknown_node_id_errors() {
        let model = json!({
            "index_sets": {"edges": {"kind": "derived", "from_faq": "missing"}},
            "equations": [{"lhs": agg(json!({"id": "present"})), "rhs": 0}]
        });
        let err = build_reference_graph(&model, "M", None).unwrap_err();
        assert!(matches!(
            err,
            ReferenceResolutionError::UnknownFaqNode { .. }
        ));
    }

    #[test]
    fn duplicate_node_id_errors() {
        let model = json!({
            "equations": [
                {"lhs": agg(json!({"id": "dup"})), "rhs": 0},
                {"lhs": agg(json!({"id": "dup"})), "rhs": 0}
            ]
        });
        let err = build_reference_graph(&model, "M", None).unwrap_err();
        assert!(matches!(
            err,
            ReferenceResolutionError::DuplicateNodeId { .. }
        ));
    }

    // ranges[*].from resolves to an index set -------------------------------

    #[test]
    fn range_from_resolves_to_index_set() {
        let node = agg(json!({"output_idx": ["i"], "ranges": {"i": {"from": "cells"}}}));
        let model = json!({
            "index_sets": {"cells": {"kind": "interval", "size": 4}},
            "equations": [{"lhs": node, "rhs": 0}]
        });
        let g = build_reference_graph(&model, "M", None).unwrap();
        let rf = g.edges_of_kind(EdgeKind::RangeFrom);
        assert_eq!(rf.len(), 1);
        assert_eq!(rf[0].target, "index_set:cells");
        assert!(
            g.dependencies(&rf[0].source)
                .contains(&"index_set:cells".to_string())
        );
    }

    #[test]
    fn range_from_undeclared_index_set_errors() {
        let node = agg(json!({"output_idx": ["i"], "ranges": {"i": {"from": "nope"}}}));
        let model = json!({
            "index_sets": {"cells": {"kind": "interval", "size": 4}},
            "equations": [{"lhs": node, "rhs": 0}]
        });
        let err = build_reference_graph(&model, "M", None).unwrap_err();
        assert!(matches!(
            err,
            ReferenceResolutionError::UndeclaredIndexSet { .. }
        ));
    }

    #[test]
    fn dense_tuple_ranges_make_no_edge() {
        let node = agg(json!({"output_idx": ["i"], "ranges": {"i": [1, 64]}}));
        let model = json!({"equations": [{"lhs": node, "rhs": 0}]});
        let g = build_reference_graph(&model, "M", None).unwrap();
        assert!(g.edges.is_empty());
    }

    // (2) a join factor resolves to its referenced factor -------------------

    #[test]
    fn join_factor_resolves_to_arg_factor() {
        let node = agg(json!({
            "output_idx": ["county"],
            "ranges": {"county": {"from": "county"}, "src": {"from": "sourceType"}},
            "join": [{"on": [["activity", "sourceType"]]}],
            "args": ["activity", "base_rate"]
        }));
        let model = json!({
            "index_sets": {
                "county": {"kind": "categorical", "members": ["A", "B"]},
                "sourceType": {"kind": "categorical", "members": ["x"]}
            },
            "equations": [{"lhs": node, "rhs": 0}]
        });
        let g = build_reference_graph(&model, "M", None).unwrap();
        let jf = g.edges_of_kind(EdgeKind::JoinFactor);
        assert_eq!(jf.len(), 1);
        assert_eq!(jf[0].target, "factor:activity");
        assert_eq!(g.vertices["factor:activity"].kind, VertexKind::Factor);
        assert!(
            g.dependencies(&jf[0].source)
                .contains(&"factor:activity".to_string())
        );
    }

    #[test]
    fn join_factor_resolves_to_range_key() {
        let node = agg(json!({
            "output_idx": ["county"],
            "ranges": {"county": {"from": "county"}, "src": {"from": "sourceType"}},
            "join": [{"on": [["src", "sourceType"]]}],
            "args": ["activity"]
        }));
        let model = json!({
            "index_sets": {
                "county": {"kind": "categorical", "members": ["A"]},
                "sourceType": {"kind": "categorical", "members": ["x"]}
            },
            "equations": [{"lhs": node, "rhs": 0}]
        });
        let g = build_reference_graph(&model, "M", None).unwrap();
        let jf = g.edges_of_kind(EdgeKind::JoinFactor);
        assert_eq!(jf.len(), 1);
        assert_eq!(jf[0].target, "factor:src");
    }

    #[test]
    fn join_factor_unresolved_errors() {
        let node = agg(json!({
            "output_idx": ["i"],
            "ranges": {"i": {"from": "cells"}},
            "join": [{"on": [["ghost", "col"]]}],
            "args": ["activity"]
        }));
        let model = json!({
            "index_sets": {"cells": {"kind": "interval", "size": 2}},
            "equations": [{"lhs": node, "rhs": 0}]
        });
        let err = build_reference_graph(&model, "M", None).unwrap_err();
        assert!(matches!(
            err,
            ReferenceResolutionError::UnresolvedJoinFactor { .. }
        ));
    }

    // (3) edges are queryable by the partition pass -------------------------

    #[test]
    fn graph_is_queryable_topologically() {
        let producer = agg(json!({"id": "edge_faq", "output_idx": ["edge"],
                                  "ranges": {"f": {"from": "faces"}}}));
        let consumer = agg(json!({"output_idx": ["e"], "ranges": {"e": {"from": "edges"}}}));
        let model = json!({
            "index_sets": {
                "faces": {"kind": "interval", "size": 8},
                "edges": {"kind": "derived", "from_faq": "edge_faq"}
            },
            "equations": [{"lhs": producer, "rhs": 0}, {"lhs": consumer, "rhs": 0}]
        });
        let g = build_reference_graph(&model, "M", None).unwrap();
        let order = g.topological_order().unwrap();
        assert_eq!(order.len(), g.vertices.len());
        let pos = |k: &str| order.iter().position(|x| x == k).unwrap();
        assert!(pos("node:edge_faq") < pos("index_set:edges"));
        assert!(g.dependencies("index_set:faces").is_empty());
    }

    // (4) a reference cycle is detectable -----------------------------------

    #[test]
    fn reference_cycle_is_detected() {
        let producer = agg(json!({"id": "edge_faq", "output_idx": ["edge"],
                                  "ranges": {"e": {"from": "edges"}}}));
        let model = json!({
            "index_sets": {"edges": {"kind": "derived", "from_faq": "edge_faq"}},
            "equations": [{"lhs": producer, "rhs": 0}]
        });
        let g = build_reference_graph(&model, "M", None).unwrap();
        let cyc = g.detect_cycle().expect("cycle");
        assert_eq!(cyc.first(), cyc.last());
        assert!(cyc.contains(&"node:edge_faq".to_string()));
        assert!(cyc.contains(&"index_set:edges".to_string()));

        let doc = json!({"models": {"M": model}});
        let err = resolve_references(&doc).unwrap_err();
        assert!(matches!(
            err,
            ReferenceResolutionError::ReferenceCycle { .. }
        ));
    }

    // additive: no references -> empty graph --------------------------------

    #[test]
    fn no_references_empty_graph() {
        let model = json!({
            "variables": {"u": {"type": "unknown"}},
            "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": -1}]
        });
        let g = build_reference_graph(&model, "M", None).unwrap();
        assert!(g.edges.is_empty());
        assert!(g.detect_cycle().is_none());
    }

    #[test]
    fn resolve_references_multi_model() {
        let m1 = json!({
            "index_sets": {"cells": {"kind": "interval", "size": 4}},
            "equations": [{"lhs": agg(json!({"output_idx": ["i"], "ranges": {"i": {"from": "cells"}}})), "rhs": 0}]
        });
        let m2 = json!({"equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": 0}]});
        let doc = json!({"models": {"A": m1, "B": m2}});
        let graphs = resolve_references(&doc).unwrap();
        assert_eq!(graphs.len(), 2);
        assert_eq!(graphs["A"].edges_of_kind(EdgeKind::RangeFrom).len(), 1);
        assert!(graphs["B"].edges.is_empty());
    }

    // Since v0.8.0 the index_sets registry is document-scoped (a sibling of
    // `models`); ranges[*].from must resolve against it even when the model
    // itself declares no index_sets. -------------------------------------

    #[test]
    fn document_scoped_index_sets_resolve() {
        let node = agg(json!({"output_idx": ["i"], "ranges": {"i": {"from": "cells"}}}));
        let doc = json!({
            "index_sets": {"cells": {"kind": "interval", "size": 4}},
            "models": {"M": {"equations": [{"lhs": node, "rhs": 0}]}}
        });
        let graphs = resolve_references(&doc).unwrap();
        let g = &graphs["M"];
        let rf = g.edges_of_kind(EdgeKind::RangeFrom);
        assert_eq!(rf.len(), 1);
        assert_eq!(rf[0].target, "index_set:cells");
        // The document-scoped index set is registered as a vertex too.
        assert!(g.vertices.contains_key("index_set:cells"));
    }

    #[test]
    fn document_and_model_scoped_index_sets_merge() {
        // A `faces` set at the document scope and a `cells` set nested in the
        // model (pre-0.8.0 shape) must both resolve — merge, don't replace.
        let node = agg(json!({
            "output_idx": ["i"],
            "ranges": {"i": {"from": "cells"}, "f": {"from": "faces"}}
        }));
        let doc = json!({
            "index_sets": {"faces": {"kind": "interval", "size": 8}},
            "models": {"M": {
                "index_sets": {"cells": {"kind": "interval", "size": 4}},
                "equations": [{"lhs": node, "rhs": 0}]
            }}
        });
        let graphs = resolve_references(&doc).unwrap();
        let g = &graphs["M"];
        assert_eq!(g.edges_of_kind(EdgeKind::RangeFrom).len(), 2);
        assert!(g.vertices.contains_key("index_set:faces"));
        assert!(g.vertices.contains_key("index_set:cells"));
    }

    /// API_SPEC.md §8 item 17: ONE name, with the document-scoped registry as
    /// an optional TRAILING argument rather than a second function.
    #[test]
    fn document_registry_is_a_trailing_argument() {
        let node = agg(json!({"output_idx": ["i"], "ranges": {"i": {"from": "cells"}}}));
        let model = json!({"equations": [{"lhs": node, "rhs": 0}]});
        let registry: Map<String, Value> = json!({"cells": {"kind": "interval", "size": 4}})
            .as_object()
            .expect("object")
            .clone();

        // Without the registry the range names an undeclared index set.
        let e = build_reference_graph(&model, "M", None).unwrap_err();
        assert!(matches!(
            e,
            ReferenceResolutionError::UndeclaredIndexSet { .. }
        ));

        // With it, the range resolves against the document scope.
        let g = build_reference_graph(&model, "M", Some(&registry)).expect("resolves");
        assert!(g.vertices.contains_key("index_set:cells"));
        assert_eq!(g.edges_of_kind(EdgeKind::RangeFrom).len(), 1);
    }
}
