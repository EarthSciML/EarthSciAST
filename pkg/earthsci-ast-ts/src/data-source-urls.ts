/**
 * Load-time resolution of `data_sources[*].source.url_template` (esm-spec §8.2.1).
 *
 * A `url_template` need not be an absolute URL. §8.2.1 resolves it to one at
 * load time against the directory of the file the entry was read from — the
 * same base and the same timing rule §4.7 fixes for a `ref`. That is what lets
 * a document name data living outside its own repository without carrying a
 * machine-specific absolute path.
 *
 * Environment variables are deliberately NOT expanded (§4.7 permits `${VAR}`
 * in a `ref`; §8.2 does not permit it at all), and a template that needs one is
 * REFUSED rather than passed through. See
 * `docs/content/rfcs/portable-data-source-urls.md`.
 *
 * The pass rewrites the RAW document before schema validation, so every
 * consumer — the typed `DataSourceLocation`, `flatten`'s `LoaderField`, `emit`
 * — sees one resolved form and none of them needs a base directory. It is
 * idempotent (its output is scheme-led), so `parse → emit → parse` is stable.
 */

import { ERROR_CODES, EsmDiagnosticError } from './errors.js'

/**
 * esm-spec §8.2.1: a template is already a URL when it is scheme-led. The
 * `://` is required (rather than a bare `scheme:`) so that a Windows drive
 * letter and a `{date:%Y}` substitution are both read as path text.
 */
const SCHEME_RE = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//

/**
 * RFC 3986 §5.2.4 dot-segment removal, lexically, on an absolute path.
 *
 * Never a filesystem `realpath`: a template carrying a `{date:…}` substitution
 * names a file that need not exist at load time, and resolving symlinks would
 * make the resolved URL depend on the filesystem rather than on the document.
 */
function removeDotSegments(path: string): string {
  const out: string[] = []
  for (const seg of path.split('/')) {
    if (seg === '' || seg === '.') continue
    if (seg === '..') {
      out.pop()
      continue
    }
    out.push(seg)
  }
  return '/' + out.join('/')
}

/**
 * `baseDir` as an absolute POSIX directory.
 *
 * The loader's base may be relative (`loadPath('fixtures/x.esm')` gives
 * `fixtures`; `loadString` defaults to the working directory) and splicing a
 * relative path after `file://` would silently make its first segment the URL
 * HOST — the exact misresolution §8.2.1 exists to stop.
 */
function absoluteBase(baseDir: string): string {
  const b = (baseDir || '.').replace(/\\/g, '/')
  if (b.startsWith('/')) return b
  const cwd =
    typeof process !== 'undefined' && typeof process.cwd === 'function'
      ? process.cwd().replace(/\\/g, '/')
      : '/'
  return cwd.replace(/\/+$/, '') + '/' + b
}

/** Resolve one `url_template` / `mirrors` entry per esm-spec §8.2.1. */
export function resolveSourceUrl(template: string, baseDir: string): string {
  if (template.includes('${')) {
    throw new EsmDiagnosticError(
      ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
      `url template '${template}' carries an unexpanded '\${...}' variable. ` +
        'esm-spec §8.2.1 does not expand environment variables into a data ' +
        "source's location: a document that reads one does not say what it reads, " +
        'and the value is spliced into a URL that is then fetched. Write a path ' +
        "relative to this document instead (it resolves against the document's " +
        'own directory), or symlink the data to that path.',
    )
  }
  // Substitution-led: the author's own substitution supplies the location, so
  // there is no literal prefix to classify. §8.2 requires unrecognized
  // substitutions to be passed through, so this is left alone.
  if (template.startsWith('{')) return template
  if (SCHEME_RE.test(template)) return template

  const joined = template.startsWith('/')
    ? template
    : absoluteBase(baseDir).replace(/\/+$/, '') + '/' + template
  const resolved = removeDotSegments(joined)
  if (resolved.includes('?') || resolved.includes('#')) {
    throw new EsmDiagnosticError(
      ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
      `url template '${template}' resolves to '${resolved}', whose '?' or '#' would ` +
        'be read as a URL query or fragment rather than as part of the path ' +
        '(esm-spec §8.2.1). Rename or relocate the file.',
    )
  }
  return 'file://' + resolved
}

/**
 * A resolution failure must name the entry AND the template: "io error at
 * /${SNAPSHOTS}/x.parquet" names neither, and a source whose location silently
 * fails to resolve is indistinguishable from one that read zeros.
 */
function resolvedAt(template: string, baseDir: string, where: string): string {
  try {
    return resolveSourceUrl(template, baseDir)
  } catch (e) {
    if (e instanceof EsmDiagnosticError) {
      throw new EsmDiagnosticError(ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED, `${where}: ${e.message}`)
    }
    throw e
  }
}

/**
 * Resolve every `data_sources[*].source` location in `doc`.
 *
 * Returns a rewritten ROOT when something changed, and `null` when nothing did
 * — the same shape (and for the same reason) as `applyScopeInjections`, whose
 * `injectedRoot ?? data` idiom this mirrors.
 *
 * Copy-on-write rather than in-place because `loadDocument(obj)` hands its
 * caller's object straight to `loadInput` with no copy at any level. Rewriting
 * a `source` in place would resolve a location inside a dict the caller still
 * holds — a side effect on an argument, and one that would make a second
 * `loadDocument` of the same object resolve an already-resolved URL against a
 * different base. Only the containers on the path to a changed value are
 * copied, so a document whose templates are already absolute URLs allocates
 * nothing.
 */
export function resolveDataSourceUrls(doc: unknown, baseDir: string): object | null {
  if (doc === null || typeof doc !== 'object') return null
  const root = doc as Record<string, unknown>
  const sources = root['data_sources']
  if (sources === null || typeof sources !== 'object' || Array.isArray(sources)) return null

  const rebuilt: Record<string, unknown> = {}
  let changed = false
  for (const [name, entry] of Object.entries(sources as Record<string, unknown>)) {
    rebuilt[name] = entry
    if (entry === null || typeof entry !== 'object') continue
    const src = (entry as Record<string, unknown>)['source']
    if (src === null || typeof src !== 'object' || Array.isArray(src)) continue

    const loc = src as Record<string, unknown>
    const newLoc: Record<string, unknown> = { ...loc }
    if (typeof loc['url_template'] === 'string') {
      newLoc['url_template'] = resolvedAt(
        loc['url_template'],
        baseDir,
        `data_sources.${name}.source.url_template`,
      )
    }
    const mirrors = loc['mirrors']
    if (Array.isArray(mirrors)) {
      newLoc['mirrors'] = mirrors.map((m, i) =>
        typeof m === 'string'
          ? resolvedAt(m, baseDir, `data_sources.${name}.source.mirrors[${i}]`)
          : m,
      )
    }
    if (
      newLoc['url_template'] === loc['url_template'] &&
      JSON.stringify(newLoc['mirrors']) === JSON.stringify(loc['mirrors'])
    ) {
      continue
    }
    rebuilt[name] = { ...(entry as Record<string, unknown>), source: newLoc }
    changed = true
  }

  if (!changed) return null
  return { ...root, data_sources: rebuilt }
}
