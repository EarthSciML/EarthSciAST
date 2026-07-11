/**
 * Web Components Export - Export ESM Editor SolidJS components as standard custom elements
 *
 * This module uses solid-element to convert SolidJS components into standard
 * web components that can be used in any framework (React, Vue, Svelte) or vanilla HTML.
 *
 * Importing this module has no side effects: call `registerWebComponents()`
 * explicitly to define the custom elements.
 *
 * Components exported:
 * - <esm-expression-editor> - Interactive expression editing interface
 * - <esm-model-editor> - Full model editing interface
 * - <esm-file-editor> - ESM file summary/editor
 * - <esm-reaction-editor> - Reaction system editor
 * - <esm-coupling-graph> - Visual coupling graph
 */

import { customElement } from 'solid-element'
import { createComponent, createEffect, createMemo, mergeProps, Show } from 'solid-js'
import type { Component, JSX } from 'solid-js'
import { componentGraph } from '@earthsciml/ast'
import type {
  EsmFile,
  Expression,
  Model,
  ReactionSystem,
  ComponentNode,
  CouplingEdge,
} from '@earthsciml/ast'

// Import the editor components
import { ExpressionEditor } from './components/ExpressionEditor.js'
import { ModelEditor } from './components/ModelEditor.js'
import { ReactionEditor } from './components/ReactionEditor.js'
import { CouplingGraph as EsmEditorCouplingGraph } from './components/CouplingGraph.js'
import { FileSummary } from './components/FileSummary.js'

// Import styles
import './web-components.css'

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
  expression: string
  /** Whether editing is allowed */
  'allow-editing'?: boolean
  /** Whether to show the expression palette */
  'show-palette'?: boolean
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
  model: string
  /** Display name for the model */
  name?: string
  /** Whether editing is allowed */
  'allow-editing'?: boolean
  /** Whether to show the expression palette */
  'show-palette'?: boolean
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
  'esm-file': string
  /** Whether to show the file summary expanded */
  'show-summary'?: boolean
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
  'reaction-system': string
  /** Whether editing is allowed */
  'allow-editing'?: boolean
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
  'esm-file': string
  /** Width of the visualization area */
  width?: number
  /** Height of the visualization area */
  height?: number
  /** Whether to show the minimap */
  'show-minimap'?: boolean
}

/**
 * Props passed to a web-component render function: the documented attribute
 * interface plus the host element solid-element injects at render time.
 */
type WebComponentProps<T> = T & {
  /** The custom-element host, injected by {@link customElement}. */
  element?: HTMLElement
}

/** Interpret a web-component attribute value as a boolean (default true) */
function attrBool(value: unknown): boolean {
  return value !== false && value !== 'false'
}

/** Dispatch a bubbling CustomEvent from a custom element host */
function dispatch(element: HTMLElement | undefined, type: string, detail: unknown): void {
  if (typeof window !== 'undefined' && element) {
    element.dispatchEvent(new CustomEvent(type, { detail, bubbles: true }))
  }
}

/** Outcome of parsing a JSON-valued web-component attribute. */
type ParsedAttr<T> = { ok: true; value: T } | { ok: false; error: string }

/** Parse a JSON attribute string, returning either the value or an error message. */
function parseJsonAttr<T>(raw: string | undefined, missingMessage: string): ParsedAttr<T> {
  if (!raw) return { ok: false, error: missingMessage }
  try {
    return { ok: true, value: JSON.parse(raw) as T }
  } catch (error) {
    return {
      ok: false,
      error: `Component error: ${error instanceof Error ? error.message : 'Unknown error'}`,
    }
  }
}

/**
 * Extract the value from a successfully-parsed attribute. Only invoked from
 * inside a `Show when={parsed().ok}` branch, where success is guaranteed.
 */
function attrValue<T>(parsed: ParsedAttr<T>): T {
  return (parsed as Extract<ParsedAttr<T>, { ok: true }>).value
}

/** Reactive inline error element for missing/invalid web-component attributes. */
function ErrorState(props: { message: string }): JSX.Element {
  const el = document.createElement('div')
  el.className = 'error-state'
  createEffect(() => {
    el.textContent = props.message
  })
  return el
}

/**
 * `Show` narrowed to a single (non-keyed) props signature. `createComponent`
 * infers a component's props from its last call signature, which for `Show` is
 * the keyed overload — so `createComponent(Show, ...)` mistypes the props. This
 * alias pins the shape actually used here (boolean gate + element children).
 */
const ShowGate = Show as unknown as Component<{
  when: unknown
  fallback?: JSX.Element
  children: JSX.Element
}>

// Web component render functions wired to the real component props.
//
// Each wrapper parses its JSON attribute inside a `createMemo` and renders
// through `Show`, so attribute changes re-run the memo and propagate to the
// underlying editor (the previous setup parsed once at mount, so attribute
// updates never re-rendered). Attribute reads use the registered kebab-case
// keys uniformly across all five wrappers.

export const EsmExpressionEditorComponent = (
  props: WebComponentProps<EsmExpressionEditorProps>,
): JSX.Element => {
  const parsed = createMemo(() =>
    parseJsonAttr<Expression>(props.expression, 'Missing required attribute: expression'),
  )

  return createComponent(ShowGate, {
    get when() {
      return parsed().ok
    },
    fallback: createComponent(ErrorState, {
      get message() {
        const p = parsed()
        return p.ok ? '' : p.error
      },
    }),
    get children() {
      return createComponent(ExpressionEditor, {
        get initialExpression() {
          return attrValue(parsed())
        },
        onChange: (newExpr: Expression) =>
          dispatch(props.element, 'change', { expression: newExpr }),
        get readonly() {
          return !attrBool(props['allow-editing'])
        },
        get showPalette() {
          return attrBool(props['show-palette'])
        },
      })
    },
  })
}

export const EsmModelEditorComponent = (
  props: WebComponentProps<EsmModelEditorProps>,
): JSX.Element => {
  const parsed = createMemo(() =>
    parseJsonAttr<Model>(props.model, 'Missing required attribute: model'),
  )

  return createComponent(ShowGate, {
    get when() {
      return parsed().ok
    },
    fallback: createComponent(ErrorState, {
      get message() {
        const p = parsed()
        return p.ok ? '' : p.error
      },
    }),
    get children() {
      return createComponent(ModelEditor, {
        get model() {
          return attrValue(parsed())
        },
        get name() {
          return typeof props.name === 'string' && props.name ? props.name : undefined
        },
        onModelChange: (updatedModel: Model) =>
          dispatch(props.element, 'change', { model: updatedModel }),
        get readonly() {
          return !attrBool(props['allow-editing'])
        },
        get showPalette() {
          return attrBool(props['show-palette'])
        },
      })
    },
  })
}

export const EsmFileEditorComponent = (
  props: WebComponentProps<EsmFileEditorProps>,
): JSX.Element => {
  const parsed = createMemo(() =>
    parseJsonAttr<EsmFile>(props['esm-file'], 'Missing required attribute: esm-file'),
  )

  return createComponent(ShowGate, {
    get when() {
      return parsed().ok
    },
    fallback: createComponent(ErrorState, {
      get message() {
        const p = parsed()
        return p.ok ? '' : p.error
      },
    }),
    get children() {
      return createComponent(FileSummary, {
        get esmFile() {
          return attrValue(parsed())
        },
        get collapsed() {
          return !attrBool(props['show-summary'])
        },
        onSectionClick: (sectionType: string, sectionId?: string) =>
          dispatch(props.element, 'sectionClick', { sectionType, sectionId }),
      })
    },
  })
}

export const EsmReactionEditorComponent = (
  props: WebComponentProps<EsmReactionEditorProps>,
): JSX.Element => {
  const parsed = createMemo(() =>
    parseJsonAttr<ReactionSystem>(
      props['reaction-system'],
      'Missing required attribute: reaction-system',
    ),
  )

  return createComponent(ShowGate, {
    get when() {
      return parsed().ok
    },
    fallback: createComponent(ErrorState, {
      get message() {
        const p = parsed()
        return p.ok ? '' : p.error
      },
    }),
    get children() {
      return createComponent(ReactionEditor, {
        get reactionSystem() {
          return attrValue(parsed())
        },
        onReactionSystemChange: (updatedSystem: ReactionSystem) =>
          dispatch(props.element, 'change', { reactionSystem: updatedSystem }),
        get readonly() {
          return !attrBool(props['allow-editing'])
        },
      })
    },
  })
}

export const EsmCouplingGraphComponent = (
  props: WebComponentProps<EsmCouplingGraphProps>,
): JSX.Element => {
  const parsed = createMemo(() =>
    parseJsonAttr<EsmFile>(props['esm-file'], 'Missing required attribute: esm-file'),
  )

  return createComponent(ShowGate, {
    get when() {
      return parsed().ok
    },
    fallback: createComponent(ErrorState, {
      get message() {
        const p = parsed()
        return p.ok ? '' : p.error
      },
    }),
    get children() {
      return createComponent(EsmEditorCouplingGraph, {
        // componentGraph returns the adjacency-bearing Graph the component
        // consumes directly, replacing the deprecated component_graph + adapter.
        get graph() {
          return componentGraph(attrValue(parsed()))
        },
        onNodeSelect: (node: ComponentNode) =>
          dispatch(props.element, 'componentSelect', { componentId: node.id }),
        onEdgeSelect: (edge: CouplingEdge) =>
          dispatch(props.element, 'couplingEdit', { coupling: edge.coupling, edgeId: edge.id }),
        get width() {
          return props.width !== undefined ? parseInt(String(props.width), 10) : undefined
        },
        get height() {
          return props.height !== undefined ? parseInt(String(props.height), 10) : undefined
        },
        get showMinimap() {
          return attrBool(props['show-minimap'])
        },
      })
    },
  })
}

/**
 * Register all ESM editor web components
 */
export function registerWebComponents() {
  if (typeof window === 'undefined' || typeof customElements === 'undefined') {
    return // Skip registration in non-browser environments
  }

  try {
    // Merge (not spread) the injected host `element` into props so
    // solid-element's reactive props object stays live and attribute updates
    // propagate. The context element is a custom element (an HTMLElement at
    // runtime); solid-element types it loosely, hence the cast.
    customElement(
      'esm-expression-editor',
      {
        expression: '',
        'allow-editing': true,
        'show-palette': true,
      },
      (props, { element }) =>
        EsmExpressionEditorComponent(
          mergeProps(props, { element: element as unknown as HTMLElement }),
        ),
    )

    customElement(
      'esm-model-editor',
      {
        model: '',
        name: '',
        'allow-editing': true,
        'show-palette': true,
      },
      (props, { element }) =>
        EsmModelEditorComponent(mergeProps(props, { element: element as unknown as HTMLElement })),
    )

    customElement(
      'esm-file-editor',
      {
        'esm-file': '',
        'show-summary': true,
      },
      (props, { element }) =>
        EsmFileEditorComponent(mergeProps(props, { element: element as unknown as HTMLElement })),
    )

    customElement(
      'esm-reaction-editor',
      {
        'reaction-system': '',
        'allow-editing': true,
      },
      (props, { element }) =>
        EsmReactionEditorComponent(
          mergeProps(props, { element: element as unknown as HTMLElement }),
        ),
    )

    customElement(
      'esm-coupling-graph',
      {
        'esm-file': '',
        width: 800,
        height: 600,
        'show-minimap': true,
      },
      (props, { element }) =>
        EsmCouplingGraphComponent(
          mergeProps(props, { element: element as unknown as HTMLElement }),
        ),
    )
  } catch (error) {
    console.warn('Failed to register ESM Editor web components:', error)
  }
}
