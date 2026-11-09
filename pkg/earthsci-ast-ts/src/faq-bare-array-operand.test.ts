/**
 * `faq_bare_array_operand` (esm-spec §4.3.1): a template application is
 * opaque, a derivative left-hand side exempts nothing, and the check reaches
 * inline subsystems.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { join } from 'path'
import { validateText, ERROR_CODES } from './index.js'
import { fixturesDir } from './test-helpers.js'

const faqDir = join(fixturesDir(), 'invalid', 'faq')

function faqBareDoc(expr: unknown): string {
  return JSON.stringify({
    esm: '1.2.0',
    metadata: { name: 't', authors: ['t'] },
    index_sets: { a_rows: { kind: 'interval', size: 2 } },
    models: {
      Probe: {
        variables: {
          v: { type: 'parameter', units: '1', shape: ['a_rows'], default: [1.0, 2.0] },
          w: { type: 'parameter', units: '1', shape: ['a_rows'], default: [10.0, 20.0] },
          out: { type: 'unknown', units: '1', shape: ['a_rows'] },
        },
        expression_templates: { twice: { params: ['x'], body: { op: '*', args: [2.0, 'x'] } } },
        equations: [
          {
            lhs: 'out',
            rhs: {
              op: 'faq',
              args: [],
              semiring: 'sum_product',
              output_idx: ['i'],
              ranges: { i: { from: 'a_rows' } },
              expr,
            },
          },
        ],
      },
    },
  })
}

const findings = (text: string) =>
  validateText(text).structural_errors.filter((e) => e.code === ERROR_CODES.FAQ_BARE_ARRAY_OPERAND)

const apply = {
  op: 'apply_expression_template',
  args: [],
  name: 'twice',
  bindings: { x: 'v' },
}

describe('faq_bare_array_operand', () => {
  it('treats a template application as opaque', () => {
    expect(
      findings(faqBareDoc({ op: '+', args: [apply, { op: 'index', args: ['w', 'i'] }] })),
    ).toEqual([])
  })

  it('still reports a bare read beside a template application, and only that one', () => {
    const got = findings(faqBareDoc({ op: '+', args: [apply, 'w'] }))
    expect(got.map((e) => (e.details as { variable: string }).variable)).toEqual(['w'])
  })

  it.each([
    ['bare_array_operand_derivative.esm', '/models/Probe/equations/0/rhs'],
    ['bare_array_operand_subsystem.esm', '/models/Host/subsystems/Probe/equations/2/rhs'],
    ['bare_array_operand_beside_template.esm', '/models/Probe/equations/0/rhs'],
  ])('reports %s at %s', (name, path) => {
    const got = findings(readFileSync(join(faqDir, name), 'utf-8'))
    expect(got.map((e) => e.path)).toEqual([path])
  })
})
