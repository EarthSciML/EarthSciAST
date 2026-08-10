/**
 * The Ajv options the ESM schema is validated under.
 *
 * Shared by `parse.ts` (which consumes the precompiled validator, and states
 * these for the reader) and `scripts/generate-standalone-validator.mjs` (which
 * compiles under them). One definition, because a precompiled validator built
 * with different options than the code expects reports different errors than the
 * runtime it replaced — and the difference would show up as a document that
 * validates here and fails there, with nothing pointing at the cause.
 *
 * `.mjs` rather than `.ts` so the build script can import it without a
 * TypeScript loader; it is plain data.
 */
export const AJV_OPTIONS = {
  allErrors: true,
  /**
   * Errors carry `schema`, `parentSchema` and `data`. Callers in this package
   * read them when rendering messages, so dropping this changes public output.
   */
  verbose: true,
  /** Allow unknown keywords for compatibility. */
  strict: false,
  /** Don't add the schema to cache. */
  addUsedSchema: false,
  /** Skip meta-schema validation. */
  validateSchema: false,
}
