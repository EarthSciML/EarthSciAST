# Contraction tier ORDER (ess-runtime-contraction × ess-affine).
#
# `_compile_arrayop_equation!` offers a constant-bound array reduction to two
# tiers, and their build costs scale with different things:
#
#   contraction loop   one resolve + `_compile` per OUTPUT CELL, each O(1) in the
#                      reduction length                    →  O(#output cells)
#   unroll + affine    one resolve + `_compile` per STRUCTURAL GROUP over a body
#                      of ∏|k…| terms                      →  O(#groups · ∏|k…|)
#
# Only the first grows with the GRID, so choosing it unconditionally would make
# the build linear in the cell count for every reduction at or above the length
# floor — including the plain column sums a transport model is full of, which
# the affine tier compiles ONCE for the whole array.
#
# The loop preempts the affine tier only when `#output cells < ∏|k…|` — the most
# optimistic (`#groups == 1`) form of "the unroll cannot be cheaper" — so:
#
#   * a NARROW output over a LONG reduction (what the loop exists for, and every
#     shape in `contraction_loop_test.jl`) takes the loop;
#   * a WIDE output over a SHORT reduction — the column-sum shape
#     `out[i,j] = Σ_k dp[i,j,k]·c[i,j,k]` — is offered to the affine tier first
#     and lands there, so its build IR does not grow with the grid;
#   * an equation the affine tier DECLINES falls back to the loop.
#
# Numerically nothing may move: the wide case is pinned bit-for-bit against the
# pure-unroll reference (`ESS_CONTRACTION_LOOP=0`), the per-cell reference
# (`ESS_STENCIL_DISABLE=1` — which for this shape IS the contraction-loop
# per-cell path, so it cross-checks the two tiers against each other) and exact
# arithmetic.

using Test
include("testutils.jl")

const _CTO_ESS = EarthSciAST

# out[i,j] = Σ_{k=1..NK} dp[i,j,k] · c[i,j,k]   (dp an inline const field, c state)
# `c` is a state at the CONTRACTED index, so the loopability probe passes and the
# reduction is a genuine contraction-loop candidate — the ordering, not the gate,
# is what decides which tier it lands on. Integer-valued data, so the grouped and
# flat sums are bit-equal and the exact value is representable.
_cto_dpv(i, j, k) = Float64((i + 2j + 3k) % 5)
_cto_cv(i, j, k)  = Float64((7i + 5j + k) % 6)

function _cto_doc(NI::Int, NJ::Int, NK::Int)
    agg = Dict{String,Any}("op" => "aggregate", "semiring" => "sum_product",
        "args" => Any[], "output_idx" => Any["i", "j"],
        "ranges" => Dict("i" => Any[1, NI], "j" => Any[1, NJ], "k" => Any[1, NK]),
        "expr" => Dict("op" => "*", "args" => Any[
            Dict("op" => "index", "args" => Any["dp", "i", "j", "k"]),
            Dict("op" => "index", "args" => Any["c", "i", "j", "k"])]))
    zero_c = Dict("op" => "aggregate", "args" => Any[], "output_idx" => Any["i", "j", "k"],
        "ranges" => Dict("i" => Any[1, NI], "j" => Any[1, NJ], "k" => Any[1, NK]),
        "expr" => 0.0)
    Dict{String,Any}("esm" => "0.8.0", "metadata" => Dict("name" => "cto_colsum"),
      "models" => Dict("R" => Dict{String,Any}(
        "variables" => Dict(
            "c"   => Dict("type" => "unknown", "shape" => Any["i", "j", "k"]),
            "dp"  => Dict("type" => "parameter", "shape" => Any["i", "j", "k"]),
            "out" => Dict("type" => "unknown", "shape" => Any["i", "j"])),
        "equations" => Any[
          Dict("lhs" => Dict("op" => "aggregate", "args" => Any[],
                 "output_idx" => Any["i", "j", "k"],
                 "ranges" => Dict("i" => Any[1, NI], "j" => Any[1, NJ], "k" => Any[1, NK]),
                 "expr" => Dict("op" => "D", "args" => Any[
                     Dict("op" => "index", "args" => Any["c", "i", "j", "k"])], "wrt" => "t")),
               "rhs" => zero_c),
          Dict("lhs" => Dict("op" => "aggregate", "args" => Any[],
                 "output_idx" => Any["i", "j"],
                 "ranges" => Dict("i" => Any[1, NI], "j" => Any[1, NJ]),
                 "expr" => Dict("op" => "D", "args" => Any[
                     Dict("op" => "index", "args" => Any["out", "i", "j"])], "wrt" => "t")),
               "rhs" => agg)])))
end

function _cto_ics(NI, NJ, NK)
    d = Dict{String,Any}()
    for i in 1:NI, j in 1:NJ
        d["out[$i,$j]"] = 0.0
    end
    for i in 1:NI, j in 1:NJ, k in 1:NK
        d["c[$i,$j,$k]"] = _cto_cv(i, j, k)
    end
    d
end

_cto_exact(NI, NJ, NK) =
    [ sum(_cto_dpv(i, j, k) * _cto_cv(i, j, k) for k in 1:NK) for i in 1:NI, j in 1:NJ ]

# Build once, returning `(du, var_map, tally, node_lowerings)`. `env` overrides are
# applied around the build only.
function _cto_build(NI, NJ, NK; env = Dict{String,String}(), form = :inplace)
    doc = _cto_doc(NI, NJ, NK)
    ics = _cto_ics(NI, NJ, NK)
    pairs = ["ESS_CONTRACTION_LOOP" => get(env, "ESS_CONTRACTION_LOOP", nothing),
             "ESS_CONTRACTION_LOOP_MIN" => get(env, "ESS_CONTRACTION_LOOP_MIN", "8"),
             "ESS_STENCIL_DISABLE" => get(env, "ESS_STENCIL_DISABLE", nothing)]
    dp = [ _cto_dpv(i, j, k) for i in 1:NI, j in 1:NJ, k in 1:NK ]
    withenv(pairs...) do
        _CTO_ESS._reset_cascade_tally!()
        _CTO_ESS._bench_reset!()
        _CTO_ESS._BENCH_ON[] = true
        local f, u0, p, vm
        try
            f, u0, p, _, vm = build_evaluator(doc; initial_conditions = ics,
                                              const_arrays = Dict("dp" => dp), form = form)
        finally
            _CTO_ESS._BENCH_ON[] = false
        end
        tally = copy(_CTO_ESS._CASCADE_TALLY)
        nodes = _CTO_ESS._BENCH_COMPILE_CALLS[]
        du = if form === :oop
            f(u0, p, 0.0)
        else
            d = similar(u0); f(d, u0, p, 0.0); d
        end
        (du, vm, tally, nodes)
    end
end

_cto_get(tally, k) = get(tally, k, 0)
_cto_outs(du, vm, NI, NJ) = [ du[vm["out[$i,$j]"]] for i in 1:NI, j in 1:NJ ]

@testset "contraction tier order (loop vs affine)" begin

    # ── A WIDE output over a SHORT reduction must reach the affine tier.
    # 36 output cells against 8 terms — the loop's per-cell cost is the larger of
    # the two, so it must not preempt.
    @testset "wide output, short reduction → affine (not per-cell loop)" begin
        NI, NJ, NK = 6, 6, 8
        @test NI * NJ >= NK                 # the admission condition, stated
        du, vm, tally, _ = _cto_build(NI, NJ, NK)
        @test _cto_get(tally, :percell_loop) == 0
        @test _cto_get(tally, :percell_acc) == 0
        @test _cto_get(tally, :affine) >= 2  # the column sum AND the D(c)=0 equation
        @test _cto_outs(du, vm, NI, NJ) == _cto_exact(NI, NJ, NK)
    end

    # ── The shape the contraction loop exists for. 4 output cells against 8
    # terms — the unroll cannot be cheaper, so the loop keeps the equation.
    @testset "narrow output, long reduction → contraction loop (unchanged)" begin
        NI, NJ, NK = 2, 2, 8
        @test NI * NJ < NK                  # the admission condition, stated
        du, vm, tally, _ = _cto_build(NI, NJ, NK)
        @test _cto_get(tally, :percell_loop) == 1
        @test _cto_outs(du, vm, NI, NJ) == _cto_exact(NI, NJ, NK)
    end

    # ── Numerics may not move. The affine tier's answer is pinned against BOTH
    # independent references, bit for bit, on the wide case that changed tiers.
    @testset "wide case is bit-identical to both references" begin
        NI, NJ, NK = 6, 6, 8
        du_a, vm_a, tally_a, _ = _cto_build(NI, NJ, NK)
        du_u, vm_u, tally_u, _ = _cto_build(NI, NJ, NK;
            env = Dict("ESS_CONTRACTION_LOOP" => "0"))          # pure unroll
        du_p, vm_p, tally_p, _ = _cto_build(NI, NJ, NK;
            env = Dict("ESS_STENCIL_DISABLE" => "1"))           # per-cell: the LOOP tier
        @test _cto_get(tally_a, :percell_loop) == 0
        @test _cto_get(tally_u, :percell_loop) == 0
        # The reference really is the other tier, not a relabelled affine build.
        @test _cto_get(tally_p, :percell_loop) == 1
        A = _cto_outs(du_a, vm_a, NI, NJ)
        @test A == _cto_outs(du_u, vm_u, NI, NJ)
        @test A == _cto_outs(du_p, vm_p, NI, NJ)
        @test A == _cto_exact(NI, NJ, NK)
        # …and through the `:oop` build, which merges the same kernels differently.
        du_o, vm_o, _, _ = _cto_build(NI, NJ, NK; form = :oop)
        @test _cto_outs(du_o, vm_o, NI, NJ) == A
    end

    # ── The point of the whole thing: build IR for the column sum does not grow
    # with the grid. Quadrupling the output cell count (6×6 → 12×12) at a fixed
    # reduction length must leave node lowerings flat; a tier that lowers a node
    # per output cell cannot hold that.
    @testset "node lowerings are FLAT in output cells" begin
        NK = 8
        _, _, t6,  n6  = _cto_build(6, 6, NK)      # 36 output cells
        _, _, t12, n12 = _cto_build(12, 12, NK)    # 144
        _, _, t24, n24 = _cto_build(24, 24, NK)    # 576
        for t in (t6, t12, t24)
            @test _cto_get(t, :percell_loop) == 0
        end
        # 16× the output cells, IDENTICAL node lowerings — the grid-independence
        # property `grid_invariance_test.jl` states, which the loop tier cannot
        # hold because it lowers a node per output cell.
        @test n6 == n12 == n24
    end
end
