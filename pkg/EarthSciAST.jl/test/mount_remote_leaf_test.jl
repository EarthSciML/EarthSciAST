# A leaf fetched over http(s) takes the same §4.7 mount pipeline a local leaf
# takes, at both mount forms: its own authored checks, its own nested mounts
# resolved against its URL directory, the fold of its axes against the enclosing
# environment, its data-source locations against its URL directory, cycle
# detection over canonical URLs, and one read per file per load. An offline
# fetcher stands in for the network.

using Test
using JSON3
using EarthSciAST

@testset "remote mounted leaves (esm-spec §4.7)" begin
    host = "https://mounts.invalid/lib"
    J(x) = JSON3.write(x)
    D = Dict{String, Any}

    # The two mount forms of `ref` in a root document; `extra` merges into the
    # root (e.g. its own metaparameters).
    function root_mounting(ref; form::Symbol, bindings = nothing, extra = D())
        edge = D("ref" => ref)
        bindings === nothing || (edge["bindings"] = bindings)
        doc = D("esm" => "2.0.0", "metadata" => D("name" => "root"))
        if form === :subsystem
            doc["models"] = D(
                "Host" => D(
                    "variables" => D("y" => D("type" => "unknown", "units" => "1", "default" => 1.0)),
                    "equations" => Any[],
                    "subsystems" => D("S" => edge)
                )
            )
        else
            doc["models"] = D("Leaf" => edge)
        end
        return merge(doc, extra)
    end

    leaf_doc(; esm = "2.0.0", extra = D(), model = D()) = merge(
        D(
            "esm" => esm, "metadata" => D("name" => "leaf"),
            "models" => D(
                "Leaf" => merge(
                    D(
                        "variables" => D("x" => D("type" => "unknown", "units" => "1", "default" => 1.0)),
                        "equations" => Any[]
                    ), model
                )
            )
        ), extra
    )

    function load_with(root, docs; fetched = String[])
        fetch = url -> begin
            push!(fetched, String(url))
            haskey(docs, url) || error("offline host has no '$url'")
            docs[url]
        end
        return EarthSciAST._load_document(
            EarthSciAST._to_ordered(root), mktempdir();
            source = EarthSciAST._DocumentSource(fetch = fetch)
        )
    end
    caught(f) = try
        f(); nothing
    catch e
        e
    end

    for form in (:subsystem, :toplevel)
        @testset "$(form) form" begin
            # (a) the leaf is held to its own version gates.
            old = leaf_doc(
                esm = "1.1.0",
                model = D("variables" => D("x" => D("type" => "unknown", "units" => "1", "default" => 1.0, "lb" => 0.0)))
            )
            e = caught(() -> load_with(root_mounting("$host/old.esm"; form), D("$host/old.esm" => J(old))))
            @test e isa EarthSciAST.EarthSciASTError
            @test occursin("2.1.0", sprint(showerror, e))

            # (b) an authored template-origin mark is refused.
            marked = leaf_doc(
                model = D(
                    "equations" => Any[
                        D(
                            "lhs" => D("op" => "D", "args" => ["x"], "wrt" => "t"),
                            "rhs" => D("op" => "-", "args" => ["x"], "__esm_template_origin" => "t")
                        ),
                    ]
                )
            )
            e = caught(() -> load_with(root_mounting("$host/marked.esm"; form), D("$host/marked.esm" => J(marked))))
            @test e !== nothing

            # (c) the leaf's own nested top-level mount resolves against ITS URL
            # directory, and (g) a file mounted twice is fetched once.
            asm = D(
                "esm" => "2.0.0", "metadata" => D("name" => "asm"),
                "models" => D("Leaf" => D("ref" => "parts/part.esm"))
            )
            part = leaf_doc(extra = D("index_sets" => D("cells" => D("kind" => "interval", "size" => 3))))
            fetched = String[]
            f = load_with(
                root_mounting("$host/asm.esm"; form),
                D("$host/asm.esm" => J(asm), "$host/parts/part.esm" => J(part)); fetched
            )
            @test f.index_sets["cells"].size == 3
            @test count(==("$host/parts/part.esm"), fetched) == 1
            @test count(==("$host/asm.esm"), fetched) == 1

            # (d) a leaf axis sized by a name only the enclosing document declares
            # closes against the enclosing environment.
            open_leaf = leaf_doc(extra = D("index_sets" => D("rows" => D("kind" => "interval", "size" => "NR"))))
            root = root_mounting(
                "$host/open.esm"; form,
                extra = D("metaparameters" => D("NR" => D("type" => "integer", "default" => 6)))
            )
            f = load_with(root, D("$host/open.esm" => J(open_leaf)))
            @test f.index_sets["rows"].size == 6

            # (e) a relative data-source location joins onto the leaf's URL directory.
            sourced = leaf_doc(
                extra = D(
                    "data_sources" => D(
                        "met" => D(
                            "kind" => "static",
                            "source" => D("url_template" => "data/met.nc")
                        )
                    )
                )
            )
            f = load_with(root_mounting("$host/sub/sourced.esm"; form), D("$host/sub/sourced.esm" => J(sourced)))
            @test f.data_sources["met"].source.url_template == "$host/sub/data/met.nc"

            # (f) a cycle through URLs (with a dot-segment spelling) is detected.
            cyc = D(
                "esm" => "2.0.0", "metadata" => D("name" => "cyc"),
                "models" => D(
                    "Leaf" => D(
                        "variables" => D(), "equations" => Any[],
                        "subsystems" => D("Back" => D("ref" => "x/../cyc.esm"))
                    )
                )
            )
            e = caught(() -> load_with(root_mounting("$host/cyc.esm"; form), D("$host/cyc.esm" => J(cyc))))
            @test e isa EarthSciAST.SubsystemRefError
            @test occursin("Circular", e.message)

            # A leaf that cannot be fetched is `unresolved_subsystem_ref`, naming
            # the URL and the underlying error.
            e = caught(() -> load_with(root_mounting("$host/missing.esm"; form), D()))
            @test e isa EarthSciAST.SubsystemRefError
            @test e.code == "unresolved_subsystem_ref"
            @test occursin("$host/missing.esm", e.message)
            @test occursin("offline host has no", e.message)
        end
    end

    # The edge's injected imports are the assembler's: a relative ref resolves
    # against the mounting document's directory and keeps naming that local
    # file inside the remote leaf, rather than joining onto the leaf's URL.
    @testset "an edge-injected import on a remote leaf stays local" begin
        dir = mktempdir()
        cp(
            joinpath(@__DIR__, "..", "..", "..", "tests", "valid", "template_import_lib.esm"),
            joinpath(dir, "template_import_lib.esm")
        )
        leaf = leaf_doc(
            model = D(
                "variables" => D(
                    "x" => D("type" => "unknown", "units" => "1", "default" => 1.0),
                    "y" => D("type" => "unknown", "units" => "1")
                ),
                "equations" => Any[
                    D("lhs" => D("op" => "D", "args" => ["x"], "wrt" => "t"), "rhs" => D("op" => "-", "args" => ["x"])),
                    D("lhs" => "y", "rhs" => D("op" => "scale_by_n", "args" => ["x"])),
                ]
            )
        )
        root = root_mounting("$host/scaled.esm"; form = :subsystem)
        root["models"]["Host"]["subsystems"]["S"]["expression_template_imports"] =
            Any[D("ref" => "./template_import_lib.esm")]
        fetched = String[]
        docs = D("$host/scaled.esm" => J(leaf))
        fetch = url -> begin
            push!(fetched, String(url))
            haskey(docs, url) || error("offline host has no '$url'")
            docs[url]
        end
        file = EarthSciAST._load_document(
            EarthSciAST._to_ordered(root), dir;
            source = EarthSciAST._DocumentSource(fetch = fetch)
        )
        @test fetched == ["$host/scaled.esm"]
        y_eq = only(filter(eq -> eq.lhs isa EarthSciAST.VarExpr && eq.lhs.name == "y", file.models["Host"].subsystems["S"].equations))
        # The rule fired: its firing writes a reference to the rule (esm-spec
        # §9.6.3 constraint 7), whose expansion holds no `scale_by_n` op.
        @test y_eq.rhs isa EarthSciAST.OpExpr && y_eq.rhs.op == "apply_expression_template" &&
            y_eq.rhs.name == "scale_by_n"
        y_exp = only(
            filter(
                eq -> eq.lhs isa EarthSciAST.VarExpr && eq.lhs.name == "y",
                EarthSciAST.expanded_file(file).models["Host"].subsystems["S"].equations
            )
        )
        @test !occursin("scale_by_n", sprint(show, y_exp.rhs))
    end

    @testset "an interrupt while fetching is not rebranded" begin
        root = root_mounting("$host/x.esm"; form = :subsystem)
        e = caught(
            () -> EarthSciAST._load_document(
                EarthSciAST._to_ordered(root), mktempdir();
                source = EarthSciAST._DocumentSource(fetch = _ -> throw(InterruptException()))
            )
        )
        @test e isa InterruptException
    end
end
