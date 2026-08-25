# Known defects in the shared corpus

Fixtures under `tests/valid/` are the cross-binding definition of "a valid
document": every binding drives its conformance suite from them. Three of the 93
do **not** survive reference resolution. Found during phase 6, while adding
`build_reference_graph` to TypeScript and checking it against Python — the two
bindings agree exactly on all three, which is why this had gone unnoticed: no
binding was running the resolver over the whole valid corpus.

Reproduce (93 fixtures, 90 resolve, 3 raise):

```bash
PYTHONPATH=pkg/earthsci-ast-py/src python3 - <<'PY'
import json, glob, earthsci_ast as e
for f in sorted(glob.glob("tests/valid/**/*.esm", recursive=True)):
    try: e.resolve_references(json.load(open(f)))
    except Exception as ex: print(f, type(ex).__name__, ex)
PY
```

#2 has since been RULED and fixed in all five bindings; #1 and #3 remain open.
The count did not drop, because fixing #2 exposed a second instance of #3 on the
same fixture — see #3 below.

## 1. `aggregate/skolem_distinct_rank.esm` — a FIXTURE defect

`E_REF_UNKNOWN_FAQ_NODE`: `index_sets.edges.from_faq` names `"edge_set"`, and
the document contains **no `id` field at all** — a walk over every node finds
zero. The name `edge_set` occurs exactly twice in the file: in the `from_faq`
itself, and inside an `_comment` describing the node it *would* refer to.

The producer node was described and never written. The resolvers are right to
reject it. Fixing this means authoring the missing index-set-producing
`aggregate` per RFC semiring-faq-unified-ir §5.5/§5.7, which is fixture work
needing the RFC author's intent, not a mechanical repair.

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

## 3. `geometry/conservative_regrid_assembly.esm` — undiagnosed

`E_REF_UNRESOLVED_JOIN_FACTOR`: join factor `'src_bin'` of node
`node:candidate_set` (`/models/ConservativeRegridAssembly/equations/2/rhs`)
"names no factor, range, or output index in scope". Six equations in the model
carry the same `join: [{"on": [["src_bin", "tgt_bin"]]}]`.

Not established whether the fixture omits a binder or the resolver fails to see
one that bin-skolem machinery introduces. Left open deliberately rather than
guessed at.

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

So the corpus sweep count did **not** drop from 3 to 2: it is 3 of 93 (the 93rd
fixture is the new `cross_model_from_faq.esm`, which resolves). Repairing #3
repairs both fixtures at once. Every binding pins `wildfire_atmosphere_ocean.esm`
under the join code, so the change of failure mode is visible rather than
silent.

---

TypeScript and Go each pin all three by name — with their codes — in their
reference-graph corpus sweeps, so a repair surfaces as a test failure rather
than silently changing the corpus. Python, Rust and Julia pin
`wildfire_atmosphere_ocean.esm` individually for the same reason.
