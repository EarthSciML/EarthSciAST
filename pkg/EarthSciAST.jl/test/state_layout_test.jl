# The flat state layout (src/tree_walk/state_layout.jl): `StateLayout` must
# answer every lookup, and iterate, exactly as the `Dict{String,Int}` of one
# `_cell_key` string per cell it replaced; the discovery arithmetic must find
# the same cells as the per-cell enumeration; `_InlineICs` must read as the
# per-cell keys an inline profile used to be expanded into.
using Test
using EarthSciAST

include("testutils.jl")

const ESM = EarthSciAST

# The map the build made before `StateLayout`: scalars in the given order, then
# each array's box column-major, one string key per cell.
function _oracle_var_map(scalars, arrays)
    names = copy(scalars)
    for (name, (lo, hi)) in arrays
        for I in CartesianIndices(ntuple(d -> lo[d]:hi[d], length(lo)))
            push!(names, ESM._cell_key(name, collect(Int, Tuple(I))))
        end
    end
    return Dict{String,Int}(n => i for (i, n) in enumerate(names)), names
end

@testset "StateLayout" begin
    scalars = ["M.a", "M.b"]
    arrays = ["M.u" => ([1], [5]), "M.v" => ([2, 0], [4, 3]), "M.w" => ([-1], [1]),
              "M.z" => ([1, 1, 1], [2, 1, 3])]
    L = ESM.StateLayout(scalars, arrays)
    oracle, names = _oracle_var_map(scalars, arrays)

    @testset "lookups and iteration match the per-cell Dict" begin
        @test length(L) == length(oracle)
        @test Dict(L) == oracle
        @test collect(keys(L)) == names                 # slot order
        @test [v for (_, v) in L] == collect(1:length(names))
        for (k, v) in oracle
            @test L[k] == v
            @test haskey(L, k)
            @test get(L, k, 0) == v
            @test ESM._slot_key(L, v) == k
            @test k in keys(L)
        end
        for bad in ["M.u[0]", "M.u[6]", "M.u[03]", "M.u[+3]", "M.u[ 3]", "M.u[3,]",
                    "M.u[3,1]", "M.v[2,-0]", "M.v[2]", "M.v[2,00]", "M.x[1]", "M.u",
                    "M.u[]", "M.u[1", "u[1]", "M.w[-2]", "M.w[--1]", "M.a[1]", "",
                    "M.u[1]]", "M.u[[1]"]
            @test !haskey(L, bad)
            @test get(L, bad, -7) == -7
            @test_throws KeyError L[bad]
        end
        @test get(L, :M_a, 3) == 3
        @test !haskey(L, 1)
    end

    @testset "block accessors" begin
        b = ESM._layout_block(L, "M.v")
        @test b.base == oracle["M.v[2,0]"]
        @test ESM._layout_block(L, "M.a") === nothing
        for (name, (lo, hi)) in arrays
            blk = ESM._layout_block(L, name)
            for I in CartesianIndices(ntuple(d -> lo[d]:hi[d], length(lo)))
                idx = collect(Int, Tuple(I))
                s = oracle[ESM._cell_key(name, idx)]
                @test ESM._layout_slot(L, name, idx) == s
                @test ESM._vm_slot(L, name, idx) == s
                @test ESM._vm_slot(oracle, name, idx) == s
                @test ESM._block_cell(blk, s) == idx
            end
        end
        @test ESM._layout_slot(L, "M.u", [6]) == 0
        @test ESM._layout_slot(L, "M.u", [1, 1]) == 0
        @test ESM._layout_slot(L, "M.q", [1]) == 0
    end

    @testset "extension appends blocks and leaves the base alone" begin
        E = ESM._layout_extend(L, ["M.obs" => ([1, 1], [2, 2])])
        @test length(L) == length(oracle)
        @test length(E) == length(oracle) + 4
        @test E["M.obs[1,1]"] == length(oracle) + 1
        @test E["M.obs[2,2]"] == length(oracle) + 4
        @test !haskey(L, "M.obs[1,1]")
        for (k, v) in oracle
            @test E[k] == v
        end
    end

    @testset "array names ending in a multi-byte character" begin
        # The name before '[' ends in a character wider than one byte, so the
        # byte before '[' is not a valid string index.
        T = ESM.StateLayout(["M.α"], ["M.θ" => ([1], [3]), "M.vθ" => ([0, 1], [1, 2])])
        toracle, tnames = _oracle_var_map(["M.α"], ["M.θ" => ([1], [3]), "M.vθ" => ([0, 1], [1, 2])])
        @test Dict(T) == toracle
        @test collect(keys(T)) == tnames
        for (k, v) in toracle
            @test T[k] == v
            @test haskey(T, k)
            @test get(T, k, 0) == v
        end
        @test get(T, "M.θ[2]", 0) == 3
        @test haskey(T, "M.θ[1]")
        for bad in ["M.θ[4]", "M.θ[0]", "M.θ", "θ[1]", "M.θθ[1]", "M.vθ[2,1]", "M.α[1]"]
            @test !haskey(T, bad)
            @test get(T, bad, -7) == -7
        end
        O = ESM._VarMapOverlay(Dict{String,Int}("\0lane\0" * "1" => -1), T)
        @test O["M.θ[3]"] == toracle["M.θ[3]"]
        @test get(O, "M.vθ[1,2]", 0) == toracle["M.vθ[1,2]"]
    end

    @testset "rank-0 block" begin
        R = ESM.StateLayout(String[], ["s" => (Int[], Int[])])
        @test length(R) == 1
        @test R["s[]"] == 1
        @test collect(keys(R)) == ["s[]"]
        @test !haskey(R, "s[1]")
    end

    @testset "overlay answers as a copy with the extra entries written in" begin
        extra = Dict{String,Int}("\0lane\0" * "1" => -1, "\0sub\0" * "2" => -1_000_000_002)
        O = ESM._VarMapOverlay(extra, L)
        want = merge(copy(oracle), extra)
        @test length(O) == length(want)
        @test Dict(O) == want
        for (k, v) in want
            @test O[k] == v
            @test get(O, k, 0) == v
        end
        @test !haskey(O, "M.u[9]")
        @test get(O, "M.u[9]", 0) == 0
        @test ESM._vm_slot(O, "M.u", [2]) == oracle["M.u[2]"]
    end
end

@testset "_InlineICs reads as the per-cell expansion" begin
    prof = [1.0 2.0 3.0; 4.0 5.0 6.0]
    explicit = Dict{String,Any}("x" => 2.5, "u[2,3]" => 9.0, "u[03,1]" => 7.0)
    ics = ESM._InlineICs(explicit, Pair{String,Array{Float64}}["u" => prof])
    want = copy(explicit)
    for I in CartesianIndices(prof)
        k = ESM._cell_key("u", collect(Int, Tuple(I)))
        haskey(want, k) || (want[k] = prof[I])
    end
    @test length(ics) == length(want)
    @test Dict(ics) == want
    for (k, v) in want
        @test ics[k] == v
        @test haskey(ics, k)
    end
    @test ics["u[2,3]"] == 9.0             # the explicit key wins
    @test !haskey(ics, "u[3,1]")
    @test !haskey(ics, "u[01,1]")
    @test !haskey(ics, "u")
    L = ESM.StateLayout(["x"], ["u" => ([1, 1], [2, 3])])
    got = Dict{Int,Float64}()
    ESM._apply_ics_by_slot!((s, v) -> (got[s] = Float64(v)), L, ics)
    @test got[L["u[2,3]"]] == 9.0
    @test got[L["u[1,2]"]] == 2.0
    @test got[L["x"]] == 2.5
    @test length(got) == 7
end

@testset "_InlineICs with a multi-byte array name" begin
    # A per-cell initial condition and an inline profile for an array whose
    # name ends in a character wider than one byte.
    explicit = Dict{String,Any}("θ[1]" => 9.0, "α" => 0.5)
    ics = ESM._InlineICs(explicit, Pair{String,Array{Float64}}["θ" => [1.0, 2.0, 3.0]])
    @test ics["θ[1]"] == 9.0
    @test ics["θ[2]"] == 2.0
    @test haskey(ics, "θ[3]")
    @test !haskey(ics, "θ[4]")
    @test !haskey(ics, "θ")
    @test length(ics) == 4
    L = ESM.StateLayout(["α"], ["θ" => ([1], [3])])
    got = Dict{Int,Float64}()
    ESM._apply_ics_by_slot!((s, v) -> (got[s] = Float64(v)), L, ics)
    @test got == Dict(L["α"] => 0.5, L["θ[1]"] => 9.0, L["θ[2]"] => 2.0, L["θ[3]"] => 3.0)
end

@testset "LHS cell discovery: boxes by arithmetic, others cell by cell" begin
    idx_names = ["i", "j"]
    # Every affine form agrees with `_eval_const_int` at every binding.
    forms = [_v("i"), _i(3), _n(2.0), _op("+", _v("i"), _i(1)), _op("-", _v("j"), _i(2)),
             _op("-", _v("i")), _op("neg", _v("j")), _op("*", _i(2), _v("i")),
             _op("*", _i(-1), _op("+", _v("j"), _i(4))), _op("+", _v("i"), _v("i")),
             _op("-", _v("i"), _v("i")), _op("+", _i(5), _op("*", _v("j"), _i(1)), _i(-2))]
    for f in forms
        t = ESM._lhs_index_affine(f, idx_names)
        @test t !== nothing
        pos, coef, c = t
        for i in -2:3, j in -1:2
            env = Dict("i" => i, "j" => j)
            @test (pos == 0 ? c : coef * (pos == 1 ? i : j) + c) ==
                  ESM._eval_const_int(f, env)
        end
    end
    for f in [_op("*", _v("i"), _v("j")), _op("+", _v("i"), _v("j")), _v("k"),
              _n(1.5), _op("mod", _v("i"), _i(2)), _op("+")]
        @test ESM._lhs_index_affine(f, idx_names) === nothing
    end

    # The discovered cell set equals the set the per-cell enumeration finds.
    function cells_of(lhs_args, ranges)
        body = _op("D", _idx("u", lhs_args...); wrt="t")
        lhs = ESM.OpExpr("faq", ESM.ASTExpr[]; expr_body=body, output_idx=Any["i", "j"],
                         ranges=Dict{String,Any}("i" => Any[ranges[1]...],
                                                 "j" => Any[ranges[2]...]))
        cells = Dict{String,ESM._DiscoveredCells}()
        ESM._scan_lhs_cells!(cells, lhs, Set(["u"]))
        got = Vector{Int}[]
        ESM._foreach_cell_lex(idx -> push!(got, copy(idx)), cells["u"])
        return got
    end
    function enumerate_cells(lhs_args, ranges)
        s = Set{Vector{Int}}()
        for i in ESM._expand_int_range(ranges[1]), j in ESM._expand_int_range(ranges[2])
            env = Dict("i" => i, "j" => j)
            push!(s, [ESM._eval_const_int(a, env) for a in lhs_args])
        end
        return sort(collect(s))
    end
    cases = [
        ([_v("i"), _v("j")], ([1, 4], [2, 5])),                      # a box
        ([_op("+", _v("i"), _i(1)), _op("-", _v("j"))], ([1, 4], [2, 5])),
        ([_v("j"), _v("i")], ([1, 3], [1, 2])),                      # transposed box
        ([_v("i"), _i(7)], ([1, 3], [1, 2])),                        # j unused
        ([_v("i"), _v("i")], ([1, 3], [1, 2])),                      # diagonal: per cell
        ([_op("*", _i(2), _v("i")), _v("j")], ([1, 3], [1, 2])),     # stride 2: per cell
        ([_v("i"), _v("j")], ([1, 2, 7], [1, 2])),                   # stepped range: per cell
        ([_op("mod", _v("i"), _i(2)), _v("j")], ([1, 4], [1, 2])),   # not affine: per cell
    ]
    for (args, ranges) in cases
        @test cells_of(args, ranges) == enumerate_cells(args, ranges)
    end
end

@testset "a built model with a multi-byte array name" begin
    _θ(i) = Dict{String,Any}("op" => "index", "args" => Any["θ", i])
    _faq(e) = Dict{String,Any}("op" => "faq", "output_idx" => Any["i"],
        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "cells")), "expr" => e)
    model = Dict{String,Any}(
        "variables" => Dict{String,Any}("θ" => Dict{String,Any}(
            "type" => "unknown", "shape" => Any["cells"], "default" => 1.0)),
        "equations" => Any[Dict{String,Any}(
            "lhs" => _faq(Dict{String,Any}("op" => "D", "args" => Any[_θ("i")], "wrt" => "t")),
            "rhs" => _faq(Dict{String,Any}("op" => "*", "args" => Any[-2.0, _θ("i")])))])
    doc = Dict{String,Any}("esm" => "0.6.0", "metadata" => Dict{String,Any}("name" => "theta"),
        "index_sets" => Dict{String,Any}("cells" => Dict{String,Any}("kind" => "interval", "size" => 3)),
        "models" => Dict{String,Any}("M" => model))
    # A per-cell initial condition, then an inline profile.
    for (ics, want) in ((Dict{String,Any}("θ[1]" => 5.0), [5.0, 1.0, 1.0]),
                        (Dict{String,Any}("θ" => [1.0, 2.0, 3.0]), [1.0, 2.0, 3.0]))
        f!, u0, p, _, vm = ESM._build_evaluator(doc; initial_conditions = ics)
        @test [u0[vm["θ[$i]"]] for i in 1:3] == want
        @test haskey(vm, "θ[3]") && !haskey(vm, "θ[4]")
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test [du[vm["θ[$i]"]] for i in 1:3] == -2 .* want
    end
end
