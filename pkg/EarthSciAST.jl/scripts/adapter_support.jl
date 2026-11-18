# Plumbing the conformance adapters share. An adapter includes this file first,
# before it loads the package: the environment bootstrap has to run before
# `using EarthSciAST`, so nothing here needs more than `Pkg` until the package is
# loaded, and the helpers that read the package take it as an argument.

import Pkg

"""
    activate_adapter_env(env)

Activate the adapter project at `env` and make it runnable. Manifest.toml is
gitignored repo-wide, so on a fresh checkout the package is developed from this
checkout and the project instantiated; on a warm run this is a fast resolve
check. A Manifest that cannot instantiate is a machine-local cache that has
fallen behind its Project.toml, so it is deleted and rebuilt rather than failing
the gate. On a fresh checkout `Pkg.develop` also rewrites the tracked
Project.toml: it adds a machine-specific `[sources]` path for the package and
drops the file's comments. Those edits are local and must not be committed.
"""
function activate_adapter_env(env::AbstractString)
    manifest = joinpath(env, "Manifest.toml")
    bootstrap() = begin
        Pkg.activate(env; io = devnull)
        isfile(manifest) ||
            Pkg.develop(path = normpath(joinpath(@__DIR__, "..")); io = devnull)
        Pkg.instantiate(; io = devnull)
    end
    try
        bootstrap()
    catch err
        @warn "$(basename(env)) did not instantiate; rebuilding Manifest.toml" exception = (err, catch_backtrace())
        rm(manifest; force = true)
        bootstrap()
    end
    return nothing
end

"""
    flag_value(args, flag, default) -> String

The value after `flag` in `args`, or `default` — for a flag an adapter must read
before the package loads (which environment to activate). The full argument
parse still validates it.
"""
function flag_value(args, flag::AbstractString, default::AbstractString)
    for i in eachindex(args)
        args[i] == flag && i < length(args) && return String(args[i + 1])
    end
    return String(default)
end

"""
    check_compiler(compiler, vocabulary) -> String

`compiler` when it is in `vocabulary` (the package's `COMPILER_VOCABULARY`),
else an error naming the vocabulary. A value outside it is a broken invocation,
not a compiler the binding happens not to have.
"""
function check_compiler(compiler::AbstractString, vocabulary)
    names = String[String(c) for c in vocabulary]
    compiler in names ||
        error("--compiler must be one of " * join(names, ", ") * ", got '$compiler'")
    return String(compiler)
end

"""
    bare_name(name) -> String

`name` with its leading component dropped (`Chemistry.O3[1,1]` → `O3[1,1]`), the
spelling a manifest's per-component lists use.
"""
bare_name(name::AbstractString) =
    occursin('.', name) ? String(split(name, '.'; limit = 2)[2]) : String(name)

"""
    nearest_index(times, t) -> Int

The index of the saved time closest to `t`. `saveat` puts a point on each
requested time, so this is an exact hit up to the solver's own arithmetic, and
it reports the value the solver saved rather than the dense interpolant.
"""
function nearest_index(times, t)
    best = firstindex(times)
    bestd = abs(times[best] - t)
    for i in eachindex(times)
        d = abs(times[i] - t)
        d < bestd && (bestd = d; best = i)
    end
    return best
end

"""
    parse_cli(argv; required = (), optional = ()) -> Dict{String,String}

The adapter's command line as flag → value. Every flag takes one value. A flag
outside `required` and `optional`, a flag with no value, a flag given twice and
a missing required flag are errors: a mistyped invocation fails rather than
running with a default.
"""
function parse_cli(argv; required = (), optional = ())
    known = (required..., optional...)
    out = Dict{String, String}()
    i = 1
    while i <= length(argv)
        flag = String(argv[i])
        flag in known || error("$(PROGRAM_FILE): unrecognised argument $(repr(flag))")
        i < length(argv) || error("$(PROGRAM_FILE): $flag needs a value")
        haskey(out, flag) && error("$(PROGRAM_FILE): $flag given twice")
        out[flag] = String(argv[i + 1])
        i += 2
    end
    for flag in required
        haskey(out, flag) || error("$(PROGRAM_FILE): $flag is required")
    end
    return out
end

"""
    write_report(path, text)

Write a report's JSON `text` to `path`, creating its directory, with a trailing
newline.
"""
function write_report(path::AbstractString, text::AbstractString)
    mkpath(dirname(abspath(path)))
    open(path, "w") do io
        write(io, text)
        write(io, "\n")
    end
    return nothing
end

"""
    to_native(x)

A parsed JSON value (JSON3's lazy views included) as plain `Dict{String,Any}` /
`Vector{Any}` / leaf values, so it is read with string keys.
"""
to_native(x::AbstractDict) = Dict{String, Any}(String(k) => to_native(v) for (k, v) in pairs(x))
to_native(x::AbstractVector) = Any[to_native(v) for v in x]
to_native(x) = x

# The diagnostic codes with which a compiler declines a document rather than
# answering it wrongly: a refusal, gated as a named exclusion, never as a wrong
# answer. The `E_TREEWALK_*` family and the direct emitter's code are refusals
# too (`is_refusal_code`).
const REFUSAL_CODES = (
    "compiler_refused_rule", "unevaluable_operator", "unlowered_operator",
    "unsupported_construct", "float32_unsupported", "E_DIRECT_EMIT_UNSUPPORTED",
)

is_refusal_code(code) =
    code !== nothing && (code in REFUSAL_CODES || startswith(code, "E_TREEWALK_"))

"""
    outcome(err) -> (; kind, code, rule, detail)

How a conformance tier reads an exception, from its structured fields and never
from its message text: `kind` is `:unavailable` for a `compiler_unavailable`
(a fact about the binding, not the document), `:refused` for a refusal code
(`is_refusal_code`), else `:error`. `code` is the error's `code` field
(`nothing` when it has none), `rule` its `rule` field (`""` when it has none)
and `detail` its `detail` (or `msg`) field, or the whole message when it has
neither.
"""
function outcome(err)
    field(name) = hasproperty(err, name) ? getproperty(err, name) : nothing
    c = field(:code)
    code = c isa AbstractString && !isempty(c) ? String(c) : nothing
    kind = code == "compiler_unavailable" ? :unavailable :
        is_refusal_code(code) ? :refused : :error
    rule = field(:rule)
    detail = field(:detail)
    detail isa AbstractString || (detail = field(:msg))
    return (
        kind = kind, code = code,
        rule = rule isa AbstractString ? String(rule) : "",
        detail = detail isa AbstractString ? String(detail) : sprint(showerror, err),
    )
end
