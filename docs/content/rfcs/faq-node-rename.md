---
title: "Renaming the `aggregate` node to `faq`"
description: "The unified query node is renamed from `aggregate` to `faq` (Functional Aggregate Query) at esm 1.1.0. `aggregate` becomes a deprecated alias, normalized on load with a warning and removed at 2.0.0. The `arrayop` alias — declared removed at 0.8.0 but still live in all five bindings — is removed for real."
---

> **Status:** accepted, implemented.
> **Scope:** the `op` tag of the unified query node (RFC
> [`semiring-faq-unified-ir`](semiring-faq-unified-ir.md) §5.6), its schema
> conditional, its five binding implementations, and the corpus.
> **Amends:** `semiring-faq-unified-ir` §5.6, which named the serialized tag
> `"aggregate"` and retained `"arrayop"` as a deprecated alias.
> **Version:** esm 1.1.0 (unreleased at the time of writing; no new version
> number is minted for this change).

---

## 1. Summary

The node that RFC `semiring-faq-unified-ir` introduced as a **Functional
Aggregate Query** is serialized as `"op": "aggregate"`. That tag names one
specialization of the node and mislabels the rest. This RFC renames the
canonical tag to **`"op": "faq"`**.

Three decisions come with it:

1. **`aggregate` becomes a deprecated alias.** It is accepted on load,
   normalized to `faq` in memory, and reported with a new **warning**
   diagnostic `deprecated_op_alias`. It is **removed at esm 2.0.0**, and that
   removal version is written into the spec now rather than left open.
2. **The text surface does not change.** The head keyword in the text form is
   the ⊕-word (`sum`, `prod`, `max`, `min`, `any`), not the node name, and it
   stays that way. See §3.
3. **`arrayop` is removed.** Not deprecated again — removed. §4 explains why
   this is the second attempt.

## 2. Why `aggregate` is the wrong word

The node's fields are `output_idx`, `expr`, `ranges`, `args`, `reduce`,
`semiring`, `join`, `filter`, `distinct`, `key`, `id`. Only `reduce` /
`semiring` are about aggregation. The node also:

- **joins** — `join.on` is an inner equi-join over key columns, and `join.overlap`
  is a spatial broad-phase gate (CONFORMANCE_SPEC §5.5);
- **filters** — `filter` is a boolean predicate gating which index tuples
  contribute;
- **invents values** — `distinct` + `key` enumerate unique Skolem terms;
- **does not necessarily aggregate anything, or even return an array.** Under
  the `bool_and_or` semiring with `distinct: true`, the node is
  index-set-producing: it materializes a `kind: "derived"` index set (RFC
  `semiring-faq-unified-ir` §5.5, §5.2). There is no reduction to a value and
  no array result. Calling that an "aggregate" is simply inaccurate.

A reader who meets `"op": "aggregate"` and reasons from the English word will
form a model of the node that is wrong in every one of those cases. "FAQ" is
the name the design already carries in its own RFC title, in
`CONFORMANCE_SPEC.md`, and in the `area_faq` module that exists in four of the
five bindings. The serialized tag was the last place still using the narrow
word.

**On the acronym.** `faq` collides with a far more common expansion, and this
is a real cost for a format whose readers are earth scientists. The mitigation
is not a different name but consistent expansion: every normative document
spells out **Functional Aggregate Query** at first use in that document, and
the schema's `op` description leads with the expansion.

## 3. Why the text surface is untouched

It is tempting to read the text form's `sum[i, j] (…)` as "the node is spelled
`sum` in text". It is not. The head keyword is the **⊕-word**, selected from
`semiring` / `reduce`, and it is the ASCII spelling of the big operator in the
unicode and LaTeX renderings (`tests/display/RENDERING_CONTRACT.md`):

| ⊕ source | unicode | latex | ascii |
|----------|---------|-------|-------|
| `+` / `sum_product` | `Σ` | `\sum` | `sum` |
| `*` | `Π` | `\prod` | `prod` |
| `max_product` / `max_sum` | `max` | `\max` | `max` |
| `min_sum` | `min` | `\min` | `min` |
| `bool_and_or` | `⋁` | `\bigvee` | `any` |

The three renderings are contractually the same shape. There is no
big-operator glyph for "faq", so renaming the ascii head would either desync
ascii from unicode/LaTeX or force `Σ` to be printed as `faq`. It would also
push the reduction out of the head and into a mandatory trailing
`[semiring=…]` annotation on every node — replacing five heads that read as
mathematics with one that does not.

The parsers therefore keep accepting the same five heads and start **emitting**
`"op": "faq"`; the printers take `faq` in and print the ⊕-word.
`tests/display/RENDERING_CONTRACT.md` is unchanged.

## 4. The `arrayop` precedent, and why this one has a removal date

Before it was `aggregate`, the node was `arrayop`. RFC
`semiring-faq-unified-ir` §5.6 renamed it and retained `"op": "arrayop"` as a
deprecated alias "so existing files keep parsing". `earthsci-ast-rs` records
that the alias was then **removed at esm v0.8.0**
(`pkg/earthsci-ast-rs/src/aggregate.rs`), and its canonical recognizer agrees:

```rust
/// Whether `op` is the aggregate node tag. `"aggregate"` is the canonical tag
/// (RFC §5.6). The legacy `"arrayop"` alias was removed in ESM v0.8.0.
pub fn is_aggregate_op(op: &str) -> bool {
    op == "aggregate"
}
```

The removal did not take. At the time of writing, `"arrayop"` is still a live
string in **all five** bindings — 19 sites in Julia `src`, 12 in Rust `src`, 2
each in Python, Go and the Julia MTK extension, 1 in TypeScript.

The reason it survived its own removal is worth recording, because it is the
failure mode this RFC is trying not to repeat. The 0.8.0 change removed
`arrayop` from the **load** path but not from the **construction** path. Three
Julia sites still *manufacture* `arrayop` nodes internally:

- `pkg/EarthSciAST.jl/src/shape_promotion.jl:304`
- `pkg/EarthSciAST.jl/src/tree_walk/build.jl:2204`
- `pkg/EarthSciAST.jl/src/tree_walk/build_helpers.jl:406`

Every other site is a defensive `op == "aggregate" || op == "arrayop"` branch
that exists to keep those manufactured nodes working. So the tag stopped being
a file-level alias and quietly became an **internal node kind** that the
bindings produce for themselves — invisible to the corpus, invisible to the
schema, and never warned about.

Two further consequences were found while surveying:

- **The schema never knew.** The conditional that requires `output_idx` and
  `expr` keys on `"op": {"enum": ["aggregate"]}` (`esm-schema.json`). An
  `arrayop` node matches no branch, so it bypasses the required-field check
  entirely.
- **No fixture ever used it.** Zero `.esm` or conformance-JSON files in the
  corpus carry `"op": "arrayop"` — the string appeared only in the
  fixture directory and fixture *names* (`tests/fixtures/arrayop/`, renamed to
  `tests/fixtures/faq/` by this change). The alias had no users left to
  protect.

Hence: `arrayop` is deleted outright in this change, the three construction
sites are changed to build `faq` nodes, and the defensive branches go with
them. There is nothing to migrate.

**And hence the rule this RFC adopts for its own alias:** a deprecation
without a removal version is a rename that never finishes. `aggregate` is
accepted at 1.1.0, warned about at 1.1.0, and **removed at 2.0.0**, stated
normatively in `esm-spec.md` §4.2 and in the schema description — not only
here.

### 4.1 What is kept

The Julia ModelingToolkit extension keeps the name `arrayop` wherever it refers
to **SymbolicUtils' own `ArrayOp` construct** — `ext/mtk_ext/arrayop.jl`, the
`_build_arrayop_sym` lowering helper, and comments about `@arrayop`. That is
upstream's vocabulary for an upstream type, not this format's tag for this
format's node, and renaming it would misdescribe the thing it lowers to. The
extension's *dispatch on the wire tag* follows the same rule as everywhere else
and recognizes `faq` only.

## 5. The design

### 5.1 Canonical tag and alias

- `"op": "faq"` is the canonical tag from esm 1.1.0.
- `"op": "aggregate"` is accepted, deprecated, and removed at 2.0.0.
- `"op": "arrayop"` is not accepted — and, per §5.4, is rejected **explicitly**
  rather than left to the open tier.

**Version gate.** A document spelling the node `faq` declares `esm: 1.1.0` or
later, the same rule the top-level `solver` block follows (esm-spec §2.2.4,
`reject_solver_pre_v11`). A 1.0.0 consumer genuinely cannot read `faq`, so the
declaration has to say so. The corpus migration therefore bumps the documents
it rewrites, and the rule is transitive through lowering: a document whose
*expanded* form contains `faq` — a template-library consumer whose imported
rules lower to one, say — declares 1.1.0 even though the authored bytes carry
no `faq` node at all. The conformance cases that pair an input with a lowered
golden were bumped as units for exactly this reason.

### 5.2 Normalize on load; do not preserve on emit

A loader that encounters `"op": "aggregate"` **rewrites the node to `faq` in
memory**. Nothing downstream of the loader — validation, classification,
lowering, evaluation, emission — ever sees the alias, and no binding carries
two spellings past its parse boundary.

Consequently `emit` writes `faq` for a document that was authored with
`aggregate`. This is a deliberate, bounded dent in the esm 0.9.0 `emit ∘ load`
byte-wise fixed point (esm-spec §9.6.4), and the invariant is restated as:

> `emit ∘ load` is a byte-wise fixed point for any document **at the current
> schema version**. A document carrying a deprecated alias is upgraded exactly
> once, on its first load; the upgraded document is then a fixed point.

The alternative — preserving the authored spelling through to emission — was
rejected. It puts both spellings into all five emitters, and the round-trip
conformance gate compares each binding's emission against **its own** re-parse
rather than against the other bindings, so a divergence in which spelling a
binding preserves would not be caught.

### 5.3 The warning

A new diagnostic, severity **warning**:

| Code | Class | Meaning |
|---|---|---|
| `deprecated_op_alias` | Structural | An expression node uses a deprecated `op` spelling. The node is normalized to the canonical tag and loading continues. Names the alias, the canonical tag, and the version at which the alias is removed. |

Warnings are a **classification**, not a wire format: CONFORMANCE_SPEC §7
already establishes this for `operator_compose_partial_merge` and the §4.8.4
units severities, and each binding asserts it idiomatically. As implemented:
`@warn` in Julia (code `E_DEPRECATED_OP_ALIAS`, alongside the existing
`_warn_deprecated_domain_bc`), a `DeprecationWarning` in Python,
`console.warn` in TypeScript, and stderr in Rust and Go (matching
`emit_coupling_warning`, the `operator_compose_partial_merge` channel). This
follows the existing contract and adds no new machinery.

The warning fires **once per document per alias**, not once per node — a file
with four hundred `aggregate` nodes produces one warning, naming the count.

### 5.4 `arrayop` is rejected EXPLICITLY, not left to the open tier

This is the one place where "just delete it" would have been wrong, and it is
worth stating because the obvious implementation is silently broken.

`arrayop` is a perfectly well-formed operator identifier. esm-spec §4.2 admits
**any** identifier that is not in the closed evaluable-core set as an OPEN
rewrite-target op, and loading is deliberately permissive about those. So
simply deleting `arrayop` from the bindings does not make a document carrying
it fail — it makes it *load*, as a user-defined rewrite-target op nobody has a
rule for, and fail much later and much more confusingly as
`unlowered_operator` (or, in a document that never simulates, not at all).

Every binding therefore rejects it by name, at the wire boundary, with a
diagnostic that says where it went:

| Code | Class | Meaning |
|---|---|---|
| `removed_op` | Structural | **Hard error.** An expression node uses an `op` spelling that was REMOVED rather than deprecated. Currently one: `arrayop`, removed at esm 0.8.0, superseded by `faq`. Names the offending node's path. |

Julia has the precedent this follows: the `call` op, removed at v0.3.0, is
rejected with a migration message rather than falling through to the open tier.


## 6. Conformance

- The **corpus is migrated** to `faq`. Leaving 634 fixture occurrences on the
  alias would mean the entire corpus exercises the deprecated path while the
  canonical tag is barely tested.
- A small dedicated suite covers the alias instead:
  `tests/conformance/deprecated_op_alias/` — a document authored with
  `aggregate` that (a) loads, (b) produces exactly one `deprecated_op_alias`
  warning, (c) emits `faq`, and (d) is byte-identical to the same document
  authored with `faq` after one load/emit cycle.
- `tests/invalid/` gains a document carrying `"op": "arrayop"`, pinning that it
  is now rejected.

## 7. Alternatives considered

**Keep `aggregate`.** The status quo is not neutral: it actively teaches the
wrong model of a node whose Boolean specialization returns an index set. The
cost of the rename is mechanical and one-time; the cost of the wrong name is
paid by every new reader.

**Rename to `query`.** Self-explanatory to a non-database reader, no acronym
collision, and still says "more than a reduction". Rejected because it is
*less* precise in the other direction — the node is not a general query, it is
specifically an FAQ over a semiring, and that is the property the entire IR is
built on. Precision was the reason for the rename; trading it away in the new
name would be self-defeating.

**Hard break with no alias.** Rejected: the corpus is migrated by codemod, but
downstream `.esm` files outside this repo are not, and a 1.x minor version is
not where a hard break belongs. The alias plus a stated 2.0.0 removal gives
downstream one major version of notice — which is exactly what `arrayop` never
got.
