# The public, reentrant right-hand side (API_SPEC §5.8, issue #541): forcing
# sets, workspaces, the parameter vector, run-time array parameters, and the
# properties CONFORMANCE_SPEC §5.51 asks a binding to test — equivalence,
# concurrency, history independence, the stale-forcing control, fault
# isolation and zero allocation.

using Test
using Random
using EarthSciAST

const PRT = EarthSciAST

_prt_idx(v, ix...) = Dict("op" => "index", "args" => Any[v, ix...])
_prt_op(op, args...) = Dict("op" => op, "args" => Any[args...])

# A 2-D diffusion `u` forced by a gridded `F`, a 0-d `y` driven by one cell of
# `F` (a read the prelude memoizes in its time tier), and a 0-d `w` reading the
# const table `C` at a subscript taken from the forcing `G`, so a forcing set
# can make one evaluation fault.
function _prt_doc(nx::Int, ny::Int)
    u(i, j) = _prt_idx("u", i, j)
    lap = _prt_op(
        "+", u(_prt_op("-", "i", 1), "j"), u(_prt_op("+", "i", 1), "j"),
        u("i", _prt_op("-", "j", 1)), u("i", _prt_op("+", "j", 1)),
        _prt_op("*", -4, u("i", "j"))
    )
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
        "ranges" => Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y")),
        "expr" => e
    )
    du = faq(Dict("op" => "D", "args" => Any[u("i", "j")], "wrt" => "t"))
    rhs = faq(
        _prt_op(
            "+", _prt_op("*", "k", lap),
            _prt_op(
                "*", _prt_idx("F", "i", "j"),
                _prt_op("exp", _prt_op("*", -1, "k", "t"))
            )
        )
    )
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "prt"),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => nx),
            "y" => Dict("kind" => "interval", "size" => ny),
            "n" => Dict("kind" => "interval", "size" => 3)
        ),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x", "y"], "default" => 1.0),
                    "y" => Dict("type" => "unknown", "default" => 0.0),
                    "w" => Dict("type" => "unknown", "default" => 0.0),
                    "F" => Dict("type" => "parameter", "shape" => ["x", "y"]),
                    "G" => Dict("type" => "parameter", "shape" => ["n"]),
                    "C" => Dict(
                        "type" => "parameter", "shape" => ["n"],
                        "default" => Any[10.0, 20.0, 30.0]
                    ),
                    "k" => Dict("type" => "parameter", "default" => 0.25)
                ),
                "equations" => Any[
                    Dict("lhs" => du, "rhs" => rhs),
                    Dict(
                        "lhs" => _prt_op("D", "y"),
                        "rhs" => _prt_op(
                            "+", _prt_op("*", "k", _prt_idx("F", 1, 1)),
                            _prt_op("*", "k", _prt_idx("F", 1, 1))
                        )
                    ),
                    Dict(
                        "lhs" => _prt_op("D", "w"),
                        "rhs" => _prt_idx("C", _prt_idx("G", 1))
                    ),
                ]
            )
        )
    )
end

_prt_bits(x) = reinterpret(UInt64, x)

function _prt_problem(nx, ny; compiler = :native)
    F = reshape(collect(range(0.5, 2.0; length = nx * ny)), nx, ny)
    G = [2.0, 1.0, 3.0]
    return esm_problem(
        _prt_doc(nx, ny), (0.0, 1.0); compiler = compiler,
        param_arrays = Dict("M.F" => F, "M.G" => G)
    )
end

_prt_alloc(du, x, ws, u, aux, p, t, fs) = @allocated rhs!(du, x, ws, u, aux, p, t, fs)

# Every object reachable from `f`, by identity.
function _prt_objects(f)
    seen = IdDict{Any, Nothing}()
    function walk(x)
        isbits(x) && return
        x isa Union{String, Symbol, Expr, Module, DataType, UnionAll, Core.TypeName, Method} && return
        haskey(seen, x) && return
        seen[x] = nothing
        if x isa Array
            isbitstype(eltype(x)) && return
            foreach(i -> isassigned(x, i) && walk(x[i]), eachindex(x))
            return
        end
        return foreach(i -> isdefined(x, i) && walk(getfield(x, i)), 1:nfields(x))
    end
    walk(f)
    return seen
end

_prt_is_data(x) = x isa Array && isbitstype(eltype(x))

# Every `_SecTCache` reachable from `f`.
function _prt_tcaches(f)
    out = Any[]
    seen = IdDict{Any, Nothing}()
    function walk(x)
        isbits(x) && return
        x isa Union{String, Symbol, Expr, Module, DataType} && return
        haskey(seen, x) && return
        seen[x] = nothing
        x isa PRT._SecTCache && (push!(out, x); return)
        if x isa Array
            isbitstype(eltype(x)) && return
            foreach(i -> isassigned(x, i) && walk(x[i]), eachindex(x))
            return
        end
        return foreach(i -> isdefined(x, i) && walk(getfield(x, i)), 1:nfields(x))
    end
    walk(f)
    return out
end

@testset "public_rhs_program" begin
    nx, ny = 8, 5
    prob = _prt_problem(nx, ny)
    prog = rhs_program(prob)
    L = tile_layout(prog)
    noaux = Float64[]
    rng = Xoshiro(541)
    u0 = 0.5 .+ rand(rng, L.n_u)
    # The faulting set and the stale control read these slots by name.
    names = [s.name for s in forcing_slots(prog)]

    @testset "slots and parameters" begin
        @test names == ["M.F", "M.G"]
        # Bound through `param_arrays` and fed by no data source or handler:
        # run-time arrays, not forcing.
        @test [s.kind for s in forcing_slots(prog)] == [:array_parameter, :array_parameter]
        @test forcing_slots(prog)[1].shape == [nx, ny]
        @test [s.name for s in parameters(prog)] == ["M.k"]
        @test parameters(prog)[1].default == 0.25
        @test parameter_vector(prog) == [0.25]
        @test parameter_vector(prog, Dict("M.k" => 0.5)) == [0.5]
        err = try
            parameter_vector(prog, Dict("M.nope" => 1.0))
        catch e
            e
        end
        @test err isa SimulateError && occursin("M.nope", err.msg)
    end

    @testset "forcing sets" begin
        a = default_forcing_set(prog)
        @test default_forcing_set(prog) === a
        @test forcing_epoch(default_forcing_set(prog)) == forcing_epoch(a)
        c = replace_forcing(a, 2, [1.0, 1.0, 1.0])
        @test forcing_epoch(c) > forcing_epoch(a)
        @test c.bufs[1] === a.bufs[1]                # unchanged buffers are shared
        @test a.bufs[2] == [2.0, 1.0, 3.0]           # and the old set is unchanged
        F = reshape(copy(a.bufs[1]), nx, ny)
        d = forcing_set(prog, [F, a.bufs[2]])
        @test pointer(d.bufs[1]) == pointer(F)       # held, not copied
        @test forcing_epoch(d) != forcing_epoch(forcing_set(prog, [F, a.bufs[2]]))
        @test_throws DimensionMismatch forcing_set(prog, [F])
        @test_throws DimensionMismatch forcing_set(prog, [zeros(3, 3), zeros(3)])
        @test_throws ArgumentError replace_forcing(a, 3, zeros(3))
        # A copy taken at program build, not an alias of the Problem's buffer.
        @test a.bufs[1] == forcing_buffers(prob)[Symbol("M.F")]
        @test a.bufs[1] !== forcing_buffers(prob)[Symbol("M.F")]
        # Derived programs have their parent's signatures and default set.
        sel = select(prog)
        @test forcing_slots(sel) == forcing_slots(prog)
        @test parameters(sel) == parameters(prog)
        @test default_forcing_set(sel) === a
    end

    @testset "state layout" begin
        @test n_states(prog) == L.n_u == nx * ny + 2
        @test state_layout(prog) == [
            StateBlock("M.w", 1, Int[]), StateBlock("M.y", 2, Int[]),
            StateBlock("M.u", 3, [nx, ny]),
        ]
    end

    fs = default_forcing_set(prog)
    pv = parameter_vector(prog)

    @testset "equivalence with the Problem's right-hand side" begin
        G = fill(NaN, L.n_u)
        prob.f!(G, u0, prob.p, 0.3)
        du = fill(NaN, L.n_u)
        rhs!(du, prog, rhs_workspace(prog), u0, noaux, prob.p, 0.3, fs)
        @test _prt_bits.(du) == _prt_bits.(G)
        rhs!(du, prog, rhs_workspace(prog), u0, noaux, pv, 0.3, fs)
        @test _prt_bits.(du) == _prt_bits.(G)
        iprob = _prt_problem(nx, ny; compiler = :interpreter)
        iprog = rhs_program(iprob)
        rhs!(
            du, iprog, rhs_workspace(iprog), u0, noaux, parameter_vector(iprog), 0.3,
            default_forcing_set(iprog)
        )
        @test du ≈ G
    end

    @testset "no internal threading" begin
        ws = rhs_workspace(prog)
        tcs = _prt_tcaches(ws.f!)
        @test !isempty(tcs)
        @test all(tc -> tc.state == -3, tcs)
        @test all(tc -> tc.state != -3, _prt_tcaches(prog.f!))
    end

    # Reference results: one fresh workspace per evaluation.
    draws = [(0.5 .+ rand(rng, L.n_u), [0.1 + 0.4 * rand(rng)], rand(rng)) for _ in 1:8]
    F2 = 3.0 .* fs.bufs[1]
    sets = [fs, replace_forcing(fs, 1, F2)]
    ref = Dict{Tuple{Int, Int}, Vector{Float64}}()
    for (i, (u, p, t)) in enumerate(draws), k in 1:2
        du = fill(NaN, L.n_u)
        rhs!(du, prog, rhs_workspace(prog), u, noaux, p, t, sets[k])
        ref[(i, k)] = du
    end

    @testset "history independence" begin
        ws = rhs_workspace(prog)
        du = fill(NaN, L.n_u)
        for (i, k) in ((1, 1), (2, 2), (2, 1), (3, 2), (1, 2), (1, 1), (8, 2), (8, 2))
            u, p, t = draws[i]
            rhs!(du, prog, ws, u, noaux, p, t, sets[k])
            @test _prt_bits.(du) == _prt_bits.(ref[(i, k)])
        end
        # A forcing change at the same (p, t) is seen.
        @test ref[(1, 1)] != ref[(1, 2)]
    end

    @testset "stale-forcing control" begin
        y = only(b.base for b in L.u if b.name == "M.y")
        u, p, t = draws[4]
        # The template right-hand side reads the Problem's live buffer. Written
        # in place at the same (p, t) with no refresh notice, its memoized read
        # of `F[1, 1]` stays at the old value: the hazard a forcing set removes.
        F = forcing_buffers(prob)[Symbol("M.F")]
        old = F[1]
        du0 = fill(NaN, L.n_u)
        prog.f!(du0, u, p, t)
        F[1] = 100.0
        du1 = fill(NaN, L.n_u)
        prog.f!(du1, u, p, t)
        @test du1[y] === du0[y]                        # stale
        F[1] = old
        # A new set at the same (p, t) on a workspace that loaded the old one.
        ws = rhs_workspace(prog)
        s0 = default_forcing_set(prog)
        F3 = copy(s0.bufs[1])
        F3[1] = 100.0
        s1 = replace_forcing(s0, 1, F3)
        a = fill(NaN, L.n_u)
        rhs!(a, prog, ws, u, noaux, p, t, s0)
        b = fill(NaN, L.n_u)
        rhs!(b, prog, ws, u, noaux, p, t, s1)
        @test b[y] != a[y]
        c = fill(NaN, L.n_u)
        rhs!(c, prog, rhs_workspace(prog), u, noaux, p, t, s1)
        @test _prt_bits.(b) == _prt_bits.(c)
    end

    @testset "concurrency" begin
        ncalls = 1000
        plan = [(rand(rng, 1:length(draws)), rand(rng, 1:2)) for _ in 1:ncalls]
        out = Vector{Vector{Float64}}(undef, ncalls)
        ntasks = max(4, 2 * Threads.nthreads())
        chunks = [Int[] for _ in 1:ntasks]
        for (j, task) in enumerate(rand(rng, 1:ntasks, ncalls))
            push!(chunks[task], j)
        end
        @sync for c in chunks
            Threads.@spawn begin
                ws = rhs_workspace(prog)
                for j in c
                    i, k = plan[j]
                    u, p, t = draws[i]
                    du = fill(NaN, L.n_u)
                    rhs!(du, prog, ws, u, noaux, p, t, sets[k])
                    out[j] = du
                end
            end
        end
        @test all(j -> _prt_bits.(out[j]) == _prt_bits.(ref[plan[j]]), 1:ncalls)
    end

    @testset "fault isolation" begin
        bad = replace_forcing(fs, 2, [7.0, 1.0, 1.0])  # C has 3 entries
        u, p, t = draws[1]
        ws = rhs_workspace(prog)
        du = fill(NaN, L.n_u)
        @test_throws PRT.TreeWalkError rhs!(du, prog, ws, u, noaux, p, t, bad)
        # The same workspace is still good, and so is every other caller.
        rhs!(du, prog, ws, u, noaux, p, t, fs)
        @test _prt_bits.(du) == _prt_bits.(ref[(1, 1)])
        nt = 8
        res = Vector{Any}(undef, nt)
        @sync for q in 1:nt
            Threads.@spawn begin
                w = rhs_workspace(prog)
                d = fill(NaN, L.n_u)
                res[q] = try
                    for _ in 1:50
                        rhs!(d, prog, w, u, noaux, p, t, isodd(q) ? bad : fs)
                    end
                    copy(d)
                catch e
                    e
                end
            end
        end
        for q in 1:nt
            if isodd(q)
                @test res[q] isa PRT.TreeWalkError
            else
                @test _prt_bits.(res[q]) == _prt_bits.(ref[(1, 1)])
            end
        end
    end

    @testset "workspaces share read-only data, never state" begin
        w1, w2 = rhs_workspace(prog), rhs_workspace(prog)
        o1, o2, ot = _prt_objects(w1.f!), _prt_objects(w2.f!), _prt_objects(prog.f!)
        # The const table `C` and the gather index tables are the program's.
        C = [x for x in keys(o1) if x isa Vector{Float64} && x == [10.0, 20.0, 30.0]]
        @test length(C) == 1 && haskey(o2, C[1]) && haskey(ot, C[1])
        tables = [x for x in keys(o1) if x isa Vector{Int} && length(x) > 1]
        @test !isempty(tables) && all(x -> haskey(o2, x) && haskey(ot, x), tables)
        # What two workspaces share is arrays (data, or containers of read-only
        # objects), never per-call state; no instance holds the template's
        # state, scratch or forcing buffers; each one's caches and forcing
        # buffers are its own.
        both = [x for x in keys(o1) if haskey(o2, x)]
        @test all(x -> !ismutable(x) || x isa Array, both)
        @test !any(x -> x isa PRT._WsState, both)
        kinds = prog.shared.factory.kinds
        @test !isempty(kinds) && !any(x -> haskey(kinds, x), keys(o1))
        @test !isempty(w1.caches)
        @test all(
            c -> !haskey(o2, c.f64) && !haskey(ot, c.f64),
            [c for c in w1.caches if c isa PRT._CSECache]
        )
        @test all(b -> isempty(b) || !haskey(o2, b), w1.fbufs)
        # Evaluating leaves every shared array as it was.
        shared = [x for x in keys(o1) if haskey(o2, x) && _prt_is_data(x)]
        snap = map(copy, shared)
        du = fill(NaN, L.n_u)
        for (i, k) in ((1, 1), (2, 2), (5, 1)), w in (w1, w2)
            u, p, t = draws[i]
            rhs!(du, prog, w, u, noaux, p, t, sets[k])
        end
        @test all(isequal.(shared, snap))
    end

    @testset "every forcing slot reaches the kernel" begin
        ws = rhs_workspace(prog)
        @test all(ws.fread)
        u, p, t = draws[2]
        base = fill(NaN, L.n_u)
        rhs!(base, prog, ws, u, noaux, p, t, fs)
        swaps = Dict("M.F" => 3.0 .* fs.bufs[1], "M.G" => [3.0, 1.0, 2.0])
        for (k, s) in enumerate(forcing_slots(prog))
            du = fill(NaN, L.n_u)
            rhs!(du, prog, ws, u, noaux, p, t, replace_forcing(fs, k, swaps[s.name]))
            @test du != base
        end
        # A template that reads a slot's memory through an array the build did
        # not record is refused when the program is built, never left reading
        # the build's data.
        B = zeros(2, 2)
        S = [PRT.ForcingSlot("M.B", [2, 2], :forcing)]
        unrecorded = let a = vec(B)
            (du, u, p, t) -> (du[1] = a[1]; nothing)
        end
        @test_throws ErrorException PRT._ws_factory(unrecorded, 1, PRT._WsCapture(), S, [B])
        recorded = let a = B
            (du, u, p, t) -> (du[1] = a[1]; nothing)
        end
        @test PRT._ws_factory(recorded, 1, PRT._WsCapture(), S, [B]).slot_read == [true]
    end

    @testset "parameter vector length" begin
        ws = rhs_workspace(prog)
        u, p, t = draws[1]
        du = fill(NaN, L.n_u)
        @test_throws DimensionMismatch rhs!(du, prog, ws, u, noaux, Float64[], t, fs)
        @test_throws DimensionMismatch rhs!(du, prog, ws, u, noaux, [0.1, 0.2], t, fs)
    end

    @testset "workspace and set belong to their program" begin
        other = rhs_program(_prt_problem(nx, ny))
        du = fill(NaN, L.n_u)
        u, p, t = draws[1]
        @test_throws ArgumentError rhs!(du, prog, rhs_workspace(other), u, noaux, p, t, fs)
        # Another program with the same slot signature takes the same sets.
        rhs!(du, other, rhs_workspace(other), u, noaux, p, t, fs)
        @test _prt_bits.(du) == _prt_bits.(ref[(1, 1)])
        sel = select(prog)
        @test_throws ArgumentError rhs!(
            fill(NaN, tile_layout(sel).n_u), sel,
            rhs_workspace(prog), u, noaux, p, t, fs
        )
    end

    @static if VERSION >= v"1.12"
        @testset "zero allocation" begin
            ws = rhs_workspace(prog)
            du = fill(NaN, L.n_u)
            u, p, t = draws[1]
            _prt_alloc(du, prog, ws, u, noaux, p, t, sets[1])
            _prt_alloc(du, prog, ws, u, noaux, p, t, sets[2])
            @test _prt_alloc(du, prog, ws, u, noaux, p, t, sets[2]) == 0
            @test _prt_alloc(du, prog, ws, u, noaux, p, t + 0.1, sets[2]) == 0
            # Loading another set is a copy into the workspace's buffers.
            @test _prt_alloc(du, prog, ws, u, noaux, p, t, sets[1]) == 0
        end
    end
end

# `log` of a parameter and of `t`, each read twice so the prelude memoizes it
# behind values filled before it: a parameter vector or a time outside its
# domain throws midway through refilling a tier.
function _prt_fault_doc()
    two(e) = _prt_op("+", e, e)
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "prt_fault"),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "a" => Dict("type" => "unknown", "default" => 0.0),
                    "b" => Dict("type" => "unknown", "default" => 0.0),
                    "c" => Dict("type" => "unknown", "default" => 0.0),
                    "d" => Dict("type" => "unknown", "default" => 0.0),
                    "k" => Dict("type" => "parameter", "default" => 0.5)
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => _prt_op("D", "a"),
                        "rhs" => _prt_op("+", two(_prt_op("exp", "k")), two(_prt_op("*", "k", "k")))
                    ),
                    Dict("lhs" => _prt_op("D", "b"), "rhs" => two(_prt_op("log", "k"))),
                    Dict(
                        "lhs" => _prt_op("D", "c"),
                        "rhs" => _prt_op(
                            "+", two(_prt_op("exp", _prt_op("*", "k", "t"))),
                            two(_prt_op("cos", "t"))
                        )
                    ),
                    Dict(
                        "lhs" => _prt_op("D", "d"),
                        "rhs" => two(_prt_op("log", _prt_op("-", 2, "t")))
                    ),
                ]
            )
        )
    )
end

@testset "a call that throws leaves no stale cache" begin
    prog = rhs_program(esm_problem(_prt_fault_doc(), (0.0, 1.0)))
    fs = default_forcing_set(prog)
    u = zeros(4)
    noaux = Float64[]
    p1, p2 = [0.5], [-0.9]
    fresh(p, t) = (d = fill(NaN, 4); rhs!(d, prog, rhs_workspace(prog), u, noaux, p, t, fs); d)
    ref = fresh(p1, 0.3)
    # The parameters' tier, then the time tier, each refilled under the stamp
    # of the values it held before the call that threw.
    for (p, t) in ((p2, 0.3), (p1, 5.5))
        ws = rhs_workspace(prog)
        du = fill(NaN, 4)
        rhs!(du, prog, ws, u, noaux, p1, 0.3, fs)
        @test_throws DomainError rhs!(du, prog, ws, u, noaux, p, t, fs)
        rhs!(du, prog, ws, u, noaux, p1, 0.3, fs)
        @test reinterpret(UInt64, du) == reinterpret(UInt64, ref)
    end
end

# A shaped parameter with a document default, as const data (the default) or
# as a run-time input.
function _prt_ap_doc(n::Int)
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict("i" => Dict("from" => "x")), "expr" => e
    )
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "prt_ap"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => n)),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x"], "default" => 1.0),
                    "K" => Dict(
                        "type" => "parameter", "shape" => ["x"],
                        "default" => Any[0.1 * i for i in 1:n]
                    )
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => faq(Dict("op" => "D", "args" => Any[_prt_idx("u", "i")], "wrt" => "t")),
                        "rhs" => faq(_prt_op("*", -1, _prt_idx("K", "i"), _prt_idx("u", "i")))
                    ),
                ]
            )
        )
    )
end

@testset "runtime_array_parameters" begin
    n = 6
    baked = esm_problem(_prt_ap_doc(n), (0.0, 1.0))
    live = esm_problem(_prt_ap_doc(n), (0.0, 1.0); runtime_array_parameters = true)
    @test isempty(forcing_slots(rhs_program(baked)))
    prog = rhs_program(live)
    @test forcing_slots(prog) == [ForcingSlot("M.K", [n], :array_parameter)]
    @test haskey(forcing_buffers(live), Symbol("M.K"))
    u = collect(1.0:n)
    du = fill(NaN, n)
    fs = default_forcing_set(prog)
    rhs!(du, prog, rhs_workspace(prog), u, Float64[], parameter_vector(prog), 0.0, fs)
    G = fill(NaN, n)
    baked.f!(G, u, baked.p, 0.0)
    @test du ≈ G
    K2 = collect(range(1.0, 2.0; length = n))
    rhs!(
        du, prog, rhs_workspace(prog), u, Float64[], parameter_vector(prog), 0.0,
        replace_forcing(fs, 1, K2)
    )
    @test du ≈ -K2 .* u
end

@testset "runtime_array_parameters with a caller's array" begin
    n = 6
    Kc = collect(range(0.3, 0.8; length = n))
    u = collect(1.0:n)
    pv = Float64[]
    off = esm_problem(_prt_ap_doc(n), (0.0, 1.0); const_arrays = Dict("M.K" => Kc))
    on = esm_problem(
        _prt_ap_doc(n), (0.0, 1.0); const_arrays = Dict("M.K" => Kc),
        runtime_array_parameters = true
    )
    # Off: the caller's array is build-time data, no slot.
    poff = rhs_program(off)
    @test isempty(forcing_slots(poff))
    du = fill(NaN, n)
    rhs!(du, poff, rhs_workspace(poff), u, Float64[], pv, 0.0, default_forcing_set(poff))
    G = fill(NaN, n)
    off.f!(G, u, off.p, 0.0)
    @test reinterpret(UInt64, du) == reinterpret(UInt64, G)
    @test du ≈ -Kc .* u
    # On: a slot like a document default, its default buffer the caller's array.
    prog = rhs_program(on)
    @test forcing_slots(prog) == [ForcingSlot("M.K", [n], :array_parameter)]
    fs = default_forcing_set(prog)
    @test fs.bufs[1] == Kc
    ws = rhs_workspace(prog)
    rhs!(du, prog, ws, u, Float64[], pv, 0.0, fs)
    @test reinterpret(UInt64, du) == reinterpret(UInt64, G)
    K2 = collect(range(1.0, 2.0; length = n))
    rhs!(du, prog, ws, u, Float64[], pv, 0.0, replace_forcing(fs, 1, K2))
    @test du ≈ -K2 .* u
end

# A pointwise operator a lane program serves: `D(u[i, j]) = F[i, j] - k·u[i, j]`.
function _prt_lane_doc(nx::Int, ny::Int)
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
        "ranges" => Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y")),
        "expr" => e
    )
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "prt_lane"),
        "index_sets" => Dict(
            "x" => Dict("kind" => "interval", "size" => nx),
            "y" => Dict("kind" => "interval", "size" => ny)
        ),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => ["x", "y"], "default" => 1.0),
                    "F" => Dict("type" => "parameter", "shape" => ["x", "y"]),
                    "k" => Dict("type" => "parameter", "default" => 0.25)
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => faq(
                            Dict(
                                "op" => "D", "args" => Any[_prt_idx("u", "i", "j")],
                                "wrt" => "t"
                            )
                        ),
                        "rhs" => faq(
                            _prt_op(
                                "-", _prt_idx("F", "i", "j"),
                                _prt_op("*", "k", _prt_idx("u", "i", "j"))
                            )
                        )
                    ),
                ]
            )
        )
    )
end

@testset "lanes on workspaces" begin
    nx, ny = 7, 4
    F = reshape(collect(range(1.0, 3.0; length = nx * ny)), nx, ny)
    prob = esm_problem(_prt_lane_doc(nx, ny), (0.0, 1.0); param_arrays = Dict("M.F" => F))
    prog = rhs_program(prob)
    lp = lanes(prog, :cells, ["x", "y"])
    fs = default_forcing_set(prog)
    fs2 = replace_forcing(fs, 1, 5.0 .* F)
    u = collect(range(0.5, 1.5; length = nx * ny))
    p = parameter_vector(prog)
    whole(s) = (
        d = fill(NaN, nx * ny);
        rhs!(d, prog, rhs_workspace(prog), u, Float64[], p, 0.0, s); d
    )
    G1, G2 = whole(fs), whole(fs2)
    @test G1 != G2
    allcells = [(i, j) for j in 1:ny for i in 1:nx]
    function batch(ws, s, cells; li = nothing)
        nl = size(cells, 2)
        ul = Float64[u[(cells[2, l] - 1) * nx + cells[1, l]] for l in 1:nl]
        dl = fill(NaN, nl)
        li === nothing ? rhs!(dl, lp, ws, ul, Float64[], p, 0.0, s, cells, nl) :
            rhs!(dl, lp, ws, ul, Float64[], p, 0.0, li, cells, nl)
        return dl
    end
    expect(G, cells) = Float64[G[(cells[2, l] - 1) * nx + cells[1, l]] for l in axes(cells, 2)]
    rng = Xoshiro(7)
    batches = [
        Int32[c[d] for d in 1:2, c in allcells[randperm(rng, nx * ny)[1:k]]]
            for k in (1, 5, nx * ny)
    ]
    # Distinct workspaces on concurrent tasks; every per-call buffer is theirs.
    ok = fill(false, 16)
    @sync for q in 1:16
        Threads.@spawn begin
            local ws = rhs_workspace(lp)
            local good = true
            for r in 1:20, (bi, cells) in enumerate(batches)
                local s, G = isodd(q + r + bi) ? (fs, G1) : (fs2, G2)
                good &= reinterpret(UInt64, batch(ws, s, cells)) ==
                    reinterpret(UInt64, expect(G, cells))
            end
            ok[q] = good
        end
    end
    @test all(ok)
    ws = rhs_workspace(lp)
    cells = batches[2]
    li = lane_inputs(lp, size(cells, 2))
    gather_lane_inputs!(li, lp, p, 0.0, fs2, cells, size(cells, 2))
    @test batch(ws, fs2, cells; li = li) == expect(G2, cells)
    nb = size(cells, 2)
    db = fill(NaN, nb)
    ub = zeros(nb)
    noaux = Float64[]
    # A gather that throws midway leaves the inputs holding no gather.
    bad = Float64.(cells)
    bad[1, 3] = 1.5
    @test_throws InexactError gather_lane_inputs!(li, lp, p, 0.0, fs, bad, nb)
    @test li.fs[] === nothing
    @test_throws ArgumentError rhs!(db, lp, ws, ub, noaux, p, 0.0, li, cells, nb)
    gather_lane_inputs!(li, lp, p, 0.0, fs2, cells, nb)
    @test batch(ws, fs2, cells; li = li) == expect(G2, cells)
    # Inputs, sets and batches that do not fit are refused before any write.
    other = rhs_program(esm_problem(_prt_ap_doc(3), (0.0, 1.0); runtime_array_parameters = true))
    @test_throws ArgumentError gather_lane_inputs!(
        li, lp, p, 0.0, default_forcing_set(other),
        cells, nb
    )
    @test_throws DimensionMismatch gather_lane_inputs!(li, lp, p, 0.0, fs, cells, 0)
    @test_throws DimensionMismatch gather_lane_inputs!(li, lp, p, 0.0, fs, cells, nb + 1)
    @test_throws DimensionMismatch gather_lane_inputs!(li, lp, p, 0.0, fs, cells[1:1, :], nb)
    @test_throws DimensionMismatch gather_lane_inputs!(
        li, lp, p, 0.0, fs, cells[:, 1:(nb - 1)],
        nb - 1
    )
    lp2 = lanes(prog, :cells, ["x", "y"])
    @test_throws ArgumentError gather_lane_inputs!(lane_inputs(lp2, nb), lp, p, 0.0, fs, cells, nb)
    @test_throws ArgumentError rhs!(db, lp, ws, ub, noaux, p, 0.0, lane_inputs(lp2, nb), cells, nb)
    @test li.fs[] === fs2
    # A parameter vector of the wrong length.
    @test_throws DimensionMismatch rhs!(db, lp, ws, ub, noaux, Float64[], 0.0, fs, cells, nb)
    # A tile of the same operator on its own workspace.
    dec = Decomposition(axes = ["x" => (period = nothing,), "y" => (period = nothing,)])
    tile = restrict(
        prog, dec; owned = ("x" => 1:4, "y" => 2:4),
        storage = ("x" => 1:4, "y" => 2:4)
    )
    T = tile_layout(tile)
    b = only(T.u)
    uS = vec(Float64[u[(c[2] - 1) * nx + c[1]] for c in CartesianIndices(Tuple(b.storage))])
    duS = fill(NaN, T.n_u)
    tws = rhs_workspace(tile)
    rhs!(duS, tile, tws, uS, Float64[], p, 0.0, fs2)
    @test_throws DimensionMismatch rhs!(duS, tile, tws, uS, Float64[], [p; p], 0.0, fs2)
    @test all(
        c -> reinterpret(UInt64, duS[PRT._tile_slot(b, (c[1], c[2]))]) ==
            reinterpret(UInt64, G2[(c[2] - 1) * nx + c[1]]),
        CartesianIndices(Tuple(b.owned))
    )
    @static if VERSION >= v"1.12"
        nb = size(cells, 2)
        ub = zeros(nb)
        db = zeros(nb)
        noaux = Float64[]
        lane_alloc() = @allocated rhs!(db, lp, ws, ub, noaux, p, 0.0, fs, cells, nb)
        lane_alloc()
        @test lane_alloc() == 0
        gather_alloc() = @allocated gather_lane_inputs!(li, lp, p, 0.0, fs, cells, nb)
        gather_alloc()
        @test gather_alloc() == 0
        li_alloc() = @allocated rhs!(db, lp, ws, ub, noaux, p, 0.0, li, cells, nb)
        li_alloc()
        @test li_alloc() == 0
        tile_alloc() = @allocated rhs!(duS, tile, tws, uS, noaux, p, 0.0, fs2)
        tile_alloc()
        @test tile_alloc() == 0
    end
end

# A scalar parameter fed by a data source is a 0-d forcing slot, not a
# parameter; a shaped one is a slot of its shape.
function _prt_fed_doc(n::Int)
    faq(e) = Dict(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict("i" => Dict("from" => "x")), "expr" => e
    )
    fed(fv) = Dict("kind" => "data", "source" => "met", "from" => Dict("file_variable" => fv))
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "prt_fed"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => n)),
        "data_sources" => Dict(
            "met" => Dict(
                "kind" => "grid",
                "source" => Dict("url_template" => "file:///met.nc")
            )
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
                    "k" => Dict("type" => "parameter", "default" => 0.25)
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => faq(
                            Dict(
                                "op" => "D", "args" => Any[_prt_idx("u", "i")],
                                "wrt" => "t"
                            )
                        ),
                        "rhs" => faq(
                            _prt_op(
                                "-", _prt_op("*", "s", _prt_idx("E", "i")),
                                _prt_op("*", "k", _prt_idx("u", "i"))
                            )
                        )
                    ),
                    Dict("lhs" => _prt_op("D", "y"), "rhs" => _prt_op("*", "s", "k")),
                ]
            )
        )
    )
end

@testset "externally fed parameters are forcing slots" begin
    n = 5
    prob = esm_problem(_prt_fed_doc(n), (0.0, 1.0))
    prog = rhs_program(prob)
    @test forcing_slots(prog) == [
        ForcingSlot("M.E", [n], :forcing),
        ForcingSlot("M.s", Int[], :forcing),
    ]
    @test parameters(prog) == [ParamSlot("M.k", 0.25)]
    D = default_forcing_set(prog)
    @test D.bufs == [fill(0.5, n), [2.0]]
    u = vcat(0.0, collect(range(0.5, 1.5; length = n)))      # y, then u
    @test [b.name for b in state_layout(prog)] == ["M.y", "M.u"]
    pv = parameter_vector(prog)
    du = fill(NaN, n + 1)
    rhs!(du, prog, rhs_workspace(prog), u, Float64[], pv, 0.0, D)
    G = fill(NaN, n + 1)
    prob.f!(G, u, prob.p, 0.0)
    @test reinterpret(UInt64, du) == reinterpret(UInt64, G)
    s3 = replace_forcing(D, 2, [3.0])
    rhs!(du, prog, rhs_workspace(prog), u, Float64[], pv, 0.0, s3)
    @test du[1] == 3.0 * 0.25
    @test du[2:end] == 3.0 .* 0.5 .- 0.25 .* u[2:end]
end
