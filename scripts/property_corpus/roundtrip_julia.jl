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
        # `serialize_expression` returns a plain string-keyed
        # `Dict{String,Any}`/`Vector`/scalar tree directly (since the
        # `f02f99d2` "one post-wire carrier" refactor there are no JSON3
        # carrier types left to scrub, so the former `_plain_json` pass was
        # removed from the package). The plain tree preserves each scalar's
        # Julia type — the `Int64` literals `parse_expression` narrowed to
        # `IntExpr` (CONFORMANCE_SPEC §5.5.3.1 rule 1) stay `Int64`, so the
        # outer `JSON3.write` emits them as integers (no heterogeneous-array
        # re-floating). Emit `out` verbatim.
        normalized = EarthSciAST.serialize_expression(expr)
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
