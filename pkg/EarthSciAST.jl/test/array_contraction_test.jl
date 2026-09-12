# Whole-array contraction loop nest (ess-array-contraction).
#
# An array-producing aggregate `out[i…] = ⊕_{k…} body(i…, k…)` above the tier's
# contracted-length floor compiles to ONE body node plus a flat output-slot
# vector and runs as a loop NEST, instead of one `_NK_CONTRACTION_LOOP` per
# output cell (the per-cell loop tier) or a ∏|k…|-term unrolled body per
# structural group (the affine tier). This pins:
#
#   * BIT-IDENTITY, `===` per element (so NaN and -0.0 count), against the
#     kill-switch oracle `ESS_ARRAY_CONTRACTION_DISABLE=1` — which for the shapes
#     below is the per-cell contraction loop, the nest's own fold order — and,
#     for a SINGLE contracted index, against the pure-unroll reference
#     `ESS_CONTRACTION_LOOP=0` as well;
#   * the dense SOURCE-RECEPTOR shape `conc[rcv] = Σ_s SR[s,rcv]·E[s]`, whose
#     output and contracted extents are EQUAL — the shape neither existing tier
#     can afford, since `#out < ∏|k…|` never holds so the unroll is always built;
#   * zero per-call allocation in the steady-state `f!` (`rhs_alloc_bytes`);
#   * build IR FLAT in the contracted extent AND in the output extent — the
#     node-lowering count is identical across a 64× range of each;
#   * `:oop` bit-identical to `:inplace`, and ForwardDiff through the nest;
#   * the FLOOR: a reduction under `ESS_ARRAY_CONTRACTION_MIN` is left to the
#     existing loop-vs-affine order, unchanged;
#   * the DECLINE: a reduction this tier cannot model (a per-cell variable bound)
#     falls through to that order and still gives the right answer.

using Test
using ForwardDiff
include("testutils.jl")
include("zero_alloc_harness.jl")

const _AC_ESS = EarthSciAST

# ── The source-receptor fixture ───────────────────────────────────────────────
# out[rcv] = Σ_s SR[s,rcv]·E[s], as an ODE from zero ICs so `du(u0)` IS the
# contraction. `SR` is an inline const matrix and `E` is STATE at the contracted
# index, so the body exercises both runtime gathers the nest relies on
# (`_NK_CONST_GATHER` at a loop-var subscript, `_NK_STATE_GATHER`).
# Integer-valued data, so the exact sum is representable and every tier's answer
# is comparable bit for bit.
_ac_sr(s, r) = Float64((3s + 7r) % 11)
_ac_e0(s)    = Float64(s % 5)

_ac_lhs(v, idx, n) = Dict("op" => "faq", "args" => Any[], "output_idx" => Any[idx],
    "ranges" => Dict(idx => Any[1, n]),
    "expr" => Dict("op" => "D", "args" => Any[
        Dict("op" => "index", "args" => Any[v, idx])], "wrt" => "t"))
_ac_zero(idx, n) = Dict("op" => "faq", "args" => Any[], "output_idx" => Any[idx],
    "ranges" => Dict(idx => Any[1, n]), "expr" => 0.0)

function _ac_doc(NS::Int, NR::Int)
    SR = [[_ac_sr(s, r) for r in 1:NR] for s in 1:NS]
    agg = Dict{String,Any}("op" => "faq", "semiring" => "sum_product",
        "args" => Any[], "output_idx" => Any["rcv"],
        "ranges" => Dict("rcv" => Any[1, NR], "s" => Any[1, NS]),
        "expr" => Dict("op" => "*", "args" => Any[
            Dict("op" => "index", "args" => Any[
                Dict("op" => "const", "args" => Any[], "value" => SR), "s", "rcv"]),
            Dict("op" => "index", "args" => Any["E", "s"])]))
    Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "ac_sr"),
      "models" => Dict("R" => Dict{String,Any}(
        "variables" => Dict("E" => Dict("type" => "unknown", "shape" => Any["s"]),
                            "conc" => Dict("type" => "unknown", "shape" => Any["rcv"])),
        "equations" => Any[
          Dict("lhs" => _ac_lhs("E", "s", NS), "rhs" => _ac_zero("s", NS)),
          Dict("lhs" => _ac_lhs("conc", "rcv", NR), "rhs" => agg)])))
end
_ac_ics(NS, NR) = merge(Dict{String,Any}("E[$s]" => _ac_e0(s) for s in 1:NS),
                        Dict{String,Any}("conc[$r]" => 0.0 for r in 1:NR))
_ac_exact(NS, NR) = [sum(_ac_sr(s, r) * _ac_e0(s) for s in 1:NS) for r in 1:NR]

# Every build in this file pins the floor to 8, so the tier engages at sizes
# where the oracle tiers are still cheap enough to run against it.
_ac_env(extra) = merge(Dict("ESS_ARRAY_CONTRACTION_MIN" => "8"), extra)

function _ac_build(doc, ics; env=Dict{String,String}(), form=:inplace,
                   const_arrays=Dict{String,Vector{Float64}}())
    withenv((k => v for (k, v) in _ac_env(env))...) do
        _AC_ESS._reset_cascade_tally!()
        r = build_evaluator(doc; initial_conditions=ics, form=form,
                            const_arrays=const_arrays)
        (r, copy(_AC_ESS._CASCADE_TALLY))
    end
end

# `du` at the model's own initial condition, plus the build's cascade tally.
function _ac_du(doc, ics; env=Dict{String,String}(),
                const_arrays=Dict{String,Vector{Float64}}())
    (f!, u0, p, _, vm), tally = _ac_build(doc, ics; env=env, const_arrays=const_arrays)
    du = similar(u0); f!(du, u0, p, 0.0)
    (du, vm, tally)
end
_ac_outs(du, vm, NR) = [du[vm["conc[$r]"]] for r in 1:NR]
_ac_tally(t, k) = get(t, k, 0)

const _AC_OFF = Dict("ESS_ARRAY_CONTRACTION_DISABLE" => "1")

@testset "whole-array contraction nest (ess-array-contraction)" begin

    @testset "source-receptor NS=$NS NR=$NR: nest == oracle == exact" for (NS, NR) in
            ((16, 16), (24, 8), (8, 24))
        doc, ics = _ac_doc(NS, NR), _ac_ics(NS, NR)
        dn, vn, tn = _ac_du(doc, ics)
        do_, vo, to = _ac_du(doc, ics; env=_AC_OFF)
        @test _ac_tally(tn, :array_contraction) == 1
        @test _ac_tally(to, :array_contraction) == 0     # the oracle really is another tier
        A = _ac_outs(dn, vn, NR)
        # `===` per element: bit-identity, so a NaN or a -0.0 could not pass.
        @test all(A[r] === _ac_outs(do_, vo, NR)[r] for r in 1:NR)
        @test all(A[r] === _ac_exact(NS, NR)[r] for r in 1:NR)
    end

    @testset "bit-identical to the pure-unroll reference (single contracted index)" begin
        # One contracted index, so the nest's fold order IS the unroll's: the
        # strongest oracle in the file, and the one the ISRM shape actually has.
        NS, NR = 20, 12
        doc, ics = _ac_doc(NS, NR), _ac_ics(NS, NR)
        dn, vn, tn = _ac_du(doc, ics)
        du, vu, tu = _ac_du(doc, ics; env=Dict("ESS_CONTRACTION_LOOP" => "0"))
        @test _ac_tally(tn, :array_contraction) == 1
        @test _ac_tally(tu, :array_contraction) == 0
        @test all(_ac_outs(dn, vn, NR)[r] === _ac_outs(du, vu, NR)[r] for r in 1:NR)
    end

    @testset "zero-allocation steady-state f!" begin
        NS, NR = 64, 64
        (f!, u0, p, _, _), tally = _ac_build(_ac_doc(NS, NR), _ac_ics(NS, NR))
        @test _ac_tally(tally, :array_contraction) == 1
        du = similar(u0)
        @test rhs_alloc_bytes(f!, du, u0, p, 0.0) == 0
    end

    @testset ":oop is bit-identical to :inplace" begin
        NS, NR = 16, 16
        doc, ics = _ac_doc(NS, NR), _ac_ics(NS, NR)
        di, vi, _ = _ac_du(doc, ics)
        (fo, u0o, po, _, vo), to = _ac_build(doc, ics; form=:oop)
        @test _ac_tally(to, :array_contraction) == 1
        duo = fo(u0o, po, 0.0)
        @test all(duo[vo["conc[$r]"]] === di[vi["conc[$r]"]] for r in 1:NR)
    end

    @testset "ForwardDiff differentiates through the nest" begin
        # ∂(du_conc[r])/∂E[s] = SR[s,r] — the contraction is linear in the state
        # it gathers, so the whole Jacobian row is known in closed form.
        NS, NR = 12, 6
        (f!, u0, p, _, vm), _ = _ac_build(_ac_doc(NS, NR), _ac_ics(NS, NR))
        g(u) = (d = similar(u, eltype(u)); f!(d, u, p, 0.0); d[vm["conc[3]"]])
        J = ForwardDiff.gradient(g, u0)
        @test all(J[vm["E[$s]"]] == _ac_sr(s, 3) for s in 1:NS)
    end

    # ── The property the tier exists for: build IR does not grow with EITHER
    # extent. `n_node_lowerings` counts the `_Node`s this build lowered, so a
    # tier that compiles per output cell (or unrolls per contracted index)
    # cannot hold either half of this.
    @testset "node lowerings are FLAT in both extents" begin
        # `_BENCH_COMPILE_CALLS` counts `_compile` lowerings for the build, the
        # same instrument `contraction_tier_order_test.jl` uses for the affine
        # tier's grid-independence claim.
        function nodes(NS, NR)
            withenv("ESS_ARRAY_CONTRACTION_MIN" => "8") do
                _AC_ESS._bench_reset!()
                _AC_ESS._BENCH_ON[] = true
                try
                    build_evaluator(_ac_doc(NS, NR); initial_conditions=_ac_ics(NS, NR))
                finally
                    _AC_ESS._BENCH_ON[] = false
                end
                _AC_ESS._BENCH_COMPILE_CALLS[]
            end
        end
        # Contracted extent ×64, output extent fixed.
        c1 = nodes(16, 8)
        c2 = nodes(256, 8)
        c3 = nodes(1024, 8)
        @test c1 == c2 == c3
        # Output extent ×64, contracted extent fixed.
        o1 = nodes(16, 16)
        o2 = nodes(16, 256)
        o3 = nodes(16, 1024)
        @test o1 == o2 == o3
    end

    @testset "under the floor the existing tier order is unchanged" begin
        # ∏|k…| = 16 < 32: the tier must not engage, and the answer must be the
        # one the pre-existing cascade gives.
        NS, NR = 16, 16
        doc, ics = _ac_doc(NS, NR), _ac_ics(NS, NR)
        dl, vl, tl = _ac_du(doc, ics; env=Dict("ESS_ARRAY_CONTRACTION_MIN" => "32"))
        @test _ac_tally(tl, :array_contraction) == 0
        do_, vo, _ = _ac_du(doc, ics; env=_AC_OFF)
        @test all(_ac_outs(dl, vl, NR)[r] === _ac_outs(do_, vo, NR)[r] for r in 1:NR)
    end

    # ── The nest is a `ue` READER the SSA dataflow pass has to know about ────
    # `ESS_OOP_SSA=1` drops a materialized fill's scatter into `ue` once nothing
    # is left reading its slots off the buffer. The nest's body is an ordinary
    # `_Node` walked by `_oop_eval`, so it reads `ue` like any scalar node does —
    # if the plan does not count those reads, the producer feeding the nest looks
    # dead, its scatter goes, and the nest folds a zero buffer. Pinned at BOTH
    # positions a nest can occupy: the state RHS and a materialized fill level.
    @testset "ESS_OOP_SSA keeps the scatter a nest reads ($where)" for
            (where, obs_nest) in (("state nest", false), ("observed nest", true))
        N = 16
        ag1(b) = _AC_ESS.OpExpr("faq", _AC_ESS.ASTExpr[]; output_idx=Any["i"],
            ranges=Dict("i" => _AC_ESS.IndexSetRef("x")), expr_body=b)
        # w[i] = 2·u[i] — an elementwise materialized observed, i.e. a
        # vectorizable producer whose ONLY reader is the nest below.
        weq = _AC_ESS.Equation(_v("w"), ag1(_op("*", _n(2.0), _idx("u", _v("i")))))
        # The source-receptor body this file is built on — an INLINE CONST
        # matrix read at both indices — because that is the shape the affine
        # tier declines, and a nest only exists where affine declined. An
        # arithmetic coefficient is taken by affine instead, and then there is
        # no nest to pin.
        Cm = [[_ac_sr(j, i) for i in 1:N] for j in 1:N]
        nest = _AC_ESS.OpExpr("faq", _AC_ESS.ASTExpr[]; output_idx=Any["i"],
            reduce="+", ranges=Dict("i" => _AC_ESS.IndexSetRef("x"),
                                    "j" => _AC_ESS.IndexSetRef("x")),
            expr_body=_op("*", _op("index", _AC_ESS.OpExpr("const", _AC_ESS.ASTExpr[];
                                                           value=Cm), _v("j"), _v("i")),
                          _idx("w", _v("j"))))
        vars = Dict("u" => _AC_ESS.ModelVariable(_AC_ESS.UnknownVariable; shape=["x"]),
                    "w" => _AC_ESS.ModelVariable(_AC_ESS.UnknownVariable; shape=["x"]))
        eqs = if obs_nest
            vars["z"] = _AC_ESS.ModelVariable(_AC_ESS.UnknownVariable; shape=["x"])
            [weq, _AC_ESS.Equation(_v("z"), nest),
             _AC_ESS.Equation(ag1(_Didx("u", _v("i"))), ag1(_idx("z", _v("i"))))]
        else
            [weq, _AC_ESS.Equation(ag1(_Didx("u", _v("i"))), nest)]
        end
        kw = (; index_sets=Dict("x" => _AC_ESS.IndexSet("interval"; size=N)),
                initial_conditions=Dict("u[$i]" => Float64(i % 7) for i in 1:N),
                form=:oop)
        # `SKIP_GATE=0` releases the worthwhileness bounds, so a scatter the
        # static accounting calls dead really is dropped and the values bite.
        bld(extra) = withenv((k => v for (k, v) in _ac_env(extra))...) do
            _AC_ESS._reset_cascade_tally!()
            (_AC_ESS._build_evaluator_impl(_AC_ESS.Model(vars, eqs); kw...),
             copy(_AC_ESS._CASCADE_TALLY))
        end
        (rb, tb) = bld(Dict{String,String}())
        (rs, _) = bld(Dict("ESS_OOP_SSA" => "1", "ESS_OOP_SSA_SKIP_GATE" => "0"))
        @test _ac_tally(tb, :array_contraction) == 1
        # The producer the nest reads must not be counted dead…
        @test !any(q.skippable for q in _AC_ESS.oop_ssa_producers(rs[1]))
        # …and the two arms must agree element for element.
        @test rb[1](rb[2], rb[3], 0.0) == rs[1](rs[2], rs[3], 0.0)
    end

    @testset "a bound this tier cannot model declines and still answers" begin
        # A per-cell VARIABLE contracted bound (`index(valence, i)`): not a
        # constant integer range, so the tier's admission test rejects it before
        # any probe and the equation keeps the existing per-cell path.
        NI, NK = 4, 12
        valence = [Float64(2 + (i % 3)) for i in 1:NI]     # 2..4 neighbours per cell
        W = [[Float64((i + 2k) % 7) for k in 1:NK] for i in 1:NI]
        agg = Dict{String,Any}("op" => "faq", "semiring" => "sum_product",
            "args" => Any[], "output_idx" => Any["i"],
            "ranges" => Dict("i" => Any[1, NI],
                             "k" => Any[1, Dict("op" => "index",
                                                "args" => Any["valence", "i"])]),
            "expr" => Dict("op" => "*", "args" => Any[
                Dict("op" => "index", "args" => Any[
                    Dict("op" => "const", "args" => Any[], "value" => W), "i", "k"]),
                Dict("op" => "index", "args" => Any["q", "i"])]))
        doc = Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "ac_ragged"),
          "models" => Dict("R" => Dict{String,Any}(
            "variables" => Dict("q" => Dict("type" => "unknown", "shape" => Any["i"]),
                                "out" => Dict("type" => "unknown", "shape" => Any["i"])),
            "equations" => Any[
              Dict("lhs" => _ac_lhs("q", "i", NI), "rhs" => _ac_zero("i", NI)),
              Dict("lhs" => _ac_lhs("out", "i", NI), "rhs" => agg)])))
        ics = merge(Dict{String,Any}("q[$i]" => Float64(i) for i in 1:NI),
                    Dict{String,Any}("out[$i]" => 0.0 for i in 1:NI))
        du, vm, tally = _ac_du(doc, ics;
                               const_arrays=Dict("valence" => valence))
        @test _ac_tally(tally, :array_contraction) == 0
        @test all(du[vm["out[$i]"]] ==
                  sum(Float64((i + 2k) % 7) for k in 1:Int(valence[i])) * Float64(i)
                  for i in 1:NI)
    end
end
