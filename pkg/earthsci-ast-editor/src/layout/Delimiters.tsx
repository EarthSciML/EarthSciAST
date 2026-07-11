/**
 * Delimiters Layout Component - Parentheses with auto-sizing
 *
 * Provides proper delimiter rendering with automatic sizing based on content height.
 * Supports various delimiter types (parentheses, brackets, braces) with CSS scaling.
 */

import { Component, JSX, createEffect, onCleanup } from 'solid-js';
import { MathLayoutProps, buildClasses } from './shared';
import './delimiters.css';

export interface DelimitersProps extends MathLayoutProps {
  /** The content to wrap with delimiters */
  content: JSX.Element;

  /** Type of delimiters to use */
  type?: 'parentheses' | 'brackets' | 'braces' | 'absolute' | 'angle';

  /** Whether delimiters should auto-size based on content (default true) */
  autoSize?: boolean;

  /** Manual size override ('small', 'medium', 'large', 'xlarge') */
  size?: 'small' | 'medium' | 'large' | 'xlarge';
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

  const classes = () =>
    buildClasses(
      'esm-delimiters',
      `esm-delimiters-${delimiterType()}`,
      autoSize() && 'esm-delimiters-auto',
      manualSize() && `esm-delimiters-${manualSize()}`,
      props.class,
    );

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
      const initialTimer = setTimeout(updateSize, 0);

      // Set up ResizeObserver for dynamic sizing
      const observer = new ResizeObserver(updateSize);
      const contentElement = containerRef?.querySelector('.esm-delimiters-content');
      if (contentElement) {
        observer.observe(contentElement);
      }

      // Cleanup. Solid ignores values returned from createEffect (unlike React's
      // useEffect), so cleanup MUST be registered via onCleanup or the observer
      // leaks on every effect re-run and on disposal.
      onCleanup(() => {
        clearTimeout(initialTimer);
        observer.disconnect();
      });
    }
  });

  return (
    <span
      ref={(el) => (containerRef = el)}
      class={classes()}
      onClick={props.onClick}
      onMouseEnter={props.onMouseEnter}
      onMouseLeave={props.onMouseLeave}
      role="math"
      aria-label={`${delimiterType()} delimiters`}
    >
      <span class="esm-delimiters-left">
        {getDelimiterChars().left}
      </span>
      <span class="esm-delimiters-content">
        {props.content}
      </span>
      <span class="esm-delimiters-right">
        {getDelimiterChars().right}
      </span>
    </span>
  );
};