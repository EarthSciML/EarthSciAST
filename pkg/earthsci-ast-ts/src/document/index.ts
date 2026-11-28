/**
 * ESM documents as Markdown and Typst source text.
 *
 * An `.esm` document can be written as Markdown (LaTeX math, remark-directive
 * directives, YAML front matter and container bodies) or as Typst (Typst math,
 * `esm` package functions, Typst dictionaries). Both formats are lossless:
 * printing a document and reading it back gives the document again, and prose
 * between the constructs never changes what is read.
 *
 * The specification of both formats is the Lean model in `formal/`:
 * `formal/Esm/Document/Notation.lean` is the notation table, and this module is
 * a port of the executable definitions under `formal/Esm/Document/`, laid out
 * file by file after the Rust binding's `document` module:
 *
 * | TypeScript | Lean |
 * |---|---|
 * | `json.ts` | `Json.lean` (the value type, canonical numbers) |
 * | `number.ts` | `Number.lean` |
 * | `strings.ts` | `Strings.lean` |
 * | `yaml.ts` | `Yaml.lean` |
 * | `typst-dict.ts` | `TypstDict.lean` |
 * | `limits.ts` | (none: the readers' own bounds, as in Rust) |
 * | `math/` | `Math/*.lean` |
 * | `source/` | `Source/*.lean` |
 *
 * The golden set every binding reproduces is
 * `tests/conformance/document_format/` (CONFORMANCE_SPEC §5.58).
 */

import { canonicalizeDocument } from '../canonicalize.js'
import { ERROR_CODES, EsmDiagnosticError } from '../errors.js'
import {
  fromPlain,
  jarr,
  jnumToFloat,
  jobj,
  jstr,
  lookKvs,
  sortKeys,
  toPlain,
  type JNum,
  type Json,
} from './json.js'
import { MAX_JSON_DEPTH, MAX_NESTING, jsonDepth, reading, type Findings } from './limits.js'
import {
  parseLatex,
  parseTypst as parseTypstMath,
  printLatex,
  printLatexEqn,
  printTypst as printTypstMath,
  printTypstEqn,
} from './math/index.js'
import { printNum } from './number.js'
import { eqSides } from './source/equation.js'
import { parseMd, printMd } from './source/markdown-doc.js'
import { parseTyp, printTyp } from './source/typst-doc.js'

/** Which source format a document is written in. */
export type DocumentFormat = 'markdown' | 'typst'

/** Options of the document readers. */
export interface ParseDocumentOptions {
  /**
   * Give every number as a `NumericLiteral` (as `loadString` does with
   * `canonical: true`): an integer is an int literal and a decimal a float
   * literal, so `2` and `1.0e19` keep their kinds. An integer past 2^53
   * (`|z| > 2^53 - 1`), which no `number` holds exactly, is a `bigint` of its
   * exact value instead, so `9223372036854775807` stays that integer. Without
   * it numbers are plain `number`s, as `JSON.parse` gives (an integer past 2^53
   * is then its nearest binary64).
   */
  canonical?: boolean
}

/**
 * The document value the printers take: `canonicalizeDocument` applied, then
 * every object's keys sorted, as the Lean printers require (`Source.canonDoc`).
 */
function printable(doc: unknown): Json {
  return sortKeys(fromPlain(canonicalizeDocument(doc)))
}

/**
 * Print an ESM document as Markdown (`Source.Md.printMd`).
 *
 * `doc` is the JSON document value (plain numbers, or the `NumericLiteral`
 * leaves and `bigint`s of `losslessJsonParse`). It is put in canonical form first
 * (`canonicalizeDocument`), so two documents that canonicalize alike print
 * alike, and `parseMarkdown(printMarkdown(d))` is `canonicalizeDocument(d)`.
 */
export function printMarkdown(doc: object): string {
  return printMd(printable(doc))
}

/** Print an ESM document as Typst (`Source.Typ.printTyp`). See {@link printMarkdown}. */
export function printTypst(doc: object): string {
  return printTyp(printable(doc))
}

/** Print an ESM document in the given format. */
export function printDocument(doc: object, format: DocumentFormat): string {
  return format === 'markdown' ? printMarkdown(doc) : printTypst(doc)
}

/**
 * Print one expression, or one equation, as math under a set of declared names:
 * LaTeX for `'markdown'` (`Math.printLatex`), Typst math for `'typst'`
 * (`Math.printTypst`).
 *
 * `expr` is an ESM expression (a number, a name or an operator node) or an
 * equation, an object with `lhs` and `rhs` (other fields, such as `_comment`,
 * are not printed). An equation prints as in a document (`Source.eqExpr`,
 * `Math.printLatexEqn` / `Math.printTypstEqn`): its two sides around `=`,
 * except that an equation `x = faq` whose `faq` has output indices prints in
 * its defining form when that reads back as exactly the equation, the output
 * indices on the left and their ranges after the right side (Typst
 * `y_j = sum_(i in S) w_(i, j), j in C`). An expression whose top is `==` is a
 * comparison and prints as any expression does, never in the defining form.
 * `names` plays the part of the variables a component declares: a name in it
 * prints in its declared shape, and the printer avoids spellings that would
 * collide with it. The result is what a document display holds, without its
 * delimiters; no template is in scope.
 */
export function printMath(expr: unknown, names: readonly string[], format: DocumentFormat): string {
  let e = sortKeys(fromPlain(canonicalizeDocument(expr)))
  let eqn = false
  if (e.t === 'obj') {
    const lhs = lookKvs('lhs', e.kvs)
    const rhs = lookKvs('rhs', e.kvs)
    if (lhs !== undefined && rhs !== undefined) {
      e = jobj([
        ['args', jarr([lhs, rhs])],
        ['op', jstr('==')],
      ])
      eqn = true
    }
  }
  const sym = { names: [...names], templates: [] }
  if (format === 'markdown') return (eqn ? printLatexEqn : printLatex)(sym, e)
  return (eqn ? printTypstEqn : printTypstMath)(sym, e)
}

/**
 * The variable names an expression or an equation uses, in order of first use:
 * its string leaves under `lhs`, `rhs` and `args`. These are the `names` to
 * give {@link printMath} to show an expression on its own, with its names
 * declared.
 */
export function expressionNames(expr: unknown): string[] {
  const out: string[] = []
  const seen = new Set<string>()
  const walk = (v: unknown): void => {
    if (typeof v === 'string') {
      if (!seen.has(v)) {
        seen.add(v)
        out.push(v)
      }
    } else if (Array.isArray(v)) {
      for (const item of v) walk(item)
    } else if (v !== null && typeof v === 'object') {
      const fields = v as Record<string, unknown>
      for (const key of ['lhs', 'rhs', 'args']) {
        if (Object.prototype.hasOwnProperty.call(fields, key)) walk(fields[key])
      }
    }
  }
  walk(expr)
  return out
}

/**
 * Read one expression, or one equation, written as math under a set of
 * declared names: LaTeX for `'markdown'` (`Math.parseLatex`), Typst math for
 * `'typst'` (`Math.parseTypst`). The inverse of {@link printMath}:
 * `parseMath(printMath(e, names, f), names, f)` is `e` in canonical form.
 *
 * `text` is what a document display holds, without its delimiters. Text whose
 * top is `=` reads as an equation, an object with `lhs` and `rhs`, as a display
 * does (`Source.eqSides`), and so does an equation in its defining form,
 * `y_j = … , j in C`, whose right side reads as the `faq` with output indices
 * it writes (`Math.unlift`); any other text reads as an expression. `names` plays
 * the part of the variables a component declares: it decides how a run of
 * letters reads (in LaTeX, `RT` is the name `RT` when it is declared, the
 * product of `R` and `T` when they are). No template is in scope. Numbers come
 * back as the document readers give them (see {@link ParseDocumentOptions}).
 *
 * @throws {EsmDiagnosticError} with code `removed_op` when the math uses an
 *   operator removed from the format (esm-spec §4.2), and `parse_error` for any
 *   other text that is not math, and for one past a bound of the reader
 *   (`limits.ts`): nested too deeply, or holding a number beyond the binary64
 *   range.
 */
export function parseMath(
  text: string,
  names: readonly string[],
  format: DocumentFormat,
  options?: ParseDocumentOptions,
): unknown {
  const sym = { names: [...names], templates: [] }
  const [e, found] = reading(() =>
    format === 'markdown' ? parseLatex(sym, text) : parseTypstMath(sym, text),
  )
  if (e === undefined && found.removedOp === undefined && !found.tooDeep) {
    throw new EsmDiagnosticError(
      ERROR_CODES.PARSE_ERROR,
      format === 'markdown'
        ? 'not an ESM expression in LaTeX math'
        : 'not an ESM expression in Typst math',
    )
  }
  let read = e
  if (read !== undefined) {
    const sides = eqSides(read)
    if (sides !== undefined) {
      read = jobj([
        ['lhs', sides[0]],
        ['rhs', sides[1]],
      ])
    }
  }
  return checked(read, found, format, options)
}

/**
 * Read a Markdown ESM document (`Source.Md.parseMd`). The result is in canonical
 * form.
 *
 * @throws {EsmDiagnosticError} with code `removed_op` when the document's math
 *   uses an operator removed from the format (esm-spec §4.2), and `parse_error`
 *   for any other text that is not a Markdown ESM document, and for one past a
 *   bound of the reader (`limits.ts`): nested too deeply, or holding a number
 *   beyond the binary64 range.
 */
export function parseMarkdown(
  text: string,
  options?: ParseDocumentOptions,
): Record<string, unknown> {
  return read(text, 'markdown', options)
}

/** Read a Typst ESM document (`Source.Typ.parseTyp`). See {@link parseMarkdown}. */
export function parseTypst(text: string, options?: ParseDocumentOptions): Record<string, unknown> {
  return read(text, 'typst', options)
}

/** Read an ESM document written in the given format. See {@link parseMarkdown}. */
export function parseDocument(
  text: string,
  format: DocumentFormat,
  options?: ParseDocumentOptions,
): Record<string, unknown> {
  return read(text, format, options)
}

function read(
  text: string,
  format: DocumentFormat,
  options: ParseDocumentOptions | undefined,
): Record<string, unknown> {
  const [doc, found] = reading(() => (format === 'markdown' ? parseMd(text) : parseTyp(text)))
  return checked(doc, found, format, options) as Record<string, unknown>
}

/**
 * A reader's result, checked against the reader's bounds and turned into the
 * JSON value the caller gets.
 */
function checked(
  doc: Json | undefined,
  found: Findings,
  format: DocumentFormat,
  options: ParseDocumentOptions | undefined,
): unknown {
  if (found.tooDeep || (doc !== undefined && jsonDepth(doc) > MAX_JSON_DEPTH)) {
    throw new EsmDiagnosticError(
      ERROR_CODES.PARSE_ERROR,
      `the document nests too deeply for the reader (at most ${MAX_NESTING} constructs open at once, and ${MAX_JSON_DEPTH} levels of arrays and objects)`,
    )
  }
  if (doc === undefined) throw refusal(found.removedOp, format)
  const big = beyondBinary64(doc)
  if (big !== undefined) {
    throw new EsmDiagnosticError(
      ERROR_CODES.PARSE_ERROR,
      `the number \`${printNum(big)}\` is outside the binary64 range`,
    )
  }
  return toPlain(doc, options?.canonical === true)
}

/**
 * The first number of a document (in document order) that is beyond the
 * binary64 range (`1.0e400`): it has no nearest finite binary64 value, so no
 * JSON document can hold it.
 */
function beyondBinary64(doc: Json): JNum | undefined {
  const stack: Json[] = [doc]
  for (let v = stack.pop(); v !== undefined; v = stack.pop()) {
    if (v.t === 'num') {
      if (!Number.isFinite(jnumToFloat(v.n))) return v.n
    } else if (v.t === 'arr') {
      for (let k = v.xs.length - 1; k >= 0; k--) stack.push(v.xs[k])
    } else if (v.t === 'obj') {
      for (let k = v.kvs.length - 1; k >= 0; k--) stack.push(v.kvs[k][1])
    }
  }
  return undefined
}

/**
 * The diagnostic for a text the reader refused. The Lean reader refuses every
 * bad input alike; the code comes from the specification: a removed operator
 * the math writes in the call form or the escape form is refused by name
 * (CONFORMANCE §7.1), everything else is a parse error.
 */
function refusal(op: string | undefined, format: DocumentFormat): EsmDiagnosticError {
  if (op !== undefined) {
    return new EsmDiagnosticError(
      ERROR_CODES.REMOVED_OP,
      `\`${op}\` was removed from the format (esm-spec §4.2)`,
      {
        op,
      },
    )
  }
  return new EsmDiagnosticError(
    ERROR_CODES.PARSE_ERROR,
    format === 'markdown' ? 'not an ESM Markdown document' : 'not an ESM Typst document',
  )
}
