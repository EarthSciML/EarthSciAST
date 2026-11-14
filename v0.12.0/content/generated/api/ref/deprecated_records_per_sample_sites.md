---
title: "deprecated_records_per_sample_sites"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `deprecated_records_per_sample_sites` | `deprecatedRecordsPerSampleSites` | `deprecated_records_per_sample_sites` | `deprecated_records_per_sample_sites` | `DeprecatedRecordsPerSampleSites` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
deprecated_records_per_sample_sites(file::EsmFile)
```

```julia
deprecated_records_per_sample_sites(file::EsmFile) -> Vector{String}
```

The JSON pointers at which the deprecated `records_per_sample` (esm-spec §8.3,
§8.5.1; removed at esm 3.0.0) is written in a loaded document, sorted
(byte-order): `/data_sources/<S>/temporal/records_per_sample` and
`/models/<M>[/subsystems/<S>…]/variables/<v>/update[/<i>]/from/records_per_sample`
and `/reaction_systems/<R>[/subsystems/<S>…]/parameters/<p>/update[/<i>]/from/records_per_sample`
(`/<i>` only for an array-form `update`). Empty when the document never writes
it. The load entry points warn `deprecated_records_per_sample` once, naming
these, when it is not empty.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/EarthSciAST.jl/src/validate.jl#L1715)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function deprecatedRecordsPerSampleSites(esmFile: EsmFile): string[]
```

The sorted JSON pointers at which the deprecated `records_per_sample` is
written in `esmFile` (esm-spec §8.3, §8.5.1):
`/data_sources/<S>/temporal/records_per_sample` and
`/models/<M>[/subsystems/<S>…]/variables/<v>/update[/<i>]/from/records_per_sample`
and
`/reaction_systems/<R>[/subsystems/<S>…]/parameters/<p>/update[/<i>]/from/records_per_sample`.
Components behind an unmounted `{ref}` are not visited.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-ts/src/records-per-sample.ts#L438)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
deprecated_records_per_sample_sites(file: EsmFile) -> list[str]
```

The JSON pointers at which a loaded document writes the deprecated
`records_per_sample` (esm-spec §8.3, §8.5.1; removed at esm 3.0.0),
sorted by plain string order:
`/data_sources/<S>/temporal/records_per_sample` and
`/models/<M>[/subsystems/<S>...]/variables/<v>/update[/<i>]/from/records_per_sample`
and
`/reaction_systems/<R>[/subsystems/<S>...]/parameters/<p>/update[/<i>]/from/records_per_sample`
(`/<i>` only for an array-form `update`). Mounted components are walked
at the place they are mounted. The top-level loaders warn once, naming
these, when the list is non-empty.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L3466)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn deprecated_records_per_sample_sites(file: &EsmFile) -> Vec<String>
```

The JSON pointers at which the deprecated `records_per_sample` is written
in `file` (esm-spec §8.5.1), sorted by plain byte order:
`/data_sources/<S>/temporal/records_per_sample`,
`/models/<M>[/subsystems/<S>…]/variables/<v>/update[/<i>]/from/records_per_sample`
and
`/reaction_systems/<R>[/subsystems/<S>…]/parameters/<p>/update[/<i>]/from/records_per_sample`
(`/<i>` only for an array-form `update`). Loading a document for which
this is non-empty warns once, `deprecated_records_per_sample`. Runs on
every load, so a subsystem is scanned as raw JSON for the key, never
decoded.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-rs/src/structural.rs#L1564) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.deprecated_records_per_sample_sites.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func DeprecatedRecordsPerSampleSites(file *ESMFile) []string
```

DeprecatedRecordsPerSampleSites lists, sorted, the JSON pointers at which a loaded document writes the deprecated `records_per_sample` (esm-spec §8.3, §8.5.1; removed at esm 3.0.0): `/data_sources/<S>/temporal/records_per_sample`, `/models/<M>[/subsystems/<S>…]/variables/<v>/update[/<i>]/from/records_per_sample` and `/reaction_systems/<R>[/subsystems/<S>…]/parameters/<p>/update[/<i>]/from/records_per_sample` (`/<i>` only for an array-form update). These are the places the load-time `deprecated_records_per_sample` warning names. It runs on every load, so a subsystem is scanned as raw JSON for the key, never decoded.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-go/pkg/esm/validate.go#L2336) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DeprecatedRecordsPerSampleSites)

</div>

</div>
