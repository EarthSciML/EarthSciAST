@testset "Subsystem Reference Resolution Tests" begin

    @testset "SubsystemRefError construction" begin
        err = EarthSciAST.SubsystemRefError("test error")
        @test err.message == "test error"
        @test err isa Exception
    end

    @testset "resolve_subsystem_refs! on file with no subsystems" begin
        metadata = Metadata("no_subsystems")
        file = EsmFile("0.1.0", metadata)
        # Should not error on empty file
        resolve_subsystem_refs!(file, tempdir())
        @test true  # just verifies no error thrown
    end

    @testset "resolve_subsystem_refs! on file with models but no refs" begin
        vars = Dict{String, ModelVariable}(
            "T" => ModelVariable(UnknownVariable, default=300.0)
        )
        model = Model(vars, Equation[])
        models = Dict{String, Model}("Atm" => model)
        metadata = Metadata("model_no_refs")
        file = EsmFile("0.1.0", metadata, models=models)

        resolve_subsystem_refs!(file, tempdir())
        @test haskey(file.models, "Atm")
    end

    @testset "resolve_subsystem_refs! on file with reaction systems but no refs" begin
        species = [Species("O3", default=1e-6)]
        rsys = ReactionSystem(species, Reaction[])
        rsys_dict = Dict{String, ReactionSystem}("Chem" => rsys)
        metadata = Metadata("rsys_no_refs")
        file = EsmFile("0.1.0", metadata, reaction_systems=rsys_dict)

        resolve_subsystem_refs!(file, tempdir())
        @test haskey(file.reaction_systems, "Chem")
    end

    @testset "resolve_subsystem_refs! on file with nested subsystems (no refs)" begin
        inner_vars = Dict{String, ModelVariable}(
            "x" => ModelVariable(UnknownVariable, default=1.0)
        )
        inner = Model(inner_vars, Equation[])

        outer_vars = Dict{String, ModelVariable}(
            "y" => ModelVariable(UnknownVariable, default=2.0)
        )
        outer = Model(outer_vars, Equation[], subsystems=Dict{String, Model}("Inner" => inner))

        models = Dict{String, Model}("Outer" => outer)
        metadata = Metadata("nested_no_refs")
        file = EsmFile("0.1.0", metadata, models=models)

        resolve_subsystem_refs!(file, tempdir())
        @test haskey(file.models["Outer"].subsystems, "Inner")
    end

    @testset "_canonical_ref for local paths" begin
        base = "/tmp/test_dir"
        ref = "sub/model.esm"
        canonical = EarthSciAST._canonical_ref(ref, base)
        @test canonical == abspath(joinpath(base, ref))
    end

    @testset "_canonical_ref for URLs" begin
        ref = "https://example.com/model.esm"
        canonical = EarthSciAST._canonical_ref(ref, "/tmp")
        @test canonical == ref
    end

    @testset "_load_ref with missing local file" begin
        visited = Set{String}()
        @test_throws EarthSciAST.SubsystemRefError begin
            EarthSciAST._load_ref("nonexistent_file.esm", tempdir(), visited)
        end
    end

    @testset "Circular reference detection" begin
        # Simulate a cycle by pre-loading the visited set
        visited = Set{String}()
        ref = "/tmp/circular.esm"
        push!(visited, abspath(ref))

        @test_throws EarthSciAST.SubsystemRefError begin
            EarthSciAST._load_ref("circular.esm", "/tmp", visited)
        end
    end

    @testset "Local ref loading with valid ESM file" begin
        # Create a temporary ESM file to reference
        tmp_dir = mktempdir()
        ref_content = """{
            "esm": "0.1.0",
            "metadata": {
                "name": "Referenced Model",
                "authors": ["Test"]
            },
            "models": {
                "SubModel": {
                    "variables": {
                        "x": {"type": "unknown", "default": 1.0}
                    },
                    "equations": []
                }
            }
        }"""

        ref_path = joinpath(tmp_dir, "referenced.esm")
        write(ref_path, ref_content)

        try
            # The minimal fixture is schema-valid, so this must load cleanly;
            # any exception propagates as a genuine failure.
            visited = Set{String}()
            loaded = EarthSciAST._load_ref("referenced.esm", tmp_dir, visited)
            @test loaded isa EsmFile
            @test loaded.metadata.name == "Referenced Model"
            @test haskey(loaded.models, "SubModel")
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "load() with path calls resolve_subsystem_refs!" begin
        # Create a minimal valid ESM file
        tmp_dir = mktempdir()
        esm_content = """{
            "esm": "0.1.0",
            "metadata": {
                "name": "Test File",
                "authors": ["Test"]
            },
            "models": {
                "SimpleModel": {
                    "variables": {
                        "T": {"type": "unknown", "default": 300.0}
                    },
                    "equations": []
                }
            }
        }"""

        esm_path = joinpath(tmp_dir, "test.esm")
        write(esm_path, esm_content)

        try
            # This should call resolve_subsystem_refs! automatically. The
            # minimal fixture is schema-valid, so load must succeed; any
            # exception propagates as a genuine failure.
            loaded = EarthSciAST.load(esm_path)
            @test loaded isa EsmFile
            @test loaded.metadata.name == "Test File"
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    # --- Data sources: a document-scoped INGEST REGISTRY, not components ---
    #
    # esm 1.0.0 (esm-spec §8): a source exposes no variables of its own, cannot
    # be a subsystem, a coupling endpoint, or a scoped-name path root. The
    # binding lives on the CONSUMING PARAMETER, which owns the units.

    # A minimal schema-valid pure-I/O data source, reused below. It declares no
    # `variables` — that map is exactly what moved onto the consumer.
    loader_json = """{
        "kind": "grid",
        "source": {"url_template": "file:///data/{date:%Y%m%d}.nc"}
    }"""

    @testset "source-only file is a valid document" begin
        tmp_dir = mktempdir()
        try
            path = joinpath(tmp_dir, "loader_only.esm")
            write(path, """{
                "esm": "0.1.0",
                "metadata": {"name": "loader only", "authors": ["Test"]},
                "data_sources": {"Met": $loader_json}
            }""")
            loaded = EarthSciAST.load(path)
            @test loaded isa EsmFile
            @test loaded.data_sources !== nothing
            @test haskey(loaded.data_sources, "Met")
            @test loaded.data_sources["Met"] isa DataSource
            @test loaded.models === nothing || isempty(loaded.models)
            # The registry entry declares no variables of its own.
            @test !hasproperty(loaded.data_sources["Met"], :variables)
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "a data source may NOT be a model subsystem" begin
        # The 0.x shape mounted a loader under `models.<M>.subsystems.<key>`.
        # From 1.0.0 the subsystems union is [Model, SubsystemRef] only, so the
        # loader-shaped entry is no longer a legal subsystem and the document is
        # rejected rather than silently reinterpreted.
        tmp_dir = mktempdir()
        try
            path = joinpath(tmp_dir, "main.esm")
            write(path, """{
                "esm": "0.1.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "models": {"Regridder": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {"Met": $loader_json}
                }}
            }""")
            @test_throws Exception EarthSciAST.load(path)
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "a model consumes a source through a parameter update" begin
        # The replacement for the 0.x loader-as-subsystem split: the source is a
        # top-level registry entry, and the field the model reads is one of its
        # OWN parameters (esm-spec §8.5).
        tmp_dir = mktempdir()
        try
            path = joinpath(tmp_dir, "main.esm")
            write(path, """{
                "esm": "0.1.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "data_sources": {"Met": $loader_json},
                "models": {"Regridder": {
                    "variables": {
                        "emis": {
                            "type": "parameter", "units": "kg/m^2/s", "shape": [],
                            "update": {"kind": "data", "source": "Met",
                                       "from": {"file_variable": "EMIS"}}
                        }
                    },
                    "equations": []
                }}
            }""")
            loaded = EarthSciAST.load(path)
            m = loaded.models["Regridder"]
            @test isempty(m.subsystems)
            @test discrete_parameters(m) == ["emis"]
            rule = m.variables["emis"].update[1]
            @test rule.kind == "data"
            @test rule.source == "Met"
            @test rule.from.file_variable == "EMIS"
            # The units are the CONSUMER's, declared once.
            @test m.variables["emis"].units == "kg/m^2/s"

            # Round-trips: one rule emits as the OBJECT form, and the source
            # keeps its registry shape.
            rt = EarthSciAST.serialize_esm_file(loaded)
            v = rt["models"]["Regridder"]["variables"]["emis"]
            @test v["update"]["kind"] == "data"
            @test v["update"]["from"]["file_variable"] == "EMIS"
            @test haskey(rt["data_sources"]["Met"], "source")
            @test !haskey(rt["data_sources"]["Met"], "variables")
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "a source-only file cannot be mounted as a subsystem ref" begin
        # A `{"ref": ...}` subsystem resolves to the referenced file's single
        # top-level MODEL. From 1.0.0 a file whose only top-level entry is a
        # `data_sources` block has no mountable component, so the ref fails
        # loudly instead of resolving to a pseudo-component.
        tmp_dir = mktempdir()
        try
            write(joinpath(tmp_dir, "loader.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "loader", "authors": ["Test"]},
                "data_sources": {"GEOSFP": $loader_json}
            }""")
            main_path = joinpath(tmp_dir, "main.esm")
            write(main_path, """{
                "esm": "0.1.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "models": {"Regridder": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {"Met": {"ref": "./loader.esm"}}
                }}
            }""")
            @test_throws SubsystemRefError EarthSciAST.load(main_path)
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "ref to a file without exactly one component errors" begin
        tmp_dir = mktempdir()
        try
            # Two top-level loaders: ambiguous, not a single-component file.
            write(joinpath(tmp_dir, "two_loaders.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "two loaders", "authors": ["Test"]},
                "data_sources": {"A": $loader_json, "B": $loader_json}
            }""")
            main_path = joinpath(tmp_dir, "main.esm")
            write(main_path, """{
                "esm": "0.1.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "models": {"Outer": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {"Bad": {"ref": "./two_loaders.esm"}}
                }}
            }""")
            @test_throws EarthSciAST.SubsystemRefError EarthSciAST.load(main_path)
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    # --- Top-level model {ref} stubs (schema §4.7: models.* = oneOf [Model, {ref}]) ---

    @testset "top-level model {ref} stub resolves on load()" begin
        tmp_dir = mktempdir()
        try
            write(joinpath(tmp_dir, "child.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "child", "authors": ["Test"]},
                "models": {"Inner": {
                    "variables": {"u": {"type": "unknown", "default": 1.0}},
                    "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                                   "rhs": {"op": "*", "args": ["u", 0.0]}}]
                }}
            }""")
            main_path = joinpath(tmp_dir, "main.esm")
            write(main_path, """{
                "esm": "0.1.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "models": {"Comp": {"ref": "./child.esm"}}
            }""")
            loaded = EarthSciAST.load(main_path)
            # Named by the parent model key; the ref stub is replaced by the model.
            @test haskey(loaded.models, "Comp")
            m = loaded.models["Comp"]
            @test m isa Model
            @test haskey(m.variables, "u")
            @test length(m.equations) == 1
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "top-level model ref merges component function_tables" begin
        tmp_dir = mktempdir()
        try
            write(joinpath(tmp_dir, "child.esm"), """{
                "esm": "0.4.0",
                "metadata": {"name": "child", "authors": ["Test"]},
                "function_tables": {"sig": {
                    "axes": [{"name": "i", "values": [1, 2, 3, 4]}],
                    "interpolation": "linear", "out_of_bounds": "clamp",
                    "data": [1.0, 2.0, 3.0, 4.0]
                }},
                "models": {"Inner": {
                    "variables": {"k": {"type": "unknown", "default": 0.0}},
                    "equations": [{"lhs": {"op": "D", "args": ["k"], "wrt": "t"},
                                   "rhs": {"op": "table_lookup", "table": "sig",
                                           "axes": {"i": 2}, "args": []}}]
                }}
            }""")
            main_path = joinpath(tmp_dir, "main.esm")
            write(main_path, """{
                "esm": "0.4.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "models": {"Comp": {"ref": "./child.esm"}}
            }""")
            loaded = EarthSciAST.load(main_path)
            # The table_lookup the spliced model references resolves at the parent.
            @test loaded.function_tables !== nothing
            @test haskey(loaded.function_tables, "sig")
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "top-level model ref anchors the component's nested subsystem refs" begin
        tmp_dir = mktempdir()
        try
            # The component lives in a subdir and references its NESTED MODEL
            # relative to itself; without re-anchoring, that ref would break once
            # the component is spliced into the parent (a different directory).
            comp_dir = joinpath(tmp_dir, "components")
            mkpath(comp_dir)
            write(joinpath(comp_dir, "leaf.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "leaf", "authors": ["Test"]},
                "models": {"Leaf": {
                    "variables": {"q": {"type": "parameter", "units": "1", "default": 1.0}},
                    "equations": []
                }}
            }""")
            write(joinpath(comp_dir, "comp.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "comp", "authors": ["Test"]},
                "models": {"Inner": {
                    "variables": {},
                    "equations": [],
                    "subsystems": {"Met": {"ref": "./leaf.esm"}}
                }}
            }""")
            main_path = joinpath(tmp_dir, "main.esm")
            write(main_path, """{
                "esm": "0.1.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "models": {"Comp": {"ref": "./components/comp.esm"}}
            }""")
            loaded = EarthSciAST.load(main_path)
            met = loaded.models["Comp"].subsystems["Met"]
            @test met isa Model
            @test !(met isa SubsystemRef)
            @test haskey(met.variables, "q")
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "top-level model ref to a multi-model file errors" begin
        tmp_dir = mktempdir()
        try
            write(joinpath(tmp_dir, "two_models.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "two models", "authors": ["Test"]},
                "models": {
                    "A": {"variables": {"x": {"type": "unknown", "default": 1.0}}, "equations": []},
                    "B": {"variables": {"y": {"type": "unknown", "default": 2.0}}, "equations": []}
                }
            }""")
            main_path = joinpath(tmp_dir, "main.esm")
            write(main_path, """{
                "esm": "0.1.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "models": {"Comp": {"ref": "./two_models.esm"}}
            }""")
            @test_throws EarthSciAST.SubsystemRefError EarthSciAST.load(main_path)
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "circular top-level model ref is detected" begin
        tmp_dir = mktempdir()
        try
            write(joinpath(tmp_dir, "a.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "a", "authors": ["Test"]},
                "models": {"B": {"ref": "./b.esm"}}
            }""")
            write(joinpath(tmp_dir, "b.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "b", "authors": ["Test"]},
                "models": {"A": {"ref": "./a.esm"}}
            }""")
            @test_throws EarthSciAST.SubsystemRefError EarthSciAST.load(joinpath(tmp_dir, "a.esm"))
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "top-level model ref selects one model from a multi-model file" begin
        tmp_dir = mktempdir()
        try
            write(joinpath(tmp_dir, "lib.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "lib", "authors": ["Test"]},
                "models": {
                    "KernelA": {"variables": {"a": {"type": "unknown", "default": 1.0}}, "equations": []},
                    "KernelB": {"variables": {"b": {"type": "unknown", "default": 2.0}}, "equations": []}
                }
            }""")
            main_path = joinpath(tmp_dir, "main.esm")
            write(main_path, """{
                "esm": "0.1.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "models": {"Pick": {"ref": "./lib.esm", "model": "KernelB"}}
            }""")
            loaded = EarthSciAST.load(main_path)
            @test haskey(loaded.models, "Pick")
            @test haskey(loaded.models["Pick"].variables, "b")
            @test !haskey(loaded.models["Pick"].variables, "a")
            # A selector naming a missing model errors.
            bad_path = joinpath(tmp_dir, "bad.esm")
            write(bad_path, """{
                "esm": "0.1.0",
                "metadata": {"name": "bad", "authors": ["Test"]},
                "models": {"Pick": {"ref": "./lib.esm", "model": "KernelZ"}}
            }""")
            @test_throws EarthSciAST.SubsystemRefError EarthSciAST.load(bad_path)
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    @testset "same single-model file referenced by multiple instances" begin
        tmp_dir = mktempdir()
        try
            write(joinpath(tmp_dir, "child.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "child", "authors": ["Test"]},
                "models": {"Inner": {"variables": {"u": {"type": "unknown", "default": 1.0}}, "equations": []}}
            }""")
            main_path = joinpath(tmp_dir, "main.esm")
            write(main_path, """{
                "esm": "0.1.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "models": {
                    "First":  {"ref": "./child.esm"},
                    "Second": {"ref": "./child.esm"}
                }
            }""")
            loaded = EarthSciAST.load(main_path)
            # Path-scoped cycle detection allows the same file in sibling slots.
            @test haskey(loaded.models["First"].variables, "u")
            @test haskey(loaded.models["Second"].variables, "u")
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

    # A §4.7 subsystem-ref `bindings` value may be a metaparameter EXPRESSION
    # (esm-spec §9.7.6 binding site 3): an integer, a name in the MOUNTING
    # document's metaparameter scope, or a `{op:+|-|*|/, args}` tree over the
    # same — e.g. deriving the regridder's target-cell count `NTGT = NX*NY` from
    # the mount's grid. It folds immediately against the mounting document's
    # already-closed metaparameter environment. Mirrors the subsystem cases of
    # pkg/earthsci-ast-py/tests/test_metaparam_expr_bindings.py.
    @testset "subsystem-ref bindings: metaparameter-expression values (§9.7.6)" begin
        _child = """{
            "esm": "0.8.0",
            "metadata": {"name": "child_regrid"},
            "metaparameters": {
                "NX": {"type": "integer", "default": 2},
                "NY": {"type": "integer", "default": 2},
                "NTGT": {"type": "integer", "default": 4}
            },
            "index_sets": {
                "tgt_cells": {"kind": "interval", "size": "NTGT"},
                "gx": {"kind": "interval", "size": "NX"},
                "gy": {"kind": "interval", "size": "NY"}
            },
            "models": {"Regrid": {
                "variables": {"u": {"type": "unknown", "units": "1", "default": 0.0}},
                "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                               "rhs": {"op": "*", "args": [-0.5, "u"]}}]
            }}
        }"""
        _parent(bindings) = """{
            "esm": "0.8.0",
            "metadata": {"name": "parent_mount"},
            "metaparameters": {
                "NX": {"type": "integer", "default": 18},
                "NY": {"type": "integer", "default": 20}
            },
            "models": {"Host": {
                "variables": {}, "equations": [],
                "subsystems": {"Regrid": {"ref": "./child_regrid.esm", "bindings": $bindings}}
            }}
        }"""
        _err(f) = try
            f(); nothing
        catch e
            e isa EarthSciAST.ExpressionTemplateError ? e.code : rethrow(e)
        end

        @testset "NTGT = NX*NY derived at the mount, folded to concrete" begin
            tmp = mktempdir()
            try
                write(joinpath(tmp, "child_regrid.esm"), _child)
                p = joinpath(tmp, "parent.esm")
                write(p, _parent(
                    """{"NX": "NX", "NY": "NY", "NTGT": {"op": "*", "args": ["NX", "NY"]}}"""))
                # The child's index sets merge into the importing document's
                # registry (§4.7); their sizes come from the folded bindings.
                f = EarthSciAST.load(p; metaparameters=Dict("NX" => 18, "NY" => 20))
                @test f.index_sets["tgt_cells"].size == 360   # derived NX*NY
                @test f.index_sets["gx"].size == 18
                @test f.index_sets["gy"].size == 20
                @test f.models["Host"].subsystems["Regrid"] isa EarthSciAST.Model
            finally
                rm(tmp, recursive=true, force=true)
            end
        end

        @testset "folds against the mounting document's defaults" begin
            tmp = mktempdir()
            try
                write(joinpath(tmp, "child_regrid.esm"), _child)
                p = joinpath(tmp, "parent.esm")
                write(p, _parent(
                    """{"NX": "NX", "NY": "NY", "NTGT": {"op": "*", "args": ["NX", "NY"]}}"""))
                f = EarthSciAST.load(p)   # parent defaults NX=18, NY=20
                @test f.index_sets["tgt_cells"].size == 360
            finally
                rm(tmp, recursive=true, force=true)
            end
        end

        @testset "plain-integer bindings still work (regression)" begin
            tmp = mktempdir()
            try
                write(joinpath(tmp, "child_regrid.esm"), _child)
                p = joinpath(tmp, "parent.esm")
                write(p, _parent("""{"NX": 5, "NY": 6, "NTGT": 30}"""))
                f = EarthSciAST.load(p)
                @test f.index_sets["tgt_cells"].size == 30
                @test f.index_sets["gx"].size == 5
                @test f.index_sets["gy"].size == 6
            finally
                rm(tmp, recursive=true, force=true)
            end
        end

        @testset "unknown free name in a binding value is loud" begin
            tmp = mktempdir()
            try
                write(joinpath(tmp, "child_regrid.esm"), _child)
                p = joinpath(tmp, "parent.esm")
                write(p, _parent(
                    """{"NX": "NX", "NY": "NX", "NTGT": {"op": "*", "args": ["NX", "NZZ"]}}"""))
                @test _err(() -> EarthSciAST.load(p; metaparameters=Dict("NX" => 18))) ==
                      "template_import_unknown_name"
            finally
                rm(tmp, recursive=true, force=true)
            end
        end
    end

    @testset "load(::IO) runs the same pipeline as load(::String)" begin
        # REGRESSION: `load(::IO)` used to call the typed pipeline directly,
        # skipping top-level `{ref}` inlining AND `resolve_subsystem_refs!`.
        # A stream-loaded document therefore kept its subsystem refs as
        # unresolved `SubsystemRef`s — which `flatten` SILENTLY SKIPS. Same
        # bytes, smaller system, no error.
        tmp_dir = mktempdir()
        try
            write(joinpath(tmp_dir, "child.esm"), """{
                "esm": "0.1.0",
                "metadata": {"name": "child", "authors": ["Test"]},
                "models": {"Inner": {
                    "variables": {"u": {"type": "unknown", "default": 1.0},
                                  "k": {"type": "parameter", "units": "s^-1",
                                        "default": 0.5}},
                    "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                                   "rhs": {"op": "*", "args": ["k", "u"]}}]
                }}
            }""")
            main_path = joinpath(tmp_dir, "main.esm")
            main_json = """{
                "esm": "0.1.0",
                "metadata": {"name": "main", "authors": ["Test"]},
                "models": {"Host": {
                    "variables": {"y": {"type": "unknown", "default": 2.0}},
                    "equations": [{"lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                                   "rhs": {"op": "*", "args": ["y", 0.0]}}],
                    "subsystems": {"Sub": {"ref": "./child.esm"}}
                }}
            }"""
            write(main_path, main_json)

            from_path = EarthSciAST.load(main_path)
            from_io = EarthSciAST.load(IOBuffer(main_json); base_path=tmp_dir)
            from_dict = EarthSciAST.load(JSON3.read(main_json, Dict{String,Any});
                                         base_path=tmp_dir)

            # The ref is linked, not left as a stub, on every entry point.
            for f in (from_path, from_io, from_dict)
                @test f.models["Host"].subsystems["Sub"] isa Model
            end

            fp = flatten(from_path)
            fi = flatten(from_io)
            fd = flatten(from_dict)

            # The subsystem's variables and equation survive the stream path.
            @test "Host.Sub.u" in collect(keys(fi.state_variables))
            for other in (fi, fd)
                @test collect(keys(other.state_variables)) ==
                      collect(keys(fp.state_variables))
                @test collect(keys(other.parameters)) == collect(keys(fp.parameters))
                @test length(other.equations) == length(fp.equations)
                @test [to_ascii(e.lhs) for e in other.equations] ==
                      [to_ascii(e.lhs) for e in fp.equations]
                @test [to_ascii(e.rhs) for e in other.equations] ==
                      [to_ascii(e.rhs) for e in fp.equations]
            end
        finally
            rm(tmp_dir, recursive=true, force=true)
        end
    end

end
