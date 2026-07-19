/**
 * Unit tests for expression_templates / apply_expression_template
 * (esm-spec §9.6, docs/rfcs/ast-expression-templates.md, esm-giy).
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { describe, it, expect } from 'vitest'
import { load } from './parse.js'
import {
  lowerExpressionTemplates,
  expandDocument,
  EsmMachineryError,
  // Deprecated same-class alias — imported to assert backward compatibility below.
  ExpressionTemplateError,
} from './lower-expression-templates.js'
import { EsmDiagnosticError } from './errors.js'
import { evaluateExpression, UnloweredOperatorError } from './codegen.js'
import { fixturesDir, REPO_ROOT } from './test-helpers.js'
import { save } from './serialize.js'
import { validate } from './validate.js'
import type { ReactionSystem } from './types.js'

// Canonical Arrhenius template fixture: 5 reactions sharing one
// `arrhenius` template and one inline rate, plus an arithmetic check.
const ARRHENIUS_FIXTURE = {
  esm: '0.4.0',
  metadata: { name: 'expr_template_smoke', authors: ['esm-giy'] },
  reaction_systems: {
    chem: {
      species: {
        A: { default: 1.0 },
        B: { default: 0.5 },
        C: { default: 0.0 },
      },
      parameters: {
        T: { default: 298.15 },
        num_density: { default: 2.5e19 },
      },
      expression_templates: {
        arrhenius: {
          params: ['A_pre', 'Ea'],
          body: {
            op: '*',
            args: [
              'A_pre',
              {
                op: 'exp',
                args: [{ op: '/', args: [{ op: '-', args: ['Ea'] }, 'T'] }],
              },
              'num_density',
            ],
          },
        },
      },
      reactions: [
        {
          id: 'R1',
          substrates: [{ species: 'A', stoichiometry: 1 }],
          products: [{ species: 'B', stoichiometry: 1 }],
          rate: {
            op: 'apply_expression_template',
            args: [],
            name: 'arrhenius',
            bindings: { A_pre: 1.8e-12, Ea: 1500 },
          },
        },
        {
          id: 'R2',
          substrates: [{ species: 'B', stoichiometry: 1 }],
          products: [{ species: 'C', stoichiometry: 1 }],
          rate: {
            op: 'apply_expression_template',
            args: [],
            name: 'arrhenius',
            bindings: { A_pre: 3.4e-13, Ea: 800 },
          },
        },
      ],
    },
  },
}

function inlineArrhenius(A: number, Ea: number) {
  return {
    op: '*',
    args: [
      A,
      { op: 'exp', args: [{ op: '/', args: [{ op: '-', args: [Ea] }, 'T'] }] },
      'num_density',
    ],
  }
}

describe('expression_templates / apply_expression_template (esm-giy)', () => {
  it('expands apply_expression_template at load time and strips the templates block', () => {
    const file = load(JSON.parse(JSON.stringify(ARRHENIUS_FIXTURE)))
    const sys = file.reaction_systems!.chem as unknown as Record<string, unknown>
    expect('expression_templates' in sys).toBe(false)
    // Both reactions should have a rate AST identical to the inline form.
    const reactions = sys.reactions as Array<{ rate: unknown }>
    expect(reactions[0].rate).toEqual(inlineArrhenius(1.8e-12, 1500))
    expect(reactions[1].rate).toEqual(inlineArrhenius(3.4e-13, 800))
  })

  it('expansion is structurally identical to inlining (determinism)', () => {
    const a = lowerExpressionTemplates(JSON.parse(JSON.stringify(ARRHENIUS_FIXTURE)))
    const b = lowerExpressionTemplates(JSON.parse(JSON.stringify(ARRHENIUS_FIXTURE)))
    expect(a).toEqual(b)
  })

  it('files without templates parse unchanged', () => {
    const noTemplates = {
      esm: '0.4.0',
      metadata: { name: 'no_templates', authors: ['t'] },
      reaction_systems: {
        chem: {
          species: { A: {} },
          parameters: { k: { default: 1.0 } },
          reactions: [
            {
              id: 'R1',
              substrates: [{ species: 'A', stoichiometry: 1 }],
              products: null,
              rate: 'k',
            },
          ],
        },
      },
    }
    const file = load(JSON.parse(JSON.stringify(noTemplates)))
    expect((file.reaction_systems!.chem as ReactionSystem).reactions[0].rate).toBe('k')
  })

  it('rejects apply_expression_template when esm < 0.4.0', () => {
    const oldVersion = {
      ...JSON.parse(JSON.stringify(ARRHENIUS_FIXTURE)),
      esm: '0.3.5',
    }
    expect(() => load(oldVersion)).toThrow(/version_too_old|0\.4\.0/)
  })

  it('rejects unknown template name', () => {
    const fixture = JSON.parse(JSON.stringify(ARRHENIUS_FIXTURE))
    fixture.reaction_systems.chem.reactions[0].rate.name = 'unknown_form'
    expect(() => load(fixture)).toThrow(/unknown_template/)
  })

  it('rejects bindings with extra params', () => {
    const fixture = JSON.parse(JSON.stringify(ARRHENIUS_FIXTURE))
    fixture.reaction_systems.chem.reactions[0].rate.bindings.bogus = 99
    expect(() => load(fixture)).toThrow(/bindings_mismatch/)
  })

  it('rejects bindings missing a param', () => {
    const fixture = JSON.parse(JSON.stringify(ARRHENIUS_FIXTURE))
    delete fixture.reaction_systems.chem.reactions[0].rate.bindings.Ea
    expect(() => load(fixture)).toThrow(/bindings_mismatch/)
  })

  it('rejects nested apply_expression_template inside a template body', () => {
    const fixture = JSON.parse(JSON.stringify(ARRHENIUS_FIXTURE))
    // Inject a recursive body
    fixture.reaction_systems.chem.expression_templates.arrhenius.body = {
      op: 'apply_expression_template',
      args: [],
      name: 'arrhenius',
      bindings: { A_pre: 1, Ea: 1 },
    }
    expect(() => load(fixture)).toThrow(/recursive_body/)
  })

  it('expansion accepts AST-valued bindings (not just scalars)', () => {
    const fixture = JSON.parse(JSON.stringify(ARRHENIUS_FIXTURE))
    fixture.reaction_systems.chem.reactions[0].rate.bindings.Ea = {
      op: '*',
      args: [3, 'T'],
    }
    const file = load(fixture)
    const rate = (file.reaction_systems!.chem as ReactionSystem).reactions[0].rate as Record<
      string,
      unknown
    >
    expect(rate.op).toBe('*')
    // The inner exp's argument should be (-(3*T))/T (post-substitution).
    const args = rate.args as Array<unknown>
    expect(args[0]).toBe(1.8e-12)
    expect((args[1] as Record<string, unknown>).op).toBe('exp')
  })

  it('conformance fixture matches the canonical expanded form (cross-binding pin)', () => {
    const fixturePath = fixturesDir('conformance/expression_templates/arrhenius_smoke/fixture.esm')
    const expandedPath = fixturesDir(
      'conformance/expression_templates/arrhenius_smoke/expanded.esm',
    )
    const file = load(fs.readFileSync(fixturePath, 'utf8'))
    const expanded = JSON.parse(fs.readFileSync(expandedPath, 'utf8'))
    expect((file.reaction_systems!.chem as ReactionSystem).reactions).toEqual(
      expanded.reaction_systems.chem.reactions,
    )
  })

  it('coupling_transform_expression conformance fixture matches expanded form (esm-spec §10.4)', () => {
    // The v0.8.0 variable_map expression-transform widening: a coupling
    // `transform` invoking a template declared by the RECEIVING component
    // expands at load against that component's registry (§9.6.4).
    const casedir = fixturesDir('conformance/expression_templates/coupling_transform_expression')
    const file = load(
      fs.readFileSync(path.join(casedir, 'fixture.esm'), 'utf8'),
    ) as unknown as Record<string, unknown>
    const expanded = JSON.parse(fs.readFileSync(path.join(casedir, 'expanded.esm'), 'utf8'))
    expect(file.coupling).toEqual(expanded.coupling)
    expect(file.models).toEqual(expanded.models)
  })

  it('EsmMachineryError is thrown with stable diagnostic codes', () => {
    const fixture = JSON.parse(JSON.stringify(ARRHENIUS_FIXTURE))
    fixture.reaction_systems.chem.reactions[0].rate.name = 'missing'
    try {
      load(fixture)
      throw new Error('expected error')
    } catch (e) {
      expect(e).toBeInstanceOf(EsmMachineryError)
      expect((e as EsmMachineryError).code).toBe('apply_expression_template_unknown_template')
    }
  })
})

// ---------------------------------------------------------------------------
// Auto-applied `match` rewrite rules (esm-spec §9.6, §9.6.8).
// ---------------------------------------------------------------------------

function gradModel(templates: Record<string, unknown>, rhs: unknown) {
  return {
    esm: '0.4.0',
    metadata: { name: 'rewrite_rules', authors: ['t'] },
    models: {
      M: {
        expression_templates: templates,
        equations: [{ lhs: 'q', rhs }],
      },
    },
  }
}

describe('match rewrite rules (esm-spec §9.6 auto-applied lowering)', () => {
  it('auto-applies an operator-lowering rule: binds operand, passes through unbound params', () => {
    const file = gradModel(
      {
        central_grad_x: {
          params: ['f', 'dx'],
          match: { op: 'grad', args: ['f'], dim: 'x' },
          body: { op: '/', args: [{ op: '-', args: ['f', 'f'] }, 'dx'] },
        },
      },
      { op: 'grad', args: ['c'], dim: 'x' },
    )
    const out = lowerExpressionTemplates(file) as any
    // Option B (esm-spec §9.6.4 rule 1): the registry is RETAINED at load.
    expect('expression_templates' in out.models.M).toBe(true)
    // f → "c" (operand); dx unbound by `match`, so it stays a bare ref.
    expect(out.models.M.equations[0].rhs).toEqual({
      op: '/',
      args: [{ op: '-', args: ['c', 'c'] }, 'dx'],
    })
  })

  it('binds an operand metavariable to a full sub-AST (repeated occurrences)', () => {
    const file = gradModel(
      {
        dup: {
          params: ['f'],
          match: { op: 'grad', args: ['f'], dim: 'x' },
          body: { op: 'makearray', args: ['f', 'f'] },
        },
      },
      { op: 'grad', args: [{ op: '+', args: ['a', 'b'] }], dim: 'x' },
    )
    const out = lowerExpressionTemplates(file) as any
    expect(out.models.M.equations[0].rhs).toEqual({
      op: 'makearray',
      args: [
        { op: '+', args: ['a', 'b'] },
        { op: '+', args: ['a', 'b'] },
      ],
    })
  })

  it('binds a scalar-field metavariable (dim) to the matched literal', () => {
    const file = gradModel(
      {
        grad_any: {
          params: ['f', 'd'],
          match: { op: 'grad', args: ['f'], dim: 'd' },
          body: { op: 'index', args: ['f'], along: 'd' },
        },
      },
      { op: 'grad', args: ['c'], dim: 'y' },
    )
    const out = lowerExpressionTemplates(file) as any
    // d → "y" (scalar field literal), substituted into the body's `along` field.
    expect(out.models.M.equations[0].rhs).toEqual({ op: 'index', args: ['c'], along: 'y' })
  })

  it('applies match rules in declaration order (first match wins)', () => {
    const file = gradModel(
      {
        rule_a: {
          params: ['f'],
          match: { op: 'grad', args: ['f'], dim: 'x' },
          body: { op: 'sin', args: ['f'] },
        },
        rule_b: {
          params: ['g'],
          match: { op: 'grad', args: ['g'], dim: 'x' },
          body: { op: 'cos', args: ['g'] },
        },
      },
      { op: 'grad', args: ['c'], dim: 'x' },
    )
    const out = lowerExpressionTemplates(file) as any
    expect(out.models.M.equations[0].rhs).toEqual({ op: 'sin', args: ['c'] })
  })

  it('re-scans a produced body in a SUBSEQUENT pass (bounded fixpoint)', () => {
    // 0.8.0 outermost-first + fixpoint (esm-spec §9.6.3): a freshly-produced
    // body is NOT re-matched within the pass that produced it, but IS re-scanned
    // in the NEXT pass. So grad → div (pass 1) then div → abs (pass 2).
    const file = gradModel(
      {
        g2d: {
          params: ['f'],
          match: { op: 'grad', args: ['f'], dim: 'x' },
          body: { op: 'div', args: ['f'], dim: 'x' },
        },
        d2z: {
          params: ['f'],
          match: { op: 'div', args: ['f'], dim: 'x' },
          body: { op: 'abs', args: ['f'] },
        },
      },
      { op: 'grad', args: ['c'], dim: 'x' },
    )
    const out = lowerExpressionTemplates(file) as any
    expect(out.models.M.equations[0].rhs).toEqual({ op: 'abs', args: ['c'] })
  })

  it('selects the highest-priority matching rule; ties break by declaration order', () => {
    // esm-spec §9.6.3: when several rules match a node, the highest `priority`
    // wins (default 0). Here `lo` is declared first but `hi` (priority 5)
    // out-ranks it and fires.
    const file = gradModel(
      {
        lo: {
          params: ['f'],
          match: { op: 'grad', args: ['f'], dim: 'x' },
          body: { op: 'sin', args: ['f'] },
        },
        hi: {
          params: ['f'],
          priority: 5,
          match: { op: 'grad', args: ['f'], dim: 'x' },
          body: { op: 'cos', args: ['f'] },
        },
      },
      { op: 'grad', args: ['c'], dim: 'x' },
    )
    const out = lowerExpressionTemplates(file) as any
    expect(out.models.M.equations[0].rhs).toEqual({ op: 'cos', args: ['c'] })
  })

  it('rejects a self-reintroducing rule via the pass bound (rewrite_rule_nonterminating)', () => {
    // 0.8.0: nontermination is caught by the MAX_REWRITE_PASSES=64 bound at
    // load time, NOT by a static pre-check. A rule whose body wraps its own
    // pattern grows the tree every pass and never converges.
    const file = gradModel(
      {
        bad: {
          params: ['f'],
          match: { op: 'grad', args: ['f'], dim: 'x' },
          body: { op: '+', args: [{ op: 'grad', args: ['f'], dim: 'x' }, 'f'] },
        },
      },
      { op: 'grad', args: ['c'], dim: 'x' },
    )
    expect(() => lowerExpressionTemplates(file)).toThrow(/rewrite_rule_nonterminating/)
    try {
      lowerExpressionTemplates(file)
      throw new Error('expected error')
    } catch (e) {
      expect((e as EsmMachineryError).code).toBe('rewrite_rule_nonterminating')
    }
  })

  it('ignores node fields the pattern omits; leaves non-matching nodes untouched', () => {
    const file = {
      esm: '0.4.0',
      metadata: { name: 'partial_match', authors: ['t'] },
      models: {
        M: {
          expression_templates: {
            grad_x: {
              params: ['f'],
              match: { op: 'grad', args: ['f'], dim: 'x' },
              body: { op: 'makearray', args: ['f'] },
            },
          },
          equations: [
            // Matches despite carrying an extra field absent from the pattern.
            { lhs: 'p', rhs: { op: 'grad', args: ['c'], dim: 'x', note: 'keep' } },
            // Does not match (dim differs) — left untouched.
            { lhs: 'q', rhs: { op: 'grad', args: ['c'], dim: 'y' } },
          ],
        },
      },
    }
    const out = lowerExpressionTemplates(file) as any
    expect(out.models.M.equations[0].rhs).toEqual({ op: 'makearray', args: ['c'] })
    expect(out.models.M.equations[1].rhs).toEqual({ op: 'grad', args: ['c'], dim: 'y' })
  })

  it('accepts the `match` field through load() and auto-applies the rule', () => {
    const fixture = {
      esm: '0.4.0',
      metadata: { name: 'match_load', authors: ['t'] },
      reaction_systems: {
        chem: {
          species: { A: { default: 1.0 }, B: { default: 0.0 } },
          parameters: { T: { default: 298.15 }, num_density: { default: 2.5e19 } },
          expression_templates: {
            max_to_sum: {
              params: ['a', 'b'],
              match: { op: 'max', args: ['a', 'b'] },
              body: { op: '+', args: ['a', 'b'] },
            },
          },
          reactions: [
            {
              id: 'R1',
              substrates: [{ species: 'A', stoichiometry: 1 }],
              products: [{ species: 'B', stoichiometry: 1 }],
              rate: { op: 'max', args: ['T', 'num_density'] },
            },
          ],
        },
      },
    }
    const file = load(fixture)
    expect((file.reaction_systems!.chem as ReactionSystem).reactions[0].rate).toEqual({
      op: '+',
      args: ['T', 'num_density'],
    })
    expect(
      'expression_templates' in (file.reaction_systems!.chem as unknown as Record<string, unknown>),
    ).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// 0.8.0 outermost-first + priority + bounded-fixpoint engine, and the
// `unlowered_operator` evaluation gate. Mirrors the Julia reference testset
// ("expression_templates rewrite engine — 0.8.0 outermost-first + fixpoint")
// and drives the cross-binding conformance fixtures under
// tests/conformance/expression_templates/
// (docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md §8).
// ---------------------------------------------------------------------------

describe('0.8.0 outermost-first + fixpoint rewrite engine (conformance fixtures)', () => {
  const confDir = fixturesDir('conformance/expression_templates')
  const fixtureText = (name: string) =>
    fs.readFileSync(path.join(confDir, name, 'fixture.esm'), 'utf8')
  // Mirror the Julia driver `_lower_conf`: parse the fixture and run the
  // load-time lowering directly.
  const lowerFixture = (name: string) =>
    lowerExpressionTemplates(JSON.parse(fixtureText(name))) as any
  const expandedVars = (name: string) =>
    JSON.parse(fs.readFileSync(path.join(confDir, name, 'expanded.esm'), 'utf8')).models.m.variables
  const goldenError = (name: string) =>
    JSON.parse(fs.readFileSync(path.join(confDir, name, 'error.json'), 'utf8'))

  it('godunov compound rule beats inner derivative (priority + outermost-first)', () => {
    // The priority:100 compound rule fires on the WHOLE sqrt(D(u,x)^2 + D(u,y)^2)
    // before the priority:0 central-difference D rule can lower either inner D.
    const out = lowerFixture('godunov_beats_inner_deriv')
    expect(out.models.m.variables).toEqual(expandedVars('godunov_beats_inner_deriv'))
    expect(out.models.m.variables.grad_mag.expression).toEqual({
      op: '*',
      args: ['godunov_coef', 'u'],
    })
    // The per-derivative rule (which alone emits `inv_dx`) never touched the
    // inner D nodes; the marker parameter still appears in the vars dict but not
    // in the rewritten expression.
    const exprJson = JSON.stringify(out.models.m.variables.grad_mag.expression)
    expect(exprJson).not.toContain('inv_dx')
    expect(exprJson).toContain('godunov_coef')
  })

  it('nested-derivative fixpoint converges across passes', () => {
    // laplacian -> D(D(u,x),x)+D(D(u,y),y) (pass 1), then each nested D ->
    // stencil (pass 2). A produced body is re-scanned only in a subsequent pass.
    const out = lowerFixture('fixpoint_nested_deriv')
    expect(out.models.m.variables).toEqual(expandedVars('fixpoint_nested_deriv'))
    expect(out.models.m.variables.lap.expression).toEqual({
      op: '+',
      args: [
        { op: '*', args: ['inv_dx2', 'u'] },
        { op: '*', args: ['inv_dy2', 'u'] },
      ],
    })
    const exprJson = JSON.stringify(out.models.m.variables.lap.expression)
    expect(exprJson).not.toContain('laplacian')
    expect(exprJson).not.toContain('"op":"D"')
  })

  it('self-reintroducing rule rejected by the pass bound (rewrite_rule_nonterminating)', () => {
    let err: unknown
    try {
      lowerFixture('nonterminating_rewrite')
    } catch (e) {
      err = e
    }
    expect(err).toBeInstanceOf(EsmMachineryError)
    expect((err as EsmMachineryError).code).toBe('rewrite_rule_nonterminating')
    // Also fires through the full load() pipeline (stage: "load").
    expect(() => load(fixtureText('nonterminating_rewrite'))).toThrow(/rewrite_rule_nonterminating/)
    expect((err as EsmMachineryError).code).toBe(goldenError('nonterminating_rewrite').code)
  })

  it('unlowered spatial D loads clean, then errors `unlowered_operator` at evaluation', () => {
    // Open namespace (esm-spec §4.2): the file LOADS fine — the gate is deferred
    // to evaluation, mirroring the Julia `_compile` gate (stage: "evaluate").
    const file = load(fixtureText('unlowered_operator')) as any
    const rhs = file.models.m.equations[0].rhs
    expect(rhs).toEqual({ op: 'D', args: ['u'], wrt: 'x' })
    // Reaching evaluation yields the uniform `unlowered_operator` diagnostic.
    let err: unknown
    try {
      evaluateExpression(rhs, new Map<string, number>([['u', 1.0]]))
    } catch (e) {
      err = e
    }
    expect(err).toBeInstanceOf(UnloweredOperatorError)
    expect((err as UnloweredOperatorError).code).toBe('unlowered_operator')
    expect(String(err)).toMatch(/unlowered_operator/)
    expect((err as UnloweredOperatorError).code).toBe(goldenError('unlowered_operator').code)
  })

  it('grad/div/laplacian also gate as `unlowered_operator` at evaluation', () => {
    for (const op of ['grad', 'div', 'laplacian']) {
      let err: unknown
      try {
        evaluateExpression({ op, args: ['x'], dim: 'x' } as any, new Map([['x', 1.0]]))
      } catch (e) {
        err = e
      }
      expect((err as UnloweredOperatorError).code).toBe('unlowered_operator')
      expect(String(err)).toContain(op)
    }
  })

  it('attrs on a rewrite-target op bind as scalar metavariables', () => {
    // esm-spec §4.2 open tier: a custom op carries scheme params in `attrs`;
    // a `match` pattern's `attrs.<key>` set to a bare param binds it to the
    // matched literal. Falls out of generic structural matching — no engine
    // special-casing.
    const src = {
      esm: '0.8.0',
      metadata: { name: 'attrs_match', authors: ['t'] },
      models: {
        m: {
          variables: {
            u: { type: 'state', units: '1', default: 0.0 },
            y: {
              type: 'observed',
              units: '1',
              expression: { op: 'custom_scheme', args: ['u'], attrs: { gamma: 1.4 } },
            },
          },
          equations: [],
          expression_templates: {
            lower_custom: {
              params: ['f', 'g'],
              match: { op: 'custom_scheme', args: ['f'], attrs: { gamma: 'g' } },
              body: { op: '*', args: ['g', 'f'] },
            },
          },
        },
      },
    }
    const out = lowerExpressionTemplates(JSON.parse(JSON.stringify(src))) as any
    expect(out.models.m.variables.y.expression).toEqual({ op: '*', args: [1.4, 'u'] })
    // Option B (esm-spec §9.6.4 rule 1): the registry is RETAINED at load.
    expect('expression_templates' in out.models.m).toBe(true)
  })
})

describe('coupling variable_map expression transforms (receiving-component rewrite scope)', () => {
  // Model "Sink" (the RECEIVER — first dot-segment of the entry's `to`)
  // declares the template; the coupling transform invokes it.
  const couplingFixture = () => ({
    esm: '0.8.0',
    metadata: { name: 'coupling_transform_expansion' },
    models: {
      Src: {
        variables: { F: { type: 'state', default: 1.0 } },
        equations: [{ lhs: { op: 'D', args: ['F'], wrt: 't' }, rhs: 0 }],
      },
      Sink: {
        variables: { offset: { type: 'parameter', default: 0.5 } },
        equations: [],
        expression_templates: {
          double_plus: {
            params: ['x', 'off'],
            body: { op: '+', args: [{ op: '*', args: [2.0, 'x'] }, 'off'] },
          },
        },
      },
    },
    coupling: [
      {
        type: 'variable_map',
        from: 'Src.F',
        to: 'Sink.offset',
        transform: {
          op: 'apply_expression_template',
          name: 'double_plus',
          args: [],
          bindings: { x: 'Src.F', off: 'Sink.offset' },
        },
      },
    ],
  })

  const expandedTransform = {
    op: '+',
    args: [{ op: '*', args: [2.0, 'Src.F'] }, 'Sink.offset'],
  }

  it('expands apply_expression_template in a coupling transform at load time', () => {
    const file = load(couplingFixture()) as any
    expect(file.coupling[0].transform).toEqual(expandedTransform)
    expect('expression_templates' in file.models.Sink).toBe(false)
  })

  it('expands the transform in the receiving component scope (lowering pass)', () => {
    // Option B: the target-free reference survives the lowering pass; Expand
    // (the Expand-at-build load strategy, §9.6.4 rule 2) inlines it.
    const lowered = lowerExpressionTemplates(couplingFixture()) as any
    expect(lowered.coupling[0].transform.op).toBe('apply_expression_template')
    const out = expandDocument(lowered) as any
    expect(out.coupling[0].transform).toEqual(expandedTransform)
    // Everything else on the entry is untouched.
    expect(out.coupling[0].from).toBe('Src.F')
    expect(out.coupling[0].to).toBe('Sink.offset')
  })

  it('auto-applies the receiving component match rules to the transform (fixpoint)', () => {
    const src = {
      esm: '0.8.0',
      metadata: { name: 'coupling_match_rule' },
      models: {
        Sink: {
          variables: { p: { type: 'parameter', default: 0.0 } },
          equations: [],
          expression_templates: {
            dbl: {
              params: ['x'],
              match: { op: 'dbl', args: ['x'] },
              body: { op: '*', args: [2.0, 'x'] },
            },
          },
        },
      },
      coupling: [
        {
          type: 'variable_map',
          from: 'Src.F',
          to: 'Sink.p',
          // Nested occurrences require the bounded fixpoint, not one pass.
          transform: { op: 'dbl', args: [{ op: 'dbl', args: ['Src.F'] }] },
        },
      ],
    }
    const out = lowerExpressionTemplates(src) as any
    expect(out.coupling[0].transform).toEqual({
      op: '*',
      args: [2.0, { op: '*', args: [2.0, 'Src.F'] }],
    })
  })

  it('resolves a reaction_systems receiver when no model shares the name', () => {
    const src = {
      esm: '0.8.0',
      metadata: { name: 'coupling_rs_receiver' },
      reaction_systems: {
        Chem: {
          species: { A: { default: 1.0 } },
          parameters: { k: { default: 0.0 } },
          reactions: [],
          expression_templates: {
            triple: {
              params: ['x'],
              body: { op: '*', args: [3.0, 'x'] },
            },
          },
        },
      },
      coupling: [
        {
          type: 'variable_map',
          from: 'Src.F',
          to: 'Chem.k',
          transform: {
            op: 'apply_expression_template',
            name: 'triple',
            args: [],
            bindings: { x: 'Src.F' },
          },
        },
      ],
    }
    const out = expandDocument(lowerExpressionTemplates(src)) as any
    expect(out.coupling[0].transform).toEqual({ op: '*', args: [3.0, 'Src.F'] })
  })

  it('leaves the transform unrewritten when the receiver lacks templates (Expand rejects the dangling ref)', () => {
    const src = couplingFixture() as any
    // Move the template block from the receiver (Sink) to the sender (Src):
    // coupling transforms expand in the RECEIVING component's scope only, so
    // the apply op survives the lowering pass (Option B, §9.6.4 rule 1) and the
    // dangling reference is rejected when Expand resolves it against the (empty)
    // receiver registry.
    src.models.Src.expression_templates = src.models.Sink.expression_templates
    delete src.models.Sink.expression_templates
    const lowered = lowerExpressionTemplates(src) as any
    expect(lowered.coupling[0].transform.op).toBe('apply_expression_template')
    expect(() => expandDocument(lowered)).toThrow(EsmMachineryError)
    expect(() => expandDocument(lowered)).toThrow(/apply_expression_template_unknown_template/)
    expect(() => expandDocument(lowered)).toThrow(/coupling\[0\]\.transform/)
  })

  it('reports the coupling[<idx>].transform scope for an unknown template name', () => {
    const src = couplingFixture() as any
    src.coupling[0].transform.name = 'nope'
    expect(() => lowerExpressionTemplates(src)).toThrow(EsmMachineryError)
    expect(() => lowerExpressionTemplates(src)).toThrow(/coupling\[0\]\.transform/)
  })

  it('keeps named string transforms untouched', () => {
    const src = couplingFixture() as any
    src.coupling[0].transform = 'param_to_var'
    const out = lowerExpressionTemplates(src) as any
    expect(out.coupling[0]).toEqual({
      type: 'variable_map',
      from: 'Src.F',
      to: 'Sink.offset',
      transform: 'param_to_var',
    })
  })
})

// ---------------------------------------------------------------------------
// Scalar-field template-parameter substitution
// (esm-spec §9.6.1 / §9.6.3 constraint 5; mirrors the Julia/Python testsets 1:1)
// ---------------------------------------------------------------------------

describe('scalar-field template-parameter substitution (esm-spec §9.6.1 / §9.6.3 c5)', () => {
  const scalarFieldDoc = (
    templates: Record<string, unknown>,
    bindings: Record<string, unknown>,
    name = 'overlap_area',
  ) => ({
    esm: '0.8.0',
    metadata: { name: 'scalar_field_param_unit', authors: ['t'] },
    models: {
      M: {
        variables: {
          pa: { type: 'parameter' },
          pb: { type: 'parameter' },
          area: {
            type: 'observed',
            expression: {
              op: 'apply_expression_template',
              args: [],
              name,
              bindings,
            },
          },
        },
        equations: [],
        expression_templates: templates,
      },
    },
  })

  it('substitutes a param name in a scalar Expression-node field (happy path)', () => {
    const src = scalarFieldDoc(
      {
        overlap_area: {
          params: ['K_manifold', 'a', 'b'],
          body: {
            op: 'polygon_intersection_area',
            manifold: 'K_manifold',
            args: ['a', 'b'],
          },
        },
      },
      { K_manifold: 'planar', a: 'pa', b: 'pb' },
    )
    // Option B: `polygon_intersection_area` is evaluable-core (not a T-op), so
    // the reference survives lowering; Expand instantiates the scalar-field param.
    const out = expandDocument(lowerExpressionTemplates(src)) as any
    expect(out.models.M.variables.area.expression).toEqual({
      op: 'polygon_intersection_area',
      manifold: 'planar',
      args: ['pa', 'pb'],
    })
  })

  it('threads a scalar-field param through §9.7.3 registration-time body composition', () => {
    const src = scalarFieldDoc(
      {
        inner: {
          params: ['m', 'x', 'y'],
          body: {
            op: 'polygon_intersection_area',
            manifold: 'm',
            args: ['x', 'y'],
          },
        },
        outer: {
          params: ['K', 'p', 'q'],
          body: {
            op: '*',
            args: [
              {
                op: 'apply_expression_template',
                args: [],
                name: 'inner',
                bindings: { m: 'K', x: 'p', y: 'q' },
              },
              2.0,
            ],
          },
        },
      },
      { K: 'spherical', p: 'pa', q: 'pb' },
      'outer',
    )
    // Option B: the `outer`→`inner` DAG is checked (not inlined) at registration
    // and both references survive lowering; Expand inlines the whole chain.
    const out = expandDocument(lowerExpressionTemplates(src)) as any
    expect(out.models.M.variables.area.expression).toEqual({
      op: '*',
      args: [
        {
          op: 'polygon_intersection_area',
          manifold: 'spherical',
          args: ['pa', 'pb'],
        },
        2.0,
      ],
    })
  })

  it('rejects an invalid substituted manifold post-expansion (§9.6.4)', () => {
    const src = scalarFieldDoc(
      {
        overlap_area: {
          params: ['K_manifold', 'a', 'b'],
          body: {
            op: 'polygon_intersection_area',
            manifold: 'K_manifold',
            args: ['a', 'b'],
          },
        },
      },
      { K_manifold: 'bogus', a: 'pa', b: 'pb' },
    )
    expect(() => lowerExpressionTemplates(src)).toThrow(EsmMachineryError)
    expect(() => lowerExpressionTemplates(src)).toThrow(/geometry_manifold_invalid/)
  })

  it('params shadow literals: a param named after a field literal substitutes', () => {
    // Authoring guidance says don't do this (esm-spec §9.6.1) — but when an
    // author does, the pinned resolution is that the param WINS: every string
    // value equal to a declared param name is a substitution site.
    const src = scalarFieldDoc(
      {
        shadowed: {
          params: ['planar', 'x', 'y'],
          body: {
            op: 'polygon_intersection_area',
            manifold: 'planar',
            args: ['x', 'y'],
          },
        },
      },
      { planar: 'spherical', x: 'pa', y: 'pb' },
      'shadowed',
    )
    const out = expandDocument(lowerExpressionTemplates(src)) as any
    expect(out.models.M.variables.area.expression.manifold).toBe('spherical')
  })
})

describe('scalar_field_param conformance fixture', () => {
  // Drives tests/conformance/expression_templates/scalar_field_param — the
  // scalar-field substitution site rule (esm-spec §9.6.1) instantiated twice
  // (planar / spherical) — against its pinned Julia-generated expanded.esm.
  const caseDir = fixturesDir('conformance/expression_templates/scalar_field_param')

  it('matches the canonical expanded form', () => {
    const fixture = JSON.parse(fs.readFileSync(path.join(caseDir, 'fixture.esm'), 'utf8'))
    const expanded = JSON.parse(fs.readFileSync(path.join(caseDir, 'expanded.esm'), 'utf8'))
    // Option B: Expand reproduces the pinned Option-A expanded form (RFC bridge).
    const out = expandDocument(lowerExpressionTemplates(fixture)) as any
    expect(out.models).toEqual(expanded.models)
    const vars = out.models.Overlap.variables
    expect(vars.area_planar.expression.manifold).toBe('planar')
    expect(vars.area_spherical.expression.manifold).toBe('spherical')
  })
})

// ---------------------------------------------------------------------------
// Static match-scoping constraints (`where`, esm-spec §9.6.1 / §9.6.3;
// docs/content/rfcs/match-pattern-scoping-constraints.md). Drives the shared
// cross-binding conformance fixtures + the two non-fixture unit pins (§10.6).
// ---------------------------------------------------------------------------

describe('match-scoping `where` constraints (esm-spec §9.6.1)', () => {
  const confDir = fixturesDir('conformance/expression_templates')
  const fixture = (name: string) =>
    JSON.parse(fs.readFileSync(path.join(confDir, name, 'fixture.esm'), 'utf8'))
  const golden = (name: string) =>
    JSON.parse(fs.readFileSync(path.join(confDir, name, 'expanded.esm'), 'utf8'))
  // Option B: Expand the reference-preserving load to the Option-A image the
  // `expanded.esm` goldens pin (the match-only `where` fixtures carry no
  // surviving references, so Expand only strips the retained registry block).
  const lower = (name: string) => expandDocument(lowerExpressionTemplates(fixture(name))) as any

  it('constrained_match_scope: fires only where the shape constraint holds', () => {
    // div(F_edge) rewritten (F over [edges]); div(F_cell) constraint-excluded,
    // survives as the un-lowered rewrite-target (loading is permissive).
    const out = lower('constrained_match_scope')
    expect(out.models).toEqual(golden('constrained_match_scope').models)
    expect(out.models.m.variables.div_edge.expression).toEqual({
      op: '*',
      args: ['inv_area', 'F_edge'],
    })
    expect(out.models.m.variables.div_cell.expression).toEqual({ op: 'div', args: ['F_cell'] })
  })

  it('two_div_two_meshes: identical patterns routed by shape at equal priority', () => {
    // Without `where`, the declaration-order tie-break would send BOTH div
    // nodes to fv_div_mesh_a. Constraints filter before selection, so each div
    // lowers by its own mesh's rule.
    const out = lower('two_div_two_meshes')
    expect(out.models).toEqual(golden('two_div_two_meshes').models)
    expect(out.models.m.variables.div_a.expression).toEqual({
      op: '*',
      args: ['inv_area_a', 'F_a'],
    })
    expect(out.models.m.variables.div_b.expression).toEqual({
      op: '*',
      args: ['inv_area_b', 'F_b'],
    })
  })

  it('per_variable_scheme_literal_args: ground-pattern per-variable selector', () => {
    // Sanctioned per-variable mechanism (no `where`): a non-parameter string in
    // an args position is a literal. upwind1_D_u (priority 10) fires only on
    // D(u, x); central_D_any captures every other D(·, x).
    const out = lower('per_variable_scheme_literal_args')
    expect(out.models).toEqual(golden('per_variable_scheme_literal_args').models)
    expect(out.models.m.variables.du.expression).toEqual({ op: '*', args: ['upwind_coef', 'u'] })
    expect(out.models.m.variables.dv.expression).toEqual({ op: '*', args: ['central_coef', 'v'] })
  })

  it('constraint_unknown_index_set: unknown shape name rejected at registration', () => {
    const err = JSON.parse(
      fs.readFileSync(path.join(confDir, 'constraint_unknown_index_set', 'error.json'), 'utf8'),
    )
    let caught: unknown
    try {
      lowerExpressionTemplates(fixture('constraint_unknown_index_set'))
    } catch (e) {
      caught = e
    }
    expect(caught).toBeInstanceOf(EsmMachineryError)
    expect((caught as EsmMachineryError).code).toBe(err.code)
    expect((caught as EsmMachineryError).code).toBe('template_constraint_unknown_index_set')
  })

  // --- non-fixture unit pins (match-pattern-scoping-constraints RFC §10.6) ---

  it('constraints filter BEFORE priority (excluded high-priority rule never shadows)', () => {
    // A high-priority (100) shape-constrained rule is excluded at div(F_cell)
    // because F_cell is not over [edges]; a low-priority (0) generic rule must
    // still fire there. Pins that `where` is part of eligibility, not selection.
    const src = {
      esm: '0.8.0',
      metadata: { name: 'filter_before_priority', authors: ['t'] },
      index_sets: { cells: { kind: 'interval', size: 3 }, edges: { kind: 'interval', size: 5 } },
      models: {
        m: {
          variables: {
            F_cell: { type: 'state', units: '1', shape: ['cells'] },
            d: {
              type: 'observed',
              units: '1',
              shape: ['cells'],
              expression: { op: 'div', args: ['F_cell'] },
            },
          },
          equations: [],
          expression_templates: {
            hi_edges_only: {
              params: ['F'],
              priority: 100,
              match: { op: 'div', args: ['F'] },
              where: { F: { shape: ['edges'] } },
              body: { op: 'edge_div', args: ['F'] },
            },
            lo_generic: {
              params: ['F'],
              priority: 0,
              match: { op: 'div', args: ['F'] },
              body: { op: 'generic_div', args: ['F'] },
            },
          },
        },
      },
    }
    const out = lowerExpressionTemplates(JSON.parse(JSON.stringify(src))) as any
    expect(out.models.m.variables.d.expression).toEqual({ op: 'generic_div', args: ['F_cell'] })
  })

  it('compound argument fails the constraint conservatively (no error, no rewrite)', () => {
    // A `where` constraint holds only for a BARE variable-reference binding; a
    // compound sub-AST fails conservatively — the node is left un-lowered, and
    // loading stays permissive (no error).
    const src = {
      esm: '0.8.0',
      metadata: { name: 'compound_arg_conservative', authors: ['t'] },
      index_sets: { edges: { kind: 'interval', size: 5 } },
      models: {
        m: {
          variables: {
            F: { type: 'state', units: '1', shape: ['edges'] },
            d: {
              type: 'observed',
              units: '1',
              shape: ['edges'],
              expression: { op: 'div', args: [{ op: '*', args: [2, 'F'] }] },
            },
          },
          equations: [],
          expression_templates: {
            fv: {
              params: ['F'],
              match: { op: 'div', args: ['F'] },
              where: { F: { shape: ['edges'] } },
              body: { op: '*', args: ['inv_area', 'F'] },
            },
          },
        },
      },
    }
    const out = lowerExpressionTemplates(JSON.parse(JSON.stringify(src))) as any
    // The div of a compound flux is NOT rewritten (bare-var-only judgment).
    expect(out.models.m.variables.d.expression).toEqual({
      op: 'div',
      args: [{ op: '*', args: [2, 'F'] }],
    })
  })

  it('`where` without `match` is a malformed declaration', () => {
    const src = {
      esm: '0.8.0',
      metadata: { name: 'where_without_match', authors: ['t'] },
      index_sets: { edges: { kind: 'interval', size: 5 } },
      models: {
        m: {
          variables: {},
          equations: [],
          expression_templates: {
            bad: { params: ['F'], where: { F: { shape: ['edges'] } }, body: 'F' },
          },
        },
      },
    }
    let caught: unknown
    try {
      lowerExpressionTemplates(JSON.parse(JSON.stringify(src)))
    } catch (e) {
      caught = e
    }
    expect((caught as EsmMachineryError).code).toBe('apply_expression_template_invalid_declaration')
  })
})

// ---------------------------------------------------------------------------
// Pin 1: makearray empty vs inverted region bounds (esm-spec §4.3.2 / §9.6.4).
// docs/content/rfcs matches _validate_makearray_regions in the Julia reference.
// ---------------------------------------------------------------------------

describe('makearray region bounds validation (esm-spec §4.3.2, Pin 1)', () => {
  const validDir = fixturesDir('valid')

  it('empty bound [start, start-1] loads clean at the minimum extent', () => {
    // tests/valid/makearray_empty_region_min_extent.esm folds the interior
    // region [2, N-1] to [2, 1] at the default N = 2 — the canonical empty
    // bound, which contributes no elements and MUST load.
    const text = fs.readFileSync(
      path.join(validDir, 'makearray_empty_region_min_extent.esm'),
      'utf8',
    )
    const f = load(text, { basePath: validDir }) as any
    const regions = f.models.Advection.equations[0].rhs.regions
    expect(regions[0][0]).toEqual([2, 1])
  })

  it('inverted bound [2, 0] at N = 1 (loader API) is rejected', () => {
    // Re-binding N = 1 folds the interior region to [2, 0] — inverted
    // (stop < start - 1) — which MUST fail with makearray_region_inverted.
    const text = fs.readFileSync(
      path.join(validDir, 'makearray_empty_region_min_extent.esm'),
      'utf8',
    )
    let caught: unknown
    try {
      load(text, { basePath: validDir, metaparameters: { N: 1 } })
    } catch (e) {
      caught = e
    }
    expect(caught).toBeInstanceOf(EsmMachineryError)
    expect((caught as EsmMachineryError).code).toBe('makearray_region_inverted')
  })
})

// ---------------------------------------------------------------------------
// Regression guards for the Wave-2β clarity/consistency fixes.
// ---------------------------------------------------------------------------

describe('rulePriority — non-finite priority does not poison rule selection', () => {
  it('a NaN-priority rule sorts as priority 0, so a real higher-priority rule still wins', () => {
    // Two `match` rules fire on the same `foo` node. `ruleNaN` is declared
    // FIRST (declIndex 0) with a non-finite priority; `rule5` is declared
    // second with priority 5. Before the guard fix, `NaN` made the sort
    // comparator fall back to declaration order, so `ruleNaN` (declIndex 0)
    // shadowed `rule5`. With the fix (`NaN` -> 0) the priority-5 rule wins.
    const file = {
      esm: '0.8.0',
      metadata: { name: 'nan_priority' },
      models: {
        m: {
          variables: { x: { type: 'variable', units: '1' } },
          expression_templates: {
            ruleNaN: {
              params: ['a'],
              match: { op: 'foo', args: ['a'] },
              body: { op: 'from_nan', args: ['a'] },
              priority: Number.NaN,
            },
            rule5: {
              params: ['a'],
              match: { op: 'foo', args: ['a'] },
              body: { op: 'from_five', args: ['a'] },
              priority: 5,
            },
          },
          equations: [{ lhs: 'x', rhs: { op: 'foo', args: ['z'] } }],
        },
      },
    }
    const out = lowerExpressionTemplates(file) as any
    expect(out.models.m.equations[0].rhs).toEqual({ op: 'from_five', args: ['z'] })
  })
})

describe('EsmMachineryError — extends EsmDiagnosticError, byte-compatible', () => {
  it('keeps its name, code, and [code] message while gaining the EsmDiagnosticError base', () => {
    const err = new EsmMachineryError('some_code', 'boom')
    expect(err).toBeInstanceOf(EsmMachineryError)
    expect(err).toBeInstanceOf(EsmDiagnosticError)
    expect(err).toBeInstanceOf(Error)
    expect(err.name).toBe('EsmMachineryError')
    expect(err.code).toBe('some_code')
    expect(err.message).toBe('[some_code] boom')
  })

  it('exposes the deprecated ExpressionTemplateError alias as the SAME class', () => {
    // Backward compatibility: the alias is the same class object, so instanceof
    // classifies identically in either direction for external consumers.
    expect(ExpressionTemplateError).toBe(EsmMachineryError)
    const err = new EsmMachineryError('some_code', 'boom')
    expect(err).toBeInstanceOf(ExpressionTemplateError)
    expect(new ExpressionTemplateError('c', 'm')).toBeInstanceOf(EsmMachineryError)
  })
})

/**
 * esm-spec §9.6.4 rule 5 — Option A expands CALL SITES; it does NOT delete
 * DECLARATIONS. A template-library file MUST round-trip to itself.
 */
describe('§9.6.4 rule 5: a template library round-trips to itself', () => {
  const libraries = [
    'tests/valid/template_import_lib.esm',
    'tests/valid/template_import_rename_lib.esm',
  ]

  it.each(libraries)('%s preserves its top-level declarations through parse -> emit', (rel) => {
    const file = path.join(REPO_ROOT, rel)
    const dir = path.dirname(file)
    const onDisk = JSON.parse(fs.readFileSync(file, 'utf-8')) as Record<string, unknown>
    const emitted = JSON.parse(
      save(load(fs.readFileSync(file, 'utf-8'), { basePath: dir })),
    ) as Record<string, unknown>

    // The two DECLARATION blocks survive VERBATIM — not folded, not stripped.
    // Dropping them emitted `{esm, metadata, index_sets}`: a document with NONE of
    // the five top-level payload keys, which the schema's top-level `anyOf` rejects.
    expect(emitted.expression_templates).toEqual(onDisk.expression_templates)
    expect(emitted.metaparameters).toEqual(onDisk.metaparameters)

    // ...and the emitted form is itself a legal, loadable document — the property
    // that was actually broken. "Legal on disk, illegal once loaded and re-emitted"
    // means the document kind does not exist.
    expect(validate(JSON.stringify(emitted), { basePath: dir }).is_valid).toBe(true)
  })

  it.each(libraries)('%s is a fixed point of load -> save -> load', (rel) => {
    const file = path.join(REPO_ROOT, rel)
    const dir = path.dirname(file)
    const once = load(fs.readFileSync(file, 'utf-8'), { basePath: dir })
    const twice = load(save(once), { basePath: dir })
    expect(twice).toEqual(once)
  })

  it('still rejects a genuinely unexpanded apply at a CALL SITE', () => {
    // Skipping `expression_templates` blocks in the stray-apply scan must not
    // blind it to a real unexpanded call: an `apply_expression_template` naming a
    // template that does not exist, in an EQUATION (a call site, not a body).
    expect(() =>
      load({
        esm: '0.1.0',
        metadata: { name: 'stray' },
        models: {
          M: {
            variables: { u: { type: 'state', units: '1' } },
            expression_templates: { known: { params: ['x'], body: { op: '*', args: ['x', 2] } } },
            equations: [
              {
                lhs: { op: 'D', args: ['u'], wrt: 't' },
                rhs: { op: 'apply_expression_template', template: 'does_not_exist', args: ['u'] },
              },
            ],
          },
        },
      }),
    ).toThrow()
  })
})
