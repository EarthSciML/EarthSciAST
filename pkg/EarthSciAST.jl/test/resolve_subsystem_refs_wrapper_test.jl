# `resolve_subsystem_refs!` runs the load's §4.7 edge pipeline on the
# `SubsystemRef`s a typed file still carries. For every corpus document that
# mounts a local `subsystems.<k>` `{ref}` and has nothing else the load does on
# the root (no top-level mount stub, no §9.7 machinery, no enums), coercing the
# document and then calling the wrapper must give the subsystems and index sets
# `load_path` gives.

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

function _rsw_candidate(doc)::Bool
    doc isa AbstractDict || return false
    for k in ("operator_imports", "operators", "metaparameters", "enums")
        haskey(doc, k) && return false
    end
    haskey(doc, "reaction_systems") && return false
    mounts = false
    walk(c) = begin
        haskey(c, "operator_imports") && return false
        haskey(c, "operators") && return false
        subs = get(c, "subsystems", nothing)
        subs isa AbstractDict || return true
        for (_, s) in pairs(subs)
            s isa AbstractDict || continue
            r = get(s, "ref", nothing)
            if r isa AbstractString
                mounts = true
            else
                walk(s) || return false
            end
        end
        true
    end
    for (_, m) in pairs(get(doc, "models", Dict()))
        m isa AbstractDict || return false
        haskey(m, "ref") && return false
        walk(m) || return false
    end
    return mounts
end

_rsw_json(x) = JSON3.read(JSON3.write(x), Dict{String, Any})

@testset "resolve_subsystem_refs! agrees with load_path" begin
    checked = 0
    for dir in ("tests/valid",)
        root = joinpath(TESTUTILS_REPO_ROOT, dir)
        for (r, _, fs) in walkdir(root), f in sort(fs)
            endswith(f, ".esm") || continue
            path = joinpath(r, f)
            raw = try
                JSON3.read(read(path, String), Dict{String, Any})
            catch
                continue
            end
            _rsw_candidate(raw) || continue
            loaded = try
                EarthSciAST.load_path(path)
            catch
                continue
            end
            typed = EarthSciAST.coerce_esm_file(EarthSciAST._read_json_document(read(path, String)))
            typed = resolve_subsystem_refs!(typed, dirname(path))
            @testset "$(relpath(path, TESTUTILS_REPO_ROOT))" begin
                a = EarthSciAST.serialize_esm_file(loaded)
                b = EarthSciAST.serialize_esm_file(typed)
                @test _rsw_json(a["models"]) == _rsw_json(b["models"])
                @test _rsw_json(get(a, "index_sets", Dict())) == _rsw_json(get(b, "index_sets", Dict()))
                @test _rsw_json(get(a, "data_sources", Dict())) == _rsw_json(get(b, "data_sources", Dict()))
            end
            checked += 1
        end
    end
    # Guard the scan itself: an empty corpus would pass vacuously.
    @test checked >= 3
end
