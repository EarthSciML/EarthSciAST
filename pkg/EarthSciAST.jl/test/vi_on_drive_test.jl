# The value-invention join driven by a bin-EQUALITY gate's key matches
# (`_vi_equality_candidates` / `_vi_enumerate_driven`, value_invention.jl).
#
# A `join.on [[src_bin, tgt_bin]]` producer — the regridder's candidate set —
# and a bin-pruned nearest-generator `argmin` used to test the gate on every
# tuple of the full product. The driven walk visits the ranges in the product's
# order and restricts the second gated symbol to the first one's partners, so
# the admitted tuples are the same ones in the same order. Every case compares
# against `compiler=:interpreter` (plan field `join_on_gate` off: the full
# product), and the visit counter shows the driven walk actually ran.

module ViOnDriveTests

using Test
using EarthSciAST
import JSON3
const EA = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

function _typed(rel, name; sizes...)
    raw = JSON3.read(read(joinpath(TESTUTILS_REPO_ROOT, rel), String), Dict{String,Any})
    for (k, v) in sizes
        raw["index_sets"][String(k)]["size"] = v
    end
    file = EA.coerce_esm_file(raw)
    return EA._select_model(file, name), file.index_sets
end

_interp(f) = EA._with_compiler_plan(f, EA._compiler_plan(:interpreter))

# Deterministic pseudo-random coordinates (no RNG-version dependence).
_lcg(n, seed, scale) = let s = UInt64(seed)
    [begin
         s = s * 0x5851f42d4c957f2d + 0x14057b7ef767814f
         scale * Float64(s >> 11) / Float64(1 << 53)
     end for _ in 1:n]
end

const REGRID = "tests/valid/geometry/conservative_regrid_overlap_join.esm"
const ARGMIN = "tests/valid/faq/nearest_generator_argmin.esm"

@testset "value-invention bin-equality drive" begin

    @testset "regrid candidate-set producer" begin
        n = 60
        m, isets = _typed(REGRID, "ConservativeRegridOverlapJoin"; src_cells = n, tgt_cells = n)
        # Unit bins over [0, 6): about ten cells of each grid per bin.
        ca = Dict{String,Any}("src_lon" => _lcg(n, 1, 6.0), "src_lat" => zeros(n),
                              "tgt_lon" => _lcg(n, 2, 6.0), "tgt_lat" => zeros(n))
        params = Dict("dx" => 1.0, "dy" => 1.0, "atol" => 1e-12)
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
        ctx = EA._ViCtx(Dict{String,Any}(ca), Dict{String,Float64}(params),
                        Dict{String,EA.IndexSet}(isets), m.variables,
                        Dict{String,Dict{Any,Any}}(), EA._vi_seed_map(m))
        det = EA._vi_detect(m)
        for (v, node) in det.maps
            EA._vi_materialize_map!(ctx, v, node)
        end
        node = only(det.producers)[2]
        ranges = EA._vi_ranges(node)
        function admitted()
            local gs = EA._vi_resolve_join(node.join, ranges, ctx)
            local out = Tuple{Any,Any}[]
            EA._vi_enumerate_join(ranges, gs, ctx,
                b -> EA._vi_join_ok(gs, b) && push!(out, (b["i"], b["j"])))
            return out, gs
        end
        got, gates = admitted()
        want, rgates = _interp(admitted)
        @test got == want
        @test gates[1].candidates !== nothing
        @test rgates[1].candidates === nothing
    end

    @testset "bin-pruned nearest-generator argmin" begin
        np, ng = 300, 40
        # Coordinates on a coarse lattice so equal distances (ties) occur.
        ca = Dict{String,Any}("px" => round.(_lcg(np, 3, 3.9); digits = 1),
                              "py" => round.(_lcg(np, 4, 3.9); digits = 1),
                              "gx" => round.(_lcg(ng, 5, 4.0); digits = 1),
                              "gy" => round.(_lcg(ng, 6, 4.0); digits = 1))
        params = Dict("binw" => 1.0)
        # Every point bin needs a generator (an empty candidate set is an
        # error by spec): add one generator at each bin's corner.
        gx = Float64[]; gy = Float64[]
        for a in 0:3, b in 0:3
            push!(gx, a + 0.5); push!(gy, b + 0.5)
        end
        ca["gx"] = vcat(ca["gx"], gx); ca["gy"] = vcat(ca["gy"], gy)
        m, isets = _typed(ARGMIN, "NearestGeneratorBinned"; points = np, generators = ng + 16)
        vi = EA.materialize_value_invention(m, isets, ca, params)
        ref = _interp(() -> EA.materialize_value_invention(m, isets, ca, params))
        @test vi.assignments["assign_binned"] == ref.assignments["assign_binned"]
        @test length(unique(vi.assignments["assign_binned"])) > 10
    end
end

end # module
