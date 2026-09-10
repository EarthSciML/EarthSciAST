# Regression tests for issue #232 — an ARRAY-shaped observed defined by the
# INDEXED LHS spelling.
#
# esm-spec §6.3.1 admits TWO LHS spellings for the equation that DEFINES an
# unknown: bare (`y ~ f(…)`) and indexed (`y[i] ~ f(…)`, "which defines the whole
# array `y`"). Both are normative and neither is restricted by rank — the spec is
# explicit that the defining form is read through the LHS's BASE NAME, so "an
# arrayed definition is observed exactly as its scalar counterpart is".
#
# Every owner-bucket collector in the tree-walk build nonetheless tested the
# SYNTACTIC `eq.lhs isa VarExpr`, so an ARRAY-shaped observed written the indexed
# way landed in none of them (not the WS4 elementwise fold, not
# `_collect_array_inline_vars`, not the bare-alias path, not clip-ring discovery)
# and fell through to `_partition_variables`' geometry-ring gate as
# `E_TREEWALK_UNSUPPORTED_SHAPE: w`. `_normalize_indexed_observed_lhs`
# (tree_walk/build_helpers.jl) now rewrites the spelling into the bare form ONCE,
# upstream of every classifier.
#
# The three spellings of the SAME observed `w[k] = 2·u[k]` are built here and
# must agree BIT-FOR-BIT, at build products and at `du`:
#
#   bare      `w ~ aggregate{k}(2·u[k])`                  (already worked)
#   indexed   `aggregate{k}(w[k]) ~ aggregate{k}(2·u[k])` (whole-array rhs)
#   per-cell  `aggregate{k}(w[k]) ~ 2·u[k]`               (rhs is a cell body)
#
# The normalizer's own recognition boundary is pinned below it: a derivative LHS,
# a contracting/gating shell, a non-identity gather, and a rank mismatch are all
# left exactly as authored.
using Test
using EarthSciAST

include("testutils.jl")

const ESM_IOL = EarthSciAST

@testset "indexed LHS for an array-shaped observed (#232)" begin

    N = 4
    isets = Dict("lev" => ESM_IOL.IndexSet("interval"; size = N))
    _iol_rng() = Dict{String,Any}("k" => ESM_IOL.IndexSetRef("lev"))
    _iol_agg(body; kw...) = ESM_IOL.OpExpr("aggregate", ESM_IOL.ASTExpr[];
                                           output_idx = Any["k"],
                                           ranges = _iol_rng(),
                                           expr_body = body, kw...)
    _iol_vars() = Dict(
        "u" => ESM_IOL.ModelVariable(ESM_IOL.UnknownVariable; shape = ["lev"]),
        "w" => ESM_IOL.ModelVariable(ESM_IOL.UnknownVariable; shape = ["lev"]),
    )
    # The observed's per-cell body, `2·u[k]`, and the state equation that reads
    # it — `D(u[k]) = w[k]` — shared by all three spellings.
    _iol_body() = _op("*", _n(2.0), _idx("u", _v("k")))
    _iol_deriv() = ESM_IOL.Equation(_iol_agg(_Didx("u", _v("k"))),
                                    _iol_agg(_idx("w", _v("k"))))

    bare_eq     = () -> ESM_IOL.Equation(_v("w"), _iol_agg(_iol_body()))
    indexed_eq  = () -> ESM_IOL.Equation(_iol_agg(_idx("w", _v("k"))),
                                         _iol_agg(_iol_body()))
    percell_eq  = () -> ESM_IOL.Equation(_iol_agg(_idx("w", _v("k"))), _iol_body())

    ics = Dict("u[$j]" => Float64(j) for j in 1:N)
    _iol_build(eq) = ESM_IOL._build_evaluator_impl(
        ESM_IOL.Model(_iol_vars(), [eq(), _iol_deriv()]);
        index_sets = isets, initial_conditions = ics)
    _iol_du(built, u) = (du = similar(u); built[1](du, u, built[3], 0.0); du)

    @testset "all three spellings build and agree" begin
        bare    = _iol_build(bare_eq)
        indexed = _iol_build(indexed_eq)      # threw E_TREEWALK_UNSUPPORTED_SHAPE
        percell = _iol_build(percell_eq)      # threw E_TREEWALK_UNSUPPORTED_SHAPE

        u0 = bare[2]
        @test length(u0) == N                 # `w` carries NO ode slot in any of them
        @test indexed[2] == u0
        @test percell[2] == u0
        @test indexed[5] == bare[5]           # identical public var_map
        @test percell[5] == bare[5]

        for probe in (u0, fill(1.0, N), collect(range(-3.0, 3.0; length = N)))
            want = 2.0 .* probe               # D(u[k]) = w[k] = 2·u[k]
            @test _iol_du(bare, probe) == want
            @test _iol_du(indexed, probe) == want
            @test _iol_du(percell, probe) == want
        end
    end

    @testset "the rewrite normalizes to exactly the bare spelling" begin
        model = ESM_IOL.Model(_iol_vars(), [indexed_eq(), _iol_deriv()])
        out = ESM_IOL._normalize_indexed_observed_lhs(model.equations, model)
        @test length(out) == 2
        @test out[1].lhs isa ESM_IOL.VarExpr
        @test (out[1].lhs::ESM_IOL.VarExpr).name == "w"
        # The rhs was ALREADY the whole array, so the shell simply dropped —
        # the same node, by identity, not a re-wrapped copy.
        @test out[1].rhs === model.equations[1].rhs
        # The derivative equation is not a definition; it is untouched by identity.
        @test out[2] === model.equations[2]

        # A per-cell rhs is wrapped in the LHS's own frame instead.
        pmodel = ESM_IOL.Model(_iol_vars(), [percell_eq(), _iol_deriv()])
        pout = ESM_IOL._normalize_indexed_observed_lhs(pmodel.equations, pmodel)
        @test (pout[1].lhs::ESM_IOL.VarExpr).name == "w"
        wrapped = pout[1].rhs
        @test wrapped isa ESM_IOL.OpExpr
        @test (wrapped::ESM_IOL.OpExpr).op == "aggregate"
        @test (wrapped::ESM_IOL.OpExpr).output_idx == Any["k"]
        @test collect(keys((wrapped::ESM_IOL.OpExpr).ranges)) == ["k"]
        @test (wrapped::ESM_IOL.OpExpr).expr_body === pmodel.equations[1].rhs
    end

    @testset "the recognition boundary holds" begin
        # Each of these is NOT the indexed-observed spelling, so the equations
        # vector comes back by IDENTITY — nothing was rewritten.
        untouched(eqs) = begin
            m = ESM_IOL.Model(_iol_vars(), eqs)
            ESM_IOL._normalize_indexed_observed_lhs(m.equations, m) === m.equations
        end

        # A shell that GATES is computing, not addressing.
        @test untouched([ESM_IOL.Equation(
            _iol_agg(_idx("w", _v("k")); filter = _op(">", _v("k"), _i(1))),
            _iol_agg(_iol_body())), _iol_deriv()])
        # A non-identity gather writes somewhere else.
        @test untouched([ESM_IOL.Equation(
            _iol_agg(_idx("w", _op("+", _v("k"), _i(1)))),
            _iol_agg(_iol_body())), _iol_deriv()])
        # A SCALAR reduction (empty `output_idx`) is no frame at all.
        @test untouched([ESM_IOL.Equation(
            ESM_IOL.OpExpr("aggregate", ESM_IOL.ASTExpr[];
                           output_idx = Any[], ranges = _iol_rng(),
                           expr_body = _idx("w", _v("k"))),
            _iol_agg(_iol_body())), _iol_deriv()])
        # `w` is an ODE STATE here (it carries its own `D`), not an observed.
        @test untouched([ESM_IOL.Equation(_iol_agg(_idx("w", _v("k"))),
                                          _iol_agg(_iol_body())),
                         ESM_IOL.Equation(_iol_agg(_Didx("w", _v("k"))),
                                          _iol_agg(_idx("u", _v("k")))),
                         _iol_deriv()])
        # Rank mismatch: a rank-1 frame does not define a rank-2 variable.
        let vars = Dict(
                "u" => ESM_IOL.ModelVariable(ESM_IOL.UnknownVariable; shape = ["lev"]),
                "w" => ESM_IOL.ModelVariable(ESM_IOL.UnknownVariable;
                                             shape = ["lev", "lev"]))
            m = ESM_IOL.Model(vars, [ESM_IOL.Equation(_iol_agg(_idx("w", _v("k"))),
                                                      _iol_agg(_iol_body())),
                                     _iol_deriv()])
            @test ESM_IOL._normalize_indexed_observed_lhs(m.equations, m) === m.equations
        end
    end
end
