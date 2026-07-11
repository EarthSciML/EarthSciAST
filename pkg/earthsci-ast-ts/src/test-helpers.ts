/**
 * Shared test-only helpers for the TypeScript test suite.
 *
 * This module is imported ONLY by `*.test.ts` files; it is not re-exported from
 * `index.ts` and is not part of the shipped package (the rollup build entry is
 * `index.ts`). It centralises two pieces of boilerplate that used to be
 * re-implemented across ~18 test files:
 *
 *  1. Repo-root / fixture-path resolution — the fragile
 *     `path.join(__dirname, '..','..','..','tests', ...)` idiom (and one
 *     `fileURLToPath(import.meta.url)` variant), and
 *  2. Fixture reading / ESM parsing — the local `loadFixture` / `loadPath`
 *     helpers that read a `.esm` file and hand it to {@link load}.
 *
 * It also exposes a single canonical {@link errCode} / {@link errCodeAsync}
 * pair, replacing five privately-redeclared copies with two incompatible
 * contracts.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { load, type LoadOptions } from './parse.js'
import { EsmMachineryError } from './lower-expression-templates.js'
import type { EsmFile } from './types.js'

/**
 * Absolute path to the repository root. This file lives at
 * `pkg/earthsci-ast-ts/src/test-helpers.ts`, so the repo root is three
 * directories up — the same relative depth every `*.test.ts` file assumed.
 */
export const REPO_ROOT: string = path.resolve(__dirname, '..', '..', '..')

/**
 * Absolute path under the repo-root `tests/` directory (the shared fixture
 * corpus). Pass the segments below `tests/`, e.g. `fixturesDir('valid')` or
 * `fixturesDir('conformance', 'canonical')`.
 */
export function fixturesDir(...segments: string[]): string {
  return path.join(REPO_ROOT, 'tests', ...segments)
}

/**
 * Alias of {@link fixturesDir}; reads more naturally when the segments point at
 * a specific fixture file, e.g. `fixturePath('valid', 'foo.esm')`.
 */
export const fixturePath = fixturesDir

/** Raw UTF-8 text of a fixture addressed by `tests/`-relative segments. */
export function readFixture(...segments: string[]): string {
  return fs.readFileSync(fixturesDir(...segments), 'utf-8')
}

/**
 * Parse a fixture addressed by `tests/`-relative segments via {@link load}. The
 * fixture's own directory is used as `basePath`, so template-import /
 * subsystem-ref edges resolve relative to the fixture (a no-op for fixtures
 * without such edges).
 */
export function loadFixture(...segments: string[]): EsmFile {
  return loadFixtureFile(fixturesDir(...segments))
}

/**
 * Parse a fixture addressed by an absolute path via {@link load}, defaulting
 * `basePath` to the file's own directory. Any extra {@link LoadOptions} (e.g.
 * `metaparameters`) are merged in and override the defaults.
 */
export function loadFixtureFile(absPath: string, options?: LoadOptions): EsmFile {
  return load(fs.readFileSync(absPath, 'utf-8'), {
    basePath: path.dirname(absPath),
    ...options,
  })
}

/** Options for {@link errCode} / {@link errCodeAsync}. */
export interface ErrCodeOptions {
  /**
   * Select the legacy sentinel-string contract used by the file-corpus coupling
   * suites: return `'NO_ERROR'` on success and `err.code ?? 'NON_CODE_ERROR'`
   * for ANY thrown error (never rethrows).
   *
   * When absent/false, the canonical contract applies: return `null` on
   * success, the `.code` of a thrown {@link EsmMachineryError}, and rethrow
   * anything else so unexpected errors surface loudly.
   */
  sentinel?: boolean
}

/**
 * Run `fn` and report the load-time machinery error code it raised.
 *
 * Canonical contract (default): returns `null` when `fn` succeeds, the `.code`
 * of a thrown {@link EsmMachineryError}, and rethrows any other error so
 * unexpected failures are not silently swallowed.
 *
 * Pass `{ sentinel: true }` for the legacy string contract (`'NO_ERROR'` on
 * success, `err.code ?? 'NON_CODE_ERROR'` on any throw, never rethrows).
 */
export function errCode(fn: () => unknown, options?: ErrCodeOptions): string | null {
  try {
    fn()
    return options?.sentinel ? 'NO_ERROR' : null
  } catch (e) {
    if (options?.sentinel) return (e as { code?: string }).code ?? 'NON_CODE_ERROR'
    if (e instanceof EsmMachineryError) return e.code
    throw e
  }
}

/** Async counterpart of {@link errCode}; see it for the contract. */
export async function errCodeAsync(
  fn: () => Promise<unknown>,
  options?: ErrCodeOptions,
): Promise<string | null> {
  try {
    await fn()
    return options?.sentinel ? 'NO_ERROR' : null
  } catch (e) {
    if (options?.sentinel) return (e as { code?: string }).code ?? 'NON_CODE_ERROR'
    if (e instanceof EsmMachineryError) return e.code
    throw e
  }
}
