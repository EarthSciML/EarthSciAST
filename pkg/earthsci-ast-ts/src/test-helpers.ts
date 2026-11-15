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
import { isDeepStrictEqual } from 'node:util'
import { canonicalizeDocument } from './canonicalize.js'
import { isIntLit, isNumericLiteral } from './numeric-literal.js'
import { loadString, type LoadOptions } from './parse.js'
import { EsmMachineryError } from './lower-expression-templates.js'
import type { EsmFile } from './types.js'

const INT64_BOUND = 2 ** 63

/**
 * A JSON value with every number as its kind and value, an integer as a
 * `bigint`: `{ int }` or `{ float }`. A `NumericLiteral` keeps its kind, and a
 * `bigint` (an integer past 2^53) is an int; a plain number is an int when it
 * is integral and in Int64 (the canonical kind of CONFORMANCE §5.5.3.1), and
 * `-0` is the float `0`. Two values compare equal with `toEqual` exactly when
 * they are the same JSON value with the same number kinds.
 */
export function numberKinds(value: unknown): unknown {
  if (typeof value === 'bigint') return { int: value }
  if (isNumericLiteral(value)) {
    return isIntLit(value) ? { int: BigInt(value.value) } : { float: value.value }
  }
  if (typeof value === 'number') {
    const int = Number.isInteger(value) && value >= -INT64_BOUND && value < INT64_BOUND
    return int ? { int: BigInt(value) } : { float: Object.is(value, -0) ? 0 : value }
  }
  if (Array.isArray(value)) return value.map(numberKinds)
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, numberKinds(v)]))
  }
  return value
}

/**
 * An expression (or any JSON value) in canonical JSON (CONFORMANCE §5.4,
 * `canonicalizeDocument`), with every number in its canonical kind
 * ({@link numberKinds}). This is how the shared corpora that record
 * expressions (the flatten corpus) compare them.
 */
export function canonicalJson(value: unknown): unknown {
  return numberKinds(canonicalizeDocument(value))
}

/** Whether two expressions are the same in canonical JSON ({@link canonicalJson}). */
export function sameExpr(a: unknown, b: unknown): boolean {
  return isDeepStrictEqual(canonicalJson(a), canonicalJson(b))
}

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
 * Parse a fixture addressed by an absolute path via {@link loadString}, defaulting
 * `basePath` to the file's own directory. Any extra {@link LoadOptions} (e.g.
 * `metaparameters`) are merged in and override the defaults.
 */
export function loadFixtureFile(absPath: string, options?: LoadOptions): EsmFile {
  return loadString(fs.readFileSync(absPath, 'utf-8'), {
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
