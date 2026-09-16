# wall2 Phase B — unit tests for the `_NK_CONST_GATHER` compiled node.
#
# `_NK_CONST_GATHER` reads a captured const/provider array at a subscript computed
# AT EVAL TIME from its subscript `children` (Phase C will bind output-index
# parameters into some of those children). These tests exercise the node IN
# ISOLATION — nodes are built by hand via `_const_gather_node` / `_mknode`; the
# resolve/compile pipeline is deliberately NOT involved (that wiring is Phase C).
#
# Pinned properties:
#   * value correctness for rank 1/2/3 arrays with literal subscripts (bit-exact),
#   * a runtime-varying subscript (a `_NK_PARAM` child reading `p.rcv`) selects a
#     different column per binding — proving the offset is computed, not baked,
#   * the eval arm is type-stable (`@inferred` → Float64), and
#   * the hot read is allocation-free (`@allocated == 0`).

using Test
using Random
using EarthSciAST

const ESM = EarthSciAST

# Literal subscript child holding the 1-based integer index `i`.
_lit(i::Integer) = ESM._mknode(kind = ESM._NK_LITERAL, literal = Float64(i))
# Parameter subscript child reading `p.<sym>` at eval time.
_par(sym::Symbol) = ESM._mknode(kind = ESM._NK_PARAM, sym = sym)

@testset "wall2 Phase B — _NK_CONST_GATHER" begin
    Random.seed!(0xB0B)  # deterministic arrays across runs
    u = Float64[]
    p0 = NamedTuple()
    t = 0.0

    @testset "value correctness — rank 1" begin
        A = rand(7)
        for i in 1:7
            node = ESM._const_gather_node(A, ESM._Node[_lit(i)])
            @test ESM._eval_node(node, u, p0, t) === A[i]
        end
    end

    @testset "value correctness — rank 2" begin
        A = rand(4, 5)
        for i in 1:4, j in 1:5
            node = ESM._const_gather_node(A, ESM._Node[_lit(i), _lit(j)])
            @test ESM._eval_node(node, u, p0, t) === A[i, j]
        end
    end

    @testset "value correctness — rank 3" begin
        A = rand(3, 4, 2)
        for i in 1:3, j in 1:4, k in 1:2
            node = ESM._const_gather_node(A, ESM._Node[_lit(i), _lit(j), _lit(k)])
            @test ESM._eval_node(node, u, p0, t) === A[i, j, k]
        end
    end

    @testset "dynamic subscript — column selected at eval time" begin
        # Gather A[i, rcv]: the first subscript is a fixed literal, the second is a
        # `_NK_PARAM` reading `p.rcv`. ONE node object, evaluated at several bindings,
        # must read the matching column — so the offset cannot have been baked in.
        A = rand(4, 5)
        i = 2
        node = ESM._const_gather_node(A, ESM._Node[_lit(i), _par(:rcv)])
        for col in 1:5
            p = (; rcv = Float64(col))
            @test ESM._eval_node(node, u, p, t) === A[i, col]
        end

        # A rank-3 variant with a dynamic MIDDLE subscript, to prove the computed
        # offset uses the right per-dimension stride, not just the last axis.
        B = rand(3, 6, 2)
        node3 = ESM._const_gather_node(B, ESM._Node[_lit(3), _par(:j), _lit(2)])
        for jj in 1:6
            p = (; j = Float64(jj))
            @test ESM._eval_node(node3, u, p, t) === B[3, jj, 2]
        end
    end

    @testset "type-stability — @inferred returns Float64" begin
        A = rand(4, 5)
        litnode = ESM._const_gather_node(A, ESM._Node[_lit(2), _lit(3)])
        # Literal-subscript node, empty params.
        @test (@inferred ESM._eval_node(litnode, u, p0, t, Float64)) isa Float64
        @test (@inferred ESM._eval_node(litnode, u, p0, t, Float64)) === A[2, 3]

        # Dynamic-subscript node, concrete Float64-valued params.
        parnode = ESM._const_gather_node(A, ESM._Node[_lit(2), _par(:rcv)])
        p = (; rcv = 4.0)
        @test (@inferred ESM._eval_node(parnode, u, p, t, Float64)) isa Float64
        @test (@inferred ESM._eval_node(parnode, u, p, t, Float64)) === A[2, 4]
    end

    @testset "allocation-free — hot read is 0 bytes" begin
        A = rand(3, 4, 2)
        # Literal-subscript node.
        litnode = ESM._const_gather_node(A, ESM._Node[_lit(1), _lit(2), _lit(1)])
        ESM._eval_node(litnode, u, p0, t)  # warmup
        @test ESM._eval_node(litnode, u, p0, t) === A[1, 2, 1]
        @test (@allocated ESM._eval_node(litnode, u, p0, t)) == 0

        # Dynamic-subscript node (param read must stay 0-alloc too).
        parnode = ESM._const_gather_node(A, ESM._Node[_lit(1), _par(:j), _lit(1)])
        p = (; j = 3.0)
        ESM._eval_node(parnode, u, p, t)  # warmup
        @test ESM._eval_node(parnode, u, p, t) === A[1, 3, 1]
        @test (@allocated ESM._eval_node(parnode, u, p, t)) == 0
    end

    # Each subscript is checked against its own axis. On a 3×2 array the
    # column-major offsets of [4, 1] and [0, 2] fall inside the 6 elements, so a
    # check on the offset alone read A[1, 2] and A[3, 1] instead of raising.
    @testset "out of range on one axis raises E_TREEWALK_CONSTARRAY_OOB" begin
        A = Float64[1 2; 3 4; 5 6]
        gather_err(i, j) = try
            ESM._eval_node(ESM._const_gather_node(A, ESM._Node[_lit(i), _lit(j)];
                                                  name="A"), u, p0, t)
            nothing
        catch err
            err
        end
        for (i, j) in ((4, 1), (0, 2), (1, 3), (2, 0))
            err = gather_err(i, j)
            @test err isa ESM.TreeWalkError && err.code == "E_TREEWALK_CONSTARRAY_OOB"
        end
        @test ESM._eval_node(ESM._const_gather_node(A, ESM._Node[_lit(3), _lit(2)]),
                             u, p0, t) === 6.0
        # A declared boundary policy resolves on the run-time path exactly as it
        # does when the gather folds (`_resolve_const_index`).
        B = ESM._wrap_bounded_const(A, [:periodic, :clamp], "B")
        @test ESM._eval_node(ESM._const_gather_node(B, ESM._Node[_lit(4), _lit(3)]),
                             u, p0, t) === A[1, 2]
    end
end
