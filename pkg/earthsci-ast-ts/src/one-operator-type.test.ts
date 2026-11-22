/**
 * esm 2.4.0 "one operator type" (esm-spec §4.2, §4.8.3, §9.6.1–9.6.3, §9.6.6,
 * §9.6.12; CONFORMANCE_SPEC §5.61): calls of defined operators resolve to
 * definitions and become references, old spellings are read at the wire
 * boundary, core names are reserved, arity is checked at load, unit
 * expressions type a call. Drives the fixtures under
 * tests/conformance/expression_templates/. Mirrors the Julia reference
 * `one_operator_type_test.jl`.
 */
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  emitEsmString,
  expandDocument,
  lowerExpressionTemplates,
} from './lower-expression-templates.js'
import { emitDocument, resolveTemplateMachinery } from './template-imports.js'
import { loadPath, rewriteOldSpellings } from './parse.js'
import { canonicalizeDocument } from './canonicalize.js'
import { validateText } from './validate.js'
import { canonicalErrorCode } from './errors.js'
import { evaluateExpression, UnloweredOperatorError } from './codegen.js'
import { fixturesDir } from './test-helpers.js'

const conf = (...parts: string[]) => fixturesDir('conformance', 'expression_templates', ...parts)

function normj(v: unknown): unknown {
  return JSON.parse(JSON.stringify(v))
}

function emitPath(fp: string): string {
  const raw = JSON.parse(fs.readFileSync(fp, 'utf-8'))
  return emitEsmString(emitDocument(raw, path.dirname(fp)))
}

function loadRefPreserving(fp: string): Record<string, unknown> {
  const raw = JSON.parse(fs.readFileSync(fp, 'utf-8'))
  const resolved = resolveTemplateMachinery(raw, path.dirname(fp))
  return lowerExpressionTemplates((resolved ?? raw) as object) as Record<string, unknown>
}

function core(d: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const k of ['models', 'reaction_systems', 'coupling', 'index_sets']) {
    if (k in d) out[k] = normj(d[k])
  }
  return out
}

function errorOf(f: () => unknown): { code?: string; message: string } | undefined {
  try {
    f()
  } catch (e) {
    return e as { code?: string; message: string }
  }
  return undefined
}

describe('one operator type (esm 2.4.0, esm-spec §9.6.12)', () => {
  let warn: ReturnType<typeof vi.spyOn>
  beforeEach(() => {
    warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
  })
  afterEach(() => {
    warn.mockRestore()
  })

  describe('emitted goldens, byte for byte, and emit ∘ load is a fixed point', () => {
    it.each([
      ['operator_call_by_name', 'fixture.esm', 'emitted.esm'],
      ['placeholder_call', 'fixture.esm', 'emitted.esm'],
      ['partial_wrt_param_instance', 'fixture.esm', 'emitted.esm'],
      ['old_names', 'fixture.esm', 'emitted.esm'],
      ['reference_only_round_trip', 'fixture.esm', 'emitted.esm'],
      ['independent_variable_wrt', 'fixture.esm', 'emitted.esm'],
      ['vector_calculus_import', 'fixture.esm', 'emitted.esm'],
    ])('%s / %s', (dir, fix, gold) => {
      const out = emitPath(conf(dir, fix))
      expect(out).toBe(fs.readFileSync(conf(dir, gold), 'utf-8'))
      const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'oot-'))
      try {
        const p = path.join(tmp, 'e.esm')
        fs.writeFileSync(p, out)
        expect(emitPath(p)).toBe(out)
      } finally {
        fs.rmSync(tmp, { recursive: true, force: true })
      }
    })
  })

  it('old spellings emit exactly as the new ones (metadata aside)', () => {
    const strip = (t: string): unknown => {
      const d = JSON.parse(t) as Record<string, unknown>
      delete d.metadata
      return d
    }
    expect(strip(emitPath(conf('old_names', 'fixture.esm')))).toEqual(
      strip(emitPath(conf('old_names', 'new_names.esm'))),
    )
  })

  describe('expanded goldens, structurally', () => {
    it.each(['operator_call_by_name', 'partial_wrt_param_instance'])('%s', (dir) => {
      const got = core(expandDocument(loadRefPreserving(conf(dir, 'fixture.esm'))))
      const want = core(JSON.parse(fs.readFileSync(conf(dir, 'expanded.esm'), 'utf-8')))
      expect(got).toEqual(want)
    })
  })

  describe('load errors by code', () => {
    it.each([
      ['operator_arity_mismatch', 'fixture.esm', 'error.json'],
      ['operator_defines_core_op', 'fixture.esm', 'error.json'],
      ['operator_defines_core_op', 'explicit_defines.esm', 'error_explicit_defines.json'],
    ])('%s / %s', (dir, fix, errf) => {
      const want = JSON.parse(fs.readFileSync(conf(dir, errf), 'utf-8')) as { code: string }
      const err = errorOf(() => loadPath(conf(dir, fix)))
      expect(err?.code).toBe(want.code)
    })

    it('a compound rule keyed by a core name is exempt from the reservation', () => {
      expect(() =>
        loadPath(conf('operator_defines_core_op', 'compound_rule_exempt.esm')),
      ).not.toThrow()
    })
  })

  it('old spellings warn; new spellings do not', () => {
    const want = JSON.parse(fs.readFileSync(conf('old_names', 'warnings.json'), 'utf-8')) as {
      warnings: string[]
    }
    loadPath(conf('old_names', 'fixture.esm'))
    const msgs = warn.mock.calls.map((c: unknown[]) => String(c[0]))
    for (const code of want.warnings) {
      expect(msgs.some((m: string) => m.startsWith(`${code}:`))).toBe(true)
    }
    warn.mockClear()
    loadPath(conf('old_names', 'new_names.esm'))
    const again = warn.mock.calls.map((c: unknown[]) => String(c[0]))
    expect(again.filter((m: string) => /^deprecated_(field|op):/.test(m))).toEqual([])
  })

  it('a placeholder loads and is refused only if evaluated', () => {
    const want = JSON.parse(fs.readFileSync(conf('placeholder_call', 'error.json'), 'utf-8')) as {
      code: string
    }
    const f = loadPath(conf('placeholder_call', 'fixture.esm')) as any
    const eqs = f.models.m.equations as { lhs: unknown; rhs: unknown }[]
    const rhs = eqs.find((e) => e.lhs === 'T')!.rhs
    const err = errorOf(() =>
      evaluateExpression(rhs as any, new Map(), {
        registry: f.componentTemplates?.['models.m'],
      }),
    )
    expect(err).toBeInstanceOf(UnloweredOperatorError)
    expect(err?.code).toBe(want.code)
    expect(err?.message).toContain('placeholder')
  })

  it('an unresolved call names the definitions in scope and why each was not eligible', () => {
    const registry = {
      grad_x: { params: ['f'], defines: 'grad', body: 'f' },
      grad_pair: { params: ['f', 'g'], defines: 'grad', body: 'f' },
    }
    const err = errorOf(() =>
      evaluateExpression({ op: 'grad', args: ['u'], dim: 'x' } as any, new Map([['u', 1]]), {
        registry,
      }),
    )
    expect(err?.code).toBe('unlowered_operator')
    expect(err?.message).toContain("definitions of 'grad' in scope")
    expect(err?.message).toContain("'grad_pair': takes 2 operand(s), the call carries 1")
    expect(err?.message).toContain(
      "'grad_x': has no match, so it binds operands only, and the call carries dim",
    )
  })

  it('unit expressions (esm-spec §9.6.12 "Units")', () => {
    const expected = JSON.parse(
      fs.readFileSync(conf('definition_units', 'expected.json'), 'utf-8'),
    ) as Record<string, { errors: string[]; warnings: string[] }>
    for (const f of ['fixture.esm', 'body_mismatch.esm', 'call_unit_from_expression.esm']) {
      const fp = conf('definition_units', f)
      const r = validateText(fs.readFileSync(fp, 'utf-8'), { basePath: path.dirname(fp) })
      const want = expected[f]!
      const errs = [...new Set(r.structural_errors.map((e) => e.code))].sort()
      expect(errs, f).toEqual([...want.errors].sort())
      const ws = [
        ...new Set(
          r.unit_warnings
            .filter((w) => w.code === 'definition_unit_mismatch')
            .map((w) => w.code as string),
        ),
      ].sort()
      expect(ws, f).toEqual([...want.warnings].sort())
    }
  })

  it('emitted rules are reference-only (esm-spec §9.6.1, §9.6.4 rule 5)', () => {
    const out = fs.readFileSync(conf('reference_only_round_trip', 'emitted.esm'), 'utf-8')
    const reg = JSON.parse(out).models.m.operators
    expect(reg.fv_div_edges.reference_only).toBe(true)
    expect(reg.exp.reference_only).toBe(true)
    expect('where' in reg.fv_div_edges).toBe(false)
    // div(G) stayed a call; reloading does not turn it into a reference.
    expect(out).toContain('"op": "div"')
    // emit → load → emit is exact (also for constrained_match_scope).
    for (const dir of ['reference_only_round_trip', 'constrained_match_scope']) {
      const once = emitPath(conf(dir, 'fixture.esm'))
      const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'oot-'))
      try {
        const p = path.join(tmp, 'e.esm')
        fs.writeFileSync(p, once)
        const twice = emitPath(p)
        expect(twice, dir).toBe(once)
        fs.writeFileSync(p, twice)
        expect(emitPath(p), dir).toBe(once)
      } finally {
        fs.rmSync(tmp, { recursive: true, force: true })
      }
    }
  })

  it('a reference-only definition is no call rule and the gate says so', () => {
    const registry = {
      grad_x: { params: ['f'], defines: 'grad', body: 'f', reference_only: true },
    }
    const err = errorOf(() =>
      evaluateExpression({ op: 'grad', args: ['u'] } as any, new Map([['u', 1]]), { registry }),
    )
    expect(err?.message).toContain(
      "'grad_x': reference-only, reached by explicit references, never by a call",
    )
    expect(err?.message).toContain(
      'definitions no reference reached were removed by emit and flatten and are not listed',
    )
  })

  it('a D along the renamed independent variable is the time derivative', () => {
    const doc = {
      domain: { independent_variable: 'tau' },
      models: {
        m: {
          equations: [
            { lhs: { op: 'D', args: ['u'], wrt: 'tau' }, rhs: { op: 'D', args: ['u'], wrt: 'x' } },
          ],
        },
      },
    }
    const sites = rewriteOldSpellings(doc)
    const eq = doc.models.m.equations[0]!
    expect(eq.lhs).toEqual({ op: 'D', args: ['u'], wrt: 't' })
    expect(eq.rhs.op).toBe('partial')
    expect(sites.ops).toEqual(['/models/m/equations/0/rhs (D)'])
    expect(
      canonicalizeDocument({
        ...doc,
        models: { m: { equations: [{ lhs: 'y', rhs: { op: 'D', args: ['u'], wrt: 'tau' } }] } },
      }).models.m.equations[0].rhs.wrt,
    ).toBe('t')
  })

  it('old codes are aliases of the new ones (esm-spec §9.6.6)', () => {
    expect(canonicalErrorCode('template_import_cycle')).toBe('operator_import_cycle')
    expect(canonicalErrorCode('apply_expression_template_unknown_template')).toBe(
      'operator_unknown_definition',
    )
    expect(canonicalErrorCode('operator_import_cycle')).toBe('operator_import_cycle')
  })
})
