# Known defects in the shared corpus

Fixtures under `tests/valid/` are the cross-binding definition of "a valid
document": every binding drives its conformance suite from them. Three of them
did **not** survive reference resolution when this file was opened in phase 6,
found while adding `build_reference_graph` to TypeScript and checking it against
Python — the two bindings agreed exactly on all three, which is why it had gone
unnoticed: no binding was running the resolver over the whole valid corpus.

Defect 1 is **fixed** (phase 6b) and its recorded diagnosis turned out to be
wrong. Defect 2 is **ruled and implemented** in all five bindings (phase 6b).
Defect 3 is **diagnosed** (phase 6b) and, unlike the other two, is a bug in the
five bindings rather than in the corpus — and it has TWO instances, the second
of which defect 2 was hiding.

Reproduce (measured on the merged phase-6b tree: **93 fixtures, 91 resolve,
2 raise** — both remaining are defect 3, with the same error code):

```bash
PYTHONPATH=pkg/earthsci-ast-py/src python3 - <<'PY'
import json, glob, earthsci_ast as e
for f in sorted(glob.glob("tests/valid/**/*.esm", recursive=True)):
    try: e.resolve_references(json.load(open(f)))
    except Exception as ex: print(f, type(ex).__name__, ex)
PY
```

Each section below carries its own status; read it before assuming the fixture
is at fault, because for two of the three it was not. Note that the failure
count did not fall by two: fixing defect 2 unmasked a second instance of
defect 3 on the same fixture — see #3.

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

**This defect is closed.** The `wildfire_atmosphere_ocean.esm` fixture still
does not resolve — but for defect #3's reason, not this one; see below.

## 3. `geometry/conservative_regrid_assembly.esm` — a RESOLVER defect (diagnosed, NOT fixed)

`E_REF_UNRESOLVED_JOIN_FACTOR`: join factor `'src_bin'` of node
`node:candidate_set` (`/models/ConservativeRegridAssembly/equations/2/rhs`)
"names no factor, range, or output index in scope". Six equations in the model
carry the same `join: [{"on": [["src_bin", "tgt_bin"]]}]`.

The open question was whether the fixture omits a binder or the resolver fails
to see one. **It is the resolver, in all five bindings.** The fixture is not
repaired here, because repairing it means changing
`reference_resolution.*` / `reference_graph.*` in every binding — see "Why this
is not fixed here" below.

### The evidence

**1. The normative text names three binder classes; the resolvers implement
one.** `esm-spec.md` §4.9.5 says an `on` key column is **polymorphic** — a loop
symbol bound by the enclosing `ranges`, a document-scoped index set (§9.7.5), or
a declared component-local variable — and that a binding diagnosing such a name
"must do so against the variable **and** index-set registries". CONFORMANCE_SPEC
§5.5.6 says the same and adds the ordering: a name the node BINDS is tested
first, then a declared local variable, then anything else is left alone. It
names the third class explicitly, as a "value-invention bin buffer".

Every binding's `factor_scope` helper consults exactly three **node-local**
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

**3. The scope set is self-inconsistent on fixtures everyone already accepts.**
`tests/valid/aggregate/join_filter.esm` and
`.../join_moves_running_exhaust.esm` join on `["src", "sourceType"]` — and
`sourceType` is a document-scoped index set, in no `args`, no `ranges` key and
no `output_idx`. They pass only because no binding validates `pair[1]` at all;
the resolvers check the left column and ignore the right. Apply the existing
scope test to the right column and an accepted, canonical fixture starts
failing. So the implemented rule cannot be the intended rule even on the corpus
it currently passes.

**4. Nothing requires a join key column to appear in the node's `args`.** Not
`esm-schema.json` (`on` items are just `[left, right]` strings), not RFC
semiring-faq-unified-ir §5.3, not the spec. The three fixtures that resolve
today do so because whoever authored them happened to list the columns in
`args`. That is a coincidence of authorship, not a binder.
`E_REF_UNRESOLVED_JOIN_FACTOR` itself appears in no spec, no schema and no RFC —
only in the five bindings and their tests.

### What the fix is

In each binding's join handling, scope assembly must be layered, in this order
(the order is normative per CONFORMANCE_SPEC §5.5.6, because a node-local binder
SHADOWS a same-named variable):

1. node-local binders — `ranges` keys and symbolic `output_idx` entries;
2. node-local string `args`;
3. **the model's variable registry** — where a bin buffer or envelope factor
   lives. This is the omitted step that produces the failure;
4. **the document-scoped index-set registry** — already threaded in for
   `ranges[*].from`. Its absence is currently hidden by (5);
5. only then `E_REF_UNRESOLVED_JOIN_FACTOR`.

And the check must then be applied to `pair[1]` as well — today it cannot be,
which is itself a symptom. Julia additionally validates `overlap`'s
`src_env` / `tgt_env` against the same incomplete scope and will misfire the
same way.

### ⚠ A second instance, and what defect 2 did to it

This defect has TWO instances. See the detail below — defect 2 landed
first, and unmasked the second rather than repairing it.

### Why this is not fixed here

The repair is a five-binding change to `reference_resolution.*` /
`reference_graph.*`, the same modules being rewritten for defect 2's
document-scope ruling. Landing two independent rewrites of one module in
parallel is how the drift this file records got made. The diagnosis is the
deliverable; the implementation belongs with defect 2's.

### The fixture-side workaround, and why it is not the answer

A mechanical repair exists: add `"args": ["src_bin", "tgt_bin"]` to each of the
six aggregates here and the five in wildfire's `OceanDynamics`, matching how
`bin_skolem_spatial_join.esm` and `conservative_regrid_overlap_join.esm` were
authored. It is semantically harmless. But adopting it as *the* fix would ratify
a rule the spec does not state, would leave `join_filter.esm`'s index-set column
unresolvable the moment `pair[1]` is checked, and would leave §4.9.5's "must
diagnose against the variable and index-set registries" unimplemented in all
five bindings. If it is taken for scheduling reasons it should be recorded as a
workaround, not as the diagnosis.

**Second instance, exposed by the defect-#2 fix:**
`wildfire_atmosphere_ocean.esm` has the same shape. Its producing node
`rg_candidate_set` (`/models/OceanDynamics/equations/2/rhs`) carries
`join: [{"on": [["rg_src_bin", "rg_tgt_bin"]]}]`, and `rg_src_bin` /
`rg_tgt_bin` are model **variables** — defined at equations 0 and 1 with an
indexed LHS — not that node's args, range keys, or `output_idx`. Defect #2 had
been masking this: `index_sets` is document-scoped, so the `from_faq` lookup ran
for EVERY model's graph and failed on whichever model each binding built first
(`AtmosphericDynamics` in document order, `AirSeaFluxCalculator` in Go's sorted
order) — always before `OceanDynamics`, so the join error never fired. With #2
fixed the fixture now raises `E_REF_UNRESOLVED_JOIN_FACTOR` for `'rg_src_bin'`
instead.

So repairing #3 repairs both fixtures at once, and the sweep did not fall by
two when defect 2 landed — one of the two fixtures defect 2 fixed simply began
failing here instead. **Measured on the merged tree: 93 fixtures, 91 resolve, 2
raise**, both with `E_REF_UNRESOLVED_JOIN_FACTOR`. (Two counts recorded during
phase 6b read 3 of 93; each was measured on a branch holding only one of the two
fixes, and neither is the merged number.) Every binding pins `wildfire_atmosphere_ocean.esm`
under the join code, so the change of failure mode is visible rather than
silent.

---

TypeScript (`src/reference-resolution.test.ts`) and Go
(`pkg/esm/reference_graph_test.go`) pin the remaining rejections by name, with
their codes, so a repair surfaces as a test failure rather than silently
changing the corpus. Python, Rust and Julia pin `wildfire_atmosphere_ocean.esm`
individually for the same reason. Defect 1's entry was removed from all of them,
which is what its fix had to do.
