# The Reactant suite: every test of the direct StableHLO emitter
# (EarthSciASTReactantExt) and of `compiler = :xla`.
#
# WHY IT IS A SEPARATE SUITE. Reactant bundles an XLA runtime. Keeping it out of
# the package's own `Pkg.test()` keeps resolving, downloading and precompiling it
# out of the regular test environment. This suite runs in its own environment
# (test/reactant/Project.toml) in the `julia-xla` job of
# .github/workflows/xla-backends.yml.
#
# RUNNING IT. Manifest.toml is gitignored repo-wide, so point the environment at
# this checkout first (from the repository root):
#
#     julia --project=pkg/EarthSciAST.jl/test/reactant -e '
#         using Pkg; Pkg.develop(path = "pkg/EarthSciAST.jl"); Pkg.instantiate()'
#     julia --project=pkg/EarthSciAST.jl/test/reactant pkg/EarthSciAST.jl/test/reactant/runtests.jl
#
# Every file here also runs standalone in that environment. The two invariants
# test/test_file_prelude_test.jl pins for the regular suite hold here too, and
# are checked from there: every file carries the prelude it uses, and this
# driver names every `*_test.jl` in this directory.
using Test

# Each file runs in a module of its own, as in test/runtests.jl.
const FILES = [
    "reactant_locate_test.jl",
    "reactant_direct_emit_test.jl",
    "reactant_direct_closed_test.jl",
    "reactant_direct_sharding_test.jl",
    "compiler_xla_test.jl",
    "operator_fragment_test.jl",
]

function _run_file(path::String)
    name = Symbol("TestReactant_", replace(splitext(basename(path))[1], r"[^A-Za-z0-9_]" => "_"))
    m = Core.eval(Main, Expr(:module, true, name, Expr(:block)))
    return Base.include(m, path)
end

@testset verbose = true "EarthSciAST.jl Reactant Tests" begin
    for f in FILES
        @testset "$f" begin
            _run_file(joinpath(@__DIR__, f))
        end
    end
end
