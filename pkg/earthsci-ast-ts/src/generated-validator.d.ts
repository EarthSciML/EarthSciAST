/**
 * Types for the generated standalone validator.
 *
 * Hand-written rather than generated, because the shape never varies: Ajv's
 * `standaloneCode` always emits one validate function with `.errors` on it,
 * whatever the schema says. The GENERATED file is `generated-validator.js`.
 */
import type { ValidateFunction } from 'ajv'

declare const validate: ValidateFunction
export default validate
export { validate }
