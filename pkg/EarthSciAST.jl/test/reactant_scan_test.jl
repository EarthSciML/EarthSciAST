# The traced prefix (cumulative) scan (ext/EarthSciASTReactantExt.jl,
# `_scan_lanes_oop`).
#
# THE DEFECT THIS PINS. `_scan_lanes_oop` (src/tree_walk/scan.jl) walks
# lane × level and touches ONE element per step — a scalar read of `du`, a ⊕, a
# scalar write back. On host that is the right program. Under a trace each
# element costs a `dynamic_slice` + a `dynamic_update_slice` (each rewriting the
# WHOLE state tensor) + 4 index constants + 2 reshapes, so the emitted module
# grew by `2·len` slice ops and `~4·len` constants PER LANE. Once the per-cell
# scalar surface was lane-batched (ess-oop-batch) this was the ONLY thing left
# in the `:oop` emitter that scaled with the grid: on ReSEACT at NLEV=16 (one
# exclusive scan of 17 half levels, one lane per column, two traced RHS sites
# per SSPRK43 step) it was 34 `dynamic_slice` and 140 `constant` per GRID
# COLUMN — 100% of the measured residual.
#
# WHAT IS ASSERTED, in two layers:
#   1. VALUES. The traced fold is bitwise the host scalar fold, over all four ⊕,
#      both window kinds, and the degenerate shapes (one lane, unit length).
#      Inputs are catastrophic-cancellation magnitudes with sign flips, so a
#      re-association shows as a mismatch rather than a last-ulp difference.
#   2. SHAPE. The claim is not "smaller" but GRID-INDEPENDENT: the emitted op
#      census must be IDENTICAL at two lane multiplicities. That is the layer
#      that would have caught the original defect.
using Test
using EarthSciAST
using Reactant

const ESM = EarthSciAST
const RXs = Reactant

# `nlanes × len` slots in the LANE-MAJOR order `_ScanFold` documents.
_sf(nlanes, len; inclusive = true, oplus = :+, zerobar = 0.0) =
    ESM._ScanFold(Int[(l - 1) * len + k for l in 1:nlanes for k in 1:len],
                  len, oplus, zerobar, inclusive)

_sf_bits(v::AbstractVector{Float64}) = reinterpret(UInt64, v)
_sf_val(k) = (1.0 - 2.0 * (k % 2)) * 10.0^(((k * 7) % 17) - 8)
_sf_zero(op) = op === :+ ? 0.0 : op === :* ? 1.0 : op === :max ? -Inf : Inf

function _sf_census(mod)
    s = string(mod)
    Dict(op => length(findall(op, s)) for op in
         ("stablehlo.constant", "stablehlo.dynamic_slice",
          "stablehlo.dynamic_update_slice", "stablehlo.slice", "stablehlo.gather",
          "stablehlo.scatter", "stablehlo.reshape", "stablehlo.add",
          "stablehlo.broadcast_in_dim", "func.func"))
end

@testset "traced prefix scan ≡ host fold, and ≢ grid size" begin
    @testset "bitwise host ≡ traced" begin
        for inclusive in (true, false), op in (:+, :*, :max, :min),
            (nlanes, len) in ((5, 17), (1, 17), (7, 1), (1, 1), (3, 4))

            S = _sf(nlanes, len; inclusive = inclusive, oplus = op,
                    zerobar = _sf_zero(op))
            u = Float64[_sf_val(k) for k in 1:(nlanes * len)]
            host = ESM._apply_scan_folds_oop(copy(u), [S])
            g = du -> ESM._apply_scan_folds_oop(du, [S])
            traced = Array(RXs.@jit g(RXs.ConcreteRArray(copy(u))))
            @test _sf_bits(host) == _sf_bits(traced)
        end
    end

    # The property the fix exists for. `len` is held fixed and only the LANE
    # count moves, which is exactly what adding grid columns does.
    @testset "op census ≢ lane count" begin
        for inclusive in (true, false)
            cen = map((4, 91)) do nlanes
                S = _sf(nlanes, 17; inclusive = inclusive)
                g = du -> ESM._apply_scan_folds_oop(du, [S])
                _sf_census(RXs.@code_hlo optimize = false g(
                    RXs.ConcreteRArray(zeros(nlanes * 17))))
            end
            @test cen[1] == cen[2]
            # and the scalar-spine ops the old form emitted per element are gone
            @test cen[2]["stablehlo.dynamic_slice"] == 0
            @test cen[2]["stablehlo.dynamic_update_slice"] == 0
        end
    end
end
