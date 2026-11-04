# `forcing_from_sample` (API_SPEC §5.8, "Forcing sets"): a slot's buffer built from
# a provider sample is, bit for bit, the buffer `esm_problem` builds from the
# same sample.
#
# Each case builds a Problem with providers, takes its program's default
# forcing set (the Problem's forcing when the program was built) and, for a
# discrete provider, the Problem's own live buffer, and compares them with
# `forcing_from_sample` of a second sample on the f64 bits: a gridded parameter, a
# scalar one, a parameter whose first dimension is a two-record axis, and
# parameters whose source declares a `unit_conversion`.

using Test
using EarthSciAST
using EarthSciIO
using DiffEqCallbacks            # the refresh callback of a discrete provider
using SciMLBase
import JSON

const FB = EarthSciAST

_fb_bits(v) = UInt64[reinterpret(UInt64, Float64(x)) for x in v]

# A provider delivering one fixed field per variable: const with no refresh
# times, discrete with some (sampled at the build's start time either way).
struct _FBProvider
    times::Vector{Float64}
    sample::Dict{String, Any}
end
FB.provider_refresh_times(p::_FBProvider) = p.times
FB.provider_sample(p::_FBProvider, ::Real; selection = nothing) = p.sample

_fb_idx(v, ix...) = Dict("op" => "index", "args" => Any[v, ix...])
_fb_op(op, args...) = Dict("op" => op, "args" => Any[args...])

# `u[x]` forced by a gridded `E[x, y]`, a scalar `s` and `R[rec, x]`, whose
# first dimension holds two records, all fed by one data source.
function _fb_doc(nx::Int, ny::Int)
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict("i" => Dict("from" => "x")), "expr" => e
    )
    fed(fv) = Dict("kind" => "data", "source" => "met", "from" => Dict("file_variable" => fv))
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "forcing_from_sample"),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => nx),
            "y" => Dict("kind" => "interval", "size" => ny),
            "rec" => Dict("kind" => "interval", "size" => 2)
        ),
        "data_sources" => Dict(
            "met" => Dict(
                "kind" => "grid", "source" => Dict("url_template" => "file:///met.nc")
            )
        ),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x"], "default" => 1.0),
                    "E" => Dict(
                        "type" => "parameter", "shape" => ["x", "y"], "default" => 0.5,
                        "update" => fed("E")
                    ),
                    "s" => Dict(
                        "type" => "parameter", "shape" => Any[], "default" => 2.0,
                        "update" => fed("s")
                    ),
                    "R" => Dict(
                        "type" => "parameter", "shape" => ["rec", "x"], "default" => 0.0,
                        "update" => fed("R")
                    ),
                    "k" => Dict("type" => "parameter", "default" => 0.25)
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => faq(
                            Dict(
                                "op" => "D", "args" => Any[_fb_idx("u", "i")],
                                "wrt" => "t"
                            )
                        ),
                        "rhs" => faq(
                            _fb_op(
                                "+", _fb_op("*", "s", _fb_idx("E", "i", 2)),
                                _fb_idx("R", 1, "i"), _fb_idx("R", 2, "i"),
                                _fb_op("*", -1, "k", _fb_idx("u", "i"))
                            )
                        )
                    ),
                ]
            )
        )
    )
end

# Fields whose every element differs, so a transposed or reordered buffer
# cannot pass.
_fb_field(dims, base) = reshape([base + k / 7 for k in 0:(prod(dims; init = 1) - 1)], dims...)

_fb_samples(nx, ny) = Dict(
    "M.E" => Dict{String, Any}("M.E" => _fb_field((nx, ny), 0.1)),
    "M.s" => Dict{String, Any}("M.s" => [3.0]),
    "M.R" => Dict{String, Any}("M.R" => _fb_field((2, nx), -1.3)),
)

# Every slot of `prog`, from the matching sample, equals its default buffer.
function _fb_check_default(prog, samples)
    D = default_forcing_set(prog)
    for (k, slot) in enumerate(forcing_slots(prog))
        got = forcing_from_sample(samples[slot.name], slot)
        @test got isa Vector{Float64}
        @test _fb_bits(got) == _fb_bits(D.bufs[k])
    end
    return nothing
end

@testset "forcing_from_sample (API_SPEC §5.8)" begin
    nx, ny = 3, 4

    @testset "const providers: the program's default forcing" begin
        samples = _fb_samples(nx, ny)
        provs = Dict{String, Any}(k => _FBProvider(Float64[], s) for (k, s) in samples)
        prog = rhs_program(esm_problem(_fb_doc(nx, ny), (0.0, 1.0); providers = provs))
        @test forcing_slots(prog) == [
            ForcingSlot("M.E", [nx, ny], :forcing),
            ForcingSlot("M.R", [2, nx], :forcing),
            ForcingSlot("M.s", Int[], :forcing),
        ]
        _fb_check_default(prog, _fb_samples(nx, ny))
        # Column-major over the declared shape: E[i, j] is element i + nx(j - 1).
        e = forcing_from_sample(samples["M.E"], forcing_slots(prog)[1])
        @test _fb_bits(e) == _fb_bits(vec(samples["M.E"]["M.E"]))
    end

    @testset "discrete providers: the Problem's live buffers" begin
        samples = _fb_samples(nx, ny)
        provs = Dict{String, Any}(k => _FBProvider([0.5], s) for (k, s) in samples)
        prob = esm_problem(_fb_doc(nx, ny), (0.0, 1.0); providers = provs)
        prog = rhs_program(prob)
        _fb_check_default(prog, _fb_samples(nx, ny))
        bufs = forcing_buffers(prob)
        idx = forcing_buffer_index(prob)
        for slot in forcing_slots(prog)
            haskey(idx, slot.name) || continue
            @test _fb_bits(forcing_from_sample(samples[slot.name], slot)) ==
                _fb_bits(vec(bufs[idx[slot.name]]))
        end
        @test haskey(idx, "M.E")
        # The name method is the array `esm_problem` binds: the delivered
        # dimensions, a fresh copy.
        a = forcing_from_sample(samples["M.R"], "M.R")
        @test size(a) == (2, nx)
        @test a !== samples["M.R"]["M.R"]
        @test _fb_bits(a) == _fb_bits(samples["M.R"]["M.R"])
    end

    @testset "a sample that does not fit the slot is refused" begin
        slot = ForcingSlot("M.E", [3, 4], :forcing)
        @test_throws DimensionMismatch forcing_from_sample(Dict("M.E" => zeros(4, 3)), slot)
        @test_throws DimensionMismatch forcing_from_sample(Dict("M.E" => zeros(12)), slot)
        @test_throws RefreshError forcing_from_sample(Dict("M.F" => zeros(3, 4)), slot)
        scalar = ForcingSlot("M.s", Int[], :forcing)
        @test forcing_from_sample(Dict("M.s" => [4.0]), scalar) == [4.0]
        @test_throws DimensionMismatch forcing_from_sample(Dict("M.s" => [4.0, 5.0]), scalar)
        # A bare array is a single-variable sample: the field itself, and a
        # bare number is a 0-d one.
        @test forcing_from_sample(zeros(3, 4), slot) == zeros(12)
        @test forcing_from_sample(Dict("M.s" => 3.0), scalar) == [3.0]
        @test forcing_from_sample(3.0, "M.s"; shape = Int[]) == fill(3.0)
        # `shape` takes any collection of integers.
        @test size(forcing_from_sample(zeros(3, 4), "M.E"; shape = (3, 4))) == (3, 4)
        @test forcing_from_sample([4.0], "M.s"; shape = []) == [4.0]
        @test_throws DimensionMismatch forcing_from_sample(zeros(4, 3), "M.E"; shape = (3, 4))
    end

    @testset "esm_problem refuses what forcing_from_sample refuses" begin
        doc = _fb_doc(nx, ny)
        fed(e) = merge(
            Dict{String, Any}(k => _FBProvider(Float64[], s) for (k, s) in _fb_samples(nx, ny)),
            Dict{String, Any}("M.E" => _FBProvider(Float64[], Dict{String, Any}("M.E" => e)))
        )
        for wrong in (zeros(ny, nx), zeros(nx * ny), zeros(nx, ny, 1))
            @test_throws DimensionMismatch esm_problem(doc, (0.0, 1.0); providers = fed(wrong))
        end
        # A discrete provider is checked at its first sample too.
        discrete = Dict{String, Any}(
            "M.E" => _FBProvider([0.5], Dict{String, Any}("M.E" => zeros(ny, nx))),
            "M.s" => _FBProvider(Float64[], _fb_samples(nx, ny)["M.s"]),
            "M.R" => _FBProvider(Float64[], _fb_samples(nx, ny)["M.R"]),
        )
        @test_throws DimensionMismatch esm_problem(doc, (0.0, 1.0); providers = discrete)
        # And at each refresh, against the buffer it bound.
        buf = zeros(nx, ny)
        @test_throws RefreshError FB._write_forcing!(buf, "M.E", Dict("M.E" => zeros(ny, nx)))
        @test_throws RefreshError FB._write_forcing!(buf, "M.E", Dict("M.E" => zeros(nx * ny)))
        FB._write_forcing!(buf, "M.E", Dict("M.E" => _fb_field((nx, ny), 0.1)))
        @test _fb_bits(buf) == _fb_bits(_fb_field((nx, ny), 0.1))
        one = zeros(1)
        FB._write_forcing!(one, "M.s", Dict("M.s" => 5.0))
        @test one == [5.0]
    end

    @testset "a source declaring unit_conversion" begin
        tests = normpath(joinpath(@__DIR__, "..", "..", "..", "tests"))
        dir = joinpath(tests, "conformance", "loader_unit_conversion")
        doc = JSON.parsefile(joinpath(dir, "fixtures", "loader_unit_conversion.esm"))
        # The fixture declares no equations; give it one that reads every
        # parameter, so the Problem has a right-hand side.
        doc["esm"] = "1.2.0"           # `faq` needs 1.1.0 or later
        m = doc["models"]["Stacks_Ingest"]
        m["system_kind"] = "ode"
        m["variables"]["h"] = Dict(
            "type" => "unknown", "units" => "1", "shape" => ["stacks"], "default" => 0.0
        )
        sfaq(e) = Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
            "ranges" => Dict("i" => Dict("from" => "stacks")), "expr" => e
        )
        m["equations"] = Any[
            Dict(
                "lhs" => sfaq(
                    Dict("op" => "D", "args" => Any[_fb_idx("h", "i")], "wrt" => "t")
                ),
                "rhs" => sfaq(
                    _fb_op(
                        "+", _fb_idx("annual", "i"), _fb_idx("stkhgt", "i"),
                        _fb_idx("stkdiam", "i"), _fb_idx("stktemp", "i")
                    )
                )
            ),
        ]
        csv = joinpath(dir, "fixtures", "stacks_ff10_point.csv")
        golden = JSON.parsefile(joinpath(dir, "golden", "ff10_stacks.json"))
        mktempdir() do tmp
            build() = FB.providers_from_document(
                doc; cache_root = joinpath(tmp, "cache"), loaders = ["Stacks"],
                url_overrides = Dict("Stacks" => "file://" * abspath(csv))
            )
            prob = esm_problem(doc, (0.0, 1.0); providers = build())
            prog = rhs_program(prob)
            @test length(forcing_slots(prog)) == 4
            again = build()
            samples = Dict(k => FB.provider_sample(p, 0.0) for (k, p) in again)
            _fb_check_default(prog, samples)
            # The conversion is in the buffer: feet to metres on `stkhgt`.
            k = findfirst(s -> s.name == "Stacks_Ingest.stkhgt", forcing_slots(prog))
            @test _fb_bits(default_forcing_set(prog).bufs[k]) ==
                _fb_bits(golden["delivered"]["Stacks_Ingest.stkhgt"])
        end
    end
end
