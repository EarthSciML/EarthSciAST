/**
 * Schema-validation conformance tests for the additive aggregate / semiring /
 * index_sets fixtures (bead ess-my4.1.5; RFC semiring-faq-unified-ir §5.1 /
 * §5.2). Exercises the additive schema deltas — op:"aggregate", the closed
 * `semiring` enum, `ranges` { "from": <index-set> } references, and the
 * document-scoped `index_sets` registry — through the TypeScript binding's
 * validate + parse/serialize path. The TS binding does no numeric evaluation,
 * so this is validation / round-trip only (the numeric cross-binding
 * equivalence is asserted by the Julia / Rust / Python evaluator suites).
 */
import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync } from 'fs'
import { join, basename } from 'path'
import { load, save, validate, validateSchema } from './index.js'
import { fixturesDir } from './test-helpers.js'

const testsDir = fixturesDir()

function esmFilesIn(dir: string): string[] {
  return readdirSync(dir)
    .filter((e) => e.endsWith('.esm'))
    .map((e) => join(dir, e))
    .sort()
}

describe('Aggregate / semiring fixtures', () => {
  describe('tests/valid/aggregate', () => {
    const validFiles = esmFilesIn(join(testsDir, 'valid', 'aggregate'))

    it('has fixtures to test', () => {
      expect(validFiles.length).toBeGreaterThan(0)
    })

    it.each(validFiles)('validates and round-trips %s', (filePath) => {
      const content = readFileSync(filePath, 'utf-8')

      // Schema-valid: the additive aggregate/semiring/index_sets fields all
      // satisfy the embedded JSON schema.
      expect(validateSchema(JSON.parse(content))).toHaveLength(0)

      // Structurally valid too: the structural pass is aggregate-aware
      // (ess-my4.1.7). It recognises an LHS-aggregate equation (and the
      // relational `index(v, i) = aggregate(...)` form) as an equation for its
      // output variable, and binds aggregate range / `index` element symbols so
      // contracted indices are not flagged as undefined references.
      const result = validate(content)
      expect(result.schema_errors).toHaveLength(0)
      expect(result.structural_errors).toHaveLength(0)
      expect(result.is_valid).toBe(true)

      // parse -> serialize -> parse is a fixed point on the typed view.
      const original = load(content)
      const reloaded = load(save(original))
      expect(reloaded).toEqual(original)
    })
  })

  describe('tests/invalid/aggregate', () => {
    const invalidFiles = esmFilesIn(join(testsDir, 'invalid', 'aggregate'))

    // Resolver-only invalid fixtures are SCHEMA-VALID but rejected only by an
    // evaluator/resolver the schema-only TS binding does not run (e.g. a genuine
    // template-import cycle needing the import graph). tests/invalid/
    // expected_errors.json marks those `resolver_only: true`; for them the schema
    // validator must ACCEPT the document, so this loop asserts schema acceptance.
    //
    // The F-6 fixtures that USED to be `resolver_only` — `continuous_relational_node`
    // (relational_node_in_continuous) and `undeclared_from_name` (undefined_index_set)
    // — are now PROMOTED to STRUCTURAL pins (bead ess-my4; DECISION 2026-07-15:
    // decidable from the single document, so validate() must reject them). They are
    // still SCHEMA-valid, so schema alone does NOT reject them — the assertion below
    // is against the full validate() pipeline (is_valid === false) and the pinned
    // structural code, which is exactly what the promotion requires.
    const expectedErrors = JSON.parse(
      readFileSync(join(testsDir, 'invalid', 'expected_errors.json'), 'utf-8'),
    ) as Record<
      string,
      { resolver_only?: boolean; structural_errors?: { code: string; path: string }[] }
    >

    it('has fixtures to test', () => {
      expect(invalidFiles.length).toBeGreaterThan(0)
    })

    it.each(invalidFiles)('rejects %s', (filePath) => {
      const content = readFileSync(filePath, 'utf-8')
      const parsed = JSON.parse(content)
      const pin = expectedErrors[basename(filePath)]

      if (pin?.resolver_only) {
        // Schema-valid; the defect is caught only by a resolver the TS binding
        // does not run. The schema validator must ACCEPT it (no errors).
        expect(validateSchema(parsed)).toHaveLength(0)
        return
      }

      // Every other pinned-invalid aggregate fixture must be REJECTED by the full
      // validate() pipeline — whether that rejection is a pure schema violation
      // (unregistered semiring, join not an array / wrong `on` arity, discrete
      // missing shape, ...) or a promoted STRUCTURAL F-6 finding (a relational
      // node reading state, an undeclared index-set range).
      const result = validate(content)
      expect(result.is_valid, `${basename(filePath)} is pinned invalid but was accepted`).toBe(
        false,
      )

      // Where the corpus pins a structural code, assert THAT code was emitted —
      // "some error" is too weak a contract for the F-6 promotions.
      const pinnedCode = pin?.structural_errors?.[0]?.code
      if (pinnedCode) {
        const codes = result.structural_errors.map((e) => e.code)
        expect(
          codes,
          `${basename(filePath)}: corpus pins "${pinnedCode}", binding emitted: ${codes.join(', ') || '(none)'}`,
        ).toContain(pinnedCode)
      }
    })
  })
})
