# Vectorized array-kernel RHS property tests (ess-dhq).
#
# Verifies that the tree-walk runner evaluates discretized `arrayop` derivative
# equations as WHOLE-ARRAY kernels whose compiled-node count is independent of
# the grid size N (no per-cell scalarization), while preserving numeric results
# identical to the analytic stencil/reduction.
#
# Property under test (the "no scalarization" hard requirement): for the same
# equation at different grid sizes, the number of compiled array kernels and the
# total number of `_VecNode`s are EQUAL — only the embedded slot/value vectors
# grow with N. Contrast the previous behaviour, where the compiled RHS held one
# scalar `_Node` per cell (an O(N) node list).

using Test
using EarthSciAST

include("testutils.jl")  # _n/_i/_v/_op/_idx builder quartet

const ESM = EarthSciAST

# `got` and `ref` agree bit-for-bit, treating NaN as equal to NaN (interp clamps
# / blends propagate the query NaN, whose payload is implementation-defined).
_bitsame(got, ref) = (got === ref) || (isnan(got) && isnan(ref))

# A 2-D field with a bare-aggregate coordinate initial condition: ic(psi) is a
# closed-form signed-distance field over [1,N]×[1,N]. Exercises the compile-once
# field-ic fast path (indices bound as params, compiled a SINGLE time) against the
# per-cell resolve+compile fallback. Mirrors the wildland-fire InitialPerimeter IC.
function _fieldic_model(N)
    vars = Dict("psi" => ModelVariable(StateVariable; shape=["i", "j"]))
    dref = _op("D", _idx("psi", _v("i"), _v("j")); wrt="t")
    drhs = _op("neg", _idx("psi", _v("i"), _v("j")))
    dlhs = OpExpr("arrayop", ESM.Expr[]; output_idx=Any["i", "j"],
        expr_body=dref, ranges=Dict("i" => [1, N], "j" => [1, N]))
    drhs_ao = OpExpr("arrayop", ESM.Expr[]; output_idx=Any["i", "j"],
        expr_body=drhs, ranges=Dict("i" => [1, N], "j" => [1, N]))
    icbody = _op("-",
        _op("sqrt", _op("+",
            _op("^", _op("-", _op("*", _op("-", _v("i"), _n(0.5)), _n(2.0)), _n(1.0 * N)), _i(2)),
            _op("^", _op("-", _op("*", _op("-", _v("j"), _n(0.5)), _n(2.0)), _n(1.0 * N)), _i(2)))),
        _n(0.3 * N))
    ic_agg = OpExpr("aggregate", ESM.Expr[]; output_idx=Any["i", "j"],
        expr_body=icbody, ranges=Dict("i" => [1, N], "j" => [1, N]))
    ESM.Model(vars, [ESM.Equation(dlhs, drhs_ao),
                     ESM.Equation(_op("ic", _v("psi")), ic_agg)])
end

@testset "tree_walk vectorized array-kernel RHS (ess-dhq)" begin

    @testset "N-independent compiled-kernel count (two+ grid sizes)" begin
        diags = map((8, 16, 64)) do N
            ics = Dict("u[$k]" => 0.0 for k in 1:N)
            _, u0, _, _, _, d = ESM._build_evaluator_impl(_stencil_model(N);
                                                          initial_conditions=ics)
            @test length(u0) == N                 # state DOES grow with N …
            d
        end
        # … but the compiled array-kernel structure does NOT.
        @test diags[1].n_vec_kernels == diags[2].n_vec_kernels == diags[3].n_vec_kernels
        @test diags[1].template_node_count ==
              diags[2].template_node_count == diags[3].template_node_count
        @test diags[1].n_vec_kernels >= 1
        # The array equation produced ZERO per-cell scalar RHS entries: it is a
        # whole-array kernel, not an O(N) scalar node list.
        @test all(d -> d.n_scalar_entries == 0, diags)
    end

    @testset "numeric identity vs analytic stencil (rtol 1e-12)" begin
        for N in (8, 32)
            ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
            f!, u0, p, _, vmap = build_evaluator(_stencil_model(N);
                                                 initial_conditions=ics)
            du = similar(u0); f!(du, u0, p, 0.0)
            uv(k) = (1 <= k <= N) ? (sin(0.3k) + 0.1k) : 0.0   # ghost → 0
            for i in 1:N
                expected = uv(i - 1) - 2 * uv(i) + uv(i + 1)
                @test isapprox(du[vmap["u[$i]"]], expected; rtol=1e-12, atol=1e-12)
            end
        end
    end

    @testset "contraction (reduction) arrayop vectorizes + stays correct" begin
        # D(y[i]) = Σ_{k=1..3} A[i,k]·x[k]  (sum_product semiring)
        vars = Dict("y" => ModelVariable(StateVariable),
                    "x" => ModelVariable(StateVariable))
        body = _op("*", _idx("A", _v("i"), _v("k")), _idx("x", _v("k")))
        rhs = OpExpr("arrayop", ESM.Expr[]; output_idx=Any["i"], expr_body=body,
                     ranges=Dict("i" => [1, 2], "k" => [1, 3]), reduce="+")
        m = ESM.Model(vars, [ESM.Equation(_ao1(_Didx("y", _v("i")), "i", 1, 2), rhs)])
        A = [1.0 2.0 3.0; 4.0 5.0 6.0]
        ics = Dict("y[1]" => 0.0, "y[2]" => 0.0,
                   "x[1]" => 1.0, "x[2]" => 1.0, "x[3]" => 1.0)
        f!, u0, p, _, vmap = build_evaluator(m; initial_conditions=ics,
                                             const_arrays=Dict("A" => A))
        _, _, _, _, _, d = ESM._build_evaluator_impl(m; initial_conditions=ics,
                                                     const_arrays=Dict("A" => A))
        @test d.n_vec_kernels >= 1
        @test d.n_scalar_entries == 0
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["y[1]"]], 6.0;  rtol=1e-12)
        @test isapprox(du[vmap["y[2]"]], 15.0; rtol=1e-12)
    end

    # ess-wrh: the de-boxed whole-array `interp.*` kernels must reproduce the
    # scalar `:fn` arm bit-for-bit on the fiddly corners (endpoint clamps, exact
    # on-knot queries, NaN propagation, Inf-sentinel table entries). We drive one
    # arrayop whose per-cell query `u[i]` is set to each corner via the IC, run a
    # single `f!`, and compare every lane to `evaluate_closed_function` (the
    # cross-binding scalar contract). Both routes call the same `_interp_*_core`,
    # so this guards the wiring (arg order, child selection, clamp endpoints) and
    # the build-time spec validation/coercion.
    @testset "interp.* vectorized arm is bit-identical to scalar :fn (ess-wrh)" begin
        # Map per-cell queries through a one-line arrayop and read the lanes back.
        function run_unary_interp(fname, const2, queries)
            N = length(queries)
            body = _op("fn", _idx("u", _v("i")), _const(const2); name=fname)
            if fname != "interp.searchsorted"
                # linear/bilinear take (table, axis, x); searchsorted takes (x, xs)
                error("run_unary_interp only models the (x, const) shape")
            end
            m = ESM.Model(Dict("u" => ModelVariable(StateVariable)),
                          [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                        _ao1(body, "i", 1, N))])
            ics = Dict("u[$i]" => queries[i] for i in 1:N)
            f!, u0, p, _, vmap = build_evaluator(m; initial_conditions=ics)
            du = similar(u0); f!(du, u0, p, 0.0)
            return [du[vmap["u[$i]"]] for i in 1:N]
        end
        # linear: (table, axis, u[i])
        function run_linear(table, axis, queries)
            N = length(queries)
            body = _op("fn", _const(table), _const(axis), _idx("u", _v("i")); name="interp.linear")
            m = ESM.Model(Dict("u" => ModelVariable(StateVariable)),
                          [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                        _ao1(body, "i", 1, N))])
            ics = Dict("u[$i]" => queries[i] for i in 1:N)
            f!, u0, p, _, vmap = build_evaluator(m; initial_conditions=ics)
            du = similar(u0); f!(du, u0, p, 0.0)
            return [du[vmap["u[$i]"]] for i in 1:N]
        end

        @testset "linear: clamps / on-knot / midpoints / NaN" begin
            table = [10.0, 20.0, 40.0, 80.0, 160.0]; axis = [0.0, 1.0, 2.0, 3.0, 4.0]
            qs = [0.0, 4.0, -5.0, 99.0, 0.5, 1.5, 2.0, 2.25, NaN]
            got = run_linear(table, axis, qs)
            for (i, q) in enumerate(qs)
                ref = Float64(ESM.evaluate_closed_function("interp.linear", Any[table, axis, q]))
                @test _bitsame(got[i], ref)
            end
        end

        @testset "linear: Inf-sentinel (1e25) table entry" begin
            table = [1.0, 1.0e25, 2.0, 3.0, 4.0]; axis = [0.0, 1.0, 2.0, 3.0, 4.0]
            qs = [1.0, 0.5, 1.5, 2.0, NaN]   # on the sentinel knot, either side, NaN
            got = run_linear(table, axis, qs)
            for (i, q) in enumerate(qs)
                ref = Float64(ESM.evaluate_closed_function("interp.linear", Any[table, axis, q]))
                @test _bitsame(got[i], ref)
            end
        end

        @testset "searchsorted: below / boundary / above / duplicates / NaN" begin
            xs = [1.0, 2.0, 2.0, 2.0, 3.0]
            qs = [0.5, 1.0, 2.0, 1.999999, 3.0, 10.0, NaN]
            got = run_unary_interp("interp.searchsorted", xs, qs)
            for (i, q) in enumerate(qs)
                ref = Float64(ESM.evaluate_closed_function("interp.searchsorted", Any[q, xs]))
                @test _bitsame(got[i], ref)
            end
        end

        @testset "bilinear: per-axis clamps / corner / NaN" begin
            table = Any[Any[1.0, 1.5, 2.0], Any[1.1, 1.6, 2.1], Any[1.2, 1.7, 2.2]]
            ax = [10.0, 100.0, 1000.0]; ay = [0.1, 0.5, 1.0]
            # x = u[i] (state, GATHER), y = cz (parameter, broadcast).
            xqs = [10.0, 1000.0, 5.0, 2000.0, 55.0, 500.0, NaN]
            yval = 0.5
            N = length(xqs)
            body = _op("fn", _const(table), _const(ax), _const(ay),
                       _idx("u", _v("i")), _v("cz"); name="interp.bilinear")
            m = ESM.Model(Dict("u" => ModelVariable(StateVariable),
                               "cz" => ModelVariable(ParameterVariable; default=yval)),
                          [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                        _ao1(body, "i", 1, N))])
            ics = Dict("u[$i]" => xqs[i] for i in 1:N)
            f!, u0, p, _, vmap = build_evaluator(m; initial_conditions=ics)
            du = similar(u0); f!(du, u0, p, 0.0)
            for (i, xq) in enumerate(xqs)
                ref = Float64(ESM.evaluate_closed_function("interp.bilinear",
                                                           Any[table, ax, ay, xq, yval]))
                @test _bitsame(du[vmap["u[$i]"]], ref)
            end
        end
    end

    # ess-wrh §4: an interp leaf whose query is a build-time constant folds, at
    # build time, to a single `_VK_LITERAL` — the closed-function call and its box
    # vanish for that leaf. A runtime query (`u[i]`) is not foldable and stays a
    # `_VK_FN` carrying a typed `_Interp*Spec`. We assert at the `_merge_nodes`
    # seam (the fold site) and end-to-end.
    @testset "constant-query interp folds to a literal; runtime query stays a kernel (ess-wrh)" begin
        table = [10.0, 20.0, 40.0, 80.0, 160.0]; axis = [0.0, 1.0, 2.0, 3.0, 4.0]
        mkfn(child) = ESM._mknode(kind=ESM._NK_OP, op=:fn,
            handler=("interp.linear", Any[table, axis]), children=ESM._Node[child])

        @testset "literal on-knot query → _VK_LITERAL = table entry" begin
            lit = mkfn(ESM._mknode(kind=ESM._NK_LITERAL, literal=2.0))  # on knot axis[3]
            merged = ESM._merge_nodes(ESM._Node[lit, lit, lit], 3)
            @test merged.kind === ESM._VK_LITERAL
            @test merged.literal == 40.0
        end

        @testset "literal between-knot query → _VK_LITERAL = exact blend" begin
            lit = mkfn(ESM._mknode(kind=ESM._NK_LITERAL, literal=0.5))  # w=0.5 → 15.0
            merged = ESM._merge_nodes(ESM._Node[lit], 1)
            @test merged.kind === ESM._VK_LITERAL
            @test merged.literal == 15.0
        end

        @testset "searchsorted literal query folds too" begin
            ss = ESM._mknode(kind=ESM._NK_OP, op=:fn,
                handler=("interp.searchsorted", Any[[1.0, 2.0, 3.0, 4.0, 5.0]]),
                children=ESM._Node[ESM._mknode(kind=ESM._NK_LITERAL, literal=2.5)])
            merged = ESM._merge_nodes(ESM._Node[ss], 1)
            @test merged.kind === ESM._VK_LITERAL
            @test merged.literal == 3.0
        end

        @testset "runtime (state) query is NOT folded → _VK_FN + typed spec" begin
            g1 = mkfn(ESM._mknode(kind=ESM._NK_STATE, idx=1))
            g2 = mkfn(ESM._mknode(kind=ESM._NK_STATE, idx=2))
            merged = ESM._merge_nodes(ESM._Node[g1, g2], 2)
            @test merged.kind === ESM._VK_FN
            @test merged.handler isa ESM._InterpLinearSpec
            @test merged.handler.table == table
            @test merged.handler.axis == axis
        end

        @testset "end-to-end: folded constant-query arrayop is correct + 0-alloc" begin
            N = 8
            body = _op("fn", _const(table), _const(axis), _n(2.0); name="interp.linear")
            m = ESM.Model(Dict("u" => ModelVariable(StateVariable)),
                          [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                        _ao1(body, "i", 1, N))])
            ics = Dict("u[$k]" => 0.0 for k in 1:N)
            f!, u0, p, _, vmap = build_evaluator(m; initial_conditions=ics)
            du = similar(u0); f!(du, u0, p, 0.0)
            for i in 1:N
                @test du[vmap["u[$i]"]] == 40.0   # interp.linear(table, axis, 2.0) on knot
            end
            # A folded literal kernel trivially allocates nothing.
            du2 = similar(u0)
            for _ in 1:3; f!(du2, u0, p, 0.0); end
            @test (@allocated f!(du2, u0, p, 0.0)) == 0
        end
    end
end

# The symbolic stencil compiler (ess-perf §4c) builds one spine template per
# structural branch and derives each cell's gather slots by evaluating the index
# expressions per lane, instead of running sub→resolve→compile for every cell.
# It is provably identical to the per-cell path where it applies and falls back
# otherwise. This regression guards that equivalence AND that the fast path fires.
@testset "symbolic stencil compiler ≡ per-cell fallback (differential, ess-perf)" begin
    # `ESS_STENCIL_DISABLE=1` forces the byte-identical per-cell path.
    _build(model, ics, disable) =
        withenv("ESS_STENCIL_DISABLE" => (disable ? "1" : nothing)) do
            build_evaluator(model; initial_conditions=ics)
        end

    # Bit-identical du across interior + ghost-boundary kernels, every grid size.
    @testset "bit-identical du (N=$N)" for N in (8, 32, 64)
        model = _stencil_model(N)
        ics = Dict("u[$k]" => sin(0.7k) - 0.05k for k in 1:N)
        fsym, u0, p, = _build(model, ics, false)
        ffb,  _,  _, = _build(model, ics, true)
        for trial in 0:5
            u = Float64[sin(2.3k + 1.1trial) + 0.3cos(0.9k - trial) for k in 1:N]
            dus = similar(u); duf = similar(u)
            fsym(dus, u, p, Float64(trial))
            ffb(duf, u, p, Float64(trial))
            @test dus == duf   # bit-identical, not merely ≈
        end
    end

    # The fast path actually fires: compiling the spine once (not per cell) must
    # allocate strictly less than the forced per-cell fallback.
    @testset "fast path fires (fewer build allocations)" begin
        N = 128
        model = _stencil_model(N)
        ics = Dict("u[$k]" => 0.0 for k in 1:N)
        _build(model, ics, false); _build(model, ics, true)   # warm up both
        a_sym = @allocated _build(model, ics, false)
        a_fb  = @allocated _build(model, ics, true)
        @test a_sym < a_fb
    end
end

# The compile-once field-ic fast path (ess-perf) compiles a coordinate ic's
# closed-form body ONCE with the loop indices bound as parameters, deriving each
# cell's u0 by re-evaluation instead of a per-cell _index_at_cell→resolve→compile
# rebuild. `_eval_node` computes every leaf in Float64, so an index bound as a
# param equals that index folded to a literal — the u0 field must be bit-identical
# to the forced per-cell path. `ESS_STENCIL_DISABLE=1` forces that per-cell path.
@testset "compile-once field-ic ≡ per-cell fallback (u0, ess-perf)" begin
    _build_u0(N, disable) =
        withenv("ESS_STENCIL_DISABLE" => (disable ? "1" : nothing)) do
            build_evaluator(_fieldic_model(N))[2]   # u0 is the 2nd return value
        end

    @testset "bit-identical u0 (N=$N)" for N in (4, 16, 32)
        u0_fast = _build_u0(N, false)
        u0_slow = _build_u0(N, true)
        @test length(u0_fast) == N * N
        @test u0_fast == u0_slow   # bit-identical initial field, not merely ≈
    end

    @testset "fast path fires (fewer build allocations)" begin
        N = 48
        _build_u0(N, false); _build_u0(N, true)   # warm up both
        a_fast = @allocated _build_u0(N, false)
        a_slow = @allocated _build_u0(N, true)
        @test a_fast < a_slow
    end
end
