# Known defects in the shared corpus

Fixtures under `tests/valid/` are the cross-binding definition of "a valid
document": every binding drives its conformance suite from them. Three of them
did **not** survive reference resolution when this file was opened in phase 6,
found while adding `build_reference_graph` to TypeScript and checking it against
Python — the two bindings agreed exactly on all three, which is why it had gone
unnoticed: no binding was running the resolver over the whole valid corpus.

**All three defects are now closed.** Defect 1 is **fixed** and its recorded
diagnosis turned out to be wrong. Defect 2 is **ruled and implemented** in all
five bindings. Defect 3 is **fixed** and, unlike the other two, was a bug in the
five bindings rather than in the corpus — it had TWO instances, the second of
which defect 2 was hiding, and one change repaired both.

Reproduce (measured **93 fixtures, 93 resolve, 0 raise**; before the defect-3
fix it was 93 / 91 / 2, both remaining raises being defect 3 with the same error
code):

```bash
PYTHONPATH=pkg/earthsci-ast-py/src python3 - <<'PY'
import json, glob, earthsci_ast as e
for f in sorted(glob.glob("tests/valid/**/*.esm", recursive=True)):
    try: e.resolve_references(json.load(open(f)))
    except Exception as ex: print(f, type(ex).__name__, ex)
PY
```

Each section below carries its own status; read it, because for two of the three
the fixture was not at fault. Note that the failure count did not fall by two
when defect 2 landed: fixing it unmasked a second instance of defect 3 on the
same fixture, and only defect 3's repair cleared both — see #3.

## 1. `aggregate/skolem_distinct_rank.esm` — FIXED (phase 6b)

**The recorded diagnosis was wrong, and the repair was one line.**

This entry used to read: "The producer node was described and never written …
Fixing this means authoring the missing index-set-producing `aggregate` per RFC
semiring-faq-unified-ir §5.5/§5.7, which is fixture work needing the RFC
author's intent, not a mechanical repair."

Both observations it rested on were true. `index_sets.edges.from_faq` named
`"edge_set"`; a recursive walk over every object in the document found **zero**
`"id"` keys; and `edge_set` appeared exactly twice, in the `from_faq` and in an
`_comment`. The **inference** drawn from them was not: the node was never
absent.

The `_comment` is not a description of a node someone meant to write. It is the
doc-comment **on that node**, sitting in the same equation object as a sibling
of the `lhs` / `rhs` it annotates, and it opens by saying so — *"edge_set: the
index-set-producing node referenced by `index_sets.edges.from_faq`"*. The node
itself was at `/models/EdgeEnumeration/equations/0/rhs` all along, complete:
`op: aggregate`, `semiring: bool_and_or`, `distinct: true`, the skolem `key`
over the sorted endpoints, `filter`, `expr`, `ranges`, `output_idx`. Every field
the RFC and the `_comment` call for was already written.

The only thing missing was `"id": "edge_set"` — the one field that makes the
node addressable, and the one field the schema does **not** require, which is
exactly why the fixture was schema-valid and reference-broken at the same time.
Nothing was underdetermined: the id's VALUE is pinned by the `from_faq` string
it has to match, and `esm-schema.json` says so inline (`from_faq` is "the id of
the index-set-producing node … named by its `id`").

**Fix:** `"id": "edge_set"` added to that node, placed after `"op"` to match
the near-twin fixture `tests/valid/cadence/pure_topology.esm`, which carries the
same `index_sets` names, the same `ranges` keys, the same `output_idx` and the
same `key` shape — and does carry the id. The fixture now resolves, and still
validates.

The resolver needs nothing else of a `from_faq` target: `build_reference_graph`
registers any node carrying a non-empty string `id`, and checks only that the
`from_faq` value is among them. It never inspects `op`, `semiring`, `distinct`,
`key`, `ranges` or `output_idx` to resolve the reference.

Unpinned in the two bindings that recorded the rejection —
`pkg/earthsci-ast-go/pkg/esm/reference_graph_test.go`
(`referenceCorpusRejections`) and
`pkg/earthsci-ast-ts/src/reference-resolution.test.ts` (`KNOWN_UNRESOLVED`) —
which is the failure those pins exist to produce.

## 2. `wildfire_atmosphere_ocean.esm` — a RESOLVER/SPEC defect — **FIXED**

`E_REF_UNKNOWN_FAQ_NODE`: `index_sets.rg_candidate_pairs.from_faq` named
`"rg_candidate_set"`, and **that node exists** — at
`/models/OceanDynamics/equations/2/rhs`. The error said it "is not the id of any
expression node in model `'AtmosphericDynamics'`".

That was the bug. `index_sets` is **document-scoped** (`esm-schema.json` declares
it only at `/properties/index_sets` — the same scoping fact behind API_SPEC §8
item 17), but `from_faq` was resolved within **one model's** scope. A
document-scoped derived index set whose producer lives in a different model was
therefore unresolvable, and this fixture is exactly that shape: the atmosphere
model consuming a candidate-pair set produced by the ocean model.

**RULED (phase 6): `from_faq` is document-scoped.** `esm-spec.md` §9.7.5 states
it normatively, and `esm-schema.json`'s `id` description widens node-id
uniqueness from per-model to per-document to match — a document-scoped registry
whose entries could only name one model's nodes is incoherent, and per-model
uniqueness would leave a cross-model reference ambiguous. Verified before
ruling: **no fixture in `tests/` reuses an `id` across models**, so the widened
uniqueness requirement invalidates nothing that exists.

**LANDED in all five bindings.** Each collects node ids from every model in the
document before any single model's graph is built; a `from_faq` may name a
producer in any model, and the consuming model's graph gains a real vertex for
the foreign node (path `models/<Model>/<local path>`) so the partition pass can
walk `index_set → node` across the model boundary. A `from_faq` naming no node
in the document is still `unknown_faq_node`; the same `id` in two models is now
`E_REF_DUPLICATE_NODE_ID`.

`tests/valid/aggregate/cross_model_from_faq.esm` is the minimal cross-binding
fixture for the ruling, and every binding pins it.

**This defect is closed.** After it landed, `wildfire_atmosphere_ocean.esm`
still did not resolve — but for defect #3's reason, not this one. That is fixed
too now; see below.

## 3. `geometry/conservative_regrid_assembly.esm` — a RESOLVER defect — **FIXED**

It used to raise `E_REF_UNRESOLVED_JOIN_FACTOR`: join factor `'src_bin'` of node
`node:candidate_set` (`/models/ConservativeRegridAssembly/equations/2/rhs`)
"names no factor, range, or output index in scope". Six equations in the model
carry the same `join: [{"on": [["src_bin", "tgt_bin"]]}]`.

The open question was whether the fixture omits a binder or the resolver fails
to see one. **It was the resolver, in all five bindings.** The fixtures are
unchanged; `reference_resolution.*` / `reference_graph.*` changed in every
binding — see "The fix, as landed" below.

### The evidence (unchanged; this is what the repair was built on)

**1. The normative text names three binder classes; the resolvers implemented
one.** `esm-spec.md` §4.9.5 says an `on` key column is **polymorphic** — a loop
symbol bound by the enclosing `ranges`, a document-scoped index set (§9.7.5), or
a declared component-local variable — and that a binding diagnosing such a name
"must do so against the variable **and** index-set registries". CONFORMANCE_SPEC
§5.5.6 says the same and adds the ordering: a name the node BINDS is tested
first, then a declared local variable, then anything else is left alone. It
names the third class explicitly, as a "value-invention bin buffer".

Every binding's `factor_scope` helper consulted exactly three **node-local**
sources — the node's string `args`, its `ranges` keys, and its symbolic
`output_idx` — and neither registry, even though `build_reference_graph` holds
both (it already uses `index_sets` for `ranges[*].from`).

`src_bin` and `tgt_bin` are class three: `models.ConservativeRegridAssembly.
variables` declares both, each shaped over the join's range index set
(`src_bin: shape ["src_cells"]`, `tgt_bin: shape ["tgt_cells"]`), and equations
0 and 1 write them as the per-cell skolem bin buffers.

**2. The engines execute this document.** Running Python's value-invention front
door over the model returns `join_key_buffers` keyed `{'src_bin', 'tgt_bin'}` —
the engine binds both names, under exactly the spellings the `join.on` uses.
`numpy_interpreter`'s join-key resolver is written for precisely this case ("a
materialized value-invention MAP buffer"); Julia's `_namespace_join` documents
this fixture family by name; Julia's `geometry_assembly_conformance_test.jl`
drives the whole fixture end-to-end. `validate_path` returns `is_valid: True`
with no structural error and no unit warning. A document the semantic engines
run is not reference-broken.

**3. The scope set was self-inconsistent on fixtures everyone already accepts.**
`tests/valid/aggregate/join_filter.esm` and
`.../join_moves_running_exhaust.esm` join on `["src", "sourceType"]` — and
`sourceType` is a document-scoped index set, in no `args`, no `ranges` key and
no `output_idx`. They passed only because no binding validated `pair[1]` at all;
the resolvers checked the left column and ignored the right. Applying the OLD
scope test to the right column would have made an accepted, canonical fixture
fail. So the implemented rule could not have been the intended rule even on the
corpus it passed.

**4. Nothing requires a join key column to appear in the node's `args`.** Not
`esm-schema.json` (`on` items are just `[left, right]` strings), not RFC
semiring-faq-unified-ir §5.3, not the spec. The three fixtures that resolved
under the old rule did so because whoever authored them happened to list the
columns in `args`. That is a coincidence of authorship, not a binder.
`E_REF_UNRESOLVED_JOIN_FACTOR` itself appears in no spec, no schema and no RFC —
only in the five bindings and their tests.

### ⚠ A second instance, and what defect 2 did to it

`wildfire_atmosphere_ocean.esm` has the same shape. Its producing node
`rg_candidate_set` (`/models/OceanDynamics/equations/2/rhs`) carries
`join: [{"on": [["rg_src_bin", "rg_tgt_bin"]]}]`, and `rg_src_bin` /
`rg_tgt_bin` are model **variables** — defined at equations 0 and 1 with an
indexed LHS — not that node's args, range keys, or `output_idx`. Defect #2 had
been masking this: `index_sets` is document-scoped, so the `from_faq` lookup ran
for EVERY model's graph and failed on whichever model each binding built first
(`AtmosphericDynamics` in document order, `AirSeaFluxCalculator` in Go's sorted
order) — always before `OceanDynamics`, so the join error never fired. With #2
fixed the fixture raised `E_REF_UNRESOLVED_JOIN_FACTOR` for `'rg_src_bin'`
instead.

So the sweep did not fall by two when defect 2 landed — one of the two fixtures
defect 2 fixed simply began failing here instead. One change repairs both.

### The fix, as landed

`factor_scope` is gone from all five bindings. In its place each carries a
`join_binder_class` (`joinBinderClass` in TypeScript and Go,
`_join_binder_class` in Julia) which reports WHICH binder class a join name
resolves to, testing the classes in the order CONFORMANCE_SPEC §5.5.6 fixes —
the order is normative because a node-local binder SHADOWS a same-named
variable (esm-spec §4.3.1 permits one string to be a variable reference outside
an aggregate and an index symbol inside one):

1. node-local binders — `ranges` keys and symbolic `output_idx` entries, FIRST;
2. node-local string factor `args`;
3. **the model's variable registry** — where a value-invention bin buffer or an
   overlap envelope factor lives. This was the omitted step that produced the
   failure;
4. **the document-scoped index-set registry** — already threaded in for
   `ranges[*].from`, and previously never consulted here;
5. only then `E_REF_UNRESOLVED_JOIN_FACTOR`.

The check is now applied to **both** key columns of every `on` pair, which it
could not be before (see evidence 3). Only the LEFT column carries the
`join_factor` graph edge — the right column is frequently a document-scoped
index set, which already has its own vertex kind, and inventing a
`factor:sourceType` twin of `index_set:sourceType` would be worse than leaving
it un-edged. A non-string right column is left to the schema, where
`tests/invalid/aggregate/join_on_key_not_string.esm` already pins it; the left
column keeps its existing "non-string ⇒ unresolved factor" behaviour.

Julia additionally validates `overlap`'s `src_env` / `tgt_env` against the same
scope and was misfiring the same way; it now resolves them through class 3,
which CONFORMANCE_SPEC §5.5.6 says is where envelope factors always live. (The
other four bindings still do not validate `overlap` names at all — a separate,
pre-existing divergence, not part of this defect.)

The error message changed in all five, identically:
`join factor '<name>' of node <key> names no range, output index, factor arg,
declared variable, or index set in scope (model '<M>', at <path>)`.

**Measured, whole `tests/valid` corpus:**

| | before | after |
|---|---|---|
| fixtures | 93 | 93 |
| resolve | 91 | **93** |
| raise | 2 | **0** |

Both raises were `E_REF_UNRESOLVED_JOIN_FACTOR`, on the two fixtures above. Each
binding runs the sweep in its own suite (Python `test_reference_resolution.py`,
TypeScript `reference-resolution.test.ts`, Go `TestReferenceGraphOverValidCorpus`,
Julia `reference_graph_test.jl`), and the five-binding conformance run
(`compare-conformance-outputs.py` over all 245 validation files) still passes.

`tests/valid/aggregate/join_filter.esm` was the live trap here: it joins on
`["src", "sourceType"]`, where `sourceType` is a document-scoped index set in no
`args`, no `ranges` key and no `output_idx`. It survived only because `pair[1]`
was never validated. It resolves under the new rule through class 4, which is
the direct check that the widening is the SPEC's rule and not merely a
convenience for the two broken fixtures.

**This is not "accept anything".** Each binding carries a negative test — a
document declaring a variable, an index set, a bound range and a string arg, so
every registry the check consults is non-empty — asserting that a name in NONE
of the four classes still raises `E_REF_UNRESOLVED_JOIN_FACTOR`, on either key
column.

### The fixture-side workaround, and why it was not taken

A mechanical repair existed: add `"args": ["src_bin", "tgt_bin"]` to each of the
six aggregates here and the five in wildfire's `OceanDynamics`, matching how
`bin_skolem_spatial_join.esm` and `conservative_regrid_overlap_join.esm` were
authored. It is semantically harmless. But adopting it as *the* fix would have
ratified a rule the spec does not state, would have left `join_filter.esm`'s
index-set column unresolvable the moment `pair[1]` is checked, and would have
left §4.9.5's "must diagnose against the variable and index-set registries"
unimplemented in all five bindings. It was **not** taken.

---

The pins that recorded these rejections are updated rather than deleted.
TypeScript's `KNOWN_UNRESOLVED` and Go's `referenceCorpusRejections` are now
EMPTY maps, still asserted as an exact partition, so a regression that starts
rejecting a valid fixture surfaces as a partition failure rather than as the
weaker "never errors". The per-fixture pins in Python, Rust, Go and Julia
(`wildfire_fixture_no_longer_raises_unknown_faq_node` and friends) became
positive assertions: the fixture resolves, and the `join_factor` edge to
`factor:rg_src_bin` exists. Defect 1's entry was removed from all of them, which
is what its fix had to do.
