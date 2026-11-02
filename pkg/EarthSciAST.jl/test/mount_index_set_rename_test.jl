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
        leaf = Dict{String, Any}(
            "esm" => "1.0.0", "metadata" => Dict("name" => "leaf"),
            "index_sets" => Dict("ax" => Dict("kind" => "interval", "size" => 3)),
            "models" => Dict(
                "Leaf" => Dict(
                    "variables" => Dict(
                        "u" => Dict(
                            "type" => "unknown", "units" => "1",
                            "shape" => ["ax"], "default" => 1.0
                        )
                    ),
                    "equations" => [
                        Dict(
                            "lhs" => Dict("op" => "D", "args" => ["u"], "wrt" => "t"),
                            "rhs" => Dict("op" => "*", "args" => [-1.0, "u"])
                        ),
                    ]
                )
            )
        )
        write(joinpath(dir, "leaf.esm"), JSON3.write(leaf))
        host = Dict{String, Any}(
            "esm" => "1.0.0", "metadata" => Dict("name" => "host"),
            "models" => Dict(
                "L" => Dict(
                    "ref" => "./leaf.esm",
                    "index_set_rename" => Dict("ax" => "renamed_ax")
                )
            )
        )
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
        bad_host = Dict{String, Any}(
            "esm" => "1.0.0", "metadata" => Dict("name" => "host_bad"),
            "models" => Dict(
                "L" => Dict(
                    "ref" => "./leaf.esm",
                    "index_set_rename" => Dict("nope" => "renamed_ax")
                )
            )
        )
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

    @testset "the field applies at a top-level reaction-system `{ref}` too" begin
        # esm-spec §4.7 "Two mount forms, one mechanism": a top-level
        # `reaction_systems.<k>` `{ref}` runs the same edge pipeline as a
        # `models.<k>` one. It used to be a raw pre-pass that refused the field
        # with `subsystem_index_set_rename_unsupported_mount_form`, dropped the
        # leaf's `index_sets` and ignored the edge's `bindings`. Now the leaf
        # closes under the edge's `bindings`, its axes merge, and the rename
        # applies.
        dir = mktempdir()
        leaf = Dict{String, Any}(
            "esm" => "1.0.0", "metadata" => Dict("name" => "rs_leaf"),
            "metaparameters" => Dict("N" => Dict("type" => "integer", "default" => 2)),
            "index_sets" => Dict("ax" => Dict("kind" => "interval", "size" => "N")),
            "reaction_systems" => Dict(
                "RS" => Dict(
                    "species" => Dict(
                        "A" => Dict("units" => "mol/m^3", "default" => 1.0),
                        "B" => Dict("units" => "mol/m^3", "default" => 0.0)
                    ),
                    "parameters" => Dict("k" => Dict("units" => "1/s", "default" => 0.5)),
                    "reactions" => [
                        Dict(
                            "id" => "R1",
                            "substrates" => [Dict("species" => "A", "stoichiometry" => 1)],
                            "products" => [Dict("species" => "B", "stoichiometry" => 1)],
                            "rate" => "k"
                        ),
                    ]
                )
            )
        )
        write(joinpath(dir, "rs_leaf.esm"), JSON3.write(leaf))
        host(edge) = Dict{String, Any}(
            "esm" => "1.0.0", "metadata" => Dict("name" => "rs_host"),
            "reaction_systems" => Dict("R" => merge(Dict{String, Any}("ref" => "./rs_leaf.esm"), edge))
        )
        load(edge) = begin
            write(joinpath(dir, "rs_host.esm"), JSON3.write(host(edge)))
            EarthSciAST.load_path(joinpath(dir, "rs_host.esm"))
        end

        f = load(Dict{String, Any}())
        @test f.index_sets["ax"].size == 2                # the leaf's own default
        @test Set(keys(f.reaction_systems["R"].species)) == Set(["A", "B"]) ||
            length(f.reaction_systems["R"].species) == 2

        f = load(Dict{String, Any}("bindings" => Dict("N" => 5)))
        @test f.index_sets["ax"].size == 5                # closed by the edge

        f = load(Dict{String, Any}("index_set_rename" => Dict("ax" => "renamed_ax")))
        @test haskey(f.index_sets, "renamed_ax")
        @test !haskey(f.index_sets, "ax")
        @test f.index_sets["renamed_ax"].size == 2

        err = try
            load(Dict{String, Any}("index_set_rename" => Dict("nope" => "renamed_ax")))
            nothing
        catch e
            e
        end
        @test err isa ExpressionTemplateError
        @test err.code == ERROR_CODES.SUBSYSTEM_INDEX_SET_RENAME_UNKNOWN_NAME
    end

    @testset "a rename key the mounted document does not declare is loud" begin
        # Renames never invent names — the §9.7.7 rule at a mount edge.
        bad = joinpath(
            repo_root, "tests", "invalid", "template_imports",
            "mount_rename_unknown_index_set.esm"
        )
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

        bad = joinpath(
            repo_root, "tests", "invalid", "template_imports",
            "mount_rename_unknown_index_set_toplevel.esm"
        )
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

    @testset "an assembly mounted by another assembly resolves through" begin
        # esm-spec §4.7 "Two mount forms, one mechanism": the top-level form
        # lands its component as a TOP-LEVEL system, which is exactly what the
        # form mounts — so it has to compose with itself, and which attachment
        # point mounted a file cannot change what that file IS. A binding that
        # resolves one level deep picks the leaf's own UNRESOLVED `{ref}` out of
        # its `models` and treats it as the component.
        file = EarthSciAST.load_path(valid("mount_chain_outer.esm"))
        @test file.models["Deep"].variables["Tsoil"].shape == ["soil_lev"]
        # The axis name the INNER edge chose reaches the OUTER document's registry.
        @test file.index_sets["soil_lev"].size == 4
        @test !haskey(file.index_sets, "lev")

        file = EarthSciAST.load_path(valid("mount_chain_via_subsystem.esm"))
        deep = file.models["Host"].subsystems["Deep"]
        @test !(deep isa AbstractDict)   # a bare mount edge would still be one
        @test deep.variables["Tsoil"].shape == ["soil_lev"]
        @test file.index_sets["soil_lev"].size == 4
    end

    @testset "a mount cycle across the chain is reported" begin
        # Composition without cycle detection is unbounded recursion. `visited`
        # is path-scoped (pushed on enter, popped on exit), so the same component
        # file may be mounted by several keys — only a cycle ALONG THE CURRENT
        # PATH is the error.
        dir = mktempdir()
        doc(name, ref) = JSON3.write(
            Dict(
                "esm" => "1.0.0",
                "metadata" => Dict("name" => name, "description" => "mount cycle probe"),
                "models" => Dict("M" => Dict("ref" => ref)),
            )
        )
        write(joinpath(dir, "a.esm"), doc("a", "./b.esm"))
        write(joinpath(dir, "b.esm"), doc("b", "./a.esm"))
        write(joinpath(dir, "root.esm"), doc("root", "./a.esm"))
        err = try
            EarthSciAST.load_path(joinpath(dir, "root.esm"))
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("ircular", sprint(showerror, err))
    end
end
