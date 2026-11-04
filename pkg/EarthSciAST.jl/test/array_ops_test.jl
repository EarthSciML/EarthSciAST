# The array-op nodes (faq / makearray / index / broadcast / reshape /
# transpose / concat) without a compiled system: parse/serialize round trips
# and `infer_array_shapes`. The runtime half — each array-op Model piped through
# `ModelingToolkit.System(model)`, compiled, solved and checked against
# analytical or reference solutions — is test/mtk/array_ops_mtk_test.jl, in the
# ModelingToolkit suite.
using Test
using EarthSciAST

const ESM2 = EarthSciAST

# ------------------------------------------------------------
# AST-building helpers — reduce boilerplate in the testsets.
# ------------------------------------------------------------

# Shorthand constructors for the expression AST.
_var(name::AbstractString) = ESM2.VarExpr(String(name))
_num(x) = ESM2.NumExpr(Float64(x))
_op(op::AbstractString, args...; kwargs...) =
    ESM2.OpExpr(String(op), ESM2.ASTExpr[args...]; kwargs...)

# Build an `index(u, idxs...)` node.
_idx(arr::AbstractString, idxs...) =
    _op("index", _var(arr), (i isa Integer ? _num(i) : i for i in idxs)...)

# Build a 1-D `faq` node with a single range declaration `i in lo:hi`.
function _faq1d(body::ESM2.ASTExpr, idx_name::AbstractString, lo::Int, hi::Int)
    return ESM2.OpExpr(
        "faq", ESM2.ASTExpr[];
        output_idx = Any[String(idx_name)],
        expr_body = body,
        ranges = Dict{String, Vector{Int}}(String(idx_name) => [lo, hi])
    )
end

# Build a 2-D `faq` node with ranges `i in 1:M, j in 1:N` — output shape
# is `(M, N)` when both indices appear in `output_idx`.
function _faq2d(
        body::ESM2.ASTExpr,
        i_name::AbstractString, ilo::Int, ihi::Int,
        j_name::AbstractString, jlo::Int, jhi::Int
    )
    return ESM2.OpExpr(
        "faq", ESM2.ASTExpr[];
        output_idx = Any[String(i_name), String(j_name)],
        expr_body = body,
        ranges = Dict{String, Vector{Int}}(
            String(i_name) => [ilo, ihi],
            String(j_name) => [jlo, jhi]
        )
    )
end

# Build a `D(u[i], t)` node for use inside a `faq` body.
_d_index(arr::AbstractString, idxs...) =
    _op("D", _idx(arr, idxs...); wrt = "t")

@testset "Array-op nodes without a compiled system (gt-vt3)" begin

    # ================================================================
    # Parse/serialize round trip smoke test for each array-op node.
    # ================================================================
    @testset "Parse/serialize round trip for all 7 array ops" begin
        # faq
        node1 = ESM2.OpExpr(
            "faq", ESM2.ASTExpr[_var("A"), _var("B")];
            output_idx = Any["i", "j"],
            expr_body = _op(
                "*",
                _op("index", _var("A"), _var("i"), _var("k")),
                _op("index", _var("B"), _var("k"), _var("j"))
            ),
            reduce = "+"
        )
        j1 = ESM2.serialize_expression(node1)
        @test j1["op"] == "faq"
        @test j1["output_idx"] == Any["i", "j"]
        @test j1["reduce"] == "+"
        rt1 = ESM2.expression_from_json(j1)
        @test rt1 isa ESM2.OpExpr
        @test rt1.output_idx == Any["i", "j"]
        @test rt1.reduce == "+"
        @test rt1.expr_body isa ESM2.OpExpr

        # makearray
        node2 = ESM2.OpExpr(
            "makearray", ESM2.ASTExpr[];
            regions = [[[1, 2]], [[3, 3]]],
            values = ESM2.ASTExpr[_var("x"), _num(0)]
        )
        j2 = ESM2.serialize_expression(node2)
        rt2 = ESM2.expression_from_json(j2)
        @test rt2.regions == [[[1, 2]], [[3, 3]]]
        @test length(rt2.values) == 2

        # index
        node3 = ESM2.OpExpr("index", ESM2.ASTExpr[_var("u"), _num(1), _num(2)])
        j3 = ESM2.serialize_expression(node3)
        rt3 = ESM2.expression_from_json(j3)
        @test rt3.op == "index"
        @test length(rt3.args) == 3

        # broadcast
        node4 = ESM2.OpExpr("broadcast", ESM2.ASTExpr[_var("A"), _var("B")]; fn = "+")
        rt4 = ESM2.expression_from_json(ESM2.serialize_expression(node4))
        @test rt4.fn == "+"

        # reshape
        node5 = ESM2.OpExpr("reshape", ESM2.ASTExpr[_var("A")]; shape = Any[1, 9])
        rt5 = ESM2.expression_from_json(ESM2.serialize_expression(node5))
        @test rt5.shape == Any[1, 9]

        # transpose
        node6 = ESM2.OpExpr("transpose", ESM2.ASTExpr[_var("T")]; perm = [2, 0, 1])
        rt6 = ESM2.expression_from_json(ESM2.serialize_expression(node6))
        @test rt6.perm == [2, 0, 1]

        # concat
        node7 = ESM2.OpExpr("concat", ESM2.ASTExpr[_var("A"), _var("B")]; axis = 1)
        rt7 = ESM2.expression_from_json(ESM2.serialize_expression(node7))
        @test rt7.axis == 1
    end

    # ================================================================
    # Shape inference sanity tests — scalar-only vs array cases.
    # ================================================================
    @testset "infer_array_shapes" begin
        # Scalar-only: empty dict.
        eq_scalar = ESM2.Equation(
            _op("D", _var("x"); wrt = "t"),
            _op("-", _var("x"))
        )
        @test isempty(infer_array_shapes([eq_scalar]))

        # 1D: u[i] over i in 1:5 → u has shape [1:5].
        eq_arr = ESM2.Equation(
            _faq1d(_d_index("u", _var("i")), "i", 1, 5),
            _faq1d(_op("-", _idx("u", _var("i"))), "i", 1, 5)
        )
        shapes = infer_array_shapes([eq_arr])
        @test haskey(shapes, "u")
        @test shapes["u"] == [1:5]

        # 1D with offset: u[i] + u[i+2] where i in 1:8 → u has shape [1:10].
        body = _op(
            "+",
            _idx("u", _var("i")),
            _idx("u", _op("+", _var("i"), _num(2)))
        )
        eq_off = ESM2.Equation(
            _faq1d(_d_index("u", _op("+", _var("i"), _num(1))), "i", 1, 8),
            _faq1d(body, "i", 1, 8)
        )
        shapes_off = infer_array_shapes([eq_off])
        @test shapes_off["u"] == [1:10]

        # 2D: u[i,j] over i in 1:4, j in 1:3 → shape [1:4, 1:3].
        eq_2d = ESM2.Equation(
            _faq2d(
                _op("D", _idx("u", _var("i"), _var("j")); wrt = "t"),
                "i", 1, 4, "j", 1, 3
            ),
            _faq2d(
                _op("-", _idx("u", _var("i"), _var("j"))),
                "i", 1, 4, "j", 1, 3
            )
        )
        shapes_2d = infer_array_shapes([eq_2d])
        @test shapes_2d["u"] == [1:4, 1:3]
    end
end
