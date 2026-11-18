# The ModelingToolkit / Catalyst suite: every test of EarthSciASTMTKExt,
# EarthSciASTCatalystExt, `compiler = :mtk`, and the `run_esm_tests` runs that
# compile through ModelingToolkit.
#
# WHY IT IS A SEPARATE SUITE. Keeping ModelingToolkit and Catalyst out of the
# package's own `Pkg.test()` keeps their builds, the precompile of both
# extensions and the ModelingToolkitBase / SymbolicUtils holdback caps out of
# the regular test environment. This suite runs in its own environment
# (test/mtk/Project.toml) in the ModelingToolkit CI workflow
# (.github/workflows/mtk-compiler.yml).
#
# RUNNING IT. Manifest.toml is gitignored repo-wide, so point the environment at
# this checkout first (from the repository root):
#
#     julia --project=pkg/EarthSciAST.jl/test/mtk -e '
#         using Pkg; Pkg.develop(path = "pkg/EarthSciAST.jl"); Pkg.instantiate()'
#     julia --project=pkg/EarthSciAST.jl/test/mtk pkg/EarthSciAST.jl/test/mtk/runtests.jl
#
# Every file here also runs standalone in that environment, e.g.
#     julia --project=pkg/EarthSciAST.jl/test/mtk pkg/EarthSciAST.jl/test/mtk/mtk_export_test.jl
#
# The two invariants test/test_file_prelude_test.jl pins for the regular suite
# hold here too, and are checked from there: every file carries the prelude it
# uses, and this driver includes every `*_test.jl` in this directory.
using Test

# Each file runs in a module of its own, as in test/runtests.jl.
const FILES = [
    "real_mtk_integration_test.jl",
    "mtk_metadata_test.jl",
    "simulate_e2e_test.jl",
    "tests_blocks_execution_test.jl",
    "mtk_continuous_event_options_test.jl",
    "compiler_mtk_test.jl",
    "run_esm_tests_mtk_test.jl",
    "container_in_document_test.jl",
    "array_ops_mtk_test.jl",
    "broadcast_alignment_mtk_test.jl",
    "const_array_index_mtk_test.jl",
    "tree_walk_mtk_parity_test.jl",
    "catalyst_extension_test.jl",
    "mtk_export_test.jl",
]

function _run_file(path::String)
    name = Symbol("TestMTK_", replace(splitext(basename(path))[1], r"[^A-Za-z0-9_]" => "_"))
    m = Core.eval(Main, Expr(:module, true, name, Expr(:block)))
    return Base.include(m, path)
end

@testset verbose = true "EarthSciAST.jl ModelingToolkit / Catalyst Tests" begin
    for f in FILES
        @testset "$f" begin
            _run_file(joinpath(@__DIR__, f))
        end
    end
end
