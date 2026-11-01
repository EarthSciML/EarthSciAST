---
title: "compiler"
description: "Stable type · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `Compiler` | `Compiler` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

Julia does not export this type.

**Planned:** API_SPEC.md §8 item 21: `esm_problem` gains a `compiler` keyword over the closed vocabulary `interpreter` / `native` / `xla` / `mtk` / `sympy` (§5.8), defaulting to a strict `native`, and every Problem exposes `compiler` and `compiler_report`. Julia `compiler::Symbol`, Python `compiler: str | None`, Rust `ProblemOptions.compiler: Option<Compiler>` over a new `Compiler` enum.

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
Compiler = Literal['native', 'interpreter', 'xla', 'mtk', 'sympy']
```

The type a caller's `compiler` keyword takes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/compiler.py#L59)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum Compiler {
    Native,
    Interpreter,
    Xla,
    Mtk,
    Sympy,
}

impl Compiler { pub fn as_str(self) -> &'static str }

impl Compiler { pub fn parse(name: &str) -> Option<Compiler> }

impl Compiler { pub fn parse_named(name: &str) -> Result<Compiler, String> }

impl Compiler { pub fn is_strict(self) -> bool }

impl Compiler { pub fn vocabulary() -> &'static [Compiler] }
```

Which strategy builds a Problem's right-hand side (API_SPEC §5.8,
esm-libraries-spec §2.5.10).

The vocabulary is CLOSED and the same in every binding. A value this
binding does not provide is REFUSED — never answered by quietly selecting
another one, because the point of naming a compiler is that the caller
knows which one ran.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/problem.rs#L233) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Compiler.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
