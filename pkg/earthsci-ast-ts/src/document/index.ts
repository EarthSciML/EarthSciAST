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
import { MAX_JSON_DEPTH, MAX_NESTING, jsonDepth, reading } from './limits.js'
import { printLatex, printTypst as printTypstMath } from './math/index.js'
import { printNum } from './number.js'
import { parseMd, printMd } from './source/markdown-doc.js'
import { parseTyp, printTyp } from './source/typst-doc.js'

/** Which source format a document is written in. */
export type DocumentFormat = 'markdown' | 'typst'

/** Options of the document readers. */
export interface ParseDocumentOptions {
  /**
   * Give every number as a `NumericLiteral` (as `loadString` does with
   * `canonical: true`): an integer is an int literal and a decimal a float
   * literal, so `2` and `1.0e19` keep their kinds. Without it numbers are plain
   * `number`s, as `JSON.parse` gives.
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
 * leaves of `losslessJsonParse`). It is put in canonical form first
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
 * are not printed), which prints as its two sides around `=` as in a document.
 * `names` plays the part of the variables a component declares: a name in it
 * prints in its declared shape, and the printer avoids spellings that would
 * collide with it. The result is what a document display holds, without its
 * delimiters; no template is in scope.
 */
export function printMath(expr: unknown, names: readonly string[], format: DocumentFormat): string {
  let e = sortKeys(fromPlain(canonicalizeDocument(expr)))
  if (e.t === 'obj') {
    const lhs = lookKvs('lhs', e.kvs)
    const rhs = lookKvs('rhs', e.kvs)
    if (lhs !== undefined && rhs !== undefined) {
      e = jobj([
        ['args', jarr([lhs, rhs])],
        ['op', jstr('==')],
      ])
    }
  }
  const sym = { names: [...names], templates: [] }
  return format === 'markdown' ? printLatex(sym, e) : printTypstMath(sym, e)
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
  return toPlain(doc, options?.canonical === true) as Record<string, unknown>
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
