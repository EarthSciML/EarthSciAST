# Template references compiled as CALLS (esm-spec §9.6.4 rule 2; call.jl): a
# scalar function template is compiled once into a call target and every use
# calls it with its arguments, under both compilers. The right-hand side must
# be bit for bit the build of the expanded document's, and the number of
# targets must not grow with the number of uses.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: load_path, flatten, expand_flattened_refs

include("testutils.jl")

const _TC_N = 10

_tc_ref(name, bindings) = Dict(
    "op" => "apply_operator", "args" => Any[], "name" => name,
    "bindings" => bindings
)
_tc_op(op, args...) = Dict("op" => op, "args" => Any[args...])
_tc_at(f, off) = off == 0 ? _tc_op("index", f, "i") :
    _tc_op("index", f, _tc_op(off > 0 ? "+" : "-", "i", abs(off)))

function _tc_templates()
    return Dict(
        # A limiter: plain bindings, read under both branches.
        "upwind" => Dict(
            "params" => Any["w", "lo", "hi"],
            "body" => _tc_op(
                "ifelse", _tc_op(">", "w", 0),
                _tc_op("*", "w", "lo"), _tc_op("*", "w", "hi")
            ),
        ),
        # Calls another template, and reads `s` (bound to a compound
        # expression at the use) unconditionally.
        "face" => Dict(
            "params" => Any["w", "lo", "hi", "s"],
            "body" => _tc_op(
                "+", _tc_ref("upwind", Dict("w" => "w", "lo" => "lo", "hi" => "hi")),
                _tc_op("*", 0.25, "s", "s")
            ),
        ),
        # Reads `t` and a parameter from its caller (implicit parameters).
        "season" => Dict(
            "params" => Any["a"],
            "body" => _tc_op("*", "a", _tc_op("+", 1.0, _tc_op("sin", _tc_op("*", "k", "t")))),
        ),
        # A chain of calls, each calling the next with a different arity.
        "c1" => Dict("params" => Any["x"], "body" => _tc_op("*", "x", 2)),
        "c2" => Dict("params" => Any["x", "y"], "body" => _tc_op("+", _tc_ref("c1", Dict("x" => "x")), "y")),
        "c3" => Dict(
            "params" => Any["x", "y", "z"],
            "body" => _tc_op("*", _tc_ref("c2", Dict("x" => "x", "y" => "y")), "z"),
        ),
        "c4" => Dict(
            "params" => Any["a", "b", "c", "d"],
            "body" => _tc_op("-", _tc_ref("c3", Dict("x" => "a", "y" => "b", "z" => "c")), "d"),
        ),
        # An integer subscript computed from time.
        "slot" => Dict(
            "params" => Any["x"],
            "body" => _tc_op("floor", _tc_op("+", 1, "x")),
        ),
        # A literal exponent bound at the use: it must stay a Float64 under AD.
        "power" => Dict(
            "params" => Any["x", "e"],
            "body" => _tc_op("^", "x", "e"),
        ),
    )
end

function _tc_document(tracers)
    vars = Dict{String, Any}(
        "U" => Dict(
            "type" => "parameter", "units" => "1", "shape" => Any["x"],
            "default" => Any[0.3 * sin(0.9 * k) for k in 1:_TC_N]
        ),
        "k" => Dict("type" => "parameter", "units" => "1", "default" => 0.7),
        "m" => Dict("type" => "unknown", "units" => "1", "default" => 2.0),
        "n" => Dict("type" => "unknown", "units" => "1", "default" => 3.0),
    )
    eqs = Any[]
    for (n, q) in enumerate(tracers)
        vars[q] = Dict("type" => "unknown", "units" => "1", "shape" => Any["x"], "default" => 1.0 + 0.1 * n)
        flux = _tc_ref(
            "face", Dict(
                "w" => _tc_at("U", 0), "lo" => _tc_at(q, -1), "hi" => _tc_at(q, 0),
                "s" => _tc_op("-", _tc_at(q, 1), _tc_at(q, -1)),
            )
        )
        push!(
            eqs, Dict(
                "lhs" => Dict(
                    "op" => "faq", "output_idx" => Any["i"], "args" => Any[],
                    "ranges" => Dict("i" => Any[1, _TC_N]),
                    "expr" => Dict("op" => "D", "args" => Any[_tc_op("index", q, "i")], "wrt" => "t"),
                ),
                "rhs" => Dict(
                    "op" => "faq", "output_idx" => Any["i"], "args" => Any[],
                    "ranges" => Dict("i" => Any[1, _TC_N]),
                    "expr" => _tc_op(
                        "-",
                        _tc_op(
                            "+", flux,
                            _tc_op(
                                "*", 1.0e-3, _tc_ref(
                                    "c4", Dict(
                                        "a" => _tc_at(q, 0), "b" => _tc_at(q, 1),
                                        "c" => _tc_at("U", 0), "d" => 0.5
                                    )
                                )
                            )
                        ),
                        _tc_op("*", _tc_ref("season", Dict("a" => 0.01)), _tc_at(q, 0))
                    ),
                ),
            )
        )
    end
    # Two right-hand sides that differ only in a call's binding: the scalar
    # common-subexpression keys must tell them apart.
    for v in ("m", "n")
        push!(
            eqs, Dict(
                "lhs" => Dict("op" => "D", "args" => Any[v], "wrt" => "t"),
                "rhs" => _tc_op(
                    "+",
                    _tc_op(
                        "-", _tc_ref("season", Dict("a" => v)),
                        _tc_ref("power", Dict("x" => "m", "e" => 2))
                    ),
                    # A table read at a subscript that moves with time: never
                    # taken for a build-time constant.
                    _tc_op(
                        "index", "U",
                        _tc_op("max", 1, _tc_op("min", _TC_N, _tc_ref("slot", Dict("x" => _tc_op("*", 2, "t")))))
                    ),
                ),
            )
        )
    end
    return Dict(
        "esm" => "2.0.0",
        "metadata" => Dict("name" => "template_calls_1d"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => _TC_N)),
        "models" => Dict(
            "T" => Dict(
                "operators" => _tc_templates(),
                "variables" => vars,
                "equations" => eqs,
            )
        ),
    )
end

function _tc_build_and_probe(fix; atload = false, compiler = :native)
    flat = flatten(load_path(fix))
    atload && (flat = expand_flattened_refs(flat))
    (f, u0, p, _, _, rep), counts = EarthSciAST._with_counts(
        () -> EarthSciAST.Internal.build(flat; compiler = compiler)
    )
    dus = Vector{Float64}[]
    for (k, ti) in enumerate((0.0, 0.7, 3.25))
        u = Float64[1.5 + 0.4 * sin(0.37 * i * k) for i in eachindex(u0)]
        du = similar(u0)
        f(du, u, p, ti)
        push!(dus, copy(du))
    end
    du = similar(u0)
    f(du, u0, p, 0.1)
    alloc = @allocated f(du, u0, p, 0.2)
    return dus, u0, counts, alloc
end

@testset "template references compiled as calls" begin
    ntargets = Dict{Int, Int}()
    mktempdir() do dir
        for tracers in (["a"], ["a", "b", "c"])
            fix = joinpath(dir, "calls_$(length(tracers)).esm")
            open(io -> JSON3.write(io, _tc_document(tracers)), fix, "w")
            fast, u0, counts, alloc = _tc_build_and_probe(fix)
            atload, _, _, _ = _tc_build_and_probe(fix; atload = true)
            interp, _, icounts, _ = _tc_build_and_probe(fix; compiler = :interpreter)
            # Calls between emitted call functions are static: nothing is
            # boxed on a right-hand-side call.
            @test alloc == 0
            for k in 1:3
                @test fast[k] == atload[k]
                @test interp[k] == atload[k]
                @test sum(abs, fast[k]) > 0
            end
            # Every reference here is a call: no target per use.
            @test get(counts, :call_targets, 0) >= 3
            @test get(icounts, :call_targets, 0) >= 3
            ntargets[length(tracers)] = get(counts, :call_targets, 0)
        end
    end
    @test ntargets[3] == ntargets[1]
end
