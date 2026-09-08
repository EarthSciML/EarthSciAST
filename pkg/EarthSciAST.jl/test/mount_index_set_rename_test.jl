# Mount-edge index-set renaming (esm-spec §4.7 "Mount-edge index-set
# renaming") — the fix for EarthSciML/EarthSciAST#198 item 4.
#
# `index_sets` is a DOCUMENT-scoped registry, so a document that mounts a
# 59-layer atmospheric column and a 4-layer soil column — both of which spell
# their axis `lev`, because both come from the same one-dimensional column
# family at different lengths — hits the §4.7 deep-equal-or-error merge and
# fails with
# `subsystem_index_set_conflict`. That scoping is load-bearing (`shape`,
# `{"from"}`, `from_faq`, §11.2 dimensionality, §9.6.1 `where` constraints and
# §2.1 `coordinates` all resolve against the one registry), so the fix is not to
# re-scope it but to let the ASSEMBLER say "this mount's `lev` is not that
# mount's `lev`" at the edge.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: ExpressionTemplateError, serialize_esm_file

include("testutils.jl")  # TESTUTILS_REPO_ROOT

@testset "Mount-edge index-set renaming (esm-spec §4.7)" begin
    repo_root = TESTUTILS_REPO_ROOT
    valid(name) = joinpath(repo_root, "tests", "valid", name)

    @testset "two columns naming one axis coexist under a mount rename" begin
        file = EarthSciAST.load_path(valid("mount_rename_two_columns.esm"))
        @test file.index_sets["lev"].size == 59        # the un-renamed mount
        @test file.index_sets["soil_lev"].size == 4    # the renamed mount
    end

    @testset "the rename rewrites the mounted component transitively" begin
        # A `shape` list that still said `lev` would resolve against the
        # 59-layer axis and allocate 59 soil layers.
        file = EarthSciAST.load_path(valid("mount_rename_two_columns.esm"))
        host = file.models["Host"]
        soil = host.subsystems["Soil"]
        @test soil.variables["Tsoil"].shape == ["soil_lev"]
        @test host.subsystems["Atm"].variables["T"].shape == ["lev"]  # untouched
        # The aggregate's `{from}` range follows the axis too.
        emitted = serialize_esm_file(file)
        soil_json = JSON3.write(emitted["models"]["Host"]["subsystems"]["Soil"])
        @test occursin("soil_lev", soil_json)
        @test !occursin("\"lev\"", soil_json)
    end

    @testset "a rename key the mounted document does not declare is loud" begin
        # Renames never invent names — the §9.7.7 rule at a mount edge.
        bad = joinpath(repo_root, "tests", "invalid", "template_imports",
                       "mount_rename_unknown_index_set.esm")
        err = try
            EarthSciAST.load_path(bad)
            nothing
        catch e
            e
        end
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.SUBSYSTEM_INDEX_SET_RENAME_UNKNOWN_NAME
        @test occursin("celsl", err.message)
    end
end
