# Getting Started with ESM Format in TypeScript/JavaScript

The TypeScript implementation provides excellent web integration, interactive editing components, and comprehensive type safety for browser and Node.js applications.

## Installation

### NPM
```bash
npm install @earthsciml/ast
```

### Yarn
```bash
yarn add @earthsciml/ast
```

### CDN (Browser)
```html
<script type="module">
  import { load, validate, toUnicode } from 'https://unpkg.com/@earthsciml/ast/dist/esm/index.js';
</script>
```

## Core Capabilities

The TypeScript implementation provides **Interactive** tier capabilities:
- ✅ Parse, serialize, validate ESM files
- ✅ Complete TypeScript type definitions
- ✅ Mathematical expression manipulation
- ✅ Pretty-printing (Unicode, LaTeX, ASCII)
- ✅ Interactive editing components (SolidJS)
- ✅ Web component export
- ✅ Browser and Node.js support

## Basic Usage

### Loading and Parsing ESM Files

```typescript
import { load, save, validate, type EsmFile } from '@earthsciml/ast';
import fs from 'fs';

// Load from file (Node.js)
const jsonString = fs.readFileSync('model.esm', 'utf8');
const esmFile: EsmFile = load(jsonString);
console.log('Loaded:', esmFile.metadata.name);

// Load from object
const esmFile2 = load({
  esm: "0.1.0",
  metadata: {
    name: "Test Model",
    author: "Developer"
  }
});

// Validate loaded file
const result = validate(esmFile);
if (result.isValid) {
  console.log('✓ Valid ESM file');
} else {
  result.errors.forEach(error => {
    console.error(`✗ ${error.path}: ${error.message}`);
  });
}

// Save back to JSON
const jsonOutput = save(esmFile);
```

### Working with Expressions

```typescript
import { toUnicode, toLatex, toAscii, substitute, freeVariables, type Expression } from '@earthsciml/ast';

// Define mathematical expression
const expr: Expression = {
  op: '+',
  args: [
    'x',
    { op: '^', args: ['y', '2'] }
  ]
};

// Pretty-print in different formats
console.log('Unicode:', toUnicode(expr));    // x + y²
console.log('LaTeX:', toLatex(expr));        // x + y^{2}
console.log('ASCII:', toAscii(expr));        // x + y^2

// Analyze expression
const variables = freeVariables(expr);       // ['x', 'y']
console.log('Free variables:', variables);

// Substitute values
const substituted = substitute(expr, { x: '2', y: 't' });
console.log('Substituted:', toUnicode(substituted)); // 2 + t²
```

## Type System

The package provides comprehensive TypeScript definitions:

```typescript
import type {
  EsmFile,
  Model,
  ModelVariable,
  ModelEquation,
  Expression,
  CouplingEntry,
  ValidationResult
} from '@earthsciml/ast';

// Type-safe model construction
const model: Model = {
  name: 'atmospheric_chemistry',
  variables: [
    {
      name: 'O3',
      type: 'state',
      units: 'molec/cm^3',
      description: 'Ozone concentration',
      initial_value: '1e12'
    }
  ],
  equations: [
    {
      lhs: 'O3',
      rhs: { op: '*', args: ['-k', 'O3'] },
      description: 'First-order decay'
    }
  ]
};

// Type-safe ESM file
const esmFile: EsmFile = {
  esm: '0.1.0',
  metadata: {
    name: 'My Model',
    description: 'TypeScript-created model',
    author: 'Developer',
    created: new Date().toISOString().split('T')[0]
  },
  models: {
    atmosphere: model
  }
};
```

## Web Application Integration

### React Integration
```tsx
import React, { useState, useEffect } from 'react';
import { load, validate, toUnicode } from '@earthsciml/ast';

const ModelViewer: React.FC<{ esmData: string }> = ({ esmData }) => {
  const [esmFile, setEsmFile] = useState(null);
  const [errors, setErrors] = useState([]);

  useEffect(() => {
    try {
      const parsed = load(esmData);
      const validation = validate(parsed);

      if (validation.isValid) {
        setEsmFile(parsed);
        setErrors([]);
      } else {
        setErrors(validation.errors);
      }
    } catch (e) {
      setErrors([{ message: e.message, path: 'root' }]);
    }
  }, [esmData]);

  if (errors.length > 0) {
    return (
      <div className="error-panel">
        <h3>Validation Errors:</h3>
        {errors.map((error, idx) => (
          <div key={idx} className="error">
            <strong>{error.path}:</strong> {error.message}
          </div>
        ))}
      </div>
    );
  }

  return (
    <div className="model-viewer">
      <h2>{esmFile?.metadata.name}</h2>
      <p>{esmFile?.metadata.description}</p>

      {Object.entries(esmFile?.models || {}).map(([name, model]) => (
        <div key={name} className="model-section">
          <h3>Model: {model.name}</h3>

          <h4>Equations:</h4>
          {model.equations?.map((eq, idx) => (
            <div key={idx} className="equation">
              <strong>{eq.lhs}</strong> = {toUnicode(eq.rhs)}
              {eq.description && <em> ({eq.description})</em>}
            </div>
          ))}
        </div>
      ))}
    </div>
  );
};
```

### Vue.js Integration
```vue
<template>
  <div class="esm-model-viewer">
    <h2>{{ esmFile?.metadata.name }}</h2>
    <div v-for="error in validationErrors" :key="error.path" class="error">
      {{ error.path }}: {{ error.message }}
    </div>

    <div v-for="(model, name) in esmFile?.models" :key="name">
      <h3>{{ model.name }}</h3>
      <div v-for="equation in model.equations" :key="equation.lhs" class="equation">
        {{ equation.lhs }} = {{ formatExpression(equation.rhs) }}
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue';
import { load, validate, toUnicode, type EsmFile } from '@earthsciml/ast';

const props = defineProps<{ esmData: string }>();

const esmFile = ref<EsmFile | null>(null);
const validationErrors = ref([]);

const loadModel = () => {
  try {
    const parsed = load(props.esmData);
    const validation = validate(parsed);

    if (validation.isValid) {
      esmFile.value = parsed;
      validationErrors.value = [];
    } else {
      validationErrors.value = validation.errors;
    }
  } catch (e) {
    validationErrors.value = [{ path: 'root', message: e.message }];
  }
};

const formatExpression = (expr) => toUnicode(expr);

watch(() => props.esmData, loadModel, { immediate: true });
</script>
```

## Interactive Components (SolidJS)

The package includes interactive editing components built with SolidJS:

```typescript
import { ExpressionEditor, ModelEditor } from '@earthsciml/ast/interactive';

// Use as SolidJS components
function App() {
  const [expression, setExpression] = createSignal({ op: '+', args: ['x', 'y'] });

  return (
    <div>
      <ExpressionEditor
        value={expression()}
        onChange={setExpression}
        showUnicode={true}
        showLatex={true}
      />

      <ModelEditor
        model={model()}
        onChange={setModel}
        enableValidation={true}
      />
    </div>
  );
}
```

## Web Components

Export as standard HTML custom elements for use in any framework:

```typescript
import '@earthsciml/ast/web-components';

// Use in HTML
// <esm-expression-editor value='{"op": "+", "args": ["x", "y"]}'></esm-expression-editor>
// <esm-model-editor model-data="..."></esm-model-editor>
```

```html
<!-- Pure HTML usage -->
<!DOCTYPE html>
<html>
<head>
  <script type="module" src="@earthsciml/ast/web-components.js"></script>
</head>
<body>
  <esm-expression-editor
    value='{"op": "+", "args": ["x", "y"]}'
    show-unicode="true"
    show-latex="true">
  </esm-expression-editor>

  <esm-model-editor
    model-data='{"name": "test", "variables": [], "equations": []}'>
  </esm-model-editor>

  <script>
    // Listen for changes
    document.querySelector('esm-expression-editor')
      .addEventListener('change', (e) => {
        console.log('Expression changed:', e.detail.expression);
      });
  </script>
</body>
</html>
```

## Node.js Server Applications

### Express.js API
```typescript
import express from 'express';
import { load, validate, save } from '@earthsciml/ast';

const app = express();
app.use(express.json());

// Validation endpoint
app.post('/api/validate', (req, res) => {
  try {
    const esmFile = load(req.body);
    const result = validate(esmFile);

    res.json({
      valid: result.isValid,
      errors: result.errors
    });
  } catch (error) {
    res.status(400).json({
      valid: false,
      errors: [{ path: 'root', message: error.message }]
    });
  }
});

// Model conversion endpoint
app.post('/api/convert', (req, res) => {
  try {
    const esmFile = load(req.body);
    const jsonOutput = save(esmFile, { pretty: true });

    res.setHeader('Content-Type', 'application/json');
    res.send(jsonOutput);
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

app.listen(3000, () => {
  console.log('ESM server running on port 3000');
});
```

### Next.js API Routes
```typescript
// pages/api/models/[id].ts
import type { NextApiRequest, NextApiResponse } from 'next';
import { load, validate, save } from '@earthsciml/ast';

export default function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method === 'POST') {
    try {
      const esmFile = load(req.body);
      const validation = validate(esmFile);

      if (!validation.isValid) {
        return res.status(400).json({ errors: validation.errors });
      }

      // Save to database or file system
      const modelId = req.query.id as string;
      const jsonString = save(esmFile);

      // ... save logic ...

      res.json({ success: true, modelId });
    } catch (error) {
      res.status(500).json({ error: error.message });
    }
  }
}
```

## Performance Optimization

### Lazy Loading
```typescript
// Dynamically import heavy components
const ModelEditor = lazy(() => import('@earthsciml/ast/interactive').then(m => ({ default: m.ModelEditor })));

// Use in React with Suspense
<Suspense fallback={<div>Loading model editor...</div>}>
  <ModelEditor model={model} />
</Suspense>
```

### Web Workers
```typescript
// worker.ts
import { validate, load } from '@earthsciml/ast';

self.onmessage = (e) => {
  const { type, data } = e.data;

  if (type === 'validate') {
    try {
      const esmFile = load(data);
      const result = validate(esmFile);
      self.postMessage({ type: 'validation-result', result });
    } catch (error) {
      self.postMessage({ type: 'error', error: error.message });
    }
  }
};

// main.ts
const worker = new Worker('worker.js');
worker.postMessage({ type: 'validate', data: esmData });
worker.onmessage = (e) => {
  if (e.data.type === 'validation-result') {
    console.log('Validation result:', e.data.result);
  }
};
```

## Testing

### Jest Testing
```typescript
import { load, validate, toUnicode } from '@earthsciml/ast';

describe('ESM Format', () => {
  test('loads valid ESM file', () => {
    const esmData = {
      esm: '0.1.0',
      metadata: { name: 'Test' }
    };

    const esmFile = load(esmData);
    expect(esmFile.metadata.name).toBe('Test');
  });

  test('validates model structure', () => {
    const esmFile = load(validEsmData);
    const result = validate(esmFile);

    expect(result.isValid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });

  test('pretty-prints expressions', () => {
    const expr = { op: '+', args: ['x', 'y'] };
    const unicode = toUnicode(expr);

    expect(unicode).toBe('x + y');
  });
});
```

### Playwright E2E Testing
```typescript
import { test, expect } from '@playwright/test';

test('interactive model editor', async ({ page }) => {
  await page.goto('/model-editor');

  // Load model
  await page.fill('[data-testid="esm-input"]', JSON.stringify(testModel));
  await page.click('[data-testid="load-button"]');

  // Verify model loaded
  await expect(page.locator('[data-testid="model-name"]')).toHaveText('Test Model');

  // Edit expression
  await page.click('[data-testid="equation-0"]');
  await page.fill('[data-testid="expression-editor"]', '{"op": "*", "args": ["k", "x"]}');

  // Verify expression updated
  await expect(page.locator('[data-testid="equation-display-0"]')).toContainText('k⋅x');
});
```

## Common Patterns

### Model Builder Pattern
```typescript
class ModelBuilder {
  private model: Partial<Model> = {};

  name(name: string) {
    this.model.name = name;
    return this;
  }

  addVariable(variable: ModelVariable) {
    this.model.variables = [...(this.model.variables || []), variable];
    return this;
  }

  addEquation(equation: ModelEquation) {
    this.model.equations = [...(this.model.equations || []), equation];
    return this;
  }

  build(): Model {
    return this.model as Model;
  }
}

// Usage
const model = new ModelBuilder()
  .name('atmospheric_chemistry')
  .addVariable({
    name: 'O3',
    type: 'state',
    units: 'molec/cm^3'
  })
  .addEquation({
    lhs: 'O3',
    rhs: { op: '*', args: ['-k', 'O3'] }
  })
  .build();
```

### Expression Builder
```typescript
class ExpressionBuilder {
  static add(...args: (string | Expression)[]): Expression {
    return { op: '+', args };
  }

  static multiply(...args: (string | Expression)[]): Expression {
    return { op: '*', args };
  }

  static power(base: string | Expression, exp: string | Expression): Expression {
    return { op: '^', args: [base, exp] };
  }
}

// Usage
const expr = ExpressionBuilder.add(
  'x',
  ExpressionBuilder.multiply('k',
    ExpressionBuilder.power('y', '2')
  )
);
// Results in: x + k * y^2
```

## Next Steps

- **Interactive Development** — Explore the [earthsci-ast-editor package](https://github.com/EarthSciML/EarthSciAST/tree/main/pkg/earthsci-ast-editor) (SolidJS interactive components)
- **Web Integration** — See the [examples directory](../examples/) for web application patterns
- **Reference** — Browse the [TypeScript API Reference](../api/typescript/)

Ready to build interactive model editors? Browse the [examples](../examples/) and the [earthsci-ast-editor source](https://github.com/EarthSciML/EarthSciAST/tree/main/pkg/earthsci-ast-editor).