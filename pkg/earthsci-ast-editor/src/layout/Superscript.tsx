/**
 * Superscript Layout Component - Exponent positioning
 *
 * Provides proper mathematical superscript positioning for exponents.
 * Uses CSS for precise positioning and scaling without requiring
 * external math rendering libraries.
 */

import type { Component, JSX } from 'solid-js'
import type { MathLayoutProps } from './shared'
import { buildClasses } from './shared'
import './superscript.css'

export interface SuperscriptProps extends MathLayoutProps {
  /** The base expression */
  base: JSX.Element

  /** The superscript/exponent content */
  exponent: JSX.Element
}

/**
 * Superscript component for mathematical exponentiation layout.
 * Handles proper positioning and scaling of exponents relative to base expressions.
 */
export const Superscript: Component<SuperscriptProps> = (props) => {
  const classes = () => buildClasses('esm-superscript', props.class)

  return (
    <span
      class={classes()}
      onClick={props.onClick}
      onMouseEnter={props.onMouseEnter}
      onMouseLeave={props.onMouseLeave}
      role="math"
      aria-label="exponentiation"
    >
      <span class="esm-superscript-base">{props.base}</span>
      <span class="esm-superscript-exponent">{props.exponent}</span>
    </span>
  )
}
