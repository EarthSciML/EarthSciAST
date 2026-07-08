# Regression tests for the no-MTK mock system snapshots (src/mock_systems.jl):
#   - MockPDESystem: `boundary_conditions` is reserved/empty, ICs come from
#     state defaults WITHOUT a `domain !== nothing` gate, and event summaries
#     are stored symmetrically with MockMTKSystem (struct `events` field).
#   - MockCatalystSystem: reactions render from the ORDERED substrates/products
#     vectors (deterministic strings), not the unordered backward-compat Dicts.
using Test
using EarthSciAST
const _ME = EarthSciAST

_mn(x) = _ME.NumExpr(x)
_mv(n) = _ME.VarExpr(n)
_mop(op, args...; kwargs...) = _ME.OpExpr(op, _ME.Expr[args...]; kwargs...)
_mderiv(name) = _mop("D", _mv(name); wrt="t")

@testset "Mock systems" begin

    @testset "MockPDESystem: ICs without a domain; empty reserved BCs; events field" begin
        vars = Dict{String,ModelVariable}(
            "u" => ModelVariable(StateVariable; default=1.5),
            "D" => ModelVariable(ParameterVariable; default=0.1),
        )
        eq = Equation(
            _mderiv("u"),
            _mop("*", _mv("D"), _mop("grad", _mop("grad", _mv("u"); dim="x"); dim="x")),
        )
        model = Model(vars, [eq])
        flat = flatten(model; name="Diffuse")
        @test flat.domain === nothing            # spatial via operator dims only
        pde = MockPDESystem(flat; name=:Diffuse)
        # ICs from state defaults are emitted even with no explicit domain
        # (the old `flat.domain !== nothing` gate silently dropped them).
        @test "Diffuse.u(t=0) = 1.5" in pde.initial_conditions
        # BCs are reserved: always empty.
        @test isempty(pde.boundary_conditions)
        # Symmetric event storage: struct field, not a metadata stash.
        @test pde.events isa Vector{String}
        @test !haskey(pde.metadata, "events")
    end

    @testset "event summaries symmetric between MockMTKSystem and MockPDESystem" begin
        ev = ContinuousEvent(_ME.Expr[_mv("x")],
                             [AffectEquation("x", _mn(0.0))])
        vars = Dict{String,ModelVariable}("x" => ModelVariable(StateVariable; default=1.0))
        ode_model = Model(vars, [Equation(_mderiv("x"), _mv("x"))];
                          continuous_events=[ev])
        ode_flat = flatten(ode_model; name="M")
        ode_mock = MockMTKSystem(ode_flat; name=:M)
        @test ode_mock.events == ["continuous_event_1: 1 condition(s)"]

        pde_vars = Dict{String,ModelVariable}("u" => ModelVariable(StateVariable; default=0.0))
        pde_model = Model(pde_vars,
            [Equation(_mderiv("u"), _mop("grad", _mv("u"); dim="x"))];
            continuous_events=[ev])
        pde_flat = flatten(pde_model; name="P")
        pde_mock = MockPDESystem(pde_flat; name=:P)
        @test pde_mock.events == ["continuous_event_1: 1 condition(s)"]
    end

    @testset "MockCatalystSystem renders ordered substrates/products" begin
        species = [Species("A"), Species("B"), Species("C"), Species("D")]
        # Author order B before A: a Dict-based rendering could reorder these.
        rxn = Reaction("r1",
            [_ME.StoichiometryEntry("B", 1), _ME.StoichiometryEntry("A", 2)],
            [_ME.StoichiometryEntry("D", 1), _ME.StoichiometryEntry("C", 1)],
            _mv("k"))
        rsys = ReactionSystem(species, [rxn];
                              parameters=[Parameter("k", 0.1)])
        cat = MockCatalystSystem(rsys; name=:Ordered)
        # stoichiometry is stored as Float64 (matching the old Dict-based
        # rendering); only the ORDER is new — authored order, deterministic.
        @test cat.reactions == ["B + 2.0 A → D + C, rate: k"]
        # Source reaction (no substrates) renders with the empty-set glyph.
        src = Reaction("r2", nothing, [_ME.StoichiometryEntry("A", 1)], _mv("k"))
        cat2 = MockCatalystSystem(ReactionSystem(species, [src];
                                                 parameters=[Parameter("k", 0.1)]))
        @test cat2.reactions == ["∅ → A, rate: k"]
    end
end
