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
# materializes the SAME map twice — once on the fast path, once with
# `ESS_SETUP_MAP_COMPILE_ONCE_DISABLE=1` forcing the per-cell reference — and
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
    Dict{String,Any}("op" => "aggregate", "output_idx" => collect(output_idx),
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
    ref = withenv("ESS_SETUP_MAP_COMPILE_ONCE_DISABLE" => "1") do
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
        ref = withenv("ESS_SETUP_MAP_COMPILE_ONCE_DISABLE" => "1") do
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

    @testset "kill switch keeps the per-cell reference available" begin
        body = _op("exp", _ix(_v("A"), _v("x"), _v("y")))
        j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
        rhs = EA.expression_from_json(j)
        m0 = EA._SETUP_MAP_FASTPATH_MISS[]
        h0 = EA._SETUP_MAP_FASTPATH_HITS[]
        withenv("ESS_SETUP_MAP_COMPILE_ONCE_DISABLE" => "1") do
            EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, IDX,
                                              Dict{String,Function}())
        end
        @test EA._SETUP_MAP_FASTPATH_MISS[] - m0 == 1   # forced onto the reference
        @test EA._SETUP_MAP_FASTPATH_HITS[] - h0 == 0
    end

    @testset "verify mode agrees on the same maps" begin
        body = _op("+", _op("log", _op("*", _ix(_v("A"), _v("x"), _v("y")),
                                            _ix(_v("A"), _v("x"), _v("y")))),
                        _ix(_v("B"), _v("x"), _v("y")))
        j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
        rhs = EA.expression_from_json(j)
        got = withenv("ESS_SETUP_MAP_COMPILE_ONCE_VERIFY" => "1") do
            EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, IDX,
                                              Dict{String,Function}())
        end                                   # throws unless bit-identical
        ref = withenv("ESS_SETUP_MAP_COMPILE_ONCE_DISABLE" => "1") do
            EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, IDX,
                                              Dict{String,Function}())
        end
        @test bitsame(got, ref)
    end

    # ---- the two guards that keep the fast path exact ----

    @testset "guard: `/` in a gather subscript declines" begin
        # `_eval_const_int` reads `/` as TRUNCATING integer `div`; the compiled
        # subscript reads it as true Float64 division. Refuse rather than diverge.
        # `2x/2 == x` under BOTH readings, so this case is about the DECLINE, not
        # about a divergence — the guard is structural, it does not try to prove
        # a particular `/` harmless.
        body = _op("exp", _ix(_v("B"), _op("/", _op("*", _v("x"), 2), 2), _v("y")))
        j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
        fast, ref, hits, miss = both_ways(j, ENV0)
        @test hits == 0 && miss == 1          # declined → per-cell reference
        @test bitsame(fast, ref)
        @test !EA._subscripts_int_exact(EA.expression_from_json(j))
        # ... and it is found in a NESTED node's body too, not just in the
        # top-level `args` spine (the guard walks via `foreach_subexpr_once`).
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

    @testset "guard: non-:error const boundary declines" begin
        # A `:periodic`/`:clamp` array makes an OOB gather LEGAL, and the two
        # paths resolve OOB differently (fold → `_resolve_const_index`; runtime
        # gather → raw linearization). Refuse the fast path outright.
        wrapped = EA._wrap_bounded_const(copy(B), (:periodic, :error), "B")
        env = Dict{String,Any}("A" => A, "B" => wrapped, "s" => 1.5, "thr" => 0.0)
        body = _op("exp", _ix(_v("B"), _v("x"), _v("y")))
        j = _map(["x", "y"], ["x" => "X", "y" => "Y"], body)
        fast, ref, hits, miss = both_ways(j, env)
        @test hits == 0 && miss == 1
        @test bitsame(fast, ref)
        # ... and the same map with the default (:error) policy DOES engage.
        plain = EA._wrap_bounded_const(copy(B), (:error, :error), "B")
        _, _, h2, m2 = both_ways(j, Dict{String,Any}("A" => A, "B" => plain,
                                                     "s" => 1.5, "thr" => 0.0))
        @test h2 == 1 && m2 == 0
    end

    @testset "an unsupported map still falls back, not throws" begin
        # A join/filter aggregate is refused on the symbolic path
        # (`_resolve_index_of_arrayop` throws E_TREEWALK_COMPILE_ONCE_UNSUPPORTED);
        # the caller must swallow that and produce the reference values.
        body = _op("exp", _ix(_v("A"), _v("x"), _v("k")))
        j = _map(["x"], ["x" => "X", "k" => Any[1, 4]], body)
        j["reduce"] = "+"
        j["filter"] = _op(">", _v("k"), 1)
        rhs = EA.expression_from_json(j)
        fast = EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, IDX,
                                                 Dict{String,Function}())
        ref = withenv("ESS_SETUP_MAP_COMPILE_ONCE_DISABLE" => "1") do
            EA._materialize_setup_general_map(rhs, copy(ENV0), nothing, IDX,
                                              Dict{String,Function}())
        end
        @test bitsame(fast, ref)
    end

end

end # module
