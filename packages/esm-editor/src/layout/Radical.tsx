/**
 * Radical Layout Component - Square root rendering
 *
 * Provides proper square root symbol rendering with content containment.
 * Uses CSS for the radical symbol and proper content alignment.
 */

import { Component, JSX } from 'solid-js';
import './radical.css';

export interface RadicalProps {
  /** The content under the radical */
  content: JSX.Element;

  /** The index of the radical (for nth roots, default is 2 for square root) */
  index?: JSX.Element;

  /** Additional CSS classes to apply */
  class?: string;

  /** Callback for click events */
  onClick?: (e: MouseEvent) => void;

  /** Callback for hover events */
  onMouseEnter?: (e: MouseEvent) => void;
  onMouseLeave?: (e: MouseEvent) => void;
}

/**
 * Radical component for square roots and nth roots.
 * Uses CSS borders and pseudo-elements to create the radical symbol.
 */
export const Radical: Component<RadicalProps> = (props) => {
  const classes = () => {
    const baseClasses = ['esm-radical'];
    if (props.index) baseClasses.push('esm-radical-with-index');
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
      aria-label={props.index ? "nth root" : "square root"}
    >
      {props.index && (
        <span class="esm-radical-index">
          {props.index}
        </span>
      )}
      <span class="esm-radical-symbol">√</span>
      <span class="esm-radical-content">
        {props.content}
      </span>
    </span>
  );
};

export default Radical;