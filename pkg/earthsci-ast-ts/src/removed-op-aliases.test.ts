/**
 * The removed spellings of the Functional Aggregate Query node — `arrayop`
 * (removed at esm 0.8.0) and `aggregate` (a deprecated alias from 1.1.0,
 * removed at 2.0.0) — are refused by name with `removed_op`, in the root and in
 * every referenced document; neither is normalized. Gates
 * `tests/conformance/removed_spellings/` (CONFORMANCE_SPEC §7). See
 * `docs/content/rfcs/faq-node-rename.md`.
 */
import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

import {
  ParseError,
  SCHEMA_VERSION,
  loadDocument,
  loadPath,
  prepareDocumentOps,
  raiseFaqVersionFloor,
} from './parse.js'
import { resolveSubsystemRefsSync } from './ref-loading.js'
import { toJson } from './serialize.js'
import { fixturesDir } from './test-helpers.js'
import { validateText } from './validate.js'

const conf = (name: string) => fixturesDir('conformance', 'removed_spellings', name)

function refusal(fn: () => unknown): ParseError {
  try {
    fn()
  } catch (e) {
    expect(e).toBeInstanceOf(ParseError)
    return e as ParseError
  }
  throw new Error('expected a refusal')
}

describe('removed_spellings conformance tier', () => {
  it('canonical_loads: loads, and emit(load(x)) is the document', () => {
    const p = conf('canonical.esm')
    const emitted = toJson(loadPath(p))
    expect(JSON.parse(emitted)).toEqual(JSON.parse(fs.readFileSync(p, 'utf-8')))
  })

  it('aggregate_rejected: `aggregate` is refused with removed_op, naming `faq` and the codemod', () => {
    const err = refusal(() =>
      loadPath(fixturesDir('invalid', 'removed_ops', 'removed_op_aggregate.esm')),
    )
    expect(err.code).toBe('removed_op')
    expect(err.message).toContain('"op": "aggregate"')
    expect(err.message).toContain('"op": "faq"')
    expect(err.message).toContain('python -m earthsci_ast.migrate')
  })

  it('arrayop_rejected: `arrayop` is refused with removed_op', () => {
    expect(
      refusal(() => loadPath(fixturesDir('invalid', 'faq', 'arrayop_op_removed.esm'))).code,
    ).toBe('removed_op')
  })

  // TypeScript resolves subsystem refs through a separate exported API rather
  // than inside `loadPath`, so the test drives that explicitly.
  for (const [id, file] of [
    ['aggregate_in_referenced_child', 'ref_parent_aliased.esm'],
    ['arrayop_in_referenced_child', 'ref_parent_arrayop.esm'],
  ] as const) {
    it(`${id}: the child's removed spelling is refused at its own wire boundary`, () => {
      const p = conf(file)
      const f = loadPath(p)
      expect(() => resolveSubsystemRefsSync(f, path.dirname(p))).toThrow(/removed_op/)
    })
  }

  it('faq_requires_v11: `faq` below esm 1.1.0 is faq_version_too_old', () => {
    // A 1.x root is refused by the major-version check after the wire boundary,
    // so the boundary is driven directly.
    const doc = JSON.parse(fs.readFileSync(conf('canonical.esm'), 'utf-8'))
    doc.esm = '1.0.0'
    expect(() => prepareDocumentOps(doc)).toThrow(/faq_version_too_old/)
    doc.esm = '1.1.0'
    expect(() => prepareDocumentOps(doc)).not.toThrow()
  })
})

describe('removed spellings outside the tier', () => {
  /** A document whose one equation's right-hand side is a reduction tagged `op`. */
  const docWith = (op: string, esm = SCHEMA_VERSION): Record<string, unknown> => ({
    esm,
    metadata: { name: 'aliases', authors: ['t'] },
    models: {
      M: {
        variables: { u: { type: 'unknown' }, s: { type: 'unknown' } },
        equations: [
          {
            lhs: 's',
            rhs: {
              op,
              args: [],
              output_idx: [],
              expr: { op: 'index', args: ['u', 'f'] },
              ranges: { f: [1, 4] },
            },
          },
        ],
      },
    },
  })

  it('refuses `aggregate` whatever version the document declares', () => {
    // Before the version check, so a 1.0.0 document (where `aggregate` was the
    // spelling) is told about the construct and the codemod.
    const err = refusal(() => loadDocument(docWith('aggregate', '1.0.0')))
    expect(err.code).toBe('removed_op')
    expect(err.message).toContain('removed_op at /models/M/equations/0/rhs:')
  })

  it('validate() reports removed_op ahead of schema validation', () => {
    const result = validateText(JSON.stringify(docWith('aggregate')))
    expect(result.is_valid).toBe(false)
    expect(result.schema_errors.map((e) => [e.code, e.path])).toEqual([
      ['removed_op', '/models/M/equations/0/rhs'],
    ])
  })

  it('raises a resolved document below 1.1.0 that contains `faq` to the 1.1.0 floor', () => {
    const doc = docWith('faq', '1.0.0')
    raiseFaqVersionFloor(doc)
    expect(doc.esm).toBe('1.1.0')
    const current = docWith('faq')
    raiseFaqVersionFloor(current)
    expect(current.esm).toBe(SCHEMA_VERSION)
  })
})
