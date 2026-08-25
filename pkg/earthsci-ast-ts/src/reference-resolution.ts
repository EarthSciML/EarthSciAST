/**
 * Build-time reference resolution for the semiring-FAQ unified IR: the
 * intra-document node-id / index-set dependency DAG.
 *
 * Not to be confused with `./ref-loading.js`, which inlines cross-file
 * `{ "ref": ... }` subsystem mounts at load time — this module never touches
 * the filesystem; it wires id-addressed edges inside ONE document.
 *
 * It implements *node addressing* and *reference-edge resolution* — the hard
 * prerequisite the §6.1 cadence-partition pass of the
 * `semiring-faq-unified-ir` RFC calls out:
 *
 * > "node addressing — referencing a node by id — is a hard prerequisite: the
 * > pass cannot be built until `from_faq` and join references are real edges
 * > in this DAG."
 *
 * Three kinds of name/id reference become real, queryable graph edges
 * (RFC §6.1 "Propagation"):
 *
 * - an aggregate node → an index set it iterates (`ranges[*].from`);
 * - a `kind: "derived"` index set → its `from_faq` node (by stable id);
 * - an aggregate `join.on` factor → the factor it names.
 *
 * Like the Julia, Python, Rust and Go passes, this one walks the RAW parsed
 * document rather than the typed layer: `index_sets`, node `id`,
 * `ranges[*].from` and `join` are exactly the fields the typed layer drops, so
 * working the raw shape is what keeps the five bindings in step.
 *
 * PORTED FROM the Python binding (`earthsci_ast/reference_resolution.py`),
 * which is the most complete of the four: it registers every node BEFORE
 * resolving any reference (a two-step walk), so a `join.on` or `from_faq` may
 * name a node that appears later in the document. Rust's single-pass
 * `register_and_process` cannot do that. Vertex keys, edge kinds, error codes
 * and message shapes follow Python byte for byte.
 */

import { EsmDiagnosticError } from './errors.js'
import type { EsmFile, Model } from './types.js'

// --- error codes (stable; mirrored across every binding) --------------------

/** Undeclared name in a `ranges[*].from` reference. */
export const E_REF_UNDECLARED_INDEX_SET = 'E_REF_UNDECLARED_INDEX_SET'
/** A `kind: "derived"` index set's `from_faq` names no node id in the model. */
export const E_REF_UNKNOWN_FAQ_NODE = 'E_REF_UNKNOWN_FAQ_NODE'
/** Two expression nodes in the same model share an explicit `id`. */
export const E_REF_DUPLICATE_NODE_ID = 'E_REF_DUPLICATE_NODE_ID'
/** A `join.on` factor reference names nothing in the node's scope. */
export const E_REF_UNRESOLVED_JOIN_FACTOR = 'E_REF_UNRESOLVED_JOIN_FACTOR'
/** A directed cycle exists among the reference edges. */
export const E_REF_CYCLE = 'E_REF_CYCLE'

/**
 * A reference could not be resolved, or the reference graph has a cycle.
 *
 * Carries the stable `code` (one of the `E_REF_*` constants above) so callers
 * and the cross-binding conformance suite can assert on the failure mode. For a
 * cycle, `cycle` holds the offending vertex-key path.
 */
export class ReferenceResolutionError extends EsmDiagnosticError {
  declare code: string
  readonly cycle: string[] | undefined

  constructor(code: string, message: string, cycle?: string[]) {
    super(code, `ReferenceResolutionError(${code}): ${message}`)
    this.name = 'ReferenceResolutionError'
    this.cycle = cycle
  }
}

// --- vertex / edge model ----------------------------------------------------

/** The three kinds of vertex in the reference graph. */
export const VertexKind = {
  NODE: 'node',
  INDEX_SET: 'index_set',
  FACTOR: 'factor',
} as const
export type VertexKind = (typeof VertexKind)[keyof typeof VertexKind]

/** The three kinds of reference edge (RFC §6.1 "Propagation"). */
export const EdgeKind = {
  /** aggregate node → the index set it iterates (`ranges[*].from`). */
  RANGE_FROM: 'range_from',
  /** `kind: "derived"` index set → the node that materializes it (`from_faq`). */
  FROM_FAQ: 'from_faq',
  /** aggregate node → a factor named by `join.on`. */
  JOIN_FACTOR: 'join_factor',
} as const
export type EdgeKind = (typeof EdgeKind)[keyof typeof EdgeKind]

/**
 * A vertex in the reference graph, addressed by a kind-namespaced `key`.
 *
 * `key` is `` `${kind}:${name}` ``. For a `node` vertex, `name` is the node's
 * stable address: its explicit `id` when it has one, else its structural path
 * (e.g. `equations/0/rhs/expr`).
 */
export interface ReferenceVertex {
  key: string
  kind: VertexKind
  name: string
  op?: string
  nodeId?: string
  path?: string
}

/** A directed `source → target` edge: *source references / depends on target*. */
export interface ReferenceEdge {
  source: string
  target: string
  kind: EdgeKind
}

type RawObject = Record<string, unknown>

const isObject = (v: unknown): v is RawObject =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

const isNode = (v: unknown): v is RawObject => isObject(v) && 'op' in v

const nodeKey = (addr: string): string => `${VertexKind.NODE}:${addr}`
const indexSetKey = (name: string): string => `${VertexKind.INDEX_SET}:${name}`
const factorKey = (name: string): string => `${VertexKind.FACTOR}:${name}`

/**
 * The resolved reference DAG for one model — the partition pass's input.
 *
 * Vertices are keyed by their kind-namespaced `key`. Edges point from a vertex
 * to a vertex it *depends on*, so a bottom-up {@link topologicalOrder} walk
 * visits each vertex after its dependencies — exactly the order
 * `class(n) = max(class(inputs))` propagation needs.
 */
export class ReferenceGraph {
  readonly model: string
  /** Insertion-ordered `key -> vertex`. */
  readonly vertices: Map<string, ReferenceVertex> = new Map()
  readonly edges: ReferenceEdge[] = []

  private readonly out: Map<string, string[]> = new Map()
  private readonly inn: Map<string, string[]> = new Map()

  constructor(model = '') {
    this.model = model
  }

  /** @internal */
  ensureVertex(vertex: ReferenceVertex): void {
    if (!this.vertices.has(vertex.key)) {
      this.vertices.set(vertex.key, vertex)
      if (!this.out.has(vertex.key)) this.out.set(vertex.key, [])
      if (!this.inn.has(vertex.key)) this.inn.set(vertex.key, [])
    }
  }

  /** @internal */
  addEdge(source: string, target: string, kind: EdgeKind): void {
    this.edges.push({ source, target, kind })
    const o = this.out.get(source)
    if (o) o.push(target)
    else this.out.set(source, [target])
    const i = this.inn.get(target)
    if (i) i.push(source)
    else this.inn.set(target, [source])
  }

  /** Vertices `key` references / depends on (its out-neighbours). */
  dependencies(key: string): string[] {
    return [...(this.out.get(key) ?? [])]
  }

  /** Vertices that reference / depend on `key` (its in-neighbours). */
  dependents(key: string): string[] {
    return [...(this.inn.get(key) ?? [])]
  }

  edgesOfKind(kind: EdgeKind): ReferenceEdge[] {
    return this.edges.filter((e) => e.kind === kind)
  }

  /**
   * A reference cycle as a vertex-key path, or `null` if acyclic.
   *
   * Three-colour DFS over the dependency edges, traversing sorted keys and
   * sorted neighbours so the reported path is deterministic and matches the
   * other bindings. The returned path is `[v, …, v]` (the repeated vertex
   * closes the cycle).
   */
  detectCycle(): string[] | null {
    const WHITE = 0
    const GREY = 1
    const BLACK = 2
    const colour = new Map<string, number>()
    for (const k of this.vertices.keys()) colour.set(k, WHITE)
    const order = [...this.vertices.keys()].sort()

    const visit = (start: string): string[] | null => {
      const stack: Array<[string, number]> = [[start, 0]]
      const path: string[] = [start]
      colour.set(start, GREY)
      while (stack.length > 0) {
        const top = stack[stack.length - 1]
        const [node, i] = top
        const neighbours = [...(this.out.get(node) ?? [])].sort()
        if (i < neighbours.length) {
          top[1] = i + 1
          const next = neighbours[i]
          if ((colour.get(next) ?? WHITE) === GREY) {
            const idx = path.indexOf(next)
            return [...path.slice(idx), next]
          }
          if ((colour.get(next) ?? WHITE) === WHITE) {
            colour.set(next, GREY)
            stack.push([next, 0])
            path.push(next)
          }
        } else {
          colour.set(node, BLACK)
          stack.pop()
          path.pop()
        }
      }
      return null
    }

    for (const start of order) {
      if (colour.get(start) === WHITE) {
        const cyc = visit(start)
        if (cyc !== null) return cyc
      }
    }
    return null
  }

  /**
   * Bottom-up order (dependencies before dependents).
   *
   * Throws {@link ReferenceResolutionError} (`E_REF_CYCLE`) if the graph is
   * cyclic — a cycle among reference edges is an out-of-scope
   * implicit/iterative solve (RFC §6.1 "Acyclicity").
   */
  topologicalOrder(): string[] {
    const cyc = this.detectCycle()
    if (cyc !== null) {
      throw new ReferenceResolutionError(
        E_REF_CYCLE,
        `reference cycle detected: ${cyc.join(' -> ')}`,
        cyc,
      )
    }
    // Kahn over the dependency DAG, emitting a dependency before its
    // dependents. Deterministic: repeatedly emit every not-yet-emitted key, in
    // sorted order, whose out-neighbours are all done.
    const emitted: string[] = []
    const done = new Set<string>()
    const keys = [...this.vertices.keys()].sort()
    while (emitted.length < this.vertices.size) {
      let progressed = false
      for (const k of keys) {
        if (done.has(k)) continue
        const deps = this.out.get(k) ?? []
        if (deps.every((d) => done.has(d))) {
          emitted.push(k)
          done.add(k)
          progressed = true
        }
      }
      /* c8 ignore next */
      if (!progressed) break // guarded by detectCycle above
    }
    return emitted
  }
}

/** Ops whose nodes are addressable FAQ vertices even without an explicit `id`. */
const AGGREGATE_OPS = new Set(['aggregate'])

/**
 * Resolve the reference edges of ONE `model` into a {@link ReferenceGraph}.
 *
 * @param model - the raw model object (as parsed, not the typed layer)
 * @param modelName - the model's key in the document, used in diagnostics
 * @param indexSets - the DOCUMENT-SCOPED `index_sets` registry. Since v0.8.0
 *   the registry is a sibling of `models` rather than nested inside each model,
 *   and 1.0.0 keeps it there; {@link resolveReferences} reads it once from the
 *   document root and threads it into every model. It is an OPTIONAL TRAILING
 *   argument, not a separate function and not required (API_SPEC.md §8 item 17).
 *   When it is omitted entirely, a model-local `index_sets` key is read as a
 *   fallback so a caller holding only a raw model still resolves — the same
 *   fallback Python and Rust apply, and the reason the corpus agrees. Note that
 *   this binding NEVER reads the model-nested shape in preference to the
 *   document-scoped one.
 *
 * Throws {@link ReferenceResolutionError} on a duplicate node id, an undeclared
 * `ranges[*].from` index set, a `from_faq` naming no node, or an unresolved
 * `join.on` factor. Cycles are reported lazily by
 * {@link ReferenceGraph.topologicalOrder}, or eagerly by
 * {@link resolveReferences}.
 */
export function buildReferenceGraph(
  model: Model | RawObject,
  modelName = '',
  indexSets?: Record<string, unknown>,
): ReferenceGraph {
  const graph = new ReferenceGraph(modelName)
  const raw = model as RawObject

  // Prefer the document-scoped registry; fall back to a model-local
  // `index_sets` key only when no registry was supplied at all.
  let sets: RawObject = {}
  if (indexSets !== undefined) {
    if (isObject(indexSets)) sets = indexSets
  } else if (isObject(raw.index_sets)) {
    sets = raw.index_sets
  }

  // Pass 1 — register declared index sets as vertices.
  for (const name of Object.keys(sets)) {
    graph.ensureVertex({ key: indexSetKey(name), kind: VertexKind.INDEX_SET, name })
  }

  // Pass 2 — walk every expression node; assign a stable address, register
  // aggregate / id-bearing nodes, and add the within-node reference edges
  // (ranges[*].from, join.on). Also build id -> address for from_faq.
  const idToAddr = new Map<string, string>()

  const registerNode = (node: RawObject, path: string): string | null => {
    const op = typeof node.op === 'string' ? node.op : undefined
    const rawId = node.id
    const nid = typeof rawId === 'string' && rawId !== '' ? rawId : undefined
    const isAgg = op !== undefined && AGGREGATE_OPS.has(op)
    // Only nodes that participate in addressing become vertices: the
    // aggregate/FAQ nodes and any node carrying an explicit id.
    if (!isAgg && nid === undefined) return null
    const addr = nid ?? path
    const key = nodeKey(addr)
    if (nid !== undefined) {
      const prior = idToAddr.get(nid)
      if (prior !== undefined) {
        throw new ReferenceResolutionError(
          E_REF_DUPLICATE_NODE_ID,
          `duplicate expression-node id '${nid}' in model '${modelName}' ` +
            `(at ${path} and ${nodeKey(prior)})`,
        )
      }
      idToAddr.set(nid, addr)
    }
    graph.ensureVertex({
      key,
      kind: VertexKind.NODE,
      name: addr,
      op,
      nodeId: nid,
      path,
    })
    return key
  }

  /**
   * Names a `join.on` reference may resolve to: the node's string factor-args,
   * its declared range keys, and its symbolic `output_idx`.
   */
  const factorScope = (node: RawObject): Set<string> => {
    const names = new Set<string>()
    const args = node.args
    if (Array.isArray(args)) {
      for (const a of args) if (typeof a === 'string') names.add(a)
    }
    if (isObject(node.ranges)) {
      for (const k of Object.keys(node.ranges)) names.add(k)
    }
    const outIdx = node.output_idx
    if (Array.isArray(outIdx)) {
      for (const o of outIdx) if (typeof o === 'string') names.add(o)
    }
    return names
  }

  const processNodeRefs = (node: RawObject, key: string, path: string): void => {
    // ranges[*].from -> index set
    const ranges = node.ranges
    if (isObject(ranges)) {
      for (const [idxName, spec] of Object.entries(ranges)) {
        if (isObject(spec) && 'from' in spec) {
          const target = spec.from
          if (typeof target !== 'string' || !(target in sets)) {
            throw new ReferenceResolutionError(
              E_REF_UNDECLARED_INDEX_SET,
              `range '${idxName}' of node ${key} references undeclared index set ` +
                `'${String(target)}' (model '${modelName}', at ${path})`,
            )
          }
          graph.addEdge(key, indexSetKey(target), EdgeKind.RANGE_FROM)
        }
      }
    }
    // join[*].on[*] -> factor
    const join = node.join
    if (Array.isArray(join)) {
      const scope = factorScope(node)
      for (const clause of join) {
        if (!isObject(clause)) continue
        const on = clause.on
        if (!Array.isArray(on)) continue
        for (const pair of on) {
          if (!Array.isArray(pair) || pair.length === 0) continue
          const ref = pair[0]
          if (typeof ref !== 'string' || !scope.has(ref)) {
            throw new ReferenceResolutionError(
              E_REF_UNRESOLVED_JOIN_FACTOR,
              `join factor '${String(ref)}' of node ${key} names no factor, range, ` +
                `or output index in scope (model '${modelName}', at ${path})`,
            )
          }
          graph.ensureVertex({ key: factorKey(ref), kind: VertexKind.FACTOR, name: ref })
          graph.addEdge(key, factorKey(ref), EdgeKind.JOIN_FACTOR)
        }
      }
    }
  }

  // Two-step walk: register ALL nodes first (so every id is known before any
  // reference is resolved), then resolve within-node refs.
  const pending: Array<[RawObject, string, string]> = []

  const walk = (value: unknown, path: string): void => {
    if (isObject(value)) {
      if (isNode(value)) {
        const key = registerNode(value, path)
        if (key !== null) pending.push([value, key, path])
      }
      for (const [k, v] of Object.entries(value)) walk(v, `${path}/${k}`)
    } else if (Array.isArray(value)) {
      value.forEach((v, i) => walk(v, `${path}/${i}`))
    }
  }

  for (const rootKey of ['equations', 'initialization_equations']) {
    walk(raw[rootKey], rootKey)
  }

  for (const [node, key, path] of pending) processNodeRefs(node, key, path)

  // Pass 3 — derived index sets resolve their from_faq to a node by id.
  for (const [name, entry] of Object.entries(sets)) {
    if (!isObject(entry)) continue
    if (entry.kind !== 'derived') continue
    const faq = entry.from_faq
    const addr = typeof faq === 'string' ? idToAddr.get(faq) : undefined
    if (addr === undefined) {
      throw new ReferenceResolutionError(
        E_REF_UNKNOWN_FAQ_NODE,
        `derived index set '${name}' references from_faq '${faq === undefined ? '' : String(faq)}', ` +
          `which is not the id of any expression node in model '${modelName}'`,
      )
    }
    graph.addEdge(indexSetKey(name), nodeKey(addr), EdgeKind.FROM_FAQ)
  }

  return graph
}

/**
 * Resolve reference edges for EVERY model in `document`.
 *
 * Returns a `modelName -> ReferenceGraph` map. Throws
 * {@link ReferenceResolutionError} on any unresolved reference *or* reference
 * cycle (each model's graph is checked acyclic eagerly here).
 *
 * The document-scoped `index_sets` registry is read once from the top level and
 * threaded into every model, so a caller never assembles it by hand.
 */
export function resolveReferences(document: EsmFile | RawObject): Map<string, ReferenceGraph> {
  const out = new Map<string, ReferenceGraph>()
  const raw = document as RawObject
  const models = raw.models
  if (!isObject(models)) return out
  const docIndexSets = isObject(raw.index_sets) ? raw.index_sets : {}
  for (const [modelName, model] of Object.entries(models)) {
    if (!isObject(model)) continue
    const graph = buildReferenceGraph(model, modelName, docIndexSets)
    const cyc = graph.detectCycle()
    if (cyc !== null) {
      throw new ReferenceResolutionError(
        E_REF_CYCLE,
        `reference cycle in model '${modelName}': ${cyc.join(' -> ')}`,
        cyc,
      )
    }
    out.set(modelName, graph)
  }
  return out
}
