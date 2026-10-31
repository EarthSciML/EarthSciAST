---
title: "unit_finding_unparseable"
description: "Stable constant · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** constant · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `UNIT_FINDING_UNPARSEABLE` | `UNIT_FINDING_UNPARSEABLE` | `UnitFindingUnparseable` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this constant.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this constant.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
UNIT_FINDING_UNPARSEABLE = 'unparseable_unit'
```

A declared unit string that denotes no real unit. Meaningless declaration,
so a defect in the FILE, not in the checker.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/units.py#L1109)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub const UNIT_FINDING_UNPARSEABLE: &str = crate::diagnostic::codes::UNPARSEABLE_UNIT;
```

See [`UNIT_FINDING_DIMENSIONAL_MISMATCH`](/generated/api/ref/unit_finding_dimensional_mismatch).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/units.rs#L486) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/constant.UNIT_FINDING_UNPARSEABLE.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
const UnitFindingUnparseable = "unparseable_unit"
```

Unit-finding codes. A unit finding is either a DEFECT IN THE FILE — which invalidates the document — or a limit of the ANALYSIS, which does not. The classification is decided at the point the finding is raised (never recovered later from the prose) and carried on UnitWarning.Code; ValidateStructuralWithCodes promotes the defect-bearing codes to `unit_inconsistency` structural errors.

The split is the cross-binding policy and mirrors TypeScript's units.ts:

- UnitFindingDimensionalMismatch — a PROVABLE inconsistency: adding metres to kilograms, log() of a dimensional quantity, an equation whose sides have different dimensions. The file is wrong. → HARD ERROR.
- UnitFindingUnparseable — a declared unit string that does not denote a real unit ("not\_a\_unit"). The file is wrong. → HARD ERROR.
- UnitFindingAnalysis — the checker cannot DETERMINE a dimension: a symbolic (non-literal) exponent, an operator with no dimensional rule (fn/table\_lookup), a malformed arity. That is a statement about the checker, not a defect in the file. → WARNING.
- UnitFindingDimensionlessLiteral — the esm-spec §4.8.6 warning stage: a site that fails only when nonzero bare literals are dimensionless. Never promoted. → WARNING.

An unknown VARIABLE is likewise never a mismatch (it propagates as "unknown" and suppresses the check); it is separately a hard `undefined_variable` error, so the units layer does not double-report it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/units.go#L1599) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UnitFindingUnparseable)

</div>

</div>
