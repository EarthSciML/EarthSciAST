# Native Coverage (`native_coverage`)

The ledger of every document `native` refuses and `interpreter` builds, per
binding, and the check that holds it to one rule: **the count may only fall**.
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
| Rust | `pkg/earthsci-ast-rs/examples/compiler_census.rs` (release build) | one process per document, both compilers in it, under a wall-clock timeout and an address-space cap |

`scripts/native-coverage-census.sh` runs both drivers and the check;
`scripts/native-coverage.sbatch` runs it on a Slurm node; the scheduled
`.github/workflows/native-coverage.yml` runs it weekly and on demand.

Only the **front door** counts. Julia's census falls back to `_build_evaluator`
for a document that needs providers or a model selection `esm_problem` cannot
guess, but a document only the fallback builds is not one a caller can build, so
it counts as not building. After a build, Julia's census also calls the
problem's right-hand side `f!` on `u0`; a build whose call then throws counts as
not building either (code `rhs_call_failed`), since a missing evaluation rule
can fire at call time rather than at construction. Rust builds through
`esm_problem` with the default `Rhs::Auto` and does not call the right-hand
side.

A document is a **native coverage gap** when the interpreter builds it and
native does not. Two kinds of document are never gaps, whatever they answer,
exactly as the research census that measured the first baseline classified
them:

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
    { "path": "tests/…/doc.esm", "code": "compiler_refused_rule",
      "rule": "Model.x", "reason": "…" }
  ]
}
```

An entry has the shape of a compiler-agreement named exclusion, keyed by
document instead of by fixture: `path` is relative to the repository root, or
`EarthSciModels/…` for a document in that repository; `code` is native's error
code (`compiler_refused_rule` for a refusal, the error's own code or type
otherwise, `rhs_call_failed` for a Julia build whose first right-hand-side call
threw); `rule` is the refused rule where the refusal names one; `reason` is the
message, squashed to one line. Entries are sorted by path and unique.
`measured` records what the baseline ran on and is not compared.

## The check

`scripts/native-coverage.py check` compares a fresh census against the ledger.
It is RED when:

| Finding | Why |
|---|---|
| a gap the ledger does not name | native lost coverage — **fix native**, do not add an entry |
| a ledger entry native now builds | "remove this entry": a stale entry would let the same document regress again unnoticed |
| a ledger entry that stopped being a gap another way — the interpreter no longer builds it, or the document left the corpus or became an invalid fixture | the ledger lists gaps and nothing else; remove the entry |
| a ledger entry whose `code` drifted | the refusal the ledger excuses is not the one native now raises; update the entry |
| a corpus document with no record from either compiler | a document the census lost is not a document native builds |

The `reason` text is not compared: messages are reworded without the refusal
changing.

**A document the census could not finish is inconclusive.** A Julia worker
that runs past the timeout (`timeout`) or dies (`crashed`), and a Rust process
that is killed (`killed`), finish or not depending on the machine's load, so
they say nothing about native's coverage. Such a document is reported
(`INCONCLUSIVE` in the check's output, `inconclusive` in its JSON report, and
`inconclusive (excluded)` in the counts) and kept out of the comparison
whichever compiler it was: it is never a new refusal, a ledger entry for it is
neither confirmed nor stale and its code is not compared, and `write-ledger`
keeps such an entry as it was. The ledger therefore never holds a `timeout`,
`crashed` or `killed` entry. The census still has a record for the document,
so it is not "census incomplete".

**The one-way rule is enforced on the file too.** `write-ledger` rewrites a
ledger from a census and refuses to add an entry the committed ledger lacks; it
may drop entries and update the ones it keeps. Only `--baseline`, for a first
measurement, writes a ledger that grows. A change that adds an entry by hand is
a coverage regression, and review is where it is refused.

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
this checkout. When native gains coverage, the check goes red naming the entries
to delete; delete them, or regenerate with `--write-ledger`, which can only
shrink the file.

## Baseline

Measured 2026-09-25 UTC on `native/p1-cross-gates` (EarthSciAST `b36fe61a3`,
the branch after phase 0 of the native universal-coverage plan; the only
uncommitted changes were to the census scripts and this tier's documents) and
EarthSciModels `e298021`, 1,226 documents:

| | Julia | Rust |
|---|---|---|
| both compilers build | 702 | 817 |
| **native gap** (interpreter builds, native does not) | **3** | **75** |
| both fail | 255 | 130 |
| invalid fixture (excluded) | 204 | 204 |
| library fragment (excluded) | 62 | 0 |

Rust builds, under both compilers, all 62 documents Julia reports as library
fragments, so there they count under "both build" and are never gaps either.
No document timed out or crashed in either census.

**Since the baseline.** The scaling tier's committed fixtures
(`tests/conformance/scaling/fixtures/`, 22 documents) and two
`scalar_operator_semantics` fixtures landed after this census, so the first
scheduled census (`native-coverage.yml` run 36175185154, 1,250 documents) saw
four Rust gaps the baseline did not: the scaling tier's `regrid` and
`unstructured_gather` fixtures at both PR sizes, which the scaling tier's own
Rust ledger already lists (phase 3). They were added to `rust.json` then,
which is the one time the Rust ledger has grown. On those 1,250 documents
Rust counts 837 both build, **79 native gaps**, 130 both fail and 204 invalid
fixtures; the Julia census matched its ledger unchanged.

**Julia's three** are per-cell setup evaluations that strict `native` refuses
rather than walking the tree once per cell: a setup-time `makearray` whose
compile-once form declined (`build_once_spatial_ode.esm`), and two array
initial conditions written as a coordinate expression the compile-once seed
declined (`ic_param_override.esm`, `pde_inline_assertions_exec.esm`).

**Rust's seventy-nine**, by what the tape cannot lower:

| Documents | Reason |
|---|---|
| 14 | the whole-rule lowering meets a name it cannot resolve: a loaded forcing field (the EarthSciModels data loaders), a coupled or scoped reference, a loop index |
| 15 | a geometry kernel, `polygon_intersection_area` or `intersect_polygon` |
| 9 | a variable the tape cannot bind, fed by a loader or a provider (the pipeline's per-cell routes) |
| 9 | a recurrence (a causal self-reference), which needs a sequential sweep |
| 8 | a constant-array gather out of range, which native refuses at build and the interpreter reaches only when it evaluates |
| 5 | a `makearray` region whose value does not match the region's box |
| 5 | a `faq` whose overlap join gate drives the enumeration |
| 4 | `reshape`, `transpose` or `concat` |
| 3 | a `faq` with an empty output box, or a `makearray` with an empty region |
| 2 | a ragged (non-static) contraction dimension |
| 2 | a gather through a neighbour table, whose index is neither an affine or periodic map of an output index nor a constant (the scaling tier's `unstructured_gather`) |
| 3 | one each: `ifelse` branches of different shapes under a runtime condition, a variable with its own `element_type`, and a reduction with a filter |
