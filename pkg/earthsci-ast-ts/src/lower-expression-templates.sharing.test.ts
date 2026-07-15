/**
 * Regression tests for the nested-template exponential blow-up (esm-spec
 * §9.6/§9.7.3): a chain of templates T0..Tn where each T_i's body references
 * T_{i-1} TWICE must expand to a structurally SHARED DAG with O(n) unique
 * nodes, not a 2^n-node tree. The old deep-copy substitution made a ~4KB file
 * allocate millions of nodes (multi-GiB peak RSS in the Julia binding before
 * its equivalent fix). Structural sharing changes representation only — the
 * canonical serialized bytes are unchanged, which the small-depth test pins.
 */
import { describe, it, expect } from 'vitest'
import { load } from './parse.js'

function applyNode(name: string) {
  return { op: 'apply_expression_template', args: [], name, bindings: {} }
}

const LEAF_BODY = {
  op: '*',
  args: [
    1.8e-12,
    { op: 'exp', args: [{ op: '/', args: [{ op: '-', args: [1500.0] }, 'T'] }] },
  ],
}

/** T0 = an Arrhenius-style leaf; each T_i = T_{i-1} + T_{i-1}; one call site. */
function buildDoublingChainDoc(depth: number): Record<string, unknown> {
  const templates: Record<string, unknown> = {
    T0: { params: [], body: LEAF_BODY },
  }
  for (let i = 1; i <= depth; i++) {
    templates[`T${i}`] = {
      params: [],
      body: { op: '+', args: [applyNode(`T${i - 1}`), applyNode(`T${i - 1}`)] },
    }
  }
  return {
    esm: '0.4.0',
    metadata: { name: 'template_sharing_regression', authors: ['t'] },
    reaction_systems: {
      chem: {
        species: { A: { default: 1.0 }, B: { default: 0.5 } },
        parameters: { T: { default: 298.15 } },
        expression_templates: templates,
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: applyNode(`T${depth}`),
          },
        ],
      },
    },
  }
}

/**
 * Identity-memoized node counter: `logical` counts every object/array node as
 * many times as it is reachable (what a deep copy would materialize) WITHOUT
 * actually walking each path — subtree counts are memoized on object identity
 * — while `unique` counts distinct objects. NEVER replace this with a naive
 * recursive count: at the depths below that walk itself is exponential.
 */
function countNodes(root: unknown): { logical: number; unique: number } {
  const memo = new Map<object, number>()
  const count = (n: unknown): number => {
    if (n === null || typeof n !== 'object') return 0
    const hit = memo.get(n)
    if (hit !== undefined) return hit
    memo.set(n, 0)
    let c = 1
    if (Array.isArray(n)) {
      for (const v of n) c += count(v)
    } else {
      for (const k of Object.keys(n)) c += count((n as Record<string, unknown>)[k])
    }
    memo.set(n, c)
    return c
  }
  const logical = count(root)
  return { logical, unique: memo.size }
}

function expandedRate(file: unknown): unknown {
  const sys = (file as { reaction_systems: Record<string, unknown> }).reaction_systems
    .chem as Record<string, unknown>
  return (sys.reactions as Array<{ rate: unknown }>)[0].rate
}

describe('nested-template expansion uses structural sharing (no exponential blow-up)', () => {
  it('expands a doubling chain of depth 14 as a shared DAG with O(depth) unique nodes', () => {
    const file = load(buildDoublingChainDoc(14))
    const { logical, unique } = countNodes(expandedRate(file))
    // Semantics: the expansion is still the full 2^14-leaf sum...
    expect(logical).toBeGreaterThan(2 ** 14)
    // ...but the representation is a DAG: a handful of unique objects.
    expect(unique).toBeLessThan(100)
  })

  it('shares the two operands of each doubling level by object identity', () => {
    const file = load(buildDoublingChainDoc(14))
    let node = expandedRate(file) as { op: string; args: unknown[] }
    let levels = 0
    while (node.op === '+') {
      expect(node.args[0]).toBe(node.args[1]) // identical reference, not a copy
      node = node.args[0] as { op: string; args: unknown[] }
      levels++
    }
    expect(levels).toBe(14)
    expect(node.op).toBe('*') // the single shared leaf
  })

  it('handles the spec-maximum 32-template chain (depth 31) with flat memory', () => {
    const file = load(buildDoublingChainDoc(31))
    const { logical, unique } = countNodes(expandedRate(file))
    expect(logical).toBeGreaterThan(2 ** 31)
    expect(unique).toBeLessThan(200)
  })

  it('serializes byte-identically to the fully-inlined (unshared) expansion', () => {
    const file = load(buildDoublingChainDoc(3))
    // Build the expected expansion the naive way: an actual tree.
    const inline = (d: number): unknown =>
      d === 0 ? LEAF_BODY : { op: '+', args: [inline(d - 1), inline(d - 1)] }
    expect(JSON.stringify(expandedRate(file))).toBe(JSON.stringify(inline(3)))
  })
})
