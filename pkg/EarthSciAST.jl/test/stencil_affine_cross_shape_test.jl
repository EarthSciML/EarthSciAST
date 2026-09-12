# CROSS-SHAPE STATE GATHER: a state array read from a loop of a DIFFERENT shape.
#
# `_AK_STATE_AFFINE` models `u[oln + Δ]` — a gather from an array laid out
# exactly like the output. A gather from an array of a different shape (a
# lower-rank geometry column read from a 2-D/3-D loop, a staggered face field, a
# surface field) has a slot that is still AFFINE in the loop indices, but with
# the array's own strides, so `Δ` moves at every cell. Two things followed, both
# O(#cells):
#
#   * the per-cell cut signature keyed state lanes by `Δ`, so it read a
#     transition at every cell — the edge-inward scan never stabilised and every
#     axis was cut into segments up to the `_AFFINE_MAX_DELTA_SEGS` cap, making
#     the BOX COUNT grow with the grid;
#   * `_derive_lane_repl` then could not prove the lane uniform over its box and
#     materialised a DENSE per-box slot table — one `_eval_recipe` and one stored
#     `Int` per box CELL, per lane.
#
# The fix keys the lane by its own subscripts' deviation from affinity (which is
# identically zero for an affine subscript, at any grid size) and lowers it to
# `_AccStateTblBox` addressed through the variable's own IDENTITY slot block —
# shared across every lane, box and equation of the build.
#
# This pins BOTH halves as grid-independent, and pins numeric equality against
# the two kill switches (`ESS_LANE_AFFINE_KEY_DISABLE=1`, `ESS_STATE_BOX_DISABLE=1`)
# which restore the pre-fix build.
using Test
using EarthSciAST
include("testutils.jl")
const ESM_CS = EarthSciAST

# D(a[j])   = 0                          — a 1-D column, extent N
# D(u[i,j]) = a[j] * u[i,j]              — a 2-D field, extent N×N
# `a[j]` read from the (i,j) loop is the cross-shape gather: slot(a[j]) is
# affine in `j` alone while the output slot moves with both `i` and `j`.
function _cs_model(N)
    vars = Dict{String,ESM_CS.ModelVariable}(
        "a" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable),
        "u" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable))
    ao2(body, lhs) = ESM_CS.OpExpr("faq", ESM_CS.ASTExpr[];
        output_idx = Any["i", "j"], expr_body = body,
        ranges = Dict("i" => [1, N], "j" => [1, N]))
    ESM_CS.Model(vars, [
        ESM_CS.Equation(_ao1(_Didx("a", _v("j")), "j", 1, N),
                        _ao1(_n(0.0), "j", 1, N)),
        ESM_CS.Equation(ao2(_Didx("u", _v("i"), _v("j")), nothing),
                        ao2(_op("*", _idx("a", _v("j")),
                                     _idx("u", _v("i"), _v("j"))), nothing))])
end

function _cs_build(N)
    ics = Dict{String,Float64}()
    for j in 1:N
        ics["a[$j]"] = 0.5 + 0.1j
        for i in 1:N
            ics["u[$i,$j]"] = sin(0.3i) + 0.2j
        end
    end
    ESM_CS._reset_cascade_tally!()
    f, u0, p, _t, vm, diag = ESM_CS._build_evaluator_impl(_cs_model(N);
        initial_conditions = ics)
    du = zero(u0); f(du, u0, p, 0.0)
    ks = getfield(getfield(f, :kernel_section), :kernels)
    (u0 = u0, du = du, diag = diag, kernels = ks,
     tally = copy(ESM_CS._CASCADE_TALLY),
     n_kernels = length(ks),
     conn_entries = sum(sum(length(d.conn) for d in K.acc; init = 0)
                        for K in ks; init = 0))
end

# `kernel_section.kernels` is complete only with the codegen tier off (the
# oop_merge/xcse idiom used by grid_invariance_test.jl).
_cs_run(N) = withenv("ESS_CODEGEN_DISABLE" => "1") do; _cs_build(N); end
_cs_run_pre(N) = withenv("ESS_CODEGEN_DISABLE" => "1",
                         "ESS_LANE_AFFINE_KEY_DISABLE" => "1",
                         "ESS_STATE_BOX_DISABLE" => "1") do; _cs_build(N); end

@testset "cross-shape state gather is grid-independent" begin
    N1, N2 = 8, 24
    A = _cs_run(N1)
    B = _cs_run(N2)

    @testset "both array equations took the affine tier" begin
        @test get(A.tally, :affine, 0) == 2
        @test get(A.tally, :percell_acc, 0) == 0
        @test A.tally == B.tally
    end

    @testset "the box count does not grow with the grid" begin
        @test A.n_kernels == B.n_kernels
    end

    @testset "no per-cell slot table: descriptor tables stay small" begin
        # Pre-fix this was one `Int` per box CELL per cross-shape lane, i.e.
        # Θ(N²); with the identity slot block it is Θ(N) (the `a` column) and
        # the same object is shared, so the 3× grid must not be 9× the table.
        @test B.conn_entries <= 4 * A.conn_entries
        @test B.conn_entries < N2 * N2
    end

    @testset "RHS is bit-identical to the pre-fix build" begin
        for N in (N1, N2)
            post = _cs_run(N)
            pre  = _cs_run_pre(N)
            @test post.du == pre.du
            @test all(isfinite, post.du)
        end
    end

    @testset "the values are right" begin
        # du[u[i,j]] = a[j]·u[i,j]; du[a[j]] = 0
        vm = ESM_CS._build_evaluator_impl(_cs_model(N1);
                initial_conditions = Dict("a[1]" => 0.0))[5]
        for j in 1:N1, i in 1:N1
            aj = 0.5 + 0.1j
            uij = sin(0.3i) + 0.2j
            @test A.du[vm["u[$i,$j]"]] ≈ aj * uij
        end
        for j in 1:N1
            @test A.du[vm["a[$j]"]] == 0.0
        end
    end
end

# The lane-affine STATE BOX is licensed by a PROOF, not by a sample.
#
# `_derive_lane_repl` verifies a derived affine slot map at the 2^D box corners
# and at `rep + e_d`. That is a sample of 2^D + D cells; it cannot see the box
# interior. A state subscript may be arbitrary data — an unstructured
# `index(conn, i)` gather — so agreement at the corners says nothing about the
# cells between them, exactly as the `LANE_CONST` branch's comment says of the
# value fold it removed for the same reason.
#
# The guard is that every subscript is STRUCTURALLY affine in the output loop
# indices (`_affine_idx_expr`), which is a property of the expression and holds
# at every cell. This pins it: a CROSS-SHAPE gather (so the Δ test fails and the
# state-box branch is reached) whose connectivity is the identity except for one
# swapped INTERIOR cell — affine at every corner and at `rep + e_d`, and far
# enough from both ends that `_AFFINE_STABLE_GUARD` retires the cut scan before
# it gets there. Without the guard the interior cell reads the wrong slot,
# silently, with no error and no fallback.
@testset "cross-shape state box is not licensed by corner agreement" begin
    N, i0 = 40, 20
    perm = collect(1:N); perm[i0] = i0 + 1        # identity but for one swap
    vars = Dict{String,ESM_CS.ModelVariable}(
        "w" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable),
        "u" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable))
    ao2(body) = ESM_CS.OpExpr("faq", ESM_CS.ASTExpr[];
        output_idx = Any["i", "j"], expr_body = body,
        ranges = Dict("i" => [1, N], "j" => [1, N]))
    model = ESM_CS.Model(vars, [
        ESM_CS.Equation(_ao1(_Didx("w", _v("i")), "i", 1, N),
                        _ao1(_n(0.0), "i", 1, N)),
        ESM_CS.Equation(ao2(_Didx("u", _v("i"), _v("j"))),
                        ao2(_idx("w", _idx("conn", _v("i")))))])
    ics = Dict{String,Float64}()
    for k in 1:N
        ics["w[$k]"] = 10.0k
        for j in 1:N; ics["u[$k,$j]"] = 0.0; end
    end
    ca = Dict("conn" => Float64.(perm))

    ev(envs...) = withenv(envs...) do
        f, u0, p, _t, vm, _d = ESM_CS._build_evaluator_impl(model;
            initial_conditions = ics, const_arrays = ca)
        du = fill(NaN, length(u0)); f(du, u0, p, 0.0)
        (du = du, vm = vm, u0 = u0)
    end

    got = ev()
    ref = ev("ESS_STENCIL_DISABLE" => "1")        # forced per-cell walk
    @test got.du == ref.du
    # ... and spelled out around the swap, so a failure names the cell rather
    # than a whole vector (`i0` is the wrong one; its neighbours are the
    # control that the rest of the box is still right).
    for i in (i0 - 1, i0, i0 + 1), j in (1, N)
        @test got.du[got.vm["u[$i,$j]"]] == got.u0[got.vm["w[$(perm[i])]"]]
    end
end
