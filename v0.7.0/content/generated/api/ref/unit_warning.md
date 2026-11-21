---
title: "unit_warning"
description: "Stable type · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `UnitWarning` | `UnitWarning` | `UnitWarning` | `UnitWarning` | `UnitWarning` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct UnitWarning
UnitWarning(path::AbstractString, code::AbstractString, message::AbstractString)
UnitWarning(path::AbstractString, code::AbstractString, message::AbstractString, lhs_units::AbstractString)
UnitWarning(path::AbstractString, code::AbstractString, message::AbstractString, lhs_units::AbstractString, rhs_units::AbstractString)
```

```julia
UnitWarning
```

A single dimensional-analysis finding, in the STRUCTURED form the Python,
TypeScript and Go bindings have always used and Julia did not: this field was
a bare `Vector{String}`, so a caller could read the prose but could not filter
or route findings by `code` without regex-ing the message — exactly the
prose-parsing every binding's units documentation warns against.

Fields and their JSON spellings match Go's `UnitWarning`
(`pkg/earthsci-ast-go/pkg/esm/validate.go`) and the shape pinned by
`CONFORMANCE_SPEC.md` §3.1:

* `path` — RFC-6901 JSON Pointer to the offending equation / expression, the
  document root being `""` (the same addressing as `StructuralError.path`).
* `code` — the finding kind, decided AT THE POINT the finding was raised and
  never recovered from the prose, so rewording a message can never silently
  reclassify it. This is the SECOND, smaller unit vocabulary — the one Go's
  `UnitFinding*`, Rust's `UNIT_FINDING_*` and TypeScript's
  `UnitWarning['code']` union share: `dimensional_mismatch` (a PROVABLE
  inconsistency), `unparseable_unit` (a declared unit string denoting no real
  unit), `analysis` (the checker could not DETERMINE a dimension), and the
  warning `units_dimensionless_literal_mismatch`
  ([`UNIT_FINDING_DIMENSIONLESS_LITERAL`](/generated/api/ref/unit_finding_dimensionless_literal), esm-spec §4.8.6). It is NOT
  the `unit_inconsistency` / `unit_parse_error` pair, which names the
  STRUCTURAL error each finding is promoted to.
* `message` — human-readable description (binding-local prose).
* `lhs_units` / `rhs_units` — the inferred units of each side, `""` when the
  raise site does not know them. Julia's units engine (`model_unit_findings`)
  currently reports findings as prose and carries no separate unit pair, so
  these are `""` today; `validate` reads them from the promoted
  `StructuralError`'s `details` under those keys, so a raise site that starts
  supplying them is picked up with no further change here.

Despite the name — kept for wire compatibility, it is the `unit_warnings`
field of the spec's `ValidationResult` — a `UnitWarning` is not necessarily
advisory: the codes that state a defect in the FILE are promoted to hard
`unit_inconsistency` structural errors, and those are what invalidate the
document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/validate.jl#L52)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface UnitWarning {
    message: string;
    code: 'dimensional_mismatch' | 'unparseable_unit' | 'analysis' | 'units_dimensionless_literal_mismatch';
    location?: string;
    equation?: string;
    variable?: string;
    units?: string;
}
```

Dimensional-consistency warning emitted during file-level validation.

**Properties**

- `code` — Structured finding kind, and the whole of the severity policy.
  
  A unit finding is either a DEFECT IN THE FILE — which invalidates the
  document — or a limit of the ANALYSIS, which does not. The classification is
  decided AT THE POINT the finding is raised (never recovered later from the
  prose, so rewording a message can never silently change its severity), and
  `validate()` promotes exactly the defect-bearing codes to
  `unit_inconsistency` structural errors.
  
  - `dimensional_mismatch` — a PROVABLE inconsistency: metres added to
    kilograms, `log()` of a dimensional quantity, an equation whose sides
    cannot agree. The file is wrong. → HARD ERROR.
  - `unparseable_unit` — a declared unit string that does not denote a real
    unit (`"not_a_unit"`). A unit that names nothing is not an ambiguity to be
    worked around; the declaration is meaningless, and that is a defect in the
    FILE, not in the checker. → HARD ERROR. (Which is why the registry in
    `unit-conversion.ts` must not be missing real units — under this policy a
    registry gap is a false rejection.)
  - `analysis` — the checker cannot DETERMINE a dimension: a symbolic
    exponent (`x^n`, whose dimension depends on `n`'s runtime value), an
    operator with no dimensional rule (`fn`, `table_lookup`), a malformed
    arity, an unknown variable. Genuinely undeterminable — a statement
    about the checker, not the file. → WARNING, and the dimension is
    reported UNKNOWN and the check SKIPPED, never assumed dimensionless.
  
  - `units_dimensionless_literal_mismatch` — a check site that the current
    neutral-literal rule passes or skips fails once a nonzero bare numeric
    literal is read as dimensionless at scale 1 (esm-spec §4.8.6). Emitted by
    `dimensionlessLiteralWarnings`, never by `validateUnits`. →
    WARNING at this stage; it becomes an error at the next major esm version.
  
  An unknown VARIABLE is an `analysis` finding here and nothing more: it is
  separately a hard `undefined_variable` error, so the units layer does not
  double-report it.
- `variable` — For `unparseable_unit`: the declaration at fault. `validate()` promotes the
   finding to a `unit_parse_error` structural error and reports these verbatim
   as its `details`, which the shared corpus pins.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/units.ts#L83)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class UnitWarning
UnitWarning(path: str, message: str, code: str = UNIT_FINDING_ANALYSIS, lhs_units: str = '', rhs_units: str = '', details: dict[str, Any] = None)
```

A single dimensional-analysis finding.

Field names and their JSON spellings are a CROSS-BINDING CONTRACT, matching
Go's `UnitWarning` (`pkg/earthsci-ast-go/pkg/esm/validate.go`), Julia's,
Rust's and TypeScript's, and the shape pinned by CONFORMANCE_SPEC.md §3.1:

* `path` — RFC-6901 JSON Pointer to the offending equation / expression,
  the document root being `""` (the same addressing as
  [`ValidationError`](/generated/api/ref/validation_error)). `""` when the raise site has no pointer.
* `code` — the finding kind, decided AT THE POINT the finding was raised
  and never recovered from the prose, so rewording a message can never
  silently reclassify it. One of
  [`UNIT_FINDING_DIMENSIONAL_MISMATCH`](/generated/api/ref/unit_finding_dimensional_mismatch),
  [`UNIT_FINDING_UNPARSEABLE`](/generated/api/ref/unit_finding_unparseable),
  [`UNIT_FINDING_ANALYSIS`](/generated/api/ref/unit_finding_analysis), or the warning
  [`UNIT_FINDING_DIMENSIONLESS_LITERAL`](/generated/api/ref/unit_finding_dimensionless_literal)
  (esm-spec §4.8.6). This is the SECOND,
  smaller unit vocabulary — NOT the `unit_inconsistency` /
  `unit_parse_error` pair, which names the STRUCTURAL error a finding is
  promoted to.
* `message` — human-readable description (binding-local prose).
* `lhs_units` / `rhs_units` — the inferred units of each side, `""`
  when the raise site does not know them (the norm for an `analysis`
  finding — not determining a dimension is what makes it one).

`details` is a Python-only extra carrying local diagnostic context; it is
not part of the cross-binding contract and no other binding has it.

Despite the name — kept for wire compatibility, it is the `unit_warnings`
field of the spec's [`ValidationResult`](/generated/api/ref/validation_result) — a `UnitWarning` is not
necessarily advisory: the codes that state a defect in the FILE are what the
structural checks report as hard `unit_inconsistency` /
`unit_parse_error` errors, and those are what invalidate the document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/validation.py#L65)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct UnitWarning {
    pub path: String,
    pub code: String,
    pub message: String,
    pub lhs_units: String,
    pub rhs_units: String,
}
```

A dimensional-analysis finding surfaced by validation.

Despite the name — kept for wire compatibility, it is the `unit_warnings`
field of the spec's `ValidationResult` (CONFORMANCE_SPEC §3.1) — a
`UnitWarning` is not necessarily advisory. `code` says whether
the finding states a defect in the FILE or a limit of the ANALYSIS:

* `dimensional_mismatch` — a PROVABLE inconsistency (metres plus kilograms,
  an equation whose sides cannot agree).
* `unparseable_unit` — a declared unit string that denotes no real unit.
* `analysis` — the checker could not DETERMINE a dimension (an unknown
  variable, a symbolic exponent, an op with no dimensional rule). This
  reports what the checker could not conclude, not a defect in the file.

The classification is decided AT THE POINT the finding is raised (never
recovered later from the prose, so rewording a message can never silently
change its severity) — see [`crate::units::UnitSeverity`](/generated/api/extension/rust#x-unitseverity). In this binding
the defect-bearing kinds are promoted at that same decision point:
`dimensional_mismatch` becomes a `unit_inconsistency`
[`StructuralError`](/generated/api/ref/structural_error) and `unparseable_unit` a `unit_parse_error` one, so what
remains here is the non-blocking `analysis` residue. Mirrors Go's
`UnitWarning` (`pkg/earthsci-ast-go/pkg/esm/validate.go`) field for field, so
the two serialize identically.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/validate.rs#L75) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.UnitWarning.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type UnitWarning struct {
	Path     string `json:"path"`      // RFC 6901 JSON Pointer to the equation/expression (see StructuralError.Path)
	Code     string `json:"code"`      // UnitFindingDimensionalMismatch | UnitFindingUnparseable | UnitFindingAnalysis | UnitFindingDimensionlessLiteral
	Message  string `json:"message"`   // Human-readable description
	LHSUnits string `json:"lhs_units"` // Inferred units of the LHS
	RHSUnits string `json:"rhs_units"` // Inferred units of the RHS
}
```

UnitWarning represents a finding from dimensional analysis.

Despite the name (kept for wire compatibility — it is the `unit_warnings` field of the spec's ValidationResult), a UnitWarning is not necessarily advisory: Code says whether it is a defect in the FILE or a limit of the ANALYSIS. Findings coded UnitFindingDimensionalMismatch or UnitFindingUnparseable are promoted to hard `unit_inconsistency` structural errors and invalidate the document; UnitFindingAnalysis findings do not. See the UnitFinding\* constants in units.go for the policy.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/validate.go#L59) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UnitWarning)

</div>

</div>
