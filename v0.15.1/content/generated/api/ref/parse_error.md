---
title: "parse_error"
description: "Stable error · Errors"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Errors](/generated/api/topics/errors)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ParseError` | `ParseError` | not exported | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ParseError <: EarthSciAST._LoadDiagnostic
ParseError(code::String, message::String, path::String, file::String, details::Dict{String, Any}, original_error::Union{Nothing, Exception})
ParseError(code, message, path, file, details, original_error)
ParseError(message::AbstractString; ...)
ParseError(message::AbstractString, original_error; code, path, file, details)
```

```julia
ParseError <: EarthSciASTError
```

A document that cannot be read: malformed JSON, a value the typed coercion
cannot accept, or a construct refused by name at the wire boundary
(`removed_op`, `faq_version_too_old`, `ic_in_reaction_system`). An ordinary
parse failure has an empty `code`; a refusal that is also a pinned finding
carries its `code` and `path`, which `load_failure_structural_error`
renders. After the common fields (see `_LoadDiagnostic`) comes
`original_error`, the underlying exception, if any.

    ParseError(message, original_error = nothing; code = "", path = "", file = "", details = Dict())

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/load_errors.jl#L25)

**Example** (`load_errors`)

```julia
# Text that is not JSON at all raises a ParseError...
try
    load_string("{not json")
    error("expected a ParseError")
catch e
    @assert e isa ParseError
    println(sprint(showerror, e))
end

# ...and JSON that breaks the schema raises a SchemaValidationError, whose
# `errors` field lists each failure.
try
    load_string("""{"esm": "1.0.0"}""")
    error("expected a SchemaValidationError")
catch e
    @assert e isa SchemaValidationError
    @assert !isempty(e.errors)
    println(sprint(showerror, e))
end
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/julia/documents.jl#L34-L52">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class ParseError extends EsmDiagnosticError
new ParseError(message: string, originalError?: Error, code?: string): ParseError
```

Parse error - thrown when JSON parsing fails, or when the wire boundary
refuses a document before schema validation. `code` defaults to
`parse_error`; a removed op or field carries `removed_op`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-ts/src/parse.ts#L99)

**Example** (`validate`)

```typescript
// A good document validates cleanly.
const good = validate(loadPath(fixture('decay.esm')))
assert.equal(good.is_valid, true)
assert.deepEqual(good.structural_errors, [])

// `validate` reports problems in its result; it does not throw. invalid.esm
// uses a variable `k` that its model never declares.
const bad = validateText(readFileSync(fixture('invalid.esm'), 'utf8'))
assert.equal(bad.is_valid, false)
assert.equal(bad.schema_errors.length, 0)
const [err] = bad.structural_errors
assert.equal(err.code, 'undefined_variable')
assert.equal(err.path, '/models/Broken/equations/0/rhs')
assert.match(err.message, /Variable "k" referenced in equation is not declared/)

// Loading a structurally invalid document still succeeds. Unit warnings found
// while loading go to `console.warn` unless you collect them yourself.
const warnings: UnitWarning[] = []
const broken = loadPath(fixture('invalid.esm'), { onUnitWarning: (w) => warnings.push(w) })
assert.equal(validate(broken).is_valid, false)
assert.match(warnings[0].message, /Unknown variable: k/)

// Text that is not JSON at all is a `ParseError`, thrown at load time.
assert.throws(() => loadString('{ not json'), ParseError)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/typescript/validate.ts#L11-L34">docs/api/examples/typescript/validate.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this error.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
