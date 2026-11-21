---
title: "solver"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Solver` | not exported | `Solver` | `Solver` | `Solver` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Solver
Solver(; stiffness, abstol, reltol, splitting, external, time_span)
```

```julia
Solver(; stiffness=nothing, abstol=nothing, reltol=nothing, splitting=nothing,
       external=nothing, time_span=nothing)
```

Document-scoped, OPTIONAL solver hints (esm-spec §2.2) — numerics the document
knows about *itself*, which each binding maps to its own integrator — plus
`external`, a reference to a run-configuration document, and `time_span`, the
interval the document asks to be simulated over (both esm 1.3.0). The
authored `external` string is what the type holds and what `emit` writes; where
it points comes from [`solver_external_location`](/generated/api/ref/solver_external_location) (§2.2.6). Likewise
`time_span` holds the authored bounds, and [`resolve_time_span`](/generated/api/ref/resolve_time_span) converts
them to seconds (§2.2.7).

Every field is ADVISORY: a binding may ignore any or all of them and still
conform. Advisory governs the MECHANISM, never the OUTCOME — a binding that
ignores every field and still converges conforms; the CONFORMANCE_SPEC §5.9
requirement to integrate successfully and agree within the error band is
untouched by this block and is not excused by it.

`abstol` / `reltol` are INTEGRATION tolerances and are a DIFFERENT QUANTITY
from `Tolerance`, which is what an assertion is COMPARED at (§6.6.4).
They resolve on independent chains and neither substitutes for the other.

Every field is `Union{...,Nothing}` because each is independently optional and
absence is NOT a default value: a document omitting `stiffness` has not
declared its stiffness, and a binding must not read absence as an assertion
about the system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L1392)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Solver
Solver(stiffness: str | None = None, abstol: float | None = None, reltol: float | None = None, splitting: str | None = None, external: str | None = None, time_span: SolverTimeSpan | None = None)
```

Document-scoped, OPTIONAL solver hints (esm-spec §2.2).

Numerics the document knows about *itself*, which each binding maps to its
own integrator. Every field is ADVISORY: a binding may ignore any or all of
them and still conform.

Advisory governs the MECHANISM, never the OUTCOME. A binding that ignores
every field and still converges conforms; the CONFORMANCE_SPEC §5.9
requirement to integrate successfully and agree within the error band is
untouched by this block and is not excused by it.

`abstol` / `reltol` are INTEGRATION tolerances and are a different
quantity from `Tolerance`, which is what an assertion is COMPARED at
(esm-spec §6.6.4). They resolve on independent chains; neither substitutes
for the other.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L662)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Solver {
    pub stiffness: Option<String>,
    pub abstol: Option<f64>,
    pub reltol: Option<f64>,
    pub splitting: Option<String>,
    pub external: Option<String>,
    pub time_span: Option<SolverTimeSpan>,
}
```

Document-scoped, OPTIONAL solver hints (esm-spec §2.2).

Numerics the document knows about ITSELF, which each binding maps to its own
integrator. Every field is ADVISORY: a binding may ignore any or all of them
and still conform. Advisory governs the MECHANISM, never the OUTCOME — a
binding that ignores every field and still converges conforms; the
CONFORMANCE_SPEC §5.9 requirement to integrate successfully and agree within
the error band is untouched by this block and is not excused by it.

`abstol` / `reltol` are INTEGRATION tolerances and are a different quantity
from [`Tolerance`](/generated/api/ref/tolerance), which is what an assertion is COMPARED at (§6.6.4). They
resolve on independent chains and neither substitutes for the other.

Every field is `Option` because each is independently optional and absence
is NOT a default value: a document omitting `stiffness` has not declared its
stiffness, and a binding must not read absence as an assertion about it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/model.rs#L194) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Solver.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Solver struct {
	// Stiffness is the author's declaration of the system's stiffness:
	// "low", "moderate" or "high". A binding MAY select an implicit /
	// BDF-family integrator on "high".
	Stiffness *string `json:"stiffness,omitempty"`
	// Abstol is the absolute INTEGRATION tolerance the document asks for.
	Abstol *float64 `json:"abstol,omitempty"`
	// Reltol is the relative INTEGRATION tolerance the document asks for.
	Reltol *float64 `json:"reltol,omitempty"`
	// Splitting is an advisory operator-splitting convention: "none", "lie"
	// or "strang". It carries no prescribed substep structure.
	Splitting *string `json:"splitting,omitempty"`
	// External names a run-configuration document for this document
	// (esm-spec §2.2.6). It is held exactly as authored and emitted verbatim;
	// the resolved location comes from SolverExternalLocation and is never
	// written back. EarthSciAST never opens the referenced document.
	External *string `json:"external,omitempty"`
	// TimeSpan is the interval the document is meant to be simulated over
	// (esm-spec §2.2.7). Each bound is held exactly as authored -- a number
	// or an RFC 3339 UTC timestamp -- and emitted verbatim; its value in
	// seconds comes from ResolveTimeSpan and is never written back.
	TimeSpan *SolverTimeSpan `json:"time_span,omitempty"`
}
```

Solver carries numerics the document knows about ITSELF — stiffness, integration tolerances, and a splitting hint — which each binding maps to its own integrator (esm-spec §2.2).

Every field is ADVISORY: a binding may ignore any or all of them and still conform. Advisory governs the MECHANISM, never the OUTCOME — a binding that ignores every field and still converges conforms; the CONFORMANCE\_SPEC §5.9 requirement to integrate successfully and agree within the error band is untouched by this block and is not excused by it.

Abstol/Reltol are INTEGRATION tolerances and are a different quantity from Tolerance, which is what an assertion is COMPARED at (esm-spec §6.6.4). They resolve on independent chains and neither substitutes for the other.

Every field is a pointer with `omitempty` because each is independently optional and absence is NOT a default value: a document that omits `stiffness` has not declared its stiffness, and a binding must not read the zero value as an assertion about the system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/solver.go#L33) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Solver)

</div>

</div>
