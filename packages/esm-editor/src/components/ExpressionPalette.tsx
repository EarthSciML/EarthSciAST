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

import { Component, createSignal, createMemo, For, Show } from 'solid-js';
import type { Expression, Model } from 'earthsci-toolkit';

export interface ExpressionPaletteProps {
  /** Current model for context-aware suggestions */
  currentModel?: Model;

  /** Callback when an expression template is inserted */
  onInsertExpression?: (expr: Expression) => void;

  /** Whether the palette is visible */
  visible?: boolean;

  /** CSS class for styling */
  class?: string;

  /** Quick insert mode (triggered by '/' shortcut) */
  quickInsertMode?: boolean;

  /** Search query for filtering expressions */
  searchQuery?: string;

  /** Callback when search query changes */
  onSearchQueryChange?: (query: string) => void;

  /** Callback when quick insert mode should be closed */
  onCloseQuickInsert?: () => void;
}

// Expression template definitions
interface ExpressionTemplate {
  id: string;
  label: string;
  description: string;
  expression: Expression;
  keywords: string[];
  category: 'calculus' | 'arithmetic' | 'functions' | 'logic';
}

// Predefined expression templates
const EXPRESSION_TEMPLATES: ExpressionTemplate[] = [
  // Calculus operators
  {
    id: 'derivative',
    label: 'D(_, t)',
    description: 'Time derivative',
    expression: { op: 'D', args: ['_placeholder_', 't'] },
    keywords: ['derivative', 'time', 'differential', 'd', 'dt'],
    category: 'calculus'
  },
  {
    id: 'gradient',
    label: 'grad(_, x)',
    description: 'Spatial gradient',
    expression: { op: 'grad', args: ['_placeholder_', 'x'] },
    keywords: ['gradient', 'spatial', 'grad', 'nabla'],
    category: 'calculus'
  },
  {
    id: 'divergence',
    label: 'div(_)',
    description: 'Divergence operator',
    expression: { op: 'div', args: ['_placeholder_'] },
    keywords: ['divergence', 'div'],
    category: 'calculus'
  },
  {
    id: 'laplacian',
    label: 'laplacian(_)',
    description: 'Laplacian operator',
    expression: { op: 'laplacian', args: ['_placeholder_'] },
    keywords: ['laplacian', 'laplace', 'del2'],
    category: 'calculus'
  },

  // Arithmetic operators
  {
    id: 'addition',
    label: '_ + _',
    description: 'Addition',
    expression: { op: '+', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['add', 'addition', 'plus', '+'],
    category: 'arithmetic'
  },
  {
    id: 'subtraction',
    label: '_ - _',
    description: 'Subtraction',
    expression: { op: '-', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['subtract', 'subtraction', 'minus', '-'],
    category: 'arithmetic'
  },
  {
    id: 'multiplication',
    label: '_ * _',
    description: 'Multiplication',
    expression: { op: '*', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['multiply', 'multiplication', 'times', '*'],
    category: 'arithmetic'
  },
  {
    id: 'division',
    label: '_ / _',
    description: 'Division',
    expression: { op: '/', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['divide', 'division', 'over', '/'],
    category: 'arithmetic'
  },
  {
    id: 'power',
    label: '_ ^ _',
    description: 'Power/Exponentiation',
    expression: { op: '^', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['power', 'exponent', 'exp', '^', '**'],
    category: 'arithmetic'
  },
  {
    id: 'negate',
    label: '-_',
    description: 'Unary negation',
    expression: { op: '-', args: ['_placeholder_'] },
    keywords: ['negate', 'negative', 'unary', 'minus'],
    category: 'arithmetic'
  },

  // Mathematical functions
  {
    id: 'exponential',
    label: 'exp(_)',
    description: 'Exponential function (e^x)',
    expression: { op: 'exp', args: ['_placeholder_'] },
    keywords: ['exponential', 'exp', 'e'],
    category: 'functions'
  },
  {
    id: 'logarithm',
    label: 'log(_)',
    description: 'Natural logarithm',
    expression: { op: 'log', args: ['_placeholder_'] },
    keywords: ['logarithm', 'log', 'ln', 'natural'],
    category: 'functions'
  },
  {
    id: 'sqrt',
    label: 'sqrt(_)',
    description: 'Square root',
    expression: { op: 'sqrt', args: ['_placeholder_'] },
    keywords: ['sqrt', 'square', 'root'],
    category: 'functions'
  },
  {
    id: 'absolute',
    label: 'abs(_)',
    description: 'Absolute value',
    expression: { op: 'abs', args: ['_placeholder_'] },
    keywords: ['absolute', 'abs', 'magnitude'],
    category: 'functions'
  },
  {
    id: 'sine',
    label: 'sin(_)',
    description: 'Sine function',
    expression: { op: 'sin', args: ['_placeholder_'] },
    keywords: ['sine', 'sin', 'trigonometry'],
    category: 'functions'
  },
  {
    id: 'cosine',
    label: 'cos(_)',
    description: 'Cosine function',
    expression: { op: 'cos', args: ['_placeholder_'] },
    keywords: ['cosine', 'cos', 'trigonometry'],
    category: 'functions'
  },
  {
    id: 'minimum',
    label: 'min(_, _)',
    description: 'Minimum of two values',
    expression: { op: 'min', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['minimum', 'min', 'smaller'],
    category: 'functions'
  },
  {
    id: 'maximum',
    label: 'max(_, _)',
    description: 'Maximum of two values',
    expression: { op: 'max', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['maximum', 'max', 'larger'],
    category: 'functions'
  },

  // Logical operators
  {
    id: 'ifelse',
    label: 'ifelse(_, _, _)',
    description: 'Conditional expression',
    expression: { op: 'ifelse', args: ['_placeholder_', '_placeholder_', '_placeholder_'] },
    keywords: ['if', 'ifelse', 'conditional', 'ternary'],
    category: 'logic'
  },
  {
    id: 'greater_than',
    label: '_ > _',
    description: 'Greater than comparison',
    expression: { op: '>', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['greater', 'than', '>', 'compare'],
    category: 'logic'
  },
  {
    id: 'less_than',
    label: '_ < _',
    description: 'Less than comparison',
    expression: { op: '<', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['less', 'than', '<', 'compare'],
    category: 'logic'
  },
  {
    id: 'equals',
    label: '_ == _',
    description: 'Equality comparison',
    expression: { op: '==', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['equals', 'equal', '==', 'compare'],
    category: 'logic'
  },
  {
    id: 'logical_and',
    label: '_ && _',
    description: 'Logical AND',
    expression: { op: 'and', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['and', 'logical', '&&', 'both'],
    category: 'logic'
  },
  {
    id: 'logical_or',
    label: '_ || _',
    description: 'Logical OR',
    expression: { op: 'or', args: ['_placeholder_', '_placeholder_'] },
    keywords: ['or', 'logical', '||', 'either'],
    category: 'logic'
  },
  {
    id: 'logical_not',
    label: '!_',
    description: 'Logical NOT',
    expression: { op: 'not', args: ['_placeholder_'] },
    keywords: ['not', 'logical', '!', 'negate'],
    category: 'logic'
  }
];

// Category display configuration
const CATEGORY_CONFIG = {
  calculus: {
    title: 'Calculus',
    description: 'Differential operators',
    icon: '∂'
  },
  arithmetic: {
    title: 'Arithmetic',
    description: 'Basic mathematical operations',
    icon: '±'
  },
  functions: {
    title: 'Functions',
    description: 'Mathematical functions',
    icon: 'ƒ'
  },
  logic: {
    title: 'Logic',
    description: 'Logical operators and comparisons',
    icon: '∧'
  }
};

/**
 * Component for individual draggable expression template
 */
const ExpressionTemplate: Component<{
  template: ExpressionTemplate;
  onInsert: (expr: Expression) => void;
}> = (props) => {
  const [isDragging, setIsDragging] = createSignal(false);

  const handleDragStart = (e: DragEvent) => {
    if (e.dataTransfer) {
      e.dataTransfer.effectAllowed = 'copy';
      e.dataTransfer.setData('application/json', JSON.stringify({
        type: 'expression-template',
        expression: props.template.expression,
        templateId: props.template.id
      }));
    }
    setIsDragging(true);
  };

  const handleDragEnd = () => {
    setIsDragging(false);
  };

  const handleClick = () => {
    props.onInsert(props.template.expression);
  };

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
  );
};

/**
 * Component for context-aware suggestions from current model
 */
const ContextSuggestions: Component<{
  model?: Model;
  onInsert: (expr: Expression) => void;
}> = (props) => {
  const suggestions = createMemo(() => {
    if (!props.model) return [];

    const items: { label: string; expression: Expression; type: 'species' | 'variable' | 'parameter' }[] = [];

    // Add model variables (keyed by name in the ESM schema)
    if (props.model.variables) {
      Object.entries(props.model.variables).forEach(([name, variable]) => {
        items.push({
          label: name,
          expression: name,
          type: variable.type === 'parameter' ? 'parameter' : 'variable'
        });
      });
    }

    return items;
  });

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
  );
};

/**
 * Main ExpressionPalette component
 */
export const ExpressionPalette: Component<ExpressionPaletteProps> = (props) => {
  const [searchInput, setSearchInput] = createSignal('');

  // Use external search query if provided, otherwise use internal
  const searchQuery = createMemo(() => props.searchQuery || searchInput());

  // Filter templates based on search query
  const filteredTemplates = createMemo(() => {
    const query = searchQuery().toLowerCase().trim();
    if (!query) return EXPRESSION_TEMPLATES;

    return EXPRESSION_TEMPLATES.filter(template => {
      return template.label.toLowerCase().includes(query) ||
             template.description.toLowerCase().includes(query) ||
             template.keywords.some(keyword => keyword.toLowerCase().includes(query));
    });
  });

  // Group templates by category
  const templatesByCategory = createMemo(() => {
    const groups: Record<string, ExpressionTemplate[]> = {};

    filteredTemplates().forEach(template => {
      if (!groups[template.category]) {
        groups[template.category] = [];
      }
      groups[template.category].push(template);
    });

    return groups;
  });

  // Handle insertion of expressions
  const handleInsert = (expr: Expression) => {
    props.onInsertExpression?.(expr);

    // Close quick insert mode after selection
    if (props.quickInsertMode) {
      props.onCloseQuickInsert?.();
    }
  };

  // Handle search input changes
  const handleSearchChange = (value: string) => {
    if (props.onSearchQueryChange) {
      props.onSearchQueryChange(value);
    } else {
      setSearchInput(value);
    }
  };

  // Handle keyboard events in quick insert mode
  const handleKeyDown = (e: KeyboardEvent) => {
    if (props.quickInsertMode && e.key === 'Escape') {
      props.onCloseQuickInsert?.();
    }
  };

  const paletteClasses = () => {
    const classes = ['expression-palette'];
    if (props.quickInsertMode) classes.push('quick-insert-mode');
    if (props.visible === false) classes.push('hidden');
    if (props.class) classes.push(props.class);
    return classes.join(' ');
  };

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
          <ContextSuggestions
            model={props.currentModel}
            onInsert={handleInsert}
          />
        </Show>

        {/* Expression templates by category */}
        <For each={Object.entries(CATEGORY_CONFIG)}>
          {([categoryKey, categoryInfo]) => {
            const categoryTemplates = templatesByCategory()[categoryKey] || [];

            return (
              <Show when={categoryTemplates.length > 0}>
                <div class="palette-section">
                  <h4 class="section-title">
                    <span class="section-icon">{categoryInfo.icon}</span>
                    {categoryInfo.title}
                  </h4>
                  <div class="templates-grid">
                    <For each={categoryTemplates}>
                      {(template) => (
                        <ExpressionTemplate
                          template={template}
                          onInsert={handleInsert}
                        />
                      )}
                    </For>
                  </div>
                </div>
              </Show>
            );
          }}
        </For>

        {/* No results message */}
        <Show when={searchQuery() && filteredTemplates().length === 0}>
          <div class="no-results">
            <div class="no-results-icon">🔍</div>
            <div class="no-results-text">
              No expressions found for "{searchQuery()}"
            </div>
            <div class="no-results-hint">
              Try searching for operators, functions, or keywords
            </div>
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
  );
};

export default ExpressionPalette;