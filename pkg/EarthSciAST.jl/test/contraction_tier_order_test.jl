# Contraction tier ORDER (ess-runtime-contraction × ess-affine).
#
# `_compile_faq_equation!` offers a constant-bound array reduction to two
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
#     shape in `contraction_loop_test.jl`) takes the loop's place;
#   * a WIDE output over a SHORT reduction — the column-sum shape
#     `out[i,j] = Σ_k dp[i,j,k]·c[i,j,k]` — is offered to the affine tier first
#     and lands there, so its build IR does not grow with the grid;
#   * an equation the affine tier DECLINES falls back to the loop's place.
#
# In the IN-PLACE build that place belongs to the whole-array contraction nest,
# whatever the nest's length floor: the loop's cells are `_Node` trees the
# in-place `f!` walks per output cell on every call, so the loop is retired
# there and the nest — same admission, same fold order, emitted code — takes
# every equation the loop would have. The out-of-place build keeps the loop,
# because its emitters compile it (test/reactant_direct_emit_test.jl).
#
# Numerically nothing may move, whichever tier takes the equation: every case is
# pinned bit-for-bit against `compiler=:interpreter` — which turns the nest, the
# per-cell contraction loop and the affine stencil all off, so the reduction is
# reached by the pure unroll — and against exact arithmetic.

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
    agg = Dict{String,Any}("op" => "faq", "semiring" => "sum_product",
        "args" => Any[], "output_idx" => Any["i", "j"],
        "ranges" => Dict("i" => Any[1, NI], "j" => Any[1, NJ], "k" => Any[1, NK]),
        "expr" => Dict("op" => "*", "args" => Any[
            Dict("op" => "index", "args" => Any["dp", "i", "j", "k"]),
            Dict("op" => "index", "args" => Any["c", "i", "j", "k"])]))
    zero_c = Dict("op" => "faq", "args" => Any[], "output_idx" => Any["i", "j", "k"],
        "ranges" => Dict("i" => Any[1, NI], "j" => Any[1, NJ], "k" => Any[1, NK]),
        "expr" => 0.0)
    Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "cto_colsum"),
      "models" => Dict("R" => Dict{String,Any}(
        "variables" => Dict(
            "c"   => Dict("type" => "unknown", "shape" => Any["i", "j", "k"]),
            "dp"  => Dict("type" => "parameter", "shape" => Any["i", "j", "k"]),
            "out" => Dict("type" => "unknown", "shape" => Any["i", "j"])),
        "equations" => Any[
          Dict("lhs" => Dict("op" => "faq", "args" => Any[],
                 "output_idx" => Any["i", "j", "k"],
                 "ranges" => Dict("i" => Any[1, NI], "j" => Any[1, NJ], "k" => Any[1, NK]),
                 "expr" => Dict("op" => "D", "args" => Any[
                     Dict("op" => "index", "args" => Any["c", "i", "j", "k"])], "wrt" => "t")),
               "rhs" => zero_c),
          Dict("lhs" => Dict("op" => "faq", "args" => Any[],
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

# Build once, returning `(du, var_map, tally, node_lowerings)`. `compiler`
# chooses the evaluator; the two `env` entries are the TUNING THRESHOLDS that
# decide which side of a tier's admission floor this fixture falls on, stated
# per case so the routing under test is a property of the fixture rather than of
# the ambient environment.
function _cto_build(NI, NJ, NK; compiler = :native, env = Dict{String,String}())
    doc = _cto_doc(NI, NJ, NK)
    ics = _cto_ics(NI, NJ, NK)
    pairs = ["ESS_CONTRACTION_LOOP_MIN" => get(env, "ESS_CONTRACTION_LOOP_MIN", "8"),
             "ESS_ARRAY_CONTRACTION_MIN" =>
                 get(env, "ESS_ARRAY_CONTRACTION_MIN", "1024")]
    dp = [ _cto_dpv(i, j, k) for i in 1:NI, j in 1:NJ, k in 1:NK ]
    withenv(pairs...) do
        _CTO_ESS._reset_cascade_tally!()
        _CTO_ESS._bench_reset!()
        _CTO_ESS._BENCH_ON[] = true
        local f, u0, p, vm
        try
            f, u0, p, _, vm = EarthSciAST._build_evaluator(doc; initial_conditions = ics,
                                              compiler = compiler,
                                              const_arrays = Dict("dp" => dp))
        finally
            _CTO_ESS._BENCH_ON[] = false
        end
        tally = copy(_CTO_ESS._CASCADE_TALLY)
        nodes = _CTO_ESS._BENCH_COMPILE_CALLS[]
        du = (d = similar(u0); f(d, u0, p, 0.0); d)
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
    # terms — the unroll cannot be cheaper, so the loop's place keeps the
    # equation, and in place that is the nest, although the reduction is far
    # under the nest's floor.
    @testset "narrow output, long reduction → the nest (under its floor)" begin
        NI, NJ, NK = 2, 2, 8
        @test NI * NJ < NK                  # the admission condition, stated
        du, vm, tally, _ = _cto_build(NI, NJ, NK)
        @test _cto_get(tally, :percell_loop) == 0
        @test _cto_get(tally, :array_contraction_codegen) == 1
        @test _cto_get(tally, :affine) == 1     # only the D(c) = 0 equation
        @test _cto_outs(du, vm, NI, NJ) == _cto_exact(NI, NJ, NK)
        du_i, vm_i, _, _ = _cto_build(NI, NJ, NK; compiler = :interpreter)
        A = _cto_outs(du, vm, NI, NJ)
        @test all(A[i] === _cto_outs(du_i, vm_i, NI, NJ)[i] for i in eachindex(A))
    end

    # ── …and the SAME shape once the reduction clears the nest's floor. The
    # per-cell loop lowers one node per OUTPUT CELL; the nest lowers one for the
    # whole equation, so by the rule both tiers are selected on — take the
    # equation when the alternative's build scales with an extent — the nest wins
    # here too, narrow output or not. Pinned as a positive routing fact on both
    # sides: the nest fired AND the loop did not.
    @testset "narrow output, long reduction → the nest once above the floor" begin
        NI, NJ, NK = 2, 2, 8
        env = Dict("ESS_ARRAY_CONTRACTION_MIN" => "8")
        du, vm, tally, _ = _cto_build(NI, NJ, NK; env = env)
        @test _cto_get(tally, :array_contraction_codegen) == 1
        @test _cto_get(tally, :percell_loop) == 0
        @test _cto_get(tally, :percell_acc) == 0
        # Numerics do not move with the floor: the same fixture BELOW it is the
        # same nest, bit for bit.
        du_l, vm_l, tally_l, _ = _cto_build(NI, NJ, NK)
        @test _cto_get(tally_l, :array_contraction_codegen) == 1
        A = _cto_outs(du, vm, NI, NJ)
        @test all(A[i] === _cto_outs(du_l, vm_l, NI, NJ)[i] for i in eachindex(A))
        @test A == _cto_exact(NI, NJ, NK)
        # …and bit for bit against the pure unroll. This shape reaches the
        # emitter through a 3-D const gather at two output indices and a state
        # gather at the contracted one, which the source-receptor shape in
        # `array_contraction_test.jl` does not.
        du_i, vm_i, tally_i, _ = _cto_build(NI, NJ, NK; compiler = :interpreter,
                                            env = env)
        @test _cto_get(tally_i, :array_contraction_codegen) == 0
        @test all(A[i] === _cto_outs(du_i, vm_i, NI, NJ)[i] for i in eachindex(A))
    end

    # ── Numerics may not move. The affine tier's answer on the wide case is
    # pinned against the pure unroll, `===` per element, and against exact
    # arithmetic.
    @testset "wide case is bit-identical to the unrolled reference" begin
        NI, NJ, NK = 6, 6, 8
        du_a, vm_a, tally_a, _ = _cto_build(NI, NJ, NK)
        du_u, vm_u, tally_u, _ = _cto_build(NI, NJ, NK; compiler = :interpreter)
        @test _cto_get(tally_a, :affine) >= 2
        # The reference really is the unroll, not a relabelled affine build.
        @test _cto_get(tally_u, :affine) == 0
        @test _cto_get(tally_u, :percell_disabled) >= 1
        A = _cto_outs(du_a, vm_a, NI, NJ)
        @test all(A[i] === _cto_outs(du_u, vm_u, NI, NJ)[i] for i in eachindex(A))
        @test A == _cto_exact(NI, NJ, NK)
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
