/**
 * Shared editor constants
 *
 * Centralizes the magic placeholder strings used when inserting template
 * expressions, equations, and events, so every component refers to the
 * same tokens.
 */

/** Placeholder leaf inserted into template expressions (palette, new equations) */
export const EXPRESSION_PLACEHOLDER = '_placeholder_';

/** Placeholder condition expression for a newly created continuous event */
export const CONDITION_PLACEHOLDER = '_condition_placeholder';

/** Placeholder trigger expression for a newly created discrete event */
export const TRIGGER_PLACEHOLDER = '_trigger_placeholder';

/** Placeholder target variable for a newly created event affect */
export const VARIABLE_PLACEHOLDER = '_variable_placeholder';

/** Placeholder value expression for a newly created event affect */
export const VALUE_PLACEHOLDER = '_value_placeholder';
