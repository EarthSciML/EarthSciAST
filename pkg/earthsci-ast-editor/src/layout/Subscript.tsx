/**
 * Subscript Layout Component - Chemical subscript
 *
 * Provides proper chemical subscript positioning for molecular formulas
 * and mathematical indices. Uses CSS for precise positioning and scaling.
 */

import { Component, JSX } from 'solid-js';
import './subscript.css';

export interface SubscriptProps {
  /** The base expression */
  base: JSX.Element;

  /** The subscript content */
  subscript: JSX.Element;

  /** Additional CSS classes to apply */
  class?: string;

  /** Whether this is a chemical subscript (affects styling) */
  chemical?: boolean;

  /** Callback for click events */
  onClick?: (e: MouseEvent) => void;

  /** Callback for hover events */
  onMouseEnter?: (e: MouseEvent) => void;
  onMouseLeave?: (e: MouseEvent) => void;
}

/**
 * Subscript component for chemical formulas and mathematical indices.
 * Handles proper positioning and scaling relative to base expressions.
 */
export const Subscript: Component<SubscriptProps> = (props) => {
  const classes = () => {
    const baseClasses = ['esm-subscript'];
    if (props.chemical) baseClasses.push('esm-subscript-chemical');
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
      aria-label={props.chemical ? "chemical subscript" : "subscript"}
    >
      <span class="esm-subscript-base">
        {props.base}
      </span>
      <span class="esm-subscript-content">
        {props.subscript}
      </span>
    </span>
  );
};

export default Subscript;