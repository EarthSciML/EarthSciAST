/**
 * ModelEditor - Complete model editing interface
 *
 * This component provides a comprehensive view for editing entire models,
 * including:
 * - Variables panel grouped by type (state/parameter/observed/...) with badges, units, and defaults
 * - Equation list with each equation as an EquationEditor
 * - Event editors for both continuous and discrete events
 * - UI for adding/removing variables and equations
 *
 * All add/edit flows use inline forms (InlineForm) — no blocking browser
 * dialogs. Hovering a variable in the variables panel highlights its
 * occurrences in the equation list.
 *
 * The panels themselves live in their own files (VariablesPanel,
 * EquationsPanel, EventsPanel); this component owns model-level state and the
 * add/edit/remove handlers that produce new Model objects.
 */

import type { Component } from 'solid-js'
import { createSignal, Show } from 'solid-js'
import type {
  Model,
  ModelVariable,
  Equation,
  ContinuousEvent,
  DiscreteEvent,
} from '@earthsciml/ast'
import { ExpressionPalette } from './ExpressionPalette'
import { VariablesPanel } from './VariablesPanel'
import { EquationsPanel } from './EquationsPanel'
import { EventsPanel } from './EventsPanel'
import {
  EXPRESSION_PLACEHOLDER,
  CONDITION_PLACEHOLDER,
  TRIGGER_PLACEHOLDER,
  VARIABLE_PLACEHOLDER,
  VALUE_PLACEHOLDER,
} from '../constants'

export interface ModelEditorProps {
  /** The model to display and edit */
  model: Model

  /** Display name of the model (in the ESM schema the name is the key in the `models` record) */
  name?: string

  /** Optional display description for the model */
  description?: string

  /** Callback when the model is modified */
  onModelChange?: (newModel: Model) => void

  /** Whether the editor is in read-only mode */
  readonly?: boolean

  /** CSS class for styling */
  class?: string

  /** Whether to show the expression palette */
  showPalette?: boolean
}

/**
 * Main ModelEditor component
 */
export const ModelEditor: Component<ModelEditorProps> = (props) => {
  // Highlighting is driven by hovering variables in the variables panel:
  // the hovered variable is highlighted in the equation list.
  const [highlightedVars, setHighlightedVars] = createSignal<Set<string>>(new Set())

  const handleVariableHover = (name: string | null) => {
    setHighlightedVars(name ? new Set([name]) : new Set<string>())
  }

  // Handle model modifications
  const handleModelChange = (changes: Partial<Model>) => {
    if (props.readonly || !props.onModelChange) return

    const newModel = { ...props.model, ...changes }
    props.onModelChange(newModel)
  }

  // Variable management handlers
  const handleAddVariable = (name: string, variable: ModelVariable) => {
    const newVariables = { ...(props.model.variables || {}), [name]: variable }
    handleModelChange({ variables: newVariables })
  }

  const handleEditVariable = (oldName: string, newName: string, variable: ModelVariable) => {
    const updatedVariables = { ...(props.model.variables || {}) }
    if (newName !== oldName) {
      delete updatedVariables[oldName]
    }
    updatedVariables[newName] = variable
    handleModelChange({ variables: updatedVariables })
  }

  const handleRemoveVariable = (name: string) => {
    const updatedVariables = { ...(props.model.variables || {}) }
    delete updatedVariables[name]
    handleModelChange({ variables: updatedVariables })
  }

  // Equation management handlers
  const handleAddEquation = () => {
    const newEquation: Equation = {
      lhs: EXPRESSION_PLACEHOLDER,
      rhs: 0,
    }
    const newEquations = [...(props.model.equations || []), newEquation]
    handleModelChange({ equations: newEquations })
  }

  const handleEditEquation = (index: number, equation: Equation) => {
    const newEquations = [...(props.model.equations || [])]
    newEquations[index] = equation
    handleModelChange({ equations: newEquations })
  }

  const handleRemoveEquation = (index: number) => {
    const newEquations = (props.model.equations || []).filter((_, i) => i !== index)
    handleModelChange({ equations: newEquations })
  }

  // Event management handlers
  const handleAddContinuousEvent = (name: string, description: string) => {
    const newEvent: ContinuousEvent = {
      name,
      description,
      conditions: [CONDITION_PLACEHOLDER],
      affects: [
        {
          lhs: VARIABLE_PLACEHOLDER,
          rhs: VALUE_PLACEHOLDER,
        },
      ],
    }

    const newContinuousEvents = [...(props.model.continuous_events || []), newEvent]
    handleModelChange({ continuous_events: newContinuousEvents })
  }

  const handleAddDiscreteEvent = (name: string, description: string) => {
    const newEvent: DiscreteEvent = {
      name,
      description,
      trigger: { type: 'condition', expression: TRIGGER_PLACEHOLDER },
      affects: [
        {
          lhs: VARIABLE_PLACEHOLDER,
          rhs: VALUE_PLACEHOLDER,
        },
      ],
    }

    const newDiscreteEvents = [...(props.model.discrete_events || []), newEvent]
    handleModelChange({ discrete_events: newDiscreteEvents })
  }

  const handleEditContinuousEvent = (index: number, event: ContinuousEvent) => {
    const updatedEvents = [...(props.model.continuous_events || [])]
    updatedEvents[index] = event
    handleModelChange({ continuous_events: updatedEvents })
  }

  const handleEditDiscreteEvent = (index: number, event: DiscreteEvent) => {
    const updatedEvents = [...(props.model.discrete_events || [])]
    updatedEvents[index] = event
    handleModelChange({ discrete_events: updatedEvents })
  }

  const editorClasses = () => {
    const classes = ['model-editor']
    if (props.readonly) classes.push('readonly')
    if (props.class) classes.push(props.class)
    return classes.join(' ')
  }

  return (
    <div class={editorClasses()}>
      <div class="model-editor-layout">
        {/* Main content area */}
        <div class="model-content">
          <div class="model-header">
            <h2 class="model-name">{props.name || 'Untitled Model'}</h2>
            <Show when={props.description}>
              <div class="model-description">{props.description}</div>
            </Show>
          </div>

          <div class="model-panels">
            <VariablesPanel
              variables={props.model.variables}
              onAddVariable={handleAddVariable}
              onEditVariable={handleEditVariable}
              onRemoveVariable={handleRemoveVariable}
              onVariableHover={handleVariableHover}
              readonly={props.readonly}
            />

            <EquationsPanel
              equations={props.model.equations}
              highlightedVars={highlightedVars()}
              onAddEquation={handleAddEquation}
              onEditEquation={handleEditEquation}
              onRemoveEquation={handleRemoveEquation}
              readonly={props.readonly}
            />

            <EventsPanel
              continuousEvents={props.model.continuous_events}
              discreteEvents={props.model.discrete_events}
              onAddContinuousEvent={handleAddContinuousEvent}
              onAddDiscreteEvent={handleAddDiscreteEvent}
              onEditContinuousEvent={handleEditContinuousEvent}
              onEditDiscreteEvent={handleEditDiscreteEvent}
              readonly={props.readonly}
            />
          </div>
        </div>

        {/* Expression palette sidebar */}
        <Show when={props.showPalette && !props.readonly}>
          <div class="palette-sidebar">
            <ExpressionPalette currentModel={props.model} visible={true} />
          </div>
        </Show>
      </div>
    </div>
  )
}

export default ModelEditor
