/**
 * Layout Components - Mathematical typography components for ESM Editor
 *
 * This module provides all the mathematical layout components required by
 * Section 5.2.3 of the ESM Libraries Specification for CSS math typography
 * rendering without external libraries like KaTeX or MathJax.
 */

// Export all layout components. Each component imports its own stylesheet, so
// the CSS is bundled transitively — no separate CSS imports needed here.
export { Fraction } from './Fraction'
export type { FractionProps } from './Fraction'

export { Superscript } from './Superscript'
export type { SuperscriptProps } from './Superscript'

export { Subscript } from './Subscript'
export type { SubscriptProps } from './Subscript'

export { Radical } from './Radical'
export type { RadicalProps } from './Radical'

export { Delimiters } from './Delimiters'
export type { DelimitersProps } from './Delimiters'

// `shared.ts` (MathLayoutProps base + buildClasses) is an internal helper the
// components import directly; it is intentionally not re-exported here.
