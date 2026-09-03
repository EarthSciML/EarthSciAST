# Design note — a relation joined to itself: two `aggregate` ranges over one index set

Status: accepted, implemented.
Scope: `aggregate.join.on` resolution (RFC `semiring-faq-unified-ir` §5.3,
CONFORMANCE_SPEC.md §5.5.8).
Downstream: EarthSciAST-consumer finding **F11**, "a relation cannot be joined
to itself".

## 1. What was refused, and why

An `aggregate` whose `ranges` draw two symbols from ONE index set could not
carry a `join.on` clause over data columns of that index set. Rust reported

```
Compile failed: Unsupported feature 'value-equality join over data-derived
columns': join key column 'r_priorID' does not resolve to a loop index of this
aggregate ({"b", "a"}): it names neither a range symbol, nor an index set one
of those ranges draws from, nor a declared 1-D data column over such an index
set
```

and Julia, from the same shape, `E_TREEWALK_JOIN_AMBIGUOUS_KEY` — "join key
'row_ax' names an index set bound by multiple range symbols ["a", "b"];
reference the range symbol directly".

**Root cause.** Resolving an `on` key column to the loop symbol it is read at
goes through the column's **axis**:

```
key column  --shape[0]-->  index set  --set_to_syms-->  loop symbol
```

`set_to_syms` is one-to-many the moment two ranges draw `{from}` the same index
set, and both reference implementations deliberately decline an ambiguous
lookup rather than pick (Rust `join.rs::resolve_key` returns `None` on
`syms.len() != 1`; Julia `_join_sym_for_key` throws). The data-column branch
then has no symbol, and the LEFT key's `None` is the error above.

The error message was accurate about every clause it listed and wrong about the
conclusion: `r_priorID` *is* a declared 1-D data column over `row_ax`, and
`row_ax` *is* an index set the ranges draw from. What failed was the resolution
**strategy**.

**Which of the three candidate causes it is.** Not a validator rule — `validate`
accepts the document; the refusal is in build-time join lowering. Not a defect
in the join kernel or the enumeration driver either: `relational::equijoin` and
`reduce_contraction_gated` are addressed purely by range-SYMBOL name and never
consult the symbols' axes, so they were always able to drive a pair of symbols
over one index set. It is a **genuine underdetermination in the format**, of a
kind that only shows up here: an `on` pair `["r_priorID", "r_id"]` names two
columns, and when both columns' axis is drawn by two symbols, nothing in the
document says which symbol each column is read at. `["a", "b"]` and `["b", "a"]`
are both consistent readings and they compute transposed results. Declining was
therefore the right behaviour for the information available; the fix has to add
information, not guess better.

## 2. The design

Two parts: a canonical default that makes the ordinary two-range self-join
spellable with no new syntax, and an explicit spelling for everything the
default cannot determine.

### 2.1 A node's canonical range order

Every binding already needs a total order on an `aggregate`'s range symbols —
it is the enumeration order, and §5.5.8's fourth drive shape is stated in terms
of "the LATER of the two gated axes". That order is:

1. the `output_idx` symbols, in the order `output_idx` lists them;
2. then the contracted symbols (in `ranges` but not `output_idx`), in ascending
   Unicode code-point order of their names.

This note names it and reuses it; it introduces no new ordering.

### 2.2 Default side assignment (two candidates)

For one `on` pair, let `C` be the node's range symbols that draw the key
column's axis, in canonical range order. Today's rule is the `|C| == 1` case.
Additionally:

* `|C| == 2` — the **LEFT** key is read at `C[0]` and the **RIGHT** key at
  `C[1]`. Left-to-earlier is the reading the construct's own grammar suggests:
  in a one-output self-join the output symbol is `C[0]`, so the pair reads "for
  each output row, match the row whose `r_id` equals my `r_priorID`", which is
  what an author writing `[["r_priorID", "r_id"]]` means. It is also the
  orientation §5.5.8's partner-restricted walk already assumes.
* `|C| >= 3` — **refused**, with a build error naming the candidates and
  pointing at §2.3. Silently taking the first two would be a guess, and a guess
  here produces a plausible wrong number rather than a failure.

A pair whose two sides resolve to the same symbol stays what it is today: a
predicate-only comparison of two columns of one table, no drivable gate.

### 2.3 Explicit `syms` on the clause

A `join` clause may carry `"syms": [<left symbol>, <right symbol>]`, naming the
two range symbols this clause's pairs are read at. It is the authoritative
answer to the question §1 says the document could not previously express, and
it is required for `|C| >= 3`.

```json
{ "on": [["sched_priorID", "sched_id"]], "syms": ["cur", "prev"] }
```

Both entries MUST name range symbols of the node. Every pair in the clause is
then resolved left-at-`syms[0]`, right-at-`syms[1]`; a key naming an index set
or a data column whose axis the named symbol does not draw is a build error, as
is a key naming a range symbol other than its side's.

`syms` names symbols the node **binds**, not variable references. Like
`overlap.sym_src` / `overlap.sym_tgt`, it is therefore invisible to flattening's
dot-namespacing and to `variable_map` renaming — which is the reason this is a
clause field and not a qualified `"sym.col"` key string. A dotted key string
would collide with §5.5.6's namespacing of join names, whose `ns` rule already
inspects the head of a dotted name.

### 2.4 What is deliberately NOT added

* No lag / offset / shift feature. The two sides differ by carrying **different
  key columns**, which is an ordinary key expression. A predecessor lookup is
  `[[prior_id_column, id_column]]`, nothing more; the format learns nothing
  about time series.
* No new relational semantics. Inner-only, many-to-many, exact-equality keys,
  identity fill for an unmatched row: unchanged, and a self-join is subject to
  all of them.
* No change to the join kernel or the driver. A self-join is driven by the same
  `equijoin` match set and the same `reduce_contraction_gated` plans as any
  other `on` gate, so it is `O(|L| + |R| + |matches|)` and never the product.

## 2.5 Two resolution steps, one of which has the gap

§2.2's default applies to the DATA-COLUMN step only, and the distinction is
load-bearing. §5.5.8 resolves a key in two steps:

1. the key names a **loop symbol or an index set**;
2. otherwise it names a **data column**, and the symbol comes from the column's
   declared 1-D axis.

An ambiguity in step 1 is one the author can already fix without any new
syntax: name the range symbol instead of the index set, which is exactly what
the pre-existing diagnostic advises. So an index-set key drawn by several
symbols stays an **error**, however many candidates it has, and only `syms`
resolves it. An ambiguity in step 2 is one the author cannot fix at all — the
pair holds column names, and the axis is a property of the column rather than
of the clause. That is where the default belongs, and only there.

Without the split, `on: [["county", "i"]]` with `i` and `j` both drawing
`county` would resolve its left key to `i` by default, find the right key
already naming `i`, and drop the pair as a tautology: a build error traded for
an ungated full product. Adding a capability must not remove a diagnostic.

## 2.6 Why this lands without a schema version bump

`SCHEMA_CHANGE_PROCEDURE.md` calls for a MINOR bump on a new optional field,
and this note deliberately does not take one. `syms` is purely additive: every
document written before it validates and evaluates unchanged, and a document
using it needs no version declaration to be accepted (the version gate rejects
only a MAJOR mismatch).

What a bump would cost is not in this feature. `1.0.0` is the floor AND the
current ceiling of the migration additive line, and the shared, cross-binding
fixture set `tests/version_compatibility/` exists to pin what happens on either
side of it — `version_1_1_0_minor_upgrade.esm` asserts that a MINOR above
current has no migration target, `version_1_0_5_patch_upgrade.esm` and
`version_1_0_100_large_patch.esm` likewise. Moving current to `1.1.0` inverts
all three expectations, plus `compatibility_matrix.json`'s `library_version`
and its README, in a fixture set all five bindings read. Measured: the bump
alone turned 12 green Python tests red, none of them about joins.

That is a release decision about the migration contract, not a consequence of
adding a field, and it belongs in its own change. The schema `description`
records the new field so it is not undocumented in the meantime.

## 2.7 The refusals are validation rules, stated about the document

Both refusals in §2.2 and §2.3 began as build errors raised where each
implementation happens to resolve a join. That is the wrong place for them, and
the wrong way to say them. Both are decidable from the single file — the node's
`ranges`, the document `index_sets`, the declared variable shapes and the
clause are all in it — so they are `validate()` findings with codes every
binding carries:

* `join_side_ambiguous` — the document does not determine a range symbol for an
  `on` key.
* `join_syms_unknown_symbol` — a `syms` entry the node does not bind.

The negative cases live in **one shared fixture set**,
`tests/invalid/aggregate/build_time/self_join_*.esm`, pinned by `(code, path)`
in `tests/invalid/expected_errors.json`. That file is what
`scripts/compare-conformance-outputs.py` reads for its check B (every
`tests/invalid/**` must be rejected, per binding, no exceptions) and check C
(every rejection must carry the pinned findings), so
`./scripts/test-conformance.sh` fails if any one binding accepts a fixture or
reports a different code or a different pointer. Per-binding tests are kept as
well, but they are not the enforcement: a rejection asserted only in each
binding's own suite is one every binding can pass while disagreeing.

## 3. Determinism

Both parts of §2 are pure functions of the document. The default consults only
`output_idx` order and Unicode name order; `syms` is written down. Neither
touches hash iteration order, so §5.7 rule 5 is untouched: the match set is
still emitted sorted by canonical key, and the driven walk is still an
order-preserving subsequence of the full product.
