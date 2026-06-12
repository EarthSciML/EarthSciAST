# Multi-Output Discretization Schemes — DRAFT Proposal

> **Status: DRAFT — not normative.** This document proposes an RFC §7
> extension; nothing here is in `esm-schema.json` or implemented by any
> binding. It exists so the design discussion starts from a concrete
> shape. Authored 2026-06-12 alongside the ESD Layer-B activation work
> (ESD/dsc-a7b2); the per-output lowering stopgap described in §5 below
> is shipped and covers the numerical-convergence acceptance.

## 1. Problem

Several authoritative ESD catalog rules describe operators that emit
**multiple named outputs** from one stencil application:

| Rule | Outputs | Consumer |
|---|---|---|
| `ppm_reconstruction` | `q_left_edge`, `q_right_edge` (+ documented `parabola.{a_L,a_R,da,a_6}` block) | PPM flux assembly |
| `weno5_advection_2d` | `q_left_edge_x`, `q_right_edge_x`, `q_left_edge_y`, `q_right_edge_y` | 2D advective flux |
| `flux_1d_ppm` | `F_{i+1/2}` (face-located) | flux-difference tendency |

The catalog encodes these as a `stencil` **object keyed by output name**
(vs. §7.1's flat array) plus an `outputs` array — a schema extension
ahead of this RFC. The §7.2 rewrite contract cannot express them: one
rule match replaces one expression occurrence with one expression. Two
rules with the same pattern cannot both fire on a single `reconstruct(q,
dim=x)` occurrence, and the outputs are not consumed *at* the matched
expression anyway — they are intermediate fields a *downstream* rule
(flux assembly) reads.

## 2. Design options considered

**A. Output-qualified `use:`** (`"use": "ppm_reconstruction#q_left_edge"`).
Minimal parser change, no AST change — but forces the model author to
write one distinct PDE op per output (`reconstruct_left(q)`,
`reconstruct_right(q)`), leaking the discretization's internal structure
into the model document. Rejected as the primary mechanism (though the
`scheme#output` resolution syntax is reused in option B).

**B. Scheme-emitted observed fields** (recommended). A new scheme
`kind: "multi_output_stencil"`. When a `use:` rule matches, the engine
does two things:

1. **Emits one observed arrayop equation per named output** into the
   enclosing model:

   ```jsonc
   { "lhs": { "op": "arrayop", "output_idx": ["i"],
              "expr": { "op": "index", "args": ["q_left_edge", "i"] }, ... },
     "rhs": <expansion of stencil["q_left_edge"] at $target>,
     "observed": true, "emitted_by": "ppm_reconstruction" }
   ```

   Output variables are auto-declared with `location` from the scheme's
   `emits_location` (face outputs live on faces; see open question §4.1)
   and `shape` from the operand's grid.

2. **Rewrites the matched expression** to the output named by a required
   `primary` field (e.g. `flux_1d_ppm`'s `F_{i+1/2}`), or — when the
   matched op is purely a *provider* (its value is never consumed
   directly, as with `reconstruct`) — the rule must appear in
   `provides`-position: matched as an equation-level declaration, not an
   expression rewrite. Strawman: a model-level `discretization_uses`
   block listing provider rules, mirroring how `boundary_conditions`
   flow through the engine as synthetic ops.

Downstream rules reference the emitted names as ordinary shaped
variables (they are, after emission). This composes with the existing
`requires_locations` / `emits_location` fields, which are parsed today
but unenforced.

**C. Tuple/record AST node** (a §4 `outputs` bundle selected by field
access). Uniform but heavy: touches expression typing, canonical JSON,
and every binding's evaluator. Rejected for v1.

## 3. Proposed schema (option B)

```jsonc
{
  "discretizations": {
    "ppm_reconstruction": {
      "kind": "multi_output_stencil",
      "applies_to": { "op": "reconstruct", "args": ["$q"], "dim": "$x" },
      "grid_family": "cartesian",
      "outputs": ["q_left_edge", "q_right_edge"],
      "emits_location": "face",          // per-output override allowed
      "primary": null,                    // provider-only: no expression rewrite
      "stencil": {
        "q_left_edge":  [ { "selector": {...}, "coeff": {...} }, ... ],
        "q_right_edge": [ ... ]
      }
    }
  }
}
```

Loader contract: `outputs` must equal the `stencil` object's key set;
each entry list validates per §7.1; `primary`, when non-null, names an
output. Bindings round-trip the block losslessly (same contract as §7.5
`dimensional_split`).

## 4. Open questions

1. **Staggered output extents.** A face-located output on a size-`n`
   periodic dimension has `n` faces, but `n+1` on a bounded one. The
   arrayop `ranges` for emitted equations need the §7.4 staggering
   vocabulary to be answerable; this proposal should land after (or
   with) staggered-location enforcement.
2. **Provider matching.** Option B's provider-position (`primary:
   null`) needs a home for the triggering occurrence: a
   `discretization_uses` model block, or matching `reconstruct(...)`
   equations whose LHS is discarded. Neither exists today.
3. **Derived (non-stencil) outputs.** CW84's parabola coefficients
   (`a_6 = 6·(q̄ − (a_L+a_R)/2)`) are expressions over other outputs,
   not stencil rows. A `derived: { <name>: <ExpressionNode over
   outputs/operand> }` block would cover them and keep the AST-first
   authoring policy.

## 5. Shipped stopgap (per-output lowering)

Until this lands, ESD's
`lower_stencil_to_scheme(name, spec; output=...)` lowers one named
output at a time to an ordinary §7.1 scheme; the ESD Layer-B walker
drives each output through `discretize → ArrayOp → eval` in its own
document and verifies convergence (`ppm_reconstruction` measures O(h⁴)
edge interpolation this way). What the stopgap cannot provide is the
document-level contract: one model document whose single `reconstruct`
occurrence yields all outputs plus their consumers — that is exactly the
Layer-A canonical byte contract the affected fixtures keep
`applicable:false` for.
