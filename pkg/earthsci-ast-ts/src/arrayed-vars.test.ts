import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { load, save } from './index.js'
import type { EsmFile, Model, ModelVariable } from './types.js'

const FIXTURE_DIR = resolve(__dirname, '..', '..', '..', 'tests', 'fixtures', 'arrayed_vars')

function loadFixture(name: string): EsmFile {
  const raw = readFileSync(resolve(FIXTURE_DIR, name), 'utf8')
  return load(raw)
}

function roundtrip(name: string): { first: EsmFile; second: EsmFile } {
  const first = loadFixture(name)
  const serialized = save(first)
  const second = load(serialized)
  return { first, second }
}

function getVar(esm: EsmFile, modelName: string, varName: string): ModelVariable {
  const models = esm.models as { [k: string]: Model }
  const model = models[modelName]
  if (!model) throw new Error(`model ${modelName} missing`)
  const v = model.variables[varName]
  if (!v) throw new Error(`variable ${varName} missing in ${modelName}`)
  return v
}

describe('Arrayed variable shape/location (RFC §10.2)', () => {
  it('scalar_no_shape regression: unset fields stay undefined', () => {
    const { first, second } = roundtrip('scalar_no_shape.esm')
    for (const esm of [first, second]) {
      const v = getVar(esm, 'Scalar0D', 'x')
      expect(v.shape).toBeUndefined()
      expect(v.location).toBeUndefined()
    }
  })

  it('scalar_explicit: empty-list shape parses as zero dimensions', () => {
    const { first, second } = roundtrip('scalar_explicit.esm')
    for (const esm of [first, second]) {
      const v = getVar(esm, 'ScalarExplicit', 'mass')
      const dims = v.shape === undefined ? 0 : v.shape.length
      expect(dims).toBe(0)
      expect(v.location).toBeUndefined()
    }
  })

  it('one_d: 1-D cell-centered variable', () => {
    const { first, second } = roundtrip('one_d.esm')
    for (const esm of [first, second]) {
      const c = getVar(esm, 'Diffusion1D', 'c')
      expect(c.shape).toEqual(['x'])
      expect(c.location).toBe('cell_center')
      const d = getVar(esm, 'Diffusion1D', 'D')
      expect(d.shape).toBeUndefined()
      expect(d.location).toBeUndefined()
    }
  })

  it('two_d_faces: staggered locations preserved', () => {
    const { first, second } = roundtrip('two_d_faces.esm')
    for (const esm of [first, second]) {
      const p = getVar(esm, 'StaggeredFlow2D', 'p')
      const u = getVar(esm, 'StaggeredFlow2D', 'u')
      expect(p.shape).toEqual(['x', 'y'])
      expect(p.location).toBe('cell_center')
      expect(u.shape).toEqual(['x', 'y'])
      expect(u.location).toBe('x_face')
    }
  })

  it('vertex_located: 2-D vertex variable round-trips', () => {
    const { first, second } = roundtrip('vertex_located.esm')
    for (const esm of [first, second]) {
      const phi = getVar(esm, 'VertexScalar2D', 'phi')
      expect(phi.shape).toEqual(['x', 'y'])
      expect(phi.location).toBe('vertex')
    }
  })
})
