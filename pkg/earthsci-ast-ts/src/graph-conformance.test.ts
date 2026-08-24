/**
 * Drives the shared graph conformance corpus (`tests/conformance/graph/cases.json`).
 *
 * TypeScript is that corpus's ORACLE, so this suite is a REGENERATION GUARD
 * rather than a discovery of divergence: it fails when someone changes
 * `graph.ts` without re-running `scripts/generate-graph-corpus.mjs`, which is
 * exactly the moment the other four bindings would silently start diverging.
 * The other bindings' identically-shaped suites are where the corpus does its
 * real work.
 *
 * Node and edge ORDER is not a conformance property (each binding iterates its
 * own maps), so every list is compared as a sorted multiset.
 */
import { describe, expect, it } from 'vitest'
import { componentGraph, expressionGraph, toDot, toJsonGraph, toMermaid } from './graph.js'
import type { Graph } from './graph.js'
import { loadFixture, readFixture } from './test-helpers.js'
import type { EsmFile } from './types.js'

interface ComponentNodeCase {
  id: string
  type: string
  var_count: number
  eq_count: number
  species_count: number
}
interface CouplingEdgeCase {
  from: string
  to: string
  type: string
  label: string
}
interface VariableNodeCase {
  name: string
  kind: string
  units: string | null
  system: string
}
interface DependencyEdgeCase {
  source: string
  target: string
  relationship: string
  equation_index: number
}
interface ClosureCase {
  [node: string]: { adjacency: string[]; predecessors: string[]; successors: string[] }
}
interface JsonExportCase {
  top_level_keys: string[]
  node_ids: string[]
  edges: Array<{ source: string; target: string }>
  adjacency: Record<string, string[]>
}
interface ComponentGraphCase {
  nodes: ComponentNodeCase[]
  edges: CouplingEdgeCase[]
  closure: ClosureCase
}
interface ExpressionGraphCase {
  nodes: VariableNodeCase[]
  edges: DependencyEdgeCase[]
  closure: ClosureCase
}
interface FileCase {
  name: string
  input_file: string
  covers: string
  component_graph: ComponentGraphCase
  component_graph_json: JsonExportCase
  expression_graph: ExpressionGraphCase
  expression_graph_json: JsonExportCase
  expression_graph_merge_coupled: ExpressionGraphCase
  /** The first line of each §4.8.3 text export — only the header is pinned. */
  component_graph_dot_header: string
  component_graph_mermaid_header: string
  expression_graph_dot_header: string
  expression_graph_mermaid_header: string
}
interface TargetCase {
  name: string
  kind: string
  covers: string
  target: unknown
  expression_graph: ExpressionGraphCase
}
interface Corpus {
  files: FileCase[]
  targets: TargetCase[]
}

const corpus: Corpus = JSON.parse(readFixture('conformance', 'graph', 'cases.json'))

/** Sort a list of records by their canonical JSON so it compares as a multiset. */
const multiset = <T>(xs: T[]): string[] => xs.map((x) => JSON.stringify(x)).sort()

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const actualComponent = (g: Graph<any, any>): ComponentGraphCase => ({
  nodes: g.nodes.map((n) => ({
    id: n.id,
    type: n.type,
    var_count: n.metadata.var_count,
    eq_count: n.metadata.eq_count,
    species_count: n.metadata.species_count,
  })),
  edges: g.edges.map((e) => ({
    from: e.data.from,
    to: e.data.to,
    type: e.data.type,
    label: e.data.label,
  })),
  closure: closureOf(g, (n) => n.id),
})

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const actualExpression = (g: Graph<any, any>): ExpressionGraphCase => ({
  nodes: g.nodes.map((n) => ({
    name: n.name,
    kind: n.kind,
    units: n.units ?? null,
    system: n.system,
  })),
  edges: g.edges.map((e) => ({
    source: e.data.source,
    target: e.data.target,
    relationship: e.data.relationship,
    equation_index: e.data.equation_index,
  })),
  closure: closureOf(g, (n) => n.name),
})

function closureOf<N, E>(g: Graph<N, E>, keyOf: (n: N) => string): ClosureCase {
  const out: ClosureCase = {}
  for (const node of g.nodes) {
    const k = keyOf(node)
    out[k] = {
      adjacency: [...g.adjacency(k)].sort(),
      predecessors: [...g.predecessors(k)].sort(),
      successors: [...g.successors(k)].sort(),
    }
  }
  return out
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const actualJsonExport = (g: Graph<any, any>): JsonExportCase => {
  const parsed = JSON.parse(toJsonGraph(g))
  return {
    top_level_keys: Object.keys(parsed).sort(),
    node_ids: parsed.nodes.map((n: { id: string }) => n.id),
    edges: parsed.edges.map((e: { source: string; target: string }) => ({
      source: e.source,
      target: e.target,
    })),
    // Sorted — see the generator: neighbour order is not pinned.
    adjacency: Object.fromEntries(
      Object.entries(parsed.adjacency as Record<string, string[]>).map(([k, v]) => [
        k,
        [...v].sort(),
      ]),
    ),
  }
}

function expectGraph(
  actual: ComponentGraphCase | ExpressionGraphCase,
  expected: ComponentGraphCase | ExpressionGraphCase,
): void {
  expect(multiset(actual.nodes)).toEqual(multiset(expected.nodes))
  expect(multiset(actual.edges)).toEqual(multiset(expected.edges))
  expect(actual.closure).toEqual(expected.closure)
}

function expectJsonExport(actual: JsonExportCase, expected: JsonExportCase): void {
  expect(actual.top_level_keys).toEqual(expected.top_level_keys)
  expect([...actual.node_ids].sort()).toEqual([...expected.node_ids].sort())
  expect(multiset(actual.edges)).toEqual(multiset(expected.edges))
  expect(actual.adjacency).toEqual(expected.adjacency)
}

describe('graph conformance corpus — whole documents', () => {
  for (const c of corpus.files) {
    describe(`${c.name} (${c.covers})`, () => {
      const file = (): EsmFile =>
        loadFixture(...c.input_file.replace(/^tests\//, '').split('/')) as EsmFile

      it('component_graph', () => {
        expectGraph(actualComponent(componentGraph(file())), c.component_graph)
      })

      it('component_graph JSON adjacency-list export', () => {
        expectJsonExport(actualJsonExport(componentGraph(file())), c.component_graph_json)
      })

      it('expression_graph', () => {
        expectGraph(actualExpression(expressionGraph(file())), c.expression_graph)
      })

      it('expression_graph JSON adjacency-list export', () => {
        expectJsonExport(actualJsonExport(expressionGraph(file())), c.expression_graph_json)
      })

      it('expression_graph with mergeCoupled', () => {
        expectGraph(
          actualExpression(expressionGraph(file(), { mergeCoupled: true })),
          c.expression_graph_merge_coupled,
        )
      })

      // The corpus pins only the FIRST LINE of the DOT and Mermaid exports: the
      // rest carries node labels run through the chemical-subscript formatter,
      // which two of the five bindings do not have. See
      // tests/conformance/graph/README.md.
      it('DOT and Mermaid headers', () => {
        const cg = componentGraph(file())
        const eg = expressionGraph(file())
        expect(toDot(cg).split('\n')[0]).toBe(c.component_graph_dot_header)
        expect(toMermaid(cg).split('\n')[0]).toBe(c.component_graph_mermaid_header)
        expect(toDot(eg).split('\n')[0]).toBe(c.expression_graph_dot_header)
        expect(toMermaid(eg).split('\n')[0]).toBe(c.expression_graph_mermaid_header)
      })
    })
  }
})

describe('graph conformance corpus — sub-document expression_graph targets', () => {
  for (const c of corpus.targets) {
    it(`${c.name} (${c.kind}: ${c.covers})`, () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      expectGraph(actualExpression(expressionGraph(c.target as any)), c.expression_graph)
    })
  }
})
