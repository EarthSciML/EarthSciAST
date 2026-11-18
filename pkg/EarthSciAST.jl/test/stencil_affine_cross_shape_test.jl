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
# the per-cell reference `compiler=:interpreter` builds.
using Test
using EarthSciAST
include("testutils.jl")
const ESM_CS = EarthSciAST

# The build flattens its model into component `M`: every declared name it
# takes or returns is qualified. The const arrays and live buffers these models
# read are not declared, so they keep the spelling the equations use.
_cs_q(d) = Dict{String, Any}("M.$k" => v for (k, v) in d)

# D(a[j])   = 0                          — a 1-D column, extent N
# D(u[i,j]) = a[j] * u[i,j]              — a 2-D field, extent N×N
# `a[j]` read from the (i,j) loop is the cross-shape gather: slot(a[j]) is
# affine in `j` alone while the output slot moves with both `i` and `j`.
function _cs_model(N)
    vars = Dict{String, ESM_CS.ModelVariable}(
        "a" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable; default = 0.0),
        "u" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable; default = 0.0)
    )
    ao2(body, lhs) = ESM_CS.OpExpr(
        "faq", ESM_CS.ASTExpr[];
        output_idx = Any["i", "j"], expr_body = body,
        ranges = Dict("i" => [1, N], "j" => [1, N])
    )
    return ESM_CS.Model(
        vars, [
            ESM_CS.Equation(
                _ao1(_Didx("a", _v("j")), "j", 1, N),
                _ao1(_n(0.0), "j", 1, N)
            ),
            ESM_CS.Equation(
                ao2(_Didx("u", _v("i"), _v("j")), nothing),
                ao2(
                    _op(
                        "*", _idx("a", _v("j")),
                        _idx("u", _v("i"), _v("j"))
                    ), nothing
                )
            ),
        ]
    )
end

function _cs_build(N; compiler::Symbol = :native)
    ics = Dict{String, Float64}()
    for j in 1:N
        ics["a[$j]"] = 0.5 + 0.1j
        for i in 1:N
            ics["u[$i,$j]"] = sin(0.3i) + 0.2j
        end
    end
    f, u0, p, _t, vm, rep = ESM_CS.Internal.build(
        _cs_model(N);
        initial_conditions = _cs_q(ics), compiler = compiler
    )
    du = zero(u0); f(du, u0, p, 0.0)
    ks = rep.kernels
    return (
        u0 = u0, du = du, diag = rep.stats, kernels = ks,
        tally = rep.counts,
        n_kernels = length(ks),
        conn_entries = sum(
            sum(length(d.conn) for d in K.acc; init = 0)
                for K in ks; init = 0
        ),
    )
end

_cs_run(N) = _cs_build(N)
_cs_run_ref(N) = _cs_build(N; compiler = :interpreter)

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

    @testset "RHS is bit-identical to the per-cell reference" begin
        for N in (N1, N2)
            post = _cs_run(N)
            ref = _cs_run_ref(N)
            @test post.du == ref.du
            @test all(isfinite, post.du)
        end
    end

    @testset "the values are right" begin
        # du[u[i,j]] = a[j]·u[i,j]; du[a[j]] = 0
        vm = ESM_CS.Internal.build(
            _cs_model(N1);
            initial_conditions = Dict("M.a[1]" => 0.0)
        ).var_map
        for j in 1:N1, i in 1:N1
            aj = 0.5 + 0.1j
            uij = sin(0.3i) + 0.2j
            @test A.du[vm["M.u[$i,$j]"]] ≈ aj * uij
        end
        for j in 1:N1
            @test A.du[vm["M.a[$j]"]] == 0.0
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
    vars = Dict{String, ESM_CS.ModelVariable}(
        "w" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable; default = 0.0),
        "u" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable; default = 0.0)
    )
    ao2(body) = ESM_CS.OpExpr(
        "faq", ESM_CS.ASTExpr[];
        output_idx = Any["i", "j"], expr_body = body,
        ranges = Dict("i" => [1, N], "j" => [1, N])
    )
    model = ESM_CS.Model(
        vars, [
            ESM_CS.Equation(
                _ao1(_Didx("w", _v("i")), "i", 1, N),
                _ao1(_n(0.0), "i", 1, N)
            ),
            ESM_CS.Equation(
                ao2(_Didx("u", _v("i"), _v("j"))),
                ao2(_idx("w", _idx("conn", _v("i"))))
            ),
        ]
    )
    ics = Dict{String, Float64}()
    for k in 1:N
        ics["w[$k]"] = 10.0k
        for j in 1:N
            ics["u[$k,$j]"] = 0.0
        end
    end
    ca = Dict("conn" => Float64.(perm))

    function ev(compiler = :native)
        f, u0, p, _t, vm, _ = ESM_CS.Internal.build(
            model;
            initial_conditions = _cs_q(ics), const_arrays = ca, compiler = compiler
        )
        du = fill(NaN, length(u0)); f(du, u0, p, 0.0)
        return (du = du, vm = vm, u0 = u0)
    end

    got = ev()
    ref = ev(:interpreter)                        # the per-cell walk
    @test got.du == ref.du
    # ... and spelled out around the swap, so a failure names the cell rather
    # than a whole vector (`i0` is the wrong one; its neighbours are the
    # control that the rest of the box is still right).
    for i in (i0 - 1, i0, i0 + 1), j in (1, N)
        @test got.du[got.vm["M.u[$i,$j]"]] == got.u0[got.vm["M.w[$(perm[i])]"]]
    end
end

# The SAME defect on a SAME-SHAPE gather. When the gathered array is laid out
# like the output, the slot offset `Δ` is tested at the box corners and a
# uniform `Δ` lowers the lane to `_AccStateAffine`. That test is a sample too:
# an `index(conn, i)` subscript that is the identity at every corner but swaps
# one interior cell has `Δ = 0` at every corner and a different slot inside.
@testset "same-shape state gather is not licensed by corner agreement" begin
    function check(model, ics, ca, cells; pa = Dict{String, Any}())
        function ev(compiler = :native)
            f, u0, p, _t, vm, _ = ESM_CS.Internal.build(
                model;
                initial_conditions = _cs_q(ics), const_arrays = ca,
                param_arrays = Dict(k => copy(v) for (k, v) in pa),
                compiler = compiler
            )
            du = fill(NaN, length(u0)); f(du, u0, p, 0.0)
            return (du = du, vm = vm)
        end
        got = ev()
        ref = ev(:interpreter)                    # the per-cell walk
        @test got.du == ref.du
        for c in cells
            @test got.du[got.vm["M.$c"]] == ref.du[ref.vm["M.$c"]]
        end
    end
    vars() = Dict{String, ESM_CS.ModelVariable}(
        "w" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable; default = 0.0),
        "u" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable; default = 0.0)
    )

    # 1-D: D(u[i]) = w[conn[i]]
    N, i0 = 40, 20
    perm = collect(1:N); perm[i0] = i0 + 1
    m1 = ESM_CS.Model(
        vars(), [
            ESM_CS.Equation(_ao1(_Didx("w", _v("i")), "i", 1, N), _ao1(_n(0.0), "i", 1, N)),
            ESM_CS.Equation(
                _ao1(_Didx("u", _v("i")), "i", 1, N),
                _ao1(_idx("w", _idx("conn", _v("i"))), "i", 1, N)
            ),
        ]
    )
    ics1 = Dict{String, Float64}()
    for k in 1:N
        ics1["w[$k]"] = 10.0k; ics1["u[$k]"] = 0.0
    end
    check(m1, ics1, Dict("conn" => Float64.(perm)), ["u[$(i0 - 1)]", "u[$i0]", "u[$(i0 + 1)]"])

    # 2-D: D(u[i,j]) = w[conn[i], j]
    ao2(body) = ESM_CS.OpExpr(
        "faq", ESM_CS.ASTExpr[];
        output_idx = Any["i", "j"], expr_body = body,
        ranges = Dict("i" => [1, N], "j" => [1, N])
    )
    m2 = ESM_CS.Model(
        vars(), [
            ESM_CS.Equation(ao2(_Didx("w", _v("i"), _v("j"))), ao2(_n(0.0))),
            ESM_CS.Equation(
                ao2(_Didx("u", _v("i"), _v("j"))),
                ao2(_idx("w", _idx("conn", _v("i")), _v("j")))
            ),
        ]
    )
    ics2 = Dict{String, Float64}()
    for k in 1:N, j in 1:N
        ics2["w[$k,$j]"] = 10.0k + j; ics2["u[$k,$j]"] = 0.0
    end
    check(m2, ics2, Dict("conn" => Float64.(perm)), ["u[$i0,1]", "u[$i0,$N]", "u[$(i0 + 1),1]"])

    # A CONST array read through the same connectivity: the linear index is
    # derived at `rep`, `rep + e_d` and checked at the corners, so an interior
    # swap reads the wrong element, and a table that is 1 at every corner derives
    # a zero stride and folds the whole box to one literal.
    cvars = Dict{String, ESM_CS.ModelVariable}(
        "u" => ESM_CS.ModelVariable(ESM_CS.UnknownVariable; default = 0.0)
    )
    mc = ESM_CS.Model(
        cvars, [
            ESM_CS.Equation(
                _ao1(_Didx("u", _v("i")), "i", 1, N),
                _ao1(_idx("c", _idx("conn", _v("i"))), "i", 1, N)
            ),
        ]
    )
    icsc = Dict{String, Float64}("u[$k]" => 0.0 for k in 1:N)
    cvals = Float64.(10 .* (1:N))
    check(mc, icsc, Dict("conn" => Float64.(perm), "c" => cvals), ["u[$i0]"])
    ones_but = ones(N); ones_but[i0] = 7
    check(mc, icsc, Dict("conn" => ones_but, "c" => cvals), ["u[$i0]"])

    # A GHOST at every corner is not a ghost box: connectivity out of range
    # everywhere but one interior cell folded that cell to 0.0 too.
    ghost_but = fill(Float64(N + 5), N); ghost_but[i0] = 3
    check(m1, ics1, Dict("conn" => ghost_but), ["u[$i0]"])

    # ... and not even for an affine subscript: `3i - 40` over 1:40 is below the
    # bounds at i = 1, above them at i = 40, and in range for 14 ≤ i ≤ 26.
    ma = ESM_CS.Model(
        vars(), [
            ESM_CS.Equation(_ao1(_Didx("w", _v("i")), "i", 1, N), _ao1(_n(0.0), "i", 1, N)),
            ESM_CS.Equation(
                _ao1(_Didx("u", _v("i")), "i", 1, N),
                _ao1(
                    _idx("w", _op("-", _op("*", _i(3), _v("i")), _i(40))),
                    "i", 1, N
                )
            ),
        ]
    )
    check(ma, ics1, Dict{String, Any}(), ["u[13]", "u[14]", "u[20]", "u[26]", "u[27]"])

    # The LIVE-FORCING (pgather) lane derives its flat buffer index the same
    # way the const lane derives its linear index, so the same connectivity
    # swap sent it to the wrong buffer element.
    mp = ESM_CS.Model(
        cvars, [
            ESM_CS.Equation(
                _ao1(_Didx("u", _v("i")), "i", 1, N),
                _ao1(_idx("forcing", _idx("conn", _v("i"))), "i", 1, N)
            ),
        ]
    )
    check(
        mp, icsc, Dict("conn" => Float64.(perm)), ["u[$i0]"];
        pa = Dict("forcing" => cvals)
    )
end
