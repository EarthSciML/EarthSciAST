# Compile-once materialization of a promoted-physics MAP — BIT-EXACTNESS.
#
# Run per output cell, the build-time pipeline (`_index_at_cell` →
# `_resolve_indices` → `_compile` → `_eval_node`) would make a per-cell physics
# lookup over an N-cell grid pay N full AST lowerings, so build cost would track
# the grid. `_materialize_setup_general_map` resolves+compiles ONCE with the output indices
# bound as parameters (the `_cellwise_compile_once` machinery: a
# const read carrying an output index lowers to a runtime `_NK_CONST_GATHER`
# instead of constant-folding) and rebinds only those per cell.
#
# The whole game is that this changes NOTHING numerically. Every case below
# materializes the SAME map twice — once on the fast path, once under
# `compiler=:interpreter`, which is the per-cell reference — and
# demands `isequal` cell for cell. `isequal`, never `≈` and never `==`: `-0.0`
# must not pass for `+0.0` and `NaN` must match `NaN`.
#
# The engagement counts (`Internal.counting`) make the comparison non-vacuous: a case that silently
# stopped taking the fast path would compare the reference against itself and
# pass, so each case asserts which path it took.

using Test
include("testutils.jl")
using EarthSciAST
const EA = EarthSciAST

# ---- small JSON AST builders ----
function _map(output_idx, ranges, expr)
    return Dict{String, Any}(
        "op" => "faq", "output_idx" => collect(output_idx),
        "ranges" => Dict{String, Any}(
            k => (
                v isa AbstractString ?
                    Dict{String, Any}("from" => v) : v
            )
                for (k, v) in ranges
        ),
        "args" => Any[],
        "expr" => expr
    )
end

const IDX = Dict{String, Int}("X" => 5, "Y" => 4)

# Materialize `json` both ways and return (fast, reference, hits, miss).
function both_ways(json, env)
    rhs = EA.expression_from_json(json)
    fast, c = EA.Internal.counting(
        () -> EA._materialize_setup_general_map(rhs, copy(env), nothing, IDX)
    )
    hits = get(c, :setup_map_fastpath_hit, 0)
    miss = get(c, :setup_map_fastpath_miss, 0)
    ref = EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
        EA._materialize_setup_general_map(rhs, copy(env), nothing, IDX)
    end
    return fast, ref, hits, miss
end

# A gradient-y source field with a signed zero, a negative, and a huge value, so
# `exp`/`log`/`neg` below actually produce -0.0, NaN and ±Inf.
const A = Float64[(-1.0)^(i + j) * (i - 3) * (j - 2) / 4 for i in 1:5, j in 1:4]
const B = Float64[i + 10j for i in 1:5, j in 1:4]
const ENV0 = Dict{String, Any}("A" => A, "B" => B, "s" => 1.5, "thr" => 0.0)

@testset "setup-map compile-once" begin

    @testset "per-cell physics lookup is bit-identical" begin
        # exp/log/ifelse/and/comparisons — the promoted-physics vocabulary that
        # routes here in the first place, over const gathers on the output index.
        # `A` has zero, negative and positive cells, so between them these bodies
        # produce a signed zero, ±Inf and a NaN — exactly what `isequal` (rather
        # than `==` or `≈`) is here to police.
        Axy = jidx("A", "x", "y")
        Bxy = jidx("B", "x", "y")
        bodies = Dict(
            # signed zero out of the false arm of a gated physics branch
            "gated" => jop(
                "ifelse",
                jop("and", jop(">", Axy, "thr"), jop("<", Bxy, 40.0)),
                jop("exp", jop("*", Axy, "s")),
                jop("neg", jop("*", 0, Bxy))
            ),
            # -Inf where A is zero
            "log" => jop("log", jop("*", Axy, Axy)),
            # ±Inf where A is zero, finite elsewhere
            "recip" => jop("/", "s", Axy),
            # NaN (0/0) where A is zero
            "nan" => jop("/", Axy, Axy),
        )
        seen = Float64[]
        for (nm, body) in bodies
            j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
            fast, ref, hits, miss = both_ways(j, ENV0)
            @test (nm, hits, miss) == (nm, 1, 0)   # the fast path really engaged
            @test (nm, bitsame(fast, ref)) == (nm, true)
            @test (nm, length(unique(fast)) > 1) == (nm, true)
            append!(seen, vec(fast))
        end
        @test any(isnan, seen)
        @test any(x -> !isfinite(x) && !isnan(x), seen)
        @test any(x -> x === -0.0, seen)
        # And such a map is genuinely one the general evaluator (not the compiled
        # geometry materializer) owns.
        @test EA._is_setup_general_map(
            EA.expression_from_json(
                _map(
                    ["x", "y"], ["x" => "X", "y" => "Y"],
                    bodies["log"]
                )
            )
        )
    end

    @testset "shifted / arithmetic gather subscripts" begin
        # A subscript that is not the bare output index: the compiled gather must
        # recompute the offset from the rebound index, not from a folded literal.
        body = jop(
            "exp", jop(
                "-",
                jidx("B", jop("+", "x", 1), "y"),
                jidx("B", "x", jop("min", jop("+", "y", 1), 4))
            )
        )
        j = _map(["x", "y"], ["x" => "X2", "y" => "Y"], body)
        idx = Dict{String, Int}("X2" => 4, "Y" => 4)
        rhs = EA.expression_from_json(j)
        fast, c = EA.Internal.counting(
            () -> EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, idx)
        )
        @test get(c, :setup_map_fastpath_hit, 0) == 1
        @test get(c, :setup_map_fastpath_miss, 0) == 0
        ref = EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
            EA._materialize_setup_general_map(
                rhs, copy(ENV0), nothing, idx
            )
        end
        @test bitsame(fast, ref)
        @test length(unique(fast)) > 1
    end

    @testset "rank-1 map" begin
        body = jop("*", jidx("A", "c", 2), "s")
        j = _map(["c"], ["c" => "X"], body)
        fast, ref, hits, miss = both_ways(j, ENV0)
        @test hits == 1 && miss == 0
        @test bitsame(fast, ref)
    end

    @testset "the interpreter keeps the per-cell reference available" begin
        body = jop("exp", jidx("A", "x", "y"))
        j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
        rhs = EA.expression_from_json(j)
        _, c = EA.Internal.counting() do
            EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
                EA._materialize_setup_general_map(
                    rhs, copy(ENV0), nothing, IDX
                )
            end
        end
        @test get(c, :setup_map_fastpath_miss, 0) == 1   # forced onto the reference
        @test get(c, :setup_map_fastpath_hit, 0) == 0
    end

    # ---- the two guards that keep the fast path exact ----

    @testset "`/` in a gather subscript: the fill reads it as the reference does" begin
        # A bare quotient in an integer subscript must be exact
        # (`_subscript_quotient`); a subscript the compile-once sweep keeps
        # symbolic would carry a fractional quotient on as Float64, so that sweep
        # declines any `/` under an `index` subscript (`_subscripts_int_exact`).
        # The compiled fill resolves subscripts the way the reference does, so it
        # serves an exact quotient `(2x)/2`, and an inexact one `(x+1)/2` is
        # refused on both routes alike.
        sub = jop("/", jop("*", "x", 2), 2)
        body = jop("exp", jidx("B", sub, "y"))
        j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
        fast, ref, hits, miss = both_ways(j, ENV0)
        @test hits == 1 && miss == 0
        @test bitsame(fast, ref)
        @test !EA._subscripts_int_exact(EA.expression_from_json(j))
        inexact = _map(
            ["x", "y"], ["x" => "X", "y" => "Y"],
            jop("exp", jidx("B", jop("/", jop("+", "x", 1), 2), "y"))
        )
        rhs = EA.expression_from_json(inexact)
        code(f) = try
            f(); nothing
        catch e
            e isa EA.TreeWalkError ? e.code : e
        end
        @test code(() -> EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, IDX)) ==
            "E_TREEWALK_INEXACT_SUBSCRIPT"
        @test code(
            () -> EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
                EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, IDX)
            end
        ) == "E_TREEWALK_INEXACT_SUBSCRIPT"
        # The compile-once guard finds a `/` in a NESTED node's body too, not
        # just in the top-level `args` spine (it walks via `foreach_subexpr_once`).
        inner = _map(
            ["k"], ["k" => "Y"],
            jidx("B", jop("/", jop("*", "x", 2), 2), "k")
        )
        nested = _map(
            ["x", "y"], ["x" => "X", "y" => "Y"],
            jidx(inner, "y")
        )
        @test !EA._subscripts_int_exact(EA.expression_from_json(nested))
        # A `/` OUTSIDE an index subscript is harmless and must NOT decline.
        ok = _map(
            ["x", "y"], ["x" => "X", "y" => "Y"],
            jop("/", jidx("B", "x", "y"), "s")
        )
        _, _, h2, m2 = both_ways(ok, ENV0)
        @test h2 == 1 && m2 == 0
    end

    @testset "a periodic or clamp const boundary wraps as the reference does" begin
        # A `:periodic`/`:clamp` axis makes an out-of-range gather LEGAL. The
        # reference resolves it at fold time (`_resolve_const_index`), the
        # compiled paths at run time (`_const_gather_sub`), and both hand the
        # out-of-range case to `_resolve_const_index_oob`, so each reads the
        # same element: the compiled fill, and the compile-once sweep it falls
        # back to, which does not decline such an array.
        for pol in (:periodic, :clamp)
            wrapped = EA._wrap_bounded_const(copy(B), (pol, :error), "B")
            env = Dict{String, Any}("A" => A, "B" => wrapped, "s" => 1.5, "thr" => 0.0)
            for sub in (jop("+", "x", 1), jop("-", "x", 2))
                body = jop("exp", jidx("B", sub, "y"))
                j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
                fast, ref, hits, miss = both_ways(j, env)
                @test (pol, hits, miss) == (pol, 1, 0)
                @test (pol, bitsame(fast, ref)) == (pol, true)
                # The sweep the fill falls back to, on its own.
                rhs = EA.expression_from_json(j)
                ca, params = EA._setup_env_split(env)
                ce = EA._setup_map_compile_once(rhs, 2, ca, params)
                @test ce !== nothing
                @test (pol, bitsame(EA._fill_map_fast(ce, [5, 4], 2), ref)) == (pol, true)
            end
        end
    end

    @testset "a filtered map gives the reference values" begin
        # A filter is a run-time guard on the symbolic path, the same
        # `ifelse(pred, term, 0̄)` per term the per-cell expansion builds (a join
        # gate is still refused there, and the caller swallows that refusal);
        # either way the values are the reference's.
        body = jop("exp", jidx("A", "x", "k"))
        j = _map(["x"], ["x" => "X", "k" => Any[1, 4]], body)
        j["reduce"] = "+"
        j["filter"] = jop(">", "k", 1)
        rhs = EA.expression_from_json(j)
        fast = EA._materialize_setup_general_map(
            rhs, copy(ENV0), nothing, IDX
        )
        ref = EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
            EA._materialize_setup_general_map(
                rhs, copy(ENV0), nothing, IDX
            )
        end
        @test bitsame(fast, ref)
    end

    # A const read out of range on a non-final axis. Its column-major offset
    # still lands inside `B`, so the compiled gather read a neighbouring cell
    # (B[x+1, 1] at x = 5 returned B[1, 2]) while the per-cell reference raised.
    @testset "out of range on one axis raises on both paths" begin
        for body in (
                jidx("B", jop("+", "x", 1), 1),
                jidx("B", jop("-", "x", 1), 2),
            )
            rhs = EA.expression_from_json(_map(["x"], ["x" => "X"], body))
            for interp in (false, true)
                mat() = EA._materialize_setup_general_map(
                    rhs, copy(ENV0), nothing,
                    IDX
                )
                err = try
                    interp ?
                        EA._with_compiler_plan(mat, EA._compiler_plan(:interpreter)) :
                        mat()
                    nothing
                catch e
                    e
                end
                @test err isa EA.TreeWalkError && err.code == "E_TREEWALK_CONSTARRAY_OOB"
            end
        end
    end

end

# A node reached from two parents is wrapped by `_cell_memoize!` in a
# `:cellmemo` node: evaluated once per cell, to the same bits as the tree
# without sharing, and allocating nothing per cell.
@testset "a shared sub-tree is evaluated once per cell" begin
    t1 = EA.expression_from_json(jop("*", "a", jop("+", "b", "__esm_oidx_1")))
    t2 = EA.expression_from_json(jop("*", "a", jop("+", "b", "__esm_oidx_1")))
    e = EA.OpExpr("+", EA.ASTExpr[t1, EA.OpExpr("-", EA.ASTExpr[t2, EA.VarExpr("c")])])
    params = Dict{String, Any}("a" => 0.3, "b" => -1.25, "c" => 7.0)
    ce_plain = EA._cellwise_compile_once(e, 1, Dict{String, Any}(), params)
    @test ce_plain !== nothing
    # The same evaluator with the second copy of the term replaced by the
    # first, so one node has two parents.
    ce0 = EA._cellwise_compile_once(e, 1, Dict{String, Any}(), params)
    root = ce0.node
    root.children[2].children[1] = root.children[1]
    syms, np, ni = typeof(ce0).parameters
    P = NamedTuple{syms, NTuple{length(syms), Float64}}
    ce = EA._CellEval{syms, np, ni}(EA._cell_memoize!(root, P), ce0.base, ce0.t)
    memos = 0
    seen = IdDict{Any, Nothing}()
    function count_memos(n)
        haskey(seen, n) && return
        seen[n] = nothing
        n.op === :cellmemo && (memos += 1)
        foreach(count_memos, n.children)
        return
    end
    count_memos(ce.node)
    @test memos == 1
    cells = [[i] for i in 1:64]
    got = EA._eval_cells(ce, cells)
    @test isequal(got, EA._eval_cells(ce_plain, cells))
    @test isequal(got, EA._eval_cells(ce, cells))
    if VERSION >= v"1.12"
        # Only the output vector: a memo miss stores its entry in place.
        @test (@allocated EA._eval_cells(ce, cells)) == (@allocated EA._eval_cells(ce_plain, cells))
    end
end
