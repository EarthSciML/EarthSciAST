# `solver.external` Resolution Conformance (`tests/conformance/solver_external/`)

Cross-language conformance for **esm-spec §2.2.6**: where a document's
`solver.external` points. Design: GitHub issue #538 (RFC U1). Gate:
CONFORMANCE_SPEC §5.47.

`solver.external` names a run-configuration document: the schedule, the
algorithm per operator, per-operator tolerances. EarthSciAST never opens it.
What every binding does is parse it, validate it, gate it on version,
round-trip it verbatim, and resolve it to a location **on request**, through an
accessor. Resolution is a pure string function, so it is required of all five
bindings, and this suite pins one answer per document.

The rule is the §8.2.1 table without its substitution-led row: a URL is
unchanged; an absolute path (one beginning `/`, or a drive letter `C:/` /
`C:\`) has its dot segments removed, is percent-encoded and is prefixed
`file://`; anything else is joined onto *D* (the directory of the file read,
the process working directory for a string load, or an explicit base), dot
segments removed, percent-encoded, prefixed `file://`. A `${` in the ROOT
document's `external` is refused at load, before schema validation.

Unlike a `url_template`, the resolved location is **not** written into the
document. The typed document keeps the authored string, `emit` writes the
authored string, and the location comes from the accessor. That is why this
suite asserts two things per fixture — what the document holds and what the
accessor returns — where `data_source_url` asserts one.

## Files

| File | What it is |
|------|------------|
| `manifest.json` | The SHARED pin: every case, its expected `external`, location and emitted `solver` block, the refusal contract, the invariance pair and the advisory-gate fixture. |
| `fixtures/<row>.esm` | One document per row of the §2.2.6 table: `dot_relative`, `bare_relative`, `parent_relative`, `dot_segments_collapse`, `absolute_path`, `file_url`, `https_url`. A document has one `external`, so each row is its own file. |
| `fixtures/space_hash.esm`, `fixtures/non_ascii.esm`, `fixtures/absolute_encoded.esm`, `fixtures/url_not_reencoded.esm` | Percent-encoding: a space and a `#`, non-ASCII names, a literal pin including `%` → `%25`, and a URL whose escapes are left alone. |
| `fixtures/env_var.esm` | `"${RUNS}/x.json"` — must be REFUSED. |
| `fixtures/mount_*.esm`, `fixtures/leaves/*.esm` | A root mounting a leaf whose `solver` carries `external`, at both mount forms. The root reports its own value, or none. Two leaves carry an `external` that would be refused on its own — one holding `${`, one at esm 1.2.0 — and the root still loads: the leaf's block does not cross the mount, so neither load-time check applies to it. |
| `invariance/with_external.esm`, `invariance/without_external.esm` | The same model with and without `external`, for each binding's flatten test. |

The advisory-gate fixture lives with the other simulation fixtures, at
`tests/simulation/solver_external_advisory.esm`, so the existing
`tests/simulation` sweeps in Julia, Python and Rust run it with no new wiring.

**Nothing named here exists on disk** — no `runs/` directory, no `elsewhere/`
directory, no `.run.json` file. Resolution is lexical and never touches the
filesystem; a target that existed would hide a binding that had reached for it.

## The manifest entry format

Each entry of `fixtures`:

```json
{
  "id": "parent_relative",
  "path": "fixtures/parent_relative.esm",
  "load": "path",
  "base": null,
  "expect": "accepted",
  "external": "../runs/probe.run.json",
  "location": {"repo_path": "tests/conformance/solver_external/runs/probe.run.json"},
  "solver": {"external": "../runs/probe.run.json"}
}
```

| Key | Meaning |
|---|---|
| `path` | The fixture, relative to this directory. |
| `load` | `"path"`: load the fixture by its path (the binding's path loader). `"string"`: read the file's text and load it with the binding's string loader, so no file directory is recorded. |
| `base` | `null`, or `{"repo_path": <dir>}`: the **explicit base** to pass to the accessor's base argument, made absolute against the repository root. It replaces the recorded *D*. |
| `external` | The string the typed document holds at `solver.external` after load, or `null` when the root has none. |
| `location` | What the accessor returns: `{"repo_path": p}` → `"file://" + encode(<repo root>/p)`; `{"cwd_path": p}` → `"file://" + encode(<process working directory>/p)`, dot segments removed; `{"verbatim": s}` → `s`, compared as written; `null` → no location (`nothing` / `None` / `null` / Rust `Ok(None)` / Go `nil`, `false` or `""`, whatever that binding's accessor returns for "none"). |
| `solver` | The root document's `solver` block exactly as `emit` writes it, compared as parsed JSON (numbers numerically). `null` means the emitted document has no `solver` key. |
| `expect: "refused"` + `error_code` + `message_contains` | The load MUST fail with `error_code`, and the message MUST contain every listed substring. |

`repo_path` and `cwd_path` are the only way an absolute location enters an
expectation: a resolved location is machine-specific, so a golden holding one
would pass only on the machine that wrote it.

`encode` is the esm-spec §2.2.6 percent-encoding, and a consumer applies it to
the WHOLE expanded path — the repository root or working directory included,
since a checkout may live under a directory whose name needs it: each byte of
the path's UTF-8 encoding outside `A`–`Z` `a`–`z` `0`–`9` `-` `.` `_` `~` `/`
`:` becomes `%XX`, uppercase hex. So `space_hash`'s pin
`tests/conformance/solver_external/fixtures/runs/case #2.json` expects
`file://<encoded repo root>/tests/conformance/solver_external/fixtures/runs/case%20%232.json`.
Each consumer writes its own small `encode` for this; it MUST NOT call the
binding's accessor or resolver to build an expectation.

## How a binding consumes it

There is **no adapter and no golden**. Each binding's own test suite reads
`manifest.json` and asserts against it, exactly as the `data_source_url` suite
is consumed. The test file names below are the ones the bindings use:

| Binding | Test | Wiring |
|---|---|---|
| Julia | `pkg/EarthSciAST.jl/test/solver_external_conformance_test.jl` | `include`d from `test/runtests.jl`, beside `data_source_url_conformance_test.jl` (runtests lists its files explicitly) |
| TypeScript | `pkg/earthsci-ast-ts/src/solver-external.test.ts` | discovered by vitest |
| Python | `pkg/earthsci-ast-py/tests/test_solver_external_conformance.py` | discovered by pytest |
| Rust | `pkg/earthsci-ast-rs/tests/solver_external_conformance.rs` | an integration-test target, discovered by cargo |
| Go | `pkg/earthsci-ast-go/pkg/esm/solver_external_conformance_test.go` | discovered by `go test ./...` |

Every binding's test does the same five things:

1. **Resolution.** For each `expect: "accepted"` entry: load it as `load` says
   (by path, or from the file's text); assert the typed document's
   `solver.external` equals `external`; call the accessor with `base` (absent
   when `null`) and assert it equals the expanded `location`; emit the document
   and assert its `solver` equals `solver`.
2. **Refusal.** For each `expect: "refused"` entry: loading MUST fail; the error
   carries `error_code` (read the code out of the binding's code registry, not a
   string literal in the test, as `data_source_url_conformance.rs` does) and the
   message contains every `message_contains` entry.
3. **No disk.** Nothing a fixture names exists. A test MUST NOT create the
   targets; a binding that stat-ed or opened one fails resolution or refuses.
4. **Round-trip stability.** For at least one relative fixture, emit, write the
   emitted text to a DIFFERENT directory, reload it, and assert `external` is
   still the authored string (the resolved form is never written back, so the
   new directory changes the accessor's answer and not the document).
5. **Invariance.** Load `invariance.with` and `invariance.without`, flatten
   every model of each, and assert the flattened systems are identical — the
   binding's own flatten-equality comparison, on its own flattened type or on
   its emitted flattened JSON.

The advisory-gate fixture needs no test of its own: `tests/simulation/` is
already swept by `test/tests_blocks_execution_test.jl` (Julia),
`tests/test_simulation_fixtures_blocks.py` (Python) and
`tests/tests_blocks_execution.rs` (Rust). It MUST NOT be added to any of their
skip lists.

`./scripts/test-conformance.sh` needs no new stage: it runs each binding's own
suite (CI already runs those directly and passes `--skip-binding-suites`), and
the corpus fixtures next door enter its validation sweep.

## The corpus fixtures next door

Six more fixtures enter the ordinary `tests/valid` / `tests/invalid` sweep:

| Fixture | Pin |
|---|---|
| `tests/valid/solver_external.esm` | accepted, all five `solver` fields, round-trips verbatim |
| `tests/valid/solver_external_only.esm` | accepted; a block holding only `external` is not empty and survives `parse → emit` |
| `tests/invalid/solver_external_version_too_old.esm` | `resolver_only`, `resolver_error_code: solver_external_version_too_old`, `is_valid: false` for all five |
| `tests/invalid/solver_external_env_var.esm` | `resolver_only`, `resolver_error_code: solver_external_unresolved`, `is_valid: false` for all five |
| `tests/invalid/solver_external_empty.esm` | schema error `minLength` at `/solver/external` |
| `tests/invalid/solver_external_nonstring.esm` | schema error `type` at `/solver/external` |

The two `resolver_only` pins are documents the version-agnostic schema accepts;
the rejection is each binding's load-time gate. Every binding implements the
gate, so none of the five may accept either file.
