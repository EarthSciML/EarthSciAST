# Compile-once materialization of a promoted-physics MAP — BIT-EXACTNESS.
#
# `_materialize_setup_general_map` used to re-run the ENTIRE build-time pipeline
# (`_index_at_cell` → `_resolve_indices` → `_compile` → `_eval_node`) once per
# output cell, so a per-cell physics lookup over an N-cell grid paid N full AST
# lowerings — 55% of a ReSEACT chemistry `build_evaluator`, and the reason build
# cost tracked the grid. It now resolves+compiles ONCE with the output indices
# bound as parameters (the wall2 Phase C `_cellwise_compile_once` machinery: a
# const read carrying an output index lowers to a runtime `_NK_CONST_GATHER`
# instead of constant-folding) and rebinds only those per cell.
#
# The whole game is that this changes NOTHING numerically. Every case below
# materializes the SAME map twice — once on the fast path, once under
# `compiler=:interpreter`, which is the per-cell reference — and
# demands `isequal` cell for cell. `isequal`, never `≈` and never `==`: `-0.0`
# must not pass for `+0.0` and `NaN` must match `NaN`.
#
# The engagement counters make the comparison non-vacuous: a case that silently
# stopped taking the fast path would compare the reference against itself and
# pass, so each case asserts which path it took.

module SetupMapCompileOnceTests

using Test
using EarthSciAST
const EA = EarthSciAST

# ---- small JSON AST builders ----
_op(o, args...) = Dict{String,Any}("op" => o, "args" => Any[args...])
_ix(f, args...) = Dict{String,Any}("op" => "index", "args" => Any[f, args...])
_v(n) = n     # a bare String IS a variable reference (parse.jl)
function _map(output_idx, ranges, expr)
    Dict{String,Any}("op" => "faq", "output_idx" => collect(output_idx),
                     "ranges" => Dict{String,Any}(
                         k => (v isa AbstractString ?
                               Dict{String,Any}("from" => v) : v)
                         for (k, v) in ranges),
                     "args" => Any[],
                     "expr" => expr)
end

const IDX = Dict{String,Int}("X" => 5, "Y" => 4)

# Materialize `json` both ways and return (fast, reference, hits, miss).
function both_ways(json, env)
    rhs = EA.expression_from_json(json)
    regfns = Dict{String,Function}()
    hits0, miss0 = EA._SETUP_MAP_FASTPATH_HITS[], EA._SETUP_MAP_FASTPATH_MISS[]
    fast = EA._materialize_setup_general_map(rhs, copy(env), nothing, IDX, regfns)
    hits = EA._SETUP_MAP_FASTPATH_HITS[] - hits0
    miss = EA._SETUP_MAP_FASTPATH_MISS[] - miss0
    ref = EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
        EA._materialize_setup_general_map(rhs, copy(env), nothing, IDX, regfns)
    end
    return fast, ref, hits, miss
end

# Bitwise array agreement — the correctness bar.
function bitsame(a, b)
    size(a) == size(b) || return false
    for i in eachindex(a)
        isequal(a[i], b[i]) || return false
    end
    return true
end

# A gradient-y source field with a signed zero, a negative, and a huge value, so
# `exp`/`log`/`neg` below actually produce -0.0, NaN and ±Inf.
const A = Float64[(-1.0)^(i + j) * (i - 3) * (j - 2) / 4 for i in 1:5, j in 1:4]
const B = Float64[i + 10j for i in 1:5, j in 1:4]
const ENV0 = Dict{String,Any}("A" => A, "B" => B, "s" => 1.5, "thr" => 0.0)

@testset "setup-map compile-once" begin

    @testset "per-cell physics lookup is bit-identical" begin
        # exp/log/ifelse/and/comparisons — the promoted-physics vocabulary that
        # routes here in the first place, over const gathers on the output index.
        # `A` has zero, negative and positive cells, so between them these bodies
        # produce a signed zero, ±Inf and a NaN — exactly what `isequal` (rather
        # than `==` or `≈`) is here to police.
        Axy = _ix(_v("A"), _v("x"), _v("y"))
        Bxy = _ix(_v("B"), _v("x"), _v("y"))
        bodies = Dict(
            # signed zero out of the false arm of a gated physics branch
            "gated" => _op("ifelse",
                _op("and", _op(">", Axy, _v("thr")), _op("<", Bxy, 40.0)),
                _op("exp", _op("*", Axy, _v("s"))),
                _op("neg", _op("*", 0, Bxy))),
            # -Inf where A is zero
            "log" => _op("log", _op("*", Axy, Axy)),
            # ±Inf where A is zero, finite elsewhere
            "recip" => _op("/", _v("s"), Axy),
            # NaN (0/0) where A is zero
            "nan" => _op("/", Axy, Axy),
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
            EA.expression_from_json(_map(["x", "y"], ["x" => "X", "y" => "Y"],
                                         bodies["log"])))
    end

    @testset "shifted / arithmetic gather subscripts" begin
        # A subscript that is not the bare output index: the compiled gather must
        # recompute the offset from the rebound index, not from a folded literal.
        body = _op("exp", _op("-",
            _ix(_v("B"), _op("+", _v("x"), 1), _v("y")),
            _ix(_v("B"), _v("x"), _op("min", _op("+", _v("y"), 1), 4))))
        j = _map(["x", "y"], ["x" => "X2", "y" => "Y"], body)
        idx = Dict{String,Int}("X2" => 4, "Y" => 4)
        rhs = EA.expression_from_json(j)
        h0, m0 = EA._SETUP_MAP_FASTPATH_HITS[], EA._SETUP_MAP_FASTPATH_MISS[]
        fast = EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, idx,
                                                 Dict{String,Function}())
        @test EA._SETUP_MAP_FASTPATH_HITS[] - h0 == 1
        @test EA._SETUP_MAP_FASTPATH_MISS[] - m0 == 0
        ref = EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
            EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, idx,
                                              Dict{String,Function}())
        end
        @test bitsame(fast, ref)
        @test length(unique(fast)) > 1
    end

    @testset "rank-1 map" begin
        body = _op("*", _ix(_v("A"), _v("c"), 2), _v("s"))
        j = _map(["c"], ["c" => "X"], body)
        fast, ref, hits, miss = both_ways(j, ENV0)
        @test hits == 1 && miss == 0
        @test bitsame(fast, ref)
    end

    @testset "the interpreter keeps the per-cell reference available" begin
        body = _op("exp", _ix(_v("A"), _v("x"), _v("y")))
        j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
        rhs = EA.expression_from_json(j)
        m0 = EA._SETUP_MAP_FASTPATH_MISS[]
        h0 = EA._SETUP_MAP_FASTPATH_HITS[]
        EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
            EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, IDX,
                                              Dict{String,Function}())
        end
        @test EA._SETUP_MAP_FASTPATH_MISS[] - m0 == 1   # forced onto the reference
        @test EA._SETUP_MAP_FASTPATH_HITS[] - h0 == 0
    end

    # ---- the two guards that keep the fast path exact ----

    @testset "`/` in a gather subscript: the fill reads it as the reference does" begin
        # `_eval_const_int` reads `/` as TRUNCATING integer `div`; a subscript the
        # compile-once sweep keeps symbolic would read it as true Float64
        # division, so that sweep declines any `/` under an `index` subscript
        # (`_subscripts_int_exact`). The compiled fill resolves subscripts the
        # way the right-hand side does, with the reference's integer reading, so
        # it serves the map — including `(x+1)/2`, where the two readings
        # differ at every even `x`.
        for sub in (_op("/", _op("*", _v("x"), 2), 2), _op("/", _op("+", _v("x"), 1), 2))
            body = _op("exp", _ix(_v("B"), sub, _v("y")))
            j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
            fast, ref, hits, miss = both_ways(j, ENV0)
            @test hits == 1 && miss == 0
            @test bitsame(fast, ref)
            @test !EA._subscripts_int_exact(EA.expression_from_json(j))
        end
        # The compile-once guard finds a `/` in a NESTED node's body too, not
        # just in the top-level `args` spine (it walks via `foreach_subexpr_once`).
        inner = _map(["k"], ["k" => "Y"],
                     _ix(_v("B"), _op("/", _op("*", _v("x"), 2), 2), _v("k")))
        nested = _map(["x", "y"], ["x" => "X", "y" => "Y"],
                      _ix(inner, _v("y")))
        @test !EA._subscripts_int_exact(EA.expression_from_json(nested))
        # A `/` OUTSIDE an index subscript is harmless and must NOT decline.
        ok = _map(["x", "y"], ["x" => "X", "y" => "Y"],
                  _op("/", _ix(_v("B"), _v("x"), _v("y")), _v("s")))
        _, _, h2, m2 = both_ways(ok, ENV0)
        @test h2 == 1 && m2 == 0
    end

    @testset "a periodic or clamp const boundary wraps as the reference does" begin
        # A `:periodic`/`:clamp` axis makes an out-of-range gather LEGAL. The
        # reference resolves it at fold time (`_resolve_const_index`), the
        # compiled paths at run time (`_const_gather_sub`), and both hand the
        # out-of-range case to `_resolve_const_index_oob`, so each reads the
        # same element: the compiled fill, and the compile-once sweep it falls
        # back to, which no longer declines such an array.
        for pol in (:periodic, :clamp)
            wrapped = EA._wrap_bounded_const(copy(B), (pol, :error), "B")
            env = Dict{String,Any}("A" => A, "B" => wrapped, "s" => 1.5, "thr" => 0.0)
            for sub in (_op("+", _v("x"), 1), _op("-", _v("x"), 2))
                body = _op("exp", _ix(_v("B"), sub, _v("y")))
                j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
                fast, ref, hits, miss = both_ways(j, env)
                @test (pol, hits, miss) == (pol, 1, 0)
                @test (pol, bitsame(fast, ref)) == (pol, true)
                # The sweep the fill falls back to, on its own.
                rhs = EA.expression_from_json(j)
                ca, params = EA._setup_env_split(env)
                ce = EA._setup_map_compile_once(rhs, 2, ca, Dict{String,Function}(), params)
                @test ce !== nothing
                @test (pol, bitsame(EA._fill_map_fast(ce, [5, 4], 2), ref)) == (pol, true)
            end
        end
    end

    @testset "an unsupported map still falls back, not throws" begin
        # A join/filter aggregate is refused on the symbolic path
        # (`_resolve_index_of_faq` throws E_TREEWALK_COMPILE_ONCE_UNSUPPORTED);
        # the caller must swallow that and produce the reference values.
        body = _op("exp", _ix(_v("A"), _v("x"), _v("k")))
        j = _map(["x"], ["x" => "X", "k" => Any[1, 4]], body)
        j["reduce"] = "+"
        j["filter"] = _op(">", _v("k"), 1)
        rhs = EA.expression_from_json(j)
        fast = EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, IDX,
                                                 Dict{String,Function}())
        ref = EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
            EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, IDX,
                                              Dict{String,Function}())
        end
        @test bitsame(fast, ref)
    end

    # A const read out of range on a non-final axis. Its column-major offset
    # still lands inside `B`, so the compiled gather read a neighbouring cell
    # (B[x+1, 1] at x = 5 returned B[1, 2]) while the per-cell reference raised.
    @testset "out of range on one axis raises on both paths" begin
        for body in (_ix(_v("B"), _op("+", _v("x"), 1), 1),
                     _ix(_v("B"), _op("-", _v("x"), 1), 2))
            rhs = EA.expression_from_json(_map(["x"], ["x" => "X"], body))
            for interp in (false, true)
                mat() = EA._materialize_setup_general_map(rhs, copy(ENV0), nothing,
                                                          IDX, Dict{String,Function}())
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

end # module
