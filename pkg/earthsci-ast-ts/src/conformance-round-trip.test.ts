/**
 * Conformance harness adapter — round-trip category (TypeScript binding).
 *
 * The oracle is the AUTHORED FIXTURE. The shared harness used to compare emit
 * pass 2 against emit pass 3, with `F` itself never a participant — the
 * self-comparing shape described in tests/conformance/README.md, blind to any
 * field lost on the FIRST load because the second emit forgets exactly what the
 * first forgot. esm-spec §9.6.4 rule 5 now states BOTH halves normatively
 * ("Load preservation" and "Idempotence") and neither implies the other, so
 * both are asserted here.
 *
 * This is the CROSS-BINDING adapter, driven by the shared manifest at
 * tests/conformance/round_trip/manifest.json. It is distinct from the
 * `Round-trip tests` block in conformance.test.ts, which sweeps tests/valid
 * comparing a reloaded object against the first-loaded one — self-comparing,
 * and in memory rather than on the wire.
 *
 * See tests/conformance/README.md for the contract: the five normalizations,
 * the two exemption ledgers (`load_transforms` for spec-mandated rewrites,
 * `known_divergences` for the defect ratchet), and the `preserved_keys`
 * field-loss check that runs on EVERY fixture, excused or not.
 */

import { describe, expect, it } from 'vitest'
import { existsSync, readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { loadString, toJson } from './index'

const BINDING = 'typescript'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = join(here, '..', '..', '..')
const testsDir = join(repoRoot, 'tests')
const manifestPath = join(testsDir, 'conformance', 'round_trip', 'manifest.json')

interface Divergence {
  id: string
  fixtures: string[]
  conformant: string[]
  nonconformant: string[]
}
interface Fixture {
  id: string
  path: string
  load_transforms?: unknown[]
}
interface Manifest {
  category: string
  preserved_keys: string[]
  known_divergences?: Divergence[]
  fixtures: Fixture[]
}

if (!existsSync(manifestPath)) {
  throw new Error(`conformance manifest not found at ${manifestPath}`)
}
const manifest: Manifest = JSON.parse(readFileSync(manifestPath, 'utf-8'))
const preserved = new Set(manifest.preserved_keys)

// Fixture id -> the divergence entry naming THIS binding non-conformant. A
// binding listed `conformant`, or in neither column, stays held to the checks
// the entry relieves: that is what makes the ledger a ratchet, not a licence.
const excusedByDivergence = new Map<string, string>()
for (const entry of manifest.known_divergences ?? []) {
  if (!entry.nonconformant.includes(BINDING)) continue
  for (const fixture of entry.fixtures) excusedByDivergence.set(fixture, entry.id)
}

const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

/**
 * Applied to BOTH sides, so no relaxation can hide a drop. Implements the five
 * normalizations in tests/conformance/README.md (admissions 1 and 2 of
 * esm-spec §9.6.4 rule 5).
 */
function normalize(value: unknown, parent = ''): unknown {
  if (Array.isArray(value)) return value.map((x) => normalize(x, parent))
  if (isObject(value)) {
    const out: Record<string, unknown> = {}
    for (const [key, item] of Object.entries(value)) {
      const norm = normalize(item, key)
      if (Array.isArray(norm) && norm.length === 0) continue
      if (isObject(norm) && Object.keys(norm).length === 0) continue
      if (key === 'expect_cadence') continue
      if (key === 'independent_variable' && parent === 'domain' && norm === 't') continue
      if (key === 'initial_offset' && norm === 0) continue
      out[key] = norm
    }
    return out
  }
  return value
}

const brief = (v: unknown) => {
  const s = JSON.stringify(v) ?? String(v)
  return s.length > 120 ? `${s.slice(0, 120)}…` : s
}

/**
 * Every JSON-pointer path at which the two documents differ. Numbers compare by
 * MATHEMATICAL VALUE, not spelling — a tolerance for where the bindings stand
 * today (see the manifest's `normalizations`), not a rule the format grants.
 */
function diff(a: unknown, b: unknown, path = ''): string[] {
  const out: string[] = []
  if (isObject(a) && isObject(b)) {
    for (const [key, value] of Object.entries(a)) {
      if (key in b) out.push(...diff(value, b[key], `${path}/${key}`))
      else out.push(`${path}/${key}  DROPPED (was ${brief(value)})`)
    }
    for (const [key, value] of Object.entries(b)) {
      if (!(key in a)) out.push(`${path}/${key}  ADDED (${brief(value)})`)
    }
  } else if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) out.push(`${path}  LENGTH ${a.length} -> ${b.length}`)
    else for (let i = 0; i < a.length; i++) out.push(...diff(a[i], b[i], `${path}[${i}]`))
  } else if (typeof a === 'number' && typeof b === 'number') {
    if (a !== b) out.push(`${path}  ${a} -> ${b}`)
  } else if (JSON.stringify(a) !== JSON.stringify(b)) {
    out.push(`${path}  ${brief(a)} -> ${brief(b)}`)
  }
  return out
}

/** `[wireKey, jsonPath]` for every mapping key in `orig` absent from `emitted`. */
function droppedKeys(orig: unknown, emitted: unknown, path = ''): Array<[string, string]> {
  const out: Array<[string, string]> = []
  if (isObject(orig) && isObject(emitted)) {
    for (const [key, value] of Object.entries(orig)) {
      const here_ = `${path}.${key}`
      if (key in emitted) out.push(...droppedKeys(value, emitted[key], here_))
      else out.push([key, here_])
    }
  } else if (Array.isArray(orig) && Array.isArray(emitted)) {
    const n = Math.min(orig.length, emitted.length)
    for (let i = 0; i < n; i++) out.push(...droppedKeys(orig[i], emitted[i], `${path}[${i}]`))
  }
  return out
}

describe('Conformance: round-trip (manifest-driven)', () => {
  it('loads the shared manifest', () => {
    expect(manifest.category).toBe('round_trip')
    expect(manifest.fixtures.length).toBeGreaterThan(0)
  })

  const stale: string[] = []

  it.each(manifest.fixtures.map((f) => [f.id, f] as const))('%s', (_id, fixture) => {
    const path = join(testsDir, fixture.path)
    if (!existsSync(path)) {
      throw new Error(`fixture not on disk: ${path}`)
    }
    const basePath = dirname(path)
    const authoredText = readFileSync(path, 'utf-8')

    const loaded = loadString(authoredText, { basePath })
    const firstJson = toJson(loaded)

    const authored = normalize(JSON.parse(authoredText))
    const emitted = normalize(JSON.parse(firstJson))

    const divergence = excusedByDivergence.get(fixture.id)
    const excused = (fixture.load_transforms?.length ?? 0) > 0 || divergence !== undefined

    const differences = diff(authored, emitted)

    // 1. LOAD PRESERVATION (esm-spec §9.6.4 rule 5).
    if (!excused) {
      if (differences.length > 0) {
        throw new Error(
          `${fixture.id}: save(load(F)) differs from F — either a field is being ` +
            `dropped/invented, or a spec-REQUIRED load-time transform needs a ` +
            `\`load_transforms\` entry citing its clause. Do NOT add one to silence a ` +
            `drop.\n  ${differences.join('\n  ')}`,
        )
      }
    } else if (differences.length === 0) {
      // Improving, not failing: README adapter contract item 8.
      stale.push(fixture.id)
    }

    // 2. FIELD LOSS — runs on EVERY fixture, excused or not. A load-time
    //    transform rewrites a CONSTRUCT; it does not licence dropping the
    //    document around it.
    const lost = droppedKeys(authored, emitted)
      .filter(([key]) => preserved.has(key))
      .map(([, where]) => where)
    expect(lost, `${fixture.id}: dropped preserved field(s)`).toEqual([])

    // 3. IDEMPOTENCE (esm-spec §9.6.4 rule 5) — still required, no longer alone.
    //    A ledger-excused fixture whose emit is not RE-LOADABLE (a drop that
    //    removed a schema-required field) is recorded as a known failure naming
    //    the ledger entry — never a silent pass.
    let secondJson: string
    try {
      secondJson = toJson(loadString(firstJson, { basePath }))
    } catch (err) {
      if (divergence === undefined) throw err
      console.warn(
        `KNOWN FAILURE: ${fixture.id}: emit is not re-loadable (${String(err)}); ` +
          `known_divergence '${divergence}'`,
      )
      return
    }
    expect(JSON.parse(secondJson), `${fixture.id}: emit is not a fixed point`).toEqual(
      JSON.parse(firstJson),
    )
  })

  it('reports excused fixtures that now round-trip cleanly', () => {
    // NOT a failure — a binding that stops applying a permitted transform, or
    // fixes its own defect, is improving. The ledger entry is then stale and
    // should be trimmed by hand. See README adapter contract item 8.
    if (stale.length > 0) {
      console.warn(
        `note: excused fixtures that now round-trip cleanly in ${BINDING} ` +
          `(ledger entry may be stale — trim by hand): ${stale.join(', ')}`,
      )
    }
    expect(true).toBe(true)
  })
})
