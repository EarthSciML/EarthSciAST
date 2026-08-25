/**
 * Build-time reference resolution (RFC semiring-faq-unified-ir §6.1).
 *
 * The unit cases below mirror `pkg/earthsci-ast-py/tests/test_reference_resolution.py`
 * one for one — same documents, same expectations — because this binding is a
 * PORT of the Python pass and the two must not drift.
 *
 * The corpus block at the bottom drives the pass over every shared
 * `tests/valid/**` fixture. Cross-binding agreement was checked directly while
 * porting: `resolveReferences` was run over all 46 shared fixtures that yield a
 * non-empty graph and compared against the Python binding's output, vertex for
 * vertex, edge for edge and position for position in the topological order —
 * ZERO mismatches. What is pinned here is that the sweep stays clean and that
 * the fixtures known to carry reference edges keep carrying them.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import {
  buildReferenceGraph,
  resolveReferences,
  ReferenceResolutionError,
  VertexKind,
  EdgeKind,
  E_REF_UNDECLARED_INDEX_SET,
  E_REF_UNKNOWN_FAQ_NODE,
  E_REF_DUPLICATE_NODE_ID,
  E_REF_UNRESOLVED_JOIN_FACTOR,
  E_REF_CYCLE,
} from './reference-resolution.js'
import { fixturesDir } from './test-helpers.js'
import type { Model } from './types.js'

const model = (m: Record<string, unknown>): Model => m as unknown as Model

describe('buildReferenceGraph', () => {
  it('is empty-but-valid for a document using none of the features', () => {
    const g = buildReferenceGraph(model({ variables: {}, equations: [] }), 'M')
    expect(g.model).toBe('M')
    expect(g.vertices.size).toBe(0)
    expect(g.edges).toEqual([])
    expect(g.topologicalOrder()).toEqual([])
  })

  it('registers declared index sets and links ranges[*].from to them', () => {
    const g = buildReferenceGraph(
      model({
        equations: [
          {
            lhs: { op: 'aggregate', id: 'agg1', args: [], ranges: { i: { from: 'cells' } } },
            rhs: 0,
          },
        ],
      }),
      'M',
      { cells: { kind: 'categorical', members: [1, 2] } },
    )
    expect([...g.vertices.keys()]).toContain(`${VertexKind.INDEX_SET}:cells`)
    expect([...g.vertices.keys()]).toContain(`${VertexKind.NODE}:agg1`)
    expect(g.dependencies(`${VertexKind.NODE}:agg1`)).toEqual([`${VertexKind.INDEX_SET}:cells`])
    expect(g.edgesOfKind(EdgeKind.RANGE_FROM)).toHaveLength(1)
    // Bottom-up: the index set is emitted before the node that reads it.
    const topo = g.topologicalOrder()
    expect(topo.indexOf(`${VertexKind.INDEX_SET}:cells`)).toBeLessThan(
      topo.indexOf(`${VertexKind.NODE}:agg1`),
    )
  })

  it('rejects a ranges[*].from naming an undeclared index set', () => {
    expect(() =>
      buildReferenceGraph(
        model({
          equations: [
            { lhs: { op: 'aggregate', args: [], ranges: { i: { from: 'ghosts' } } }, rhs: 0 },
          ],
        }),
        'M',
        { cells: {} },
      ),
    ).toThrow(expect.objectContaining({ code: E_REF_UNDECLARED_INDEX_SET }) as unknown as Error)
  })

  it('rejects two expression nodes sharing an explicit id', () => {
    expect(() =>
      buildReferenceGraph(
        model({
          equations: [
            { lhs: { op: 'aggregate', id: 'dup', args: [] }, rhs: 0 },
            { lhs: { op: 'aggregate', id: 'dup', args: [] }, rhs: 0 },
          ],
        }),
        'M',
      ),
    ).toThrow(expect.objectContaining({ code: E_REF_DUPLICATE_NODE_ID }) as unknown as Error)
  })

  it('links a derived index set to its from_faq node — even when the node comes LATER', () => {
    // The two-step walk is what makes this work: every node is registered
    // before any reference is resolved. A single-pass resolver would reject it.
    const g = buildReferenceGraph(
      model({ equations: [{ lhs: { op: 'aggregate', id: 'faq', args: [] }, rhs: 0 }] }),
      'M',
      { pairs: { kind: 'derived', from_faq: 'faq' } },
    )
    expect(g.dependencies(`${VertexKind.INDEX_SET}:pairs`)).toEqual([`${VertexKind.NODE}:faq`])
    expect(g.edgesOfKind(EdgeKind.FROM_FAQ)).toHaveLength(1)
  })

  it('rejects a derived index set whose from_faq names no node', () => {
    expect(() =>
      buildReferenceGraph(model({ equations: [] }), 'M', {
        pairs: { kind: 'derived', from_faq: 'nope' },
      }),
    ).toThrow(expect.objectContaining({ code: E_REF_UNKNOWN_FAQ_NODE }) as unknown as Error)
  })

  it('resolves join.on factors against the node scope and rejects the rest', () => {
    const ok = buildReferenceGraph(
      model({
        equations: [
          {
            lhs: {
              op: 'aggregate',
              id: 'j',
              args: ['A', 'B'],
              join: [{ on: [['A', 'B']] }],
            },
            rhs: 0,
          },
        ],
      }),
      'M',
    )
    expect(ok.edgesOfKind(EdgeKind.JOIN_FACTOR)).toHaveLength(1)
    expect(ok.dependents(`${VertexKind.FACTOR}:A`)).toEqual([`${VertexKind.NODE}:j`])

    expect(() =>
      buildReferenceGraph(
        model({
          equations: [
            {
              lhs: { op: 'aggregate', id: 'j', args: ['A'], join: [{ on: [['Z', 'A']] }] },
              rhs: 0,
            },
          ],
        }),
        'M',
      ),
    ).toThrow(expect.objectContaining({ code: E_REF_UNRESOLVED_JOIN_FACTOR }) as unknown as Error)
  })

  it('addresses an id-less aggregate by its structural path', () => {
    const g = buildReferenceGraph(
      model({ equations: [{ lhs: { op: 'aggregate', args: [] }, rhs: 0 }] }),
      'M',
    )
    expect([...g.vertices.keys()]).toEqual([`${VertexKind.NODE}:equations/0/lhs`])
  })

  it('reports a reference cycle from topologicalOrder', () => {
    // `pairs` is derived from node `n`, and `n` iterates `pairs`.
    const g = buildReferenceGraph(
      model({
        equations: [
          { lhs: { op: 'aggregate', id: 'n', args: [], ranges: { i: { from: 'pairs' } } }, rhs: 0 },
        ],
      }),
      'M',
      { pairs: { kind: 'derived', from_faq: 'n' } },
    )
    expect(g.detectCycle()).not.toBeNull()
    expect(() => g.topologicalOrder()).toThrow(
      expect.objectContaining({ code: E_REF_CYCLE }) as unknown as Error,
    )
  })

  describe('the index_sets registry is a TRAILING argument (API_SPEC.md §8 item 17)', () => {
    const doc = {
      index_sets: { cells: { kind: 'categorical', members: [1, 2] } },
      models: {
        M: {
          equations: [
            {
              lhs: { op: 'aggregate', id: 'a', args: [], ranges: { i: { from: 'cells' } } },
              rhs: 0,
            },
          ],
        },
      },
    }

    it('resolveReferences threads the DOCUMENT-scoped registry into every model', () => {
      const graphs = resolveReferences(doc)
      expect([...graphs.keys()]).toEqual(['M'])
      expect(graphs.get('M')!.edgesOfKind(EdgeKind.RANGE_FROM)).toHaveLength(1)
    })

    it('the same model WITHOUT the registry does not resolve', () => {
      expect(() => buildReferenceGraph(doc.models.M, 'M')).toThrow(
        expect.objectContaining({ code: E_REF_UNDECLARED_INDEX_SET }) as unknown as Error,
      )
    })

    it('merges a model-nested index_sets on TOP of the document registry', () => {
      // Go's rule (reference_graph.go) and Rust's, matched exactly: the
      // document-scoped registry is the base and a pre-0.8.0 model-nested key
      // is merged over it, so a model-level entry wins a collision. Reading
      // ONLY the nested key is the Julia bug of API_SPEC.md §8 item 17.
      const nested = {
        index_sets: { local: {} },
        equations: [
          { lhs: { op: 'aggregate', id: 'a', args: [], ranges: { i: { from: 'local' } } }, rhs: 0 },
        ],
      }
      // Nested-only, no argument: still resolves.
      expect(buildReferenceGraph(model(nested), 'M').edgesOfKind(EdgeKind.RANGE_FROM)).toHaveLength(
        1,
      )
      // Document registry supplied as well: BOTH are visible.
      const merged = buildReferenceGraph(model(nested), 'M', { doc: {} })
      expect([...merged.vertices.keys()].sort()).toEqual([
        `${VertexKind.INDEX_SET}:doc`,
        `${VertexKind.INDEX_SET}:local`,
        `${VertexKind.NODE}:a`,
      ])
      // A document-scoped set alone still resolves a range that names it.
      const docOnly = {
        equations: [
          { lhs: { op: 'aggregate', id: 'a', args: [], ranges: { i: { from: 'doc' } } }, rhs: 0 },
        ],
      }
      expect(
        buildReferenceGraph(model(docOnly), 'M', { doc: {} }).edgesOfKind(EdgeKind.RANGE_FROM),
      ).toHaveLength(1)
    })
  })
})

describe('reference resolution over the shared corpus', () => {
  const validDir = fixturesDir('valid')
  const files = execSync(`find ${JSON.stringify(validDir)} -name '*.esm'`, { encoding: 'utf-8' })
    .trim()
    .split('\n')
    .sort()

  /**
   * THREE fixtures under `tests/valid/` are rejected by the resolver — and the
   * Python binding rejects the same three with the same codes, byte for byte.
   * They are schema-valid but reference-broken; see `tests/CORPUS_DEFECTS.md`:
   *
   * - `skolem_distinct_rank` declares a `kind: "derived"` index set whose
   *   `from_faq` names an id no expression node in the DOCUMENT carries (the
   *   name appears only inside an `_comment`) — corpus defect #1;
   * - `conservative_regrid_assembly` and `wildfire_atmosphere_ocean` each have
   *   a `join.on` factor outside its node's scope — corpus defect #3, whose
   *   second instance was masked until `from_faq` moved to document scope
   *   (esm-spec §9.7.5): `wildfire_atmosphere_ocean` used to fail earlier, with
   *   `unknown_faq_node`, because its producer lives in another model.
   *
   * That is a defect in the shared fixtures, not in this pass; it is pinned
   * here so the agreement is visible and so a fixture repair shows up as a test
   * failure rather than silently.
   */
  const KNOWN_UNRESOLVED: Record<string, string> = {
    'aggregate/skolem_distinct_rank.esm': E_REF_UNKNOWN_FAQ_NODE,
    'geometry/conservative_regrid_assembly.esm': E_REF_UNRESOLVED_JOIN_FACTOR,
    'wildfire_atmosphere_ocean.esm': E_REF_UNRESOLVED_JOIN_FACTOR,
  }

  it('every shared valid fixture resolves, bar the three known reference-broken ones', () => {
    expect(files.length).toBeGreaterThan(50)
    const failures: string[] = []
    const rejected: Record<string, string> = {}
    let withEdges = 0
    for (const f of files) {
      const rel = f.slice(validDir.length + 1)
      let raw: Record<string, unknown>
      try {
        raw = JSON.parse(readFileSync(f, 'utf-8')) as Record<string, unknown>
      } catch {
        continue
      }
      try {
        for (const g of resolveReferences(raw).values()) {
          if (g.edges.length > 0) withEdges += 1
          g.topologicalOrder()
        }
      } catch (e) {
        if (e instanceof ReferenceResolutionError && rel in KNOWN_UNRESOLVED) {
          rejected[rel] = e.code
        } else {
          failures.push(`${rel}: ${(e as Error).message}`)
        }
      }
    }
    expect(failures).toEqual([])
    expect(rejected).toEqual(KNOWN_UNRESOLVED)
    // The corpus really does exercise the pass — this guards a vacuous pass.
    expect(withEdges).toBeGreaterThan(10)
  })

  it('rejects the shared undeclared-index-set fixture with the pinned code', () => {
    const raw = JSON.parse(
      readFileSync(fixturesDir('invalid', 'aggregate', 'undeclared_from_name.esm'), 'utf-8'),
    ) as { models: Record<string, unknown>; index_sets?: Record<string, unknown> }
    const [name, m] = Object.entries(raw.models)[0]
    let caught: ReferenceResolutionError | undefined
    try {
      buildReferenceGraph(m as Record<string, unknown>, name, raw.index_sets)
    } catch (e) {
      caught = e as ReferenceResolutionError
    }
    expect(caught?.code).toBe(E_REF_UNDECLARED_INDEX_SET)
    // The message names the offending set, exactly as Python's does.
    expect(caught?.message).toContain('ghost_cells')
  })
})

describe('from_faq resolves at DOCUMENT scope (esm-spec §9.7.5)', () => {
  // `index_sets` is a document-scoped registry, so a `kind: "derived"` entry is
  // visible to every model and its producing node may live in ANY of them.
  // Until this ruling every binding resolved `from_faq` against one model's
  // nodes, which made the cross-model shape unresolvable. The consequence: node
  // ids are unique per DOCUMENT, not per model.
  const agg = (extra: Record<string, unknown>) => ({ op: 'aggregate', args: [], ...extra })

  it('resolves a producer that lives in another model', () => {
    const doc = {
      index_sets: {
        faces: { kind: 'interval', size: 8 },
        edges: { kind: 'derived', from_faq: 'edge_faq' },
      },
      models: {
        Consumer: {
          equations: [{ lhs: agg({ output_idx: [], ranges: { e: { from: 'edges' } } }), rhs: 0 }],
        },
        Producer: {
          equations: [
            {
              lhs: agg({ id: 'edge_faq', output_idx: ['edge'], ranges: { f: { from: 'faces' } } }),
              rhs: 0,
            },
          ],
        },
      },
    }
    const graphs = resolveReferences(doc)
    // BOTH graphs carry the edge: the registry entry is document-scoped, so
    // every model sees the same derived set and the same producer.
    for (const name of ['Consumer', 'Producer']) {
      const faq = graphs.get(name)!.edgesOfKind(EdgeKind.FROM_FAQ)
      expect(faq).toHaveLength(1)
      expect(faq[0].source).toBe(`${VertexKind.INDEX_SET}:edges`)
      expect(faq[0].target).toBe(`${VertexKind.NODE}:edge_faq`)
    }
    // the consumer's graph gained a real vertex for the foreign producer, so
    // the partition pass can walk index_set -> node across the model boundary.
    const v = graphs.get('Consumer')!.vertices.get(`${VertexKind.NODE}:edge_faq`)
    expect(v?.nodeId).toBe('edge_faq')
    expect(v?.path).toBe('models/Producer/equations/0/lhs')
  })

  it('still rejects a from_faq naming no node anywhere in the document', () => {
    const doc = {
      index_sets: { edges: { kind: 'derived', from_faq: 'nowhere' } },
      models: {
        A: { equations: [{ lhs: agg({ id: 'here' }), rhs: 0 }] },
        B: { equations: [{ lhs: agg({ id: 'there' }), rhs: 0 }] },
      },
    }
    expect(() => resolveReferences(doc)).toThrow(
      expect.objectContaining({ code: E_REF_UNKNOWN_FAQ_NODE }) as unknown as Error,
    )
  })

  it('rejects the same node id used in two different models', () => {
    // Legal before the §9.7.5 ruling, a load-time error now: one document-wide
    // id namespace cannot hold two.
    const doc = {
      models: {
        A: { equations: [{ lhs: agg({ id: 'dup' }), rhs: 0 }] },
        B: { equations: [{ lhs: agg({ id: 'dup' }), rhs: 0 }] },
      },
    }
    expect(() => resolveReferences(doc)).toThrow(
      expect.objectContaining({ code: E_REF_DUPLICATE_NODE_ID }) as unknown as Error,
    )
  })

  it('resolves the shared cross-model corpus fixture', () => {
    const raw = JSON.parse(
      readFileSync(fixturesDir('valid', 'aggregate', 'cross_model_from_faq.esm'), 'utf-8'),
    ) as Record<string, unknown>
    const graphs = resolveReferences(raw)
    expect([...graphs.keys()].sort()).toEqual(['EdgeProducer', 'FluxConsumer'])
    const faq = graphs.get('FluxConsumer')!.edgesOfKind(EdgeKind.FROM_FAQ)
    expect(faq.map((e) => [e.source, e.target])).toEqual([
      [`${VertexKind.INDEX_SET}:edges`, `${VertexKind.NODE}:edge_enum`],
    ])
  })
})
