#!/usr/bin/env julia
# B3 bench: the time-cadence tier's effect on an FD-Jacobian fill over a
# FastJX-like box model — many `interp.linear` observeds depending only on `t`
# (a shared solar chain + a live met gather), feeding a small stiff ODE. This is
# the box-model pattern from treewalk-perf-plan.md: the stiff solver's
# finite-difference Jacobian makes N+1 RHS calls at the SAME `t`, so with the
# tier every state-blind interpolation chain is evaluated once per fill instead
# of N+1 times.
#
# Usage (from the repo root):
#   julia --project=pkg/EarthSciAST.jl scripts/bench/bench_tcadence.jl [K] [M]
#
#   K = number of interp.linear photolysis bands (default 100)
#   M = number of chemical states               (default 15)
#
# Prints, tier ON vs OFF (ESS_TCADENCE_DISABLE=1):
#   * warm single-RHS time (moving t — the non-Jacobian path, should be ~equal)
#   * FD Jacobian fill time (N+1 same-t calls) + the ON/OFF ratio
#   * ForwardDiff.jacobian time + ratio
#   * a bit-exactness cross-check of du and the FD fill between the two builds

const BENCH_DIR = @__DIR__
import Pkg
if !isfile(joinpath(BENCH_DIR, "Manifest.toml"))
    prev = Base.active_project()
    Pkg.activate(BENCH_DIR; io = devnull)
    Pkg.instantiate()
    Pkg.activate(prev; io = devnull)
end
BENCH_DIR in LOAD_PATH || push!(LOAD_PATH, BENCH_DIR)

using EarthSciAST
using BenchmarkTools, ForwardDiff, Printf
const EA = EarthSciAST

_bn(x) = NumExpr(Float64(x))
_bi(x) = EA.IntExpr(Int64(x))
_bv(n) = VarExpr(n)
_bop(op, args...; kw...) = OpExpr(op, EA.ASTExpr[args...]; kw...)
_bD(v) = _bop("D", _bv(v); wrt="t")
_bidx(a, s) = _bop("index", _bv(a), s)
_bfn(name, args...) = OpExpr("fn", EA.ASTExpr[args...]; name=String(name))
_bconst(v) = OpExpr("const", EA.ASTExpr[]; value=v)

_axis() = Float64[0.0, 0.25, 0.5, 0.75, 1.0]
_table(i) = Float64[0.1i, 0.22i, 0.35i, 0.51i, 0.8i] ./ 100.0

# The FastJX-like box: K bands over one solar chain, a met gather, M states.
function fastjx_box(K::Int, M::Int)
    vars = Dict{String,ModelVariable}(
        "w" => ModelVariable(ParameterVariable; default=0.7),
        "scale" => ModelVariable(ParameterVariable; default=1.5),
        "sza" => ModelVariable(ObservedVariable),
        "met" => ModelVariable(ObservedVariable),
    )
    eqs = EA.Equation[
        EA.Equation(_bv("sza"),
            _bop("+", _bn(0.5), _bop("*", _bn(0.4),
                _bop("sin", _bop("*", _bv("w"), _bv("t")))))),
        EA.Equation(_bv("met"), _bop("*", _bidx("F", _bi(1)), _bv("scale"))),
    ]
    for i in 1:K
        vars["band$i"] = ModelVariable(ObservedVariable)
        push!(eqs, EA.Equation(_bv("band$i"),
            _bfn("interp.linear", _bconst(_table(i)), _bconst(_axis()), _bv("sza"))))
    end
    for j in 1:M
        vars["x$j"] = ModelVariable(StateVariable; default=1.0 + 0.1j)
        # Each state consumes a strided subset of bands (FastJX's band→species map).
        terms = EA.ASTExpr[_bop("*", _bn(0.1 + 0.01i + 0.02j),
                                _bop("*", _bv("band$i"), _bv("met")))
                           for i in j:M:K]
        prod = isempty(terms) ? _bn(0.0) :
               (length(terms) == 1 ? terms[1] : OpExpr("+", terms))
        push!(eqs, EA.Equation(_bD("x$j"),
            _bop("-", prod,
                _bop("*", _bn(0.3 + 0.05j), _bop("*", _bv("met"), _bv("x$j"))))))
    end
    return EA.Model(vars, eqs)
end

# The FD-Jacobian fill: the N+1 same-t RHS calls FiniteDiff makes (forward mode).
function fd_fill!(J, f!, du0, du, u, p, t)
    f!(du0, u, p, t)
    N = length(u)
    @inbounds for col in 1:N
        h = 1e-8 * max(1.0, abs(u[col]))
        tmp = u[col]
        u[col] = tmp + h
        f!(du, u, p, t)
        u[col] = tmp
        for r in 1:N
            J[r, col] = (du[r] - du0[r]) / h
        end
    end
    return J
end

function bench_one(K, M; disable::Bool)
    buf = [2.0]
    build() = EA._build_evaluator_impl(fastjx_box(K, M); param_arrays=Dict("F" => buf))
    f!, u0, p, _ts, _vm, diag = disable ?
        withenv(build, "ESS_TCADENCE_DISABLE" => "1") : build()
    N = length(u0)
    du = similar(u0); du0 = similar(u0); J = zeros(N, N)
    u = copy(u0)
    t = 0.35
    # warm RHS, moving t (no memo reuse possible): the non-Jacobian path
    f!(du, u, p, t)
    rhs_moving = @belapsed (global _tt += 1e-6; $f!($du, $u, $p, _tt)) setup=(global _tt = 0.35) seconds = 2
    # FD fill at fixed t
    fd_fill!(J, f!, du0, du, u, p, t)
    fd = @belapsed fd_fill!($J, $f!, $du0, $du, $u, $p, tt) setup=(tt = 0.35 + 1e-3*rand()) seconds = 3
    # ForwardDiff jacobian at fixed t
    g! = (d, uu) -> f!(d, uu, p, t)
    cfg = ForwardDiff.JacobianConfig(g!, du, u)
    ForwardDiff.jacobian!(J, g!, du, u, cfg)
    ad = @belapsed ForwardDiff.jacobian!($J, $g!, $du, $u, $cfg) seconds = 3
    return (; diag, f!, u0, p, N, rhs_moving, fd, ad)
end

function main()
    K = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 100
    M = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 15
    println("FastJX-like box: K=$K interp.linear bands, M=$M states\n")
    on = bench_one(K, M; disable=false)
    off = bench_one(K, M; disable=true)
    println("tier ON : n_const=$(on.diag.n_const_slots) n_time=$(on.diag.n_time_slots) n_dyn=$(on.diag.n_dynamic_slots)")
    println("tier OFF: n_const=$(off.diag.n_const_slots) n_time=$(off.diag.n_time_slots) n_dyn=$(off.diag.n_dynamic_slots)")
    println()
    @printf("%-34s %12s %12s %8s\n", "metric", "tier ON", "tier OFF", "OFF/ON")
    @printf("%-34s %10.2f µs %10.2f µs %7.2fx\n", "warm RHS, moving t",
            1e6 * on.rhs_moving, 1e6 * off.rhs_moving, off.rhs_moving / on.rhs_moving)
    @printf("%-34s %10.2f µs %10.2f µs %7.2fx\n", "FD Jacobian fill (N+1 same-t)",
            1e6 * on.fd, 1e6 * off.fd, off.fd / on.fd)
    @printf("%-34s %10.2f µs %10.2f µs %7.2fx\n", "ForwardDiff.jacobian (fixed t)",
            1e6 * on.ad, 1e6 * off.ad, off.ad / on.ad)

    # bit-exactness cross-check between the two builds
    N = on.N
    duA = zeros(N); duB = zeros(N)
    JA = zeros(N, N); JB = zeros(N, N)
    tmpA = zeros(N); tmpB = zeros(N)
    u = copy(on.u0)
    ok = true
    for t in (0.0, 0.35, 0.35, 1.0)
        on.f!(duA, u, on.p, t); off.f!(duB, u, off.p, t)
        ok &= duA == duB
        fd_fill!(JA, on.f!, tmpA, duA, u, on.p, t)
        fd_fill!(JB, off.f!, tmpB, duB, u, off.p, t)
        ok &= JA == JB
    end
    println("\nbit-exact ON≡OFF over du + FD fills: ", ok ? "PASS" : "FAIL")
    ok || exit(1)
end

main()
