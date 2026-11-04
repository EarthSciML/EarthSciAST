# Conformance: run-time providers and the forcing they give a Problem and its
# `rhs_program` (tests/conformance/provider_forcing/README.md; API_SPEC §5.8,
# "Forcing sets"). Consumes manifest.json case by case; every comparison is
# bitwise against the values the manifest records.

using Test
using JSON3
using EarthSciAST
using DiffEqCallbacks            # the refresh callback of a discrete provider
using SciMLBase
using OrdinaryDiffEqTsit5

const PFC = EarthSciAST

const _PFC_DIR = joinpath(
    @__DIR__, "..", "..", "..", "tests", "conformance", "provider_forcing"
)

_pfc_bits(x) = reinterpret(UInt64, Float64[v for v in x])

# One field, `base + slope * t` elementwise (README "Providers").
struct _PFCProvider
    key::String
    times::Vector{Float64}
    shape::Vector{Int}
    base::Any
    slope::Float64
end

function _pfc_value(p::_PFCProvider, t::Real)
    isempty(p.shape) && return [Float64(p.base) + p.slope * t]
    a = Array{Float64}(undef, p.shape...)
    for I in CartesianIndices(a)
        v = p.base
        for i in Tuple(I)
            v = v[i]
        end
        a[I] = Float64(v) + p.slope * t
    end
    return a
end

PFC.provider_refresh_times(p::_PFCProvider) = p.times
PFC.provider_sample(p::_PFCProvider, t::Real; selection = nothing) =
    Dict{String, Any}(p.key => _pfc_value(p, t))

# A provider with every optional capability, for the re-keying wrapper's check.
struct _PFCSelectable end
PFC.provider_supports_selection(::_PFCSelectable) = true
PFC.provider_gate_spec(::_PFCSelectable) = Dict("axes" => Any["all"])
PFC.provider_extent_metaparameter(::_PFCSelectable) = "n"

function _pfc_problem(M, c)
    provs = Dict{String, Any}(
        String(p.key) => _PFCProvider(
            String(p.key), Float64[x for x in p.refresh_times],
            Int[x for x in p.shape], copy(p.base), Float64(p.slope)
        ) for p in c.providers
    )
    kw = Dict{Symbol, Any}(:compiler => :native)
    isempty(provs) || (kw[:providers] = provs)
    get(c, :sample_time, nothing) === nothing || (kw[:sample_time] = Float64(c.sample_time))
    tspan = (Float64(M.tspan[1]), Float64(M.tspan[2]))
    return PFC.esm_problem(joinpath(_PFC_DIR, M.document), tspan; kw...), tspan
end

@testset "provider_forcing conformance" begin
    M = JSON3.read(read(joinpath(_PFC_DIR, "manifest.json"), String))
    for c in M.cases
        @testset "$(c.id)" begin
            prob, tspan = _pfc_problem(M, c)
            prog = PFC.rhs_program(prob)
            slots = PFC.forcing_slots(prog)
            @test slots == [
                PFC.ForcingSlot(String(s.name), Int[x for x in s.shape], Symbol(s.kind))
                    for s in c.forcing_slots
            ]
            D = PFC.default_forcing_set(prog)
            for (i, s) in enumerate(slots)
                @test _pfc_bits(D.bufs[i]) == _pfc_bits(c.default_forcing[Symbol(s.name)])
            end
            # The document's only state is `Fed.u`, default 1.0 everywhere.
            u = ones(PFC.n_states(prog))
            p = PFC.parameter_vector(prog, Dict{String, Float64}())
            du = fill(NaN, PFC.n_states(prog))
            PFC.rhs!(du, prog, PFC.rhs_workspace(prog), u, Float64[], p, tspan[1], D)
            @test _pfc_bits(du) == _pfc_bits(c.du_default)
            dp = fill(NaN, length(prob.u0))
            prob.f!(dp, prob.u0, prob.p, tspan[1])
            @test _pfc_bits(dp) == _pfc_bits(c.du_default)
            # Not a manifest check: a solve integrates what the providers
            # deliver. A run samples them at its own start, t0 = tspan[1]
            # (whatever `sample_time` the Problem was built at), and nothing
            # changes before the first refresh time (0.5), so up to then
            # D(u[i]) = a[i] - k u[i], a[i] = s E[i, 2], and with u(t0) = 1,
            # u(t) = a/k + (1 - a/k) e^(-k (t - t0)).
            k, T = 0.25, 0.25
            field(key, default) = begin
                i = findfirst(p -> String(p.key) in (key, "Fed." * key), c.providers)
                i === nothing && return default
                pr = c.providers[i]
                return _pfc_value(
                    _PFCProvider(
                        "", Float64[], Int[x for x in pr.shape], copy(pr.base),
                        Float64(pr.slope)
                    ), tspan[1]
                )
            end
            sv = only(field("s", [2.0]))
            Ev = field("E", fill(0.5, 3, 2))
            a = sv .* Ev[:, 2]
            sol = SciMLBase.solve(prob, Tsit5(); saveat = [T], abstol = 1.0e-12, reltol = 1.0e-12)
            uT = sol.u[findfirst(==(T), sol.t)]
            @test uT ≈ a ./ k .+ (1 .- a ./ k) .* exp(-k * (T - tspan[1])) rtol = 1.0e-9
            # A 0-d data-fed parameter given data takes no slot of `p`, which
            # nothing would read: it is const data or a live buffer.
            want = isempty(c.providers) ? :numeric :
                all(p -> isempty(p.refresh_times), c.providers) ? :const_folded : :forcing
            @test PFC.parameter_classes(prob)["Fed.s"] == want
            @test haskey(prob.p, Symbol("Fed.s")) == (want == :numeric)
        end
    end
end

# Binding-local checks beside the suite: a 0-d data-fed parameter read by a
# scalar (unindexed) equation, and two keys for one parameter.
@testset "provider_forcing: scalar equation, key collisions" begin
    doc = Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "scalar_fed", "authors" => ["test"]),
        "data_sources" => Dict(
            "met" => Dict(
                "kind" => "grid",
                "source" => Dict("url_template" => "file:///data/met/fields.nc")
            )
        ),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "x" => Dict("type" => "unknown", "units" => "1", "default" => 1.0),
                    "s" => Dict(
                        "type" => "parameter", "units" => "1/s", "default" => 2.0,
                        "shape" => Any[],
                        "update" => Dict(
                            "kind" => "data", "source" => "met",
                            "from" => Dict("file_variable" => "s")
                        )
                    ),
                    "k" => Dict("type" => "parameter", "units" => "1/s", "default" => 0.25)
                ),
                "equations" => [
                    Dict(
                        "lhs" => Dict("op" => "D", "args" => ["x"], "wrt" => "t"),
                        "rhs" => Dict(
                            "op" => "-",
                            "args" => ["s", Dict("op" => "*", "args" => ["k", "x"])]
                        )
                    ),
                ]
            )
        )
    )
    for (key, times) in (("s", Float64[]), ("M.s", Float64[]), ("s", [0.5]), ("M.s", [0.5]))
        prov = _PFCProvider(key, times, Int[], 3.0, 0.0)
        prob = PFC.esm_problem(
            doc, (0.0, 1.0); compiler = :native, providers = Dict{String, Any}(key => prov)
        )
        du = fill(NaN, 1)
        prob.f!(du, prob.u0, prob.p, 0.0)
        @test du == [2.75]
    end
    _pfc_err(f) = try
        f()
        nothing
    catch e
        e
    end
    run_du(prob) = (du = fill(NaN, 1); prob.f!(du, prob.u0, prob.p, 0.0); du)
    mk(; kw...) = PFC.esm_problem(doc, (0.0, 1.0); compiler = :native, kw...)
    # An exact key wins over a bare key for the same parameter, as it does for
    # `parameter_overrides` (esm-spec §6.6.2); the bare key's data is not read.
    p1 = _PFCProvider("s", Float64[], Int[], 3.0, 0.0)
    p2 = _PFCProvider("M.s", Float64[], Int[], 4.0, 0.0)
    @test run_du(mk(providers = Dict{String, Any}("s" => p1, "M.s" => p2))) == [3.75]
    # A provider keyed by the bare name of an ORDINARY scalar parameter feeds it.
    pk = _PFCProvider("k", Float64[], Int[], 0.5, 0.0)
    @test run_du(mk(providers = Dict{String, Any}("k" => pk))) == [1.5]
    # An explicit override outranks const data for a scalar, as for a shaped
    # parameter, and is refused beside a live buffer the run rewrites.
    for key in ("s", "M.s")
        cp = _PFCProvider(key, Float64[], Int[], 3.0, 0.0)
        prob = mk(p = Dict("s" => 5.0), providers = Dict{String, Any}(key => cp))
        @test run_du(prob) == [4.75]
        live = _PFCProvider(key, [0.5], Int[], 3.0, 0.0)
        err = _pfc_err(() -> mk(p = Dict("s" => 5.0), providers = Dict{String, Any}(key => live)))
        @test err isa ArgumentError && occursin("live forcing buffer", err.msg)
    end
    # A provider and the caller's own array for one parameter, under any
    # spellings: refused rather than one silently replacing the other.
    for (pk_, ck) in (("s", "M.s"), ("M.s", "s"), ("M.s", "M.s"))
        pr = _PFCProvider(pk_, Float64[], Int[], 3.0, 0.0)
        err = _pfc_err(
            () -> mk(providers = Dict{String, Any}(pk_ => pr), const_arrays = Dict(ck => [9.0]))
        )
        @test err isa ArgumentError && occursin("both supply the parameter 'M.s'", err.msg)
    end
    # The override replaces the data under every key that holds it: the
    # caller's spelling (`s`) beside the build's name (`M.s`), so a consumer
    # that reads the caller's spelling sees the override too.
    model = PFC.coerce_esm_file(JSON3.read(JSON3.write(doc))).models["M"]
    data = [3.0]
    out = PFC._scalar_overrides_over_supplied(
        model, Dict{String, Any}("s" => data, "M.s" => data), Dict{String, Any}(),
        Dict("s" => 5.0)
    )
    @test out["s"] == [5.0] && out["M.s"] == [5.0]
    # With two models carrying `s`, a bare `s` in `const_arrays` beside a
    # provider for `Fed.s` is ambiguous (esm-spec §6.6.2), the shared
    # resolver's diagnostic, not a claim that both supply `Fed.s`.
    two = deepcopy(doc)
    two["models"]["Fed"] = two["models"]["M"]
    two["models"]["Other"] = Dict(
        "variables" => Dict(
            "y" => Dict("type" => "unknown", "units" => "1", "default" => 1.0),
            "s" => Dict("type" => "parameter", "units" => "1/s", "default" => 1.0)
        ),
        "equations" => [
            Dict(
                "lhs" => Dict("op" => "D", "args" => ["y"], "wrt" => "t"),
                "rhs" => Dict("op" => "*", "args" => ["s", "y"])
            ),
        ]
    )
    delete!(two["models"], "M")
    pr = _PFCProvider("Fed.s", Float64[], Int[], 3.0, 0.0)
    err = _pfc_err(
        () -> PFC.esm_problem(
            two, (0.0, 1.0); compiler = :native,
            providers = Dict{String, Any}("Fed.s" => pr), const_arrays = Dict("s" => [9.0])
        )
    )
    @test err isa ArgumentError && occursin("const_arrays: ambiguous parameter name 's'", err.msg)
    # The other model's own `s`, named in full, is no overlap.
    prob = PFC.esm_problem(
        two, (0.0, 1.0); compiler = :native,
        providers = Dict{String, Any}("Fed.s" => pr), const_arrays = Dict("Other.s" => [9.0])
    )
    @test prob !== nothing
    # A key a `variable_map` coupling reads keeps its own name rather than
    # being routed onto the parameter it is a bare suffix of, as in Rust; the
    # parameter's exact name is still routed.
    flat = PFC.flatten(PFC.coerce_esm_file(JSON3.read(JSON3.write(doc))))
    @test first(PFC._provider_routing((flat = flat,), ["s"]))["s"] == "M.s"
    kept = (flat = flat, coupling_reads = Set(["s", "M.s"]))
    targets, _ = PFC._provider_routing(kept, ["s"])
    @test !haskey(targets, "s")
    @test first(PFC._provider_routing(kept, ["M.s"]))["M.s"] == "M.s"
    # The re-keying wrapper answers every optional provider capability as the
    # provider it wraps does.
    w = PFC._RekeyedProvider(_PFCSelectable(), Pair{String, String}[])
    @test PFC.provider_supports_selection(w)
    @test PFC.provider_gate_spec(w) == Dict("axes" => Any["all"])
    @test PFC.provider_extent_metaparameter(w) == "n"
end
