# `esm_problem(…; program_build = true)`: the Problem's right-hand side is its
# whole-model program, lowered once, and `rhs_program` returns that program.
# Its evaluations are the ones a program built the default way gives.

using Test
using Random
using EarthSciAST
using DiffEqCallbacks, SciMLBase     # the discrete providers' refresh callback

_pbt_idx(v, ix...) = Dict("op" => "index", "args" => Any[v, ix...])
_pbt_op(op, args...) = Dict("op" => op, "args" => Any[args...])

# A 2-D diffusion `u` forced by a gridded `F` (a live buffer), and a 0-d `y`
# driven by one cell of `F` and a parameter.
function _pbt_doc(nx::Int, ny::Int)
    u(i, j) = _pbt_idx("u", i, j)
    lap = _pbt_op(
        "+", u(_pbt_op("-", "i", 1), "j"), u(_pbt_op("+", "i", 1), "j"),
        u("i", _pbt_op("-", "j", 1)), u("i", _pbt_op("+", "j", 1)),
        _pbt_op("*", -4, u("i", "j"))
    )
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
        "ranges" => Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y")),
        "expr" => e
    )
    return Dict{String, Any}(
        "esm" => "2.0.0",
        "metadata" => Dict("name" => "pbt"),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => nx),
            "y" => Dict("kind" => "interval", "size" => ny)
        ),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x", "y"], "default" => 1.0),
                    "y" => Dict("type" => "unknown", "default" => 0.5),
                    "F" => Dict("type" => "parameter", "shape" => ["x", "y"]),
                    "k" => Dict("type" => "parameter", "default" => 0.25)
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => faq(Dict("op" => "D", "args" => Any[u("i", "j")], "wrt" => "t")),
                        "rhs" => faq(
                            _pbt_op(
                                "+", _pbt_op("*", "k", lap),
                                _pbt_op("*", _pbt_idx("F", "i", "j"), _pbt_op("exp", _pbt_op("*", -1, "t")))
                            )
                        )
                    ),
                    Dict(
                        "lhs" => _pbt_op("D", "y"),
                        "rhs" => _pbt_op("-", _pbt_op("*", "k", _pbt_idx("F", 2, 3)), "y")
                    ),
                ]
            )
        )
    )
end

_pbt_bits(x) = reinterpret(UInt64, x)

@testset "program_build" begin
    nx, ny = 7, 5
    F = reshape(collect(range(0.5, 2.0; length = nx * ny)), nx, ny)
    for c in (:native, :interpreter)
        @testset "$c" begin
            base = esm_problem(
                _pbt_doc(nx, ny), (0.0, 1.0); compiler = c,
                param_arrays = Dict("M.F" => copy(F))
            )
            shared = esm_problem(
                _pbt_doc(nx, ny), (0.0, 1.0); compiler = c,
                param_arrays = Dict("M.F" => copy(F)), program_build = true
            )
            prog0 = rhs_program(base)
            prog = rhs_program(shared)
            # The Problem holds its program: no second build.
            @test rhs_program(shared) === prog
            @test shared.f! === prog.f!

            @test shared.u0 == base.u0
            @test Dict(shared.var_map) == Dict(base.var_map)
            @test n_states(prog) == n_states(prog0)
            @test state_layout(prog) == state_layout(prog0)
            @test tile_layout(prog).n_aux == tile_layout(prog0).n_aux
            @test [s.name for s in parameters(prog)] == [s.name for s in parameters(prog0)]
            @test [(s.name, s.kind, s.shape) for s in forcing_slots(prog)] ==
                [(s.name, s.kind, s.shape) for s in forcing_slots(prog0)]

            rng = Xoshiro(7)
            n = n_states(prog)
            aux = zeros(tile_layout(prog).n_aux)
            ws, ws0 = rhs_workspace(prog), rhs_workspace(prog0)
            fs, fs0 = default_forcing_set(prog), default_forcing_set(prog0)
            pv, pv0 = parameter_vector(prog), parameter_vector(prog0)
            @test pv == pv0
            for t in (0.0, 0.3)
                u = 0.5 .+ rand(rng, n)
                du, du0 = zeros(n), zeros(n)
                rhs!(du, prog, ws, u, aux, pv, t, fs)
                rhs!(du0, prog0, ws0, u, aux, pv0, t, fs0)
                @test _pbt_bits.(du) == _pbt_bits.(du0)
                # The Problem's own `f!` evaluates the same right-hand side.
                dp, dp0 = zeros(n), zeros(n)
                shared.f!(dp, u, shared.p, t)
                base.f!(dp0, u, base.p, t)
                @test _pbt_bits.(dp) == _pbt_bits.(dp0)
            end
            if c === :native
                u = 0.5 .+ rand(rng, n)
                du = zeros(n)
                rhs!(du, prog, ws, u, aux, pv, 0.1, fs)
                @test (@allocated rhs!(du, prog, ws, u, aux, pv, 0.1, fs)) == 0
            end
            # A derived program still builds from the shared one's seed.
            sel = select(prog)
            sel0 = select(prog0)
            u = 0.5 .+ rand(rng, n)
            du, du0 = zeros(n), zeros(n)
            rhs!(du, sel, rhs_workspace(sel), u, aux, pv, 0.2, default_forcing_set(sel))
            rhs!(du0, sel0, rhs_workspace(sel0), u, aux, pv0, 0.2, default_forcing_set(sel0))
            @test _pbt_bits.(du) == _pbt_bits.(du0)
        end
    end
end

# A discrete provider: one field per refresh tick, counting its samples.
mutable struct _PbtDiscrete
    times::Vector{Float64}
    fields::Dict{Float64, Vector{Float64}}
    n::Int
end
EarthSciAST.provider_refresh_times(p::_PbtDiscrete) = p.times
EarthSciAST.provider_sample(p::_PbtDiscrete, t::Real; selection = nothing) =
    (p.n += 1; p.fields[Float64(t)])

# A const provider, counting its samples.
mutable struct _PbtConst
    arr::Vector{Float64}
    n::Int
end
EarthSciAST.provider_refresh_times(::_PbtConst) = Float64[]
EarthSciAST.provider_sample(p::_PbtConst, ::Real; selection = nothing) = (p.n += 1; p.arr)

@testset "program_build: remake, sinks and re-lowerings" begin
    nx, ny = 7, 5
    F = reshape(collect(range(0.5, 2.0; length = nx * ny)), nx, ny)
    base = esm_problem(_pbt_doc(nx, ny), (0.0, 1.0); param_arrays = Dict("M.F" => copy(F)))
    shared = esm_problem(
        _pbt_doc(nx, ny), (0.0, 1.0); param_arrays = Dict("M.F" => copy(F)),
        program_build = true
    )
    @test shared.param_classes == base.param_classes
    @test shared.param_classes["M.k"] === :numeric
    prog = rhs_program(shared)

    # A re-lowering of the Problem's program writes into none of the Problem's
    # build sinks: a class it records stays as it was.
    @test EarthSciAST._relower_kwargs(prog.front)[:_param_classes] === nothing
    @test EarthSciAST._relower_kwargs(prog.front)[:inspect] === nothing
    classes = copy(shared.param_classes)
    shared.param_classes["M.k"] = :pbt_sentinel
    # (`halo`, `restrict` and `lanes` re-lower through `_relower`; this model's
    # 0-d `y` has global locality, so it is re-lowered directly.)
    EarthSciAST._relower(
        prog, EarthSciAST._CaptureSpec(Ref{Any}(nothing), EarthSciAST._ProgramMemo())
    )
    @test shared.param_classes["M.k"] === :pbt_sentinel
    shared.param_classes["M.k"] = classes["M.k"]
    @test shared.param_classes == classes

    # `remake` takes the same overrides as on a default Problem, and the
    # program of the remade Problem, evaluated at its `p`, is its `f!`.
    rb, rs = EarthSciAST.remake(base; p = Dict("M.k" => 0.7)),
        EarthSciAST.remake(shared; p = Dict("M.k" => 0.7))
    @test rs.p == rb.p
    @test_throws Exception EarthSciAST.remake(shared; p = Dict("M.F" => 1.0))
    @test_throws Exception EarthSciAST.remake(base; p = Dict("M.F" => 1.0))
    n = n_states(prog)
    u = collect(range(0.6, 1.4; length = n))
    for r in (rb, rs)
        pr = rhs_program(r)
        @test parameters(pr) == parameters(prog)
        du, g = zeros(n), zeros(n)
        rhs!(du, pr, rhs_workspace(pr), u, Float64[], r.p, 0.3, default_forcing_set(pr))
        r.f!(g, u, r.p, 0.3)
        @test _pbt_bits.(du) == _pbt_bits.(g)
    end
    gb, gs = zeros(n), zeros(n)
    rb.f!(gb, u, rb.p, 0.3)
    rs.f!(gs, u, rs.p, 0.3)
    @test _pbt_bits.(gs) == _pbt_bits.(gb)

    # A program build has no discrete-cadence cut to fill a materializer with;
    # the refusal comes before the input is read.
    err = try
        esm_problem(
            "/nonexistent/pbt.esm", (0.0, 1.0); program_build = true,
            materialize_out = EarthSciAST.DiscreteMaterializer()
        )
        nothing
    catch e
        e
    end
    @test err isa SimulateError && occursin("materialize_out", sprint(showerror, err))
end

@testset "program_build: providers" begin
    fixture = joinpath(@__DIR__, "fixtures", "refresh", "coupled_forced.esm")
    mk() = Dict{String, Any}(
        "src" => _PbtDiscrete(
            [1.0, 2.0],
            Dict(0.0 => [1.0, 1.0, 1.0], 1.0 => [2.0, 2.0, 2.0], 2.0 => [3.0, 3.0, 3.0]), 0
        ),
        "scale" => _PbtConst([1.0, 2.0, 3.0], 0)
    )
    pv0, pv = mk(), mk()
    base = esm_problem(fixture, (0.0, 3.0); providers = pv0)
    shared = esm_problem(fixture, (0.0, 3.0); providers = pv, program_build = true)
    prog = rhs_program(shared)
    # Each provider is sampled once, at construction: the program is built
    # from those samples.
    @test pv["scale"].n == 1
    @test pv["src"].n == 1
    @test rhs_program(shared) === prog
    fs0 = default_forcing_set(rhs_program(base))
    @test default_forcing_set(prog).bufs == fs0.bufs
    @test any(==([1.0, 1.0, 1.0]), fs0.bufs)

    # A refresh writes the live buffers in place (here the re-seed of a run
    # starting at t = 1); `rhs_program` then holds the forcing as it is now,
    # as a default-built Problem's does.
    EarthSciAST._prepare_run!(base, 1.0)
    EarthSciAST._prepare_run!(shared, 1.0)
    prog1, prog01 = rhs_program(shared), rhs_program(base)
    fs1 = default_forcing_set(prog1)
    @test prog1 !== prog
    @test prog1.f! === shared.f!
    @test fs1.bufs == default_forcing_set(prog01).bufs
    @test any(==([2.0, 2.0, 2.0]), fs1.bufs)
    @test default_forcing_set(prog).bufs == fs0.bufs
    @test rhs_program(shared) === prog1
    @test default_forcing_set(select(prog1)) === fs1

    n = n_states(prog1)
    u = collect(range(0.1, 1.0; length = n))
    aux = zeros(tile_layout(prog1).n_aux)
    du, du0, dp = zeros(n), zeros(n), zeros(n)
    rhs!(du, prog1, rhs_workspace(prog1), u, aux, parameter_vector(prog1), 1.5, fs1)
    rhs!(
        du0, prog01, rhs_workspace(prog01), u, aux, parameter_vector(prog01), 1.5,
        default_forcing_set(prog01)
    )
    @test _pbt_bits.(du) == _pbt_bits.(du0)
    shared.f!(dp, u, shared.p, 1.5)
    @test _pbt_bits.(dp) == _pbt_bits.(du)
    ws = rhs_workspace(prog1)
    pvec = parameter_vector(prog1)
    rhs!(du, prog1, ws, u, aux, pvec, 1.5, fs1)
    @test (@allocated rhs!(du, prog1, ws, u, aux, pvec, 1.5, fs1)) == 0
end

# Externally fed parameters (a scalar `s`, a shaped `E`) with observeds over
# them: a program reads both from live buffers, the default build folds them.
function _pbt_fed_doc(n::Int)
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict("i" => Dict("from" => "x")), "expr" => e
    )
    fed(fv) = Dict("kind" => "data", "source" => "met", "from" => Dict("file_variable" => fv))
    return Dict{String, Any}(
        "esm" => "2.0.0",
        "metadata" => Dict("name" => "pbt_fed"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => n)),
        "data_sources" => Dict(
            "met" => Dict("kind" => "grid", "source" => Dict("url_template" => "file:///met.nc"))
        ),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x"], "default" => 1.0),
                    "y" => Dict("type" => "unknown", "default" => 0.0),
                    "s" => Dict(
                        "type" => "parameter", "shape" => Any[], "default" => 2.0,
                        "update" => fed("s")
                    ),
                    "E" => Dict(
                        "type" => "parameter", "shape" => ["x"], "default" => 0.5,
                        "update" => fed("E")
                    ),
                    "k" => Dict("type" => "parameter", "default" => 0.25),
                    "o" => Dict("type" => "unknown"),
                    "g" => Dict("type" => "unknown", "shape" => ["x"])
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => faq(Dict("op" => "D", "args" => Any[_pbt_idx("u", "i")], "wrt" => "t")),
                        "rhs" => faq(
                            _pbt_op(
                                "-", _pbt_op("*", "s", _pbt_idx("E", "i")),
                                _pbt_op("*", "k", _pbt_idx("u", "i"))
                            )
                        )
                    ),
                    Dict("lhs" => _pbt_op("D", "y"), "rhs" => _pbt_op("*", "o", "k")),
                    Dict("lhs" => "o", "rhs" => _pbt_op("+", _pbt_op("*", "s", "k"), "y")),
                    Dict(
                        "lhs" => faq(_pbt_idx("g", "i")),
                        "rhs" => faq(_pbt_op("*", "s", _pbt_idx("E", "i")))
                    ),
                ]
            )
        )
    )
end

@testset "program_build: observed fields over fed parameters" begin
    n = 4
    for c in (:native, :interpreter)
        @testset "$c" begin
            base = esm_problem(_pbt_fed_doc(n), (0.0, 1.0); compiler = c)
            shared = esm_problem(_pbt_fed_doc(n), (0.0, 1.0); compiler = c, program_build = true)
            # The documented difference: a fed parameter is a live buffer of
            # the program, so it is not in `p` and is `:forcing`.
            @test keys(shared.p) == (Symbol("M.k"),)
            @test shared.param_classes["M.s"] === :forcing
            @test shared.param_classes["M.k"] === base.param_classes["M.k"]
            u = [0.3, 0.5, 0.7, 0.9, 1.1]
            @test observed_field(shared, "M.g") == observed_field(base, "M.g")
            for name in ("M.o", "M.g")
                @test observed_field(shared, name; u = u, t = 0.2) ==
                    observed_field(base, name; u = u, t = 0.2)
            end
            rb = EarthSciAST.remake(base; p = Dict("M.k" => 0.7))
            rs = EarthSciAST.remake(shared; p = Dict("M.k" => 0.7))
            @test observed_field(rs, "M.o"; u = u, t = 0.2) ==
                observed_field(rb, "M.o"; u = u, t = 0.2)
            @test shared.n_equations == base.n_equations
        end
    end
end

# Counting const providers, and gated ones that serve a selection.
mutable struct _PbtGated
    full::Array{Float64, 3}
    calls::Vector{Symbol}
end
EarthSciAST.provider_refresh_times(::_PbtGated) = Float64[]
EarthSciAST.provider_supports_selection(::_PbtGated) = true
function EarthSciAST.provider_sample(m::_PbtGated, ::Real; selection = nothing)
    selection === nothing && (push!(m.calls, :whole); return m.full)
    push!(m.calls, :selection)
    return m.full[selection[1]:selection[1], selection[2], selection[3]]
end

@testset "program_build: pushdown_rewrite" begin
    fixture = joinpath(
        @__DIR__, "..", "..", "..", "tests", "conformance", "pushdown", "fixtures", "pushdown_l1.esm"
    )
    grid, nrcv = 9, 4
    W, Sv, Ev, Nv = zeros(grid), zeros(grid), zeros(grid), zeros(grid)
    for row in 1:3, col in 1:3
        k = (row - 1) * 3 + col
        W[k] = (col - 1) * 2.0
        Ev[k] = col * 2.0
        Sv[k] = (row - 1) * 2.0
        Nv[k] = row * 2.0
    end
    ca = Dict{String, Any}("src_W" => W, "src_S" => Sv, "src_E" => Ev, "src_N" => Nv)
    lon = [-97.0, -96.9, -96.95, -97.05, -96.98]
    lat = [40.0, 40.01, 39.99, 40.02, 40.0]
    function providers()
        c(a) = _PbtConst(a, 0)
        p = Dict{String, Any}(
            "ISRM.TotalPop" => c([1.0, 2, 3, 4]), "ISRM.MortalityRate" => c([5.0, 6, 7, 8]),
            "ISRM.emis_lon" => c(lon), "ISRM.emis_lat" => c(lat),
            "ISRM.emis_annual" => c([1.0, 2, 3, 4, 5]),
            "ISRM.is_VOC" => c([1.0, 0, 1, 0, 0]), "ISRM.is_NOx" => c([0.0, 1, 0, 0, 0]),
            "ISRM.is_NH3" => c([0.0, 0, 0, 0, 1]), "ISRM.is_SOx" => c(zeros(5)),
            "ISRM.is_PM25" => c([0.0, 0, 0, 1, 0])
        )
        for (i, v) in enumerate(["SOA", "pNO3", "pNH4", "pSO4", "PrimaryPM25"])
            full = [1.0e-3 * (l + 10 * s + 100 * r + 1000 * i) for l in 1:3, s in 1:grid, r in 1:nrcv]
            p["ISRM.SR_$v"] = _PbtGated(full, Symbol[])
        end
        return p
    end
    pv0, pv = providers(), providers()
    base = esm_problem(fixture, (0.0, 1.0); providers = pv0, const_arrays = ca, pushdown_rewrite = true)
    shared = esm_problem(
        fixture, (0.0, 1.0); providers = pv, const_arrays = ca, pushdown_rewrite = true,
        program_build = true
    )
    for name in ("E_VOC", "conc_SOA", "TotalPM25", "deathsK")
        @test isequal(observed_field(shared, name), observed_field(base, name))
    end
    prog = rhs_program(shared)
    @test forcing_slots(prog) == forcing_slots(rhs_program(base))
    # Each const provider is sampled once, at construction, and each gated one
    # fetches its selection once: the program is built from those samples.
    @test all(p.n == 1 for p in values(pv) if p isa _PbtConst)
    @test all(p.calls == [:selection] for p in values(pv) if p isa _PbtGated)
end
