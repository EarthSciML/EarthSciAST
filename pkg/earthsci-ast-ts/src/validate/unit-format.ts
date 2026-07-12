/**
 * Go-mirroring unit-string formatters and affine-unit predicate.
 *
 * Pure string helpers (no cross-module deps) shared by the reaction- and
 * model-check passes. Their output is conformance-pinned against the Go
 * binding's helpers of the same name, so the emitted `expected_rate_units`
 * payloads line up byte-for-byte across bindings.
 */

/**
 * Split a unit string like "mol/L" into ("mol", "L") or "mol/(L*s)" into
 * ("mol", "L*s"). The split is on the first top-level '/'. If no '/' appears,
 * the whole string is the numerator. Matches Go's splitUnitNumDen so the
 * expected_rate_units payloads line up byte-for-byte across bindings.
 */
function splitUnitNumDen(s: string): [string, string] {
  const trimmed = s.trim()
  if (trimmed === '') return ['', '']
  let depth = 0
  for (let i = 0; i < trimmed.length; i++) {
    const c = trimmed[i]
    if (c === '(') depth++
    else if (c === ')') depth--
    else if (c === '/' && depth === 0) {
      const num = trimmed.slice(0, i).trim()
      let den = trimmed.slice(i + 1).trim()
      if (den.startsWith('(') && den.endsWith(')')) {
        den = den.slice(1, -1)
      }
      return [num, den]
    }
  }
  return [trimmed, '']
}

/**
 * Render a unit factor raised to an integer power. Parenthesizes compound
 * factors when the exponent is not 1. Mirrors Go's powerFactor.
 */
function powerFactor(s: string, n: number): string {
  const t = s.trim()
  if (t === '') return ''
  if (n === 1) return t
  if (/[*/]/.test(t)) return `(${t})^${n}`
  return `${t}^${n}`
}

/**
 * Compose the canonical expected rate-unit string from the reference species
 * unit string and total reaction order: rate_units = species_units^(1-order) / s.
 * Matches the contract in tests/invalid/expected_errors.json and the Go
 * formatExpectedRateUnits helper so cross-binding details stay identical.
 *
 *   ("mol/L", 2) → "L/(mol*s)"
 *   ("mol/L", 1) → "1/s"
 *   ("mol/L", 0) → "mol/(L*s)"
 *   ("mol/m^3", 2) → "m^3/(mol*s)"
 */
export function formatExpectedRateUnits(speciesUnits: string, totalOrder: number): string {
  let exp = 1 - totalOrder
  if (exp === 0) return '1/s'
  let [num, den] = splitUnitNumDen(speciesUnits)
  if (exp < 0) {
    ;[num, den] = [den, num]
    exp = -exp
  }
  let numStr = powerFactor(num, exp)
  const denFactors: string[] = []
  const df = powerFactor(den, exp)
  if (df !== '') denFactors.push(df)
  denFactors.push('s')
  if (numStr === '') numStr = '1'
  if (denFactors.length === 1) return `${numStr}/${denFactors[0]}`
  return `${numStr}/(${denFactors.join('*')})`
}

const AFFINE_TEMP_UNITS = new Set(['C', 'degC', 'Celsius'])

export function isAffineTempUnit(u: string): boolean {
  return AFFINE_TEMP_UNITS.has(u.trim())
}
