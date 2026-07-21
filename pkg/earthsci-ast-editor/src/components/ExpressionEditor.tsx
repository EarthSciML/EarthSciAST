/**
 * ExpressionEditor - Single expression editor without LHS = RHS format
 *
 * One editing surface over the controlled `initialExpression` / `onChange`
 * contract, plus a read-only render:
 *  - **editable**: an in-place textarea holding the expression's ascii DSL form
 *    (`toAscii` ⇄ `parseExpression` from `@earthsciml/ast`) — the same code-like
 *    syntax used everywhere else, the inverse of `toAscii`.
 *  - **readonly**: the expression rendered as pretty math via the read-only
 *    `ExpressionNode` renderer. No click-to-edit.
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
import { createMergedHighlight } from './merged-highlight'
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

  /**
   * Retained for API/web-component compatibility. The old draggable expression
   * palette was a structural-editing affordance and has been removed now that
   * editing is text-only, so this prop is currently a no-op.
   */
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
  const [hoveredVar, setHoveredVar] = createSignal<string | null>(null)

  // Text edit surface over the expression's ascii DSL form. The shared hook owns
  // the buffer/commit/error state and the block-on-error + emit-only-when-changed
  // invariants; a bare expression has nothing to merge, so it's emitted whole.
  // Text is the editable surface; readonly renders the pretty math instead.
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

  // Handle hovering over variables
  const handleHoverVar = (varName: string | null) => {
    setHoveredVar(varName)
  }

  const editorClasses = () => {
    const classes = ['expression-editor']
    if (props.readonly) classes.push('readonly')
    if (props.class) classes.push(props.class)
    return classes.join(' ')
  }

  return (
    <div class={editorClasses()} id={props.id}>
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
              />
            </div>
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
    </div>
  )
}

export default ExpressionEditor
