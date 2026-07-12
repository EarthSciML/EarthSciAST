/**
 * ExpressionPalette - Interactive sidebar with draggable expression templates
 *
 * This component provides a palette of commonly used mathematical expressions
 * and operators that can be dragged onto the expression tree. Features:
 * - Organized sections: Calculus, Arithmetic, Functions, Logic
 * - Context-aware suggestions based on current model
 * - Keyboard shortcut support with search filter
 * - Drag-and-drop integration with expression tree
 */

import type { Component } from 'solid-js'
import { createSignal, createMemo, For, Show } from 'solid-js'
import type { Expression, Model } from '@earthsciml/ast'
import {
  EXPRESSION_TEMPLATES,
  CATEGORY_CONFIG,
  type ExpressionTemplate,
} from './expression-templates'

export interface ExpressionPaletteProps {
  /** Current model for context-aware suggestions */
  currentModel?: Model

  /** Callback when an expression template is inserted */
  onInsertExpression?: (expr: Expression) => void

  /** Whether the palette is visible */
  visible?: boolean

  /** CSS class for styling */
  class?: string

  /** Quick insert mode (triggered by '/' shortcut) */
  quickInsertMode?: boolean

  /** Search query for filtering expressions */
  searchQuery?: string

  /** Callback when search query changes */
  onSearchQueryChange?: (query: string) => void

  /** Callback when quick insert mode should be closed */
  onCloseQuickInsert?: () => void
}

/**
 * Card for a single draggable expression template. Named `TemplateCard` to
 * avoid colliding with the `ExpressionTemplate` data interface.
 */
const TemplateCard: Component<{
  template: ExpressionTemplate
  onInsert: (expr: Expression) => void
}> = (props) => {
  const [isDragging, setIsDragging] = createSignal(false)

  const handleDragStart = (e: DragEvent) => {
    if (e.dataTransfer) {
      e.dataTransfer.effectAllowed = 'copy'
      e.dataTransfer.setData(
        'application/json',
        JSON.stringify({
          type: 'expression-template',
          expression: props.template.expression,
          templateId: props.template.id,
        }),
      )
    }
    setIsDragging(true)
  }

  const handleDragEnd = () => {
    setIsDragging(false)
  }

  const handleClick = () => {
    props.onInsert(props.template.expression)
  }

  return (
    <div
      class={`expression-template ${isDragging() ? 'dragging' : ''}`}
      draggable={true}
      onDragStart={handleDragStart}
      onDragEnd={handleDragEnd}
      onClick={handleClick}
      title={props.template.description}
      role="button"
      tabIndex={0}
      aria-label={`Insert ${props.template.label}: ${props.template.description}`}
    >
      <div class="template-label">{props.template.label}</div>
      <div class="template-description">{props.template.description}</div>
    </div>
  )
}

/**
 * Component for context-aware suggestions from current model
 */
const ContextSuggestions: Component<{
  model?: Model
  onInsert: (expr: Expression) => void
}> = (props) => {
  const suggestions = createMemo(() => {
    if (!props.model) return []

    const items: { label: string; expression: Expression; type: 'variable' | 'parameter' }[] = []

    // Add model variables (keyed by name in the ESM schema)
    if (props.model.variables) {
      Object.entries(props.model.variables).forEach(([name, variable]) => {
        items.push({
          label: name,
          expression: name,
          type: variable.type === 'parameter' ? 'parameter' : 'variable',
        })
      })
    }

    return items
  })

  return (
    <Show when={suggestions().length > 0}>
      <div class="context-suggestions">
        <h4 class="section-title">
          <span class="section-icon">🧪</span>
          Model Context
        </h4>
        <div class="suggestions-grid">
          <For each={suggestions()}>
            {(item) => (
              <div
                class={`context-item ${item.type}`}
                onClick={() => props.onInsert(item.expression)}
                title={`${item.type}: ${item.label}`}
                role="button"
                tabIndex={0}
                aria-label={`Insert ${item.type} ${item.label}`}
              >
                <div class="item-type">{item.type.charAt(0).toUpperCase()}</div>
                <div class="item-label">{item.label}</div>
              </div>
            )}
          </For>
        </div>
      </div>
    </Show>
  )
}

/**
 * Main ExpressionPalette component
 */
export const ExpressionPalette: Component<ExpressionPaletteProps> = (props) => {
  const [searchInput, setSearchInput] = createSignal('')

  // Controlled vs. uncontrolled is decided by a single condition: the presence
  // of `searchQuery` makes the palette controlled (the parent owns the value and
  // receives writes via `onSearchQueryChange`); otherwise it self-manages.
  const isControlled = () => props.searchQuery !== undefined
  const searchQuery = createMemo(() => (isControlled() ? (props.searchQuery ?? '') : searchInput()))

  // Filter templates based on search query
  const filteredTemplates = createMemo(() => {
    const query = searchQuery().toLowerCase().trim()
    if (!query) return EXPRESSION_TEMPLATES

    return EXPRESSION_TEMPLATES.filter((template) => {
      return (
        template.label.toLowerCase().includes(query) ||
        template.description.toLowerCase().includes(query) ||
        template.keywords.some((keyword) => keyword.toLowerCase().includes(query))
      )
    })
  })

  // Group templates by category
  const templatesByCategory = createMemo(() => {
    const groups: Record<string, ExpressionTemplate[]> = {}

    filteredTemplates().forEach((template) => {
      if (!groups[template.category]) {
        groups[template.category] = []
      }
      groups[template.category].push(template)
    })

    return groups
  })

  // Handle insertion of expressions
  const handleInsert = (expr: Expression) => {
    props.onInsertExpression?.(expr)

    // Close quick insert mode after selection
    if (props.quickInsertMode) {
      props.onCloseQuickInsert?.()
    }
  }

  // Handle search input changes (writes follow the same controlled-mode
  // condition as the read path above).
  const handleSearchChange = (value: string) => {
    if (isControlled()) {
      props.onSearchQueryChange?.(value)
    } else {
      setSearchInput(value)
    }
  }

  // Handle keyboard events in quick insert mode
  const handleKeyDown = (e: KeyboardEvent) => {
    if (props.quickInsertMode && e.key === 'Escape') {
      props.onCloseQuickInsert?.()
    }
  }

  const paletteClasses = () => {
    const classes = ['expression-palette']
    if (props.quickInsertMode) classes.push('quick-insert-mode')
    if (props.visible === false) classes.push('hidden')
    if (props.class) classes.push(props.class)
    return classes.join(' ')
  }

  return (
    <div class={paletteClasses()} onKeyDown={handleKeyDown}>
      {/* Search bar - always visible in quick insert mode, optional otherwise */}
      <Show when={props.quickInsertMode || searchQuery()}>
        <div class="palette-search">
          <input
            type="text"
            class="search-input"
            placeholder="Search expressions... (type '/' to open)"
            value={searchQuery()}
            onInput={(e) => handleSearchChange(e.currentTarget.value)}
            autofocus={props.quickInsertMode}
          />
        </div>
      </Show>

      <div class="palette-content">
        {/* Context-aware suggestions */}
        <Show when={!searchQuery()}>
          <ContextSuggestions model={props.currentModel} onInsert={handleInsert} />
        </Show>

        {/* Expression templates by category */}
        <For each={Object.entries(CATEGORY_CONFIG)}>
          {([categoryKey, categoryInfo]) => {
            const categoryTemplates = templatesByCategory()[categoryKey] || []

            return (
              <Show when={categoryTemplates.length > 0}>
                <div class="palette-section">
                  <h4 class="section-title">
                    <span class="section-icon">{categoryInfo.icon}</span>
                    {categoryInfo.title}
                  </h4>
                  <div class="templates-grid">
                    <For each={categoryTemplates}>
                      {(template) => <TemplateCard template={template} onInsert={handleInsert} />}
                    </For>
                  </div>
                </div>
              </Show>
            )
          }}
        </For>

        {/* No results message */}
        <Show when={searchQuery() && filteredTemplates().length === 0}>
          <div class="no-results">
            <div class="no-results-icon">🔍</div>
            <div class="no-results-text">No expressions found for "{searchQuery()}"</div>
            <div class="no-results-hint">Try searching for operators, functions, or keywords</div>
          </div>
        </Show>
      </div>

      {/* Help text for quick insert mode */}
      <Show when={props.quickInsertMode}>
        <div class="quick-insert-help">
          Press <kbd>Escape</kbd> to close, click or drag to insert
        </div>
      </Show>
    </div>
  )
}

export default ExpressionPalette
