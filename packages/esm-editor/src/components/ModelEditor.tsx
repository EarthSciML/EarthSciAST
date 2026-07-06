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
 */

import { Component, createSignal, createMemo, For, Show } from 'solid-js';
import type { Model, ModelVariable, Equation, ContinuousEvent, DiscreteEvent, Expression } from 'earthsci-toolkit';
import { EquationEditor } from './EquationEditor';
import { ExpressionPalette } from './ExpressionPalette';
import { InlineForm } from './InlineForm';
import {
  EXPRESSION_PLACEHOLDER,
  CONDITION_PLACEHOLDER,
  TRIGGER_PLACEHOLDER,
  VARIABLE_PLACEHOLDER,
  VALUE_PLACEHOLDER
} from '../constants';

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

const VARIABLE_TYPES = ['state', 'parameter', 'observed', 'brownian', 'discrete'] as const;

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

/** Parse a JSON expression string, or return null when invalid */
function tryParseJson(text: string): { value: Expression } | null {
  try {
    return { value: JSON.parse(text) };
  } catch {
    return null;
  }
}

const INVALID_JSON_MESSAGE = 'Invalid JSON format';

/**
 * Component for individual variable item in the variables panel
 */
const VariableItem: Component<{
  name: string;
  variable: ModelVariable;
  type: VariableType;
  onEdit?: (name: string, variable: ModelVariable) => void;
  onRemove?: (name: string) => void;
  onHover?: (name: string | null) => void;
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
      onMouseEnter={() => { setIsHovered(true); props.onHover?.(props.name); }}
      onMouseLeave={() => { setIsHovered(false); props.onHover?.(null); }}
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
  onAddVariable?: (name: string, variable: ModelVariable) => void;
  onEditVariable?: (oldName: string, newName: string, variable: ModelVariable) => void;
  onRemoveVariable?: (name: string) => void;
  onVariableHover?: (name: string | null) => void;
  readonly?: boolean;
}> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true);
  const [isAdding, setIsAdding] = createSignal(false);
  const [editingName, setEditingName] = createSignal<string | null>(null);

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

  const startAdding = () => {
    setIsExpanded(true);
    setEditingName(null);
    setIsAdding(true);
  };

  const handleAddConfirm = (values: Record<string, string>) => {
    const name = values.name.trim();
    if (!name) return 'Variable name is required';

    const type = (VARIABLE_TYPES as readonly string[]).includes(values.type)
      ? (values.type as ModelVariable['type'])
      : 'parameter';

    const newVariable: ModelVariable = {
      type,
      units: values.units || '',
      description: values.description || '',
      ...(type === 'parameter' && { default: 0 })
    };

    props.onAddVariable?.(name, newVariable);
    setIsAdding(false);
  };

  const handleEditConfirm = (oldName: string, variable: ModelVariable, values: Record<string, string>) => {
    const newName = values.name.trim();
    if (!newName) return 'Variable name is required';

    let newDefault = variable.default;
    if (variable.type === 'parameter' && values.default !== undefined) {
      const parsed = parseFloat(values.default);
      if (values.default.trim() !== '' && isNaN(parsed)) {
        return 'Default value must be a number';
      }
      if (!isNaN(parsed)) {
        newDefault = parsed;
      }
    }

    props.onEditVariable?.(oldName, newName, {
      ...variable,
      description: values.description || '',
      units: values.units || '',
      ...(variable.type === 'parameter' && { default: newDefault })
    });
    setEditingName(null);
  };

  return (
    <div class="variables-panel">
      <div class="panel-header" onClick={() => setIsExpanded(!isExpanded())}>
        <span class={`expand-icon ${isExpanded() ? 'expanded' : ''}`}>▶</span>
        <h3>Variables ({variableEntries().length})</h3>
        <Show when={!props.readonly}>
          <button
            class="add-btn"
            onClick={(e) => { e.stopPropagation(); startAdding(); }}
            title="Add new variable"
            aria-label="Add new variable"
          >
            +
          </button>
        </Show>
      </div>

      <Show when={isExpanded()}>
        <div class="variables-content">
          <Show when={isAdding()}>
            <InlineForm
              title="Add variable"
              fields={[
                { name: 'name', label: 'Name', placeholder: 'e.g. O3' },
                { name: 'type', label: 'Type', options: VARIABLE_TYPES, initial: 'parameter' },
                { name: 'units', label: 'Units', placeholder: 'e.g. mol/mol' },
                { name: 'description', label: 'Description' }
              ]}
              confirmLabel="Add"
              onConfirm={handleAddConfirm}
              onCancel={() => setIsAdding(false)}
            />
          </Show>

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
                        <Show
                          when={editingName() === entry.name}
                          fallback={
                            <VariableItem
                              name={entry.name}
                              variable={entry.variable}
                              type={type}
                              onEdit={(name) => { setIsAdding(false); setEditingName(name); }}
                              onRemove={props.onRemoveVariable}
                              onHover={props.onVariableHover}
                              readonly={props.readonly}
                            />
                          }
                        >
                          <InlineForm
                            title={`Edit variable ${entry.name}`}
                            fields={[
                              { name: 'name', label: 'Name', initial: entry.name },
                              { name: 'description', label: 'Description', initial: entry.variable.description || '' },
                              { name: 'units', label: 'Units', initial: entry.variable.units || '' },
                              ...(entry.variable.type === 'parameter'
                                ? [{ name: 'default', label: 'Default value', initial: String(entry.variable.default ?? 0) }]
                                : [])
                            ]}
                            onConfirm={(values) => handleEditConfirm(entry.name, entry.variable, values)}
                            onCancel={() => setEditingName(null)}
                          />
                        </Show>
                      )}
                    </For>
                  </div>
                </div>
              </Show>
            )}
          </For>

          <Show when={variableEntries().length === 0 && !isAdding()}>
            <div class="empty-state">
              <div class="empty-icon">📊</div>
              <div class="empty-text">No variables defined</div>
              <Show when={!props.readonly}>
                <button class="add-first-btn" onClick={startAdding}>
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

/** Identifies which event sub-item is currently being edited inline */
type EventEditTarget =
  | { kind: 'condition'; eventIndex: number; index: number }
  | { kind: 'continuous-affect'; eventIndex: number; index: number }
  | { kind: 'discrete-affect'; eventIndex: number; index: number }
  | { kind: 'trigger'; eventIndex: number };

/**
 * Events panel component
 */
const EventsPanel: Component<{
  continuousEvents?: ContinuousEvent[];
  discreteEvents?: DiscreteEvent[];
  onAddContinuousEvent?: (name: string, description: string) => void;
  onAddDiscreteEvent?: (name: string, description: string) => void;
  onEditContinuousEvent?: (index: number, event: ContinuousEvent) => void;
  onEditDiscreteEvent?: (index: number, event: DiscreteEvent) => void;
  readonly?: boolean;
}> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true);
  const [addingKind, setAddingKind] = createSignal<'continuous' | 'discrete' | null>(null);
  const [editTarget, setEditTarget] = createSignal<EventEditTarget | null>(null);

  const totalEvents = () =>
    (props.continuousEvents || []).length + (props.discreteEvents || []).length;

  const isEditing = (target: EventEditTarget) => {
    const current = editTarget();
    if (!current || current.kind !== target.kind || current.eventIndex !== target.eventIndex) {
      return false;
    }
    return !('index' in target) || !('index' in current) || current.index === target.index;
  };

  const startAdding = (kind: 'continuous' | 'discrete') => {
    setIsExpanded(true);
    setEditTarget(null);
    setAddingKind(kind);
  };

  const handleAddConfirm = (values: Record<string, string>) => {
    const name = values.name.trim();
    if (!name) return 'Event name is required';

    if (addingKind() === 'continuous') {
      props.onAddContinuousEvent?.(name, values.description || '');
    } else {
      props.onAddDiscreteEvent?.(name, values.description || '');
    }
    setAddingKind(null);
  };

  const handleConditionConfirm = (event: ContinuousEvent, eventIndex: number, index: number, values: Record<string, string>) => {
    const parsed = tryParseJson(values.condition);
    if (!parsed) return INVALID_JSON_MESSAGE;

    const updatedConditions = [...event.conditions] as ContinuousEvent['conditions'];
    updatedConditions[index] = parsed.value;
    props.onEditContinuousEvent?.(eventIndex, { ...event, conditions: updatedConditions });
    setEditTarget(null);
  };

  const handleAffectConfirm = (
    kind: 'continuous-affect' | 'discrete-affect',
    event: ContinuousEvent | DiscreteEvent,
    eventIndex: number,
    index: number,
    values: Record<string, string>
  ) => {
    const parsedLhs = tryParseJson(values.lhs);
    const parsedRhs = tryParseJson(values.rhs);
    if (!parsedLhs || !parsedRhs) return INVALID_JSON_MESSAGE;

    const updatedAffects = [...(event.affects || [])];
    updatedAffects[index] = { lhs: parsedLhs.value, rhs: parsedRhs.value } as (typeof updatedAffects)[number];

    if (kind === 'continuous-affect') {
      props.onEditContinuousEvent?.(eventIndex, {
        ...(event as ContinuousEvent),
        affects: updatedAffects as ContinuousEvent['affects']
      });
    } else {
      props.onEditDiscreteEvent?.(eventIndex, {
        ...(event as DiscreteEvent),
        affects: updatedAffects as DiscreteEvent['affects']
      });
    }
    setEditTarget(null);
  };

  const handleTriggerConfirm = (event: DiscreteEvent, eventIndex: number, values: Record<string, string>) => {
    const parsed = tryParseJson(values.trigger);
    if (!parsed) return INVALID_JSON_MESSAGE;

    props.onEditDiscreteEvent?.(eventIndex, { ...event, trigger: parsed.value as DiscreteEvent['trigger'] });
    setEditTarget(null);
  };

  /** Shared affect list rendering for continuous and discrete events */
  const affectsList = (
    kind: 'continuous-affect' | 'discrete-affect',
    event: ContinuousEvent | DiscreteEvent,
    eventIndex: number
  ) => (
    <div class="event-affects">
      <strong>Effects:</strong>
      <For each={event.affects || []}>
        {(affect, index) => (
          <div class="affect-item">
            <code class="affect-expr">
              {JSON.stringify(affect.lhs)} = {JSON.stringify(affect.rhs)}
            </code>
            <Show when={!props.readonly}>
              <Show
                when={isEditing({ kind, eventIndex, index: index() })}
                fallback={
                  <button
                    class="edit-btn"
                    onClick={() => setEditTarget({ kind, eventIndex, index: index() })}
                  >
                    Edit
                  </button>
                }
              >
                <InlineForm
                  title="Edit effect"
                  fields={[
                    { name: 'lhs', label: 'Left side (JSON)', initial: JSON.stringify(affect.lhs), multiline: true },
                    { name: 'rhs', label: 'Right side (JSON)', initial: JSON.stringify(affect.rhs), multiline: true }
                  ]}
                  onConfirm={(values) => handleAffectConfirm(kind, event, eventIndex, index(), values)}
                  onCancel={() => setEditTarget(null)}
                />
              </Show>
            </Show>
          </div>
        )}
      </For>
    </div>
  );

  return (
    <div class="events-panel">
      <div class="panel-header" onClick={() => setIsExpanded(!isExpanded())}>
        <span class={`expand-icon ${isExpanded() ? 'expanded' : ''}`}>▶</span>
        <h3>Events ({totalEvents()})</h3>
        <Show when={!props.readonly}>
          <div class="event-add-buttons">
            <button
              class="add-btn"
              onClick={(e) => { e.stopPropagation(); startAdding('continuous'); }}
              title="Add continuous event"
            >
              + Continuous
            </button>
            <button
              class="add-btn"
              onClick={(e) => { e.stopPropagation(); startAdding('discrete'); }}
              title="Add discrete event"
            >
              + Discrete
            </button>
          </div>
        </Show>
      </div>

      <Show when={isExpanded()}>
        <div class="events-content">
          <Show when={addingKind()}>
            <InlineForm
              title={addingKind() === 'continuous' ? 'Add continuous event' : 'Add discrete event'}
              fields={[
                { name: 'name', label: 'Name', initial: addingKind() === 'continuous' ? 'New Continuous Event' : 'New Discrete Event' },
                { name: 'description', label: 'Description' }
              ]}
              confirmLabel="Add"
              onConfirm={handleAddConfirm}
              onCancel={() => setAddingKind(null)}
            />
          </Show>

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
                                <Show
                                  when={isEditing({ kind: 'condition', eventIndex: eventIndex(), index: index() })}
                                  fallback={
                                    <button
                                      class="edit-btn"
                                      onClick={() => setEditTarget({ kind: 'condition', eventIndex: eventIndex(), index: index() })}
                                    >
                                      Edit
                                    </button>
                                  }
                                >
                                  <InlineForm
                                    title="Edit condition"
                                    fields={[
                                      { name: 'condition', label: 'Condition (JSON)', initial: JSON.stringify(condition), multiline: true }
                                    ]}
                                    onConfirm={(values) => handleConditionConfirm(event, eventIndex(), index(), values)}
                                    onCancel={() => setEditTarget(null)}
                                  />
                                </Show>
                              </Show>
                            </div>
                          )}
                        </For>
                      </div>
                      {affectsList('continuous-affect', event, eventIndex())}
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
                            <Show
                              when={isEditing({ kind: 'trigger', eventIndex: eventIndex() })}
                              fallback={
                                <button
                                  class="edit-btn"
                                  onClick={() => setEditTarget({ kind: 'trigger', eventIndex: eventIndex() })}
                                >
                                  Edit
                                </button>
                              }
                            >
                              <InlineForm
                                title="Edit trigger"
                                fields={[
                                  { name: 'trigger', label: 'Trigger (JSON)', initial: JSON.stringify(event.trigger), multiline: true }
                                ]}
                                onConfirm={(values) => handleTriggerConfirm(event, eventIndex(), values)}
                                onCancel={() => setEditTarget(null)}
                              />
                            </Show>
                          </Show>
                        </div>
                      </div>
                      {affectsList('discrete-affect', event, eventIndex())}
                    </div>
                  </div>
                )}
              </For>
            </div>
          </Show>

          <Show when={totalEvents() === 0 && !addingKind()}>
            <div class="empty-state">
              <div class="empty-icon">⚡</div>
              <div class="empty-text">No events defined</div>
              <Show when={!props.readonly}>
                <div class="empty-actions">
                  <button class="add-first-btn" onClick={() => startAdding('continuous')}>
                    Add continuous event
                  </button>
                  <button class="add-first-btn" onClick={() => startAdding('discrete')}>
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
  // Highlighting is driven by hovering variables in the variables panel:
  // the hovered variable is highlighted in the equation list.
  const [highlightedVars, setHighlightedVars] = createSignal<Set<string>>(new Set());

  const handleVariableHover = (name: string | null) => {
    setHighlightedVars(name ? new Set([name]) : new Set<string>());
  };

  // Handle model modifications
  const handleModelChange = (changes: Partial<Model>) => {
    if (props.readonly || !props.onModelChange) return;

    const newModel = { ...props.model, ...changes };
    props.onModelChange(newModel);
  };

  // Variable management handlers
  const handleAddVariable = (name: string, variable: ModelVariable) => {
    const newVariables = { ...(props.model.variables || {}), [name]: variable };
    handleModelChange({ variables: newVariables });
  };

  const handleEditVariable = (oldName: string, newName: string, variable: ModelVariable) => {
    const updatedVariables = { ...(props.model.variables || {}) };
    if (newName !== oldName) {
      delete updatedVariables[oldName];
    }
    updatedVariables[newName] = variable;
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
      lhs: EXPRESSION_PLACEHOLDER,
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
  const handleAddContinuousEvent = (name: string, description: string) => {
    const newEvent: ContinuousEvent = {
      name,
      description,
      conditions: [CONDITION_PLACEHOLDER],
      affects: [{
        lhs: VARIABLE_PLACEHOLDER,
        rhs: VALUE_PLACEHOLDER
      }]
    };

    const newContinuousEvents = [...(props.model.continuous_events || []), newEvent];
    handleModelChange({ continuous_events: newContinuousEvents });
  };

  const handleAddDiscreteEvent = (name: string, description: string) => {
    const newEvent: DiscreteEvent = {
      name,
      description,
      trigger: { type: 'condition', expression: TRIGGER_PLACEHOLDER },
      affects: [{
        lhs: VARIABLE_PLACEHOLDER,
        rhs: VALUE_PLACEHOLDER
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
