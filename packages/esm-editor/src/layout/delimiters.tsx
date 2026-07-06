/**
 * Delimiters Layout Component - Parentheses with auto-sizing
 *
 * Provides proper delimiter rendering with automatic sizing based on content height.
 * Supports various delimiter types (parentheses, brackets, braces) with CSS scaling.
 */

import { Component, JSX, createEffect } from 'solid-js';
import './delimiters.css';

export interface DelimitersProps {
  /** The content to wrap with delimiters */
  content: JSX.Element;

  /** Type of delimiters to use */
  type?: 'parentheses' | 'brackets' | 'braces' | 'absolute' | 'angle';

  /** Additional CSS classes to apply */
  class?: string;

  /** Whether delimiters should auto-size based on content (default true) */
  autoSize?: boolean;

  /** Manual size override ('small', 'medium', 'large', 'xlarge') */
  size?: 'small' | 'medium' | 'large' | 'xlarge';

  /** Callback for click events */
  onClick?: (e: MouseEvent) => void;

  /** Callback for hover events */
  onMouseEnter?: (e: MouseEvent) => void;
  onMouseLeave?: (e: MouseEvent) => void;
}

/**
 * Delimiters component for mathematical bracketing with auto-sizing.
 * Uses CSS transforms to scale delimiters based on content height.
 */
export const Delimiters: Component<DelimitersProps> = (props) => {
  let containerRef: HTMLSpanElement | undefined;

  const delimiterType = () => props.type || 'parentheses';
  const autoSize = () => props.autoSize !== false;
  const manualSize = () => props.size;

  const classes = () => {
    const baseClasses = ['esm-delimiters', `esm-delimiters-${delimiterType()}`];
    if (autoSize()) baseClasses.push('esm-delimiters-auto');
    if (manualSize()) baseClasses.push(`esm-delimiters-${manualSize()}`);
    if (props.class) baseClasses.push(props.class);
    return baseClasses.join(' ');
  };

  const getDelimiterChars = () => {
    switch (delimiterType()) {
      case 'parentheses':
        return { left: '(', right: ')' };
      case 'brackets':
        return { left: '[', right: ']' };
      case 'braces':
        return { left: '{', right: '}' };
      case 'absolute':
        return { left: '|', right: '|' };
      case 'angle':
        return { left: '⟨', right: '⟩' };
      default:
        return { left: '(', right: ')' };
    }
  };

  // Auto-sizing effect
  createEffect(() => {
    if (autoSize() && containerRef) {
      const updateSize = () => {
        const contentElement = containerRef?.querySelector('.esm-delimiters-content') as HTMLElement;
        if (contentElement) {
          const height = contentElement.offsetHeight;
          const leftDelim = containerRef?.querySelector('.esm-delimiters-left') as HTMLElement;
          const rightDelim = containerRef?.querySelector('.esm-delimiters-right') as HTMLElement;

          if (leftDelim && rightDelim) {
            let scaleY = 1;
            if (height > 20) {
              scaleY = Math.min(height / 16, 4); // Cap at 4x scale
            }

            const transform = `scaleY(${scaleY})`;
            leftDelim.style.transform = transform;
            rightDelim.style.transform = transform;
          }
        }
      };

      // Initial sizing
      setTimeout(updateSize, 0);

      // Set up ResizeObserver for dynamic sizing
      const observer = new ResizeObserver(updateSize);
      const contentElement = containerRef?.querySelector('.esm-delimiters-content');
      if (contentElement) {
        observer.observe(contentElement);
      }

      // Cleanup
      return () => observer.disconnect();
    }
  });

  const { left, right } = getDelimiterChars();

  return (
    <span
      ref={containerRef}
      class={classes()}
      onClick={props.onClick}
      onMouseEnter={props.onMouseEnter}
      onMouseLeave={props.onMouseLeave}
      role="math"
      aria-label={`${delimiterType()} delimiters`}
    >
      <span class="esm-delimiters-left">
        {left}
      </span>
      <span class="esm-delimiters-content">
        {props.content}
      </span>
      <span class="esm-delimiters-right">
        {right}
      </span>
    </span>
  );
};

export default Delimiters;