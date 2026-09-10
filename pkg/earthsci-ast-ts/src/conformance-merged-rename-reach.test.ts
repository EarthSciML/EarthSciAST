/**
 * Conformance harness adapter — merged-away rename REACH (TypeScript).
 *
 * Driven by the shared manifest at
 * `tests/conformance/merged_rename_reach/manifest.json`
 * (esm-libraries-spec §4.7.1 step 4 and §4.7.5 step 3 ordering;
 * EarthSciML/EarthSciAST#230).
 *
 * An `operator_compose` renaming match folds `B.x` into `A.x`, deleting `B.x`
 * and rewriting every equation off it. That rewrite reaches equation ASTs and
 * nothing else, and `operator_compose` entries run BEFORE `couple` and
 * `variable_map` — so a later entry's `from` / `to`, plain scoped-reference
 * STRINGS on the entry object, could still name a spelling that no longer
 * exists. This pins that they RESOLVE to the survivor.
 *
 * Three surfaces bind here — `flatten`, `events_and_updates` and
 * `template_registry`. All three are pure structural transforms, so a
 * rewrite-only port implements them in full. The two RUNTIME surfaces
 * (`override_keys`, `output_selection`) and `inline_tests` do not: this binding
 * has no simulator, so it has no override-key surface, no result object to read
 * by name, and no inline-test runner.
 */

import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { describe, expect, it } from 'vitest'
import { flatten, loadString, toAscii } from './index'
import type { FlattenedSystem, FlattenedVariable } from './flatten'
import type { AffectEquation, Expression } from './types'

const here = dirname(fileURLToPath(import.meta.url))
const categoryDir = join(here, '..', '..', '..', 'tests', 'conformance', 'merged_rename_reach')

interface ReachCase {
  id: string
  path: string
  surface: string
  merged_variable_renames?: Record<string, string>
  state_variables?: string[]
  tendency_of?: string
  tendency_references?: string[]
  no_equation_references?: string[]
  /** `events_and_updates`: the affects the flattened events must carry, in order. */
  event_affects?: Array<{ lhs: string; rhs_references?: string[] }>
  /** `events_and_updates`: variable -> names its `update` rules must reference. */
  variable_updates?: Record<string, string[]>
  /** `events_and_updates`: spellings no event and no update rule may still name. */
  absent_from_events_and_updates?: string[]
  /** `template_registry`: the diagnostic code flatten must refuse with. */
  raises?: string
  /** `template_registry`: substrings the refusal message must name. */
  names_in_message?: string[]
}

interface Manifest {
  cases: ReachCase[]
  surfaces: Record<string, { bindings: string[]; scope_excluded?: Record<string, string> }>
  merged_variable_renames_field: Record<string, string>
}

const manifest = JSON.parse(readFileSync(join(categoryDir, 'manifest.json'), 'utf-8')) as Manifest
const flattenCases = manifest.cases.filter((c) => c.surface === 'flatten')
const eventCases = manifest.cases.filter((c) => c.surface === 'events_and_updates')
const registryCases = manifest.cases.filter((c) => c.surface === 'template_registry')

function flattenCase(c: ReachCase) {
  return flatten(loadString(readFileSync(join(categoryDir, c.path), 'utf-8')))
}

/** The dependent variable an equation LHS defines, `undefined` for none. */
function dependentVar(lhs: Expression): string | undefined {
  if (typeof lhs === 'string') return lhs
  if (typeof lhs === 'object' && lhs !== null && 'op' in lhs) {
    const node = lhs as { op: string; args?: unknown[] }
    if (node.op === 'D' && node.args !== undefined && node.args.length > 0) {
      return dependentVar(node.args[0] as Expression)
    }
  }
  return undefined
}

/** Every affect of every flattened event, discrete first, in document order. */
function allAffects(flat: FlattenedSystem): AffectEquation[] {
  const out: AffectEquation[] = []
  for (const event of flat.discreteEvents) out.push(...(event.affects ?? []))
  for (const event of flat.continuousEvents) {
    out.push(...(event.affects ?? []))
    out.push(...(event.affect_neg ?? []))
  }
  return out
}

/** The rendered EXPRESSION slots of a variable's `update` rules. */
function updateText(variable: FlattenedVariable): string[] {
  const spec = variable.update
  if (spec === undefined) return []
  const rules = Array.isArray(spec) ? spec : [spec]
  const out: string[] = []
  for (const rule of rules) {
    const r = rule as unknown as Record<string, unknown>
    for (const key of ['when', 'expression']) {
      const value = r[key]
      if (value !== undefined && value !== null) out.push(toAscii(value as Expression))
    }
  }
  return out
}

/**
 * Every name-bearing rendering of the flattened events and update rules — the
 * surfaces §4.7.1 step 4's retarget has to reach beyond the equation pool.
 */
function eventAndUpdateText(flat: FlattenedSystem): string[] {
  const out: string[] = []
  for (const event of flat.discreteEvents) {
    const trigger = event.trigger as { type: string; expression?: Expression }
    if (trigger.type === 'condition' && trigger.expression !== undefined) {
      out.push(toAscii(trigger.expression))
    }
  }
  for (const event of flat.continuousEvents) {
    for (const condition of event.conditions) out.push(toAscii(condition))
  }
  for (const affect of allAffects(flat)) out.push(affect.lhs, toAscii(affect.rhs))
  for (const table of [flat.stateVariables, flat.parameters, flat.observedVariables]) {
    for (const variable of Object.values(table)) out.push(...updateText(variable))
  }
  return out
}

describe('conformance: merged_rename_reach (esm-libraries-spec §4.7.1 step 4)', () => {
  it('the manifest is not empty and lists this binding', () => {
    // A manifest that silently listed zero cases would make every test below
    // vacuously green.
    expect(flattenCases.length).toBeGreaterThan(0)
    expect(manifest.surfaces.flatten.bindings).toContain('typescript')
    // …and both runtime halves are recorded as OUT of scope here, each with a
    // reason. This binding has no simulator, so it has neither an override-key
    // surface nor a result object to read by name; asserting the exclusion is
    // what keeps it from quietly becoming a gap.
    for (const surface of ['events_and_updates', 'template_registry'] as const) {
      expect(manifest.surfaces[surface].bindings).toContain('typescript')
    }
    expect(eventCases.length).toBeGreaterThan(0)
    expect(registryCases.length).toBeGreaterThan(0)
    for (const surface of ['override_keys', 'output_selection', 'inline_tests'] as const) {
      expect(manifest.surfaces[surface].bindings).not.toContain('typescript')
      expect(manifest.surfaces[surface].scope_excluded?.typescript).toBeTruthy()
    }
    expect(manifest.merged_variable_renames_field.typescript).toBe(
      'FlattenMetadata.mergedVariableRenames',
    )
  })

  for (const c of flattenCases) {
    describe(c.id, () => {
      it('records which names the merge deleted', () => {
        // The rename map is what a consumer addressing a state by name resolves
        // through, so it is part of the flattened form's contract.
        const flat = flattenCase(c)
        expect(flat.metadata.mergedVariableRenames).toEqual(c.merged_variable_renames)
      })

      it('leaves the merged-away name surviving nowhere', () => {
        const flat = flattenCase(c)
        expect(Object.keys(flat.stateVariables)).toEqual(c.state_variables)
        for (const gone of c.no_equation_references ?? []) {
          expect(flat.stateVariables[gone]).toBeUndefined()
          expect(flat.parameters[gone]).toBeUndefined()
          expect(flat.observedVariables[gone]).toBeUndefined()
          for (const eq of flat.equations) {
            const rendered = `${toAscii(eq.lhs)} = ${toAscii(eq.rhs)}`
            expect(rendered, `equation still references ${gone}`).not.toContain(gone)
          }
        }
      })

      it('lands the later entry on the survivor', () => {
        // The non-vacuity anchor for the test above: deleting the entry's
        // reference outright would satisfy "the dead name survives nowhere" by
        // doing nothing at all.
        const flat = flattenCase(c)
        const target = c.tendency_of as string
        const eq = flat.equations.find((e) => dependentVar(e.lhs) === target)
        expect(eq, `no equation defines ${target}`).toBeDefined()
        const rendered = toAscii(eq!.rhs)
        for (const name of c.tendency_references ?? []) {
          expect(rendered, `D(${target}) must reference ${name}`).toContain(name)
        }
      })
    })
  }

  // The `events_and_updates` surface. An event's affect `lhs` is a plain
  // variable NAME string and an `update` rule's `when` / `expression` live on
  // the VARIABLE, so a walk over `equations` alone reaches neither. An affect
  // left writing to a name the flattened system no longer declares is a SILENT
  // wrong answer rather than a refusal, which is what makes this surface the
  // sharpest of the four.
  for (const c of eventCases) {
    describe(c.id, () => {
      it('records which names the merge deleted', () => {
        const flat = flattenCase(c)
        expect(flat.metadata.mergedVariableRenames).toEqual(c.merged_variable_renames)
        expect(Object.keys(flat.stateVariables)).toEqual(c.state_variables)
      })

      it('lands every affect and every update rule on the survivor', () => {
        const flat = flattenCase(c)
        const affects = allAffects(flat)
        const wanted = c.event_affects ?? []
        expect(affects.length).toBe(wanted.length)
        wanted.forEach((want, i) => {
          expect(affects[i]!.lhs).toBe(want.lhs)
          const rendered = toAscii(affects[i]!.rhs)
          for (const name of want.rhs_references ?? []) expect(rendered).toContain(name)
        })
        for (const [name, references] of Object.entries(c.variable_updates ?? {})) {
          const variable =
            flat.parameters[name] ?? flat.stateVariables[name] ?? flat.observedVariables[name]
          expect(variable, `no variable named ${name}`).toBeDefined()
          const rendered = updateText(variable!).join(' ; ')
          for (const reference of references) expect(rendered).toContain(reference)
        }
      })

      it('leaves the merged-away spelling in no event and no update rule', () => {
        // The non-vacuity anchor: an implementation that DROPPED the affect
        // would satisfy "the dead name survives nowhere" by doing nothing, so
        // this only means something beside the assertion above.
        const flat = flattenCase(c)
        for (const gone of c.absent_from_events_and_updates ?? []) {
          for (const text of eventAndUpdateText(flat)) {
            expect(text, `'${text}' still references ${gone}`).not.toContain(gone)
          }
        }
      })
    })
  }

  // The `template_registry` surface — the ONE place a rewritten name is REFUSED
  // rather than resolved. A surviving registry body is authored source that
  // expands at the BUILD boundary, so rewriting it would silently diverge from
  // the expand-at-load image of the same document.
  for (const c of registryCases) {
    describe(c.id, () => {
      it('refuses the flatten, naming the template and the variable', () => {
        let raised: unknown
        try {
          flattenCase(c)
        } catch (error) {
          raised = error
        }
        expect(raised, 'flatten must refuse a stale registry body').toBeInstanceOf(Error)
        expect((raised as { code?: string }).code).toBe(c.raises)
        for (const name of c.names_in_message ?? []) {
          expect((raised as Error).message).toContain(name)
        }
      })
    })
  }
})
