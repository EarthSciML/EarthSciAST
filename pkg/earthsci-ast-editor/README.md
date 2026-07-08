# ESM Editor

Interactive SolidJS editor for EarthSciML Serialization Format expressions.

## Features

- **ExpressionNode**: Core component for rendering interactive AST nodes
  - Number literals with click-to-select and hover highlighting
  - Variable references with chemical subscript rendering (e.g., CO₂, H₂O)
  - Operator nodes that dispatch to layout components
  - Full keyboard accessibility support
  - Reactive updates via SolidJS stores

## Installation

```bash
npm install earthsci-ast-editor
```

## Usage

```tsx
import { ExpressionNode } from 'earthsci-ast-editor';
import { createSignal } from 'solid-js';

function MyEditor() {
  const [highlightedVars, setHighlightedVars] = createSignal(new Set<string>());

  return (
    <ExpressionNode
      expr={myExpression}
      path={[]}
      highlightedVars={highlightedVars}
      onHoverVar={(name) => name ? setHighlightedVars(new Set([name])) : setHighlightedVars(new Set())}
      onSelect={(path) => console.log('Selected:', path)}
      onReplace={(path, newExpr) => console.log('Replace:', path, newExpr)}
    />
  );
}
```

## Development

```bash
# Install dependencies
npm install

# Run tests
npm test

# Build package
npm run build

# Development mode
npm run dev
```

## API

### ExpressionNode

Core component for rendering interactive AST nodes.

#### Props

- `expr: Expression` - The expression to render (reactive)
- `path: (string | number)[]` - AST path for unique identification
- `highlightedVars: Accessor<Set<string>>` - Currently highlighted variables
- `onHoverVar: (name: string | null) => void` - Hover callback
- `onSelect: (path: (string | number)[]) => void` - Selection callback
- `onReplace: (path: (string | number)[], newExpr: Expression) => void` - Replace callback

## CSS Classes

The component uses these CSS classes for styling:

- `.esm-expression-node` - Base node class
- `.esm-num` - Number literals
- `.esm-var` - Variable references
- `.esm-operator-layout` - Operator containers
- `.highlighted` - Highlighted state
- `.hovered` - Hovered state

## License

MIT