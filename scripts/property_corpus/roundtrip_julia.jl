#!/usr/bin/env julia

# Julia expression round-trip driver for property-corpus conformance.
#
# Reads expression JSON fixtures, passes each through
# EarthSciAST.parse_expression / serialize_expression, and emits
# a JSON object {fixture_name: {"ok": bool, "value"|"error": ...}} to stdout.
#
# Usage: julia roundtrip_julia.jl <fixture.json> [<fixture.json> ...]

using Pkg

project_root = dirname(dirname(dirname(@__FILE__)))
julia_pkg = joinpath(project_root, "pkg", "EarthSciAST.jl")
Pkg.activate(julia_pkg; io=devnull)

using EarthSciAST
using JSON3

function roundtrip_one(path::String)::Dict{String,Any}
    try
        raw = read(path, String)
        data = JSON3.read(raw)
        expr = EarthSciAST.parse_expression(data)
        out = EarthSciAST.serialize_expression(expr)
        # Strip JSON3-specific carrier types so the outer JSON3.write sees a
        # plain Dict/Vector tree. This MUST preserve each scalar's Julia type:
        # a `JSON3.read(JSON3.write(out))` round-trip instead re-INFERS a common
        # element type for a heterogeneous array (`[1.5e-9, -77305, 166348]` →
        # `Vector{Float64}`), silently re-floating the integer literals that
        # `parse_expression` narrowed to `IntExpr` (CONFORMANCE_SPEC §5.5.3.1
        # rule 1) — the sole reason Julia diverged on nested `min`/`concat`
        # bodies. `_plain_json` converts containers element-wise and leaves
        # `Int64`/`Float64` scalars intact.
        normalized = EarthSciAST._plain_json(out)
        return Dict{String,Any}("ok" => true, "value" => normalized)
    catch err
        return Dict{String,Any}("ok" => false, "error" => sprint(showerror, err))
    end
end

function main()
    results = Dict{String,Any}()
    for p in ARGS
        results[basename(p)] = roundtrip_one(p)
    end
    JSON3.write(stdout, results)
    println(stdout)
end

main()
