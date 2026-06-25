//! Cadence-partition pass (`CONFORMANCE_SPEC.md` §5.7, RFC
//! `semiring-faq-unified-ir` §6.1) — the Rust producer.
//!
//! The dependency-partition pass is the ESS analogue of ModelingToolkit's
//! `structural_simplify` / observed-variable elimination, generalised from two
//! phases to three. It classifies **every node** by the *cadence* at which its
//! value can change — `const ⊏ discrete ⊏ continuous`, `class(node) = max` over
//! inputs — and schedules each class into its own phase: a **folded artifact**
//! (`CONST`), a **per-event handler** (`DISCRETE`), and the **hot per-step
//! `_Node` tree** (`CONTINUOUS`). The boundary between phases is *derived* from
//! the data-dependency DAG, never declared.
//!
//! Because the classification is a compile-time property that drives *which code
//! runs in which phase*, two bindings that disagree on a node's class, on the
//! **set of materialization points**, or on the bytes of a **`CONST`-folded
//! buffer** produce *different models* — different hot loops, different
//! per-event work — not merely different formatting. So this is **normative
//! spec**: the cross-binding harness (`scripts/run-cadence-conformance.py`)
//! asserts class-, materialization-, and fold-agreement byte-for-byte against
//! the golden in `tests/conformance/cadence/manifest.json`, and this module is
//! the Rust side of that contract (bead ess-my4.3.8).
//!
//! Topology folds (`edge_enumeration`, `rank`) run through the build-time
//! relational engine ([`crate::relational`], bead ess-my4.3.4) in the
//! `CONST`/`DISCRETE` phase — never on the hot path.

use crate::relational::{Key, canonical_index_set_json, rank, skolem};
use serde_json::{Map, Value};

/// A cadence-partition contract violation in a fixture or producer output (a
/// wrong `expect_cadence`, a `CONTINUOUS` relational node, a `from_faq` cycle, a
/// float topology key, or a malformed node).
#[derive(Debug, Clone, thiserror::Error)]
#[error("{0}")]
pub struct CadenceError(pub String);

fn err(msg: impl Into<String>) -> CadenceError {
    CadenceError(msg.into())
}

/// The cadence lattice (`CONFORMANCE_SPEC.md` §5.7.1): `const ⊏ discrete ⊏
/// continuous`. The derived [`Ord`] **is** the lattice order (variants declared
/// low-to-high), so `class(node) = max` over inputs is just [`Iterator::max`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Cadence {
    /// Never changes — folded into the artifact once. `parameter` / literal.
    Const,
    /// Changes only at discrete events — per-event handler. `discrete` variable.
    Discrete,
    /// Changes every step — hot `_Node` tree. `state` / the independent `t`.
    Continuous,
}

impl Cadence {
    /// The lower-case class tag used in the golden / adapter wire form.
    pub fn as_str(self) -> &'static str {
        match self {
            Cadence::Const => "const",
            Cadence::Discrete => "discrete",
            Cadence::Continuous => "continuous",
        }
    }
}

/// The lattice join (`max`) over cadence classes — the §5.7 propagation rule.
/// Empty (a leaf with no inputs / a nullary op) is `const`.
fn join(classes: impl IntoIterator<Item = Cadence>) -> Cadence {
    classes.into_iter().max().unwrap_or(Cadence::Const)
}

/// The relational / value-invention ops that may not run on the hot path (§5.7
/// guard 2): one classifying `CONTINUOUS` is a hard error. Includes the
/// arg-witness reducers (`argmin`/`argmax`, §5.7 rule 6) — a state-dependent
/// assignment is out of scope for v1, exactly like a state-dependent `distinct`.
const RELATIONAL_OPS: [&str; 6] = ["distinct", "join", "skolem", "rank", "argmin", "argmax"];

// === Leaf seeds + classification ==========================================

/// True iff `var` is a discrete variable whose `data_ingest` refresh names a
/// DataLoader — found in the document's top-level `data_loaders`, attached to the
/// model by [`model_with_loaders`] — that declares no `temporal` block. Such a
/// loader describes non-time-varying data, so its output variable seeds `Const`
/// (folds at bind), not `Discrete` (RFC pure-io-data-loaders §4.6 / §5.7.2).
fn loader_without_temporal(var: &Value, model: &Value) -> bool {
    let refresh = var.get("refresh");
    if refresh.and_then(|r| r.get("kind")).and_then(|v| v.as_str()) != Some("data_ingest") {
        return false;
    }
    let Some(source) = refresh
        .and_then(|r| r.get("source"))
        .and_then(|v| v.as_str())
    else {
        return false;
    };
    match model.get("data_loaders").and_then(|l| l.get(source)) {
        Some(loader) => loader.is_object() && loader.get("temporal").is_none(),
        None => false,
    }
}

/// Seed a leaf's cadence from its declared role (§5.7.2 leaf-seed table):
/// `state` → continuous, `parameter` / literal → const, `discrete` → discrete.
/// The independent variable `t` is continuous (an explicit continuous-`t`
/// forcing is not piecewise-constant between events). Index-set names, bound
/// index symbols, relation tags, and numeric literals are all `CONST`.
pub fn seed_leaf(leaf: &Value, model: &Value) -> Result<Cadence, CadenceError> {
    match leaf {
        // A numeric literal (int or float) is CONST. JSON booleans are not
        // valid value leaves (they only appear as op bodies like `{op:"true"}`).
        Value::Number(_) => Ok(Cadence::Const),
        Value::String(s) => {
            if s == "t" {
                return Ok(Cadence::Continuous);
            }
            if let Some(var) = model.get("variables").and_then(|v| v.get(s)) {
                let kind = var.get("type").and_then(|v| v.as_str());
                return match kind {
                    Some("state") | Some("brownian") => Ok(Cadence::Continuous),
                    // Loader-seeded refinement (§5.7.2): a discrete variable fed
                    // by a `data_ingest` refresh whose source loader has no
                    // `temporal` block is non-time-varying → CONST (folds at
                    // bind). Otherwise it keeps the declared DISCRETE seed.
                    Some("discrete") => Ok(if loader_without_temporal(var, model) {
                        Cadence::Const
                    } else {
                        Cadence::Discrete
                    }),
                    // parameter = CONST. An `observed` leaf would resolve to its
                    // defining expression's class elsewhere; none of the §6.1
                    // fixtures read one as a leaf, so CONST is the conservative
                    // seed (matching the reference classifier).
                    Some("parameter") | Some("observed") => Ok(Cadence::Const),
                    other => Err(err(format!("leaf {s:?}: unknown variable kind {other:?}"))),
                };
            }
            // index-set name, bound index symbol (i, k, e, f, le), relation tag
            // ("edge"), or numeric-string literal — all CONST topology.
            Ok(Cadence::Const)
        }
        other => Err(err(format!("unexpected leaf {other}"))),
    }
}

/// Every sub-Expression of a node: the operand list `args` plus the
/// aggregate/integral sub-fields. `output_idx`, `ranges`, `wrt`, `dim`, `var`
/// are index/metadata declarations (const), not value inputs — excluded.
fn child_exprs(node: &Map<String, Value>) -> Vec<&Value> {
    let mut out = Vec::new();
    if let Some(Value::Array(args)) = node.get("args") {
        out.extend(args.iter());
    }
    for field in ["expr", "key", "filter", "lower", "upper"] {
        if let Some(v) = node.get(field) {
            out.push(v);
        }
    }
    out
}

/// Derive a node's cadence class. For a leaf, seed it. For an operator node,
/// `class = max` over child classes — which, for a gather `index(A, e…)`, is
/// `max(class(A), class(e…))`: the index expressions are classed
/// **independently of the array**, so a stencil splits (§5.7.3 gather rule).
pub fn classify(node: &Value, model: &Value) -> Result<Cadence, CadenceError> {
    let Value::Object(map) = node else {
        return seed_leaf(node, model);
    };
    let mut classes = Vec::new();
    for c in child_exprs(map) {
        classes.push(classify(c, model)?);
    }
    Ok(join(classes))
}

/// Walk the tree; wherever a node carries `expect_cadence`, assert the derived
/// class agrees (§5.7.6 guard 3 — the author assertion). Collects every
/// mismatch into `problems` rather than failing fast, so a fixture's annotations
/// are all reported at once.
pub fn check_expect_cadence(
    node: &Value,
    model: &Value,
    problems: &mut Vec<String>,
) -> Result<(), CadenceError> {
    let Value::Object(map) = node else {
        return Ok(());
    };
    if let Some(want) = map.get("expect_cadence").and_then(|v| v.as_str()) {
        let derived = classify(node, model)?;
        if derived.as_str() != want {
            problems.push(format!(
                "expect_cadence mismatch on op={:?}: declared {:?} but derived {:?}",
                map.get("op").and_then(|v| v.as_str()),
                want,
                derived.as_str()
            ));
        }
    }
    for c in child_exprs(map) {
        check_expect_cadence(c, model, problems)?;
    }
    Ok(())
}

/// Count annotated nodes (those carrying `expect_cadence`) by derived class —
/// the golden `class_summary`.
pub fn tally_classes(
    node: &Value,
    model: &Value,
    counts: &mut ClassSummary,
) -> Result<(), CadenceError> {
    let Value::Object(map) = node else {
        return Ok(());
    };
    if map.contains_key("expect_cadence") {
        counts.bump(classify(node, model)?);
    }
    for c in child_exprs(map) {
        tally_classes(c, model, counts)?;
    }
    Ok(())
}

/// `true` iff `node` or any of its descendants classifies `CONTINUOUS` (used to
/// decide whether an equation contributes to the hot per-step tree).
pub fn has_continuous(node: &Value, model: &Value) -> Result<bool, CadenceError> {
    if let Value::Object(map) = node {
        if classify(node, model)? == Cadence::Continuous {
            return Ok(true);
        }
        for c in child_exprs(map) {
            if has_continuous(c, model)? {
                return Ok(true);
            }
        }
        Ok(false)
    } else {
        Ok(seed_leaf(node, model)? == Cadence::Continuous)
    }
}

// === Materialization frontier =============================================

/// An expression-edge cadence drop: a lower-cadence child feeding a
/// higher-cadence parent (§5.7.4). The maximal lower-cadence sub-DAG below the
/// edge is the materialization point.
#[derive(Debug, Clone)]
pub struct ExprEdge {
    /// The cadence drop, e.g. `"const->continuous"` / `"discrete->continuous"`.
    pub threshold: String,
    /// The boundary node's `op` (diagnostic).
    pub op: Option<String>,
}

/// Derive the expr-edge materialization frontier of `node`: a DICT child whose
/// class is strictly lower than its parent's is a materialization point (the
/// maximal lower-cadence sub-DAG below that edge is cut, stored in a buffer,
/// referenced by the parent). We record the boundary and do **not** recurse into
/// it — its descendants are inside the buffer. A bare scalar-constant LEAF is
/// not a buffer (scalar inlining is excluded by the dict-only test).
pub fn materialization_frontier(
    node: &Value,
    model: &Value,
    out: &mut Vec<ExprEdge>,
) -> Result<(), CadenceError> {
    let Value::Object(map) = node else {
        return Ok(());
    };
    let parent = classify(node, model)?;
    for c in child_exprs(map) {
        let Value::Object(child_map) = c else {
            continue;
        };
        let cc = classify(c, model)?;
        if cc < parent {
            out.push(ExprEdge {
                threshold: format!("{}->{}", cc.as_str(), parent.as_str()),
                op: child_map
                    .get("op")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
            });
        } else {
            materialization_frontier(c, model, out)?;
        }
    }
    Ok(())
}

// === Guards ===============================================================

/// §5.7.6 guard 2: a `distinct`/`join`/`skolem`/`rank` node (or a `distinct`
/// aggregate) that classifies `CONTINUOUS` is rejected — state-dependent
/// topology may not run per step in v1.
pub fn assert_no_continuous_relational(node: &Value, model: &Value) -> Result<(), CadenceError> {
    let Value::Object(map) = node else {
        return Ok(());
    };
    let op = map.get("op").and_then(|v| v.as_str());
    let is_relational = op.is_some_and(|o| RELATIONAL_OPS.contains(&o))
        || (op == Some("aggregate")
            && map
                .get("distinct")
                .and_then(|v| v.as_bool())
                .unwrap_or(false));
    if is_relational && classify(node, model)? == Cadence::Continuous {
        return Err(err(format!(
            "relational/value-invention node op={op:?} classifies CONTINUOUS — it may \
             not run on the hot path (§5.7 guard 2). A state-dependent \
             distinct/join/skolem/rank is out of scope for v1."
        )));
    }
    for c in child_exprs(map) {
        assert_no_continuous_relational(c, model)?;
    }
    Ok(())
}

/// §5.7.6 guard 1: the `≤DISCRETE` subgraph must be a DAG. A derived index set
/// points (via `from_faq`) at the node that materializes it; that node
/// references index sets (via `ranges {from}`); a cycle in those edges is an
/// implicit/iterative solve, out of scope. Reject naming the cycle.
pub fn assert_acyclic_index_sets(model: &Value) -> Result<(), CadenceError> {
    use std::collections::{BTreeMap, BTreeSet};

    // Map each aggregate node id → the index sets it reads (ranges {from}).
    let mut node_reads: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    fn collect(node: &Value, node_reads: &mut BTreeMap<String, BTreeSet<String>>) {
        let Value::Object(map) = node else {
            return;
        };
        if let Some(nid) = map.get("id").and_then(|v| v.as_str()) {
            let reads = node_reads.entry(nid.to_string()).or_default();
            if let Some(Value::Object(ranges)) = map.get("ranges") {
                for r in ranges.values() {
                    if let Some(from) = r.get("from").and_then(|v| v.as_str()) {
                        reads.insert(from.to_string());
                    }
                }
            }
        }
        for c in child_exprs(map) {
            collect(c, node_reads);
        }
    }
    if let Some(eqs) = model.get("equations").and_then(|v| v.as_array()) {
        for eq in eqs {
            if let Some(lhs) = eq.get("lhs") {
                collect(lhs, &mut node_reads);
            }
            if let Some(rhs) = eq.get("rhs") {
                collect(rhs, &mut node_reads);
            }
        }
    }

    // Edges: set --(from_faq)--> node --(reads)--> set.
    let mut set_to_node: BTreeMap<String, String> = BTreeMap::new();
    if let Some(Value::Object(sets)) = model.get("index_sets") {
        for (name, s) in sets {
            if s.get("kind").and_then(|v| v.as_str()) == Some("derived")
                && let Some(node_id) = s.get("from_faq").and_then(|v| v.as_str())
            {
                set_to_node.insert(name.clone(), node_id.to_string());
            }
        }
    }

    // DFS over set → from_faq node → read sets → … detecting a back-edge.
    #[derive(Clone, Copy, PartialEq)]
    enum Color {
        Gray,
        Black,
    }
    let mut color: BTreeMap<String, Color> = BTreeMap::new();
    fn visit(
        name: &str,
        stack: &mut Vec<String>,
        color: &mut std::collections::BTreeMap<String, Color>,
        set_to_node: &std::collections::BTreeMap<String, String>,
        node_reads: &std::collections::BTreeMap<String, std::collections::BTreeSet<String>>,
    ) -> Result<(), CadenceError> {
        color.insert(name.to_string(), Color::Gray);
        stack.push(name.to_string());
        if let Some(node_id) = set_to_node.get(name)
            && let Some(reads) = node_reads.get(node_id)
        {
            for nxt in reads {
                if !set_to_node.contains_key(nxt) {
                    continue; // only derived sets participate in the topology DAG
                }
                match color.get(nxt) {
                    Some(Color::Gray) => {
                        let from = stack.iter().position(|n| n == nxt).unwrap_or(0);
                        let mut cyc: Vec<String> = stack[from..].to_vec();
                        cyc.push(nxt.clone());
                        return Err(err(format!(
                            "cycle in the ≤DISCRETE index-set dependency graph \
                             (implicit solve, out of scope — §5.7 guard 1): {}",
                            cyc.join(" -> ")
                        )));
                    }
                    Some(Color::Black) => {}
                    None => visit(nxt, stack, color, set_to_node, node_reads)?,
                }
            }
        }
        stack.pop();
        color.insert(name.to_string(), Color::Black);
        Ok(())
    }
    for name in set_to_node.keys() {
        if !color.contains_key(name) {
            visit(name, &mut Vec::new(), &mut color, &set_to_node, &node_reads)?;
        }
    }
    Ok(())
}

// === CONST-fold kernels ===================================================

/// The canonical byte form of a folded buffer: compact JSON (`,` / `:`
/// separators, no spaces), UTF-8 (no `\uXXXX`), arrays for tuples — the same
/// canonical-JSON discipline §5.5.3 / the round-trip contract require. This is
/// what "byte-identical CONST-folded buffer" means. `serde_json`'s default
/// serializer already emits this compact form.
pub fn canonical_serialize(value: &Value) -> String {
    serde_json::to_string(value).expect("serialising a JSON value never fails")
}

/// Subtract 1 from every component of a 2-D integer array (a 1-based neighbour
/// index table folded to the 0-based array backend).
fn fold_to_zero_based(arr: &Value) -> Result<Value, CadenceError> {
    let rows = arr
        .as_array()
        .ok_or_else(|| err("to_zero_based: expected a 2-D array"))?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let cells = row
            .as_array()
            .ok_or_else(|| err("to_zero_based: expected an array of rows"))?;
        let mut orow = Vec::with_capacity(cells.len());
        for x in cells {
            let n = x
                .as_i64()
                .ok_or_else(|| err(format!("to_zero_based: non-integer component {x}")))?;
            orow.push(Value::from(n - 1));
        }
        out.push(Value::Array(orow));
    }
    Ok(Value::Array(out))
}

/// Enumerate the unique edges from the `(lo, hi)` endpoint tables, through the
/// build-time relational engine (ess-my4.3.4): `skolem` canonicalises each pair
/// (undirected → sorted), `distinct` sorts by the §5.5 total order and drops
/// adjacent duplicates. Identical to the determinism `edge_enumeration`
/// reference; `Key::try_from_json` rejects a float component (§5.5 rule 1).
fn edge_keys(face_lo: &Value, face_hi: &Value, mode: &str) -> Result<Vec<Key>, CadenceError> {
    let symmetric = mode == "undirected";
    let los = face_lo
        .as_array()
        .ok_or_else(|| err("edge_enumeration: face_lo must be a 2-D array"))?;
    let his = face_hi
        .as_array()
        .ok_or_else(|| err("edge_enumeration: face_hi must be a 2-D array"))?;
    let mut keys = Vec::new();
    for (f_lo, f_hi) in los.iter().zip(his.iter()) {
        let lo_cells = f_lo
            .as_array()
            .ok_or_else(|| err("edge_enumeration: face_lo row must be an array"))?;
        let hi_cells = f_hi
            .as_array()
            .ok_or_else(|| err("edge_enumeration: face_hi row must be an array"))?;
        for (lo, hi) in lo_cells.iter().zip(hi_cells.iter()) {
            let klo = Key::try_from_json(lo).map_err(|e| {
                err(format!(
                    "float component forbidden in a topology key (§5.5 rule 1): {e}"
                ))
            })?;
            let khi = Key::try_from_json(hi).map_err(|e| {
                err(format!(
                    "float component forbidden in a topology key (§5.5 rule 1): {e}"
                ))
            })?;
            keys.push(skolem(vec![klo, khi], symmetric));
        }
    }
    Ok(keys)
}

/// Compute a single CONST-folded buffer and return its **canonical byte form**.
/// `label` is the buffer name (the default array key when `spec.array` is
/// absent); `spec` is the golden's per-buffer fold descriptor (`fold` kind +
/// optional `array`); `inputs` is the CONST-fold input block (the document
/// literals — the fixtures are value-free, so the values live in the manifest).
pub fn compute_fold(label: &str, spec: &Value, inputs: &Value) -> Result<String, CadenceError> {
    let kind = spec
        .get("fold")
        .and_then(|v| v.as_str())
        .ok_or_else(|| err(format!("buffer {label:?}: missing fold kind")))?;
    let input = |name: &str| {
        inputs
            .get(name)
            .ok_or_else(|| err(format!("buffer {label:?}: missing fold input {name:?}")))
    };
    let array_name = spec.get("array").and_then(|v| v.as_str()).unwrap_or(label);
    let mode = inputs
        .get("skolem")
        .and_then(|v| v.as_str())
        .unwrap_or("undirected");
    match kind {
        "to_zero_based" => Ok(canonical_serialize(&fold_to_zero_based(input(
            array_name,
        )?)?)),
        "identity" => Ok(canonical_serialize(input(array_name)?)),
        "edge_enumeration" => {
            let keys = edge_keys(input("face_lo")?, input("face_hi")?, mode)?;
            // The relational engine's canonical index-set serialiser distincts
            // and emits the §5.5.3 byte form directly.
            Ok(canonical_index_set_json(&keys))
        }
        "rank" => {
            let keys = edge_keys(input("face_lo")?, input("face_hi")?, mode)?;
            let ids: Vec<Value> = rank(&keys)
                .canonical_dense_ids()
                .into_iter()
                .map(Value::from)
                .collect();
            Ok(canonical_serialize(&Value::Array(ids)))
        }
        other => Err(err(format!(
            "buffer {label:?}: unknown fold kind {other:?}"
        ))),
    }
}

// === High-level per-model partition (for the adapter + tests) =============

/// Annotated-node counts by derived class — the golden `class_summary`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ClassSummary {
    /// `CONST` nodes.
    pub const_: u64,
    /// `DISCRETE` nodes.
    pub discrete: u64,
    /// `CONTINUOUS` nodes.
    pub continuous: u64,
}

impl ClassSummary {
    fn bump(&mut self, c: Cadence) {
        match c {
            Cadence::Const => self.const_ += 1,
            Cadence::Discrete => self.discrete += 1,
            Cadence::Continuous => self.continuous += 1,
        }
    }

    /// The `{"const":_, "discrete":_, "continuous":_}` wire form.
    pub fn to_json(&self) -> Value {
        serde_json::json!({
            "const": self.const_,
            "discrete": self.discrete,
            "continuous": self.continuous,
        })
    }
}

/// A materialization point: where the frontier cut fires (§5.7.4). Either an
/// `expr_edge` cadence drop inside a hot/per-event RHS, or an `output_buffer` —
/// a top-level CONST equation whose entire output folds into the artifact.
#[derive(Debug, Clone)]
pub struct MaterializationPoint {
    /// A human label (the node `id` or LHS target), if derivable.
    pub label: Option<String>,
    /// `"expr_edge"` or `"output_buffer"`.
    pub kind: &'static str,
    /// The cadence drop, e.g. `"const->continuous"` / `"const->artifact"`.
    pub threshold: String,
}

/// The partition of one model: the class summary, the materialization-point set,
/// and the hot-tree / per-event-handler emptiness (§5.7.5 three execution
/// outputs). Guards (§5.7.6) are checked during [`partition_model`]; a violation
/// is an `Err`.
#[derive(Debug, Clone)]
pub struct Partition {
    /// Annotated-node class counts.
    pub class_summary: ClassSummary,
    /// Where the frontier cut fires.
    pub materialization_points: Vec<MaterializationPoint>,
    /// `true` iff no equation contributes a per-step (`CONTINUOUS`) term.
    pub hot_tree_empty: bool,
    /// `true` iff nothing is event-driven (`DISCRETE`).
    pub event_handler_empty: bool,
}

/// Best-effort label for a top-level output buffer: the producing node `id`, or
/// the LHS target variable name.
fn output_label(eq: &Value, rhs: &Map<String, Value>) -> Option<String> {
    if let Some(id) = rhs.get("id").and_then(|v| v.as_str()) {
        return Some(id.to_string());
    }
    // LHS `index(var, …)` → the target variable name.
    let lhs = eq.get("lhs")?;
    let args = lhs.get("args").and_then(|v| v.as_array())?;
    args.first().and_then(|v| v.as_str()).map(str::to_string)
}

/// Attach the document's top-level `data_loaders` to a model object so the
/// loader-seeded cadence refinement (§5.7.2) can resolve a `discrete` variable's
/// `data_ingest` source loader (DISCRETE if it has `temporal`, else CONST).
/// Returns a clone of `model` with `data_loaders` inserted; if the document
/// declares none — or the model already carries them — the model is unchanged.
pub fn model_with_loaders(model: &Value, doc: &Value) -> Value {
    let mut model = model.clone();
    if let (Value::Object(map), Some(loaders)) = (&mut model, doc.get("data_loaders")) {
        map.entry("data_loaders".to_string())
            .or_insert_with(|| loaders.clone());
    }
    model
}

/// Run the cadence-partition pass over one model: classify every annotated node,
/// derive the materialization frontier (both thresholds), check the guards
/// (expect-cadence agreement, no `CONTINUOUS` relational, acyclic `≤DISCRETE`
/// graph), and report the three execution outputs' emptiness. The model is the
/// inner `models.<name>` object (use [`model_with_loaders`] to attach the
/// document's `data_loaders` first when the model reads loader-seeded variables).
pub fn partition_model(model: &Value) -> Result<Partition, CadenceError> {
    let empty = Vec::new();
    let equations = model
        .get("equations")
        .and_then(|v| v.as_array())
        .unwrap_or(&empty);

    // Guard 3 (author assertions) — collect all mismatches, fail if any.
    let mut problems = Vec::new();
    for eq in equations {
        if let Some(rhs) = eq.get("rhs") {
            check_expect_cadence(rhs, model, &mut problems)?;
        }
    }
    if !problems.is_empty() {
        return Err(err(problems.join("; ")));
    }

    // Guard 2 (no CONTINUOUS relational on the hot path) + guard 1 (acyclic).
    for eq in equations {
        if let Some(rhs) = eq.get("rhs") {
            assert_no_continuous_relational(rhs, model)?;
        }
    }
    assert_acyclic_index_sets(model)?;

    let mut class_summary = ClassSummary::default();
    let mut materialization_points = Vec::new();
    let mut hot_tree_empty = true;

    for eq in equations {
        let Some(rhs) = eq.get("rhs") else { continue };
        let Value::Object(rhs_map) = rhs else {
            continue;
        };

        tally_classes(rhs, model, &mut class_summary)?;
        if has_continuous(rhs, model)? {
            hot_tree_empty = false;
        }

        // expr-edge frontier (cadence drops inside the RHS). Empty for a CONST
        // root — there is nothing below `const`.
        let mut edges = Vec::new();
        materialization_frontier(rhs, model, &mut edges)?;
        for e in edges {
            materialization_points.push(MaterializationPoint {
                label: e.op.clone(),
                kind: "expr_edge",
                threshold: e.threshold,
            });
        }

        // A top-level CONST equation folds entirely into the artifact: its
        // output is a `const->artifact` buffer (§5.7.5 output 1). DISCRETE /
        // CONTINUOUS roots are the per-event handler / hot tree, handled by the
        // expr-edge frontier above.
        if classify(rhs, model)? == Cadence::Const {
            materialization_points.push(MaterializationPoint {
                label: output_label(eq, rhs_map),
                kind: "output_buffer",
                threshold: "const->artifact".to_string(),
            });
        }
    }

    // The per-event handler is empty iff nothing is DISCRETE-driven: no
    // `discrete->…` expr-edge drop and no DISCRETE-classified annotated node.
    let event_handler_empty = class_summary.discrete == 0
        && !materialization_points
            .iter()
            .any(|m| m.threshold.starts_with("discrete"));

    Ok(Partition {
        class_summary,
        materialization_points,
        hot_tree_empty,
        event_handler_empty,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const MIXED: &str = include_str!("../../../tests/valid/cadence/mixed_stencil.esm");
    const TOPOLOGY: &str = include_str!("../../../tests/valid/cadence/pure_topology.esm");
    const POINTWISE: &str = include_str!("../../../tests/valid/cadence/pure_pointwise.esm");

    fn model(fixture: &str, name: &str) -> Value {
        let doc: Value = serde_json::from_str(fixture).expect("fixture parses");
        doc["models"][name].clone()
    }

    fn thresholds(p: &Partition) -> Vec<String> {
        let mut t: Vec<String> = p
            .materialization_points
            .iter()
            .map(|m| m.threshold.clone())
            .collect();
        t.sort();
        t
    }

    #[test]
    fn mixed_stencil_classes_and_frontier() {
        let m = model(MIXED, "MixedStencilDiffusion");
        let p = partition_model(&m).expect("partition");
        assert_eq!(
            p.class_summary,
            ClassSummary {
                const_: 2,
                discrete: 1,
                continuous: 6
            }
        );
        // The gather splits: nbr + coeff fold at CONST->CONTINUOUS, Kdiff
        // materialises at DISCRETE->CONTINUOUS.
        assert_eq!(
            thresholds(&p),
            vec![
                "const->continuous",
                "const->continuous",
                "discrete->continuous"
            ]
        );
        assert!(!p.hot_tree_empty);
        assert!(!p.event_handler_empty);
    }

    #[test]
    fn pure_topology_all_const_empty_hot_tree() {
        let m = model(TOPOLOGY, "PureTopologyEdges");
        let p = partition_model(&m).expect("partition");
        assert_eq!(
            p.class_summary,
            ClassSummary {
                const_: 6,
                discrete: 0,
                continuous: 0
            }
        );
        assert_eq!(thresholds(&p), vec!["const->artifact", "const->artifact"]);
        assert!(p.hot_tree_empty);
        assert!(p.event_handler_empty);
    }

    #[test]
    fn pure_pointwise_all_continuous_no_materialization() {
        let m = model(POINTWISE, "PurePointwiseForcing");
        let p = partition_model(&m).expect("partition");
        assert_eq!(
            p.class_summary,
            ClassSummary {
                const_: 0,
                discrete: 0,
                continuous: 6
            }
        );
        assert!(p.materialization_points.is_empty());
        assert!(!p.hot_tree_empty);
        assert!(p.event_handler_empty);
    }

    #[test]
    fn gather_split_is_independent_of_the_array() {
        // index(u, index(nbr,i,k)): outer load CONTINUOUS, inner topology CONST.
        let m = model(MIXED, "MixedStencilDiffusion");
        let outer = json!({
            "op": "index",
            "args": ["u", {"op": "index", "args": ["nbr", "i", "k"]}]
        });
        let inner = json!({"op": "index", "args": ["nbr", "i", "k"]});
        assert_eq!(classify(&outer, &m).unwrap(), Cadence::Continuous);
        assert_eq!(classify(&inner, &m).unwrap(), Cadence::Const);
    }

    #[test]
    fn loader_temporal_seeds_discrete_no_temporal_seeds_const() {
        // §5.7.2 / RFC pure-io-data-loaders §4.6: a discrete variable fed by a
        // `data_ingest` refresh resolves through its source loader's `temporal`
        // block — DISCRETE when the loader is time-varying, CONST (folds at bind)
        // when it is not. The SAME variable declaration; only the loader differs.
        let variables = json!({
            "c": {"type": "state", "shape": ["cells"]},
            "bc": {"type": "discrete", "shape": ["cells"],
                   "refresh": {"kind": "data_ingest", "source": "bc_loader"}}
        });
        let bc = json!({"op": "index", "args": ["bc", "i"]});

        // Loader WITH temporal → DISCRETE (refreshes on each ingest).
        let with_temporal = json!({
            "variables": variables.clone(),
            "data_loaders": {"bc_loader": {"kind": "grid", "temporal": {"frequency": "PT6H"}}}
        });
        assert_eq!(classify(&bc, &with_temporal).unwrap(), Cadence::Discrete);

        // Loader WITHOUT temporal → CONST (non-time-varying, folds at bind).
        let no_temporal = json!({
            "variables": variables.clone(),
            "data_loaders": {"bc_loader": {"kind": "static"}}
        });
        assert_eq!(classify(&bc, &no_temporal).unwrap(), Cadence::Const);

        // No loaders attached / unresolvable source → keeps the declared DISCRETE
        // seed (the conservative default).
        let bare = json!({ "variables": variables });
        assert_eq!(classify(&bc, &bare).unwrap(), Cadence::Discrete);
    }

    #[test]
    fn model_with_loaders_attaches_top_level_loaders() {
        let doc = json!({
            "models": {"M": {"variables": {}, "equations": []}},
            "data_loaders": {"bc_loader": {"kind": "static"}}
        });
        let model = model_with_loaders(&doc["models"]["M"], &doc);
        assert!(
            model
                .get("data_loaders")
                .and_then(|l| l.get("bc_loader"))
                .is_some()
        );
        // A document with no loaders leaves the model untouched.
        let doc2 = json!({ "models": {"M": {"variables": {}}} });
        let model2 = model_with_loaders(&doc2["models"]["M"], &doc2);
        assert!(model2.get("data_loaders").is_none());
    }

    #[test]
    fn const_folds_are_byte_identical_to_golden() {
        // mixed_stencil: nbr_idx (to_zero_based), coeff (identity).
        let nbr = json!([[2, 4, 1], [3, 1, 2], [4, 2, 3], [1, 3, 4]]);
        let coeff = json!([[1, 1, 0], [1, 1, 0], [1, 1, 0], [1, 1, 0]]);
        let inputs = json!({ "nbr": nbr, "coeff": coeff });
        assert_eq!(
            compute_fold(
                "nbr_idx",
                &json!({"fold": "to_zero_based", "array": "nbr"}),
                &inputs
            )
            .unwrap(),
            "[[1,3,0],[2,0,1],[3,1,2],[0,2,3]]"
        );
        assert_eq!(
            compute_fold("coeff", &json!({"fold": "identity"}), &inputs).unwrap(),
            "[[1,1,0],[1,1,0],[1,1,0],[1,1,0]]"
        );

        // pure_topology: edges (edge_enumeration), edge_dense_id (rank).
        let topo = json!({
            "face_lo": [[1, 2, 3], [3, 2, 4]],
            "face_hi": [[2, 3, 1], [2, 4, 3]],
            "skolem": "undirected"
        });
        assert_eq!(
            compute_fold("edges", &json!({"fold": "edge_enumeration"}), &topo).unwrap(),
            "[[1,2],[1,3],[2,3],[2,4],[3,4]]"
        );
        assert_eq!(
            compute_fold("edge_dense_id", &json!({"fold": "rank"}), &topo).unwrap(),
            "[0,1,2,3,4]"
        );
    }

    #[test]
    fn guards_pass_on_the_good_fixtures() {
        for (fx, name) in [
            (MIXED, "MixedStencilDiffusion"),
            (TOPOLOGY, "PureTopologyEdges"),
            (POINTWISE, "PurePointwiseForcing"),
        ] {
            let m = model(fx, name);
            // partition_model runs every guard; a false positive would Err here.
            partition_model(&m).expect("guards must not reject a valid fixture");
        }
    }

    // --- Negative controls (mirror run-cadence-conformance.py _negative_controls) ---

    #[test]
    fn neg_wrong_expect_cadence_is_flagged() {
        // Flip the CONST coeff gather to `continuous`: the derived class (const)
        // now disagrees with the assertion.
        let mut m = model(MIXED, "MixedStencilDiffusion");
        let coeff_node = &mut m["equations"][0]["rhs"]["expr"]["args"][1]["args"][0];
        assert_eq!(coeff_node["expect_cadence"], json!("const"));
        coeff_node["expect_cadence"] = json!("continuous");
        let mut problems = Vec::new();
        check_expect_cadence(&m["equations"][0]["rhs"], &m, &mut problems).unwrap();
        assert!(
            !problems.is_empty(),
            "a wrong expect_cadence must be flagged"
        );
    }

    #[test]
    fn neg_continuous_relational_is_rejected() {
        // A distinct aggregate whose key reads state `u` classifies CONTINUOUS.
        let bad = json!({
            "variables": {"u": {"type": "state"}, "lo": {"type": "parameter"}},
            "index_sets": {"faces": {"kind": "interval", "size": 4}},
            "equations": [{
                "lhs": {"op": "index", "args": ["edge_exists", "e"]},
                "rhs": {
                    "op": "aggregate", "distinct": true, "semiring": "bool_and_or",
                    "output_idx": ["e"], "ranges": {"f": {"from": "faces"}},
                    "key": {"op": "skolem", "args": ["edge", {"op": "index", "args": ["u", "f"]}]},
                    "expr": {"op": "true", "args": []}
                }
            }]
        });
        let rhs = &bad["equations"][0]["rhs"];
        assert!(
            assert_no_continuous_relational(rhs, &bad).is_err(),
            "guard 2 must reject a state-dependent distinct"
        );
    }

    #[test]
    fn neg_from_faq_cycle_is_rejected() {
        let cyclic = json!({
            "variables": {},
            "index_sets": {
                "setA": {"kind": "derived", "from_faq": "nodeA"},
                "setB": {"kind": "derived", "from_faq": "nodeB"}
            },
            "equations": [
                {"lhs": {"op": "index", "args": ["a", "x"]},
                 "rhs": {"op": "aggregate", "id": "nodeA", "distinct": true,
                         "semiring": "bool_and_or", "output_idx": ["x"],
                         "ranges": {"y": {"from": "setB"}},
                         "expr": {"op": "true", "args": []}}},
                {"lhs": {"op": "index", "args": ["b", "x"]},
                 "rhs": {"op": "aggregate", "id": "nodeB", "distinct": true,
                         "semiring": "bool_and_or", "output_idx": ["x"],
                         "ranges": {"y": {"from": "setA"}},
                         "expr": {"op": "true", "args": []}}}
            ]
        });
        assert!(
            assert_acyclic_index_sets(&cyclic).is_err(),
            "guard 1 must reject a from_faq cycle"
        );
    }

    #[test]
    fn neg_float_topology_key_is_rejected() {
        let topo = json!({"face_lo": [[1.5]], "face_hi": [[2]], "skolem": "undirected"});
        assert!(
            compute_fold("edges", &json!({"fold": "edge_enumeration"}), &topo).is_err(),
            "a float topology key must be rejected (§5.5 rule 1)"
        );
    }
}
