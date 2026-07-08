# ESM Editor E2E Tests

This directory contains comprehensive End-to-End (E2E) tests for the SolidJS ESM Editor web components.

## Test Files

### 1. `expression_editing_e2e.test.js`

Tests for interactive expression editing capabilities:

- **Expression Editor Web Component**: Tests rendering, attribute handling, and event emission
- **Live Validation During Expression Editing**: Real-time validation feedback as users type
- **Variable Hover Highlighting**: Cross-coupling variable highlighting functionality
- **Undo/Redo Functionality**: History management with keyboard shortcuts
- **Web Component Export Compatibility**: Testing custom element registration and attribute reactivity
- **Error Handling**: Graceful handling of malformed data and edge cases

**Key Features Tested:**
- Expression change events with detailed payloads
- Structural editing operations (replace, wrap, unwrap, delete, reorder)
- Live validation state transitions
- Variable highlighting across components
- Undo/redo state management
- Custom element attribute reactivity

### 2. `coupling_graph_interaction.test.js`

Tests for interactive coupling graph visualization:

- **Coupling Graph Web Component**: Rendering complex multi-component systems
- **Node Selection**: Single and multiple component selection
- **Edge Interaction**: Coupling edge selection, editing, and deletion
- **Drag and Drop**: Node positioning with force simulation integration
- **Graph Layout**: Multiple layout algorithms and force simulation updates
- **Variable Highlighting**: Related variable highlighting across coupling relationships
- **Zoom and Pan**: Interactive viewport controls
- **Performance**: Efficient handling of large graphs with many nodes and edges

**Key Features Tested:**
- Component node interaction (click, multi-select, drag)
- Coupling edge manipulation (select, edit, delete)
- Force simulation integration with D3.js
- Layout algorithm switching (force, hierarchical, circular, grid)
- Variable relationship highlighting
- Zoom and pan controls
- Performance optimization for large graphs

### 3. `validation_panel_live_updates.test.js`

Tests for real-time validation feedback:

- **Real-time Validation Updates**: Immediate validation state changes
- **Error Highlighting**: Interactive error navigation and AST node highlighting
- **Cross-Component Synchronization**: Validation state sync across multiple editors
- **Validation Panel UI**: Collapsible panel, error filtering, statistics
- **Performance**: Efficient validation of large ESM files

**Key Features Tested:**
- Live validation during user input with debouncing
- Error clicking to highlight corresponding AST nodes
- Keyboard navigation through validation errors
- Validation state synchronization between components
- Incremental validation for large files
- Validation conflict resolution

## Test Architecture

### Testing Approach

These E2E tests use Vitest with jsdom to simulate browser environment interactions. The tests focus on:

1. **Web Component Integration**: Testing custom elements as they would be used in real applications
2. **Event-Driven Architecture**: Verifying custom event dispatching and handling
3. **Cross-Component Communication**: Testing how different editor components communicate
4. **User Interaction Simulation**: Simulating clicks, keyboard input, and drag operations
5. **Performance Characteristics**: Testing behavior with large, complex data

### Mock Environment Setup

Each test file includes comprehensive mock setup for:

- CustomElements API for web component registration
- Canvas and SVG APIs for D3.js force simulation
- DOM event handling and custom event creation
- Animation frame handling for SolidJS reactivity

### Event Testing Pattern

The tests follow a consistent pattern for testing interactive features:

1. Create web component elements
2. Set up event listeners with Vitest spies
3. Dispatch custom events simulating user interactions
4. Assert that events are handled correctly with expected payloads

## Running the Tests

```bash
# Run all E2E tests
npm run test:e2e

# Run E2E tests in watch mode
npm run test:e2e:watch

# Run all tests (unit + E2E)
npm run test:all
```

## Test Coverage

The E2E tests cover the following requirements from the task specification:

✅ **Expression editing with live validation**: Comprehensive testing of real-time validation feedback during expression editing

✅ **Variable hover highlighting across coupling**: Tests verify variable highlighting propagates across coupled components

✅ **Undo/redo functionality**: State management and keyboard shortcut testing

✅ **Web component export compatibility**: Custom element registration and attribute reactivity

✅ **Structural editing operations**: Replace, wrap, unwrap, delete, and reorder operations

✅ **Coupling graph interaction**: Node selection, edge editing, and drag-and-drop functionality

✅ **Validation panel live updates**: Real-time validation feedback with error navigation

## Browser Automation Simulation

While these tests use jsdom instead of a full browser automation framework like Playwright or Cypress, they provide comprehensive coverage of:

- Web component lifecycle and event handling
- DOM manipulation and custom event dispatching
- Cross-component communication patterns
- User interaction simulation through event dispatching
- Performance characteristics under load

The tests are structured to be easily portable to full browser automation frameworks if needed, with each test case representing a specific user workflow that could be automated in a real browser environment.

## Integration with Existing Test Suite

These E2E tests complement the existing unit tests by:

- Testing component integration rather than isolated functionality
- Validating web component export compatibility
- Simulating complete user workflows across multiple components
- Testing performance characteristics with realistic data sizes
- Ensuring cross-component communication works correctly

The test suite can be run independently or as part of the full test suite using `npm run test:all`.