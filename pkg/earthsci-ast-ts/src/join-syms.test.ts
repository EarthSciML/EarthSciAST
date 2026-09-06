/**
 * A `join` clause's `syms` names the two RANGE SYMBOLS its `on` pairs are read
 * at — the self-join disambiguation of CONFORMANCE_SPEC §5.5.8 "Two ranges over
 * one index set".
 *
 * The TypeScript binding does no numeric evaluation, so its obligation for the
 * field is that it survive: validate, round-trip, and — the one that is easy to
 * get wrong — flattening's dot-namespacing of join names (§5.5.6). An `on` key
 * column IS a variable reference and is namespaced; `syms` names symbols the
 * node BINDS and must not be. Getting that backwards is not cosmetic: a
 * namespaced `syms` entry names no range of the node, so an executing binding
 * would reject the document, or resolve the key at the wrong side and return
 * the wrong neighbour's value.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { join as pathJoin } from 'path'
import { loadString, toJson, validateText, flatten } from './index.js'
import { fixturesDir } from './test-helpers.js'

const fixture = pathJoin(fixturesDir(), 'valid', 'aggregate', 'join_on_self_join_syms.esm')

/** Every `join` clause of the flattened document, in order. */
function flattenedJoinClauses(doc: ReturnType<typeof loadString>): Record<string, unknown>[] {
  const found: Record<string, unknown>[] = []
  const walk = (v: unknown): void => {
    if (Array.isArray(v)) {
      v.forEach(walk)
      return
    }
    if (v === null || typeof v !== 'object') return
    const o = v as Record<string, unknown>
    if (Array.isArray(o.join)) {
      for (const c of o.join) {
        if (c !== null && typeof c === 'object' && !Array.isArray(c)) {
          found.push(c as Record<string, unknown>)
        }
      }
    }
    Object.values(o).forEach(walk)
  }
  walk(flatten(doc) as unknown)
  return found
}

describe('join.syms (CONFORMANCE_SPEC §5.5.8)', () => {
  it('validates and round-trips verbatim', () => {
    const content = readFileSync(fixture, 'utf-8')
    expect(validateText(content).is_valid).toBe(true)

    const doc = loadString(content)
    const emitted = JSON.parse(toJson(doc))
    const clauses = emitted.models.SelfJoin.equations
      .filter((e: { rhs?: { join?: unknown } }) => e.rhs?.join)
      .map((e: { rhs: { join: unknown[] } }) => e.rhs.join[0])
    expect(clauses).toHaveLength(2)
    for (const c of clauses) {
      expect(c.on).toEqual([['row_prior', 'row_id']])
      expect(c.syms).toEqual(['b', 'a'])
    }

    // parse -> emit -> parse is a fixed point, `syms` included.
    expect(loadString(toJson(doc))).toEqual(doc)
  })

  it('survives flattening: key columns are namespaced, syms are not', () => {
    const doc = loadString(readFileSync(fixture, 'utf-8'))
    const clauses = flattenedJoinClauses(doc)
    expect(clauses).toHaveLength(2)
    for (const c of clauses) {
      // The key COLUMNS are references and follow the flattened registry.
      expect(c.on).toEqual([['SelfJoin.row_prior', 'SelfJoin.row_id']])
      // The `syms` are binders of the node and are carried through unchanged.
      expect(c.syms).toEqual(['b', 'a'])
    }
  })

  it('rejects a syms without an on, and a syms of the wrong length', () => {
    const base = JSON.parse(readFileSync(fixture, 'utf-8'))

    // `dependentRequired`: `syms` is meaningful only for an `on` clause.
    const orphan = structuredClone(base)
    orphan.models.SelfJoin.equations[3].rhs.join = [{ syms: ['a', 'b'] }]
    expect(validateText(JSON.stringify(orphan)).is_valid).toBe(false)

    // Exactly two entries — a left side and a right side.
    const short = structuredClone(base)
    short.models.SelfJoin.equations[3].rhs.join = [{ on: [['row_prior', 'row_id']], syms: ['a'] }]
    expect(validateText(JSON.stringify(short)).is_valid).toBe(false)
  })
})
