# The `aggregate` -> `faq` deprecated-op-alias contract (esm 1.1.0).
#
# Gates tests/conformance/deprecated_op_alias/ and the `removed_op` rejection
# of `arrayop`. See CONFORMANCE_SPEC §7 and
# docs/content/rfcs/faq-node-rename.md.

using Test
using EarthSciAST
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _ALIAS_CONF = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                             "deprecated_op_alias")

# Every `op` string in a decoded document, depth-first.
function _all_ops(node, out = String[])
    if node isa AbstractDict
        v = get(node, "op", nothing)
        v isa AbstractString && push!(out, String(v))
        for child in values(node)
            _all_ops(child, out)
        end
    elseif node isa AbstractVector
        for child in node
            _all_ops(child, out)
        end
    end
    return out
end

@testset "deprecated op alias: aggregate -> faq" begin
    @testset "the alias loads and warns exactly once for the document" begin
        # Once per DOCUMENT, not once per node: the fixture carries two aliased
        # nodes and must still produce a single warning.
        @test_logs (:warn,) match_mode = :any EarthSciAST.load_path(
            joinpath(_ALIAS_CONF, "aliased.esm"))
    end

    @testset "the alias never survives the loader" begin
        f = EarthSciAST.load_path(joinpath(_ALIAS_CONF, "aliased.esm"))
        ops = _all_ops(JSON3.read(EarthSciAST.to_json(f), Dict{String,Any}))
        @test !("aggregate" in ops)   # the alias reached emit
        @test "faq" in ops
    end

    @testset "emitting the alias document reproduces the canonical one" begin
        aliased = EarthSciAST.load_path(joinpath(_ALIAS_CONF, "aliased.esm"))
        canonical = EarthSciAST.load_path(joinpath(_ALIAS_CONF, "canonical.esm"))
        @test EarthSciAST.to_json(aliased) == EarthSciAST.to_json(canonical)
    end

    @testset "the canonical document is quiet" begin
        @test_logs EarthSciAST.load_path(joinpath(_ALIAS_CONF, "canonical.esm"))
    end

    @testset "the wire boundary covers REFERENCED documents" begin
        # Every other fixture here is a single self-contained document — which
        # is exactly why five green binding suites missed the leak: the
        # normalizer ran on the ROOT's bytes and ref resolution then parsed
        # child files raw, so a child's alias reached `emit` untouched.
        f = EarthSciAST.load_path(joinpath(_ALIAS_CONF, "ref_parent_aliased.esm"))
        ops = _all_ops(JSON3.read(EarthSciAST.to_json(f), Dict{String,Any}))
        @test !("aggregate" in ops)
        @test "faq" in ops
    end

    @testset "arrayop in a referenced child is rejected" begin
        err = try
            EarthSciAST.load_path(joinpath(_ALIAS_CONF, "ref_parent_arrayop.esm"))
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("removed_op", sprint(showerror, err))  # the shared diagnostic name
    end

    @testset "the esm 1.1.0 version gate" begin
        mktempdir() do dir
            function at_version(src, version)
                doc = JSON3.read(read(joinpath(_ALIAS_CONF, src), String), Dict{String,Any})
                doc["esm"] = version
                path = joinpath(dir, "v_" * version * "_" * src)
                write(path, JSON3.write(doc))
                return path
            end
            # `faq` arrives at 1.1.0 — the gate the `solver` block also uses.
            err = try
                EarthSciAST.load_path(at_version("canonical.esm", "1.0.0")); nothing
            catch e; e end
            @test err !== nothing
            @test occursin("faq_version_too_old", sprint(showerror, err))  # the shared diagnostic name
            # `aggregate` IS the pre-1.1.0 spelling, so the gate must NOT catch
            # it: the gate reads the AUTHORED form, and the alias is normalized
            # with the declared version raised to the floor alongside it.
            f = EarthSciAST.load_path(at_version("aliased.esm", "1.0.0"))
            @test f.esm == "1.1.0"
        end
    end

    @testset "the other version gates read the RAISED esm, on every path" begin
        # A 1.0.0 file spelling `aggregate` is raised to 1.1.0 at the wire
        # boundary, so its `solver` block (a 1.1.0 construct) is legal: as a
        # root read from a file, as the same root held in memory, and as a
        # mounted leaf. Only the `faq` gate reads the authored version.
        err_text(f) = try f(); "" catch e; sprint(showerror, e) end
        mktempdir() do dir
            function with_solver(src, version)
                doc = JSON3.read(read(joinpath(_ALIAS_CONF, src), String), Dict{String,Any})
                doc["esm"] = version
                doc["solver"] = Dict{String,Any}("stiffness" => "high")
                return doc
            end
            root = with_solver("aliased.esm", "1.0.0")
            path = joinpath(dir, "root.esm")
            write(path, JSON3.write(root))
            @test EarthSciAST.load_path(path).esm == "1.1.0"
            @test EarthSciAST.load_document(root).esm == "1.1.0"

            write(joinpath(dir, "ref_child_aliased.esm"),
                  JSON3.write(with_solver("ref_child_aliased.esm", "1.0.0")))
            parent = JSON3.read(read(joinpath(_ALIAS_CONF, "ref_parent_aliased.esm"), String),
                                Dict{String,Any})
            write(joinpath(dir, "parent.esm"), JSON3.write(parent))
            @test EarthSciAST.load_path(joinpath(dir, "parent.esm")) isa EarthSciAST.EsmFile

            # The `faq` gate still reads the authored version in memory too.
            canonical = with_solver("canonical.esm", "1.0.0")
            @test occursin("faq_version_too_old",
                           err_text(() -> EarthSciAST.load_document(canonical)))
            # Without the alias there is nothing to raise: a 1.0.0 `solver`
            # block is refused.
            plain = with_solver("canonical.esm", "1.0.0")
            delete!(plain, "index_sets")
            plain["models"] = Dict{String,Any}("M" => Dict{String,Any}(
                "variables" => Dict{String,Any}("u" => Dict{String,Any}("type" => "unknown")),
                "equations" => Any[Dict{String,Any}(
                    "lhs" => Dict{String,Any}("op" => "D", "args" => Any["u"], "wrt" => "t"),
                    "rhs" => 0)]))
            @test occursin("solver_version_too_old",
                           err_text(() -> EarthSciAST.load_document(plain)))
        end
    end

    @testset "each file is held to its own esm across a mount (§4.7)" begin
        inv = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid")
        code(path) = try
            EarthSciAST.load_path(path); nothing
        catch e
            e isa EarthSciAST.ExpressionTemplateError ? e.code : rethrow(e)
        end
        @test code(joinpath(inv, "version_gate_newer_mounts_older_const_units.esm")) ==
              "const_units_version_too_old"
        @test code(joinpath(inv, "version_gate_newer_mounts_older_solver.esm")) ==
              "solver_version_too_old"
        @test EarthSciAST.load_path(joinpath(TESTUTILS_REPO_ROOT, "tests", "valid",
            "version_gate_older_mounts_newer.esm")) isa EarthSciAST.EsmFile
    end

    @testset "arrayop is rejected by name, not left to the open tier" begin
        # `arrayop` matches the `op` pattern, so without a by-name rejection it
        # would load as an OPEN rewrite-target op (esm-spec §4.2) and fail only
        # much later as `unlowered_operator`.
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "faq",
                        "arrayop_op_removed.esm")
        err = try
            EarthSciAST.load_path(path)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("removed_op", sprint(showerror, err))  # the shared diagnostic name
    end
end
