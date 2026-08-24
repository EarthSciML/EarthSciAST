/**
 * Drives the shared `flatten` conformance corpus
 * (`tests/conformance/flatten/cases.json`).
 *
 * The corpus is generated from the PYTHON oracle
 * (`scripts/generate-flatten-corpus.py`) and pins the canonical
 * `FlattenedSystem` field set of esm-libraries-spec §4.7.5 step 4 for 19 shared
 * fixtures, plus 2 refusals. TypeScript is a CONSUMER of it, not its oracle, so
 * this suite is where the corpus does its real work: every field is compared as
 * an ORDERED sequence, never as a set.
 *
 * Order is the property most likely to differ silently. Step 4 makes DOCUMENT
 * order normative — components in file order, variables in declaration order,
 * coupling-merged entries keeping first-occurrence position — because a
 * parameter vector is positional. `fixtures/sde/ornstein_uhlenbeck.esm` is the
 * standing witness: it declares `x, theta, sigma, Bw`, so its recorded parameter
 * list `[OU.theta, OU.sigma, OU.Bw]` fails under sorted order, under reverse
 * order, and under any host-map iteration order. The dedicated ordering test at
 * the bottom states that explicitly, so a regression names the rule it broke
 * instead of dumping a diff.
 *
 * Equations are compared through `toAscii` — the same renderer the shared
 * display fixtures and the expression-parse corpus use, and the one the
 * generator recorded with.
 */
import { describe, expect, it } from 'vitest'
import { flatten, type FlattenedVariable, type FlattenedVariableMap } from './flatten.js'
import { updateRules } from './classification.js'
import { toAscii } from './pretty-print.js'
import { loadFixture, readFixture } from './test-helpers.js'
import type { AffectEquation, ContinuousEvent, DiscreteEvent, Expression } from './types.js'

// --- the corpus's JSON shape -------------------------------------------------

interface VariableCase {
  name: string
  role: string
  units: string | null
  default: unknown
  shape: string[] | null
  update_kinds: string[]
  distribution_kind: string | null
  source_system: string | null
}
interface EquationCase {
  lhs: string
  rhs: string
  source_system: string
}
interface EventCase {
  name: string | null
  conditions: string[]
  affects: string[]
}
interface LoaderFieldCase {
  name: string
  owner: string
  source: string
  file_variable: string
  cadence: string
}
interface FlattenCase {
  id: string
  tier: string
  fixture: string
  system_kind: string
  independent_variables: string[]
  state_variables: VariableCase[]
  parameters: VariableCase[]
  observed_variables: VariableCase[]
  algebraic_variables: string[]
  brownian_parameters: string[]
  discrete_parameters: string[]
  equation_count: number
  equations: EquationCase[]
  continuous_events: EventCase[]
  discrete_events: EventCase[]
  domain: {
    independent_variable: string | null
    element_type: string | null
    array_type: string | null
  } | null
  metadata: {
    source_systems: string[]
    coupling_rules: string[]
    operator_applies: string[]
    callbacks: string[]
  }
  index_sets: string[]
  function_tables: string[]
  template_registry: string[]
  field_ics: Array<{ state: string; expr: string }>
  loader_fields: LoaderFieldCase[]
  lifted_shapes: Record<string, number[]>
}
interface Refusal {
  fixture: string
  error: string
  reason: string
}
interface Corpus {
  oracle: string
  cases: FlattenCase[]
  refusals: Refusal[]
}

const corpus: Corpus = JSON.parse(readFixture('conformance', 'flatten', 'cases.json')) as Corpus

/** Load a corpus fixture by its `tests/`-relative path. */
function load(relative: string) {
  return loadFixture(...relative.split('/'))
}

// --- the TS side of the record, in the corpus's language-neutral form --------

function variableRecord(v: FlattenedVariable): VariableCase {
  return {
    name: v.name,
    role: v.type,
    units: v.units ?? null,
    default: v.default ?? null,
    shape: v.shape !== undefined && v.shape.length > 0 ? v.shape : null,
    update_kinds: updateRules(v.update).map((r) => r.kind),
    distribution_kind: (v.distribution as { kind?: string } | undefined)?.kind ?? null,
    source_system: v.sourceSystem ?? null,
  }
}

function variableRecords(map: FlattenedVariableMap): VariableCase[] {
  return Object.values(map).map(variableRecord)
}

function affectString(a: AffectEquation): string {
  return `${toAscii(a.lhs as Expression)} = ${toAscii(a.rhs)}`
}

function eventRecord(e: ContinuousEvent | DiscreteEvent): EventCase {
  const conditions = (e as ContinuousEvent).conditions ?? []
  return {
    name: e.name ?? null,
    conditions: conditions.map((c) => toAscii(c)),
    affects: (e.affects ?? []).map(affectString),
  }
}

describe('flatten conformance corpus (esm-libraries-spec §4.7.5 step 4)', () => {
  it('covers every corpus case', () => {
    // 22 = the 19 of the previous recording plus the new `operator_compose`
    // tier (minimal_chemistry, metadata_inheritance_coupled,
    // bare_reference_resolution) — the three shared fixtures whose operator
    // model is really spelled with `_var`, which is what makes a composition
    // observable at all.
    expect(corpus.cases.length).toBe(22)
    expect(corpus.refusals.length).toBe(3)
    expect(corpus.oracle).toContain('earthsci_ast.flatten')
  })

  describe.each(corpus.cases.map((c) => [c.id, c] as const))('%s', (_id, expected) => {
    // No options: the corpus generator calls `flatten(load_path(path))` with the
    // default base path, and no corpus fixture carries a `coupling_import`.
    const flat = flatten(load(expected.fixture))

    // --- the ordered maps, WITH their per-variable metadata -----------------
    //
    // Compared as ARRAYS: `toEqual` on an array is order-sensitive, which is the
    // whole point. A membership-only assertion would pass under sorted order and
    // hide the exact defect this corpus exists to catch.

    it('state_variables (ordered, with metadata)', () => {
      expect(variableRecords(flat.stateVariables)).toEqual(expected.state_variables)
    })

    it('parameters (ordered, with metadata)', () => {
      expect(variableRecords(flat.parameters)).toEqual(expected.parameters)
    })

    it('observed_variables (ordered, with metadata)', () => {
      expect(variableRecords(flat.observedVariables)).toEqual(expected.observed_variables)
    })

    // --- the §6.3.1 SUBSETS -------------------------------------------------

    it('algebraic_variables is an ordered subset of state_variables', () => {
      const names = Object.keys(flat.algebraicVariables)
      expect(names).toEqual(expected.algebraic_variables)
      // esm-libraries-spec §4.7.5 step 4: a subset, not a sibling bucket. A
      // binding that files algebraic unknowns in a bucket DISJOINT from
      // `state_variables` emits a `u` vector that silently omits them.
      for (const name of names) {
        expect(Object.keys(flat.stateVariables)).toContain(name)
      }
    })

    it('brownian_parameters is an ordered subset of parameters', () => {
      const names = Object.keys(flat.brownianParameters)
      expect(names).toEqual(expected.brownian_parameters)
      // esm-spec §6.3.1: the four parameter sets PARTITION the parameters, so a
      // wiener-updated entry is a parameter that ALSO appears here. Removing it
      // from `parameters` makes the vector's LENGTH depend on whether the model
      // happens to be stochastic.
      for (const name of names) expect(Object.keys(flat.parameters)).toContain(name)
    })

    it('discrete_parameters is an ordered subset of parameters', () => {
      const names = Object.keys(flat.discreteParameters)
      expect(names).toEqual(expected.discrete_parameters)
      for (const name of names) expect(Object.keys(flat.parameters)).toContain(name)
      // ... and the two subsets are disjoint.
      for (const name of names) expect(Object.keys(flat.brownianParameters)).not.toContain(name)
    })

    // --- equations, events, registries --------------------------------------

    it('equations (ordered, rendered with toAscii)', () => {
      const rendered: EquationCase[] = flat.equations.map((eq) => ({
        lhs: toAscii(eq.lhs),
        rhs: toAscii(eq.rhs),
        source_system: eq.sourceSystem,
      }))
      expect(rendered).toEqual(expected.equations)
      expect(flat.equations.length).toBe(expected.equation_count)
    })

    it('field_ics (ordered) and their removal from equations', () => {
      expect(flat.fieldIcs.map((ic) => ({ state: ic.state, expr: toAscii(ic.expr) }))).toEqual(
        expected.field_ics,
      )
      // Normative: an `ic` is a datum, not an equation of motion, so no
      // surviving equation may still carry an `ic` LHS.
      for (const eq of flat.equations) {
        const lhs = eq.lhs as { op?: string }
        expect(lhs?.op).not.toBe('ic')
      }
    })

    it('continuous_events / discrete_events (ordered)', () => {
      expect(flat.continuousEvents.map(eventRecord)).toEqual(expected.continuous_events)
      expect(flat.discreteEvents.map(eventRecord)).toEqual(expected.discrete_events)
    })

    it('independent_variables and the derived system_kind', () => {
      expect(flat.independentVariables).toEqual(expected.independent_variables)
      expect(flat.systemKind).toBe(expected.system_kind)
    })

    it('domain and metadata', () => {
      // The FULL domain record is compared. `element_type` / `array_type` were
      // exempted while the oracle could not represent them — Python's `Domain`
      // dataclass carried neither field, so `load` dropped them and the corpus
      // recorded null for every case. That gap is CLOSED (the oracle now parses
      // AND serializes both; its round trip had been lossy too), so these are
      // compared like any other field.
      expect(flat.domain === null).toBe(expected.domain === null)
      if (flat.domain !== null && expected.domain !== null) {
        expect(flat.domain.independent_variable ?? null).toBe(expected.domain.independent_variable)
        expect(flat.domain.element_type ?? null).toBe(expected.domain.element_type)
        expect(flat.domain.array_type ?? null).toBe(expected.domain.array_type)
      }
      expect(flat.metadata.sourceSystems).toEqual(expected.metadata.source_systems)
      expect(flat.metadata.couplingRules).toEqual(
        expected.metadata.coupling_rules,
      )
      expect(flat.metadata.operatorApplies).toEqual(expected.metadata.operator_applies)
      expect(flat.metadata.callbacks).toEqual(expected.metadata.callbacks)
    })

    it('index_sets / function_tables / template_registry (ordered keys)', () => {
      expect(Object.keys(flat.indexSets)).toEqual(expected.index_sets)
      expect(Object.keys(flat.functionTables)).toEqual(expected.function_tables)
      expect(Object.keys(flat.templateRegistry)).toEqual(expected.template_registry)
    })

    it('loader_fields (ordered) and lifted_shapes', () => {
      const fields: LoaderFieldCase[] = flat.loaderFields.map((lf) => ({
        name: lf.name,
        owner: lf.owner,
        source: lf.subkey,
        file_variable: lf.var,
        cadence: lf.cadence,
      }))
      expect(fields).toEqual(expected.loader_fields)
      // The generator sorts `lifted_shapes` keys, so this one comparison is
      // key-order-insensitive by construction.
      const shapes: Record<string, number[]> = {}
      for (const k of Object.keys(flat.liftedShapes).sort()) shapes[k] = flat.liftedShapes[k]
      expect(shapes).toEqual(expected.lifted_shapes)
    })
  })

  // --- domain pass-through, pinned independently of the corpus --------------

  it('carries Domain.element_type through flatten unchanged', () => {
    // esm-libraries-spec §4.7.5 step 4: `domain` is "The file's `domain`
    // section, unchanged". `element_type` selects Float32 vs Float64 — a real
    // numerical property of the assembled problem — and `array_type` selects
    // the array backend (e.g. "CuArray").
    //
    // These were once null for EVERY corpus case: the Python oracle's `Domain`
    // dataclass carried neither field, so `load` dropped them before flatten ran
    // and the generator recorded null. TypeScript was right and the oracle was
    // wrong. The oracle was fixed on 2026-08-24 and the corpus regenerated, so
    // the per-case comparison above now covers both fields.
    //
    // This keeps the corpus-INDEPENDENT half: `model_only.esm` declares Float32,
    // so the pass-through stays pinned even if no corpus fixture declares it.
    const flat = flatten(load('valid/model_only.esm'))
    expect(flat.domain?.element_type).toBe('Float32')
  })

  // --- refusals -------------------------------------------------------------

  it('refuses a pure template LIBRARY (nothing to flatten)', () => {
    const entry = corpus.refusals.find((r) => r.fixture === 'valid/template_import_lib.esm')
    expect(entry).toBeDefined()
    // The oracle raises `ValueError`; TypeScript's equivalent is `FlattenError`
    // (both are "this document cannot be flattened", not a diagnostic finding).
    expect(() => flatten(load(entry!.fixture))).toThrow(/no models or reaction systems/)
  })

  it('never reaches flatten for a non-terminating rewrite (rejected at LOAD)', () => {
    const entry = corpus.refusals.find((r) =>
      r.fixture.includes('nonterminating_rewrite'),
    ) as Refusal
    expect(entry.error).toBe('ExpressionTemplateError')
    // esm-spec §9.6.3: the fixpoint bound rejects it before flatten ever sees it,
    // so the refusal belongs to LOAD. Recorded here so a binding that reaches
    // flatten with this document knows which pass is wrong.
    expect(() => load(entry.fixture)).toThrow()
  })
})

// ---------------------------------------------------------------------------
// Ordering, stated as its own rule
// ---------------------------------------------------------------------------

describe('document order is observable (esm-libraries-spec §4.7.5 step 4)', () => {
  it('ornstein_uhlenbeck keeps declaration order, which is NOT sorted order', () => {
    const flat = flatten(loadFixture('fixtures', 'sde', 'ornstein_uhlenbeck.esm'))

    // The document declares x, theta, sigma, Bw — deliberately not alphabetical.
    expect(Object.keys(flat.parameters)).toEqual(['OU.theta', 'OU.sigma', 'OU.Bw'])
    expect(Object.keys(flat.stateVariables)).toEqual(['OU.x'])

    // The assertion that fails under sorting: `[...].sort()` differs from what
    // flatten produced. Without this line a binding could sort its maps and the
    // equality above would still be the only thing distinguishing it.
    const sorted = [...Object.keys(flat.parameters)].sort()
    expect(sorted).not.toEqual(Object.keys(flat.parameters))

    // The wiener parameter is IN `parameters` and ALSO in `brownianParameters`
    // (esm-spec §6.3.1's partition), and carrying that bucket is what lets the
    // flattened form report "sde" at all.
    expect(Object.keys(flat.brownianParameters)).toEqual(['OU.Bw'])
    expect(flat.systemKind).toBe('sde')
  })
})
