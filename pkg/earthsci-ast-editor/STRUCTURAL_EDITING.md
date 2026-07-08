# Structural Editing Operations

This document describes the structural editing capabilities added to the earthsci-ast-editor package.

## Overview

The structural editing system provides powerful AST manipulation operations that allow users to modify expression structure beyond simple text editing. All operations maintain the integrity of the ESM format and provide granular reactivity through path-based updates.

## Core Operations

### 1. Replace
- **Purpose**: Replace a selected node entirely with a new expression
- **Usage**: Select any node, then use the replace operation with a new expression
- **Example**: Replace `5` with `sin(x)` in the expression `2 + 5`

### 2. Wrap
- **Purpose**: Wrap a selected node in an operator
- **Available Operators**:
  - Unary: `-` (negate), `abs`, `sqrt`, `exp`, `log`, `sin`, `cos`
  - Binary: `+`, `*`, `/`, `^`
- **Usage**: Select a node, choose an operator from the context menu
- **Example**: Select `O3`, choose 'negate' → `{op: '-', args: ['O3']}`

### 3. Unwrap
- **Purpose**: Replace a unary operation with its argument
- **Conditions**: Only works on unary operations (single argument)
- **Usage**: Right-click on a unary operation, select "Unwrap"
- **Example**: `sin(x)` → `x`

### 4. Delete Term
- **Purpose**: Remove an argument from commutative operations
- **Conditions**: Only works on arguments of `+` or `*` operations
- **Behavior**:
  - 3+ args: Remove the selected arg
  - 2 args: Replace parent with the remaining arg
- **Example**: `a + b + c` → delete `b` → `a + c`

### 5. Drag-and-Drop Reordering
- **Purpose**: Reorder arguments in commutative operations
- **Supported Operations**: `+` (addition), `*` (multiplication)
- **Usage**: Drag arguments to new positions using HTML5 drag API
- **Visual Feedback**: Drag indicators and drop zones

## Architecture

### Context Providers

```tsx
<StructuralEditingProvider rootExpression={expr} onRootReplace={setExpr}>
  <ExpressionNode ... />
</StructuralEditingProvider>
```

### Key Components

- **StructuralEditingProvider**: Context provider for all structural operations
- **StructuralEditingMenu**: Right-click context menu for operations
- **DraggableExpression**: Wrapper for drag-and-drop functionality

### Integration with ExpressionNode

The `ExpressionNode` component now supports:
- Right-click context menus for structural operations
- Visual selection state
- Drag-and-drop for commutative operations
- Automatic operation availability detection

## Usage Examples

### Basic Setup

```tsx
import {
  StructuralEditingProvider,
  useStructuralEditingContext,
  ExpressionNode
} from 'earthsci-ast-editor';

function MyEditor() {
  const [expr, setExpr] = createSignal(myExpression);

  return (
    <StructuralEditingProvider
      rootExpression={expr}
      onRootReplace={setExpr}
    >
      <ExpressionNode
        expr={expr()}
        path={[]}
        // ... other props
      />
    </StructuralEditingProvider>
  );
}
```

### Programmatic Operations

```tsx
function MyComponent() {
  const structural = useStructuralEditingContext();

  // Wrap a node in sin()
  structural.wrapNode(['args', 0], 'sin');

  // Unwrap a unary operation
  structural.unwrapNode(['args', 1]);

  // Delete a term
  structural.deleteTerm(['args', 2]);

  // Reorder arguments
  structural.reorderArgs([], 0, 2); // Move first arg to third position
}
```

## CSS Styling

Include the structural editing styles:

```tsx
import 'earthsci-ast-editor/src/styles/structural-editing.css';
```

Key CSS classes:
- `.esm-expression-node.selected` - Selected node styling
- `.draggable-expression` - Draggable wrapper
- `.structural-editing-menu` - Context menu styling

## Testing

The implementation includes comprehensive tests:
- **Unit Tests**: 25 tests for structural operations
- **Integration Tests**: Component integration scenarios
- **Edge Cases**: Invalid operations, error handling

Run tests with:
```bash
npm test
```

## Accessibility

All structural editing operations support:
- Keyboard navigation
- Screen reader compatibility
- High contrast mode
- Focus management
- ARIA labels and descriptions

## Performance

The system is optimized for:
- Large expression trees
- Frequent updates
- Real-time drag operations
- Memory efficiency through path-based updates

## Future Enhancements

Potential future additions:
- Custom operator definitions
- Macro operations (e.g., distribute, factor)
- Undo/redo integration
- Multi-node selection
- Advanced drag behaviors (snapping, constraints)