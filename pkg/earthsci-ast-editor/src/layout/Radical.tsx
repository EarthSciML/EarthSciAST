/**
 * Radical Layout Component - Square root rendering
 *
 * Provides proper square root symbol rendering with content containment.
 * Uses CSS for the radical symbol and proper content alignment.
 */

import type { Component, JSX } from 'solid-js'
import type { MathLayoutProps } from './shared'
import { buildClasses } from './shared'
import './radical.css'

export interface RadicalProps extends MathLayoutProps {
  /** The content under the radical */
  content: JSX.Element

  /** The index of the radical (for nth roots, default is 2 for square root) */
  index?: JSX.Element
}

/**
 * Radical component for square roots and nth roots.
 * Uses CSS borders and pseudo-elements to create the radical symbol.
 */
export const Radical: Component<RadicalProps> = (props) => {
  const classes = () =>
    buildClasses('esm-radical', !!props.index && 'esm-radical-with-index', props.class)

  return (
    <span
      class={classes()}
      onClick={props.onClick}
      onMouseEnter={props.onMouseEnter}
      onMouseLeave={props.onMouseLeave}
      role="math"
      aria-label={props.index ? 'nth root' : 'square root'}
    >
      {props.index && <span class="esm-radical-index">{props.index}</span>}
      <span class="esm-radical-symbol">√</span>
      <span class="esm-radical-content">{props.content}</span>
    </span>
  )
}
