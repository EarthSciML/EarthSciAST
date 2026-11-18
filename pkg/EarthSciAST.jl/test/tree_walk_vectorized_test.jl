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
    tables = ESM._ConstTableIds()
    sig(n) = String(take!(ESM._struct_sig!(IOBuffer(), n, ESM._NodeMap{Int}(), tables)))
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

# A const-array read at a computed subscript carries its TABLE in the node's
# payload, and both kernel merges keep the first member's payload for the whole
# group. Cells, and kernels, that differ only in WHICH table they read therefore
# must not share a merge signature: merged, every lane reads the first table.
# Tables equal in content do merge, whether or not they are the same buffer (a
# const array that is not a dense `Float64` array is converted per gather node).
@testset "a merge signature tells constant tables apart" begin
    st(i) = ESM._mknode(kind = ESM._NK_STATE, idx = i)
    gather(tab, i) = ESM._const_gather_node(tab, ESM._Node[st(i)]; name = "t")
    A = [1.0, 2.0, 3.0]
    B = [1.0, 2.0, 4.0]
    # every constant table a kernel reads, through its spine and both CSE tiers
    function tables_read(K)
        out = Vector{Float64}[]
        walk(n) = (
            n.payload isa ESM._ConstGatherArray && push!(out, n.payload.flat);
            foreach(walk, n.children)
        )
        walk(K.spine); foreach(walk, K.cse.recipes); foreach(walk, K.cse.inv_recipes)
        return out
    end

    @testset "the table's id" begin
        ids = ESM._ConstTableIds()
        id(n) = ESM._const_table_id!(ids, n.payload)
        @test id(gather(A, 1)) == id(gather(A, 2)) != 0        # one buffer
        @test id(gather(A, 1)) == id(gather(copy(A), 2))       # equal content, two buffers
        @test id(gather(A, 1)) == id(gather(collect(1:3), 2))  # a converted copy of the same values
        @test id(gather(A, 1)) != id(gather(B, 1))             # different values
        # the same values under another shape are another table
        A31 = ESM._const_gather_node(reshape(copy(A), 3, 1), ESM._Node[st(1), st(2)]; name = "t")
        @test id(A31) != id(gather(A, 1))
        @test ESM._const_table_id!(ids, nothing) == 0          # not a table: nothing written
    end

    @testset "per-cell grouping (`_struct_sig!`)" begin
        ids = ESM._ConstTableIds()
        sig(n) = String(take!(ESM._struct_sig!(IOBuffer(), n, ESM._NodeMap{Int}(), ids)))
        @test sig(gather(A, 1)) == sig(gather(copy(A), 2))
        @test sig(gather(A, 1)) != sig(gather(B, 2))

        same = ESM._acc_from_cell_entries([(1, gather(A, 1)), (2, gather(copy(A), 2))])
        @test length(same) == 1                                 # one kernel, two lanes
        apart = ESM._acc_from_cell_entries([(1, gather(A, 1)), (2, gather(B, 2))])
        @test length(apart) == 2                                # never one kernel
        @test [only(tables_read(K)) for K in apart] == [A, B]   # and each keeps its own table
    end

    @testset "round 1 of the kernel-class merge (`_oop_merge_class!`)" begin
        KA, KB = ESM._acc_from_cell_entries([(1, gather(A, 1)), (2, gather(B, 2))])
        KA2 = only(ESM._acc_from_cell_entries([(3, gather(copy(A), 3))]))
        classes = ESM._OopSigClasses()
        ksig(K) = ESM._oop_merge_kernel_sig(K, true, false, classes)
        @test all(s -> s[2] === :ok, (ksig(KA), ksig(KB), ksig(KA2)))
        @test ksig(KA)[1] != ksig(KB)[1]
        @test ksig(KA)[1] == ksig(KA2)[1]
    end
end

# A per-cell node and a kernel tree are DAGs: a template expansion references one
# subexpression object from several places, and the references nest, so a walk
# that descends into every reference does work — and builds output — in
# proportion to the UNFOLDED tree, which is exponential in the nesting. The
# merge signature, the per-cell merge and round 1's clone each handle a
# repeated node once. The chains below double a node 20 to 60 times: a few
# dozen nodes as a DAG, 2^20 to 2^60 as a tree.
@testset "the kernel merges handle a shared subexpression once" begin
    ids = ESM._ConstTableIds()
    sig(n) = String(take!(ESM._struct_sig!(IOBuffer(), n, ESM._NodeMap{Int}(), ids)))
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

    @testset "the signature back-references a repeated node" begin
        tree = op(:+, op(:*, st(1), lit(2.0)), op(:*, st(3), lit(2.0)))
        @test sig(tree) == "O:+(O:*(S,L),O:*(S,L))"       # no sharing: the bytes it always wrote
        shared = op(:*, st(1), lit(2.0))
        dag = op(:+, shared, shared)
        @test sig(dag) == "O:+(O:*(S,L),#2)"
        @test sig(dag) != sig(tree)                       # same shape, different sharing
        @test sizeof(sig(doubled(st(1), 60))) < 2_000     # linear in the DAG
    end

    @testset "the per-cell merge" begin
        cell(i) = (sh = op(:*, st(i), lit(2.0)); op(:+, sh, op(:sin, sh)))
        nodes = ESM._Node[cell(1), cell(2), cell(3)]
        @test allequal(sig.(nodes))
        acc = ESM._AccDesc[]
        spine = ESM._acc_merge_nodes(nodes, 3, acc)
        @test spine.children[1] === spine.children[2].children[1]   # built once, still shared
        @test length(acc) == 1                            # one slot table, not one per reference
        K = ESM._AccKernel(ESM._outs_cells([1, 2, 3]), spine, acc, ESM._FixedBound(0), 0.0)
        du = zeros(3)
        u = [0.3, 0.7, 1.1]
        ESM._run_acc_kernel!(du, u, NamedTuple(), 0.0, K)
        @test du ≈ [2x + sin(2x) for x in u]

        acc40 = ESM._AccDesc[]
        spine40 = ESM._acc_merge_nodes(
            ESM._Node[doubled(st(1), 40), doubled(st(2), 40)], 2, acc40
        )
        @test length(acc40) == 1
        @test nnodes(spine40) == nnodes(doubled(st(1), 40))
    end

    @testset "round 1's clone" begin
        # two one-lane kernels over the same DAG, reading different state slots
        function kernel(slot)
            acc = ESM._AccDesc[ESM._AccStateFixed(slot)]
            return ESM._AccKernel(
                ESM._outs_cells([slot]), doubled(ESM._acc(1), 20), acc,
                ESM._FixedBound(0), 0.0
            )
        end
        kernels = ESM._AccKernel[kernel(1), kernel(2)]
        plans = ESM._OopAccPlan[ESM._build_oop_acc_plan(K) for K in kernels]
        @test all(pl -> pl.vectorizable, plans)
        merged, _, diag = ESM._merge_oop_acc_kernels(kernels, plans)
        @test diag.n_out == 1 && diag.n_failed == 0
        @test nnodes(only(merged).spine) == nnodes(kernels[1].spine)
    end

    # Round 1's signature names each node by its CLASS — its own token plus the
    # classes of its children — instead of writing the unfolded tree as text.
    @testset "round 1's signature" begin
        classes = ESM._OopSigClasses()
        ksig(K) = ESM._oop_merge_kernel_sig(K, true, false, classes)
        kernel(spine, acc = ESM._AccDesc[]) = ESM._AccKernel(
            ESM._outs_cells([1]), spine, acc, ESM._FixedBound(0), 0.0
        )
        over(slot, f) = kernel(
            op(:+, doubled(ESM._acc(1), 60), op(f, ESM._acc(1))),
            ESM._AccDesc[ESM._AccStateFixed(slot)]
        )
        s1, s2, s3 = ksig(over(1, :exp)), ksig(over(2, :exp)), ksig(over(3, :cos))
        @test s1[2] === :ok
        @test s1[1] == s2[1]                  # which state slot a lane reads is free
        @test s1[1] != s3[1]                  # another operator is another class
        @test sizeof(s1[1]) < 200             # 2^60 nodes as a tree
        # a key delimits its children, which the concatenated text did not:
        # f(aT) and f(a, t) both read "Of(PaT)"
        par(name) = ESM._mknode(kind = ESM._NK_PARAM, sym = name)
        tnode = ESM._mknode(kind = ESM._NK_TIME)
        @test ksig(kernel(op(:f, par(:aT))))[1] != ksig(kernel(op(:f, par(:a), tnode)))[1]
    end
end
