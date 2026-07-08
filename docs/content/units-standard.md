# ESM-Specific Units Standard

This document defines the canonical set of ESM-specific units that every binding
(Julia, Python, TypeScript, Rust, Go) must accept and resolve to the same
dimensions. These are units common in Earth system modelling but not part of SI,
where cross-binding divergence was observed in the 2026-04-15 units audit.

The Go binding is gated on a separate Go-units decision (gt-go-units) and is not
yet required to enforce this standard.

## Canonical Set

### Mole-fraction family (dimensionless)

All mole-fraction units are **dimensionless** for the purposes of dimensional
analysis. The scale factor relative to `mol/mol` is a known numeric constant and
is only applied during unit *conversion*, not during dimensional *checking*.

| Unit    | Scale vs mol/mol | Meaning                          |
|---------|------------------|----------------------------------|
| `mol/mol` | 1              | Mole fraction                    |
| `ppm`   | `1e-6`           | Parts per million                |
| `ppmv`  | `1e-6`           | Parts per million by volume (alias for `ppm`) |
| `ppb`   | `1e-9`           | Parts per billion                |
| `ppbv`  | `1e-9`           | Parts per billion by volume (alias for `ppb`) |
| `ppt`   | `1e-12`          | Parts per trillion               |
| `pptv`  | `1e-12`          | Parts per trillion by volume (alias for `ppt`) |

**Rationale:** For gases under the ideal-gas approximation, volume mixing ratio
equals mole fraction, so `ppmv` ≡ `ppm`, `ppbv` ≡ `ppb`, `pptv` ≡ `ppt`. Every
binding must treat these as aliases.

Dimensional compatibility rule: any two mole-fraction units are
dimensionally-equivalent and may be combined with additive operators without
warning. They are all dimensionally-equivalent to any other dimensionless
quantity.

### Molecule count atom

| Unit    | Dimension                    | Notes                               |
|---------|------------------------------|-------------------------------------|
| `molec` | dimensionless count          | Number of molecules; used in composite units like `molec/cm^3` (number density) and `molec/m^2` (areal density). Treated as a dimensionless count, not a mole-equivalent. |

`molec/cm^3` must parse as dimension `[length]^-3`. `molec/m^2` must parse as
dimension `[length]^-2`.

### Dobson unit

| Unit     | Dimension            | Definition                          |
|----------|----------------------|-------------------------------------|
| `Dobson` | `molec/area` ≡ `[length]^-2` | `1 Dobson = 2.6867e20 molec/m^2 = 2.6867e16 molec/cm^2` |

**Decision:** Dobson is **NOT dimensionless**. It is an areal number density of
ozone molecules, with dimension `[length]^-2` (since `molec` is a dimensionless
count atom — see above).

**Rationale for this choice:**
- Dobson is physically an areal number density, not a ratio. Treating it as
  dimensionless would silently allow it to add to any pure number, which is the
  exact cross-binding hazard this standard is meant to prevent.
- The conversion factor `2.6867e20 molec/m^2` (Loschmidt × 1e-5 m = 2.687e20)
  can be applied when converting to explicit `molec/m^2` or `molec/cm^2`.
- Bindings with a scale-factor-tracking unit system (Python/pint, Rust) may
  store the scale factor; bindings that only track dimensions
  (TypeScript/Julia) need only record the dimension `[length]^-2`.

## Per-Binding Status

| unit       | Julia | Python | TypeScript | Rust | Go |
|------------|:-----:|:------:|:----------:|:----:|:--:|
| `mol/mol`  |  ✓    |   ✓    |     ✓      |  ✓   | —  |
| `ppm`,`ppmv` | ✓   |   ✓    |     ✓      |  ✓   | —  |
| `ppb`,`ppbv` | ✓   |   ✓    |     ✓      |  ✓   | —  |
| `ppt`,`pptv` | ✓   |   ✓    |     ✓      |  ✓   | —  |
| `molec`    |  ✓    |   ✓    |     ✓      |  ✓   | —  |
| `Dobson`   |  ✓    |   ✓    |     ✓      |  ✓   | —  |

Go (`pkg/earthsci-ast-go`) is not required until gt-go-units lands.

## Verification

Each binding's units test suite has cases under the name "ESM-specific units
standard" that assert each of the above parses and dimensionally-compares as
specified. Cross-binding fixture tests live in the separate fixture-wiring
effort.
