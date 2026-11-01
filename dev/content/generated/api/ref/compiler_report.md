---
title: "compiler_report"
description: "Stable type · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `CompilerReport` | outside profile | `CompilerReport` | `CompilerReport` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct CompilerReport
CompilerReport(compiler::Symbol, rules::Vector{CompilerRuleRecord}, tally::Dict{Symbol, Int64})
CompilerReport(compiler, rules, tally)
CompilerReport(compiler::Symbol)
```

```julia
CompilerReport
```

What a build did, per rule. [`compiler_report`](/generated/api/extension/julia#x-compiler_report) returns one.

* `compiler` — the vocabulary value that built this problem.
* `rules` — a [`CompilerRuleRecord`](/generated/api/extension/julia#x-compilerrulerecord) per equation / observed / setup
  array, in build order.
* `tally` — this build's cascade counters (the per-build twin of the
  process-global `_CASCADE_TALLY`), for the counts a per-rule row does not
  carry: emitted kernels, class merges, subtree-table rescues.

`tier_histogram(report)` folds `rules` into tier → count, which is what
`show(::EsmProblem)` prints.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/compiler.jl#L279)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class CompilerReport
CompilerReport()
CompilerReport.add(entry: RuleTier) -> None
CompilerReport.entries: tuple[RuleTier, ...]  # property
CompilerReport.rules() -> tuple[str, ...]
CompilerReport.for_rule(rule: str) -> tuple[RuleTier, ...]
CompilerReport.tiers() -> dict[str, int]
CompilerReport.per_cell_rules() -> tuple[str, ...]
CompilerReport.__iter__() -> Iterator[RuleTier]
CompilerReport.__len__() -> int
```

Per rule, the tier it landed on and what declined on the way.

One entry per aggregate LANDING, not per rule: a rule whose body holds two
aggregates, or whose aggregate is re-evaluated in a second phase, produces
an entry each, which is what makes the record a cost story rather than a
summary. A rule with no aggregate at all produces no entry — the whole
ladder this records is the `faq` ladder — so `rules` is the rules
that had a tier to land on.

**Members**

- `add` — Record a landing, ONCE per distinct (rule, phase, tier, chain).
- `rules` — Every rule that landed somewhere, in first-landing order.
- `tiers` — Landing counts by tier — the one-line cost summary.
- `per_cell_rules` — The rules that walked per cell. Empty under a build that survived `native`, by construction.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/compiler.py#L213)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct CompilerReport {
    /* private fields */
}

impl CompilerReport { pub fn compiler(&self) -> Compiler }

impl CompilerReport { pub fn rules(&self) -> &[CompilerRuleReport] }

impl CompilerReport { pub fn n_taped(&self) -> usize }

impl CompilerReport { pub fn n_xla(&self) -> usize }

impl CompilerReport { pub fn n_oracle(&self) -> usize }

impl CompilerReport { pub fn n_vectorized(&self) -> usize }

impl CompilerReport { pub fn fused_groups(&self) -> usize }

impl CompilerReport { pub fn fused_instructions(&self) -> usize }
```

What built a Problem's right-hand side, per rule (API_SPEC §5.8).

The names and their meanings are stable surface; the record's exact shape
is per-binding and is deliberately not pinned across the five.

**Fusion is reported per PROGRAM, not per rule.** The tape's Step-4 fusion
pass merges instructions across rule boundaries and the fused program keeps
no rule attribution, so a `tier` of `"taped"` covers both a rule that runs
as discrete instructions and one absorbed into a fused group;
`Self::fused_groups` and `Self::fused_instructions` report the fusion
at the level the tape actually tracks it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/problem.rs#L425) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.CompilerReport.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
