/**
 * ReactionEditor - Chemical reaction system editor with chemical notation
 *
 * This component provides an interactive editor for reaction systems. Each
 * reaction reads as rendered chemistry (native MathML, `substrates ⟶ products`
 * with the rate set over the arrow); clicking it (when editable) swaps the whole
 * line to a textarea holding the reaction's ascii DSL form — `toAscii` ⇄
 * `parseReaction`, the inverse-of-print syntax used everywhere else. Substrates,
 * products, stoichiometric coefficients, AND the rate are all edited as one text
 * line, e.g. `2 NO + O3 -> [k1] NO2 + O2`.
 * Features:
 * - MathML rendering when not editing (mirrors the EquationEditor surface)
 * - Whole-reaction text editing with parse-blocking + no-churn-when-untouched
 * - Species panel with chemical formulas, default value, and units
 * - Parameter panel listing all parameters
 * - UI for adding/removing reactions
 *
 * Add/edit flows use inline forms (InlineForm) — no blocking prompt()
 * dialogs.
 */

import type { Component } from 'solid-js'
import { createEffect, createSignal, For, Show } from 'solid-js'
import type { ReactionSystem, Reaction, Species, Parameter } from '@earthsciml/ast'
import { toAscii, toMathML, parseReaction } from '@earthsciml/ast'
import { InlineForm } from './InlineForm'
import { CollapsiblePanel } from './CollapsiblePanel'
import { EmptyState } from './EmptyState'
import { createTextEditMode } from './text-edit-mode'
import { renderChemicalName } from '../primitives/chemical-formula'
import './equation-editor.css'

/**
 * Coerce a plain `Reaction[]` into the schema's non-empty-tuple `reactions`
 * type. The editor UI permits a transient empty list — it renders an explicit
 * empty state and an "Add first reaction" affordance — so min-1 schema
 * conformance is enforced at save/validate time, not on every edit. This is the
 * single place that bridges that gap, replacing three scattered ad-hoc casts.
 */
function asReactions(reactions: Reaction[]): ReactionSystem['reactions'] {
  return reactions as ReactionSystem['reactions']
}

/** MathML for a reaction, wrapped in a `<math>` root when needed; '' on failure. */
function toMathMLSafe(node: unknown): string {
  try {
    const ml = toMathML(node as Parameters<typeof toMathML>[0])
    if (!ml) return ''
    return ml.trimStart().startsWith('<math') ? ml : `<math>${ml}</math>`
  } catch {
    return ''
  }
}

export interface ReactionEditorProps {
  /** The reaction system to display and edit */
  reactionSystem: ReactionSystem

  /** Callback when the reaction system is modified */
  onReactionSystemChange?: (newReactionSystem: ReactionSystem) => void

  /** Currently highlighted variable equivalence class */
  highlightedVars?: Set<string>

  /** Whether the editor is in read-only mode */
  readonly?: boolean

  /** CSS class for styling */
  class?: string
}

/** A species paired with its name (the key in the reaction system's species record) */
interface NamedSpecies {
  name: string
  species: Species
}

/** A parameter paired with its name (the key in the reaction system's parameters record) */
interface NamedParameter {
  name: string
  parameter: Parameter
}

/**
 * Component for rendering a single chemical reaction.
 *
 * The default surface is rendered MathML (`substrates ⟶ products` with the rate
 * over the arrow); clicking it (when editable) swaps the whole line to a
 * textarea holding the reaction's ascii DSL form. Substrates, products,
 * coefficients, and the rate are all edited on that one line — mirroring the
 * EquationEditor surface. The shared {@link createTextEditMode} hook owns the
 * buffer/commit/error state plus the block-on-error and emit-only-when-changed
 * invariants, so an untouched reaction stays byte-identical (the reaction
 * printer is non-injective, e.g. `1` coefficients drop out).
 */
const ReactionItem: Component<{
  reaction: Reaction
  index: number
  onEditReaction?: (index: number, reaction: Reaction) => void
  onRemoveReaction?: (index: number) => void
  readonly?: boolean
}> = (props) => {
  const reactionText = createTextEditMode<Reaction>({
    readonly: () => props.readonly,
    seed: () => toAscii(props.reaction),
    parse: (src) => parseReaction(src),
    reprint: (parsed) => toAscii(parsed),
    // parseReaction returns an id-less reaction; merge over the original so its
    // id / name / reference survive and only the edited chemistry is adopted.
    emit: (parsed) =>
      props.onEditReaction?.(props.index, {
        ...props.reaction,
        substrates: parsed.substrates,
        products: parsed.products,
        rate: parsed.rate,
      }),
    initialMode: 'structural',
  })

  const mathml = () => toMathMLSafe(props.reaction)

  // Focus the textarea when the edit surface opens, so a click lands ready to
  // type (parity with EquationEditor). queueMicrotask defers past the render
  // that mounts the textarea.
  let textareaRef: HTMLTextAreaElement | undefined
  createEffect(() => {
    if (reactionText.inTextMode()) queueMicrotask(() => textareaRef?.focus())
  })

  const handleRemove = () => {
    if (!props.readonly) {
      props.onRemoveReaction?.(props.index)
    }
  }

  const enterEdit = () => {
    if (!props.readonly) reactionText.toggleMode()
  }

  return (
    <div class="reaction-item">
      <div class="reaction-header">
        <Show
          when={reactionText.inTextMode()}
          fallback={
            <div
              class={`reaction-equation ${props.readonly ? '' : 'clickable'}`}
              role={props.readonly ? undefined : 'button'}
              tabindex={props.readonly ? undefined : '0'}
              title={props.readonly ? undefined : 'Click to edit reaction'}
              onClick={enterEdit}
              onKeyDown={(e) => {
                if (!props.readonly && (e.key === 'Enter' || e.key === ' ')) {
                  e.preventDefault()
                  enterEdit()
                }
              }}
            >
              <Show
                when={mathml()}
                fallback={<span class="reaction-ascii">{toAscii(props.reaction)}</span>}
              >
                <span class="esm-math" innerHTML={mathml()} />
              </Show>
            </div>
          }
        >
          <div class="reaction-equation-edit esm-eq-text">
            <textarea
              ref={textareaRef}
              class="esm-eq-textarea"
              classList={{ 'has-error': reactionText.error() != null }}
              value={reactionText.text()}
              spellcheck={false}
              rows={2}
              aria-label="Reaction text"
              aria-invalid={reactionText.error() != null}
              onInput={(e) => reactionText.onInput(e.currentTarget.value)}
              // Commit + leave text mode on blur; the shared toggleMode blocks
              // the exit while the buffer fails to parse.
              onBlur={() => reactionText.toggleMode()}
              onKeyDown={reactionText.handleKeyDown}
            />
            <Show when={reactionText.error()}>
              <div class="esm-eq-error" role="alert">
                {reactionText.error()}
              </div>
            </Show>
            <div class="esm-eq-hint">
              e.g. <code>2 NO + O3 -&gt; [k1] NO2 + O2</code> · ⌘⏎ to save · Esc to cancel
            </div>
          </div>
        </Show>

        <div class="reaction-controls">
          <Show when={props.reaction.name}>
            <span class="reaction-name" title="Reaction name">
              {props.reaction.name}
            </span>
          </Show>

          <Show when={!props.readonly}>
            <button
              class="reaction-remove-btn"
              onClick={handleRemove}
              title="Remove reaction"
              aria-label={`Remove reaction ${props.index + 1}`}
            >
              ×
            </button>
          </Show>
        </div>
      </div>
    </div>
  )
}

/**
 * Species panel component
 */
const SpeciesPanel: Component<{
  species?: NamedSpecies[]
  onAddSpecies?: (name: string, species: Species) => void
  onEditSpecies?: (oldName: string, newName: string, species: Species) => void
  onRemoveSpecies?: (name: string) => void
  readonly?: boolean
}> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true)
  const [isAdding, setIsAdding] = createSignal(false)
  const [editingName, setEditingName] = createSignal<string | null>(null)

  const startAdding = () => {
    setIsExpanded(true)
    setEditingName(null)
    setIsAdding(true)
  }

  // Build a Species from the inline-form values. `default` is optional (unlike a
  // Parameter's): an empty value field leaves it unset. `base` carries forward
  // any fields the form doesn't expose (e.g. `constant`, `default_units`) on an
  // edit. Returns an error string when the value field isn't a number.
  const parseSpeciesFields = (
    values: Record<string, string>,
    base: Species = {},
  ): Species | string => {
    const raw = (values.value ?? '').trim()
    let def: number | undefined
    if (raw !== '') {
      const n = Number(raw)
      if (!Number.isFinite(n)) return 'Default value must be a number'
      def = n
    }
    return {
      ...base,
      default: def,
      units: (values.units ?? '').trim() || undefined,
      description: (values.description ?? '').trim() || undefined,
    }
  }

  const handleAddConfirm = (values: Record<string, string>) => {
    const name = values.name.trim()
    if (!name) return 'Species name is required'

    const species = parseSpeciesFields(values)
    if (typeof species === 'string') return species

    props.onAddSpecies?.(name, species)
    setIsAdding(false)
  }

  const handleEditConfirm = (oldName: string, species: Species, values: Record<string, string>) => {
    const newName = values.name.trim()
    if (!newName) return 'Species name is required'

    const updated = parseSpeciesFields(values, species)
    if (typeof updated === 'string') return updated

    props.onEditSpecies?.(oldName, newName, updated)
    setEditingName(null)
  }

  return (
    <CollapsiblePanel
      panelClass="species-panel"
      contentClass="species-content"
      expanded={isExpanded()}
      onToggle={() => setIsExpanded(!isExpanded())}
      title={<h3>Species ({(props.species || []).length})</h3>}
      actions={
        <Show when={!props.readonly}>
          <button
            class="add-btn"
            onClick={(e) => {
              e.stopPropagation()
              startAdding()
            }}
            title="Add new species"
            aria-label="Add new species"
          >
            +
          </button>
        </Show>
      }
    >
      <Show when={isAdding()}>
        <InlineForm
          title="Add species"
          fields={[
            { name: 'name', label: 'Name (chemical formula)', placeholder: 'e.g. NO2' },
            { name: 'value', label: 'Default value' },
            { name: 'units', label: 'Units', placeholder: 'e.g. ppb' },
            { name: 'description', label: 'Description' },
          ]}
          confirmLabel="Add"
          onConfirm={handleAddConfirm}
          onCancel={() => setIsAdding(false)}
        />
      </Show>

      <For each={props.species || []}>
        {(entry) => (
          <Show
            when={editingName() === entry.name}
            fallback={
              <div
                class="species-item"
                onClick={() => {
                  if (!props.readonly) {
                    setIsAdding(false)
                    setEditingName(entry.name)
                  }
                }}
              >
                <div class="species-info">
                  <span class="species-formula">{renderChemicalName(entry.name)}</span>
                  <Show when={renderChemicalName(entry.name) !== entry.name}>
                    <span class="species-name">({entry.name})</span>
                  </Show>
                  <Show when={entry.species.units}>
                    <span class="species-unit">[{entry.species.units}]</span>
                  </Show>
                  <Show when={entry.species.default !== undefined}>
                    <span class="species-value">= {entry.species.default}</span>
                  </Show>
                </div>

                <Show when={entry.species.description}>
                  <div class="species-description">{entry.species.description}</div>
                </Show>

                <Show when={!props.readonly}>
                  <button
                    class="species-remove-btn"
                    onClick={(e) => {
                      e.stopPropagation()
                      props.onRemoveSpecies?.(entry.name)
                    }}
                    title="Remove species"
                    aria-label={`Remove species ${entry.name}`}
                  >
                    ×
                  </button>
                </Show>
              </div>
            }
          >
            <InlineForm
              title={`Edit species ${entry.name}`}
              fields={[
                { name: 'name', label: 'Name', initial: entry.name },
                {
                  name: 'value',
                  label: 'Default value',
                  initial: entry.species.default !== undefined ? String(entry.species.default) : '',
                },
                { name: 'units', label: 'Units', initial: entry.species.units || '' },
                {
                  name: 'description',
                  label: 'Description',
                  initial: entry.species.description || '',
                },
              ]}
              onConfirm={(values) => handleEditConfirm(entry.name, entry.species, values)}
              onCancel={() => setEditingName(null)}
            />
          </Show>
        )}
      </For>

      <Show when={(props.species || []).length === 0 && !isAdding()}>
        <EmptyState icon="🧪" text="No species defined">
          <Show when={!props.readonly}>
            <button class="add-first-btn" onClick={startAdding}>
              Add first species
            </button>
          </Show>
        </EmptyState>
      </Show>
    </CollapsiblePanel>
  )
}

/**
 * Parameters panel component. Lists ALL parameters of the reaction system
 * (no name-based filtering — rate constants are not required to follow any
 * particular naming convention).
 */
const ParametersPanel: Component<{
  parameters?: NamedParameter[]
  onAddParameter?: (name: string, parameter: Parameter) => void
  onEditParameter?: (oldName: string, newName: string, parameter: Parameter) => void
  onRemoveParameter?: (name: string) => void
  readonly?: boolean
}> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true)
  const [isAdding, setIsAdding] = createSignal(false)
  const [editingName, setEditingName] = createSignal<string | null>(null)

  const startAdding = () => {
    setIsExpanded(true)
    setEditingName(null)
    setIsAdding(true)
  }

  const parseParameter = (values: Record<string, string>): Parameter | string => {
    const value = parseFloat(values.value)
    if (values.value.trim() !== '' && isNaN(value)) {
      return 'Default value must be a number'
    }
    return {
      default: isNaN(value) ? 1.0 : value,
      units: values.units || undefined,
      description: values.description || undefined,
    }
  }

  const handleAddConfirm = (values: Record<string, string>) => {
    const name = values.name.trim()
    if (!name) return 'Parameter name is required'

    const parameter = parseParameter(values)
    if (typeof parameter === 'string') return parameter

    props.onAddParameter?.(name, parameter)
    setIsAdding(false)
  }

  const handleEditConfirm = (oldName: string, values: Record<string, string>) => {
    const newName = values.name.trim()
    if (!newName) return 'Parameter name is required'

    const parameter = parseParameter(values)
    if (typeof parameter === 'string') return parameter

    props.onEditParameter?.(oldName, newName, parameter)
    setEditingName(null)
  }

  return (
    <CollapsiblePanel
      panelClass="parameters-panel"
      contentClass="parameters-content"
      expanded={isExpanded()}
      onToggle={() => setIsExpanded(!isExpanded())}
      title={<h3>Parameters ({(props.parameters || []).length})</h3>}
      actions={
        <Show when={!props.readonly}>
          <button
            class="add-btn"
            onClick={(e) => {
              e.stopPropagation()
              startAdding()
            }}
            title="Add new parameter"
            aria-label="Add new parameter"
          >
            +
          </button>
        </Show>
      }
    >
      <Show when={isAdding()}>
        <InlineForm
          title="Add parameter"
          fields={[
            { name: 'name', label: 'Name', placeholder: 'e.g. k_rate' },
            { name: 'value', label: 'Default value', initial: '1.0' },
            { name: 'units', label: 'Units' },
            { name: 'description', label: 'Description' },
          ]}
          confirmLabel="Add"
          onConfirm={handleAddConfirm}
          onCancel={() => setIsAdding(false)}
        />
      </Show>

      <For each={props.parameters || []}>
        {(entry) => (
          <Show
            when={editingName() === entry.name}
            fallback={
              <div
                class="parameter-item"
                onClick={() => {
                  if (!props.readonly) {
                    setIsAdding(false)
                    setEditingName(entry.name)
                  }
                }}
              >
                <div class="parameter-info">
                  <span class="parameter-name">{entry.name}</span>
                  <Show when={entry.parameter.units}>
                    <span class="parameter-unit">[{entry.parameter.units}]</span>
                  </Show>
                  <Show when={entry.parameter.default !== undefined}>
                    <span class="parameter-value">= {entry.parameter.default}</span>
                  </Show>
                </div>

                <Show when={entry.parameter.description}>
                  <div class="parameter-description">{entry.parameter.description}</div>
                </Show>

                <Show when={!props.readonly}>
                  <button
                    class="parameter-remove-btn"
                    onClick={(e) => {
                      e.stopPropagation()
                      props.onRemoveParameter?.(entry.name)
                    }}
                    title="Remove parameter"
                    aria-label={`Remove parameter ${entry.name}`}
                  >
                    ×
                  </button>
                </Show>
              </div>
            }
          >
            <InlineForm
              title={`Edit parameter ${entry.name}`}
              fields={[
                { name: 'name', label: 'Name', initial: entry.name },
                {
                  name: 'value',
                  label: 'Default value',
                  initial: String(entry.parameter.default ?? 1.0),
                },
                { name: 'units', label: 'Units', initial: entry.parameter.units || '' },
                {
                  name: 'description',
                  label: 'Description',
                  initial: entry.parameter.description || '',
                },
              ]}
              onConfirm={(values) => handleEditConfirm(entry.name, values)}
              onCancel={() => setEditingName(null)}
            />
          </Show>
        )}
      </For>

      <Show when={(props.parameters || []).length === 0 && !isAdding()}>
        <EmptyState icon="⚗️" text="No parameters defined">
          <Show when={!props.readonly}>
            <button class="add-first-btn" onClick={startAdding}>
              Add first parameter
            </button>
          </Show>
        </EmptyState>
      </Show>
    </CollapsiblePanel>
  )
}

/**
 * Main ReactionEditor component
 */
export const ReactionEditor: Component<ReactionEditorProps> = (props) => {
  // Handle reaction system modifications
  const handleReactionSystemChange = (changes: Partial<ReactionSystem>) => {
    if (props.readonly || !props.onReactionSystemChange) return

    const newReactionSystem = { ...props.reactionSystem, ...changes }
    props.onReactionSystemChange(newReactionSystem)
  }

  // First `R{n}` id not already taken. Using `reactions.length + 1` collides
  // after a deletion (e.g. delete R2 of R1/R2/R3 → next id R3, already in use).
  const nextReactionId = (): string => {
    const existing = new Set((props.reactionSystem.reactions || []).map((r) => r.id))
    let n = 1
    while (existing.has(`R${n}`)) n++
    return `R${n}`
  }

  // Reaction management handlers
  const handleAddReaction = () => {
    const newReaction: Reaction = {
      id: nextReactionId(),
      substrates: [{ species: 'A', stoichiometry: 1 }],
      products: [{ species: 'B', stoichiometry: 1 }],
      rate: 'k_rate',
    }
    const newReactions = [...(props.reactionSystem.reactions || []), newReaction]
    handleReactionSystemChange({ reactions: asReactions(newReactions) })
  }

  const handleEditReaction = (index: number, reaction: Reaction) => {
    const newReactions = [...(props.reactionSystem.reactions || [])]
    newReactions[index] = reaction
    handleReactionSystemChange({ reactions: asReactions(newReactions) })
  }

  const handleRemoveReaction = (index: number) => {
    const newReactions = (props.reactionSystem.reactions || []).filter((_, i) => i !== index)
    handleReactionSystemChange({ reactions: asReactions(newReactions) })
  }

  // Species management handlers
  const handleAddSpecies = (name: string, species: Species) => {
    const updatedSpecies = {
      ...(props.reactionSystem.species || {}),
      [name]: species,
    }
    handleReactionSystemChange({ species: updatedSpecies })
  }

  const handleEditSpecies = (oldName: string, newName: string, species: Species) => {
    const updatedSpecies = { ...(props.reactionSystem.species || {}) }

    // Remove old species if name changed
    if (newName !== oldName) {
      delete updatedSpecies[oldName]
    }

    updatedSpecies[newName] = species
    handleReactionSystemChange({ species: updatedSpecies })
  }

  const handleRemoveSpecies = (name: string) => {
    // window.confirm is intentionally kept for this destructive action:
    // removing a species can silently break every reaction that references
    // it, and the species list has no undo affordance of its own. A native
    // blocking confirm is the conservative guard until a proper non-blocking
    // confirmation UI exists.
    if (!confirm(`Remove species "${name}"? This may affect reactions that reference it.`)) return

    const updatedSpecies = { ...(props.reactionSystem.species || {}) }
    delete updatedSpecies[name]
    handleReactionSystemChange({ species: updatedSpecies })
  }

  // Parameter management handlers
  const handleAddParameter = (name: string, parameter: Parameter) => {
    const updatedParameters = {
      ...(props.reactionSystem.parameters || {}),
      [name]: parameter,
    }
    handleReactionSystemChange({ parameters: updatedParameters })
  }

  const handleEditParameter = (oldName: string, newName: string, parameter: Parameter) => {
    const updatedParameters = { ...(props.reactionSystem.parameters || {}) }

    // Remove old parameter if name changed
    if (newName !== oldName) {
      delete updatedParameters[oldName]
    }

    updatedParameters[newName] = parameter
    handleReactionSystemChange({ parameters: updatedParameters })
  }

  const handleRemoveParameter = (name: string) => {
    // window.confirm intentionally kept for destructive delete — see
    // handleRemoveSpecies for the rationale.
    if (!confirm(`Remove parameter "${name}"? This may affect reactions that reference it.`)) return

    const updatedParameters = { ...(props.reactionSystem.parameters || {}) }
    delete updatedParameters[name]

    handleReactionSystemChange({ parameters: updatedParameters })
  }

  const editorClasses = () => {
    const classes = ['reaction-editor']
    if (props.readonly) classes.push('readonly')
    if (props.class) classes.push(props.class)
    return classes.join(' ')
  }

  return (
    <div class={editorClasses()}>
      <div class="reaction-editor-layout">
        {/* Main reactions panel */}
        <div class="reactions-main">
          <div class="reactions-header">
            <h2>Reactions ({(props.reactionSystem.reactions || []).length})</h2>
            <Show when={!props.readonly}>
              <button class="add-reaction-btn" onClick={handleAddReaction} title="Add new reaction">
                + Add Reaction
              </button>
            </Show>
          </div>

          <div class="reactions-list">
            <For each={props.reactionSystem.reactions || []}>
              {(reaction, index) => (
                <ReactionItem
                  reaction={reaction}
                  index={index()}
                  onEditReaction={handleEditReaction}
                  onRemoveReaction={handleRemoveReaction}
                  readonly={props.readonly}
                />
              )}
            </For>

            <Show when={(props.reactionSystem.reactions || []).length === 0}>
              <EmptyState icon="⚛️" text="No reactions defined">
                <Show when={!props.readonly}>
                  <button class="add-first-btn" onClick={handleAddReaction}>
                    Add first reaction
                  </button>
                </Show>
              </EmptyState>
            </Show>
          </div>
        </div>

        {/* Side panels */}
        <div class="reaction-sidebar">
          <SpeciesPanel
            species={Object.entries(props.reactionSystem.species || {}).map(([name, species]) => ({
              name,
              species,
            }))}
            onAddSpecies={handleAddSpecies}
            onEditSpecies={handleEditSpecies}
            onRemoveSpecies={handleRemoveSpecies}
            readonly={props.readonly}
          />

          <ParametersPanel
            parameters={Object.entries(props.reactionSystem.parameters || {}).map(
              ([name, parameter]) => ({
                name,
                parameter,
              }),
            )}
            onAddParameter={handleAddParameter}
            onEditParameter={handleEditParameter}
            onRemoveParameter={handleRemoveParameter}
            readonly={props.readonly}
          />
        </div>
      </div>
    </div>
  )
}

export default ReactionEditor
