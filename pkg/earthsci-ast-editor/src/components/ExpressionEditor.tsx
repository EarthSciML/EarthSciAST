/**
 * ExpressionEditor - Single expression editor without LHS = RHS format
 *
 * This component provides an interactive editor for individual expressions,
 * displaying them as a single mathematical expression with clickable
 * nodes that can be edited using the ExpressionNode component.
 * This is distinct from EquationEditor which shows "left = right" format.
 */

import type { Component } from 'solid-js'
import { createSignal, Show } from 'solid-js'
import type { Expression } from '@earthsciml/ast'
import { ExpressionNode } from './ExpressionNode'
import { ExpressionPalette } from './ExpressionPalette'
import { createMergedHighlight } from './merged-highlight'
import { replaceExpressionAtPath } from '../primitives/path-utils'

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
