# The ModelingToolkit exporter speaks the same `broadcast` `fn` vocabulary as
# `validate()` and the tree-walk build (esm-spec §4.3.4). Split out of
# broadcast_alignment_test.jl, which pins the rest of §4.3.4 without
# ModelingToolkit; this file runs in the ModelingToolkit suite
# (test/mtk/runtests.jl).
using Test
using EarthSciAST
import EarthSciAST as ESS
import ModelingToolkit          # loads EarthSciASTMTKExt (exporter `fn` vocabulary)
import Symbolics
include("../testutils.jl")  # _v/_op builders

@testset "MTK exporter speaks the same `fn` vocabulary" begin
    # The shared `tests/fixtures/faq/` corpus runs through the MTK exporter,
    # not the tree-walk evaluator, so its `broadcast` vocabulary must be the same
    # one `validate()` accepts. It used to be a hand-listed dozen ops; it is now
    # derived from the registry (arithmetic + elementary rows with a scalar fn).
    MTKExt = Base.get_extension(EarthSciAST, :EarthSciASTMTKExt)
    @test MTKExt !== nothing
    fns = MTKExt._BROADCAST_FNS
    for n in [
            "+", "-", "*", "/", "^", "pow", "neg", "exp", "log", "log10",
            "sin", "cos", "tan", "sqrt", "abs", "sign", "floor", "ceil",
            "tanh", "asin", "atan", "atan2", "min", "max",
        ]
        @test haskey(fns, n)
    end
    # Comparison / logical / control rows stay OUT: broadcasting them would
    # yield symbolic Booleans, not the spec's 1.0/0.0 comparison values.
    for n in [
            "<", "==", "and", "or", "not", "ifelse", "Pre", "pi",
            "faq", "index", "makearray", "broadcast",
        ]
        @test !haskey(fns, n)
    end
    # A unary broadcast lowers through the exporter to the plain unary op — the
    # shape `tests/fixtures/faq/27_broadcast_unary.esm` exercises.
    L = MTKExt._Lowering(Dict{String, Any}("u" => Symbolics.variable(:u)), nothing)
    for f in ["-", "exp", "sqrt", "abs", "sin", "tan"]
        bc = MTKExt._build_broadcast(
            ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]; fn = f), L
        )
        plain = MTKExt._esm_to_symbolic(_op(f, _v("u")), L)
        @test isequal(bc, plain)
    end
    # The derived vocabulary is a strict SUPERSET of this exporter's plain-op
    # ladder, which has no arm for the deprecated word spellings `neg`/`pow`
    # (nor for `floor`/`ceil`/`sign`) — `broadcast(fn:"neg")` still lowers, to
    # the same symbolic as unary `-`.
    @test isequal(
        MTKExt._build_broadcast(
            ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]; fn = "neg"),
            L
        ),
        MTKExt._esm_to_symbolic(_op("-", _v("u")), L)
    )
    # …and the §4.3.4 `fn` contract is enforced there too.
    for bad in [
            ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]; fn = "not_a_real_op"),
            ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]),
            ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]; fn = "faq"),
            ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u"), _v("u")]; fn = "sin"),
            ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]; fn = "min"),
        ]
        @test_throws SimulateError MTKExt._build_broadcast(bad, L)
    end
end
