# Template references with ARRAY parameters compiled as calls (call.jl): the
# array a reference binds is passed at run time (a state array, a const
# array, an inline const table), and a reduction bound bound to a literal is
# fixed per instance. Under both compilers the right-hand side must be bit for
# bit the build of the expanded document's, and the number of call targets
# must not grow with the number of tracers.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: load_path, flatten, expand_flattened_refs

const _TA_N = 9

_ta_ref(name, bindings) = Dict(
    "op" => "apply_expression_template", "args" => Any[], "name" => name,
    "bindings" => bindings
)
_ta_op(op, args...) = Dict("op" => op, "args" => Any[args...])

function _ta_templates()
    lib = JSON3.read(
        read(joinpath(pkgdir(EarthSciAST), "data", "lib", "interp.esm"), String), Dict{String, Any}
    )
    t = Dict{String, Any}("linear" => lib["expression_templates"]["linear"])
    # A neighbour average of an array parameter around the caller's `i`, the
    # cells past the ends reading 0 (ghost cells).
    t["smooth"] = Dict(
        "params" => Any["q", "w"],
        "body" => _ta_op(
            "+",
            _ta_op("*", "w", _ta_op("index", "q", _ta_op("-", "i", 1))),
            _ta_op("*", _ta_op("-", 1, _ta_op("*", 2, "w")), _ta_op("index", "q", "i")),
            _ta_op("*", "w", _ta_op("index", "q", _ta_op("+", "i", 1)))
        ),
    )
    return t
end

function _ta_document(tracers)
    axis = Dict("op" => "const", "args" => Any[], "value" => Any[0.0, 1.0, 2.5, 4.0, 7.0])
    vars = Dict{String, Any}(
        "T" => Dict(
            "type" => "parameter", "units" => "1", "shape" => Any["x"],
            "default" => Any[0.2 + 0.1 * k for k in 1:_TA_N]
        ),
        "s" => Dict("type" => "unknown", "units" => "1", "default" => 0.5),
    )
    eqs = Any[]
    for (n, q) in enumerate(tracers)
        vars[q] = Dict("type" => "unknown", "units" => "1", "shape" => Any["x"], "default" => 1.0 + 0.1 * n)
        rate = _ta_ref(
            "linear", Dict(
                "table" => Dict("op" => "const", "args" => Any[], "value" => Any[1.0, 0.5, 0.25, 0.1, 0.05 * n]),
                "axis" => axis, "x" => _ta_op("*", "s", 3.0), "n" => 5
            )
        )
        push!(
            eqs, Dict(
                "lhs" => Dict(
                    "op" => "faq", "output_idx" => Any["i"], "args" => Any[],
                    "ranges" => Dict("i" => Any[1, _TA_N]),
                    "expr" => Dict("op" => "D", "args" => Any[_ta_op("index", q, "i")], "wrt" => "t"),
                ),
                "rhs" => Dict(
                    "op" => "faq", "output_idx" => Any["i"], "args" => Any[],
                    "ranges" => Dict("i" => Any[1, _TA_N]),
                    "expr" => _ta_op(
                        "-",
                        _ta_ref("smooth", Dict("q" => q, "w" => 0.25)),
                        _ta_op("*", rate, _ta_op("index", q, "i"))
                    ),
                ),
            )
        )
    end
    # A scalar equation reading a parameter table through the template.
    push!(
        eqs, Dict(
            "lhs" => Dict("op" => "D", "args" => Any["s"], "wrt" => "t"),
            "rhs" => _ta_op(
                "-", _ta_ref(
                    "linear", Dict(
                        "table" => "T",
                        "axis" => Dict("op" => "const", "args" => Any[], "value" => Any[Float64(k) for k in 1:_TA_N]),
                        "x" => _ta_op("+", 1.5, _ta_op("*", 4.0, "s")), "n" => _TA_N
                    )
                ), "s"
            ),
        )
    )
    return Dict(
        "esm" => "2.0.0",
        "metadata" => Dict("name" => "template_array_calls_1d"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => _TA_N)),
        "models" => Dict(
            "M" => Dict(
                "expression_templates" => _ta_templates(),
                "variables" => vars,
                "equations" => eqs,
            )
        ),
    )
end

function _ta_build_and_probe(fix; atload = false, compiler = :native)
    flat = flatten(load_path(fix))
    atload && (flat = expand_flattened_refs(flat))
    (f, u0, p, _, _, rep), counts = EarthSciAST._with_counts(
        () -> EarthSciAST.Internal.build(flat; compiler = compiler)
    )
    dus = Vector{Float64}[]
    for (k, ti) in enumerate((0.0, 0.7, 3.25))
        u = Float64[0.3 + 0.4 * sin(0.37 * i * k) for i in eachindex(u0)]
        du = similar(u0)
        f(du, u, p, ti)
        push!(dus, copy(du))
    end
    du = similar(u0)
    f(du, u0, p, 0.1)
    alloc = @allocated f(du, u0, p, 0.2)
    return dus, counts, alloc
end

@testset "template references with array arguments compiled as calls" begin
    ntargets = Dict{Int, Int}()
    mktempdir() do dir
        for tracers in (["a"], ["a", "b", "c"])
            fix = joinpath(dir, "arrcalls_$(length(tracers)).esm")
            open(io -> JSON3.write(io, _ta_document(tracers)), fix, "w")
            fast, counts, alloc = _ta_build_and_probe(fix)
            atload, _, _ = _ta_build_and_probe(fix; atload = true)
            interp, icounts, _ = _ta_build_and_probe(fix; compiler = :interpreter)
            @test alloc == 0
            for k in 1:3
                @test fast[k] == atload[k]
                @test interp[k] == atload[k]
                @test sum(abs, fast[k]) > 0
            end
            # `smooth` (one state array kind) and `linear` (two instances:
            # n = 5 and n = 9, const tables) are calls, whatever the tracers.
            @test get(counts, :call_targets, 0) == 3
            @test get(icounts, :call_targets, 0) == 3
            ntargets[length(tracers)] = get(counts, :call_targets, 0)
        end
    end
    @test ntargets[3] == ntargets[1]
end
