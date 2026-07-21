/**
 * ExpressionEditor - Single expression editor without LHS = RHS format
 *
 * Two edit surfaces over the SAME controlled `initialExpression` / `onChange`
 * contract:
 *  - **text** (default when editable): an in-place textarea holding the
 *    expression's ascii DSL form (`toAscii` ⇄ `parseExpression` from
 *    `@earthsciml/ast`) — the same code-like syntax used everywhere else, the
 *    inverse of `toAscii`.
 *  - **structural**: clickable `ExpressionNode`s (plus optional palette), edited
 *    via the shared expression-path replace — now opt-in behind the toggle.
 *
 * The text surface **blocks emit until it parses** and **emits only when the
 * reprint actually changed** (so an untouched expression's AST stays
 * byte-identical). Unlike EquationEditor there is no comment/metadata to merge:
 * a bare expression is emitted wholesale. The buffer/commit/error state lives in
 * the shared {@link createTextEditMode} hook.
 */

import type { Component } from 'solid-js'
import { createSignal, Show } from 'solid-js'
import type { Expression } from '@earthsciml/ast'
import { toAscii, parseExpression } from '@earthsciml/ast'
import { ExpressionNode } from './ExpressionNode'
import { ExpressionPalette } from './ExpressionPalette'
import { createMergedHighlight } from './merged-highlight'
import { replaceExpressionAtPath } from '../primitives/path-utils'
import { createTextEditMode } from './text-edit-mode'
import './equation-editor.css'

export interface ExpressionEditorProps {
  /**
   * The expression to display and edit. This is a controlled prop: the parent
   * owns the expression and receives edits through {@link onChange}. (The name
   * is retained for API compatibility; it is not merely an initial value.)
   */
  initialExpression: Expression

  /** Callback when the expression is modified */
  onChange?: (newExpression: Expression) => void

  /** Currently highlighted variable equivalence class */
  highlightedVars?: Set<string>

  /**
   * Whether the editor is read-only. Defaults to `false` (editing enabled);
   * pass `true` for a read-only view. Matches the sibling editors' `readonly`
   * convention.
   */
  readonly?: boolean

  /** Whether to show the expression palette */
  showPalette?: boolean

  /** CSS class for styling */
  class?: string

  /** Unique identifier for this editor */
  id?: string
}

/**
 * Main ExpressionEditor component
 */
export const ExpressionEditor: Component<ExpressionEditorProps> = (props) => {
  const [selectedPath, setSelectedPath] = createSignal<(string | number)[] | null>(null)
  const [hoveredVar, setHoveredVar] = createSignal<string | null>(null)
  const [showPalettePanel, setShowPalettePanel] = createSignal(props.showPalette ?? false)

  // Text edit surface over the expression's ascii DSL form. The shared hook owns
  // the buffer/commit/error state and the block-on-error + emit-only-when-changed
  // invariants; a bare expression has nothing to merge, so it's emitted whole.
  // Text is the default surface (when editable); structural is opt-in behind the
  // toggle.
  const textMode = createTextEditMode<Expression>({
    readonly: () => props.readonly,
    seed: () => toAscii(props.initialExpression),
    // parseExpression returns the wider `Expr` (`Expression | NumericLiteral`);
    // narrow to the editor's public `Expression`, matching the codebase's
    // parse→Expression bridging convention.
    parse: (src) => parseExpression(src) as Expression,
    reprint: (parsed) => toAscii(parsed),
    emit: (parsed) => props.onChange?.(parsed),
    initialMode: 'text',
  })

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

  // Handle replacement of expression parts. Paths are pure expression-dialect
  // (rooted at the expression itself), so the shared path-utils replace applies
  // directly. Controlled: the new value flows out via onChange, not internal
  // state.
  const handleReplace = (path: (string | number)[], newExpr: Expression) => {
    if (props.readonly) return

    const updatedExpression = replaceExpressionAtPath(props.initialExpression, path, newExpr)
    props.onChange?.(updatedExpression)
  }

  // Handle palette insertion
  const handleInsertExpression = (expr: Expression) => {
    const selected = selectedPath()
    if (selected) {
      handleReplace(selected, expr)
    } else {
      // If nothing selected, replace the entire expression
      handleReplace([], expr)
    }
    setShowPalettePanel(false)
  }

  const editorClasses = () => {
    const classes = ['expression-editor']
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
            aria-pressed={textMode.inTextMode()}
            title={textMode.inTextMode() ? 'Switch to structural editing' : 'Edit as text'}
            onClick={textMode.toggleMode}
          >
            {textMode.inTextMode() ? 'Structural' : 'Edit as text'}
          </button>
        </div>
      </Show>

      <Show
        when={textMode.inTextMode()}
        fallback={
          <div class="expression-editor-content">
            {/* Main expression display */}
            <div class="expression-main">
              <ExpressionNode
                expr={props.initialExpression}
                path={[]}
                highlightedVars={highlightedVars()}
                onHoverVar={handleHoverVar}
                onSelect={handleSelect}
                onReplace={handleReplace}
                selectedPath={selectedPath()}
              />
            </div>

            {/* Optional palette toggle button */}
            <Show when={props.showPalette && !props.readonly}>
              <button
                class="palette-toggle-btn"
                onClick={() => setShowPalettePanel((prev) => !prev)}
                title="Toggle expression palette"
                aria-label="Toggle expression palette"
              >
                {showPalettePanel() ? '←' : '→'}
              </button>
            </Show>
          </div>
        }
      >
        <div class="esm-eq-text">
          <textarea
            class="esm-eq-textarea"
            classList={{ 'has-error': textMode.error() != null }}
            value={textMode.text()}
            spellcheck={false}
            rows={2}
            aria-label="Expression text"
            aria-invalid={textMode.error() != null}
            onInput={(e) => textMode.onInput(e.currentTarget.value)}
            onBlur={() => textMode.commit()}
            onKeyDown={textMode.handleKeyDown}
          />
          <Show when={textMode.error()}>
            <div class="esm-eq-error" role="alert">
              {textMode.error()}
            </div>
          </Show>
        </div>
      </Show>

      {/* Optional expression palette */}
      <Show when={showPalettePanel() && props.showPalette && !props.readonly}>
        <div class="expression-palette-container">
          <ExpressionPalette
            visible={showPalettePanel()}
            onInsertExpression={handleInsertExpression}
            class="expression-editor-palette"
          />
        </div>
      </Show>
    </div>
  )
}

export default ExpressionEditor
