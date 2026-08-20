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
        "u" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
        "g" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
        "h" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
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
            "u" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
            "g" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
            "w" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
            "s" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable),
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
            "u" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
            "A" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
            "B" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
            # `w` is a bit-exact copy of `u` (esm 1.0.0: defined by the
            # bare-variable-LHS equation below, not by a `expression` field)
            "w" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
        )
        eqsD = [
            ESM_AOM.Equation(_v("w"), aggM(_idx("u", _v("i")))),
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
        varsC["hz"] = ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"])
        varsC["C"] = ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"])
        eqsC = vcat(eqsD, [ESM_AOM.Equation(_v("hz"), lowered_D("u")),
                           ESM_AOM.Equation(_op("D", _v("C"); wrt = "t"),
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
    # inside (`W[3, j]` is 0, 0.5, 0 across j = 1..3) must not fold to a literal.
    #
    # This IS the adversarial column that the old value-sampling fold in
    # `_derive_lane_repl` silently zeroed, and the reason the fill used to be
    # withheld from the bare-aggregate path. That fold now derives invariance
    # STRUCTURALLY from the resolved linear index, so `_unwrap_identity_gather`
    # hands this contracting producer over bare — which makes this testset the
    # live guard on that derivation rather than a test of an avoided path.
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
            Dict("c" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["tgt"]),
                 "g" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["tgt"])),
            # esm 1.0.0: `g`'s contraction body is its defining equation.
            [ESM_AOM.Equation(_v("g"), gdef),
             ESM_AOM.Equation(aggJ(_Didx("c", _v("j"))), aggJ(_idx("g", _v("j"))))])
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

    # ---- A materialized observed that CONTRACTS reaches the affine tier ----
    # `_materialized_fill_equation` synthesizes the fill as `index(<def>, i…)`,
    # and `_compile_arrayop_equation!` detects a contraction by testing
    # `rhs.op == "aggregate"` — so under the gather form it saw `index`, left
    # `contract_names` empty, and skipped EVERY contraction tier. The affine
    # build was then handed `index(<contracting aggregate>, i…)`, which it cannot
    # model ("index(aggregate) with contracted index"), so the equation dropped
    # to the per-cell tier: one kernel per output cell, O(#cells) IR, for a shape
    # whose kernel is grid-independent. `_unwrap_identity_gather` lifts the
    # wrapper whenever the producer contracts.
    #
    # ReSEACT's `Transport3D.divh_col` / `dp_col` are exactly this shape — column
    # sums over `lev` feeding a [lon, lat] field — and were the last two
    # `:percell_acc` equations in that build.
    @testset "a CONTRACTING materialized observed reaches the affine tier" begin
        Nx, Ny = 6, 4
        isetsC = Dict("x" => ESM_AOM.IndexSet("interval"; size = Nx),
                      "y" => ESM_AOM.IndexSet("interval"; size = Ny))
        # s[i] = Σ_j u[i,j] — `j` is contracted (in `ranges`, not `output_idx`).
        colsum = ESM_AOM.OpExpr("aggregate", ESM_AOM.ASTExpr[];
            output_idx = Any["i"], reduce = "+",
            ranges = Dict("i" => ESM_AOM.IndexSetRef("x"),
                          "j" => ESM_AOM.IndexSetRef("y")),
            expr_body = _idx("u", _v("i"), _v("j")))
        agg2(body) = ESM_AOM.OpExpr("arrayop", ESM_AOM.ASTExpr[];
            output_idx = Any["i", "j"],
            ranges = Dict("i" => ESM_AOM.IndexSetRef("x"),
                          "j" => ESM_AOM.IndexSetRef("y")),
            expr_body = body)
        mC = ESM_AOM.Model(
            Dict("u" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x", "y"]),
                 "s" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
                 "k" => ESM_AOM.ModelVariable(ESM_AOM.ParameterVariable; default = 0.5)),
            [ESM_AOM.Equation(_v("s"), colsum),
             ESM_AOM.Equation(agg2(_Didx("u", _v("i"), _v("j"))),
                              agg2(_op("*", _v("k"), _idx("s", _v("i")))))])
        icsC = Dict("u[$i,$j]" => Float64(10i + j) for i in 1:Nx, j in 1:Ny)
        kwC = (; index_sets = isetsC, initial_conditions = icsC)

        ESM_AOM._reset_cascade_tally!()
        facC = ESM_AOM._build_evaluator_impl(mC; kwC...)
        tally = copy(ESM_AOM._CASCADE_TALLY)
        @test facC[6].n_mat_array_obs == 1              # `s` IS materialized
        # The point of the unwrap: nothing lands on the per-cell tier.
        @test get(tally, :percell_acc, 0) == 0
        @test get(tally, :affine, 0) >= 2               # the fill AND D(u)

        # Differential: bit-identical to the inlining oracle and to the per-cell
        # reference, which never sees the unwrap at all.
        inlC = withenv("ESS_ARRAY_OBS_INLINE" => "1") do
            ESM_AOM._build_evaluator_impl(mC; kwC...)
        end
        pcC = withenv("ESS_STENCIL_DISABLE" => "1") do
            ESM_AOM._build_evaluator_impl(mC; kwC...)
        end
        u0 = facC[2]
        for probe in (u0, fill(1.0, length(u0)),
                      collect(range(-3.0, 3.0; length = length(u0))))
            @test _aom_du(facC, probe) == _aom_du(inlC, probe)
            @test _aom_du(facC, probe) == _aom_du(pcC, probe)
        end

        # ...and the hand-computed value: D(u)[i,j] = k · Σ_j' u[i,j'].
        du = _aom_du(facC, u0)
        for i in 1:Nx
            rowsum = sum(Float64(10i + j) for j in 1:Ny)
            for j in 1:Ny
                @test du[facC[5]["u[$i,$j]"]] == 0.5 * rowsum
            end
        end
    end

    # ---- Intersection with the O(N) prefix scan (ess-scan, scan.jl) ----
    # These two mechanisms meet in `_build_compile_evaluator`: the scan rewrite
    # widened `_compile_derivative_equations`' return and `_make_rhs`' argument
    # list, and the fills WRAP the state RHS. A merge that dropped either side
    # compiles and runs, so pin both from the outside:
    #
    #   * a STATE equation that is itself a forward prefix reduction still takes
    #     the O(N) accumulation (`n_scan_folds`, cascade `:scan`) in a model that
    #     ALSO factors an array observed — i.e. the fold survives being wrapped;
    #   * and its values are bit-identical to the inlining oracle, so the fold
    #     is reading back terms the kernels wrote into the SAME `du` (it runs
    #     inside the wrapped state RHS, not over the extended vector).
    #
    # The scanned body reads the factored observed `g`, so the fold's terms come
    # through a buffer gather — the two mechanisms are genuinely composed here,
    # not merely co-present.
    @testset "prefix scan over a factored observed ≡ the inlining build" begin
        Ns = 12
        isetsS = Dict("x" => ESM_AOM.IndexSet("interval"; size = Ns))
        aggS(body) = ESM_AOM.OpExpr("aggregate", ESM_AOM.ASTExpr[];
            output_idx = Any["i"], ranges = Dict("i" => Any[1, Ns]),
            expr_body = body)
        # c is a state whose RHS is Σ_{j<=i} g[j], and g is a factored observed.
        scan_rhs = ESM_AOM.OpExpr("arrayop", ESM_AOM.ASTExpr[];
            output_idx = Any["i"], reduce = "+",
            ranges = Dict("i" => Any[1, Ns], "j" => Any[1, Ns]),
            filter = _op("<=", _v("j"), _v("i")),
            expr_body = _idx("g", _v("j")))
        mS = ESM_AOM.Model(
            Dict("u" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
                 "c" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
                 "g" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"])),
            [ESM_AOM.Equation(_v("g"), aggS(_op("*", _n(2.0), _idx("u", _v("i"))))),
             ESM_AOM.Equation(aggS(_Didx("c", _v("i"))), scan_rhs),
             ESM_AOM.Equation(aggS(_Didx("u", _v("i"))), aggS(_n(0.0)))])
        icsS = merge(Dict("u[$j]" => Float64(j) for j in 1:Ns),
                     Dict("c[$j]" => 0.0 for j in 1:Ns))
        facS, inlS = _aom_build_both(mS; index_sets = isetsS,
                                     initial_conditions = icsS)
        @test facS[6].n_mat_array_obs == 1        # g is factored
        @test facS[6].n_scan_folds == 1           # ...and the scan STILL fires
        @test inlS[6].n_mat_array_obs == 0
        @test inlS[6].n_scan_folds == 1
        for probe in (facS[2], fill(1.0, length(facS[2])),
                      collect(range(-3.0, 3.0; length = length(facS[2]))))
            @test _aom_du(facS, probe) == _aom_du(inlS, probe)
        end
        # g[j] = 2u[j], so D(c)[i] is 2·(the i-th triangular number) at u[j] = j.
        du = _aom_du(facS, facS[2])
        @test [du[facS[5]["c[$i]"]] for i in 1:Ns] == 2.0 .* cumsum(1.0:Ns)
    end
end

# Capture-avoiding substitution when an array observed is INLINED.
#
# `_sub_preserving` (tree_walk/helpers.jl) used to substitute straight through a
# nested aggregate's own binders, so an inlined column sum lost its loop variable
# while `ranges` still declared it — the unroll then emitted `length(gk)`
# IDENTICAL terms and the sum degenerated to `length(gk) · body[gk = outer_k]`.
#
# The shape below is the ReSEACT PBL mixing operator reduced to its essentials:
# `gk` is CONTRACTED in `w` and an OUTPUT index in `mean`, so inlining `w` into
# `mean` puts the two binders in the same body. Materializing `w` (the default
# `:inplace` build) hides the collision behind a buffer gather, which is why the
# defect was invisible there and reached only the INLINING builds:
# `ESS_ARRAY_OBS_INLINE=1` and `form = :oop` (which never materializes).
@testset "inlined aggregate does not capture a reader's loop variable" begin
    NI, NK = 2, 4
    _agg(out, rngs, body) = Dict{String,Any}(
        "op" => "aggregate", "args" => Any[], "output_idx" => Any[out...],
        "ranges" => Dict(rngs...), "expr" => body)
    _ix(a, ks...) = Dict{String,Any}("op" => "index", "args" => Any[a, ks...])

    doc = Dict{String,Any}(
        "esm" => "1.0.0", "metadata" => Dict("name" => "agg_inline_capture"),
        "models" => Dict("R" => Dict{String,Any}(
            "variables" => Dict(
                "q"    => Dict("type" => "unknown",    "shape" => Any["gi", "gk"]),
                "w"    => Dict("type" => "unknown", "shape" => Any["gi"]),
                "mean" => Dict("type" => "unknown", "shape" => Any["gi", "gk"])),
            "equations" => Any[
                # w[gi] = Σ_gk q[gi,gk]           — `gk` CONTRACTED
                Dict("lhs" => "w",
                     "rhs" => merge(_agg(["gi"], ["gi" => Any[1, NI], "gk" => Any[1, NK]],
                                         _ix("q", "gi", "gk")),
                                    Dict("reduce" => "+"))),
                # mean[gi,gk] = w[gi] / 2         — `gk` an OUTPUT index
                Dict("lhs" => "mean",
                     "rhs" => _agg(["gi", "gk"], ["gi" => Any[1, NI], "gk" => Any[1, NK]],
                                   Dict("op" => "/", "args" => Any[_ix("w", "gi"), 2.0]))),
                Dict("lhs" => _agg(["gi", "gk"], ["gi" => Any[1, NI], "gk" => Any[1, NK]],
                                   Dict("op" => "D", "wrt" => "t",
                                        "args" => Any[_ix("q", "gi", "gk")])),
                     "rhs" => _agg(["gi", "gk"], ["gi" => Any[1, NI], "gk" => Any[1, NK]],
                                   Dict("op" => "-", "args" => Any[_ix("mean", "gi", "gk"),
                                                                   _ix("q", "gi", "gk")])))])))

    ics = Dict{String,Any}("q[$i,$k]" => Float64(10i + k) for i in 1:NI, k in 1:NK)
    # du[gi,gk] = (Σ_kk q[gi,kk])/2 − q[gi,gk]
    want(i, k) = sum(Float64(10i + kk) for kk in 1:NK) / 2 - Float64(10i + k)

    du_iip(; inline) = withenv("ESS_ARRAY_OBS_INLINE" => (inline ? "1" : nothing)) do
        f!, u0, p, _, vm = EarthSciAST.build_evaluator(doc; initial_conditions = ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        [du[vm["q[$i,$k]"]] for i in 1:NI, k in 1:NK]
    end
    fo, u0o, po, _, vmo = EarthSciAST.build_evaluator(doc; initial_conditions = ics,
                                                      form = :oop)
    duo = fo(u0o, po, 0.0)

    ref = [want(i, k) for i in 1:NI, k in 1:NK]
    @test du_iip(inline = false) == ref          # factored: was already right
    @test du_iip(inline = true)  == ref          # inlined: the capture path
    @test [duo[vmo["q[$i,$k]"]] for i in 1:NI, k in 1:NK] == ref   # :oop never materializes
end

# `:oop` materializes too, and agrees with `:inplace` bit for bit.
#
# Materialization used to be `:inplace`-only, which made INLINING mandatory under
# `:oop` — and inlining is superlinear, because a reader spliced with a reduction
# body pays that whole body per output cell. On ReSEACT the same emitter took
# 2 GiB materialized and blew past 39 GiB inlined at the smallest grid that model
# builds, so the traced build was not merely slower, it was impossible.
#
# The oracle is the one this file uses throughout: `:oop` is documented as
# emitting the same IR in the same evaluation order, so the two must agree
# EXACTLY, not approximately.
@testset ":oop materializes array observeds and matches :inplace" begin
    Ns = 6
    isetsO = Dict("x" => ESM_AOM.IndexSet("interval"; size = Ns))
    aggO(body) = ESM_AOM.OpExpr("aggregate", ESM_AOM.ASTExpr[];
        output_idx = Any["i"], ranges = Dict("i" => Any[1, Ns]), expr_body = body)
    # tot = Σ_j u[j]^2 — a genuine CONTRACTION, so inlining it into every reader
    # is exactly the blow-up this pins against. Scalar-shaped, hence read by all.
    totO = ESM_AOM.OpExpr("arrayop", ESM_AOM.ASTExpr[];
        output_idx = Any["i"], reduce = "+",
        ranges = Dict("i" => Any[1, Ns], "j" => Any[1, Ns]),
        expr_body = _op("*", _idx("u", _v("j")), _idx("u", _v("j"))))
    mO = ESM_AOM.Model(
        Dict("u" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"]),
             "g" => ESM_AOM.ModelVariable(ESM_AOM.UnknownVariable; shape = ["x"])),
        [ESM_AOM.Equation(_v("g"), totO),
         ESM_AOM.Equation(aggO(_Didx("u", _v("i"))),
                          aggO(_op("-", _idx("g", _v("i")), _idx("u", _v("i")))))])
    icsO = Dict("u[$j]" => 0.5 * j for j in 1:Ns)

    iip = ESM_AOM._build_evaluator_impl(mO; index_sets = isetsO,
                                        initial_conditions = icsO)
    oop = ESM_AOM._build_evaluator_impl(mO; index_sets = isetsO,
                                        initial_conditions = icsO, form = :oop)
    # BOTH emitters buffer the observed. Without this the value check below would
    # still pass on the inlining build it exists to rule out.
    @test iip[6].n_mat_array_obs == 1
    @test oop[6].n_mat_array_obs == 1

    du = similar(iip[2]); iip[1](du, iip[2], iip[3], 0.0)
    duo = oop[1](oop[2], oop[3], 0.0)
    want = [sum((0.5j)^2 for j in 1:Ns) - 0.5 * i for i in 1:Ns]
    @test [du[iip[5]["u[$i]"]] for i in 1:Ns] == want
    @test [duo[oop[5]["u[$i]"]] for i in 1:Ns] ==
          [du[iip[5]["u[$i]"]] for i in 1:Ns]      # bit-identical, not merely close
end
