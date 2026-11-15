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
 * | `math/` | `Math/*.lean` |
 * | `source/` | `Source/*.lean` |
 *
 * The golden set every binding reproduces is
 * `tests/conformance/document_format/` (CONFORMANCE_SPEC §5.58).
 */

import { canonicalizeDocument } from '../canonicalize.js'
import { ERROR_CODES, EsmDiagnosticError } from '../errors.js'
import { fromPlain, jarr, jobj, jstr, lookKvs, sortKeys, toPlain, type Json } from './json.js'
import { REMOVED_OPS, printLatex, printTypst as printTypstMath } from './math/index.js'
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
 * @throws {EsmDiagnosticError} with code `removed_op` when the text uses an
 *   operator removed from the format (esm-spec §4.2), and `parse_error` for any
 *   other text that is not a Markdown ESM document.
 */
export function parseMarkdown(
  text: string,
  options?: ParseDocumentOptions,
): Record<string, unknown> {
  const d = parseMd(text)
  if (d === undefined) throw refusal(text, 'markdown')
  return toPlain(d, options?.canonical === true) as Record<string, unknown>
}

/** Read a Typst ESM document (`Source.Typ.parseTyp`). See {@link parseMarkdown}. */
export function parseTypst(text: string, options?: ParseDocumentOptions): Record<string, unknown> {
  const d = parseTyp(text)
  if (d === undefined) throw refusal(text, 'typst')
  return toPlain(d, options?.canonical === true) as Record<string, unknown>
}

/** Read an ESM document written in the given format. See {@link parseMarkdown}. */
export function parseDocument(
  text: string,
  format: DocumentFormat,
  options?: ParseDocumentOptions,
): Record<string, unknown> {
  return format === 'markdown' ? parseMarkdown(text, options) : parseTypst(text, options)
}

/**
 * The diagnostic for a text the reader refused. The Lean reader refuses every
 * bad input alike; the code comes from the specification: a removed operator
 * written in the call form or the escape form is refused by name (CONFORMANCE
 * §7.1), everything else is a parse error.
 */
function refusal(text: string, format: DocumentFormat): EsmDiagnosticError {
  const op = removedOpIn(text, format)
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

/**
 * The first removed operator the text writes in a call or escape form:
 * `\operatorname{op}` / `\esm{op}` in LaTeX (with `\_` for `_`), `op("op")` /
 * `esm.node("op"` in Typst.
 */
function removedOpIn(text: string, format: DocumentFormat): string | undefined {
  const [opens, close] =
    format === 'markdown' ? [['\\operatorname{', '\\esm{'], '}'] : [['op("', 'esm.node("'], '"']
  for (const open of opens) {
    for (let i = text.indexOf(open); i >= 0; i = text.indexOf(open, i + 1)) {
      const start = i + open.length
      const end = text.indexOf(close, start)
      if (end < 0) continue
      let body = text.slice(start, end)
      if (format === 'markdown') body = body.replace(/\\_/g, '_')
      if (REMOVED_OPS.includes(body)) return body
    }
  }
  return undefined
}
