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
the gate. `Pkg.develop` only writes the Manifest: the package is already in the
project's `[deps]`, so the tracked Project.toml is not touched.
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
