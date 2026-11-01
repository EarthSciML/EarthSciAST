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
export const SCHEME_RE = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//

/**
 * RFC 3986 §5.2.4 dot-segment removal, lexically, on an absolute path.
 *
 * Never a filesystem `realpath`: a template carrying a `{date:…}` substitution
 * names a file that need not exist at load time, and resolving symlinks would
 * make the resolved URL depend on the filesystem rather than on the document.
 */
export function removeDotSegments(path: string): string {
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
/**
 * `s` without its trailing slashes. A scan rather than `/\/+$/`, which
 * backtracks quadratically on a long run of slashes not at the end.
 */
function stripTrailingSlashes(s: string): string {
  let end = s.length
  while (end > 0 && s[end - 1] === '/') end--
  return s.slice(0, end)
}

function absoluteBase(baseDir: string): string {
  const b = (baseDir || '.').replace(/\\/g, '/')
  if (b.startsWith('/')) return b
  const cwd =
    typeof process !== 'undefined' && typeof process.cwd === 'function'
      ? process.cwd().replace(/\\/g, '/')
      : '/'
  return stripTrailingSlashes(cwd) + '/' + b
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

  // A document loaded from a URL has a URL for a directory: a relative
  // location joins onto it by RFC 3986 §5.2, as its relative refs do (§4.7).
  if (SCHEME_RE.test(baseDir) && !template.startsWith('/')) {
    return joinUrlDirectory(baseDir, template)
  }
  const joined = template.startsWith('/')
    ? template
    : stripTrailingSlashes(absoluteBase(baseDir)) + '/' + template
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
 * RFC 3986 §5.2 resolution of the relative path `rel` against the DIRECTORY
 * URL `base` (`scheme://authority/path`, read as a directory whether or not it
 * ends in `/`), with dot segments removed. A query or fragment on `base` is
 * dropped, as §5.2.2 drops them for a path reference. Written out rather than
 * `new URL(...)`, which would percent-encode a `{…}` substitution.
 */
export function joinUrlDirectory(base: string, rel: string): string {
  const cut = base.search(/[?#]/)
  const b = cut >= 0 ? base.slice(0, cut) : base
  const afterScheme = b.indexOf('://') + 3
  const slash = b.indexOf('/', afterScheme)
  const pathStart = slash >= 0 ? slash : b.length
  const origin = b.slice(0, pathStart)
  const joined = stripTrailingSlashes(b.slice(pathStart)) + '/' + rel
  const trailing = joined.endsWith('/') || joined.endsWith('/.') || joined.endsWith('/..')
  let path = removeDotSegments(joined)
  if (trailing && !path.endsWith('/')) path += '/'
  return origin + path
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

/**
 * The bare `{name}` placeholders in a template, in order of appearance, as
 * `[start, end, name]` (esm-spec §4.7 "Binding a data source's location at the
 * mount").
 *
 * Only a brace pair enclosing a C identifier is a placeholder a mount edge can
 * bind; a formatted substitution such as `{date:%Y%m%d}` is not, so an edge can
 * never rewrite the runtime's own date expansion.
 */
export function placeholders(template: string): Array<[number, number, string]> {
  const out: Array<[number, number, string]> = []
  for (const m of template.matchAll(/\{([A-Za-z_][A-Za-z0-9_]*)\}/g)) {
    out.push([m.index, m.index + m[0].length, m[1]])
  }
  return out
}

/** Every `url_template` / `mirrors` string of `doc`'s `data_sources`, as get/set sites. */
function locationSites(
  doc: unknown,
): Array<{ site: string; get: () => string; set: (v: string) => void }> {
  const out: Array<{ site: string; get: () => string; set: (v: string) => void }> = []
  if (doc === null || typeof doc !== 'object') return out
  const sources = (doc as Record<string, unknown>)['data_sources']
  if (sources === null || typeof sources !== 'object' || Array.isArray(sources)) return out
  for (const [name, entry] of Object.entries(sources as Record<string, unknown>)) {
    if (entry === null || typeof entry !== 'object') continue
    const src = (entry as Record<string, unknown>)['source']
    if (src === null || typeof src !== 'object' || Array.isArray(src)) continue
    const loc = src as Record<string, unknown>
    if (typeof loc['url_template'] === 'string') {
      out.push({
        site: `data_sources.${name}.source.url_template`,
        get: () => loc['url_template'] as string,
        set: (v) => {
          loc['url_template'] = v
        },
      })
    }
    const mirrors = loc['mirrors']
    if (Array.isArray(mirrors)) {
      mirrors.forEach((m, i) => {
        if (typeof m !== 'string') return
        out.push({
          site: `data_sources.${name}.source.mirrors[${i}]`,
          get: () => mirrors[i] as string,
          set: (v) => {
            mirrors[i] = v
          },
        })
      })
    }
  }
  return out
}

/**
 * Apply a mount edge's `url_substitutions` to the referenced document's
 * `data_sources`, in place (esm-spec §4.7 "Binding a data source's location at
 * the mount").
 *
 * `doc` is the referenced document as resolved at this edge and `binderDir` is
 * the directory of the MOUNTING document, the one that wrote the edge. Three
 * rules:
 *
 * - A key names a bare `{key}` placeholder of some location in `doc`; one that
 *   names none is `url_substitution_unknown_name`, so a misspelt key fails at
 *   the edge rather than leaving the placeholder for a read to trip over.
 * - A value is text: a string carrying no `{` or `}`, so a substitution never
 *   introduces another one (`data_source_url_unresolved` otherwise).
 * - Who wrote the location decides what it anchors on (§8.2.1). A placeholder
 *   that LEADS a template supplies the whole location, so the bound value is
 *   the mounting document's location and a relative one joins onto
 *   `binderDir`. A placeholder anywhere else is a segment of a location the
 *   referenced document wrote, so the value is spliced in as text and the
 *   result resolves against the referenced document's directory, as before.
 *
 * A placeholder the edge does not bind is left as written (§8.2 pass-through).
 * A location already `file:///…` after the splice is re-normalized here, since
 * §8.2.1 leaves a scheme-led template alone and a spliced `..` must not survive.
 */
export function applyMountUrlSubstitutions(
  doc: unknown,
  substitutions: unknown,
  binderDir: string,
  where: string,
): void {
  if (substitutions === undefined) return
  if (substitutions === null || typeof substitutions !== 'object' || Array.isArray(substitutions)) {
    throw new EsmDiagnosticError(
      ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
      `${where}: \`url_substitutions\` must be an object mapping a placeholder name to a string (esm-spec §4.7)`,
    )
  }
  const values = new Map<string, string>()
  for (const [k, v] of Object.entries(substitutions as Record<string, unknown>)) {
    if (typeof v !== 'string') {
      throw new EsmDiagnosticError(
        ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
        `${where}: \`url_substitutions.${k}\` must be a string, got ${JSON.stringify(v)} (esm-spec §4.7)`,
      )
    }
    if (v.includes('{') || v.includes('}')) {
      throw new EsmDiagnosticError(
        ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
        `${where}: \`url_substitutions.${k}\` = ${JSON.stringify(v)} carries a brace; a bound value is text and may not introduce another substitution (esm-spec §4.7)`,
      )
    }
    values.set(k, v)
  }
  if (values.size === 0) return

  const sites = locationSites(doc)
  const present = new Set<string>()
  for (const s of sites) for (const [, , n] of placeholders(s.get())) present.add(n)
  for (const k of values.keys()) {
    if (!present.has(k)) {
      throw new EsmDiagnosticError(
        ERROR_CODES.URL_SUBSTITUTION_UNKNOWN_NAME,
        `${where}: \`url_substitutions\` binds '${k}', which no \`url_template\` or \`mirrors\` entry of the referenced document's data_sources spells as a placeholder \`{${k}}\` (available: [${[...present].sort().join(', ')}]); a mount edge never invents a placeholder (esm-spec §4.7)`,
      )
    }
  }

  // The value a LEADING placeholder contributes: the mounting document's
  // location, per §8.2.1's own forms.
  // A mounting document loaded from a URL has a URL for a directory; a
  // relative value then joins onto it by RFC 3986 §5.2, as that document's own
  // relative refs do (§4.7).
  const remoteBinder = SCHEME_RE.test(binderDir)
  const base = remoteBinder ? binderDir : stripTrailingSlashes(absoluteBase(binderDir))
  const lead = (v: string): string =>
    SCHEME_RE.test(v) || v.startsWith('/')
      ? v
      : remoteBinder
        ? joinUrlDirectory(base, v)
        : base + '/' + v

  for (const s of sites) {
    const t = s.get()
    const found = placeholders(t).filter(([, , n]) => values.has(n))
    if (found.length === 0) continue
    let out = ''
    let last = 0
    for (const [start, end, n] of found) {
      const val = values.get(n)!
      out += t.slice(last, start) + (start === 0 ? lead(val) : val)
      last = end
    }
    out += t.slice(last)
    if (out.startsWith('file:///')) {
      const p = removeDotSegments(out.slice('file://'.length))
      if (p.includes('?') || p.includes('#')) {
        throw new EsmDiagnosticError(
          ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
          `${where}: ${s.site}: the substituted location ${JSON.stringify(out)} carries a '?' or '#' (esm-spec §8.2.1)`,
        )
      }
      out = 'file://' + p
    }
    s.set(out)
  }
}
