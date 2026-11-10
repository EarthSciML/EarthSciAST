# The ModelingToolkit / Catalyst suite: every test of EarthSciASTMTKExt,
# EarthSciASTCatalystExt, `compiler = :mtk`, and the `run_esm_tests` runs that
# compile through ModelingToolkit.
#
# WHY IT IS A SEPARATE SUITE. These tests used to run inside the package's own
# `Pkg.test()` (test/runtests.jl), which meant ModelingToolkit and Catalyst sat
# in the `[targets] test` list of pkg/EarthSciAST.jl/Project.toml. That cost the
# regular Julia CI job minutes of MTK builds and the precompile of both
# extensions on every run, and it forced the ModelingToolkitBase and
# SymbolicUtils holdback caps onto the whole regular test environment. Now the
# regular suite never loads ModelingToolkit or Catalyst, and this suite runs in
# its own environment (test/mtk/Project.toml) in the ModelingToolkit CI workflow
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
using EarthSciAST
using JSON3

include("../testutils.jl")  # shared prelude: repo root, AST builders, _normj, _require_fixture

@testset verbose = true "EarthSciAST.jl ModelingToolkit / Catalyst Tests" begin

    # ---- ModelingToolkit extension (ext/EarthSciASTMTKExt.jl) ----
    include("real_mtk_integration_test.jl")
    include("mtk_metadata_test.jl")
    include("simulate_e2e_test.jl")
    include("tests_blocks_execution_test.jl")
    # The ModelingToolkit export honours a continuous event's `affect_neg` and
    # `root_find` (esm-spec §5.2, issue #356).
    include("mtk_continuous_event_options_test.jl")
    # `esm_problem(...; compiler = :mtk)` — the specialty compiler that RUNS the
    # three constructs CONFORMANCE_SPEC §5.39 has every other evaluator refuse,
    # and refuses by name the document content it cannot express (API_SPEC §5.8).
    include("compiler_mtk_test.jl")

    # ---- The inline-test runner that compiles through ModelingToolkit
    #      (src/run_tests.jl) ----
    include("run_esm_tests_mtk_test.jl")
    include("container_in_document_test.jl")

    # ---- Array ops, broadcast and const arrays through the ModelingToolkit
    #      lowering ----
    include("array_ops_mtk_test.jl")
    include("broadcast_alignment_mtk_test.jl")     # the exporter's `broadcast` `fn` vocabulary
    include("const_array_index_mtk_test.jl")       # #286: a bare const array as an index base
    include("tree_walk_mtk_parity_test.jl")        # tree-walk right-hand side ≡ MTK codegen

    # ---- Catalyst extension (ext/EarthSciASTCatalystExt.jl) + MTK export ----
    include("catalyst_extension_test.jl")
    include("mtk_export_test.jl")
end
