using EarthSciAST, ForwardDiff, Enzyme
const ESM = EarthSciAST
Enzyme.API.strictAliasing!(false)
include("models.jl")
flush(stdout)

fo, u0, p, _, _ = ESM.build_evaluator(_zerod(); form = :oop)
u = [0.7, 0.4]; t = 0.37
loss = uu -> sum(abs2, fo(uu, p, t))
g_fd = ForwardDiff.gradient(loss, u)
println("fd = ", g_fd); flush(stdout)

du = zero(u)
t0 = time()
try
    Enzyme.autodiff(Enzyme.Reverse, Enzyme.Const(loss), Enzyme.Active,
                    Enzyme.Duplicated(u, du))
    println("OK after $(round(time()-t0, digits=1)) s")
    println("enzyme = ", du)
    println("maxdiff = ", maximum(abs.(du .- g_fd)))
catch e
    println("FAIL after $(round(time()-t0, digits=1)) s: ", typeof(e))
    io = IOBuffer(); showerror(io, e); println(first(String(take!(io)), 1500))
end
flush(stdout)
