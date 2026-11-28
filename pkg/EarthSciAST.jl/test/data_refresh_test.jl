# Discrete-cadence loader refresh — build_refresh_callback.
#
# A forcing buffer is readable LIVE by the RHS (`param_arrays`
# / `_NK_PARAM_GATHER`). These tests pin the surface that drives it: a
# `PresetTimeCallback` whose `affect!` samples a Provider, regrids, and writes
# the SAME buffer object in place at each cadence anchor. They exercise the full
# user wiring — the build + `build_refresh_callback` + an honest
# `solve(prob, Tsit5(); callback, tstops)` (the solver is the test-only dep; ESS
# ships none) — and assert every acceptance clause:
#   • build_refresh_callback returns (cb, tstops);
#   • the buffer refreshes at each preset time and the RHS reads the latest;
#   • CONST providers are materialize-once with NO tstops;
#   • dependent/observed vars over the buffer recompute for free;
#   • the per-step RHS path stays zero-alloc within a segment.
# Plus the protocol/type guards that need no solver.

using Test
using EarthSciAST
using DiffEqCallbacks            # loads EarthSciASTCallbacksExt
using SciMLBase                  # ext co-trigger (u_modified!)
import OrdinaryDiffEqTsit5 as ODE  # Tsit5 + ODEProblem + solve (cf. scripts/pde_simulation_adapter.jl)

include("testutils.jl")  # builder quartet + zero_alloc_harness.jl

const ESM = EarthSciAST

# ---- A mock Provider implementing the ESS consumer protocol ----
# A DISCRETE provider has non-empty `times` and a per-tick (var => field) table;
# a CONST provider has empty `times`. `nsamples` records every provider_sample
# call so a test can prove a shared provider is sampled once per boundary.
mutable struct MockProvider
    times::Vector{Float64}
    fields::Dict{Float64, Dict{String, Vector{Float64}}}
    nsamples::Int
end
MockProvider(times, fields) = MockProvider(Float64[t for t in times], fields, 0)

ESM.provider_refresh_times(p::MockProvider) = p.times
function ESM.provider_sample(p::MockProvider, t::Real)
    p.nsamples += 1
    tf = Float64(t)
    haskey(p.fields, tf) ||
        error("MockProvider has no sample for t=$tf (have $(sort!(collect(keys(p.fields)))))")
    return p.fields[tf]
end

# A source with NO protocol methods — its generics must throw a clean RefreshError.
struct _BareSource end

@testset "build_refresh_callback" begin

    @testset "returns (cb, tstops); buffer refreshes at each preset time; RHS reads latest" begin
        # D(y) = forcing[1]; forcing is piecewise-constant, refreshed at the
        # interior anchors t=1,2. With D(y)=c on each unit segment Tsit5 is exact,
        # so y(3) is the exact piecewise integral — a direct readout of "the RHS
        # saw the refreshed buffer on each segment."
        model = ESM.Model(
            Dict("y" => ModelVariable(UnknownVariable)),
            [ESM.Equation(_D("y"), _idx("forcing", _i(1)))]
        )
        buf = [2.0]                       # setup-time materialize for the first segment [0,1)
        (f!, u0, p, _ts, vm) = b = EarthSciAST.Internal.build(
            model;
            initial_conditions = Dict("M.y" => 0.0), param_arrays = Dict("forcing" => buf)
        )

        prov = MockProvider(
            [1.0, 2.0], Dict(
                1.0 => Dict("forcing" => [5.0]),
                2.0 => Dict("forcing" => [-1.0])
            )
        )
        cb, tstops = build_refresh_callback(;
            owner = b,
            providers = Dict("forcing" => prov),
            buffers = RefreshBuffers(Dict("forcing" => buf))
        )   # SAME buf object

        @test tstops == [1.0, 2.0]
        @test cb isa SciMLBase.DiscreteCallback                # PresetTimeCallback is a DiscreteCallback

        prob = ODE.ODEProblem(f!, u0, (0.0, 3.0), p)
        sol = ODE.solve(prob, ODE.Tsit5(); callback = cb, tstops = tstops)
        @test sol.retcode == ODE.SciMLBase.ReturnCode.Success
        # ∫ = 2·[0,1) + 5·[1,2) + (-1)·[2,3] = 2 + 5 - 1 = 6
        @test isapprox(sol.u[end][vm["M.y"]], 6.0; atol = 1.0e-8)
        # The buffer ends holding the LAST refreshed value (in place, not realloc).
        @test buf == [-1.0]
    end

    @testset "dependent/observed variable over the buffer recomputes for free" begin
        # dep = 2*forcing[1] (observed, inlined); D(y) = dep. Nothing refreshes
        # `dep` explicitly — it is an RHS expression over the live buffer, so the
        # refresh shows through. y(3) = 2·(piecewise integral).
        #
        # esm 1.0.0 (§6.3.1): `dep` is declared as a plain `unknown`; what makes
        # it OBSERVED is the bare-variable-LHS equation `dep ~ 2*forcing[1]`
        # below, not a declared type. (0.x declared `ObservedVariable` and hung
        # the expression off the variable.)
        vars = Dict(
            "y" => ModelVariable(UnknownVariable),
            "dep" => ModelVariable(UnknownVariable)
        )
        eqs = [
            ESM.Equation(_v("dep"), _op("*", _n(2.0), _idx("forcing", _i(1)))),
            ESM.Equation(_D("y"), _v("dep")),
        ]
        model = ESM.Model(vars, eqs)
        buf = [2.0]
        (f!, u0, p, _ts, vm) = b = EarthSciAST.Internal.build(
            model;
            initial_conditions = Dict("M.y" => 0.0), param_arrays = Dict("forcing" => buf)
        )

        prov = MockProvider(
            [1.0, 2.0], Dict(
                1.0 => Dict("forcing" => [5.0]),
                2.0 => Dict("forcing" => [-1.0])
            )
        )
        cb, tstops = build_refresh_callback(;
            owner = b,
            providers = Dict("forcing" => prov),
            buffers = RefreshBuffers(Dict("forcing" => buf))
        )

        prob = ODE.ODEProblem(f!, u0, (0.0, 3.0), p)
        sol = ODE.solve(prob, ODE.Tsit5(); callback = cb, tstops = tstops)
        @test isapprox(sol.u[end][vm["M.y"]], 12.0; atol = 1.0e-8)   # 2·6
    end

    @testset "CONST provider: materialize-once, no tstops, never refreshed" begin
        # A CONST provider (empty refresh_times) contributes NO tstops and is
        # absent from the callback — it is never sampled.
        model = ESM.Model(
            Dict("y" => ModelVariable(UnknownVariable)),
            [ESM.Equation(_D("y"), _idx("forcing", _i(1)))]
        )
        buf = [4.0]
        (f!, u0, p, _ts, vm) = b = EarthSciAST.Internal.build(
            model;
            initial_conditions = Dict("M.y" => 0.0), param_arrays = Dict("forcing" => buf)
        )

        const_prov = MockProvider(Float64[], Dict{Float64, Dict{String, Vector{Float64}}}())
        @test provider_is_const(const_prov)
        cb, tstops = build_refresh_callback(;
            owner = b,
            providers = Dict("forcing" => const_prov),
            buffers = RefreshBuffers(Dict("forcing" => buf))
        )
        @test isempty(tstops)

        prob = ODE.ODEProblem(f!, u0, (0.0, 2.0), p)
        sol = ODE.solve(prob, ODE.Tsit5(); callback = cb, tstops = tstops)
        @test const_prov.nsamples == 0                         # never sampled
        @test isapprox(sol.u[end][vm["M.y"]], 8.0; atol = 1.0e-8)    # 4·2, buffer never changed
    end

    @testset "several variables sharing one provider are sampled once per boundary" begin
        # D(y) = a[1] + b[1]; both a and b come from ONE provider. At the single
        # anchor t=1 the provider must be sampled exactly once, not once per var.
        model = ESM.Model(
            Dict("y" => ModelVariable(UnknownVariable)),
            [ESM.Equation(_D("y"), _op("+", _idx("a", _i(1)), _idx("b", _i(1))))]
        )
        abuf = [1.0]; bbuf = [1.0]
        (f!, u0, p, _ts, vm) = b = EarthSciAST.Internal.build(
            model;
            initial_conditions = Dict("M.y" => 0.0),
            param_arrays = Dict("a" => abuf, "b" => bbuf)
        )

        prov = MockProvider([1.0], Dict(1.0 => Dict("a" => [10.0], "b" => [100.0])))
        cb, tstops = build_refresh_callback(;
            owner = b,
            providers = Dict("a" => prov, "b" => prov),          # SAME provider object
            buffers = RefreshBuffers(Dict("a" => abuf, "b" => bbuf))
        )
        @test tstops == [1.0]

        prob = ODE.ODEProblem(f!, u0, (0.0, 2.0), p)
        sol = ODE.solve(prob, ODE.Tsit5(); callback = cb, tstops = tstops)
        @test prov.nsamples == 1                               # one sample, two buffers filled
        @test abuf == [10.0] && bbuf == [100.0]
        # ∫ = (1+1)·[0,1) + (10+100)·[1,2] = 2 + 110 = 112
        @test isapprox(sol.u[end][vm["M.y"]], 112.0; atol = 1.0e-8)
    end

    @testset "RHS stays zero-alloc within a segment after a refresh" begin
        # The hot per-step path only READS the buffer; refresh happens at the
        # boundary (the affect). After a refresh, f! must still allocate nothing.
        N = 8
        _ao1(body, idx, lo, hi) = OpExpr(
            "faq", ESM.ASTExpr[];
            output_idx = Any[idx], expr_body = body, ranges = Dict(idx => [lo, hi])
        )
        model = ESM.Model(
            Dict("u" => ModelVariable(UnknownVariable)),
            [
                ESM.Equation(
                    _ao1(_op("D", _idx("u", _v("i")); wrt = "t"), "i", 1, N),
                    _ao1(_op("+", _idx("forcing", _v("i")), _idx("u", _v("i"))), "i", 1, N)
                ),
            ]
        )
        buf = collect(1.0:Float64(N))
        ics = Dict("M.u[$k]" => 0.0 for k in 1:N)
        (f!, u0, p, _ts, _vm) = b = EarthSciAST.Internal.build(
            model;
            initial_conditions = ics, param_arrays = Dict("forcing" => buf)
        )
        du = similar(u0)
        @test rhs_alloc_bytes(f!, du, u0, p, 0.0) == 0
        buf .= buf .+ 1000.0                                   # simulate an in-place refresh
        @test rhs_alloc_bytes(f!, du, u0, p, 0.0) == 0         # still zero-alloc
    end

    @testset "forcing-only observeds: owner = nothing refills at a new t" begin
        # g, a contraction of the forcing F, reads forcing but neither the
        # state nor `t`: in a program build (no discrete-cadence cut) it is a
        # forcing-cadence observed. A callback with `owner = nothing` rewrites F
        # in place without announcing it, so the build keeps refilling g when
        # `t` moves; a callback given `owner` declares the writes announced,
        # and g is then refilled only on an announcement.
        N = 4
        sq(a) = Dict("op" => "*", "args" => Any[a, a])
        doc() = Dict{String, Any}(
            "esm" => "1.2.0",
            "metadata" => Dict("name" => "forcing_tier_refresh", "authors" => ["test"]),
            "data_sources" => Dict(
                "Inv" => Dict(
                    "kind" => "static",
                    "source" => Dict("url_template" => "file:///never_read.nc")
                )
            ),
            "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => N)),
            "models" => Dict(
                "M" => Dict(
                    "variables" => Dict(
                        "u" => Dict(
                            "type" => "unknown", "units" => "1", "shape" => ["x"],
                            "default" => 0.0
                        ),
                        "g" => Dict("type" => "unknown", "units" => "1/s", "shape" => ["x"]),
                        "F" => Dict(
                            "type" => "parameter", "units" => "1/s", "shape" => ["x"],
                            "default" => fill(1.0, N),
                            "update" => Dict(
                                "kind" => "data", "source" => "Inv",
                                "from" => Dict("file_variable" => "F")
                            )
                        )
                    ),
                    "equations" => Any[
                        Dict(
                            "lhs" => "g",
                            "rhs" => Dict(
                                "op" => "faq", "args" => Any[], "output_idx" => ["i"],
                                "ranges" => Dict("i" => Dict("from" => "x"), "k" => Dict("from" => "x")),
                                "expr" => Dict(
                                    "op" => "/", "args" => Any[
                                        Dict("op" => "index", "args" => Any["F", "k"]),
                                        Dict(
                                            "op" => "+", "args" => Any[
                                                1.0,
                                                sq(Dict("op" => "-", "args" => Any["k", "i"])),
                                            ]
                                        ),
                                    ]
                                )
                            )
                        ),
                        Dict(
                            "lhs" => Dict(
                                "op" => "faq", "args" => Any[], "output_idx" => ["i"],
                                "ranges" => Dict("i" => Dict("from" => "x")),
                                "expr" => Dict(
                                    "op" => "D", "wrt" => "t",
                                    "args" => Any[Dict("op" => "index", "args" => Any["u", "i"])]
                                )
                            ),
                            "rhs" => Dict(
                                "op" => "faq", "args" => Any[], "output_idx" => ["i"],
                                "ranges" => Dict("i" => Dict("from" => "x")),
                                "expr" => Dict("op" => "index", "args" => Any["g", "i"])
                            )
                        ),
                    ]
                )
            )
        )
        build(F) = esm_problem(
            doc(), (0.0, 2.0); compiler = :native, program_build = true,
            param_arrays = Dict("M.F" => F)
        )
        prov() = MockProvider([1.0], Dict(1.0 => Dict("M.F" => fill(3.0, N))))

        F = ones(N)
        prob = build(F)
        @test prob.build.products.stats.n_mat_forcing_levels == 1
        cb, tstops = build_refresh_callback(;
            owner = nothing, providers = Dict("M.F" => prov()),
            buffers = RefreshBuffers(Dict("M.F" => F))
        )
        @test !prob.build.products.forcing_epoch.announced
        du = similar(prob.u0)
        prob.f!(du, prob.u0, prob.p, 0.5)
        d0 = copy(du)
        ode = ODE.ODEProblem(prob.f!, prob.u0, (0.0, 2.0), prob.p)
        sol = ODE.solve(ode, ODE.Tsit5(); callback = cb, tstops = tstops)
        @test sol.retcode == ODE.SciMLBase.ReturnCode.Success
        @test F == fill(3.0, N)                       # rewritten at the anchor
        prob.f!(du, prob.u0, prob.p, 2.5)
        @test du ≈ 3 .* d0                            # g reads the new data

        F2 = ones(N)
        prob2 = build(F2)
        build_refresh_callback(;
            owner = prob2, providers = Dict("M.F" => prov()),
            buffers = RefreshBuffers(Dict("M.F" => F2))
        )
        @test prob2.build.products.forcing_epoch.announced
        prob2.f!(du, prob2.u0, prob2.p, 0.5)
        @test du == d0
        F2 .= 5.0                                     # an unannounced write
        prob2.f!(du, prob2.u0, prob2.p, 0.75)
        @test du == d0                                # kept across a new `t`
        ESM.notify_forcing_refresh!(prob2)
        prob2.f!(du, prob2.u0, prob2.p, 0.75)
        @test du ≈ 5 .* d0
    end

    @testset "protocol + type guards" begin
        # RefreshBuffers rejects a non-dense-Float64 buffer (the param_arrays invariant).
        err = try
            RefreshBuffers(Dict("f" => [1, 2, 3])); nothing
        catch e
            e
        end
        @test err isa RefreshError

        # _write_forcing!: source/buffer length mismatch is a hard error — the
        # provider must deliver the native forcing on the buffer's grid (regrid
        # is an in-model coupling, not a refresh-time transform).
        err = try
            EarthSciAST._write_forcing!(zeros(3), "f", Dict("f" => [1.0, 2.0]))
            nothing
        catch e
            e
        end
        @test err isa RefreshError

        # _write_forcing!: missing variable in the sample dict.
        err = try
            EarthSciAST._write_forcing!(zeros(2), "f", Dict("g" => [1.0, 2.0]))
            nothing
        catch e
            e
        end
        @test err isa RefreshError

        # _write_forcing! copies a same-length field in place, column-major-linear.
        b = zeros(4)
        EarthSciAST._write_forcing!(b, "f", Dict("f" => [9.0, 8.0, 7.0, 6.0]))
        @test b == [9.0, 8.0, 7.0, 6.0]

        # Unimplemented Provider protocol → a clean RefreshError, not a MethodError.
        @test_throws RefreshError provider_refresh_times(_BareSource())
        @test_throws RefreshError provider_sample(_BareSource(), 0.0)

        # A DISCRETE provider whose variable has no buffer is rejected.
        model = ESM.Model(
            Dict("y" => ModelVariable(UnknownVariable)),
            [ESM.Equation(_D("y"), _idx("forcing", _i(1)))]
        )
        prov = MockProvider([1.0], Dict(1.0 => Dict("forcing" => [5.0])))
        err = try
            build_refresh_callback(;
                owner = nothing,
                providers = Dict("forcing" => prov),
                buffers = RefreshBuffers(Dict("other" => [0.0]))
            )
            nothing
        catch e
            e
        end
        @test err isa RefreshError
    end
end
