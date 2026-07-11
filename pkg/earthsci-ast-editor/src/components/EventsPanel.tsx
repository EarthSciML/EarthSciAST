/**
 * EventsPanel - collapsible panel for a model's continuous and discrete events,
 * with inline JSON editing of conditions, triggers, and effects.
 */

import { Component, createSignal, For, Show } from 'solid-js';
import type { ContinuousEvent, DiscreteEvent, Expression } from '@earthsciml/ast';
import { InlineForm } from './InlineForm';
import { CollapsiblePanel } from './CollapsiblePanel';
import { EmptyState } from './EmptyState';

/**
 * Parse a JSON expression string, or return null when invalid. The parsed value
 * is typed `unknown` — JSON.parse cannot guarantee a well-formed Expression, so
 * callers narrow/cast at the point of use rather than laundering it silently.
 */
function tryParseJson(text: string): { value: unknown } | null {
  try {
    return { value: JSON.parse(text) };
  } catch {
    return null;
  }
}

const INVALID_JSON_MESSAGE = 'Invalid JSON format';

/** Identifies which event sub-item is currently being edited inline. */
type EventEditTarget =
  | { kind: 'condition'; eventIndex: number; index: number }
  | { kind: 'continuous-affect'; eventIndex: number; index: number }
  | { kind: 'discrete-affect'; eventIndex: number; index: number }
  | { kind: 'trigger'; eventIndex: number };

/**
 * Whether two edit targets address the same sub-item. `trigger` targets have no
 * sub-index (one trigger per event), so they match on kind + event alone; every
 * other kind also matches on its list index.
 */
function targetsEqual(a: EventEditTarget, b: EventEditTarget): boolean {
  if (a.kind !== b.kind || a.eventIndex !== b.eventIndex) return false;
  if (!('index' in a) || !('index' in b)) return true;
  return a.index === b.index;
}

export interface EventsPanelProps {
  continuousEvents?: ContinuousEvent[];
  discreteEvents?: DiscreteEvent[];
  onAddContinuousEvent?: (name: string, description: string) => void;
  onAddDiscreteEvent?: (name: string, description: string) => void;
  onEditContinuousEvent?: (index: number, event: ContinuousEvent) => void;
  onEditDiscreteEvent?: (index: number, event: DiscreteEvent) => void;
  readonly?: boolean;
}

export const EventsPanel: Component<EventsPanelProps> = (props) => {
  const [isExpanded, setIsExpanded] = createSignal(true);
  const [addingKind, setAddingKind] = createSignal<'continuous' | 'discrete' | null>(null);
  const [editTarget, setEditTarget] = createSignal<EventEditTarget | null>(null);

  const totalEvents = () =>
    (props.continuousEvents || []).length + (props.discreteEvents || []).length;

  const isEditing = (target: EventEditTarget) => {
    const current = editTarget();
    return current != null && targetsEqual(current, target);
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
    updatedConditions[index] = parsed.value as Expression;
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
    updatedAffects[index] = {
      lhs: parsedLhs.value as Expression,
      rhs: parsedRhs.value as Expression
    } as (typeof updatedAffects)[number];

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

  /** Shared affect list rendering for continuous and discrete events. */
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
    <CollapsiblePanel
      panelClass="events-panel"
      contentClass="events-content"
      expanded={isExpanded()}
      onToggle={() => setIsExpanded(!isExpanded())}
      title={<h3>Events ({totalEvents()})</h3>}
      actions={
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
      }
    >
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
        <EmptyState icon="⚡" text="No events defined">
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
        </EmptyState>
      </Show>
    </CollapsiblePanel>
  );
};

export default EventsPanel;
