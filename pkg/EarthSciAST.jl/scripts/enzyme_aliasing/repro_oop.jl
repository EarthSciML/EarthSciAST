# Reproducer: does Enzyme reverse mode on the `:oop` RHS need
# `Enzyme.API.strictAliasing!(false)`?
#
# Run as:   julia --project=... repro_oop.jl strict   (flag NOT set — the default)
#           julia --project=... repro_oop.jl relaxed  (strictAliasing!(false))
#
# One process per mode on purpose: the flag is a process-global that feeds Enzyme's
# type analysis at COMPILE time, and Enzyme caches compiled adjoints, so toggling it
# mid-process would not give a clean answer.

using EarthSciAST
using ForwardDiff
using Enzyme

const ESM = EarthSciAST

mode = length(ARGS) >= 1 ? ARGS[1] : "strict"
if mode == "relaxed"
    Enzyme.API.strictAliasing!(false)
end
@info "mode = $mode" enzyme_version=pkgversion(Enzyme)

include("models.jl")

# ---- The experiment ---------------------------------------------------------
function run_case(name, doc, n)
    println("\n", "="^72, "\n", name, "\n", "="^72)
    fo, u0, p, _, _ = ESM.build_evaluator(doc; form = :oop)
    u = n == 2 ? [0.7, 0.4] : _seed(n)
    t = 0.37

    loss = uu -> sum(abs2, fo(uu, p, t))
    g_fd = ForwardDiff.gradient(loss, u)
    println("value            = ", loss(u))
    println("ForwardDiff grad = ", g_fd)

    du = zero(u)
    try
        Enzyme.autodiff(Enzyme.Reverse, Enzyme.Const(loss), Enzyme.Active,
                        Enzyme.Duplicated(u, du))
        println("Enzyme grad      = ", du)
        rel = maximum(abs.(du .- g_fd)) / max(1.0, maximum(abs.(g_fd)))
        println("REVERSE OK; max rel diff vs ForwardDiff = ", rel)
        return (:ok, rel)
    catch e
        println("REVERSE FAILED: ", typeof(e))
        io = IOBuffer()
        showerror(io, e)
        s = String(take!(io))
        println(first(s, 6000))
        return (:fail, typeof(e))
    end
end

results = Any[]
push!(results, ("0-D with CSE prelude", run_case("0-D with CSE prelude", _zerod(), 2)))
push!(results, ("reaction-diffusion N=16", run_case("reaction-diffusion N=16", _rd(16), 16)))

println("\n\nSUMMARY (mode = $mode)")
for (n, r) in results
    println("  ", rpad(n, 32), " => ", r)
end
