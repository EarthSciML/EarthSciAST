/**
 * EquationEditor - Single equation editor with LHS = RHS format
 *
 * Two edit surfaces over the SAME `equation: Equation` / `onEquationChange`
 * contract:
 *  - **structural** (default): clickable `ExpressionNode`s for LHS and RHS, edited
 *    via the shared document-path replace;
 *  - **text**: an in-place textarea holding the equation's ascii DSL form
 *    (`toAscii` ⇄ `parseEquation` from `@earthsciml/ast`). This is the same
 *    code-like syntax used everywhere else; it's the inverse of `toAscii`.
 *
 * The text surface **blocks emit until it parses**: on commit (blur, ⌘/Ctrl+Enter,
 * or toggling back) the buffer is parsed; a parse error is surfaced and NOTHING is
 * emitted, and you can't leave text mode until it parses (Escape reverts). A
 * successful parse emits only when the equation actually changed (reprint differs),
 * preserving non-lhs/rhs fields such as `_comment` — so an untouched equation's AST
 * stays byte-identical (the parser is a faithful, but structure-normalizing,
 * inverse of the non-injective printer).
 */

import type { Component } from 'solid-js'
import { createSignal, Show } from 'solid-js'
import type { Equation, Expression } from '@earthsciml/ast'
import { toAscii, parseEquation, ExpressionParseError } from '@earthsciml/ast'
import { ExpressionNode } from './ExpressionNode'
import { createMergedHighlight } from './merged-highlight'
import { replaceAtDocumentPath } from './document-path'
import './equation-editor.css'

export interface EquationEditorProps {
  /** The equation to display and edit */
  equation: Equation

  /** Callback when the equation is modified */
  onEquationChange?: (newEquation: Equation) => void

  /** Currently highlighted variable equivalence class */
  highlightedVars?: Set<string>

  /** Whether the editor is in read-only mode */
  readonly?: boolean

  /** CSS class for styling */
  class?: string

  /** Unique identifier for this editor */
  id?: string
}

/**
 * Main EquationEditor component
 */
export const EquationEditor: Component<EquationEditorProps> = (props) => {
  const [selectedPath, setSelectedPath] = createSignal<(string | number)[] | null>(null)
  const [hoveredVar, setHoveredVar] = createSignal<string | null>(null)

  // Text-mode state: the mode, the editable ascii buffer, and the last parse
  // error (null when the buffer parses). Default to structural; text is opt-in.
  const [mode, setMode] = createSignal<'structural' | 'text'>('structural')
  const [text, setText] = createSignal('')
  const [error, setError] = createSignal<string | null>(null)

  const inTextMode = () => mode() === 'text' && !props.readonly

  // Base highlight set merged with the locally hovered variable.
  const highlightedVars = createMergedHighlight(() => props.highlightedVars, hoveredVar)

  // Handle selection of expression nodes
  const handleSelect = (path: (string | number)[]) => {
    setSelectedPath(path)
  }

  // Handle hovering over variables
  const handleHoverVar = (varName: string | null) => {
    setHoveredVar(varName)
  }

  // Handle replacement of expression parts. The paths handed up by
  // ExpressionNode are rooted at the equation (`['lhs']`, `['rhs', 'args', 0]`,
  // …), so this uses the document-dialect replace rather than the pure
  // expression-path variant.
  const handleReplace = (path: (string | number)[], newExpr: Expression) => {
    if (props.readonly || !props.onEquationChange) return

    const newEquation = replaceAtDocumentPath(props.equation, path, newExpr)
    props.onEquationChange(newEquation)
  }

  // Parse the current text buffer and, on success, emit iff the equation's math
  // actually changed (reprint differs) — preserving non-lhs/rhs fields (comment,
  // metadata) by merging onto the existing equation. On a parse error, surface it
  // and emit NOTHING (block). Returns whether the buffer parsed.
  const commit = (): boolean => {
    let parsed: Equation
    try {
      parsed = parseEquation(text())
    } catch (e) {
      if (e instanceof ExpressionParseError) {
        setError(e.message)
        return false
      }
      throw e
    }
    setError(null)
    if (props.onEquationChange && !props.readonly && toAscii(parsed) !== toAscii(props.equation)) {
      props.onEquationChange({ ...props.equation, lhs: parsed.lhs, rhs: parsed.rhs })
    }
    return true
  }

  const enterTextMode = () => {
    setText(toAscii(props.equation))
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

  const handleTextKeyDown = (e: KeyboardEvent) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault()
      commit()
    } else if (e.key === 'Escape') {
      e.preventDefault()
      setText(toAscii(props.equation))
      setError(null)
    }
  }

  const editorClasses = () => {
    const classes = ['equation-editor']
    if (props.readonly) classes.push('readonly')
    if (props.class) classes.push(props.class)
    return classes.join(' ')
  }

  return (
    <div class={editorClasses()} id={props.id}>
      <Show when={!props.readonly}>
        <div class="esm-eq-toolbar">
          <button
            type="button"
            class="esm-eq-mode-btn"
            aria-pressed={inTextMode()}
            title={inTextMode() ? 'Switch to structural editing' : 'Edit as text'}
            onClick={toggleMode}
          >
            {inTextMode() ? 'Structural' : 'Edit as text'}
          </button>
        </div>
      </Show>

      <Show
        when={inTextMode()}
        fallback={
          <div class="equation-content">
            {/* Left-hand side */}
            <div class="equation-lhs">
              <ExpressionNode
                expr={props.equation.lhs}
                path={['lhs']}
                highlightedVars={highlightedVars()}
                onHoverVar={handleHoverVar}
                onSelect={handleSelect}
                onReplace={handleReplace}
                selectedPath={selectedPath()}
              />
            </div>

            {/* Equals sign */}
            <div class="equation-equals" aria-label="equals">
              =
            </div>

            {/* Right-hand side */}
            <div class="equation-rhs">
              <ExpressionNode
                expr={props.equation.rhs}
                path={['rhs']}
                highlightedVars={highlightedVars()}
                onHoverVar={handleHoverVar}
                onSelect={handleSelect}
                onReplace={handleReplace}
                selectedPath={selectedPath()}
              />
            </div>
          </div>
        }
      >
        <div class="esm-eq-text">
          <textarea
            class="esm-eq-textarea"
            classList={{ 'has-error': error() != null }}
            value={text()}
            spellcheck={false}
            rows={2}
            aria-label="Equation text"
            aria-invalid={error() != null}
            onInput={(e) => {
              setText(e.currentTarget.value)
              if (error()) setError(null)
            }}
            onBlur={() => commit()}
            onKeyDown={handleTextKeyDown}
          />
          <Show when={error()}>
            <div class="esm-eq-error" role="alert">
              {error()}
            </div>
          </Show>
        </div>
      </Show>

      {/* Optional equation metadata display */}
      <Show when={props.equation._comment}>
        <div class="equation-description" title="Equation comment">
          {props.equation._comment}
        </div>
      </Show>
    </div>
  )
}

export default EquationEditor
