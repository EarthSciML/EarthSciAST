# Companion to repro.jl: does the IN-PLACE `f!` (the default emitter, which since
# codegen_kernel.jl emits its array kernels as Julia source at build time) survive
# Enzyme reverse mode WITHOUT `strictAliasing!(false)`?
#
#   julia --project=. repro_iip.jl strict|relaxed [nocodegen]

using EarthSciAST, ForwardDiff, Enzyme
const ESM = EarthSciAST

mode = length(ARGS) >= 1 ? ARGS[1] : "strict"
mode == "relaxed" && Enzyme.API.strictAliasing!(false)
if length(ARGS) >= 2 && ARGS[2] == "nocodegen"
    ENV["ESS_CODEGEN_DISABLE"] = "1"
end
@info "mode=$mode codegen_disabled=$(get(ENV,"ESS_CODEGEN_DISABLE",""))" v=pkgversion(Enzyme)

include("models.jl")

function run_case(name, doc, n)
    println("\n", "="^72, "\n", name, "\n", "="^72)
    fi, u0, p, _, _ = ESM.build_evaluator(doc)
    u = n == 2 ? [0.7, 0.4] : _seed(n)
    t = 0.37
    loss = function (uu)
        du = zero(uu)
        fi(du, uu, p, t)
        sum(abs2, du)
    end
    g_fd = ForwardDiff.gradient(loss, u)
    println("value            = ", loss(u))
    println("ForwardDiff grad = ", g_fd)
    du = zero(u)
    try
        Enzyme.autodiff(Enzyme.set_runtime_activity(Enzyme.Reverse),
                        Enzyme.Const(loss), Enzyme.Active, Enzyme.Duplicated(u, du))
        rel = maximum(abs.(du .- g_fd)) / max(1.0, maximum(abs.(g_fd)))
        println("REVERSE OK; max abs diff vs ForwardDiff = ", rel)
        return :ok
    catch e
        io = IOBuffer(); showerror(io, e); s = String(take!(io))
        println("REVERSE FAILED: ", typeof(e))
        println(first(s, 3000))
        return :fail
    end
end

r1 = run_case("0-D with CSE prelude (f!)", _zerod(), 2)
r2 = run_case("reaction-diffusion N=16 (f!)", _rd(16), 16)
println("\nSUMMARY (in-place, mode=$mode): 0-D => $r1 ; RD => $r2")
