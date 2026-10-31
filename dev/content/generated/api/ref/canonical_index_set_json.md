---
title: "canonical_index_set_json"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `canonical_index_set_json` | `canonical_index_set_json` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
canonical_index_set_json(rows: Iterable[Any]) -> str
```

Canonical byte form of an index set (`CONFORMANCE_SPEC.md` §5.5.3): the
[`distinct`](/generated/api/ref/distinct) rows, each tuple serialised as a JSON array, in §5.5.1
sorted order, as compact UTF-8 JSON.

Two conforming bindings MUST produce byte-for-byte identical output for the
same input multiset. This is the artifact the adversarial conformance
harness (§5.5.4) compares byte-for-byte across duplicate / reversed /
permuted inputs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/relational.py#L391)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn canonical_index_set_json(rows: &[Key]) -> String
```

Canonical byte form of an index set (`CONFORMANCE_SPEC.md` §5.5.3): the
[`distinct`](/generated/api/ref/distinct) rows, each tuple serialised as a JSON array, in §5.5.1 sorted
order, as **compact JSON** (`,` / `:` separators, no spaces, UTF-8, no
`\uXXXX` escaping). Two conforming bindings MUST produce byte-for-byte
identical output for the same input multiset.

This is the artifact the adversarial conformance harness (§5.5.4) compares
byte-for-byte across duplicate / reversed / permuted inputs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/relational.rs#L505) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.canonical_index_set_json.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
