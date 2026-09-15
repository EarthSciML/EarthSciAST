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

# `reduce=nothing` keeps the declared `sum_product` semiring (the shape every
# other case in this file uses); naming a reducer instead exercises the other
# three ⊕ the tier admits. `coef`/`e` swap in data with no exact zero and no
# integer value, so a ×-fold cannot collapse to 0̄ and a fold ORDER difference
# shows up in the last bit.
function _ac_doc(NS::Int, NR::Int; coef=_ac_sr, red=nothing)
    SR = [[coef(s, r) for r in 1:NR] for s in 1:NS]
    agg = Dict{String,Any}("op" => "faq",
        "args" => Any[], "output_idx" => Any["rcv"],
        "ranges" => Dict("rcv" => Any[1, NR], "s" => Any[1, NS]),
        "expr" => Dict("op" => "*", "args" => Any[
            Dict("op" => "index", "args" => Any[
                Dict("op" => "const", "args" => Any[], "value" => SR), "s", "rcv"]),
            Dict("op" => "index", "args" => Any["E", "s"])]))
    # The semiring, when declared, is authoritative over `reduce` (§5.1), so the
    # two spellings are mutually exclusive rather than merged.
    red === nothing ? (agg["semiring"] = "sum_product") : (agg["reduce"] = red)
    Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "ac_sr"),
      "models" => Dict("R" => Dict{String,Any}(
        "variables" => Dict("E" => Dict("type" => "unknown", "shape" => Any["s"]),
                            "conc" => Dict("type" => "unknown", "shape" => Any["rcv"])),
        "equations" => Any[
          Dict("lhs" => _ac_lhs("E", "s", NS), "rhs" => _ac_zero("s", NS)),
          Dict("lhs" => _ac_lhs("conc", "rcv", NR), "rhs" => agg)])))
end
_ac_ics(NS, NR; e=_ac_e0) = merge(Dict{String,Any}("E[$s]" => e(s) for s in 1:NS),
                                  Dict{String,Any}("conc[$r]" => 0.0 for r in 1:NR))
_ac_sr_frac(s, r) = _ac_sr(s, r) / 4 + 0.5      # never 0, never an integer
_ac_e0_frac(s)    = _ac_e0(s) + 0.25            # never 0
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

    # ── Every ⊕ the tier admits, not just the sum ────────────────────────────
    # `+` is the shape the tier was written for, but the admission test also lets
    # `*`, `max` and `min` through, and all four are seeded from the semiring's 0̄
    # and folded by the SAME `_NK_CONTRACTION_LOOP`. Pinned against both oracles
    # at once, so a wrong identity or a reversed fold could not pass.
    @testset "reducer $red folds exactly as the tier it replaces" for
            red in ("*", "max", "min")
        NS, NR = 16, 10
        doc = _ac_doc(NS, NR; coef=_ac_sr_frac, red=red)
        ics = _ac_ics(NS, NR; e=_ac_e0_frac)
        dn, vn, tn = _ac_du(doc, ics)
        do_, vo, to = _ac_du(doc, ics; env=_AC_OFF)
        du_, vu, tu = _ac_du(doc, ics; env=Dict("ESS_CONTRACTION_LOOP" => "0"))
        @test _ac_tally(tn, :array_contraction) == 1
        @test _ac_tally(to, :array_contraction) == 0
        @test _ac_tally(tu, :array_contraction) == 0
        f = red == "*" ? (*) : red == "max" ? max : min
        ex = [foldl(f, [_ac_sr_frac(s, r) * _ac_e0_frac(s) for s in 1:NS])
              for r in 1:NR]
        A = _ac_outs(dn, vn, NR)
        @test all(A[r] === _ac_outs(do_, vo, NR)[r] for r in 1:NR)
        @test all(A[r] === _ac_outs(du_, vu, NR)[r] for r in 1:NR)
        @test all(A[r] === ex[r] for r in 1:NR)
    end

    # ── More than one index on each side ─────────────────────────────────────
    # Every case above has ONE output index and ONE contracted index, which
    # leaves the section runner's output odometer (`_ac_seek!`: dimension 1
    # fastest, driven off `los`/`steps`/`lens`) and the nest order over several
    # contracted indices unpinned. Two of each here, with the output extents
    # DIFFERENT so a transposed counter pair could not pass, and the first output
    # range starting at 2 so `los` is not the identity.
    @testset "two output indices and two contracted indices" begin
        NS1, NS2, R1LO, R1HI, NR2 = 3, 4, 2, 6, 7
        c1(s, r) = _ac_sr(s, r)          # read at (contracted 1, output 1)
        c2(s, r) = Float64((5s + 2r) % 13)  # read at (contracted 2, output 2)
        e2(a, b) = Float64((a + 3b) % 5)
        ax(idxs, rngs) = Dict("op" => "faq", "args" => Any[],
            "output_idx" => Any[idxs...], "ranges" => Dict(rngs))
        lhs(v, idxs, rngs) = merge(ax(idxs, rngs),
            Dict("expr" => Dict("op" => "D", "wrt" => "t", "args" => Any[
                Dict("op" => "index", "args" => Any[v, idxs...])])))
        zro(idxs, rngs) = merge(ax(idxs, rngs), Dict("expr" => 0.0))
        cst(v) = Dict("op" => "const", "args" => Any[], "value" => v)
        # `c1` is stored over the FULL 1:R1HI axis: the const is subscripted by
        # the output index itself, whose range starts at 2.
        C1 = [[c1(s, r) for r in 1:R1HI] for s in 1:NS1]
        C2 = [[c2(s, r) for r in 1:NR2] for s in 1:NS2]
        srng = ["s1" => Any[1, NS1], "s2" => Any[1, NS2]]
        orng = ["r1" => Any[R1LO, R1HI], "r2" => Any[1, NR2]]
        agg = merge(ax(("r1", "r2"), vcat(orng, srng)),
            Dict("semiring" => "sum_product",
                 "expr" => Dict("op" => "*", "args" => Any[
                    Dict("op" => "index", "args" => Any[cst(C1), "s1", "r1"]),
                    Dict("op" => "*", "args" => Any[
                        Dict("op" => "index", "args" => Any[cst(C2), "s2", "r2"]),
                        Dict("op" => "index", "args" => Any["E", "s1", "s2"])])])))
        doc = Dict{String,Any}("esm" => "1.1.0",
          "metadata" => Dict("name" => "ac_sr2"),
          "models" => Dict("R" => Dict{String,Any}(
            "variables" => Dict(
              "E" => Dict("type" => "unknown", "shape" => Any["s1", "s2"]),
              "conc" => Dict("type" => "unknown", "shape" => Any["r1", "r2"])),
            "equations" => Any[
              Dict("lhs" => lhs("E", ("s1", "s2"), srng),
                   "rhs" => zro(("s1", "s2"), srng)),
              Dict("lhs" => lhs("conc", ("r1", "r2"), orng), "rhs" => agg)])))
        ics = merge(
            Dict{String,Any}("E[$a,$b]" => e2(a, b) for a in 1:NS1, b in 1:NS2),
            Dict{String,Any}("conc[$r,$q]" => 0.0 for r in R1LO:R1HI, q in 1:NR2))
        dn, vn, tn = _ac_du(doc, ics)
        do_, vo, to = _ac_du(doc, ics; env=_AC_OFF)
        @test _ac_tally(tn, :array_contraction) == 1
        @test _ac_tally(to, :array_contraction) == 0
        cells = [(r, q) for r in R1LO:R1HI, q in 1:NR2]
        @test all(dn[vn["conc[$r,$q]"]] === do_[vo["conc[$r,$q]"]]
                  for (r, q) in cells)
        # Integer-valued data again, so the closed form is exactly representable.
        @test all(dn[vn["conc[$r,$q]"]] ==
                  sum(c1(a, r) * c2(b, q) * e2(a, b)
                      for a in 1:NS1, b in 1:NS2)
                  for (r, q) in cells)
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

    # ── The `:inplace` twin of the level fill ────────────────────────────────
    # `_fill_obs_levels!` runs a level's nests through the SAME section as the
    # state RHS, but the case above builds `:oop` only, so the in-place level arm
    # is reached by no fixture. Build the observed-nest model both ways and pin
    # the level fill against the kill-switch oracle AND against `:oop`.
    @testset "a nest on a materialized observed level, in place" begin
        N = 16
        ag1(b) = _AC_ESS.OpExpr("faq", _AC_ESS.ASTExpr[]; output_idx=Any["i"],
            ranges=Dict("i" => _AC_ESS.IndexSetRef("x")), expr_body=b)
        weq = _AC_ESS.Equation(_v("w"), ag1(_op("*", _n(2.0), _idx("u", _v("i")))))
        Cm = [[_ac_sr(j, i) for i in 1:N] for j in 1:N]
        nest = _AC_ESS.OpExpr("faq", _AC_ESS.ASTExpr[]; output_idx=Any["i"],
            reduce="+", ranges=Dict("i" => _AC_ESS.IndexSetRef("x"),
                                    "j" => _AC_ESS.IndexSetRef("x")),
            expr_body=_op("*", _op("index", _AC_ESS.OpExpr("const", _AC_ESS.ASTExpr[];
                                                           value=Cm), _v("j"), _v("i")),
                          _idx("w", _v("j"))))
        vars = Dict("u" => _AC_ESS.ModelVariable(_AC_ESS.UnknownVariable; shape=["x"]),
                    "w" => _AC_ESS.ModelVariable(_AC_ESS.UnknownVariable; shape=["x"]),
                    "z" => _AC_ESS.ModelVariable(_AC_ESS.UnknownVariable; shape=["x"]))
        eqs = [weq, _AC_ESS.Equation(_v("z"), nest),
               _AC_ESS.Equation(ag1(_Didx("u", _v("i"))), ag1(_idx("z", _v("i"))))]
        u0v = Dict("u[$i]" => Float64(i % 7) for i in 1:N)
        bld(form, extra) = withenv((k => v for (k, v) in _ac_env(extra))...) do
            _AC_ESS._reset_cascade_tally!()
            (_AC_ESS._build_evaluator_impl(_AC_ESS.Model(vars, eqs);
                index_sets=Dict("x" => _AC_ESS.IndexSet("interval"; size=N)),
                initial_conditions=u0v, form=form),
             copy(_AC_ESS._CASCADE_TALLY))
        end
        run_ip(extra) = begin
            (r, t) = bld(:inplace, extra)
            (f!, u0, p) = (r[1], r[2], r[3])
            du = similar(u0); f!(du, u0, p, 0.0)
            (du, r[5], t)
        end
        dn, vn, tn = run_ip(Dict{String,String}())
        do_, vo, to = run_ip(_AC_OFF)
        @test _ac_tally(tn, :array_contraction) == 1
        @test _ac_tally(to, :array_contraction) == 0
        @test all(dn[vn["u[$i]"]] === do_[vo["u[$i]"]] for i in 1:N)
        # The closed form: u̇[i] = z[i] = Σ_j C[j,i]·2·u[j].
        @test all(dn[vn["u[$i]"]] ==
                  sum(_ac_sr(j, i) * 2.0 * Float64(j % 7) for j in 1:N)
                  for i in 1:N)
        (ro, _) = bld(:oop, Dict{String,String}())
        duo = ro[1](ro[2], ro[3], 0.0)
        @test all(duo[ro[5]["u[$i]"]] === dn[vn["u[$i]"]] for i in 1:N)
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
