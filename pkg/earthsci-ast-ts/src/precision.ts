import type { EsmFile, ModelVariable } from './types.js'

/** Precision of a root's omitted domain.element_type (esm-spec §11.3.3). */
export function omittedPrecision(version: unknown): 'Float64' | 'unspecified' {
  const parts = typeof version === 'string' && /^(\d+)\.(\d+)\.\d+$/.exec(version)
  if (parts && (Number(parts[1]) > 1 || (Number(parts[1]) === 1 && Number(parts[2]) >= 3))) {
    return 'unspecified'
  }
  return 'Float64'
}

/** Return the declared element type or `unspecified`. With no variable, query the document default. */
export function precisionSource(
  document: EsmFile,
  variable?: Pick<ModelVariable, 'element_type'>,
): 'Float32' | 'Float64' | 'unspecified' {
  return variable?.element_type ?? document.domain?.element_type ?? omittedPrecision(document.esm)
}
