#!/usr/bin/env node
/**
 * Generate the cross-language expression-text-parser conformance corpus.
 *
 * The TypeScript `parseExpression` / `parseEquation` (pkg/earthsci-ast-ts) is the
 * ORACLE: it is the original implementation, its 76-test suite is green, and the
 * Julia / Python / Rust / Go ports are written against the corpus this script
 * emits rather than against each other. Every case records the source text, the
 * AST the oracle produces, and the `toAscii` reprint of that AST, so a port is
 * checkable on three properties at once:
 *
 *   1. parse(text)            == ast                (exact AST agreement)
 *   2. to_ascii(parse(text))  == reprint            (round-trip through the printer)
 *   3. parse(reprint)         == ast                (reprint is itself parseable)
 *
 * Source texts come from three places: a curated list mirroring the oracle's own
 * test corpus (every operator tier — scalar, array/call-shaped, reduction/
 * array-query), the `ascii` renderings of the shared display fixtures
 * (tests/display/*.json), and an explicit refusal list for the structural ops
 * that have no text surface yet plus genuinely malformed input.
 *
 * Regenerate with:  node scripts/generate-expression-parse-corpus.mjs
 * (Rebuild the TS package first — this reads pkg/earthsci-ast-ts/dist.)
 */

import { readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const TS = join(ROOT, 'pkg/earthsci-ast-ts/dist/esm/index.js')
const OUT_DIR = join(ROOT, 'tests/conformance/expression_parse')

const { parseExpression, parseEquation, toAscii } = await import(TS)

// --- curated source texts, by tier ------------------------------------------
// Mirrors pkg/earthsci-ast-ts/src/parse-expression.test.ts. Keep in sync when
// the oracle's coverage grows.

const SCALAR = [
  'k1 * NO2 * O2 - k2 * O3',
  'A * exp(-(Ea / (R * T)))',
  'r * N * (1 - N / K)',
  'a^b^c',
  '(300 / T)^-1.3',
  'a - (b - c)',
  'D(O3)/Dt',
  'D(O3, t)',
  'atan2(y, x)',
  'ifelse(x > 0, a, b)',
  'p and q or not r',
  'div(u)',
  '0.0004',
  'Emissions.NO',
  'x == 0',
  'x != 0',
  'x >= 1',
  'x <= 1',
  '-a + b',
  '2 * (a + b)',
  'sqrt(a^2 + b^2)',
  '∂u_∂z^2 + ∂v_∂z^2',
  '∇phi',
]

const ARRAY_TIER = [
  '[1, 2, 3]',
  '[[1, 2], [3, 4]]',
  'u[i, j]',
  'datetime.year(t)',
  'true',
  'integral(f, x, 0, 1)',
  'reshape(a, [3, 4])',
  'transpose(a)',
  'transpose(a, [1, 0])',
  'concat(a, b, axis=0)',
]

const REDUCTION_TIER = [
  'sum[i] (i * j) where {i in 1:2, j in faces}',
  'sum[i] (u[i, k]) where {i in cells, k in edges_of_cell(i)}',
  'min[i] (a[i]) where {i in cells}',
  'sum[] (u[i]) where {i in cells}',
  'max[i] (i * j) where {i in 1:2, j in options} [semiring=max_product]',
  'sum[j] (A[i, j]) where {i in src, j in tgt} join(src_bin=tgt_bin) if A[i, j] > atol',
  'argmin[g] (a[g]) where {g in gens}',
  'argmax[g] (a[g]) where {g in gens}',
  'any[e] (u[f]) where {f in faces} [semiring=bool_and_or]',
  'sqrt(sum[] (v[e] * v[e]) where {e in space})',
  'arrhenius<A_pre=1.8e-12, Ea=1500>',
  'polygon_intersection_area(a[i], b[j], manifold=planar)',
  'makearray([2:NLON - 1, 1:NLAT] = a[i, j] / dlon, [1:1, 1:NLAT] = b)',
  'makearray([2:NLON, 1:NLAT] = central_D<f=f>, [1:1, 1:NLAT] = sum[j] (u[1, j]) where {j in lat})',
]

// Structural ops with no text surface yet, plus malformed input. Both MUST be
// refused with the binding's expression-parse error.
const REFUSALS = [
  { text: 'table_lookup(a)', reason: 'structural op with no text surface' },
  { text: 'broadcast(y)', reason: 'structural op with no text surface' },
  { text: 'enum(a, b)', reason: 'structural op with no text surface' },
  { text: 'k * ', reason: 'truncated binary expression' },
  { text: 'a b', reason: 'implicit multiplication is not admitted' },
  { text: '(a + b', reason: 'unclosed parenthesis' },
  { text: 'makearray(x)', reason: 'makearray body without its [region] bracket' },
  { text: '', reason: 'empty input' },
  { text: '∑', reason: 'unicode big-operator display form is not input syntax' },
]

const EQUATIONS = [
  'D(x)/Dt = k * A - x',
  'y = ifelse(x == 0, a, b)',
  'O3 = k1 * NO2 * O2',
]

const EQUATION_REFUSALS = [
  { text: 'a + b', reason: 'no top-level lone = separator' },
  { text: 'x == 0', reason: '== is a comparison, not the lhs/rhs separator' },
]

// --- display fixtures: every ascii rendering the shared corpus carries -------

function displayAsciiTexts() {
  const dir = join(ROOT, 'tests/display')
  const texts = new Set()
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.json')) continue
    let data
    try {
      data = JSON.parse(readFileSync(join(dir, f), 'utf8'))
    } catch {
      continue
    }
    const walk = (v) => {
      if (Array.isArray(v)) return v.forEach(walk)
      if (v && typeof v === 'object') {
        if (typeof v.ascii === 'string' && v.ascii.length > 0) texts.add(v.ascii)
        Object.values(v).forEach(walk)
      }
    }
    walk(data)
  }
  return [...texts].sort()
}

// --- build ------------------------------------------------------------------

const expressions = []
const expressionErrors = []
const seen = new Set()

function addExpression(text, tier) {
  if (seen.has(text)) return
  seen.add(text)
  let ast
  try {
    ast = parseExpression(text)
  } catch (e) {
    // A display rendering the parser does not admit is recorded as a refusal
    // rather than dropped: the ports must agree on rejection too.
    expressionErrors.push({ text, tier, reason: e.message })
    return
  }
  let reprint
  try {
    reprint = toAscii(ast)
  } catch (e) {
    throw new Error(`toAscii failed on the AST parsed from ${JSON.stringify(text)}: ${e.message}`)
  }
  // Property 3, asserted here so a bad case never reaches the corpus.
  const reparsed = parseExpression(reprint)
  if (JSON.stringify(reparsed) !== JSON.stringify(ast)) {
    throw new Error(`reprint of ${JSON.stringify(text)} does not re-parse to the same AST`)
  }
  expressions.push({ text, tier, ast, reprint })
}

for (const t of SCALAR) addExpression(t, 'scalar')
for (const t of ARRAY_TIER) addExpression(t, 'array')
for (const t of REDUCTION_TIER) addExpression(t, 'reduction')
for (const t of displayAsciiTexts()) addExpression(t, 'display-fixture')

for (const { text, reason } of REFUSALS) {
  let threw = false
  try {
    parseExpression(text)
  } catch {
    threw = true
  }
  if (!threw) throw new Error(`expected the oracle to refuse ${JSON.stringify(text)}`)
  expressionErrors.push({ text, tier: 'refusal', reason })
}

const equations = []
for (const text of EQUATIONS) {
  const eq = parseEquation(text)
  equations.push({ text, lhs: eq.lhs, rhs: eq.rhs })
}
const equationErrors = []
for (const { text, reason } of EQUATION_REFUSALS) {
  let threw = false
  try {
    parseEquation(text)
  } catch {
    threw = true
  }
  if (!threw) throw new Error(`expected the oracle to refuse equation ${JSON.stringify(text)}`)
  equationErrors.push({ text, reason })
}

const corpus = {
  $comment:
    'Cross-language expression-text-parser conformance corpus. GENERATED by ' +
    'scripts/generate-expression-parse-corpus.mjs from the TypeScript oracle — do not hand-edit. ' +
    'Every binding must satisfy: parse(text) == ast; to_ascii(parse(text)) == reprint; ' +
    'parse(reprint) == ast. Entries in expression_errors and equation_errors must be REFUSED ' +
    "with the binding's expression-parse error type; the `reason` is prose and is not asserted.",
  oracle: '@earthsciml/ast parseExpression / parseEquation',
  expressions,
  expression_errors: expressionErrors,
  equations,
  equation_errors: equationErrors,
}

mkdirSync(OUT_DIR, { recursive: true })
writeFileSync(join(OUT_DIR, 'cases.json'), JSON.stringify(corpus, null, 2) + '\n')

console.log(
  `expressions: ${expressions.length}\n` +
    `expression_errors: ${expressionErrors.length}\n` +
    `equations: ${equations.length}\n` +
    `equation_errors: ${equationErrors.length}\n` +
    `-> ${join(OUT_DIR, 'cases.json')}`,
)
