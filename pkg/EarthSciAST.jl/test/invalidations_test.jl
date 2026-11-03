# Code the solver stack invalidates is compiled again on first use. In a fresh
# process, count the EarthSciAST method instances that importing SciMLBase,
# OrdinaryDiffEqTsit5 and ForwardDiff invalidates; the limit is about 20% over
# the count when this was written, which holds for Julia 1.12 only.
using Test

@testset "solver stack invalidations" begin
    if v"1.12" <= VERSION < v"1.13"
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
        count <= 2500 || print(out)
        @test count <= 2500
    end
end
