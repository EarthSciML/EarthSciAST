# Tests for the semiring-parameterized FAQ evaluator changes (ess-my4.1.2):
#   (a) semiring parameterization of _combine_with_reducer / _NK_CONTRACTION,
#       with the §5.1 normative empty-reduction identities (0̄);
#   (b) op:aggregate accepted identically to op:arrayop (§5.6);
#   (c) ranges[*] {from, of} resolved against the document index_sets registry —
#       interval / categorical / ragged — with a clear error on an undeclared
#       name (§5.2);
#   (d) const_arrays / tables treated uniformly as keyed factors (§5.4).
#
# RFC: docs/content/rfcs/semiring-faq-unified-ir.md.

using Test
using EarthSciAST

const ESM = EarthSciAST
include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _SR_REPO_ROOT = TESTUTILS_REPO_ROOT

@testset "tree_walk semiring + index-set registry + aggregate (ess-my4.1.2)" begin
    # Helpers (scoped local to this testset so they don't clobber siblings).
    _n(x)   = NumExpr(Float64(x))
    _i(x)   = IntExpr(Int64(x))
    _v(n)   = VarExpr(String(n))
    _op(op, args...; kw...) = OpExpr(String(op), ESM.ASTExpr[args...]; kw...)
    _idx(var, ix...)  = _op("index", _v(var), ix...)
    _D_idx(var, ix...) = _op("D", _idx(var, ix...); wrt="t")

    # ------------------------------------------------------------------
    # (a) Semiring registry — (⊕, 0̄) resolution. ⊗ and identities come from
    #     the table, never the file; `reduce` names ⊕ only (§5.1).
    # ------------------------------------------------------------------
    @testset "(a) semiring registry resolution" begin
        @test ESM._aggregate_oplus_identity("sum_product", nothing) == ("+",   0.0)
        @test ESM._aggregate_oplus_identity("max_product", nothing) == ("max", -Inf)
        @test ESM._aggregate_oplus_identity("min_sum",     nothing) == ("min",  Inf)
        @test ESM._aggregate_oplus_identity("max_sum",     nothing) == ("max", -Inf)
        # Legacy reduce-only shorthand → same ⊕/0̄ (back-compat, §5.1 note 1).
        @test ESM._aggregate_oplus_identity(nothing, "+")   == ("+",   0.0)
        @test ESM._aggregate_oplus_identity(nothing, "max") == ("max", -Inf)
        @test ESM._aggregate_oplus_identity(nothing, "min") == ("min",  Inf)
        @test ESM._aggregate_oplus_identity(nothing, "*")   == ("*",   1.0)
        @test ESM._aggregate_oplus_identity(nothing, nothing) == ("+",  0.0)
        # `semiring` supersedes `reduce` when both are present.
        @test ESM._aggregate_oplus_identity("min_sum", "+") == ("min", Inf)
        # Unregistered semiring → clear error (closed registry, §5.1).
        @test_throws ESM.TreeWalkError ESM._aggregate_oplus_identity("tropical_max", nothing)
    end

    # ------------------------------------------------------------------
    # (a) Empty-reduction identities (0̄) — the build-time combiner returns the
    #     semiring's 0̄ for an empty ⊕-reduction (§5.1).
    # ------------------------------------------------------------------
    @testset "(a) empty-reduction identity element" begin
        empty = ESM.ASTExpr[]
        @test ESM._combine_with_reducer("+",   0.0,  empty) isa NumExpr
        @test (ESM._combine_with_reducer("+",   0.0,  empty)).value == 0.0
        @test (ESM._combine_with_reducer("max", -Inf, empty)).value == -Inf
        @test (ESM._combine_with_reducer("min",  Inf, empty)).value ==  Inf
        @test (ESM._combine_with_reducer("*",    1.0, empty)).value ==  1.0
        # bool_and_or (⊕=or) is index-set-producing (§5.5) — out of M1 scope.
        @test_throws ESM.TreeWalkError ESM._combine_with_reducer("or", 0.0, ESM.ASTExpr[_n(1.0), _n(0.0)])
    end

    # ------------------------------------------------------------------
    # (a) End-to-end empty reduction through build_evaluator: a scalar aggregate
    #     over an empty contraction range evaluates to the semiring's 0̄.
    # ------------------------------------------------------------------
    @testset "(a) e2e empty scalar aggregate → 0̄" begin
        for (sr, expected) in (("sum_product", 0.0), ("min_sum", Inf),
                               ("max_product", -Inf), ("max_sum", -Inf))
            vars = Dict("z" => ModelVariable(StateVariable))
            # D(z) = aggregate_{k ∈ [1,0]} 1   (empty range ⇒ 0̄)
            rhs = OpExpr("aggregate", ESM.ASTExpr[];
                output_idx=Any[], semiring=sr, expr_body=_n(1.0),
                ranges=Dict("k" => Any[1, 0]))
            model = ESM.Model(vars, [ESM.Equation(_op("D", _v("z"); wrt="t"), rhs)])
            f!, u0, p, _, vmap = build_evaluator(model)
            du = similar(u0); f!(du, u0, p, 0.0)
            @test du[vmap["z"]] == expected
        end
    end

    # ------------------------------------------------------------------
    # (a) Non-empty min/max aggregate evaluates with the right ⊕ (tropical etc.).
    # ------------------------------------------------------------------
    @testset "(a) non-empty min_sum / max_product reductions" begin
        # D(z) = min_{j ∈ 1:5} x[j];  D(w) = max_{j ∈ 1:5} x[j]
        vars = Dict("x" => ModelVariable(StateVariable),
                    "z" => ModelVariable(StateVariable),
                    "w" => ModelVariable(StateVariable))
        agg_min = OpExpr("aggregate", ESM.ASTExpr[];
            output_idx=Any[], semiring="min_sum",
            expr_body=_idx("x", _v("j")), ranges=Dict("j" => Any[1, 5]))
        agg_max = OpExpr("aggregate", ESM.ASTExpr[];
            output_idx=Any[], semiring="max_product",
            expr_body=_idx("x", _v("j")), ranges=Dict("j" => Any[1, 5]))
        eqs = [ESM.Equation(_op("D", _v("z"); wrt="t"), agg_min),
               ESM.Equation(_op("D", _v("w"); wrt="t"), agg_max)]
        model = ESM.Model(vars, eqs)
        ics = Dict("x[1]"=>3.0, "x[2]"=>1.0, "x[3]"=>5.0, "x[4]"=>2.0, "x[5]"=>4.0)
        f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["z"]] == 1.0   # min
        @test du[vmap["w"]] == 5.0   # max
    end

    # ------------------------------------------------------------------
    # (b) op:aggregate is dispatched identically to op:arrayop (§5.6).
    # ------------------------------------------------------------------
    @testset "(b) aggregate alias ≡ arrayop" begin
        N = 4
        vars = Dict("u" => ModelVariable(StateVariable))
        ics = Dict("u[$i]" => Float64(i) for i in 1:N)
        mk(tag) = ESM.Model(vars, [ESM.Equation(
            OpExpr(tag, ESM.ASTExpr[]; output_idx=Any["i"],
                   expr_body=_D_idx("u", _v("i")), ranges=Dict("i" => Any[1, N])),
            OpExpr(tag, ESM.ASTExpr[]; output_idx=Any["i"], reduce="+",
                   expr_body=_op("-", _idx("u", _v("i"))), ranges=Dict("i" => Any[1, N])))])
        fa!, ua, pa, _, va = build_evaluator(mk("arrayop");   initial_conditions=ics)
        fb!, ub, pb, _, vb = build_evaluator(mk("aggregate"); initial_conditions=ics)
        dua = similar(ua); fa!(dua, ua, pa, 0.0)
        dub = similar(ub); fb!(dub, ub, pb, 0.0)
        @test va == vb
        @test dua == dub
        for i in 1:N
            @test dub[vb["u[$i]"]] == -Float64(i)
        end
    end

    # ------------------------------------------------------------------
    # (c) Index-set registry — interval `{from}` → dense bound [1, size].
    # ------------------------------------------------------------------
    @testset "(c) interval index set resolution" begin
        N = 5
        vars = Dict("u" => ModelVariable(StateVariable),
                    "total" => ModelVariable(StateVariable))
        index_sets = Dict("cells" => ESM.IndexSet("interval"; size=N))
        eqs = [
            # D(u[i]) = -u[i]  for i ∈ cells
            ESM.Equation(
                OpExpr("aggregate", ESM.ASTExpr[]; output_idx=Any["i"],
                       expr_body=_D_idx("u", _v("i")),
                       ranges=Dict("i" => ESM.IndexSetRef("cells"))),
                OpExpr("aggregate", ESM.ASTExpr[]; output_idx=Any["i"], semiring="sum_product",
                       expr_body=_op("-", _idx("u", _v("i"))),
                       ranges=Dict("i" => ESM.IndexSetRef("cells")))),
            # D(total) = Σ_{i ∈ cells} u[i]
            ESM.Equation(_op("D", _v("total"); wrt="t"),
                OpExpr("aggregate", ESM.ASTExpr[]; output_idx=Any[], semiring="sum_product",
                       expr_body=_idx("u", _v("i")),
                       ranges=Dict("i" => ESM.IndexSetRef("cells")))),
        ]
        model = ESM.Model(vars, eqs)
        ics = Dict("u[$i]" => Float64(i) for i in 1:N)
        f!, u0, p, _, vmap = build_evaluator(model; index_sets=index_sets,
                                             initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        for i in 1:N
            @test du[vmap["u[$i]"]] == -Float64(i)
        end
        @test du[vmap["total"]] == sum(1.0:N)   # 15
    end

    # ------------------------------------------------------------------
    # (c)+(d) Categorical `{from}` → [1, |members|]; a `tables` factor keyed by
    #         the categorical index is just a const_array (keyed factor, §5.4).
    # ------------------------------------------------------------------
    @testset "(c)+(d) categorical index set + keyed-factor table" begin
        vars = Dict("total" => ModelVariable(StateVariable))
        index_sets = Dict("county" =>
            ESM.IndexSet("categorical"; members=["Champaign", "Cook", "Sangamon"]))
        # D(total) = Σ_{c ∈ county} pop[c]   (pop is a categorical-keyed table)
        eq = ESM.Equation(_op("D", _v("total"); wrt="t"),
            OpExpr("aggregate", ESM.ASTExpr[]; output_idx=Any[], semiring="sum_product",
                   expr_body=_idx("pop", _v("c")),
                   ranges=Dict("c" => ESM.IndexSetRef("county"))))
        model = ESM.Model(vars, [eq])
        f!, u0, p, _, vmap = build_evaluator(model; index_sets=index_sets,
            const_arrays=Dict("pop" => [10.0, 20.0, 30.0]))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["total"]] == 60.0
    end

    # ------------------------------------------------------------------
    # (c) Ragged `{from, of}` → per-cell dynamic bound [1, index(offsets, of…)],
    #     i.e. exactly the existing variable-valence reduction (§5.2). Verify it
    #     matches the explicit-dynamic-bound form bit-for-bit.
    # ------------------------------------------------------------------
    @testset "(c) ragged index set ≡ explicit dynamic bound" begin
        N_c = 4
        cells_on_cell = [2.0 0.0; 1.0 3.0; 2.0 4.0; 3.0 0.0]
        coeff         = [1.0 0.0; 1.0 1.0; 1.0 1.0; 1.0 0.0]
        n_edges       = [1.0, 2.0, 2.0, 1.0]
        carrs = Dict("cells_on_cell" => cells_on_cell, "coeff" => coeff,
                     "n_edges_on_cell" => n_edges)
        vars = Dict("u" => ModelVariable(StateVariable))
        _c = _v("c"); _k = _v("k")
        body = _op("*", _op("index", _v("coeff"), _c, _k),
                   _op("-", _op("index", _v("u"), _op("index", _v("cells_on_cell"), _c, _k)),
                            _idx("u", _c)))
        lhs = OpExpr("aggregate", ESM.ASTExpr[]; output_idx=Any["c"],
                     expr_body=_D_idx("u", _c), ranges=Dict("c" => Any[1, N_c]))
        # Registry form: k ∈ {from: edges_of_cell, of: [c]}.
        index_sets = Dict("edges_of_cell" => ESM.IndexSet("ragged";
            of=["cells"], offsets="n_edges_on_cell", values="cells_on_cell"))
        rhs_reg = OpExpr("aggregate", ESM.ASTExpr[]; output_idx=Any["c"], reduce="+",
            ranges=Dict("c" => Any[1, N_c], "k" => ESM.IndexSetRef("edges_of_cell"; of=["c"])),
            expr_body=body)
        model_reg = ESM.Model(vars, [ESM.Equation(lhs, rhs_reg)])
        # Explicit form: k ∈ [1, index(n_edges_on_cell, c)].
        rhs_exp = OpExpr("aggregate", ESM.ASTExpr[]; output_idx=Any["c"], reduce="+",
            ranges=Dict("c" => Any[1, N_c],
                        "k" => Any[1, _op("index", _v("n_edges_on_cell"), _c)]),
            expr_body=body)
        model_exp = ESM.Model(vars, [ESM.Equation(lhs, rhs_exp)])

        ics = Dict("u[$c]" => 0.0 for c in 1:N_c)
        fr!, ur, pr, _, vr = build_evaluator(model_reg; index_sets=index_sets,
                                             initial_conditions=ics, const_arrays=carrs)
        fe!, ue, pe, _, ve = build_evaluator(model_exp; initial_conditions=ics, const_arrays=carrs)
        u = copy(ur); u[vr["u[2]"]] = 1.0
        dur = similar(ur); fr!(dur, u, pr, 0.0)
        ue2 = copy(ue); ue2[ve["u[2]"]] = 1.0
        due = similar(ue); fe!(due, ue2, pe, 0.0)
        @test dur == due
        @test isapprox(dur[vr["u[1]"]],  1.0; atol=1e-12)
        @test isapprox(dur[vr["u[2]"]], -2.0; atol=1e-12)
        @test isapprox(dur[vr["u[3]"]],  1.0; atol=1e-12)
        @test isapprox(dur[vr["u[4]"]],  0.0; atol=1e-12)
    end

    # ------------------------------------------------------------------
    # (c) Undeclared `{from}` name → clear error (no implicit interval, §5.2).
    # ------------------------------------------------------------------
    @testset "(c) undeclared index set errors" begin
        vars = Dict("u" => ModelVariable(StateVariable),
                    "total" => ModelVariable(StateVariable))
        eq = ESM.Equation(_op("D", _v("total"); wrt="t"),
            OpExpr("aggregate", ESM.ASTExpr[]; output_idx=Any[], semiring="sum_product",
                   expr_body=_idx("u", _v("i")),
                   ranges=Dict("i" => ESM.IndexSetRef("not_declared"))))
        # No registry at all.
        model0 = ESM.Model(vars, [eq])
        @test_throws ESM.TreeWalkError build_evaluator(model0)
        # Registry present but missing the referenced name.
        model1 = ESM.Model(vars, [eq])
        err = try
            build_evaluator(model1;
                index_sets=Dict("cells" => ESM.IndexSet("interval"; size=3)))
            nothing
        catch e; e; end
        @test err isa ESM.TreeWalkError
        @test occursin("not_declared", sprint(showerror, err))
    end

    # ------------------------------------------------------------------
    # Round-trip: semiring / index_sets / {from} ranges survive parse↔serialize.
    # ------------------------------------------------------------------
    @testset "round-trip semiring + index_sets + {from} ranges" begin
        agg = OpExpr("aggregate", ESM.ASTExpr[]; output_idx=Any[], semiring="min_sum",
                     expr_body=_idx("u", _v("i")),
                     ranges=Dict("i" => ESM.IndexSetRef("cells"; of=String[])))
        j = ESM.serialize_expression(agg)
        @test j["op"] == "aggregate"
        @test j["semiring"] == "min_sum"
        @test j["ranges"]["i"]["from"] == "cells"
        rt = ESM.parse_expression(j)
        @test rt.op == "aggregate"
        @test rt.semiring == "min_sum"
        @test rt.ranges["i"] isa ESM.IndexSetRef
        @test rt.ranges["i"].from == "cells"

        is = ESM.IndexSet("ragged"; of=["cells"], offsets="noc", values="eoc")
        jd = ESM.serialize_index_set(is)
        @test jd["kind"] == "ragged"
        @test jd["offsets"] == "noc"
        rtis = ESM.coerce_index_set(jd)
        @test rtis.kind == "ragged"
        @test rtis.values == "eoc"
    end

    # ------------------------------------------------------------------
    # Integration: the shared conformance fixture loads, parses, and evaluates.
    # ------------------------------------------------------------------
    @testset "valid fixture aggregate_semiring_indexset.esm evaluates" begin
        path = joinpath(_SR_REPO_ROOT, "tests", "valid", "aggregate",
                        "aggregate_semiring_indexset.esm")
        if isfile(path)
            file = EarthSciAST.load(path)
            ics = Dict("u[$i]" => Float64(i) for i in 1:5)
            f!, u0, p, _, vmap = build_evaluator(file; model_name="AggregateDemo",
                                                 initial_conditions=ics)
            du = similar(u0); f!(du, u0, p, 0.0)
            for i in 1:5
                @test du[vmap["u[$i]"]] == -Float64(i)
            end
            @test du[vmap["total"]] == 15.0
        else
            @warn "fixture not found; skipping" path
        end
    end
end
