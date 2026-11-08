/**
 * Standard-library refs (esm-spec §4.7): `esm:std/<file>.esm` resolves to the
 * copy of the repository's `lib/` bundled into this package as the generated
 * module `stdlib-bundle.ts` (written by `scripts/sync-lib.sh`). The form is
 * REQUIRED of every binding, at every §4.7 ref site — subsystem mounts at both
 * forms, template imports and coupling imports.
 *
 * A bundled file has the identity `esm:std/<file>.esm` (its cycle-detection
 * key) and the virtual base directory `esm:std`, so a relative ref inside it
 * (a library file importing `calendar.esm`) names a sibling in the bundle.
 */

import { STDLIB_FILES } from './stdlib-bundle.js'

/** The virtual base directory of a bundled file. */
export const STDLIB_BASE = 'esm:std'

const SCHEME = 'esm:'
const PREFIX = 'esm:std/'
const FILE_NAME_RE = /^[A-Za-z0-9_][A-Za-z0-9_.-]*\.esm$/

let stdlibFiles: Readonly<Record<string, string>> = STDLIB_FILES

/**
 * Substitute the bundle (tests only); call with no argument to restore the
 * shipped one.
 * @internal
 */
export function setStdlibFilesForTesting(files?: Readonly<Record<string, string>>): void {
  stdlibFiles = files ?? STDLIB_FILES
}

/** A standard-library ref: its identity, and whether the name is well formed. */
export interface StdRef {
  identity: string
  valid: boolean
}

/**
 * Classify a ref whose `${VAR}` tokens are already expanded (`expandRefEnv`
 * leaves a ref beginning with `esm:` untouched, so §4.7 rule 3 holds). A ref is
 * a standard-library ref when it begins with `esm:`, or when it is a relative
 * path inside a bundled file (`baseDir` is the virtual `esm:std`). Returns
 * `undefined` for any other ref. The identity is `esm:std/<file>.esm` for a
 * well-formed name (`.` segments dropped), else the spelling as written; the
 * bundle may still lack the file.
 */
export function classifyStdRef(ref: string, baseDir?: string): StdRef | undefined {
  let r = ref
  if (!r.startsWith(SCHEME)) {
    const relative = !r.startsWith('/') && !/^https?:\/\//.test(r)
    if (baseDir !== STDLIB_BASE || !relative) return undefined
    r = PREFIX + r
  }
  if (!r.startsWith(PREFIX)) return { identity: r, valid: false }
  const segs = r
    .slice(PREFIX.length)
    .split('/')
    .filter((s) => s !== '.')
  if (segs.length !== 1 || !FILE_NAME_RE.test(segs[0]!)) return { identity: r, valid: false }
  return { identity: PREFIX + segs[0], valid: true }
}

/**
 * The text of the bundled file a standard-library ref names. Throws a plain
 * `Error` for a malformed name or a file the bundle does not contain; callers
 * wrap it in their own unresolved diagnostic.
 */
export function readStdRef(ref: string, std: StdRef): string {
  if (!std.valid) {
    throw new Error(`standard-library ref '${ref}' is not of the form esm:std/<file>.esm`)
  }
  const name = std.identity.slice(PREFIX.length)
  if (!Object.prototype.hasOwnProperty.call(stdlibFiles, name)) {
    throw new Error(`standard-library ref '${ref}' names no file of the bundled standard library`)
  }
  return stdlibFiles[name]!
}
