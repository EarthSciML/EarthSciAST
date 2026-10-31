---
title: "cadence"
description: "Stable type · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | not exported | `Cadence` | `Cadence` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum Cadence {
    Const,
    Discrete,
    Continuous,
}

impl Cadence { pub fn as_str(self) -> &'static str }
```

The cadence lattice (`CONFORMANCE_SPEC.md` §5.7.1): `const ⊏ discrete ⊏
continuous`. The derived `Ord` **is** the lattice order (variants declared
low-to-high), so `class(node) = max` over inputs is just `Iterator::max`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/cadence.rs#L49) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Cadence.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Cadence int
func (c Cadence) String() string
```

Cadence is a value's evaluation class, forming the total order CadenceConst ⊏ CadenceDiscrete ⊏ CadenceContinuous (CONFORMANCE\_SPEC §5.7.1).

**Methods**

```go
func (c Cadence) String() string
```

String renders the class in the spelling `expect_cadence` and the conformance goldens use.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/cadence.go#L33) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Cadence)

</div>

</div>
