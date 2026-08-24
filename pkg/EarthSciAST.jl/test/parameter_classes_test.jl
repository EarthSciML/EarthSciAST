# The PARAMETER PARTITION — which parameters may be overridden at SOLVE time,
# and which are a rebuild (differentiability plan §3 Phase 5).
#
# Every one of these is spelled `"type": "parameter"` in the document, so the
# declared type is NOT the discriminator; WHERE THE VALUE IS CONSUMED is. Four
# classes, and the third is the reason the partition has to be automatic:
#
#   :numeric      — a scalar in the runtime `p`. A solve-time override is a `p`
#                   swap: cheap, and AD-transparent (the SciML `remake` shape).
#   :structural   — consumed at BUILD time (here: an `ic()` fold), where it can
#                   decide the shape of the problem. Refused by `remake`; a
#                   change is an explicit rebuild (`esm_problem` again).
#   :const_folded — declared a parameter but supplied as CONST DATA, frozen into
#                   the build and inlined into the RHS. It never reaches `p`, so
#                   ∂/∂(it) is an unconditional zero that a finite-difference
#                   check on its declared default would CONFIRM — a wrong
#                   gradient and a wrong check agreeing silently, which is why
#                   it gets its own class and its own message rather than being
#                   lumped in with :structural.
#   :forcing      — bound to a live buffer a discrete provider rewrites.
#
# The classification is a record of what the build actually READ (the
# `_PARAM_READS` seam), not a second static reading of the document — so the
# test that matters most is the one below where the SAME parameter name is
# structural in one document and numeric in another, differing only in whether
# an `ic()` equation reads it.
using Test
using EarthSciAST
import SciMLBase: solve, remake
import OrdinaryDiffEqTsit5: Tsit5
using ForwardDiff
using JSON3
const ESM_PC = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT (idempotent; standalone runs too)

_pc_D(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_pc_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_pc_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_pc_param(v; shape = nothing) = shape === nothing ?
    Dict{String,Any}("type" => "parameter", "default" => v) :
    Dict{String,Any}("type" => "parameter", "default" => v, "shape" => shape)

# One 0-D state, four parameters that reach the build by four different routes:
#   k       — RHS only                      ⇒ :numeric
#   y0      — read by the `ic(y)` fold      ⇒ :structural
#   dat[2]  — const-array data, gathered    ⇒ :const_folded
#   buf[2]  — live forcing buffer, gathered ⇒ :forcing
# `fold_ic` toggles ONLY whether the ic equation exists, so it is the control
# for "the class follows consumption, not declaration".
function _pc_doc(; fold_ic::Bool = true)
    eqs = Any[Dict{String,Any}(
        "lhs" => _pc_D("y"),
        "rhs" => _pc_o("*", "k", _pc_o("*", _pc_ix("dat", 1.0), _pc_ix("buf", 1.0))))]
    fold_ic && push!(eqs, Dict{String,Any}(
        "lhs" => _pc_o("ic", "y"), "rhs" => _pc_o("*", "y0", 2.0)))
    Dict{String,Any}(
        "esm" => "0.8.0", "metadata" => Dict{String,Any}("name" => "PC"),
        "index_sets" => Dict{String,Any}(
            "n" => Dict{String,Any}("kind" => "interval", "size" => 2)),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "y" => Dict{String,Any}("type" => "unknown", "default" => 0.0),
                "k" => _pc_param(1.5),
                "y0" => _pc_param(3.0),
                "dat" => _pc_param(0.0; shape = Any["n"]),
                "buf" => _pc_param(0.0; shape = Any["n"])),
            "equations" => eqs)))
end

# Both spellings: `build_evaluator(::Dict)` builds the document as authored (bare
# names), while `esm_problem` FLATTENS first (`M.dat`). Same arrays either way.
_pc_const() = Dict{String,Any}("dat" => [2.0, 0.0], "M.dat" => [2.0, 0.0])
_pc_param_arrays() = Dict{String,Any}("buf" => [5.0, 0.0], "M.buf" => [5.0, 0.0])

@testset "parameter classes" begin
    @testset "the four classes, derived from what the build read" begin
        insp = BuildInspection()
        f!, u0, p, _t, vm = ESM_PC.build_evaluator(_pc_doc();
            const_arrays = _pc_const(), param_arrays = _pc_param_arrays(),
            inspect = insp)
        cls = parameter_classes(insp)
        @test cls["k"] === :numeric
        @test cls["y0"] === :structural       # read by the ic() fold
        @test cls["dat"] === :const_folded
        @test cls["buf"] === :forcing
        # Every `:numeric` parameter is a slot of `p` — but NOT conversely: a
        # STRUCTURAL scalar still occupies its `p` slot (the RHS may read it at
        # runtime too), which is exactly why the class cannot be read off `p`.
        # It is refused at solve time because the build already baked a COPY of
        # the value elsewhere, and the two would then disagree.
        pm = param_map(p)
        @test all(haskey(pm, n) for (n, c) in cls if c === :numeric)
        @test haskey(pm, "y0") && cls["y0"] === :structural
        @test sort(collect(keys(pm))) ==
              sort([n for (n, c) in cls if c === :numeric || c === :structural])
        # The structural read actually happened: u0 = 2*y0.
        @test u0[vm["y"]] ≈ 6.0
    end

    @testset "the class follows CONSUMPTION, not the declared type" begin
        # Same variable, same declaration, one document with the `ic()` equation
        # and one without. Declared type cannot tell them apart; the build can.
        i1 = BuildInspection(); i2 = BuildInspection()
        ESM_PC.build_evaluator(_pc_doc(fold_ic = true);
            const_arrays = _pc_const(), param_arrays = _pc_param_arrays(), inspect = i1)
        ESM_PC.build_evaluator(_pc_doc(fold_ic = false);
            const_arrays = _pc_const(), param_arrays = _pc_param_arrays(), inspect = i2)
        @test parameter_classes(i1)["y0"] === :structural
        @test parameter_classes(i2)["y0"] === :numeric
    end

    @testset "the problem carries the partition" begin
        prob = ESM_PC.esm_problem(_pc_doc(), (0.0, 1.0); const_arrays = _pc_const(),
                                  param_arrays = _pc_param_arrays())
        cls = parameter_classes(prob)
        @test cls["M.k"] === :numeric
        @test cls["M.y0"] === :structural
        @test cls["M.dat"] === :const_folded
        @test cls["M.buf"] === :forcing
    end

    # ---- the narrowed refusal -------------------------------------------- #
    @testset "a NUMERIC override rides `p` through remake" begin
        Y = Symbol("M.y")
        prob = ESM_PC.esm_problem(_pc_doc(), (0.0, 1.0); const_arrays = _pc_const(),
                                  param_arrays = _pc_param_arrays())
        base = solve(prob, Tsit5())
        over = solve(remake(prob; p = Dict("M.k" => 3.0)), Tsit5())
        # dy/dt = k*dat[1]*buf[1] = k*10, y(0) = 6  ⇒  y(1) = 6 + 10k.
        @test base[Y][end] ≈ 6.0 + 10 * 1.5 rtol = 1e-8
        @test over[Y][end] ≈ 6.0 + 10 * 3.0 rtol = 1e-8
        @test !isapprox(base[Y][end], over[Y][end])     # it MOVED
        # …and it agrees with baking the same value in at construction time.
        prob2 = ESM_PC.esm_problem(_pc_doc(), (0.0, 1.0); p = Dict("M.k" => 3.0),
                                   const_arrays = _pc_const(),
                                   param_arrays = _pc_param_arrays())
        baked = solve(prob2, Tsit5())
        @test over[Y][end] ≈ baked[Y][end] rtol = 1e-10
        # `remake` does NOT mutate the problem it came from (§2.5.5).
        @test prob.p.var"M.k" == 1.5
        again = solve(prob, Tsit5())
        @test again[Y][end] ≈ base[Y][end]
        # A local (un-namespaced) key resolves, exactly as `esm_problem`'s do.
        @test solve(remake(prob; p = Dict("k" => 3.0)), Tsit5())[Y][end] ≈ over[Y][end]
    end

    @testset "structural / const-folded / forcing are refused BY CLASS" begin
        prob = ESM_PC.esm_problem(_pc_doc(), (0.0, 1.0); const_arrays = _pc_const(),
                                  param_arrays = _pc_param_arrays())
        for (name, word, fix) in (("M.y0", "STRUCTURAL", "esm_problem"),
                                  ("M.dat", "CONST-FOLDED", "esm_problem"),
                                  ("M.buf", "LIVE FORCING", "param_buffers"))
            err = nothing
            try
                remake(prob; p = Dict(name => 1.0))
            catch e
                err = e
            end
            @test err isa ESM_PC.SimulateError
            msg = sprint(showerror, err)
            @test occursin(name, msg)          # names the offending parameter
            @test occursin(word, msg)          # …and says which class it is
            @test occursin(fix, msg)           # …and what to do instead
        end
        # An unknown key is refused too — never silently dropped.
        @test_throws ESM_PC.SimulateError remake(prob; p = Dict("nope" => 1.0))
    end

    @testset "remake_parameters is a `p` swap, not a rebuild" begin
        prob = ESM_PC.esm_problem(_pc_doc(), (0.0, 1.0); const_arrays = _pc_const(),
                                  param_arrays = _pc_param_arrays())
        p2 = remake_parameters(prob, Dict("M.k" => 7.0))
        # Same NamedTuple shape and ORDER as `prob.p` (every `_NK_PARAM` node's
        # `idx` was minted against that order), one value changed.
        @test keys(p2) == keys(prob.p)
        @test param_map(p2) == param_map(prob.p)
        @test p2.var"M.k" == 7.0
        @test prob.p.var"M.k" == 1.5                  # the problem is untouched
        @test remake_parameters(prob, Dict{String,Float64}()) === prob.p
        du = zeros(length(prob.u0))
        prob.f!(du, copy(prob.u0), p2, 0.0)
        @test du[prob.var_map["M.y"]] ≈ 7.0 * 10
        # AD-TRANSPARENT, which is the whole reason this is a `p` swap and not a
        # rebuild: an override keeps its OWN type, so a `Dual` stays a `Dual` in
        # `p` and ∂(RHS)/∂(parameter) flows straight through the swap. A
        # `remake` that re-ran the build could not do this at all.
        p3 = remake_parameters(prob, Dict("M.k" => 7))
        @test p3.var"M.k" === 7                      # not coerced to Float64
        g = ForwardDiff.derivative(1.5) do kk
            pk = remake_parameters(prob, Dict("M.k" => kk))
            duk = zeros(typeof(kk), length(prob.u0))
            prob.f!(duk, copy(prob.u0), pk, 0.0)
            duk[prob.var_map["M.y"]]
        end
        @test g ≈ 10.0                               # d(k*dat[1]*buf[1])/dk
        # `remake` installs exactly what `remake_parameters` produces.
        @test remake(prob; p = Dict("M.k" => 7.0)).p == p2
    end
end
