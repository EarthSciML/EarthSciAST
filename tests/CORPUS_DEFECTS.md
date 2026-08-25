# Known defects in the shared corpus

Fixtures under `tests/valid/` are the cross-binding definition of "a valid
document": every binding drives its conformance suite from them. Three of the 92
do **not** survive reference resolution. Found during phase 6, while adding
`build_reference_graph` to TypeScript and checking it against Python — the two
bindings agree exactly on all three, which is why this had gone unnoticed: no
binding was running the resolver over the whole valid corpus.

Reproduce (92 fixtures, 89 resolve, 3 raise):

```bash
PYTHONPATH=pkg/earthsci-ast-py/src python3 - <<'PY'
import json, glob, earthsci_ast as e
for f in sorted(glob.glob("tests/valid/**/*.esm", recursive=True)):
    try: e.resolve_references(json.load(open(f)))
    except Exception as ex: print(f, type(ex).__name__, ex)
PY
```

These are recorded, not fixed. Two need a ruling that is not phase 6's to make.

## 1. `aggregate/skolem_distinct_rank.esm` — a FIXTURE defect

`E_REF_UNKNOWN_FAQ_NODE`: `index_sets.edges.from_faq` names `"edge_set"`, and
the document contains **no `id` field at all** — a walk over every node finds
zero. The name `edge_set` occurs exactly twice in the file: in the `from_faq`
itself, and inside an `_comment` describing the node it *would* refer to.

The producer node was described and never written. The resolvers are right to
reject it. Fixing this means authoring the missing index-set-producing
`aggregate` per RFC semiring-faq-unified-ir §5.5/§5.7, which is fixture work
needing the RFC author's intent, not a mechanical repair.

## 2. `wildfire_atmosphere_ocean.esm` — a RESOLVER/SPEC defect

`E_REF_UNKNOWN_FAQ_NODE`: `index_sets.rg_candidate_pairs.from_faq` names
`"rg_candidate_set"`, and **that node exists** — at
`/models/OceanDynamics/equations/2/rhs`. The error says it "is not the id of any
expression node in model `'AtmosphericDynamics'`".

That is the bug. `index_sets` is **document-scoped** (`esm-schema.json` declares
it only at `/properties/index_sets` — the same scoping fact behind API_SPEC §8
item 17), but `from_faq` is resolved within **one model's** scope. A
document-scoped derived index set whose producer lives in a different model is
therefore unresolvable, and this fixture is exactly that shape: the atmosphere
model consuming a candidate-pair set produced by the ocean model.

**RULED (phase 6): `from_faq` is document-scoped.** `esm-spec.md` §9.7.5 now
states it normatively, and `esm-schema.json`'s `id` description widens node-id
uniqueness from per-model to per-document to match — a document-scoped registry
whose entries could only name one model's nodes is incoherent, and per-model
uniqueness would leave a cross-model reference ambiguous. Verified before
ruling: **no fixture in `tests/` reuses an `id` across models**, so the widened
uniqueness requirement invalidates nothing that exists. All five bindings resolve
`from_faq` per-model today and all five need the change; once they have it, this
fixture is valid and stops being a defect.

## 3. `geometry/conservative_regrid_assembly.esm` — undiagnosed

`E_REF_UNRESOLVED_JOIN_FACTOR`: join factor `'src_bin'` of node
`node:candidate_set` (`/models/ConservativeRegridAssembly/equations/2/rhs`)
"names no factor, range, or output index in scope". Six equations in the model
carry the same `join: [{"on": [["src_bin", "tgt_bin"]]}]`.

Not established whether the fixture omits a binder or the resolver fails to see
one that bin-skolem machinery introduces. Left open deliberately rather than
guessed at.

---

TypeScript pins all three by name in its reference-graph tests, so a repair
surfaces as a test failure rather than silently changing the corpus.
