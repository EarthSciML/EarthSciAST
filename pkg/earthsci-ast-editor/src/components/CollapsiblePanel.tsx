/**
 * CollapsiblePanel - shared expandable section with an accessible header.
 *
 * The variables/equations/events panels (ModelEditor) and the
 * species/parameters panels (ReactionEditor) all share the same scaffold: a
 * clickable header with an expand chevron, a title, optional action buttons,
 * and a body shown only while expanded. This component is that scaffold, with
 * the keyboard-accessible header pattern (role/tabIndex/Enter/Space) applied in
 * one place instead of being re-derived (or omitted) per panel.
 *
 * The expanded state is controlled by the caller so panels can force-expand
 * themselves (e.g. when an inline add form opens).
 */

import type { Component, JSX } from 'solid-js'
import { Show } from 'solid-js'

export interface CollapsiblePanelProps {
  /** Root panel class, e.g. `'variables-panel'`. */
  panelClass: string

  /** Body wrapper class, e.g. `'variables-content'`. */
  contentClass: string

  /** Header title content (typically an `<h3>`). */
  title: JSX.Element

  /** Optional header actions (add buttons); the caller gates these by readonly. */
  actions?: JSX.Element

  /** Whether the body is shown. */
  expanded: boolean

  /** Called when the header is activated (click or Enter/Space). */
  onToggle: () => void

  /** Panel body. */
  children: JSX.Element
}

export const CollapsiblePanel: Component<CollapsiblePanelProps> = (props) => {
  const handleKeyDown = (e: KeyboardEvent & { currentTarget: HTMLDivElement; target: Element }) => {
    // Only respond to keys on the header itself, not on focused children
    // (e.g. the add button) whose own activation bubbles up here.
    if (e.target !== e.currentTarget) return
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      props.onToggle()
    }
  }

  return (
    <div class={props.panelClass}>
      <div
        class="panel-header"
        role="button"
        tabIndex={0}
        aria-expanded={props.expanded}
        onClick={props.onToggle}
        onKeyDown={handleKeyDown}
      >
        <span class={`expand-icon ${props.expanded ? 'expanded' : ''}`}>▶</span>
        {props.title}
        {props.actions}
      </div>

      <Show when={props.expanded}>
        <div class={props.contentClass}>{props.children}</div>
      </Show>
    </div>
  )
}

export default CollapsiblePanel
