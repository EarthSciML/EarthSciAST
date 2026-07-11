/**
 * Fraction Layout Component - CSS fraction layout
 *
 * Provides proper mathematical fraction rendering using CSS Flexbox and
 * CSS Grid for horizontal fraction bars. This replaces the inline
 * fraction handling in ExpressionNode with a dedicated, reusable component.
 */

import { Component, JSX } from 'solid-js';
import { MathLayoutProps, buildClasses } from './shared';
import './fraction.css';

export interface FractionProps extends MathLayoutProps {
  /** The numerator content */
  numerator: JSX.Element;

  /** The denominator content */
  denominator: JSX.Element;

  /** Whether this fraction should display inline (default true) */
  inline?: boolean;
}

/**
 * Fraction component for mathematical layout.
 * Uses CSS Grid for proper fraction bar alignment and sizing.
 */
export const Fraction: Component<FractionProps> = (props) => {
  const classes = () =>
    buildClasses('esm-fraction', props.inline !== false && 'esm-fraction-inline', props.class);

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