# A `makearray` whose region value is an array `faq` with a rank-0 `faq`
# reduction nested in its body (issue #547, the EarthSciASTDiff contracted-band
# shape):
#
#     D(J[i]) = makearray([[1,N]], [[1,N]]; [0, faq_i( Σ_j body(i, j) )])
#
# Native used to refuse it: with the cell index symbolic the whole-array nest
# could not pick the makearray's region. It now takes one equation per region
# (`_makearray_region_equations`), and the nest keeps the nested reduction as a
# counted loop (`_NEST_SCALAR_LOOPS`) instead of unrolling one term per `j` into
# its one body. This pins, against `compiler=:interpreter` (the per-cell unroll):
#
#   * bit-identity, `===` per element, for one region, `[0, nested]` over the same
#     box, overlapping regions where the last wins, a gap left at 0, and a `+`
#     fold whose terms are all `-0.0` (`+0.0`, from the 0̄ seed, esm-spec §4.3.1);
#   * the same values as the bare `faq` with no `makearray` around it;
#   * a region value that contracts an index itself, folded as the interpreter's
#     gather folds it, for every numeric ⊕;
#   * the route: the whole-array nest, no per-cell build, and report rows that
#     name the equation each region's piece came from;
#   * node lowerings flat in N, zero allocation per steady call, and ForwardDiff
#     through the loop.

using Test
using ForwardDiff
include("testutils.jl")
include("zero_alloc_harness.jl")

const _MNR = EarthSciAST

_mnr_idx(v, i) = Dict{String,Any}("op" => "index", "args" => Any[v, i])
_mnr_faq(out, ranges, expr; reduce=nothing) = begin
    d = Dict{String,Any}("op" => "faq", "args" => Any[], "output_idx" => Any[out...],
                         "ranges" => ranges, "expr" => expr)
    reduce === nothing || (d["reduce"] = reduce)
    d
end
_mnr_ma(regions, values) = Dict{String,Any}("op" => "makearray", "args" => Any[],
    "regions" => Any[Any[Any[r...] for r in reg] for reg in regions], "values" => Any[values...])

_mnr_term(term) =
    term === :prod ? Dict{String,Any}("op" => "*", "args" => Any[_mnr_idx("u", "i"), _mnr_idx("u", "j")]) :
    # `-(0·u[i]·u[j])`: a `-0.0` literal reads back as the integer 0.
    term === :negzero ? Dict{String,Any}("op" => "-", "args" => Any[
        Dict{String,Any}("op" => "*", "args" => Any[
            Dict{String,Any}("op" => "*", "args" => Any[0.0, _mnr_idx("u", "i")]),
            _mnr_idx("u", "j")])]) :
    error("term")

# Σ_{j=jlo..jhi} term(i, j) for each i in ilo..ihi, as an array faq over `i`.
_mnr_nested(N; term=:prod, jlo=1, jhi=N, ilo=1, ihi=N) =
    _mnr_faq(["i"], Dict{String,Any}("i" => Any[ilo, ihi]),
             _mnr_faq(String[], Dict{String,Any}("j" => Any[jlo, jhi]), _mnr_term(term);
                      reduce="+"))

# The same reduction as ONE array faq that contracts `j` itself, with no rank-0
# faq inside: `faq_i ⊕_j term(i, j)`.
_mnr_contracting(N; term=:prod, reduce="+", ilo=1, ihi=N) =
    _mnr_faq(["i"], Dict{String,Any}("i" => Any[ilo, ihi], "j" => Any[1, N]), _mnr_term(term);
             reduce=reduce)

function _mnr_doc(N, rhs)
    Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "MakearrayNested"),
      "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => N)),
      "models" => Dict("M" => Dict{String,Any}(
        "variables" => Dict(
            "u" => Dict("type" => "unknown", "shape" => Any["x"], "default" => 0.5),
            "J" => Dict("type" => "unknown", "shape" => Any["x"], "default" => 0.0)),
        "equations" => Any[
            Dict("lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                 "rhs" => _mnr_faq(["i"], Dict{String,Any}("i" => Any[1, N]), 0.0)),
            Dict("lhs" => Dict("op" => "D", "args" => Any["J"], "wrt" => "t"), "rhs" => rhs)])))
end

# Alternating 1e8 magnitudes: the products alternate 1e16, so a fold in any order
# but the per-cell build's left-to-right one differs in whole units.
_mnr_u(k) = isodd(k) ? 1e8 * (1 + k / 7) : -(1e8 - k / 3)
_mnr_ics(N; u=_mnr_u) = merge(Dict{String,Any}("u[$k]" => u(k) for k in 1:N),
                              Dict{String,Any}("J[$k]" => 0.0 for k in 1:N))

function _mnr_build(doc, ics; compiler=:native)
    _MNR._reset_cascade_tally!()
    r = _MNR._build_evaluator(doc; initial_conditions=ics, compiler=compiler)
    (r, copy(_MNR._CASCADE_TALLY))
end
function _mnr_du(doc, ics; compiler=:native)
    (f!, u0, p, _, vm), tally = _mnr_build(doc, ics; compiler=compiler)
    du = similar(u0); f!(du, u0, p, 0.0)
    N = count(k -> startswith(k, "J["), keys(vm))
    ([du[vm["J[$i]"]] for i in 1:N], tally)
end
_mnr_same(a, b) = length(a) == length(b) && all(a[k] === b[k] for k in eachindex(a))

@testset "makearray region value with a nested scalar reduction (#547)" begin
    one_region(N; kw...) = _mnr_ma([[(1, N)]], [_mnr_nested(N; kw...)])
    two_regions(N; kw...) = _mnr_ma([[(1, N)], [(1, N)]], [0, _mnr_nested(N; kw...)])

    @testset "the issue's reproducer, N=$N" for N in (6, 40)
        ics = _mnr_ics(N)
        ref, _ = _mnr_du(_mnr_doc(N, _mnr_nested(N)), ics; compiler=:interpreter)
        for (name, rhs) in (("bare", _mnr_nested(N)), ("one region", one_region(N)),
                            ("[0, nested]", two_regions(N)))
            interp, _ = _mnr_du(_mnr_doc(N, rhs), ics; compiler=:interpreter)
            nat, tally = _mnr_du(_mnr_doc(N, rhs), ics; compiler=:native)
            @test _mnr_same(nat, interp)
            @test _mnr_same(nat, ref)
            # A reduction shorter than the contraction loop's floor is unrolled
            # by the affine tier, as a top-level one is; a longer one is kept a
            # loop by the whole-array nest.
            if N >= _MNR._contraction_loop_min()
                @test get(tally, :array_contraction_codegen, 0) >= 1
            else
                @test get(tally, :affine, 0) >= 1
            end
            @test get(tally, :percell_acc, 0) == 0
        end
        # The data make the fold order visible: the exact sum is not the fold.
        @test ref[1] != sum(big(_mnr_u(1)) * big(_mnr_u(j)) for j in 1:N)
    end

    @testset "every term -0.0 sums to +0.0 (N=$N)" for N in (6, 40)
        ics = _mnr_ics(N; u=k -> 1.0 + k)
        interp, _ = _mnr_du(_mnr_doc(N, two_regions(N; term=:negzero)), ics; compiler=:interpreter)
        nat, _ = _mnr_du(_mnr_doc(N, two_regions(N; term=:negzero)), ics; compiler=:native)
        @test all(x -> x === 0.0, interp)
        @test _mnr_same(nat, interp)
    end

    # A region value that contracts `j` itself. The interpreter reads it as the
    # gather `index(<faq>, i)`, a fold from the semiring's 0̄, so under `+` every
    # `-0.0` term sums to `+0.0`; a piece unwraps the gather to the bare
    # contraction, which folds from the same seed. The partials under
    # ForwardDiff are all `-0.0` here, which the `Float64` seed leaves as they are.
    # Alone in its makearray the value is the affine tier's; next to a nested
    # reduction, which that tier declines, the equation is split by region.
    @testset "a contracting region value folds as the interpreter does ($reduce, N=$N)" for
            N in (6, 40), reduce in ("+", "max", "min", "*")
        ics = _mnr_ics(N; u=k -> 1.0 + k)
        h = N ÷ 2
        alone = _mnr_ma([[(1, N)], [(1, N)]],
                        [0, _mnr_contracting(N; term=:negzero, reduce=reduce)])
        beside = _mnr_ma([[(1, h)], [(h + 1, N)]],
                         [_mnr_nested(N; term=:negzero, ihi=h),
                          _mnr_contracting(N; term=:negzero, reduce=reduce, ilo=h + 1)])
        for rhs in (alone, beside)
            interp, _ = _mnr_du(_mnr_doc(N, rhs), ics; compiler=:interpreter)
            nat, tally = _mnr_du(_mnr_doc(N, rhs), ics; compiler=:native)
            reduce == "+" && @test all(x -> x === 0.0, interp)
            @test _mnr_same(nat, interp)
            @test get(tally, :percell_acc, 0) == 0
            grads = map((:interpreter, :native)) do c
                (f!, u0, p, _, vm), _ = _mnr_build(_mnr_doc(N, rhs), ics; compiler=c)
                g(u) = (d = similar(u, eltype(u)); f!(d, u, p, 0.0); d[vm["J[3]"]])
                ForwardDiff.gradient(g, u0)
            end
            @test _mnr_same(grads[1], grads[2])
        end
    end

    # A region bound the build cannot hold as an `Int` keeps the whole equation
    # (no split) rather than throwing out of the build.
    @testset "a region bound past Int64 does not split" begin
        @test _MNR._ma_region_bound(12.0) === 12
        @test _MNR._ma_region_bound(12) === 12
        @test _MNR._ma_region_bound(12.5) === nothing
        @test _MNR._ma_region_bound(1e20) === nothing
        @test _MNR._ma_region_bound(-1e20) === nothing
        @test _MNR._ma_region_bound(2.0^63) === nothing
        @test _MNR._ma_region_bound(-2.0^63) === typemin(Int)
        @test _MNR._ma_region_bound(Int128(2)^70) === nothing
        # A document cannot carry such a bound (the parser keeps integers), but
        # a makearray built in code can.
        N = 24
        lhs_body = EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.OpExpr("index",
            EarthSciAST.ASTExpr[EarthSciAST.VarExpr("J"), EarthSciAST.VarExpr("i")])]; wrt="t")
        lhs = EarthSciAST.OpExpr("faq", EarthSciAST.ASTExpr[]; output_idx=Any["i"],
            ranges=Dict{String,Any}("i" => Any[1, N]), expr_body=lhs_body)
        split_at(hi) = _MNR._makearray_region_equations(
            EarthSciAST.Equation(lhs, EarthSciAST.OpExpr("index", EarthSciAST.ASTExpr[
                EarthSciAST.OpExpr("makearray", EarthSciAST.ASTExpr[];
                    regions=[[Any[1, hi]]], values=EarthSciAST.ASTExpr[EarthSciAST.NumExpr(7.5)]),
                EarthSciAST.VarExpr("i")])),
            lhs, lhs_body, ["i"], [1:N])
        @test split_at(1e20) === nothing
        @test split_at(Float64(N)) isa Vector && length(split_at(Float64(N))) == 1
    end

    @testset "overlapping regions, a window, a gap" begin
        N = 24
        ics = _mnr_ics(N)
        rank0 = _mnr_faq(String[], Dict{String,Any}("j" => Any[1, N]), _mnr_idx("u", "j");
                         reduce="+")
        # Last wins: 7.5 on 1..3, the windowed sum on 2..24 except cell 12, the
        # rank-0 total at 12; then a second document with a 0 gap at 9..14. A
        # region value's own range is its region (esm-spec §4.3.2).
        overlap = _mnr_ma([[(1, 3)], [(2, N)], [(12, 12)]],
                          [7.5, _mnr_nested(N; jlo=3, jhi=N - 2, ilo=2), rank0])
        gap = _mnr_ma([[(1, 8)], [(15, N)]], [_mnr_nested(N; ihi=8), 2.0])
        for rhs in (overlap, gap)
            interp, _ = _mnr_du(_mnr_doc(N, rhs), ics; compiler=:interpreter)
            nat, tally = _mnr_du(_mnr_doc(N, rhs), ics; compiler=:native)
            @test _mnr_same(nat, interp)
            @test get(tally, :percell_acc, 0) == 0
        end
        g, _ = _mnr_du(_mnr_doc(N, gap), ics; compiler=:native)
        @test all(iszero, g[9:14]) && all(==(2.0), g[15:N])
        o, _ = _mnr_du(_mnr_doc(N, overlap), ics; compiler=:native)
        @test o[1] == 7.5 && o[12] == foldl(+, (_mnr_u(j) for j in 1:N))
    end

    # Each region's piece is filed under the equation it came from, with what
    # that equation collected before it was split.
    @testset "the report names the equation the regions came from" begin
        N = 24
        rhs = _mnr_ma([[(1, 3)], [(2, N)], [(12, 12)]],
                      [7.5, _mnr_nested(N; jlo=3, jhi=N - 2, ilo=2),
                       _mnr_faq(String[], Dict{String,Any}("j" => Any[1, N]),
                                _mnr_idx("u", "j"); reduce="+")])
        insp = _MNR.BuildInspection()
        _MNR._build_evaluator(_mnr_doc(N, rhs); initial_conditions=_mnr_ics(N),
                              compiler=:native, inspect=insp)
        rows = [r for r in insp.compiler_report.rules if occursin("D(J)", r.rule)]
        # Later regions win: 1 (region 1), 2..3, 4..11 and 13..24 (region 2,
        # which do not tile a box), 12 (region 3).
        @test length(rows) == 5
        pieces = map(rows) do r
            m = match(r"^D\(J\)\[(\w+)=24\], makearray region (\d) \((\w+)=(\d+)\.\.(\d+)\)$", r.rule)
            m === nothing ? nothing :
                (m[1] == m[3], parse(Int, m[2]), parse(Int, m[4]), parse(Int, m[5]))
        end
        @test sort(pieces) == [(true, 1, 1, 1), (true, 2, 2, 3), (true, 2, 4, 11),
                               (true, 2, 13, 24), (true, 3, 12, 12)]
        @test all(r -> r.kind === :equation, rows)
        @test all(r -> r.tier in (:affine, :array_contraction_codegen), rows)
        # The equation's own decline, before the split, heads every piece's.
        @test all(r -> !isempty(r.declines) && r.declines[1].first === :affine, rows)
    end

    @testset "zero-allocation steady-state f!" begin
        N = 64
        (f!, u0, p, _, _), _ = _mnr_build(_mnr_doc(N, two_regions(N)), _mnr_ics(N))
        du = similar(u0)
        # Julia >= 1.12 only: older versions box across RuntimeGeneratedFunction inner functions and @testset-scope reads.
        if VERSION >= v"1.12"
            @test rhs_alloc_bytes(f!, du, u0, p, 0.0) == 0
        end
    end

    @testset "ForwardDiff through the nested loop" begin
        N = 20
        ics = _mnr_ics(N; u=k -> 0.25 * k + 0.5)
        grads = map((:interpreter, :native)) do c
            (f!, u0, p, _, vm), _ = _mnr_build(_mnr_doc(N, two_regions(N)), ics; compiler=c)
            g(u) = (d = similar(u, eltype(u)); f!(d, u, p, 0.0); d[vm["J[3]"]])
            ForwardDiff.gradient(g, u0)
        end
        @test _mnr_same(grads[1], grads[2])
    end

    @testset "node lowerings are flat in N" begin
        function nodes(N, rhs)
            _MNR._bench_reset!()
            _MNR._BENCH_ON[] = true
            try
                _MNR._build_evaluator(_mnr_doc(N, rhs); initial_conditions=_mnr_ics(N))
            finally
                _MNR._BENCH_ON[] = false
            end
            _MNR._BENCH_COMPILE_CALLS[]
        end
        for mk in (one_region, two_regions)
            @test nodes(16, mk(16)) == nodes(256, mk(256)) == nodes(1024, mk(1024))
        end
    end
end
