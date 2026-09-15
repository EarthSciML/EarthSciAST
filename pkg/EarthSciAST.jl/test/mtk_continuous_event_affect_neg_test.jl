# esm-spec §5.2: a continuous event's `affect_neg` runs on the NEGATIVE-going
# crossing, and `affects` is used for both directions only when `affect_neg` is
# null or absent (issue #356). The ModelingToolkit export must hand `affect_neg`
# to `SymbolicContinuousCallback`: left at MTK's default (`affect_neg = affect`),
# the downward crossing below runs `affects`, and an event whose `affects` is
# empty is not built at all.
using Test
using EarthSciAST
import ModelingToolkit
import OrdinaryDiffEqTsit5

# `x` falls at rate 1 from 2 and crosses 1 downward at t = 1, where `affect_neg`
# stops it (v := 0), so x(3) = 1. Running `affects` instead (v := 5) on that
# crossing sends it to 11; dropping the event lets it fall to -1.
function _affect_neg_doc(affects::AbstractString)
    return """
    {"esm": "1.1.0", "metadata": {"name": "AffectNeg", "authors": ["test"]},
     "models": {"AffectNeg": {
       "variables": {"x": {"type": "unknown", "units": "1"},
                     "v": {"type": "unknown", "units": "1"}},
       "equations": [
         {"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": "v"},
         {"lhs": {"op": "D", "args": ["v"], "wrt": "t"}, "rhs": 0.0},
         {"lhs": {"op": "ic", "args": ["x"]}, "rhs": 2.0},
         {"lhs": {"op": "ic", "args": ["v"]}, "rhs": -1.0}],
       "continuous_events": [{"name": "floor",
         "conditions": [{"op": "-", "args": ["x", 1.0]}],
         "affects": $(affects),
         "affect_neg": [{"lhs": "v", "rhs": 0.0}]}]}}}
    """
end

@testset "MTK continuous events honour affect_neg (esm-spec §5.2)" begin
    for (label, affects) in (("with a different positive-edge affect",
                              """[{"lhs": "v", "rhs": 5.0}]"""),
                             ("with no positive-edge affect", "[]"))
        @testset "$label" begin
            model = EarthSciAST.load_string(_affect_neg_doc(affects)).models["AffectNeg"]
            sys = ModelingToolkit.System(model)
            @test length(ModelingToolkit.continuous_events(sys)) == 1
            simp = ModelingToolkit.mtkcompile(sys)
            prob = ModelingToolkit.ODEProblem(simp, Dict(), (0.0, 3.0))
            sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                            reltol=1e-10, abstol=1e-12)
            @test sol.retcode == ModelingToolkit.SciMLBase.ReturnCode.Success
            x = only(filter(u -> endswith(string(ModelingToolkit.getname(u)), "x"),
                            ModelingToolkit.unknowns(simp)))
            @test isapprox(sol(3.0, idxs=x), 1.0; atol=1e-6)
        end
    end
end
