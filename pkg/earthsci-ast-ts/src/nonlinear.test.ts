/**
 * Nonlinear-system round-trip tests — Model.initialization_equations,
 * guesses, and system_kind (gt-ebuq).
 */
import { describe, it, expect } from 'vitest'
import { loadString } from './parse.js'
import { toJson } from './serialize.js'
import { readFixture } from './test-helpers.js'
import type { Model } from './types.js'

function loadFixture(name: string) {
  const text = readFixture('valid', name)
  return { text, parsed: loadString(text) }
}

describe('Nonlinear-system additions (gt-ebuq)', () => {
  it('round-trips the ISORROPIA-shape fixture: init eqs read as guesses, system_kind kept', () => {
    const { parsed } = loadFixture('nonlinear_isorropia_shape.esm')
    const model = parsed.models!.IsorropiaEq as Model
    expect(model.system_kind).toBe('nonlinear')
    // esm 2.5.0 (esm-spec §11.4.4): a model with no time derivative reads its
    // deprecated initialization equations as `guesses`; both unknowns already
    // have one, which is kept.
    expect(model.initialization_equations).toBeUndefined()
    expect(Object.keys(model.guesses!).sort()).toEqual(['H', 'SO4'])

    const first = toJson(parsed)
    const second = toJson(loadString(first))
    expect(JSON.parse(first)).toEqual(JSON.parse(second))
  })

  it('round-trips the Mogi-shape algebraic fixture', () => {
    const { parsed } = loadFixture('nonlinear_mogi_shape.esm')
    const model = parsed.models!.MogiModel as Model
    expect(model.system_kind).toBe('nonlinear')
    expect(model.initialization_equations).toBeUndefined()
    expect(model.guesses).toBeUndefined()

    const first = toJson(parsed)
    const second = toJson(loadString(first))
    expect(JSON.parse(first)).toEqual(JSON.parse(second))
  })
})
