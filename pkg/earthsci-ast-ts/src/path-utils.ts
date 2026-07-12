/**
 * Shared POSIX-style path + synchronous-file-access helpers for the §9.7
 * template-library / coupling-library / subsystem ref loaders.
 *
 * These functions were previously copy-pasted (byte-identically) into
 * `template-imports.ts` and `ref-loading.ts`, with a third slightly-different
 * `joinPath` variant in `coupling-imports.ts`. This module is the single home
 * for the canonical behavior so the loaders cannot drift apart.
 *
 * "Canonical" here means the `template-imports.ts` / `ref-loading.ts` pair:
 * those two were byte-identical, so their behavior is authoritative. Any
 * intentional deviation in `coupling-imports.ts` is documented on the relevant
 * function below; the consuming agent decides whether to adopt the canonical
 * form there.
 */

/** True for `http://` / `https://` refs, which are resolved as opaque keys. */
export function isRemoteRef(ref: string): boolean {
  return ref.startsWith('http://') || ref.startsWith('https://')
}

/**
 * Join two POSIX-style paths. An absolute `ref` (leading `/`) wins outright;
 * otherwise `ref` is appended to `baseDir` with exactly one separator.
 *
 * This is the canonical `template-imports.ts` / `ref-loading.ts` form.
 * `coupling-imports.ts` carries an intentionally-different variant that
 *   (a) strips *all* trailing slashes from the base (`base.replace(/\/+$/, '')`)
 *       rather than only collapsing a single one, and
 *   (b) on an empty base returns the bare `ref` (no leading `/`) instead of the
 *       `/ref` this canonical form produces.
 * The two agree for the common single-trailing-slash / non-empty-base cases and
 * diverge only for multi-slash bases (`'a//'`) and empty bases (`''`). The
 * coupling variant is NOT reproduced here; adopt-or-keep is the consumer's call.
 */
export function joinPath(baseDir: string, ref: string): string {
  if (ref.startsWith('/')) return ref
  if (baseDir.endsWith('/')) return `${baseDir}${ref}`
  return `${baseDir}/${ref}`
}

/**
 * Collapse `.` and `..` segments in a POSIX-style path. Absolute paths keep a
 * leading `/` and never escape the root (leading `..` are dropped); relative
 * paths retain leading `..` and collapse to `.` when they reduce to nothing.
 */
export function canonicalizePath(p: string): string {
  const isAbs = p.startsWith('/')
  const parts = p.split('/').filter((seg) => seg.length > 0 && seg !== '.')
  const stack: string[] = []
  for (const seg of parts) {
    if (seg === '..') {
      if (stack.length > 0 && stack[stack.length - 1] !== '..') {
        stack.pop()
      } else if (!isAbs) {
        stack.push('..')
      }
    } else {
      stack.push(seg)
    }
  }
  const joined = stack.join('/')
  return isAbs ? `/${joined}` : joined || '.'
}

/**
 * Canonical cycle-detection key for an import/subsystem ref (esm-spec §9.7.2 /
 * §4.7). Remote refs are returned verbatim; local refs are joined against
 * `baseDir` and collapsed so that different spellings of the same file
 * (`a/../b`, `./b`) map to one key.
 *
 * This reconciles the two prior spellings of the same operation:
 *   - `ref-loading.ts#normalizeRef(ref, basePath)` — no backslash handling.
 *   - `template-imports.ts#canonicalRef(ref, baseDir)` — additionally ran
 *     `baseDir.replace(/\\/g, '/')` before joining, so Windows-style bases
 *     collapse to POSIX form.
 * The canonical form KEEPS the backslash normalization: it is a strict superset
 * (a no-op for POSIX bases, which contain no `\`) and makes the key robust to a
 * Windows-style `baseDir`. `baseDir` is optional; when omitted (or empty) the
 * ref is canonicalized on its own with no base prefix.
 */
export function normalizeRef(ref: string, baseDir?: string): string {
  if (isRemoteRef(ref)) return ref
  const base = baseDir ? baseDir.replace(/\\/g, '/') : ''
  return canonicalizePath(base ? joinPath(base, ref) : ref)
}

/**
 * Read a file synchronously under Node via `process.getBuiltinModule('node:fs')`
 * (the §9.7 loaders resolve inside the synchronous `load()`, so they cannot use
 * `await import`). Throws in environments without `getBuiltinModule` — such
 * hosts must supply their own `readFile` hook to the caller. Mirrors the
 * `defaultReadFile` dance from `template-imports.ts` / `ref-loading.ts`.
 */
export function readFileSyncNode(path: string): string {
  const proc = (globalThis as { process?: { getBuiltinModule?: (id: string) => unknown } }).process
  const getBuiltin = proc?.getBuiltinModule
  if (typeof getBuiltin === 'function') {
    const fs = getBuiltin.call(proc, 'node:fs') as {
      readFileSync: (p: string, enc: string) => string
    }
    return fs.readFileSync(path, 'utf8')
  }
  throw new Error(
    'synchronous file access is unavailable in this environment; supply a readFile hook',
  )
}
