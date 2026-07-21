/**
 * createTextEditMode — the shared buffer/commit/error state behind every
 * "edit as text" surface (EquationEditor, ExpressionEditor, and the
 * ReactionEditor rate).
 *
 * Each surface displays the ascii/DSL form of some AST node (`toAscii`) in a
 * textarea and re-parses it on commit (`parseEquation`/`parseExpression`). The
 * two invariants live here so all three surfaces behave identically:
 *
 *  - **Block emit until it parses.** On commit the buffer is parsed; an
 *    {@link ExpressionParseError} is surfaced (its message stored in `error`)
 *    and NOTHING is emitted — and `commit()` returns `false` so the caller can
 *    refuse to leave text mode. Escape reverts the buffer to the seed.
 *  - **Emit only when the reprint actually changed.** `reprint(parsed)` is
 *    compared against the seed (`toAscii` of the source); an untouched node
 *    re-parses to a byte-identical reprint and is left alone, so the
 *    non-injective printer never rewrites an AST the user didn't edit.
 *
 * The surface-specific merge/emit lives in {@link TextEditModeOptions.emit},
 * which is called only on a clean parse, only when editable, and only when the
 * value genuinely changed.
 */

import { createSignal, type Accessor } from 'solid-js'
import { ExpressionParseError } from '@earthsciml/ast'

export interface TextEditModeOptions<T> {
  /** Whether editing is disabled. When true no text is ever emitted. */
  readonly: Accessor<boolean | undefined>

  /**
   * The ascii/DSL string for the current source node (`toAscii(source)`). Used
   * to seed the buffer, to revert on Escape, and — via {@link reprint} — to
   * detect whether an edit actually changed anything.
   */
  seed: () => string

  /** Parse the buffer into an AST; throws {@link ExpressionParseError} on failure. */
  parse: (src: string) => T

  /** Reprint a parsed AST to ascii (`toAscii`), for the changed-check. */
  reprint: (parsed: T) => string

  /**
   * Apply a parsed value. Called only on a clean parse, only when editable, and
   * only when `reprint(parsed) !== seed()` (i.e. the edit genuinely changed the
   * node). Surface-specific: merges non-value fields, routes through the shared
   * document-path replace, etc.
   */
  emit: (parsed: T) => void

  /** Initial mode. Defaults to `'structural'`; pass `'text'` to make text the default surface. */
  initialMode?: 'structural' | 'text'
}

export interface TextEditMode {
  /** Whether the text surface is currently showing (mode is text AND editable). */
  inTextMode: Accessor<boolean>
  /** The current editable buffer. */
  text: Accessor<string>
  /** The last parse error message, or null when the buffer parses. */
  error: Accessor<string | null>
  /** Update the buffer (clears a stale error). Wire to the textarea's onInput. */
  onInput: (value: string) => void
  /** Parse + (maybe) emit. Returns whether the buffer parsed. Wire to onBlur. */
  commit: () => boolean
  /** Toggle between structural and text; leaving text is blocked until it parses. */
  toggleMode: () => void
  /** ⌘/Ctrl+Enter commits; Escape reverts to the seed. Wire to the textarea's onKeyDown. */
  handleKeyDown: (e: KeyboardEvent) => void
}

export function createTextEditMode<T>(opts: TextEditModeOptions<T>): TextEditMode {
  const [mode, setMode] = createSignal<'structural' | 'text'>(opts.initialMode ?? 'structural')
  const [text, setText] = createSignal(opts.seed())
  const [error, setError] = createSignal<string | null>(null)

  const inTextMode = () => mode() === 'text' && !opts.readonly()

  const commit = (): boolean => {
    let parsed: T
    try {
      parsed = opts.parse(text())
    } catch (e) {
      if (e instanceof ExpressionParseError) {
        setError(e.message)
        return false
      }
      throw e
    }
    setError(null)
    if (!opts.readonly() && opts.reprint(parsed) !== opts.seed()) opts.emit(parsed)
    return true
  }

  const enterTextMode = () => {
    setText(opts.seed())
    setError(null)
    setMode('text')
  }

  const toggleMode = () => {
    if (mode() === 'text') {
      // Block leaving text mode while the buffer doesn't parse.
      if (commit()) setMode('structural')
    } else {
      enterTextMode()
    }
  }

  const onInput = (value: string) => {
    setText(value)
    if (error()) setError(null)
  }

  const handleKeyDown = (e: KeyboardEvent) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault()
      commit()
    } else if (e.key === 'Escape') {
      e.preventDefault()
      setText(opts.seed())
      setError(null)
    }
  }

  return { inTextMode, text, error, onInput, commit, toggleMode, handleKeyDown }
}
