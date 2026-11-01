/**
 * The package's OWN version — distinct from {@link SCHEMA_VERSION}, which is
 * the `.esm` FORMAT version this build implements. The two are unrelated
 * numbers; every binding exposes both, under these two names.
 *
 * package.json is the source of truth. It cannot be imported here —
 * tsconfig's `rootDir` is `./src`, and a runtime read would break browser
 * hosts — so the value is mirrored, and `version.test.ts` fails the build if
 * the mirror drifts. Same arrangement Rust uses for its `SCHEMA_VERSION`.
 */
export const LIBRARY_VERSION = '0.7.0'
