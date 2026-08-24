/**
 * The package's OWN version — distinct from {@link SCHEMA_VERSION}, which is
 * the `.esm` FORMAT version this build implements. The two are unrelated
 * numbers and used to be conflated: `VERSION` meant the schema version here
 * and the package version in Rust, so the same name read two different
 * things depending on which binding you were in. `VERSION` is gone; every
 * binding now exposes exactly `SCHEMA_VERSION` and `LIBRARY_VERSION`.
 *
 * package.json is the source of truth. It cannot be imported here —
 * tsconfig's `rootDir` is `./src`, and a runtime read would break browser
 * hosts — so the value is mirrored, and `version.test.ts` fails the build if
 * the mirror drifts. Same arrangement Rust uses for its `SCHEMA_VERSION`.
 */
export const LIBRARY_VERSION = '0.1.1'
