---
title: "load_options"
description: "Stable type · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `LoadOptions` | not exported | `LoadOptions` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface LoadOptions {
    canonical?: boolean;
    basePath?: string | undefined;
    metaparameters?: Record<string, number> | undefined;
    readFile?: ((path: string) => string) | undefined;
    injectedImports?: readonly unknown[] | undefined;
    assumeValid?: boolean | undefined;
    onUnitWarning?: ((warning: UnitWarning) => void) | undefined;
    onVersionWarning?: ((message: string) => void) | undefined;
}
```

Options controlling how the `load*` entry points parse and represent an ESM file.

**Properties**

- `canonical` — When `true`, numeric literals at Expression-bearing positions are
  decoded to tagged `NumericLiteral` leaves so downstream consumers can preserve the
  integer-vs-float distinction required by the canonical form
  (discretization RFC §5.4.1 / §5.4.6). When `false` or absent
  (default), numeric literals decode to plain JS numbers.
  
  Canonical mode only takes effect on [`loadString`](/generated/api/ref/load_string) and
  [`loadPath`](/generated/api/ref/load_path), which decode JSON text; [`loadDocument`](/generated/api/ref/load_document) takes an
  already-decoded object and ignores it.
- `basePath` — Directory anchoring relative `expression_template_imports` refs
  (esm-spec §9.7.2). Defaults to the current working directory. Callers
  loading from a known file path should pass that file's directory.
- `metaparameters` — Loader-API metaparameter bindings for the root document
  (esm-spec §9.7.6 binding site 4): name → integer. Already-closed edge
  bindings win; API bindings beat `default`s. Binding a name the
  document does not declare raises `template_import_unknown_name`.
- `readFile` — Synchronous file reader used to resolve template-library import refs.
  Defaults to Node's `fs.readFileSync` (via `process.getBuiltinModule`);
  browser hosts that need template imports must supply their own.
- `injectedImports` — Scope-directed template injection for a §4.7 subsystem-ref edge
  (esm-spec §9.7.10 form A): raw §9.7.2 import entries folded into this
  document's single top-level component's own scope BEFORE the §9.6.3
  fixpoint, so a mounted discretization-agnostic PDE leaf is lowered under
  the assembler-chosen discretization. Threaded in by `resolveSubsystemRefs`
  from the subsystem edge; not part of the public authoring surface.
- `assumeValid` — Skip schema validation because the caller has already run
  [`validateSchema`](/generated/api/ref/validate_schema) on this input. Version checks and the
  removed-construct rejections still apply. Used by `validate()` to avoid
  validating the same document twice.
- `onUnitWarning` — Receives each dimensional-analysis warning instead of the default
  `console.warn`. Used by `validate()` to collect unit warnings into its
  structured result.
- `onVersionWarning` — Receives the forward-compatibility warning emitted when the file's minor
  version is newer than the schema this build implements, instead of the
  default `console.warn`. Parallels `onUnitWarning` so hosts can route
  both load-time warnings into a structured channel.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/parse.ts#L292)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct LoadOptions {
    pub base_path: Option<PathBuf>,
    pub metaparameters: BTreeMap<String, i64>,
}
```

Options controlling how [`load_string_with_options`](/generated/api/extension/rust#x-load_string_with_options) /
[`load_document_with_options`](/generated/api/extension/rust#x-load_document_with_options) / [`load_path_with_options`](/generated/api/extension/rust#x-load_path_with_options) parse an ESM
file (esm-spec §9.7).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/parse.rs#L127) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.LoadOptions.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
