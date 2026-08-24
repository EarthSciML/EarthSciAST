#!/usr/bin/env node
/**
 * Generate the cross-language GRAPH conformance corpus.
 *
 * The TypeScript `componentGraph` / `expressionGraph` (pkg/earthsci-ast-ts) is
 * the ORACLE. It was chosen on three grounds, in this order:
 *
 *   1. THE SPEC. esm-libraries-spec §4.8 fixes the two points on which the five
 *      bindings actually disagreed in substance, and TypeScript is on the spec's
 *      side of both:
 *        - §4.8.1: "A `data_sources` entry is not a component and is NOT a
 *          node". Rust and Julia emitted one; TypeScript, Go and Python do not.
 *        - §4.8.2: `kind: "state" | "parameter" | "observed" | "species"`. Go
 *          spells these `ode_state` / `sampled` / `constant` (the §6.3.1
 *          CLASSIFIER names, which are a finer partition than the graph's) and
 *          Julia emitted the DECLARED type `unknown`, which is in no vocabulary.
 *        - §4.8.2 also lists `NO → NO` / `O₃ → O₃` self-loss edges explicitly,
 *          so an implementation that drops self-loops (Go, Julia) is wrong.
 *   2. MAJORITY OF THE 1.0.0-CURRENT BINDINGS. Where the spec is silent
 *      (`variable_map` label text, `equation_index` base, subsystem recursion,
 *      fabrication of nodes for undeclared equation variables) TypeScript and
 *      Python agree and are the two bindings carrying the 1.0.0 model.
 *   3. It is the reference printer for the expression-parse corpus, so a porter
 *      has one oracle to hold in their head rather than two.
 *
 * WHAT IS PINNED. The SEMANTIC graph model: the component node set with its
 * types and summary counts, the coupling edge set with its types and labels,
 * the variable node set with its derived kinds / units / owning systems, the
 * dependency edge set with its relationships and equation indices, and the
 * adjacency / predecessor / successor closure. Also the JSON adjacency-list
 * export, which esm-libraries-spec §4.8.3 names by structure ("JSON adjacency
 * list").
 *
 * WHAT IS DELIBERATELY NOT PINNED. The DOT and Mermaid BYTES. §4.8.3 requires
 * both formats but specifies neither one's syntax, and the five bindings do not
 * split in a way any rule here resolves: TypeScript emits `digraph {` +
 * `flowchart TD` while Python, Go, Rust and Julia all emit
 * `digraph ComponentGraph` — so the majority rule points AWAY from the oracle —
 * and those four then disagree with each other on the Mermaid header
 * (`graph TD` vs `graph LR`) and on every node/edge line's shapes, colours and
 * label text. Choosing here would be picking a house style, not resolving a
 * conformance question, so the corpus does not pretend to have an answer. See
 * tests/conformance/graph/README.md.
 *
 * Regenerate with:  node scripts/generate-graph-corpus.mjs
 * (Build the TS package first — this reads pkg/earthsci-ast-ts/dist.)
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const TS = join(ROOT, 'pkg/earthsci-ast-ts/dist/esm/index.js')
const OUT_DIR = join(ROOT, 'tests/conformance/graph')

const { componentGraph, expressionGraph, toJsonGraph, loadString } = await import(TS)

/**
 * Whole-document cases. Each names a fixture under tests/valid/ and the reason
 * it earns a slot, so a later editor can tell which property would go untested
 * if they removed it.
 */
const FILE_CASES = [
  {
    name: 'minimal_chemistry',
    file: 'minimal_chemistry.esm',
    covers:
      'reaction system + model + operator_compose, and a data_sources entry that must contribute NO node (spec §4.8.1)',
  },
  {
    name: 'full_coupled',
    file: 'full_coupled.esm',
    covers:
      'TWO data_sources entries (still no nodes) and a `callback` coupling, which names no two components and so contributes no edge',
  },
  {
    name: 'data_sources_only',
    file: 'data_sources_only.esm',
    covers: 'a document that is NOTHING BUT data_sources — both graphs must come back empty',
  },
  {
    name: 'expr_graphs_variable_deps',
    file: 'expr_graphs_variable_deps.esm',
    covers:
      'a variable-dependency model (states, observeds, parameters) beside a reaction system, joined by a variable_map',
  },
  {
    name: 'scoped_refs_coupling',
    file: 'scoped_refs_coupling.esm',
    covers:
      'nested `subsystems` (the expression graph must recurse into them), a `couple` entry, a `callback`, and a variable_map whose two endpoints share one component (a self-edge)',
  },
  {
    name: 'wildfire_atmosphere_ocean',
    file: 'wildfire_atmosphere_ocean.esm',
    covers: 'five models joined by seven variable_map couplings — the coupled multi-model document',
  },
  {
    name: 'model_only',
    file: 'model_only.esm',
    covers: 'three models with no reaction system, plus data_sources and an operator_compose',
  },
  {
    name: 'reaction_system_only',
    file: 'reaction_system_only.esm',
    covers: 'a document with only reaction systems — no model nodes at all',
  },
  {
    name: 'events_all_types',
    file: 'events_all_types.esm',
    covers:
      'an `event` coupling (contributes no component edge) alongside operator_compose and variable_map',
  },
]

/**
 * Sub-document `expression_graph` targets. §4.8.2 requires the function to
 * accept a Model, a ReactionSystem, an Equation, a Reaction and a bare Expr as
 * well as an EsmFile; nothing measured any of those five overloads before.
 * `component` cases pull the real component out of a fixture (so the corpus
 * tracks the fixture); `literal` cases carry their own payload.
 */
const TARGET_CASES = [
  {
    name: 'model_from_minimal_chemistry',
    kind: 'model',
    from: { file: 'minimal_chemistry.esm', container: 'models', key: 'Advection' },
    covers: 'a Model target — bare (unscoped) node names, `_var` placeholder equations',
  },
  {
    name: 'reaction_system_from_minimal_chemistry',
    kind: 'reaction_system',
    from: { file: 'minimal_chemistry.esm', container: 'reaction_systems', key: 'SimpleOzone' },
    covers: 'a ReactionSystem target — the spec §4.8.2 worked example',
  },
  {
    name: 'model_with_subsystems',
    kind: 'model',
    from: { file: 'scoped_refs_coupling.esm', container: 'models', key: 'AtmosphericChemistry' },
    covers: 'a Model target that itself has `subsystems` — recursion under a bare target',
  },
  {
    name: 'equation_ode',
    kind: 'equation',
    literal: { lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: { op: '*', args: ['k', 'x'] } },
    covers: 'an Equation target with a derivative LHS and a self-reference on the RHS',
  },
  {
    name: 'equation_observed',
    kind: 'equation',
    literal: { lhs: 'y', rhs: { op: '+', args: ['a', { op: '*', args: ['b', 'c'] }] } },
    covers: 'an Equation target with a bare-variable LHS',
  },
  {
    name: 'reaction_bimolecular',
    kind: 'reaction',
    literal: {
      substrates: [{ species: 'NO', stoichiometry: 1 }, { species: 'O3', stoichiometry: 1 }],
      products: [{ species: 'NO2', stoichiometry: 1 }],
      rate: { op: '*', args: ['k1', 'M'] },
    },
    covers: 'a Reaction target — rate edges to every substrate AND product, plus stoichiometric edges',
  },
  {
    name: 'expression_scalar',
    kind: 'expression',
    literal: { op: '+', args: [{ op: '*', args: ['k', 'NO2'] }, 'j'] },
    covers: 'a bare Expr target — every free variable feeds the synthetic `expr_result` node',
  },
]

// --- shaping -----------------------------------------------------------------

/**
 * A component node, reduced to the fields every binding can produce. `id`,
 * `type` and the three summary counts are pinned; `description` / `reference`
 * are NOT — TypeScript derives them from `reference.notes` while Python and
 * Julia leave them null, and the spec calls for "summary metadata" without
 * naming those two.
 */
const shapeComponentNode = (n) => ({
  id: n.id,
  type: n.type,
  var_count: n.metadata.var_count,
  eq_count: n.metadata.eq_count,
  species_count: n.metadata.species_count,
})

/** A coupling edge: endpoints, kind, and the human-readable label (§4.8.1). */
const shapeCouplingEdge = (e) => ({
  from: e.data.from,
  to: e.data.to,
  type: e.data.type,
  label: e.data.label,
})

/** A variable node: the four fields §4.8.2 names. */
const shapeVariableNode = (n) => ({
  name: n.name,
  kind: n.kind,
  units: n.units ?? null,
  system: n.system,
})

/**
 * A dependency edge. `expression` is NOT pinned: §4.8.2 marks it optional
 * ("for detail views") and the bindings legitimately differ on whether a
 * stoichiometric edge carries the rate expression that produced it.
 */
const shapeDependencyEdge = (e) => ({
  source: e.data.source,
  target: e.data.target,
  relationship: e.data.relationship,
  equation_index: e.data.equation_index,
})

/** The adjacency/predecessor/successor closure, keyed by node id, sorted. */
function closure(graph, keyOf) {
  const out = {}
  for (const node of graph.nodes) {
    const k = keyOf(node)
    out[k] = {
      adjacency: [...graph.adjacency(k)].sort(),
      predecessors: [...graph.predecessors(k)].sort(),
      successors: [...graph.successors(k)].sort(),
    }
  }
  return out
}

const componentKey = (n) => n.id
const variableKey = (n) => n.name

/**
 * The JSON adjacency-list export (§4.8.3), reduced to the part that is a
 * CONFORMANCE property rather than a serializer detail.
 *
 * Pinned: the three top-level keys, the node ids in order, each edge's two
 * endpoints, and the adjacency map. NOT pinned: key order, indentation, or the
 * per-node/per-edge payload — those carry the same `description` / `reference` /
 * `coupling` fields `shapeComponentNode` already declines to pin, and every
 * binding's serializer spells them differently.
 */
function shapeJsonExport(json) {
  const g = JSON.parse(json)
  return {
    top_level_keys: Object.keys(g).sort(),
    node_ids: g.nodes.map((n) => n.id),
    edges: g.edges.map((e) => ({ source: e.source, target: e.target })),
    // Sorted: a node's neighbour ORDER is no more a conformance property than
    // the node list's own order (each binding builds its adjacency map from its
    // own iteration order).
    adjacency: Object.fromEntries(
      Object.entries(g.adjacency).map(([k, v]) => [k, [...v].sort()]),
    ),
  }
}

function shapeComponentGraph(graph) {
  return {
    nodes: graph.nodes.map(shapeComponentNode),
    edges: graph.edges.map(shapeCouplingEdge),
    closure: closure(graph, componentKey),
  }
}

function shapeExpressionGraph(graph) {
  return {
    nodes: graph.nodes.map(shapeVariableNode),
    edges: graph.edges.map(shapeDependencyEdge),
    closure: closure(graph, variableKey),
  }
}

// --- build -------------------------------------------------------------------

/**
 * Read a fixture through the package's own `load` — the same door every
 * binding's conformance test goes through, so the corpus cannot encode a graph
 * that only a raw `JSON.parse` produces. (Verified: all nine fixtures yield an
 * identical graph either way; `loadString` is used for definitional cleanliness, not
 * because any of them needs reference resolution.)
 */
const readFixture = (rel) =>
  loadString(readFileSync(join(ROOT, 'tests/valid', rel), 'utf8'), {
    basePath: join(ROOT, 'tests/valid'),
  })

const files = []
for (const c of FILE_CASES) {
  const doc = readFixture(c.file)
  const cg = componentGraph(doc)
  const eg = expressionGraph(doc)
  const merged = expressionGraph(doc, { mergeCoupled: true })
  files.push({
    name: c.name,
    input_file: `tests/valid/${c.file}`,
    covers: c.covers,
    component_graph: shapeComponentGraph(cg),
    component_graph_json: shapeJsonExport(toJsonGraph(cg)),
    expression_graph: shapeExpressionGraph(eg),
    expression_graph_json: shapeJsonExport(toJsonGraph(eg)),
    // `merge_coupled` (§4.8.2, "Coupled file-level graph"): variable_map
    // entries become cross-system dependency edges.
    expression_graph_merge_coupled: shapeExpressionGraph(merged),
  })
}

const targets = []
for (const c of TARGET_CASES) {
  let payload
  if (c.literal !== undefined) {
    payload = c.literal
  } else {
    const doc = readFixture(c.from.file)
    payload = doc[c.from.container][c.from.key]
  }
  targets.push({
    name: c.name,
    kind: c.kind,
    covers: c.covers,
    source: c.from ? { ...c.from, input_file: `tests/valid/${c.from.file}` } : null,
    // The target itself is inlined so a binding can drive the case without
    // re-reading (and re-resolving) the fixture it came from.
    target: payload,
    expression_graph: shapeExpressionGraph(expressionGraph(payload)),
  })
}

const corpus = {
  $comment:
    'Cross-language GRAPH conformance corpus (esm-libraries-spec §4.8). GENERATED by ' +
    'scripts/generate-graph-corpus.mjs from the TypeScript oracle — do not hand-edit. ' +
    'Pins the SEMANTIC graph model (component nodes/types/counts, coupling edges/types/labels, ' +
    'variable nodes/kinds/units/systems, dependency edges/relationships/equation_index, and the ' +
    'adjacency closure) plus the JSON adjacency-list export. Node and edge ORDER is not a ' +
    'conformance property — compare as multisets. The DOT and Mermaid byte formats are NOT ' +
    'pinned; see README.md for why.',
  oracle: '@earthsciml/ast componentGraph / expressionGraph / toJsonGraph',
  spec: 'esm-libraries-spec.md §4.8',
  files,
  targets,
}

mkdirSync(OUT_DIR, { recursive: true })
writeFileSync(join(OUT_DIR, 'cases.json'), JSON.stringify(corpus, null, 2) + '\n')

const count = (k) => files.reduce((n, f) => n + f[k].nodes.length, 0)
console.log(
  `files: ${files.length} (component nodes: ${count('component_graph')}, ` +
    `expression nodes: ${count('expression_graph')})\n` +
    `targets: ${targets.length}\n` +
    `-> ${join(OUT_DIR, 'cases.json')}`,
)
