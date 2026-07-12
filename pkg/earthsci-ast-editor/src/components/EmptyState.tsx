/**
 * EmptyState - shared "nothing here yet" placeholder.
 *
 * Every panel renders the same empty-state scaffold (an icon, a message, and an
 * optional call-to-action). This component centralizes that markup; callers
 * supply the icon and text and pass any action buttons as children (gating them
 * by readonly themselves).
 */

import type { Component, JSX } from 'solid-js'

export interface EmptyStateProps {
  /** Emoji/icon shown above the message. */
  icon: string

  /** Message describing what is empty. */
  text: string

  /** Optional call-to-action buttons. */
  children?: JSX.Element
}

export const EmptyState: Component<EmptyStateProps> = (props) => (
  <div class="empty-state">
    <div class="empty-icon">{props.icon}</div>
    <div class="empty-text">{props.text}</div>
    {props.children}
  </div>
)

export default EmptyState
