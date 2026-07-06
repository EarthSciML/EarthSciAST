# EarthSci Toolkit - TypeScript Package

[![npm version](https://badge.fury.io/js/earthsci-toolkit.svg)](https://badge.fury.io/js/earthsci-toolkit)
[![Cross-Language Conformance Testing](https://github.com/EarthSciML/EarthSciSerialization/actions/workflows/conformance-testing.yml/badge.svg)](https://github.com/EarthSciML/EarthSciSerialization/actions/workflows/conformance-testing.yml)

TypeScript types and utilities for the **EarthSciML Serialization Format**, providing complete type definitions, parsing, validation, and manipulation tools for scientific modeling data structures.

## Installation

```bash
npm install earthsci-toolkit
```

## Usage

### Basic Usage

```typescript
import { EsmFile, Model, load, save, validate } from 'earthsci-toolkit';

// Parse ESM file from JSON
const esmFile = load('{"esm": "0.8.0", "metadata": {"name": "demo"}, "models": {...}}');

// Create a new model
const model: Model = {
  variables: {
    x: { type: 'state', default: 1.0 },
    k: { type: 'parameter', default: 0.1 },
  },
  equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: { op: '*', args: [-1, 'k', 'x'] } }],
};

// Validate an ESM structure
const result = validate(esmFile);
if (result.is_valid) {
  console.log("Valid ESM file!");
} else {
  console.error("Validation errors:", result.schema_errors, result.structural_errors);
}

// Serialize back to JSON
const jsonString = save(esmFile);
```

### Working with Expressions

```typescript
import { toUnicode, toLatex, substitute, freeVariables } from 'earthsci-toolkit';

// Pretty-print mathematical expressions
const expr = { op: "+", args: ["x", { op: "^", args: ["y", "2"] }] };
console.log(toUnicode(expr)); // "x + y²"
console.log(toLatex(expr));   // "x + y^{2}"

// Analyze expressions
const variables = freeVariables(expr); // ["x", "y"]

// Substitute values
const substituted = substitute(expr, { x: "2", y: "t" });
// Result: { op: "+", args: ["2", { op: "^", args: ["t", "2"] }] }
```

### Graph Analysis

```typescript
import { component_graph, componentExists } from 'earthsci-toolkit';

// Analyze component dependencies
const graph = component_graph(esmFile);
console.log("Components:", graph.nodes.map(n => n.name));
console.log("Coupling edges:", graph.edges.length);

// Check for component existence
if (componentExists(esmFile, "atmospheric_chemistry")) {
  console.log("Found atmospheric chemistry model");
}
```

## Dual Package Support

This package supports both ESM and CommonJS environments:

### ESM (ECMAScript Modules)
```typescript
import { load, save, validate } from 'earthsci-toolkit';
```

### CommonJS
```javascript
const { load, save, validate } = require('earthsci-toolkit');
```

## API Reference

### Core Functions

- **`load(input: string | object): EsmFile`** - Parse JSON string or object into ESM structure
- **`save(esmFile: EsmFile): string`** - Serialize ESM structure to formatted JSON
- **`validate(esmFile: EsmFile): ValidationResult`** - Validate ESM structure against schema

### Type System

The package provides complete TypeScript type definitions for:

- `EsmFile` - Root ESM file structure
- `Model` - Scientific model definition
- `Expression` - Mathematical expression trees
- `Reaction` - Chemical reaction specifications
- `CouplingEntry` - Model coupling definitions
- And many more...

### Expression Utilities

- **`toUnicode(expr: Expression): string`** - Render as Unicode mathematical notation
- **`toLatex(expr: Expression): string`** - Render as LaTeX mathematical notation
- **`toAscii(expr: Expression): string`** - Render as plain ASCII text
- **`substitute(expr: Expression, substitutions: Record<string, string>): Expression`** - Variable substitution
- **`freeVariables(expr: Expression): string[]`** - Extract variable names
- **`simplify(expr: Expression): Expression`** - Algebraic simplification

### Graph Analysis

- **`component_graph(esmFile: EsmFile): ComponentGraph`** - Build dependency graph
- **`componentExists(esmFile: EsmFile, name: string): boolean`** - Check component existence
- **`getComponentType(esmFile: EsmFile, name: string): string`** - Get component type

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

This package supports ESM Format schema version **0.8.0** (exported as
`SCHEMA_VERSION`, derived from the embedded schema's `$id`).

## License

[License details to be added]

## Contributing

[Contributing guidelines to be added]