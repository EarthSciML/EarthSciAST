# The Julia environments beside the package (the test sub-suites and the
# conformance adapters' script environments) are kept consistent with it by
# hand; these checks make that a test.
#
# 1. A holdback cap in the package's [compat] (an entry for a package it lists
#    only in [extras], outside the test target, to cap a dependency of
#    ModelingToolkit) binds only the environment that lists the package. So
#    every environment that installs ModelingToolkit restates each such cap,
#    with the same bound.
# 2. Every package a script environment lists is imported by a script that
#    activates it, or carries a holdback cap: an unused entry costs every run a
#    resolve and a precompile, and can break the bootstrap.
using Test

const _ENV_PKG_DIR = normpath(joinpath(@__DIR__, ".."))
const _ENV_REPO_ROOT = normpath(joinpath(_ENV_PKG_DIR, "..", ".."))

# The `key = value` entries of each `[section]` of a Project.toml, values as
# written (quotes kept off a plain string). Line-based: the files are flat.
function _project_sections(path::AbstractString)
    out = Dict{String, Dict{String, String}}()
    section = ""
    for line in eachline(path)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        if startswith(s, "[")
            section = strip(s, ['[', ']'])
            continue
        end
        m = match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", s)
        m === nothing && continue
        v = strip(m.captures[2])
        startswith(v, "\"") && endswith(v, "\"") && (v = v[2:(end - 1)])
        get!(Dict{String, String}, out, section)[m.captures[1]] = v
    end
    return out
end

_sect(p, name) = get(p, name, Dict{String, String}())

function _holdback_caps()
    p = _project_sections(joinpath(_ENV_PKG_DIR, "Project.toml"))
    test_target = Set(m.captures[1] for m in eachmatch(r"\"([^\"]+)\"", get(_sect(p, "targets"), "test", "")))
    held = Dict{String, String}()
    for name in keys(_sect(p, "extras"))
        name in test_target && continue
        (haskey(_sect(p, "deps"), name) || haskey(_sect(p, "weakdeps"), name)) && continue
        haskey(_sect(p, "compat"), name) && (held[name] = _sect(p, "compat")[name])
    end
    return held
end

# Every Project.toml under test/ and scripts/.
function _side_environments()
    out = String[]
    for top in ("test", "scripts"), (dir, _, files) in walkdir(joinpath(_ENV_PKG_DIR, top))
        "Project.toml" in files && push!(out, joinpath(dir, "Project.toml"))
    end
    return sort!(out)
end

@testset "environments beside the package" begin
    held = _holdback_caps()
    @test haskey(held, "SymbolicUtils")   # the package's own file was really read
    envs = _side_environments()
    @test length(envs) >= 6

    @testset "holdback caps restated where ModelingToolkit is installed: $(relpath(env, _ENV_PKG_DIR))" for env in envs
        p = _project_sections(env)
        haskey(_sect(p, "deps"), "ModelingToolkit") || continue
        for (name, bound) in held
            @test get(_sect(p, "compat"), name, nothing) == bound
        end
    end

    # The scripts that can activate an environment: the package's scripts and
    # the repository's per-tier Julia adapters.
    scripts = vcat(
        [joinpath(_ENV_PKG_DIR, "scripts", f) for f in readdir(joinpath(_ENV_PKG_DIR, "scripts")) if endswith(f, ".jl")],
        [
            joinpath(dir, f) for (dir, _, files) in walkdir(joinpath(_ENV_REPO_ROOT, "tests", "conformance"))
                for f in files if endswith(f, ".jl")
        ],
    )
    imported(text) = Set(
        String(strip(split(n, '.')[1]))
            for m in eachmatch(r"\b(?:using|import)\s+([A-Za-z_][\w.]*(?:\s*,\s*[A-Za-z_][\w.]*)*)", text)
            for n in split(m.captures[1], ',')
    )
    script_envs = [env for env in envs if startswith(env, joinpath(_ENV_PKG_DIR, "scripts"))]
    @test length(script_envs) >= 5
    @testset "every package of $(basename(dirname(env))) is imported by a script that activates it" for env in script_envs
        name = basename(dirname(env))
        activators = [f for f in scripts if occursin("\"$name\"", read(f, String))]
        @test !isempty(activators)
        used = union(Set{String}(), (imported(read(f, String)) for f in activators)...)
        unused = sort!([d for d in keys(_sect(_project_sections(env), "deps")) if !(d in used) && !haskey(held, d)])
        @test isempty(unused)
    end
end
