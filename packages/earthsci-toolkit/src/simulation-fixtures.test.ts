/**
 * Execution runner for inline `tests` blocks on the tests/simulation/*.esm
 * physics fixtures (gt-l1fk). Mirrors the Julia reference at
 * packages/EarthSciSerialization.jl/test/tests_blocks_execution_test.jl.
 *
 * The TypeScript binding is parse-only (no ODE solver), so this runner does
 * not execute assertions numerically. Instead it closes the schema-vs-binding
 * gap by parsing every tests/simulation/ fixture, round-tripping it through
 * save -> load, and validating the shape of every inline `tests` block.
 *
 * When a JS-side ODE backend lands, this runner is the place to wire
 * numerical execution in — the fixture walk is already here.
 */

import { describe, it, expect } from 'vitest'
import { readdirSync, readFileSync } from 'fs'
import { join } from 'path'
import { load, save } from './index.js'

const simulationDir = join(__dirname, '../../../tests/simulation')

function findSimulationFixtures(): string[] {
  return readdirSync(simulationDir)
    .filter((name) => name.endsWith('.esm'))
    .sort()
}

function validateTestsBlock(label: string, tests: unknown): number {
  expect(Array.isArray(tests), `${label}: tests is not an array`).toBe(true)
  const arr = tests as any[]
  let assertionsSeen = 0
  for (let i = 0; i < arr.length; i++) {
    const tc = arr[i]
    expect(tc, `${label}: tests[${i}] not an object`).toBeTypeOf('object')
    expect(typeof tc.id, `${label}: tests[${i}].id not string`).toBe('string')
    expect(tc.id.length > 0, `${label}/${i}: empty id`).toBe(true)

    expect(tc.time_span, `${label}/${tc.id}: missing time_span`).toBeTypeOf('object')
    expect(typeof tc.time_span.start, `${label}/${tc.id}: time_span.start not number`).toBe(
      'number',
    )
    expect(typeof tc.time_span.end, `${label}/${tc.id}: time_span.end not number`).toBe('number')

    expect(Array.isArray(tc.assertions), `${label}/${tc.id}: assertions not array`).toBe(true)
    expect(tc.assertions.length, `${label}/${tc.id}: expected >=1 assertion`).toBeGreaterThan(0)
    for (let j = 0; j < tc.assertions.length; j++) {
      const a = tc.assertions[j]
      expect(typeof a.variable, `${label}/${tc.id}/a${j}: variable not string`).toBe('string')
      expect(typeof a.time, `${label}/${tc.id}/a${j}: time not number`).toBe('number')
      expect(typeof a.expected, `${label}/${tc.id}/a${j}: expected not number`).toBe('number')
      assertionsSeen++
    }
  }
  return assertionsSeen
}

describe('tests/simulation/ inline tests blocks', () => {
  const fixtures = findSimulationFixtures()

  it('finds at least one simulation fixture', () => {
    expect(fixtures.length).toBeGreaterThan(0)
  })

  // Aggregate across fixtures to guard against a regression that drops all
  // tests blocks — each fixture individually may legitimately omit them.
  let globalTests = 0
  let globalAssertions = 0

  it.each(fixtures)('%s: parses and round-trips', (name) => {
    const path = join(simulationDir, name)
    const text = readFileSync(path, 'utf-8')

    const file = load(text)
    const serialized = save(file)
    const reloaded = load(serialized)
    expect(reloaded).toEqual(file)

    const raw = JSON.parse(text)
    let fixtureTests = 0
    let fixtureAssertions = 0

    const models = raw.models ?? {}
    for (const [mname, mraw] of Object.entries<any>(models)) {
      const tests = mraw?.tests
      if (!tests || tests.length === 0) continue
      fixtureAssertions += validateTestsBlock(`${name}/models/${mname}`, tests)
      fixtureTests += tests.length
    }
    const rsys = raw.reaction_systems ?? {}
    for (const [rsname, rraw] of Object.entries<any>(rsys)) {
      const tests = rraw?.tests
      if (!tests || tests.length === 0) continue
      fixtureAssertions += validateTestsBlock(`${name}/reaction_systems/${rsname}`, tests)
      fixtureTests += tests.length
    }
    globalTests += fixtureTests
    globalAssertions += fixtureAssertions
  })

  // Spec §4.7 — tests/simulation must carry executable inline tests for at
  // least one component, otherwise a schema migration silently stripped them.
  it('aggregates at least one inline test across all fixtures', () => {
    expect(globalTests).toBeGreaterThan(0)
    expect(globalAssertions).toBeGreaterThan(0)
  })
})
