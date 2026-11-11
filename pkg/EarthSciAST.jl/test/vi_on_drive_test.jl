# The value-invention join driven by a bin-EQUALITY gate's key matches
# (`_vi_equality_candidates` / `_vi_enumerate_driven`, value_invention.jl).
#
# A `join.on [[src_bx, tgt_bx]]` producer — the regridder's candidate set over
# integer bin columns — used to test the gate on every tuple of the full
# product. The driven walk visits the ranges in the product's
# order and restricts the second gated symbol to the first one's partners, so
# the admitted tuples are the same ones in the same order. Every case compares
# against `compiler=:interpreter` (plan field `join_on_gate` off: the full
# product), and the visit counter shows the driven walk actually ran. The
# driven walk's allocation is bounded too: linear in the first gated range and
# the candidates, never a list of the second range per binding of the first.

module ViOnDriveTests

using Test
using EarthSciAST
import JSON3
const EA = EarthSciAST

_ix(a...) = Dict{String, Any}("op" => "index", "args" => Any[a...])
_op(o, a...) = Dict{String, Any}("op" => o, "args" => Any[a...])

# The regridder's candidate set over `n` source and `n` target cells: a bin
# column `floor(lon / dx)` per grid, and a `distinct` producer over (i, j)
# joined on it, keyed (i - 1)·n + (j - 1).
function _regrid(n)
    col(name, coord, step, sym, cells) = Dict{String, Any}(
        "lhs" => _ix(name, sym),
        "rhs" => Dict{String, Any}(
            "op" => "faq", "semiring" => "sum_product", "output_idx" => Any[sym],
            "ranges" => Dict{String, Any}(sym => Dict{String, Any}("from" => cells)),
            "args" => Any[coord, step], "expr" => _op("floor", _op("/", _ix(coord, sym), step))
        )
    )
    par(shape) = Dict{String, Any}("type" => "parameter", "shape" => Any[shape...])
    unk(shape) = Dict{String, Any}("type" => "unknown", "shape" => Any[shape...])
    vars = Dict{String, Any}(
        "src_lon" => par(["src_cells"]), "tgt_lon" => par(["tgt_cells"]), "dx" => par([]),
        "src_bx" => unk(["src_cells"]), "tgt_bx" => unk(["tgt_cells"]),
        "pair_exists" => unk(["candidate_pairs"])
    )
    eqs = Any[
        col("src_bx", "src_lon", "dx", "i", "src_cells"),
        col("tgt_bx", "tgt_lon", "dx", "j", "tgt_cells"),
        Dict{String, Any}(
            "lhs" => _ix("pair_exists", "p"),
            "rhs" => Dict{String, Any}(
                "op" => "faq", "id" => "candidate_set", "semiring" => "bool_and_or",
                "distinct" => true, "output_idx" => Any["p"],
                "ranges" => Dict{String, Any}(
                    "i" => Dict{String, Any}("from" => "src_cells"),
                    "j" => Dict{String, Any}("from" => "tgt_cells")
                ),
                "join" => Any[Dict{String, Any}("on" => Any[Any["src_bx", "tgt_bx"]])],
                "args" => Any["src_bx", "tgt_bx"],
                "key" => _op("+", _op("*", _op("-", "i", 1), n), _op("-", "j", 1)),
                "expr" => _op("true")
            )
        ),
    ]
    raw = Dict{String, Any}(
        "esm" => "2.0.0", "metadata" => Dict{String, Any}("name" => "vi_on_drive"),
        "index_sets" => Dict{String, Any}(
            "src_cells" => Dict{String, Any}("kind" => "interval", "size" => n),
            "tgt_cells" => Dict{String, Any}("kind" => "interval", "size" => n),
            "candidate_pairs" => Dict{String, Any}("kind" => "derived", "from_faq" => "candidate_set")
        ),
        "models" => Dict{String, Any}("Regrid" => Dict{String, Any}("variables" => vars, "equations" => eqs))
    )
    file = EA.coerce_esm_file(raw)
    return EA._select_model(file, "Regrid"), file.index_sets
end

# A value-invention context with the bin columns materialised.
function _ctx(m, isets, ca, params)
    ctx = EA._ViCtx(
        Dict{String, Any}(ca), Dict{String, Float64}(params),
        Dict{String, EA.IndexSet}(isets), m.variables,
        Dict{String, Dict{Any, Any}}(), EA._vi_seed_map(m)
    )
    for (v, node) in EA._vi_detect(m).columns
        EA._vi_materialize_column!(ctx, v, node)
    end
    return ctx
end

_interp(f) = EA._with_compiler_plan(f, EA._compiler_plan(:interpreter))

# Deterministic pseudo-random coordinates (no RNG-version dependence).
_lcg(n, seed, scale) = let s = UInt64(seed)
    [
        begin
            s = s * 0x5851f42d4c957f2d + 0x14057b7ef767814f
            scale * Float64(s >> 11) / Float64(1 << 53)
        end for _ in 1:n
    ]
end


@testset "value-invention bin-equality drive" begin

    @testset "regrid candidate-set producer" begin
        n = 60
        m, isets = _regrid(n)
        # Unit bins over [0, 6): about ten cells of each grid per bin.
        ca = Dict{String, Any}(
            "src_lon" => _lcg(n, 1, 6.0), "tgt_lon" => _lcg(n, 2, 6.0)
        )
        params = Dict("dx" => 1.0)
        EA._VI_ENUM_VISITS[] = 0
        vi = EA.materialize_value_invention(m, isets, ca, params)
        driven = EA._VI_ENUM_VISITS[]
        EA._VI_ENUM_VISITS[] = 0
        ref = _interp(() -> EA.materialize_value_invention(m, isets, ca, params))
        full = EA._VI_ENUM_VISITS[]
        @test isequal(vi.members["candidate_set"], ref.members["candidate_set"])
        @test length(vi.members["candidate_set"]) > n     # several pairs per bin
        @test full == n * n
        @test driven == length(vi.members["candidate_set"])

        # The admitted tuples, in visit order, are the product's.
        ctx = _ctx(m, isets, ca, params)
        node = only(EA._vi_detect(m).producers)[2]
        ranges = EA._vi_ranges(node)
        function admitted()
            local gs = EA._vi_resolve_join(node.join, ranges, ctx)
            local out = Tuple{Any, Any}[]
            EA._vi_enumerate_join(
                ranges, gs, ctx,
                b -> EA._vi_join_ok(gs, b) && push!(out, (b["i"], b["j"]))
            )
            return out, gs
        end
        got, gates = admitted()
        want, rgates = _interp(admitted)
        @test got == want
        @test gates[1].candidates !== nothing
        @test rgates[1].candidates === nothing
    end

    # The driven walk allocates O(N_first + |candidates|), not a list of the
    # second gated range per binding of the first (O(N_first × N_second)).
    @testset "driven walk allocation is linear" begin
        function regrid_walk(n)
            m, isets = _regrid(n)
            # About ten cells of each grid per unit bin.
            ca = Dict{String, Any}(
                "src_lon" => _lcg(n, 1, n / 10), "tgt_lon" => _lcg(n, 2, n / 10)
            )
            params = Dict("dx" => 1.0)
            ctx = _ctx(m, isets, ca, params)
            node = only(EA._vi_detect(m).producers)[2]
            ranges = EA._vi_ranges(node)
            gs = EA._vi_resolve_join(node.join, ranges, ctx)
            cb = _ -> nothing
            EA._vi_enumerate_join(ranges, gs, ctx, cb)          # compile
            EA._VI_ENUM_VISITS[] = 0
            bytes = @allocated EA._vi_enumerate_join(ranges, gs, ctx, cb)
            return bytes, EA._VI_ENUM_VISITS[]
        end
        small, v_small = regrid_walk(500)
        big, v_big = regrid_walk(2000)
        @test 0 < v_small < 500 * 500 ÷ 10 && 0 < v_big < 2000 * 2000 ÷ 10
        # Four times the cells: four times the bytes when linear, sixteen when
        # each first binding lists the whole second range (8 n² bytes).
        @test big < 8 * small
        @test big < 2 * 2000^2
    end
end

end # module
