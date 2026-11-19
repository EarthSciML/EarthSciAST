# One compiled function per template instance (esm-spec §9.6.4 rule 2): the
# native emitter writes each template body's sub-kernel once, as a function of
# its run-time inputs, and calls it from every use with the same instance —
# here three tracers transported by one flux template, so three uses share one
# function per region class. The fixtures nest templates, bind compound
# expressions (a compound binding read only under an `ifelse` branch among
# them), and pin the right-hand side bit for bit against the build of the
# expanded document and against the interpreter.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: load_path, flatten, expand_flattened_refs

include("testutils.jl")  # TESTUTILS_REPO_ROOT (also lets this file run standalone)

const _TIF_N = 12

_tif_ref(name, bindings) = Dict(
    "op" => "apply_expression_template", "args" => Any[], "name" => name,
    "bindings" => bindings
)
_tif_at(f, off) = off == 0 ? Dict("op" => "index", "args" => Any[f, "i"]) :
    Dict(
    "op" => "index", "args" => Any[
        f, Dict("op" => (off > 0 ? "+" : "-"), "args" => Any["i", abs(off)]),
    ]
)
_tif_pin(f, at) = Dict("op" => "index", "args" => Any[f, at])

# Templates: `upwind(w, lo, hi, curv)` picks a face value by the sign of `w`,
# and reads `curv` (bound to a compound second difference) ONLY in its `w > 0`
# branch; `face(q, U)` binds it with compound `index` expressions; `flux_int`
# is the interior aggregate and the two pinned boundary faces close the
# `Dx1` makearray that the `D(·, x)` rewrite rule applies per tracer.
function _tif_templates()
    curv(q) = Dict(
        "op" => "+", "args" => Any[
            _tif_at(q, 1),
            Dict("op" => "-", "args" => Any[_tif_at(q, -1), Dict("op" => "*", "args" => Any[2, _tif_at(q, 0)])]),
        ]
    )
    return Dict(
        "upwind" => Dict(
            "params" => Any["w", "lo", "hi", "curv"],
            "body" => Dict(
                "op" => "ifelse", "args" => Any[
                    Dict("op" => ">", "args" => Any["w", 0]),
                    Dict("op" => "*", "args" => Any["w", Dict("op" => "+", "args" => Any["lo", Dict("op" => "*", "args" => Any[0.125, "curv"])])]),
                    Dict("op" => "*", "args" => Any["w", "hi"]),
                ]
            ),
        ),
        "face" => Dict(
            "params" => Any["q", "U"],
            "body" => _tif_ref(
                "upwind", Dict(
                    "w" => _tif_at("U", 0), "lo" => _tif_at("q", -1),
                    "hi" => _tif_at("q", 0), "curv" => curv("q"),
                )
            ),
        ),
        "flux_int" => Dict(
            "params" => Any["q", "U"],
            "body" => Dict(
                "op" => "faq", "output_idx" => Any["i"],
                "args" => Any["q", "U"], "ranges" => Dict("i" => Any[2, _TIF_N - 1]),
                "expr" => Dict(
                    "op" => "-", "args" => Any[
                        _tif_ref(
                            "face", Dict(
                                "q" => "q",
                                "U" => "U"
                            )
                        ),
                        Dict("op" => "*", "args" => Any[0.5, _tif_at("q", 1)]),
                    ]
                ),
            ),
        ),
        "flux_lo" => Dict(
            "params" => Any["q"],
            "body" => Dict(
                "op" => "faq", "output_idx" => Any["i"], "args" => Any["q"],
                "ranges" => Dict("i" => Any[1, 1]),
                "expr" => Dict("op" => "-", "args" => Any[_tif_pin("q", 2), _tif_pin("q", 1)]),
            ),
        ),
        "flux_hi" => Dict(
            "params" => Any["q"],
            "body" => Dict(
                "op" => "faq", "output_idx" => Any["i"], "args" => Any["q"],
                "ranges" => Dict("i" => Any[_TIF_N, _TIF_N]),
                "expr" => Dict("op" => "-", "args" => Any[_tif_pin("q", _TIF_N), _tif_pin("q", _TIF_N - 1)]),
            ),
        ),
        "Dx1" => Dict(
            "params" => Any["f"],
            "match" => Dict("op" => "D", "args" => Any["f"], "wrt" => "x"),
            "body" => Dict(
                "op" => "makearray", "args" => Any[],
                "regions" => Any[Any[Any[2, _TIF_N - 1]], Any[Any[1, 1]], Any[Any[_TIF_N, _TIF_N]]],
                "values" => Any[
                    _tif_ref("flux_int", Dict("q" => "f", "U" => "U")),
                    _tif_ref("flux_lo", Dict("q" => "f")),
                    _tif_ref("flux_hi", Dict("q" => "f")),
                ]
            ),
        ),
    )
end

function _tif_document(tracers)
    vars = Dict{String, Any}(
        "U" => Dict(
            "type" => "parameter", "units" => "1", "shape" => Any["x"],
            "default" => Any[0.3 * sin(0.9 * k) for k in 1:_TIF_N]
        ),
    )
    eqs = Any[]
    for (n, q) in enumerate(tracers)
        vars[q] = Dict("type" => "unknown", "units" => "1", "shape" => Any["x"], "default" => 1.0 + 0.1 * n)
        push!(
            eqs, Dict(
                "lhs" => Dict("op" => "D", "args" => Any[q], "wrt" => "t"),
                "rhs" => Dict("op" => "-", "args" => Any[Dict("op" => "D", "args" => Any[q], "wrt" => "x")]),
            )
        )
    end
    return Dict(
        "esm" => "2.0.0",
        "metadata" => Dict("name" => "template_instances_1d"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => _TIF_N)),
        "models" => Dict(
            "T" => Dict(
                "expression_templates" => _tif_templates(),
                "variables" => vars,
                "equations" => eqs,
            )
        ),
    )
end

_tif_states(n) = (
    Float64[sin(0.37 * i) + 1.5 for i in 1:n],
    Float64[0.5 + 0.01 * i + cos(0.3 * i)^2 for i in 1:n],
    Float64[1.5 - 0.25 * sin(0.7 * i) * cos(0.05 * i) for i in 1:n],
)

function _tif_build_and_probe(fix; atload = false, compiler = :native)
    flat = flatten(load_path(fix))
    atload && (flat = expand_flattened_refs(flat))
    f, u0, p, _, _, rep = EarthSciAST.Internal.build(flat; compiler = compiler)
    dus = Vector{Float64}[]
    for (ti, u) in zip((0.0, 0.7, 3.25), _tif_states(length(u0)))
        du = similar(u0)
        f(du, u, p, ti)
        push!(dus, copy(du))
    end
    return dus, u0, rep.counts
end

@testset "one compiled function per template instance" begin
    nfns = Dict{Int, Int}()
    mktempdir() do dir
        for tracers in (["a"], ["a", "b", "c"], ["a", "b", "c", "d", "e", "f"])
            fix = joinpath(dir, "instances_$(length(tracers)).esm")
            open(io -> JSON3.write(io, _tif_document(tracers)), fix, "w")
            fast, u0, counts = _tif_build_and_probe(fix)
            atload, _, _ = _tif_build_and_probe(fix; atload = true)
            interp, _, _ = _tif_build_and_probe(fix; compiler = :interpreter)
            @test length(u0) == _TIF_N * length(tracers)
            for k in 1:3
                # Bit for bit (Float64 ==, no tolerance) against the expanded
                # document's build and the interpreter.
                @test fast[k] == atload[k]
                @test fast[k] == interp[k]
                @test sum(abs, fast[k]) > 0
            end
            # The references are template calls: one emitted function per
            # compiled body.
            nfns[length(tracers)] = get(counts, :cg_call_fn, 0)
            @test nfns[length(tracers)] >= 1
        end
    end
    # The wind changes sign along `x`, so both `upwind` branches run, the one
    # reading the compound `curv` binding among them.
    w = [0.3 * sin(0.9 * k) for k in 2:(_TIF_N - 1)]
    @test any(<(0), w) && any(>(0), w)
    # The number of emitted instance functions does not grow with the number of
    # tracers that use the instance.
    @test nfns[6] == nfns[3]
end
