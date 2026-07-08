/**
 * InlineForm - Small inline edit form with confirm/cancel buttons
 *
 * Replaces blocking browser dialogs (prompt/alert) for editing flows in
 * ModelEditor and ReactionEditor. Renders labelled text inputs, textareas,
 * or selects, and reports validation errors inline instead of via alert().
 */

import { Component, For, Show, Switch, Match, createSignal } from 'solid-js';
import './inline-form.css';

export interface InlineFormField {
  /** Key of this field in the submitted values record */
  name: string;
  /** Visible label */
  label: string;
  /** Initial value */
  initial?: string;
  /** Placeholder text */
  placeholder?: string;
  /** Render a textarea instead of an input (for JSON/expressions) */
  multiline?: boolean;
  /** Render a select with these options instead of a free-text input */
  options?: readonly string[];
}

export interface InlineFormProps {
  /** Optional form heading */
  title?: string;
  /** Field definitions */
  fields: InlineFormField[];
  /** Label for the confirm button (default "Save") */
  confirmLabel?: string;
  /** Extra CSS class */
  class?: string;
  /**
   * Called with the field values on confirm. Return an error message to
   * keep the form open and display the error inline; return nothing on
   * success (the caller is responsible for closing the form).
   */
  onConfirm: (values: Record<string, string>) => string | null | undefined | void;
  /** Called when editing is cancelled */
  onCancel: () => void;
}

export const InlineForm: Component<InlineFormProps> = (props) => {
  // Initial field values are intentionally captured once per form instance
  const initialValues = Object.fromEntries(
    props.fields.map(field => [field.name, field.initial ?? ''])
  );
  const [values, setValues] = createSignal<Record<string, string>>(initialValues);
  const [error, setError] = createSignal<string | null>(null);

  const setValue = (name: string, value: string) => {
    setValues(prev => ({ ...prev, [name]: value }));
  };

  const handleSubmit = (e: Event) => {
    e.preventDefault();
    const result = props.onConfirm(values());
    setError(typeof result === 'string' ? result : null);
  };

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      props.onCancel();
    }
  };

  return (
    <form
      class={`inline-form${props.class ? ` ${props.class}` : ''}`}
      onSubmit={handleSubmit}
      onKeyDown={handleKeyDown}
    >
      <Show when={props.title}>
        <div class="inline-form-title">{props.title}</div>
      </Show>

      <For each={props.fields}>
        {(field) => (
          <label class="inline-form-field">
            <span class="inline-form-label">{field.label}</span>
            <Switch
              fallback={
                <input
                  type="text"
                  class="inline-form-input"
                  value={values()[field.name] ?? ''}
                  placeholder={field.placeholder}
                  onInput={(e) => setValue(field.name, e.currentTarget.value)}
                />
              }
            >
              <Match when={field.options}>
                <select
                  class="inline-form-select"
                  value={values()[field.name] ?? ''}
                  onChange={(e) => setValue(field.name, e.currentTarget.value)}
                >
                  <For each={field.options}>
                    {(option) => <option value={option}>{option}</option>}
                  </For>
                </select>
              </Match>
              <Match when={field.multiline}>
                <textarea
                  class="inline-form-textarea"
                  value={values()[field.name] ?? ''}
                  placeholder={field.placeholder}
                  rows={3}
                  onInput={(e) => setValue(field.name, e.currentTarget.value)}
                />
              </Match>
            </Switch>
          </label>
        )}
      </For>

      <Show when={error()}>
        <div class="inline-form-error" role="alert">{error()}</div>
      </Show>

      <div class="inline-form-actions">
        <button type="submit" class="inline-form-confirm">
          {props.confirmLabel ?? 'Save'}
        </button>
        <button type="button" class="inline-form-cancel" onClick={props.onCancel}>
          Cancel
        </button>
      </div>
    </form>
  );
};

export default InlineForm;
