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

## 3. Determinism

Both parts of §2 are pure functions of the document. The default consults only
`output_idx` order and Unicode name order; `syms` is written down. Neither
touches hash iteration order, so §5.7 rule 5 is untouched: the match set is
still emitted sorted by canonical key, and the driven walk is still an
order-preserving subsequence of the full product.
