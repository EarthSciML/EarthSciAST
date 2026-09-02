# Design note — a portable form for `data_sources[*].source.url_template`

**Date:** 2026-09-02
**Spec sections touched:** `esm-spec.md` §8.2 (normative), §4.7 (cross-reference)
**Bindings:** Julia, TypeScript, Python, Rust, Go — all five, mandatory
**Motivating defect:** downstream finding F15, "a `url_template` has no portable form"
(`moves.esm/docs/findings/README.md`)

---

## The defect

`source.url_template` was taken literally. The runtime required an explicit URL
scheme (a bare path failed as `bad url … missing scheme`), and once it had one
it neither expanded environment variables nor resolved the path against the
directory of the document that declared it. Only `file:///absolute/path` read
anything, so a document whose data lives outside its own repository could not
name its own inputs.

The downstream consequence, measured: 27 declared sources across 2 catalog
files, and a test harness that had to rewrite every document with `sed` before
running it —

```sh
sed "s|\${MOVES_SNAPSHOTS}|$SNAP_ABS|g" "$f" > "$run"
```

so the document the repository reviews and the document the toolchain runs were
not the same bytes, and `esm validate` could not be pointed at the real thing.

## The two candidate mechanisms

Finding F15 offered both, and they are not exclusive:

1. **Document-relative resolution** — the rule §4.7 already fixes for a `ref`:
   *"Relative path … Resolved relative to the directory of the referencing
   file."*
2. **Environment expansion** of `${VAR}` in `url_template`, which §4.7 also
   already allows for a `ref`.

## Decision

**Adopt (1), mandatory in all five bindings. Reject (2), and refuse it loudly.**

### Why (1), and why mandatory

A `url_template` is the last place in the format where a path is resolved
differently from every other path in the format. §4.7's rule is already the
one authors know, it is already implemented in every binding for refs, and it
already has the base directory threaded to the point of use (each binding's
load pipeline carries a `base_path` / `baseDir` / `basePath` for exactly this).
Making `url_template` obey it is a *removal* of a special case, not an
addition of a feature.

Mandatory, not optional, because the acceptance condition here is portability.
§4.7 makes `${VAR}` expansion and URL refs OPTIONAL binding capabilities, with
a per-binding matrix — Julia and Python expand `${VAR}`, Rust/TS/Go do not.
That is tolerable for a ref, whose failure is a loud unresolved-file
diagnostic. It is *not* tolerable for the rule that decides where a
document's data comes from: a document that resolves its inputs under Julia
and not under Rust is precisely the non-portability this change exists to
remove. So the relative rule is required for conformance, and a binding that
cannot resolve a relative `url_template` is non-conforming rather than
"reduced capability".

### Why not (2) — environment expansion

Three reasons, in order of weight.

**It makes the document non-reproducible.** A document that reads `${VAR}` from
the ambient environment does not say what it reads. Two runs on one machine can
ingest different tables with no diff between them, and the record of what was
ingested lives in a shell, not in the repository. Every other input to an ESM
run is in the file; this would be the only one that is not. That is the
opposite of what a source catalog is for.

**It is an injection surface.** The expanded value is spliced into a URL that
is then *fetched*. An environment variable is attacker-controllable in more
settings than people expect (CI job config, a `.env` a dependency wrote, a
container's inherited environment), and a value containing `://`, `@`, `?`,
`#`, or `..` can redirect the fetch to a different scheme, a different host, or
a different file without changing a byte of the document. Constraining it well
enough to be safe means constraining it to the point where it no longer buys
the flexibility that motivated it.

**It is not needed to fix F15.** The relative rule alone closes the finding.
The motivating data lives in a sibling checkout — `moves.rs/characterization/snapshots`
next to `moves.esm` — which a relative path from the declaring document names
exactly, and which the finding itself accepts as sufficient ("**Either**
removes the materialization step").

The one thing (2) buys that (1) does not is "one catalog serving several
machines with the data at different absolute paths". That case is already
served, better, by two existing mechanisms: a **symlink** at the relative
location, which keeps the machine-specific part out of the document *and* out
of the environment; and the ingest-time **URL override** the provider
constructors already take (`url_overrides` in Rust
`providers_from_document`), which puts the machine-specific part in the
caller's code where it is visible.

### Refuse, do not ignore

The characteristic failure of this toolchain is a plausible wrong value rather
than an error — a `data_sources` entry read by no provider once returned zeros
silently, and so did a published `earthsciio` shadowing a local checkout. So
"we do not expand `${VAR}`" must not mean "we treat `${VAR}` as a directory
name and fail with an I/O error about a path nobody wrote". A resolved
`url_template` or mirror that still contains a `${` is a **load-time error**,
`data_source_url_unresolved`, whose message names the data source, the offending
template, and the reason. The same code covers a resolved path carrying a `?` or
`#`, which would silently change the meaning of the URL the path is spliced
into.

This is the direction §4.7 chose for refs too ("an **unset** variable is left
literal, so the ref fails to resolve with the ordinary unresolved
diagnostic … rather than misresolving"); here the refusal is unconditional
rather than contingent on the variable being unset, because the variable is
never consulted.

## The rule, normatively

Stated in `esm-spec.md` §8.2. In summary, applied at **load time** — before
schema validation and before any other processing, the same timing rule §4.7
fixes for refs — to `source.url_template` and to every entry of
`source.mirrors`:

| Form | Test | Resolution |
|---|---|---|
| URL | matches `^[A-Za-z][A-Za-z0-9+.-]*://` | used as-is |
| Substitution-led | first character is `{` | used as-is (the author's substitution supplies the location) |
| Absolute path | begins `/` | dot segments removed, then `file://` + path |
| Relative path | anything else | joined onto the referencing document's directory, dot segments removed, then `file://` + path |

Dot-segment removal is **lexical** (RFC 3986 §5.2.4), never `realpath`: a
template with a `{date:…}` substitution names a file that need not exist at
load time, and a binding that resolved symlinks here would make the resolved
URL depend on the filesystem rather than on the document.

The result is **idempotent** — a resolved URL is already scheme-led, so a
second pass is a no-op. That is what keeps `parse → emit → parse` stable.

For a document loaded from a string or an in-memory value rather than a path,
the base directory is the process working directory, exactly as it already is
for a relative `ref` in the same situation.

## Consequences

**The resolved form is what emit carries.** Resolution is a load-time
normalization of the document, like §4.7 ref inlining, so `esm convert` /
`esm emit` on a document with a relative `url_template` writes the resolved
absolute `file://` URL. This is deliberate and it is what makes the rule
checkable in a validate-only binding (Go has no ingest at all): the rule is
observable in every binding through parse → emit, which is what the
cross-language corpus already compares. The authored relative form stays in the
source file, which is the file under review.

**Backwards compatible.** Every spelling that worked before still works: an
absolute `file:///…` URL is scheme-led and is used as-is. Nothing that
previously resolved changes.

**F7 is fixed as a side effect, not made worse.** F7 records that
`esm round-trip` resolves a relative `ref` against the process working
directory instead of the document's directory, because `run_round_trip` calls
`load_string` and never supplies a base. Leaving that alone would have given
`url_template` *two* resolution rules — the document's directory under
`validate`/`test`, the CWD under `round-trip` — which is the bug class this
change exists to close. So `run_round_trip` now loads with the file's own
directory as the base for every round. The downstream workaround (the
round-trip stage `cd`-ing into each document's directory) becomes dead weight;
it stays harmless.

## What a downstream document now looks like

Before — the checked-in document could not ingest, and the harness rewrote it:

```jsonc
"source": {
  "url_template": "file://${MOVES_SNAPSHOTS}/nr-logging-county/tables/…__nrscc.parquet"
}
```

After — checked in, byte-identical to what runs, `esm validate` and `esm test`
both pointed at the real file:

```jsonc
"source": {
  "url_template": "../../moves.rs/characterization/snapshots/nr-logging-county/tables/…__nrscc.parquet"
}
```

(relative to the directory of the declaring `.esm`), and the `sed` stage is
deleted.

## Conformance

Normatively: `esm-spec.md` §8.2.1 states the rule, `CONFORMANCE_SPEC.md` §5.19
states what is compared and why `bindings_required` is all five, and
`ESM_COMPLIANCE_VALIDATION_MATRIX.md` carries it as FORMAT-08-A-002a/b and
BEHAV-08-B.


`tests/conformance/data_source_url/` pins the rule: fixtures covering one
`url_template` per row of the §8.2.1 table, and a `manifest.json` giving each
one's expected resolution as a path relative to the **repository root** (an
absolute expectation would only pass on the machine that wrote it).

There is **no sixth conformance stage and no per-binding adapter**: each
binding's own suite reads that manifest and asserts against it, and
`./scripts/test-conformance.sh` already runs all five suites. What makes that
sufficient is the decision above — §8.2.1 is a *document normalization*
observable through `parse` alone, so even a validate-only binding (Go has no
ingest at all) can be held to it. Had the rule been specified at fetch time
instead, Go could not have conformed and there would have been nothing to pin.

Two fixtures also enter the ordinary `tests/valid` / `tests/invalid` corpus
sweep, so every binding's validator is held to the rule with no new machinery
at all: `tests/valid/data_source_relative_url.esm` must be accepted, and
`tests/invalid/data_source_url_env_var.esm` — a `url_template` carrying
`${VAR}` — must be **rejected**, by all five.

## Two corrections to the above, from the implementation

**Two Julia-local fixtures had to change.**
`pkg/EarthSciAST.jl/test/fixtures/data_sources/wrf.esm` and `era5.esm` spelled a
local mirror as `file://${WRF_MIRROR}/…` / `file://${ERA5_LOCAL}/…` — exactly
the pattern this note refuses, and the only two places in the repository that
used it. They now spell it the portable way, a path relative to the fixture,
which is what they were reaching for. Nothing in the shared `tests/` corpus used
`${…}` in a `url_template`, so the refusal invalidates nothing that was being
tested; those two fixtures now *exercise* the new rule in Julia's own suite
instead of documenting the old workaround.

**Go resolves on the typed struct, not on the JSON text.** Every other binding
rewrites the raw document. Go's load pipeline is text-based and records the
AUTHORED key order off that text (`extractTemplateOrders`), which
esm-libraries-spec §4.7.5 step 4 makes normative for every `FlattenedSystem`;
decoding to a `map[string]any` and re-encoding it to substitute two strings
would destroy that order. The typed field is the same value the serializer
emits, so the resolved form still reaches `emit` and the observable rule is
identical.

**A third correction: the pass had to become copy-on-write.** As first written it
rewrote `data_sources[*].source` in place. Harmless in Rust, Go and Julia, whose
load paths already copy; a defect in Python (`load_document` only
*shallow*-copies) and TypeScript (`loadDocument` does not copy at all), where the
nested `source` dicts still belong to the caller. The visible symptom would not
have been a crash: a second load of the same in-memory document would resolve an
ALREADY-RESOLVED template, and against a different base that succeeds and reads a
different file. That is the silent-wrong-value failure this note's refusal
argument is about, arriving through the success path instead — so both bindings
now pin it with a test that loads one dict twice against two different bases.
