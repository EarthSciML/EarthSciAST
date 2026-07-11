/**
 * FileSummary - Read-only overview of entire ESM file
 *
 * This component provides a comprehensive overview of the ESM file structure
 * matching spec Section 6.3 format. Shows: version, metadata, reaction systems
 * summary, models summary, data loaders, coupling rules, domain, solver.
 * Section headers are clickable links that scroll to / select the relevant
 * editor section.
 */

import { Component, type JSX, createMemo, For, Show } from 'solid-js';
import { Dynamic } from 'solid-js/web';
import type { EsmFile, Model, ReactionSystem, SubsystemRef, CouplingEntry } from '@earthsciml/ast';

export interface FileSummaryProps {
  /** The ESM file to summarize */
  esmFile: EsmFile;

  /** Callback when a section header is clicked */
  onSectionClick?: (sectionType: string, sectionId?: string) => void;

  /** CSS class for styling */
  class?: string;

  /** Whether the summary is collapsed */
  collapsed?: boolean;

  /** Callback when collapse state changes */
  onToggleCollapsed?: (collapsed: boolean) => void;
}

/**
 * Helper to count items in an object or return 0 if undefined
 */
function countItems(obj: Record<string, unknown> | undefined): number {
  return obj ? Object.keys(obj).length : 0;
}

/**
 * An accessible clickable heading/label: wires up role="button", tabIndex, and
 * keyboard (Enter/Space) activation once so the nine section headers and item
 * names don't each re-implement the same a11y block.
 */
const ClickableHeading: Component<{
  /** Element tag to render (e.g. 'h4' for section headers, 'div' for items). */
  as: 'h4' | 'div';
  class: string;
  onActivate: () => void;
  children: JSX.Element;
}> = (props) => {
  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      props.onActivate();
    }
  };
  return (
    <Dynamic
      component={props.as}
      class={props.class}
      role="button"
      tabIndex={0}
      onClick={() => props.onActivate()}
      onKeyDown={handleKeyDown}
    >
      {props.children}
    </Dynamic>
  );
};

/**
 * Helper to get coupling type description
 */
function getCouplingDescription(coupling: CouplingEntry): string {
  switch (coupling.type) {
    case 'operator_compose':
      return `Compose: ${coupling.systems?.join(', ') || 'N/A'}`;
    case 'couple':
      return `Couple: ${coupling.systems?.join(', ') || 'N/A'}`;
    case 'variable_map':
      return `Map: ${coupling.from || 'N/A'} → ${coupling.to || 'N/A'}`;
    case 'callback':
      return `Callback: ${coupling.callback_id || 'N/A'}`;
    case 'event':
      return `Event coupling`;
    default:
      return 'Unknown coupling type';
  }
}

/**
 * Helper to format model/reaction system summary
 */
function getSystemSummary(system: Model | ReactionSystem | SubsystemRef): string {
  if ('ref' in system && typeof system.ref === 'string') {
    return `External reference: ${system.ref}`;
  }

  const items = [];

  if ('variables' in system && system.variables) {
    items.push(`${Object.keys(system.variables).length} variables`);
  }

  if ('species' in system && system.species) {
    items.push(`${Object.keys(system.species).length} species`);
  }

  if ('parameters' in system && system.parameters) {
    items.push(`${Object.keys(system.parameters).length} parameters`);
  }

  if ('equations' in system && system.equations) {
    items.push(`${system.equations.length} equations`);
  }

  if ('reactions' in system && system.reactions) {
    items.push(`${system.reactions.length} reactions`);
  }

  if ('subsystems' in system && system.subsystems) {
    items.push(`${Object.keys(system.subsystems).length} subsystems`);
  }

  return items.join(', ') || 'Empty system';
}

/**
 * Main FileSummary component
 */
export const FileSummary: Component<FileSummaryProps> = (props) => {
  // Reactive summaries
  const modelCount = createMemo(() => countItems(props.esmFile.models));
  const reactionSystemCount = createMemo(() => countItems(props.esmFile.reaction_systems));
  const dataLoaderCount = createMemo(() => countItems(props.esmFile.data_loaders));
  const couplingCount = createMemo(() => props.esmFile.coupling?.length || 0);

  // Handle section click
  const handleSectionClick = (sectionType: string, sectionId?: string) => {
    if (props.onSectionClick) {
      props.onSectionClick(sectionType, sectionId);
    }
  };

  // Handle collapse toggle
  const handleToggleCollapsed = () => {
    if (props.onToggleCollapsed) {
      props.onToggleCollapsed(!props.collapsed);
    }
  };

  // CSS classes
  const summaryClasses = () => {
    const classes = ['file-summary'];
    if (props.collapsed) classes.push('collapsed');
    if (props.class) classes.push(props.class);
    return classes.join(' ');
  };

  return (
    <div class={summaryClasses()}>
      {/* Summary header */}
      <div class="summary-header" onClick={handleToggleCollapsed}>
        <h3 class="summary-title">File Summary</h3>
        <button
          class="collapse-toggle"
          aria-label={props.collapsed ? 'Expand file summary' : 'Collapse file summary'}
        >
          {props.collapsed ? '▶' : '▼'}
        </button>
      </div>

      {/* Summary content - only shown when not collapsed */}
      <Show when={!props.collapsed}>
        <div class="summary-content">
          {/* Version and Metadata */}
          <div class="summary-section">
            <h4 class="section-title">Format Information</h4>
            <div class="section-content">
              <div class="info-item">
                <strong>Version:</strong> {props.esmFile.esm || 'Not specified'}
              </div>
              <Show when={props.esmFile.metadata}>
                {(metadata) => (
                  <>
                    <div class="info-item">
                      <strong>Title:</strong> {metadata().name || 'Untitled'}
                    </div>
                    <Show when={metadata().description}>
                      <div class="info-item">
                        <strong>Description:</strong> {metadata().description}
                      </div>
                    </Show>
                    <Show when={metadata().authors}>
                      {(authors) => (
                        <Show when={authors().length > 0}>
                          <div class="info-item">
                            <strong>Authors:</strong> {authors().join(', ')}
                          </div>
                        </Show>
                      )}
                    </Show>
                    <Show when={metadata().created}>
                      <div class="info-item">
                        <strong>Created:</strong> {metadata().created}
                      </div>
                    </Show>
                  </>
                )}
              </Show>
            </div>
          </div>

          {/* Models Summary */}
          <Show when={modelCount() > 0}>
            <div class="summary-section">
              <ClickableHeading
                as="h4"
                class="section-title clickable-section"
                onActivate={() => handleSectionClick('models')}
              >
                Models ({modelCount()}) →
              </ClickableHeading>
              <div class="section-content">
                <For each={Object.entries(props.esmFile.models || {})}>
                  {([modelName, model]) => (
                    <div class="system-item">
                      <ClickableHeading
                        as="div"
                        class="system-name clickable"
                        onActivate={() => handleSectionClick('models', modelName)}
                      >
                        <strong>{modelName}</strong> →
                      </ClickableHeading>
                      <div class="system-summary">
                        {getSystemSummary(model)}
                      </div>
                    </div>
                  )}
                </For>
              </div>
            </div>
          </Show>

          {/* Reaction Systems Summary */}
          <Show when={reactionSystemCount() > 0}>
            <div class="summary-section">
              <ClickableHeading
                as="h4"
                class="section-title clickable-section"
                onActivate={() => handleSectionClick('reaction_systems')}
              >
                Reaction Systems ({reactionSystemCount()}) →
              </ClickableHeading>
              <div class="section-content">
                <For each={Object.entries(props.esmFile.reaction_systems || {})}>
                  {([systemName, system]) => (
                    <div class="system-item">
                      <ClickableHeading
                        as="div"
                        class="system-name clickable"
                        onActivate={() => handleSectionClick('reaction_systems', systemName)}
                      >
                        <strong>{systemName}</strong> →
                      </ClickableHeading>
                      <div class="system-summary">
                        {getSystemSummary(system)}
                      </div>
                    </div>
                  )}
                </For>
              </div>
            </div>
          </Show>

          {/* Data Loaders Summary */}
          <Show when={dataLoaderCount() > 0}>
            <div class="summary-section">
              <ClickableHeading
                as="h4"
                class="section-title clickable-section"
                onActivate={() => handleSectionClick('data_loaders')}
              >
                Data Loaders ({dataLoaderCount()}) →
              </ClickableHeading>
              <div class="section-content">
                <For each={Object.entries(props.esmFile.data_loaders || {})}>
                  {([loaderName, loader]) => (
                    <div class="system-item">
                      <ClickableHeading
                        as="div"
                        class="system-name clickable"
                        onActivate={() => handleSectionClick('data_loaders', loaderName)}
                      >
                        <strong>{loaderName}</strong> →
                      </ClickableHeading>
                      <div class="system-summary">
                        Type: {loader.kind || 'Unknown'}
                        {loader.source?.url_template && ` | Source: ${loader.source.url_template}`}
                      </div>
                    </div>
                  )}
                </For>
              </div>
            </div>
          </Show>

          {/* Coupling Rules Summary */}
          <Show when={couplingCount() > 0}>
            <div class="summary-section">
              <ClickableHeading
                as="h4"
                class="section-title clickable-section"
                onActivate={() => handleSectionClick('coupling')}
              >
                Coupling Rules ({couplingCount()}) →
              </ClickableHeading>
              <div class="section-content">
                <For each={props.esmFile.coupling || []}>
                  {(coupling, index) => (
                    <div class="system-item">
                      <ClickableHeading
                        as="div"
                        class="system-name clickable"
                        onActivate={() => handleSectionClick('coupling', index().toString())}
                      >
                        <strong>Rule {index() + 1}</strong> →
                      </ClickableHeading>
                      <div class="system-summary">
                        {getCouplingDescription(coupling)}
                      </div>
                    </div>
                  )}
                </For>
              </div>
            </div>
          </Show>

          {/* Domain Summary */}
          <Show when={props.esmFile.domain}>
            {(domain) => (
              <div class="summary-section">
                <ClickableHeading
                  as="h4"
                  class="section-title clickable-section"
                  onActivate={() => handleSectionClick('domain')}
                >
                  Domain Configuration →
                </ClickableHeading>
                <div class="section-content">
                  <Show when={domain().temporal}>
                    {(temporal) => (
                      <div class="info-item">
                        <strong>Time:</strong>
                        Start: {temporal().start ?? 'N/A'},
                        End: {temporal().end ?? 'N/A'}
                      </div>
                    )}
                  </Show>
                  <Show when={domain().independent_variable}>
                    <div class="info-item">
                      <strong>Independent variable:</strong> {domain().independent_variable}
                    </div>
                  </Show>
                  <Show when={domain().element_type}>
                    <div class="info-item">
                      <strong>Element type:</strong> {domain().element_type}
                    </div>
                  </Show>
                </div>
              </div>
            )}
          </Show>

          {/* Empty state message */}
          <Show when={modelCount() === 0 && reactionSystemCount() === 0 && dataLoaderCount() === 0 && couplingCount() === 0}>
            <div class="empty-state">
              <p>This ESM file appears to be empty or contains no major components.</p>
            </div>
          </Show>
        </div>
      </Show>
    </div>
  );
};

export default FileSummary;