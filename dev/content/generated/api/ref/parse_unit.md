---
title: "parse_unit"
description: "Stable function · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `parseUnit` | not exported | `parse_unit` | `ParseUnit` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function parseUnit(unitStr: string): ParsedUnit
```

Parse a unit string into canonical SI dimensions plus scale factor.

STRICT: an unparseable unit string is an ERROR. It is never silently
collapsed to dimensionless — a dimensionless fallback is a *claim* about the
quantity, and a wrong one, which both hides real mismatches (everything
compares equal to everything) and manufactures false ones (against genuinely
dimensional operands).

Callers that must degrade gracefully rather than throw — the validators, which
want to leave a dimension UNKNOWN and carry on — use [`tryParseUnit`](/generated/api/extension/typescript#x-tryparseunit),
which returns `null` instead.

**Throws**

- [`UnitConversionError`](/generated/api/ref/unit_conversion_error) — on an unknown unit name, a malformed token,
    unbalanced parentheses, or a misused offset unit.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/units.ts#L216)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn parse_unit(unit_str: &str) -> Result<Unit, UnitError>
```

Parse a unit string into a Unit struct

Supports common scientific unit notations:
- base units (`"m"`, `"s"`, `"kg"`, `"mol"`, `"K"`, `"Pa"`, …)
- products (`"kg*m"`, `"N*m"`)
- quotients (`"m/s"`, `"mol/L"`)
- parenthesised groups (`"J/(mol*K)"`)
- integer powers (`"m^2"`, `"s^-1"`)
- dimensionless (`""`, `"1"`, `"dimensionless"`)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/units.rs#L2562) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.parse_unit.html)

**Example** (`convert_units`)

```rust
let km = parse_unit("km")?;
let m = parse_unit("m")?;
assert_eq!(convert_units(2.5, &km, &m)?, 2500.0);

// Incompatible dimensions are an error.
assert!(convert_units(1.0, &km, &parse_unit("s")?).is_err());
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/units.rs#L12-L17">docs/api/examples/rust/units.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ParseUnit(s string) (Unit, error)
```

ParseUnit parses a unit string into a Unit. Grammar:

```text
unit     := term ( ('*'|'/')? term )*
term     := atom ( ('^'|'**') exponent )?
exponent := '-'? (integer | decimal) | '(' '-'? integer '/' '-'? integer ')'
atom     := '1' | symbol | '%' | '(' unit ')'
```

TOKENS (esm-spec §4.8.2). A RUN is a maximal sequence of \[A-Za-z0-9\_\]. A run of digits alone, optionally followed by '.' and a second digit-only run, is a NUMBER; every other run is ONE symbol, which must be a table key as a whole: "s1", "1s" and "kgm" are never split into a key and a remainder, and "1e3" is a symbol, not exponent notation. The only numeric atom is the literal "1" ("01" and "1.0" are scaling factors). Exponents take no '+' sign.

EXPONENTS ARE RATIONAL. "1/s^0.5" (SDE noise intensity), "s^(-1/2)" and "m^(3/2)" are legitimate corpus units; an integer-only exponent grammar cannot express them and — under the hard-error severity for an unparseable unit — falsely rejects the files that carry them.

'\*' AND '/' ARE ONE PRECEDENCE LEVEL, applied strictly left to right: "J/mol\*K" is (J/mol)\*K, NOT J/(mol\*K), and "a/b/c" is a/(b\*c). Giving '\*' a tighter binding silently negates the exponent of every factor after a '/'.

Whitespace (space, tab, CR, LF) separates tokens and, between two terms, means MULTIPLICATION — the SI style "kg m^2 s^-2" and the corpus's "ppb^-1 s^-1" (== ppb^-1 \* s^-1). An explicit '\*' is equivalent. '\*\*' is accepted as a synonym for '^' (the Python/pint spelling, e.g. "Pa\*m\*\*3").

A unit string carries DIMENSIONS ONLY: there is no species-tag convention, so the "C" of "kg C/m^2" is the coulomb, not a carbon tag.

The empty string, "1" and "dimensionless" are the dimensionless unit. Only the EMPTY string is the empty unit: a whitespace-only string has no tokens and does not resolve. Non-ASCII spellings (μg, °C, W/m², J/(kg·K), Ω) are normalized first — see normalizeUnitString. Examples that must parse:

```text
"m", "m/s", "m/s^2", "kg*m^2/s^3", "cm^3/molec/s", "mol/mol", "1/s",
"Pa", "J/(mol*K)", "Pa*m**3", "ppb^-1 s^-1", "μg/m^3", "°C", "1/s^0.5",
"s^(-1/2)", "W/m²", "J/(kg·K)", "%", "".
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/units.go#L1250) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ParseUnit)

</div>

</div>
