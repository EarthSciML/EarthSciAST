# Conformance: generalized `ic` equations and the initialization system
# (esm 2.5.0; esm-spec §11.4.2–§11.4.4, API_SPEC §5.8; issue #817), driven by
# the shared manifest at `tests/conformance/ic_system/`.
#
# Each case builds its fixture with the case's tspan, p, u0 and strip under
# both tree-walk compilers, which must agree, and checks the state the Problem
# starts from element by element by flattened name, or the construction
# refusal, or the members of the stripped object it names. Each load checks
# the loader's migration of the deprecated `initialization_equations` block,
# its warnings and refusals, and `validate`'s document-level findings.

using Test
using Logging
using JSON3
using EarthSciAST
using SciMLBase
using OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _ICY_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "ic_system")
const _ICY = JSON3.read(read(joinpath(_ICY_DIR, "manifest.json"), String))

_icy_plain(x) = x isa JSON3.Object ? Dict{String, Any}(String(k) => _icy_plain(v) for (k, v) in x) :
    x isa JSON3.Array ? Any[_icy_plain(v) for v in x] : x

# Structural JSON equality, numbers by value.
_icy_same(a::Number, b::Number) = Float64(a) == Float64(b)
_icy_same(a::AbstractString, b::AbstractString) = a == b
_icy_same(a::AbstractVector, b::AbstractVector) =
    length(a) == length(b) && all(_icy_same(x, y) for (x, y) in zip(a, b))
_icy_same(a::AbstractDict, b::AbstractDict) =
    Set(String.(collect(keys(a)))) == Set(String.(collect(keys(b)))) &&
    all(_icy_same(a[k], b[k]) for k in keys(a))
_icy_same(a, b) = a == b

function _icy_problem(c, compiler::Symbol)
    kw = Dict{Symbol, Any}(:compiler => compiler)
    isempty(c.p) || (kw[:p] = Dict{String, Any}(String(k) => Float64(v) for (k, v) in pairs(c.p)))
    isempty(c.u0) || (kw[:u0] = Dict{String, Any}(String(k) => Float64(v) for (k, v) in pairs(c.u0)))
    isempty(c.strip) || (kw[:strip] = String[String(s) for s in c.strip])
    return esm_problem(
        joinpath(_ICY_DIR, String(c.fixture)), (Float64(c.tspan[1]), Float64(c.tspan[2])); kw...
    )
end

function _icy_check_state(prob, expected, rtol, atol)
    # Julia's Problem keeps a stripped algebraic unknown as a held slot of its
    # own state vector; the state of API_SPEC §5.8 (`state_layout`) leaves it
    # out, as the manifest's `expected` does.
    z = Set{String}(b.name for b in stripped(prob).z_layout)
    held(k) = (br = findfirst('[', k); (br === nothing ? k : k[1:prevind(k, br)]) in z)
    @test Set(String(k) for k in keys(expected)) ==
        Set(String(k) for k in keys(prob.var_map) if !held(String(k)))
    for (k, v) in pairs(expected)
        i = get(prob.var_map, String(k), 0)
        @test i != 0
        i == 0 || @test isapprox(prob.u0[i], Float64(v); rtol = rtol, atol = atol)
    end
    return nothing
end

@testset "ic_system conformance (esm 2.5.0)" begin
    rtol, atol = Float64(_ICY.tolerances.rtol), Float64(_ICY.tolerances.atol)
    @testset "$(c.id) [$(compiler)]" for c in _ICY.cases, compiler in (:native, :interpreter)
        code = get(c, :error_code, nothing)
        if code !== nothing
            err = try
                with_logger(NullLogger()) do
                    _icy_problem(c, compiler)
                end
                nothing
            catch e
                e
            end
            @test err !== nothing
            err === nothing || @test occursin(String(code), sprint(showerror, err))
            continue
        end
        prob = with_logger(NullLogger()) do
            _icy_problem(c, compiler)
        end
        _icy_check_state(prob, c.expected, rtol, atol)
        st = get(c, :stripped, nothing)
        if st !== nothing
            got = JSON3.read(canonical_json(stripped(prob)))
            for (k, want) in pairs(st)
                if k === :algebraic_z0
                    @test _icy_same(_icy_plain(got.algebraic.z0), _icy_plain(want))
                else
                    @test _icy_same(_icy_plain(got[k]), _icy_plain(want))
                end
            end
        end
        if get(c, :not_solvable, false) == true
            err = try
                SciMLBase.solve(prob, Tsit5())
                nothing
            catch e
                e
            end
            @test err !== nothing && occursin("stripped_problem_not_solvable", sprint(showerror, err))
        elseif !is_stripped(prob)
            # The state a solve starts from is the one built.
            sol = SciMLBase.solve(
                prob, Tsit5(); saveat = [Float64(c.tspan[1])], abstol = 1.0e-12, reltol = 1.0e-12
            )
            @test SciMLBase.successful_retcode(sol)
            @test sol.u[1] == prob.u0
        end
    end

    @testset "load $(l.id)" for l in _ICY.loads
        path = joinpath(_ICY_DIR, String(l.fixture))
        lerr = get(l, :load_error, nothing)
        if lerr !== nothing
            err = try
                with_logger(NullLogger()) do
                    load_path(path)
                end
                nothing
            catch e
                e
            end
            @test err !== nothing
            err === nothing || @test occursin(String(lerr), sprint(showerror, err))
            continue
        end
        warns = get(l, :warnings, nothing)
        logs, file = Test.collect_test_logs(; min_level = Logging.Warn) do
            load_path(path)
        end
        if warns !== nothing
            msgs = String[string(r.message) for r in logs if r.level >= Logging.Warn]
            for w in warns
                @test any(m -> occursin(String(w), m), msgs)
            end
            isempty(warns) && @test isempty(msgs)
        end
        emitted = JSON3.read(JSON3.write(serialize_esm_file(file)))
        m = get(l, :model, nothing)
        if m !== nothing
            model = emitted.models[Symbol(m)]
            nf = get(l, :no_field, nothing)
            nf === nothing || @test !haskey(model, Symbol(nf))
            tail = get(l, :equations_tail, nothing)
            if tail !== nothing
                eqs = _icy_plain(model.equations)
                @test length(eqs) >= length(tail)
                @test _icy_same(eqs[(end - length(tail) + 1):end], _icy_plain(tail))
            end
            cnt = get(l, :equations_count, nothing)
            cnt === nothing || @test length(model.equations) == cnt
            g = get(l, :guesses, nothing)
            g === nothing || @test _icy_same(_icy_plain(model.guesses), _icy_plain(g))
        end
        verrs = get(l, :validate_errors, nothing)
        if verrs !== nothing
            r = validate(file)
            codes = Set(String(e.error_type) for e in r.structural_errors)
            ic_codes = Set(c for c in codes if startswith(c, "ic_"))
            @test ic_codes == Set(String(x) for x in verrs if startswith(String(x), "ic_"))
            for want in verrs
                @test String(want) in codes
            end
        end
    end
end
