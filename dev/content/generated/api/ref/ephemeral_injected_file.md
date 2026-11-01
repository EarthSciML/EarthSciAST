---
title: "ephemeral_injected_file"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `ephemeralInjectedFile` | not exported | `ephemeral_injected_file` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function ephemeralInjectedFile(file: EsmFile | null, sourcePath: string | null, mname: string, imports: readonly unknown[], baseDir: string): Promise<EsmFile>
```

esm-spec §9.7.10 form C: build a throwaway `EsmFile` in which component
`mname` has the run's `imports` (raw §9.7.2 entries) appended to its own
`expression_template_imports`, so the ordinary import resolver + §9.6.3
fixpoint lower its rewrite-targets under the run-chosen discretization. The
persisted `file` is never mutated. This is what lets one test/analysis suite
exercise a discretization-agnostic PDE leaf under several schemes with no
conflict between runs.

The raw base is re-read from `sourcePath` when given (relative import `ref`s
resolve against its directory), else re-serialized from `file`; `baseDir`
anchors the injected `ref`s. Mirrors the Julia reference
`_ephemeral_injected_file` (`EarthSciAST.jl/src/inline_tests.jl`).

This binding does not numerically simulate PDEs; the ephemeral build is the
structural-lowering half of form C (the leaf's rewrite-target is lowered in
this copy only). No solver is implied.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/ref-loading.ts#L1751)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn ephemeral_injected_file(file: &EsmFile, source_path: Option<&Path>, model_name: &str, imports: &[Value], base_dir: &Path) -> Result<EsmFile, EsmError>
```

esm-spec §9.7.10 form C: build a throwaway [`EsmFile`](/generated/api/ref/esm_file) in which component
`model_name` has the test's `imports` (raw §9.7.2 entries) appended to its
own `expression_template_imports`, so the ordinary import resolver + §9.6.3
fixpoint lower its rewrite-targets under the test-chosen discretization. The
persisted `file` is never mutated. When `source_path` is `Some`, the raw base
is re-read from it (relative `ref`s resolve against its directory); otherwise
it is re-serialized from the loaded `file` (`base_dir` anchors the injected
`ref`s). This is what lets one test suite exercise a discretization-agnostic
PDE leaf under several schemes with no conflict between tests. Mirrors the
Julia reference (`inline_tests.jl` `_ephemeral_injected_file`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/inline_tests.rs#L1438) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.ephemeral_injected_file.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
