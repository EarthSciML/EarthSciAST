# The geometry materializer's rank-specialized sweeps (`_geom_sweep_map!`,
# `_geom_sweep_contract!`), checked against arrays computed by hand from the
# same inputs. `CartesianIndices` visits a column-major product first index
# fastest, so the assignment order and the CONTRACTION FOLD ORDER are the term
# sequence the document defines; the expectations below fold in that order and
# demand `isequal` cell for cell — never `≈` and never `==`: `-0.0` must not
# pass for `+0.0` and `NaN` must match `NaN`.

using Test
include("testutils.jl")
using EarthSciAST
const EA = EarthSciAST

# ---- small JSON AST builders ----
function _agg(output_idx, ranges, expr; kw...)
    d = Dict{String, Any}(
        "op" => "faq", "output_idx" => collect(output_idx),
        "ranges" => Dict{String, Any}(
            k => (v isa AbstractString ? Dict{String, Any}("from" => v) : v)
                for (k, v) in ranges
        ),
        "args" => Any[], "expr" => expr
    )
    for (k, v) in kw
        d[String(k)] = v
    end
    return d
end

const IDX = Dict{String, Int}("I" => 5, "J" => 4, "V" => 3, "C" => 2)

# A source field carrying a signed zero, negatives and a huge value, so the
# bodies below actually produce -0.0, ±Inf and NaN.
const A = Float64[(-1.0)^(i + j) * (i - 3) * (j - 2) / 4 for i in 1:5, j in 1:4]
const B = Float64[i + 10j for i in 1:5, j in 1:4]
const R = Float64[i + 0.25v + 0.5c for i in 1:5, v in 1:3, c in 1:2]
const KI = Float64[mod(i, 2) for i in 1:5]
const KJ = Float64[mod(j, 2) for j in 1:4]
const ENV0 = Dict{String, Any}(
    "A" => A, "B" => B, "R" => R, "kI" => KI, "kJ" => KJ,
    "s" => 1.5, "thr" => 0.0
)
const SHAPES = Dict{String, Vector{String}}("kI" => ["I"], "kJ" => ["J"])

# Materialize `json` under the default compiler.
materialize(json, env = ENV0, idx = IDX) =
    EA._materialize_geom_array(EA.expression_from_json(json), copy(env), nothing, idx, SHAPES)

# The contracted indices in the order the sweep nests them (first fastest).
contracted(json) = (
    rhs = EA.expression_from_json(json);
    String[k for k in keys(rhs.ranges) if !(k in rhs.output_idx)]
)

@testset "geometry sweep rank specialization" begin

    @testset "zero codegen budget walks small geometry sweeps in a non-strict build" begin
        doc = _agg(["i", "j"], ["i" => "I", "j" => "J"], jop("*", jidx("A", "i", "j"), "s"))
        strict = EA._compiler_plan(:native)
        lax = EA._plan_with(strict; strict = false)
        for (plan, budget, copies, emits) in (
                (lax, "1000", 1, true), (lax, "0", 1, false),
                (lax, "0", 4, true), (strict, "0", 1, true),
            )
            field = repeat(A, copies, 1)
            env = merge(ENV0, Dict("A" => field))
            idx = merge(IDX, Dict("I" => size(field, 1)))
            got, counts = withenv("ESS_CODEGEN_NODE_BUDGET" => budget) do
                EA._with_compiler_plan(plan) do
                    EA.Internal.counting(() -> materialize(doc, env, idx))
                end
            end
            @test (get(counts, :geo_kernel, 0) > 0) == emits
            @test bitsame(got, field .* ENV0["s"])
        end
    end

    @testset "MAP sweeps at ranks 1, 2 and 3" begin
        Aij = jidx("A", "i", "j")
        Bij = jidx("B", "i", "j")
        s, thr = 1.5, 0.0
        cases = Dict(
            # rank 2, signed zero out of the false arm of a gated branch
            "rank2_gated" => (
                _agg(
                    ["i", "j"], ["i" => "I", "j" => "J"],
                    jop(
                        "ifelse", jop(">", Aij, "thr"),
                        jop("*", Aij, "s"), jop("*", -1.0, jop("*", 0.0, Bij))
                    )
                ),
                [A[i, j] > thr ? A[i, j] * s : -1.0 * (0.0 * B[i, j]) for i in 1:5, j in 1:4],
            ),
            # rank 2, ±Inf where A is zero
            "rank2_inf" => (
                _agg(["i", "j"], ["i" => "I", "j" => "J"], jop("/", "s", Aij)),
                [s / A[i, j] for i in 1:5, j in 1:4],
            ),
            # rank 2, NaN (0/0) where A is zero
            "rank2_nan" => (
                _agg(["i", "j"], ["i" => "I", "j" => "J"], jop("/", Aij, Aij)),
                [A[i, j] / A[i, j] for i in 1:5, j in 1:4],
            ),
            # rank 1
            "rank1" => (
                _agg(["i"], ["i" => "I"], jop("/", "s", jidx("A", "i", 2))),
                [s / A[i, 2] for i in 1:5],
            ),
            # rank 3 over a [pos, vert, coord] ring stack — the shape a
            # constructed cell ring materializes into
            "rank3" => (
                _agg(
                    ["i", "v", "c"], ["i" => "I", "v" => "V", "c" => "C"],
                    jop(
                        "+", jop("*", jidx("R", "i", "v", "c"), "s"),
                        jop("-", jidx("R", "i", "v", "c"), jidx("A", "i", 1))
                    )
                ),
                [R[i, v, c] * s + (R[i, v, c] - A[i, 1]) for i in 1:5, v in 1:3, c in 1:2],
            ),
        )
        seen = Float64[]
        for (nm, (j, want)) in cases
            got = materialize(j)
            @test (nm, bitsame(got, want)) == (nm, true)
            @test (nm, length(unique(got)) > 1) == (nm, true)
            append!(seen, vec(got))
        end
        @test any(isnan, seen)
        @test any(x -> !isfinite(x) && !isnan(x), seen)
        @test any(x -> x === -0.0, seen)
    end

    @testset "CONTRACTING sweeps keep the fold term sequence" begin
        # A `-0.0` summand and a `NaN` summand both reach the accumulator here,
        # so a reordered or dropped term shows up as a bit difference.
        body = jop("*", jidx("A", "i", "j"), jidx("B", "i", "j"))
        for (nm, extra, init, f) in (
                ("sum", Dict{String, Any}(), 0.0, +),
                ("min", Dict{String, Any}("reduce" => "min"), Inf, min),
                ("max", Dict{String, Any}("reduce" => "max"), -Inf, max),
                ("prod", Dict{String, Any}("reduce" => "prod"), 1.0, *),
            )
            j = _agg(["j"], ["i" => "I", "j" => "J"], body)
            merge!(j, extra)
            want = [foldl(f, (A[i, jj] * B[i, jj] for i in 1:5); init = init) for jj in 1:4]
            got = materialize(j)
            @test (nm, bitsame(got, want)) == (nm, true)
            @test (nm, length(unique(got)) > 1) == (nm, true)
        end
        # A NaN in the fold: `+` propagates it, so the contraction is not
        # vacuously finite.
        jn = _agg(
            ["j"], ["i" => "I", "j" => "J"], jop(
                "/", jidx("A", "i", "j"),
                jidx("A", "i", "j")
            )
        )
        got = materialize(jn)
        @test bitsame(got, [foldl(+, (A[i, jj] / A[i, jj] for i in 1:5); init = 0.0) for jj in 1:4])
        @test any(isnan, got)
    end

    @testset "rank-2 output over TWO contracted indices" begin
        # Two contracted vars: the inner `CartesianIndices` nests them first
        # fastest, in the order the sweep lists them.
        body = jop("*", jidx("R", "i", "v", "c"), jidx("A", "i", "j"))
        j = _agg(["i", "j"], ["i" => "I", "j" => "J", "v" => "V", "c" => "C"], body)
        ext = Dict("v" => 3, "c" => 2)
        con = contracted(j)
        term(i, jj, b) = R[i, b["v"], b["c"]] * A[i, jj]
        want = [
            foldl(
                +, (
                    term(i, jj, Dict(con[1] => x, con[2] => y))
                        for y in 1:ext[con[2]] for x in 1:ext[con[1]]
                ); init = 0.0
            )
                for i in 1:5, jj in 1:4
        ]
        got = materialize(j)
        @test bitsame(got, want)
        @test length(unique(got)) > 1
    end

    @testset "join gate and filter reject cells" begin
        # A bin-equality join over the output indices of a MAP: rejected cells
        # keep the zero-initialized 0̄. Under `native` such a gate drives the
        # sweep from its key matches (geom_on_drive_test.jl); these cases turn
        # that driver off so the DENSE sweep is the one checked.
        dense = EA._plan_with(EA._compiler_plan(:native); strict = false, join_on_gate = false)
        dense_mat(j) = EA._with_compiler_plan(() -> materialize(j), dense)
        body = jop("+", jidx("A", "i", "j"), "s")
        j = _agg(
            ["i", "j"], ["i" => "I", "j" => "J"], body;
            join = Any[Dict{String, Any}("on" => Any[Any["kI", "kJ"]])]
        )
        got = dense_mat(j)
        @test bitsame(got, [KI[i] == KJ[jj] ? A[i, jj] + 1.5 : 0.0 for i in 1:5, jj in 1:4])
        @test any(iszero, got)            # the gate really rejected something
        @test !all(iszero, got)
        # ... and the same gate on the CONTRACTED index, with a filter on top.
        jc = _agg(
            ["j"], ["i" => "I", "j" => "J"], jidx("B", "i", "j");
            join = Any[Dict{String, Any}("on" => Any[Any["kI", "kJ"]])],
            filter = jop(">", jidx("A", "i", "j"), "thr")
        )
        gotc = dense_mat(jc)
        wantc = [
            foldl(+, (B[i, jj] for i in 1:5 if KI[i] == KJ[jj] && A[i, jj] > 0.0); init = 0.0)
                for jj in 1:4
        ]
        @test bitsame(gotc, wantc)
        @test length(unique(gotc)) > 1
    end

    @testset "nested aggregate in the body" begin
        # `:geo_agg` allocates its own frame slots from the shared counter, so
        # the sweep must not disturb them.
        inner = _agg(String[], ["v" => "V"], jidx("R", "i", "v", 1))
        j = _agg(
            ["i", "j"], ["i" => "I", "j" => "J"],
            jop("*", inner, jidx("A", "i", "j"))
        )
        got = materialize(j)
        want = [foldl(+, (R[i, v, 1] for v in 1:3); init = 0.0) * A[i, jj] for i in 1:5, jj in 1:4]
        @test bitsame(got, want)
        @test length(unique(got)) > 1
    end

    @testset "rank-0 output (a scalar reduction)" begin
        # `out` empty ⇒ a 0-dimensional `Array{Float64,0}`; `CartesianIndices`
        # yields exactly one empty index, so the arm must not fall over on N == 0.
        j = _agg(
            String[], ["i" => "I", "j" => "J"],
            jop("*", jidx("A", "i", "j"), jidx("B", "i", "j"))
        )
        con = contracted(j)
        ext = Dict("i" => 5, "j" => 4)
        terms = (
            (b = Dict(con[1] => x, con[2] => y); A[b["i"], b["j"]] * B[b["i"], b["j"]])
                for y in 1:ext[con[2]] for x in 1:ext[con[1]]
        )
        got = materialize(j)
        @test ndims(got) == 0
        @test isequal(got[], foldl(+, terms; init = 0.0))
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
        @test !(vA isa Array{Float64, 2})    # ... and it really misses the arm
        bodies = (
            jop("/", jidx("A", "i", "j"), jidx("A", "i", "j")),
            jop("*", jidx("A", "i", "j"), "s"),
            jop(
                "ifelse", jop(">", jidx("A", "i", "j"), "thr"),
                jop("/", "s", jidx("A", "i", "j")),
                jop("*", -1.0, jop("*", 0.0, jidx("B", "i", "j")))
            ),
        )
        for body in bodies
            j = _agg(["i", "j"], ["i" => "I", "j" => "J"], body)
            rhs = EA.expression_from_json(j)
            dense = EA._materialize_geom_array(rhs, copy(ENV0), nothing, IDX, SHAPES)
            envv = merge(copy(ENV0), Dict{String, Any}("A" => vA))
            sub = EA._materialize_geom_array(rhs, envv, nothing, IDX, SHAPES)
            @test bitsame(dense, sub)
            @test length(unique(dense)) > 1
        end
    end

    @testset "overlap-area sweep (the A_ij shape)" begin
        # The dominant sweep of a conservative regrid: a dense `A_ij[i,j]` MAP
        # of the overlap area of `src[i]` and `tgt[j]` (here two axis-aligned
        # squares, the product of the axes' clamped interval overlaps). Most
        # pairs are disjoint, so the matrix is mostly exact `0.0` — which is
        # what makes `isequal` (not `≈`) the right bar: a `-0.0` here would be a
        # bug.
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
        env = Dict{String, Any}("src_poly" => srcp, "tgt_poly" => tgtp)
        # The SW (vertex 1) and NE (vertex 3) corners of the two squares.
        ov(c) = jop(
            "max", 0.0, jop(
                "-",
                jop("min", jidx("src_poly", "i", 3, c), jidx("tgt_poly", "j", 3, c)),
                jop("max", jidx("src_poly", "i", 1, c), jidx("tgt_poly", "j", 1, c))
            )
        )
        pia = jop("*", ov(1), ov(2))
        j = _agg(["i", "j"], ["i" => "S", "j" => "T"], pia)
        idx = Dict{String, Int}("S" => 6, "T" => 3)
        rhs = EA.expression_from_json(j)
        fast = EA._materialize_geom_array(
            rhs, copy(env), nothing, idx,
            Dict{String, Vector{String}}()
        )
        @test bitsame(fast, [cld(p, 2) == q ? 0.25 : 0.0 for p in 1:6, q in 1:3])
        @test count(!iszero, fast) == 6          # each src square sits in one tgt
        @test any(iszero, fast)                  # ... and the rest are exact zero
        @test all(x -> !(x === -0.0), fast)
    end

end
