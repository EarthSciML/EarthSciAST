/**
 * EquationsPanel - collapsible panel listing a model's equations, each rendered
 * with an EquationEditor and a remove control.
 */

import type { Component } from 'solid-js'
import { createSignal, For, Show } from 'solid-js'
import type { Equation } from '@earthsciml/ast'
import { EquationEditor } from './EquationEditor'
import { CollapsiblePanel } from './CollapsiblePanel'
import { EmptyState } from './EmptyState'

export interface EquationsPanelProps {
  equations?: Equation[]
  highlightedVars?: Set<string>
  onAddEquation?: () => void
  onEditEquation?: (index: number, equation: Equation) => void
  onRemoveEquation?: (index: number) => void
  readonly?: boolean
}

export const EquationsPanel: Component<EquationsPanelProps> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true)

  return (
    <CollapsiblePanel
      panelClass="equations-panel"
      contentClass="equations-content"
      expanded={isExpanded()}
      onToggle={() => setIsExpanded(!isExpanded())}
      title={<h3>Equations ({(props.equations || []).length})</h3>}
      actions={
        <Show when={!props.readonly}>
          <button
            class="add-btn"
            onClick={(e) => {
              e.stopPropagation()
              props.onAddEquation?.()
            }}
            title="Add new equation"
            aria-label="Add new equation"
          >
            +
          </button>
        </Show>
      }
    >
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
        <EmptyState icon="⚖️" text="No equations defined">
          <Show when={!props.readonly}>
            <button class="add-first-btn" onClick={props.onAddEquation}>
              Add first equation
            </button>
          </Show>
        </EmptyState>
      </Show>
    </CollapsiblePanel>
  )
}

export default EquationsPanel
