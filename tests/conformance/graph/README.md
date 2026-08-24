# Graph conformance corpus

`cases.json` is **generated**. Regenerate it with:

```bash
cd pkg/earthsci-ast-ts && npm run build && cd ../..
node scripts/generate-graph-corpus.mjs
```

Never hand-edit it. The generator's header comment is the normative account of
what is pinned and why; this file is the short version for someone porting a
binding.

## What it pins

For nine whole documents from `tests/valid/` and seven sub-document
`expression_graph` targets:

| Section | Pinned |
|---|---|
| `component_graph.nodes` | `id`, `type`, `var_count`, `eq_count`, `species_count` |
| `component_graph.edges` | `from`, `to`, `type`, `label` |
| `component_graph.closure` | `adjacency` / `predecessors` / `successors` per node |
| `component_graph_json` | the JSON adjacency-list export's top-level keys, node ids, edge endpoints and adjacency map |
| `expression_graph.nodes` | `name`, `kind`, `units`, `system` |
| `expression_graph.edges` | `source`, `target`, `relationship`, `equation_index` |
| `expression_graph.closure` | the same three lookups |
| `expression_graph_merge_coupled` | the whole-file graph with `variable_map` folded into cross-system edges |
| `targets[].expression_graph` | the Model / ReactionSystem / Equation / Reaction / Expr overloads |
| `*_dot_header` / `*_mermaid_header` | the FIRST LINE of each §4.8.3 text export |

**Node and edge ORDER is not a conformance property.** Bindings iterate their
own maps. Compare as multisets.

## Four decisions of record

These were open questions the corpus recorded rather than settled. All four are
now settled; each is listed with what changed, so a porter reading an older
binding knows which way it moved.

### 1. An indexed-LHS unknown is `observed`, not `algebraic`

`wildfire_atmosphere_ocean` defines `rg_pairs`, `rg_src_bin` and `rg_tgt_bin`
with an indexed LHS (`rg_src_bin[a] ~ …`). esm-spec §6.3.1 used to spell the
observed criterion "a bare-variable LHS", which was written for scalar equations
and contradicts the same table's semantic criterion in the arrayed case: an
indexed definition is plainly eliminable and materializable and constrains
nothing implicitly.

**The SPEC was the defect, and it changed.** §6.3.1 now states the split
semantically — observed when an equation DEFINES the unknown (its LHS naming it,
bare or indexed, read through the LHS base name), algebraic when it is only
CONSTRAINED by an expression LHS that names no single variable. Python, Rust and
Julia were already right; TypeScript and Go moved.

This is load-bearing beyond bookkeeping: `algebraic_unknowns` seeds the cadence
partition `CONTINUOUS` (CONFORMANCE_SPEC.md §5.7.2), whereas an observed
unknown's cadence resolves through its defining equation's RHS — so classing an
arrayed definition algebraic pushes build-time regridding work onto the
per-timestep hot path.

The three named expected-failures this had created are GONE, not inverted:
Python's strict `xfail`, Rust's masked `kind` comparison and Julia's
`@test_broken` (which also silently skipped that fixture's JSON-export and
`merge_coupled` assertions) are all deleted, and every binding now compares that
fixture strictly.

### 2. An aggregate's BOUND index variables are not graph nodes

A bound index (`a`, `o`, `v` in this corpus) is a binder introduced by the
aggregate's own `ranges` clause: no declaration, no units, no kind, scoped to
the aggregate. Julia was right; the other four emitted them because their
free-variable collector did not subtract range binders.

TypeScript, Python, Go and Rust now each have a **graph-private** binder-aware
collector that subtracts a node's own `ranges` keys, `output_idx` entries and
integral `var` — per node, at the binder, so a name bound inside one reduction
and free outside it is still reported. The subtraction is deliberately narrower
than each binding's validator-side bound-symbol helper, which also treats every
bare name in an `index(A, i, j)` position as bound: subtracting there rather
than at the binding node would hide a real reference to a declared variable used
as an index.

The shared `freeVariables` / `free_variables` / `collect_variables` are
UNCHANGED. They are public API and are what substitution, differentiation,
validation and unit conversion want, where "every name the subtree mentions" is
the right answer. TypeScript's second graph builder,
`analysis/dependency-graph.ts`, shares the new collector so the two graphs
cannot disagree about their node set.

### 3. DOT and Mermaid headers pinned to the majority

§4.8.3 requires both formats and specifies neither one's syntax, so the
cross-binding tie-break is the MAJORITY of the five bindings. On both headers
the majority runs against TypeScript, the corpus oracle, and TypeScript has been
moved rather than followed.

**DOT: `digraph ComponentGraph {` / `digraph ExpressionGraph {`.** Python, Go,
Rust and Julia all emitted the named form; TypeScript alone emitted a bare
`digraph {` (4-1).

**Mermaid: `graph TD`.** Majority applied to the keyword and the direction
independently, since they are independent choices:

| | keyword | direction |
|---|---|---|
| TypeScript | `flowchart` | `TD` |
| Python | `graph` | `TD` |
| Go | `graph` | `LR` |
| Rust | `graph` | `LR` (component) / `TD` (expression) |
| Julia | `graph` | `TD` |

`graph` beats `flowchart` 4-1; `TD` beats `LR` 3-2 on the component graph and
4-1 on the expression graph. Both resolve to `graph TD`.

Recorded for the future: `graph` is Mermaid's LEGACY spelling and `flowchart` is
its modern one. Both render. The majority rule points at `graph`, and that is
what the corpus carries; someone who wants `flowchart` is asking to overrule the
majority, not to fix a bug.

#### Why only the HEADER is pinned

Every node line in both formats carries a LABEL, and the majority of bindings
(TypeScript, Python, Julia — 3-2) run that label through an element-aware
**chemical-subscript formatter**: `O3` renders `O₃`, `jNO2` renders `jNO₂`. Go
and Rust have no such formatter — it is a ~1500-line element-table-plus-Greek-
transliteration module in each of the three bindings that do, with no
cross-language corpus of its own. Converging Go and Rust on the per-line format
is therefore a PORT OF THAT FEATURE, not an exporter edit, and it has not been
done here.

What the majority rule does settle, for whenever that port happens, is the rest
of the per-line format. Python and Julia are already byte-identical to each
other and are the only two bindings that agree on anything below the header, so
they are the plurality bloc; and on every element where three or more bindings
DO agree, they agree with that bloc:

| Element | Vote | Winner |
|---|---|---|
| node label text | subscripted name (TS, Py, Julia) vs counts-and-units (Go) vs raw name (Rust) | subscripted name, 3-2 |
| component DOT node attrs | `label` + `fillcolor` (Py, Julia, Go) | `label`, `fillcolor`, `style=filled` |
| … `style=filled` | Py, Julia, TS | present, 3-2 |
| … `shape` | TS, Rust only | absent, 3-2 |
| expression DOT node attrs | `label` + `shape` (TS, Rust, Py, Julia) | `label`, `shape`, 4-1 |
| expression DOT node shapes | parameter=`box`, observed=`diamond`, brownian=`doubleoctagon`, discrete=`hexagon` each 3-2 (Py, Julia, Rust); species=`ellipse` 3-2 (Py, Julia, TS) | the Python/Julia table |
| DOT edge attr order | `label` first (Py, Julia, Go, Rust) | `label` first, 4-1 |
| component DOT edge `color` | TS, Py, Julia | present, 3-2 |
| expression DOT edge label | the full relationship word (Py, Julia, Go) | `additive` / `multiplicative` / `rate` / `stoichiometric`, 3-2 |
| Mermaid indent | 4 spaces (Py, Go, Julia) | 4 spaces, 3-2 |
| Mermaid node id | sanitized, `[^A-Za-z0-9_] → _` (Py, Go, Julia) | sanitized, 3-2 |
| Mermaid `variable_map` arrow | `-.->` (TS, Py, Julia) | `-.->`, 3-2 |
| Mermaid `stoichiometric` arrow | `-..->` (TS, Py, Julia) | `-..->`, 3-2 |
| Mermaid trailing `classDef` block | Go only | absent, 4-1 |

Three elements have NO majority and fall to the Python/Julia bloc. Recorded here
rather than left implicit:

1. **Mermaid label quoting.** Always-quoted (Py, Julia) 2, never-quoted (TS, Go)
   2, conditionally-quoted (Rust) 1. → always-quoted.
2. **Mermaid `state` / `algebraic` / `species` node shapes.** For a state,
   `((…))` (Py, Julia) 2 vs `[…]` (TS, Go) 2 vs `(…)` (Rust) 1; species splits
   `(…)` (Py, Julia) 2 against `((…))` (TS, Rust) 2. → the Python/Julia table.
3. **The DOT document skeleton** — a `rankdir` + node-default preamble with
   blank lines between the node and edge blocks. Three bindings have one (TS,
   Go, Rust) and two do not (Py, Julia), but the three disagree with each other
   on its content (`rankdir=TB` vs `LR`; `node [fontname="Arial"]` vs
   `[shape=box, style=filled]` vs `[shape=box]`), so no FORM has a majority. →
   the flat Python/Julia list, no preamble.

### 4. The two thin pins

**A reaction system's `var_count` is `len(parameters)`**, not 0. The schema
FORBIDS a `variables` field on a `ReactionSystem` (`additionalProperties: false`
over `species` / `parameters` / `reactions` / …), and `species_count` already
carries the species, so `parameters` is the only thing left for §4.8.1's
"variable count" to mean — and it is the exact analogue of a model's
`variables`, which counts unknowns and parameters together. `0` asserted that a
reaction system declares no variables at all, which is false for every fixture
in the corpus. All five bindings had converged on the oracle's `0`; all five
moved.

**A bare-`Expr` target's `expr_result` edges carry `equation_index: -1`**, the
`NON_EQUATION_INDEX` sentinel, not `0`. A loose expression has no positional
equation to index, which is exactly what the sentinel is for; every binding's own
doc for the sentinel said so while its code wrote `0`. The Equation and Reaction
overloads still number their single target `0` — those ARE positional
statements, and the two remain distinguishable by `relationship` as well
(`additive` / `rate` vs `multiplicative`).

## What is still NOT pinned, and why

**The DOT and Mermaid bytes below the header.** See §3 above.

**`ComponentNode.description` / `.reference`.** TypeScript derives `description`
from `reference.notes`; Python and Julia leave both null; Rust carries an
unrelated `name`. §4.8.1 asks for "summary metadata" and names neither field.

**`DependencyEdge.expression`.** §4.8.2 marks it optional, "for detail views",
and the bindings differ on whether a stoichiometric edge carries the rate
expression that produced it.

## Oracle

TypeScript (`pkg/earthsci-ast-ts`), on the grounds set out at the top of
`scripts/generate-graph-corpus.mjs`: the spec decides the substantive splits and
TypeScript is on its side of each; where the spec is silent, TypeScript and
Python — the two bindings carrying the 1.0.0 model — agree.

The oracle is not a majority: on the four decisions above TypeScript was moved
onto the majority or onto the amended spec in every case, and the corpus was
regenerated afterwards. Being the oracle means the corpus is generated from it,
not that it wins arguments.

## Drivers

| Binding | Test |
|---|---|
| TypeScript | `pkg/earthsci-ast-ts/src/graph-conformance.test.ts` |
| Python | `pkg/earthsci-ast-py/tests/test_graph_conformance.py` |
| Go | `pkg/earthsci-ast-go/pkg/esm/graph_conformance_test.go` |
| Rust | `pkg/earthsci-ast-rs/tests/graph_conformance.rs` |
| Julia | `pkg/EarthSciAST.jl/test/graph_conformance_test.jl` |

None of them carries a skip, xfail, mask or `@test_broken` any more.
