/**
 * Shared building blocks for the mathematical layout components.
 *
 * The five layout components (Fraction, Superscript, Subscript, Radical,
 * Delimiters) share the same event/`class` prop surface and the same
 * "base class + conditional classes + caller class" className builder. Both
 * live here so the individual components stay declarative and consistent.
 */

/**
 * Common prop surface shared by every mathematical layout component:
 * an optional extra `class` plus the pointer event callbacks. Each component
 * extends this with its own content props.
 */
export interface MathLayoutProps {
  /** Additional CSS classes to apply */
  class?: string;

  /** Callback for click events */
  onClick?: (e: MouseEvent) => void;

  /** Callback for hover events */
  onMouseEnter?: (e: MouseEvent) => void;
  onMouseLeave?: (e: MouseEvent) => void;
}

/**
 * Build a space-separated className from a required base class and any number
 * of conditional classes. Falsy entries (`false`/`null`/`undefined`/`''`) are
 * dropped, so callers can pass `cond && 'class-name'` inline.
 *
 * Call this inside a reactive accessor (e.g. `const classes = () => buildClasses(...)`)
 * so class changes track prop changes.
 */
export function buildClasses(
  base: string,
  ...conditional: Array<string | false | null | undefined>
): string {
  const classes = [base];
  for (const cls of conditional) {
    if (cls) classes.push(cls);
  }
  return classes.join(' ');
}
