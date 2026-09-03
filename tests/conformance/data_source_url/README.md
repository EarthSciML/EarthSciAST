# Data-Source Location Resolution Conformance (`tests/conformance/data_source_url/`)

Cross-language conformance for **esm-spec §8.2.1**: where a
`data_sources[*].source.url_template` points. Design note:
`docs/content/rfcs/portable-data-source-urls.md`.

A `url_template` used to be taken literally. The runtime required an explicit
scheme, and once it had one it neither expanded environment variables nor
resolved the path against the referencing document's directory — so only
`file:///absolute/path` read anything, and a document whose data lives outside
its own repository could not name its own inputs. §8.2.1 replaces that with one
rule, REQUIRED of every binding: a scheme-less template is a filesystem path,
and a relative one resolves against the directory of the file it was read
from — the same base and the same timing rule §4.7 fixes for a `ref`.

## What this set pins, and why it is shaped this way

| File | What it is |
|------|------------|
| `manifest.json` | The SHARED pin: every fixture, every expected resolution, and the refusal contract. |
| `fixtures/relative_catalog.esm` | One `data_sources` entry per row of the §8.2.1 resolution table. |
| `fixtures/env_var_catalog.esm` | A `url_template` needing `${VAR}` — must be REFUSED. |
| `fixtures/env_var_mirror_catalog.esm` | The same refusal reached through a `mirrors` entry. |

**No per-binding adapter, and no golden.** Each binding's own test suite reads
`manifest.json` and asserts against it:

| Binding | Test |
|---|---|
| Julia | `pkg/EarthSciAST.jl/test/data_source_url_conformance_test.jl` |
| TypeScript | `pkg/earthsci-ast-ts/src/data-source-urls.test.ts` |
| Python | `pkg/earthsci-ast-py/tests/test_data_source_url_conformance.py` |
| Rust | `pkg/earthsci-ast-rs/tests/data_source_url_conformance.rs` |
| Go | `pkg/earthsci-ast-go/pkg/esm/data_source_url_conformance_test.go` |

`./scripts/test-conformance.sh` runs all five of those suites already, so the
rule is covered by the stages that exist rather than by a sixth producer. What
makes that sufficient here is that §8.2.1 is a **document normalization**, not a
runtime behaviour: it is observable through `parse` alone, in every binding
including a validate-only one (Go has no ingest at all), which is exactly why
the rule was specified at load time rather than at fetch time.

**Expectations are repo-relative paths, not literal URLs.** A resolved
`url_template` is a machine-specific absolute `file://` URL, so a golden holding
one would only ever pass on the machine that wrote it. Each pin is either
`{"repo_path": "..."}` — the binding asserts
`"file://" + abspath(<repo root>/<repo_path>)`, dot segments already removed —
or `{"verbatim": "..."}`, for a template §8.2.1 leaves unchanged because it was
already a URL or was substitution-led.

**Nothing here exists on disk.** §8.2.1 resolution is lexical (RFC 3986 §5.2.4,
never `realpath`) precisely so that a template carrying a `{date:…}`
substitution — which names one file per timestep, none of which exists at load
time — resolves like any other. A fixture pointing at a real file would hide a
binding that had reached for the filesystem.

## The refusal is half the contract

`env_var_catalog.esm` and `env_var_mirror_catalog.esm` are the direction that
matters. The failure §8.2.1 replaces was `io error at /${MOVES_SNAPSHOTS}/…`:
a message about a path nobody wrote, one step away from a source that quietly
delivers a consuming parameter's `default` and compares nothing. So the tests
assert more than "it did not resolve" — they assert the diagnostic code
(`data_source_url_unresolved`) **and** that the message names the offending
entry and the offending template. A binding that refused with a vague message
would pass a weaker test and still leave the next person guessing.

The mirror fixture exists because a mirror is an optional fallback, which makes
it the tempting place to be lenient. Being lenient there is how a catalog
acquires an entry nobody can resolve without anyone noticing: the primary keeps
working until the day it does not.

## The corpus fixtures next door

Two more fixtures enter the ordinary `tests/valid` / `tests/invalid` sweep, so
every binding's validator is held to the rule with no new machinery at all:
`tests/valid/data_source_relative_url.esm` must be accepted, and
`tests/invalid/data_source_url_env_var.esm` must be rejected (pinned
`resolver_only` in `tests/invalid/expected_errors.json` — the document is
schema-valid, so the rejection is the resolver's).
