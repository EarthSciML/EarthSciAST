# Vectorized array-kernel RHS property tests.
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

@testset "tree_walk vectorized array-kernel RHS" begin

    @testset "N-independent compiled-kernel count (two+ grid sizes)" begin
        diags = map((8, 16, 64)) do N
            ics = Dict("M.u[$k]" => 0.0 for k in 1:N)
            _, u0, _, _, _, d = ESM.Internal.build(
                _stencil_model(N);
                initial_conditions = ics
            )
            @test length(u0) == N                 # state DOES grow with N …
            d
        end
        # … but the compiled array-kernel structure does NOT: one whole-array
        # access kernel per structural box, N-independent.
        akerns(d) = d.stats.n_acc_kernels
        @test akerns(diags[1]) == akerns(diags[2]) == akerns(diags[3])
        @test akerns(diags[1]) >= 1
        # The array equation produced ZERO per-cell scalar RHS entries: it is a
        # whole-array kernel, not an O(N) scalar node list.
        @test all(d -> d.stats.n_scalar_entries == 0, diags)
    end

    @testset "numeric identity vs analytic stencil (rtol 1e-12)" begin
        for N in (8, 32)
            ics = Dict("M.u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
            f!, u0, p, _, vmap = EarthSciAST.Internal.build(
                _stencil_model(N);
                initial_conditions = ics
            )
            du = similar(u0); f!(du, u0, p, 0.0)
            uv(k) = (1 <= k <= N) ? (sin(0.3k) + 0.1k) : 0.0   # ghost → 0
            for i in 1:N
                expected = uv(i - 1) - 2 * uv(i) + uv(i + 1)
                @test isapprox(du[vmap["M.u[$i]"]], expected; rtol = 1.0e-12, atol = 1.0e-12)
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
            "M.y[1]" => 0.0, "M.y[2]" => 0.0,
            "M.x[1]" => 1.0, "M.x[2]" => 1.0, "M.x[3]" => 1.0
        )
        f!, u0, p, _, vmap, rep = EarthSciAST.Internal.build(
            m; initial_conditions = ics,
            const_arrays = Dict("A" => A)
        )
        d = rep.stats
        # A constant-bound contraction is unrolled onto the affine path by default
        # (acc kernel); either array-kernel flavour satisfies the whole-array intent.
        @test d.n_acc_kernels >= 1
        @test d.n_scalar_entries == 0
        du = similar(u0); f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["M.y[1]"]], 6.0; rtol = 1.0e-12)
        @test isapprox(du[vmap["M.y[2]"]], 15.0; rtol = 1.0e-12)
    end
end

# The default array build (affine access kernels + codegen tier) against the
# forced per-cell SCALAR reference (`compiler=:interpreter` — compiled cell
# nodes on `rhs_list`, evaluated by `_eval_node` with no merge machinery).
@testset "array kernels ≡ per-cell scalar reference (differential)" begin
    _build(model, ics, disable) =
        EarthSciAST.Internal.build(
        model; initial_conditions = ics,
        compiler = disable ? :interpreter : :native
    )

    # Bit-identical du across interior + ghost-boundary kernels, every grid size.
    @testset "bit-identical du (N=$N)" for N in (8, 32, 64)
        model = _stencil_model(N)
        ics = Dict("M.u[$k]" => sin(0.7k) - 0.05k for k in 1:N)
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
        ics = Dict("M.u[$k]" => 0.0 for k in 1:N)
        _build(model, ics, false); _build(model, ics, true)   # warm up both
        a_sym = @allocated _build(model, ics, false)
        a_fb = @allocated _build(model, ics, true)
        @test a_sym < a_fb
    end
end

# The compile-once field-ic fast path compiles a coordinate ic's
# closed-form body ONCE with the loop indices bound as parameters, deriving each
# cell's u0 by re-evaluation instead of a per-cell _index_at_cell→resolve→compile
# rebuild. `_eval_node` computes every leaf in Float64, so an index bound as a
# param equals that index folded to a literal — the u0 field must be bit-identical
# to the forced per-cell path. `compiler=:interpreter` forces that per-cell path.
@testset "compile-once field-ic ≡ per-cell fallback (u0)" begin
    _build_u0(N, disable) =
        EarthSciAST.Internal.build(
        _fieldic_model(N);
        compiler = disable ? :interpreter : :native
    ).u0

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

# A per-cell node and a kernel tree are DAGs: a subexpression object is
# referenced from several places, and the references nest, so a walk that
# descends into every reference does work, and builds output, in proportion to
# the UNFOLDED tree, exponential in the nesting. The per-cell merge, round 1's
# signature and round 1's clone each handle a repeated node once. The chains
# below double a node 20 to 60 times: a few dozen nodes as a DAG, 2^20 to 2^60
# as a tree.
@testset "the kernel merges handle a shared subexpression once" begin
    st(i) = ESM._mknode(kind = ESM._NK_STATE, idx = i)
    lit(x) = ESM._mknode(kind = ESM._NK_LITERAL, literal = x)
    op(o, ch...) = ESM._mknode(kind = ESM._NK_OP, op = o, children = collect(ESM._Node, ch))
    function doubled(leaf, levels)
        d = op(:sin, leaf)
        for _ in 1:levels
            d = op(:+, d, d)
        end
        return d
    end
    # distinct node objects reachable from a root
    function nnodes(root)
        seen = ESM._NodeMap{Bool}()
        stack = ESM._Node[root]
        while !isempty(stack)
            n = pop!(stack)
            haskey(seen, n) && continue
            seen[n] = true
            append!(stack, n.children)
        end
        return length(seen)
    end

    @testset "the per-cell merge" begin
        cell(i) = (sh = op(:*, st(i), lit(2.0)); op(:+, sh, op(:sin, sh)))
        acc = ESM._AccDesc[]
        spine = ESM._acc_merge_nodes(ESM._Node[cell(1), cell(2), cell(3)], 3, acc)
        @test spine.children[1] === spine.children[2].children[1]   # built once, still shared
        @test length(acc) == 1                            # one slot table, not one per reference
        K = ESM._AccKernel(ESM._outs_cells([1, 2, 3]), spine, acc)
        du = zeros(3)
        u = [0.3, 0.7, 1.1]
        ESM._run_acc_kernel!(du, u, NamedTuple(), 0.0, K)
        @test du == [2x + sin(2x) for x in u]

        intern = ESM._SigIntern()
        @test ESM._struct_sig_id(doubled(st(1), 60), intern) ==
            ESM._struct_sig_id(doubled(st(2), 60), intern)
        acc40 = ESM._AccDesc[]
        spine40 = ESM._acc_merge_nodes(
            ESM._Node[doubled(st(1), 40), doubled(st(2), 40)], 2, acc40
        )
        @test length(acc40) == 1
        @test nnodes(spine40) == nnodes(doubled(st(1), 40))
    end

    @testset "round 1's clone" begin
        # two one-lane kernels over the same DAG, reading different state slots
        kernel(slot) = ESM._AccKernel(
            ESM._outs_cells([slot]), doubled(ESM._acc(1), 20),
            ESM._AccDesc[ESM._AccStateFixed(slot)]
        )
        kernels = ESM._AccKernel[kernel(1), kernel(2)]
        plans = ESM._OopAccPlan[ESM._build_oop_acc_plan(K) for K in kernels]
        @test all(pl -> pl.vectorizable, plans)
        merged, _, diag = ESM._merge_oop_acc_kernels(kernels, plans)
        @test diag.n_out == 1 && diag.n_failed == 0
        @test nnodes(only(merged).spine) == nnodes(kernels[1].spine)
        # the merged kernel still evaluates to each member's value
        small = ESM._AccKernel[
            ESM._AccKernel(
                ESM._outs_cells([s]), doubled(ESM._acc(1), 3),
                ESM._AccDesc[ESM._AccStateFixed(s)]
            ) for s in (1, 2)
        ]
        msmall, _, _ = ESM._merge_oop_acc_kernels(
            small, ESM._OopAccPlan[ESM._build_oop_acc_plan(K) for K in small]
        )
        u = [0.3, 0.7]
        want = zeros(2)
        foreach(K -> ESM._run_acc_kernel!(want, u, NamedTuple(), 0.0, K), small)
        got = zeros(2)
        ESM._run_acc_kernel!(got, u, NamedTuple(), 0.0, only(msmall))
        @test got == want
    end

    # Round 1's signature names each node by its CLASS, its own token plus the
    # classes of its children, instead of writing the unfolded tree as text.
    @testset "round 1's signature" begin
        intern = ESM._SigIntern()
        ksig(K) = ESM._oop_merge_kernel_sig(K, true, intern)
        kernel(spine, acc = ESM._AccDesc[]) = ESM._AccKernel(ESM._outs_cells([1]), spine, acc)
        over(slot, f) = kernel(
            op(:+, doubled(ESM._acc(1), 60), op(f, ESM._acc(1))),
            ESM._AccDesc[ESM._AccStateFixed(slot)]
        )
        s1, s2, s3 = ksig(over(1, :exp)), ksig(over(2, :exp)), ksig(over(3, :cos))
        @test s1[2] === :ok
        @test s1[1] == s2[1]                  # which state slot a lane reads is free
        @test s1[1] != s3[1]                  # another operator is another class
        @test length(s1[1]) == 3              # 2^60 nodes as a tree: one class per root, two tier marks
        # a key delimits its children, which concatenated text could not:
        # f(aT) and f(a, t)
        par(name) = ESM._mknode(kind = ESM._NK_PARAM, sym = name)
        tnode = ESM._mknode(kind = ESM._NK_TIME)
        @test ksig(kernel(op(:f, par(:aT))))[1] != ksig(kernel(op(:f, par(:a), tnode)))[1]
        # the decline reason is the last one in preorder, whatever the sharing
        pay = ESM._mknode(kind = ESM._NK_OP, op = :g, payload = Ref(1), children = ESM._Node[lit(1.0)])
        odd = ESM._mknode(kind = ESM._NK_STATE, idx = 1)
        @test ksig(kernel(op(:+, pay, odd)))[2] === :node_kind
        @test ksig(kernel(op(:+, odd, pay)))[2] === :op_payload
        @test ksig(kernel(op(:+, pay, odd, pay)))[2] === :op_payload
        @test ESM._oop_merge_kernel_sig(kernel(lit(1.0)), false, intern) == (nothing, :unvectorizable)
    end
end

# A ragged loop (`_NK_RAGGED_LOOP`, children `[body, lo, hi]`) is keyed by
# identity in the merge signature, like the other runtime loops: under the
# generic op arm it read as an n-ary `+` over three children, so two distinct
# ragged loops, or a ragged loop and a plain three-way sum, shared a signature.
@testset "a ragged loop's merge signature is its own" begin
    intern = ESM._SigIntern()
    sig(n) = ESM._struct_sig_id(n, intern)
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

# A const table read at a subscript computed from the state (a linear
# interpolation) declines the compile-once tiers, so the out-of-place build
# compiles every cell on its own and groups the cells by structure. The build
# gives each table one gather payload, so the cells reading one table group
# into one kernel with a lane per cell, and cells reading different tables stay
# in separate kernels, each holding its own table.
function _tbl_interp_doc(N; two_tables = false)
    op(o, args...) = Dict{String, Any}("op" => o, "args" => Any[args...])
    faq(e) = Dict{String, Any}(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict("i" => Dict("from" => "cells")), "expr" => e
    )
    function interp(var, tab)
        c = Dict{String, Any}("op" => "const", "args" => Any[], "value" => tab)
        x = op("min", op("max", op("index", var, "i"), 1.0), length(tab) - 0.5)
        k = op("floor", x)
        w = op("-", x, k)
        return op(
            "+", op("*", op("-", 1.0, w), op("index", c, k)),
            op("*", w, op("index", c, op("+", k, 1)))
        )
    end
    tabs = Dict("u" => [sin(0.1j) + 0.01j^1.5 for j in 1:12], "v" => [cos(0.07j) + 0.02j for j in 1:12])
    vars = Dict{String, Any}()
    eqs = Any[]
    for q in (two_tables ? ("u", "v") : ("u",))
        vars[q] = Dict("type" => "unknown", "units" => "1", "shape" => Any["cells"], "default" => 1.0)
        dq = merge(op("D", op("index", q, "i")), Dict{String, Any}("wrt" => "t"))
        push!(eqs, Dict("lhs" => faq(dq), "rhs" => faq(op("-", interp(q, tabs[q]), op("*", 0.1, op("index", q, "i"))))))
    end
    doc = Dict(
        "esm" => ESM.SCHEMA_VERSION, "metadata" => Dict("name" => "tbl_interp"),
        "index_sets" => Dict("cells" => Dict("kind" => "interval", "size" => N)),
        "models" => Dict("M" => Dict("variables" => vars, "equations" => eqs))
    )
    return doc, tabs
end

function _tbl_payloads(K)
    out = IdDict{Any, Nothing}()
    walk(n) = (n.payload isa ESM._ConstGatherArray && (out[n.payload] = nothing); foreach(walk, n.children))
    walk(K.spine)
    foreach(walk, K.cse.recipes)
    foreach(walk, K.cse.inv_recipes)
    return collect(keys(out))
end

@testset "cells reading one const table merge into one kernel" begin
    N = 24
    for two in (false, true)
        names = two ? ("u", "v") : ("u",)
        doc, tabs = _tbl_interp_doc(N; two_tables = two)
        b = ESM.Internal.build(doc; form = :oop)
        # Every equation took the per-cell build, and each became one kernel
        # with a lane per cell.
        @test b.report.tally[:percell_acc] == length(names)
        ks = b.report.kernels
        @test length(ks) == length(names)
        @test all(K -> ESM._cellset_ncells(K.cells) == N, ks)
        # Each kernel holds one table payload, its own equation's table.
        pls = map(_tbl_payloads, ks)
        @test all(p -> length(p) == 1, pls)
        @test sort([only(p).flat for p in pls]) == sort([tabs[q] for q in names])
        two && @test only(pls[1]) !== only(pls[2])
    end
end

# The build's one gather payload per const array: the same array under the same
# name is one object, a different array (equal values or not) or a different
# name is another, and outside a build every call makes its own.
@testset "one const gather payload per array per build" begin
    A = [1.0, 2.0, 3.0]
    A2 = copy(A)
    B = [1 2; 3 4]   # not Float64: converted once per build
    ctx = ESM._new_build_ctx(ESM._compiler_plan(:native), nothing)
    a = ESM._with_build_ctx(ctx) do
        a = ESM._const_gather_payload(A, "t")
        @test ESM._const_gather_payload(A, "t") === a
        @test a.flat === A
        @test ESM._const_gather_payload(A2, "t") !== a
        @test ESM._const_gather_payload(A, "s") !== a
        b = ESM._const_gather_payload(B, "b")
        @test ESM._const_gather_payload(B, "b") === b
        @test b.flat == Float64[1, 3, 2, 4] && b.dims == [2, 2]
        # A child context (an output-time compile) shares the build's payloads.
        ESM._with_build_ctx(ESM._child_build_ctx()) do
            @test ESM._const_gather_payload(A, "t") === a
        end
        a
    end
    # A new build starts with none of them.
    ESM._with_build_ctx(ESM._new_build_ctx(ESM._compiler_plan(:native), nothing)) do
        @test ESM._const_gather_payload(A, "t") !== a
    end
    @test ESM._const_gather_payload(A, "t") !== ESM._const_gather_payload(A, "t")
end
