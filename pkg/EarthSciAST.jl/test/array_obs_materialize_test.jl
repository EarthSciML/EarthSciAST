# Factored array observeds ≡ the inlining build (differential).
#
# An array-shaped observed defined by an `aggregate`/`makearray` used to be
# INLINED into every reader (`_collect_array_inline_vars`); it is now evaluated
# ONCE PER RHS CALL into a dense buffer laid out above the ODE state, and readers
# gather that buffer (build.jl §2b-f). `ESS_ARRAY_OBS_INLINE=1` restores the
# inlining build, which is the oracle every case below compares against —
# bit-for-bit, not approximately.
include("testutils.jl")

using EarthSciAST
const ESM_AOM = EarthSciAST

# Build the same model twice — factored (default) and inlined (the oracle) —
# and return both `(f!, u0, p, var_map)` tuples. The switch is read at BUILD
# time, so flipping the env var between calls is enough.
function _aom_build_both(model; kwargs...)
    fac = ESM_AOM._build_evaluator_impl(model; kwargs...)
    inl = withenv("ESS_ARRAY_OBS_INLINE" => "1") do
        ESM_AOM._build_evaluator_impl(model; kwargs...)
    end
    return fac, inl
end

# du at a given state vector, from a built evaluator tuple.
function _aom_du(built, u)
    f!, _, p, _, _, _ = built
    du = similar(u)
    f!(du, u, p, 0.0)
    return du
end

@testset "factored array observeds" begin

    # ---- A chain of array observeds feeding an array state equation ----
    # g[i] = 2·u[i]                       (level 1)
    # h[i] = g[i] + g[i+1]                (level 2; g[N+1] is a ghost)
    # D(u[i]) = k·h[i]
    # Both observeds are array producers, so both are factored.
    N = 8
    isets = Dict("x" => ESM_AOM.IndexSet("interval"; size = N))
    _rng = Dict("i" => ESM_AOM.IndexSetRef("x"))
    _agg(body) = ESM_AOM.OpExpr("aggregate", ESM_AOM.ASTExpr[];
                                output_idx = Any["i"], ranges = copy(_rng),
                                expr_body = body)
    vars = Dict(
        "u" => ESM_AOM.ModelVariable(ESM_AOM.StateVariable; shape = ["x"]),
        "g" => ESM_AOM.ModelVariable(ESM_AOM.ObservedVariable; shape = ["x"]),
        "h" => ESM_AOM.ModelVariable(ESM_AOM.ObservedVariable; shape = ["x"]),
        "k" => ESM_AOM.ModelVariable(ESM_AOM.ParameterVariable; default = 0.25),
    )
    eqs = [
        ESM_AOM.Equation(_v("g"), _agg(_op("*", _n(2.0), _idx("u", _v("i"))))),
        ESM_AOM.Equation(_v("h"), _agg(_op("+", _idx("g", _v("i")),
                                            _idx("g", _op("+", _v("i"), _i(1)))))),
        ESM_AOM.Equation(_agg(_Didx("u", _v("i"))),
                         _agg(_op("*", _v("k"), _idx("h", _v("i"))))),
    ]
    model = ESM_AOM.Model(vars, eqs)
    ics = Dict("u[$j]" => Float64(j) for j in 1:N)
    fac, inl = _aom_build_both(model; index_sets = isets, initial_conditions = ics)

    @testset "differential ≡ the inlining build" begin
        @test fac[6].n_mat_array_obs == 2          # both observeds factored
        @test fac[6].n_mat_array_cells == 2N       # one buffer cell per element
        @test fac[6].n_mat_levels == 2             # h depends on g
        @test inl[6].n_mat_array_obs == 0          # the oracle inlines
        u0 = fac[2]
        @test u0 == inl[2]
        @test fac[5] == inl[5]                     # the PUBLIC var_map is ODE-only
        for probe in (u0, fill(1.0, N), collect(range(-3.0, 3.0; length = N)))
            @test _aom_du(fac, probe) == _aom_du(inl, probe)      # bit-identical
        end
        # ...and the value is the hand-computed one (h ghosts past the edge).
        du = _aom_du(fac, u0)
        h = [2.0 * u0[j] + (j < N ? 2.0 * u0[j+1] : 0.0) for j in 1:N]
        @test du == 0.25 .* h
    end

    @testset "buffer slots are build-owned, not ODE slots" begin
        # The buffers live ABOVE the state; nothing about the integrator's view
        # of the problem changes.
        @test length(fac[2]) == N
        @test all(0 < s <= N for s in values(fac[5]))
        @test !any(startswith(k, "g[") || startswith(k, "h[") for k in keys(fac[5]))
    end

    @testset "the RHS stays allocation-free" begin
        f!, u0, p, _, _, _ = fac
        du = similar(u0)
        f!(du, u0, p, 0.0)
        f!(du, u0, p, 0.0)
        @test (@allocated f!(du, u0, p, 0.0)) == 0
    end

    # ---- Ordering must be transitive THROUGH an observed that stays inlined ----
    # `s` is a SCALAR observed (never factored), so the edge g → s → w is
    # invisible to a direct-reference walk over the factored defs alone. If the
    # fills ran in the wrong order, `w` would read an unfilled `g` buffer.
    @testset "dependency order through an inlined observed" begin
        vars2 = Dict(
            "u" => ESM_AOM.ModelVariable(ESM_AOM.StateVariable; shape = ["x"]),
            "g" => ESM_AOM.ModelVariable(ESM_AOM.ObservedVariable; shape = ["x"]),
            "w" => ESM_AOM.ModelVariable(ESM_AOM.ObservedVariable; shape = ["x"]),
            "s" => ESM_AOM.ModelVariable(ESM_AOM.ObservedVariable),
        )
        eqs2 = [
            ESM_AOM.Equation(_v("g"), _agg(_op("+", _idx("u", _v("i")), _n(1.0)))),
            ESM_AOM.Equation(_v("s"), _op("+", _idx("g", _i(1)), _idx("g", _i(2)))),
            ESM_AOM.Equation(_v("w"), _agg(_op("*", _v("s"), _idx("g", _v("i"))))),
            ESM_AOM.Equation(_agg(_Didx("u", _v("i"))), _agg(_idx("w", _v("i")))),
        ]
        m2 = ESM_AOM.Model(vars2, eqs2)
        f2, i2 = _aom_build_both(m2; index_sets = isets, initial_conditions = ics)
        @test f2[6].n_mat_levels == 2       # w must fill strictly after g
        for probe in (f2[2], fill(2.0, N))
            @test _aom_du(f2, probe) == _aom_du(i2, probe)
        end
    end

    # ---- Observeds that MUST stay inlined ----
    # A buffer read is a RUNTIME value, so an observed referenced where the build
    # needs a CONCRETE one — a gather SUBSCRIPT, a range bound — cannot be
    # factored (the array analogue of `_obs_structural_refs!`). The gather TARGET
    # is the exemption: `index(obs, i…)` naming the observed IS the buffer read,
    # and so is a reference inside an inline producer that a gather selects.
    @testset "structural-position references keep the inline path" begin
        base = [ESM_AOM.Equation(_v("g"), _agg(_op("+", _idx("u", _v("i")), _n(1.0))))]
        pick(eqs) = ESM_AOM._collect_materialized_array_obs(
            ESM_AOM.Model(vars, eqs), eqs, Set(["g"]), Set{String}())

        # (a) plain gather of `g` — factored.
        @test pick(vcat(base, [ESM_AOM.Equation(_agg(_Didx("u", _v("i"))),
                                                _agg(_idx("g", _v("i"))))])) ==
              Set(["g"])
        # (b) `g` as a gather SUBSCRIPT — must stay inlined.
        @test isempty(pick(vcat(base,
            [ESM_AOM.Equation(_agg(_Didx("u", _v("i"))),
                              _agg(_idx("M", _idx("g", _v("i")))))])))
        # (c) `g` in an aggregate RANGE BOUND — must stay inlined.
        redu = ESM_AOM.OpExpr("aggregate", ESM_AOM.ASTExpr[];
                              output_idx = Any["i"],
                              ranges = Dict("i" => copy(_rng)["i"],
                                            "m" => Any[1, _idx("g", _v("i"))]),
                              expr_body = _idx("u", _v("m")))
        @test isempty(pick(vcat(base,
            [ESM_AOM.Equation(_agg(_Didx("u", _v("i"))), redu)])))
        # (d) `g` inside a `makearray` region value the reader gathers — an
        #     ordinary EXPRESSION position, so it is still factored.
        mk = ESM_AOM.OpExpr("makearray", ESM_AOM.ASTExpr[];
                            regions = [[[1, N]]],
                            values = ESM_AOM.ASTExpr[_agg(_idx("g", _v("i")))])
        @test pick(vcat(base, [ESM_AOM.Equation(_agg(_Didx("u", _v("i"))),
                                                _agg(_op("index", mk, _v("i"))))])) ==
              Set(["g"])
    end

    # ---- SILENT-WRONG-ANSWER regression: D of an array observed ----
    # `D(<array observed>, wrt: <axis>)` at ARRAY level lowers, through a
    # discretization rule, to a `makearray` whose region values are aggregates
    # gathering the operand at ±1. When the operand was an INLINED array
    # observed, that gather beta-reduced to a body the region expansion then
    # collapsed, and the derivative came out IDENTICALLY ZERO — with no error.
    # Factoring makes the observed a gather target exactly like a state, so
    # `D(w)` and `D(s)` reduce to the same kernel. Pinned as an equality:
    # `w` is a bit-exact copy of `s`, so A and B must agree at every cell.
    @testset "D of an array observed == D of the identical state" begin
        M = 6
        rngM = Dict("i" => Any[1, M])
        aggM(body) = ESM_AOM.OpExpr("aggregate", ESM_AOM.ASTExpr[];
                                    output_idx = Any["i"], ranges = copy(rngM),
                                    expr_body = body)
        # the lowered centered-difference-with-periodic-wrap region form
        function lowered_D(f)
            interior = aggM(_op("/", _op("-", _idx(f, _op("+", _v("i"), _i(1))),
                                              _idx(f, _op("-", _v("i"), _i(1)))),
                                _n(2.0)))
            west = aggM(_op("/", _op("-", _idx(f, _i(2)), _idx(f, _i(M))), _n(2.0)))
            east = aggM(_op("/", _op("-", _idx(f, _i(1)), _idx(f, _i(M - 1))), _n(2.0)))
            return ESM_AOM.OpExpr("makearray", ESM_AOM.ASTExpr[];
                                  regions = [[[1, 1]], [[2, M - 1]], [[M, M]]],
                                  values = ESM_AOM.ASTExpr[west, interior, east])
        end
        varsD = Dict(
            "u" => ESM_AOM.ModelVariable(ESM_AOM.StateVariable; shape = ["x"]),
            "A" => ESM_AOM.ModelVariable(ESM_AOM.StateVariable; shape = ["x"]),
            "B" => ESM_AOM.ModelVariable(ESM_AOM.StateVariable; shape = ["x"]),
            # `w` is a bit-exact copy of `u`
            "w" => ESM_AOM.ModelVariable(ESM_AOM.ObservedVariable; shape = ["x"],
                                         expression = aggM(_idx("u", _v("i")))),
        )
        eqsD = [
            ESM_AOM.Equation(_op("D", _v("u"); wrt = "t"), aggM(_n(0.0))),
            ESM_AOM.Equation(_op("D", _v("A"); wrt = "t"), lowered_D("w")),
            ESM_AOM.Equation(_op("D", _v("B"); wrt = "t"), lowered_D("u")),
        ]
        icsD = Dict{String,Float64}()
        for j in 1:M
            icsD["u[$j]"] = Float64(j)^2
            icsD["A[$j]"] = 0.0
            icsD["B[$j]"] = 0.0
        end
        isetsM = Dict("x" => ESM_AOM.IndexSet("interval"; size = M))
        f!, u0, p, _, vmD, dD = ESM_AOM._build_evaluator_impl(varsD |> vs ->
            ESM_AOM.Model(vs, eqsD); index_sets = isetsM, initial_conditions = icsD)
        @test dD.n_mat_array_obs == 1
        du = similar(u0); f!(du, u0, p, 0.0)
        A = [du[vmD["A[$j]"]] for j in 1:M]
        B = [du[vmD["B[$j]"]] for j in 1:M]
        @test A == B                       # THE invariant — exact, not approximate
        @test !all(iszero, A)              # and non-vacuous (it used to be all zeros)
        # the hand-computed centered difference of u = j², periodic wrap
        @test B == [(4.0 - 36.0) / 2, (9.0 - 1.0) / 2, (16.0 - 4.0) / 2,
                    (25.0 - 9.0) / 2, (36.0 - 16.0) / 2, (1.0 - 25.0) / 2]

        # ---- and the sibling shape: index(<observed HOLDING a lowered D>) ----
        # `hz` is an observed whose own definition IS the lowered derivative
        # (the ESD corpus spells this as `horiz = D(Mx, wrt: lon)`); a reader
        # then gathers it per cell. Inlined, that gather collapsed the region
        # expansion and the term went to zero — and unlike the shape above,
        # this one does NOT depend on the observed's loop-index names, so no
        # amount of careful naming in a rule library avoids it.
        varsC = copy(varsD)
        varsC["hz"] = ESM_AOM.ModelVariable(ESM_AOM.ObservedVariable; shape = ["x"],
                                            expression = lowered_D("u"))
        varsC["C"] = ESM_AOM.ModelVariable(ESM_AOM.StateVariable; shape = ["x"])
        eqsC = vcat(eqsD, [ESM_AOM.Equation(_op("D", _v("C"); wrt = "t"),
                                            aggM(_idx("hz", _v("i"))))])
        icsC = copy(icsD)
        for j in 1:M
            icsC["C[$j]"] = 0.0
        end
        fC!, u0C, pC, _, vmC, dC2 = ESM_AOM._build_evaluator_impl(
            ESM_AOM.Model(varsC, eqsC); index_sets = isetsM, initial_conditions = icsC)
        duC = similar(u0C); fC!(duC, u0C, pC, 0.0)
        Cv = [duC[vmC["C[$j]"]] for j in 1:M]
        Bv = [duC[vmC["B[$j]"]] for j in 1:M]
        @test Cv == Bv                     # same operator, same field, same numbers
        @test !all(iszero, Cv)
    end

    # ---- Const-weight contraction: the regrid shape (differential) ----
    # `g[j] = Σ_i W[i,j]·c[i]` over const `W`/`c` — the in-model conservative
    # regrid of the §5.10 refresh fixture. Pins the FILL against the inline
    # oracle: a lane whose const VALUES coincide at the box corners but differ
    # inside (`W[3, j]` is 0, 0.5, 0 across j = 1..3) must not fold to a
    # literal. See `_materialized_fill_equation` for why the fill is spelled as
    # a gather rather than handed the bare aggregate.
    @testset "const-weight contraction ≡ the inlining build" begin
        Wm = [0.5 0.0 0.0; 0.5 0.0 0.0; 0.0 0.5 0.0;
              0.0 0.5 0.0; 0.0 0.0 0.5; 0.0 0.0 0.5]
        src = [0.0, 2.0, 1.0, 3.0, 2.0, 4.0]
        gdef = ESM_AOM.OpExpr("aggregate", ESM_AOM.ASTExpr[];
            semiring = "sum_product", output_idx = Any["j"],
            ranges = Dict("i" => [1, 6], "j" => [1, 3]),
            expr_body = _op("*", _idx("W", _v("i"), _v("j")), _idx("src", _v("i"))))
        aggJ(body) = ESM_AOM.OpExpr("aggregate", ESM_AOM.ASTExpr[];
            output_idx = Any["j"], ranges = Dict("j" => [1, 3]), expr_body = body)
        mR = ESM_AOM.Model(
            Dict("c" => ESM_AOM.ModelVariable(ESM_AOM.StateVariable; shape = ["tgt"]),
                 "g" => ESM_AOM.ModelVariable(ESM_AOM.ObservedVariable;
                                              shape = ["tgt"], expression = gdef)),
            [ESM_AOM.Equation(aggJ(_Didx("c", _v("j"))), aggJ(_idx("g", _v("j"))))])
        kw = (; index_sets = Dict("tgt" => ESM_AOM.IndexSet("interval"; size = 3)),
                initial_conditions = Dict("c[$j]" => 0.0 for j in 1:3),
                const_arrays = Dict("W" => Wm, "src" => src))
        fac, inl = _aom_build_both(mR; kw...)
        @test fac[6].n_mat_array_obs == 1
        du_f = _aom_du(fac, fac[2])
        du_i = _aom_du(inl, inl[2])
        @test du_f == du_i
        @test [du_f[fac[5]["c[$j]"]] for j in 1:3] == vec(sum(Wm .* src; dims = 1))
    end
end
