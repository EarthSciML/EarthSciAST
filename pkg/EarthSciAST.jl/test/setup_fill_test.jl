# Construction-time fills compiled through the right-hand-side cascade
# (tree_walk/setup_fill.jl).
#
# A coordinate-expression field `ic`, a setup-time makearray, a setup MAP and a
# faq-valued initialization equation are each lowered as one fill equation into
# a buffer block and run once through the emitted kernels. Two properties are
# pinned here:
#
#   * the fill is BIT-IDENTICAL to the interpreter's per-cell reference, at every
#     cell (`===`, so a signed zero or a NaN cannot pass for its neighbour);
#   * the compile is SHARED ACROSS N: the fill's kernels carry the box as
#     run-time data, so two sizes of the same expression emit the same code,
#     and a build at a second size compiles nothing new.
module SetupFillTests

using Test
using EarthSciAST
const EA = EarthSciAST

_expr(json) = EA.expression_from_json(EA.JSON3.read(json, Dict{String,Any}))

# The coordinate-expression initial condition of the two corpus documents this
# fill closed (ic_param_override.esm, pde_inline_assertions_exec.esm), at `n`
# cells, with the cell width a parameter `dx` so that only the box changes with
# `n`.
coord_ic(n) = _expr("""{"op": "*", "args": ["A", {"op": "cos", "args": [{"op": "*",
    "args": [3.141592653589793, {"op": "faq", "args": [], "output_idx": ["i"],
    "ranges": {"i": [1, $n]}, "expr": {"op": "*", "args": [{"op": "-", "args": ["i", 0.5]},
    "dx"]}}]}]}]}""")

# A makearray stencil over a const array: the interior and the two faces, the
# shape the build_once_spatial_ode.esm `darea` takes, at `n` cells.
stencil(n) = _expr("""{"op": "makearray", "args": [],
    "regions": [[[2, $(n - 1)]], [[1, 1]], [[$n, $n]]],
    "values": [
      {"op": "faq", "args": [], "output_idx": ["c"], "ranges": {"c": [2, $(n - 1)]},
       "expr": {"op": "/", "args": [{"op": "-", "args": [{"op": "index", "args": ["a", {"op": "+", "args": ["c", 1]}]},
                {"op": "index", "args": ["a", {"op": "-", "args": ["c", 1]}]}]}, {"op": "*", "args": [2, "dx"]}]}},
      {"op": "faq", "args": [], "output_idx": ["c"], "ranges": {"c": [1, 1]},
       "expr": {"op": "/", "args": [{"op": "-", "args": [{"op": "index", "args": ["a", 2]},
                {"op": "index", "args": ["a", $n]}]}, {"op": "*", "args": [2, "dx"]}]}},
      {"op": "faq", "args": [], "output_idx": ["c"], "ranges": {"c": [$n, $n]},
       "expr": {"op": "/", "args": [{"op": "-", "args": [{"op": "index", "args": ["a", 1]},
                {"op": "index", "args": ["a", $(n - 1)]}]}, {"op": "*", "args": [2, "dx"]}]}}]}""")

native(f) = EA._with_compiler_plan(f, EA._compiler_plan(:native))

function compiled(def, n; const_arrays = Dict{String,Any}(), params = Dict{String,Float64}())
    native() do
        p, psyms = EA._setup_fill_params(params)
        EA._compile_setup_fill(def, [1], [n]; const_arrays = const_arrays, p = p,
                               param_sym_set = psyms)
    end
end

emitted(sf) = EA.RuntimeGeneratedFunctions.get_expression(getfield(sf.section, :cgf))

@testset "construction-time fills" begin

    @testset "coordinate-expression ic: bit-identical, one compile for every N" begin
        codes = Any[]
        for n in (8, 64, 512)
            params = Dict("A" => 2.0, "dx" => 1.0 / n)
            sf = compiled(coord_ic(n), n; params = params)
            @test sf !== nothing
            @test sf.tier === :affine
            buf = EA._run_setup_fill(sf)
            ref = [EA._eval_cellwise(coord_ic(n), [i]; params = params) for i in 1:n]
            @test all(buf .=== ref)
            push!(codes, emitted(sf))
        end
        @test codes[1] == codes[2] == codes[3]
    end

    @testset "setup makearray: bit-identical, one compile for every N" begin
        codes = Any[]
        for n in (5, 40)
            a = [sin(0.7 * i) * 10.0^(i % 3) for i in 1:n]
            ca = Dict{String,Any}("a" => a)
            sf = compiled(stencil(n), n; const_arrays = ca, params = Dict("dx" => 0.25))
            @test sf !== nothing
            buf = EA._run_setup_fill(sf)
            ref = [EA._eval_cellwise(stencil(n), [i]; const_arrays = ca,
                                     params = Dict("dx" => 0.25)) for i in 1:n]
            @test all(buf .=== ref)
            push!(codes, emitted(sf))
        end
        @test codes[1] == codes[2]
    end

    @testset "a document's field ic under native is the interpreter's, bit for bit" begin
        root = normpath(joinpath(@__DIR__, "..", "..", ".."))
        for rel in ("tests/conformance/pde_inline_ic_param_override/fixtures/ic_param_override.esm",
                    "tests/spatial/pde_inline_assertions_exec.esm",
                    "tests/conformance/build_once_spatial_field/fixtures/build_once_spatial_ode.esm")
            path = joinpath(root, rel)
            pn = esm_problem(path, (0.0, 1.0))
            pi_ = esm_problem(path, (0.0, 1.0); compiler = :interpreter)
            @test all(pn.u0[pn.var_map[k]] === pi_.u0[j] for (k, j) in pi_.var_map)
            dn = similar(pn.u0); pn.f!(dn, pn.u0, pn.p, 0.0)
            di = similar(pi_.u0); pi_.f!(di, pi_.u0, pi_.p, 0.0)
            @test all(dn[pn.var_map[k]] === di[j] for (k, j) in pi_.var_map)
            rows = compiler_report(pn).rules
            @test any(r -> r.tier === :setup_codegen, rows)
            @test !any(r -> r.tier in (:setup_percell, :setup_compiled), rows)
        end
    end

    @testset "a fill declines rather than evaluating a cell its target lacks" begin
        # A box that does not start at 1 is outside the declared grid for a
        # field ic, and the fill leaves it to the other routes.
        cs = EA._DiscoveredCells()
        EA._cellset_push_box!(cs, [0], [4], "u")
        @test native(() -> EA._field_ic_fill(coord_ic(4), cs, Dict("A" => 1.0, "dx" => 0.25),
                                             Dict{String,Function}(), Dict{String,Any}())) === nothing
        # An expression with no array producer is the cell-independent forms'.
        cs2 = EA._DiscoveredCells()
        EA._cellset_push_box!(cs2, [1], [4], "u")
        @test native(() -> EA._field_ic_fill(_expr("""{"op": "*", "args": ["A", 2]}"""), cs2,
                                             Dict("A" => 1.0), Dict{String,Function}(),
                                             Dict{String,Any}())) === nothing
        # Off under the interpreter, whose per-cell reference must stay untouched.
        interp = EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
            EA._field_ic_fill(coord_ic(4), cs2, Dict("A" => 1.0, "dx" => 0.25), Dict{String,Function}(),
                              Dict{String,Any}())
        end
        @test interp === nothing
    end
end

end # module
