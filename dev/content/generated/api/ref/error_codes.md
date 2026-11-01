---
title: "error_codes"
description: "Stable constant · Errors"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** constant · **Topic:** [Errors](/generated/api/topics/errors)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ERROR_CODES` | `ERROR_CODES` | `ERROR_CODES` | `ERROR_CODES` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
const ERROR_CODES::NamedTuple
```

```julia
ERROR_CODES
```

The registry itself: a `NamedTuple` mapping each SCREAMING_SNAKE_CASE name to
the stable diagnostic code string it stands for. See this file's module-level
documentation for the contract. Grouped by the spec section that pins each
family.

```julia
julia> ERROR_CODES.UNDEFINED_VARIABLE
"undefined_variable"

julia> length(ERROR_CODES)   # how many codes this binding knows
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/error_codes.jl#L28)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const ERROR_CODES: { readonly ANALYSIS: "analysis"; readonly CIRCULAR_DEPENDENCY: "circular_dependency"; readonly DIMENSIONAL_MISMATCH: "dimensional_mismatch"; readonly JOIN_KEY_INVALID_TYPE: "join_key_invalid_type"; ... 160 more ...; readonly UNEVALUABLE_OPERATOR: "unevaluable_operator"; }
```

Central registry of the diagnostic code STRINGS emitted by this binding, plus
a neutral diagnostic base class.

Cross-binding contract — values must never change; see Python `ErrorCode`
enum (`pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py`). These strings
are pinned by the shared conformance fixtures: every value below equals, byte
for byte, a literal currently emitted somewhere in `src/`. This module only
CENTRALIZES the references — it does not (and must not) change any emitted
string. Adding a new diagnostic means adding an entry here AND coordinating
the value across every binding.

Keys are the SCREAMING_SNAKE_CASE form of the value (mirroring the Python
enum) so a reference reads as `ERROR_CODES.UNDEFINED_VARIABLE`.

**Properties**

- `URL_SUBSTITUTION_UNKNOWN_NAME` — A mount edge's `url_substitutions` key names no bare `{name}` placeholder
  of the referenced document's `data_sources` locations (esm-spec §4.7
  "Binding a data source's location at the mount").
- `DATA_SOURCE_MERGE_CONFLICT` — Two mounts contribute one `data_sources` name with entries that differ
  after `url_substitutions` and §8.2.1 resolution, and the mounting document
  does not declare it (esm-spec §4.7 "A mounted document's data sources").
- `MOUNT_FORM_UNSUPPORTED` — A §4.7 `{ ref }` mount at a form this binding does not implement — a
  top-level `reaction_systems.<k>` `{ ref }` (esm-spec §4.7 "Two mount forms,
  one mechanism"). Refused at `/reaction_systems/<k>` rather than left as an
  unresolved stub.
- `ELEMENT_TYPE_UNCARRIED` — A declared working precision reaches a construct that cannot carry it
  (esm-spec §4.7 "Working precision crosses a mount", §11.3.1): a mounted
  leaf's `domain.element_type` that must be written onto a reaction system,
  whose species and parameters have no per-variable `element_type`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/errors.ts#L16)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
ERROR_CODES = _build_error_codes()
```

Every diagnostic code this binding can emit, keyed by its SCREAMING_SNAKE
name: `ERROR_CODES.UNDEFINED_VARIABLE == "undefined_variable"`. The same
names and values are exported as `ERROR_CODES` by the Julia, TypeScript
and Rust bindings (API_SPEC.md §6), and the code strings are a
cross-binding contract that never changes. Read-only: attribute access and
the mapping protocol (`[]`, `in`, `len`, iteration, `keys` /
`values` / `items`) work; an unknown name raises `AttributeError` and
any assignment raises.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py#L703)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub const ERROR_CODES: &[(&str, &str)];
```

The `codes` registry in ENUMERABLE form: `(constant name, code string)`
for every diagnostic code this binding emits, in declaration order
(grouped by the pass that emits it, as the `codes` module is).

The Rust twin of Julia's `ERROR_CODES` `NamedTuple`
(`pkg/EarthSciAST.jl/src/error_codes.jl`), TypeScript's `ERROR_CODES`
object (`pkg/earthsci-ast-ts/src/errors.ts`), Python's `ErrorCode` enum and
Go's `codes.go`. The individual `pub const`s in `codes` are what raise
sites reference — that is the Rust-idiomatic form, and it is checked at
compile time. This table exists so the vocabulary can be *enumerated*:
diffed against a peer binding, or asserted over in a test.

**The code VALUES are a cross-binding contract and must never change.**
Every entry equals, byte for byte, a literal this crate already emitted.
Both this table and `codes` expand from the one
`diagnostic_code_registry!` declaration list, so the table covers every
constant by construction.

By convention each name is the SCREAMING_SNAKE_CASE form of its value —
the same convention the TypeScript keys and the Python enum members follow.
`error_codes_are_well_formed` in this module enforces it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/diagnostic.rs#L107) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/constant.ERROR_CODES.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this constant.</p>

</div>

</div>
