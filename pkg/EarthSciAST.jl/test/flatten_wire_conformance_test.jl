# Cross-language conformance: the flattened system as this binding writes it out,
# byte for byte against the shared golden every binding writes
# (tests/conformance/flatten_wire/README.md; esm-spec §9.6.11, "A flattened
# system keeps its applications' meaning on the wire"; esm-libraries-spec §4.7.5,
# "Pointwise lift: operands read per cell"). This binding keeps template
# references through flatten, so the surviving ones are expanded first, as a
# consumer that writes the flattened system out does. Each written-out system is
# also read back and built under both compilers: the bare expansion it held
# before was refused there with `faq_bare_array_operand`.

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
    return sprint() do io
        _fw_canonical(io, Dict("equations" => eqs, "shapes" => shapes))
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
    return Dict(zip(names, du))
end

@testset "flatten_wire conformance" begin
    cases = JSON3.read(read(joinpath(_FW_DIR, "cases.json"), String))["cases"]
    @test length(cases) == 2
    for case in cases
        @testset "$(case["name"])" begin
            file = EarthSciAST.load_path(joinpath(_FW_DIR, case["fixture"]))
            flat = EarthSciAST.expand_flattened_refs(EarthSciAST.flatten(file))
            @test _fw_form(flat) == read(joinpath(_FW_DIR, case["golden"]), String)
            back = EarthSciAST.load_string(JSON3.write(_fw_document(flat)))
            for compiler in (:interpreter, :native)
                want = _fw_rhs(file, compiler)
                got = _fw_rhs(back, compiler)
                @test keys(got) == keys(want)
                @test all(k -> reinterpret(UInt64, got[k]) == reinterpret(UInt64, want[k]), keys(want))
            end
        end
    end
end
