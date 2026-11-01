---
title: "build_unit_env"
description: "Stable function · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `build_unit_env` | `BuildUnitEnv` |


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

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn build_unit_env(variables: &IndexMap<String, ModelVariable>) -> (HashMap<String, Unit>, Vec<UnitParseFailure>)
```

Build a `HashMap<String, Unit>` environment from model variable metadata,
together with a list of warnings for any variables whose declared unit
string could not be parsed.

A variable is entered into the environment ONLY when its dimension is
actually known. Both an *unparseable* unit string and a *missing* one leave
the variable OUT of the map, so `propagate_dim` yields `Dim::Unknown` for
it and every expression containing it is skipped for dimensional checking.

Neither case is coerced to dimensionless. Doing so would both HIDE genuine
mismatches (when the variable is used consistently) and MANUFACTURE false
ones (when the real unit was, e.g., `m`) — and since a provable mismatch is
now a hard validation error, a fabricated dimension would fail the build on
a legitimate file. A model that declares no units at all (a common idiom in
the shared corpus) is therefore simply not dimension-checked, rather than
being treated as an all-dimensionless model in which `D(u)/dt = A*sin(w*t)`
looks inconsistent.

The two cases are NOT alike, and only one of them is a defect:

* A MISSING `units` field is a legitimate choice — the variable is simply
  not dimension-checked.
* An UNPARSEABLE `units` field is a HARD ERROR (`unit_parse_error`,
  esm-spec §4.8.4). A unit string either resolves against the shared
  registry or it is a defect in the file: silently treating a typo
  (`1/time`, `m/s2`) as "dimension unknown" disables every dimensional check
  downstream, which is precisely the class of bug the checker exists to
  catch. The failures are returned to the caller, which reports each one at
  the JSON-Pointer of the offending DECLARATION.

Note this is a *different* case from a genuinely UNDETERMINABLE dimension (a
symbolic exponent), which stays a non-blocking warning: there the checker
cannot conclude, whereas here the author wrote something that is not a unit.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/units.rs#L1848) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.build_unit_env.html)

**Example** (`validate_equation_dimensions`)

```rust
let doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];
let (env, failures) = build_unit_env(&model.variables);
assert!(failures.is_empty());

// half_life = log(2) / lambda: seconds on both sides.
validate_equation_dimensions(&model.equations[1], &env)?;
// half_life is in s but lambda is in 1/s.
let wrong = parse_equation("half_life = lambda")?;
let err = validate_equation_dimensions(&wrong, &env).unwrap_err();
println!("{err}");
assert!(err.to_string().contains("mismatch"));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/units.rs#L21-L32">docs/api/examples/rust/units.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func BuildUnitEnv(raw map[string]string) (map[string]Unit, map[string]error)
```

BuildUnitEnv converts a map of name→unit-string into a map of name→Unit. Entries whose unit string fails to parse are omitted from the returned environment and reported in the second return value (a name→parse-error map) so callers can emit warnings. Empty unit strings are skipped without error.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/units.go#L2350) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#BuildUnitEnv)

</div>

</div>
