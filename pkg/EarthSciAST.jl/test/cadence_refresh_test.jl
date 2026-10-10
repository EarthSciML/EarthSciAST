# Every kind of refresh reaches the cadence-memoized values (cadence_stamp.jl).
#
# A native build skips work whose inputs have not moved: the const tiers (the
# scalar prelude's const slots, the const-cadence materialized observeds) while
# `p` stands still, the time tiers (the prelude's time slots, the time-cadence
# materialized observeds) while `(p, t, the build's forcing epoch)` stand still.
# Each refresh that can move those inputs must be seen on the very next call,
# bit for bit as `compiler=:interpreter` (which memoizes nothing) sees it:
#   * a new `t`, a new `p` (what `remake(prob; p = …)` hands the RHS);
#   * a live buffer written through `_write_forcing!` (the refresh callback);
#   * a direct in-place write followed by `notify_forcing_refresh!()` or
#     `notify_forcing_refresh!(buffer)`;
#   * a direct in-place write followed by a call at a `t` not yet evaluated.
# Both value types are checked: Float64 calls and the ForwardDiff Jacobian's
# dual-number calls, which run on their own buffers and stamps. The child
# process at the bottom repeats the sequence with the observed fills and the
# state kernels threaded.
#
# The boundary of that contract is pinned too: a direct write at a `t` already
# evaluated, with no notice, is not seen (the memo is what makes a Jacobian's
# columns cheap); `notify_forcing_refresh!` documents this.
using Test
using EarthSciAST
using ForwardDiff
using DiffEqCallbacks            # loads EarthSciASTDataRefreshExt
using SciMLBase
import OrdinaryDiffEqRosenbrock as ODERos
include("testutils.jl")
const ESM = EarthSciAST

# A discrete provider: one field per refresh time.
struct _CRProvider
    fields::Dict{Float64,Dict{String,Vector{Float64}}}
end
ESM.provider_refresh_times(p::_CRProvider) = sort!(collect(keys(p.fields)))
ESM.provider_sample(p::_CRProvider, t::Real) = p.fields[Float64(t)]

#   c[i] = k·sin(i)                         const cadence (p only)
#   w[i] = t·F[i] + c[i]                    time cadence (t, a live buffer)
#   D(u[i]) = w[i]·u[i] + F[i] + c[i]·0.5
#   D(z)    = sin(F[2]·k) + cos(F[2]·k)     a scalar prelude time slot
function _cr_model(N)
    isets = Dict("x" => ESM.IndexSet("interval"; size = N))
    agg(body) = ESM.OpExpr("faq", ESM.ASTExpr[]; output_idx = Any["i"],
                           ranges = Dict("i" => ESM.IndexSetRef("x")), expr_body = body)
    vars = Dict(
        "u" => ESM.ModelVariable(ESM.UnknownVariable; shape = ["x"]),
        "z" => ESM.ModelVariable(ESM.UnknownVariable),
        "c" => ESM.ModelVariable(ESM.UnknownVariable; shape = ["x"]),
        "w" => ESM.ModelVariable(ESM.UnknownVariable; shape = ["x"]),
        "k" => ESM.ModelVariable(ESM.ParameterVariable; default = 0.25))
    fk() = _op("*", _idx("F", _i(2)), _v("k"))
    eqs = [
        ESM.Equation(_v("c"), agg(_op("*", _v("k"), _op("sin", _v("i"))))),
        ESM.Equation(_v("w"), agg(_op("+", _op("*", _v("t"), _idx("F", _v("i"))),
                                       _idx("c", _v("i"))))),
        ESM.Equation(agg(_Didx("u", _v("i"))),
                     agg(_op("+", _op("*", _idx("w", _v("i")), _idx("u", _v("i"))),
                             _idx("F", _v("i")),
                             _op("*", _idx("c", _v("i")), _n(0.5))))),
        ESM.Equation(_D("z"), _op("+", _op("sin", fk()), _op("cos", fk()))),
    ]
    ics = merge(Dict("u[$j]" => 0.1j for j in 1:N), Dict("z" => 0.3))
    return ESM.Model(vars, eqs), isets, ics
end

function _cr_refresh_sequence(N)
    model, isets, ics = _cr_model(N)
    F = [1.0 + 0.5j for j in 1:N]
    nat = ESM._build_evaluator_impl(model; index_sets = isets, initial_conditions = ics,
                                    param_arrays = Dict("F" => F))
    ref = ESM._build_evaluator_impl(model; index_sets = isets, initial_conditions = ics,
                                    param_arrays = Dict("F" => F), compiler = :interpreter)
    # Each memoized tier this file is about is really there.
    @test nat[6].n_mat_const_levels == 1
    @test nat[6].n_mat_time_levels == 1
    @test nat[6].n_time_slots >= 1
    fn!, u0, p = nat[1], nat[2], nat[3]
    fr! = ref[1]
    du, dr = similar(u0), similar(u0)
    jac(f!, pp, t) = ForwardDiff.jacobian((d, uu) -> f!(d, uu, pp, t), similar(u0), u0)
    function agree(pp, t)
        fn!(du, u0, pp, t)
        fr!(dr, u0, pp, t)
        return du == dr && jac(fn!, pp, t) == jac(fr!, pp, t)
    end
    p2 = typeof(p)(map(x -> 3.0 * x, values(p)))

    @test agree(p, 0.0)
    @test agree(p, 0.0)                                    # a memo hit
    @test agree(p, 1.5)                                    # new t
    ESM._write_forcing!(F, "F", Dict("F" => F .* 2.0))
    @test agree(p, 1.5)                                    # the refresh callback's write
    F .+= 1.0
    ESM.notify_forcing_refresh!()
    @test agree(p, 1.5)                                    # direct write + global notice
    F .*= 0.5
    ESM.notify_forcing_refresh!(F)
    @test agree(p, 1.5)                                    # direct write + buffer notice
    @test agree(p2, 1.5)                                   # new p (remake)
    @test agree(p, 1.5)                                    # and back
    F .-= 0.25
    @test agree(p, 2.5)                                    # direct write, then a new t
    @test agree(p, 1.5)                                    # a rejected step's earlier t

    # The boundary: an unannounced write at an evaluated `t` leaves the memo
    # standing until it is announced. The Jacobian reads `F` only through the
    # memoized `w` (the state equation's own `F[i]` is read live every call).
    jbefore = jac(fn!, p, 1.5)
    F .+= 7.0
    fn!(du, u0, p, 1.5)
    @test jac(fn!, p, 1.5) == jbefore
    ESM.notify_forcing_refresh!(F)
    @test agree(p, 1.5)
    @test jac(fn!, p, 1.5) != jbefore
    return nothing
end

if get(ENV, "ESS_CR_CHILD", "") == "1"
    @testset "cadence refresh kinds (child, $(Threads.nthreads()) threads)" begin
        @test Threads.nthreads() >= 2
        ESM._reset_thread_tally!()
        _cr_refresh_sequence(64)
        @test get(ESM._THREAD_TALLY, :cg_threaded, 0) >= 1
    end
else
    @testset "cadence refresh kinds" begin
        @testset "serial" begin
            withenv("ESS_THREADS_MIN_CELLS" => string(typemax(Int))) do
                _cr_refresh_sequence(16)
            end
        end

        @testset "a second build of the same buffer is not disturbed" begin
            # A buffer notice reaches every build that reads the buffer, and
            # only those: a build over another buffer keeps its memo.
            model, isets, ics = _cr_model(8)
            F = [1.0 + 0.5j for j in 1:8]
            G = copy(F)
            bF = ESM._build_evaluator_impl(model; index_sets = isets,
                                           initial_conditions = ics,
                                           param_arrays = Dict("F" => F))
            bF2 = ESM._build_evaluator_impl(model; index_sets = isets,
                                            initial_conditions = ics,
                                            param_arrays = Dict("F" => F))
            bG = ESM._build_evaluator_impl(model; index_sets = isets,
                                           initial_conditions = ics,
                                           param_arrays = Dict("F" => G))
            # The Jacobian reads the buffer only through the memoized `w`.
            call(b) = ForwardDiff.jacobian((d, uu) -> b[1](d, uu, b[3], 0.5),
                                           similar(b[2]), b[2])
            d0 = call(bF)
            @test call(bF2) == d0 && call(bG) == d0
            F .*= 2.0
            G .*= 2.0
            ESM.notify_forcing_refresh!(F)
            @test call(bF) != d0
            @test call(bF2) == call(bF)
            @test call(bG) == d0                     # G was not announced
        end

        @testset "a stiff solve across refreshes ≡ the interpreter" begin
            # The solver path: Rosenbrock23 evaluates its Jacobian (dual
            # numbers) at the step's `t`, and a refresh fires AT its tstop, so
            # the calls after it are at a `t` the time tiers have stamped. The
            # refresh callback's write and a hand-written callback that writes
            # the buffer and notifies must both give the interpreter's solution
            # bit for bit.
            model, isets, ics = _cr_model(8)
            fields = Dict(1.0 => Dict("F" => fill(-0.5, 8)),
                          2.0 => Dict("F" => collect(0.25:0.25:2.0)))
            function solve_with(compiler, how)
                F = [0.2j for j in 1:8]
                f!, u0, p = ESM._build_evaluator_impl(model; index_sets = isets,
                    initial_conditions = ics, param_arrays = Dict("F" => F),
                    compiler = compiler)
                cb, tstops = if how === :provider
                    ESM.build_refresh_callback(;
                        providers = Dict("F" => _CRProvider(fields)),
                        buffers = ESM.RefreshBuffers(Dict("F" => F)))
                else
                    DiffEqCallbacks.PresetTimeCallback([1.0, 2.0], integ -> begin
                        F .= fields[integ.t]["F"]
                        ESM.notify_forcing_refresh!(F)
                    end), [1.0, 2.0]
                end
                prob = ODERos.ODEProblem(f!, u0, (0.0, 3.0), p)
                sol = ODERos.solve(prob, ODERos.Rosenbrock23(); callback = cb,
                                   tstops = tstops, reltol = 1e-8, abstol = 1e-10)
                return sol.t, sol.u
            end
            for how in (:provider, :hand)
                tn, un = solve_with(:native, how)
                ti, ui = solve_with(:interpreter, how)
                @test tn == ti
                @test un == ui
            end
        end

        @testset "threaded subprocess (julia -t 2)" begin
            env = copy(ENV)
            for k in collect(keys(env))
                startswith(k, "ESS_") && delete!(env, k)
            end
            env["ESS_CR_CHILD"] = "1"
            env["ESS_THREADS_MIN_CELLS"] = "8"
            env["JULIA_PROJECT"] = Base.active_project()
            cmd = setenv(`$(Base.julia_cmd()) --startup-file=no -t 2 $(@__FILE__)`, env)
            proc = run(pipeline(ignorestatus(cmd); stdout = stdout, stderr = stderr))
            @test success(proc)
        end
    end
end
