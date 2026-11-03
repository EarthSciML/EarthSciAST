# Code the solver stack invalidates is compiled again on first use. In a fresh
# process, count the EarthSciAST method instances that importing SciMLBase,
# OrdinaryDiffEqTsit5 and ForwardDiff invalidates, against a limit about 20%
# over the count measured on each Julia minor version. The count depends on the
# flags the package images were built with, so it is taken only under the
# default ones (`Pkg.test` adds `--check-bounds=yes` before Julia 1.13).
using Test
using EarthSciAST
using OrdinaryDiffEqTsit5: Tsit5
using SciMLBase

const _INVALIDATION_LIMITS = Dict(v"1.12" => 2500, v"1.13" => 2450)

@testset "solver stack invalidations" begin
    limit = get(_INVALIDATION_LIMITS, VersionNumber(VERSION.major, VERSION.minor), nothing)
    opts = Base.JLOptions()
    if limit === nothing || opts.check_bounds != 0 || opts.code_coverage != 0
        @info "solver stack invalidations: no limit for Julia $VERSION under these flags"
        @test_skip false
    else
        child = """
        using SnoopCompileCore, EarthSciAST
        invs = @snoop_invalidations import SciMLBase, OrdinaryDiffEqTsit5, ForwardDiff
        own(m) = startswith(string(Base.moduleroot(m)), "EarthSciAST")
        mi(x) = x isa Core.CodeInstance ? x.def : x
        mis = unique(m for m in mi.(vcat(invs.logedges, invs.logmeths)) if m isa Core.MethodInstance && m.def isa Method && own(m.def.module))
        n = Dict{Method, Int}(); foreach(mi -> n[mi.def] = get(n, mi.def, 0) + 1, mis)
        foreach(p -> println(p[2], "  ", p[1]), first(sort!(collect(n); by = last, rev = true), 15))
        println(length(mis))
        """
        out = read(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $child`, String)
        count = parse(Int, last(split(strip(out), '\n')))
        @info "solver stack invalidations: $count (limit $limit)"
        count <= limit || print(out)
        @test count <= limit
    end
end

# The precompile workloads compile whatever path their documents take, so a
# document that stops solving or passing its inline test would quietly cache
# an error path instead.
@testset "precompile workload documents" begin
    for json in EarthSciAST._WORKLOAD_DOCS, compiler in (:interpreter, :native)
        file = load_string(json)
        @test SciMLBase.successful_retcode(solve(esm_problem(file, (0.0, 1.0); compiler), Tsit5()))
        @test all(r -> r.status == EarthSciAST.PASS, run_inline_tests(file; model_name = "M", alg = Tsit5(), compiler))
    end
end
