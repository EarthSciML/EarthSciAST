/**
 * Superscript Layout Component - Exponent positioning
 *
 * Provides proper mathematical superscript positioning for exponents.
 * Uses CSS for precise positioning and scaling without requiring
 * external math rendering libraries.
 */

import { Component, JSX } from 'solid-js';
import './superscript.css';

export interface SuperscriptProps {
  /** The base expression */
  base: JSX.Element;

  /** The superscript/exponent content */
  exponent: JSX.Element;

  /** Additional CSS classes to apply */
  class?: string;

  /** Callback for click events */
  onClick?: (e: MouseEvent) => void;

  /** Callback for hover events */
  onMouseEnter?: (e: MouseEvent) => void;
  onMouseLeave?: (e: MouseEvent) => void;
}

/**
 * Superscript component for mathematical exponentiation layout.
 * Handles proper positioning and scaling of exponents relative to base expressions.
 */
export const Superscript: Component<SuperscriptProps> = (props) => {
  const classes = () => {
    const baseClasses = ['esm-superscript'];
    if (props.class) baseClasses.push(props.class);
    return baseClasses.join(' ');
  };

  return (
    <span
      class={classes()}
      onClick={props.onClick}
      onMouseEnter={props.onMouseEnter}
      onMouseLeave={props.onMouseLeave}
      role="math"
      aria-label="exponentiation"
    >
      <span class="esm-superscript-base">
        {props.base}
      </span>
      <span class="esm-superscript-exponent">
        {props.exponent}
      </span>
    </span>
  );
};

export default Superscript;