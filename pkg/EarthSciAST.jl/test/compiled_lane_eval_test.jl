# The compiled lane evaluator the affine tier's per-box table materializers use
# (stencil.jl, "Compiled lane evaluation"): wherever it answers (`ok`), it must
# return exactly what `_eval_const_int` / `_eval_recipe` return at that cell, and
# wherever those would throw or apply a boundary policy it must decline.
using Test
using EarthSciAST

include("testutils.jl")

const ESM = EarthSciAST

@testset "compiled lane evaluation ≡ _eval_const_int / _eval_recipe" begin
    idx_names = ["i", "k"]
    nbr = Float64[mod1(3i + 2k, 7) for i in 1:7, k in 1:2]
    bad = [1.0 NaN; 2.0 3.0]
    periodic = ESM._wrap_bounded_const(Float64[10, 20, 30], (:periodic,), "per")
    const_arrays = Dict{String,Any}("nbr" => nbr, "bad" => bad, "per" => periodic)
    exprs = [
        _v("i"), _i(4), _n(3.0), _op("+", _v("i"), _i(1), _v("k")), _op("-", _v("i"), _v("k")),
        _op("-", _v("k")), _op("neg", _v("i")), _op("*", _i(2), _v("i"), _v("k")),
        _op("/", _v("i"), _v("k")), _op("/", _v("i"), _op("-", _v("k"), _i(1))),
        _op("mod", _op("+", _v("i"), _i(5)), _i(7)), _op("mod", _v("i"), _op("-", _v("k"), _i(1))),
        _op("max", _i(1), _op("min", _i(3), _v("i"))), _op("floor", _op("/", _v("i"), _i(2))),
        _op("ifelse", _op("<", _v("i"), _i(3)), _v("k"), _op("*", _v("i"), _i(2))),
        _op("<=", _v("i"), _v("k")), _op(">", _v("i"), _v("k")), _op(">=", _v("i"), _i(2)),
        _op("==", _v("i"), _v("k")),
        _idx("nbr", _v("i"), _v("k")), _idx("nbr", _op("+", _v("i"), _i(1)), _v("k")),
        _idx("nbr", _idx("nbr", _v("i"), _v("k")), _i(1)),
        _idx("bad", _v("k"), _i(2)), _idx("per", _op("+", _v("i"), _i(2))),
    ]
    for e in exprs
        node = ESM._ix_compile(e, idx_names, const_arrays)
        @test node !== nothing
        for i in -1:8, k in 0:3
            ref = try
                ESM._eval_const_int(e, Dict("i" => i, "k" => k), const_arrays)
            catch err
                err
            end
            v, ok = ESM._ix_eval(node, [i, k])
            if ok
                @test !(ref isa Exception) && v == ref
            end
            # It answers every in-range, plain-array case.
            if !(ref isa Exception) && !occursin("per", sprint(show, e)) &&
               !occursin("bad", sprint(show, e))
                @test ok
            end
        end
    end
    for e in [_v("j"), _n(1.5), _op("+"), _op("sin", _v("i")), _idx("nope", _v("i")),
              _idx("nbr", _v("i"))]
        @test ESM._ix_compile(e, idx_names, const_arrays) === nothing
    end

    # Whole recipes, against `_eval_recipe`, for each kind the materializers use.
    L = ESM.StateLayout(String[], ["u" => ([1], [7])])
    pg = ESM._PGatherArray(zeros(7 * 2), [7, 2])
    recs = [
        ESM._LaneRecipe(ESM.LANE_STATE, "u", ESM.ASTExpr[_idx("nbr", _v("i"), _v("k"))],
                        [1], [7], nothing, ""),
        ESM._LaneRecipe(ESM.LANE_STATE, "u", ESM.ASTExpr[_op("+", _v("i"), _v("k"))],
                        [1], [7], nothing, ""),                     # ghosts past 7
        ESM._LaneRecipe(ESM.LANE_STATE, "u", ESM.ASTExpr[_op("-", _v("i"), _v("k"))],
                        [1], [7], nothing, "", (0, [1])),
        ESM._LaneRecipe(ESM.LANE_CONST, "nbr", ESM.ASTExpr[_v("i"), _v("k")],
                        Int[], Int[], nbr, ""),
        ESM._LaneRecipe(ESM.LANE_PGATHER, "f", ESM.ASTExpr[_v("i"), _v("k")],
                        Int[], Int[], pg, ""),
        ESM._LaneRecipe(ESM.LANE_LOOPLIT, "", ESM.ASTExpr[], Int[], Int[], nothing, "k"),
    ]
    for rec in recs
        le = ESM._lane_evaluator(rec, idx_names, L, const_arrays)
        @test le !== nothing
        for i in 1:7, k in 1:2
            want = ESM._eval_recipe(rec, Dict("i" => i, "k" => k), L, const_arrays)
            v, ok = ESM._lane_eval(le, [i, k])
            @test ok
            @test v === want
        end
    end
end
