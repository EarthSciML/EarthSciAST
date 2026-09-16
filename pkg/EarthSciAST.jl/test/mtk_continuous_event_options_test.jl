# esm-spec §5.2 options of a continuous event in the ModelingToolkit export.
#
# A continuous event's `affect_neg` runs on the NEGATIVE-going
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

# esm-spec §5.2: `root_find` "maps to DiffEq `rootfind` option". `"left"` (the
# default) places the event at the last point BEFORE the root, `"right"` at the
# first point after it. The affect records the condition's value at that point,
# `s := Pre(x)*Pre(x) - 2`, so it is negative for `"left"` and positive for
# `"right"`. A runner that drops `root_find` gives the `"left"` sign for both.
# The condition is `x*x - 2` with `x = t`: no floating-point `x` squares to
# exactly 2, so neither bracket of the root evaluates the condition to zero,
# which would make the two options indistinguishable.
function _root_find_doc(root_find)
    field = root_find === nothing ? "" : """, "root_find": "$(root_find)" """
    return """
    {"esm": "1.1.0", "metadata": {"name": "RootFind", "authors": ["test"]},
     "models": {"RootFind": {
       "variables": {"x": {"type": "unknown", "units": "1"},
                     "s": {"type": "unknown", "units": "1"}},
       "equations": [
         {"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 1.0},
         {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 0.0},
         {"lhs": {"op": "ic", "args": ["x"]}, "rhs": 0.0},
         {"lhs": {"op": "ic", "args": ["s"]}, "rhs": 7.0}],
       "continuous_events": [{"name": "cross",
         "conditions": [{"op": "-", "args": [{"op": "*", "args": ["x", "x"]}, 2.0]}],
         "affects": [{"lhs": "s",
                      "rhs": {"op": "-", "args": [{"op": "*", "args": [{"op": "Pre", "args": ["x"]},
                                                                       {"op": "Pre", "args": ["x"]}]},
                                                  2.0]}}]$(field)}]}}}
    """
end

@testset "MTK continuous events honour root_find (esm-spec §5.2)" begin
    for (root_find, side) in ((nothing, :left), ("left", :left), ("right", :right))
        @testset "root_find = $(repr(root_find))" begin
            model = EarthSciAST.load_string(_root_find_doc(root_find)).models["RootFind"]
            simp = ModelingToolkit.mtkcompile(ModelingToolkit.System(model))
            prob = ModelingToolkit.ODEProblem(simp, Dict(), (0.0, 2.0))
            sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                            reltol=1e-10, abstol=1e-12)
            @test sol.retcode == ModelingToolkit.SciMLBase.ReturnCode.Success
            s = only(filter(u -> endswith(string(ModelingToolkit.getname(u)), "s"),
                            ModelingToolkit.unknowns(simp)))
            s_end = sol(2.0, idxs=s)
            @info "root_find" root_find s_end
            @test s_end != 7.0                  # the event fired
            @test abs(s_end) < 1e-6             # at the root
            @test side === :left ? s_end < 0 : s_end > 0
        end
    end
end
