/**
 * ReactionEditor - Chemical reaction system editor with chemical notation
 *
 * This component provides an interactive editor for reaction systems,
 * displaying reactions in chemical notation (e.g., NO + O₃ →[k] NO₂)
 * with clickable rate expressions that expand to full ExpressionEditor.
 * Features:
 * - Chemical notation display with proper subscripts (shared element-aware
 *   renderer, identical to ExpressionNode's variable rendering)
 * - Species panel with chemical formulas
 * - Parameter panel listing all parameters
 * - UI for adding/removing reactions
 *
 * Add/edit flows use inline forms (InlineForm) — no blocking prompt()
 * dialogs.
 */

import { Component, createSignal, For, Show } from 'solid-js';
import type { ReactionSystem, Reaction, Species, Parameter, Expression } from '@earthsciml/ast';
import { ExpressionNode } from './ExpressionNode';
import { InlineForm } from './InlineForm';
import { CollapsiblePanel } from './CollapsiblePanel';
import { EmptyState } from './EmptyState';
import { createMergedHighlight } from './merged-highlight';
import { replaceAtDocumentPath } from './document-path';
import { renderChemicalName } from '../primitives/chemical-formula';

/**
 * Coerce a plain `Reaction[]` into the schema's non-empty-tuple `reactions`
 * type. The editor UI permits a transient empty list — it renders an explicit
 * empty state and an "Add first reaction" affordance — so min-1 schema
 * conformance is enforced at save/validate time, not on every edit. This is the
 * single place that bridges that gap, replacing three scattered ad-hoc casts.
 */
function asReactions(reactions: Reaction[]): ReactionSystem['reactions'] {
  return reactions as ReactionSystem['reactions'];
}

/**
 * Render a substrate/product list in chemical notation (e.g. `2NO + O₃`).
 * Shared by the reactants and products sides, which are byte-identical.
 */
function renderSpeciesList(entries: Reaction['substrates'] | Reaction['products']): string {
  if (!entries) return '';

  return entries
    .map((entry) => {
      const formula = renderChemicalName(entry.species);
      const stoichiometry = entry.stoichiometry ?? 1;
      return `${stoichiometry !== 1 ? stoichiometry : ''}${formula}`;
    })
    .join(' + ');
}

export interface ReactionEditorProps {
  /** The reaction system to display and edit */
  reactionSystem: ReactionSystem;

  /** Callback when the reaction system is modified */
  onReactionSystemChange?: (newReactionSystem: ReactionSystem) => void;

  /** Currently highlighted variable equivalence class */
  highlightedVars?: Set<string>;

  /** Whether the editor is in read-only mode */
  readonly?: boolean;

  /** CSS class for styling */
  class?: string;
}

/** A species paired with its name (the key in the reaction system's species record) */
interface NamedSpecies {
  name: string;
  species: Species;
}

/** A parameter paired with its name (the key in the reaction system's parameters record) */
interface NamedParameter {
  name: string;
  parameter: Parameter;
}

/**
 * Component for rendering a single chemical reaction
 */
const ReactionItem: Component<{
  reaction: Reaction;
  index: number;
  onEditReaction?: (index: number, reaction: Reaction) => void;
  onRemoveReaction?: (index: number) => void;
  highlightedVars?: Set<string>;
  readonly?: boolean;
}> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(false);
  const [selectedPath, setSelectedPath] = createSignal<(string | number)[] | null>(null);
  const [hoveredVar, setHoveredVar] = createSignal<string | null>(null);

  // Base highlight set merged with the locally hovered variable.
  const highlightedVars = createMergedHighlight(() => props.highlightedVars, hoveredVar);

  // Handle rate expression editing
  const handleRateClick = () => {
    if (!props.readonly) {
      setIsExpanded(!isExpanded());
    }
  };

  const handleRateChange = (newRate: Expression) => {
    if (props.readonly || !props.onEditReaction) return;

    const newReaction = { ...props.reaction, rate: newRate };
    props.onEditReaction(props.index, newReaction);
  };

  // Apply an edit from anywhere in the rate subtree. Paths are rooted at the
  // reaction (`['rate']`, `['rate', 'args', 0]`, …); nested edits previously
  // fell through a `path === ['rate']` guard and were silently dropped.
  const handleReplace = (path: (string | number)[], newExpr: Expression) => {
    if (props.readonly || !props.onEditReaction) return;

    const newReaction = replaceAtDocumentPath(props.reaction, path, newExpr);
    props.onEditReaction(props.index, newReaction);
  };

  const handleRemove = () => {
    if (!props.readonly) {
      props.onRemoveReaction?.(props.index);
    }
  };

  return (
    <div class="reaction-item">
      <div class="reaction-header">
        <div class="reaction-equation">
          {/* Substrates (reactants) */}
          <span class="reactants">{renderSpeciesList(props.reaction.substrates)}</span>

          {/* Arrow with rate */}
          <span class="reaction-arrow">
            →
            <span
              class={`rate-expression ${isExpanded() ? 'expanded' : ''} ${!props.readonly ? 'clickable' : ''}`}
              onClick={handleRateClick}
              title={props.readonly ? undefined : 'Click to edit rate expression'}
            >
              [{props.reaction.rate ? 'k' : '?'}]
            </span>
          </span>

          {/* Products */}
          <span class="products">{renderSpeciesList(props.reaction.products)}</span>
        </div>

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

      {/* Expanded rate expression editor */}
      <Show when={isExpanded()}>
        <div class="reaction-rate-editor">
          <div class="rate-editor-header">
            <span>Rate Expression:</span>
            <button
              class="collapse-btn"
              onClick={() => setIsExpanded(false)}
              title="Collapse rate editor"
            >
              ▲
            </button>
          </div>

          <div class="rate-editor-content">
            <Show when={props.reaction.rate} fallback={
              <div class="no-rate-placeholder">
                <span>No rate expression defined</span>
                <button
                  class="add-rate-btn"
                  onClick={() => handleRateChange('k_rate')}
                >
                  Add rate constant
                </button>
              </div>
            }>
              <ExpressionNode
                expr={props.reaction.rate!}
                path={['rate']}
                highlightedVars={highlightedVars()}
                onHoverVar={setHoveredVar}
                onSelect={setSelectedPath}
                onReplace={handleReplace}
                selectedPath={selectedPath()}
              />
            </Show>
          </div>
        </div>
      </Show>
    </div>
  );
};

/**
 * Species panel component
 */
const SpeciesPanel: Component<{
  species?: NamedSpecies[];
  onAddSpecies?: (name: string, species: Species) => void;
  onEditSpecies?: (oldName: string, newName: string, species: Species) => void;
  onRemoveSpecies?: (name: string) => void;
  readonly?: boolean;
}> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true);
  const [isAdding, setIsAdding] = createSignal(false);
  const [editingName, setEditingName] = createSignal<string | null>(null);

  const startAdding = () => {
    setIsExpanded(true);
    setEditingName(null);
    setIsAdding(true);
  };

  const handleAddConfirm = (values: Record<string, string>) => {
    const name = values.name.trim();
    if (!name) return 'Species name is required';

    props.onAddSpecies?.(name, values.description ? { description: values.description } : {});
    setIsAdding(false);
  };

  const handleEditConfirm = (oldName: string, species: Species, values: Record<string, string>) => {
    const newName = values.name.trim();
    if (!newName) return 'Species name is required';

    props.onEditSpecies?.(oldName, newName, {
      ...species,
      description: values.description || undefined
    });
    setEditingName(null);
  };

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
            onClick={(e) => { e.stopPropagation(); startAdding(); }}
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
                { name: 'description', label: 'Description' }
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
                        setIsAdding(false);
                        setEditingName(entry.name);
                      }
                    }}
                  >
                    <div class="species-info">
                      <span class="species-formula">
                        {renderChemicalName(entry.name)}
                      </span>
                      <Show when={renderChemicalName(entry.name) !== entry.name}>
                        <span class="species-name">({entry.name})</span>
                      </Show>
                    </div>

                    <Show when={entry.species.description}>
                      <div class="species-description">{entry.species.description}</div>
                    </Show>

                    <Show when={!props.readonly}>
                      <button
                        class="species-remove-btn"
                        onClick={(e) => { e.stopPropagation(); props.onRemoveSpecies?.(entry.name); }}
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
                    { name: 'description', label: 'Description', initial: entry.species.description || '' }
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
  );
};

/**
 * Parameters panel component. Lists ALL parameters of the reaction system
 * (no name-based filtering — rate constants are not required to follow any
 * particular naming convention).
 */
const ParametersPanel: Component<{
  parameters?: NamedParameter[];
  onAddParameter?: (name: string, parameter: Parameter) => void;
  onEditParameter?: (oldName: string, newName: string, parameter: Parameter) => void;
  onRemoveParameter?: (name: string) => void;
  readonly?: boolean;
}> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true);
  const [isAdding, setIsAdding] = createSignal(false);
  const [editingName, setEditingName] = createSignal<string | null>(null);

  const startAdding = () => {
    setIsExpanded(true);
    setEditingName(null);
    setIsAdding(true);
  };

  const parseParameter = (values: Record<string, string>): Parameter | string => {
    const value = parseFloat(values.value);
    if (values.value.trim() !== '' && isNaN(value)) {
      return 'Default value must be a number';
    }
    return {
      default: isNaN(value) ? 1.0 : value,
      units: values.units || undefined,
      description: values.description || undefined
    };
  };

  const handleAddConfirm = (values: Record<string, string>) => {
    const name = values.name.trim();
    if (!name) return 'Parameter name is required';

    const parameter = parseParameter(values);
    if (typeof parameter === 'string') return parameter;

    props.onAddParameter?.(name, parameter);
    setIsAdding(false);
  };

  const handleEditConfirm = (oldName: string, values: Record<string, string>) => {
    const newName = values.name.trim();
    if (!newName) return 'Parameter name is required';

    const parameter = parseParameter(values);
    if (typeof parameter === 'string') return parameter;

    props.onEditParameter?.(oldName, newName, parameter);
    setEditingName(null);
  };

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
            onClick={(e) => { e.stopPropagation(); startAdding(); }}
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
                { name: 'description', label: 'Description' }
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
                        setIsAdding(false);
                        setEditingName(entry.name);
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
                        onClick={(e) => { e.stopPropagation(); props.onRemoveParameter?.(entry.name); }}
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
                    { name: 'value', label: 'Default value', initial: String(entry.parameter.default ?? 1.0) },
                    { name: 'units', label: 'Units', initial: entry.parameter.units || '' },
                    { name: 'description', label: 'Description', initial: entry.parameter.description || '' }
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
  );
};

/**
 * Main ReactionEditor component
 */
export const ReactionEditor: Component<ReactionEditorProps> = (props) => {
  // Handle reaction system modifications
  const handleReactionSystemChange = (changes: Partial<ReactionSystem>) => {
    if (props.readonly || !props.onReactionSystemChange) return;

    const newReactionSystem = { ...props.reactionSystem, ...changes };
    props.onReactionSystemChange(newReactionSystem);
  };

  // First `R{n}` id not already taken. Using `reactions.length + 1` collides
  // after a deletion (e.g. delete R2 of R1/R2/R3 → next id R3, already in use).
  const nextReactionId = (): string => {
    const existing = new Set((props.reactionSystem.reactions || []).map((r) => r.id));
    let n = 1;
    while (existing.has(`R${n}`)) n++;
    return `R${n}`;
  };

  // Reaction management handlers
  const handleAddReaction = () => {
    const newReaction: Reaction = {
      id: nextReactionId(),
      substrates: [{ species: 'A', stoichiometry: 1 }],
      products: [{ species: 'B', stoichiometry: 1 }],
      rate: 'k_rate'
    };
    const newReactions = [...(props.reactionSystem.reactions || []), newReaction];
    handleReactionSystemChange({ reactions: asReactions(newReactions) });
  };

  const handleEditReaction = (index: number, reaction: Reaction) => {
    const newReactions = [...(props.reactionSystem.reactions || [])];
    newReactions[index] = reaction;
    handleReactionSystemChange({ reactions: asReactions(newReactions) });
  };

  const handleRemoveReaction = (index: number) => {
    const newReactions = (props.reactionSystem.reactions || []).filter((_, i) => i !== index);
    handleReactionSystemChange({ reactions: asReactions(newReactions) });
  };

  // Species management handlers
  const handleAddSpecies = (name: string, species: Species) => {
    const updatedSpecies = {
      ...(props.reactionSystem.species || {}),
      [name]: species
    };
    handleReactionSystemChange({ species: updatedSpecies });
  };

  const handleEditSpecies = (oldName: string, newName: string, species: Species) => {
    const updatedSpecies = { ...(props.reactionSystem.species || {}) };

    // Remove old species if name changed
    if (newName !== oldName) {
      delete updatedSpecies[oldName];
    }

    updatedSpecies[newName] = species;
    handleReactionSystemChange({ species: updatedSpecies });
  };

  const handleRemoveSpecies = (name: string) => {
    // window.confirm is intentionally kept for this destructive action:
    // removing a species can silently break every reaction that references
    // it, and the species list has no undo affordance of its own. A native
    // blocking confirm is the conservative guard until a proper non-blocking
    // confirmation UI exists.
    if (!confirm(`Remove species "${name}"? This may affect reactions that reference it.`)) return;

    const updatedSpecies = { ...(props.reactionSystem.species || {}) };
    delete updatedSpecies[name];
    handleReactionSystemChange({ species: updatedSpecies });
  };

  // Parameter management handlers
  const handleAddParameter = (name: string, parameter: Parameter) => {
    const updatedParameters = {
      ...(props.reactionSystem.parameters || {}),
      [name]: parameter
    };
    handleReactionSystemChange({ parameters: updatedParameters });
  };

  const handleEditParameter = (oldName: string, newName: string, parameter: Parameter) => {
    const updatedParameters = { ...(props.reactionSystem.parameters || {}) };

    // Remove old parameter if name changed
    if (newName !== oldName) {
      delete updatedParameters[oldName];
    }

    updatedParameters[newName] = parameter;
    handleReactionSystemChange({ parameters: updatedParameters });
  };

  const handleRemoveParameter = (name: string) => {
    // window.confirm intentionally kept for destructive delete — see
    // handleRemoveSpecies for the rationale.
    if (!confirm(`Remove parameter "${name}"? This may affect reactions that reference it.`)) return;

    const updatedParameters = { ...(props.reactionSystem.parameters || {}) };
    delete updatedParameters[name];

    handleReactionSystemChange({ parameters: updatedParameters });
  };

  const editorClasses = () => {
    const classes = ['reaction-editor'];
    if (props.readonly) classes.push('readonly');
    if (props.class) classes.push(props.class);
    return classes.join(' ');
  };

  return (
    <div class={editorClasses()}>
      <div class="reaction-editor-layout">
        {/* Main reactions panel */}
        <div class="reactions-main">
          <div class="reactions-header">
            <h2>Reactions ({(props.reactionSystem.reactions || []).length})</h2>
            <Show when={!props.readonly}>
              <button
                class="add-reaction-btn"
                onClick={handleAddReaction}
                title="Add new reaction"
              >
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
                  highlightedVars={props.highlightedVars}
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
              species
            }))}
            onAddSpecies={handleAddSpecies}
            onEditSpecies={handleEditSpecies}
            onRemoveSpecies={handleRemoveSpecies}
            readonly={props.readonly}
          />

          <ParametersPanel
            parameters={Object.entries(props.reactionSystem.parameters || {}).map(([name, parameter]) => ({
              name,
              parameter
            }))}
            onAddParameter={handleAddParameter}
            onEditParameter={handleEditParameter}
            onRemoveParameter={handleRemoveParameter}
            readonly={props.readonly}
          />
        </div>
      </div>
    </div>
  );
};

export default ReactionEditor;
