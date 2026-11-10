/**
 * The esm 2.0.0 removals are refused at the wire boundary with `removed_op`.
 *
 * `fn`, `table_lookup`, `skolem`, `rank`, `intersect_polygon`,
 * `polygon_intersection_area`, `argmin` and `argmax` are well-formed op names,
 * so without a by-name rejection each would load as an OPEN rewrite-target op
 * (esm-spec §4.2) and fail only much later as `unlowered_operator`. The
 * `function_tables` block is refused the same way, at the root and on any
 * component. Every message names the construct, where it sits, and the codemod.
 */
import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'

import { ParseError, SCHEMA_VERSION, loadDocument, loadPath } from './parse.js'
import { fixturesDir } from './test-helpers.js'
import { validateText } from './validate.js'

/** A current-version document whose one equation's right-hand side is `rhs`. */
function docWithRhs(rhs: unknown, model: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    esm: SCHEMA_VERSION,
    metadata: { name: 'removed_ops', authors: ['t'] },
    models: {
      M: {
        variables: {
          x: { type: 'unknown', units: '1' },
          p: { type: 'parameter', units: '1', default: 1.0 },
        },
        equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs }],
        ...model,
      },
    },
  }
}

/** Load `doc` and return the error it throws (or fail when it loads). */
function loadError(doc: unknown): ParseError {
  try {
    loadDocument(doc as object)
  } catch (e) {
    expect(e).toBeInstanceOf(ParseError)
    return e as ParseError
  }
  throw new Error('document loaded but should have been refused')
}

const REMOVED_NODES: [string, Record<string, unknown>][] = [
  ['fn', { op: 'fn', name: 'datetime.year', args: ['t'] }],
  ['table_lookup', { op: 'table_lookup', args: [], table: 'T', axes: { a: 'p' } }],
  ['skolem', { op: 'skolem', args: ['p'], label: 'edge' }],
  ['rank', { op: 'rank', args: ['p'] }],
  ['intersect_polygon', { op: 'intersect_polygon', args: ['p', 'p'], manifold: 'planar' }],
  [
    'polygon_intersection_area',
    { op: 'polygon_intersection_area', args: ['p', 'p'], manifold: 'spherical' },
  ],
  ['argmin', { op: 'argmin', args: ['p'], arg: 'i', expr: 'p', ranges: { i: [1, 3] } }],
  ['argmax', { op: 'argmax', args: ['p'], arg: 'i', expr: 'p', ranges: { i: [1, 3] } }],
]

describe('removed_op: ops removed at esm 2.0.0', () => {
  for (const [op, node] of REMOVED_NODES) {
    it(`refuses \`${op}\` by name, naming the node path and the codemod`, () => {
      const err = loadError(docWithRhs({ op: '*', args: ['p', node] }))
      expect(err.code).toBe('removed_op')
      expect(err.message).toContain(`removed_op at /models/M/equations/0/rhs/args/1:`)
      expect(err.message).toContain(`"op": "${op}"`)
      expect(err.message).toContain('removed at esm 2.0.0')
      expect(err.message).toContain('earthsci-ast migrate')
      expect(err.message).toContain('earthsci_ast.migration')
    })
  }

  it('refuses a removed op whatever version the document declares', () => {
    // Before the version check, so a 1.x document is told about the construct
    // and the codemod rather than only about its major version.
    const doc = { ...docWithRhs(REMOVED_NODES[0][1]), esm: '1.3.0' }
    expect(loadError(doc).code).toBe('removed_op')
  })

  it('refuses a removed op inside an expression-template body', () => {
    const doc = docWithRhs(
      { op: 'apply_expression_template', args: [], name: 'yr', bindings: { a: 'p' } },
      {
        expression_templates: {
          yr: { params: ['a'], body: { op: 'fn', name: 'datetime.year', args: ['a'] } },
        },
      },
    )
    const err = loadError(doc)
    expect(err.code).toBe('removed_op')
    expect(err.message).toContain('/models/M/expression_templates/yr/body')
  })

  it('reports removed_op through validate()', () => {
    const result = validateText(JSON.stringify(docWithRhs(REMOVED_NODES[1][1])))
    expect(result.is_valid).toBe(false)
    const codes = [...result.schema_errors, ...result.structural_errors].map((e) => e.code)
    expect(codes).toContain('removed_op')
  })

  it('keeps the esm:std templates of the same names', () => {
    // `argmin` / `argmax` survive as template NAMES; only the op form went.
    const doc = docWithRhs(
      { op: 'apply_expression_template', args: [], name: 'argmin', bindings: { f: 'p', n: 3 } },
      {
        expression_template_imports: [{ ref: 'esm:std/relational.esm', only: ['argmin'] }],
      },
    )
    expect(() => loadDocument(doc)).not.toThrow(/removed_op/)
  })
})

describe('removed_op: the function_tables block', () => {
  const block = { T: { axes: [{ name: 'a', values: [0, 1] }], data: [0, 1] } }

  it('refuses a top-level block', () => {
    const err = loadError({ ...docWithRhs('p'), function_tables: block })
    expect(err.code).toBe('removed_op')
    expect(err.message).toContain('removed_op at /function_tables:')
    expect(err.message).toContain('`function_tables` block was removed at esm 2.0.0')
    expect(err.message).toContain('earthsci-ast migrate')
  })

  it('refuses a component-level block', () => {
    const err = loadError(docWithRhs('p', { function_tables: block }))
    expect(err.code).toBe('removed_op')
    expect(err.message).toContain('removed_op at /models/M/function_tables:')
  })

  it('refuses a block on a reaction system and on a nested subsystem', () => {
    const rs = {
      esm: SCHEMA_VERSION,
      metadata: { name: 'rs', authors: ['t'] },
      reaction_systems: {
        R: { species: {}, parameters: {}, reactions: [], function_tables: block },
      },
    }
    expect(loadError(rs).message).toContain('removed_op at /reaction_systems/R/function_tables:')

    const nested = docWithRhs('p', {
      subsystems: { S: { variables: {}, equations: [], function_tables: block } },
    })
    expect(loadError(nested).message).toContain(
      'removed_op at /models/M/subsystems/S/function_tables:',
    )
  })

  it('does not mistake a variable named function_tables for the block', () => {
    const doc = docWithRhs('p')
    const vars = (doc.models as Record<string, Record<string, Record<string, unknown>>>).M.variables
    vars.function_tables = { type: 'parameter', units: '1', default: 2.0 }
    expect(() => loadDocument(doc)).not.toThrow(/removed_op/)
  })
})

describe('removed_op: shared fixtures', () => {
  // tests/invalid/removed_ops/ holds one fixture per removed op or field.
  const dir = fixturesDir('invalid', 'removed_ops')
  const files = fs.existsSync(dir)
    ? fs
        .readdirSync(dir)
        .filter((f) => f.endsWith('.esm'))
        .sort()
    : []
  for (const file of files) {
    it(`${file} is refused with removed_op`, () => {
      let err: unknown
      try {
        loadPath(path.join(dir, file))
      } catch (e) {
        err = e
      }
      expect(err).toBeInstanceOf(ParseError)
      expect((err as ParseError).code).toBe('removed_op')
    })
  }
  it.skipIf(files.length > 0)('has no shared removed_op fixtures in this tree yet', () => {})
})
