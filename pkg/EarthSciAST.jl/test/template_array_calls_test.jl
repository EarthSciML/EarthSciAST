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

# Array-valued templates (a `faq` body over output indices) read per cell
# (`index`) and whole (a `makearray` region value): element calls, the reads
# made by the caller (lanes), bodies shared between instances that differ only
# in which cells they read, an array passed on to a nested call, and a
# compound binding read on one arm only, compiled into its instance.
function _ta_elem_document(tracers)
    N = _TA_N
    ix(a, s...) = _ta_op("index", a, s...)
    tpl = Dict{String, Any}(
        # Interior flux and the two boundary rows: the same arithmetic over
        # different cells (one compiled body for all three).
        "flux" => Dict("params" => Any["q", "U"], "body" => Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any["i"], "ranges" => Dict("i" => Any[2, N - 1]),
            "expr" => _ta_op("*", ix("U", "i"), _ta_op("-", ix("q", _ta_op("+", "i", 1)), ix("q", _ta_op("-", "i", 1)))),
        )),
        "flux_w" => Dict("params" => Any["q", "U", "qbc"], "body" => Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any["i"], "ranges" => Dict("i" => Any[1, 1]),
            "expr" => _ta_op("*", ix("U", "i"), _ta_op("-", ix("q", 2), ix("qbc", 1))),
        )),
        "flux_e" => Dict("params" => Any["q", "U", "qbc"], "body" => Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any["i"], "ranges" => Dict("i" => Any[N, N]),
            "expr" => _ta_op("*", ix("U", "i"), _ta_op("-", ix("qbc", 1), ix("q", N - 1))),
        )),
        # A whole-array observed of an array-valued template.
        "ramp" => Dict("params" => Any[], "body" => Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any["g"], "ranges" => Dict("g" => Any[1, N]),
            "expr" => _ta_op("*", 0.01, "g"),
        )),
        # A reduction over its array argument, called by `outer`, which
        # passes its own array argument on and reads it on one arm only.
        "colsum" => Dict("params" => Any["a", "w"], "body" => Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any[], "ranges" => Dict("m" => Any[1, N]),
            "expr" => _ta_op("*", ix("w", "m"), ix("a", "m")),
        )),
        "outer" => Dict("params" => Any["q", "w", "c"], "body" => _ta_op(
            "+", _ta_ref("colsum", Dict("a" => "q", "w" => "w")),
            _ta_op("ifelse", _ta_op(">", "c", 0.5), ix("q", 2), _ta_op("*", 2.0, ix("q", 3)))
        )),
        # Reads `x` on one arm only: a compound binding is part of the instance.
        "pick" => Dict("params" => Any["c", "x"], "body" => _ta_op("ifelse", _ta_op(">", "c", 0.5), _ta_op("^", "x", 2), 0.0)),
    )
    vars = Dict{String, Any}(
        "U" => Dict("type" => "parameter", "units" => "1", "shape" => Any["x"], "default" => Any[0.1 * sin(k) for k in 1:N]),
        "w" => Dict("type" => "parameter", "units" => "1", "shape" => Any["x"], "default" => Any[0.1 * k for k in 1:N]),
        "kc" => Dict("type" => "parameter", "units" => "1", "default" => 0.7),
        "r" => Dict("type" => "unknown", "units" => "1", "shape" => Any["x"]),
    )
    eqs = Any[Dict("lhs" => "r", "rhs" => _ta_ref("ramp", Dict()))]
    for (n, q) in enumerate(tracers)
        vars[q] = Dict("type" => "unknown", "units" => "1", "shape" => Any["x"], "default" => 1.0 + 0.1 * n)
        vars[q * "_bc"] = Dict("type" => "parameter", "units" => "1", "shape" => Any["bc"], "default" => Any[0.3 * n])
        bc = q * "_bc"
        ma = Dict(
            "op" => "makearray", "args" => Any[], "regions" => Any[Any[Any[1, 1]], Any[Any[2, N - 1]], Any[Any[N, N]]],
            "values" => Any[
                _ta_ref("flux_w", Dict("q" => q, "U" => "U", "qbc" => bc)),
                _ta_ref("flux", Dict("q" => q, "U" => "U")),
                _ta_ref("flux_e", Dict("q" => q, "U" => "U", "qbc" => bc)),
            ]
        )
        rhs = _ta_op(
            "+", _ta_op("-", ix(ma, "i"), _ta_op("*", 0.05, ix(q, "i"))),
            _ta_op("*", 0.01, _ta_ref("outer", Dict("q" => q, "w" => "w", "c" => "kc"))),
            _ta_op("*", 1.0e-3, _ta_ref("pick", Dict("c" => "kc", "x" => _ta_op("+", _ta_op("*", "kc", 2.0), "i")))),
            ix("r", "i")
        )
        push!(eqs, Dict(
            "lhs" => Dict("op" => "faq", "output_idx" => Any["i"], "args" => Any[], "ranges" => Dict("i" => Any[1, N]),
                "expr" => Dict("op" => "D", "args" => Any[ix(q, "i")], "wrt" => "t")),
            "rhs" => Dict("op" => "faq", "output_idx" => Any["i"], "args" => Any[], "ranges" => Dict("i" => Any[1, N]), "expr" => rhs),
        ))
    end
    return Dict(
        "esm" => "2.0.0", "metadata" => Dict("name" => "template_element_calls_1d"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => N), "bc" => Dict("kind" => "interval", "size" => 1)),
        "models" => Dict("M" => Dict("expression_templates" => tpl, "variables" => vars, "equations" => eqs)),
    )
end

@testset "array-valued templates, nested array arguments, inlined bindings" begin
    seen = Dict{Int, Any}()
    mktempdir() do dir
        for tracers in (["a"], ["a", "b", "c"])
            fix = joinpath(dir, "elemcalls_$(length(tracers)).esm")
            open(io -> JSON3.write(io, _ta_elem_document(tracers)), fix, "w")
            fast, counts, alloc = _ta_build_and_probe(fix)
            atload, _, _ = _ta_build_and_probe(fix; atload = true)
            interp, icounts, _ = _ta_build_and_probe(fix; compiler = :interpreter)
            @test alloc == 0
            for k in 1:3
                @test fast[k] == atload[k]
                @test interp[k] == atload[k]
                @test sum(abs, fast[k]) > 0
            end
            # No expansion sub-kernel; the flux family is one body.
            @test get(counts, :body_variants, 0) == 0
            @test get(counts, :call_targets_shared, 0) >= 2
            seen[length(tracers)] = (
                get(counts, :call_targets, 0), get(counts, :cg_call_fn, 0), get(counts, :codegen_kernel, 0),
            )
        end
    end
    # Compiled bodies, emitted functions and kernels do not grow with tracers.
    @test seen[3] == seen[1]
end

# A body that reads an ELEMENT of another template's array (`index(ref, s)`
# inside a body) is a body with an element call in it: the outer template is
# a call, not an expansion, and the bits are the expanded document's.
function _ta_inner_elem_document(tracers)
    N = _TA_N
    ix(a, s...) = _ta_op("index", a, s...)
    tpl = Dict{String, Any}(
        "sm" => Dict("params" => Any["q"], "body" => Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any["i"], "ranges" => Dict("i" => Any[1, N]),
            "expr" => _ta_op("*", 0.5, _ta_op("+", ix("q", _ta_op("-", "i", 1)), ix("q", _ta_op("+", "i", 1)))),
        )),
        "useelem" => Dict("params" => Any["q", "c"], "body" => _ta_op(
            "*", "c", _ta_op("-", ix(_ta_ref("sm", Dict("q" => "q")), "i"), ix("q", "i"))
        )),
    )
    vars = Dict{String, Any}("kc" => Dict("type" => "parameter", "units" => "1", "default" => 0.7))
    eqs = Any[]
    for (n, q) in enumerate(tracers)
        vars[q] = Dict("type" => "unknown", "units" => "1", "shape" => Any["x"], "default" => 1.0 + 0.1 * n)
        push!(eqs, Dict(
            "lhs" => Dict("op" => "faq", "output_idx" => Any["i"], "args" => Any[], "ranges" => Dict("i" => Any[1, N]),
                "expr" => Dict("op" => "D", "args" => Any[ix(q, "i")], "wrt" => "t")),
            "rhs" => Dict("op" => "faq", "output_idx" => Any["i"], "args" => Any[], "ranges" => Dict("i" => Any[1, N]),
                "expr" => _ta_op("-", _ta_ref("useelem", Dict("q" => q, "c" => "kc")), _ta_op("*", 0.05, ix(q, "i")))),
        ))
    end
    return Dict(
        "esm" => "2.0.0", "metadata" => Dict("name" => "template_inner_element_calls_1d"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => N)),
        "models" => Dict("M" => Dict("expression_templates" => tpl, "variables" => vars, "equations" => eqs)),
    )
end

@testset "a body reading an element of an array-valued template" begin
    seen = Dict{Int, Any}()
    mktempdir() do dir
        for tracers in (["a"], ["a", "b", "c"])
            doc = _ta_inner_elem_document(tracers)
            fix = joinpath(dir, "innerelem_$(length(tracers)).esm")
            open(io -> JSON3.write(io, doc), fix, "w")
            # The build calls `useelem`; nothing is expanded.
            flat = flatten(load_path(fix))
            tt = EarthSciAST._TplTable(flat.template_registry)
            name = only(k for k in keys(flat.template_registry) if endswith(k, "useelem"))
            @test EarthSciAST._tpl_call_info(tt, name) !== nothing
            fast, counts, alloc = _ta_build_and_probe(fix)
            atload, _, _ = _ta_build_and_probe(fix; atload = true)
            interp, _, _ = _ta_build_and_probe(fix; compiler = :interpreter)
            @test alloc == 0
            for k in 1:3
                @test fast[k] == atload[k]
                @test interp[k] == atload[k]
                @test sum(abs, fast[k]) > 0
            end
            @test get(counts, :call_targets, 0) == 2
            seen[length(tracers)] = (get(counts, :call_targets, 0), get(counts, :codegen_kernel, 0))
        end
    end
    @test seen[3] == seen[1]
end

# A template with a parameter in a structural position (here an output index
# name) read with a name there is a template of its own: the reference is
# re-pointed at the instance, whose declaration has the value substituted and
# no structural parameter left.
@testset "structural parameters: one template per structural value" begin
    reg = EarthSciAST.OrderedDict{String, Any}(
        "ramp" => Dict{String, Any}("params" => Any["n", "s"], "body" => Dict{String, Any}(
            "op" => "faq", "args" => Any[], "output_idx" => Any["n"], "ranges" => Dict{String, Any}("n" => Any[1, 4]),
            "expr" => _ta_op("*", "s", "n")
        )),
    )
    tt = EarthSciAST._TplTable(reg)
    @test EarthSciAST._tpl_def(tt, "ramp").structural == ["n"]
    ref = EarthSciAST.expression_from_json(_ta_ref("ramp", Dict("n" => "g", "s" => 2.0)))
    inst = EarthSciAST._tpl_structural_refs(tt, ref)
    @test inst.name != "ramp" && startswith(inst.name, "ramp")
    @test sort!(collect(keys(inst.bindings))) == ["s"]
    d = EarthSciAST._tpl_def(tt, inst.name)
    @test isempty(d.structural) && d.params == ["s"]
    @test d.closed.body.output_idx == ["g"]
    # A reference whose structural binding is not a name or a number keeps
    # the template.
    ref2 = EarthSciAST.expression_from_json(_ta_ref("ramp", Dict("n" => _ta_op("+", "g", 1), "s" => 2.0)))
    @test EarthSciAST._tpl_structural_refs(tt, ref2).name == "ramp"
end
