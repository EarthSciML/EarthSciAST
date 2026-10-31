# `solver.time_span` Conformance (`tests/conformance/solver_time_span/`)

Cross-language conformance for **esm-spec §2.2.7**: what a document's
`solver.time_span` means in seconds. Design: GitHub issue #550 (RFC U16).
Gate: CONFORMANCE_SPEC §5.49.

`time_span` is the interval a document is meant to be simulated over:
`{start, end}`, each a number in the document's time units (seconds) or an RFC
3339 UTC timestamp. A timestamp counts seconds from the document's time origin
— `domain.temporal.reference_time`, else `domain.temporal.start`, else the
POSIX epoch — computed from the fields as `(W − W₀) + (f − f₀)`, never through
a host date library. Every binding parses, validates, gates and round-trips the
field, refuses an interval that is no interval at load, and exposes the
converted value through `resolve_time_span` (`resolveTimeSpan`,
`ResolveTimeSpan`), where an explicit call-site interval wins.

## Files

| File | What it is |
|------|------------|
| `manifest.json` | The SHARED pin: every case, its expected seconds and emitted `solver` block or its refusal, the call-site cases, and the clock accessors' cases. |
| `fixtures/<id>.esm` | One document per case. A document has one `time_span` and one time origin, so each case is its own file. |
| `fixtures/mount_*.esm`, `fixtures/leaves/*.esm` | A root mounting a leaf whose `solver` carries `time_span`, at both mount forms. Two leaves would be refused on their own — one reversed, one at esm 1.2.0 — and the root still loads. |

## How a binding consumes it

For each `fixtures[]` entry, load `path` (relative to this directory) by path.

- `expect: "accepted"`: `resolve_time_span(file)` with no call-site interval
  MUST equal `seconds` exactly (binary64 equality; `null` means no interval),
  and the root's `solver` block as `emit` writes it MUST equal `solver` once
  both are parsed as JSON, numbers compared by value (`null`: no `solver` key).
- `expect: "refused"`: the load MUST fail with `error_code`, and the message
  MUST contain every `message_contains` substring.

For each `call_site.cases[]` entry, load `fixtures/<fixture>.esm` and call the
accessor with `call_site` as the explicit interval; it MUST return `resolved`.

For each `clock.cases[]` entry (Julia, Python and Rust, the bindings that
carry the clock accessors of API_SPEC §5.8), call `time_origin` and
`timestamp_to_seconds` with `domain`, the raw JSON value (null: the document
has none). When `typed` is true, also call them with the typed domain built
from it and with a document built in memory that carries it. `time_origin`
MUST give `origin`, and `timestamp_to_seconds` each entry of `timestamps`:
`seconds` exactly, or a refusal with `error_code`. A binding whose signature
admits only a string timestamp skips a non-string one.

Every pinned value is exact in binary64, so no tolerance applies.
