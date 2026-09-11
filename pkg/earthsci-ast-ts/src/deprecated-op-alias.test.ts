/**
 * The `aggregate` → `faq` deprecated-op-alias contract (esm 1.1.0).
 *
 * Gates `tests/conformance/deprecated_op_alias/` and the `removed_op`
 * rejection of `arrayop`. See CONFORMANCE_SPEC §7 and
 * `docs/content/rfcs/faq-node-rename.md`.
 */
import { describe, expect, it, vi, afterEach } from 'vitest'
import fs from 'node:fs'

import { loadPath } from './parse.js'
import { toJson } from './serialize.js'
import { fixturesDir } from './test-helpers.js'

const conf = (name: string) => fixturesDir('conformance', 'deprecated_op_alias', name)

/** Every `op` string in a decoded document, depth-first. */
function allOps(node: unknown, out: string[] = []): string[] {
  if (Array.isArray(node)) {
    for (const v of node) allOps(v, out)
  } else if (node !== null && typeof node === 'object') {
    const obj = node as Record<string, unknown>
    if (typeof obj.op === 'string') out.push(obj.op)
    for (const k of Object.keys(obj)) allOps(obj[k], out)
  }
  return out
}

describe('deprecated op alias: aggregate → faq', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('warns exactly once for the document, naming the node count', () => {
    // Once per DOCUMENT, not once per node: the fixture carries two aliased
    // nodes and must still produce a single warning.
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    loadPath(conf('aliased.esm'))
    const alias = warn.mock.calls.filter((c) => String(c[0]).includes('deprecated_op_alias'))
    expect(alias).toHaveLength(1)
    expect(String(alias[0][0])).toContain('2 nodes were normalized')
  })

  it('never lets the alias survive the loader', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    const emitted = toJson(loadPath(conf('aliased.esm')))
    const ops = allOps(JSON.parse(emitted))
    expect(ops).not.toContain('aggregate')
    expect(ops).toContain('faq')
  })

  it('emits the canonical document from the aliased one', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    // The two fixtures differ ONLY in the op tag, so normalization at the wire
    // boundary must make their emitted forms byte-identical.
    expect(toJson(loadPath(conf('aliased.esm')))).toBe(toJson(loadPath(conf('canonical.esm'))))
  })

  it('does not warn on the canonical document', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    loadPath(conf('canonical.esm'))
    expect(warn.mock.calls.filter((c) => String(c[0]).includes('deprecated_op_alias'))).toHaveLength(
      0
    )
  })

  it('rejects `arrayop` by name rather than leaving it to the open tier', () => {
    // `arrayop` matches the `op` pattern, so without a by-name rejection it
    // would load as an OPEN rewrite-target op (esm-spec §4.2) and fail only
    // much later as `unlowered_operator`.
    const path = fixturesDir('invalid', 'faq', 'arrayop_op_removed.esm')
    expect(fs.existsSync(path)).toBe(true)
    expect(() => loadPath(path)).toThrow(/removed_op/)
  })
})
