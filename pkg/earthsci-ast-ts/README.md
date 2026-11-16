# EarthSci Toolkit - TypeScript Package

[![npm version](https://badge.fury.io/js/@earthsciml/ast.svg)](https://badge.fury.io/js/@earthsciml/ast)
[![Cross-Language Conformance Testing](https://github.com/EarthSciML/EarthSciAST/actions/workflows/conformance-testing.yml/badge.svg)](https://github.com/EarthSciML/EarthSciAST/actions/workflows/conformance-testing.yml)

TypeScript types and utilities for the **EarthSciML Abstract Syntax Tree Format**, providing complete type definitions, parsing, validation, and manipulation tools for scientific modeling data structures.

## Installation

```bash
npm install @earthsciml/ast
```

## Usage

### Basic Usage

```typescript
import { loadString, toJson, validate } from '@earthsciml/ast';

// Parse an ESM document from JSON text (`loadPath` reads a file).
const doc = loadString(`{
  "esm": "2.1.0",
  "metadata": { "name": "demo" },
  "models": {
    "Decay": {
      "variables": {
        "N": { "type": "unknown", "units": "1", "default": 1.0 },
        "k": { "type": "parameter", "units": "1/s", "default": 0.1 }
      },
      "equations": [
        { "lhs": { "op": "D", "args": ["N"], "wrt": "t" },
          "rhs": { "op": "*", "args": [-1, "k", "N"] } }
      ]
    }
  }
}`);

// Validate the document; problems are reported in the result, not thrown.
const result = validate(doc);
if (result.is_valid) {
  console.log('Valid ESM file!');
} else {
  console.error('Validation errors:', result.schema_errors, result.structural_errors);
}

// A `models` entry is a `Model`, or a `{ ref }` subsystem reference that
// loading had no file to resolve against; narrow before using it.
const model = doc.models!.Decay;
if ('ref' in model) throw new Error('unresolved subsystem reference');
console.log(Object.keys(model.variables)); // ["N", "k"]

// Serialize back to JSON text (`writePath` writes a file).
const json = toJson(doc);
```

### Working with Expressions

```typescript
import {
  expressionNames,
  freeVariables,
  parseMath,
  printMath,
  substitute,
} from '@earthsciml/ast';
import type { Expression } from '@earthsciml/ast';

// Show an expression as Typst or LaTeX math, with its names declared
const expr: Expression = { op: '+', args: ['x', { op: '^', args: ['y', 2] }] };
const names = expressionNames(expr); // ["x", "y"]
console.log(printMath(expr, names, 'typst'));    // "x + y^2"
console.log(printMath(expr, names, 'markdown')); // "x + y^{2}"

// Read math back: an expression, or an equation `{ lhs, rhs }` when the top is `=`
parseMath('x + y^2', ['x', 'y'], 'typst'); // the expression above
parseMath('y = 2 k', ['y', 'k'], 'typst'); // { lhs: "y", rhs: { op: "*", args: [2, "k"] } }

// Analyze expressions
const variables = freeVariables(expr); // Set { "x", "y" }

// Substitute expressions for variables
const substituted = substitute(expr, { x: 2, y: 't' });
// { op: "+", args: [2, { op: "^", args: ["t", 2] }] }
```

### Graph Analysis

```typescript
import { loadPath, componentGraph, componentExists, toMermaid } from '@earthsciml/ast';

const doc = loadPath('coupled.esm');

// Analyze component dependencies
const graph = componentGraph(doc);
console.log('Components:', graph.nodes.map((n) => n.id));
console.log('Coupling edges:', graph.edges.length);
console.log(toMermaid(graph));

// Check for component existence
if (componentExists(doc, 'Box')) {
  console.log('Found the Box model');
}
```

## Dual Package Support

This package supports both ESM and CommonJS environments:

### ESM (ECMAScript Modules)
```typescript
import { loadString, toJson, validate } from '@earthsciml/ast';
```

### CommonJS
```javascript
const { loadString, toJson, validate } = require('@earthsciml/ast');
```

## API Reference

The generated API reference (built by `tools/api_docs/typescript.sh` in [EarthSciML/earthsci.dev](https://github.com/EarthSciML/earthsci.dev) from
the doc comments) covers every export. The most common entry points:

### Core Functions

- **`loadString(json: string, options?: LoadOptions): EsmFile`** - Parse JSON text into an ESM document
- **`loadPath(path: string, options?: LoadOptions): EsmFile`** - Read and parse an `.esm` file, resolving subsystem references relative to it
- **`toJson(file: EsmFile, options?: ToJsonOptions): string`** - Serialize a document to JSON text
- **`writePath(file: EsmFile, path: string, options?: ToJsonOptions): void`** - Serialize a document to a file
- **`validate(document: EsmFile, options?: ValidateOptions): ValidationResult`** - Schema and structural validation of a loaded document
- **`validateText(text: string, options?: ValidateOptions): ValidationResult`** - The same, starting from JSON text

### Type System

The package provides complete TypeScript type definitions for:

- `EsmFile` - Root ESM file structure
- `Model` - Scientific model definition
- `Expression` - Mathematical expression trees
- `Reaction` - Chemical reaction specifications
- `CouplingEntry` - Model coupling definitions
- And many more...

### Expression Utilities

- **`printMath(expr, names: readonly string[], format: 'markdown' | 'typst'): string`** - Print an expression or an equation as LaTeX (`'markdown'`) or Typst math, under the declared `names`
- **`parseMath(text: string, names: readonly string[], format, options?): unknown`** - The inverse of `printMath`: read one expression, or one equation (`{ lhs, rhs }`), from LaTeX or Typst math; throws an `EsmDiagnosticError` (`parse_error`, or `removed_op` for an operator removed from the format)
- **`expressionNames(expr): string[]`** - The variable names an expression or equation uses, in order of first use: the `names` to give `printMath` to show it on its own
- **`printMarkdown` / `printTypst` / `parseMarkdown` / `parseTypst`** - A whole document as Markdown (LaTeX math) or Typst source, losslessly
- **`substitute(expr: Expression, bindings: Record<string, Expression>): Expression`** - Replace variables with expressions
- **`freeVariables(expr: Expression): Set<string>`** - Collect the variable names an expression references
- **`simplify(expr: Expression): Expression`** - Algebraic simplification

### Graph Analysis

- **`componentGraph(file: EsmFile): Graph<ComponentNode, CouplingEdge>`** - Build the component coupling graph
- **`componentExists(esmFile: EsmFile, componentId: string): boolean`** - Check component existence
- **`getComponentType(esmFile: EsmFile, componentId: string): ComponentNode['type'] | null`** - Get a component's type

## Development

### Building from Source

```bash
npm install
npm run build
```

This creates dual ESM/CommonJS builds in the `dist/` directory:
- `dist/esm/` - ESM build
- `dist/cjs/` - CommonJS build
- Type definitions in both directories

### Testing

```bash
npm test                    # Run unit tests (watch mode)
npm run test:ci             # Run unit tests once
npm run typecheck           # Strict TypeScript check
npm run lint                # ESLint
npm run format:check        # Prettier check
```

## Schema Version

This package implements ESM Format schema version **2.1.0** (exported as
`SCHEMA_VERSION`, derived from the embedded schema's `$id`).

## License

[License details to be added]

## Contributing

[Contributing guidelines to be added]