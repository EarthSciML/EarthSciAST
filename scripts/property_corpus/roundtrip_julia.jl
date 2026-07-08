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
        # Round-trip through JSON to strip JSON3-specific types so the outer
        # JSON3.write is a plain Dict/Vector tree.
        normalized = JSON3.read(JSON3.write(out))
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
