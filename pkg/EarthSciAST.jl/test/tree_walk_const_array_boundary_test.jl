# Tests for generic const_array boundary policy in tree_walk (ess-gj4).
#
# A const_array stencil gather at an out-of-range index resolves per a declared
# per-dimension boundary policy instead of erroring:
#   :periodic — wrap into 1..N via mod1 (matches the state-var periodic fold)
#   :clamp    — edge-extend (clamp to 1..N); the correct finite policy for a
#               metric/geometry factor at a non-periodic boundary (NOT zero-ghost)
# A const_array WITHOUT a declared policy keeps throwing E_TREEWALK_CONSTARRAY_OOB,
# so genuine out-of-bounds bugs in connectivity / stencil-weight factors stay caught.
#
# Covers both gather sites: the value gather in `_resolve_indices` (the covariant
# metric case) and the index-position indirect gather in `_eval_const_int`.

using Test
using EarthSciAST

include("testutils.jl")  # _n/_i/_v/_op/_idx builder quartet

const ESM = EarthSciAST

@testset "const_array boundary policy (ess-gj4)" begin

    # ------------------------------------------------------------------
    # A. Value gather (_resolve_indices): D(y[i]) = index(M, i+1)
    #    M has size N; at i=N the gather index i+1 = N+1 is out of range.
    # ------------------------------------------------------------------
    @testset "A. value gather honors clamp / periodic / throw" begin
        N = 4
        M = [10.0, 20.0, 30.0, 40.0]
        vars = Dict("y" => ModelVariable(UnknownVariable))
        lhs = _faq1d(_D_idx("y", _v("i")), "i", 1, N)
        rhs = _faq1d(_idx("M", _op("+", _v("i"), _i(1))), "i", 1, N)
        model = ESM.Model(vars, [ESM.Equation(lhs, rhs)])
        ics = Dict("y[$k]" => 0.0 for k in 1:N)

        # clamp: M[5] -> M[4] = 40 (edge-extend)
        # The boundary fold is in the affine per-cell signature (a cut at the
        # clamp transition), so the DEFAULT build lands on the access-kernel
        # path — pinned here so a signature regression can't silently demote
        # these equations to a fallback tier.
        f!, u0, p, _, vmap, _diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics, const_arrays=Dict("M" => M),
            const_array_boundaries=Dict("M" => [:clamp]))
        @test _diag.n_acc_kernels >= 1
        @test _diag.n_vec_kernels == 0
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["y[1]"]], 20.0; rtol=1e-12)   # M[2], in range
        @test isapprox(du[vmap["y[3]"]], 40.0; rtol=1e-12)   # M[4], in range
        @test isapprox(du[vmap["y[4]"]], 40.0; rtol=1e-12)   # clamp M[5] -> M[4]

        # periodic: M[5] -> M[1] = 10 (wrap)
        f!, u0, p, _, vmap = EarthSciAST._build_evaluator(model; initial_conditions=ics,
            const_arrays=Dict("M" => M), const_array_boundaries=Dict("M" => [:periodic]))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["y[1]"]], 20.0; rtol=1e-12)
        @test isapprox(du[vmap["y[4]"]], 10.0; rtol=1e-12)   # wrap M[5] -> M[1]

        # no declared policy -> the OOB gather throws (bug-catching preserved)
        @test_throws ESM.TreeWalkError EarthSciAST._build_evaluator(model; initial_conditions=ics,
            const_arrays=Dict("M" => M))
    end

    # ------------------------------------------------------------------
    # B. Index-position indirect gather (_eval_const_int):
    #    D(y[i]) = index(u, index(conn, i+1)) — conn is a connectivity factor.
    # ------------------------------------------------------------------
    @testset "B. index-position gather honors clamp / periodic / throw" begin
        N = 4
        conn = [2.0, 3.0, 4.0, 1.0]    # permutation of valid u indices
        vars = Dict("y" => ModelVariable(UnknownVariable),
                    "u" => ModelVariable(UnknownVariable))
        lhs = _faq1d(_D_idx("y", _v("i")), "i", 1, N)
        rhs = _faq1d(_idx("u", _idx("conn", _op("+", _v("i"), _i(1)))), "i", 1, N)
        model = ESM.Model(vars, [ESM.Equation(lhs, rhs)])
        ics = Dict{String,Float64}()
        for k in 1:N
            ics["y[$k]"] = 0.0
            ics["u[$k]"] = 10.0 * k
        end

        # clamp: conn[5] -> conn[4] = 1 -> u[1] = 10
        # The indirect-through-const state gather also lands on the access-kernel
        # path (Δ-keyed cuts / indirect slot table) — pinned like testset A.
        f!, u0, p, _, vmap, _diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics, const_arrays=Dict("conn" => conn),
            const_array_boundaries=Dict("conn" => [:clamp]))
        @test _diag.n_acc_kernels >= 1
        @test _diag.n_vec_kernels == 0
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["y[1]"]], 30.0; rtol=1e-12)   # conn[2]=3 -> u[3]
        @test isapprox(du[vmap["y[2]"]], 40.0; rtol=1e-12)   # conn[3]=4 -> u[4]
        @test isapprox(du[vmap["y[4]"]], 10.0; rtol=1e-12)   # clamp conn[5]->conn[4]=1 -> u[1]

        # periodic: conn[5] -> conn[1] = 2 -> u[2] = 20
        f!, u0, p, _, vmap = EarthSciAST._build_evaluator(model; initial_conditions=ics,
            const_arrays=Dict("conn" => conn), const_array_boundaries=Dict("conn" => [:periodic]))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["y[4]"]], 20.0; rtol=1e-12)   # wrap conn[5]->conn[1]=2 -> u[2]

        @test_throws ESM.TreeWalkError EarthSciAST._build_evaluator(model; initial_conditions=ics,
            const_arrays=Dict("conn" => conn))
    end

    # ------------------------------------------------------------------
    # C. BoundedConstArray + _resolve_const_index units
    # ------------------------------------------------------------------
    @testset "C. BoundedConstArray / _resolve_const_index units" begin
        a = ESM.BoundedConstArray{1}([5.0, 6.0, 7.0], (:clamp,))
        @test size(a) == (3,)
        @test ndims(a) == 1
        @test a[2] == 6.0
        @test Float64(a[3]) == 7.0

        # in-range passes through regardless of policy
        @test ESM._resolve_const_index(a, "a", 1, 2, 3) == 2
        # clamp = edge-extend
        @test ESM._resolve_const_index(a, "a", 1, 0, 3) == 1
        @test ESM._resolve_const_index(a, "a", 1, 9, 3) == 3

        # periodic = mod1 wrap
        b = ESM.BoundedConstArray{1}([5.0, 6.0, 7.0], (:periodic,))
        @test ESM._resolve_const_index(b, "b", 1, 0, 3) == 3    # mod1(0,3)
        @test ESM._resolve_const_index(b, "b", 1, 4, 3) == 1    # mod1(4,3)
        @test ESM._resolve_const_index(b, "b", 1, -1, 3) == 2   # mod1(-1,3)

        # plain array (no policy): in-range ok, OOB throws
        plain = [1.0, 2.0, 3.0]
        @test ESM._resolve_const_index(plain, "p", 1, 2, 3) == 2
        @test_throws ESM.TreeWalkError ESM._resolve_const_index(plain, "p", 1, 4, 3)

        # 2D mixed policy: dim 1 clamp, dim 2 periodic
        m = ESM.BoundedConstArray{2}(reshape(collect(1.0:6.0), 2, 3), (:clamp, :periodic))
        @test ESM._resolve_const_index(m, "m", 1, 0, 2) == 1    # clamp dim 1
        @test ESM._resolve_const_index(m, "m", 1, 5, 2) == 2    # clamp dim 1
        @test ESM._resolve_const_index(m, "m", 2, 4, 3) == 1    # mod1(4,3) dim 2
        @test ESM._resolve_const_index(m, "m", 2, 0, 3) == 3    # mod1(0,3) dim 2
    end

    # ------------------------------------------------------------------
    # D. Boundary-spec validation
    # ------------------------------------------------------------------
    @testset "D. boundary-spec validation errors" begin
        N = 3
        M = [1.0, 2.0, 3.0]
        vars = Dict("y" => ModelVariable(UnknownVariable))
        lhs = _faq1d(_D_idx("y", _v("i")), "i", 1, N)
        rhs = _faq1d(_idx("M", _v("i")), "i", 1, N)
        model = ESM.Model(vars, [ESM.Equation(lhs, rhs)])
        ics = Dict("y[$k]" => 0.0 for k in 1:N)

        # wrong rank: 1D array, 2-dim boundary spec
        @test_throws ESM.TreeWalkError EarthSciAST._build_evaluator(model; initial_conditions=ics,
            const_arrays=Dict("M" => M), const_array_boundaries=Dict("M" => [:clamp, :clamp]))
        # unknown policy kind
        @test_throws ESM.TreeWalkError EarthSciAST._build_evaluator(model; initial_conditions=ics,
            const_arrays=Dict("M" => M), const_array_boundaries=Dict("M" => [:reflect]))
    end

    # ------------------------------------------------------------------
    # E. An out-of-range read under a guard the build cannot decide is
    #    deferred to run time. That is the guarded site's answer only: the
    #    same (shared) node read with no guard still raises at build, even
    #    when the guarded site was resolved first through the build memo.
    # ------------------------------------------------------------------
    @testset "E. a guarded deferral does not reach an unguarded read" begin
        c = [1.0, 2.0, 3.0]
        cas = Dict{String,Any}("c" => c)
        avi = Dict{String,Tuple{Vector{Int},Vector{Int}}}()
        vm = Dict{String,Int}()
        oob = _idx("c", _i(5))                          # ONE node, read at both sites
        guarded = _op("ifelse", _op(">", _v("p"), _n(0)), oob, _n(0))
        res(e, memo) = ESM._resolve_indices(e, avi, vm, cas, ESM._EMPTY_PGATHER, memo)
        oob_code(f) = try
            f(); nothing
        catch err
            err isa ESM.TreeWalkError ? err.code : rethrow()
        end

        memo = ESM._BuildMemo()
        @test oob_code(() -> res(guarded, memo)) === nothing      # deferred, no error
        @test oob_code(() -> res(oob, memo)) == "E_TREEWALK_CONSTARRAY_OOB"
        @test oob_code(() -> res(_op("+", guarded, oob), ESM._BuildMemo())) ==
              "E_TREEWALK_CONSTARRAY_OOB"
        # A guard the build decides as taken raises there too, memo or not.
        taken = _op("ifelse", _op(">", _n(1), _n(0)), oob, _n(0))
        @test oob_code(() -> res(taken, ESM._BuildMemo())) == "E_TREEWALK_CONSTARRAY_OOB"

        # Through a build: the unguarded read fails the build under both
        # compilers, whichever order the two sites are met in.
        N = 2
        vars = Dict("y" => ModelVariable(UnknownVariable),
                    "p" => ModelVariable(ParameterVariable; default=1.0))
        ics = Dict("y[$k]" => 0.0 for k in 1:N)
        for body in (_op("+", guarded, oob), _op("+", oob, guarded))
            model = ESM.Model(vars, [ESM.Equation(_faq1d(_D_idx("y", _v("i")), "i", 1, N),
                                                  _faq1d(body, "i", 1, N))])
            for comp in (:native, :interpreter)
                @test oob_code(() -> EarthSciAST._build_evaluator(model;
                    initial_conditions=ics, const_arrays=Dict("c" => c),
                    compiler=comp)) == "E_TREEWALK_CONSTARRAY_OOB"
            end
        end
    end
end
