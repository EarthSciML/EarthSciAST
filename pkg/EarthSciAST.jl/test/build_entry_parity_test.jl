# `Internal.build` builds what `esm_problem` builds.
#
# The internal build entry exists so tests and adapters read the build a
# Problem runs (its compiler report, its right-hand side). For every
# tests/valid document (and three conformance documents with parameter-only
# array observeds) `esm_problem` builds, `Internal.build` must build it
# too, with the same tier for every rule, the same starting state and the same
# derivative bit for bit at that state and at a second one. A document
# `esm_problem` refuses, `Internal.build` refuses with the same error type and
# code.

using Test
using EarthSciAST

include("testutils.jl")

const _BEP = EarthSciAST

_bep_bits(v) = reinterpret(UInt64, collect(Float64, v))
_bep_rules(rep) = [(r.kind, r.rule, r.tier) for r in rep.rules]
_bep_code(err) = (typeof(err), hasproperty(err, :code) ? err.code : nothing)
_bep_unwrap(err) = err isa CompositeException ? err.exceptions[1] : err

function _bep_du(f!, u, p)
    du = fill(NaN, length(u))
    f!(du, u, p, 0.25)
    return du
end

@testset "Internal.build builds what esm_problem builds" begin
    paths = String[]
    for (dir, _, files) in walkdir(joinpath(TESTUTILS_REPO_ROOT, "tests", "valid"))
        for f in files
            endswith(f, ".esm") && push!(paths, joinpath(dir, f))
        end
    end
    sort!(paths)
    @test length(paths) >= 100
    # Conformance documents whose parameter-only array observeds a Problem
    # fills once at setup: the discrete-cadence materializer both entries pass.
    for rel in (
            ("template_array_args", "fixtures", "bilin_x_array.esm"),
            ("native_model_shapes", "fixtures", "const_subscript_maps_static.esm"),
            ("native_model_shapes", "fixtures", "const_subscript_maps_dynamic.esm"),
        )
        push!(paths, joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", rel...))
    end
    built = Ref(0)
    for path in paths
        rel = relpath(path, TESTUTILS_REPO_ROOT)
        prob = try
            esm_problem(path, (0.0, 1.0))
        catch err
            err isa InterruptException && rethrow()
            _bep_unwrap(err)
        end
        b = try
            _BEP.Internal.build(path)
        catch err
            err isa InterruptException && rethrow()
            _bep_unwrap(err)
        end
        @testset "$rel" begin
            if prob isa Exception
                # Both entries refuse it, for the same reason.
                @test b isa Exception && _bep_code(b) == _bep_code(prob)
            elseif b isa Exception
                @test b === nothing   # esm_problem built it; Internal.build threw
            else
                built[] += 1
                @test _bep_rules(compiler_report(prob)) == _bep_rules(b.report.compiler_report)
                @test Dict(prob.var_map) == Dict(b.var_map)
                @test _bep_bits(prob.u0) == _bep_bits(b.u0)
                u1 = [x + 0.125 * sin(1.3 * i) for (i, x) in enumerate(prob.u0)]
                for u in (prob.u0, u1)
                    @test _bep_bits(_bep_du(prob.f!, u, prob.p)) ==
                        _bep_bits(_bep_du(b.f!, u, b.p))
                end
            end
        end
    end
    # The comparison is real: most of the corpus builds.
    @test built[] >= 40
end
