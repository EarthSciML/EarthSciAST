using Pkg
Pkg.activate(joinpath(@__DIR__, "env"))
Pkg.develop(path="/projects/illinois/eng/cee/ctessum/ctessum/code/EarthSciAST/.prfix/juliaudit/pkg/EarthSciAST.jl")
Pkg.add(["ForwardDiff","JSON3","Test"])
Pkg.precompile()
println("ENV_BUILD_DONE")
