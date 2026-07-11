/**
 * VariablesPanel - collapsible panel listing a model's variables grouped by
 * type, with inline add/edit forms.
 */

import { Component, createSignal, createMemo, For, Show } from 'solid-js';
import type { ModelVariable } from '@earthsciml/ast';
import { InlineForm } from './InlineForm';
import { CollapsiblePanel } from './CollapsiblePanel';
import { EmptyState } from './EmptyState';
import {
  VariableItem,
  VARIABLE_TYPES,
  VARIABLE_TYPE_CONFIG,
  type VariableType,
  type NamedVariable,
  type ModelVariables
} from './VariableItem';

export interface VariablesPanelProps {
  variables?: ModelVariables;
  onAddVariable?: (name: string, variable: ModelVariable) => void;
  onEditVariable?: (oldName: string, newName: string, variable: ModelVariable) => void;
  onRemoveVariable?: (name: string) => void;
  onVariableHover?: (name: string | null) => void;
  readonly?: boolean;
}

export const VariablesPanel: Component<VariablesPanelProps> = (props) => {
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
    <CollapsiblePanel
      panelClass="variables-panel"
      contentClass="variables-content"
      expanded={isExpanded()}
      onToggle={() => setIsExpanded(!isExpanded())}
      title={<h3>Variables ({variableEntries().length})</h3>}
      actions={
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
      }
    >
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
        <EmptyState icon="📊" text="No variables defined">
          <Show when={!props.readonly}>
            <button class="add-first-btn" onClick={startAdding}>
              Add first variable
            </button>
          </Show>
        </EmptyState>
      </Show>
    </CollapsiblePanel>
  );
};

export default VariablesPanel;
