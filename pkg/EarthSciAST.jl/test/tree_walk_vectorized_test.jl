# Vectorized array-kernel RHS property tests (ess-dhq).
#
# Verifies that the tree-walk runner evaluates discretized `faq` derivative
# equations as WHOLE-ARRAY kernels whose compiled-node count is independent of
# the grid size N (no per-cell scalarization), while preserving numeric results
# identical to the analytic stencil/reduction.
#
# Property under test (the "no scalarization" hard requirement): for the same
# equation at different grid sizes, the number of compiled array kernels and the
# total number of spine nodes are EQUAL — only the embedded slot/value vectors
# grow with N. Contrast the previous behaviour, where the compiled RHS held one
# scalar `_Node` per cell (an O(N) node list).

using Test
using EarthSciAST

include("testutils.jl")  # _n/_i/_v/_op/_idx builder quartet

const ESM = EarthSciAST

# A 2-D field with a bare-aggregate coordinate initial condition: ic(psi) is a
# closed-form signed-distance field over [1,N]×[1,N]. Exercises the compile-once
# field-ic fast path (indices bound as params, compiled a SINGLE time) against the
# per-cell resolve+compile fallback. Mirrors the wildland-fire InitialPerimeter IC.
function _fieldic_model(N)
    vars = Dict("psi" => ModelVariable(UnknownVariable; shape = ["i", "j"]))
    dref = _op("D", _idx("psi", _v("i"), _v("j")); wrt = "t")
    drhs = _op("neg", _idx("psi", _v("i"), _v("j")))
    dlhs = OpExpr(
        "faq", ESM.ASTExpr[]; output_idx = Any["i", "j"],
        expr_body = dref, ranges = Dict("i" => [1, N], "j" => [1, N])
    )
    drhs_ao = OpExpr(
        "faq", ESM.ASTExpr[]; output_idx = Any["i", "j"],
        expr_body = drhs, ranges = Dict("i" => [1, N], "j" => [1, N])
    )
    icbody = _op(
        "-",
        _op(
            "sqrt", _op(
                "+",
                _op("^", _op("-", _op("*", _op("-", _v("i"), _n(0.5)), _n(2.0)), _n(1.0 * N)), _i(2)),
                _op("^", _op("-", _op("*", _op("-", _v("j"), _n(0.5)), _n(2.0)), _n(1.0 * N)), _i(2))
            )
        ),
        _n(0.3 * N)
    )
    ic_agg = OpExpr(
        "faq", ESM.ASTExpr[]; output_idx = Any["i", "j"],
        expr_body = icbody, ranges = Dict("i" => [1, N], "j" => [1, N])
    )
    return ESM.Model(
        vars, [
            ESM.Equation(dlhs, drhs_ao),
            ESM.Equation(_op("ic", _v("psi")), ic_agg),
        ]
    )
end

@testset "tree_walk vectorized array-kernel RHS (ess-dhq)" begin

    @testset "N-independent compiled-kernel count (two+ grid sizes)" begin
        diags = map((8, 16, 64)) do N
            ics = Dict("u[$k]" => 0.0 for k in 1:N)
            _, u0, _, _, _, d = ESM._build_evaluator_impl(
                _stencil_model(N);
                initial_conditions = ics
            )
            @test length(u0) == N                 # state DOES grow with N …
            d
        end
        # … but the compiled array-kernel structure does NOT. Affine access kernels
        # are the default path, so count array kernels of either flavour (vec + acc)
        # — the intent, "one whole-array kernel per structural box, N-independent",
        # holds whichever path owns the equation.
        akerns(d) = d.n_vec_kernels + d.n_acc_kernels
        @test akerns(diags[1]) == akerns(diags[2]) == akerns(diags[3])
        @test diags[1].template_node_count ==
            diags[2].template_node_count == diags[3].template_node_count
        @test akerns(diags[1]) >= 1
        # The array equation produced ZERO per-cell scalar RHS entries: it is a
        # whole-array kernel, not an O(N) scalar node list.
        @test all(d -> d.n_scalar_entries == 0, diags)
    end

    @testset "numeric identity vs analytic stencil (rtol 1e-12)" begin
        for N in (8, 32)
            ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
            f!, u0, p, _, vmap = EarthSciAST._build_evaluator(
                _stencil_model(N);
                initial_conditions = ics
            )
            du = similar(u0); f!(du, u0, p, 0.0)
            uv(k) = (1 <= k <= N) ? (sin(0.3k) + 0.1k) : 0.0   # ghost → 0
            for i in 1:N
                expected = uv(i - 1) - 2 * uv(i) + uv(i + 1)
                @test isapprox(du[vmap["u[$i]"]], expected; rtol = 1.0e-12, atol = 1.0e-12)
            end
        end
    end

    @testset "contraction (reduction) faq vectorizes + stays correct" begin
        # D(y[i]) = Σ_{k=1..3} A[i,k]·x[k]  (sum_product semiring)
        vars = Dict(
            "y" => ModelVariable(UnknownVariable),
            "x" => ModelVariable(UnknownVariable)
        )
        body = _op("*", _idx("A", _v("i"), _v("k")), _idx("x", _v("k")))
        rhs = OpExpr(
            "faq", ESM.ASTExpr[]; output_idx = Any["i"], expr_body = body,
            ranges = Dict("i" => [1, 2], "k" => [1, 3]), reduce = "+"
        )
        m = ESM.Model(vars, [ESM.Equation(_ao1(_Didx("y", _v("i")), "i", 1, 2), rhs)])
        A = [1.0 2.0 3.0; 4.0 5.0 6.0]
        ics = Dict(
            "y[1]" => 0.0, "y[2]" => 0.0,
            "x[1]" => 1.0, "x[2]" => 1.0, "x[3]" => 1.0
        )
        f!, u0, p, _, vmap = EarthSciAST._build_evaluator(
            m; initial_conditions = ics,
            const_arrays = Dict("A" => A)
        )
        _, _, _, _, _, d = ESM._build_evaluator_impl(
            m; initial_conditions = ics,
            const_arrays = Dict("A" => A)
        )
        # A constant-bound contraction is unrolled onto the affine path by default
        # (acc kernel); either array-kernel flavour satisfies the whole-array intent.
        @test d.n_vec_kernels + d.n_acc_kernels >= 1
        @test d.n_scalar_entries == 0
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["y[1]"]], 6.0; rtol = 1.0e-12)
        @test isapprox(du[vmap["y[2]"]], 15.0; rtol = 1.0e-12)
    end
end

# The default array build (affine access kernels + codegen tier) against the
# forced per-cell SCALAR reference (`compiler=:interpreter` — compiled cell
# nodes on `rhs_list`, evaluated by `_eval_node` with no merge machinery).
@testset "array kernels ≡ per-cell scalar reference (differential)" begin
    _build(model, ics, disable) =
        EarthSciAST._build_evaluator(
        model; initial_conditions = ics,
        compiler = disable ? :interpreter : :native
    )

    # Bit-identical du across interior + ghost-boundary kernels, every grid size.
    @testset "bit-identical du (N=$N)" for N in (8, 32, 64)
        model = _stencil_model(N)
        ics = Dict("u[$k]" => sin(0.7k) - 0.05k for k in 1:N)
        fsym, u0, p, = _build(model, ics, false)
        ffb, _, _, = _build(model, ics, true)
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
        a_fb = @allocated _build(model, ics, true)
        @test a_sym < a_fb
    end
end

# The compile-once field-ic fast path (ess-perf) compiles a coordinate ic's
# closed-form body ONCE with the loop indices bound as parameters, deriving each
# cell's u0 by re-evaluation instead of a per-cell _index_at_cell→resolve→compile
# rebuild. `_eval_node` computes every leaf in Float64, so an index bound as a
# param equals that index folded to a literal — the u0 field must be bit-identical
# to the forced per-cell path. `compiler=:interpreter` forces that per-cell path.
@testset "compile-once field-ic ≡ per-cell fallback (u0, ess-perf)" begin
    _build_u0(N, disable) =
        EarthSciAST._build_evaluator(
        _fieldic_model(N);
        compiler = disable ? :interpreter : :native
    )[2]   # u0 is 2nd

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

# A ragged loop (`_NK_RAGGED_LOOP`, children `[body, lo, hi]`) is keyed by
# identity in the merge signature, like the other runtime loops: under the
# generic op arm it read as an n-ary `+` over three children, so two distinct
# ragged loops, or a ragged loop and a plain three-way sum, shared a signature.
@testset "a ragged loop's merge signature is its own" begin
    sig(n) = String(take!(ESM._struct_sig!(IOBuffer(), n)))
    st(i) = ESM._mknode(kind = ESM._NK_STATE, idx = i)
    lit(x) = ESM._mknode(kind = ESM._NK_LITERAL, literal = x)
    ragged(lo, hi) = ESM._mknode(
        kind = ESM._NK_RAGGED_LOOP, op = :+, literal = 0.0,
        payload = ESM._RaggedLoop(Ref(0), 1, 4), children = ESM._Node[st(1), lo, hi]
    )
    r1 = ragged(lit(1.0), st(2))
    r2 = ragged(lit(1.0), st(2))
    plus3 = ESM._mknode(kind = ESM._NK_OP, op = :+, children = ESM._Node[st(1), lit(1.0), st(2)])
    @test sig(r1) != sig(r2)
    @test sig(r1) != sig(plus3)
    @test sig(r1) == sig(r1)
end
