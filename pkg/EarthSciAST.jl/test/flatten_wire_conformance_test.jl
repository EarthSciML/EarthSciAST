# Cross-language conformance: the flattened system as this binding writes it out,
# byte for byte against the shared golden every binding writes
# (tests/conformance/flatten_wire/README.md; esm-spec §9.6.11, "A flattened
# system keeps its applications' meaning on the wire"; esm-libraries-spec §4.7.5,
# "Pointwise lift: operands read per cell"). This binding keeps template
# references through flatten, so the surviving ones are expanded first, as a
# consumer that writes the flattened system out does. Each written-out system is
# also read back and built under both compilers, and gives the initial state and
# right-hand side the original gives, bit for bit, or is refused where the
# original is: the bare expansion it held before was refused there
# with `faq_bare_array_operand`.

using Test
using EarthSciAST
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _FW_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "flatten_wire")

# `v` as canonical JSON: keys sorted by code point, no whitespace, integers as
# written, floats through `format_canonical_float`.
function _fw_canonical(io::IO, v)
    return if v === nothing
        print(io, "null")
    elseif v isa Bool
        print(io, v ? "true" : "false")
    elseif v isa Integer
        print(io, v)
    elseif v isa AbstractFloat
        print(io, EarthSciAST.format_canonical_float(Float64(v)))
    elseif v isa AbstractString
        JSON3.write(io, String(v))
    elseif v isa AbstractVector
        print(io, '[')
        for (i, x) in enumerate(v)
            i > 1 && print(io, ',')
            _fw_canonical(io, x)
        end
        print(io, ']')
    elseif v isa AbstractDict
        ks = sort!([String(k) for k in keys(v)])
        print(io, '{')
        for (i, k) in enumerate(ks)
            i > 1 && print(io, ',')
            JSON3.write(io, k)
            print(io, ':')
            _fw_canonical(io, haskey(v, k) ? v[k] : v[Symbol(k)])
        end
        print(io, '}')
    else
        error("no canonical JSON for $(typeof(v))")
    end
end

# The expression as it serializes, as plain JSON values.
_fw_wire(e) = JSON3.read(JSON3.write(EarthSciAST.serialize_expression(e)))

function _fw_form(flat)
    shapes = Dict{String, Any}()
    for part in (flat.state_variables, flat.parameters, flat.observed_variables), (k, v) in part
        shapes[k] = v.shape === nothing ? nothing : String[string(s) for s in v.shape]
    end
    eqs = Any[Dict("lhs" => _fw_wire(e.lhs), "rhs" => _fw_wire(e.rhs)) for e in flat.equations]
    ics = Any[Dict("target" => t, "rhs" => _fw_wire(r)) for (t, r) in flat.field_ics]
    return sprint() do io
        _fw_canonical(io, Dict("equations" => eqs, "field_ics" => ics, "shapes" => shapes))
        print(io, '\n')
    end
end

# The flattened system as a document, one model per component, every reference
# fully qualified: the shape of the EarthSciIntegrator planner's derived documents.
function _fw_document(flat)
    models = Dict{String, Any}()
    owner(n) = String.(rsplit(n, '.'; limit = 2))
    for (kind, part) in (
                ("unknown", flat.state_variables), ("parameter", flat.parameters),
                ("unknown", flat.observed_variables),
            ), (n, v) in part
        c, l = owner(n)
        m = get!(() -> Dict{String, Any}("variables" => Dict{String, Any}(), "equations" => Any[]), models, c)
        d = Dict{String, Any}("type" => kind)
        v.shape !== nothing && !isempty(v.shape) && (d["shape"] = collect(v.shape))
        v.default !== nothing && (d["default"] = EarthSciAST.serialize_model_variable(v)["default"])
        m["variables"][l] = d
    end
    for e in flat.equations
        lhs = EarthSciAST.serialize_expression(e.lhs)
        # The first name the left-hand side reads: the variable, or the
        # differentiated (possibly pointwise-lifted) state.
        subject = match(r"\"([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_.]+)\"", JSON3.write(lhs))[1]
        push!(models[owner(subject)[1]]["equations"], Dict("lhs" => lhs, "rhs" => EarthSciAST.serialize_expression(e.rhs)))
    end
    for (target, rhs) in flat.field_ics
        push!(
            models[owner(target)[1]]["equations"],
            Dict("lhs" => Dict("op" => "ic", "args" => [target]), "rhs" => EarthSciAST.serialize_expression(rhs))
        )
    end
    sets = Dict(k => Dict("kind" => v.kind, "size" => v.size) for (k, v) in flat.index_sets)
    return Dict("esm" => "1.3.0", "metadata" => Dict("name" => "written"), "index_sets" => sets, "models" => models)
end

function _fw_rhs(file, compiler)
    prob = EarthSciAST.esm_problem(file, (0.0, 1.0); compiler = compiler)
    prog = EarthSciAST.rhs_program(prob)
    du = zeros(length(prob.u0))
    EarthSciAST.rhs!(
        du, prog, EarthSciAST.rhs_workspace(prog), copy(prob.u0),
        zeros(EarthSciAST.tile_layout(prog).n_aux), EarthSciAST.parameter_vector(prog), 0.0,
        EarthSciAST.default_forcing_set(prog)
    )
    names = Vector{String}(undef, length(du))
    for (k, v) in prob.var_map
        names[Int(v)] = String(k)
    end
    return Dict(n => (prob.u0[i], du[i]) for (i, n) in enumerate(names))
end

_fw_built(file, compiler) = try
    _fw_rhs(file, compiler)
catch e
    e isa EarthSciAST.EarthSciASTError || rethrow()
    nothing
end

_fw_bits((u, d)) = (reinterpret(UInt64, Float64(u)), reinterpret(UInt64, Float64(d)))

@testset "flatten_wire conformance" begin
    cases = JSON3.read(read(joinpath(_FW_DIR, "cases.json"), String))["cases"]
    @test length(cases) == 5
    for case in cases
        @testset "$(case["name"])" begin
            file = EarthSciAST.load_path(joinpath(_FW_DIR, case["fixture"]))
            flat = EarthSciAST.expand_flattened_refs(EarthSciAST.flatten(file))
            @test _fw_form(flat) == read(joinpath(_FW_DIR, case["golden"]), String)
            back = EarthSciAST.load_string(JSON3.write(_fw_document(flat)))
            for compiler in (:interpreter, :native)
                want = _fw_built(file, compiler)
                got = _fw_built(back, compiler)
                # The original and the read-back system agree: both build, to
                # the same bits, or both are refused. `builds` is the reference
                # evaluator's verdict; a strict compiler may refuse more.
                @test (want === nothing) == (got === nothing)
                compiler === :interpreter && @test (want !== nothing) == case["builds"]
                (want === nothing || got === nothing) && continue
                @test keys(got) == keys(want)
                @test all(k -> _fw_bits(got[k]) == _fw_bits(want[k]), keys(want))
            end
        end
    end
end

# The template-origin mark is load provenance (esm-spec §9.6.11): a document
# that spells it is refused by the schema, as in every binding, rather than
# read as a template application.
@testset "an authored template-origin mark is refused" begin
    doc = Dict(
        "esm" => "1.3.0", "metadata" => Dict("name" => "authored_mark"),
        "index_sets" => Dict("c" => Dict("kind" => "interval", "size" => 3)),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "parameter", "shape" => ["c"], "default" => [1.0, 2.0, 3.0]),
                    "y" => Dict("type" => "unknown"),
                ),
                "equations" => [
                    Dict(
                        "lhs" => "y",
                        "rhs" => Dict(
                            "op" => "faq", "args" => [], "output_idx" => [],
                            "ranges" => Dict("k" => Dict("from" => "c")),
                            "__esm_template_origin" => "linear", "expr" => "u"
                        )
                    ),
                ],
            )
        ),
    )
    err = try
        EarthSciAST.load_string(JSON3.write(doc))
        nothing
    catch e
        e
    end
    @test err isa EarthSciAST.SchemaValidationError
    @test occursin("__esm_template_origin", sprint(showerror, err))
    @test occursin("/models/M/equations/0/rhs", sprint(showerror, err))
end

# The lift's loop symbols avoid every name the right-hand side reads or binds,
# in any field (esm-spec §9.6.11): here an integral's variable.
@testset "loop symbols avoid a name bound in any field" begin
    ESM = EarthSciAST
    area = ESM.OpExpr(
        "integral", ESM.ASTExpr[ESM.NumExpr(1.0)];
        int_var = "_p0", lower = ESM.NumExpr(0.0), upper = ESM.NumExpr(1.0)
    )
    rhs = ESM.OpExpr("*", ESM.ASTExpr[ESM.VarExpr("rho"), area])
    @test ESM._ew_fresh_loops(rhs, 2, nothing) == ["__p0", "__p1"]
    @test ESM._ew_fresh_loops(ESM.VarExpr("rho"), 1, nothing) == ["_p0"]
end
