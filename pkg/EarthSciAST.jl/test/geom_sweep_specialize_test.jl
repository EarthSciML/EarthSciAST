# Rank-specialized sweep of the compiled geometry materializer — BIT-EXACTNESS.
#
# `_materialize_geom_array` compiles its body ONCE per sweep, but its inner
# loops were written against a `Vector{Int}` of extents:
#
#     for tup in Iterators.product((1:e for e in exts)...)
#         ...; arr[tup...] = _eval_node(body, u, nothing, 0.0, Float64)
#
# Splatting a generator of statically-unknown length hides the product
# iterator's type from inference, and `zeros(Float64, exts...)` is only ever an
# `Array{Float64}` (rank-abstract), so every cell paid a dynamic `iterate`, a
# boxed `tup` and a dynamically dispatched `setindex!` through the splat — on
# top of the `_eval_node` walk. That per-cell tax, not the walk, was what made
# a ReSEACT chemistry build's cost track the grid: the dominant sweeps are a
# 137241 x NCOL overlap matrix and five 137241 x NCOL contractions, so the tax
# is paid ~5e6 times per 36 columns. The sweeps now run in methods typed
# `Array{Float64,N}` (one dynamic dispatch PER SWEEP), and the `:geo_gather`
# evaluator arm narrows its `Any`-typed source payload with a concrete `isa`
# before reading (tree_walk/geometry_compile.jl).
#
# The whole game is that this changes NOTHING numerically. `CartesianIndices`
# visits a column-major product in EXACTLY the order `Iterators.product` does,
# so the assignment order and — what actually matters — the CONTRACTION FOLD
# ORDER are the same term sequence. Every case below materializes the same
# array twice, once specialized and once with
# `ESS_GEOM_SWEEP_SPECIALIZE_DISABLE=1` forcing the rank-abstract reference,
# and demands `isequal` cell for cell. `isequal`, never `≈` and never `==`:
# `-0.0` must not pass for `+0.0` and `NaN` must match `NaN`.
#
# The engagement counters make the comparison non-vacuous: a case that silently
# stopped taking the specialized sweep would compare the reference against
# itself and pass, so each case asserts which path it took.

module GeomSweepSpecializeTests

using Test
using EarthSciAST
const EA = EarthSciAST

# ---- small JSON AST builders ----
_op(o, args...) = Dict{String,Any}("op" => o, "args" => Any[args...])
_ix(f, args...) = Dict{String,Any}("op" => "index", "args" => Any[f, args...])
function _agg(output_idx, ranges, expr; kw...)
    d = Dict{String,Any}("op" => "aggregate", "output_idx" => collect(output_idx),
                         "ranges" => Dict{String,Any}(
                             k => (v isa AbstractString ? Dict{String,Any}("from" => v) : v)
                             for (k, v) in ranges),
                         "args" => Any[], "expr" => expr)
    for (k, v) in kw
        d[String(k)] = v
    end
    return d
end

const IDX = Dict{String,Int}("I" => 5, "J" => 4, "V" => 3, "C" => 2)

# A source field carrying a signed zero, negatives and a huge value, so the
# bodies below actually produce -0.0, ±Inf and NaN.
const A = Float64[(-1.0)^(i + j) * (i - 3) * (j - 2) / 4 for i in 1:5, j in 1:4]
const B = Float64[i + 10j for i in 1:5, j in 1:4]
const R = Float64[i + 0.25v + 0.5c for i in 1:5, v in 1:3, c in 1:2]
const KI = Float64[mod(i, 2) for i in 1:5]
const KJ = Float64[mod(j, 2) for j in 1:4]
const ENV0 = Dict{String,Any}("A" => A, "B" => B, "R" => R, "kI" => KI, "kJ" => KJ,
                              "s" => 1.5, "thr" => 0.0)
const SHAPES = Dict{String,Vector{String}}("kI" => ["I"], "kJ" => ["J"])

# Materialize `json` both ways and return (fast, reference, fastcount, refcount).
function both_ways(json, env = ENV0, idx = IDX)
    rhs = EA.expression_from_json(json)
    f0, r0 = EA._GEOM_SWEEP_FAST[], EA._GEOM_SWEEP_REF[]
    fast = EA._materialize_geom_array(rhs, copy(env), nothing, idx, SHAPES)
    nf = EA._GEOM_SWEEP_FAST[] - f0
    nr = EA._GEOM_SWEEP_REF[] - r0
    ref = withenv("ESS_GEOM_SWEEP_SPECIALIZE_DISABLE" => "1") do
        EA._materialize_geom_array(rhs, copy(env), nothing, idx, SHAPES)
    end
    return fast, ref, nf, nr
end

# Bitwise array agreement — the correctness bar.
function bitsame(a, b)
    size(a) == size(b) || return false
    for i in eachindex(a)
        isequal(a[i], b[i]) || return false
    end
    return true
end

@testset "geometry sweep rank specialization" begin

    @testset "MAP sweeps are bit-identical at ranks 1, 2 and 3" begin
        Aij = _ix("A", "i", "j")
        Bij = _ix("B", "i", "j")
        cases = Dict(
            # rank 2, signed zero out of the false arm of a gated branch
            "rank2_gated" => (_agg(["i", "j"], ["i" => "I", "j" => "J"],
                _op("ifelse", _op(">", Aij, "thr"),
                    _op("*", Aij, "s"), _op("*", -1.0, _op("*", 0.0, Bij)))), IDX),
            # rank 2, ±Inf where A is zero
            "rank2_inf" => (_agg(["i", "j"], ["i" => "I", "j" => "J"],
                _op("/", "s", Aij)), IDX),
            # rank 2, NaN (0/0) where A is zero
            "rank2_nan" => (_agg(["i", "j"], ["i" => "I", "j" => "J"],
                _op("/", Aij, Aij)), IDX),
            # rank 1
            "rank1" => (_agg(["i"], ["i" => "I"],
                _op("/", "s", _ix("A", "i", 2))), IDX),
            # rank 3 over a [pos, vert, coord] ring stack — the shape a
            # constructed cell ring materializes into
            "rank3" => (_agg(["i", "v", "c"], ["i" => "I", "v" => "V", "c" => "C"],
                _op("+", _op("*", _ix("R", "i", "v", "c"), "s"),
                         _op("-", _ix("R", "i", "v", "c"), _ix("A", "i", 1)))), IDX),
        )
        seen = Float64[]
        for (nm, (j, idx)) in cases
            fast, ref, nf, nr = both_ways(j, ENV0, idx)
            @test (nm, nf, nr) == (nm, 1, 0)          # the specialized sweep engaged
            @test (nm, bitsame(fast, ref)) == (nm, true)
            @test (nm, length(unique(fast)) > 1) == (nm, true)
            append!(seen, vec(fast))
        end
        @test any(isnan, seen)
        @test any(x -> !isfinite(x) && !isnan(x), seen)
        @test any(x -> x === -0.0, seen)
    end

    @testset "CONTRACTING sweeps keep the fold term sequence" begin
        # A `-0.0` summand and a `NaN` summand both reach the accumulator here,
        # so a reordered or dropped term shows up as a bit difference.
        body = _op("*", _ix("A", "i", "j"), _ix("B", "i", "j"))
        for (nm, extra) in ("sum" => Dict{String,Any}(),
                            "min" => Dict{String,Any}("reduce" => "min"),
                            "max" => Dict{String,Any}("reduce" => "max"),
                            "prod" => Dict{String,Any}("reduce" => "prod"))
            j = _agg(["j"], ["i" => "I", "j" => "J"], body)
            merge!(j, extra)
            fast, ref, nf, nr = both_ways(j)
            @test (nm, nf, nr) == (nm, 1, 0)
            @test (nm, bitsame(fast, ref)) == (nm, true)
            @test (nm, length(unique(fast)) > 1) == (nm, true)
        end
        # A NaN in the fold: `+` propagates it, so the contraction is not
        # vacuously finite.
        jn = _agg(["j"], ["i" => "I", "j" => "J"], _op("/", _ix("A", "i", "j"),
                                                          _ix("A", "i", "j")))
        fast, ref, nf, nr = both_ways(jn)
        @test (nf, nr) == (1, 0)
        @test bitsame(fast, ref)
        @test any(isnan, fast)
    end

    @testset "rank-2 output over TWO contracted indices" begin
        # Two contracted vars exercise the M-dimensional inner `CartesianIndices`
        # against the reference's nested `Iterators.product`.
        body = _op("*", _ix("R", "i", "v", "c"), _ix("A", "i", "j"))
        j = _agg(["i", "j"], ["i" => "I", "j" => "J", "v" => "V", "c" => "C"], body)
        fast, ref, nf, nr = both_ways(j)
        @test (nf, nr) == (1, 0)
        @test bitsame(fast, ref)
        @test length(unique(fast)) > 1
    end

    @testset "join gate and filter still reject the same cells" begin
        # A bin-equality join over the output indices of a MAP: rejected cells
        # must keep the zero-initialized 0̄ on BOTH paths.
        body = _op("+", _ix("A", "i", "j"), "s")
        j = _agg(["i", "j"], ["i" => "I", "j" => "J"], body;
                 join = Any[Dict{String,Any}("on" => Any[Any["kI", "kJ"]])])
        fast, ref, nf, nr = both_ways(j)
        @test (nf, nr) == (1, 0)
        @test bitsame(fast, ref)
        @test any(iszero, fast)            # the gate really rejected something
        @test !all(iszero, fast)
        # ... and the same gate on the CONTRACTED index, with a filter on top.
        jc = _agg(["j"], ["i" => "I", "j" => "J"], _ix("B", "i", "j");
                  join = Any[Dict{String,Any}("on" => Any[Any["kI", "kJ"]])],
                  filter = _op(">", _ix("A", "i", "j"), "thr"))
        fastc, refc, nfc, nrc = both_ways(jc)
        @test (nfc, nrc) == (1, 0)
        @test bitsame(fastc, refc)
        @test length(unique(fastc)) > 1
    end

    @testset "nested aggregate in the body" begin
        # `:geo_agg` allocates its own frame slots from the shared counter, so
        # the specialized sweep must not disturb them.
        inner = _agg(String[], ["v" => "V"], _ix("R", "i", "v", 1))
        j = _agg(["i", "j"], ["i" => "I", "j" => "J"],
                 _op("*", inner, _ix("A", "i", "j")))
        fast, ref, nf, nr = both_ways(j)
        @test (nf, nr) == (1, 0)
        @test bitsame(fast, ref)
        @test length(unique(fast)) > 1
    end

    @testset "rank-0 output (a scalar reduction)" begin
        # `out` empty ⇒ a 0-dimensional `Array{Float64,0}`. `CartesianIndices`
        # yields exactly one empty index, as `Iterators.product()` yields one
        # empty tuple — the arm must not fall over on N == 0.
        j = _agg(String[], ["i" => "I", "j" => "J"],
                 _op("*", _ix("A", "i", "j"), _ix("B", "i", "j")))
        fast, ref, nf, nr = both_ways(j)
        @test (nf, nr) == (1, 0)
        @test bitsame(fast, ref)
        @test ndims(fast) == 0
    end

    @testset "narrowed and generic gather arms agree" begin
        # `_geo_gather_value` / `_geo_ring_value` narrow an `Array{Float64,1..3}`
        # payload with a concrete `isa` so the read dispatches statically; every
        # other source type keeps the generic call. Both sweeps in this file go
        # through those arms, so the kill switch cannot oracle them — feed the
        # SAME values through a source type that MISSES the narrowed arms (a
        # `SubArray`) and demand the same array back.
        big = Float64[(-1.0)^(i + j) * (i - 3) * (j - 2) / 4 for i in 1:7, j in 1:6]
        vA = view(big, 1:5, 1:4)
        @test vA == A                       # same values, different type
        @test !(vA isa Array{Float64,2})    # ... and it really misses the arm
        bodies = (_op("/", _ix("A", "i", "j"), _ix("A", "i", "j")),
                  _op("*", _ix("A", "i", "j"), "s"),
                  _op("ifelse", _op(">", _ix("A", "i", "j"), "thr"),
                      _op("/", "s", _ix("A", "i", "j")),
                      _op("*", -1.0, _op("*", 0.0, _ix("B", "i", "j")))))
        for body in bodies
            j = _agg(["i", "j"], ["i" => "I", "j" => "J"], body)
            rhs = EA.expression_from_json(j)
            dense = EA._materialize_geom_array(rhs, copy(ENV0), nothing, IDX, SHAPES)
            envv = merge(copy(ENV0), Dict{String,Any}("A" => vA))
            sub = EA._materialize_geom_array(rhs, envv, nothing, IDX, SHAPES)
            @test bitsame(dense, sub)
            @test length(unique(dense)) > 1
        end
    end

    @testset "polygon_intersection_area sweep (the A_ij shape)" begin
        # The dominant sweep of a conservative regrid: a dense `A_ij[i,j] =
        # polygon_intersection_area(src[i], tgt[j])` MAP whose body is ONE
        # `:geo_pia` node over two `_GeoRingRef` operands. Most pairs are
        # disjoint, so the matrix is mostly exact `0.0` — which is what makes
        # `isequal` (not `≈`) the right bar: a `-0.0` here would be a bug.
        srcp = zeros(Float64, 6, 4, 2)
        tgtp = zeros(Float64, 3, 4, 2)
        function sq!(R, p, x, y, w)
            R[p, 1, 1] = x;     R[p, 1, 2] = y
            R[p, 2, 1] = x + w; R[p, 2, 2] = y
            R[p, 3, 1] = x + w; R[p, 3, 2] = y + w
            R[p, 4, 1] = x;     R[p, 4, 2] = y + w
        end
        for p in 1:6
            sq!(srcp, p, (p - 1) * 0.5, 0.0, 0.5)
        end
        for p in 1:3
            sq!(tgtp, p, (p - 1) * 1.0, 0.0, 1.0)
        end
        env = Dict{String,Any}("src_poly" => srcp, "tgt_poly" => tgtp)
        pia = Dict{String,Any}("op" => "polygon_intersection_area",
                               "manifold" => "planar",
                               "args" => Any[_ix("src_poly", "i"), _ix("tgt_poly", "j")])
        j = _agg(["i", "j"], ["i" => "S", "j" => "T"], pia)
        idx = Dict{String,Int}("S" => 6, "T" => 3)
        rhs = EA.expression_from_json(j)
        f0, r0 = EA._GEOM_SWEEP_FAST[], EA._GEOM_SWEEP_REF[]
        fast = EA._materialize_geom_array(rhs, copy(env), nothing, idx,
                                          Dict{String,Vector{String}}())
        @test (EA._GEOM_SWEEP_FAST[] - f0, EA._GEOM_SWEEP_REF[] - r0) == (1, 0)
        ref = withenv("ESS_GEOM_SWEEP_SPECIALIZE_DISABLE" => "1") do
            EA._materialize_geom_array(rhs, copy(env), nothing, idx,
                                       Dict{String,Vector{String}}())
        end
        @test bitsame(fast, ref)
        @test count(!iszero, fast) == 6          # each src square sits in one tgt
        @test any(iszero, fast)                  # ... and the rest are exact zero
        @test all(x -> !(x === -0.0), fast)

        # The `:geo_pia` arm narrows `_GeoRingRef` operands with a concrete
        # `isa`; a WHOLE-ARRAY operand misses that arm and takes the generic
        # call. Same two polygons either way ⇒ same area, bit for bit.
        env2 = merge(copy(env), Dict{String,Any}(
            "ring_a" => Array{Float64}(srcp[1, :, :]),
            "ring_b" => Array{Float64}(tgtp[1, :, :])))
        whole = Dict{String,Any}("op" => "polygon_intersection_area",
                                 "manifold" => "planar",
                                 "args" => Any["ring_a", "ring_b"])
        jw = _agg(["i"], ["i" => "S"], whole)
        got = EA._materialize_geom_array(EA.expression_from_json(jw), env2, nothing,
                                         idx, Dict{String,Vector{String}}())
        @test all(x -> isequal(x, fast[1, 1]), got)
        @test !iszero(fast[1, 1])
    end

    @testset "kill switch keeps the rank-abstract reference available" begin
        j = _agg(["i", "j"], ["i" => "I", "j" => "J"], _ix("A", "i", "j"))
        rhs = EA.expression_from_json(j)
        f0, r0 = EA._GEOM_SWEEP_FAST[], EA._GEOM_SWEEP_REF[]
        withenv("ESS_GEOM_SWEEP_SPECIALIZE_DISABLE" => "1") do
            EA._materialize_geom_array(rhs, copy(ENV0), nothing, IDX, SHAPES)
        end
        @test EA._GEOM_SWEEP_REF[] - r0 == 1     # forced onto the reference
        @test EA._GEOM_SWEEP_FAST[] - f0 == 0
    end

    @testset "verify mode agrees on the same arrays" begin
        for j in (_agg(["i", "j"], ["i" => "I", "j" => "J"],
                       _op("/", _ix("A", "i", "j"), _ix("A", "i", "j"))),
                  _agg(["j"], ["i" => "I", "j" => "J"],
                       _op("*", _ix("A", "i", "j"), _ix("B", "i", "j"))))
            rhs = EA.expression_from_json(j)
            got = withenv("ESS_GEOM_SWEEP_VERIFY" => "1") do
                EA._materialize_geom_array(rhs, copy(ENV0), nothing, IDX, SHAPES)
            end                              # throws unless bit-identical
            ref = withenv("ESS_GEOM_SWEEP_SPECIALIZE_DISABLE" => "1") do
                EA._materialize_geom_array(rhs, copy(ENV0), nothing, IDX, SHAPES)
            end
            @test bitsame(got, ref)
        end
    end

    @testset "verify mode CATCHES a divergence" begin
        # The oracle is only worth having if it fires. Feed the assertion two
        # arrays that differ in exactly the way `==` would miss.
        a = Float64[0.0 1.0; NaN 3.0]
        b = Float64[-0.0 1.0; NaN 3.0]
        @test_throws EarthSciAST.TreeWalkError EA._assert_geom_sweep_bit_identical(
            a, b, ["i", "j"])
        c = Float64[0.0 1.0; 2.0 3.0]
        @test_throws EarthSciAST.TreeWalkError EA._assert_geom_sweep_bit_identical(
            a, c, ["i", "j"])          # NaN vs 2.0
        @test EA._assert_geom_sweep_bit_identical(a, copy(a), ["i", "j"]) === nothing
    end

end

end # module
