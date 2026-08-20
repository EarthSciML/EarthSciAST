# Lane-batched scalar entries under the `:oop` emitter (ess-oop-batch).
#
# The per-cell scalar surface of the out-of-place emitter — `rhs_list` entries
# (a runtime contraction loop routes there by design) and the per-column
# `scalars` of a materialized-observed fill level — is grouped at closure build
# by structural congruence and each group evaluates ONCE as whole-array ops
# over its lane axis (`_oop_eval_batch`): one gather per state leaf, L
# whole-lane accumulate steps per contraction loop, one scatter per group. This
# is what makes a traced `:oop` program's size independent of the grid (the
# ReSEACT CONUS blocker: ~80 stablehlo.dynamic_slice PER CELL before).
#
# Pinned here:
#   * VALUES: bit-identical to (a) the unbatched `:oop` walk
#     (`ESS_OOP_BATCH=0`), (b) the in-place emitter, (c) the unrolled build
#     (`ESS_CONTRACTION_LOOP=0`) — the correctness bar `:oop` carries as the
#     in-place oracle;
#   * WITNESS: the closure's `rhs_batches` / `mat_batches` fields prove the
#     batched path ENGAGED (a silent decline back to per-cell fails the test);
#   * the pow-exponent pin (a literal exponent is part of the group key, so a
#     Dual walk keeps the power rule — groups never blend exponents);
#   * ForwardDiff through the batched path;
#   * `ESS_OOP_BATCH=0` restores the pre-feature closure (kill switch).
include("testutils.jl")

using Test
using ForwardDiff
using EarthSciAST
const _OB_ESS = EarthSciAST

# ── rhs_list: the state-source halo tent from contraction_loop_test.jl ────────
# Per output cell, ONE `_NK_CONTRACTION_LOOP` whose body reads state at a
# loop-var-dependent slot (`_NK_STATE_GATHER`) and a per-cell const weight
# (`_NK_CONST_GATHER`) — the exact shape ReSEACT's mass-weighted column
# integral lowers to. All 4 output cells are congruent ⇒ one group of 4 lanes.
function _ob_halo(M::Int; ghost::Bool=false)
    NI, NJ = 2, 2
    NQ = ghost ? M : (max(NI, NJ) + M - 1)
    W = [ [ [ [ Float64((i+2j+3k+5l) % 7) for l in 1:M ] for k in 1:M ] for j in 1:NJ ] for i in 1:NI ]
    donor(a, b) = Dict("op"=>"-","args"=>Any[Dict("op"=>"+","args"=>Any[a,b]),1])
    agg = Dict{String,Any}("op"=>"aggregate","semiring"=>"sum_product","args"=>Any[],
        "output_idx"=>Any["i","j"],
        "ranges"=>Dict("i"=>Any[1,NI],"j"=>Any[1,NJ],"k"=>Any[1,M],"l"=>Any[1,M]),
        "expr"=>Dict("op"=>"*","args"=>Any[
            Dict("op"=>"index","args"=>Any[Dict("op"=>"const","args"=>Any[],"value"=>W),"i","j","k","l"]),
            Dict("op"=>"index","args"=>Any["q", donor("i","k"), donor("j","l")])]))
    doc = Dict{String,Any}("esm"=>"0.8.0","metadata"=>Dict("name"=>"ob_halo"),
      "models"=>Dict("R"=>Dict{String,Any}(
        "variables"=>Dict("q"=>Dict("type"=>"unknown","shape"=>Any["a","b"]),
                          "out"=>Dict("type"=>"unknown","shape"=>Any["i","j"])),
        "equations"=>Any[
          Dict("lhs"=>Dict("op"=>"aggregate","args"=>Any[],"output_idx"=>Any["a","b"],
                 "ranges"=>Dict("a"=>Any[1,NQ],"b"=>Any[1,NQ]),
                 "expr"=>Dict("op"=>"D","args"=>Any[Dict("op"=>"index","args"=>Any["q","a","b"])],"wrt"=>"t")),
               "rhs"=>Dict("op"=>"aggregate","args"=>Any[],"output_idx"=>Any["a","b"],
                 "ranges"=>Dict("a"=>Any[1,NQ],"b"=>Any[1,NQ]),"expr"=>0.0)),
          Dict("lhs"=>Dict("op"=>"aggregate","args"=>Any[],"output_idx"=>Any["i","j"],
                 "ranges"=>Dict("i"=>Any[1,NI],"j"=>Any[1,NJ]),
                 "expr"=>Dict("op"=>"D","args"=>Any[Dict("op"=>"index","args"=>Any["out","i","j"])],"wrt"=>"t")),
               "rhs"=>agg)])))
    ics = Dict{String,Any}("out[1,1]"=>0.0,"out[1,2]"=>0.0,"out[2,1]"=>0.0,"out[2,2]"=>0.0)
    for a in 1:NQ, b in 1:NQ; ics["q[$a,$b]"] = Float64(10a + b); end
    (doc, ics, NI, NJ, M)
end

_ob_build(doc, ics; form=:inplace, loop=true, batch=true) =
    withenv("ESS_CONTRACTION_LOOP" => (loop ? "1" : "0"),
            "ESS_CONTRACTION_LOOP_MIN" => "8",
            "ESS_OOP_BATCH" => (batch ? "1" : "0")) do
        build_evaluator(doc; initial_conditions=ics, form=form)
    end

@testset "oop lane-batched scalars (ess-oop-batch)" begin

    @testset "rhs_list contraction loops: values + witness ($(ghost ? "ghost" : "in-bounds"))" for ghost in (false, true)
        doc, ics, NI, NJ, M = _ob_halo(8; ghost=ghost)
        f!, u0, p, _, vmi = _ob_build(doc, ics)
        di = similar(u0); f!(di, u0, p, 0.0)

        fo, u0o, po, _, vmo = _ob_build(doc, ics; form=:oop)
        duo = fo(u0o, po, 0.0)
        # (a) bit-identical to the in-place emitter (the oracle contract)
        @test all(duo[vmo["out[$i,$j]"]] == di[vmi["out[$i,$j]"]] for i in 1:NI, j in 1:NJ)
        # (b) bit-identical to the unbatched :oop closure
        fn_, u0n, pn, _, _ = _ob_build(doc, ics; form=:oop, batch=false)
        @test duo == fn_(u0n, pn, 0.0)
        # (c) bit-identical to the unrolled build (`ESS_CONTRACTION_LOOP=0`)
        fu, u0u, pu, _, vmu = _ob_build(doc, ics; form=:oop, loop=false)
        duu = fu(u0u, pu, 0.0)
        @test all(duo[vmo["out[$i,$j]"]] == duu[vmu["out[$i,$j]"]] for i in 1:NI, j in 1:NJ)

        # WITNESS: the batched path engaged — one group carrying all 4 loop
        # cells, nothing left on the per-entry path. If grouping silently
        # declined (rest non-empty, no group), this fails.
        rhs = getfield(fo, :rhs)
        @test :rhs_batches in fieldnames(typeof(rhs))
        rb = getfield(rhs, :rhs_batches)
        @test length(rb.groups) == 1
        @test rb.n_batched == NI * NJ
        @test isempty(rb.rest)
        # the group's lowered tree really carries the batched contraction loop
        @test rb.groups[1].root.kind == _OB_ESS._NK_CONTRACTION_LOOP ||
              any(c -> c.kind == _OB_ESS._NK_CONTRACTION_LOOP,
                  rb.groups[1].root.children)

        # kill switch: ESS_OOP_BATCH=0 restores the pre-feature closure
        rn = getfield(fn_, :rhs)
        @test isempty(getfield(rn, :rhs_batches).groups)
        @test getfield(rn, :rhs_batches).n_batched == 0
    end

    @testset "ForwardDiff through the batched rhs_list path" begin
        doc, ics, NI, NJ, M = _ob_halo(8)
        fo, u0, p, _, vm = _ob_build(doc, ics; form=:oop)
        fn_, u0n, pn, _, vmn = _ob_build(doc, ics; form=:oop, batch=false)
        g(f, vmap, pp) = u -> f(u, pp, 0.0)[vmap["out[1,1]"]]
        Jb = ForwardDiff.gradient(g(fo, vm, p), u0)
        Ju = ForwardDiff.gradient(g(fn_, vmn, pn), u0n)
        @test Jb == Ju
        W11(a, b) = Float64((1 + 2 + 3a + 5b) % 7)
        @test all(Jb[vm["q[$a,$b]"]] == ((1 <= a <= M && 1 <= b <= M) ? W11(a, b) : 0.0)
                  for a in 1:3, b in 1:3)
    end

    # ── Materialized-observed fills: S[i] = Σ_k W[k]·q[i,k], read by D(v[i]) ──
    # The observed's fill compiles per COLUMN into `mat_levels` scalars, each
    # carrying one contraction loop over k — the ReSEACT per-column fill shape.
    # All N columns are congruent ⇒ one group of N lanes at that level.
    @testset "materialized fill levels batch per column" begin
        N, M = 6, 12                      # M ≥ the contraction-loop floor
        W = collect(1.0:Float64(M))
        isets = Dict("x" => _OB_ESS.IndexSet("interval"; size = N),
                     "y" => _OB_ESS.IndexSet("interval"; size = M))
        vars = Dict(
            "q" => _OB_ESS.ModelVariable(_OB_ESS.UnknownVariable; shape = ["x", "y"]),
            "v" => _OB_ESS.ModelVariable(_OB_ESS.UnknownVariable; shape = ["x"]),
            # esm 1.0.0 (§5.4/§6.3.1): `S` is a plain `unknown`; the `S ~ Sdef`
            # equation below is what makes it OBSERVED.
            "S" => _OB_ESS.ModelVariable(_OB_ESS.UnknownVariable; shape = ["x"]),
        )
        rng_i  = Dict{String,Any}("i" => _OB_ESS.IndexSetRef("x"))
        rng_ik = Dict{String,Any}("i" => _OB_ESS.IndexSetRef("x"),
                                  "k" => _OB_ESS.IndexSetRef("y"))
        rng_ab = Dict{String,Any}("a" => _OB_ESS.IndexSetRef("x"),
                                  "b" => _OB_ESS.IndexSetRef("y"))
        Sdef = _op("aggregate"; output_idx = Any["i"], ranges = rng_ik,
                   semiring = "sum_product",
                   expr_body = _op("*", _op("index", _const(W), _v("k")),
                                   _idx("q", _v("i"), _v("k"))))
        eqs = [
            _OB_ESS.Equation(_v("S"), Sdef),
            _OB_ESS.Equation(
                _op("aggregate"; output_idx = Any["a", "b"], ranges = rng_ab,
                    expr_body = _Didx("q", _v("a"), _v("b"))),
                _op("aggregate"; output_idx = Any["a", "b"], ranges = rng_ab,
                    expr_body = _n(0.0))),
            _OB_ESS.Equation(
                _op("aggregate"; output_idx = Any["i"], ranges = rng_i,
                    expr_body = _Didx("v", _v("i"))),
                _op("aggregate"; output_idx = Any["i"], ranges = rng_i,
                    expr_body = _idx("S", _v("i")))),
        ]
        model = _OB_ESS.Model(vars, eqs)
        ics = Dict{String,Any}("v[$j]" => 0.0 for j in 1:N)
        for j in 1:N, k in 1:M; ics["q[$j,$k]"] = Float64(3j + k); end
        bld(; form=:inplace, batch=true, loop=true) =
            withenv("ESS_CONTRACTION_LOOP" => (loop ? "1" : "0"),
                    "ESS_CONTRACTION_LOOP_MIN" => "8",
                    "ESS_OOP_BATCH" => (batch ? "1" : "0")) do
                build_evaluator(model; index_sets = isets, initial_conditions = ics,
                                form = form)
            end

        f!, u0, p, _, vmi = bld()
        di = similar(u0); f!(di, u0, p, 0.0)
        fo, u0o, po, _, vmo = bld(form=:oop)
        duo = fo(u0o, po, 0.0)
        fn_, u0n, pn, _, _ = bld(form=:oop, batch=false)
        dun = fn_(u0n, pn, 0.0)
        fu, u0u, pu, _, vmu = bld(form=:oop, loop=false)
        duu = fu(u0u, pu, 0.0)

        # values: oop(batch) == inplace == oop(nobatch) == oop(unroll) == exact
        @test all(duo[vmo["v[$j]"]] == di[vmi["v[$j]"]] for j in 1:N)
        @test duo == dun
        @test all(duo[vmo["v[$j]"]] == duu[vmu["v[$j]"]] for j in 1:N)
        @test all(duo[vmo["v[$j]"]] == sum(W[k] * (3j + k) for k in 1:M) for j in 1:N)

        # WITNESS: the fill level's scalars formed one N-lane group; nothing
        # left per-column. (`mat_batches` is tuple-aligned with `mat_levels`.)
        rhs = getfield(fo, :rhs)
        @test :mat_batches in fieldnames(typeof(rhs))
        mb = getfield(rhs, :mat_batches)
        @test length(mb) >= 1
        lvl = findfirst(sb -> !isempty(sb.groups), collect(mb))
        @test lvl !== nothing
        sb = mb[lvl]
        @test length(sb.groups) == 1
        @test sb.n_batched == N
        @test isempty(sb.rest)

        # kill switch leaves the fills on the per-column path
        mn = getfield(getfield(fn_, :rhs), :mat_batches)
        @test all(sb -> isempty(sb.groups), mn)

        # ForwardDiff: d v[1] / d q[1,k] = W[k], through the batched fill
        gv(u) = fo(u, po, 0.0)[vmo["v[1]"]]
        J = ForwardDiff.gradient(gv, u0o)
        @test all(J[vmo["q[1,$k]"]] == W[k] for k in 1:M)
        @test J[vmo["q[2,1]"]] == 0.0
    end

    # ── pow-exponent pinning ─────────────────────────────────────────────────
    # Same-structure entries with the SAME literal exponent group; DIFFERENT
    # exponents get different keys and stay single — a group never blends the
    # power rule (the `_oop_pow` Dual-safety property).
    @testset "pow exponent is pinned in the group key" begin
        doc = Dict{String,Any}("esm"=>"0.8.0","metadata"=>Dict("name"=>"ob_pow"),
          "models"=>Dict("P"=>Dict{String,Any}(
            "variables"=>Dict("x"=>Dict("type"=>"unknown"),"y"=>Dict("type"=>"unknown"),
                              "a"=>Dict("type"=>"unknown"),"b"=>Dict("type"=>"unknown"),
                              "c"=>Dict("type"=>"unknown")),
            "equations"=>Any[
              Dict("lhs"=>Dict("op"=>"D","args"=>Any["x"],"wrt"=>"t"),"rhs"=>0.0),
              Dict("lhs"=>Dict("op"=>"D","args"=>Any["y"],"wrt"=>"t"),"rhs"=>0.0),
              Dict("lhs"=>Dict("op"=>"D","args"=>Any["a"],"wrt"=>"t"),
                   "rhs"=>Dict("op"=>"^","args"=>Any["x",2.0])),
              Dict("lhs"=>Dict("op"=>"D","args"=>Any["b"],"wrt"=>"t"),
                   "rhs"=>Dict("op"=>"^","args"=>Any["y",2.0])),
              Dict("lhs"=>Dict("op"=>"D","args"=>Any["c"],"wrt"=>"t"),
                   "rhs"=>Dict("op"=>"^","args"=>Any["x",3.0])),
            ])))
        ics = Dict("x"=>1.5,"y"=>-2.5,"a"=>0.0,"b"=>0.0,"c"=>0.0)
        fo, u0, p, _, vm = withenv("ESS_OOP_BATCH"=>"1") do
            build_evaluator(doc; initial_conditions=ics, form=:oop)
        end
        du = fo(u0, p, 0.0)
        @test du[vm["a"]] == 1.5^2.0
        @test du[vm["b"]] == (-2.5)^2.0
        @test du[vm["c"]] == 1.5^3.0
        rb = getfield(getfield(fo, :rhs), :rhs_batches)
        # ^2 entries group (2 lanes); ^3 and the two D(·)=0 zero equations are
        # whatever the grouper decides for them — but NO group may mix
        # exponents. Find the pow group and check it.
        powgroups = [g for g in rb.groups if g.root.kind == _OB_ESS._NK_OP &&
                     (g.root.op === :^ || g.root.op === :pow)]
        @test length(powgroups) == 1
        g = powgroups[1]
        @test length(g.slots) == 2
        e = g.root.children[2]
        @test e.kind == _OB_ESS._NK_LITERAL && isempty(e.lanes_f) && e.literal == 2.0
        # Dual walk keeps the power rule at a negative base (no log(-|x|) NaN)
        gb(u) = fo(u, p, 0.0)[vm["b"]]
        J = ForwardDiff.gradient(gb, u0)
        @test J[vm["y"]] == 2.0 * (-2.5)
    end
end
