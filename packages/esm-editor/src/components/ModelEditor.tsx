/**
 * ModelEditor - Complete model editing interface
 *
 * This component provides a comprehensive view for editing entire models,
 * including:
 * - Variables panel grouped by type (state/parameter/observed/...) with badges, units, and defaults
 * - Equation list with each equation as an EquationEditor
 * - Event editors for both continuous and discrete events
 * - UI for adding/removing variables and equations
 */

import { Component, createSignal, createMemo, For, Show } from 'solid-js';
import type { Model, ModelVariable, Equation, ContinuousEvent, DiscreteEvent } from 'earthsci-toolkit';
import { EquationEditor } from './EquationEditor';
import { ExpressionPalette } from './ExpressionPalette';

export interface ModelEditorProps {
  /** The model to display and edit */
  model: Model;

  /** Display name of the model (in the ESM schema the name is the key in the `models` record) */
  name?: string;

  /** Optional display description for the model */
  description?: string;

  /** Callback when the model is modified */
  onModelChange?: (newModel: Model) => void;

  /** Whether the editor is in read-only mode */
  readonly?: boolean;

  /** CSS class for styling */
  class?: string;

  /** Whether to show the expression palette */
  showPalette?: boolean;
}

// Variable type definitions for categorization
type VariableType = ModelVariable['type'] | 'other';

// Badge configuration for different variable types
const VARIABLE_TYPE_CONFIG: Record<VariableType, { label: string; color: string; description: string }> = {
  state: { label: 'State', color: 'blue', description: 'State variable' },
  parameter: { label: 'Param', color: 'green', description: 'Parameter' },
  observed: { label: 'Obs', color: 'orange', description: 'Observed variable' },
  brownian: { label: 'Brownian', color: 'purple', description: 'Brownian variable' },
  discrete: { label: 'Discrete', color: 'teal', description: 'Discrete variable' },
  other: { label: 'Var', color: 'gray', description: 'Variable' }
};

/** A model variable paired with its name (the key in the model's variables record) */
interface NamedVariable {
  name: string;
  variable: ModelVariable;
}

/**
 * Component for individual variable item in the variables panel
 */
const VariableItem: Component<{
  name: string;
  variable: ModelVariable;
  type: VariableType;
  onEdit?: (name: string, variable: ModelVariable) => void;
  onRemove?: (name: string) => void;
  readonly?: boolean;
}> = (props) => {
  const [isHovered, setIsHovered] = createSignal(false);

  const typeConfig = () => VARIABLE_TYPE_CONFIG[props.type];

  const handleEdit = () => {
    if (!props.readonly) {
      props.onEdit?.(props.name, props.variable);
    }
  };

  const handleRemove = (e: MouseEvent) => {
    e.stopPropagation();
    if (!props.readonly) {
      props.onRemove?.(props.name);
    }
  };

  return (
    <div
      class={`variable-item ${isHovered() ? 'hovered' : ''}`}
      onMouseEnter={() => setIsHovered(true)}
      onMouseLeave={() => setIsHovered(false)}
      onClick={handleEdit}
      role="button"
      tabIndex={0}
    >
      <div class="variable-info">
        <div class="variable-header">
          <span class="variable-name">{props.name}</span>
          <span class={`variable-type-badge ${typeConfig().color}`} title={typeConfig().description}>
            {typeConfig().label}
          </span>
        </div>

        <Show when={props.variable.units}>
          <div class="variable-unit" title="Unit">
            [{props.variable.units}]
          </div>
        </Show>

        <Show when={props.variable.default !== undefined}>
          <div class="variable-default" title="Default value">
            = {props.variable.default}
          </div>
        </Show>

        <Show when={props.variable.description}>
          <div class="variable-description" title="Description">
            {props.variable.description}
          </div>
        </Show>
      </div>

      <Show when={!props.readonly && isHovered()}>
        <button
          class="variable-remove-btn"
          onClick={handleRemove}
          title="Remove variable"
          aria-label={`Remove variable ${props.name}`}
        >
          ×
        </button>
      </Show>
    </div>
  );
};

/**
 * Variables panel component
 */
const VariablesPanel: Component<{
  variables?: Model['variables'];
  onAddVariable?: () => void;
  onEditVariable?: (name: string, variable: ModelVariable) => void;
  onRemoveVariable?: (name: string) => void;
  readonly?: boolean;
}> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true);

  const variableEntries = createMemo((): NamedVariable[] =>
    Object.entries(props.variables || {}).map(([name, variable]) => ({ name, variable }))
  );

  // Group variables by type
  const groupedVariables = createMemo(() => {
    const groups: Record<VariableType, NamedVariable[]> = {
      state: [],
      parameter: [],
      observed: [],
      brownian: [],
      discrete: [],
      other: []
    };

    variableEntries().forEach(entry => {
      // Use the actual type field from ModelVariable, fall back to 'other' if not recognized
      const type: VariableType =
        entry.variable.type && entry.variable.type in groups ? entry.variable.type : 'other';

      groups[type].push(entry);
    });

    return groups;
  });

  return (
    <div class="variables-panel">
      <div class="panel-header" onClick={() => setIsExpanded(!isExpanded())}>
        <span class={`expand-icon ${isExpanded() ? 'expanded' : ''}`}>▶</span>
        <h3>Variables ({variableEntries().length})</h3>
        <Show when={!props.readonly}>
          <button
            class="add-btn"
            onClick={(e) => { e.stopPropagation(); props.onAddVariable?.(); }}
            title="Add new variable"
            aria-label="Add new variable"
          >
            +
          </button>
        </Show>
      </div>

      <Show when={isExpanded()}>
        <div class="variables-content">
          <For each={Object.entries(groupedVariables()) as [VariableType, NamedVariable[]][]}>
            {([type, variables]) => (
              <Show when={variables.length > 0}>
                <div class="variable-group">
                  <h4 class="group-title">
                    <span class={`group-badge ${VARIABLE_TYPE_CONFIG[type].color}`}>
                      {VARIABLE_TYPE_CONFIG[type].label}
                    </span>
                    {VARIABLE_TYPE_CONFIG[type].description}s ({variables.length})
                  </h4>
                  <div class="variables-list">
                    <For each={variables}>
                      {(entry) => (
                        <VariableItem
                          name={entry.name}
                          variable={entry.variable}
                          type={type}
                          onEdit={props.onEditVariable}
                          onRemove={props.onRemoveVariable}
                          readonly={props.readonly}
                        />
                      )}
                    </For>
                  </div>
                </div>
              </Show>
            )}
          </For>

          <Show when={variableEntries().length === 0}>
            <div class="empty-state">
              <div class="empty-icon">📊</div>
              <div class="empty-text">No variables defined</div>
              <Show when={!props.readonly}>
                <button class="add-first-btn" onClick={props.onAddVariable}>
                  Add first variable
                </button>
              </Show>
            </div>
          </Show>
        </div>
      </Show>
    </div>
  );
};

/**
 * Equations panel component
 */
const EquationsPanel: Component<{
  equations?: Equation[];
  highlightedVars?: Set<string>;
  onAddEquation?: () => void;
  onEditEquation?: (index: number, equation: Equation) => void;
  onRemoveEquation?: (index: number) => void;
  readonly?: boolean;
}> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true);

  return (
    <div class="equations-panel">
      <div class="panel-header" onClick={() => setIsExpanded(!isExpanded())}>
        <span class={`expand-icon ${isExpanded() ? 'expanded' : ''}`}>▶</span>
        <h3>Equations ({(props.equations || []).length})</h3>
        <Show when={!props.readonly}>
          <button
            class="add-btn"
            onClick={(e) => { e.stopPropagation(); props.onAddEquation?.(); }}
            title="Add new equation"
            aria-label="Add new equation"
          >
            +
          </button>
        </Show>
      </div>

      <Show when={isExpanded()}>
        <div class="equations-content">
          <For each={props.equations || []}>
            {(equation, index) => (
              <div class="equation-item">
                <EquationEditor
                  equation={equation}
                  highlightedVars={props.highlightedVars}
                  onEquationChange={(newEquation) => props.onEditEquation?.(index(), newEquation)}
                  readonly={props.readonly}
                  class="model-equation"
                />
                <Show when={!props.readonly}>
                  <button
                    class="equation-remove-btn"
                    onClick={() => props.onRemoveEquation?.(index())}
                    title="Remove equation"
                    aria-label={`Remove equation ${index() + 1}`}
                  >
                    ×
                  </button>
                </Show>
              </div>
            )}
          </For>

          <Show when={(props.equations || []).length === 0}>
            <div class="empty-state">
              <div class="empty-icon">⚖️</div>
              <div class="empty-text">No equations defined</div>
              <Show when={!props.readonly}>
                <button class="add-first-btn" onClick={props.onAddEquation}>
                  Add first equation
                </button>
              </Show>
            </div>
          </Show>
        </div>
      </Show>
    </div>
  );
};

/**
 * Events panel component
 */
const EventsPanel: Component<{
  continuousEvents?: ContinuousEvent[];
  discreteEvents?: DiscreteEvent[];
  onAddContinuousEvent?: () => void;
  onAddDiscreteEvent?: () => void;
  onEditContinuousEvent?: (index: number, event: ContinuousEvent) => void;
  onEditDiscreteEvent?: (index: number, event: DiscreteEvent) => void;
  readonly?: boolean;
}> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true);

  const totalEvents = () =>
    (props.continuousEvents || []).length + (props.discreteEvents || []).length;

  return (
    <div class="events-panel">
      <div class="panel-header" onClick={() => setIsExpanded(!isExpanded())}>
        <span class={`expand-icon ${isExpanded() ? 'expanded' : ''}`}>▶</span>
        <h3>Events ({totalEvents()})</h3>
        <Show when={!props.readonly}>
          <div class="event-add-buttons">
            <button
              class="add-btn"
              onClick={(e) => { e.stopPropagation(); props.onAddContinuousEvent?.(); }}
              title="Add continuous event"
            >
              + Continuous
            </button>
            <button
              class="add-btn"
              onClick={(e) => { e.stopPropagation(); props.onAddDiscreteEvent?.(); }}
              title="Add discrete event"
            >
              + Discrete
            </button>
          </div>
        </Show>
      </div>

      <Show when={isExpanded()}>
        <div class="events-content">
          <Show when={(props.continuousEvents || []).length > 0}>
            <div class="event-group">
              <h4>Continuous Events</h4>
              <For each={props.continuousEvents || []}>
                {(event, eventIndex) => (
                  <div class="event-item continuous">
                    <div class="event-name">{event.name || 'Unnamed Event'}</div>
                    <Show when={event.description}>
                      <div class="event-description">{event.description}</div>
                    </Show>
                    <div class="event-details">
                      <div class="event-conditions">
                        <strong>Conditions:</strong>
                        <For each={event.conditions || []}>
                          {(condition, index) => (
                            <div class="condition-item">
                              <code class="condition-expr">{JSON.stringify(condition)}</code>
                              <Show when={!props.readonly}>
                                <button
                                  class="edit-btn"
                                  onClick={() => {
                                    const newCondition = prompt('Edit condition:', JSON.stringify(condition));
                                    if (newCondition) {
                                      try {
                                        const parsed = JSON.parse(newCondition);
                                        const updatedConditions = [...event.conditions] as ContinuousEvent['conditions'];
                                        updatedConditions[index()] = parsed;
                                        props.onEditContinuousEvent?.(eventIndex(), { ...event, conditions: updatedConditions });
                                      } catch {
                                        alert('Invalid JSON format');
                                      }
                                    }
                                  }}
                                >
                                  Edit
                                </button>
                              </Show>
                            </div>
                          )}
                        </For>
                      </div>
                      <div class="event-affects">
                        <strong>Effects:</strong>
                        <For each={event.affects || []}>
                          {(affect, index) => (
                            <div class="affect-item">
                              <code class="affect-expr">
                                {JSON.stringify(affect.lhs)} = {JSON.stringify(affect.rhs)}
                              </code>
                              <Show when={!props.readonly}>
                                <button
                                  class="edit-btn"
                                  onClick={() => {
                                    const newLhs = prompt('Edit left side:', JSON.stringify(affect.lhs));
                                    const newRhs = prompt('Edit right side:', JSON.stringify(affect.rhs));
                                    if (newLhs && newRhs) {
                                      try {
                                        const parsedLhs = JSON.parse(newLhs);
                                        const parsedRhs = JSON.parse(newRhs);
                                        const updatedAffects = [...event.affects];
                                        updatedAffects[index()] = { lhs: parsedLhs, rhs: parsedRhs };
                                        props.onEditContinuousEvent?.(eventIndex(), { ...event, affects: updatedAffects });
                                      } catch {
                                        alert('Invalid JSON format');
                                      }
                                    }
                                  }}
                                >
                                  Edit
                                </button>
                              </Show>
                            </div>
                          )}
                        </For>
                      </div>
                    </div>
                  </div>
                )}
              </For>
            </div>
          </Show>

          <Show when={(props.discreteEvents || []).length > 0}>
            <div class="event-group">
              <h4>Discrete Events</h4>
              <For each={props.discreteEvents || []}>
                {(event, eventIndex) => (
                  <div class="event-item discrete">
                    <div class="event-name">{event.name || 'Unnamed Event'}</div>
                    <Show when={event.description}>
                      <div class="event-description">{event.description}</div>
                    </Show>
                    <div class="event-details">
                      <div class="event-trigger">
                        <strong>Trigger:</strong>
                        <div class="trigger-item">
                          <code class="trigger-expr">{JSON.stringify(event.trigger)}</code>
                          <Show when={!props.readonly}>
                            <button
                              class="edit-btn"
                              onClick={() => {
                                const newTrigger = prompt('Edit trigger:', JSON.stringify(event.trigger));
                                if (newTrigger) {
                                  try {
                                    const parsed = JSON.parse(newTrigger);
                                    props.onEditDiscreteEvent?.(eventIndex(), { ...event, trigger: parsed });
                                  } catch {
                                    alert('Invalid JSON format');
                                  }
                                }
                              }}
                            >
                              Edit
                            </button>
                          </Show>
                        </div>
                      </div>
                      <div class="event-affects">
                        <strong>Effects:</strong>
                        <For each={event.affects || []}>
                          {(affect, index) => (
                            <div class="affect-item">
                              <code class="affect-expr">
                                {JSON.stringify(affect.lhs)} = {JSON.stringify(affect.rhs)}
                              </code>
                              <Show when={!props.readonly}>
                                <button
                                  class="edit-btn"
                                  onClick={() => {
                                    const newLhs = prompt('Edit left side:', JSON.stringify(affect.lhs));
                                    const newRhs = prompt('Edit right side:', JSON.stringify(affect.rhs));
                                    if (newLhs && newRhs) {
                                      try {
                                        const parsedLhs = JSON.parse(newLhs);
                                        const parsedRhs = JSON.parse(newRhs);
                                        const updatedAffects = [...(event.affects || [])];
                                        updatedAffects[index()] = { lhs: parsedLhs, rhs: parsedRhs };
                                        props.onEditDiscreteEvent?.(eventIndex(), { ...event, affects: updatedAffects });
                                      } catch {
                                        alert('Invalid JSON format');
                                      }
                                    }
                                  }}
                                >
                                  Edit
                                </button>
                              </Show>
                            </div>
                          )}
                        </For>
                      </div>
                    </div>
                  </div>
                )}
              </For>
            </div>
          </Show>

          <Show when={totalEvents() === 0}>
            <div class="empty-state">
              <div class="empty-icon">⚡</div>
              <div class="empty-text">No events defined</div>
              <Show when={!props.readonly}>
                <div class="empty-actions">
                  <button class="add-first-btn" onClick={props.onAddContinuousEvent}>
                    Add continuous event
                  </button>
                  <button class="add-first-btn" onClick={props.onAddDiscreteEvent}>
                    Add discrete event
                  </button>
                </div>
              </Show>
            </div>
          </Show>
        </div>
      </Show>
    </div>
  );
};

/**
 * Main ModelEditor component
 */
export const ModelEditor: Component<ModelEditorProps> = (props) => {
  const [highlightedVars] = createSignal<Set<string>>(new Set());

  // Handle model modifications
  const handleModelChange = (changes: Partial<Model>) => {
    if (props.readonly || !props.onModelChange) return;

    const newModel = { ...props.model, ...changes };
    props.onModelChange(newModel);
  };

  // Variable management handlers
  const handleAddVariable = () => {
    const name = prompt('Enter variable name:');
    if (!name || !name.trim()) return;

    const type = prompt('Enter variable type (state, parameter, observed, brownian, or discrete):', 'parameter');
    if (!type) return;

    const validTypes: ModelVariable['type'][] = ['state', 'parameter', 'observed', 'brownian', 'discrete'];
    const variableType = (validTypes as string[]).includes(type) ? (type as ModelVariable['type']) : 'parameter';

    const newVariable: ModelVariable = {
      type: variableType,
      units: '',
      description: '',
      ...(variableType === 'parameter' && { default: 0 })
    };

    const newVariables = { ...(props.model.variables || {}), [name.trim()]: newVariable };
    handleModelChange({ variables: newVariables });
  };

  const handleEditVariable = (name: string, variable: ModelVariable) => {
    const newName = prompt('Enter variable name:', name);
    if (!newName || !newName.trim()) return;

    const newDescription = prompt('Enter description:', variable.description || '');
    const newUnit = prompt('Enter unit:', variable.units || '');

    let newDefault = variable.default;
    if (variable.type === 'parameter') {
      const defaultInput = prompt('Enter default value:', String(variable.default ?? 0));
      if (defaultInput !== null) {
        const parsed = parseFloat(defaultInput);
        if (!isNaN(parsed)) {
          newDefault = parsed;
        }
      }
    }

    const updatedVariables = { ...(props.model.variables || {}) };
    if (newName.trim() !== name) {
      delete updatedVariables[name];
    }
    updatedVariables[newName.trim()] = {
      ...variable,
      description: newDescription || '',
      units: newUnit || '',
      ...(variable.type === 'parameter' && { default: newDefault })
    };

    handleModelChange({ variables: updatedVariables });
  };

  const handleRemoveVariable = (name: string) => {
    const updatedVariables = { ...(props.model.variables || {}) };
    delete updatedVariables[name];
    handleModelChange({ variables: updatedVariables });
  };

  // Equation management handlers
  const handleAddEquation = () => {
    const newEquation: Equation = {
      lhs: '_placeholder_',
      rhs: 0
    };
    const newEquations = [...(props.model.equations || []), newEquation];
    handleModelChange({ equations: newEquations });
  };

  const handleEditEquation = (index: number, equation: Equation) => {
    const newEquations = [...(props.model.equations || [])];
    newEquations[index] = equation;
    handleModelChange({ equations: newEquations });
  };

  const handleRemoveEquation = (index: number) => {
    const newEquations = (props.model.equations || []).filter((_, i) => i !== index);
    handleModelChange({ equations: newEquations });
  };

  // Event management handlers
  const handleAddContinuousEvent = () => {
    const name = prompt('Enter event name:', 'New Continuous Event');
    if (!name) return;

    const description = prompt('Enter event description:', '');

    const newEvent: ContinuousEvent = {
      name: name.trim(),
      description: description || '',
      conditions: ['_condition_placeholder'],
      affects: [{
        lhs: '_variable_placeholder',
        rhs: '_value_placeholder'
      }]
    };

    const newContinuousEvents = [...(props.model.continuous_events || []), newEvent];
    handleModelChange({ continuous_events: newContinuousEvents });
  };

  const handleAddDiscreteEvent = () => {
    const name = prompt('Enter event name:', 'New Discrete Event');
    if (!name) return;

    const description = prompt('Enter event description:', '');

    const newEvent: DiscreteEvent = {
      name: name.trim(),
      description: description || '',
      trigger: { type: 'condition', expression: '_trigger_placeholder' },
      affects: [{
        lhs: '_variable_placeholder',
        rhs: '_value_placeholder'
      }]
    };

    const newDiscreteEvents = [...(props.model.discrete_events || []), newEvent];
    handleModelChange({ discrete_events: newDiscreteEvents });
  };

  const handleEditContinuousEvent = (index: number, event: ContinuousEvent) => {
    const updatedEvents = [...(props.model.continuous_events || [])];
    updatedEvents[index] = event;
    handleModelChange({ continuous_events: updatedEvents });
  };

  const handleEditDiscreteEvent = (index: number, event: DiscreteEvent) => {
    const updatedEvents = [...(props.model.discrete_events || [])];
    updatedEvents[index] = event;
    handleModelChange({ discrete_events: updatedEvents });
  };

  const editorClasses = () => {
    const classes = ['model-editor'];
    if (props.readonly) classes.push('readonly');
    if (props.class) classes.push(props.class);
    return classes.join(' ');
  };

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
            <ExpressionPalette
              currentModel={props.model}
              visible={true}
            />
          </div>
        </Show>
      </div>
    </div>
  );
};

export default ModelEditor;
