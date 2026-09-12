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

    @testset "the field applies at a top-level model `{ref}` mount" begin
        # esm-spec §4.7 "Where it applies": `index_set_rename` is normative at
        # BOTH mount forms, with the same meaning and the same pipeline — "a
        # binding MUST NOT make the two forms differ". Julia used to refuse the
        # field at a top-level `models.<k>` `{ref}` with
        # `subsystem_index_set_rename_unsupported_mount_form`, because that form
        # was a raw pre-pass with no resolved mounted document to rename. The
        # form now runs the §4.7 edge pipeline, so the rename applies: the spec
        # says the refusal "closes when that gap does".
        dir = mktempdir()
        leaf = Dict{String,Any}(
            "esm" => "1.0.0", "metadata" => Dict("name" => "leaf"),
            "index_sets" => Dict("ax" => Dict("kind" => "interval", "size" => 3)),
            "models" => Dict("Leaf" => Dict(
                "variables" => Dict("u" => Dict("type" => "unknown", "units" => "1",
                                                "shape" => ["ax"], "default" => 1.0)),
                "equations" => [Dict(
                    "lhs" => Dict("op" => "D", "args" => ["u"], "wrt" => "t"),
                    "rhs" => Dict("op" => "*", "args" => [-1.0, "u"]))])))
        write(joinpath(dir, "leaf.esm"), JSON3.write(leaf))
        host = Dict{String,Any}(
            "esm" => "1.0.0", "metadata" => Dict("name" => "host"),
            "models" => Dict("L" => Dict("ref" => "./leaf.esm",
                                         "index_set_rename" => Dict("ax" => "renamed_ax"))))
        write(joinpath(dir, "host.esm"), JSON3.write(host))
        f = EarthSciAST.load_path(joinpath(dir, "host.esm"))
        # The leaf's axis merges under its POST-rename name.
        @test haskey(f.index_sets, "renamed_ax")
        @test !haskey(f.index_sets, "ax")
        @test f.index_sets["renamed_ax"].size == 3
        # §4.7 transitivity: the rename rewrites every occurrence, not only the
        # registry key — the mounted component's `shape` entries included.
        @test f.models["L"].variables["u"].shape == ["renamed_ax"]

        # A key the resolved mounted document does not declare is still
        # `subsystem_index_set_rename_unknown_name` — renames never invent names.
        bad_host = Dict{String,Any}(
            "esm" => "1.0.0", "metadata" => Dict("name" => "host_bad"),
            "models" => Dict("L" => Dict("ref" => "./leaf.esm",
                                         "index_set_rename" => Dict("nope" => "renamed_ax"))))
        write(joinpath(dir, "host_bad.esm"), JSON3.write(bad_host))
        err = try
            EarthSciAST.load_path(joinpath(dir, "host_bad.esm"))
            nothing
        catch e
            e
        end
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.SUBSYSTEM_INDEX_SET_RENAME_UNKNOWN_NAME
    end

    @testset "the twin refusal survives at a top-level reaction-system `{ref}`" begin
        # OUT of the model form's scope and deliberately unchanged: Julia is the
        # only binding with a top-level `reaction_systems.<k>` `{ref}` mount, and
        # that inliner is still the raw pre-pass the model form used to be — no
        # resolved mounted document, so nothing for the rename to speak about.
        # Refusing rather than ignoring keeps it loud (esm-spec §4.7 "Where it
        # applies"); the refusal closes when THAT gap does.
        dir = mktempdir()
        leaf = Dict{String,Any}(
            "esm" => "1.0.0", "metadata" => Dict("name" => "rs_leaf"),
            "reaction_systems" => Dict("RS" => Dict(
                "species" => Dict("A" => Dict("units" => "mol/m^3", "default" => 1.0),
                                  "B" => Dict("units" => "mol/m^3", "default" => 0.0)),
                "reactions" => [Dict("reactants" => Dict("A" => 1),
                                     "products" => Dict("B" => 1),
                                     "rate" => 0.5)])))
        write(joinpath(dir, "rs_leaf.esm"), JSON3.write(leaf))
        host = Dict{String,Any}(
            "esm" => "1.0.0", "metadata" => Dict("name" => "rs_host"),
            "reaction_systems" => Dict("R" => Dict(
                "ref" => "./rs_leaf.esm",
                "index_set_rename" => Dict("ax" => "renamed_ax"))))
        write(joinpath(dir, "rs_host.esm"), JSON3.write(host))
        err = try
            EarthSciAST.load_path(joinpath(dir, "rs_host.esm"))
            nothing
        catch e
            e
        end
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.SUBSYSTEM_INDEX_SET_RENAME_UNSUPPORTED_MOUNT_FORM
        @test occursin("not supported at this mount form", err.message)
        @test occursin("subsystems", err.message)   # names the form that works
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

    @testset "the shared top-level-form fixtures" begin
        # esm-spec §4.7 "Two mount forms, one mechanism": the pair below is the
        # `mount_rename_two_columns` assembly written at the top-level
        # `models.<k>` attachment point, and all five bindings drive it. A
        # binding that applies the field at one form and ignores it at the other
        # passes the `subsystems.<k>` fixtures above and fails these.
        file = EarthSciAST.load_path(valid("mount_rename_two_columns_toplevel.esm"))
        @test file.index_sets["lev"].size == 59
        @test file.index_sets["soil_lev"].size == 4
        # Each component lands as a TOP-LEVEL system under its mount key.
        @test file.models["Soil"].variables["Tsoil"].shape == ["soil_lev"]
        @test file.models["Atm"].variables["T"].shape == ["lev"]

        bad = joinpath(repo_root, "tests", "invalid", "template_imports",
                       "mount_rename_unknown_index_set_toplevel.esm")
        err = try
            EarthSciAST.load_path(bad)
            nothing
        catch e
            e
        end
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.SUBSYSTEM_INDEX_SET_RENAME_UNKNOWN_NAME
        @test occursin("celsl", err.message)
        @test occursin("top-level model ref", err.message)
    end
end
