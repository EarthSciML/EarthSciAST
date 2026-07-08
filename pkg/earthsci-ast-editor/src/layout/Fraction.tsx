/**
 * Fraction Layout Component - CSS fraction layout
 *
 * Provides proper mathematical fraction rendering using CSS Flexbox and
 * CSS Grid for horizontal fraction bars. This replaces the inline
 * fraction handling in ExpressionNode with a dedicated, reusable component.
 */

import { Component, JSX } from 'solid-js';
import './fraction.css';

export interface FractionProps {
  /** The numerator content */
  numerator: JSX.Element;

  /** The denominator content */
  denominator: JSX.Element;

  /** Additional CSS classes to apply */
  class?: string;

  /** Whether this fraction should display inline (default true) */
  inline?: boolean;

  /** Callback for click events */
  onClick?: (e: MouseEvent) => void;

  /** Callback for hover events */
  onMouseEnter?: (e: MouseEvent) => void;
  onMouseLeave?: (e: MouseEvent) => void;
}

/**
 * Fraction component for mathematical layout.
 * Uses CSS Grid for proper fraction bar alignment and sizing.
 */
export const Fraction: Component<FractionProps> = (props) => {
  const classes = () => {
    const baseClasses = ['esm-fraction'];
    if (props.inline !== false) baseClasses.push('esm-fraction-inline');
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
      aria-label="fraction"
    >
      <span class="esm-fraction-numerator">
        {props.numerator}
      </span>
      <span class="esm-fraction-bar"></span>
      <span class="esm-fraction-denominator">
        {props.denominator}
      </span>
    </span>
  );
};

export default Fraction;