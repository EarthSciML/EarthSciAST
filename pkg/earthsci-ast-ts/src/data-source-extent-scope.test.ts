/**
 * A discovered `extent` binds where the NAME is declared, not only at the root.
 *
 * esm-spec §8.9.4 lets a data source measure its own record count and bind a
 * metaparameter an index set is sized by. The count arrives as a §9.7.6 site-4
 * loader-API binding, so these tests bind it directly: loading with
 * `{ metaparameters: { N_REC: 3 } }` is exactly what extent discovery hands the
 * loader, and it exercises the same path without needing a file on disk.
 *
 * Three separable properties are pinned here:
 *
 *  * the mounting document need not RESTATE a metaparameter the leaf it mounts
 *    already declares (§9.7.6 site 4, widened past "the root document's");
 *  * a `subsystems.<k>` mount edge forwards the loader-API bindings into the
 *    leaf's own close, so the axis sizes from the data instead of falling
 *    through to the leaf's placeholder default (§4.7 "Two mount forms, one
 *    mechanism");
 *  * whether a leaf resolves does not turn on an `expression_template_imports`
 *    entry it never calls.
 *
 * SCOPE. This binding implements only the `subsystems.<k>` mount form — a
 * top-level `models.<k>` `{ref}` is carried in the schema types but never
 * inlined — and it does not implement §8.9.4 extent DISCOVERY (no data file is
 * ever sampled). So the shared fixtures that mount at the top level are used
 * only where the property under test does not need the mount to resolve, and
 * the cross-form equality the Python oracle pins is out of reach here. The
 * static half of §8.9.4 IS fully reachable: it is a pure document check.
 *
 * The fixtures are shared with the other bindings and live under
 * `tests/fixtures/` rather than `tests/valid/`, because the corpus sweep would
 * score this binding a false pass on the top-level mount form it does not
 * implement.
 */
import { describe, expect, it } from 'vitest'
import * as path from 'node:path'
import { loadPath } from './parse.js'
import { resolveSubsystemRefsSync } from './ref-loading.js'
import { fixturesDir } from './test-helpers.js'
import type { EsmFile } from './types.js'

const DIR = fixturesDir('fixtures', 'data_source_extent_scope')

/** Load a fixture and inline its `{ref}` mounts, as a host driving both steps does. */
function loadMounted(name: string, metaparameters?: Record<string, number>): EsmFile {
  const full = path.join(DIR, name)
  const file = loadPath(full, metaparameters ? { metaparameters } : undefined)
  resolveSubsystemRefsSync(file, path.dirname(full))
  return file
}

/** The merged `records` axis declaration, whatever shape the registry holds. */
function records(file: EsmFile): unknown {
  return (file as unknown as { index_sets?: Record<string, unknown> }).index_sets?.records
}

function sizeOf(file: EsmFile): unknown {
  return (records(file) as { size?: unknown } | undefined)?.size
}

/** The canonical diagnostic code off whatever the load threw. */
function codeOf(fn: () => unknown): string {
  try {
    fn()
  } catch (e) {
    return (e as { code?: string }).code ?? String(e)
  }
  throw new Error('expected the load to throw, but it succeeded')
}

describe('§9.7.6 site 4 reaches a name only a MOUNTED document declares', () => {
  it('does not make the root restate a mounted leaf’s metaparameter', () => {
    // The thin root owns the `data_sources` entry and declares NO
    // `metaparameters`; the leaf it mounts as a subsystem declares `N_REC` and
    // is sized by it. The discovered extent is a loader-API binding, and the
    // site-4 check used to ask only whether the ROOT declared the name — so
    // every assembly had to carry a second, identical `metaparameters` block
    // that configured nothing. The check now accepts a name declared by any
    // document the root mounts, and the mount edge forwards the value into the
    // leaf's own close.
    const file = loadMounted('extent_root_subsystem.esm', { N_REC: 3 })
    expect(sizeOf(file)).toBe(3)
  })

  it('still refuses a loader-API binding NO document declares', () => {
    // Widening the check must not delete it. A name neither the root nor
    // anything it mounts declares is still `template_import_unknown_name` —
    // §9.7.6: bindings never invent metaparameters, a typo fails loudly.
    expect(codeOf(() => loadMounted('extent_root_subsystem.esm', { N_RECS: 3 }))).toBe(
      'template_import_unknown_name',
    )
  })

  it('loads the declared case standalone, with no loader bindings at all', () => {
    // The widened check and the static §8.9.4 check must not refuse the
    // ordinary case: an `extent` whose metaparameter the mounted leaf declares
    // loads at that leaf's own default (§8.9.4: "declare the metaparameter with
    // a `default` so the document still validates and loads standalone").
    const file = loadMounted('extent_root_subsystem.esm')
    expect(sizeOf(file)).toBe(0)
  })
})

describe('an UNUSED template import does not decide whether a leaf resolves', () => {
  it('resolves the same with and without an import the leaf never calls', () => {
    // Two assemblies differing by ONE import of a library the leaf never calls.
    //
    // Whether a mounted leaf folded strictly used to be a whole-document
    // boolean — does it carry ANY §9.7 machinery — so adding that import
    // flipped the leaf from "axis merges symbolically and the assembler closes
    // it" to `metaparameter_unbound`. Factoring a shared expression into a
    // library is not supposed to change whether a document's shape resolves.
    //
    // The assertion is DIFFERENTIAL rather than absolute on purpose: where the
    // §4.7 merge sits relative to the mounting document's own §9.7.6 close
    // still differs across bindings (RFC `mount-edge-index-set-renaming.md`
    // open question 2), so the portable contract is that the two spellings
    // agree with each other.
    const withImport = loadMounted('assembler_root_with_import.esm')
    const noImport = loadMounted('assembler_root_no_import.esm')
    expect(records(withImport)).toEqual(records(noImport))
  })
})

describe('§8.9.4 statically: an extent nobody declares is refused at load', () => {
  it('refuses an `extent` naming an undeclared metaparameter, naming it', () => {
    // `extent` names `N_RECS`; neither the root nor the leaf it mounts declares
    // it. This used to load clean and fail only once the source was SAMPLED, at
    // build — the same validate/build split §9.7.6's own binding sites had. It
    // is decidable from the document alone, so it is decided at load.
    //
    // Purely a document check, so it fires on the top-level-mount fixture even
    // though this binding never inlines that mount form.
    let err: unknown
    try {
      loadMounted('extent_undeclared_root.esm')
    } catch (e) {
      err = e
    }
    expect((err as { code?: string } | undefined)?.code).toBe('template_import_unknown_name')
    expect(String((err as Error).message)).toContain('N_RECS')
  })
})

describe('the site-4 backfill is FILTERED to the names the leaf declares', () => {
  it('does not forward a loader binding the leaf does not declare', () => {
    // Here the assembler declares `N_REC` and the leaf it mounts declares
    // nothing. Forwarding the whole loader-API map into the leaf's close would
    // raise `template_import_unknown_name` against a leaf that never asked for
    // the name — and, worse, would let an assembler's unrelated metaparameter
    // silently resize a leaf axis the edge never bound (esm-spec §4.7).
    const file = loadMounted('assembler_root_with_import.esm', { N_REC: 5 })
    expect(file).not.toBeNull()
    expect(sizeOf(file)).not.toBe(5)
  })
})

describe('the backfill filter is PER-NAME, not merely per-document', () => {
  it('hands the leaf the name it declares and withholds the one it does not', () => {
    // The assembler declares `N_OTHER` and the leaf declares `N_REC`, so the
    // loader-API map carries one name the leaf must receive and one it must
    // not. A filter that withholds the whole map from a leaf declaring NOTHING
    // looks correct against every other fixture here and still lets an
    // assembler's unrelated metaparameter through to a leaf that declares
    // something — which is how an unbound `NLEV: default 12` silently resizes a
    // leaf axis the edge never bound (esm-spec §4.7).
    const file = loadMounted('assembler_partial_overlap_root.esm', { N_REC: 3, N_OTHER: 7 })
    expect(sizeOf(file)).toBe(3)
  })
})
