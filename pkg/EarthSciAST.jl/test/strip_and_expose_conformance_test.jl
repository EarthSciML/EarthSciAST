# Strip and expose (issue #543, CONFORMANCE_SPEC §5.57), driven by the shared
# manifest at `tests/conformance/strip_and_expose/`.

using Test
using EarthSciAST
using JSON3
using OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _SE_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "strip_and_expose")
const _SE = JSON3.read(read(joinpath(_SE_DIR, "manifest.json"), String))

_se_build(path, strip; compiler = :native, tspan = (0.0, 1.0), p = Dict{String, Float64}()) =
    esm_problem(
    joinpath(_SE_DIR, path), tspan; strip = String[String(c) for c in strip], compiler = compiler, p = p
)

_se_plain(x) = x isa JSON3.Object ? Dict{String, Any}(String(k) => _se_plain(v) for (k, v) in x) :
    x isa JSON3.Array ? Any[_se_plain(v) for v in x] : x

function _se_assemble(layout, named)
    n = sum((max(prod(b.shape; init = 1), 1) for b in layout); init = 0)
    out = fill(NaN, n)
    for b in layout
        len = max(prod(b.shape; init = 1), 1)
        v = named[Symbol(b.name)]
        vals = v isa Number ? fill(Float64(v), len) : Float64[x for x in v]
        @assert length(vals) == len
        out[b.offset:(b.offset + len - 1)] = vals
    end
    return out
end

function _se_eval(ks, probe)
    k = ks[String(probe.kernel)]
    u = _se_assemble(state_layout(ks), probe.u)
    z = _se_assemble(z_layout(ks), probe.z)
    p = parameter_vector(ks)
    out = fill(NaN, length(k))
    kernel!(out, k, kernel_workspace(k), u, z, p, Float64(probe.t), Float64(probe.dt), default_forcing_set(ks))
    return out, kernel_layout(k)
end

@testset "conformance: strip and expose (CONFORMANCE_SPEC §5.57)" begin
    @testset "per-class strip: $(c.id)" for c in _SE.per_class
        c.builds_with === nothing || @test _se_build(c.path, c.builds_with) isa EsmProblem
        for classes in c.refuses_with
            err = try
                _se_build(c.path, classes)
                nothing
            catch e
                e
            end
            @test err !== nothing
            if err !== nothing && c.refusal_code !== nothing
                @test occursin(String(c.refusal_code), sprint(showerror, err)) ||
                    getproperty(err, :code) == c.refusal_code
            end
        end
    end

    @testset "stripped object golden: $(c.id)" for c in _SE.stripped_goldens
        tspan = haskey(c, :tspan) ? (Float64(c.tspan[1]), Float64(c.tspan[2])) : (0.0, 1.0)
        p = Dict{String, Float64}(String(k) => Float64(v) for (k, v) in get(c, :p, Dict()))
        prob = _se_build(c.path, c.strip; tspan = tspan, p = p)
        @test canonical_json(stripped(prob)) == read(joinpath(_SE_DIR, c.golden), String)
    end

    @testset "not solvable: $(c.id)" for c in _SE.not_solvable
        prob = _se_build(c.path, c.strip; tspan = (Float64(c.tspan[1]), Float64(c.tspan[2])))
        if c.expect == "solves"
            @test !is_stripped(prob)
            @test solve(prob, Tsit5()) !== nothing
        else
            @test is_stripped(prob)
            e = try
                solve(prob, Tsit5()); nothing
            catch err
                err
            end
            @test e isa SimulateError && e.code == c.expect
            e = try
                OrdinaryDiffEqTsit5.SciMLBase.init(prob, Tsit5()); nothing
            catch err
                err
            end
            @test e isa SimulateError && e.code == c.expect
        end
    end

    tol = _SE.tolerance_classes.algebraic
    close(g, w) = abs(g - w) <= tol.atol + tol.rtol * abs(w)
    @testset "kernel probes: $(c.id)" for c in _SE.kernels
        specs = _se_plain(c.specs)
        sets = [compile_kernels(_se_build(c.path, c.strip; compiler = comp), specs) for comp in (:native, :interpreter)]
        for probe in c.probes
            native, layout = _se_eval(sets[1], probe)
            interp, _ = _se_eval(sets[2], probe)
            for (label, want) in pairs(probe.expected)
                w = want isa Number ? [Float64(want)] : Float64[x for x in want]
                r = if label in (:u, :du)
                    1:length(native)
                else
                    b = layout[findfirst(b -> b.label == String(label), layout)]
                    b.offset:(b.offset + max(prod(b.shape; init = 1), 1) - 1)
                end
                @test length(r) == length(w)
                @test all(close.(native[r], w))
                @test all(close.(interp[r], w))
            end
        end
    end

    function strip_events!(x)
        if x isa AbstractDict
            delete!(x, "continuous_events"); delete!(x, "discrete_events")
            if haskey(x, "coupling")
                x["coupling"] = Any[e for e in x["coupling"] if !(e isa AbstractDict && get(e, "type", "") == "event")]
            end
            foreach(strip_events!, values(x))
        elseif x isa AbstractVector
            foreach(strip_events!, x)
        end
        return x
    end
    @testset "remaining rhs: $(c.id)" for c in _SE.remaining_rhs
        prob = _se_build(c.path, c.strip)
        ks = compile_kernels(prob, [Dict("name" => "rhs")])
        doc = strip_events!(JSON3.read(read(joinpath(_SE_DIR, c.path), String), Dict{String, Any}))
        control = esm_problem(doc, (0.0, 1.0); base_path = dirname(joinpath(_SE_DIR, c.path)))
        prog = rhs_program(control)
        for probe in c.probes
            u = probe.u === nothing ? copy(control.u0) : _se_assemble(state_layout(prog), probe.u)
            want = fill(NaN, length(u))
            rhs!(want, prog, rhs_workspace(prog), u, Float64[], parameter_vector(prog), Float64(probe.t), default_forcing_set(prog))
            k = ks["rhs"]
            got = fill(NaN, length(k))
            kernel!(got, k, kernel_workspace(k), u, Float64[], parameter_vector(ks), Float64(probe.t), 0.0, default_forcing_set(ks))
            @test reinterpret(UInt64, got) == reinterpret(UInt64, want)
        end
    end

    @testset "refusals: $(c.id)" for c in _SE.refusals
        prob = _se_build(c.path, c.strip)
        err = try
            compile_kernels(prob, _se_plain(c.specs)); nothing
        catch e
            e
        end
        @test err isa SimulateError && err.code == c.expect_error.code
        if err !== nothing
            msg = sprint(showerror, err)
            for m in c.expect_error.mentions
                @test occursin(String(m), msg)
            end
        end
    end
end
