/**
 * Web Components Export - Export ESM Editor SolidJS components as standard custom elements
 *
 * This module uses solid-element to convert SolidJS components into standard
 * web components that can be used in any framework (React, Vue, Svelte) or vanilla HTML.
 *
 * Components exported:
 * - <esm-expression-editor> - Interactive expression editing interface
 * - <esm-model-editor> - Full model editing interface
 * - <esm-file-editor> - ESM file summary/editor
 * - <esm-reaction-editor> - Reaction system editor
 * - <esm-coupling-graph> - Visual coupling graph
 */

import { customElement } from 'solid-element';
import { createComponent } from 'solid-js';
import type { JSX } from 'solid-js';
import { component_graph } from 'earthsci-toolkit';
import type {
  EsmFile,
  Expression,
  Model,
  ReactionSystem,
  ComponentNode,
  CouplingEdge,
  ComponentGraph,
  Graph
} from 'earthsci-toolkit';

// Import the editor components
import { ExpressionEditor } from './components/ExpressionEditor.js';
import { ModelEditor } from './components/ModelEditor.js';
import { ReactionEditor } from './components/ReactionEditor.js';
import { CouplingGraph as EsmEditorCouplingGraph } from './components/CouplingGraph.js';
import { FileSummary } from './components/FileSummary.js';

// Import styles
import './web-components.css';

/**
 * Web component wrapper for ExpressionEditor (expression editing)
 *
 * Usage:
 * <esm-expression-editor
 *   expression='{"op": "+", "args": [1, 2]}'
 *   allow-editing="true"
 *   show-palette="true">
 * </esm-expression-editor>
 */
export interface EsmExpressionEditorProps {
  /** JSON string of the expression to edit */
  expression: string;
  /** Whether editing is allowed */
  'allow-editing'?: boolean;
  /** Whether to show the expression palette */
  'show-palette'?: boolean;
  /** Whether to show validation errors */
  'show-validation'?: boolean;
}

/**
 * Web component wrapper for ModelEditor
 *
 * Usage:
 * <esm-model-editor
 *   model='{"variables": {...}, "equations": [...]}'
 *   name="MyModel"
 *   allow-editing="true">
 * </esm-model-editor>
 */
export interface EsmModelEditorProps {
  /** JSON string of the model to edit */
  model: string;
  /** Display name for the model */
  name?: string;
  /** Whether editing is allowed */
  'allow-editing'?: boolean;
  /** Whether to show the expression palette */
  'show-palette'?: boolean;
}

/**
 * Web component wrapper for a whole-file summary view
 *
 * Usage:
 * <esm-file-editor
 *   esm-file='{"esm": "0.8.0", "metadata": {...}, "models": {...}}'
 *   show-summary="true">
 * </esm-file-editor>
 */
export interface EsmFileEditorProps {
  /** JSON string of the ESM file to edit */
  'esm-file': string;
  /** Whether to show the file summary expanded */
  'show-summary'?: boolean;
}

/**
 * Web component wrapper for ReactionEditor
 *
 * Usage:
 * <esm-reaction-editor
 *   reaction-system='{"species": {...}, "parameters": {...}, "reactions": [...]}'
 *   allow-editing="true">
 * </esm-reaction-editor>
 */
export interface EsmReactionEditorProps {
  /** JSON string of the reaction system to edit */
  'reaction-system': string;
  /** Whether editing is allowed */
  'allow-editing'?: boolean;
}

/**
 * Web component wrapper for CouplingGraph
 *
 * Usage:
 * <esm-coupling-graph
 *   esm-file='{"esm": "0.8.0", "models": {...}, "coupling": [...]}'
 *   width="800"
 *   height="600">
 * </esm-coupling-graph>
 */
export interface EsmCouplingGraphProps {
  /** JSON string of the ESM file to visualize */
  'esm-file': string;
  /** Width of the visualization area */
  width?: number;
  /** Height of the visualization area */
  height?: number;
  /** Whether to show the minimap */
  'show-minimap'?: boolean;
}

/** Interpret a web-component attribute value as a boolean (default true) */
function attrBool(value: unknown): boolean {
  return value !== false && value !== 'false';
}

/** Dispatch a bubbling CustomEvent from a custom element host */
function dispatch(element: HTMLElement | undefined, type: string, detail: unknown): void {
  if (typeof window !== 'undefined' && element) {
    element.dispatchEvent(new CustomEvent(type, { detail, bubbles: true }));
  }
}

/** Render an inline error message */
function renderError(message: string): HTMLElement {
  const errorDiv = document.createElement('div');
  errorDiv.className = 'error-state';
  errorDiv.textContent = message;
  return errorDiv;
}

/**
 * Convert the toolkit's ComponentGraph ({nodes, edges: CouplingEdge[]}) into the
 * Graph<ComponentNode, CouplingEdge> shape (with adjacency helpers) that the
 * CouplingGraph component consumes.
 */
function toGraph(componentGraph: ComponentGraph): Graph<ComponentNode, CouplingEdge> {
  const edges = componentGraph.edges.map(edge => ({
    source: edge.from,
    target: edge.to,
    data: edge
  }));

  return {
    nodes: componentGraph.nodes,
    edges,
    adjacency: (node: string) => {
      const neighbors = new Set<string>();
      for (const edge of edges) {
        if (edge.source === node) neighbors.add(edge.target);
        if (edge.target === node) neighbors.add(edge.source);
      }
      return Array.from(neighbors);
    },
    predecessors: (node: string) =>
      edges.filter(edge => edge.target === node).map(edge => edge.source),
    successors: (node: string) =>
      edges.filter(edge => edge.source === node).map(edge => edge.target)
  };
}

// Web component render functions wired to the real component props

export const EsmExpressionEditorComponent = (props: Record<string, any>): JSX.Element => {
  if (!props.expression) {
    return renderError('Missing required attribute: expression');
  }

  try {
    const expression: Expression = JSON.parse(props.expression);

    return createComponent(ExpressionEditor, {
      initialExpression: expression,
      onChange: (newExpr: Expression) =>
        dispatch(props.element, 'change', { expression: newExpr }),
      allowEditing: attrBool(props['allow-editing']),
      showPalette: attrBool(props['show-palette']),
      showValidation: attrBool(props['show-validation'])
    });
  } catch (error) {
    return renderError(`Component error: ${error instanceof Error ? error.message : 'Unknown error'}`);
  }
};

export const EsmModelEditorComponent = (props: Record<string, any>): JSX.Element => {
  if (!props.model) {
    return renderError('Missing required attribute: model');
  }

  try {
    const model: Model = JSON.parse(props.model);

    return createComponent(ModelEditor, {
      model,
      name: typeof props.name === 'string' && props.name ? props.name : undefined,
      onModelChange: (updatedModel: Model) =>
        dispatch(props.element, 'change', { model: updatedModel }),
      readonly: !attrBool(props['allow-editing']),
      showPalette: attrBool(props['show-palette'])
    });
  } catch (error) {
    return renderError(`Component error: ${error instanceof Error ? error.message : 'Unknown error'}`);
  }
};

export const EsmFileEditorComponent = (props: Record<string, any>): JSX.Element => {
  const esmFileValue = props['esm-file'] || props.esmFile;
  if (!esmFileValue) {
    return renderError('Missing required attribute: esm-file');
  }

  try {
    const esmFile: EsmFile = JSON.parse(esmFileValue);

    return createComponent(FileSummary, {
      esmFile,
      collapsed: !attrBool(props['show-summary']),
      onSectionClick: (sectionType: string, sectionId?: string) =>
        dispatch(props.element, 'sectionClick', { sectionType, sectionId })
    });
  } catch (error) {
    return renderError(`Component error: ${error instanceof Error ? error.message : 'Unknown error'}`);
  }
};

export const EsmReactionEditorComponent = (props: Record<string, any>): JSX.Element => {
  const reactionSystemValue = props['reaction-system'] || props.reactionSystem;
  if (!reactionSystemValue) {
    return renderError('Missing required attribute: reaction-system');
  }

  try {
    const reactionSystem: ReactionSystem = JSON.parse(reactionSystemValue);

    return createComponent(ReactionEditor, {
      reactionSystem,
      onReactionSystemChange: (updatedSystem: ReactionSystem) =>
        dispatch(props.element, 'change', { reactionSystem: updatedSystem }),
      readonly: !attrBool(props['allow-editing'])
    });
  } catch (error) {
    return renderError(`Component error: ${error instanceof Error ? error.message : 'Unknown error'}`);
  }
};

export const EsmCouplingGraphComponent = (props: Record<string, any>): JSX.Element => {
  const esmFileValue = props['esm-file'] || props.esmFile;
  if (!esmFileValue) {
    return renderError('Missing required attribute: esm-file');
  }

  try {
    const esmFile: EsmFile = JSON.parse(esmFileValue);

    // Convert the ESM file to a graph for the CouplingGraph component
    const graph = toGraph(component_graph(esmFile));

    return createComponent(EsmEditorCouplingGraph, {
      graph,
      onNodeSelect: (node: ComponentNode) =>
        dispatch(props.element, 'componentSelect', { componentId: node.id }),
      onEdgeSelect: (edge: CouplingEdge) =>
        dispatch(props.element, 'couplingEdit', { coupling: edge.coupling, edgeId: edge.id }),
      width: props.width !== undefined ? parseInt(String(props.width), 10) : undefined,
      height: props.height !== undefined ? parseInt(String(props.height), 10) : undefined,
      showMinimap: attrBool(props['show-minimap'])
    });
  } catch (error) {
    return renderError(`Component error: ${error instanceof Error ? error.message : 'Unknown error'}`);
  }
};

/**
 * Register all ESM editor web components
 */
export function registerWebComponents() {
  if (typeof window === 'undefined' || typeof customElements === 'undefined') {
    return; // Skip registration in non-browser environments
  }

  try {
    customElement('esm-expression-editor', {
      expression: '',
      'allow-editing': true,
      'show-palette': true,
      'show-validation': true
    }, (props, { element }) => EsmExpressionEditorComponent({ ...props, element }));

    customElement('esm-model-editor', {
      model: '',
      name: '',
      'allow-editing': true,
      'show-palette': true
    }, (props, { element }) => EsmModelEditorComponent({ ...props, element }));

    customElement('esm-file-editor', {
      'esm-file': '',
      'show-summary': true
    }, (props, { element }) => EsmFileEditorComponent({ ...props, element }));

    customElement('esm-reaction-editor', {
      'reaction-system': '',
      'allow-editing': true
    }, (props, { element }) => EsmReactionEditorComponent({ ...props, element }));

    customElement('esm-coupling-graph', {
      'esm-file': '',
      width: 800,
      height: 600,
      'show-minimap': true
    }, (props, { element }) => EsmCouplingGraphComponent({ ...props, element }));

    console.log('ESM Editor web components registered successfully');

  } catch (error) {
    console.warn('Failed to register ESM Editor web components:', error);
  }
}

// Auto-register when module is imported in browser environment
if (typeof window !== 'undefined') {
  // Delay registration to ensure solid-element is loaded
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', registerWebComponents);
  } else {
    // Document is already loaded
    setTimeout(registerWebComponents, 0);
  }
}
