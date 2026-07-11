/**
 * VariableItem - a single row in the model VariablesPanel.
 *
 * Also the home of the variable-type metadata (labels, badge colors,
 * descriptions) shared with VariablesPanel.
 */

import { Component, createSignal, Show } from 'solid-js';
import type { Model, ModelVariable } from '@earthsciml/ast';

/** Variable categorization, including a catch-all for unrecognized types. */
export type VariableType = ModelVariable['type'] | 'other';

/** The variable types offered in the add/edit forms. */
export const VARIABLE_TYPES = ['state', 'parameter', 'observed', 'brownian', 'discrete'] as const;

/** Badge configuration for the different variable types. */
export const VARIABLE_TYPE_CONFIG: Record<VariableType, { label: string; color: string; description: string }> = {
  state: { label: 'State', color: 'blue', description: 'State variable' },
  parameter: { label: 'Param', color: 'green', description: 'Parameter' },
  observed: { label: 'Obs', color: 'orange', description: 'Observed variable' },
  brownian: { label: 'Brownian', color: 'purple', description: 'Brownian variable' },
  discrete: { label: 'Discrete', color: 'teal', description: 'Discrete variable' },
  other: { label: 'Var', color: 'gray', description: 'Variable' }
};

/** A model variable paired with its name (the key in the model's variables record). */
export interface NamedVariable {
  name: string;
  variable: ModelVariable;
}

/** The variables record shape on a Model. */
export type ModelVariables = Model['variables'];

export interface VariableItemProps {
  name: string;
  variable: ModelVariable;
  type: VariableType;
  onEdit?: (name: string, variable: ModelVariable) => void;
  onRemove?: (name: string) => void;
  onHover?: (name: string | null) => void;
  readonly?: boolean;
}

export const VariableItem: Component<VariableItemProps> = (props) => {
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

export default VariableItem;
