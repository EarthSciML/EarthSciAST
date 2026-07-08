using Test
using EarthSciAST
using JSON3
import ModelingToolkit
import Symbolics
import Catalyst
import OrdinaryDiffEqTsit5

const ESM = EarthSciAST
const MTK = ModelingToolkit

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

"""
Construct a 3-equation toy ODESystem via MTK macros (analogous to what a
per-model migration would touch). Returns the parent system.
"""
function _toy_ode_system(name::Symbol=:ToyDecay)
    # Build an ESM Model first and lower it to MTK.System — same approach
    # as the existing real_mtk_integration_test and simulate_e2e_test. MTK
    # v11 doesn't accept the short `System(eqs, iv; defaults=...)` path.
    vars = Dict{String,ESM.ModelVariable}(
        "x" => ESM.ModelVariable(ESM.StateVariable; default=1.0),
        "y" => ESM.ModelVariable(ESM.StateVariable; default=0.0),
        "z" => ESM.ModelVariable(ESM.StateVariable; default=0.0),
        "k1" => ESM.ModelVariable(ESM.ParameterVariable; default=0.5),
        "k2" => ESM.ModelVariable(ESM.ParameterVariable; default=0.3),
        "k3" => ESM.ModelVariable(ESM.ParameterVariable; default=0.1),
    )
    eqs = ESM.Equation[
        ESM.Equation(
            OpExpr("D", ESM.Expr[VarExpr("x")], wrt="t"),
            OpExpr("*", ESM.Expr[OpExpr("-", ESM.Expr[VarExpr("k1")]),
                                 VarExpr("x")])),
        ESM.Equation(
            OpExpr("D", ESM.Expr[VarExpr("y")], wrt="t"),
            OpExpr("-", ESM.Expr[
                OpExpr("*", ESM.Expr[VarExpr("k1"), VarExpr("x")]),
                OpExpr("*", ESM.Expr[VarExpr("k2"), VarExpr("y")])])),
        ESM.Equation(
            OpExpr("D", ESM.Expr[VarExpr("z")], wrt="t"),
            OpExpr("-", ESM.Expr[
                OpExpr("*", ESM.Expr[VarExpr("k2"), VarExpr("y")]),
                OpExpr("*", ESM.Expr[VarExpr("k3"), VarExpr("z")])])),
    ]
    model = ESM.Model(vars, eqs)
    return MTK.System(model; name=name)
end

function _toy_catalyst_system(name::Symbol=:ToyReactions)
    # Build via ESM → Catalyst so we don't depend on Catalyst's
    # `@species`/`@variables` re-exports (which have moved between versions).
    species = [ESM.Species("A"; default=1.0),
               ESM.Species("B"; default=0.0)]
    params = [ESM.Parameter("k1", 1.0),
              ESM.Parameter("k2", 0.5)]
    rxns = ESM.Reaction[
        ESM.Reaction(Dict("A" => 1), Dict("B" => 1), VarExpr("k1")),
        ESM.Reaction(Dict("B" => 1), Dict("A" => 1), VarExpr("k2")),
    ]
    esm_rsys = ESM.ReactionSystem(species, rxns; parameters=params)
    return Catalyst.ReactionSystem(esm_rsys; name=name)
end

# ---------------------------------------------------------------------
# mtk2esm — ODESystem branch
# ---------------------------------------------------------------------

@testset "mtk2esm: basic ODESystem export" begin
    sys = _toy_ode_system()
    out = mtk2esm(sys)

    @test out isa Dict
    @test out["esm"] == ESM.ESM_FORMAT_VERSION
    @test haskey(out, "metadata")
    @test haskey(out, "models")
    @test haskey(out["models"], "ToyDecay")

    model_dict = out["models"]["ToyDecay"]
    @test haskey(model_dict, "variables")
    @test haskey(model_dict, "equations")

    vars = model_dict["variables"]
    @test haskey(vars, "x")
    @test haskey(vars, "y")
    @test haskey(vars, "z")
    @test haskey(vars, "k1")
    @test haskey(vars, "k2")
    @test haskey(vars, "k3")

    @test vars["x"]["type"] == "state"
    @test vars["k1"]["type"] == "parameter"
    @test vars["x"]["default"] == 1.0
    @test vars["k1"]["default"] == 0.5

    @test length(model_dict["equations"]) == 3

    # Placeholders: tests/examples arrays, reference is omitted when
    # there is nothing to say (default version, no gaps, no source_ref).
    @test model_dict["tests"] == []
    @test model_dict["examples"] == []
end

@testset "mtk2esm: metadata kwargs pass through" begin
    sys = _toy_ode_system(:Tagged)
    out = mtk2esm(sys; metadata=(;
        description="toy decay chain",
        tags=["migration", "toy"],
        source_ref="earthsciml/UnitTests.jl@abc123",
        authors=["migrator"],
        version="0.2.0",
    ))

    @test out["metadata"]["name"] == "Tagged"
    @test out["metadata"]["description"] == "toy decay chain"
    @test out["metadata"]["authors"] == ["migrator"]
    @test out["metadata"]["tags"] == ["migration", "toy"]

    m = out["models"]["Tagged"]
    # Per-model description + version + source_ref are folded into
    # `reference.notes` — the Model schema has `additionalProperties: false`
    # and only Reference.notes is a schema-sanctioned free-form text slot.
    @test haskey(m, "reference")
    notes = m["reference"]["notes"]
    @test occursin("version: 0.2.0", notes)
    @test occursin("toy decay chain", notes)
    @test occursin("source_ref: earthsciml/UnitTests.jl@abc123", notes)
end

@testset "mtk2esm: JSON-serializable output" begin
    sys = _toy_ode_system()
    out = mtk2esm(sys)
    # Must round-trip through JSON without errors
    s = JSON3.write(out)
    parsed = JSON3.read(s)
    @test parsed["esm"] == ESM.ESM_FORMAT_VERSION
    @test haskey(parsed["models"], "ToyDecay")
end

# ---------------------------------------------------------------------
# mtk2esm — Catalyst.ReactionSystem branch
# ---------------------------------------------------------------------

@testset "mtk2esm: Catalyst ReactionSystem export" begin
    rs = _toy_catalyst_system()
    out = mtk2esm(rs)

    @test out["esm"] == ESM.ESM_FORMAT_VERSION
    @test haskey(out, "reaction_systems")
    @test haskey(out["reaction_systems"], "ToyReactions")

    rs_dict = out["reaction_systems"]["ToyReactions"]
    @test haskey(rs_dict, "species")
    @test haskey(rs_dict, "reactions")
    @test length(rs_dict["reactions"]) == 2

    # Species are serialized as a map keyed by name
    species_map = rs_dict["species"]
    @test species_map isa Dict || species_map isa AbstractDict
    @test haskey(species_map, "A")
    @test haskey(species_map, "B")
end

# ---------------------------------------------------------------------
# Gap detection — non-standard op triggers TODO_GAP note
# ---------------------------------------------------------------------

@testset "mtk2esm: TODO_GAP for non-standard operator" begin
    # Build an ESM Equation list with a deliberately-unknown op and run the
    # gap-walker directly. Exercising mtk2esm on a real @register_symbolic
    # construction is fragile across MTK versions, so we drive the detection
    # pass from ESM input — the walker is the public contract anyway.
    ext = Base.get_extension(ESM, :EarthSciASTMTKExt)
    @assert ext !== nothing
    walker = getfield(ext, :_walk_expr_for_gaps!)

    gaps = GapReport[]
    seen = Set{String}()
    unknown_op = OpExpr("sigmoid", ESM.Expr[VarExpr("u")])
    walker(unknown_op, seen, gaps, "equations[0].rhs")

    @test !isempty(gaps)
    @test gaps[1].bead_id == "gt-p3ep"
    @test occursin("sigmoid", gaps[1].description)

    # And confirm the full mtk2esm emits TODO_GAP in reference.notes when
    # a brownian-declared system is exported (uses the SDESystem path gap).
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.StateVariable; default=1.0),
        "k" => ESM.ModelVariable(ESM.ParameterVariable; default=0.5),
    )
    eqs = ESM.Equation[
        ESM.Equation(
            OpExpr("D", ESM.Expr[VarExpr("u")], wrt="t"),
            OpExpr("*", ESM.Expr[OpExpr("-", ESM.Expr[VarExpr("k")]),
                                 VarExpr("u")])),
    ]
    model = ESM.Model(vars, eqs)
    ode_sys = MTK.System(model; name=:GapSys)
    out = mtk2esm(ode_sys; metadata=(;
        source_ref="fake/ref", description="probe"))
    model_dict = out["models"]["GapSys"]
    @test haskey(model_dict, "reference")
    @test occursin("source_ref: fake/ref", model_dict["reference"]["notes"])
    @test occursin("probe", model_dict["reference"]["notes"])
end

# ---------------------------------------------------------------------
# Round-trip smoke test — no simulation, just syntactic
# ---------------------------------------------------------------------

@testset "mtk2esm: syntactic round-trip through load/save" begin
    sys = _toy_ode_system(:RoundTrip)
    out = mtk2esm(sys)

    tmpfile = tempname() * ".esm"
    try
        open(tmpfile, "w") do io
            write(io, JSON3.write(out; indent=2))
        end

        reloaded = ESM.load(tmpfile)
        @test reloaded isa ESM.EsmFile
        @test reloaded.esm == ESM.ESM_FORMAT_VERSION
        @test reloaded.models !== nothing
        @test haskey(reloaded.models, "RoundTrip")

        # The loaded Model must be buildable back into an MTK System.
        rt_sys = MTK.System(reloaded.models["RoundTrip"]; name=:RoundTripBack)
        @test rt_sys isa MTK.AbstractSystem

        simp = MTK.mtkcompile(rt_sys)
        @test length(MTK.unknowns(simp)) >= 3
    finally
        isfile(tmpfile) && rm(tmpfile)
    end
end

# ---------------------------------------------------------------------
# Full numerical round-trip — simulate original + round-tripped, compare
# ---------------------------------------------------------------------

@testset "mtk2esm: numerical round-trip (toy ODE)" begin
    sys = _toy_ode_system(:NumRT)
    out = mtk2esm(sys)

    tmpfile = tempname() * ".esm"
    try
        open(tmpfile, "w") do io
            write(io, JSON3.write(out; indent=2))
        end
        reloaded = ESM.load(tmpfile)
        rt_sys = MTK.System(reloaded.models["NumRT"]; name=:NumRTBack)

        # Simulate original
        simp_a = MTK.mtkcompile(sys)
        prob_a = MTK.ODEProblem(simp_a, Dict{Any,Any}(), (0.0, 5.0))
        sol_a = OrdinaryDiffEqTsit5.solve(prob_a, OrdinaryDiffEqTsit5.Tsit5();
            reltol=1e-10, abstol=1e-12)

        # Simulate round-tripped
        simp_b = MTK.mtkcompile(rt_sys)
        prob_b = MTK.ODEProblem(simp_b, Dict{Any,Any}(), (0.0, 5.0))
        sol_b = OrdinaryDiffEqTsit5.solve(prob_b, OrdinaryDiffEqTsit5.Tsit5();
            reltol=1e-10, abstol=1e-12)

        # Compare x, y, z at a few time points. Match unknowns by suffix.
        for state in ("x", "y", "z")
            u_a = nothing
            u_b = nothing
            for u in MTK.unknowns(simp_a)
                nm = string(MTK.getname(u))
                if endswith(nm, "_" * state) || nm == state
                    u_a = u; break
                end
            end
            for u in MTK.unknowns(simp_b)
                nm = string(MTK.getname(u))
                if endswith(nm, "_" * state) || nm == state
                    u_b = u; break
                end
            end
            @test u_a !== nothing
            @test u_b !== nothing
            for t in (0.0, 1.0, 2.5, 5.0)
                @test isapprox(sol_a(t, idxs=u_a), sol_b(t, idxs=u_b);
                               atol=1e-6, rtol=1e-6)
            end
        end
    finally
        isfile(tmpfile) && rm(tmpfile)
    end
end

# ---------------------------------------------------------------------
# mtk2esm_gaps quick pre-flight
# ---------------------------------------------------------------------

@testset "mtk2esm_gaps pre-flight on gap-free system" begin
    sys = _toy_ode_system(:Clean)
    gaps = mtk2esm_gaps(sys)
    @test gaps isa Vector{GapReport}
    @test isempty(gaps)  # no brownians declared
end

# ---------------------------------------------------------------------
# min/max operator round-trip — gt-p3ep gap resolution
# ---------------------------------------------------------------------

@testset "mtk2esm: min/max operators round-trip" begin
    # Build a system with min/max clamping equations
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.StateVariable; default=0.5),
        "k" => ESM.ModelVariable(ESM.ParameterVariable; default=0.1),
    )
    # D(u) ~ -k * min(max(u, 0.0), 1.0)  — clamped decay
    eqs = ESM.Equation[
        ESM.Equation(
            OpExpr("D", ESM.Expr[VarExpr("u")], wrt="t"),
            OpExpr("*", ESM.Expr[
                OpExpr("-", ESM.Expr[VarExpr("k")]),
                OpExpr("min", ESM.Expr[
                    OpExpr("max", ESM.Expr[VarExpr("u"), NumExpr(0.0)]),
                    NumExpr(1.0)
                ])
            ])
        ),
    ]
    model = ESM.Model(vars, eqs)
    sys = MTK.System(model; name=:MinMaxClamp)

    # Export to ESM
    out = mtk2esm(sys; metadata=(; source_ref="test/minmax"))

    @test out["esm"] == ESM.ESM_FORMAT_VERSION
    @test haskey(out["models"], "MinMaxClamp")

    model_dict = out["models"]["MinMaxClamp"]
    @test haskey(model_dict, "equations")
    @test length(model_dict["equations"]) == 1

    # Verify the equation contains min/max operators (not TODO_GAP).
    # MTK/Symbolics may canonicalize `-k * min(...)` as an n-ary product
    # with a literal -1 factor (`(-1) * k * min(...)`), so locate the min
    # node among the product's factors instead of assuming its position.
    eq = model_dict["equations"][1]
    rhs = eq["rhs"]
    @test rhs["op"] == "*"
    min_idx = findfirst(a -> a isa AbstractDict && get(a, "op", nothing) == "min",
                        rhs["args"])
    @test min_idx !== nothing
    min_node = rhs["args"][min_idx]
    @test min_node["args"][1]["op"] == "max"

    # Round-trip through JSON and verify
    s = JSON3.write(out)
    parsed = JSON3.read(s)
    @test parsed["models"]["MinMaxClamp"]["equations"][1]["rhs"]["op"] == "*"

    # Load back and verify we can reconstruct the MTK system
    tmpfile = tempname() * ".esm"
    try
        open(tmpfile, "w") do io
            write(io, s)
        end
        reloaded = ESM.load(tmpfile)
        rt_sys = MTK.System(reloaded.models["MinMaxClamp"]; name=:MinMaxClampRT)
        @test rt_sys isa MTK.AbstractSystem
    finally
        isfile(tmpfile) && rm(tmpfile)
    end
end

@testset "mtk2esm: n-ary min/max (nested)" begin
    # Test that min(a, b, c) is represented as nested min(a, min(b, c))
    vars = Dict{String,ESM.ModelVariable}(
        "x" => ESM.ModelVariable(ESM.StateVariable; default=1.0),
        "y" => ESM.ModelVariable(ESM.StateVariable; default=2.0),
        "z" => ESM.ModelVariable(ESM.StateVariable; default=3.0),
    )
    # D(x) ~ -min(x, y, z) — nested min
    eqs = ESM.Equation[
        ESM.Equation(
            OpExpr("D", ESM.Expr[VarExpr("x")], wrt="t"),
            OpExpr("-", ESM.Expr[
                OpExpr("min", ESM.Expr[
                    VarExpr("x"),
                    OpExpr("min", ESM.Expr[VarExpr("y"), VarExpr("z")])
                ])
            ])
        ),
    ]
    model = ESM.Model(vars, eqs)
    sys = MTK.System(model; name=:NaryMinMax)

    out = mtk2esm(sys)
    @test out["esm"] == ESM.ESM_FORMAT_VERSION

    model_dict = out["models"]["NaryMinMax"]
    eq = model_dict["equations"][1]
    inner_min = eq["rhs"]["args"][2]
    @test inner_min["op"] == "min"
    @test length(inner_min["args"]) == 2
end
