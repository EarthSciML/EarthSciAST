# Conformance: the public, thread-safe right-hand side (CONFORMANCE_SPEC §5.51;
# API_SPEC §5.8, "The public right-hand side"; issue #541).
#
# Consumes tests/conformance/public_rhs_program/manifest.json case by case, as
# its README specifies. Every comparison is BITWISE, against `f!` of a Problem
# built with `param_arrays` holding a set's data, or against the program's own
# serial results. `PUBLIC_RHS_CASES` (comma-separated case ids) narrows the run.

using Test
using JSON3
using EarthSciAST

const PRC = EarthSciAST

const _PRC_DIR = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance",
                          "public_rhs_program")

# ---- the generator (README "The generator") ----

function _prc_fnv1a32(s::AbstractString)
    h = 0x811c9dc5
    for b in codeunits(s)
        h = (h ⊻ UInt32(b)) * 0x01000193
    end
    return h
end

function _prc_h(key::AbstractString, k::Integer)
    x = _prc_fnv1a32(key) + 0x9e3779b1 * UInt32(k % UInt32)
    x ⊻= x >> 16
    x *= 0x85ebca6b
    x ⊻= x >> 13
    x *= 0xc2b2ae35
    x ⊻= x >> 16
    return Float64(x) / 2.0^32
end

_prc_bits(x::AbstractVector{Float64}) = reinterpret(UInt64, x)

_prc_kind(k) = k == "array_parameter" ? :array_parameter : Symbol(k)

function _prc_problem(c, opts; param_arrays = nothing)
    kw = Dict{Symbol,Any}(:compiler => :native)
    haskey(opts, :runtime_array_parameters) &&
        (kw[:runtime_array_parameters] = Bool(opts.runtime_array_parameters))
    param_arrays === nothing || (kw[:param_arrays] = param_arrays)
    return PRC.esm_problem(joinpath(_PRC_DIR, c.document), (0.0, 1.0); kw...)
end

# The state of draw `d`, laid out by `state_layout`.
function _prc_u(prog, d::Int)
    u = fill(NaN, PRC.n_states(prog))
    for b in PRC.state_layout(prog)
        for k in 1:prod(b.shape; init = 1)
            u[b.offset + k - 1] = 0.5 + _prc_h("u$d/$(b.name)", k)
        end
    end
    return u
end

function _prc_p(prog, d::Int)
    d == 0 && return PRC.parameter_vector(prog, Dict{String,Float64}())
    ov = Dict{String,Float64}(s.name => 0.5 + _prc_h("p$d/$(s.name)", 1)
                              for s in PRC.parameters(prog))
    return PRC.parameter_vector(prog, ov)
end

_prc_t(d::Int) = d == 0 ? 0.0 : 10 * _prc_h("t$d", 1)

_prc_buf(prefix, s) = Float64[0.5 + _prc_h("$prefix/$(s.name)", k)
                              for k in 1:prod(s.shape; init = 1)]

# A state given by name, placed by `state_layout`.
function _prc_named_state(prog, st)
    u = fill(NaN, PRC.n_states(prog))
    for b in PRC.state_layout(prog)
        u[b.offset] = Float64(st[Symbol(b.name)])
    end
    return u
end

# The reference Problem's `p` for a parameter vector in `parameters` order.
_prc_ref_p(prob, prog, pv) = prob.p === nothing ? nothing :
    NamedTuple{Tuple(Symbol(s.name) for s in PRC.parameters(prog))}(Tuple(pv))

function _prc_eval(prog, ws, u, p, t, fs)
    du = fill(NaN, PRC.n_states(prog))
    PRC.rhs!(du, prog, ws, u, Float64[], p, t, fs)
    return du
end

function _prc_case(c, M)
    opts = c.options
    prob = _prc_problem(c, opts)
    prog = PRC.rhs_program(prob)
    slots = PRC.forcing_slots(prog)

    @testset "1 surface" begin
        @test PRC.n_states(prog) == c.n_states
        @test PRC.state_layout(prog) ==
              [PRC.StateBlock(String(b.name), Int(b.offset) + 1, Int[x for x in b.shape])
               for b in c.state_layout]
        @test [s.name for s in PRC.parameters(prog)] == [String(s.name) for s in c.parameters]
        @test all(zip(PRC.parameters(prog), c.parameters)) do (a, b)
            b.default === nothing ? a.default === nothing :
                reinterpret(UInt64, a.default) == reinterpret(UInt64, Float64(b.default))
        end
        @test slots == [PRC.ForcingSlot(String(s.name), Int[x for x in s.shape], _prc_kind(s.kind))
                        for s in c.forcing_slots]
    end

    D = PRC.default_forcing_set(prog)
    @testset "2 default forcing" begin
        for (i, s) in enumerate(slots)
            @test _prc_bits(D.bufs[i]) ==
                  _prc_bits(Float64[x for x in c.default_forcing[Symbol(s.name)]])
        end
        @test PRC.forcing_epoch(PRC.default_forcing_set(prog)) == PRC.forcing_epoch(D)
    end

    has_ab = !isempty(slots)
    A = has_ab ? PRC.forcing_set(prog, [_prc_buf("fA", s) for s in slots]) : nothing
    B = nothing
    if has_ab
        rs = findfirst(s -> s.name == String(c.replace_slot), slots)
        Abufs = [copy(b) for b in A.bufs]
        B = PRC.replace_forcing(A, rs, _prc_buf("fB", slots[rs]))
        @testset "3 epochs" begin
            e = PRC.forcing_epoch.((D, A, B))
            @test allunique(e)
            @test all(i -> A.bufs[i] == Abufs[i], eachindex(Abufs))
            @test PRC.forcing_epoch(PRC.forcing_set(prog, A.bufs)) ∉ e
        end
    end

    @testset "4 parameter vector" begin
        @test PRC.parameter_vector(prog, Dict{String,Float64}()) ==
              Float64[s.default for s in c.parameters]
        err = try
            PRC.parameter_vector(prog, Dict("NoSuchModel.nothing" => 1.0))
        catch e
            e
        end
        @test err isa Exception && occursin("NoSuchModel.nothing", sprint(showerror, err))
    end

    # ---- the task list ----
    ndraw = Int(M.draws.count)
    sets = has_ab ? [D, A, B] : [D]
    setname = has_ab ? ["D", "A", "B"] : ["D"]
    tasks = Tuple{Vector{Float64},Vector{Float64},Float64,Int}[]
    for d in 0:(ndraw - 1), k in eachindex(sets)
        push!(tasks, (_prc_u(prog, d), _prc_p(prog, d), _prc_t(d), k))
    end
    fault = c.kind == "fault"
    if fault
        push!(tasks, (_prc_named_state(prog, c.ok_state), _prc_p(prog, 0), 0.0, 1))
    end
    run(ws, j) = (x = tasks[j]; _prc_eval(prog, ws, x[1], x[2], x[3], sets[x[4]]))

    # Reference Problems: the Problem as built for D; one built with
    # `param_arrays` holding the set's data for A and B.
    refprob = Dict{Int,Any}(1 => prob)
    for k in 2:length(sets)
        pa = Dict{String,Any}(s.name => reshape(copy(sets[k].bufs[i]), Tuple(s.shape))
                              for (i, s) in enumerate(slots))
        refprob[k] = _prc_problem(c, opts; param_arrays = pa)
    end
    function reference(j)
        u, p, t, k = tasks[j]
        rp = refprob[k]
        du = fill(NaN, length(u))
        rp.f!(du, u, _prc_ref_p(rp, prog, p), t)
        return du
    end

    ws = PRC.rhs_workspace(prog)
    serial = [run(ws, j) for j in eachindex(tasks)]
    if !fault
        @testset "5 equivalence" begin
            for j in eachindex(tasks)
                @test _prc_bits(serial[j]) == _prc_bits(reference(j))
            end
        end
    end

    @testset "6 history independence" begin
        w2 = PRC.rhs_workspace(prog)
        order = sortperm([(_prc_h("order", i), i) for i in eachindex(tasks)])
        for j in order
            run(w2, j)
        end
        @test _prc_bits(run(w2, 1)) == _prc_bits(run(PRC.rhs_workspace(prog), 1))
    end

    nthreads = Int(M.concurrency.threads)
    ncalls = Int(M.concurrency.calls_per_thread)
    fault_u = fault ? _prc_named_state(prog, c.fault_state) : nothing
    p0 = _prc_p(prog, 0)
    @testset "7 concurrency" begin
        ok = fill(false, nthreads)
        @sync for q in 1:nthreads
            Threads.@spawn begin
                local w = PRC.rhs_workspace(prog)
                local good = true
                for j in 1:ncalls
                    if fault && q == 1
                        local got = try
                            _prc_eval(prog, w, fault_u, p0, 0.0, D)
                            nothing
                        catch e
                            e
                        end
                        good &= got isa PRC.TreeWalkError &&
                                got.code == String(c.expect_error.code)
                    else
                        local i = floor(Int, _prc_h("c$q", j) * length(tasks)) + 1
                        good &= _prc_bits(run(w, i)) == _prc_bits(serial[i])
                    end
                end
                ok[q] = good
            end
        end
        @test all(ok)
    end

    if c.kind == "forcing" || c.kind == "array_parameters"
        @testset "stale-forcing control" begin
            w = PRC.rhs_workspace(prog)
            u, p, t = _prc_u(prog, 0), _prc_p(prog, 0), _prc_t(0)
            rA = _prc_eval(prog, w, u, p, t, A)
            rB = _prc_eval(prog, w, u, p, t, B)
            @test _prc_bits(rB) != _prc_bits(rA)
            @test _prc_bits(rB) == _prc_bits(reference(3))    # task (0, B)
            if c.kind == "forcing" && Bool(c.stale_control.julia)
                # The old path: `f!` reading the Problem's buffers, overwritten in
                # place with no refresh notice, keeps the old result.
                rp = refprob[2]
                old = fill(NaN, length(u))
                rp.f!(old, u, _prc_ref_p(rp, prog, p), t)
                rs = findfirst(s -> s.name == String(c.replace_slot), slots)
                PRC.forcing_buffers(rp)[Symbol(slots[rs].name)] .= B.bufs[rs]
                stale = fill(NaN, length(u))
                rp.f!(stale, u, _prc_ref_p(rp, prog, p), t)
                @test _prc_bits(stale) == _prc_bits(old)
                PRC.forcing_buffers(rp)[Symbol(slots[rs].name)] .= A.bufs[rs]
            end
        end
    end

    if c.kind == "array_parameters"
        @testset "baked twin" begin
            twin = _prc_problem(c, c.baked_twin.options)
            tp = PRC.rhs_program(twin)
            @test [s.name for s in PRC.parameters(tp)] ==
                  [String(s.name) for s in c.baked_twin.parameters]
            @test isempty(c.baked_twin.forcing_slots) && isempty(PRC.forcing_slots(tp))
            tw = PRC.rhs_workspace(tp)
            tD = PRC.default_forcing_set(tp)
            for d in 0:(ndraw - 1)
                u, p, t = _prc_u(prog, d), _prc_p(prog, d), _prc_t(d)
                @test _prc_bits(_prc_eval(tp, tw, u, p, t, tD)) ==
                      _prc_bits(_prc_eval(prog, ws, u, p, t, D))
            end
        end
    end

    if fault
        @testset "fault returned, no latch" begin
            w = PRC.rhs_workspace(prog)
            err = try
                _prc_eval(prog, w, fault_u, p0, 0.0, D)
                nothing
            catch e
                e
            end
            @test err isa PRC.TreeWalkError && err.code == String(c.expect_error.code)
            uok = _prc_named_state(prog, c.ok_state)
            @test _prc_bits(_prc_eval(prog, w, uok, p0, 0.0, D)) ==
                  _prc_bits(_prc_eval(prog, PRC.rhs_workspace(prog), uok, p0, 0.0, D))
        end
    end

    @static if VERSION >= v"1.12"
        @testset "allocation" begin
            # Alternating two forcing sets and two parameter vectors.
            u = _prc_u(prog, 1)
            pA, pB = _prc_p(prog, 1), _prc_p(prog, 2)
            sA, sB = has_ab ? (A, B) : (D, D)
            du = fill(NaN, PRC.n_states(prog))
            aux = Float64[]
            w = PRC.rhs_workspace(prog)
            call(p, s) = @allocated PRC.rhs!(du, prog, w, u, aux, p, 0.25, s)
            for _ in 1:2
                call(pA, sA); call(pB, sB)
            end
            @test call(pA, sA) + call(pB, sB) + call(pA, sB) + call(pB, sA) == 0
        end
    end
end

@testset "public_rhs_program conformance (CONFORMANCE_SPEC §5.51)" begin
    M = JSON3.read(read(joinpath(_PRC_DIR, "manifest.json"), String))
    @testset "generator" begin
        for chk in M.generator.checks
            @test _prc_h(String(chk.key), Int(chk.k)) == Float64(chk.h)
        end
    end
    only_ids = get(ENV, "PUBLIC_RHS_CASES", "")
    keep = isempty(only_ids) ? nothing : Set(split(only_ids, ","))
    for c in M.cases
        keep === nothing || String(c.id) in keep || continue
        c.kind in ("forcing", "array_parameters", "fault") ||
            error("public_rhs_program: unknown case kind '$(c.kind)' in case $(c.id)")
        @testset "$(c.id)" begin
            _prc_case(c, M)
        end
    end
end
