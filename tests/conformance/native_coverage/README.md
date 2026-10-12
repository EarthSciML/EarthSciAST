# Native Coverage (`native_coverage`)

The ledger of every document `native` refuses and `interpreter` builds, per
binding, and the check that holds it to one rule: **`native` builds every
document the interpreter builds**, except one carrying a construct outside its
scope — events, implicit equations, SDE noise (`unsupported_construct`) or a
spatial operator with no discretization rule (`unlowered_operator`), as
`API_SPEC.md` §5.8 lists them. A ledger entry may carry only one of those two
codes, and its count may only fall.
Normative text is `CONFORMANCE_SPEC.md` §5.44.6; what `native` and
`interpreter` mean is `esm-libraries-spec.md` §2.5.10.

`compiler_agreement` gates a handful of fixtures closely: a trajectory, within a
band, and each fixture's `required` map names the compilers that must run it.
This tier gates the whole corpus loosely: does `native` BUILD the document at
all, wherever the interpreter does. The two are the same ratchet at two widths.
Neither replaces the other, because a build that succeeds says nothing about
the numbers it produces, and a close check of six documents says nothing about
the other twelve hundred.

## What is measured

The corpus is every `.esm` under `tests/` plus every `.esm` in a checkout of
[EarthSciML/EarthSciModels](https://github.com/EarthSciML/EarthSciModels). A
census builds each one through `esm_problem(path, (0, 1))` twice per binding,
once with `compiler = native` and once with `compiler = interpreter`, and
records what each answered:

| Binding | Census driver | Unit of work |
|---|---|---|
| Julia | `pkg/EarthSciAST.jl/scripts/compiler_census.jl --compiler <c>` | one sweep per compiler, sharded across worker processes that each load the package once; a worker whose document runs past the timeout, or that dies, is recorded and restarted at the next document |
| Rust | `pkg/earthsci-ast-rs/examples/compiler_census.rs` (release build) | one process per document and compiler (`--only native` / `--only interpreter`), each under a wall-clock timeout and an address-space cap; the two halves are merged into one record per document |

`scripts/native-coverage-census.sh` runs both drivers and the check;
`scripts/native-coverage.sbatch` runs it on a Slurm node; the scheduled
`.github/workflows/native-coverage.yml` runs it weekly and on demand.

Only the **front door** counts. Julia's census falls back to `_build_evaluator`
for a document that needs providers or a model selection `esm_problem` cannot
guess, but a document only the fallback builds is not one a caller can build, so
it counts as not building. After a build, Julia's census also calls the
problem's right-hand side `f!` on `u0`; a build whose call then throws counts as
not building either (code `rhs_call_failed`), since a missing evaluation rule
can fire at call time rather than at construction. That includes a stack
overflow or an out-of-memory error in the call, and a record with no `rhs_ok`
that carries an error. Rust builds through
`esm_problem` with the default `Rhs::Auto` and does not call the right-hand
side.

A document is a **native coverage gap** when the interpreter builds it and
native does not. Two kinds of document are never gaps, whatever they answer:

* **invalid fixtures** — any document under an `invalid/` directory. They exist
  to fail, and a refusal there is not coverage;
* **library fragments** — template and coupling libraries, which are imported by
  other documents and have no model of their own to build (their build error
  says so: "nothing to flatten", `coupling_import_not_library`, …).

## The ledger

`julia.json` and `rust.json`, one per binding:

```json
{
  "category": "native_coverage",
  "version": "1.0",
  "binding": "rust",
  "compiler": "native",
  "reference_compiler": "interpreter",
  "measured": { "date": "…", "earthsciast_commit": "…", "earthscimodels_commit": "…",
                "documents": 1226, "counts": { "both build": 0, "native gap": 0, "…": 0 } },
  "entries": [
    { "path": "tests/…/doc.esm", "code": "unsupported_construct",
      "rule": "Model.x", "reason": "…" }
  ]
}
```

An entry has the shape of a compiler-agreement named exclusion, keyed by
document instead of by fixture: `path` is relative to the repository root, or
`EarthSciModels/…` for a document in that repository; `code` is native's error
code, which in a committed entry must be `unsupported_construct` or
`unlowered_operator`. A census records whatever code a gap carries
(`compiler_refused_rule` for a refusal, the error's own code or type otherwise,
`rhs_call_failed` for a Julia build whose first right-hand-side call threw,
`crashed` or `killed` for a build whose process died), and any of those is a
finding to fix in `native`, never an entry; `rule` is the
refused rule where the refusal names one; `reason` is the message, squashed to
one line. Entries are sorted by path and unique.
`measured` records what the census that wrote the ledger ran on and is not compared.

## The check

`scripts/native-coverage.py check` compares a fresh census against the ledger.
It is RED when:

| Finding | Why |
|---|---|
| a ledger entry whose `code` is not `unsupported_construct` or `unlowered_operator` | native is required for every in-scope document, so the ledger excuses nothing else — **fix native** and remove the entry |
| a gap the ledger does not name | native lost coverage — **fix native**, do not add an entry |
| a ledger entry native now builds | "remove this entry": a stale entry would let the same document regress again unnoticed |
| a ledger entry that stopped being a gap another way — the interpreter no longer builds it, or the document left the corpus or became an invalid fixture | the ledger lists gaps and nothing else; remove the entry |
| a ledger entry whose `code` drifted | the refusal the ledger excuses is not the one native now raises; update the entry |
| a corpus document with no record from either compiler | a document the census lost is not a document native builds |

The `reason` text is not compared: messages are reworded without the refusal
changing.

**A document the census timed out on is inconclusive.** Whether a build
finishes inside the census's wall clock depends on the machine's load, so a
timeout (a Julia worker that runs past it, or a Rust half that `timeout`
stopped) says nothing about native's coverage. Such a document is reported
(`INCONCLUSIVE` in the check's output, `inconclusive` in its JSON report, and
`inconclusive (excluded)` in the counts) and kept out of the comparison
whichever compiler it was: it is never a new refusal, a ledger entry for it is
neither confirmed nor stale and its code is not compared, and `write-ledger`
keeps such an entry as it was. The ledger therefore never holds a `timeout`
entry. The census still has a record for the document, so it is not "census
incomplete".

**A build whose process died is a failure, not inconclusive.** A Julia worker
that dies (`crashed`: most often out of memory) or never loads
(`worker_load_failure`), and a Rust half that printed nothing without the
timeout stopping it (`killed`: the address-space cap, an abort, a stack
overflow), fail the same way on every run whatever the load. Each is read as
that compiler not building the document, with that code. So a native build that
blows up in memory on a document the interpreter builds is a new gap and turns
the check red, which is the failure this ledger exists to catch. Because the
Rust census runs each compiler in its own process, a killed half is known to be
that compiler's; a Rust record from before that split, killed with anything but
a timeout's exit status, names no compiler, and the check refuses it as input
(`native-coverage-census.sh` runs such a document again).

**The one-way rule is enforced on the file too.** `write-ledger` rewrites a
ledger from a census and refuses to add an entry the committed ledger lacks; it
may drop entries and update the ones it keeps. Only `--baseline`, for a first
measurement, writes a ledger that grows. An entry added by hand with an in-scope
code is red under `check`; one with an out-of-scope code is still a claim that
the document carries such a construct, and review is where that is confirmed.

`scripts/native-coverage.py self-test` drives the check through each row of the
table above on synthetic records, checks both census readers, and validates both
committed ledgers' shape. It runs in `scripts/test-conformance.sh` as
`native-coverage self-test`, on every conformance run; the census itself is
weekly, because it builds about 1,200 documents twice per binding and half of
them belong to another repository.

## Running it

```bash
# the census and the check, both bindings (EarthSciModels checked out beside this repo)
./scripts/native-coverage-census.sh --earthscimodels ../EarthSciModels --out <dir> --jobs 4

# re-check a census already on disk
./scripts/native-coverage-census.sh --earthscimodels ../EarthSciModels --out <dir> --check-only

# on a Slurm node
sbatch --output=<logdir>/native-coverage-%j.out \
       --export=ALL,NC_OUT=<dir>,NC_MODELS=../EarthSciModels,NC_BINDINGS=julia \
       scripts/native-coverage.sbatch

# the always-on guard
python3 scripts/native-coverage.py self-test
```

The Julia census runs in `pkg/EarthSciAST.jl/scripts/compiler_agreement_env`
(override with `JULIA_CENSUS_ENV`), which must already be instantiated against
this checkout. When a ledgered document starts building under native, the check
goes red naming the entry to delete; delete it, or regenerate with
`--write-ledger`, which can only shrink the file.

## Current state

Both ledgers are empty: wherever the interpreter builds a corpus document, Julia
and Rust `native` build it too. They stay empty unless the corpus gains a
document carrying a construct outside `native`'s scope, and then the entry
carries that refusal's code, `unsupported_construct` or `unlowered_operator`.
