# XLA tracing of the out-of-place RHS, via ext/EarthSciASTReactantExt.jl.
#
# OPT-IN. Reactant is a heavy dependency (a bundled XLA runtime) and is deliberately
# NOT a test dep, so `Pkg.test()` never loads it. runtests.jl includes this file only
# when `ESM_TEST_REACTANT=1`, and the environment must then supply Reactant itself:
#
#     julia --project=@reactant -e 'using Pkg
#         Pkg.develop(path="pkg/EarthSciAST.jl"); Pkg.add(["Reactant","OrdinaryDiffEqTsit5"])'
#     ESM_TEST_REACTANT=1 julia --project=@reactant pkg/EarthSciAST.jl/test/reactant_oop_test.jl
#
# WHAT IS BEING ASSERTED, AND WHAT CANNOT BE.
#
# NOT bit-equality. Every other consumer of the out-of-place emitter is pinned to `f!`
# BIT FOR BIT (tree_walk_oop_test.jl), and that is the right assertion there, because
# both run the same Float64 operations in the same order. XLA does not: it reassociates
# sums and contracts multiply-adds into FMAs, both of which are value-changing
# transformations that are also the entire point of compiling. So the assertion here is
# AGREEMENT TO A FEW ULP — `rtol = 1e-14`, against measured worst cases of 1.4e-17
# (reaction–diffusion) and 5.6e-17 (the 0-D CSE model), i.e. ~3 orders of margin. A
# tolerance is not a weaker claim here, it is the only true one; asserting `==` would
# be asserting that XLA did not optimize.
#
# THE TWO SILENT-STALENESS TRAPS. Both are `@test_broken`, and both are the same bug
# in different clothes: a value the tracer sees as a HOST CONSTANT gets baked into the
# compiled program, and a later host-side update is invisible to it. No error is
# raised, the program runs at full speed, and the numbers look plausible.
#
#   1. `t` passed as a plain `Float64` is frozen at its compile-time value. Fixed by
#      passing a `ConcreteRNumber` — so this one is a USAGE contract, and the test
#      pins both halves (frozen when concrete, live when traced).
#   2. A live forcing buffer (`param_arrays`, ess-14f.3) is frozen at its
#      compile-time CONTENTS, because `_NK_PARAM_GATHER` / `_VK_PGATHER` hold the
#      aliased host `Vector{Float64}` in the node payload. This one CANNOT be fixed by
#      calling differently: the buffer is a closure capture, not an argument, so there
#      is no way to hand XLA a fresh value. `build_refresh_callback`'s in-place refresh
#      is therefore INVISIBLE to a compiled RHS. The `@test_broken` below is the
#      failing test for that, and it is what must go green before a model with data
#      loaders may be compiled. See ext/EarthSciASTReactantExt.jl for the fix's shape.

using Test
using EarthSciAST
using Reactant
using OrdinaryDiffEqTsit5
using SciMLBase

const ESM = EarthSciAST
const RX = Reactant

_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_cst(v) = Dict{String,Any}("op" => "const", "value" => v)
_fnop(nm, a...) = Dict{String,Any}("op" => "fn", "name" => nm, "args" => Any[a...])
_ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)
_doc(name, vars, eqs; index_sets = nothing) = begin
    d = Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => name),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => vars, "equations" => eqs)))
    index_sets === nothing || (d["index_sets"] = index_sets)
    d
end
_nset(N) = Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => N))
_state(; kw...) = Dict{String,Any}("type" => "state",
                                   (String(k) => v for (k, v) in kw)...)
_param(v) = Dict{String,Any}("type" => "parameter", "default" => v)

# 1-D reaction–diffusion. Exercises every seam at once: GATHER (the stencil), a
# boundary CONSTVEC, INVARIANT (`exp(-Ea/T)` hoisted), the literal-exponent `c[i]^2`,
# and — the arm a quick test misses — the DEGENERATE single-cell boundary kernels,
# whose whole template hoists to one scalar and so takes `_oop_scatter`'s scalar path.
function _rd(N)
    stencil = _o("+", _o("-", _ix("c", _o("-", "i", 1.0)), _o("*", 2.0, _ix("c", "i"))),
                 _ix("c", _o("+", "i", 1.0)))
    rate = _o("*", "k_rxn", _o("exp", _o("neg", _o("/", "Ea", "T"))))
    _doc("RD",
        Dict{String,Any}("c" => _state(shape = Any["n"]), "k_diff" => _param(0.1),
                         "k_rxn" => _param(0.3), "Ea" => _param(50.0),
                         "T" => _param(300.0)),
        Any[Dict{String,Any}("lhs" => _ao(_Dt(_ix("c", "i"))),
            "rhs" => _ao(_o("-", _o("*", "k_diff", stencil),
                            _o("*", rate, _o("^", _ix("c", "i"), 2.0)))))];
        index_sets = _nset(N))
end

# 0-D: a shared subexpression across two equations ⇒ a non-empty CSE prelude, so the
# scalar `_Node` walker and `_NK_CACHED` are traced, not just the array kernels.
function _zerod()
    shared = _o("*", _o("exp", _o("neg", _o("/", "Ea", "T"))), _o("*", "x", "y"))
    _doc("Z",
        Dict{String,Any}("x" => _state(default = 0.7), "y" => _state(default = 0.4),
                         "Ea" => _param(50.0), "T" => _param(300.0), "k" => _param(1.3)),
        Any[Dict{String,Any}("lhs" => _Dt("x"), "rhs" => _o("neg", _o("*", "k", shared))),
            Dict{String,Any}("lhs" => _Dt("y"), "rhs" => shared)])
end

# Time-varying, and parameter-free (`p === nothing`): `sin(2t)` is lane-invariant but
# NOT constant, so it is the model that catches a frozen `t`.
function _tv(N)
    body = _o("*", _o("ifelse", _o(">", _ix("c", "i"), 0.0), _o("sin", _o("*", 2.0, "t")),
                      _o("cos", "t")),
              _o("+", _ix("c", "i"), _o("sqrt", _o("abs", _ix("c", "i")))))
    _doc("TV", Dict{String,Any}("c" => _state(shape = Any["n"])),
        Any[Dict{String,Any}("lhs" => _ao(_Dt(_ix("c", "i"))), "rhs" => _ao(body))];
        index_sets = _nset(N))
end

function _interpdoc()
    table = Any[0.0, 1.0, 4.0, 9.0, 16.0]
    axis = Any[0.0, 1.0, 2.0, 3.0, 4.0]
    _doc("IT", Dict{String,Any}("y" => _state(default = 1.5), "k" => _param(2.0)),
        Any[Dict{String,Any}("lhs" => _Dt("y"),
            "rhs" => _o("*", "k", _fnop("interp.linear", _cst(table), _cst(axis), "y")))])
end

# `D(c[i]) = -k*c[i] + wind[i]`, where `wind` is a LIVE forcing buffer bound by
# reference through `param_arrays` — the discrete-cadence loader channel.
function _forced(N)
    body = _o("+", _o("*", -1.0, _o("*", "k", _ix("c", "i"))), _ix("wind", "i"))
    _doc("F", Dict{String,Any}("c" => _state(shape = Any["n"]), "k" => _param(0.5)),
        Any[Dict{String,Any}("lhs" => _ao(_Dt(_ix("c", "i"))), "rhs" => _ao(body))];
        index_sets = _nset(N))
end

_ip(f!, u, p, t) = (du = zero(u); f!(du, u, p, t); du)
_seed(n) = [0.6sin(0.7k) - 0.15 for k in 1:n]

# Parameters ride as a NamedTuple of traced scalars — which is already how
# `build_evaluator` hands them out, so no indexing and no re-plumbing. A
# parameter-free model carries SciMLBase's `nothing` sentinel instead.
_dev(p::NamedTuple) = NamedTuple{keys(p)}(map(RX.ConcreteRNumber, values(p)))
_dev(::Nothing) = nothing

# `sync = true` is NOT optional. Reactant calls are ASYNCHRONOUS: without it the
# returned array is a future, and both a timing and (if the host mutates its inputs
# underneath) a VALUE can be wrong.
const TOL = 1e-14   # see the header: XLA reassociates and fuses FMAs.

@testset "Reactant/XLA tracing of the out-of-place RHS" begin

    @testset "the loader-free RHS traces and agrees with f!" begin
        for (name, doc) in ["reaction-diffusion N=32" => _rd(32),
                            "0-D with a CSE prelude" => _zerod(),
                            "time-varying + ifelse/trig N=24" => _tv(24)]
            @testset "$name" begin
                fi, u0, p, _, _ = ESM.build_evaluator(doc)
                fo, _, _, _, _ = ESM.build_evaluator(doc; form = :oop)
                u = length(u0) == 2 ? [0.7, 0.4] : _seed(length(u0))

                ur, pr = RX.ConcreteRArray(u), _dev(p)
                xla = @compile sync = true fo(ur, pr, RX.ConcreteRNumber(0.0))
                for t in (0.0, 0.37, 1.9)
                    got = Array(xla(ur, pr, RX.ConcreteRNumber(t)))
                    @test isapprox(got, _ip(fi, u, p, t); rtol = TOL, atol = 1e-15)
                end
            end
        end
    end

    @testset "`t` is frozen unless it is passed traced" begin
        # A plain `Float64` `t` is a trace-time CONSTANT: the compiled program ignores
        # the `t` it is handed and keeps returning the value it was compiled at. It does
        # not error. Pin both halves, so the usage contract is a test and not a docstring.
        fi, u0, p, _, _ = ESM.build_evaluator(_tv(8))
        fo, _, _, _, _ = ESM.build_evaluator(_tv(8); form = :oop)
        u = _seed(8)
        ur = RX.ConcreteRArray(u)

        frozen = @compile sync = true fo(ur, nothing, 0.0)
        @test Array(frozen(ur, nothing, 1.3)) == Array(frozen(ur, nothing, 0.0))
        @test !isapprox(Array(frozen(ur, nothing, 1.3)), _ip(fi, u, p, 1.3); atol = 1e-8)

        live = @compile sync = true fo(ur, nothing, RX.ConcreteRNumber(0.0))
        for t in (0.0, 1.3)
            @test isapprox(Array(live(ur, nothing, RX.ConcreteRNumber(t))),
                           _ip(fi, u, p, t); rtol = TOL, atol = 1e-15)
        end
    end

    @testset "a full ODE solve driven by the compiled RHS" begin
        # SciML's RHS contract is unchanged (`f(u, p, t) -> du` on host arrays); the
        # closure marshals host → device → XLA → host per call. The trajectory is
        # compared against the SAME solver driven by the trusted in-place `f!`.
        N = 32
        fi, _, p, _, _ = ESM.build_evaluator(_rd(N))
        fo, _, _, _, _ = ESM.build_evaluator(_rd(N); form = :oop)
        u0 = _seed(N)
        pr = _dev(p)
        xla = @compile sync = true fo(RX.ConcreteRArray(u0), pr, RX.ConcreteRNumber(0.0))
        f_xla(u, _p, t) = Array(xla(RX.ConcreteRArray(u), pr, RX.ConcreteRNumber(t)))

        kw = (; reltol = 1e-10, abstol = 1e-10, saveat = 0.5)
        ref = solve(ODEProblem(fi, u0, (0.0, 2.0), p), Tsit5(); kw...)
        got = solve(ODEProblem(f_xla, u0, (0.0, 2.0), p), Tsit5(); kw...)

        @test got.retcode == ReturnCode.Success
        @test got.t == ref.t
        for k in eachindex(ref.t)
            # Loosened over the per-call tolerance on purpose: the two solves take the
            # same STEPS but not the same rounding, so the few-ulp RHS difference is
            # integrated. 1e-10 is still far below the solver's own tolerance.
            @test isapprox(got.u[k], ref.u[k]; rtol = 1e-10, atol = 1e-10)
        end
    end

    # ---- The gaps -----------------------------------------------------------

    @testset "interp.* does not trace (known gap)" begin
        # `_interp_*_core` is the SAME kernel the in-place path calls, and it takes an
        # `x::Real` query it then BRANCHES on (clamp, then a linear scan for the cell).
        # A `TracedRNumber` is not a `Real` and a traced comparison is not a `Bool`, so
        # this fails twice over — it is not a dispatch oversight but a control-flow one.
        # It fails LOUDLY, which is the one mercy here (contrast the forcing buffers
        # below, which do not).
        #
        # The fix is to re-express the kernel branch-free — clamp and cell-select folded
        # with `ifelse` — behind the `_oop_interp_linear` seam that already exists for
        # exactly this. That was PROTOTYPED and it works: on this model's table it
        # reproduces `f!` BIT FOR BIT at every in-cell and both clamped queries. It is
        # not shipped because of one unresolved divergence, and it is the kind that must
        # be resolved rather than tolerated: for a NaN query the core is specified to
        # propagate NaN (esm-spec §9.2 — a NaN bypasses both clamps and poisons the
        # blend), but the traced form returns the upper clamp instead, because XLA's
        # compare answered `NaN >= axis[end]` with TRUE. Pinning down that comparison's
        # semantics (and Reactant's `no_nan` compile option) is the remaining work.
        fo, _, p, _, _ = ESM.build_evaluator(_interpdoc(); form = :oop)
        ur, pr = RX.ConcreteRArray([1.5]), _dev(p)
        @test_throws Exception (@compile sync = true fo(ur, pr, RX.ConcreteRNumber(0.0)))
    end

    @testset "a live forcing buffer REFUSES to be XLA-compiled (audit J5)" begin
        # THE ONE THAT USED NOT TO FAIL LOUDLY. `wind` is bound by reference through
        # `param_arrays`; the RHS reads it through `_VK_PGATHER`, whose payload is the
        # aliased host `Vector{Float64}`. To the tracer that is a constant, so XLA baked
        # in the buffer's COMPILE-TIME contents. The discrete-cadence refresh callback
        # then wrote the buffer in place — exactly as `build_refresh_callback` does at
        # every cadence boundary — and the compiled program did not see one bit of it:
        # not an exception, not a NaN, but the SAME NUMBERS FOREVER, off by the full
        # magnitude of the forcing update.
        #
        # A silently wrong answer is worse than no answer, so the out-of-place closure
        # now REFUSES the trace when a live forcing buffer is bound.
        N = 8
        wind = fill(1.0, N)
        fi, _, p, _, _ = ESM.build_evaluator(_forced(N); param_arrays = Dict("wind" => wind))
        fo, _, _, _, _ = ESM.build_evaluator(_forced(N); form = :oop,
                                             param_arrays = Dict("wind" => wind))
        u = _seed(N)
        ur, pr, tr = RX.ConcreteRArray(u), _dev(p), RX.ConcreteRNumber(0.0)

        # The refusal fires during the TRACE, so `@compile` itself throws.
        @test_throws Exception (@compile sync = true fo(ur, pr, tr))

        # And it says WHY, and how to proceed.
        err = try
            @compile sync = true fo(ur, pr, tr)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("param_arrays", sprint(showerror, err))
        @test occursin("const_arrays", sprint(showerror, err))

        # The refusal is scoped to the TRACER, not to the model: the interpreted
        # evaluators over the very same `param_arrays` build are correct and DO track
        # an in-place refresh. That is why the refusal cannot live at build time.
        before = _ip(fi, u, p, 0.0)
        wind .= 100.0                       # the in-place refresh, verbatim
        fresh = _ip(fi, u, p, 0.0)          # `f!` sees it; that is the whole design
        @test isapprox(fo(u, p, 0.0), fresh; rtol = TOL)   # ...and so does the oop one
        @test maximum(abs, fresh .- before) ≈ 99.0 rtol = 1e-12   # it really did change
    end

    @testset "a model with NO live forcing still compiles (J5 refusal is scoped)" begin
        # The guard must not cost the ordinary XLA path anything: a model that binds no
        # `param_arrays` traces and compiles exactly as before.
        N = 8
        fo, _, p, _, _ = ESM.build_evaluator(_forced(N); form = :oop,
                                             const_arrays = Dict("wind" => fill(1.0, N)))
        fi, _, _, _, _ = ESM.build_evaluator(_forced(N);
                                             const_arrays = Dict("wind" => fill(1.0, N)))
        u = _seed(N)
        ur, pr, tr = RX.ConcreteRArray(u), _dev(p), RX.ConcreteRNumber(0.0)
        xla = @compile sync = true fo(ur, pr, tr)
        @test isapprox(Array(xla(ur, pr, tr)), _ip(fi, u, p, 0.0); rtol = TOL, atol = 1e-15)
    end
end
