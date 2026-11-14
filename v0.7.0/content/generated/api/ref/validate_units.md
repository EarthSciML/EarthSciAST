---
title: "validate_units"
description: "Stable function · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `validateUnits` | `validate_units` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function validateUnits(file: EsmFile): UnitWarning[]
```

Validate dimensional consistency of equations in an ESM file.

SCOPE: every real inline component — each top-level model / reaction system
AND their inline `subsystems` (walked via `forEachComponent(..., {recurse:
true})`; reference-stub and data-loader subsystems are opaque leaves and are
skipped). For each, `forEachEquation` covers a model's dynamic `equations`
and a reaction system's `constraint_equations`; models additionally have
their `observed` variable expressions checked.

BINDINGS: the shared top-level environment (top-level models' variables +
reaction systems' species/parameters, bare first-wins) is used
for EVERY component, including subsystems. Subsystem-local declarations are
deliberately NOT added, so a name defined only inside a subsystem stays an
"Unknown variable" and keeps the mismatch-suppression in `checkAndReport`.
This is the conservative scope required to broaden coverage without
introducing cross-language divergence: binding a subsystem's own variables
would un-suppress equation-level mismatches for nondimensionalized subsystem
ODEs (e.g. `D(u,t) = k*u` with a dimensionless `u`), which the other bindings
— none of which run a full per-equation dimensional check — never flag. A
top-level reaction system's `constraint_equations` still resolve fully,
because that system's species/parameters ARE in the shared environment.

SPATIAL-CALCULUS SUGAR: `grad`/`div`/`laplacian` (and `integral`, and any user
op) are ordinary open-tier rewrite-target ops with NO dimensional rule
(esm-spec §4.2 / §4.8.3 "any other op"): their dimension is UNDETERMINABLE
until a discretization rule lowers them to a `D` stencil, so `checkDimensions`
reports UNKNOWN and skips the enclosing check (§4.8.4). There is no coordinate
table and no op-name special case — the checker never divides an operand by a
coordinate's units. Unparseable variable-unit DECLARATIONS are still a defect;
`reportUnparseableVariableUnits` flags them per component (the only pass
that sees inline-subsystem variables).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/units.ts#L1310)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
validate_units(target: EsmFile | Model | ReactionSystem) -> UnitValidationResult
```

Convenience function to validate units of an ESM structure.

**Parameters**

- `target` (`EsmFile | Model | ReactionSystem`) — The ESM file, model, or reaction system to validate

**Returns**

- `UnitValidationResult` — UnitValidationResult with validation status and issues

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/units.py#L2428)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
